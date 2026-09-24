package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func TestGoHostDecisionsMatchSharedInteractiveTrace(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	var trace strings.Builder
	formatWake := func(wake, begunAt int64) string {
		if wake == begunAt {
			return "none"
		}
		return fmt.Sprint(wake)
	}
	instantiate := func(name string) api.Module {
		compiled := compileWasmModuleForTest(t, ctx, runtime, "gui/"+name+".wasm")
		t.Cleanup(func() { compiled.Close(ctx) })
		mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("trace-"+name))
		if err != nil {
			t.Fatalf("instantiate %s: %v", name, err)
		}
		t.Cleanup(func() { mod.Close(ctx) })
		return mod
	}
	callOne := func(fn api.Function, args ...uint64) uint64 {
		results, err := fn.Call(ctx, args...)
		if err != nil {
			t.Fatalf("call %s: %v", fn.Definition().Name(), err)
		}
		if len(results) != 1 {
			t.Fatalf("call %s returned %d values, want 1", fn.Definition().Name(), len(results))
		}
		return results[0]
	}
	callBegin := func(fn api.Function, nowMS int64) {
		fmt.Fprintf(&trace, "call begin_update_at now_ms=%d\n", nowMS)
		results, err := fn.Call(ctx, uint64(nowMS))
		if err != nil {
			t.Fatalf("call begin_update_at: %v", err)
		}
		if len(results) != 0 {
			t.Fatalf("begin_update_at returned %d values, want 0", len(results))
		}
		trace.WriteString("return ok\n")
	}
	callFinish := func(fn api.Function) int64 {
		trace.WriteString("call finish_update\n")
		result := int64(callOne(fn))
		fmt.Fprintf(&trace, "return next_wake_at_ms=%d\n", result)
		return result
	}
	callRender := func(fn api.Function) uint64 {
		trace.WriteString("call render input_size=0\n")
		result := callOne(fn, 0) & 0xffff_ffff
		fmt.Fprintf(&trace, "return output_bytes=%d\n", result)
		return result
	}
	callKey := func(fn api.Function, keysym, flags int32) bool {
		fmt.Fprintf(&trace, "call key_event keysym=%d flags=%d\n", keysym, flags)
		accepted := callOne(fn, uint64(uint32(keysym)), uint64(uint32(flags))) != 0
		fmt.Fprintf(&trace, "return accepted=%d\n", map[bool]int{false: 0, true: 1}[accepted])
		return accepted
	}
	callPointer := func(fn api.Function, buttons, x, y int32) bool {
		fmt.Fprintf(&trace, "call pointer_event buttons=%d x=%d y=%d\n", buttons, x, y)
		accepted := callOne(fn, uint64(uint32(buttons)), uint64(uint32(x)), uint64(uint32(y))) != 0
		fmt.Fprintf(&trace, "return accepted=%d\n", map[bool]int{false: 0, true: 1}[accepted])
		return accepted
	}
	writeDecision := func(events int, accepted bool, wake, begunAt int64, render bool) {
		fmt.Fprintf(&trace, "host update events=%d accepted=%s wake=%s render=%s\n",
			events,
			map[bool]string{false: "no", true: "yes"}[accepted],
			formatWake(wake, begunAt),
			map[bool]string{false: "no", true: "yes"}[render],
		)
	}

	trace.WriteString("calculator\n")
	calculator := instantiate("calculator")
	calculatorRender := requiredExportedFunction(t, calculator, "render")
	calculatorBegin := requiredExportedFunction(t, calculator, "begin_update_at")
	calculatorFinish := requiredExportedFunction(t, calculator, "finish_update")
	calculatorKey := requiredExportedFunction(t, calculator, "key_event")
	calculatorPointer := requiredExportedFunction(t, calculator, "pointer_event")
	outputBytes := callRender(calculatorRender)
	fmt.Fprintf(&trace, "host initial present output_bytes=%d\n", outputBytes)
	callBegin(calculatorBegin, 1)
	wake := callFinish(calculatorFinish)
	fmt.Fprintf(&trace, "host bootstrap wake=%s\n", formatWake(wake, 1))
	callBegin(calculatorBegin, 2)
	accepted := callPointer(calculatorPointer, 0, -1, -1)
	wake = callFinish(calculatorFinish)
	writeDecision(1, accepted, wake, 2, accepted)
	callBegin(calculatorBegin, 3)
	accepted = callPointer(calculatorPointer, 0, -1, -1)
	accepted = callKey(calculatorKey, '1', 1) || accepted
	wake = callFinish(calculatorFinish)
	if accepted {
		callRender(calculatorRender)
	}
	writeDecision(2, accepted, wake, 3, accepted)

	trace.WriteString("snake\n")
	snake := instantiate("snake")
	snakeRender := requiredExportedFunction(t, snake, "render")
	snakeBegin := requiredExportedFunction(t, snake, "begin_update_at")
	snakeFinish := requiredExportedFunction(t, snake, "finish_update")
	snakeKey := requiredExportedFunction(t, snake, "key_event")
	outputBytes = callRender(snakeRender)
	fmt.Fprintf(&trace, "host initial present output_bytes=%d\n", outputBytes)
	callBegin(snakeBegin, 1)
	wake = callFinish(snakeFinish)
	fmt.Fprintf(&trace, "host bootstrap wake=%s\n", formatWake(wake, 1))
	callBegin(snakeBegin, 120)
	accepted = callKey(snakeKey, 0xff52, 1)
	wake = callFinish(snakeFinish)
	callRender(snakeRender) // The scheduled wake requests presentation.
	writeDecision(1, accepted, wake, 120, true)
	callBegin(snakeBegin, 121)
	accepted = callKey(snakeKey, 0x20, 1)
	wake = callFinish(snakeFinish)
	if accepted {
		callRender(snakeRender)
	}
	writeDecision(1, accepted, wake, 121, accepted)

	want, err := os.ReadFile("testdata/interactive-host-decisions.txt")
	if err != nil {
		t.Fatalf("read shared Interactive trace: %v", err)
	}
	if got := trace.String(); got != string(want) {
		t.Fatalf("Go host decisions differ from shared Interactive trace\n--- got ---\n%s--- want ---\n%s", got, want)
	}
}
