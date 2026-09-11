const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
const SCRATCH_CAP: usize = 16 * 1024 * 1024;
const BODY_CAP: usize = 8 * 1024 * 1024;
const MAX_TYPES: usize = 8192;
const MAX_FUNCS: usize = 8192;

const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

const TRACE_MODULE = "qip_trace";
const TRACE_BEFORE_LOAD = "before_load";
const TRACE_BEFORE_STORE = "before_store";
const TRACE_AFTER_STORE = "after_store";
const TRACE_IMPORT_COUNT: u32 = 3;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var scratch_buf: [SCRATCH_CAP]u8 = undefined;
var body_buf: [BODY_CAP]u8 = undefined;

var type_param_counts: [MAX_TYPES]u32 = [_]u32{0} ** MAX_TYPES;
var func_type_indices: [MAX_FUNCS]u32 = [_]u32{0} ** MAX_FUNCS;
var old_type_count: u32 = 0;
var old_imported_func_count: u32 = 0;
var defined_func_count: u32 = 0;
var trace_type_index: u32 = 0;

const InstrumentError = error{
    InvalidWasm,
    UnsupportedVersion,
    UnexpectedEOF,
    InvalidLEB,
    OutputTooLarge,
    ScratchTooSmall,
    BodyTooLarge,
    TooManyTypes,
    TooManyFunctions,
    MissingTypeSection,
    MissingFunctionSection,
    FunctionCodeMismatch,
    UnsupportedImportKind,
    UnsupportedInstruction,
    UnsupportedMemory64,
    UnsupportedMultiMemory,
    UnsupportedSIMDMemory,
    UnsupportedAtomicMemory,
};

const Reader = struct {
    data: []const u8,
    off: usize = 0,

    fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.off;
    }

    fn readByte(self: *Reader) InstrumentError!u8 {
        if (self.off >= self.data.len) return InstrumentError.UnexpectedEOF;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }

    fn peekByte(self: *const Reader) InstrumentError!u8 {
        if (self.off >= self.data.len) return InstrumentError.UnexpectedEOF;
        return self.data[self.off];
    }

    fn readN(self: *Reader, n: usize) InstrumentError![]const u8 {
        if (self.remaining() < n) return InstrumentError.UnexpectedEOF;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }

    fn readName(self: *Reader) InstrumentError![]const u8 {
        const n = try self.readVarU32();
        return self.readN(n);
    }

    fn readVarU32(self: *Reader) InstrumentError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return InstrumentError.InvalidLEB;
    }

    fn readVarU64(self: *Reader) InstrumentError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return InstrumentError.InvalidLEB;
    }

    fn readVarS32(self: *Reader) InstrumentError!i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < 5) : (i += 1) {
            b = try self.readByte();
            result |= @as(i32, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == 4) return InstrumentError.InvalidLEB;
        }
        if (shift < 32 and (b & 0x40) != 0) {
            result |= ~@as(i32, 0) << shift;
        }
        return result;
    }

    fn readVarS64(self: *Reader, max_bytes: usize) InstrumentError!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.readByte();
            result |= @as(i64, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == max_bytes - 1) return InstrumentError.InvalidLEB;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= ~@as(i64, 0) << shift;
        }
        return result;
    }
};

const Writer = struct {
    buf: []u8,
    off: usize = 0,
    err: InstrumentError,

    fn init(buf: []u8, err: InstrumentError) Writer {
        return .{ .buf = buf, .err = err };
    }

    fn bytes(self: *const Writer) []const u8 {
        return self.buf[0..self.off];
    }

    fn writeByte(self: *Writer, b: u8) InstrumentError!void {
        if (self.off >= self.buf.len) return self.err;
        self.buf[self.off] = b;
        self.off += 1;
    }

    fn writeAll(self: *Writer, data: []const u8) InstrumentError!void {
        if (self.off + data.len > self.buf.len) return self.err;
        @memcpy(self.buf[self.off .. self.off + data.len], data);
        self.off += data.len;
    }

    fn writeName(self: *Writer, name: []const u8) InstrumentError!void {
        try self.writeVarU32(@intCast(name.len));
        try self.writeAll(name);
    }

    fn writeVarU32(self: *Writer, value_in: u32) InstrumentError!void {
        var value = value_in;
        while (true) {
            var b: u8 = @intCast(value & 0x7f);
            value >>= 7;
            if (value != 0) b |= 0x80;
            try self.writeByte(b);
            if (value == 0) break;
        }
    }

    fn writeVarS32(self: *Writer, value_in: i32) InstrumentError!void {
        var value = value_in;
        while (true) {
            const b: u8 = @intCast(@as(u32, @bitCast(value)) & 0x7f);
            value >>= 7;
            const done = (value == 0 and (b & 0x40) == 0) or (value == -1 and (b & 0x40) != 0);
            try self.writeByte(if (done) b else b | 0x80);
            if (done) break;
        }
    }
};

const MemOpKind = enum { load, store };
const ValueType = enum { i32, i64, f32, f64 };
const MemOp = struct {
    kind: MemOpKind,
    width: u32,
    value_type: ValueType,
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

fn resetInfo() void {
    old_type_count = 0;
    old_imported_func_count = 0;
    defined_func_count = 0;
    trace_type_index = 0;
}

fn readBlockType(r: *Reader) InstrumentError!void {
    const b = try r.peekByte();
    switch (b) {
        0x40, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f => _ = try r.readByte(),
        else => _ = try r.readVarS64(5),
    }
}

fn readMemArg(r: *Reader) InstrumentError!struct { alignment: u32, offset: u32 } {
    const alignment = try r.readVarU32();
    const offset = try r.readVarU32();
    return .{ .alignment = alignment, .offset = offset };
}

fn skipLimits(r: *Reader) InstrumentError!void {
    const flags = try r.readVarU32();
    if ((flags & 0x04) != 0) return InstrumentError.UnsupportedMemory64;
    _ = try r.readVarU32();
    if ((flags & 0x01) != 0) _ = try r.readVarU32();
}

fn skipTableType(r: *Reader) InstrumentError!void {
    _ = try r.readByte();
    try skipLimits(r);
}

fn skipGlobalType(r: *Reader) InstrumentError!void {
    _ = try r.readByte();
    _ = try r.readByte();
}

fn parseTypeSection(payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count >= MAX_TYPES) return InstrumentError.TooManyTypes;
    old_type_count = count;
    trace_type_index = count;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const form = try r.readByte();
        if (form != 0x60) return InstrumentError.InvalidWasm;
        const params = try r.readVarU32();
        if (i < MAX_TYPES) type_param_counts[@intCast(i)] = params;
        _ = try r.readN(params);
        const results = try r.readVarU32();
        _ = try r.readN(results);
    }
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
}

fn parseImportSection(payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try r.readName();
        _ = try r.readName();
        const kind = try r.readByte();
        switch (kind) {
            0x00 => {
                _ = try r.readVarU32();
                old_imported_func_count += 1;
            },
            0x01 => try skipTableType(&r),
            0x02 => try skipLimits(&r),
            0x03 => try skipGlobalType(&r),
            0x04 => {
                _ = try r.readByte();
                _ = try r.readVarU32();
            },
            else => return InstrumentError.UnsupportedImportKind,
        }
    }
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
}

fn parseFunctionSection(payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_FUNCS) return InstrumentError.TooManyFunctions;
    defined_func_count = count;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const type_idx = try r.readVarU32();
        if (type_idx >= old_type_count) return InstrumentError.InvalidWasm;
        func_type_indices[@intCast(i)] = type_idx;
    }
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
}

fn scanModule(input: []const u8) InstrumentError!void {
    resetInfo();
    if (input.len < 8) return InstrumentError.InvalidWasm;
    if (!std.mem.eql(u8, input[0..4], "\x00asm")) return InstrumentError.InvalidWasm;
    if (!std.mem.eql(u8, input[4..8], "\x01\x00\x00\x00")) return InstrumentError.UnsupportedVersion;

    var r = Reader.init(input[8..]);
    var saw_type = false;
    var saw_function = false;
    while (r.remaining() > 0) {
        const id = try r.readByte();
        const size = try r.readVarU32();
        const payload = try r.readN(size);
        switch (id) {
            1 => {
                try parseTypeSection(payload);
                saw_type = true;
            },
            2 => try parseImportSection(payload),
            3 => {
                if (!saw_type) return InstrumentError.MissingTypeSection;
                try parseFunctionSection(payload);
                saw_function = true;
            },
            5 => try parseMemorySection(payload),
            else => {},
        }
    }
    if (!saw_type) return InstrumentError.MissingTypeSection;
    if (!saw_function) return InstrumentError.MissingFunctionSection;
}

fn parseMemorySection(payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > 1) return InstrumentError.UnsupportedMultiMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) try skipLimits(&r);
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
}

fn shiftFuncIndex(idx: u32) u32 {
    return if (idx >= old_imported_func_count) idx + TRACE_IMPORT_COUNT else idx;
}

fn emitSection(out: *Writer, id: u8, payload: []const u8) InstrumentError!void {
    try out.writeByte(id);
    try out.writeVarU32(@intCast(payload.len));
    try out.writeAll(payload);
}

fn writeTraceType(out: *Writer) InstrumentError!void {
    try out.writeByte(0x60);
    try out.writeVarU32(5);
    try out.writeByte(0x7f);
    try out.writeByte(0x7f);
    try out.writeByte(0x7f);
    try out.writeByte(0x7f);
    try out.writeByte(0x7f);
    try out.writeVarU32(0);
}

fn emitTypeSection(out: *Writer, payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var p = Writer.init(scratch_buf[0..], InstrumentError.ScratchTooSmall);
    try p.writeVarU32(count + 1);
    try p.writeAll(payload[r.off..]);
    try writeTraceType(&p);
    try emitSection(out, 1, p.bytes());
}

fn writeTraceImport(out: *Writer, name: []const u8) InstrumentError!void {
    try out.writeName(TRACE_MODULE);
    try out.writeName(name);
    try out.writeByte(0x00);
    try out.writeVarU32(trace_type_index);
}

fn emitImportSection(out: *Writer, payload: ?[]const u8) InstrumentError!void {
    var p = Writer.init(scratch_buf[0..], InstrumentError.ScratchTooSmall);
    if (payload) |bytes| {
        var r = Reader.init(bytes);
        const count = try r.readVarU32();
        try p.writeVarU32(count + TRACE_IMPORT_COUNT);
        try p.writeAll(bytes[r.off..]);
    } else {
        try p.writeVarU32(TRACE_IMPORT_COUNT);
    }
    try writeTraceImport(&p, TRACE_BEFORE_LOAD);
    try writeTraceImport(&p, TRACE_BEFORE_STORE);
    try writeTraceImport(&p, TRACE_AFTER_STORE);
    try emitSection(out, 2, p.bytes());
}

fn emitExportSection(out: *Writer, payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    var p = Writer.init(scratch_buf[0..], InstrumentError.ScratchTooSmall);
    const count = try r.readVarU32();
    try p.writeVarU32(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try r.readName();
        const kind = try r.readByte();
        const idx = try r.readVarU32();
        try p.writeName(name);
        try p.writeByte(kind);
        try p.writeVarU32(if (kind == 0x00) shiftFuncIndex(idx) else idx);
    }
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
    try emitSection(out, 7, p.bytes());
}

fn emitStartSection(out: *Writer, payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    const idx = try r.readVarU32();
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
    var p = Writer.init(scratch_buf[0..], InstrumentError.ScratchTooSmall);
    try p.writeVarU32(shiftFuncIndex(idx));
    try emitSection(out, 8, p.bytes());
}

fn transformConstExpression(r: *Reader, p: *Writer) InstrumentError!void {
    while (true) {
        const op_start = r.off;
        const op = try r.readByte();
        switch (op) {
            0x0b => {
                try p.writeByte(0x0b);
                return;
            },
            0x23 => {
                _ = try r.readVarU32();
                try p.writeAll(r.data[op_start..r.off]);
            },
            0x41 => {
                _ = try r.readVarS32();
                try p.writeAll(r.data[op_start..r.off]);
            },
            0x42 => {
                _ = try r.readVarS64(10);
                try p.writeAll(r.data[op_start..r.off]);
            },
            0x43 => {
                _ = try r.readN(4);
                try p.writeAll(r.data[op_start..r.off]);
            },
            0x44 => {
                _ = try r.readN(8);
                try p.writeAll(r.data[op_start..r.off]);
            },
            0xd0 => {
                _ = try r.readByte();
                try p.writeAll(r.data[op_start..r.off]);
            },
            0xd2 => {
                const idx = try r.readVarU32();
                try p.writeByte(op);
                try p.writeVarU32(shiftFuncIndex(idx));
            },
            else => return InstrumentError.UnsupportedInstruction,
        }
    }
}

fn transformFuncIndexVec(r: *Reader, p: *Writer) InstrumentError!void {
    const count = try r.readVarU32();
    try p.writeVarU32(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const idx = try r.readVarU32();
        try p.writeVarU32(shiftFuncIndex(idx));
    }
}

fn transformExpressionVec(r: *Reader, p: *Writer) InstrumentError!void {
    const count = try r.readVarU32();
    try p.writeVarU32(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try transformConstExpression(r, p);
    }
}

fn emitElementSection(out: *Writer, payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    var p = Writer.init(scratch_buf[0..], InstrumentError.ScratchTooSmall);
    const count = try r.readVarU32();
    try p.writeVarU32(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try r.readVarU32();
        try p.writeVarU32(flags);
        switch (flags) {
            0 => {
                try transformConstExpression(&r, &p);
                try transformFuncIndexVec(&r, &p);
            },
            1, 3 => {
                const elem_kind = try r.readByte();
                try p.writeByte(elem_kind);
                try transformFuncIndexVec(&r, &p);
            },
            2 => {
                const table_idx = try r.readVarU32();
                try p.writeVarU32(table_idx);
                try transformConstExpression(&r, &p);
                const elem_kind = try r.readByte();
                try p.writeByte(elem_kind);
                try transformFuncIndexVec(&r, &p);
            },
            4 => {
                try transformConstExpression(&r, &p);
                try transformExpressionVec(&r, &p);
            },
            5, 7 => {
                const reftype = try r.readByte();
                try p.writeByte(reftype);
                try transformExpressionVec(&r, &p);
            },
            6 => {
                const table_idx = try r.readVarU32();
                try p.writeVarU32(table_idx);
                try transformConstExpression(&r, &p);
                const reftype = try r.readByte();
                try p.writeByte(reftype);
                try transformExpressionVec(&r, &p);
            },
            else => return InstrumentError.InvalidWasm,
        }
    }
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
    try emitSection(out, 9, p.bytes());
}

fn memOp(op: u8) ?MemOp {
    return switch (op) {
        0x28 => .{ .kind = .load, .width = 4, .value_type = .i32 },
        0x29 => .{ .kind = .load, .width = 8, .value_type = .i64 },
        0x2a => .{ .kind = .load, .width = 4, .value_type = .f32 },
        0x2b => .{ .kind = .load, .width = 8, .value_type = .f64 },
        0x2c, 0x2d => .{ .kind = .load, .width = 1, .value_type = .i32 },
        0x2e, 0x2f => .{ .kind = .load, .width = 2, .value_type = .i32 },
        0x30, 0x31 => .{ .kind = .load, .width = 1, .value_type = .i64 },
        0x32, 0x33 => .{ .kind = .load, .width = 2, .value_type = .i64 },
        0x34, 0x35 => .{ .kind = .load, .width = 4, .value_type = .i64 },
        0x36 => .{ .kind = .store, .width = 4, .value_type = .i32 },
        0x37 => .{ .kind = .store, .width = 8, .value_type = .i64 },
        0x38 => .{ .kind = .store, .width = 4, .value_type = .f32 },
        0x39 => .{ .kind = .store, .width = 8, .value_type = .f64 },
        0x3a, 0x3b => .{ .kind = .store, .width = 1, .value_type = .i32 },
        0x3c => .{ .kind = .store, .width = 1, .value_type = .i64 },
        0x3d => .{ .kind = .store, .width = 2, .value_type = .i64 },
        0x3e => .{ .kind = .store, .width = 4, .value_type = .i64 },
        else => null,
    };
}

fn traceImportIndex(kind: MemOpKind, after: bool) u32 {
    return switch (kind) {
        .load => old_imported_func_count,
        .store => if (after) old_imported_func_count + 2 else old_imported_func_count + 1,
    };
}

fn writeLocalSet(out: *Writer, idx: u32) InstrumentError!void {
    try out.writeByte(0x21);
    try out.writeVarU32(idx);
}

fn writeLocalGet(out: *Writer, idx: u32) InstrumentError!void {
    try out.writeByte(0x20);
    try out.writeVarU32(idx);
}

fn writeI32Const(out: *Writer, value: u32) InstrumentError!void {
    try out.writeByte(0x41);
    try out.writeVarS32(@bitCast(value));
}

fn writeTraceCall(out: *Writer, func_id: u32, op_id: u32, addr_local: u32, width: u32, offset: u32, trace_func_idx: u32) InstrumentError!void {
    try writeI32Const(out, func_id);
    try writeI32Const(out, op_id);
    try writeI32Const(out, 0);
    try writeLocalGet(out, addr_local);
    if (offset != 0) {
        try writeI32Const(out, offset);
        try out.writeByte(0x6a);
    }
    try writeI32Const(out, width);
    try out.writeByte(0x10);
    try out.writeVarU32(trace_func_idx);
}

fn valueLocalFor(value_type: ValueType, value_i32_local: u32) u32 {
    return switch (value_type) {
        .i32 => value_i32_local,
        .i64 => value_i32_local + 1,
        .f32 => value_i32_local + 2,
        .f64 => value_i32_local + 3,
    };
}

fn instrumentLoad(out: *Writer, op: u8, mem: MemOp, alignment: u32, offset: u32, func_id: u32, op_id: u32, addr_local: u32) InstrumentError!void {
    try writeLocalSet(out, addr_local);
    try writeTraceCall(out, func_id, op_id, addr_local, mem.width, offset, traceImportIndex(.load, false));
    try writeLocalGet(out, addr_local);
    try out.writeByte(op);
    try out.writeVarU32(alignment);
    try out.writeVarU32(offset);
}

fn instrumentStore(out: *Writer, op: u8, mem: MemOp, alignment: u32, offset: u32, func_id: u32, op_id: u32, addr_local: u32, value_i32_local: u32) InstrumentError!void {
    const value_local = valueLocalFor(mem.value_type, value_i32_local);
    try writeLocalSet(out, value_local);
    try writeLocalSet(out, addr_local);
    try writeTraceCall(out, func_id, op_id, addr_local, mem.width, offset, traceImportIndex(.store, false));
    try writeLocalGet(out, addr_local);
    try writeLocalGet(out, value_local);
    try out.writeByte(op);
    try out.writeVarU32(alignment);
    try out.writeVarU32(offset);
    try writeTraceCall(out, func_id, op_id, addr_local, mem.width, offset, traceImportIndex(.store, true));
}

fn skipFCImmediate(r: *Reader) InstrumentError!void {
    const sub = try r.readVarU32();
    switch (sub) {
        0 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        1 => _ = try r.readVarU32(),
        2 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        3 => _ = try r.readVarU32(),
        4 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        5 => _ = try r.readVarU32(),
        6 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        7, 8, 9 => _ = try r.readVarU32(),
        10 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        11 => _ = try r.readVarU32(),
        else => {},
    }
}

fn skipFDImmediate(r: *Reader) InstrumentError!void {
    const sub = try r.readVarU32();
    switch (sub) {
        0...11, 84, 85 => return InstrumentError.UnsupportedSIMDMemory,
        12, 13 => _ = try r.readN(16),
        21...34 => _ = try r.readByte(),
        92...99 => return InstrumentError.UnsupportedSIMDMemory,
        else => {},
    }
}

fn skipInstructionImmediate(r: *Reader, op: u8) InstrumentError!void {
    switch (op) {
        0x00, 0x01, 0x05, 0x0b, 0x0f, 0x1a, 0x1b => {},
        0x02, 0x03, 0x04 => try readBlockType(r),
        0x0c, 0x0d => _ = try r.readVarU32(),
        0x0e => {
            const count = try r.readVarU32();
            var i: u32 = 0;
            while (i < count) : (i += 1) _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        0x11, 0x13 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        0x14 => _ = try r.readVarU32(),
        0x1c => {
            const count = try r.readVarU32();
            _ = try r.readN(count);
        },
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => _ = try r.readVarU32(),
        0x3f, 0x40 => _ = try r.readVarU32(),
        0x41 => _ = try r.readVarS32(),
        0x42 => _ = try r.readVarS64(10),
        0x43 => _ = try r.readN(4),
        0x44 => _ = try r.readN(8),
        0x45...0xbf => {},
        0xd0 => _ = try r.readByte(),
        0xd1 => {},
        0xfc => try skipFCImmediate(r),
        0xfd => try skipFDImmediate(r),
        0xfe => return InstrumentError.UnsupportedAtomicMemory,
        else => return InstrumentError.UnsupportedInstruction,
    }
}

fn transformFunctionBody(body: []const u8, defined_idx: u32) InstrumentError![]const u8 {
    var r = Reader.init(body);
    var out = Writer.init(body_buf[0..], InstrumentError.BodyTooLarge);

    const local_decl_count_start = r.off;
    const local_decl_count = try r.readVarU32();
    const local_entries_start = r.off;
    var existing_local_count: u32 = 0;
    var ld: u32 = 0;
    while (ld < local_decl_count) : (ld += 1) {
        const n = try r.readVarU32();
        _ = try r.readByte();
        existing_local_count += n;
    }
    const local_entries_end = r.off;
    _ = local_decl_count_start;

    const type_idx = func_type_indices[@intCast(defined_idx)];
    const param_count = type_param_counts[@intCast(type_idx)];
    const addr_local = param_count + existing_local_count;
    const value_i32_local = addr_local + 1;
    const func_id = old_imported_func_count + defined_idx;

    try out.writeVarU32(local_decl_count + 4);
    try out.writeAll(body[local_entries_start..local_entries_end]);
    try out.writeVarU32(2);
    try out.writeByte(0x7f);
    try out.writeVarU32(1);
    try out.writeByte(0x7e);
    try out.writeVarU32(1);
    try out.writeByte(0x7d);
    try out.writeVarU32(1);
    try out.writeByte(0x7c);

    var op_id: u32 = 0;
    while (r.remaining() > 0) {
        const op_start = r.off;
        const op = try r.readByte();
        if (memOp(op)) |m| {
            const mem = try readMemArg(&r);
            switch (m.kind) {
                .load => try instrumentLoad(&out, op, m, mem.alignment, mem.offset, func_id, op_id, addr_local),
                .store => try instrumentStore(&out, op, m, mem.alignment, mem.offset, func_id, op_id, addr_local, value_i32_local),
            }
            op_id += 1;
            continue;
        }
        switch (op) {
            0x10, 0x12 => {
                const idx = try r.readVarU32();
                try out.writeByte(op);
                try out.writeVarU32(shiftFuncIndex(idx));
            },
            0xd2 => {
                const idx = try r.readVarU32();
                try out.writeByte(op);
                try out.writeVarU32(shiftFuncIndex(idx));
            },
            else => {
                try skipInstructionImmediate(&r, op);
                try out.writeAll(body[op_start..r.off]);
            },
        }
    }
    return out.bytes();
}

fn emitCodeSection(out: *Writer, payload: []const u8) InstrumentError!void {
    var r = Reader.init(payload);
    var p = Writer.init(scratch_buf[0..], InstrumentError.ScratchTooSmall);
    const count = try r.readVarU32();
    if (count != defined_func_count) return InstrumentError.FunctionCodeMismatch;
    try p.writeVarU32(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body_size = try r.readVarU32();
        const body = try r.readN(body_size);
        const next = try transformFunctionBody(body, i);
        try p.writeVarU32(@intCast(next.len));
        try p.writeAll(next);
    }
    if (r.remaining() != 0) return InstrumentError.InvalidWasm;
    try emitSection(out, 10, p.bytes());
}

fn instrumentModule(input: []const u8) InstrumentError!usize {
    try scanModule(input);

    var out = Writer.init(output_buf[0..], InstrumentError.OutputTooLarge);
    try out.writeAll(input[0..8]);

    var r = Reader.init(input[8..]);
    var emitted_import = false;
    var emitted_type = false;
    while (r.remaining() > 0) {
        const section_start = r.off;
        const id = try r.readByte();
        const size = try r.readVarU32();
        const payload = try r.readN(size);
        switch (id) {
            0 => try out.writeAll(r.data[section_start..r.off]),
            1 => {
                try emitTypeSection(&out, payload);
                emitted_type = true;
            },
            2 => {
                try emitImportSection(&out, payload);
                emitted_import = true;
            },
            else => {
                if (!emitted_type) return InstrumentError.MissingTypeSection;
                if (!emitted_import and id > 2) {
                    try emitImportSection(&out, null);
                    emitted_import = true;
                }
                switch (id) {
                    7 => try emitExportSection(&out, payload),
                    8 => try emitStartSection(&out, payload),
                    9 => try emitElementSection(&out, payload),
                    10 => try emitCodeSection(&out, payload),
                    else => try out.writeAll(r.data[section_start..r.off]),
                }
            },
        }
    }
    return out.off;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    const output_size = instrumentModule(input_buf[0..input_size]) catch @trap();
    return @intCast(output_size);
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
