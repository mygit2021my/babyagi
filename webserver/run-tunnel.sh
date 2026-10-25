#!/usr/bin/env bash
# Foreground Cloudflare quick tunnel. Writes the public URL for the login page.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"
LOG="$ROOT/data/cloudflared.log"
URL_FILE="$ROOT/data/public-url.txt"

cloudflared tunnel --url http://127.0.0.1:8080 --protocol http2 --no-autoupdate >>"$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM

while kill -0 "$pid" 2>/dev/null; do
  url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$LOG" | tail -n 1 || true)"
  if [ -z "$url" ] && [ ! -f "$LOG" ] && [ -f /tmp/cloudflared-hello.log ]; then
    url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared-hello.log | tail -n 1 || true)"
  fi
  if [ -n "$url" ]; then
    printf '%s\n' "$url" >"$URL_FILE"
  fi
  sleep 1
done
wait "$pid"
