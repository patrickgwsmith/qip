//! Runs one QIP Content component with the bounded Zig Wasm interpreter.
//!
//! Input is `multipart/form-data`: the required `component` part contains the
//! target `application/wasm` bytes and the optional `input` part contains its
//! exact Content input. Optional `uniforms[key]` parts configure the target.
//! Successful output is the target's raw output bytes.
//! The wrapper declares `application/octet-stream` because QIP content-type
//! metadata is static while the nested component's type is known only at run
//! time.

const std = @import("std");
const interpreter = @import("wasm_interpreter");
const request = @import("content_interpreter_request");

const INPUT_CAP = request.INPUT_CAP;
const OUTPUT_CAP: usize = interpreter.MAX_TARGET_MEMORY_BYTES;
const OUTPUT_CONTENT_TYPE = "application/octet-stream";

var input_content_type = request.default_content_type;
var input_buf: [INPUT_CAP]u8 = undefined;
var machine: interpreter.Machine = undefined;
var instruction_budget: u32 = request.DEFAULT_INSTRUCTION_BUDGET;

const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

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
    return @intCast(@intFromPtr(&input_content_type));
}

export fn input_content_type_size() u32 {
    return input_content_type.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn uniform_set_instruction_budget(value: u32) u32 {
    instruction_budget = std.math.clamp(value, 1, request.MAX_INSTRUCTION_BUDGET);
    return instruction_budget;
}

fn rejected() RenderResult {
    return .{ .output_size = 0, .output_ptr = 0, .failed = 1 };
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    defer instruction_budget = request.DEFAULT_INSTRUCTION_BUDGET;

    const parsed = request.parse(input_buf[0..input_size], &input_content_type) catch return rejected();
    const bytes = request.run(&machine, parsed, instruction_budget) orelse return rejected();
    return .{
        .output_size = @intCast(bytes.len),
        .output_ptr = @intCast(@intFromPtr(bytes.ptr)),
        .failed = 0,
    };
}
