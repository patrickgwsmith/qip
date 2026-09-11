//! Lists every actual central-directory entry in a classic single-disk ZIP.
//! Explicit directories and Unix symlinks are included; implied parent
//! directories are not synthesized. `entry_index` is the zero-based central
//! directory ordinal. Regular files also receive a dense `file_index`.
//!
//! Output columns:
//!
//!     entry_index,file_index,path,type,method,compressed_size,size,mode,mtime
//!
//! Input and output are capped at 128 MiB and 160 MiB. On the mixed
//! application/docs source-tree benchmark (553,864-byte ZIP, 137 explicit
//! entries), `qip bench --benchtime=1s` produced 12,212 CSV bytes in 3.08 ms
//! mean including instantiation, with 290.2 MiB peak memory. The stripped Wasm
//! was 38,004 bytes raw and 14,121 bytes gzipped.

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
    return @intCast(list.render(input_buf[0..input_size], &output_buf, false) catch @trap());
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
