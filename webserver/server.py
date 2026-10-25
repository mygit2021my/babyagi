#!/usr/bin/env python3
"""Login gate in front of a real browser running on this sandbox.

The signed-in page does not rewrite the sites it opens. It shows the sandbox
browser and forwards pointer, keyboard, and address-bar input to it.
"""

import base64
import hashlib
import html
import json
import os
import secrets
import socket
import time
import hmac
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from browser import AUDIO, RemoteBrowser, send_ws, start_egress

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "data")
AUTH_PATH = os.path.join(DATA, "auth.json")
PORT = int(os.environ.get("PORT", "8080"))
BIND = os.environ.get("BIND", "0.0.0.0")
COOKIE = "gate_session"
SESSION_TTL = 7 * 24 * 3600


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
BROWSER = RemoteBrowser()


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


def shell_page() -> bytes:
    document = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>远程浏览</title>
  <style>
    html, body { margin: 0; height: 100%; background: #000; color: #f4f7fb; font-family: sans-serif; }
    body { display: flex; flex-direction: column; height: 100dvh; }
    header { display: flex; gap: 0.4rem; padding: 0.4rem; background: #101418; }
    input, button { font: inherit; }
    #url { flex: 1; min-width: 0; padding: 0.55rem 0.7rem; border-radius: 8px; border: 1px solid #3a4654; background: #1b232c; color: inherit; }
    button { padding: 0.55rem 0.7rem; border: 0; border-radius: 8px; background: #d7e6ff; color: #102033; }
    #stage { flex: 1; min-height: 0; display: flex; align-items: center; justify-content: center; touch-action: none; }
    #frame { position: relative; max-width: 100%; max-height: 100%; }
    #screen { display: block; max-width: 100%; max-height: 100%; background: #000; }
    #keys { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; padding: 0; border: 0; resize: none; outline: none; opacity: 0.01; color: transparent; background: transparent; caret-color: transparent; font-size: 16px; z-index: 2; }
    #note { margin: 0; padding: 0 0.5rem 0.4rem; color: #ffb4ab; font-size: 0.85rem; background: #101418; }
  </style>
</head>
<body>
  <header>
    <button type="button" id="back">后退</button>
    <form id="go"><input id="url" inputmode="url" placeholder="https://example.com" autocomplete="off"></form>
    <button type="submit" form="go">打开</button>
    <form method="post" action="/logout"><button type="submit">退出</button></form>
  </header>
  <p id="note"></p>
  <div id="stage"><div id="frame"><img id="screen" alt="远程页面"><textarea id="keys" autocomplete="off" autocapitalize="off"></textarea></div></div>
  <script>
    const screen = document.querySelector('#screen');
    const url = document.querySelector('#url');
    const keys = document.querySelector('#keys');
    const note = document.querySelector('#note');
    let previous = '';
    let view = {width: 1280, height: 800};
    let chain = Promise.resolve();
    let composing = false;
    let skipInput = false;
    function point(ev) {
      const rect = screen.getBoundingClientRect();
      const width = view.width || screen.naturalWidth || rect.width || 1;
      const height = view.height || screen.naturalHeight || rect.height || 1;
      return {
        x: Math.max(0, (ev.clientX - rect.left) / Math.max(rect.width, 1) * width),
        y: Math.max(0, (ev.clientY - rect.top) / Math.max(rect.height, 1) * height)
      };
    }
    function send(event) {
      const run = chain.then(() => fetch('/input', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(event)
      }));
      chain = run.catch(() => {});
      return run;
    }
    function startAudio() {
      const context = window.__audioCtx || new AudioContext();
      window.__audioCtx = context;
      if (context.state === 'suspended') context.resume();
      if (window.__audioOn) return;
      window.__audioOn = true;
      const proto = location.protocol === 'https:' ? 'wss' : 'ws';
      const socket = new WebSocket(proto + '://' + location.host + '/audio');
      socket.binaryType = 'arraybuffer';
      let next = 0;
      socket.onmessage = (ev) => {
        const pcm = new Int16Array(ev.data);
        if (!pcm.length) return;
        const buf = context.createBuffer(1, pcm.length, 48000);
        const channel = buf.getChannelData(0);
        for (let i = 0; i < pcm.length; i++) channel[i] = pcm[i] / 32768;
        const source = context.createBufferSource();
        source.buffer = buf;
        source.connect(context.destination);
        const now = context.currentTime;
        if (next < now + 0.05) next = now + 0.15;
        source.start(next);
        next += buf.duration;
      };
      socket.onclose = () => {
        window.__audioOn = false;
        setTimeout(startAudio, 1000);
      };
    }
    document.querySelector('#back').onclick = () => send({t: 'back'});
    document.querySelector('#go').onsubmit = async (ev) => {
      ev.preventDefault();
      note.textContent = '';
      const response = await fetch('/go', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({u: url.value})
      });
      if (!response.ok) note.textContent = await response.text();
    };
    keys.addEventListener('pointerdown', (ev) => {
      startAudio();
      try { keys.setPointerCapture(ev.pointerId); } catch (err) {}
      send(Object.assign({t: 'down', button: ev.button, click: ev.detail || 1}, point(ev)));
    });
    keys.addEventListener('pointerup', async (ev) => {
      const response = await send(Object.assign({t: 'up', button: ev.button}, point(ev)));
      let data = {};
      try { data = await response.json(); } catch (err) {}
      if (!data.editable) keys.blur();
    });
    keys.addEventListener('pointermove', (ev) => {
      if (ev.buttons) send(Object.assign({t: 'move', button: ev.button}, point(ev)));
    });
    keys.addEventListener('wheel', (ev) => {
      ev.preventDefault();
      send(Object.assign({t: 'wheel', dx: ev.deltaX, dy: ev.deltaY}, point(ev)));
    }, {passive: false});
    keys.addEventListener('compositionstart', () => { composing = true; });
    keys.addEventListener('compositionend', (ev) => {
      composing = false;
      skipInput = true;
      const text = ev.data || keys.value;
      keys.value = '';
      if (text) send({t: 'text', text: text});
    });
    keys.addEventListener('input', () => {
      if (composing || skipInput) { skipInput = false; return; }
      const text = keys.value;
      keys.value = '';
      if (text) send({t: 'text', text: text});
    });
    keys.addEventListener('keydown', (ev) => {
      if (composing) return;
      if (ev.key.length === 1 && !ev.ctrlKey && !ev.metaKey && !ev.altKey) return;
      ev.preventDefault();
      send({t: 'key', down: true, key: ev.key, code: ev.code});
      send({t: 'key', down: false, key: ev.key, code: ev.code});
    });
    async function frames() {
      try {
        const response = await fetch('/snap', {cache: 'no-store', credentials: 'same-origin'});
        if (response.status === 200) {
          const blob = await response.blob();
          const next = URL.createObjectURL(blob);
          screen.src = next;
          if (previous) URL.revokeObjectURL(previous);
          previous = next;
        }
      } catch (err) {}
      setTimeout(frames, 140);
    }
    async function watch() {
      try {
        const state = await fetch('/state', {cache: 'no-store', credentials: 'same-origin'}).then(r => r.json());
        if (state.width && state.height) view = state;
        if (document.activeElement !== url && state.url) url.value = state.url;
        if (state.error) note.textContent = state.error;
      } catch (err) {}
      setTimeout(watch, 1000);
    }
    frames();
    watch();
  </script>
</body>
</html>"""
    return document.encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "GateBrowser/1.0"
    protocol_version = "HTTP/1.1"
    rbufsize = 0

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def session_user(self):
        token = ""
        for part in self.headers.get("Cookie", "").split(";"):
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

    def send_bytes(self, status: int, body: bytes, content_type: str, headers=None):
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in headers or []:
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)
        except ConnectionError:
            return

    def send_html(self, status: int, body: bytes, headers=None):
        self.send_bytes(status, body, "text/html; charset=utf-8", headers)

    def redirect(self, location: str, headers=None):
        try:
            self.send_response(303)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            for key, value in headers or []:
                self.send_header(key, value)
            self.end_headers()
        except ConnectionError:
            return

    def cookie_header(self, token: str) -> str:
        secure = self.headers.get("X-Forwarded-Proto", "http") == "https"
        suffix = "; Secure" if secure else ""
        return f"{COOKIE}={urllib.parse.quote(token)}; HttpOnly; Path=/; SameSite=Lax; Max-Age={SESSION_TTL}{suffix}"

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 200_000:
            raise ValueError("请求体过大")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        if "application/json" in self.headers.get("Content-Type", ""):
            return json.loads(raw.decode("utf-8"))
        parsed = urllib.parse.parse_qs(raw.decode("utf-8", errors="replace"), keep_blank_values=True)
        return {key: values[-1] for key, values in parsed.items()}

    def require_user(self):
        user = self.session_user()
        if user:
            return user
        if self.command == "GET":
            self.redirect("/login")
        else:
            self.send_bytes(401, "需要登录".encode(), "text/plain; charset=utf-8")
        return None

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/login":
            self.send_html(200, login_page(""))
            return
        if not self.require_user():
            return
        if path in ("/", ""):
            self.send_html(200, shell_page())
            return
        if path == "/snap":
            try:
                frame = BROWSER.snapshot()
            except RuntimeError as exc:
                self.send_bytes(503, str(exc).encode(), "text/plain; charset=utf-8")
                return
            if not frame:
                self.send_bytes(204, b"", "image/jpeg")
                return
            self.send_bytes(200, frame, "image/jpeg")
            return
        if path == "/state":
            body = json.dumps(BROWSER.status(), ensure_ascii=False).encode()
            self.send_bytes(200, body, "application/json")
            return
        if path == "/audio":
            self.stream_audio()
            return
        self.send_html(404, page("未找到", "<p>未找到该页面。</p>"))

    def stream_audio(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        if not key:
            self.send_bytes(400, "需要 WebSocket".encode(), "text/plain; charset=utf-8")
            return
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        try:
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
        except ConnectionError:
            return
        conn = self.connection
        AUDIO.add(conn)
        try:
            while True:
                frame = self.read_ws(conn)
                if frame is None:
                    break
                opcode, payload = frame
                if opcode == 8:
                    break
                if opcode == 9:
                    send_ws(conn, 10, payload)
        except (ConnectionError, OSError):
            pass
        finally:
            AUDIO.remove(conn)
            self.close_connection = True

    def read_ws(self, conn: socket.socket):
        def recvn(count: int) -> bytes:
            data = b""
            while len(data) < count:
                piece = conn.recv(count - len(data))
                if not piece:
                    return b""
                data += piece
            return data

        head = recvn(2)
        if len(head) < 2:
            return None
        opcode = head[0] & 0x0F
        masked = head[1] & 0x80
        length = head[1] & 0x7F
        if length == 126:
            length = int.from_bytes(recvn(2), "big")
        elif length == 127:
            length = int.from_bytes(recvn(8), "big")
        mask = recvn(4) if masked else b""
        payload = recvn(length) if length else b""
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return opcode, payload

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        try:
            fields = self.read_json()
        except (ValueError, json.JSONDecodeError):
            self.send_bytes(400, "请求无法读取".encode(), "text/plain; charset=utf-8")
            return
        if path == "/login":
            username = str(fields.get("username", ""))
            password = str(fields.get("password", ""))
            valid = secrets.compare_digest(username, AUTH["username"]) and secrets.compare_digest(
                password, AUTH["password"]
            )
            if not valid:
                self.send_html(401, login_page("用户名或密码不正确"))
                return
            token = issue_session(username)
            if "application/json" in self.headers.get("Accept", ""):
                body = json.dumps({"ok": True, "token": token}).encode()
                self.send_bytes(
                    200,
                    body,
                    "application/json",
                    [("Set-Cookie", self.cookie_header(token))],
                )
                return
            self.redirect("/", [("Set-Cookie", self.cookie_header(token))])
            return
        if not self.require_user():
            return
        if path == "/logout":
            self.redirect("/login", [("Set-Cookie", f"{COOKIE}=; HttpOnly; Path=/; Max-Age=0")])
            return
        if path == "/go":
            try:
                BROWSER.open_url(str(fields.get("u", "")).strip())
            except (ValueError, RuntimeError, TimeoutError) as exc:
                self.send_bytes(400, str(exc).encode(), "text/plain; charset=utf-8")
                return
            self.send_bytes(204, b"", "text/plain")
            return
        if path == "/input":
            try:
                result = BROWSER.handle_input(fields if isinstance(fields, dict) else {}) or {}
            except (RuntimeError, TimeoutError) as exc:
                self.send_bytes(503, str(exc).encode(), "text/plain; charset=utf-8")
                return
            self.send_bytes(200, json.dumps(result).encode(), "application/json")
            return
        self.send_html(404, page("未找到", "<p>未找到该页面。</p>"))


def main():
    start_egress()
    try:
        AUDIO.ensure()
    except OSError as exc:
        print(f"audio unavailable: {exc}", flush=True)
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"listening on {BIND}:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
