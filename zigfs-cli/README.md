# ZigFS CLI

`zc` is the ZigFS command-line client. It provides local connection aliases and a signed S3 protocol client.
Bucket basics, paginated listings, single-object copy/move/delete, explicit batch deletion and multipart upload/resume/pipe are available. Recursive/multi-source transfers and unversioned bucket cleanup are available; management workflows follow in later steps.

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
