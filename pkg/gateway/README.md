# ZigFS HTTPS gateway

Independent Go module: `github.com/molast/zigfs/pkg/gateway`.

The package owns HTTPS listeners, explicit Admin/S3 host routing, streaming reverse
proxying, local CA and imported certificates, atomic deployment state, candidate
apply/rollback coordination, optional macOS loopback DNS, and macOS/Windows local setup helpers.
It imports neither Gin nor Admin internals and never accesses object storage.
It is a library: extracting it does not introduce another required process.

## Embed

```go
edge := gateway.New(privateConfigDirectory, func() string { return upstreamURL })
edge.Start(adminHandler)
go edge.Maintain(ctx)
// Optional: only runs on macOS. It serves loopback DNS, never changes the OS.
go edge.RunLocalDNS(ctx)
// On shutdown: cancel ctx, then drain HTTPS connections.
edge.Shutdown(shutdownContext)
```

`Start` leaves the HTTP recovery handler available if persisted HTTPS configuration
cannot start. Read `Status().Error` for diagnostics. Prepare with a revision from
`Status()`, then validate the candidate from the actual client before applying.
The caller must authenticate and authorize every management call, enforce CSRF,
audit changes, and limit request sizes. `Apply` and `Rollback` accept read/write
callbacks to coordinate the public S3 endpoint; writes must compare the expected
upstream network state to prevent overwriting concurrent changes. Do not expose
these methods as unauthenticated HTTP endpoints.

The endpoint callback must be concurrency-safe and return a trusted HTTP(S) origin
without credentials, path, query or fragment. The Admin handler and configuration
directory must be ready before starting. All instances on one Mac share the fixed
local resolver port; only one should enable `RunLocalDNS`.

## Development

From this directory run `go test ./...` or `go test -race ./...`. The repository
`go.work` links Admin directly to this module, so local edits take effect without
copying vendored sources. To test independently: `GOWORK=off go test ./...`.

Admin retains a local `replace` for builds outside workspace mode. If using its
optional ignored vendor directory, regenerate it with `GOWORK=off go mod vendor`
after changing this module. Docker does this automatically when vendor is present.
Build Admin from the repository root:

```sh
docker build -f zigfs-admin/Dockerfile -t zigfs-admin:local .
```

See [operation guide](../../docs/gateway.md) and
[API contract](../../docs/api/gateway.openapi.yaml) for the integrated Admin adapter.
