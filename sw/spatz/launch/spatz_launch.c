// K9R5: CVA6 launcher for a Spatz cluster program. The program's image is
// linked into this ELF at the cluster's DRAM window (spatz_image.S), so it is
// preloaded with it. CVA6 writes the entry point to the cluster's boot
// control register, wakes all cores through CL_CLINT_SET (the cluster boot
// ROM waits in wfi) and polls the cluster's EOC register for the exit code.
// Prints one short line with the mailbox contents (UART output dominates
// simulation time) and returns the cluster program's exit code.

#include <stdint.h>
#include "dif/clint.h"
#include "dif/uart.h"
#include "k9r5_spatz_mailbox.h"
#include "params.h"
#include "regs/cheshire.h"
#include "spatz_cluster_peripheral.h"
#include "util.h"

// From spatz_image.S
extern const char __spatz_image_start[], __spatz_image_end[], __spatz_entry[];

static volatile uint32_t *spatz_reg(uint32_t offset) {
    return (volatile uint32_t *)(uintptr_t)(K9R5_SPATZ_PERIPH_BASE + offset);
}

// Appends the decimal representation of v to *s
static void put_dec(char **s, uint32_t v) {
    char buf[10];
    int n = 0;
    do buf[n++] = '0' + v % 10;
    while (v /= 10);
    while (n) *(*s)++ = buf[--n];
}

static void put_str(char **s, const char *t) {
    while (*t) *(*s)++ = *t++;
}

int main(void) {
    // Only read after the cluster has written it: CVA6 must not cache the
    // mailbox's line before (the cluster writes DRAM behind CVA6's cache)
    volatile k9r5_spatz_mailbox_t *mb = k9r5_spatz_mailbox();

    *spatz_reg(SPATZ_CLUSTER_PERIPHERAL_CLUSTER_EOC_EXIT_REG_OFFSET) = 0;
    *spatz_reg(SPATZ_CLUSTER_PERIPHERAL_CLUSTER_BOOT_CONTROL_REG_OFFSET) =
        (uint32_t)(uintptr_t)__spatz_entry;
    fence();
    *spatz_reg(SPATZ_CLUSTER_PERIPHERAL_CL_CLINT_SET_REG_OFFSET) = (1u << K9R5_SPATZ_CORES) - 1;

    uint32_t eoc;
    while (!((eoc = *spatz_reg(SPATZ_CLUSTER_PERIPHERAL_CLUSTER_EOC_EXIT_REG_OFFSET)) & 1))
        ;
    int ret = eoc >> 1;

    // e.g. "spatz ret 0 cores ff vec 312 dma 845": exit code, core mask (hex)
    // and the cluster cycles of the vector phase and the DMA round trip
    char msg[112], *s = msg;
    put_str(&s, "spatz ret ");
    put_dec(&s, ret);
    if (mb->magic == K9R5_SPATZ_MAILBOX_MAGIC) {
        put_str(&s, " cores ");
        int i = 7;
        while (i > 0 && !(mb->cores >> (4 * i))) i--;
        for (; i >= 0; i--) *s++ = "0123456789abcdef"[(mb->cores >> (4 * i)) & 0xf];
        put_str(&s, " vec ");
        put_dec(&s, mb->vec_cycles);
        put_str(&s, " dma ");
        put_dec(&s, mb->dma_cycles);
        // On failure: wrong elements per check (axpy/dma/add) and the first
        // wrong axpy element, e.g. " err 1024/0/0 y[0] 0 exp 1000"
        if (mb->errors) {
            put_str(&s, " err ");
            for (int e = 0; e < K9R5_SPATZ_NUM_ERR; e++) {
                if (e) *s++ = '/';
                put_dec(&s, mb->err[e]);
            }
        }
        if (mb->err[K9R5_SPATZ_ERR_AXPY]) {
            put_str(&s, " y[");
            put_dec(&s, mb->bad_idx);
            put_str(&s, "] ");
            if (mb->bad_got < 0) *s++ = '-';
            put_dec(&s, mb->bad_got < 0 ? -mb->bad_got : mb->bad_got);
            put_str(&s, " exp ");
            put_dec(&s, mb->bad_exp);
        }
    }
    put_str(&s, "\r\n");

    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, __BOOT_BAUDRATE);
    uart_write_str(&__base_uart, msg, s - msg);
    uart_write_flush(&__base_uart);

    // Keep the image (and its section) referenced for --gc-sections
    return (uintptr_t)__spatz_image_end > (uintptr_t)__spatz_image_start ? ret : 0x7f;
}
