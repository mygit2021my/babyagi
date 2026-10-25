#!/usr/bin/env bash
# Offline installer for a cloud server that only hands out the Cloudflare address.
# Copy this directory to the server, then: sudo bash setup-addr.sh
set -euo pipefail

say() {
  printf '%s\n' "$*"
}

say "开始安装地址入口（不转发网页流量，不访问外网）"

if [ "$(id -u)" -ne 0 ]; then
  say "请用 root 运行: sudo bash setup-addr.sh"
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64) bin_arch=amd64 ;;
  aarch64) bin_arch=arm64 ;;
  *) say "不支持的系统架构: $arch"; exit 1 ;;
esac

name="gate-addr-linux-${bin_arch}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
binary=""
for candidate in "$script_dir/$name" "$script_dir/offline/$name"; do
  if [ -f "$candidate" ]; then
    binary="$candidate"
    break
  fi
done
if [ -z "$binary" ]; then
  say "找不到 $name"
  say "请把程序和本脚本放在同一个目录后再运行。"
  exit 1
fi

say "正在安装 $name"
install -m 755 "$binary" /usr/local/bin/gate-addr

if [ -d /run/systemd/system ] && systemctl list-unit-files gate-frps.service >/dev/null 2>&1; then
  say "正在停掉原来的流量转发"
  systemctl disable --now gate-frps.service >/dev/null 2>&1 || true
fi

install -d -m 755 /etc/gate-addr /var/lib/gate-addr
if [ ! -s /etc/gate-addr/token ]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24 >/etc/gate-addr/token
  else
    od -An -tx1 -N24 /dev/urandom | tr -d ' \n' >/etc/gate-addr/token
  fi
  chmod 600 /etc/gate-addr/token
fi
token="$(tr -d '[:space:]' </etc/gate-addr/token)"

port=80
if command -v ss >/dev/null 2>&1 && ss -ltn | awk '{print $4}' | grep -Eq '(:80$|]:80$)'; then
  port=8080
fi
if [ "$port" = "8080" ] && command -v ss >/dev/null 2>&1 && ss -ltn | awk '{print $4}' | grep -Eq '(:8080$|]:8080$)'; then
  port=18080
fi
say "地址入口使用端口 ${port}"

if [ -d /run/systemd/system ]; then
  say "正在设置开机自启服务 gate-addr"
  cat >/etc/systemd/system/gate-addr.service <<EOF
[Unit]
Description=Gate address board
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/gate-addr -listen 0.0.0.0:${port} -token-file /etc/gate-addr/token -url-file /var/lib/gate-addr/url
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now gate-addr.service
  systemctl --no-pager --full status gate-addr || true
else
  say "这台机器没有 systemd，只在当前这次开机中启动"
  pkill -f '/usr/local/bin/gate-addr -listen' || true
  setsid /usr/local/bin/gate-addr -listen "0.0.0.0:${port}" -token-file /etc/gate-addr/token -url-file /var/lib/gate-addr/url >/var/log/gate-addr.log 2>&1 </dev/null &
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  say "正在放行本机防火墙"
  ufw allow "${port}/tcp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  say "正在放行 firewalld"
  firewall-cmd --permanent --add-port="${port}/tcp" || true
  firewall-cmd --reload || true
fi

say
say "地址入口已启动。这台机器不能访问外网，下面的 VPS_IP 请改成控制台里的公网 IP。"
say "在沙箱执行: bash webserver/use-vps.sh 公网IP ${token} ${port}"
say "VPS_IP=这里填公网IP"
say "VPS_PORT=${port}"
say "ADDR_TOKEN=${token}"
say
say "安全组只需放行 TCP ${port}。浏览器打开 http://公网IP 时只会看到加密后的乱码，解密口令不在这台机器上。"
