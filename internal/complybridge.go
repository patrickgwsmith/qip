// Content Compliance bridge: the host side of the qip.* import ABI for
// Compliance oracles that own their memory and declare cases by ordinal.
//
// Bridge ABI (module "qip"; every call carries the component's u64 case
// ordinal so both sides continuously verify they agree on which case this is):
//
//	must_render_exactly(ordinal, in_ptr, in_len, expected_ptr, expected_len) -> i32
//	must_trap(ordinal, in_ptr, in_len) -> i32
//	must_reject(ordinal, in_ptr, in_len) -> i32
//	must_render_into(ordinal, in_ptr, in_len, out_ptr, out_cap) -> i32
//	must_render_into_emit_error(ordinal, message_ptr, message_len) -> i32
//	must_render_into_finish(ordinal, error_count) -> i32
//	set_uniform_u32(name_ptr, name_len, value) -> i32
//
// The component exports comply() -> i32 (declared-case count) and optionally
// uniform_set_seed(i32). The host owns all data movement (memcpy between the
// component's and the implementation's memories), comparison, and reporting;
// there are no failure_* exports and no case names on the wire — a failing
// case is identified as (component, seed, ordinal).
package qinternal

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const (
	bridgeHostModuleName  = "qip"
	bridgeExportComply    = "comply"
	bridgeUniformSeed     = "seed"
	bridgeMaxFailureNotes = 5
)

func validUniformKey(key string) bool {
	if key == "" || len(key) > 63 || key[0] < 'a' || key[0] > 'z' || strings.HasSuffix(key, "_") || strings.Contains(key, "__") {
		return false
	}
	for _, r := range key {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' {
			continue
		}
		return false
	}
	return true
}

type bridgeFailure struct {
	ordinal  uint64
	kind     string
	input    []byte
	expected []byte
	actual   []byte
}

type bridgeState struct {
	runtime                wazero.Runtime
	implWasm               []byte
	implMod                api.Module
	implSetters            map[string]string
	renderFn               api.Function
	hasFailure             bool
	implInPtr              uint32
	implInCap              uint32
	next                   uint64
	openRenderInto         *uint64
	openRenderIntoFailed   bool
	openRenderIntoErrCount uint32
	failures               []bridgeFailure
	failCount              int
	protocolErr            error
}

func (s *bridgeState) instantiateImplementation(ctx context.Context) error {
	if s.implMod != nil {
		_ = s.implMod.Close(ctx)
		s.implMod = nil
	}
	implMod, err := s.runtime.Instantiate(ctx, s.implWasm)
	if err != nil {
		return errors.New("implementation module could not be instantiated")
	}
	s.implMod = implMod
	s.implSetters, err = UniformSetterExports(implMod.ExportedFunctionDefinitions())
	if err != nil {
		return fmt.Errorf("implementation %w", err)
	}
	s.renderFn = implMod.ExportedFunction(complyExportRun)
	if s.renderFn == nil {
		return errors.New("bridge compliance requires implementation export render(i32) -> i64")
	}
	s.hasFailure = implMod.ExportedFunction("failure_modes_per_input_offset") != nil
	inPtr, ok, err := getExportedI32(ctx, implMod, complyExportInputPtr)
	if err != nil || !ok {
		return errors.New("implementation input_ptr unavailable")
	}
	s.implInPtr = uint32(inPtr)
	inCap, ok, err := getExportedI32(ctx, implMod, complyExportInputUTF8Cap)
	if err != nil || !ok {
		inCap, ok, err = getExportedI32(ctx, implMod, complyExportInputBytesCap)
		if err != nil || !ok {
			return errors.New("implementation input cap unavailable")
		}
	}
	s.implInCap = uint32(inCap)
	return nil
}

func (s *bridgeState) protocolViolation(format string, args ...any) {
	if s.protocolErr == nil {
		s.protocolErr = fmt.Errorf(format, args...)
	}
}

func (s *bridgeState) recordFailure(f bridgeFailure) {
	s.failCount++
	s.recordFailureNote(f)
}

func (s *bridgeState) recordFailureNote(f bridgeFailure) {
	if len(s.failures) < bridgeMaxFailureNotes {
		s.failures = append(s.failures, f)
	}
}

type bridgeRender struct {
	output        []byte
	rejected      bool
	failureDetail uint32
	renderTrap    error
}

// renderImpl runs one render. Rejection and traps stay distinct so an oracle
// must state which behavior it expects.
func (s *bridgeState) renderImpl(ctx context.Context, input []byte) (bridgeRender, error) {
	if uint32(len(input)) > s.implInCap {
		return bridgeRender{}, fmt.Errorf("input length %d exceeds implementation input cap %d", len(input), s.implInCap)
	}
	if !s.implMod.Memory().Write(s.implInPtr, input) {
		return bridgeRender{}, errors.New("implementation input buffer out of range")
	}
	res, err := s.renderFn.Call(ctx, uint64(uint32(len(input))))
	if err != nil {
		trapErr := err
		if resetErr := s.instantiateImplementation(ctx); resetErr != nil {
			return bridgeRender{}, fmt.Errorf("reinstantiate implementation after trap: %w", resetErr)
		}
		return bridgeRender{renderTrap: trapErr}, nil
	}
	renderResult := res[0]
	if renderResult&(uint64(1)<<63) != 0 {
		if !s.hasFailure {
			return bridgeRender{}, errors.New("implementation returned failure without failure_modes_per_input_offset")
		}
		return bridgeRender{rejected: true, failureDetail: uint32(renderResult)}, nil
	}
	outLen := uint32(renderResult)
	outPtr := uint32((renderResult >> 32) & 0x7fff_ffff)
	out, ok := s.implMod.Memory().Read(uint32(outPtr), outLen)
	if !ok {
		return bridgeRender{}, errors.New("implementation output out of range")
	}
	return bridgeRender{output: out}, nil
}

// The named return matters: out.duration is assigned in a defer, which only
// reaches the caller's copy through the named result.
func runBridgeComplianceModule(implWasm []byte, compliance complianceSpec, seed *int32) (out complianceOutcomes) {
	out = complianceOutcomes{index: compliance.index, path: compliance.path}
	start := time.Now()
	defer func() { out.duration = time.Since(start) }()

	ctx := context.Background()
	r := wasmruntime.NewRunToCompletion(ctx)
	defer r.Close(ctx)

	state := &bridgeState{runtime: r, implWasm: implWasm}
	if err := state.instantiateImplementation(ctx); err != nil {
		out.err = err
		return out
	}
	defer func() { _ = state.implMod.Close(ctx) }()

	readOracle := func(m api.Module, ptr, length uint32) ([]byte, bool) {
		return m.Memory().Read(ptr, length)
	}
	caseOpen := func(ordinal uint64, kind string) bool {
		if state.openRenderInto != nil {
			state.protocolViolation("%s at ordinal %d inside open must_render_into case %d", kind, ordinal, *state.openRenderInto)
			return false
		}
		if ordinal != state.next {
			state.protocolViolation("%s declared ordinal %d, host expected %d", kind, ordinal, state.next)
			return false
		}
		return true
	}
	setUniformU32 := func(callCtx context.Context, m api.Module, namePtr, nameLen, value uint32) uint32 {
		if state.openRenderInto != nil {
			state.protocolViolation("set_uniform_u32 called inside open must_render_into case %d", *state.openRenderInto)
			return 0
		}
		if nameLen == 0 || nameLen > 128 {
			state.protocolViolation("set_uniform_u32 name length %d is outside 1..128", nameLen)
			return 0
		}
		nameBytes, ok := readOracle(m, namePtr, nameLen)
		if !ok {
			state.protocolViolation("set_uniform_u32 name pointer out of range")
			return 0
		}
		name := string(nameBytes)
		if !validUniformKey(name) {
			state.protocolViolation("set_uniform_u32 name %q is not a valid uniform key", name)
			return 0
		}

		exportName, ok := state.implSetters[name]
		if !ok {
			state.protocolViolation("implementation does not export uniform_set_%s", name)
			return 0
		}
		setter := state.implMod.ExportedFunction(exportName)
		if err := requireSignature(setter.Definition(), []api.ValueType{api.ValueTypeI32}, []api.ValueType{api.ValueTypeI32}, exportName); err != nil {
			state.protocolViolation("%v", err)
			return 0
		}
		result, err := setter.Call(callCtx, uint64(value))
		if err != nil {
			state.protocolViolation("%s trapped: %v", exportName, err)
			return 0
		}
		return api.DecodeU32(result[0])
	}

	_, err := r.NewHostModuleBuilder(bridgeHostModuleName).
		NewFunctionBuilder().
		WithFunc(setUniformU32).
		Export("set_uniform_u32").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen, expPtr, expLen uint32) int32 {
			if !caseOpen(ordinal, "must_render_exactly") {
				return 0
			}
			state.next++
			input, ok1 := readOracle(m, inPtr, inLen)
			expected, ok2 := readOracle(m, expPtr, expLen)
			if !ok1 || !ok2 {
				state.protocolViolation("must_render_exactly pointers out of range at ordinal %d", ordinal)
				return 0
			}
			actual, err := state.renderImpl(callCtx, input)
			if err != nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "could not render: " + err.Error(), input: bytes.Clone(input), expected: bytes.Clone(expected)})
				return 0
			}
			if actual.renderTrap != nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "trapped: " + actual.renderTrap.Error(), input: bytes.Clone(input), expected: bytes.Clone(expected)})
				return 0
			}
			if actual.rejected {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: fmt.Sprintf("unexpected rejection (failure detail %d)", actual.failureDetail), input: bytes.Clone(input), expected: bytes.Clone(expected)})
				return 0
			}
			if !bytes.Equal(actual.output, expected) {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "output mismatch", input: bytes.Clone(input), expected: bytes.Clone(expected), actual: bytes.Clone(actual.output)})
				return 0
			}
			return 1
		}).
		Export("must_render_exactly").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen uint32) int32 {
			if !caseOpen(ordinal, "must_trap") {
				return 0
			}
			state.next++
			input, ok := readOracle(m, inPtr, inLen)
			if !ok {
				state.protocolViolation("must_trap pointer out of range at ordinal %d", ordinal)
				return 0
			}
			actual, err := state.renderImpl(callCtx, input)
			if err != nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "expected trap, could not render: " + err.Error(), input: bytes.Clone(input)})
				return 0
			}
			if actual.renderTrap == nil {
				kind := "expected trap, got output"
				if actual.rejected {
					kind = fmt.Sprintf("expected trap, got rejection (failure detail %d)", actual.failureDetail)
				}
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: kind, input: bytes.Clone(input), actual: bytes.Clone(actual.output)})
				return 0
			}
			return 1
		}).
		Export("must_trap").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen uint32) int32 {
			if !caseOpen(ordinal, "must_reject") {
				return 0
			}
			state.next++
			input, ok := readOracle(m, inPtr, inLen)
			if !ok {
				state.protocolViolation("must_reject pointer out of range at ordinal %d", ordinal)
				return 0
			}
			if !state.hasFailure {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "expected rejection, but implementation does not export failure_modes_per_input_offset", input: bytes.Clone(input)})
				return 0
			}
			actual, err := state.renderImpl(callCtx, input)
			if err != nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "expected rejection, could not render: " + err.Error(), input: bytes.Clone(input)})
				return 0
			}
			if actual.renderTrap != nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "expected rejection, render trapped: " + actual.renderTrap.Error(), input: bytes.Clone(input)})
				return 0
			}
			if !actual.rejected {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "expected rejection, render was accepted", input: bytes.Clone(input), actual: bytes.Clone(actual.output)})
				return 0
			}
			return 1
		}).
		Export("must_reject").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen, outPtr, outCap uint32) int32 {
			if state.openRenderInto != nil {
				state.protocolViolation("must_render_into opened ordinal %d while ordinal %d is still open", ordinal, *state.openRenderInto)
				return -1
			}
			if ordinal != state.next {
				state.protocolViolation("must_render_into opened ordinal %d, host expected %d", ordinal, state.next)
				return -1
			}
			o := ordinal
			state.openRenderInto = &o
			state.openRenderIntoFailed = false
			state.openRenderIntoErrCount = 0
			input, ok := readOracle(m, inPtr, inLen)
			if !ok {
				state.protocolViolation("must_render_into pointer out of range at ordinal %d", ordinal)
				state.openRenderIntoFailed = true
				return -1
			}
			output, err := state.renderImpl(callCtx, input)
			if err != nil {
				state.openRenderIntoFailed = true
				return -1
			}
			if output.renderTrap != nil || output.rejected {
				state.openRenderIntoFailed = true
				return -1
			}
			if uint32(len(output.output)) > outCap {
				state.openRenderIntoFailed = true
				return -2
			}
			if !m.Memory().Write(outPtr, output.output) {
				state.protocolViolation("must_render_into out pointer out of range at ordinal %d", ordinal)
				state.openRenderIntoFailed = true
				return -1
			}
			return int32(len(output.output))
		}).
		Export("must_render_into").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, msgPtr, msgLen uint32) int32 {
			if state.openRenderInto == nil || *state.openRenderInto != ordinal {
				state.protocolViolation("must_render_into_emit_error ordinal %d does not match open must_render_into case", ordinal)
				return 0
			}
			msg, ok := readOracle(m, msgPtr, msgLen)
			if !ok {
				state.protocolViolation("must_render_into_emit_error message pointer out of range at ordinal %d", ordinal)
				return 0
			}
			state.openRenderIntoErrCount++
			state.recordFailureNote(bridgeFailure{ordinal: ordinal, kind: "render_into error: " + string(msg)})
			return 1
		}).
		Export("must_render_into_emit_error").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, ordinal uint64, errorCount uint32) int32 {
			if state.openRenderInto == nil || *state.openRenderInto != ordinal {
				state.protocolViolation("must_render_into_finish ordinal %d does not match open must_render_into case", ordinal)
				return 0
			}
			if errorCount != state.openRenderIntoErrCount {
				state.protocolViolation("must_render_into_finish ordinal %d reported %d errors, host observed %d", ordinal, errorCount, state.openRenderIntoErrCount)
				return 0
			}
			if state.openRenderIntoFailed && errorCount == 0 {
				state.protocolViolation("must_render_into_finish ordinal %d reported 0 errors after render failure", ordinal)
				return 0
			}
			if errorCount > 0 {
				state.failCount++
			}
			state.openRenderInto = nil
			state.openRenderIntoFailed = false
			state.openRenderIntoErrCount = 0
			state.next++
			return 1
		}).
		Export("must_render_into_finish").
		Instantiate(ctx)
	if err != nil {
		out.err = fmt.Errorf("bridge host module could not be instantiated: %w", err)
		return out
	}

	oracleMod, err := r.Instantiate(ctx, compliance.wasm)
	if err != nil {
		out.err = fmt.Errorf("Compliance oracle could not be instantiated (imports must bind to %q): %w", bridgeHostModuleName, err)
		return out
	}
	defer oracleMod.Close(ctx)

	if seed != nil {
		oracleSetters, err := UniformSetterExports(oracleMod.ExportedFunctionDefinitions())
		if err != nil {
			out.err = fmt.Errorf("Compliance oracle %w", err)
			return out
		}
		seedExport, ok := oracleSetters[bridgeUniformSeed]
		if !ok {
			out.err = fmt.Errorf("--seed given but Compliance oracle does not export uniform_set_%s", bridgeUniformSeed)
			return out
		}
		if _, err := oracleMod.ExportedFunction(seedExport).Call(ctx, uint64(uint32(*seed))); err != nil {
			out.err = fmt.Errorf("%s failed: %w", seedExport, err)
			return out
		}
	}

	complyFn := oracleMod.ExportedFunction(bridgeExportComply)
	if complyFn == nil {
		out.err = errors.New("Compliance oracle must export comply() -> i32")
		return out
	}
	if err := requireSignature(complyFn.Definition(), nil, []api.ValueType{api.ValueTypeI32}, bridgeExportComply); err != nil {
		out.err = err
		return out
	}
	res, err := complyFn.Call(ctx)
	if state.protocolErr != nil {
		out.err = fmt.Errorf("bridge protocol violation: %w", state.protocolErr)
		return out
	}
	if err != nil {
		out.err = fmt.Errorf("comply() trapped: %w", err)
		return out
	}
	if state.openRenderInto != nil {
		out.err = fmt.Errorf("comply() returned with must_render_into case %d still open", *state.openRenderInto)
		return out
	}
	declared := api.DecodeI32(res[0])
	if declared <= 0 {
		out.err = fmt.Errorf("comply() declared no cases (returned %d)", declared)
		return out
	}
	if uint64(uint32(declared)) != state.next&0x7FFFFFFF {
		out.err = fmt.Errorf("comply() returned %d cases but host counted %d", declared, state.next)
		return out
	}
	out.cases = state.next
	if state.failCount > 0 {
		out.err = fmt.Errorf("%d/%d cases failed", state.failCount, state.next)
		out.detail = bridgeFailureDetail(state)
		return out
	}

	out.passed = true
	return out
}

func bridgeFailureDetail(state *bridgeState) string {
	var parts []string
	for _, f := range state.failures {
		parts = append(parts, fmt.Sprintf("case %d: %s", f.ordinal, f.kind))
		if f.input != nil {
			parts = append(parts, "  input_utf8_preview="+previewUTF8(f.input))
			parts = append(parts, "  input_hex_preview="+previewHex(f.input))
		}
		if f.expected != nil {
			parts = append(parts, "  expected_output_hex_preview="+previewHex(f.expected))
		}
		if f.actual != nil {
			parts = append(parts, "  actual_output_hex_preview="+previewHex(f.actual))
		}
	}
	if state.failCount > len(state.failures) {
		parts = append(parts, fmt.Sprintf("… and %d more failing case(s); reproduce via (component, seed, ordinal)", state.failCount-len(state.failures)))
	}
	return strings.Join(parts, "\n")
}
