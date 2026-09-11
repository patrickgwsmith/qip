const std = @import("std");
const root = @import("root");

const OUTPUT_KTX2 = true;
const ktx2 = @import("ktx2_rgba8_srgb");
const OUTPUT_FLOAT = @hasDecl(root, "SVG_RASTERIZE_RGBA32FLOAT") and root.SVG_RASTERIZE_RGBA32FLOAT;
const ANTIALIAS = OUTPUT_FLOAT or (@hasDecl(root, "SVG_RASTERIZE_ANTIALIAS") and root.SVG_RASTERIZE_ANTIALIAS);
const ktx2_float = if (ANTIALIAS) @import("ktx2_rgba32float") else struct {};

// TODO(svg): Required paint parsing to be practical for SVG icons/text:
// - Add css color functions: rgb(), rgba(), hsl(), hsla()
// - Add currentColor support for fill/stroke
// Not required for this module:
// - No var() / CSS custom properties
// - No calc() in paint values
// - No stylesheet/style="" cascade engine

const INPUT_CAP: u32 = 1024 * 1024;
const MAX_PIXELS: u32 = 25_000_000;
const MAX_DIMENSION: u32 = 8192;
const OUTPUT_HEADER_SIZE: u32 = if (OUTPUT_KTX2) 224 else 54;
const OUTPUT_PIXEL_SIZE: u32 = if (OUTPUT_FLOAT) 16 else 4;
const OUTPUT_CAP: u32 = MAX_PIXELS * OUTPUT_PIXEL_SIZE + OUTPUT_HEADER_SIZE;
const WORK_PIXEL_SIZE: u32 = if (ANTIALIAS) 16 else OUTPUT_PIXEL_SIZE;
const WORK_CAP: u32 = MAX_PIXELS * WORK_PIXEL_SIZE + OUTPUT_HEADER_SIZE;
const INPUT_CONTENT_TYPE = "image/svg+xml";
const OUTPUT_CONTENT_TYPE = if (OUTPUT_KTX2) "image/ktx2" else "image/bmp";
const DEFAULT_BACKGROUND_COLOR_RGBA: u32 = 0x00000000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [WORK_CAP]u8 = undefined;
var background_color_rgba: u32 = DEFAULT_BACKGROUND_COLOR_RGBA;
var output_width: u32 = 0;
var output_height: u32 = 0;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

fn colorFromRgba(value: u32) Color {
    return .{
        .r = @intCast((value >> 24) & 0xFF),
        .g = @intCast((value >> 16) & 0xFF),
        .b = @intCast((value >> 8) & 0xFF),
        .a = @intCast(value & 0xFF),
    };
}

export fn uniform_set_background_color_rgba(value: u32) u32 {
    background_color_rgba = value;
    return background_color_rgba;
}

export fn uniform_set_width(value: u32) u32 {
    if (!ANTIALIAS) return 0;
    output_width = @min(value, MAX_DIMENSION);
    return output_width;
}

export fn uniform_set_height(value: u32) u32 {
    if (!ANTIALIAS) return 0;
    output_height = @min(value, MAX_DIMENSION);
    return output_height;
}

fn resetBackgroundColorUniform() void {
    background_color_rgba = DEFAULT_BACKGROUND_COLOR_RGBA;
    output_width = 0;
    output_height = 0;
}

const Mat = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    tx: f32,
    ty: f32,
};

const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    set_x: bool = false,
    set_y: bool = false,
    set_w: bool = false,
    set_h: bool = false,
};

const Circle = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    r: f32 = 0,
    set_cx: bool = false,
    set_cy: bool = false,
    set_r: bool = false,
};

const Line = struct {
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 0,
    y2: f32 = 0,
    set_x1: bool = false,
    set_y1: bool = false,
    set_x2: bool = false,
    set_y2: bool = false,
};

const MAX_POINTS: usize = 256;
const MAX_PATH_SEGMENTS: usize = 4096;

const PathSegment = struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
};

const PathIntersection = struct {
    x: f32,
    winding_delta: i32,
};

// Rendering is single-threaded and non-reentrant. Keeping scanline scratch out
// of the Wasm stack avoids combining it with the bounded 4096-segment path
// array in drawPathFill.
var path_intersections: [MAX_PATH_SEGMENTS]PathIntersection = undefined;
var path_scanline_coverage: [MAX_DIMENSION]u8 = undefined;

const ParserCtx = struct {
    input: []const u8,
    width: u32,
    height: u32,
    pixel_base: u32,
    out_len: u32,
};

const Vec4f = @Vector(4, f32);

fn matIdentity() Mat {
    return Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };
}

fn matMul(a: Mat, b: Mat) Mat {
    return Mat{
        .a = a.a * b.a + a.c * b.b,
        .b = a.b * b.a + a.d * b.b,
        .c = a.a * b.c + a.c * b.d,
        .d = a.b * b.c + a.d * b.d,
        .tx = a.a * b.tx + a.c * b.ty + a.tx,
        .ty = a.b * b.tx + a.d * b.ty + a.ty,
    };
}

fn matApply(m: Mat, x: f32, y: f32) [2]f32 {
    return .{ m.a * x + m.c * y + m.tx, m.b * x + m.d * y + m.ty };
}

fn matInverse(m: Mat) ?Mat {
    const det = m.a * m.d - m.b * m.c;
    if (det == 0) return null;
    const inv_det = 1.0 / det;
    const a = m.d * inv_det;
    const b = -m.b * inv_det;
    const c = -m.c * inv_det;
    const d = m.a * inv_det;
    const tx = -(a * m.tx + c * m.ty);
    const ty = -(b * m.tx + d * m.ty);
    return Mat{ .a = a, .b = b, .c = c, .d = d, .tx = tx, .ty = ty };
}

fn matMaxScale(m: Mat) f32 {
    const sx = std.math.sqrt(m.a * m.a + m.b * m.b);
    const sy = std.math.sqrt(m.c * m.c + m.d * m.d);
    return if (sx > sy) sx else sy;
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == ':';
}

fn skipWs(input: []const u8, idx: *usize) void {
    while (idx.* < input.len) {
        const c = input[idx.*];
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            idx.* += 1;
            continue;
        }
        break;
    }
}

fn skipWsCommas(input: []const u8, idx: *usize) void {
    while (idx.* < input.len) {
        const c = input[idx.*];
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r' or c == ',') {
            idx.* += 1;
            continue;
        }
        break;
    }
}

fn readName(input: []const u8, idx: *usize) []const u8 {
    const start = idx.*;
    while (idx.* < input.len and isNameChar(input[idx.*])) {
        idx.* += 1;
    }
    return input[start..idx.*];
}

fn readQuoted(input: []const u8, idx: *usize) []const u8 {
    if (idx.* >= input.len) return input[0..0];
    const quote = input[idx.*];
    if (quote != '"' and quote != '\'') return input[0..0];
    idx.* += 1;
    const start = idx.*;
    while (idx.* < input.len and input[idx.*] != quote) {
        idx.* += 1;
    }
    const slice = input[start..idx.*];
    if (idx.* < input.len and input[idx.*] == quote) {
        idx.* += 1;
    }
    return slice;
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

fn parseColor(value: []const u8) ?Color {
    if (value.len == 4 and value[0] == '#') {
        const r = hexVal(value[1]);
        const g = hexVal(value[2]);
        const b = hexVal(value[3]);
        return Color{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    }
    if (value.len >= 7 and value[0] == '#') {
        const r = (hexVal(value[1]) << 4) | hexVal(value[2]);
        const g = (hexVal(value[3]) << 4) | hexVal(value[4]);
        const b = (hexVal(value[5]) << 4) | hexVal(value[6]);
        return Color{ .r = r, .g = g, .b = b, .a = 255 };
    }
    if (strEq(value, "none")) {
        return Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    if (strEq(value, "black")) {
        return Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    }
    if (strEq(value, "white")) {
        return Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }
    if (strEq(value, "red")) {
        return Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    }
    if (strEq(value, "green")) {
        return Color{ .r = 0, .g = 128, .b = 0, .a = 255 };
    }
    if (strEq(value, "blue")) {
        return Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    }
    return null;
}

fn parseFloat(input: []const u8, idx: *usize) ?f32 {
    skipWs(input, idx);
    if (idx.* >= input.len) return null;
    var i = idx.*;
    var sign: f32 = 1.0;
    if (input[i] == '-') {
        sign = -1.0;
        i += 1;
    } else if (input[i] == '+') {
        i += 1;
    }
    var int_part: f32 = 0.0;
    var has_digit = false;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') {
        int_part = int_part * 10.0 + @as(f32, @floatFromInt(input[i] - '0'));
        i += 1;
        has_digit = true;
    }
    var frac_part: f32 = 0.0;
    var div: f32 = 1.0;
    if (i < input.len and input[i] == '.') {
        i += 1;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') {
            frac_part = frac_part * 10.0 + @as(f32, @floatFromInt(input[i] - '0'));
            div *= 10.0;
            i += 1;
            has_digit = true;
        }
    }
    if (!has_digit) return null;
    idx.* = i;
    return sign * (int_part + frac_part / div);
}

fn parseNumber(value: []const u8) ?f32 {
    var i: usize = 0;
    return parseFloat(value, &i);
}

fn parsePathNumber(input: []const u8, idx: *usize) ?f32 {
    skipWsCommas(input, idx);
    if (idx.* >= input.len) return null;
    const c = input[idx.*];
    if (!((c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.')) {
        return null;
    }
    return parseFloat(input, idx);
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn toUpperASCII(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn parseTransform(value: []const u8) Mat {
    var idx: usize = 0;
    var result = matIdentity();
    while (idx < value.len) {
        skipWs(value, &idx);
        if (idx >= value.len) break;
        const name_start = idx;
        while (idx < value.len and ((value[idx] >= 'a' and value[idx] <= 'z') or (value[idx] >= 'A' and value[idx] <= 'Z'))) {
            idx += 1;
        }
        const name = value[name_start..idx];
        skipWs(value, &idx);
        if (idx >= value.len or value[idx] != '(') break;
        idx += 1;
        var nums: [6]f32 = undefined;
        var count: usize = 0;
        while (idx < value.len and value[idx] != ')') {
            if (count >= nums.len) {
                while (idx < value.len and value[idx] != ')') idx += 1;
                break;
            }
            if (parseFloat(value, &idx)) |v| {
                nums[count] = v;
                count += 1;
            } else {
                idx += 1;
            }
            skipWs(value, &idx);
            if (idx < value.len and value[idx] == ',') idx += 1;
        }
        if (idx < value.len and value[idx] == ')') idx += 1;

        var op = matIdentity();
        if (strEq(name, "matrix") and count == 6) {
            op = Mat{
                .a = nums[0],
                .b = nums[1],
                .c = nums[2],
                .d = nums[3],
                .tx = nums[4],
                .ty = nums[5],
            };
        } else if (strEq(name, "translate")) {
            const tx = if (count >= 1) nums[0] else 0.0;
            const ty = if (count >= 2) nums[1] else 0.0;
            op = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = tx, .ty = ty };
        } else if (strEq(name, "scale")) {
            const sx = if (count >= 1) nums[0] else 1.0;
            const sy = if (count >= 2) nums[1] else sx;
            op = Mat{ .a = sx, .b = 0, .c = 0, .d = sy, .tx = 0, .ty = 0 };
        } else if (strEq(name, "rotate")) {
            const angle = if (count >= 1) nums[0] else 0.0;
            const rad = angle * (std.math.pi / 180.0);
            const c = std.math.cos(rad);
            const s = std.math.sin(rad);
            op = Mat{ .a = c, .b = s, .c = -s, .d = c, .tx = 0, .ty = 0 };
            if (count >= 3) {
                const cx = nums[1];
                const cy = nums[2];
                const t1 = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = cx, .ty = cy };
                const t2 = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = -cx, .ty = -cy };
                op = matMul(t1, matMul(op, t2));
            }
        }
        result = matMul(result, op);
    }
    return result;
}

fn floatPixelPtr(ctx: *ParserCtx, x: u32, y: u32) *align(1) Vec4f {
    const idx: usize = ctx.pixel_base + (y * ctx.width + x) * 16;
    return @ptrCast(&output_buf[idx]);
}

fn blendPixelCoverage(ctx: *ParserCtx, x: i32, y: i32, color: Color, coverage: f32) void {
    if (!ANTIALIAS) @compileError("float coverage is only available in an antialiased renderer");
    if (color.a == 0 or coverage <= 0) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= ctx.width or uy >= ctx.height) return;

    const paint_alpha = @as(f32, @floatFromInt(color.a)) / 255.0;
    const source_alpha = @min(@as(f32, 1.0), coverage) * paint_alpha;
    const inverse_alpha: Vec4f = @splat(1.0 - source_alpha);
    const source: Vec4f = .{
        ktx2_float.SRGB8_TO_LINEAR[color.r] * source_alpha,
        ktx2_float.SRGB8_TO_LINEAR[color.g] * source_alpha,
        ktx2_float.SRGB8_TO_LINEAR[color.b] * source_alpha,
        source_alpha,
    };
    const pixel = floatPixelPtr(ctx, ux, uy);
    pixel.* = source + pixel.* * inverse_alpha;
}

fn setPixel(ctx: *ParserCtx, x: i32, y: i32, color: Color) void {
    if (ANTIALIAS) {
        blendPixelCoverage(ctx, x, y, color, 1.0);
        return;
    }
    if (color.a == 0) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= ctx.width or uy >= ctx.height) return;
    const row = if (OUTPUT_KTX2) uy else ctx.height - 1 - uy;
    const idx: u32 = ctx.pixel_base + (row * ctx.width + ux) * 4;
    output_buf[idx] = if (OUTPUT_KTX2) color.r else color.b;
    output_buf[idx + 1] = color.g;
    output_buf[idx + 2] = if (OUTPUT_KTX2) color.b else color.r;
    output_buf[idx + 3] = color.a;
}

fn finishAntialiasedPixels(ctx: *ParserCtx) void {
    if (!ANTIALIAS) return;
    var pixel_index: u32 = 0;
    const pixel_count = ctx.width * ctx.height;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const byte_index: usize = ctx.pixel_base + pixel_index * 16;
        const pixel: *align(1) Vec4f = @ptrCast(&output_buf[byte_index]);
        const alpha = pixel.*[3];
        if (OUTPUT_FLOAT and alpha > 0.0) {
            const inverse_alpha: Vec4f = @splat(1.0 / alpha);
            const straight = pixel.* * inverse_alpha;
            pixel.* = .{ straight[0], straight[1], straight[2], alpha };
        } else if (OUTPUT_FLOAT) {
            pixel.* = @splat(0.0);
        } else {
            const destination = ctx.pixel_base + pixel_index * 4;
            if (alpha > 0.0) {
                const inverse_alpha = 1.0 / alpha;
                output_buf[destination] = ktx2_float.linearToSrgb8(pixel.*[0] * inverse_alpha);
                output_buf[destination + 1] = ktx2_float.linearToSrgb8(pixel.*[1] * inverse_alpha);
                output_buf[destination + 2] = ktx2_float.linearToSrgb8(pixel.*[2] * inverse_alpha);
                output_buf[destination + 3] = ktx2_float.linearToUnorm8(alpha);
            } else {
                @memset(output_buf[destination .. destination + 4], 0);
            }
        }
    }
}

const AA_GRID: i32 = 4;
const AA_SAMPLE_X: Vec4f = .{ 0.125, 0.375, 0.625, 0.875 };

fn sampleLocalX(inv: Mat, x: i32, sample_y: f32) Vec4f {
    const xs = @as(Vec4f, @splat(@as(f32, @floatFromInt(x)))) + AA_SAMPLE_X;
    return @as(Vec4f, @splat(inv.a)) * xs + @as(Vec4f, @splat(inv.c * sample_y + inv.tx));
}

fn sampleLocalY(inv: Mat, x: i32, sample_y: f32) Vec4f {
    const xs = @as(Vec4f, @splat(@as(f32, @floatFromInt(x)))) + AA_SAMPLE_X;
    return @as(Vec4f, @splat(inv.b)) * xs + @as(Vec4f, @splat(inv.d * sample_y + inv.ty));
}

fn maskCount(mask: @Vector(4, bool)) i32 {
    return @reduce(.Add, @select(i32, mask, @as(@Vector(4, i32), @splat(1)), @as(@Vector(4, i32), @splat(0))));
}

fn rectCoverage(inv: Mat, x: i32, y: i32, x0: f32, y0: f32, x1: f32, y1: f32) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / @as(f32, @floatFromInt(AA_GRID));
        const lx = sampleLocalX(inv, x, sy);
        const ly = sampleLocalY(inv, x, sy);
        covered += maskCount((lx >= @as(Vec4f, @splat(x0))) & (lx <= @as(Vec4f, @splat(x1))) &
            (ly >= @as(Vec4f, @splat(y0))) & (ly <= @as(Vec4f, @splat(y1))));
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn rectStrokeCoverage(inv: Mat, x: i32, y: i32, ox0: f32, oy0: f32, ox1: f32, oy1: f32, ix0: f32, iy0: f32, ix1: f32, iy1: f32, has_inner: bool) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / 4.0;
        const lx = sampleLocalX(inv, x, sy);
        const ly = sampleLocalY(inv, x, sy);
        const outer = (lx >= @as(Vec4f, @splat(ox0))) & (lx <= @as(Vec4f, @splat(ox1))) &
            (ly >= @as(Vec4f, @splat(oy0))) & (ly <= @as(Vec4f, @splat(oy1)));
        const inner = if (has_inner)
            (lx >= @as(Vec4f, @splat(ix0))) & (lx <= @as(Vec4f, @splat(ix1))) &
                (ly >= @as(Vec4f, @splat(iy0))) & (ly <= @as(Vec4f, @splat(iy1)))
        else
            @as(@Vector(4, bool), @splat(false));
        covered += maskCount(outer & !inner);
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn circleCoverage(inv: Mat, x: i32, y: i32, cx: f32, cy: f32, inner_r2: f32, outer_r2: f32) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / 4.0;
        const dx = sampleLocalX(inv, x, sy) - @as(Vec4f, @splat(cx));
        const dy = sampleLocalY(inv, x, sy) - @as(Vec4f, @splat(cy));
        const distance2 = dx * dx + dy * dy;
        covered += maskCount((distance2 >= @as(Vec4f, @splat(inner_r2))) & (distance2 <= @as(Vec4f, @splat(outer_r2))));
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn polygonCoverage(inv: Mat, x: i32, y: i32, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / 4.0;
        const lx = sampleLocalX(inv, x, sy);
        const ly = sampleLocalY(inv, x, sy);
        var inside: @Vector(4, bool) = @splat(false);
        var prior: usize = count - 1;
        var edge: usize = 0;
        while (edge < count) : (edge += 1) {
            const xi: Vec4f = @splat(xs[edge]);
            const yi: Vec4f = @splat(ys[edge]);
            const xj: Vec4f = @splat(xs[prior]);
            const yj: Vec4f = @splat(ys[prior]);
            const intersects = ((yi > ly) != (yj > ly)) & (lx < (xj - xi) * (ly - yi) / (yj - yi + @as(Vec4f, @splat(0.0000001))) + xi);
            inside = inside != intersects;
            prior = edge;
        }
        covered += maskCount(inside);
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn segmentStrokeCoverage(inv: Mat, x: i32, y: i32, ax: f32, ay: f32, bx: f32, by: f32, half_width2: f32) f32 {
    const vx: Vec4f = @splat(bx - ax);
    const vy: Vec4f = @splat(by - ay);
    const vv = vx * vx + vy * vy;
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / 4.0;
        const wx = sampleLocalX(inv, x, sy) - @as(Vec4f, @splat(ax));
        const wy = sampleLocalY(inv, x, sy) - @as(Vec4f, @splat(ay));
        var t: Vec4f = @splat(0.0);
        if (vv[0] > 0.0000001) t = @min(@as(Vec4f, @splat(1.0)), @max(@as(Vec4f, @splat(0.0)), (wx * vx + wy * vy) / vv));
        const dx = wx - t * vx;
        const dy = wy - t * vy;
        covered += maskCount(dx * dx + dy * dy <= @as(Vec4f, @splat(half_width2)));
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn polygonStrokeCoverage(inv: Mat, x: i32, y: i32, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize, half_width2: f32) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / 4.0;
        const lx = sampleLocalX(inv, x, sy);
        const ly = sampleLocalY(inv, x, sy);
        var near: @Vector(4, bool) = @splat(false);
        var prior: usize = count - 1;
        var edge: usize = 0;
        while (edge < count) : (edge += 1) {
            const ax: Vec4f = @splat(xs[prior]);
            const ay: Vec4f = @splat(ys[prior]);
            const vx: Vec4f = @splat(xs[edge] - xs[prior]);
            const vy: Vec4f = @splat(ys[edge] - ys[prior]);
            const wx = lx - ax;
            const wy = ly - ay;
            const vv = vx * vx + vy * vy;
            var t: Vec4f = @splat(0.0);
            if (vv[0] > 0.0000001) t = @min(@as(Vec4f, @splat(1.0)), @max(@as(Vec4f, @splat(0.0)), (wx * vx + wy * vy) / vv));
            const dx = wx - t * vx;
            const dy = wy - t * vy;
            near = near | (dx * dx + dy * dy <= @as(Vec4f, @splat(half_width2)));
            prior = edge;
        }
        covered += maskCount(near);
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn intersectionLessThan(_: void, left: PathIntersection, right: PathIntersection) bool {
    return left.x < right.x;
}

fn addScanlineSpanCoverage(width: u32, start_x: f32, end_x: f32) void {
    if (!(end_x > start_x) or end_x <= 0.0 or start_x >= @as(f32, @floatFromInt(width))) return;
    var first: i32 = @intFromFloat(@floor(start_x));
    var last: i32 = @intFromFloat(@floor(end_x));
    if (first < 0) first = 0;
    if (last >= @as(i32, @intCast(width))) last = @as(i32, @intCast(width)) - 1;
    if (last < first) return;

    var x = first;
    while (x <= last) : (x += 1) {
        if (x > first and x < last) {
            path_scanline_coverage[@intCast(x)] += 4;
            continue;
        }
        const samples = @as(Vec4f, @splat(@as(f32, @floatFromInt(x)))) + AA_SAMPLE_X;
        const count = maskCount((samples >= @as(Vec4f, @splat(start_x))) & (samples < @as(Vec4f, @splat(end_x))));
        path_scanline_coverage[@intCast(x)] += @intCast(count);
    }
}

fn drawPathScanlines(ctx: *ParserCtx, color: Color, segments: *const [MAX_PATH_SEGMENTS]PathSegment, seg_count: usize, x0: i32, y0: i32, x1: i32, y1: i32) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        @memset(path_scanline_coverage[@intCast(x0)..@intCast(x1 + 1)], 0);

        var sample_row: i32 = 0;
        while (sample_row < AA_GRID) : (sample_row += 1) {
            const sample_y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / @as(f32, @floatFromInt(AA_GRID));
            var intersection_count: usize = 0;
            var edge: usize = 0;
            while (edge < seg_count) : (edge += 1) {
                const segment = segments[edge];
                var delta: i32 = 0;
                if (segment.ay <= sample_y and segment.by > sample_y) {
                    delta = -1;
                } else if (segment.ay > sample_y and segment.by <= sample_y) {
                    delta = 1;
                } else {
                    continue;
                }
                const x = segment.ax + (sample_y - segment.ay) * (segment.bx - segment.ax) / (segment.by - segment.ay);
                path_intersections[intersection_count] = .{ .x = x, .winding_delta = delta };
                intersection_count += 1;
            }

            std.sort.heap(PathIntersection, path_intersections[0..intersection_count], {}, intersectionLessThan);
            var winding: i32 = 0;
            var intersection: usize = 0;
            while (intersection < intersection_count) {
                const span_start = path_intersections[intersection].x;
                while (intersection < intersection_count and path_intersections[intersection].x == span_start) : (intersection += 1) {
                    winding += path_intersections[intersection].winding_delta;
                }
                if (intersection < intersection_count and winding != 0) {
                    addScanlineSpanCoverage(ctx.width, span_start, path_intersections[intersection].x);
                }
            }
        }

        var x = x0;
        while (x <= x1) : (x += 1) {
            const covered = path_scanline_coverage[@intCast(x)];
            if (covered != 0) {
                blendPixelCoverage(ctx, x, y, color, @as(f32, @floatFromInt(covered)) / 16.0);
            }
        }
    }
}

fn drawRect(ctx: *ParserCtx, transform: Mat, color: Color, rect: Rect) void {
    if (!(rect.set_w and rect.set_h)) return;
    const inv = matInverse(transform) orelse return;
    const corners = [_][2]f32{
        matApply(transform, rect.x, rect.y),
        matApply(transform, rect.x + rect.w, rect.y),
        matApply(transform, rect.x, rect.y + rect.h),
        matApply(transform, rect.x + rect.w, rect.y + rect.h),
    };
    var min_x = corners[0][0];
    var max_x = corners[0][0];
    var min_y = corners[0][1];
    var max_y = corners[0][1];
    for (corners[1..]) |pt| {
        if (pt[0] < min_x) min_x = pt[0];
        if (pt[0] > max_x) max_x = pt[0];
        if (pt[1] < min_y) min_y = pt[1];
        if (pt[1] > max_y) max_y = pt[1];
    }
    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, rectCoverage(inv, x, y, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            if (local[0] >= rect.x and local[0] <= rect.x + rect.w and local[1] >= rect.y and local[1] <= rect.y + rect.h) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawRectStroke(ctx: *ParserCtx, transform: Mat, color: Color, rect: Rect, stroke_width: f32) void {
    if (!(rect.set_w and rect.set_h)) return;
    if (stroke_width <= 0) return;
    const inv = matInverse(transform) orelse return;
    const half_w = stroke_width * 0.5;
    const ox0_local = rect.x - half_w;
    const oy0_local = rect.y - half_w;
    const ox1_local = rect.x + rect.w + half_w;
    const oy1_local = rect.y + rect.h + half_w;
    const outer_corners = [_][2]f32{
        matApply(transform, ox0_local, oy0_local),
        matApply(transform, ox1_local, oy0_local),
        matApply(transform, ox0_local, oy1_local),
        matApply(transform, ox1_local, oy1_local),
    };
    var min_x = outer_corners[0][0];
    var max_x = outer_corners[0][0];
    var min_y = outer_corners[0][1];
    var max_y = outer_corners[0][1];
    for (outer_corners[1..]) |pt| {
        if (pt[0] < min_x) min_x = pt[0];
        if (pt[0] > max_x) max_x = pt[0];
        if (pt[1] < min_y) min_y = pt[1];
        if (pt[1] > max_y) max_y = pt[1];
    }
    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    const ix0 = rect.x + half_w;
    const iy0 = rect.y + half_w;
    const ix1 = rect.x + rect.w - half_w;
    const iy1 = rect.y + rect.h - half_w;
    const has_inner = ix0 <= ix1 and iy0 <= iy1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, rectStrokeCoverage(inv, x, y, ox0_local, oy0_local, ox1_local, oy1_local, ix0, iy0, ix1, iy1, has_inner));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);

            if (local[0] < ox0_local or local[0] > ox1_local or local[1] < oy0_local or local[1] > oy1_local) continue;

            var in_inner = false;
            if (has_inner) {
                in_inner = local[0] >= ix0 and local[0] <= ix1 and local[1] >= iy0 and local[1] <= iy1;
            }
            if (!in_inner) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawCircle(ctx: *ParserCtx, transform: Mat, color: Color, circle: Circle) void {
    if (!circle.set_r) return;
    const inv = matInverse(transform) orelse return;
    const center = matApply(transform, circle.cx, circle.cy);
    const rx = circle.r * std.math.sqrt(transform.a * transform.a + transform.c * transform.c);
    const ry = circle.r * std.math.sqrt(transform.b * transform.b + transform.d * transform.d);
    var x0: i32 = @intFromFloat(@floor(center[0] - rx));
    var x1: i32 = @intFromFloat(@ceil(center[0] + rx));
    var y0: i32 = @intFromFloat(@floor(center[1] - ry));
    var y1: i32 = @intFromFloat(@ceil(center[1] + ry));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;
    const r2 = circle.r * circle.r;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, circleCoverage(inv, x, y, circle.cx, circle.cy, 0.0, r2));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            const dx = local[0] - circle.cx;
            const dy = local[1] - circle.cy;
            if (dx * dx + dy * dy <= r2) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawCircleStroke(ctx: *ParserCtx, transform: Mat, color: Color, circle: Circle, stroke_width: f32) void {
    if (!circle.set_r) return;
    if (stroke_width <= 0) return;
    const inv = matInverse(transform) orelse return;
    const center = matApply(transform, circle.cx, circle.cy);
    const half_w = stroke_width * 0.5;
    const outer_r = circle.r + half_w;
    if (outer_r <= 0) return;
    const inner_r = if (circle.r - half_w > 0) circle.r - half_w else 0.0;
    const rx_outer = outer_r * std.math.sqrt(transform.a * transform.a + transform.c * transform.c);
    const ry_outer = outer_r * std.math.sqrt(transform.b * transform.b + transform.d * transform.d);
    var x0: i32 = @intFromFloat(@floor(center[0] - rx_outer));
    var x1: i32 = @intFromFloat(@ceil(center[0] + rx_outer));
    var y0: i32 = @intFromFloat(@floor(center[1] - ry_outer));
    var y1: i32 = @intFromFloat(@ceil(center[1] + ry_outer));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;
    const outer_r2 = outer_r * outer_r;
    const inner_r2 = inner_r * inner_r;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, circleCoverage(inv, x, y, circle.cx, circle.cy, inner_r2, outer_r2));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            const dx = local[0] - circle.cx;
            const dy = local[1] - circle.cy;
            const d2 = dx * dx + dy * dy;
            if (d2 <= outer_r2 and d2 >= inner_r2) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawPolygon(ctx: *ParserCtx, transform: Mat, color: Color, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) void {
    if (count < 3) return;
    const inv = matInverse(transform) orelse return;
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const pt = matApply(transform, xs[i], ys[i]);
        if (pt[0] < min_x) min_x = pt[0];
        if (pt[0] > max_x) max_x = pt[0];
        if (pt[1] < min_y) min_y = pt[1];
        if (pt[1] > max_y) max_y = pt[1];
    }
    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, polygonCoverage(inv, x, y, xs, ys, count));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            var inside = false;
            var j: usize = count - 1;
            var k: usize = 0;
            while (k < count) : (k += 1) {
                const xi = xs[k];
                const yi = ys[k];
                const xj = xs[j];
                const yj = ys[j];
                const intersect = (yi > local[1]) != (yj > local[1]) and
                    (local[0] < (xj - xi) * (local[1] - yi) / (yj - yi + 0.0000001) + xi);
                if (intersect) inside = !inside;
                j = k;
            }
            if (inside) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn parsePoints(value: []const u8, xs: *[MAX_POINTS]f32, ys: *[MAX_POINTS]f32, count: *usize) void {
    var idx: usize = 0;
    var have_x = false;
    var current_x: f32 = 0;
    count.* = 0;
    while (idx < value.len) {
        skipWs(value, &idx);
        if (idx < value.len and value[idx] == ',') {
            idx += 1;
            continue;
        }
        if (parseFloat(value, &idx)) |v| {
            if (!have_x) {
                current_x = v;
                have_x = true;
            } else {
                if (count.* < MAX_POINTS) {
                    xs[count.*] = current_x;
                    ys[count.*] = v;
                    count.* += 1;
                }
                have_x = false;
            }
        } else {
            idx += 1;
        }
    }
}

fn pointSegmentDistSq(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const wx = px - ax;
    const wy = py - ay;
    const vv = vx * vx + vy * vy;
    if (vv <= 0.0000001) {
        return wx * wx + wy * wy;
    }
    var t = (wx * vx + wy * vy) / vv;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    const cx = ax + t * vx;
    const cy = ay + t * vy;
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy;
}

fn drawPolygonStroke(ctx: *ParserCtx, transform: Mat, color: Color, stroke_width: f32, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) void {
    if (count < 2) return;
    if (stroke_width <= 0) return;
    const inv = matInverse(transform) orelse return;
    const half_w = stroke_width * 0.5;
    const half_w2 = half_w * half_w;
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const pt = matApply(transform, xs[i], ys[i]);
        if (pt[0] < min_x) min_x = pt[0];
        if (pt[0] > max_x) max_x = pt[0];
        if (pt[1] < min_y) min_y = pt[1];
        if (pt[1] > max_y) max_y = pt[1];
    }
    const pad = half_w * matMaxScale(transform) + 1.0;
    var x0: i32 = @intFromFloat(@floor(min_x - pad));
    var y0: i32 = @intFromFloat(@floor(min_y - pad));
    var x1: i32 = @intFromFloat(@ceil(max_x + pad));
    var y1: i32 = @intFromFloat(@ceil(max_y + pad));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, polygonStrokeCoverage(inv, x, y, xs, ys, count, half_w2));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);

            var near_edge = false;
            var j: usize = count - 1;
            var k: usize = 0;
            while (k < count) : (k += 1) {
                const d2 = pointSegmentDistSq(local[0], local[1], xs[j], ys[j], xs[k], ys[k]);
                if (d2 <= half_w2) {
                    near_edge = true;
                    break;
                }
                j = k;
            }
            if (near_edge) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawSegmentStroke(ctx: *ParserCtx, transform: Mat, color: Color, stroke_width: f32, ax: f32, ay: f32, bx: f32, by: f32) void {
    if (color.a == 0) return;
    if (stroke_width <= 0) return;
    const inv = matInverse(transform) orelse return;
    const half_w = stroke_width * 0.5;
    const half_w2 = half_w * half_w;
    const p0 = matApply(transform, ax, ay);
    const p1 = matApply(transform, bx, by);
    var min_x = if (p0[0] < p1[0]) p0[0] else p1[0];
    var max_x = if (p0[0] > p1[0]) p0[0] else p1[0];
    var min_y = if (p0[1] < p1[1]) p0[1] else p1[1];
    var max_y = if (p0[1] > p1[1]) p0[1] else p1[1];
    const pad = half_w * matMaxScale(transform) + 1.0;
    min_x -= pad;
    min_y -= pad;
    max_x += pad;
    max_y += pad;

    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, segmentStrokeCoverage(inv, x, y, ax, ay, bx, by, half_w2));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            const d2 = pointSegmentDistSq(local[0], local[1], ax, ay, bx, by);
            if (d2 <= half_w2) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawPolylineStroke(ctx: *ParserCtx, transform: Mat, color: Color, stroke_width: f32, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize, closed: bool) void {
    if (count < 2) return;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        drawSegmentStroke(ctx, transform, color, stroke_width, xs[i - 1], ys[i - 1], xs[i], ys[i]);
    }
    if (closed and count >= 3) {
        drawSegmentStroke(ctx, transform, color, stroke_width, xs[count - 1], ys[count - 1], xs[0], ys[0]);
    }
}

fn cubicPoint(t: f32, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32) [2]f32 {
    const u = 1.0 - t;
    const uu = u * u;
    const uuu = uu * u;
    const tt = t * t;
    const ttt = tt * t;
    return .{
        uuu * p0[0] + 3.0 * uu * t * p1[0] + 3.0 * u * tt * p2[0] + ttt * p3[0],
        uuu * p0[1] + 3.0 * uu * t * p1[1] + 3.0 * u * tt * p2[1] + ttt * p3[1],
    };
}

fn quadPoint(t: f32, p0: [2]f32, p1: [2]f32, p2: [2]f32) [2]f32 {
    const u = 1.0 - t;
    const uu = u * u;
    const tt = t * t;
    return .{
        uu * p0[0] + 2.0 * u * t * p1[0] + tt * p2[0],
        uu * p0[1] + 2.0 * u * t * p1[1] + tt * p2[1],
    };
}

fn drawCubicStroke(ctx: *ParserCtx, transform: Mat, color: Color, stroke_width: f32, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32) void {
    const steps: usize = 20;
    var prev = p0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const pt = cubicPoint(t, p0, p1, p2, p3);
        drawSegmentStroke(ctx, transform, color, stroke_width, prev[0], prev[1], pt[0], pt[1]);
        prev = pt;
    }
}

fn drawQuadStroke(ctx: *ParserCtx, transform: Mat, color: Color, stroke_width: f32, p0: [2]f32, p1: [2]f32, p2: [2]f32) void {
    const steps: usize = 14;
    var prev = p0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const pt = quadPoint(t, p0, p1, p2);
        drawSegmentStroke(ctx, transform, color, stroke_width, prev[0], prev[1], pt[0], pt[1]);
        prev = pt;
    }
}

fn addPathSegment(segments: *[MAX_PATH_SEGMENTS]PathSegment, seg_count: *usize, ax: f32, ay: f32, bx: f32, by: f32) void {
    if (seg_count.* >= MAX_PATH_SEGMENTS) return;
    segments[seg_count.*] = .{ .ax = ax, .ay = ay, .bx = bx, .by = by };
    seg_count.* += 1;
}

fn drawCubicFillSegments(segments: *[MAX_PATH_SEGMENTS]PathSegment, seg_count: *usize, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32) void {
    const steps: usize = 20;
    var prev = p0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const pt = cubicPoint(t, p0, p1, p2, p3);
        addPathSegment(segments, seg_count, prev[0], prev[1], pt[0], pt[1]);
        prev = pt;
    }
}

fn drawQuadFillSegments(segments: *[MAX_PATH_SEGMENTS]PathSegment, seg_count: *usize, p0: [2]f32, p1: [2]f32, p2: [2]f32) void {
    const steps: usize = 14;
    var prev = p0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const pt = quadPoint(t, p0, p1, p2);
        addPathSegment(segments, seg_count, prev[0], prev[1], pt[0], pt[1]);
        prev = pt;
    }
}

fn pointLeftOfSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    return (bx - ax) * (py - ay) - (px - ax) * (by - ay);
}

fn pathPointsEqual(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) <= 0.0001 and @abs(a[1] - b[1]) <= 0.0001;
}

fn drawPathFill(ctx: *ParserCtx, transform: Mat, color: Color, d: []const u8) void {
    if (color.a == 0) return;
    var segments: [MAX_PATH_SEGMENTS]PathSegment = undefined;
    var seg_count: usize = 0;
    var idx: usize = 0;
    var cmd: u8 = 0;
    var cur = [2]f32{ 0, 0 };
    var sub_start = [2]f32{ 0, 0 };
    var sub_active = false;
    var sub_has_edges = false;
    var prev_cubic_ctrl = [2]f32{ 0, 0 };
    var prev_quad_ctrl = [2]f32{ 0, 0 };
    var has_prev_cubic = false;
    var has_prev_quad = false;

    while (idx < d.len) {
        skipWsCommas(d, &idx);
        if (idx >= d.len) break;

        if (isAlpha(d[idx])) {
            cmd = d[idx];
            idx += 1;
        } else if (cmd == 0) {
            break;
        }

        const cmd_upper = toUpperASCII(cmd);
        const rel = cmd >= 'a' and cmd <= 'z';

        switch (cmd_upper) {
            'M' => {
                if (sub_active and sub_has_edges and !pathPointsEqual(cur, sub_start)) {
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], sub_start[0], sub_start[1]);
                }
                const x = parsePathNumber(d, &idx) orelse break;
                const y = parsePathNumber(d, &idx) orelse break;
                cur = if (rel) .{ cur[0] + x, cur[1] + y } else .{ x, y };
                sub_start = cur;
                sub_active = true;
                sub_has_edges = false;
                has_prev_cubic = false;
                has_prev_quad = false;

                while (true) {
                    const lx = parsePathNumber(d, &idx) orelse break;
                    const ly = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) .{ cur[0] + lx, cur[1] + ly } else .{ lx, ly };
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                }
            },
            'L' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) .{ cur[0] + x, cur[1] + y } else .{ x, y };
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'H' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const nx = if (rel) cur[0] + x else x;
                    const next = [2]f32{ nx, cur[1] };
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'V' => {
                while (true) {
                    const y = parsePathNumber(d, &idx) orelse break;
                    const ny = if (rel) cur[1] + y else y;
                    const next = [2]f32{ cur[0], ny };
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'C' => {
                while (true) {
                    const x1 = parsePathNumber(d, &idx) orelse break;
                    const y1 = parsePathNumber(d, &idx) orelse break;
                    const x2 = parsePathNumber(d, &idx) orelse break;
                    const y2 = parsePathNumber(d, &idx) orelse break;
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c1 = if (rel) [2]f32{ cur[0] + x1, cur[1] + y1 } else [2]f32{ x1, y1 };
                    const c2 = if (rel) [2]f32{ cur[0] + x2, cur[1] + y2 } else [2]f32{ x2, y2 };
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawCubicFillSegments(&segments, &seg_count, cur, c1, c2, next);
                    cur = next;
                    sub_has_edges = true;
                    prev_cubic_ctrl = c2;
                    has_prev_cubic = true;
                    has_prev_quad = false;
                }
            },
            'S' => {
                while (true) {
                    const x2 = parsePathNumber(d, &idx) orelse break;
                    const y2 = parsePathNumber(d, &idx) orelse break;
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c1 = if (has_prev_cubic) [2]f32{ 2.0 * cur[0] - prev_cubic_ctrl[0], 2.0 * cur[1] - prev_cubic_ctrl[1] } else cur;
                    const c2 = if (rel) [2]f32{ cur[0] + x2, cur[1] + y2 } else [2]f32{ x2, y2 };
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawCubicFillSegments(&segments, &seg_count, cur, c1, c2, next);
                    cur = next;
                    sub_has_edges = true;
                    prev_cubic_ctrl = c2;
                    has_prev_cubic = true;
                    has_prev_quad = false;
                }
            },
            'Q' => {
                while (true) {
                    const x1 = parsePathNumber(d, &idx) orelse break;
                    const y1 = parsePathNumber(d, &idx) orelse break;
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c = if (rel) [2]f32{ cur[0] + x1, cur[1] + y1 } else [2]f32{ x1, y1 };
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawQuadFillSegments(&segments, &seg_count, cur, c, next);
                    cur = next;
                    sub_has_edges = true;
                    prev_quad_ctrl = c;
                    has_prev_quad = true;
                    has_prev_cubic = false;
                }
            },
            'T' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c = if (has_prev_quad) [2]f32{ 2.0 * cur[0] - prev_quad_ctrl[0], 2.0 * cur[1] - prev_quad_ctrl[1] } else cur;
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawQuadFillSegments(&segments, &seg_count, cur, c, next);
                    cur = next;
                    sub_has_edges = true;
                    prev_quad_ctrl = c;
                    has_prev_quad = true;
                    has_prev_cubic = false;
                }
            },
            'A' => {
                // Arc support fallback: connect start->end so closed shapes still fill.
                while (true) {
                    _ = parsePathNumber(d, &idx) orelse break; // rx
                    _ = parsePathNumber(d, &idx) orelse break; // ry
                    _ = parsePathNumber(d, &idx) orelse break; // x-axis-rotation
                    _ = parsePathNumber(d, &idx) orelse break; // large-arc-flag
                    _ = parsePathNumber(d, &idx) orelse break; // sweep-flag
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'Z' => {
                if (sub_active and sub_has_edges and !pathPointsEqual(cur, sub_start)) {
                    addPathSegment(&segments, &seg_count, cur[0], cur[1], sub_start[0], sub_start[1]);
                }
                cur = sub_start;
                sub_has_edges = false;
                has_prev_cubic = false;
                has_prev_quad = false;
            },
            else => break,
        }
    }

    if (sub_active and sub_has_edges and !pathPointsEqual(cur, sub_start)) {
        addPathSegment(&segments, &seg_count, cur[0], cur[1], sub_start[0], sub_start[1]);
    }
    if (seg_count == 0) return;

    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);

    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const p0 = matApply(transform, segments[i].ax, segments[i].ay);
        const p1 = matApply(transform, segments[i].bx, segments[i].by);
        if (ANTIALIAS) {
            segments[i] = .{ .ax = p0[0], .ay = p0[1], .bx = p1[0], .by = p1[1] };
        }
        if (p0[0] < min_x) min_x = p0[0];
        if (p1[0] < min_x) min_x = p1[0];
        if (p0[0] > max_x) max_x = p0[0];
        if (p1[0] > max_x) max_x = p1[0];
        if (p0[1] < min_y) min_y = p0[1];
        if (p1[1] < min_y) min_y = p1[1];
        if (p0[1] > max_y) max_y = p0[1];
        if (p1[1] > max_y) max_y = p1[1];
    }

    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;
    if (x0 > x1 or y0 > y1) return;

    if (ANTIALIAS) {
        drawPathScanlines(ctx, color, &segments, seg_count, x0, y0, x1, y1);
        return;
    }

    const inv = matInverse(transform) orelse return;
    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);

            var winding: i32 = 0;
            var j: usize = 0;
            while (j < seg_count) : (j += 1) {
                const ax = segments[j].ax;
                const ay = segments[j].ay;
                const bx = segments[j].bx;
                const by = segments[j].by;
                if (ay <= local[1]) {
                    if (by > local[1] and pointLeftOfSegment(local[0], local[1], ax, ay, bx, by) > 0) {
                        winding += 1;
                    }
                } else {
                    if (by <= local[1] and pointLeftOfSegment(local[0], local[1], ax, ay, bx, by) < 0) {
                        winding -= 1;
                    }
                }
            }
            if (winding != 0) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawPathStroke(ctx: *ParserCtx, transform: Mat, color: Color, stroke_width: f32, d: []const u8) void {
    if (color.a == 0) return;
    if (stroke_width <= 0) return;
    var idx: usize = 0;
    var cmd: u8 = 0;
    var cur = [2]f32{ 0, 0 };
    var sub_start = [2]f32{ 0, 0 };
    var prev_cubic_ctrl = [2]f32{ 0, 0 };
    var prev_quad_ctrl = [2]f32{ 0, 0 };
    var has_prev_cubic = false;
    var has_prev_quad = false;

    while (idx < d.len) {
        skipWsCommas(d, &idx);
        if (idx >= d.len) break;

        if (isAlpha(d[idx])) {
            cmd = d[idx];
            idx += 1;
        } else if (cmd == 0) {
            break;
        }

        const cmd_upper = toUpperASCII(cmd);
        const rel = cmd >= 'a' and cmd <= 'z';

        switch (cmd_upper) {
            'M' => {
                const x = parsePathNumber(d, &idx) orelse break;
                const y = parsePathNumber(d, &idx) orelse break;
                cur = if (rel) .{ cur[0] + x, cur[1] + y } else .{ x, y };
                sub_start = cur;
                has_prev_cubic = false;
                has_prev_quad = false;

                while (true) {
                    const lx = parsePathNumber(d, &idx) orelse break;
                    const ly = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) .{ cur[0] + lx, cur[1] + ly } else .{ lx, ly };
                    drawSegmentStroke(ctx, transform, color, stroke_width, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                }
            },
            'L' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) .{ cur[0] + x, cur[1] + y } else .{ x, y };
                    drawSegmentStroke(ctx, transform, color, stroke_width, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'H' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const nx = if (rel) cur[0] + x else x;
                    const next = [2]f32{ nx, cur[1] };
                    drawSegmentStroke(ctx, transform, color, stroke_width, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'V' => {
                while (true) {
                    const y = parsePathNumber(d, &idx) orelse break;
                    const ny = if (rel) cur[1] + y else y;
                    const next = [2]f32{ cur[0], ny };
                    drawSegmentStroke(ctx, transform, color, stroke_width, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'C' => {
                while (true) {
                    const x1 = parsePathNumber(d, &idx) orelse break;
                    const y1 = parsePathNumber(d, &idx) orelse break;
                    const x2 = parsePathNumber(d, &idx) orelse break;
                    const y2 = parsePathNumber(d, &idx) orelse break;
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c1 = if (rel) [2]f32{ cur[0] + x1, cur[1] + y1 } else [2]f32{ x1, y1 };
                    const c2 = if (rel) [2]f32{ cur[0] + x2, cur[1] + y2 } else [2]f32{ x2, y2 };
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawCubicStroke(ctx, transform, color, stroke_width, cur, c1, c2, next);
                    cur = next;
                    prev_cubic_ctrl = c2;
                    has_prev_cubic = true;
                    has_prev_quad = false;
                }
            },
            'S' => {
                while (true) {
                    const x2 = parsePathNumber(d, &idx) orelse break;
                    const y2 = parsePathNumber(d, &idx) orelse break;
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c1 = if (has_prev_cubic) [2]f32{ 2.0 * cur[0] - prev_cubic_ctrl[0], 2.0 * cur[1] - prev_cubic_ctrl[1] } else cur;
                    const c2 = if (rel) [2]f32{ cur[0] + x2, cur[1] + y2 } else [2]f32{ x2, y2 };
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawCubicStroke(ctx, transform, color, stroke_width, cur, c1, c2, next);
                    cur = next;
                    prev_cubic_ctrl = c2;
                    has_prev_cubic = true;
                    has_prev_quad = false;
                }
            },
            'Q' => {
                while (true) {
                    const x1 = parsePathNumber(d, &idx) orelse break;
                    const y1 = parsePathNumber(d, &idx) orelse break;
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c = if (rel) [2]f32{ cur[0] + x1, cur[1] + y1 } else [2]f32{ x1, y1 };
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawQuadStroke(ctx, transform, color, stroke_width, cur, c, next);
                    cur = next;
                    prev_quad_ctrl = c;
                    has_prev_quad = true;
                    has_prev_cubic = false;
                }
            },
            'T' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const c = if (has_prev_quad) [2]f32{ 2.0 * cur[0] - prev_quad_ctrl[0], 2.0 * cur[1] - prev_quad_ctrl[1] } else cur;
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawQuadStroke(ctx, transform, color, stroke_width, cur, c, next);
                    cur = next;
                    prev_quad_ctrl = c;
                    has_prev_quad = true;
                    has_prev_cubic = false;
                }
            },
            'A' => {
                // Arc support fallback: connect start->end so icons still render basic geometry.
                while (true) {
                    _ = parsePathNumber(d, &idx) orelse break; // rx
                    _ = parsePathNumber(d, &idx) orelse break; // ry
                    _ = parsePathNumber(d, &idx) orelse break; // x-axis-rotation
                    _ = parsePathNumber(d, &idx) orelse break; // large-arc-flag
                    _ = parsePathNumber(d, &idx) orelse break; // sweep-flag
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) [2]f32{ cur[0] + x, cur[1] + y } else [2]f32{ x, y };
                    drawSegmentStroke(ctx, transform, color, stroke_width, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'Z' => {
                drawSegmentStroke(ctx, transform, color, stroke_width, cur[0], cur[1], sub_start[0], sub_start[1]);
                cur = sub_start;
                has_prev_cubic = false;
                has_prev_quad = false;
            },
            else => {
                // Unknown command: stop path parsing.
                break;
            },
        }
    }
}

fn parseAttributes(input: []const u8, idx: *usize, base_fill: Color, base_stroke: Color, base_stroke_width: f32, base_transform: Mat, rect: *Rect, circle: *Circle, line: *Line, xs: *[MAX_POINTS]f32, ys: *[MAX_POINTS]f32, poly_count: *usize, path_d: *?[]const u8, attr_fill: *Color, fill_set: *bool, attr_stroke: *Color, stroke_set: *bool, attr_stroke_width: *f32, stroke_width_set: *bool, attr_transform: *Mat, transform_set: *bool, self_closing: *bool) void {
    while (idx.* < input.len) {
        skipWs(input, idx);
        if (idx.* >= input.len) return;
        if (input[idx.*] == '/') {
            if (idx.* + 1 < input.len and input[idx.* + 1] == '>') {
                idx.* += 2;
                self_closing.* = true;
                return;
            }
        }
        if (input[idx.*] == '>') {
            idx.* += 1;
            return;
        }
        const name = readName(input, idx);
        skipWs(input, idx);
        if (idx.* >= input.len or input[idx.*] != '=') continue;
        idx.* += 1;
        skipWs(input, idx);
        const value = readQuoted(input, idx);
        if (value.len == 0) continue;

        if (strEq(name, "fill")) {
            if (parseColor(value)) |c| {
                attr_fill.* = c;
                fill_set.* = true;
            }
        } else if (strEq(name, "stroke")) {
            if (parseColor(value)) |c| {
                attr_stroke.* = c;
                stroke_set.* = true;
            }
        } else if (strEq(name, "stroke-width")) {
            if (parseNumber(value)) |v| {
                attr_stroke_width.* = if (v > 0) v else 0;
                stroke_width_set.* = true;
            }
        } else if (strEq(name, "transform")) {
            attr_transform.* = parseTransform(value);
            transform_set.* = true;
        } else if (strEq(name, "x")) {
            if (parseNumber(value)) |v| {
                rect.x = v;
                rect.set_x = true;
            }
        } else if (strEq(name, "y")) {
            if (parseNumber(value)) |v| {
                rect.y = v;
                rect.set_y = true;
            }
        } else if (strEq(name, "width")) {
            if (parseNumber(value)) |v| {
                rect.w = v;
                rect.set_w = true;
            }
        } else if (strEq(name, "height")) {
            if (parseNumber(value)) |v| {
                rect.h = v;
                rect.set_h = true;
            }
        } else if (strEq(name, "cx")) {
            if (parseNumber(value)) |v| {
                circle.cx = v;
                circle.set_cx = true;
            }
        } else if (strEq(name, "cy")) {
            if (parseNumber(value)) |v| {
                circle.cy = v;
                circle.set_cy = true;
            }
        } else if (strEq(name, "r")) {
            if (parseNumber(value)) |v| {
                circle.r = v;
                circle.set_r = true;
            }
        } else if (strEq(name, "points")) {
            parsePoints(value, xs, ys, poly_count);
        } else if (strEq(name, "x1")) {
            if (parseNumber(value)) |v| {
                line.x1 = v;
                line.set_x1 = true;
            }
        } else if (strEq(name, "y1")) {
            if (parseNumber(value)) |v| {
                line.y1 = v;
                line.set_y1 = true;
            }
        } else if (strEq(name, "x2")) {
            if (parseNumber(value)) |v| {
                line.x2 = v;
                line.set_x2 = true;
            }
        } else if (strEq(name, "y2")) {
            if (parseNumber(value)) |v| {
                line.y2 = v;
                line.set_y2 = true;
            }
        } else if (strEq(name, "d")) {
            path_d.* = value;
        }
    }
    _ = base_fill;
    _ = base_stroke;
    _ = base_stroke_width;
    _ = base_transform;
}

fn skipSpecial(input: []const u8, idx: *usize) void {
    if (idx.* >= input.len) return;
    if (input[idx.*] == '?') {
        while (idx.* + 1 < input.len) : (idx.* += 1) {
            if (input[idx.*] == '?' and input[idx.* + 1] == '>') {
                idx.* += 2;
                return;
            }
        }
    } else if (input[idx.*] == '!') {
        if (idx.* + 2 < input.len and input[idx.* + 1] == '-' and input[idx.* + 2] == '-') {
            idx.* += 3;
            while (idx.* + 2 < input.len) : (idx.* += 1) {
                if (input[idx.*] == '-' and input[idx.* + 1] == '-' and input[idx.* + 2] == '>') {
                    idx.* += 3;
                    return;
                }
            }
        } else {
            while (idx.* < input.len and input[idx.*] != '>') idx.* += 1;
            if (idx.* < input.len) idx.* += 1;
        }
    }
}

// <g>/<svg> nesting is tracked with an explicit stack instead of recursion:
// the strict wasm profile requires an acyclic call graph, and a fixed cap
// makes the nesting bound deterministic instead of stack-size dependent.
// The old recursive version overflowed the 64 KiB wasm stack around 25
// levels; this allows 128 and traps cleanly past that.
const MAX_GROUP_DEPTH: usize = 128;

const GroupFrame = struct {
    end_tag: []const u8,
    transform: Mat,
    fill: Color,
    stroke: Color,
    stroke_width: f32,
};

fn parseElements(ctx: *ParserCtx, idx: *usize, root_transform: Mat, root_fill: Color, root_stroke: Color, root_stroke_width: f32) void {
    const input = ctx.input;
    var group_stack: [MAX_GROUP_DEPTH]GroupFrame = undefined;
    var group_depth: usize = 0;
    var transform = root_transform;
    var fill = root_fill;
    var stroke = root_stroke;
    var stroke_width = root_stroke_width;

    while (idx.* < input.len) {
        while (idx.* < input.len and input[idx.*] != '<') idx.* += 1;
        if (idx.* >= input.len) return;
        idx.* += 1;
        if (idx.* >= input.len) return;

        if (input[idx.*] == '/') {
            idx.* += 1;
            skipWs(input, idx);
            const name = readName(input, idx);
            while (idx.* < input.len and input[idx.*] != '>') idx.* += 1;
            if (idx.* < input.len) idx.* += 1;
            if (group_depth > 0 and strEq(name, group_stack[group_depth - 1].end_tag)) {
                group_depth -= 1;
                transform = group_stack[group_depth].transform;
                fill = group_stack[group_depth].fill;
                stroke = group_stack[group_depth].stroke;
                stroke_width = group_stack[group_depth].stroke_width;
            }
            continue;
        }
        if (input[idx.*] == '?' or input[idx.*] == '!') {
            skipSpecial(input, idx);
            continue;
        }

        const name = readName(input, idx);
        var rect = Rect{};
        var circle = Circle{};
        var line = Line{};
        var xs: [MAX_POINTS]f32 = undefined;
        var ys: [MAX_POINTS]f32 = undefined;
        var poly_count: usize = 0;
        var path_d: ?[]const u8 = null;
        var attr_fill = fill;
        var fill_set = false;
        var attr_stroke = stroke;
        var stroke_set = false;
        var attr_stroke_width = stroke_width;
        var stroke_width_set = false;
        var attr_transform = matIdentity();
        var transform_set = false;
        var self_closing = false;

        parseAttributes(input, idx, fill, stroke, stroke_width, transform, &rect, &circle, &line, &xs, &ys, &poly_count, &path_d, &attr_fill, &fill_set, &attr_stroke, &stroke_set, &attr_stroke_width, &stroke_width_set, &attr_transform, &transform_set, &self_closing);

        const final_transform = if (transform_set) matMul(transform, attr_transform) else transform;
        const final_fill = if (fill_set) attr_fill else fill;
        const final_stroke = if (stroke_set) attr_stroke else stroke;
        const final_stroke_width = if (stroke_width_set) attr_stroke_width else stroke_width;

        if (strEq(name, "g") or strEq(name, "svg")) {
            if (!self_closing) {
                if (group_depth >= MAX_GROUP_DEPTH) @trap();
                group_stack[group_depth] = .{
                    .end_tag = name,
                    .transform = transform,
                    .fill = fill,
                    .stroke = stroke,
                    .stroke_width = stroke_width,
                };
                group_depth += 1;
                transform = final_transform;
                fill = final_fill;
                stroke = final_stroke;
                stroke_width = final_stroke_width;
            }
        } else if (strEq(name, "rect")) {
            drawRect(ctx, final_transform, final_fill, rect);
            drawRectStroke(ctx, final_transform, final_stroke, rect, final_stroke_width);
        } else if (strEq(name, "circle")) {
            drawCircle(ctx, final_transform, final_fill, circle);
            drawCircleStroke(ctx, final_transform, final_stroke, circle, final_stroke_width);
        } else if (strEq(name, "polygon")) {
            drawPolygon(ctx, final_transform, final_fill, &xs, &ys, poly_count);
            drawPolygonStroke(ctx, final_transform, final_stroke, final_stroke_width, &xs, &ys, poly_count);
        } else if (strEq(name, "polyline")) {
            drawPolylineStroke(ctx, final_transform, final_stroke, final_stroke_width, &xs, &ys, poly_count, false);
        } else if (strEq(name, "line")) {
            if (line.set_x1 and line.set_y1 and line.set_x2 and line.set_y2) {
                drawSegmentStroke(ctx, final_transform, final_stroke, final_stroke_width, line.x1, line.y1, line.x2, line.y2);
            }
        } else if (strEq(name, "path")) {
            if (path_d) |d| {
                drawPathFill(ctx, final_transform, final_fill, d);
                drawPathStroke(ctx, final_transform, final_stroke, final_stroke_width, d);
            }
        }
    }
}

const SvgViewport = struct {
    width: u32,
    height: u32,
    transform: Mat,
};

fn parseViewBox(value: []const u8) ?[4]f32 {
    var result: [4]f32 = undefined;
    var idx: usize = 0;
    var count: usize = 0;
    while (count < result.len) : (count += 1) {
        skipWsCommas(value, &idx);
        result[count] = parseFloat(value, &idx) orelse return null;
    }
    skipWsCommas(value, &idx);
    if (idx != value.len or result[2] <= 0 or result[3] <= 0) return null;
    return result;
}

fn findSvgViewport(input: []const u8) ?SvgViewport {
    var idx: usize = 0;
    while (idx + 4 < input.len) : (idx += 1) {
        if (input[idx] == '<' and input[idx + 1] == 's' and input[idx + 2] == 'v' and input[idx + 3] == 'g') {
            idx += 4;
            var width: ?u32 = null;
            var height: ?u32 = null;
            var view_box: ?[4]f32 = null;
            while (idx < input.len) {
                skipWs(input, &idx);
                if (idx >= input.len) break;
                if (input[idx] == '>') {
                    idx += 1;
                    break;
                }
                if (input[idx] == '/' and idx + 1 < input.len and input[idx + 1] == '>') {
                    idx += 2;
                    break;
                }
                const name = readName(input, &idx);
                skipWs(input, &idx);
                if (idx >= input.len or input[idx] != '=') continue;
                idx += 1;
                skipWs(input, &idx);
                const value = readQuoted(input, &idx);
                if (strEq(name, "width")) {
                    if (parseNumber(value)) |v| width = @intFromFloat(v);
                } else if (strEq(name, "height")) {
                    if (parseNumber(value)) |v| height = @intFromFloat(v);
                } else if (strEq(name, "viewBox")) {
                    view_box = parseViewBox(value);
                }
            }

            const resolved_width = if (ANTIALIAS and output_width != 0)
                output_width
            else if (width) |value|
                value
            else if (view_box) |box|
                @as(u32, @intFromFloat(@ceil(box[2])))
            else
                return null;
            const resolved_height = if (ANTIALIAS and output_height != 0)
                output_height
            else if (height) |value|
                value
            else if (view_box) |box|
                @as(u32, @intFromFloat(@ceil(box[3])))
            else
                return null;

            var transform = matIdentity();
            if (view_box) |box| {
                const sx = @as(f32, @floatFromInt(resolved_width)) / box[2];
                const sy = @as(f32, @floatFromInt(resolved_height)) / box[3];
                const scale = @min(sx, sy);
                transform = .{
                    .a = scale,
                    .b = 0,
                    .c = 0,
                    .d = scale,
                    .tx = (@as(f32, @floatFromInt(resolved_width)) - box[2] * scale) * 0.5 - box[0] * scale,
                    .ty = (@as(f32, @floatFromInt(resolved_height)) - box[3] * scale) * 0.5 - box[1] * scale,
                };
            }
            return .{ .width = resolved_width, .height = resolved_height, .transform = transform };
        }
    }
    return null;
}

fn writeU16LE(buf: []u8, off: u32, value: u16) void {
    buf[off] = @intCast(value & 0xFF);
    buf[off + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32LE(buf: []u8, off: u32, value: u32) void {
    buf[off] = @intCast(value & 0xFF);
    buf[off + 1] = @intCast((value >> 8) & 0xFF);
    buf[off + 2] = @intCast((value >> 16) & 0xFF);
    buf[off + 3] = @intCast((value >> 24) & 0xFF);
}

fn renderImpl(input_size: u32) ?u32 {
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    const viewport = findSvgViewport(input) orelse return null;
    const width = viewport.width;
    const height = viewport.height;
    if (width == 0 or height == 0) return null;
    if (width > MAX_DIMENSION or height > MAX_DIMENSION or
        @as(u64, width) * @as(u64, height) > MAX_PIXELS) return null;

    const pixel_count: u64 = @as(u64, width) * @as(u64, height);
    const pixel_bytes: u64 = pixel_count * OUTPUT_PIXEL_SIZE;
    const work_pixel_bytes: u64 = pixel_count * WORK_PIXEL_SIZE;
    const header_size: u32 = OUTPUT_HEADER_SIZE;
    const needed: u64 = @as(u64, header_size) + pixel_bytes;
    const work_needed: u64 = @as(u64, header_size) + work_pixel_bytes;
    if (needed > OUTPUT_CAP) return null;
    if (work_needed > WORK_CAP) return null;
    const work_needed_usize: usize = @intCast(work_needed);

    var i: usize = 0;
    while (i < header_size) : (i += 1) {
        output_buf[i] = 0;
    }
    const bg = colorFromRgba(background_color_rgba);
    var off: usize = header_size;
    while (off < work_needed_usize) : (off += WORK_PIXEL_SIZE) {
        if (ANTIALIAS) {
            const alpha = @as(f32, @floatFromInt(bg.a)) / 255.0;
            const pixel: *align(1) Vec4f = @ptrCast(&output_buf[off]);
            pixel.* = .{
                ktx2_float.SRGB8_TO_LINEAR[bg.r] * alpha,
                ktx2_float.SRGB8_TO_LINEAR[bg.g] * alpha,
                ktx2_float.SRGB8_TO_LINEAR[bg.b] * alpha,
                alpha,
            };
        } else {
            output_buf[off] = if (OUTPUT_KTX2) bg.r else bg.b;
            output_buf[off + 1] = bg.g;
            output_buf[off + 2] = if (OUTPUT_KTX2) bg.b else bg.r;
            output_buf[off + 3] = bg.a;
        }
    }

    if (OUTPUT_FLOAT) {
        _ = ktx2_float.writeHeader(&output_buf, width, height) orelse return null;
    } else if (OUTPUT_KTX2) {
        _ = ktx2.writeHeader(&output_buf, width, height) orelse return null;
    } else {
        // BMP header (BITMAPFILEHEADER + BITMAPINFOHEADER).
        output_buf[0] = 'B';
        output_buf[1] = 'M';
        writeU32LE(output_buf[0..], 2, @intCast(needed));
        writeU32LE(output_buf[0..], 6, 0);
        writeU32LE(output_buf[0..], 10, header_size);
        writeU32LE(output_buf[0..], 14, 40);
        writeU32LE(output_buf[0..], 18, width);
        writeU32LE(output_buf[0..], 22, height);
        writeU16LE(output_buf[0..], 26, 1);
        writeU16LE(output_buf[0..], 28, 32);
        writeU32LE(output_buf[0..], 30, 0);
        writeU32LE(output_buf[0..], 34, @intCast(pixel_bytes));
        writeU32LE(output_buf[0..], 38, 2835);
        writeU32LE(output_buf[0..], 42, 2835);
        writeU32LE(output_buf[0..], 46, 0);
        writeU32LE(output_buf[0..], 50, 0);
    }

    var ctx = ParserCtx{
        .input = input,
        .width = width,
        .height = height,
        .pixel_base = header_size,
        .out_len = @intCast(needed),
    };
    var idx: usize = 0;
    const default_fill = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const default_stroke = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    parseElements(&ctx, &idx, viewport.transform, default_fill, default_stroke, 1.0);
    finishAntialiasedPixels(&ctx);

    return ctx.out_len;
}

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

noinline fn renderOutcome(input_size: u32) RenderOutcome {
    defer resetBackgroundColorUniform();
    const output_size = renderImpl(input_size) orelse {
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{
        .output_size_or_failure = output_size,
        .output_ptr = @intFromPtr(&output_buf),
        .failed = 0,
    };
}

export fn render(input_size: u32) RenderResult {
    const outcome = renderOutcome(input_size);
    const output_size_or_failure = outcome.output_size_or_failure;
    if (output_size_or_failure > OUTPUT_CAP) @trap();
    return .{
        .output_size_or_failure = output_size_or_failure,
        .output_ptr = if (outcome.failed == 1) 0 else @intCast(outcome.output_ptr),
        .failed = outcome.failed,
    };
}

pub fn renderForTest(input: []const u8) []const u8 {
    if (input.len > INPUT_CAP) @panic("test input exceeds SVG input capacity");
    @memcpy(input_buf[0..input.len], input);
    const outcome = renderOutcome(@intCast(input.len));
    if (outcome.failed == 1) @panic("test SVG was rejected");
    return output_buf[0..outcome.output_size_or_failure];
}

pub const native_output_capacity: usize = OUTPUT_CAP;

pub fn nativeRender(input: []const u8, output: []u8) u32 {
    const rendered = renderForTest(input);
    if (rendered.len > output.len) @trap();
    @memcpy(output[0..rendered.len], rendered);
    return @intCast(rendered.len);
}

pub fn renderForTestWithBackground(input: []const u8, bg_rgba: u32) []const u8 {
    _ = uniform_set_background_color_rgba(bg_rgba);
    return renderForTest(input);
}

test "render rejects unsupported dimensions, resets its uniform, and recovers" {
    const invalid = "<svg/>";
    @memcpy(input_buf[0..invalid.len], invalid);
    _ = uniform_set_background_color_rgba(0xff0000ff);
    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, 0), rejected.output_size_or_failure);
    try std.testing.expectEqual(DEFAULT_BACKGROUND_COLOR_RGBA, background_color_rgba);

    const valid = "<svg width=\"1\" height=\"1\"></svg>";
    @memcpy(input_buf[0..valid.len], valid);
    _ = uniform_set_background_color_rgba(0x11223344);
    const accepted = renderOutcome(valid.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(DEFAULT_BACKGROUND_COLOR_RGBA, background_color_rgba);
}

fn pixelAt(buf: []const u8, width: u32, height: u32, x: u32, y: u32) Color {
    _ = height;
    const idx: usize = @intCast(224 + (y * width + x) * 4);
    return Color{
        .r = buf[idx],
        .g = buf[idx + 1],
        .b = buf[idx + 2],
        .a = buf[idx + 3],
    };
}

test "svg-rasterize pixel pattern" {
    const input =
        "<svg width=\"12\" height=\"8\">\n" ++
        "  <rect x=\"0\" y=\"0\" width=\"4\" height=\"8\" fill=\"#ff0000\"/>\n" ++
        "  <circle cx=\"9\" cy=\"2\" r=\"2\" fill=\"#00ff00\"/>\n" ++
        "  <g transform=\"translate(1,0)\" fill=\"#0000ff\">\n" ++
        "    <polygon points=\"6,5 11,5 11,7\"/>\n" ++
        "  </g>\n" ++
        "</svg>";

    const output = renderForTest(input);
    try std.testing.expect(output.len >= 224 + 12 * 8 * 4);

    try std.testing.expectEqual(@as(u8, 12), output[20]);
    try std.testing.expectEqual(@as(u8, 0), output[21]);
    try std.testing.expectEqual(@as(u8, 0), output[22]);
    try std.testing.expectEqual(@as(u8, 0), output[23]);
    try std.testing.expectEqual(@as(u8, 8), output[24]);
    try std.testing.expectEqual(@as(u8, 0), output[25]);
    try std.testing.expectEqual(@as(u8, 0), output[26]);
    try std.testing.expectEqual(@as(u8, 0), output[27]);

    const width: u32 = 12;
    const height: u32 = 8;

    const red = pixelAt(output, width, height, 1, 1);
    try std.testing.expectEqual(@as(u8, 0x00), red.b);
    try std.testing.expectEqual(@as(u8, 0x00), red.g);
    try std.testing.expectEqual(@as(u8, 0xFF), red.r);
    try std.testing.expectEqual(@as(u8, 0xFF), red.a);

    const green = pixelAt(output, width, height, 9, 2);
    try std.testing.expectEqual(@as(u8, 0x00), green.b);
    try std.testing.expectEqual(@as(u8, 0xFF), green.g);
    try std.testing.expectEqual(@as(u8, 0x00), green.r);
    try std.testing.expectEqual(@as(u8, 0xFF), green.a);

    const blue = pixelAt(output, width, height, 10, 5);
    try std.testing.expectEqual(@as(u8, 0xFF), blue.b);
    try std.testing.expectEqual(@as(u8, 0x00), blue.g);
    try std.testing.expectEqual(@as(u8, 0x00), blue.r);
    try std.testing.expectEqual(@as(u8, 0xFF), blue.a);

    const clear = pixelAt(output, width, height, 11, 0);
    try std.testing.expectEqual(@as(u8, 0x00), clear.b);
    try std.testing.expectEqual(@as(u8, 0x00), clear.g);
    try std.testing.expectEqual(@as(u8, 0x00), clear.r);
    try std.testing.expectEqual(@as(u8, 0x00), clear.a);
}

test "svg-rasterize stroke support" {
    const input =
        "<svg width=\"12\" height=\"12\">\n" ++
        "  <rect x=\"1\" y=\"1\" width=\"10\" height=\"10\" fill=\"none\" stroke=\"#ff00ff\" stroke-width=\"2\"/>\n" ++
        "</svg>";

    const output = renderForTest(input);
    const width: u32 = 12;
    const height: u32 = 12;

    const stroke_px = pixelAt(output, width, height, 1, 6);
    try std.testing.expectEqual(@as(u8, 0xFF), stroke_px.b);
    try std.testing.expectEqual(@as(u8, 0x00), stroke_px.g);
    try std.testing.expectEqual(@as(u8, 0xFF), stroke_px.r);
    try std.testing.expectEqual(@as(u8, 0xFF), stroke_px.a);

    const center = pixelAt(output, width, height, 6, 6);
    try std.testing.expectEqual(@as(u8, 0x00), center.b);
    try std.testing.expectEqual(@as(u8, 0x00), center.g);
    try std.testing.expectEqual(@as(u8, 0x00), center.r);
    try std.testing.expectEqual(@as(u8, 0x00), center.a);
}

test "svg-rasterize path and line stroke support" {
    const input =
        "<svg width=\"24\" height=\"24\" fill=\"none\" stroke=\"#ff7722\" stroke-width=\"2\">\n" ++
        "  <circle cx=\"12\" cy=\"12\" r=\"10\"/>\n" ++
        "  <path d=\"M8 14s1.5 2 4 2 4-2 4-2\"/>\n" ++
        "  <line x1=\"9\" y1=\"9\" x2=\"9.01\" y2=\"9\"/>\n" ++
        "  <line x1=\"15\" y1=\"9\" x2=\"15.01\" y2=\"9\"/>\n" ++
        "</svg>";

    const output = renderForTest(input);
    const width: u32 = 24;
    const height: u32 = 24;

    const ring = pixelAt(output, width, height, 12, 2);
    try std.testing.expectEqual(@as(u8, 0x22), ring.b);
    try std.testing.expectEqual(@as(u8, 0x77), ring.g);
    try std.testing.expectEqual(@as(u8, 0xFF), ring.r);
    try std.testing.expectEqual(@as(u8, 0xFF), ring.a);

    const left_eye = pixelAt(output, width, height, 9, 9);
    try std.testing.expectEqual(@as(u8, 0x22), left_eye.b);
    try std.testing.expectEqual(@as(u8, 0x77), left_eye.g);
    try std.testing.expectEqual(@as(u8, 0xFF), left_eye.r);
    try std.testing.expectEqual(@as(u8, 0xFF), left_eye.a);

    const mouth = pixelAt(output, width, height, 12, 16);
    try std.testing.expectEqual(@as(u8, 0x22), mouth.b);
    try std.testing.expectEqual(@as(u8, 0x77), mouth.g);
    try std.testing.expectEqual(@as(u8, 0xFF), mouth.r);
    try std.testing.expectEqual(@as(u8, 0xFF), mouth.a);
}

test "svg-rasterize path fill support" {
    const input =
        "<svg width=\"10\" height=\"10\">\n" ++
        "  <path d=\"M 1 1 L 8 1 L 8 8 L 1 8 Z\" fill=\"#00ff00\" stroke=\"none\"/>\n" ++
        "</svg>";

    const output = renderForTestWithBackground(input, 0xffffffff);
    const width: u32 = 10;
    const height: u32 = 10;

    const inside = pixelAt(output, width, height, 4, 4);
    try std.testing.expectEqual(@as(u8, 0x00), inside.r);
    try std.testing.expectEqual(@as(u8, 0xFF), inside.g);
    try std.testing.expectEqual(@as(u8, 0x00), inside.b);
    try std.testing.expectEqual(@as(u8, 0xFF), inside.a);

    const outside = pixelAt(output, width, height, 0, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), outside.r);
    try std.testing.expectEqual(@as(u8, 0xFF), outside.g);
    try std.testing.expectEqual(@as(u8, 0xFF), outside.b);
    try std.testing.expectEqual(@as(u8, 0xFF), outside.a);
}

test "svg-rasterize background color uniform" {
    const input =
        "<svg width=\"4\" height=\"4\">\n" ++
        "  <rect x=\"1\" y=\"1\" width=\"2\" height=\"2\" fill=\"#ff0000\"/>\n" ++
        "</svg>";

    const output = renderForTestWithBackground(input, 0x11223344);
    const width: u32 = 4;
    const height: u32 = 4;

    const bg = pixelAt(output, width, height, 0, 0);
    try std.testing.expectEqual(@as(u8, 0x11), bg.r);
    try std.testing.expectEqual(@as(u8, 0x22), bg.g);
    try std.testing.expectEqual(@as(u8, 0x33), bg.b);
    try std.testing.expectEqual(@as(u8, 0x44), bg.a);

    const red = pixelAt(output, width, height, 2, 2);
    try std.testing.expectEqual(@as(u8, 0xFF), red.r);
    try std.testing.expectEqual(@as(u8, 0x00), red.g);
    try std.testing.expectEqual(@as(u8, 0x00), red.b);
    try std.testing.expectEqual(@as(u8, 0xFF), red.a);
}

test "svg-rasterize named stroke color support" {
    const input =
        "<svg width=\"10\" height=\"10\">\n" ++
        "  <path d=\"M 1 5 L 8 5\" stroke=\"black\" stroke-width=\"2\"/>\n" ++
        "</svg>";

    const output = renderForTestWithBackground(input, 0xffffffff);
    const width: u32 = 10;
    const height: u32 = 10;
    const px = pixelAt(output, width, height, 4, 5);
    try std.testing.expectEqual(@as(u8, 0x00), px.r);
    try std.testing.expectEqual(@as(u8, 0x00), px.g);
    try std.testing.expectEqual(@as(u8, 0x00), px.b);
    try std.testing.expectEqual(@as(u8, 0xFF), px.a);
}

test "declares the standard 25 MP image output capacity" {
    try std.testing.expectEqual(@as(u32, MAX_PIXELS * 4 + OUTPUT_HEADER_SIZE), output_bytes_cap());
}
