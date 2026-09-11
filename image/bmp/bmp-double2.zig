// Zig port of bmp-double.c

const builtin = @import("builtin");
const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 32 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "image/bmp";
const OUTPUT_CONTENT_TYPE = "image/bmp";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

fn readU16LE(off: u32) u16 {
    const idx: usize = @intCast(off);
    return @as(u16, input_buf[idx]) | (@as(u16, input_buf[idx + 1]) << 8);
}

fn readU32LE(off: u32) u32 {
    const idx: usize = @intCast(off);
    if (builtin.target.cpu.arch.endian() == .little) {
        const ptr = @as(*align(1) const u32, @ptrCast(&input_buf[idx]));
        return ptr.*;
    }
    return @as(u32, input_buf[idx]) |
        (@as(u32, input_buf[idx + 1]) << 8) |
        (@as(u32, input_buf[idx + 2]) << 16) |
        (@as(u32, input_buf[idx + 3]) << 24);
}

fn readI32LE(off: u32) i32 {
    return @as(i32, @bitCast(readU32LE(off)));
}

fn writeU16LE(off: u32, value: u16) void {
    const idx: usize = @intCast(off);
    output_buf[idx] = @intCast(value & 0xFF);
    output_buf[idx + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32LE(off: u32, value: u32) void {
    const idx: usize = @intCast(off);
    output_buf[idx] = @intCast(value & 0xFF);
    output_buf[idx + 1] = @intCast((value >> 8) & 0xFF);
    output_buf[idx + 2] = @intCast((value >> 16) & 0xFF);
    output_buf[idx + 3] = @intCast((value >> 24) & 0xFF);
}

fn storeU32LE(off: u32, value: u32) void {
    if (builtin.target.cpu.arch.endian() == .little) {
        const ptr = @as(*align(1) u32, @ptrCast(&output_buf[@intCast(off)]));
        ptr.* = value;
        return;
    }
    writeU32LE(off, value);
}

fn storeU64LE(off: u32, value: u64) void {
    if (builtin.target.cpu.arch.endian() == .little) {
        const ptr = @as(*align(1) u64, @ptrCast(&output_buf[@intCast(off)]));
        ptr.* = value;
        return;
    }
    const lo: u32 = @intCast(value & 0xFFFF_FFFF);
    const hi: u32 = @intCast(value >> 32);
    storeU32LE(off, lo);
    storeU32LE(off + 4, hi);
}

fn renderImpl(input_size_in: u32) u32 {
    var input_size = input_size_in;
    if (input_size > INPUT_CAP) {
        input_size = @intCast(INPUT_CAP);
    }
    if (input_size < 54) {
        return 0;
    }
    if (input_buf[0] != 'B' or input_buf[1] != 'M') {
        return 0;
    }

    const pixel_offset = readU32LE(10);
    const dib_size = readU32LE(14);
    if (pixel_offset < 54 or dib_size < 40) {
        return 0;
    }

    const width = readI32LE(18);
    const height = readI32LE(22);
    const planes = readU16LE(26);
    const bpp = readU16LE(28);
    const compression = readU32LE(30);

    if (planes != 1 or bpp != 32 or compression != 0) {
        return 0;
    }
    if (width <= 0 or height == 0) {
        return 0;
    }

    var top_down = false;
    var abs_height: u32 = @intCast(height);
    if (height < 0) {
        top_down = true;
        abs_height = @intCast(-height);
    }

    const uwidth: u32 = @intCast(width);
    const src_stride: u32 = uwidth * 4;
    const src_pixels: u64 = @as(u64, src_stride) * @as(u64, abs_height);
    if (@as(u64, pixel_offset) + src_pixels > input_size) {
        return 0;
    }

    const out_width: u32 = uwidth * 2;
    const out_height: u32 = abs_height * 2;
    const out_stride: u32 = out_width * 4;
    const out_pixels: u64 = @as(u64, out_stride) * @as(u64, out_height);
    const out_size: u64 = @as(u64, pixel_offset) + out_pixels;
    if (out_size > OUTPUT_CAP) {
        return 0;
    }

    var i: u32 = 0;
    while (i < pixel_offset) : (i += 1) {
        output_buf[@intCast(i)] = input_buf[@intCast(i)];
    }
    writeU32LE(2, @intCast(out_size));
    writeU32LE(18, out_width);
    const out_height_signed: i32 = if (top_down) -@as(i32, @intCast(out_height)) else @as(i32, @intCast(out_height));
    writeU32LE(22, @as(u32, @bitCast(out_height_signed)));
    writeU32LE(34, @intCast(out_pixels));

    const src_base: u32 = pixel_offset;
    const dst_base: u32 = pixel_offset;

    var y: u32 = 0;
    while (y < abs_height) : (y += 1) {
        const src_row: u32 = if (top_down) y else (abs_height - 1 - y);
        const out_y0: u32 = y * 2;
        const out_y1: u32 = out_y0 + 1;
        const dst_row0: u32 = if (top_down) out_y0 else (out_height - 1 - out_y0);
        const dst_row1: u32 = if (top_down) out_y1 else (out_height - 1 - out_y1);

        const src_row_ptr: u32 = src_base + src_row * src_stride;
        const dst_row_ptr0: u32 = dst_base + dst_row0 * out_stride;
        const dst_row_ptr1: u32 = dst_base + dst_row1 * out_stride;

        var x: u32 = 0;
        while (x < uwidth) : (x += 1) {
            const px_idx: u32 = src_row_ptr + x * 4;
            const b = input_buf[@intCast(px_idx)];
            const g = input_buf[@intCast(px_idx + 1)];
            const r = input_buf[@intCast(px_idx + 2)];
            const a = input_buf[@intCast(px_idx + 3)];

            const out_x: u32 = x * 2;
            const d0: u32 = dst_row_ptr0 + out_x * 4;
            const d1: u32 = dst_row_ptr1 + out_x * 4;

            const pixel: u32 = @as(u32, b) | (@as(u32, g) << 8) |
                (@as(u32, r) << 16) | (@as(u32, a) << 24);
            const pair: u64 = @as(u64, pixel) | (@as(u64, pixel) << 32);
            storeU64LE(d0, pair);
            storeU64LE(d1, pair);
        }
    }

    return @intCast(out_size);
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
