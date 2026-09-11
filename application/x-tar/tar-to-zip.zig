const std = @import("std");
const deflate = @import("deflate");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 160 * 1024 * 1024;
// 512 KiB kept throughput flat in the block-size sweep while reducing token
// scratch from 32 MiB to 2 MiB. Adjust this one constant to retune the batch.
const DEFLATE_BLOCK_SIZE: usize = 512 * 1024;
const TAR_BLOCK: usize = 512;
const MAX_ENTRIES: usize = 65_535;

const INPUT_CONTENT_TYPE = "application/x-tar";
const OUTPUT_CONTENT_TYPE = "application/zip";

const ZIP_LOCAL_HEADER_SIZE: usize = 30;
const ZIP_CENTRAL_HEADER_SIZE: usize = 46;
const ZIP_END_SIZE: usize = 22;
const ZIP_UTF8_FLAG: u16 = 1 << 11;
const ZIP_METHOD_STORE: u16 = 0;
const ZIP_METHOD_DEFLATE: u16 = 8;
// A 32-candidate search retains nearly all of the compression ratio on mixed
// source archives without spending time on the long tail of the hash chain.
const DEFLATE_MAX_CHAIN: usize = 32;
const ZIP_VERSION_20: u16 = 20;
const ZIP_VERSION_UNIX_20: u16 = (3 << 8) | ZIP_VERSION_20;
const ZIP_TIMESTAMP_EXTRA_ID: u16 = 0x5455;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var token_buf: [DEFLATE_BLOCK_SIZE]u32 = undefined;
var entries: [MAX_ENTRIES]ZipEntry = undefined;

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
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

const ConvertError = error{
    InvalidTar,
    UnsupportedTarEntry,
    UnsafePath,
    TooManyEntries,
    Zip32Limit,
    OutputOverflow,
    CompressionFailed,
};

const TarOverrides = struct {
    path: ?[]const u8 = null,
    linkpath: ?[]const u8 = null,
    size: ?usize = null,
    mtime: ?u64 = null,

    fn overlay(base: TarOverrides, next: TarOverrides) TarOverrides {
        return .{
            .path = next.path orelse base.path,
            .linkpath = next.linkpath orelse base.linkpath,
            .size = next.size orelse base.size,
            .mtime = next.mtime orelse base.mtime,
        };
    }
};

const ZipEntry = struct {
    name_offset: u32,
    name_len: u16,
    local_offset: u32,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    method: u16,
    mode: u16,
    kind: u8,
    mtime: ?u32,
};

const Output = struct {
    bytes: []u8,
    index: usize = 0,

    fn ensure(self: *const Output, count: usize) ConvertError!void {
        if (count > self.bytes.len - self.index) return error.OutputOverflow;
    }

    fn writeByte(self: *Output, value: u8) ConvertError!void {
        try self.ensure(1);
        self.bytes[self.index] = value;
        self.index += 1;
    }

    fn write(self: *Output, bytes: []const u8) ConvertError!void {
        try self.ensure(bytes.len);
        @memcpy(self.bytes[self.index .. self.index + bytes.len], bytes);
        self.index += bytes.len;
    }

    fn reserve(self: *Output, count: usize) ConvertError!usize {
        try self.ensure(count);
        const start = self.index;
        self.index += count;
        return start;
    }

    fn writeU16(self: *Output, value: u16) ConvertError!void {
        const start = try self.reserve(2);
        std.mem.writeInt(u16, self.bytes[start..][0..2], value, .little);
    }

    fn writeU32(self: *Output, value: u32) ConvertError!void {
        const start = try self.reserve(4);
        std.mem.writeInt(u32, self.bytes[start..][0..4], value, .little);
    }

    fn patchU16(self: *Output, offset: usize, value: u16) void {
        std.mem.writeInt(u16, self.bytes[offset..][0..2], value, .little);
    }

    fn patchU32(self: *Output, offset: usize, value: u32) void {
        std.mem.writeInt(u32, self.bytes[offset..][0..4], value, .little);
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
        // POSIX base-256 encoding. Negative values are not useful for the
        // sizes, modes, and timestamps represented by this component.
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

fn paxTimestamp(bytes: []const u8) ConvertError!u64 {
    if (bytes.len == 0 or bytes[0] == '-') return error.InvalidTar;
    const dot = std.mem.indexOfScalar(u8, bytes, '.') orelse bytes.len;
    return decimal(bytes[0..dot]);
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
        } else if (std.mem.eql(u8, key, "linkpath")) {
            overrides.linkpath = value;
        } else if (std.mem.eql(u8, key, "size")) {
            const parsed = try decimal(value);
            if (parsed > std.math.maxInt(usize)) return error.InvalidTar;
            overrides.size = @intCast(parsed);
        } else if (std.mem.eql(u8, key, "mtime")) {
            overrides.mtime = try paxTimestamp(value);
        }
        cursor = record_end;
    }
}

fn trimExtensionValue(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == 0 or data[end - 1] == '\n')) : (end -= 1) {}
    return data[0..end];
}

fn validatePath(path: []const u8) ConvertError!void {
    if (path.len == 0 or path.len > std.math.maxInt(u16)) return error.UnsafePath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.UnsafePath;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafePath;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.UnsafePath;
    }
}

fn timestampExtraSize(mtime: ?u32) u16 {
    return if (mtime == null) 0 else 9;
}

fn writeTimestampExtra(out: *Output, mtime: ?u32) ConvertError!void {
    const value = mtime orelse return;
    try out.writeU16(ZIP_TIMESTAMP_EXTRA_ID);
    try out.writeU16(5);
    try out.writeByte(1);
    try out.writeU32(value);
}

fn appendTarPath(out: *Output, header: []const u8, override_path: ?[]const u8, is_dir: bool) ConvertError!struct { offset: usize, len: usize } {
    const start = out.index;
    if (override_path) |path| {
        try out.write(path);
    } else {
        const name = try fieldString(header[0..100]);
        const prefix = try fieldString(header[345..500]);
        if (prefix.len != 0) {
            try out.write(prefix);
            try out.writeByte('/');
        }
        try out.write(name);
    }

    if (is_dir and (out.index == start or out.bytes[out.index - 1] != '/')) {
        try out.writeByte('/');
    }
    const path = out.bytes[start..out.index];
    try validatePath(path);
    return .{ .offset = start, .len = path.len };
}

fn zipMode(tar_mode: u64, kind: u8) u16 {
    const permissions: u16 = @intCast(tar_mode & 0o7777);
    const file_type: u16 = switch (kind) {
        '5' => 0o040000,
        '2' => 0o120000,
        else => 0o100000,
    };
    return file_type | permissions;
}

fn addZipEntry(
    out: *Output,
    entry_table: []ZipEntry,
    entry_count: *usize,
    header: []const u8,
    override_path: ?[]const u8,
    body: []const u8,
    tar_mode: u64,
    kind: u8,
    mtime_u64: u64,
    tokens: []u32,
) ConvertError!void {
    if (entry_count.* >= entry_table.len) return error.TooManyEntries;
    if (body.len > std.math.maxInt(u32) or out.index > std.math.maxInt(u32)) return error.Zip32Limit;

    const local_offset = out.index;
    const local_header = try out.reserve(ZIP_LOCAL_HEADER_SIZE);
    const is_dir = kind == '5';
    const name = try appendTarPath(out, header, override_path, is_dir);
    if (name.len > std.math.maxInt(u16)) return error.Zip32Limit;

    const mtime: ?u32 = if (mtime_u64 <= std.math.maxInt(u32)) @intCast(mtime_u64) else null;
    const extra_len = timestampExtraSize(mtime);
    try writeTimestampExtra(out, mtime);

    const data_start = out.index;
    var method: u16 = ZIP_METHOD_STORE;
    var compressed_size = body.len;
    if (!is_dir and body.len != 0) {
        const available = out.bytes[data_start..];
        const raw_size_optional = deflate.compressRawBlocksWithOptions(body, available, tokens, .{
            .max_chain = DEFLATE_MAX_CHAIN,
        });
        if (raw_size_optional) |raw_size| {
            if (raw_size < body.len) {
                method = ZIP_METHOD_DEFLATE;
                compressed_size = raw_size;
                out.index = data_start + raw_size;
            } else {
                try out.write(body);
            }
        } else {
            // A full output buffer may still have room for the uncompressed
            // entry, which is a valid and preferable fallback.
            try out.write(body);
        }
    }

    if (compressed_size > std.math.maxInt(u32)) return error.Zip32Limit;
    const crc = std.hash.Crc32.hash(body);
    const name_len: u16 = @intCast(name.len);
    const size_u32: u32 = @intCast(body.len);
    const compressed_u32: u32 = @intCast(compressed_size);

    out.patchU32(local_header, 0x04034b50);
    out.patchU16(local_header + 4, ZIP_VERSION_20);
    out.patchU16(local_header + 6, ZIP_UTF8_FLAG);
    out.patchU16(local_header + 8, method);
    out.patchU16(local_header + 10, 0);
    out.patchU16(local_header + 12, 0x0021); // 1980-01-01; Unix time is in the extra field.
    out.patchU32(local_header + 14, crc);
    out.patchU32(local_header + 18, compressed_u32);
    out.patchU32(local_header + 22, size_u32);
    out.patchU16(local_header + 26, name_len);
    out.patchU16(local_header + 28, extra_len);

    entry_table[entry_count.*] = .{
        .name_offset = @intCast(name.offset),
        .name_len = name_len,
        .local_offset = @intCast(local_offset),
        .crc32 = crc,
        .compressed_size = compressed_u32,
        .uncompressed_size = size_u32,
        .method = method,
        .mode = zipMode(tar_mode, kind),
        .kind = kind,
        .mtime = mtime,
    };
    entry_count.* += 1;
}

fn writeCentralDirectory(out: *Output, entry_table: []const ZipEntry) ConvertError!void {
    if (out.index > std.math.maxInt(u32)) return error.Zip32Limit;
    const central_start = out.index;

    for (entry_table) |entry| {
        try out.writeU32(0x02014b50);
        try out.writeU16(ZIP_VERSION_UNIX_20);
        try out.writeU16(ZIP_VERSION_20);
        try out.writeU16(ZIP_UTF8_FLAG);
        try out.writeU16(entry.method);
        try out.writeU16(0);
        try out.writeU16(0x0021);
        try out.writeU32(entry.crc32);
        try out.writeU32(entry.compressed_size);
        try out.writeU32(entry.uncompressed_size);
        try out.writeU16(entry.name_len);
        try out.writeU16(timestampExtraSize(entry.mtime));
        try out.writeU16(0);
        try out.writeU16(0);
        try out.writeU16(0);
        const dos_attrs: u32 = if (entry.kind == '5') 0x10 else 0;
        try out.writeU32((@as(u32, entry.mode) << 16) | dos_attrs);
        try out.writeU32(entry.local_offset);
        const name_start: usize = entry.name_offset;
        try out.write(out.bytes[name_start .. name_start + entry.name_len]);
        try writeTimestampExtra(out, entry.mtime);
    }

    const central_size = out.index - central_start;
    if (central_start > std.math.maxInt(u32) or central_size > std.math.maxInt(u32)) {
        return error.Zip32Limit;
    }
    if (entry_table.len > std.math.maxInt(u16)) return error.TooManyEntries;

    try out.writeU32(0x06054b50);
    try out.writeU16(0);
    try out.writeU16(0);
    try out.writeU16(@intCast(entry_table.len));
    try out.writeU16(@intCast(entry_table.len));
    try out.writeU32(@intCast(central_size));
    try out.writeU32(@intCast(central_start));
    try out.writeU16(0);
}

fn convertTarToZip(input: []const u8, output: []u8, tokens: []u32, entry_table: []ZipEntry) ConvertError!usize {
    if (input.len < TAR_BLOCK * 2 or input.len % TAR_BLOCK != 0) return error.InvalidTar;

    var out = Output{ .bytes = output };
    var cursor: usize = 0;
    var entry_count: usize = 0;
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
                try writeCentralDirectory(&out, entry_table[0..entry_count]);
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
            if (!allZero(input[data_start + header_size .. data_start + padded])) return error.InvalidTar;
            if (type_flag == 'x') {
                try parsePax(data, &pending);
            } else if (type_flag == 'g') {
                try parsePax(data, &global);
            } else if (type_flag == 'L') {
                pending.path = trimExtensionValue(data);
            } else {
                pending.linkpath = trimExtensionValue(data);
            }
            if (type_flag != 'g') have_pending_extension = true;
            cursor = data_start + padded;
            continue;
        }

        const effective = global.overlay(pending);
        const body_size = effective.size orelse header_size;
        const padded = try paddedTarSize(body_size);
        if (padded > input.len - data_start or body_size > input.len - data_start) return error.InvalidTar;
        if (!allZero(input[data_start + body_size .. data_start + padded])) return error.InvalidTar;

        const tar_mode = try parseTarNumber(header[100..108]);
        const header_mtime = try parseTarNumber(header[136..148]);
        const mtime = effective.mtime orelse header_mtime;
        const kind: u8 = if (type_flag == 0) '0' else type_flag;
        switch (kind) {
            '0' => try addZipEntry(
                &out,
                entry_table,
                &entry_count,
                header,
                effective.path,
                input[data_start .. data_start + body_size],
                tar_mode,
                kind,
                mtime,
                tokens,
            ),
            '5' => {
                if (body_size != 0) return error.InvalidTar;
                try addZipEntry(&out, entry_table, &entry_count, header, effective.path, "", tar_mode, kind, mtime, tokens);
            },
            '2' => {
                if (body_size != 0) return error.InvalidTar;
                const link_target = effective.linkpath orelse try fieldString(header[157..257]);
                if (link_target.len == 0 or std.mem.indexOfScalar(u8, link_target, 0) != null) return error.InvalidTar;
                try addZipEntry(&out, entry_table, &entry_count, header, effective.path, link_target, tar_mode, kind, mtime, tokens);
            },
            else => return error.UnsupportedTarEntry,
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
    const written = convertTarToZip(
        input_buf[0..input_size],
        &output_buf,
        &token_buf,
        &entries,
    ) catch @trap();
    return @intCast(written);
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

test "CRC-32 matches the ZIP check value" {
    try std.testing.expectEqual(@as(u32, 0xcbf43926), std.hash.Crc32.hash("123456789"));
}
