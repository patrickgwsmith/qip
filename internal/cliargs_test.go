package qinternal

import (
	"reflect"
	"testing"
)

func TestNormalizeComplyArgs(t *testing.T) {
	in := []string{
		"impl.wasm",
		"--with",
		"a.wasm",
		"--with",
		"b.wasm",
		"--straight-line-oracles",
		"--seed",
		"500",
	}
	got := normalizeComplyArgs(in)
	want := []string{
		"--with",
		"a.wasm",
		"--with",
		"b.wasm",
		"--straight-line-oracles",
		"--seed",
		"500",
		"impl.wasm",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestNormalizeFlagArgsPreservingPositionalOptions(t *testing.T) {
	in := []string{"module.wasm", "-u", "width=640", "--max-memory", "1048576"}
	got := NormalizeFlagArgsPreserving(
		in,
		map[string]struct{}{"--max-memory": {}},
		map[string]struct{}{"-u": {}},
	)
	want := []string{"--max-memory", "1048576", "--", "module.wasm", "-u", "width=640"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestNormalizeFlagArgsPreservesDoubleDash(t *testing.T) {
	in := []string{"module.wasm", "--", "--not-a-flag"}
	got := NormalizeFlagArgs(in, map[string]struct{}{
		"--timeout-ms": {},
	})
	want := []string{"--", "module.wasm", "--not-a-flag"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}
