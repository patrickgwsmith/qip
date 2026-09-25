const std = @import("std");

const OUTPUT_CAP = 65536;
const MAX_STOPS = 8;
const Point = struct { x: f64, y: f64 };
const Stop = struct { offset: f64, hue: f64, saturation: f64, lightness: f64, alpha: u8 };
const Drag = enum { none, start, end, stop, hue, saturation, lightness, alpha };

var output_buf: [OUTPUT_CAP]u8 = undefined;
var input_mime = "image/svg+xml".*;
var output_mime = "image/svg+xml".*;
var stops: [MAX_STOPS]Stop = undefined;
var count: usize = 3;
var selected: usize = 1;
var start = Point{ .x = 155, .y = 260 };
var end = Point{ .x = 645, .y = 210 };
var radial = false;
var editing = true;
var initialized = false;
var updating = false;
var down = false;
var drag: Drag = .none;
var begun_at: i64 = 0;
var committed_at: i64 = 0;

export fn input_ptr() i32 { return 0; }
export fn input_utf8_cap() i32 { return 0; }
export fn output_utf8_cap() i32 { return OUTPUT_CAP; }
export fn input_content_type_ptr() i32 { return @intCast(@intFromPtr(&input_mime)); }
export fn input_content_type_size() i32 { return input_mime.len; }
export fn output_content_type_ptr() i32 { return @intCast(@intFromPtr(&output_mime)); }
export fn output_content_type_size() i32 { return output_mime.len; }
export fn uniform_set_editing(value: u32) u32 {
    editing = value != 0;
    return @intFromBool(editing);
}

fn init() void {
    stops[0] = fromRgb(0, .{ 73, 62, 236 });
    stops[1] = fromRgb(0.5, .{ 243, 80, 139 });
    stops[2] = fromRgb(1, .{ 255, 190, 92 });
    initialized = true;
}

fn fromRgb(offset: f64, rgb: [3]u8) Stop {
    const r = @as(f64, @floatFromInt(rgb[0])) / 255.0;
    const g = @as(f64, @floatFromInt(rgb[1])) / 255.0;
    const b = @as(f64, @floatFromInt(rgb[2])) / 255.0;
    const high = @max(r, @max(g, b));
    const low = @min(r, @min(g, b));
    const delta = high - low;
    const lightness = (high + low) / 2.0;
    var hue: f64 = 0;
    if (delta > 0) {
        if (high == r) {
            hue = (g - b) / delta;
            if (hue < 0) hue += 6;
        } else if (high == g) {
            hue = (b - r) / delta + 2;
        } else {
            hue = (r - g) / delta + 4;
        }
    }
    return .{
        .offset = offset,
        .hue = hue * 60,
        .saturation = if (delta == 0) 0 else delta / (1 - @abs(2 * lightness - 1)),
        .lightness = lightness,
        .alpha = 255,
    };
}

fn toRgb(s: Stop) [4]u8 {
    const chroma = (1 - @abs(2 * s.lightness - 1)) * s.saturation;
    const sector = s.hue / 60;
    const x = chroma * (1 - @abs(@mod(sector, 2) - 1));
    const parts: [3]f64 = if (sector < 1) .{ chroma, x, 0 } else if (sector < 2) .{ x, chroma, 0 } else if (sector < 3) .{ 0, chroma, x } else if (sector < 4) .{ 0, x, chroma } else if (sector < 5) .{ x, 0, chroma } else .{ chroma, 0, x };
    const m = s.lightness - chroma / 2;
    return .{
        @intFromFloat(@round(std.math.clamp(parts[0] + m, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(parts[1] + m, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(parts[2] + m, 0, 1) * 255)),
        s.alpha,
    };
}

const Writer = struct {
    n: usize = 0,
    fn bytes(w: *Writer, s: []const u8) !void {
        if (s.len > OUTPUT_CAP - w.n) return error.Full;
        @memcpy(output_buf[w.n..][0..s.len], s);
        w.n += s.len;
    }
    fn fmt(w: *Writer, comptime f: []const u8, args: anytype) !void {
        const got = std.fmt.bufPrint(output_buf[w.n..], f, args) catch return error.Full;
        w.n += got.len;
    }
};

fn hex(w: *Writer, rgb: [4]u8) !void {
    try w.fmt("#{X:0>2}{X:0>2}{X:0>2}", .{ rgb[0], rgb[1], rgb[2] });
}

fn trackStop(w: *Writer, offset: u8, s: Stop, opacity: f64) !void {
    try w.fmt("<stop offset=\"{d}%\" stop-color=\"", .{offset});
    try hex(w, toRgb(s));
    try w.fmt("\" stop-opacity=\"{d:.3}\"/>", .{opacity});
}

fn sliderTracks(w: *Writer, current: Stop) !void {
    var sample = current;
    sample.saturation = 1;
    sample.lightness = 0.5;
    try w.bytes("<linearGradient id=\"qip-hue-track\">");
    for (0..7) |i| {
        sample.hue = @as(f64, @floatFromInt(i)) * 60;
        try trackStop(w, @intCast(i * 100 / 6), sample, 1);
    }
    try w.bytes("</linearGradient><linearGradient id=\"qip-saturation-track\">");
    sample = current;
    sample.saturation = 0;
    try trackStop(w, 0, sample, 1);
    sample.saturation = 1;
    try trackStop(w, 100, sample, 1);
    try w.bytes("</linearGradient><linearGradient id=\"qip-lightness-track\">");
    sample = current;
    sample.lightness = 0;
    try trackStop(w, 0, sample, 1);
    sample.lightness = 0.5;
    try trackStop(w, 50, sample, 1);
    sample.lightness = 1;
    try trackStop(w, 100, sample, 1);
    try w.bytes("</linearGradient><linearGradient id=\"qip-alpha-track\">");
    try trackStop(w, 0, current, 0);
    try trackStop(w, 100, current, 1);
    try w.bytes("</linearGradient>");
}

fn stopPoint(offset: f64) Point {
    return .{ .x = start.x + (end.x - start.x) * offset, .y = start.y + (end.y - start.y) * offset };
}

fn markerPoint(offset: f64) Point {
    const p = stopPoint(offset);
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const length = @sqrt(dx * dx + dy * dy);
    return .{ .x = p.x - dy / length * 23, .y = p.y + dx / length * 23 };
}

fn button(w: *Writer, x: u32, label: []const u8, role: []const u8, active: bool) !void {
    try w.fmt("<g data-qip-gradient-control=\"{s}\"><rect x=\"{d}\" y=\"18\" width=\"98\" height=\"34\" rx=\"17\" fill=\"{s}\" stroke=\"{s}\"/><text x=\"{d}\" y=\"40\" text-anchor=\"middle\" font-size=\"13\" font-weight=\"600\" fill=\"{s}\">{s}</text></g>", .{ role, x, if (active) "#1f2340" else "#fff", if (active) "#1f2340" else "#d8dce7", x + 49, if (active) "#fff" else "#374151", label });
}

fn slider(w: *Writer, row: usize, label: []const u8, role: []const u8, value: f64, max: f64, unit: []const u8, color: []const u8, track: []const u8) !void {
    const y: usize = 466 + row * 28;
    const thumb = 535.0 + 169.0 * value / max;
    try w.fmt("<g data-qip-gradient-control=\"{s}\" data-qip-gradient-channel=\"{s}\"><text x=\"448\" y=\"{d}\" font-size=\"12\" font-weight=\"600\" fill=\"#525b70\">{s}</text><rect x=\"535\" y=\"{d}\" width=\"169\" height=\"8\" rx=\"4\" fill=\"url(#{s})\" stroke=\"#c7cbd4\" stroke-width=\"0.5\"/><circle cx=\"{d:.2}\" cy=\"{d}\" r=\"9\" fill=\"#fff\" stroke=\"{s}\" stroke-width=\"2\"/><text x=\"758\" y=\"{d}\" text-anchor=\"end\" font-size=\"11\" fill=\"#6b7280\">{d}{s}</text></g>", .{ role, role, y + 3, label, y - 7, track, thumb, y - 3, color, y + 3, @as(u16, @intFromFloat(@round(value))), unit });
}

fn writeSvg() !usize {
    var w = Writer{};
    try w.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\" viewBox=\"0 0 800 600\"><defs>");
    if (radial) {
        const dx = end.x - start.x;
        const dy = end.y - start.y;
        try w.fmt("<radialGradient id=\"qip-gradient\" data-qip-gradient-definition=\"true\" gradientUnits=\"userSpaceOnUse\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\">", .{ start.x, start.y, @sqrt(dx * dx + dy * dy) });
    } else {
        try w.fmt("<linearGradient id=\"qip-gradient\" data-qip-gradient-definition=\"true\" gradientUnits=\"userSpaceOnUse\" x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\">", .{ start.x, start.y, end.x, end.y });
    }
    for (stops[0..count]) |s| {
        try w.fmt("<stop offset=\"{d:.4}\" stop-color=\"", .{s.offset});
        try hex(&w, toRgb(s));
        try w.fmt("\" stop-opacity=\"{d:.4}\"/>", .{@as(f64, @floatFromInt(s.alpha)) / 255.0});
    }
    try w.bytes("</");
    try w.bytes(if (radial) "radialGradient" else "linearGradient");
    try w.bytes(">");
    if (editing) try sliderTracks(&w, stops[selected]);
    try w.bytes("</defs><rect width=\"800\" height=\"600\" fill=\"#f7f8fc\"/><rect data-qip-gradient-swatch=\"true\" x=\"34\" y=\"72\" width=\"732\" height=\"342\" rx=\"20\" fill=\"url(#qip-gradient)\"/>");
    if (editing) {
        try w.bytes("<g data-qip-gradient-overlay=\"true\" font-family=\"Inter, system-ui, sans-serif\">");
        try button(&w, 34, "Linear", "mode-linear", !radial);
        try button(&w, 142, "Radial", "mode-radial", radial);
        try button(&w, 668, "Preview", "preview", false);
        try w.fmt("<path data-qip-gradient-control=\"rope\" d=\"M{d:.2} {d:.2} L{d:.2} {d:.2}\" fill=\"none\" stroke=\"#fff\" stroke-width=\"3\" stroke-dasharray=\"5 5\"/><path d=\"M{d:.2} {d:.2} L{d:.2} {d:.2}\" fill=\"none\" stroke=\"#22243b\" stroke-width=\"1\" stroke-dasharray=\"5 5\"/>", .{ start.x, start.y, end.x, end.y, start.x, start.y, end.x, end.y });
        for (stops[0..count], 0..) |s, i| {
            const p = markerPoint(s.offset);
            try w.fmt("<g data-qip-gradient-control=\"stop\" data-qip-gradient-stop-index=\"{d}\"><circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d}\" fill=\"#fff\" stroke=\"{s}\" stroke-width=\"{d}\"/><circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"5\" fill=\"", .{ i, p.x, p.y, if (i == selected) @as(u8, 13) else @as(u8, 11), if (i == selected) "#20243e" else "#fff", if (i == selected) @as(u8, 3) else @as(u8, 2), p.x, p.y });
            try hex(&w, toRgb(s));
            try w.bytes("\"/></g>");
        }
        try w.fmt("<circle data-qip-gradient-control=\"start-handle\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"9\" fill=\"#fff\" stroke=\"#20243e\" stroke-width=\"3\"/><circle data-qip-gradient-control=\"end-handle\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"9\" fill=\"#20243e\" stroke=\"#fff\" stroke-width=\"3\"/>", .{ start.x, start.y, end.x, end.y });
        try w.bytes("<text x=\"36\" y=\"460\" font-size=\"17\" font-weight=\"700\" fill=\"#20243e\">Gradient stops</text><text x=\"36\" y=\"487\" font-size=\"12\" fill=\"#626b7d\">Click the line to add a stop. Drag a stop to move it.</text><text x=\"36\" y=\"508\" font-size=\"12\" fill=\"#626b7d\">Select a stop to edit its color and opacity.</text><text x=\"36\" y=\"529\" font-size=\"12\" fill=\"#626b7d\">Delete removes a selected inner stop.</text><text x=\"36\" y=\"564\" font-size=\"12\" fill=\"#626b7d\">Press P to toggle preview.</text>");
        try w.bytes("<rect x=\"436\" y=\"442\" width=\"338\" height=\"130\" rx=\"15\" fill=\"#fff\" stroke=\"#e0e3eb\"/>");
        const c = stops[selected];
        try slider(&w, 0, "Hue", "channel-hue", c.hue, 360, "°", "#ef6179", "qip-hue-track");
        try slider(&w, 1, "Saturation", "channel-saturation", c.saturation * 100, 100, "%", "#34b89b", "qip-saturation-track");
        try slider(&w, 2, "Lightness", "channel-lightness", c.lightness * 100, 100, "%", "#5b80ed", "qip-lightness-track");
        try slider(&w, 3, "Opacity", "channel-alpha", @as(f64, @floatFromInt(c.alpha)) * 100 / 255, 100, "%", "#8a73d7", "qip-alpha-track");
        try w.bytes("</g>");
    }
    try w.bytes("</svg>");
    return w.n;
}

export fn render(input_size: u32) u64 {
    if (updating or input_size != 0) @trap();
    if (!initialized) init();
    const n = writeSvg() catch @trap();
    return (@as(u64, @intCast(@intFromPtr(&output_buf))) << 32) | @as(u64, @intCast(n));
}
export fn begin_update_at(now_ms: i64) void {
    if (!initialized or updating or now_ms <= committed_at or now_ms <= 0) @trap();
    updating = true;
    begun_at = now_ms;
}
export fn finish_update() i64 {
    if (!updating) @trap();
    updating = false;
    committed_at = begun_at;
    return begun_at;
}

fn dist2(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}
fn clampPoint(p: Point) Point {
    return .{ .x = std.math.clamp(p.x, 45, 755), .y = std.math.clamp(p.y, 83, 403) };
}
fn projection(p: Point) f64 {
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    return std.math.clamp(((p.x - start.x) * dx + (p.y - start.y) * dy) / (dx * dx + dy * dy), 0, 1);
}
fn applyDrag(p: Point) bool {
    switch (drag) {
        .start => if (dist2(p, end) > 900) {
            const next = clampPoint(p);
            if (dist2(start, next) == 0) return false;
            start = next;
            return true;
        },
        .end => if (dist2(p, start) > 900) {
            const next = clampPoint(p);
            if (dist2(end, next) == 0) return false;
            end = next;
            return true;
        },
        .stop => if (selected > 0 and selected + 1 < count) {
            const next = std.math.clamp(projection(p), stops[selected - 1].offset + 0.01, stops[selected + 1].offset - 0.01);
            if (stops[selected].offset == next) return false;
            stops[selected].offset = next;
            return true;
        },
        .hue, .saturation, .lightness, .alpha => {
            const fraction = std.math.clamp((p.x - 535) / 169.0, 0, 1);
            const s = &stops[selected];
            switch (drag) {
                .hue => {
                    const next = @round(fraction * 360);
                    if (s.hue == next) return false;
                    s.hue = next;
                },
                .saturation => {
                    const next = @round(fraction * 100) / 100;
                    if (s.saturation == next) return false;
                    s.saturation = next;
                },
                .lightness => {
                    const next = @round(fraction * 100) / 100;
                    if (s.lightness == next) return false;
                    s.lightness = next;
                },
                .alpha => {
                    const next: u8 = @intFromFloat(@round(fraction * 255));
                    if (s.alpha == next) return false;
                    s.alpha = next;
                },
                else => unreachable,
            }
            return true;
        },
        .none => {},
    }
    return false;
}

export fn pointer_event(mask: i32, x: i32, y: i32) i32 {
    if (!updating) @trap();
    const pressed = (mask & 1) != 0;
    const p = Point{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    if (!pressed) { down = false; drag = .none; return 0; }
    if (!editing) { down = true; return 0; }
    if (down) return @intFromBool(applyDrag(p));
    down = true;
    if (y >= 18 and y <= 52) {
        if (x >= 34 and x <= 132) { radial = false; return 1; }
        if (x >= 142 and x <= 240) { radial = true; return 1; }
        if (x >= 668 and x <= 766) { editing = false; return 1; }
    }
    if (x >= 526 and x <= 713 and y >= 450 and y <= 555) {
        const row: i32 = @divTrunc(y - 450, 28);
        if (row >= 0 and row < 4) {
            drag = switch (row) { 0 => .hue, 1 => .saturation, 2 => .lightness, else => .alpha };
            return @intFromBool(applyDrag(p));
        }
    }
    for (stops[0..count], 0..) |s, i| {
        if (dist2(p, markerPoint(s.offset)) <= 324) {
            selected = i;
            drag = .stop;
            return 1;
        }
    }
    if (dist2(p, start) <= 324) { drag = .start; return 1; }
    if (dist2(p, end) <= 324) { drag = .end; return 1; }
    const t = projection(p);
    if (dist2(p, stopPoint(t)) <= 225 and count < MAX_STOPS and t > 0.02 and t < 0.98) {
        var at: usize = 1;
        while (at < count and stops[at].offset < t) : (at += 1) {}
        var j = count;
        while (j > at) : (j -= 1) stops[j] = stops[j - 1];
        const a = stops[at - 1];
        const b = stops[at + 1];
        const f = (t - a.offset) / (b.offset - a.offset);
        var hue_delta = b.hue - a.hue;
        if (hue_delta > 180) hue_delta -= 360;
        if (hue_delta < -180) hue_delta += 360;
        var hue = a.hue + hue_delta * f;
        if (hue < 0) hue += 360;
        if (hue > 360) hue -= 360;
        stops[at] = .{
            .offset = t,
            .hue = hue,
            .saturation = a.saturation * (1 - f) + b.saturation * f,
            .lightness = a.lightness * (1 - f) + b.lightness * f,
            .alpha = @intFromFloat(@round(@as(f64, @floatFromInt(a.alpha)) * (1 - f) + @as(f64, @floatFromInt(b.alpha)) * f)),
        };
        count += 1;
        selected = at;
        drag = .stop;
        return 1;
    }
    return 0;
}

export fn key_event(key: i32, flags: i32) i32 {
    if (!updating) @trap();
    if ((flags & 1) == 0) return 0;
    switch (key) {
        'p', 'P' => { editing = !editing; return 1; },
        'l', 'L' => { radial = false; return 1; },
        'r', 'R' => { radial = true; return 1; },
        0xffff, 0xff08 => {
            if (editing and selected > 0 and selected + 1 < count) {
                var i = selected;
                while (i + 1 < count) : (i += 1) stops[i] = stops[i + 1];
                count -= 1;
                selected -= 1;
                return 1;
            }
        },
        else => {},
    }
    return 0;
}
