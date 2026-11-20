# Native outbound transport

ZigFS uses this module for outbound KMS, webhooks and MQTT/WebSocket connections.
HTTP framing, DNS, TCP, deadlines and bounded streaming buffers are implemented
in Zig. Mbed TLS 3.6.8 is statically linked for TLS and client authentication.
No Go toolchain/runtime, libcurl, TLS DLL or helper process is required.
The CLI has its own native Zig transport and does not link this module.

## Build

Requires Zig 0.17.0. The Zig package manager downloads the hash-pinned
upstream Mbed TLS sources on first build. The revision and content hash are
pinned; the Zig build recipe and C source list are maintained in this module. Cached builds can run
offline; `zig build --fetch` can populate dependencies ahead of time.

The TLS library is compiled with Zig's C compiler for the requested target,
without CMake, Perl, Go or a platform package manager. PSA shared state uses
Mbed TLS's threading abstraction with pthread mutexes on POSIX and critical
sections on Windows. The TLS library is initialized once before concurrent use.
The first call initializes a process-lifetime Zig I/O executor; HTTP idle pools
are bounded to 32 connections, expired after 90 seconds when next inspected.
Each channel handle owns one connection and must be closed exactly once.

The Docker builder and runtime both use Alpine; the builder fetches TLS sources
and compiles them into `zigfs`. The runtime still needs a system CA bundle for
public HTTPS endpoints. The Go Admin BFF and gateway remain separate components.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and MBEDTLS-LICENSE for
third-party licensing. Mbed TLS is used under its Apache-2.0 option. Ship these
notices with binaries; the Dockerfile includes them. Updating the pinned TLS
version requires rebuilding and redistributing ZigFS to receive security fixes.

## Behavior and ownership

- `bridge.h` remains the public C ABI. All request buffers, strings and callback
  contexts are borrowed until return. Callbacks run on the original OS thread.
- HTTP/1.1 only. Redirects, automatic decompression and ambient proxies are
  disabled. Signed paths and query escaping are preserved.
- TLS 1.2/1.3, server hostname verification, system/custom roots, PEM client
  certificate/key pairs and explicit insecure mode are supported. Insecure mode
  retains SNI while disabling authentication. Private keys must be unencrypted.
- MQTT `strict` requires CA:TRUE unless leaf trust is explicitly enabled.
  `compat` accepts the library's default TLS 1.2/1.3 range. **TLS 1.0/1.1 are no
  longer supported**, including in compat mode; upgrade those broker endpoints.
- System roots are loaded once per process with Zig's platform trust loader.
  Custom CA material participates in pool identity, as do client certificate
  and key contents. Rotated material cannot select a previously authenticated
  connection. Restart the process to pick up changes to system trust roots.
- The connection deadline covers DNS, TCP and TLS. The total HTTP deadline covers
  transfer and throttling. Channel deadlines cover their complete lifetime.
  Pending network operations are polled for cancellation/progress, without
  resubmitting partially completed writes. Local callbacks are cooperative.
- HTTP responses are bounded by caller buffers. Webhook diagnostics can truncate
  while draining the response; KMS rejects overflow. Partial bodies are errors.
- The module uses its own process-lifetime I/O executor, not a caller's allocator
  or I/O instance. Every request/connection allocation has a corresponding free;
  only the bounded idle pool, system trust cache and executor are retained.

## Verification

```sh
(cd pkg/net-transport && zig build test http-probe && python3 tests/http_tls.py)
(cd pkg/net-transport && zig build check -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe)
(cd pkg/net-transport && zig build check -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe)
(cd zigfs && zig build test event-delivery-probe && zig build)
python3 conformance/event_delivery.py
python3 conformance/sse_kms.py  # requires boto3
```

Cross-link checks do not replace running on the target OS. The complete Windows
server has separate platform limitations; do not infer server support from a
successful standalone transport build. CLI tests exercise a separate transport.
