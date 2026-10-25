#!/usr/bin/env python3
"""Authenticated web proxy. The sandbox fetches the URL the user enters."""

import hmac
import html
import ipaddress
import json
import os
import re
import secrets
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "data")
AUTH_PATH = os.path.join(DATA, "auth.json")
PORT = int(os.environ.get("PORT", "8080"))
BIND = os.environ.get("BIND", "0.0.0.0")
MAX_BYTES = 4_000_000
TIMEOUT = 20
MAX_REDIRECTS = 5
COOKIE = "gate_session"
SESSION_TTL = 7 * 24 * 3600

BLOCKED_HOSTS = {
    "localhost",
    "metadata.google.internal",
    "metadata.internal",
}


def load_auth():
    os.makedirs(DATA, exist_ok=True)
    if not os.path.exists(AUTH_PATH):
        record = {
            "username": "gate",
            "password": secrets.token_urlsafe(12),
            "secret": secrets.token_hex(32),
        }
        with open(AUTH_PATH, "w", encoding="utf-8") as fh:
            json.dump(record, fh)
            fh.write("\n")
        os.chmod(AUTH_PATH, 0o600)
        print(f"created login username={record['username']}", flush=True)
    with open(AUTH_PATH, encoding="utf-8") as fh:
        return json.load(fh)


AUTH = load_auth()


def sign(payload: bytes) -> str:
    mac = hmac.new(AUTH["secret"].encode(), payload, "sha256").hexdigest()
    return payload.hex() + "." + mac


def unsign(token: str):
    try:
        payload_hex, mac = token.split(".", 1)
        payload = bytes.fromhex(payload_hex)
    except ValueError:
        return None
    expected = hmac.new(AUTH["secret"].encode(), payload, "sha256").hexdigest()
    if not hmac.compare_digest(expected, mac):
        return None
    try:
        data = json.loads(payload.decode())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if data.get("exp", 0) < time.time():
        return None
    return data


def issue_session(username: str) -> str:
    payload = json.dumps(
        {"u": username, "exp": int(time.time()) + SESSION_TTL},
        separators=(",", ":"),
    ).encode()
    return sign(payload)


def blocked_ip(value: str) -> bool:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return True
    return any(
        (
            addr.is_private,
            addr.is_loopback,
            addr.is_link_local,
            addr.is_multicast,
            addr.is_reserved,
            addr.is_unspecified,
        )
    )


def check_target(url: str):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ValueError("只允许 http 和 https")
    host = parts.hostname
    if not host:
        raise ValueError("地址缺少主机名")
    if host.lower().rstrip(".") in BLOCKED_HOSTS:
        raise ValueError("该地址不能通过代理访问")
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None and blocked_ip(str(literal)):
        raise ValueError("内网地址不能通过代理访问")
    port = parts.port or (443 if parts.scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ValueError("无法解析该地址") from exc
    for item in infos:
        ip = item[4][0]
        if blocked_ip(ip):
            raise ValueError("该地址解析到内网，已拒绝")
    return parts


def fetch(url: str):
    current = url
    for _ in range(MAX_REDIRECTS + 1):
        parts = check_target(current)
        request = urllib.request.Request(
            urllib.parse.urlunsplit(parts),
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Linux; Android 14; Mobile) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            },
            method="GET",
        )
        opener = urllib.request.build_opener(NoRedirect())
        try:
            response = opener.open(request, timeout=TIMEOUT)
        except urllib.error.HTTPError as exc:
            response = exc
        except urllib.error.URLError as exc:
            raise ValueError("目标站点无法连接") from exc
        status = getattr(response, "status", None) or response.getcode()
        if status in (301, 302, 303, 307, 308):
            location = response.headers.get("Location")
            response.close()
            if not location:
                raise ValueError("目标返回了没有地址的跳转")
            current = urllib.parse.urljoin(current, location)
            continue
        body = response.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            response.close()
            raise ValueError("页面超过 4MB，已停止")
        content_type = response.headers.get("Content-Type", "application/octet-stream")
        response.close()
        return status, content_type, body, current
    raise ValueError("跳转次数过多")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def page(title: str, body: str) -> bytes:
    document = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    body {{ margin: 0; font-family: sans-serif; background: #101418; color: #f4f7fb; }}
    main {{ max-width: 40rem; margin: 0 auto; padding: 2rem 1rem; }}
    form {{ display: grid; gap: 0.75rem; }}
    input {{ font: inherit; padding: 0.7rem 0.8rem; border-radius: 8px; border: 1px solid #3a4654; background: #1b232c; color: inherit; }}
    button {{ font: inherit; padding: 0.7rem 0.8rem; border: 0; border-radius: 8px; background: #d7e6ff; color: #102033; }}
    p.err {{ color: #ffb4ab; }}
  </style>
</head>
<body><main>{body}</main></body>
</html>"""
    return document.encode()


def proxy_url(base_url: str, value: str) -> str:
    if not value or value.startswith(("#", "javascript:", "data:", "mailto:")):
        return value
    absolute = urllib.parse.urljoin(base_url, value)
    return "/open?u=" + urllib.parse.quote(absolute, safe="")


def rewrite_html(text: str, base_url: str) -> str:
    def attr(match):
        name = match.group(1)
        quote = match.group(2)
        value = match.group(3) if quote else match.group(4)
        if name.lower() == "srcset":
            items = []
            for part in value.split(","):
                bits = part.strip().split()
                if bits:
                    bits[0] = proxy_url(base_url, bits[0])
                    items.append(" ".join(bits))
            value = ", ".join(items)
        else:
            value = proxy_url(base_url, value)
        return f'{name}="{value}"'

    text = re.sub(
        r"""(?i)\b(href|src|action|poster|srcset)\s*=\s*(?:(["'])(.*?)\2|([^\s"'=<>`]+))""",
        attr,
        text,
    )
    base = f'<base href="{html.escape(base_url, quote=True)}">'
    head = re.search(r"(?i)<head[^>]*>", text)
    if head:
        return text[: head.end()] + base + text[head.end() :]
    return base + text


def render_remote(content_type: str, body: bytes, final_url: str):
    mime = content_type.split(";", 1)[0].strip().lower()
    if mime not in ("text/html", "application/xhtml+xml"):
        return content_type, body
    charset = "utf-8"
    for piece in content_type.split(";")[1:]:
        piece = piece.strip()
        if piece.lower().startswith("charset="):
            charset = piece.split("=", 1)[1].strip("\"' ") or "utf-8"
    text = body.decode(charset, errors="replace")
    return "text/html; charset=utf-8", rewrite_html(text, final_url).encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "GateProxy/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def session_user(self):
        cookie = self.headers.get("Cookie", "")
        token = ""
        for part in cookie.split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE:
                token = urllib.parse.unquote(value)
                break
        if not token:
            header = self.headers.get("Authorization", "")
            if header.lower().startswith("bearer "):
                token = header[7:].strip()
        data = unsign(token) if token else None
        return data.get("u") if data else None

    def send_html(self, status: int, body: bytes, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in headers or []:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location: str, headers=None):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        for key, value in headers or []:
            self.send_header(key, value)
        self.end_headers()

    def cookie_header(self, token: str) -> str:
        secure = self.headers.get("X-Forwarded-Proto", "http") == "https"
        suffix = "; Secure" if secure else ""
        return f"{COOKIE}={urllib.parse.quote(token)}; HttpOnly; Path=/; SameSite=Lax; Max-Age={SESSION_TTL}{suffix}"

    def form(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 1_000_000:
            return {}
        raw = self.rfile.read(length) if length else b""
        parsed = urllib.parse.parse_qs(raw.decode("utf-8", errors="replace"), keep_blank_values=True)
        return {key: values[-1] for key, values in parsed.items()}

    def require_user(self):
        user = self.session_user()
        if user:
            return user
        self.redirect("/login")
        return None

    def do_GET(self):
        parts = urllib.parse.urlsplit(self.path)
        if parts.path == "/login":
            self.send_html(200, login_page(""))
            return
        if parts.path == "/open":
            if not self.require_user():
                return
            query = urllib.parse.parse_qs(parts.query)
            target = (query.get("u") or [""])[-1].strip()
            self.serve_target(target)
            return
        if parts.path in ("/", ""):
            if not self.require_user():
                return
            self.send_html(200, home_page(""))
            return
        self.send_html(404, page("未找到", "<p>未找到该页面。</p>"))

    def do_POST(self):
        parts = urllib.parse.urlsplit(self.path)
        fields = self.form()
        if parts.path == "/login":
            username = fields.get("username", "")
            password = fields.get("password", "")
            valid = secrets.compare_digest(username, AUTH["username"]) and secrets.compare_digest(
                password, AUTH["password"]
            )
            if not valid:
                self.send_html(401, login_page("用户名或密码不正确"))
                return
            token = issue_session(username)
            accept = self.headers.get("Accept", "")
            if "application/json" in accept:
                body = json.dumps({"ok": True, "token": token}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Set-Cookie", self.cookie_header(token))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            self.redirect("/", [("Set-Cookie", self.cookie_header(token))])
            return
        if parts.path == "/logout":
            self.redirect("/login", [("Set-Cookie", f"{COOKIE}=; HttpOnly; Path=/; Max-Age=0")])
            return
        if parts.path == "/open":
            if not self.require_user():
                return
            target = fields.get("u", "").strip()
            self.serve_target(target)
            return
        self.send_html(404, page("未找到", "<p>未找到该页面。</p>"))

    def serve_target(self, target: str):
        if not target:
            self.send_html(400, home_page("请输入要访问的地址"))
            return
        if "://" not in target:
            target = "https://" + target
        try:
            status, content_type, body, final_url = fetch(target)
            content_type, body = render_remote(content_type, body, final_url)
        except ValueError as exc:
            self.send_html(400, home_page(str(exc)))
            return
        self.send_response(status if 200 <= status < 600 else 502)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


def login_page(error: str) -> bytes:
    message = f'<p class="err">{html.escape(error)}</p>' if error else ""
    return page(
        "登录",
        message
        + """
        <h1>登录</h1>
        <form method="post" action="/login">
          <input name="username" autocomplete="username" placeholder="用户名" required>
          <input name="password" type="password" autocomplete="current-password" placeholder="密码" required>
          <button type="submit">登录</button>
        </form>
        """,
    )


def home_page(error: str) -> bytes:
    message = f'<p class="err">{html.escape(error)}</p>' if error else ""
    return page(
        "打开地址",
        message
        + """
        <h1>打开一个地址</h1>
        <form method="get" action="/open">
          <input name="u" inputmode="url" placeholder="https://example.com" required>
          <button type="submit">访问</button>
        </form>
        <form method="post" action="/logout"><button type="submit">退出</button></form>
        """,
    )


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"listening on {BIND}:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
