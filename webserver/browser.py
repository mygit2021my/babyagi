"""A real Chrome on this machine, shown to the signed-in user as a screen.

Pages are not rewritten. Chrome loads each site itself. A local proxy only
rejects private and link-local addresses.
"""

import base64
import ipaddress
import json
import os
import queue
import socket
import socketserver
import subprocess
import threading
import time
import urllib.parse
import urllib.request

from websocket import WebSocketTimeoutException, create_connection

CHROME = os.environ.get("CHROME", "/usr/bin/google-chrome-stable")
DEBUG_PORT = int(os.environ.get("CHROME_DEBUG_PORT", "9224"))
EGRESS_PORT = int(os.environ.get("EGRESS_PORT", "8081"))
PROFILE = os.environ.get("CHROME_PROFILE", "/tmp/gate-chrome")
VIEW_W = 1280
VIEW_H = 800
DISPLAY = ":99"
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
AUDIO_ENV = os.environ.copy()

BLOCKED_HOSTS = {
    "localhost",
    "metadata.google.internal",
    "metadata.internal",
}


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


def public_target(host: str, port: int):
    if not host or host.lower().rstrip(".") in BLOCKED_HOSTS:
        raise ValueError("该地址不能通过这台机器访问")
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None and blocked_ip(str(literal)):
        raise ValueError("内网地址不能通过这台机器访问")
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ValueError("无法解析该地址") from exc
    for item in infos:
        if blocked_ip(item[4][0]):
            raise ValueError("该地址解析到内网，已拒绝")
    return infos


def connect_public(host: str, port: int) -> socket.socket:
    infos = public_target(host, port)
    last = None
    for item in infos:
        sock = socket.socket(item[0], item[1], item[2])
        sock.settimeout(15)
        try:
            sock.connect(item[4])
        except OSError as exc:
            last = exc
            sock.close()
            continue
        sock.settimeout(None)
        return sock
    raise ValueError("目标站点无法连接") from last


def splice(left: socket.socket, right: socket.socket):
    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    threads = [
        threading.Thread(target=pump, args=(left, right), daemon=True),
        threading.Thread(target=pump, args=(right, left), daemon=True),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


class EgressHandler(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(20)
        try:
            head = b""
            while b"\r\n\r\n" not in head and len(head) < 65536:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                head += chunk
        except OSError:
            return
        header, _, rest = head.partition(b"\r\n\r\n")
        lines = header.decode("latin1", errors="replace").split("\r\n")
        if not lines or not lines[0]:
            return
        parts = lines[0].split(" ")
        if len(parts) < 2:
            return
        method, target = parts[0], parts[1]
        try:
            if method == "CONNECT":
                host, _, port_text = target.partition(":")
                remote = connect_public(host, int(port_text or "443"))
                conn.settimeout(None)
                conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                if rest:
                    remote.sendall(rest)
                splice(conn, remote)
                remote.close()
                return
            absolute = urllib.parse.urlsplit(target)
            if absolute.scheme not in ("http", "https") or not absolute.hostname:
                raise ValueError("只允许 http 和 https")
            port = absolute.port or (443 if absolute.scheme == "https" else 80)
            remote = connect_public(absolute.hostname, port)
            path = absolute.path or "/"
            if absolute.query:
                path += "?" + absolute.query
            version = parts[2] if len(parts) > 2 else "HTTP/1.1"
            rebuilt = [f"{method} {path} {version}"]
            rebuilt.extend(lines[1:])
            remote.sendall(("\r\n".join(rebuilt) + "\r\n\r\n").encode("latin1") + rest)
            conn.settimeout(None)
            splice(conn, remote)
            remote.close()
        except (ValueError, OSError) as exc:
            message = str(exc).encode()
            try:
                conn.sendall(
                    b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: "
                    + str(len(message)).encode()
                    + b"\r\nConnection: close\r\n\r\n"
                    + message
                )
            except OSError:
                pass


class EgressServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def start_egress(host: str = "127.0.0.1", port: int = EGRESS_PORT) -> EgressServer:
    server = EgressServer((host, port), EgressHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def ensure_display_and_pulse() -> dict:
    global RUNTIME_DIR, AUDIO_ENV
    if not os.path.isdir(RUNTIME_DIR):
        RUNTIME_DIR = "/tmp/gate-runtime"
        os.makedirs(RUNTIME_DIR, mode=0o700, exist_ok=True)
    env = os.environ.copy()
    env["DISPLAY"] = DISPLAY
    env["XDG_RUNTIME_DIR"] = RUNTIME_DIR
    env["PULSE_SINK"] = "gate_audio"
    if not os.path.exists("/tmp/.X11-unix/X99"):
        subprocess.Popen(
            ["Xvfb", DISPLAY, "-screen", "0", f"{VIEW_W}x{VIEW_H}x24", "-ac"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        for _ in range(30):
            if os.path.exists("/tmp/.X11-unix/X99"):
                break
            time.sleep(0.1)
    subprocess.run(
        ["pulseaudio", "--start", "--exit-idle-time=-1", "--daemonize=yes"],
        env=env,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    listed = subprocess.run(
        ["pactl", "list", "short", "sinks"],
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    if "gate_audio" not in listed.stdout:
        subprocess.run(
            [
                "pactl",
                "load-module",
                "module-null-sink",
                "sink_name=gate_audio",
                "sink_properties=device.description=gate",
            ],
            env=env,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    subprocess.run(
        ["pactl", "set-default-sink", "gate_audio"],
        env=env,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    AUDIO_ENV = env
    return env


def send_ws(conn: socket.socket, opcode: int, payload: bytes):
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += length.to_bytes(2, "big")
    else:
        header.append(127)
        header += length.to_bytes(8, "big")
    conn.sendall(header + payload)


class AudioHub:
    def __init__(self):
        self.clients = []
        self.lock = threading.Lock()
        self.start_lock = threading.Lock()
        self.proc = None
        self.thread = None

    def ensure(self):
        with self.start_lock:
            if self.proc is not None and self.proc.poll() is None:
                return
            self._spawn()

    def _spawn(self):
        env = ensure_display_and_pulse()
        self.proc = subprocess.Popen(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-fflags",
                "nobuffer",
                "-f",
                "pulse",
                "-i",
                "gate_audio.monitor",
                "-ac",
                "1",
                "-ar",
                "48000",
                "-f",
                "s16le",
                "pipe:1",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._pump, daemon=True)
            self.thread.start()

    def add(self, conn: socket.socket):
        self.ensure()
        with self.lock:
            self.clients.append(conn)

    def remove(self, conn: socket.socket):
        with self.lock:
            if conn in self.clients:
                self.clients.remove(conn)

    def _pump(self):
        while True:
            proc = self.proc
            if proc is None or proc.stdout is None or proc.poll() is not None:
                time.sleep(0.3)
                try:
                    self.ensure()
                except OSError:
                    time.sleep(1)
                continue
            chunk = proc.stdout.read(9600)
            if not chunk:
                time.sleep(0.2)
                continue
            with self.lock:
                stale = []
                for conn in self.clients:
                    try:
                        send_ws(conn, 2, chunk)
                    except OSError:
                        stale.append(conn)
                for conn in stale:
                    if conn in self.clients:
                        self.clients.remove(conn)


AUDIO = AudioHub()


class RemoteBrowser:
    def __init__(self):
        self.start_lock = threading.Lock()
        self.frame_lock = threading.Lock()
        self.frame = b""
        self.url = ""
        self.title = ""
        self.error = ""
        self.proc = None
        self.ws = None
        self.reader = None
        self.outbox = queue.Queue()
        self.results = {}
        self.pending = set()
        self.result_ready = threading.Condition()
        self.id_lock = threading.Lock()
        self.input_lock = threading.Lock()
        self.next_id = 0
        self.viewport = (VIEW_W, VIEW_H)

    def healthy(self) -> bool:
        return self.proc is not None and self.proc.poll() is None and self.ws is not None

    def ensure(self):
        if self.healthy():
            return
        with self.start_lock:
            if self.healthy():
                return
            try:
                self._start()
            except Exception as exc:
                self.error = str(exc)
                self._stop()
                raise RuntimeError(self.error) from exc

    def _start(self):
        self._stop()
        subprocess.run(["pkill", "-f", f"user-data-dir={PROFILE}"], check=False)
        for _ in range(25):
            probe = socket.socket()
            probe.settimeout(0.2)
            try:
                busy = probe.connect_ex(("127.0.0.1", DEBUG_PORT)) == 0
            finally:
                probe.close()
            if not busy:
                break
            time.sleep(0.2)
        os.makedirs(PROFILE, exist_ok=True)
        env = ensure_display_and_pulse()
        log = open("/tmp/gate-chrome.log", "ab")
        self.proc = subprocess.Popen(
            [
                CHROME,
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu",
                "--ozone-platform=x11",
                "--use-gl=angle",
                "--use-angle=swiftshader",
                f"--remote-debugging-port={DEBUG_PORT}",
                "--remote-debugging-address=127.0.0.1",
                f"--user-data-dir={PROFILE}",
                f"--window-size={VIEW_W},{VIEW_H}",
                "--window-position=0,0",
                f"--proxy-server=http://127.0.0.1:{EGRESS_PORT}",
                "--proxy-bypass-list=<-loopback>",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-background-networking",
                "--autoplay-policy=no-user-gesture-required",
                "--lang=zh-CN",
                "about:blank",
            ],
            stdout=log,
            stderr=log,
            env=env,
        )
        page = self._wait_page()
        self.outbox = queue.Queue()
        with self.result_ready:
            self.results.clear()
            self.pending.clear()
        self.ws = create_connection(page["webSocketDebuggerUrl"], timeout=10, suppress_origin=True)
        socket_for_reader = self.ws
        self.reader = threading.Thread(target=self._read_loop, args=(socket_for_reader,), daemon=True)
        self.reader.start()
        self.call("Page.enable")
        self.call("Runtime.enable")
        self.call(
            "Emulation.setDeviceMetricsOverride",
            width=VIEW_W,
            height=VIEW_H,
            deviceScaleFactor=1,
            mobile=False,
        )
        self.call(
            "Page.startScreencast",
            format="jpeg",
            quality=55,
            maxWidth=VIEW_W,
            maxHeight=VIEW_H,
            everyNthFrame=1,
        )
        self.error = ""

    def _wait_page(self):
        deadline = time.time() + 20
        last = "浏览器没有启动"
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError("浏览器启动失败")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{DEBUG_PORT}/json", timeout=2) as resp:
                    tabs = json.load(resp)
            except (OSError, json.JSONDecodeError) as exc:
                last = str(exc)
                time.sleep(0.3)
                continue
            pages = [tab for tab in tabs if tab.get("type") == "page" and tab.get("webSocketDebuggerUrl")]
            if pages:
                return pages[0]
            time.sleep(0.3)
        raise RuntimeError(last)

    def _stop(self):
        ws = self.ws
        self.ws = None
        if ws is not None:
            try:
                ws.close()
            except OSError:
                pass
        reader = self.reader
        if reader is not None and reader.is_alive() and reader is not threading.current_thread():
            reader.join(timeout=2)
        self.reader = None
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def _read_loop(self, ws):
        while self.ws is ws:
            try:
                ws.settimeout(0.2)
                raw = ws.recv()
            except WebSocketTimeoutException:
                raw = ""
            except Exception:
                if self.ws is ws:
                    self.ws = None
                    self.error = "浏览器连接中断"
                return
            if raw:
                self._on_message(raw)
            while self.ws is ws:
                try:
                    outgoing = self.outbox.get_nowait()
                except queue.Empty:
                    break
                try:
                    ws.send(outgoing)
                except Exception:
                    if self.ws is ws:
                        self.ws = None
                        self.error = "浏览器连接中断"
                    return

    def _on_message(self, raw: str):
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            return
        if "id" in message:
            with self.result_ready:
                if message["id"] in self.pending:
                    self.results[message["id"]] = message
                    self.result_ready.notify_all()
            return
        if message.get("method") == "Page.screencastFrame":
            params = message.get("params") or {}
            data = params.get("data") or ""
            if data:
                frame = base64.b64decode(data)
                meta = params.get("metadata") or {}
                with self.frame_lock:
                    self.frame = frame
                    width = meta.get("deviceWidth") or self.viewport[0]
                    height = meta.get("deviceHeight") or self.viewport[1]
                    if width and height:
                        self.viewport = (width, height)
            session_id = params.get("sessionId")
            if session_id is not None:
                self.outbox.put(
                    json.dumps(
                        {
                            "id": self._next(),
                            "method": "Page.screencastFrameAck",
                            "params": {"sessionId": session_id},
                        }
                    )
                )
        elif message.get("method") == "Page.frameNavigated":
            frame = (message.get("params") or {}).get("frame") or {}
            if frame.get("parentId"):
                return
            url = frame.get("url") or ""
            if url:
                self.url = url

    def _next(self) -> int:
        with self.id_lock:
            self.next_id += 1
            return self.next_id

    def call(self, method: str, timeout: float = 20, **params):
        if self.ws is None:
            raise RuntimeError(self.error or "浏览器还没有就绪")
        ident = self._next()
        with self.result_ready:
            self.pending.add(ident)
        self.outbox.put(json.dumps({"id": ident, "method": method, "params": params}))
        deadline = time.time() + timeout
        with self.result_ready:
            try:
                while ident not in self.results:
                    remaining = deadline - time.time()
                    if remaining <= 0:
                        raise TimeoutError(method)
                    self.result_ready.wait(remaining)
                message = self.results.pop(ident)
            finally:
                self.pending.discard(ident)
        if "error" in message:
            raise RuntimeError(str(message["error"]))
        return message.get("result") or {}

    def open_url(self, target: str):
        if "://" not in target:
            target = "https://" + target
        parts = urllib.parse.urlsplit(target)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError("只允许打开 http 和 https")
        public_target(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80))
        self.ensure()
        self.call("Page.navigate", url=target)
        self.url = target

    def snapshot(self) -> bytes:
        self.ensure()
        with self.frame_lock:
            return self.frame

    def status(self) -> dict:
        try:
            self.ensure()
            current = self.call(
                "Runtime.evaluate",
                expression="location.href",
                returnByValue=True,
            )
            value = ((current.get("result") or {}).get("value")) or self.url
            if value:
                self.url = value
        except (RuntimeError, TimeoutError, OSError) as exc:
            self.error = str(exc)
        return {
            "url": self.url,
            "title": self.title,
            "width": self.viewport[0],
            "height": self.viewport[1],
            "error": self.error,
        }

    def _key(self, key: str, code: str, down: bool, text: str = ""):
        vk = {
            "Enter": 13,
            "Backspace": 8,
            "Tab": 9,
            "Escape": 27,
            "ArrowLeft": 37,
            "ArrowUp": 38,
            "ArrowRight": 39,
            "ArrowDown": 40,
            "Delete": 46,
            " ": 32,
        }.get(key, ord(key.upper()) if len(key) == 1 else 0)
        params = {
            "type": "keyDown" if down else "keyUp",
            "key": key,
            "code": code,
            "windowsVirtualKeyCode": vk,
            "nativeVirtualKeyCode": vk,
        }
        if text and down:
            params["text"] = text
            params["unmodifiedText"] = text.lower() if text.isalpha() else text
        if len(key) == 1 and key.isalpha() and key.isupper():
            params["modifiers"] = 8
        self.call("Input.dispatchKeyEvent", **params)

    def _pointer(self, kind: str, x: float, y: float, button: str, click: int):
        mapping = {"down": "mousePressed", "up": "mouseReleased", "move": "mouseMoved"}
        params = {
            "type": mapping[kind],
            "x": x,
            "y": y,
            "button": button,
            "buttons": 0 if kind == "up" else 1,
            "pointerType": "mouse",
        }
        if kind == "down":
            params["clickCount"] = click
        self.call("Input.dispatchMouseEvent", **params)

    def handle_input(self, event: dict):
        self.ensure()
        kind = event.get("t")
        with self.input_lock:
            if kind == "text":
                text = str(event.get("text") or "")
                if len(text) == 1:
                    code = f"Key{text.upper()}" if text.isalpha() else ("Space" if text == " " else "")
                    self._key(text, code, True, text)
                    self._key(text, code, False)
                elif text:
                    self.call("Input.insertText", text=text)
                return
            if kind == "key":
                self._key(
                    str(event.get("key") or ""),
                    str(event.get("code") or ""),
                    bool(event.get("down", True)),
                )
                return
            if kind == "back":
                self.call("Runtime.evaluate", expression="history.back()")
                return
            if kind not in ("down", "up", "move", "wheel"):
                return
            try:
                x = float(event.get("x", 0))
                y = float(event.get("y", 0))
            except (TypeError, ValueError):
                return
            button = {0: "left", 1: "middle", 2: "right"}.get(int(event.get("button") or 0), "left")
            if kind == "wheel":
                self.call(
                    "Input.dispatchMouseEvent",
                    type="mouseWheel",
                    x=x,
                    y=y,
                    deltaX=float(event.get("dx") or 0),
                    deltaY=float(event.get("dy") or 0),
                    pointerType="mouse",
                )
                return
            self._pointer(kind, x, y, button, int(event.get("click") or 1))
            if kind == "up":
                return {"editable": self.focused_editable()}
            return {}

    def focused_editable(self) -> bool:
        result = self.call(
            "Runtime.evaluate",
            expression="""(() => {
              const el = document.activeElement;
              if (!el || el === document.body || el === document.documentElement) return false;
              if (el.isContentEditable) return true;
              const tag = (el.tagName || '').toUpperCase();
              if (tag === 'TEXTAREA') return !el.readOnly && !el.disabled;
              if (tag === 'INPUT') {
                const type = (el.type || 'text').toLowerCase();
                if (el.readOnly || el.disabled) return false;
                return ['text','search','email','password','url','tel','number'].indexOf(type) >= 0;
              }
              return false;
            })()""",
            returnByValue=True,
        )
        return bool((result.get("result") or {}).get("value"))
