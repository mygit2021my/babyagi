#!/usr/bin/env bash
# Idempotent packages for the web service and the tunnel. Safe to run twice.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
ROOT="$(cd "$(dirname "$0")" && pwd)"

sudo apt-get update
sudo apt-get install -y pulseaudio ffmpeg xvfb python3 python3-pip curl ca-certificates

if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL -o /tmp/cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/download/2026.10.3/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb
fi

python3 -m pip install --user 'websocket-client==1.9.2'

if [ -d /run/systemd/system ]; then
  sudo cp "$ROOT/systemd/gate-web.service" /etc/systemd/system/gate-web.service
  sudo cp "$ROOT/systemd/gate-tunnel.service" /etc/systemd/system/gate-tunnel.service
  sudo systemctl daemon-reload
  sudo systemctl enable gate-web.service gate-tunnel.service
  echo "enabled systemd units gate-web.service and gate-tunnel.service"
else
  echo "systemd is not the init process; boot.sh will start the services"
fi
