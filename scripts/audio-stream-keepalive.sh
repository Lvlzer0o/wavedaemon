#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
ACTION="${1:-start}"
PIDFILE="${CAMILLADSP_KEEPALIVE_PIDFILE:-$RUNTIME_DIR/keepalive.pid}"
LOGFILE="${CAMILLADSP_KEEPALIVE_LOGFILE:-$RUNTIME_DIR/keepalive.log}"
SILENCE_WAV="${CAMILLADSP_KEEPALIVE_WAV:-$RUNTIME_DIR/keepalive_silence_60s.wav}"

mkdir -p "$(dirname "$PIDFILE")"

generate_silence_file() {
  if [[ -f "$SILENCE_WAV" ]]; then
    return 0
  fi
  python3 - <<PY
import wave
import struct
path = "${SILENCE_WAV}"
samplerate = 48000
seconds = 60
samples = samplerate * seconds
with wave.open(path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(samplerate)
    frame = struct.pack("<hh", 0, 0)
    chunk = frame * 4096
    remaining = samples
    while remaining > 0:
        n = min(remaining, 4096)
        w.writeframes(chunk[: n * 4])
        remaining -= n
PY
}

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "${pid:-}" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

run_loop() {
  generate_silence_file
  while true; do
    afplay -v 0 "$SILENCE_WAV" >/dev/null 2>&1 || sleep 1
  done
}

case "$ACTION" in
  start)
    if is_running; then
      pid="$(cat "$PIDFILE")"
      echo "Keepalive already running (PID $pid)."
      exit 0
    fi
    nohup "$0" run >>"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      echo "Keepalive started (PID $pid)."
      exit 0
    fi
    rm -f "$PIDFILE"
    echo "Failed to start keepalive. Check log: $LOGFILE"
    exit 1
    ;;
  stop)
    if is_running; then
      pid="$(cat "$PIDFILE")"
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$PIDFILE"
      echo "Keepalive stopped."
      exit 0
    fi
    rm -f "$PIDFILE"
    echo "Keepalive was not running."
    ;;
  status)
    if is_running; then
      pid="$(cat "$PIDFILE")"
      echo "running (PID $pid)"
    else
      echo "stopped"
    fi
    ;;
  run)
    run_loop
    ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
