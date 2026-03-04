#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${CAMILLADSP_RUNTIME_DIR:-$REPO_ROOT/.runtime}"
PIDFILE="${CAMILLADSP_PIDFILE:-$RUNTIME_DIR/camilladsp.pid}"
CAMILLADSP_BIN="${CAMILLADSP_BIN:-}"

if [[ -z "$CAMILLADSP_BIN" ]]; then
  if command -v camilladsp >/dev/null 2>&1; then
    CAMILLADSP_BIN="$(command -v camilladsp)"
  elif [[ -x "$HOME/.local/bin/camilladsp" ]]; then
    CAMILLADSP_BIN="$HOME/.local/bin/camilladsp"
  fi
fi

stop_pid() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in {1..10}; do
      if ! kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
      sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

stopped=0

if [[ -f "$PIDFILE" ]]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]]; then
    stop_pid "$pid"
    stopped=1
  fi
  rm -f "$PIDFILE"
fi

regex="$(printf '%s' "$CAMILLADSP_BIN" | sed 's/[][(){}.+*?^$|]/\\&/g')"
while IFS= read -r pid; do
  [[ -n "${pid:-}" ]] || continue
  stop_pid "$pid"
  stopped=1
done < <(pgrep -f "^$regex( |$)" || true)

if [[ "$stopped" -eq 1 ]]; then
  echo "CamillaDSP stopped."
else
  echo "CamillaDSP was not running."
fi
