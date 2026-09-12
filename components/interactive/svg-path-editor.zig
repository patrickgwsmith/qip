const std = @import("std");

// This editor deliberately uses fixed storage. The input is also the retained
// source document: events change the parsed path records, and render is the
// only operation which publishes those changes.
const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const MAX_PATHS: usize = 256;
const MAX_ANCHORS: usize = 4096;
const MAX_DEPTH: usize = 64;

const Point = struct { x: f64 = 0, y: f64 = 0 };
const Matrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    fn mul(l: Matrix, r: Matrix) Matrix {
        return .{
            .a = l.a * r.a + l.c * r.b,
            .b = l.b * r.a + l.d * r.b,
            .c = l.a * r.c + l.c * r.d,
            .d = l.b * r.c + l.d * r.d,
            .e = l.a * r.e + l.c * r.f + l.e,
            .f = l.b * r.e + l.d * r.f + l.f,
        };
    }
    fn map(m: Matrix, p: Point) Point {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }
    fn inverse(m: Matrix) ?Matrix {
        const det = m.a * m.d - m.b * m.c;
        if (@abs(det) < 0.000000001) return null;
        return .{
            .a = m.d / det,
            .b = -m.b / det,
            .c = -m.c / det,
            .d = m.a / det,
            .e = (m.c * m.f - m.d * m.e) / det,
            .f = (m.b * m.e - m.a * m.f) / det,
        };
    }
};

const Seg = enum(u8) { move, line, cubic };
const Anchor = struct {
    p: Point = .{},
    hin: Point = .{},
    hout: Point = .{},
    seg: Seg = .move,
    subpath_start: bool = false,
    closes: bool = false,
};
const Path = struct {
    element_start: u32 = 0,
    element_end: u32 = 0,
    d_start: u32 = 0,
    d_end: u32 = 0,
    anchor_start: u16 = 0,
    anchor_count: u16 = 0,
    transform: Matrix = .{},
    inverse: Matrix = .{},
    editable: bool = false,
    modified: bool = false,
    deleted: bool = false,
    is_new: bool = false,
    filled: bool = true,
};
const EditorMode = enum { selection, pen };
const InteractionMode = enum { idle, drag_path, drag_anchor, drag_in_handle, drag_out_handle, marquee, drag_pen_handle, drag_pen_close };
const Selection = struct {
    paths: [MAX_PATHS]bool = [_]bool{false} ** MAX_PATHS,
    anchors: [MAX_ANCHORS]bool = [_]bool{false} ** MAX_ANCHORS,

    fn clear(self: *Selection) void {
        @memset(&self.paths, false);
        @memset(&self.anchors, false);
    }
};
const Skip = struct { start: u32 = 0, end: u32 = 0 };
const StackEntry = struct { name_start: u32 = 0, name_end: u32 = 0, matrix: Matrix = .{}, start: u32 = 0, overlay: bool = false, supported: bool = true, path_index: i16 = -1 };

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var paths: [MAX_PATHS]Path = [_]Path{.{}} ** MAX_PATHS;
var anchors: [MAX_ANCHORS]Anchor = [_]Anchor{.{}} ** MAX_ANCHORS;
var skips: [MAX_PATHS + 4]Skip = [_]Skip{.{}} ** (MAX_PATHS + 4);
var path_count: usize = 0;
var anchor_count: usize = 0;
var skip_count: usize = 0;
var source_len: usize = 0;
var root_close: usize = 0;
var root_tag_end: usize = 0;
var root_width: ?Attr = null;
var root_height: ?Attr = null;
var root_viewbox: ?Attr = null;
var root_self_closing = false;
var root_slash: usize = 0;
var initialized = false;
var updating = false;
var begun_at: i64 = 0;
var committed_at: i64 = 0;
var editor_mode: EditorMode = .selection;
var selection = Selection{};
var edited_path: ?usize = null;
var primary_down = false;
var alt_down = false;
var shift_down = false;
var space_down = false;
var interaction_mode: InteractionMode = .idle;
var drag_path: i32 = -1;
var drag_anchor: i32 = -1;
var last_pointer: Point = .{};
var marquee_start: Point = .{};
var marquee_end: Point = .{};
var draft_path: i32 = -1;
var editing = true;

const svg_mime = "image/svg+xml";
export fn input_ptr() i32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_utf8_cap() i32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() i32 {
    return OUTPUT_CAP;
}
export fn failure_modes_per_input_offset() i32 {
    return 3;
}
export fn input_content_type_ptr() i32 {
    return @intCast(@intFromPtr(svg_mime.ptr));
}
export fn input_content_type_size() i32 {
    return svg_mime.len;
}
export fn output_content_type_ptr() i32 {
    return @intCast(@intFromPtr(svg_mime.ptr));
}
export fn output_content_type_size() i32 {
    return svg_mime.len;
}
export fn uniform_set_editing(value: u32) u32 {
    editing = value != 0;
    return @intFromBool(editing);
}

fn failure(offset: usize, mode: u32) u64 {
    return (@as(u64, 1) << 63) | @as(u64, @intCast(offset * 3 + mode));
}
fn success(len: usize) u64 {
    return (@as(u64, @intCast(@intFromPtr(&output_buf))) << 32) | @as(u64, @intCast(len));
}

export fn render(input_size: u32) u64 {
    if (updating) @trap();
    if (!initialized) {
        if (input_size > INPUT_CAP) @trap();
        if (initDocument(input_size)) |bad| return failure(bad.offset, bad.mode);
        initialized = true;
    } else if (input_size != 0) @trap();
    const n = writeDocument() orelse @trap();
    return success(n);
}

export fn begin_update_at(now_ms: i64) void {
    if (!initialized or updating or now_ms <= 0 or now_ms <= committed_at) @trap();
    updating = true;
    begun_at = now_ms;
}
export fn finish_update() i64 {
    if (!updating) @trap();
    updating = false;
    committed_at = begun_at;
    return begun_at;
}

const ParseFailure = struct { offset: usize, mode: u32 };

fn resetState() void {
    path_count = 0;
    anchor_count = 0;
    skip_count = 0;
    root_close = 0;
    root_tag_end = 0;
    root_width = null;
    root_height = null;
    root_viewbox = null;
    root_self_closing = false;
    root_slash = 0;
    editor_mode = .selection;
    selection.clear();
    edited_path = null;
    primary_down = false;
    alt_down = false;
    shift_down = false;
    space_down = false;
    interaction_mode = .idle;
    drag_path = -1;
    drag_anchor = -1;
    draft_path = -1;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
fn isName(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.';
}
fn eqlName(src: []const u8, a: usize, b: usize, name: []const u8) bool {
    return std.mem.eql(u8, src[a..b], name);
}

fn initDocument(n: usize) ?ParseFailure {
    resetState();
    source_len = n;
    var nonspace = false;
    for (input_buf[0..n]) |c| if (!isSpace(c)) {
        nonspace = true;
        break;
    };
    if (!nonspace) {
        source_len = 0;
        return null;
    }
    const src = input_buf[0..n];
    var stack: [MAX_DEPTH]StackEntry = [_]StackEntry{.{}} ** MAX_DEPTH;
    var depth: usize = 0;
    var i: usize = 0;
    var saw_root = false;
    while (i < n) {
        if (src[i] != '<') {
            if (saw_root and depth == 0 and !isSpace(src[i])) return .{ .offset = i, .mode = 0 };
            i += 1;
            continue;
        }
        if (i + 4 <= n and std.mem.eql(u8, src[i .. i + 4], "<!--")) {
            const end = findSeq(src, i + 4, "-->") orelse return .{ .offset = n, .mode = 0 };
            i = end + 3;
            continue;
        }
        if (i + 2 <= n and src[i + 1] == '?') {
            const end = findSeq(src, i + 2, "?>") orelse return .{ .offset = n, .mode = 0 };
            i = end + 2;
            continue;
        }
        if (i + 9 <= n and std.mem.eql(u8, src[i .. i + 9], "<![CDATA[")) {
            const end = findSeq(src, i + 9, "]]>") orelse return .{ .offset = n, .mode = 0 };
            i = end + 3;
            continue;
        }
        if (i + 2 <= n and src[i + 1] == '!') {
            const end = findTagEnd(src, i + 2) orelse return .{ .offset = n, .mode = 0 };
            i = end + 1;
            continue;
        }
        if (i + 2 <= n and src[i + 1] == '/') {
            var p = i + 2;
            while (p < n and isSpace(src[p])) : (p += 1) {}
            const ns = p;
            while (p < n and isName(src[p])) : (p += 1) {}
            const ne = p;
            while (p < n and isSpace(src[p])) : (p += 1) {}
            if (ns == ne or p >= n or src[p] != '>' or depth == 0) return .{ .offset = i, .mode = 0 };
            const top = stack[depth - 1];
            if (!std.mem.eql(u8, src[ns..ne], src[top.name_start..top.name_end])) return .{ .offset = ns, .mode = 0 };
            depth -= 1;
            if (top.path_index >= 0) paths[@intCast(top.path_index)].element_end = @intCast(p + 1);
            if (top.overlay) addSkip(top.start, p + 1) orelse return .{ .offset = i, .mode = 2 };
            if (depth == 0) root_close = i;
            i = p + 1;
            continue;
        }
        var p = i + 1;
        while (p < n and isSpace(src[p])) : (p += 1) {}
        const ns = p;
        while (p < n and isName(src[p])) : (p += 1) {}
        const ne = p;
        if (ns == ne) return .{ .offset = i, .mode = 0 };
        const end = findTagEnd(src, p) orelse return .{ .offset = n, .mode = 0 };
        var q = end;
        while (q > p and isSpace(src[q - 1])) : (q -= 1) {}
        const self_close = q > p and src[q - 1] == '/';
        if (saw_root and depth == 0) return .{ .offset = i, .mode = 0 };
        const parent_matrix = if (depth == 0) Matrix{} else stack[depth - 1].matrix;
        var supported = depth == 0 or stack[depth - 1].supported;
        var local = Matrix{};
        if (findAttr(src, p, end, "transform")) |ta| {
            local = parseTransform(src[ta.value_start..ta.value_end]) orelse bad: {
                supported = false;
                break :bad Matrix{};
            };
        }
        if (findAttr(src, p, end, "style")) |style_attr| {
            if (std.mem.indexOf(u8, src[style_attr.value_start..style_attr.value_end], "transform") != null) supported = false;
        }
        if (eqlName(src, ns, ne, "svg")) {
            local = (svgViewport(src, p, end, depth == 0) orelse bad: {
                supported = false;
                break :bad Matrix{};
            }).mul(local);
        }
        const matrix = parent_matrix.mul(local);
        const overlay = attrEquals(src, p, end, "data-qip-editor-overlay", "true");
        if (!saw_root) {
            if (!eqlName(src, ns, ne, "svg")) return .{ .offset = ns, .mode = 1 };
            saw_root = true;
            root_tag_end = end;
            root_width = findAttr(src, p, end, "width");
            root_height = findAttr(src, p, end, "height");
            root_viewbox = findAttr(src, p, end, "viewBox");
            if (self_close) {
                root_self_closing = true;
                root_slash = q - 1;
                root_close = end + 1;
            }
        }
        var opened_path: i16 = -1;
        if (eqlName(src, ns, ne, "path") and !overlay and !ancestorOverlay(stack[0..depth])) {
            const before_path = path_count;
            scanPath(src, i, end + 1, p, end, matrix, supported) catch |err| return .{ .offset = i, .mode = if (err == error.Limit) 2 else 0 };
            if (path_count != before_path) opened_path = @intCast(before_path);
        }
        if (!self_close) {
            if (depth >= MAX_DEPTH) return .{ .offset = i, .mode = 2 };
            stack[depth] = .{ .name_start = @intCast(ns), .name_end = @intCast(ne), .matrix = matrix, .start = @intCast(i), .overlay = overlay or ancestorOverlay(stack[0..depth]), .supported = supported, .path_index = opened_path };
            depth += 1;
        } else if (overlay or ancestorOverlay(stack[0..depth])) addSkip(i, end + 1) orelse return .{ .offset = i, .mode = 2 };
        i = end + 1;
    }
    if (!saw_root) return .{ .offset = n, .mode = 1 };
    if (depth != 0 or root_close == 0) return .{ .offset = n, .mode = 0 };
    return null;
}

fn ancestorOverlay(s: []const StackEntry) bool {
    for (s) |v| if (v.overlay) return true;
    return false;
}
fn findSeq(s: []const u8, from: usize, needle: []const u8) ?usize {
    return std.mem.indexOfPos(u8, s, from, needle);
}
fn findTagEnd(s: []const u8, from: usize) ?usize {
    var quote: u8 = 0;
    var i = from;
    while (i < s.len) : (i += 1) {
        if (quote != 0) {
            if (s[i] == quote) quote = 0;
        } else if (s[i] == '\'' or s[i] == '"') quote = s[i] else if (s[i] == '>') return i;
    }
    return null;
}
fn addSkip(a: usize, b: usize) ?void {
    if (skip_count >= skips.len) return null;
    skips[skip_count] = .{ .start = @intCast(a), .end = @intCast(b) };
    skip_count += 1;
}

const Attr = struct { value_start: usize, value_end: usize };
fn findAttr(s: []const u8, from: usize, end: usize, wanted: []const u8) ?Attr {
    var i = from;
    while (i < end) {
        while (i < end and (isSpace(s[i]) or s[i] == '/')) : (i += 1) {}
        const a = i;
        while (i < end and isName(s[i])) : (i += 1) {}
        if (a == i) {
            i += 1;
            continue;
        }
        const b = i;
        while (i < end and isSpace(s[i])) : (i += 1) {}
        if (i >= end or s[i] != '=') continue;
        i += 1;
        while (i < end and isSpace(s[i])) : (i += 1) {}
        if (i >= end or (s[i] != '\'' and s[i] != '"')) continue;
        const quote = s[i];
        i += 1;
        const vs = i;
        while (i < end and s[i] != quote) : (i += 1) {}
        if (i >= end) return null;
        if (std.mem.eql(u8, s[a..b], wanted)) return .{ .value_start = vs, .value_end = i };
        i += 1;
    }
    return null;
}
fn attrEquals(s: []const u8, from: usize, end: usize, name: []const u8, value: []const u8) bool {
    const a = findAttr(s, from, end, name) orelse return false;
    return std.mem.eql(u8, s[a.value_start..a.value_end], value);
}

fn parseTransformAttr(s: []const u8, from: usize, end: usize) ?Matrix {
    const a = findAttr(s, from, end, "transform") orelse return Matrix{};
    return parseTransform(s[a.value_start..a.value_end]);
}

fn attrNumber(s: []const u8, from: usize, end: usize, name: []const u8) ?f64 {
    const a = findAttr(s, from, end, name) orelse return null;
    const value = s[a.value_start..a.value_end];
    var i: usize = 0;
    const number = parseNumber(value, &i) orelse return null;
    while (i < value.len and isSpace(value[i])) : (i += 1) {}
    if (i != value.len) return null;
    return number;
}
fn attrNumberOr(s: []const u8, from: usize, end: usize, name: []const u8, fallback: f64) ?f64 {
    if (findAttr(s, from, end, name) == null) return fallback;
    return attrNumber(s, from, end, name);
}

fn svgViewport(s: []const u8, from: usize, end: usize, root: bool) ?Matrix {
    const x = attrNumberOr(s, from, end, "x", 0) orelse return null;
    const y = attrNumberOr(s, from, end, "y", 0) orelse return null;
    const vb = findAttr(s, from, end, "viewBox") orelse return Matrix{ .e = if (root) 0 else x, .f = if (root) 0 else y };
    const value = s[vb.value_start..vb.value_end];
    var i: usize = 0;
    const min_x = parseNumber(value, &i) orelse return null;
    const min_y = parseNumber(value, &i) orelse return null;
    const vb_w = parseNumber(value, &i) orelse return null;
    const vb_h = parseNumber(value, &i) orelse return null;
    skipCommaSpace(value, &i);
    if (i != value.len or vb_w <= 0 or vb_h <= 0) return null;
    const width = if (root) 800 else (attrNumberOr(s, from, end, "width", vb_w) orelse return null);
    const height = if (root) 600 else (attrNumberOr(s, from, end, "height", vb_h) orelse return null);
    if (width <= 0 or height <= 0) return null;
    var none = false;
    if (findAttr(s, from, end, "preserveAspectRatio")) |pa| {
        const raw = std.mem.trim(u8, s[pa.value_start..pa.value_end], " \t\r\n");
        if (std.mem.eql(u8, raw, "none")) none = true else if (!std.mem.eql(u8, raw, "xMidYMid meet") and !std.mem.eql(u8, raw, "xMidYMid")) return null;
    }
    var sx = width / vb_w;
    var sy = height / vb_h;
    var ox: f64 = 0;
    var oy: f64 = 0;
    if (!none) {
        const scale = @min(sx, sy);
        ox = (width - vb_w * scale) / 2;
        oy = (height - vb_h * scale) / 2;
        sx = scale;
        sy = scale;
    }
    return .{ .a = sx, .d = sy, .e = (if (root) 0 else x) + ox - min_x * sx, .f = (if (root) 0 else y) + oy - min_y * sy };
}
fn parseTransform(s: []const u8) ?Matrix {
    var i: usize = 0;
    var result = Matrix{};
    while (true) {
        skipCommaSpace(s, &i);
        if (i == s.len) return result;
        const ns = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) : (i += 1) {}
        const name = s[ns..i];
        skipCommaSpace(s, &i);
        if (i >= s.len or s[i] != '(') return null;
        i += 1;
        var vals: [6]f64 = undefined;
        var count: usize = 0;
        while (true) {
            skipCommaSpace(s, &i);
            if (i >= s.len) return null;
            if (s[i] == ')') {
                i += 1;
                break;
            }
            if (count == vals.len) return null;
            vals[count] = parseNumber(s, &i) orelse return null;
            count += 1;
        }
        var m = Matrix{};
        if (std.mem.eql(u8, name, "matrix") and count == 6) m = .{ .a = vals[0], .b = vals[1], .c = vals[2], .d = vals[3], .e = vals[4], .f = vals[5] } else if (std.mem.eql(u8, name, "translate") and (count == 1 or count == 2)) {
            m.e = vals[0];
            m.f = if (count == 2) vals[1] else 0;
        } else if (std.mem.eql(u8, name, "scale") and (count == 1 or count == 2)) {
            m.a = vals[0];
            m.d = if (count == 2) vals[1] else vals[0];
        } else if (std.mem.eql(u8, name, "rotate") and (count == 1 or count == 3)) {
            const rad = vals[0] * std.math.pi / 180.0;
            const c = @cos(rad);
            const sn = @sin(rad);
            const r = Matrix{ .a = c, .b = sn, .c = -sn, .d = c };
            m = if (count == 1) r else (Matrix{ .e = vals[1], .f = vals[2] }).mul(r).mul(Matrix{ .e = -vals[1], .f = -vals[2] });
        } else if (std.mem.eql(u8, name, "skewX") and count == 1) m.c = @tan(vals[0] * std.math.pi / 180.0) else if (std.mem.eql(u8, name, "skewY") and count == 1) m.b = @tan(vals[0] * std.math.pi / 180.0) else return null;
        result = result.mul(m);
    }
}

fn skipCommaSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and (isSpace(s[i.*]) or s[i.*] == ',')) i.* += 1;
}
fn parseNumber(s: []const u8, i: *usize) ?f64 {
    skipCommaSpace(s, i);
    const start = i.*;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) i.* += 1;
    var digits = false;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) {
        i.* += 1;
        digits = true;
    }
    if (i.* < s.len and s[i.*] == '.') {
        i.* += 1;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) {
            i.* += 1;
            digits = true;
        }
    }
    if (!digits) {
        i.* = start;
        return null;
    }
    if (i.* < s.len and (s[i.*] == 'e' or s[i.*] == 'E')) {
        i.* += 1;
        if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) i.* += 1;
        const es = i.*;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) i.* += 1;
        if (es == i.*) {
            i.* = start;
            return null;
        }
    }
    return std.fmt.parseFloat(f64, s[start..i.*]) catch null;
}

fn scanPath(src: []const u8, element_start: usize, element_end: usize, attrs_start: usize, attrs_end: usize, matrix: Matrix, supported: bool) !void {
    if (path_count >= MAX_PATHS) return error.Limit;
    const d = findAttr(src, attrs_start, attrs_end, "d") orelse return;
    var path = Path{ .element_start = @intCast(element_start), .element_end = @intCast(element_end), .d_start = @intCast(d.value_start), .d_end = @intCast(d.value_end), .anchor_start = @intCast(anchor_count), .transform = matrix };
    if (findAttr(src, attrs_start, attrs_end, "fill")) |fill| path.filled = !std.mem.eql(u8, std.mem.trim(u8, src[fill.value_start..fill.value_end], " \t\r\n"), "none");
    if (!supported) {
        paths[path_count] = path;
        path_count += 1;
        return;
    }
    path.inverse = matrix.inverse() orelse {
        paths[path_count] = path;
        path_count += 1;
        return;
    };
    const before = anchor_count;
    if (parsePathData(src[d.value_start..d.value_end])) |_| {
        path.anchor_count = @intCast(anchor_count - before);
        path.editable = path.anchor_count > 0;
    } else |_| {
        anchor_count = before;
    }
    paths[path_count] = path;
    path_count += 1;
}

fn appendAnchor(a: Anchor) !void {
    if (anchor_count >= MAX_ANCHORS) return error.Limit;
    anchors[anchor_count] = a;
    anchor_count += 1;
}
fn parsePathData(s: []const u8) !void {
    var i: usize = 0;
    var cmd: u8 = 0;
    var cur = Point{};
    var start = Point{};
    var previous_c2 = Point{};
    var previous_cubic = false;
    while (true) {
        skipCommaSpace(s, &i);
        if (i == s.len) return;
        if (std.ascii.isAlphabetic(s[i])) {
            cmd = s[i];
            i += 1;
        } else if (cmd == 0) return error.Syntax;
        const rel = std.ascii.isLower(cmd);
        const upper = std.ascii.toUpper(cmd);
        if (upper == 'Q' or upper == 'T' or upper == 'A') return error.Unsupported;
        if (upper == 'Z') {
            if (anchor_count == 0) return error.Syntax;
            anchors[anchor_count - 1].closes = true;
            cur = start;
            previous_cubic = false;
            cmd = 0;
            continue;
        }
        var first = true;
        while (true) {
            const save = i;
            skipCommaSpace(s, &i);
            if (i == s.len or std.ascii.isAlphabetic(s[i])) break;
            if (upper == 'M' or upper == 'L') {
                var x = parseNumber(s, &i) orelse {
                    i = save;
                    break;
                };
                const y = parseNumber(s, &i) orelse return error.Syntax;
                if (rel) {
                    x += cur.x;
                }
                const yy = if (rel) y + cur.y else y;
                cur = .{ .x = x, .y = yy };
                const moving = upper == 'M' and first;
                if (moving) start = cur;
                try appendAnchor(.{ .p = cur, .hin = cur, .hout = cur, .seg = if (moving) .move else .line, .subpath_start = moving });
                first = false;
            } else if (upper == 'H') {
                var x = parseNumber(s, &i) orelse {
                    i = save;
                    break;
                };
                if (rel) x += cur.x;
                cur.x = x;
                try appendAnchor(.{ .p = cur, .hin = cur, .hout = cur, .seg = .line });
                first = false;
            } else if (upper == 'V') {
                var y = parseNumber(s, &i) orelse {
                    i = save;
                    break;
                };
                if (rel) y += cur.y;
                cur.y = y;
                try appendAnchor(.{ .p = cur, .hin = cur, .hout = cur, .seg = .line });
                first = false;
            } else if (upper == 'C') {
                var x1 = parseNumber(s, &i) orelse {
                    i = save;
                    break;
                };
                var y1 = parseNumber(s, &i) orelse return error.Syntax;
                var x2 = parseNumber(s, &i) orelse return error.Syntax;
                var y2 = parseNumber(s, &i) orelse return error.Syntax;
                var x = parseNumber(s, &i) orelse return error.Syntax;
                var y = parseNumber(s, &i) orelse return error.Syntax;
                if (rel) {
                    x1 += cur.x;
                    y1 += cur.y;
                    x2 += cur.x;
                    y2 += cur.y;
                    x += cur.x;
                    y += cur.y;
                }
                if (anchor_count == 0) return error.Syntax;
                anchors[anchor_count - 1].hout = .{ .x = x1, .y = y1 };
                cur = .{ .x = x, .y = y };
                try appendAnchor(.{ .p = cur, .hin = .{ .x = x2, .y = y2 }, .hout = cur, .seg = .cubic });
                previous_c2 = .{ .x = x2, .y = y2 };
                previous_cubic = true;
                first = false;
            } else if (upper == 'S') {
                var x2 = parseNumber(s, &i) orelse {
                    i = save;
                    break;
                };
                var y2 = parseNumber(s, &i) orelse return error.Syntax;
                var x = parseNumber(s, &i) orelse return error.Syntax;
                var y = parseNumber(s, &i) orelse return error.Syntax;
                if (rel) {
                    x2 += cur.x;
                    y2 += cur.y;
                    x += cur.x;
                    y += cur.y;
                }
                const c1 = if (previous_cubic) Point{ .x = 2 * cur.x - previous_c2.x, .y = 2 * cur.y - previous_c2.y } else cur;
                if (anchor_count == 0) return error.Syntax;
                anchors[anchor_count - 1].hout = c1;
                cur = .{ .x = x, .y = y };
                try appendAnchor(.{ .p = cur, .hin = .{ .x = x2, .y = y2 }, .hout = cur, .seg = .cubic });
                previous_c2 = .{ .x = x2, .y = y2 };
                previous_cubic = true;
                first = false;
            } else return error.Unsupported;
            if (upper != 'C' and upper != 'S') previous_cubic = false;
            if (upper == 'M') cmd = if (rel) 'l' else 'L';
        }
        if (first) return error.Syntax;
    }
}

const Writer = struct {
    n: usize = 0,
    fn bytes(w: *Writer, s: []const u8) !void {
        if (w.n + s.len > OUTPUT_CAP) return error.Full;
        @memcpy(output_buf[w.n .. w.n + s.len], s);
        w.n += s.len;
    }
    fn fmt(w: *Writer, comptime f: []const u8, args: anytype) !void {
        const got = std.fmt.bufPrint(output_buf[w.n..], f, args) catch return error.Full;
        w.n += got.len;
    }
};
fn writeNumber(w: *Writer, v: f64) !void {
    const value = if (@abs(v) < 0.0000005) 0 else v;
    if (@abs(value - @round(value)) < 0.0000005) {
        try w.fmt("{d}", .{@as(i64, @intFromFloat(@round(value)))});
    } else {
        var number_buf: [64]u8 = undefined;
        const formatted = std.fmt.bufPrint(&number_buf, "{d:.3}", .{value}) catch return error.Full;
        var end = formatted.len;
        while (end > 0 and formatted[end - 1] == '0') end -= 1;
        if (end > 0 and formatted[end - 1] == '.') end -= 1;
        try w.bytes(formatted[0..end]);
    }
}
fn writePathD(w: *Writer, p: Path) !void {
    const aa = anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count];
    var subpath_first: usize = 0;
    for (aa, 0..) |a, j| {
        if (a.subpath_start) subpath_first = j;
        if (j > 0) try w.bytes(" ");
        switch (a.seg) {
            .move => try w.bytes("M"),
            .line => try w.bytes("L"),
            .cubic => {
                try w.bytes("C");
                const prev = aa[j - 1];
                try writeNumber(w, prev.hout.x);
                try w.bytes(" ");
                try writeNumber(w, prev.hout.y);
                try w.bytes(" ");
                try writeNumber(w, a.hin.x);
                try w.bytes(" ");
                try writeNumber(w, a.hin.y);
                try w.bytes(" ");
            },
        }
        try writeNumber(w, a.p.x);
        try w.bytes(" ");
        try writeNumber(w, a.p.y);
        if (a.closes) {
            const first = aa[subpath_first];
            if (closingIsCubic(a, first)) {
                try w.bytes(" C");
                try writeNumber(w, a.hout.x);
                try w.bytes(" ");
                try writeNumber(w, a.hout.y);
                try w.bytes(" ");
                try writeNumber(w, first.hin.x);
                try w.bytes(" ");
                try writeNumber(w, first.hin.y);
                try w.bytes(" ");
                try writeNumber(w, first.p.x);
                try w.bytes(" ");
                try writeNumber(w, first.p.y);
            }
            try w.bytes(" Z");
        }
    }
}

fn closingIsCubic(last: Anchor, first: Anchor) bool {
    return dist2(last.p, last.hout) > 0.000001 or dist2(first.p, first.hin) > 0.000001;
}
fn covered(pos: usize) ?usize {
    for (skips[0..skip_count]) |s| if (pos >= s.start and pos < s.end) return s.end;
    for (paths[0..path_count]) |p| if (p.deleted and !p.is_new and pos >= p.element_start and pos < p.element_end) return p.element_end;
    return null;
}
fn modifiedD(pos: usize) ?usize {
    for (paths[0..path_count], 0..) |p, idx| if (p.modified and !p.deleted and !p.is_new and pos == p.d_start) return idx;
    return null;
}
fn rootViewportValue(pos: usize) ?struct { end: usize, value: []const u8 } {
    if (root_width) |a| if (pos == a.value_start) return .{ .end = a.value_end, .value = "800" };
    if (root_height) |a| if (pos == a.value_start) return .{ .end = a.value_end, .value = "600" };
    if (root_viewbox) |a| if (pos == a.value_start) return .{ .end = a.value_end, .value = "0 0 800 600" };
    return null;
}
fn writeDocument() ?usize {
    var w = Writer{};
    if (source_len == 0) {
        w.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\" viewBox=\"0 0 800 600\">") catch return null;
    }
    var i: usize = 0;
    while (i < source_len) {
        if (i == root_close) writeAddedPathsAndOverlay(&w) catch return null;
        if (i == root_tag_end) {
            if (root_width == null) w.bytes(" width=\"800\"") catch return null;
            if (root_height == null) w.bytes(" height=\"600\"") catch return null;
            if (root_viewbox == null) w.bytes(" viewBox=\"0 0 800 600\"") catch return null;
        }
        if (covered(i)) |end| {
            i = end;
            continue;
        }
        if (rootViewportValue(i)) |replacement| {
            w.bytes(replacement.value) catch return null;
            i = replacement.end;
            continue;
        }
        if (root_self_closing and i == root_slash) {
            i += 1;
            continue;
        }
        if (modifiedD(i)) |pi| {
            writePathD(&w, paths[pi]) catch return null;
            i = paths[pi].d_end;
            continue;
        }
        w.bytes(input_buf[i .. i + 1]) catch return null;
        i += 1;
    }
    if (source_len != 0 and root_self_closing) {
        writeAddedPathsAndOverlay(&w) catch return null;
        w.bytes("</svg>") catch return null;
    }
    if (source_len == 0) {
        writeAddedPathsAndOverlay(&w) catch return null;
        w.bytes("</svg>") catch return null;
    }
    return w.n;
}
fn writeAddedPathsAndOverlay(w: *Writer) !void {
    for (paths[0..path_count]) |p| if (p.is_new and !p.deleted) {
        try w.bytes("<path d=\"");
        try writePathD(w, p);
        try w.bytes("\" fill=\"none\" stroke=\"#111827\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>");
    };
    if (!editing) return;
    try w.bytes("<g data-qip-editor-overlay=\"true\" data-qip-editor-mode=\"");
    try w.bytes(if (editor_mode == .pen) "pen" else "selection");
    try w.bytes("\" data-qip-edited-path=\"");
    if (edited_path) |pi| try w.fmt("{d}", .{pi}) else try w.bytes("none");
    try w.bytes("\" pointer-events=\"none\"><style>.qip-ui{font:14px sans-serif}.qip-tool-active{fill:#dbeafe}.qip-hit{fill:#fff;stroke:#2563eb;stroke-width:2}.qip-hit-selected{fill:#2563eb;stroke:#fff;stroke-width:1.5}.qip-line{fill:none;stroke:#2563eb;stroke-width:1}</style><rect x=\"8\" y=\"8\" width=\"82\" height=\"70\" rx=\"6\" fill=\"#fff\" stroke=\"#cbd5e1\"/>");
    if (editor_mode == .selection) try w.bytes("<rect class=\"qip-tool-active\" x=\"12\" y=\"13\" width=\"74\" height=\"25\" rx=\"3\"/>") else try w.bytes("<rect class=\"qip-tool-active\" x=\"12\" y=\"42\" width=\"74\" height=\"25\" rx=\"3\"/>");
    try w.bytes("<text class=\"qip-ui\" x=\"20\" y=\"34\">V Select</text><text class=\"qip-ui\" x=\"20\" y=\"61\">P Pen</text>");
    for (paths[0..path_count], 0..) |p, pi| if (!p.deleted and p.editable and (edited_path == pi or selection.paths[pi] or hasSelectedAnchor(pi))) {
        const aa = anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count];
        for (aa, p.anchor_start..) |a, ai| {
            const q = p.transform.map(a.p);
            if (selection.anchors[ai] and dist2(a.p, a.hin) > 0.000001) {
                const h = p.transform.map(a.hin);
                try w.fmt("<path class=\"qip-line\" d=\"M{d:.2} {d:.2}L{d:.2} {d:.2}\"/><circle class=\"qip-hit\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"3\"/>", .{ q.x, q.y, h.x, h.y, h.x, h.y });
            }
            if (selection.anchors[ai] and dist2(a.p, a.hout) > 0.000001) {
                const h = p.transform.map(a.hout);
                try w.fmt("<path class=\"qip-line\" d=\"M{d:.2} {d:.2}L{d:.2} {d:.2}\"/><circle class=\"qip-hit\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"3\"/>", .{ q.x, q.y, h.x, h.y, h.x, h.y });
            }
            try w.fmt("<circle class=\"{s}\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"4\"/>", .{ if (selection.anchors[ai]) "qip-hit-selected" else "qip-hit", q.x, q.y });
        }
    };
    if (interaction_mode == .marquee) {
        const x = @min(marquee_start.x, marquee_end.x);
        const y = @min(marquee_start.y, marquee_end.y);
        try w.fmt("<rect class=\"qip-line\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" stroke-dasharray=\"4 3\"/>", .{ x, y, @abs(marquee_end.x - marquee_start.x), @abs(marquee_end.y - marquee_start.y) });
    }
    try w.bytes("</g>");
}
fn hasSelectedAnchor(path_index: usize) bool {
    const p = paths[path_index];
    for (selection.anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count]) |selected| if (selected) return true;
    return false;
}

fn singleSelectedPath() ?usize {
    var found: ?usize = null;
    for (paths[0..path_count], 0..) |p, pi| {
        if (p.deleted or (!selection.paths[pi] and !hasSelectedAnchor(pi))) continue;
        if (found != null) return null;
        found = pi;
    }
    return found;
}

const FLAG_DOWN: i32 = 1;
const FLAG_SHIFT: i32 = 1 << 2;
const FLAG_ALT: i32 = 1 << 4;
export fn key_event(key: i32, flags: i32) i32 {
    if (!updating) @trap();
    if (key == 0xffe9 or key == 0xffea) {
        alt_down = (flags & FLAG_DOWN) != 0;
        return 0;
    }
    if (key == 0xffe1 or key == 0xffe2) {
        shift_down = (flags & FLAG_DOWN) != 0;
        return 0;
    }
    if (key == 0x20) {
        space_down = (flags & FLAG_DOWN) != 0;
        return 0;
    }
    if ((flags & FLAG_DOWN) == 0) return 0;
    switch (key) {
        'p', 'P' => {
            editor_mode = .pen;
            clearSelection();
            edited_path = null;
            return 1;
        },
        'v', 'V' => {
            editor_mode = .selection;
            cancelDraft();
            return 1;
        },
        0xff1b => {
            cancelDraft();
            clearSelection();
            edited_path = null;
            return 1;
        },
        0xff0d => {
            finishDraft(false);
            return 1;
        },
        0xffff, 0xff08 => {
            deleteSelected();
            return 1;
        },
        0xff51 => {
            nudge(-1, 0, (flags & FLAG_SHIFT) != 0);
            return 1;
        },
        0xff53 => {
            nudge(1, 0, (flags & FLAG_SHIFT) != 0);
            return 1;
        },
        0xff52 => {
            nudge(0, -1, (flags & FLAG_SHIFT) != 0);
            return 1;
        },
        0xff54 => {
            nudge(0, 1, (flags & FLAG_SHIFT) != 0);
            return 1;
        },
        else => return 0,
    }
}
fn clearSelection() void {
    selection.clear();
}
fn cancelDraft() void {
    if (draft_path >= 0) {
        const pi: @TypeOf(path_count) = @intCast(draft_path);
        paths[pi].deleted = true;
        if (edited_path == pi) edited_path = null;
        draft_path = -1;
    }
    interaction_mode = .idle;
}
fn finishDraft(close: bool) void {
    if (draft_path < 0) return;
    const pi: usize = @intCast(draft_path);
    if (paths[pi].anchor_count < 2) {
        paths[pi].deleted = true;
        edited_path = null;
    } else if (close) {
        const last = @as(usize, paths[pi].anchor_start) + paths[pi].anchor_count - 1;
        anchors[last].closes = true;
    }
    if (!paths[pi].deleted) edited_path = pi;
    draft_path = -1;
    interaction_mode = .idle;
}
fn nudge(dx0: f64, dy0: f64, big: bool) void {
    const k: f64 = if (big) 10 else 1;
    for (paths[0..path_count], 0..) |*p, pi| {
        if (p.deleted or !p.editable) continue;
        const local_delta = p.inverse.map(.{ .x = dx0 * k, .y = dy0 * k });
        const origin = p.inverse.map(.{});
        const dx = local_delta.x - origin.x;
        const dy = local_delta.y - origin.y;
        var changed = false;
        for (anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count], p.anchor_start..) |*a, ai| if (selection.paths[pi] or selection.anchors[ai]) {
            a.p.x += dx;
            a.p.y += dy;
            a.hin.x += dx;
            a.hin.y += dy;
            a.hout.x += dx;
            a.hout.y += dy;
            changed = true;
        };
        if (changed) p.modified = true;
    }
}
fn deleteSelected() void {
    for (paths[0..path_count], 0..) |*p, pi| {
        if (selection.paths[pi]) {
            p.deleted = true;
            selection.paths[pi] = false;
            if (edited_path == pi) edited_path = null;
            continue;
        }
        if (!hasSelectedAnchor(pi)) continue;
        var kept: u16 = 0;
        const begin = @as(usize, p.anchor_start);
        var j: usize = 0;
        while (j < p.anchor_count) : (j += 1) {
            if (!selection.anchors[begin + j]) {
                anchors[begin + kept] = anchors[begin + j];
                selection.anchors[begin + kept] = false;
                kept += 1;
            }
        }
        @memset(selection.anchors[begin + kept .. begin + p.anchor_count], false);
        p.anchor_count = kept;
        if (kept < 2) {
            p.deleted = true;
            if (edited_path == pi) edited_path = null;
        } else p.modified = true;
    }
}

fn dist2(a: Point, b: Point) f64 {
    const x = a.x - b.x;
    const y = a.y - b.y;
    return x * x + y * y;
}
fn hitAnchor(doc: Point) ?struct { p: usize, a: usize, kind: u2 } {
    var pi = path_count;
    while (pi > 0) {
        pi -= 1;
        const p = paths[pi];
        if (!p.editable or p.deleted) continue;
        const aa = anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count];
        var j = aa.len;
        while (j > 0) {
            j -= 1;
            if (dist2(doc, p.transform.map(aa[j].p)) <= 49) return .{ .p = pi, .a = j, .kind = 0 };
            const ai = @as(usize, p.anchor_start) + j;
            if (selection.anchors[ai] and dist2(doc, p.transform.map(aa[j].hin)) <= 36) return .{ .p = pi, .a = j, .kind = 1 };
            if (selection.anchors[ai] and dist2(doc, p.transform.map(aa[j].hout)) <= 36) return .{ .p = pi, .a = j, .kind = 2 };
        }
    }
    return null;
}
fn segmentDistance(p: Point, a: Point, b: Point) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const l = dx * dx + dy * dy;
    if (l < 0.00001) return dist2(p, a);
    const t = @max(0, @min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l));
    return dist2(p, .{ .x = a.x + t * dx, .y = a.y + t * dy });
}
fn cubic(a: Point, c1: Point, c2: Point, b: Point, t: f64) Point {
    const u = 1 - t;
    return .{ .x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x, .y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y };
}
fn rayCrosses(p: Point, a: Point, b: Point) bool {
    if ((a.y > p.y) == (b.y > p.y)) return false;
    return p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
}
fn pathContains(path: Path, doc: Point) bool {
    if (!path.filled) return false;
    const aa = anchors[path.anchor_start .. @as(usize, path.anchor_start) + path.anchor_count];
    var inside = false;
    var subpath_first: usize = 0;
    var j: usize = 1;
    while (j < aa.len) : (j += 1) {
        if (aa[j].subpath_start) {
            subpath_first = j;
            continue;
        }
        var prev = path.transform.map(aa[j - 1].p);
        const steps: usize = if (aa[j].seg == .cubic) 24 else 1;
        var k: usize = 1;
        while (k <= steps) : (k += 1) {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
            const cur = if (aa[j].seg == .cubic) path.transform.map(cubic(aa[j - 1].p, aa[j - 1].hout, aa[j].hin, aa[j].p, t)) else path.transform.map(aa[j].p);
            if (rayCrosses(doc, prev, cur)) inside = !inside;
            prev = cur;
        }
        if (aa[j].closes) {
            const first_anchor = aa[subpath_first];
            const close_steps: usize = if (closingIsCubic(aa[j], first_anchor)) 24 else 1;
            var close_k: usize = 1;
            while (close_k <= close_steps) : (close_k += 1) {
                const t = @as(f64, @floatFromInt(close_k)) / @as(f64, @floatFromInt(close_steps));
                const cur = if (close_steps > 1) path.transform.map(cubic(aa[j].p, aa[j].hout, first_anchor.hin, first_anchor.p, t)) else path.transform.map(first_anchor.p);
                if (rayCrosses(doc, prev, cur)) inside = !inside;
                prev = cur;
            }
        }
    }
    return inside;
}
fn hitPath(doc: Point) ?usize {
    var pi = path_count;
    while (pi > 0) {
        pi -= 1;
        const p = paths[pi];
        if (!p.editable or p.deleted) continue;
        const aa = anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count];
        var subpath_first: usize = 0;
        var j: usize = 1;
        while (j < aa.len) : (j += 1) {
            if (aa[j].subpath_start) {
                subpath_first = j;
                continue;
            }
            var prev = p.transform.map(aa[j - 1].p);
            var k: usize = 1;
            const steps: usize = if (aa[j].seg == .cubic) 24 else 1;
            while (k <= steps) : (k += 1) {
                const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
                const cur = if (aa[j].seg == .cubic) p.transform.map(cubic(aa[j - 1].p, aa[j - 1].hout, aa[j].hin, aa[j].p, t)) else p.transform.map(aa[j].p);
                if (segmentDistance(doc, prev, cur) <= 36) return pi;
                prev = cur;
            }
            if (aa[j].closes) {
                const first_anchor = aa[subpath_first];
                const close_steps: usize = if (closingIsCubic(aa[j], first_anchor)) 24 else 1;
                var close_k: usize = 1;
                while (close_k <= close_steps) : (close_k += 1) {
                    const t = @as(f64, @floatFromInt(close_k)) / @as(f64, @floatFromInt(close_steps));
                    const cur = if (close_steps > 1) p.transform.map(cubic(aa[j].p, aa[j].hout, first_anchor.hin, first_anchor.p, t)) else p.transform.map(first_anchor.p);
                    if (segmentDistance(doc, prev, cur) <= 36) return pi;
                    prev = cur;
                }
            }
        }
        if (pathContains(p, doc)) return pi;
    }
    return null;
}

export fn pointer_event(mask: i32, x: i32, y: i32) i32 {
    if (!updating) @trap();
    const down = (mask & 1) != 0;
    const doc = Point{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    var changed = false;
    if (down and !primary_down) {
        if (y >= 8 and y <= 78 and x >= 8 and x <= 90) {
            editor_mode = if (y >= 43) .pen else .selection;
            clearSelection();
            edited_path = null;
            changed = true;
        } else if (editor_mode == .pen) {
            changed = penPress(doc);
        } else {
            changed = selectPress(doc);
        }
    } else if (down and primary_down) {
        changed = drag(doc);
    } else if (!down and primary_down) {
        changed = release(doc);
    }
    primary_down = down;
    last_pointer = doc;
    return if (changed) 1 else 0;
}
fn penPress(doc: Point) bool {
    if (draft_path >= 0) {
        const pi: usize = @intCast(draft_path);
        const p = &paths[pi];
        if (p.anchor_count >= 2 and dist2(doc, p.transform.map(anchors[p.anchor_start].p)) <= 64) {
            const first = @as(usize, p.anchor_start);
            const last = first + p.anchor_count - 1;
            @memset(selection.anchors[first .. last + 1], false);
            selection.anchors[first] = true;
            anchors[last].closes = true;
            edited_path = pi;
            interaction_mode = .drag_pen_close;
            drag_path = @intCast(pi);
            drag_anchor = 0;
            return true;
        }
    }
    if (draft_path < 0) {
        if (path_count >= MAX_PATHS) return false;
        paths[path_count] = .{ .anchor_start = @intCast(anchor_count), .editable = true, .modified = true, .is_new = true };
        draft_path = @intCast(path_count);
        edited_path = path_count;
        path_count += 1;
    }
    if (anchor_count >= MAX_ANCHORS) return false;
    const pi: usize = @intCast(draft_path);
    const local = paths[pi].inverse.map(doc);
    @memset(selection.anchors[paths[pi].anchor_start .. @as(usize, paths[pi].anchor_start) + paths[pi].anchor_count], false);
    var segment: Seg = .move;
    if (paths[pi].anchor_count != 0) {
        const previous = anchors[@as(usize, paths[pi].anchor_start) + paths[pi].anchor_count - 1];
        segment = if (dist2(previous.p, previous.hout) > 0.000001) .cubic else .line;
    }
    const new_anchor = anchor_count;
    appendAnchor(.{ .p = local, .hin = local, .hout = local, .seg = segment, .subpath_start = paths[pi].anchor_count == 0 }) catch return false;
    selection.anchors[new_anchor] = true;
    paths[pi].anchor_count += 1;
    interaction_mode = .drag_pen_handle;
    drag_path = @intCast(pi);
    drag_anchor = @intCast(paths[pi].anchor_count - 1);
    return true;
}
fn selectPress(doc: Point) bool {
    if (hitAnchor(doc)) |h| {
        edited_path = h.p;
        const ai = @as(usize, paths[h.p].anchor_start) + h.a;
        if (h.kind == 0) {
            if (shift_down) {
                selection.anchors[ai] = !selection.anchors[ai];
            } else if (!selection.anchors[ai]) {
                clearSelection();
                selection.anchors[ai] = true;
            }
            selection.paths[h.p] = false;
        }
        drag_path = @intCast(h.p);
        drag_anchor = @intCast(h.a);
        interaction_mode = switch (h.kind) {
            0 => if (selection.anchors[ai]) .drag_anchor else .idle,
            1 => .drag_in_handle,
            2 => .drag_out_handle,
            else => .idle,
        };
        return true;
    }
    if (hitPath(doc)) |pi| {
        edited_path = pi;
        if (shift_down) {
            selection.paths[pi] = !selection.paths[pi];
        } else if (!selection.paths[pi]) {
            clearSelection();
            selection.paths[pi] = true;
        }
        drag_path = @intCast(pi);
        interaction_mode = .drag_path;
        return true;
    }
    if (!shift_down) {
        clearSelection();
        edited_path = null;
    }
    interaction_mode = .marquee;
    marquee_start = doc;
    marquee_end = doc;
    return true;
}
fn drag(doc: Point) bool {
    if (interaction_mode == .marquee) {
        marquee_end = doc;
        return true;
    }
    if (drag_path < 0) return false;
    const pi: usize = @intCast(drag_path);
    const p = &paths[pi];
    if (interaction_mode == .drag_anchor) {
        var changed = false;
        for (paths[0..path_count], 0..) |*selected_path, selected_pi| {
            if (selected_path.deleted or !selected_path.editable) continue;
            const selected_local = selected_path.inverse.map(doc);
            const selected_prev = selected_path.inverse.map(last_pointer);
            const selected_dx = selected_local.x - selected_prev.x;
            const selected_dy = selected_local.y - selected_prev.y;
            for (anchors[selected_path.anchor_start .. @as(usize, selected_path.anchor_start) + selected_path.anchor_count], selected_path.anchor_start..) |*a, ai| {
                if (!selection.anchors[ai]) continue;
                a.p.x += selected_dx;
                a.p.y += selected_dy;
                a.hin.x += selected_dx;
                a.hin.y += selected_dy;
                a.hout.x += selected_dx;
                a.hout.y += selected_dy;
                changed = true;
            }
            if (changed and hasSelectedAnchor(selected_pi)) selected_path.modified = true;
        }
        return changed;
    }
    const local = p.inverse.map(doc);
    const prev = p.inverse.map(last_pointer);
    const dx = local.x - prev.x;
    const dy = local.y - prev.y;
    if (interaction_mode == .drag_path) {
        for (anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count]) |*a| {
            a.p.x += dx;
            a.p.y += dy;
            a.hin.x += dx;
            a.hin.y += dy;
            a.hout.x += dx;
            a.hout.y += dy;
        }
    } else if (drag_anchor >= 0) {
        const a = &anchors[@as(usize, p.anchor_start) + @as(usize, @intCast(drag_anchor))];
        if (space_down and (interaction_mode == .drag_pen_handle or interaction_mode == .drag_pen_close)) {
            a.p.x += dx;
            a.p.y += dy;
            a.hin.x += dx;
            a.hin.y += dy;
            a.hout.x += dx;
            a.hout.y += dy;
        } else if (interaction_mode == .drag_in_handle) {
            a.hin = local;
            if (!alt_down) a.hout = .{ .x = 2 * a.p.x - local.x, .y = 2 * a.p.y - local.y };
        } else if (interaction_mode == .drag_out_handle or interaction_mode == .drag_pen_handle or interaction_mode == .drag_pen_close) {
            a.hout = local;
            if (!alt_down) a.hin = .{ .x = 2 * a.p.x - local.x, .y = 2 * a.p.y - local.y };
            if (interaction_mode == .drag_pen_handle and drag_anchor > 0) a.seg = .cubic;
        } else {
            return false;
        }
    }
    p.modified = true;
    return true;
}
fn release(doc: Point) bool {
    if (interaction_mode == .drag_pen_close) {
        finishDraft(true);
        editor_mode = .selection;
        drag_path = -1;
        drag_anchor = -1;
        return true;
    }
    if (interaction_mode == .marquee) {
        marquee_end = doc;
        for (paths[0..path_count], 0..) |*p, pi| if (p.editable and !p.deleted) for (anchors[p.anchor_start .. @as(usize, p.anchor_start) + p.anchor_count], p.anchor_start..) |*a, ai| {
            const q = p.transform.map(a.p);
            if (q.x >= @min(marquee_start.x, doc.x) and q.x <= @max(marquee_start.x, doc.x) and q.y >= @min(marquee_start.y, doc.y) and q.y <= @max(marquee_start.y, doc.y)) {
                selection.anchors[ai] = true;
                selection.paths[pi] = false;
            }
        };
        edited_path = singleSelectedPath();
    }
    interaction_mode = .idle;
    drag_path = -1;
    drag_anchor = -1;
    return true;
}

test "empty input creates an SVG editor scene" {
    initialized = false;
    const r = render(0);
    try std.testing.expectEqual(@as(u64, 0), r >> 63);
    const n: usize = @intCast(r & 0xffffffff);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..n], "viewBox=\"0 0 800 600\"") != null);
}
test "relative cubic data normalizes while unrelated bytes survive" {
    initialized = false;
    const s = "<svg xmlns=\"http://www.w3.org/2000/svg\"><!--keep--><path data-x=\"yes\" d=\"m 1 2 c 3 4 5 6 7 8 s 9 10 11 12\"/></svg>";
    @memcpy(input_buf[0..s.len], s);
    const r = render(s.len);
    try std.testing.expectEqual(@as(u64, 0), r >> 63);
    paths[0].modified = true;
    const rr = render(0);
    const n: usize = @intCast(rr & 0xffffffff);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..n], "<!--keep-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..n], "M1 2 C4 6 6 8 8 10 C10 12 17 20 19 22") != null);
}
test "malformed XML is recoverable" {
    initialized = false;
    const s = "<svg><g></svg>";
    @memcpy(input_buf[0..s.len], s);
    try std.testing.expect((render(s.len) >> 63) == 1);
}
