package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
)

func TestHostedDryRunPlansMissingSourcesWithoutNetworkOrWrites(t *testing.T) {
	missing := "testdata/host-dry-run-missing/component.wasm"
	config := runCommandConfig{
		opts: options{hosts: []qinternal.ComponentHost{
			{Authority: "qip.dev", Origin: "https://qip.dev"},
			{Authority: "mirror.example:8443", Origin: "https://mirror.example:8443"},
		}},
		timeoutMS: 5000,
		formValues: formAssignmentList{
			"component=@testdata/host-dry-run-missing/target.wasm",
			"input=hello",
		},
		componentInvocations: []ComponentInvocation{{
			Source: missing,
		}},
	}
	var output bytes.Buffer
	if err := executeDryRun(context.Background(), config, &output); err != nil {
		t.Fatal(err)
	}
	got := output.String()
	for _, want := range []string{
		"https://qip.dev/testdata/host-dry-run-missing/component.wasm",
		"https://mirror.example:8443/testdata/host-dry-run-missing/component.wasm",
		"Multipart files:",
		`Field "component": testdata/host-dry-run-missing/target.wasm`,
		"https://qip.dev/testdata/host-dry-run-missing/target.wasm  unexamined",
		"testdata/host-dry-run-missing/target.wasm  missing",
		"0  missing",
		"1  unexamined",
		"deferred (local file missing)",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("output missing %q:\n%s", want, got)
		}
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("dry run wrote component: %v", err)
	}
	if _, err := os.Stat("testdata/host-dry-run-missing/target.wasm"); !os.IsNotExist(err) {
		t.Fatalf("dry run wrote multipart file: %v", err)
	}
}

func TestHostedDryRunObservesMultipartPathWithoutReadingContents(t *testing.T) {
	target := filepath.Join(t.TempDir(), "target.wasm")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	config := runCommandConfig{
		opts:       options{hosts: []qinternal.ComponentHost{{Authority: "qip.dev", Origin: "https://qip.dev"}}},
		timeoutMS:  5000,
		formValues: formAssignmentList{"component=@" + target},
		componentInvocations: []ComponentInvocation{{
			Source: "text/trim.wasm",
		}},
	}
	var output bytes.Buffer
	if err := executeDryRun(context.Background(), config, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), target+"  present (contents not read)") {
		t.Fatalf("unexpected dry-run report:\n%s", output.String())
	}
}

func TestExecuteDryRunDoesNotCallRender(t *testing.T) {
	config, err := parseRunCommandArgs([]string{
		"--timeout-ms", "250",
		"text/infinite-loop.wasm",
	}, "dry run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs: %v", err)
	}

	var output bytes.Buffer
	if err := executeDryRun(context.Background(), config, &output); err != nil {
		t.Fatalf("executeDryRun: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Pipeline compatible: 1 step(s)") ||
		!strings.Contains(got, "text/infinite-loop.wasm — Content") ||
		!strings.Contains(got, "Total declared buffer capacity:") {
		t.Fatalf("unexpected dry-run report:\n%s", got)
	}
}

func TestDryRunTreatsInteractiveInitializationAsContent(t *testing.T) {
	config, err := parseRunCommandArgs([]string{
		"components/interactive/tile-world-12x12.wasm",
	}, "dry run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs: %v", err)
	}

	var output bytes.Buffer
	if err := executeDryRun(context.Background(), config, &output); err != nil {
		t.Fatalf("executeDryRun: %v", err)
	}
	got := output.String()
	for _, expected := range []string{
		"components/interactive/tile-world-12x12.wasm — Content",
		"Input:  encoding=raw bytes, type=unspecified, capacity=none",
		"Output: encoding=raw bytes, type=image/ktx2",
	} {
		if !strings.Contains(got, expected) {
			t.Fatalf("dry-run report missing %q:\n%s", expected, got)
		}
	}
}

func TestValidateDeclaredContentTypeRequiresCanonicalMIME(t *testing.T) {
	if got, err := validateDeclaredContentType("text/html"); err != nil || got != "text/html" {
		t.Fatalf("canonical MIME result=%q error=%v", got, err)
	}
	multipart := "multipart/form-data;boundary=uuid-12345678-90ab-cdef-1234-567890abcdef"
	if got, err := validateDeclaredContentType(multipart); err != nil || got != multipart {
		t.Fatalf("canonical multipart result=%q error=%v", got, err)
	}
	if got := normalizeIncomingContentType(multipart); got != multipart {
		t.Fatalf("normalized multipart=%q, want %q", got, multipart)
	}
	for _, value := range []string{
		"Text/HTML", " text/html", "text/html ", "text/html; charset=utf-8",
		"multipart/form-data; boundary=uuid-12345678-90ab-cdef-1234-567890abcdef",
		"multipart/form-data;boundary=qip-12345678-90ab-cdef-1234-567890abcdef",
		"multipart/form-data;boundary=uuid-12345678-90AB-cdef-1234-567890abcdef",
		"multipart/form-data;boundary=uuid-12345678-90ab-cdef-1234-567890abcde",
	} {
		if _, err := validateDeclaredContentType(value); err == nil {
			t.Fatalf("validateDeclaredContentType(%q) succeeded, want canonical-form error", value)
		}
	}
}

func TestDryRunHelpIncludesReportAndMemoryScope(t *testing.T) {
	for _, required := range []string{
		"Pipeline compatible: 2 step(s)",
		"Input:  encoding=UTF-8, type=text/markdown",
		"Total declared buffer capacity:",
		"checked independently against every component",
		"not a cap on the pipeline total",
		"--capacities-must-fit",
		"producer's maximum output capacity exceeds the consumer's input",
	} {
		if !strings.Contains(helpDryRun, required) {
			t.Fatalf("dry-run help missing %q", required)
		}
	}
}

func TestCapacitiesMustFitFlagRejectsRunAndDryRunPlans(t *testing.T) {
	for _, commandName := range []string{"run", "dry run"} {
		t.Run(commandName, func(t *testing.T) {
			config, err := parseRunCommandArgs([]string{
				"--capacities-must-fit",
				"text/markdown/commonmark.0.31.2.wasm",
				"text/html/html-page-wrap.wasm",
			}, commandName)
			if err != nil {
				t.Fatalf("parseRunCommandArgs: %v", err)
			}
			if !config.opts.capacitiesMustFit {
				t.Fatal("capacitiesMustFit=false, want true")
			}
			prepared, err := prepareRunPipelineFromInvocations(context.Background(), config.componentInvocations, config.opts)
			if err == nil {
				prepared.pipeline.Close(context.Background())
				t.Fatal("capacity-incompatible pipeline succeeded")
			}
			for _, required := range []string{
				"capacities must fit",
				"commonmark.0.31.2.wasm) output capacity is 2.0 MiB (2097152 bytes)",
				"html-page-wrap.wasm) input capacity is 256.0 KiB (262144 bytes)",
			} {
				if !strings.Contains(err.Error(), required) {
					t.Fatalf("error=%q, want %q", err, required)
				}
			}
		})
	}
}

func TestDryRunMaxMemoryIsPerComponent(t *testing.T) {
	const componentMemory = "262144"
	args := []string{
		"--max-memory", componentMemory,
		"bytes/base64-encode.wasm",
		"bytes/base64-encode.wasm",
	}
	config, err := parseRunCommandArgs(args, "dry run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs: %v", err)
	}
	var output bytes.Buffer
	if err := executeDryRun(context.Background(), config, &output); err != nil {
		t.Fatalf("per-component cap rejected compatible pipeline: %v", err)
	}
	if !strings.Contains(output.String(), "Total declared buffer capacity: 298.7 KiB (305840 bytes)") {
		t.Fatalf("report does not show total exceeding per-component cap:\n%s", output.String())
	}

	config, err = parseRunCommandArgs([]string{
		"--max-memory", "262143",
		"bytes/base64-encode.wasm",
	}, "dry run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs below cap: %v", err)
	}
	if err := executeDryRun(context.Background(), config, &bytes.Buffer{}); err == nil ||
		!strings.Contains(err.Error(), "exceeds --max-memory 262143 bytes") {
		t.Fatalf("error=%v, want per-component max-memory rejection", err)
	}
}

func TestDocumentedRunPipelinesRemainCompatible(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{"zlib to base64", []string{"bytes/zlib-compress-dynamic-huffman.wasm", "bytes/base64-encode.wasm"}},
		{"zlib round trip", []string{"bytes/zlib-compress-dynamic-huffman.wasm", "bytes/zlib-decompress.wasm"}},
		{"SVG to doubled ICO", []string{"image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm", "image/bmp/bmp-double.wasm", "image/bmp/bmp-to-ico.wasm"}},
		{"SVG directly to ICO", []string{"image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm", "image/bmp/bmp-to-ico.wasm"}},
		{"PNG to ICO", []string{"image/png/png-to-bmp-b8g8r8a8-srgb.wasm", "image/bmp/bmp-to-ico.wasm"}},
		{"strict Wasm checks", []string{"application/wasm/wasm-strict-profile.wasm", "application/wasm/wasm-bounded-loops.wasm"}},
		{"Markdown highlighting", []string{"text/markdown/commonmark.0.31.2.wasm", "text/html/html-code-syntax-highlight-tsx.wasm"}},
		{"HTML highlighter chain", []string{"text/html/html-code-syntax-highlight-zig.wasm", "text/html/html-code-syntax-highlight-css.wasm", "text/html/html-code-syntax-highlight-bash.wasm", "text/html/html-add-highlight-stylesheet-night-owl.wasm"}},
		{"SVG data URI to CSS", []string{"image/svg+xml/svg-to-data-uri.wasm", "text/uri-list/data-uri-to-css-url.wasm"}},
		{"Content Tile Content", []string{"image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm", "components/rgba/brightness.wasm", "?brightness=0.1", "image/bmp/bmp-to-ico.wasm"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			config, err := parseRunCommandArgs(tc.args, "dry run")
			if err != nil {
				t.Fatalf("parseRunCommandArgs: %v", err)
			}
			if err := executeDryRun(context.Background(), config, &bytes.Buffer{}); err != nil {
				t.Fatalf("documented pipeline is incompatible: %v", err)
			}
		})
	}
}

func TestPreparedContentTileContentPipelineExecutes(t *testing.T) {
	config, err := parseRunCommandArgs([]string{
		"image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm",
		"components/rgba/brightness.wasm",
		"?brightness=0.1",
		"image/bmp/bmp-to-ico.wasm",
	}, "run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs: %v", err)
	}
	input, err := os.ReadFile("qip-logo.svg")
	if err != nil {
		t.Fatalf("read qip-logo.svg: %v", err)
	}

	execCtx, cancel := wasmruntime.WithExecutionTimeout(context.Background(), 5*time.Second)
	defer cancel()
	prepared, err := prepareRunPipelineFromInvocations(execCtx, config.componentInvocations, config.opts)
	if err != nil {
		t.Fatalf("prepareRunPipelineFromInvocations: %v", err)
	}
	defer prepared.pipeline.Close(context.Background())

	result, err := prepared.pipeline.Process(execCtx, qinternal.NewRawBytesContentWithType(input, ""), 0)
	if err != nil {
		t.Fatalf("pipeline.Process: %v", err)
	}
	output, err := qinternal.AsRawBytes(result)
	if err != nil {
		t.Fatalf("AsRawBytes: %v", err)
	}
	if got := qinternal.ContentTypeOf(result); got != "image/x-icon" {
		t.Fatalf("output content type=%q, want image/x-icon", got)
	}
	if len(output) < 4 || !bytes.Equal(output[:4], []byte{0, 0, 1, 0}) {
		t.Fatalf("output does not start with ICO signature: %x", output[:min(len(output), 4)])
	}
}

func TestPlanRunPipelineContentTypesAndBufferCapacity(t *testing.T) {
	descriptions := []pipelineComponentDescription{
		{
			source: "markdown.wasm",
			kind:   pipelineComponentContent,
			content: pipelineContentDescription{
				inputCapBytes:                1024,
				inputEncoding:                dataEncodingUTF8,
				hasOutput:                    true,
				outputCapBytes:               2048,
				outputEncoding:               dataEncodingUTF8,
				declaredInputContentType:     "text/markdown",
				hasDeclaredInputContentType:  true,
				declaredOutputContentType:    "text/html",
				hasDeclaredOutputContentType: true,
			},
		},
		{
			source: "page.wasm",
			kind:   pipelineComponentContent,
			content: pipelineContentDescription{
				inputCapBytes:               4096,
				inputEncoding:               dataEncodingUTF8,
				hasOutput:                   true,
				outputCapBytes:              8192,
				outputEncoding:              dataEncodingUTF8,
				declaredInputContentType:    "text/html",
				hasDeclaredInputContentType: true,
			},
		},
	}

	plan, err := planRunPipeline(descriptions)
	if err != nil {
		t.Fatalf("planRunPipeline: %v", err)
	}
	if len(plan.steps) != 2 {
		t.Fatalf("steps=%d, want 2", len(plan.steps))
	}
	if got := plan.steps[0].inputType; got != "text/markdown" {
		t.Fatalf("first input type=%q, want text/markdown", got)
	}
	if got := plan.steps[0].outputType; got != "text/html" {
		t.Fatalf("first output type=%q, want text/html", got)
	}
	if got := plan.steps[1].inputType; got != "text/html" {
		t.Fatalf("second input type=%q, want text/html", got)
	}
	if got := plan.steps[1].outputType; got != "text/html" {
		t.Fatalf("second output type=%q, want inherited text/html", got)
	}
	const wantTotal = 1024 + 2048 + 4096 + 8192
	if plan.totalBufferBytes != wantTotal {
		t.Fatalf("totalBufferBytes=%d, want %d", plan.totalBufferBytes, wantTotal)
	}
	secondPlan, err := planRunPipeline(descriptions)
	if err != nil {
		t.Fatalf("second planRunPipeline: %v", err)
	}
	if !reflect.DeepEqual(plan, secondPlan) {
		t.Fatalf("same descriptions produced different plans:\nfirst: %#v\nsecond: %#v", plan, secondPlan)
	}
}

func TestPlanRunPipelineRejectsContentTypeMismatch(t *testing.T) {
	descriptions := []pipelineComponentDescription{
		{
			source: "json.wasm",
			kind:   pipelineComponentContent,
			content: pipelineContentDescription{
				inputCapBytes:                64,
				inputEncoding:                dataEncodingUTF8,
				hasOutput:                    true,
				outputCapBytes:               64,
				outputEncoding:               dataEncodingUTF8,
				declaredOutputContentType:    "application/json",
				hasDeclaredOutputContentType: true,
			},
		},
		{
			source: "html.wasm",
			kind:   pipelineComponentContent,
			content: pipelineContentDescription{
				inputCapBytes:               64,
				inputEncoding:               dataEncodingUTF8,
				hasOutput:                   true,
				outputCapBytes:              64,
				outputEncoding:              dataEncodingUTF8,
				declaredInputContentType:    "text/html",
				hasDeclaredInputContentType: true,
			},
		},
	}

	_, err := planRunPipeline(descriptions)
	want := `step 2 (html.wasm): content type mismatch: step 1 (json.wasm) output is "application/json", but step 2 (html.wasm) input is "text/html"`
	if err == nil || err.Error() != want {
		t.Fatalf("error=%q, want %q", err, want)
	}
}

func TestPlanRunPipelineEncodingSubtyping(t *testing.T) {
	content := func(source string, input, output dataEncoding) pipelineComponentDescription {
		return pipelineComponentDescription{
			source: source,
			kind:   pipelineComponentContent,
			content: pipelineContentDescription{
				inputCapBytes:  64,
				inputEncoding:  input,
				hasOutput:      true,
				outputCapBytes: 64,
				outputEncoding: output,
			},
		}
	}

	t.Run("UTF-8 safely widens to bytes", func(t *testing.T) {
		_, err := planRunPipeline([]pipelineComponentDescription{
			content("text.wasm", dataEncodingUTF8, dataEncodingUTF8),
			content("hash.wasm", dataEncodingRaw, dataEncodingRaw),
		})
		if err != nil {
			t.Fatalf("planRunPipeline: %v", err)
		}
	})

	t.Run("bytes do not implicitly narrow to UTF-8", func(t *testing.T) {
		_, err := planRunPipeline([]pipelineComponentDescription{
			content("bytes.wasm", dataEncodingRaw, dataEncodingRaw),
			content("text.wasm", dataEncodingUTF8, dataEncodingUTF8),
		})
		if err == nil || !strings.Contains(err.Error(), "input encoding mismatch") {
			t.Fatalf("error=%v, want encoding mismatch", err)
		}
	})
}

func TestPlanRunPipelineCountsTileBufferOnce(t *testing.T) {
	descriptions := []pipelineComponentDescription{{
		source:       "blur.wasm",
		kind:         pipelineComponentTile,
		tileInputCap: 80 * 80 * 4 * 4,
		tileHaloPx:   8,
	}}

	plan, err := planRunPipeline(descriptions)
	if err != nil {
		t.Fatalf("planRunPipeline: %v", err)
	}
	if got, want := plan.totalBufferBytes, uint64(80*80*4*4); got != want {
		t.Fatalf("totalBufferBytes=%d, want in-place capacity %d", got, want)
	}
	if plan.steps[0].inputCapBytes != plan.steps[0].outputCapBytes {
		t.Fatalf("tile input/output capacities differ: %#v", plan.steps[0])
	}
}

func TestPlanRunPipelineRejectsUndersizedHaloBuffer(t *testing.T) {
	descriptions := []pipelineComponentDescription{{
		source:       "blur.wasm",
		kind:         pipelineComponentTile,
		tileInputCap: 64 * 64 * 4 * 4,
		tileHaloPx:   8,
	}}

	_, err := planRunPipeline(descriptions)
	if err == nil || !strings.Contains(err.Error(), "80x80 RGBA32Float tile buffer") {
		t.Fatalf("error=%v, want undersized halo buffer", err)
	}
}
