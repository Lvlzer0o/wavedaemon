#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_OUTPUT_DEVICE="${1:-${CAMILLADSP_STOP_OUTPUT_DEVICE:-Built-in Output}}"
STOP_SCRIPT="${SCRIPT_DIR}/stop-audio-dsp.sh"
KEEPALIVE_SCRIPT="${SCRIPT_DIR}/audio-stream-keepalive.sh"
AUTO_KEEPALIVE="${CAMILLADSP_AUTO_KEEPALIVE:-0}"

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
