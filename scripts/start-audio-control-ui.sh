#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/camilladsp-ws-env.sh"

RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
UI_ROOT="${CAMILLADSP_UI_ROOT:-$REPO_ROOT}"
UI_PORT="${CAMILLADSP_UI_PORT:-9137}"
UI_HOST="${CAMILLADSP_UI_HOST:-127.0.0.1}"
CLIENT_WS_URL="$(camilladsp_client_ws_url)"
PIDFILE="${CAMILLADSP_UI_PIDFILE:-$RUNTIME_DIR/ui-server.pid}"
LOGFILE="${CAMILLADSP_UI_LOGFILE:-$RUNTIME_DIR/ui-server.log}"

build_ui_url() {
  local encoded_ws

  if command -v python3 >/dev/null 2>&1; then
    encoded_ws="$(python3 - "$CLIENT_WS_URL" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
)"
  else
    encoded_ws="$CLIENT_WS_URL"
  fi

  printf 'http://%s:%s/ui/control.html?ws=%s\n' "$UI_HOST" "$UI_PORT" "$encoded_ws"
}

if [[ ! -f "$UI_ROOT/ui/control.html" ]]; then
  echo "UI file not found: $UI_ROOT/ui/control.html"
  exit 1
fi

mkdir -p "$RUNTIME_DIR" "$(dirname "$PIDFILE")"

if [[ -f "$PIDFILE" ]]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Control UI server already running (PID $pid)."
    echo "WebSocket target: $CLIENT_WS_URL"
    echo "URL: $(build_ui_url)"
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
  echo "WebSocket target: $CLIENT_WS_URL"
  echo "URL: $(build_ui_url)"
  echo "Log: $LOGFILE"
  exit 0
fi

rm -f "$PIDFILE"
echo "Failed to start control UI server. Check log: $LOGFILE"
exit 1
