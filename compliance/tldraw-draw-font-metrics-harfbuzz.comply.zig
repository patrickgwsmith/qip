// HarfBuzz-derived advance_x oracle for tldraw draw font metrics.
const std = @import("std");

extern "qip" fn must_render_into(ordinal: u64, input_ptr: u32, input_len: u32, output_ptr: u32, output_cap: u32) i32;
extern "qip" fn must_render_into_emit_error(ordinal: u64, message_ptr: u32, message_len: u32) i32;
extern "qip" fn must_render_into_finish(ordinal: u64, error_count: u32) i32;

const render_failed_message = "render failed or output did not fit";
const missing_row_message = "CSV output did not contain a data row";
const advance_mismatch_message = "CSV advance_x field did not match HarfBuzz fixture";
const malformed_advance_message = "CSV advance_x field was not a decimal number";

const Case = struct { input: []const u8, advance_milli: i64 };

const cases = [_]Case{
    .{ .input = "", .advance_milli = 0 },
    .{ .input = " ", .advance_milli = 8232 },
    .{ .input = "Hello", .advance_milli = 62952 },
    .{ .input = "AVATAR, yay!?", .advance_milli = 174888 },
    .{ .input = "space  test", .advance_milli = 136632 },
    .{ .input = "World", .advance_milli = 73152 },
    .{ .input = "Café déjà vu — €", .advance_milli = 210552 },
    .{ .input = "fi fl ffi", .advance_milli = 85080 },
    .{ .input = "--------------------", .advance_milli = 243984 },
    .{ .input = "“Hello” (World) 123", .advance_milli = 241248 },
    .{ .input = "quotes: “AVATAR” — yay!", .advance_milli = 311208 },
    .{ .input = "To VA WA Te Yo", .advance_milli = 188592 },
    .{ .input = "The quick brown fox jumps over the lazy dog.", .advance_milli = 562152 },
    .{ .input = "0123456789", .advance_milli = 153888 },
    .{ .input = "!?.,:;()[]{}", .advance_milli = 119760 },
    .{ .input = "A/V W.A T-o", .advance_milli = 144792 },
    .{ .input = "Été déjà naïve façade", .advance_milli = 271776 },
    .{ .input = "--- – — −", .advance_milli = 118896 },
    .{ .input = "™ € • … ‹› «»", .advance_milli = 169032 },
    .{ .input = "ffffi ffi ffl fi fl", .advance_milli = 186120 },
    .{ .input = "yyyy aaa oooo llll", .advance_milli = 222912 },
};

const advance_tolerance_milli = 1;
const advance_field_index = 7;
var output_buf: [8192]u8 = undefined;

fn firstDataLine(output: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOfScalar(u8, output, '\n') orelse return null;
    if (header_end + 1 >= output.len) return null;
    const rest = output[header_end + 1 ..];
    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return rest[0..line_end];
}

fn csvField(line: []const u8, want_index: usize) ?[]const u8 {
    var index: usize = 0;
    var field_start: usize = 0;
    var in_quotes = false;
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        if (i == line.len or (!in_quotes and line[i] == ',')) {
            if (index == want_index) {
                var field = line[field_start..i];
                if (field.len >= 2 and field[0] == '"' and field[field.len - 1] == '"') field = field[1 .. field.len - 1];
                return field;
            }
            index += 1;
            field_start = i + 1;
        } else if (line[i] == '"') {
            if (in_quotes and i + 1 < line.len and line[i + 1] == '"') i += 1 else in_quotes = !in_quotes;
        }
    }
    return null;
}

fn parseDecimalMilli(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var i: usize = 0;
    var sign: i64 = 1;
    if (text[i] == '-') { sign = -1; i += 1; }
    if (i >= text.len) return null;
    var whole: i64 = 0;
    var saw_digit = false;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        saw_digit = true;
        whole = whole * 10 + @as(i64, text[i] - '0');
    }
    if (!saw_digit) return null;
    var frac: i64 = 0;
    var frac_digits: usize = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            if (frac_digits < 3) { frac = frac * 10 + @as(i64, text[i] - '0'); frac_digits += 1; }
        }
    }
    if (i != text.len) return null;
    while (frac_digits < 3) : (frac_digits += 1) frac *= 10;
    return sign * (whole * 1000 + frac);
}

fn absDiff(a: i64, b: i64) i64 { return if (a > b) a - b else b - a; }
fn emit(ordinal: u64, message: []const u8) void { _ = must_render_into_emit_error(ordinal, @intCast(@intFromPtr(message.ptr)), @intCast(message.len)); }

export fn comply() i32 {
    for (cases, 0..) |case, ordinal| {
        const status = must_render_into(ordinal, @intCast(@intFromPtr(case.input.ptr)), @intCast(case.input.len), @intCast(@intFromPtr(&output_buf)), output_buf.len);
        if (status < 0) { emit(ordinal, render_failed_message); _ = must_render_into_finish(ordinal, 1); continue; }
        if (case.input.len == 0) { _ = must_render_into_finish(ordinal, 0); continue; }
        const output = output_buf[0..@as(usize, @intCast(status))];
        const line = firstDataLine(output) orelse { emit(ordinal, missing_row_message); _ = must_render_into_finish(ordinal, 1); continue; };
        const field = csvField(line, advance_field_index) orelse "";
        const got = parseDecimalMilli(field) orelse { emit(ordinal, malformed_advance_message); _ = must_render_into_finish(ordinal, 1); continue; };
        var error_count: u32 = 0;
        if (absDiff(got, case.advance_milli) > advance_tolerance_milli) { emit(ordinal, advance_mismatch_message); error_count += 1; }
        _ = must_render_into_finish(ordinal, error_count);
    }
    return cases.len;
}
