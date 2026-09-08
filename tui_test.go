package main

import (
	"bytes"
	"context"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestTUIKeyDecoder(t *testing.T) {
	tests := []struct {
		name   string
		input  []byte
		keysym uint32
		flags  uint32
	}{
		{"lowercase", []byte("a"), 'a', 0},
		{"uppercase", []byte("A"), 'A', tuiFlagShift},
		{"question mark", []byte("?"), '?', 0},
		{"tab", []byte{0x09}, tuiXKTab, 0},
		{"backspace control-H", []byte{0x08}, tuiXKBackspace, 0},
		{"backspace DEL", []byte{0x7f}, tuiXKBackspace, 0},
		{"return", []byte{0x0d}, tuiXKReturn, 0},
		{"left", []byte("\x1b[D"), tuiXKLeft, 0},
		{"control-left", []byte("\x1b[1;5D"), tuiXKLeft, tuiFlagControl},
		{"F5", []byte("\x1b[15~"), tuiXKF1 + 4, 0},
		{"F10", []byte("\x1b[21~"), tuiXKF1 + 9, 0},
		{"Shift-F11", []byte("\x1b[23;2~"), tuiXKF1 + 10, tuiFlagShift},
		{"Alt-[", []byte("\x1b["), '[', tuiFlagAlt},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			decoder := tuiKeyDecoder{}
			keys, pending := decoder.push(test.input, true)
			if pending {
				t.Fatal("decoder retained input after final flush")
			}
			want := []tuiKey{{keysym: test.keysym, flags: test.flags}}
			if !reflect.DeepEqual(keys, want) {
				t.Fatalf("keys=%+v, want %+v", keys, want)
			}
		})
	}
}

func TestTUIKeyDecoderRetainsSplitInput(t *testing.T) {
	decoder := tuiKeyDecoder{}
	keys, pending := decoder.push([]byte("\x1b["), false)
	if len(keys) != 0 || !pending {
		t.Fatalf("first push keys=%v pending=%v", keys, pending)
	}
	keys, pending = decoder.push([]byte{'D', 0xc3}, false)
	if !reflect.DeepEqual(keys, []tuiKey{{keysym: tuiXKLeft}}) || !pending {
		t.Fatalf("second push keys=%v pending=%v", keys, pending)
	}
	keys, pending = decoder.push([]byte{0xa9}, false)
	if !reflect.DeepEqual(keys, []tuiKey{{keysym: 0xe9}}) || pending {
		t.Fatalf("third push keys=%v pending=%v", keys, pending)
	}
}

func TestValidateTerminalFrame(t *testing.T) {
	safe := []byte("plain é\n\x1b[1;96mbold cyan\x1b[0m")
	if err := validateTerminalFrame(safe); err != nil {
		t.Fatalf("safe frame rejected: %v", err)
	}
	unsafe := [][]byte{
		[]byte("\x1b[Hcursor"),
		[]byte("\x1b]52;c;YQ==\x07"),
		[]byte("tab\there"),
		[]byte("back\bspace"),
		[]byte("return\r"),
		[]byte("\u0085"),
		[]byte("\x1b[38;5;196mindexed"),
		[]byte("\x1b[38;2;1;2;3mrgb"),
	}
	for _, frame := range unsafe {
		if err := validateTerminalFrame(frame); err == nil {
			t.Fatalf("unsafe frame accepted: %q", frame)
		}
	}
}

func TestWriteTUIFrameExpandsLineFeedsAfterRawMode(t *testing.T) {
	var output bytes.Buffer
	if err := writeTUIFrame(&output, []byte("one\ntwo\n")); err != nil {
		t.Fatal(err)
	}
	want := "\x1b[H\x1b[Jone\r\ntwo\r\n\x1b[0m\x1b[J"
	if output.String() != want {
		t.Fatalf("frame=%q, want %q", output.String(), want)
	}
}

func TestTUISessionRendersDebuggerThroughContentStep(t *testing.T) {
	debugger, err := os.ReadFile("components/interactive/qipdb.wasm")
	if err != nil {
		t.Fatal(err)
	}
	strip, err := os.ReadFile("components/text/strip-ansi-sgr.wasm")
	if err != nil {
		t.Fatal(err)
	}
	form, contentType, err := buildMultipartFormInput([]string{
		"component=@components/text/wc.wasm",
		"input=The quick brown fox jumps over the lazy dog",
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	config := runCommandConfig{
		opts: options{
			contentTypeChecking:    ContentTypeCheckingStrong,
			trustFirstStageContent: true,
		},
		timeoutMS: 5000,
	}
	components := []ResolvedComponent{
		{Name: "qipdb.wasm", WASM: debugger, UniformValues: map[string]string{"instruction_budget": "1000"}},
		{Name: "strip-ansi-sgr.wasm", WASM: strip, UniformValues: map[string]string{}},
	}
	session, err := newTUISession(context.Background(), config, components, form, contentType)
	if err != nil {
		t.Fatal(err)
	}
	defer session.close(context.Background())
	dimensions := tuiDimensions{columns: 80, lines: 24}
	frame, err := session.renderFrame(true, dimensions)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(frame, []byte("\x1b[")) {
		t.Fatal("post-processing step did not strip ANSI")
	}
	if !strings.Contains(string(frame), "INSTRUCTIONS") || !strings.Contains(string(frame), "MEMORY") {
		t.Fatalf("unexpected debugger frame:\n%s", frame)
	}
	startedAt := time.Now()
	wake, accepted, committed, err := session.update([]tuiKey{{keysym: 's'}}, 0, startedAt, 0, dimensions)
	if err != nil {
		t.Fatal(err)
	}
	if !accepted || wake != committed {
		t.Fatalf("update accepted=%v wake=%d committed=%d", accepted, wake, committed)
	}
	if _, err := session.renderFrame(false, dimensions); err != nil {
		t.Fatal(err)
	}
}
