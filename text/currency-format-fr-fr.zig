// Format one exact ASCII decimal using fr-FR currency conventions.
// Currency is selected with uniform_set_currency using its ISO 4217 numeric
// code. USD (840) is the default. Unsupported codes and invalid input trap.
const INPUT_CAP: usize = 128;
const OUTPUT_CAP: usize = 144;
const MAX_INTEGER_DIGITS: usize = 96;
const DEFAULT_CURRENCY_NUMERIC: u32 = 840;
const currency_data = @import("lib/currency-format-fr-fr-table.zig");

// The source table stays readable while the emitted representation fits each
// lookup entry in one u32. Most fr-FR suffixes are a non-breaking space plus
// the alphabetic code, so those three letters live directly in the entry. Only
// exceptional display suffixes occupy the concatenated byte array.
const PackedCurrency = packed struct(u32) {
    numeric: u10,
    fraction_digits: u2,
    suffix_payload: u15,
    suffix_len: u4,
    has_custom_suffix: bool,
};

fn hasAlphabeticSuffix(currency: currency_data.Currency) bool {
    if (currency.suffix.len != 5) return false;
    if (currency.suffix[0] != 0xc2 or currency.suffix[1] != 0xa0) return false;
    for (currency.suffix[2..5]) |byte| {
        if (byte < 'A' or byte > 'Z') return false;
    }
    return true;
}

fn packedAlphabeticSuffix(suffix: []const u8) u15 {
    return @as(u15, suffix[2] - 'A') |
        (@as(u15, suffix[3] - 'A') << 5) |
        (@as(u15, suffix[4] - 'A') << 10);
}

const custom_suffix_data_size: usize = size: {
    var total: usize = 0;
    for (currency_data.currencies) |currency| {
        if (!hasAlphabeticSuffix(currency)) total += currency.suffix.len;
    }
    break :size total;
};

const custom_suffix_data: [custom_suffix_data_size]u8 = data: {
    var result: [custom_suffix_data_size]u8 = undefined;
    var offset: usize = 0;
    for (currency_data.currencies) |currency| {
        if (hasAlphabeticSuffix(currency)) continue;
        @memcpy(result[offset .. offset + currency.suffix.len], currency.suffix);
        offset += currency.suffix.len;
    }
    break :data result;
};

const packed_currencies: [currency_data.currencies.len]PackedCurrency = entries: {
    var result: [currency_data.currencies.len]PackedCurrency = undefined;
    var offset: usize = 0;
    for (currency_data.currencies, 0..) |currency, index| {
        const alphabetic_suffix = hasAlphabeticSuffix(currency);
        result[index] = .{
            .numeric = @intCast(currency.numeric),
            .fraction_digits = @intCast(currency.fraction_digits),
            .suffix_payload = if (alphabetic_suffix)
                packedAlphabeticSuffix(currency.suffix)
            else
                @intCast(offset),
            .suffix_len = if (alphabetic_suffix) 0 else @intCast(currency.suffix.len),
            .has_custom_suffix = !alphabetic_suffix,
        };
        if (!alphabetic_suffix) offset += currency.suffix.len;
    }
    break :entries result;
};

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var integer_buf: [MAX_INTEGER_DIGITS + 1]u8 = undefined;
var currency_numeric: u32 = DEFAULT_CURRENCY_NUMERIC;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn uniform_set_currency(value: u32) u32 {
    currency_numeric = value;
    return currency_numeric;
}

fn selectedCurrency() ?PackedCurrency {
    var low: usize = 0;
    var high: usize = packed_currencies.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const currency = packed_currencies[middle];
        if (currency.numeric == currency_numeric) return currency;
        if (currency.numeric < currency_numeric) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return null;
}

const Amount = struct {
    negative: bool,
    integer_start: usize,
    integer_end: usize,
    fraction_start: usize,
    fraction_len: usize,
};

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn parse(input: []const u8) ?Amount {
    if (input.len == 0) return null;
    var cursor: usize = 0;
    const negative = input[0] == '-';
    if (negative) cursor = 1;
    if (cursor == input.len) return null;

    const integer_start = cursor;
    while (cursor < input.len and isDigit(input[cursor])) : (cursor += 1) {}
    const integer_end = cursor;
    if (integer_end == integer_start or integer_end - integer_start > MAX_INTEGER_DIGITS) return null;

    var fraction_start = cursor;
    var fraction_len: usize = 0;
    if (cursor < input.len and input[cursor] == '.') {
        cursor += 1;
        fraction_start = cursor;
        while (cursor < input.len and isDigit(input[cursor])) : (cursor += 1) {}
        fraction_len = cursor - fraction_start;
        if (fraction_len == 0) return null;
    }
    if (cursor != input.len) return null;
    return .{
        .negative = negative,
        .integer_start = integer_start,
        .integer_end = integer_end,
        .fraction_start = fraction_start,
        .fraction_len = fraction_len,
    };
}

fn incrementInteger(len: *usize) void {
    var cursor = len.*;
    while (cursor > 0) {
        cursor -= 1;
        if (integer_buf[cursor] < '9') {
            integer_buf[cursor] += 1;
            return;
        }
        integer_buf[cursor] = '0';
    }
    cursor = len.*;
    while (cursor > 0) {
        integer_buf[cursor] = integer_buf[cursor - 1];
        cursor -= 1;
    }
    integer_buf[0] = '1';
    len.* += 1;
}

fn renderImpl(input_size_in: u32) u32 {
    const currency = selectedCurrency() orelse @trap();
    currency_numeric = DEFAULT_CURRENCY_NUMERIC;
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];
    const amount = parse(input) orelse @trap();

    var first = amount.integer_start;
    while (first + 1 < amount.integer_end and input[first] == '0') : (first += 1) {}
    var integer_len = amount.integer_end - first;
    for (input[first..amount.integer_end], 0..) |digit, i| integer_buf[i] = digit;

    var fraction_value: u16 = 0;
    var position: usize = 0;
    while (position < currency.fraction_digits) : (position += 1) {
        fraction_value *= 10;
        if (position < amount.fraction_len) fraction_value += input[amount.fraction_start + position] - '0';
    }
    if (amount.fraction_len > currency.fraction_digits and input[amount.fraction_start + currency.fraction_digits] >= '5') {
        fraction_value += 1;
        var scale: u16 = 1;
        position = 0;
        while (position < currency.fraction_digits) : (position += 1) scale *= 10;
        if (fraction_value == scale) {
            fraction_value = 0;
            incrementInteger(&integer_len);
        }
    }

    var out: usize = 0;
    if (amount.negative) {
        output_buf[out] = '-';
        out += 1;
    }
    for (integer_buf[0..integer_len], 0..) |digit, i| {
        if (i > 0 and (integer_len - i) % 3 == 0) {
            output_buf[out] = 0xe2;
            output_buf[out + 1] = 0x80;
            output_buf[out + 2] = 0xaf;
            out += 3;
        }
        output_buf[out] = digit;
        out += 1;
    }
    if (currency.fraction_digits > 0) {
        output_buf[out] = ',';
        out += 1;
        var divisor: u16 = 1;
        position = 1;
        while (position < currency.fraction_digits) : (position += 1) divisor *= 10;
        position = 0;
        while (position < currency.fraction_digits) : (position += 1) {
            output_buf[out] = '0' + @as(u8, @intCast((fraction_value / divisor) % 10));
            out += 1;
            if (divisor > 1) divisor /= 10;
        }
    }
    if (currency.has_custom_suffix) {
        const suffix_start: usize = @intCast(currency.suffix_payload);
        const suffix_end = suffix_start + currency.suffix_len;
        for (custom_suffix_data[suffix_start..suffix_end]) |byte| {
            output_buf[out] = byte;
            out += 1;
        }
    } else {
        output_buf[out] = 0xc2;
        output_buf[out + 1] = 0xa0;
        output_buf[out + 2] = 'A' + @as(u8, @intCast(currency.suffix_payload & 0x1f));
        output_buf[out + 3] = 'A' + @as(u8, @intCast((currency.suffix_payload >> 5) & 0x1f));
        output_buf[out + 4] = 'A' + @as(u8, @intCast(currency.suffix_payload >> 10));
        out += 5;
    }
    return @intCast(out);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "currency uniform resets to USD after render" {
    const std = @import("std");
    const input = "1234.5";
    const expected_eur = "1\u{202f}234,50\u{a0}€";
    const expected_usd = "1\u{202f}234,50\u{a0}$US";
    @memcpy(input_buf[0..input.len], input);

    _ = uniform_set_currency(978);
    const euro_len: usize = @intCast(renderImpl(input.len));
    try std.testing.expectEqualStrings(expected_eur, output_buf[0..euro_len]);

    const usd_len: usize = @intCast(renderImpl(input.len));
    try std.testing.expectEqualStrings(expected_usd, output_buf[0..usd_len]);
}
