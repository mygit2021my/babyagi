#!/usr/bin/env bash
# Restart the web service and the remote browsers.
# A tunnel whose name still answers is left running. A dead Quick Tunnel
# (hostname gone, or the process still up but Cloudflare rejected it) is
# replaced. The cloud server IP and token stay in data/vps.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data" /tmp/gate-runtime
chmod 700 /tmp/gate-runtime || true

conf_value() {
  local key="$1"
  [ -s "$ROOT/data/vps.conf" ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$ROOT/data/vps.conf" | tail -n 1
}

vps_entry() {
  local ip port
  ip="$(conf_value VPS_IP)"
  port="$(conf_value VPS_PORT)"
  [ -n "$ip" ] || return 0
  port="${port:-80}"
  if [ "$port" = "80" ]; then
    printf 'http://%s\n' "$ip"
  else
    printf 'http://%s:%s\n' "$ip" "$port"
  fi
}

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
  kill_match 'user-data-dir=/tmp/gate-chrome'
  kill_match 'gate_audio\.monitor'
  kill_match 'gate_phone\.monitor'
  kill_match 'Xvfb :99 '
  kill_match 'Xvfb :100 '
  wait_gone '/webserver/server\.py'
  wait_gone 'user-data-dir=/tmp/gate-chrome'
  wait_gone 'gate_audio\.monitor'
  wait_gone 'gate_phone\.monitor'
  rm -f "$ROOT/data/web.pid"
}

start_services() {
  if [ -d /run/systemd/system ]; then
    sudo systemctl restart gate-web.service
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

read_public_url() {
  if [ -f "$ROOT/data/public-url.txt" ]; then
    tr -d '[:space:]' <"$ROOT/data/public-url.txt"
  fi
}

public_answers() {
  local url="$1"
  [[ "$url" == https://* ]] || return 1
  curl -4 -skf -o /dev/null --max-time 8 "$url/login"
}

# A dead quick-tunnel process keeps running and retrying a name Cloudflare
# has already dropped. Replace it so boot.sh can publish a new name.
# Rotate the log first: the old process keeps its file descriptor, and the
# replacement must not republish the dead name from the previous log.
replace_dead_tunnel() {
  say "当前隧道地址已失效，正在更换"
  if [ -f "$ROOT/data/cloudflared.log" ]; then
    mv -f "$ROOT/data/cloudflared.log" "$ROOT/data/cloudflared.log.prev"
  fi
  echo "tunnel log rotated $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$ROOT/data/cloudflared.log"
  kill_match '/webserver/run-tunnel\.sh'
  kill_match 'cloudflared tunnel'
  wait_gone '/webserver/run-tunnel\.sh'
  wait_gone 'cloudflared tunnel'
  rm -f "$ROOT/data/tunnel.pid"
}

wait_ready() {
  local i url old="" named=0
  old="$(read_public_url || true)"
  for i in $(seq 1 40); do
    if curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8080/login; then
      break
    fi
    if [ "$i" -eq 40 ]; then
      return 1
    fi
    sleep 1
  done
  if public_answers "$old"; then
    printf '%s\n' "$old"
    return 0
  fi
  if [ -s "$ROOT/data/fixed-url.txt" ]; then
    named=1
  fi
  replace_dead_tunnel
  for i in $(seq 1 90); do
    url="$(read_public_url || true)"
    if { [ "$named" -eq 1 ] || [ "$url" != "$old" ]; } && public_answers "$url"; then
      printf '%s\n' "$url"
      return 0
    fi
    if [ $((i % 15)) -eq 0 ]; then
      say "仍在等待新的隧道地址生效"
    fi
    sleep 1
  done
  return 1
}

entry="$(vps_entry || true)"
token="$(conf_value ADDR_TOKEN || true)"
if [ -z "$entry" ] || [ -z "$token" ]; then
  say "data/vps.conf 里还没有云服务器 IP 或令牌。网页仍会重启，固定入口不会更新。"
else
  say "固定入口: ${entry}/address"
  say "云服务器 IP 和令牌从 data/vps.conf 读取，这次不需要重新填写。"
fi
say "正在重启网页和远程浏览器。隧道地址有效则保持不变。"
stop_services
start_services
if url="$(wait_ready)"; then
  say "网页服务已启动"
  say "Cloudflare 地址: $url"
  if [ -n "$entry" ] && [ -n "$token" ]; then
    board="${entry}/address"
    got=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      got="$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$board" 2>/dev/null || true)"
      got="$(printf '%s' "$got" | tr -d '[:space:]')"
        plain=""
      key="$(conf_value ADDR_KEY || true)"
      seal=""
      case "$(uname -m)" in
        x86_64) seal="$ROOT/vps/offline/gate-seal-linux-amd64" ;;
        aarch64) seal="$ROOT/vps/offline/gate-seal-linux-arm64" ;;
      esac
      if [ -n "$key" ] && [ -x "$seal" ]; then
        plain="$("$seal" decrypt "$key" "$got" 2>/dev/null || true)"
      fi
      if [ "$plain" = "$url" ] || [ "$got" = "$url" ]; then
        break
      fi
      sleep 2
    done
    if [ "$plain" = "$url" ]; then
      say "云服务器 /address 已是当前内容。请用 App 打开 ${entry}"
    elif [ "$got" = "$url" ]; then
      say "云服务器 /address 返回的是明文地址。请先在云服务器上重新运行 setup-addr.sh"
    else
      say "云服务器上的地址还没有换成当前隧道。沙箱会继续上报。"
    fi
  fi
  exit 0
fi
say "重启未完成。请查看 $ROOT/data/web.log 和 $ROOT/data/cloudflared.log"
exit 1
