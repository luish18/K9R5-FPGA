// K9R5: results a Spatz cluster program leaves for CVA6, at the end of the
// cluster's DRAM window (K9R5_SPATZ_MAILBOX, passed by the Makefile from
// hw/spatz/k9r5.spatz_cluster.hjson). Shared by the RV32 cluster programs and
// the RV64 launcher, hence fixed-width fields only.

#pragma once

#include <stdint.h>

#define K9R5_SPATZ_MAILBOX_MAGIC 0x5a7a0c0dU

// Error classes of vec_test
enum { K9R5_SPATZ_ERR_AXPY, K9R5_SPATZ_ERR_DMA, K9R5_SPATZ_ERR_ADD, K9R5_SPATZ_NUM_ERR };

typedef struct {
    uint32_t magic;       // K9R5_SPATZ_MAILBOX_MAGIC once the fields are valid
    uint32_t cores;       // cores that ran the program (bit per core index)
    uint32_t errors;      // wrong result elements, in total
    uint32_t vec_cycles;  // cluster cycles of the vector phase
    uint32_t dma_cycles;  // cluster cycles of the DMA round trip
    uint32_t err[K9R5_SPATZ_NUM_ERR];  // wrong elements per error class
    // First wrong fp64 vector result: index, result and expected value
    // (converted to integers; all expected values are integers)
    uint32_t bad_idx;
    int32_t bad_got, bad_exp;
} k9r5_spatz_mailbox_t;

static inline volatile k9r5_spatz_mailbox_t *k9r5_spatz_mailbox(void) {
    return (volatile k9r5_spatz_mailbox_t *)(uintptr_t)K9R5_SPATZ_MAILBOX;
}
