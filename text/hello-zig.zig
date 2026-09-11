const std = @import("std");

// Memory layout
const INPUT_CAP: u32 = 0x10000;
const OUTPUT_CAP: u32 = 0x10000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

// Get input/output slices
fn getInput(size: u32) []u8 {
    return input_buf[0..@as(usize, @intCast(size))];
}

fn getOutput() []u8 {
    return output_buf[0..];
}

// Main entry point
fn renderImpl(input_size: u32) u32 {
    const input = getInput(input_size);
    const output = getOutput();
    const input_bytes_size: usize = @intCast(input_size);

    // Example: prepend "Hello, " to input
    const prefix = "Hello, ";
    @memcpy(output[0..prefix.len], prefix);

    const output_size: u32 = blk: {
        if (input_size > 0) {
            // Copy input after prefix
            @memcpy(output[prefix.len..][0..input_bytes_size], input);
            break :blk @intCast(prefix.len + input_bytes_size);
        } else {
            // Default to "World" if no input
            const default_name = "World";
            @memcpy(output[prefix.len..][0..default_name.len], default_name);
            break :blk @intCast(prefix.len + default_name.len);
        }
    };
    return output_size;
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
