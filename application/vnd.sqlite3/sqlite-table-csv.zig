//! Converts one user table of a SQLite database to CSV (header row of column
//! names, then one line per row). NULL becomes an empty field and blobs
//! become x'HEX'. Uniform: `?table=N` selects the table by schema-order
//! ordinal (default 0).

const std = @import("std");
const sqlite = @import("lib/sqlite.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;
const OUTPUT_CONTENT_TYPE = "text/csv";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;
var selected: sqlite.SelectedTable = .{};

var table_index: u32 = 0;

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

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

fn csvNeedsQuoting(s: []const u8) bool {
    for (s) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') return true;
    }
    return false;
}

fn writeCSVText(out: *sqlite.Output, s: []const u8) void {
    if (!csvNeedsQuoting(s)) {
        out.writeSlice(s);
        return;
    }
    out.writeByte('"');
    for (s) |c| {
        if (c == '"') out.writeByte('"');
        out.writeByte(c);
        if (out.overflow) return;
    }
    out.writeByte('"');
}

fn writeCSVValue(out: *sqlite.Output, serial: u64, data: []const u8) void {
    switch (serial) {
        0 => {}, // NULL is an empty field
        1, 2, 3, 4, 5, 6 => out.writeFmt("{d}", .{sqlite.decodeSignedBigEndian(data)}),
        7 => {
            const f = sqlite.decodeFloat64BigEndian(data) orelse return;
            out.writeFmt("{d}", .{f});
        },
        8 => out.writeSlice("0"),
        9 => out.writeSlice("1"),
        else => {
            if (serial >= 12 and (serial & 1) == 1) {
                writeCSVText(out, data);
                return;
            }
            if (serial >= 12 and (serial & 1) == 0) {
                out.writeSlice("x'");
                for (data) |b| out.writeFmt("{X:0>2}", .{b});
                out.writeByte('\'');
                return;
            }
        },
    }
}

const RowCtx = struct {
    db: *sqlite.Db,
    out: *sqlite.Output,
    ipk_column: ?usize,
};

fn onRow(ctx: RowCtx, cell: sqlite.LeafCell) bool {
    const header = sqlite.parseRecordHeader(cell.payload) orelse {
        ctx.db.setError("table row decode failed");
        return false;
    };
    var data_cursor = header.data_offset;
    var i: usize = 0;
    while (i < header.count) : (i += 1) {
        if (i > 0) ctx.out.writeByte(',');
        const serial = header.serials[i];
        const field_size = sqlite.serialTypeByteSize(serial) orelse {
            ctx.db.setError("table row decode failed");
            return false;
        };
        if (data_cursor + field_size > cell.payload.len) {
            ctx.db.setError("table row decode failed");
            return false;
        }
        const data = cell.payload[data_cursor .. data_cursor + field_size];
        // An INTEGER PRIMARY KEY column aliases the rowid: the record stores
        // NULL and the real value lives in the cell's rowid varint.
        if (serial == 0 and ctx.ipk_column != null and i == ctx.ipk_column.?) {
            ctx.out.writeFmt("{d}", .{cell.rowid});
        } else {
            writeCSVValue(ctx.out, serial, data);
        }
        data_cursor += field_size;
        if (ctx.out.overflow) return false;
    }
    ctx.out.writeByte('\n');
    return !ctx.out.overflow;
}

fn writeCSV(db: *sqlite.Db, out: *sqlite.Output) void {
    var columns: [sqlite.MAX_COLUMNS]sqlite.ColumnDecl = undefined;
    const parsed = sqlite.parseColumnsFromCreateSQL(selected.sql(), &columns);

    if (sqlite.isWithoutRowid(parsed.tail)) {
        db.setError("WITHOUT ROWID tables are not supported");
        return;
    }

    const ipk_column = sqlite.findRowidAliasColumn(columns[0..parsed.column_count], parsed.table_pk_column);

    var i: usize = 0;
    while (i < parsed.column_count) : (i += 1) {
        if (i > 0) out.writeByte(',');
        writeCSVText(out, columns[i].name);
    }
    out.writeByte('\n');

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

    writeCSV(&db, &out);
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
