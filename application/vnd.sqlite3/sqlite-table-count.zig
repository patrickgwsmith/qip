//! Counts the rows of one user table (the COUNT(*) aggregate). Outputs the
//! decimal count followed by a newline. Uniform: `?table=N` selects the table
//! by schema-order ordinal (default 0).

const std = @import("std");
const sqlite = @import("lib/sqlite.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;
const DEFAULT_TABLE_INDEX: u32 = 0;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;
var selected: sqlite.SelectedTable = .{};

var table_index: u32 = DEFAULT_TABLE_INDEX;

export fn uniform_set_table(v: u32) u32 {
    table_index = v;
    return table_index;
}

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(sqlite.INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(sqlite.INPUT_CONTENT_TYPE.len));
}

fn onRow(count: *u64, cell: sqlite.LeafCell) bool {
    _ = cell;
    count.* += 1;
    return true;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > INPUT_CAP) @trap();
    const output_size = renderCount(input_buf[0..input_size]);
    table_index = DEFAULT_TABLE_INDEX;
    return output_size;
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

fn renderCount(input: []const u8) u32 {
    var out = sqlite.Output{ .buf = &output_buf };
    var db = sqlite.init(input, &payload_copy_buf) catch |e| {
        out.writeSlice("error\t");
        out.writeSlice(sqlite.initErrorMessage(e));
        out.writeByte('\n');
        return @as(u32, @intCast(out.index));
    };

    sqlite.selectTable(&db, table_index, &selected);
    if (db.had_error) {
        out.writeSlice("error\t");
        out.writeSlice(db.error_msg);
        out.writeByte('\n');
        return @as(u32, @intCast(out.index));
    }
    if (!selected.found) {
        out.writeSlice("error\ttable index out of range\n");
        return @as(u32, @intCast(out.index));
    }

    var columns: [sqlite.MAX_COLUMNS]sqlite.ColumnDecl = undefined;
    const parsed = sqlite.parseColumnsFromCreateSQL(selected.sql(), &columns);
    if (sqlite.isWithoutRowid(parsed.tail)) {
        out.writeSlice("error\tWITHOUT ROWID tables are not supported\n");
        return @as(u32, @intCast(out.index));
    }

    var count: u64 = 0;
    sqlite.walkTableRows(&db, selected.root_page, &count, onRow);
    if (db.had_error) {
        out.writeSlice("error\t");
        out.writeSlice(db.error_msg);
        out.writeByte('\n');
        return @as(u32, @intCast(out.index));
    }

    out.writeFmt("{d}\n", .{count});
    return @as(u32, @intCast(out.index));
}
