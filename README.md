# Do Container Resource Reservations Hold for GPU?

A replication and extension of **Mind the Gap: Broken Promises of CPU
Reservations in Containerized Multi tenant Clouds** (Liu, Wang, Wang, Xiao,
Cheng, Chen. SoCC 2021) onto GPU and memory, on a single node consumer AMD
stack.

**Status:** in progress. CPU arm harness complete and unit tested. GPU and
memory arms pending.

---

## The question

Chen's group showed that a container requesting N CPUs does not reliably
receive N CPUs when its neighbours are burstable. This study asks whether the
same reservation promise breaks for GPU and memory, and if so whether it
breaks the same way.

The short version of the finding this repo is built to test:

| Resource | What happens to the reservation |
|---|---|
| CPU | Made, then partially honoured. Degrades smoothly under neighbour pressure |
| Memory | Made and honoured absolutely, until the OOM killer fires |
| GPU | Cannot be expressed on this stack. There is no fractional request to break |

The CPU arm is not the contribution. It is a calibration check: if the
harness reproduces a known result, its readings on the untested resources can
be trusted.

---

## Hardware

| Item | Value |
|---|---|
| OS | Fedora 43 |
| CPU | AMD Ryzen 9 9900X, 12 cores / 24 threads |
| GPU | AMD Radeon RX 9070 XT, 16GB GDDR6 |
| RAM | 32GB DDR5 6000 |
| Runtime | Docker, cgroup v2 unified |
| GPU stack | ROCm, `/dev/kfd` and `/dev/dri` passthrough |

This hardware has no NVIDIA MPS, no MIG, and no time slicing device plugin.
That absence is a constraint on the study and also the point of it: nearly all
published GPU sharing work assumes NVIDIA datacentre parts. See
`docs/RELATED_WORK.md`.

---

## Reproducing the CPU arm

Everything below runs on one machine. No cluster, no cloud.

### 1. Build the workload image

```bash
docker build -t rkube-stress:pinned experiments/cpu/
```

The base image is pinned to a Debian point release so the stress-ng version
cannot drift mid study.

### 2. Smoke test first

```bash
./experiments/cpu/smoke_test.sh
```

Takes about three minutes. It checks cgroup v2, the Docker cgroup driver, the
cgroup path resolution, and whether a solo container reserving 12 CPUs lands
at a delivery ratio near 1.0.

**Do not skip this.** The failure mode of a misresolved cgroup path is not an
error, it is a plausible looking number. A ratio of 0.0 or a ratio far above
1.0 means the measurement is wrong, and forty minutes of runs would produce
forty minutes of garbage.

### 3. Full run set

```bash
./experiments/cpu/run_all_cpu.sh
```

30 trials, roughly 45 minutes, unattended. Output lands in
`results/raw/cpu.csv` with a per trial log in `results/raw/cpu_run.log`.

### 4. Single trial, for debugging

```bash
./experiments/cpu/run_cpu.sh C 1
```

---

## Design

### Conditions

| ID | Target | Neighbours |
|---|---|---|
| A | `--cpus=12`, 12 workers | none |
| B | `--cpus=12`, 12 workers | 3 x `--cpus=4`, 8 workers each |
| C | `--cpus=12`, 12 workers | 3 x **no cpu limit**, 24 workers each |

Condition B saturates the machine exactly: 12 reserved for the target plus 12
capped across neighbours equals 24 logical CPUs. Condition C is the burstable
neighbour case from the paper, where the split is decided by cgroup weight
rather than quota. If the rKube gap reproduces anywhere, it reproduces in C.

### Trial timeline

```
t=0    neighbours launch, live 75s
t=5    target launches, lives 65s
t=8    t0 sample: usage_usec, wall clock
t=68   t1 sample: usage_usec, wall clock
t=70   target exits
t=75   neighbours exit
```

Neighbours bracket the target's entire lifetime, so the target never competes
against a partially warmed or already draining neighbour set. The 60s
measurement window sits inside the target's steady state and excludes 3s of
spin up.

### Primary metric

```
delivery_ratio = usage_usec_delta / (60s_in_usec * 12)
```

1.0 means the container received exactly what it reserved. Below 1.0 is the
gap.

### Why throttling is recorded separately

A ratio below 1.0 has two possible causes and they mean opposite things:

| Ratio | `nr_throttled` | Interpretation |
|---|---|---|
| < 1.0 | high | The quota is binding. The container asked for more than 12 and was capped. Working as designed |
| < 1.0 | near zero | The container wanted its 12 and did not get them. **This is the rKube gap** |

Reporting the ratio without the throttle counters would leave the two
indistinguishable.

### Interleaving

Trials run A, B, C, A, B, C rather than in blocks. A 9900X under sustained
load clocks down over forty minutes, so block ordering would confound
condition with thermal drift and make whichever condition ran last look worse.

### Warmup discard

Trial 1 of each condition is recorded but excluded at analysis time. The
discard is a documented analysis decision, not missing data.

---

## Layout

```
experiments/
  config.md            frozen parameters, do not edit mid study
  cpu/
    Dockerfile         pinned stress-ng workload image
    lib_cgroup.sh      cgroup v2 resolution and cpu.stat reading
    run_cpu.sh         one trial, appends one CSV row
    run_all_cpu.sh     full interleaved run set
    smoke_test.sh      pre flight validation
  gpu/                 pending
  mem/                 pending
results/raw/           CSVs, stress-ng yaml, run logs
analysis/              figures and summary stats
docs/                  method notes, related work
report/                the writeup
```

## CSV schema

`results/raw/cpu.csv`

| Column | Meaning |
|---|---|
| `condition` | A, B, or C |
| `trial` | 1 to 10. Trial 1 discarded at analysis |
| `timestamp` | ISO 8601, trial completion |
| `usage_delta_usec` | CPU microseconds consumed in the window |
| `wall_delta_usec` | Window length in microseconds |
| `reserved_cpus` | 12, constant, recorded for provenance |
| `delivery_ratio` | Primary metric |
| `nr_throttled` | Periods where the quota was hit |
| `throttled_usec` | Total microseconds parked by the quota |
| `bogo_ops` | stress-ng throughput, full 65s lifetime |
| `bogo_ops_per_sec` | stress-ng rate, full 65s lifetime |

**Window mismatch, declared:** the delivery ratio covers a clean 60s window.
Bogo ops covers the container's full 65s lifetime including spin up and drain.
The two are not aligned, which is why the ratio is primary. Do not compute
throughput per delivered CPU second across them.

---

## Not in scope

No fix is proposed. rKube's cpuset pinning solution is out of scope by
design. This study verifies whether a problem exists and forms a hypothesis
about why. It stops there.
