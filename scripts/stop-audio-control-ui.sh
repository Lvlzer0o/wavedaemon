#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
PIDFILE="${CAMILLADSP_UI_PIDFILE:-$RUNTIME_DIR/ui-server.pid}"

stopped=0

if [[ -f "$PIDFILE" ]]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    stopped=1
  fi
  rm -f "$PIDFILE"
fi

if [[ "$stopped" -eq 1 ]]; then
  echo "Control UI server stopped."
else
  echo "Control UI server was not running."
fi
