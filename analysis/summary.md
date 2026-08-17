## Delivery ratio and throughput, warmup discarded

| Condition | n | Ratio mean | SD | Min | Max | nr_throttled | Bogo ops/s | SD |
|---|---|---|---|---|---|---|---|---|
| A solo | 9 | 0.9974 | 0.0034 | 0.9882 | 0.9988 | 251.0 | 33223 | 167 |
| B capped neighbours | 9 | 0.8770 | 0.0255 | 0.8269 | 0.9025 | 0.0 | 22878 | 437 |
| C burstable neighbours | 9 | 0.4881 | 0.0233 | 0.4503 | 0.5182 | 0.0 | 12406 | 584 |

## Delivered time against delivered work, normalised to A

| Condition | Ratio rel. A | Throughput rel. A | Work per delivered usec |
|---|---|---|---|
| A solo | 1.000 | 1.000 | 1.000 |
| B capped neighbours | 0.879 | 0.689 | 0.783 |
| C burstable neighbours | 0.489 | 0.373 | 0.763 |

## Shortfall against reservation

- A solo: received 11.97 of 12 reserved CPUs, shortfall 0.3 percent
- B capped neighbours: received 10.52 of 12 reserved CPUs, shortfall 12.3 percent
- C burstable neighbours: received 5.86 of 12 reserved CPUs, shortfall 51.2 percent
