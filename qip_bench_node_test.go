package main

import (
	"context"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestNodeBenchRunsContentComponentInOneProcess(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("Node.js is not installed")
	}
	body, err := os.ReadFile("text/hello.wasm")
	if err != nil {
		t.Fatal(err)
	}

	response, err := runNodeBench(
		context.Background(),
		[][]byte{body},
		[]byte("World"),
		3,
		10*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(response.results) != 1 {
		t.Fatalf("got %d results, want 1", len(response.results))
	}
	result := response.results[0]
	if result.sampleCount != 3 {
		t.Fatalf("got %d samples, want 3", result.sampleCount)
	}
	if got, want := string(result.output.bytes), "Hello, World"; got != want {
		t.Fatalf("got output %q, want %q", got, want)
	}
	if result.output.encoding != dataEncodingUTF8 {
		t.Fatalf("got encoding %v, want UTF-8", result.output.encoding)
	}
	if result.summary.total.mean <= 0 {
		t.Fatalf("got non-positive mean duration %s", result.summary.total.mean)
	}
	if response.nodeVersion == "" || response.v8Version == "" {
		t.Fatal("Node.js response omitted runtime versions")
	}
}
