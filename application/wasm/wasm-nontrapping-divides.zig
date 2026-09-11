//! wasm-nontrapping-divides: proves that every integer division and remainder
//! instruction has operands that cannot trigger a WebAssembly arithmetic trap.
//!
//! The checker recognizes constants and path-sensitive guards, and propagates
//! those facts through locals and structured forward branches. Unsigned division and all remainder
//! instructions require a nonzero divisor. Signed division additionally proves
//! that the operands cannot be MIN / -1. Unrecognized dynamic divisors are
//! rejected.
//!
//! Input is a Wasm module; output is the same bytes on success. `render`
//! rejects when any division or remainder is not proven non-trapping.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const CheckError = wasm_reader.Error || error{
    FunctionCodeMismatch,
    DivideMayTrap,
    TooDeepControl,
};

const MAX_TRACKED_LOCALS: usize = 4096;
const MAX_CONTROL_DEPTH: usize = 4096;
const MAX_LOOPS: usize = 4096;
const LOOP_WRITE_BYTES: usize = MAX_TRACKED_LOCALS / 8;
const MAX_PATH_FACTS: usize = 16;
const FACT_NONZERO_32: u8 = 1 << 0;
const FACT_NOT_NEG_ONE_32: u8 = 1 << 1;
const FACT_NOT_MIN_32: u8 = 1 << 2;
const FACT_NONZERO_64: u8 = 1 << 3;
const FACT_NOT_NEG_ONE_64: u8 = 1 << 4;
const FACT_NOT_MIN_64: u8 = 1 << 5;
const RANGE_UNKNOWN: u8 = 0;
const RANGE_I32: u8 = 1;
const RANGE_I64: u8 = 2;

const ValueRange = struct {
    kind: u8 = RANGE_UNKNOWN,
    min: u64 = 0,
    max: u64 = 0,
};

const GuardFact = struct {
    local: u32,
    mask: u8,
};

const PathFrame = struct {
    op: u8,
    entry_reachable: bool,
    has_else: bool = false,
    pending_reachable: bool = false,
    pending: [MAX_PATH_FACTS]GuardFact = undefined,
    pending_len: usize = 0,
};

var path_frame_buf: [MAX_CONTROL_DEPTH]PathFrame = undefined;
var loop_written_buf: [MAX_LOOPS][LOOP_WRITE_BYTES]u8 = undefined;

const LoopWriteFinder = struct {
    frame_is_loop: [MAX_CONTROL_DEPTH]bool = @splat(false),
    frame_loop_index: [MAX_CONTROL_DEPTH]u16 = @splat(0),
    depth: usize = 0,
    loop_count: usize = 0,

    pub fn onInstr(self: *LoopWriteFinder, instr: Instr) CheckError!void {
        switch (instr.op) {
            0x02, 0x03, 0x04 => {
                if (self.depth >= self.frame_is_loop.len) return CheckError.TooDeepControl;
                const is_loop = instr.op == 0x03;
                self.frame_is_loop[self.depth] = is_loop;
                if (is_loop) {
                    if (self.loop_count >= MAX_LOOPS) return CheckError.TooDeepControl;
                    self.frame_loop_index[self.depth] = @intCast(self.loop_count);
                    @memset(&loop_written_buf[self.loop_count], 0);
                    self.loop_count += 1;
                }
                self.depth += 1;
            },
            0x0b => {
                self.depth -= 1;
            },
            0x21, 0x22 => {
                const index: usize = @intCast(instr.imm);
                if (index >= MAX_TRACKED_LOCALS) return;
                for (self.frame_is_loop[0..self.depth], 0..) |is_loop, frame_index| {
                    if (!is_loop) continue;
                    const loop_index = self.frame_loop_index[frame_index];
                    loop_written_buf[loop_index][index / 8] |= @as(u8, 1) << @intCast(index % 8);
                }
            },
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *LoopWriteFinder, depth: u32) CheckError!void {
        _ = self;
        _ = depth;
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const DivideChecker = struct {
    previous: [8]Instr = @splat(.{}),
    previous_count: usize = 0,
    local_facts: [MAX_TRACKED_LOCALS]u8 = @splat(0),
    local_fact_scope: [MAX_TRACKED_LOCALS]u16 = @splat(0),
    local_range_kind: [MAX_TRACKED_LOCALS]u8 = @splat(RANGE_UNKNOWN),
    local_range_min: [MAX_TRACKED_LOCALS]u64 = @splat(0),
    local_range_max: [MAX_TRACKED_LOCALS]u64 = @splat(0),
    control_depth: u16 = 0,
    path_facts: [MAX_PATH_FACTS]GuardFact = undefined,
    path_facts_len: usize = 0,
    path_reachable: bool = true,
    path_frames_len: usize = 0,
    table_facts: [MAX_PATH_FACTS]GuardFact = undefined,
    table_facts_len: usize = 0,
    table_reachable: bool = false,
    loop_index: usize = 0,

    fn prior(self: *const DivideChecker, distance: usize) ?Instr {
        if (distance == 0 or distance > self.previous_count) return null;
        return self.previous[self.previous_count - distance];
    }

    fn remember(self: *DivideChecker, instr: Instr) void {
        if (self.previous_count < self.previous.len) {
            self.previous[self.previous_count] = instr;
            self.previous_count += 1;
            return;
        }
        var i: usize = 1;
        while (i < self.previous.len) : (i += 1) self.previous[i - 1] = self.previous[i];
        self.previous[self.previous.len - 1] = instr;
    }

    fn constant(self: *const DivideChecker, distance: usize, op: u8) ?i64 {
        const instr = self.prior(distance) orelse return null;
        if (instr.op != op or !instr.has_imm) return null;
        return instr.imm;
    }

    fn localIndex(self: *const DivideChecker, distance: usize) ?usize {
        const instr = self.prior(distance) orelse return null;
        if ((instr.op != 0x20 and instr.op != 0x22) or !instr.has_imm) return null;
        const index: usize = @intCast(instr.imm);
        if (index >= MAX_TRACKED_LOCALS) return null;
        return index;
    }

    fn i32AbsSource(self: *const DivideChecker, distance: usize) ?usize {
        const sub = self.prior(distance) orelse return null;
        const sign_get = self.prior(distance + 1) orelse return null;
        const xor = self.prior(distance + 2) orelse return null;
        const sign_tee = self.prior(distance + 3) orelse return null;
        const shr = self.prior(distance + 4) orelse return null;
        if (sub.op != 0x6b or sign_get.op != 0x20 or xor.op != 0x73 or
            sign_tee.op != 0x22 or shr.op != 0x75)
        {
            return null;
        }
        const shift = self.constant(distance + 5, 0x41) orelse return null;
        const right_source = self.localIndex(distance + 6) orelse return null;
        const left_source = self.localIndex(distance + 7) orelse return null;
        if (shift != 31 or right_source != left_source or
            sign_get.imm != sign_tee.imm)
        {
            return null;
        }
        return left_source;
    }

    fn factsForValue(self: *const DivideChecker, distance: usize, const_op: u8) u8 {
        if (self.constant(distance, const_op)) |value| {
            if (const_op == 0x41) {
                var facts: u8 = 0;
                if (@as(i32, @intCast(value)) != 0) facts |= FACT_NONZERO_32;
                if (@as(i32, @intCast(value)) != -1) facts |= FACT_NOT_NEG_ONE_32;
                if (@as(i32, @intCast(value)) != std.math.minInt(i32)) facts |= FACT_NOT_MIN_32;
                return facts;
            }
            var facts: u8 = 0;
            if (value != 0) facts |= FACT_NONZERO_64;
            if (value != -1) facts |= FACT_NOT_NEG_ONE_64;
            if (value != std.math.minInt(i64)) facts |= FACT_NOT_MIN_64;
            return facts;
        }
        const instr = self.prior(distance) orelse return 0;
        if (const_op == 0x42 and instr.op == 0xad) { // i64.extend_i32_u
            const source = self.factsForValue(distance + 1, 0x41);
            var facts: u8 = FACT_NOT_NEG_ONE_64 | FACT_NOT_MIN_64;
            if ((source & FACT_NONZERO_32) != 0) facts |= FACT_NONZERO_64;
            return facts;
        }
        if (const_op == 0x41) {
            if (self.i32AbsSource(distance)) |source| {
                const source_facts = self.local_facts[source] | self.pathFactMask(source);
                if ((source_facts & (FACT_NONZERO_32 | FACT_NOT_MIN_32)) ==
                    (FACT_NONZERO_32 | FACT_NOT_MIN_32))
                {
                    return FACT_NONZERO_32 | FACT_NOT_NEG_ONE_32 | FACT_NOT_MIN_32;
                }
            }
        }
        const index = self.localIndex(distance) orelse return 0;
        return self.local_facts[index] | self.pathFactMask(index);
    }

    fn atomRange(self: *const DivideChecker, distance: usize, kind: u8) ValueRange {
        const const_op: u8 = if (kind == RANGE_I32) 0x41 else 0x42;
        if (self.constant(distance, const_op)) |value| {
            const raw = if (kind == RANGE_I32)
                @as(u32, @bitCast(@as(i32, @intCast(value))))
            else
                @as(u64, @bitCast(value));
            return .{ .kind = kind, .min = raw, .max = raw };
        }
        const instr = self.prior(distance) orelse return .{};
        if (kind == RANGE_I32) {
            const max: ?u64 = switch (instr.op) {
                0x2d => 255, // i32.load8_u
                0x2f => 65535, // i32.load16_u
                else => null,
            };
            if (max) |value| return .{ .kind = kind, .min = 0, .max = value };
        }
        const index = self.localIndex(distance) orelse return .{};
        if (self.local_range_kind[index] != kind) return .{};
        return .{
            .kind = kind,
            .min = self.local_range_min[index],
            .max = self.local_range_max[index],
        };
    }

    fn rangeForValue(self: *const DivideChecker, distance: usize, kind: u8) ValueRange {
        const atom = self.atomRange(distance, kind);
        if (atom.kind != RANGE_UNKNOWN) return atom;

        const instr = self.prior(distance) orelse return .{};
        if (kind == RANGE_I64 and instr.op == 0xad) { // i64.extend_i32_u
            const source = self.rangeForValue(distance + 1, RANGE_I32);
            if (source.kind != RANGE_UNKNOWN) {
                return .{ .kind = RANGE_I64, .min = source.min, .max = source.max };
            }
        }
        if (kind == RANGE_I32) {
            if (self.i32AbsSource(distance)) |source| {
                const source_facts = self.local_facts[source] | self.pathFactMask(source);
                if ((source_facts & (FACT_NONZERO_32 | FACT_NOT_MIN_32)) ==
                    (FACT_NONZERO_32 | FACT_NOT_MIN_32))
                {
                    return .{ .kind = RANGE_I32, .min = 1, .max = std.math.maxInt(i32) };
                }
            }
        }
        const left = self.atomRange(distance + 2, kind);
        const right = self.atomRange(distance + 1, kind);
        if (left.kind == RANGE_UNKNOWN or right.kind == RANGE_UNKNOWN) return .{};
        const type_max: u64 = if (kind == RANGE_I32) std.math.maxInt(u32) else std.math.maxInt(u64);

        switch (instr.op) {
            0x6a, 0x7c => { // add
                const min = @as(u128, left.min) + right.min;
                const max = @as(u128, left.max) + right.max;
                if (max > type_max) return .{};
                return .{ .kind = kind, .min = @intCast(min), .max = @intCast(max) };
            },
            0x6b, 0x7d => { // sub
                if (left.min < right.max) return .{};
                return .{ .kind = kind, .min = left.min - right.max, .max = left.max - right.min };
            },
            0x6c, 0x7e => { // mul
                const min = @as(u128, left.min) * right.min;
                const max = @as(u128, left.max) * right.max;
                if (max > type_max) return .{};
                return .{ .kind = kind, .min = @intCast(min), .max = @intCast(max) };
            },
            0x71, 0x83 => { // and
                if (left.min == left.max and right.min == right.max) {
                    const value = left.min & right.min;
                    return .{ .kind = kind, .min = value, .max = value };
                }
                if (left.min == left.max) {
                    const mask = left.min;
                    if ((mask & (mask +% 1)) == 0) {
                        if (right.max <= mask) return right;
                        return .{ .kind = kind, .min = 0, .max = @min(right.max, mask) };
                    }
                }
                if (right.min == right.max) {
                    const mask = right.min;
                    if ((mask & (mask +% 1)) == 0) {
                        if (left.max <= mask) return left;
                        return .{ .kind = kind, .min = 0, .max = @min(left.max, mask) };
                    }
                }
                return .{};
            },
            0x76, 0x88 => { // shr_u
                if (right.min != right.max) return .{};
                const shift_mask: u64 = if (kind == RANGE_I32) 31 else 63;
                const shift: u6 = @intCast(right.min & shift_mask);
                return .{ .kind = kind, .min = left.min >> shift, .max = left.max >> shift };
            },
            else => return .{},
        }
    }

    fn factsFromRange(range: ValueRange) u8 {
        if (range.kind == RANGE_UNKNOWN) return 0;
        var facts: u8 = 0;
        if (range.kind == RANGE_I32) {
            if (range.min > 0) facts |= FACT_NONZERO_32;
            if (range.max < std.math.maxInt(u32)) facts |= FACT_NOT_NEG_ONE_32;
            if (range.max < 0x80000000 or range.min > 0x80000000) facts |= FACT_NOT_MIN_32;
        } else {
            if (range.min > 0) facts |= FACT_NONZERO_64;
            if (range.max < std.math.maxInt(u64)) facts |= FACT_NOT_NEG_ONE_64;
            if (range.max < 0x8000000000000000 or range.min > 0x8000000000000000) facts |= FACT_NOT_MIN_64;
        }
        return facts;
    }

    fn setLocalFacts(self: *DivideChecker, index: usize, facts: u8) void {
        if (index >= MAX_TRACKED_LOCALS) return;
        self.local_facts[index] = facts;
        self.local_fact_scope[index] = if (facts == 0) 0 else self.control_depth + 1;
    }

    fn setLocalValue(self: *DivideChecker, index: usize, facts: u8, range: ValueRange) void {
        self.setLocalFacts(index, facts | factsFromRange(range));
        if (index >= MAX_TRACKED_LOCALS) return;
        self.local_range_kind[index] = range.kind;
        self.local_range_min[index] = range.min;
        self.local_range_max[index] = range.max;
    }

    fn addLocalRange(self: *DivideChecker, index: usize, range: ValueRange) void {
        if (index >= MAX_TRACKED_LOCALS) return;
        self.local_range_kind[index] = range.kind;
        self.local_range_min[index] = range.min;
        self.local_range_max[index] = range.max;
        self.local_facts[index] |= factsFromRange(range);
        self.local_fact_scope[index] = self.control_depth + 1;
    }

    fn clearInnerFacts(self: *DivideChecker) void {
        const inner_scope = self.control_depth + 1;
        for (&self.local_fact_scope, 0..) |*scope, index| {
            if (scope.* >= inner_scope) {
                scope.* = 0;
                self.local_facts[index] = 0;
                self.local_range_kind[index] = RANGE_UNKNOWN;
            }
        }
    }

    fn clearLoopWrittenFacts(self: *DivideChecker) CheckError!void {
        if (self.loop_index >= MAX_LOOPS) return CheckError.TooDeepControl;
        const written = &loop_written_buf[self.loop_index];
        self.loop_index += 1;
        for (0..MAX_TRACKED_LOCALS) |index| {
            if ((written[index / 8] & (@as(u8, 1) << @intCast(index % 8))) == 0) continue;
            self.local_facts[index] = 0;
            self.local_fact_scope[index] = 0;
            self.local_range_kind[index] = RANGE_UNKNOWN;
            self.removePathFact(index);
        }
    }

    fn pathFactMask(self: *const DivideChecker, index: usize) u8 {
        for (self.path_facts[0..self.path_facts_len]) |fact| {
            if (fact.local == index) return fact.mask;
        }
        return 0;
    }

    fn removePathFact(self: *DivideChecker, index: usize) void {
        var i: usize = 0;
        while (i < self.path_facts_len) {
            if (self.path_facts[i].local != index) {
                i += 1;
                continue;
            }
            self.path_facts_len -= 1;
            self.path_facts[i] = self.path_facts[self.path_facts_len];
        }
    }

    fn addPathFact(self: *DivideChecker, index: usize, fact: u8) void {
        if (index >= MAX_TRACKED_LOCALS) return;
        for (self.path_facts[0..self.path_facts_len]) |*existing| {
            if (existing.local == index) {
                existing.mask |= fact;
                return;
            }
        }
        if (self.path_facts_len >= self.path_facts.len) return;
        self.path_facts[self.path_facts_len] = .{ .local = @intCast(index), .mask = fact };
        self.path_facts_len += 1;
    }

    fn replacePathFacts(self: *DivideChecker, facts: []const GuardFact) void {
        self.path_facts_len = @min(facts.len, self.path_facts.len);
        @memcpy(self.path_facts[0..self.path_facts_len], facts[0..self.path_facts_len]);
    }

    fn intersectPathFacts(self: *DivideChecker, other: []const GuardFact) void {
        var i: usize = 0;
        while (i < self.path_facts_len) {
            var other_mask: u8 = 0;
            for (other) |fact| {
                if (fact.local == self.path_facts[i].local) {
                    other_mask = fact.mask;
                    break;
                }
            }
            self.path_facts[i].mask &= other_mask;
            if (self.path_facts[i].mask == 0) {
                self.path_facts_len -= 1;
                self.path_facts[i] = self.path_facts[self.path_facts_len];
            } else {
                i += 1;
            }
        }
    }

    fn mergeIntoFrame(frame: *PathFrame, facts: []const GuardFact, reachable: bool) void {
        if (!reachable) return;
        if (!frame.pending_reachable) {
            frame.pending_reachable = true;
            frame.pending_len = @min(facts.len, frame.pending.len);
            @memcpy(frame.pending[0..frame.pending_len], facts[0..frame.pending_len]);
            return;
        }

        var i: usize = 0;
        while (i < frame.pending_len) {
            var other_mask: u8 = 0;
            for (facts) |fact| {
                if (fact.local == frame.pending[i].local) {
                    other_mask = fact.mask;
                    break;
                }
            }
            frame.pending[i].mask &= other_mask;
            if (frame.pending[i].mask == 0) {
                frame.pending_len -= 1;
                frame.pending[i] = frame.pending[frame.pending_len];
            } else {
                i += 1;
            }
        }
    }

    fn transferBranch(self: *DivideChecker, depth: u32, facts: []const GuardFact, reachable: bool) CheckError!void {
        const target_depth: usize = @intCast(depth);
        if (target_depth >= self.path_frames_len) {
            if (target_depth == self.path_frames_len) return; // function label
            return CheckError.InvalidWasm;
        }
        const frame = &path_frame_buf[self.path_frames_len - 1 - target_depth];
        if (frame.op == 0x03) return; // a loop branch targets its header
        mergeIntoFrame(frame, facts, reachable);
    }

    fn pushPathFrame(self: *DivideChecker, op: u8) CheckError!void {
        if (self.path_frames_len >= path_frame_buf.len) return CheckError.TooDeepControl;
        path_frame_buf[self.path_frames_len] = .{
            .op = op,
            .entry_reachable = self.path_reachable,
        };
        self.path_frames_len += 1;
        // Full if-arm snapshots are intentionally not retained. Dropping
        // incoming guard facts is conservative and keeps frame memory bounded.
        if (op == 0x04) self.path_facts_len = 0;
    }

    fn mergePathFrameEnd(self: *DivideChecker) CheckError!void {
        if (self.path_frames_len == 0) return CheckError.InvalidWasm;
        const frame = &path_frame_buf[self.path_frames_len - 1];
        if (frame.op == 0x04 and !frame.has_else and frame.entry_reachable) {
            // The untaken arm reaches the end without any retained facts.
            if (self.path_reachable) self.path_facts_len = 0;
            self.path_reachable = true;
        }
        if (frame.pending_reachable) {
            if (self.path_reachable) {
                self.intersectPathFacts(frame.pending[0..frame.pending_len]);
            } else {
                self.replacePathFacts(frame.pending[0..frame.pending_len]);
                self.path_reachable = true;
            }
        }
        self.path_frames_len -= 1;
    }

    fn recordFalseEquality(self: *DivideChecker, value_op: u8, const_op: u8) void {
        const comparison = self.prior(1) orelse return;
        if (comparison.op != value_op) return;

        var local_index: ?usize = null;
        var constant_value: ?i64 = null;
        if (self.localIndex(3)) |index| {
            local_index = index;
            constant_value = self.constant(2, const_op);
        } else if (self.localIndex(2)) |index| {
            local_index = index;
            constant_value = self.constant(3, const_op);
        }
        const index = local_index orelse return;
        const value = constant_value orelse return;

        if (const_op == 0x41) {
            const narrowed: i32 = @intCast(value);
            if (narrowed == 0) self.addPathFact(index, FACT_NONZERO_32);
            if (narrowed == -1) self.addPathFact(index, FACT_NOT_NEG_ONE_32);
            if (narrowed == std.math.minInt(i32)) self.addPathFact(index, FACT_NOT_MIN_32);
        } else {
            if (value == 0) self.addPathFact(index, FACT_NONZERO_64);
            if (value == -1) self.addPathFact(index, FACT_NOT_NEG_ONE_64);
            if (value == std.math.minInt(i64)) self.addPathFact(index, FACT_NOT_MIN_64);
        }
    }

    fn recordBrIfFallthrough(self: *DivideChecker) void {
        const condition = self.prior(1) orelse return;
        if (condition.op == 0x45) { // i32.eqz(local.get)
            if (self.localIndex(2)) |index| self.addPathFact(index, FACT_NONZERO_32);
            return;
        }
        if (condition.op == 0x50) { // i64.eqz(local.get)
            if (self.localIndex(2)) |index| self.addPathFact(index, FACT_NONZERO_64);
            return;
        }
        if (condition.op == 0x48) { // !(local <s positive constant)
            const index = self.localIndex(3) orelse return;
            const lower = self.constant(2, 0x41) orelse return;
            if (lower > 0 and lower <= std.math.maxInt(i32)) {
                self.addLocalRange(index, .{
                    .kind = RANGE_I32,
                    .min = @intCast(lower),
                    .max = std.math.maxInt(i32),
                });
            }
            return;
        }
        if (condition.op == 0x46 and self.constant(2, 0x41) == std.math.minInt(i32)) {
            // Zig lowers `x == 0 or x == MIN` to
            // `(x | MIN) == MIN`. Its false edge excludes both values.
            const bit_or = self.prior(3) orelse return;
            if (bit_or.op == 0x72 and self.constant(4, 0x41) == std.math.minInt(i32)) {
                if (self.localIndex(5)) |index| {
                    self.addPathFact(index, FACT_NONZERO_32 | FACT_NOT_MIN_32);
                    return;
                }
            }
        }
        self.recordFalseEquality(0x46, 0x41); // i32.eq
        self.recordFalseEquality(0x51, 0x42); // i64.eq
    }

    fn proveUnsignedOrRemainder(self: *const DivideChecker, const_op: u8) CheckError!void {
        const kind: u8 = if (const_op == 0x41) RANGE_I32 else RANGE_I64;
        const facts = self.factsForValue(1, const_op) | factsFromRange(self.rangeForValue(1, kind));
        const nonzero = if (const_op == 0x41) FACT_NONZERO_32 else FACT_NONZERO_64;
        if ((facts & nonzero) == 0) return CheckError.DivideMayTrap;
    }

    fn proveSigned(self: *const DivideChecker, const_op: u8) CheckError!void {
        const kind: u8 = if (const_op == 0x41) RANGE_I32 else RANGE_I64;
        const divisor = self.factsForValue(1, const_op) | factsFromRange(self.rangeForValue(1, kind));
        const dividend = self.factsForValue(2, const_op) | factsFromRange(self.rangeForValue(2, kind));
        const nonzero = if (const_op == 0x41) FACT_NONZERO_32 else FACT_NONZERO_64;
        const not_neg_one = if (const_op == 0x41) FACT_NOT_NEG_ONE_32 else FACT_NOT_NEG_ONE_64;
        const not_min = if (const_op == 0x41) FACT_NOT_MIN_32 else FACT_NOT_MIN_64;
        if ((divisor & nonzero) == 0) return CheckError.DivideMayTrap;
        if ((divisor & not_neg_one) == 0 and (dividend & not_min) == 0) {
            return CheckError.DivideMayTrap;
        }
    }

    pub fn onInstr(self: *DivideChecker, instr: Instr) CheckError!void {
        switch (instr.op) {
            0x02, 0x04 => {
                try self.pushPathFrame(instr.op);
                self.control_depth += 1;
            },
            0x03 => {
                // A loop body is analyzed once, but executes repeatedly. Entry
                // facts for locals written later in the body would otherwise
                // be unsound on the next iteration. Clear them until a guard
                // or local expression re-establishes a fact inside the loop.
                try self.clearLoopWrittenFacts();
                try self.pushPathFrame(instr.op);
                self.control_depth += 1;
            },
            0x05 => {
                self.clearInnerFacts();
                if (self.path_frames_len == 0) return CheckError.InvalidWasm;
                const frame = &path_frame_buf[self.path_frames_len - 1];
                if (frame.op != 0x04 or frame.has_else) return CheckError.InvalidWasm;
                mergeIntoFrame(frame, self.path_facts[0..self.path_facts_len], self.path_reachable);
                frame.has_else = true;
                self.path_reachable = frame.entry_reachable;
                self.path_facts_len = 0;
            },
            0x0b => {
                self.clearInnerFacts();
                try self.mergePathFrameEnd();
                self.control_depth -= 1;
            },
            0x0c => {
                try self.transferBranch(@intCast(instr.imm), self.path_facts[0..self.path_facts_len], self.path_reachable);
                self.path_reachable = false;
                self.path_facts_len = 0;
            },
            0x0d => {
                try self.transferBranch(@intCast(instr.imm), self.path_facts[0..self.path_facts_len], self.path_reachable);
                if (self.path_reachable) self.recordBrIfFallthrough();
            },
            0x0e => {
                self.table_reachable = self.path_reachable;
                self.table_facts_len = self.path_facts_len;
                @memcpy(self.table_facts[0..self.table_facts_len], self.path_facts[0..self.path_facts_len]);
                self.path_reachable = false;
                self.path_facts_len = 0;
            },
            0x00, 0x0f, 0x12, 0x13 => {
                self.path_reachable = false;
                self.path_facts_len = 0;
            },
            0x21, 0x22 => {
                const index: usize = @intCast(instr.imm);
                const range32 = self.rangeForValue(1, RANGE_I32);
                const range64 = self.rangeForValue(1, RANGE_I64);
                const range = if (range32.kind != RANGE_UNKNOWN) range32 else range64;
                const facts = self.factsForValue(1, 0x41) | self.factsForValue(1, 0x42);
                self.removePathFact(index);
                if (self.path_reachable and facts != 0) self.addPathFact(index, facts);
                self.setLocalValue(index, facts, range);
            },
            0x6d => if (self.path_reachable) try self.proveSigned(0x41), // i32.div_s
            0x6e => if (self.path_reachable) try self.proveUnsignedOrRemainder(0x41), // i32.div_u
            0x6f, 0x70 => if (self.path_reachable) try self.proveUnsignedOrRemainder(0x41), // i32.rem_s/u
            0x7f => if (self.path_reachable) try self.proveSigned(0x42), // i64.div_s
            0x80 => if (self.path_reachable) try self.proveUnsignedOrRemainder(0x42), // i64.div_u
            0x81, 0x82 => if (self.path_reachable) try self.proveUnsignedOrRemainder(0x42), // i64.rem_s/u
            else => {},
        }
        self.remember(instr);
    }

    pub fn onBrTableTarget(self: *DivideChecker, depth: u32) CheckError!void {
        try self.transferBranch(depth, self.table_facts[0..self.table_facts_len], self.table_reachable);
    }
};

fn parseFunctionCount(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) _ = try r.readVarU32();
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn checkCodeSection(payload: []const u8, defined_functions: u32) CheckError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != defined_functions) return CheckError.FunctionCodeMismatch;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body = try r.readN(try r.readVarU32());
        var finder = LoopWriteFinder{};
        try wasm_reader.walkFunctionBody(&finder, body);
        var checker = DivideChecker{};
        try wasm_reader.walkFunctionBody(&checker, body);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn checkModule(wasm: []const u8) CheckError!void {
    try wasm_reader.checkHeader(wasm);
    var r = Reader.init(wasm[8..]);
    var defined_functions: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const payload = try r.readN(try r.readVarU32());
        switch (section_id) {
            3 => {
                defined_functions = try parseFunctionCount(payload);
                have_function_section = true;
            },
            10 => {
                try checkCodeSection(payload, defined_functions);
                have_code_section = true;
            },
            else => {},
        }
    }
    if (have_function_section != have_code_section) return CheckError.FunctionCodeMismatch;
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

fn expectBodyPasses(comptime body: []const u8) !void {
    const module = wasm_reader.moduleWithBody(body);
    try checkModule(&module);
}

fn expectBodyFails(comptime body: []const u8) !void {
    const module = wasm_reader.moduleWithBody(body);
    try std.testing.expectError(CheckError.DivideMayTrap, checkModule(&module));
}

test "accepts nonzero constant divisors" {
    try expectBodyPasses(&.{ 0x41, 42, 0x41, 3, 0x6e, 0x1a, 0x0b });
    try expectBodyPasses(&.{ 0x42, 42, 0x42, 10, 0x82, 0x1a, 0x0b });
}

test "render rejects an unsafe divide and the instance recovers" {
    const unsafe_module = wasm_reader.moduleWithBody(&.{ 0x41, 42, 0x41, 0, 0x6e, 0x1a, 0x0b });
    @memcpy(input_buf[0..unsafe_module.len], &unsafe_module);
    const rejected = renderOutcome(unsafe_module.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);

    const safe_module = wasm_reader.moduleWithBody(&.{ 0x41, 42, 0x41, 3, 0x6e, 0x1a, 0x0b });
    @memcpy(input_buf[0..safe_module.len], &safe_module);
    const accepted = renderOutcome(safe_module.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, safe_module.len), accepted.output_size_or_failure);
    try std.testing.expectEqualSlices(u8, &safe_module, input_buf[0..safe_module.len]);
}

test "rejects zero and dynamic divisors" {
    try expectBodyFails(&.{ 0x41, 42, 0x41, 0, 0x6e, 0x1a, 0x0b });
    try expectBodyFails(&.{ 0x41, 42, 0x20, 0, 0x6e, 0x1a, 0x0b });
}

test "handles signed overflow separately from remainder" {
    // i32.const MIN is encoded as the signed LEB 80 80 80 80 78.
    try expectBodyFails(&.{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x41, 0x7f, 0x6d, 0x1a, 0x0b });
    try expectBodyPasses(&.{ 0x41, 7, 0x41, 0x7f, 0x6d, 0x1a, 0x0b });
    try expectBodyPasses(&.{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x41, 0x7f, 0x6f, 0x1a, 0x0b });
}

test "accepts a dynamic divisor after a dominating zero guard" {
    try expectBodyPasses(&.{
        0x02, 0x40, // block
        0x20, 0x00, 0x45, 0x0d, 0x00, // local.get 0; eqz; br_if 0
        0x41, 42,   0x20, 0x00, 0x6e, 0x1a, // 42 / local 0
        0x0b, 0x0b,
    });
}

test "does not carry a fallthrough guard across its branch target" {
    try expectBodyFails(&.{
        0x02, 0x40, // block
        0x20, 0x00, 0x45, 0x0d, 0x00, // local.get 0; eqz; br_if 0
        0x0b, // branch target joins here
        0x41,
        42,
        0x20,
        0x00,
        0x6e,
        0x1a,
        0x0b,
    });
}

test "carries a guard through a branch when the other path returns" {
    try expectBodyPasses(&.{
        0x02, 0x40, // outer block
        0x02, 0x40, // inner block
        0x20, 0x00, 0x45, 0x0d, 0x00, // zero enters the return path
        0x0c, 0x01, // nonzero skips the return path
        0x0b,
        0x0f, // the zero path cannot reach the division
        0x0b,
        0x41,
        42,
        0x20,
        0x00,
        0x6e,
        0x1a,
        0x0b,
    });
}

test "signed division also proves the divisor is not minus one" {
    try expectBodyPasses(&.{
        0x02, 0x40,
        0x20, 0x00, 0x45, 0x0d, 0x00, // divisor != 0 on fallthrough
        0x20, 0x00, 0x41, 0x7f, 0x46, 0x0d, 0x00, // divisor != -1
        0x20, 0x01, 0x20, 0x00, 0x6d, 0x1a, 0x0b,
        0x0b,
    });
}

test "propagates non-wrapping ranges through locals and arithmetic" {
    try expectBodyPasses(&.{
        0x41, 0x01, 0x21, 0x00, // local 0 = 1
        0x20, 0x00, 0x41, 0x0a, 0x6c, 0x21, 0x00, // local 0 *= 10
        0x41, 42,   0x20, 0x00, 0x6e, 0x1a, 0x0b,
    });
    try expectBodyPasses(&.{
        0x41, 0x01, 0x21, 0x00,
        0x41, 42,   0x20, 0x00,
        0x41, 0xff, 0xff, 0x03,
        0x71, 0x6e, 0x1a, 0x0b,
    });
}

test "derives an identity range through a low-bit mask" {
    var checker = DivideChecker{};
    checker.setLocalValue(0, 0, .{ .kind = RANGE_I32, .min = 1, .max = 1 });
    checker.remember(.{ .op = 0x20, .imm = 0, .has_imm = true });
    checker.remember(.{ .op = 0x41, .imm = 65535, .has_imm = true });
    checker.remember(.{ .op = 0x71 });
    const left = checker.atomRange(3, RANGE_I32);
    const right = checker.atomRange(2, RANGE_I32);
    try std.testing.expectEqual(@as(u64, 1), left.min);
    try std.testing.expectEqual(@as(u64, 65535), right.min);
    const range = checker.rangeForValue(1, RANGE_I32);
    try std.testing.expectEqual(RANGE_I32, range.kind);
    try std.testing.expectEqual(@as(u64, 1), range.min);
    try std.testing.expectEqual(@as(u64, 1), range.max);
}

test "does not invalidate a local for writes in a different loop" {
    try expectBodyPasses(&.{
        0x41, 0x01, 0x21, 0x00, // local 0 = 1
        0x02, 0x40, 0x03, 0x40, 0x0c, 0x01, 0x0b, 0x0b, // first loop exits
        0x41, 42,   0x20, 0x00, 0x6e, 0x1a,
        0x02, 0x40, 0x03, 0x40, // an unrelated later loop writes local 0
        0x41, 0x00, 0x21, 0x00,
        0x0c, 0x01, 0x0b, 0x0b,
        0x0b,
    });
}

test "drops a range when arithmetic may wrap" {
    try expectBodyFails(&.{
        0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x21, 0x00, // local 0 = 0x80000000
        0x20, 0x00, 0x41, 0x02, 0x6c, 0x21, 0x00, // wrapping result is unknown
        0x41, 42,   0x20, 0x00, 0x6e, 0x1a, 0x0b,
    });
}

test "does not reuse a pre-loop range for later iterations" {
    try expectBodyFails(&.{
        0x41, 0x01, 0x21, 0x00, // local 0 = 1
        0x02, 0x40, 0x03, 0x40, // block; loop
        0x41, 42,   0x20, 0x00,
        0x6e, 0x1a,
        0x41, 0x00, 0x21, 0x00, // a later iteration can see zero
        0x0c, 0x00, 0x0b, 0x0b,
        0x0b,
    });
}
