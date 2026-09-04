# zigfs-admin web

Vite + React web client for ZigFS management operations.

```bash
pnpm install
pnpm run dev
pnpm run build
```

The development server proxies `/api` and `/health` to `127.0.0.1:9001`.

The console provides Dashboard, Buckets, Objects, Access Keys, Storage, System,
and Settings views. It calls only the Go BFF. Object downloads and PUT uploads
use ZigFS Presigned URLs, so object bytes never pass through Go.
