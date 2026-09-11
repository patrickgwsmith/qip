//! Lists regular files in a classic single-disk ZIP. Explicit directories and
//! Unix symlinks are excluded. `file_index` is a dense zero-based counter over
//! regular files in central-directory order and is the selector accepted by
//! `zip-extract-file.wasm`.
//!
//! Output columns:
//!
//!     file_index,entry_index,path,method,compressed_size,size,mode,mtime
//!
//! Input and output are capped at 128 MiB and 160 MiB. On the mixed
//! application/docs source-tree benchmark, `qip bench --benchtime=1s`
//! produced 10,725 CSV bytes in 2.93 ms mean including instantiation, with
//! 290.2 MiB peak memory. The stripped Wasm was 37,741 bytes raw and 13,923
//! bytes gzipped.

const zip = @import("lib/zip.zig");
const list = @import("lib/list-csv.zig");

const OUTPUT_CONTENT_TYPE = "text/csv";

var input_buf: [zip.INPUT_CAP]u8 = undefined;
var output_buf: [zip.OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(zip.INPUT_CAP);
}

export fn output_utf8_cap() u32 {
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

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > zip.INPUT_CAP) @trap();
    return @intCast(list.render(input_buf[0..input_size], &output_buf, true) catch @trap());
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
