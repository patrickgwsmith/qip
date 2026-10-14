const std = @import("std");
const root = @import("root");

const OUTPUT_KTX2 = !(@hasDecl(root, "SVG_RASTERIZE_BMP") and root.SVG_RASTERIZE_BMP);
const ktx2 = @import("ktx2_rgba8_srgb");
const OUTPUT_FLOAT = @hasDecl(root, "SVG_RASTERIZE_RGBA32FLOAT") and root.SVG_RASTERIZE_RGBA32FLOAT;
const ANTIALIAS = OUTPUT_FLOAT or (@hasDecl(root, "SVG_RASTERIZE_ANTIALIAS") and root.SVG_RASTERIZE_ANTIALIAS);
const ktx2_float = if (ANTIALIAS) @import("ktx2_rgba32float") else struct {};
// <text> is drawn with Inter Display outlines, whatever font-family says.
const font_regular = @import("inter_regular");
const font_bold = @import("inter_bold");

// TODO(svg): Required paint parsing to be practical for SVG icons/text:
// - Add css color functions: rgb(), rgba(), hsl(), hsla()
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
const DEFAULT_CURRENT_COLOR_RGBA: u32 = 0x000000FF;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [WORK_CAP]u8 = undefined;
var background_color_rgba: u32 = DEFAULT_BACKGROUND_COLOR_RGBA;
var current_color_rgba: u32 = DEFAULT_CURRENT_COLOR_RGBA;
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

export fn uniform_set_current_color_rgba(value: u32) u32 {
    current_color_rgba = value;
    return current_color_rgba;
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

fn resetUniforms() void {
    background_color_rgba = DEFAULT_BACKGROUND_COLOR_RGBA;
    current_color_rgba = DEFAULT_CURRENT_COLOR_RGBA;
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
    rx: f32 = 0,
    ry: f32 = 0,
    set_x: bool = false,
    set_y: bool = false,
    set_w: bool = false,
    set_h: bool = false,
    set_rx: bool = false,
    set_ry: bool = false,
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

// Rendering is single-threaded and non-reentrant, so path and scanline scratch
// live outside the Wasm stack.
var path_segments: [MAX_PATH_SEGMENTS]PathSegment = undefined;
var path_intersections: [MAX_PATH_SEGMENTS]PathIntersection = undefined;
var path_scanline_coverage: [MAX_DIMENSION]u8 = undefined;

// Gradients are collected in a pre-pass so paint can reference them before
// or after their definition. Each one is baked into a 256-entry sRGB ramp.
const MAX_GRADIENTS: usize = 64;
const MAX_GRADIENT_STOPS: usize = 32;
const GRADIENT_RAMP_SIZE: usize = 256;

const GradientKind = enum { linear, radial };
const GradientSpread = enum { pad, reflect, repeat };

const GradientStop = struct {
    offset: f32,
    color: Color,
};

const Gradient = struct {
    id: []const u8,
    href: []const u8 = "",
    kind: GradientKind,
    user_space: bool = false,
    spread: GradientSpread = .pad,
    transform: Mat,
    // Linear: x1 y1 x2 y2. Radial: cx cy r (fx/fy are not supported).
    coords: [4]f32,
    set_coords: [4]bool = .{ false, false, false, false },
    set_units: bool = false,
    set_spread: bool = false,
    set_transform: bool = false,
    stops: [MAX_GRADIENT_STOPS]GradientStop = undefined,
    stop_count: usize = 0,
};

var gradients: [MAX_GRADIENTS]Gradient = undefined;
var gradient_count: usize = 0;
var gradient_ramps: [MAX_GRADIENTS][GRADIENT_RAMP_SIZE]Color = undefined;

// Paint as written and inherited: a solid color or a gradient reference.
const PaintSpec = struct {
    color: Color,
    gradient: ?u8 = null,
};

// Paint resolved for one element. It stays small because strokes pass it
// through every flattened segment; a gradient's device-to-gradient matrix
// lives in `paint_slots` (fill and stroke) instead.
const PaintSlot = enum(u1) { fill, stroke };

const Paint = struct {
    color: Color,
    gradient: ?u8 = null,
    slot: PaintSlot = .fill,
    opacity: f32 = 1,
};

var paint_slots: [2]Mat = undefined;

const Bounds = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

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
    if (strEq(value, "currentColor")) return colorFromRgba(current_color_rgba);
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

fn paintVisible(paint: Paint) bool {
    return paint.opacity > 0 and (paint.gradient != null or paint.color.a != 0);
}

fn gradientRampIndex(spread: GradientSpread, t: f32) usize {
    var u = t;
    switch (spread) {
        .pad => {},
        .repeat => u = u - @floor(u),
        .reflect => {
            const period = u - 2.0 * @floor(u * 0.5);
            u = if (period > 1.0) 2.0 - period else period;
        },
    }
    if (!(u > 0)) return 0;
    if (u >= 1) return GRADIENT_RAMP_SIZE - 1;
    return @intFromFloat(u * @as(f32, @floatFromInt(GRADIENT_RAMP_SIZE - 1)) + 0.5);
}

// Paint color at a device pixel center, before the paint's opacity.
fn paintColorAt(paint: Paint, x: i32, y: i32) Color {
    const index = paint.gradient orelse return paint.color;
    return gradientColorAt(index, paint.slot, x, y);
}

// Kept out of line so the solid-color path stays small enough to inline into
// the per-pixel coverage loops.
noinline fn gradientColorAt(index: u8, slot: PaintSlot, x: i32, y: i32) Color {
    const gradient = &gradients[index];
    const p = matApply(paint_slots[@intFromEnum(slot)], @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
    const c = gradient.coords;
    var t: f32 = 0;
    switch (gradient.kind) {
        .linear => {
            const dx = c[2] - c[0];
            const dy = c[3] - c[1];
            const length2 = dx * dx + dy * dy;
            if (length2 > 0) t = ((p[0] - c[0]) * dx + (p[1] - c[1]) * dy) / length2;
        },
        .radial => {
            const dx = p[0] - c[0];
            const dy = p[1] - c[1];
            t = if (c[2] > 0) std.math.sqrt(dx * dx + dy * dy) / c[2] else 1;
        },
    }
    return gradient_ramps[index][gradientRampIndex(gradient.spread, t)];
}

fn blendPixelCoverage(ctx: *ParserCtx, x: i32, y: i32, paint: Paint, coverage: f32) void {
    if (!ANTIALIAS) @compileError("float coverage is only available in an antialiased renderer");
    if (coverage <= 0) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= ctx.width or uy >= ctx.height) return;

    const color = paintColorAt(paint, x, y);
    if (color.a == 0) return;
    const paint_alpha = @as(f32, @floatFromInt(color.a)) / 255.0 * paint.opacity;
    const source_alpha = @min(@as(f32, 1.0), coverage) * paint_alpha;
    const inverse_alpha: Vec4f = @splat(1.0 - source_alpha);
    // Working pixels hold premultiplied sRGB-encoded values: SVG composites
    // in sRGB (color-interpolation defaults to sRGB), as browsers and Skia do.
    const channel_scale = source_alpha / 255.0;
    const source: Vec4f = .{
        @as(f32, @floatFromInt(color.r)) * channel_scale,
        @as(f32, @floatFromInt(color.g)) * channel_scale,
        @as(f32, @floatFromInt(color.b)) * channel_scale,
        source_alpha,
    };
    const pixel = floatPixelPtr(ctx, ux, uy);
    pixel.* = source + pixel.* * inverse_alpha;
}

fn setPixel(ctx: *ParserCtx, x: i32, y: i32, paint: Paint) void {
    if (ANTIALIAS) {
        blendPixelCoverage(ctx, x, y, paint, 1.0);
        return;
    }
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= ctx.width or uy >= ctx.height) return;
    const color = paintColorAt(paint, x, y);
    const source_alpha = @as(f32, @floatFromInt(color.a)) / 255.0 * paint.opacity;
    if (source_alpha <= 0) return;
    const row = if (OUTPUT_KTX2) uy else ctx.height - 1 - uy;
    const idx: u32 = ctx.pixel_base + (row * ctx.width + ux) * 4;
    const ri = if (OUTPUT_KTX2) idx else idx + 2;
    const bi = if (OUTPUT_KTX2) idx + 2 else idx;
    if (source_alpha >= 1) {
        output_buf[ri] = color.r;
        output_buf[idx + 1] = color.g;
        output_buf[bi] = color.b;
        output_buf[idx + 3] = 255;
        return;
    }
    // Straight-alpha source-over in sRGB, matching this renderer's 8-bit output.
    const dest_alpha = @as(f32, @floatFromInt(output_buf[idx + 3])) / 255.0;
    const dest_weight = dest_alpha * (1 - source_alpha);
    const out_alpha = source_alpha + dest_weight;
    const channels = [3]usize{ ri, idx + 1, bi };
    const sources = [3]u8{ color.r, color.g, color.b };
    for (channels, sources) |channel, source| {
        const blended = (@as(f32, @floatFromInt(source)) * source_alpha + @as(f32, @floatFromInt(output_buf[channel])) * dest_weight) / out_alpha;
        output_buf[channel] = @intFromFloat(@min(@as(f32, 255), blended + 0.5));
    }
    output_buf[idx + 3] = @intFromFloat(@min(@as(f32, 255), out_alpha * 255 + 0.5));
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
            pixel.* = .{
                ktx2_float.srgbToLinear(@min(@as(f32, 1.0), straight[0])),
                ktx2_float.srgbToLinear(@min(@as(f32, 1.0), straight[1])),
                ktx2_float.srgbToLinear(@min(@as(f32, 1.0), straight[2])),
                alpha,
            };
        } else if (OUTPUT_FLOAT) {
            pixel.* = @splat(0.0);
        } else {
            const destination = ctx.pixel_base + pixel_index * 4;
            if (alpha > 0.0) {
                const inverse_alpha = 1.0 / alpha;
                output_buf[destination] = ktx2_float.linearToUnorm8(pixel.*[0] * inverse_alpha);
                output_buf[destination + 1] = ktx2_float.linearToUnorm8(pixel.*[1] * inverse_alpha);
                output_buf[destination + 2] = ktx2_float.linearToUnorm8(pixel.*[2] * inverse_alpha);
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

// A box with elliptical corners. Zero radii give a plain box.
const RoundedBox = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    rx: f32 = 0,
    ry: f32 = 0,
};

fn roundedBoxMask(box: RoundedBox, lx: Vec4f, ly: Vec4f) @Vector(4, bool) {
    const inside = (lx >= @as(Vec4f, @splat(box.x0))) & (lx <= @as(Vec4f, @splat(box.x1))) &
        (ly >= @as(Vec4f, @splat(box.y0))) & (ly <= @as(Vec4f, @splat(box.y1)));
    if (box.rx <= 0 or box.ry <= 0) return inside;
    const zero: Vec4f = @splat(0.0);
    const ex = @max(zero, @abs(lx - @as(Vec4f, @splat((box.x0 + box.x1) * 0.5))) - @as(Vec4f, @splat((box.x1 - box.x0) * 0.5 - box.rx))) / @as(Vec4f, @splat(box.rx));
    const ey = @max(zero, @abs(ly - @as(Vec4f, @splat((box.y0 + box.y1) * 0.5))) - @as(Vec4f, @splat((box.y1 - box.y0) * 0.5 - box.ry))) / @as(Vec4f, @splat(box.ry));
    return inside & (ex * ex + ey * ey <= @as(Vec4f, @splat(1.0)));
}

fn roundedBoxContains(box: RoundedBox, lx: f32, ly: f32) bool {
    if (lx < box.x0 or lx > box.x1 or ly < box.y0 or ly > box.y1) return false;
    if (box.rx <= 0 or box.ry <= 0) return true;
    const ex = @max(0, @abs(lx - (box.x0 + box.x1) * 0.5) - ((box.x1 - box.x0) * 0.5 - box.rx)) / box.rx;
    const ey = @max(0, @abs(ly - (box.y0 + box.y1) * 0.5) - ((box.y1 - box.y0) * 0.5 - box.ry)) / box.ry;
    return ex * ex + ey * ey <= 1;
}

fn rectCoverage(inv: Mat, x: i32, y: i32, box: RoundedBox) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / @as(f32, @floatFromInt(AA_GRID));
        covered += maskCount(roundedBoxMask(box, sampleLocalX(inv, x, sy), sampleLocalY(inv, x, sy)));
    }
    return @as(f32, @floatFromInt(covered)) / 16.0;
}

fn rectStrokeCoverage(inv: Mat, x: i32, y: i32, outer: RoundedBox, inner: RoundedBox, has_inner: bool) f32 {
    var covered: i32 = 0;
    var sample_row: i32 = 0;
    while (sample_row < AA_GRID) : (sample_row += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_row)) + 0.5) / 4.0;
        const lx = sampleLocalX(inv, x, sy);
        const ly = sampleLocalY(inv, x, sy);
        const inner_mask = if (has_inner) roundedBoxMask(inner, lx, ly) else @as(@Vector(4, bool), @splat(false));
        covered += maskCount(roundedBoxMask(outer, lx, ly) & !inner_mask);
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

fn drawPathScanlines(ctx: *ParserCtx, color: Paint, segments: *const [MAX_PATH_SEGMENTS]PathSegment, seg_count: usize, x0: i32, y0: i32, x1: i32, y1: i32) void {
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

// SVG corner radii: a missing radius copies the other, and both are clamped
// to half the side.
fn rectRadii(rect: Rect) [2]f32 {
    var rx = if (rect.set_rx) rect.rx else if (rect.set_ry) rect.ry else 0;
    var ry = if (rect.set_ry) rect.ry else rx;
    rx = @max(0, @min(rx, rect.w * 0.5));
    ry = @max(0, @min(ry, rect.h * 0.5));
    return .{ rx, ry };
}

fn drawRect(ctx: *ParserCtx, transform: Mat, color: Paint, rect: Rect) void {
    if (!(rect.set_w and rect.set_h)) return;
    if (!paintVisible(color)) return;
    const inv = matInverse(transform) orelse return;
    const radii = rectRadii(rect);
    const box = RoundedBox{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.w, .y1 = rect.y + rect.h, .rx = radii[0], .ry = radii[1] };
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
                blendPixelCoverage(ctx, x, y, color, rectCoverage(inv, x, y, box));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            if (roundedBoxContains(box, local[0], local[1])) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawRectStroke(ctx: *ParserCtx, transform: Mat, color: Paint, rect: Rect, stroke_width: f32) void {
    if (!(rect.set_w and rect.set_h)) return;
    if (stroke_width <= 0) return;
    if (!paintVisible(color)) return;
    const inv = matInverse(transform) orelse return;
    const half_w = stroke_width * 0.5;
    const radii = rectRadii(rect);
    const rounded = radii[0] > 0 and radii[1] > 0;
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
    // Offsetting an elliptical corner is approximated by growing or shrinking
    // its radii; this is exact for circular corners.
    const outer = RoundedBox{
        .x0 = ox0_local,
        .y0 = oy0_local,
        .x1 = ox1_local,
        .y1 = oy1_local,
        .rx = if (rounded) radii[0] + half_w else 0,
        .ry = if (rounded) radii[1] + half_w else 0,
    };
    const inner = RoundedBox{
        .x0 = ix0,
        .y0 = iy0,
        .x1 = ix1,
        .y1 = iy1,
        .rx = if (rounded) @max(0, radii[0] - half_w) else 0,
        .ry = if (rounded) @max(0, radii[1] - half_w) else 0,
    };

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            if (ANTIALIAS) {
                blendPixelCoverage(ctx, x, y, color, rectStrokeCoverage(inv, x, y, outer, inner, has_inner));
                continue;
            }
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);

            if (!roundedBoxContains(outer, local[0], local[1])) continue;

            var in_inner = false;
            if (has_inner) {
                in_inner = roundedBoxContains(inner, local[0], local[1]);
            }
            if (!in_inner) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawCircle(ctx: *ParserCtx, transform: Mat, color: Paint, circle: Circle) void {
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

fn drawCircleStroke(ctx: *ParserCtx, transform: Mat, color: Paint, circle: Circle, stroke_width: f32) void {
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

fn drawPolygon(ctx: *ParserCtx, transform: Mat, color: Paint, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) void {
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

fn drawPolygonStroke(ctx: *ParserCtx, transform: Mat, color: Paint, stroke_width: f32, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) void {
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

fn drawSegmentStroke(ctx: *ParserCtx, transform: Mat, color: Paint, stroke_width: f32, ax: f32, ay: f32, bx: f32, by: f32) void {
    if (!paintVisible(color)) return;
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

fn drawPolylineStroke(ctx: *ParserCtx, transform: Mat, color: Paint, stroke_width: f32, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize, closed: bool) void {
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

fn drawCubicStroke(ctx: *ParserCtx, transform: Mat, color: Paint, stroke_width: f32, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32) void {
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

fn drawQuadStroke(ctx: *ParserCtx, transform: Mat, color: Paint, stroke_width: f32, p0: [2]f32, p1: [2]f32, p2: [2]f32) void {
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

// Flattens path data into `path_segments` in local coordinates, closing
// every subpath, and returns the segment count.
fn flattenPath(d: []const u8) usize {
    const segments = &path_segments;
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
                    addPathSegment(segments, &seg_count, cur[0], cur[1], sub_start[0], sub_start[1]);
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
                    addPathSegment(segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                }
            },
            'L' => {
                while (true) {
                    const x = parsePathNumber(d, &idx) orelse break;
                    const y = parsePathNumber(d, &idx) orelse break;
                    const next = if (rel) .{ cur[0] + x, cur[1] + y } else .{ x, y };
                    addPathSegment(segments, &seg_count, cur[0], cur[1], next[0], next[1]);
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
                    addPathSegment(segments, &seg_count, cur[0], cur[1], next[0], next[1]);
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
                    addPathSegment(segments, &seg_count, cur[0], cur[1], next[0], next[1]);
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
                    drawCubicFillSegments(segments, &seg_count, cur, c1, c2, next);
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
                    drawCubicFillSegments(segments, &seg_count, cur, c1, c2, next);
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
                    drawQuadFillSegments(segments, &seg_count, cur, c, next);
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
                    drawQuadFillSegments(segments, &seg_count, cur, c, next);
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
                    addPathSegment(segments, &seg_count, cur[0], cur[1], next[0], next[1]);
                    cur = next;
                    sub_has_edges = true;
                    has_prev_cubic = false;
                    has_prev_quad = false;
                }
            },
            'Z' => {
                if (sub_active and sub_has_edges and !pathPointsEqual(cur, sub_start)) {
                    addPathSegment(segments, &seg_count, cur[0], cur[1], sub_start[0], sub_start[1]);
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
        addPathSegment(segments, &seg_count, cur[0], cur[1], sub_start[0], sub_start[1]);
    }
    return seg_count;
}

fn segmentBounds(seg_count: usize) ?Bounds {
    if (seg_count == 0) return null;
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    for (path_segments[0..seg_count]) |segment| {
        min_x = @min(min_x, @min(segment.ax, segment.bx));
        max_x = @max(max_x, @max(segment.ax, segment.bx));
        min_y = @min(min_y, @min(segment.ay, segment.by));
        max_y = @max(max_y, @max(segment.ay, segment.by));
    }
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

// Fills the first `seg_count` entries of `path_segments` with the nonzero rule.
fn fillPath(ctx: *ParserCtx, transform: Mat, color: Paint, seg_count: usize) void {
    if (!paintVisible(color)) return;
    if (seg_count == 0) return;
    const segments = &path_segments;

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
        drawPathScanlines(ctx, color, segments, seg_count, x0, y0, x1, y1);
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

fn drawPathStroke(ctx: *ParserCtx, transform: Mat, color: Paint, stroke_width: f32, d: []const u8) void {
    if (!paintVisible(color)) return;
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

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

// Returns the next attribute of the open tag at `idx`, or null once its `>`
// or `/>` has been consumed.
fn nextAttribute(input: []const u8, idx: *usize, self_closing: *bool) ?Attr {
    while (idx.* < input.len) {
        skipWs(input, idx);
        if (idx.* >= input.len) return null;
        if (input[idx.*] == '/' and idx.* + 1 < input.len and input[idx.* + 1] == '>') {
            idx.* += 2;
            self_closing.* = true;
            return null;
        }
        if (input[idx.*] == '>') {
            idx.* += 1;
            return null;
        }
        const name = readName(input, idx);
        skipWs(input, idx);
        if (idx.* >= input.len or input[idx.*] != '=') {
            if (name.len == 0) idx.* += 1;
            continue;
        }
        idx.* += 1;
        skipWs(input, idx);
        return .{ .name = name, .value = readQuoted(input, idx) };
    }
    return null;
}

fn trimWs(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t' or value[start] == '\n' or value[start] == '\r')) start += 1;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t' or value[end - 1] == '\n' or value[end - 1] == '\r')) end -= 1;
    return value[start..end];
}

// A number, or a percentage as a fraction.
fn parseNumberOrPercent(value: []const u8) ?f32 {
    var idx: usize = 0;
    const number = parseFloat(value, &idx) orelse return null;
    if (idx < value.len and value[idx] == '%') return number / 100.0;
    return number;
}

fn parseUnitInterval(value: []const u8) ?f32 {
    const number = parseNumberOrPercent(value) orelse return null;
    return @max(0, @min(1, number));
}

fn findGradient(id: []const u8) ?u8 {
    var index: usize = 0;
    while (index < gradient_count) : (index += 1) {
        if (strEq(gradients[index].id, id)) return @intCast(index);
    }
    return null;
}

// Strips the leading `#` of an href value.
fn hrefFragment(value: []const u8) []const u8 {
    const trimmed = trimWs(value);
    if (trimmed.len > 1 and trimmed[0] == '#') return trimmed[1..];
    return "";
}

fn parsePaint(value: []const u8) ?PaintSpec {
    const none = PaintSpec{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
    const trimmed = trimWs(value);
    if (trimmed.len > 4 and strEq(trimmed[0..4], "url(")) {
        var close: usize = 4;
        while (close < trimmed.len and trimmed[close] != ')') close += 1;
        var reference = trimWs(trimmed[4..close]);
        if (reference.len >= 2 and (reference[0] == '\'' or reference[0] == '"') and reference[reference.len - 1] == reference[0]) {
            reference = reference[1 .. reference.len - 1];
        }
        if (findGradient(hrefFragment(reference))) |index| {
            return .{ .color = none.color, .gradient = index };
        }
        // An unresolved reference uses its fallback color, or paints nothing.
        if (close + 1 < trimmed.len) {
            if (parseColor(trimWs(trimmed[close + 1 ..]))) |fallback| return .{ .color = fallback };
        }
        return none;
    }
    const color = parseColor(trimmed) orelse return null;
    return .{ .color = color };
}

const TextAnchor = enum { start, middle, end };

// Inherited presentation state.
const Style = struct {
    fill: PaintSpec,
    stroke: PaintSpec,
    stroke_width: f32,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    // Group opacity is approximated by multiplying it into each descendant's
    // paint rather than compositing the group as one layer.
    opacity: f32 = 1,
    font_size: f32 = 16,
    font_bold: bool = false,
    text_anchor: TextAnchor = .start,
};

const ElementAttrs = struct {
    rect: Rect = .{},
    circle: Circle = .{},
    line: Line = .{},
    poly_count: usize = 0,
    path_d: ?[]const u8 = null,
    transform: ?Mat = null,
    fill: ?PaintSpec = null,
    stroke: ?PaintSpec = null,
    stroke_width: ?f32 = null,
    fill_opacity: ?f32 = null,
    stroke_opacity: ?f32 = null,
    opacity: ?f32 = null,
    font_size: ?f32 = null,
    font_bold: ?bool = null,
    text_anchor: ?TextAnchor = null,
    self_closing: bool = false,
};

fn parseAttributes(input: []const u8, idx: *usize, attrs: *ElementAttrs, xs: *[MAX_POINTS]f32, ys: *[MAX_POINTS]f32) void {
    const rect = &attrs.rect;
    const circle = &attrs.circle;
    const line = &attrs.line;
    while (nextAttribute(input, idx, &attrs.self_closing)) |attr| {
        const name = attr.name;
        const value = attr.value;
        if (value.len == 0) continue;

        if (strEq(name, "fill")) {
            if (parsePaint(value)) |paint| attrs.fill = paint;
        } else if (strEq(name, "stroke")) {
            if (parsePaint(value)) |paint| attrs.stroke = paint;
        } else if (strEq(name, "stroke-width")) {
            if (parseNumber(value)) |v| attrs.stroke_width = if (v > 0) v else 0;
        } else if (strEq(name, "fill-opacity")) {
            if (parseUnitInterval(value)) |v| attrs.fill_opacity = v;
        } else if (strEq(name, "stroke-opacity")) {
            if (parseUnitInterval(value)) |v| attrs.stroke_opacity = v;
        } else if (strEq(name, "opacity")) {
            if (parseUnitInterval(value)) |v| attrs.opacity = v;
        } else if (strEq(name, "transform")) {
            attrs.transform = parseTransform(value);
        } else if (strEq(name, "font-size")) {
            if (parseNumber(value)) |v| {
                if (v > 0) attrs.font_size = v;
            }
        } else if (strEq(name, "font-weight")) {
            if (strEq(value, "bold") or strEq(value, "bolder")) {
                attrs.font_bold = true;
            } else if (strEq(value, "normal") or strEq(value, "lighter")) {
                attrs.font_bold = false;
            } else if (parseNumber(value)) |v| {
                attrs.font_bold = v >= 600;
            }
        } else if (strEq(name, "text-anchor")) {
            if (strEq(value, "start")) {
                attrs.text_anchor = .start;
            } else if (strEq(value, "middle")) {
                attrs.text_anchor = .middle;
            } else if (strEq(value, "end")) {
                attrs.text_anchor = .end;
            }
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
        } else if (strEq(name, "rx")) {
            if (parseNumber(value)) |v| {
                rect.rx = v;
                rect.set_rx = true;
            }
        } else if (strEq(name, "ry")) {
            if (parseNumber(value)) |v| {
                rect.ry = v;
                rect.set_ry = true;
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
            parsePoints(value, xs, ys, &attrs.poly_count);
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
            attrs.path_d = value;
        }
    }
}

fn applyAttrs(style: Style, attrs: ElementAttrs) Style {
    var result = style;
    if (attrs.fill) |v| result.fill = v;
    if (attrs.stroke) |v| result.stroke = v;
    if (attrs.stroke_width) |v| result.stroke_width = v;
    if (attrs.fill_opacity) |v| result.fill_opacity = v;
    if (attrs.stroke_opacity) |v| result.stroke_opacity = v;
    if (attrs.opacity) |v| result.opacity *= v;
    if (attrs.font_size) |v| result.font_size = v;
    if (attrs.font_bold) |v| result.font_bold = v;
    if (attrs.text_anchor) |v| result.text_anchor = v;
    return result;
}

fn resolvePaint(spec: PaintSpec, opacity: f32, transform: Mat, bounds: ?Bounds, slot: PaintSlot) Paint {
    const none = Paint{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
    const index = spec.gradient orelse return .{ .color = spec.color, .opacity = opacity };
    const gradient = &gradients[index];
    if (gradient.stop_count == 0) return none;
    var to_user = gradient.transform;
    if (!gradient.user_space) {
        // objectBoundingBox gradients are not drawn on a zero-area box.
        const box = bounds orelse return none;
        if (!(box.w > 0 and box.h > 0)) return none;
        to_user = matMul(.{ .a = box.w, .b = 0, .c = 0, .d = box.h, .tx = box.x, .ty = box.y }, gradient.transform);
    }
    paint_slots[@intFromEnum(slot)] = matInverse(matMul(transform, to_user)) orelse return none;
    return .{ .color = spec.color, .gradient = index, .slot = slot, .opacity = opacity };
}

fn pointBounds(xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) ?Bounds {
    if (count == 0) return null;
    var min_x = xs[0];
    var max_x = xs[0];
    var min_y = ys[0];
    var max_y = ys[0];
    for (xs[1..count], ys[1..count]) |x, y| {
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
        min_y = @min(min_y, y);
        max_y = @max(max_y, y);
    }
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

fn stopColorAt(stops: []const GradientStop, t: f32) [4]f32 {
    var upper: usize = 0;
    while (upper < stops.len and stops[upper].offset < t) upper += 1;
    const lower = if (upper == 0) 0 else upper - 1;
    if (upper >= stops.len) upper = stops.len - 1;
    const a = stops[lower];
    const b = stops[upper];
    const span = b.offset - a.offset;
    const weight: f32 = if (span > 0) @max(0, @min(1, (t - a.offset) / span)) else if (t >= b.offset) 1 else 0;
    var result: [4]f32 = undefined;
    const a_alpha = @as(f32, @floatFromInt(a.color.a)) / 255.0;
    const b_alpha = @as(f32, @floatFromInt(b.color.a)) / 255.0;
    result[3] = a_alpha + (b_alpha - a_alpha) * weight;
    const a_rgb = [3]u8{ a.color.r, a.color.g, a.color.b };
    const b_rgb = [3]u8{ b.color.r, b.color.g, b.color.b };
    // Interpolate premultiplied so a transparent stop does not tint its neighbour.
    for (0..3) |channel| {
        const from = @as(f32, @floatFromInt(a_rgb[channel])) * a_alpha;
        const to = @as(f32, @floatFromInt(b_rgb[channel])) * b_alpha;
        result[channel] = from + (to - from) * weight;
    }
    return result;
}

fn bakeGradientRamp(index: usize) void {
    const gradient = &gradients[index];
    if (gradient.stop_count == 0) return;
    const stops = gradient.stops[0..gradient.stop_count];
    for (&gradient_ramps[index], 0..) |*entry, step| {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(GRADIENT_RAMP_SIZE - 1));
        const rgba = stopColorAt(stops, t);
        if (rgba[3] <= 0) {
            entry.* = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            continue;
        }
        entry.* = .{
            .r = @intFromFloat(@min(@as(f32, 255), rgba[0] / rgba[3] + 0.5)),
            .g = @intFromFloat(@min(@as(f32, 255), rgba[1] / rgba[3] + 0.5)),
            .b = @intFromFloat(@min(@as(f32, 255), rgba[2] / rgba[3] + 0.5)),
            .a = @intFromFloat(@min(@as(f32, 255), rgba[3] * 255 + 0.5)),
        };
    }
}

fn parseGradientAttributes(input: []const u8, idx: *usize, gradient: *Gradient, self_closing: *bool) void {
    const coord_names = if (gradient.kind == .linear)
        [4][]const u8{ "x1", "y1", "x2", "y2" }
    else
        [4][]const u8{ "cx", "cy", "r", "" };
    while (nextAttribute(input, idx, self_closing)) |attr| {
        if (strEq(attr.name, "id")) {
            gradient.id = attr.value;
        } else if (strEq(attr.name, "href") or strEq(attr.name, "xlink:href")) {
            gradient.href = hrefFragment(attr.value);
        } else if (strEq(attr.name, "gradientUnits")) {
            gradient.user_space = strEq(attr.value, "userSpaceOnUse");
            gradient.set_units = true;
        } else if (strEq(attr.name, "spreadMethod")) {
            gradient.spread = if (strEq(attr.value, "reflect")) .reflect else if (strEq(attr.value, "repeat")) .repeat else .pad;
            gradient.set_spread = true;
        } else if (strEq(attr.name, "gradientTransform")) {
            gradient.transform = parseTransform(attr.value);
            gradient.set_transform = true;
        } else {
            for (coord_names, 0..) |coord_name, coord| {
                if (coord_name.len == 0 or !strEq(attr.name, coord_name)) continue;
                if (parseNumberOrPercent(attr.value)) |v| {
                    gradient.coords[coord] = v;
                    gradient.set_coords[coord] = true;
                }
            }
        }
    }
}

fn parseStop(input: []const u8, idx: *usize, self_closing: *bool) GradientStop {
    var stop = GradientStop{ .offset = 0, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } };
    var stop_opacity: f32 = 1;
    while (nextAttribute(input, idx, self_closing)) |attr| {
        if (strEq(attr.name, "offset")) {
            if (parseUnitInterval(attr.value)) |v| stop.offset = v;
        } else if (strEq(attr.name, "stop-color")) {
            if (parseColor(trimWs(attr.value))) |c| stop.color = c;
        } else if (strEq(attr.name, "stop-opacity")) {
            if (parseUnitInterval(attr.value)) |v| stop_opacity = v;
        }
    }
    stop.color.a = @intFromFloat(@as(f32, @floatFromInt(stop.color.a)) * stop_opacity + 0.5);
    return stop;
}

// Inherits stops and unset attributes along each gradient's href chain.
fn resolveGradientReferences() void {
    const MAX_HREF_HOPS: usize = 8;
    var index: usize = 0;
    while (index < gradient_count) : (index += 1) {
        const gradient = &gradients[index];
        var href = gradient.href;
        var hops: usize = 0;
        while (href.len > 0 and hops < MAX_HREF_HOPS) : (hops += 1) {
            const parent_index = findGradient(href) orelse break;
            if (parent_index == index) break;
            const parent = &gradients[parent_index];
            if (gradient.stop_count == 0 and parent.stop_count > 0) {
                gradient.stops = parent.stops;
                gradient.stop_count = parent.stop_count;
            }
            if (!gradient.set_units and parent.set_units) {
                gradient.user_space = parent.user_space;
                gradient.set_units = true;
            }
            if (!gradient.set_spread and parent.set_spread) {
                gradient.spread = parent.spread;
                gradient.set_spread = true;
            }
            if (!gradient.set_transform and parent.set_transform) {
                gradient.transform = parent.transform;
                gradient.set_transform = true;
            }
            if (parent.kind == gradient.kind) {
                for (0..4) |coord| {
                    if (!gradient.set_coords[coord] and parent.set_coords[coord]) {
                        gradient.coords[coord] = parent.coords[coord];
                        gradient.set_coords[coord] = true;
                    }
                }
            }
            href = parent.href;
        }
    }
}

fn collectGradients(input: []const u8) void {
    gradient_count = 0;
    var idx: usize = 0;
    var current: ?usize = null;
    while (idx < input.len) {
        while (idx < input.len and input[idx] != '<') idx += 1;
        if (idx >= input.len) break;
        idx += 1;
        if (idx >= input.len) break;
        if (input[idx] == '/') {
            idx += 1;
            const name = readName(input, &idx);
            if (strEq(name, "linearGradient") or strEq(name, "radialGradient")) current = null;
            continue;
        }
        if (input[idx] == '?' or input[idx] == '!') {
            skipSpecial(input, &idx);
            continue;
        }
        const name = readName(input, &idx);
        var self_closing = false;
        const linear = strEq(name, "linearGradient");
        if (linear or strEq(name, "radialGradient")) {
            current = null;
            var gradient = Gradient{
                .id = "",
                .kind = if (linear) .linear else .radial,
                .transform = matIdentity(),
                .coords = if (linear) .{ 0, 0, 1, 0 } else .{ 0.5, 0.5, 0.5, 0 },
            };
            parseGradientAttributes(input, &idx, &gradient, &self_closing);
            if (gradient.id.len == 0 or gradient_count >= MAX_GRADIENTS) continue;
            gradients[gradient_count] = gradient;
            if (!self_closing) current = gradient_count;
            gradient_count += 1;
        } else if (strEq(name, "stop")) {
            const stop = parseStop(input, &idx, &self_closing);
            const gradient = &gradients[current orelse continue];
            if (gradient.stop_count >= MAX_GRADIENT_STOPS) continue;
            var placed = stop;
            // Offsets never decrease along the ramp.
            if (gradient.stop_count > 0) placed.offset = @max(placed.offset, gradient.stops[gradient.stop_count - 1].offset);
            gradient.stops[gradient.stop_count] = placed;
            gradient.stop_count += 1;
        }
    }
    resolveGradientReferences();
    var index: usize = 0;
    while (index < gradient_count) : (index += 1) bakeGradientRamp(index);
}

const MAX_TEXT_CODEPOINTS: usize = 1024;
var text_codepoints: [MAX_TEXT_CODEPOINTS]u32 = undefined;

const DecodedChar = struct {
    codepoint: u32,
    len: usize,
};

fn decodeEntity(input: []const u8, start: usize) DecodedChar {
    const amp = DecodedChar{ .codepoint = '&', .len = 1 };
    var end = start + 1;
    while (end < input.len and end - start < 12 and input[end] != ';') end += 1;
    if (end >= input.len or input[end] != ';') return amp;
    const body = input[start + 1 .. end];
    const len = end + 1 - start;
    if (strEq(body, "amp")) return .{ .codepoint = '&', .len = len };
    if (strEq(body, "lt")) return .{ .codepoint = '<', .len = len };
    if (strEq(body, "gt")) return .{ .codepoint = '>', .len = len };
    if (strEq(body, "quot")) return .{ .codepoint = '"', .len = len };
    if (strEq(body, "apos")) return .{ .codepoint = '\'', .len = len };
    if (body.len >= 2 and body[0] == '#') {
        const hex = body[1] == 'x' or body[1] == 'X';
        const digits = if (hex) body[2..] else body[1..];
        if (digits.len == 0) return amp;
        var value: u32 = 0;
        for (digits) |digit| {
            const is_decimal = digit >= '0' and digit <= '9';
            const is_hex_letter = (digit >= 'a' and digit <= 'f') or (digit >= 'A' and digit <= 'F');
            if (!(is_decimal or (hex and is_hex_letter))) return amp;
            value = value * (if (hex) @as(u32, 16) else 10) + hexVal(digit);
        }
        if (value > 0x10FFFF) return amp;
        return .{ .codepoint = value, .len = len };
    }
    return amp;
}

// Reads character data up to `</text>`, keeping the text of nested elements
// such as <tspan> but not their positioning. Whitespace collapses as with the
// default xml:space handling.
fn readTextContent(input: []const u8, idx: *usize) usize {
    var count: usize = 0;
    var pending_space = false;
    while (idx.* < input.len) {
        const c = input[idx.*];
        if (c == '<') {
            if (idx.* + 1 < input.len and input[idx.* + 1] == '/') {
                var probe = idx.* + 2;
                if (strEq(readName(input, &probe), "text")) {
                    while (probe < input.len and input[probe] != '>') probe += 1;
                    idx.* = if (probe < input.len) probe + 1 else probe;
                    return count;
                }
            } else if (idx.* + 1 < input.len and input[idx.* + 1] == '!') {
                idx.* += 1;
                skipSpecial(input, idx);
                continue;
            }
            while (idx.* < input.len and input[idx.*] != '>') idx.* += 1;
            if (idx.* < input.len) idx.* += 1;
            continue;
        }
        var decoded = DecodedChar{ .codepoint = c, .len = 1 };
        if (c == '&') {
            decoded = decodeEntity(input, idx.*);
        } else if (c >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (len > 1 and idx.* + len <= input.len) {
                if (std.unicode.utf8Decode(input[idx.* .. idx.* + len])) |cp| {
                    decoded = .{ .codepoint = cp, .len = len };
                } else |_| {}
            }
        }
        idx.* += decoded.len;
        const cp = decoded.codepoint;
        if (cp == ' ' or cp == '\n' or cp == '\t' or cp == '\r') {
            if (count > 0) pending_space = true;
            continue;
        }
        if (count + 2 > MAX_TEXT_CODEPOINTS) continue;
        if (pending_space) {
            text_codepoints[count] = ' ';
            count += 1;
            pending_space = false;
        }
        text_codepoints[count] = cp;
        count += 1;
    }
    return count;
}

fn drawTextWithFont(comptime font: type, ctx: *ParserCtx, transform: Mat, style: Style, x: f32, y: f32, count: usize) void {
    const scale = style.font_size / font.UNITS_PER_EM;
    if (!(scale > 0)) return;
    const codepoints = text_codepoints[0..count];

    var width_units: f32 = 0;
    var previous: ?usize = null;
    for (codepoints) |cp| {
        const glyph = font.glyphIndex(cp) orelse continue;
        if (previous) |left| width_units += @floatFromInt(font.kerning(left, glyph));
        width_units += @floatFromInt(font.advances[glyph]);
        previous = glyph;
    }
    const width = width_units * scale;
    const start_x = switch (style.text_anchor) {
        .start => x,
        .middle => x - width * 0.5,
        .end => x - width,
    };
    const bounds = Bounds{
        .x = start_x,
        .y = y - font.ASCENDER * scale,
        .w = width,
        .h = (font.ASCENDER - font.DESCENDER) * scale,
    };
    const fill = resolvePaint(style.fill, style.fill_opacity * style.opacity, transform, bounds, .fill);
    const stroke = resolvePaint(style.stroke, style.stroke_opacity * style.opacity, transform, bounds, .stroke);
    const draw_fill = paintVisible(fill);
    const draw_stroke = paintVisible(stroke) and style.stroke_width > 0;
    if (!draw_fill and !draw_stroke) return;

    var pen_units: f32 = 0;
    previous = null;
    for (codepoints) |cp| {
        const glyph = font.glyphIndex(cp) orelse continue;
        if (previous) |left| pen_units += @floatFromInt(font.kerning(left, glyph));
        previous = glyph;
        const d = font.glyph_paths[glyph];
        const glyph_transform = matMul(transform, .{ .a = scale, .b = 0, .c = 0, .d = scale, .tx = start_x + pen_units * scale, .ty = y });
        pen_units += @floatFromInt(font.advances[glyph]);
        if (d.len == 0) continue;
        if (draw_fill) fillPath(ctx, glyph_transform, fill, flattenPath(d));
        if (draw_stroke) drawPathStroke(ctx, glyph_transform, stroke, style.stroke_width / scale, d);
    }
}

fn drawText(ctx: *ParserCtx, transform: Mat, style: Style, x: f32, y: f32, count: usize) void {
    if (count == 0) return;
    if (style.font_bold) {
        drawTextWithFont(font_bold, ctx, transform, style, x, y, count);
    } else {
        drawTextWithFont(font_regular, ctx, transform, style, x, y, count);
    }
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
    style: Style,
};

// Containers whose children are referenced, not drawn in place.
fn isNonRendered(name: []const u8) bool {
    const names = [_][]const u8{ "defs", "symbol", "clipPath", "mask", "pattern", "marker", "filter", "linearGradient", "radialGradient", "title", "desc", "metadata", "style", "script" };
    for (names) |candidate| {
        if (strEq(name, candidate)) return true;
    }
    return false;
}

// Skips to the end tag matching an open `name`, counting nested `name` tags.
fn skipElementContent(input: []const u8, idx: *usize, name: []const u8) void {
    var depth: usize = 1;
    while (idx.* < input.len) {
        while (idx.* < input.len and input[idx.*] != '<') idx.* += 1;
        if (idx.* >= input.len) return;
        idx.* += 1;
        if (idx.* >= input.len) return;
        if (input[idx.*] == '/') {
            idx.* += 1;
            const close = readName(input, idx);
            while (idx.* < input.len and input[idx.*] != '>') idx.* += 1;
            if (idx.* < input.len) idx.* += 1;
            if (strEq(close, name)) {
                depth -= 1;
                if (depth == 0) return;
            }
            continue;
        }
        if (input[idx.*] == '?' or input[idx.*] == '!') {
            skipSpecial(input, idx);
            continue;
        }
        const open = readName(input, idx);
        var self_closing = false;
        while (nextAttribute(input, idx, &self_closing)) |_| {}
        if (strEq(open, name) and !self_closing) depth += 1;
    }
}

fn parseElements(ctx: *ParserCtx, idx: *usize, root_transform: Mat, root_style: Style) void {
    const input = ctx.input;
    var group_stack: [MAX_GROUP_DEPTH]GroupFrame = undefined;
    var group_depth: usize = 0;
    var transform = root_transform;
    var style = root_style;

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
                style = group_stack[group_depth].style;
            }
            continue;
        }
        if (input[idx.*] == '?' or input[idx.*] == '!') {
            skipSpecial(input, idx);
            continue;
        }

        const name = readName(input, idx);
        var attrs = ElementAttrs{};
        var xs: [MAX_POINTS]f32 = undefined;
        var ys: [MAX_POINTS]f32 = undefined;
        parseAttributes(input, idx, &attrs, &xs, &ys);

        const final_transform = if (attrs.transform) |m| matMul(transform, m) else transform;
        const final_style = applyAttrs(style, attrs);
        const fill_opacity = final_style.fill_opacity * final_style.opacity;
        const stroke_opacity = final_style.stroke_opacity * final_style.opacity;
        const final_stroke_width = final_style.stroke_width;
        const rect = attrs.rect;
        const circle = attrs.circle;
        const line = attrs.line;
        const poly_count = attrs.poly_count;

        if (strEq(name, "g") or strEq(name, "svg")) {
            if (!attrs.self_closing) {
                if (group_depth >= MAX_GROUP_DEPTH) @trap();
                group_stack[group_depth] = .{
                    .end_tag = name,
                    .transform = transform,
                    .style = style,
                };
                group_depth += 1;
                transform = final_transform;
                style = final_style;
            }
        } else if (isNonRendered(name)) {
            if (!attrs.self_closing) skipElementContent(input, idx, name);
        } else if (strEq(name, "rect")) {
            const bounds = Bounds{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
            drawRect(ctx, final_transform, resolvePaint(final_style.fill, fill_opacity, final_transform, bounds, .fill), rect);
            drawRectStroke(ctx, final_transform, resolvePaint(final_style.stroke, stroke_opacity, final_transform, bounds, .stroke), rect, final_stroke_width);
        } else if (strEq(name, "circle")) {
            const bounds = Bounds{ .x = circle.cx - circle.r, .y = circle.cy - circle.r, .w = circle.r * 2, .h = circle.r * 2 };
            const fill = resolvePaint(final_style.fill, fill_opacity, final_transform, bounds, .fill);
            const stroke = resolvePaint(final_style.stroke, stroke_opacity, final_transform, bounds, .stroke);
            if (paintVisible(fill)) drawCircle(ctx, final_transform, fill, circle);
            if (paintVisible(stroke)) drawCircleStroke(ctx, final_transform, stroke, circle, final_stroke_width);
        } else if (strEq(name, "polygon")) {
            const bounds = pointBounds(&xs, &ys, poly_count);
            const fill = resolvePaint(final_style.fill, fill_opacity, final_transform, bounds, .fill);
            const stroke = resolvePaint(final_style.stroke, stroke_opacity, final_transform, bounds, .stroke);
            if (paintVisible(fill)) drawPolygon(ctx, final_transform, fill, &xs, &ys, poly_count);
            if (paintVisible(stroke)) drawPolygonStroke(ctx, final_transform, stroke, final_stroke_width, &xs, &ys, poly_count);
        } else if (strEq(name, "polyline")) {
            const stroke = resolvePaint(final_style.stroke, stroke_opacity, final_transform, pointBounds(&xs, &ys, poly_count), .stroke);
            drawPolylineStroke(ctx, final_transform, stroke, final_stroke_width, &xs, &ys, poly_count, false);
        } else if (strEq(name, "line")) {
            if (line.set_x1 and line.set_y1 and line.set_x2 and line.set_y2) {
                const bounds = Bounds{ .x = @min(line.x1, line.x2), .y = @min(line.y1, line.y2), .w = @abs(line.x2 - line.x1), .h = @abs(line.y2 - line.y1) };
                const stroke = resolvePaint(final_style.stroke, stroke_opacity, final_transform, bounds, .stroke);
                drawSegmentStroke(ctx, final_transform, stroke, final_stroke_width, line.x1, line.y1, line.x2, line.y2);
            }
        } else if (strEq(name, "path")) {
            if (attrs.path_d) |d| {
                // Flattening is skipped when nothing needs the fill geometry.
                const fill_spec = final_style.fill;
                const needs_bounds = fill_spec.gradient != null or final_style.stroke.gradient != null;
                const seg_count = if (needs_bounds or fill_spec.color.a != 0) flattenPath(d) else 0;
                const bounds = if (needs_bounds) segmentBounds(seg_count) else null;
                fillPath(ctx, final_transform, resolvePaint(fill_spec, fill_opacity, final_transform, bounds, .fill), seg_count);
                drawPathStroke(ctx, final_transform, resolvePaint(final_style.stroke, stroke_opacity, final_transform, bounds, .stroke), final_stroke_width, d);
            }
        } else if (strEq(name, "text")) {
            const count = if (attrs.self_closing) 0 else readTextContent(input, idx);
            drawText(ctx, final_transform, final_style, rect.x, rect.y, count);
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
                @as(f32, @floatFromInt(bg.r)) / 255.0 * alpha,
                @as(f32, @floatFromInt(bg.g)) / 255.0 * alpha,
                @as(f32, @floatFromInt(bg.b)) / 255.0 * alpha,
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
    collectGradients(input);
    const default_style = Style{
        .fill = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .stroke = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        .stroke_width = 1.0,
    };
    parseElements(&ctx, &idx, viewport.transform, default_style);
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
    defer resetUniforms();
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
    _ = uniform_set_current_color_rgba(0x11223344);
    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, 0), rejected.output_size_or_failure);
    try std.testing.expectEqual(DEFAULT_BACKGROUND_COLOR_RGBA, background_color_rgba);
    try std.testing.expectEqual(DEFAULT_CURRENT_COLOR_RGBA, current_color_rgba);

    const valid = "<svg width=\"1\" height=\"1\"></svg>";
    @memcpy(input_buf[0..valid.len], valid);
    _ = uniform_set_background_color_rgba(0x11223344);
    const accepted = renderOutcome(valid.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(DEFAULT_BACKGROUND_COLOR_RGBA, background_color_rgba);
    try std.testing.expectEqual(DEFAULT_CURRENT_COLOR_RGBA, current_color_rgba);
}

test "currentColor defaults to black and accepts a uniform override" {
    defer resetUniforms();
    try std.testing.expectEqual(colorFromRgba(DEFAULT_CURRENT_COLOR_RGBA), parseColor("currentColor").?);
    _ = uniform_set_current_color_rgba(0x11223344);
    try std.testing.expectEqual(colorFromRgba(0x11223344), parseColor("currentColor").?);
}

pub fn pixelAt(buf: []const u8, width: u32, height: u32, x: u32, y: u32) Color {
    if (OUTPUT_FLOAT) @compileError("pixelAt reads 8-bit output");
    const row = if (OUTPUT_KTX2) y else height - 1 - y;
    const idx: usize = @intCast(OUTPUT_HEADER_SIZE + (row * width + x) * 4);
    return Color{
        .r = if (OUTPUT_KTX2) buf[idx] else buf[idx + 2],
        .g = buf[idx + 1],
        .b = if (OUTPUT_KTX2) buf[idx + 2] else buf[idx],
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
    try std.testing.expect(output.len >= OUTPUT_HEADER_SIZE + 12 * 8 * 4);

    // KTX2 pixelWidth/pixelHeight at 20/24; BMP biWidth/biHeight at 18/22.
    const width_offset: usize = if (OUTPUT_KTX2) 20 else 18;
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, output[width_offset..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, output[width_offset + 4 ..][0..4], .little));

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

test "svg-rasterize linear and radial gradients" {
    const input =
        "<svg width=\"20\" height=\"20\">\n" ++
        "  <defs>\n" ++
        "    <linearGradient id=\"lr\"><stop offset=\"0\" stop-color=\"#ff0000\"/><stop offset=\"100%\" stop-color=\"#0000ff\"/></linearGradient>\n" ++
        "    <radialGradient id=\"rad\" href=\"#lr\"/>\n" ++
        "  </defs>\n" ++
        "  <rect width=\"20\" height=\"10\" fill=\"url(#lr)\"/>\n" ++
        "  <rect y=\"10\" width=\"20\" height=\"10\" fill=\"url('#rad')\"/>\n" ++
        "</svg>";

    const output = renderForTest(input);
    const left = pixelAt(output, 20, 20, 0, 5);
    const right = pixelAt(output, 20, 20, 19, 5);
    try std.testing.expect(left.r > 240 and left.b < 15);
    try std.testing.expect(right.b > 240 and right.r < 15);
    const middle = pixelAt(output, 20, 20, 10, 5);
    try std.testing.expect(middle.r > 100 and middle.r < 155 and middle.b > 100 and middle.b < 155);

    // The radial gradient inherits its stops through href.
    const center = pixelAt(output, 20, 20, 10, 15);
    const corner = pixelAt(output, 20, 20, 0, 19);
    try std.testing.expect(center.r > 200 and center.b < 55);
    try std.testing.expect(corner.b > 240 and corner.r < 15);
}

test "svg-rasterize unresolved paint references use their fallback or paint nothing" {
    const input =
        "<svg width=\"4\" height=\"2\">\n" ++
        "  <rect width=\"2\" height=\"2\" fill=\"url(#missing)\"/>\n" ++
        "  <rect x=\"2\" width=\"2\" height=\"2\" fill=\"url(#missing) #00ff00\"/>\n" ++
        "</svg>";

    const output = renderForTest(input);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 4, 2, 0, 0).a);
    const fallback = pixelAt(output, 4, 2, 3, 1);
    try std.testing.expectEqual(@as(u8, 0xFF), fallback.g);
    try std.testing.expectEqual(@as(u8, 0xFF), fallback.a);
}

test "svg-rasterize fill-opacity and opacity blend over the background" {
    const input =
        "<svg width=\"4\" height=\"2\">\n" ++
        "  <rect width=\"2\" height=\"2\" fill=\"#ff0000\" fill-opacity=\"0.5\"/>\n" ++
        "  <g opacity=\"0.5\"><rect x=\"2\" width=\"2\" height=\"2\" fill=\"#0000ff\"/></g>\n" ++
        "</svg>";

    const output = renderForTestWithBackground(input, 0xffffffff);
    const red = pixelAt(output, 4, 2, 0, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), red.r);
    try std.testing.expect(red.g > 100 and red.g < 200);
    try std.testing.expectEqual(red.g, red.b);
    try std.testing.expectEqual(@as(u8, 0xFF), red.a);
    const blue = pixelAt(output, 4, 2, 3, 1);
    try std.testing.expectEqual(@as(u8, 0xFF), blue.b);
    try std.testing.expect(blue.r > 100 and blue.r < 200);
}

test "svg-rasterize rounded rect corners" {
    const input =
        "<svg width=\"20\" height=\"20\">\n" ++
        "  <rect width=\"20\" height=\"20\" rx=\"8\" fill=\"#000000\"/>\n" ++
        "</svg>";

    const output = renderForTest(input);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 20, 20, 0, 0).a);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 20, 20, 19, 19).a);
    try std.testing.expectEqual(@as(u8, 0xFF), pixelAt(output, 20, 20, 10, 0).a);
    try std.testing.expectEqual(@as(u8, 0xFF), pixelAt(output, 20, 20, 10, 10).a);
}

test "svg-rasterize skips defs content" {
    const input =
        "<svg width=\"2\" height=\"2\">\n" ++
        "  <defs><rect width=\"2\" height=\"2\" fill=\"#ff0000\"/><defs/></defs>\n" ++
        "  <clipPath id=\"c\"><circle r=\"5\"/></clipPath>\n" ++
        "</svg>";

    const output = renderForTest(input);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 2, 2, 0, 0).a);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 2, 2, 1, 1).a);
}

test "svg-rasterize draws text with Inter outlines and text-anchor" {
    const input =
        "<svg width=\"40\" height=\"20\">\n" ++
        "  <text x=\"20\" y=\"17\" font-size=\"20\" font-weight=\"bold\" text-anchor=\"middle\" fill=\"#ff0000\">&#73;<tspan>I</tspan></text>\n" ++
        "</svg>";

    const output = renderForTest(input);
    var painted_left: u32 = 0;
    var painted_right: u32 = 0;
    var y: u32 = 0;
    while (y < 20) : (y += 1) {
        var x: u32 = 0;
        while (x < 40) : (x += 1) {
            if (pixelAt(output, 40, 20, x, y).a == 0) continue;
            if (x < 20) painted_left += 1 else painted_right += 1;
        }
    }
    // "II" centred on x=20 paints on both sides, and nothing far from it.
    try std.testing.expect(painted_left > 10);
    try std.testing.expect(painted_right > 10);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 40, 20, 2, 10).a);
    try std.testing.expectEqual(@as(u8, 0), pixelAt(output, 40, 20, 37, 10).a);
}
