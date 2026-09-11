const std = @import("std");

const INPUT_CAP: usize = 4096;
const OUTPUT_CAP: usize = 128;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

// Deterministic defaults for callers that do not provide uniforms. Every value
// is in CSS pixels.
const DEFAULT_ROOT_FONT_SIZE: f64 = 16;
const DEFAULT_ROOT_LINE_HEIGHT: f64 = 19.2;
const DEFAULT_VIEWPORT_WIDTH: f64 = 1280;
const DEFAULT_VIEWPORT_HEIGHT: f64 = 720;

var root_font_size: f64 = DEFAULT_ROOT_FONT_SIZE;
var root_line_height: f64 = DEFAULT_ROOT_LINE_HEIGHT;
var viewport_width: f64 = DEFAULT_VIEWPORT_WIDTH;
var viewport_height: f64 = DEFAULT_VIEWPORT_HEIGHT;
var small_viewport_width: f64 = DEFAULT_VIEWPORT_WIDTH;
var small_viewport_height: f64 = DEFAULT_VIEWPORT_HEIGHT;
var dynamic_viewport_width: f64 = DEFAULT_VIEWPORT_WIDTH;
var dynamic_viewport_height: f64 = DEFAULT_VIEWPORT_HEIGHT;
var safe_area_inset_top: f64 = 0;
var safe_area_inset_right: f64 = 0;
var safe_area_inset_bottom: f64 = 0;
var safe_area_inset_left: f64 = 0;
var safe_area_max_inset_top: f64 = 0;
var safe_area_max_inset_right: f64 = 0;
var safe_area_max_inset_bottom: f64 = 0;
var safe_area_max_inset_left: f64 = 0;
var keyboard_inset_top: f64 = 0;
var keyboard_inset_right: f64 = 0;
var keyboard_inset_bottom: f64 = 0;
var keyboard_inset_left: f64 = 0;
var keyboard_inset_width: f64 = 0;
var keyboard_inset_height: f64 = 0;

fn resetUniforms() void {
    root_font_size = DEFAULT_ROOT_FONT_SIZE;
    root_line_height = DEFAULT_ROOT_LINE_HEIGHT;
    viewport_width = DEFAULT_VIEWPORT_WIDTH;
    viewport_height = DEFAULT_VIEWPORT_HEIGHT;
    small_viewport_width = DEFAULT_VIEWPORT_WIDTH;
    small_viewport_height = DEFAULT_VIEWPORT_HEIGHT;
    dynamic_viewport_width = DEFAULT_VIEWPORT_WIDTH;
    dynamic_viewport_height = DEFAULT_VIEWPORT_HEIGHT;
    safe_area_inset_top = 0;
    safe_area_inset_right = 0;
    safe_area_inset_bottom = 0;
    safe_area_inset_left = 0;
    safe_area_max_inset_top = 0;
    safe_area_max_inset_right = 0;
    safe_area_max_inset_bottom = 0;
    safe_area_max_inset_left = 0;
    keyboard_inset_top = 0;
    keyboard_inset_right = 0;
    keyboard_inset_bottom = 0;
    keyboard_inset_left = 0;
    keyboard_inset_width = 0;
    keyboard_inset_height = 0;
}

const Kind = enum {
    number,
    length,
};

const Value = struct {
    value: f64,
    kind: Kind,
};

const ParseError = error{
    InvalidSyntax,
    InvalidNumber,
    InvalidUnit,
    IncompatibleTypes,
    DivisionByZero,
    NonFiniteResult,
};

const Parser = struct {
    input: []const u8,
    cursor: usize = 0,

    fn skipWhitespace(self: *Parser) void {
        while (self.cursor < self.input.len and std.ascii.isWhitespace(self.input[self.cursor])) {
            self.cursor += 1;
        }
    }

    fn consume(self: *Parser, byte: u8) bool {
        self.skipWhitespace();
        if (self.cursor >= self.input.len or self.input[self.cursor] != byte) return false;
        self.cursor += 1;
        return true;
    }

    fn parse(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        if (self.cursor == self.input.len) return error.InvalidSyntax;
        const result = try self.parseSum();
        self.skipWhitespace();
        if (self.cursor != self.input.len or !std.math.isFinite(result.value)) return error.InvalidSyntax;
        return result;
    }

    fn parseSum(self: *Parser) ParseError!Value {
        var lhs = try self.parseProduct();
        while (true) {
            self.skipWhitespace();
            if (self.cursor >= self.input.len) return lhs;
            const operator = self.input[self.cursor];
            if (operator != '+' and operator != '-') return lhs;
            self.cursor += 1;
            const rhs = try self.parseProduct();
            if (lhs.kind != rhs.kind) return error.IncompatibleTypes;
            lhs.value = if (operator == '+') lhs.value + rhs.value else lhs.value - rhs.value;
            if (!std.math.isFinite(lhs.value)) return error.NonFiniteResult;
        }
    }

    fn parseProduct(self: *Parser) ParseError!Value {
        var lhs = try self.parseUnary();
        while (true) {
            self.skipWhitespace();
            if (self.cursor >= self.input.len) return lhs;
            const operator = self.input[self.cursor];
            if (operator != '*' and operator != '/') return lhs;
            self.cursor += 1;
            const rhs = try self.parseUnary();
            if (operator == '*') {
                if (lhs.kind == .length and rhs.kind == .length) return error.IncompatibleTypes;
                lhs = .{
                    .value = lhs.value * rhs.value,
                    .kind = if (lhs.kind == .length or rhs.kind == .length) .length else .number,
                };
            } else {
                if (rhs.value == 0) return error.DivisionByZero;
                if (lhs.kind == .number and rhs.kind == .length) return error.IncompatibleTypes;
                lhs = .{
                    .value = lhs.value / rhs.value,
                    .kind = if (lhs.kind == rhs.kind) .number else .length,
                };
            }
            if (!std.math.isFinite(lhs.value)) return error.NonFiniteResult;
        }
    }

    fn parseUnary(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        var negative = false;
        while (self.cursor < self.input.len) {
            if (self.input[self.cursor] == '+') {
                self.cursor += 1;
            } else if (self.input[self.cursor] == '-') {
                negative = !negative;
                self.cursor += 1;
            } else {
                break;
            }
            self.skipWhitespace();
        }
        var result = try self.parsePrimary();
        if (negative) result.value = -result.value;
        return result;
    }

    fn parsePrimary(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        if (self.consume('(')) {
            const result = try self.parseSum();
            if (!self.consume(')')) return error.InvalidSyntax;
            return result;
        }

        if (self.cursor < self.input.len and std.ascii.isAlphabetic(self.input[self.cursor])) {
            const name_start = self.cursor;
            while (self.cursor < self.input.len and std.ascii.isAlphabetic(self.input[self.cursor])) self.cursor += 1;
            const name = self.input[name_start..self.cursor];
            if (!self.consume('(')) return error.InvalidSyntax;
            if (std.ascii.eqlIgnoreCase(name, "calc")) {
                const result = try self.parseSum();
                if (!self.consume(')')) return error.InvalidSyntax;
                return result;
            }
            if (std.ascii.eqlIgnoreCase(name, "min")) return self.parseMinMax(false);
            if (std.ascii.eqlIgnoreCase(name, "max")) return self.parseMinMax(true);
            if (std.ascii.eqlIgnoreCase(name, "clamp")) return self.parseClamp();
            if (std.ascii.eqlIgnoreCase(name, "env")) return self.parseEnvironment();
            return error.InvalidSyntax;
        }

        return self.parseNumericValue();
    }

    fn parseMinMax(self: *Parser, choose_maximum: bool) ParseError!Value {
        var result = try self.parseSum();
        var argument_count: usize = 1;
        while (self.consume(',')) {
            const candidate = try self.parseSum();
            if (candidate.kind != result.kind) return error.IncompatibleTypes;
            if ((choose_maximum and candidate.value > result.value) or
                (!choose_maximum and candidate.value < result.value)) result = candidate;
            argument_count += 1;
        }
        if (argument_count == 0 or !self.consume(')')) return error.InvalidSyntax;
        return result;
    }

    fn parseClamp(self: *Parser) ParseError!Value {
        const minimum = try self.parseSum();
        if (!self.consume(',')) return error.InvalidSyntax;
        const preferred = try self.parseSum();
        if (!self.consume(',')) return error.InvalidSyntax;
        const maximum = try self.parseSum();
        if (!self.consume(')')) return error.InvalidSyntax;
        if (minimum.kind != preferred.kind or preferred.kind != maximum.kind) return error.IncompatibleTypes;
        return .{ .value = @max(minimum.value, @min(preferred.value, maximum.value)), .kind = preferred.kind };
    }

    fn parseEnvironment(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        const name_start = self.cursor;
        while (self.cursor < self.input.len) {
            const byte = self.input[self.cursor];
            if (!(std.ascii.isAlphabetic(byte) or byte == '-')) break;
            self.cursor += 1;
        }
        if (self.cursor == name_start) return error.InvalidSyntax;
        const name = self.input[name_start..self.cursor];
        self.skipWhitespace();

        const resolved = environmentValue(name);
        var fallback: ?Value = null;
        if (self.consume(',')) fallback = try self.parseSum();
        if (!self.consume(')')) return error.InvalidSyntax;
        return resolved orelse fallback orelse error.InvalidSyntax;
    }

    fn parseNumericValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        const number_start = self.cursor;
        var integer_digits: usize = 0;
        while (self.cursor < self.input.len and std.ascii.isDigit(self.input[self.cursor])) {
            self.cursor += 1;
            integer_digits += 1;
        }

        var fractional_digits: usize = 0;
        if (self.cursor < self.input.len and self.input[self.cursor] == '.') {
            self.cursor += 1;
            while (self.cursor < self.input.len and std.ascii.isDigit(self.input[self.cursor])) {
                self.cursor += 1;
                fractional_digits += 1;
            }
        }
        if (integer_digits == 0 and fractional_digits == 0) return error.InvalidNumber;

        if (self.cursor < self.input.len and (self.input[self.cursor] == 'e' or self.input[self.cursor] == 'E')) {
            const exponent_mark = self.cursor;
            self.cursor += 1;
            if (self.cursor < self.input.len and (self.input[self.cursor] == '+' or self.input[self.cursor] == '-')) {
                self.cursor += 1;
            }
            const exponent_start = self.cursor;
            while (self.cursor < self.input.len and std.ascii.isDigit(self.input[self.cursor])) self.cursor += 1;
            if (self.cursor == exponent_start) {
                self.cursor = exponent_mark;
            }
        }

        const numeric = std.fmt.parseFloat(f64, self.input[number_start..self.cursor]) catch return error.InvalidNumber;
        if (!std.math.isFinite(numeric)) return error.InvalidNumber;

        const unit_start = self.cursor;
        if (self.cursor < self.input.len and self.input[self.cursor] == '%') {
            self.cursor += 1;
            // This component intentionally treats percentages as factors so
            // expressions such as calc(1rem * 50%) evaluate without needing a
            // property-specific percentage basis.
            return .{ .value = numeric / 100, .kind = .number };
        }
        while (self.cursor < self.input.len and std.ascii.isAlphabetic(self.input[self.cursor])) self.cursor += 1;
        const unit = self.input[unit_start..self.cursor];
        if (unit.len == 0) return .{ .value = numeric, .kind = .number };
        if (std.ascii.eqlIgnoreCase(unit, "px")) return .{ .value = numeric, .kind = .length };
        if (std.ascii.eqlIgnoreCase(unit, "rem")) return .{ .value = numeric * root_font_size, .kind = .length };
        if (std.ascii.eqlIgnoreCase(unit, "rlh")) return .{ .value = numeric * root_line_height, .kind = .length };
        if (viewportUnitSize(unit)) |size| return .{ .value = numeric * size / 100, .kind = .length };
        return error.InvalidUnit;
    }
};

fn environmentValue(name: []const u8) ?Value {
    const value = if (std.mem.eql(u8, name, "safe-area-inset-top")) safe_area_inset_top else if (std.mem.eql(u8, name, "safe-area-inset-right")) safe_area_inset_right else if (std.mem.eql(u8, name, "safe-area-inset-bottom")) safe_area_inset_bottom else if (std.mem.eql(u8, name, "safe-area-inset-left")) safe_area_inset_left else if (std.mem.eql(u8, name, "safe-area-max-inset-top")) safe_area_max_inset_top else if (std.mem.eql(u8, name, "safe-area-max-inset-right")) safe_area_max_inset_right else if (std.mem.eql(u8, name, "safe-area-max-inset-bottom")) safe_area_max_inset_bottom else if (std.mem.eql(u8, name, "safe-area-max-inset-left")) safe_area_max_inset_left else if (std.mem.eql(u8, name, "keyboard-inset-top")) keyboard_inset_top else if (std.mem.eql(u8, name, "keyboard-inset-right")) keyboard_inset_right else if (std.mem.eql(u8, name, "keyboard-inset-bottom")) keyboard_inset_bottom else if (std.mem.eql(u8, name, "keyboard-inset-left")) keyboard_inset_left else if (std.mem.eql(u8, name, "keyboard-inset-width")) keyboard_inset_width else if (std.mem.eql(u8, name, "keyboard-inset-height")) keyboard_inset_height else return null;
    return .{ .value = value, .kind = .length };
}

fn viewportUnitSize(unit: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(unit, "vw") or std.ascii.eqlIgnoreCase(unit, "lvw")) return viewport_width;
    if (std.ascii.eqlIgnoreCase(unit, "vh") or std.ascii.eqlIgnoreCase(unit, "lvh")) return viewport_height;
    if (std.ascii.eqlIgnoreCase(unit, "vmin") or std.ascii.eqlIgnoreCase(unit, "lvmin")) return @min(viewport_width, viewport_height);
    if (std.ascii.eqlIgnoreCase(unit, "vmax") or std.ascii.eqlIgnoreCase(unit, "lvmax")) return @max(viewport_width, viewport_height);
    if (std.ascii.eqlIgnoreCase(unit, "svw")) return small_viewport_width;
    if (std.ascii.eqlIgnoreCase(unit, "svh")) return small_viewport_height;
    if (std.ascii.eqlIgnoreCase(unit, "svmin")) return @min(small_viewport_width, small_viewport_height);
    if (std.ascii.eqlIgnoreCase(unit, "svmax")) return @max(small_viewport_width, small_viewport_height);
    if (std.ascii.eqlIgnoreCase(unit, "dvw")) return dynamic_viewport_width;
    if (std.ascii.eqlIgnoreCase(unit, "dvh")) return dynamic_viewport_height;
    if (std.ascii.eqlIgnoreCase(unit, "dvmin")) return @min(dynamic_viewport_width, dynamic_viewport_height);
    if (std.ascii.eqlIgnoreCase(unit, "dvmax")) return @max(dynamic_viewport_width, dynamic_viewport_height);
    return null;
}

fn evaluate(input: []const u8) ParseError!Value {
    var parser = Parser{ .input = input };
    return parser.parse();
}

fn setNonNegative(value: f64) f64 {
    if (!std.math.isFinite(value)) @trap();
    return @max(value, 0);
}

export fn uniform_set_root_font_size(value: f64) f64 {
    root_font_size = setNonNegative(value);
    return root_font_size;
}

export fn uniform_set_root_line_height(value: f64) f64 {
    root_line_height = setNonNegative(value);
    return root_line_height;
}

export fn uniform_set_viewport_width(value: f64) f64 {
    viewport_width = setNonNegative(value);
    return viewport_width;
}

export fn uniform_set_viewport_height(value: f64) f64 {
    viewport_height = setNonNegative(value);
    return viewport_height;
}

export fn uniform_set_small_viewport_width(value: f64) f64 {
    small_viewport_width = setNonNegative(value);
    return small_viewport_width;
}

export fn uniform_set_small_viewport_height(value: f64) f64 {
    small_viewport_height = setNonNegative(value);
    return small_viewport_height;
}

export fn uniform_set_dynamic_viewport_width(value: f64) f64 {
    dynamic_viewport_width = setNonNegative(value);
    return dynamic_viewport_width;
}

export fn uniform_set_dynamic_viewport_height(value: f64) f64 {
    dynamic_viewport_height = setNonNegative(value);
    return dynamic_viewport_height;
}

export fn uniform_set_safe_area_inset_top(value: f64) f64 {
    safe_area_inset_top = setNonNegative(value);
    return safe_area_inset_top;
}

export fn uniform_set_safe_area_inset_right(value: f64) f64 {
    safe_area_inset_right = setNonNegative(value);
    return safe_area_inset_right;
}

export fn uniform_set_safe_area_inset_bottom(value: f64) f64 {
    safe_area_inset_bottom = setNonNegative(value);
    return safe_area_inset_bottom;
}

export fn uniform_set_safe_area_inset_left(value: f64) f64 {
    safe_area_inset_left = setNonNegative(value);
    return safe_area_inset_left;
}

export fn uniform_set_safe_area_max_inset_top(value: f64) f64 {
    safe_area_max_inset_top = setNonNegative(value);
    return safe_area_max_inset_top;
}

export fn uniform_set_safe_area_max_inset_right(value: f64) f64 {
    safe_area_max_inset_right = setNonNegative(value);
    return safe_area_max_inset_right;
}

export fn uniform_set_safe_area_max_inset_bottom(value: f64) f64 {
    safe_area_max_inset_bottom = setNonNegative(value);
    return safe_area_max_inset_bottom;
}

export fn uniform_set_safe_area_max_inset_left(value: f64) f64 {
    safe_area_max_inset_left = setNonNegative(value);
    return safe_area_max_inset_left;
}

export fn uniform_set_keyboard_inset_top(value: f64) f64 {
    keyboard_inset_top = setNonNegative(value);
    return keyboard_inset_top;
}

export fn uniform_set_keyboard_inset_right(value: f64) f64 {
    keyboard_inset_right = setNonNegative(value);
    return keyboard_inset_right;
}

export fn uniform_set_keyboard_inset_bottom(value: f64) f64 {
    keyboard_inset_bottom = setNonNegative(value);
    return keyboard_inset_bottom;
}

export fn uniform_set_keyboard_inset_left(value: f64) f64 {
    keyboard_inset_left = setNonNegative(value);
    return keyboard_inset_left;
}

export fn uniform_set_keyboard_inset_width(value: f64) f64 {
    keyboard_inset_width = setNonNegative(value);
    return keyboard_inset_width;
}

export fn uniform_set_keyboard_inset_height(value: f64) f64 {
    keyboard_inset_height = setNonNegative(value);
    return keyboard_inset_height;
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    var result = evaluate(input_buf[0..input_size]) catch @trap();
    resetUniforms();
    if (result.value == 0) result.value = 0; // Normalize negative zero.
    const numeric = std.fmt.bufPrint(output_buf[0..], "{d}", .{result.value}) catch @trap();
    var output_size = numeric.len;
    if (result.kind == .length) {
        if (output_size + 2 > output_buf.len) @trap();
        output_buf[output_size] = 'p';
        output_buf[output_size + 1] = 'x';
        output_size += 2;
    }
    return @intCast(output_size);
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

test "render resets every uniform to its authored default" {
    const input = "calc(1rem + 1rlh + 1vw + 1vh + 1svw + 1svh + 1dvw + 1dvh + env(safe-area-inset-top) + env(safe-area-inset-right) + env(safe-area-inset-bottom) + env(safe-area-inset-left) + env(safe-area-max-inset-top) + env(safe-area-max-inset-right) + env(safe-area-max-inset-bottom) + env(safe-area-max-inset-left) + env(keyboard-inset-top) + env(keyboard-inset-right) + env(keyboard-inset-bottom) + env(keyboard-inset-left) + env(keyboard-inset-width) + env(keyboard-inset-height))";
    @memcpy(input_buf[0..input.len], input);

    _ = uniform_set_root_font_size(20);
    _ = uniform_set_root_line_height(30);
    _ = uniform_set_viewport_width(1000);
    _ = uniform_set_viewport_height(800);
    _ = uniform_set_small_viewport_width(600);
    _ = uniform_set_small_viewport_height(400);
    _ = uniform_set_dynamic_viewport_width(200);
    _ = uniform_set_dynamic_viewport_height(100);
    _ = uniform_set_safe_area_inset_top(1);
    _ = uniform_set_safe_area_inset_right(2);
    _ = uniform_set_safe_area_inset_bottom(3);
    _ = uniform_set_safe_area_inset_left(4);
    _ = uniform_set_safe_area_max_inset_top(5);
    _ = uniform_set_safe_area_max_inset_right(6);
    _ = uniform_set_safe_area_max_inset_bottom(7);
    _ = uniform_set_safe_area_max_inset_left(8);
    _ = uniform_set_keyboard_inset_top(9);
    _ = uniform_set_keyboard_inset_right(10);
    _ = uniform_set_keyboard_inset_bottom(11);
    _ = uniform_set_keyboard_inset_left(12);
    _ = uniform_set_keyboard_inset_width(13);
    _ = uniform_set_keyboard_inset_height(14);

    const configured_len: usize = @intCast(renderImpl(input.len));
    try std.testing.expectEqualStrings("186px", output_buf[0..configured_len]);

    const default_len: usize = @intCast(renderImpl(input.len));
    try std.testing.expectEqualStrings("95.2px", output_buf[0..default_len]);
}

test "resolves supported relative units" {
    root_font_size = 16;
    root_line_height = 24;
    viewport_width = 1440;
    viewport_height = 900;
    try std.testing.expectEqual(Value{ .value = 16, .kind = .length }, try evaluate("1rem"));
    try std.testing.expectEqual(Value{ .value = 36, .kind = .length }, try evaluate("1.5rlh"));
    try std.testing.expectEqual(Value{ .value = 144, .kind = .length }, try evaluate("10vw"));
    try std.testing.expectEqual(Value{ .value = 90, .kind = .length }, try evaluate("10vh"));
}

test "evaluates calc arithmetic and percentage factors" {
    root_font_size = 16;
    viewport_width = 1440;
    try std.testing.expectEqual(Value{ .value = 8, .kind = .length }, try evaluate("calc(1rem * 50%)"));
    try std.testing.expectEqual(Value{ .value = 80, .kind = .length }, try evaluate("calc(10vw / 2 + 8px)"));
    try std.testing.expectEqual(Value{ .value = 3.5, .kind = .number }, try evaluate("calc(1 + 5 / 2)"));
}

test "resolves mobile viewport families" {
    viewport_width = 430;
    viewport_height = 932;
    small_viewport_width = 430;
    small_viewport_height = 780;
    dynamic_viewport_width = 430;
    dynamic_viewport_height = 844;
    try std.testing.expectEqual(Value{ .value = 932, .kind = .length }, try evaluate("100vh"));
    try std.testing.expectEqual(Value{ .value = 932, .kind = .length }, try evaluate("100lvh"));
    try std.testing.expectEqual(Value{ .value = 780, .kind = .length }, try evaluate("100svh"));
    try std.testing.expectEqual(Value{ .value = 844, .kind = .length }, try evaluate("100dvh"));
    try std.testing.expectEqual(Value{ .value = 4.3, .kind = .length }, try evaluate("1dvmin"));
    try std.testing.expectEqual(Value{ .value = 9.32, .kind = .length }, try evaluate("1lvmax"));
}

test "resolves environment values and comparison functions" {
    root_font_size = 16;
    dynamic_viewport_height = 700;
    safe_area_inset_bottom = 34;
    keyboard_inset_height = 290;
    try std.testing.expectEqual(Value{ .value = 34, .kind = .length }, try evaluate("env(safe-area-inset-bottom)"));
    try std.testing.expectEqual(Value{ .value = 34, .kind = .length }, try evaluate("max(1rem, env(safe-area-inset-bottom))"));
    try std.testing.expectEqual(Value{ .value = 410, .kind = .length }, try evaluate("calc(100dvh - env(keyboard-inset-height))"));
    try std.testing.expectEqual(Value{ .value = 20, .kind = .length }, try evaluate("clamp(10px, 3rem, 20px)"));
    try std.testing.expectEqual(Value{ .value = 30, .kind = .length }, try evaluate("clamp(30px, 20px, 10px)"));
    try std.testing.expectEqual(Value{ .value = 12, .kind = .length }, try evaluate("env(unknown-inset, 12px)"));
}

test "rejects incomplete and dimensionally invalid expressions" {
    try std.testing.expectError(error.InvalidSyntax, evaluate("calc(1rem + 2px"));
    try std.testing.expectError(error.IncompatibleTypes, evaluate("1rem + 2"));
    try std.testing.expectError(error.IncompatibleTypes, evaluate("1rem * 2px"));
    try std.testing.expectError(error.DivisionByZero, evaluate("1rem / 0"));
    try std.testing.expectError(error.InvalidUnit, evaluate("1em"));
    try std.testing.expectError(error.InvalidSyntax, evaluate("env(unknown-inset)"));
    try std.testing.expectError(error.IncompatibleTypes, evaluate("min(1px, 2)"));
}
