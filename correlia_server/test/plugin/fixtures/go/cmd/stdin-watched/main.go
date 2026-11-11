package main

import (
	"fmt"
	"os"

	"correlia.local/pluginspike/internal/fixture"
)

func main() {
	config, err := fixture.ParseConfig(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if config.EOFMarker == "" {
		fmt.Fprintln(os.Stderr, "--eof-marker is required")
		os.Exit(2)
	}
	if err := fixture.Run(config, true); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
