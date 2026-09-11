//! wasm-bounded-output: a QIP component that certifies the successful return
//! output size in a Content component's `render(i32) -> i64` result is within its declared
//! output capacity.
//!
//! The checker deliberately recognizes a small proof-carrying epilogue rather
//! than attempting whole-program range analysis. A dynamic result must be
//! copied to a local, compared unsigned against the exact static value exported
//! by `output_utf8_cap()` or `output_bytes_cap()`, and trap when it is greater:
//!
//!   ;; Pack $pointer and the guarded $size into the i64 render result.
//!   i32.const OUTPUT_CAP  ;; or global.get of an immutable OUTPUT_CAP
//!   i32.gt_u
//!   if
//!     unreachable
//!   end
//!   local.get $size
//!
//! A constant successful result no greater than the capacity is also accepted.
//! Explicit returns and branches to the function label are rejected, ensuring
//! every successful exit passes through the recognized final proof. The
//! checker proves the returned byte count only; other QIP ABI and artifact
//! rules belong to the normal contract validator and wasm-strict-profile.
//!
//! Input is a Wasm module; output is the same bytes on success. `render`
//! rejects when the proof is absent or malformed.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_TYPES: usize = 4096;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_GLOBALS: usize = 4096;
const TRACE_LEN: usize = 64;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};
var type_buf: [MAX_TYPES]FuncType = undefined;
var func_type_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var function_body_buf: [MAX_DEFINED_FUNCS][]const u8 = undefined;
var global_buf: [MAX_GLOBALS]StaticGlobal = undefined;

const FuncType = struct {
    param_count: u32 = 0,
    first_param_type: u8 = 0,
    result_count: u32 = 0,
    result_type: u8 = 0,
};

const StaticGlobal = struct {
    is_static_i32: bool = false,
    value: u32 = 0,
};

const FunctionExport = union(enum) {
    missing,
    function: u32,
    invalid,
};

const OutputExports = struct {
    render: FunctionExport = .missing,
    utf8_cap: FunctionExport = .missing,
    bytes_cap: FunctionExport = .missing,
};

const CheckError = wasm_reader.Error || error{
    ImportNotSupported,
    TooManyTypes,
    TooManyFunctions,
    TooManyGlobals,
    FunctionCodeMismatch,
    RenderExportMissing,
    RenderExportInvalid,
    RenderSignatureInvalid,
    OutputCapacityMissing,
    OutputCapacityAmbiguous,
    OutputCapacityExportInvalid,
    OutputCapacitySignatureInvalid,
    OutputCapacityNotStatic,
    OutputCapacityGlobalNotStatic,
    OutputBoundNotProven,
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

fn parseTypeSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_TYPES) return CheckError.TooManyTypes;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (try r.readByte() != 0x60) return CheckError.InvalidWasm;
        const param_count = try r.readVarU32();
        var first_param_type: u8 = 0;
        if (param_count > 0) {
            first_param_type = try r.readByte();
            if (param_count > 1) _ = try r.readN(param_count - 1);
        }
        const result_count = try r.readVarU32();
        var result_type: u8 = 0;
        if (result_count > 0) {
            result_type = try r.readByte();
            if (result_count > 1) _ = try r.readN(result_count - 1);
        }
        type_buf[i] = .{
            .param_count = param_count,
            .first_param_type = first_param_type,
            .result_count = result_count,
            .result_type = result_type,
        };
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn parseImportSection(payload: []const u8) CheckError!void {
    var r = Reader.init(payload);
    if (try r.readVarU32() != 0) return CheckError.ImportNotSupported;
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseFunctionSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        func_type_buf[i] = try r.readVarU32();
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn readInitExpr(r: *Reader, prior_global_count: u32) CheckError!StaticGlobal {
    const op = try r.readByte();
    var result = StaticGlobal{};
    switch (op) {
        0x41 => result = .{
            .is_static_i32 = true,
            .value = @bitCast(try r.readVarS32()),
        },
        0x42 => _ = try r.readVarS64(10),
        0x43 => _ = try r.readN(4),
        0x44 => _ = try r.readN(8),
        0x23 => {
            const index = try r.readVarU32();
            if (index < prior_global_count and global_buf[index].is_static_i32) {
                result = global_buf[index];
            }
        },
        0xd0 => _ = try r.readVarS64(5),
        0xd2 => _ = try r.readVarU32(),
        0xfd => {
            if (try r.readVarU32() != 12) return CheckError.InvalidWasm;
            _ = try r.readN(16);
        },
        else => return CheckError.InvalidWasm,
    }
    if (try r.readByte() != 0x0b) return CheckError.InvalidWasm;
    return result;
}

fn parseGlobalSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_GLOBALS) return CheckError.TooManyGlobals;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const value_type = try r.readByte();
        const mutable = try r.readByte();
        const initial = try readInitExpr(&r, i);
        global_buf[i] = if (value_type == 0x7f and mutable == 0) initial else .{};
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn exportSlot(exports: *OutputExports, name: []const u8) ?*FunctionExport {
    if (std.mem.eql(u8, name, "render")) return &exports.render;
    if (std.mem.eql(u8, name, "output_utf8_cap")) return &exports.utf8_cap;
    if (std.mem.eql(u8, name, "output_bytes_cap")) return &exports.bytes_cap;
    return null;
}

fn parseExportSection(payload: []const u8, exports: *OutputExports) CheckError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_len = try r.readVarU32();
        const name = try r.readN(name_len);
        const kind = try r.readByte();
        const index = try r.readVarU32();
        const slot = exportSlot(exports, name) orelse continue;
        slot.* = if (kind == 0x00) .{ .function = index } else .invalid;
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseCodeSection(payload: []const u8, defined_func_count: u32) CheckError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != defined_func_count) return CheckError.FunctionCodeMismatch;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body_size = try r.readVarU32();
        function_body_buf[i] = try r.readN(body_size);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn functionIndex(target: FunctionExport, missing: CheckError, invalid: CheckError) CheckError!u32 {
    return switch (target) {
        .missing => missing,
        .invalid => invalid,
        .function => |index| index,
    };
}

fn functionType(index: u32, type_count: u32, defined_func_count: u32, invalid: CheckError) CheckError!FuncType {
    if (index >= defined_func_count) return invalid;
    const type_index = func_type_buf[index];
    if (type_index >= type_count) return invalid;
    return type_buf[type_index];
}

fn resolveStaticCapacity(
    target: FunctionExport,
    type_count: u32,
    defined_func_count: u32,
    global_count: u32,
) CheckError!u32 {
    const index = try functionIndex(
        target,
        CheckError.OutputCapacityMissing,
        CheckError.OutputCapacityExportInvalid,
    );
    const func_type = try functionType(
        index,
        type_count,
        defined_func_count,
        CheckError.OutputCapacitySignatureInvalid,
    );
    if (func_type.param_count != 0 or func_type.result_count != 1 or func_type.result_type != 0x7f) {
        return CheckError.OutputCapacitySignatureInvalid;
    }

    var r = Reader.init(function_body_buf[index]);
    if (try r.readVarU32() != 0) return CheckError.OutputCapacityNotStatic;
    const op = try r.readByte();
    const value: u32 = switch (op) {
        0x41 => @bitCast(try r.readVarS32()),
        0x23 => blk: {
            const global_index = try r.readVarU32();
            if (global_index >= global_count or !global_buf[global_index].is_static_i32) {
                return CheckError.OutputCapacityGlobalNotStatic;
            }
            break :blk global_buf[global_index].value;
        },
        else => return CheckError.OutputCapacityNotStatic,
    };
    if (try r.readByte() != 0x0b or r.remaining() != 0) {
        return CheckError.OutputCapacityNotStatic;
    }
    return value;
}

const ProofHandler = struct {
    recent: [TRACE_LEN]Instr = undefined,
    recent_depth: [TRACE_LEN]usize = undefined,
    recent_len: usize = 0,
    control_depth: usize = 0,
    has_escaping_exit: bool = false,
    escaping_exit_count: usize = 0,

    fn append(self: *ProofHandler, instr: Instr, depth: usize) void {
        if (self.recent_len < TRACE_LEN) {
            self.recent[self.recent_len] = instr;
            self.recent_depth[self.recent_len] = depth;
            self.recent_len += 1;
            return;
        }
        var i: usize = 1;
        while (i < TRACE_LEN) : (i += 1) {
            self.recent[i - 1] = self.recent[i];
            self.recent_depth[i - 1] = self.recent_depth[i];
        }
        self.recent[TRACE_LEN - 1] = instr;
        self.recent_depth[TRACE_LEN - 1] = depth;
    }

    pub fn onInstr(self: *ProofHandler, instr: Instr) CheckError!void {
        const depth = self.control_depth;
        switch (instr.op) {
            0x02, 0x03, 0x04 => self.control_depth += 1,
            0x0b => {
                if (self.control_depth > 0) self.control_depth -= 1;
            },
            0x0f, 0x12, 0x13 => {
                self.has_escaping_exit = true;
                self.escaping_exit_count += 1;
            },
            0x0c, 0x0d => {
                const branch_depth: usize = @intCast(instr.imm);
                if (branch_depth >= self.control_depth) {
                    self.has_escaping_exit = true;
                    self.escaping_exit_count += 1;
                }
            },
            else => {},
        }
        self.append(instr, depth);
    }

    pub fn onBrTableTarget(self: *ProofHandler, depth: u32) CheckError!void {
        if (depth >= self.control_depth) {
            self.has_escaping_exit = true;
            self.escaping_exit_count += 1;
        }
    }
};

fn isOp(instr: Instr, op: u8) bool {
    return instr.op == op;
}

fn i32ImmediateBits(instr: Instr) u32 {
    return @bitCast(@as(i32, @intCast(instr.imm)));
}

fn i64ImmediateBits(instr: Instr) u64 {
    return @bitCast(instr.imm);
}

fn isCapacityOperand(instr: Instr, capacity: u32, global_count: u32) bool {
    if (instr.op == 0x41) return i32ImmediateBits(instr) == capacity;
    if (instr.op != 0x23) return false;
    const index: u32 = @intCast(instr.imm);
    return index < global_count and
        global_buf[index].is_static_i32 and
        global_buf[index].value == capacity;
}

fn hasPackedLocalResult(recent: []const Instr, start: usize, end: usize, local: i64) bool {
    var i = start;
    while (i < end) : (i += 1) {
        if ((recent[i].op == 0x21 or recent[i].op == 0x22) and recent[i].imm == local) return false;
        if (i >= 4 and
            recent[i - 4].op == 0xad and
            recent[i - 3].op == 0x42 and recent[i - 3].imm == 32 and
            recent[i - 2].op == 0x86 and
            recent[i - 1].op == 0x20 and recent[i - 1].imm == local and
            recent[i].op == 0xad and
            i + 1 < end and recent[i + 1].op == 0x84)
        {
            return true;
        }
    }
    return false;
}

fn provesFinalResult(recent: []const Instr, recent_depth: []const usize, capacity: u32, global_count: u32) bool {
    if (recent.len == 0) return false;

    const last = recent[recent.len - 1];
    if (last.op == 0x42) {
        const result = i64ImmediateBits(last);
        return (result >> 63) == 1 or @as(u32, @truncate(result)) <= capacity;
    }

    // Find a final top-level size guard, then require the same unchanged local
    // in the low 32 bits of the packed i64 result. The pointer expression is
    // extended and shifted left by 32 bits before the two fields are combined.
    var guard_start: usize = 0;
    while (guard_start + 5 < recent.len) : (guard_start += 1) {
        const proof = recent[guard_start .. guard_start + 6];
        if (!(recent_depth[guard_start] == 0 and
            recent_depth[guard_start + 1] == 0 and
            recent_depth[guard_start + 2] == 0 and
            recent_depth[guard_start + 3] == 0 and
            recent_depth[guard_start + 4] == 1 and
            recent_depth[guard_start + 5] == 1)) continue;
        if (!(isOp(proof[3], 0x04) and
            isOp(proof[4], 0x00) and
            isOp(proof[5], 0x0b))) continue;

        var size_local: ?i64 = null;
        // size > capacity
        if (proof[0].op == 0x20 and
            isCapacityOperand(proof[1], capacity, global_count) and
            proof[2].op == 0x4b)
        {
            size_local = proof[0].imm;
        }
        // capacity < size
        if (isCapacityOperand(proof[0], capacity, global_count) and
            proof[1].op == 0x20 and
            proof[2].op == 0x49)
        {
            size_local = proof[1].imm;
        }
        const local = size_local orelse continue;

        if (hasPackedLocalResult(recent, guard_start + 6, recent.len, local)) return true;
    }

    return false;
}

fn provesBranchedTrapResult(recent: []const Instr, recent_depth: []const usize, capacity: u32) bool {
    if (capacity == std.math.maxInt(u32)) return false;
    var guard_start: usize = 0;
    while (guard_start + 7 < recent.len) : (guard_start += 1) {
        if (!(recent_depth[guard_start] == 1 and
            recent_depth[guard_start + 1] == 1 and
            recent_depth[guard_start + 2] == 1 and
            recent_depth[guard_start + 3] == 1)) continue;
        var block_start = guard_start;
        while (block_start > 0) {
            block_start -= 1;
            if (recent_depth[block_start] == 0) break;
        }
        if (recent_depth[block_start] != 0 or recent[block_start].op != 0x02) continue;
        const size = recent[guard_start];
        if (!((size.op == 0x20 or size.op == 0x22) and
            recent[guard_start + 1].op == 0x41 and
            i32ImmediateBits(recent[guard_start + 1]) == capacity + 1 and
            recent[guard_start + 2].op == 0x4f and
            recent[guard_start + 3].op == 0x0d and
            recent[guard_start + 3].imm == 0)) continue;

        var return_index = guard_start + 4;
        while (return_index < recent.len and recent[return_index].op != 0x0f) : (return_index += 1) {}
        if (return_index + 2 >= recent.len or
            recent_depth[return_index] != 1 or
            recent[return_index + 1].op != 0x0b or recent_depth[return_index + 1] != 1 or
            recent[return_index + 2].op != 0x00 or recent_depth[return_index + 2] != 0)
        {
            continue;
        }
        if (hasPackedLocalResult(recent, guard_start + 4, return_index, size.imm)) return true;
    }
    return false;
}

fn validateRender(
    target: FunctionExport,
    capacity: u32,
    type_count: u32,
    defined_func_count: u32,
    global_count: u32,
) CheckError!void {
    const index = try functionIndex(
        target,
        CheckError.RenderExportMissing,
        CheckError.RenderExportInvalid,
    );
    const func_type = try functionType(
        index,
        type_count,
        defined_func_count,
        CheckError.RenderSignatureInvalid,
    );
    if (func_type.param_count != 1 or
        func_type.first_param_type != 0x7f or
        func_type.result_count != 1 or
        func_type.result_type != 0x7e)
    {
        return CheckError.RenderSignatureInvalid;
    }

    var handler = ProofHandler{};
    try wasm_reader.walkFunctionBody(&handler, function_body_buf[index]);
    const recent = handler.recent[0..handler.recent_len];
    const recent_depth = handler.recent_depth[0..handler.recent_len];
    const conventional = !handler.has_escaping_exit and
        provesFinalResult(recent, recent_depth, capacity, global_count);
    const branched_trap = handler.escaping_exit_count == 1 and
        provesBranchedTrapResult(recent, recent_depth, capacity);
    if (!conventional and !branched_trap) {
        return CheckError.OutputBoundNotProven;
    }
}

fn checkModule(wasm: []const u8) CheckError!void {
    try wasm_reader.checkHeader(wasm);

    var r = Reader.init(wasm[8..]);
    var type_count: u32 = 0;
    var defined_func_count: u32 = 0;
    var global_count: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;
    var exports = OutputExports{};

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);
        switch (section_id) {
            0 => {},
            1 => type_count = try parseTypeSection(payload),
            2 => try parseImportSection(payload),
            3 => {
                defined_func_count = try parseFunctionSection(payload);
                have_function_section = true;
            },
            6 => global_count = try parseGlobalSection(payload),
            7 => try parseExportSection(payload, &exports),
            10 => {
                try parseCodeSection(payload, defined_func_count);
                have_code_section = true;
            },
            else => {},
        }
    }

    if (!have_function_section or !have_code_section) return CheckError.InvalidWasm;
    const has_utf8 = exports.utf8_cap != .missing;
    const has_bytes = exports.bytes_cap != .missing;
    if (!has_utf8 and !has_bytes) return CheckError.OutputCapacityMissing;
    if (has_utf8 and has_bytes) return CheckError.OutputCapacityAmbiguous;
    const capacity = try resolveStaticCapacity(
        if (has_utf8) exports.utf8_cap else exports.bytes_cap,
        type_count,
        defined_func_count,
        global_count,
    );
    try validateRender(exports.render, capacity, type_count, defined_func_count, global_count);
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

const hexBytes = wasm_reader.hexBytes;

// (module
//   (memory (export "memory") 1 1)
//   (func (export "output_utf8_cap") (result i32) (i32.const 100))
//   (func (export "render") (param i32) (result i64) (local i32)
//     local.get 0 local.set 1
//     local.get 1 i32.const 100 i32.gt_u
//     if unreachable end
//     i32.const 200 i64.extend_i32_u i64.const 32 i64.shl
//     local.get 1 i64.extend_i32_u i64.or))
const guarded_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a2502050041e4000b1d01017f20002101200141e4004b" ++
        "0440000b41c801ad4220862001ad840b",
);

const unguarded_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a1502050041e4000b0d0041c801ad4220862000ad840b",
);

const wrong_capacity_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072603066d656d6f72790200106f75747075745f62797465735f6361700000" ++
        "0672656e64657200010a2502050041e4000b1d01017f20002101200141e500" ++
        "4b0440000b41c801ad4220862001ad840b",
);

const early_return_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a2d02050041e4000b2501017f2000044042000f0b2000" ++
        "2101200141e4004b0440000b41c801ad4220862001ad840b",
);

// Zig lowers `if (size > capacity) @trap()` to an equivalent final block:
// branch out when `size >= capacity + 1`, return on the in-bound path, and
// trap immediately after the block.
const branched_trap_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a2802050041e4000b2001017f200021010240200141e5" ++
        "004f0d0041c801ad4220862001ad840f0b000b",
);

const branched_trap_wrong_limit_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a2802050041e4000b2001017f200021010240200141e4" ++
        "004f0d0041c801ad4220862001ad840f0b000b",
);

const branched_loop_module = hexBytes(
    "0061736d01000000010a026000017f60017f017e0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a2802050041e4000b2001017f200021010340200141e5" ++
        "004f0d0041c801ad4220862001ad840f0b000b",
);

test "accepts an exact guarded output bound" {
    try checkModule(&guarded_module);
}

test "accepts Zig's equivalent branch-to-trap output bound" {
    try checkModule(&branched_trap_module);
}

test "render rejects an unproved output and the instance recovers" {
    @memcpy(input_buf[0..unguarded_module.len], &unguarded_module);
    const rejected = renderOutcome(unguarded_module.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);

    @memcpy(input_buf[0..guarded_module.len], &guarded_module);
    const accepted = renderOutcome(guarded_module.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, guarded_module.len), accepted.output_size_or_failure);
    try std.testing.expectEqualSlices(u8, &guarded_module, input_buf[0..guarded_module.len]);
}

test "rejects an unguarded dynamic result" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&unguarded_module));
}

test "rejects a guard against a different capacity" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&wrong_capacity_module));
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&branched_trap_wrong_limit_module));
}

test "rejects a bound that loops instead of trapping" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&branched_loop_module));
}

test "rejects a path returning before the guard" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&early_return_module));
}
