const std = @import("std");

const INPUT_CAP: usize = 128 * 1024 * 1024;
// Every regular file costs at least one 512-byte header, so a full input holds
// at most 262,144 files. 32 MiB fits that many lines with ~60-byte paths, and
// any archive up to 32 MiB fits whatever its paths are, unless they need escaping.
const OUTPUT_CAP: usize = 32 * 1024 * 1024;
const TAR_BLOCK: usize = 512;
const INPUT_CONTENT_TYPE = "application/x-tar";
// SHA256SUMS has no registered media type; the component name pins the format.
const OUTPUT_CONTENT_TYPE = "text/plain";

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

const ConvertError = error{
    InvalidTar,
    UnsupportedTarEntry,
    InvalidPath,
    OutputOverflow,
};

const TarOverrides = struct {
    path: ?[]const u8 = null,
    size: ?usize = null,

    fn overlay(base: TarOverrides, next: TarOverrides) TarOverrides {
        return .{
            .path = next.path orelse base.path,
            .size = next.size orelse base.size,
        };
    }
};

const Output = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Output, value: []const u8) ConvertError!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }
};

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn fieldString(field: []const u8) ConvertError![]const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    if (end < field.len and !allZero(field[end..])) return error.InvalidTar;
    return field[0..end];
}

fn parseTarNumber(field: []const u8) ConvertError!u64 {
    if (field.len == 0) return error.InvalidTar;

    if ((field[0] & 0x80) != 0) {
        // POSIX base-256 encoding. Negative sizes are invalid.
        if ((field[0] & 0x40) != 0) return error.InvalidTar;
        var value: u64 = field[0] & 0x3f;
        for (field[1..]) |byte| {
            value = std.math.mul(u64, value, 256) catch return error.InvalidTar;
            value = std.math.add(u64, value, byte) catch return error.InvalidTar;
        }
        return value;
    }

    var value: u64 = 0;
    var have_digit = false;
    var ended = false;
    for (field) |byte| {
        if (byte == 0 or byte == ' ') {
            if (have_digit) ended = true;
            continue;
        }
        if (ended or byte < '0' or byte > '7') return error.InvalidTar;
        have_digit = true;
        value = std.math.mul(u64, value, 8) catch return error.InvalidTar;
        value = std.math.add(u64, value, byte - '0') catch return error.InvalidTar;
    }
    return value;
}

fn validTarChecksum(header: []const u8) bool {
    const stored = parseTarNumber(header[148..156]) catch return false;
    var sum: u64 = 0;
    for (header, 0..) |byte, index| {
        sum += if (index >= 148 and index < 156) ' ' else byte;
    }
    return stored == sum;
}

fn paddedTarSize(size: usize) ConvertError!usize {
    const with_padding = std.math.add(usize, size, TAR_BLOCK - 1) catch return error.InvalidTar;
    return (with_padding / TAR_BLOCK) * TAR_BLOCK;
}

fn decimal(bytes: []const u8) ConvertError!u64 {
    if (bytes.len == 0) return error.InvalidTar;
    var value: u64 = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidTar;
        value = std.math.mul(u64, value, 10) catch return error.InvalidTar;
        value = std.math.add(u64, value, byte - '0') catch return error.InvalidTar;
    }
    return value;
}

fn parsePax(data: []const u8, overrides: *TarOverrides) ConvertError!void {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const space = std.mem.indexOfPos(u8, data, cursor, " ") orelse return error.InvalidTar;
        const record_len_u64 = try decimal(data[cursor..space]);
        if (record_len_u64 > std.math.maxInt(usize)) return error.InvalidTar;
        const record_len: usize = @intCast(record_len_u64);
        if (record_len == 0 or record_len > data.len - cursor) return error.InvalidTar;
        const record_end = cursor + record_len;
        if (data[record_end - 1] != '\n' or space + 1 >= record_end) return error.InvalidTar;

        const body = data[space + 1 .. record_end - 1];
        const equals = std.mem.indexOfScalar(u8, body, '=') orelse return error.InvalidTar;
        const key = body[0..equals];
        const value = body[equals + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            overrides.path = value;
        } else if (std.mem.eql(u8, key, "size")) {
            const parsed = try decimal(value);
            if (parsed > std.math.maxInt(usize)) return error.InvalidTar;
            overrides.size = @intCast(parsed);
        }
        cursor = record_end;
    }
}

fn trimExtensionValue(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == 0 or data[end - 1] == '\n')) : (end -= 1) {}
    return data[0..end];
}

/// A member path as stored: either one override string, or a ustar prefix and
/// name joined by `/`.
const MemberPath = struct {
    prefix: []const u8 = "",
    name: []const u8,

    fn fromHeader(header: []const u8, override_path: ?[]const u8) ConvertError!MemberPath {
        if (override_path) |path| return .{ .name = path };
        const name = try fieldString(header[0..100]);
        // Only POSIX ustar stores a prefix at 345; old GNU headers keep
        // access and change times there.
        const posix = std.mem.eql(u8, header[257..263], "ustar\x00");
        const prefix = if (posix) try fieldString(header[345..500]) else "";
        return .{ .prefix = prefix, .name = name };
    }

    fn isDirectory(self: MemberPath) bool {
        return self.name.len != 0 and self.name[self.name.len - 1] == '/';
    }

    fn validate(self: MemberPath) ConvertError!void {
        if (self.name.len == 0) return error.InvalidPath;
        for ([_][]const u8{ self.prefix, self.name }) |part| {
            if (std.mem.indexOfScalar(u8, part, 0) != null) return error.InvalidPath;
            if (!std.unicode.utf8ValidateSlice(part)) return error.InvalidPath;
        }
    }

    fn needsEscape(self: MemberPath) bool {
        return std.mem.indexOfAny(u8, self.prefix, "\\\n") != null or
            std.mem.indexOfAny(u8, self.name, "\\\n") != null;
    }
};

fn appendEscaped(out: *Output, value: []const u8) ConvertError!void {
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        const replacement: []const u8 = switch (byte) {
            '\\' => "\\\\",
            '\n' => "\\n",
            else => continue,
        };
        try out.write(value[start..index]);
        try out.write(replacement);
        start = index + 1;
    }
    try out.write(value[start..]);
}

/// Writes one line in the `sha256sum` text format. Like coreutils, a path with
/// a backslash or newline gets a leading `\` and escapes both characters.
fn appendLine(out: *Output, digest: [32]u8, path: MemberPath) ConvertError!void {
    const escape = path.needsEscape();
    if (escape) try out.write("\\");
    var hex: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        hex[index * 2] = digits[byte >> 4];
        hex[index * 2 + 1] = digits[byte & 0x0f];
    }
    try out.write(&hex);
    try out.write("  ");
    if (path.prefix.len != 0) {
        if (escape) try appendEscaped(out, path.prefix) else try out.write(path.prefix);
        try out.write("/");
    }
    if (escape) try appendEscaped(out, path.name) else try out.write(path.name);
    try out.write("\n");
}

fn convert(input: []const u8, output: []u8) ConvertError!usize {
    if (input.len < TAR_BLOCK * 2 or input.len % TAR_BLOCK != 0) return error.InvalidTar;

    var out = Output{ .bytes = output };
    var cursor: usize = 0;
    var zero_blocks: usize = 0;
    var global = TarOverrides{};
    var pending = TarOverrides{};
    var have_pending_extension = false;

    while (cursor + TAR_BLOCK <= input.len) {
        const header = input[cursor .. cursor + TAR_BLOCK];
        if (allZero(header)) {
            zero_blocks += 1;
            cursor += TAR_BLOCK;
            if (zero_blocks == 2) {
                if (!allZero(input[cursor..])) return error.InvalidTar;
                if (have_pending_extension) return error.InvalidTar;
                return out.index;
            }
            continue;
        }
        if (zero_blocks != 0 or !validTarChecksum(header)) return error.InvalidTar;

        const header_size_u64 = try parseTarNumber(header[124..136]);
        if (header_size_u64 > std.math.maxInt(usize)) return error.InvalidTar;
        const header_size: usize = @intCast(header_size_u64);
        const type_flag = header[156];
        const data_start = cursor + TAR_BLOCK;

        if (type_flag == 'x' or type_flag == 'g' or type_flag == 'L' or type_flag == 'K') {
            const padded = try paddedTarSize(header_size);
            if (padded > input.len - data_start or header_size > input.len - data_start) return error.InvalidTar;
            const data = input[data_start .. data_start + header_size];
            if (type_flag == 'x') {
                try parsePax(data, &pending);
            } else if (type_flag == 'g') {
                try parsePax(data, &global);
            } else if (type_flag == 'L') {
                pending.path = trimExtensionValue(data);
            }
            // 'K' names a link target, which a checksum list does not use.
            if (type_flag != 'g') have_pending_extension = true;
            cursor = data_start + padded;
            continue;
        }

        const effective = global.overlay(pending);
        // Hard links, symlinks, devices, directories and FIFOs carry no
        // payload in the archive. Their size field may still be nonzero for
        // hard links, so only regular files use it to skip data.
        const regular = type_flag == '0' or type_flag == 0 or type_flag == '7';
        switch (type_flag) {
            '0', 0, '7', '1', '2', '3', '4', '5', '6' => {},
            else => return error.UnsupportedTarEntry,
        }
        const body_size = if (regular) effective.size orelse header_size else 0;
        const padded = try paddedTarSize(body_size);
        if (padded > input.len - data_start or body_size > input.len - data_start) return error.InvalidTar;

        if (regular) {
            const path = try MemberPath.fromHeader(header, effective.path);
            try path.validate();
            // Pre-POSIX archives mark directories as regular files with a
            // trailing slash.
            if (!(path.isDirectory() and body_size == 0)) {
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(input[data_start .. data_start + body_size], &digest, .{});
                try appendLine(&out, digest, path);
            }
        }

        pending = .{};
        have_pending_extension = false;
        cursor = data_start + padded;
    }
    return error.InvalidTar;
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

test "escaped lines follow coreutils sha256sum" {
    var bytes: [256]u8 = undefined;
    var out = Output{ .bytes = &bytes };
    try appendLine(&out, [_]u8{0xab} ** 32, .{ .prefix = "a\\b", .name = "c\nd" });
    try std.testing.expectEqualStrings("\\" ++ "ab" ** 32 ++ "  a\\\\b/c\\nd\n", out.bytes[0..out.index]);
}

test "plain lines are not escaped" {
    var bytes: [256]u8 = undefined;
    var out = Output{ .bytes = &bytes };
    try appendLine(&out, [_]u8{0x01} ** 32, .{ .name = "docs/readme.md" });
    try std.testing.expectEqualStrings("01" ** 32 ++ "  docs/readme.md\n", out.bytes[0..out.index]);
}
