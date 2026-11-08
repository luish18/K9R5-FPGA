// K9R5: self-checking test of every core of the Spatz cluster.
//
// Each core fills its slice of fp64 and int32 vectors in TCDM, then with its
// own Spatz computes y = a * x + y (vfmacc.vf, e64) and z = p + q (vadd.vv,
// e32). Core 0 copies the fp64 results to DRAM and back with the cluster DMA,
// and every core checks its slice of the results against scalar code: the
// axpy result in TCDM, its copy back from DRAM and the integer sum. All values
// are small integers, so the results are exact.
//
// Returns (through the cluster's EOC register) the number of wrong elements,
// plus 0x100 if a core did not take part. The core mask, the error counts per
// check, the first wrong axpy element and the cycle counts are also left in
// the mailbox for CVA6 (k9r5_spatz_mailbox.h).

#include <snrt.h>
#include <stdint.h>

#include "k9r5_spatz_mailbox.h"

#define N_PER_CORE 128
#define ALPHA      3.0

// Shared by all cores: set by core 0 before the first barrier
static double *x, *y, *y_back;
static int32_t *p, *q, *z;
static volatile uint32_t *errors, *cores;  // errors[K9R5_SPATZ_NUM_ERR]
// DMA round trip target in DRAM
static double y_dram[N_PER_CORE * 8];

static inline uint32_t mcycle(void) {
    uint32_t c;
    asm volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

// ALPHA * i + (1000 - i) with ALPHA = 3, computed in integers: scalar fused
// FP ops are not reliable here (a scalar fmadd.d's result never reached the
// FP register file in the K9R5 model, see README), and the check must only
// depend on the vector units
static inline double y_expected(uint32_t i) {
    return (double)(2 * (int32_t)i + 1000);
}

// y = a * x + y
static void faxpy(double a, const double *x, double *y, unsigned int n) {
    while (n) {
        unsigned int vl;
        asm volatile("vsetvli %0, %1, e64, m8, ta, ma" : "=r"(vl) : "r"(n));
        asm volatile("vle64.v v0, (%0)" ::"r"(x) : "memory");
        asm volatile("vle64.v v8, (%0)" ::"r"(y) : "memory");
        asm volatile("vfmacc.vf v8, %0, v0" ::"f"(a));
        asm volatile("vse64.v v8, (%0)" ::"r"(y) : "memory");
        x += vl;
        y += vl;
        n -= vl;
    }
}

// z = p + q
static void iadd(const int32_t *p, const int32_t *q, int32_t *z, unsigned int n) {
    while (n) {
        unsigned int vl;
        asm volatile("vsetvli %0, %1, e32, m8, ta, ma" : "=r"(vl) : "r"(n));
        asm volatile("vle32.v v0, (%0)" ::"r"(p) : "memory");
        asm volatile("vle32.v v8, (%0)" ::"r"(q) : "memory");
        asm volatile("vadd.vv v16, v0, v8");
        asm volatile("vse32.v v16, (%0)" ::"r"(z) : "memory");
        p += vl;
        q += vl;
        z += vl;
        n -= vl;
    }
}

int main(void) {
    const uint32_t cid = snrt_cluster_core_idx();
    const uint32_t num_cores = snrt_cluster_core_num();
    const uint32_t n = N_PER_CORE * num_cores;
    uint32_t t_vec = 0, t_dma = 0;

    if (num_cores > 8) return 0x200;  // y_dram is sized for up to 8 cores

    if (cid == 0) {
        x = snrt_l1alloc(n * sizeof(double));
        y = snrt_l1alloc(n * sizeof(double));
        y_back = snrt_l1alloc(n * sizeof(double));
        p = snrt_l1alloc(n * sizeof(int32_t));
        q = snrt_l1alloc(n * sizeof(int32_t));
        z = snrt_l1alloc(n * sizeof(int32_t));
        errors = snrt_l1alloc(K9R5_SPATZ_NUM_ERR * sizeof(uint32_t));
        cores = snrt_l1alloc(sizeof(uint32_t));
        for (int e = 0; e < K9R5_SPATZ_NUM_ERR; e++) errors[e] = 0;
        *cores = 0;
    }
    snrt_cluster_hw_barrier();

    // Each core initializes its own slice
    const uint32_t base = cid * N_PER_CORE;
    for (uint32_t i = base; i < base + N_PER_CORE; i++) {
        x[i] = (double)i;
        y[i] = (double)(1000 - (int32_t)i);
        p[i] = 7 * (int32_t)i - 300;
        q[i] = 5 * (int32_t)i;
    }
    __atomic_fetch_or(cores, 1u << cid, __ATOMIC_RELAXED);
    snrt_cluster_hw_barrier();

    // Vector phase: all cores at once
    if (cid == 0) t_vec = mcycle();
    faxpy(ALPHA, x + base, y + base, N_PER_CORE);
    iadd(p + base, q + base, z + base, N_PER_CORE);
    snrt_cluster_hw_barrier();
    if (cid == 0) t_vec = mcycle() - t_vec;

    // DMA round trip of the fp64 results through DRAM
    if (cid == 0) {
        t_dma = mcycle();
        snrt_dma_start_1d(y_dram, y, n * sizeof(double));
        snrt_dma_wait_all();
        snrt_dma_start_1d(y_back, y_dram, n * sizeof(double));
        snrt_dma_wait_all();
        t_dma = mcycle() - t_dma;
    }
    snrt_cluster_hw_barrier();

    // Each core checks its own slice
    uint32_t err[K9R5_SPATZ_NUM_ERR] = {0};
    for (uint32_t i = base; i < base + N_PER_CORE; i++) {
        if (y[i] != y_expected(i)) err[K9R5_SPATZ_ERR_AXPY]++;
        if (y_back[i] != y[i]) err[K9R5_SPATZ_ERR_DMA]++;
        if (z[i] != 12 * (int32_t)i - 300) err[K9R5_SPATZ_ERR_ADD]++;
    }
    for (int e = 0; e < K9R5_SPATZ_NUM_ERR; e++)
        if (err[e]) __atomic_fetch_add(&errors[e], err[e], __ATOMIC_RELAXED);
    snrt_cluster_hw_barrier();

    if (cid != 0) return 0;

    uint32_t all = (num_cores == 32) ? ~0u : (1u << num_cores) - 1;
    uint32_t total = 0;
    volatile k9r5_spatz_mailbox_t *mb = k9r5_spatz_mailbox();
    for (int e = 0; e < K9R5_SPATZ_NUM_ERR; e++) {
        mb->err[e] = errors[e];
        total += errors[e];
    }
    mb->bad_idx = n;
    for (uint32_t i = 0; errors[K9R5_SPATZ_ERR_AXPY] && i < n; i++)
        if (y[i] != y_expected(i)) {
            mb->bad_idx = i;
            mb->bad_got = (int32_t)y[i];
            mb->bad_exp = (int32_t)y_expected(i);
            break;
        }
    uint32_t ret = total + (*cores != all ? 0x100 : 0);
    mb->cores = *cores;
    mb->errors = total;
    mb->vec_cycles = t_vec;
    mb->dma_cycles = t_dma;
    mb->magic = K9R5_SPATZ_MAILBOX_MAGIC;
    // The EOC write takes another path (cluster peripherals): make sure the
    // mailbox has reached DRAM before CVA6 reads it
    asm volatile("fence" ::: "memory");
    while (mb->magic != K9R5_SPATZ_MAILBOX_MAGIC)
        ;
    return ret;
}
