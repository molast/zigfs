# System logs

The Admin **System logs** menu follows **Audit logs** at `/system-logs`.
It implements single-node application log browsing from
`docs/plans/rustfs-system-logs-design-v1.md`, using ZigFS as the source of truth.
Admin never accesses the data directory directly.

## Data and boundaries

- ZigFS JSON emission uses SystemLog schema `1.0`, UTC RFC 3339 milliseconds,
  uppercase levels, ZigFS version and its API address as the local instance ID.
- Source type is `application`; scoped logging supplies the component. The
  unscoped fallback is `server`. Request IDs and available error codes are
  extracted from internally generated diagnostic messages; unknown trace IDs,
  bucket/object context and source positions are omitted/null, not invented.
- The browser normalizes old Unix-second JSON records and text records. Unparsed
  records retain raw text and `metadata.parse_status=unparsed`; missing times
  display as an em dash and do not contribute to the time histogram.
- No audit records are used. Existing audit persistence/retention is unchanged.
  System files are `data/<configured-directory>/zigfs-*.log` (default `data/logs/`).
  Audit files use their own configured directory (default `data/audit-logs/`)
  and the `audit-*.log` prefix. Legacy audit files are imported once. Runtime log paths reject `.zigfs` components;
  queries only read owned runtime segments, never the audit files.
- Startup terminal status messages remain separate from persisted runtime logs.
- File/both modes use the configured ZigFS log directory. Both reads the file
  once, without re-ingesting stdout. Console-only logs are not buffered or
  persisted; the UI explains that only existing file history can be queried.
- Docker stdout/stderr, host system logs, collector and OTLP ingestion are not
  implemented. The source selector lists only the connected application source
  and sources actually present in returned records; it does not imply a Docker
  collector is running. Application file output inside Docker works normally.

## Query and UI

The BFF forwards `GET /api/v1/settings/logs/query` and `/download` to ZigFS.
Optional `from`/`to` are inclusive Unix seconds, overriding the saved access
range for this query only. Existing callers without bounds keep their behavior.

Queries retain the existing 1 MiB / 1024 segment scan bound. `truncated=true`
is displayed prominently as a persistent description. Filters, statistics,
histogram and pagination operate on the returned snapshot, **not** on an
unbounded total. Raw lines without parseable timestamps can be returned from
eligible files but do not have an invented event time.

The UI supports 5m/15m/1h/24h and custom local date ranges, level/component/source
and keyword filters (message, request ID, trace ID, instance and error), 5-second
polling, sorting, wrapping, 10/25/50/100-row pages and a details sheet containing
full message, normalized fields and raw content. Polls do not overlap, pause in
hidden tabs, stop on an error and are cleaned up on navigation. Custom ranges
are fixed snapshots and disable live mode. Results are replaced, not appended,
so polling does not duplicate records.

Download requests recheck the ZigFS download setting and export matching
normalized records as JSONL. A scan-limited download reports partial results.
Copy uses the raw log. Errors use the shared top-center toast, including when
the details sheet is open. The UI and APIs retain management-only access.

## Validation

- `cd zigfs && zig build && zig build test`
- `cd zigfs-admin/server && go test ./...`
- `cd zigfs-admin/web && node --test scripts/system-logs.test.mjs scripts/i18n.test.mjs`
- `cd zigfs-admin/web && pnpm run build`
- `python3 conformance/log_configuration.py`

Formatting changes affect new JSON records; old records do not require a
migration. Saved output, format, directory, retention and download permissions
continue to apply.

## Runtime diagnostic behavior

Successful HTTP requests (including log reads, settings reads and health checks)
are not emitted as runtime log records. The audit pipeline independently tracks
operations. Historical generic HTTP access-summary lines are excluded from the
System logs viewer/export so old polling traffic does not dominate diagnostics.

Caught transport, storage scanner, lifecycle and KMS startup failures record an
ERROR with error code, reporting source location and an available Zig error
return trace (`error.trace_kind=error_return`). Errors mapped to HTTP 5xx and
ordinary `std.log.err` calls record the current reporting-site stack, explicitly
marked `reporting_site`, rather than claiming it is the error origin. The build
retains debug symbols and enables error tracing. Stack capture is bounded to
16 KiB and serializes symbol resolution; JSON preserves multiline stack text.
Text output appends an escaped JSON diagnostic suffix (`\t@zigfs:`), keeping one
physical line per record while retaining a readable multiline stack in the UI.

The details sheet displays error code/type, source position and stack separately;
raw/normalized payloads are collapsible. Errors which were never passed through
the logging API, process kills and early fatal failures are not guaranteed to
appear in file logs. Missing historical stack traces are not reconstructed.
