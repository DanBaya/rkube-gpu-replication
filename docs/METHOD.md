# Method Notes

Design decisions and the reasoning behind them. Written during the build so
the Limitations section of the report has a factual basis rather than
reconstructed memory.

---

## Why measure `usage_usec` rather than `docker stats`

`docker stats` reports a smoothed percentage over a sampling interval it
controls. The smoothing window is not documented as stable and the value is
derived, not raw. `cpu.stat` under cgroup v2 is a monotonic counter maintained
by the kernel. Two reads and a subtraction give an exact figure for a window
whose bounds are known.

`docker stats` is fine for watching a run. It is not fine as a primary metric.

---

## Why the cgroup path is resolved rather than assumed

Docker on Fedora defaults to the systemd cgroup driver, which places container
cgroups at:

```
/sys/fs/cgroup/system.slice/docker-<full-id>.scope
```

The cgroupfs driver instead uses:

```
/sys/fs/cgroup/docker/<full-id>
```

Rootless Docker uses a user slice path. Hardcoding one of these and running on
a host configured differently does not error. `read_usage_usec` on a
nonexistent file returns empty, the delta becomes zero, and the delivery ratio
reads 0.0 for every trial. That looks like a dramatic finding rather than a
bug, which is exactly the kind of failure that survives into a writeup.

`resolve_cgroup` tries all known layouts and falls back to a bounded `find`.
If none resolve it aborts the trial loudly.

---

## Why the quota is 12 and not something rounder

The paper's target reserves 12 of 22 allocatable CPUs, roughly 55 percent. On
a 9900X with 24 logical CPUs, 12 is 50 percent. Close enough to preserve the
shape of the original setup while keeping the arithmetic clean.

The physical core count is 12 and SMT gives 24 logical. Reserving 12 does not
mean reserving 12 physical cores. `--cpus=12` sets a CFS quota of 1200000us
per 100000us period, which is a time budget, not a placement. The scheduler
may satisfy it across any threads. This is worth stating in the report because
a reader might otherwise assume core pinning, which is precisely what rKube
proposes and this study does not do.

---

## Why neighbours bracket the target

If neighbours and target start together, the target's first seconds run
against neighbours that are still spinning up, and its last seconds may run
against neighbours that have already exited. Both effects push the ratio
toward 1.0 and would mask a real gap.

Starting neighbours 5s early and ending them 5s late means the target's entire
lifetime sits inside a period of stable contention.

---

## Why bogo ops is secondary

stress-ng's yaml metrics cover the process lifetime. The delivery ratio covers
a 60s window inside that lifetime. The two denominators differ by the spin up
and drain periods.

Aligning them would require either stress-ng emitting windowed metrics, which
it does not do natively, or shortening the measurement window to match the
process, which reintroduces spin up contamination into the primary metric.

The ratio is what the study turns on. Bogo ops is corroboration: if the ratio
drops in condition C and throughput drops with it, the delivered CPU time
shortfall has an application level consequence rather than being an accounting
artefact.

---

## Threats to validity

| Threat | Mitigation | Residual risk |
|---|---|---|
| Thermal drift over a 45 min run | Interleaved condition order | Not eliminated, only spread evenly |
| First trial runs on a cold machine | Trial 1 discarded per condition | Assumes one trial is enough warmup |
| Background host processes | Nothing else running during collection | Not enforced programmatically |
| stress-ng version drift | Base image pinned to a Debian point release | None for this study |
| SMT effects on delivered work | Not controlled | A delivered CPU second on a shared SMT thread is worth less than one on an idle core. The ratio counts time, not work. Bogo ops partially covers this |
| Single machine, n=1 host | None available | Findings do not generalise across hardware and the report must say so |

---

## What would strengthen this that was not available

1. **NVIDIA hardware.** Would allow the MPS and MIG partitioning experiments
   that the published literature runs, making the GPU arm directly comparable
   to prior work rather than a documented absence.
2. **A multi node cluster.** rKube's findings concern the Kubernetes scheduler
   as well as the kernel. Docker level controls cover the cgroup mechanism but
   not scheduler placement decisions.
3. **More than one GPU.** The `amd.com/gpu: 1` device plugin allocation
   granularity cannot be examined with a single device.

Item 1 is an open question with GMU Office of Research Computing and should be
raised regardless of this study's outcome.
