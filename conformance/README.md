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
