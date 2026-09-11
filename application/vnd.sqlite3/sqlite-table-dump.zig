//! Dumps one user table of a SQLite database as TSV-style lines.
//! Uniforms: `?table=N` selects the table by schema-order ordinal (default 0),
//! `?limit=N` caps the number of rows (0 = all), `?offset=N` skips rows.

const std = @import("std");
const sqlite = @import("lib/sqlite.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;
var selected: sqlite.SelectedTable = .{};

var table_index: u32 = 0;
var row_limit: u32 = 0;
var row_offset: u32 = 0;

export fn uniform_set_table(v: u32) u32 {
    table_index = v;
    return table_index;
}

export fn uniform_set_limit(v: u32) u32 {
    row_limit = v;
    return row_limit;
}

export fn uniform_set_offset(v: u32) u32 {
    row_offset = v;
    return row_offset;
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

const RowCtx = struct {
    db: *sqlite.Db,
    out: *sqlite.Output,
    ipk_column: ?usize,
    skipped: u32 = 0,
    written: u32 = 0,
};

fn onRow(ctx: *RowCtx, cell: sqlite.LeafCell) bool {
    if (ctx.skipped < row_offset) {
        ctx.skipped += 1;
        return true;
    }
    if (!sqlite.writeRowTSV(ctx.out, cell, ctx.ipk_column)) {
        ctx.db.setError("table row decode failed");
        return false;
    }
    ctx.written += 1;
    if (row_limit != 0 and ctx.written >= row_limit) return false;
    return true;
}

fn writeDump(db: *sqlite.Db, out: *sqlite.Output) void {
    var columns: [sqlite.MAX_COLUMNS]sqlite.ColumnDecl = undefined;
    const parsed = sqlite.parseColumnsFromCreateSQL(selected.sql(), &columns);

    if (sqlite.isWithoutRowid(parsed.tail)) {
        db.setError("WITHOUT ROWID tables are not supported");
        return;
    }

    const ipk_column = sqlite.findRowidAliasColumn(columns[0..parsed.column_count], parsed.table_pk_column);

    out.writeSlice("table\t");
    out.writeSlice(selected.name());
    out.writeByte('\n');

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

    out.writeSlice("rows\n");
    var ctx = RowCtx{
        .db = db,
        .out = out,
        .ipk_column = ipk_column,
    };
    sqlite.walkTableRows(db, selected.root_page, &ctx, onRow);
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

    writeDump(&db, &out);
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
