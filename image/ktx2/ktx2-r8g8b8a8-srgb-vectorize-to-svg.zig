//! Traces a bounded, reduced-colour canonical KTX2 image into grid-aligned SVG paths.
//!
//! This deliberately targets flat artwork. It reduces opaque pixels to at most eight
//! representative colours, joins 4-connected pixels into regions, and traces each
//! region's pixel-edge contours. The result uses only M, H, V, and Z commands so it
//! round-trips through QIP's SVG rasterizer. It does not attempt to trace photos or
//! smooth anti-aliased artwork.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const MAX_PIXELS: usize = 8_000_000;
const INPUT_CAP: usize = ktx.HEADER_SIZE + MAX_PIXELS * 4;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const BUCKETS: usize = 32 * 32 * 32;
const MAX_COLORS: usize = 8;
const MAX_PATH_SEGMENTS: usize = 4_096;
const DEFAULT_COLORS: u32 = 8;
const DEFAULT_ALPHA_THRESHOLD: u32 = 128;
const INPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const transparent: u8 = 0xff;
const component: u8 = 0xfe;
const done: u8 = 0xfd;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var labels: [MAX_PIXELS]u8 = undefined;
var edge_marks: [MAX_PIXELS]u8 = undefined;
var queue: [MAX_PIXELS]u32 = undefined;
var counts: [BUCKETS]u32 = undefined;
var sum_r: [BUCKETS]u32 = undefined;
var sum_g: [BUCKETS]u32 = undefined;
var sum_b: [BUCKETS]u32 = undefined;
var color_count: u32 = DEFAULT_COLORS;
var alpha_threshold: u32 = DEFAULT_ALPHA_THRESHOLD;

const Color = struct {
    bucket: usize,
    count: u32,
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

const Direction = enum(u2) { east, south, west, north };

const Edge = struct {
    pixel: usize,
    direction: Direction,
};

const Point = struct { x: usize, y: usize };

const Writer = struct {
    index: usize = 0,

    fn append(self: *Writer, bytes: []const u8) !void {
        if (self.index + bytes.len > OUTPUT_CAP) return error.OutputOverflow;
        @memcpy(output_buf[self.index .. self.index + bytes.len], bytes);
        self.index += bytes.len;
    }

    fn byte(self: *Writer, value: u8) !void {
        if (self.index == OUTPUT_CAP) return error.OutputOverflow;
        output_buf[self.index] = value;
        self.index += 1;
    }

    fn integer(self: *Writer, value: usize) !void {
        var buf: [20]u8 = undefined;
        try self.append(try std.fmt.bufPrint(&buf, "{d}", .{value}));
    }

    fn hexByte(self: *Writer, value: u8) !void {
        const hex = "0123456789abcdef";
        try self.byte(hex[value >> 4]);
        try self.byte(hex[value & 0x0f]);
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn uniform_set_colors(value: u32) u32 {
    color_count = std.math.clamp(value, 1, @as(u32, MAX_COLORS));
    return color_count;
}

export fn uniform_set_alpha_threshold(value: u32) u32 {
    alpha_threshold = std.math.clamp(value, 1, 255);
    return alpha_threshold;
}

fn resetUniforms() void {
    color_count = DEFAULT_COLORS;
    alpha_threshold = DEFAULT_ALPHA_THRESHOLD;
}

fn bucketIndex(r: u8, g: u8, b: u8) usize {
    return (@as(usize, r >> 3) << 10) | (@as(usize, g >> 3) << 5) | @as(usize, b >> 3);
}

fn insertTop(top: []Color, candidate: Color) void {
    if (candidate.count == 0) return;
    var position: usize = 0;
    while (position < top.len and top[position].count >= candidate.count) : (position += 1) {}
    if (position == top.len) return;
    var index = top.len - 1;
    while (index > position) : (index -= 1) top[index] = top[index - 1];
    top[position] = candidate;
}

fn colorDistanceSquared(pixel: []const u8, color: Color) u32 {
    const dr: i32 = @as(i32, pixel[0]) - @as(i32, color.r);
    const dg: i32 = @as(i32, pixel[1]) - @as(i32, color.g);
    const db: i32 = @as(i32, pixel[2]) - @as(i32, color.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

fn chooseColors(image: ktx.Image, palette: *[MAX_COLORS]Color) usize {
    @memset(&counts, 0);
    @memset(&sum_r, 0);
    @memset(&sum_g, 0);
    @memset(&sum_b, 0);

    for (image.pixels, 0..) |_, offset| {
        if (offset % 4 != 0 or image.pixels[offset + 3] < alpha_threshold) continue;
        const bucket = bucketIndex(image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2]);
        counts[bucket] += 1;
        sum_r[bucket] += image.pixels[offset];
        sum_g[bucket] += image.pixels[offset + 1];
        sum_b[bucket] += image.pixels[offset + 2];
    }

    palette.* = [_]Color{.{ .bucket = 0, .count = 0 }} ** MAX_COLORS;
    for (counts, 0..) |count, bucket| insertTop(palette[0..], .{ .bucket = bucket, .count = count });

    const selected: usize = @intCast(color_count);
    var palette_len: usize = 0;
    while (palette_len < selected and palette[palette_len].count != 0) : (palette_len += 1) {
        const count = palette[palette_len].count;
        palette[palette_len].r = @intCast((sum_r[palette[palette_len].bucket] + count / 2) / count);
        palette[palette_len].g = @intCast((sum_g[palette[palette_len].bucket] + count / 2) / count);
        palette[palette_len].b = @intCast((sum_b[palette[palette_len].bucket] + count / 2) / count);
    }
    return palette_len;
}

fn labelPixels(image: ktx.Image, palette: []const Color) void {
    const pixel_count = image.width * image.height;
    for (0..pixel_count) |index| {
        const pixel = image.pixels[index * 4 ..][0..4];
        if (pixel[3] < alpha_threshold) {
            labels[index] = transparent;
            continue;
        }
        var nearest: usize = 0;
        var best_distance = colorDistanceSquared(pixel, palette[0]);
        for (palette[1..], 1..) |color, palette_index| {
            const distance = colorDistanceSquared(pixel, color);
            if (distance < best_distance) {
                nearest = palette_index;
                best_distance = distance;
            }
        }
        labels[index] = @intCast(nearest);
    }
}

fn collectComponent(width: usize, height: usize, start: usize, color: u8) usize {
    labels[start] = component;
    queue[0] = @intCast(start);
    var head: usize = 0;
    var length: usize = 1;
    while (head < length) : (head += 1) {
        const index: usize = queue[head];
        const x = index % width;
        const y = index / width;
        if (x > 0) addComponentNeighbor(index - 1, color, &length);
        if (x + 1 < width) addComponentNeighbor(index + 1, color, &length);
        if (y > 0) addComponentNeighbor(index - width, color, &length);
        if (y + 1 < height) addComponentNeighbor(index + width, color, &length);
    }
    return length;
}

fn addComponentNeighbor(index: usize, color: u8, length: *usize) void {
    if (labels[index] != color) return;
    labels[index] = component;
    queue[length.*] = @intCast(index);
    length.* += 1;
}

fn finishComponent(length: usize) void {
    for (queue[0..length]) |index| labels[index] = done;
}

fn edgeBit(direction: Direction) u8 {
    return @as(u8, 1) << @intFromEnum(direction);
}

fn edgeExposed(width: usize, height: usize, pixel: usize, direction: Direction) bool {
    const x = pixel % width;
    const y = pixel / width;
    const neighbor = switch (direction) {
        .east => if (y + 1 < height) pixel + width else return true,
        .south => if (x > 0) pixel - 1 else return true,
        .west => if (y > 0) pixel - width else return true,
        .north => if (x + 1 < width) pixel + 1 else return true,
    };
    return labels[neighbor] != component;
}

fn edgeAt(width: usize, height: usize, x: usize, y: usize, direction: Direction) ?Edge {
    const pixel = switch (direction) {
        .east => if (x < width and y > 0) (y - 1) * width + x else return null,
        .south => if (x < width and y < height) y * width + x else return null,
        .west => if (x > 0 and y < height) y * width + x - 1 else return null,
        .north => if (x > 0 and y > 0) (y - 1) * width + x - 1 else return null,
    };
    if (labels[pixel] != component or !edgeExposed(width, height, pixel, direction)) return null;
    return .{ .pixel = pixel, .direction = direction };
}

fn edgeStart(width: usize, edge: Edge) Point {
    const x = edge.pixel % width;
    const y = edge.pixel / width;
    return switch (edge.direction) {
        .east => .{ .x = x, .y = y + 1 },
        .south => .{ .x = x, .y = y },
        .west => .{ .x = x + 1, .y = y },
        .north => .{ .x = x + 1, .y = y + 1 },
    };
}

fn edgeEnd(width: usize, edge: Edge) Point {
    const start = edgeStart(width, edge);
    return switch (edge.direction) {
        .east => .{ .x = start.x + 1, .y = start.y },
        .south => .{ .x = start.x, .y = start.y + 1 },
        .west => .{ .x = start.x - 1, .y = start.y },
        .north => .{ .x = start.x, .y = start.y - 1 },
    };
}

fn turn(direction: Direction, amount: u2) Direction {
    const direction_value: u3 = @intFromEnum(direction);
    return @enumFromInt((direction_value + amount) % 4);
}

fn sameEdge(a: Edge, b: Edge) bool {
    return a.pixel == b.pixel and a.direction == b.direction;
}

fn nextEdge(width: usize, height: usize, edge: Edge, start: Edge) !Edge {
    const point = edgeEnd(width, edge);
    const directions = [_]Direction{ turn(edge.direction, 3), edge.direction, turn(edge.direction, 1), turn(edge.direction, 2) };
    for (directions) |direction| {
        const candidate = edgeAt(width, height, point.x, point.y, direction) orelse continue;
        if (sameEdge(candidate, start)) return candidate;
        if (edge_marks[candidate.pixel] & edgeBit(candidate.direction) == 0) return candidate;
    }
    return error.UntraceableContour;
}

fn appendMove(out: *Writer, point: Point) !void {
    try out.byte('M');
    try out.integer(point.x);
    try out.byte(' ');
    try out.integer(point.y);
}

fn appendRunEnd(out: *Writer, direction: Direction, point: Point) !void {
    switch (direction) {
        .east, .west => {
            try out.byte('H');
            try out.integer(point.x);
        },
        .south, .north => {
            try out.byte('V');
            try out.integer(point.y);
        },
    }
}

fn traceLoop(out: *Writer, width: usize, height: usize, start: Edge, path_segments: *usize) !void {
    try appendMove(out, edgeStart(width, start));
    var edge = start;
    while (true) {
        edge_marks[edge.pixel] |= edgeBit(edge.direction);
        const next = try nextEdge(width, height, edge, start);
        if (sameEdge(next, start)) {
            if (path_segments.* == MAX_PATH_SEGMENTS) return error.PathTooComplex;
            path_segments.* += 1;
            try out.byte('Z');
            return;
        }
        if (next.direction != edge.direction) {
            if (path_segments.* == MAX_PATH_SEGMENTS) return error.PathTooComplex;
            path_segments.* += 1;
            try appendRunEnd(out, edge.direction, edgeEnd(width, edge));
        }
        edge = next;
    }
}

fn traceComponent(out: *Writer, width: usize, height: usize, palette_color: Color, length: usize) !void {
    try out.append("<path fill=\"#");
    try out.hexByte(palette_color.r);
    try out.hexByte(palette_color.g);
    try out.hexByte(palette_color.b);
    try out.append("\" d=\"");

    var path_segments: usize = 0;
    for (queue[0..length]) |index_u32| {
        const index: usize = index_u32;
        const directions = [_]Direction{ .east, .south, .west, .north };
        for (directions) |direction| {
            if (!edgeExposed(width, height, index, direction)) continue;
            if (edge_marks[index] & edgeBit(direction) != 0) continue;
            try traceLoop(out, width, height, .{ .pixel = index, .direction = direction }, &path_segments);
        }
    }
    try out.append("\"/>");
}

fn renderImpl(input_size_u32: u32) !usize {
    const input_size: usize = input_size_u32;
    if (input_size > INPUT_CAP) return error.InputTooLarge;
    const image = ktx.parse(input_buf[0..input_size]) orelse return error.InvalidKtx2;
    const pixel_count = image.width * image.height;
    if (pixel_count > MAX_PIXELS) return error.InputTooLarge;

    var palette: [MAX_COLORS]Color = undefined;
    const palette_len = chooseColors(image, &palette);
    var out = Writer{};
    try out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ");
    try out.integer(image.width);
    try out.byte(' ');
    try out.integer(image.height);
    try out.append("\" width=\"");
    try out.integer(image.width);
    try out.append("\" height=\"");
    try out.integer(image.height);
    try out.append("\">");

    if (palette_len != 0) {
        labelPixels(image, palette[0..palette_len]);
        @memset(edge_marks[0..pixel_count], 0);
        for (0..pixel_count) |index| {
            const color = labels[index];
            if (color >= palette_len) continue;
            const length = collectComponent(image.width, image.height, index, color);
            try traceComponent(&out, image.width, image.height, palette[color], length);
            finishComponent(length);
        }
    }
    try out.append("</svg>\n");
    return out.index;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
} {
    defer resetUniforms();
    const output_size = renderImpl(input_size) catch return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    return .{ .output_size_or_failure = @intCast(output_size), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "traces a rectangular region with grid path commands" {
    const size = ktx.writeHeader(input_buf[0..], 3, 2) orelse unreachable;
    @memcpy(input_buf[ktx.HEADER_SIZE..size], &[_]u8{
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0,
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0,
    });
    const written = try renderImpl(@intCast(size));
    const svg = output_buf[0..written];
    try std.testing.expect(std.mem.indexOf(u8, svg, "fill=\"#ff0000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "M0 0V2H2V0Z") != null);
}

test "traces a transparent hole as a second subpath" {
    const size = ktx.writeHeader(input_buf[0..], 3, 3) orelse unreachable;
    @memset(input_buf[ktx.HEADER_SIZE..size], 0);
    for (0..9) |index| {
        if (index == 4) continue;
        const pixel = ktx.HEADER_SIZE + index * 4;
        input_buf[pixel] = 0;
        input_buf[pixel + 1] = 255;
        input_buf[pixel + 2] = 0;
        input_buf[pixel + 3] = 255;
    }
    const written = try renderImpl(@intCast(size));
    const svg = output_buf[0..written];
    try std.testing.expect(std.mem.indexOf(u8, svg, "M0 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "M1 1") != null);
}
