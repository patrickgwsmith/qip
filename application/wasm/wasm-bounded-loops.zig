//! wasm-bounded-loops: a QIP component that proves every loop with a
//! backedge has a fixed bound. This is the flow-analysis half of the strict
//! tier; the factual profile rules (imports, memory, banned instructions,
//! recursion) live in wasm-strict-profile. Run both for the full strict
//! tier:
//!
//!   qip run -i m.wasm -- wasm-strict-profile.wasm wasm-bounded-loops.wasm
//!
//! A loop bound is proven from evidence in the spirit of the eBPF verifier:
//! some local must have every write inside the loop be a recognized monotonic
//! step (add/sub of a constant, a magnitude shrink such as div by a constant
//! or shr_u, either step through a temp local, or a non-negative narrow
//! extra step beside a strict increase), all in one direction, plus an exit
//! comparison in the matching direction. Exit evidence comes from branches
//! that leave the loop, branches back to the loop header, conditional
//! returns, and branches to a block whose end path leaves the function.
//!
//! Input is a wasm module; output is the same bytes when every loop is
//! proven; `render` rejects otherwise. Run `qip score` for per-loop
//! diagnostics. The analysis mirrors `internal/wasminspect` in the Go CLI;
//! keep the two in sync. See docs/provable-loops.md for how to write code
//! that passes.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_CONTROL_DEPTH: usize = 4096;
const MAX_LOOP_EVIDENCE: usize = 4096;
const MAX_LOOP_COUNTERS: usize = 16384;
const MAX_RECENT_INSTR: usize = 8;
const MAX_TRACKED_LOCALS: usize = 512;
const MAX_PENDING: usize = 8;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

var loop_has_backedge_buf: [MAX_LOOP_EVIDENCE]bool = undefined;
var loop_counter_head_buf: [MAX_LOOP_EVIDENCE]i32 = undefined;
var loop_counter_local_buf: [MAX_LOOP_COUNTERS]u32 = undefined;
var loop_counter_update_buf: [MAX_LOOP_COUNTERS]u8 = undefined;
var loop_counter_exit_buf: [MAX_LOOP_COUNTERS]u8 = undefined;
var loop_counter_next_buf: [MAX_LOOP_COUNTERS]i32 = undefined;
var loop_count_current: usize = 0;
var loop_counter_count: usize = 0;
var derived_active_buf: [MAX_TRACKED_LOCALS]bool = undefined;
var derived_src_buf: [MAX_TRACKED_LOCALS]u32 = undefined;
var derived_dir_buf: [MAX_TRACKED_LOCALS]u8 = undefined;
var small_nonneg_buf: [MAX_TRACKED_LOCALS]bool = undefined;
var control_stack_buf: [MAX_CONTROL_DEPTH]ControlFrame = undefined;

// Must-exit prepass state. mustExit[i] means every path from instruction
// ordinal i leaves the function; computed backward per body, then queried
// by the analysis pass. Functions above MAX_BODY_INSTRS degrade gracefully:
// pre_valid stays false and no must-exit evidence is credited.
const MAX_BODY_INSTRS: usize = 262144;
const AUX_BACKEDGE: i32 = -1;
const AUX_FUNC_LABEL: i32 = -2;
var pre_op_buf: [MAX_BODY_INSTRS]u8 = undefined;
var pre_aux_buf: [MAX_BODY_INSTRS]i32 = undefined;
var pre_else_cont_buf: [MAX_BODY_INSTRS]i32 = undefined;
var pre_site_next_buf: [MAX_BODY_INSTRS]i32 = undefined;
var must_exit_buf: [MAX_BODY_INSTRS + 1]bool = undefined;
var taken_exit_buf: [MAX_BODY_INSTRS]bool = undefined;
var else_exit_buf: [MAX_BODY_INSTRS]bool = undefined;
var pre_frame_is_loop: [MAX_CONTROL_DEPTH]bool = undefined;
var pre_frame_if_ord: [MAX_CONTROL_DEPTH]i32 = undefined;
var pre_frame_site_head: [MAX_CONTROL_DEPTH]i32 = undefined;
var pre_valid: bool = false;
var pre_n: usize = 0;

const DIR_INC: u8 = 1;
const DIR_DEC: u8 = 2;
// A write to the local inside the loop that is not a recognized monotonic
// step. A tainted local cannot prove the loop.
const DIR_TAINT: u8 = 4;
// An add of a known non-negative local (a byte load or a masked value). It
// cannot prove progress by itself, but it does not break monotonicity when
// the strict updates all increase.
const DIR_WEAK_INC: u8 = 8;

const ControlFrame = struct {
    op: u8,
    loop_idx: i32,
    // Exit candidates from conditional branches that target this frame's end.
    // If the code after the end leaves the function, those branches were loop
    // exits even though they never crossed a loop frame.
    pending: [MAX_PENDING]BoundCandidate,
    pending_len: usize,
};

const BoundCandidate = struct {
    local: u32,
    direction: u8,
};

const BoundCandidates = struct {
    items: [2]BoundCandidate = undefined,
    len: usize = 0,
};

const ValueUpdate = struct {
    src: u32,
    dir: u8,
};

const CompareKind = enum { none, eq, lt, gt };

const CheckError = wasm_reader.Error || error{
    TooDeepControl,
    TooManyLoops,
    TooManyLoopCounters,
    LoopBoundNotProven,
    FunctionCodeMismatch,
    TooManyFunctions,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

// ---------------------------------------------------------------------------
// Loop-bound evidence. A loop passes when some local has only monotonic
// constant-step updates inside the loop, all in one direction, plus an exit
// comparison in the matching direction. Mirrors internal/wasminspect.
// ---------------------------------------------------------------------------

fn initLoopEvidence() void {
    loop_count_current = 0;
    loop_counter_count = 0;
}

fn addLoopEvidence() CheckError!u32 {
    if (loop_count_current >= MAX_LOOP_EVIDENCE) return CheckError.TooManyLoops;
    const idx = loop_count_current;
    loop_has_backedge_buf[idx] = false;
    loop_counter_head_buf[idx] = -1;
    loop_count_current += 1;
    return @intCast(idx);
}

fn findLoopCounter(loop_idx: u32, local: u32) ?usize {
    var edge = loop_counter_head_buf[loop_idx];
    while (edge != -1) {
        const i: usize = @intCast(edge);
        if (loop_counter_local_buf[i] == local) return i;
        edge = loop_counter_next_buf[i];
    }
    return null;
}

fn loopCounterSlot(loop_idx: u32, local: u32) CheckError!usize {
    if (findLoopCounter(loop_idx, local)) |idx| return idx;
    if (loop_counter_count >= MAX_LOOP_COUNTERS) return CheckError.TooManyLoopCounters;
    const idx = loop_counter_count;
    loop_counter_local_buf[idx] = local;
    loop_counter_update_buf[idx] = 0;
    loop_counter_exit_buf[idx] = 0;
    loop_counter_next_buf[idx] = loop_counter_head_buf[loop_idx];
    loop_counter_head_buf[loop_idx] = @intCast(idx);
    loop_counter_count += 1;
    return idx;
}

fn markLoopCounterUpdate(loop_idx: u32, local: u32, direction: u8) CheckError!void {
    if (direction == 0) return;
    const idx = try loopCounterSlot(loop_idx, local);
    loop_counter_update_buf[idx] |= direction;
}

fn markLoopCounterTaint(loop_idx: u32, local: u32) CheckError!void {
    const idx = try loopCounterSlot(loop_idx, local);
    loop_counter_update_buf[idx] |= DIR_TAINT;
}

fn markLoopCounterExit(loop_idx: u32, candidate: BoundCandidate) CheckError!void {
    if (candidate.direction == 0) return;
    const idx = try loopCounterSlot(loop_idx, candidate.local);
    loop_counter_exit_buf[idx] |= candidate.direction;
}

fn loopHasBoundedCounter(loop_idx: u32) bool {
    var edge = loop_counter_head_buf[loop_idx];
    while (edge != -1) {
        const i: usize = @intCast(edge);
        const upd = loop_counter_update_buf[i];
        const base = upd & (DIR_INC | DIR_DEC);
        // Untainted, single-direction updates matching an exit direction. A
        // weak non-negative extra step only preserves monotonic increase.
        if ((upd & DIR_TAINT) == 0 and
            (base == DIR_INC or base == DIR_DEC) and
            !((upd & DIR_WEAK_INC) != 0 and base != DIR_INC) and
            (base & loop_counter_exit_buf[i]) != 0) return true;
        edge = loop_counter_next_buf[i];
    }
    return false;
}

fn appendTrace(recent: *[MAX_RECENT_INSTR]Instr, recent_len: *usize, instr: Instr) void {
    if (recent_len.* < MAX_RECENT_INSTR) {
        recent[recent_len.*] = instr;
        recent_len.* += 1;
        return;
    }
    var i: usize = 1;
    while (i < MAX_RECENT_INSTR) : (i += 1) {
        recent[i - 1] = recent[i];
    }
    recent[MAX_RECENT_INSTR - 1] = instr;
}

fn traceLocalGet(t: Instr) ?u32 {
    if (t.op != 0x20 or !t.has_imm or t.imm < 0) return null;
    return @intCast(t.imm);
}

fn traceConst(t: Instr) ?i64 {
    if ((t.op != 0x41 and t.op != 0x42) or !t.has_imm) return null; // i32.const, i64.const
    return t.imm;
}

// Whether the instruction pushes exactly one value and pops none, so it
// forms a complete compare operand on its own: local.get, global.get, or a
// constant.
fn traceSinglePushOperand(t: Instr) bool {
    if (t.op == 0x20 or t.op == 0x23) return t.has_imm; // local.get, global.get
    return traceConst(t) != null;
}

fn counterDirection(is_add: bool, delta: i64) ?u8 {
    if (delta == 0) return null;
    if (is_add == (delta > 0)) return DIR_INC;
    return DIR_DEC;
}

// Updates that strictly shrink a value's magnitude toward zero each
// iteration, such as the x = x / 10 in itoa-style loops. i32.shr_s is
// excluded: shifting a negative value right saturates at -1.
fn shrinkDirection(op: u8, c: i64) ?u8 {
    switch (op) {
        0x6d, 0x6e, 0x7f, 0x80 => { // i32.div_s/div_u, i64.div_s/div_u
            if (c >= 2 or c <= -2) return DIR_DEC;
        },
        0x76 => { // i32.shr_u; shift counts are taken modulo the bit width
            if ((c & 31) >= 1) return DIR_DEC;
        },
        0x88 => { // i64.shr_u
            if ((c & 63) >= 1) return DIR_DEC;
        },
        else => {},
    }
    return null;
}

fn detectCounterUpdate(recent: []const Instr, set_local: u32) ?u8 {
    const vu = detectValueUpdate(recent) orelse return null;
    if (vu.src != set_local) return null;
    return vu.dir;
}

// Recognizes a value on top of the stack computed as a monotonic step from a
// local: local.get X; const C; add/sub/div/shr_u.
fn detectValueUpdate(recent: []const Instr) ?ValueUpdate {
    if (recent.len < 3) return null;
    const a = recent[recent.len - 3];
    const b = recent[recent.len - 2];
    const op = recent[recent.len - 1];

    const is_add = op.op == 0x6a or op.op == 0x7c; // i32.add, i64.add
    const is_sub = op.op == 0x6b or op.op == 0x7d; // i32.sub, i64.sub

    if (traceLocalGet(a)) |local| {
        if (traceConst(b)) |c| {
            if (is_add or is_sub) {
                const dir = counterDirection(is_add, c) orelse return null;
                return .{ .src = local, .dir = dir };
            }
            const dir = shrinkDirection(op.op, c) orelse return null;
            return .{ .src = local, .dir = dir };
        }
    }
    if (is_add) {
        if (traceConst(a)) |c| {
            if (traceLocalGet(b)) |local| {
                const dir = counterDirection(true, c) orelse return null;
                return .{ .src = local, .dir = dir };
            }
        }
    }
    return null;
}

fn copySourceLocal(recent: []const Instr) ?u32 {
    if (recent.len == 0) return null;
    return traceLocalGet(recent[recent.len - 1]);
}

// ---------------------------------------------------------------------------
// Fused add chains: LLVM merges split stride updates back into a single
// expression such as (X + load8(p)) + 1. The chain walk is iterative — this
// checker holds itself to the strict profile it enforces.
// ---------------------------------------------------------------------------

const AddChain = struct {
    local_count: usize = 0,
    local: u32 = 0,
    pos_const: usize = 0,
    neg_const: usize = 0,
    nonneg: usize = 0,
    other: usize = 0,
};

// The stack effect of instructions the fused-chain walk may skip over.
fn operandNetPush(op: u8) ?struct { pops: usize, pushes: usize } {
    return switch (op) {
        0x20, 0x23, 0x41, 0x42, 0x43, 0x44 => .{ .pops = 0, .pushes = 1 }, // local.get, global.get, constants
        0x28...0x35 => .{ .pops = 1, .pushes = 1 }, // loads
        0x45, 0x50, 0x22 => .{ .pops = 1, .pushes = 1 }, // eqz, local.tee
        0x67...0x69, 0x79...0x7b => .{ .pops = 1, .pushes = 1 }, // clz/ctz/popcnt
        0xa7, 0xac, 0xad, 0xc0...0xc4 => .{ .pops = 1, .pushes = 1 }, // wrap/extend
        0x46...0x4f, 0x51...0x5a => .{ .pops = 2, .pushes = 1 }, // compares
        0x6a...0x78, 0x7c...0x8a => .{ .pops = 2, .pushes = 1 }, // binary arithmetic
        0x1b => .{ .pops = 3, .pushes = 1 }, // select
        else => null,
    };
}

// Finds the first instruction of the self-contained operand whose last
// instruction is recent[e], by walking the stack effect backward.
fn operandStart(recent: []const Instr, e: isize) ?isize {
    var needed: isize = 1;
    var j = e;
    while (needed > 0) {
        if (j < 0) return null;
        const effect = operandNetPush(recent[@intCast(j)].op) orelse return null;
        needed = needed - @as(isize, @intCast(effect.pushes)) + @as(isize, @intCast(effect.pops));
        j -= 1;
    }
    return j + 1;
}

fn collectAddChain(recent: []const Instr, e: isize, chain: *AddChain) bool {
    var pending: usize = 1;
    var i = e;
    while (pending > 0) {
        if (i < 0) return false;
        const t = recent[@intCast(i)];
        switch (t.op) {
            0x6a, 0x7c => { // add: flatten, one node becomes two operands
                pending += 1;
                i -= 1;
            },
            0x6b, 0x7d => { // sub: only with a constant subtrahend, sign-flipped
                if (i < 1) return false;
                const c = traceConst(recent[@intCast(i - 1)]) orelse return false;
                if (c > 0) {
                    chain.neg_const += 1;
                } else if (c < 0) {
                    chain.pos_const += 1;
                }
                pending += 1; // minuend still pending; subtrahend consumed here
                i -= 2;
            },
            0x20 => { // local.get leaf
                if (!t.has_imm) return false;
                if (chain.local_count == 0) {
                    chain.local = @intCast(t.imm);
                } else if (chain.local != @as(u32, @intCast(t.imm))) {
                    chain.other += 1;
                }
                chain.local_count += 1;
                pending -= 1;
                i -= 1;
            },
            0x41, 0x42 => { // constant leaf
                if (!t.has_imm) return false;
                if (t.imm > 0) {
                    chain.pos_const += 1;
                } else if (t.imm < 0) {
                    chain.neg_const += 1;
                }
                pending -= 1;
                i -= 1;
            },
            0x2d, 0x2f => { // load8_u/load16_u leaf: non-negative narrow value
                const start = operandStart(recent, i - 1) orelse return false;
                chain.nonneg += 1;
                pending -= 1;
                i = start - 1;
            },
            0x71 => { // and leaf: non-negative if either side is a const >= 0
                const right_start = operandStart(recent, i - 1) orelse return false;
                const left_start = operandStart(recent, right_start - 1) orelse return false;
                const rc = traceConst(recent[@intCast(i - 1)]);
                const lc = traceConst(recent[@intCast(right_start - 1)]);
                const r_nonneg = if (rc) |c| c >= 0 else false;
                const l_nonneg = if (lc) |c| c >= 0 else false;
                if (r_nonneg or l_nonneg) {
                    chain.nonneg += 1;
                } else {
                    chain.other += 1;
                }
                pending -= 1;
                i = left_start - 1;
            },
            else => return false,
        }
    }
    return true;
}

const FusedUpdate = struct {
    dir: u8,
    weak: bool,
};

// Recognizes a monotonic step written as one fused expression: exactly one
// occurrence of the stored local plus positive constants and non-negative
// narrow values (strict increase), only negative constants (strict
// decrease), or only non-negative values (weak increase).
fn detectFusedUpdate(recent: []const Instr, set_local: u32) ?FusedUpdate {
    if (recent.len < 3) return null;
    const top = recent[recent.len - 1];
    if (top.op != 0x6a and top.op != 0x7c and top.op != 0x6b and top.op != 0x7d) return null;
    var chain = AddChain{};
    if (!collectAddChain(recent, @intCast(recent.len - 1), &chain)) return null;
    if (chain.other != 0 or chain.local_count != 1 or chain.local != set_local) return null;
    if (chain.pos_const > 0 and chain.neg_const == 0) {
        return .{ .dir = DIR_INC, .weak = false };
    }
    if (chain.neg_const > 0 and chain.pos_const == 0 and chain.nonneg == 0) {
        return .{ .dir = DIR_DEC, .weak = false };
    }
    if (chain.pos_const == 0 and chain.neg_const == 0 and chain.nonneg > 0) {
        return .{ .dir = DIR_INC, .weak = true };
    }
    return null;
}

// Matches local.get X; local.get T; i32.add (either operand order) storing
// back into X, where T is known non-negative.
fn detectNonnegLocalStep(recent: []const Instr, set_local: u32) bool {
    if (recent.len < 3) return false;
    const a = recent[recent.len - 3];
    const b = recent[recent.len - 2];
    const op = recent[recent.len - 1];
    if (op.op != 0x6a and op.op != 0x7c) return false; // i32.add, i64.add
    const a_local = traceLocalGet(a) orelse return false;
    const b_local = traceLocalGet(b) orelse return false;
    if (a_local == set_local and b_local < MAX_TRACKED_LOCALS and small_nonneg_buf[b_local]) return true;
    if (b_local == set_local and a_local < MAX_TRACKED_LOCALS and small_nonneg_buf[a_local]) return true;
    return false;
}

// Whether the value about to be stored is known non-negative and far below
// the wrap boundary: a narrow load or a mask by a non-negative constant.
fn isSmallNonnegSource(recent: []const Instr) bool {
    if (recent.len == 0) return false;
    const last = recent[recent.len - 1];
    switch (last.op) {
        0x2d, 0x2f => return true, // i32.load8_u, i32.load16_u
        0x71 => { // i32.and with a non-negative constant on either side
            if (recent.len >= 2) {
                if (traceConst(recent[recent.len - 2])) |c| {
                    if (c >= 0) return true;
                }
            }
            if (recent.len >= 3) {
                if (traceConst(recent[recent.len - 3])) |c| {
                    if (c >= 0) return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn compareKindOf(op: u8) CompareKind {
    return switch (op) {
        0x46, 0x47, 0x51, 0x52 => .eq, // i32.eq/ne, i64.eq/ne
        0x48, 0x49, 0x4c, 0x4d, 0x53, 0x54, 0x57, 0x58 => .lt, // i32/i64 lt_s/lt_u/le_s/le_u
        0x4a, 0x4b, 0x4e, 0x4f, 0x55, 0x56, 0x59, 0x5a => .gt, // i32/i64 gt_s/gt_u/ge_s/ge_u
        else => .none,
    };
}

fn pushCandidate(out: *BoundCandidates, local: u32, direction: u8) void {
    if (direction == 0 or out.len >= out.items.len) return;
    out.items[out.len] = .{ .local = local, .direction = direction };
    out.len += 1;
}

fn chooseBoundDirection(exit_direction: u8, branch_back: bool) u8 {
    if (!branch_back) return exit_direction;
    return switch (exit_direction) {
        DIR_INC => DIR_DEC,
        DIR_DEC => DIR_INC,
        else => exit_direction,
    };
}

fn oneSidedBoundCandidates(kind: CompareKind, local: u32, local_on_right: bool, branch_back: bool) BoundCandidates {
    var out = BoundCandidates{};
    switch (kind) {
        .eq => pushCandidate(&out, local, DIR_INC | DIR_DEC),
        .lt, .gt => {
            var exit: u8 = DIR_DEC;
            if ((kind == .lt) == local_on_right) exit = DIR_INC;
            pushCandidate(&out, local, chooseBoundDirection(exit, branch_back));
        },
        .none => {},
    }
    return out;
}

fn compareBoundCandidates(kind: CompareKind, left: u32, right: u32, branch_back: bool) BoundCandidates {
    var out = BoundCandidates{};
    switch (kind) {
        .eq => {
            pushCandidate(&out, left, DIR_INC | DIR_DEC);
            pushCandidate(&out, right, DIR_INC | DIR_DEC);
        },
        .gt => {
            pushCandidate(&out, left, chooseBoundDirection(DIR_INC, branch_back));
            pushCandidate(&out, right, chooseBoundDirection(DIR_DEC, branch_back));
        },
        .lt => {
            pushCandidate(&out, left, chooseBoundDirection(DIR_DEC, branch_back));
            pushCandidate(&out, right, chooseBoundDirection(DIR_INC, branch_back));
        },
        .none => {},
    }
    return out;
}

fn detectBoundCandidates(recent: []const Instr, branch_back: bool) BoundCandidates {
    var out = BoundCandidates{};
    if (recent.len < 2) return out;

    const last = recent[recent.len - 1];
    const prev = recent[recent.len - 2];
    if (last.op == 0x45 or last.op == 0x50) { // i32.eqz, i64.eqz
        if (branch_back) return out;
        if (traceLocalGet(prev)) |local| pushCandidate(&out, local, DIR_DEC);
        return out;
    }
    const kind = compareKindOf(last.op);
    if (kind == .none) return out;

    if (recent.len >= 3) {
        const left = recent[recent.len - 3];
        const right = recent[recent.len - 2];
        const left_local = traceLocalGet(left);
        const right_local = traceLocalGet(right);
        if (left_local) |left_l| {
            if (right_local) |right_l| return compareBoundCandidates(kind, left_l, right_l, branch_back);
            if (traceSinglePushOperand(right)) return oneSidedBoundCandidates(kind, left_l, false, branch_back);
        }
        if (right_local) |right_l| {
            if (traceSinglePushOperand(left)) return oneSidedBoundCandidates(kind, right_l, true, branch_back);
        }
    }

    // Left operand as a monotonic expression of a local, such as
    // local.get i; i32.const 4; i32.add; local.get n; i32.gt_u. The three
    // instructions form one complete operand (two pushes, one pop-2-push-1),
    // so the single-push instruction after them must be the right operand.
    if (recent.len >= 5) {
        const right = recent[recent.len - 2];
        if (traceSinglePushOperand(right)) {
            if (detectValueUpdate(recent[0 .. recent.len - 2])) |vu| {
                if (traceLocalGet(right)) |right_l| return compareBoundCandidates(kind, vu.src, right_l, branch_back);
                return oneSidedBoundCandidates(kind, vu.src, false, branch_back);
            }
        }
    }

    // Bottom-tested shape after an update:
    // local.get bound; local.get i; i32.const 1; i32.add; local.tee i; i32.ne
    if (recent.len >= 6 and recent[recent.len - 2].op == 0x22) {
        const local: u32 = @intCast(recent[recent.len - 2].imm);
        if (traceLocalGet(recent[recent.len - 6]) != null) {
            if (detectCounterUpdate(recent[0 .. recent.len - 2], local)) |dir| {
                pushCandidate(&out, local, dir);
                return out;
            }
        }
    }
    // Same shape with the updated counter on the left:
    // local.get i; i32.const -1; i32.add; local.tee i; local.get bound; i32.gt_u
    if (recent.len >= 6 and recent[recent.len - 3].op == 0x22) {
        const local: u32 = @intCast(recent[recent.len - 3].imm);
        if (traceLocalGet(recent[recent.len - 2]) != null) {
            if (detectCounterUpdate(recent[0 .. recent.len - 3], local)) |dir| {
                pushCandidate(&out, local, dir);
                return out;
            }
        }
    }

    // Right operand as a monotonic expression of a local: the three
    // instructions before the compare form the complete right operand.
    if (recent.len >= 4) {
        if (detectValueUpdate(recent[0 .. recent.len - 1])) |vu| {
            return oneSidedBoundCandidates(kind, vu.src, true, branch_back);
        }
    }

    // One-sided fallback: a lone local.get directly before a binary compare
    // must be the complete right operand, whatever produced the left operand.
    // The mirror case (visible left, computed right) is not safe: the
    // instruction at recent[-3] may be part of the right operand's
    // computation, such as the address feeding a load. Ordered compares only;
    // an equality test against an unknown, possibly moving value says nothing
    // about termination.
    if (kind != .eq) {
        if (traceLocalGet(prev)) |right_local| {
            return oneSidedBoundCandidates(kind, right_local, true, branch_back);
        }
    }
    return out;
}

fn markActiveLoopCounterUpdate(control_stack: []const ControlFrame, local: u32, direction: u8) CheckError!void {
    if (direction == 0) return;
    for (control_stack) |frame| {
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        try markLoopCounterUpdate(@intCast(frame.loop_idx), local, direction);
    }
}

fn markActiveLoopCounterTaint(control_stack: []const ControlFrame, local: u32) CheckError!void {
    for (control_stack) |frame| {
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        try markLoopCounterTaint(@intCast(frame.loop_idx), local);
    }
}

fn markActiveLoopCounterWeakInc(control_stack: []const ControlFrame, local: u32) CheckError!void {
    for (control_stack) |frame| {
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        const idx = try loopCounterSlot(@intCast(frame.loop_idx), local);
        loop_counter_update_buf[idx] |= DIR_WEAK_INC;
    }
}

fn markBranchLoopEvidence(control_stack: []ControlFrame, depth: u32, exit_candidates: BoundCandidates, continue_candidates: BoundCandidates) CheckError!void {
    if (depth >= control_stack.len) {
        // A branch to the implicit function label is a conditional return,
        // exiting every open loop.
        if (depth == control_stack.len) {
            try applyArmedExits(control_stack, exit_candidates.items[0..exit_candidates.len]);
        }
        return;
    }
    const target_index = control_stack.len - 1 - @as(usize, @intCast(depth));
    const target = &control_stack[target_index];
    if (target.op == 0x03) {
        if (target.loop_idx >= 0) {
            const loop_idx: u32 = @intCast(target.loop_idx);
            loop_has_backedge_buf[loop_idx] = true;
            var i: usize = 0;
            while (i < continue_candidates.len) : (i += 1) try markLoopCounterExit(loop_idx, continue_candidates.items[i]);
        }
        return;
    }

    var i = control_stack.len;
    while (i > target_index + 1) {
        i -= 1;
        const frame = control_stack[i];
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        const loop_idx: u32 = @intCast(frame.loop_idx);
        var j: usize = 0;
        while (j < exit_candidates.len) : (j += 1) try markLoopCounterExit(loop_idx, exit_candidates.items[j]);
    }

    var j: usize = 0;
    while (j < exit_candidates.len) : (j += 1) {
        if (target.pending_len >= MAX_PENDING) break;
        target.pending[target.pending_len] = exit_candidates.items[j];
        target.pending_len += 1;
    }
}

fn applyArmedExits(control_stack: []const ControlFrame, candidates: []const BoundCandidate) CheckError!void {
    if (candidates.len == 0) return;
    for (control_stack) |frame| {
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        for (candidates) |candidate| {
            try markLoopCounterExit(@intCast(frame.loop_idx), candidate);
        }
    }
}

// Follows an unconditional branch taken while armed exit candidates are
// live. Loops the branch crosses are exited by the armed path; a forward
// target inherits the candidates so multi-hop exit ladders (block end, br
// out, another block end, return) keep their evidence.
fn transferArmedOnBr(control_stack: []ControlFrame, depth: u32, armed: []const BoundCandidate) CheckError!void {
    if (armed.len == 0) return;
    if (depth >= control_stack.len) {
        try applyArmedExits(control_stack, armed);
        return;
    }
    const target_index = control_stack.len - 1 - @as(usize, @intCast(depth));
    var i = control_stack.len;
    while (i > target_index + 1) {
        i -= 1;
        const frame = control_stack[i];
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        for (armed) |candidate| {
            try markLoopCounterExit(@intCast(frame.loop_idx), candidate);
        }
    }
    const target = &control_stack[target_index];
    if (target.op != 0x03) {
        for (armed) |candidate| {
            if (target.pending_len >= MAX_PENDING) break;
            target.pending[target.pending_len] = candidate;
            target.pending_len += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Must-exit prepass: resolve every forward branch to its continuation
// ordinal, then compute must-exit backward. Structured control flow makes
// one reverse pass sufficient: every edge except loop backedges points
// forward, and backedges are simply "not an exit".
// ---------------------------------------------------------------------------

const PrepassHandler = struct {
    count: usize = 0,
    frames_len: usize = 0,
    too_big: bool = false,

    pub fn onInstr(self: *PrepassHandler, instr: Instr) CheckError!void {
        if (self.too_big) return;
        if (self.count >= MAX_BODY_INSTRS) {
            self.too_big = true;
            return;
        }
        const ord = self.count;
        self.count += 1;
        pre_op_buf[ord] = instr.op;
        pre_aux_buf[ord] = 0;
        switch (instr.op) {
            0x02, 0x03, 0x04 => {
                if (self.frames_len >= MAX_CONTROL_DEPTH) return CheckError.TooDeepControl;
                pre_frame_is_loop[self.frames_len] = instr.op == 0x03;
                pre_frame_if_ord[self.frames_len] = if (instr.op == 0x04) @intCast(ord) else -1;
                pre_frame_site_head[self.frames_len] = -1;
                if (instr.op == 0x04) pre_else_cont_buf[ord] = -1;
                self.frames_len += 1;
            },
            0x05 => {
                // The then-arm jumps from here to after the if's end; the
                // if's false edge enters the else body at ord + 1.
                if (self.frames_len > 0) {
                    const top = self.frames_len - 1;
                    if (pre_frame_if_ord[top] >= 0) {
                        pre_else_cont_buf[@intCast(pre_frame_if_ord[top])] = @intCast(ord + 1);
                        pre_site_next_buf[ord] = pre_frame_site_head[top];
                        pre_frame_site_head[top] = @intCast(ord);
                    }
                }
            },
            0x0b => {
                if (self.frames_len == 0) return;
                self.frames_len -= 1;
                const top = self.frames_len;
                var site = pre_frame_site_head[top];
                while (site >= 0) {
                    const s: usize = @intCast(site);
                    const next = pre_site_next_buf[s];
                    pre_aux_buf[s] = @intCast(ord + 1);
                    site = next;
                }
                if (pre_frame_if_ord[top] >= 0) {
                    const if_ord: usize = @intCast(pre_frame_if_ord[top]);
                    if (pre_else_cont_buf[if_ord] < 0) pre_else_cont_buf[if_ord] = @intCast(ord + 1);
                }
            },
            0x0c, 0x0d => {
                const depth: usize = @intCast(instr.imm);
                if (depth >= self.frames_len) {
                    pre_aux_buf[ord] = AUX_FUNC_LABEL;
                } else {
                    const target = self.frames_len - 1 - depth;
                    if (pre_frame_is_loop[target]) {
                        pre_aux_buf[ord] = AUX_BACKEDGE;
                    } else {
                        pre_site_next_buf[ord] = pre_frame_site_head[target];
                        pre_frame_site_head[target] = @intCast(ord);
                    }
                }
            },
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *PrepassHandler, depth: u32) CheckError!void {
        _ = self;
        _ = depth;
    }
};

fn branchEdgeExits(aux: i32) bool {
    return switch (aux) {
        AUX_BACKEDGE => false,
        AUX_FUNC_LABEL => true,
        else => must_exit_buf[@intCast(aux)],
    };
}

fn finishBodyExit(n: usize) void {
    must_exit_buf[n] = true; // falling off the final end returns
    var i = n;
    while (i > 0) {
        i -= 1;
        taken_exit_buf[i] = false;
        else_exit_buf[i] = false;
        switch (pre_op_buf[i]) {
            0x00, 0x0f => must_exit_buf[i] = true, // unreachable, return
            0x0c => { // br
                taken_exit_buf[i] = branchEdgeExits(pre_aux_buf[i]);
                must_exit_buf[i] = taken_exit_buf[i];
            },
            0x0d => { // br_if
                taken_exit_buf[i] = branchEdgeExits(pre_aux_buf[i]);
                must_exit_buf[i] = taken_exit_buf[i] and must_exit_buf[i + 1];
            },
            0x0e => must_exit_buf[i] = false, // br_table: under-approximate
            0x04 => { // if: both edges must exit
                const else_cont = pre_else_cont_buf[i];
                else_exit_buf[i] = else_cont >= 0 and must_exit_buf[@intCast(else_cont)];
                must_exit_buf[i] = must_exit_buf[i + 1] and else_exit_buf[i];
            },
            0x05 => { // else marker: the then-arm's jump to after the end
                must_exit_buf[i] = if (pre_aux_buf[i] > 0) must_exit_buf[@intCast(pre_aux_buf[i])] else false;
            },
            else => must_exit_buf[i] = must_exit_buf[i + 1],
        }
    }
    pre_n = n;
}

fn preMustExitAfter(ord: usize) bool {
    if (!pre_valid or ord + 1 > pre_n) return false;
    return must_exit_buf[ord + 1];
}

fn preTakenExit(ord: usize) bool {
    if (!pre_valid or ord >= pre_n) return false;
    return taken_exit_buf[ord];
}

fn preElseExit(ord: usize) bool {
    if (!pre_valid or ord >= pre_n) return false;
    return else_exit_buf[ord];
}

// ---------------------------------------------------------------------------
// The per-function analysis, driven by lib/wasm-reader's body walk.
// ---------------------------------------------------------------------------

const LoopHandler = struct {
    control_len: usize = 0,
    ord: usize = 0,
    recent: [MAX_RECENT_INSTR]Instr = undefined,
    recent_len: usize = 0,
    // armed carries a just-ended block's pending exit candidates, an if
    // condition, or a br_if's inverted condition. If control then leaves the
    // function before any other control flow, those candidates were exits.
    armed: [MAX_PENDING]BoundCandidate = undefined,
    armed_len: usize = 0,
    // Candidates stashed by a br_table instruction for its target events.
    table_exit: BoundCandidates = .{},
    table_continue: BoundCandidates = .{},

    pub fn onInstr(self: *LoopHandler, instr: Instr) CheckError!void {
        const control_stack = &control_stack_buf;
        const ord = self.ord;
        self.ord += 1;
        switch (instr.op) {
            // nop, drop, select, ref.is_null: keep armed alive through data ops
            0x01, 0x1a, 0x1b, 0xd1 => {},
            // unreachable, return: leaving the function exits every open loop
            0x00, 0x0f => {
                try applyArmedExits(control_stack[0..self.control_len], self.armed[0..self.armed_len]);
                self.armed_len = 0;
            },
            // else
            0x05 => self.armed_len = 0,
            // block, loop, if
            0x02, 0x03, 0x04 => {
                if (self.control_len >= MAX_CONTROL_DEPTH) return CheckError.TooDeepControl;
                self.armed_len = 0;
                if (instr.op == 0x04) {
                    // The if body runs when the condition is true; if it
                    // leaves the function before other control flow, the
                    // condition was an exit test, as in: if (i >= n) return.
                    const candidates = detectBoundCandidates(self.recent[0..self.recent_len], false);
                    var ci: usize = 0;
                    while (ci < candidates.len) : (ci += 1) {
                        self.armed[self.armed_len] = candidates.items[ci];
                        self.armed_len += 1;
                    }
                    // Must-exit generalizes that through nested control
                    // flow, and covers an else arm that exits.
                    if (preMustExitAfter(ord)) {
                        try applyArmedExits(control_stack[0..self.control_len], candidates.items[0..candidates.len]);
                    }
                    if (preElseExit(ord)) {
                        const inverse = detectBoundCandidates(self.recent[0..self.recent_len], true);
                        try applyArmedExits(control_stack[0..self.control_len], inverse.items[0..inverse.len]);
                    }
                }
                var loop_idx: i32 = -1;
                if (instr.op == 0x03) loop_idx = @intCast(try addLoopEvidence());
                control_stack[self.control_len] = .{ .op = instr.op, .loop_idx = loop_idx, .pending = undefined, .pending_len = 0 };
                self.control_len += 1;
            },
            // end (the final function end is not reported by the walk)
            0x0b => {
                if (self.control_len == 0) return;
                const frame = &control_stack[self.control_len - 1];
                self.control_len -= 1;
                // A still-armed fall-through path converges with branches to
                // this frame's end, so both candidate sets stay live.
                var merged: [MAX_PENDING]BoundCandidate = frame.pending;
                var merged_len: usize = frame.pending_len;
                var ai: usize = 0;
                while (ai < self.armed_len and merged_len < MAX_PENDING) : (ai += 1) {
                    merged[merged_len] = self.armed[ai];
                    merged_len += 1;
                }
                self.armed = merged;
                self.armed_len = merged_len;
                if (frame.op == 0x03 and frame.loop_idx >= 0) {
                    self.armed_len = 0;
                    const loop_idx: u32 = @intCast(frame.loop_idx);
                    if (loop_has_backedge_buf[loop_idx] and !loopHasBoundedCounter(loop_idx)) {
                        return CheckError.LoopBoundNotProven;
                    }
                }
            },
            // br
            0x0c => {
                const depth: u32 = @intCast(instr.imm);
                try markBranchLoopEvidence(control_stack[0..self.control_len], depth, BoundCandidates{}, BoundCandidates{});
                try transferArmedOnBr(control_stack[0..self.control_len], depth, self.armed[0..self.armed_len]);
                self.armed_len = 0;
            },
            // br_if
            0x0d => {
                const depth: u32 = @intCast(instr.imm);
                const exit_candidates = detectBoundCandidates(self.recent[0..self.recent_len], false);
                const continue_candidates = detectBoundCandidates(self.recent[0..self.recent_len], true);
                try markBranchLoopEvidence(control_stack[0..self.control_len], depth, exit_candidates, continue_candidates);
                // The fall-through path holds the inverted condition; if it
                // leaves the function, the branch skipped past an exit, as
                // in: loop { block { br_if 0 (i != n); return } ... }.
                self.armed_len = 0;
                var ci: usize = 0;
                while (ci < continue_candidates.len) : (ci += 1) {
                    self.armed[self.armed_len] = continue_candidates.items[ci];
                    self.armed_len += 1;
                }
                // Must-exit covers both edges through arbitrary forward
                // flow: a taken edge whose target's continuation leaves the
                // function, and a fall-through that leaves via later
                // conditional paths.
                if (preTakenExit(ord)) {
                    try applyArmedExits(control_stack[0..self.control_len], exit_candidates.items[0..exit_candidates.len]);
                }
                if (preMustExitAfter(ord)) {
                    try applyArmedExits(control_stack[0..self.control_len], continue_candidates.items[0..continue_candidates.len]);
                }
            },
            // br_table: targets arrive as onBrTableTarget events next
            0x0e => {
                self.table_exit = detectBoundCandidates(self.recent[0..self.recent_len], false);
                self.table_continue = detectBoundCandidates(self.recent[0..self.recent_len], true);
                self.armed_len = 0;
            },
            // local.set, local.tee
            0x21, 0x22 => {
                const idx: u32 = @intCast(instr.imm);
                const recent = self.recent[0..self.recent_len];
                var new_src: u32 = 0;
                var new_dir: u8 = 0;
                var has_new = false;
                if (detectValueUpdate(recent)) |vu| {
                    if (vu.src == idx) {
                        try markActiveLoopCounterUpdate(control_stack[0..self.control_len], idx, vu.dir);
                    } else {
                        try markActiveLoopCounterTaint(control_stack[0..self.control_len], idx);
                        new_src = vu.src;
                        new_dir = vu.dir;
                        has_new = true;
                    }
                } else if (detectFusedUpdate(recent, idx)) |fused| {
                    if (fused.weak) {
                        try markActiveLoopCounterWeakInc(control_stack[0..self.control_len], idx);
                    } else {
                        try markActiveLoopCounterUpdate(control_stack[0..self.control_len], idx, fused.dir);
                    }
                } else if (detectNonnegLocalStep(recent, idx)) {
                    try markActiveLoopCounterWeakInc(control_stack[0..self.control_len], idx);
                } else if (copySourceLocal(recent)) |from| {
                    if (from < MAX_TRACKED_LOCALS and derived_active_buf[from] and derived_src_buf[from] == idx) {
                        try markActiveLoopCounterUpdate(control_stack[0..self.control_len], idx, derived_dir_buf[from]);
                    } else if (from != idx) {
                        try markActiveLoopCounterTaint(control_stack[0..self.control_len], idx);
                    }
                } else {
                    try markActiveLoopCounterTaint(control_stack[0..self.control_len], idx);
                }
                if (idx < MAX_TRACKED_LOCALS) {
                    derived_active_buf[idx] = false;
                    if (has_new) {
                        derived_active_buf[idx] = true;
                        derived_src_buf[idx] = new_src;
                        derived_dir_buf[idx] = new_dir;
                    }
                    small_nonneg_buf[idx] = isSmallNonnegSource(recent);
                }
            },
            else => {},
        }
        appendTrace(&self.recent, &self.recent_len, instr);
    }

    pub fn onBrTableTarget(self: *LoopHandler, depth: u32) CheckError!void {
        try markBranchLoopEvidence(control_stack_buf[0..self.control_len], depth, self.table_exit, self.table_continue);
    }
};

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

fn parseFunctionSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.readVarU32();
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return n;
}

fn parseCodeSection(payload: []const u8, defined_func_count: u32) CheckError!void {
    if (defined_func_count > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;

    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n != defined_func_count) return CheckError.FunctionCodeMismatch;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const body_size = try r.readVarU32();
        const body = try r.readN(body_size);

        initLoopEvidence();
        var d: usize = 0;
        while (d < MAX_TRACKED_LOCALS) : (d += 1) {
            derived_active_buf[d] = false;
            small_nonneg_buf[d] = false;
        }
        pre_valid = false;
        var prepass = PrepassHandler{};
        try wasm_reader.walkFunctionBody(&prepass, body);
        if (!prepass.too_big) {
            finishBodyExit(prepass.count);
            pre_valid = true;
        }
        var handler = LoopHandler{};
        try wasm_reader.walkFunctionBody(&handler, body);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn checkModule(wasm: []const u8) CheckError!void {
    try wasm_reader.checkHeader(wasm);

    var r = Reader.init(wasm[8..]);
    var defined_func_count: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);

        switch (section_id) {
            3 => {
                defined_func_count = try parseFunctionSection(payload);
                have_function_section = true;
            },
            10 => {
                try parseCodeSection(payload, defined_func_count);
                have_code_section = true;
            },
            else => {},
        }
    }

    if (have_function_section and !have_code_section) return CheckError.InvalidWasm;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size: u32) RenderOutcome {
    if (input_size > INPUT_CAP) @trap();

    checkModule(input_buf[0..input_size]) catch {
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{ .output_size_or_failure = input_size, .output_ptr = @intFromPtr(&input_buf), .failed = 0 };
}

export fn render(input_size: u32) RenderResult {
    const result = renderOutcome(input_size);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}

// ---------------------------------------------------------------------------
// Tests. Loop-shape modules are built around a raw () -> () body.
// ---------------------------------------------------------------------------

const moduleWithBody = wasm_reader.moduleWithBody;

const ok_module = moduleWithBody(&[_]u8{0x0b});

const bounded_counter_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, // block
    0x03, 0x40, // loop
    0x20, 0x00, // local.get 0
    0x41, 0x0a, // i32.const 10
    0x4f, // i32.ge_u
    0x0d, 0x01, // br_if 1 (exit)
    0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local 0 += 1
    0x0c, 0x00, // br 0 (backedge)
    0x0b, 0x0b,
    0x0b,
});

const signed_compare_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x41, 0x0a, 0x4e, // local0 >= 10 (signed)
    0x0d, 0x01, 0x20, 0x00, 0x41,
    0x01, 0x6a, 0x21, 0x00, 0x0c,
    0x00, 0x0b, 0x0b, 0x0b,
});

const i64_counter_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x42, 0xe4, 0x00, 0x5a, // local0 >= 100 (i64)
    0x0d, 0x01,
    0x20, 0x00, 0x42, 0x01, 0x7c, 0x21, 0x00, // local0 += 1 (i64)
    0x0c, 0x00, 0x0b, 0x0b, 0x0b,
});

const div_shrink_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x45, // eqz(local0)
    0x0d, 0x01,
    0x20, 0x00, 0x41, 0x0a, 0x6e, 0x21, 0x00, // local0 /= 10
    0x0c, 0x00, 0x0b, 0x0b, 0x0b,
});

const copy_chain_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x45, // eqz(local0)
    0x0d, 0x01,
    0x20, 0x00, 0x41, 0x0a, 0x6e, // local0 / 10
    0x22, 0x01, // local.tee 1
    0x1a, // drop
    0x20, 0x01, 0x21, 0x00, // local0 = local1
    0x0c, 0x00, 0x0b, 0x0b,
    0x0b,
});

const return_exit_loop = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x02, 0x40, // block
    0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
    0x0d, 0x00, // br_if 0 (to block end)
    0x20, 0x00,
    0x41, 0x01,
    0x6a, 0x21,
    0x00,
    0x0c, 0x01, // br 1 (backedge)
    0x0b, // end block
    0x0f, // return
    0x0b,
    0x0b,
});

const expression_operand_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x41, 0x04, 0x6a, // local0 + 4
    0x20, 0x01, 0x4b, // > local1
    0x0d, 0x01,
    0x20, 0x00, 0x41, 0x04, 0x6a, 0x21, 0x00, // local0 += 4
    0x0c, 0x00, 0x0b, 0x0b, 0x0b,
});

const one_sided_compare_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x02, 0x2d, 0x00, 0x00, // load8(local2)
    0x20, 0x00, 0x49, // < local0
    0x0d, 0x01, 0x20,
    0x00, 0x41, 0x01,
    0x6a, 0x21, 0x00,
    0x0c, 0x00, 0x0b,
    0x0b, 0x0b,
});

const global_bound_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x23, 0x00, 0x4f, // local0 >= global0
    0x0d, 0x01, 0x20, 0x00, 0x41,
    0x01, 0x6a, 0x21, 0x00, 0x0c,
    0x00, 0x0b, 0x0b, 0x0b,
});

const conditional_return_loop = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
    0x0d, 0x01, // br_if 1 (function label)
    0x20, 0x00,
    0x41, 0x01,
    0x6a, 0x21,
    0x00, 0x0c,
    0x00, 0x0b,
    0x0b,
});

const armed_br_chain_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, // block (outer)
    0x03, 0x40, // loop
    0x02, 0x40, // block (inner)
    0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
    0x0d, 0x00, // br_if 0 (to inner block end)
    0x20, 0x00,
    0x41, 0x01,
    0x6a, 0x21,
    0x00,
    0x0c, 0x01, // br 1 (backedge)
    0x0b, // end inner block
    0x0c, 0x01, // br 1 (crosses loop to outer block end)
    0x0b, 0x0b,
    0x0b,
});

const if_return_exit_loop = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x20, 0x00, 0x41, 0x0a, 0x4f, // local0 >= 10
    0x04, 0x40, // if
    0x0f, // return
    0x0b, // end if
    0x20,
    0x00,
    0x41,
    0x01,
    0x6a,
    0x21,
    0x00,
    0x0c, 0x00, // br 0 (backedge)
    0x0b, 0x0b,
});

const br_if_skip_return_loop = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x02, 0x40, // block
    0x20, 0x00, 0x41, 0x0a, 0x47, // local0 != 10
    0x0d, 0x00, // br_if 0 (skip the return)
    0x0f, // return
    0x0b, // end block
    0x20,
    0x00,
    0x41,
    0x01,
    0x6a,
    0x21,
    0x00,
    0x0c, 0x00, // br 0 (backedge)
    0x0b, 0x0b,
});

const nonneg_stride_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
    0x0d, 0x01,
    0x20, 0x02, 0x2d, 0x00, 0x00, 0x21, 0x03, // local3 = load8_u(local2)
    0x20, 0x00, 0x20, 0x03, 0x6a, 0x21, 0x00, // local0 += local3
    0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local0 += 1
    0x0c, 0x00, 0x0b, 0x0b, 0x0b,
});

const nonneg_stride_alone_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
    0x0d, 0x01,
    0x20, 0x02, 0x2d, 0x00, 0x00, 0x21, 0x03, // local3 = load8_u(local2)
    0x20, 0x00, 0x20, 0x03, 0x6a, 0x21, 0x00, // local0 += local3 (weak only)
    0x0c, 0x00, 0x0b, 0x0b, 0x0b,
});

const fused_stride_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
    0x0d, 0x01,
    0x20, 0x00, // local.get 0
    0x20, 0x00, 0x2d, 0x00, 0x00, // load8_u(local0)
    0x6a, // i32.add
    0x41, 0x01, // i32.const 1
    0x6a, // i32.add
    0x21, 0x00, // local.set 0
    0x0c, 0x00,
    0x0b, 0x0b,
    0x0b,
});

const fused_weak_alone_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x20, 0x01, 0x4f, // local0 >= local1
    0x0d, 0x01,
    0x20, 0x00, // local.get 0
    0x20, 0x00, 0x2d, 0x00, 0x00, // load8_u(local0)
    0x6a, // i32.add (no strict component)
    0x21, 0x00, // local.set 0
    0x0c, 0x00,
    0x0b, 0x0b,
    0x0b,
});

const must_exit_ladder_loop = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x02, 0x40, // block
    0x20, 0x00, 0x41, 0x0a, 0x46, // local0 == 10
    0x0d, 0x00, // br_if 0 (to block end)
    0x20, 0x00,
    0x41, 0x01,
    0x6a, 0x21,
    0x00,
    0x0c, 0x01, // br 1 (backedge)
    0x0b, // end block
    0x20, 0x01, // local.get 1
    0x04, 0x40, // if
    0x0f, // return
    0x0b, // end if
    0x0f, // return
    0x0b,
    0x0b,
});

const unbounded_loop = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x0c, 0x00, // br 0
    0x0b, 0x0b,
});

const tainted_counter_loop = moduleWithBody(&[_]u8{
    0x02, 0x40, 0x03, 0x40,
    0x20, 0x00, 0x41, 0x0a, 0x4f, // local0 >= 10
    0x0d, 0x01,
    0x20, 0x00, 0x41, 0x01, 0x6a, 0x21, 0x00, // local0 += 1
    0x41, 0x00, 0x21, 0x00, // local0 = 0 (taints the counter)
    0x0c, 0x00, 0x0b, 0x0b,
    0x0b,
});

// The profile rules are the other component's job: memory.grow and atomics
// pass here as long as every loop is proven.
const memory_grow_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01, 0x01,
    0x01, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x00,
    0x40, 0x00, 0x0b,
};

const atomics_module = moduleWithBody(&[_]u8{ 0xfe, 0x10, 0x00, 0x00, 0x0b });

test "accepts a module with no loops" {
    try checkModule(&ok_module);
}

test "render rejects an unproved loop and the instance recovers" {
    @memcpy(input_buf[0..unbounded_loop.len], &unbounded_loop);
    const rejected = renderOutcome(unbounded_loop.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);

    @memcpy(input_buf[0..ok_module.len], &ok_module);
    const accepted = renderOutcome(ok_module.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, ok_module.len), accepted.output_size_or_failure);
    try std.testing.expectEqualSlices(u8, &ok_module, input_buf[0..ok_module.len]);
}

test "accepts a counter loop with a visible bound" {
    try checkModule(&bounded_counter_loop);
}

test "accepts a signed compare exit" {
    try checkModule(&signed_compare_loop);
}

test "accepts an i64 counter" {
    try checkModule(&i64_counter_loop);
}

test "accepts an itoa-style division shrink" {
    try checkModule(&div_shrink_loop);
}

test "accepts a copy-chain update through a temp local" {
    try checkModule(&copy_chain_loop);
}

test "accepts an exit that leaves via return" {
    try checkModule(&return_exit_loop);
}

test "accepts a compare with an expression operand" {
    try checkModule(&expression_operand_loop);
}

test "accepts a one-sided compare against a computed value" {
    try checkModule(&one_sided_compare_loop);
}

test "accepts a global bound compare" {
    try checkModule(&global_bound_loop);
}

test "accepts a conditional return via the function label" {
    try checkModule(&conditional_return_loop);
}

test "accepts an armed exit chained through an unconditional br" {
    try checkModule(&armed_br_chain_loop);
}

test "accepts an if body that returns as an exit test" {
    try checkModule(&if_return_exit_loop);
}

test "accepts a br_if that skips past a return" {
    try checkModule(&br_if_skip_return_loop);
}

test "accepts a non-negative stride beside a strict increment" {
    try checkModule(&nonneg_stride_loop);
}

test "accepts memory.grow: profile rules are wasm-strict-profile's job" {
    try checkModule(&memory_grow_module);
}

test "accepts atomics: profile rules are wasm-strict-profile's job" {
    try checkModule(&atomics_module);
}

test "accepts a fused add-chain stride" {
    try checkModule(&fused_stride_loop);
}

test "accepts an exit ladder proven by must-exit analysis" {
    try checkModule(&must_exit_ladder_loop);
}

test "rejects a fused weak stride with no strict component" {
    try std.testing.expectError(CheckError.LoopBoundNotProven, checkModule(&fused_weak_alone_loop));
}

test "rejects a non-negative stride with no strict update" {
    try std.testing.expectError(CheckError.LoopBoundNotProven, checkModule(&nonneg_stride_alone_loop));
}

test "rejects a loop with a backedge and no bound" {
    try std.testing.expectError(CheckError.LoopBoundNotProven, checkModule(&unbounded_loop));
}

test "rejects a counter with an unrecognized extra write" {
    try std.testing.expectError(CheckError.LoopBoundNotProven, checkModule(&tainted_counter_loop));
}
