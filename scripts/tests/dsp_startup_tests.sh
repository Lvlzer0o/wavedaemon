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
if [[ -n "${CAMILLA_ARGS_MARKER:-}" ]]; then
  printf '%s\n' "$*" > "${CAMILLA_ARGS_MARKER}"
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
  assert_contains "$output" "already in use by PID 99999" "different-owner startup output"
  [[ ! -f "$dir/runtime/camilladsp.pid.actual" ]] || fail "different-owner startup should not spawn camilladsp"
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

test_start_prefers_bind_env_over_legacy_ws_env() {
  local dir="$TEST_TMP/bind_env_precedence"
  setup_mock_runtime "$dir"
  local output

  set +e
  output="$(
    PATH="$dir/bin:/usr/bin:/bin" \
    CAMILLA_TERM_MARKER="$dir/runtime/term.log" \
    CAMILLA_PID_MARKER="$dir/runtime/camilladsp.pid.actual" \
    CAMILLA_ARGS_MARKER="$dir/runtime/camilladsp.args" \
    LSOF_MODE="none" \
    CAMILLADSP_BIN="$dir/bin/camilladsp" \
    CAMILLADSP_CONFIG="$dir/config.yml" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    CAMILLADSP_WS_ADDRESS=127.0.0.1 \
    CAMILLADSP_WS_PORT=1234 \
    CAMILLADSP_BIND_ADDRESS=0.0.0.0 \
    CAMILLADSP_BIND_PORT=4321 \
    "$START_SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  [[ $status -ne 0 ]] || fail "bind precedence startup should still fail in timeout scenario"
  assert_contains "$(cat "$dir/runtime/camilladsp.args")" "--address 0.0.0.0 --port 4321" "bind env precedence args"
  assert_contains "$output" "local probe ws://127.0.0.1:4321 (bind: 0.0.0.0:4321)" "bind env precedence output"
  assert_pid_not_running "$(cat "$dir/runtime/camilladsp.pid.actual")"
  pass "start-audio-dsp.sh prefers bind env over legacy websocket env"
}

test_start_uses_ipv6_loopback_probe_for_ipv6_wildcard_bind() {
  local dir="$TEST_TMP/ipv6_probe"
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
    CAMILLADSP_BIND_ADDRESS="::" \
    CAMILLADSP_BIND_PORT=4321 \
    "$START_SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  [[ $status -ne 0 ]] || fail "ipv6 wildcard startup should still fail in timeout scenario"
  assert_contains "$output" "local probe ws://::1:4321" "ipv6 wildcard probe output"
  assert_pid_not_running "$(cat "$dir/runtime/camilladsp.pid.actual")"
  pass "start-audio-dsp.sh probes IPv6 loopback when daemon binds to ::"
}

test_start_treats_live_pidfile_as_startup_in_progress() {
  local dir="$TEST_TMP/live_pidfile"
  setup_mock_runtime "$dir"
  local output

  sleep 30 &
  local existing_pid=$!
  echo "$existing_pid" > "$dir/runtime/camilladsp.pid"

  set +e
  output="$(
    PATH="$dir/bin:/usr/bin:/bin" \
    CAMILLA_TERM_MARKER="$dir/runtime/term.log" \
    CAMILLA_PID_MARKER="$dir/runtime/camilladsp.pid.actual" \
    LSOF_MODE="none" \
    CAMILLADSP_BIN="$dir/bin/camilladsp" \
    CAMILLADSP_CONFIG="$dir/config.yml" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    "$START_SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  kill "$existing_pid" 2>/dev/null || true
  wait "$existing_pid" 2>/dev/null || true

  [[ $status -eq 0 ]] || fail "live pidfile startup should short-circuit as in-progress"
  assert_contains "$output" "startup already in progress (PID $existing_pid)" "live pidfile startup output"
  [[ ! -f "$dir/runtime/camilladsp.pid.actual" ]] || fail "live pidfile startup should not spawn duplicate camilladsp"
  [[ "$(cat "$dir/runtime/camilladsp.pid")" == "$existing_pid" ]] || fail "live pidfile startup should preserve pidfile"
  pass "start-audio-dsp.sh treats live pidfile as startup in progress"
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

test_failsafe_stop_cleans_previous_output_state_on_stop_failure() {
  local dir="$TEST_TMP/failsafe_stop_cleanup"
  mkdir -p "$dir/scripts" "$dir/runtime"

  cp "$FAILSAFE_STOP" "$dir/scripts/stop-audio-dsp-failsafe.sh"

  cat >"$dir/scripts/stop-audio-dsp.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$dir/scripts/audio-stream-keepalive.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/scripts/"*.sh

  local previous_output_file="$dir/runtime/previous_output_device"
  echo "Built-in Output" > "$previous_output_file"

  set +e
  PATH="/usr/bin:/bin" \
    CAMILLADSP_RUNTIME_DIR="$dir/runtime" \
    "$dir/scripts/stop-audio-dsp-failsafe.sh" >/dev/null 2>&1
  local status=$?
  set -e

  [[ $status -ne 0 ]] || fail "failsafe stop should surface stop-script failure"
  [[ ! -f "$previous_output_file" ]] || fail "failsafe stop should clear previous output statefile even on stop failure"
  pass "failsafe stop clears previous output statefile when stop script fails"
}

test_start_fails_when_different_process_owns_port
test_start_timeout_cleans_up_spawned_process
test_start_prefers_bind_env_over_legacy_ws_env
test_start_uses_ipv6_loopback_probe_for_ipv6_wildcard_bind
test_start_treats_live_pidfile_as_startup_in_progress
test_failsafe_persists_and_restores_previous_output
test_failsafe_stop_cleans_previous_output_state_on_stop_failure

echo "All script tests passed."
