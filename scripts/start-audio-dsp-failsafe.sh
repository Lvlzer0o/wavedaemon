#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_OUTPUT_DEVICE="${1:-}"
START_SCRIPT="${SCRIPT_DIR}/start-audio-dsp.sh"
KEEPALIVE_SCRIPT="${SCRIPT_DIR}/audio-stream-keepalive.sh"
AUTO_KEEPALIVE="${CAMILLADSP_AUTO_KEEPALIVE:-0}"
PREFERRED_MULTI_OUTPUT_NAME="${CAMILLADSP_MULTI_OUTPUT_NAME:-System DSP Output}"
FALLBACK_MULTI_OUTPUT_NAME="${CAMILLADSP_MULTI_OUTPUT_FALLBACK:-Multi-Output Device}"
RAW_OUTPUT_FALLBACK="${CAMILLADSP_RAW_OUTPUT_FALLBACK:-BlackHole 2ch}"
SAFE_OUTPUT_FALLBACK="${CAMILLADSP_SAFE_OUTPUT_FALLBACK:-Built-in Output}"
ALLOW_RAW_OUTPUT_FALLBACK="${CAMILLADSP_ALLOW_RAW_OUTPUT_FALLBACK:-0}"
PREVIOUS_OUTPUT_DEVICE=""
OUTPUT_SWITCHED=0
STARTUP_SUCCESS=0

output_device_exists() {
  local device="$1"
  [[ -z "$device" ]] && return 1
  SwitchAudioSource -a -t output | grep -Fx "$device" >/dev/null 2>&1
}

is_raw_loopback_device() {
  local device="$1"
  [[ -z "$device" ]] && return 1
  [[ "$device" == "$RAW_OUTPUT_FALLBACK" ]] && return 0
  printf '%s\n' "$device" | grep -Eiq '(blackhole|loopback|soundflower)'
}

pick_non_loopback_output() {
  local device
  while IFS= read -r device; do
    [[ -z "$device" ]] && continue
    if is_raw_loopback_device "$device"; then
      continue
    fi
    echo "$device"
    return 0
  done < <(SwitchAudioSource -a -t output)
  return 1
}

pick_default_output_device() {
  local current_output
  local non_loopback_output

  if output_device_exists "$PREFERRED_MULTI_OUTPUT_NAME"; then
    echo "$PREFERRED_MULTI_OUTPUT_NAME"
    return 0
  fi
  if output_device_exists "$FALLBACK_MULTI_OUTPUT_NAME"; then
    echo "$FALLBACK_MULTI_OUTPUT_NAME"
    return 0
  fi

  current_output="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
  if output_device_exists "$current_output" && ! is_raw_loopback_device "$current_output"; then
    echo "$current_output"
    return 0
  fi

  if output_device_exists "$SAFE_OUTPUT_FALLBACK"; then
    echo "$SAFE_OUTPUT_FALLBACK"
    return 0
  fi

  if non_loopback_output="$(pick_non_loopback_output)"; then
    echo "$non_loopback_output"
    return 0
  fi

  if [[ "$ALLOW_RAW_OUTPUT_FALLBACK" == "1" ]] && output_device_exists "$RAW_OUTPUT_FALLBACK"; then
    echo "$RAW_OUTPUT_FALLBACK"
    return 0
  fi

  return 1
}

restore_previous_output_on_failure() {
  local exit_code=$?
  set +e

  if [[ "$STARTUP_SUCCESS" != "1" && "$OUTPUT_SWITCHED" == "1" && -n "$PREVIOUS_OUTPUT_DEVICE" ]]; then
    if output_device_exists "$PREVIOUS_OUTPUT_DEVICE"; then
      SwitchAudioSource -s "$PREVIOUS_OUTPUT_DEVICE" -t output >/dev/null 2>&1
      echo "Startup failed; restored previous output: $PREVIOUS_OUTPUT_DEVICE" >&2
    else
      echo "Startup failed and previous output '$PREVIOUS_OUTPUT_DEVICE' is no longer available." >&2
    fi
  fi

  return "$exit_code"
}

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
  echo "SwitchAudioSource is not installed."
  echo "Install with: brew install switchaudio-osx"
  exit 1
fi

trap restore_previous_output_on_failure EXIT
PREVIOUS_OUTPUT_DEVICE="$(SwitchAudioSource -c -t output 2>/dev/null || true)"

if [[ -z "$SYSTEM_OUTPUT_DEVICE" ]]; then
  if ! SYSTEM_OUTPUT_DEVICE="$(pick_default_output_device)"; then
    echo "No safe output device was found."
    echo "Pass an explicit output device name, or opt in to raw fallback with:"
    echo "  CAMILLADSP_ALLOW_RAW_OUTPUT_FALLBACK=1 $0 \"$RAW_OUTPUT_FALLBACK\""
    echo "Available outputs:"
    SwitchAudioSource -a -t output
    exit 1
  fi
fi

if ! output_device_exists "$SYSTEM_OUTPUT_DEVICE"; then
  echo "Output device '$SYSTEM_OUTPUT_DEVICE' not found."
  echo "Available outputs:"
  SwitchAudioSource -a -t output
  exit 1
fi

if [[ -n "$PREVIOUS_OUTPUT_DEVICE" && "$SYSTEM_OUTPUT_DEVICE" == "$PREVIOUS_OUTPUT_DEVICE" ]]; then
  echo "System output already set to: $SYSTEM_OUTPUT_DEVICE"
else
  SwitchAudioSource -s "$SYSTEM_OUTPUT_DEVICE" -t output
  OUTPUT_SWITCHED=1
  echo "System output set to: $SYSTEM_OUTPUT_DEVICE"
fi

if [[ "$AUTO_KEEPALIVE" == "1" ]]; then
  if [[ -x "$KEEPALIVE_SCRIPT" ]]; then
    "$KEEPALIVE_SCRIPT" start || true
  else
    echo "Keepalive script not found: $KEEPALIVE_SCRIPT"
  fi
fi

"$START_SCRIPT"
STARTUP_SUCCESS=1

echo
echo "Current output:"
SwitchAudioSource -c -t output
