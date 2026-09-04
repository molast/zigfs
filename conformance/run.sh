#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
port="${ZIGFS_CONFORMANCE_PORT:-19070}"

if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65534 )); then
  echo "ZIGFS_CONFORMANCE_PORT must be an integer between 1024 and 65534." >&2
  exit 2
fi

for command_name in zig node swiftc curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 2
  fi
done

typescript_compiler="$repo_root/zigfs-admin/web/node_modules/.bin/tsc"
if [[ ! -x "$typescript_compiler" ]]; then
  echo "TypeScript is not installed; run pnpm install in zigfs-admin/web first." >&2
  exit 2
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zigfs-conformance.XXXXXX")"
zigfs_pid=""
zigfs_log="$temp_dir/zigfs.log"

cleanup() {
  local status=$?
  if [[ -n "$zigfs_pid" ]] && kill -0 "$zigfs_pid" >/dev/null 2>&1; then
    kill "$zigfs_pid" >/dev/null 2>&1 || true
    wait "$zigfs_pid" >/dev/null 2>&1 || true
  fi
  if (( status != 0 )) && [[ -f "$zigfs_log" ]]; then
    echo "--- ZigFS conformance log ---" >&2
    tail -n 80 "$zigfs_log" >&2 || true
  fi
  rm -rf "$temp_dir"
}
trap cleanup EXIT INT TERM

endpoint="http://127.0.0.1:$port"
config_path="$temp_dir/config.yaml"
runtime_config="$temp_dir/runtime.json"
fixture="$repo_root/conformance/fixtures/v1.json"
swift_binary="$temp_dir/zigfs-swift-conformance"

cat >"$config_path" <<EOF
server:
  api_address: "127.0.0.1:$port"
observability:
  metrics_enabled: false
  metrics_address: "127.0.0.1:$((port + 1))"
storage:
  data_root: "$temp_dir/data"
  stream_buffer_size: 65536
s3:
  public_endpoint: "$endpoint"
  region: "us-east-1"
  request_time_skew_seconds: 900
  multipart_expiry_seconds: 604800
admin:
  username: "phase7-admin"
  password: "phase7-admin-password"
  session_secret: "phase7-isolated-session-secret-000000000000"
  session_ttl_seconds: 3600
EOF

(cd "$repo_root/zigfs" && zig build)
(cd "$repo_root/zigfs" && exec ./zig-out/bin/zigfs --config "$config_path") >"$zigfs_log" 2>&1 &
zigfs_pid=$!

ready=false
for _ in {1..100}; do
  if ! kill -0 "$zigfs_pid" >/dev/null 2>&1; then
    echo "Isolated ZigFS exited before becoming ready; check whether port $port is already in use." >&2
    exit 1
  fi
  if curl --silent --fail "$endpoint/health/ready" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  echo "ZigFS did not become ready at $endpoint." >&2
  exit 1
fi

node "$repo_root/conformance/provision.mjs" "$endpoint" "$runtime_config"
"$typescript_compiler" -p "$repo_root/conformance/typescript/tsconfig.json"

ZIGFS_CONFORMANCE_CONFIG="$runtime_config" \
ZIGFS_CONFORMANCE_FIXTURE="$fixture" \
node "$repo_root/conformance/typescript/verify.ts"

SWIFT_MODULECACHE_PATH="$temp_dir/swift-module-cache" \
CLANG_MODULE_CACHE_PATH="$temp_dir/clang-module-cache" \
swiftc -parse-as-library \
  -module-cache-path "$temp_dir/swift-module-cache" \
  "$repo_root/conformance/swift/Models.swift" \
  "$repo_root/conformance/swift/SigV4.swift" \
  "$repo_root/conformance/swift/XML.swift" \
  "$repo_root/conformance/swift/S3Client.swift" \
  "$repo_root/conformance/swift/main.swift" \
  -o "$swift_binary"

ZIGFS_CONFORMANCE_CONFIG="$runtime_config" \
ZIGFS_CONFORMANCE_FIXTURE="$fixture" \
"$swift_binary"

echo "Phase 7 SDK conformance: PASS"
