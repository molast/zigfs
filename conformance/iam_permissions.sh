#!/usr/bin/env bash
set -uo pipefail

# Permission-only test entrypoint. It intentionally keeps each suite isolated
# and returns non-zero when any suite is blocked or fails.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="${IAM_RESULTS:-$ROOT/.iam-test-results}"
mkdir -p "$RESULTS"
status=0

run_suite() {
  local name="$1"; shift
  echo "== $name =="
  if (cd "$ROOT" && "$@") >"$RESULTS/$name.log" 2>&1; then
    echo "PASS $name"
    printf 'PASS\n' >"$RESULTS/$name.status"
  else
    echo "FAIL/BLOCKED $name (see $RESULTS/$name.log)"
    printf 'FAIL_OR_BLOCKED\n' >"$RESULTS/$name.status"
    status=1
  fi
}

run_suite zig bash -c "cd '$ROOT/zigfs' && zig build test"
run_suite go go -C zigfs-admin/server test ./...
run_suite go-race go -C zigfs-admin/server test -race ./...
run_suite web corepack pnpm --dir zigfs-admin/web run build
run_suite conformance python3 conformance/user_access_keys.py --admin-bin "${ADMIN_BIN:-/tmp/zigfs-admin-permissions-qa}"

exit "$status"
