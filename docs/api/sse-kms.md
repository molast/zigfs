# SSE-KMS and KMS backends

Security → SSE Configuration now reads and writes ZigFS through the Admin BFF.
Saving validates the settings and durably persists the configuration without
contacting the provider. Failed validation or persistence leaves the previous
configuration unchanged. Refresh reads configuration and the last enable-time
health result without network probing.

## Backends

| UI backend | Value | Key source |
| --- | --- | --- |
| Local filesystem | `local` | `<localKeyDirectory>/<key-id>.key`, a versioned JSON key record with Base64 key material; created with exclusive creation and configured permissions (decimal, default 384 = 0600). Missing keys are created for new writes, never for reads. Development/testing only. |
| Static single-key | `static` | `staticSecretKey`, Base64 encoding of exactly 32 bytes. All accepted key names refer to this key. Development/testing only. |
| HashiCorp Vault Transit | `vault` | POST `/v1/<mountPath>/encrypt/<key-id>` and `/decrypt/<key-id>`. The Vault ciphertext includes its key version. |
| HashiCorp Vault KV2 | `vault-kv2` | GET `/v1/<kvMount>/data/<keyPathPrefix>/<key-id>`. Provision the secret's `key` field with a Base64-encoded 32-byte key. ZigFS records `data.metadata.version` and reads that version on decrypt; the object data path never creates or overwrites Vault secrets. Explicit key management creates and rotates secrets with check-and-set. |

`/data/test` maps to `test/` inside the configured ZigFS data root, not the
operating system’s `/data/test`. Traversal, reserved `.zigfs` components and
symlinked directories are rejected in this namespace. Other absolute paths
continue to refer to the ZigFS server filesystem.

The Local key record contains `format_version`, `key_id`, `version`, `algorithm`,
`usage`, `status`, `description`, `metadata`, `created_at`, `rotated_at`, `created_by`,
`deletion_date`, `encrypted_key_material`, `nonce`, and `at_rest_protection`.
New keys use `AES_256`, `EncryptDecrypt`, `Enabled`, an empty nonce array and
`plaintext-dev-only`. Key material is randomly generated, Base64-encoded, and
not encrypted at rest in this development backend. Disabled/pending-deletion
keys are rejected, not silently replaced. No deletion or rotation scheduler is
introduced by these record fields.

Local enable-time verification uses a dedicated
`zigfs-internal-kms-probe.key` record for synthetic probes. Enabled keys, including this key, may also be explicitly selected for Bucket SSE-KMS.
It is not the platform default data key; its
creation time and key material are generated locally, with no scheduled deletion.

An empty default key selects `zigfs`. Key IDs are 1–256 ASCII letters, digits,
periods, underscores or hyphens; `.` and `..` are rejected. These are backend key
names, not AWS KMS ARNs. Vault mount/prefix values are relative paths without
traversal. An empty KV prefix is supported. Vault tokens and namespaces are sent
using `X-Vault-Token` and `X-Vault-Namespace`; redirects are not followed.

Vault TLS settings refer to files on the **ZigFS server**, not the browser or BFF.
CA verification is enabled by default; a custom CA and PEM client certificate/key
pair are supported. Skip verification explicitly disables certificate/hostname
verification. The configured timeout (1–300 seconds) applies per HTTP attempt;
retry count (0–10) retries transport errors, HTTP 429 and HTTP 5xx, not ordinary
4xx errors. An enable-time probe may involve multiple HTTP operations; configure
`ZIGFS_UPSTREAM_TIMEOUT` accordingly for slow remote backends.

Caching applies to KEKs for Local/Static/KV2 and decrypted data keys for Transit.
Entries are scoped by immutable profile and key/version (Transit also binds the
ciphertext and object identity), expire after the configured TTL and are bounded
by the configured capacity. Disabling cache performs a fresh key lookup for each
operation. Changing configuration clears the in-memory cache. Cache entries are
never persisted, and their key buffers are wiped on eviction/shutdown. Local
cache defaults off. Revocation at Vault takes effect after any cached key expires.

## API and UI

- ZigFS: `GET` / `PUT /_admin/v1/settings/kms` (requires `admin:*`).
- BFF: `GET` / `PUT /api/v1/settings/kms` (authenticated session, forwarded to ZigFS).
- PUT accepts the current form's camelCase fields; numeric form values are decimal
  strings. See `KMSConfig` in the management OpenAPI contract.
- Responses contain `configured`, `healthy`, `healthChecked`, `config`, `tokenConfigured`, and
  `staticSecretKeyConfigured`. Both secret strings are always empty in responses.
- A blank token/static secret preserves the previously configured secret when
  saving the same backend. Switching backend requires its own credentials.
- Invalid configuration returns 400; a provider/persistence failure returns 503.
  Error codes distinguish Vault DNS/connection/timeout/TLS/access/key lookup errors,
  local directory/key-file failures, configuration-read errors, and persistence errors.
  No request or error response includes Vault response bodies or credentials.
- Save/reset start disabled and become available after form interaction.
  After saving, all configuration fields remain editable, including the backend
  selector. Switching backends only changes the draft; clicking **Reconfigure KMS**
  validates and atomically updates the existing `xl.meta`. Reset restores the current configuration.
  Successful saves reset the action buttons; failed saves retain the editable draft.
  Status refresh remains available. There is no UI delete entry.

## S3 usage

Set a Bucket's encryption type to **SSE-KMS**, or send
`x-amz-server-side-encryption: aws:kms` on PUT/CopyObject/CreateMultipartUpload.
Optional `x-amz-server-side-encryption-aws-kms-key-id` selects a backend key name;
otherwise the configured default is used. The same fields work in signed POST
policies. Bucket `PutBucketEncryption` accepts `SSEAlgorithm=aws:kms` using the
platform default key; a separate per-bucket `KMSMasterKeyID` is not supported.
`BucketKeyEnabled=true`, encryption contexts, DSSE-KMS and SSE-C remain unsupported.

PUT, copy, multipart, HEAD, GET and ranges return `aws:kms` and the actual key ID
for KMS objects. SSE-S3 remains `AES256` and continues using the local server
master key. Enabling a bucket default affects new objects only. Disabling or
changing a default does not alter already stored objects.

KMS uses a random AES-256-GCM data key for each object, with the existing framed
object data format. Its wrapped key is bound to bucket/key/data generation;
there is no plaintext or SSE-S3 fallback on KMS failure. A GET unwrap failure
returns 503 before sending object headers/data. Multipart parts retain the
existing encrypted staging format, and the completed object uses the KMS profile
and key selected at initiation, including across configuration changes/restarts.

Identity/key restrictions and permission boundaries apply `kms:GenerateDataKey`
to writes and `kms:Decrypt` to reads/copy sources, with resource
`arn:aws:kms:::key/<key-id>`. Multipart completion requires both. Anonymous KMS
object reads are denied. Legacy owner-scoped credentials retain their existing
full access; this does not introduce an AWS KMS API or separate key-policy service.

## Persistence and deployment

Configuration and historical profiles are encrypted/authenticated with the ZigFS
server master key under `.zigfs/config/kms_config.json/` (`kms_config.json` is a directory).
A single `xl.meta` contains the current configuration and immutable historical
profiles. No separate profile directory is created. Local enable-time checks
create only the probe key; data keys are created on the first encryption request.
Existing data keys must be retained for decryption.
The file contains a binary AES-GCM envelope (12-byte nonce, 16-byte tag, raw ciphertext)
inside a ZigFS binary metadata container: `ZFKM` magic, little-endian version and
flags (u16 each), payload length (u32), SHA-256 checksum (32 bytes), then payload. Flags 2 identifies the binary envelope; legacy flags 1 JSON envelopes remain readable.
This follows the directory/object-metadata layout illustrated by RustFS, but is
not byte-compatible with RustFS XL2 erasure metadata.
Legacy binary configuration/profiles under `.zigfs/kms/` remain readable; new saves
use the new directory. Earlier encrypted `current.json`/profile files and simple `.json` key files
remain readable. Legacy raw 32-byte `.key` files also remain readable. Each object retains its original profile;
profiles are immutable and are not removed when switching backends. Back up these
files together with the existing master key, metadata, and object storage.
Historical Vault endpoints/tokens, KV versions, Transit key versions, and local
key files must remain available to read older objects. Updating the current
configuration does not rewrite historical profiles or rotate existing objects.
Local key JSON files contain Base64-encoded key bytes; retain their restricted permissions.

Object metadata minor version 6 stores the KMS envelope; multipart metadata minor
version 2 stores the selected profile/key. Existing object versions 0–5 and
multipart versions 0–1 remain readable. Older binaries cannot read new metadata;
back up data before upgrading and do not downgrade after new writes.

Native builds now require libcurl development headers/library (`brew install curl`
or the platform's libcurl development package). The ZigFS Docker builder installs
`curl-dev`/`pkgconf`; the runtime installs libcurl and CA certificates.

## Verification

Run `zig build test`, `go test ./...` in the BFF, and the web build/i18n checks.
After building ZigFS, run `python conformance/sse_kms.py` with boto3 installed.
This uses isolated Local/Static storage and a Vault HTTP contract fixture, real
TLS handshakes with a temporary CA and client certificate, SDK uploads/copies/
multipart/ranges, KV version pinning, profile changes, restart, cache expiry,
secret redaction and fail-closed checks. It does not replace testing against your
Vault deployment, policies, key configuration and certificate chain.

### Validation and activation

Saving or reconfiguring KMS only validates the configuration and writes xl.meta;
it does not contact Vault or create local keys. GET status is also network-free.
Vault Transit and KV2 require HTTPS unless the ZigFS process was started with
`ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS=true` (development only).
Enabling SSE-KMS for a bucket through Management or S3 requires KMS to have
been started successfully through Security. Object encryption and
decryption also require the relevant provider/key to work; there is no plaintext
fallback. Health is unknown after saving until start-time verification. On process restart, enabled KMS is automatically checked and restored.

### Starting KMS from Security

After saving, the overview shows Configured and unknown health. **Start KMS** opens
a confirmation dialog. Cancel sends no request; Confirm calls
`POST /api/v1/settings/kms/start` through the BFF to ZigFS
`POST /_admin/v1/settings/kms/start` (management authority required).
The startup intent is saved inside xl.meta, then the saved backend/default key is
verified. Unsaved form changes are not submitted. A successful check reports Running; failure reports Error
with a sanitized, persistent-in-process error detail and an error toast.
Refresh reads that state without making another provider request. Saving another
configuration clears the previous check/error. The startup intent survives process restarts: enabled KMS is automatically
verified and restored, while stopped KMS stays stopped. Failed automatic startup
reports Error without preventing the ZigFS management API from starting.
SSE-KMS reads/writes require a successful start after saving.
Once started, historical object profiles still select their original backends.
SSE-S3 and unencrypted objects are unaffected.

### Runtime actions and key management

The running overview exposes Restart KMS (repeats the start check), Clear Cache,
and Stop KMS. Stop clears cached material and blocks SSE-KMS reads/writes until
the next successful start. Start and Stop atomically persist the enabled flag in the existing encrypted
xl.meta. Clear Cache does not change that flag. These actions do not delete persisted keys.
The BFF forwards `POST settings/kms/stop` and `POST settings/kms/clear-cache`.

While running, `GET settings/kms/keys` lists metadata only; the UI paginates at
20 rows. `POST settings/kms/keys` accepts an optional display name, description
and `setAsDefault`; generated key IDs are independent of display names.
The default-key update writes the existing xl.meta and keeps KMS running.
Static mode provides read-only details. Local, Vault Transit and Vault KV2 support
creation, rotation, marking PendingDeletion, cancelling deletion, and immediate
deletion via `POST settings/kms/keys/action`.

Local rotation adds `previous_versions` to the JSON record. New envelopes pin
the local key version using the existing 68-byte versioned envelope format.
Earlier 60-byte local envelopes use version 1, so old objects remain readable.
Vault KV2 rotation uses check-and-set and retains Vault versions; Transit uses
its native rotate API. Provider retention policies must retain versions needed
by objects. Vault display names and lifecycle state are recorded inside encrypted
xl.meta; pending deletion is enforced by ZigFS, not by unrelated Vault clients.
The seven-day deletion date is metadata only; automatic deletion is not scheduled.
Immediate deletion requires PendingDeletion, destroys all key versions, and
retains a non-secret tombstone to prevent accidental regeneration. Restore is
available only before permanent deletion. These operations clear the KMS cache.

Keys management needs additional Vault permissions: Transit keys list/read/create,
rotate, config updates and delete; KV2 metadata list/read/delete and data read/write.
Object-only Vault tokens may successfully start KMS but cannot manage keys.
Existing-object rekey/rewrap jobs are not implemented; the UI explicitly shows
this capability as unavailable. Rotation itself preserves the old key versions.

Older configuration files without an enabled flag default to not started; start
KMS once to record the intended state. Failed startup retains the enabled flag
for retry on the next ZigFS restart. Saving/reconfiguring resets the flag to false.


### Bucket default key

Bucket Encryption supports selecting an enabled KMS key. The Management/BFF bucket configuration field `kms_key_id` is saved together with `encryption: "KMS"`; S3 uses `KMSMasterKeyID` inside `ApplyServerSideEncryptionByDefault`. IDs use ZigFS portable key names (ASCII letters, digits, `.`, `_`, `-`, up to 256 bytes); enabled health probe keys can also be explicitly selected. Empty IDs retain the backend-default behavior for existing clients.

New PUT, COPY, multipart uploads and browser POSTs inherit the bucket key when the request does not explicitly choose encryption. Explicit `aws:kms` without a key uses the backend default. SSE-S3/disabled configuration clears the bucket key. Unrelated bucket settings and service restarts preserve it; existing encrypted objects retain their recorded key.

Bucket metadata `ZFBK` is now version 1.7: the 88-byte header stores key length as little-endian u16 at offsets 82–83, with key bytes appended after tags. Older versions decode with an empty key ID.
