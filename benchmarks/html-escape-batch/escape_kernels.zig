// Hand-written code shapes for HTML escaping many pages at once, to time
// before teaching wgsl-to-wasm to emit any of them.
//
// Every kernel reads pages from `in_buf` using the `pages` table and writes
// page p's escaped bytes to `out_buf[pages[p].out_off ..][0..out_len]`.
// The host sets in_off, in_len and out_off; kernels set out_len.
//
// - run_lut:      one page at a time, branchless table lookup per byte.
// - run_block:    one page at a time, 16-byte blocks; a block with no
//                 & < > " ' is copied with one v128 store.
// - run_lanes16:  16 pages at a time, one per i8x16 lane (cross-input
//                 batching). Byte i of all 16 pages is gathered into a
//                 vector, classified with i8x16 compares and selects, and
//                 each lane's entity is stored at that lane's own cursor.
// - run_lanes16_interleaved: the same, but the host has already transposed
//                 the group so byte i of its 16 pages is one v128 load.
const std = @import("std");

const IN_CAP: usize = 8 << 20;
const OUT_CAP: usize = 64 << 20;
const MAX_PAGES: usize = 1024;

pub const Page = extern struct { in_off: u32, in_len: u32, out_off: u32, out_len: u32 };

var in_buf: [IN_CAP]u8 align(16) = undefined;
var il_buf: [IN_CAP * 2]u8 align(16) = undefined;
var out_buf: [OUT_CAP]u8 align(16) = undefined;
var pages: [MAX_PAGES]Page = undefined;

export fn in_ptr() u32 {
    return @intCast(@intFromPtr(&in_buf));
}
export fn il_ptr() u32 {
    return @intCast(@intFromPtr(&il_buf));
}
export fn out_ptr() u32 {
    return @intCast(@intFromPtr(&out_buf));
}
export fn pages_ptr() u32 {
    return @intCast(@intFromPtr(&pages));
}

// Entity bytes packed little-endian into a u64, and their lengths.
const ent: [256]u64 = blk: {
    var t: [256]u64 = undefined;
    for (&t, 0..) |*e, b| e.* = b;
    t['&'] = std.mem.readInt(u40, "&amp;", .little);
    t['<'] = std.mem.readInt(u32, "&lt;", .little);
    t['>'] = std.mem.readInt(u32, "&gt;", .little);
    t['"'] = std.mem.readInt(u48, "&quot;", .little);
    t['\''] = std.mem.readInt(u40, "&#39;", .little);
    break :blk t;
};
const elen: [256]u8 = blk: {
    var t = [_]u8{1} ** 256;
    t['&'] = 5;
    t['<'] = 4;
    t['>'] = 4;
    t['"'] = 6;
    t['\''] = 5;
    break :blk t;
};

inline fn lutByte(out: [*]u8, o: usize, b: u8) usize {
    std.mem.writeInt(u64, out[o..][0..8], ent[b], .little);
    return o + elen[b];
}

fn escapeLut(in: []const u8, out: [*]u8) usize {
    var o: usize = 0;
    for (in) |b| o = lutByte(out, o, b);
    return o;
}

const V = @Vector(16, u8);

inline fn special(v: V) @Vector(16, bool) {
    const z: V = @splat(0);
    const ff: V = @splat(0xff);
    const m = @select(u8, v == @as(V, @splat('&')), ff, z) |
        @select(u8, v == @as(V, @splat('<')), ff, z) |
        @select(u8, v == @as(V, @splat('>')), ff, z) |
        @select(u8, v == @as(V, @splat('"')), ff, z) |
        @select(u8, v == @as(V, @splat('\'')), ff, z);
    return m != z;
}

fn escapeBlock(in: []const u8, out: [*]u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i + 16 <= in.len) : (i += 16) {
        const v: V = in[i..][0..16].*;
        if (!@reduce(.Or, special(v))) {
            out[o..][0..16].* = v;
            o += 16;
            continue;
        }
        inline for (0..16) |k| o = lutByte(out, o, in[i + k]);
    }
    while (i < in.len) : (i += 1) o = lutByte(out, o, in[i]);
    return o;
}

export fn run_lut(n: u32) void {
    for (pages[0..n]) |*p| p.out_len = @intCast(escapeLut(in_buf[p.in_off..][0..p.in_len], out_buf[p.out_off..].ptr));
}

export fn run_block(n: u32) void {
    for (pages[0..n]) |*p| p.out_len = @intCast(escapeBlock(in_buf[p.in_off..][0..p.in_len], out_buf[p.out_off..].ptr));
}

// What the WGSL shader computes per invocation, 16 invocations wide: entity
// words and lengths come from compares and selects (a const array lookup
// would stop wgsl-to-wasm vectorizing), inactive lanes get length 0.
const W = @Vector(16, u32);

inline fn storeLanes(v: V, active: @Vector(16, bool), cur: *[16]u32) void {
    const w: W = v;
    const amp = v == @as(V, @splat('&'));
    const lt = v == @as(V, @splat('<'));
    const gt = v == @as(V, @splat('>'));
    const qt = v == @as(V, @splat('"'));
    const ap = v == @as(V, @splat('\''));
    const s = std.mem.readInt;
    var lo: W = w;
    lo = @select(u32, amp, @as(W, @splat(s(u32, "&amp", .little))), lo);
    lo = @select(u32, lt, @as(W, @splat(s(u32, "&lt;", .little))), lo);
    lo = @select(u32, gt, @as(W, @splat(s(u32, "&gt;", .little))), lo);
    lo = @select(u32, qt, @as(W, @splat(s(u32, "&quo", .little))), lo);
    lo = @select(u32, ap, @as(W, @splat(s(u32, "&#39", .little))), lo);
    var hi: W = @splat(0);
    hi = @select(u32, amp, @as(W, @splat(';')), hi);
    hi = @select(u32, qt, @as(W, @splat(s(u16, "t;", .little))), hi);
    hi = @select(u32, ap, @as(W, @splat(';')), hi);
    var len: W = @splat(1);
    len = @select(u32, amp, @as(W, @splat(5)), len);
    len = @select(u32, lt, @as(W, @splat(4)), len);
    len = @select(u32, gt, @as(W, @splat(4)), len);
    len = @select(u32, qt, @as(W, @splat(6)), len);
    len = @select(u32, ap, @as(W, @splat(5)), len);
    len = @select(u32, active, len, @as(W, @splat(0)));
    // The scatter: wasm SIMD has no scattered store, so each lane is
    // extracted and stored at its own cursor.
    const ob: [*]u8 = &out_buf;
    inline for (0..16) |l| {
        const o = cur[l];
        std.mem.writeInt(u32, ob[o..][0..4], lo[l], .little);
        std.mem.writeInt(u32, ob[o + 4 ..][0..4], hi[l], .little);
        cur[l] = o + len[l];
    }
}

fn group16(g: []Page, comptime interleaved: bool, il_off: usize) void {
    var cur: [16]u32 = @splat(0);
    var lens: W = @splat(0);
    var offs: [16]u32 = @splat(0);
    var maxlen: u32 = 0;
    for (g, 0..) |p, l| {
        cur[l] = p.out_off;
        lens[l] = p.in_len;
        offs[l] = p.in_off;
        maxlen = @max(maxlen, p.in_len);
    }
    // Unused lanes write into a scratch area past every page.
    for (g.len..16) |l| cur[l] = @intCast(OUT_CAP - 16 * 8 + l * 8);
    const ib: [*]const u8 = &in_buf;
    const il: [*]const u8 = &il_buf;
    var i: u32 = 0;
    while (i < maxlen) : (i += 1) {
        const active = @as(W, @splat(i)) < lens;
        var v: V = undefined;
        if (interleaved) {
            v = il[il_off + @as(usize, i) * 16 ..][0..16].*;
        } else {
            // The gather: one scalar load per lane, masked past each page.
            inline for (0..16) |l| v[l] = if (i < lens[l]) ib[offs[l] + i] else 0;
        }
        storeLanes(v, active, &cur);
    }
    for (g, 0..) |*p, l| p.out_len = cur[l] - p.out_off;
}

export fn run_lanes16(n: u32) void {
    var s: u32 = 0;
    while (s < n) : (s += 16) group16(pages[s..@min(n, s + 16)], false, 0);
}

// `il_offs[g]` is where group g's transposed bytes start in il_buf.
var il_offs: [MAX_PAGES / 16 + 1]u32 = undefined;
export fn il_offs_ptr() u32 {
    return @intCast(@intFromPtr(&il_offs));
}

export fn run_lanes16_interleaved(n: u32) void {
    var s: u32 = 0;
    while (s < n) : (s += 16) group16(pages[s..@min(n, s + 16)], true, il_offs[s / 16]);
}
