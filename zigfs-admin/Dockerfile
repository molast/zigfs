# syntax=docker/dockerfile:1.7

FROM node:24-bookworm-slim AS web-builder

WORKDIR /src/web
RUN corepack enable
COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm run build

FROM golang:1.27-bookworm AS server-builder

WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/zigfs-admin \
    ./cmd/admin

FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="ZigFS Admin" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app/web \
    && chown -R 10001:10001 /app

COPY --from=server-builder /out/zigfs-admin /usr/local/bin/zigfs-admin
COPY --from=web-builder /src/web/dist /app/web

ENV ZIGFS_ADMIN_LISTEN=":9001" \
    ZIGFS_ENDPOINT="http://zigfs:9000" \
    ZIGFS_WEB_ROOT="/app/web" \
    ZIGFS_UPSTREAM_TIMEOUT="15m"

USER 10001:10001
WORKDIR /app

EXPOSE 9001
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/zigfs-admin"]
