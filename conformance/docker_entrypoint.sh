#!/bin/sh
# Run against a locally built image containing the new entrypoint.
set -eu
image=${1:-zigfs-entrypoint-qa}

# Simulate a NAS directory created by root, including existing read-only data.
# The probe replaces the server only inside this disposable container.
docker run --rm --entrypoint sh "$image" -ec '
    mkdir -p /tmp/storage/nested /tmp/outside
    printf preserved > /tmp/storage/nested/object
    chmod 500 /tmp/storage/nested
    chmod 400 /tmp/storage/nested/object
    ln -s /tmp/outside /tmp/storage/link
    cat > /usr/local/bin/zigfs <<"PROBE"
#!/bin/sh
set -eu
[ "$(id -u)" = 10001 ]
[ "$(id -g)" = 10001 ]
[ "$(cat /tmp/storage/nested/object)" = preserved ]
printf updated >> /tmp/storage/nested/object
mkdir /tmp/storage/new-directory
[ "$(stat -c %u /tmp/outside)" = 0 ]
[ "$1" = --probe ]
echo "ownership, existing data, symlink isolation, arguments and privilege drop: passed"
PROBE
    chmod 755 /usr/local/bin/zigfs
    ZIGFS_DATA_ROOT=/tmp/storage /usr/local/bin/docker-entrypoint.sh /usr/local/bin/zigfs --probe
'

# An explicit non-root user can still run the entrypoint without su-exec.
docker run --rm --user 10001:10001 --entrypoint sh "$image" -ec '
    mkdir -p /tmp/probe
    printf "#!/bin/sh\nid -u\n" > /tmp/probe/zigfs
    chmod 755 /tmp/probe/zigfs
    result=$(PATH=/tmp/probe:$PATH ZIGFS_DATA_ROOT=/tmp/user-data /usr/local/bin/docker-entrypoint.sh zigfs)
    [ "$result" = 10001 ]
    echo "explicit non-root user: passed"
'

# A read-only mount must produce an actionable error instead of starting.
output=$(docker run --rm --read-only --entrypoint sh "$image" -ec '
    ZIGFS_DATA_ROOT=/unwritable /usr/local/bin/docker-entrypoint.sh /usr/local/bin/zigfs
' 2>&1) && {
    echo 'ERROR: read-only storage unexpectedly succeeded' >&2
    exit 1
}
printf '%s\n' "$output" | grep -q 'cannot prepare /unwritable'
echo 'read-only storage diagnostic: passed'
