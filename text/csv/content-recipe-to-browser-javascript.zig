const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 512 * 1024;
const MAX_ROWS: usize = 128;
const MAX_ROW_BYTES: usize = 4096;

const INPUT_CONTENT_TYPE = "text/csv";
const OUTPUT_CONTENT_TYPE = "text/javascript";
const HEADER = "path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
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

const ConvertError = error{
    InvalidCSV,
    InvalidHeader,
    InvalidPath,
    InvalidEncoding,
    InvalidMIME,
    InvalidCapacity,
    EmptyRecipe,
    TooManyRows,
    RowTooLarge,
    DisconnectedRecipe,
    OutputOverflow,
};

const Encoding = enum {
    utf8,
    bytes,

    fn parse(value: []const u8) ConvertError!Encoding {
        if (std.mem.eql(u8, value, "utf8")) return .utf8;
        if (std.mem.eql(u8, value, "bytes")) return .bytes;
        return ConvertError.InvalidEncoding;
    }

    fn label(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "utf8",
            .bytes => "bytes",
        };
    }

    fn inputCapacityExport(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "input_utf8_cap",
            .bytes => "input_bytes_cap",
        };
    }
};

const Row = struct {
    path: []const u8,
    input_encoding: Encoding,
    input_mime: []const u8,
    input_capacity: u32,
    output_encoding: Encoding,
    output_mime: []const u8,
    output_capacity: u32,
};

const CSVReader = struct {
    input: []const u8,
    pos: usize = 0,

    fn nextRow(self: *CSVReader, storage: *[MAX_ROW_BYTES]u8, fields: *[7][]const u8) ConvertError!bool {
        if (self.pos == self.input.len) return false;

        var storage_pos: usize = 0;
        var field_index: usize = 0;
        while (field_index < fields.len) : (field_index += 1) {
            const field_start = storage_pos;
            if (self.pos >= self.input.len) return ConvertError.InvalidCSV;

            if (self.input[self.pos] == '"') {
                self.pos += 1;
                var closed = false;
                while (self.pos < self.input.len) {
                    const byte = self.input[self.pos];
                    if (byte == '\r' or byte == '\n') return ConvertError.InvalidCSV;
                    if (byte == '"') {
                        if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '"') {
                            try appendFieldByte(storage, &storage_pos, '"');
                            self.pos += 2;
                            continue;
                        }
                        self.pos += 1;
                        closed = true;
                        break;
                    }
                    try appendFieldByte(storage, &storage_pos, byte);
                    self.pos += 1;
                }
                if (!closed) return ConvertError.InvalidCSV;
            } else {
                while (self.pos < self.input.len) {
                    const byte = self.input[self.pos];
                    if (byte == ',' or byte == '\n') break;
                    if (byte == '\r' or byte == '"') return ConvertError.InvalidCSV;
                    try appendFieldByte(storage, &storage_pos, byte);
                    self.pos += 1;
                }
            }

            fields[field_index] = storage[field_start..storage_pos];
            const expected_delimiter: u8 = if (field_index + 1 == fields.len) '\n' else ',';
            if (self.pos >= self.input.len or self.input[self.pos] != expected_delimiter) {
                return ConvertError.InvalidCSV;
            }
            self.pos += 1;
        }
        return true;
    }
};

fn appendFieldByte(storage: *[MAX_ROW_BYTES]u8, pos: *usize, byte: u8) ConvertError!void {
    if (pos.* >= storage.len) return ConvertError.RowTooLarge;
    storage[pos.*] = byte;
    pos.* += 1;
}

const Output = struct {
    bytes: []u8,
    pos: usize = 0,

    fn append(self: *Output, value: []const u8) ConvertError!void {
        if (value.len > self.bytes.len - self.pos) return ConvertError.OutputOverflow;
        @memcpy(self.bytes[self.pos..][0..value.len], value);
        self.pos += value.len;
    }

    fn appendJSString(self: *Output, value: []const u8) ConvertError!void {
        try self.append("\"");
        for (value) |byte| {
            switch (byte) {
                '"' => try self.append("\\\""),
                '\\' => try self.append("\\\\"),
                else => try self.append(&.{byte}),
            }
        }
        try self.append("\"");
    }

    fn appendU32(self: *Output, value: u32) ConvertError!void {
        var buffer: [10]u8 = undefined;
        var start = buffer.len;
        var remaining = value;
        while (remaining >= 10) {
            start -= 1;
            buffer[start] = @intCast('0' + remaining % 10);
            remaining /= 10;
        }
        start -= 1;
        buffer[start] = @intCast('0' + remaining);
        try self.append(buffer[start..]);
    }
};

fn validPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn validMIME(value: []const u8) bool {
    var slash_count: usize = 0;
    var side_len: usize = 0;
    for (value) |byte| {
        if (byte == '/') {
            if (side_len == 0 or slash_count != 0) return false;
            slash_count += 1;
            side_len = 0;
            continue;
        }
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            std.mem.indexOfScalar(u8, "!#$&^_.+-", byte) != null;
        if (!valid) return false;
        side_len += 1;
    }
    return slash_count == 1 and side_len > 0;
}

fn parseCapacity(value: []const u8) ConvertError!u32 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return ConvertError.InvalidCapacity;
    var result: u32 = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return ConvertError.InvalidCapacity;
        const digit: u32 = byte - '0';
        if (result > (std.math.maxInt(u32) - digit) / 10) return ConvertError.InvalidCapacity;
        result = result * 10 + digit;
    }
    return result;
}

fn parseRow(fields: *const [7][]const u8) ConvertError!Row {
    if (!validPath(fields[0])) return ConvertError.InvalidPath;
    if (!validMIME(fields[2]) or !validMIME(fields[5])) return ConvertError.InvalidMIME;
    return .{
        .path = fields[0],
        .input_encoding = try Encoding.parse(fields[1]),
        .input_mime = fields[2],
        .input_capacity = try parseCapacity(fields[3]),
        .output_encoding = try Encoding.parse(fields[4]),
        .output_mime = fields[5],
        .output_capacity = try parseCapacity(fields[6]),
    };
}

fn encodingAccepted(actual: Encoding, expected: Encoding) bool {
    return actual == expected or (actual == .utf8 and expected == .bytes);
}

fn appendStep(out: *Output, row: Row) ConvertError!void {
    try out.append("  // ");
    try out.append(row.input_mime);
    try out.append(" (");
    try out.append(row.input_encoding.label());
    try out.append(", ");
    try out.appendU32(row.input_capacity);
    try out.append(" bytes) -> ");
    try out.append(row.output_mime);
    try out.append(" (");
    try out.append(row.output_encoding.label());
    try out.append(", ");
    try out.appendU32(row.output_capacity);
    try out.append(" bytes)\n  WebAssembly.instantiateStreaming(fetch(");
    try out.appendJSString(row.path);
    try out.append(")),\n");
}

fn convert(input: []const u8, output: []u8) ConvertError!usize {
    var reader = CSVReader{ .input = input };
    var storage: [MAX_ROW_BYTES]u8 = undefined;
    var fields: [7][]const u8 = undefined;
    if (!try reader.nextRow(&storage, &fields)) return ConvertError.InvalidHeader;
    if (!std.mem.eql(u8, fields[0], "path") or
        !std.mem.eql(u8, fields[1], "input_encoding") or
        !std.mem.eql(u8, fields[2], "input_mime") or
        !std.mem.eql(u8, fields[3], "input_capacity_bytes") or
        !std.mem.eql(u8, fields[4], "output_encoding") or
        !std.mem.eql(u8, fields[5], "output_mime") or
        !std.mem.eql(u8, fields[6], "output_capacity_bytes"))
    {
        return ConvertError.InvalidHeader;
    }

    var out = Output{ .bytes = output };
    try out.append(
        \\const textEncoder = new TextEncoder();
        \\const textDecoder = new TextDecoder("utf-8", { fatal: true });
        \\const components = await Promise.all([
        \\
    );

    var input_encodings: [MAX_ROWS]Encoding = undefined;
    var row_count: usize = 0;
    var first_encoding: Encoding = undefined;
    var final_encoding: Encoding = undefined;
    var previous_output_encoding: Encoding = undefined;
    var previous_output_mime: [255]u8 = undefined;
    var previous_output_mime_len: usize = 0;

    while (try reader.nextRow(&storage, &fields)) {
        if (row_count >= MAX_ROWS) return ConvertError.TooManyRows;
        const row = try parseRow(&fields);
        if (row_count == 0) {
            first_encoding = row.input_encoding;
        } else {
            if (!encodingAccepted(previous_output_encoding, row.input_encoding) or
                !std.mem.eql(u8, previous_output_mime[0..previous_output_mime_len], row.input_mime))
            {
                return ConvertError.DisconnectedRecipe;
            }
        }
        if (row.output_mime.len > previous_output_mime.len) return ConvertError.InvalidMIME;
        @memcpy(previous_output_mime[0..row.output_mime.len], row.output_mime);
        previous_output_mime_len = row.output_mime.len;
        previous_output_encoding = row.output_encoding;
        final_encoding = row.output_encoding;
        input_encodings[row_count] = row.input_encoding;
        row_count += 1;
        try appendStep(&out, row);
    }
    if (row_count == 0) return ConvertError.EmptyRecipe;

    try out.append(
        \\]);
        \\
        \\function runComponent(instance, input, inputCapacityExport) {
        \\  const exports = instance.exports;
        \\  const inputCapacity = exports[inputCapacityExport]();
        \\  if (input.length > inputCapacity) {
        \\    throw new RangeError(`Component input is too large: ${input.length} > ${inputCapacity}`);
        \\  }
        \\  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
        \\  const result = exports.render(input.length);
        \\  if (typeof result !== "bigint") throw new TypeError("Component render must return i64");
        \\  const bits = BigInt.asUintN(64, result);
        \\  if ((bits & (1n << 63n)) !== 0n) throw new Error("Component rejected input");
        \\  const outputLength = Number(bits & 0xffff_ffffn);
        \\  const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
        \\  return new Uint8Array(exports.memory.buffer, outputPointer, outputLength).slice();
        \\}
        \\
        \\export function render(value) {
        \\
    );

    if (first_encoding == .utf8) {
        try out.append(
            \\  if (typeof value !== "string") throw new TypeError("Recipe input must be a string");
            \\  let bytes = textEncoder.encode(value);
            \\
        );
    } else {
        try out.append(
            \\  if (!(value instanceof Uint8Array)) throw new TypeError("Recipe input must be Uint8Array");
            \\  let bytes = value;
            \\
        );
    }

    var index: usize = 0;
    while (index < row_count) : (index += 1) {
        try out.append("  bytes = runComponent(components[");
        try out.appendU32(@intCast(index));
        try out.append("].instance, bytes, ");
        try out.appendJSString(input_encodings[index].inputCapacityExport());
        try out.append(");\n");
    }

    if (final_encoding == .utf8) {
        try out.append("  return textDecoder.decode(bytes);\n");
    } else {
        try out.append("  return bytes;\n");
    }
    try out.append(
        \\}
        \\
        \\export default render;
        \\
    );
    return out.pos;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > INPUT_CAP) @trap();
    return @intCast(convert(input_buf[0..input_size], &output_buf) catch @trap());
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

test "generates a direct browser JavaScript recipe" {
    const csv =
        HEADER ++ "\n" ++
        "/markdown.wasm,utf8,text/markdown,1024,utf8,text/html,2048\n" ++
        "/html.wasm,utf8,text/html,2048,bytes,application/octet-stream,4096\n";
    var output: [8192]u8 = undefined;
    const size = try convert(csv, &output);
    const javascript = output[0..size];
    try std.testing.expect(std.mem.indexOf(u8, javascript, "WebAssembly.instantiateStreaming(fetch(\"/markdown.wasm\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, javascript, "components[1].instance") != null);
    try std.testing.expect(std.mem.indexOf(u8, javascript, "textEncoder.encode(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, javascript, "return bytes;") != null);
}

test "supports canonical quoted CSV fields" {
    const csv =
        HEADER ++ "\n" ++
        "\"/components/a,b.wasm\",bytes,application/wasm,100,utf8,text/javascript,200\n";
    var output: [4096]u8 = undefined;
    const size = try convert(csv, &output);
    try std.testing.expect(std.mem.indexOf(u8, output[0..size], "fetch(\"/components/a,b.wasm\")") != null);
}

test "rejects disconnected rows" {
    const csv =
        HEADER ++ "\n" ++
        "/one.wasm,utf8,text/markdown,10,utf8,text/html,20\n" ++
        "/two.wasm,utf8,text/plain,20,utf8,text/html,30\n";
    var output: [4096]u8 = undefined;
    try std.testing.expectError(ConvertError.DisconnectedRecipe, convert(csv, &output));
}

test "requires the canonical header and final newline" {
    var output: [4096]u8 = undefined;
    try std.testing.expectError(ConvertError.InvalidCSV, convert("path,input\n", &output));
    try std.testing.expectError(ConvertError.InvalidCSV, convert(
        HEADER ++ "\n" ++
            "/one.wasm,bytes,application/wasm,10,utf8,text/javascript,20",
        &output,
    ));
}
