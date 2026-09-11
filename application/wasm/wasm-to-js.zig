const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 2 * 1024 * 1024;
const MAX_EXPORTS: usize = 64;
const MAX_GLOBALS: usize = 256;
const MAX_FUNCS: usize = 8192;
const MAX_DATA_SEGMENTS: usize = 256;

const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/javascript";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
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

const ParseError = error{
    InvalidWasm,
    UnsupportedVersion,
    UnexpectedEOF,
    InvalidLEB,
    UnsupportedInitExpr,
    TooManyExports,
    TooManyGlobals,
    TooManyFunctions,
    TooManyDataSegments,
    MissingRender,
    MissingMemory,
    MissingInput,
    MissingOutput,
    UnreadableContentType,
    OutputTooLarge,
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

    fn readByte(self: *Reader) ParseError!u8 {
        if (self.off >= self.data.len) return ParseError.UnexpectedEOF;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }

    fn readN(self: *Reader, n: usize) ParseError![]const u8 {
        if (self.remaining() < n) return ParseError.UnexpectedEOF;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }

    fn skip(self: *Reader, n: usize) ParseError!void {
        _ = try self.readN(n);
    }

    fn readVarU32(self: *Reader) ParseError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return ParseError.InvalidLEB;
    }

    fn readVarS32(self: *Reader) ParseError!i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < 5) : (i += 1) {
            b = try self.readByte();
            result |= @as(i32, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == 4) return ParseError.InvalidLEB;
        }
        if (shift < 32 and (b & 0x40) != 0) {
            result |= ~@as(i32, 0) << shift;
        }
        return result;
    }

    fn readName(self: *Reader) ParseError![]const u8 {
        const n = try self.readVarU32();
        return self.readN(n);
    }
};

const ExportKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
};

const Export = struct {
    name: []const u8,
    kind: u8,
    index: u32,
};

const DataSegment = struct {
    offset: u32,
    bytes: []const u8,
};

const ModuleInfo = struct {
    imported_funcs: u32 = 0,
    imported_globals: u32 = 0,
    exports: [MAX_EXPORTS]Export = undefined,
    export_count: usize = 0,
    globals: [MAX_GLOBALS]?u32 = [_]?u32{null} ** MAX_GLOBALS,
    funcs: [MAX_FUNCS][]const u8 = undefined,
    func_count: usize = 0,
    data_segments: [MAX_DATA_SEGMENTS]DataSegment = undefined,
    data_count: usize = 0,
};

const Encoding = enum { utf8, bytes };

const ExportRef = struct {
    name: []const u8,
    kind: u8,
    index: u32,
};

const Contract = struct {
    input_encoding: Encoding,
    output_encoding: Encoding,
    input_cap_name: []const u8,
    output_cap_name: []const u8,
    input_type: ?[]const u8,
    output_type: ?[]const u8,
    input_ptr: ExportRef,
    input_cap: ExportRef,
    output_cap: ExportRef,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseConstI32Expr(r: *Reader) ParseError!u32 {
    const op = try r.readByte();
    if (op != 0x41) return ParseError.UnsupportedInitExpr;
    const value = try r.readVarS32();
    if (try r.readByte() != 0x0b) return ParseError.UnsupportedInitExpr;
    return @bitCast(value);
}

fn skipLimits(r: *Reader) ParseError!void {
    const flags = try r.readVarU32();
    _ = try r.readVarU32();
    if ((flags & 0x01) != 0) _ = try r.readVarU32();
    if ((flags & 0x02) != 0) return ParseError.UnsupportedInitExpr;
}

fn skipTableType(r: *Reader) ParseError!void {
    _ = try r.readByte();
    try skipLimits(r);
}

fn skipGlobalType(r: *Reader) ParseError!void {
    _ = try r.readByte();
    _ = try r.readByte();
}

fn parseImportSection(info: *ModuleInfo, payload: []const u8) ParseError!void {
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
                info.imported_funcs += 1;
            },
            0x01 => try skipTableType(&r),
            0x02 => try skipLimits(&r),
            0x03 => {
                try skipGlobalType(&r);
                info.imported_globals += 1;
            },
            else => return ParseError.InvalidWasm,
        }
    }
}

fn parseGlobalSection(info: *ModuleInfo, payload: []const u8) ParseError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const global_index = info.imported_globals + i;
        if (global_index >= MAX_GLOBALS) return ParseError.TooManyGlobals;
        try skipGlobalType(&r);
        info.globals[@intCast(global_index)] = parseConstI32Expr(&r) catch null;
    }
}

fn parseExportSection(info: *ModuleInfo, payload: []const u8) ParseError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (info.export_count >= MAX_EXPORTS) return ParseError.TooManyExports;
        const name = try r.readName();
        const kind = try r.readByte();
        const index = try r.readVarU32();
        info.exports[info.export_count] = .{ .name = name, .kind = kind, .index = index };
        info.export_count += 1;
    }
}

fn parseCodeSection(info: *ModuleInfo, payload: []const u8) ParseError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_FUNCS) return ParseError.TooManyFunctions;
    info.func_count = @intCast(count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const body_size = try r.readVarU32();
        info.funcs[i] = try r.readN(body_size);
    }
}

fn parseDataSection(info: *ModuleInfo, payload: []const u8) ParseError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try r.readVarU32();
        if (flags == 1) {
            const size = try r.readVarU32();
            try r.skip(size);
            continue;
        }

        if (info.data_count >= MAX_DATA_SEGMENTS) return ParseError.TooManyDataSegments;
        if (flags == 2) _ = try r.readVarU32();
        if (flags != 0 and flags != 2) return ParseError.UnsupportedInitExpr;

        const offset = try parseConstI32Expr(&r);
        const size = try r.readVarU32();
        const bytes = try r.readN(size);
        info.data_segments[info.data_count] = .{ .offset = offset, .bytes = bytes };
        info.data_count += 1;
    }
}

fn parseWasm(wasm: []const u8) ParseError!ModuleInfo {
    if (wasm.len < 8) return ParseError.InvalidWasm;
    if (!eql(wasm[0..4], "\x00asm")) return ParseError.InvalidWasm;
    if (!eql(wasm[4..8], "\x01\x00\x00\x00")) return ParseError.UnsupportedVersion;

    var info = ModuleInfo{};
    var r = Reader.init(wasm[8..]);
    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);
        switch (section_id) {
            2 => try parseImportSection(&info, payload),
            6 => try parseGlobalSection(&info, payload),
            7 => try parseExportSection(&info, payload),
            10 => try parseCodeSection(&info, payload),
            11 => try parseDataSection(&info, payload),
            else => {},
        }
    }
    return info;
}

fn findExport(info: *const ModuleInfo, name: []const u8) ?ExportRef {
    var i: usize = 0;
    while (i < info.export_count) : (i += 1) {
        const exp = info.exports[i];
        if (eql(exp.name, name)) {
            return .{ .name = name, .kind = exp.kind, .index = exp.index };
        }
    }
    return null;
}

fn evalConstGetter(info: *const ModuleInfo, name: []const u8) ?u32 {
    const exp = findExport(info, name) orelse return null;
    if (exp.kind != @intFromEnum(ExportKind.func)) return null;
    if (exp.index < info.imported_funcs) return null;
    const def_index = exp.index - info.imported_funcs;
    if (def_index >= info.func_count) return null;

    var r = Reader.init(info.funcs[@intCast(def_index)]);
    const local_groups = r.readVarU32() catch return null;
    var i: u32 = 0;
    while (i < local_groups) : (i += 1) {
        _ = r.readVarU32() catch return null;
        _ = r.readByte() catch return null;
    }
    const value = parseConstI32Expr(&r) catch return null;
    if (r.remaining() != 0) return null;
    return value;
}

fn readDataAt(info: *const ModuleInfo, ptr: u32, size: u32) ?[]const u8 {
    var i: usize = 0;
    while (i < info.data_count) : (i += 1) {
        const seg = info.data_segments[i];
        const start = seg.offset;
        const end = start +% @as(u32, @intCast(seg.bytes.len));
        if (ptr >= start and ptr <= end and size <= end - ptr) {
            const off: usize = @intCast(ptr - start);
            return seg.bytes[off .. off + @as(usize, @intCast(size))];
        }
    }
    return null;
}

fn detectContentType(info: *const ModuleInfo, ptr_name: []const u8, size_name: []const u8) ParseError!?[]const u8 {
    const has_ptr = findExport(info, ptr_name) != null;
    const has_size = findExport(info, size_name) != null;
    if (!has_ptr and !has_size) return null;
    if (!has_ptr or !has_size) return ParseError.UnreadableContentType;

    const ptr = evalConstGetter(info, ptr_name) orelse return ParseError.UnreadableContentType;
    const size = evalConstGetter(info, size_name) orelse return ParseError.UnreadableContentType;
    if (size == 0 or size > 128) return null;
    return readDataAt(info, ptr, size) orelse return ParseError.UnreadableContentType;
}

fn analyzeContract(info: *const ModuleInfo) ParseError!Contract {
    if (findExport(info, "memory") == null) return ParseError.MissingMemory;
    if (findExport(info, "render") == null) return ParseError.MissingRender;

    const input_ptr_exp = findExport(info, "input_ptr") orelse return ParseError.MissingInput;
    if (input_ptr_exp.kind != @intFromEnum(ExportKind.func)) return ParseError.MissingInput;
    const input_utf8 = findExport(info, "input_utf8_cap");
    const input_bytes = findExport(info, "input_bytes_cap");
    const output_utf8 = findExport(info, "output_utf8_cap");
    const output_bytes = findExport(info, "output_bytes_cap");

    const input_encoding: Encoding = if (input_utf8 != null) .utf8 else if (input_bytes != null) .bytes else return ParseError.MissingInput;
    const output_encoding: Encoding = if (output_utf8 != null) .utf8 else if (output_bytes != null) .bytes else return ParseError.MissingOutput;
    const input_cap_exp = if (input_encoding == .utf8) input_utf8.? else input_bytes.?;
    const output_cap_exp = if (output_encoding == .utf8) output_utf8.? else output_bytes.?;
    if (input_cap_exp.kind != @intFromEnum(ExportKind.func)) return ParseError.MissingInput;
    if (output_cap_exp.kind != @intFromEnum(ExportKind.func)) return ParseError.MissingOutput;

    return .{
        .input_encoding = input_encoding,
        .output_encoding = output_encoding,
        .input_cap_name = if (input_encoding == .utf8) "input_utf8_cap" else "input_bytes_cap",
        .output_cap_name = if (output_encoding == .utf8) "output_utf8_cap" else "output_bytes_cap",
        .input_type = try detectContentType(info, "input_content_type_ptr", "input_content_type_size"),
        .output_type = try detectContentType(info, "output_content_type_ptr", "output_content_type_size"),
        .input_ptr = input_ptr_exp,
        .input_cap = input_cap_exp,
        .output_cap = output_cap_exp,
    };
}

fn base64Len(n: usize) usize {
    return ((n + 2) / 3) * 4;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn appendBase64(out_pos: *usize, bytes: []const u8) ParseError!void {
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const b1 = bytes[i];
        const b2 = bytes[i + 1];
        const b3 = bytes[i + 2];
        output_buf[out_pos.*] = B64[b1 >> 2];
        output_buf[out_pos.* + 1] = B64[((b1 & 3) << 4) | (b2 >> 4)];
        output_buf[out_pos.* + 2] = B64[((b2 & 15) << 2) | (b3 >> 6)];
        output_buf[out_pos.* + 3] = B64[b3 & 63];
        out_pos.* += 4;
    }
    const rem = bytes.len - i;
    if (rem == 1) {
        const b1 = bytes[i];
        output_buf[out_pos.*] = B64[b1 >> 2];
        output_buf[out_pos.* + 1] = B64[(b1 & 3) << 4];
        output_buf[out_pos.* + 2] = '=';
        output_buf[out_pos.* + 3] = '=';
        out_pos.* += 4;
    } else if (rem == 2) {
        const b1 = bytes[i];
        const b2 = bytes[i + 1];
        output_buf[out_pos.*] = B64[b1 >> 2];
        output_buf[out_pos.* + 1] = B64[((b1 & 3) << 4) | (b2 >> 4)];
        output_buf[out_pos.* + 2] = B64[(b2 & 15) << 2];
        output_buf[out_pos.* + 3] = '=';
        out_pos.* += 4;
    }
}

fn append(out_pos: *usize, bytes: []const u8) ParseError!void {
    if (out_pos.* + bytes.len > output_buf.len) return ParseError.OutputTooLarge;
    @memcpy(output_buf[out_pos.* .. out_pos.* + bytes.len], bytes);
    out_pos.* += bytes.len;
}

fn appendFmt(out_pos: *usize, comptime fmt: []const u8, args: anytype) ParseError!void {
    const written = std.fmt.bufPrint(output_buf[out_pos.*..], fmt, args) catch return ParseError.OutputTooLarge;
    out_pos.* += written.len;
}

fn appendJsString(out_pos: *usize, bytes: []const u8) ParseError!void {
    try append(out_pos, "\"");
    for (bytes) |b| {
        switch (b) {
            '\\' => try append(out_pos, "\\\\"),
            '"' => try append(out_pos, "\\\""),
            '\n' => try append(out_pos, "\\n"),
            '\r' => try append(out_pos, "\\r"),
            '\t' => try append(out_pos, "\\t"),
            else => {
                if (b >= 0x20 and b <= 0x7e) {
                    const one = [_]u8{b};
                    try append(out_pos, &one);
                } else {
                    try appendFmt(out_pos, "\\x{x:0>2}", .{b});
                }
            },
        }
    }
    try append(out_pos, "\"");
}

fn appendContractObject(out_pos: *usize, encoding: Encoding, content_type: ?[]const u8) ParseError!void {
    try append(out_pos, "Object.freeze({ encoding: ");
    try appendJsString(out_pos, if (encoding == .utf8) "utf-8" else "bytes");
    if (content_type) |ct| {
        try append(out_pos, ", contentType: ");
        try appendJsString(out_pos, ct);
    }
    try append(out_pos, " })");
}

fn accessor(out_pos: *usize, exp: ExportRef) ParseError!void {
    try append(out_pos, "e.");
    try append(out_pos, exp.name);
    if (exp.kind == @intFromEnum(ExportKind.func)) {
        try append(out_pos, "()");
    } else {
        try append(out_pos, ".value");
    }
}

fn appendGeneratedJs(out_pos: *usize, wasm: []const u8, contract: Contract) ParseError!void {
    if (base64Len(wasm.len) + 4096 > OUTPUT_CAP) return ParseError.OutputTooLarge;

    try append(out_pos, "const wasmBytes = Uint8Array.from(atob(\"");
    try appendBase64(out_pos, wasm);
    try append(out_pos, "\"), c => c.charCodeAt(0));\n");
    if (contract.input_encoding == .utf8) {
        try append(out_pos, "const textEncoder = new TextEncoder();\n");
    }
    if (contract.output_encoding == .utf8) {
        try append(out_pos, "const textDecoder = new TextDecoder(\"utf-8\", { fatal: true });\n");
    }
    try append(out_pos, "const wasmModule = await WebAssembly.compile(wasmBytes);\n");
    try append(out_pos, "export const input = ");
    try appendContractObject(out_pos, contract.input_encoding, contract.input_type);
    try append(out_pos, ";\nexport const output = ");
    try appendContractObject(out_pos, contract.output_encoding, contract.output_type);
    try append(out_pos, ";\n\n");

    try append(out_pos,
        \\function i32(value, label) {
        \\  const n = typeof value === "bigint" ? Number(value) : value;
        \\  if (typeof n !== "number" || !Number.isFinite(n)) throw new Error(label + " returned non-finite numeric value");
        \\  return n | 0;
        \\}
        \\
        \\function assertMemory(memory) {
        \\  if (!(memory instanceof WebAssembly.Memory)) throw new Error("component export memory must be WebAssembly.Memory");
        \\}
        \\
        \\function checkSlice(memory, ptr, len, label) {
        \\  if (ptr < 0 || len < 0) throw new Error(label + " returned negative pointer/size");
        \\  const start = ptr >>> 0;
        \\  const end = start + (len >>> 0);
        \\  if (end < start || end > memory.buffer.byteLength) throw new Error(label + " exceeds wasm memory bounds");
        \\  return start;
        \\}
        \\
        \\export function render(value) {
        \\  const instance = new WebAssembly.Instance(wasmModule, {});
        \\  const e = instance.exports;
        \\  assertMemory(e.memory);
        \\
    );

    if (contract.input_encoding == .utf8) {
        try append(out_pos,
            \\  if (typeof value !== "string") throw new Error("input must be a string");
            \\  const inputBytes = textEncoder.encode(value);
            \\
        );
    } else {
        try append(out_pos,
            \\  if (!(value instanceof Uint8Array)) throw new Error("input must be Uint8Array");
            \\  const inputBytes = value;
            \\
        );
    }

    try append(out_pos, "  const inputPtr = i32(");
    try accessor(out_pos, contract.input_ptr);
    try append(out_pos, ", \"input_ptr\");\n  const inputCap = i32(");
    try accessor(out_pos, contract.input_cap);
    try appendFmt(out_pos,
        \\, "{s}");
        \\  if (inputBytes.length > inputCap) throw new Error("input exceeds component capacity: " + inputBytes.length + " > " + inputCap);
        \\  new Uint8Array(e.memory.buffer).set(inputBytes, checkSlice(e.memory, inputPtr, inputBytes.length, "input_ptr"));
        \\  const renderValue = e.render(inputBytes.length);
        \\  if (typeof renderValue !== "bigint") throw new Error("render must return i64");
        \\  const renderResult = BigInt.asUintN(64, renderValue);
        \\  const outputLen = Number(renderResult & 0xffff_ffffn);
        \\  if (renderResult >> 63n) {{
        \\    if (typeof e.failure_modes_per_input_offset !== "function") throw new Error("component returned failure without failure_modes_per_input_offset");
        \\    const failureModes = i32(e.failure_modes_per_input_offset(), "failure_modes_per_input_offset") >>> 0;
        \\    const error = new Error("component rejected input");
        \\    error.failureDetail = outputLen;
        \\    error.failureModesPerInputOffset = failureModes;
        \\    if (failureModes > 0) {{
        \\      error.inputOffset = Math.floor(outputLen / failureModes);
        \\      error.failureMode = outputLen % failureModes;
        \\    }}
        \\    throw error;
        \\  }}
        \\  const outputPtr = Number((renderResult >> 32n) & 0x7fff_ffffn);
        \\
    , .{contract.input_cap_name});

    try append(out_pos, "  const outputCap = i32(");
    try accessor(out_pos, contract.output_cap);
    try appendFmt(out_pos,
        \\, "{s}");
        \\  if (outputLen > outputCap) throw new Error("render output exceeds component capacity: " + outputLen + " > " + outputCap);
        \\
    , .{contract.output_cap_name});
    try append(out_pos,
        \\  const outputStart = checkSlice(e.memory, outputPtr, outputLen, "render");
        \\  const outputBytes = new Uint8Array(e.memory.buffer).slice(outputStart, outputStart + outputLen);
        \\
    );

    if (contract.output_encoding == .utf8) {
        try append(out_pos, "  return textDecoder.decode(outputBytes);\n");
    } else {
        try append(out_pos, "  return outputBytes;\n");
    }

    try append(out_pos,
        \\}
        \\
        \\Object.defineProperties(render, {
        \\  input: { value: input, enumerable: true },
        \\  output: { value: output, enumerable: true },
        \\});
        \\
        \\export default render;
        \\
    );
}

fn renderImpl(input_size: u32) u32 {
    const size: usize = @min(@as(usize, @intCast(input_size)), INPUT_CAP);
    var out_pos: usize = 0;
    const info = parseWasm(input_buf[0..size]) catch @trap();
    const contract = analyzeContract(&info) catch @trap();
    appendGeneratedJs(&out_pos, input_buf[0..size], contract) catch @trap();
    return @intCast(out_pos);
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
