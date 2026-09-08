//! wasm-counts: static, factual counts for comparing WebAssembly modules.
//!
//! Input is a WebAssembly module. Output is deterministic long-form CSV with
//! one integer metric per row. Counts are deliberately not scores or policy
//! verdicts: callers can load the CSV into SQLite, DuckDB, a spreadsheet, or
//! their own CI analysis.

const std = @import("std");
const wasm_counts = @import("lib/wasm-counts.zig");
const wasm_reader = @import("lib/wasm-reader.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/csv";
const CSV_HEADER = "metric,value\n";
const MAX_U64_DECIMAL_DIGITS = 20;

const METRIC_NAMES = .{
    "module_bytes",
    "sections",
    "custom_sections",
    "types",
    "v128_types",
    "exports",
    "functions_exported",
    "tables_exported",
    "memories_exported",
    "globals_exported",
    "tags_exported",
    "functions_defined",
    "functions_imported",
    "tables_defined",
    "tables_imported",
    "tables_funcref",
    "tables_externref",
    "tables_typed_reference",
    "tables_table64",
    "tables_with_maximum",
    "tables_fixed_size",
    "table_initial_slots",
    "table_maximum_slots",
    "element_segments",
    "active_element_segments",
    "passive_element_segments",
    "declarative_element_segments",
    "active_element_segments_table_zero",
    "active_element_segments_nonzero_table",
    "active_element_offsets_i32_const_zero",
    "active_element_offsets_i32_const_one",
    "active_element_offsets_i32_const_other",
    "active_element_offsets_global_get",
    "active_element_offsets_other",
    "element_initializers",
    "active_element_initializers",
    "element_function_index_initializers",
    "element_expression_initializers",
    "globals_defined",
    "globals_imported",
    "memories_defined",
    "memories_imported",
    "memories_memory64",
    "memories_shared",
    "memories_with_maximum",
    "memory_initial_pages",
    "memory_initial_bytes",
    "memory_maximum_pages",
    "memory_maximum_bytes",
    "data_segments",
    "active_data_segments",
    "data_bytes",
    "active_data_bytes",
    "instructions",
    "function_instructions",
    "loops",
    "branches",
    "conditional_branches",
    "br_table_targets",
    "calls_direct_local",
    "calls_direct_imported",
    "calls_indirect",
    "call_indirect",
    "return_call_indirect",
    "call_ref",
    "indirect_calls_table_zero",
    "indirect_calls_nonzero_table",
    "table_get",
    "table_set",
    "table_init",
    "elem_drop",
    "table_copy",
    "table_grow",
    "table_size",
    "table_fill",
    "ref_null",
    "ref_is_null",
    "ref_func",
    "simd_instructions",
    "memory_loads",
    "memory_stores",
    "memory_copies",
    "memory_fills",
    "explicit_traps",
    "integer_divisions",
    "integer_remainders",
    "trapping_float_to_int",
    "potentially_trapping_memory",
    "potentially_trapping_table",
    "potentially_trapping_instructions",
};

const OUTPUT_CAP: usize = blk: {
    var capacity = CSV_HEADER.len;
    for (METRIC_NAMES) |name| {
        capacity += name.len + 1 + MAX_U64_DECIMAL_DIGITS + 1;
    }
    break :blk capacity;
};

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Writer = struct {
    off: usize = 0,

    fn write(self: *Writer, bytes: []const u8) void {
        @memcpy(output_buf[self.off..][0..bytes.len], bytes);
        self.off += bytes.len;
    }

    fn writeU64(self: *Writer, value: u64) void {
        var decimal: [MAX_U64_DECIMAL_DIGITS]u8 = undefined;
        var remaining = value;
        var start = decimal.len;
        if (remaining == 0) {
            start -= 1;
            decimal[start] = '0';
        } else {
            while (remaining != 0) {
                start -= 1;
                const digit: u8 = @intCast(remaining % 10);
                decimal[start] = '0' + digit;
                remaining /= 10;
            }
        }
        self.write(decimal[start..]);
    }

    fn row(self: *Writer, comptime name: []const u8, value: u64) void {
        self.write(name ++ ",");
        self.writeU64(value);
        self.write("\n");
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn metricValue(counts: wasm_counts.Counts, comptime name: []const u8) u64 {
    if (comptime std.mem.eql(u8, name, "memory_initial_bytes"))
        return counts.memory_initial_pages *| 65536;
    if (comptime std.mem.eql(u8, name, "memory_maximum_bytes"))
        return counts.memory_maximum_pages *| 65536;
    return @field(counts, name);
}

fn renderCsv(counts: wasm_counts.Counts) usize {
    var w = Writer{};
    w.write(CSV_HEADER);
    inline for (METRIC_NAMES) |name| {
        w.row(name, metricValue(counts, name));
    }
    return w.off;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    const counts = wasm_counts.analyze(input_buf[0..input_size]) catch @trap();
    return @intCast(renderCsv(counts));
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

test "reports semantic, SIMD, trapping, memory, and table counts as CSV" {
    const body = [_]u8{
        0x03, 0x40, // loop
        0x41, 0x08, 0x41, 0x02, 0x6d, 0x1a, // i32.div_s; drop
        0x41, 0x00, 0x28, 0x02, 0x00, 0x1a, // i32.load; drop
        0x41, 0x00, 0x41, 0x01, 0x36, 0x02, 0x00, // i32.store
        0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0a, 0x00, 0x00, // memory.copy
        0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0b, 0x00, // memory.fill
        0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // v128.const
        0x1a, 0x0b, 0x0b, // drop; end loop; end function
    };
    const module = wasm_reader.moduleWithBody(&body);
    const counts = try wasm_counts.analyze(&module);
    try std.testing.expectEqual(@as(u64, 1), counts.functions_defined);
    try std.testing.expectEqual(@as(u64, 1), counts.memories_defined);
    try std.testing.expectEqual(@as(u64, 1), counts.memory_initial_pages);
    try std.testing.expectEqual(@as(u64, 1), counts.loops);
    try std.testing.expectEqual(@as(u64, 1), counts.simd_instructions);
    try std.testing.expectEqual(@as(u64, 1), counts.memory_loads);
    try std.testing.expectEqual(@as(u64, 1), counts.memory_stores);
    try std.testing.expectEqual(@as(u64, 1), counts.memory_copies);
    try std.testing.expectEqual(@as(u64, 1), counts.memory_fills);
    try std.testing.expectEqual(@as(u64, 5), counts.potentially_trapping_instructions);

    const out_len = renderCsv(counts);
    const csv = output_buf[0..out_len];
    try std.testing.expect(std.mem.indexOf(u8, csv, "metric,value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "function_instructions,") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "simd_instructions,1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "memory_loads,1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "element_initializers,0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "explicit_traps,0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "integer_divisions,1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "integer_remainders,0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "trapping_float_to_int,0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "potentially_trapping_memory,4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "potentially_trapping_table,0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "potentially_trapping_instructions,5\n") != null);
}

test "comptime output capacity fits maximum decimal values exactly" {
    var counts = wasm_counts.Counts{};
    inline for (std.meta.fields(wasm_counts.Counts)) |field| {
        @field(counts, field.name) = std.math.maxInt(u64);
    }
    try std.testing.expectEqual(OUTPUT_CAP, renderCsv(counts));
}

test "counts declared table capacity and active element initializers" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // () -> () type
        0x03, 0x02, 0x01, 0x00, // one function
        0x04, 0x05, 0x01, 0x70, 0x01, 0x02, 0x04, // funcref table min 2, max 4
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, // active element[0] = function 0
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // empty function body
    };
    const counts = try wasm_counts.analyze(&module);
    try std.testing.expectEqual(@as(u64, 1), counts.tables_defined);
    try std.testing.expectEqual(@as(u64, 1), counts.tables_funcref);
    try std.testing.expectEqual(@as(u64, 0), counts.tables_externref);
    try std.testing.expectEqual(@as(u64, 1), counts.tables_with_maximum);
    try std.testing.expectEqual(@as(u64, 0), counts.tables_fixed_size);
    try std.testing.expectEqual(@as(u64, 2), counts.table_initial_slots);
    try std.testing.expectEqual(@as(u64, 4), counts.table_maximum_slots);
    try std.testing.expectEqual(@as(u64, 1), counts.element_segments);
    try std.testing.expectEqual(@as(u64, 1), counts.active_element_segments);
    try std.testing.expectEqual(@as(u64, 1), counts.active_element_segments_table_zero);
    try std.testing.expectEqual(@as(u64, 1), counts.element_initializers);
    try std.testing.expectEqual(@as(u64, 1), counts.active_element_initializers);
    try std.testing.expectEqual(@as(u64, 1), counts.element_function_index_initializers);
}

test "counts table reference types and fixed limits" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x09, 0x02,
        0x70, 0x01, 0x02, 0x04, // funcref, min 2, max 4
        0x6f, 0x01, 0x03, 0x03, // externref, fixed at 3
    };
    const counts = try wasm_counts.analyze(&module);
    try std.testing.expectEqual(@as(u64, 2), counts.tables_defined);
    try std.testing.expectEqual(@as(u64, 1), counts.tables_funcref);
    try std.testing.expectEqual(@as(u64, 1), counts.tables_externref);
    try std.testing.expectEqual(@as(u64, 0), counts.tables_typed_reference);
    try std.testing.expectEqual(@as(u64, 2), counts.tables_with_maximum);
    try std.testing.expectEqual(@as(u64, 1), counts.tables_fixed_size);
    try std.testing.expectEqual(@as(u64, 5), counts.table_initial_slots);
    try std.testing.expectEqual(@as(u64, 7), counts.table_maximum_slots);
}

test "counts element segment modes, targets, and initializer encodings" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x09, 0x17, 0x04,
        0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, // active, implicit table 0
        0x01, 0x00, 0x01, 0x00, // passive
        0x03, 0x00, 0x01, 0x00, // declarative
        0x02, 0x01, 0x41, 0x00, 0x0b, 0x00, 0x01, 0x00, // active, table 1
    };
    const counts = try wasm_counts.analyze(&module);
    try std.testing.expectEqual(@as(u64, 4), counts.element_segments);
    try std.testing.expectEqual(@as(u64, 2), counts.active_element_segments);
    try std.testing.expectEqual(@as(u64, 1), counts.passive_element_segments);
    try std.testing.expectEqual(@as(u64, 1), counts.declarative_element_segments);
    try std.testing.expectEqual(@as(u64, 1), counts.active_element_segments_table_zero);
    try std.testing.expectEqual(@as(u64, 1), counts.active_element_segments_nonzero_table);
    try std.testing.expectEqual(@as(u64, 2), counts.active_element_offsets_i32_const_zero);
    try std.testing.expectEqual(@as(u64, 0), counts.active_element_offsets_i32_const_one);
    try std.testing.expectEqual(@as(u64, 4), counts.element_initializers);
    try std.testing.expectEqual(@as(u64, 2), counts.active_element_initializers);
    try std.testing.expectEqual(@as(u64, 4), counts.element_function_index_initializers);
    try std.testing.expectEqual(@as(u64, 0), counts.element_expression_initializers);
}

test "counts indirect calls, table instructions, and reference instructions separately" {
    const body = [_]u8{
        0x11, 0x00, 0x00, // call_indirect type 0 table 0
        0x13, 0x00, 0x01, // return_call_indirect type 0 table 1
        0x14, 0x00, // call_ref type 0
        0x25, 0x00, // table.get 0
        0x26, 0x00, // table.set 0
        0xd0, 0x70, // ref.null func
        0xd1, // ref.is_null
        0xd2, 0x00, // ref.func 0
        0xfc, 0x0c, 0x00, 0x00, // table.init 0 0
        0xfc, 0x0d, 0x00, // elem.drop 0
        0xfc, 0x0e, 0x00, 0x00, // table.copy 0 0
        0xfc, 0x0f, 0x00, // table.grow 0
        0xfc, 0x10, 0x00, // table.size 0
        0xfc, 0x11, 0x00, // table.fill 0
        0x0b,
    };
    const module = wasm_reader.moduleWithBody(&body);
    const counts = try wasm_counts.analyze(&module);
    try std.testing.expectEqual(@as(u64, 3), counts.calls_indirect);
    try std.testing.expectEqual(@as(u64, 1), counts.call_indirect);
    try std.testing.expectEqual(@as(u64, 1), counts.return_call_indirect);
    try std.testing.expectEqual(@as(u64, 1), counts.call_ref);
    try std.testing.expectEqual(@as(u64, 1), counts.indirect_calls_table_zero);
    try std.testing.expectEqual(@as(u64, 1), counts.indirect_calls_nonzero_table);
    try std.testing.expectEqual(@as(u64, 1), counts.table_get);
    try std.testing.expectEqual(@as(u64, 1), counts.table_set);
    try std.testing.expectEqual(@as(u64, 1), counts.table_init);
    try std.testing.expectEqual(@as(u64, 1), counts.elem_drop);
    try std.testing.expectEqual(@as(u64, 1), counts.table_copy);
    try std.testing.expectEqual(@as(u64, 1), counts.table_grow);
    try std.testing.expectEqual(@as(u64, 1), counts.table_size);
    try std.testing.expectEqual(@as(u64, 1), counts.table_fill);
    try std.testing.expectEqual(@as(u64, 1), counts.ref_null);
    try std.testing.expectEqual(@as(u64, 1), counts.ref_is_null);
    try std.testing.expectEqual(@as(u64, 1), counts.ref_func);
}
