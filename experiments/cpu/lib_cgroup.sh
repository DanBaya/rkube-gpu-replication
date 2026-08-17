#!/usr/bin/env bash
# lib_cgroup.sh
# cgroup v2 path resolution and cpu.stat reading for Docker containers.
#
# Docker on Fedora defaults to the systemd cgroup driver, which places
# container cgroups under system.slice as docker-<full-id>.scope. Other
# setups use the cgroupfs driver, which places them under /sys/fs/cgroup/docker.
# Rootless Docker puts them under a user slice. This resolver tries all of
# them rather than assuming, because guessing wrong yields a silent zero
# rather than an error.
#
# Source this file. Do not execute it directly.

set -uo pipefail

CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"

# verify_cgroup_v2
# Exits nonzero if the host is not running unified cgroup v2. The whole
# measurement approach depends on cpu.stat existing in the v2 format.
verify_cgroup_v2() {
    if [[ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]]; then
        echo "FATAL: ${CGROUP_ROOT}/cgroup.controllers not found." >&2
        echo "Host is not running unified cgroup v2. This harness requires v2." >&2
        return 1
    fi
    if ! grep -qw cpu "${CGROUP_ROOT}/cgroup.controllers"; then
        echo "FATAL: cpu controller not enabled at the cgroup root." >&2
        return 1
    fi
    return 0
}

# resolve_cgroup <container_name_or_id>
# Prints the absolute cgroup directory for the container on stdout.
# Returns nonzero and prints diagnostics to stderr if it cannot be found.
resolve_cgroup() {
    local ref="$1"
    local cid
    cid="$(docker inspect -f '{{.Id}}' "$ref" 2>/dev/null)" || {
        echo "resolve_cgroup: docker inspect failed for '${ref}'" >&2
        return 1
    }

    # Ask Docker directly first. This is authoritative when available.
    local reported
    reported="$(docker inspect -f '{{.HostConfig.CgroupParent}}' "$ref" 2>/dev/null)"

    local candidates=(
        "${CGROUP_ROOT}/system.slice/docker-${cid}.scope"
        "${CGROUP_ROOT}/docker/${cid}"
        "${CGROUP_ROOT}/user.slice/user-$(id -u).slice/user@$(id -u).service/user.slice/docker-${cid}.scope"
        "${CGROUP_ROOT}/system.slice/${reported}/docker-${cid}.scope"
    )

    local path
    for path in "${candidates[@]}"; do
        if [[ -f "${path}/cpu.stat" ]]; then
            echo "$path"
            return 0
        fi
    done

    # Last resort: search. Slow, but better than a wrong answer.
    local found
    found="$(find "${CGROUP_ROOT}" -maxdepth 4 -type d -name "*${cid}*" 2>/dev/null | head -n1)"
    if [[ -n "$found" && -f "${found}/cpu.stat" ]]; then
        echo "$found"
        return 0
    fi

    {
        echo "resolve_cgroup: no cpu.stat found for container ${ref} (${cid:0:12})"
        echo "Tried:"
        printf '  %s\n' "${candidates[@]}"
    } >&2
    return 1
}

# read_usage_usec <cgroup_path>
# Prints cumulative CPU time consumed by the cgroup, in microseconds.
read_usage_usec() {
    awk '/^usage_usec/ {print $2; found=1} END {if (!found) exit 1}' "$1/cpu.stat"
}

# read_throttle <cgroup_path>
# Prints "nr_throttled throttled_usec" on one line, space separated.
# Both keys are absent when no quota is set, in which case zeros are printed.
read_throttle() {
    awk '
        /^nr_throttled/   {nr = $2}
        /^throttled_usec/ {tu = $2}
        END {printf "%s %s\n", (nr == "" ? 0 : nr), (tu == "" ? 0 : tu)}
    ' "$1/cpu.stat"
}

# wall_usec
# Prints the current wall clock in microseconds. Uses date rather than
# SECONDS because 60s at second resolution is a 1.6 percent quantisation
# error on the denominator, which is the same order as the effect we are
# trying to measure.
wall_usec() {
    local ns
    ns="$(date +%s%N)"
    echo $(( ns / 1000 ))
}

# compute_ratio <usage_delta_usec> <wall_delta_usec> <reserved_cpus>
# Prints the delivery ratio to 4 decimal places. bash has no float
# arithmetic, so this goes through awk.
compute_ratio() {
    awk -v u="$1" -v w="$2" -v c="$3" \
        'BEGIN { if (w <= 0 || c <= 0) { print "NaN"; exit 1 } printf "%.4f\n", u / (w * c) }'
}
