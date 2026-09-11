//! Converts a strict, bounded multipart/form-data body to deterministic ustar.
//! Each form field becomes a regular file whose path is the field's `name`.

const std = @import("std");

const INPUT_CAP: usize = 64 * 1024 * 1024;
const MAX_PARTS: usize = 256;
const OUTPUT_CAP: usize = INPUT_CAP + MAX_PARTS * 1024 + 1024;
const TAR_BLOCK: usize = 512;
const MAX_HEADER_BYTES: usize = 16 * 1024;
const OUTPUT_CONTENT_TYPE = "application/x-tar";
const TYPE_PREFIX = "multipart/form-data;boundary=uuid-";
const DEFAULT_UUID = "00000000-0000-0000-0000-000000000000";

// The UUID bytes are deliberately writable through the exported pointer. Hosts
// may replace them with another canonical lowercase UUID before render().
var input_content_type = (TYPE_PREFIX ++ DEFAULT_UUID).*;
var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var names: [MAX_PARTS][]const u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(&input_content_type));
}

export fn input_content_type_size() u32 {
    return input_content_type.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const ConvertError = error{
    InvalidBoundary,
    InvalidMultipart,
    InvalidHeader,
    MissingName,
    UnsafePath,
    DuplicateName,
    TooManyParts,
    OutputOverflow,
};

const Output = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Output, value: []const u8) ConvertError!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index .. self.index + value.len], value);
        self.index += value.len;
    }

    fn zero(self: *Output, count: usize) ConvertError!void {
        if (count > self.bytes.len - self.index) return error.OutputOverflow;
        @memset(self.bytes[self.index .. self.index + count], 0);
        self.index += count;
    }
};

fn readBoundary(out: *[TYPE_PREFIX.len + DEFAULT_UUID.len]u8) ConvertError![]const u8 {
    // Volatile loads are required because the host can edit this metadata after
    // instantiation, outside Zig's view of program execution.
    for (&input_content_type, 0..) |*byte, index| {
        out[index] = @as(*volatile u8, @ptrCast(byte)).*;
    }
    if (!std.mem.eql(u8, out[0..TYPE_PREFIX.len], TYPE_PREFIX)) return error.InvalidBoundary;
    const uuid = out[TYPE_PREFIX.len..];
    for (uuid, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidBoundary;
        } else if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) {
            return error.InvalidBoundary;
        }
    }
    return out["multipart/form-data;boundary=".len..];
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 100 or path[0] == '/') return false;
    var segment_start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte < 0x20 or byte > 0x7e or byte == '\\') return false;
        if (byte == '/') {
            const segment = path[segment_start..index];
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
            segment_start = index + 1;
        }
    }
    const last = path[segment_start..];
    return last.len != 0 and !std.mem.eql(u8, last, ".") and !std.mem.eql(u8, last, "..");
}

fn trimOWS(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn dispositionName(value: []const u8) ConvertError![]const u8 {
    var fields = std.mem.splitScalar(u8, value, ';');
    if (!std.ascii.eqlIgnoreCase(trimOWS(fields.next() orelse return error.InvalidHeader), "form-data")) {
        return error.InvalidHeader;
    }
    var result: ?[]const u8 = null;
    while (fields.next()) |raw_field| {
        const field = trimOWS(raw_field);
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidHeader;
        const key = trimOWS(field[0..equal]);
        const raw_value = trimOWS(field[equal + 1 ..]);
        if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') return error.InvalidHeader;
        const quoted = raw_value[1 .. raw_value.len - 1];
        // Escaped quoted-string values would need decoding before becoming TAR
        // paths. Reject them so a field name has one unambiguous byte spelling.
        if (std.mem.indexOfAny(u8, quoted, "\"\\\r\n") != null) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(key, "name")) {
            if (result != null) return error.InvalidHeader;
            result = quoted;
        }
    }
    return result orelse error.MissingName;
}

fn parseHeaders(block: []const u8) ConvertError![]const u8 {
    var disposition: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return error.InvalidHeader;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const key = line[0..colon];
        const value = trimOWS(line[colon + 1 ..]);
        if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
            if (disposition != null) return error.InvalidHeader;
            disposition = try dispositionName(value);
        } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
            if (value.len == 0) return error.InvalidHeader;
        } else if (std.ascii.eqlIgnoreCase(key, "content-transfer-encoding")) {
            return error.InvalidHeader;
        } else {
            return error.InvalidHeader;
        }
    }
    return disposition orelse error.MissingName;
}

fn putOctal(field: []u8, value: usize) ConvertError!void {
    @memset(field, '0');
    field[field.len - 1] = 0;
    var remaining = value;
    var index = field.len - 1;
    while (remaining != 0) {
        if (index == 0) return error.OutputOverflow;
        index -= 1;
        field[index] = @intCast('0' + remaining % 8);
        remaining /= 8;
    }
}

fn writeTarEntry(output: *Output, path: []const u8, body: []const u8) ConvertError!void {
    if (TAR_BLOCK > output.bytes.len - output.index) return error.OutputOverflow;
    const header = output.bytes[output.index .. output.index + TAR_BLOCK];
    @memset(header, 0);
    @memcpy(header[0..path.len], path);
    try putOctal(header[100..108], 0o644);
    try putOctal(header[108..116], 0);
    try putOctal(header[116..124], 0);
    try putOctal(header[124..136], body.len);
    try putOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = '0';
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var checksum: usize = 0;
    for (header) |byte| checksum += byte;
    try putOctal(header[148..155], checksum);
    header[155] = ' ';
    output.index += TAR_BLOCK;
    try output.write(body);
    const padding = (TAR_BLOCK - body.len % TAR_BLOCK) % TAR_BLOCK;
    try output.zero(padding);
}

fn findBoundary(input: []const u8, start: usize, marker: []const u8) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, input, cursor, marker)) |at| {
        const suffix = at + marker.len;
        if (suffix + 2 <= input.len and
            (std.mem.eql(u8, input[suffix .. suffix + 2], "\r\n") or
                std.mem.eql(u8, input[suffix .. suffix + 2], "--"))) return at;
        cursor = at + 1;
    }
    return null;
}

fn run(input: []const u8) ConvertError!usize {
    var type_bytes: [TYPE_PREFIX.len + DEFAULT_UUID.len]u8 = undefined;
    const boundary = try readBoundary(&type_bytes);
    var opening: [2 + "uuid-".len + DEFAULT_UUID.len + 2]u8 = undefined;
    opening[0] = '-';
    opening[1] = '-';
    @memcpy(opening[2 .. opening.len - 2], boundary);
    opening[opening.len - 2] = '\r';
    opening[opening.len - 1] = '\n';
    if (input.len >= opening.len - 2 + 4 and
        std.mem.eql(u8, input[0 .. opening.len - 2], opening[0 .. opening.len - 2]) and
        std.mem.eql(u8, input[opening.len - 2 .. opening.len + 2], "--\r\n"))
    {
        if (input.len != opening.len + 2) return error.InvalidMultipart;
        @memset(output_buf[0 .. TAR_BLOCK * 2], 0);
        return TAR_BLOCK * 2;
    }
    if (!std.mem.startsWith(u8, input, &opening)) return error.InvalidMultipart;

    var marker: [4 + "uuid-".len + DEFAULT_UUID.len]u8 = undefined;
    marker[0] = '\r';
    marker[1] = '\n';
    marker[2] = '-';
    marker[3] = '-';
    @memcpy(marker[4..], boundary);

    var output = Output{ .bytes = &output_buf };
    var cursor: usize = opening.len;
    var part_count: usize = 0;
    while (true) {
        if (part_count == MAX_PARTS) return error.TooManyParts;
        const header_end = std.mem.indexOfPos(u8, input, cursor, "\r\n\r\n") orelse return error.InvalidMultipart;
        if (header_end - cursor > MAX_HEADER_BYTES) return error.InvalidHeader;
        const path = try parseHeaders(input[cursor..header_end]);
        if (!safePath(path)) return error.UnsafePath;
        for (names[0..part_count]) |previous| {
            if (std.mem.eql(u8, previous, path)) return error.DuplicateName;
        }
        names[part_count] = path;

        const body_start = header_end + 4;
        const marker_at = findBoundary(input, body_start, &marker) orelse return error.InvalidMultipart;
        try writeTarEntry(&output, path, input[body_start..marker_at]);
        part_count += 1;

        cursor = marker_at + marker.len;
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "--")) {
            cursor += 2;
            if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "\r\n")) cursor += 2;
            if (cursor != input.len) return error.InvalidMultipart;
            try output.zero(TAR_BLOCK * 2);
            return output.index;
        }
        if (cursor + 2 > input.len or !std.mem.eql(u8, input[cursor .. cursor + 2], "\r\n")) return error.InvalidMultipart;
        cursor += 2;
    }
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    return @intCast(run(input_buf[0..input_size]) catch @trap());
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
