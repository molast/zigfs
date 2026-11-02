# zigfs-admin web

Vite + React web client for ZigFS management operations.

```bash
pnpm install
pnpm run dev
pnpm run build
```

The development server proxies `/api` and `/health` to `127.0.0.1:9001`.

The console provides Object Browser, Access Keys, Storage, System,
and Settings views. It calls only the Go BFF for control operations. Object
downloads and multipart part uploads use ZigFS Presigned URLs, so object bytes
never pass through Go.

Multipart uploads report aggregate progress and can be paused, resumed, retried,
or aborted. ZigFS remains the source of truth for Upload IDs and committed parts.
After a page reload, the console rediscovers unfinished uploads from ZigFS; the
user must reselect the original local file before continuing. After all Parts
are committed, the task enters a distinct completing state until ZigFS publishes
the final Object. A reload during completion reconciles the vanished Upload ID
against the Object list instead of reporting a stale task error.
