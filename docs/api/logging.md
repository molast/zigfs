# Runtime log configuration

ZigFS owns runtime log configuration. Admin calls the BFF, which forwards to the
Management API; it never reads or writes the data directory directly.

## API

All routes require management authority (`admin:*`). BFF routes use `/api/v1`
instead of `/_admin/v1`.

| Method | Management path | Behavior |
| --- | --- | --- |
| GET | `/_admin/v1/settings/logs` | Read configuration, or defaults before first save |
| PUT | `/_admin/v1/settings/logs` | Validate, persist atomically and apply immediately |
| GET | `/_admin/v1/settings/logs/query` | Read bounded log content |
| GET | `/_admin/v1/settings/logs/download` | Read bounded content if downloads are enabled |

Example PUT body (omitted properties use defaults, rather than patching):

```json
{
  "level": "info",
  "format": "json",
  "output": "both",
  "directory": "logs",
  "retention": "7",
  "maxSize": "100",
  "sizeUnit": "MiB",
  "cleanup": "enabled",
  "downloads": "enabled",
  "range": "24h"
}
```

Defaults match this example except `output`, which defaults to `console`.
See the OpenAPI `LogConfig` schema for all options. UI labels KB/MB/GB correspond
to binary KiB/MiB/GiB (1024-based). Fractional positive sizes are supported,
with a converted range of 1 byte through 1 TiB.

## Persistence and paths

Configuration is atomically written with mode `0600` to
`data/.zigfs/config/log_config.json` and restored at startup. Saving takes effect
without restarting. Invalid stored configuration causes initialization to fail
instead of silently discarding it.

The directory is relative to the configured ZigFS data root: `logs` means
`data/logs`. Blank input becomes `logs`. Absolute paths, `.`/`..`, empty path
components, `.zigfs` components and symlink components are rejected. Components
accept ASCII letters, numbers, dots, underscores and hyphens, with a total path
limit of 512 bytes. Saving checks directory writability before committing.

## Output and retention

Levels are trace/debug/info/warn/error/off. Zig has no separate trace emission
level, so trace currently includes the same messages as debug. JSON records have
Unix-second `timestamp`, `level`, `scope` and `message`; text records contain the
same fields on one line. Console output writes stderr; file/both writes mode
`0600` segments named `zigfs-{unix_seconds}-{random_id}.log`. Console-only output
is not captured for later queries. Early initialization logs use stderr before
the configured logger is installed.

Segments rotate before the next record would exceed the configured size. A
single record is never split, so an oversized record can exceed the limit;
message text is bounded to 32 KiB before encoding. File-output failures produce
a fallback stderr error without recursive logging.

Enabled cleanup removes expired owned segments by modification time, at save,
on log activity and on a background interval of 60 seconds. `forever` or
disabled cleanup prevents deletion. Only matching regular log segment files in
the currently configured directory are eligible. Changing directories retains
previous directories and their contents; unrelated files are never cleaned up.

## Query and download

Both return JSON `{ "content": "...", "truncated": false, "range": "24h" }`.
The Admin UI converts downloaded content into a `zigfs.log` attachment. Disabled
downloads return HTTP 403; querying remains available to authorized admins.

The configured range (1h/24h/7d/30d) filters record timestamps. Queries consider
at most 1024 segments and read at most 1 MiB of segment data, taking file tails
when necessary and discarding partial first lines. Limits set `truncated`;
this is a bounded diagnostic export, not a full log archive. Segments are read
in descending filename order; segments from the same second have random suffixes
and are not guaranteed chronological ordering. Empty directories return empty
content. Symlink files are excluded. No arbitrary filename or path is accepted
from the query caller.

These settings control runtime logs, independently of audit event storage.
See [Audit coverage](audit-coverage.md) for the audit page, API, recorded operations
and current coverage boundaries.

## Verification

Run `zig build test` in `zigfs/`, rebuild with `zig build`, then run
`python3 conformance/log_configuration.py` from the repository root. The latter
uses isolated temporary data and a local service to check persistence/restart,
rotation, filtering, retention, path confinement, concurrency and downloads.

Startup status (initialization summary, API listening address, and metrics listener
status) is printed directly to stderr independently of the runtime log output and
level settings. These terminal status messages are not runtime log records: they
are not written to log files or included in log queries, downloads, or retention.
Startup warnings and failures remain diagnostic logs and follow the logging pipeline.
