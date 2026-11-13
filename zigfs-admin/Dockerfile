# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM node:24-bookworm-slim AS web-builder

ARG PNPM_VERSION=11.10.0
ARG PNPM_REGISTRY=https://registry.npmjs.org

ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:${PATH} \
    COREPACK_NPM_REGISTRY=${PNPM_REGISTRY}

WORKDIR /src/web
COPY web/ ./
RUN --mount=type=cache,id=zigfs-admin-pnpm,target=/pnpm/store \
    if [ -f dist/index.html ]; then \
      echo "Using locally built Admin Web assets"; \
    else \
      corepack enable \
      && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
      && pnpm config set registry "${PNPM_REGISTRY}" \
      && pnpm config set store-dir /pnpm/store \
      && pnpm install --frozen-lockfile \
      && pnpm run build; \
    fi \
    && mkdir -p /out \
    && cp -R dist/. /out/

FROM --platform=$BUILDPLATFORM golang:1.27-bookworm AS server-builder

ARG TARGETARCH
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}

WORKDIR /src/server
COPY server/ ./
RUN --mount=type=cache,id=zigfs-admin-go-mod,target=/go/pkg/mod \
    if [ -f vendor/modules.txt ]; then \
      echo "Using vendored Go modules"; \
    else \
      go mod download; \
    fi
RUN --mount=type=cache,id=zigfs-admin-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=zigfs-admin-go-build,target=/root/.cache/go-build \
    if [ -f vendor/modules.txt ]; then \
      export GOFLAGS="-mod=vendor"; \
    fi \
    && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/zigfs-admin \
    ./cmd/admin

FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="ZigFS Admin" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN mkdir -p /app/web \
    && chown -R 10001:10001 /app

COPY --from=server-builder /out/zigfs-admin /usr/local/bin/zigfs-admin
COPY --from=server-builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=web-builder /out /app/web

ENV ZIGFS_ADMIN_LISTEN=":9001" \
    ZIGFS_ENDPOINT="http://zigfs:9000" \
    ZIGFS_WEB_ROOT="/app/web" \
    ZIGFS_UPSTREAM_TIMEOUT="15m"

USER 10001:10001
WORKDIR /app

EXPOSE 9001
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/zigfs-admin"]
