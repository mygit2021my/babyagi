#!/usr/bin/env bash
# Publish the local web service through a Cloudflare tunnel.
#
# When webserver/data/vps.conf exists, this machine also tells that cloud
# server the current Cloudflare address. The cloud server only hands the
# address to visitors. It does not carry the page, screen, or audio.
#
# A Quick Tunnel name changes every time cloudflared starts.
# A named tunnel still works if these gitignored files exist:
#   webserver/data/tunnel.token
#   webserver/data/fixed-url.txt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"
LOG="$ROOT/data/cloudflared.log"
URL_FILE="$ROOT/data/public-url.txt"
TOKEN_FILE="$ROOT/data/tunnel.token"
FIXED_FILE="$ROOT/data/fixed-url.txt"
VPS_CONF="$ROOT/data/vps.conf"

exec 8>>"$ROOT/data/tunnel.lock"
if ! flock -n 8; then
  exit 0
fi

valid_url() {
  [[ "$1" =~ ^https://[A-Za-z0-9.-]+$ ]]
}

tunnel_url() {
  [[ "$1" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]]
}

write_fixed_url() {
  [ -s "$FIXED_FILE" ] || return 1
  local fixed
  fixed="$(tr -d '[:space:]' <"$FIXED_FILE")"
  valid_url "$fixed" || return 1
  printf '%s\n' "$fixed" >"$URL_FILE"
}

current_url() {
  local fixed="" url=""
  if [ -s "$FIXED_FILE" ]; then
    fixed="$(tr -d '[:space:]' <"$FIXED_FILE")"
    if valid_url "$fixed"; then
      printf '%s\n' "$fixed"
      return 0
    fi
  fi
  if [ -f "$LOG" ]; then
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | tail -n 1 || true)"
  fi
  if [ -z "$url" ] && [ ! -s "$LOG" ] && [ -f /tmp/cloudflared-hello.log ]; then
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared-hello.log | tail -n 1 || true)"
  fi
  printf '%s\n' "$url"
}

conf_value() {
  local key="$1"
  [ -s "$VPS_CONF" ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$VPS_CONF" | tail -n 1
}

seal_bin() {
  local name
  case "$(uname -m)" in
    x86_64) name=amd64 ;;
    aarch64) name=arm64 ;;
    *) return 1 ;;
  esac
  if [ -x "$ROOT/vps/offline/gate-seal-linux-${name}" ]; then
    printf '%s\n' "$ROOT/vps/offline/gate-seal-linux-${name}"
  fi
}

push_addr() {
  local url="$1" ip token key port dest seal cipher
  ip="$(conf_value VPS_IP)"
  token="$(conf_value ADDR_TOKEN)"
  key="$(conf_value ADDR_KEY)"
  port="$(conf_value VPS_PORT)"
  [ -n "$ip" ] && [ -n "$token" ] && [ -n "$key" ] || return 0
  tunnel_url "$url" || return 0
  seal="$(seal_bin || true)"
  if [ -z "$seal" ]; then
    echo "push address failed" >>"$LOG"
    return 1
  fi
  cipher="$("$seal" encrypt "$key" "$url" 2>/dev/null || true)"
  if [ -z "$cipher" ]; then
    echo "push address failed" >>"$LOG"
    return 1
  fi
  port="${port:-80}"
  if [ "$port" = "80" ]; then
    dest="http://${ip}/address"
  else
    dest="http://${ip}:${port}/address"
  fi
  code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -X POST "$dest" \
    -H "X-Gate-Token: ${token}" \
    -H "Content-Type: text/plain" \
    --data-binary "$cipher" || true)"
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    return 0
  fi
  # The cloud server copied earlier only accepts a plain address.
  if [ "$code" = "400" ]; then
    code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -X POST "$dest" \
      -H "X-Gate-Token: ${token}" \
      -H "Content-Type: text/plain" \
      --data-binary "$url" || true)"
    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
      echo "cloud server rejected ciphertext and stored the plain address" >>"$LOG"
      return 0
    fi
  fi
  echo "push address failed" >>"$LOG"
  return 1
}

if [ -s "$TOKEN_FILE" ]; then
  write_fixed_url || true
  (
    exec 8>&-
    exec 9>&-
    exec cloudflared tunnel --no-autoupdate --protocol http2 run --token-file "$TOKEN_FILE"
  ) >>"$LOG" 2>&1 &
else
  (
    exec 8>&-
    exec 9>&-
    exec cloudflared tunnel --url http://127.0.0.1:8080 --protocol http2 --no-autoupdate
  ) >>"$LOG" 2>&1 &
fi
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM

pushed=""
push_after=0
while kill -0 "$pid" 2>/dev/null; do
  url="$(current_url || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url" >"$URL_FILE"
    now="$(date +%s)"
    if [ "$url" != "$pushed" ] || [ "$now" -ge "$push_after" ]; then
      if push_addr "$url"; then
        pushed="$url"
        push_after="$((now + 20))"
      else
        push_after="$((now + 5))"
      fi
    fi
  fi
  sleep 1
done
wait "$pid"
