#!/usr/bin/env bash
# run_all_cpu.sh
# Runs the full CPU arm: 10 trials of each condition, interleaved.
#
# Interleaving matters. Running all ten A trials, then all ten B, then all
# ten C would confound condition with time. A 9900X under sustained load
# heats up and clocks down over forty minutes, so a block ordering would
# make condition C look worse partly because it ran last. Interleaving
# spreads any drift evenly across all three conditions.
#
# Trial 1 of each condition is discarded at analysis time as warmup. The
# script still runs it and still records it, so the discard is a documented
# analysis decision rather than missing data.
#
# Expected wall clock: 30 trials x roughly 82s plus cleanup, about 45 minutes.
#
# Usage: ./run_all_cpu.sh [trials_per_condition]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TRIALS="${1:-10}"
CSV="${REPO_ROOT}/results/raw/cpu.csv"
LOG="${REPO_ROOT}/results/raw/cpu_run.log"

mkdir -p "$(dirname "$CSV")"

echo "CPU arm: ${TRIALS} trials x 3 conditions, interleaved" | tee -a "$LOG"
echo "started $(date -Iseconds)" | tee -a "$LOG"
echo "csv: ${CSV}" | tee -a "$LOG"
echo | tee -a "$LOG"

# Provenance. Without this the results are not reproducible six weeks later.
{
    echo "--- host provenance ---"
    uname -a
    nproc
    docker --version
    docker info --format 'cgroup driver: {{.CgroupDriver}} / version: {{.CgroupVersion}}' 2>/dev/null
    echo "-----------------------"
} >> "$LOG" 2>&1

FAILED=0
for (( t=1; t<=TRIALS; t++ )); do
    for cond in A B C; do
        echo "[$(date +%H:%M:%S)] condition ${cond} trial ${t}" | tee -a "$LOG"
        if ! "${SCRIPT_DIR}/run_cpu.sh" "$cond" "$t" "$CSV" 2>&1 | tee -a "$LOG"; then
            echo "  WARN: trial failed, continuing" | tee -a "$LOG"
            FAILED=$(( FAILED + 1 ))
        fi
        # Let the machine settle between trials so residual heat and any
        # lingering kernel work does not bleed into the next measurement.
        sleep 5
    done
done

echo | tee -a "$LOG"
echo "finished $(date -Iseconds)" | tee -a "$LOG"
echo "failed trials: ${FAILED}" | tee -a "$LOG"
echo "rows written: $(( $(wc -l < "$CSV") - 1 ))" | tee -a "$LOG"
