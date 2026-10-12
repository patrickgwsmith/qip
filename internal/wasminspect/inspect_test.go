package wasminspect

import (
	"strings"
	"testing"
)

func TestAnalyzeModuleCountsAndNoCycle(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		FunctionBodies: [][]byte{
			{
				0x03, 0x40, // loop
				0x0d, 0x00, // br_if 0 (backedge)
				0x0b,       // end loop
				0x04, 0x40, // if
				0x0b,       // end if
				0x02, 0x40, // block
				0x41, 0x00, // i32.const 0
				0x0e, 0x02, 0x00, 0x00, 0x00, // br_table [0,0] default 0
				0x0b,       // end block
				0x10, 0x00, // call import (global idx 0)
				0x10, 0x02, // call local (global idx 2)
				0x11, 0x00, 0x00, // call_indirect type 0 table 0
				0x0b, // end function
			},
			{0x0b}, // end function
		},
		WithTable: true,
	})

	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	if analysis.ImportedFuncCount != 1 {
		t.Fatalf("importedFuncCount=%d, want 1", analysis.ImportedFuncCount)
	}
	if analysis.Metrics.BranchDecision != 2 {
		t.Fatalf("branch decisions=%d, want 2", analysis.Metrics.BranchDecision)
	}
	if analysis.Metrics.BrTableCount != 1 || analysis.Metrics.BrTableTargets != 2 {
		t.Fatalf("br_table count/targets=%d/%d, want 1/2", analysis.Metrics.BrTableCount, analysis.Metrics.BrTableTargets)
	}
	if analysis.Metrics.CallImport != 1 || analysis.Metrics.CallLocal != 1 || analysis.Metrics.CallIndirect != 1 {
		t.Fatalf("calls import/local/indirect=%d/%d/%d, want 1/1/1", analysis.Metrics.CallImport, analysis.Metrics.CallLocal, analysis.Metrics.CallIndirect)
	}
	if analysis.Metrics.LoopBackedge != 1 {
		t.Fatalf("loop_backedge=%d, want 1", analysis.Metrics.LoopBackedge)
	}
	if analysis.Metrics.InstructionTotal != 14 {
		t.Fatalf("instruction total=%d, want 14", analysis.Metrics.InstructionTotal)
	}

	hasCycle, _ := DetectCallCycle(analysis.CallEdges)
	if hasCycle {
		t.Fatalf("unexpected recursion cycle")
	}
}

func TestDetectCallCycle(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		FunctionBodies: [][]byte{
			{0x10, 0x01, 0x0b}, // func 0 calls func 1
			{0x10, 0x00, 0x0b}, // func 1 calls func 0
		},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	hasCycle, cycle := DetectCallCycle(analysis.CallEdges)
	if !hasCycle {
		t.Fatalf("expected recursion cycle")
	}
	if len(cycle) != 2 {
		t.Fatalf("cycle=%v, want 2 nodes", cycle)
	}
}

func TestEvaluateQIPContractChecksFailDynamicFunction(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		FunctionBodies:  [][]byte{{0x10, 0x00, 0x0b}}, // call import
		Exports: []testExport{
			{Name: "input_ptr", Kind: 0x00, Index: 1},
		},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	checks, fail := EvaluateQIPContractChecks(analysis)
	if !fail {
		t.Fatalf("expected contract failure")
	}
	if len(checks) != 1 {
		t.Fatalf("checks=%d, want 1", len(checks))
	}
	if checks[0].Pass || checks[0].Export != "input_ptr" || checks[0].Kind != "func" {
		t.Fatalf("unexpected check result: %+v", checks[0])
	}
}

func TestEvaluateQIPContractChecksPassGlobalGetFunction(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Globals: []testGlobal{
			{ValueType: 0x7f, InitExpr: []byte{0x41, 0x80, 0x80, 0x40}}, // i32.const 1048576
		},
		FunctionBodies: [][]byte{{0x23, 0x00, 0x0b}}, // global.get 0
		Exports: []testExport{
			{Name: "input_ptr", Kind: 0x00, Index: 0},
		},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	checks, fail := EvaluateQIPContractChecks(analysis)
	if fail {
		t.Fatalf("unexpected contract failure: %+v", checks)
	}
	if len(checks) != 1 {
		t.Fatalf("checks=%d, want 1", len(checks))
	}
	if !checks[0].Pass || checks[0].Export != "input_ptr" || checks[0].Kind != "func" {
		t.Fatalf("unexpected check result: %+v", checks[0])
	}
}

func TestEvaluateQIPContractChecksRejectConstantGlobal(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Globals: []testGlobal{
			{ValueType: 0x7f, InitExpr: []byte{0x41, 0x80, 0x80, 0x40}}, // i32.const 1048576
		},
		Exports: []testExport{{Name: "input_ptr", Kind: 0x03, Index: 0}},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	checks, fail := EvaluateQIPContractChecks(analysis)
	if !fail {
		t.Fatalf("expected contract failure: %+v", checks)
	}
	if len(checks) != 1 {
		t.Fatalf("checks=%d, want 1", len(checks))
	}
	if checks[0].Pass || checks[0].Kind != "global" || checks[0].Reason != "must be function" {
		t.Fatalf("unexpected check result: %+v", checks[0])
	}
}

func TestValidateModulePolicyRejectsMemoryGrow(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Memories: []testMemory{{MinPages: 1, HasMax: true, MaxPages: 1}},
		FunctionBodies: [][]byte{
			{
				0x41, 0x01, // i32.const 1
				0x40, 0x00, // memory.grow 0
				0x1a, // drop
				0x0b, // end function
			},
		},
	})

	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	if got := analysis.InstructionCounts[OpcodeMemoryGrow]; got != 1 {
		t.Fatalf("memory.grow count=%d, want 1", got)
	}

	err = ValidateModulePolicy(module, ModulePolicy{RejectOpcodes: []InstructionOpcode{OpcodeMemoryGrow}})
	if err == nil {
		t.Fatalf("expected policy rejection")
	}
	if !strings.Contains(err.Error(), "violates fixed-memory policy") {
		t.Fatalf("error=%q, want memory.grow rejection", err.Error())
	}
}

func TestValidateStraightLineComplyOracleAcceptsOracleCalls(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		Memories:        []testMemory{{MinPages: 1, HasMax: true, MaxPages: 1}},
		FunctionBodies: [][]byte{{
			0x42, 0x00, // i64.const ordinal
			0x41, 0x00, // i32.const input pointer
			0x41, 0x00, // i32.const input length
			0x41, 0x00, // i32.const expected pointer
			0x41, 0x00, // i32.const expected length
			0x10, 0x00, // call imported oracle
			0x1a,       // drop oracle result
			0x41, 0x01, // i32.const declared count
			0x0b, // end function
		}},
		Exports: []testExport{
			{Name: "memory", Kind: 0x02, Index: 0},
			{Name: "comply", Kind: 0x00, Index: 1},
		},
	})

	if err := ValidateStraightLineComplyOracle(module); err != nil {
		t.Fatalf("ValidateStraightLineComplyOracle: %v", err)
	}
}

func TestValidateStraightLineComplyOracleRejectsConditionalInstructions(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		Memories:        []testMemory{{MinPages: 1, HasMax: true, MaxPages: 1}},
		FunctionBodies: [][]byte{{
			0x41, 0x01, // i32.const true
			0x04, 0x40, // if
			0x0b,       // end if
			0x41, 0x00, // i32.const declared count
			0x0b, // end function
		}},
		Exports: []testExport{
			{Name: "memory", Kind: 0x02, Index: 0},
			{Name: "comply", Kind: 0x00, Index: 1},
		},
	})

	err := ValidateStraightLineComplyOracle(module)
	if err == nil {
		t.Fatal("expected strict profile rejection")
	}
	if !strings.Contains(err.Error(), "contains if (1)") {
		t.Fatalf("error=%q, want if rejection", err)
	}
}

func TestValidateStraightLineComplyOracleRejectsHelperFunctions(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		Memories:        []testMemory{{MinPages: 1, HasMax: true, MaxPages: 1}},
		FunctionBodies: [][]byte{
			{0x10, 0x02, 0x41, 0x00, 0x0b}, // comply calls local helper
			{0x0b},
		},
		Exports: []testExport{
			{Name: "memory", Kind: 0x02, Index: 0},
			{Name: "comply", Kind: 0x00, Index: 1},
		},
	})

	err := ValidateStraightLineComplyOracle(module)
	if err == nil {
		t.Fatal("expected strict profile rejection")
	}
	if !strings.Contains(err.Error(), "defines 2 functions") || !strings.Contains(err.Error(), "local calls") {
		t.Fatalf("error=%q, want helper-function rejection", err)
	}
}

func TestValidateModulePolicyMaxMemory(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Memories:       []testMemory{{MinPages: 1, HasMax: true, MaxPages: 2}},
		FunctionBodies: [][]byte{{0x0b}},
	})

	if err := ValidateModulePolicy(module, ModulePolicy{MaxMemoryBytes: 2 * WasmPageSizeBytes}); err != nil {
		t.Fatalf("ValidateModulePolicy within max: %v", err)
	}
	err := ValidateModulePolicy(module, ModulePolicy{MaxMemoryBytes: WasmPageSizeBytes})
	if err == nil {
		t.Fatalf("expected max-memory rejection")
	}
	if !strings.Contains(err.Error(), "maximum 2 pages exceeds") {
		t.Fatalf("error=%q, want max-memory rejection", err.Error())
	}
}

func TestValidateModulePolicyRejectsMemoryWithoutDeclaredMax(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Memories:       []testMemory{{MinPages: 1}},
		FunctionBodies: [][]byte{{0x0b}},
	})

	err := ValidateModulePolicy(module, ModulePolicy{MaxMemoryBytes: 2 * WasmPageSizeBytes})
	if err == nil {
		t.Fatalf("expected no-max rejection")
	}
	if !strings.Contains(err.Error(), "has no declared maximum") {
		t.Fatalf("error=%q, want missing max rejection", err.Error())
	}
}

func TestValidateModulePolicyAcceptsBoundedCounterLoop(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		FunctionBodies: [][]byte{{
			0x41, 0x00, // i32.const 0
			0x21, 0x00, // local.set 0
			0x02, 0x40, // block
			0x03, 0x40, // loop
			0x20, 0x00, // local.get 0
			0x41, 0x0a, // i32.const 10
			0x4f,       // i32.ge_u
			0x0d, 0x01, // br_if 1 (exit block)
			0x20, 0x00, // local.get 0
			0x41, 0x01, // i32.const 1
			0x6a,       // i32.add
			0x21, 0x00, // local.set 0
			0x0c, 0x00, // br 0 (backedge)
			0x0b, // end loop
			0x0b, // end block
			0x0b, // end function
		}},
	})

	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	if len(analysis.LoopBoundFailures) != 0 {
		t.Fatalf("unexpected loop bound failures: %+v", analysis.LoopBoundFailures)
	}
	if err := ValidateModulePolicy(module, ModulePolicy{RequireBoundedLoops: true}); err != nil {
		t.Fatalf("ValidateModulePolicy bounded loop: %v", err)
	}
}

func TestLoopBoundAcceptsSignedCompare(t *testing.T) {
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, // local.get 0
		0x41, 0x0a, // i32.const 10
		0x4e,       // i32.ge_s
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsI64Counter(t *testing.T) {
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, // local.get 0
		0x42, 0xe4, 0x00, // i64.const 100
		0x5a,       // i64.ge_u
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x42, 0x01, 0x7c, 0x21, 0x00, // local 0 += 1 (i64)
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsDivShrink(t *testing.T) {
	// itoa shape: x = x / 10 until x == 0
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, // local.get 0
		0x45,       // i32.eqz
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x0a, 0x6e, 0x21, 0x00, // local 0 = local 0 / 10
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsCopyChainUpdate(t *testing.T) {
	// temp := x / 10 ... x := temp closes the update on x
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, // local.get 0
		0x45,       // i32.eqz
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x0a, 0x6e, // local.get 0; i32.const 10; i32.div_u
		0x22, 0x01, // local.tee 1
		0x1a,       // drop
		0x20, 0x01, // local.get 1
		0x21, 0x00, // local.set 0
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsExitViaReturn(t *testing.T) {
	// br_if to a block whose end path returns out of the function
	assertLoopBoundFailures(t, 0, []byte{
		0x03, 0x40, // loop
		0x02, 0x40, // block
		0x20, 0x00, // local.get 0
		0x41, 0x0a, // i32.const 10
		0x46,       // i32.eq
		0x0d, 0x00, // br_if 0 (to block end)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x01, // br 1 (backedge)
		0x0b, // end block
		0x0f, // return
		0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsExpressionOperand(t *testing.T) {
	// exit when local0 + 4 > local1
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, 0x41, 0x04, 0x6a, // local.get 0; i32.const 4; i32.add
		0x20, 0x01, // local.get 1
		0x4b,       // i32.gt_u
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x04, 0x6a, 0x21, 0x00, // local 0 += 4
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsOneSidedCompare(t *testing.T) {
	// exit when load8(local2) < local0; counter local0 += 1
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x02, // local.get 2
		0x2d, 0x00, 0x00, // i32.load8_u
		0x20, 0x00, // local.get 0
		0x49,       // i32.lt_u
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundRejectsTaintedCounter(t *testing.T) {
	// local 0 has a recognized increment but also an unrecognized reset
	assertLoopBoundFailures(t, 1, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, // local.get 0
		0x41, 0x0a, // i32.const 10
		0x4f,       // i32.ge_u
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x41, 0x00, 0x21, 0x00, // local 0 = 0
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsWriteOnExitPath(t *testing.T) {
	// LLVM's scan shape: on exit, copy the bound into the counter (i = n)
	// and br out. The copy can't reach another iteration.
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x02, 0x40, // block
		0x20, 0x01, 0x20, 0x00, 0x47, // local 1 != local 0
		0x0d, 0x00, // br_if 0 (keep scanning)
		0x20, 0x01, 0x21, 0x00, // local 0 = local 1
		0x0c, 0x02, // br 2 (leave the loop)
		0x0b,                                     // end block
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundRejectsWriteBeforeBackedge(t *testing.T) {
	// Same shape, but the br after the copy continues the loop.
	assertLoopBoundFailures(t, 1, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x02, 0x40, // block
		0x20, 0x01, 0x20, 0x00, 0x47, // local 1 != local 0
		0x0d, 0x00, // br_if 0
		0x41, 0x00, 0x21, 0x00, // local 0 = 0
		0x0c, 0x01, // br 1 (backedge)
		0x0b,                                     // end block
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundRejectsExitPathWriteToOuterCounter(t *testing.T) {
	// The br leaves the inner loop only, so resetting the outer loop's
	// counter there still taints the outer loop.
	assertLoopBoundFailures(t, 1, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop (outer)
		0x20, 0x02, 0x41, 0x0a, 0x4f, // local 2 >= 10
		0x0d, 0x01, // br_if 1 (exit)
		0x02, 0x40, // block
		0x03, 0x40, // loop (inner)
		0x20, 0x00, 0x20, 0x01, 0x4f, // local 0 >= local 1
		0x0d, 0x01, // br_if 1 (exit inner)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x41, 0x00, 0x21, 0x02, // local 2 = 0
		0x0c, 0x01, // br 1 (leave inner only)
		0x0b, 0x0b, // end inner loop, block
		0x20, 0x02, 0x41, 0x01, 0x6a, 0x21, 0x02, // local 2 += 1
		0x0c, 0x00, // br 0 (outer backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsGlobalBound(t *testing.T) {
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, // local.get 0
		0x23, 0x00, // global.get 0
		0x4f,       // i32.ge_u
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsConditionalReturnBranch(t *testing.T) {
	// br_if to the implicit function label is a conditional return
	assertLoopBoundFailures(t, 0, []byte{
		0x03, 0x40, // loop
		0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
		0x0d, 0x01, // br_if 1 (function label)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsArmedExitThroughBr(t *testing.T) {
	// br_if to inner block end, then unconditional br crossing the loop
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block (outer)
		0x03, 0x40, // loop
		0x02, 0x40, // block (inner)
		0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
		0x0d, 0x00, // br_if 0 (to inner block end)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x01, // br 1 (backedge)
		0x0b,       // end inner block
		0x0c, 0x01, // br 1 (crosses loop to outer block end)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsIfReturnExit(t *testing.T) {
	// if (i >= n) with a body that returns
	assertLoopBoundFailures(t, 0, []byte{
		0x03, 0x40, // loop
		0x20, 0x00, 0x41, 0x0a, 0x4f, // local0 >= 10
		0x04, 0x40, // if
		0x0f,                                     // return
		0x0b,                                     // end if
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsBrIfSkippingReturn(t *testing.T) {
	// br_if past a return: the exit fires when the condition is false
	assertLoopBoundFailures(t, 0, []byte{
		0x03, 0x40, // loop
		0x02, 0x40, // block
		0x20, 0x00, 0x41, 0x0a, 0x47, // local0 != 10
		0x0d, 0x00, // br_if 0 (skip the return)
		0x0f,                                     // return
		0x0b,                                     // end block
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsNonnegStride(t *testing.T) {
	// i += load8(p) is a weak increase; the strict i += 1 keeps it monotonic
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x02, 0x2d, 0x00, 0x00, 0x21, 0x03, // local3 = load8_u(local2)
		0x20, 0x00, 0x20, 0x03, 0x6a, 0x21, 0x00, // local0 += local3
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local0 += 1
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundRejectsNonnegStrideAlone(t *testing.T) {
	// without a strict update the weak stride cannot prove progress
	assertLoopBoundFailures(t, 1, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x02, 0x2d, 0x00, 0x00, 0x21, 0x03, // local3 = load8_u(local2)
		0x20, 0x00, 0x20, 0x03, 0x6a, 0x21, 0x00, // local0 += local3
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsFusedStride(t *testing.T) {
	// i = i + load8(i) + 1 fused into one add chain, as LLVM emits
	assertLoopBoundFailures(t, 0, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, // local.get 0
		0x20, 0x00, 0x2d, 0x00, 0x00, // load8_u(local0)
		0x6a,       // i32.add
		0x41, 0x01, // i32.const 1
		0x6a,       // i32.add
		0x21, 0x00, // local.set 0
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundRejectsFusedWeakAlone(t *testing.T) {
	// i = i + load8(i) with no strict component cannot prove progress
	assertLoopBoundFailures(t, 1, []byte{
		0x02, 0x40, // block
		0x03, 0x40, // loop
		0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
		0x0d, 0x01, // br_if 1 (exit)
		0x20, 0x00, // local.get 0
		0x20, 0x00, 0x2d, 0x00, 0x00, // load8_u(local0)
		0x6a,       // i32.add
		0x21, 0x00, // local.set 0
		0x0c, 0x00, // br 0 (backedge)
		0x0b, 0x0b, 0x0b,
	})
}

func TestLoopBoundAcceptsMustExitLadder(t *testing.T) {
	// br_if to a block whose end path exits on every branch of a following
	// if: only must-exit analysis can see through the conditional.
	assertLoopBoundFailures(t, 0, []byte{
		0x03, 0x40, // loop
		0x02, 0x40, // block
		0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
		0x0d, 0x00, // br_if 0 (to block end)
		0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local0 += 1
		0x0c, 0x01, // br 1 (backedge)
		0x0b,       // end block
		0x20, 0x01, // local.get 1
		0x04, 0x40, // if
		0x0f, // return
		0x0b, // end if
		0x0f, // return
		0x0b, 0x0b,
	})
}

func assertLoopBoundFailures(t *testing.T, want int, body []byte) {
	t.Helper()
	module := buildTestModule(testModuleConfig{FunctionBodies: [][]byte{body}})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	if len(analysis.LoopBoundFailures) != want {
		t.Fatalf("loop bound failures=%+v, want %d", analysis.LoopBoundFailures, want)
	}
}

func TestValidateModulePolicyRejectsUnboundedLoop(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		FunctionBodies: [][]byte{{
			0x03, 0x40, // loop
			0x0c, 0x00, // br 0 (backedge)
			0x0b, // end loop
			0x0b, // end function
		}},
	})

	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	if len(analysis.LoopBoundFailures) != 1 {
		t.Fatalf("loop bound failures=%+v, want 1", analysis.LoopBoundFailures)
	}
	err = ValidateModulePolicy(module, ModulePolicy{RequireBoundedLoops: true})
	if err == nil {
		t.Fatalf("expected bounded-loop policy rejection")
	}
	if !strings.Contains(err.Error(), "loop bound not proven") {
		t.Fatalf("error=%q, want loop bound rejection", err.Error())
	}
}

func TestAnalyzeModuleParsesCurrentBulkMemoryAndSIMDImmediates(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Memories: []testMemory{{MinPages: 1, HasMax: true, MaxPages: 1}},
		FunctionBodies: [][]byte{
			{
				0xfc, 0x0a, 0x00, 0x00, // memory.copy 0 0
				0xfc, 0x0b, 0x00, // memory.fill 0
				0xfd, 0x56, 0x00, 0x00, 0x01, // v128.load32_lane align=0 offset=0 lane=1
				0xfd, 0x5a, 0x00, 0x00, 0x02, // v128.store32_lane align=0 offset=0 lane=2
				0xfd, 0x5c, 0x00, 0x00, // v128.load32_zero align=0 offset=0
				0x0b, // end function
			},
		},
	})

	if _, err := AnalyzeModule(module); err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
}

type testModuleConfig struct {
	ImportFuncCount   int
	ImportGlobalCount int
	FunctionBodies    [][]byte
	WithTable         bool
	Memories          []testMemory
	Globals           []testGlobal
	Exports           []testExport
	StartFunc         *uint32
}

type testMemory struct {
	MinPages uint32
	HasMax   bool
	MaxPages uint32
}

type testGlobal struct {
	ValueType byte
	Mutable   bool
	InitExpr  []byte // without trailing end (0x0b)
}

type testExport struct {
	Name  string
	Kind  byte
	Index uint32
}

func buildTestModule(cfg testModuleConfig) []byte {
	typeEntry := []byte{0x60, 0x00, 0x00} // () -> ()
	typeSecPayload := append(encodeU32(1), typeEntry...)
	typeSec := makeSection(1, typeSecPayload)

	importEntries := make([][]byte, 0, cfg.ImportFuncCount+cfg.ImportGlobalCount)
	for i := 0; i < cfg.ImportFuncCount; i++ {
		entry := []byte{}
		entry = append(entry, encodeName("env")...)
		entry = append(entry, encodeName("imp"+strconvI(i))...)
		entry = append(entry, 0x00)            // import kind func
		entry = append(entry, encodeU32(0)...) // typeidx 0
		importEntries = append(importEntries, entry)
	}
	for i := 0; i < cfg.ImportGlobalCount; i++ {
		entry := []byte{}
		entry = append(entry, encodeName("env")...)
		entry = append(entry, encodeName("gimp"+strconvI(i))...)
		entry = append(entry, 0x03) // import kind global
		entry = append(entry, 0x7f) // i32
		entry = append(entry, 0x00) // immutable
		importEntries = append(importEntries, entry)
	}
	importSec := []byte{}
	if len(importEntries) > 0 {
		payload := append(encodeU32(uint32(len(importEntries))), joinBytes(importEntries...)...)
		importSec = makeSection(2, payload)
	}

	functionTypeIdx := make([]byte, 0, len(cfg.FunctionBodies)*2)
	functionTypeIdx = append(functionTypeIdx, encodeU32(uint32(len(cfg.FunctionBodies)))...)
	for range cfg.FunctionBodies {
		functionTypeIdx = append(functionTypeIdx, 0x00) // typeidx 0
	}
	functionSec := makeSection(3, functionTypeIdx)

	tableSec := []byte{}
	if cfg.WithTable {
		payload := []byte{}
		payload = append(payload, encodeU32(1)...) // one table
		payload = append(payload, 0x70)            // funcref
		payload = append(payload, 0x00)            // min only
		payload = append(payload, encodeU32(1)...) // min=1
		tableSec = makeSection(4, payload)
	}

	memorySec := []byte{}
	if len(cfg.Memories) > 0 {
		payload := []byte{}
		payload = append(payload, encodeU32(uint32(len(cfg.Memories)))...)
		for _, m := range cfg.Memories {
			if m.HasMax {
				payload = append(payload, 0x01)
				payload = append(payload, encodeU32(m.MinPages)...)
				payload = append(payload, encodeU32(m.MaxPages)...)
			} else {
				payload = append(payload, 0x00)
				payload = append(payload, encodeU32(m.MinPages)...)
			}
		}
		memorySec = makeSection(5, payload)
	}

	globalSec := []byte{}
	if len(cfg.Globals) > 0 {
		payload := []byte{}
		payload = append(payload, encodeU32(uint32(len(cfg.Globals)))...)
		for _, g := range cfg.Globals {
			payload = append(payload, g.ValueType)
			if g.Mutable {
				payload = append(payload, 0x01)
			} else {
				payload = append(payload, 0x00)
			}
			payload = append(payload, g.InitExpr...)
			payload = append(payload, 0x0b) // end const expr
		}
		globalSec = makeSection(6, payload)
	}

	exportSec := []byte{}
	if len(cfg.Exports) > 0 {
		payload := []byte{}
		payload = append(payload, encodeU32(uint32(len(cfg.Exports)))...)
		for _, e := range cfg.Exports {
			payload = append(payload, encodeName(e.Name)...)
			payload = append(payload, e.Kind)
			payload = append(payload, encodeU32(e.Index)...)
		}
		exportSec = makeSection(7, payload)
	}

	startSec := []byte{}
	if cfg.StartFunc != nil {
		startSec = makeSection(8, encodeU32(*cfg.StartFunc))
	}

	codePayload := []byte{}
	codePayload = append(codePayload, encodeU32(uint32(len(cfg.FunctionBodies)))...)
	for _, ops := range cfg.FunctionBodies {
		body := []byte{0x00} // local decl count
		body = append(body, ops...)
		codePayload = append(codePayload, encodeU32(uint32(len(body)))...)
		codePayload = append(codePayload, body...)
	}
	codeSec := makeSection(10, codePayload)

	module := []byte{0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00}
	module = append(module, typeSec...)
	module = append(module, importSec...)
	module = append(module, functionSec...)
	module = append(module, tableSec...)
	module = append(module, memorySec...)
	module = append(module, globalSec...)
	module = append(module, exportSec...)
	module = append(module, startSec...)
	module = append(module, codeSec...)
	return module
}

func makeSection(id byte, payload []byte) []byte {
	out := []byte{id}
	out = append(out, encodeU32(uint32(len(payload)))...)
	out = append(out, payload...)
	return out
}

func encodeName(s string) []byte {
	out := encodeU32(uint32(len(s)))
	out = append(out, []byte(s)...)
	return out
}

func encodeU32(v uint32) []byte {
	if v == 0 {
		return []byte{0x00}
	}
	out := make([]byte, 0, 5)
	for v > 0 {
		b := byte(v & 0x7f)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		out = append(out, b)
	}
	return out
}

func joinBytes(parts ...[]byte) []byte {
	total := 0
	for _, p := range parts {
		total += len(p)
	}
	out := make([]byte, 0, total)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func strconvI(v int) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	buf := make([]byte, 0, 12)
	for v > 0 {
		d := byte(v % 10)
		buf = append([]byte{'0' + d}, buf...)
		v /= 10
	}
	if neg {
		buf = append([]byte{'-'}, buf...)
	}
	return string(buf)
}
