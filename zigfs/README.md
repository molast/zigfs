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
GET    /{bucket}?location=
DELETE /{bucket}
GET    /{bucket}?list-type=2
POST   /{bucket}?delete=
PUT    /{bucket}/{object}
GET    /{bucket}/{object}
HEAD   /{bucket}/{object}
DELETE /{bucket}/{object}

POST   /{bucket}/{object}?uploads
PUT    /{bucket}/{object}?partNumber=N&uploadId=ID
GET    /{bucket}/{object}?uploadId=ID
POST   /{bucket}/{object}?uploadId=ID
DELETE /{bucket}/{object}?uploadId=ID
```

S3 endpoints use path-style requests and Signature V4 Header authentication. Object-level
GET and PUT also accept Signature V4 Presigned Query authentication with a maximum lifetime
of seven days. DeleteObjects, single-range GetObject, the complete Multipart lifecycle, and
signed aws-chunked PutObject/UploadPart are supported, including the CRC64NVME signed trailer
variant. Interrupted fixed-length uploads fail without publishing Object/Part data, and a
canceled GetObject releases its read lease. Conditional requests, temporary credentials,
virtual-hosted-style requests, S3 POST Policy uploads, and non-CRC64NVME streaming trailer
checksums are not yet implemented. Management authentication endpoints are available;
remaining Management business routes return `501 Not Implemented`.
