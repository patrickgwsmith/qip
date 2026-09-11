//! Extracts one regular file from a classic single-disk ZIP. The
//! `?file_index=N` uniform selects the Nth regular file in central-directory
//! order, matching `zip-list-files-csv.wasm`; explicit directories and Unix
//! symlinks do not consume file indices. The default is file index zero.
//!
//! The complete archive structure is validated before extraction. The chosen
//! stored or raw-DEFLATE body must match its declared size and CRC-32 exactly.
//! Output is `application/octet-stream` because ZIP does not carry a reliable
//! media type for each entry.
//!
//! Input and output are capped at 128 MiB and 160 MiB. Extracting file zero
//! from the mixed application/docs source-tree benchmark took 6.43 ms mean
//! including instantiation, with 290.3 MiB peak memory. The stripped Wasm was
//! 39,857 bytes raw and 14,317 bytes gzipped.

const zip = @import("lib/zip.zig");

const OUTPUT_CONTENT_TYPE = "application/octet-stream";

var input_buf: [zip.INPUT_CAP]u8 = undefined;
var output_buf: [zip.OUTPUT_CAP]u8 = undefined;
var selected_file_index: u32 = 0;

export fn uniform_set_file_index(file_index: u32) u32 {
    selected_file_index = file_index;
    return selected_file_index;
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(zip.INPUT_CAP);
}

export fn output_bytes_cap() u32 {
    return @intCast(zip.OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(zip.INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(zip.INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

fn extract(input: []const u8, output: []u8, wanted: u32) zip.Error!usize {
    var selected: ?zip.Entry = null;
    var reader = try zip.Reader.init(input);
    while (try reader.next()) |entry| {
        if (entry.file_index != null and entry.file_index.? == wanted) selected = entry;
    }
    try reader.finish();
    const entry = selected orelse return error.InvalidZip;
    if (entry.uncompressed_size > output.len) return error.OutputOverflow;
    const body = output[0..entry.uncompressed_size];
    try zip.extractBody(input, entry, body);
    return body.len;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > zip.INPUT_CAP) @trap();
    return @intCast(extract(input_buf[0..input_size], &output_buf, selected_file_index) catch @trap());
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
