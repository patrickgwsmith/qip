//! Strict reader for the classic single-disk ZIP subset used by the
//! application/zip components. Entry and file indices are assigned from
//! central-directory order; neither index is stored in the ZIP itself.

const std = @import("std");
const inflate = @import("inflate");

pub const INPUT_CAP: usize = 128 * 1024 * 1024;
pub const OUTPUT_CAP: usize = 160 * 1024 * 1024;
pub const MAX_ENTRIES: usize = 65_534;
pub const MAX_NAME_UTF8: usize = 3 * 65_535;

pub const INPUT_CONTENT_TYPE = "application/zip";

const LOCAL_SIGNATURE: u32 = 0x04034b50;
const CENTRAL_SIGNATURE: u32 = 0x02014b50;
const DESCRIPTOR_SIGNATURE: u32 = 0x08074b50;
const EOCD_SIGNATURE: u32 = 0x06054b50;
const METHOD_STORE: u16 = 0;
const METHOD_DEFLATE: u16 = 8;
const FLAG_DESCRIPTOR: u16 = 1 << 3;
const FLAG_UTF8: u16 = 1 << 11;
const ALLOWED_FLAGS: u16 = (1 << 1) | (1 << 2) | FLAG_DESCRIPTOR | FLAG_UTF8;

pub const Error = error{
    InvalidZip,
    UnsupportedZip,
    UnsafePath,
    OutputOverflow,
};

pub const Kind = enum(u8) {
    regular,
    directory,
    symlink,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .regular => "file",
            .directory => "directory",
            .symlink => "symlink",
        };
    }
};

pub const Entry = struct {
    entry_index: u32,
    file_index: ?u32,
    path: []const u8,
    kind: Kind,
    method: u16,
    compressed_size: u32,
    uncompressed_size: u32,
    mode: u16,
    mtime: u64,
    uid: u64,
    gid: u64,
    crc32: u32,
    data_offset: u32,

    pub fn methodText(self: Entry) []const u8 {
        return if (self.method == METHOD_STORE) "store" else "deflate";
    }
};

const Range = struct {
    start: u32,
    end: u32,
};

const Extra = struct {
    unicode_path: ?[]const u8 = null,
    mtime: ?u64 = null,
    uid: ?u64 = null,
    gid: ?u64 = null,
};

const Draft = struct {
    name: []const u8,
    central_extra: Extra,
    made_by: u16,
    external: u32,
    flags: u16,
    method: u16,
    dos_time: u16,
    dos_date: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    local_offset: u32,
};

const Local = struct {
    metadata: Extra,
    data_offset: u32,
    range_end: u32,
};

var ranges: [MAX_ENTRIES]Range = undefined;
var decoded_name: [MAX_NAME_UTF8]u8 = undefined;
var normalized_name: [MAX_NAME_UTF8]u8 = undefined;
var component_starts: [65_536]u32 = undefined;

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return error.InvalidZip;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.InvalidZip;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn checkedEnd(start: usize, length: usize, limit: usize) Error!usize {
    if (start > limit or length > limit - start) return error.InvalidZip;
    return start + length;
}

fn findEocd(input: []const u8) Error!usize {
    if (input.len < 22) return error.InvalidZip;
    const earliest = input.len - @min(input.len, 22 + 65_535);
    var offset = input.len - 22;
    while (true) {
        if (try readU32(input, offset) == EOCD_SIGNATURE) {
            const comment_len = try readU16(input, offset + 20);
            if (offset + 22 + @as(usize, comment_len) == input.len) return offset;
        }
        if (offset == earliest) break;
        offset -= 1;
    }
    return error.InvalidZip;
}

fn parseExtras(bytes: []const u8, raw_name: []const u8, central: bool) Error!Extra {
    var result = Extra{};
    var pos: usize = 0;
    var seen_unicode = false;
    var seen_timestamp = false;
    var seen_uid_gid = false;
    while (pos < bytes.len) {
        if (bytes.len - pos < 4) return error.InvalidZip;
        const id = std.mem.readInt(u16, bytes[pos..][0..2], .little);
        const size: usize = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .little);
        pos += 4;
        if (size > bytes.len - pos) return error.InvalidZip;
        const value = bytes[pos .. pos + size];
        pos += size;

        switch (id) {
            0x0001 => return error.UnsupportedZip,
            0x7075 => {
                if (seen_unicode or value.len < 5 or value[0] != 1) return error.InvalidZip;
                seen_unicode = true;
                if (std.mem.readInt(u32, value[1..5], .little) != std.hash.Crc32.hash(raw_name)) return error.InvalidZip;
                if (value.len == 5 or !std.unicode.utf8ValidateSlice(value[5..])) return error.InvalidZip;
                result.unicode_path = value[5..];
            },
            0x5455 => {
                if (seen_timestamp or value.len < 1) return error.InvalidZip;
                seen_timestamp = true;
                const flags = value[0];
                if ((flags & ~@as(u8, 7)) != 0) return error.InvalidZip;
                var field_pos: usize = 1;
                var bit: u8 = 1;
                while (bit <= 4) : (bit <<= 1) {
                    if ((flags & bit) == 0) continue;
                    if (value.len - field_pos < 4) {
                        if (central and bit != 1) continue;
                        return error.InvalidZip;
                    }
                    const stamp = std.mem.readInt(u32, value[field_pos..][0..4], .little);
                    if (bit == 1) result.mtime = stamp;
                    field_pos += 4;
                }
                if (field_pos != value.len) return error.InvalidZip;
            },
            0x7875 => {
                if (seen_uid_gid or value.len < 3 or value[0] != 1) return error.InvalidZip;
                seen_uid_gid = true;
                const uid_len: usize = value[1];
                if (uid_len == 0 or uid_len > 8 or 2 + uid_len >= value.len) return error.InvalidZip;
                result.uid = try parseLittleUnsigned(value[2 .. 2 + uid_len]);
                const gid_len_offset = 2 + uid_len;
                const gid_len: usize = value[gid_len_offset];
                if (gid_len == 0 or gid_len > 8 or gid_len_offset + 1 + gid_len != value.len) return error.InvalidZip;
                result.gid = try parseLittleUnsigned(value[gid_len_offset + 1 ..]);
            },
            else => {},
        }
    }
    return result;
}

fn parseLittleUnsigned(bytes: []const u8) Error!u64 {
    if (bytes.len == 0 or bytes.len > 8) return error.InvalidZip;
    var value: u64 = 0;
    for (bytes, 0..) |byte, shift| {
        value |= @as(u64, byte) << @intCast(shift * 8);
    }
    return value;
}

const CP437 = [_]u16{
    0x00c7, 0x00fc, 0x00e9, 0x00e2, 0x00e4, 0x00e0, 0x00e5, 0x00e7,
    0x00ea, 0x00eb, 0x00e8, 0x00ef, 0x00ee, 0x00ec, 0x00c4, 0x00c5,
    0x00c9, 0x00e6, 0x00c6, 0x00f4, 0x00f6, 0x00f2, 0x00fb, 0x00f9,
    0x00ff, 0x00d6, 0x00dc, 0x00a2, 0x00a3, 0x00a5, 0x20a7, 0x0192,
    0x00e1, 0x00ed, 0x00f3, 0x00fa, 0x00f1, 0x00d1, 0x00aa, 0x00ba,
    0x00bf, 0x2310, 0x00ac, 0x00bd, 0x00bc, 0x00a1, 0x00ab, 0x00bb,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
    0x2555, 0x2563, 0x2551, 0x2557, 0x255d, 0x255c, 0x255b, 0x2510,
    0x2514, 0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0x255e, 0x255f,
    0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256c, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256b,
    0x256a, 0x2518, 0x250c, 0x2588, 0x2584, 0x258c, 0x2590, 0x2580,
    0x03b1, 0x00df, 0x0393, 0x03c0, 0x03a3, 0x03c3, 0x00b5, 0x03c4,
    0x03a6, 0x0398, 0x03a9, 0x03b4, 0x221e, 0x03c6, 0x03b5, 0x2229,
    0x2261, 0x00b1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00f7, 0x2248,
    0x00b0, 0x2219, 0x00b7, 0x221a, 0x207f, 0x00b2, 0x25a0, 0x00a0,
};

fn appendCodepoint(out: []u8, pos: *usize, cp: u21) Error!void {
    const len = std.unicode.utf8CodepointSequenceLength(cp) catch return error.InvalidZip;
    if (len > out.len - pos.*) return error.InvalidZip;
    _ = std.unicode.utf8Encode(cp, out[pos.*..]) catch return error.InvalidZip;
    pos.* += len;
}

fn decodedPath(raw_name: []const u8, flags: u16, extra: Extra) Error![]const u8 {
    if (extra.unicode_path) |path| return path;
    if ((flags & FLAG_UTF8) != 0) {
        if (!std.unicode.utf8ValidateSlice(raw_name)) return error.InvalidZip;
        return raw_name;
    }
    var len: usize = 0;
    for (raw_name) |byte| {
        if (byte < 0x80) {
            decoded_name[len] = byte;
            len += 1;
        } else {
            try appendCodepoint(&decoded_name, &len, @intCast(CP437[byte - 0x80]));
        }
    }
    return decoded_name[0..len];
}

fn asciiDrive(component: []const u8) bool {
    return component.len == 2 and component[1] == ':' and
        ((component[0] >= 'a' and component[0] <= 'z') or
            (component[0] >= 'A' and component[0] <= 'Z'));
}

fn normalizePath(path: []const u8) Error![]const u8 {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;

    var out_len: usize = 0;
    var components: usize = 0;
    var start: usize = 0;
    var pos: usize = 0;
    while (pos <= path.len) : (pos += 1) {
        if (pos != path.len and path[pos] != '/' and path[pos] != '\\') continue;
        const component = path[start..pos];
        start = pos + 1;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components == 0) return error.UnsafePath;
            components -= 1;
            out_len = component_starts[components];
            continue;
        }
        if (components == 0 and asciiDrive(component)) return error.UnsafePath;
        if (components >= component_starts.len) return error.InvalidZip;
        if (out_len != 0) {
            normalized_name[out_len] = '/';
            out_len += 1;
        }
        component_starts[components] = @intCast(if (out_len == 0) 0 else out_len - 1);
        components += 1;
        if (component.len > normalized_name.len - out_len) return error.InvalidZip;
        @memcpy(normalized_name[out_len..][0..component.len], component);
        out_len += component.len;
    }
    if (out_len == 0) return error.UnsafePath;
    return normalized_name[0..out_len];
}

fn isLeap(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn dosTimestamp(date: u16, time: u16) Error!u64 {
    if (date == 0) return 0;
    const year: u32 = 1980 + (date >> 9);
    const month: u32 = (date >> 5) & 15;
    const day: u32 = date & 31;
    const hour: u32 = time >> 11;
    const minute: u32 = (time >> 5) & 63;
    const second: u32 = (time & 31) * 2;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidZip;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const max_day: u32 = month_days[month - 1] + @as(u8, if (month == 2 and isLeap(year)) 1 else 0);
    if (day > max_day) return error.InvalidZip;
    var days: u64 = 0;
    var y: u32 = 1970;
    while (y < year) : (y += 1) days += if (isLeap(y)) 366 else 365;
    var m: u32 = 1;
    while (m < month) : (m += 1) {
        days += month_days[m - 1];
        if (m == 2 and isLeap(year)) days += 1;
    }
    days += day - 1;
    return days * 86_400 + hour * 3600 + minute * 60 + second;
}

fn classify(made_by: u16, external: u32, trailing_separator: bool) Error!struct { Kind, u16 } {
    const host = made_by >> 8;
    const unix_mode: u16 = @intCast(external >> 16);
    const type_bits = unix_mode & 0o170000;
    var kind: Kind = if (trailing_separator or (external & 0x10) != 0) .directory else .regular;
    if (host == 3 and type_bits != 0) {
        kind = switch (type_bits) {
            0o100000 => .regular,
            0o040000 => .directory,
            0o120000 => .symlink,
            else => return error.UnsupportedZip,
        };
    }
    const default_mode: u16 = switch (kind) {
        .directory => 0o755,
        .symlink => 0o777,
        .regular => 0o644,
    };
    const permissions = if (host == 3 and (unix_mode & 0o7777) != 0) unix_mode & 0o7777 else default_mode;
    return .{ kind, permissions };
}

fn mergeExtra(central: Extra, local: Extra) Error!Extra {
    if (central.unicode_path != null and local.unicode_path != null and
        !std.mem.eql(u8, central.unicode_path.?, local.unicode_path.?)) return error.InvalidZip;
    if (central.uid != null and local.uid != null and central.uid.? != local.uid.?) return error.InvalidZip;
    if (central.gid != null and local.gid != null and central.gid.? != local.gid.?) return error.InvalidZip;
    return .{
        .unicode_path = central.unicode_path orelse local.unicode_path,
        .mtime = local.mtime orelse central.mtime,
        .uid = local.uid orelse central.uid,
        .gid = local.gid orelse central.gid,
    };
}

fn validateLocal(input: []const u8, cd_start: usize, draft: Draft) Error!Local {
    const local: usize = draft.local_offset;
    if (local >= cd_start or try readU32(input, local) != LOCAL_SIGNATURE) return error.InvalidZip;
    if (try readU16(input, local + 6) != draft.flags or
        try readU16(input, local + 8) != draft.method or
        try readU16(input, local + 10) != draft.dos_time or
        try readU16(input, local + 12) != draft.dos_date) return error.InvalidZip;
    const name_len: usize = try readU16(input, local + 26);
    const extra_len: usize = try readU16(input, local + 28);
    const name_start = try checkedEnd(local, 30, cd_start);
    const extra_start = try checkedEnd(name_start, name_len, cd_start);
    const data_start = try checkedEnd(extra_start, extra_len, cd_start);
    if (!std.mem.eql(u8, draft.name, input[name_start..extra_start])) return error.InvalidZip;
    const local_extra = try parseExtras(input[extra_start..data_start], draft.name, false);
    const metadata = try mergeExtra(draft.central_extra, local_extra);

    const local_crc = try readU32(input, local + 14);
    const local_compressed = try readU32(input, local + 18);
    const local_uncompressed = try readU32(input, local + 22);
    if ((draft.flags & FLAG_DESCRIPTOR) == 0) {
        if (local_crc != draft.crc32 or local_compressed != draft.compressed_size or
            local_uncompressed != draft.uncompressed_size) return error.InvalidZip;
    } else {
        if ((local_crc != 0 and local_crc != draft.crc32) or
            (local_compressed != 0 and local_compressed != draft.compressed_size) or
            (local_uncompressed != 0 and local_uncompressed != draft.uncompressed_size)) return error.InvalidZip;
    }

    const data_end = try checkedEnd(data_start, draft.compressed_size, cd_start);
    var range_end = data_end;
    if ((draft.flags & FLAG_DESCRIPTOR) != 0) {
        const first = try readU32(input, data_end);
        var matched = false;
        if (first == DESCRIPTOR_SIGNATURE and data_end + 16 <= cd_start and
            try readU32(input, data_end + 4) == draft.crc32 and
            try readU32(input, data_end + 8) == draft.compressed_size and
            try readU32(input, data_end + 12) == draft.uncompressed_size)
        {
            range_end = data_end + 16;
            matched = true;
        }
        if (!matched and data_end + 12 <= cd_start and first == draft.crc32 and
            try readU32(input, data_end + 4) == draft.compressed_size and
            try readU32(input, data_end + 8) == draft.uncompressed_size)
        {
            range_end = data_end + 12;
            matched = true;
        }
        if (!matched) return error.InvalidZip;
    }
    return .{
        .metadata = metadata,
        .data_offset = @intCast(data_start),
        .range_end = @intCast(range_end),
    };
}

fn rangeLessThan(_: void, a: Range, b: Range) bool {
    return a.start < b.start;
}

pub const Reader = struct {
    input: []const u8,
    eocd: usize,
    cd_start: usize,
    pos: usize,
    total: u16,
    entry_index: u32 = 0,
    next_file_index: u32 = 0,

    pub fn init(input: []const u8) Error!Reader {
        const eocd = try findEocd(input);
        if (try readU16(input, eocd + 4) != 0 or try readU16(input, eocd + 6) != 0) return error.UnsupportedZip;
        const disk_count = try readU16(input, eocd + 8);
        const total_count = try readU16(input, eocd + 10);
        if (disk_count == 0xffff or total_count == 0xffff) return error.UnsupportedZip;
        if (disk_count != total_count or total_count > MAX_ENTRIES) return error.InvalidZip;
        const cd_size = try readU32(input, eocd + 12);
        const cd_offset = try readU32(input, eocd + 16);
        if (cd_size == 0xffffffff or cd_offset == 0xffffffff) return error.UnsupportedZip;
        const cd_start: usize = cd_offset;
        if (try checkedEnd(cd_start, cd_size, input.len) != eocd) return error.InvalidZip;
        return .{
            .input = input,
            .eocd = eocd,
            .cd_start = cd_start,
            .pos = cd_start,
            .total = total_count,
        };
    }

    pub fn next(self: *Reader) Error!?Entry {
        if (self.entry_index == self.total) return null;
        const input = self.input;
        const pos = self.pos;
        if (try readU32(input, pos) != CENTRAL_SIGNATURE) return error.InvalidZip;
        const made_by = try readU16(input, pos + 4);
        const flags = try readU16(input, pos + 8);
        if ((flags & ~ALLOWED_FLAGS) != 0) return error.UnsupportedZip;
        const method = try readU16(input, pos + 10);
        if (method != METHOD_STORE and method != METHOD_DEFLATE) return error.UnsupportedZip;
        const dos_time = try readU16(input, pos + 12);
        const dos_date = try readU16(input, pos + 14);
        const crc32 = try readU32(input, pos + 16);
        const compressed_size = try readU32(input, pos + 20);
        const uncompressed_size = try readU32(input, pos + 24);
        const name_len: usize = try readU16(input, pos + 28);
        const extra_len: usize = try readU16(input, pos + 30);
        const comment_len: usize = try readU16(input, pos + 32);
        const disk = try readU16(input, pos + 34);
        const external = try readU32(input, pos + 38);
        const local_offset = try readU32(input, pos + 42);
        if (compressed_size == 0xffffffff or uncompressed_size == 0xffffffff or local_offset == 0xffffffff) return error.UnsupportedZip;
        if (disk != 0 or name_len == 0) return error.UnsupportedZip;
        const name_start = try checkedEnd(pos, 46, self.eocd);
        const extra_start = try checkedEnd(name_start, name_len, self.eocd);
        const comment_start = try checkedEnd(extra_start, extra_len, self.eocd);
        self.pos = try checkedEnd(comment_start, comment_len, self.eocd);
        const name = input[name_start..extra_start];
        const central_extra = try parseExtras(input[extra_start..comment_start], name, true);
        const draft = Draft{
            .name = name,
            .central_extra = central_extra,
            .made_by = made_by,
            .external = external,
            .flags = flags,
            .method = method,
            .dos_time = dos_time,
            .dos_date = dos_date,
            .crc32 = crc32,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .local_offset = local_offset,
        };
        const local = try validateLocal(input, self.cd_start, draft);
        const decoded = try decodedPath(name, flags, local.metadata);
        const trailing_separator = decoded[decoded.len - 1] == '/' or decoded[decoded.len - 1] == '\\';
        var path = try normalizePath(decoded);
        const classified = try classify(made_by, external, trailing_separator);
        const kind = classified[0];
        if (kind == .directory) {
            if (uncompressed_size != 0) return error.InvalidZip;
            if (path.len == normalized_name.len) return error.InvalidZip;
            normalized_name[path.len] = '/';
            path = normalized_name[0 .. path.len + 1];
        }
        if (kind == .symlink and uncompressed_size == 0) return error.UnsupportedZip;
        if (method == METHOD_STORE and compressed_size != uncompressed_size) return error.InvalidZip;

        const current_entry = self.entry_index;
        self.entry_index += 1;
        const file_index = if (kind == .regular) blk: {
            const value = self.next_file_index;
            self.next_file_index += 1;
            break :blk value;
        } else null;
        ranges[current_entry] = .{ .start = local_offset, .end = local.range_end };
        return .{
            .entry_index = current_entry,
            .file_index = file_index,
            .path = path,
            .kind = kind,
            .method = method,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .mode = classified[1],
            .mtime = local.metadata.mtime orelse try dosTimestamp(dos_date, dos_time),
            .uid = local.metadata.uid orelse 0,
            .gid = local.metadata.gid orelse 0,
            .crc32 = crc32,
            .data_offset = local.data_offset,
        };
    }

    pub fn finish(self: *Reader) Error!void {
        if (self.entry_index != self.total or self.pos != self.eocd) return error.InvalidZip;
        const used = ranges[0..self.total];
        std.sort.block(Range, used, {}, rangeLessThan);
        var previous_end: u32 = 0;
        for (used) |range| {
            if (range.start < previous_end) return error.InvalidZip;
            previous_end = range.end;
        }
    }
};

pub fn extractPayload(input: []const u8, entry: Entry, output: []u8) Error!void {
    if (output.len != entry.uncompressed_size) return error.InvalidZip;
    const compressed = input[entry.data_offset..][0..entry.compressed_size];
    if (entry.method == METHOD_STORE) {
        @memcpy(output, compressed);
        if (std.hash.Crc32.hash(output) != entry.crc32) return error.InvalidZip;
    } else {
        const result = inflate.inflateRawExact(compressed, output) orelse return error.InvalidZip;
        if (result.length != entry.uncompressed_size or result.crc32 != entry.crc32) return error.InvalidZip;
    }
}

pub fn extractBody(input: []const u8, entry: Entry, output: []u8) Error!void {
    if (entry.kind != .regular) return error.InvalidZip;
    try extractPayload(input, entry, output);
}

test "normalizes paths and assigns file indices independently" {
    try std.testing.expectEqualStrings("a/c", try normalizePath("a\\b/../c"));
    try std.testing.expectError(error.UnsafePath, normalizePath("../escape"));
}
