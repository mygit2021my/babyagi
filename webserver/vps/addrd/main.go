package main

import (
	"crypto/subtle"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var ciphertext = regexp.MustCompile(`^g1\.[A-Za-z0-9_-]{40,800}$`)

type store struct {
	mu   sync.Mutex
	path string
	blob string
}

func loadStore(path string) *store {
	stored := &store{path: path}
	buf, err := os.ReadFile(path)
	if err != nil {
		return stored
	}
	value := strings.TrimSpace(string(buf))
	if ciphertext.MatchString(value) {
		stored.blob = value
	}
	return stored
}

func (stored *store) get() string {
	stored.mu.Lock()
	defer stored.mu.Unlock()
	return stored.blob
}

func (stored *store) set(value string) error {
	stored.mu.Lock()
	defer stored.mu.Unlock()
	temp := stored.path + ".tmp"
	if err := os.WriteFile(temp, []byte(value+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.Rename(temp, stored.path); err != nil {
		return err
	}
	stored.blob = value
	return nil
}

func boardPage(blob string) string {
	return fmt.Sprintf(pageTemplate, strconv.Quote(blob))
}

const waitingPage = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>入口</title>
</head>
<body>
  <p>沙箱还没有上报加密地址。请稍后再打开这个页面。</p>
</body>
</html>
`

const pageTemplate = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
  <title>入口</title>
  <style>
    body { margin: 0; font-family: sans-serif; background: #101418; color: #f4f7fb; }
    main { max-width: 40rem; margin: 0 auto; padding: 2rem 1rem; }
    textarea, input, button { font: inherit; width: 100%%; box-sizing: border-box; }
    textarea { min-height: 7rem; padding: 0.7rem; border-radius: 8px; border: 1px solid #3a4654; background: #1b232c; color: inherit; }
    input { margin-top: 0.75rem; padding: 0.7rem; border-radius: 8px; border: 1px solid #3a4654; background: #1b232c; color: inherit; }
    button { margin-top: 0.75rem; padding: 0.7rem; border: 0; border-radius: 8px; background: #d7e6ff; color: #102033; }
    p.err { color: #ffb4ab; }
  </style>
</head>
<body>
<main>
  <h1>加密地址</h1>
  <p>下面是一串密文。口令只留在这台浏览器里，不会发回云服务器。</p>
  <textarea id="cipher" readonly></textarea>
  <input id="key" autocomplete="off" placeholder="解密口令" spellcheck="false">
  <button id="open" type="button">解密并打开</button>
  <p id="err" class="err"></p>
</main>
<script>
const blob = %s;
const cipher = document.getElementById("cipher");
const keyBox = document.getElementById("key");
const err = document.getElementById("err");
cipher.value = blob;
keyBox.value = localStorage.getItem("gate-addr-key") || "";

function bytesFromHex(hex) {
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error("key");
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

function bytesFromBase64Url(text) {
  let padded = text.replace(/-/g, "+").replace(/_/g, "/");
  while (padded.length %% 4) padded += "=";
  const raw = atob(padded);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function decrypt(keyHex, value) {
  if (!value.startsWith("g1.")) throw new Error("blob");
  const raw = bytesFromBase64Url(value.slice(3));
  const iv = raw.slice(0, 12);
  const data = raw.slice(12);
  const cryptoKey = await crypto.subtle.importKey("raw", bytesFromHex(keyHex), "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv }, cryptoKey, data);
  return new TextDecoder().decode(plain);
}

async function openAddress() {
  err.textContent = "";
  const keyHex = keyBox.value.trim().toLowerCase();
  try {
    const url = await decrypt(keyHex, blob);
    if (!/^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(url)) throw new Error("url");
    localStorage.setItem("gate-addr-key", keyHex);
    location.href = url;
  } catch (e) {
    err.textContent = "口令不正确，或这串内容已损坏";
  }
}

document.getElementById("open").addEventListener("click", openAddress);
keyBox.addEventListener("keydown", function (event) {
  if (event.key === "Enter") openAddress();
});
if (keyBox.value) openAddress();
</script>
</body>
</html>
`

func main() {
	listen := flag.String("listen", "0.0.0.0:80", "listen address")
	tokenFile := flag.String("token-file", "/etc/gate-addr/token", "shared token")
	urlFile := flag.String("url-file", "/var/lib/gate-addr/url", "stored ciphertext")
	flag.Parse()

	tokenBuf, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatal(err)
	}
	token := strings.TrimSpace(string(tokenBuf))
	if token == "" {
		log.Fatal("empty token")
	}
	stored := loadStore(*urlFile)

	mux := http.NewServeMux()
	mux.HandleFunc("/address", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		switch r.Method {
		case http.MethodGet:
			current := stored.get()
			if current == "" {
				http.Error(w, "还没有地址\n", http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = io.WriteString(w, current+"\n")
		case http.MethodPost:
			got := r.Header.Get("X-Gate-Token")
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				http.Error(w, "令牌不正确\n", http.StatusUnauthorized)
				return
			}
			body, err := io.ReadAll(io.LimitReader(r.Body, 1024))
			if err != nil {
				http.Error(w, "读失败\n", http.StatusBadRequest)
				return
			}
			value := strings.TrimSpace(string(body))
			if !ciphertext.MatchString(value) {
				http.Error(w, "地址格式不正确\n", http.StatusBadRequest)
				return
			}
			if err := stored.set(value); err != nil {
				http.Error(w, "保存失败\n", http.StatusInternalServerError)
				return
			}
			log.Printf("ciphertext stored (%d bytes)", len(value))
			w.WriteHeader(http.StatusNoContent)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "方法不支持\n", http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "请用浏览器打开入口\n", http.StatusMethodNotAllowed)
			return
		}
		current := stored.get()
		if current == "" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, waitingPage)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, boardPage(current))
	})

	server := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s", *listen)
	log.Fatal(server.ListenAndServe())
}
