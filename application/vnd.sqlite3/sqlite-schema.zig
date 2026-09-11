//! Lists every user table in a SQLite database with its root page, column
//! names, and declared types — the coordination component that tells callers
//! which `?table=N` ordinal to pass to the other vnd.sqlite3 components.

const std = @import("std");
const sqlite = @import("lib/sqlite.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;

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

fn onTable(out: *sqlite.Output, entry: sqlite.TableEntry) bool {
    var columns: [sqlite.MAX_COLUMNS]sqlite.ColumnDecl = undefined;
    const parsed = sqlite.parseColumnsFromCreateSQL(entry.sql, &columns);

    if (entry.index > 0) out.writeByte('\n');

    out.writeSlice("table\t");
    out.writeSlice(entry.name);
    out.writeByte('\n');

    out.writeFmt("rootpage\t{d}\n", .{entry.root_page});

    out.writeSlice("columns");
    var i: usize = 0;
    while (i < parsed.column_count) : (i += 1) {
        out.writeByte('\t');
        out.writeSlice(columns[i].name);
    }
    out.writeByte('\n');

    out.writeSlice("types");
    i = 0;
    while (i < parsed.column_count) : (i += 1) {
        out.writeByte('\t');
        out.writeSlice(columns[i].decl_type);
    }
    out.writeByte('\n');

    return !out.overflow;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_u32)), INPUT_CAP);
    const input = input_buf[0..input_size];

    var out = sqlite.Output{ .buf = &output_buf };
    var db = sqlite.init(input, &payload_copy_buf) catch |e| {
        out.writeSlice("error\t");
        out.writeSlice(sqlite.initErrorMessage(e));
        out.writeByte('\n');
        return @as(u32, @intCast(out.index));
    };

    sqlite.walkTables(&db, &out, onTable);
    if (db.had_error) {
        out.writeSlice("error\t");
        out.writeSlice(db.error_msg);
        out.writeByte('\n');
    } else if (out.overflow) {
        return 0;
    }

    return @as(u32, @intCast(out.index));
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
