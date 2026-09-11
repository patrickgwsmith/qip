const BUFFER_CAP: usize = 60 * 1024;
const PREFIX = "data:image/svg+xml,";
const INPUT_CAP: usize = (BUFFER_CAP - PREFIX.len) / 3;
const INPUT_CONTENT_TYPE = "image/svg+xml";
const OUTPUT_CONTENT_TYPE = "text/uri-list";
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

fn isSafe(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        switch (byte) {
            '-', '.', '_', '~', '!', '$', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?' => true,
            else => false,
        };
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();

    var encoded_size: usize = 0;
    for (buffer[0..input_size]) |byte| encoded_size += if (isSafe(byte)) 1 else 3;
    const output_size = PREFIX.len + encoded_size;
    if (output_size > BUFFER_CAP) @trap();

    var read = input_size;
    var write = output_size;
    while (read > 0) {
        read -= 1;
        const byte = buffer[read];
        if (isSafe(byte)) {
            write -= 1;
            buffer[write] = byte;
        } else {
            write -= 1;
            buffer[write] = HEX[byte & 0x0F];
            write -= 1;
            buffer[write] = HEX[byte >> 4];
            write -= 1;
            buffer[write] = '%';
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
