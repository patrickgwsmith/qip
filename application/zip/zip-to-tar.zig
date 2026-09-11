//! Converts a bounded classic ZIP archive into a PAX-compatible ustar
//! archive. Stored entries are copied and raw-DEFLATE entries are decoded
//! directly into their final TAR body, so regular files do not require a
//! whole-entry scratch allocation.
//!
//!     qip run \
//!       -i download.zip \
//!       -o download.tar \
//!       application/zip/zip-to-tar.wasm
//!
//! The converter accepts single-disk ZIP archives with stored or DEFLATE
//! entries, including signed and unsigned data descriptors. It preserves
//! central-directory order, duplicate normalized names, Unix permissions and
//! file types, UID/GID from Info-ZIP Unix extras, extended or DOS modification
//! times, and Unix symbolic links. Names may use UTF-8, the Info-ZIP Unicode
//! Path extra, or CP437. Backslashes become slashes and redundant path
//! components are removed.
//!
//! Output uses ordinary ustar name and prefix fields when they fit. Longer
//! paths and links, or numeric metadata outside the ustar fields, use
//! deterministic `PaxHeaders/qip-NNNNN` extended headers. DOS timestamps are
//! interpreted as UTC so conversion does not depend on the host timezone.
//!
//! The input cap is 128 MiB and the output cap is 160 MiB. Symlink targets are
//! limited to 64 KiB; regular DEFLATE bodies decode directly into the output
//! buffer. Fixed Wasm memory is approximately 320 MiB. Exceeding the output
//! cap traps even for an otherwise valid archive.
//!
//! ZIP64, encryption, split archives, unsupported compression methods,
//! special Unix file types, malformed extras, corrupt checksums, overlapping
//! entry ranges, and unsafe paths reject the complete conversion. Absolute
//! paths, drive-prefixed paths, root-escaping `..`, and symlink targets that
//! resolve outside the archive root are unsafe. Archive and entry comments,
//! unknown well-framed extras, and metadata without a safe TAR equivalent are
//! discarded. Self-extracting archives work only when their recorded offsets
//! are already absolute; the converter does not infer a prepended stub.
//!
//! Benchmark snapshot from `qip bench --benchtime=1s`:
//!
//! - Stored 635,842-byte PNG ZIP: 637,440-byte TAR, 7.33 ms mean.
//! - DEFLATE 8 MiB zero file: 8,362-byte ZIP, 8,390,144-byte TAR,
//!   94.73 ms mean.
//! - Mixed application/docs source tree: 553,864-byte ZIP, 3,523,072-byte
//!   TAR, 175.82 ms mean.
//! - Each case used 290.6 MiB peak memory. The stripped Wasm was 47,765 bytes
//!   raw and 18,074 bytes gzipped.
//!
//! These timings include instantiation and are a local regression baseline,
//! not a cross-machine throughput claim. Use this component for conventional
//! download or desktop ZIPs, not ZIP64, encrypted packages, sparse files,
//! device nodes, or workflows that require every ZIP extra field to survive.

const std = @import("std");
const zip = @import("lib/zip.zig");

const TAR_BLOCK: usize = 512;
const MAX_SYMLINK: usize = 64 * 1024;
const OUTPUT_CONTENT_TYPE = "application/x-tar";

var input_buf: [zip.INPUT_CAP]u8 = undefined;
var output_buf: [zip.OUTPUT_CAP]u8 = undefined;
var symlink_scratch: [MAX_SYMLINK]u8 = undefined;
var pax_scratch: [zip.MAX_NAME_UTF8 + MAX_SYMLINK + 512]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(zip.INPUT_CAP);
}

export fn output_bytes_cap() u32 {
    return @intCast(zip.OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(zip.INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(zip.INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

const Kind = enum {
    regular,
    directory,
    symlink,
};

const Output = struct {
    bytes: []u8,
    index: usize = 0,

    fn ensure(self: *const Output, count: usize) zip.Error!void {
        if (count > self.bytes.len - self.index) return error.OutputOverflow;
    }

    fn write(self: *Output, data: []const u8) zip.Error!void {
        try self.ensure(data.len);
        @memcpy(self.bytes[self.index..][0..data.len], data);
        self.index += data.len;
    }

    fn reserve(self: *Output, count: usize) zip.Error![]u8 {
        try self.ensure(count);
        const start = self.index;
        self.index += count;
        return self.bytes[start..self.index];
    }

    fn padBlock(self: *Output, size: usize) zip.Error!void {
        const padding = (TAR_BLOCK - (size % TAR_BLOCK)) % TAR_BLOCK;
        const target = try self.reserve(padding);
        @memset(target, 0);
    }
};

fn decimalDigits(value: u64) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return digits;
}

fn decimalText(buffer: []u8, value: u64) zip.Error![]const u8 {
    const length = decimalDigits(value);
    if (length > buffer.len) return error.OutputOverflow;

    var remaining = value;
    var pos = length;
    while (pos != 0) {
        pos -= 1;
        const digit: u8 = @intCast(remaining % 10);
        buffer[pos] = '0' + digit;
        remaining /= 10;
    }
    return buffer[0..length];
}

fn appendDecimal(out: []u8, index: *usize, value: u64) zip.Error!void {
    var digits: [20]u8 = undefined;
    const text = try decimalText(&digits, value);
    if (text.len > out.len - index.*) return error.OutputOverflow;
    @memcpy(out[index.*..][0..text.len], text);
    index.* += text.len;
}

fn paxRecordLength(key: []const u8, value: []const u8) usize {
    var length = 1 + key.len + 1 + value.len + 1;
    while (true) {
        const digits = decimalDigits(length);
        const next = digits + 1 + key.len + 1 + value.len + 1;
        if (next == length) return length;
        length = next;
    }
}

fn appendPaxRecord(out: []u8, index: *usize, key: []const u8, value: []const u8) zip.Error!void {
    const length = paxRecordLength(key, value);
    try appendDecimal(out, index, length);
    if (1 + key.len + 1 + value.len + 1 > out.len - index.*) return error.OutputOverflow;
    out[index.*] = ' ';
    index.* += 1;
    @memcpy(out[index.*..][0..key.len], key);
    index.* += key.len;
    out[index.*] = '=';
    index.* += 1;
    @memcpy(out[index.*..][0..value.len], value);
    index.* += value.len;
    out[index.*] = '\n';
    index.* += 1;
}

fn writeOctal(field: []u8, value: u64) bool {
    if (field.len < 2) return false;
    @memset(field, '0');
    field[field.len - 1] = 0;
    var remaining = value;
    var pos = field.len - 1;
    while (remaining != 0) {
        if (pos == 0) return false;
        pos -= 1;
        field[pos] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
    }
    return true;
}

fn putName(header: []u8, path: []const u8) bool {
    if (path.len <= 100) {
        @memcpy(header[0..path.len], path);
        return true;
    }
    var split = path.len;
    while (split != 0) {
        split -= 1;
        if (path[split] != '/') continue;
        const prefix = path[0..split];
        const name = path[split + 1 ..];
        if (prefix.len <= 155 and name.len != 0 and name.len <= 100) {
            @memcpy(header[0..name.len], name);
            @memcpy(header[345..][0..prefix.len], prefix);
            return true;
        }
    }
    return false;
}

fn tarHeader(
    destination: []u8,
    path: []const u8,
    fallback_name: []const u8,
    mode: u16,
    uid: u64,
    gid: u64,
    size: u64,
    mtime: u64,
    kind: Kind,
    link: []const u8,
) zip.Error!void {
    if (destination.len != TAR_BLOCK) return error.OutputOverflow;
    @memset(destination, 0);
    if (!putName(destination, path) and !putName(destination, fallback_name)) return error.OutputOverflow;
    if (!writeOctal(destination[100..108], mode) or
        !writeOctal(destination[108..116], uid) or
        !writeOctal(destination[116..124], gid) or
        !writeOctal(destination[124..136], size) or
        !writeOctal(destination[136..148], mtime)) return error.OutputOverflow;
    @memset(destination[148..156], ' ');
    destination[156] = switch (kind) {
        .regular => '0',
        .directory => '5',
        .symlink => '2',
    };
    if (link.len <= 100) @memcpy(destination[157..][0..link.len], link);
    @memcpy(destination[257..263], "ustar\x00");
    @memcpy(destination[263..265], "00");
    var sum: u64 = 0;
    for (destination) |byte| sum += byte;
    if (!writeOctal(destination[148..155], sum)) return error.OutputOverflow;
    destination[155] = ' ';
}

fn formatPaxName(buffer: []u8, index: usize) zip.Error![]const u8 {
    const prefix = "PaxHeaders/qip-";
    const digits: usize = 5;
    if (index > 99_999 or buffer.len < prefix.len + digits) return error.OutputOverflow;
    @memcpy(buffer[0..prefix.len], prefix);

    var remaining = index;
    var pos = prefix.len + digits;
    while (pos != prefix.len) {
        pos -= 1;
        const digit: u8 = @intCast(remaining % 10);
        buffer[pos] = '0' + digit;
        remaining /= 10;
    }
    return buffer[0 .. prefix.len + digits];
}

fn asciiDrive(component: []const u8) bool {
    return component.len == 2 and component[1] == ':' and
        ((component[0] >= 'a' and component[0] <= 'z') or
            (component[0] >= 'A' and component[0] <= 'Z'));
}

fn safeSymlinkTarget(target: []const u8, parent: []const u8) bool {
    if (target.len == 0 or target[0] == '/' or target[0] == '\\' or
        std.mem.indexOfScalar(u8, target, 0) != null or
        !std.unicode.utf8ValidateSlice(target)) return false;
    if (target.len >= 2 and asciiDrive(target[0..2])) return false;
    var depth: usize = if (parent.len == 0) 0 else 1;
    for (parent) |byte| if (byte == '/') {
        depth += 1;
    };
    var start: usize = 0;
    var pos: usize = 0;
    while (pos <= target.len) : (pos += 1) {
        if (pos != target.len and target[pos] != '/' and target[pos] != '\\') continue;
        const component = target[start..pos];
        start = pos + 1;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return false;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return true;
}

fn emitEntry(out: *Output, input: []const u8, entry: zip.Entry, index: usize) zip.Error!void {
    const path = entry.path;
    var link: []u8 = symlink_scratch[0..0];
    if (entry.kind == .symlink) {
        if (entry.uncompressed_size > symlink_scratch.len) return error.UnsupportedZip;
        link = symlink_scratch[0..entry.uncompressed_size];
        try zip.extractPayload(input, entry, link);
        const parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const parent = if (parent_end == 0) "" else path[0..parent_end];
        if (!safeSymlinkTarget(link, parent)) return error.UnsafePath;
    } else if (entry.kind == .directory) {
        try zip.extractPayload(input, entry, symlink_scratch[0..0]);
    }

    var probe: [512]u8 = undefined;
    @memset(&probe, 0);
    const path_fits = putName(&probe, path);
    const link_fits = link.len <= 100;
    const uid_fits = entry.uid <= 0o7777777;
    const gid_fits = entry.gid <= 0o7777777;
    const mtime_fits = entry.mtime <= 0o77777777777;
    const need_pax = !path_fits or !link_fits or !uid_fits or !gid_fits or !mtime_fits;
    var pax_name_buf: [32]u8 = undefined;
    const pax_name = try formatPaxName(&pax_name_buf, index);
    const tar_kind: Kind = switch (entry.kind) {
        .regular => .regular,
        .directory => .directory,
        .symlink => .symlink,
    };

    if (need_pax) {
        var pax_len: usize = 0;
        if (!path_fits) try appendPaxRecord(&pax_scratch, &pax_len, "path", path);
        if (!link_fits) try appendPaxRecord(&pax_scratch, &pax_len, "linkpath", link);
        var number: [20]u8 = undefined;
        if (!mtime_fits) {
            const text = try decimalText(&number, entry.mtime);
            try appendPaxRecord(&pax_scratch, &pax_len, "mtime", text);
        }
        if (!uid_fits) {
            const text = try decimalText(&number, entry.uid);
            try appendPaxRecord(&pax_scratch, &pax_len, "uid", text);
        }
        if (!gid_fits) {
            const text = try decimalText(&number, entry.gid);
            try appendPaxRecord(&pax_scratch, &pax_len, "gid", text);
        }
        const header = try out.reserve(TAR_BLOCK);
        try tarHeader(header, pax_name, pax_name, 0o644, 0, 0, pax_len, entry.mtime, .regular, "");
        header[156] = 'x';
        @memset(header[148..156], ' ');
        var sum: u64 = 0;
        for (header) |byte| sum += byte;
        _ = writeOctal(header[148..155], sum);
        header[155] = ' ';
        try out.write(pax_scratch[0..pax_len]);
        try out.padBlock(pax_len);
    }

    const size: usize = if (entry.kind == .regular) entry.uncompressed_size else 0;
    const header = try out.reserve(TAR_BLOCK);
    try tarHeader(
        header,
        path,
        pax_name,
        entry.mode,
        if (uid_fits) entry.uid else 0,
        if (gid_fits) entry.gid else 0,
        size,
        if (mtime_fits) entry.mtime else 0,
        tar_kind,
        if (link_fits) link else "",
    );
    if (entry.kind == .regular) {
        const body = try out.reserve(size);
        try zip.extractBody(input, entry, body);
        try out.padBlock(size);
    }
}

fn convert(input: []const u8, output: []u8) zip.Error!usize {
    var out = Output{ .bytes = output };
    var reader = try zip.Reader.init(input);
    var index: usize = 0;
    while (try reader.next()) |entry| {
        try emitEntry(&out, input, entry, index);
        index += 1;
    }
    try reader.finish();
    const ending = try out.reserve(2 * TAR_BLOCK);
    @memset(ending, 0);
    return out.index;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > zip.INPUT_CAP) @trap();
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
