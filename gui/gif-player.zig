const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const INPUT_CAP: usize = 4 * 1024 * 1024;
const MAX_PIXELS: usize = 1024 * 1024;
const MAX_DIMENSION: usize = 2048;
const MAX_FRAMES: usize = 256;
const OUTPUT_CAP: usize = ktx.HEADER_SIZE + MAX_PIXELS * 4;
const INPUT_CONTENT_TYPE = "image/gif";
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const MIN_FRAME_DELAY_MS: u64 = 20;

const GifError = error{InvalidGif};
const Phase = enum { initializing, ready, updating };

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const Frame = struct {
    left: usize,
    top: usize,
    width: usize,
    height: usize,
    palette_offset: usize,
    palette_entries: usize,
    data_offset: usize,
    data_end: usize,
    min_code_size: u8,
    delay_ms: u64,
    disposal: u8,
    transparent_index: ?u8,
    interlaced: bool,
};

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var canvas: [MAX_PIXELS * 4]u8 = undefined;
var restore_canvas: [MAX_PIXELS * 4]u8 = undefined;
var compressed: [INPUT_CAP]u8 = undefined;
var indices: [MAX_PIXELS]u8 = undefined;
var frames: [MAX_FRAMES]Frame = undefined;

var phase: Phase = .initializing;
var reject_offset: u32 = 0;
var source_size: usize = 0;
var screen_width: usize = 0;
var screen_height: usize = 0;
var frame_count: usize = 0;
var current_frame: usize = 0;
var total_duration_ms: u64 = 0;
var play_count: u64 = 1; // 0 means infinite.
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
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
    return 1;
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size: u32) RenderOutcome {
    switch (phase) {
        .initializing => {
            if (input_size > INPUT_CAP) @trap();
            reject_offset = 0;
            parseAndValidate(input_buf[0..input_size]) catch {
                const failure_offset = reject_offset;
                resetSourceState();
                return .{ .output_size_or_failure = failure_offset, .output_ptr = 0, .failed = 1 };
            };
            source_size = input_size;
            current_frame = 0;
            renderCurrentFrame() catch @trap();
            committed_at_ms = 0;
            phase = .ready;
            return .{ .output_size_or_failure = @intCast(ktx.HEADER_SIZE + screen_width * screen_height * 4), .output_ptr = @intFromPtr(&output_buf), .failed = 0 };
        },
        .ready => {
            if (input_size != 0) @trap();
            renderCurrentFrame() catch @trap();
            return .{ .output_size_or_failure = @intCast(ktx.HEADER_SIZE + screen_width * screen_height * 4), .output_ptr = @intFromPtr(&output_buf), .failed = 0 };
        },
        else => @trap(),
    }
}

export fn render(input_size: u32) RenderResult {
    const result = renderOutcome(input_size);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed_at_ms = begun_at_ms;
    const timing = frameAtTime(@intCast(begun_at_ms));
    current_frame = timing.frame;
    phase = .ready;
    return @intCast(timing.next_wake_ms orelse @as(u64, @intCast(begun_at_ms)));
}

const Timing = struct { frame: usize, next_wake_ms: ?u64 };

fn frameAtTime(now_ms: u64) Timing {
    if (frame_count == 1 or total_duration_ms == 0) return .{ .frame = frame_count - 1, .next_wake_ms = null };

    const cycle: u64 = now_ms / total_duration_ms;
    const within = now_ms % total_duration_ms;
    if (play_count != 0 and cycle >= play_count) {
        return .{ .frame = frame_count - 1, .next_wake_ms = null };
    }

    var end: u64 = 0;
    var i: usize = 0;
    while (i < frame_count) : (i += 1) {
        end += frames[i].delay_ms;
        if (within < end) {
            const wake = cycle * total_duration_ms + end;
            if (play_count != 0 and wake >= play_count * total_duration_ms and i + 1 == frame_count) {
                return .{ .frame = i, .next_wake_ms = null };
            }
            return .{ .frame = i, .next_wake_ms = wake };
        }
    }
    // `within` is a remainder, so this is unreachable unless timing state is corrupt.
    @trap();
}

fn resetSourceState() void {
    source_size = 0;
    screen_width = 0;
    screen_height = 0;
    frame_count = 0;
    current_frame = 0;
    total_duration_ms = 0;
    play_count = 1;
}

fn failAt(offset: usize) GifError {
    reject_offset = @intCast(@min(offset, std.math.maxInt(u32)));
    return error.InvalidGif;
}

fn readU16(data: []const u8, offset: usize) GifError!u16 {
    if (offset + 2 > data.len) return failAt(offset);
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn skipSubBlocks(data: []const u8, pos: *usize) GifError!void {
    while (true) {
        if (pos.* >= data.len) return failAt(pos.*);
        const len = data[pos.*];
        pos.* += 1;
        if (len == 0) return;
        if (pos.* + len > data.len) return failAt(pos.*);
        pos.* += len;
    }
}

fn collectSubBlocks(data: []const u8, start: usize, end: usize) GifError![]const u8 {
    var pos = start;
    var out_len: usize = 0;
    while (pos < end) {
        const len = data[pos];
        pos += 1;
        if (len == 0) {
            if (pos != end) return failAt(pos);
            return compressed[0..out_len];
        }
        if (pos + len > end or out_len + len > compressed.len) return failAt(pos);
        @memcpy(compressed[out_len .. out_len + len], data[pos .. pos + len]);
        out_len += len;
        pos += len;
    }
    return failAt(pos);
}

fn parseAndValidate(data: []const u8) GifError!void {
    resetSourceState();
    if (data.len < 13) return failAt(data.len);
    if (!std.mem.eql(u8, data[0..6], "GIF87a") and !std.mem.eql(u8, data[0..6], "GIF89a")) return failAt(0);

    screen_width = try readU16(data, 6);
    screen_height = try readU16(data, 8);
    if (screen_width == 0 or screen_height == 0 or screen_width > MAX_DIMENSION or screen_height > MAX_DIMENSION) return failAt(6);
    if (screen_width * screen_height > MAX_PIXELS) return failAt(6);

    var pos: usize = 13;
    var global_palette_offset: usize = 0;
    var global_palette_entries: usize = 0;
    if ((data[10] & 0x80) != 0) {
        global_palette_entries = @as(usize, 1) << @intCast((data[10] & 7) + 1);
        global_palette_offset = pos;
        const bytes = global_palette_entries * 3;
        if (pos + bytes > data.len) return failAt(pos);
        pos += bytes;
    }

    var pending_delay_ms: u64 = 100;
    var pending_disposal: u8 = 0;
    var pending_transparent: ?u8 = null;
    var saw_trailer = false;

    while (pos < data.len) {
        reject_offset = @intCast(pos);
        const marker = data[pos];
        pos += 1;
        switch (marker) {
            0x3b => {
                saw_trailer = true;
                break;
            },
            0x21 => {
                if (pos >= data.len) return failAt(pos);
                const label = data[pos];
                pos += 1;
                if (label == 0xf9) {
                    if (pos + 6 > data.len or data[pos] != 4 or data[pos + 5] != 0) return failAt(pos);
                    const packed_fields = data[pos + 1];
                    pending_disposal = (packed_fields >> 2) & 7;
                    if (pending_disposal > 3) return failAt(pos + 1);
                    const delay_cs = @as(u16, data[pos + 2]) | (@as(u16, data[pos + 3]) << 8);
                    pending_delay_ms = @max(@as(u64, delay_cs) * 10, MIN_FRAME_DELAY_MS);
                    pending_transparent = if ((packed_fields & 1) != 0) data[pos + 4] else null;
                    pos += 6;
                } else {
                    // Plain Text is a rendering block. This pixel player cannot
                    // ignore it without changing the animation, so reject it.
                    if (label == 0x01) return failAt(pos - 1);
                    if (pos >= data.len) return failAt(pos);
                    const header_len = data[pos];
                    pos += 1;
                    if (pos + header_len > data.len) return failAt(pos);
                    const is_netscape = label == 0xff and header_len == 11 and
                        (std.mem.eql(u8, data[pos .. pos + 11], "NETSCAPE2.0") or std.mem.eql(u8, data[pos .. pos + 11], "ANIMEXTS1.0"));
                    pos += header_len;
                    if (is_netscape and pos + 5 <= data.len and data[pos] == 3 and data[pos + 1] == 1 and data[pos + 4] == 0) {
                        const repeats = @as(u16, data[pos + 2]) | (@as(u16, data[pos + 3]) << 8);
                        play_count = if (repeats == 0) 0 else @as(u64, repeats) + 1;
                    }
                    try skipSubBlocks(data, &pos);
                }
            },
            0x2c => {
                if (frame_count >= MAX_FRAMES or pos + 9 > data.len) return failAt(pos);
                const left: usize = try readU16(data, pos);
                const top: usize = try readU16(data, pos + 2);
                const width: usize = try readU16(data, pos + 4);
                const height: usize = try readU16(data, pos + 6);
                const packed_fields = data[pos + 8];
                pos += 9;
                if (width == 0 or height == 0 or left + width > screen_width or top + height > screen_height) return failAt(pos - 9);
                if (width * height > MAX_PIXELS) return failAt(pos - 5);

                var palette_offset = global_palette_offset;
                var palette_entries = global_palette_entries;
                if ((packed_fields & 0x80) != 0) {
                    palette_entries = @as(usize, 1) << @intCast((packed_fields & 7) + 1);
                    palette_offset = pos;
                    const bytes = palette_entries * 3;
                    if (pos + bytes > data.len) return failAt(pos);
                    pos += bytes;
                }
                if (palette_entries == 0) return failAt(pos);
                if (pending_transparent) |transparent| if (transparent >= palette_entries) return failAt(pos);
                if (pos >= data.len) return failAt(pos);
                const min_code_size = data[pos];
                pos += 1;
                const data_offset = pos;
                try skipSubBlocks(data, &pos);

                frames[frame_count] = .{
                    .left = left,
                    .top = top,
                    .width = width,
                    .height = height,
                    .palette_offset = palette_offset,
                    .palette_entries = palette_entries,
                    .data_offset = data_offset,
                    .data_end = pos,
                    .min_code_size = min_code_size,
                    .delay_ms = pending_delay_ms,
                    .disposal = pending_disposal,
                    .transparent_index = pending_transparent,
                    .interlaced = (packed_fields & 0x40) != 0,
                };
                const frame = &frames[frame_count];
                const stream = try collectSubBlocks(data, frame.data_offset, frame.data_end);
                try lzwDecode(stream, frame.min_code_size, frame.width * frame.height, indices[0 .. frame.width * frame.height]);
                for (indices[0 .. frame.width * frame.height]) |index| if (index >= frame.palette_entries) return failAt(frame.data_offset);
                total_duration_ms = std.math.add(u64, total_duration_ms, frame.delay_ms) catch return failAt(frame.data_offset);
                frame_count += 1;
                pending_delay_ms = 100;
                pending_disposal = 0;
                pending_transparent = null;
            },
            else => return failAt(pos - 1),
        }
        if (saw_trailer) break;
    }
    if (!saw_trailer or pos != data.len or frame_count == 0) return failAt(pos);
}

fn lzwDecode(data: []const u8, min_code_size: u8, expected: usize, out: []u8) GifError!void {
    if (min_code_size < 2 or min_code_size > 8 or out.len < expected) return failAt(reject_offset);
    const clear: u16 = @as(u16, 1) << @intCast(min_code_size);
    const end = clear + 1;
    var next_code = clear + 2;
    var code_size: u8 = min_code_size + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;
    var bit_pos: usize = 0;
    var out_len: usize = 0;
    var old_code: ?u16 = null;
    var first_char: u8 = 0;

    while (true) {
        if (bit_pos + code_size > data.len * 8) return failAt(reject_offset);
        var code: u16 = 0;
        var bit: u8 = 0;
        while (bit < code_size) : (bit += 1) {
            code |= @as(u16, (data[bit_pos / 8] >> @intCast(bit_pos & 7)) & 1) << @intCast(bit);
            bit_pos += 1;
        }
        if (code == clear) {
            next_code = clear + 2;
            code_size = min_code_size + 1;
            old_code = null;
            continue;
        }
        if (code == end) break;
        if (old_code == null) {
            if (code >= clear or out_len >= expected) return failAt(reject_offset);
            out[out_len] = @intCast(code);
            out_len += 1;
            first_char = @intCast(code);
            old_code = code;
            continue;
        }

        var stack_len: usize = 0;
        var walk = code;
        if (code == next_code) {
            walk = old_code.?;
            stack[stack_len] = first_char;
            stack_len += 1;
        } else if (code > next_code) return failAt(reject_offset);
        while (walk >= clear) {
            if (walk >= next_code or stack_len >= stack.len) return failAt(reject_offset);
            stack[stack_len] = suffix[walk];
            stack_len += 1;
            walk = prefix[walk];
        }
        if (stack_len >= stack.len) return failAt(reject_offset);
        first_char = @intCast(walk);
        stack[stack_len] = first_char;
        stack_len += 1;
        while (stack_len > 0) {
            stack_len -= 1;
            if (out_len >= expected) return failAt(reject_offset);
            out[out_len] = stack[stack_len];
            out_len += 1;
        }
        if (next_code < 4096) {
            prefix[next_code] = old_code.?;
            suffix[next_code] = first_char;
            next_code += 1;
            if (next_code == (@as(u16, 1) << @intCast(code_size)) and code_size < 12) code_size += 1;
        }
        old_code = code;
    }
    if (out_len != expected) return failAt(reject_offset);
}

fn renderCurrentFrame() GifError!void {
    const pixel_bytes = screen_width * screen_height * 4;
    @memset(canvas[0..pixel_bytes], 0);
    var i: usize = 0;
    while (i <= current_frame) : (i += 1) {
        if (i > 0) disposeFrame(&frames[i - 1]);
        if (frames[i].disposal == 3) @memcpy(restore_canvas[0..pixel_bytes], canvas[0..pixel_bytes]);
        try drawFrame(&frames[i]);
    }
    _ = ktx.writeHeader(&output_buf, screen_width, screen_height) orelse @trap();
    @memcpy(output_buf[ktx.HEADER_SIZE .. ktx.HEADER_SIZE + pixel_bytes], canvas[0..pixel_bytes]);
}

fn disposeFrame(frame: *const Frame) void {
    if (frame.disposal == 2) {
        var y: usize = 0;
        while (y < frame.height) : (y += 1) {
            const start = ((frame.top + y) * screen_width + frame.left) * 4;
            @memset(canvas[start .. start + frame.width * 4], 0);
        }
    } else if (frame.disposal == 3) {
        @memcpy(canvas[0 .. screen_width * screen_height * 4], restore_canvas[0 .. screen_width * screen_height * 4]);
    }
}

fn drawFrame(frame: *const Frame) GifError!void {
    const stream = try collectSubBlocks(input_buf[0..source_size], frame.data_offset, frame.data_end);
    try lzwDecode(stream, frame.min_code_size, frame.width * frame.height, indices[0 .. frame.width * frame.height]);
    const palette = input_buf[frame.palette_offset .. frame.palette_offset + frame.palette_entries * 3];
    var source: usize = 0;
    if (!frame.interlaced) {
        var y: usize = 0;
        while (y < frame.height) : (y += 1) drawRow(frame, palette, y, &source);
    } else {
        const starts = [_]usize{ 0, 4, 2, 1 };
        const steps = [_]usize{ 8, 8, 4, 2 };
        for (starts, steps) |start, step| {
            var y = start;
            while (y < frame.height) : (y += step) drawRow(frame, palette, y, &source);
        }
    }
    if (source != frame.width * frame.height) return failAt(frame.data_offset);
}

fn drawRow(frame: *const Frame, palette: []const u8, y: usize, source: *usize) void {
    var x: usize = 0;
    while (x < frame.width) : (x += 1) {
        const index = indices[source.*];
        source.* += 1;
        if (frame.transparent_index != null and index == frame.transparent_index.?) continue;
        const src = @as(usize, index) * 3;
        const dst = ((frame.top + y) * screen_width + frame.left + x) * 4;
        canvas[dst] = palette[src];
        canvas[dst + 1] = palette[src + 1];
        canvas[dst + 2] = palette[src + 2];
        canvas[dst + 3] = 255;
    }
}

const TWO_FRAME_GIF = [_]u8{
    'G',  'I', 'F', '8',  '9',  'a', 1,    0,    1,  0,    0x80, 0,   0,
    0,    0,   0,   255,  0,    0,   0x21, 0xff, 11, 'N',  'E',  'T', 'S',
    'C',  'A', 'P', 'E',  '2',  '.', '0',  3,    1,  0,    0,    0,   0x21,
    0xf9, 4,   0,   2,    0,    0,   0,    0x2c, 0,  0,    0,    0,   1,
    0,    1,   0,   0,    2,    2,   0x44, 0x01, 0,  0x21, 0xf9, 4,   0,
    3,    0,   0,   0,    0x2c, 0,   0,    0,    0,  1,    0,    1,   0,
    0,    2,   2,   0x4c, 0x01, 0,   0x3b,
};

fn resetForTest() void {
    phase = .initializing;
    committed_at_ms = 0;
    resetSourceState();
}

test "fallible GIF initialization recovers and exposes image/gif" {
    resetForTest();
    input_buf[0] = 0;
    try std.testing.expectEqual(@as(u1, 1), renderOutcome(1).failed);
    @memcpy(input_buf[0..TWO_FRAME_GIF.len], &TWO_FRAME_GIF);
    const accepted = renderOutcome(TWO_FRAME_GIF.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, ktx.HEADER_SIZE + 4), accepted.output_size_or_failure);
    try std.testing.expectEqualStrings("image/gif", INPUT_CONTENT_TYPE);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, output_buf[ktx.HEADER_SIZE .. ktx.HEADER_SIZE + 4]);
}

test "timed updates select frames and request GIF deadlines" {
    resetForTest();
    @memcpy(input_buf[0..TWO_FRAME_GIF.len], &TWO_FRAME_GIF);
    try std.testing.expectEqual(@as(u1, 0), renderOutcome(TWO_FRAME_GIF.len).failed);
    begin_update_at(1);
    try std.testing.expectEqual(@as(i64, 20), finish_update());
    begin_update_at(20);
    try std.testing.expectEqual(@as(i64, 50), finish_update());
    _ = renderOutcome(0);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, output_buf[ktx.HEADER_SIZE .. ktx.HEADER_SIZE + 4]);
}
