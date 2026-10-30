//! Hand-written ROT13 Content component with 16-byte SIMD, as the CPU baseline.
const CAP: usize = 4 * 1024 * 1024;

var input_buf: [CAP]u8 align(16) = undefined;
var output_buf: [CAP]u8 align(16) = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_bytes_cap() u32 {
    return CAP;
}
export fn output_bytes_cap() u32 {
    return CAP;
}

const V = @Vector(16, u8);

fn rotVec(b: V) V {
    const k = (b | @as(V, @splat(0x20))) -% @as(V, @splat(97));
    const letter = k < @as(V, @splat(26));
    const low = k < @as(V, @splat(13));
    const d = @select(u8, low, @as(V, @splat(13)), @as(V, @splat(256 - 13)));
    return b +% @select(u8, letter, d, @as(V, @splat(0)));
}

fn renderImpl(input_size: u32) u32 {
    const n: usize = input_size;
    if (n > CAP) @trap();
    const in: []const u8 = input_buf[0..n];
    const out: []u8 = output_buf[0..n];
    var i: usize = 0;
    while (i + 16 <= n) : (i += 16) {
        const v: V = in[i..][0..16].*;
        out[i..][0..16].* = rotVec(v);
    }
    while (i < n) : (i += 1) {
        const b = in[i];
        const k = (b | 0x20) -% 97;
        out[i] = if (k < 13) b + 13 else if (k < 26) b - 13 else b;
    }
    return input_size;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
