package seal

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
)

var (
	blobPattern   = regexp.MustCompile(`^g1\.[A-Za-z0-9_-]{40,800}$`)
	tunnelPattern = regexp.MustCompile(`^https://[a-z0-9-]+\.trycloudflare\.com$`)
)

func Valid(value string) bool {
	return blobPattern.MatchString(value)
}

func Encrypt(keyHex, url string) (string, error) {
	if !tunnelPattern.MatchString(url) {
		return "", errors.New("url")
	}
	key, err := hex.DecodeString(strings.TrimSpace(keyHex))
	if err != nil || len(key) != 32 {
		return "", errors.New("key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := gcm.Seal(nil, nonce, []byte(url), nil)
	buf := make([]byte, 0, len(nonce)+len(sealed))
	buf = append(buf, nonce...)
	buf = append(buf, sealed...)
	return "g1." + base64.RawURLEncoding.EncodeToString(buf), nil
}

func Decrypt(keyHex, blob string) (string, error) {
	blob = strings.TrimSpace(blob)
	if !Valid(blob) {
		return "", errors.New("blob")
	}
	key, err := hex.DecodeString(strings.TrimSpace(keyHex))
	if err != nil || len(key) != 32 {
		return "", errors.New("key")
	}
	raw, err := base64.RawURLEncoding.DecodeString(blob[3:])
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(raw) < gcm.NonceSize()+16 {
		return "", errors.New("short")
	}
	nonce := raw[:gcm.NonceSize()]
	sealed := raw[gcm.NonceSize():]
	plain, err := gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return "", err
	}
	url := string(plain)
	if !tunnelPattern.MatchString(url) {
		return "", errors.New("url")
	}
	return url, nil
}
