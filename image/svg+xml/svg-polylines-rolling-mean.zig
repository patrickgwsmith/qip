//! Applies a trailing rolling arithmetic mean to every `polyline` in the strict
//! time-series SVG subset emitted by `time-series-csv-to-svg-polylines.wasm`.
//! Input and output are `image/svg+xml`. `window_size` is a positive count of
//! samples. The component preserves every non-polyline byte and replaces each
//! polyline's raw value-space y values.
const smoothing = @import("polyline_smoothing");
const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 256 * 1024;
const INPUT_CONTENT_TYPE = "image/svg+xml";
var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var window_size: u32 = 7;
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
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn uniform_set_window_size(value: u32) u32 {
    window_size = value;
    return value;
}
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const out_n = smoothing.smooth(input[0..n], &output, .rolling_mean, window_size) catch {
        window_size = 7;
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    window_size = 7;
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
