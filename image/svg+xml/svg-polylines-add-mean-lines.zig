//! Adds one horizontal dashed arithmetic-mean line for every `polyline` in
//! the strict time-series SVG subset emitted by
//! `time-series-csv-to-svg-polylines.wasm`. Input and output are
//! `image/svg+xml`. Run this component after an optional smoothing pass when
//! the mean should describe the smoothed values.
const smoothing = @import("polyline_smoothing");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 512 * 1024;
const CONTENT_TYPE = "image/svg+xml";

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn failure_modes_per_input_offset() u32 {
    return 0;
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
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const out_n = smoothing.addMeanLines(input[0..n], &output) catch return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
