# Do Container Resource Reservations Hold for GPU?

**Daniel Bayasgalan**, George Mason University, B.S. Computer Science
August 2026

**Full scripts, raw data, figures, and reproduction steps:**
`github.com/DanBaya/rkube-gpu-replication`
This report gives the results and what they mean. Method detail, design
rationale, threats to validity, and the unaggregated per trial data are all in
the repository.

---

## 1. Problem and hypotheses

Containers declare what they need and the scheduler places them where it is
available. Tenants read this as a reservation. *Mind the Gap* (SoCC 2021)
showed that for CPU the reading is wrong: a container requesting 12 of 22
allocatable CPUs did not receive 12 CPUs of delivered compute when its
neighbours were burstable.

This study asks whether the same promise holds for GPU.

**H1.** The CPU gap reproduces at Docker level, without Kubernetes. This is a
calibration check. If the known result does not reproduce, the apparatus is
faulty and nothing else here is trustworthy.

**H2.** The GPU case fails differently. *This hypothesis was revised during
execution and the revision is reported in section 4.*

**H3.** Delivered CPU time understates the harm on an SMT host. This was not
part of the design and arose from the data.

---

## 2. Method

Single workstation: Fedora 43, kernel 7.1.5, Ryzen 9 9900X (12 cores, 24
logical), RX 9070 XT 16GB, 32GB DDR5, Docker 29.6.2, cgroup v2.

**CPU arm.** Target container reserves `--cpus=12` and runs 12 stress-ng
workers. Three conditions:

| ID | Neighbours |
|---|---|
| A | none |
| B | 3 containers, `--cpus=4` each, capped |
| C | 3 containers, no cpu limit, burstable |

Ten trials per condition, interleaved A/B/C to spread thermal drift, first
trial discarded as warmup, n=9 analysed. Sixty second measurement window
inside each container's lifetime.

**Metric.** delivery ratio = usage_usec delta divided by (window_usec x 12),
read from the container's `cpu.stat`. A ratio of 1.0 means the container
received exactly what it reserved.

`nr_throttled` is recorded alongside because it separates two opposite
meanings. A ratio below 1.0 with high throttling means the quota is binding and
the system is working. A ratio below 1.0 with zero throttling means the
container wanted its reservation and did not get it.

**GPU arm.** Prior work has established GPU interference thoroughly, almost all
of it on NVIDIA hardware using MPS and MIG, neither of which exists on this
stack. Rather than repeat it, the GPU arm asks a prior question: can a
fractional GPU reservation be expressed at all, and at which layer does the
ability disappear?

---

## 3. CPU results

n=9 per condition.

| Condition | Ratio mean | SD | Delivered of 12 CPUs | Shortfall | nr_throttled | Bogo ops/s |
|---|---|---|---|---|---|---|
| A solo | 0.9974 | 0.0034 | 11.97 | 0.3% | 251.0 | 33223 |
| B capped | 0.8770 | 0.0255 | 10.52 | 12.3% | **0** | 22878 |
| C burstable | 0.4881 | 0.0233 | 5.86 | **51.2%** | **0** | 12406 |

**H1 is supported.** The gap reproduces without a Kubernetes control plane.

**Zero throttling is the load bearing observation.** Condition A shows 251
throttle events, which is enforcement working correctly on a solo container
that occasionally exceeds its quota. Conditions B and C show zero across all
eighteen trials. The shortfall is not the container being capped for
overreaching. It is the container receiving less than it reserved while the
kernel recorded no enforcement action at all.

**Capped neighbours are not safe.** The design predicted condition B would be
well behaved, since the machine is exactly saturated and every neighbour has a
ceiling. It lost 12.3 percent, consistently, with no trial approaching 1.0.
This is the configuration an operator would adopt as the remedy.

### Delivered time against delivered work

Normalised to condition A:

| Condition | Ratio rel. A | Throughput rel. A | Work per delivered microsecond |
|---|---|---|---|
| B capped | 0.879 | 0.689 | 0.783 |
| C burstable | 0.489 | 0.373 | 0.763 |

**H3 is supported.** Throughput fell further than delivered time. Each
microsecond the container actually received produced roughly 76 to 78 percent
of the work the same microsecond produced in isolation.

The likely mechanism is SMT: 24 logical CPUs from 12 physical cores, and a
logical CPU whose sibling is saturated retires fewer instructions.
`usage_usec` counts scheduled time, not work, so it increments identically
either way.

**The delivery ratio is therefore a lower bound.** In condition C the container
lost 51.2 percent of its reserved time and roughly 63 percent of its
throughput. That the coefficient is stable across two very different contention
levels is consistent with core sharing rather than contention intensity, though
instructions retired were not measured directly.
