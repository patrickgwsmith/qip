const std = @import("std");
const ShiftInt = std.math.Log2Int(usize);
const CodeShift = std.math.Log2Int(u16);

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "image/gif";
const OUTPUT_CONTENT_TYPE = "image/gif";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var lzw_in_buf: [INPUT_CAP]u8 = undefined;
var lzw_out_buf: [INPUT_CAP]u8 = undefined;
var index_buf: [INPUT_CAP]u8 = undefined;
var canvas_buf: [INPUT_CAP]u32 = undefined;

var lossy_amount: u32 = 0;
var max_colors: u32 = 256;
var dither_amount: u32 = 0;

const OptimizeError = error{
    InvalidGif,
    OutputOverflow,
};

const PaletteMap = struct {
    old_count: usize,
    active_count: usize,
    padded_count: usize,
    size_code: u8, // value stored in GIF packed field low 3 bits
    changed: bool,
    old_to_new: [256]u8,
    table_bytes: [256 * 3]u8,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
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

export fn uniform_set_lossy(value: u32) u32 {
    lossy_amount = if (value > 200) 200 else value;
    return lossy_amount;
}

export fn uniform_set_max_colors(value: u32) u32 {
    max_colors = if (value == 0 or value > 256) 256 else value;
    return max_colors;
}

export fn uniform_set_dither(value: u32) u32 {
    dither_amount = if (value > 100) 100 else value;
    return dither_amount;
}

fn writeByte(output: []u8, out_idx: *usize, b: u8) OptimizeError!void {
    if (out_idx.* >= output.len) return error.OutputOverflow;
    output[out_idx.*] = b;
    out_idx.* += 1;
}

fn writeSlice(output: []u8, out_idx: *usize, s: []const u8) OptimizeError!void {
    if (out_idx.* + s.len > output.len) return error.OutputOverflow;
    @memcpy(output[out_idx.* .. out_idx.* + s.len], s);
    out_idx.* += s.len;
}

fn parseSubBlockLength(input: []const u8, pos: *usize) OptimizeError!usize {
    if (pos.* >= input.len) return error.InvalidGif;
    const n = input[pos.*];
    pos.* += 1;
    return n;
}

fn skipSubBlocks(input: []const u8, pos: *usize) OptimizeError!void {
    while (true) {
        const block_len = try parseSubBlockLength(input, pos);
        if (block_len == 0) return;
        if (pos.* + block_len > input.len) return error.InvalidGif;
        pos.* += block_len;
    }
}

// Canonical O3-style packing: consolidate data sub-blocks into 255-byte chunks.
fn copySubBlocksRechunk(input: []const u8, pos: *usize, output: []u8, out_idx: *usize) OptimizeError!void {
    var carry: [255]u8 = undefined;
    var carry_len: usize = 0;

    while (true) {
        const block_len = try parseSubBlockLength(input, pos);
        if (block_len == 0) break;
        if (pos.* + block_len > input.len) return error.InvalidGif;

        var i: usize = 0;
        while (i < block_len) : (i += 1) {
            carry[carry_len] = input[pos.* + i];
            carry_len += 1;
            if (carry_len == carry.len) {
                try writeByte(output, out_idx, 255);
                try writeSlice(output, out_idx, carry[0..]);
                carry_len = 0;
            }
        }
        pos.* += block_len;
    }

    if (carry_len > 0) {
        try writeByte(output, out_idx, @as(u8, @intCast(carry_len)));
        try writeSlice(output, out_idx, carry[0..carry_len]);
    }
    try writeByte(output, out_idx, 0);
}

fn copyHeaderAndGlobalTable(input: []const u8, output: []u8, out_idx: *usize) OptimizeError!usize {
    if (input.len < 13) return error.InvalidGif;
    const header = input[0..6];
    if (!std.mem.eql(u8, header, "GIF87a") and !std.mem.eql(u8, header, "GIF89a")) {
        return error.InvalidGif;
    }

    try writeSlice(output, out_idx, input[0..13]);

    var pos: usize = 13;
    const packed_fields = input[10];
    if ((packed_fields & 0x80) != 0) {
        const table_bits: u8 = @as(u8, @intCast((packed_fields & 0x07) + 1));
        const table_entries: usize = @as(usize, 1) << @as(ShiftInt, @intCast(table_bits));
        const table_len: usize = table_entries * 3;
        if (pos + table_len > input.len) return error.InvalidGif;
        try writeSlice(output, out_idx, input[pos .. pos + table_len]);
        pos += table_len;
    }

    return pos;
}

fn quantizeChannel(value: u8, levels: u16) u8 {
    if (levels <= 1) return 0;

    const max_index: u32 = @as(u32, levels) - 1;
    const index = (@as(u32, value) * max_index + 127) / 255;
    const q = (index * 255 + (max_index / 2)) / max_index;
    return @as(u8, @intCast(q));
}

fn choosePaletteLevels(limit: u32) [3]u16 {
    var levels = [3]u16{ 1, 1, 1 };
    var product: u32 = 1;

    while (true) {
        var best_dim: usize = 3;
        var best_product: u32 = 0;
        var best_level: u16 = std.math.maxInt(u16);

        var dim: usize = 0;
        while (dim < 3) : (dim += 1) {
            const current_level = @as(u32, levels[dim]);
            const candidate = (product / current_level) * (current_level + 1);
            if (candidate > limit) continue;
            if (candidate > best_product or (candidate == best_product and levels[dim] < best_level)) {
                best_dim = dim;
                best_product = candidate;
                best_level = levels[dim];
            }
        }

        if (best_dim == 3) break;
        levels[best_dim] += 1;
        product = best_product;
    }

    return levels;
}

fn pow2CeilAtLeast2(value: usize) usize {
    var p: usize = 2;
    while (p < value and p < 256) : (p <<= 1) {}
    return p;
}

fn log2ExactPow2(value: usize) ShiftInt {
    var bits: ShiftInt = 0;
    var v = value;
    while (v > 1) : (v >>= 1) {
        bits += 1;
    }
    return bits;
}

fn minCodeSizeForPaletteEntries(entries: usize) u8 {
    const bits: u8 = @as(u8, @intCast(log2ExactPow2(entries)));
    return if (bits < 2) 2 else bits;
}

fn buildPaletteMap(table: []const u8, palette_limit: u32) OptimizeError!PaletteMap {
    const entry_count = table.len / 3;
    if (entry_count == 0 or entry_count > 256) return error.InvalidGif;

    var out: PaletteMap = undefined;
    out.old_count = entry_count;
    out.active_count = entry_count;
    out.padded_count = entry_count;
    out.size_code = @as(u8, @intCast(log2ExactPow2(entry_count) - 1));
    out.changed = false;

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        out.old_to_new[i] = @as(u8, @intCast(if (i < entry_count) i else 0));
    }
    @memcpy(out.table_bytes[0..table.len], table);
    if (table.len < out.table_bytes.len) {
        @memset(out.table_bytes[table.len..], 0);
    }

    if (palette_limit >= entry_count) {
        return out;
    }

    const levels = choosePaletteLevels(palette_limit);
    var unique_keys: [256]u32 = undefined;
    var unique_count: usize = 0;

    i = 0;
    while (i < entry_count) : (i += 1) {
        const base = i * 3;
        const qr = quantizeChannel(table[base], levels[0]);
        const qg = quantizeChannel(table[base + 1], levels[1]);
        const qb = quantizeChannel(table[base + 2], levels[2]);
        const key = (@as(u32, qr) << 16) | (@as(u32, qg) << 8) | @as(u32, qb);

        var found: usize = unique_count;
        var j: usize = 0;
        while (j < unique_count) : (j += 1) {
            if (unique_keys[j] == key) {
                found = j;
                break;
            }
        }
        if (found == unique_count) {
            unique_keys[unique_count] = key;
            unique_count += 1;
        }
        out.old_to_new[i] = @as(u8, @intCast(found));
    }

    const required_count = if (unique_count < 2) @as(usize, 2) else unique_count;
    const padded_count = pow2CeilAtLeast2(required_count);
    out.active_count = unique_count;
    out.padded_count = padded_count;
    out.size_code = @as(u8, @intCast(log2ExactPow2(padded_count) - 1));
    out.changed = true;

    i = 0;
    while (i < padded_count) : (i += 1) {
        const base = i * 3;
        if (i < unique_count) {
            const key = unique_keys[i];
            out.table_bytes[base] = @as(u8, @intCast((key >> 16) & 0xFF));
            out.table_bytes[base + 1] = @as(u8, @intCast((key >> 8) & 0xFF));
            out.table_bytes[base + 2] = @as(u8, @intCast(key & 0xFF));
        } else {
            out.table_bytes[base] = 0;
            out.table_bytes[base + 1] = 0;
            out.table_bytes[base + 2] = 0;
        }
    }
    if (padded_count * 3 < out.table_bytes.len) {
        @memset(out.table_bytes[padded_count * 3 ..], 0);
    }

    return out;
}

fn lossyDerivedPaletteLimit(lossy: u32) u32 {
    if (lossy == 0) return 256;
    const reduction = (lossy * 254 + 199) / 200;
    const limit = if (reduction >= 254) 2 else (256 - reduction);
    return if (limit < 2) 2 else limit;
}

fn effectivePaletteLimit(palette_limit: u32, lossy: u32) u32 {
    const lossy_limit = lossyDerivedPaletteLimit(lossy);
    return if (palette_limit < lossy_limit) palette_limit else lossy_limit;
}

fn collectSubBlocks(input: []const u8, pos: *usize, out: []u8) OptimizeError!usize {
    var out_len: usize = 0;
    while (true) {
        const block_len = try parseSubBlockLength(input, pos);
        if (block_len == 0) return out_len;
        if (pos.* + block_len > input.len) return error.InvalidGif;
        if (out_len + block_len > out.len) return error.OutputOverflow;
        @memcpy(out[out_len .. out_len + block_len], input[pos.* .. pos.* + block_len]);
        out_len += block_len;
        pos.* += block_len;
    }
}

fn writeSubBlocks(output: []u8, out_idx: *usize, data: []const u8) OptimizeError!void {
    var i: usize = 0;
    while (i < data.len) {
        const chunk = @min(@as(usize, 255), data.len - i);
        try writeByte(output, out_idx, @as(u8, @intCast(chunk)));
        try writeSlice(output, out_idx, data[i .. i + chunk]);
        i += chunk;
    }
    try writeByte(output, out_idx, 0);
}

fn lzwDecodeIndices(compressed: []const u8, min_code_size: u8, expected_len: usize, out: []u8) OptimizeError!usize {
    if (min_code_size < 2 or min_code_size > 8) return error.InvalidGif;
    if (expected_len > out.len) return error.OutputOverflow;

    const clear: u16 = @as(u16, 1) << @as(CodeShift, @intCast(min_code_size));
    const end: u16 = clear + 1;
    const first_code: u16 = clear + 2;
    var next_code: u16 = first_code;
    var code_size: u8 = min_code_size + 1;

    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;

    var bit_pos: usize = 0;
    var out_len: usize = 0;
    var old_code: i32 = -1;
    var first_char: u8 = 0;

    while (true) {
        var code: u16 = 0;
        var bit_i: u8 = 0;
        while (bit_i < code_size) : (bit_i += 1) {
            if (bit_pos >= compressed.len * 8) return error.InvalidGif;
            const byte = compressed[bit_pos / 8];
            const bit = (byte >> @as(u3, @intCast(bit_pos & 7))) & 1;
            code |= (@as(u16, bit) << @as(CodeShift, @intCast(bit_i)));
            bit_pos += 1;
        }

        if (code == clear) {
            next_code = first_code;
            code_size = min_code_size + 1;
            old_code = -1;
            continue;
        }
        if (code == end) break;

        if (old_code < 0) {
            if (code >= clear) return error.InvalidGif;
            if (out_len >= expected_len) return error.InvalidGif;
            out[out_len] = @as(u8, @intCast(code));
            out_len += 1;
            first_char = @as(u8, @intCast(code));
            old_code = @as(i32, @intCast(code));
            continue;
        }

        var stack_len: usize = 0;
        const current = code;

        if (current == next_code) {
            var walk = @as(u16, @intCast(old_code));
            while (walk >= clear) {
                if (walk >= 4096 or stack_len >= stack.len) return error.InvalidGif;
                stack[stack_len] = suffix[walk];
                stack_len += 1;
                walk = prefix[walk];
            }
            if (stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = @as(u8, @intCast(walk));
            stack_len += 1;
            if (stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = first_char;
            stack_len += 1;
            first_char = @as(u8, @intCast(walk));
        } else if (current < next_code) {
            var walk = current;
            while (walk >= clear) {
                if (walk >= 4096 or stack_len >= stack.len) return error.InvalidGif;
                stack[stack_len] = suffix[walk];
                stack_len += 1;
                walk = prefix[walk];
            }
            if (stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = @as(u8, @intCast(walk));
            stack_len += 1;
            first_char = @as(u8, @intCast(walk));
        } else {
            return error.InvalidGif;
        }

        while (stack_len > 0) {
            stack_len -= 1;
            if (out_len >= expected_len) return error.InvalidGif;
            out[out_len] = stack[stack_len];
            out_len += 1;
        }

        if (next_code < 4096) {
            prefix[next_code] = @as(u16, @intCast(old_code));
            suffix[next_code] = first_char;
            next_code += 1;
            if (next_code == (@as(u16, 1) << @as(CodeShift, @intCast(code_size))) and code_size < 12) {
                code_size += 1;
            }
        }

        old_code = @as(i32, @intCast(current));
    }

    if (out_len < expected_len) return error.InvalidGif;
    return out_len;
}

fn lzwEncodeIndices(indices: []const u8, min_code_size: u8, out: []u8) OptimizeError!usize {
    if (min_code_size < 2 or min_code_size > 8) return error.InvalidGif;

    const clear: u16 = @as(u16, 1) << @as(CodeShift, @intCast(min_code_size));
    const end: u16 = clear + 1;
    var next_code: u16 = clear + 2;
    var code_size: u8 = min_code_size + 1;

    var out_len: usize = 0;
    var bitbuf: u32 = 0;
    var bitcount: u8 = 0;

    const writeCode = struct {
        fn render(code: u16, code_bits: u8, out_buf: []u8, out_pos: *usize, bit_buffer: *u32, bit_count: *u8) OptimizeError!void {
            bit_buffer.* |= (@as(u32, code) << @as(u5, @intCast(bit_count.*)));
            bit_count.* += code_bits;
            while (bit_count.* >= 8) {
                if (out_pos.* >= out_buf.len) return error.OutputOverflow;
                out_buf[out_pos.*] = @as(u8, @intCast(bit_buffer.* & 0xFF));
                out_pos.* += 1;
                bit_buffer.* >>= 8;
                bit_count.* -= 8;
            }
        }
    }.render;

    try writeCode(clear, code_size, out, &out_len, &bitbuf, &bitcount);
    var first_after_clear = true;

    var i: usize = 0;
    while (i < indices.len) : (i += 1) {
        const lit = @as(u16, indices[i]);
        if (lit >= clear) return error.InvalidGif;
        try writeCode(lit, code_size, out, &out_len, &bitbuf, &bitcount);

        if (first_after_clear) {
            first_after_clear = false;
            continue;
        }

        if (next_code < 4096) {
            next_code += 1;
            if (next_code == (@as(u16, 1) << @as(CodeShift, @intCast(code_size))) and code_size < 12) {
                code_size += 1;
            }
        } else {
            try writeCode(clear, code_size, out, &out_len, &bitbuf, &bitcount);
            code_size = min_code_size + 1;
            next_code = clear + 2;
            first_after_clear = true;
        }
    }

    try writeCode(end, code_size, out, &out_len, &bitbuf, &bitcount);

    if (bitcount > 0) {
        if (out_len >= out.len) return error.OutputOverflow;
        out[out_len] = @as(u8, @intCast(bitbuf & 0xFF));
        out_len += 1;
    }

    return out_len;
}

fn paletteColorU32(table: []const u8, idx: u8) u32 {
    const base = @as(usize, idx) * 3;
    if (base + 2 >= table.len) return 0;
    return (@as(u32, table[base]) << 16) | (@as(u32, table[base + 1]) << 8) | @as(u32, table[base + 2]);
}

fn deinterlaceToRows(src: []const u8, dst: []u8, width: usize, height: usize) OptimizeError!void {
    if (src.len != width * height or dst.len != width * height) return error.InvalidGif;
    var p: usize = 0;
    const starts = [_]usize{ 0, 4, 2, 1 };
    const steps = [_]usize{ 8, 8, 4, 2 };
    var pass: usize = 0;
    while (pass < 4) : (pass += 1) {
        var y = starts[pass];
        while (y < height) : (y += steps[pass]) {
            const row_off = y * width;
            if (p + width > src.len) return error.InvalidGif;
            @memcpy(dst[row_off .. row_off + width], src[p .. p + width]);
            p += width;
        }
    }
    if (p != src.len) return error.InvalidGif;
}

fn nearestPaletteIndex(table: []const u8, count: usize, r: i32, g: i32, b: i32) u8 {
    var best_idx: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const base = i * 3;
        const pr = @as(i32, table[base]);
        const pg = @as(i32, table[base + 1]);
        const pb = @as(i32, table[base + 2]);
        const dr = r - pr;
        const dg = g - pg;
        const db = b - pb;
        const dist = @as(u32, @intCast(dr * dr + dg * dg + db * db));
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = @as(u8, @intCast(i));
        }
    }
    return best_idx;
}

fn clampU8(v: i32) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @as(u8, @intCast(v));
}

fn remapFrameIndices(
    indices_row_major: []u8,
    width: usize,
    height: usize,
    old_table: []const u8,
    map: *const PaletteMap,
    transparent_old: ?u8,
    dither_pct: u32,
) void {
    if (!map.changed) return;
    if (dither_pct == 0 or map.active_count == 0) {
        var i: usize = 0;
        while (i < indices_row_major.len) : (i += 1) {
            const old_idx = indices_row_major[i];
            if (transparent_old) |t| {
                if (old_idx == t) {
                    indices_row_major[i] = map.old_to_new[t];
                    continue;
                }
            }
            indices_row_major[i] = map.old_to_new[old_idx];
        }
        return;
    }

    const bayer4 = [_]i32{
        0,  8,  2,  10,
        12, 4,  14, 6,
        3,  11, 1,  9,
        15, 7,  13, 5,
    };
    const strength = @as(i32, @intCast((dither_pct * 32) / 100));

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const i = y * width + x;
            const old_idx = indices_row_major[i];
            if (transparent_old) |t| {
                if (old_idx == t) {
                    indices_row_major[i] = map.old_to_new[t];
                    continue;
                }
            }
            const old_base = @as(usize, old_idx) * 3;
            const d = bayer4[(y & 3) * 4 + (x & 3)] - 8;
            const delta = d * strength;
            const r = clampU8(@as(i32, old_table[old_base]) + delta);
            const g = clampU8(@as(i32, old_table[old_base + 1]) + delta);
            const b = clampU8(@as(i32, old_table[old_base + 2]) + delta);
            indices_row_major[i] = nearestPaletteIndex(map.table_bytes[0 .. map.padded_count * 3], map.active_count, r, g, b);
        }
    }
}

fn clearCanvasRect(canvas: []u32, screen_w: usize, screen_h: usize, x: usize, y: usize, w: usize, h: usize, color: u32) void {
    if (x >= screen_w or y >= screen_h) return;
    const max_w = @min(w, screen_w - x);
    const max_h = @min(h, screen_h - y);
    var yy: usize = 0;
    while (yy < max_h) : (yy += 1) {
        const row = (y + yy) * screen_w + x;
        @memset(canvas[row .. row + max_w], color);
    }
}

fn countImageDescriptorBlocks(input: []const u8) OptimizeError!u32 {
    if (input.len < 13) return error.InvalidGif;
    if (!std.mem.eql(u8, input[0..6], "GIF87a") and !std.mem.eql(u8, input[0..6], "GIF89a")) {
        return error.InvalidGif;
    }

    var pos: usize = 13;
    const packed_fields = input[10];
    if ((packed_fields & 0x80) != 0) {
        const bits: u8 = @as(u8, @intCast((packed_fields & 0x07) + 1));
        const table_len = (@as(usize, 1) << @as(ShiftInt, @intCast(bits))) * 3;
        if (pos + table_len > input.len) return error.InvalidGif;
        pos += table_len;
    }

    var count: u32 = 0;
    while (true) {
        if (pos >= input.len) return error.InvalidGif;
        const block_id = input[pos];
        pos += 1;

        switch (block_id) {
            0x3B => return count,
            0x21 => {
                if (pos >= input.len) return error.InvalidGif;
                const label = input[pos];
                pos += 1;

                switch (label) {
                    0xF9 => {
                        if (pos >= input.len) return error.InvalidGif;
                        const sz = input[pos];
                        pos += 1;
                        if (pos + sz > input.len) return error.InvalidGif;
                        pos += sz;
                        if (pos >= input.len or input[pos] != 0) return error.InvalidGif;
                        pos += 1;
                    },
                    0xFE => try skipSubBlocks(input, &pos),
                    else => {
                        if (pos >= input.len) return error.InvalidGif;
                        const header_sz = input[pos];
                        pos += 1;
                        if (pos + header_sz > input.len) return error.InvalidGif;
                        pos += header_sz;
                        try skipSubBlocks(input, &pos);
                    },
                }
            },
            0x2C => {
                count += 1;
                if (pos + 9 > input.len) return error.InvalidGif;
                const desc = input[pos .. pos + 9];
                pos += 9;
                const desc_packed = desc[8];
                if ((desc_packed & 0x80) != 0) {
                    const bits: u8 = @as(u8, @intCast((desc_packed & 0x07) + 1));
                    const local_table_len = (@as(usize, 1) << @as(ShiftInt, @intCast(bits))) * 3;
                    if (pos + local_table_len > input.len) return error.InvalidGif;
                    pos += local_table_len;
                }
                if (pos >= input.len) return error.InvalidGif;
                pos += 1; // lzw min code size
                try skipSubBlocks(input, &pos);
            },
            else => return error.InvalidGif,
        }
    }
}

fn readU16LE(bytes: []const u8, off: usize) OptimizeError!u16 {
    if (off + 1 >= bytes.len) return error.InvalidGif;
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn pixelCountFromImageDescriptor(desc: []const u8) OptimizeError!usize {
    if (desc.len < 9) return error.InvalidGif;
    const w = try readU16LE(desc, 4);
    const h = try readU16LE(desc, 6);
    if (w == 0 or h == 0) return error.InvalidGif;
    const prod = @as(u64, w) * @as(u64, h);
    if (prod > INPUT_CAP) return error.OutputOverflow;
    return @as(usize, @intCast(prod));
}

fn optimizeGif(input: []const u8, output: []u8, lossy: u32, palette_limit: u32) OptimizeError!usize {
    var out_idx: usize = 0;
    if (palette_limit == 0 or palette_limit > 256) return error.InvalidGif;
    const effective_palette_limit = effectivePaletteLimit(palette_limit, lossy);

    var pos = try copyHeaderAndGlobalTable(input, output, &out_idx);
    const screen_w_u16 = try readU16LE(input, 6);
    const screen_h_u16 = try readU16LE(input, 8);
    const screen_w = @as(usize, screen_w_u16);
    const screen_h = @as(usize, screen_h_u16);
    const canvas_len_u64 = @as(u64, screen_w_u16) * @as(u64, screen_h_u16);
    if (canvas_len_u64 > INPUT_CAP) return error.OutputOverflow;
    const canvas_len = @as(usize, @intCast(canvas_len_u64));

    const has_global_table = (input[10] & 0x80) != 0;
    var global_map: PaletteMap = undefined;
    var global_table_in: []const u8 = input[0..0];
    var have_global_map = false;
    if (has_global_table) {
        const table_bits: u8 = @as(u8, @intCast((input[10] & 0x07) + 1));
        const table_entries: usize = @as(usize, 1) << @as(ShiftInt, @intCast(table_bits));
        const table_len: usize = table_entries * 3;
        const gct_start: usize = 13;
        const gct_end: usize = gct_start + table_len;
        if (gct_end > input.len) return error.InvalidGif;
        global_table_in = input[gct_start..gct_end];

        global_map = try buildPaletteMap(global_table_in, effective_palette_limit);
        have_global_map = true;
        if (global_map.changed) {
            out_idx = 13;
            output[10] = (output[10] & 0xF8) | (global_map.size_code & 0x07);
            try writeSlice(output, &out_idx, global_map.table_bytes[0 .. global_map.padded_count * 3]);
            output[11] = global_map.old_to_new[input[11]];
        }
        pos = gct_end;
    }

    var bg_color: u32 = 0;
    if (have_global_map) {
        const bg_index = output[11];
        bg_color = paletteColorU32(global_map.table_bytes[0 .. global_map.padded_count * 3], bg_index);
    }
    @memset(canvas_buf[0..canvas_len], bg_color);

    var pending_gce: [259]u8 = undefined;
    var pending_gce_len: usize = 0;
    var have_emitted_frame = false;
    var last_emitted_disposal: u8 = 0;
    var last_emitted_delay_off: ?usize = null;

    while (true) {
        if (pos >= input.len) return error.InvalidGif;
        const block_id = input[pos];
        pos += 1;

        switch (block_id) {
            0x3B => {
                // GIF trailer.
                pending_gce_len = 0;
                try writeByte(output, &out_idx, 0x3B);
                // Preserve any trailing bytes if present.
                if (pos < input.len) try writeSlice(output, &out_idx, input[pos..]);
                return out_idx;
            },
            0x21 => {
                if (pos >= input.len) return error.InvalidGif;
                const label = input[pos];
                pos += 1;

                switch (label) {
                    0xF9 => {
                        // Graphic Control Extension: hold until next rendering block.
                        if (pos >= input.len) return error.InvalidGif;
                        const gce_size = input[pos];
                        pos += 1;
                        if (pos + gce_size > input.len) return error.InvalidGif;
                        if (pos >= input.len) return error.InvalidGif;
                        const gce_data = input[pos .. pos + gce_size];
                        pos += gce_size;
                        const terminator = input[pos];
                        pos += 1;
                        if (terminator != 0) return error.InvalidGif;

                        const total_len: usize = 4 + gce_size;
                        pending_gce[0] = 0x21;
                        pending_gce[1] = 0xF9;
                        pending_gce[2] = gce_size;
                        @memcpy(pending_gce[3 .. 3 + gce_data.len], gce_data);
                        pending_gce[3 + gce_data.len] = 0;
                        pending_gce_len = total_len;
                    },
                    0xFE => {
                        // O3 behavior: strip comment extensions.
                        try skipSubBlocks(input, &pos);
                    },
                    0x01 => {
                        // Plain-text extension is a rendering block.
                        if (pos >= input.len) return error.InvalidGif;
                        const header_size = input[pos];
                        pos += 1;
                        if (pos + header_size > input.len) return error.InvalidGif;
                        const header_data = input[pos .. pos + header_size];
                        pos += header_size;
                        if (pending_gce_len > 0) {
                            try writeSlice(output, &out_idx, pending_gce[0..pending_gce_len]);
                            pending_gce_len = 0;
                        }
                        try writeByte(output, &out_idx, 0x21);
                        try writeByte(output, &out_idx, 0x01);
                        try writeByte(output, &out_idx, header_size);
                        try writeSlice(output, &out_idx, header_data);
                        try copySubBlocksRechunk(input, &pos, output, &out_idx);
                    },
                    else => {
                        // Application/unknown extensions: keep, but re-chunk their sub-block payload.
                        if (pos >= input.len) return error.InvalidGif;
                        const header_size = input[pos];
                        pos += 1;
                        if (pos + header_size > input.len) return error.InvalidGif;
                        const header_data = input[pos .. pos + header_size];
                        pos += header_size;

                        try writeByte(output, &out_idx, 0x21);
                        try writeByte(output, &out_idx, label);
                        try writeByte(output, &out_idx, header_size);
                        try writeSlice(output, &out_idx, header_data);
                        try copySubBlocksRechunk(input, &pos, output, &out_idx);
                    },
                }
            },
            0x2C => {
                // Image Descriptor (rendering block).
                if (pos + 9 > input.len) return error.InvalidGif;
                const desc = input[pos .. pos + 9];
                pos += 9;
                var desc_out: [9]u8 = undefined;
                @memcpy(desc_out[0..], desc);

                const frame_x_u16 = try readU16LE(desc, 0);
                const frame_y_u16 = try readU16LE(desc, 2);
                const frame_w_u16 = try readU16LE(desc, 4);
                const frame_h_u16 = try readU16LE(desc, 6);
                if (frame_w_u16 == 0 or frame_h_u16 == 0) return error.InvalidGif;

                const frame_x = @as(usize, frame_x_u16);
                const frame_y = @as(usize, frame_y_u16);
                const frame_w = @as(usize, frame_w_u16);
                const frame_h = @as(usize, frame_h_u16);
                if (frame_x + frame_w > screen_w or frame_y + frame_h > screen_h) return error.InvalidGif;

                const packed_fields = desc[8];
                var local_table_len: usize = 0;
                if ((packed_fields & 0x80) != 0) {
                    const bits: u8 = @as(u8, @intCast((packed_fields & 0x07) + 1));
                    local_table_len = (@as(usize, 1) << @as(ShiftInt, @intCast(bits))) * 3;
                }
                if (pos + local_table_len > input.len) return error.InvalidGif;
                const local_table = input[pos .. pos + local_table_len];
                pos += local_table_len;

                if (pos >= input.len) return error.InvalidGif;
                const lzw_min_code_size_in = input[pos];
                pos += 1;
                if (lzw_min_code_size_in < 2 or lzw_min_code_size_in > 8) return error.InvalidGif;

                var local_map: PaletteMap = undefined;
                var active_map: ?*const PaletteMap = null;
                var old_table: []const u8 = input[0..0];

                if (local_table_len > 0) {
                    local_map = try buildPaletteMap(local_table, effective_palette_limit);
                    active_map = &local_map;
                    old_table = local_table;
                    if (local_map.changed) {
                        desc_out[8] = (desc_out[8] & 0xF8) | (local_map.size_code & 0x07);
                    }
                } else if (have_global_map) {
                    active_map = &global_map;
                    old_table = global_table_in;
                } else {
                    return error.InvalidGif;
                }

                var current_disposal: u8 = 0;
                var current_delay: u16 = 0;
                var transparent_old: ?u8 = null;
                if (pending_gce_len >= 8 and pending_gce[1] == 0xF9 and pending_gce[2] >= 4) {
                    const gce_packed = pending_gce[3];
                    current_disposal = (gce_packed >> 2) & 0x07;
                    current_delay = @as(u16, pending_gce[4]) | (@as(u16, pending_gce[5]) << 8);
                    if ((gce_packed & 0x01) != 0) {
                        transparent_old = pending_gce[6];
                    }
                }

                var transparent_new: ?u8 = transparent_old;
                if (active_map.?.changed) {
                    if (transparent_old) |to| {
                        const mapped = active_map.?.old_to_new[to];
                        transparent_new = mapped;
                        if (pending_gce_len >= 8 and pending_gce[1] == 0xF9 and pending_gce[2] >= 4) {
                            pending_gce[6] = mapped;
                        }
                    }
                }

                const frame_pixels_u64 = @as(u64, frame_w_u16) * @as(u64, frame_h_u16);
                if (frame_pixels_u64 > INPUT_CAP) return error.OutputOverflow;
                const frame_pixels = @as(usize, @intCast(frame_pixels_u64));
                const compressed_len = try collectSubBlocks(input, &pos, lzw_in_buf[0..]);
                _ = try lzwDecodeIndices(lzw_in_buf[0..compressed_len], lzw_min_code_size_in, frame_pixels, lzw_out_buf[0..frame_pixels]);

                if ((packed_fields & 0x40) != 0) {
                    try deinterlaceToRows(lzw_out_buf[0..frame_pixels], index_buf[0..frame_pixels], frame_w, frame_h);
                } else {
                    @memcpy(index_buf[0..frame_pixels], lzw_out_buf[0..frame_pixels]);
                }

                remapFrameIndices(index_buf[0..frame_pixels], frame_w, frame_h, old_table, active_map.?, transparent_old, dither_amount);

                const palette_out = active_map.?.table_bytes[0 .. active_map.?.padded_count * 3];
                var changed_count: usize = 0;
                var min_x = frame_w;
                var min_y = frame_h;
                var max_x: usize = 0;
                var max_y: usize = 0;

                var fy: usize = 0;
                while (fy < frame_h) : (fy += 1) {
                    var fx: usize = 0;
                    while (fx < frame_w) : (fx += 1) {
                        const frame_i = fy * frame_w + fx;
                        const idx = index_buf[frame_i];
                        const canvas_i = (frame_y + fy) * screen_w + (frame_x + fx);
                        const old_color = canvas_buf[canvas_i];

                        var new_color = old_color;
                        if (transparent_new) |t| {
                            if (idx != t) new_color = paletteColorU32(palette_out, idx);
                        } else {
                            new_color = paletteColorU32(palette_out, idx);
                        }

                        if (new_color != old_color) {
                            changed_count += 1;
                            if (fx < min_x) min_x = fx;
                            if (fy < min_y) min_y = fy;
                            if (fx > max_x) max_x = fx;
                            if (fy > max_y) max_y = fy;
                        }
                    }
                }

                const disposal_none = current_disposal == 0 or current_disposal == 1;
                const duplicate_skip_ok = changed_count == 0 and disposal_none and have_emitted_frame and
                    (last_emitted_disposal == 0 or last_emitted_disposal == 1) and last_emitted_delay_off != null;
                if (duplicate_skip_ok) {
                    const off = last_emitted_delay_off.?;
                    const prev = @as(u16, output[off]) | (@as(u16, output[off + 1]) << 8);
                    const sum_u32 = @as(u32, prev) + @as(u32, current_delay);
                    const merged: u16 = if (sum_u32 > 0xFFFF) 0xFFFF else @as(u16, @intCast(sum_u32));
                    output[off] = @as(u8, @intCast(merged & 0xFF));
                    output[off + 1] = @as(u8, @intCast(merged >> 8));
                    pending_gce_len = 0;
                    continue;
                }

                var emit_x = frame_x;
                var emit_y = frame_y;
                var emit_w = frame_w;
                var emit_h = frame_h;
                var emit_indices = index_buf[0..frame_pixels];
                var did_crop = false;

                const can_crop = changed_count > 0 and current_disposal != 2;
                if (can_crop) {
                    const crop_x = min_x;
                    const crop_y = min_y;
                    const crop_w = max_x - min_x + 1;
                    const crop_h = max_y - min_y + 1;
                    if (!(crop_x == 0 and crop_y == 0 and crop_w == frame_w and crop_h == frame_h)) {
                        did_crop = true;
                        emit_x = frame_x + crop_x;
                        emit_y = frame_y + crop_y;
                        emit_w = crop_w;
                        emit_h = crop_h;

                        const emit_pixels = emit_w * emit_h;
                        var cy: usize = 0;
                        while (cy < emit_h) : (cy += 1) {
                            const src = (crop_y + cy) * frame_w + crop_x;
                            const dst = cy * emit_w;
                            std.mem.copyForwards(u8, index_buf[dst .. dst + emit_w], index_buf[src .. src + emit_w]);
                        }
                        emit_indices = index_buf[0..emit_pixels];

                        const ex16 = @as(u16, @intCast(emit_x));
                        const ey16 = @as(u16, @intCast(emit_y));
                        const ew16 = @as(u16, @intCast(emit_w));
                        const eh16 = @as(u16, @intCast(emit_h));
                        desc_out[0] = @as(u8, @intCast(ex16 & 0xFF));
                        desc_out[1] = @as(u8, @intCast(ex16 >> 8));
                        desc_out[2] = @as(u8, @intCast(ey16 & 0xFF));
                        desc_out[3] = @as(u8, @intCast(ey16 >> 8));
                        desc_out[4] = @as(u8, @intCast(ew16 & 0xFF));
                        desc_out[5] = @as(u8, @intCast(ew16 >> 8));
                        desc_out[6] = @as(u8, @intCast(eh16 & 0xFF));
                        desc_out[7] = @as(u8, @intCast(eh16 >> 8));
                    }
                }

                const passthrough = !did_crop and !active_map.?.changed;

                var current_delay_off: ?usize = null;
                if (pending_gce_len > 0) {
                    const gce_start = out_idx;
                    try writeSlice(output, &out_idx, pending_gce[0..pending_gce_len]);
                    if (pending_gce_len >= 8 and pending_gce[1] == 0xF9 and pending_gce[2] >= 4) {
                        current_delay_off = gce_start + 4;
                    } else {
                        current_delay_off = null;
                    }
                    pending_gce_len = 0;
                }

                try writeByte(output, &out_idx, 0x2C);
                if (passthrough) {
                    try writeSlice(output, &out_idx, desc);
                } else {
                    desc_out[8] &= 0xBF; // clear interlace flag; encoder outputs row-major
                    try writeSlice(output, &out_idx, desc_out[0..]);
                }
                if (local_table_len > 0) {
                    if (passthrough) {
                        try writeSlice(output, &out_idx, local_table);
                    } else if (local_map.changed) {
                        try writeSlice(output, &out_idx, local_map.table_bytes[0 .. local_map.padded_count * 3]);
                    } else {
                        try writeSlice(output, &out_idx, local_table);
                    }
                }

                if (passthrough) {
                    try writeByte(output, &out_idx, lzw_min_code_size_in);
                    try writeSubBlocks(output, &out_idx, lzw_in_buf[0..compressed_len]);
                } else {
                    const lzw_min_code_size_out = minCodeSizeForPaletteEntries(active_map.?.padded_count);
                    try writeByte(output, &out_idx, lzw_min_code_size_out);
                    const encoded_len = try lzwEncodeIndices(emit_indices, lzw_min_code_size_out, lzw_out_buf[0..]);
                    try writeSubBlocks(output, &out_idx, lzw_out_buf[0..encoded_len]);
                }

                have_emitted_frame = true;
                last_emitted_disposal = current_disposal;
                last_emitted_delay_off = current_delay_off;

                if (current_disposal == 0 or current_disposal == 1) {
                    var ay: usize = 0;
                    while (ay < emit_h) : (ay += 1) {
                        var ax: usize = 0;
                        while (ax < emit_w) : (ax += 1) {
                            const idx = emit_indices[ay * emit_w + ax];
                            if (transparent_new) |t| {
                                if (idx == t) continue;
                            }
                            const canvas_i = (emit_y + ay) * screen_w + (emit_x + ax);
                            canvas_buf[canvas_i] = paletteColorU32(palette_out, idx);
                        }
                    }
                } else if (current_disposal == 2) {
                    clearCanvasRect(canvas_buf[0..canvas_len], screen_w, screen_h, emit_x, emit_y, emit_w, emit_h, bg_color);
                }
            },
            else => return error.InvalidGif,
        }
    }
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const out_len = optimizeGif(input_buf[0..input_size], output_buf[0..], lossy_amount, max_colors) catch return 0;
    return @as(u32, @intCast(out_len));
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

test "strips comment extension and keeps valid trailer" {
    const input = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, // LSD with global table
        0x00, 0x00, 0x00, 0xff, 0xff, 0xff, // GCT (2 entries)
        0x21, 0xFE, 0x03, 'a', 'b', 'c', 0x00, // comment ext
        0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // image desc
        0x02, // LZW min code size
        0x02, 0x44, 0x01, 0x00, // image data
        0x3B, // trailer
    };

    var out: [256]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 0, 256);

    try std.testing.expect(out_len < input.len);
    try std.testing.expectEqual(@as(u8, 0x3B), out[out_len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, out[0..out_len], "abc") == null);
}

test "dedupe merges identical consecutive frames" {
    const input = [_]u8{
        'G',  'I',  'F',  '8',  '9',  'a',
        0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff,
        0xff,
        // Frame 0
        0x21, 0xF9, 0x04, 0x04, 0x01,
        0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00,
        // Frame 1
        0x21, 0xF9, 0x04, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x2C, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    };

    var out: [512]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 0, 256);
    const frames = try countImageDescriptorBlocks(out[0..out_len]);
    try std.testing.expectEqual(@as(u32, 1), frames);
    try std.testing.expect(std.mem.indexOf(u8, out[0..out_len], &[_]u8{ 0x02, 0x00 }) != null);
}

test "max_colors quantizes global palette" {
    const input = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x01, 0x00, 0x01, 0x00, 0x81, 0x00, 0x00, // 4-color global table
        0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x2C, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    };

    var out: [512]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 0, 2);
    try std.testing.expect(out_len > 19);
    try std.testing.expectEqual(@as(u8, 0), out[10] & 0x07); // 2-color table

    const table_len: usize = (@as(usize, 1) << @as(ShiftInt, @intCast((out[10] & 0x07) + 1))) * 3;
    try std.testing.expectEqual(@as(usize, 6), table_len);
    const table = out[13 .. 13 + table_len];
    const entry_count = table.len / 3;
    var distinct: usize = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const ib = i * 3;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const jb = j * 3;
            if (table[ib] == table[jb] and table[ib + 1] == table[jb + 1] and table[ib + 2] == table[jb + 2]) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct += 1;
    }
    try std.testing.expect(distinct <= 2);
}

test "lossy can quantize palette without max_colors" {
    const input = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x01, 0x00, 0x01, 0x00, 0x81, 0x00, 0x00, // 4-color global table
        0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x2C, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    };

    var out: [512]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 200, 256);
    try std.testing.expect(out_len > 19);
    try std.testing.expectEqual(@as(u8, 0), out[10] & 0x07); // lossy drives toward 2 colors

    const table_len: usize = (@as(usize, 1) << @as(ShiftInt, @intCast((out[10] & 0x07) + 1))) * 3;
    const table = out[13 .. 13 + table_len];
    const entry_count = table.len / 3;
    var distinct: usize = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const ib = i * 3;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const jb = j * 3;
            if (table[ib] == table[jb] and table[ib + 1] == table[jb + 1] and table[ib + 2] == table[jb + 2]) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct += 1;
    }
    try std.testing.expect(distinct <= 2);
}
