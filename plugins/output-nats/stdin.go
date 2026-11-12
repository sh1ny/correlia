package main

import (
	"io"
	"os"
)

func watchStdin() {
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()
}
