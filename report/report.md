# Do Container Resource Reservations Hold for GPU?

## A single node replication of the rKube CPU reservation gap, extended to GPU and memory on a consumer AMD stack

**Daniel Bayasgalan**
George Mason University, B.S. Computer Science
August 2026

---

## 1. Problem

Container orchestrators let a tenant declare what it needs. A Kubernetes pod
spec asks for a quantity of CPU, a quantity of memory, and a count of GPUs,
and the scheduler places the workload only where those quantities are
available. The tenant reasonably reads this as a reservation.

Liu et al. showed at SoCC 2021 that for CPU this reading is wrong. In *Mind
the Gap: Broken Promises of CPU Reservations in Containerized Multi tenant
Clouds*, a target application requesting 12 of 22 allocatable CPUs did not
receive 12 CPUs worth of delivered compute when its neighbours were
burstable. The gap between what was reserved and what arrived is the
phenomenon their paper names. Their proposed remedy, rKube, pins containers
to cpusets rather than relying on the CFS quota.

The CPU case is now well established. What is less clear is whether the same
promise breaks for the other two resources a container declares, and whether
it breaks in the same manner. That question has practical weight because the
workloads driving container adoption today are increasingly GPU bound
inference services, where the resource under contention is not the one rKube
studied.

This report asks: **does the reservation gap reproduce for GPU and memory, and
if so, is it the same failure?**

---

## 2. Hypothesis

**H1.** The CPU reservation gap reproduces on a single node Docker deployment
using cgroup v2 controls, without a Kubernetes control plane. If it does not,
the measurement apparatus is faulty and no conclusion about the other arms is
supportable.

**H2.** Memory reservations do not exhibit a proportional gap. Memory is
allocated in pages rather than in time slices, so a shortfall cannot be
partial. The reservation either holds or the allocation fails.

**H3.** GPU reservations exhibit neither a proportional gap nor a hard
failure, because on this stack there is no mechanism by which a fractional
GPU reservation can be expressed. The promise is absent rather than broken.

H1 functions as a calibration check. H2 and H3 are the contribution.

---

## 3. Related work

GPU sharing interference is a mature research area, and this study does not
claim to discover it. Prior work has established the phenomenon repeatedly
across NVIDIA hardware:

| Work | Contribution |
|---|---|
| iGniter (2022) | Quantified interference between co located DNN inference workloads under MPS, reporting latency increases from under one percent to roughly thirty five percent as co located workloads scaled from two to five |
| Orion (EuroSys 2024) | Interference aware fine grained GPU sharing for ML applications |
| Tally (2024) | Threadblock level kernel scheduling to mitigate co execution interference, motivated by inadequate performance isolation in existing mechanisms |
| Transparent GPU Sharing (NSDI 2023) | Container level GPU sharing for deep learning workloads |
| InferFair | Performance isolation for heterogeneous model serving, noting that spatial sharing yields performance unpredictability |
| MuxFlow, Guardian, LithOS, XSched, KubeShare | Further mechanisms for safe or efficient GPU multiplexing |

Two observations follow from this body of work.

First, the problem is confirmed. A study whose contribution was to
demonstrate that concurrent GPU workloads interfere would be redundant.

Second, and more usefully, this literature is almost entirely NVIDIA. The
mechanisms it studies, mitigates, or replaces are MPS, MIG, and CUDA stream
scheduling. Every mitigation named above presupposes a partitioning primitive
that exists on datacentre NVIDIA parts.

The AMD ROCm case is thinly covered. ROCm's documented isolation model
describes Docker namespaces granting or withholding access to whole GPUs, with
the finer grained option being exposure of a subset of devices rather than a
subset of one device. A July 2025 issue on the ROCm Kubernetes device plugin
repository records a user with eight MI300X GPUs limited to eight containers,
one per device, asking whether sharing or over allocation is possible at all.

This study therefore positions itself not as a demonstration that GPU
contention exists, but as a test of whether the rKube *mechanism story*
survives translation to a stack where the partitioning primitives are absent.

---

## 4. Method

### 4.1 Structure

Three arms, each holding the same shape as the rKube experiment: a target
container with a declared reservation, neighbour containers holding the
remainder, and a comparison of delivered performance against what was
reserved.

| Arm | Target reservation | Neighbours | Role |
|---|---|---|---|
| CPU | `--cpus=12` | stress-ng, capped and uncapped | Calibration |
| Memory | `--memory=8g` | stress-ng vm workers, uncapped | Contribution |
| GPU | whole device passthrough | second inference container | Contribution |

### 4.2 CPU arm

Three conditions, mirroring the paper's capped and burstable neighbour
distinction:

| ID | Target | Neighbours |
|---|---|---|
| A | `--cpus=12`, 12 workers | none |
| B | `--cpus=12`, 12 workers | 3 containers, `--cpus=4` each, 8 workers each |
| C | `--cpus=12`, 12 workers | 3 containers, no cpu limit, 24 workers each |

Condition B saturates the machine exactly. Condition C is the burstable case,
where the split between target and neighbours is decided by cgroup weight
rather than by quota. If the gap reproduces anywhere, it reproduces in C.

**Primary metric, delivery ratio:**

```
delivery_ratio = usage_usec_delta / (window_usec * reserved_cpus)
```

`usage_usec` is a monotonic counter read from the target container's
`cpu.stat` under cgroup v2. A ratio of 1.0 means the container received
exactly the twelve CPUs it reserved. Below 1.0 is the gap.

**Secondary metrics:** `nr_throttled` and `throttled_usec` from the same file,
and application throughput in bogo ops from stress-ng.

The throttle counters are not decoration. A delivery ratio below 1.0 has two
possible causes that mean opposite things:

| Ratio | `nr_throttled` | Interpretation |
|---|---|---|
| Below 1.0 | High | The quota is binding. The container asked for more than it reserved and was capped. The system is working as designed |
| Below 1.0 | Near zero | The container wanted its reservation and did not receive it. This is the rKube gap |

Reporting the ratio alone would leave these indistinguishable.

**Trial timeline.** Neighbours launch first and outlive the target, so the
target's entire lifetime sits inside a period of stable contention:

```
t=0    neighbours launch, live 75s
t=5    target launches, lives 65s
t=8    t0 sample
t=68   t1 sample
t=70   target exits
t=75   neighbours exit
```

The 60 second measurement window excludes three seconds of process spin up.

**Trial count and ordering.** Ten trials per condition, run interleaved as A,
B, C, A, B, C rather than in blocks. Block ordering would confound condition
with thermal drift over a forty five minute run, making whichever condition
ran last appear worse. Trial 1 of each condition is recorded but excluded at
analysis time as warmup.

### 4.3 Memory arm

Target container with `--memory=8g` running LLM inference, neighbours running
uncapped `stress-ng --vm` workers sized to keep the 32GB host clear of swap.
Observed values are `memory.current`, `memory.max`, and `memory.events` from
the target's cgroup.

The metric of interest is not a ratio. It is whether `memory.events` records
an `oom_kill`, and at what point in the neighbour pressure curve it does.

### 4.4 GPU arm

Three conditions:

| ID | Setup |
|---|---|
| Solo | One inference container, fixed prompt set, sequential |
| Concurrent | Two inference containers, same prompt set, launched together |
| Partition attempt | Attempt to grant one container a smaller share than the other |

Throughput is computed from `eval_count` divided by `eval_duration` as
returned by the Ollama API, giving tokens per second per container. Device
utilisation and VRAM occupancy are sampled from `rocm-smi` at 500ms
intervals.

The third condition has no expected numeric result. It records the outcome of
attempting to express a fractional GPU reservation through every mechanism
available on this stack. The failure, and its specific form, is the datum.

---

## 5. Setup

| Item | Value |
|---|---|
| OS | Fedora 43 |
| CPU | AMD Ryzen 9 9900X, 12 cores, 24 logical |
| GPU | AMD Radeon RX 9070 XT, 16GB GDDR6 |
| RAM | 32GB DDR5 6000 |
| Runtime | Docker, cgroup v2 unified hierarchy |
| GPU stack | ROCm, `/dev/kfd` and `/dev/dri` passthrough |
| Inference | Ollama serving Llama 3.1 8B |
| Workload image | Debian bookworm pinned point release, stress-ng |

Not available on this hardware: NVIDIA MPS, NVIDIA MIG, the NVIDIA Kubernetes
device plugin with time slicing, and any AMD equivalent of hardware
partitioning. AMD's partitioning modes exist on Instinct datacentre parts and
not on RDNA consumer cards.

Note on the CPU reservation semantics: `--cpus=12` sets a CFS quota of
1200000 microseconds per 100000 microsecond period. This is a time budget,
not a placement. The scheduler may satisfy it across any logical CPUs. It
does not pin the container to twelve cores, which is precisely the difference
between the default behaviour and what rKube proposes.

---

## 6. Results

> **[FILL: all numbers in this section come from `results/raw/`. Populate
> after the run set completes. Delete this note before delivery.]**

### 6.1 CPU arm

| Condition | Delivery ratio, mean | Std dev | Min | Max | `nr_throttled` mean | Bogo ops/s mean |
|---|---|---|---|---|---|---|
| A solo | [FILL] | [FILL] | [FILL] | [FILL] | [FILL] | [FILL] |
| B capped | [FILL] | [FILL] | [FILL] | [FILL] | [FILL] | [FILL] |
| C burstable | [FILL] | [FILL] | [FILL] | [FILL] | [FILL] | [FILL] |

n = 9 per condition after warmup discard.

**Figure 1.** Delivery ratio by condition, error bars showing one standard
deviation. [FILL]

[FILL: two to four sentences. State whether the ratio in condition C fell
below conditions A and B, by how much, and critically whether `nr_throttled`
in condition C was near zero. If the ratio dropped without throttling, the
rKube gap reproduced and the harness is validated. If the ratio held near 1.0
across all conditions, state that plainly: the gap did not reproduce at
Docker level on this hardware, and every claim in the GPU and memory arms
must be read against a harness that has not been positively validated.]

### 6.2 Memory arm

| Condition | `memory.current` peak | `memory.max` | `oom_kill` events |
|---|---|---|---|
| Solo | [FILL] | 8G | [FILL] |
| Under neighbour pressure | [FILL] | 8G | [FILL] |

[FILL: state whether the reservation held, and whether failure when it came
was proportional or terminal.]

### 6.3 GPU arm

| Condition | Tokens/s container 1 | Tokens/s container 2 | Peak VRAM | GPU utilisation |
|---|---|---|---|---|
| Solo | [FILL] | n/a | [FILL] | [FILL] |
| Concurrent | [FILL] | [FILL] | [FILL] | [FILL] |

**Figure 2.** Per container throughput, solo against concurrent. [FILL]

[FILL: state the aggregate throughput change and, separately, whether the two
concurrent containers degraded evenly or unevenly. These are different
findings. Even degradation means sharing is fair but uncontrollable. Uneven
degradation means it is neither.]

**Partition attempt.** The following mechanisms were examined for a means of
granting one container a smaller share of the single device than the other:

| Mechanism | Result |
|---|---|
| Docker `--cpus` analogue for GPU | [FILL: no such flag exists] |
| cgroup v2 controller for GPU | [FILL: enumerate `cgroup.controllers`, note absence] |
| ROCm Kubernetes device plugin | [FILL: allocation granularity of `amd.com/gpu`] |
| Environment variable device masking | [FILL: `ROCR_VISIBLE_DEVICES` behaviour with one device] |
| NVIDIA MPS, MIG, time slicing | Unavailable, not NVIDIA hardware |

[FILL: one paragraph on what this table means.]

---

## 7. Findings

> **[FILL: this section is written last, from the results above. The
> structure below is the argument the data is expected to support. Revise it
> to match what actually happened rather than forcing the numbers into it.]**

### 7.1 Three resources, two failure modes

The initial framing of this study anticipated three distinct failure modes,
one per resource. The results suggest a cleaner division into two.

**Divisible resources fail proportionally.** CPU time is compressible. A
container asking for twelve CPUs and receiving the equivalent of ten
continues to run, more slowly. The failure is graded, silent, and observable
only by comparing delivered against reserved. This is the rKube gap.

**Indivisible resources fail terminally.** Memory is allocated in pages, and
a page is either yours or it is not. There is no equivalent of running at
eighty percent of your memory reservation. The failure is binary, loud, and
observable as a process death.

GPU on this stack belongs to the second category, not the first. Despite
being marketed and scheduled as a shareable resource, the RX 9070 XT under
concurrent inference behaves as an indivisible one: containers contend for
VRAM until the ceiling is reached, at which point allocation fails rather
than degrading.

### 7.2 The promise is absent, not broken

rKube documents a broken promise: the reservation is expressible, is
accepted, and is then not honoured. The GPU case on this stack is
structurally different. There is no syntax in which a fractional GPU
reservation can be written. A container receives the whole device or none of
it.

This is a weaker claim than "GPU allocation is unfair" and a stronger one
than it appears. Unfairness is a property of a scheduler that could in
principle be fixed by a better scheduler. Inexpressibility is a property of
the interface, and no scheduler can allocate a quantity that the interface
cannot represent.

### 7.3 Why the resources differ

[FILL: this is the mechanism argument. See section 9 for the reasoning to
develop here.]

---

## 8. Limitations

These are constraints on what the study can support, stated without hedging.

1. **Single node, single host.** All results come from one machine. Nothing
   here generalises across hardware, and no claim about cluster behaviour is
   supportable from this data.

2. **Consumer AMD hardware.** The RX 9070 XT is an RDNA consumer part.
   Findings about the absence of partitioning primitives apply to this class
   of device. AMD Instinct parts expose partitioning modes not examined here.

3. **No NVIDIA comparison.** MPS and MIG are the mechanisms the published
   literature studies. Their absence here means this study cannot compare its
   AMD results against the NVIDIA baseline directly, only against published
   figures obtained on different hardware and different models.

4. **Docker level rather than Kubernetes level.** The cgroup mechanisms
   examined here are the ones Kubernetes ultimately configures, but scheduler
   placement decisions are not exercised. rKube's findings concern both.

5. **Trial count.** Nine analysed trials per CPU condition. Sufficient to
   report variance, insufficient for a strong statistical claim about small
   effects.

6. **SMT accounting.** The delivery ratio counts CPU time, not work
   completed. A delivered CPU second on a contended SMT sibling is worth less
   than one on an idle physical core. Bogo ops partially covers this gap but
   the two metrics span different windows and are not directly divisible.

7. **One model, one quantisation.** GPU results describe Llama 3.1 8B at a
   single quantisation. Larger models that do not fit two instances in 16GB
   would exhibit VRAM exhaustion sooner and might show a different curve.

8. **Window mismatch.** The delivery ratio covers a clean sixty second
   window. Throughput in bogo ops covers the container's full sixty five
   second lifetime. The denominators differ and the two should not be
   combined.

---

## 9. Future work

1. **NVIDIA replication.** Running the identical three arm design on hardware
   with MPS and MIG would separate what is a property of GPUs generally from
   what is a property of consumer AMD hardware specifically. This is the
   single highest value follow up and depends on access rather than on
   method.

2. **Kubernetes control plane.** Reproducing the memory and GPU arms under a
   real scheduler, rather than Docker level controls, would test whether the
   scheduler's accounting of a satisfied reservation diverges from the
   tenant's experience of one.

3. **Multiple devices.** The allocation granularity of `amd.com/gpu` cannot
   be examined with a single device. A multi GPU node would allow testing
   whether the device plugin's integer allocation model produces stranded
   capacity.

4. **Larger models.** Testing at a size where two instances cannot coexist in
   VRAM would characterise the failure boundary rather than only the region
   below it.

No remedy is proposed. rKube's cpuset pinning approach is out of scope by
design. This study verifies whether a problem exists and forms a hypothesis
about its mechanism. It stops there.

---

## References

Liu, L., Wang, H., Wang, A., Xiao, M., Cheng, Y., Chen, S. *Mind the Gap:
Broken Promises of CPU Reservations in Containerized Multi tenant Clouds.*
SoCC 2021.

Xu, F. et al. *iGniter: Interference Aware GPU Resource Provisioning for
Predictable DNN Inference in the Cloud.* arXiv:2211.01713.

Strati, F., Ma, X., Klimovic, A. *Orion: Interference Aware, Fine Grained GPU
Sharing for ML Applications.* EuroSys 2024.

*Tally: Non Intrusive Performance Isolation for Concurrent Deep Learning
Workloads.* arXiv:2410.07381.

Wu, B., Zhang, Z., Bai, Z., Liu, X., Jin, X. *Transparent GPU Sharing in
Container Clouds for Deep Learning Workloads.* NSDI 2023.

AMD ROCm Documentation. *GPU Isolation Techniques.*

ROCm k8s-device-plugin, GitHub issue 143, July 2025.

[FILL: add AdaGap, Future Generation Computer Systems, December 2025, if the
author list confirms it is the same S. Chen.]
