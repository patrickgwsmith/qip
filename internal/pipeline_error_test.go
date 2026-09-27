package qinternal

import (
	"context"
	"errors"
	"testing"
)

type failingLabeledStage struct {
	label string
	err   error
}

func (s failingLabeledStage) Process(context.Context, Content, uint64) (Content, error) {
	return nil, s.err
}

func (s failingLabeledStage) Close(context.Context) error { return nil }
func (s failingLabeledStage) Label() string               { return s.label }

func TestPipelineErrorNamesRecipeStepAndComponent(t *testing.T) {
	pipeline := Pipeline{Stages: []Stage{
		passThroughLabeledStage{label: "first.wasm"},
		failingLabeledStage{label: "validate.wasm", err: errors.New("rejected invalid input at byte 7")},
	}}

	_, err := pipeline.Process(context.Background(), NewRawBytesContent([]byte("input")), 1)
	if err == nil {
		t.Fatal("expected pipeline error")
	}
	const want = "step 2 validate.wasm rejected invalid input at byte 7"
	if err.Error() != want {
		t.Fatalf("error=%q, want %q", err, want)
	}
}

type passThroughLabeledStage struct{ label string }

func (s passThroughLabeledStage) Process(_ context.Context, input Content, _ uint64) (Content, error) {
	return input, nil
}

func (s passThroughLabeledStage) Close(context.Context) error { return nil }
func (s passThroughLabeledStage) Label() string               { return s.label }
