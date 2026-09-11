//! Translate a bounded QIP Content component to one C11 header.
//!
//! Supported profile:
//! - One defined wasm32 memory with a declared maximum. Generated code uses the
//!   fixed initial size and checks every memory access.
//! - Core 1.0 structured control flow, scalar integer instructions, globals,
//!   direct calls, and single-value function and block results.
//! - Core 1.0 scalar floating-point instructions except `f32.nearest`,
//!   `f64.nearest`, `f32.min`, `f64.min`, `f32.max`, and `f64.max`.
//! - One fixed funcref table, active function-index element segments, and
//!   `call_indirect` with bounds, null, structural type, and call-depth checks.
//! - Active and passive data segments, saturating float-to-integer conversions,
//!   sign extension, `memory.size`, `memory.copy`, `memory.fill`, `memory.init`,
//!   and `data.drop`.
//! - Recoverable numeric and memory traps, caller-owned memory, shared-workspace
//!   turnover, and optional dirty-page tracking.
//!
//! Explicitly disabled or not implemented:
//! - Imports, WASI, host callbacks, and start functions.
//! - `memory.grow`, shared memory, threads, and atomic instructions.
//! - Multiple memories or tables, table mutation, table bulk operations,
//!   general reference instructions, and externref.
//! - Multi-value functions and blocks, and type-index block signatures.
//! - SIMD and post-Core-2.0 features such as exceptions and tail calls.
//! - The six floating-point operations named above.
//!
//! Unsupported sections and instructions fail closed. See
//! docs/qip-component-to-c.md for the generated API and runtime contract.
//!
//! TODO(code-generation performance): treat the following as hypotheses and
//! measure them independently. WABT's C writer gives the native compiler typed
//! scalar stack variables and typed calls, while this implementation currently
//! emits `qip_val` stack/local arrays plus a runtime `sp`. Clang may already
//! remove part of that machinery, so generated-C shape alone is not evidence of
//! a useful end-to-end improvement.
//!
//! Measurement protocol:
//! - Change one lowering decision at a time and retain the previous translator
//!   as an executable baseline.
//! - Compile all generated C with the same compiler, flags, explicit-bounds
//!   policy, and dirty-tracking policy. Compare WABT's explicit-bounds mode;
//!   guard pages answer a different question.
//! - Require byte-identical Content output and run the trap, table, stale
//!   instance, workspace-turnover, and bundle tests before timing.
//! - Measure warmed time, RSS checkpoints, linear-memory size, and stripped
//!   artifact size with `tools/bench-qip-component-to-c-source.sh` and
//!   `tools/bench-qip-component-to-c-recipe.sh`. Measure fresh-process latency with the
//!   source harness until the recipe harness grows an equivalent mode.
//! - Include at least a parser such as CommonMark and an image recipe with a
//!   large intermediate. Record a dirty-tracking-disabled diagnostic separately
//!   so code-generation changes are not confused with workspace accounting.
//! - Inspect optimized assembly when a C-level change does not move wall time;
//!   keep only improvements that repeat beyond benchmark noise or materially
//!   simplify the generated runtime without weakening its checks.
//!
//! Candidate experiments:
//! 1. Track the validated Wasm operand stack during translation and assign each
//!    stack position a typed C temporary.
//! 2. Replace union-backed Wasm locals with typed C locals. Initialize every
//!    semantically observable local to zero, but omit unused locals and avoid
//!    clearing parameters or dead storage.
//! 3. Give direct calls typed C parameters and return values instead of copying
//!    arguments through temporary `qip_val` arrays. Keep `call_indirect` type
//!    validation and dispatch behavior unchanged.
//! 4. Use the translated maximum stack depth, which now sizes each operand
//!    array, to assign stack positions to C temporaries. At control-flow joins,
//!    emit only the value moves required by block results and eliminate runtime
//!    `sp` updates and normalization where the validated stack shape is static.
//! 5. Measure whether inlining or specializing scalar load/store helpers lets
//!    Clang remove repeated address arithmetic. Preserve complete widened range
//!    checks before every access.
//! 6. Measure cheaper representations of dirty-page marking separately from
//!    instruction lowering. Every possible write must remain tracked when dirty
//!    tracking is enabled.
//! 7. Measure alternative placements or inlining of call-depth accounting.
//!    Preserve the same runtime limit and recoverable trap behavior, including
//!    for indirect recursion.
//!
//! Non-negotiable behavior for these experiments: explicit memory bounds,
//! dirty-page correctness, WebAssembly numeric traps, table/type checks,
//! recoverable trap status, and runtime call-depth exhaustion.

const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
const MAX_TYPES: usize = 4096;
const MAX_TYPE_VALUES: usize = 32768;
const MAX_FUNCTIONS: usize = 8192;
const MAX_GLOBALS: usize = 4096;
const MAX_EXPORTS: usize = 512;
const MAX_DATA_SEGMENTS: usize = 1024;
const MAX_CONTROLS: usize = 4096;
const MAX_STACK_VALUES: u32 = 65536;
const MAX_TABLE_ELEMENTS: usize = 16384;

const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/x-c";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
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

const Error = error{
    InvalidWasm,
    UnexpectedEof,
    InvalidLeb,
    InvalidType,
    InvalidSection,
    InvalidIndex,
    InvalidControl,
    StackUnderflow,
    StackMismatch,
    UnsupportedFeature,
    TooManyItems,
    MissingMemory,
    MissingExport,
    InvalidContentContract,
    ContentGetterNotStatic,
    InputDataOverlap,
    OutputTooLarge,
};

const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
};

const FuncType = struct {
    params_off: u32,
    params_len: u32,
    result: ?ValType,
};

const Function = struct {
    type_index: u32,
    body: []const u8 = &.{},
};

const Value = union {
    u32_: u32,
    u64_: u64,
};

const Global = struct {
    value_type: ValType,
    mutable: bool,
    initial: Value,
};

const Export = struct {
    name: []const u8,
    kind: u8,
    index: u32,
};

const DataSegment = struct {
    passive: bool,
    offset: u32,
    bytes: []const u8,
};

var types: [MAX_TYPES]FuncType = undefined;
var type_count: usize = 0;
var type_values: [MAX_TYPE_VALUES]ValType = undefined;
var type_value_count: usize = 0;
var functions: [MAX_FUNCTIONS]Function = undefined;
var function_count: usize = 0;
var globals: [MAX_GLOBALS]Global = undefined;
var global_count: usize = 0;
var exports: [MAX_EXPORTS]Export = undefined;
var export_count: usize = 0;
var data_segments: [MAX_DATA_SEGMENTS]DataSegment = undefined;
var data_count: usize = 0;
var memory_min_pages: u32 = 0;
var memory_max_pages: u32 = 0;
var table_size: u32 = 0;
var table_elements: [MAX_TABLE_ELEMENTS]u32 = undefined;

const Reader = struct {
    data: []const u8,
    off: usize = 0,

    fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.off;
    }

    fn byte(self: *Reader) Error!u8 {
        if (self.off >= self.data.len) return Error.UnexpectedEof;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }

    fn peek(self: *const Reader) Error!u8 {
        if (self.off >= self.data.len) return Error.UnexpectedEof;
        return self.data[self.off];
    }

    fn bytes(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return Error.UnexpectedEof;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }

    fn varU32(self: *Reader) Error!u32 {
        var result: u32 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.byte();
            if (i == 4 and (b & 0xf0) != 0) return Error.InvalidLeb;
            result |= @as(u32, b & 0x7f) << @intCast(shift);
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return Error.InvalidLeb;
    }

    fn signed(self: *Reader, comptime bits: u7, comptime max_bytes: usize) Error!i64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.byte();
            const payload = b & 0x7f;
            if (i == max_bytes - 1) {
                const used: u3 = @intCast(bits - shift);
                const low_mask: u8 = (@as(u8, 1) << used) - 1;
                const high_mask: u8 = 0x7f ^ low_mask;
                const sign_bit: u8 = @as(u8, 1) << (used - 1);
                const expected: u8 = if ((payload & sign_bit) == 0) 0 else high_mask;
                if ((payload & high_mask) != expected) return Error.InvalidLeb;
            }
            result |= @as(u64, payload) << @intCast(shift);
            shift += 7;
            if ((b & 0x80) == 0) {
                if ((b & 0x40) != 0 and shift < 64) result |= ~@as(u64, 0) << @intCast(shift);
                if (bits == 32) return @as(i32, @bitCast(@as(u32, @truncate(result))));
                return @bitCast(result);
            }
        }
        return Error.InvalidLeb;
    }

    fn s32(self: *Reader) Error!i32 {
        return @intCast(try self.signed(32, 5));
    }

    fn s64(self: *Reader) Error!i64 {
        return try self.signed(64, 10);
    }

    fn name(self: *Reader) Error![]const u8 {
        return self.bytes(try self.varU32());
    }

    fn fixedU32(self: *Reader) Error!u32 {
        const raw = try self.bytes(4);
        return std.mem.readInt(u32, @ptrCast(raw.ptr), .little);
    }

    fn fixedU64(self: *Reader) Error!u64 {
        const raw = try self.bytes(8);
        return std.mem.readInt(u64, @ptrCast(raw.ptr), .little);
    }
};

fn valType(b: u8) Error!ValType {
    return switch (b) {
        0x7f => .i32,
        0x7e => .i64,
        0x7d => .f32,
        0x7c => .f64,
        else => Error.InvalidType,
    };
}

fn resetModule() void {
    type_count = 0;
    type_value_count = 0;
    function_count = 0;
    global_count = 0;
    export_count = 0;
    data_count = 0;
    memory_min_pages = 0;
    memory_max_pages = 0;
    table_size = 0;
    @memset(&table_elements, std.math.maxInt(u32));
}

fn parseTypeSection(r: *Reader) Error!void {
    const count = try r.varU32();
    if (count > MAX_TYPES) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (try r.byte() != 0x60) return Error.InvalidType;
        const params_len = try r.varU32();
        if (params_len > MAX_TYPE_VALUES - type_value_count) return Error.TooManyItems;
        const params_off = type_value_count;
        var p: u32 = 0;
        while (p < params_len) : (p += 1) {
            type_values[type_value_count] = try valType(try r.byte());
            type_value_count += 1;
        }
        const results_len = try r.varU32();
        if (results_len > 1) return Error.UnsupportedFeature;
        const result = if (results_len == 1) try valType(try r.byte()) else null;
        types[type_count] = .{
            .params_off = @intCast(params_off),
            .params_len = params_len,
            .result = result,
        };
        type_count += 1;
    }
}

fn parseFunctionSection(r: *Reader) Error!void {
    const count = try r.varU32();
    if (count > MAX_FUNCTIONS) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const type_index = try r.varU32();
        if (type_index >= type_count) return Error.InvalidIndex;
        functions[function_count] = .{ .type_index = type_index };
        function_count += 1;
    }
}

fn parseMemorySection(r: *Reader) Error!void {
    if (try r.varU32() != 1) return Error.MissingMemory;
    const flags = try r.byte();
    if (flags != 1) return Error.UnsupportedFeature;
    memory_min_pages = try r.varU32();
    memory_max_pages = try r.varU32();
    if (memory_min_pages > memory_max_pages or memory_max_pages > 65536) return Error.InvalidSection;
}

fn parseTableSection(r: *Reader) Error!void {
    if (try r.varU32() != 1 or try r.byte() != 0x70) return Error.UnsupportedFeature;
    const flags = try r.varU32();
    if (flags > 1) return Error.UnsupportedFeature;
    const min = try r.varU32();
    const max = if (flags == 1) try r.varU32() else min;
    if (min > max or min > MAX_TABLE_ELEMENTS) return Error.TooManyItems;
    table_size = min;
}

fn readConstExpr(r: *Reader, expected: ValType) Error!Value {
    const op = try r.byte();
    const value: Value = switch (op) {
        0x41 => if (expected == .i32)
            .{ .u32_ = @bitCast(try r.s32()) }
        else
            return Error.InvalidType,
        0x42 => if (expected == .i64)
            .{ .u64_ = @bitCast(try r.s64()) }
        else
            return Error.InvalidType,
        0x43 => if (expected == .f32)
            .{ .u32_ = try r.fixedU32() }
        else
            return Error.InvalidType,
        0x44 => if (expected == .f64)
            .{ .u64_ = try r.fixedU64() }
        else
            return Error.InvalidType,
        else => return Error.UnsupportedFeature,
    };
    if (try r.byte() != 0x0b) return Error.InvalidSection;
    return value;
}

fn parseGlobalSection(r: *Reader) Error!void {
    const count = try r.varU32();
    if (count > MAX_GLOBALS) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const value_type = try valType(try r.byte());
        const mut = try r.byte();
        if (mut > 1) return Error.InvalidType;
        globals[global_count] = .{
            .value_type = value_type,
            .mutable = mut == 1,
            .initial = try readConstExpr(r, value_type),
        };
        global_count += 1;
    }
}

fn parseExportSection(r: *Reader) Error!void {
    const count = try r.varU32();
    if (count > MAX_EXPORTS) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        exports[export_count] = .{
            .name = try r.name(),
            .kind = try r.byte(),
            .index = try r.varU32(),
        };
        export_count += 1;
    }
}

fn parseCodeSection(r: *Reader) Error!void {
    const count = try r.varU32();
    if (count != function_count) return Error.InvalidSection;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        functions[i].body = try r.bytes(try r.varU32());
    }
}

fn readI32Offset(r: *Reader) Error!u32 {
    if (try r.byte() != 0x41) return Error.UnsupportedFeature;
    const result: u32 = @bitCast(try r.s32());
    if (try r.byte() != 0x0b) return Error.InvalidSection;
    return result;
}

fn parseElementSection(r: *Reader) Error!void {
    const count = try r.varU32();
    var segment_index: u32 = 0;
    while (segment_index < count) : (segment_index += 1) {
        const mode = try r.varU32();
        var offset: u32 = 0;
        switch (mode) {
            0 => offset = try readI32Offset(r),
            2 => {
                if (try r.varU32() != 0) return Error.InvalidIndex;
                offset = try readI32Offset(r);
                if (try r.byte() != 0) return Error.UnsupportedFeature;
            },
            else => return Error.UnsupportedFeature,
        }
        const element_count = try r.varU32();
        if (@as(u64, offset) + element_count > table_size) return Error.InvalidSection;
        var i: u32 = 0;
        while (i < element_count) : (i += 1) {
            const function_index = try r.varU32();
            if (function_index >= function_count) return Error.InvalidIndex;
            table_elements[offset + i] = function_index;
        }
    }
}

fn parseDataSection(r: *Reader) Error!void {
    const count = try r.varU32();
    if (count > MAX_DATA_SEGMENTS) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const mode = try r.varU32();
        var passive = false;
        var offset: u32 = 0;
        switch (mode) {
            0 => offset = try readI32Offset(r),
            1 => passive = true,
            2 => {
                if (try r.varU32() != 0) return Error.InvalidIndex;
                offset = try readI32Offset(r);
            },
            else => return Error.UnsupportedFeature,
        }
        data_segments[data_count] = .{
            .passive = passive,
            .offset = offset,
            .bytes = try r.bytes(try r.varU32()),
        };
        data_count += 1;
    }
}

fn parseModule(wasm: []const u8) Error!void {
    resetModule();
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..4], "\x00asm") or
        !std.mem.eql(u8, wasm[4..8], "\x01\x00\x00\x00"))
    {
        return Error.InvalidWasm;
    }

    var r = Reader.init(wasm[8..]);
    var last_non_custom: u8 = 0;
    while (r.remaining() != 0) {
        const id = try r.byte();
        const payload = try r.bytes(try r.varU32());
        var p = Reader.init(payload);
        if (id != 0) {
            const rank: u8 = switch (id) {
                12 => 10,
                10 => 11,
                11 => 12,
                else => id,
            };
            if (rank < last_non_custom) return Error.InvalidSection;
            last_non_custom = rank;
        }
        switch (id) {
            0 => {},
            1 => try parseTypeSection(&p),
            2 => if (try p.varU32() != 0) return Error.UnsupportedFeature,
            3 => try parseFunctionSection(&p),
            4 => try parseTableSection(&p),
            5 => try parseMemorySection(&p),
            6 => try parseGlobalSection(&p),
            7 => try parseExportSection(&p),
            8 => return Error.UnsupportedFeature,
            9 => try parseElementSection(&p),
            10 => try parseCodeSection(&p),
            11 => try parseDataSection(&p),
            12 => _ = try p.varU32(),
            else => return Error.UnsupportedFeature,
        }
        if (p.remaining() != 0) return Error.InvalidSection;
    }
    if (memory_min_pages == 0 or function_count == 0) return Error.MissingMemory;
}

fn findFunctionExport(name: []const u8) Error!u32 {
    var i: usize = 0;
    while (i < export_count) : (i += 1) {
        const exp = exports[i];
        if (std.mem.eql(u8, exp.name, name)) {
            if (exp.kind != 0 or exp.index >= function_count) return Error.InvalidContentContract;
            return exp.index;
        }
    }
    return Error.MissingExport;
}

fn sameFunctionType(a_index: u32, b_index: u32) bool {
    const a = types[a_index];
    const b = types[b_index];
    if (a.params_len != b.params_len or a.result != b.result) return false;
    var i: u32 = 0;
    while (i < a.params_len) : (i += 1) {
        if (type_values[a.params_off + i] != type_values[b.params_off + i]) return false;
    }
    return true;
}

const Contract = struct {
    input_ptr: u32,
    input_cap: u32,
    output_cap: u32,
    render: u32,
    input_offset: u32,
    input_capacity: u32,
    output_capacity: u32,
};

fn staticGetterValue(function_index: u32) Error!u32 {
    if (function_index >= function_count) return Error.InvalidIndex;
    const function = functions[function_index];
    const ft = types[function.type_index];
    if (ft.params_len != 0 or ft.result != .i32) return Error.InvalidContentContract;
    var r = Reader.init(function.body);
    if (try r.varU32() != 0) return Error.ContentGetterNotStatic;
    const value: u32 = switch (try r.byte()) {
        0x41 => @bitCast(try r.s32()),
        0x23 => blk: {
            const global_index = try r.varU32();
            if (global_index >= global_count) return Error.InvalidIndex;
            const global = globals[global_index];
            if (global.mutable or global.value_type != .i32) return Error.ContentGetterNotStatic;
            break :blk global.initial.u32_;
        },
        else => return Error.ContentGetterNotStatic,
    };
    if (try r.byte() != 0x0b or r.remaining() != 0) return Error.ContentGetterNotStatic;
    return value;
}

fn readContract() Error!Contract {
    var input_cap: ?u32 = null;
    input_cap = findFunctionExport("input_utf8_cap") catch null;
    if (input_cap == null) input_cap = findFunctionExport("input_bytes_cap") catch null;
    var output_cap: ?u32 = null;
    output_cap = findFunctionExport("output_utf8_cap") catch null;
    if (output_cap == null) output_cap = findFunctionExport("output_bytes_cap") catch null;
    const input_ptr_export = try findFunctionExport("input_ptr");
    const selected_input_cap = input_cap orelse return Error.MissingExport;
    const selected_output_cap = output_cap orelse return Error.MissingExport;
    const input_offset = try staticGetterValue(input_ptr_export);
    const input_capacity = try staticGetterValue(selected_input_cap);
    const output_capacity = try staticGetterValue(selected_output_cap);
    const memory_size = @as(u64, memory_min_pages) * 65536;
    const input_end = @as(u64, input_offset) + input_capacity;
    if (input_end > memory_size or output_capacity > memory_size) {
        return Error.InvalidContentContract;
    }
    for (data_segments[0..data_count]) |segment| {
        if (segment.passive) continue;
        const data_start: u64 = segment.offset;
        const data_end = data_start + segment.bytes.len;
        if (data_start < input_end and data_end > input_offset) {
            return Error.InputDataOverlap;
        }
    }
    return .{
        .input_ptr = input_ptr_export,
        .input_cap = selected_input_cap,
        .output_cap = selected_output_cap,
        .render = try findFunctionExport("render"),
        .input_offset = input_offset,
        .input_capacity = input_capacity,
        .output_capacity = output_capacity,
    };
}

const Writer = struct {
    pos: usize = 0,

    fn write(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > output_buf.len - self.pos) return Error.OutputTooLarge;
        @memcpy(output_buf[self.pos .. self.pos + bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) Error!void {
        const rendered = std.fmt.bufPrint(output_buf[self.pos..], fmt, args) catch return Error.OutputTooLarge;
        self.pos += rendered.len;
    }

    fn prefixed(self: *Writer, prefix: []const u8, template: []const u8) Error!void {
        var start: usize = 0;
        var i: usize = 0;
        while (i + 2 < template.len) : (i += 1) {
            if (template[i] == '{' and template[i + 1] == 'P' and template[i + 2] == '}') {
                try self.write(template[start..i]);
                try self.write(prefix);
                i += 2;
                start = i + 1;
            }
        }
        try self.write(template[start..]);
    }
};

fn moduleHash(wasm: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wasm, &digest, .{});
    return digest;
}

const ControlKind = enum { function, block, loop, if_ };
const Control = struct {
    kind: ControlKind,
    id: u32,
    branch_arity: u1,
    end_arity: u1,
};

const StackControlKind = enum { function, block, loop, if_, else_ };
const StackControl = struct {
    kind: StackControlKind,
    height: u32,
    branch_arity: u1,
    end_arity: u1,
    is_unreachable: bool = false,
};

const StackValidator = struct {
    local_count: u32,
    height: u32 = 0,
    max_height: u32 = 0,
    controls: [MAX_CONTROLS]StackControl = undefined,
    control_count: usize = 0,

    fn push(self: *StackValidator, count: u32) Error!void {
        if (count > MAX_STACK_VALUES - self.height) return Error.TooManyItems;
        self.height += count;
        self.max_height = @max(self.max_height, self.height);
    }

    fn pop(self: *StackValidator, count: u32) Error!void {
        if (self.control_count == 0) return Error.InvalidControl;
        const control = self.controls[self.control_count - 1];
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            if (self.height == control.height) {
                if (!control.is_unreachable) return Error.StackUnderflow;
            } else {
                self.height -= 1;
            }
        }
    }

    fn apply(self: *StackValidator, pops: u32, pushes: u32) Error!void {
        try self.pop(pops);
        try self.push(pushes);
    }

    fn pushControl(
        self: *StackValidator,
        kind: StackControlKind,
        branch_arity: u1,
        end_arity: u1,
    ) Error!void {
        if (self.control_count == MAX_CONTROLS) return Error.TooManyItems;
        self.controls[self.control_count] = .{
            .kind = kind,
            .height = self.height,
            .branch_arity = branch_arity,
            .end_arity = end_arity,
        };
        self.control_count += 1;
    }

    fn popControl(self: *StackValidator) Error!StackControl {
        if (self.control_count == 0) return Error.InvalidControl;
        const control = self.controls[self.control_count - 1];
        try self.pop(control.end_arity);
        if (self.height != control.height) return Error.StackMismatch;
        self.control_count -= 1;
        return control;
    }

    fn markUnreachable(self: *StackValidator) Error!void {
        if (self.control_count == 0) return Error.InvalidControl;
        self.height = self.controls[self.control_count - 1].height;
        self.controls[self.control_count - 1].is_unreachable = true;
    }

    fn target(self: *const StackValidator, depth: u32) Error!StackControl {
        if (depth >= self.control_count) return Error.InvalidIndex;
        return self.controls[self.control_count - 1 - depth];
    }

    fn blockArity(r: *Reader) Error!u1 {
        return switch (try r.byte()) {
            0x40 => 0,
            0x7f, 0x7e, 0x7d, 0x7c => 1,
            else => Error.UnsupportedFeature,
        };
    }

    fn localIndex(self: *const StackValidator, r: *Reader) Error!u32 {
        const index = try r.varU32();
        if (index >= self.local_count) return Error.InvalidIndex;
        return index;
    }

    fn globalIndex(r: *Reader) Error!u32 {
        const index = try r.varU32();
        if (index >= global_count) return Error.InvalidIndex;
        return index;
    }

    fn branch(self: *StackValidator, control: StackControl) Error!void {
        try self.pop(control.branch_arity);
        try self.markUnreachable();
    }

    fn bulkMemory(self: *StackValidator, r: *Reader) Error!void {
        switch (try r.varU32()) {
            0...7 => try self.apply(1, 1),
            8 => {
                if (try r.varU32() >= data_count or try r.varU32() != 0) return Error.InvalidIndex;
                try self.pop(3);
            },
            9 => if (try r.varU32() >= data_count) return Error.InvalidIndex,
            10 => {
                if (try r.varU32() != 0 or try r.varU32() != 0) return Error.InvalidIndex;
                try self.pop(3);
            },
            11 => {
                if (try r.varU32() != 0) return Error.InvalidIndex;
                try self.pop(3);
            },
            else => return Error.UnsupportedFeature,
        }
    }

    fn validate(self: *StackValidator, r: *Reader, result_arity: u1) Error!u32 {
        try self.pushControl(.function, result_arity, result_arity);
        while (r.remaining() != 0) {
            const op = try r.byte();
            switch (op) {
                0x00 => try self.markUnreachable(),
                0x01 => {},
                0x02, 0x03 => {
                    const arity = try blockArity(r);
                    try self.pushControl(if (op == 0x02) .block else .loop, if (op == 0x03) 0 else arity, arity);
                },
                0x04 => {
                    try self.pop(1);
                    const arity = try blockArity(r);
                    try self.pushControl(.if_, arity, arity);
                },
                0x05 => {
                    const control = try self.popControl();
                    if (control.kind != .if_) return Error.InvalidControl;
                    try self.pushControl(.else_, control.branch_arity, control.end_arity);
                },
                0x0b => {
                    const control = try self.popControl();
                    if (control.kind == .if_ and control.end_arity != 0) return Error.InvalidControl;
                    try self.push(control.end_arity);
                    if (self.control_count == 0) {
                        if (r.remaining() != 0 or self.height != result_arity) return Error.StackMismatch;
                        return self.max_height;
                    }
                },
                0x0c => try self.branch(try self.target(try r.varU32())),
                0x0d => {
                    const control = try self.target(try r.varU32());
                    try self.pop(1);
                    try self.pop(control.branch_arity);
                    try self.push(control.branch_arity);
                },
                0x0e => {
                    const count = try r.varU32();
                    if (count > MAX_CONTROLS) return Error.TooManyItems;
                    var expected_arity: ?u1 = null;
                    var i: u32 = 0;
                    while (i <= count) : (i += 1) {
                        const arity = (try self.target(try r.varU32())).branch_arity;
                        if (expected_arity) |expected| {
                            if (arity != expected) return Error.StackMismatch;
                        } else {
                            expected_arity = arity;
                        }
                    }
                    try self.pop(1);
                    try self.pop(expected_arity orelse 0);
                    try self.markUnreachable();
                },
                0x0f => try self.branch(self.controls[0]),
                0x10 => {
                    const index = try r.varU32();
                    if (index >= function_count) return Error.InvalidIndex;
                    const ft = types[functions[index].type_index];
                    try self.apply(ft.params_len, if (ft.result == null) 0 else 1);
                },
                0x11 => {
                    const type_index = try r.varU32();
                    if (type_index >= type_count or try r.varU32() != 0 or table_size == 0) return Error.InvalidIndex;
                    const ft = types[type_index];
                    try self.apply(ft.params_len + 1, if (ft.result == null) 0 else 1);
                },
                0x1a => try self.pop(1),
                0x1b => try self.apply(3, 1),
                0x20 => {
                    _ = try self.localIndex(r);
                    try self.push(1);
                },
                0x21 => {
                    _ = try self.localIndex(r);
                    try self.pop(1);
                },
                0x22 => {
                    _ = try self.localIndex(r);
                    try self.apply(1, 1);
                },
                0x23 => {
                    _ = try globalIndex(r);
                    try self.push(1);
                },
                0x24 => {
                    const index = try globalIndex(r);
                    if (!globals[index].mutable) return Error.InvalidIndex;
                    try self.pop(1);
                },
                0x28...0x35 => {
                    _ = try r.varU32();
                    _ = try r.varU32();
                    try self.apply(1, 1);
                },
                0x36...0x3e => {
                    _ = try r.varU32();
                    _ = try r.varU32();
                    try self.pop(2);
                },
                0x3f => {
                    if (try r.byte() != 0) return Error.InvalidIndex;
                    try self.push(1);
                },
                0x40 => return Error.UnsupportedFeature,
                0x41 => {
                    _ = try r.s32();
                    try self.push(1);
                },
                0x42 => {
                    _ = try r.s64();
                    try self.push(1);
                },
                0x43 => {
                    _ = try r.fixedU32();
                    try self.push(1);
                },
                0x44 => {
                    _ = try r.fixedU64();
                    try self.push(1);
                },
                0x45, 0x50, 0x67...0x69, 0x79...0x7b, 0x8b...0x8f, 0x91, 0x99...0x9d, 0x9f, 0xa7...0xbf, 0xc0...0xc4 => try self.apply(1, 1),
                0x46...0x4f, 0x51...0x66, 0x6a...0x78, 0x7c...0x8a, 0x92...0x95, 0x98, 0xa0...0xa3, 0xa6 => try self.apply(2, 1),
                0xfc => try self.bulkMemory(r),
                0xfd => return Error.UnsupportedFeature,
                else => return Error.UnsupportedFeature,
            }
        }
        return Error.UnexpectedEof;
    }
};

const FunctionEmitter = struct {
    out: *Writer,
    prefix: []const u8,
    function_index: u32,
    local_count: u32,
    next_label: u32 = 0,
    next_call: u32 = 0,
    controls: [MAX_CONTROLS]Control = undefined,
    control_count: usize = 0,

    fn pushControl(self: *FunctionEmitter, control: Control) Error!void {
        if (self.control_count == MAX_CONTROLS) return Error.TooManyItems;
        self.controls[self.control_count] = control;
        self.control_count += 1;
    }

    fn popControl(self: *FunctionEmitter) void {
        self.control_count -= 1;
    }

    fn target(self: *FunctionEmitter, depth: u32) Error!Control {
        if (depth >= self.control_count) return Error.InvalidIndex;
        return self.controls[self.control_count - 1 - depth];
    }

    fn localIndex(self: *const FunctionEmitter, r: *Reader) Error!u32 {
        const index = try r.varU32();
        if (index >= self.local_count) return Error.InvalidIndex;
        return index;
    }

    fn globalIndex(r: *Reader) Error!u32 {
        const index = try r.varU32();
        if (index >= global_count) return Error.InvalidIndex;
        return index;
    }

    fn writableGlobalIndex(r: *Reader) Error!u32 {
        const index = try globalIndex(r);
        if (!globals[index].mutable) return Error.InvalidIndex;
        return index;
    }

    fn blockArity(r: *Reader) Error!u1 {
        const b = try r.byte();
        return switch (b) {
            0x40 => 0,
            0x7f, 0x7e, 0x7d, 0x7c => 1,
            else => Error.UnsupportedFeature,
        };
    }

    fn normalize(self: *FunctionEmitter, control: Control, for_branch: bool) Error!void {
        const arity = if (for_branch) control.branch_arity else control.end_arity;
        if (control.kind == .function) {
            if (arity == 0) {
                try self.out.write("  sp = 0;\n");
            } else {
                try self.out.write("  s[0] = s[sp - 1]; sp = 1;\n");
            }
            return;
        }
        if (arity == 0) {
            try self.out.print("  sp = b{d};\n", .{control.id});
        } else {
            try self.out.print("  s[b{d}] = s[sp - 1]; sp = b{d} + 1;\n", .{ control.id, control.id });
        }
    }

    fn branch(self: *FunctionEmitter, control: Control) Error!void {
        try self.normalize(control, true);
        switch (control.kind) {
            .function => try self.out.write("  goto f_return;\n"),
            .loop => try self.out.print("  goto l{d};\n", .{control.id}),
            else => try self.out.print("  goto e{d};\n", .{control.id}),
        }
    }

    fn memarg(r: *Reader) Error!u32 {
        _ = try r.varU32();
        return r.varU32();
    }

    fn emitLoad(self: *FunctionEmitter, op: u8, r: *Reader) Error!void {
        const offset = try memarg(r);
        const helper = switch (op) {
            0x28 => "load_u32",
            0x29 => "load_u64",
            0x2a => "load_f32",
            0x2b => "load_f64",
            0x2c => "load_i8_i32",
            0x2d => "load_u8_i32",
            0x2e => "load_i16_i32",
            0x2f => "load_u16_i32",
            0x30 => "load_i8_i64",
            0x31 => "load_u8_i64",
            0x32 => "load_i16_i64",
            0x33 => "load_u16_i64",
            0x34 => "load_i32_i64",
            0x35 => "load_u32_i64",
            else => return Error.UnsupportedFeature,
        };
        try self.out.print("  s[sp - 1] = {s}_{s}(i, s[sp - 1].u32, {d}u);\n", .{ self.prefix, helper, offset });
    }

    fn emitStore(self: *FunctionEmitter, op: u8, r: *Reader) Error!void {
        const offset = try memarg(r);
        const helper = switch (op) {
            0x36 => "store_u32",
            0x37 => "store_u64",
            0x38 => "store_f32",
            0x39 => "store_f64",
            0x3a => "store8_i32",
            0x3b => "store16_i32",
            0x3c => "store8_i64",
            0x3d => "store16_i64",
            0x3e => "store32_i64",
            else => return Error.UnsupportedFeature,
        };
        try self.out.print("  {s}_{s}(i, s[sp - 2].u32, {d}u, s[sp - 1]); sp -= 2;\n", .{ self.prefix, helper, offset });
    }

    fn emitI32Binary(self: *FunctionEmitter, expression: []const u8) Error!void {
        try self.out.print("  s[sp - 2].u32 = {s}; --sp;\n", .{expression});
    }

    fn emitI64Binary(self: *FunctionEmitter, expression: []const u8) Error!void {
        try self.out.print("  s[sp - 2].u64 = {s}; --sp;\n", .{expression});
    }

    fn emitF32Compare(self: *FunctionEmitter, operator: []const u8) Error!void {
        try self.out.print("  s[sp - 2].u32 = s[sp - 2].f32 {s} s[sp - 1].f32; --sp;\n", .{operator});
    }

    fn emitF64Compare(self: *FunctionEmitter, operator: []const u8) Error!void {
        try self.out.print("  s[sp - 2].u32 = s[sp - 2].f64 {s} s[sp - 1].f64; --sp;\n", .{operator});
    }

    fn emitF32Binary(self: *FunctionEmitter, operator: []const u8) Error!void {
        try self.out.print("  s[sp - 2].f32 = s[sp - 2].f32 {s} s[sp - 1].f32; --sp;\n", .{operator});
    }

    fn emitF64Binary(self: *FunctionEmitter, operator: []const u8) Error!void {
        try self.out.print("  s[sp - 2].f64 = s[sp - 2].f64 {s} s[sp - 1].f64; --sp;\n", .{operator});
    }

    fn emitCall(self: *FunctionEmitter, index: u32) Error!void {
        if (index >= function_count) return Error.InvalidIndex;
        const ft = types[functions[index].type_index];
        const call_id = self.next_call;
        self.next_call += 1;
        if (ft.params_len != 0) {
            try self.out.print("  {s}_val a{d}[{d}]; sp -= {d};\n", .{ self.prefix, call_id, ft.params_len, ft.params_len });
            var p: u32 = 0;
            while (p < ft.params_len) : (p += 1) {
                try self.out.print("  a{d}[{d}] = s[sp + {d}];\n", .{ call_id, p, p });
            }
        }
        if (ft.result != null) try self.out.write("  s[sp++] = ");
        try self.out.print("{s}_f{d}(i, {s});\n", .{
            self.prefix,
            index,
            if (ft.params_len == 0) "NULL" else blk: {
                var buf: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(&buf, "a{d}", .{call_id}) catch return Error.TooManyItems;
            },
        });
    }

    fn emitCallIndirect(self: *FunctionEmitter, r: *Reader) Error!void {
        const type_index = try r.varU32();
        if (type_index >= type_count or try r.varU32() != 0 or table_size == 0)
            return Error.InvalidIndex;
        const ft = types[type_index];
        const call_id = self.next_call;
        self.next_call += 1;
        try self.out.print(
            "  {{ uint32_t ti{d} = s[--sp].u32, fi{d}; {s}_val a{d}[{d}];\n",
            .{ call_id, call_id, self.prefix, call_id, @max(ft.params_len, 1) },
        );
        try self.out.print(
            "    if (ti{d} >= {d}u) {s}_trap(i, {s}_TRAP_TABLE_OOB); fi{d} = i->table[ti{d}];\n",
            .{ call_id, table_size, self.prefix, self.prefix, call_id, call_id },
        );
        try self.out.print(
            "    if (fi{d} == UINT32_MAX) {s}_trap(i, {s}_TRAP_INDIRECT_NULL); sp -= {d}u;\n",
            .{ call_id, self.prefix, self.prefix, ft.params_len },
        );
        var p: u32 = 0;
        while (p < ft.params_len) : (p += 1) {
            try self.out.print("    a{d}[{d}] = s[sp + {d}u];\n", .{ call_id, p, p });
        }
        try self.out.print("    switch (fi{d}) {{\n", .{call_id});
        var function_index: u32 = 0;
        while (function_index < function_count) : (function_index += 1) {
            if (!sameFunctionType(type_index, functions[function_index].type_index)) continue;
            if (ft.result == null) {
                try self.out.print("    case {d}u: (void){s}_f{d}(i, a{d}); break;\n", .{
                    function_index, self.prefix, function_index, call_id,
                });
            } else {
                try self.out.print("    case {d}u: s[sp] = {s}_f{d}(i, a{d}); break;\n", .{
                    function_index, self.prefix, function_index, call_id,
                });
            }
        }
        try self.out.print(
            "    default: {s}_trap(i, {s}_TRAP_INDIRECT_TYPE); }}",
            .{ self.prefix, self.prefix },
        );
        if (ft.result != null) try self.out.write(" ++sp;");
        try self.out.write(" }\n");
    }

    fn emitBrTable(self: *FunctionEmitter, r: *Reader) Error!void {
        const count = try r.varU32();
        if (count > MAX_CONTROLS) return Error.TooManyItems;
        try self.out.write("  switch (s[--sp].u32) {\n");
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const control = try self.target(try r.varU32());
            try self.out.print("  case {d}u:\n", .{i});
            try self.branch(control);
        }
        try self.out.write("  default:\n");
        try self.branch(try self.target(try r.varU32()));
        try self.out.write("  }\n");
    }

    fn emitBulkMemory(self: *FunctionEmitter, r: *Reader) Error!void {
        const subop = try r.varU32();
        switch (subop) {
            0 => try self.out.print("  s[sp - 1].u32 = {s}_sat_i32_f32_s(s[sp - 1].f32);\n", .{self.prefix}),
            1 => try self.out.print("  s[sp - 1].u32 = {s}_sat_i32_f32_u(s[sp - 1].f32);\n", .{self.prefix}),
            2 => try self.out.print("  s[sp - 1].u32 = {s}_sat_i32_f64_s(s[sp - 1].f64);\n", .{self.prefix}),
            3 => try self.out.print("  s[sp - 1].u32 = {s}_sat_i32_f64_u(s[sp - 1].f64);\n", .{self.prefix}),
            4 => try self.out.print("  s[sp - 1].u64 = {s}_sat_i64_f32_s(s[sp - 1].f32);\n", .{self.prefix}),
            5 => try self.out.print("  s[sp - 1].u64 = {s}_sat_i64_f32_u(s[sp - 1].f32);\n", .{self.prefix}),
            6 => try self.out.print("  s[sp - 1].u64 = {s}_sat_i64_f64_s(s[sp - 1].f64);\n", .{self.prefix}),
            7 => try self.out.print("  s[sp - 1].u64 = {s}_sat_i64_f64_u(s[sp - 1].f64);\n", .{self.prefix}),
            8 => {
                const data_index = try r.varU32();
                if (data_index >= data_count or try r.varU32() != 0) return Error.InvalidIndex;
                const segment = data_segments[data_index];
                try self.out.print(
                    \\  {{ uint32_t n = s[sp - 1].u32, src = s[sp - 2].u32, dst = s[sp - 3].u32;
                    \\    uint32_t available = i->data_dropped[{d}] ? 0u : {d}u;
                    \\    uint8_t *d = {s}_range(i, dst, 0, n);
                    \\    if ((uint64_t)src + n > available) {s}_trap(i, {s}_TRAP_OOB);
                    \\    {s}_mark_dirty(i, dst, n);
                    \\    memcpy(d, {s}_data_{d} + src, n); sp -= 3; }}
                    \\
                , .{
                    data_index,  segment.bytes.len, self.prefix, self.prefix,
                    self.prefix, self.prefix,       self.prefix, data_index,
                });
            },
            9 => {
                const data_index = try r.varU32();
                if (data_index >= data_count) return Error.InvalidIndex;
                try self.out.print("  i->data_dropped[{d}] = 1;\n", .{data_index});
            },
            10 => {
                if (try r.varU32() != 0 or try r.varU32() != 0) return Error.InvalidIndex;
                try self.out.print(
                    \\  {{ uint32_t n = s[sp - 1].u32, src = s[sp - 2].u32, dst = s[sp - 3].u32;
                    \\    uint8_t *d = {s}_range(i, dst, 0, n);
                    \\    uint8_t *source = {s}_range(i, src, 0, n);
                    \\    {s}_mark_dirty(i, dst, n);
                    \\    memmove(d, source, n); sp -= 3; }}
                    \\
                , .{ self.prefix, self.prefix, self.prefix });
            },
            11 => {
                if (try r.varU32() != 0) return Error.InvalidIndex;
                try self.out.print(
                    \\  {{ uint32_t n = s[sp - 1].u32, value = s[sp - 2].u32, dst = s[sp - 3].u32;
                    \\    memset({s}_write_range(i, dst, 0, n), (int)(uint8_t)value, n); sp -= 3; }}
                    \\
                , .{self.prefix});
            },
            else => return Error.UnsupportedFeature,
        }
    }

    /// Emit through the matching end. Returns true when it stopped at `else`.
    fn sequence(self: *FunctionEmitter, r: *Reader, allow_else: bool) Error!bool {
        while (r.remaining() != 0) {
            const op = try r.byte();
            switch (op) {
                0x00 => try self.out.print("  {s}_trap(i, {s}_TRAP_UNREACHABLE);\n", .{ self.prefix, self.prefix }),
                0x01 => {},
                0x02 => {
                    const arity = try blockArity(r);
                    const id = self.next_label;
                    self.next_label += 1;
                    const control = Control{ .kind = .block, .id = id, .branch_arity = arity, .end_arity = arity };
                    try self.out.print("  {{ uint32_t b{d} = sp; if (0) goto e{d};\n", .{ id, id });
                    try self.pushControl(control);
                    if (try self.sequence(r, false)) return Error.InvalidSection;
                    self.popControl();
                    try self.out.print("e{d}: ;\n", .{id});
                    try self.normalize(control, false);
                    try self.out.write("  }\n");
                },
                0x03 => {
                    const arity = try blockArity(r);
                    const id = self.next_label;
                    self.next_label += 1;
                    const control = Control{ .kind = .loop, .id = id, .branch_arity = 0, .end_arity = arity };
                    try self.out.print("  {{ uint32_t b{d} = sp; if (0) goto l{d}; if (0) goto e{d}; l{d}: ;\n", .{ id, id, id, id });
                    try self.pushControl(control);
                    if (try self.sequence(r, false)) return Error.InvalidSection;
                    self.popControl();
                    try self.out.print("e{d}: ;\n", .{id});
                    try self.normalize(control, false);
                    try self.out.write("  }\n");
                },
                0x04 => {
                    const arity = try blockArity(r);
                    const id = self.next_label;
                    self.next_label += 1;
                    const control = Control{ .kind = .if_, .id = id, .branch_arity = arity, .end_arity = arity };
                    try self.out.print("  {{ uint32_t b{d}; uint32_t c{d} = s[--sp].u32; b{d} = sp; if (0) goto e{d}; if (!c{d}) goto x{d};\n", .{ id, id, id, id, id, id });
                    try self.pushControl(control);
                    const had_else = try self.sequence(r, true);
                    if (had_else) {
                        try self.out.print("  goto e{d}; x{d}: ;\n", .{ id, id });
                        if (try self.sequence(r, false)) return Error.InvalidSection;
                    } else {
                        try self.out.print("x{d}: ;\n", .{id});
                    }
                    self.popControl();
                    try self.out.print("e{d}: ;\n", .{id});
                    try self.normalize(control, false);
                    try self.out.write("  }\n");
                },
                0x05 => {
                    if (!allow_else) return Error.InvalidSection;
                    return true;
                },
                0x0b => return false,
                0x0c => try self.branch(try self.target(try r.varU32())),
                0x0d => {
                    const control = try self.target(try r.varU32());
                    try self.out.write("  if (s[--sp].u32) {\n");
                    try self.branch(control);
                    try self.out.write("  }\n");
                },
                0x0e => try self.emitBrTable(r),
                0x0f => try self.branch(self.controls[0]),
                0x10 => try self.emitCall(try r.varU32()),
                0x11 => try self.emitCallIndirect(r),
                0x1a => try self.out.write("  --sp;\n"),
                0x1b => try self.out.write("  { uint32_t c = s[--sp].u32; --sp; if (!c) s[sp - 1] = s[sp]; }\n"),
                0x20 => try self.out.print("  s[sp++] = v[{d}];\n", .{try self.localIndex(r)}),
                0x21 => try self.out.print("  v[{d}] = s[--sp];\n", .{try self.localIndex(r)}),
                0x22 => try self.out.print("  v[{d}] = s[sp - 1];\n", .{try self.localIndex(r)}),
                0x23 => try self.out.print("  s[sp++] = i->g[{d}];\n", .{try globalIndex(r)}),
                0x24 => try self.out.print("  i->g[{d}] = s[--sp];\n", .{try writableGlobalIndex(r)}),
                0x28...0x35 => try self.emitLoad(op, r),
                0x36...0x3e => try self.emitStore(op, r),
                0x3f => {
                    if (try r.byte() != 0) return Error.InvalidIndex;
                    try self.out.print("  s[sp++].u32 = {d}u;\n", .{memory_min_pages});
                },
                0x40 => return Error.UnsupportedFeature,
                0x41 => try self.out.print("  s[sp++].u32 = {d}u;\n", .{@as(u32, @bitCast(try r.s32()))}),
                0x42 => try self.out.print("  s[sp++].u64 = UINT64_C({d});\n", .{@as(u64, @bitCast(try r.s64()))}),
                0x43 => try self.out.print("  s[sp++].u32 = UINT32_C({d});\n", .{try r.fixedU32()}),
                0x44 => try self.out.print("  s[sp++].u64 = UINT64_C({d});\n", .{try r.fixedU64()}),
                0x45 => try self.out.write("  s[sp - 1].u32 = s[sp - 1].u32 == 0;\n"),
                0x46 => try self.emitI32Binary("s[sp - 2].u32 == s[sp - 1].u32"),
                0x47 => try self.emitI32Binary("s[sp - 2].u32 != s[sp - 1].u32"),
                0x48 => try self.emitI32Binary("(int32_t)s[sp - 2].u32 < (int32_t)s[sp - 1].u32"),
                0x49 => try self.emitI32Binary("s[sp - 2].u32 < s[sp - 1].u32"),
                0x4a => try self.emitI32Binary("(int32_t)s[sp - 2].u32 > (int32_t)s[sp - 1].u32"),
                0x4b => try self.emitI32Binary("s[sp - 2].u32 > s[sp - 1].u32"),
                0x4c => try self.emitI32Binary("(int32_t)s[sp - 2].u32 <= (int32_t)s[sp - 1].u32"),
                0x4d => try self.emitI32Binary("s[sp - 2].u32 <= s[sp - 1].u32"),
                0x4e => try self.emitI32Binary("(int32_t)s[sp - 2].u32 >= (int32_t)s[sp - 1].u32"),
                0x4f => try self.emitI32Binary("s[sp - 2].u32 >= s[sp - 1].u32"),
                0x50 => try self.out.write("  s[sp - 1].u32 = s[sp - 1].u64 == 0;\n"),
                0x51 => try self.emitI64Binary("s[sp - 2].u64 == s[sp - 1].u64"),
                0x52 => try self.emitI64Binary("s[sp - 2].u64 != s[sp - 1].u64"),
                0x53 => try self.emitI64Binary("(int64_t)s[sp - 2].u64 < (int64_t)s[sp - 1].u64"),
                0x54 => try self.emitI64Binary("s[sp - 2].u64 < s[sp - 1].u64"),
                0x55 => try self.emitI64Binary("(int64_t)s[sp - 2].u64 > (int64_t)s[sp - 1].u64"),
                0x56 => try self.emitI64Binary("s[sp - 2].u64 > s[sp - 1].u64"),
                0x57 => try self.emitI64Binary("(int64_t)s[sp - 2].u64 <= (int64_t)s[sp - 1].u64"),
                0x58 => try self.emitI64Binary("s[sp - 2].u64 <= s[sp - 1].u64"),
                0x59 => try self.emitI64Binary("(int64_t)s[sp - 2].u64 >= (int64_t)s[sp - 1].u64"),
                0x5a => try self.emitI64Binary("s[sp - 2].u64 >= s[sp - 1].u64"),
                0x5b => try self.emitF32Compare("=="),
                0x5c => try self.emitF32Compare("!="),
                0x5d => try self.emitF32Compare("<"),
                0x5e => try self.emitF32Compare(">"),
                0x5f => try self.emitF32Compare("<="),
                0x60 => try self.emitF32Compare(">="),
                0x61 => try self.emitF64Compare("=="),
                0x62 => try self.emitF64Compare("!="),
                0x63 => try self.emitF64Compare("<"),
                0x64 => try self.emitF64Compare(">"),
                0x65 => try self.emitF64Compare("<="),
                0x66 => try self.emitF64Compare(">="),
                0x67 => try self.out.print("  s[sp - 1].u32 = {s}_clz32(s[sp - 1].u32);\n", .{self.prefix}),
                0x68 => try self.out.print("  s[sp - 1].u32 = {s}_ctz32(s[sp - 1].u32);\n", .{self.prefix}),
                0x69 => try self.out.print("  s[sp - 1].u32 = {s}_pop32(s[sp - 1].u32);\n", .{self.prefix}),
                0x6a => try self.emitI32Binary("s[sp - 2].u32 + s[sp - 1].u32"),
                0x6b => try self.emitI32Binary("s[sp - 2].u32 - s[sp - 1].u32"),
                0x6c => try self.emitI32Binary("s[sp - 2].u32 * s[sp - 1].u32"),
                0x6d => try self.out.print(
                    "  if (!s[sp - 1].u32) {s}_trap(i, {s}_TRAP_DIV_ZERO); if (s[sp - 2].u32 == UINT32_C(2147483648) && s[sp - 1].u32 == UINT32_C(4294967295)) {s}_trap(i, {s}_TRAP_INT_OVERFLOW); s[sp - 2].u32 = (uint32_t)((int32_t)s[sp - 2].u32 / (int32_t)s[sp - 1].u32); --sp;\n",
                    .{ self.prefix, self.prefix, self.prefix, self.prefix },
                ),
                0x6e => try self.out.print("  if (!s[sp - 1].u32) {s}_trap(i, {s}_TRAP_DIV_ZERO); s[sp - 2].u32 /= s[sp - 1].u32; --sp;\n", .{ self.prefix, self.prefix }),
                0x6f => try self.out.print("  if (!s[sp - 1].u32) {s}_trap(i, {s}_TRAP_DIV_ZERO); s[sp - 2].u32 = (s[sp - 2].u32 == UINT32_C(2147483648) && s[sp - 1].u32 == UINT32_C(4294967295)) ? 0u : (uint32_t)((int32_t)s[sp - 2].u32 % (int32_t)s[sp - 1].u32); --sp;\n", .{ self.prefix, self.prefix }),
                0x70 => try self.out.print("  if (!s[sp - 1].u32) {s}_trap(i, {s}_TRAP_DIV_ZERO); s[sp - 2].u32 %= s[sp - 1].u32; --sp;\n", .{ self.prefix, self.prefix }),
                0x71 => try self.emitI32Binary("s[sp - 2].u32 & s[sp - 1].u32"),
                0x72 => try self.emitI32Binary("s[sp - 2].u32 | s[sp - 1].u32"),
                0x73 => try self.emitI32Binary("s[sp - 2].u32 ^ s[sp - 1].u32"),
                0x74 => try self.emitI32Binary("s[sp - 2].u32 << (s[sp - 1].u32 & 31)"),
                0x75 => try self.emitI32Binary("(uint32_t)((int32_t)s[sp - 2].u32 >> (s[sp - 1].u32 & 31))"),
                0x76 => try self.emitI32Binary("s[sp - 2].u32 >> (s[sp - 1].u32 & 31)"),
                0x77 => try self.out.print("  s[sp - 2].u32 = {s}_rotl32(s[sp - 2].u32, s[sp - 1].u32); --sp;\n", .{self.prefix}),
                0x78 => try self.out.print("  s[sp - 2].u32 = {s}_rotr32(s[sp - 2].u32, s[sp - 1].u32); --sp;\n", .{self.prefix}),
                0x79 => try self.out.print("  s[sp - 1].u64 = {s}_clz64(s[sp - 1].u64);\n", .{self.prefix}),
                0x7a => try self.out.print("  s[sp - 1].u64 = {s}_ctz64(s[sp - 1].u64);\n", .{self.prefix}),
                0x7b => try self.out.print("  s[sp - 1].u64 = {s}_pop64(s[sp - 1].u64);\n", .{self.prefix}),
                0x7c => try self.emitI64Binary("s[sp - 2].u64 + s[sp - 1].u64"),
                0x7d => try self.emitI64Binary("s[sp - 2].u64 - s[sp - 1].u64"),
                0x7e => try self.emitI64Binary("s[sp - 2].u64 * s[sp - 1].u64"),
                0x7f => try self.out.print(
                    "  if (!s[sp - 1].u64) {s}_trap(i, {s}_TRAP_DIV_ZERO); if (s[sp - 2].u64 == (UINT64_C(1) << 63) && s[sp - 1].u64 == UINT64_MAX) {s}_trap(i, {s}_TRAP_INT_OVERFLOW); s[sp - 2].u64 = (uint64_t)((int64_t)s[sp - 2].u64 / (int64_t)s[sp - 1].u64); --sp;\n",
                    .{ self.prefix, self.prefix, self.prefix, self.prefix },
                ),
                0x80 => try self.out.print("  if (!s[sp - 1].u64) {s}_trap(i, {s}_TRAP_DIV_ZERO); s[sp - 2].u64 /= s[sp - 1].u64; --sp;\n", .{ self.prefix, self.prefix }),
                0x81 => try self.out.print("  if (!s[sp - 1].u64) {s}_trap(i, {s}_TRAP_DIV_ZERO); s[sp - 2].u64 = (s[sp - 2].u64 == (UINT64_C(1) << 63) && s[sp - 1].u64 == UINT64_MAX) ? 0u : (uint64_t)((int64_t)s[sp - 2].u64 % (int64_t)s[sp - 1].u64); --sp;\n", .{ self.prefix, self.prefix }),
                0x82 => try self.out.print("  if (!s[sp - 1].u64) {s}_trap(i, {s}_TRAP_DIV_ZERO); s[sp - 2].u64 %= s[sp - 1].u64; --sp;\n", .{ self.prefix, self.prefix }),
                0x83 => try self.emitI64Binary("s[sp - 2].u64 & s[sp - 1].u64"),
                0x84 => try self.emitI64Binary("s[sp - 2].u64 | s[sp - 1].u64"),
                0x85 => try self.emitI64Binary("s[sp - 2].u64 ^ s[sp - 1].u64"),
                0x86 => try self.emitI64Binary("s[sp - 2].u64 << (s[sp - 1].u64 & 63)"),
                0x87 => try self.emitI64Binary("(uint64_t)((int64_t)s[sp - 2].u64 >> (s[sp - 1].u64 & 63))"),
                0x88 => try self.emitI64Binary("s[sp - 2].u64 >> (s[sp - 1].u64 & 63)"),
                0x89 => try self.out.print("  s[sp - 2].u64 = {s}_rotl64(s[sp - 2].u64, s[sp - 1].u64); --sp;\n", .{self.prefix}),
                0x8a => try self.out.print("  s[sp - 2].u64 = {s}_rotr64(s[sp - 2].u64, s[sp - 1].u64); --sp;\n", .{self.prefix}),
                0x8b => try self.out.write("  s[sp - 1].u32 &= UINT32_C(0x7fffffff);\n"),
                0x8c => try self.out.write("  s[sp - 1].u32 ^= UINT32_C(0x80000000);\n"),
                0x8d => try self.out.write("  s[sp - 1].f32 = ceilf(s[sp - 1].f32);\n"),
                0x8e => try self.out.write("  s[sp - 1].f32 = floorf(s[sp - 1].f32);\n"),
                0x8f => try self.out.write("  s[sp - 1].f32 = truncf(s[sp - 1].f32);\n"),
                0x91 => try self.out.write("  s[sp - 1].f32 = sqrtf(s[sp - 1].f32);\n"),
                0x92 => try self.emitF32Binary("+"),
                0x93 => try self.emitF32Binary("-"),
                0x94 => try self.emitF32Binary("*"),
                0x95 => try self.emitF32Binary("/"),
                0x98 => try self.out.write("  s[sp - 2].f32 = copysignf(s[sp - 2].f32, s[sp - 1].f32); --sp;\n"),
                0x99 => try self.out.write("  s[sp - 1].u64 &= UINT64_C(0x7fffffffffffffff);\n"),
                0x9a => try self.out.write("  s[sp - 1].u64 ^= UINT64_C(0x8000000000000000);\n"),
                0x9b => try self.out.write("  s[sp - 1].f64 = ceil(s[sp - 1].f64);\n"),
                0x9c => try self.out.write("  s[sp - 1].f64 = floor(s[sp - 1].f64);\n"),
                0x9d => try self.out.write("  s[sp - 1].f64 = trunc(s[sp - 1].f64);\n"),
                0x9f => try self.out.write("  s[sp - 1].f64 = sqrt(s[sp - 1].f64);\n"),
                0xa0 => try self.emitF64Binary("+"),
                0xa1 => try self.emitF64Binary("-"),
                0xa2 => try self.emitF64Binary("*"),
                0xa3 => try self.emitF64Binary("/"),
                0xa6 => try self.out.write("  s[sp - 2].f64 = copysign(s[sp - 2].f64, s[sp - 1].f64); --sp;\n"),
                0xa7 => try self.out.write("  s[sp - 1].u32 = (uint32_t)s[sp - 1].u64;\n"),
                0xa8 => try self.out.print("  s[sp - 1].u32 = {s}_trunc_i32_f32_s(i, s[sp - 1].f32);\n", .{self.prefix}),
                0xa9 => try self.out.print("  s[sp - 1].u32 = {s}_trunc_i32_f32_u(i, s[sp - 1].f32);\n", .{self.prefix}),
                0xaa => try self.out.print("  s[sp - 1].u32 = {s}_trunc_i32_f64_s(i, s[sp - 1].f64);\n", .{self.prefix}),
                0xab => try self.out.print("  s[sp - 1].u32 = {s}_trunc_i32_f64_u(i, s[sp - 1].f64);\n", .{self.prefix}),
                0xae => try self.out.print("  s[sp - 1].u64 = {s}_trunc_i64_f32_s(i, s[sp - 1].f32);\n", .{self.prefix}),
                0xaf => try self.out.print("  s[sp - 1].u64 = {s}_trunc_i64_f32_u(i, s[sp - 1].f32);\n", .{self.prefix}),
                0xb0 => try self.out.print("  s[sp - 1].u64 = {s}_trunc_i64_f64_s(i, s[sp - 1].f64);\n", .{self.prefix}),
                0xb1 => try self.out.print("  s[sp - 1].u64 = {s}_trunc_i64_f64_u(i, s[sp - 1].f64);\n", .{self.prefix}),
                0xb2 => try self.out.write("  s[sp - 1].f32 = (float)(int32_t)s[sp - 1].u32;\n"),
                0xb3 => try self.out.write("  s[sp - 1].f32 = (float)s[sp - 1].u32;\n"),
                0xb4 => try self.out.write("  s[sp - 1].f32 = (float)(int64_t)s[sp - 1].u64;\n"),
                0xb5 => try self.out.write("  s[sp - 1].f32 = (float)s[sp - 1].u64;\n"),
                0xb6 => try self.out.write("  s[sp - 1].f32 = (float)s[sp - 1].f64;\n"),
                0xb7 => try self.out.write("  s[sp - 1].f64 = (double)(int32_t)s[sp - 1].u32;\n"),
                0xb8 => try self.out.write("  s[sp - 1].f64 = (double)s[sp - 1].u32;\n"),
                0xb9 => try self.out.write("  s[sp - 1].f64 = (double)(int64_t)s[sp - 1].u64;\n"),
                0xba => try self.out.write("  s[sp - 1].f64 = (double)s[sp - 1].u64;\n"),
                0xbb => try self.out.write("  s[sp - 1].f64 = (double)s[sp - 1].f32;\n"),
                0xbc => try self.out.print("  s[sp - 1].u32 = {s}_bits_f32(s[sp - 1].f32);\n", .{self.prefix}),
                0xbd => try self.out.print("  s[sp - 1].u64 = {s}_bits_f64(s[sp - 1].f64);\n", .{self.prefix}),
                0xbe => try self.out.print("  s[sp - 1].f32 = {s}_from_bits_f32(s[sp - 1].u32);\n", .{self.prefix}),
                0xbf => try self.out.print("  s[sp - 1].f64 = {s}_from_bits_f64(s[sp - 1].u64);\n", .{self.prefix}),
                0xad => try self.out.write("  s[sp - 1].u64 = s[sp - 1].u32;\n"),
                0xac => try self.out.write("  s[sp - 1].u64 = (uint64_t)(int64_t)(int32_t)s[sp - 1].u32;\n"),
                0xc0 => try self.out.write("  s[sp - 1].u32 = (uint32_t)(int32_t)(int8_t)s[sp - 1].u32;\n"),
                0xc1 => try self.out.write("  s[sp - 1].u32 = (uint32_t)(int32_t)(int16_t)s[sp - 1].u32;\n"),
                0xc2 => try self.out.write("  s[sp - 1].u64 = (uint64_t)(int64_t)(int8_t)s[sp - 1].u64;\n"),
                0xc3 => try self.out.write("  s[sp - 1].u64 = (uint64_t)(int64_t)(int16_t)s[sp - 1].u64;\n"),
                0xc4 => try self.out.write("  s[sp - 1].u64 = (uint64_t)(int64_t)(int32_t)s[sp - 1].u64;\n"),
                0xfc => try self.emitBulkMemory(r),
                0xfd => return Error.UnsupportedFeature,
                else => return Error.UnsupportedFeature,
            }
        }
        return Error.UnexpectedEof;
    }
};

fn writePreamble(out: *Writer, prefix: []const u8, hash_hex: []const u8, contract: Contract) Error!void {
    try out.print(
        \\/* Generated by qip-component-to-c. */
        \\/* Source SHA-256: {s}. */
        \\#ifndef QIP_WASM_{s}_H
        \\#define QIP_WASM_{s}_H
        \\#include <math.h>
        \\#include <stddef.h>
        \\#include <setjmp.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\#include <string.h>
        \\#ifdef __cplusplus
        \\extern "C" {{
        \\#endif
        \\
        \\
    , .{ hash_hex, hash_hex, hash_hex });
    try out.print("#define {s}_MEMORY_SIZE UINT64_C({d})\n", .{ prefix, @as(u64, memory_min_pages) * 65536 });
    try out.print("#define {s}_MEMORY_PAGES {d}u\n", .{ prefix, memory_min_pages });
    try out.print("#define {s}_INPUT_OFFSET UINT32_C({d})\n", .{ prefix, contract.input_offset });
    try out.print("#define {s}_INPUT_CAPACITY UINT32_C({d})\n", .{ prefix, contract.input_capacity });
    try out.print("#define {s}_OUTPUT_CAPACITY UINT32_C({d})\n", .{ prefix, contract.output_capacity });
    try out.print("#define {s}_CALL_DEPTH_LIMIT 1024u\n", .{prefix});
    try out.write(
        "#ifndef QIP_WASM_DIRTY_TRACKING\n" ++
            "#define QIP_WASM_DIRTY_TRACKING 1\n" ++
            "#endif\n" ++
            "#if QIP_WASM_DIRTY_TRACKING != 0 && QIP_WASM_DIRTY_TRACKING != 1\n" ++
            "#error \"QIP_WASM_DIRTY_TRACKING must be 0 or 1\"\n" ++
            "#endif\n\n",
    );
    try out.write(
        "#ifndef QIP_RENDER_WORKSPACE_ABI_V1\n" ++
            "#define QIP_RENDER_WORKSPACE_ABI_V1\n" ++
            "typedef struct qip_render_workspace {\n" ++
            "  uint8_t *memory;\n" ++
            "  size_t memory_size;\n" ++
            "} qip_render_workspace;\n" ++
            "typedef struct qip_render_workspace_private {\n" ++
            "  uint64_t generation;\n" ++
            "  uint64_t dirty_pages[];\n" ++
            "} qip_render_workspace_private;\n" ++
            "static inline size_t qip_render_workspace_dirty_words(size_t memory_size) {\n" ++
            "  size_t pages;\n" ++
            "  if (memory_size > SIZE_MAX - 65535u) return 0;\n" ++
            "  pages = (memory_size + 65535u) >> 16;\n" ++
            "  return (pages + 63u) >> 6;\n" ++
            "}\n" ++
            "static inline size_t qip_render_workspace_private_offset(size_t memory_size) {\n" ++
            "  if (memory_size > SIZE_MAX - 7u) return 0;\n" ++
            "  return (memory_size + 7u) & ~(size_t)7u;\n" ++
            "}\n" ++
            "static inline size_t qip_render_workspace_allocation_size(size_t memory_size) {\n" ++
            "  size_t offset = qip_render_workspace_private_offset(memory_size);\n" ++
            "  size_t words = qip_render_workspace_dirty_words(memory_size);\n" ++
            "  size_t trailer;\n" ++
            "  if (!offset && memory_size) return 0;\n" ++
            "  if (words > (SIZE_MAX - sizeof(qip_render_workspace_private)) / sizeof(uint64_t)) return 0;\n" ++
            "  trailer = sizeof(qip_render_workspace_private) + words * sizeof(uint64_t);\n" ++
            "  if (offset > SIZE_MAX - trailer) return 0;\n" ++
            "  return offset + trailer;\n" ++
            "}\n" ++
            "static inline qip_render_workspace_private *qip_render_workspace_private_data(qip_render_workspace *w) {\n" ++
            "  return (qip_render_workspace_private *)(void *)(w->memory + qip_render_workspace_private_offset(w->memory_size));\n" ++
            "}\n" ++
            "static inline void qip_render_workspace_mark_dirty(qip_render_workspace *w, size_t address, size_t width) {\n" ++
            "#if QIP_WASM_DIRTY_TRACKING != 0\n" ++
            "  qip_render_workspace_private *p;\n" ++
            "  size_t first, last, page;\n" ++
            "  if (!width) return;\n" ++
            "  p = qip_render_workspace_private_data(w);\n" ++
            "  first = address >> 16;\n" ++
            "  last = (address + width - 1u) >> 16;\n" ++
            "  for (page = first;; ++page) {\n" ++
            "    p->dirty_pages[page >> 6] |= UINT64_C(1) << (page & 63u);\n" ++
            "    if (page == last) break;\n" ++
            "  }\n" ++
            "#else\n" ++
            "  (void)w; (void)address; (void)width;\n" ++
            "#endif\n" ++
            "}\n" ++
            "static inline uint32_t qip_render_workspace_clear_except(qip_render_workspace *w, size_t keep, size_t keep_size) {\n" ++
            "  qip_render_workspace_private *p;\n" ++
            "  size_t keep_end, pages;\n" ++
            "  uint32_t count = 0;\n" ++
            "  if (!w || !w->memory || keep > w->memory_size || keep_size > w->memory_size - keep) return 0;\n" ++
            "  keep_end = keep + keep_size;\n" ++
            "  p = qip_render_workspace_private_data(w);\n" ++
            "#if QIP_WASM_DIRTY_TRACKING != 0\n" ++
            "  size_t page;\n" ++
            "  pages = (w->memory_size + 65535u) >> 16;\n" ++
            "  for (page = 0; page < pages; ++page) {\n" ++
            "    size_t start, end;\n" ++
            "    uint64_t mask = UINT64_C(1) << (page & 63u);\n" ++
            "    if (!(p->dirty_pages[page >> 6] & mask)) continue;\n" ++
            "    start = page << 16;\n" ++
            "    end = start + 65536u;\n" ++
            "    if (end > w->memory_size) end = w->memory_size;\n" ++
            "    if (start < keep && start < keep_end) memset(w->memory + start, 0, (keep < end ? keep : end) - start);\n" ++
            "    if (end > keep_end && end > keep) memset(w->memory + (keep_end > start ? keep_end : start), 0, end - (keep_end > start ? keep_end : start));\n" ++
            "    p->dirty_pages[page >> 6] &= ~mask;\n" ++
            "    ++count;\n" ++
            "  }\n" ++
            "#else\n" ++
            "  if (keep) memset(w->memory, 0, keep);\n" ++
            "  if (keep_end < w->memory_size) memset(w->memory + keep_end, 0, w->memory_size - keep_end);\n" ++
            "  pages = (w->memory_size + 65535u) >> 16;\n" ++
            "  count = (uint32_t)pages;\n" ++
            "#endif\n" ++
            "  qip_render_workspace_mark_dirty(w, keep, keep_size);\n" ++
            "  if (++p->generation == 0) ++p->generation;\n" ++
            "  return count;\n" ++
            "}\n" ++
            "static inline uint32_t qip_render_workspace_clear(qip_render_workspace *w) {\n" ++
            "  return qip_render_workspace_clear_except(w, 0, 0);\n" ++
            "}\n" ++
            "#endif\n\n",
    );
    try out.prefixed(prefix,
        \\typedef enum {P}_status {
        \\  {P}_OK = 0,
        \\  {P}_INPUT_TOO_LARGE = 1,
        \\  {P}_OUTPUT_TOO_LARGE = 2,
        \\  {P}_INVALID_ARGUMENT = 3,
        \\  {P}_MEMORY_TOO_SMALL = 4,
        \\  {P}_STALE_INSTANCE = 5,
        \\  {P}_REJECTED = 6,
        \\  {P}_TRAP_UNREACHABLE = 16,
        \\  {P}_TRAP_OOB = 17,
        \\  {P}_TRAP_CALL_DEPTH = 18,
        \\  {P}_TRAP_DIV_ZERO = 19,
        \\  {P}_TRAP_INT_OVERFLOW = 20,
        \\  {P}_TRAP_INVALID_CONVERSION = 21,
        \\  {P}_TRAP_TABLE_OOB = 22,
        \\  {P}_TRAP_INDIRECT_NULL = 23,
        \\  {P}_TRAP_INDIRECT_TYPE = 24
        \\} {P}_status;
        \\
        \\typedef union {P}_val {
        \\  uint32_t u32;
        \\  uint64_t u64;
        \\  float f32;
        \\  double f64;
        \\} {P}_val;
        \\
    );
    try out.print("typedef struct {s}_instance {{\n", .{prefix});
    try out.write(
        "  qip_render_workspace *workspace;\n" ++
            "  uint64_t *dirty_pages;\n" ++
            "  uint8_t *memory;\n" ++
            "  uint64_t workspace_generation;\n",
    );
    try out.print("  {s}_val g[{d}];\n", .{ prefix, @max(global_count, 1) });
    try out.print("  uint32_t table[{d}];\n", .{@max(table_size, 1)});
    try out.prefixed(prefix,
        \\  jmp_buf trap_target;
        \\  uint32_t trap_active;
        \\  uint32_t call_depth;
        \\  uint8_t data_dropped[
    );
    try out.print("{d}", .{@max(data_count, 1)});
    try out.prefixed(prefix,
        \\];
        \\} {P}_instance;
        \\
        \\{P}_status {P}_init(
        \\    {P}_instance *instance,
        \\    qip_render_workspace *workspace,
        \\    uint32_t input_size);
        \\uint32_t {P}_dirty_page_count(const {P}_instance *instance);
        \\{P}_status {P}_render(
        \\    {P}_instance *instance,
        \\    uint32_t input_size,
        \\    uint32_t *output_offset,
        \\    uint32_t *output_size);
        \\
        \\#ifdef QIP_WASM_GENERIC_API
        \\typedef {P}_instance qip_wasm_instance;
        \\typedef {P}_status qip_wasm_status;
        \\#define qip_wasm_init {P}_init
        \\#define qip_wasm_dirty_page_count {P}_dirty_page_count
        \\#define qip_wasm_render {P}_render
        \\#define QIP_WASM_MEMORY_SIZE {P}_MEMORY_SIZE
        \\#define QIP_WASM_INPUT_OFFSET {P}_INPUT_OFFSET
        \\#define QIP_WASM_INPUT_CAPACITY {P}_INPUT_CAPACITY
        \\#define QIP_WASM_OUTPUT_CAPACITY {P}_OUTPUT_CAPACITY
        \\#define QIP_WASM_OK {P}_OK
        \\#define QIP_WASM_INVALID_ARGUMENT {P}_INVALID_ARGUMENT
        \\#define QIP_WASM_MEMORY_TOO_SMALL {P}_MEMORY_TOO_SMALL
        \\#define QIP_WASM_STALE_INSTANCE {P}_STALE_INSTANCE
        \\#define QIP_WASM_TRAP_DIV_ZERO {P}_TRAP_DIV_ZERO
        \\#define QIP_WASM_TRAP_INVALID_CONVERSION {P}_TRAP_INVALID_CONVERSION
        \\#define QIP_WASM_TRAP_TABLE_OOB {P}_TRAP_TABLE_OOB
        \\#define QIP_WASM_TRAP_INDIRECT_NULL {P}_TRAP_INDIRECT_NULL
        \\#define QIP_WASM_TRAP_INDIRECT_TYPE {P}_TRAP_INDIRECT_TYPE
        \\#endif
        \\
        \\#ifdef QIP_WASM_IMPLEMENTATION
        \\#if defined(__clang__)
        \\#pragma clang diagnostic push
        \\#pragma clang diagnostic ignored "-Wunused-function"
        \\#elif defined(__GNUC__)
        \\#pragma GCC diagnostic push
        \\#pragma GCC diagnostic ignored "-Wunused-function"
        \\#endif
        \\
    );
}

fn writeRuntime(out: *Writer, prefix: []const u8) Error!void {
    try out.prefixed(prefix,
        \\static void {P}_trap({P}_instance *i, {P}_status status) {
        \\  i->call_depth = 0;
        \\  if (i->trap_active) longjmp(i->trap_target, (int)status);
        \\  abort();
        \\}
        \\
        \\static uint8_t *{P}_range({P}_instance *i, uint32_t address, uint32_t offset, uint32_t width) {
        \\  uint64_t start = (uint64_t)address + (uint64_t)offset;
        \\  if (start > {P}_MEMORY_SIZE || width > {P}_MEMORY_SIZE - start)
        \\    {P}_trap(i, {P}_TRAP_OOB);
        \\  return i->memory + start;
        \\}
        \\
        \\static void {P}_mark_dirty({P}_instance *i, uint64_t address, uint32_t width) {
        \\#if QIP_WASM_DIRTY_TRACKING != 0
        \\  uint32_t first, last, page;
        \\  if (width == 0) return;
        \\  first = (uint32_t)(address >> 16);
        \\  last = (uint32_t)((address + width - 1u) >> 16);
        \\  page = first;
        \\  for (;;) {
        \\    i->dirty_pages[page >> 6] |= UINT64_C(1) << (page & 63u);
        \\    if (page == last) break;
        \\    ++page;
        \\  }
        \\#else
        \\  (void)i; (void)address; (void)width;
        \\#endif
        \\}
        \\
        \\static uint8_t *{P}_write_range({P}_instance *i, uint32_t address, uint32_t offset, uint32_t width) {
        \\  uint8_t *result = {P}_range(i, address, offset, width);
        \\  {P}_mark_dirty(i, (uint64_t)address + offset, width);
        \\  return result;
        \\}
        \\
        \\uint32_t {P}_dirty_page_count(const {P}_instance *i) {
        \\  if (!i || !i->workspace || !i->memory) return 0;
        \\  if (i->workspace_generation != qip_render_workspace_private_data(i->workspace)->generation) return 0;
        \\#if QIP_WASM_DIRTY_TRACKING != 0
        \\  qip_render_workspace_private *p = qip_render_workspace_private_data(i->workspace);
        \\  uint32_t page, count = 0;
        \\  for (page = 0; page < {P}_MEMORY_PAGES; ++page)
        \\    count += (uint32_t)((p->dirty_pages[page >> 6] >> (page & 63u)) & 1u);
        \\  return count;
        \\#else
        \\  return {P}_MEMORY_PAGES;
        \\#endif
        \\}
        \\
        \\static {P}_val {P}_load_u32({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; memcpy(&v.u32, {P}_range(i,a,o,4),4); return v; }
        \\static {P}_val {P}_load_u64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; memcpy(&v.u64, {P}_range(i,a,o,8),8); return v; }
        \\static {P}_val {P}_load_f32({P}_instance *i, uint32_t a, uint32_t o) { return {P}_load_u32(i,a,o); }
        \\static {P}_val {P}_load_f64({P}_instance *i, uint32_t a, uint32_t o) { return {P}_load_u64(i,a,o); }
        \\static {P}_val {P}_load_i8_i32({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; v.u32=(uint32_t)(int32_t)(int8_t)*{P}_range(i,a,o,1); return v; }
        \\static {P}_val {P}_load_u8_i32({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; v.u32=*{P}_range(i,a,o,1); return v; }
        \\static {P}_val {P}_load_i16_i32({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; int16_t x; memcpy(&x,{P}_range(i,a,o,2),2); v.u32=(uint32_t)(int32_t)x; return v; }
        \\static {P}_val {P}_load_u16_i32({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; uint16_t x; memcpy(&x,{P}_range(i,a,o,2),2); v.u32=x; return v; }
        \\static {P}_val {P}_load_i8_i64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; v.u64=(uint64_t)(int64_t)(int8_t)*{P}_range(i,a,o,1); return v; }
        \\static {P}_val {P}_load_u8_i64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; v.u64=*{P}_range(i,a,o,1); return v; }
        \\static {P}_val {P}_load_i16_i64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; int16_t x; memcpy(&x,{P}_range(i,a,o,2),2); v.u64=(uint64_t)(int64_t)x; return v; }
        \\static {P}_val {P}_load_u16_i64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; uint16_t x; memcpy(&x,{P}_range(i,a,o,2),2); v.u64=x; return v; }
        \\static {P}_val {P}_load_i32_i64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; int32_t x; memcpy(&x,{P}_range(i,a,o,4),4); v.u64=(uint64_t)(int64_t)x; return v; }
        \\static {P}_val {P}_load_u32_i64({P}_instance *i, uint32_t a, uint32_t o) { {P}_val v; uint32_t x; memcpy(&x,{P}_range(i,a,o,4),4); v.u64=x; return v; }
        \\
        \\static void {P}_store_u32({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){memcpy({P}_write_range(i,a,o,4),&v.u32,4);}
        \\static void {P}_store_u64({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){memcpy({P}_write_range(i,a,o,8),&v.u64,8);}
        \\static void {P}_store_f32({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){{P}_store_u32(i,a,o,v);}
        \\static void {P}_store_f64({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){{P}_store_u64(i,a,o,v);}
        \\static void {P}_store8_i32({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){*{P}_write_range(i,a,o,1)=(uint8_t)v.u32;}
        \\static void {P}_store16_i32({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){uint16_t x=(uint16_t)v.u32;memcpy({P}_write_range(i,a,o,2),&x,2);}
        \\static void {P}_store8_i64({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){*{P}_write_range(i,a,o,1)=(uint8_t)v.u64;}
        \\static void {P}_store16_i64({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){uint16_t x=(uint16_t)v.u64;memcpy({P}_write_range(i,a,o,2),&x,2);}
        \\static void {P}_store32_i64({P}_instance*i,uint32_t a,uint32_t o,{P}_val v){uint32_t x=(uint32_t)v.u64;memcpy({P}_write_range(i,a,o,4),&x,4);}
        \\
        \\static uint32_t {P}_clz32(uint32_t x) { return x ? (uint32_t)__builtin_clz(x) : 32u; }
        \\static uint32_t {P}_ctz32(uint32_t x) { return x ? (uint32_t)__builtin_ctz(x) : 32u; }
        \\static uint32_t {P}_pop32(uint32_t x) { return (uint32_t)__builtin_popcount(x); }
        \\static uint64_t {P}_clz64(uint64_t x) { return x ? (uint64_t)__builtin_clzll(x) : 64u; }
        \\static uint64_t {P}_ctz64(uint64_t x) { return x ? (uint64_t)__builtin_ctzll(x) : 64u; }
        \\static uint64_t {P}_pop64(uint64_t x) { return (uint64_t)__builtin_popcountll(x); }
        \\static uint32_t {P}_rotl32(uint32_t x, uint32_t n) { n &= 31u; return (x << n) | (x >> ((32u - n) & 31u)); }
        \\static uint32_t {P}_rotr32(uint32_t x, uint32_t n) { n &= 31u; return (x >> n) | (x << ((32u - n) & 31u)); }
        \\static uint64_t {P}_rotl64(uint64_t x, uint64_t n) { n &= 63u; return (x << n) | (x >> ((64u - n) & 63u)); }
        \\static uint64_t {P}_rotr64(uint64_t x, uint64_t n) { n &= 63u; return (x >> n) | (x << ((64u - n) & 63u)); }
        \\static uint32_t {P}_bits_f32(float x) { uint32_t r; memcpy(&r, &x, 4); return r; }
        \\static uint64_t {P}_bits_f64(double x) { uint64_t r; memcpy(&r, &x, 8); return r; }
        \\static float {P}_from_bits_f32(uint32_t x) { float r; memcpy(&r, &x, 4); return r; }
        \\static double {P}_from_bits_f64(uint64_t x) { double r; memcpy(&r, &x, 8); return r; }
        \\
        \\static uint32_t {P}_sat_i32_f32_s(float x) { if (isnan(x)) return 0; if (x <= -2147483648.0f) return UINT32_C(0x80000000); if (x >= 2147483648.0f) return UINT32_C(0x7fffffff); return (uint32_t)(int32_t)x; }
        \\static uint32_t {P}_sat_i32_f32_u(float x) { if (isnan(x) || x <= 0) return 0; if (x >= 4294967296.0f) return UINT32_MAX; return (uint32_t)x; }
        \\static uint32_t {P}_sat_i32_f64_s(double x) { if (isnan(x)) return 0; if (x <= -2147483648.0) return UINT32_C(0x80000000); if (x >= 2147483648.0) return UINT32_C(0x7fffffff); return (uint32_t)(int32_t)x; }
        \\static uint32_t {P}_sat_i32_f64_u(double x) { if (isnan(x) || x <= 0) return 0; if (x >= 4294967296.0) return UINT32_MAX; return (uint32_t)x; }
        \\static uint64_t {P}_sat_i64_f32_s(float x) { if (isnan(x)) return 0; if (x <= -9223372036854775808.0f) return UINT64_C(0x8000000000000000); if (x >= 9223372036854775808.0f) return UINT64_C(0x7fffffffffffffff); return (uint64_t)(int64_t)x; }
        \\static uint64_t {P}_sat_i64_f32_u(float x) { if (isnan(x) || x <= 0) return 0; if (x >= 18446744073709551616.0f) return UINT64_MAX; return (uint64_t)x; }
        \\static uint64_t {P}_sat_i64_f64_s(double x) { if (isnan(x)) return 0; if (x <= -9223372036854775808.0) return UINT64_C(0x8000000000000000); if (x >= 9223372036854775808.0) return UINT64_C(0x7fffffffffffffff); return (uint64_t)(int64_t)x; }
        \\static uint64_t {P}_sat_i64_f64_u(double x) { if (isnan(x) || x <= 0) return 0; if (x >= 18446744073709551616.0) return UINT64_MAX; return (uint64_t)x; }
        \\
        \\static uint32_t {P}_trunc_i32_f32_s({P}_instance *i, float x) { if (isnan(x) || x < -2147483648.0f || x >= 2147483648.0f) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint32_t)(int32_t)x; }
        \\static uint32_t {P}_trunc_i32_f32_u({P}_instance *i, float x) { if (isnan(x) || x <= -1.0f || x >= 4294967296.0f) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint32_t)x; }
        \\static uint32_t {P}_trunc_i32_f64_s({P}_instance *i, double x) { if (isnan(x) || x <= -2147483649.0 || x >= 2147483648.0) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint32_t)(int32_t)x; }
        \\static uint32_t {P}_trunc_i32_f64_u({P}_instance *i, double x) { if (isnan(x) || x <= -1.0 || x >= 4294967296.0) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint32_t)x; }
        \\static uint64_t {P}_trunc_i64_f32_s({P}_instance *i, float x) { if (isnan(x) || x < -9223372036854775808.0f || x >= 9223372036854775808.0f) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint64_t)(int64_t)x; }
        \\static uint64_t {P}_trunc_i64_f32_u({P}_instance *i, float x) { if (isnan(x) || x <= -1.0f || x >= 18446744073709551616.0f) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint64_t)x; }
        \\static uint64_t {P}_trunc_i64_f64_s({P}_instance *i, double x) { if (isnan(x) || x < -9223372036854775808.0 || x >= 9223372036854775808.0) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint64_t)(int64_t)x; }
        \\static uint64_t {P}_trunc_i64_f64_u({P}_instance *i, double x) { if (isnan(x) || x <= -1.0 || x >= 18446744073709551616.0) {P}_trap(i,{P}_TRAP_INVALID_CONVERSION); return (uint64_t)x; }
        \\
    );
}

fn writeFunctionDeclarations(out: *Writer, prefix: []const u8) Error!void {
    var d: usize = 0;
    while (d < data_count) : (d += 1) {
        try out.print("static const uint8_t {s}_data_{d}[{d}];\n", .{
            prefix, d, @max(data_segments[d].bytes.len, 1),
        });
    }
    var i: usize = 0;
    while (i < function_count) : (i += 1) {
        try out.print("static {s}_val {s}_f{d}({s}_instance *, const {s}_val *);\n", .{ prefix, prefix, i, prefix, prefix });
    }
    try out.write("\n");
}

fn writeFunction(out: *Writer, prefix: []const u8, index: u32) Error!void {
    const function = functions[index];
    const ft = types[function.type_index];
    var r = Reader.init(function.body);
    const groups = try r.varU32();
    var local_count: u32 = ft.params_len;
    var g: u32 = 0;
    while (g < groups) : (g += 1) {
        const count = try r.varU32();
        _ = try valType(try r.byte());
        if (count > 65536 - local_count) return Error.TooManyItems;
        local_count += count;
    }

    var validation_reader = r;
    var validator = StackValidator{ .local_count = local_count };
    const max_stack = try validator.validate(&validation_reader, if (ft.result == null) 0 else 1);

    try out.print(
        \\static {s}_val {s}_f{d}({s}_instance *i, const {s}_val *args) {{
        \\  {s}_val s[{d}], v[{d}], z;
        \\  uint32_t sp = 0;
        \\  memset(v, 0, sizeof(v)); memset(&z, 0, sizeof(z));
        \\  (void)args; if (0) goto f_return;
        \\  if (++i->call_depth > {s}_CALL_DEPTH_LIMIT) {s}_trap(i, {s}_TRAP_CALL_DEPTH);
        \\
    , .{ prefix, prefix, index, prefix, prefix, prefix, @max(max_stack, 1), @max(local_count, 1), prefix, prefix, prefix });
    var p: u32 = 0;
    while (p < ft.params_len) : (p += 1) {
        try out.print("  v[{d}] = args[{d}];\n", .{ p, p });
    }
    const function_control = Control{
        .kind = .function,
        .id = 0xffffffff,
        .branch_arity = if (ft.result == null) 0 else 1,
        .end_arity = if (ft.result == null) 0 else 1,
    };
    var emitter = FunctionEmitter{
        .out = out,
        .prefix = prefix,
        .function_index = index,
        .local_count = local_count,
    };
    try emitter.pushControl(function_control);
    if (try emitter.sequence(&r, false)) return Error.InvalidSection;
    if (r.remaining() != 0) return Error.InvalidSection;
    try out.write("f_return: ;\n");
    try out.write("  --i->call_depth;\n");
    if (ft.result == null) {
        try out.write("  return z;\n}\n\n");
    } else {
        try out.write("  return s[sp - 1];\n}\n\n");
    }
}

fn writeInitializers(out: *Writer, prefix: []const u8, contract: Contract) Error!void {
    _ = contract;
    var d: usize = 0;
    while (d < data_count) : (d += 1) {
        const segment = data_segments[d];
        try out.print("static const uint8_t {s}_data_{d}[{d}] = {{", .{ prefix, d, @max(segment.bytes.len, 1) });
        if (segment.bytes.len == 0) try out.write(" 0,");
        for (segment.bytes, 0..) |b, i| {
            if (i % 16 == 0) try out.write("\n ");
            try out.print(" {d},", .{b});
        }
        try out.write("\n};\n");
    }
    try out.print(
        "\n{s}_status {s}_init({s}_instance *i, qip_render_workspace *workspace, uint32_t input_size) {{\n" ++
            "  qip_render_workspace_private *private_data;\n" ++
            "  if (!i || !workspace || !workspace->memory) return {s}_INVALID_ARGUMENT;\n" ++
            "  if (workspace->memory_size < (size_t){s}_MEMORY_SIZE) return {s}_MEMORY_TOO_SMALL;\n" ++
            "  if (input_size > {s}_INPUT_CAPACITY) return {s}_INPUT_TOO_LARGE;\n" ++
            "  qip_render_workspace_clear_except(workspace, {s}_INPUT_OFFSET, input_size);\n" ++
            "  memset(i, 0, sizeof(*i));\n" ++
            "  private_data = qip_render_workspace_private_data(workspace);\n" ++
            "  i->workspace = workspace;\n" ++
            "  i->dirty_pages = private_data->dirty_pages;\n" ++
            "  i->memory = workspace->memory;\n" ++
            "  i->workspace_generation = private_data->generation;\n",
        .{ prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix },
    );
    if (table_size != 0) {
        try out.print("  {{ uint32_t t; for (t = 0; t < {d}u; ++t) i->table[t] = UINT32_MAX; }}\n", .{table_size});
        var t: u32 = 0;
        while (t < table_size) : (t += 1) {
            if (table_elements[t] != std.math.maxInt(u32)) {
                try out.print("  i->table[{d}] = {d}u;\n", .{ t, table_elements[t] });
            }
        }
    }
    var g: usize = 0;
    while (g < global_count) : (g += 1) {
        const global = globals[g];
        switch (global.value_type) {
            .i32, .f32 => try out.print("  i->g[{d}].u32 = UINT32_C({d});\n", .{ g, global.initial.u32_ }),
            .i64, .f64 => try out.print("  i->g[{d}].u64 = UINT64_C({d});\n", .{ g, global.initial.u64_ }),
        }
    }
    d = 0;
    while (d < data_count) : (d += 1) {
        const segment = data_segments[d];
        if (!segment.passive) {
            const end = @as(u64, segment.offset) + segment.bytes.len;
            if (end > @as(u64, memory_min_pages) * 65536) return Error.InvalidSection;
            try out.print(
                "  memcpy({s}_write_range(i, {d}u, 0, {d}u), {s}_data_{d}, {d}u);\n",
                .{ prefix, segment.offset, segment.bytes.len, prefix, d, segment.bytes.len },
            );
        }
    }
    try out.print(
        "  return {s}_OK;\n" ++
            "}}\n\n",
        .{prefix},
    );
}

fn writeWrapper(out: *Writer, prefix: []const u8, contract: Contract) Error!void {
    try out.print(
        \\{s}_status {s}_render(
        \\    {s}_instance *i, uint32_t input_size,
        \\    uint32_t *output_offset, uint32_t *output_size) {{
        \\  {s}_val arg, result;
        \\  qip_render_workspace_private *private_data;
        \\  uint64_t render_result;
        \\  uint32_t output_ptr, n;
        \\  int trapped;
        \\  if (!i || !i->workspace || !i->memory || !output_offset || !output_size) return {s}_INVALID_ARGUMENT;
        \\  private_data = qip_render_workspace_private_data(i->workspace);
        \\  if (i->workspace_generation != private_data->generation) return {s}_STALE_INSTANCE;
        \\  if (input_size > {s}_INPUT_CAPACITY) return {s}_INPUT_TOO_LARGE;
        \\  i->call_depth = 0; i->trap_active = 1;
        \\  trapped = setjmp(i->trap_target);
        \\  if (trapped) {{ i->trap_active = 0; i->call_depth = 0; return ({s}_status)trapped; }}
        \\  {s}_mark_dirty(i, {s}_INPUT_OFFSET, input_size);
        \\  arg.u32 = input_size;
        \\  result = {s}_f{d}(i, &arg);
        \\  render_result = result.u64;
        \\  n = (uint32_t)render_result;
        \\  if (render_result >> 63) {{
        \\    *output_offset = 0;
        \\    *output_size = n;
        \\    i->trap_active = 0;
        \\    return {s}_REJECTED;
        \\  }}
        \\  output_ptr = (uint32_t)((render_result >> 32) & UINT64_C(0x7fffffff));
        \\  if (n > {s}_OUTPUT_CAPACITY ||
        \\      (uint64_t)output_ptr + n > {s}_MEMORY_SIZE) {{
        \\    i->trap_active = 0;
        \\    return {s}_OUTPUT_TOO_LARGE;
        \\  }}
        \\  *output_offset = output_ptr;
        \\  *output_size = n;
        \\  i->trap_active = 0;
        \\  return {s}_OK;
        \\}}
        \\
        \\#if defined(__clang__)
        \\#pragma clang diagnostic pop
        \\#elif defined(__GNUC__)
        \\#pragma GCC diagnostic pop
        \\#endif
        \\#endif /* QIP_WASM_IMPLEMENTATION */
        \\#ifdef __cplusplus
        \\}}
        \\#endif
        \\#endif
        \\
    , .{
        prefix,          prefix, prefix, prefix,
        prefix,          prefix, prefix, prefix,
        prefix,          prefix, prefix, prefix,
        contract.render, prefix, prefix, prefix,
        prefix,          prefix,
    });
}

fn generate(wasm: []const u8) Error!usize {
    try parseModule(wasm);
    const contract = try readContract();
    const hash = moduleHash(wasm);
    var hash_hex_buf: [64]u8 = undefined;
    const hash_hex = std.fmt.bufPrint(&hash_hex_buf, "{x}", .{hash}) catch return Error.TooManyItems;
    // The first 128 bits keep generated identifiers manageable while retaining
    // ample collision resistance for independently bundled components.
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "qip_wasm_{s}", .{hash_hex[0..32]}) catch return Error.TooManyItems;
    var out = Writer{};
    try writePreamble(&out, prefix, hash_hex, contract);
    try writeRuntime(&out, prefix);
    try writeFunctionDeclarations(&out, prefix);
    var i: u32 = 0;
    while (i < function_count) : (i += 1) try writeFunction(&out, prefix, i);
    try writeInitializers(&out, prefix, contract);
    try writeWrapper(&out, prefix, contract);
    return out.pos;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    return @intCast(generate(input_buf[0..input_size]) catch @trap());
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn expectInvalidIndexInstruction(bytes: []const u8, local_count: u32) !void {
    var out = Writer{};
    var emitter = FunctionEmitter{
        .out = &out,
        .prefix = "test",
        .function_index = 0,
        .local_count = local_count,
    };
    var reader = Reader.init(bytes);
    try std.testing.expectError(Error.InvalidIndex, emitter.sequence(&reader, false));
    try std.testing.expectEqual(@as(usize, 0), out.pos);
}

fn validateTestStack(bytes: []const u8, result_arity: u1) Error!u32 {
    var reader = Reader.init(bytes);
    var validator = StackValidator{ .local_count = 0 };
    return validator.validate(&reader, result_arity);
}

test "reject out-of-range local instruction indices before emitting C" {
    const instructions = [_]u8{ 0x20, 0x21, 0x22 };
    for (instructions) |instruction| {
        const body = [_]u8{ instruction, 0x01, 0x0b };
        try expectInvalidIndexInstruction(&body, 1);
    }
}

test "reject out-of-range global instruction indices before emitting C" {
    resetModule();
    defer resetModule();
    global_count = 1;
    globals[0] = .{
        .value_type = .i32,
        .mutable = true,
        .initial = .{ .u32_ = 0 },
    };

    const instructions = [_]u8{ 0x23, 0x24 };
    for (instructions) |instruction| {
        const body = [_]u8{ instruction, 0x01, 0x0b };
        try expectInvalidIndexInstruction(&body, 0);
    }
}

test "reject writes to immutable globals before emitting C" {
    resetModule();
    defer resetModule();
    global_count = 1;
    globals[0] = .{
        .value_type = .i32,
        .mutable = false,
        .initial = .{ .u32_ = 0 },
    };

    const body = [_]u8{ 0x24, 0x00, 0x0b };
    try expectInvalidIndexInstruction(&body, 0);
}

test "reject operand stack underflow" {
    const body = [_]u8{ 0x6a, 0x0b }; // i32.add; end
    try std.testing.expectError(Error.StackUnderflow, validateTestStack(&body, 0));
}

test "reject extra operand stack values at function end" {
    const body = [_]u8{ 0x41, 0x00, 0x0b }; // i32.const 0; end
    try std.testing.expectError(Error.StackMismatch, validateTestStack(&body, 0));
}

test "do not consume values below a block stack boundary" {
    const body = [_]u8{
        0x41, 0x00, // i32.const 0
        0x02, 0x40, // block
        0x1a, // drop
        0x0b, // end block
        0x1a, // drop
        0x0b, // end function
    };
    try std.testing.expectError(Error.StackUnderflow, validateTestStack(&body, 0));
}

test "accept balanced polymorphic dead code" {
    const body = [_]u8{
        0x00, // unreachable
        0x6a, // i32.add consumes polymorphic values
        0x1a, // drop
        0x0b, // end function
    };
    try std.testing.expectEqual(@as(u32, 1), try validateTestStack(&body, 0));
}

test "compute the exact maximum operand stack height" {
    const body = [_]u8{
        0x41, 0x01, // i32.const 1
        0x41, 0x02, // i32.const 2
        0x6a, // i32.add
        0x0b, // end function
    };
    try std.testing.expectEqual(@as(u32, 2), try validateTestStack(&body, 1));
}

test "size generated C operand arrays from maximum stack height" {
    resetModule();
    defer resetModule();
    types[0] = .{ .params_off = 0, .params_len = 0, .result = .i32 };
    type_count = 1;
    functions[0] = .{
        .type_index = 0,
        .body = &.{
            0x00, // no local groups
            0x41, 0x01, // i32.const 1
            0x41, 0x02, // i32.const 2
            0x6a, // i32.add
            0x0b, // end function
        },
    };
    function_count = 1;

    var out = Writer{};
    try writeFunction(&out, "test", 0);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..out.pos], "test_val s[2], v[1], z;") != null);
}

test "reject operand stacks above the translation limit" {
    var validator = StackValidator{ .local_count = 0 };
    try validator.push(MAX_STACK_VALUES);
    try std.testing.expectError(Error.TooManyItems, validator.push(1));
}
