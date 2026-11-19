#!/bin/sh
set -eu

# Only prepare storage for the server, not for diagnostic commands.
if [ "${1:-}" = /usr/local/bin/zigfs ] || [ "${1:-}" = zigfs ]; then
    data_root=${ZIGFS_DATA_ROOT:-/var/lib/zigfs}
    if [ "$(id -u)" = 0 ]; then
        if [ "$(readlink -f "$data_root")" = / ] || [ -L "$data_root" ]; then
            echo "ZigFS: refusing to prepare an unsafe data directory: $data_root" >&2
            exit 1
        fi

        echo "ZigFS: preparing data directory $data_root for UID/GID 10001:10001"
        # Do not follow symlinks or traverse nested mounts. Existing files from
        # a root-run deployment also need to be writable after dropping root.
        if ! mkdir -p "$data_root" ||
            ! find "$data_root" -xdev ! -type l \
                -exec chown 10001:10001 '{}' + ||
            ! find "$data_root" -xdev ! -type l \
                -exec chmod u+rwX '{}' +; then
            echo "ZigFS: cannot prepare $data_root; check for a read-only mount or NAS ACL restrictions." >&2
            exit 1
        fi
        exec su-exec 10001:10001 "$@"
    fi

    # Honor an explicit Docker --user setting without attempting privileged work.
    if ! mkdir -p "$data_root" || [ ! -w "$data_root" ] || [ ! -x "$data_root" ]; then
        echo "ZigFS: $data_root is not writable by the configured container user $(id -u)." >&2
        exit 1
    fi
fi

exec "$@"
