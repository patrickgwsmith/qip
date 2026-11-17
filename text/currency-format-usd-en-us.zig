// Format one ASCII decimal as en-US USD currency.
//
// Accepted input: -?[0-9]+(\.[0-9]+)? with at most 96 integer digits.
// Output always has a dollar sign, three-digit comma grouping, and two
// fraction digits. Decimal rounding is half away from zero. Invalid input
// traps so malformed financial values cannot quietly become plausible text.
const INPUT_CAP: usize = 128;
const MAX_INTEGER_DIGITS: usize = 96;
// Sign, dollar sign, 97 digits (96 plus a rounding carry) with 32 commas,
// the point, and two cents.
const OUTPUT_CAP: usize = 1 + 1 + 97 + 32 + 1 + 2;

// io[0] is a spare byte before the input: rounding can carry into it. The
// four bytes after the input hold a scan sentinel, then zero digits that pad
// a short fraction.
var io: [1 + INPUT_CAP + 4]u8 = undefined;
const input_buf: *[INPUT_CAP]u8 = io[1..][0..INPUT_CAP];
// The cents are copied as a four-byte block, so two bytes of slack.
var output_buf: [OUTPUT_CAP + 2]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn isDigit(byte: u8) bool {
    return @as(u32, byte) -% '0' < 10;
}

fn renderImpl(input_size_in: u32) u32 {
    const size: usize = input_size_in;
    if (size > INPUT_CAP) @trap();
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

    // Zero digits after the input pad a fraction shorter than two digits. A
    // spare zero before the integer takes any carry out of the top digit.
    end[0..4].* = "0000".*;
    var first = integer_start - 1;
    first[0] = '0';
    if (fraction_start[2] >= '5') {
        var carry = fraction_start + 2;
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

    var out: [*]u8 = &output_buf;
    out[0] = '-';
    out += @intFromBool(negative);
    out[0] = '$';
    out += 1;
    var remaining = integer_end - first;
    while (true) {
        out[0] = first[0];
        out += 1;
        first += 1;
        remaining -= 1;
        if (remaining == 0) break;
        if (remaining % 3 == 0) {
            out[0] = ',';
            out += 1;
        }
    }
    out[0] = '.';
    // Copies four bytes and keeps the two cents digits.
    out[1..5].* = fraction_start[0..4].*;
    return @intCast(out + 3 - @as([*]u8, &output_buf));
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
