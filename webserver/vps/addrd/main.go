package main

import (
	"crypto/subtle"
	"flag"
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

func writeText(w http.ResponseWriter, r *http.Request, status int, body string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		_, _ = io.WriteString(w, body)
	}
}

func main() {
	listen := flag.String("listen", "0.0.0.0:80", "listen address")
	tokenFile := flag.String("token-file", "/etc/gate-addr/token", "shared token")
	urlFile := flag.String("url-file", "/var/lib/gate-addr/url", "stored value")
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
				writeText(w, r, http.StatusNotFound, "404 Not Found\n")
				return
			}
			writeText(w, r, http.StatusOK, current+"\n")
		case http.MethodPost:
			got := r.Header.Get("X-Gate-Token")
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				writeText(w, r, http.StatusUnauthorized, "401 Unauthorized\n")
				return
			}
			body, err := io.ReadAll(io.LimitReader(r.Body, 1024))
			if err != nil {
				writeText(w, r, http.StatusBadRequest, "400 Bad Request\n")
				return
			}
			value := strings.TrimSpace(string(body))
			if !ciphertext.MatchString(value) {
				writeText(w, r, http.StatusBadRequest, "400 Bad Request\n")
				return
			}
			if err := stored.set(value); err != nil {
				writeText(w, r, http.StatusInternalServerError, "500 Internal Server Error\n")
				return
			}
			log.Printf("stored %d bytes", len(value))
			w.Header().Set("Cache-Control", "no-store")
			w.WriteHeader(http.StatusNoContent)
		default:
			w.Header().Set("Allow", "GET, POST")
			writeText(w, r, http.StatusMethodNotAllowed, "405 Method Not Allowed\n")
		}
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeText(w, r, http.StatusForbidden, "403 Forbidden\n")
	})

	server := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s", *listen)
	log.Fatal(server.ListenAndServe())
}
