//! Dumps the first user table of a SQLite database as TSV-style lines:
//! table/columns/types header lines followed by one line per row.

const std = @import("std");
const sqlite = @import("lib/sqlite.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;
var selected: sqlite.SelectedTable = .{};

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
};

fn onRow(ctx: RowCtx, cell: sqlite.LeafCell) bool {
    if (!sqlite.writeRowTSV(ctx.out, cell, ctx.ipk_column)) {
        ctx.db.setError("table row decode failed");
        return false;
    }
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
    sqlite.walkTableRows(db, selected.root_page, RowCtx{
        .db = db,
        .out = out,
        .ipk_column = ipk_column,
    }, onRow);
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

    sqlite.selectTable(&db, 0, &selected);
    if (db.had_error) {
        out.writeSlice("error\t");
        out.writeSlice(db.error_msg);
        out.writeByte('\n');
        return @as(u32, @intCast(out.index));
    }
    if (!selected.found) {
        out.writeSlice("error\tno user table found\n");
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

test "dumps first table schema and rows from sqlite fixture" {
    const sqlite_bytes = @embedFile("fixtures/countries.sqlite");
    try std.testing.expect(sqlite_bytes.len <= INPUT_CAP);
    @memcpy(input_buf[0..sqlite_bytes.len], sqlite_bytes);

    const out_size = renderImpl(@as(u32, @intCast(sqlite_bytes.len)));
    try std.testing.expect(out_size > 0);
    const out = output_buf[0..@as(usize, @intCast(out_size))];

    try std.testing.expect(std.mem.indexOf(u8, out, "table\tcountries\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "columns\tiso_3166_code\tname_en\tcurrency\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "types\tTEXT\tTEXT\tTEXT\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rows\nAU\tAustralia\tAUD\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "US\tUnited States\tUSD\n") != null);
}
