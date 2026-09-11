//! Translate a bounded QIP Content component to native Swift source.
//!
//! Supported profile:
//! - One defined wasm32 memory with a declared maximum. Generated code uses the
//!   fixed initial size and checks every memory access.
//! - Core 1.0 structured control flow and scalar integer and floating-point
//!   instructions, except the policy-disabled `memory.grow` instruction.
//! - Scalar globals, direct calls, and single-value function and block results.
//! - One fixed funcref table, active function-index element segments, and
//!   `call_indirect` with bounds, null, structural type, and call-depth checks.
//! - Active data segments, sign extension, `memory.size`, `memory.copy`, and
//!   `memory.fill`.
//! - Recoverable numeric and memory traps, caller-owned raw memory buffers,
//!   shared-workspace turnover, and dirty-page tracking.
//!
//! Explicitly disabled or not implemented:
//! - Imports, WASI, host callbacks, and start functions.
//! - `memory.grow`, shared memory, threads, and atomic instructions.
//! - Multiple memories or tables, table mutation, table bulk operations,
//!   general reference instructions, and externref.
//! - Passive data segments, `memory.init`, and `data.drop`.
//! - Saturating float-to-integer conversions.
//! - Multi-value functions and blocks, and type-index block signatures.
//! - SIMD and post-Core-2.0 features such as exceptions and tail calls.
//!
//! Unsupported sections and instructions fail closed. Generated code targets
//! fixed little-endian memory. Generated components are single-threaded and
//! isolated except for raw memory buffers that the host explicitly shares.

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
const MAX_TABLE_ELEMENTS: usize = 16384;

const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/x-swift";

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

const FunctionEmitter = struct {
    out: *Writer,
    controls: [MAX_CONTROLS]Control = undefined,
    control_count: usize = 0,
    next_label: u32 = 0,
    next_call: u32 = 0,

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

    fn blockArity(r: *Reader) Error!u1 {
        return switch (try r.byte()) {
            0x40 => 0,
            0x7f, 0x7e, 0x7d, 0x7c => 1,
            else => Error.UnsupportedFeature,
        };
    }

    fn normalize(self: *FunctionEmitter, control: Control, for_branch: bool) Error!void {
        const arity = if (for_branch) control.branch_arity else control.end_arity;
        if (control.kind == .function) {
            if (arity == 0) {
                try self.out.write("            sp = 0\n");
            } else {
                try self.out.write("            stack[0] = stack[sp - 1]; sp = 1\n");
            }
        } else if (arity == 0) {
            try self.out.print("            sp = base{d}\n", .{control.id});
        } else {
            try self.out.print("            stack[base{d}] = stack[sp - 1]; sp = base{d} + 1\n", .{ control.id, control.id });
        }
    }

    fn branch(self: *FunctionEmitter, control: Control) Error!void {
        try self.normalize(control, true);
        switch (control.kind) {
            .function => try self.out.write("            if always() { break functionExit }\n"),
            .loop => try self.out.print("            if always() {{ continue label{d} }}\n", .{control.id}),
            else => try self.out.print("            if always() {{ break label{d} }}\n", .{control.id}),
        }
    }

    fn memarg(r: *Reader) Error!u32 {
        _ = try r.varU32();
        return r.varU32();
    }

    fn emitLoad(self: *FunctionEmitter, op: u8, r: *Reader) Error!void {
        const helper = switch (op) {
            0x28 => "loadU32",
            0x29 => "loadU64",
            0x2a => "loadF32",
            0x2b => "loadF64",
            0x2c => "loadI8I32",
            0x2d => "loadU8I32",
            0x2e => "loadI16I32",
            0x2f => "loadU16I32",
            0x30 => "loadI8I64",
            0x31 => "loadU8I64",
            0x32 => "loadI16I64",
            0x33 => "loadU16I64",
            0x34 => "loadI32I64",
            0x35 => "loadU32I64",
            else => return Error.UnsupportedFeature,
        };
        try self.out.print("            stack[sp - 1] = try {s}(&instance, stack[sp - 1].u32, {d})\n", .{ helper, try memarg(r) });
    }

    fn emitStore(self: *FunctionEmitter, op: u8, r: *Reader) Error!void {
        const helper = switch (op) {
            0x36 => "storeU32",
            0x37 => "storeU64",
            0x38 => "storeF32",
            0x39 => "storeF64",
            0x3a => "store8I32",
            0x3b => "store16I32",
            0x3c => "store8I64",
            0x3d => "store16I64",
            0x3e => "store32I64",
            else => return Error.UnsupportedFeature,
        };
        try self.out.print("            try {s}(&instance, stack[sp - 2].u32, {d}, stack[sp - 1]); sp -= 2\n", .{ helper, try memarg(r) });
    }

    fn emitI32Binary(self: *FunctionEmitter, expression: []const u8) Error!void {
        try self.out.print("            stack[sp - 2].u32 = {s}; sp -= 1\n", .{expression});
    }

    fn emitI64Binary(self: *FunctionEmitter, expression: []const u8) Error!void {
        try self.out.print("            stack[sp - 2].u64 = {s}; sp -= 1\n", .{expression});
    }

    fn emitF32Binary(self: *FunctionEmitter, expression: []const u8) Error!void {
        try self.out.print("            stack[sp - 2].f32 = {s}; sp -= 1\n", .{expression});
    }

    fn emitF64Binary(self: *FunctionEmitter, expression: []const u8) Error!void {
        try self.out.print("            stack[sp - 2].f64 = {s}; sp -= 1\n", .{expression});
    }

    fn emitCall(self: *FunctionEmitter, index: u32) Error!void {
        if (index >= function_count) return Error.InvalidIndex;
        const ft = types[functions[index].type_index];
        const call_id = self.next_call;
        self.next_call += 1;
        if (ft.params_len != 0) {
            try self.out.print("            var args{d}: [Val] = [Val](repeating: Val(), count: {d}); sp -= {d}\n", .{ call_id, ft.params_len, ft.params_len });
            var p: u32 = 0;
            while (p < ft.params_len) : (p += 1) {
                try self.out.print("            args{d}[{d}] = stack[sp + {d}]\n", .{ call_id, p, p });
            }
        }
        if (ft.result != null) try self.out.write("            stack[sp] = ") else try self.out.write("            _ = ");
        try self.out.print("try qipWasmFunction{d}(&instance, {s})", .{
            index,
            if (ft.params_len == 0) "[]" else blk: {
                var buf: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(&buf, "args{d}", .{call_id}) catch return Error.TooManyItems;
            },
        });
        if (ft.result != null) try self.out.write("; sp += 1");
        try self.out.write("\n");
    }

    fn emitCallIndirect(self: *FunctionEmitter, r: *Reader) Error!void {
        const type_index = try r.varU32();
        if (type_index >= type_count or try r.varU32() != 0 or table_size == 0)
            return Error.InvalidIndex;
        const ft = types[type_index];
        const call_id = self.next_call;
        self.next_call += 1;
        try self.out.print(
            "            sp -= 1; let tableIndex{d}: UInt32 = stack[sp].u32; if tableIndex{d} >= {d} {{ throw trap(&instance, .trapTableOutOfBounds) }}; let functionIndex{d}: UInt32 = table[Int(tableIndex{d})]; if functionIndex{d} == UInt32.max {{ throw trap(&instance, .trapIndirectNull) }}\n",
            .{ call_id, call_id, table_size, call_id, call_id, call_id },
        );
        try self.out.print("            {s} indirectArgs{d}: [Val] = [Val](repeating: Val(), count: {d}); sp -= {d}\n", .{
            if (ft.params_len == 0) "let" else "var",
            call_id,
            @max(ft.params_len, 1),
            ft.params_len,
        });
        var p: u32 = 0;
        while (p < ft.params_len) : (p += 1) {
            try self.out.print("            indirectArgs{d}[{d}] = stack[sp + {d}]\n", .{ call_id, p, p });
        }
        try self.out.print("            switch functionIndex{d} {{\n", .{call_id});
        var function_index: u32 = 0;
        while (function_index < function_count) : (function_index += 1) {
            if (!sameFunctionType(type_index, functions[function_index].type_index)) continue;
            if (ft.result == null) {
                try self.out.print("            case {d}: _ = try qipWasmFunction{d}(&instance, indirectArgs{d})\n", .{
                    function_index, function_index, call_id,
                });
            } else {
                try self.out.print("            case {d}: stack[sp] = try qipWasmFunction{d}(&instance, indirectArgs{d})\n", .{
                    function_index, function_index, call_id,
                });
            }
        }
        try self.out.write("            default: throw trap(&instance, .trapIndirectType)\n            }\n");
        if (ft.result != null) try self.out.write("            sp += 1\n");
    }

    fn emitBrTable(self: *FunctionEmitter, r: *Reader) Error!void {
        const count = try r.varU32();
        if (count > MAX_CONTROLS) return Error.TooManyItems;
        try self.out.write("            sp -= 1; switch stack[sp].u32 {\n");
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try self.out.print("            case {d}:\n", .{i});
            try self.branch(try self.target(try r.varU32()));
        }
        try self.out.write("            default:\n");
        try self.branch(try self.target(try r.varU32()));
        try self.out.write("            }\n");
    }

    fn emitBulkMemory(self: *FunctionEmitter, r: *Reader) Error!void {
        switch (try r.varU32()) {
            10 => {
                if (try r.varU32() != 0 or try r.varU32() != 0) return Error.InvalidIndex;
                try self.out.write("            try memoryCopy(&instance, stack[sp - 3].u32, stack[sp - 2].u32, stack[sp - 1].u32); sp -= 3\n");
            },
            11 => {
                if (try r.varU32() != 0) return Error.InvalidIndex;
                try self.out.write("            try memoryFill(&instance, stack[sp - 3].u32, stack[sp - 2].u32, stack[sp - 1].u32); sp -= 3\n");
            },
            else => return Error.UnsupportedFeature,
        }
    }

    /// Emit through the matching end. Returns true when it stopped at `else`.
    fn sequence(self: *FunctionEmitter, r: *Reader, allow_else: bool) Error!bool {
        while (r.remaining() != 0) {
            const op = try r.byte();
            switch (op) {
                0x00 => try self.out.write("            throw trap(&instance, .trapUnreachable)\n"),
                0x01 => {},
                0x02 => {
                    const arity = try blockArity(r);
                    const id = self.next_label;
                    self.next_label += 1;
                    const control = Control{ .kind = .block, .id = id, .branch_arity = arity, .end_arity = arity };
                    try self.out.print("            let base{d}: Int = sp\n            label{d}: do {{ if !always() {{ break label{d} }}\n", .{ id, id, id });
                    try self.pushControl(control);
                    if (try self.sequence(r, false)) return Error.InvalidSection;
                    self.popControl();
                    try self.out.write("            }\n");
                    try self.normalize(control, false);
                },
                0x03 => {
                    const arity = try blockArity(r);
                    const id = self.next_label;
                    self.next_label += 1;
                    const control = Control{ .kind = .loop, .id = id, .branch_arity = 0, .end_arity = arity };
                    try self.out.print("            let base{d}: Int = sp\n            label{d}: while true {{\n", .{ id, id });
                    try self.pushControl(control);
                    if (try self.sequence(r, false)) return Error.InvalidSection;
                    self.popControl();
                    try self.out.print("                break label{d}\n            }}\n", .{id});
                    try self.normalize(control, false);
                },
                0x04 => {
                    const arity = try blockArity(r);
                    const id = self.next_label;
                    self.next_label += 1;
                    const control = Control{ .kind = .if_, .id = id, .branch_arity = arity, .end_arity = arity };
                    try self.out.print("            sp -= 1\n            let condition{d}: UInt32 = stack[sp].u32\n            let base{d}: Int = sp\n            label{d}: do {{ if !always() {{ break label{d} }}\n                if condition{d} != 0 {{\n", .{ id, id, id, id, id });
                    try self.pushControl(control);
                    const had_else = try self.sequence(r, true);
                    if (had_else) {
                        try self.out.write("                } else {\n");
                        if (try self.sequence(r, false)) return Error.InvalidSection;
                    }
                    self.popControl();
                    try self.out.write("                }\n            }\n");
                    try self.normalize(control, false);
                },
                0x05 => {
                    if (!allow_else) return Error.InvalidSection;
                    return true;
                },
                0x0b => return false,
                0x0c => try self.branch(try self.target(try r.varU32())),
                0x0d => {
                    const control = try self.target(try r.varU32());
                    try self.out.write("            sp -= 1\n            if stack[sp].u32 != 0 {\n");
                    try self.branch(control);
                    try self.out.write("            }\n");
                },
                0x0e => try self.emitBrTable(r),
                0x0f => try self.branch(self.controls[0]),
                0x10 => try self.emitCall(try r.varU32()),
                0x11 => try self.emitCallIndirect(r),
                0x1a => try self.out.write("            sp -= 1\n"),
                0x1b => try self.out.write("            sp -= 1; if stack[sp].u32 == 0 { sp -= 1; stack[sp - 1] = stack[sp] } else { sp -= 1 }\n"),
                0x20 => try self.out.print("            stack[sp] = locals[{d}]; sp += 1\n", .{try r.varU32()}),
                0x21 => try self.out.print("            sp -= 1; locals[{d}] = stack[sp]\n", .{try r.varU32()}),
                0x22 => try self.out.print("            locals[{d}] = stack[sp - 1]\n", .{try r.varU32()}),
                0x23 => try self.out.print("            stack[sp] = instance.globals[{d}]; sp += 1\n", .{try r.varU32()}),
                0x24 => try self.out.print("            sp -= 1; instance.globals[{d}] = stack[sp]\n", .{try r.varU32()}),
                0x28...0x35 => try self.emitLoad(op, r),
                0x36...0x3e => try self.emitStore(op, r),
                0x3f => {
                    if (try r.byte() != 0) return Error.InvalidIndex;
                    try self.out.print("            stack[sp].u32 = {d}; sp += 1\n", .{memory_min_pages});
                },
                0x40 => return Error.UnsupportedFeature,
                0x41 => try self.out.print("            stack[sp].u32 = {d}; sp += 1\n", .{@as(u32, @bitCast(try r.s32()))}),
                0x42 => try self.out.print("            stack[sp].u64 = {d}; sp += 1\n", .{@as(u64, @bitCast(try r.s64()))}),
                0x43 => try self.out.print("            stack[sp].u32 = {d}; sp += 1\n", .{try r.fixedU32()}),
                0x44 => try self.out.print("            stack[sp].u64 = {d}; sp += 1\n", .{try r.fixedU64()}),
                0x45 => try self.out.write("            stack[sp - 1].u32 = bool32(stack[sp - 1].u32 == 0)\n"),
                0x46 => try self.emitI32Binary("bool32(stack[sp - 2].u32 == stack[sp - 1].u32)"),
                0x47 => try self.emitI32Binary("bool32(stack[sp - 2].u32 != stack[sp - 1].u32)"),
                0x48 => try self.emitI32Binary("bool32(s32(stack[sp - 2].u32) < s32(stack[sp - 1].u32))"),
                0x49 => try self.emitI32Binary("bool32(stack[sp - 2].u32 < stack[sp - 1].u32)"),
                0x4a => try self.emitI32Binary("bool32(s32(stack[sp - 2].u32) > s32(stack[sp - 1].u32))"),
                0x4b => try self.emitI32Binary("bool32(stack[sp - 2].u32 > stack[sp - 1].u32)"),
                0x4c => try self.emitI32Binary("bool32(s32(stack[sp - 2].u32) <= s32(stack[sp - 1].u32))"),
                0x4d => try self.emitI32Binary("bool32(stack[sp - 2].u32 <= stack[sp - 1].u32)"),
                0x4e => try self.emitI32Binary("bool32(s32(stack[sp - 2].u32) >= s32(stack[sp - 1].u32))"),
                0x4f => try self.emitI32Binary("bool32(stack[sp - 2].u32 >= stack[sp - 1].u32)"),
                0x50 => try self.out.write("            stack[sp - 1].u32 = bool32(stack[sp - 1].u64 == 0)\n"),
                0x51 => try self.emitI64Binary("UInt64(bool32(stack[sp - 2].u64 == stack[sp - 1].u64))"),
                0x52 => try self.emitI64Binary("UInt64(bool32(stack[sp - 2].u64 != stack[sp - 1].u64))"),
                0x53 => try self.emitI64Binary("UInt64(bool32(s64(stack[sp - 2].u64) < s64(stack[sp - 1].u64)))"),
                0x54 => try self.emitI64Binary("UInt64(bool32(stack[sp - 2].u64 < stack[sp - 1].u64))"),
                0x55 => try self.emitI64Binary("UInt64(bool32(s64(stack[sp - 2].u64) > s64(stack[sp - 1].u64)))"),
                0x56 => try self.emitI64Binary("UInt64(bool32(stack[sp - 2].u64 > stack[sp - 1].u64))"),
                0x57 => try self.emitI64Binary("UInt64(bool32(s64(stack[sp - 2].u64) <= s64(stack[sp - 1].u64)))"),
                0x58 => try self.emitI64Binary("UInt64(bool32(stack[sp - 2].u64 <= stack[sp - 1].u64))"),
                0x59 => try self.emitI64Binary("UInt64(bool32(s64(stack[sp - 2].u64) >= s64(stack[sp - 1].u64)))"),
                0x5a => try self.emitI64Binary("UInt64(bool32(stack[sp - 2].u64 >= stack[sp - 1].u64))"),
                0x5b => try self.emitI32Binary("bool32(stack[sp - 2].f32 == stack[sp - 1].f32)"),
                0x5c => try self.emitI32Binary("bool32(stack[sp - 2].f32 != stack[sp - 1].f32)"),
                0x5d => try self.emitI32Binary("bool32(stack[sp - 2].f32 < stack[sp - 1].f32)"),
                0x5e => try self.emitI32Binary("bool32(stack[sp - 2].f32 > stack[sp - 1].f32)"),
                0x5f => try self.emitI32Binary("bool32(stack[sp - 2].f32 <= stack[sp - 1].f32)"),
                0x60 => try self.emitI32Binary("bool32(stack[sp - 2].f32 >= stack[sp - 1].f32)"),
                0x61 => try self.emitI32Binary("bool32(stack[sp - 2].f64 == stack[sp - 1].f64)"),
                0x62 => try self.emitI32Binary("bool32(stack[sp - 2].f64 != stack[sp - 1].f64)"),
                0x63 => try self.emitI32Binary("bool32(stack[sp - 2].f64 < stack[sp - 1].f64)"),
                0x64 => try self.emitI32Binary("bool32(stack[sp - 2].f64 > stack[sp - 1].f64)"),
                0x65 => try self.emitI32Binary("bool32(stack[sp - 2].f64 <= stack[sp - 1].f64)"),
                0x66 => try self.emitI32Binary("bool32(stack[sp - 2].f64 >= stack[sp - 1].f64)"),
                0x67 => try self.out.write("            stack[sp - 1].u32 = UInt32(stack[sp - 1].u32.leadingZeroBitCount)\n"),
                0x68 => try self.out.write("            stack[sp - 1].u32 = UInt32(stack[sp - 1].u32.trailingZeroBitCount)\n"),
                0x69 => try self.out.write("            stack[sp - 1].u32 = UInt32(stack[sp - 1].u32.nonzeroBitCount)\n"),
                0x6a => try self.emitI32Binary("stack[sp - 2].u32 &+ stack[sp - 1].u32"),
                0x6b => try self.emitI32Binary("stack[sp - 2].u32 &- stack[sp - 1].u32"),
                0x6c => try self.emitI32Binary("stack[sp - 2].u32 &* stack[sp - 1].u32"),
                0x6d => try self.out.write("            try divS32(&instance, &stack[sp - 2], stack[sp - 1].u32); sp -= 1\n"),
                0x6e => try self.out.write("            if stack[sp - 1].u32 == 0 { throw trap(&instance, .trapDivZero) }; stack[sp - 2].u32 /= stack[sp - 1].u32; sp -= 1\n"),
                0x6f => try self.out.write("            try remS32(&instance, &stack[sp - 2], stack[sp - 1].u32); sp -= 1\n"),
                0x70 => try self.out.write("            if stack[sp - 1].u32 == 0 { throw trap(&instance, .trapDivZero) }; stack[sp - 2].u32 %= stack[sp - 1].u32; sp -= 1\n"),
                0x71 => try self.emitI32Binary("stack[sp - 2].u32 & stack[sp - 1].u32"),
                0x72 => try self.emitI32Binary("stack[sp - 2].u32 | stack[sp - 1].u32"),
                0x73 => try self.emitI32Binary("stack[sp - 2].u32 ^ stack[sp - 1].u32"),
                0x74 => try self.emitI32Binary("stack[sp - 2].u32 << (stack[sp - 1].u32 & 31)"),
                0x75 => try self.emitI32Binary("UInt32(bitPattern: s32(stack[sp - 2].u32) >> (stack[sp - 1].u32 & 31))"),
                0x76 => try self.emitI32Binary("stack[sp - 2].u32 >> (stack[sp - 1].u32 & 31)"),
                0x77 => try self.emitI32Binary("rotl32(stack[sp - 2].u32, stack[sp - 1].u32)"),
                0x78 => try self.emitI32Binary("rotr32(stack[sp - 2].u32, stack[sp - 1].u32)"),
                0x79 => try self.out.write("            stack[sp - 1].u64 = UInt64(stack[sp - 1].u64.leadingZeroBitCount)\n"),
                0x7a => try self.out.write("            stack[sp - 1].u64 = UInt64(stack[sp - 1].u64.trailingZeroBitCount)\n"),
                0x7b => try self.out.write("            stack[sp - 1].u64 = UInt64(stack[sp - 1].u64.nonzeroBitCount)\n"),
                0x7c => try self.emitI64Binary("stack[sp - 2].u64 &+ stack[sp - 1].u64"),
                0x7d => try self.emitI64Binary("stack[sp - 2].u64 &- stack[sp - 1].u64"),
                0x7e => try self.emitI64Binary("stack[sp - 2].u64 &* stack[sp - 1].u64"),
                0x7f => try self.out.write("            try divS64(&instance, &stack[sp - 2], stack[sp - 1].u64); sp -= 1\n"),
                0x80 => try self.out.write("            if stack[sp - 1].u64 == 0 { throw trap(&instance, .trapDivZero) }; stack[sp - 2].u64 /= stack[sp - 1].u64; sp -= 1\n"),
                0x81 => try self.out.write("            try remS64(&instance, &stack[sp - 2], stack[sp - 1].u64); sp -= 1\n"),
                0x82 => try self.out.write("            if stack[sp - 1].u64 == 0 { throw trap(&instance, .trapDivZero) }; stack[sp - 2].u64 %= stack[sp - 1].u64; sp -= 1\n"),
                0x83 => try self.emitI64Binary("stack[sp - 2].u64 & stack[sp - 1].u64"),
                0x84 => try self.emitI64Binary("stack[sp - 2].u64 | stack[sp - 1].u64"),
                0x85 => try self.emitI64Binary("stack[sp - 2].u64 ^ stack[sp - 1].u64"),
                0x86 => try self.emitI64Binary("stack[sp - 2].u64 << (stack[sp - 1].u64 & 63)"),
                0x87 => try self.emitI64Binary("UInt64(bitPattern: s64(stack[sp - 2].u64) >> (stack[sp - 1].u64 & 63))"),
                0x88 => try self.emitI64Binary("stack[sp - 2].u64 >> (stack[sp - 1].u64 & 63)"),
                0x89 => try self.emitI64Binary("rotl64(stack[sp - 2].u64, stack[sp - 1].u64)"),
                0x8a => try self.emitI64Binary("rotr64(stack[sp - 2].u64, stack[sp - 1].u64)"),
                0x8b => try self.out.write("            stack[sp - 1].f32 = absF32(stack[sp - 1].f32)\n"),
                0x8c => try self.out.write("            stack[sp - 1].f32 = negF32(stack[sp - 1].f32)\n"),
                0x8d => try self.out.write("            stack[sp - 1].f32 = stack[sp - 1].f32.rounded(.up)\n"),
                0x8e => try self.out.write("            stack[sp - 1].f32 = stack[sp - 1].f32.rounded(.down)\n"),
                0x8f => try self.out.write("            stack[sp - 1].f32 = stack[sp - 1].f32.rounded(.towardZero)\n"),
                0x90 => try self.out.write("            stack[sp - 1].f32 = stack[sp - 1].f32.rounded(.toNearestOrEven)\n"),
                0x91 => try self.out.write("            stack[sp - 1].f32 = stack[sp - 1].f32.squareRoot()\n"),
                0x92 => try self.emitF32Binary("stack[sp - 2].f32 + stack[sp - 1].f32"),
                0x93 => try self.emitF32Binary("stack[sp - 2].f32 - stack[sp - 1].f32"),
                0x94 => try self.emitF32Binary("stack[sp - 2].f32 * stack[sp - 1].f32"),
                0x95 => try self.emitF32Binary("stack[sp - 2].f32 / stack[sp - 1].f32"),
                0x96 => try self.emitF32Binary("minF32(stack[sp - 2].f32, stack[sp - 1].f32)"),
                0x97 => try self.emitF32Binary("maxF32(stack[sp - 2].f32, stack[sp - 1].f32)"),
                0x98 => try self.emitF32Binary("copySignF32(stack[sp - 2].f32, stack[sp - 1].f32)"),
                0x99 => try self.out.write("            stack[sp - 1].f64 = absF64(stack[sp - 1].f64)\n"),
                0x9a => try self.out.write("            stack[sp - 1].f64 = negF64(stack[sp - 1].f64)\n"),
                0x9b => try self.out.write("            stack[sp - 1].f64 = stack[sp - 1].f64.rounded(.up)\n"),
                0x9c => try self.out.write("            stack[sp - 1].f64 = stack[sp - 1].f64.rounded(.down)\n"),
                0x9d => try self.out.write("            stack[sp - 1].f64 = stack[sp - 1].f64.rounded(.towardZero)\n"),
                0x9e => try self.out.write("            stack[sp - 1].f64 = stack[sp - 1].f64.rounded(.toNearestOrEven)\n"),
                0x9f => try self.out.write("            stack[sp - 1].f64 = stack[sp - 1].f64.squareRoot()\n"),
                0xa0 => try self.emitF64Binary("stack[sp - 2].f64 + stack[sp - 1].f64"),
                0xa1 => try self.emitF64Binary("stack[sp - 2].f64 - stack[sp - 1].f64"),
                0xa2 => try self.emitF64Binary("stack[sp - 2].f64 * stack[sp - 1].f64"),
                0xa3 => try self.emitF64Binary("stack[sp - 2].f64 / stack[sp - 1].f64"),
                0xa4 => try self.emitF64Binary("minF64(stack[sp - 2].f64, stack[sp - 1].f64)"),
                0xa5 => try self.emitF64Binary("maxF64(stack[sp - 2].f64, stack[sp - 1].f64)"),
                0xa6 => try self.emitF64Binary("copySignF64(stack[sp - 2].f64, stack[sp - 1].f64)"),
                0xa7 => try self.out.write("            stack[sp - 1].u32 = UInt32(truncatingIfNeeded: stack[sp - 1].u64)\n"),
                0xa8 => try self.out.write("            stack[sp - 1].u32 = try truncI32F32S(&instance, stack[sp - 1].f32)\n"),
                0xa9 => try self.out.write("            stack[sp - 1].u32 = try truncI32F32U(&instance, stack[sp - 1].f32)\n"),
                0xaa => try self.out.write("            stack[sp - 1].u32 = try truncI32F64S(&instance, stack[sp - 1].f64)\n"),
                0xab => try self.out.write("            stack[sp - 1].u32 = try truncI32F64U(&instance, stack[sp - 1].f64)\n"),
                0xac => try self.out.write("            stack[sp - 1].u64 = UInt64(bitPattern: Int64(s32(stack[sp - 1].u32)))\n"),
                0xad => try self.out.write("            stack[sp - 1].u64 = UInt64(stack[sp - 1].u32)\n"),
                0xae => try self.out.write("            stack[sp - 1].u64 = try truncI64F32S(&instance, stack[sp - 1].f32)\n"),
                0xaf => try self.out.write("            stack[sp - 1].u64 = try truncI64F32U(&instance, stack[sp - 1].f32)\n"),
                0xb0 => try self.out.write("            stack[sp - 1].u64 = try truncI64F64S(&instance, stack[sp - 1].f64)\n"),
                0xb1 => try self.out.write("            stack[sp - 1].u64 = try truncI64F64U(&instance, stack[sp - 1].f64)\n"),
                0xb2 => try self.out.write("            stack[sp - 1].f32 = Float(s32(stack[sp - 1].u32))\n"),
                0xb3 => try self.out.write("            stack[sp - 1].f32 = Float(stack[sp - 1].u32)\n"),
                0xb4 => try self.out.write("            stack[sp - 1].f32 = Float(s64(stack[sp - 1].u64))\n"),
                0xb5 => try self.out.write("            stack[sp - 1].f32 = Float(stack[sp - 1].u64)\n"),
                0xb6 => try self.out.write("            stack[sp - 1].f32 = Float(stack[sp - 1].f64)\n"),
                0xb7 => try self.out.write("            stack[sp - 1].f64 = Double(s32(stack[sp - 1].u32))\n"),
                0xb8 => try self.out.write("            stack[sp - 1].f64 = Double(stack[sp - 1].u32)\n"),
                0xb9 => try self.out.write("            stack[sp - 1].f64 = Double(s64(stack[sp - 1].u64))\n"),
                0xba => try self.out.write("            stack[sp - 1].f64 = Double(stack[sp - 1].u64)\n"),
                0xbb => try self.out.write("            stack[sp - 1].f64 = Double(stack[sp - 1].f32)\n"),
                0xbc, 0xbd, 0xbe, 0xbf => {},
                0xc0 => try self.out.write("            stack[sp - 1].u32 = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: stack[sp - 1].u32))))\n"),
                0xc1 => try self.out.write("            stack[sp - 1].u32 = UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: stack[sp - 1].u32))))\n"),
                0xc2 => try self.out.write("            stack[sp - 1].u64 = UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: stack[sp - 1].u64))))\n"),
                0xc3 => try self.out.write("            stack[sp - 1].u64 = UInt64(bitPattern: Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: stack[sp - 1].u64))))\n"),
                0xc4 => try self.out.write("            stack[sp - 1].u64 = UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: stack[sp - 1].u64))))\n"),
                0xfc => try self.emitBulkMemory(r),
                else => return Error.UnsupportedFeature,
            }
        }
        return Error.UnexpectedEof;
    }
};

fn writePreamble(out: *Writer, hash_hex: []const u8, contract: Contract) Error!void {
    try out.print(
        \\// Generated by qip-component-to-swift.
        \\// Source SHA-256: {s}.
        \\const std = @import("std");
        \\
        \\pub const MEMORY_SIZE: usize = {d};
        \\pub const MEMORY_PAGES: u32 = {d};
        \\pub const INPUT_OFFSET: u32 = {d};
        \\pub const INPUT_CAPACITY: u32 = {d};
        \\pub const OUTPUT_CAPACITY: u32 = {d};
        \\pub const CALL_DEPTH_LIMIT: u32 = 1024;
        \\
    , .{
        hash_hex,
        @as(u64, memory_min_pages) * 65536,
        memory_min_pages,
        contract.input_offset,
        contract.input_capacity,
        contract.output_capacity,
    });
    try out.write(
        \\pub const Status = enum(u32) {
        \\    ok = 0,
        \\    input_too_large = 1,
        \\    output_too_large = 2,
        \\    invalid_argument = 3,
        \\    memory_too_small = 4,
        \\    stale_instance = 5,
        \\    trap_unreachable = 16,
        \\    trap_out_of_bounds = 17,
        \\    trap_call_depth = 18,
        \\    trap_div_zero = 19,
        \\    trap_integer_overflow = 20,
        \\    trap_invalid_conversion = 21,
        \\    trap_table_out_of_bounds = 22,
        \\    trap_indirect_null = 23,
        \\    trap_indirect_type = 24,
        \\};
        \\
        \\pub fn requiredDirtyWords(memory_size: usize) usize {
        \\    return (((memory_size + 65535) >> 16) + 63) >> 6;
        \\}
        \\
        \\pub const Workspace = struct {
        \\    memory: []u8,
        \\    generation: u64 = 0,
        \\    dirty_pages: []u64,
        \\
        \\    pub fn init(memory: []u8, dirty_pages: []u64) !Workspace {
        \\        if (memory.len < MEMORY_SIZE) return error.MemoryTooSmall;
        \\        if (dirty_pages.len < requiredDirtyWords(memory.len)) return error.DirtyBitmapTooSmall;
        \\        @memset(memory, 0);
        \\        @memset(dirty_pages, 0);
        \\        return .{ .memory = memory, .dirty_pages = dirty_pages };
        \\    }
        \\};
        \\
        \\const Val = extern union {
        \\    u32_: u32,
        \\    u64_: u64,
        \\    f32_: f32,
        \\    f64_: f64,
        \\};
        \\
    );
    try out.print(
        \\pub const Instance = struct {{
        \\    memory: []u8,
        \\    generation: *u64,
        \\    dirty_pages: []u64,
        \\    workspace_generation: u64,
        \\    globals: [{d}]Val = [_]Val{{.{{ .u64_ = 0 }}}} ** {d},
        \\    call_depth: u32 = 0,
        \\    trap_status: Status = .ok,
        \\}};
        \\
    , .{ @max(global_count, 1), @max(global_count, 1) });
    try out.write("const TABLE = [_]u32{");
    var t: u32 = 0;
    while (t < @max(table_size, 1)) : (t += 1) {
        try out.print("{d},", .{if (t < table_size) table_elements[t] else std.math.maxInt(u32)});
    }
    try out.write("};\n\n");
}

fn writeRuntime(out: *Writer) Error!void {
    try out.write(
        \\const Trap = error{Trap};
        \\
        \\fn always() bool {
        \\    return true;
        \\}
        \\
        \\fn trap(instance: *Instance, status: Status) Trap {
        \\    instance.trap_status = status;
        \\    return error.Trap;
        \\}
        \\
        \\fn markDirty(instance: *Instance, address: usize, width: usize) void {
        \\    if (width == 0) return;
        \\    const first = address >> 16;
        \\    const last = (address + width - 1) >> 16;
        \\    var page = first;
        \\    while (page <= last) : (page += 1) {
        \\        instance.dirty_pages[page >> 6] |= @as(u64, 1) << @intCast(page & 63);
        \\    }
        \\}
        \\
        \\fn clearExcept(workspace: anytype, keep: usize, keep_size: usize) u32 {
        \\    const keep_end = keep + keep_size;
        \\    const pages = (workspace.memory.len + 65535) >> 16;
        \\    var count: u32 = 0;
        \\    var page: usize = 0;
        \\    while (page < pages) : (page += 1) {
        \\        const mask = @as(u64, 1) << @intCast(page & 63);
        \\        if ((workspace.dirty_pages[page >> 6] & mask) == 0) continue;
        \\        const start = page << 16;
        \\        const end = @min(start + 65536, workspace.memory.len);
        \\        if (start < keep and start < keep_end) {
        \\            @memset(workspace.memory[start..@min(keep, end)], 0);
        \\        }
        \\        if (end > keep_end and end > keep) {
        \\            @memset(workspace.memory[@max(keep_end, start)..end], 0);
        \\        }
        \\        workspace.dirty_pages[page >> 6] &= ~mask;
        \\        count += 1;
        \\    }
        \\    if (keep_size != 0) {
        \\        const first = keep >> 16;
        \\        const last = (keep_end - 1) >> 16;
        \\        page = first;
        \\        while (page <= last) : (page += 1) {
        \\            workspace.dirty_pages[page >> 6] |= @as(u64, 1) << @intCast(page & 63);
        \\        }
        \\    }
        \\    workspace.generation +%= 1;
        \\    if (workspace.generation == 0) workspace.generation = 1;
        \\    return count;
        \\}
        \\
        \\pub fn clearWorkspace(workspace: anytype) u32 {
        \\    return clearExcept(workspace, 0, 0);
        \\}
        \\
        \\fn range(instance: *Instance, address: u32, offset: u32, width: usize) Trap![]u8 {
        \\    const start = @as(u64, address) + offset;
        \\    const end = start + width;
        \\    if (end > instance.memory.len) return trap(instance, .trap_out_of_bounds);
        \\    const native_start: usize = @intCast(start);
        \\    return instance.memory[native_start..@intCast(end)];
        \\}
        \\
        \\fn writeRange(instance: *Instance, address: u32, offset: u32, width: usize) Trap![]u8 {
        \\    const bytes = try range(instance, address, offset, width);
        \\    markDirty(instance, @intFromPtr(bytes.ptr) - @intFromPtr(instance.memory.ptr), width);
        \\    return bytes;
        \\}
        \\
        \\fn loadU32(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u32_ = std.mem.readInt(u32, (try range(i, a, o, 4))[0..4], .little) }; }
        \\fn loadU64(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u64_ = std.mem.readInt(u64, (try range(i, a, o, 8))[0..8], .little) }; }
        \\fn loadF32(i: *Instance, a: u32, o: u32) Trap!Val { return loadU32(i, a, o); }
        \\fn loadF64(i: *Instance, a: u32, o: u32) Trap!Val { return loadU64(i, a, o); }
        \\fn loadI8I32(i: *Instance, a: u32, o: u32) Trap!Val { const x: i8 = @bitCast((try range(i, a, o, 1))[0]); return .{ .u32_ = @bitCast(@as(i32, x)) }; }
        \\fn loadU8I32(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u32_ = (try range(i, a, o, 1))[0] }; }
        \\fn loadI16I32(i: *Instance, a: u32, o: u32) Trap!Val { const x: i16 = @bitCast(std.mem.readInt(u16, (try range(i, a, o, 2))[0..2], .little)); return .{ .u32_ = @bitCast(@as(i32, x)) }; }
        \\fn loadU16I32(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u32_ = std.mem.readInt(u16, (try range(i, a, o, 2))[0..2], .little) }; }
        \\fn loadI8I64(i: *Instance, a: u32, o: u32) Trap!Val { const x: i8 = @bitCast((try range(i, a, o, 1))[0]); return .{ .u64_ = @bitCast(@as(i64, x)) }; }
        \\fn loadU8I64(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u64_ = (try range(i, a, o, 1))[0] }; }
        \\fn loadI16I64(i: *Instance, a: u32, o: u32) Trap!Val { const x: i16 = @bitCast(std.mem.readInt(u16, (try range(i, a, o, 2))[0..2], .little)); return .{ .u64_ = @bitCast(@as(i64, x)) }; }
        \\fn loadU16I64(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u64_ = std.mem.readInt(u16, (try range(i, a, o, 2))[0..2], .little) }; }
        \\fn loadI32I64(i: *Instance, a: u32, o: u32) Trap!Val { const x: i32 = @bitCast(std.mem.readInt(u32, (try range(i, a, o, 4))[0..4], .little)); return .{ .u64_ = @bitCast(@as(i64, x)) }; }
        \\fn loadU32I64(i: *Instance, a: u32, o: u32) Trap!Val { return .{ .u64_ = std.mem.readInt(u32, (try range(i, a, o, 4))[0..4], .little) }; }
        \\
        \\fn storeU32(i: *Instance, a: u32, o: u32, v: Val) Trap!void { std.mem.writeInt(u32, (try writeRange(i, a, o, 4))[0..4], v.u32_, .little); }
        \\fn storeU64(i: *Instance, a: u32, o: u32, v: Val) Trap!void { std.mem.writeInt(u64, (try writeRange(i, a, o, 8))[0..8], v.u64_, .little); }
        \\fn storeF32(i: *Instance, a: u32, o: u32, v: Val) Trap!void { try storeU32(i, a, o, v); }
        \\fn storeF64(i: *Instance, a: u32, o: u32, v: Val) Trap!void { try storeU64(i, a, o, v); }
        \\fn store8I32(i: *Instance, a: u32, o: u32, v: Val) Trap!void { (try writeRange(i, a, o, 1))[0] = @truncate(v.u32_); }
        \\fn store16I32(i: *Instance, a: u32, o: u32, v: Val) Trap!void { std.mem.writeInt(u16, (try writeRange(i, a, o, 2))[0..2], @truncate(v.u32_), .little); }
        \\fn store8I64(i: *Instance, a: u32, o: u32, v: Val) Trap!void { (try writeRange(i, a, o, 1))[0] = @truncate(v.u64_); }
        \\fn store16I64(i: *Instance, a: u32, o: u32, v: Val) Trap!void { std.mem.writeInt(u16, (try writeRange(i, a, o, 2))[0..2], @truncate(v.u64_), .little); }
        \\fn store32I64(i: *Instance, a: u32, o: u32, v: Val) Trap!void { std.mem.writeInt(u32, (try writeRange(i, a, o, 4))[0..4], @truncate(v.u64_), .little); }
        \\
        \\fn memoryCopy(i: *Instance, dst: u32, src: u32, n: u32) Trap!void {
        \\    _ = try range(i, dst, 0, n);
        \\    _ = try range(i, src, 0, n);
        \\    markDirty(i, dst, n);
        \\    if (dst <= src) {
        \\        var p: u32 = 0;
        \\        while (p < n) : (p += 1) i.memory[dst + p] = i.memory[src + p];
        \\    } else {
        \\        var p = n;
        \\        while (p != 0) { p -= 1; i.memory[dst + p] = i.memory[src + p]; }
        \\    }
        \\}
        \\
        \\fn memoryFill(i: *Instance, dst: u32, value: u32, n: u32) Trap!void {
        \\    @memset(try writeRange(i, dst, 0, n), @truncate(value));
        \\}
        \\
        \\fn rotl32(x: u32, n: u32) u32 { const s: u5 = @intCast(n & 31); return (x << s) | (x >> (0 -% s)); }
        \\fn rotr32(x: u32, n: u32) u32 { const s: u5 = @intCast(n & 31); return (x >> s) | (x << (0 -% s)); }
        \\fn rotl64(x: u64, n: u64) u64 { const s: u6 = @intCast(n & 63); return (x << s) | (x >> (0 -% s)); }
        \\fn rotr64(x: u64, n: u64) u64 { const s: u6 = @intCast(n & 63); return (x >> s) | (x << (0 -% s)); }
        \\
        \\fn divS32(i: *Instance, lhs: *Val, rhs_bits: u32) Trap!void { const a: i32 = @bitCast(lhs.u32_); const b: i32 = @bitCast(rhs_bits); if (b == 0) return trap(i, .trap_div_zero); if (a == std.math.minInt(i32) and b == -1) return trap(i, .trap_integer_overflow); lhs.u32_ = @bitCast(@divTrunc(a, b)); }
        \\fn remS32(i: *Instance, lhs: *Val, rhs_bits: u32) Trap!void { const a: i32 = @bitCast(lhs.u32_); const b: i32 = @bitCast(rhs_bits); if (b == 0) return trap(i, .trap_div_zero); lhs.u32_ = if (a == std.math.minInt(i32) and b == -1) 0 else @bitCast(@rem(a, b)); }
        \\fn divS64(i: *Instance, lhs: *Val, rhs_bits: u64) Trap!void { const a: i64 = @bitCast(lhs.u64_); const b: i64 = @bitCast(rhs_bits); if (b == 0) return trap(i, .trap_div_zero); if (a == std.math.minInt(i64) and b == -1) return trap(i, .trap_integer_overflow); lhs.u64_ = @bitCast(@divTrunc(a, b)); }
        \\fn remS64(i: *Instance, lhs: *Val, rhs_bits: u64) Trap!void { const a: i64 = @bitCast(lhs.u64_); const b: i64 = @bitCast(rhs_bits); if (b == 0) return trap(i, .trap_div_zero); lhs.u64_ = if (a == std.math.minInt(i64) and b == -1) 0 else @bitCast(@rem(a, b)); }
        \\
        \\fn absF32(x: f32) f32 { return @bitCast(@as(u32, @bitCast(x)) & 0x7fffffff); }
        \\fn absF64(x: f64) f64 { return @bitCast(@as(u64, @bitCast(x)) & 0x7fffffffffffffff); }
        \\fn negF32(x: f32) f32 { return @bitCast(@as(u32, @bitCast(x)) ^ 0x80000000); }
        \\fn negF64(x: f64) f64 { return @bitCast(@as(u64, @bitCast(x)) ^ 0x8000000000000000); }
        \\fn copySignF32(magnitude: f32, sign: f32) f32 { return @bitCast((@as(u32, @bitCast(magnitude)) & 0x7fffffff) | (@as(u32, @bitCast(sign)) & 0x80000000)); }
        \\fn copySignF64(magnitude: f64, sign: f64) f64 { return @bitCast((@as(u64, @bitCast(magnitude)) & 0x7fffffffffffffff) | (@as(u64, @bitCast(sign)) & 0x8000000000000000)); }
        \\fn canonicalNanF32() f32 { return @bitCast(@as(u32, 0x7fc00000)); }
        \\fn canonicalNanF64() f64 { return @bitCast(@as(u64, 0x7ff8000000000000)); }
        \\fn minF32(a: f32, b: f32) f32 { if (std.math.isNan(a) or std.math.isNan(b)) return canonicalNanF32(); if (a == b) return if (a == 0.0) @bitCast(@as(u32, @bitCast(a)) | @as(u32, @bitCast(b))) else a; return if (a < b) a else b; }
        \\fn minF64(a: f64, b: f64) f64 { if (std.math.isNan(a) or std.math.isNan(b)) return canonicalNanF64(); if (a == b) return if (a == 0.0) @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b))) else a; return if (a < b) a else b; }
        \\fn maxF32(a: f32, b: f32) f32 { if (std.math.isNan(a) or std.math.isNan(b)) return canonicalNanF32(); if (a == b) return if (a == 0.0) @bitCast(@as(u32, @bitCast(a)) & @as(u32, @bitCast(b))) else a; return if (a > b) a else b; }
        \\fn maxF64(a: f64, b: f64) f64 { if (std.math.isNan(a) or std.math.isNan(b)) return canonicalNanF64(); if (a == b) return if (a == 0.0) @bitCast(@as(u64, @bitCast(a)) & @as(u64, @bitCast(b))) else a; return if (a > b) a else b; }
        \\fn nearestF32(x: f32) f32 { if (!std.math.isFinite(x) or x == 0.0) return x; const lower = @floor(x); const fraction = x - lower; var result = lower; if (fraction > 0.5 or (fraction == 0.5 and (@as(i64, @intFromFloat(lower)) & 1) != 0)) result = lower + 1.0; return if (result == 0.0) copySignF32(result, x) else result; }
        \\fn nearestF64(x: f64) f64 { if (!std.math.isFinite(x) or x == 0.0) return x; const lower = @floor(x); const fraction = x - lower; var result = lower; if (fraction > 0.5 or (fraction == 0.5 and (@as(i64, @intFromFloat(lower)) & 1) != 0)) result = lower + 1.0; return if (result == 0.0) copySignF64(result, x) else result; }
        \\
        \\fn truncI32F32S(i: *Instance, x: f32) Trap!u32 { if (std.math.isNan(x) or x < -2147483648.0 or x >= 2147483648.0) return trap(i, .trap_invalid_conversion); const value: i32 = @intFromFloat(x); return @bitCast(value); }
        \\fn truncI32F32U(i: *Instance, x: f32) Trap!u32 { if (std.math.isNan(x) or x <= -1.0 or x >= 4294967296.0) return trap(i, .trap_invalid_conversion); return @intFromFloat(x); }
        \\fn truncI32F64S(i: *Instance, x: f64) Trap!u32 { if (std.math.isNan(x) or x <= -2147483649.0 or x >= 2147483648.0) return trap(i, .trap_invalid_conversion); const value: i32 = @intFromFloat(x); return @bitCast(value); }
        \\fn truncI32F64U(i: *Instance, x: f64) Trap!u32 { if (std.math.isNan(x) or x <= -1.0 or x >= 4294967296.0) return trap(i, .trap_invalid_conversion); return @intFromFloat(x); }
        \\fn truncI64F32S(i: *Instance, x: f32) Trap!u64 { if (std.math.isNan(x) or x < -9223372036854775808.0 or x >= 9223372036854775808.0) return trap(i, .trap_invalid_conversion); const value: i64 = @intFromFloat(x); return @bitCast(value); }
        \\fn truncI64F32U(i: *Instance, x: f32) Trap!u64 { if (std.math.isNan(x) or x <= -1.0 or x >= 18446744073709551616.0) return trap(i, .trap_invalid_conversion); return @intFromFloat(x); }
        \\fn truncI64F64S(i: *Instance, x: f64) Trap!u64 { if (std.math.isNan(x) or x < -9223372036854775808.0 or x >= 9223372036854775808.0) return trap(i, .trap_invalid_conversion); const value: i64 = @intFromFloat(x); return @bitCast(value); }
        \\fn truncI64F64U(i: *Instance, x: f64) Trap!u64 { if (std.math.isNan(x) or x <= -1.0 or x >= 18446744073709551616.0) return trap(i, .trap_invalid_conversion); return @intFromFloat(x); }
        \\
    );
}

fn writeSwiftPreamble(out: *Writer, hash_hex: []const u8, contract: Contract) Error!void {
    try out.print(
        \\// Generated by qip-component-to-swift.
        \\// Source SHA-256: {s}.
        \\public let memorySize = {d}
        \\public let memoryPages: UInt32 = {d}
        \\public let inputOffset: UInt32 = {d}
        \\public let inputCapacity: UInt32 = {d}
        \\public let outputCapacity: UInt32 = {d}
        \\public let callDepthLimit: UInt32 = 1024
        \\
    , .{
        hash_hex,
        @as(u64, memory_min_pages) * 65536,
        memory_min_pages,
        contract.input_offset,
        contract.input_capacity,
        contract.output_capacity,
    });
    try out.write(
        \\public enum Status: UInt32 {
        \\    case ok = 0, inputTooLarge = 1, outputTooLarge = 2
        \\    case invalidArgument = 3, memoryTooSmall = 4, staleInstance = 5
        \\    case rejected = 6
        \\    case trapUnreachable = 16, trapOutOfBounds = 17, trapCallDepth = 18
        \\    case trapDivZero = 19, trapIntegerOverflow = 20, trapInvalidConversion = 21
        \\    case trapTableOutOfBounds = 22, trapIndirectNull = 23, trapIndirectType = 24
        \\}
        \\
        \\public func requiredDirtyWords(_ size: Int) -> Int {
        \\    (((size + 65535) >> 16) + 63) >> 6
        \\}
        \\
        \\private struct Val {
        \\    var bits: UInt64 = 0
        \\    var u32: UInt32 { get { UInt32(truncatingIfNeeded: bits) } set { bits = UInt64(newValue) } }
        \\    var u64: UInt64 { get { bits } set { bits = newValue } }
        \\    var f32: Float { get { Float(bitPattern: u32) } set { u32 = newValue.bitPattern } }
        \\    var f64: Double { get { Double(bitPattern: bits) } set { bits = newValue.bitPattern } }
        \\}
        \\
        \\public struct Instance {
        \\    fileprivate var memory = UnsafeMutableRawBufferPointer(start: nil, count: 0)
        \\    fileprivate var generation: UnsafeMutablePointer<UInt64>?
        \\    fileprivate var dirtyPages = UnsafeMutableBufferPointer<UInt64>(start: nil, count: 0)
        \\    fileprivate var workspaceGeneration: UInt64 = 0
    );
    try out.print("\n    fileprivate var globals = [Val](repeating: Val(), count: {d})\n", .{@max(global_count, 1)});
    try out.write(
        \\    fileprivate var callDepth: UInt32 = 0
        \\    fileprivate var trapStatus: Status = .ok
        \\    public init() {}
        \\}
        \\
    );
    try out.write("private let table: [UInt32] = [");
    var t: u32 = 0;
    while (t < @max(table_size, 1)) : (t += 1) {
        try out.print("{d},", .{if (t < table_size) table_elements[t] else std.math.maxInt(u32)});
    }
    try out.write("]\n\n");
}

fn writeSwiftRuntime(out: *Writer) Error!void {
    try out.write(
        \\private struct Trap: Error {}
        \\private func always() -> Bool { true }
        \\private func bool32(_ value: Bool) -> UInt32 { value ? 1 : 0 }
        \\private func s32(_ value: UInt32) -> Int32 { Int32(bitPattern: value) }
        \\private func s64(_ value: UInt64) -> Int64 { Int64(bitPattern: value) }
        \\private func trap(_ instance: inout Instance, _ status: Status) -> Trap {
        \\    instance.trapStatus = status
        \\    return Trap()
        \\}
        \\
        \\private func markDirty(_ instance: inout Instance, _ address: Int, _ width: Int) {
        \\    if width == 0 { return }
        \\    var page: Int = address >> 16
        \\    let last: Int = (address + width - 1) >> 16
        \\    while page <= last {
        \\        instance.dirtyPages[page >> 6] |= UInt64(1) << UInt64(page & 63)
        \\        page += 1
        \\    }
        \\}
        \\
        \\private func checkedStart(_ instance: inout Instance, _ address: UInt32, _ offset: UInt32, _ width: Int) throws -> Int {
        \\    let start: UInt64 = UInt64(address) + UInt64(offset)
        \\    let end: UInt64 = start + UInt64(width)
        \\    if end > UInt64(instance.memory.count) { throw trap(&instance, .trapOutOfBounds) }
        \\    return Int(start)
        \\}
        \\private func readBits(_ instance: inout Instance, _ address: UInt32, _ offset: UInt32, _ width: Int) throws -> UInt64 {
        \\    let start: Int = try checkedStart(&instance, address, offset, width)
        \\    var value: UInt64 = 0
        \\    for n in 0..<width { value |= UInt64(instance.memory[start + n]) << UInt64(n * 8) }
        \\    return value
        \\}
        \\private func writeBits(_ instance: inout Instance, _ address: UInt32, _ offset: UInt32, _ width: Int, _ value: UInt64) throws {
        \\    let start: Int = try checkedStart(&instance, address, offset, width)
        \\    markDirty(&instance, start, width)
        \\    for n in 0..<width { instance.memory[start + n] = UInt8(truncatingIfNeeded: value >> UInt64(n * 8)) }
        \\}
        \\
        \\private func loadU32(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 4)) }
        \\private func loadU64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 8)) }
        \\private func loadF32(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { try loadU32(&i, a, o) }
        \\private func loadF64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { try loadU64(&i, a, o) }
        \\private func loadI8I32(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: UInt64(UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(try readBits(&i, a, o, 1))))))) }
        \\private func loadU8I32(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 1)) }
        \\private func loadI16I32(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: UInt64(UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(try readBits(&i, a, o, 2))))))) }
        \\private func loadU16I32(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 2)) }
        \\private func loadI8I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(try readBits(&i, a, o, 1)))))) }
        \\private func loadU8I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 1)) }
        \\private func loadI16I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: UInt64(bitPattern: Int64(Int16(bitPattern: UInt16(try readBits(&i, a, o, 2)))))) }
        \\private func loadU16I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 2)) }
        \\private func loadI32I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(try readBits(&i, a, o, 4)))))) }
        \\private func loadU32I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32) throws -> Val { Val(bits: try readBits(&i, a, o, 4)) }
        \\
        \\private func storeU32(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 4, UInt64(v.u32)) }
        \\private func storeU64(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 8, v.u64) }
        \\private func storeF32(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try storeU32(&i, a, o, v) }
        \\private func storeF64(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try storeU64(&i, a, o, v) }
        \\private func store8I32(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 1, UInt64(v.u32)) }
        \\private func store16I32(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 2, UInt64(v.u32)) }
        \\private func store8I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 1, v.u64) }
        \\private func store16I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 2, v.u64) }
        \\private func store32I64(_ i: inout Instance, _ a: UInt32, _ o: UInt32, _ v: Val) throws { try writeBits(&i, a, o, 4, v.u64) }
        \\
        \\private func memoryCopy(_ i: inout Instance, _ dst: UInt32, _ src: UInt32, _ n: UInt32) throws {
        \\    let d: Int = try checkedStart(&i, dst, 0, Int(n)); let s: Int = try checkedStart(&i, src, 0, Int(n))
        \\    markDirty(&i, d, Int(n)); if d <= s { for p in 0..<Int(n) { i.memory[d+p] = i.memory[s+p] } }
        \\    else { for p in (0..<Int(n)).reversed() { i.memory[d+p] = i.memory[s+p] } }
        \\}
        \\private func memoryFill(_ i: inout Instance, _ dst: UInt32, _ value: UInt32, _ n: UInt32) throws {
        \\    let d: Int = try checkedStart(&i, dst, 0, Int(n)); markDirty(&i, d, Int(n))
        \\    for p in 0..<Int(n) { i.memory[d+p] = UInt8(truncatingIfNeeded: value) }
        \\}
        \\
        \\private func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 { let s: UInt32 = n & 31; return (x << s) | (x >> ((0 &- s) & 31)) }
        \\private func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 { let s: UInt32 = n & 31; return (x >> s) | (x << ((0 &- s) & 31)) }
        \\private func rotl64(_ x: UInt64, _ n: UInt64) -> UInt64 { let s: UInt64 = n & 63; return (x << s) | (x >> ((0 &- s) & 63)) }
        \\private func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 { let s: UInt64 = n & 63; return (x >> s) | (x << ((0 &- s) & 63)) }
        \\private func divS32(_ i: inout Instance, _ lhs: inout Val, _ rhs: UInt32) throws { let a: Int32=s32(lhs.u32), b: Int32=s32(rhs); if b==0 { throw trap(&i,.trapDivZero) }; if a==Int32.min && b == -1 { throw trap(&i,.trapIntegerOverflow) }; lhs.u32=UInt32(bitPattern:a/b) }
        \\private func remS32(_ i: inout Instance, _ lhs: inout Val, _ rhs: UInt32) throws { let a: Int32=s32(lhs.u32), b: Int32=s32(rhs); if b==0 { throw trap(&i,.trapDivZero) }; lhs.u32 = a==Int32.min && b == -1 ? 0 : UInt32(bitPattern:a%b) }
        \\private func divS64(_ i: inout Instance, _ lhs: inout Val, _ rhs: UInt64) throws { let a: Int64=s64(lhs.u64), b: Int64=s64(rhs); if b==0 { throw trap(&i,.trapDivZero) }; if a==Int64.min && b == -1 { throw trap(&i,.trapIntegerOverflow) }; lhs.u64=UInt64(bitPattern:a/b) }
        \\private func remS64(_ i: inout Instance, _ lhs: inout Val, _ rhs: UInt64) throws { let a: Int64=s64(lhs.u64), b: Int64=s64(rhs); if b==0 { throw trap(&i,.trapDivZero) }; lhs.u64 = a==Int64.min && b == -1 ? 0 : UInt64(bitPattern:a%b) }
        \\
        \\private func absF32(_ x: Float) -> Float { Float(bitPattern:x.bitPattern & 0x7fffffff) }
        \\private func negF32(_ x: Float) -> Float { Float(bitPattern:x.bitPattern ^ 0x80000000) }
        \\private func absF64(_ x: Double) -> Double { Double(bitPattern:x.bitPattern & 0x7fffffffffffffff) }
        \\private func negF64(_ x: Double) -> Double { Double(bitPattern:x.bitPattern ^ 0x8000000000000000) }
        \\private func copySignF32(_ a: Float,_ b: Float)->Float { Float(bitPattern:(a.bitPattern&0x7fffffff)|(b.bitPattern&0x80000000)) }
        \\private func copySignF64(_ a: Double,_ b: Double)->Double { Double(bitPattern:(a.bitPattern&0x7fffffffffffffff)|(b.bitPattern&0x8000000000000000)) }
        \\private func minF32(_ a:Float,_ b:Float)->Float { if a.isNaN||b.isNaN{return Float(bitPattern:0x7fc00000)}; if a==b{return a==0 ? Float(bitPattern:a.bitPattern|b.bitPattern):a}; return a<b ? a:b }
        \\private func maxF32(_ a:Float,_ b:Float)->Float { if a.isNaN||b.isNaN{return Float(bitPattern:0x7fc00000)}; if a==b{return a==0 ? Float(bitPattern:a.bitPattern&b.bitPattern):a}; return a>b ? a:b }
        \\private func minF64(_ a:Double,_ b:Double)->Double { if a.isNaN||b.isNaN{return Double(bitPattern:0x7ff8000000000000)}; if a==b{return a==0 ? Double(bitPattern:a.bitPattern|b.bitPattern):a}; return a<b ? a:b }
        \\private func maxF64(_ a:Double,_ b:Double)->Double { if a.isNaN||b.isNaN{return Double(bitPattern:0x7ff8000000000000)}; if a==b{return a==0 ? Double(bitPattern:a.bitPattern&b.bitPattern):a}; return a>b ? a:b }
        \\
        \\private func invalidConversion(_ i: inout Instance) -> Trap { trap(&i,.trapInvalidConversion) }
        \\private func truncI32F32S(_ i: inout Instance,_ x:Float)throws->UInt32 { if x.isNaN||x < -2147483648||x >= 2147483648{throw invalidConversion(&i)}; return UInt32(bitPattern:Int32(x)) }
        \\private func truncI32F32U(_ i: inout Instance,_ x:Float)throws->UInt32 { if x.isNaN||x <= -1||x >= 4294967296{throw invalidConversion(&i)}; return UInt32(x) }
        \\private func truncI32F64S(_ i: inout Instance,_ x:Double)throws->UInt32 { if x.isNaN||x <= -2147483649||x >= 2147483648{throw invalidConversion(&i)}; return UInt32(bitPattern:Int32(x)) }
        \\private func truncI32F64U(_ i: inout Instance,_ x:Double)throws->UInt32 { if x.isNaN||x <= -1||x >= 4294967296{throw invalidConversion(&i)}; return UInt32(x) }
        \\private func truncI64F32S(_ i: inout Instance,_ x:Float)throws->UInt64 { if x.isNaN||x < -9223372036854775808||x >= 9223372036854775808{throw invalidConversion(&i)}; return UInt64(bitPattern:Int64(x)) }
        \\private func truncI64F32U(_ i: inout Instance,_ x:Float)throws->UInt64 { if x.isNaN||x <= -1||x >= 18446744073709551616{throw invalidConversion(&i)}; return UInt64(x) }
        \\private func truncI64F64S(_ i: inout Instance,_ x:Double)throws->UInt64 { if x.isNaN||x < -9223372036854775808||x >= 9223372036854775808{throw invalidConversion(&i)}; return UInt64(bitPattern:Int64(x)) }
        \\private func truncI64F64U(_ i: inout Instance,_ x:Double)throws->UInt64 { if x.isNaN||x <= -1||x >= 18446744073709551616{throw invalidConversion(&i)}; return UInt64(x) }
        \\
    );
}

fn writeData(out: *Writer) Error!void {
    var d: usize = 0;
    while (d < data_count) : (d += 1) {
        const segment = data_segments[d];
        if (segment.passive) return Error.UnsupportedFeature;
        try out.print("const data_{d} = [_]u8{{", .{d});
        if (segment.bytes.len == 0) try out.write("0");
        for (segment.bytes, 0..) |byte, index| {
            if (index % 20 == 0) try out.write("\n    ");
            try out.print("{d},", .{byte});
        }
        try out.write("\n};\n\n");
    }
}

fn writeFunction(out: *Writer, index: u32) Error!void {
    const function = functions[index];
    const ft = types[function.type_index];
    var r = Reader.init(function.body);
    const groups = try r.varU32();
    var local_count: u32 = ft.params_len;
    var group: u32 = 0;
    while (group < groups) : (group += 1) {
        const count = try r.varU32();
        _ = try valType(try r.byte());
        if (count > 65536 - local_count) return Error.TooManyItems;
        local_count += count;
    }

    try out.print(
        \\fn f{d}(instance: *Instance, args: []const Val) Trap!Val {{
        \\    var stack: [{d}]Val = undefined;
        \\    var locals = [_]Val{{.{{ .u64_ = 0 }}}} ** {d};
        \\    var sp: usize = 0;
        \\    _ = &stack;
        \\    _ = &locals;
        \\    _ = &sp;
        \\    instance.call_depth += 1;
        \\    if (instance.call_depth > CALL_DEPTH_LIMIT) return trap(instance, .trap_call_depth);
        \\    defer instance.call_depth -= 1;
        \\    function_exit: {{ if (!always()) break :function_exit;
        \\
    , .{ index, function.body.len + 1, @max(local_count, 1) });
    if (ft.params_len == 0) try out.write("    _ = args;\n");
    var param: u32 = 0;
    while (param < ft.params_len) : (param += 1) {
        try out.print("    locals[{d}] = args[{d}];\n", .{ param, param });
    }
    const function_control = Control{
        .kind = .function,
        .id = std.math.maxInt(u32),
        .branch_arity = if (ft.result == null) 0 else 1,
        .end_arity = if (ft.result == null) 0 else 1,
    };
    var emitter = FunctionEmitter{ .out = out };
    try emitter.pushControl(function_control);
    if (try emitter.sequence(&r, false)) return Error.InvalidSection;
    if (r.remaining() != 0) return Error.InvalidSection;
    try out.write("    }\n");
    if (ft.result == null) {
        try out.write("    return .{ .u64_ = 0 };\n}\n\n");
    } else {
        try out.write("    return stack[sp - 1];\n}\n\n");
    }
}

fn writeInit(out: *Writer) Error!void {
    try out.write(
        \\pub fn init(instance: *Instance, workspace: anytype, input_size: u32) Status {
        \\    if (workspace.memory.len < MEMORY_SIZE or
        \\        workspace.dirty_pages.len < requiredDirtyWords(workspace.memory.len)) return .memory_too_small;
        \\    if (input_size > INPUT_CAPACITY) return .input_too_large;
        \\    _ = clearExcept(workspace, INPUT_OFFSET, input_size);
        \\    instance.* = .{
        \\        .memory = workspace.memory[0..MEMORY_SIZE],
        \\        .generation = &workspace.generation,
        \\        .dirty_pages = workspace.dirty_pages,
        \\        .workspace_generation = workspace.generation,
        \\    };
        \\
    );
    var g: usize = 0;
    while (g < global_count) : (g += 1) {
        const global = globals[g];
        switch (global.value_type) {
            .i32, .f32 => try out.print("    instance.globals[{d}].u32_ = {d};\n", .{ g, global.initial.u32_ }),
            .i64, .f64 => try out.print("    instance.globals[{d}].u64_ = {d};\n", .{ g, global.initial.u64_ }),
        }
    }
    var d: usize = 0;
    while (d < data_count) : (d += 1) {
        const segment = data_segments[d];
        if (segment.passive) return Error.UnsupportedFeature;
        const end = @as(u64, segment.offset) + segment.bytes.len;
        if (end > @as(u64, memory_min_pages) * 65536) return Error.InvalidSection;
        if (segment.bytes.len != 0) {
            try out.print("    @memcpy(instance.memory[{d}..{d}], &data_{d}); markDirty(instance, {d}, {d});\n", .{
                segment.offset, end, d, segment.offset, segment.bytes.len,
            });
        }
    }
    try out.write("    return .ok;\n}\n\n");
}

fn writeWrapper(out: *Writer, contract: Contract) Error!void {
    try out.print(
        \\pub fn dirtyPageCount(instance: *const Instance) u32 {{
        \\    if (instance.workspace_generation != instance.generation.*) return 0;
        \\    var count: u32 = 0;
        \\    for (instance.dirty_pages) |word| count += @popCount(word);
        \\    return count;
        \\}}
        \\
        \\pub fn render(instance: *Instance, input_size: u32, output_offset: *u32, output_size: *u32) Status {{
        \\    if (instance.workspace_generation != instance.generation.*) return .stale_instance;
        \\    if (input_size > INPUT_CAPACITY) return .input_too_large;
        \\    instance.call_depth = 0;
        \\    instance.trap_status = .ok;
        \\    markDirty(instance, INPUT_OFFSET, input_size);
        \\    const args = [_]Val{{.{{ .u32_ = input_size }}}};
        \\    const result = f{d}(instance, &args) catch {{ instance.call_depth = 0; return instance.trap_status; }};
        \\    const bits = result.u64_;
        \\    output_size.* = @truncate(bits);
        \\    if (bits >> 63 != 0) {{ output_offset.* = 0; return .rejected; }}
        \\    output_offset.* = @truncate((bits >> 32) & 0x7fff_ffff);
        \\    if (output_size.* > OUTPUT_CAPACITY or @as(u64, output_offset.*) + output_size.* > MEMORY_SIZE) return .output_too_large;
        \\    return .ok;
        \\}}
        \\
    , .{contract.render});
}

fn writeSwiftData(out: *Writer) Error!void {
    var d: usize = 0;
    while (d < data_count) : (d += 1) {
        const segment = data_segments[d];
        if (segment.passive) return Error.UnsupportedFeature;
        try out.print("private let data{d}: [UInt8] = [", .{d});
        for (segment.bytes) |byte| try out.print("{d},", .{byte});
        try out.write("]\n");
    }
    try out.write("\n");
}

fn writeSwiftFunction(out: *Writer, index: u32) Error!void {
    const function = functions[index];
    const ft = types[function.type_index];
    var r = Reader.init(function.body);
    const groups = try r.varU32();
    var local_count: u32 = ft.params_len;
    var group: u32 = 0;
    while (group < groups) : (group += 1) {
        const count = try r.varU32();
        _ = try valType(try r.byte());
        if (count > 65536 - local_count) return Error.TooManyItems;
        local_count += count;
    }
    try out.print(
        \\private func qipWasmFunction{d}(_ instance: inout Instance, _ args: [Val]) throws -> Val {{
        \\    var stack: [Val] = [Val](repeating: Val(), count: {d})
        \\    var locals: [Val] = [Val](repeating: Val(), count: {d})
        \\    var sp: Int = 0
        \\    sp += 0
        \\    instance.callDepth += 1
        \\    if instance.callDepth > callDepthLimit {{ throw trap(&instance, .trapCallDepth) }}
        \\    defer {{ instance.callDepth -= 1 }}
        \\    functionExit: do {{ if !always() {{ break functionExit }}
        \\
    , .{ index, function.body.len + 1, @max(local_count, 1) });
    var param: u32 = 0;
    while (param < ft.params_len) : (param += 1)
        try out.print("            locals[{d}] = args[{d}]\n", .{ param, param });
    const function_control = Control{
        .kind = .function,
        .id = std.math.maxInt(u32),
        .branch_arity = if (ft.result == null) 0 else 1,
        .end_arity = if (ft.result == null) 0 else 1,
    };
    var emitter = FunctionEmitter{ .out = out };
    try emitter.pushControl(function_control);
    if (try emitter.sequence(&r, false)) return Error.InvalidSection;
    if (r.remaining() != 0) return Error.InvalidSection;
    try out.write("    }\n");
    if (ft.result == null) try out.write("    return Val()\n}\n\n") else try out.write("    return stack[sp - 1]\n}\n\n");
}

fn writeSwiftInit(out: *Writer) Error!void {
    try out.write(
        \\private func clearExcept(_ memory: UnsafeMutableRawBufferPointer, _ dirty: UnsafeMutableBufferPointer<UInt64>, _ generation: UnsafeMutablePointer<UInt64>, _ keep: Int, _ keepSize: Int) -> UInt32 {
        \\    var count: UInt32 = 0
        \\    let keepEnd: Int = keep + keepSize
        \\    if generation.pointee == 0 {
        \\        if keep > 0 { for p in 0..<keep { memory[p] = 0 } }
        \\        if keepEnd < memory.count { for p in keepEnd..<memory.count { memory[p] = 0 } }
        \\        for n in dirty.indices { dirty[n] = 0 }
        \\        if keepSize != 0 { for page in (keep >> 16)...((keepEnd - 1) >> 16) { dirty[page >> 6] |= UInt64(1) << UInt64(page & 63) } }
        \\        generation.pointee = 1
        \\        return UInt32((memory.count + 65535) >> 16)
        \\    }
        \\    let pageCount: Int = (memory.count + 65535) >> 16
        \\    var page: Int = 0
        \\    while page < pageCount {
        \\        let mask: UInt64 = UInt64(1) << UInt64(page & 63)
        \\        if dirty[page >> 6] & mask != 0 {
        \\            let start: Int = page << 16
        \\            let end: Int = Swift.min(start + 65536, memory.count)
        \\            if start < keep { for p in start..<Swift.min(keep,end) { memory[p] = 0 } }
        \\            if end > keepEnd { for p in Swift.max(keepEnd,start)..<end { memory[p] = 0 } }
        \\            dirty[page >> 6] &= ~mask; count += 1
        \\        }
        \\        page += 1
        \\    }
        \\    if keepSize != 0 { for page in (keep >> 16)...((keepEnd - 1) >> 16) { dirty[page >> 6] |= UInt64(1) << UInt64(page & 63) } }
        \\    generation.pointee &+= 1; if generation.pointee == 0 { generation.pointee = 1 }
        \\    return count
        \\}
        \\public func clearWorkspace(memory: UnsafeMutableRawBufferPointer, dirtyPages: UnsafeMutableBufferPointer<UInt64>, generation: UnsafeMutablePointer<UInt64>) -> UInt32 {
        \\    clearExcept(memory, dirtyPages, generation, 0, 0)
        \\}
        \\public func initialize(_ instance: inout Instance, memory: UnsafeMutableRawBufferPointer, dirtyPages: UnsafeMutableBufferPointer<UInt64>, generation: UnsafeMutablePointer<UInt64>, inputSize: UInt32) -> Status {
        \\    if memory.count < memorySize || dirtyPages.count < requiredDirtyWords(memory.count) { return .memoryTooSmall }
        \\    if inputSize > inputCapacity { return .inputTooLarge }
        \\    _ = clearExcept(memory, dirtyPages, generation, Int(inputOffset), Int(inputSize))
        \\    instance = Instance(); instance.memory = UnsafeMutableRawBufferPointer(rebasing: memory[0..<memorySize])
        \\    instance.dirtyPages = dirtyPages; instance.generation = generation; instance.workspaceGeneration = generation.pointee
        \\
    );
    var g: usize = 0;
    while (g < global_count) : (g += 1) switch (globals[g].value_type) {
        .i32, .f32 => try out.print("    instance.globals[{d}].u32 = {d}\n", .{ g, globals[g].initial.u32_ }),
        .i64, .f64 => try out.print("    instance.globals[{d}].u64 = {d}\n", .{ g, globals[g].initial.u64_ }),
    };
    var d: usize = 0;
    while (d < data_count) : (d += 1) {
        const segment = data_segments[d];
        if (segment.bytes.len != 0) try out.print("    var dataIndex{d}: Int = 0; while dataIndex{d} < data{d}.count {{ instance.memory[{d} + dataIndex{d}] = data{d}[dataIndex{d}]; dataIndex{d} += 1 }}; markDirty(&instance, {d}, {d})\n", .{ d, d, d, segment.offset, d, d, d, d, segment.offset, segment.bytes.len });
    }
    try out.write("    return .ok\n}\n\n");
}

fn writeSwiftWrapper(out: *Writer, contract: Contract) Error!void {
    try out.print(
        \\public func dirtyPageCount(_ instance: Instance) -> UInt32 {{
        \\    guard let generation = instance.generation, generation.pointee == instance.workspaceGeneration else {{ return 0 }}
        \\    var count: UInt32 = 0
        \\    var index: Int = 0
        \\    while index < instance.dirtyPages.count {{ count += UInt32(instance.dirtyPages[index].nonzeroBitCount); index += 1 }}
        \\    return count
        \\}}
        \\public func render(_ instance: inout Instance, inputSize: UInt32, outputOffset: inout UInt32, outputSize: inout UInt32) -> Status {{
        \\    guard let generation = instance.generation, generation.pointee == instance.workspaceGeneration else {{ return .staleInstance }}
        \\    if inputSize > inputCapacity {{ return .inputTooLarge }}
        \\    instance.callDepth = 0; instance.trapStatus = .ok; markDirty(&instance, Int(inputOffset), Int(inputSize))
        \\    do {{
        \\        var argument: Val = Val(); argument.u32 = inputSize
        \\        let arguments: [Val] = [argument]
        \\        let result: Val = try qipWasmFunction{d}(&instance, arguments)
        \\        outputSize = result.u32
        \\        if result.u64 >> 63 != 0 {{ outputOffset = 0; return .rejected }}
        \\        outputOffset = UInt32(truncatingIfNeeded: (result.u64 >> 32) & 0x7fff_ffff)
        \\        if outputSize > outputCapacity || UInt64(outputOffset) + UInt64(outputSize) > UInt64(memorySize) {{ return .outputTooLarge }}
        \\        return .ok
        \\    }} catch {{ instance.callDepth = 0; return instance.trapStatus }}
        \\}}
        \\
    , .{contract.render});
}

fn generate(wasm: []const u8) Error!usize {
    try parseModule(wasm);
    const contract = try readContract();
    const hash = moduleHash(wasm);
    var hash_hex_buf: [64]u8 = undefined;
    const hash_hex = std.fmt.bufPrint(&hash_hex_buf, "{x}", .{hash}) catch return Error.TooManyItems;
    var out = Writer{};
    try writeSwiftPreamble(&out, hash_hex, contract);
    try writeSwiftRuntime(&out);
    try writeSwiftData(&out);
    var i: u32 = 0;
    while (i < function_count) : (i += 1) try writeSwiftFunction(&out, i);
    try writeSwiftInit(&out);
    try writeSwiftWrapper(&out, contract);
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
