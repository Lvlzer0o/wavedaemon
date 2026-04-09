#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
PREVIOUS_OUTPUT_STATEFILE="${CAMILLADSP_PREVIOUS_OUTPUT_STATEFILE:-$RUNTIME_DIR/previous_output_device}"
SYSTEM_OUTPUT_DEVICE="${1:-}"
STOP_SCRIPT="${SCRIPT_DIR}/stop-audio-dsp.sh"
KEEPALIVE_SCRIPT="${SCRIPT_DIR}/audio-stream-keepalive.sh"
AUTO_KEEPALIVE="${CAMILLADSP_AUTO_KEEPALIVE:-0}"

if [[ -z "$SYSTEM_OUTPUT_DEVICE" && -f "$PREVIOUS_OUTPUT_STATEFILE" ]]; then
  SYSTEM_OUTPUT_DEVICE="$(cat "$PREVIOUS_OUTPUT_STATEFILE" 2>/dev/null || true)"
fi

if [[ -z "$SYSTEM_OUTPUT_DEVICE" ]]; then
  SYSTEM_OUTPUT_DEVICE="${CAMILLADSP_STOP_OUTPUT_DEVICE:-Built-in Output}"
fi

"$STOP_SCRIPT"

if [[ "$AUTO_KEEPALIVE" == "1" ]] && [[ -x "$KEEPALIVE_SCRIPT" ]]; then
  "$KEEPALIVE_SCRIPT" stop || true
fi

if command -v SwitchAudioSource >/dev/null 2>&1; then
  if SwitchAudioSource -a -t output | grep -Fx "$SYSTEM_OUTPUT_DEVICE" >/dev/null 2>&1; then
    SwitchAudioSource -s "$SYSTEM_OUTPUT_DEVICE" -t output
    echo "System output set to: $SYSTEM_OUTPUT_DEVICE"
  else
    echo "Output device '$SYSTEM_OUTPUT_DEVICE' not found. Leaving current output unchanged."
  fi
else
  echo "SwitchAudioSource is not installed; output device unchanged."
fi

rm -f "$PREVIOUS_OUTPUT_STATEFILE"
