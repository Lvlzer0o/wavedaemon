#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-./dsp/config.yml}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config not found: $CONFIG_PATH"
  exit 1
fi

samplerate=$(awk '/^  samplerate:/ {print $2; exit}' "$CONFIG_PATH")
chunksize=$(awk '/^  chunksize:/ {print $2; exit}' "$CONFIG_PATH")
target_level=$(awk '/^  target_level:/ {print $2; exit}' "$CONFIG_PATH")

if [[ -z "${samplerate:-}" || -z "${chunksize:-}" || -z "${target_level:-}" ]]; then
  echo "Could not parse samplerate/chunksize/target_level from $CONFIG_PATH"
  exit 1
fi

python3 - "$samplerate" "$chunksize" "$target_level" <<'PY'
import sys
sr = float(sys.argv[1])
chunk = float(sys.argv[2])
target = float(sys.argv[3])
chunk_ms = chunk / sr * 1000.0
target_ms = target / sr * 1000.0
est_ms = chunk_ms + target_ms
print(f"samplerate   : {int(sr)} Hz")
print(f"chunksize    : {int(chunk)} samples  (~{chunk_ms:.2f} ms)")
print(f"target_level : {int(target)} samples  (~{target_ms:.2f} ms)")
print(f"rough buffer latency estimate: ~{est_ms:.2f} ms")
PY
