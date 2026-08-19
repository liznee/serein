//go:build !windows

// Non-Windows stub for input injection. The bridge only runs on Windows,
// but this stub allows go vet and IDE analysis on other platforms.
package main

import "fmt"

func handleInputEvent(data []byte) error {
	return fmt.Errorf("input injection not supported on this platform")
}

func releaseAllInput() {}
