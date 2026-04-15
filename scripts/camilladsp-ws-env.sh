#!/usr/bin/env bash

camilladsp_trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

camilladsp_valid_port() {
  local value
  value="$(camilladsp_trim "${1-}")"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

camilladsp_legacy_ws_address() {
  local value
  value="$(camilladsp_trim "${CAMILLADSP_WS_ADDRESS:-}")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '127.0.0.1\n'
}

camilladsp_legacy_ws_port() {
  local value
  value="$(camilladsp_trim "${CAMILLADSP_WS_PORT:-}")"
  if camilladsp_valid_port "$value"; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '1234\n'
}

camilladsp_bind_address() {
  local value
  value="$(camilladsp_trim "${CAMILLADSP_BIND_ADDRESS:-}")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  camilladsp_legacy_ws_address
}

camilladsp_bind_port() {
  local value
  value="$(camilladsp_trim "${CAMILLADSP_BIND_PORT:-}")"
  if camilladsp_valid_port "$value"; then
    printf '%s\n' "$value"
    return 0
  fi
  camilladsp_legacy_ws_port
}

camilladsp_client_ws_url() {
  local value
  value="$(camilladsp_trim "${CAMILLADSP_CLIENT_WS_URL:-}")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf 'ws://%s:%s\n' "$(camilladsp_legacy_ws_address)" "$(camilladsp_legacy_ws_port)"
}

camilladsp_probe_host() {
  local value normalized
  value="$(camilladsp_trim "${1-}")"
  normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized" == "0.0.0.0" || "$normalized" == "*" ]]; then
    printf '127.0.0.1\n'
    return 0
  fi
  if [[ "$normalized" == "::" ]]; then
    printf '::1\n'
    return 0
  fi
  printf '%s\n' "$value"
}
