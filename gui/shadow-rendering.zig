const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const ui_font = @import("assets/dejavu_sans_mono_56_ascii_subset.zig");

const RENDER_W: usize = 1120;
const RENDER_H: usize = 720;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_RIGHT: i32 = 0xFF53;

const Color = [4]u8;
const PointF = struct {
    x: f32,
    y: f32,
};

const C_BG: Color = .{ 0xEF, 0xF2, 0xF5, 0xFF };
const C_PANEL: Color = .{ 0xFA, 0xFA, 0xF8, 0xFF };
const C_TILE: Color = .{ 0xFF, 0xFF, 0xFC, 0xFF };
const C_TILE_ALT: Color = .{ 0xF5, 0xF7, 0xFA, 0xFF };
const C_INK: Color = .{ 0x16, 0x1A, 0x20, 0xFF };
const C_MUTED: Color = .{ 0x67, 0x70, 0x7A, 0xFF };
const C_RULE: Color = .{ 0xC8, 0xD0, 0xD8, 0xFF };
const C_TRACK: Color = .{ 0xD8, 0xDD, 0xE3, 0xFF };
const C_ACCENT: Color = .{ 0xE1, 0x06, 0x00, 0xFF };
const C_ACCENT_DARK: Color = .{ 0x96, 0x0A, 0x0A, 0xFF };
const C_OBJECT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_OBJECT_EDGE: Color = .{ 0xBC, 0xC5, 0xCE, 0xFF };

const Slider = enum(u8) {
    x_offset,
    y_offset,
    blur,
    spread,
    opacity,
    radius,
};

const Profile = enum {
    css_gaussian,
    skia,
    ios,
    photoshop,
};

const AaProfile = enum {
    webkit,
    skia,
    webrender,
    figma,
    core_animation,
    photoshop,
};

const Platform = struct {
    title: []const u8,
    note: []const u8,
    profile: Profile,
    aa: AaProfile,
};

const platforms = [_]Platform{
    .{ .title = "SAFARI", .note = "CSS SIGMA B/2", .profile = .css_gaussian, .aa = .webkit },
    .{ .title = "CHROME", .note = "CSS SIGMA B/2", .profile = .css_gaussian, .aa = .skia },
    .{ .title = "FIREFOX", .note = "CSS SIGMA B/2", .profile = .css_gaussian, .aa = .webrender },
    .{ .title = "FIGMA", .note = "MATCHES CSS", .profile = .css_gaussian, .aa = .figma },
    .{ .title = "ANDROID", .note = "SKIA B/SQRT3", .profile = .skia, .aa = .skia },
    .{ .title = "IOS", .note = "CALAYER 2X", .profile = .ios, .aa = .core_animation },
    .{ .title = "PHOTOSHOP", .note = "SIZE PLUS SPREAD", .profile = .photoshop, .aa = .photoshop },
};

const SliderInfo = struct {
    label: []const u8,
    min: i32,
    max: i32,
    suffix: []const u8,
};

const slider_info = [_]SliderInfo{
    .{ .label = "X OFFSET", .min = -32, .max = 32, .suffix = "PX" },
    .{ .label = "Y OFFSET", .min = -20, .max = 56, .suffix = "PX" },
    .{ .label = "BLUR", .min = 0, .max = 64, .suffix = "PX" },
    .{ .label = "SPREAD", .min = -18, .max = 28, .suffix = "PX" },
    .{ .label = "OPACITY", .min = 5, .max = 90, .suffix = "PCT" },
    .{ .label = "CORNER", .min = 0, .max = 32, .suffix = "PX" },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var x_offset: i32 = 0;
var y_offset: i32 = 24;
var blur_radius: i32 = 24;
var spread_radius: i32 = 0;
var shadow_opacity: i32 = 44;
var corner_radius: i32 = 14;
var active_slider: i32 = -1;
var selected_slider: Slider = .blur;
var primary_down: bool = false;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    switch (x11_key) {
        '1'...'6' => {
            selected_slider = @as(Slider, @enumFromInt(@as(u8, @intCast(x11_key - '1'))));
            return 1;
        },
        XK_LEFT, '-' => {
            adjustSlider(selected_slider, -1);
            return 1;
        },
        XK_RIGHT, '+', '=' => {
            adjustSlider(selected_slider, 1);
            return 1;
        },
        'r', 'R', '0' => {
            resetValues();
            return 1;
        },
        else => return 0,
    }
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    if (down and !primary_down) {
        if (hit(x_px, y_px, 24, 648, 106, 34)) {
            resetValues();
            changed = true;
        } else if (sliderAt(x_px, y_px)) |idx| {
            active_slider = @intFromEnum(idx);
            selected_slider = idx;
            setSliderFromX(idx, x_px);
            changed = true;
        }
    } else if (down and primary_down and active_slider >= 0) {
        const slider = @as(Slider, @enumFromInt(@as(u8, @intCast(active_slider))));
        setSliderFromX(slider, x_px);
        changed = true;
    } else if (!down and primary_down) {
        active_slider = -1;
    }

    primary_down = down;
    return if (changed) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    phase = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf[0])),
        .failed = 0,
    };
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return begun_at_ms;
}

fn resetValues() void {
    x_offset = 0;
    y_offset = 24;
    blur_radius = 24;
    spread_radius = 0;
    shadow_opacity = 44;
    corner_radius = 14;
    selected_slider = .blur;
}

fn drawFrame() void {
    fillRect(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), C_BG);
    drawControlPanel();
    drawComparisonGrid();
}

fn drawControlPanel() void {
    fillRect(0, 0, 286, @as(i32, @intCast(RENDER_H)), C_PANEL);
    fillRect(284, 0, 2, @as(i32, @intCast(RENDER_H)), C_RULE);

    drawText(24, 24, "DROP SHADOW", C_INK, 3);
    drawText(24, 54, "RENDER MODELS", C_MUTED, 2);
    drawText(24, 92, "SAME INPUTS", C_INK, 2);

    var i: usize = 0;
    while (i < slider_info.len) : (i += 1) {
        drawSlider(@as(Slider, @enumFromInt(@as(u8, @intCast(i)))));
    }

    drawButton(24, 648, 106, 34, "RESET");
    drawText(146, 654, "1-6 SELECT", C_MUTED, 1);
    drawText(146, 668, "ARROWS ADJUST", C_MUTED, 1);
}

fn drawComparisonGrid() void {
    drawText(320, 24, "SHADOW RENDERING ACROSS PLATFORMS", C_INK, 2);
    drawText(320, 45, "THE CARDS USE THE SAME OFFSETS BLUR SPREAD OPACITY AND CORNER RADIUS", C_MUTED, 1);

    var i: usize = 0;
    while (i < platforms.len) : (i += 1) {
        const col = @as(i32, @intCast(i % 4));
        const row = @as(i32, @intCast(i / 4));
        const x = 316 + col * 198;
        const y = 74 + row * 208;
        drawPlatformCard(x, y, 184, 194, platforms[i]);
    }

    drawEdgeProfileStack(316, 500, 778, 184);
}

fn drawPlatformCard(x: i32, y: i32, w: i32, h: i32, platform: Platform) void {
    const bg = if (platform.profile == .ios or platform.profile == .skia) C_TILE_ALT else C_TILE;
    fillRect(x + 2, y + 3, w, h, .{ 0xD0, 0xD6, 0xDC, 0xFF });
    fillRect(x, y, w, h, bg);
    drawRect(x, y, w, h, C_RULE);

    drawText(x + 12, y + 12, platform.title, C_INK, 2);
    drawText(x + 12, y + 31, platform.note, C_MUTED, 1);
    drawText(x + 12, y + 43, aaLabel(platform.aa), C_MUTED, 1);

    const rw = 82;
    const rh = 52;
    const rx = x + @divTrunc(w - rw, 2);
    const ry = y + 68;
    drawShadow(x + 8, y + 58, w - 16, h - 66, @as(f64, @floatFromInt(rx)), @as(f64, @floatFromInt(ry)), @as(f64, @floatFromInt(rw)), @as(f64, @floatFromInt(rh)), platform);
    drawRoundedRect(rx, ry, rw, rh, corner_radius, C_OBJECT, C_OBJECT_EDGE, platform.aa);
}

fn drawEdgeProfileStack(x: i32, y: i32, w: i32, h: i32) void {
    fillRect(x + 2, y + 3, w, h, .{ 0xD0, 0xD6, 0xDC, 0xFF });
    fillRect(x, y, w, h, C_TILE);
    drawRect(x, y, w, h, C_RULE);

    drawText(x + 12, y + 12, "EDGE PROFILE STACK", C_INK, 2);
    drawText(x + 12, y + 31, "ALIGNED FALLOFF CURVES FOR THE SAME SHADOW INPUT", C_MUTED, 1);

    const label_x = x + 12;
    const bar_x = x + 124;
    const bar_w = w - 232;
    const sigma_x = x + w - 88;
    var i: usize = 0;
    while (i < platforms.len) : (i += 1) {
        const row_y = y + 52 + @as(i32, @intCast(i)) * 17;
        drawText(label_x, row_y + 1, platforms[i].title, C_INK, 1);
        drawProfileBar(bar_x, row_y, bar_w, 8, platforms[i]);
        fillRect(bar_x + @divTrunc(bar_w, 2), row_y - 2, 1, 12, C_ACCENT);
        drawSigmaLabel(sigma_x, row_y + 1, platforms[i].profile);
    }
}

fn drawShadow(clip_x: i32, clip_y: i32, clip_w: i32, clip_h: i32, rect_x: f64, rect_y: f64, rect_w: f64, rect_h: f64, platform: Platform) void {
    const sigma = platformSigma(platform.profile);
    const support = @max(8.0, sigma * 3.2 + aaWidth(platform.aa) * 2.0 + @as(f64, @floatFromInt(absI32(spread_radius))) + 8.0);
    const shadow_cx = rect_x + rect_w * 0.5 + @as(f64, @floatFromInt(x_offset));
    const shadow_cy = rect_y + rect_h * 0.5 + @as(f64, @floatFromInt(y_offset));
    const half_w = @max(1.0, rect_w * 0.5 + @as(f64, @floatFromInt(spread_radius)));
    const half_h = @max(1.0, rect_h * 0.5 + @as(f64, @floatFromInt(spread_radius)));
    const corner = clampF64(@as(f64, @floatFromInt(corner_radius + spread_radius)), 0.0, @min(half_w, half_h));

    const min_x = @max(clip_x, @as(i32, @intFromFloat(@floor(shadow_cx - half_w - support))));
    const max_x = @min(clip_x + clip_w - 1, @as(i32, @intFromFloat(@ceil(shadow_cx + half_w + support))));
    const min_y = @max(clip_y, @as(i32, @intFromFloat(@floor(shadow_cy - half_h - support))));
    const max_y = @min(clip_y + clip_h - 1, @as(i32, @intFromFloat(@ceil(shadow_cy + half_h + support))));
    if (min_x > max_x or min_y > max_y) return;

    const opacity = @as(f64, @floatFromInt(shadow_opacity)) / 100.0;
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const d = roundedRectSdf(px, py, shadow_cx, shadow_cy, half_w, half_h, corner);
            const a = shadowAlpha(d, platform.profile, platform.aa, sigma) * opacity;
            if (a > 0.003) blendPixel(x, y, C_INK, a);
        }
    }
}

fn drawProfileBar(x: i32, y: i32, w: i32, h: i32, platform: Platform) void {
    const sigma = platformSigma(platform.profile);
    var ix: i32 = 0;
    while (ix < w) : (ix += 1) {
        const t = @as(f64, @floatFromInt(ix)) / @as(f64, @floatFromInt(@max(1, w - 1)));
        const d = (t - 0.5) * @max(16.0, @as(f64, @floatFromInt(blur_radius)) * 2.6 + 20.0);
        const a = shadowAlpha(d, platform.profile, platform.aa, sigma);
        const v = @as(u8, @intFromFloat(@round(255.0 - a * 176.0)));
        fillRect(x + ix, y, 1, h, .{ v, v, v, 0xFF });
    }
    drawRect(x, y, w, h, C_RULE);
}

fn drawSigmaLabel(x: i32, y: i32, profile: Profile) void {
    drawText(x, y, "SIG", C_MUTED, 1);
    drawUnsignedInt(x + 25, y, @as(i32, @intFromFloat(@round(platformSigma(profile)))), C_MUTED, 1);
}

fn aaLabel(aa: AaProfile) []const u8 {
    return switch (aa) {
        .webkit => "AA WEBKIT",
        .skia => "AA SKIA",
        .webrender => "AA WEBRENDER",
        .figma => "AA FIGMA",
        .core_animation => "AA COREANIM",
        .photoshop => "AA PHOTOSHOP",
    };
}

fn platformSigma(profile: Profile) f64 {
    const b = @as(f64, @floatFromInt(blur_radius));
    if (b <= 0.0) return 0.0;
    return switch (profile) {
        .css_gaussian => b * 0.5,
        .skia => b * 0.57735026919 + 0.5,
        .ios => b,
        .photoshop => b * 0.42 + 0.75,
    };
}

fn shadowAlpha(distance: f64, profile: Profile, aa: AaProfile, sigma: f64) f64 {
    if (profile == .skia and blur_radius == 0) return 0.0;
    const aa_sigma = aaWidth(aa) * 0.35;
    if (sigma <= 0.05) return edgeCoverage(distance, aa);
    const effective_sigma = std.math.sqrt(sigma * sigma + aa_sigma * aa_sigma);
    return switch (profile) {
        .css_gaussian, .ios => normalCdf(-distance / effective_sigma),
        .skia => skiaIntegral(distance / (2.0 * effective_sigma)),
        .photoshop => photoshopProfile(distance, effective_sigma),
    };
}

fn edgeCoverage(distance: f64, aa: AaProfile) f64 {
    const c = clampF64(0.5 - distance / aaWidth(aa), 0.0, 1.0);
    return aaCurve(c, aa);
}

fn strokeCoverage(distance: f64, stroke_width: f64, aa: AaProfile) f64 {
    const c = clampF64((stroke_width * 0.5 + aaWidth(aa) * 0.5 - absF64(distance)) / aaWidth(aa), 0.0, 1.0);
    return aaCurve(c, aa);
}

fn aaWidth(aa: AaProfile) f64 {
    return switch (aa) {
        .webkit => 1.08,
        .skia => 1.00,
        .webrender => 0.96,
        .figma => 1.06,
        .core_animation => 1.22,
        .photoshop => 1.34,
    };
}

fn aaCurve(c: f64, aa: AaProfile) f64 {
    return switch (aa) {
        .skia => c,
        .webrender => c * c * (2.6 - 1.6 * c),
        .figma => smoothstep(c),
        .webkit => smoothstep(c),
        .core_animation => smootherstep(c),
        .photoshop => smoothstep(smoothstep(c)),
    };
}

fn smoothstep(c: f64) f64 {
    return c * c * (3.0 - 2.0 * c);
}

fn smootherstep(c: f64) f64 {
    return c * c * c * (c * (c * 6.0 - 15.0) + 10.0);
}

fn photoshopProfile(distance: f64, sigma: f64) f64 {
    const span = @max(1.0, sigma * 4.4);
    const t = clampF64(0.5 - distance / span, 0.0, 1.0);
    const s = t * t * (3.0 - 2.0 * t);
    return s * (0.94 + 0.06 * s);
}

fn skiaIntegral(x: f64) f64 {
    if (x > 1.5) return 0.0;
    if (x < -1.5) return 1.0;
    const x2 = x * x;
    const x3 = x2 * x;
    if (x > 0.5) return 0.5625 - (x3 / 6.0 - 0.75 * x2 + 1.125 * x);
    if (x > -0.5) return 0.5 - (0.75 * x - x3 / 3.0);
    return 0.4375 + (-x3 / 6.0 - 0.75 * x2 - 1.125 * x);
}

fn normalCdf(x: f64) f64 {
    return 0.5 * (1.0 + erfApprox(x * 0.70710678118));
}

fn erfApprox(x: f64) f64 {
    const sign: f64 = if (x < 0.0) -1.0 else 1.0;
    const ax = absF64(x);
    const t = 1.0 / (1.0 + 0.3275911 * ax);
    const poly = (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
    return sign * (1.0 - poly * std.math.exp(-(ax * ax)));
}

fn roundedRectSdf(px: f64, py: f64, cx: f64, cy: f64, half_w: f64, half_h: f64, radius: f64) f64 {
    const qx = absF64(px - cx) - (half_w - radius);
    const qy = absF64(py - cy) - (half_h - radius);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    const outside = std.math.sqrt(ox * ox + oy * oy);
    const inside = @min(@max(qx, qy), 0.0);
    return outside + inside - radius;
}

fn drawSlider(slider: Slider) void {
    const idx = @as(usize, @intFromEnum(slider));
    const info = slider_info[idx];
    const y = sliderY(slider);
    const active = selected_slider == slider;
    drawText(24, y - 21, info.label, if (active) C_INK else C_MUTED, 1);
    drawSignedInt(160, y - 21, sliderValue(slider), if (active) C_INK else C_MUTED, 1);
    drawText(202, y - 21, info.suffix, if (active) C_INK else C_MUTED, 1);

    fillRect(24, y, 214, 4, C_TRACK);
    const knob_x = sliderKnobX(slider);
    fillRect(knob_x - 4, y - 5, 8, 14, if (active) C_ACCENT else C_MUTED);
    drawRect(knob_x - 4, y - 5, 8, 14, if (active) C_ACCENT_DARK else C_INK);
}

fn sliderY(slider: Slider) i32 {
    return 142 + @as(i32, @intFromEnum(slider)) * 78;
}

fn sliderKnobX(slider: Slider) i32 {
    const info = slider_info[@as(usize, @intFromEnum(slider))];
    const value = sliderValue(slider);
    const t = @as(f64, @floatFromInt(value - info.min)) / @as(f64, @floatFromInt(info.max - info.min));
    return 24 + @as(i32, @intFromFloat(@round(t * 214.0)));
}

fn sliderAt(x: i32, y: i32) ?Slider {
    if (x < 16 or x > 248) return null;
    var i: usize = 0;
    while (i < slider_info.len) : (i += 1) {
        const slider = @as(Slider, @enumFromInt(@as(u8, @intCast(i))));
        const sy = sliderY(slider);
        if (y >= sy - 18 and y <= sy + 18) return slider;
    }
    return null;
}

fn setSliderFromX(slider: Slider, x: i32) void {
    const info = slider_info[@as(usize, @intFromEnum(slider))];
    const clamped_x = clampI32(x, 24, 238);
    const t = @as(f64, @floatFromInt(clamped_x - 24)) / 214.0;
    const value = info.min + @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(info.max - info.min)))));
    setSliderValue(slider, value);
}

fn adjustSlider(slider: Slider, delta: i32) void {
    const step: i32 = switch (slider) {
        .opacity => 5,
        else => 1,
    };
    setSliderValue(slider, sliderValue(slider) + delta * step);
}

fn sliderValue(slider: Slider) i32 {
    return switch (slider) {
        .x_offset => x_offset,
        .y_offset => y_offset,
        .blur => blur_radius,
        .spread => spread_radius,
        .opacity => shadow_opacity,
        .radius => corner_radius,
    };
}

fn setSliderValue(slider: Slider, value: i32) void {
    const info = slider_info[@as(usize, @intFromEnum(slider))];
    const v = clampI32(value, info.min, info.max);
    switch (slider) {
        .x_offset => x_offset = v,
        .y_offset => y_offset = v,
        .blur => blur_radius = v,
        .spread => spread_radius = v,
        .opacity => shadow_opacity = v,
        .radius => corner_radius = v,
    }
}

fn drawRoundedRect(x: i32, y: i32, w: i32, h: i32, r: i32, fill: Color, edge: Color, aa: AaProfile) void {
    const cx = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(w)) * 0.5;
    const cy = @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(h)) * 0.5;
    const hw = @as(f64, @floatFromInt(w)) * 0.5;
    const hh = @as(f64, @floatFromInt(h)) * 0.5;
    const rr = clampF64(@as(f64, @floatFromInt(r)), 0.0, @min(hw, hh));
    const pad = @as(i32, @intFromFloat(@ceil(aaWidth(aa) + 2.0)));
    const stroke_width = 1.15;
    var yy = y - pad;
    while (yy <= y + h + pad) : (yy += 1) {
        var xx = x - pad;
        while (xx <= x + w + pad) : (xx += 1) {
            const d = roundedRectSdf(@as(f64, @floatFromInt(xx)) + 0.5, @as(f64, @floatFromInt(yy)) + 0.5, cx, cy, hw, hh, rr);
            const fill_a = edgeCoverage(d, aa);
            if (fill_a > 0.001) blendPixel(xx, yy, fill, fill_a);
            const edge_a = strokeCoverage(d, stroke_width, aa) * 0.86;
            if (edge_a > 0.001) blendPixel(xx, yy, edge, edge_a);
        }
    }
}

fn drawButton(x: i32, y: i32, w: i32, h: i32, label: []const u8) void {
    fillRect(x + 2, y + 2, w, h, .{ 0xCA, 0xD1, 0xD8, 0xFF });
    fillRect(x, y, w, h, .{ 0xFF, 0xFF, 0xFF, 0xFF });
    drawRect(x, y, w, h, C_INK);
    drawText(x + 16, y + 11, label, C_INK, 1);
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    const size_px = textSizeForScale(scale);
    const advance = fontAdvance(size_px);
    var cursor = x;
    var i: usize = 0;
    while (i < text.len and i < 120) : (i += 1) {
        drawFontChar(cursor, y, text[i], c, size_px);
        cursor += advance;
    }
}

fn drawSignedInt(x: i32, y: i32, value: i32, c: Color, scale: i32) void {
    var cursor = x;
    if (value < 0) {
        drawFontChar(cursor, y, '-', c, textSizeForScale(scale));
        cursor += fontAdvance(textSizeForScale(scale));
        drawUnsignedInt(cursor, y, -value, c, scale);
    } else {
        drawUnsignedInt(cursor, y, value, c, scale);
    }
}

fn drawUnsignedInt(x: i32, y: i32, value_in: i32, c: Color, scale: i32) void {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var value = @as(u32, @intCast(@max(0, value_in)));
    while (true) {
        digits[count] = @as(u8, @intCast(value % 10));
        count += 1;
        value = @divTrunc(value, 10);
        if (value == 0 or count == digits.len) break;
    }

    var i = count;
    var cursor = x;
    const size_px = textSizeForScale(scale);
    const advance = fontAdvance(size_px);
    while (i > 0) {
        i -= 1;
        drawFontChar(cursor, y, '0' + digits[i], c, size_px);
        cursor += advance;
    }
}

fn textSizeForScale(scale: i32) i32 {
    return switch (scale) {
        1 => 11,
        2 => 16,
        3 => 23,
        else => @max(1, scale * 8),
    };
}

fn fontAdvance(size_px: i32) i32 {
    return @max(1, @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(ui_font.GLYPH_W)) * fontScale(size_px)))));
}

fn fontScale(size_px: i32) f32 {
    return @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(ui_font.GLYPH_H));
}

fn drawFontChar(x: i32, y: i32, ch: u8, c: Color, size_px: i32) void {
    const glyph_index = glyphIndexForByte(ch) orelse return;
    const scale = fontScale(size_px);
    const w = fontAdvance(size_px);
    const h = size_px;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const coverage = fontCoverage(glyph_index, dx, dy, scale);
            if (coverage == 0) continue;
            const alpha = (@as(f64, @floatFromInt(c[3])) / 255.0) * (@as(f64, @floatFromInt(coverage)) / 4.0);
            blendPixel(x + dx, y + dy, c, alpha);
        }
    }
}

fn glyphIndexForByte(ch: u8) ?usize {
    if (ch >= ui_font.ASCII_START and ch <= ui_font.ASCII_END) {
        return @as(usize, @intCast(ch - ui_font.ASCII_START));
    }
    return null;
}

fn fontCoverage(glyph_index: usize, dx: i32, dy: i32, scale: f32) i32 {
    const offsets = [_]PointF{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };

    var covered: i32 = 0;
    for (offsets) |off| {
        const sx = @as(i32, @intFromFloat(@floor((@as(f32, @floatFromInt(dx)) + off.x) / scale)));
        const sy = @as(i32, @intFromFloat(@floor((@as(f32, @floatFromInt(dy)) + off.y) / scale)));
        if (fontBit(glyph_index, sx, sy)) covered += 1;
    }
    return covered;
}

fn fontBit(glyph_index: usize, sx: i32, sy: i32) bool {
    if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(ui_font.GLYPH_W)) or sy >= @as(i32, @intCast(ui_font.GLYPH_H))) return false;
    const row = ui_font.glyph_rows[glyph_index][@as(usize, @intCast(sy))];
    return ((row >> @as(u6, @intCast(sx))) & 1) != 0;
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRect(x, y, w, 1, c);
    fillRect(x, y + h - 1, w, 1, c);
    fillRect(x, y, 1, h, c);
    fillRect(x + w - 1, y, 1, h, c);
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = @max(0, x);
    const sy = @max(0, y);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y + h);
    if (sx >= ex or sy >= ey) return;

    var yy = sy;
    while (yy < ey) : (yy += 1) {
        var xx = sx;
        while (xx < ex) : (xx += 1) setPixelI32(xx, yy, c);
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const ux = @as(usize, @intCast(x));
    const uy = @as(usize, @intCast(y));
    const idx = (uy * RENDER_W + ux) * 4;
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn blendPixel(x: i32, y: i32, c: Color, alpha: f64) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const a = clampF64(alpha, 0.0, 1.0);
    if (a <= 0.0) return;
    const ux = @as(usize, @intCast(x));
    const uy = @as(usize, @intCast(y));
    const idx = (uy * RENDER_W + ux) * 4;
    pixel_buf[idx + 0] = blendChannel(pixel_buf[idx + 0], c[0], a);
    pixel_buf[idx + 1] = blendChannel(pixel_buf[idx + 1], c[1], a);
    pixel_buf[idx + 2] = blendChannel(pixel_buf[idx + 2], c[2], a);
    pixel_buf[idx + 3] = 0xFF;
}

fn blendChannel(dst: u8, src: u8, alpha: f64) u8 {
    const d = @as(f64, @floatFromInt(dst));
    const s = @as(f64, @floatFromInt(src));
    return @as(u8, @intFromFloat(@round(d * (1.0 - alpha) + s * alpha)));
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn clampI32(v: i32, min_v: i32, max_v: i32) i32 {
    return if (v < min_v) min_v else if (v > max_v) max_v else v;
}

fn clampF64(v: f64, min_v: f64, max_v: f64) f64 {
    return if (v < min_v) min_v else if (v > max_v) max_v else v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn absF64(v: f64) f64 {
    return if (v < 0.0) -v else v;
}
