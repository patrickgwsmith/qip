const BUFFER_CAP: usize = 60 * 1024;
const PREFIX = "url(\"";
const SUFFIX = "\")";
const INPUT_CAP: usize = (BUFFER_CAP - PREFIX.len - SUFFIX.len) / 3;
const INPUT_CONTENT_TYPE = "text/uri-list";
const OUTPUT_CONTENT_TYPE = "text/plain";
const HEX = "0123456789ABCDEF";

var buffer: [BUFFER_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&buffer));
}

export fn input_utf8_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_utf8_cap() u32 {
    return @intCast(BUFFER_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

fn mustEscape(byte: u8) bool {
    return byte == '"' or byte == '\'' or byte == '\\' or byte <= 0x1F or byte == 0x7F;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP or input_size < 5) @trap();
    const std = @import("std");
    if (!std.mem.eql(u8, buffer[0..5], "data:")) @trap();
    if (std.mem.indexOfScalar(u8, buffer[5..input_size], ',') == null) @trap();

    var encoded_size: usize = 0;
    for (buffer[0..input_size]) |byte| encoded_size += if (mustEscape(byte)) 3 else 1;
    const output_size = PREFIX.len + encoded_size + SUFFIX.len;
    if (output_size > BUFFER_CAP) @trap();

    @memcpy(buffer[output_size - SUFFIX.len .. output_size], SUFFIX);
    var read = input_size;
    var write = output_size - SUFFIX.len;
    while (read > 0) {
        read -= 1;
        const byte = buffer[read];
        if (mustEscape(byte)) {
            write -= 1;
            buffer[write] = HEX[byte & 0x0F];
            write -= 1;
            buffer[write] = HEX[byte >> 4];
            write -= 1;
            buffer[write] = '%';
        } else {
            write -= 1;
            buffer[write] = byte;
        }
    }
    @memcpy(buffer[0..PREFIX.len], PREFIX);
    return @intCast(output_size);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&buffer)),
        .failed = 0,
    };
}
