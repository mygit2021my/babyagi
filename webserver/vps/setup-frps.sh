#!/usr/bin/env bash
# Run this on the cloud server that has a fixed public IP.
# It listens on that IP and forwards one port to the sandbox.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行: sudo bash setup-frps.sh" >&2
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64) frp_arch=amd64 ;;
  aarch64) frp_arch=arm64 ;;
  *) echo "不支持的系统架构: $arch" >&2; exit 1 ;;
esac

ver=0.71.1
if [ ! -x /usr/local/bin/frps ]; then
  curl -fsSL -o /tmp/frp.tgz \
    "https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${frp_arch}.tar.gz"
  tar -C /tmp -xzf /tmp/frp.tgz
  install -m 755 "/tmp/frp_${ver}_linux_${frp_arch}/frps" /usr/local/bin/frps
fi

install -d -m 700 /etc/gate-frp
if [ ! -s /etc/gate-frp/token ]; then
  openssl rand -hex 24 >/etc/gate-frp/token
  chmod 600 /etc/gate-frp/token
fi
token="$(tr -d '[:space:]' </etc/gate-frp/token)"

port=80
if command -v ss >/dev/null 2>&1 && ss -ltn | awk '{print $4}' | grep -Eq '(:80$|]:80$)'; then
  port=8080
fi
if [ "$port" = "8080" ] && command -v ss >/dev/null 2>&1 && ss -ltn | awk '{print $4}' | grep -Eq '(:8080$|]:8080$)'; then
  port=18080
fi

cat >/etc/gate-frp/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000
auth.method = "token"
auth.token = "$token"
allowPorts = [
  { single = $port }
]
EOF
chmod 600 /etc/gate-frp/frps.toml

if [ -d /run/systemd/system ]; then
  cat >/etc/systemd/system/gate-frps.service <<'EOF'
[Unit]
Description=Gate public entry
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/frps -c /etc/gate-frp/frps.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now gate-frps.service
else
  pkill -f '/usr/local/bin/frps -c /etc/gate-frp/frps.toml' || true
  setsid /usr/local/bin/frps -c /etc/gate-frp/frps.toml >/var/log/gate-frps.log 2>&1 </dev/null &
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  ufw allow "${port}/tcp" || true
  ufw allow 7000/tcp || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${port}/tcp" || true
  firewall-cmd --permanent --add-port=7000/tcp || true
  firewall-cmd --reload || true
fi

ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me || true)"
if [ -z "$ip" ]; then
  ip="把这里换成这台机器的公网IP"
fi

echo
echo "云服务器入口已启动。请把下面四行保存到沙箱的 webserver/data/vps.conf"
echo "VPS_IP=${ip}"
echo "VPS_PORT=${port}"
echo "FRP_SERVER_PORT=7000"
echo "FRP_TOKEN=${token}"
echo
echo "还要在云服务器的安全组里放行 TCP ${port} 和 TCP 7000。"
echo "放行之后，固定访问地址是: http://${ip}$([ "$port" = 80 ] || echo ":${port}")"
