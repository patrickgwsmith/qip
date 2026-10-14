package main

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func TestResolveComponentInvocationsOwnsUniformValues(t *testing.T) {
	invocations := []ComponentInvocation{{
		Source:        "text/hello.wasm",
		UniformValues: map[string]string{"answer": "41"},
	}}

	components, err := resolveComponentInvocations(invocations)
	if err != nil {
		t.Fatalf("resolveComponentInvocations: %v", err)
	}
	invocations[0].UniformValues["answer"] = "42"

	if got := components[0].UniformValues["answer"]; got != "41" {
		t.Fatalf("resolved uniform value=%q, want captured value 41", got)
	}
	if len(components[0].WASM) == 0 {
		t.Fatal("resolved component has no Wasm bytes")
	}
}

func TestApplyModuleUniformsMatchesSetterByKeyBeforeSuffix(t *testing.T) {
	ctx := context.Background()
	r := wasmruntime.NewRunToCompletion(ctx)
	defer r.Close(ctx)
	instantiate := func(path string) api.Module {
		t.Helper()
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		mod, err := r.InstantiateWithConfig(ctx, body, wazero.NewModuleConfig().WithName(path))
		if err != nil {
			t.Fatal(err)
		}
		return mod
	}

	mod := instantiate("test/fixtures/uniform-setter-suffix.wasm")
	if err := applyModuleUniforms(ctx, mod, map[string]string{"quality": "80"}); err != nil {
		t.Fatalf("applyModuleUniforms: %v", err)
	}
	if _, err := mod.ExportedFunction("render").Call(ctx, 0); err != nil {
		t.Fatalf("render: %v", err)
	}
	if got, _ := mod.Memory().ReadUint32Le(0); got != 80 {
		t.Fatalf("quality=%d, want 80", got)
	}

	duplicate := instantiate("test/fixtures/uniform-setter-duplicate.wasm")
	err := applyModuleUniforms(ctx, duplicate, nil)
	if err == nil || !strings.Contains(err.Error(), "exports both uniform_set_quality and uniform_set_quality__0x64") {
		t.Fatalf("duplicate setters error=%v", err)
	}
}
