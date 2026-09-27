const html_anchor = @import("html_anchor");

const INPUT_CAP: u32 = 0x100000;
const OUTPUT_CAP: u32 = 0x200000;
const CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const written = html_anchor.addWasmAnchorTypes(input_buf[0..input_size], output_buf[0..]) orelse return .{
        .output_size = 0,
        .output_ptr = 0,
        .failed = 1,
    };
    return .{
        .output_size = @intCast(written),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
