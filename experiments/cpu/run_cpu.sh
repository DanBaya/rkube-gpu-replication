#!/usr/bin/env bash
# run_cpu.sh
# Runs one trial of the CPU arm and appends one row to the results CSV.
#
# Usage:
#   ./run_cpu.sh <condition> <trial_number> [csv_path]
#
#   condition     A | B | C
#   trial_number  integer, used only as a label in the output
#   csv_path      defaults to results/raw/cpu.csv
#
# Timeline of a single trial:
#
#   t=0    neighbours launch (conditions B and C only), live 75s
#   t=5    target launches, lives 65s
#   t=8    t0 sample: usage_usec and wall clock
#   t=68   t1 sample: usage_usec and wall clock
#   t=70   target exits
#   t=75   neighbours exit
#
# Neighbours bracket the target's entire lifetime, so the target never runs
# against a partially warmed or already draining neighbour set. The 60s
# measurement window sits inside the target's steady state, excluding 3s of
# spin up and 2s of drain.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib_cgroup.sh
source "${SCRIPT_DIR}/lib_cgroup.sh"

# ---------------------------------------------------------------- parameters
IMAGE="${IMAGE:-rkube-stress:pinned}"
RESERVED_CPUS=12          # must match config.md
TARGET_WORKERS=12
TARGET_LIFETIME=65        # seconds
NEIGHBOUR_LIFETIME=75     # seconds
NEIGHBOUR_LEAD=5          # seconds neighbours start before the target
SPINUP_EXCLUDE=3          # seconds excluded at the start of the target's life
WINDOW=60                 # seconds, the measurement window

TARGET_NAME="rkube-target"
NEIGHBOUR_PREFIX="rkube-neighbour"

CONDITION="${1:?usage: run_cpu.sh <A|B|C> <trial> [csv_path]}"
TRIAL="${2:?usage: run_cpu.sh <A|B|C> <trial> [csv_path]}"
CSV="${3:-${REPO_ROOT}/results/raw/cpu.csv}"

METRICS_DIR="${REPO_ROOT}/results/raw/stress_yaml"
mkdir -p "$(dirname "$CSV")" "$METRICS_DIR"

# ------------------------------------------------------------------ cleanup
cleanup() {
    docker rm -f "$TARGET_NAME" >/dev/null 2>&1
    local i
    for i in 1 2 3; do
        docker rm -f "${NEIGHBOUR_PREFIX}-${i}" >/dev/null 2>&1
    done
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------- preconditions
verify_cgroup_v2 || exit 1

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "FATAL: image ${IMAGE} not found. Build it first:" >&2
    echo "  docker build -t ${IMAGE} ${SCRIPT_DIR}" >&2
    exit 1
fi

# A stray container from a crashed prior trial silently poisons the next one.
cleanup
if [[ -n "$(docker ps -q --filter "name=rkube-")" ]]; then
    echo "FATAL: rkube containers still running after cleanup. Investigate." >&2
    exit 1
fi

# --------------------------------------------------------------- neighbours
launch_neighbours() {
    local i
    case "$CONDITION" in
        A)
            # No neighbours. Solo baseline.
            ;;
        B)
            # Capped. Each neighbour is quota limited to 4 CPUs, 12 total.
            # Target 12 plus neighbours 12 exactly saturates 24 logical CPUs.
            for i in 1 2 3; do
                docker run -d --rm --name "${NEIGHBOUR_PREFIX}-${i}" \
                    --cpus=4 "$IMAGE" \
                    --cpu 8 --timeout "${NEIGHBOUR_LIFETIME}s" >/dev/null
            done
            ;;
        C)
            # Burstable. No --cpus ceiling, and each neighbour spawns more
            # workers than the machine has cores. This is the rKube condition:
            # the split is decided by cgroup weight, not quota.
            for i in 1 2 3; do
                docker run -d --rm --name "${NEIGHBOUR_PREFIX}-${i}" \
                    "$IMAGE" \
                    --cpu 24 --timeout "${NEIGHBOUR_LIFETIME}s" >/dev/null
            done
            ;;
        *)
            echo "FATAL: unknown condition '${CONDITION}'. Use A, B, or C." >&2
            exit 1
            ;;
    esac
}

launch_neighbours

if [[ "$CONDITION" != "A" ]]; then
    sleep "$NEIGHBOUR_LEAD"
    running="$(docker ps -q --filter "name=${NEIGHBOUR_PREFIX}" | wc -l)"
    if [[ "$running" -ne 3 ]]; then
        echo "FATAL: expected 3 neighbours, found ${running}. Trial aborted." >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------- target
YAML_HOST="${METRICS_DIR}/${CONDITION}_${TRIAL}.yml"
rm -f "$YAML_HOST"

docker run -d --name "$TARGET_NAME" \
    --cpus="$RESERVED_CPUS" \
    -v "${METRICS_DIR}:/out" \
    "$IMAGE" \
    --cpu "$TARGET_WORKERS" \
    --timeout "${TARGET_LIFETIME}s" \
    --metrics \
    --yaml "/out/${CONDITION}_${TRIAL}.yml" >/dev/null || {
        echo "FATAL: target container failed to start." >&2
        exit 1
    }

sleep "$SPINUP_EXCLUDE"

CG="$(resolve_cgroup "$TARGET_NAME")" || {
    echo "FATAL: could not resolve target cgroup. Trial aborted." >&2
    exit 1
}

# --------------------------------------------------------------- measurement
U0="$(read_usage_usec "$CG")" || { echo "FATAL: usage_usec unreadable at t0" >&2; exit 1; }
W0="$(wall_usec)"

sleep "$WINDOW"

# The container must still be alive here, because the cgroup directory is
# torn down on exit and a dead container yields a read failure rather than
# a final value.
if ! docker ps -q --filter "name=${TARGET_NAME}" | grep -q .; then
    echo "FATAL: target exited before the window closed. Timing is wrong." >&2
    exit 1
fi

U1="$(read_usage_usec "$CG")" || { echo "FATAL: usage_usec unreadable at t1" >&2; exit 1; }
W1="$(wall_usec)"
read -r NR_THROTTLED THROTTLED_USEC <<<"$(read_throttle "$CG")"

USAGE_DELTA=$(( U1 - U0 ))
WALL_DELTA=$(( W1 - W0 ))
RATIO="$(compute_ratio "$USAGE_DELTA" "$WALL_DELTA" "$RESERVED_CPUS")"

# ---------------------------------------------------------------- throughput
docker wait "$TARGET_NAME" >/dev/null 2>&1

BOGO_OPS="NA"
BOGO_RATE="NA"
if [[ -f "$YAML_HOST" ]]; then
    # Match the key exactly. A loose grep for bogo-ops also catches
    # bogo-ops-per-second-real-time and silently returns the wrong number.
    BOGO_OPS="$(awk '$1 == "bogo-ops:" {print $2; exit}' "$YAML_HOST")"
    BOGO_RATE="$(awk '$1 == "bogo-ops-per-second-real-time:" {print $2; exit}' "$YAML_HOST")"
    [[ -z "$BOGO_OPS"  ]] && BOGO_OPS="NA"
    [[ -z "$BOGO_RATE" ]] && BOGO_RATE="NA"
fi

# ---------------------------------------------------------------------- csv
HEADER="condition,trial,timestamp,usage_delta_usec,wall_delta_usec,reserved_cpus,delivery_ratio,nr_throttled,throttled_usec,bogo_ops,bogo_ops_per_sec"
if [[ ! -f "$CSV" ]]; then
    echo "$HEADER" > "$CSV"
fi

echo "${CONDITION},${TRIAL},$(date -Iseconds),${USAGE_DELTA},${WALL_DELTA},${RESERVED_CPUS},${RATIO},${NR_THROTTLED},${THROTTLED_USEC},${BOGO_OPS},${BOGO_RATE}" >> "$CSV"

printf 'cond=%s trial=%s ratio=%s throttled=%s bogo/s=%s\n' \
    "$CONDITION" "$TRIAL" "$RATIO" "$NR_THROTTLED" "$BOGO_RATE"
