#!/usr/bin/env bash
# Offline installer for a cloud server that cannot reach the public internet.
# Put this script in the same directory as the frp archives, then:
#   sudo bash setup-frps.sh
set -euo pipefail

say() {
  printf '%s\n' "$*"
}

say "开始安装固定入口（不访问外网）"

if [ "$(id -u)" -ne 0 ]; then
  say "请用 root 运行: sudo bash setup-frps.sh"
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64) frp_arch=amd64; frp_sha=1d9875210972a5d1a62b2dc4c48df45ab0af05d3ca1b5e494a014428259df803 ;;
  aarch64) frp_arch=arm64; frp_sha=8edf590b0c396fa42f9c147121a76af83cfc2002b08f5aef0ea1008c43482019 ;;
  *) say "不支持的系统架构: $arch"; exit 1 ;;
esac

ver=0.71.1
name="frp_${ver}_linux_${frp_arch}.tar.gz"
script_dir="$(cd "$(dirname "$0")" && pwd)"
archive=""
for candidate in "$script_dir/$name" "$script_dir/offline/$name"; do
  if [ -f "$candidate" ]; then
    archive="$candidate"
    break
  fi
done
if [ -z "$archive" ]; then
  say "找不到 $name"
  say "请把压缩包和本脚本放在同一个目录后再运行。"
  exit 1
fi

say "使用本机文件: $archive"
if command -v sha256sum >/dev/null 2>&1; then
  got="$(sha256sum "$archive" | awk '{print $1}')"
  if [ "$got" != "$frp_sha" ]; then
    say "文件校验失败。请重新上传 $name"
    exit 1
  fi
  say "文件校验通过"
fi

say "正在安装 frps"
rm -rf "/tmp/frp_${ver}_linux_${frp_arch}"
tar -C /tmp -xzf "$archive"
install -m 755 "/tmp/frp_${ver}_linux_${frp_arch}/frps" /usr/local/bin/frps

say "正在写入配置"
install -d -m 700 /etc/gate-frp
if [ ! -s /etc/gate-frp/token ]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24 >/etc/gate-frp/token
  else
    od -An -tx1 -N24 /dev/urandom | tr -d ' \n' >/etc/gate-frp/token
  fi
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

say
say "云服务器入口已启动。这台机器不能访问外网，下面的 VPS_IP 请改成控制台里的公网 IP。"
say "把改好的四行保存到沙箱的 webserver/data/vps.conf"
say "VPS_IP=这里填公网IP"
say "VPS_PORT=${port}"
say "FRP_SERVER_PORT=7000"
say "FRP_TOKEN=${token}"
say
say "在云服务器安全组里放行 TCP ${port} 和 TCP 7000。入方向放行即可，云服务器不需要访问外网。"
if [ "$port" = "80" ]; then
  say "固定访问地址是: http://公网IP"
else
  say "固定访问地址是: http://公网IP:${port}"
fi
