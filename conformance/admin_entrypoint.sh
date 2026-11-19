#!/bin/sh
# Validate configuration mount preparation using an isolated runtime image.
set -eu
image=${1:-zigfs-admin-gateway-qa}
docker run --rm --entrypoint sh "$image" -ec '
    mkdir -p /tmp/config/gateway
    printf preserved > /tmp/config/gateway/state.json
    chmod 700 /tmp/config /tmp/config/gateway
    chmod 600 /tmp/config/gateway/state.json
    cat > /usr/local/bin/zigfs-admin <<"PROBE"
#!/bin/sh
set -eu
[ "$(id -u)" = 10001 ]
[ "$(id -g)" = 10001 ]
[ "$(cat /tmp/config/gateway/state.json)" = preserved ]
printf updated >> /tmp/config/gateway/state.json
touch /tmp/config/listener.json
[ "$(stat -c %a /tmp/config/gateway/state.json)" = 600 ]
echo "Admin configuration mount ownership, private permissions and privilege drop: passed"
PROBE
    chmod 755 /usr/local/bin/zigfs-admin
    ZIGFS_ADMIN_CONFIG=/tmp/config/listener.json ZIGFS_GATEWAY_CONFIG_DIR=/tmp/config/gateway \
        /usr/local/bin/docker-entrypoint.sh /usr/local/bin/zigfs-admin
'
