#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
UI_ROOT="${CAMILLADSP_UI_ROOT:-$REPO_ROOT}"
UI_PORT="${CAMILLADSP_UI_PORT:-9137}"
UI_HOST="${CAMILLADSP_UI_HOST:-127.0.0.1}"
WS_ADDRESS="${CAMILLADSP_WS_ADDRESS:-127.0.0.1}"
WS_PORT="${CAMILLADSP_WS_PORT:-1234}"
PIDFILE="${CAMILLADSP_UI_PIDFILE:-$RUNTIME_DIR/ui-server.pid}"
LOGFILE="${CAMILLADSP_UI_LOGFILE:-$RUNTIME_DIR/ui-server.log}"

if [[ ! -f "$UI_ROOT/ui/control.html" ]]; then
  echo "UI file not found: $UI_ROOT/ui/control.html"
  exit 1
fi

mkdir -p "$RUNTIME_DIR" "$(dirname "$PIDFILE")"

if [[ -f "$PIDFILE" ]]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Control UI server already running (PID $pid)."
    echo "URL: http://$UI_HOST:$UI_PORT/ui/control.html?ws=ws://$WS_ADDRESS:$WS_PORT"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

nohup python3 -m http.server "$UI_PORT" --bind "$UI_HOST" --directory "$UI_ROOT" \
  >>"$LOGFILE" 2>&1 &

pid=$!
echo "$pid" > "$PIDFILE"
sleep 1

if kill -0 "$pid" 2>/dev/null; then
  echo "Control UI server started (PID $pid)."
  echo "URL: http://$UI_HOST:$UI_PORT/ui/control.html?ws=ws://$WS_ADDRESS:$WS_PORT"
  echo "Log: $LOGFILE"
  exit 0
fi

rm -f "$PIDFILE"
echo "Failed to start control UI server. Check log: $LOGFILE"
exit 1
