# syntax=docker/dockerfile:1.7

FROM alpine:latest AS builder

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH

WORKDIR /src
RUN apk add --no-cache ca-certificates jq wget xz \
    && case "${TARGETARCH}" in \
         amd64) zig_arch="x86_64" ;; \
         arm64) zig_arch="aarch64" ;; \
         *) echo "Unsupported Docker architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && wget -qO /tmp/zig-index.json https://ziglang.org/download/index.json \
    && zig_platform="${zig_arch}-linux" \
    && zig_url="$(jq -er --arg version "${ZIG_VERSION}" --arg platform "${zig_platform}" '.[$version][$platform].tarball' /tmp/zig-index.json)" \
    && zig_sha256="$(jq -er --arg version "${ZIG_VERSION}" --arg platform "${zig_platform}" '.[$version][$platform].shasum' /tmp/zig-index.json)" \
    && wget -qO /tmp/zig.tar.xz "${zig_url}" \
    && echo "${zig_sha256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && zig version \
    && rm -f /tmp/zig-index.json /tmp/zig.tar.xz
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Doptimize=ReleaseSafe --prefix /out

FROM alpine:latest AS runtime

LABEL org.opencontainers.image.title="ZigFS" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN addgroup -S -g 10001 zigfs \
    && adduser -S -D -H -u 10001 -G zigfs zigfs \
    && mkdir -p /etc/zigfs /var/lib/zigfs \
    && chown -R zigfs:zigfs /var/lib/zigfs

COPY --from=builder /out/bin/zigfs /usr/local/bin/zigfs
COPY config.docker.yaml /etc/zigfs/config.yaml

USER zigfs:zigfs
WORKDIR /var/lib/zigfs

VOLUME ["/var/lib/zigfs"]
EXPOSE 9000 9090
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/zigfs"]
CMD ["--config", "/etc/zigfs/config.yaml"]
