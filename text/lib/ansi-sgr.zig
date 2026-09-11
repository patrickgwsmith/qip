//! Narrow ANSI SGR parser for trusted terminal presentation streams.
//!
//! It accepts only CSI SGR (`ESC [ ... m`) controls. Cursor movement, OSC,
//! hyperlinks, and every other escape sequence are rejected.

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
    foreground: ?u4 = null,
    background: ?u4 = null,
};

pub const Error = error{ InvalidEscape, InvalidSgr, TooManyParameters };

pub fn colorHex(color: u4) []const u8 {
    return switch (color) {
        0 => "#000000",
        1 => "#cd3131",
        2 => "#0dbc79",
        3 => "#e5e510",
        4 => "#2472c8",
        5 => "#bc3fbc",
        6 => "#11a8cd",
        7 => "#e5e5e5",
        8 => "#666666",
        9 => "#f14c4c",
        10 => "#23d18b",
        11 => "#f5f543",
        12 => "#3b8eea",
        13 => "#d670d6",
        14 => "#29b8db",
        15 => "#ffffff",
    };
}

pub fn parse(input: []const u8, comptime Context: type, context: *Context, comptime emit: fn (*Context, []const u8, Style) anyerror!void) !void {
    var style = Style{};
    var text_start: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != 0x1b) {
            i += 1;
            continue;
        }
        if (i > text_start) try emit(context, input[text_start..i], style);
        i = try parseSgr(input, i, &style);
        text_start = i;
    }
    if (text_start < input.len) try emit(context, input[text_start..], style);
}

fn parseSgr(input: []const u8, start: usize, style: *Style) Error!usize {
    if (start + 2 > input.len or input[start + 1] != '[') return error.InvalidEscape;
    var i = start + 2;
    var value: u16 = 0;
    var has_digit = false;
    var parameter_count: u8 = 0;
    while (i < input.len) : (i += 1) {
        const byte = input[i];
        if (byte >= '0' and byte <= '9') {
            const digit: u16 = byte - '0';
            if (value > 999) return error.InvalidSgr;
            value = value * 10 + digit;
            has_digit = true;
            continue;
        }
        if (byte != ';' and byte != 'm') return error.InvalidSgr;
        if (parameter_count >= 16) return error.TooManyParameters;
        try apply(style, if (has_digit) value else 0);
        parameter_count += 1;
        value = 0;
        has_digit = false;
        if (byte == 'm') return i + 1;
    }
    return error.InvalidSgr;
}

fn apply(style: *Style, parameter: u16) Error!void {
    switch (parameter) {
        0 => style.* = .{},
        1 => style.bold = true,
        2 => style.dim = true,
        4 => style.underline = true,
        22 => {
            style.bold = false;
            style.dim = false;
        },
        24 => style.underline = false,
        30...37 => style.foreground = @intCast(parameter - 30),
        39 => style.foreground = null,
        40...47 => style.background = @intCast(parameter - 40),
        49 => style.background = null,
        90...97 => style.foreground = @intCast(parameter - 90 + 8),
        100...107 => style.background = @intCast(parameter - 100 + 8),
        else => return error.InvalidSgr,
    }
}

test "parses supported SGR spans" {
    const Context = struct {
        seen: u8 = 0,
        fn emit(self: *@This(), text: []const u8, style: Style) !void {
            if (self.seen == 0) {
                try @import("std").testing.expectEqualStrings("plain", text);
                try @import("std").testing.expect(!style.bold);
            } else {
                try @import("std").testing.expectEqualStrings("hot", text);
                try @import("std").testing.expect(style.bold);
                try @import("std").testing.expectEqual(@as(?u4, 9), style.foreground);
            }
            self.seen += 1;
        }
    };
    var context = Context{};
    try parse("plain\x1b[1;91mhot\x1b[0m", Context, &context, Context.emit);
    try @import("std").testing.expectEqual(@as(u8, 2), context.seen);
}
