#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
START_SCRIPT="$ROOT_DIR/scripts/start-audio-dsp.sh"
FAILSAFE_START="$ROOT_DIR/scripts/start-audio-dsp-failsafe.sh"
FAILSAFE_STOP="$ROOT_DIR/scripts/stop-audio-dsp-failsafe.sh"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$label (expected to find '$needle')"
  fi
}

assert_pid_not_running() {
  local pid="$1"
  if [[ -z "$pid" ]]; then
    fail "missing pid for process liveness assertion"
  fi
  if kill -0 "$pid" 2>/dev/null; then
    fail "expected pid $pid to be stopped"
  fi
}

setup_mock_runtime() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/runtime"
  cat >"$dir/bin/camilladsp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--check" ]]; then
  exit 0
fi
trap 'echo term >> "${CAMILLA_TERM_MARKER:?}"; exit 0' TERM INT
echo "$$" > "${CAMILLA_PID_MARKER:?}"
while true; do sleep 1; done
EOF
  cat >"$dir/bin/lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${LSOF_MODE:-none}" in
  other-owner)
    printf '%s\n' "99999"
    ;;
  none|*)
    exit 1
    ;;
esac
EOF
  cat >"$dir/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$dir/bin/camilladsp" "$dir/bin/lsof" "$dir/bin/pgrep"
  printf 'filters: {}\n' >"$dir/config.yml"
}

test_start_fails_when_different_process_owns_port() {
  local dir="$TEST_TMP/port_owner"
  setup_mock_runtime "$dir"
  local output

  set +e
  output="$(
    PATH="$dir/bin:/usr/bin:/bin" \
    CAMILLA_TERM_MARKER="$dir/runtime/term.log" \
    CAMILLA_PID_MARKER="$dir/runtime/camilladsp.pid.actual" \
    LSOF_MODE="other-owner" \
    CAMILLADSP_BIN="$dir/bin/camilladsp" \
    CAMILLADSP_CONFIG="$dir/config.yml" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    CAMILLADSP_WS_PORT=1234 \
    "$START_SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  [[ $status -ne 0 ]] || fail "different-owner startup should fail"
  assert_contains "$output" "never opened" "different-owner startup output"
  assert_pid_not_running "$(cat "$dir/runtime/camilladsp.pid.actual")"
  [[ ! -f "$dir/runtime/camilladsp.pid" ]] || fail "different-owner startup should remove pidfile"
  pass "start-audio-dsp.sh rejects foreign port owner and fails clearly"
}

test_start_timeout_cleans_up_spawned_process() {
  local dir="$TEST_TMP/timeout_cleanup"
  setup_mock_runtime "$dir"
  local output

  set +e
  output="$(
    PATH="$dir/bin:/usr/bin:/bin" \
    CAMILLA_TERM_MARKER="$dir/runtime/term.log" \
    CAMILLA_PID_MARKER="$dir/runtime/camilladsp.pid.actual" \
    LSOF_MODE="none" \
    CAMILLADSP_BIN="$dir/bin/camilladsp" \
    CAMILLADSP_CONFIG="$dir/config.yml" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    CAMILLADSP_WS_PORT=1234 \
    "$START_SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  [[ $status -ne 0 ]] || fail "timeout startup should fail"
  assert_contains "$output" "never opened" "timeout startup output"
  assert_pid_not_running "$(cat "$dir/runtime/camilladsp.pid.actual")"
  [[ ! -f "$dir/runtime/camilladsp.pid" ]] || fail "timeout startup should remove pidfile"
  pass "start-audio-dsp.sh timeout cleanup terminates process and removes pidfile"
}

test_failsafe_persists_and_restores_previous_output() {
  local dir="$TEST_TMP/failsafe_restore"
  mkdir -p "$dir/bin" "$dir/scripts" "$dir/runtime"

  cp "$FAILSAFE_START" "$dir/scripts/start-audio-dsp-failsafe.sh"
  cp "$FAILSAFE_STOP" "$dir/scripts/stop-audio-dsp-failsafe.sh"

  cat >"$dir/scripts/start-audio-dsp.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$dir/scripts/stop-audio-dsp.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$dir/scripts/audio-stream-keepalive.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/scripts/"*.sh

  local state_file="$dir/runtime/output_state"
  echo "Built-in Output" >"$state_file"
  cat >"$dir/bin/SwitchAudioSource" <<EOF
#!/usr/bin/env bash
set -euo pipefail
state_file="$state_file"
if [[ "\${1:-}" == "-a" ]]; then
  printf '%s\n' "Built-in Output" "System DSP Output"
  exit 0
fi
if [[ "\${1:-}" == "-c" ]]; then
  cat "\$state_file"
  exit 0
fi
if [[ "\${1:-}" == "-s" ]]; then
  echo "\$2" > "\$state_file"
  exit 0
fi
exit 1
EOF
  chmod +x "$dir/bin/SwitchAudioSource"

  local previous_output_file="$dir/runtime/previous_output_device"
  PATH="$dir/bin:/usr/bin:/bin" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    "$dir/scripts/start-audio-dsp-failsafe.sh" >/dev/null

  [[ -f "$previous_output_file" ]] || fail "failsafe start should persist previous output device"
  [[ "$(cat "$previous_output_file")" == "Built-in Output" ]] || fail "persisted previous output mismatch"
  [[ "$(cat "$state_file")" == "System DSP Output" ]] || fail "failsafe start should route to processing output"

  PATH="$dir/bin:/usr/bin:/bin" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    "$dir/scripts/stop-audio-dsp-failsafe.sh" >/dev/null

  [[ "$(cat "$state_file")" == "Built-in Output" ]] || fail "failsafe stop should restore previous output"
  [[ ! -f "$previous_output_file" ]] || fail "failsafe stop should clear previous output statefile"
  pass "failsafe scripts persist and restore previous output device"
}

test_start_fails_when_different_process_owns_port
test_start_timeout_cleans_up_spawned_process
test_failsafe_persists_and_restores_previous_output

echo "All script tests passed."
