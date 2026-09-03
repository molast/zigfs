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
configured API and Metrics addresses. Implemented endpoints include:

```text
GET /health/live
GET /health/ready
GET /metrics              (Metrics listener only)

GET    /
PUT    /{bucket}
HEAD   /{bucket}
DELETE /{bucket}
GET    /{bucket}?list-type=2
PUT    /{bucket}/{object}
GET    /{bucket}/{object}
HEAD   /{bucket}/{object}
DELETE /{bucket}/{object}
```

S3 endpoints use path-style requests and Signature V4 Header authentication.
Multipart, Range, conditional requests, presigned URLs, temporary credentials,
virtual-hosted-style requests, and streaming chunk signatures are not yet
implemented. Management authentication endpoints are available; remaining
Management business routes return `501 Not Implemented`.
