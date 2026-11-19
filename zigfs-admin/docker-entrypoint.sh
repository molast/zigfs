#!/bin/sh
set -eu

if [ "${1:-}" = /usr/local/bin/zigfs-admin ]; then
    config_file=${ZIGFS_ADMIN_CONFIG:-/app/config/listener.json}
    config_dir=$(dirname "$config_file")
    gateway_dir=${ZIGFS_GATEWAY_CONFIG_DIR:-$config_dir/gateway}
    if [ "$(id -u)" = 0 ]; then
        for directory in "$config_dir" "$gateway_dir"; do
            if [ "$(readlink -f "$directory")" = / ] || [ -L "$directory" ]; then
                echo "ZigFS Admin: unsafe configuration directory: $directory" >&2
                exit 1
            fi
            if ! mkdir -p "$directory" ||
                ! find "$directory" -xdev ! -type l -exec chown 10001:10001 '{}' + ||
                ! find "$directory" -xdev ! -type l -exec chmod u+rwX '{}' +; then
                echo "ZigFS Admin: configuration directory is not writable: $directory" >&2
                exit 1
            fi
        done
        exec gosu 10001:10001 "$@"
    fi
fi
exec "$@"
