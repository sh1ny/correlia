package main

import (
	"fmt"
	"io"
	"os"
)

func watchStdin() {
	stderr := os.Stderr
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		_, _ = fmt.Fprintln(stderr, `{"event":"stdin_eof"}`)
		os.Exit(0)
	}()
}
