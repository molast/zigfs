# zigfs-admin server

Go + Gin web forwarding server for ZigFS Admin.

## Environment

```text
ZIGFS_ADMIN_LISTEN=:9001
ZIGFS_ENDPOINT=http://127.0.0.1:9000
ZIGFS_WEB_ROOT=../web/dist
```

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
Management Health, and read-only Settings operations through the typed
`zigclient`. ZigFS error codes are preserved; an unreachable ZigFS is reported
as `503 StorageOffline`, while a recovering instance is `503 StorageNotReady`.

When creating an Access Key, the BFF omits the owner field. ZigFS binds the
credential to the confirmed administrator username in the current Management
API session; the browser cannot choose or override the tenant owner.

When creating a Bucket, the BFF also omits the owner field. ZigFS binds the
Bucket to the current administrator username, so the Admin Web does not expose
an Owner / tenant input.
