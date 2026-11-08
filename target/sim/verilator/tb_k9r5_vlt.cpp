// K9R5 Verilator testbench driver for tb_k9r5_vlt.sv: clocks and reset, ELF
// preload, UART output, exit code and timeout. Mirrors what Cheshire's VIP
// does in idle boot with serial link preload (BOOTMODE=0, PRELMODE=1):
//
//   1. Wait until the boot ROM has configured the LLC as SPM (poll over the
//      serial link, as the VIP does).
//   2. Preload the ELF: DRAM segments directly into the C++ memory, all other
//      segments over the serial link.
//   3. Write the entry point to SCRATCH[1:0] and the launch signal to
//      SCRATCH[2] over the serial link.
//   4. Wait for software to write its exit code to SCRATCH[2] (bit 0 set).
//
// Plusargs: +BINARY=<elf> (required), +TIMEOUT=<time> of simulated time (e.g.
// 100ms, 500us; 0 for none), +TRACE=<file.fst> (models built with tracing),
// +PROGRESS=<n> (print hart 0's pc every n cycles, and preload details).

#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <verilated.h>
#if VM_TRACE
#include <verilated_fst_c.h>
#endif

#include "Vtb_k9r5_vlt.h"
#include "Vtb_k9r5_vlt__Dpi.h"

// Timing in ps, as in Cheshire's VIP and the former K9R5 Questa fixture
static const uint64_t kClkPeriodSys   = 5000;      // 200 MHz
static const uint64_t kClkPeriodSpatz = 12500;     // 80 MHz
static const uint64_t kClkPeriodRtc   = 30518000;  // 32.768 kHz
static const unsigned kRstCycles      = 5;
static const uint64_t kUartBaudRate   = 115200;
static const uint64_t kUartBaudPeriod = 1000000000000ULL / kUartBaudRate;
// Idle cycles between serial link polls of the LLC configuration (as the VIP)
static const unsigned kLlcPollIdle = 20;

/////////////////
//  DRAM model //
/////////////////

// Sparse 64-bit word memory, zero where never written
class SparseMem {
  public:
    uint64_t read(uint64_t addr) {
        auto it = pages_.find(addr >> kPageBits);
        return it == pages_.end() ? 0 : it->second[word(addr)];
    }
    void write(uint64_t addr, uint64_t data, uint8_t strb) {
        auto &page = pages_[addr >> kPageBits];
        if (!page) page.reset(new uint64_t[kPageWords]());
        uint64_t mask = 0;
        for (int b = 0; b < 8; b++)
            if (strb & (1 << b)) mask |= 0xffULL << (8 * b);
        uint64_t &w = page[word(addr)];
        w = (w & ~mask) | (data & mask);
    }

  private:
    static const unsigned kPageBits  = 16;
    static const unsigned kPageWords = (1 << kPageBits) / 8;
    static unsigned word(uint64_t addr) { return (addr & ((1 << kPageBits) - 1)) >> 3; }
    std::unordered_map<uint64_t, std::unique_ptr<uint64_t[]>> pages_;
};

static SparseMem dram;

long long k9r5_vlt_dram_read(long long addr) { return dram.read(addr); }
void k9r5_vlt_dram_write(long long addr, long long data, char strb) {
    dram.write(addr, data, (uint8_t)strb);
}

/////////////////////////////
//  Serial link mem master //
/////////////////////////////

// Drives the testbench's 64-bit memory port (axi_from_mem on the mirror serial
// link). Requests are issued back to back; responses arrive in order.
class SlinkMaster {
  public:
    struct Req {
        uint64_t addr, data;
        uint8_t be;
        bool we;
    };

    explicit SlinkMaster(Vtb_k9r5_vlt *top) : top_(top) {
        top_->slink_mem_req_i = 0;
        top_->slink_mem_we_i  = 0;
    }

    void write(uint64_t addr, uint64_t data, uint8_t be) { queue_.push_back({addr, data, be, true}); }
    void read(uint64_t addr) { queue_.push_back({addr, 0, 0xff, false}); }
    bool idle() const { return queue_.empty() && inflight_.empty() && !top_->slink_mem_req_i; }
    bool has_read_data() const { return !rdata_.empty(); }
    uint64_t pop_read_data() {
        uint64_t d = rdata_.front();
        rdata_.pop_front();
        return d;
    }
    unsigned errors() const { return errors_; }
    size_t pending() const { return queue_.size() + inflight_.size(); }

    // Just before a rising clock edge: sample handshake and responses
    void before_posedge() {
        handshake_ = top_->slink_mem_req_i && top_->slink_mem_gnt_o;
        if (top_->slink_mem_rsp_valid_o) {
            if (inflight_.empty()) {
                fprintf(stderr, "[K9R5] Serial link response without request\n");
                return;
            }
            Req r = inflight_.front();
            inflight_.pop_front();
            if (top_->slink_mem_rsp_error_o) {
                errors_++;
                printf("[SLINK] %s error at 0x%016" PRIx64 "\n", r.we ? "Write" : "Read", r.addr);
            }
            if (!r.we) rdata_.push_back(top_->slink_mem_rsp_rdata_o);
        }
    }

    // Just after a rising clock edge: drive the next request
    void after_posedge() {
        if (handshake_) top_->slink_mem_req_i = 0;
        if (!top_->slink_mem_req_i && !queue_.empty()) {
            Req r = queue_.front();
            queue_.pop_front();
            top_->slink_mem_req_i   = 1;
            top_->slink_mem_addr_i  = r.addr;
            top_->slink_mem_we_i    = r.we;
            top_->slink_mem_wdata_i = r.data;
            top_->slink_mem_be_i    = r.be;
            inflight_.push_back(r);
        }
    }

  private:
    Vtb_k9r5_vlt *top_;
    std::deque<Req> queue_, inflight_;
    std::deque<uint64_t> rdata_;
    bool handshake_ = false;
    unsigned errors_ = 0;
};

///////////
//  ELF  //
///////////

struct Segment {
    uint64_t addr;
    std::vector<uint8_t> data;  // p_memsz bytes, zero-filled past p_filesz
};

static bool load_elf(const char *path, std::vector<Segment> &segs, uint64_t &entry) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        printf("[ELF] Cannot open %s\n", path);
        return false;
    }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    auto rd = [&](size_t off, size_t n) -> uint64_t {
        uint64_t v = 0;
        if (off + n > buf.size()) return 0;
        memcpy(&v, &buf[off], n);  // little endian host and target
        return v;
    };
    if (buf.size() < 64 || memcmp(buf.data(), "\x7f" "ELF", 4) || buf[4] != 2 || buf[5] != 1) {
        printf("[ELF] %s is not a little-endian ELF64 file\n", path);
        return false;
    }
    entry = rd(24, 8);
    uint64_t phoff = rd(32, 8);
    unsigned phentsize = rd(54, 2), phnum = rd(56, 2);
    for (unsigned i = 0; i < phnum; i++) {
        size_t ph = phoff + i * phentsize;
        if (rd(ph, 4) != 1 /* PT_LOAD */) continue;
        uint64_t off = rd(ph + 8, 8), paddr = rd(ph + 24, 8);
        uint64_t filesz = rd(ph + 32, 8), memsz = rd(ph + 40, 8);
        if (!filesz) continue;  // as Cheshire's elfloader: .bss is not preloaded
        if (off + filesz > buf.size()) {
            printf("[ELF] Segment at 0x%" PRIx64 " exceeds the file\n", paddr);
            return false;
        }
        Segment s{paddr, std::vector<uint8_t>(memsz, 0)};
        memcpy(s.data.data(), &buf[off], filesz);
        segs.push_back(std::move(s));
    }
    return true;
}

// Split a segment into 64-bit aligned words with byte enables
template <typename F>
static void for_each_word(const Segment &s, F f) {
    uint64_t end = s.addr + s.data.size();
    for (uint64_t a = s.addr & ~7ULL; a < end; a += 8) {
        uint64_t data = 0;
        uint8_t be = 0;
        for (int b = 0; b < 8; b++) {
            uint64_t ba = a + b;
            if (ba < s.addr || ba >= end) continue;
            data |= (uint64_t)s.data[ba - s.addr] << (8 * b);
            be |= 1 << b;
        }
        f(a, data, be);
    }
}

////////////
//  UART  //
////////////

// Decodes 8N1 frames from the sampled TX line and prints lines as Cheshire's
// VIP does ("[UART] <line>")
class UartRx {
  public:
    void sample(uint64_t t, bool tx) {
        if (!busy_) {
            if (last_ && !tx) {
                busy_ = true;
                next_ = t + kUartBaudPeriod + kUartBaudPeriod / 2;
                bit_ = 0;
                byte_ = 0;
            }
        } else if (t >= next_) {
            if (bit_ < 8) {
                byte_ |= tx << bit_++;
                next_ += kUartBaudPeriod;
            } else {  // stop bit
                busy_ = false;
                put(byte_);
            }
        }
        last_ = tx;
    }
    bool busy() const { return busy_; }
    void flush() {
        if (!line_.empty()) printf("[UART] %s\n", line_.c_str());
        line_.clear();
    }

  private:
    void put(uint8_t c) {
        if (c == '\n') {
            printf("[UART] %s\n", line_.c_str());
            fflush(stdout);
            line_.clear();
        } else if (c != '\r') {
            line_.push_back(c);
        }
    }
    // A start bit needs an idle (high) line first: TX may be low out of reset
    bool busy_ = false, last_ = false;
    uint64_t next_ = 0;
    unsigned bit_ = 0;
    uint8_t byte_ = 0;
    std::string line_;
};

////////////
//  Main  //
////////////

// Parses a time such as "100ms", "20us", "1500ns" or "0" into ps
static bool parse_time(const char *s, uint64_t &ps) {
    char *end;
    double v = strtod(s, &end);
    std::string unit(end);
    static const std::pair<const char *, double> units[] = {
        {"", 1e3}, {"ps", 1}, {"ns", 1e3}, {"us", 1e6}, {"ms", 1e9}, {"s", 1e12}};
    for (auto &u : units)
        if (unit == u.first) {
            ps = (uint64_t)(v * u.second);
            return end != s;
        }
    return false;
}

// Value of +<name>=<value> (copied: Verilator returns a buffer it reuses)
static const char *plusarg(VerilatedContext *ctx, const char *name) {
    std::string match = std::string(name) + "=";
    const char *a = ctx->commandArgsPlusMatch(match.c_str());
    return *a ? strdup(a + match.size() + 1) : nullptr;
}

int main(int argc, char **argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    ctx->randReset(0);
    Verilated::mkdir("logs");

    const char *binary = plusarg(ctx.get(), "BINARY");
    if (!binary) {
        fprintf(stderr, "Usage: %s +BINARY=<elf> [+TIMEOUT=<time>] [+TRACE=<file.fst>] [+PROGRESS=<n>]\n",
                argv[0]);
        return 2;
    }
    uint64_t timeout = 0;
    const char *timeout_arg = plusarg(ctx.get(), "TIMEOUT");
    if (timeout_arg && !parse_time(timeout_arg, timeout)) {
        fprintf(stderr, "[K9R5] Bad +TIMEOUT=%s (e.g. 100ms, 0 for none)\n", timeout_arg);
        return 2;
    }

    const char *progress_arg = plusarg(ctx.get(), "PROGRESS");
    uint64_t progress = progress_arg ? strtoull(progress_arg, nullptr, 0) : 0;
    bool verbose = progress != 0;

    std::vector<Segment> segs;
    uint64_t entry = 0;
    printf("[ELF] Loading %s\n", binary);
    if (!load_elf(binary, segs, entry)) return 2;

    auto top = std::make_unique<Vtb_k9r5_vlt>(ctx.get(), "TOP");
#if VM_TRACE
    std::unique_ptr<VerilatedFstC> tfp;
    if (const char *trace = plusarg(ctx.get(), "TRACE")) {
        ctx->traceEverOn(true);
        tfp.reset(new VerilatedFstC);
        top->trace(tfp.get(), 99);
        tfp->open(trace);
        printf("[K9R5] Tracing to %s\n", trace);
    }
#endif

    SlinkMaster slink(top.get());
    UartRx uart;

    top->clk_i       = 0;
    top->clk_spatz_i = 0;
    top->rtc_i       = 0;
    top->rst_ni      = 0;

    enum { kReset, kWaitLlc, kPreload, kEntry, kLaunch, kRun, kDrainUart, kDone } phase = kReset;
    uint64_t t = 0, cycles = 0, phase_cycle = 0, launch_cycle = 0;
    uint64_t next_sys = 0, next_spatz = 0, next_rtc = 0;
    int exit_code = -1;
    bool timed_out = false;
    auto wall_start = std::chrono::steady_clock::now();
    auto wall_launch = wall_start;

    while (phase != kDone && !ctx->gotFinish()) {
        // Next clock edge, or an earlier event of the design's timing controls
        t = std::min({next_sys, next_spatz, next_rtc});
        if (top->eventsPending()) t = std::min<uint64_t>(t, top->nextTimeSlot());
        if (timeout && t >= timeout) {
            timed_out = true;
            break;
        }
        ctx->time(t);
        bool sys_posedge = false;
        if (t == next_sys) {
            top->clk_i = !top->clk_i;
            sys_posedge = top->clk_i;
            next_sys += kClkPeriodSys / 2;
        }
        if (t == next_spatz) {
            top->clk_spatz_i = !top->clk_spatz_i;
            next_spatz += kClkPeriodSpatz / 2;
        }
        if (t == next_rtc) {
            top->rtc_i = !top->rtc_i;
            next_rtc += kClkPeriodRtc / 2;
        }

        if (sys_posedge && phase != kReset) slink.before_posedge();
        top->eval();
#if VM_TRACE
        if (tfp) tfp->dump(t);
#endif
        if (!sys_posedge) continue;

        // After a rising edge of the system clock
        cycles++;
        if (phase != kReset) uart.sample(t, top->uart_tx_o);
        if (progress && cycles % progress == 0) {
            printf("[K9R5] cycle %" PRIu64 ": pc=0x%016" PRIx64 " scratch2=0x%08x\n", cycles,
                   (uint64_t)top->pc_o, top->scratch2_o);
            fflush(stdout);
        }
        switch (phase) {
            case kReset:
                // Release reset (at the next falling edge) after kRstCycles
                if (cycles == kRstCycles) {
                    top->rst_ni = 1;
                    phase = kWaitLlc;
                    phase_cycle = cycles;
                    if (!top->llc_spm_cfg_addr_o) phase = kPreload;
                }
                break;
            case kWaitLlc:
                // Wait until the boot ROM has set up the LLC as SPM (bit 0)
                if (slink.has_read_data()) {
                    uint64_t d = slink.pop_read_data();
                    if (verbose)
                        printf("[K9R5] cycle %" PRIu64 ": LLC SPM config 0x%016" PRIx64 "\n", cycles, d);
                    if (d >> (top->llc_spm_cfg_addr_o & 7) * 8 & 1) {
                        phase = kPreload;
                        break;
                    }
                    phase_cycle = cycles;
                }
                if (slink.idle() && cycles - phase_cycle >= kLlcPollIdle)
                    slink.read(top->llc_spm_cfg_addr_o & ~7ULL);
                break;
            case kPreload:
                for (auto &s : segs) {
                    bool in_dram = s.addr >= top->dram_start_o &&
                                   s.addr + s.data.size() <= top->dram_end_o;
                    printf("[ELF] Preloading segment at 0x%016" PRIx64 " (%zu bytes, %s)\n", s.addr,
                           s.data.size(), in_dram ? "DRAM" : "serial link");
                    for_each_word(s, [&](uint64_t a, uint64_t d, uint8_t be) {
                        if (in_dram) dram.write(a, d, be);
                        else slink.write(a, d, be);
                    });
                }
                phase_cycle = cycles;
                phase = kEntry;
                break;
            case kEntry:
                // Once preloaded: SCRATCH[0] = entry[31:0], SCRATCH[1] = entry[63:32]
                if (!slink.idle()) break;
                printf("[ELF] Preload complete after %" PRIu64 " cycles\n", cycles - phase_cycle);
                slink.write(top->scratch_addr_o, entry & 0xffffffff, 0x0f);
                slink.write(top->scratch_addr_o, entry & 0xffffffff00000000ULL, 0xf0);
                phase = kLaunch;
                break;
            case kLaunch:
                // Then the launch signal, SCRATCH[2] = 2
                if (!slink.idle()) break;
                slink.write(top->scratch_addr_o + 8, 2, 0x0f);
                printf("[K9R5] Launching hart 0 at 0x%016" PRIx64 "\n", entry);
                fflush(stdout);
                launch_cycle = cycles;
                wall_launch = std::chrono::steady_clock::now();
                phase = kRun;
                break;
            case kRun:
                if (top->scratch2_o & 1) {
                    exit_code = top->scratch2_o >> 1;
                    phase = kDrainUart;
                }
                break;
            case kDrainUart:
                // As Cheshire's testbench: let the UART finish the current byte
                if (!uart.busy()) phase = kDone;
                break;
            case kDone: break;
        }
        if (phase != kReset) slink.after_posedge();
    }

    uart.flush();
    double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall_start).count();
    double wall_run = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall_launch).count();
    if (slink.errors()) printf("[K9R5] %u serial link errors\n", slink.errors());
    if (timed_out)
        printf("[K9R5] Timeout after %.3f ms of simulated time\n", t / 1e9);
    else if (exit_code == 0)
        printf("[K9R5] SUCCESS\n");
    else if (exit_code > 0)
        printf("[K9R5] FAILED: return code %d\n", exit_code);
    printf("[K9R5] Stopped at %.3f us: pc=0x%016" PRIx64 " mcause=0x%016" PRIx64
           " mepc=0x%016" PRIx64 " mtval=0x%016" PRIx64 "\n",
           t / 1e6, (uint64_t)top->pc_o, (uint64_t)top->mcause_o, (uint64_t)top->mepc_o,
           (uint64_t)top->mtval_o);
    uint64_t run_cycles = launch_cycle ? cycles - launch_cycle : 0;
    printf("[K9R5] %" PRIu64 " cycles (%" PRIu64 " after launch) in %.1f s, %.1f kHz after launch\n",
           cycles, run_cycles, wall, wall_run > 0 ? run_cycles / wall_run / 1e3 : 0.0);

    top->final();
#if VM_TRACE
    if (tfp) tfp->close();
#endif
    return (exit_code == 0 && !slink.errors()) ? 0 : 1;
}
