// Format one ASCII decimal as en-US USD currency.
//
// Accepted input: -?[0-9]+(\.[0-9]+)? with at most 96 integer digits.
// Output always has a dollar sign, three-digit comma grouping, and two
// fraction digits. Decimal rounding is half away from zero. Invalid input
// traps so malformed financial values cannot quietly become plausible text.
const INPUT_CAP: usize = 128;
const OUTPUT_CAP: usize = 140;
const MAX_INTEGER_DIGITS: usize = 96;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var integer_buf: [MAX_INTEGER_DIGITS + 1]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

const Amount = struct {
    negative: bool,
    integer_start: usize,
    integer_end: usize,
    fraction_start: usize,
    fraction_len: usize,
};

fn parse(input: []const u8) ?Amount {
    if (input.len == 0) return null;
    var cursor: usize = 0;
    const negative = input[0] == '-';
    if (negative) {
        cursor = 1;
        if (cursor == input.len) return null;
    }

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

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn incrementInteger(len: *usize) void {
    var cursor = len.*;
    while (cursor > 0) {
        cursor -= 1;
        if (integer_buf[cursor] != '9') {
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
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];
    const amount = parse(input) orelse @trap();

    var first = amount.integer_start;
    while (first + 1 < amount.integer_end and input[first] == '0') : (first += 1) {}
    var integer_len = amount.integer_end - first;
    for (input[first..amount.integer_end], 0..) |digit, i| integer_buf[i] = digit;

    var cents: u8 = 0;
    if (amount.fraction_len > 0) cents = (input[amount.fraction_start] - '0') * 10;
    if (amount.fraction_len > 1) cents += input[amount.fraction_start + 1] - '0';
    if (amount.fraction_len > 2 and input[amount.fraction_start + 2] >= '5') {
        cents += 1;
        if (cents == 100) {
            cents = 0;
            incrementInteger(&integer_len);
        }
    }

    var out: usize = 0;
    if (amount.negative) {
        output_buf[out] = '-';
        out += 1;
    }
    output_buf[out] = '$';
    out += 1;

    for (integer_buf[0..integer_len], 0..) |digit, i| {
        if (i > 0 and (integer_len - i) % 3 == 0) {
            output_buf[out] = ',';
            out += 1;
        }
        output_buf[out] = digit;
        out += 1;
    }

    output_buf[out] = '.';
    output_buf[out + 1] = '0' + cents / 10;
    output_buf[out + 2] = '0' + cents % 10;
    return @intCast(out + 3);
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
