//! Runs one QIP Content component with the bounded Zig Wasm interpreter and
//! reports how it initialized, read, and wrote each 64 KiB memory page.
//!
//! Input is the same `multipart/form-data` request as `qip-content-interpreter`:
//! the required `component` part, the optional `input` part, and optional
//! `uniforms[key]` parts. Output is one CSV row per page that was initialized
//! before the run, or that the target read or wrote while its uniform setters
//! and `render` ran:
//!
//! - `page`: zero-based 64 KiB page index.
//! - `region`: known ranges that overlap the page, joined with `+`: `data`
//!   segments, the `input` buffer, the shadow `stack` below global 0's initial
//!   value, and the target's `output` bytes. `other` means none of these.
//! - `initialized_bytes`: data segment and input bytes copied in before the run.
//! - `reads`: load and memory.copy source operations that touched it.
//! - `bytes_read`: bytes read, counting each reread of a byte again.
//! - `writes`: store, memory.copy, and memory.fill operations that touched it.
//! - `bytes_written`: bytes written, counting each rewrite of a byte again.
//! - `distinct_bytes_written`: bytes written at least once.
//! - `rewrite_ratio`: `bytes_written / distinct_bytes_written`, empty when the
//!   page was not written.
//!
//! A target failure, trap, exhausted budget, or rejection becomes an outer
//! rejection.

const std = @import("std");
const interpreter = @import("wasm_interpreter");
const request = @import("content_interpreter_request");

const INPUT_CAP = request.INPUT_CAP;
const CSV_HEADER = "page,region,initialized_bytes,reads,bytes_read,writes,bytes_written,distinct_bytes_written,rewrite_ratio\n";
// Longest row: 4-digit page, all four regions, five u64 counts, a 7-digit
// distinct count, and a u64 ratio with two decimals.
const ROW_CAP: usize = 4 + 1 + "data+input+stack+output".len + 5 * (1 + 20) + 1 + 7 + 1 + 23 + 1;
const OUTPUT_CAP: usize = CSV_HEADER.len + interpreter.MAX_TARGET_MEMORY_PAGES * ROW_CAP;
const OUTPUT_CONTENT_TYPE = "text/csv";

var input_content_type = request.default_content_type;
var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
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

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}

export fn output_utf8_cap() u32 {
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
    const target_output = request.run(&machine, parsed, instruction_budget) orelse return rejected();
    const csv = writeCsv(&machine, target_output, &output_buf) catch return rejected();
    return .{
        .output_size = @intCast(csv.len),
        .output_ptr = @intCast(@intFromPtr(csv.ptr)),
        .failed = 0,
    };
}

const Regions = struct {
    data: bool = false,
    input: bool = false,
    stack: bool = false,
    output: bool = false,
};

fn overlaps(page_start: usize, page_end: usize, start: usize, end: usize) bool {
    return start < end and start < page_end and page_start < end;
}

fn pageRegions(target: *const interpreter.Machine, page: usize, target_output: []const u8) Regions {
    const page_start = page * interpreter.WASM_PAGE_BYTES;
    const page_end = page_start + interpreter.WASM_PAGE_BYTES;
    var regions: Regions = .{};
    for (target.data_segments[0..target.data_segment_count]) |segment| {
        if (overlaps(page_start, page_end, segment.offset, @as(usize, segment.offset) + segment.bytes_length)) regions.data = true;
    }
    // contentContract already succeeded, so the static input getters are valid.
    if (target.inputPointer() catch null) |pointer| {
        const capacity = (target.inputCapacity() catch null) orelse 0;
        regions.input = overlaps(page_start, page_end, pointer, @as(usize, pointer) + capacity);
    }
    if (target.stackRange()) |stack| regions.stack = overlaps(page_start, page_end, stack.start, stack.end);
    const output_start = @intFromPtr(target_output.ptr) - @intFromPtr(&target.memory);
    regions.output = overlaps(page_start, page_end, output_start, output_start + target_output.len);
    return regions;
}

fn writeRegions(writer: *std.Io.Writer, regions: Regions) std.Io.Writer.Error!void {
    var first = true;
    inline for (.{ "data", "input", "stack", "output" }) |name| {
        if (@field(regions, name)) {
            if (!first) try writer.writeByte('+');
            try writer.writeAll(name);
            first = false;
        }
    }
    if (first) try writer.writeAll("other");
}

fn overlapLength(page_start: usize, page_end: usize, start: usize, end: usize) usize {
    const overlap_start = @max(page_start, start);
    const overlap_end = @min(page_end, end);
    return if (overlap_start < overlap_end) overlap_end - overlap_start else 0;
}

/// Counts data segment and input bytes that restart copied into the page.
fn pageInitializedBytes(target: *const interpreter.Machine, page: usize) u64 {
    const page_start = page * interpreter.WASM_PAGE_BYTES;
    const page_end = page_start + interpreter.WASM_PAGE_BYTES;
    var bytes: u64 = 0;
    for (target.data_segments[0..target.data_segment_count]) |segment| {
        bytes += overlapLength(page_start, page_end, segment.offset, @as(usize, segment.offset) + segment.bytes_length);
    }
    const input_start: usize = target.target_input_ptr;
    bytes += overlapLength(page_start, page_end, input_start, input_start + target.target_input.len);
    return bytes;
}

fn writeCsv(target: *const interpreter.Machine, target_output: []const u8, out: []u8) std.Io.Writer.Error![]const u8 {
    var writer = std.Io.Writer.fixed(out);
    try writer.writeAll(CSV_HEADER);
    var page: usize = 0;
    while (page < target.memory_pages) : (page += 1) {
        const initialized_bytes = pageInitializedBytes(target, page);
        if (initialized_bytes == 0 and target.memoryPageActivity(page) == .untouched) continue;
        const bytes_written = target.memory_page_bytes_written[page];
        const distinct_bytes = target.memoryPageDistinctBytesWritten(page);
        try writer.print("{d},", .{page});
        try writeRegions(&writer, pageRegions(target, page, target_output));
        try writer.print(",{d},{d},{d},{d},{d},{d},", .{
            initialized_bytes,
            target.memory_page_reads[page],
            target.memory_page_bytes_read[page],
            target.memory_page_writes[page],
            bytes_written,
            distinct_bytes,
        });
        if (distinct_bytes > 0) {
            // Two decimals without floats: round bytes_written * 100 / distinct.
            const ratio_hundredths = (@as(u128, bytes_written) * 100 + distinct_bytes / 2) / distinct_bytes;
            try writer.print("{d}.{d:0>2}", .{ ratio_hundredths / 100, ratio_hundredths % 100 });
        }
        try writer.writeByte('\n');
    }
    return writer.buffered();
}

test "region labels join overlapping ranges in a fixed order" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeRegions(&writer, .{ .data = true, .stack = true });
    try std.testing.expectEqualStrings("data+stack", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try writeRegions(&writer, .{});
    try std.testing.expectEqualStrings("other", writer.buffered());
}

test "overlap ignores empty ranges and touching edges" {
    try std.testing.expect(overlaps(0, 65536, 65535, 65537));
    try std.testing.expect(!overlaps(65536, 131072, 0, 65536));
    try std.testing.expect(!overlaps(0, 65536, 100, 100));
}

test "overlap length clips ranges to the page" {
    try std.testing.expectEqual(@as(usize, 1), overlapLength(0, 65536, 65535, 65537));
    try std.testing.expectEqual(@as(usize, 0), overlapLength(65536, 131072, 0, 65536));
    try std.testing.expectEqual(@as(usize, 10), overlapLength(0, 65536, 100, 110));
}
