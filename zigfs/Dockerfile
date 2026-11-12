# syntax=docker/dockerfile:1.7

FROM alpine:latest AS builder

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
ARG ZIG_DOWNLOAD_BASE_URL=https://ziglang.org/download
ARG ZIG_TOOLCHAIN_SHA256=

RUN apk add --no-cache curl-dev pkgconf

WORKDIR /src
RUN --mount=type=bind,source=.,target=/build-context,ro \
    target_arch="${TARGETARCH}" \
    && if [ -z "${target_arch}" ]; then target_arch="$(uname -m)"; fi \
    && case "${target_arch}" in \
         amd64|x86_64) zig_arch="x86_64"; zig_sha256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;; \
         arm64|aarch64) zig_arch="aarch64"; zig_sha256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;; \
         *) echo "Unsupported Docker architecture: ${target_arch}" >&2; exit 1 ;; \
       esac \
    && local_toolchain="" \
    && for candidate in \
         "/build-context/zigfs/zig-toolchain.tar.xz" \
         /build-context/zigfs/zig-${zig_arch}-linux-*.tar.xz \
         "/build-context/zig-toolchain.tar.xz" \
         /build-context/zig-${zig_arch}-linux-*.tar.xz; do \
         if [ -f "${candidate}" ]; then local_toolchain="${candidate}"; break; fi; \
       done \
    && if [ -n "${local_toolchain}" ]; then \
         echo "Using local Zig toolchain: ${local_toolchain#/build-context/}"; \
         cp "${local_toolchain}" /tmp/zig.tar.xz; \
         if [ -n "${ZIG_TOOLCHAIN_SHA256}" ]; then \
           echo "${ZIG_TOOLCHAIN_SHA256}  /tmp/zig.tar.xz" | sha256sum -c -; \
         else \
           echo "No local toolchain checksum supplied; SHA-256:"; \
           sha256sum /tmp/zig.tar.xz; \
         fi; \
       else \
         zig_url="${ZIG_DOWNLOAD_BASE_URL%/}/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
         echo "Downloading Zig toolchain: ${zig_url}"; \
         wget --tries=3 --timeout=30 -O /tmp/zig.tar.xz "${zig_url}"; \
         echo "${zig_sha256}  /tmp/zig.tar.xz" | sha256sum -c -; \
       fi \
    && unxz /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xf /tmp/zig.tar -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && zig version \
    && rm -f /tmp/zig.tar
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Doptimize=ReleaseSafe --prefix /out

FROM alpine:latest AS runtime

LABEL org.opencontainers.image.title="ZigFS" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apk add --no-cache libcurl ca-certificates

RUN addgroup -S -g 10001 zigfs \
    && adduser -S -D -H -u 10001 -G zigfs zigfs \
    && mkdir -p /etc/zigfs /var/lib/zigfs \
    && chown -R zigfs:zigfs /var/lib/zigfs

COPY --from=builder /out/bin/zigfs /usr/local/bin/zigfs
ENV ZIGFS_DATA_ROOT=/var/lib/zigfs ZIGFS_API_ADDRESS=0.0.0.0:9000 ZIGFS_METRICS_ADDRESS=0.0.0.0:9090

USER zigfs:zigfs
WORKDIR /var/lib/zigfs

VOLUME ["/var/lib/zigfs"]
EXPOSE 9000 9090
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/zigfs"]
