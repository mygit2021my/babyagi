#!/usr/bin/env bash
# Publish the local web service.
#
# Stable address, no domain required: a cloud server with a fixed public IP.
#   webserver/data/vps.conf    written by use-vps.sh, not committed
# The cloud server runs webserver/vps/setup-frps.sh. This machine connects out
# to it, and visitors use http://that-ip .
#
# Otherwise this is a Cloudflare Quick Tunnel. That trycloudflare.com name
# changes every time the process starts and cannot be reserved.
# A Cloudflare named tunnel still works if these gitignored files exist:
#   webserver/data/tunnel.token
#   webserver/data/fixed-url.txt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"
LOG="$ROOT/data/cloudflared.log"
URL_FILE="$ROOT/data/public-url.txt"
TOKEN_FILE="$ROOT/data/tunnel.token"
FIXED_FILE="$ROOT/data/fixed-url.txt"
VPS_CONF="$ROOT/data/vps.conf"
FRPC_CONF="$ROOT/data/frpc.toml"

exec 8>>"$ROOT/data/tunnel.lock"
if ! flock -n 8; then
  exit 0
fi

valid_url() {
  [[ "$1" =~ ^https?://[A-Za-z0-9.:_-]+$ ]]
}

write_fixed_url() {
  [ -s "$FIXED_FILE" ] || return 1
  local fixed
  fixed="$(tr -d '[:space:]' <"$FIXED_FILE")"
  valid_url "$fixed" || return 1
  printf '%s\n' "$fixed" >"$URL_FILE"
}

start_frpc() {
  # shellcheck disable=SC1090
  source "$VPS_CONF"
  : "${VPS_IP:?}"
  : "${VPS_PORT:?}"
  : "${FRP_SERVER_PORT:?}"
  : "${FRP_TOKEN:?}"
  local frpc="${FRPC:-frpc}"
  if ! command -v "$frpc" >/dev/null 2>&1; then
    echo "frpc is not installed" >>"$LOG"
    exit 1
  fi
  umask 077
  cat >"$FRPC_CONF" <<EOF
serverAddr = "$VPS_IP"
serverPort = $FRP_SERVER_PORT
auth.method = "token"
auth.token = "$FRP_TOKEN"
loginFailExit = false

[[proxies]]
name = "gate"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = $VPS_PORT
EOF
  if [ "$VPS_PORT" = "80" ]; then
    printf 'http://%s\n' "$VPS_IP" >"$FIXED_FILE"
  else
    printf 'http://%s:%s\n' "$VPS_IP" "$VPS_PORT" >"$FIXED_FILE"
  fi
  write_fixed_url || true
  "$frpc" -c "$FRPC_CONF" >>"$LOG" 2>&1 &
}

if [ -s "$VPS_CONF" ]; then
  start_frpc
elif [ -s "$TOKEN_FILE" ]; then
  write_fixed_url || true
  cloudflared tunnel --no-autoupdate --protocol http2 run --token-file "$TOKEN_FILE" >>"$LOG" 2>&1 &
else
  cloudflared tunnel --url http://127.0.0.1:8080 --protocol http2 --no-autoupdate >>"$LOG" 2>&1 &
fi
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM

while kill -0 "$pid" 2>/dev/null; do
  if ! write_fixed_url; then
    url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$LOG" | tail -n 1 || true)"
    if [ -z "$url" ] && [ ! -s "$LOG" ] && [ -f /tmp/cloudflared-hello.log ]; then
      url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared-hello.log | tail -n 1 || true)"
    fi
    if [ -n "$url" ]; then
      printf '%s\n' "$url" >"$URL_FILE"
    fi
  fi
  sleep 1
done
wait "$pid"
