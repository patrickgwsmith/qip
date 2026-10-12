//! Lists the local time types of an RFC 9636 TZif file (`application/tzif`) as
//! CSV, one row per transition. Version 1 files use the 32-bit data block;
//! version 2 and later files use the 64-bit data block and skip the version 1
//! block. The first row has empty `time`, `utc`, and `local` fields and gives
//! time type 0, which applies before the first transition. The footer TZ
//! string, which describes times after the last transition, is checked for
//! framing but is not output.
//!
//! Output columns:
//!
//!     time,utc,local,utoff,isdst,abbreviation,type
//!
//! `time` is seconds since 1970-01-01T00:00:00Z. `utc` and `local` use the
//! proleptic Gregorian calendar; `local` carries the UT offset as `+HH:MM`, or
//! `+HH:MM:SS` when the offset has seconds.
//!
//! Rejected input reports the byte offset of the field that failed:
//!
//! - a bad magic, version, or count, or a block that does not fit the input;
//! - leap-second records, which belong to `application/tzif-leap`;
//! - transition times that do not increase, or a type index out of range;
//! - a UT offset of -2^31, an isdst value other than 0 or 1, or a UT
//!   indicator set without its standard/wall indicator;
//! - a designation without a NUL, longer than 16 bytes, or outside printable
//!   ASCII; and
//! - a missing footer, or any byte after the end of the file structure.

const INPUT_CONTENT_TYPE = "application/tzif";
const OUTPUT_CONTENT_TYPE = "text/csv";

const INPUT_CAP: usize = 256 * 1024;
const HEADER_SIZE: usize = 44;
const ABBREVIATION_MAX: usize = 16;

const CSV_HEADER = "time,utc,local,utoff,isdst,abbreviation,type\n";

// Widest field values: i64 seconds; a 12-digit signed year plus
// "-MM-DDTHH:MM:SSZ"; the same local date plus a "+596523:14:07" offset; an
// i32 offset; one isdst digit; a fully quoted designation; and a u8 type.
const TIME_FIELD_CAP: usize = 20;
const YEAR_FIELD_CAP: usize = 13;
const UTC_FIELD_CAP: usize = YEAR_FIELD_CAP + "-MM-DDTHH:MM:SSZ".len;
const LOCAL_FIELD_CAP: usize = YEAR_FIELD_CAP + "-MM-DDTHH:MM:SS".len + "+596523:14:07".len;
const UTOFF_FIELD_CAP: usize = 11;
const ABBREVIATION_FIELD_CAP: usize = 2 + 2 * ABBREVIATION_MAX;
const TYPE_FIELD_CAP: usize = 3;
const ROW_CAP: usize = TIME_FIELD_CAP + UTC_FIELD_CAP + LOCAL_FIELD_CAP + UTOFF_FIELD_CAP + 1 + ABBREVIATION_FIELD_CAP + TYPE_FIELD_CAP + ",,,,,,\n".len;

// Every transition costs at least five input bytes (a 32-bit time and a type
// index), and the header comes first, so this bounds the transition count.
const MAX_TRANSITIONS: usize = (INPUT_CAP - HEADER_SIZE) / 5;
const OUTPUT_CAP: usize = CSV_HEADER.len + (MAX_TRANSITIONS + 1) * ROW_CAP;

comptime {
    if (OUTPUT_CAP > 0x7fff_ffff) @compileError("OUTPUT_CAP does not fit the ABI");
}

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_utf8_cap() u32 {
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

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

const Header = struct {
    version: u8,
    isutcnt: usize,
    isstdcnt: usize,
    leapcnt: usize,
    timecnt: usize,
    typecnt: usize,
    charcnt: usize,
};

// A located data block. Offsets are absolute input offsets.
const Block = struct {
    header_offset: usize,
    time_size: usize,
    times: usize,
    indices: usize,
    types: usize,
    chars: usize,
    isstd: usize,
    isut: usize,
    end: usize,
    header: Header,
};

fn readU32(input: []const u8, offset: usize) u32 {
    return @as(u32, input[offset]) << 24 | @as(u32, input[offset + 1]) << 16 |
        @as(u32, input[offset + 2]) << 8 | @as(u32, input[offset + 3]);
}

fn readI32(input: []const u8, offset: usize) i32 {
    return @bitCast(readU32(input, offset));
}

fn readI64(input: []const u8, offset: usize) i64 {
    const high: u64 = readU32(input, offset);
    const low: u64 = readU32(input, offset + 4);
    return @bitCast(high << 32 | low);
}

fn readTime(input: []const u8, block: *const Block, index: usize) i64 {
    const offset = block.times + index * block.time_size;
    return if (block.time_size == 8) readI64(input, offset) else readI32(input, offset);
}

// Locates the header at `header_offset` and its data block. Returns the
// offset of the first bad field, or null after filling `block`.
fn locateBlock(input: []const u8, header_offset: usize, time_size: usize, block: *Block) ?usize {
    if (input.len - header_offset < HEADER_SIZE) return input.len;
    if (!eql(input[header_offset..][0..4], "TZif")) return header_offset;
    const version = input[header_offset + 4];
    if (version != 0 and version < '2') return header_offset + 4;

    const counts = header_offset + 20;
    const header: Header = .{
        .isutcnt = readU32(input, counts),
        .isstdcnt = readU32(input, counts + 4),
        .leapcnt = readU32(input, counts + 8),
        .timecnt = readU32(input, counts + 12),
        .typecnt = readU32(input, counts + 16),
        .charcnt = readU32(input, counts + 20),
        .version = version,
    };
    if (header.isutcnt != 0 and header.isutcnt != header.typecnt) return counts;
    if (header.isstdcnt != 0 and header.isstdcnt != header.typecnt) return counts + 4;
    if (header.typecnt == 0 or header.typecnt > 256) return counts + 16;
    if (header.charcnt == 0) return counts + 20;

    // Each count is below 2^32, so this u64 sum cannot overflow.
    const size: u64 = @as(u64, header.timecnt) * (time_size + 1) +
        @as(u64, header.typecnt) * 6 + header.charcnt +
        @as(u64, header.leapcnt) * (time_size + 4) + header.isstdcnt + header.isutcnt;
    const data = header_offset + HEADER_SIZE;
    if (size > input.len - data) return counts + 12;

    const times = data;
    const indices = times + header.timecnt * time_size;
    const types = indices + header.timecnt;
    const chars = types + header.typecnt * 6;
    const leaps = chars + header.charcnt;
    const isstd = leaps + header.leapcnt * (time_size + 4);
    const isut = isstd + header.isstdcnt;
    block.* = .{
        .header_offset = header_offset,
        .time_size = time_size,
        .times = times,
        .indices = indices,
        .types = types,
        .chars = chars,
        .isstd = isstd,
        .isut = isut,
        .end = isut + header.isutcnt,
        .header = header,
    };
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// Returns the offset of the first bad field in the block's records.
fn validateBlock(input: []const u8, block: *const Block) ?usize {
    const header = &block.header;
    if (header.leapcnt != 0) return block.header_offset + 28;

    var i: usize = 0;
    while (i < header.timecnt) : (i += 1) {
        if (i > 0 and readTime(input, block, i) <= readTime(input, block, i - 1))
            return block.times + i * block.time_size;
        if (input[block.indices + i] >= header.typecnt) return block.indices + i;
    }

    i = 0;
    while (i < header.typecnt) : (i += 1) {
        const record = block.types + i * 6;
        if (readI32(input, record) == -2147483647 - 1) return record;
        if (input[record + 4] > 1) return record + 4;
        const desigidx: usize = input[record + 5];
        if (desigidx >= header.charcnt) return record + 5;
        var end = block.chars + desigidx;
        const limit = block.chars + header.charcnt;
        while (end < limit and input[end] != 0) : (end += 1) {
            if (input[end] < 0x20 or input[end] > 0x7e) return end;
            if (end - (block.chars + desigidx) >= ABBREVIATION_MAX) return end;
        }
        if (end == limit) return record + 5;
        if (header.isutcnt != 0 and input[block.isut + i] > 1) return block.isut + i;
        if (header.isstdcnt != 0 and input[block.isstd + i] > 1) return block.isstd + i;
        if (header.isutcnt != 0 and input[block.isut + i] == 1 and
            (header.isstdcnt == 0 or input[block.isstd + i] != 1)) return block.isut + i;
    }
    return null;
}

// Checks the "\nTZ string\n" footer that starts at `start` and ends the
// input. Returns the offset of the first bad byte.
fn validateFooter(input: []const u8, start: usize) ?usize {
    if (start >= input.len or input[start] != '\n') return start;
    const stop = start + 1 + printableLen(input[start + 1 ..]);
    if (stop == input.len) return input.len;
    if (input[stop] != '\n') return stop;
    return if (stop + 1 == input.len) null else stop + 1;
}

// Returns the length of the printable ASCII run that starts `bytes`. Kept
// out of line so the loop's only exit is the scan stopping, which the loop
// verifier can prove; inlined, LLVM threads the caller's checks into it.
noinline fn printableLen(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x7e) : (i += 1) {}
    return i;
}

// Fills `block` with the data block to list. Returns the offset of the first
// bad field.
fn parse(input: []const u8, block: *Block) ?usize {
    if (locateBlock(input, 0, 4, block)) |offset| return offset;
    if (block.header.version == 0) {
        if (validateBlock(input, block)) |offset| return offset;
        return if (block.end == input.len) null else block.end;
    }
    if (locateBlock(input, block.end, 8, block)) |offset| return offset;
    if (validateFooter(input, block.end)) |offset| return offset;
    return validateBlock(input, block);
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(w: *Writer, value: u8) void {
        if (w.len >= w.buf.len) @trap();
        w.buf[w.len] = value;
        w.len += 1;
    }

    fn bytes(w: *Writer, values: []const u8) void {
        for (values) |value| w.byte(value);
    }

    fn unsigned(w: *Writer, value: u64, minimum_digits: usize) void {
        var digits: [20]u8 = undefined;
        var start = digits.len;
        var remaining = value;
        while (remaining != 0 or digits.len - start < @max(minimum_digits, 1)) {
            start -= 1;
            digits[start] = '0' + @as(u8, @intCast(remaining % 10));
            remaining /= 10;
        }
        w.bytes(digits[start..]);
    }

    fn signed(w: *Writer, value: i64, minimum_digits: usize) void {
        if (value < 0) w.byte('-');
        w.unsigned(@abs(value), minimum_digits);
    }
};

const Civil = struct { year: i64, month: u8, day: u8 };

// Howard Hinnant's days_from_civil inverse, valid for every i64 day count
// that comes from dividing an i64 second count by 86400.
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = yoe + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

// Writes the date and time of `days` and `seconds_of_day` without a zone.
fn writeDateTime(w: *Writer, days: i64, seconds_of_day: i64) void {
    const civil = civilFromDays(days);
    w.signed(civil.year, 4);
    w.byte('-');
    w.unsigned(civil.month, 2);
    w.byte('-');
    w.unsigned(civil.day, 2);
    w.byte('T');
    const s: u64 = @intCast(seconds_of_day);
    w.unsigned(s / 3600, 2);
    w.byte(':');
    w.unsigned(s / 60 % 60, 2);
    w.byte(':');
    w.unsigned(s % 60, 2);
}

fn writeOffset(w: *Writer, utoff: i32) void {
    w.byte(if (utoff < 0) '-' else '+');
    const magnitude: u64 = @abs(utoff);
    w.unsigned(magnitude / 3600, 2);
    w.byte(':');
    w.unsigned(magnitude / 60 % 60, 2);
    if (magnitude % 60 != 0) {
        w.byte(':');
        w.unsigned(magnitude % 60, 2);
    }
}

fn writeRow(w: *Writer, input: []const u8, block: *const Block, time: ?i64, type_index: u8) void {
    const record = block.types + @as(usize, type_index) * 6;
    const utoff = readI32(input, record);
    if (time) |t| {
        w.signed(t, 1);
        w.byte(',');
        const days = @divFloor(t, 86400);
        const seconds = @mod(t, 86400);
        writeDateTime(w, days, seconds);
        w.byte('Z');
        w.byte(',');
        // Shift by the offset in the seconds-of-day domain so that the sum
        // cannot overflow i64 near the ends of the time range.
        const local_seconds = seconds + utoff;
        writeDateTime(w, days + @divFloor(local_seconds, 86400), @mod(local_seconds, 86400));
        writeOffset(w, utoff);
    } else {
        w.bytes(",,");
    }
    w.byte(',');
    w.signed(utoff, 1);
    w.byte(',');
    w.byte('0' + input[record + 4]);
    w.byte(',');

    const start = block.chars + input[record + 5];
    var end = start;
    var needs_quotes = false;
    while (input[end] != 0) : (end += 1) {
        if (input[end] == ',' or input[end] == '"') needs_quotes = true;
    }
    if (needs_quotes) {
        w.byte('"');
        for (input[start..end]) |c| {
            if (c == '"') w.byte('"');
            w.byte(c);
        }
        w.byte('"');
    } else {
        w.bytes(input[start..end]);
    }
    w.byte(',');
    w.unsigned(type_index, 1);
    w.byte('\n');
}

fn renderOutcome(input_size: u32) RenderOutcome {
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];
    var block: Block = undefined;
    if (parse(input, &block)) |offset| return .{
        .output_size_or_failure = @intCast(offset),
        .output_ptr = 0,
        .failed = 1,
    };
    return .{
        .output_size_or_failure = @intCast(writeCsv(input, &block, &output_buf)),
        .output_ptr = @intFromPtr(&output_buf),
        .failed = 0,
    };
}

fn writeCsv(input: []const u8, block: *const Block, output: []u8) usize {
    var w: Writer = .{ .buf = output };
    w.bytes(CSV_HEADER);
    writeRow(&w, input, block, null, 0);
    var i: usize = 0;
    while (i < block.header.timecnt) : (i += 1) {
        writeRow(&w, input, block, readTime(input, block, i), input[block.indices + i]);
    }
    return w.len;
}

export fn render(input_size: u32) RenderResult {
    const outcome = renderOutcome(input_size);
    return .{
        .output_size_or_failure = outcome.output_size_or_failure,
        .output_ptr = if (outcome.failed == 1) 0 else @intCast(outcome.output_ptr),
        .failed = outcome.failed,
    };
}

const std = @import("std");

const TestType = struct { utoff: i32, isdst: u8, desigidx: u8 };

const TestZone = struct {
    times: []const i64,
    indices: []const u8,
    types: []const TestType,
    chars: []const u8,
    isstd: []const u8 = &.{},
    isut: []const u8 = &.{},
    leapcnt: u32 = 0,
};

fn appendBe(list: *std.ArrayList(u8), value: u64, size: usize) !void {
    var i = size;
    while (i > 0) {
        i -= 1;
        try list.append(std.testing.allocator, @truncate(value >> @intCast(i * 8)));
    }
}

fn appendBlock(list: *std.ArrayList(u8), version: u8, zone: TestZone, time_size: usize) !void {
    try list.appendSlice(std.testing.allocator, "TZif");
    try list.append(std.testing.allocator, version);
    try list.appendNTimes(std.testing.allocator, 0, 15);
    for ([_]usize{ zone.isut.len, zone.isstd.len, zone.leapcnt, zone.times.len, zone.types.len, zone.chars.len }) |count|
        try appendBe(list, count, 4);
    for (zone.times) |t| try appendBe(list, @bitCast(t), time_size);
    try list.appendSlice(std.testing.allocator, zone.indices);
    for (zone.types) |t| {
        try appendBe(list, @as(u32, @bitCast(t.utoff)), 4);
        try list.append(std.testing.allocator, t.isdst);
        try list.append(std.testing.allocator, t.desigidx);
    }
    try list.appendSlice(std.testing.allocator, zone.chars);
    try list.appendNTimes(std.testing.allocator, 0, zone.leapcnt * (time_size + 4));
    try list.appendSlice(std.testing.allocator, zone.isstd);
    try list.appendSlice(std.testing.allocator, zone.isut);
}

fn makeV2(zone: TestZone, footer: []const u8) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(std.testing.allocator);
    try appendBlock(&list, '2', .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 0 }}, .chars = "\x00" }, 4);
    try appendBlock(&list, '2', zone, 8);
    try list.appendSlice(std.testing.allocator, footer);
    return list;
}

const new_york: TestZone = .{
    .times = &.{ -2717650800, 1710054000, 1730613600 },
    .indices = &.{ 2, 1, 2 },
    .types = &.{
        .{ .utoff = -17762, .isdst = 0, .desigidx = 0 },
        .{ .utoff = -14400, .isdst = 1, .desigidx = 4 },
        .{ .utoff = -18000, .isdst = 0, .desigidx = 8 },
    },
    .chars = "LMT\x00EDT\x00EST\x00",
    .isstd = &.{ 0, 0, 0 },
    .isut = &.{ 0, 0, 0 },
};

fn renderTest(bytes: []const u8) RenderOutcome {
    @memcpy(input_buf[0..bytes.len], bytes);
    return renderOutcome(@intCast(bytes.len));
}

test "lists version 2 transitions with UTC and local times" {
    var file = try makeV2(new_york, "\nEST5EDT,M3.2.0,M11.1.0\n");
    defer file.deinit(std.testing.allocator);
    const outcome = renderTest(file.items);
    try std.testing.expectEqual(@as(u1, 0), outcome.failed);
    try std.testing.expectEqualStrings(
        CSV_HEADER ++
            ",,,-17762,0,LMT,0\n" ++
            "-2717650800,1883-11-18T17:00:00Z,1883-11-18T12:00:00-05:00,-18000,0,EST,2\n" ++
            "1710054000,2024-03-10T07:00:00Z,2024-03-10T03:00:00-04:00,-14400,1,EDT,1\n" ++
            "1730613600,2024-11-03T06:00:00Z,2024-11-03T01:00:00-05:00,-18000,0,EST,2\n",
        output_buf[0..outcome.output_size_or_failure],
    );
}

test "reads version 1 files and offsets with seconds" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendBlock(&list, 0, .{
        .times = &.{-1},
        .indices = &.{1},
        .types = &.{ .{ .utoff = 19800 + 61, .isdst = 0, .desigidx = 0 }, .{ .utoff = 0, .isdst = 0, .desigidx = 5 } },
        .chars = "A,\"B\x00UTC\x00",
    }, 4);
    const outcome = renderTest(list.items);
    try std.testing.expectEqual(@as(u1, 0), outcome.failed);
    try std.testing.expectEqualStrings(
        CSV_HEADER ++
            ",,,19861,0,\"A,\"\"B\",0\n" ++
            "-1,1969-12-31T23:59:59Z,1969-12-31T23:59:59+00:00,0,0,UTC,1\n",
        output_buf[0..outcome.output_size_or_failure],
    );
}

test "formats the ends of the 64-bit time range" {
    var file = try makeV2(.{
        .times = &.{ std.math.minInt(i64), std.math.maxInt(i64) },
        .indices = &.{ 0, 1 },
        .types = &.{ .{ .utoff = -2147483647, .isdst = 0, .desigidx = 0 }, .{ .utoff = 2147483647, .isdst = 1, .desigidx = 0 } },
        .chars = "ABCDEFGHIJKLMNOP\x00",
    }, "\n\n");
    defer file.deinit(std.testing.allocator);
    const outcome = renderTest(file.items);
    try std.testing.expectEqual(@as(u1, 0), outcome.failed);
    const csv = output_buf[0..outcome.output_size_or_failure];
    try std.testing.expect(std.mem.indexOf(u8, csv, "-9223372036854775808,-292277022657-01-27T08:29:52Z,-292277022725-01-08T05:15:45-596523:14:07,") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "9223372036854775807,292277026596-12-04T15:30:07Z,292277026664-12-23T18:44:14+596523:14:07,") != null);
    var lines = std.mem.splitScalar(u8, csv, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len + 1 <= ROW_CAP);
}

test "rejects malformed files at the failing offset" {
    const Case = struct { zone: TestZone, footer: []const u8 = "\n\n", offset: usize };
    const second = 44 + 6 + 1; // The second header follows the minimal v1 block.
    const data = second + 44;
    const footer_start = data + 8 * 3 + 3 + 6 * 3 + new_york.chars.len + 3 + 3;
    const cases = [_]Case{
        .{ .zone = new_york, .footer = "\nEST5EDT", .offset = footer_start + 8 },
        .{ .zone = new_york, .footer = "EST5EDT\n", .offset = footer_start },
        .{ .zone = new_york, .footer = "\n\x01\n", .offset = footer_start + 1 },
        .{ .zone = new_york, .footer = "\n\nX", .offset = footer_start + 2 },
        .{ .zone = .{ .times = &.{ 2, 2 }, .indices = &.{ 0, 0 }, .types = new_york.types, .chars = new_york.chars }, .offset = data + 8 },
        .{ .zone = .{ .times = &.{1}, .indices = &.{3}, .types = new_york.types, .chars = new_york.chars }, .offset = data + 8 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 2, .desigidx = 0 }}, .chars = "UTC\x00" }, .offset = data + 4 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 4 }}, .chars = "UTC\x00" }, .offset = data + 5 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 0 }}, .chars = "UTC" }, .offset = data + 5 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 0 }}, .chars = "U\xc3\xa9\x00" }, .offset = data + 7 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 0 }}, .chars = "ABCDEFGHIJKLMNOPQ\x00" }, .offset = data + 6 + 16 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = std.math.minInt(i32), .isdst = 0, .desigidx = 0 }}, .chars = "UTC\x00" }, .offset = data },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 0 }}, .chars = "UTC\x00", .isstd = &.{0}, .isut = &.{1} }, .offset = data + 6 + 4 + 1 },
        .{ .zone = .{ .times = &.{}, .indices = &.{}, .types = &.{.{ .utoff = 0, .isdst = 0, .desigidx = 0 }}, .chars = "UTC\x00", .leapcnt = 1 }, .offset = second + 28 },
    };
    for (cases, 0..) |case, i| {
        var file = try makeV2(case.zone, case.footer);
        defer file.deinit(std.testing.allocator);
        const outcome = renderTest(file.items);
        errdefer std.debug.print("case {d}\n", .{i});
        try std.testing.expectEqual(@as(u1, 1), outcome.failed);
        try std.testing.expectEqual(case.offset, outcome.output_size_or_failure);
    }

    const bad_magic = renderTest("TZiX" ++ "\x00" ** 40);
    try std.testing.expectEqual(@as(u32, 0), bad_magic.output_size_or_failure);
    const short = renderTest("TZif2");
    try std.testing.expectEqual(@as(u32, 5), short.output_size_or_failure);
    const version_one = renderTest("TZif1" ++ "\x00" ** 39);
    try std.testing.expectEqual(@as(u32, 4), version_one.output_size_or_failure);

    // A rejected call does not leave state behind for the next call.
    var file = try makeV2(new_york, "\n\n");
    defer file.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u1, 0), renderTest(file.items).failed);
}
