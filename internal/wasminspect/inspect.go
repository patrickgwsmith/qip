package wasminspect

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
)

type scoreMetrics struct {
	InstructionTotal int
	LoopCount        int
	BranchDecision   int // br_if + if
	BrTableCount     int
	BrTableTargets   int
	CallLocal        int
	CallIndirect     int
	CallImport       int
	LoopBackedge     int
}

type functionMetrics struct {
	InstructionTotal int
	LoopCount        int
	BranchDecision   int
	BrTableCount     int
	BrTableTargets   int
	CallLocal        int
	CallIndirect     int
	CallImport       int
	LoopBackedge     int
	ControlFlowOps   int
	LocalOps         int
	MemoryOps        int
	TableOps         int
}

type globalInitMetrics struct {
	InstructionTotal int
	SimpleConst      bool
	HasGlobalGet     bool
}

type instantiationMetrics struct {
	MemoryMinPages      uint64
	TableMinElements    uint64
	ActiveDataSegments  int
	ActiveDataBytes     uint64
	ActiveElemSegments  int
	ActiveElemElements  uint64
	HasStart            bool
	StartInstructionCnt int
	StartCalls          int
	StartBranches       int
	StartLoopBackedges  int
}

type memoryLimit struct {
	Imported bool
	Memory64 bool
	MinPages uint64
	HasMax   bool
	MaxPages uint64
}

type contractCheck struct {
	Export string
	Kind   string
	Pass   bool
	Reason string
}

type wasmExport struct {
	kind  byte
	index uint32
}

type wasmAnalysis struct {
	Metrics           scoreMetrics
	InstructionCounts map[InstructionOpcode]int
	LoopBoundFailures []LoopBoundFailure
	MemoryLimits      []memoryLimit
	CallEdges         []map[int]struct{}
	ImportedFuncCount int
	ImportedGlobals   int
	FuncMetrics       []functionMetrics
	GlobalMetrics     []globalInitMetrics
	Instantiation     instantiationMetrics
	Exports           map[string]wasmExport
}

type importCounts struct {
	Funcs        int
	Globals      int
	MemoryLimits []memoryLimit
}

type LoopBoundFailure struct {
	Function int
	Loop     int
	Reason   string
}

type loopCounterDirection uint8

const (
	loopCounterInc loopCounterDirection = 1 << iota
	loopCounterDec
)

type loopCounterEvidence struct {
	update  loopCounterDirection
	exit    loopCounterDirection
	tainted bool
	// weakInc records an add of a known non-negative local (a byte load or a
	// masked value). It cannot prove progress by itself, but it does not
	// break monotonicity when the strict updates all increase.
	weakInc bool
}

type loopEvidence struct {
	index       int
	hasBackedge bool
	counters    map[uint32]loopCounterEvidence
}

type controlFrame struct {
	op      byte
	loopIdx int
	// pending holds exit candidates from conditional branches that target this
	// frame's end. If the code after the end leaves the function, those
	// branches were loop exits even though they never crossed a loop frame.
	pending []boundCandidate
}

type instrTrace struct {
	op     byte
	imm    int64
	hasImm bool
}

type boundCandidate struct {
	local     uint32
	direction loopCounterDirection
}

type derivedUpdate struct {
	src uint32
	dir loopCounterDirection
}

func copySourceLocal(recent []instrTrace) (uint32, bool) {
	if len(recent) == 0 {
		return 0, false
	}
	return traceLocalGet(recent[len(recent)-1])
}

// addChain flattens a fused add tree such as (X + load8(p)) + 1, the shape
// LLVM emits when it merges split stride updates back into one expression.
type addChain struct {
	localCount int
	local      uint32
	posConst   int
	negConst   int
	nonneg     int
	other      int
}

// operandNetPush is the stack effect of instructions the fused-chain walk
// may skip over. Unknown instructions return ok=false and abort the walk.
func operandNetPush(op byte) (pops int, pushes int, ok bool) {
	switch {
	case op == 0x20 || op == 0x23 || op == 0x41 || op == 0x42 || op == 0x43 || op == 0x44:
		return 0, 1, true // local.get, global.get, constants
	case op >= 0x28 && op <= 0x35: // loads
		return 1, 1, true
	case op == 0x45 || op == 0x50 || op == 0x22: // eqz, local.tee
		return 1, 1, true
	case op >= 0x67 && op <= 0x69, op >= 0x79 && op <= 0x7b: // clz/ctz/popcnt
		return 1, 1, true
	case op == 0xa7 || op == 0xac || op == 0xad, op >= 0xc0 && op <= 0xc4: // wrap/extend
		return 1, 1, true
	case op >= 0x46 && op <= 0x4f, op >= 0x51 && op <= 0x5a: // compares
		return 2, 1, true
	case op >= 0x6a && op <= 0x78, op >= 0x7c && op <= 0x8a: // binary arithmetic
		return 2, 1, true
	case op == 0x1b: // select
		return 3, 1, true
	default:
		return 0, 0, false
	}
}

// operandStart finds the first instruction of the self-contained operand
// whose last instruction is recent[e], by walking the stack effect backward.
func operandStart(recent []instrTrace, e int) (int, bool) {
	needed := 1
	j := e
	for needed > 0 {
		if j < 0 {
			return 0, false
		}
		pops, pushes, ok := operandNetPush(recent[j].op)
		if !ok {
			return 0, false
		}
		needed = needed - pushes + pops
		j--
	}
	return j + 1, true
}

// collectAddChain flattens the fused add tree ending at recent[e] — the
// shape LLVM emits when it merges split stride updates back into one
// expression, such as (X + load8(p)) + 1 — walking backward iteratively.
func collectAddChain(recent []instrTrace, e int, chain *addChain) bool {
	pending := 1 // operands still to consume at the current chain level
	i := e
	for pending > 0 {
		if i < 0 {
			return false
		}
		t := recent[i]
		switch t.op {
		case 0x6a, 0x7c: // add: flatten, one node becomes two operands
			pending++
			i--
		case 0x6b, 0x7d: // sub: only with a constant subtrahend, sign-flipped
			if i < 1 {
				return false
			}
			c, ok := traceConst(recent[i-1])
			if !ok {
				return false
			}
			if c > 0 {
				chain.negConst++
			} else if c < 0 {
				chain.posConst++
			}
			pending++ // minuend still pending; subtrahend consumed here
			i -= 2
		case 0x20: // local.get leaf
			if !t.hasImm {
				return false
			}
			if chain.localCount == 0 {
				chain.local = uint32(t.imm)
			} else if chain.local != uint32(t.imm) {
				chain.other++
			}
			chain.localCount++
			pending--
			i--
		case 0x41, 0x42: // constant leaf
			if !t.hasImm {
				return false
			}
			if t.imm > 0 {
				chain.posConst++
			} else if t.imm < 0 {
				chain.negConst++
			}
			pending--
			i--
		case 0x2d, 0x2f: // load8_u/load16_u leaf: non-negative narrow value
			start, ok := operandStart(recent, i-1)
			if !ok {
				return false
			}
			chain.nonneg++
			pending--
			i = start - 1
		case 0x71: // and leaf: non-negative if either side is a const >= 0
			rightStart, ok := operandStart(recent, i-1)
			if !ok {
				return false
			}
			leftStart, ok := operandStart(recent, rightStart-1)
			if !ok {
				return false
			}
			rc, rOK := traceConst(recent[i-1])
			lc, lOK := traceConst(recent[rightStart-1])
			if (rOK && rc >= 0) || (lOK && lc >= 0) {
				chain.nonneg++
			} else {
				chain.other++
			}
			pending--
			i = leftStart - 1
		default:
			return false
		}
	}
	return true
}

// detectFusedUpdate recognizes a monotonic step written as one fused
// expression: exactly one occurrence of the stored local plus positive
// constants and non-negative narrow values (strict increase), only negative
// constants (strict decrease), or only non-negative values (weak increase).
func detectFusedUpdate(recent []instrTrace, setLocal uint32) (dir loopCounterDirection, weak bool, ok bool) {
	if len(recent) < 3 {
		return 0, false, false
	}
	top := recent[len(recent)-1]
	if top.op != 0x6a && top.op != 0x7c && top.op != 0x6b && top.op != 0x7d {
		return 0, false, false
	}
	var chain addChain
	if !collectAddChain(recent, len(recent)-1, &chain) {
		return 0, false, false
	}
	if chain.other != 0 || chain.localCount != 1 || chain.local != setLocal {
		return 0, false, false
	}
	switch {
	case chain.posConst > 0 && chain.negConst == 0:
		return loopCounterInc, false, true
	case chain.negConst > 0 && chain.posConst == 0 && chain.nonneg == 0:
		return loopCounterDec, false, true
	case chain.posConst == 0 && chain.negConst == 0 && chain.nonneg > 0:
		return loopCounterInc, true, true
	default:
		return 0, false, false
	}
}

// Exported aliases for shared use by commands.
type ScoreMetrics = scoreMetrics
type FunctionMetrics = functionMetrics
type GlobalInitMetrics = globalInitMetrics
type InstantiationMetrics = instantiationMetrics
type MemoryLimit = memoryLimit
type ContractCheck = contractCheck
type Export = wasmExport
type Analysis = wasmAnalysis

const WasmPageSizeBytes uint64 = 65536

type InstructionOpcode uint32

const (
	OpcodeEnd        InstructionOpcode = 0x0b
	OpcodeCall       InstructionOpcode = 0x10
	OpcodeDrop       InstructionOpcode = 0x1a
	OpcodeMemoryGrow InstructionOpcode = 0x40
	OpcodeI32Const   InstructionOpcode = 0x41
	OpcodeI64Const   InstructionOpcode = 0x42
)

var instructionOpcodeNames = map[InstructionOpcode]string{
	0x00:             "unreachable",
	0x01:             "nop",
	0x02:             "block",
	0x03:             "loop",
	0x04:             "if",
	0x05:             "else",
	OpcodeEnd:        "end",
	0x0c:             "br",
	0x0d:             "br_if",
	0x0e:             "br_table",
	0x0f:             "return",
	OpcodeCall:       "call",
	0x11:             "call_indirect",
	0x12:             "return_call",
	0x13:             "return_call_indirect",
	0x14:             "call_ref",
	OpcodeDrop:       "drop",
	0x1b:             "select",
	0x1c:             "select_t",
	OpcodeMemoryGrow: "memory.grow",
	OpcodeI32Const:   "i32.const",
	OpcodeI64Const:   "i64.const",
}

var qipContractExports = []string{
	"input_ptr",
	"input_utf8_cap",
	"input_bytes_cap",
	"output_utf8_cap",
	"output_bytes_cap",
	"input_content_type_ptr",
	"input_content_type_size",
	"output_content_type_ptr",
	"output_content_type_size",
}

func AnalyzeModule(wasm []byte) (Analysis, error) {
	return analyzeWASMModule(wasm)
}

// ValidateStraightLineComplyOracle accepts only a single comply function made
// from constants, direct imported oracle calls, drops, and its final end.
func ValidateStraightLineComplyOracle(wasm []byte) error {
	analysis, err := AnalyzeModule(wasm)
	if err != nil {
		return err
	}

	failures := make([]string, 0)
	if len(analysis.FuncMetrics) != 1 {
		failures = append(failures, fmt.Sprintf("defines %d functions; want exactly 1", len(analysis.FuncMetrics)))
	}
	if analysis.Metrics.CallLocal > 0 {
		failures = append(failures, fmt.Sprintf("contains %d local calls", analysis.Metrics.CallLocal))
	}
	if analysis.Metrics.CallIndirect > 0 {
		failures = append(failures, fmt.Sprintf("contains %d indirect calls", analysis.Metrics.CallIndirect))
	}
	if analysis.Instantiation.HasStart {
		failures = append(failures, "defines a start function")
	}
	if analysis.ImportedGlobals > 0 {
		failures = append(failures, fmt.Sprintf("imports %d globals", analysis.ImportedGlobals))
	}
	if len(analysis.MemoryLimits) != 1 {
		failures = append(failures, fmt.Sprintf("defines or imports %d memories; want exactly 1", len(analysis.MemoryLimits)))
	}

	if len(analysis.Exports) != 2 {
		failures = append(failures, fmt.Sprintf("exports %d items; want only memory and comply", len(analysis.Exports)))
	}
	if exp, ok := analysis.Exports["memory"]; !ok || exp.kind != 0x02 {
		failures = append(failures, "does not export memory")
	}
	if exp, ok := analysis.Exports["comply"]; !ok || exp.kind != 0x00 {
		failures = append(failures, "does not export comply")
	}

	allowed := map[InstructionOpcode]bool{
		OpcodeEnd:      true,
		OpcodeCall:     true,
		OpcodeDrop:     true,
		OpcodeI32Const: true,
		OpcodeI64Const: true,
	}
	rejected := make([]int, 0)
	for opcode, count := range analysis.InstructionCounts {
		if count > 0 && !allowed[opcode] {
			rejected = append(rejected, int(opcode))
		}
	}
	sort.Ints(rejected)
	for _, rawOpcode := range rejected {
		opcode := InstructionOpcode(rawOpcode)
		failures = append(failures, fmt.Sprintf("contains %s (%d)", instructionOpcodeName(opcode), analysis.InstructionCounts[opcode]))
	}

	if len(failures) > 0 {
		return errors.New("straight-line comply oracle: " + strings.Join(failures, "; "))
	}
	return nil
}

type ModulePolicy struct {
	MaxMemoryBytes      uint64
	RejectOpcodes       []InstructionOpcode
	RequireBoundedLoops bool
}

func ValidateModulePolicy(wasm []byte, policy ModulePolicy) error {
	if policy.MaxMemoryBytes == 0 && len(policy.RejectOpcodes) == 0 && !policy.RequireBoundedLoops {
		return nil
	}

	analysis, err := AnalyzeModule(wasm)
	if err != nil {
		return err
	}

	failures := make([]string, 0)
	if policy.MaxMemoryBytes > 0 {
		for i, memory := range analysis.MemoryLimits {
			minBytes, ok := pagesToBytes(memory.MinPages)
			if !ok || minBytes > policy.MaxMemoryBytes {
				failures = append(failures, fmt.Sprintf("memory[%d] initial size %d pages exceeds --max-memory %d bytes", i, memory.MinPages, policy.MaxMemoryBytes))
			}
			if !memory.HasMax {
				failures = append(failures, fmt.Sprintf("memory[%d] has no declared maximum", i))
				continue
			}
			maxBytes, ok := pagesToBytes(memory.MaxPages)
			if !ok || maxBytes > policy.MaxMemoryBytes {
				failures = append(failures, fmt.Sprintf("memory[%d] maximum %d pages exceeds --max-memory %d bytes", i, memory.MaxPages, policy.MaxMemoryBytes))
			}
		}
	}

	for _, opcode := range policy.RejectOpcodes {
		if count := analysis.InstructionCounts[opcode]; count > 0 {
			failures = append(failures, fmt.Sprintf("violates fixed-memory policy: contains %s (%d)", instructionOpcodeName(opcode), count))
		}
	}
	if policy.RequireBoundedLoops && len(analysis.LoopBoundFailures) > 0 {
		for _, failure := range analysis.LoopBoundFailures {
			failures = append(failures, fmt.Sprintf("loop bound not proven: function %d loop %d: %s", failure.Function, failure.Loop, failure.Reason))
		}
	}

	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func instructionOpcodeName(opcode InstructionOpcode) string {
	if name, ok := instructionOpcodeNames[opcode]; ok {
		return name
	}
	return fmt.Sprintf("opcode 0x%x", uint32(opcode))
}

func pagesToBytes(pages uint64) (uint64, bool) {
	if pages > ^uint64(0)/WasmPageSizeBytes {
		return 0, false
	}
	return pages * WasmPageSizeBytes, true
}

func appendTrace(recent []instrTrace, instr instrTrace) []instrTrace {
	const maxRecent = 8
	recent = append(recent, instr)
	if len(recent) > maxRecent {
		copy(recent, recent[len(recent)-maxRecent:])
		recent = recent[:maxRecent]
	}
	return recent
}

func traceLocalGet(t instrTrace) (uint32, bool) {
	if t.op != 0x20 || !t.hasImm || t.imm < 0 {
		return 0, false
	}
	return uint32(t.imm), true
}

func traceConst(t instrTrace) (int64, bool) {
	if (t.op != 0x41 && t.op != 0x42) || !t.hasImm { // i32.const, i64.const
		return 0, false
	}
	return t.imm, true
}

// traceSinglePushOperand reports whether the instruction pushes exactly one
// value and pops none, so it forms a complete compare operand on its own:
// local.get, global.get, or a constant.
func traceSinglePushOperand(t instrTrace) bool {
	if t.op == 0x20 || t.op == 0x23 { // local.get, global.get
		return t.hasImm
	}
	_, ok := traceConst(t)
	return ok
}

func detectCounterUpdate(recent []instrTrace, setLocal uint32) (loopCounterDirection, bool) {
	src, dir, ok := detectValueUpdate(recent)
	if !ok || src != setLocal {
		return 0, false
	}
	return dir, true
}

// detectValueUpdate recognizes a value on top of the stack computed as a
// monotonic step from a local: local.get X; const C; add/sub/div/shr_u.
func detectValueUpdate(recent []instrTrace) (uint32, loopCounterDirection, bool) {
	if len(recent) < 3 {
		return 0, 0, false
	}
	a := recent[len(recent)-3]
	b := recent[len(recent)-2]
	op := recent[len(recent)-1]

	isAdd := op.op == 0x6a || op.op == 0x7c // i32.add, i64.add
	isSub := op.op == 0x6b || op.op == 0x7d // i32.sub, i64.sub

	if local, ok := traceLocalGet(a); ok {
		if c, ok := traceConst(b); ok {
			if isAdd || isSub {
				dir, ok := counterDirection(isAdd, c)
				return local, dir, ok
			}
			dir, ok := shrinkDirection(op.op, c)
			return local, dir, ok
		}
	}
	if isAdd {
		if delta, ok := traceConst(a); ok {
			if local, ok := traceLocalGet(b); ok {
				dir, ok := counterDirection(isAdd, delta)
				return local, dir, ok
			}
		}
	}
	return 0, 0, false
}

func counterDirection(isAdd bool, delta int64) (loopCounterDirection, bool) {
	if delta == 0 {
		return 0, false
	}
	if isAdd == (delta > 0) {
		return loopCounterInc, true
	}
	return loopCounterDec, true
}

// shrinkDirection recognizes updates that strictly shrink a value's magnitude
// toward zero each iteration, such as the x = x / 10 in itoa-style loops.
// i32.shr_s is excluded: shifting a negative value right saturates at -1.
func shrinkDirection(op byte, c int64) (loopCounterDirection, bool) {
	switch op {
	case 0x6d, 0x6e, 0x7f, 0x80: // i32.div_s/div_u, i64.div_s/div_u
		if c >= 2 || c <= -2 {
			return loopCounterDec, true
		}
	case 0x76: // i32.shr_u; shift counts are taken modulo the bit width
		if c&31 >= 1 {
			return loopCounterDec, true
		}
	case 0x88: // i64.shr_u
		if c&63 >= 1 {
			return loopCounterDec, true
		}
	}
	return 0, false
}

type compareKind int

const (
	cmpNone compareKind = iota
	cmpEq               // eq, ne
	cmpLt               // lt, le: exit branch taken when left < right
	cmpGt               // gt, ge: exit branch taken when left > right
)

func compareKindOf(op byte) compareKind {
	switch op {
	case 0x46, 0x47, 0x51, 0x52: // i32.eq/ne, i64.eq/ne
		return cmpEq
	case 0x48, 0x49, 0x4c, 0x4d, 0x53, 0x54, 0x57, 0x58: // i32/i64 lt_s/lt_u/le_s/le_u
		return cmpLt
	case 0x4a, 0x4b, 0x4e, 0x4f, 0x55, 0x56, 0x59, 0x5a: // i32/i64 gt_s/gt_u/ge_s/ge_u
		return cmpGt
	default:
		return cmpNone
	}
}

func detectBoundCandidates(recent []instrTrace, branchBack bool) []boundCandidate {
	if len(recent) < 2 {
		return nil
	}
	last := recent[len(recent)-1]
	prev := recent[len(recent)-2]
	if last.op == 0x45 || last.op == 0x50 { // i32.eqz, i64.eqz
		if branchBack {
			return nil
		}
		if local, ok := traceLocalGet(prev); ok {
			return []boundCandidate{{local: local, direction: loopCounterDec}}
		}
		return nil
	}
	kind := compareKindOf(last.op)
	if kind == cmpNone {
		return nil
	}

	if len(recent) >= 3 {
		leftLocal, leftLocalOK := traceLocalGet(recent[len(recent)-3])
		rightLocal, rightLocalOK := traceLocalGet(recent[len(recent)-2])
		if leftLocalOK && rightLocalOK {
			return compareBoundCandidates(kind, leftLocal, rightLocal, branchBack)
		}
		if leftLocalOK && traceSinglePushOperand(recent[len(recent)-2]) {
			return oneSidedBoundCandidates(kind, leftLocal, false, branchBack)
		}
		if rightLocalOK && traceSinglePushOperand(recent[len(recent)-3]) {
			return oneSidedBoundCandidates(kind, rightLocal, true, branchBack)
		}
	}

	// Left operand as a monotonic expression of a local, such as
	// local.get i; i32.const 4; i32.add; local.get n; i32.gt_u. The three
	// instructions form one complete operand (two pushes, one pop-2-push-1),
	// so the single-push instruction after them must be the right operand.
	if len(recent) >= 5 {
		if traceSinglePushOperand(recent[len(recent)-2]) {
			if x, _, ok := detectValueUpdate(recent[:len(recent)-2]); ok {
				if rightLocal, ok := traceLocalGet(recent[len(recent)-2]); ok {
					return compareBoundCandidates(kind, x, rightLocal, branchBack)
				}
				return oneSidedBoundCandidates(kind, x, false, branchBack)
			}
		}
	}

	// Common bottom-tested shape after an update:
	// local.get bound; local.get i; i32.const 1; i32.add; local.tee i; i32.ne
	if len(recent) >= 6 && recent[len(recent)-2].op == 0x22 {
		local := uint32(recent[len(recent)-2].imm)
		if _, ok := traceLocalGet(recent[len(recent)-6]); ok {
			if dir, ok := detectCounterUpdate(recent[:len(recent)-2], local); ok {
				return []boundCandidate{{local: local, direction: dir}}
			}
		}
	}
	// Equivalent bottom-tested shape with the updated counter on the left:
	// local.get i; i32.const -1; i32.add; local.tee i; local.get bound; i32.gt_u
	if len(recent) >= 6 && recent[len(recent)-3].op == 0x22 {
		local := uint32(recent[len(recent)-3].imm)
		if _, ok := traceLocalGet(recent[len(recent)-2]); ok {
			if dir, ok := detectCounterUpdate(recent[:len(recent)-3], local); ok {
				return []boundCandidate{{local: local, direction: dir}}
			}
		}
	}

	// Right operand as a monotonic expression of a local: the three
	// instructions before the compare form the complete right operand.
	if len(recent) >= 4 {
		if x, _, ok := detectValueUpdate(recent[:len(recent)-1]); ok {
			return oneSidedBoundCandidates(kind, x, true, branchBack)
		}
	}

	// One-sided fallback: a lone local.get directly before a binary compare must
	// be the complete right operand, whatever produced the left operand. The
	// mirror case (visible left, computed right) is not safe: the instruction at
	// recent[-3] may be part of the right operand's computation, such as the
	// address feeding a load. Ordered compares only; an equality test against an
	// unknown, possibly moving value says nothing about termination.
	if kind != cmpEq {
		if rightLocal, ok := traceLocalGet(prev); ok {
			return oneSidedBoundCandidates(kind, rightLocal, true, branchBack)
		}
	}
	return nil
}

func oneSidedBoundCandidates(kind compareKind, local uint32, localOnRight bool, branchBack bool) []boundCandidate {
	switch kind {
	case cmpEq:
		return []boundCandidate{{local: local, direction: loopCounterInc | loopCounterDec}}
	case cmpLt, cmpGt:
		exit := loopCounterDec // left of lt, right of gt
		if (kind == cmpLt) == localOnRight {
			exit = loopCounterInc
		}
		return []boundCandidate{{local: local, direction: chooseBoundDirection(exit, branchBack)}}
	default:
		return nil
	}
}

func compareBoundCandidates(kind compareKind, left uint32, right uint32, branchBack bool) []boundCandidate {
	switch kind {
	case cmpEq:
		return []boundCandidate{
			{local: left, direction: loopCounterInc | loopCounterDec},
			{local: right, direction: loopCounterInc | loopCounterDec},
		}
	case cmpGt:
		return []boundCandidate{
			{local: left, direction: chooseBoundDirection(loopCounterInc, branchBack)},
			{local: right, direction: chooseBoundDirection(loopCounterDec, branchBack)},
		}
	case cmpLt:
		return []boundCandidate{
			{local: left, direction: chooseBoundDirection(loopCounterDec, branchBack)},
			{local: right, direction: chooseBoundDirection(loopCounterInc, branchBack)},
		}
	default:
		return nil
	}
}

func chooseBoundDirection(exitDirection loopCounterDirection, branchBack bool) loopCounterDirection {
	if !branchBack {
		return exitDirection
	}
	switch exitDirection {
	case loopCounterInc:
		return loopCounterDec
	case loopCounterDec:
		return loopCounterInc
	default:
		return exitDirection
	}
}

func markLoopCounterUpdate(loops []loopEvidence, controlStack []controlFrame, local uint32, direction loopCounterDirection) {
	if direction == 0 {
		return
	}
	for _, frame := range controlStack {
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		if loop.counters == nil {
			loop.counters = map[uint32]loopCounterEvidence{}
		}
		evidence := loop.counters[local]
		evidence.update |= direction
		loop.counters[local] = evidence
	}
}

// markLoopCounterTaint records a write to a local that is not a recognized
// monotonic constant update. A tainted local cannot prove the loop: some
// write could move it away from the exit bound.
func markLoopCounterTaint(loops []loopEvidence, controlStack []controlFrame, local uint32) {
	for _, frame := range controlStack {
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		if loop.counters == nil {
			loop.counters = map[uint32]loopCounterEvidence{}
		}
		evidence := loop.counters[local]
		evidence.tainted = true
		loop.counters[local] = evidence
	}
}

func markLoopCounterWeakInc(loops []loopEvidence, controlStack []controlFrame, local uint32) {
	for _, frame := range controlStack {
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		if loop.counters == nil {
			loop.counters = map[uint32]loopCounterEvidence{}
		}
		evidence := loop.counters[local]
		evidence.weakInc = true
		loop.counters[local] = evidence
	}
}

// detectNonnegLocalStep matches local.get X; local.get T; i32.add (either
// operand order) storing back into X, where T is known non-negative.
func detectNonnegLocalStep(recent []instrTrace, setLocal uint32, smallNonneg map[uint32]bool) bool {
	if len(recent) < 3 {
		return false
	}
	a := recent[len(recent)-3]
	b := recent[len(recent)-2]
	op := recent[len(recent)-1]
	if op.op != 0x6a && op.op != 0x7c { // i32.add, i64.add
		return false
	}
	aLocal, aOK := traceLocalGet(a)
	bLocal, bOK := traceLocalGet(b)
	if !aOK || !bOK {
		return false
	}
	if aLocal == setLocal && smallNonneg[bLocal] {
		return true
	}
	if bLocal == setLocal && smallNonneg[aLocal] {
		return true
	}
	return false
}

// isSmallNonnegSource reports whether the value about to be stored is known
// non-negative and far below the wrap boundary: a narrow load or a mask by a
// non-negative constant.
func isSmallNonnegSource(recent []instrTrace) bool {
	if len(recent) == 0 {
		return false
	}
	last := recent[len(recent)-1]
	switch last.op {
	case 0x2d, 0x2f: // i32.load8_u, i32.load16_u
		return true
	case 0x71: // i32.and with a non-negative constant on either side
		if len(recent) >= 2 {
			if c, ok := traceConst(recent[len(recent)-2]); ok && c >= 0 {
				return true
			}
		}
		if len(recent) >= 3 {
			if c, ok := traceConst(recent[len(recent)-3]); ok && c >= 0 {
				return true
			}
		}
	}
	return false
}

func markLoopCounterExit(loop *loopEvidence, candidate boundCandidate) {
	if candidate.direction == 0 {
		return
	}
	if loop.counters == nil {
		loop.counters = map[uint32]loopCounterEvidence{}
	}
	evidence := loop.counters[candidate.local]
	evidence.exit |= candidate.direction
	loop.counters[candidate.local] = evidence
}

func loopHasBoundedCounter(loop loopEvidence) bool {
	for _, evidence := range loop.counters {
		if evidence.tainted {
			continue
		}
		// Updates in both directions are not monotonic.
		if evidence.update != loopCounterInc && evidence.update != loopCounterDec {
			continue
		}
		// A non-negative extra step only preserves monotonic increase.
		if evidence.weakInc && evidence.update != loopCounterInc {
			continue
		}
		if evidence.update&evidence.exit != 0 {
			return true
		}
	}
	return false
}

func DetectCallCycle(edges []map[int]struct{}) (bool, []int) {
	return detectCallCycle(edges)
}

func EvaluateQIPContractChecks(analysis Analysis) ([]ContractCheck, bool) {
	return evaluateContractChecks(
		analysis.Exports,
		analysis.ImportedFuncCount,
		analysis.FuncMetrics,
		analysis.ImportedGlobals,
		analysis.GlobalMetrics,
	)
}

func evaluateContractChecks(
	exports map[string]wasmExport,
	importedFuncCount int,
	fnMetrics []functionMetrics,
	importedGlobals int,
	globalMetrics []globalInitMetrics,
) ([]contractCheck, bool) {
	checks := make([]contractCheck, 0, len(qipContractExports))
	fail := false

	for _, name := range qipContractExports {
		exp, ok := exports[name]
		if !ok {
			continue
		}
		switch exp.kind {
		case 0x00: // function
			globalIdx := int(exp.index)
			if globalIdx < importedFuncCount {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: false, Reason: "imported function"})
				fail = true
				continue
			}
			defIdx := globalIdx - importedFuncCount
			if defIdx < 0 || defIdx >= len(fnMetrics) {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: false, Reason: "function index out of range"})
				fail = true
				continue
			}
			fm := fnMetrics[defIdx]
			reasons := make([]string, 0, 4)
			if fm.CallLocal+fm.CallImport+fm.CallIndirect > 0 {
				reasons = append(reasons, "contains call")
			}
			if fm.LoopBackedge > 0 {
				reasons = append(reasons, "contains loop")
			}
			if fm.BranchDecision > 0 || fm.BrTableCount > 0 || fm.ControlFlowOps > 0 {
				reasons = append(reasons, "contains branch/control flow")
			}
			if fm.LocalOps > 0 {
				reasons = append(reasons, "contains local ops")
			}
			if fm.MemoryOps > 0 || fm.TableOps > 0 {
				reasons = append(reasons, "contains memory/table ops")
			}
			if len(reasons) > 0 {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: false, Reason: strings.Join(reasons, ", ")})
				fail = true
			} else {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: true})
			}
		case 0x03: // global
			checks = append(checks, contractCheck{Export: name, Kind: "global", Pass: false, Reason: "must be function"})
			fail = true
		default:
			checks = append(checks, contractCheck{Export: name, Kind: fmt.Sprintf("kind=%d", exp.kind), Pass: false, Reason: "unsupported export kind"})
			fail = true
		}
	}

	return checks, fail
}

type wasmReader struct {
	data []byte
	off  int
}

func newWasmReader(data []byte) *wasmReader {
	return &wasmReader{data: data}
}

func (r *wasmReader) remaining() int {
	return len(r.data) - r.off
}

func (r *wasmReader) offset() int {
	return r.off
}

func (r *wasmReader) readByte() (byte, error) {
	if r.off >= len(r.data) {
		return 0, io.ErrUnexpectedEOF
	}
	b := r.data[r.off]
	r.off++
	return b, nil
}

func (r *wasmReader) peekByte() (byte, error) {
	if r.off >= len(r.data) {
		return 0, io.ErrUnexpectedEOF
	}
	return r.data[r.off], nil
}

func (r *wasmReader) readN(n int) ([]byte, error) {
	if n < 0 || r.remaining() < n {
		return nil, io.ErrUnexpectedEOF
	}
	start := r.off
	r.off += n
	return r.data[start:r.off], nil
}

func (r *wasmReader) readVarU32() (uint32, error) {
	var result uint32
	var shift uint
	for range 5 {
		b, err := r.readByte()
		if err != nil {
			return 0, err
		}
		result |= uint32(b&0x7f) << shift
		if b&0x80 == 0 {
			return result, nil
		}
		shift += 7
	}
	return 0, errors.New("invalid u32 leb128")
}

func (r *wasmReader) readVarU64() (uint64, error) {
	var result uint64
	var shift uint
	for range 10 {
		b, err := r.readByte()
		if err != nil {
			return 0, err
		}
		result |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return result, nil
		}
		shift += 7
	}
	return 0, errors.New("invalid u64 leb128")
}

func (r *wasmReader) readVarS32() (int32, error) {
	var result int32
	var shift uint
	var b byte
	for i := range 5 {
		var err error
		b, err = r.readByte()
		if err != nil {
			return 0, err
		}
		result |= int32(b&0x7f) << shift
		shift += 7
		if b&0x80 == 0 {
			break
		}
		if i == 4 {
			return 0, errors.New("invalid s32 leb128")
		}
	}
	if shift < 32 && (b&0x40) != 0 {
		result |= ^int32(0) << shift
	}
	return result, nil
}

func (r *wasmReader) readVarS64(maxBytes int) (int64, error) {
	var result int64
	var shift uint
	var b byte
	for i := range maxBytes {
		var err error
		b, err = r.readByte()
		if err != nil {
			return 0, err
		}
		result |= int64(b&0x7f) << shift
		shift += 7
		if b&0x80 == 0 {
			break
		}
		if i == maxBytes-1 {
			return 0, errors.New("invalid s64 leb128")
		}
	}
	if shift < 64 && (b&0x40) != 0 {
		result |= ^int64(0) << shift
	}
	return result, nil
}

func (r *wasmReader) readName() (string, error) {
	n, err := r.readVarU32()
	if err != nil {
		return "", err
	}
	b, err := r.readN(int(n))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func analyzeWASMModule(wasm []byte) (wasmAnalysis, error) {
	if len(wasm) < 8 {
		return wasmAnalysis{}, errors.New("invalid wasm: file too small")
	}
	if string(wasm[0:4]) != "\x00asm" {
		return wasmAnalysis{}, errors.New("invalid wasm: bad magic")
	}
	if wasm[4] != 0x01 || wasm[5] != 0x00 || wasm[6] != 0x00 || wasm[7] != 0x00 {
		return wasmAnalysis{}, errors.New("invalid wasm: unsupported version")
	}

	r := newWasmReader(wasm[8:])
	var imports importCounts
	var functionTypeIdx []uint32
	analysis := wasmAnalysis{
		InstructionCounts: map[InstructionOpcode]int{},
		Exports:           map[string]wasmExport{},
	}
	startFuncIdx := -1

	for r.remaining() > 0 {
		sectionID, err := r.readByte()
		if err != nil {
			return wasmAnalysis{}, fmt.Errorf("read section id at offset %d: %w", r.offset()+8, err)
		}
		sectionSize, err := r.readVarU32()
		if err != nil {
			return wasmAnalysis{}, fmt.Errorf("read section size at offset %d: %w", r.offset()+8, err)
		}
		payload, err := r.readN(int(sectionSize))
		if err != nil {
			return wasmAnalysis{}, fmt.Errorf("read section payload id=%d at offset %d: %w", sectionID, r.offset()+8, err)
		}

		switch sectionID {
		case 0:
			// custom section
		case 1:
			if err := parseTypeSection(payload); err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse type section: %w", err)
			}
		case 2:
			counts, err := parseImportSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse import section: %w", err)
			}
			imports = counts
			analysis.MemoryLimits = append(analysis.MemoryLimits, counts.MemoryLimits...)
			for _, memory := range counts.MemoryLimits {
				analysis.Instantiation.MemoryMinPages += memory.MinPages
			}
		case 3:
			idxs, err := parseFunctionSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse function section: %w", err)
			}
			functionTypeIdx = idxs
		case 4:
			min, err := parseTableSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse table section: %w", err)
			}
			analysis.Instantiation.TableMinElements = min
		case 5:
			memories, err := parseMemorySection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse memory section: %w", err)
			}
			analysis.MemoryLimits = append(analysis.MemoryLimits, memories...)
			for _, memory := range memories {
				analysis.Instantiation.MemoryMinPages += memory.MinPages
			}
		case 6:
			globals, err := parseGlobalSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse global section: %w", err)
			}
			analysis.GlobalMetrics = globals
		case 7:
			exports, err := parseExportSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse export section: %w", err)
			}
			analysis.Exports = exports
		case 8:
			startIdx, hasStart, err := parseStartSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse start section: %w", err)
			}
			if hasStart {
				startFuncIdx = int(startIdx)
				analysis.Instantiation.HasStart = true
			}
		case 10:
			edges, fnMetrics, loopFailures, err := parseCodeSection(payload, imports.Funcs, len(functionTypeIdx), &analysis.Metrics, analysis.InstructionCounts)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse code section: %w", err)
			}
			analysis.CallEdges = edges
			analysis.FuncMetrics = fnMetrics
			analysis.LoopBoundFailures = append(analysis.LoopBoundFailures, loopFailures...)
		case 9:
			segCount, elemCount, err := parseElementSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse element section: %w", err)
			}
			analysis.Instantiation.ActiveElemSegments = segCount
			analysis.Instantiation.ActiveElemElements = elemCount
		case 11:
			segCount, byteCount, err := parseDataSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse data section: %w", err)
			}
			analysis.Instantiation.ActiveDataSegments = segCount
			analysis.Instantiation.ActiveDataBytes = byteCount
		}
	}

	analysis.ImportedFuncCount = imports.Funcs
	analysis.ImportedGlobals = imports.Globals

	if len(functionTypeIdx) != 0 && analysis.CallEdges == nil {
		return wasmAnalysis{}, errors.New("invalid wasm: function section without code section")
	}
	if analysis.CallEdges == nil {
		analysis.CallEdges = make([]map[int]struct{}, 0)
		analysis.FuncMetrics = make([]functionMetrics, 0)
	}
	if startFuncIdx >= 0 {
		if startFuncIdx >= imports.Funcs {
			defIdx := startFuncIdx - imports.Funcs
			if defIdx >= 0 && defIdx < len(analysis.FuncMetrics) {
				fm := analysis.FuncMetrics[defIdx]
				analysis.Instantiation.StartInstructionCnt = fm.InstructionTotal
				analysis.Instantiation.StartCalls = fm.CallLocal + fm.CallImport + fm.CallIndirect
				analysis.Instantiation.StartBranches = fm.BranchDecision + fm.BrTableCount + fm.ControlFlowOps
				analysis.Instantiation.StartLoopBackedges = fm.LoopBackedge
			}
		}
	}

	return analysis, nil
}

func parseTypeSection(payload []byte) error {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return err
	}
	for i := 0; i < int(n); i++ {
		form, err := r.readByte()
		if err != nil {
			return err
		}
		if form != 0x60 {
			return fmt.Errorf("unsupported type form 0x%x", form)
		}
		params, err := r.readVarU32()
		if err != nil {
			return err
		}
		if _, err := r.readN(int(params)); err != nil {
			return err
		}
		results, err := r.readVarU32()
		if err != nil {
			return err
		}
		if _, err := r.readN(int(results)); err != nil {
			return err
		}
	}
	if r.remaining() != 0 {
		return errors.New("trailing bytes in type section")
	}
	return nil
}

func parseImportSection(payload []byte) (importCounts, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return importCounts{}, err
	}
	counts := importCounts{}
	for i := 0; i < int(n); i++ {
		if _, err := r.readName(); err != nil {
			return importCounts{}, err
		}
		if _, err := r.readName(); err != nil {
			return importCounts{}, err
		}
		kind, err := r.readByte()
		if err != nil {
			return importCounts{}, err
		}
		switch kind {
		case 0x00: // func
			if _, err := r.readVarU32(); err != nil {
				return importCounts{}, err
			}
			counts.Funcs++
		case 0x01: // table
			if err := skipTableType(r); err != nil {
				return importCounts{}, err
			}
		case 0x02: // memory
			limit, err := parseLimits(r)
			if err != nil {
				return importCounts{}, err
			}
			limit.Imported = true
			counts.MemoryLimits = append(counts.MemoryLimits, limit)
		case 0x03: // global
			if err := skipGlobalType(r); err != nil {
				return importCounts{}, err
			}
			counts.Globals++
		case 0x04: // tag
			if _, err := r.readByte(); err != nil {
				return importCounts{}, err
			}
			if _, err := r.readVarU32(); err != nil {
				return importCounts{}, err
			}
		default:
			return importCounts{}, fmt.Errorf("unsupported import kind 0x%x", kind)
		}
	}
	if r.remaining() != 0 {
		return importCounts{}, errors.New("trailing bytes in import section")
	}
	return counts, nil
}

func parseFunctionSection(payload []byte) ([]uint32, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	idxs := make([]uint32, 0, n)
	for i := 0; i < int(n); i++ {
		v, err := r.readVarU32()
		if err != nil {
			return nil, err
		}
		idxs = append(idxs, v)
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in function section")
	}
	return idxs, nil
}

func parseGlobalSection(payload []byte) ([]globalInitMetrics, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	globals := make([]globalInitMetrics, 0, n)
	for i := 0; i < int(n); i++ {
		if err := skipGlobalType(r); err != nil {
			return nil, err
		}
		gm, err := parseGlobalInitExpr(r)
		if err != nil {
			return nil, err
		}
		globals = append(globals, gm)
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in global section")
	}
	return globals, nil
}

func parseExportSection(payload []byte) (map[string]wasmExport, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	exports := make(map[string]wasmExport, n)
	for i := 0; i < int(n); i++ {
		name, err := r.readName()
		if err != nil {
			return nil, err
		}
		kind, err := r.readByte()
		if err != nil {
			return nil, err
		}
		idx, err := r.readVarU32()
		if err != nil {
			return nil, err
		}
		exports[name] = wasmExport{kind: kind, index: idx}
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in export section")
	}
	return exports, nil
}

func parseStartSection(payload []byte) (uint32, bool, error) {
	r := newWasmReader(payload)
	idx, err := r.readVarU32()
	if err != nil {
		return 0, false, err
	}
	if r.remaining() != 0 {
		return 0, false, errors.New("trailing bytes in start section")
	}
	return idx, true, nil
}

func parseMemorySection(payload []byte) ([]memoryLimit, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	memories := make([]memoryLimit, 0, n)
	for i := 0; i < int(n); i++ {
		limit, err := parseLimits(r)
		if err != nil {
			return nil, err
		}
		memories = append(memories, limit)
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in memory section")
	}
	return memories, nil
}

func parseTableSection(payload []byte) (uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, err
	}
	var minElems uint64
	for i := 0; i < int(n); i++ {
		if _, err := r.readByte(); err != nil { // reftype
			return 0, err
		}
		min, err := parseLimitsMin(r)
		if err != nil {
			return 0, err
		}
		minElems += min
	}
	if r.remaining() != 0 {
		return 0, errors.New("trailing bytes in table section")
	}
	return minElems, nil
}

func parseDataSection(payload []byte) (int, uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, 0, err
	}
	segments := 0
	var bytes uint64
	for i := 0; i < int(n); i++ {
		flags, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}
		active := false
		switch flags {
		case 0:
			active = true
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		case 1:
			// passive
		case 2:
			active = true
			if _, err := r.readVarU32(); err != nil { // memidx
				return 0, 0, err
			}
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		default:
			return 0, 0, fmt.Errorf("unsupported data segment flags %d", flags)
		}
		size, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}
		if _, err := r.readN(int(size)); err != nil {
			return 0, 0, err
		}
		if active {
			segments++
			bytes += uint64(size)
		}
	}
	if r.remaining() != 0 {
		return 0, 0, errors.New("trailing bytes in data section")
	}
	return segments, bytes, nil
}

func parseElementSection(payload []byte) (int, uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, 0, err
	}
	activeSegments := 0
	var activeElems uint64
	for i := 0; i < int(n); i++ {
		flags, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}

		active := false
		exprElems := false
		switch flags {
		case 0:
			active = true
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		case 1:
			if _, err := r.readByte(); err != nil { // elemkind
				return 0, 0, err
			}
		case 2:
			active = true
			if _, err := r.readVarU32(); err != nil { // tableidx
				return 0, 0, err
			}
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
			if _, err := r.readByte(); err != nil { // elemkind
				return 0, 0, err
			}
		case 3:
			if _, err := r.readByte(); err != nil { // elemkind
				return 0, 0, err
			}
		case 4:
			active = true
			exprElems = true
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		case 5:
			exprElems = true
			if _, err := r.readByte(); err != nil { // reftype
				return 0, 0, err
			}
		case 6:
			active = true
			exprElems = true
			if _, err := r.readVarU32(); err != nil { // tableidx
				return 0, 0, err
			}
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
			if _, err := r.readByte(); err != nil { // reftype
				return 0, 0, err
			}
		case 7:
			exprElems = true
			if _, err := r.readByte(); err != nil { // reftype
				return 0, 0, err
			}
		default:
			return 0, 0, fmt.Errorf("unsupported element segment flags %d", flags)
		}

		elemCount, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}
		if exprElems {
			for j := 0; j < int(elemCount); j++ {
				if err := skipConstExpr(r); err != nil {
					return 0, 0, err
				}
			}
		} else {
			for j := 0; j < int(elemCount); j++ {
				if _, err := r.readVarU32(); err != nil {
					return 0, 0, err
				}
			}
		}
		if active {
			activeSegments++
			activeElems += uint64(elemCount)
		}
	}
	if r.remaining() != 0 {
		return 0, 0, errors.New("trailing bytes in element section")
	}
	return activeSegments, activeElems, nil
}

func parseCodeSection(
	payload []byte,
	importedFuncCount int,
	definedFuncCount int,
	metrics *scoreMetrics,
	instructionCounts map[InstructionOpcode]int,
) ([]map[int]struct{}, []functionMetrics, []LoopBoundFailure, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, nil, nil, err
	}
	if int(n) != definedFuncCount {
		return nil, nil, nil, fmt.Errorf("function/code count mismatch: function=%d code=%d", definedFuncCount, n)
	}
	edges := make([]map[int]struct{}, definedFuncCount)
	funcMetrics := make([]functionMetrics, definedFuncCount)
	loopFailures := make([]LoopBoundFailure, 0)
	for i := 0; i < int(n); i++ {
		bodySize, err := r.readVarU32()
		if err != nil {
			return nil, nil, nil, err
		}
		body, err := r.readN(int(bodySize))
		if err != nil {
			return nil, nil, nil, err
		}
		fm, failures, err := parseFunctionBody(body, i, importedFuncCount, definedFuncCount, metrics, instructionCounts, edges)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("function %d: %w", i, err)
		}
		funcMetrics[i] = fm
		loopFailures = append(loopFailures, failures...)
	}
	if r.remaining() != 0 {
		return nil, nil, nil, errors.New("trailing bytes in code section")
	}
	return edges, funcMetrics, loopFailures, nil
}

// bodyExitInfo holds the results of the must-exit prepass over a function
// body. mustExit[i] means every path starting at instruction ordinal i
// leaves the function: no path reaches a loop backedge or runs on. The
// virtual index past the final end is true (falling off returns).
// takenExit[i] is, for a br/br_if at ordinal i, whether the taken edge must
// exit; false for backedges and unhandled shapes (under-approximation is
// sound: it only credits less exit evidence).
type bodyExitInfo struct {
	mustExit  []bool
	takenExit []bool
	// elseExit[i] is, for an if at ordinal i, whether the false edge (the
	// else body, or the code after the end when there is no else) must exit.
	elseExit []bool
}

const (
	auxBackedge  = -1
	auxFuncLabel = -2
)

type preFrame struct {
	isLoop  bool
	ifOrd   int // ordinal of the frame's if instruction, -1 otherwise
	brSites []int
}

// computeBodyExit decodes the body once to resolve every forward branch to
// its continuation ordinal, then computes must-exit backward. Structured
// control flow makes one reverse pass sufficient: every edge except loop
// backedges points forward, and backedges are simply "not an exit".
func computeBodyExit(body []byte) (bodyExitInfo, error) {
	r := newWasmReader(body)
	localDecls, err := r.readVarU32()
	if err != nil {
		return bodyExitInfo{}, err
	}
	for i := 0; i < int(localDecls); i++ {
		if _, err := r.readVarU32(); err != nil {
			return bodyExitInfo{}, err
		}
		if _, err := r.readByte(); err != nil {
			return bodyExitInfo{}, err
		}
	}

	ops := make([]byte, 0, 64)
	aux := make([]int32, 0, 64)
	frames := make([]preFrame, 0, 16)
	ifElseCont := map[int]int{} // if ordinal -> ordinal of its false edge

	appendInstr := func(op byte, a int32) {
		ops = append(ops, op)
		aux = append(aux, a)
	}

	for {
		op, err := r.readByte()
		if err != nil {
			return bodyExitInfo{}, err
		}
		ord := len(ops)
		switch op {
		case 0x02, 0x03, 0x04:
			if err := readBlockType(r); err != nil {
				return bodyExitInfo{}, err
			}
			ifOrd := -1
			if op == 0x04 {
				ifOrd = ord
			}
			frames = append(frames, preFrame{isLoop: op == 0x03, ifOrd: ifOrd})
			appendInstr(op, 0)
		case 0x05:
			// The then-arm jumps from here to after the if's end; the if's
			// false edge enters the else body at ord+1.
			if len(frames) > 0 {
				f := &frames[len(frames)-1]
				if f.ifOrd >= 0 {
					ifElseCont[f.ifOrd] = ord + 1
					f.brSites = append(f.brSites, ord) // resolve else's jump at end
				}
			}
			appendInstr(op, 0)
		case 0x0b:
			appendInstr(op, 0)
			if len(frames) == 0 {
				if r.remaining() != 0 {
					return bodyExitInfo{}, errors.New("trailing bytes after final end")
				}
				return finishBodyExit(ops, aux, ifElseCont), nil
			}
			f := frames[len(frames)-1]
			frames = frames[:len(frames)-1]
			for _, site := range f.brSites {
				aux[site] = int32(ord + 1)
			}
			if f.ifOrd >= 0 {
				if _, has := ifElseCont[f.ifOrd]; !has {
					ifElseCont[f.ifOrd] = ord + 1
				}
			}
		case 0x0c, 0x0d:
			depth, err := r.readVarU32()
			if err != nil {
				return bodyExitInfo{}, err
			}
			a := int32(auxFuncLabel)
			if int(depth) < len(frames) {
				target := len(frames) - 1 - int(depth)
				if frames[target].isLoop {
					a = auxBackedge
				} else {
					a = 0
					frames[target].brSites = append(frames[target].brSites, ord)
				}
			}
			appendInstr(op, a)
		case 0x0e:
			targetCount, err := r.readVarU32()
			if err != nil {
				return bodyExitInfo{}, err
			}
			for i := 0; i <= int(targetCount); i++ {
				if _, err := r.readVarU32(); err != nil {
					return bodyExitInfo{}, err
				}
			}
			appendInstr(op, 0)
		default:
			if err := skipInstrImmediates(r, op); err != nil {
				return bodyExitInfo{}, err
			}
			appendInstr(op, 0)
		}
	}
}

func finishBodyExit(ops []byte, aux []int32, ifElseCont map[int]int) bodyExitInfo {
	n := len(ops)
	mustExit := make([]bool, n+1)
	takenExit := make([]bool, n)
	elseExit := make([]bool, n)
	mustExit[n] = true
	for i := n - 1; i >= 0; i-- {
		switch ops[i] {
		case 0x00, 0x0f: // unreachable, return
			mustExit[i] = true
		case 0x0c: // br
			takenExit[i] = branchEdgeExits(aux[i], mustExit)
			mustExit[i] = takenExit[i]
		case 0x0d: // br_if
			takenExit[i] = branchEdgeExits(aux[i], mustExit)
			mustExit[i] = takenExit[i] && mustExit[i+1]
		case 0x0e: // br_table: not tracked, under-approximate
			mustExit[i] = false
		case 0x04: // if: both edges must exit
			elseCont, has := ifElseCont[i]
			elseExit[i] = has && mustExit[elseCont]
			mustExit[i] = mustExit[i+1] && elseExit[i]
		case 0x05: // else marker: the then-arm's jump to after the end
			if aux[i] > 0 {
				mustExit[i] = mustExit[aux[i]]
			}
		default:
			mustExit[i] = mustExit[i+1]
		}
	}
	return bodyExitInfo{mustExit: mustExit, takenExit: takenExit, elseExit: elseExit}
}

func branchEdgeExits(a int32, mustExit []bool) bool {
	switch a {
	case auxBackedge:
		return false
	case auxFuncLabel:
		return true
	default:
		return mustExit[a]
	}
}

// skipInstrImmediates consumes the immediates of every instruction the
// must-exit prepass does not model explicitly.
func skipInstrImmediates(r *wasmReader, op byte) error {
	switch op {
	case 0x01, 0x0f, 0x1a, 0x1b, 0xd1, 0x00:
		return nil
	case 0x10, 0x12, 0x3f, 0x40, 0xd2:
		_, err := r.readVarU32()
		return err
	case 0x11, 0x13:
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		_, err := r.readVarU32()
		return err
	case 0x14:
		_, err := r.readVarU32()
		return err
	case 0x1c:
		count, err := r.readVarU32()
		if err != nil {
			return err
		}
		_, err = r.readN(int(count))
		return err
	case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26:
		_, err := r.readVarU32()
		return err
	case 0x41:
		_, err := r.readVarS32()
		return err
	case 0x42:
		_, err := r.readVarS64(10)
		return err
	case 0x43:
		_, err := r.readN(4)
		return err
	case 0x44:
		_, err := r.readN(8)
		return err
	case 0xd0:
		_, err := r.readByte()
		return err
	case 0xfc:
		return readFCImmediate(r)
	case 0xfd:
		return readFDImmediate(r)
	case 0xfe:
		return readFEImmediate(r)
	default:
		if op >= 0x28 && op <= 0x3e {
			return readMemArg(r)
		}
		return nil
	}
}

func parseFunctionBody(
	body []byte,
	funcIdx int,
	importedFuncCount int,
	definedFuncCount int,
	metrics *scoreMetrics,
	instructionCounts map[InstructionOpcode]int,
	edges []map[int]struct{},
) (functionMetrics, []LoopBoundFailure, error) {
	r := newWasmReader(body)
	localDecls, err := r.readVarU32()
	if err != nil {
		return functionMetrics{}, nil, err
	}
	for i := 0; i < int(localDecls); i++ {
		if _, err := r.readVarU32(); err != nil {
			return functionMetrics{}, nil, err
		}
		if _, err := r.readByte(); err != nil {
			return functionMetrics{}, nil, err
		}
	}

	const (
		opBlock = 0x02
		opLoop  = 0x03
		opIf    = 0x04
		opElse  = 0x05
		opEnd   = 0x0b
	)

	fm := functionMetrics{}
	controlStack := make([]controlFrame, 0, 16)
	loops := make([]loopEvidence, 0, 8)
	loopFailures := make([]LoopBoundFailure, 0)
	recent := make([]instrTrace, 0, 8)
	// derived[T] means local T currently holds a monotonic step of local src,
	// as in the itoa shape: local.tee T (i64.div_u (local.get X) (i64.const 10))
	// ... local.set X (local.get T). The copy back closes the update on X.
	derived := map[uint32]derivedUpdate{}
	// smallNonneg[T] means local T holds a known non-negative narrow value,
	// so x += T is a weak (non-taint) increase, as in i += 1 + len strides.
	smallNonneg := map[uint32]bool{}
	// armed carries a just-ended block's pending exit candidates. If control
	// then leaves the function before any other control flow, the branches
	// that targeted that block exited every enclosing loop.
	var armed []boundCandidate
	// pendingTaint defers a local.set's taint by one instruction. If the next
	// instruction is an unconditional br or a return, the write is on an exit
	// path, as in the `i = n` copy LLVM emits before leaving a scan loop, and
	// it can't reach another iteration of the loops that branch leaves. Only
	// the frames the branch stays inside are tainted.
	pendingTaint, hasPendingTaint := uint32(0), false
	resolvePendingTaint := func(keep int) {
		if hasPendingTaint {
			markLoopCounterTaint(loops, controlStack[:keep], pendingTaint)
			hasPendingTaint = false
		}
	}
	taintWrite := func(op byte, local uint32) {
		if op == 0x21 {
			pendingTaint, hasPendingTaint = local, true
			return
		}
		markLoopCounterTaint(loops, controlStack, local)
	}
	exitInfo, err := computeBodyExit(body)
	if err != nil {
		return functionMetrics{}, nil, err
	}
	ord := -1

	addInstr := func() {
		metrics.InstructionTotal++
		fm.InstructionTotal++
	}
	addLoop := func() int {
		metrics.LoopCount++
		fm.LoopCount++
		idx := len(loops)
		loops = append(loops, loopEvidence{index: fm.LoopCount})
		return idx
	}
	addBranch := func() {
		metrics.BranchDecision++
		fm.BranchDecision++
	}
	addBrTable := func(targets int) {
		metrics.BrTableCount++
		metrics.BrTableTargets += targets
		fm.BrTableCount++
		fm.BrTableTargets += targets
	}
	addLoopBack := func() {
		metrics.LoopBackedge++
		fm.LoopBackedge++
	}
	addCallImport := func() {
		metrics.CallImport++
		fm.CallImport++
	}
	addCallLocal := func() {
		metrics.CallLocal++
		fm.CallLocal++
	}
	addCallIndirect := func() {
		metrics.CallIndirect++
		fm.CallIndirect++
	}

	for {
		op, err := r.readByte()
		if err != nil {
			return functionMetrics{}, nil, err
		}
		ord++
		addInstr()
		instructionCounts[InstructionOpcode(op)]++
		trace := instrTrace{op: op}
		switch op {
		case 0x0c:
			// resolved below once the depth is read
		case 0x00, 0x0f:
			resolvePendingTaint(0)
		default:
			resolvePendingTaint(len(controlStack))
		}

		switch op {
		case 0x00, 0x01, opElse, 0x0f, 0x1a, 0x1b:
			// no immediate
			if op == 0x1b {
				fm.ControlFlowOps++
			}
			if op == 0x00 || op == 0x0f {
				applyArmedExits(loops, controlStack, armed)
				armed = nil
			}
			if op == opElse {
				armed = nil
			}
		case opBlock, opLoop, opIf:
			if err := readBlockType(r); err != nil {
				return functionMetrics{}, nil, err
			}
			armed = nil
			if op == opIf {
				addBranch()
				// The if body runs when the condition is true; if it leaves
				// the function before other control flow, the condition was
				// an exit test, as in: if (i >= n) return.
				armed = detectBoundCandidates(recent, false)
				// Must-exit generalizes that through nested control flow,
				// and covers the inverse edge: an else arm that exits.
				if exitInfo.mustExit[ord+1] {
					applyArmedExits(loops, controlStack, detectBoundCandidates(recent, false))
				}
				if exitInfo.elseExit[ord] {
					applyArmedExits(loops, controlStack, detectBoundCandidates(recent, true))
				}
			} else {
				fm.ControlFlowOps++
			}
			loopIdx := -1
			if op == opLoop {
				loopIdx = addLoop()
			}
			controlStack = append(controlStack, controlFrame{op: op, loopIdx: loopIdx})
		case opEnd:
			if len(controlStack) == 0 {
				if r.remaining() != 0 {
					return functionMetrics{}, nil, errors.New("trailing bytes after final end")
				}
				return fm, loopFailures, nil
			}
			frame := controlStack[len(controlStack)-1]
			controlStack = controlStack[:len(controlStack)-1]
			// A still-armed fall-through path converges with branches to this
			// frame's end, so both candidate sets stay live.
			armed = append(frame.pending, armed...)
			if frame.op == opLoop && frame.loopIdx >= 0 && frame.loopIdx < len(loops) {
				armed = nil
				loop := loops[frame.loopIdx]
				if loop.hasBackedge && !loopHasBoundedCounter(loop) {
					loopFailures = append(loopFailures, LoopBoundFailure{
						Function: funcIdx,
						Loop:     loop.index,
						Reason:   "no local counter with a matching monotonic update and exit bound",
					})
				}
			}
		case 0x0c:
			depth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(depth)
			trace.hasImm = true
			// Frames above the target are left; the target and everything
			// below it (a loop target continues) stay live.
			resolvePendingTaint(max(len(controlStack)-int(depth), 0))
			fm.ControlFlowOps++
			if isLoopTarget(controlStack, depth) {
				addLoopBack()
			}
			markBranchLoopEvidence(loops, controlStack, depth, nil, nil)
			transferArmedOnBr(loops, controlStack, depth, armed)
			armed = nil
		case 0x0d:
			depth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(depth)
			trace.hasImm = true
			addBranch()
			exitCandidates := detectBoundCandidates(recent, false)
			continueCandidates := detectBoundCandidates(recent, true)
			if isLoopTarget(controlStack, depth) {
				addLoopBack()
			}
			markBranchLoopEvidence(loops, controlStack, depth, exitCandidates, continueCandidates)
			// The fall-through path holds the inverted condition; if it
			// leaves the function, the branch skipped past an exit, as in:
			// loop { block { br_if 0 (i != n); return } ... }.
			armed = continueCandidates
			// Must-exit covers both edges through arbitrary forward flow:
			// a taken edge whose target's continuation leaves the function,
			// and a fall-through that leaves via later conditional paths.
			if exitInfo.takenExit[ord] {
				applyArmedExits(loops, controlStack, exitCandidates)
			}
			if exitInfo.mustExit[ord+1] {
				applyArmedExits(loops, controlStack, continueCandidates)
			}
		case 0x0e:
			targetCount, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(targetCount)
			trace.hasImm = true
			addBrTable(int(targetCount))
			exitCandidates := detectBoundCandidates(recent, false)
			continueCandidates := detectBoundCandidates(recent, true)
			hasLoopTarget := false
			for i := 0; i < int(targetCount); i++ {
				depth, err := r.readVarU32()
				if err != nil {
					return functionMetrics{}, nil, err
				}
				if isLoopTarget(controlStack, depth) {
					hasLoopTarget = true
				}
				markBranchLoopEvidence(loops, controlStack, depth, exitCandidates, continueCandidates)
			}
			defaultDepth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			if isLoopTarget(controlStack, defaultDepth) {
				hasLoopTarget = true
			}
			markBranchLoopEvidence(loops, controlStack, defaultDepth, exitCandidates, continueCandidates)
			if hasLoopTarget {
				addLoopBack()
			}
			armed = nil
		case 0x10, 0x12:
			idx, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(idx)
			trace.hasImm = true
			if int(idx) < importedFuncCount {
				addCallImport()
			} else {
				addCallLocal()
				callee := int(idx) - importedFuncCount
				if callee >= 0 && callee < definedFuncCount {
					if edges[funcIdx] == nil {
						edges[funcIdx] = map[int]struct{}{}
					}
					edges[funcIdx][callee] = struct{}{}
				}
			}
		case 0x11, 0x13:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			addCallIndirect()
			fm.TableOps++
		case 0x14:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			addCallIndirect()
		case 0x1c:
			count, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			if _, err := r.readN(int(count)); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26:
			idx, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(idx)
			trace.hasImm = true
			switch op {
			case 0x23:
				// global.get is the expected shape for qip contract accessor functions.
			case 0x25, 0x26:
				fm.TableOps++
			default:
				fm.LocalOps++
			}
			if op == 0x21 || op == 0x22 {
				newDerived, hasNewDerived := derivedUpdate{}, false
				if src, dir, ok := detectValueUpdate(recent); ok {
					if src == idx {
						markLoopCounterUpdate(loops, controlStack, idx, dir)
					} else {
						taintWrite(op, idx)
						newDerived, hasNewDerived = derivedUpdate{src: src, dir: dir}, true
					}
				} else if dir, weakStep, ok := detectFusedUpdate(recent, idx); ok {
					if weakStep {
						markLoopCounterWeakInc(loops, controlStack, idx)
					} else {
						markLoopCounterUpdate(loops, controlStack, idx, dir)
					}
				} else if detectNonnegLocalStep(recent, idx, smallNonneg) {
					markLoopCounterWeakInc(loops, controlStack, idx)
				} else if from, ok := copySourceLocal(recent); ok {
					if d, exists := derived[from]; exists && d.src == idx {
						markLoopCounterUpdate(loops, controlStack, idx, d.dir)
					} else if from != idx {
						taintWrite(op, idx)
					}
				} else {
					taintWrite(op, idx)
				}
				delete(derived, idx)
				if hasNewDerived {
					derived[idx] = newDerived
				}
				smallNonneg[idx] = isSmallNonnegSource(recent)
			}
		case 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
			0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
			0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e:
			if err := readMemArg(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0x3f, 0x40:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0x41:
			v, err := r.readVarS32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(v)
			trace.hasImm = true
		case 0x42:
			v, err := r.readVarS64(10)
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = v
			trace.hasImm = true
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0xd2:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0xfc:
			if err := readFCImmediate(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0xfd:
			if err := readFDImmediate(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0xfe:
			if err := readFEImmediate(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		default:
			// Most core numeric/reference ops have no immediates.
		}
		recent = appendTrace(recent, trace)
	}
}

func parseGlobalInitExpr(r *wasmReader) (globalInitMetrics, error) {
	instr := 0
	simpleConst := false
	hasGlobalGet := false
	for {
		op, err := r.readByte()
		if err != nil {
			return globalInitMetrics{}, err
		}
		if op == 0x0b {
			break
		}
		instr++
		switch op {
		case 0x41:
			if _, err := r.readVarS32(); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x42:
			if _, err := r.readVarS64(10); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return globalInitMetrics{}, err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return globalInitMetrics{}, err
			}
		case 0xd2:
			if _, err := r.readVarU32(); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x23:
			if _, err := r.readVarU32(); err != nil {
				return globalInitMetrics{}, err
			}
			hasGlobalGet = true
		default:
			return globalInitMetrics{}, fmt.Errorf("unsupported const expr opcode 0x%x", op)
		}
	}
	if instr == 1 && !hasGlobalGet {
		simpleConst = true
	}
	return globalInitMetrics{
		InstructionTotal: instr,
		SimpleConst:      simpleConst,
		HasGlobalGet:     hasGlobalGet,
	}, nil
}

func skipConstExpr(r *wasmReader) error {
	for {
		op, err := r.readByte()
		if err != nil {
			return err
		}
		if op == 0x0b {
			return nil
		}
		switch op {
		case 0x41:
			if _, err := r.readVarS32(); err != nil {
				return err
			}
		case 0x42:
			if _, err := r.readVarS64(10); err != nil {
				return err
			}
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return err
			}
		case 0xd2, 0x23:
			if _, err := r.readVarU32(); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unsupported const expr opcode 0x%x", op)
		}
	}
}

func readBlockType(r *wasmReader) error {
	b, err := r.peekByte()
	if err != nil {
		return err
	}
	switch b {
	case 0x40, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f:
		_, err := r.readByte()
		return err
	default:
		_, err := r.readVarS64(5)
		return err
	}
}

func readMemArg(r *wasmReader) error {
	if _, err := r.readVarU32(); err != nil {
		return err
	}
	if _, err := r.readVarU32(); err != nil {
		return err
	}
	return nil
}

func readFCImmediate(r *wasmReader) error {
	sub, err := r.readVarU32()
	if err != nil {
		return err
	}
	switch sub {
	case 8: // memory.init
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 9: // data.drop
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 10: // memory.copy
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 11: // memory.fill
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 12: // table.init
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 13: // elem.drop
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 14: // table.copy
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 15, 16, 17: // table.grow/size/fill
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	default:
		// Other FC opcodes used by current modules have no immediates.
	}
	return nil
}

func readFDImmediate(r *wasmReader) error {
	sub, err := r.readVarU32()
	if err != nil {
		return err
	}
	switch {
	case sub <= 11:
		return readMemArg(r)
	case sub == 12:
		_, err := r.readN(16)
		return err
	case sub == 13:
		_, err := r.readN(16)
		return err
	case sub >= 21 && sub <= 34:
		_, err := r.readByte()
		return err
	case sub >= 84 && sub <= 91:
		if err := readMemArg(r); err != nil {
			return err
		}
		_, err := r.readByte()
		return err
	case sub == 92 || sub == 93:
		return readMemArg(r)
	default:
		// Remaining SIMD ops in active use have no immediates.
		return nil
	}
}

func readFEImmediate(r *wasmReader) error {
	sub, err := r.readVarU32()
	if err != nil {
		return err
	}
	if sub == 3 {
		_, err := r.readByte() // atomic.fence reserved immediate
		return err
	}
	return readMemArg(r)
}

func markBranchLoopEvidence(loops []loopEvidence, controlStack []controlFrame, depth uint32, exitCandidates []boundCandidate, continueCandidates []boundCandidate) {
	d := int(depth)
	if d < 0 || d >= len(controlStack) {
		// A branch to the implicit function label is a conditional return,
		// exiting every open loop.
		if d == len(controlStack) {
			applyArmedExits(loops, controlStack, exitCandidates)
		}
		return
	}
	targetIndex := len(controlStack) - 1 - d
	target := controlStack[targetIndex]
	if target.op == 0x03 {
		if target.loopIdx >= 0 && target.loopIdx < len(loops) {
			loop := &loops[target.loopIdx]
			loop.hasBackedge = true
			for _, candidate := range continueCandidates {
				markLoopCounterExit(loop, candidate)
			}
		}
		return
	}
	for i := len(controlStack) - 1; i > targetIndex; i-- {
		frame := controlStack[i]
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		for _, candidate := range exitCandidates {
			markLoopCounterExit(loop, candidate)
		}
	}
	controlStack[targetIndex].pending = append(controlStack[targetIndex].pending, exitCandidates...)
}

func applyArmedExits(loops []loopEvidence, controlStack []controlFrame, candidates []boundCandidate) {
	if len(candidates) == 0 {
		return
	}
	for _, frame := range controlStack {
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		for _, candidate := range candidates {
			markLoopCounterExit(loop, candidate)
		}
	}
}

// transferArmedOnBr follows an unconditional branch taken while armed exit
// candidates are live. Loops the branch crosses are exited by the armed
// path; a forward target inherits the candidates so multi-hop exit ladders
// (block end, br out, another block end, return) keep their evidence.
func transferArmedOnBr(loops []loopEvidence, controlStack []controlFrame, depth uint32, armed []boundCandidate) {
	if len(armed) == 0 {
		return
	}
	d := int(depth)
	if d >= len(controlStack) {
		applyArmedExits(loops, controlStack, armed)
		return
	}
	targetIndex := len(controlStack) - 1 - d
	for i := len(controlStack) - 1; i > targetIndex; i-- {
		frame := controlStack[i]
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		for _, candidate := range armed {
			markLoopCounterExit(loop, candidate)
		}
	}
	if controlStack[targetIndex].op != 0x03 {
		controlStack[targetIndex].pending = append(controlStack[targetIndex].pending, armed...)
	}
}

func isLoopTarget(controlStack []controlFrame, depth uint32) bool {
	d := int(depth)
	if d < 0 || d >= len(controlStack) {
		return false
	}
	target := controlStack[len(controlStack)-1-d]
	return target.op == 0x03
}

func parseLimits(r *wasmReader) (memoryLimit, error) {
	flags, err := r.readByte()
	if err != nil {
		return memoryLimit{}, err
	}
	isMemory64 := (flags & 0x04) != 0
	if isMemory64 {
		min, err := r.readVarU64()
		if err != nil {
			return memoryLimit{}, err
		}
		limit := memoryLimit{
			Memory64: true,
			MinPages: min,
		}
		if (flags & 0x01) != 0 {
			max, err := r.readVarU64()
			if err != nil {
				return memoryLimit{}, err
			}
			limit.HasMax = true
			limit.MaxPages = max
		}
		return limit, nil
	}
	min32, err := r.readVarU32()
	if err != nil {
		return memoryLimit{}, err
	}
	limit := memoryLimit{MinPages: uint64(min32)}
	if (flags & 0x01) != 0 {
		max, err := r.readVarU32()
		if err != nil {
			return memoryLimit{}, err
		}
		limit.HasMax = true
		limit.MaxPages = uint64(max)
	}
	return limit, nil
}

func parseLimitsMin(r *wasmReader) (uint64, error) {
	limit, err := parseLimits(r)
	if err != nil {
		return 0, err
	}
	return limit.MinPages, nil
}

func skipLimits(r *wasmReader) error {
	_, err := parseLimitsMin(r)
	if err != nil {
		return err
	}
	return nil
}

func skipTableType(r *wasmReader) error {
	if _, err := r.readByte(); err != nil {
		return err
	}
	return skipLimits(r)
}

func skipGlobalType(r *wasmReader) error {
	if _, err := r.readByte(); err != nil {
		return err
	}
	if _, err := r.readByte(); err != nil {
		return err
	}
	return nil
}

func detectCallCycle(edges []map[int]struct{}) (bool, []int) {
	n := len(edges)
	if n == 0 {
		return false, nil
	}
	state := make([]uint8, n)
	stack := make([]int, 0, n)

	var cycle []int
	var visit func(int) bool
	visit = func(v int) bool {
		state[v] = 1
		stack = append(stack, v)

		for to := range edges[v] {
			if state[to] == 0 {
				if visit(to) {
					return true
				}
				continue
			}
			if state[to] == 1 {
				start := 0
				for i := len(stack) - 1; i >= 0; i-- {
					if stack[i] == to {
						start = i
						break
					}
				}
				cycle = append([]int(nil), stack[start:]...)
				return true
			}
		}

		stack = stack[:len(stack)-1]
		state[v] = 2
		return false
	}

	for i := range n {
		if state[i] == 0 {
			if visit(i) {
				return true, cycle
			}
		}
	}
	return false, nil
}
