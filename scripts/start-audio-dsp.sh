#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
CONFIG="${CAMILLADSP_CONFIG:-$REPO_ROOT/dsp/config.yml}"
STATEFILE="${CAMILLADSP_STATEFILE:-$RUNTIME_DIR/state.json}"
LOGFILE="${CAMILLADSP_LOGFILE:-$RUNTIME_DIR/camilladsp.log}"
PIDFILE="${CAMILLADSP_PIDFILE:-$RUNTIME_DIR/camilladsp.pid}"
WS_ADDRESS="${CAMILLADSP_WS_ADDRESS:-127.0.0.1}"
WS_PORT="${CAMILLADSP_WS_PORT:-1234}"
CAMILLADSP_BIN="${CAMILLADSP_BIN:-}"

find_running_pid() {
  local regex
  local cmdline
  regex="$(printf '%s' "$CAMILLADSP_BIN" | sed 's/[][(){}.+*?^$|]/\\&/g')"
  while IFS= read -r pid; do
    cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -z "${cmdline:-}" ]] && continue
    [[ "$cmdline" == *" --check "* ]] && continue
    echo "$pid"
    return 0
  done < <(pgrep -f "^$regex( |$)" || true)
  return 1
}

if [[ -z "$CAMILLADSP_BIN" ]]; then
  if command -v camilladsp >/dev/null 2>&1; then
    CAMILLADSP_BIN="$(command -v camilladsp)"
  elif [[ -x "$HOME/.local/bin/camilladsp" ]]; then
    CAMILLADSP_BIN="$HOME/.local/bin/camilladsp"
  fi
fi

if [[ ! -x "$CAMILLADSP_BIN" ]]; then
  echo "camilladsp binary not found. Set CAMILLADSP_BIN or install camilladsp in PATH."
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "CamillaDSP config not found: $CONFIG"
  exit 1
fi

mkdir -p "$RUNTIME_DIR" "$(dirname "$PIDFILE")"

if [[ -f "$PIDFILE" ]]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "CamillaDSP already running (PID $pid)."
    exit 0
  fi
  rm -f "$PIDFILE"
fi

if pid="$(find_running_pid)"; then
  echo "$pid" > "$PIDFILE"
  echo "CamillaDSP already running (PID $pid)."
  exit 0
fi

if ! "$CAMILLADSP_BIN" --check "$CONFIG" >/dev/null 2>&1; then
  echo "Config check failed for $CONFIG"
  "$CAMILLADSP_BIN" --check "$CONFIG"
  exit 1
fi

nohup "$CAMILLADSP_BIN" \
  --loglevel info \
  --logfile "$LOGFILE" \
  --address "$WS_ADDRESS" \
  --port "$WS_PORT" \
  --statefile "$STATEFILE" \
  "$CONFIG" >/dev/null 2>&1 &

pid=$!
echo "$pid" > "$PIDFILE"
sleep 1

if kill -0 "$pid" 2>/dev/null; then
  echo "CamillaDSP started (PID $pid)."
  echo "Config: $CONFIG"
  echo "Log: $LOGFILE"
  echo "WebSocket: ws://$WS_ADDRESS:$WS_PORT"
  exit 0
fi

rm -f "$PIDFILE"
echo "CamillaDSP exited immediately. Check log: $LOGFILE"
exit 1
