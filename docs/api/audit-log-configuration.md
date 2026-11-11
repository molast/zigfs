# Independent audit log configuration

System Settings has one **Logs** entry in its vertical navigation. Inside that
page, horizontal **System logs** / **Audit logs** tabs switch between the forms. Both reuse the same base, retention and access form. Audit has no
output selector: the server only accepts `output=file`.

| Concern | System logs | Audit logs |
| --- | --- | --- |
| Configuration | `data/.zigfs/config/log_config.json` | `data/.zigfs/config/audit_log_config.json` |
| Default directory | `data/logs/` | `data/audit-logs/` |
| Owned files | `zigfs-*.log` | `audit-*.log` |
| Output | console / file / both | file only |
| Defaults | existing settings | same base settings, file output, audit directory, forever retention |

Audit retention defaults to forever to preserve previously retained history;
the form offers the same selectable retention periods as system logs. Settings
are applied immediately and restored at restart. The two services have separate
config snapshots, file handles, mutexes, rotation and cleanup. Even if configured
to use the same directory, each reads/cleans only its own filename prefix. Paths
remain confined to data, with symlink traversal and reserved `.zigfs` components
rejected. Changing directories affects subsequent writes and current queries;
previous directories are retained, as with system logs.

## Existing audit operations

The existing global/bucket audit listing now reads the audit service's files.
No runtime log settings are consulted. JSON writes the existing structured audit
schema; text writes `<unix-seconds> <level> [audit] <event-json>` on one line,
retaining all structured fields. Queries transparently read both formats,
including after a format switch. Files rotate before the configured size is
exceeded; a single oversized record is never split. Audit writes sync to disk.

Severity mapping: success/unknown → INFO; denied → WARN; failure/error → ERROR.
The chosen level is a threshold (WARN keeps denied/failure/error; ERROR keeps
failure/error). TRACE/DEBUG currently include the same available audit events as
INFO. OFF stops new audit writes without deleting existing history. Cleanup and
retention apply only to audit segments; queries also omit expired audit events
when automatic cleanup is enabled. Physical segment deletion is based on file
age, so a segment containing recent entries is retained until its whole-file
retention time elapses.

The audit page loads its default time range and download availability from audit
settings. Explicit time filters override the default range. `from=0` represents
all retained history. Existing pagination/category/action/etc. filters continue
to work. Audit download requests use the audit download endpoint and enforce its
own permission setting, independently from system log download permissions.
Downloads preserve the saved format and apply the page's filters to returned
content. Bounded export responses disclose truncation; normal structured audit
pagination scans audit segments without the runtime-log export byte cap.

## API

- `GET/PUT /_admin/v1/settings/audit-logs`
- `GET /_admin/v1/settings/audit-logs/query`
- `GET /_admin/v1/settings/audit-logs/download`
- BFF equivalents use `/api/v1` and forward through ZigFS.

The config shape matches `LogConfig`; omitted `output` defaults to `file`, and any other explicit output is rejected.
Query/download accept optional `from`/`to` Unix-second bounds. Downloads disabled
returns 403, invalid output/config returns 400. Management authorization applies
as for system logs. Updating audit settings itself is an auditable operation,
subject to the newly selected level (OFF therefore records no new entry).

## Legacy migration

On first startup, the legacy active snapshot and archive are normalized and
imported into audit segments. Stable event IDs prevent duplication if a partial
migration is retried. After successful writes, the atomic marker
`data/.zigfs/system/audit-log-v1.migrated` prevents further import on restart or
when changing configured directories. Original legacy files are preserved as
read-only migration backups; new writes, queries and retention no longer use
them. They are not automatically deleted by the new retention configuration.
Do not remove the migration marker independently from the migrated data.

## Validation

`zig build test`, Go tests, frontend build/i18n/parser tests and
`conformance/log_configuration.py` cover isolation, fixed file output, save and
restart, text/JSON queries, level filtering, rotation, download denial and
prefix-scoped cleanup. `conformance/audit_events.py` covers the existing audit
API, migration and restart behavior.
