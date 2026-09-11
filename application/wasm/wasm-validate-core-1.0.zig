//! WebAssembly Core 1.0 validation as an assertion/pass-through QIP component.
//!
//! This implements the Core 1.0 binary-format and validation rules, including
//! the specification's single-pass operand/control-stack algorithm for function
//! bodies. It accepts exactly the Core 1.0 language: later instructions and
//! section forms are rejected even when the host browser implements them.
//! Specification: https://webassembly.github.io/spec/versions/core/WebAssembly-1.0.pdf
//! Acceptance suite: official `wg-1.0` specification tests at commit
//! 977f97014c962f7bd1291fcc6d28b41a924882bf. Run with
//! `WASM_CORE_1_0_SPEC_DIR=/path/to/spec make test-wasm-core-1-spec`.
//! The tag archive used for the recorded run has SHA-256
//! bf5a27e64e25d1cdec045d1bb12e39873f717cd44b0c749b9483ecb31ccceb8f.
//! TODO(wasmparser-differential): compare this independent implementation
//! against `wasmparser` configured with `WasmFeatures::WASM1`, including
//! generated and mutated modules beyond the official acceptance suite.
//!
//! Input and output are application/wasm. Valid input is accepted unchanged;
//! `render` rejects malformed or ill-typed input.

const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_TYPES: usize = 8192;
const MAX_TYPE_VALUES: usize = 65536;
const MAX_FUNCTIONS: usize = 16384;
const MAX_GLOBALS: usize = 8192;
const MAX_EXPORTS: usize = 8192;
const MAX_LOCALS: usize = 65536;
const MAX_VALUES: usize = 65536;
const MAX_CONTROLS: usize = 8192;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

// TODO(content-failure-offset): report the parser's invalid input byte offset instead
// of zero.

const Error = error{
    InvalidWasm,
    UnexpectedEOF,
    InvalidLeb,
    InvalidUtf8,
    InvalidSection,
    InvalidType,
    InvalidIndex,
    InvalidLimits,
    InvalidConstantExpression,
    DuplicateExport,
    FunctionCodeMismatch,
    StackUnderflow,
    TypeMismatch,
    InvalidControl,
    TooManyItems,
};

const ValType = enum(u8) { i32 = 0x7f, i64 = 0x7e, f32 = 0x7d, f64 = 0x7c, unknown = 0x00 };

const FuncType = struct {
    params_off: u32,
    params_len: u32,
    result: ?ValType,
};

const GlobalType = struct { val: ValType, mutable: bool, imported: bool };
const ExportName = struct { off: u32, len: u32 };

var types: [MAX_TYPES]FuncType = undefined;
var type_count: usize = 0;
var type_values: [MAX_TYPE_VALUES]ValType = undefined;
var type_value_count: usize = 0;
var function_types: [MAX_FUNCTIONS]u32 = undefined;
var function_count: usize = 0;
var imported_function_count: usize = 0;
var defined_function_count: usize = 0;
var globals: [MAX_GLOBALS]GlobalType = undefined;
var global_count: usize = 0;
var table_count: usize = 0;
var memory_count: usize = 0;
var exports: [MAX_EXPORTS]ExportName = undefined;
var export_count: usize = 0;

const Reader = struct {
    data: []const u8,
    off: usize = 0,
    base: usize = 0,

    fn init(data: []const u8) Reader {
        return .{ .data = data };
    }
    fn slice(data: []const u8, base: usize) Reader {
        return .{ .data = data, .base = base };
    }
    fn remaining(self: *const Reader) usize {
        return self.data.len - self.off;
    }
    fn byte(self: *Reader) Error!u8 {
        if (self.off == self.data.len) return Error.UnexpectedEOF;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }
    fn bytes(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return Error.UnexpectedEOF;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }
    fn @"u32"(self: *Reader) Error!u32 {
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
    fn s32(self: *Reader) Error!i32 {
        return @intCast(try self.signed(32, 5));
    }
    fn s64(self: *Reader) Error!i64 {
        return try self.signed(64, 10);
    }
    fn signed(self: *Reader, comptime bits: u7, comptime max_bytes: usize) Error!i64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        var b: u8 = 0;
        var i: usize = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.byte();
            const payload = b & 0x7f;
            if (i == max_bytes - 1) {
                const used: u3 = @intCast(bits - shift);
                const low_mask: u8 = (@as(u8, 1) << used) - 1;
                const mask: u8 = 0x7f ^ low_mask;
                const extra = payload & mask;
                const sign_bit = @as(u8, 1) << (used - 1);
                const expected_extra: u8 = if ((payload & sign_bit) == 0) 0 else mask;
                if (extra != expected_extra) return Error.InvalidLeb;
            }
            result |= @as(u64, payload) << @intCast(shift);
            shift += 7;
            if ((b & 0x80) == 0) {
                if ((b & 0x40) != 0 and shift < 64) result |= ~@as(u64, 0) << @intCast(shift);
                if (bits == 32) {
                    const narrowed: u32 = @truncate(result);
                    return @as(i32, @bitCast(narrowed));
                }
                return @bitCast(result);
            }
        }
        return Error.InvalidLeb;
    }
    fn name(self: *Reader) Error!ExportName {
        const len = try self.u32();
        const start = self.off;
        const value = try self.bytes(len);
        if (!std.unicode.utf8ValidateSlice(value)) return Error.InvalidUtf8;
        return .{ .off = @intCast(self.base + start), .len = len };
    }
};

fn valTypeByte(b: u8) Error!ValType {
    return switch (b) {
        0x7f => .i32,
        0x7e => .i64,
        0x7d => .f32,
        0x7c => .f64,
        else => Error.InvalidType,
    };
}

fn readLimits(r: *Reader, memory: bool) Error!void {
    const flags = try r.byte();
    if (flags > 1) return Error.InvalidLimits;
    const min = try r.u32();
    const max = if (flags == 1) try r.u32() else null;
    if (max) |m| if (min > m) return Error.InvalidLimits;
    if (memory and (min > 65536 or (max != null and max.? > 65536))) return Error.InvalidLimits;
}

fn readTableType(r: *Reader) Error!void {
    if (try r.byte() != 0x70) return Error.InvalidType;
    try readLimits(r, false);
}

fn readGlobalType(r: *Reader, imported: bool) Error!GlobalType {
    const val = try valTypeByte(try r.byte());
    const mut = try r.byte();
    if (mut > 1) return Error.InvalidType;
    return .{ .val = val, .mutable = mut == 1, .imported = imported };
}

fn resetState() void {
    type_count = 0;
    type_value_count = 0;
    function_count = 0;
    imported_function_count = 0;
    defined_function_count = 0;
    global_count = 0;
    table_count = 0;
    memory_count = 0;
    export_count = 0;
}

fn addFunction(type_idx: u32, imported: bool) Error!void {
    if (type_idx >= type_count) return Error.InvalidIndex;
    if (function_count == MAX_FUNCTIONS) return Error.TooManyItems;
    function_types[function_count] = type_idx;
    function_count += 1;
    if (imported) imported_function_count += 1 else defined_function_count += 1;
}

fn addGlobal(gt: GlobalType) Error!void {
    if (global_count == MAX_GLOBALS) return Error.TooManyItems;
    globals[global_count] = gt;
    global_count += 1;
}

fn parseTypeSection(r: *Reader) Error!void {
    const n = try r.u32();
    if (n > MAX_TYPES) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (try r.byte() != 0x60) return Error.InvalidType;
        const pc = try r.u32();
        if (pc > MAX_TYPE_VALUES - type_value_count) return Error.TooManyItems;
        const off = type_value_count;
        var p: u32 = 0;
        while (p < pc) : (p += 1) {
            type_values[type_value_count] = try valTypeByte(try r.byte());
            type_value_count += 1;
        }
        const rc = try r.u32();
        if (rc > 1) return Error.InvalidType;
        const result = if (rc == 1) try valTypeByte(try r.byte()) else null;
        types[type_count] = .{ .params_off = @intCast(off), .params_len = pc, .result = result };
        type_count += 1;
    }
}

fn parseImportSection(r: *Reader) Error!void {
    const n = try r.u32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.name();
        _ = try r.name();
        switch (try r.byte()) {
            0 => try addFunction(try r.u32(), true),
            1 => {
                try readTableType(r);
                table_count += 1;
                if (table_count > 1) return Error.InvalidType;
            },
            2 => {
                try readLimits(r, true);
                memory_count += 1;
                if (memory_count > 1) return Error.InvalidType;
            },
            3 => try addGlobal(try readGlobalType(r, true)),
            else => return Error.InvalidType,
        }
    }
}

fn parseFunctionSection(r: *Reader) Error!void {
    const n = try r.u32();
    if (n > MAX_FUNCTIONS - function_count) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < n) : (i += 1) try addFunction(try r.u32(), false);
}

fn parseTableSection(r: *Reader) Error!void {
    const n = try r.u32();
    if (n > 1 or table_count + n > 1) return Error.InvalidType;
    var i: u32 = 0;
    while (i < n) : (i += 1) try readTableType(r);
    table_count += n;
}

fn parseMemorySection(r: *Reader) Error!void {
    const n = try r.u32();
    if (n > 1 or memory_count + n > 1) return Error.InvalidType;
    var i: u32 = 0;
    while (i < n) : (i += 1) try readLimits(r, true);
    memory_count += n;
}

fn constExpr(r: *Reader, expected: ValType) Error!void {
    const op = try r.byte();
    const actual: ValType = switch (op) {
        0x41 => blk: {
            _ = try r.s32();
            break :blk .i32;
        },
        0x42 => blk: {
            _ = try r.s64();
            break :blk .i64;
        },
        0x43 => blk: {
            _ = try r.bytes(4);
            break :blk .f32;
        },
        0x44 => blk: {
            _ = try r.bytes(8);
            break :blk .f64;
        },
        0x23 => blk: {
            const idx = try r.u32();
            if (idx >= global_count) return Error.InvalidIndex;
            const g = globals[idx];
            if (!g.imported or g.mutable) return Error.InvalidConstantExpression;
            break :blk g.val;
        },
        else => return Error.InvalidConstantExpression,
    };
    if (actual != expected or try r.byte() != 0x0b) return Error.InvalidConstantExpression;
}

fn parseGlobalSection(r: *Reader) Error!void {
    const n = try r.u32();
    if (n > MAX_GLOBALS - global_count) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const gt = try readGlobalType(r, false);
        try constExpr(r, gt.val);
        try addGlobal(gt);
    }
}

fn equalExportName(a: ExportName, b: ExportName, wasm: []const u8) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, wasm[a.off .. a.off + a.len], wasm[b.off .. b.off + b.len]);
}

fn parseExportSection(r: *Reader, wasm: []const u8) Error!void {
    const n = try r.u32();
    if (n > MAX_EXPORTS) return Error.TooManyItems;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const name = try r.name();
        var j: usize = 0;
        while (j < export_count) : (j += 1) if (equalExportName(name, exports[j], wasm)) return Error.DuplicateExport;
        exports[export_count] = name;
        export_count += 1;
        const kind = try r.byte();
        const idx = try r.u32();
        const limit: usize = switch (kind) {
            0 => function_count,
            1 => table_count,
            2 => memory_count,
            3 => global_count,
            else => return Error.InvalidType,
        };
        if (idx >= limit) return Error.InvalidIndex;
    }
}

fn parseStartSection(r: *Reader) Error!void {
    const idx = try r.u32();
    if (idx >= function_count) return Error.InvalidIndex;
    const ft = types[function_types[idx]];
    if (ft.params_len != 0 or ft.result != null) return Error.InvalidType;
}

fn parseElementSection(r: *Reader) Error!void {
    const n = try r.u32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const table = try r.u32();
        if (table >= table_count) return Error.InvalidIndex;
        try constExpr(r, .i32);
        const count = try r.u32();
        var j: u32 = 0;
        while (j < count) : (j += 1) if (try r.u32() >= function_count) return Error.InvalidIndex;
    }
}

const CtrlKind = enum { function, block, loop, if_, else_ };
const Ctrl = struct { kind: CtrlKind, result: ?ValType, height: usize, unreachable_flag: bool };
var locals: [MAX_LOCALS]ValType = undefined;
var local_count: usize = 0;
var values: [MAX_VALUES]ValType = undefined;
var value_count: usize = 0;
var controls: [MAX_CONTROLS]Ctrl = undefined;
var control_count: usize = 0;
var function_result: ?ValType = null;

fn pushValue(t: ValType) Error!void {
    if (value_count == MAX_VALUES) return Error.TooManyItems;
    values[value_count] = t;
    value_count += 1;
}
fn popAny() Error!ValType {
    if (control_count == 0) return Error.InvalidControl;
    const c = controls[control_count - 1];
    if (value_count == c.height) {
        if (c.unreachable_flag) return .unknown;
        return Error.StackUnderflow;
    }
    value_count -= 1;
    return values[value_count];
}
fn popValue(expected: ValType) Error!void {
    const actual = try popAny();
    if (actual != .unknown and expected != .unknown and actual != expected) return Error.TypeMismatch;
}
fn pushCtrl(kind: CtrlKind, result: ?ValType) Error!void {
    if (control_count == MAX_CONTROLS) return Error.TooManyItems;
    controls[control_count] = .{ .kind = kind, .result = result, .height = value_count, .unreachable_flag = false };
    control_count += 1;
}
fn popCtrl() Error!Ctrl {
    if (control_count == 0) return Error.InvalidControl;
    const c = controls[control_count - 1];
    if (c.result) |t| try popValue(t);
    if (value_count != c.height) return Error.TypeMismatch;
    control_count -= 1;
    return c;
}
fn markUnreachable() Error!void {
    if (control_count == 0) return Error.InvalidControl;
    value_count = controls[control_count - 1].height;
    controls[control_count - 1].unreachable_flag = true;
}
fn labelType(depth: u32) Error!?ValType {
    if (depth >= control_count) return Error.InvalidIndex;
    const c = controls[control_count - 1 - depth];
    return if (c.kind == .loop) null else c.result;
}
fn popOptional(t: ?ValType) Error!void {
    if (t) |v| try popValue(v);
}
fn pushOptional(t: ?ValType) Error!void {
    if (t) |v| try pushValue(v);
}

fn blockType(r: *Reader) Error!?ValType {
    const b = try r.byte();
    if (b == 0x40) return null;
    return try valTypeByte(b);
}

fn functionType(idx: u32) Error!FuncType {
    if (idx >= function_count) return Error.InvalidIndex;
    return types[function_types[idx]];
}

fn popParams(ft: FuncType) Error!void {
    var i: usize = ft.params_len;
    while (i > 0) {
        i -= 1;
        try popValue(type_values[ft.params_off + i]);
    }
}

fn naturalAlign(op: u8) u32 {
    return switch (op) {
        0x28, 0x2a, 0x36, 0x38 => 2,
        0x29, 0x2b, 0x37, 0x39 => 3,
        0x2c, 0x2d, 0x30, 0x31, 0x3a, 0x3c => 0,
        0x2e, 0x2f, 0x32, 0x33, 0x3b, 0x3d => 1,
        0x34, 0x35, 0x3e => 2,
        else => unreachable,
    };
}

fn memoryLoadType(op: u8) ValType {
    return switch (op) {
        0x28, 0x2c...0x2f => .i32,
        0x29, 0x30...0x35 => .i64,
        0x2a => .f32,
        0x2b => .f64,
        else => unreachable,
    };
}
fn memoryStoreType(op: u8) ValType {
    return switch (op) {
        0x36, 0x3a, 0x3b => .i32,
        0x37, 0x3c...0x3e => .i64,
        0x38 => .f32,
        0x39 => .f64,
        else => unreachable,
    };
}

fn unary(input: ValType, output: ValType) Error!void {
    try popValue(input);
    try pushValue(output);
}
fn binary(t: ValType) Error!void {
    try popValue(t);
    try popValue(t);
    try pushValue(t);
}
fn compare(t: ValType) Error!void {
    try popValue(t);
    try popValue(t);
    try pushValue(.i32);
}

fn validateInstruction(r: *Reader) Error!bool {
    const op = try r.byte();
    switch (op) {
        0x00 => try markUnreachable(),
        0x01 => {},
        0x02, 0x03 => try pushCtrl(if (op == 0x02) .block else .loop, try blockType(r)),
        0x04 => {
            try popValue(.i32);
            try pushCtrl(.if_, try blockType(r));
        },
        0x05 => {
            const c = try popCtrl();
            if (c.kind != .if_) return Error.InvalidControl;
            try pushCtrl(.else_, c.result);
        },
        0x0b => {
            const c = try popCtrl();
            if (c.kind == .if_ and c.result != null) return Error.InvalidControl;
            try pushOptional(c.result);
            return control_count == 0;
        },
        0x0c => {
            try popOptional(try labelType(try r.u32()));
            try markUnreachable();
        },
        0x0d => {
            const t = try labelType(try r.u32());
            try popValue(.i32);
            try popOptional(t);
            try pushOptional(t);
        },
        0x0e => {
            const n = try r.u32();
            var expected: ?ValType = null;
            var set = false;
            var i: u32 = 0;
            while (i <= n) : (i += 1) {
                const t = try labelType(try r.u32());
                if (!set) {
                    expected = t;
                    set = true;
                } else if (expected != t) return Error.TypeMismatch;
            }
            try popValue(.i32);
            try popOptional(expected);
            try markUnreachable();
        },
        0x0f => {
            try popOptional(function_result);
            try markUnreachable();
        },
        0x10 => {
            const ft = try functionType(try r.u32());
            try popParams(ft);
            try pushOptional(ft.result);
        },
        0x11 => {
            const type_idx = try r.u32();
            if (type_idx >= type_count or table_count == 0 or try r.byte() != 0) return Error.InvalidIndex;
            const ft = types[type_idx];
            try popValue(.i32);
            try popParams(ft);
            try pushOptional(ft.result);
        },
        0x1a => _ = try popAny(),
        0x1b => {
            try popValue(.i32);
            const a = try popAny();
            const b = try popAny();
            if (a != .unknown and b != .unknown and a != b) return Error.TypeMismatch;
            try pushValue(if (a == .unknown) b else a);
        },
        0x20...0x22 => {
            const idx = try r.u32();
            if (idx >= local_count) return Error.InvalidIndex;
            const t = locals[idx];
            if (op == 0x20) try pushValue(t) else {
                try popValue(t);
                if (op == 0x22) try pushValue(t);
            }
        },
        0x23, 0x24 => {
            const idx = try r.u32();
            if (idx >= global_count) return Error.InvalidIndex;
            const g = globals[idx];
            if (op == 0x23) try pushValue(g.val) else {
                if (!g.mutable) return Error.InvalidType;
                try popValue(g.val);
            }
        },
        0x28...0x35 => {
            if (memory_count == 0 or try r.u32() > naturalAlign(op)) return Error.InvalidType;
            _ = try r.u32();
            try popValue(.i32);
            try pushValue(memoryLoadType(op));
        },
        0x36...0x3e => {
            if (memory_count == 0 or try r.u32() > naturalAlign(op)) return Error.InvalidType;
            _ = try r.u32();
            try popValue(memoryStoreType(op));
            try popValue(.i32);
        },
        0x3f => {
            if (memory_count == 0 or try r.byte() != 0) return Error.InvalidType;
            try pushValue(.i32);
        },
        0x40 => {
            if (memory_count == 0 or try r.byte() != 0) return Error.InvalidType;
            try unary(.i32, .i32);
        },
        0x41 => {
            _ = try r.s32();
            try pushValue(.i32);
        },
        0x42 => {
            _ = try r.s64();
            try pushValue(.i64);
        },
        0x43 => {
            _ = try r.bytes(4);
            try pushValue(.f32);
        },
        0x44 => {
            _ = try r.bytes(8);
            try pushValue(.f64);
        },
        0x45 => try unary(.i32, .i32),
        0x46...0x4f => try compare(.i32),
        0x50 => try unary(.i64, .i32),
        0x51...0x5a => try compare(.i64),
        0x5b...0x60 => try compare(.f32),
        0x61...0x66 => try compare(.f64),
        0x67...0x69 => try unary(.i32, .i32),
        0x6a...0x78 => try binary(.i32),
        0x79...0x7b => try unary(.i64, .i64),
        0x7c...0x8a => try binary(.i64),
        0x8b...0x91 => try unary(.f32, .f32),
        0x92...0x98 => try binary(.f32),
        0x99...0x9f => try unary(.f64, .f64),
        0xa0...0xa6 => try binary(.f64),
        0xa7 => try unary(.i64, .i32),
        0xa8, 0xa9 => try unary(.f32, .i32),
        0xaa, 0xab => try unary(.f64, .i32),
        0xac, 0xad => try unary(.i32, .i64),
        0xae, 0xaf => try unary(.f32, .i64),
        0xb0, 0xb1 => try unary(.f64, .i64),
        0xb2, 0xb3 => try unary(.i32, .f32),
        0xb4, 0xb5 => try unary(.i64, .f32),
        0xb6 => try unary(.f64, .f32),
        0xb7, 0xb8 => try unary(.i32, .f64),
        0xb9, 0xba => try unary(.i64, .f64),
        0xbb => try unary(.f32, .f64),
        0xbc => try unary(.f32, .i32),
        0xbd => try unary(.f64, .i64),
        0xbe => try unary(.i32, .f32),
        0xbf => try unary(.i64, .f64),
        else => return Error.InvalidWasm,
    }
    return false;
}

fn validateBody(body: []const u8, type_idx: u32) Error!void {
    var r = Reader.init(body);
    const ft = types[type_idx];
    local_count = 0;
    value_count = 0;
    control_count = 0;
    function_result = ft.result;
    var i: usize = 0;
    while (i < ft.params_len) : (i += 1) {
        locals[local_count] = type_values[ft.params_off + i];
        local_count += 1;
    }
    const groups = try r.u32();
    var g: u32 = 0;
    while (g < groups) : (g += 1) {
        const n = try r.u32();
        const t = try valTypeByte(try r.byte());
        if (n > MAX_LOCALS - local_count) return Error.TooManyItems;
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            locals[local_count] = t;
            local_count += 1;
        }
    }
    try pushCtrl(.function, ft.result);
    while (!try validateInstruction(&r)) {}
    const expected_values: usize = if (ft.result == null) 0 else 1;
    if (r.remaining() != 0 or value_count != expected_values) return Error.TypeMismatch;
}

fn parseCodeSection(r: *Reader) Error!void {
    const n = try r.u32();
    if (n != defined_function_count) return Error.FunctionCodeMismatch;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const size = try r.u32();
        const body = try r.bytes(size);
        try validateBody(body, function_types[imported_function_count + i]);
    }
}

fn parseDataSection(r: *Reader) Error!void {
    const n = try r.u32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (try r.u32() >= memory_count) return Error.InvalidIndex;
        try constExpr(r, .i32);
        _ = try r.bytes(try r.u32());
    }
}

fn checkModule(wasm: []const u8) Error!void {
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..8], "\x00asm\x01\x00\x00\x00")) return Error.InvalidWasm;
    resetState();
    var r = Reader.slice(wasm[8..], 8);
    var last: u8 = 0;
    var seen: u16 = 0;
    var have_code = false;
    while (r.remaining() != 0) {
        const id = try r.byte();
        const size = try r.u32();
        const payload_start = r.base + r.off;
        const payload = try r.bytes(size);
        var p = Reader.slice(payload, payload_start);
        if (id == 0) {
            _ = try p.name();
            p.off = p.data.len; // The remainder is uninterpreted custom data.
        } else {
            if (id > 11 or id <= last or (seen & (@as(u16, 1) << @intCast(id))) != 0) return Error.InvalidSection;
            last = id;
            seen |= @as(u16, 1) << @intCast(id);
            switch (id) {
                1 => try parseTypeSection(&p),
                2 => try parseImportSection(&p),
                3 => try parseFunctionSection(&p),
                4 => try parseTableSection(&p),
                5 => try parseMemorySection(&p),
                6 => try parseGlobalSection(&p),
                7 => try parseExportSection(&p, wasm),
                8 => try parseStartSection(&p),
                9 => try parseElementSection(&p),
                10 => {
                    try parseCodeSection(&p);
                    have_code = true;
                },
                11 => try parseDataSection(&p),
                else => unreachable,
            }
        }
        if (p.remaining() != 0) return Error.InvalidSection;
    }
    if (defined_function_count != 0 and !have_code) return Error.FunctionCodeMismatch;
}

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

const empty_module = "\x00asm\x01\x00\x00\x00";
const valid_add = "\x00asm\x01\x00\x00\x00" ++
    "\x01\x07\x01\x60\x02\x7f\x7f\x01\x7f" ++
    "\x03\x02\x01\x00" ++
    "\x0a\x09\x01\x07\x00\x20\x00\x20\x01\x6a\x0b";
const bad_add = "\x00asm\x01\x00\x00\x00" ++
    "\x01\x07\x01\x60\x02\x7f\x7e\x01\x7f" ++
    "\x03\x02\x01\x00" ++
    "\x0a\x09\x01\x07\x00\x20\x00\x20\x01\x6a\x0b";

test "accepts empty and typed Core 1.0 modules" {
    try checkModule(empty_module);
    try checkModule(valid_add);
}
test "rejects an ill-typed instruction sequence" {
    try std.testing.expectError(Error.TypeMismatch, checkModule(bad_add));
}
test "rejects a later bulk-memory instruction" {
    const later = "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x0a\x07\x01\x05\x00\xfc\x09\x00\x0b";
    try std.testing.expectError(Error.InvalidWasm, checkModule(later));
}
test "accepts maximum-length signed LEB encodings" {
    var i32_reader = Reader.init("\xff\xff\xff\xff\x7f");
    try std.testing.expectEqual(@as(i32, -1), try i32_reader.s32());
    var i64_reader = Reader.init("\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7f");
    try std.testing.expectEqual(@as(i64, -1), try i64_reader.s64());
}

test "render rejects invalid input and the instance recovers" {
    @memcpy(input_buf[0..bad_add.len], bad_add);
    const rejected = renderOutcome(bad_add.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);

    @memcpy(input_buf[0..empty_module.len], empty_module);
    const accepted = renderOutcome(empty_module.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, empty_module.len), accepted.output_size_or_failure);
}
