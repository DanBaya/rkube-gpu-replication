#!/usr/bin/env bash
# smoke_test.sh
# Three minute sanity check. Run this BEFORE committing 45 minutes to the
# full run set.
#
# It verifies four things that, if wrong, produce plausible looking numbers
# rather than errors:
#
#   1. cgroup v2 is active and the cpu controller is enabled
#   2. the container's cgroup path resolves on this host's Docker driver
#   3. usage_usec is actually incrementing
#   4. the delivery ratio lands near 1.0 for a solo container
#
# A solo container reserving 12 CPUs and running 12 busy workers should
# deliver a ratio very close to 1.0. If it does not, the measurement is
# broken and every number from the full run would be garbage.
#
# Usage: ./smoke_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_cgroup.sh
source "${SCRIPT_DIR}/lib_cgroup.sh"

IMAGE="${IMAGE:-rkube-stress:pinned}"
NAME="rkube-smoke"
RESERVED=12
WINDOW=15

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM

echo "=== 1. cgroup v2 ==="
if verify_cgroup_v2; then
    echo "PASS: unified cgroup v2 with cpu controller"
    echo "controllers: $(cat "${CGROUP_ROOT}/cgroup.controllers")"
else
    echo "FAIL: stop here, the harness cannot work on this host"
    exit 1
fi
echo

echo "=== 2. docker driver ==="
docker info --format 'cgroup driver:  {{.CgroupDriver}}
cgroup version: {{.CgroupVersion}}' 2>/dev/null || echo "WARN: docker info unavailable"
echo

echo "=== 3. image ==="
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "PASS: ${IMAGE} present"
    docker run --rm --entrypoint cat "$IMAGE" /stress-ng-version.txt 2>/dev/null | head -n1
else
    echo "FAIL: build it with: docker build -t ${IMAGE} ${SCRIPT_DIR}"
    exit 1
fi
echo

echo "=== 4. cgroup resolution ==="
cleanup
docker run -d --name "$NAME" --cpus="$RESERVED" "$IMAGE" \
    --cpu "$RESERVED" --timeout 40s >/dev/null || { echo "FAIL: container did not start"; exit 1; }
sleep 3

CG="$(resolve_cgroup "$NAME")" || { echo "FAIL: cgroup did not resolve"; exit 1; }
echo "PASS: ${CG}"
echo
echo "--- cpu.stat contents ---"
cat "${CG}/cpu.stat"
echo "-------------------------"
echo
echo "--- cpu.max (quota period) ---"
cat "${CG}/cpu.max" 2>/dev/null || echo "cpu.max unreadable"
echo "------------------------------"
echo

echo "=== 5. ${WINDOW}s measurement ==="
U0="$(read_usage_usec "$CG")"; W0="$(wall_usec)"
sleep "$WINDOW"
U1="$(read_usage_usec "$CG")"; W1="$(wall_usec)"
read -r NRT TU <<<"$(read_throttle "$CG")"

UD=$(( U1 - U0 ))
WD=$(( W1 - W0 ))
RATIO="$(compute_ratio "$UD" "$WD" "$RESERVED")"

cat <<EOF
usage_usec t0     : ${U0}
usage_usec t1     : ${U1}
usage delta (us)  : ${UD}
wall delta  (us)  : ${WD}
reserved cpus     : ${RESERVED}
delivery ratio    : ${RATIO}
nr_throttled      : ${NRT}
throttled_usec    : ${TU}
EOF
echo

echo "=== verdict ==="
awk -v r="$RATIO" 'BEGIN {
    if (r == "NaN")        { print "FAIL: ratio is NaN, arithmetic is broken"; exit }
    if (r > 0.90 && r < 1.10) { print "PASS: solo ratio near 1.0, harness is measuring correctly"; exit }
    if (r < 0.10)          { print "FAIL: ratio near zero, usage_usec is probably not incrementing"; exit }
    if (r > 1.30)          { print "FAIL: ratio well above 1.0, the quota is not being applied or RESERVED is wrong"; exit }
    print "SUSPECT: ratio is " r ", outside the expected solo band. Do not run the full set yet."
}'
echo
echo "Paste this entire output before starting the full run."
