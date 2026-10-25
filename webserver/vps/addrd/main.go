package main

import (
	"crypto/subtle"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

var tunnelURL = regexp.MustCompile(`^https://[a-z0-9-]+\.trycloudflare\.com$`)

type store struct {
	mu   sync.Mutex
	path string
	url  string
}

func loadStore(path string) *store {
	stored := &store{path: path}
	buf, err := os.ReadFile(path)
	if err != nil {
		return stored
	}
	value := strings.TrimSpace(string(buf))
	if tunnelURL.MatchString(value) {
		stored.url = value
	}
	return stored
}

func (stored *store) get() string {
	stored.mu.Lock()
	defer stored.mu.Unlock()
	return stored.url
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
	stored.url = value
	return nil
}

func join(base, requestURI string) string {
	if requestURI == "" || requestURI == "/" {
		return base
	}
	if !strings.HasPrefix(requestURI, "/") || strings.Contains(requestURI, "//") || strings.Contains(requestURI, "\\") || strings.Contains(requestURI, "://") || strings.Contains(requestURI, "..") {
		return base
	}
	for _, char := range requestURI {
		if char < 0x20 || char > 0x7e {
			return base
		}
	}
	return base + requestURI
}

const waitingPage = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>入口</title>
</head>
<body>
  <p>沙箱还没有上报 Cloudflare 地址。请稍后再打开这个页面。</p>
</body>
</html>
`

func main() {
	listen := flag.String("listen", "0.0.0.0:80", "listen address")
	tokenFile := flag.String("token-file", "/etc/gate-addr/token", "shared token")
	urlFile := flag.String("url-file", "/var/lib/gate-addr/url", "stored Cloudflare address")
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
			body, err := io.ReadAll(io.LimitReader(r.Body, 512))
			if err != nil {
				http.Error(w, "读失败\n", http.StatusBadRequest)
				return
			}
			value := strings.TrimSpace(string(body))
			if !tunnelURL.MatchString(value) {
				http.Error(w, "地址格式不正确\n", http.StatusBadRequest)
				return
			}
			if err := stored.set(value); err != nil {
				http.Error(w, "保存失败\n", http.StatusInternalServerError)
				return
			}
			log.Printf("address updated: %s", value)
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
		http.Redirect(w, r, join(current, r.URL.RequestURI()), http.StatusFound)
	})

	server := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s", *listen)
	log.Fatal(server.ListenAndServe())
}
