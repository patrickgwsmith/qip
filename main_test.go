package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasminspect"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
)

func TestParseRecipeFilename(t *testing.T) {
	t.Run("active", func(t *testing.T) {
		order, disabled, err := parseRecipeFilename("10-markdown.wasm")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if disabled {
			t.Fatalf("expected active recipe")
		}
		if order != 10 {
			t.Fatalf("order=%d, want 10", order)
		}
	})

	t.Run("disabled", func(t *testing.T) {
		order, disabled, err := parseRecipeFilename("-99-wrap.wasm")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !disabled {
			t.Fatalf("expected disabled recipe")
		}
		if order != 99 {
			t.Fatalf("order=%d, want 99", order)
		}
	})

	t.Run("invalid", func(t *testing.T) {
		cases := []string{
			"10-markdown.wat",
			"a0-markdown.wasm",
			"10.wasm",
			"10-.wasm",
			"10-rendér.wasm",
		}
		for _, filename := range cases {
			if _, _, err := parseRecipeFilename(filename); err == nil {
				t.Fatalf("expected error for %q", filename)
			}
		}
	})
}

func TestContentRequestPaths(t *testing.T) {
	root := t.TempDir()
	mustWrite := func(rel string) {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	mustWrite("index.html")
	mustWrite("docs/index.html")
	mustWrite("guide/start.md")
	mustWrite("how-it-works.uri")
	mustWrite("images/logo.png")

	routes, err := qinternal.BuildContentRoutes(root, qinternal.DefaultRouteOptions())
	if err != nil {
		t.Fatalf("BuildContentRoutes: %v", err)
	}

	checks := map[string]string{
		"/index.html":       "index.html",
		"/":                 "index.html",
		"/docs/index.html":  "docs/index.html",
		"/docs":             "docs/index.html",
		"/docs/":            "docs/index.html",
		"/guide/start.md":   "guide/start.md",
		"/guide/start":      "guide/start.md",
		"/how-it-works.uri": "how-it-works.uri",
		"/how-it-works":     "how-it-works.uri",
		"/images/logo.png":  "images/logo.png",
	}
	for requestPath, wantRel := range checks {
		route, ok := routes[requestPath]
		if !ok {
			t.Fatalf("missing route for %s", requestPath)
		}
		wantFull := filepath.Join(root, filepath.FromSlash(wantRel))
		if route.FilePath != wantFull {
			t.Fatalf("route %s file=%s, want %s", requestPath, route.FilePath, wantFull)
		}
	}
	if route, ok := routes["/how-it-works"]; !ok {
		t.Fatalf("missing route for /how-it-works")
	} else if route.SourceMIME != "text/uri-list" {
		t.Fatalf("route /how-it-works source mime=%q, want %q", route.SourceMIME, "text/uri-list")
	}
}

func TestContentRequestPathsWithSymlinks(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	mustWrite := func(base string, rel string, data []byte) {
		full := filepath.Join(base, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(full, data, 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	mustWrite(external, "docs/index.html", []byte("<h1>Docs</h1>"))
	mustWrite(external, "docs/guide.md", []byte("Guide"))
	mustWrite(external, "shared.txt", []byte("Shared"))

	if err := os.Symlink(filepath.Join(external, "docs"), filepath.Join(root, "docs")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := os.Symlink(filepath.Join(external, "shared.txt"), filepath.Join(root, "shared.txt")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	routes, err := qinternal.BuildContentRoutes(root, qinternal.DefaultRouteOptions())
	if err != nil {
		t.Fatalf("BuildContentRoutes: %v", err)
	}

	checks := map[string]string{
		"/docs/index.html": "docs/index.html",
		"/docs":            "docs/index.html",
		"/docs/":           "docs/index.html",
		"/docs/guide.md":   "docs/guide.md",
		"/docs/guide":      "docs/guide.md",
		"/shared.txt":      "shared.txt",
	}
	for requestPath, wantRel := range checks {
		route, ok := routes[requestPath]
		if !ok {
			t.Fatalf("missing route for %s", requestPath)
		}
		wantFull := filepath.Join(root, filepath.FromSlash(wantRel))
		if route.FilePath != wantFull {
			t.Fatalf("route %s file=%s, want %s", requestPath, route.FilePath, wantFull)
		}
	}
}

func TestResolveDevContentRoute(t *testing.T) {
	routes := map[string]qinternal.ContentRoute{
		"/docs":  {FilePath: "docs/index.md", SourceMIME: "text/markdown"},
		"/docs/": {FilePath: "docs/index.md", SourceMIME: "text/markdown"},
	}

	if _, ok := qinternal.ResolveContentRoute(routes, "/docs", qinternal.DefaultRouteOptions()); !ok {
		t.Fatal("expected /docs to resolve")
	}
	if _, ok := qinternal.ResolveContentRoute(routes, "/docs/", qinternal.DefaultRouteOptions()); !ok {
		t.Fatal("expected /docs/ to resolve")
	}
	if _, ok := qinternal.ResolveContentRoute(routes, "/missing", qinternal.DefaultRouteOptions()); ok {
		t.Fatal("expected /missing to be unresolved")
	}
}

func TestNormalizeDevArgs(t *testing.T) {
	t.Run("content first", func(t *testing.T) {
		in := []string{"docs/", "--recipes", "recipes/", "-p", "4004"}
		got := normalizeDevArgs(in)
		want := []string{"--recipes", "recipes/", "-p", "4004", "docs/"}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("args=%v, want %v", got, want)
		}
	})

	t.Run("flags first unchanged", func(t *testing.T) {
		in := []string{"--recipes", "recipes/", "-p", "4004", "docs/"}
		got := normalizeDevArgs(in)
		if !reflect.DeepEqual(got, in) {
			t.Fatalf("args=%v, want %v", got, in)
		}
	})

	t.Run("trailing flags after content are normalized", func(t *testing.T) {
		in := []string{"docs/", "--recipes", "recipes/", "--mode", "dev", "-p", "4004"}
		got := normalizeDevArgs(in)
		want := []string{"--recipes", "recipes/", "--mode", "dev", "-p", "4004", "docs/"}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("args=%v, want %v", got, want)
		}
	})
}

func TestLegacyDevNoticePointsToRouterCommand(t *testing.T) {
	var output bytes.Buffer
	writeLegacyDevNotice(&output)
	got := output.String()
	if !strings.Contains(got, "qip router dev") {
		t.Fatalf("legacy notice does not name replacement command: %q", got)
	}
	if !strings.Contains(got, "continue to work") {
		t.Fatalf("legacy notice does not explain compatibility: %q", got)
	}
}

func TestNormalizeRunArgs(t *testing.T) {
	in := []string{
		"components/text/trim.wasm",
		"?x=1",
		"components/text/wc.wasm",
		"-o",
		"out.txt",
		"--timeout-ms",
		"2500",
		"--max-memory",
		"1048576",
		"--allow-memory-grow",
	}
	got := normalizeRunArgs(in)
	want := []string{
		"-o",
		"out.txt",
		"--timeout-ms",
		"2500",
		"--max-memory",
		"1048576",
		"--allow-memory-grow",
		"components/text/trim.wasm",
		"?x=1",
		"components/text/wc.wasm",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}

	inWithUniform := []string{"module.wasm", "-u", "width=640", "--max-memory", "1048576"}
	gotWithUniform := normalizeRunArgs(inWithUniform)
	wantWithUniform := []string{"--max-memory", "1048576", "--", "module.wasm", "-u", "width=640"}
	if !reflect.DeepEqual(gotWithUniform, wantWithUniform) {
		t.Fatalf("args=%v, want %v", gotWithUniform, wantWithUniform)
	}

	inWithDashDash := []string{"module.wasm", "--", "--not-a-flag"}
	gotWithDashDash := normalizeRunArgs(inWithDashDash)
	wantWithDashDash := []string{"--", "module.wasm", "--not-a-flag"}
	if !reflect.DeepEqual(gotWithDashDash, wantWithDashDash) {
		t.Fatalf("args=%v, want %v", gotWithDashDash, wantWithDashDash)
	}
}

func TestNormalizeBenchArgsWithMultipartInput(t *testing.T) {
	in := []string{
		"components/interactive/qipdb.wasm",
		"-F",
		"component=@components/text/hello.wasm",
		"--form",
		"input=hello",
		"-r",
		"3",
	}
	got := normalizeBenchArgs(in)
	want := []string{
		"-F",
		"component=@components/text/hello.wasm",
		"--form",
		"input=hello",
		"-r",
		"3",
		"components/interactive/qipdb.wasm",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestApplyModulePolicyFlags(t *testing.T) {
	t.Run("fixed memory by default", func(t *testing.T) {
		var opts options
		if err := applyModulePolicyFlags(&opts, 0, false); err != nil {
			t.Fatalf("applyModulePolicyFlags: %v", err)
		}
		if !reflect.DeepEqual(opts.modulePolicy.RejectOpcodes, []wasminspect.InstructionOpcode{wasminspect.OpcodeMemoryGrow}) {
			t.Fatalf("RejectOpcodes=%v, want memory.grow", opts.modulePolicy.RejectOpcodes)
		}
	})

	t.Run("growth requires cap", func(t *testing.T) {
		var opts options
		err := applyModulePolicyFlags(&opts, 0, true)
		if err == nil || !strings.Contains(err.Error(), "requires --max-memory") {
			t.Fatalf("error=%v, want max-memory requirement", err)
		}
	})

	t.Run("capped growth", func(t *testing.T) {
		var opts options
		if err := applyModulePolicyFlags(&opts, 1048576, true); err != nil {
			t.Fatalf("applyModulePolicyFlags: %v", err)
		}
		if opts.modulePolicy.MaxMemoryBytes != 1048576 {
			t.Fatalf("MaxMemoryBytes=%d, want 1048576", opts.modulePolicy.MaxMemoryBytes)
		}
		if len(opts.modulePolicy.RejectOpcodes) != 0 {
			t.Fatalf("RejectOpcodes=%v, want none", opts.modulePolicy.RejectOpcodes)
		}
	})
}

func TestNormalizeRouteArgs(t *testing.T) {
	in := []string{"docs/", "--recipes", "recipes/", "--mode", "dev"}
	got := normalizeRouteArgs(in)
	want := []string{"--recipes", "recipes/", "--mode", "dev", "docs/"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestScaleRouteWARCTransformTimeout(t *testing.T) {
	base := 5 * time.Second
	if got := scaleRouteWARCTransformTimeout(base, 0); got != base {
		t.Fatalf("route count 0 timeout=%v, want %v", got, base)
	}
	if got := scaleRouteWARCTransformTimeout(base, 1); got != base {
		t.Fatalf("route count 1 timeout=%v, want %v", got, base)
	}
	if got := scaleRouteWARCTransformTimeout(base, 5); got != 25*time.Second {
		t.Fatalf("route count 5 timeout=%v, want 25s", got)
	}
}

func TestParseComponentInvocations(t *testing.T) {
	t.Run("associates uniform queries with prior module", func(t *testing.T) {
		specs, err := parseComponentInvocations([]string{
			"a.wasm",
			"?alpha=1&beta=2",
			"b.wasm",
			"?gamma=3",
			"?gamma=4",
		}, "run")
		if err != nil {
			t.Fatalf("parseComponentInvocations error: %v", err)
		}
		if len(specs) != 2 {
			t.Fatalf("len(specs)=%d, want 2", len(specs))
		}
		if specs[0].Source != "a.wasm" {
			t.Fatalf("specs[0].Source=%q, want %q", specs[0].Source, "a.wasm")
		}
		if specs[0].UniformValues["alpha"] != "1" || specs[0].UniformValues["beta"] != "2" {
			t.Fatalf("unexpected uniforms for first module: %+v", specs[0].UniformValues)
		}
		if specs[1].Source != "b.wasm" {
			t.Fatalf("specs[1].Source=%q, want %q", specs[1].Source, "b.wasm")
		}
		if specs[1].UniformValues["gamma"] != "4" {
			t.Fatalf("specs[1].UniformValues[gamma]=%q, want %q", specs[1].UniformValues["gamma"], "4")
		}
	})

	t.Run("associates uniform flags with prior module", func(t *testing.T) {
		specs, err := parseComponentInvocations([]string{
			"a.wasm",
			"-u", "alpha=1",
			"--uniform", "beta=2",
			"b.wasm",
			"-u", "gamma=3",
		}, "run")
		if err != nil {
			t.Fatalf("parseComponentInvocations error: %v", err)
		}
		if len(specs) != 2 {
			t.Fatalf("len(specs)=%d, want 2", len(specs))
		}
		if specs[0].UniformValues["alpha"] != "1" || specs[0].UniformValues["beta"] != "2" {
			t.Fatalf("unexpected uniforms for first module: %+v", specs[0].UniformValues)
		}
		if specs[1].UniformValues["gamma"] != "3" {
			t.Fatalf("unexpected uniforms for second module: %+v", specs[1].UniformValues)
		}
	})

	t.Run("rejects uniform flag before component path", func(t *testing.T) {
		_, err := parseComponentInvocations([]string{"-u", "x=1"}, "run")
		if err == nil || !strings.Contains(err.Error(), "must follow a QIP component path") {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("rejects malformed uniform flag", func(t *testing.T) {
		_, err := parseComponentInvocations([]string{"a.wasm", "-u", "x"}, "run")
		if err == nil || !strings.Contains(err.Error(), "requires <key=value>") {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("rejects uniform query before component path", func(t *testing.T) {
		_, err := parseComponentInvocations([]string{"?x=1"}, "run")
		if err == nil {
			t.Fatal("expected parse error")
		}
		if !strings.Contains(err.Error(), "run uniform query") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}

func TestParseUniformInt(t *testing.T) {
	t.Run("parses decimal values", func(t *testing.T) {
		got, err := parseUniformInt("123", 64)
		if err != nil {
			t.Fatalf("parseUniformInt error: %v", err)
		}
		if got != 123 {
			t.Fatalf("got %d, want 123", got)
		}
	})

	t.Run("parses hex with 0x prefix", func(t *testing.T) {
		got, err := parseUniformInt("0xff4511ff", 64)
		if err != nil {
			t.Fatalf("parseUniformInt error: %v", err)
		}
		if got != 4282716671 {
			t.Fatalf("got %d, want 4282716671", got)
		}
	})

	t.Run("parses signed hex with 0x prefix", func(t *testing.T) {
		got, err := parseUniformInt("-0x7f", 64)
		if err != nil {
			t.Fatalf("parseUniformInt error: %v", err)
		}
		if got != -127 {
			t.Fatalf("got %d, want -127", got)
		}
	})

	t.Run("rejects missing hex prefix", func(t *testing.T) {
		if _, err := parseUniformInt("ff4511ff", 64); err == nil {
			t.Fatal("expected parse error")
		}
	})

	t.Run("rejects invalid hex after prefix", func(t *testing.T) {
		if _, err := parseUniformInt("0xgg", 64); err == nil {
			t.Fatal("expected parse error")
		}
	})

	t.Run("rejects i32 overflow", func(t *testing.T) {
		if _, err := parseUniformInt("0xffffffff", 32); err == nil {
			t.Fatal("expected parse error")
		}
	})
}

func TestValidUniformKey(t *testing.T) {
	valid := []string{"currency", "font_size", "a0", "x_y_z", strings.Repeat("a", 63)}
	for _, key := range valid {
		if !validUniformKey(key) {
			t.Fatalf("validUniformKey(%q)=false", key)
		}
	}
	invalid := []string{"", "Currency", "0currency", "_currency", "currency_", "font__size", "font-size", strings.Repeat("a", 64)}
	for _, key := range invalid {
		if validUniformKey(key) {
			t.Fatalf("validUniformKey(%q)=true", key)
		}
	}
}

func TestParseUniformUint(t *testing.T) {
	t.Run("parses u32 decimal", func(t *testing.T) {
		got, err := parseUniformUint("4294967295", 32)
		if err != nil {
			t.Fatalf("parseUniformUint error: %v", err)
		}
		if got != 4294967295 {
			t.Fatalf("got %d, want 4294967295", got)
		}
	})

	t.Run("parses u32 hex with 0x prefix", func(t *testing.T) {
		got, err := parseUniformUint("0xff4511ff", 32)
		if err != nil {
			t.Fatalf("parseUniformUint error: %v", err)
		}
		if got != 4282716671 {
			t.Fatalf("got %d, want 4282716671", got)
		}
	})

	t.Run("rejects negative u32", func(t *testing.T) {
		if _, err := parseUniformUint("-1", 32); err == nil {
			t.Fatal("expected parse error")
		}
	})

	t.Run("rejects invalid hex", func(t *testing.T) {
		if _, err := parseUniformUint("0xgg", 32); err == nil {
			t.Fatal("expected parse error")
		}
	})

	t.Run("rejects u32 overflow", func(t *testing.T) {
		if _, err := parseUniformUint("0x100000000", 32); err == nil {
			t.Fatal("expected overflow parse error")
		}
	})
}

func TestRunDelayedStdinDoesNotFailExportResolution(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=TestHelperRunModuleCLI", "--", "components/text/html/html-link-extractor.wasm")
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start helper: %v", err)
	}

	// Delay long enough to fail old behavior where wasm timeout started before stdin read.
	time.Sleep(500 * time.Millisecond)
	if _, err := stdin.Write([]byte(`<a href="/x">X</a>`)); err != nil {
		_ = cmd.Process.Kill()
		t.Fatalf("write stdin: %v", err)
	}
	_ = stdin.Close()

	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper failed: %v\nstderr: %s\nstdout: %s", err, stderr.String(), stdout.String())
	}
	if !strings.Contains(stdout.String(), "/x X") {
		t.Fatalf("unexpected output: %q", stdout.String())
	}
}

func TestRunModuleExecutionErrorIncludesModulePath(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"--timeout-ms",
		"1",
		"components/text/infinite-loop.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatalf("expected run to fail, stdout=%q stderr=%q", stdout.String(), stderr.String())
	}

	gotErr := stderr.String()
	if !strings.Contains(gotErr, "step 1 (components/text/infinite-loop.wasm): render trapped:") {
		t.Fatalf("stderr=%q, want step, component path, and render failure", gotErr)
	}
	if !strings.Contains(gotErr, "Wasm module exceeded the execution time limit") {
		t.Fatalf("stderr=%q, want execution timeout message", gotErr)
	}
}

func TestRunRejectionNamesPipelineStepAndComponent(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"--trace-with",
		"components/application/wasm/wasm-trace-instrument.wasm",
		"components/bytes/base64-encode.wasm",
		"components/bytes/zlib-decompress.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	cmd.Stdin = strings.NewReader("not zlib")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err == nil {
		t.Fatalf("expected rejection, stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("rejected pipeline wrote stdout=%q", stdout.String())
	}
	got := stderr.String()
	if !strings.Contains(got, "step 2 (components/bytes/zlib-decompress.wasm): component rejected input") {
		t.Fatalf("stderr=%q, want step, component, and rejection", got)
	}
	if strings.Contains(got, "trace retry") {
		t.Fatalf("stderr=%q, input rejection must not trigger trap tracing", got)
	}
}

func TestRunAppliesUniformQueries(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("line1\nline2\nline3"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	runOnce := func(extraArgs ...string) []byte {
		args := []string{"-test.run=TestHelperRunModuleCLI", "--", "-i", inputPath, "components/text/text-to-bmp.wasm"}
		args = append(args, extraArgs...)
		cmd := exec.Command(os.Args[0], args...)
		cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
		}
		return stdout.Bytes()
	}

	base := runOnce()
	withUniform := runOnce("?leading=40")

	baseW, baseH, err := qinternal.GetBMPDimensions(base)
	if err != nil {
		t.Fatalf("base output is not bmp: %v", err)
	}
	withUniformW, withUniformH, err := qinternal.GetBMPDimensions(withUniform)
	if err != nil {
		t.Fatalf("uniform output is not bmp: %v", err)
	}

	if baseW != withUniformW {
		t.Fatalf("width changed unexpectedly: base=%d uniform=%d", baseW, withUniformW)
	}
	if baseH == withUniformH {
		t.Fatalf("expected height to change with uniform; base=%d uniform=%d", baseH, withUniformH)
	}
}

func TestRunAppliesColsUniform(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("abcdefghij"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	runOnce := func(extraArgs ...string) []byte {
		args := []string{"-test.run=TestHelperRunModuleCLI", "--", "-i", inputPath, "components/text/text-to-bmp.wasm"}
		args = append(args, extraArgs...)
		cmd := exec.Command(os.Args[0], args...)
		cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
		}
		return stdout.Bytes()
	}

	base := runOnce()
	withUniform := runOnce("?cols=10")

	baseW, baseH, err := qinternal.GetBMPDimensions(base)
	if err != nil {
		t.Fatalf("base output is not bmp: %v", err)
	}
	withUniformW, withUniformH, err := qinternal.GetBMPDimensions(withUniform)
	if err != nil {
		t.Fatalf("uniform output is not bmp: %v", err)
	}

	if baseW == withUniformW {
		t.Fatalf("expected width to change with uniform; base=%d uniform=%d", baseW, withUniformW)
	}
	if withUniformW != 80 {
		t.Fatalf("uniform width=%d, want %d", withUniformW, 80)
	}
	if withUniformH < baseH {
		t.Fatalf("height unexpectedly decreased: base=%d uniform=%d", baseH, withUniformH)
	}
}

func TestRunOutputFlagWritesToFile(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("  hello  \n"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}
	outputPath := filepath.Join(t.TempDir(), "out.txt")

	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"-i",
		inputPath,
		"-o",
		outputPath,
		"components/text/trim.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout should be empty when -o is set, got %q", stdout.String())
	}

	got, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read output file: %v", err)
	}
	if string(got) != "hello" {
		t.Fatalf("output file=%q, want %q", string(got), "hello")
	}
}

func TestRunOutputFlagAtEndWritesToFile(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("  hello  \n"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}
	outputPath := filepath.Join(t.TempDir(), "out.txt")

	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"-i",
		inputPath,
		"components/text/trim.wasm",
		"-o",
		outputPath,
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout should be empty when -o is set, got %q", stdout.String())
	}

	got, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read output file: %v", err)
	}
	if string(got) != "hello" {
		t.Fatalf("output file=%q, want %q", string(got), "hello")
	}
}

func TestRunDoubleDashTreatsFollowingAsPositional(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"--",
		"--not-a-flag",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatalf("expected run to fail due to missing module file")
	}
	gotErr := stderr.String()
	if strings.Contains(gotErr, "flag provided but not defined") {
		t.Fatalf("stderr=%q, expected '--not-a-flag' to be treated as positional", gotErr)
	}
	if !strings.Contains(gotErr, "open --not-a-flag") {
		t.Fatalf("stderr=%q, expected file-open error for positional component path", gotErr)
	}
}

func TestRunOutputFlagImageReencodeByExtension(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("qip"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	tests := []struct {
		name     string
		fileName string
		checkSig []byte
	}{
		{name: "png", fileName: "out.png", checkSig: []byte{0x89, 'P', 'N', 'G'}},
		{name: "jpg", fileName: "out.jpg", checkSig: []byte{0xFF, 0xD8}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			outputPath := filepath.Join(t.TempDir(), tc.fileName)
			cmd := exec.Command(
				os.Args[0],
				"-test.run=TestHelperRunModuleCLI",
				"--",
				"-i",
				inputPath,
				"-o",
				outputPath,
				"components/text/text-to-bmp.wasm",
			)
			cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr

			if err := cmd.Run(); err != nil {
				t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
			}
			if stdout.Len() != 0 {
				t.Fatalf("stdout should be empty when -o is set, got %q", stdout.String())
			}

			got, err := os.ReadFile(outputPath)
			if err != nil {
				t.Fatalf("read output file: %v", err)
			}
			if len(got) < len(tc.checkSig) || !bytes.Equal(got[:len(tc.checkSig)], tc.checkSig) {
				t.Fatalf("unexpected file signature for %s", tc.fileName)
			}
			img, _, err := image.Decode(bytes.NewReader(got))
			if err != nil {
				t.Fatalf("decode encoded image: %v", err)
			}
			if img.Bounds().Dx() <= 0 || img.Bounds().Dy() <= 0 {
				t.Fatalf("invalid output image bounds: %v", img.Bounds())
			}
		})
	}
}

func TestRunInteractiveModuleOutputsInitialContent(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"components/interactive/tile-world-12x12.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if stdout.Len() == 0 {
		t.Fatal("expected KTX2 bytes on stdout")
	}
	output := stdout.Bytes()
	identifier := []byte{0xab, 'K', 'T', 'X', ' ', '2', '0', 0xbb, 0x0d, 0x0a, 0x1a, 0x0a}
	if len(output) < 28 || !bytes.Equal(output[:len(identifier)], identifier) {
		t.Fatal("stdout was not KTX2")
	}
	w := binary.LittleEndian.Uint32(output[20:24])
	h := binary.LittleEndian.Uint32(output[24:28])
	if w != 288 || h != 288 {
		t.Fatalf("KTX2 dimensions=%dx%d, want 288x288", w, h)
	}
}

func TestRunOutputFlagImageReencodeRejectsNonImageOutput(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("hello"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}
	outputPath := filepath.Join(t.TempDir(), "out.png")

	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"-i",
		inputPath,
		"-o",
		outputPath,
		"components/text/trim.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatalf("expected run to fail for non-image output to .png")
	}
	if !strings.Contains(stderr.String(), "cannot encode non-image output as image") {
		t.Fatalf("stderr=%q, want image conversion error", stderr.String())
	}
	if _, statErr := os.Stat(outputPath); !os.IsNotExist(statErr) {
		t.Fatalf("output file should not be created on error, statErr=%v", statErr)
	}
}

func compileWasmModuleForTest(t *testing.T, ctx context.Context, runtime wazero.Runtime, path string) wazero.CompiledModule {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read module %s: %v", path, err)
	}
	compiled, err := runtime.CompileModule(ctx, body)
	if err != nil {
		t.Fatalf("compile module %s: %v", path, err)
	}
	return compiled
}

func TestExecuteModuleReadsOutputPtrAfterRender(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	// trim returns a dynamic immutable slice of its input.
	wasmBytes, err := os.ReadFile("components/text/trim.wasm")
	if err != nil {
		t.Fatalf("read trim component: %v", err)
	}
	_ = []byte{
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0a, 0x02, 0x60,
		0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03, 0x06, 0x05, 0x00,
		0x00, 0x00, 0x00, 0x01, 0x05, 0x04, 0x01, 0x01, 0x01, 0x01, 0x06, 0x19,
		0x04, 0x7f, 0x00, 0x41, 0x80, 0x08, 0x0b, 0x7f, 0x00, 0x41, 0xc0, 0x00,
		0x0b, 0x7f, 0x00, 0x41, 0xc0, 0x00, 0x0b, 0x7f, 0x01, 0x41, 0x80, 0x18,
		0x0b, 0x07, 0x4f, 0x06, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02,
		0x00, 0x09, 0x69, 0x6e, 0x70, 0x75, 0x74, 0x5f, 0x70, 0x74, 0x72, 0x00,
		0x00, 0x0e, 0x69, 0x6e, 0x70, 0x75, 0x74, 0x5f, 0x75, 0x74, 0x66, 0x38,
		0x5f, 0x63, 0x61, 0x70, 0x00, 0x01, 0x0a, 0x6f, 0x75, 0x74, 0x70, 0x75,
		0x74, 0x5f, 0x70, 0x74, 0x72, 0x00, 0x02, 0x0f, 0x6f, 0x75, 0x74, 0x70,
		0x75, 0x74, 0x5f, 0x75, 0x74, 0x66, 0x38, 0x5f, 0x63, 0x61, 0x70, 0x00,
		0x03, 0x06, 0x72, 0x65, 0x6e, 0x64, 0x65, 0x72, 0x00, 0x04, 0x0a, 0x83,
		0x01, 0x05, 0x04, 0x00, 0x23, 0x00, 0x0b, 0x04, 0x00, 0x23, 0x01, 0x0b,
		0x04, 0x00, 0x23, 0x03, 0x0b, 0x04, 0x00, 0x23, 0x02, 0x0b, 0x6d, 0x00,
		0x20, 0x00, 0x41, 0x04, 0x46, 0x23, 0x00, 0x2d, 0x00, 0x00, 0x41, 0xf4,
		0x00, 0x46, 0x23, 0x00, 0x41, 0x01, 0x6a, 0x2d, 0x00, 0x00, 0x41, 0xf2,
		0x00, 0x46, 0x23, 0x00, 0x41, 0x02, 0x6a, 0x2d, 0x00, 0x00, 0x41, 0xe9,
		0x00, 0x46, 0x23, 0x00, 0x41, 0x03, 0x6a, 0x2d, 0x00, 0x00, 0x41, 0xed,
		0x00, 0x46, 0x71, 0x71, 0x71, 0x71, 0x04, 0x40, 0x23, 0x00, 0x24, 0x03,
		0x20, 0x00, 0x0f, 0x0b, 0x41, 0x80, 0x10, 0x24, 0x03, 0x41, 0x80, 0x10,
		0x41, 0xf4, 0x00, 0x3a, 0x00, 0x00, 0x41, 0x81, 0x10, 0x41, 0xf2, 0x00,
		0x3a, 0x00, 0x00, 0x41, 0x82, 0x10, 0x41, 0xe9, 0x00, 0x3a, 0x00, 0x00,
		0x41, 0x83, 0x10, 0x41, 0xed, 0x00, 0x3a, 0x00, 0x00, 0x41, 0x04, 0x0b,
		0x0b, 0x0c, 0x01, 0x00, 0x41, 0x80, 0x18, 0x0b, 0x05, 0x73, 0x74, 0x61,
		0x6c, 0x65,
	}

	compiled, err := runtime.CompileModule(ctx, wasmBytes)
	if err != nil {
		t.Fatalf("compile module: %v", err)
	}
	defer compiled.Close(ctx)

	for _, tc := range []struct {
		name  string
		input []byte
	}{
		{name: "already-trimmed input is returned from input_ptr", input: []byte("trim")},
		{name: "padded input is returned from scratch output buffer", input: []byte(" trim ")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			exec, err := executeModuleWithInput(
				ctx,
				runtime,
				compiled,
				tc.input,
				options{},
				"test-deferred-output-ptr",
				nil,
				"",
				false,
			)
			if err != nil {
				t.Fatalf("execute module: %v", err)
			}
			if got := string(exec.output.bytes); got != "trim" {
				t.Fatalf("output=%q, want %q", got, "trim")
			}
		})
	}
}

func TestContentTypeCheckingModesForRunModule(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "components/text/html/html-link-extractor.wasm")
	defer compiled.Close(ctx)

	input := []byte(`<a href="/x">X</a>`)
	moduleName := "test-html-link-extractor"

	_, err := executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		input,
		options{contentTypeChecking: ContentTypeCheckingStrong},
		moduleName,
		nil,
		"text/plain",
		false,
	)
	if err == nil {
		t.Fatal("expected strong content type mismatch error")
	}
	if !strings.Contains(err.Error(), "content type check failed") {
		t.Fatalf("unexpected error: %v", err)
	}

	_, err = executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		input,
		options{contentTypeChecking: ContentTypeCheckingNone},
		moduleName,
		nil,
		"text/plain",
		false,
	)
	if err != nil {
		t.Fatalf("none mode should skip content type mismatch: %v", err)
	}
}

func TestRunModuleAcceptsAndRejects(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "components/text/utf8-must-be-valid.wasm")
	defer compiled.Close(ctx)

	exec, err := executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		[]byte("hello"),
		options{},
		"test-utf8-validator-accept",
		nil,
		"",
		false,
	)
	if err != nil {
		t.Fatalf("accepted input failed: %v", err)
	}
	if got := string(exec.output.bytes); got != "hello" {
		t.Fatalf("output=%q, want %q", got, "hello")
	}

	_, err = executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		[]byte{'A', 0xc3, '('},
		options{},
		"test-utf8-validator-reject",
		nil,
		"",
		false,
	)
	if err == nil {
		t.Fatal("expected invalid UTF-8 rejection")
	}
	if !strings.Contains(err.Error(), "component rejected input at input offset 2") {
		t.Fatalf("unexpected rejection: %v", err)
	}
}

func TestRunModuleAcceptsInputlessGenerator(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "components/image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm")
	defer compiled.Close(ctx)

	exec, err := executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		nil,
		options{},
		"test-oklch-solid-color-generator",
		map[string]string{"width": "2", "height": "1", "lightness": "0.7", "chroma": "0.5", "hue_degrees": "30", "alpha": "0.25"},
		"",
		false,
	)
	if err != nil {
		t.Fatalf("inputless generator failed: %v", err)
	}
	if got, want := len(exec.output.bytes), 256; got != want {
		t.Fatalf("output bytes=%d, want %d", got, want)
	}

	_, err = executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		[]byte("x"),
		options{},
		"test-oklch-solid-color-generator-rejects-input",
		nil,
		"",
		false,
	)
	if err == nil || !strings.Contains(err.Error(), "inputless generator cannot receive 1 input bytes") {
		t.Fatalf("error=%v, want supplied input rejection", err)
	}
}

func TestTrustFirstStageContentTypePropagation(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "components/text/html/html-link-extractor.wasm")
	defer compiled.Close(ctx)

	exec, err := executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		[]byte(`<a href="/x">X</a>`),
		options{contentTypeChecking: ContentTypeCheckingStrong},
		"test-html-link",
		nil,
		"",
		true,
	)
	if err != nil {
		t.Fatalf("expected trusted first-stage input to pass: %v", err)
	}
	if exec.outputContentType != "text/html" {
		t.Fatalf("outputContentType=%q, want %q", exec.outputContentType, "text/html")
	}
}

func TestHelperRunModuleCLI(t *testing.T) {
	if os.Getenv("QIP_HELPER_RUN_MODULE_CLI") != "1" {
		t.Skip("helper process")
	}
	args := os.Args
	sep := -1
	for i := range args {
		if args[i] == "--" {
			sep = i
			break
		}
	}
	if sep == -1 || sep+1 >= len(args) {
		os.Exit(2)
	}
	run(args[sep+1:])
	os.Exit(0)
}

func TestParseRuntimeMode(t *testing.T) {
	t.Run("dev", func(t *testing.T) {
		got, err := parseRuntimeMode("dev")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != modeDev {
			t.Fatalf("mode=%q, want %q", got, modeDev)
		}
	})

	t.Run("prod uppercase", func(t *testing.T) {
		got, err := parseRuntimeMode("PROD")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != modeProd {
			t.Fatalf("mode=%q, want %q", got, modeProd)
		}
	})

	t.Run("invalid", func(t *testing.T) {
		if _, err := parseRuntimeMode("staging"); err == nil {
			t.Fatal("expected invalid mode error")
		}
	})
}

func TestScanRecipeModuleStampsDetectsChanges(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmA := filepath.Join(recipeDir, "10-a.wasm")
	if err := os.WriteFile(wasmA, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm a: %v", err)
	}

	first, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}

	time.Sleep(2 * time.Millisecond)
	if err := os.WriteFile(wasmA, []byte{0x00, 0x61, 0x73, 0x6d, 0x01}, 0o644); err != nil {
		t.Fatalf("rewrite wasm a: %v", err)
	}

	second, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}
	if recipeModuleStampsEqual(first, second) {
		t.Fatal("expected stamp maps to differ after mtime/size change")
	}

	wasmB := filepath.Join(recipeDir, "20-b.wasm")
	if err := os.WriteFile(wasmB, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm b: %v", err)
	}

	third, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}
	if recipeModuleStampsEqual(second, third) {
		t.Fatal("expected stamp maps to differ after adding new module")
	}
}

func TestScanRecipeModuleStampsSupportsSymlinkedRecipeComponents(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmPath := filepath.Join(external, "10-linked.wasm")
	if err := os.WriteFile(wasmPath, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}
	if err := os.Symlink(wasmPath, filepath.Join(recipeDir, "10-linked.wasm")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	stamps, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}
	if _, ok := stamps["text/markdown/10-linked.wasm"]; !ok {
		t.Fatalf("expected stamp for symlinked recipe module")
	}
}

func TestLoadRecipeChainsIgnoresNonWasm(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	// Non-wasm source files may live beside compiled recipes.
	if err := os.WriteFile(filepath.Join(recipeDir, "10-markdown-basic.zig"), []byte("const x = 1;"), 0o644); err != nil {
		t.Fatalf("write source: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("components", "utf8", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "10-markdown-basic.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}

	chains, digests, err := loadRecipeChains(context.Background(), root, options{})
	if err != nil {
		t.Fatalf("loadRecipeChains error: %v", err)
	}
	t.Cleanup(func() {
		closePipelines(context.Background(), chains)
	})

	chain, ok := chains["text/markdown"]
	if !ok || chain == nil {
		t.Fatalf("expected text/markdown chain")
	}
	if got := len(digests["text/markdown"]); got != 1 {
		t.Fatalf("digest count=%d, want 1", got)
	}
}

func TestLoadRecipeChainsSupportsSymlinkedRecipeComponents(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	if err := os.MkdirAll(filepath.Join(external, "text", "markdown"), 0o755); err != nil {
		t.Fatalf("mkdir external: %v", err)
	}
	wasmBytes, err := os.ReadFile(filepath.Join("components", "utf8", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(external, "text", "markdown", "10-linked.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write linked wasm: %v", err)
	}
	if err := os.Symlink(filepath.Join(external, "text"), filepath.Join(root, "text")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	chains, digests, err := loadRecipeChains(context.Background(), root, options{})
	if err != nil {
		t.Fatalf("loadRecipeChains error: %v", err)
	}
	t.Cleanup(func() {
		closePipelines(context.Background(), chains)
	})

	if _, ok := chains["text/markdown"]; !ok {
		t.Fatalf("expected text/markdown chain")
	}
	if got := len(digests["text/markdown"]); got != 1 {
		t.Fatalf("digest count=%d, want 1", got)
	}
}

func TestLoadRecipeChainsRejectsInvalidFilename(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("components", "utf8", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "a0-invalid.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}

	if _, _, err := loadRecipeChains(context.Background(), root, options{}); err == nil {
		t.Fatal("expected error for invalid recipe filename")
	}
}

func TestLoadRecipeChainsRejectsDuplicatePrefix(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("components", "utf8", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "42-a.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm a: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "42-b.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm b: %v", err)
	}

	if _, _, err := loadRecipeChains(context.Background(), root, options{}); err == nil {
		t.Fatal("expected error for duplicate recipe prefix")
	}
}

func TestParseImageComponentInvocations(t *testing.T) {
	t.Run("module with query", func(t *testing.T) {
		specs, err := parseComponentInvocations([]string{
			"components/rgba/color-halftone.wasm",
			"?max_radius=2.0",
			"components/rgba/brightness.wasm",
			"?brightness=0.2",
		}, "image")
		if err != nil {
			t.Fatalf("parseImageModuleSpecs error: %v", err)
		}
		if len(specs) != 2 {
			t.Fatalf("spec count=%d, want 2", len(specs))
		}
		if specs[0].Source != "components/rgba/color-halftone.wasm" {
			t.Fatalf("spec[0].Source=%q", specs[0].Source)
		}
		if got := specs[0].UniformValues["max_radius"]; got != "2.0" {
			t.Fatalf("spec[0] max_radius=%q, want 2.0", got)
		}
		if specs[1].Source != "components/rgba/brightness.wasm" {
			t.Fatalf("spec[1].Source=%q", specs[1].Source)
		}
		if got := specs[1].UniformValues["brightness"]; got != "0.2" {
			t.Fatalf("spec[1] brightness=%q, want 0.2", got)
		}
	})

	t.Run("query before module is error", func(t *testing.T) {
		if _, err := parseComponentInvocations([]string{"?max_radius=2.0"}, "image"); err == nil {
			t.Fatal("expected error for query before module")
		}
	})

	t.Run("empty query is error", func(t *testing.T) {
		if _, err := parseComponentInvocations([]string{"components/rgba/brightness.wasm", "?"}, "image"); err == nil {
			t.Fatal("expected error for empty query")
		}
	})
}

func TestLoadComponentAssets(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "nested"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("components", "utf8", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "contact.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write contact wasm: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "nested", "signup.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write nested wasm: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "README.txt"), []byte("ignore"), 0o644); err != nil {
		t.Fatalf("write non-wasm: %v", err)
	}

	assets, requestPaths, err := loadComponentAssets(root)
	if err != nil {
		t.Fatalf("loadComponentAssets error: %v", err)
	}
	if len(assets) != 2 {
		t.Fatalf("asset count=%d, want 2", len(assets))
	}
	if len(requestPaths) != 2 {
		t.Fatalf("request path count=%d, want 2", len(requestPaths))
	}
	if !bytes.Equal(assets["/contact.wasm"].body, wasmBytes) {
		t.Fatalf("direct contact component bytes mismatch")
	}
	if got := assets["/contact.wasm"].contentType; got != "application/wasm" {
		t.Fatalf("content type=%q, want application/wasm", got)
	}
	if !bytes.Equal(assets["/nested/signup.wasm"].body, wasmBytes) {
		t.Fatalf("direct nested/signup component bytes mismatch")
	}
}

func TestLoadComponentAssetsSupportsSymlinkedWasmAndIgnoresNonWasmSymlink(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	wasmBytes, err := os.ReadFile(filepath.Join("components", "utf8", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	externalWasm := filepath.Join(external, "contact.wasm")
	if err := os.WriteFile(externalWasm, wasmBytes, 0o644); err != nil {
		t.Fatalf("write external wasm: %v", err)
	}
	externalText := filepath.Join(external, "commonmark-spec-0.31.2.txt")
	if err := os.WriteFile(externalText, []byte("spec"), 0o644); err != nil {
		t.Fatalf("write external text: %v", err)
	}

	if err := os.Symlink(externalWasm, filepath.Join(root, "contact.wasm")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := os.Symlink(externalText, filepath.Join(root, "commonmark-spec-0.31.2.txt")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	assets, requestPaths, err := loadComponentAssets(root)
	if err != nil {
		t.Fatalf("loadComponentAssets error: %v", err)
	}
	if len(assets) != 1 {
		t.Fatalf("asset count=%d, want 1", len(assets))
	}
	if len(requestPaths) != 1 {
		t.Fatalf("request path count=%d, want 1", len(requestPaths))
	}
	if !bytes.Equal(assets["/contact.wasm"].body, wasmBytes) {
		t.Fatalf("direct contact component bytes mismatch")
	}
}
