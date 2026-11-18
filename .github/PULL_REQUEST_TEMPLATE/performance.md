<!-- Replace prompts with measured evidence. Remove inapplicable items.
Use synthetic data and redact credentials from commands, configuration, and reports. -->

## Performance problem and change

<!-- Describe the affected operation, observed bottleneck, and how the implementation addresses it.
Link related issues and identify affected components. -->

## Benchmark setup

<!-- Use comparable conditions and record differences explicitly. Debug and diagnostic builds
are not representative production baselines. See zigfs/bench/README.md for benchmark guidance. -->

- Baseline and candidate versions / commits:
- Build modes, toolchain versions, and diagnostic settings:
- OS, CPU, memory, disk, filesystem, and available space:
- Deployment, container limits, network, TLS, and proxy settings:
- Client / benchmark tool versions and commands:
- Operations, object sizes / counts, concurrency, and multipart settings:
- Relevant configuration, warm-up, cache state, duration, and repetitions:

## Results

<!-- Include units, repeated measurements, variability, and relevant raw reports.
Use only applicable metrics, such as throughput, p95/p99 latency, CPU, RSS, or disk I/O.
Do not report only the best run. If measurements are unavailable, state that explicitly. -->

| Metric (unit) | Baseline | Candidate | Change |
| --- | --- | --- | --- |
| | | | |

## Correctness and regression validation

<!-- List commands and actual outcomes for affected unit/integration tests, compatibility,
authorization, checksums, partial failures, and crash recovery. Explain checks not run. -->

| Check or command | Result |
| --- | --- |
| | |

## Trade-offs and operational impact

<!-- Explain memory/CPU/I/O trade-offs, workloads that may regress, and any effects on durability,
consistency, API behavior, configuration, storage format, or rollback. State "None" where applicable. -->

## Checklist

<!-- Check completed items only; remove inapplicable items and explain meaningful omissions. -->

- [ ] Recorded reproducible commands and comparable benchmark conditions.
- [ ] Included measurement results and variability, or clearly identified missing evidence.
- [ ] Verified correctness and relevant failure/recovery paths, not just speed.
- [ ] Documented resource trade-offs and preserved authentication and durability guarantees.
- [ ] Ran relevant formatters, builds, tests, and `git diff --check`.
- [ ] Updated affected benchmark and operational documentation.
