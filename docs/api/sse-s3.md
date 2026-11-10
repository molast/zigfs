# SSE-S3 compatibility

ZigFS supports S3-managed server-side encryption using `AES256`. Admin's
SSE-S3 setting and the S3 bucket encryption API use the same persisted bucket
configuration. This is object data encryption, separate from credential-secret
protection.

## Supported behavior

- `GET /bucket?encryption`: returns `ServerSideEncryptionConfiguration` with
  `SSEAlgorithm` set to `AES256`. An unconfigured/disabled bucket returns HTTP 404
  `ServerSideEncryptionConfigurationNotFoundError`.
- `PUT /bucket?encryption`: accepts one AES256 rule and optional
  `BucketKeyEnabled=false`; returns HTTP 200. Invalid/unsupported algorithms,
  malformed XML, duplicate rules and checksum failures are rejected.
- `DELETE /bucket?encryption`: disables the default for future writes; returns
  HTTP 204. Existing encrypted objects remain encrypted and readable.
- These operations support SigV4 and presigned URLs, enforce
  `s3:GetEncryptionConfiguration` / `s3:PutEncryptionConfiguration` (including
  DELETE), and check `x-amz-expected-bucket-owner` when supplied.
- PUT, CopyObject, CreateMultipartUpload and signed POST-policy forms accept
  `x-amz-server-side-encryption: AES256`. An explicit request enables encryption
  even when the bucket default is disabled. Without the field/header, the
  destination bucket default applies. Copy decrypts the source and applies the
  destination setting; it does not blindly copy source encryption metadata.
- PUT, CopyObject, GET, HEAD and multipart responses report
  `x-amz-server-side-encryption: AES256` when the stored object/upload is
  encrypted. GET/HEAD must not send the encryption selection header. Range
  reads, object versions, checksums and multipart ETags retain their existing
  semantics. CORS exposes the encryption response header.
- A new multipart upload snapshots its encryption choice at initiation. Parts
  are encrypted before temporary-file writes, including UploadPartCopy. The
  snapshot survives bucket-default changes and server restarts. Completion
  decrypts the parts and streams them into the final encrypted object.

## Compatibility boundaries

ZigFS deliberately retains its **Disabled** setting. Unlike current AWS S3's
unconditional baseline encryption, a disabled bucket with no explicit AES256
request still stores new objects unencrypted. Enabling a default does not
retroactively encrypt existing objects; copy/rewrite them to encrypt them.
Therefore this is SSE-S3 API/workflow compatibility, not identical behavior to
every current AWS S3 default.

SSE-KMS is supported by the four configurable backends described in
[SSE-KMS](sse-kms.md). DSSE-KMS, encryption contexts, SSE-C, copy-source SSE-C
and `BucketKeyEnabled=true` remain unsupported. TLS is a separate transport
configuration.

## Storage and upgrades

Objects use AES-256-GCM authenticated frames with a random per-object data key,
wrapped by the persistent credential master key. Multipart staging uses a
per-generation key derived from that master key with HMAC-SHA256 and a distinct
multipart domain label; frame authentication binds the generation and index.
Preserve `.zigfs/system/credential-master.key` with the data backup. Losing or
replacing it makes encrypted data unreadable.

Multipart metadata payload `ZFMP` is now version **1.1**. Header byte 11 stores
0 (legacy/no snapshot), 1 (unencrypted), or 2 (encrypted); part record layout is
unchanged. New code reads 1.0 uploads, whose parts are plaintext and whose final
encryption follows the bucket default at completion as before. Old binaries
cannot read 1.1 upload metadata. Do not downgrade against an upgraded data root;
restore a matching pre-upgrade data/key backup if rollback is needed.

## Validation

Run `cd zigfs && zig build test && zig build`, then from the repository root:

```sh
python3 -m venv /tmp/zigfs-sse-sdk
/tmp/zigfs-sse-sdk/bin/pip install boto3
/tmp/zigfs-sse-sdk/bin/python conformance/sse_s3.py
```

The SDK runner creates a temporary data root, provisions isolated credentials,
checks bucket APIs, explicit/default encryption, copy, multipart/copy parts,
HEAD/GET/Range, POST policy, presigning, permissions, owner checks and rejected
KMS/SSE-C requests. It restarts the server between upload and completion and
checks temporary data files for the test plaintext. It does not use the running
user instance. Zig tests additionally cover authenticated corruption detection,
cross-frame reads, payload compatibility and both multipart snapshot values
across a default change and restart.
