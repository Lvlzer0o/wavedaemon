#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/camilladsp-ws-env.sh"

RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
CONFIG="${CAMILLADSP_CONFIG:-$REPO_ROOT/dsp/config.yml}"
STATEFILE="${CAMILLADSP_STATEFILE:-$RUNTIME_DIR/state.json}"
LOGFILE="${CAMILLADSP_LOGFILE:-$RUNTIME_DIR/camilladsp.log}"
PIDFILE="${CAMILLADSP_PIDFILE:-$RUNTIME_DIR/camilladsp.pid}"
WS_BIND_ADDRESS="$(camilladsp_bind_address)"
WS_BIND_PORT="$(camilladsp_bind_port)"
WS_PROBE_HOST="$(camilladsp_probe_host "$WS_BIND_ADDRESS")"
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

is_pid_listening_on_ws_port() {
  local pid="$1"
  local listening_pids

  listening_pids="$(lsof -nP -tiTCP:"$WS_BIND_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "${listening_pids:-}" ]] && return 1
  printf '%s\n' "$listening_pids" | grep -Fx "$pid" >/dev/null 2>&1
}

find_ws_port_owner_pid() {
  lsof -nP -tiTCP:"$WS_BIND_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
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
    if is_pid_listening_on_ws_port "$pid"; then
      echo "CamillaDSP already running (PID $pid)."
      exit 0
    fi
    echo "CamillaDSP startup already in progress (PID $pid)."
    exit 0
  fi
  rm -f "$PIDFILE"
fi

if pid="$(find_running_pid)"; then
  if is_pid_listening_on_ws_port "$pid"; then
    echo "$pid" > "$PIDFILE"
    echo "CamillaDSP already running (PID $pid)."
    exit 0
  fi
  echo "$pid" > "$PIDFILE"
  echo "CamillaDSP process is running (PID $pid) but WebSocket port $WS_BIND_PORT is not listening yet."
  echo "Treating startup as in progress; try again in a moment."
  exit 0
fi

port_owner_pid="$(find_ws_port_owner_pid)"
if [[ -n "${port_owner_pid:-}" ]]; then
  port_owner_cmd="$(ps -p "$port_owner_pid" -o command= 2>/dev/null || true)"
  echo "WebSocket bind port $WS_BIND_PORT is already in use by PID $port_owner_pid${port_owner_cmd:+ ($port_owner_cmd)}."
  exit 1
fi

if ! "$CAMILLADSP_BIN" --check "$CONFIG" >/dev/null 2>&1; then
  echo "Config check failed for $CONFIG"
  "$CAMILLADSP_BIN" --check "$CONFIG"
  exit 1
fi

cd "$REPO_ROOT"
nohup "$CAMILLADSP_BIN" \
  --loglevel info \
  --logfile "$LOGFILE" \
  --address "$WS_BIND_ADDRESS" \
  --port "$WS_BIND_PORT" \
  --statefile "$STATEFILE" \
  "$CONFIG" >/dev/null 2>&1 &

pid=$!
echo "$pid" > "$PIDFILE"

for _ in $(seq 1 50); do
  if is_pid_listening_on_ws_port "$pid"; then
    echo "CamillaDSP started (PID $pid)."
    echo "Config: $CONFIG"
    echo "Log: $LOGFILE"
    echo "WebSocket bind: $WS_BIND_ADDRESS:$WS_BIND_PORT"
    if [[ "$WS_PROBE_HOST" != "$WS_BIND_ADDRESS" ]]; then
      echo "Local readiness probe: ws://$WS_PROBE_HOST:$WS_BIND_PORT"
    fi
    exit 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PIDFILE"
    echo "CamillaDSP exited during startup. Tail of log:"
    tail -n 120 "$LOGFILE" || true
    exit 1
  fi

  sleep 0.1
done

if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
rm -f "$PIDFILE"

echo "CamillaDSP is running but WebSocket never opened on local probe ws://$WS_PROBE_HOST:$WS_BIND_PORT (bind: $WS_BIND_ADDRESS:$WS_BIND_PORT)."
echo "Tail of log:"
tail -n 120 "$LOGFILE" || true
exit 1
