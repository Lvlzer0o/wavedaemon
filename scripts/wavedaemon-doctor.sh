#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
CONFIG="${CAMILLADSP_CONFIG:-$REPO_ROOT/dsp/config.yml}"
CAMILLADSP_PIDFILE="${CAMILLADSP_PIDFILE:-$RUNTIME_DIR/camilladsp.pid}"
KEEPALIVE_PIDFILE="${CAMILLADSP_KEEPALIVE_PIDFILE:-$RUNTIME_DIR/keepalive.pid}"
UI_PIDFILE="${CAMILLADSP_UI_PIDFILE:-$RUNTIME_DIR/ui-server.pid}"

WS_PORT="${CAMILLADSP_WS_PORT:-1234}"
UI_PORT="${CAMILLADSP_UI_PORT:-9137}"

MULTI_OUTPUT_NAME="${CAMILLADSP_MULTI_OUTPUT_NAME:-System DSP Output}"
MULTI_OUTPUT_FALLBACK="${CAMILLADSP_MULTI_OUTPUT_FALLBACK:-Multi-Output Device}"
AGGREGATE_OUTPUT_NAME="${CAMILLADSP_AGGREGATE_OUTPUT_NAME:-DSP Aggregate}"
BLACKHOLE_DEVICE_NAME="${CAMILLADSP_BLACKHOLE_DEVICE_NAME:-BlackHole 2ch}"
TARGET_SAMPLE_RATE="${CAMILLADSP_TARGET_SAMPLE_RATE:-48000}"

TOTAL_FAIL=0
TOTAL_WARN=0
TOTAL_OK=0

AUDIO_INFO=""

report_ok() {
  TOTAL_OK=$((TOTAL_OK + 1))
  printf '  [OK]   %s\n' "$1"
}

report_warn() {
  TOTAL_WARN=$((TOTAL_WARN + 1))
  printf '  [WARN] %s\n' "$1"
}

report_fail() {
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
  printf '  [FAIL] %s\n' "$1"
}

section() {
  printf '\n%s\n' "$1"
}

device_exists() {
  local device="$1"
  local type="${2:-output}"
  [[ -n "$device" ]] || return 1
  SwitchAudioSource -a -t "$type" | grep -Fx "$device" >/dev/null 2>&1
}

first_sample_rate_for_device() {
  local device="$1"
  local first=""
  local rate=""

  [[ -n "$AUDIO_INFO" ]] || return 1

  while IFS= read -r rate; do
    [[ -z "${first:-}" ]] && first="$rate"
    if [[ "$rate" =~ ^[0-9]+$ ]] && [[ "$rate" != "0" ]]; then
      printf '%s\n' "$rate"
      return 0
    fi
  done < <(
    printf '%s\n' "$AUDIO_INFO" | awk -v dev="$device" '
      /^[[:space:]]+[^[:space:]].*:$/ {
        name=$0
        gsub(/^[[:space:]]+/, "", name)
        sub(/:$/, "", name)
      }
      /Current SampleRate:/ && name == dev { print $3 }
    '
  )

  if [[ -n "$first" ]]; then
    printf '%s\n' "$first"
    return 0
  fi

  return 1
}

default_output_device_name() {
  [[ -n "$AUDIO_INFO" ]] || return 1
  printf '%s\n' "$AUDIO_INFO" | awk '
    /^[[:space:]]+[^[:space:]].*:$/ {
      name=$0
      gsub(/^[[:space:]]+/, "", name)
      sub(/:$/, "", name)
    }
    /Default Output Device:[[:space:]]+Yes/ {
      print name
      exit
    }
  '
}

check_dependency() {
  local cmd="$1"
  local label="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    report_ok "$label found"
  else
    report_fail "$label missing"
  fi
}

check_pid_runtime() {
  local label="$1"
  local pidfile="$2"

  if [[ ! -f "$pidfile" ]]; then
    report_ok "$label: stopped"
    return 0
  fi

  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -z "${pid:-}" ]]; then
    report_warn "$label: stale pidfile (empty): $pidfile"
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    local cmdline
    cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ -n "$cmdline" ]]; then
      report_ok "$label: running (PID $pid)"
    else
      report_ok "$label: running (PID $pid)"
    fi
    return 0
  fi

  report_warn "$label: stale pidfile (PID $pid not running)"
}

check_port() {
  local port="$1"
  local label="$2"
  local line=""

  if ! command -v lsof >/dev/null 2>&1; then
    report_warn "$label: could not check (lsof not installed)"
    return 0
  fi

  line="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1 " PID " $2}' || true)"
  if [[ -z "$line" ]]; then
    report_ok "$label: port $port is free"
  else
    report_warn "$label: port $port in use by $line"
  fi
}

check_sample_rate() {
  local device="$1"
  local expected="$2"
  local rate=""

  if [[ -z "$device" ]]; then
    report_warn "Sample rate check skipped (empty device name)"
    return 0
  fi

  if ! rate="$(first_sample_rate_for_device "$device")"; then
    report_warn "$device: sample rate unknown"
    return 0
  fi

  if [[ "$rate" == "$expected" ]]; then
    report_ok "$device: ${rate} Hz"
  elif [[ "$rate" == "0" ]]; then
    report_warn "$device: sample rate unavailable (0)"
  else
    report_warn "$device: ${rate} Hz (expected ${expected} Hz)"
  fi
}

printf 'WaveDaemon Doctor\n'

section "Dependencies"
check_dependency camilladsp "camilladsp"
check_dependency SwitchAudioSource "SwitchAudioSource"
check_dependency websocat "websocat"
check_dependency jq "jq"
check_dependency python3 "python3"

section "Audio Devices"
if command -v SwitchAudioSource >/dev/null 2>&1; then
  if device_exists "$BLACKHOLE_DEVICE_NAME" output || device_exists "$BLACKHOLE_DEVICE_NAME" input; then
    report_ok "$BLACKHOLE_DEVICE_NAME present"
  else
    report_fail "$BLACKHOLE_DEVICE_NAME missing"
  fi

  if device_exists "$AGGREGATE_OUTPUT_NAME" output || device_exists "$AGGREGATE_OUTPUT_NAME" input; then
    report_ok "$AGGREGATE_OUTPUT_NAME present"
  else
    report_warn "$AGGREGATE_OUTPUT_NAME missing"
  fi

  if device_exists "$MULTI_OUTPUT_NAME" output; then
    report_ok "$MULTI_OUTPUT_NAME present"
  elif device_exists "$MULTI_OUTPUT_FALLBACK" output; then
    report_warn "$MULTI_OUTPUT_NAME missing; found fallback '$MULTI_OUTPUT_FALLBACK'"
  else
    report_warn "Neither '$MULTI_OUTPUT_NAME' nor '$MULTI_OUTPUT_FALLBACK' found"
  fi
else
  report_fail "SwitchAudioSource unavailable; cannot inspect audio devices"
fi

section "Sample Rates"
if command -v system_profiler >/dev/null 2>&1; then
  AUDIO_INFO="$(system_profiler SPAudioDataType 2>/dev/null || true)"
else
  AUDIO_INFO=""
fi

if [[ -z "$AUDIO_INFO" ]]; then
  report_warn "Unable to query sample rates (system_profiler unavailable or empty output)"
else
  check_sample_rate "$BLACKHOLE_DEVICE_NAME" "$TARGET_SAMPLE_RATE"
  check_sample_rate "$AGGREGATE_OUTPUT_NAME" "$TARGET_SAMPLE_RATE"

  current_output=""
  if command -v SwitchAudioSource >/dev/null 2>&1; then
    current_output="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
  fi

  if [[ -n "${current_output:-}" ]]; then
    check_sample_rate "$current_output" "$TARGET_SAMPLE_RATE"
  else
    default_output="$(default_output_device_name || true)"
    if [[ -n "${default_output:-}" ]]; then
      check_sample_rate "$default_output" "$TARGET_SAMPLE_RATE"
    else
      report_warn "Could not determine active output device sample rate"
    fi
  fi
fi

section "Ports"
check_port "$WS_PORT" "CamillaDSP WebSocket"
check_port "$UI_PORT" "Control UI"

section "Config"
if [[ -f "$CONFIG" ]]; then
  config_samplerate="$(awk '/^[[:space:]]*samplerate:[[:space:]]*[0-9]+/ {print $2; exit}' "$CONFIG" || true)"
  if [[ -n "${config_samplerate:-}" ]]; then
    if [[ "$config_samplerate" == "$TARGET_SAMPLE_RATE" ]]; then
      report_ok "config samplerate: ${config_samplerate} Hz"
    else
      report_warn "config samplerate: ${config_samplerate} Hz (target ${TARGET_SAMPLE_RATE} Hz)"
    fi
  else
    report_warn "could not read samplerate from $CONFIG"
  fi

  if command -v camilladsp >/dev/null 2>&1; then
    if camilladsp --check "$CONFIG" >/dev/null 2>&1; then
      report_ok "config validation passed: $CONFIG"
    else
      report_fail "config validation failed: $CONFIG"
      camilladsp --check "$CONFIG" || true
    fi
  else
    report_warn "camilladsp not found; skipped config validation"
  fi
else
  report_fail "config missing: $CONFIG"
fi

section "Runtime"
check_pid_runtime "CamillaDSP" "$CAMILLADSP_PIDFILE"
check_pid_runtime "Keepalive" "$KEEPALIVE_PIDFILE"
check_pid_runtime "UI server" "$UI_PIDFILE"

section "Summary"
printf '  OK: %s\n' "$TOTAL_OK"
printf '  WARN: %s\n' "$TOTAL_WARN"
printf '  FAIL: %s\n' "$TOTAL_FAIL"

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  printf '\nStatus: FAIL\n'
  exit 1
fi

if [[ "$TOTAL_WARN" -gt 0 ]]; then
  printf '\nStatus: WARN\n'
  exit 0
fi

printf '\nStatus: OK\n'
