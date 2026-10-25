#!/usr/bin/env bash
# Run this on the cloud server that has a fixed public IP.
# It listens on that IP and forwards one port to the sandbox.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

say() {
  printf '%s\n' "$*"
}

say "开始安装固定入口"

if [ "$(id -u)" -ne 0 ]; then
  say "请用 root 运行: sudo bash setup-frps.sh"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  say "缺少 curl，请先安装: apt-get install -y curl ca-certificates"
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  say "缺少 openssl，请先安装: apt-get install -y openssl"
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64) frp_arch=amd64; frp_sha=1d9875210972a5d1a62b2dc4c48df45ab0af05d3ca1b5e494a014428259df803 ;;
  aarch64) frp_arch=arm64; frp_sha=8edf590b0c396fa42f9c147121a76af83cfc2002b08f5aef0ea1008c43482019 ;;
  *) say "不支持的系统架构: $arch"; exit 1 ;;
esac

ver=0.71.1
if [ ! -x /usr/local/bin/frps ]; then
  name="frp_${ver}_linux_${frp_arch}.tar.gz"
  url="https://github.com/fatedier/frp/releases/download/v${ver}/${name}"
  say "正在从 GitHub 下载 ${name}。若这里停很久，说明这台机器访问 GitHub 不通。"
  rm -f /tmp/frp.tgz
  if ! curl -fL --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 -o /tmp/frp.tgz "$url"; then
    say "GitHub 下载失败。请在这台机器上执行: curl -I --max-time 20 ${url}"
    exit 1
  fi
  got="$(sha256sum /tmp/frp.tgz | awk '{print $1}')"
  if [ "$got" != "$frp_sha" ]; then
    say "下载文件校验失败，已停止安装。"
    exit 1
  fi
  say "下载完成，正在安装 frps"
  tar -C /tmp -xzf /tmp/frp.tgz
  install -m 755 "/tmp/frp_${ver}_linux_${frp_arch}/frps" /usr/local/bin/frps
else
  say "已有 /usr/local/bin/frps，跳过下载"
fi

say "正在写入配置"
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
say "网页端口使用 ${port}"

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
  say "正在设置开机自启服务 gate-frps"
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
  systemctl --no-pager --full status gate-frps || true
else
  say "这台机器没有 systemd，只在当前这次开机中启动"
  pkill -f '/usr/local/bin/frps -c /etc/gate-frp/frps.toml' || true
  setsid /usr/local/bin/frps -c /etc/gate-frp/frps.toml >/var/log/gate-frps.log 2>&1 </dev/null &
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  say "正在放行本机防火墙"
  ufw allow "${port}/tcp" || true
  ufw allow 7000/tcp || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  say "正在放行 firewalld"
  firewall-cmd --permanent --add-port="${port}/tcp" || true
  firewall-cmd --permanent --add-port=7000/tcp || true
  firewall-cmd --reload || true
fi

say "正在查询公网 IP"
ip="$(curl -4 -fsS --connect-timeout 8 --max-time 15 https://ifconfig.me || true)"
if [ -z "$ip" ]; then
  ip="把这里换成这台机器的公网IP"
fi

say
say "云服务器入口已启动。请把下面四行保存到沙箱的 webserver/data/vps.conf"
say "VPS_IP=${ip}"
say "VPS_PORT=${port}"
say "FRP_SERVER_PORT=7000"
say "FRP_TOKEN=${token}"
say
say "还要在云服务器的安全组里放行 TCP ${port} 和 TCP 7000。"
if [ "$port" = "80" ]; then
  say "固定访问地址是: http://${ip}"
else
  say "固定访问地址是: http://${ip}:${port}"
fi
