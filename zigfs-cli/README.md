# ZigFS CLI

`zc` is the ZigFS command-line client. It provides local connection aliases and a signed S3 protocol client.
High-level file workflows and management operations are planned in later steps.

## Build and run

Run the build script to create a native ReleaseSafe executable in this directory.
The script can be invoked from any working directory. The native build requires
libcurl development headers/library (the same dependency used by ZigFS). This
step is verified on macOS with Zig 0.17.0 and libcurl 8.7.1.

```sh
./build.sh
./zc --help
./zc --version
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
`bucket` and `object` provide group help. The registry reserves bucket
list/create/remove/version, object list/copy/move/remove/stat/show/head, and the
legacy names `mb`, `rb`, `version`, `cp`, `mv`, `rm`, `stat`, `cat`, `head`, `ls`.
These reserved S3 entries are help-only: business execution returns exit code **7**,
and help explicitly says they are not implemented. Step 02 alias commands are available.

Use `--version` or `-V` for the CLI version. The former `zc version` behavior is
removed; that name is reserved for bucket versioning.

| Options | Current behavior |
| --- | --- |
| `-h`, `--help` | Root or selected command help; `help object copy` also works |
| `--format auto\|human\|json`, `--json` | Default auto currently produces human output; conflicting explicit formats fail |
| `--config FILE` | Select the local alias configuration file |
| `-H`, `--header NAME:VALUE` | Add a signed `x-amz-*` header to s3api; repeatable, before or after command names |
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
| `head-bucket` | Bucket, ExpectedBucketOwner |
| `get-bucket-location` | Bucket, ExpectedBucketOwner |
| `list-objects-v2` | Bucket, Prefix, Delimiter, ContinuationToken, StartAfter, MaxKeys (1–1000), EncodingType=url, FetchOwner, ExpectedBucketOwner, RequestPayer=requester |
| `head-object`, `get-object` | Bucket, Key, VersionId, Range, IfMatch, IfNoneMatch, IfModifiedSince, IfUnmodifiedSince, PartNumber, ChecksumMode=ENABLED, ExpectedBucketOwner, RequestPayer=requester |
| `put-object` | Bucket, Key, base64 Body or `--body FILE`, ContentType, CacheControl, ContentDisposition, ContentEncoding, ContentLanguage, Metadata, IfMatch, IfNoneMatch, ExpectedBucketOwner, RequestPayer=requester |

These are protocol bootstrap operations, not a claim that every AWS optional field
or server feature is supported. High-level `bucket`/`object`, `ls`, `mb`, `cp`, etc.
remain reserved until their own implementation steps. Temporary credentials and
`ZC_REGION` use the step-02 resolution rules. Per-request endpoint/region/lookup,
CA, insecure and timeout flags override saved values without changing the config.

`--input-json FILE|-` accepts at most 1 MiB. `--body` currently requires a regular
file; streaming stdin uploads will be added with the pipe/multipart workflow.
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
