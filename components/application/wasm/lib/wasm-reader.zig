//! Shared WebAssembly binary decoding for the application/wasm components.
//!
//! This is the single source of truth for instruction immediates: a decode
//! mistake desyncs the byte stream and produces bogus verdicts downstream,
//! and keeping one copy is what prevents the checkers from drifting apart.
//! Policy (which opcodes or sections are allowed) stays in each component;
//! this file only knows how to read the bytes.
//!
//! `walkFunctionBody` drives a caller-supplied handler through every
//! instruction of a function body. The handler sees each instruction once,
//! after its immediates are consumed, as an `Instr` carrying the immediate
//! values the analyses care about (local/global indices, constants, branch
//! depths, call targets). For `call_indirect` and `return_call_indirect`,
//! `imm` is the type index and `imm2` is the table index. `br_table` targets
//! arrive as separate `onBrTableTarget` calls after the instruction itself.
//! The final `end`
//! closing the function is not emitted.

pub const Error = error{
    InvalidWasm,
    UnsupportedVersion,
    UnexpectedEOF,
    InvalidLEB,
    TrailingBytes,
    UnsupportedInstruction,
};

pub const Instr = struct {
    op: u8 = 0,
    imm: i64 = 0,
    has_imm: bool = false,
    imm2: i64 = 0,
    has_imm2: bool = false,
    subop: u32 = 0,
    has_subop: bool = false,
};

pub const Limits = struct {
    memory64: bool,
    shared: bool,
    min: u64,
    has_max: bool,
    max: u64,
};

pub const Reader = struct {
    data: []const u8,
    off: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.off;
    }

    pub fn readByte(self: *Reader) Error!u8 {
        if (self.off >= self.data.len) return Error.UnexpectedEOF;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }

    pub fn peekByte(self: *const Reader) Error!u8 {
        if (self.off >= self.data.len) return Error.UnexpectedEOF;
        return self.data[self.off];
    }

    pub fn readN(self: *Reader, n: usize) Error![]const u8 {
        if (self.remaining() < n) return Error.UnexpectedEOF;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }

    pub fn readVarU32(self: *Reader) Error!u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            if (i == 4) break;
            shift += 7;
        }
        return Error.InvalidLEB;
    }

    pub fn readVarU64(self: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            if (i == 9) break;
            shift += 7;
        }
        return Error.InvalidLEB;
    }

    pub fn readVarS32(self: *Reader) Error!i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < 5) : (i += 1) {
            b = try self.readByte();
            result |= @as(i32, @intCast(b & 0x7f)) << shift;
            if ((b & 0x80) == 0) break;
            if (i == 4) return Error.InvalidLEB;
            shift += 7;
        }
        if (shift < 25 and (b & 0x40) != 0) {
            result |= @as(i32, -1) << (shift + 7);
        }
        return result;
    }

    pub fn readVarS64(self: *Reader, max_bytes: usize) Error!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.readByte();
            result |= @as(i64, @intCast(b & 0x7f)) << shift;
            if ((b & 0x80) == 0) break;
            if (i == max_bytes - 1) return Error.InvalidLEB;
            shift += 7;
        }
        if (shift < 57 and (b & 0x40) != 0) {
            result |= @as(i64, -1) << (shift + 7);
        }
        return result;
    }
};

pub fn checkHeader(wasm: []const u8) Error!void {
    if (wasm.len < 8) return Error.InvalidWasm;
    if (!(wasm[0] == 0x00 and wasm[1] == 0x61 and wasm[2] == 0x73 and wasm[3] == 0x6d)) {
        return Error.InvalidWasm;
    }
    if (!(wasm[4] == 0x01 and wasm[5] == 0x00 and wasm[6] == 0x00 and wasm[7] == 0x00)) {
        return Error.UnsupportedVersion;
    }
}

pub fn readLimits(r: *Reader) Error!Limits {
    const flags = try r.readByte();
    var limits = Limits{
        .memory64 = (flags & 0x04) != 0,
        .shared = (flags & 0x02) != 0,
        .min = 0,
        .has_max = (flags & 0x01) != 0,
        .max = 0,
    };
    if (limits.memory64) {
        limits.min = try r.readVarU64();
        if (limits.has_max) limits.max = try r.readVarU64();
        return limits;
    }
    limits.min = try r.readVarU32();
    if (limits.has_max) limits.max = try r.readVarU32();
    return limits;
}

fn readBlockType(r: *Reader) Error!void {
    const b = try r.peekByte();
    switch (b) {
        0x40, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f => _ = try r.readByte(),
        else => _ = try r.readVarS64(5),
    }
}

fn readMemArg(r: *Reader) Error!void {
    _ = try r.readVarU32();
    _ = try r.readVarU32();
}

fn readFCImmediate(r: *Reader) Error!u32 {
    const sub = try r.readVarU32();
    switch (sub) {
        // i32/i64.trunc_sat_f32/f64_s/u
        0...7 => {},
        // memory.init, memory.copy, table.init, table.copy
        8, 10, 12, 14 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        // data.drop, memory.fill, elem.drop, table.grow, table.size, table.fill
        9, 11, 13, 15, 16, 17 => _ = try r.readVarU32(),
        else => return Error.UnsupportedInstruction,
    }
    return sub;
}

fn readFDImmediate(r: *Reader) Error!u32 {
    const sub = try r.readVarU32();
    switch (sub) {
        // v128.load*/store
        0...11 => try readMemArg(r),
        // v128.const, i8x16.shuffle
        12, 13 => _ = try r.readN(16),
        // extract_lane / replace_lane
        21...34 => _ = try r.readByte(),
        // v128.load/store*_lane
        84...91 => {
            try readMemArg(r);
            _ = try r.readByte();
        },
        // v128.load32_zero, v128.load64_zero
        92, 93 => try readMemArg(r),
        // remaining SIMD and relaxed-SIMD ops have no immediates
        14...20, 35...83, 94...275 => {},
        else => return Error.UnsupportedInstruction,
    }
    return sub;
}

fn readFEImmediate(r: *Reader) Error!u32 {
    const sub = try r.readVarU32();
    if (sub == 3) {
        // atomic.fence reserved immediate
        _ = try r.readByte();
        return sub;
    }
    try readMemArg(r);
    return sub;
}

/// Decodes every instruction of a function body (local declarations
/// included) and reports each one to the handler. The handler must provide:
///
///   fn onInstr(h, instr: Instr) !void
///   fn onBrTableTarget(h, depth: u32) !void
///
/// br_table reports the instruction first (imm = target count), then each
/// target depth including the default. The final end closing the function
/// is not reported.
pub fn walkFunctionBody(handler: anytype, body: []const u8) !void {
    var r = Reader.init(body);

    const local_decls = try r.readVarU32();
    var ld: u32 = 0;
    while (ld < local_decls) : (ld += 1) {
        _ = try r.readVarU32();
        _ = try r.readByte();
    }

    var depth: usize = 0;
    while (true) {
        const op = try r.readByte();
        var instr = Instr{ .op = op };
        switch (op) {
            // unreachable, nop, else, return, drop, select, ref.is_null
            0x00, 0x01, 0x05, 0x0f, 0x1a, 0x1b, 0xd1 => {},
            // block, loop, if
            0x02, 0x03, 0x04 => {
                try readBlockType(&r);
                depth += 1;
            },
            // end
            0x0b => {
                if (depth == 0) {
                    if (r.remaining() != 0) return Error.TrailingBytes;
                    return;
                }
                depth -= 1;
            },
            // br, br_if
            0x0c, 0x0d => {
                const branch_depth = try r.readVarU32();
                instr.imm = branch_depth;
                instr.has_imm = true;
            },
            // br_table
            0x0e => {
                const target_count = try r.readVarU32();
                instr.imm = target_count;
                instr.has_imm = true;
                try handler.onInstr(instr);
                var i: u32 = 0;
                while (i < target_count) : (i += 1) {
                    try handler.onBrTableTarget(try r.readVarU32());
                }
                try handler.onBrTableTarget(try r.readVarU32());
                continue;
            },
            // call, return_call
            0x10, 0x12 => {
                const idx = try r.readVarU32();
                instr.imm = idx;
                instr.has_imm = true;
            },
            // call_indirect, return_call_indirect
            0x11, 0x13 => {
                instr.imm = try r.readVarU32(); // type index
                instr.has_imm = true;
                instr.imm2 = try r.readVarU32(); // table index
                instr.has_imm2 = true;
            },
            // call_ref
            0x14 => _ = try r.readVarU32(),
            // select with types
            0x1c => {
                const count = try r.readVarU32();
                _ = try r.readN(count);
            },
            // local.get/set/tee, global.get/set, table.get/set
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => {
                const idx = try r.readVarU32();
                instr.imm = idx;
                instr.has_imm = true;
            },
            // loads and stores
            0x28...0x3e => try readMemArg(&r),
            // memory.size, memory.grow
            0x3f, 0x40 => _ = try r.readVarU32(),
            // i32.const
            0x41 => {
                const value = try r.readVarS32();
                instr.imm = value;
                instr.has_imm = true;
            },
            // i64.const
            0x42 => {
                const value = try r.readVarS64(10);
                instr.imm = value;
                instr.has_imm = true;
            },
            // f32.const, f64.const
            0x43 => _ = try r.readN(4),
            0x44 => _ = try r.readN(8),
            // numeric ops through i64.extend32_s: no immediates
            0x45...0xc4 => {},
            // ref.null
            0xd0 => _ = try r.readByte(),
            // ref.func
            0xd2 => _ = try r.readVarU32(),
            0xfc => {
                instr.subop = try readFCImmediate(&r);
                instr.has_subop = true;
            },
            0xfd => {
                instr.subop = try readFDImmediate(&r);
                instr.has_subop = true;
            },
            0xfe => {
                instr.subop = try readFEImmediate(&r);
                instr.has_subop = true;
            },
            else => return Error.UnsupportedInstruction,
        }
        try handler.onInstr(instr);
    }
}

// ---------------------------------------------------------------------------
// Test helpers shared by the checker components.
// ---------------------------------------------------------------------------

pub fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(hex.len * 8);
    var out: [hex.len / 2]u8 = undefined;
    for (&out, 0..) |*b, i| {
        b.* = (hexNibble(hex[2 * i]) << 4) | hexNibble(hex[2 * i + 1]);
    }
    return out;
}

fn hexNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => unreachable,
    };
}

/// Wraps a () -> () function body (without local declarations) in a module
/// with one function and a fixed one-page memory.
pub fn moduleWithBody(comptime body_ops: []const u8) [29 + body_ops.len]u8 {
    const body_len: u8 = @intCast(body_ops.len + 1);
    return [_]u8{
        0x00, 0x61,         0x73, 0x6d,     0x01, 0x00, 0x00, 0x00,
        0x01, 0x04,         0x01, 0x60,     0x00, 0x00, 0x03, 0x02,
        0x01, 0x00,         0x05, 0x04,     0x01, 0x01, 0x01, 0x01,
        0x0a, body_len + 2, 0x01, body_len, 0x00,
    } ++ body_ops[0..body_ops.len].*;
}

const std = @import("std");

const CountingHandler = struct {
    instrs: usize = 0,
    targets: usize = 0,

    fn onInstr(self: *CountingHandler, instr: Instr) Error!void {
        _ = instr;
        self.instrs += 1;
    }

    fn onBrTableTarget(self: *CountingHandler, depth: u32) Error!void {
        _ = depth;
        self.targets += 1;
    }
};

test "walk reports instructions and br_table targets" {
    // block; i32.const 0; br_table [0] default 0; end; end
    const body = [_]u8{ 0x00, 0x02, 0x40, 0x41, 0x00, 0x0e, 0x01, 0x00, 0x00, 0x0b, 0x0b };
    var h = CountingHandler{};
    try walkFunctionBody(&h, &body);
    try std.testing.expectEqual(@as(usize, 4), h.instrs);
    try std.testing.expectEqual(@as(usize, 2), h.targets);
}

test "walk rejects trailing bytes after the final end" {
    const body = [_]u8{ 0x00, 0x0b, 0x0b };
    var h = CountingHandler{};
    try std.testing.expectError(Error.TrailingBytes, walkFunctionBody(&h, &body));
}

test "walk decodes bulk memory and saturating truncation immediates" {
    // memory.copy 0 0; memory.fill 0; i32.trunc_sat_f32_s has no immediates
    const body = [_]u8{
        0x00,
        0x41,
        0x00,
        0x41,
        0x10,
        0x41,
        0x08,
        0xfc,
        0x0a,
        0x00,
        0x00,
        0x41,
        0x00,
        0x41,
        0x00,
        0x41,
        0x08,
        0xfc,
        0x0b,
        0x00,
        0x43,
        0x00,
        0x00,
        0xc0,
        0x3f,
        0xfc,
        0x00,
        0x1a,
        0x0b,
    };
    var h = CountingHandler{};
    try walkFunctionBody(&h, &body);
    try std.testing.expectEqual(@as(usize, 11), h.instrs);
}
