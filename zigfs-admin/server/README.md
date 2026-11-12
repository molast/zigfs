# zigfs-admin server

Go + Gin web forwarding server for ZigFS Admin.

## Environment

Reads literal uppercase assignments from `.env` in the working directory, or the file selected by `ZIGFS_ENV_FILE`. Process variables override the file; persisted listener settings override both. `./start.sh` selects the repository root `.env` automatically. See [configuration](../../docs/configuration.md) and the root `.env.example`.

```text
ZIGFS_ADMIN_LISTEN=:9001
ZIGFS_ENDPOINT=http://127.0.0.1:9000
ZIGFS_WEB_ROOT=../web/dist
```

## Persisted listener configuration

Network listener saves use `ZIGFS_ADMIN_CONFIG`, defaulting to the OS user
configuration directory under `zigfs-admin/listener.json`. Persisted values
supersede `ZIGFS_ADMIN_LISTEN` and `ZIGFS_ENDPOINT`. The directory must be writable
and durable across container restarts. BFF persists its own listener/upstream
settings only; it never reads or writes the ZigFS data directory.

See [Network configuration](../../docs/network-settings.md),
[deployment examples](../../docs/deployment/network.md), and
[API behavior](../../docs/api/network-settings.md).

## Commands

```bash
go test ./...
go run ./cmd/admin
```

The Admin Web is only a presentation layer, and this server is only its static
host and API forwarder. ZigFS is the sole backend and owns all user identities,
authentication, authorization, storage state, and business rules. Object bytes
never pass through Admin. This server only relays ZigFS-issued short-lived tokens
in HttpOnly cookies.

The BFF forwards Bucket, Object view, Presign, Access Key, Storage, System,
Management Health, and Settings read/write operations through the typed
`zigclient`. ZigFS error codes are preserved; an unreachable ZigFS is reported
as `503 StorageOffline`, while a recovering instance is `503 StorageNotReady`.

When creating an Access Key, the BFF omits the owner field. ZigFS binds the
credential to the confirmed administrator username in the current Management
API session; the browser cannot choose or override the tenant owner.

When creating a Bucket, the BFF also omits the owner field. ZigFS binds the
Bucket to the current administrator username, so the Admin Web does not expose
an Owner / tenant input.
