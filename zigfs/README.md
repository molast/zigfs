# zigfs

0.1 Release Candidate: `v0.1.0-rc.1` (service version: `0.1.0`).

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
GET    /{bucket}?versions
GET    /{bucket}?versioning
PUT    /{bucket}?versioning
GET    /{bucket}?lifecycle
PUT    /{bucket}?lifecycle
DELETE /{bucket}?lifecycle
POST   /{bucket}?delete=
PUT    /{bucket}/{object}
GET    /{bucket}/{object}[?versionId=ID]
HEAD   /{bucket}/{object}[?versionId=ID]
DELETE /{bucket}/{object}[?versionId=ID]

POST   /{bucket}/{object}?uploads
PUT    /{bucket}/{object}?partNumber=N&uploadId=ID
GET    /{bucket}/{object}?uploadId=ID
POST   /{bucket}/{object}?uploadId=ID
DELETE /{bucket}/{object}?uploadId=ID
```

S3 endpoints use path-style requests and Signature V4 Header authentication. Object-level
GET, PUT and DELETE also accept Signature V4 Presigned Query authentication with a maximum
lifetime of seven days. DeleteObjects, single-range GetObject, the complete Multipart
lifecycle, and signed aws-chunked PutObject/UploadPart are supported, including all five
Flexible Checksum signed trailer variants. Interrupted fixed-length uploads fail without
publishing Object/Part data, and a canceled GetObject releases its read lease. Conditional
requests, temporary credentials, virtual-hosted-style requests, and S3 POST Policy uploads
are supported. Bucket Versioning, DeleteMarker, version-specific object operations,
ListObjectVersions, and the declared Lifecycle expiration subset are also supported.
The Lifecycle scanner interval is configured with `s3.lifecycle_scan_interval_seconds`.
Management authentication and business routes are available under
`/_admin/v1`; the Admin application is only a web client and does not own storage state.

Storage compatibility and release upgrade rules are documented in
`../docs/release/v1-release-candidate.md`.
