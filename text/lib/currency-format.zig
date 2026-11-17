// Shared exact-decimal currency formatter for the per-locale
// text/currency-format-*.zig components.
//
// Each locale component instantiates Formatter with its CLDR table and
// separators. Everything locale-specific is comptime, so every module only
// carries the code paths and data its locale needs.
//
// Input is one exact ASCII decimal: -?[0-9]+(\.[0-9]+)? with at most 96
// integer digits. Currency is selected by ISO 4217 numeric code and resets to
// the default after every render. Rounding is half away from zero. Invalid
// input and unsupported currencies trap.

pub const Grouping = enum {
    // 1,234,567
    thousands,
    // 12,34,567
    indian,
    // 1234 but 12.345: CLDR minimumGroupingDigits = 2
    thousands_min_five_digits,
};

pub const Digits = enum { ascii, arabic_indic };

pub const Locale = struct {
    // A table module declaring `currencies`, sorted by numeric code, whose
    // entries have `numeric`, `fraction_digits`, and either `prefix` or `suffix`.
    table: type,
    group: []const u8,
    decimal: []const u8,
    grouping: Grouping = .thousands,
    digits: Digits = .ascii,
    negative: []const u8 = "-",
    positive: []const u8 = "",
    default_numeric: u32 = 840,
};

const NBSP = "\xC2\xA0";
pub const INPUT_CAP: usize = 128;
const MAX_INTEGER_DIGITS: usize = 96;

pub fn Formatter(comptime locale: Locale) type {
    const currencies = locale.table.currencies;
    const Entry = @TypeOf(currencies[0]);
    const affix_is_prefix = @hasField(Entry, "prefix");

    return struct {
        fn affixOf(currency: Entry) []const u8 {
            return if (affix_is_prefix) currency.prefix else currency.suffix;
        }

        // Most affixes are the ISO alphabetic code joined to the number by a
        // non-breaking space. Those store only their three letters.
        fn standardLetters(currency: Entry) ?[]const u8 {
            const affix = affixOf(currency);
            if (affix.len != 5) return null;
            const letters = if (affix_is_prefix) affix[0..3] else affix[2..5];
            const space = if (affix_is_prefix) affix[3..5] else affix[0..2];
            if (!bytesEqual(space, NBSP)) return null;
            for (letters) |byte| if (byte < 'A' or byte > 'Z') return null;
            return letters;
        }

        fn bytesEqual(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (x != y) return false;
            return true;
        }

        // The table is one byte stream of records in numeric order:
        //   entry:  numeric delta << 3 | custom << 2 | fraction digits
        //   affix:  three ASCII letters, or when custom a length byte and
        //           that many affix bytes
        const stream_len: usize = blk: {
            @setEvalBranchQuota(100_000);
            var total: usize = 0;
            for (currencies) |currency| {
                total += if (standardLetters(currency) != null) 4 else 2 + affixOf(currency).len;
            }
            break :blk total;
        };

        const stream: [stream_len]u8 = blk: {
            @setEvalBranchQuota(100_000);
            var result: [stream_len]u8 = undefined;
            var previous: u32 = 0;
            var at: usize = 0;
            for (currencies, 0..) |currency, index| {
                const delta = currency.numeric - previous;
                if (currency.numeric <= previous and index > 0) @compileError("currency table must be sorted and unique");
                if (delta == 0 or delta > 31) @compileError("numeric delta must fit five bits");
                if (currency.fraction_digits > 3) @compileError("fraction digits must fit two bits");
                previous = currency.numeric;
                var custom_flag: u8 = 0;
                var body: []const u8 = undefined;
                if (standardLetters(currency)) |letters| {
                    body = letters;
                } else {
                    const affix = affixOf(currency);
                    if (affix.len > 255) @compileError("affix too long");
                    body = [_]u8{affix.len} ++ affix;
                    custom_flag = 4;
                }
                result[at] = @as(u8, delta) << 3 | custom_flag | currency.fraction_digits;
                @memcpy(result[at + 1 .. at + 1 + body.len], body);
                at += 1 + body.len;
            }
            break :blk result;
        };

        // Affixes are copied as one block of whole 8-byte words.
        const affix_block: usize = blk: {
            @setEvalBranchQuota(100_000);
            var longest: usize = 3;
            for (currencies) |currency| {
                if (standardLetters(currency) == null) longest = @max(longest, affixOf(currency).len);
            }
            break :blk (longest + 7) / 8 * 8;
        };

        // Worst case: sign, affix, 97 integer digits (96 plus a rounding
        // carry) with every separator, then the decimal and three digits.
        const output_cap: usize = blk: {
            @setEvalBranchQuota(100_000);
            const digit_width: usize = if (locale.digits == .arabic_indic) 2 else 1;
            var affix_max: usize = 5;
            for (currencies) |currency| affix_max = @max(affix_max, affixOf(currency).len);
            const integer_max = MAX_INTEGER_DIGITS + 1;
            var groups: usize = 0;
            for (1..integer_max) |index| {
                if (groupBefore(integer_max - index, integer_max)) groups += 1;
            }
            break :blk @max(locale.negative.len, locale.positive.len) + affix_max +
                integer_max * digit_width + groups * locale.group.len +
                locale.decimal.len + 3 * digit_width;
        };

        // io[0] is a spare byte before the input: rounding can carry into
        // it. The four bytes after the input hold a scan sentinel, then
        // zero digits that pad a short fraction.
        var io: [1 + INPUT_CAP + 4]u8 = undefined;
        pub const input_buf: *[INPUT_CAP]u8 = io[1..][0..INPUT_CAP];
        // Block copies may write past the rendered bytes, never past this.
        pub var output_buf: [output_cap + affix_block]u8 = undefined;

        // A found currency: its entry byte (custom flag in bit 2, fraction
        // digits in bits 0-1) in the low byte, and the offset of its record
        // in the stream above that. Zero means the code was not found.
        const Selected = u32;
        const default_selected: Selected = blk: {
            const found = scanIn(&stream, locale.default_numeric);
            if (found == 0) @compileError("default currency missing from table");
            break :blk found;
        };

        // The table and the selection share one struct so the module has a
        // single data segment.
        const State = extern struct {
            stream: [stream_len]u8,
            selected: Selected align(1),
            // Keeps a block copy of the last affix inside the struct.
            slack: [affix_block]u8 = undefined,
        };
        var state: State = .{ .stream = stream, .selected = default_selected };

        pub fn inputPtr() u32 {
            return @intCast(@intFromPtr(input_buf));
        }

        pub fn outputPtr() u32 {
            return @intCast(@intFromPtr(&output_buf));
        }

        // The table is scanned here, not in render, so rendering in the
        // default currency never scans. No scan result is kept between
        // renders: the only state is the selection, which render resets.
        pub fn setCurrency(value: u32) u32 {
            state.selected = scanIn(&state.stream, value);
            return value;
        }

        fn scanIn(table: *const [stream_len]u8, numeric: u32) Selected {
            @setEvalBranchQuota(100_000);
            var current: u32 = 0;
            var at: u32 = 0;
            while (at < stream_len) {
                const entry: u32 = table[at];
                current += entry >> 3;
                if (current == numeric) return entry | at << 8;
                at += if (entry & 4 != 0) 2 + @as(u32, table[at + 1]) else 4;
            }
            return 0;
        }

        fn isDigit(byte: u8) bool {
            return @as(u32, byte) -% '0' < 10;
        }

        inline fn emit(out: *[*]u8, comptime bytes: []const u8) void {
            if (bytes.len == 0) return;
            out.*[0..bytes.len].* = bytes[0..bytes.len].*;
            out.* += bytes.len;
        }

        inline fn emitDigit(out: *[*]u8, digit: u8) void {
            switch (locale.digits) {
                .ascii => {
                    out.*[0] = digit;
                    out.* += 1;
                },
                .arabic_indic => {
                    out.*[0] = 0xd9;
                    out.*[1] = digit +% (0xa0 - '0');
                    out.* += 2;
                },
            }
        }

        inline fn emitAffix(out: *[*]u8, selected: Selected) void {
            var from: [*]const u8 = @as([*]const u8, &state.stream) + (selected >> 8) + 1;
            var len: usize = 3;
            const custom = selected & 4 != 0;
            if (custom) {
                len = from[0];
                from += 1;
            } else if (!affix_is_prefix) emit(out, NBSP);
            // Copies a fixed block and keeps `len` bytes of it: no loop.
            out.*[0..affix_block].* = from[0..affix_block].*;
            out.* += len;
            if (affix_is_prefix and !custom) emit(out, NBSP);
        }

        fn groupBefore(remaining: usize, integer_len: usize) bool {
            return switch (locale.grouping) {
                .thousands => remaining % 3 == 0,
                .indian => remaining >= 3 and remaining & 1 == 1,
                .thousands_min_five_digits => integer_len >= 5 and remaining % 3 == 0,
            };
        }

        // The negative sign as the bytes to add in front of the positive one.
        const negative_extra: []const u8 = blk: {
            const extra = locale.negative.len - locale.positive.len;
            for (locale.positive, locale.negative[extra..]) |a, b| {
                if (a != b) @compileError("negative sign must end with the positive sign");
            }
            break :blk locale.negative[0..extra];
        };

        pub fn render(input_size_in: u32) u32 {
            const selected = state.selected;
            state.selected = default_selected;
            const size: usize = input_size_in;
            if (selected == 0 or size > INPUT_CAP) @trap();
            const fraction_digits: usize = selected & 3;

            const input: [*]u8 = input_buf;
            const end = input + size;
            // A non-digit sentinel ends both digit scans.
            end[0] = 0;

            const negative = input[0] == '-';
            const integer_start = input + @intFromBool(negative);
            var cursor = integer_start;
            while (isDigit(cursor[0])) cursor += 1;
            const integer_end = cursor;
            // Traps on no digits and on more than MAX_INTEGER_DIGITS.
            if (integer_end - integer_start -% 1 >= MAX_INTEGER_DIGITS) @trap();
            var fraction_start = cursor;
            if (cursor[0] == '.') {
                cursor += 1;
                fraction_start = cursor;
                while (isDigit(cursor[0])) cursor += 1;
                if (cursor == fraction_start) @trap();
            }
            if (cursor != end) @trap();

            // Zero digits after the input pad a fraction shorter than the
            // currency's scale. A spare zero before the integer takes any
            // carry out of the top digit.
            end[0..4].* = "0000".*;
            var first = integer_start - 1;
            first[0] = '0';
            const fraction_end = fraction_start + fraction_digits;
            if (fraction_end[0] >= '5') {
                var carry = fraction_end;
                while (true) {
                    carry -= 1;
                    const byte = carry[0];
                    if (byte == '.') continue;
                    if (byte != '9') {
                        carry[0] = byte + 1;
                        break;
                    }
                    carry[0] = '0';
                }
            }
            while (first[0] == '0' and first + 1 != integer_end) first += 1;
            const integer_len = integer_end - first;

            var out: [*]u8 = &output_buf;
            if (negative_extra.len == 1) {
                out[0] = negative_extra[0];
                out += @intFromBool(negative);
            } else if (negative) emit(&out, negative_extra);
            emit(&out, locale.positive);
            if (affix_is_prefix) emitAffix(&out, selected);
            var remaining = integer_len;
            while (true) {
                emitDigit(&out, first[0]);
                first += 1;
                remaining -= 1;
                if (remaining == 0) break;
                if (groupBefore(remaining, integer_len)) emit(&out, locale.group);
            }
            if (fraction_digits > 0) {
                emit(&out, locale.decimal);
                if (locale.digits == .ascii) {
                    // Copies four bytes and keeps `fraction_digits` of them.
                    out[0..4].* = fraction_start[0..4].*;
                    out += fraction_digits;
                } else {
                    var digit = fraction_start;
                    while (digit != fraction_end) : (digit += 1) emitDigit(&out, digit[0]);
                }
            }
            if (!affix_is_prefix) emitAffix(&out, selected);
            return @intCast(out - @as([*]u8, &output_buf));
        }

        pub fn renderResult(input_size_in: u32) RenderResult {
            return .{
                .output_size = render(input_size_in),
                .output_ptr = @intCast(@intFromPtr(&output_buf)),
                .failed = 0,
            };
        }
    };
}

pub const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

// Renders `input` once in `currency`, then again without selecting a currency
// to check the uniform reset to the locale default.
pub fn expectRenders(
    comptime format: type,
    input: []const u8,
    currency: u32,
    expected_selected: []const u8,
    expected_default: []const u8,
) !void {
    const std = @import("std");
    @memcpy(format.input_buf[0..input.len], input);
    _ = format.setCurrency(currency);
    const selected_len = format.render(@intCast(input.len));
    try std.testing.expectEqualStrings(expected_selected, format.output_buf[0..selected_len]);
    const default_len = format.render(@intCast(input.len));
    try std.testing.expectEqualStrings(expected_default, format.output_buf[0..default_len]);
}
