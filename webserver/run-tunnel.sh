#!/usr/bin/env bash
# Keep a public HTTPS address pointed at the local web service.
#
# Without extra files this is a Cloudflare Quick Tunnel. Its trycloudflare.com
# name is new every time this process starts, and that name cannot be reserved.
#
# A stable name needs a Cloudflare named tunnel on a domain you control:
#   webserver/data/tunnel.token    one line, the tunnel token from the dashboard
#   webserver/data/fixed-url.txt   one line, https://your.domain
# Both files stay out of git. Restarting cloudflared then keeps the same address.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"
LOG="$ROOT/data/cloudflared.log"
URL_FILE="$ROOT/data/public-url.txt"
TOKEN_FILE="$ROOT/data/tunnel.token"
FIXED_FILE="$ROOT/data/fixed-url.txt"

write_fixed_url() {
  [ -s "$FIXED_FILE" ] || return 1
  local fixed
  fixed="$(tr -d '[:space:]' <"$FIXED_FILE")"
  [[ "$fixed" == https://* ]] || return 1
  printf '%s\n' "$fixed" >"$URL_FILE"
}

if [ -s "$TOKEN_FILE" ]; then
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
