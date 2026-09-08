# syntax=docker/dockerfile:1.7

FROM ziglang/zig:0.16.0 AS builder

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Doptimize=ReleaseSafe --prefix /out

FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="ZigFS" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN mkdir -p /etc/zigfs /var/lib/zigfs \
    && chown -R 10001:10001 /var/lib/zigfs

COPY --from=builder /out/bin/zigfs /usr/local/bin/zigfs
COPY config.docker.yaml /etc/zigfs/config.yaml

USER 10001:10001
WORKDIR /var/lib/zigfs

VOLUME ["/var/lib/zigfs"]
EXPOSE 9000 9090
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/zigfs"]
CMD ["--config", "/etc/zigfs/config.yaml"]
