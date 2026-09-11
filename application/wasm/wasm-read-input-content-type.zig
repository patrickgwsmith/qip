//! Reads a QIP component's declared input content type directly from its Wasm
//! sections. The target module is never instantiated and none of its code runs.
//!
//! Empty output means the target declares no input content type. A malformed,
//! dynamic, partially declared, or runtime-populated input/output content type
//! traps. Validating both directions keeps this reader aligned with the strict
//! artifact profile even though it returns only the input type.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;
const MAX_TYPES: usize = 8192;
const MAX_FUNCS: usize = 8192;
const MAX_GLOBALS: usize = 8192;
const MAX_DATA_SEGMENTS: usize = 16384;
const INPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var type_buf: [MAX_TYPES]FuncType = undefined;
var func_type_buf: [MAX_FUNCS]u32 = undefined;
var function_body_buf: [MAX_FUNCS][]const u8 = undefined;
var global_buf: [MAX_GLOBALS]StaticGlobal = undefined;
var data_buf: [MAX_DATA_SEGMENTS]DataSegment = undefined;

const FuncType = struct {
    param_count: u32 = 0,
    result_count: u32 = 0,
    result_type: u8 = 0,
};

const StaticGlobal = struct {
    is_static_i32: bool = false,
    value: u32 = 0,
};

const DataSegment = struct {
    offset: u64,
    bytes: []const u8,
};

const MetadataExport = union(enum) {
    missing,
    function: u32,
    invalid,
};

const Metadata = struct {
    input_ptr: MetadataExport = .missing,
    input_size: MetadataExport = .missing,
    output_ptr: MetadataExport = .missing,
    output_size: MetadataExport = .missing,
};

const ModuleInfo = struct {
    type_count: u32 = 0,
    imported_func_count: u32 = 0,
    defined_func_count: u32 = 0,
    global_count: u32 = 0,
    memory_count: u32 = 0,
    memory_min_bytes: u64 = 0,
    data_count: usize = 0,
    metadata: Metadata = .{},
};

const ReadError = wasm_reader.Error || error{
    TooManyTypes,
    TooManyFunctions,
    TooManyGlobals,
    TooManyDataSegments,
    TooManyMemories,
    ImportedMemoryUnsupported,
    MetadataPairRequired,
    MetadataExportInvalid,
    MetadataSignatureInvalid,
    MetadataGetterNotStatic,
    MetadataGlobalNotStatic,
    MetadataOutOfBounds,
    MetadataNotPreinitialized,
    OutputTooLarge,
};

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

fn skipLimits(r: *Reader) ReadError!void {
    const limits = try wasm_reader.readLimits(r);
    _ = limits;
}

fn readName(r: *Reader) ReadError![]const u8 {
    return r.readN(try r.readVarU32());
}

fn parseTypeSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_TYPES) return ReadError.TooManyTypes;
    info.type_count = count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (try r.readByte() != 0x60) return ReadError.InvalidWasm;
        const param_count = try r.readVarU32();
        _ = try r.readN(param_count);
        const result_count = try r.readVarU32();
        var result_type: u8 = 0;
        if (result_count > 0) {
            result_type = try r.readByte();
            if (result_count > 1) _ = try r.readN(result_count - 1);
        }
        type_buf[i] = .{
            .param_count = param_count,
            .result_count = result_count,
            .result_type = result_type,
        };
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn parseImportSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try readName(&r);
        _ = try readName(&r);
        const kind = try r.readByte();
        switch (kind) {
            0x00 => {
                _ = try r.readVarU32();
                info.imported_func_count += 1;
            },
            0x01 => {
                _ = try r.readByte();
                try skipLimits(&r);
            },
            0x02 => {
                try skipLimits(&r);
                info.memory_count += 1;
                return ReadError.ImportedMemoryUnsupported;
            },
            0x03 => {
                _ = try r.readByte();
                _ = try r.readByte();
                if (info.global_count >= MAX_GLOBALS) return ReadError.TooManyGlobals;
                global_buf[info.global_count] = .{};
                info.global_count += 1;
            },
            else => return ReadError.InvalidWasm,
        }
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn parseFunctionSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_FUNCS) return ReadError.TooManyFunctions;
    info.defined_func_count = count;
    var i: u32 = 0;
    while (i < count) : (i += 1) func_type_buf[i] = try r.readVarU32();
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn parseMemorySection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (info.memory_count + count > 1) return ReadError.TooManyMemories;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const limits = try wasm_reader.readLimits(&r);
        if (limits.memory64) return ReadError.InvalidWasm;
        info.memory_min_bytes = limits.min * 65536;
        info.memory_count += 1;
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn readInitExpr(r: *Reader, info: *const ModuleInfo) ReadError!StaticGlobal {
    const op = try r.readByte();
    var result = StaticGlobal{};
    switch (op) {
        0x41 => result = .{ .is_static_i32 = true, .value = @bitCast(try r.readVarS32()) },
        0x42 => _ = try r.readVarS64(10),
        0x43 => _ = try r.readN(4),
        0x44 => _ = try r.readN(8),
        0x23 => {
            const idx = try r.readVarU32();
            if (idx < info.global_count and global_buf[idx].is_static_i32) result = global_buf[idx];
        },
        0xd0 => _ = try r.readVarS64(5),
        0xd2 => _ = try r.readVarU32(),
        0xfd => {
            if (try r.readVarU32() != 12) return ReadError.InvalidWasm;
            _ = try r.readN(16);
        },
        else => return ReadError.InvalidWasm,
    }
    if (try r.readByte() != 0x0b) return ReadError.InvalidWasm;
    return result;
}

fn parseGlobalSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (info.global_count + count > MAX_GLOBALS) return ReadError.TooManyGlobals;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const value_type = try r.readByte();
        const mutable = try r.readByte();
        const init = try readInitExpr(&r, info);
        global_buf[info.global_count] = if (value_type == 0x7f and mutable == 0) init else .{};
        info.global_count += 1;
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn metadataSlot(metadata: *Metadata, name: []const u8) ?*MetadataExport {
    if (std.mem.eql(u8, name, "input_content_type_ptr")) return &metadata.input_ptr;
    if (std.mem.eql(u8, name, "input_content_type_size")) return &metadata.input_size;
    if (std.mem.eql(u8, name, "output_content_type_ptr")) return &metadata.output_ptr;
    if (std.mem.eql(u8, name, "output_content_type_size")) return &metadata.output_size;
    return null;
}

fn parseExportSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try readName(&r);
        const kind = try r.readByte();
        const index = try r.readVarU32();
        const slot = metadataSlot(&info.metadata, name) orelse continue;
        slot.* = switch (kind) {
            0x00 => .{ .function = index },
            else => .invalid,
        };
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn parseCodeSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != info.defined_func_count) return ReadError.InvalidWasm;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const size = try r.readVarU32();
        function_body_buf[i] = try r.readN(size);
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn readStaticOffset(r: *Reader, info: *const ModuleInfo) ReadError!?u32 {
    const op = try r.readByte();
    var value: ?u32 = null;
    switch (op) {
        0x41 => value = @bitCast(try r.readVarS32()),
        0x23 => {
            const idx = try r.readVarU32();
            if (idx < info.global_count and global_buf[idx].is_static_i32) value = global_buf[idx].value;
        },
        else => return ReadError.InvalidWasm,
    }
    if (try r.readByte() != 0x0b) return ReadError.InvalidWasm;
    return value;
}

fn parseDataSection(info: *ModuleInfo, payload: []const u8) ReadError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try r.readVarU32();
        var active = false;
        var offset: ?u32 = null;
        switch (flags) {
            0 => {
                active = true;
                offset = try readStaticOffset(&r, info);
            },
            1 => {},
            2 => {
                active = (try r.readVarU32()) == 0;
                offset = try readStaticOffset(&r, info);
            },
            else => return ReadError.InvalidWasm,
        }
        const size = try r.readVarU32();
        const bytes = try r.readN(size);
        if (active and offset != null) {
            if (info.data_count >= MAX_DATA_SEGMENTS) return ReadError.TooManyDataSegments;
            data_buf[info.data_count] = .{ .offset = offset.?, .bytes = bytes };
            info.data_count += 1;
        }
    }
    if (r.remaining() != 0) return ReadError.TrailingBytes;
}

fn parseModule(wasm: []const u8) ReadError!ModuleInfo {
    try wasm_reader.checkHeader(wasm);
    var info = ModuleInfo{};
    var r = Reader.init(wasm[8..]);
    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);
        switch (section_id) {
            0 => {},
            1 => try parseTypeSection(&info, payload),
            2 => try parseImportSection(&info, payload),
            3 => try parseFunctionSection(&info, payload),
            5 => try parseMemorySection(&info, payload),
            6 => try parseGlobalSection(&info, payload),
            7 => try parseExportSection(&info, payload),
            10 => try parseCodeSection(&info, payload),
            11 => try parseDataSection(&info, payload),
            else => {},
        }
    }
    return info;
}

fn resolveGetter(info: *const ModuleInfo, body: []const u8) ReadError!u32 {
    var r = Reader.init(body);
    if (try r.readVarU32() != 0) return ReadError.MetadataGetterNotStatic;
    const value: u32 = switch (try r.readByte()) {
        0x41 => @bitCast(try r.readVarS32()),
        0x23 => blk: {
            const idx = try r.readVarU32();
            if (idx >= info.global_count or !global_buf[idx].is_static_i32) {
                return ReadError.MetadataGlobalNotStatic;
            }
            break :blk global_buf[idx].value;
        },
        else => return ReadError.MetadataGetterNotStatic,
    };
    if (try r.readByte() != 0x0b or r.remaining() != 0) return ReadError.MetadataGetterNotStatic;
    return value;
}

fn resolveExport(info: *const ModuleInfo, target: MetadataExport) ReadError!u32 {
    return switch (target) {
        .missing => ReadError.MetadataPairRequired,
        .invalid => ReadError.MetadataExportInvalid,
        .function => |idx| blk: {
            if (idx < info.imported_func_count) return ReadError.MetadataExportInvalid;
            const defined_idx = idx - info.imported_func_count;
            if (defined_idx >= info.defined_func_count) return ReadError.MetadataExportInvalid;
            const type_idx = func_type_buf[defined_idx];
            if (type_idx >= info.type_count) return ReadError.MetadataSignatureInvalid;
            const func_type = type_buf[type_idx];
            if (func_type.param_count != 0 or func_type.result_count != 1 or func_type.result_type != 0x7f) {
                return ReadError.MetadataSignatureInvalid;
            }
            break :blk try resolveGetter(info, function_body_buf[defined_idx]);
        },
    };
}

fn readRegion(info: *const ModuleInfo, ptr: u32, size: u32) ReadError![]const u8 {
    const start: u64 = ptr;
    const end = start + size;
    if (end > info.memory_min_bytes) return ReadError.MetadataOutOfBounds;
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (i < info.data_count) : (i += 1) {
        const segment = data_buf[i];
        const seg_start = segment.offset;
        const seg_end = seg_start + segment.bytes.len;
        if (seg_end <= start or seg_start >= end) continue;
        if (found != null or seg_start > start or seg_end < end) return ReadError.MetadataNotPreinitialized;
        const offset: usize = @intCast(start - seg_start);
        const length: usize = @intCast(size);
        found = segment.bytes[offset .. offset + length];
    }
    return found orelse ReadError.MetadataNotPreinitialized;
}

fn readPair(info: *const ModuleInfo, ptr_export: MetadataExport, size_export: MetadataExport) ReadError!?[]const u8 {
    if (ptr_export == .missing and size_export == .missing) return null;
    if (ptr_export == .missing or size_export == .missing) return ReadError.MetadataPairRequired;
    const ptr = try resolveExport(info, ptr_export);
    const size = try resolveExport(info, size_export);
    return try readRegion(info, ptr, size);
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    const info = parseModule(input_buf[0..input_size]) catch @trap();
    const input_type = readPair(&info, info.metadata.input_ptr, info.metadata.input_size) catch @trap();
    _ = readPair(&info, info.metadata.output_ptr, info.metadata.output_size) catch @trap();
    const value = input_type orelse return 0;
    if (value.len > OUTPUT_CAP) @trap();
    @memcpy(output_buf[0..value.len], value);
    return @intCast(value.len);
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
