# Frozen Experiment Configuration

Locked on 2026-08-16. Do not change mid study. If any value here changes,
every prior trial is invalidated and the run set restarts.

## Host

| Item | Value |
|---|---|
| OS | Fedora 43 |
| CPU | AMD Ryzen 9 9900X, 12 physical cores, 24 logical |
| GPU | AMD Radeon RX 9070 XT, 16GB GDDR6 |
| RAM | 32GB DDR5 6000 |
| Container runtime | Docker, cgroup v2 |
| GPU stack | ROCm passthrough via /dev/kfd and /dev/dri |

## CPU arm

| Parameter | Value | Rationale |
|---|---|---|
| Target reservation | `--cpus=12` | Half of 24 logical. Mirrors rKube's 12 of 22 ratio |
| Target workload | `stress-ng --cpu 12` | One worker per reserved CPU |
| Neighbor count | 3 containers | Enough to saturate the remaining 12 |
| Trials per condition | 10 | First discarded as warmup, 9 analysed |
| Measurement window | 60s steady state | Container lives 65s, first 3s excluded |
| Run order | Interleaved A/B/C | Controls for thermal drift across the set |

### Conditions

| ID | Target | Neighbors | Expectation |
|---|---|---|---|
| A | `--cpus=12` | none | delivery ratio near 1.0 |
| B | `--cpus=12` | 3 x `--cpus=4`, `--cpu 8` | near 1.0, cores exactly saturated |
| C | `--cpus=12` | 3 x no cpu limit, `--cpu 24` | below 1.0 if the rKube gap reproduces |

Condition C is the burstable neighbor case from the paper. Neighbors have no
`--cpus` ceiling, so cgroup weight rather than quota decides the split.

## Metrics

**Primary:** delivery ratio

```
delivery_ratio = usage_usec_delta / (12 * wall_usec_delta)
```

`usage_usec` is read from the target container's `cpu.stat` under cgroup v2.
A ratio of 1.0 means the container received exactly the 12 CPUs it reserved.
Below 1.0 is the gap.

**Secondary:**

| Metric | Source | Meaning |
|---|---|---|
| `nr_throttled` | `cpu.stat` | Periods where the quota was hit |
| `throttled_usec` | `cpu.stat` | Total time parked by the quota |
| bogo ops | stress-ng yaml | Application level throughput |

Throttling separates the two failure modes. A ratio below 1.0 with high
`nr_throttled` means the quota is the binding constraint. A ratio below 1.0
with near zero throttling means the container was starved by neighbors, which
is the rKube finding.

## Window mismatch, declared

The delivery ratio covers a clean 60s window starting 3s after container
launch. Bogo ops covers the container's full 65s lifetime including spin up
and drain. The two are not perfectly aligned. Ratio is primary for this
reason. Do not compute throughput per delivered CPU second across them.

## Memory arm

| Parameter | Value |
|---|---|
| Target | `--memory=8g`, LLM inference |
| Neighbors | `stress-ng --vm 4 --vm-bytes 3G`, uncapped |
| Watch | `memory.current`, `memory.max`, `memory.events` |

3G per worker rather than 4G keeps a 32GB host clear of swap. Swap would
contaminate the CPU numbers if arms overlap.

## GPU arm

| Parameter | Value |
|---|---|
| Model | Llama 3.1 8B |
| Prompt set | 20 fixed prompts, fixed seed, fixed num_predict |
| Conditions | solo, concurrent x2, partition attempt |
| Metrics | eval_count / eval_duration from the Ollama API |
| Sampling | `rocm-smi --showuse --showmemuse --json` every 500ms |

The partition attempt condition has no expected number. It records that no
flag, cgroup controller, or device plugin option expresses a fractional GPU
request on this stack. The failure is the result.
