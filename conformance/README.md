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
