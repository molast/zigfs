# ZigFS SDK Conformance

This directory contains language-neutral V1 fixtures and executable adapters for the two Phase 7
target ecosystems:

- `typescript/`: Web Fetch, Web Streams and Web Crypto with Node.js as the headless host.
- `swift/`: Foundation URLSession, file streams, `UInt64` and CryptoKit.

Run the isolated end-to-end suite from the repository root:

```bash
./conformance/run.sh
```

The runner starts its own ZigFS instance, provisions a temporary full-access credential directly
through ZigFS Management API, exercises only S3/Data API from each adapter, then removes the complete
temporary data root. It does not require or start ZigFS Admin.

The public contract and required scenarios are documented in [docs/sdk/conformance.md](../docs/sdk/conformance.md).

## Managed user Access Keys

Build the ZigFS binary (`cd zigfs && zig build`) and an Admin test binary
(`cd zigfs-admin/server && go build -o /tmp/zigfs-admin ./cmd/admin`), then run
from the repository root:

```bash
python3 conformance/user_access_keys.py --admin-bin /tmp/zigfs-admin
```

This dependency-free regression starts isolated ZigFS/BFF services on loopback
ports with temporary data. It checks user-scoped CRUD, owner isolation, secret
redaction, TTL/token validation, actual SigV4 read/write permissions, disabling
users/keys, restart persistence, and safe user deletion/recreation. It also checks
IAM conditions (identity, IP, time, HTTPS, prefix, numeric limits, missing keys),
conditional Deny, policy variables, spoofed forwarded headers/query parameters,
and condition evaluation when consuming presigned URLs. It shuts down
both services and removes their temporary data when finished.

## Built-in HTTPS gateway

Build both services, then run the isolated standard-library-only suite:

```sh
(cd zigfs && zig build)
(cd zigfs-admin/server && go build -o /tmp/zigfs-admin-gateway ./cmd/admin)
python3 conformance/gateway_https.py --admin /tmp/zigfs-admin-gateway
```

The suite does not change hosts, system DNS, or CA trust. It connects to loopback
while preserving the configured TLS server name and HTTP Host. Unknown private
CA trust must fail; supplying that instance's public CA must succeed. It exercises
both HTTPS hosts, default and bucket-specific CORS, signed Unicode/encoded paths,
zero-byte objects, Range, conditional requests, HEAD, copy, multipart completion,
version-specific deletion, imported chains, invalid SAN rejection, candidate
rollback, persistent CA across restart, and disabling back to the HTTP endpoint.
All services and storage are temporary and cleaned up on completion.

The gateway module separately tests stream flushing, cancellation, certificate
renewal during downloads, and final-commit failure recovery with `go test -race`.

For an existing local Linux Admin image (Docker Desktop/OrbStack with
`host.docker.internal`), replace `--admin` with:

```sh
python3 conformance/gateway_https.py --admin-image zigfs-admin:local
```

This runs the actual gateway inside a Linux container, maps only loopback ports,
and recreates that container against the same temporary configuration mount.
ZigFS runs as an isolated native process on the host. The image must already be
present; the suite never pulls, publishes, or changes existing containers.
