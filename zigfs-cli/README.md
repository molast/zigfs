# ZigFS CLI

`zc` is the ZigFS command-line client. It provides local connection aliases and a signed S3 protocol client.
Bucket basics, paginated listings, single-object copy/move/delete, explicit batch deletion and multipart upload/resume/pipe are available. Recursive/multi-source transfers, unversioned bucket cleanup, presigned sharing and browser POST uploads are available; management workflows follow in later steps.

## Build and run

Run the build script to create a native ReleaseSafe executable in this directory
and install/update `/opt/homebrew/bin/zc`, so `zc` is available on PATH.
To use another existing writable directory, run
`ZC_INSTALL_DIR="$HOME/.local/bin" ./build.sh` and ensure that directory is on PATH.
The script can be invoked from any working directory. The native build requires
libcurl development headers/library (the same dependency used by ZigFS). This
step is verified on macOS with Zig 0.17.0 and libcurl 8.7.1.

```sh
./build.sh
zc --help
zc --version
```

For development and tests:

```sh
zig build
zig build run
zig build install
zig-out/bin/zc --version
zig build test
python3 tests/cli_smoke.py
python3 tests/alias_smoke.py
# Build the isolated-test server first: (cd ../zigfs && zig build)
python3 tests/s3api_integration.py
```

The command design reference is in [`../docs/zigfs-zc-cli-rustfs-reference.md`](../docs/zigfs-zc-cli-rustfs-reference.md).

## Step 01: available commands

```sh
zig-out/bin/zc
zig-out/bin/zc help
zig-out/bin/zc --version
zig-out/bin/zc bucket --help
zig-out/bin/zc help object copy
zig-out/bin/zc cp --help --json
```

Help, CLI version output and alias management are local. The step-03 `s3api`
operations below make signed network requests.
`bucket` and `object` provide group help. Bucket list/create/stat/location/remove,
object list/put/get/stat/show/head/copy and aliases `ls/mb/rb/put/get/cat/head/stat/cp`
and move/remove/remove-batch are available, including mv/rm. Bucket versioning
commands remain reserved: execution returns **7**.
Help identifies reserved commands.

Use `--version` or `-V` for the CLI version. The former `zc version` behavior is
removed; that name is reserved for bucket versioning.

| Options | Current behavior |
| --- | --- |
| `-h`, `--help` | Root or selected command help; `help object copy` also works |
| `--format auto\|human\|json`, `--json` | Default auto currently produces human output; conflicting explicit formats fail |
| `--config FILE` | Select the local alias configuration file |
| `-H`, `--header NAME:VALUE` | Add a signed `x-amz-*` header to S3 commands; repeatable, before or after command names |
| `--no-color`, `--no-progress` | Parsed and preserved; current commands emit neither colors nor progress |
| `-q`, `--quiet` | Suppresses human success output, preserves JSON and errors |
| `--debug` | Parsed and preserved for future handlers; no diagnostic events in offline help/version commands |
| `--` | Stops option parsing; subsequent tokens are command names or operands |

Global options work before or after command names. Short-option clusters such
as `-qh` are not supported. Unknown options and trailing help operands fail;
help does not hide invalid arguments. `--version` cannot accompany a command or
`--help`.

JSON successes go to stdout with `schema_version: 1`, `type` (`help` or `version`),
`status`, and `data`. JSON errors go only to stderr with `schema_version: 1`,
`type: "error"`, `status: "error"`, and `error.code`/`error.message`. Parse errors
honor a JSON selector anywhere before `--`, including conflicting format input.
Errors never include raw arguments, which may contain secrets.

Current exit codes: **0** success, **1** local I/O/general failure, **2** usage/configuration
error, **3** network/TLS/timeout or transient service failure, **4** permissions, **5** missing alias/input file, **6** conflict or locked
configuration, **7** unsupported/reserved command, **130** cancelled secret prompt.

The subprocess checks exercise the built binary, actual streams and exit codes;
they require Python 3 and no server, credentials, or network. The Zig unit tests
also cover parser behavior and structured output. Run from `zigfs-cli/`.

## Step 02: aliases and connection configuration

```sh
# The secret file must be owner-only on Unix (chmod 600).
./zc alias set local http://127.0.0.1:9000 ACCESS_KEY --secret-key-file ./secret.txt
./zc alias set remote https://s3.example.test ACCESS_KEY --secret-key-from-env MY_S3_SECRET \
  --region us-east-1 --bucket-lookup path --connect-timeout 10 --timeout 300
./zc alias list --json
./zc alias info local
./zc alias export local --output aliases.json
./zc --config ./test-config.toml alias import aliases.json
./zc alias remove remote
```

`alias set` replaces the complete entry, including settings and credentials; it
is not a partial update. Positional AK/SK remain supported for compatibility, but
file/environment input avoids putting the secret in shell history. With an AK
and no secret source, a human POSIX terminal prompts without echo; Ctrl+C restores
the terminal and cancels without writing. JSON mode and non-TTY execution never
prompt. Windows users must provide a secret file/environment source; the terminal
prompt is currently POSIX-only.

Omitting both AK/SK reads the complete `ZC_ACCESS_KEY_ID`, `ZC_SECRET_ACCESS_KEY`,
optional `ZC_SESSION_TOKEN` group. Explicit credentials never borrow an environment
session token. An explicit AK may use `--secret-key-from-env NAME` or
`--secret-key-file FILE` (mutually exclusive) and `--session-token TOKEN`.
Secret files contain one value, optionally ending in CR/LF, up to 4096 bytes after
trimming line endings; interior control characters are rejected.

Configuration selection is `--config FILE` > `ZC_CONFIG_FILE` >
`$XDG_CONFIG_HOME/zc/config.toml` > `~/.config/zc/config.toml`. Relative explicit
paths resolve against the current directory; XDG/HOME roots must be absolute.
Missing configuration reads as an empty list without creating files. Mutation
uses a persistent `.lock` file, an exclusive nonblocking advisory lock and atomic
replacement. Lock conflicts return 6 and can be retried. Read-only commands see
one complete configuration snapshot. Config files and exported files are created
with owner-only permissions on Unix; existing credential-bearing files with
broader permissions are rejected, as are final-component symlinks.

The version-1 TOML format supports `schema_version = 1` and `[[aliases]]` tables
with basic double-quoted strings, booleans and decimal integers. Comments and
blank lines are accepted; unsupported TOML syntax, unknown/duplicate fields,
duplicate names or unsupported schema versions are rejected before saving.
The writer normalizes ordering and formatting and does not preserve comments.
Configuration and import documents are bounded to 1 MiB and 1024 aliases.

Alias names start with a letter/digit and contain only letters, digits, `_` or
`-` (up to 64 bytes). Endpoints are HTTP(S) origins with an optional port/root
slash; userinfo, query, fragment and non-root paths are rejected.

| Setting | Default / behavior |
| --- | --- |
| `--region` | Explicit value > `ZC_REGION` > `us-east-1` when saving |
| `--signature` | Only `v4`; `v2` returns unsupported |
| `--bucket-lookup` | `path` (also `dns`, `auto`) |
| `--insecure` | Off; explicit alias setting disables TLS verification for that alias when connected later |
| `--ca-cert FILE` | Saves an absolute path to a readable file with PEM certificate markers |
| `--connect-timeout` / `--timeout` | 10 / 300 seconds; 1–86400, connect timeout ≤ total timeout |
| `--management-endpoint` | Optional separate HTTP(S) origin; no management token stored in this step |

This step validates and saves connection settings without making a request.
Certificate trust, TLS handshakes and remote credential validity are now checked
when using the step-03 HTTP client. `resolveConnection` defines runtime
precedence for that client: explicit overrides > environment > saved alias.
Credential groups replace one another atomically; resolution does not persist
overrides. `alias info` displays saved settings, not runtime environment values.

List/info and mutation results omit all credential values, including AK; info
reports only whether credentials/token are configured. `list --long` is accepted;
list currently always shows full non-secret connection settings. `--debug` never
echoes input arguments or credentials.

Exports are deterministic versioned JSON, not the terminal output envelope.
`--output FILE` refuses an existing file unless `--force` is given, and cannot
overwrite the active config or its lock. Exports omit AK/SK/token unless **both**
`--include-credentials --acknowledge-credentials` are supplied. Without an output
file the export document goes to stdout (also under `--quiet`). Treat explicit
credential exports as secrets. Other JSON results use the step-01 envelope.

Import validates the entire JSON document before replacing the config; conflicts
fail without partial changes unless `--replace` is specified. A redacted import
creates an alias with empty credentials; replacing with it clears the old
credentials, rather than silently merging secrets. Use `alias set` to supply
credentials afterward. Import containing credentials requires Unix owner-only
permissions. Import accepts a regular file, not stdin, in this step.

`tests/alias_smoke.py` requires Python 3.11+ (`tomllib`). It uses a temporary HOME,
XDG directory, fake credentials and no network. Checks include TOML round trips,
credential-source isolation, config-path precedence, permissions, deterministic
exports, import rollback on conflicts/errors, locks, symlink protection and POSIX
PTY prompt/cancellation. Run it against the installed binary with
`python3 tests/alias_smoke.py ./zc` after `./build.sh`.

## Step 03: HTTP/SigV4 and the S3 protocol entry

```sh
./zc s3api list-buckets local --json
./zc s3api create-bucket --generate-input-skeleton > create.json
./zc s3api create-bucket local --input-json create.json --json
./zc s3api put-object local --input-json object.json --body ./source.bin --yes --json
./zc s3api get-object local --input-json object.json --output ./saved.bin --json
./zc s3api get-object local --input-json object.json > ./raw-download.bin
./zc s3api list-objects-v2 local --input-json listing.json --json
```

Input examples:

```json
{"Bucket":"example-bucket","Key":"folder/item.bin"}
```

```json
{"Bucket":"example-bucket","Prefix":"folder/","MaxKeys":1000}
```

Only the following operation subsets are registered. `--generate-input-skeleton`
returns a minimal editable JSON request without reading aliases or contacting a
server; it is not a dump of every optional field. Operation help lists the supported
fields. Invalid types, unknown fields and unsupported combinations fail before HTTP.

| Operation | Supported input fields |
| --- | --- |
| `create-bucket` | Bucket; optional CreateBucketConfiguration containing only LocationConstraint. Omit that configuration for us-east-1. |
| `list-buckets` | Prefix, ContinuationToken, MaxBuckets (1–10000), BucketRegion |
| `create-multipart-upload` | Bucket, Key, ContentType/Encoding/Disposition/Language/CacheControl, Metadata, ExpectedBucketOwner |
| `upload-part` | Bucket, Key, UploadId, PartNumber (1–10000), base64 Body or --body FILE, ExpectedBucketOwner |
| `list-parts` | Bucket, Key, UploadId, PartNumberMarker, MaxParts (1–1000), ExpectedBucketOwner; one page |
| `list-multipart-uploads` | Bucket, Prefix, Delimiter, KeyMarker, UploadIdMarker, MaxUploads (1–1000), ExpectedBucketOwner; one page |
| `complete-multipart-upload` | Bucket, Key, UploadId, MultipartUpload={Parts:[{PartNumber,ETag}]}, IfMatch/IfNoneMatch (server-dependent), ExpectedBucketOwner |
| `abort-multipart-upload` | Bucket, Key, UploadId, ExpectedBucketOwner |
| `copy-object` | Bucket, Key, encoded CopySource, CopySourceIfMatch/IfNoneMatch/IfModifiedSince/IfUnmodifiedSince, MetadataDirective=COPY or REPLACE; replacement metadata/content fields; target IfMatch/IfNoneMatch, ExpectedBucketOwner, RequestPayer |
| `delete-object` | Bucket, Key, ExpectedBucketOwner, RequestPayer; no VersionId yet |
| `delete-objects` | Bucket, Delete={Objects:[{Key}],Quiet:false}, ExpectedBucketOwner, RequestPayer; 1–1000 unique keys, no versions |
| `get-bucket-versioning` | Bucket, ExpectedBucketOwner; high-level mutation guard |
| `delete-bucket` | Bucket, ExpectedBucketOwner; requires `--yes`, never retries |
| `head-bucket` | Bucket, ExpectedBucketOwner |
| `get-bucket-location` | Bucket, ExpectedBucketOwner |
| `list-objects-v2` | Bucket, Prefix, Delimiter, ContinuationToken, StartAfter, MaxKeys (1–1000), EncodingType=url, FetchOwner, ExpectedBucketOwner, RequestPayer=requester |
| `head-object`, `get-object` | Bucket, Key, VersionId, Range, IfMatch, IfNoneMatch, IfModifiedSince, IfUnmodifiedSince, PartNumber, ChecksumMode=ENABLED, ExpectedBucketOwner, RequestPayer=requester |
| `put-object` | Bucket, Key, base64 Body or `--body FILE`, ContentType, CacheControl, ContentDisposition, ContentEncoding, ContentLanguage, Metadata, IfMatch, IfNoneMatch, ChecksumAlgorithm=SHA256 (computed), ChecksumSHA256 (base64), ExpectedBucketOwner, RequestPayer=requester |

These are protocol bootstrap operations, not a claim that every AWS optional field
or server feature is supported. High-level commands share these protocol operations
(see steps 04–05 below). Temporary credentials and
`ZC_REGION` use the step-02 resolution rules. Per-request endpoint/region/lookup,
CA, insecure and timeout flags override saved values without changing the config.

`--input-json FILE|-` accepts at most 1 MiB. `--body` currently requires a regular
file; use the high-level `pipe` command for stdin multipart uploads.
Uploads hash and stream the same open file using bounded buffers. Do not modify the
source during upload; PUT is never retried automatically, even on HTTP 503. Its
`--yes` requirement acknowledges that writing may replace an existing object.
CreateBucket also uses PUT and is not automatically retried.

GetObject streams to stdout or to an owner-only temporary file. File output refuses
an existing destination and publishes by atomic link only after transfer success;
failure removes the temporary file. JSON mode requires `--output FILE` to keep
binary data out of the result envelope. A raw stdout download can contain partial
data after an interruption; it is not retried once bytes have been emitted.

SigV4 signs the exact encoded path, sorted query, normalized headers, payload hash
and session token. S3 keys preserve repeated slashes, dot segments, Unicode and
literal percent/plus characters. `--bucket-lookup auto` currently selects path
style; `dns` explicitly uses `BUCKET.ENDPOINT_HOST`. Certificate hostname validation
uses that host; dotted bucket names may require a suitable certificate.

Only `x-amz-*` custom headers are accepted. Host, Authorization, date, payload hash
and session token are client-owned; conflicting/duplicate headers are rejected.
Neither canonical requests nor authorization values are printed, including in
`--debug`. Server error messages are redacted; recognized error codes and sanitized
request IDs remain available for troubleshooting.

Transport uses linked libcurl, never a shell command or a credential-bearing curl
process. System certificate verification is enabled by default; `--ca-cert FILE`
loads a custom PEM trust source and `--insecure` is an explicit opt-out. Redirects
are never followed, and ambient proxy variables are ignored in this step.
`--connect-timeout` limits connection setup; `--timeout` bounds HTTP transfer,
retries and backoff together (local input/hash preparation precedes this deadline).
`--retry-attempts` is 1–5, default 3, and retries only transient GET/HEAD failures
with bounded exponential backoff. TLS verification, permission and malformed
response failures are not retried.

S3 response headers are bounded to 64 KiB and control XML bodies to 4 MiB;
GetObject content is streamed separately. The XML codec supports the S3 element/
namespace/entity subset, rejects DTD/external entities and malformed or unexpected
root elements, and imposes depth/node limits. JSON results have `type: "s3api"`;
`data` includes operation, HTTP status, request ID, attempt count, XML-derived
`result`, selected response headers and streamed byte count. XML scalar values
remain strings; Bucket/Contents/CommonPrefixes entries are arrays. Errors go to
stderr, with status/request ID/attempt count when a response was received.

List operations perform **one protocol request** and preserve IsTruncated and
continuation tokens. Automatic full pagination belongs to the step-04 high-level
commands. Do not interpret one successful s3api page as a complete listing.

`tests/s3api_integration.py` builds no services itself; it starts the supplied
ZigFS executable with a disposable data directory, synthetic credentials and a
loopback port. It verifies actual signed read/write, XML bucket creation in a
non-default region, a 12 MiB round trip, unusual keys, conditional errors, pages
and server-issued temporary credentials. An independent Python HTTP fixture checks
signatures, virtual-hosted addressing, retry counts, deadlines, redirect refusal,
response limits and partial-download cleanup. A local TLS fixture uses an ephemeral
OpenSSL certificate to test default rejection, custom CA trust, hostname mismatch
and explicit insecure mode. Those fixture results are separate from real ZigFS
results; no real AWS endpoint is used.

The integration suite requires Python 3.11+, OpenSSL with `-addext`, and permission
to bind local ports. To verify the ReleaseSafe artifact:

```sh
./build.sh
python3 tests/cli_smoke.py ./zc
python3 tests/alias_smoke.py ./zc
python3 tests/s3api_integration.py ./zc ../zigfs/zig-out/bin/zigfs
```

## Step 04: bucket basics and object listing

```sh
./zc mb local/example-bucket
./zc bucket stat local/example-bucket
./zc bucket location local/example-bucket
./zc ls local
./zc object list local/example-bucket --list-api v2
./zc ls local/example-bucket/path/ --recursive --page-size 100 --json
./zc rb local/example-bucket --dry-run
./zc rb local/example-bucket --yes
```

`bucket list ALIAS` and `object list ALIAS/BUCKET[/PREFIX]` automatically follow
all continuation tokens. `ls` selects the operation from its target. Object
listing uses delimiter `/` by default; `--recursive`/`-r` includes descendants.
`--prefix TEXT` is an alternative to a path prefix; combining both is rejected.
Keys preserve repeated slashes, dot segments, Unicode and literal percent signs.
`--page-size 1..1000` controls requests, not the total result count.
`--summarize` adds a human entry/page count (prefix entries count too).

List JSON is one document with `data.items` (each has `kind` and `entry`),
`count`, `pages`, and `complete:true`. Entry fields use S3 names; XML scalar
values such as Size remain strings. Human names are JSON-quoted to prevent
terminal control-character injection. Lists use an anonymous temporary disk
spool and one request arena per page; no results reach stdout until all pages
succeed. Disk space scales with output; memory does not scale with entries.
Repeated tokens, tokens above 64 KiB, missing object continuation tokens and
more than 100000 pages fail explicitly, with no partial success output.
Connection timeout applies per page (including retries), not to the entire list.

Create uses the resolved alias/environment/explicit region and omits the XML
location constraint for us-east-1. Stat checks HeadBucket access and reports
available headers; location reads GetBucketLocation. These non-list operations
currently retain the shared s3api response envelope.

Remove requires `--yes`; `--dry-run` only previews and does not contact the
server or guarantee access/existence. DeleteBucket checks emptiness atomically
on the server; the CLI never deletes contained objects. PUT and DELETE are not
automatically retried. `s3api delete-bucket` is also available with Bucket input
and `--yes`. Force cleanup, versioning/object-lock creation, ignore-existing
and ListObjects V1 flags are not yet available and are rejected.

Connection overrides match s3api: endpoint, region, bucket lookup, CA/insecure,
connect timeout, request timeout, retry count and signed x-amz headers.
The existing `tests/s3api_integration.py` now also covers real bucket lifecycle,
two-page object/prefix listing, filtering, aliases, dry-run, read-only credentials,
nonempty protection, plus independently signed bucket pagination, page-two
failure, repeated tokens and DELETE retry protection. No manual tests required.

## Step 05: single-object transfers and inspection

```sh
./zc put ./source.bin local/example-bucket/path/object.bin --checksum SHA256 \
  --content-type application/octet-stream --metadata source=cli
./zc stat local/example-bucket/path/object.bin --json
./zc get local/example-bucket/path/object.bin ./download.bin
./zc cp ./source.bin local/example-bucket/another.bin
./zc cp local/example-bucket/another.bin ./another.bin
./zc cat local/example-bucket/path/object.bin --offset 10 --length 20
./zc head local/example-bucket/path/object.bin --bytes 32
./zc head local/example-bucket/log.txt --lines 10
./zc put ./updated.bin local/example-bucket/path/object.bin --overwrite --yes
./zc get local/example-bucket/path/object.bin ./download.bin --overwrite --yes
```

Canonical commands are `object put/get/stat/show/head/copy`; `put/get/stat/cat/head/cp`
dispatch to the same handlers. Explicit object keys and file destinations are
required; no basename/directory inference. For `cp`, a leading saved alias identifies
a remote path; use `./`, `../` or an absolute path to force local interpretation.
Exactly one side is local in these examples. Same-alias remote copying/moving is
available in step 06; multipart and stdin `pipe` are in step 07. Recursion,
versions and multiple sources await subsequent steps.

Uploads default to `If-None-Match: *`, so concurrent creation cannot silently
overwrite data. `--overwrite --yes` permits replacement; combine it with
`--if-match ETAG` to guard replacement against changes. Download replacement uses
a temporary file and atomic rename only after the complete successful transfer
and any requested verification; failure leaves the existing destination intact.
Without overwrite, atomic publication also refuses a destination created during
the download. `--dry-run` previews put/get/cp without opening files or checking
remote existence/permissions.

Read options: `--range bytes=N-M`, or `--offset N` with optional `--length N`;
`--if-match`, `--if-none-match`, `--if-modified-since`, `--if-unmodified-since`.
Lengths must be positive; arithmetic overflow is rejected. Range requests retain
S3 semantics (for example an out-of-bounds range fails). `head` defaults to ten
lines; `--bytes N` uses a Range request. Line mode scans bounded chunks, emits the
first N newline-delimited lines, then consumes/discards the rest of the response
to detect transfer failures; it does not buffer an entire line or save bandwidth.

Uploads accept Content-Type/Encoding/Disposition/Language/Cache-Control and repeated
`--metadata KEY=VALUE` (duplicate keys rejected case-insensitively). Stat and file
transfer responses reuse the s3api envelope, now including metadata, Last-Modified,
Content-Range, SHA256 when returned, and `checksum_verified`. Arbitrary object
bytes go directly to stdout for cat/head/get-to-`-`, even under `--quiet`.
JSON reads require a file destination; raw streams may be partial on failure,
with diagnostics confined to stderr.

Checksum behavior:

- `put --checksum SHA256` computes the digest using bounded buffers and sends
  signed S3 checksum headers. Real ZigFS validates the upload.
- `get --checksum SHA256` requests the server checksum and verifies it before
  publishing. A missing checksum returns 7, a mismatch returns 1; neither replaces
  the destination. Retry resets both the temporary file and digest state.
- `get --checksum-sha256 HEX` accepts a trusted 64-character SHA256 digest and
  verifies the full download independently of server checksum availability.
- `stat --checksum SHA256` requests/reports the header; it cannot verify bytes.
  Partial downloads and stdout cannot use download checksum verification.
  Other algorithms are rejected until their implementation steps.

**ZigFS checksum responses:** GetObject/HeadObject with
`ChecksumMode=ENABLED` now return a base64 full-object `x-amz-checksum-sha256`
and `x-amz-checksum-type: FULL_OBJECT`. `get --checksum SHA256` verifies the
response before publishing the local file; `stat --checksum SHA256` reports it.
This also works for objects uploaded without an explicit checksum option.
Without ChecksumMode, the extra checksum headers are omitted. Range responses
omit the full-object checksum; partial downloads still cannot use CLI verification.

Contiguous objects use their stored plaintext digest. Segmented multipart objects
store a manifest digest internally, so checksum requests stream and hash the full
plaintext under the same read lease instead of exposing that manifest digest.
This uses bounded buffers, but adds one complete read before a GET response and
makes checksum-enabled HEAD proportional to object size for segmented objects.
No storage format changes are required. Real-server tests cover ordinary/empty
and multipart downloads; encrypted segmented/versioned reads are covered by
server tests. Independent HTTP fixtures retain missing/mismatched checksum,
interruption and atomic-file preservation coverage.

The integration suite covers 12 MiB binary data, zero bytes, lines longer than
64 KiB, Unicode/special keys, metadata, Range and ETag/date conditions, all aliases,
permissions, missing objects, no-clobber/explicit overwrite, checksum errors and
interrupted download preservation. These tests use only disposable local resources.

## Step 06: same-instance copy, move and deletion

```sh
./zc cp local/example-bucket/source local/example-bucket/destination
./zc cp local/example-bucket/source local/other-bucket/destination --dry-run
./zc cp local/example-bucket/source local/example-bucket/destination \
  --overwrite --yes --source-if-match '"SOURCE_ETAG"' --if-match '"TARGET_ETAG"'
./zc cp local/example-bucket/source local/example-bucket/replaced \
  --metadata-directive REPLACE --metadata origin=copy --content-type text/plain
./zc mv local/example-bucket/source local/example-bucket/moved --yes
./zc rm local/example-bucket/moved --dry-run
./zc rm local/example-bucket/moved --yes
./zc object remove-batch local/example-bucket --file delete.json --yes
```

`delete.json` uses this shape:
```json
{"Objects":[{"Key":"first"},{"Key":"folder/second"}],"Quiet":false}
```

Canonical commands are `object copy/move/remove/remove-batch`. Remote copy/move
require the same saved alias; distinct aliases are rejected even when their URLs
match. Cross-endpoint transfer remains out of scope. Local/remote `cp` keeps the
step-05 behavior. Remote source and destination must be different explicit keys.

Copy defaults to MetadataDirective=COPY and target If-None-Match=`*`.
Replacement requires `--overwrite --yes`; `--if-match` applies to the target.
Source conditions are separate: `--source-if-match`, `--source-if-none-match`,
`--source-if-modified-since`, `--source-if-unmodified-since`. Metadata and content
replacement options require `--metadata-directive REPLACE`; otherwise they fail
instead of being ignored. A 200 CopyObject response must contain CopyObjectResult
and a nonempty ETag. Embedded Error, missing results or transport failure never
trigger source deletion. Copy/DELETE/POST are never automatically retried.

Move requires `--yes`. It observes the source ETag, applies a copy-source condition,
confirms the copied destination ETag and rechecks source ETag/size/Last-Modified,
then deletes the source. A failure after copying reports `MOVE_INCOMPLETE`,
`copy_completed:true`, the failed phase and a sanitized cause, leaving the
destination in place. A failed delete response may mean an unknown deletion
outcome; inspect before retrying. **Move is not transactional:** the current
server lacks conditional DeleteObject. Concurrent writes can race the final
source check/delete, and identical ETag/size/date cannot identify every change.
Avoid concurrent source/destination writes or versioning changes during moves;
atomic/version-aware moves require future server support.

Copy, move, rm and remove-batch first call GetBucketVersioning and reject Enabled,
Suspended, unknown states or failed checks. Credentials therefore need permission
to read bucket versioning as well as the operation itself. This preflight is not
an atomic lock against a concurrent versioning change. No VersionId, DeleteMarker
handling, retention bypass or recursive deletion is exposed in this step.
The raw s3api operations retain normal S3 semantics for current-key deletion;
they do not perform the high-level versioning preflight.

Remove and remove-batch require `--yes`, or `--dry-run` for a local preview.
Missing single keys are successful idempotent deletions. Dry-run validates input
but does not check remote state or permissions. Batch `--file` accepts at most
1 MiB, 1–1000 unique Key objects and absent/false Quiet. Alternatively
`--keys-file` accepts a JSON array of strings. Quiet=true, VersionId, duplicate
keys and stdin are rejected. This legacy path handles up to 1000 keys; step 08
extends high-level deletion to larger, chunked inputs and recursive selections.
The raw s3api DeleteObjects operation remains limited to 1000 keys per request.

DeleteObjects sends escaped XML with a signed payload hash and Content-MD5.
Every requested key must have exactly one Deleted/Error acknowledgement. Any
per-key Error returns a nonzero exit even with HTTP 200, with sanitized per-key
results under `error.cause.error.result` for the high-level command (direct
s3api uses `error.result`). Server Message strings are omitted. Missing, duplicate
or unexpected acknowledgements report an unknown outcome; there is no blind retry.
Successful non-list mutation responses use the high-level command type with
shared s3api data; move reports separate copy/delete results.

Tests cover real same-instance copying and moving, escaped source keys, metadata
replacement, source/target conflicts, explicit confirmation/dry-run, permission
denial, single/missing-key deletion, 1000-key batches, file validation and rejection
of Enabled/Suspended buckets. Independent signed fixtures cover HTTP-200 copy
errors, missing ETag, concurrent-change detection, failed source deletion, batch
partial errors/missing acknowledgements and no retry after mutation failures.

## Step 07: multipart, resume and stdin

```sh
zc multipart create local/example-bucket/large.bin --content-type application/octet-stream
zc multipart upload-part local/example-bucket/large.bin --upload-id ID \
  --part-number 1 --body ./part-1.bin --yes
zc multipart parts local/example-bucket/large.bin --upload-id ID --page-size 100
zc multipart list local/example-bucket --prefix large --page-size 100
zc multipart complete local/example-bucket/large.bin --upload-id ID --file parts.json --yes
zc multipart abort local/example-bucket/large.bin --upload-id ID --yes

zc put ./large.bin local/example-bucket/large.bin --multipart-threshold 64MiB \
  --part-size 16MiB --state-file ./upload-state.json
# After a failed/interrupted upload, repeat with the same options and --resume.
zc put ./large.bin local/example-bucket/large.bin --multipart-threshold 64MiB \
  --part-size 16MiB --state-file ./upload-state.json --resume
cat ./large.bin | zc pipe local/example-bucket/from-stdin --part-size 16MiB
```

Complete input uses ascending, unique part numbers and exact ETags:

```json
{"Parts":[{"PartNumber":1,"ETag":"\"etag-from-upload-part\""}]}
```

The high-level create command creates only a pending upload, so it does not require
confirmation. Upload-part can replace a numbered part, complete can replace the
object, and abort discards pending parts; these require `--yes` or `--dry-run`.
The raw s3api mutation operations require `--yes` for all four writes, including
create. Complete requires 1–10000 sorted Parts; missing/unknown fields are rejected.
Each nonfinal part must satisfy the service's 5 MiB minimum; the final part can
be shorter, including an empty sole part. Manual upload-part rejects files over
5 GiB. Create preserves supported metadata/content fields; encryption, tagging,
flexible part checksums and upload-part-copy await their implementation steps.

`multipart list` and `parts` fetch all pages before emitting one JSON document
with `items`, `pages` and `complete`. Repeated markers, malformed replies or exceeding
16 MiB of aggregate encoded page results / 10000 pages fail without partial stdout.
These are explicit bounded-memory limits, distinct from the disk spool used by
bucket/object listing. The raw s3api list operations return one page only.

Regular-file `put` and local-to-remote `cp` switch to multipart at 64 MiB by default.
`--multipart-threshold` changes the threshold; `--part-size`, `--max-parts`,
`--state-file` or `--resume` explicitly select the multipart workflow.
Sizes accept bytes or KiB/MiB/GiB. Defaults are 16 MiB parts and 10000 maximum parts.
Part size must be 5 MiB–5 GiB; source size is limited to 5 TiB and the chosen part
count is checked before creating an upload. Uploads are sequential with bounded
buffers, and part bytes stream directly from file ranges. Current automatic
create metadata options are Content-Type and repeated --metadata; unsupported
advanced options fail before creating an upload.

**Conditional completion:** automatic multipart and pipe now send
`If-None-Match: *` by default, including new destinations. Explicit replacement
requires `--overwrite --yes`; add `--if-match '"ETag"'` to replace only an observed
object. Manual `multipart complete` accepts `--if-match` and `--if-none-match`
alongside `--yes`; without conditions it retains unconditional S3 completion.
ZigFS checks the condition and rechecks the observed object generation under the
publication lock. Existing targets, stale ETags or intervening writes return
412 PreconditionFailed, preserve the current object and leave parts pending.
A conditional replay cannot bypass the condition via a previous completion receipt.
Older servers that reject these headers fail explicitly; there is no unconditional
fallback. Failed completions still retain the `completing` checkpoint and are not
automatically retried; inspect/abort the pending upload before starting anew.

A checkpoint defaults to the resolved `SOURCE.zc-upload.json`; `--state-file`
selects another path. Files are atomically replaced with mode 0600, and a sibling
`.lock` uses a process lock to reject concurrent writers. Checkpoints contain
endpoint/region, a hashed access-key identity, source path/size/SHA256, part layout,
create metadata, publication conditions and confirmed ETags, but no credential values.
Changing the overwrite/condition policy rejects resume. Checkpoints made before
publication conditions were fingerprinted are also rejected; inspect and clean up
the old upload rather than bypassing this check. The full source and
each part are hashed in a single initial scan; every new upload part must match
that expected part digest before transmission, and the full file is rechecked
before Complete. Do not modify the source during upload.

Resume requires the same source, target, connection identity, metadata and layout.
It fetches ListParts and compares saved ordered parts against remote ETags and
sizes; ETags are treated as opaque identifiers, not assumed to be MD5. Confirmed
parts are skipped. A remote part whose successful response was lost is unconfirmed
locally and is reuploaded from the validated source. Changed, missing or inconsistent
confirmed parts fail instead of silently restarting. The same command with
`--resume` starts a new upload if no checkpoint exists.

Checkpoint phases are `creating`, `uploading`, `completing`, `completed`. The phase
is saved before Create and before Complete. Only `uploading` may resume:
a crash/lost response during Create may leave an unknown pending upload;
a lost Complete response may mean the final object already exists.
Neither is blindly retried. Inspect multipart list/parts and stat/get (with a
trusted expected SHA256) to resolve the outcome. Successful completion retains
the `completed` checkpoint; use a different state file for a new transfer, or
remove an old checkpoint only after confirming it is no longer needed.

Failures report `MULTIPART_INCOMPLETE`, phase, known UploadId, checkpoint path and
a sanitized cause. UploadPart, Create, Complete and Abort are not automatically
retried. A 200 Complete response containing Error or lacking an ETag is a failure,
not proof of publication. Pending parts are deliberately retained for inspection
and resume; use explicit `multipart abort ... --yes` to discard them.

`pipe` always uses multipart and cannot resume. It rejects --resume, --state-file
and --multipart-threshold. It reads stdin in 64 KiB chunks and spools only the current
part into an owner-only temporary file, reusing that file for each part. Disk usage
is at most one selected part; RAM never holds an entire part or stdin.
Empty input is supported. Exceeding maximum parts/total bytes fails with the known
UploadId; stdin cannot be replayed. Temporary files are removed on normal exit/error;
a forcibly killed process may leave its temporary file and a pending server upload.

Automated tests use real ZigFS for lifecycle, metadata, paginated upload/part lists,
12 MiB automatic upload, empty-file upload, empty/binary pipe and byte-for-byte
verification. A forwarding fault proxy keeps real storage and SigV4 verification
while losing part/complete responses: tests cover resume after an unacknowledged
part, changed source/layout/remote part, damaged checkpoint, concurrent checkpoint
lock, and refusal to retry an already-effective Complete. Independent signed
fixtures verify HTTP-200 embedded errors, missing ETags and mutation retry limits.


## Step 08: recursive and bulk workflows

```sh
# Trailing slash copies contents; without it, nest the source basename.
zc cp ./photos/ local/example-bucket/photos/ -r --exclude '*.tmp' --concurrency 2
zc cp ./one.txt ./two.txt local/example-bucket/incoming/ --summary
# The download root must already exist.
zc cp local/example-bucket/photos/ ./downloads/ -r --include '*.jpg'
zc mv local/example-bucket/old/ local/example-bucket/new/ -r --yes
zc rm local/example-bucket/tmp/ -r --dry-run
zc rm local/example-bucket/tmp/ -r --yes --continue-on-error
zc object remove-batch local/example-bucket --file keys.json --yes --summary
zc rb local/example-bucket --force --dry-run
zc rb local/example-bucket --force --yes
# Also abort pending multipart uploads before deleting objects and the bucket.
zc rb local/example-bucket --dangerous --yes
```

`cp/mv/rm` and their `object copy/move/remove` names accept recursive or multiple
sources. Multi-source destinations must be remote prefixes (bucket root or a
trailing slash) or existing local directories. A single nonrecursive source with
`--summary` retains exact target-file semantics. Moves remain same-alias
remote-to-remote; cross-endpoint copies and local moves are not supported.

Planning completes before mutations: all remote pages are consumed, sources and
targets validated, then jobs scheduled. A listing failure reports `completed: 0`
without partial stdout or writes. Plans are bounded to 100000 scanned entries/jobs,
64 MiB of accounted path/task/token payload, and depth 128; allocator/JSON/map
overhead is additional. `--page-size 1..1000` controls remote page size.
`--dry-run` returns concrete `jobs` and `remove_bucket`; it may read remote state,
but does not mutate it. `--fail-empty` returns exit 5 for an empty selection.

Repeatable `--include/--exclude GLOB` match relative paths with bytewise `*` and
`?`, including `/`; excludes win. Character classes, braces and age filters are
not supported. Local source symlinks/nonregular files, duplicate sources,
source/destination overlap and destination collisions are rejected. Recursive
local downloads always enforce portable ASCII path names, even without
`--portable-names`: non-ASCII names, traversal, empty segments, backslashes,
reserved names, invalid characters, trailing dots/spaces and case-insensitive
collisions are rejected. Local directory handles are pinned, symlinks refused,
and files published atomically. Keep local trees stable during traversal and
transfer; this does not provide a filesystem snapshot or transaction.

`--concurrency 1..32` defaults to 1. Jobs run in waves; failure stops later waves
unless `--continue-on-error` is set, while already-running jobs finish. The latter
does not turn failures into a successful exit. Ctrl+C stops scheduling and cancels
HTTP, returning 130; interrupted mutations may already have taken effect.
`--retry-attempts 1..5` defaults to 3 and supplies **N−1 retries shared by the
whole bulk command**, including planning reads. Only GET/HEAD retry; mutations
never retry automatically. Backoff defaults to 100 ms initial / 1600 ms maximum,
configurable using `--retry-initial-backoff-ms` and `--retry-max-backoff-ms`.

`--rate-limit BYTES|KiB|MiB|GiB` sets a conservative HTTP payload budget per second:
it is divided by twice the configured worker count for each worker's send/receive
direction. Unused slots are not redistributed; a positive rate must be at least
twice the worker count. Server-side copies have no client object payload to throttle.

Bulk operations emit one JSON summary (success on stdout, failure on stderr under
`error.summary`): `planned`, `completed`, `failed`, `not_started`, `filtered`,
`known_object_bytes`, `concurrency`, `retries_used`, `bucket_removed`, `errors`,
and `errors_omitted`. Counts refer to jobs, so a DeleteObjects chunk counts as one;
`delete_confirmed`, `delete_failed`, and `delete_outcome_unknown` count its keys.
Known object bytes are not network traffic and may be zero for nonrecursive
server-side copies. Errors retain at most 1000 entries / 8 MiB; individual details
above 1 MiB are replaced with an explicit limit message.

High-level `remove-batch` accepts up to 100000 unique keys / 64 MiB of input,
splitting requests into at most 1000 keys each. The JSON forms remain
`{"Objects":[{"Key":"a"}],"Quiet":false}` or `--keys-file` with a string array;
unknown fields, Quiet=true, versions and duplicates are rejected before execution.
Inputs of at most 1000 keys without explicit bulk controls retain the step 06
1 MiB limit and response shape. Use `--summary` for the bulk output contract.
**Historical step 08 validation scope:** the following force-cleanup restrictions
and test evidence describe the earlier implementation. Current `rb --force` and
`rm --versions` use the version-aware path described below under R01–R08; its
new behavior and supported options remain pending validation.

Large-batch and force-cleanup paths accept shared network options/custom signed
headers, but reject per-object options rather than silently ignoring them.

`rb --force --yes` removes objects and then the unversioned bucket. Pending
multipart uploads require `--dangerous` (which implies force) before any cleanup;
abort failures or object deletion failures prevent DeleteBucket. Enabled,
Suspended, unknown or unreadable versioning states are rejected. Avoid concurrent
writes/versioning changes during cleanup; preflight is not a lock. Version-aware
cleanup remains step 10.

Recursive copies/moves bind listing ETags to source read/copy conditions. The
step 06 nontransactional move limitation still applies. Automatic multipart
uploads default to conditional create-only completion; replacement requires
`--overwrite --yes`. Bulk mode rejects `--resume`, `--state-file`, per-object SHA256 and
range options. Default multipart checkpoint sidecars remain on disk; exclude
`*.zc-upload.json` in later scans when needed.

Automated coverage in `tests/s3api_integration.py` includes real recursive
roundtrips, filters and pagination, multi-source conflicts, path/symlink rejection,
moves/deletion, 1001-key chunking, invalid input, conditional multipart uploads, force cleanup, pending uploads
and versioning guards. Independent HTTP fixtures verify planning failures,
concurrency, shared retries, rate limits, interruption and partial-delete counts.

Conditional-completion regression coverage includes real If-Match success/failure,
missing/existing targets, retained parts after 412, concurrent create-only publishers,
automatic pipe overwrite protection and bulk multipart without overwrite. A server
application test injects a changed generation between observation and completion
and checks that publication rejects it without losing the pending upload.

## Step 09: presigned URLs and browser POST

```sh
zc share local/example-bucket/path/file.bin --expire 24h
zc object share local/example-bucket/path/file.bin --method HEAD
zc share local/example-bucket/path/new.bin --method PUT --expire 10m \
  --header 'Content-Type: application/octet-stream' --header 'If-None-Match: *'
zc share local/example-bucket/path/file.bin --method DELETE --expire 60s
zc share local/example-bucket/path/file.bin --version-id null
zc share local/example-bucket/large.bin --operation create-multipart-upload
zc share local/example-bucket/large.bin --operation upload-part --upload-id ID --part-number 1
zc share local/example-bucket/large.bin --operation list-parts --upload-id ID
zc share local/example-bucket/large.bin --operation complete-multipart-upload --upload-id ID
zc share local/example-bucket/large.bin --operation abort-multipart-upload --upload-id ID
```

`share` is the alias for `object share`. Generation is offline: it signs the
resolved endpoint, region, path/DNS bucket lookup, method, query and required
headers without checking permissions or object existence. The consumer must use
the returned method and headers exactly. GET/PUT/DELETE/HEAD are supported;
multipart `--operation` selects POST/PUT/GET/POST/DELETE respectively. UploadPart
requires a part number from 1 to 10000; all multipart operations except create
require UploadId. Complete consumers must supply the usual completion XML body.
`--version-id` is accepted for ordinary GET/HEAD/DELETE, not PUT or multipart.
Unsupported combinations are rejected before output.

Output is one JSON envelope (indented in human mode) with `data.url`, `method`,
`headers`, `expires_at` (Unix seconds), and `expires_in`. Header names are lower
case, whitespace normalized, and duplicates/reserved authentication headers
rejected. Literal key slashes, dot segments, Unicode and special characters retain
S3 encoding; `--bucket-lookup auto` uses path style. `--endpoint`, `--region`, and
`--bucket-lookup` override alias settings. The URL consumer controls its own TLS
settings. No URL is fetched during signing.

Expiry defaults to 1h; accept positive integer seconds or `s/m/h/d`, at most 7d.
Session credentials require their **actual** expiration via
`--credential-expiration UNIX_SECONDS` or `ZC_CREDENTIAL_EXPIRATION` (flag wins).
An already-expired credential or a requested lifetime extending beyond that time
is rejected, rather than silently shortened. Alias configuration does not yet
store expiry or refresh credentials, and opaque session tokens cannot reveal it;
the supplied timestamp must come from the credential issuer. The endpoint still
enforces actual credential expiry, revocation and access policy when a URL is used.

Share output intentionally contains bearer URLs or signed form credentials,
including the access-key identifier and temporary token when applicable. `--quiet`
still returns the requested capability. Secret access keys are never output;
errors omit input values. Treat generated output as private.

For POST, create a policy template (only `conditions`; expiration and authentication
conditions are generated):

```json
{"conditions":[["starts-with","$key","incoming/"],{"Content-Type":"application/octet-stream"},["content-length-range",0,16777216],{"success_action_status":"201"}]}
```

```sh
zc --json share post local/example-bucket --policy-file policy.json \
  --field key=incoming/file.bin --expire 15m > form.json
zc object post local/example-bucket --file ./file.bin --fields-file form.json --yes
```

Exact object conditions and `eq` supply fields automatically; `starts-with`
requires a matching `--field NAME=VALUE`. Key and exactly one content-length-range
condition are mandatory, and all fields must be covered. Supported fields are key,
Content-Type, success_action_status (200/201/204), Content-MD5,
x-amz-checksum-crc64nvme and x-amz-meta-*. Checksums, when supplied, must describe the
actual bytes; this command does not calculate them. Authentication fields and
bucket are supplied by the signer and cannot be overridden in the template.
Contradictory conditions, unknown fields, redirects and `${filename}` substitution
are rejected; this step uses literal keys. Templates/field files are bounded to
256 KiB, regular files without a final-component symlink. Templates have at most
100 conditions; encoded policy is at most 64 KiB. POST signatures share the URL
expiry and temporary-credential rules.

`share post` returns `data.url`, `method: POST`, `fields`, `expires_at`. Save the
whole envelope or its plain fields object for `object post --fields-file`.
Envelopes must match the resolved target URL, preventing accidental submission to
a different alias endpoint; plain fields intentionally use the specified target.
The form is submitted without an Authorization header; its own policy/signature
provides authorization. `--yes` confirms that the POST may replace an object.

`object post` sends actual multipart/form-data, fields first and file last, with a
random boundary and fixed safe filename. The file is read incrementally from an
open handle, with no whole-file memory buffer or temporary copy; keep it unchanged
during upload. Only regular files (up to 5 TiB) are accepted, no stdin. Responses
are bounded to 64 KiB of headers and 1 MiB of body. The command accepts only the
expected 200/201/204 success status; 201 must have PostResponse, a nonempty ETag and
the expected Key. It returns `http_status` and `bytes_uploaded`, never echoes form
fields or arbitrary server messages. TLS verification defaults on; `--ca-cert`,
`--insecure`, `--connect-timeout` and `--timeout` follow alias/request precedence.
Redirects are refused and POST never retries, including ambiguous disconnects.

This step also fixes two server gaps found by real tests: authenticated presigned
multipart create/list/abort accept the signed URL's unsigned-payload semantics,
and POST policies use their expiration instead of the ordinary 15-minute header
authentication age limit (future timestamps beyond clock skew remain rejected).

`tests/share_checks.py`, run inside `tests/s3api_integration.py`, independently
recomputes URL/policy HMACs and exercises real GET/PUT/HEAD/DELETE, all five multipart
operations, version selection, required headers, path encoding, temporary
credentials, tampering, POST 200/201/204, 8 MiB streaming and size conditions. It also
covers past/future/expired policy dates, DNS signing without network, redirects,
ambiguous disconnects, HTTP-200 errors and TLS verification. No external S3 account
or manual interaction is required; AWS interoperability is not claimed by these
local tests.


## 批量接入步骤 10–29（待验证）

本批次集中连接 100 项单机/旧协议 S3 操作和 114 条 Management 路由；已有步骤 01–09 的验收记录继续保留，新增命令及扩展字段统一待验证。此前批量接入执行过编译和静态检查；本轮缺口补全只修改逻辑、生成模型/清单及格式化，没有编译或测试。完整入口、管理端位置参数和限制见 [CLI-COVERAGE.md](CLI-COVERAGE.md)。后续集中验证，不再逐步重复跑全套测试。

```sh
# 配置写操作显式确认；--dry-run 校验输入并预览请求
zc bucket version enable local/data --yes
zc bucket version list local/data
zc bucket cors set local/data --file cors.json --yes
zc bucket lifecycle set local/data --file lifecycle.json --yes
zc object tag set local/data/a.txt --file tagging.json --yes
zc object get local/data/a.txt ./a.txt --version-id VERSION_ID
zc cp local/data/a.txt local/data/b.txt --version-id VERSION_ID
zc mv local/data/a.txt local/data/b.txt --version-id VERSION_ID --yes
zc rm local/data/a.txt --version-id VERSION_ID --yes
zc rm local/data/prefix/ --versions --recursive --dry-run
zc rb local/data --force --dry-run

# 配置文件是具体 payload；input-json 则是含 Bucket/Key 的完整 API 请求
zc s3api put-object-retention local --generate-input-skeleton
zc s3api put-object-retention local --input-json retention-request.json --yes
zc s3api list-object-versions local --input-json versions-request.json --all-pages
zc object list local/data --list-api v1
zc multipart copy-part local/data/source local/data/target --upload-id ID --part-number 1 --yes
zc sql local/data/data.csv --input-json select-request.json --output records.csv --yes
zc object annotation get local/data/a.txt --name NAME --output annotation.bin

# 远端扫描显式授权；列表失败、超限都会停止，不返回截断成功
zc find local/data/ --fallback --name report
zc tree local/data/ --fallback
zc du local/data/ --fallback
zc diff ./source/ local/data/prefix/ --fallback
zc mirror ./source/ local/data/prefix/ --fallback --dry-run
zc mirror ./source/ local/data/prefix/ --fallback --overwrite --remove --yes
zc ping local
zc ready local
zc completions zsh > ./zc-completions.zsh

# 管理认证与 S3 分离，先在 alias 配置 management_endpoint
zc admin auth login local --file login.json
zc admin auth session local
zc admin user list local
zc admin user update local USER_NAME --file user-update.json --yes
zc admin kms key action local --file key-action.json --yes
zc quota set local/data --max-bytes 1073741824 --yes
zc admin auth logout local --yes
```

管理请求文件和响应结构以仓库 Management OpenAPI 为准；各命令 `--help` 显示真实 HTTP 路径、位置参数和请求契约。登录会话按管理端点保存到配置旁 `.sessions/` 下的 0600 文件，检查服务端返回的到期时间；登录输出不打印 token。OIDC start/callback/refresh/logout 是显式协议步骤，登录跳转 URL 不由 CLI 自动打开。

新增 S3 命令读取固定模型，`--kebab-case-field VALUE` 映射请求字段；列表/结构/map 参数用 JSON 字符串，所有字段均可放完整 `--input-json` 文件。高层 `--file` 配置文件与 `--body` 原始二进制文件不同。新列表高层默认分页；原始 s3api 保持单页，需要时使用新增模型入口的 `--all-pages`。分页最多 10000 页 / 64 MiB；不支持的组合明确报错。

`anonymous set TARGET --mode download|upload|public|none` **替换或删除整份策略**。`ilm rule add/edit TARGET --id ID --file RULE_JSON`、`ilm rule remove TARGET --id ID` 读取后替换配置，没有服务端 CAS；初始化完整规则也可使用 `bucket lifecycle set`。`event get/set/clear` 使用 S3 通知，原生事件目标/订阅使用 `admin event-destination/event-subscription`，两者不混用。

新增扫描和 mirror 最多 100000 项 / 64 MiB；本地根目录须存在，拒绝符号链接和不安全对象路径。同实例使用 size+ETag 比较，本地/远端保守复制；复制阶段失败不会进入删除阶段。版本清理先取得完整计划；没有全局快照锁，并发写入可能导致最终 DeleteBucket 失败。`watch` 的服务端事件游标和客户端消费逻辑已接入，待验证；需新版服务端和管理端 Bearer 权限，不能将有限回放解释为无损投递。

Select 校验事件帧 CRC、处理 Records/Stats/Progress/End 和错误帧，仅把 Records 写入输出文件，收到完整 End 后才原子发布；annotation/torrent 也要求输出文件。服务器不支持某 API 时直接返回错误，不模拟归档/报表/ABAC 等能力。SHA256 可自动计算，其他上传校验算法需要提供对应值；SSE-C 传协议格式的 Base64 密钥/MD5。日期头使用 HTTP 日期，XML 时间使用 ISO 8601。

扩展字段优先通过 s3api 完整 JSON 使用。自动分片恢复、stdout/按行读取、校验下载与扩展字段的部分组合仍显式拒绝，未声称全部组合已实现。完整自测仍由 CLI 自动化完成；本轮延后执行不等于改成人工手工验收。

### 缺口补全用法（逻辑已接入，待验证）

```sh
zc tag set local/photos/a.jpg --tag project=demo --tag owner=team --yes
zc tag remove local/photos/a.jpg --key owner --yes
zc cors set local/photos cors.xml --yes
zc retention set governance 30d local/photos/a.jpg --yes
zc legalhold clear local/photos/a.jpg --yes
zc event add local/photos --id images --type queue --arn QUEUE_ARN --events s3:ObjectCreated:* --prefix images/ --yes
zc ilm rule export local/photos --output lifecycle.json
zc ilm rule import local/photos lifecycle.json --yes
zc tree local/photos --fallback --level 3
zc find local/photos --fallback --name '*.jpg' --newer 7d --min-size 1MiB
zc du local --fallback --versions
zc mirror ./photos local/photos --fallback --include '*.jpg' --watch --interval 30 --overwrite --yes
zc watch local/photos --events PUT,DELETE --cursor-file ./photos.cursor.json
zc admin user disable local alice --yes
zc admin group add-members local editors alice bob --yes
zc admin policy attach local readonly --user alice --yes
zc admin idp openid set local corporate --file provider.json --yes
zc admin kms key status local KEY_ID
zc admin kms key delete local KEY_ID --pending-window-days 7 --yes
```

CORS 接受 JSON/XML 文件或 `-` 标准输入；生命周期 export 输出原始配置，可直接 import。配置读改写没有 S3 CAS，需串行操作。原始模型 JSON 参数继续可用；OIDC 机密通过配置文件提供。

`find --name` 使用 `*`/`?` 通配，`--regex` 使用 POSIX ERE；`--newer/--older` 使用 s/m/h/d/y 相对时长，年按 365 天。`tree --level` 截断会给出 `view_truncated`。`du` 优先管理快照，只有显式 `--fallback` 才扫描对象；本地相对路径建议写 `./目录`。

`mirror --watch` 周期执行完整比较和同步，不是对象事件订阅。`watch` 消费实际成功对象事件，输出 JSON Lines；只对网络失败做有限重连，游标过期退出，绝不静默从最新位置跳过。检查点在整页输出后保存，崩溃恢复可能重复。详细权限、回放容量与重启语义见 [事件游标契约](../docs/api/object-watch.md)。

本轮未编译、未测试、未联调，现有 `zc` 和服务端二进制未重建；所有新增行为等待后续集中验证。

### 再次复扫后的接续补全（待验证）

```sh
zc retention clear local/photos/a.jpg --bypass --yes
zc mirror ./photos local/photos --endpoint https://storage.example --ca-cert ca.pem --fallback --overwrite --yes
zc s3api put-bucket-cors local --input-json - --yes < cors-request.json
zc admin kms key create local --name reports --description 'Report encryption' --set-as-default --yes
zc admin kms key status local
zc admin idp openid update local corporate --display-name Corporate --yes
```

retention bypass 由共享请求层生成对应字段；mirror 的复制与删除沿用扫描阶段的 S3 连接覆盖参数。模型化 `--input-json -`、配置 `--file -` 和管理 JSON 输入支持有界 stdin（4 MiB）；同次不能让 JSON 和 body 争用 stdin，也不能同时指定 file/input-json。凭据与会话文件不使用 stdin。

OIDC update 先读取现有 provider，仅覆盖用户给出的字段；JSON 与短选项可组合，短选项优先。机密经 JSON 提交，空 client_secret 保留服务器现值，脱敏占位符不能作为机密写回。该读改写无 CAS，请串行修改同一 provider。

管理便利命令的 help 已包含对应位置参数、选项与权限/执行边界。KMS key create 支持 name/description/set-as-default；status 无 ID 列出元数据与能力，有 ID 查询单项。KMS tag、list 分页、restart/roundtrip 以及 access-key provider 聚合过滤没有现成统一契约，仍属于上游参考范围；用户密钥使用 admin user access-key list。

本轮仅补逻辑、生成覆盖文档并格式化，所有新增及修正行为仍待验证，未重建二进制。

### 三项断点补全（待验证）

对象属性 `--all-pages` 的续页游标使用整数；未返回 ObjectParts 时保留已取得的属性页并结束。`retention set --default TARGET --file lock.json --yes`（以及 input-json / object-lock-configuration 形式）转发清理后的参数，文件采用 Bucket Object Lock 配置结构。

`watch --cursor-file PATH` 只接受真实文件路径，拒绝 `-`，并与 `--cursor` 互斥；如需字面文件名 `-`，写为 `./-`。本轮只补逻辑与文档并格式化，未编译、测试或联调。

### 响应元数据与生命周期往返（待验证）

旧请求和模型化请求共用自定义元数据响应头提取，忽略大小写匹配 `x-amz-meta-`，键名输出为小写；HTTP 临时响应中的头不会混入最终响应。模型化 HeadObject/GetObject 的结果同时提供 `data.result.Metadata` 和兼容旧消费者的 `data.metadata`，未返回元数据时为空对象。

`ilm rule list/export` 的文档格式为 Rules 加可选的独立设置，例如：

```json
{
  "Rules": [
    {"ID": "expire-temp", "Status": "Enabled", "Filter": {"Prefix": "tmp/"}, "Expiration": {"Days": 30}}
  ],
  "TransitionDefaultMinimumObjectSize": "varies_by_storage_class"
}
```

最小转换大小设置可为 `varies_by_storage_class` 或 `all_storage_classes_128K`。导入时 Rules 写入生命周期 XML 正文，独立设置写入对应请求头。规则增改删（仍有规则时）保留服务端返回的设置；删除最后一条规则仍删除整份配置。

import 兼容仅含 Rules 的旧文件、完整请求的 LifecycleConfiguration 包装和旧 CLI 结果 envelope；同时出现的内外层设置必须一致。旧文件未指定设置时不猜测值，由服务端采用其缺省行为。此导出格式用于 `ilm rule import`；直接使用 `bucket lifecycle set --file` 时文件仍须是纯 LifecycleConfiguration 正文，独立设置通过模型字段选项提供。

本轮只补上述字段处理逻辑和文档并格式化，没有编译、测试或联调，也不代表全部 CLI 已审查或验收。

## R01–R08 集中补全（待验证）

八项已补写逻辑，逐项记录见 [集中静态审查清单](../docs/zigfs-zc-cli-static-review.md)。本轮未编译、运行测试、执行 CLI 或联调；现有二进制未重建。

- `rm ALIAS/BUCKET/KEY --versions` 删除指定 Key 的版本和删除标记；加 `--recursive/-r` 按前缀。`rb ALIAS/BUCKET --force` 清理版本后删桶，存在未完成上传须另加 `--dangerous`。均要求 `--yes` 或 `--dry-run`。
- 版本清理支持 `--endpoint`、`--region`、`--bucket-lookup`、`--ca-cert`、`--insecure`、`--timeout`、`--connect-timeout`、`--page-size 1..1000`、`--bypass-governance-retention`（别名 `--bypass`）。绕过仅传给对象删除，不绕过合规模式或 legal hold。该路径串行、首错停止，拒绝 include/exclude、并发、重试/限速、header、summary、continue-on-error、fail-empty 等普通 bulk 参数。
- 历史删除和 mirror 在失败/取消时输出 `status=error`、原退出码及 `cause`，`progress` 包含已确认成功数量和阶段/目标，`completed`、`unstarted` 说明进度，`outcome_unknown` 保守标记已尝试但未确认成功的失败操作。没有自动回滚或不确定写重试。
- `du ALIAS --fallback` 进入服务扫描时完整消费 ListBuckets；逐桶释放临时数据，只保留统计。所有桶/对象/版本/上传/分片的扫描记录共用 100000 条和 64 MiB 序列化页面预算，桶数另限 10000，过滤不绕过预算；超限失败，预算不等于 RSS 上限。
- 未完成上传按分片总大小做 min/max-size 筛选；服务扫描保留多次 include/exclude。扫描错误保留原退出码和原始错误，附加失败阶段。diff/mirror 两端共享单次扫描预算。
- version enable/suspend、lock clear、legalhold enable/disable 拒绝不适用参数；通知每种动作单独校验参数。`event add --file` 可配 `--id`/`--type`，不能再配 arn/events/prefix/suffix，避免静默忽略。
