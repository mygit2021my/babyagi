package seal

import (
	"strings"
	"testing"
)

func TestRoundTripHidesTheName(t *testing.T) {
	key := "1a253933d94f3ad63c981d90cb5100c0c4956c0cd0737fa713db04325824ab42"
	url := "https://marc-sample-blvd-fruits.trycloudflare.com"
	first, err := Encrypt(key, url)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Encrypt(key, url)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("nonce was reused")
	}
	if strings.Contains(first, "marc-sample") || strings.Contains(first, "trycloudflare") {
		t.Fatal(first)
	}
	got, err := Decrypt(key, first)
	if err != nil {
		t.Fatal(err)
	}
	if got != url {
		t.Fatalf("got %s", got)
	}
	mid := len(first) / 2
	replacement := "A"
	if first[mid] == 'A' {
		replacement = "B"
	}
	bad := first[:mid] + replacement + first[mid+1:]
	if _, err := Decrypt(key, bad); err == nil {
		t.Fatal("tampered blob decrypted")
	}
	if _, err := Decrypt("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", first); err == nil {
		t.Fatal("wrong key decrypted")
	}
}
