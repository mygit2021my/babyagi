package main

import (
	"fmt"
	"os"

	"gate-addr/seal"
)

func main() {
	if len(os.Args) != 4 || (os.Args[1] != "encrypt" && os.Args[1] != "decrypt") {
		fmt.Fprintln(os.Stderr, "usage: gate-seal encrypt|decrypt <key-hex> <text>")
		os.Exit(2)
	}
	var (
		out string
		err error
	)
	if os.Args[1] == "encrypt" {
		out, err = seal.Encrypt(os.Args[2], os.Args[3])
	} else {
		out, err = seal.Decrypt(os.Args[2], os.Args[3])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed")
		os.Exit(1)
	}
	fmt.Println(out)
}
