#!/usr/bin/env bash
set -euo pipefail

socket_path="${SOCKET_PATH:-/tmp/systemd-cri-test.sock}"
state_dir="${STATE_DIR:-/tmp/systemd-cri-test-state}"
streaming_port="${STREAMING_PORT:-10011}"
metrics_port="${METRICS_PORT:-9091}"
timeout_sec="${TIMEOUT_SEC:-300}"
quick_mode=0
verbose=0
strict="${CRITEST_STRICT:-0}"
focus="${CRITEST_FOCUS:-}"
skip="${CRITEST_SKIP:-}"

log() { printf "[critest] %s\n" "$*"; }
warn() { printf "[critest] %s\n" "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: critest-runner.sh [--quick] [--verbose] [--help]

Environment:
  SOCKET_PATH, STATE_DIR, STREAMING_PORT, METRICS_PORT, TIMEOUT_SEC
  CRITEST_FOCUS, CRITEST_SKIP, CRITEST_STRICT, VERBOSE
  SYSTEMD_CRI_BIN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) quick_mode=1 ;;
    --verbose|-v) verbose=1 ;;
    --help|-h) usage; exit 0 ;;
    *) warn "unknown arg: $1"; usage; exit 1 ;;
  esac
  shift
done

if [[ -n "${VERBOSE:-}" ]]; then
  verbose=1
fi

skip_or_fail() {
  if [[ "$strict" == "1" ]]; then
    warn "$1"
    exit 1
  fi
  warn "Skipping: $1"
  exit 0
}

check_dbus() {
  if command -v dbus-send >/dev/null 2>&1; then
    dbus-send --system --dest=org.freedesktop.DBus --type=method_call --print-reply \
      /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1
    return $?
  fi
  if command -v busctl >/dev/null 2>&1; then
    busctl --system list >/dev/null 2>&1
    return $?
  fi
  return 1
}

if ! check_dbus; then
  skip_or_fail "D-Bus system bus not available"
fi

if [[ "$(id -u)" != "0" ]]; then
  warn "Not running as root - only runtime info tests will run"
  quick_mode=1
fi

if ! command -v critest >/dev/null 2>&1; then
  skip_or_fail "critest not found (install cri-tools)"
fi

if ! command -v crictl >/dev/null 2>&1; then
  skip_or_fail "crictl not found (install cri-tools)"
fi

binary="${SYSTEMD_CRI_BIN:-}"
if [[ -z "$binary" ]]; then
  if [[ -x "./bin/systemd-cri" ]]; then
    binary="./bin/systemd-cri"
  elif command -v systemd-cri >/dev/null 2>&1; then
    binary="$(command -v systemd-cri)"
  elif command -v go >/dev/null 2>&1; then
    log "Building systemd-cri..."
    mkdir -p ./bin
    go build -o ./bin/systemd-cri ./cmd/systemd-cri
    binary="./bin/systemd-cri"
  else
    skip_or_fail "systemd-cri binary not found and go is unavailable"
  fi
fi

cleanup_test_images() {
  if ! command -v machinectl >/dev/null 2>&1; then
    return 0
  fi
  local prefixes=("e2etestimages-" "k8sstagingcritools-")
  local images
  images="$(machinectl list-images --no-legend 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "$images" ]]; then
    return 0
  fi
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    for p in "${prefixes[@]}"; do
      if [[ "$img" == "$p"* ]]; then
        machinectl remove "$img" >/dev/null 2>&1 || true
        break
      fi
    done
  done <<<"$images"
}

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  if command -v umount >/dev/null 2>&1; then
    if [[ -d "$state_dir/containers" ]]; then
      find "$state_dir/containers" -type d -name rootfs -print0 2>/dev/null | while IFS= read -r -d '' mp; do
        umount -l "$mp" >/dev/null 2>&1 || true
      done
    fi
  fi
  rm -f "$socket_path"
  rm -rf "$state_dir"
  cleanup_test_images
}
trap cleanup EXIT

mkdir -p "$state_dir"
rm -f "$socket_path"

log "Starting systemd-cri..."
log "  Socket: $socket_path"
log "  State dir: $state_dir"

"$binary" \
  --socket "$socket_path" \
  --state-dir "$state_dir" \
  --streaming-port "$streaming_port" \
  --metrics-port "$metrics_port" \
  --log-level info &
server_pid="$!"

log "Waiting for socket..."
elapsed=0
until [[ -S "$socket_path" || -e "$socket_path" ]]; do
  sleep 0.5
  elapsed=$((elapsed + 1))
  if [[ $elapsed -ge $((timeout_sec * 2)) ]]; then
    warn "Timeout waiting for socket"
    exit 1
  fi
done

endpoint="unix://$socket_path"
if ! crictl --runtime-endpoint "$endpoint" --image-endpoint "$endpoint" version >/dev/null 2>&1; then
  warn "Failed to connect to systemd-cri via crictl"
  exit 1
fi

if [[ $quick_mode -eq 1 ]]; then
  focus="runtime info"
fi

if [[ -z "$skip" && $quick_mode -eq 0 ]]; then
  skip="should support seccomp|SELinux|Apparmor|ListMetricDescriptors|propagate mounts to the host"
fi

args=(critest --runtime-endpoint "$endpoint" --image-endpoint "$endpoint" --ginkgo.no-color)
if [[ -n "$focus" ]]; then
  args+=(--ginkgo.focus "$focus")
fi
if [[ -n "$skip" ]]; then
  args+=(--ginkgo.skip "$skip")
fi
if [[ $verbose -eq 1 ]]; then
  args+=(--ginkgo.v)
fi

log "Running critest..."
"${args[@]}"
