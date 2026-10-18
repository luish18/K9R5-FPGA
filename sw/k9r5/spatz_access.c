// K9R5: CVA6 reaches the Spatz cluster through Cheshire's external AXI port and
// the clock domain crossing: write and read back the cluster's TCDM and one of
// its peripheral registers. Returns 0 on success, else the number of the first
// failing check. Prints one short line (UART output dominates sim time).

#include <stdint.h>
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "regs/cheshire.h"
#include "spatz_cluster_peripheral.h"
#include "util.h"

// Must match k9r5_pkg::SpatzBase and hw/spatz/k9r5.spatz_cluster.hjson
#define SPATZ_TCDM_BASE   0x51000000UL
#define SPATZ_TCDM_SIZE   (128 * 1024)
#define SPATZ_PERIPH_BASE (SPATZ_TCDM_BASE + SPATZ_TCDM_SIZE)

static volatile uint32_t *spatz_reg(uint32_t offset) {
    return (volatile uint32_t *)(SPATZ_PERIPH_BASE + offset);
}

int main(void) {
    int ret = 0;

    // TCDM: first, middle and last 64-bit words
    volatile uint64_t *tcdm = (volatile uint64_t *)SPATZ_TCDM_BASE;
    const uint32_t idx[] = {0, SPATZ_TCDM_SIZE / 16, SPATZ_TCDM_SIZE / 8 - 1};
    for (int i = 0; i < 3; i++) tcdm[idx[i]] = 0xC0FFEE0000000000ULL | idx[i];
    for (int i = 0; i < 3 && !ret; i++)
        if (tcdm[idx[i]] != (0xC0FFEE0000000000ULL | idx[i])) ret = 1 + i;

    // Cluster peripheral: CLUSTER_BOOT_CONTROL is a plain read/write register
    // (software-defined entry point for the cores)
    if (!ret) {
        *spatz_reg(SPATZ_CLUSTER_PERIPHERAL_CLUSTER_BOOT_CONTROL_REG_OFFSET) = 0x81000000;
        if (*spatz_reg(SPATZ_CLUSTER_PERIPHERAL_CLUSTER_BOOT_CONTROL_REG_OFFSET) != 0x81000000)
            ret = 4;
    }

    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, __BOOT_BAUDRATE);
    char msg[] = "spatz rw: ?\r\n";
    msg[10] = ret ? '0' + ret : 'K';
    uart_write_str(&__base_uart, msg, sizeof(msg) - 1);
    uart_write_flush(&__base_uart);
    return ret;
}
