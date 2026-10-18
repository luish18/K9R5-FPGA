#!/bin/sh
# Run Ara's riscv-tests on its Verilator testbench, in parallel, each with a
# timeout, and summarize. Exits non-zero unless every test passes.
#
# Usage: ara-riscv-tests.sh <model> <bin dir> <trace dir> <jobs> <timeout s>
#   <model>  Ara's Verilator binary (Vara_tb_verilator)
#   <bin>    directory with the test ELFs (ara/apps/bin)
# Runs every rv64u[iv]-ara-* ELF in <bin>; set K9R5_ARA_TESTS to a
# space-separated list of test names to run only those.
set -eu

model=$(realpath "$1"); bindir=$(realpath "$2"); tracedir=$3; jobs=$4; timeout_s=$5
mkdir -p "$tracedir"; tracedir=$(realpath "$tracedir")

if [ -n "${K9R5_ARA_TESTS:-}" ]; then
    tests=$(printf '%s\n' $K9R5_ARA_TESTS)
else
    tests=$(ls "$bindir" | grep -E '^rv64u[iv]-ara-[^.]+$' | sort)
fi
[ -n "$tests" ] || { echo "No tests found in $bindir (run 'make -C ara/apps riscv_tests')."; exit 1; }

# A test that hangs shows up as a timeout instead of blocking a job slot. Run in
# the trace directory: the model writes CVA6's trace_hart_0.dasm to its cwd.
cd "$tracedir"
printf '%s\n' $tests | xargs -P "$jobs" -I{} sh -c \
    "timeout $timeout_s '$model' -l ram,'$bindir/{}',elf > '$tracedir/{}.trace' 2>&1 || true"

pass=0; fail=0; hang=0
for t in $tests; do
    f=$tracedir/$t.trace
    if grep -q '\*\*\* SUCCESS \*\*\*' "$f"; then
        pass=$((pass + 1))
    elif grep -qE '\*\*\* FAILURE|FAILED|tohost = [1-9]' "$f"; then
        fail=$((fail + 1)); echo "FAIL:    $t :: $(grep -m1 -E 'FAILURE|FAILED|tohost' "$f")"
    else
        hang=$((hang + 1)); echo "TIMEOUT: $t (no result after ${timeout_s}s)"
    fi
done
total=$((pass + fail + hang))
echo "Ara riscv-tests: $pass passed, $fail failed, $hang timed out (of $total); traces in $tracedir"
[ "$pass" -eq "$total" ]
