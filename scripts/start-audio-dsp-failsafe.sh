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

pick_default_output_device() {
  if SwitchAudioSource -a -t output | grep -Fx "$PREFERRED_MULTI_OUTPUT_NAME" >/dev/null 2>&1; then
    echo "$PREFERRED_MULTI_OUTPUT_NAME"
    return
  fi
  if SwitchAudioSource -a -t output | grep -Fx "$FALLBACK_MULTI_OUTPUT_NAME" >/dev/null 2>&1; then
    echo "$FALLBACK_MULTI_OUTPUT_NAME"
    return
  fi
  echo "$RAW_OUTPUT_FALLBACK"
}

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
  echo "SwitchAudioSource is not installed."
  echo "Install with: brew install switchaudio-osx"
  exit 1
fi

if [[ -z "$SYSTEM_OUTPUT_DEVICE" ]]; then
  SYSTEM_OUTPUT_DEVICE="$(pick_default_output_device)"
fi

if ! SwitchAudioSource -a -t output | grep -Fx "$SYSTEM_OUTPUT_DEVICE" >/dev/null 2>&1; then
  echo "Output device '$SYSTEM_OUTPUT_DEVICE' not found."
  echo "Available outputs:"
  SwitchAudioSource -a -t output
  exit 1
fi

SwitchAudioSource -s "$SYSTEM_OUTPUT_DEVICE" -t output
echo "System output set to: $SYSTEM_OUTPUT_DEVICE"

if [[ "$AUTO_KEEPALIVE" == "1" ]]; then
  if [[ -x "$KEEPALIVE_SCRIPT" ]]; then
    "$KEEPALIVE_SCRIPT" start || true
  else
    echo "Keepalive script not found: $KEEPALIVE_SCRIPT"
  fi
fi

"$START_SCRIPT"

echo
echo "Current output:"
SwitchAudioSource -c -t output
