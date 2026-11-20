# ZigFS P2 diagnostics

P2 tools run locally, outside the realtime dashboard. They use actual allocator,
sanitizer, OS and debugger evidence. No Docker image or container is required.
Python 3, Zig 0.17, Clang and LLDB are used; macOS memory-map snapshots also need
`vmmap`. Missing tools, denied debugger access, unsupported runtimes and missing
symbols fail explicitly rather than generating example data.

## Build isolated diagnostics

From the repository root:

```sh
cd zigfs
zig build -Ddiagnostic-allocator=true -Dsanitize-c=full -p /tmp/zigfs-diagnostic
zig build memory-diagnostic-probe -p /tmp/zigfs-memory-probe
zig build thread-sanitizer-probe -p /tmp/zigfs-thread-probe
# Optional separate full-server TSan build:
zig build -Dsanitize-thread=true -p /tmp/zigfs-tsan
cd ..
```

`-Ddiagnostic-allocator=true` uses Zig 0.17 `std.heap.SafeAllocator`, the current
replacement for deprecated DebugAllocator, beneath Application telemetry. It
captures 16 stack frames and enables delayed write-after-free checks. Default
builds retain the SMP allocator. Only Debug/ReleaseSafe is accepted for this
option. These checks increase memory/CPU usage; do not use diagnostic binaries
as production benchmark baselines.

The server overrides Zig's debug-info allocator with `std.heap.smp_allocator`.
Zig 0.17 otherwise uses a global arena for DWARF unwinding scratch allocations;
frequent SafeAllocator stack captures can retain this memory despite a small
live Application heap. The override reclaims scratch allocations, is thread-safe,
and stays independent of SafeAllocator to avoid recursive stack collection.
The 16-frame allocation traces and write-after-free checks remain enabled.

Only Application allocator users are covered. libc, prebuilt libraries, startup
arenas and other allocator users are outside its scope. This does not guarantee
detection of all invalid reads or arbitrary pointer writes. Leak checking runs
on normal stack unwinding after Application teardown; SIGTERM, abort and other
termination paths do not guarantee deferred cleanup.

## Verify memory and sanitizer detection

```sh
python3 tools/diagnostics/check_memory.py --binary /tmp/zigfs-memory-probe/bin/memory-diagnostic-probe --output /tmp/zigfs-memory-new
python3 tools/diagnostics/check_thread.py --binary /tmp/zigfs-thread-probe/bin/thread-sanitizer-probe --output /tmp/zigfs-thread-new
python3 tools/diagnostics/sanitizers.py --output /tmp/zigfs-sanitizers-new
```

All output directories must be new. The memory probes cover normal freeing,
leaks, duplicate frees, writes after freeing and allocator-footer overwrites.
Both nonzero exit and expected diagnostic text are required for fault cases;
crashing for an unrelated reason does not pass. Tests run in separate processes,
with timeouts and OS core dumps disabled. No fault probe is linked into ZigFS,
ordinary unit tests or HTTP routes.

The C sanitizer matrix compiles each suite separately and exercises the real
host/process/filesystem telemetry bridges concurrently, followed by known faults:

| Capability | Actual coverage | macOS ARM64 verification | Linux |
| --- | --- | --- | --- |
| SafeAllocator | Zig Application allocations; four isolated fault controls | Passed | Ubuntu 24.04 ARM64 passed |
| ASan | C telemetry bridge plus UAF, double-free, buffer-overflow controls | Passed | Ubuntu 24.04 ARM64 passed |
| UBSan | C telemetry bridge plus signed-overflow control | Passed | Ubuntu 24.04 ARM64 passed |
| Zig C `sanitize-c=full` | C sources compiled by Zig; TLS dependency instrumentation must be checked separately | Diagnostic server build and S3 integration passed | Ubuntu 24.04 ARM64 build and S3 integration passed |
| TSan (Clang) | C bridge concurrency and deliberate C data race | Passed | Ubuntu 24.04 ARM64 passed |
| TSan (Zig) | Locked/racy Zig counters, plus full-server instrumented build | Controls and real S3 integration passed | Ubuntu 24.04 ARM64 controls and S3 integration passed |

Zig 0.17 has no universal Zig ASan switch. The C ASan suite is not a whole-server
ASan build. TSan passing tests is not proof of race freedom. Sanitizer suites do
not share a runtime; ASan and TSan are never enabled together. The compiled
instrumented binaries, compiler version, logs and support matrix remain in the
output directory. UBSan recovery is disabled; TSan errors are fatal for controls.

## Memory snapshots and native cores

```sh
python3 tools/diagnostics/snapshot.py --pid <pid> --binary /path/to/zigfs --output /tmp/memory-before-new
python3 tools/diagnostics/snapshot.py --pid <pid> --binary /path/to/zigfs --output /tmp/memory-after-new --compare /tmp/memory-before-new/report.json
# Optional allocator telemetry, read through BFF:
# Add --monitor http://127.0.0.1:9001/api/v1/monitoring
# Set ZIGFS_DIAGNOSTIC_COOKIE to the existing session cookie; it is not serialized.

# Captures writable/modified memory, including heap, and resumes the target:
python3 tools/diagnostics/dump.py --pid <pid> --binary /path/to/zigfs --style modified-memory --output /tmp/memory-core-new
# Launch a reproducer and capture it when it actually faults:
python3 tools/diagnostics/dump.py --binary /tmp/zigfs-memory-probe/bin/memory-diagnostic-probe --output /tmp/crash-new -- double-free
```

`snapshot.py` records OS region summaries (`vmmap` on macOS; `/proc` maps, status,
smaps_rollup on Linux) and optional real monitoring aggregates. It is not an
object graph or a raw heap dump. Telemetry comparisons require matching run IDs
and increasing timestamps; OS-only snapshots can be inspected but do not invent
allocator deltas. The operator must select the BFF for the same target instance.

`dump.py` produces a native LLDB core plus bounded thread frames, module UUIDs,
load/file addresses and executable SHA-256. Attach requires the supplied PID to
match the executable. It briefly pauses the target and detaches; crash mode
launches only the supplied reproducer and kills its own child after capture.
No global kernel core settings are changed. A normal process exit is not a crash.

Styles: `stack` (default, small; most heap omitted), `modified-memory` (writable
memory suitable for heap inspection), and `full` (all readable regions, possibly
several GiB). Default per-file budget is 1024 MiB; use `--max-mib` explicitly to
raise it, up to 16384. File limit failure is a failure, not a valid partial dump;
partial core files are deleted, while errors and stack metadata are retained.

Native core files can contain credentials and object data. Output directories
are private and files are restricted; keep them local and share only after
review. Core capture needs OS debugger permissions and is unsuitable during
latency measurements. LLDB format/style availability depends on the platform.
On macOS, crash stack cores and live modified-memory cores have been captured;
a crash core has also been reopened successfully for its backtrace.
Ubuntu 24.04 ARM64 also passed crash/live core capture, crash-core reloading,
and the file-budget failure / partial-file removal / resumed-target retry checks.

## Offline symbols

```sh
python3 tools/diagnostics/symbolize.py --binary /path/to/matching-binary --capture /tmp/crash-new/report.json --output /tmp/symbols-new
# Raw addresses are also accepted. File addresses need no slide:
python3 tools/diagnostics/symbolize.py --binary /path/to/matching-binary --address 0x100012340 --output /tmp/raw-symbols-new
# For runtime addresses, also supply --slide (runtime load minus file image base).
```

Capture-based symbolication refuses a mismatched binary hash. It resolves file
addresses offline without launching a process and reports unresolved symbols as
failure. Raw addresses can be verified with `--sha256`; without it, matching
binary identity cannot be established. Use each module's matching binary for
external frames. Missing source lines are reported as null; no symbol names or
source locations are guessed. ASLR slide applies only to raw runtime addresses.

## Sustained integrity and resource test

Use the single-target JSON format from `zigfs/bench/benchmark.py`; credentials
come from named environment variables. Prefer an isolated test instance.

```sh
python3 zigfs/bench/stress.py --targets /tmp/zigfs-target.json --output /tmp/stress-new --seconds 1800 --concurrency 4 --size 65536
```

The default 30-minute workload continuously PUT/GET/HEAD/DELETEs one isolated key
per worker, checks GET payloads, and cleans the random bucket. Maximum duration
is 24 hours, 32 workers, 16 MiB per object; namespace and histogram memory stay
bounded. The pause between cycles defaults to 100 ms. In-flight requests and
cleanup can extend wall time beyond the requested workload duration.

Add `--monitor <BFF monitoring URL>` for 10-second allowlisted resource samples;
use `ZIGFS_DIAGNOSTIC_COOKIE` or `--cookie-env` for authentication. Failed samples,
request errors, corrupt payloads, unexpected failures, interruption, or incomplete
cleanup produce a failed report and nonzero exit. SIGINT/SIGTERM requests stop
and cleanup; records explicitly distinguish interruption from successful duration.
A fresh connection is used per request. Quantiles are successful-request
histogram upper bounds, with overflow unavailable. Neither a short smoke run nor
a stable memory trace establishes long-term leak freedom.

## Complete isolated run and consolidated report

```sh
(cd zigfs-admin/server && go build -o /tmp/zigfs-monitor-admin ./cmd/admin)
python3 conformance/diagnostics_runtime.py \
  --zig-bin /tmp/zigfs-diagnostic/bin/zigfs \
  --admin-bin /tmp/zigfs-monitor-admin \
  --memory-probe /tmp/zigfs-memory-probe/bin/memory-diagnostic-probe \
  --thread-probe /tmp/zigfs-thread-probe/bin/thread-sanitizer-probe \
  --seconds 1800
```

This creates temporary services and credentials, runs probes and sanitizer
controls, captures before/after snapshots and native cores, validates workload
cleanup, and generates a report. Core capture occurs outside the workload. It
never connects to an existing deployment, loads `.env`, or mutates production
objects. Services are terminated on completion/failure. For a smoke test use
`--seconds 10`; reports retain the actual duration and never label it 30 minutes.
Use `--core-max-mib 4096` when a diagnostic workload needs a larger native core;
the default remains 1024 MiB and the accepted range is 1–16384 MiB. This only
changes the file budget, not the workload or the evidence pass criteria.

For the diagnostic RSS regression, add `--max-rss-growth-mib 64
--rss-warmup-seconds 30` to a run of at least 50 seconds (300 seconds recommended).
The check compares the peak RSS after warmup with the first post-warmup sample,
rejects missing/invalid samples or process restarts, and writes
`rss-regression.json`. Exceeding the budget fails the run even if RSS later drops.
This is a bounded regression check, not a guarantee of leak freedom.

To combine existing evidence, use repeated `--input` options:

```sh
python3 tools/diagnostics/report.py --output /tmp/combined-new \
  --input /tmp/zigfs-memory-new/report.json \
  --input /tmp/zigfs-thread-new/report.json \
  --input /tmp/zigfs-sanitizers-new/report.json \
  --input /tmp/memory-before-new/report.json \
  --input /tmp/crash-new/report.json \
  --input /tmp/symbols-new/report.json \
  --input /tmp/stress-new/report.json
```

Required evidence kinds are memory-probes, zig-tsan, sanitizers, memory-snapshot,
dump, symbolication and stress. Missing or failed evidence cannot pass. Reports
include scope, platform, source hashes, real workload duration, error counts,
latency bounds and resource min/max/deltas. Deltas are suppressed across restarts.
JSON summaries are copied into the bundle; sensitive native cores stay outside.
The reports are evidence summaries, not a security certification.

Run focused tooling tests with:

```sh
python3 -m unittest discover -s tools/diagnostics -p 'test_*.py' -v
python3 -B -m unittest discover -s conformance -p 'test_diagnostics_runtime.py' -v
```

## Ubuntu 24.04 ARM64 validation environment

Validated with Zig 0.17.0, Clang/LLDB 18, GDB 15.1 and perf 6.8.12 on the
OrbStack Linux 7.2.9 kernel. Results do not establish x86_64 or bare-metal support.
Use an isolated source copy and test data directory; do not reuse macOS build
caches or mount an existing deployment's data into the test environment.

Ubuntu dependencies (install Zig 0.17 separately, verifying its archive hash):

```sh
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils python3 clang libclang-rt-18-dev llvm-18 \
  lldb python3-lldb-18 gdb linux-tools-generic golang-go
export DEBUGINFOD_URLS=
```

`DEBUGINFOD_URLS=` disables Ubuntu's remote symbol downloads during bounded
diagnostic runs; local executable DWARF still provides source stacks. Otherwise
an unreachable debuginfod service can make a valid fault probe time out.
Clang's sanitizer runtimes are a separate package; installing only `clang` is
insufficient with `--no-install-recommends`.

For Docker, use `--cap-add SYS_PTRACE --cap-add PERFMON --security-opt
seccomp=unconfined` for the isolated diagnostic container. Ubuntu's `/usr/bin/perf`
wrapper may demand a package matching the VM kernel, which Ubuntu does not ship.
Select the installed executable instead (this run used
`/usr/lib/linux-tools-6.8.0-149/perf`), and put its directory first in `PATH`.
The selected perf must actually record samples; a successful exit with no
samples is rejected. P1 conformance produces signed GET traffic during CPU
capture and validates the returned payloads.

After the isolated builds above, run:

```sh
python3 -m unittest discover -s tools/monitoring -p 'test_*.py' -v
DEBUGINFOD_URLS= python3 conformance/monitoring_runtime.py \
  --zig-bin /tmp/zigfs-diagnostic/bin/zigfs \
  --admin-bin /tmp/zigfs-monitor-admin --p1 --persistence
DEBUGINFOD_URLS= python3 conformance/diagnostics_runtime.py \
  --zig-bin /tmp/zigfs-diagnostic/bin/zigfs \
  --admin-bin /tmp/zigfs-monitor-admin \
  --memory-probe /tmp/zigfs-memory-probe/bin/memory-diagnostic-probe \
  --thread-probe /tmp/zigfs-thread-probe/bin/thread-sanitizer-probe \
  --seconds 1800 --core-max-mib 4096
```

See `zigfs/docs/zigfs-monitor-plan.md` for the actual duration, results, resource
observations and interrupted-run accounting. A stopped VM/container without a
completed stress report cannot count as a passed long-duration run.
