# zigfs

ZigFS data-plane service. This project owns the S3 API, object data, metadata,
transaction journal, indexes, recovery, and storage backends.

## Commands

```bash
zig build
zig build test
cp config.example.yaml config.yaml
zig build run
```

Zig 0.16.0 or newer is required.

ZigFS loads built-in defaults first and then applies `config.yaml`. Use
`--config <path>` to select another file. Command-line address and data-root
flags override YAML values.

The process remains in the foreground after initialization and listens on the
configured API and Metrics addresses. The first server milestone provides:

```text
GET /health/live
GET /health/ready
GET /metrics              (Metrics listener only)
```

S3 and Management routes currently return `501 Not Implemented` until their
handlers are connected to the object and metadata layers.
