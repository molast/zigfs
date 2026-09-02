# zigfs-admin server

Go + Gin control-plane service for ZigFS.

## Environment

```text
ZIGFS_ADMIN_LISTEN=:8080
ZIGFS_ENDPOINT=http://127.0.0.1:9001
ZIGFS_ADMIN_TOKEN=<zig-management-token>
ZIGFS_WEB_ADMIN_TOKEN=<browser-admin-token>
ZIGFS_WEB_ROOT=../web/dist
```

## Commands

```bash
go test ./...
go run ./cmd/admin
```

The Admin server does not own storage state. Its `/api/v1/*` routes are a web
adapter over the ZigFS Management API; object bytes never pass through it.
