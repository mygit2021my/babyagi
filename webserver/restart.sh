#!/usr/bin/env bash
# Stop the web service, the tunnel, and the remote browsers, then start them again.
# A new tunnel receives a new public address. The installed Android app keeps its old address.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data" /tmp/gate-runtime
chmod 700 /tmp/gate-runtime || true

say() {
  printf '%s\n' "$*" >&2
}

kill_match() {
  local pattern="$1"
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    pkill -f "$pattern" || true
  fi
}

wait_gone() {
  local pattern="$1"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  pkill -9 -f "$pattern" || true
  sleep 0.2
}

stop_services() {
  # Stop the supervisor first so it does not start replacements during shutdown.
  kill_match '/webserver/boot\.sh'
  wait_gone '/webserver/boot\.sh'
  kill_match '/webserver/server\.py'
  kill_match '/webserver/run-tunnel\.sh'
  kill_match 'cloudflared tunnel --url http://127\.0\.0\.1:8080'
  kill_match 'user-data-dir=/tmp/gate-chrome'
  kill_match 'gate_audio\.monitor'
  kill_match 'gate_phone\.monitor'
  kill_match 'Xvfb :99 '
  kill_match 'Xvfb :100 '
  wait_gone '/webserver/server\.py'
  wait_gone '/webserver/run-tunnel\.sh'
  wait_gone 'cloudflared tunnel --url http://127\.0\.0\.1:8080'
  wait_gone 'user-data-dir=/tmp/gate-chrome'
  wait_gone 'gate_audio\.monitor'
  wait_gone 'gate_phone\.monitor'
  rm -f "$ROOT/data/web.pid" "$ROOT/data/tunnel.pid" "$ROOT/data/public-url.txt"
  : >"$ROOT/data/cloudflared.log"
}

start_services() {
  if [ -d /run/systemd/system ]; then
    sudo systemctl restart gate-web.service gate-tunnel.service
    return 0
  fi
  local tmux_cmd=(tmux)
  if [ -f /exec-daemon/tmux.portal.conf ]; then
    tmux_cmd=(tmux -f /exec-daemon/tmux.portal.conf)
  fi
  if "${tmux_cmd[@]}" has-session -t gate-boot 2>/dev/null; then
    "${tmux_cmd[@]}" kill-session -t gate-boot || true
  fi
  "${tmux_cmd[@]}" new-session -d -s gate-boot -c "$ROOT" -- "$ROOT/boot.sh"
}

wait_ready() {
  local i url
  for i in $(seq 1 90); do
    url=""
    if [ -f "$ROOT/data/public-url.txt" ]; then
      url="$(tr -d '[:space:]' <"$ROOT/data/public-url.txt")"
    fi
    if curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8080/login \
      && [[ "$url" == https://*.trycloudflare.com ]] \
      && curl -4 -skf -o /dev/null --max-time 8 "$url/login"; then
      printf '%s\n' "$url"
      return 0
    fi
    if [ $((i % 15)) -eq 0 ]; then
      say "仍在等待隧道地址生效"
    fi
    sleep 1
  done
  return 1
}

say "正在重启网页、隧道和远程浏览器"
stop_services
start_services
if url="$(wait_ready)"; then
  say "网页服务已启动"
  say "隧道已启动"
  say "当前访问地址: $url"
  say "手机里已经安装的应用仍使用旧地址。地址变化后需要重新打包才能打开。"
  exit 0
fi
say "重启未完成。请查看 $ROOT/data/web.log 和 $ROOT/data/cloudflared.log"
exit 1
