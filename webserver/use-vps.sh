#!/usr/bin/env bash
# Point the public address at a cloud server with a fixed IP.
# Usage: bash use-vps.sh <公网IP> <令牌> [网页端口]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"

if [ "$#" -lt 2 ]; then
  echo "用法: bash use-vps.sh <公网IP> <令牌> [网页端口]" >&2
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

umask 077
cat >"$ROOT/data/vps.conf" <<EOF
VPS_IP=$ip
VPS_PORT=$port
FRP_SERVER_PORT=7000
FRP_TOKEN=$token
EOF
chmod 600 "$ROOT/data/vps.conf"

# The supervisor restarts the tunnel from the new config. A Quick Tunnel name
# is abandoned on purpose: the fixed IP replaces it.
pkill -f '/webserver/boot\.sh' || true
pkill -f '/webserver/run-tunnel\.sh' || true
pkill -f 'cloudflared tunnel' || true
pkill -f '/frpc -c' || true
sleep 1
pkill -9 -f 'cloudflared tunnel' || true
pkill -9 -f '/frpc -c' || true
rm -f "$ROOT/data/tunnel.pid" "$ROOT/data/fixed-url.txt"

tmux_cmd=(tmux)
if [ -f /exec-daemon/tmux.portal.conf ]; then
  tmux_cmd=(tmux -f /exec-daemon/tmux.portal.conf)
fi
if "${tmux_cmd[@]}" has-session -t gate-boot 2>/dev/null; then
  "${tmux_cmd[@]}" kill-session -t gate-boot || true
fi
"${tmux_cmd[@]}" new-session -d -s gate-boot -c "$ROOT" -- "$ROOT/boot.sh"

if [ "$port" = "80" ]; then
  url="http://$ip"
else
  url="http://$ip:$port"
fi
echo "正在连接 $url"
for _ in $(seq 1 40); do
  if curl -4 -sf -o /dev/null --max-time 5 "$url/login"; then
    echo "固定访问地址: $url"
    exit 0
  fi
  sleep 1
done
echo "沙箱已改用这台云服务器，但 $url 还打不开。请确认安全组放行了网页端口和 7000。" >&2
exit 1
