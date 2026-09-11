//! Bounded reader for static SFNT fonts with TrueType `glyf` outlines.
//!
//! The reader extracts Unicode mappings, horizontal metrics, and quadratic
//! outlines. It does not execute hinting programs, apply OpenType shaping, or
//! interpolate variable-font outlines. Compound glyphs must use XY offsets;
//! point-to-point component attachment is rejected.

const std = @import("std");

pub const MAX_POINTS: usize = 8_192;
pub const MAX_CONTOURS: usize = 1_024;
const MAX_COMPONENT_STACK: usize = 128;
const MAX_COMPONENTS_PER_GLYPH: usize = 64;
const MAX_COMPOSITE_DEPTH: u8 = 16;

pub const Error = error{
    InvalidTtf,
    UnsupportedOutlineFormat,
    UnsupportedCmap,
    UnsupportedCompoundAttachment,
    TooManyPoints,
    TooManyContours,
    TooManyComponents,
    CompositeTooDeep,
    OutputOverflow,
};

pub const Point = struct {
    x: f64,
    y: f64,
    on_curve: bool,
};

pub const Scratch = struct {
    points: [MAX_POINTS]Point = undefined,
    contour_ends: [MAX_CONTOURS]u16 = undefined,
    flags: [MAX_POINTS]u8 = undefined,
    point_count: usize = 0,
    contour_count: usize = 0,

    fn reset(self: *Scratch) void {
        self.point_count = 0;
        self.contour_count = 0;
    }
};

pub const GlyphMetrics = struct {
    glyph_id: u16,
    advance_x: u16,
    left_side_bearing: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

const Table = struct {
    bytes: []const u8,
};

const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,

    fn apply(self: Transform, x: f64, y: f64) struct { x: f64, y: f64 } {
        return .{
            .x = self.a * x + self.c * y + self.tx,
            .y = self.b * x + self.d * y + self.ty,
        };
    }

    fn then(parent: Transform, child: Transform) Transform {
        return .{
            .a = parent.a * child.a + parent.c * child.b,
            .b = parent.b * child.a + parent.d * child.b,
            .c = parent.a * child.c + parent.c * child.d,
            .d = parent.b * child.c + parent.d * child.d,
            .tx = parent.a * child.tx + parent.c * child.ty + parent.tx,
            .ty = parent.b * child.tx + parent.d * child.ty + parent.ty,
        };
    }
};

const StackEntry = struct {
    glyph_id: u16,
    transform: Transform,
    depth: u8,
};

pub const Font = struct {
    cmap: []const u8,
    cmap_format: u16,
    glyf: []const u8,
    loca: []const u8,
    hmtx: []const u8,
    num_glyphs: u16,
    num_h_metrics: u16,
    loca_format: i16,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,

    pub fn init(bytes: []const u8) Error!Font {
        if (bytes.len < 12) return error.InvalidTtf;
        const signature = try beU32(bytes, 0);
        if (signature != 0x00010000 and signature != 0x74727565) return error.UnsupportedOutlineFormat;

        const head = (try findTable(bytes, "head")) orelse return error.InvalidTtf;
        const maxp = (try findTable(bytes, "maxp")) orelse return error.InvalidTtf;
        const hhea = (try findTable(bytes, "hhea")) orelse return error.InvalidTtf;
        const hmtx = (try findTable(bytes, "hmtx")) orelse return error.InvalidTtf;
        const loca = (try findTable(bytes, "loca")) orelse return error.InvalidTtf;
        const glyf = (try findTable(bytes, "glyf")) orelse return error.UnsupportedOutlineFormat;
        const cmap_table = (try findTable(bytes, "cmap")) orelse return error.InvalidTtf;

        if (head.bytes.len < 54 or maxp.bytes.len < 6 or hhea.bytes.len < 36) return error.InvalidTtf;
        const num_glyphs = try beU16(maxp.bytes, 4);
        const num_h_metrics = try beU16(hhea.bytes, 34);
        if (num_glyphs == 0 or num_h_metrics == 0 or num_h_metrics > num_glyphs) return error.InvalidTtf;
        const units_per_em = try beU16(head.bytes, 18);
        if (units_per_em == 0) return error.InvalidTtf;
        const loca_format = try beI16(head.bytes, 50);
        if (loca_format != 0 and loca_format != 1) return error.InvalidTtf;
        const loca_entries: usize = @as(usize, num_glyphs) + 1;
        const loca_bytes = loca_entries * (if (loca_format == 0) @as(usize, 2) else 4);
        if (loca.bytes.len < loca_bytes) return error.InvalidTtf;
        if (hmtx.bytes.len < @as(usize, num_h_metrics) * 4 + @as(usize, num_glyphs - num_h_metrics) * 2) return error.InvalidTtf;

        const selected_cmap = try selectCmap(cmap_table.bytes);
        return .{
            .cmap = selected_cmap.bytes,
            .cmap_format = selected_cmap.format,
            .glyf = glyf.bytes,
            .loca = loca.bytes,
            .hmtx = hmtx.bytes,
            .num_glyphs = num_glyphs,
            .num_h_metrics = num_h_metrics,
            .loca_format = loca_format,
            .units_per_em = units_per_em,
            .ascender = try beI16(hhea.bytes, 4),
            .descender = try beI16(hhea.bytes, 6),
            .line_gap = try beI16(hhea.bytes, 8),
        };
    }

    pub fn glyphIndex(self: *const Font, codepoint: u32) Error!?u16 {
        return switch (self.cmap_format) {
            4 => self.glyphIndexFormat4(codepoint),
            12 => self.glyphIndexFormat12(codepoint),
            else => error.UnsupportedCmap,
        };
    }

    pub fn metrics(self: *const Font, glyph_id: u16) Error!GlyphMetrics {
        if (glyph_id >= self.num_glyphs) return error.InvalidTtf;
        const glyph = try self.glyphBytes(glyph_id);
        var x_min: i16 = 0;
        var y_min: i16 = 0;
        var x_max: i16 = 0;
        var y_max: i16 = 0;
        if (glyph.len != 0) {
            if (glyph.len < 10) return error.InvalidTtf;
            x_min = try beI16(glyph, 2);
            y_min = try beI16(glyph, 4);
            x_max = try beI16(glyph, 6);
            y_max = try beI16(glyph, 8);
        }

        var advance: u16 = undefined;
        var lsb: i16 = undefined;
        if (glyph_id < self.num_h_metrics) {
            const offset = @as(usize, glyph_id) * 4;
            advance = try beU16(self.hmtx, offset);
            lsb = try beI16(self.hmtx, offset + 2);
        } else {
            advance = try beU16(self.hmtx, (@as(usize, self.num_h_metrics) - 1) * 4);
            const offset = @as(usize, self.num_h_metrics) * 4 + @as(usize, glyph_id - self.num_h_metrics) * 2;
            lsb = try beI16(self.hmtx, offset);
        }
        return .{
            .glyph_id = glyph_id,
            .advance_x = advance,
            .left_side_bearing = lsb,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
        };
    }

    pub fn writeGlyphPath(self: *const Font, glyph_id: u16, scratch: *Scratch, writer: anytype) Error!void {
        try self.loadOutline(glyph_id, scratch);
        var contour_start: usize = 0;
        var contour_index: usize = 0;
        while (contour_index < scratch.contour_count) : (contour_index += 1) {
            const contour_end = @as(usize, scratch.contour_ends[contour_index]);
            if (contour_end < contour_start or contour_end >= scratch.point_count) return error.InvalidTtf;
            try writeContour(scratch.points[contour_start .. contour_end + 1], writer);
            contour_start = contour_end + 1;
        }
        if (contour_start != scratch.point_count) return error.InvalidTtf;
    }

    fn glyphIndexFormat12(self: *const Font, codepoint: u32) Error!?u16 {
        if (self.cmap.len < 16) return error.InvalidTtf;
        const group_count = try beU32(self.cmap, 12);
        if (@as(u64, group_count) * 12 + 16 > self.cmap.len) return error.InvalidTtf;
        var low: u32 = 0;
        var high = group_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const offset = 16 + @as(usize, mid) * 12;
            const start = try beU32(self.cmap, offset);
            const end = try beU32(self.cmap, offset + 4);
            if (codepoint < start) {
                high = mid;
            } else if (codepoint > end) {
                low = mid + 1;
            } else {
                const start_glyph = try beU32(self.cmap, offset + 8);
                const glyph_delta = codepoint - start;
                if (glyph_delta > std.math.maxInt(u32) - start_glyph) return error.InvalidTtf;
                const glyph = start_glyph + glyph_delta;
                if (glyph == 0 or glyph >= self.num_glyphs) return null;
                if (glyph > std.math.maxInt(u16)) return error.InvalidTtf;
                return @intCast(glyph);
            }
        }
        return null;
    }

    fn glyphIndexFormat4(self: *const Font, codepoint: u32) Error!?u16 {
        if (codepoint > 0xffff or self.cmap.len < 16) return null;
        const seg_count_x2 = try beU16(self.cmap, 6);
        if (seg_count_x2 == 0 or (seg_count_x2 & 1) != 0) return error.InvalidTtf;
        const seg_count: usize = seg_count_x2 / 2;
        const end_codes = 14;
        const start_codes = end_codes + seg_count * 2 + 2;
        const deltas = start_codes + seg_count * 2;
        const range_offsets = deltas + seg_count * 2;
        if (range_offsets + seg_count * 2 > self.cmap.len) return error.InvalidTtf;

        var segment: usize = 0;
        while (segment < seg_count) : (segment += 1) {
            const end = try beU16(self.cmap, end_codes + segment * 2);
            if (codepoint > end) continue;
            const start = try beU16(self.cmap, start_codes + segment * 2);
            if (codepoint < start) return null;
            const delta = try beI16(self.cmap, deltas + segment * 2);
            const range = try beU16(self.cmap, range_offsets + segment * 2);
            var glyph: u16 = 0;
            if (range == 0) {
                glyph = @truncate(codepoint +% @as(u32, @bitCast(@as(i32, delta))));
            } else {
                const word_offset = range_offsets + segment * 2;
                const glyph_offset = word_offset + @as(usize, range) + @as(usize, @intCast(codepoint - start)) * 2;
                glyph = try beU16(self.cmap, glyph_offset);
                if (glyph != 0) glyph +%= @bitCast(delta);
            }
            if (glyph == 0 or glyph >= self.num_glyphs) return null;
            return glyph;
        }
        return null;
    }

    fn glyphBytes(self: *const Font, glyph_id: u16) Error![]const u8 {
        const glyph_index: usize = glyph_id;
        const start = try self.locaOffset(glyph_index);
        const end = try self.locaOffset(glyph_index + 1);
        if (end < start or end > self.glyf.len) return error.InvalidTtf;
        return self.glyf[start..end];
    }

    fn locaOffset(self: *const Font, glyph_id: usize) Error!usize {
        if (glyph_id > self.num_glyphs) return error.InvalidTtf;
        if (self.loca_format == 0) return @as(usize, try beU16(self.loca, glyph_id * 2)) * 2;
        return @intCast(try beU32(self.loca, glyph_id * 4));
    }

    fn loadOutline(self: *const Font, glyph_id: u16, scratch: *Scratch) Error!void {
        scratch.reset();
        var stack: [MAX_COMPONENT_STACK]StackEntry = undefined;
        var stack_len: usize = 1;
        stack[0] = .{ .glyph_id = glyph_id, .transform = .{}, .depth = 0 };

        while (stack_len > 0) {
            stack_len -= 1;
            const entry = stack[stack_len];
            const glyph = try self.glyphBytes(entry.glyph_id);
            if (glyph.len == 0) continue;
            if (glyph.len < 10) return error.InvalidTtf;
            const contour_count = try beI16(glyph, 0);
            if (contour_count >= 0) {
                try loadSimpleGlyph(glyph, @intCast(contour_count), entry.transform, scratch);
            } else {
                if (entry.depth >= MAX_COMPOSITE_DEPTH) return error.CompositeTooDeep;
                var components: [MAX_COMPONENTS_PER_GLYPH]StackEntry = undefined;
                const component_count = try parseComponents(glyph, entry, &components);
                if (component_count > stack.len - stack_len) return error.TooManyComponents;
                var index = component_count;
                while (index > 0) {
                    index -= 1;
                    stack[stack_len] = components[index];
                    stack_len += 1;
                }
            }
        }
    }
};

const SelectedCmap = struct {
    bytes: []const u8,
    format: u16,
};

fn selectCmap(cmap: []const u8) Error!SelectedCmap {
    if (cmap.len < 4) return error.InvalidTtf;
    const count = try beU16(cmap, 2);
    if (4 + @as(usize, count) * 8 > cmap.len) return error.InvalidTtf;
    var best: ?SelectedCmap = null;
    var best_score: u8 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = 4 + index * 8;
        const platform = try beU16(cmap, record);
        const encoding = try beU16(cmap, record + 2);
        const offset: usize = @intCast(try beU32(cmap, record + 4));
        if (offset > cmap.len or 2 > cmap.len - offset) return error.InvalidTtf;
        const format = try beU16(cmap, offset);
        var length: usize = 0;
        var score: u8 = 0;
        if (format == 12) {
            if (16 > cmap.len - offset) return error.InvalidTtf;
            length = @intCast(try beU32(cmap, offset + 4));
            score = if (platform == 3 and encoding == 10) 4 else if (platform == 0) 3 else 2;
        } else if (format == 4) {
            if (8 > cmap.len - offset) return error.InvalidTtf;
            length = try beU16(cmap, offset + 2);
            score = if (platform == 3 and encoding == 1) 2 else if (platform == 0) 1 else 0;
        } else continue;
        if (length < 4 or length > cmap.len - offset) return error.InvalidTtf;
        if (score > best_score) {
            best = .{ .bytes = cmap[offset .. offset + length], .format = format };
            best_score = score;
        }
    }
    return best orelse error.UnsupportedCmap;
}

fn findTable(bytes: []const u8, tag: *const [4]u8) Error!?Table {
    const count = try beU16(bytes, 4);
    if (12 + @as(usize, count) * 16 > bytes.len) return error.InvalidTtf;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = 12 + index * 16;
        if (!std.mem.eql(u8, bytes[record .. record + 4], tag)) continue;
        const offset: usize = @intCast(try beU32(bytes, record + 8));
        const length: usize = @intCast(try beU32(bytes, record + 12));
        if (offset > bytes.len or length > bytes.len - offset) return error.InvalidTtf;
        return .{ .bytes = bytes[offset .. offset + length] };
    }
    return null;
}

fn loadSimpleGlyph(glyph: []const u8, contour_count: usize, transform: Transform, scratch: *Scratch) Error!void {
    if (contour_count == 0) return;
    if (contour_count > MAX_CONTOURS - scratch.contour_count) return error.TooManyContours;
    const ends_offset: usize = 10;
    if (ends_offset + contour_count * 2 + 2 > glyph.len) return error.InvalidTtf;
    const last_end = try beU16(glyph, ends_offset + (contour_count - 1) * 2);
    const point_count: usize = @as(usize, last_end) + 1;
    if (point_count > MAX_POINTS - scratch.point_count) return error.TooManyPoints;
    var contour: usize = 0;
    var prior_end: i32 = -1;
    while (contour < contour_count) : (contour += 1) {
        const end = try beU16(glyph, ends_offset + contour * 2);
        if (@as(i32, end) <= prior_end or end >= point_count) return error.InvalidTtf;
        scratch.contour_ends[scratch.contour_count + contour] = @intCast(scratch.point_count + end);
        prior_end = end;
    }

    var offset = ends_offset + contour_count * 2;
    const instruction_length = try beU16(glyph, offset);
    offset += 2;
    if (instruction_length > glyph.len - offset) return error.InvalidTtf;
    offset += instruction_length;

    var flag_count: usize = 0;
    while (flag_count < point_count) {
        if (offset >= glyph.len) return error.InvalidTtf;
        const flag = glyph[offset];
        offset += 1;
        var repeat: usize = 1;
        if ((flag & 0x08) != 0) {
            if (offset >= glyph.len) return error.InvalidTtf;
            repeat += glyph[offset];
            offset += 1;
        }
        if (repeat > point_count - flag_count) return error.InvalidTtf;
        var repeated: usize = 0;
        while (repeated < repeat) : (repeated += 1) scratch.flags[flag_count + repeated] = flag;
        flag_count += repeat;
    }

    const base = scratch.point_count;
    var x: i32 = 0;
    var point_index: usize = 0;
    while (point_index < point_count) : (point_index += 1) {
        const flag = scratch.flags[point_index];
        if ((flag & 0x02) != 0) {
            if (offset >= glyph.len) return error.InvalidTtf;
            const delta: i32 = glyph[offset];
            offset += 1;
            x += if ((flag & 0x10) != 0) delta else -delta;
        } else if ((flag & 0x10) == 0) {
            x += try readI16Advance(glyph, &offset);
        }
        scratch.points[base + point_index].x = @floatFromInt(x);
        scratch.points[base + point_index].on_curve = (flag & 0x01) != 0;
    }

    var y: i32 = 0;
    point_index = 0;
    while (point_index < point_count) : (point_index += 1) {
        const flag = scratch.flags[point_index];
        if ((flag & 0x04) != 0) {
            if (offset >= glyph.len) return error.InvalidTtf;
            const delta: i32 = glyph[offset];
            offset += 1;
            y += if ((flag & 0x20) != 0) delta else -delta;
        } else if ((flag & 0x20) == 0) {
            y += try readI16Advance(glyph, &offset);
        }
        const transformed = transform.apply(scratch.points[base + point_index].x, @floatFromInt(y));
        scratch.points[base + point_index].x = transformed.x;
        scratch.points[base + point_index].y = transformed.y;
    }
    scratch.point_count += point_count;
    scratch.contour_count += contour_count;
}

fn parseComponents(glyph: []const u8, parent: StackEntry, components: *[MAX_COMPONENTS_PER_GLYPH]StackEntry) Error!usize {
    var offset: usize = 10;
    var count: usize = 0;
    var more = true;
    while (more) {
        if (count >= components.len or offset + 4 > glyph.len) return error.TooManyComponents;
        const flags = try beU16(glyph, offset);
        const glyph_id = try beU16(glyph, offset + 2);
        offset += 4;
        const words = (flags & 0x0001) != 0;
        if ((flags & 0x0002) == 0) return error.UnsupportedCompoundAttachment;
        var arg1: i16 = undefined;
        var arg2: i16 = undefined;
        if (words) {
            arg1 = try beI16(glyph, offset);
            arg2 = try beI16(glyph, offset + 2);
            offset += 4;
        } else {
            if (offset + 2 > glyph.len) return error.InvalidTtf;
            arg1 = @as(i8, @bitCast(glyph[offset]));
            arg2 = @as(i8, @bitCast(glyph[offset + 1]));
            offset += 2;
        }
        var local = Transform{ .tx = @floatFromInt(arg1), .ty = @floatFromInt(arg2) };
        if ((flags & 0x0008) != 0) {
            const scale = try readF2Dot14(glyph, &offset);
            local.a = scale;
            local.d = scale;
        } else if ((flags & 0x0040) != 0) {
            local.a = try readF2Dot14(glyph, &offset);
            local.d = try readF2Dot14(glyph, &offset);
        } else if ((flags & 0x0080) != 0) {
            local.a = try readF2Dot14(glyph, &offset);
            local.b = try readF2Dot14(glyph, &offset);
            local.c = try readF2Dot14(glyph, &offset);
            local.d = try readF2Dot14(glyph, &offset);
        }
        components[count] = .{
            .glyph_id = glyph_id,
            .transform = parent.transform.then(local),
            .depth = parent.depth + 1,
        };
        count += 1;
        more = (flags & 0x0020) != 0;
    }
    return count;
}

fn writeContour(points: []const Point, writer: anytype) Error!void {
    if (points.len == 0) return;
    const first = points[0];
    const last = points[points.len - 1];
    var start: Point = undefined;
    var position: usize = 0;
    var remaining: usize = undefined;
    if (first.on_curve) {
        start = first;
        position = 1 % points.len;
        remaining = points.len - 1;
    } else if (last.on_curve) {
        start = last;
        remaining = points.len - 1;
    } else {
        start = midpoint(last, first);
        remaining = points.len;
    }
    try writer.moveTo(start.x, -start.y);

    var consumed: usize = 0;
    while (consumed < remaining) {
        const point = points[position % points.len];
        if (point.on_curve) {
            try writer.lineTo(point.x, -point.y);
            position += 1;
            consumed += 1;
            continue;
        }
        const next = points[(position + 1) % points.len];
        if (next.on_curve) {
            try writer.quadTo(point.x, -point.y, next.x, -next.y);
            position += 2;
            consumed += if (consumed + 1 < remaining) 2 else 1;
        } else {
            const implicit = midpoint(point, next);
            try writer.quadTo(point.x, -point.y, implicit.x, -implicit.y);
            position += 1;
            consumed += 1;
        }
    }
    try writer.close();
}

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2, .on_curve = true };
}

fn readI16Advance(bytes: []const u8, offset: *usize) Error!i16 {
    const value = try beI16(bytes, offset.*);
    offset.* += 2;
    return value;
}

fn readF2Dot14(bytes: []const u8, offset: *usize) Error!f64 {
    const value = try readI16Advance(bytes, offset);
    return @as(f64, @floatFromInt(value)) / 16384.0;
}

fn beU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or 2 > bytes.len - offset) return error.InvalidTtf;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn beI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try beU16(bytes, offset));
}

fn beU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 4 > bytes.len - offset) return error.InvalidTtf;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

test "rejects non-SFNT input" {
    try std.testing.expectError(error.InvalidTtf, Font.init("not a font"));
}
