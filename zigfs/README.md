# zigfs

0.1 Release Candidate: `v0.1.0-rc.1` (service version: `0.1.0`).

ZigFS data-plane service. This project owns the S3 API, object data, metadata,
transaction journal, indexes, recovery, and storage backends.

## Docker build

The image uses Alpine for both the build and runtime stages. The builder downloads
the pinned Zig `0.17.0` toolchain and verifies its SHA-256 checksum. If network
access to `ziglang.org` is unavailable, place a Linux archive matching the
container architecture in this directory as `zig-toolchain.tar.xz`, or in the
nested `zigfs/` directory using its original name or `zig-toolchain.tar.xz`.
Any Zig version is accepted for a local archive; the Dockerfile will use it
automatically:

```sh
cp zig-aarch64-linux-0.17.0.tar.xz zig-toolchain.tar.xz
docker build -t zigfs:0.1.0 .
```

Local archives are checked with `ZIG_TOOLCHAIN_SHA256` when that build argument
is provided; otherwise their SHA-256 is printed during the build. Remote
downloads remain pinned to `ZIG_VERSION` and their fixed checksum.

For an internal mirror, pass its `/download`-style base URL:

```sh
docker build \
  --build-arg ZIG_DOWNLOAD_BASE_URL=https://mirror.example/zig/download \
  -t zigfs:0.1.0 .
```

## Commands

```bash
zig build
zig build test
cp ../.env.example ../.env
zig build run -- --env-file ../.env
```

Zig 0.17.0 or newer is required.

ZigFS loads built-in defaults first and then applies `.env`. Use
`--env-file <path>` to select another file. Command-line address and data-root
flags override process environment and `.env` values.

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
The Lifecycle scanner interval is configured with `ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS`.
The same interval advances the storage scanner by one of 16 namespace partitions;
see `../docs/storage-reclamation.md` for dangling data, incomplete MPU, and Trash/GC semantics.
Management authentication and business routes are available under
`/_admin/v1`; the Admin application is only a web client and does not own storage state.

Storage compatibility and release upgrade rules are documented in
`../docs/release/v1-release-candidate.md`.
