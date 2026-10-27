#!/usr/bin/env bash
# Tell a cloud server the current Cloudflare address.
# The server only gives that address to browsers and the app.
# Usage: bash use-vps.sh <公网IP> <令牌> [端口]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"

if [ "$#" -lt 2 ]; then
  echo "用法: bash use-vps.sh <公网IP> <令牌> [端口]" >&2
  exit 1
fi

ip="$1"
token="$2"
port="${3:-80}"
if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "公网 IP 格式不正确" >&2
  exit 1
fi
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
  echo "端口不正确" >&2
  exit 1
fi
if ! [[ "$token" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "令牌格式不正确" >&2
  exit 1
fi

if [ "$port" = "80" ]; then
  board="http://$ip/address"
  entry="http://$ip"
else
  board="http://$ip:$port/address"
  entry="http://$ip:$port"
fi

code="$(curl -4 -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "$board" || true)"
if [ "$code" != "200" ] && [ "$code" != "404" ]; then
  echo "还连不上 $entry 。请先在云服务器上运行 setup-addr.sh，并放行 TCP ${port}。当前隧道没有改动。" >&2
  exit 1
fi

addr_key=""
if [ -s "$ROOT/data/vps.conf" ]; then
  addr_key="$(awk -F= '$1 == "ADDR_KEY" { print substr($0, index($0, "=") + 1) }' "$ROOT/data/vps.conf" | tail -n 1)"
fi
if [ -z "$addr_key" ]; then
  addr_key="$(openssl rand -hex 32)"
fi

umask 077
cat >"$ROOT/data/vps.conf" <<EOF
VPS_IP=$ip
VPS_PORT=$port
ADDR_TOKEN=$token
ADDR_KEY=$addr_key
EOF
chmod 600 "$ROOT/data/vps.conf"

# An old fixed URL pointed browsers at the cloud server itself. The public
# address is the Cloudflare tunnel, which this file must not hide.
if [ -s "$ROOT/data/fixed-url.txt" ]; then
  fixed="$(tr -d '[:space:]' <"$ROOT/data/fixed-url.txt")"
  if [[ "$fixed" != https://* ]]; then
    rm -f "$ROOT/data/fixed-url.txt"
  fi
fi

# Restart only the tunnel process. boot.sh starts it again with the new config.
pkill -f '/frpc -c' || true
pkill -f '/webserver/run-tunnel\.sh' || true
sleep 1
pkill -9 -f '/frpc -c' || true
pkill -f 'cloudflared tunnel' || true
rm -f "$ROOT/data/tunnel.pid"

tmux_cmd=(tmux)
if [ -f /exec-daemon/tmux.portal.conf ]; then
  tmux_cmd=(tmux -f /exec-daemon/tmux.portal.conf)
fi
if ! pgrep -f '/webserver/boot\.sh' >/dev/null 2>&1; then
  if "${tmux_cmd[@]}" has-session -t gate-boot 2>/dev/null; then
    "${tmux_cmd[@]}" kill-session -t gate-boot || true
  fi
  "${tmux_cmd[@]}" new-session -d -s gate-boot -c "$ROOT" -- "$ROOT/boot.sh"
fi

echo "正在把 Cloudflare 地址告知 $entry"
for _ in $(seq 1 45); do
  got="$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$board" 2>/dev/null || true)"
  got="$(printf '%s' "$got" | tr -d '[:space:]')"
  if [[ "$got" =~ ^g1\.[A-Za-z0-9_-]+$ ]] || [[ "$got" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]]; then
    echo "固定入口: ${entry}/address"
    echo "App 从这里读取内容，解开后再访问沙箱上的网页。网页流量不经过云服务器。"
    exit 0
  fi
  sleep 2
done
echo "沙箱会继续重试，但 $entry 现在还没有地址。请确认云服务器已运行 setup-addr.sh，并且安全组放行了 TCP ${port}。" >&2
exit 1
