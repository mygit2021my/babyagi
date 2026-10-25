#!/usr/bin/env bash
# Keep the web service and the tunnel running.
# On a machine whose init is systemd, the unit files own the processes.
# This sandbox's init is not systemd, so this loop is what starts them on boot.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data" /tmp/gate-runtime
chmod 700 /tmp/gate-runtime || true
cd "$ROOT"

exec 9>>"$ROOT/data/boot.lock"
if ! flock -n 9; then
  echo "gate boot is already running"
  exit 0
fi

if [ -d /run/systemd/system ]; then
  sudo systemctl enable --now gate-web.service gate-tunnel.service
  exit 0
fi

web_up() {
  curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8080/login
}

tunnel_up() {
  pgrep -f 'cloudflared tunnel --url http://127.0.0.1:8080' >/dev/null 2>&1
}

alive() {
  local pidfile="$1"
  [ -f "$pidfile" ] || return 1
  kill -0 "$(cat "$pidfile")" 2>/dev/null
}

start_web() {
  if web_up || alive "$ROOT/data/web.pid"; then
    return 0
  fi
  echo "starting web $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$ROOT/data/web.log"
  python3 "$ROOT/server.py" >>"$ROOT/data/web.log" 2>&1 &
  echo $! >"$ROOT/data/web.pid"
}

publish_url() {
  local url=""
  if [ -f "$ROOT/data/cloudflared.log" ]; then
    url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$ROOT/data/cloudflared.log" | tail -n 1 || true)"
  fi
  if [ -z "$url" ] && [ -f /tmp/cloudflared-hello.log ]; then
    url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared-hello.log | tail -n 1 || true)"
  fi
  if [ -n "$url" ]; then
    printf '%s\n' "$url" >"$ROOT/data/public-url.txt"
  fi
}

start_tunnel() {
  if tunnel_up || alive "$ROOT/data/tunnel.pid"; then
    return 0
  fi
  echo "starting tunnel $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$ROOT/data/cloudflared.log"
  "$ROOT/run-tunnel.sh" >>"$ROOT/data/cloudflared.log" 2>&1 &
  echo $! >"$ROOT/data/tunnel.pid"
}

while true; do
  start_web || true
  start_tunnel || true
  publish_url || true
  sleep 2
done
