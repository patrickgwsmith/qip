//! wasm-strict-profile: a QIP component that enforces the strict artifact
//! profile's factual rules — the checks that are binary and stable:
//!
//! - no imports of any kind
//! - at most one linear memory, wasm32, not shared, with a declared maximum
//! - no start function
//! - no `memory.grow`
//! - no atomic instructions
//! - no indirect calls (`call_indirect`, `return_call_indirect`, `call_ref`)
//! - no recursion (the direct call graph must be acyclic)
//! - input pointer and input/output capacity getters are static constants
//! - active data segments do not overlap the complete input buffer
//! - content-type metadata, when exported, is statically readable from the
//!   module's initial memory image without instantiation
//!
//! This component enforces artifact policy, not the WebAssembly specification's
//! complete module-validation algorithm. It assumes a valid Wasm module. The
//! instruction reader still fails closed when it cannot safely decode a body,
//! but section order, indices, types, and constant expressions belong in a
//! separate wasm-validation component.
//!
//! Complexity for a valid module, where B is its byte length, I its instruction
//! count, V its defined-function count, and E its direct-call edges:
//!
//! | Rule                                      | Time     | Extra space |
//! |-------------------------------------------|----------|-------------|
//! | Reject imports                            | O(B)     | O(1)        |
//! | Check memory count/kind/sharing/maximum   | O(B)     | O(1)        |
//! | Reject a start function                   | O(B)     | O(1)        |
//! | Reject memory.grow                        | O(I)     | O(1)        |
//! | Reject atomic instructions                | O(I)     | O(1)        |
//! | Reject indirect and reference calls       | O(I)     | O(1)        |
//! | Detect recursive direct-call cycles       | O(V + E) | O(V + E)    |
//! | Resolve static content-type metadata      | O(B)     | O(S)        |
//!
//! The module bytes are read sequentially once. Direct-call edges are collected
//! during that pass, then an iterative depth-first search traverses the graph.
//! Since every edge comes from an instruction, the complete policy check is O(B).
//!
//! The recursion rule lives here rather than with the loop analysis because
//! it is one binary fact: edge collection rides the same decode pass the
//! allowlist needs, and its soundness depends on the indirect-call ban (with
//! indirect calls rejected, the recorded edges are the complete call graph).
//! Recursion is also a determinism problem for every tier: stack exhaustion
//! traps at a host-dependent depth.
//!
//! Input is a wasm module; output is the same bytes when the module passes;
//! the component traps on any violation. Subjective flow analysis (loop
//! bounds) lives in wasm-bounded-loops; run both for the full strict tier:
//!
//!   qip run -i m.wasm -- wasm-strict-profile.wasm wasm-bounded-loops.wasm
//!
//! A future Go strict-policy entry point should mirror this table and use the
//! same accept/reject fixtures. Full Wasm validation remains a separate layer.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_TYPES: usize = MAX_DEFINED_FUNCS;
const MAX_GLOBALS: usize = MAX_DEFINED_FUNCS;
const MAX_DATA_SEGMENTS: usize = 16384;
const MAX_CALL_EDGES: usize = 262144;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

var edge_head_buf: [MAX_DEFINED_FUNCS]i32 = undefined;
var edge_to_buf: [MAX_CALL_EDGES]u32 = undefined;
var edge_next_buf: [MAX_CALL_EDGES]i32 = undefined;
var edge_count: usize = 0;
var dfs_state_buf: [MAX_DEFINED_FUNCS]u8 = undefined;
var dfs_stack_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var dfs_edge_buf: [MAX_DEFINED_FUNCS]i32 = undefined;
var type_buf: [MAX_TYPES]FuncType = undefined;
var func_type_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var global_buf: [MAX_GLOBALS]StaticGlobal = undefined;
var data_range_buf: [MAX_DATA_SEGMENTS]DataRange = undefined;
var data_range_count: usize = 0;
var function_body_buf: [MAX_DEFINED_FUNCS][]const u8 = undefined;

const FuncType = struct {
    param_count: u32 = 0,
    result_count: u32 = 0,
    result_type: u8 = 0,
};

const StaticGlobal = struct {
    is_static_i32: bool = false,
    value: u32 = 0,
};

const DataRange = struct {
    start: u64,
    end: u64,
};

const MetadataExport = union(enum) {
    missing,
    function: u32,
    invalid,
};

const ContentTypeMetadata = struct {
    input_ptr: MetadataExport = .missing,
    input_size: MetadataExport = .missing,
    output_ptr: MetadataExport = .missing,
    output_size: MetadataExport = .missing,
};

const BufferMetadata = struct {
    input_ptr: MetadataExport = .missing,
    input_utf8_cap: MetadataExport = .missing,
    input_bytes_cap: MetadataExport = .missing,
    output_utf8_cap: MetadataExport = .missing,
    output_bytes_cap: MetadataExport = .missing,
};

const CheckError = wasm_reader.Error || error{
    ImportNotAllowed,
    Memory64NotAllowed,
    SharedMemoryNotAllowed,
    MemoryMaxRequired,
    TooManyMemories,
    StartFunctionNotAllowed,
    MemoryGrowNotAllowed,
    AtomicsNotAllowed,
    IndirectCallNotAllowed,
    RecursionNotAllowed,
    FunctionCodeMismatch,
    TooManyFunctions,
    TooManyEdges,
    TooManyTypes,
    TooManyGlobals,
    TooManyDataSegments,
    ContentTypePairRequired,
    ContentTypeExportInvalid,
    ContentTypeSignatureInvalid,
    ContentTypeGetterNotStatic,
    ContentTypeGlobalNotStatic,
    ContentTypeOutOfBounds,
    ContentTypeNotPreinitialized,
    BufferExportRequired,
    BufferExportInvalid,
    BufferSignatureInvalid,
    BufferGetterNotStatic,
    BufferGlobalNotStatic,
    BufferCapacityAmbiguous,
    BufferOutOfBounds,
    InputDataOverlap,
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
// Call graph: direct calls between defined functions, rejected on any cycle.
// ---------------------------------------------------------------------------

fn initEdgeGraph(defined_funcs: usize) void {
    var i: usize = 0;
    while (i < defined_funcs) : (i += 1) {
        edge_head_buf[i] = -1;
    }
    edge_count = 0;
}

fn addEdge(src: u32, dst: u32) CheckError!void {
    if (edge_count >= MAX_CALL_EDGES) return CheckError.TooManyEdges;
    const idx = edge_count;
    edge_to_buf[idx] = dst;
    edge_next_buf[idx] = edge_head_buf[src];
    edge_head_buf[src] = @as(i32, @intCast(idx));
    edge_count += 1;
}

fn hasCallCycle(defined_func_count: u32) bool {
    var i: usize = 0;
    while (i < defined_func_count) : (i += 1) {
        dfs_state_buf[i] = 0;
    }

    i = 0;
    while (i < defined_func_count) : (i += 1) {
        if (dfs_state_buf[i] != 0) continue;

        var stack_len: usize = 1;
        dfs_stack_buf[0] = @intCast(i);
        dfs_edge_buf[0] = edge_head_buf[i];
        dfs_state_buf[i] = 1;

        while (stack_len > 0) {
            const top = stack_len - 1;
            const e = dfs_edge_buf[top];
            if (e == -1) {
                const done: usize = @intCast(dfs_stack_buf[top]);
                dfs_state_buf[done] = 2;
                stack_len -= 1;
                continue;
            }

            const ei: usize = @intCast(e);
            dfs_edge_buf[top] = edge_next_buf[ei];
            const to = edge_to_buf[ei];
            if (to >= defined_func_count) continue;

            const to_usize: usize = @intCast(to);
            if (dfs_state_buf[to_usize] == 1) return true;
            if (dfs_state_buf[to_usize] == 0) {
                dfs_stack_buf[stack_len] = to;
                dfs_edge_buf[stack_len] = edge_head_buf[to_usize];
                dfs_state_buf[to_usize] = 1;
                stack_len += 1;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Per-instruction policy: banned opcodes and call-edge collection.
// ---------------------------------------------------------------------------

const ProfileHandler = struct {
    func_idx: u32,
    defined_func_count: u32,

    pub fn onInstr(self: *ProfileHandler, instr: Instr) CheckError!void {
        switch (instr.op) {
            0x40 => return CheckError.MemoryGrowNotAllowed,
            0xfe => return CheckError.AtomicsNotAllowed,
            0x11, 0x13, 0x14 => return CheckError.IndirectCallNotAllowed,
            0x10, 0x12 => {
                const callee: u32 = @intCast(instr.imm);
                if (callee < self.defined_func_count) {
                    try addEdge(self.func_idx, callee);
                }
            },
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *ProfileHandler, depth: u32) CheckError!void {
        _ = self;
        _ = depth;
    }
};

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

fn parseTypeSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > MAX_TYPES) return CheckError.TooManyTypes;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const form = try r.readByte();
        if (form != 0x60) return CheckError.InvalidWasm;
        const params = try r.readVarU32();
        _ = try r.readN(params);
        const results = try r.readVarU32();
        var result_type: u8 = 0;
        if (results > 0) {
            result_type = try r.readByte();
            if (results > 1) _ = try r.readN(results - 1);
        }
        type_buf[i] = .{
            .param_count = params,
            .result_count = results,
            .result_type = result_type,
        };
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return n;
}

fn parseImportSection(payload: []const u8) CheckError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > 0) return CheckError.ImportNotAllowed;
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseFunctionSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        func_type_buf[i] = try r.readVarU32();
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return n;
}

fn readInitExpr(r: *Reader, prior_global_count: u32) CheckError!StaticGlobal {
    const op = try r.readByte();
    var result = StaticGlobal{};
    switch (op) {
        0x41 => {
            const value = try r.readVarS32();
            result = .{ .is_static_i32 = true, .value = @bitCast(value) };
        },
        0x42 => _ = try r.readVarS64(10),
        0x43 => _ = try r.readN(4),
        0x44 => _ = try r.readN(8),
        0x23 => {
            const idx = try r.readVarU32();
            if (idx < prior_global_count and global_buf[idx].is_static_i32) {
                result = global_buf[idx];
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
    const n = try r.readVarU32();
    if (n > MAX_GLOBALS) return CheckError.TooManyGlobals;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const value_type = try r.readByte();
        const mutable = try r.readByte();
        const init = try readInitExpr(&r, i);
        global_buf[i] = if (value_type == 0x7f and mutable == 0) init else .{};
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return n;
}

fn metadataSlot(metadata: *ContentTypeMetadata, name: []const u8) ?*MetadataExport {
    if (std.mem.eql(u8, name, "input_content_type_ptr")) return &metadata.input_ptr;
    if (std.mem.eql(u8, name, "input_content_type_size")) return &metadata.input_size;
    if (std.mem.eql(u8, name, "output_content_type_ptr")) return &metadata.output_ptr;
    if (std.mem.eql(u8, name, "output_content_type_size")) return &metadata.output_size;
    return null;
}

fn bufferSlot(metadata: *BufferMetadata, name: []const u8) ?*MetadataExport {
    if (std.mem.eql(u8, name, "input_ptr")) return &metadata.input_ptr;
    if (std.mem.eql(u8, name, "input_utf8_cap")) return &metadata.input_utf8_cap;
    if (std.mem.eql(u8, name, "input_bytes_cap")) return &metadata.input_bytes_cap;
    if (std.mem.eql(u8, name, "output_utf8_cap")) return &metadata.output_utf8_cap;
    if (std.mem.eql(u8, name, "output_bytes_cap")) return &metadata.output_bytes_cap;
    return null;
}

fn parseExportSection(
    payload: []const u8,
    content_type_metadata: *ContentTypeMetadata,
    buffer_metadata: *BufferMetadata,
) CheckError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const name_len = try r.readVarU32();
        const name = try r.readN(name_len);
        const kind = try r.readByte();
        const index = try r.readVarU32();
        if (metadataSlot(content_type_metadata, name)) |slot| {
            slot.* = switch (kind) {
                0x00 => .{ .function = index },
                else => .invalid,
            };
        }
        if (bufferSlot(buffer_metadata, name)) |slot| {
            slot.* = switch (kind) {
                0x00 => .{ .function = index },
                else => .invalid,
            };
        }
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseMemorySection(payload: []const u8) CheckError!?u64 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > 1) return CheckError.TooManyMemories;
    var min_bytes: ?u64 = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const limits = try wasm_reader.readLimits(&r);
        if (limits.memory64) return CheckError.Memory64NotAllowed;
        if (limits.shared) return CheckError.SharedMemoryNotAllowed;
        if (!limits.has_max) return CheckError.MemoryMaxRequired;
        min_bytes = limits.min * 65536;
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return min_bytes;
}

fn readStaticOffset(r: *Reader, global_count: u32) CheckError!?u32 {
    const op = try r.readByte();
    var result: ?u32 = null;
    switch (op) {
        0x41 => result = @bitCast(try r.readVarS32()),
        0x23 => {
            const idx = try r.readVarU32();
            if (idx < global_count and global_buf[idx].is_static_i32) {
                result = global_buf[idx].value;
            }
        },
        else => return CheckError.InvalidWasm,
    }
    if (try r.readByte() != 0x0b) return CheckError.InvalidWasm;
    return result;
}

fn parseDataSection(payload: []const u8, global_count: u32) CheckError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    data_range_count = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const flags = try r.readVarU32();
        var active = false;
        var offset: ?u32 = null;
        switch (flags) {
            0 => {
                active = true;
                offset = try readStaticOffset(&r, global_count);
            },
            1 => {},
            2 => {
                active = (try r.readVarU32()) == 0;
                offset = try readStaticOffset(&r, global_count);
            },
            else => return CheckError.InvalidWasm,
        }
        const size = try r.readVarU32();
        _ = try r.readN(size);
        if (active and offset != null) {
            if (data_range_count >= MAX_DATA_SEGMENTS) return CheckError.TooManyDataSegments;
            const start: u64 = offset.?;
            data_range_buf[data_range_count] = .{ .start = start, .end = start + size };
            data_range_count += 1;
        }
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn resolveGetterBody(body: []const u8, global_count: u32) CheckError!u32 {
    var r = Reader.init(body);
    if (try r.readVarU32() != 0) return CheckError.ContentTypeGetterNotStatic;
    const op = try r.readByte();
    const value: u32 = switch (op) {
        0x41 => @bitCast(try r.readVarS32()),
        0x23 => blk: {
            const idx = try r.readVarU32();
            if (idx >= global_count or !global_buf[idx].is_static_i32) {
                return CheckError.ContentTypeGlobalNotStatic;
            }
            break :blk global_buf[idx].value;
        },
        else => return CheckError.ContentTypeGetterNotStatic,
    };
    if (try r.readByte() != 0x0b or r.remaining() != 0) {
        return CheckError.ContentTypeGetterNotStatic;
    }
    return value;
}

fn resolveMetadataExport(
    target: MetadataExport,
    function_bodies: []const []const u8,
    type_count: u32,
    global_count: u32,
) CheckError!u32 {
    return switch (target) {
        .missing => CheckError.ContentTypePairRequired,
        .invalid => CheckError.ContentTypeExportInvalid,
        .function => |idx| blk: {
            if (idx >= function_bodies.len) return CheckError.ContentTypeExportInvalid;
            const type_idx = func_type_buf[idx];
            if (type_idx >= type_count) return CheckError.ContentTypeSignatureInvalid;
            const func_type = type_buf[type_idx];
            if (func_type.param_count != 0 or func_type.result_count != 1 or func_type.result_type != 0x7f) {
                return CheckError.ContentTypeSignatureInvalid;
            }
            break :blk try resolveGetterBody(function_bodies[idx], global_count);
        },
    };
}

fn validateContentTypeRegion(ptr: u32, size: u32, memory_min_bytes: u64) CheckError!void {
    const start: u64 = ptr;
    const end = start + size;
    if (end > memory_min_bytes) return CheckError.ContentTypeOutOfBounds;

    var found = false;
    var i: usize = 0;
    while (i < data_range_count) : (i += 1) {
        const range = data_range_buf[i];
        if (range.end <= start or range.start >= end) continue;
        if (found or range.start > start or range.end < end) {
            return CheckError.ContentTypeNotPreinitialized;
        }
        found = true;
    }
    if (!found) return CheckError.ContentTypeNotPreinitialized;
}

fn validateContentTypePair(
    ptr_export: MetadataExport,
    size_export: MetadataExport,
    function_bodies: []const []const u8,
    type_count: u32,
    global_count: u32,
    memory_min_bytes: u64,
) CheckError!void {
    if (ptr_export == .missing and size_export == .missing) return;
    if (ptr_export == .missing or size_export == .missing) return CheckError.ContentTypePairRequired;
    const ptr = try resolveMetadataExport(ptr_export, function_bodies, type_count, global_count);
    const size = try resolveMetadataExport(size_export, function_bodies, type_count, global_count);
    try validateContentTypeRegion(ptr, size, memory_min_bytes);
}

fn resolveBufferGetterBody(body: []const u8, global_count: u32) CheckError!u32 {
    var r = Reader.init(body);
    if (try r.readVarU32() != 0) return CheckError.BufferGetterNotStatic;
    const op = try r.readByte();
    const value: u32 = switch (op) {
        0x41 => @bitCast(try r.readVarS32()),
        0x23 => blk: {
            const idx = try r.readVarU32();
            if (idx >= global_count or !global_buf[idx].is_static_i32) {
                return CheckError.BufferGlobalNotStatic;
            }
            break :blk global_buf[idx].value;
        },
        else => return CheckError.BufferGetterNotStatic,
    };
    if (try r.readByte() != 0x0b or r.remaining() != 0) {
        return CheckError.BufferGetterNotStatic;
    }
    return value;
}

fn resolveBufferExport(
    target: MetadataExport,
    function_bodies: []const []const u8,
    type_count: u32,
    global_count: u32,
) CheckError!u32 {
    return switch (target) {
        .missing => CheckError.BufferExportRequired,
        .invalid => CheckError.BufferExportInvalid,
        .function => |idx| blk: {
            if (idx >= function_bodies.len) return CheckError.BufferExportInvalid;
            const type_idx = func_type_buf[idx];
            if (type_idx >= type_count) return CheckError.BufferSignatureInvalid;
            const func_type = type_buf[type_idx];
            if (func_type.param_count != 0 or func_type.result_count != 1 or func_type.result_type != 0x7f) {
                return CheckError.BufferSignatureInvalid;
            }
            break :blk try resolveBufferGetterBody(function_bodies[idx], global_count);
        },
    };
}

fn selectCapacity(
    utf8: MetadataExport,
    bytes: MetadataExport,
    function_bodies: []const []const u8,
    type_count: u32,
    global_count: u32,
) CheckError!u32 {
    if (utf8 != .missing and bytes != .missing) return CheckError.BufferCapacityAmbiguous;
    const selected = if (utf8 != .missing) utf8 else bytes;
    return resolveBufferExport(selected, function_bodies, type_count, global_count);
}

fn validateBufferMetadata(
    metadata: BufferMetadata,
    function_bodies: []const []const u8,
    type_count: u32,
    global_count: u32,
    memory_min_bytes: u64,
) CheckError!void {
    const any_present =
        metadata.input_ptr != .missing or
        metadata.input_utf8_cap != .missing or
        metadata.input_bytes_cap != .missing or
        metadata.output_utf8_cap != .missing or
        metadata.output_bytes_cap != .missing;
    if (!any_present) return;

    const static_input_ptr = try resolveBufferExport(
        metadata.input_ptr,
        function_bodies,
        type_count,
        global_count,
    );
    const input_cap = try selectCapacity(
        metadata.input_utf8_cap,
        metadata.input_bytes_cap,
        function_bodies,
        type_count,
        global_count,
    );
    const output_cap = try selectCapacity(
        metadata.output_utf8_cap,
        metadata.output_bytes_cap,
        function_bodies,
        type_count,
        global_count,
    );

    const input_start: u64 = static_input_ptr;
    const input_end = input_start + input_cap;
    if (input_end > memory_min_bytes or output_cap > memory_min_bytes) {
        return CheckError.BufferOutOfBounds;
    }
    var i: usize = 0;
    while (i < data_range_count) : (i += 1) {
        const range = data_range_buf[i];
        if (range.start < input_end and range.end > input_start) {
            return CheckError.InputDataOverlap;
        }
    }
}

fn parseCodeSection(payload: []const u8, defined_func_count: u32, function_bodies: *[MAX_DEFINED_FUNCS][]const u8) CheckError!void {
    if (defined_func_count > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;
    initEdgeGraph(defined_func_count);

    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n != defined_func_count) return CheckError.FunctionCodeMismatch;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const body_size = try r.readVarU32();
        const body = try r.readN(body_size);
        function_bodies[i] = body;
        var handler = ProfileHandler{ .func_idx = i, .defined_func_count = defined_func_count };
        try wasm_reader.walkFunctionBody(&handler, body);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn checkModule(wasm: []const u8) CheckError!void {
    try wasm_reader.checkHeader(wasm);

    var r = Reader.init(wasm[8..]);
    var defined_func_count: u32 = 0;
    var type_count: u32 = 0;
    var global_count: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;
    var have_memory = false;
    var memory_min_bytes: u64 = 0;
    var metadata = ContentTypeMetadata{};
    var buffer_metadata = BufferMetadata{};
    data_range_count = 0;

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
            5 => {
                const min_bytes = try parseMemorySection(payload);
                if (min_bytes != null and have_memory) return CheckError.TooManyMemories;
                if (min_bytes) |value| {
                    have_memory = true;
                    memory_min_bytes = value;
                }
            },
            6 => global_count = try parseGlobalSection(payload),
            7 => try parseExportSection(payload, &metadata, &buffer_metadata),
            8 => return CheckError.StartFunctionNotAllowed,
            10 => {
                try parseCodeSection(payload, defined_func_count, &function_body_buf);
                have_code_section = true;
            },
            11 => try parseDataSection(payload, global_count),
            else => {},
        }
    }

    if (have_function_section and !have_code_section) return CheckError.InvalidWasm;
    if (hasCallCycle(defined_func_count)) return CheckError.RecursionNotAllowed;
    try validateBufferMetadata(
        buffer_metadata,
        function_body_buf[0..defined_func_count],
        type_count,
        global_count,
        memory_min_bytes,
    );
    try validateContentTypePair(metadata.input_ptr, metadata.input_size, function_body_buf[0..defined_func_count], type_count, global_count, memory_min_bytes);
    try validateContentTypePair(metadata.output_ptr, metadata.output_size, function_body_buf[0..defined_func_count], type_count, global_count, memory_min_bytes);
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
// Tests. wat2wasm fixture bytes note their source text.
// ---------------------------------------------------------------------------

const moduleWithBody = wasm_reader.moduleWithBody;
const hexBytes = wasm_reader.hexBytes;

const ok_module = moduleWithBody(&[_]u8{0x0b});

const atomics_module = moduleWithBody(&[_]u8{ 0xfe, 0x10, 0x00, 0x00, 0x0b });

// Loop bounds are the other component's job: a bare backedge is fine here.
const unbounded_loop_module = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x0c, 0x00, // br 0
    0x0b, 0x0b,
});

const no_memory_max_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01,
};

const two_memory_sections_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x04, 0x01, 0x01, 0x01, 0x01, 0x05, 0x04,
    0x01, 0x01, 0x01, 0x01,
};

const two_memories_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x07, 0x02, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01,
};

const shared_memory_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x04, 0x01, 0x03, 0x01, 0x01,
};

const memory64_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x04, 0x01, 0x05, 0x01, 0x01,
};

const start_function_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
    0x08, 0x01, 0x00, 0x0a, 0x04, 0x01, 0x02, 0x00,
    0x0b,
};

const recursion_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x03,
    0x02, 0x00, 0x00, 0x05, 0x04, 0x01, 0x01, 0x01,
    0x01, 0x0a, 0x0b, 0x02, 0x04, 0x00, 0x10, 0x01,
    0x0b, 0x04, 0x00, 0x10, 0x00, 0x0b,
};

const memory_grow_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01, 0x01,
    0x01, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x00,
    0x40, 0x00, 0x0b,
};

// (func (param i32) (result i32) (i32.trunc_sat_f32_s (f32.const 1.5)))
const trunc_sat_module = hexBytes(
    "0061736d0100000001060160017f017f03020100050401010101071302066d65" ++
        "6d6f727902000672656e64657200000a0b010900430000c03ffc000b",
);

// (func (export "render") (param i32) (result i32)
//   (memory.copy ...) (memory.fill ...) (i32.const 0))
const bulk_memory_module = hexBytes(
    "0061736d0100000001060160017f017f03020100050401010101071302066d65" ++
        "6d6f727902000672656e64657200000a19011700410041104108fc0a00004100" ++
        "41004108fc0b0041000b",
);

// (func (param i32) (result i32) (i32.extend8_s (local.get 0)))
const sign_extension_module = hexBytes(
    "0061736d0100000001060160017f017f030201000504010101010a0701050020" ++
        "00c00b",
);

// (func (param i32) (result i32) (local v128)
//   v128.const, v128.load8_lane, i8x16.shuffle, v128.store, i8x16.extract_lane_s
const simd_lane_module = hexBytes(
    "0061736d0100000001060160017f017f030201000504010101010a4601440101" ++
        "7b2000fd0c00000000000000000000000000000000fd54000003210120012001" ++
        "fd0d000102030405060708090a0b0c0d0e0f210141102001fd0b04002001fd15" ++
        "020b",
);

// (table 1 1 funcref) (elem (i32.const 0) $f) (func (call_indirect ...))
const call_indirect_module = hexBytes(
    "0061736d01000000010401600000030302000004050170010101050401010101" ++
        "0907010041000b01000a0c0202000b070041001100000b",
);

const return_call_indirect_module = moduleWithBody(&[_]u8{ 0x13, 0x00, 0x00, 0x0b });
const call_ref_module = moduleWithBody(&[_]u8{ 0x14, 0x00, 0x0b });
const recursive_return_call_module = moduleWithBody(&[_]u8{ 0x12, 0x00, 0x0b });

// (import "env" "log" (func (param i32)))
const import_module = hexBytes(
    "0061736d0100000001080260017f00600000020b0103656e76036c6f67000003" ++
        "0201010504010101010a08010600410110000b",
);

// Static input_ptr via immutable global, static capacities, disjoint data.
const static_buffers_module = hexBytes(
    "0061736d010000000105016000017f0304030000000504010102020608017f00" ++
        "418080040b07320309696e7075745f70747200000f696e7075745f6279746573" ++
        "5f6361700001106f75747075745f62797465735f63617000020a120304002300" ++
        "0b05004180080b05004180100b0b07010041000b0178",
);

// The active data byte overlaps [input_ptr, input_ptr + input_bytes_cap).
const overlapping_input_data_module = hexBytes(
    "0061736d010000000105016000017f0304030000000504010102020732030969" ++
        "6e7075745f70747200000f696e7075745f62797465735f6361700001106f7574" ++
        "7075745f62797465735f63617000020a14030600418080040b05004180080b05" ++
        "004180100b0b090100418080040b0178",
);

// input_ptr reads a mutable global rather than a static constant.
const dynamic_input_ptr_module = hexBytes(
    "0061736d010000000105016000017f0304030000000504010102020608017f01" ++
        "418080040b07320309696e7075745f70747200000f696e7075745f6279746573" ++
        "5f6361700001106f75747075745f62797465735f63617000020a120304002300" ++
        "0b05004180080b05004180100b",
);

test "accepts a module with fixed memory and no calls" {
    try checkModule(&ok_module);
}

test "render rejects a policy failure and the instance recovers" {
    @memcpy(input_buf[0..atomics_module.len], &atomics_module);
    const rejected = renderOutcome(atomics_module.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);

    @memcpy(input_buf[0..ok_module.len], &ok_module);
    const accepted = renderOutcome(ok_module.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, ok_module.len), accepted.output_size_or_failure);
    try std.testing.expectEqualSlices(u8, &ok_module, input_buf[0..ok_module.len]);
}

test "accepts static Content buffer metadata with disjoint active data" {
    try checkModule(&static_buffers_module);
}

test "rejects active data overlapping the complete input buffer" {
    try std.testing.expectError(
        CheckError.InputDataOverlap,
        checkModule(&overlapping_input_data_module),
    );
}

test "rejects a state-dependent input pointer" {
    try std.testing.expectError(
        CheckError.BufferGlobalNotStatic,
        checkModule(&dynamic_input_ptr_module),
    );
}

test "accepts an unbounded loop: loop bounds are wasm-bounded-loops' job" {
    try checkModule(&unbounded_loop_module);
}

test "accepts saturating truncation" {
    try checkModule(&trunc_sat_module);
}

test "accepts bulk memory copy and fill" {
    try checkModule(&bulk_memory_module);
}

test "accepts sign-extension operators" {
    try checkModule(&sign_extension_module);
}

test "accepts SIMD lane and shuffle immediates" {
    try checkModule(&simd_lane_module);
}

test "rejects call_indirect" {
    try std.testing.expectError(CheckError.IndirectCallNotAllowed, checkModule(&call_indirect_module));
}

test "rejects return_call_indirect" {
    try std.testing.expectError(CheckError.IndirectCallNotAllowed, checkModule(&return_call_indirect_module));
}

test "rejects call_ref" {
    try std.testing.expectError(CheckError.IndirectCallNotAllowed, checkModule(&call_ref_module));
}

test "rejects imports" {
    try std.testing.expectError(CheckError.ImportNotAllowed, checkModule(&import_module));
}

test "rejects atomics" {
    try std.testing.expectError(CheckError.AtomicsNotAllowed, checkModule(&atomics_module));
}

test "requires memory max when memory is declared" {
    try std.testing.expectError(CheckError.MemoryMaxRequired, checkModule(&no_memory_max_module));
}

test "rejects more than one memory across memory sections" {
    try std.testing.expectError(CheckError.TooManyMemories, checkModule(&two_memory_sections_module));
}

test "rejects more than one memory in one memory section" {
    try std.testing.expectError(CheckError.TooManyMemories, checkModule(&two_memories_module));
}

test "rejects shared memory" {
    try std.testing.expectError(CheckError.SharedMemoryNotAllowed, checkModule(&shared_memory_module));
}

test "rejects memory64" {
    try std.testing.expectError(CheckError.Memory64NotAllowed, checkModule(&memory64_module));
}

test "rejects a start function" {
    try std.testing.expectError(CheckError.StartFunctionNotAllowed, checkModule(&start_function_module));
}

test "rejects direct recursion" {
    try std.testing.expectError(CheckError.RecursionNotAllowed, checkModule(&recursion_module));
}

test "rejects recursion through return_call" {
    try std.testing.expectError(CheckError.RecursionNotAllowed, checkModule(&recursive_return_call_module));
}

test "rejects memory.grow" {
    try std.testing.expectError(CheckError.MemoryGrowNotAllowed, checkModule(&memory_grow_module));
}
