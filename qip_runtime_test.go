package main

import "testing"

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
