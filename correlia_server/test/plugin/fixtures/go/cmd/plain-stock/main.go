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
	if err := fixture.Run(config, false); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
