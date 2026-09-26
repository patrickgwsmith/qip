const CAP: usize = 65536;
var input: [CAP]u8 = undefined;
var output: [CAP]u8 = undefined;

export fn input_ptr() u32 { return @intCast(@intFromPtr(&input)); }
export fn input_utf8_cap() u32 { return CAP; }
export fn output_bytes_cap() u32 { return CAP; }
export fn failure_modes_per_input_offset() u32 { return 1; }

fn value(c: u8) i32 {
    if (c >= 'A' and c <= 'Z') return @as(i32, c) - 'A';
    if (c >= 'a' and c <= 'z') return @as(i32, c) - 'a' + 26;
    if (c >= '0' and c <= '9') return @as(i32, c) - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

fn fail(offset: usize) u64 { return (@as(u64, 1) << 63) | @as(u64, @intCast(offset)); }

export fn render(size: u32) u64 {
    if (size > CAP) @trap();
    if (size & 3 != 0) return fail(size);
    var out: usize = 0;
    var i: usize = 0;
    while (i < size) : (i += 4) {
        const a = value(input[i]);
        if (a < 0) return fail(i);
        const b = value(input[i + 1]);
        if (b < 0) return fail(i + 1);
        const c = input[i + 2];
        const d = input[i + 3];
        if (c == '=') {
            if (d != '=' or i + 4 != size) return fail(i + 2);
            if (b & 15 != 0) return fail(i + 1);
            output[out] = @intCast((a << 2) | (b >> 4));
            out += 1;
            break;
        }
        const cv = value(c);
        if (cv < 0) return fail(i + 2);
        if (d == '=') {
            if (i + 4 != size) return fail(i + 3);
            if (cv & 3 != 0) return fail(i + 2);
            output[out] = @intCast((a << 2) | (b >> 4));
            output[out + 1] = @intCast(((b << 4) | (cv >> 2)) & 255);
            out += 2;
            break;
        }
        const dv = value(d);
        if (dv < 0) return fail(i + 3);
        output[out] = @intCast((a << 2) | (b >> 4));
        output[out + 1] = @intCast(((b << 4) | (cv >> 2)) & 255);
        output[out + 2] = @intCast(((cv << 6) | dv) & 255);
        out += 3;
    }
    return (@as(u64, @intCast(@intFromPtr(&output))) << 32) | out;
}
