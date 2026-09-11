//! Shared read-only SQLite file-format core for the vnd.sqlite3 QIP
//! components. Rowid tables only: callers must check isWithoutRowid() on a
//! table's CREATE SQL before walking its pages.

const std = @import("std");

pub const MAX_COLUMNS: usize = 256;
pub const MAX_TABLE_NAME: usize = 256;
pub const MAX_SQL: usize = 64 * 1024;

pub const INPUT_CONTENT_TYPE = "application/vnd.sqlite3";

// ---------------------------------------------------------------------------
// Output writer
// ---------------------------------------------------------------------------

pub const Output = struct {
    buf: []u8,
    index: usize = 0,
    overflow: bool = false,

    pub fn writeByte(self: *Output, b: u8) void {
        if (self.overflow) return;
        if (self.index >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.index] = b;
        self.index += 1;
    }

    pub fn writeSlice(self: *Output, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.index + s.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.index..][0..s.len], s);
        self.index += s.len;
    }

    pub fn writeFmt(self: *Output, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&tmp, fmt, args) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(rendered);
    }

    pub fn writeEscapedText(self: *Output, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '\\' => self.writeSlice("\\\\"),
                '\n' => self.writeSlice("\\n"),
                '\r' => self.writeSlice("\\r"),
                '\t' => self.writeSlice("\\t"),
                else => {
                    if (c < 0x20) {
                        self.writeFmt("\\x{X:0>2}", .{c});
                    } else {
                        self.writeByte(c);
                    }
                },
            }
            if (self.overflow) return;
        }
    }
};

// ---------------------------------------------------------------------------
// ASCII helpers
// ---------------------------------------------------------------------------

pub fn trimASCII(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isASCIIWhitespace(s[start])) : (start += 1) {}
    while (end > start and isASCIIWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

pub fn isASCIIWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

// ---------------------------------------------------------------------------
// Binary readers
// ---------------------------------------------------------------------------

pub fn readU16BE(input: []const u8, off: usize) ?u16 {
    if (off + 2 > input.len) return null;
    return (@as(u16, input[off]) << 8) | @as(u16, input[off + 1]);
}

pub fn readU32BE(input: []const u8, off: usize) ?u32 {
    if (off + 4 > input.len) return null;
    return (@as(u32, input[off]) << 24) |
        (@as(u32, input[off + 1]) << 16) |
        (@as(u32, input[off + 2]) << 8) |
        @as(u32, input[off + 3]);
}

pub fn readVarint(input: []const u8, off: usize) ?struct { value: u64, used: usize } {
    if (off >= input.len) return null;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        if (off + i >= input.len) return null;
        const c = input[off + i];
        if (i == 8) {
            v = (v << 8) | @as(u64, c);
            return .{ .value = v, .used = 9 };
        }
        v = (v << 7) | @as(u64, c & 0x7f);
        if ((c & 0x80) == 0) {
            return .{ .value = v, .used = i + 1 };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Record decoding
// ---------------------------------------------------------------------------

pub fn serialTypeByteSize(serial: u64) ?usize {
    return switch (serial) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 => 8,
        7 => 8,
        8 => 0,
        9 => 0,
        else => blk: {
            if (serial >= 12) {
                if ((serial & 1) == 0) break :blk @as(usize, @intCast((serial - 12) / 2));
                break :blk @as(usize, @intCast((serial - 13) / 2));
            }
            break :blk null;
        },
    };
}

pub fn decodeSignedBigEndian(bytes: []const u8) i64 {
    if (bytes.len == 0) return 0;
    var u: u64 = 0;
    for (bytes) |b| {
        u = (u << 8) | @as(u64, b);
    }
    const bit_count: u7 = @intCast(bytes.len * 8);
    if (bit_count < 64) {
        const sign_bit = @as(u64, 1) << @as(u6, @intCast(bit_count - 1));
        if ((u & sign_bit) != 0) {
            u |= (~@as(u64, 0)) << @as(u6, @intCast(bit_count));
        }
    }
    return @as(i64, @bitCast(u));
}

pub fn decodeFloat64BigEndian(bytes: []const u8) ?f64 {
    if (bytes.len != 8) return null;
    var u: u64 = 0;
    for (bytes) |b| {
        u = (u << 8) | @as(u64, b);
    }
    return @as(f64, @bitCast(u));
}

pub const SerialHeader = struct {
    count: usize,
    serials: [MAX_COLUMNS]u64,
    data_offset: usize,
};

pub fn parseRecordHeader(payload: []const u8) ?SerialHeader {
    const header_size_varint = readVarint(payload, 0) orelse return null;
    const header_size: usize = @intCast(header_size_varint.value);
    if (header_size == 0 or header_size > payload.len) return null;

    var serials: [MAX_COLUMNS]u64 = undefined;
    var count: usize = 0;
    var cursor: usize = header_size_varint.used;
    while (cursor < header_size) {
        if (count >= serials.len) return null;
        const serial_varint = readVarint(payload, cursor) orelse return null;
        serials[count] = serial_varint.value;
        count += 1;
        cursor += serial_varint.used;
    }

    if (cursor != header_size) return null;
    return .{ .count = count, .serials = serials, .data_offset = header_size };
}

pub fn extractFieldSlice(payload: []const u8, header: SerialHeader, field_idx: usize) ?struct { serial: u64, data: []const u8 } {
    if (field_idx >= header.count) return null;
    var cursor = header.data_offset;
    var i: usize = 0;
    while (i < header.count) : (i += 1) {
        const serial = header.serials[i];
        const field_size = serialTypeByteSize(serial) orelse return null;
        if (cursor + field_size > payload.len) return null;
        if (i == field_idx) {
            return .{ .serial = serial, .data = payload[cursor .. cursor + field_size] };
        }
        cursor += field_size;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Database file
// ---------------------------------------------------------------------------

pub const InitError = error{ NotSqlite, WalMode, UnsupportedEncoding };

pub fn initErrorMessage(e: InitError) []const u8 {
    return switch (e) {
        error.NotSqlite => "invalid sqlite file",
        error.WalMode => "WAL-mode database not supported; rewrite with VACUUM INTO before serving",
        error.UnsupportedEncoding => "unsupported text encoding; only UTF-8 databases are supported",
    };
}

pub const Db = struct {
    input: []const u8,
    page_size: u32,
    usable_page_bytes: u32,
    page_count: u32,
    payload_copy_buf: []u8,

    had_error: bool = false,
    error_msg: []const u8 = "",

    pub fn setError(self: *Db, msg: []const u8) void {
        if (!self.had_error) {
            self.had_error = true;
            self.error_msg = msg;
        }
    }
};

pub fn init(input: []const u8, payload_copy_buf: []u8) InitError!Db {
    if (input.len < 100) return error.NotSqlite;
    if (!std.mem.eql(u8, input[0..16], "SQLite format 3\x00")) return error.NotSqlite;

    const ps = readU16BE(input, 16) orelse return error.NotSqlite;
    const page_size: u32 = if (ps == 1) 65536 else ps;
    if (page_size == 0) return error.NotSqlite;

    const reserved = input[20];
    if (reserved >= page_size) return error.NotSqlite;
    const usable_page_bytes = page_size - reserved;
    if (usable_page_bytes < 480) return error.NotSqlite;

    // Header offsets 18/19 hold the file format write/read versions; 2 means
    // WAL journal mode, where the main file may be stale without its -wal
    // sidecar.
    if (input[18] != 1 or input[19] != 1) return error.WalMode;

    // Header offset 56 holds the text encoding: 1 is UTF-8 (0 appears in
    // schema-less files); 2 and 3 are UTF-16 variants we do not decode.
    const encoding = readU32BE(input, 56) orelse 0;
    if (encoding > 1) return error.UnsupportedEncoding;

    const page_count: u32 = @intCast((input.len + page_size - 1) / page_size);
    return .{
        .input = input,
        .page_size = page_size,
        .usable_page_bytes = usable_page_bytes,
        .page_count = page_count,
        .payload_copy_buf = payload_copy_buf,
    };
}

fn pageOffset(db: *const Db, page_num: u32) ?usize {
    if (page_num == 0 or page_num > db.page_count) return null;
    const off64 = (@as(u64, page_num) - 1) * @as(u64, db.page_size);
    if (off64 >= db.input.len) return null;
    return @intCast(off64);
}

fn pageHeaderOffset(db: *const Db, page_num: u32) ?usize {
    const off = pageOffset(db, page_num) orelse return null;
    return if (page_num == 1) off + 100 else off;
}

fn computeLocalPayloadBytes(usable: u32, payload_size: usize) usize {
    const max_local: usize = usable - 35;
    const min_local: usize = ((usable - 12) * 32 / 255) - 23;
    if (payload_size <= max_local) return payload_size;

    var local = min_local + ((payload_size - min_local) % (usable - 4));
    if (local > max_local) local = min_local;
    return local;
}

pub const LeafCell = struct {
    payload: []const u8,
    rowid: i64,
};

/// Reads one cell from a table leaf page, following overflow chains into
/// `db.payload_copy_buf`. The payload slice is only valid until the next call.
pub fn readLeafTableCell(db: *Db, cell_off: usize) ?LeafCell {
    const payload_size_varint = readVarint(db.input, cell_off) orelse return null;
    const payload_size: usize = @intCast(payload_size_varint.value);

    const rowid_varint = readVarint(db.input, cell_off + payload_size_varint.used) orelse return null;
    const rowid: i64 = @bitCast(rowid_varint.value);
    const payload_off = cell_off + payload_size_varint.used + rowid_varint.used;
    if (payload_off > db.input.len) return null;

    const local_bytes = computeLocalPayloadBytes(db.usable_page_bytes, payload_size);
    if (payload_off + local_bytes > db.input.len) return null;

    if (payload_size <= local_bytes) {
        return .{ .payload = db.input[payload_off .. payload_off + payload_size], .rowid = rowid };
    }

    if (payload_size > db.payload_copy_buf.len) return null;
    @memcpy(db.payload_copy_buf[0..local_bytes], db.input[payload_off .. payload_off + local_bytes]);

    if (payload_off + local_bytes + 4 > db.input.len) return null;
    var overflow_page = readU32BE(db.input, payload_off + local_bytes) orelse return null;
    var copied: usize = local_bytes;
    var remaining = payload_size - local_bytes;

    while (remaining > 0) {
        if (overflow_page == 0) return null;
        const overflow_off = pageOffset(db, overflow_page) orelse return null;
        if (overflow_off + 4 > db.input.len) return null;

        const next = readU32BE(db.input, overflow_off) orelse return null;
        const chunk_cap: usize = db.usable_page_bytes - 4;
        const chunk = @min(remaining, chunk_cap);
        if (overflow_off + 4 + chunk > db.input.len) return null;

        @memcpy(db.payload_copy_buf[copied..][0..chunk], db.input[overflow_off + 4 .. overflow_off + 4 + chunk]);
        copied += chunk;
        remaining -= chunk;
        overflow_page = next;
    }

    return .{ .payload = db.payload_copy_buf[0..payload_size], .rowid = rowid };
}

// ---------------------------------------------------------------------------
// Schema walking
// ---------------------------------------------------------------------------

pub const TableEntry = struct {
    /// Ordinal among user tables in sqlite_schema order.
    index: usize,
    /// Slices are only valid during the callback.
    name: []const u8,
    sql: []const u8,
    root_page: u32,
};

/// Calls `onTable` for each user table in sqlite_schema order. The callback
/// returns false to stop early. Errors are reported through `db.setError`.
pub fn walkTables(db: *Db, ctx: anytype, comptime onTable: fn (@TypeOf(ctx), TableEntry) bool) void {
    var counter: usize = 0;
    _ = walkSchemaPage(db, 1, &counter, ctx, onTable);
}

fn walkSchemaPage(db: *Db, page_num: u32, counter: *usize, ctx: anytype, comptime onTable: fn (@TypeOf(ctx), TableEntry) bool) bool {
    if (db.had_error) return false;

    const header_off = pageHeaderOffset(db, page_num) orelse {
        db.setError("invalid schema page header");
        return false;
    };
    if (header_off + 8 > db.input.len) {
        db.setError("schema page header out of bounds");
        return false;
    }

    const page_type = db.input[header_off];
    if (page_type == 0x05) {
        if (header_off + 12 > db.input.len) {
            db.setError("schema interior page header out of bounds");
            return false;
        }
        const cell_count = readU16BE(db.input, header_off + 3) orelse {
            db.setError("schema interior cell count");
            return false;
        };
        const right_ptr = readU32BE(db.input, header_off + 8) orelse {
            db.setError("schema right pointer");
            return false;
        };
        const cell_ptrs_off = header_off + 12;
        var i: u16 = 0;
        while (i < cell_count) : (i += 1) {
            const ptr = readU16BE(db.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
                db.setError("schema interior cell pointer");
                return false;
            };
            const page_off = pageOffset(db, page_num) orelse {
                db.setError("schema interior page offset");
                return false;
            };
            const cell_off = page_off + ptr;
            const child = readU32BE(db.input, cell_off) orelse {
                db.setError("schema interior child pointer");
                return false;
            };
            if (!walkSchemaPage(db, child, counter, ctx, onTable)) return false;
        }
        return walkSchemaPage(db, right_ptr, counter, ctx, onTable);
    }

    if (page_type != 0x0d) {
        db.setError("unexpected schema page type");
        return false;
    }

    const cell_count = readU16BE(db.input, header_off + 3) orelse {
        db.setError("schema leaf cell count");
        return false;
    };
    const cell_ptrs_off = header_off + 8;
    const page_off = pageOffset(db, page_num) orelse {
        db.setError("schema leaf page offset");
        return false;
    };

    var i: u16 = 0;
    while (i < cell_count) : (i += 1) {
        const ptr = readU16BE(db.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
            db.setError("schema leaf cell pointer");
            return false;
        };
        const cell_off = page_off + ptr;
        const cell = readLeafTableCell(db, cell_off) orelse {
            db.setError("schema payload decode failed");
            return false;
        };
        const entry = parseSchemaTableEntry(cell.payload, counter.*) orelse continue;
        counter.* += 1;
        if (!onTable(ctx, entry)) return false;
    }
    return true;
}

fn parseSchemaTableEntry(payload: []const u8, index: usize) ?TableEntry {
    const header = parseRecordHeader(payload) orelse return null;
    if (header.count < 5) return null;

    const type_field = extractFieldSlice(payload, header, 0) orelse return null;
    const name_field = extractFieldSlice(payload, header, 1) orelse return null;
    const root_field = extractFieldSlice(payload, header, 3) orelse return null;
    const sql_field = extractFieldSlice(payload, header, 4) orelse return null;

    if (!(type_field.serial >= 13 and (type_field.serial & 1) == 1)) return null;
    if (!(name_field.serial >= 13 and (name_field.serial & 1) == 1)) return null;
    if (!(sql_field.serial >= 13 and (sql_field.serial & 1) == 1)) return null;

    if (!std.mem.eql(u8, type_field.data, "table")) return null;
    if (startsWithIgnoreCase(name_field.data, "sqlite_")) return null;

    var root_page: i64 = 0;
    switch (root_field.serial) {
        1, 2, 3, 4, 5, 6 => root_page = decodeSignedBigEndian(root_field.data),
        8 => root_page = 0,
        9 => root_page = 1,
        else => return null,
    }
    if (root_page <= 0 or root_page > std.math.maxInt(u32)) return null;

    return .{
        .index = index,
        .name = name_field.data,
        .sql = sql_field.data,
        .root_page = @intCast(root_page),
    };
}

/// A schema table entry copied out of walk-scoped memory so it stays valid
/// after the walk. Too large for the wasm stack: keep instances in globals.
pub const SelectedTable = struct {
    found: bool = false,
    root_page: u32 = 0,
    name_len: usize = 0,
    sql_len: usize = 0,
    name_buf: [MAX_TABLE_NAME]u8 = undefined,
    sql_buf: [MAX_SQL]u8 = undefined,

    pub fn name(self: *const SelectedTable) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn sql(self: *const SelectedTable) []const u8 {
        return self.sql_buf[0..self.sql_len];
    }
};

fn copyToFixed(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    return n;
}

const SelectCtx = struct {
    ordinal: usize,
    out: *SelectedTable,
};

fn onSelectTable(ctx: SelectCtx, entry: TableEntry) bool {
    if (entry.index != ctx.ordinal) return true;
    ctx.out.found = true;
    ctx.out.root_page = entry.root_page;
    ctx.out.name_len = copyToFixed(&ctx.out.name_buf, entry.name);
    ctx.out.sql_len = copyToFixed(&ctx.out.sql_buf, entry.sql);
    return false;
}

/// Finds the user table with the given schema-order ordinal (0-based).
pub fn selectTable(db: *Db, ordinal: usize, out: *SelectedTable) void {
    out.found = false;
    walkTables(db, SelectCtx{ .ordinal = ordinal, .out = out }, onSelectTable);
}

// ---------------------------------------------------------------------------
// Table row walking
// ---------------------------------------------------------------------------

/// Calls `onRow` for every row in rowid order. The callback returns false to
/// stop early. Errors are reported through `db.setError`.
pub fn walkTableRows(db: *Db, page_num: u32, ctx: anytype, comptime onRow: fn (@TypeOf(ctx), LeafCell) bool) void {
    _ = walkTablePage(db, page_num, ctx, onRow);
}

fn walkTablePage(db: *Db, page_num: u32, ctx: anytype, comptime onRow: fn (@TypeOf(ctx), LeafCell) bool) bool {
    if (db.had_error) return false;

    const header_off = pageHeaderOffset(db, page_num) orelse {
        db.setError("table page header invalid");
        return false;
    };
    if (header_off + 8 > db.input.len) {
        db.setError("table page header out of bounds");
        return false;
    }

    const page_type = db.input[header_off];
    if (page_type == 0x05) {
        if (header_off + 12 > db.input.len) {
            db.setError("table interior page header out of bounds");
            return false;
        }
        const cell_count = readU16BE(db.input, header_off + 3) orelse {
            db.setError("table interior cell count");
            return false;
        };
        const right_ptr = readU32BE(db.input, header_off + 8) orelse {
            db.setError("table interior right pointer");
            return false;
        };
        const cell_ptrs_off = header_off + 12;
        const page_off = pageOffset(db, page_num) orelse {
            db.setError("table interior page offset");
            return false;
        };
        var i: u16 = 0;
        while (i < cell_count) : (i += 1) {
            const ptr = readU16BE(db.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
                db.setError("table interior cell pointer");
                return false;
            };
            const child = readU32BE(db.input, page_off + ptr) orelse {
                db.setError("table interior child pointer");
                return false;
            };
            if (!walkTablePage(db, child, ctx, onRow)) return false;
        }
        return walkTablePage(db, right_ptr, ctx, onRow);
    }

    if (page_type != 0x0d) {
        db.setError("unexpected table page type");
        return false;
    }

    const cell_count = readU16BE(db.input, header_off + 3) orelse {
        db.setError("table leaf cell count");
        return false;
    };
    const cell_ptrs_off = header_off + 8;
    const page_off = pageOffset(db, page_num) orelse {
        db.setError("table leaf page offset");
        return false;
    };

    var i: u16 = 0;
    while (i < cell_count) : (i += 1) {
        const ptr = readU16BE(db.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
            db.setError("table leaf cell pointer");
            return false;
        };
        const cell_off = page_off + ptr;
        const cell = readLeafTableCell(db, cell_off) orelse {
            db.setError("table row payload decode failed");
            return false;
        };
        if (!onRow(ctx, cell)) return false;
    }
    return true;
}

/// B-tree descent for a single rowid: touches O(depth) pages instead of
/// scanning every leaf. Returns true when the row was found.
pub fn findRowByRowid(db: *Db, page_num: u32, rowid: i64, ctx: anytype, comptime onRow: fn (@TypeOf(ctx), LeafCell) void) bool {
    if (db.had_error) return false;

    const header_off = pageHeaderOffset(db, page_num) orelse {
        db.setError("table page header invalid");
        return false;
    };
    if (header_off + 8 > db.input.len) {
        db.setError("table page header out of bounds");
        return false;
    }

    const page_type = db.input[header_off];
    if (page_type == 0x05) {
        if (header_off + 12 > db.input.len) {
            db.setError("table interior page header out of bounds");
            return false;
        }
        const cell_count = readU16BE(db.input, header_off + 3) orelse {
            db.setError("table interior cell count");
            return false;
        };
        const right_ptr = readU32BE(db.input, header_off + 8) orelse {
            db.setError("table interior right pointer");
            return false;
        };
        const cell_ptrs_off = header_off + 12;
        const page_off = pageOffset(db, page_num) orelse {
            db.setError("table interior page offset");
            return false;
        };
        var i: u16 = 0;
        while (i < cell_count) : (i += 1) {
            const ptr = readU16BE(db.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
                db.setError("table interior cell pointer");
                return false;
            };
            const cell_off = page_off + ptr;
            const child = readU32BE(db.input, cell_off) orelse {
                db.setError("table interior child pointer");
                return false;
            };
            const key_varint = readVarint(db.input, cell_off + 4) orelse {
                db.setError("table interior key");
                return false;
            };
            const key: i64 = @bitCast(key_varint.value);
            if (rowid <= key) {
                return findRowByRowid(db, child, rowid, ctx, onRow);
            }
        }
        return findRowByRowid(db, right_ptr, rowid, ctx, onRow);
    }

    if (page_type != 0x0d) {
        db.setError("unexpected table page type");
        return false;
    }

    const cell_count = readU16BE(db.input, header_off + 3) orelse {
        db.setError("table leaf cell count");
        return false;
    };
    const cell_ptrs_off = header_off + 8;
    const page_off = pageOffset(db, page_num) orelse {
        db.setError("table leaf page offset");
        return false;
    };

    var i: u16 = 0;
    while (i < cell_count) : (i += 1) {
        const ptr = readU16BE(db.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
            db.setError("table leaf cell pointer");
            return false;
        };
        const cell_off = page_off + ptr;
        const cell = readLeafTableCell(db, cell_off) orelse {
            db.setError("table row payload decode failed");
            return false;
        };
        if (cell.rowid == rowid) {
            onRow(ctx, cell);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// CREATE TABLE parsing
// ---------------------------------------------------------------------------

pub const ColumnDecl = struct {
    name: []const u8,
    decl_type: []const u8,
    def: []const u8,
};

fn isConstraintStart(token: []const u8) bool {
    return eqlIgnoreCase(token, "constraint") or
        eqlIgnoreCase(token, "primary") or
        eqlIgnoreCase(token, "not") or
        eqlIgnoreCase(token, "unique") or
        eqlIgnoreCase(token, "check") or
        eqlIgnoreCase(token, "default") or
        eqlIgnoreCase(token, "collate") or
        eqlIgnoreCase(token, "references") or
        eqlIgnoreCase(token, "generated");
}

fn isTableConstraint(item: []const u8) bool {
    const trimmed = trimASCII(item);
    var i: usize = 0;
    while (i < trimmed.len and !isASCIIWhitespace(trimmed[i])) : (i += 1) {}
    const first = trimmed[0..i];
    return eqlIgnoreCase(first, "constraint") or
        eqlIgnoreCase(first, "primary") or
        eqlIgnoreCase(first, "unique") or
        eqlIgnoreCase(first, "check") or
        eqlIgnoreCase(first, "foreign");
}

pub fn parseIdentifier(item: []const u8) struct { ident: []const u8, rest_start: usize } {
    var i: usize = 0;
    while (i < item.len and isASCIIWhitespace(item[i])) : (i += 1) {}
    if (i >= item.len) return .{ .ident = "", .rest_start = item.len };

    if (item[i] == '"' or item[i] == '\'' or item[i] == '`') {
        const quote = item[i];
        const start = i + 1;
        i += 1;
        while (i < item.len and item[i] != quote) : (i += 1) {}
        if (i < item.len) {
            return .{ .ident = item[start..i], .rest_start = i + 1 };
        }
        return .{ .ident = item[start..], .rest_start = item.len };
    }
    if (item[i] == '[') {
        const start = i + 1;
        i += 1;
        while (i < item.len and item[i] != ']') : (i += 1) {}
        if (i < item.len) {
            return .{ .ident = item[start..i], .rest_start = i + 1 };
        }
        return .{ .ident = item[start..], .rest_start = item.len };
    }

    const start = i;
    while (i < item.len and !isASCIIWhitespace(item[i])) : (i += 1) {}
    return .{ .ident = item[start..i], .rest_start = i };
}

fn parseDeclaredType(item: []const u8, start_at: usize) []const u8 {
    var i = start_at;
    while (i < item.len and isASCIIWhitespace(item[i])) : (i += 1) {}
    if (i >= item.len) return "";

    const type_start = i;
    var type_end = i;
    var paren_depth: usize = 0;
    while (i < item.len) {
        if (item[i] == '(') paren_depth += 1 else if (item[i] == ')' and paren_depth > 0) paren_depth -= 1;

        if (paren_depth == 0 and isASCIIWhitespace(item[i])) {
            var j = i;
            while (j < item.len and isASCIIWhitespace(item[j])) : (j += 1) {}
            if (j >= item.len) {
                type_end = i;
                break;
            }
            var k = j;
            while (k < item.len and !isASCIIWhitespace(item[k]) and item[k] != '(' and item[k] != ',') : (k += 1) {}
            const token = item[j..k];
            if (isConstraintStart(token)) {
                type_end = i;
                break;
            }
        }

        type_end = i + 1;
        i += 1;
    }

    return trimASCII(item[type_start..type_end]);
}

fn matchesTokenAt(s: []const u8, at: usize, token: []const u8) bool {
    if (at + token.len > s.len) return false;
    if (!eqlIgnoreCase(s[at .. at + token.len], token)) return false;
    if (at > 0) {
        const prev = s[at - 1];
        if (!isASCIIWhitespace(prev) and prev != '(' and prev != ',') return false;
    }
    const end = at + token.len;
    if (end < s.len) {
        const next = s[end];
        if (!isASCIIWhitespace(next) and next != '(' and next != ',' and next != ')') return false;
    }
    return true;
}

fn hasPrimaryKeyClause(def: []const u8) bool {
    var i: usize = 0;
    while (i + 7 <= def.len) : (i += 1) {
        if (!matchesTokenAt(def, i, "primary")) continue;
        var j = i + 7;
        while (j < def.len and isASCIIWhitespace(def[j])) : (j += 1) {}
        if (matchesTokenAt(def, j, "key")) return true;
    }
    return false;
}

// For `PRIMARY KEY (col)` / `CONSTRAINT name PRIMARY KEY (col)` table
// constraints, returns the single constrained column name, or null when the
// key spans multiple columns.
fn extractSinglePkColumn(item: []const u8) ?[]const u8 {
    if (!hasPrimaryKeyClause(item)) return null;
    var open: ?usize = null;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < item.len) : (i += 1) {
        const c = item[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`' or c == '[') {
            quote = if (c == '[') ']' else c;
            continue;
        }
        if (c == '(') {
            open = i;
            break;
        }
    }
    if (open == null) return null;
    const inner_start = open.? + 1;
    var end = inner_start;
    quote = 0;
    while (end < item.len) : (end += 1) {
        const c = item[end];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`' or c == '[') {
            quote = if (c == '[') ']' else c;
            continue;
        }
        if (c == ',') return null;
        if (c == ')') break;
    }
    const parsed = parseIdentifier(item[inner_start..end]);
    const name = trimASCII(parsed.ident);
    if (name.len == 0) return null;
    return name;
}

pub const ParsedCreateSQL = struct {
    column_count: usize,
    table_pk_column: ?[]const u8,
    tail: []const u8,
};

pub fn parseColumnsFromCreateSQL(sql: []const u8, out_cols: *[MAX_COLUMNS]ColumnDecl) ParsedCreateSQL {
    var open_idx: ?usize = null;
    var close_idx: ?usize = null;
    var i: usize = 0;
    var depth: usize = 0;
    var quote: u8 = 0;

    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            continue;
        }
        if (c == '(') {
            if (open_idx == null) open_idx = i;
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0) {
                    close_idx = i;
                    break;
                }
            }
        }
    }

    if (open_idx == null or close_idx == null or close_idx.? <= open_idx.?) {
        return .{ .column_count = 0, .table_pk_column = null, .tail = "" };
    }
    const body = sql[open_idx.? + 1 .. close_idx.?];
    const tail = sql[close_idx.? + 1 ..];

    var table_pk_column: ?[]const u8 = null;
    var count: usize = 0;
    var part_start: usize = 0;
    i = 0;
    depth = 0;
    quote = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        const c: u8 = if (at_end) ',' else body[i];
        if (!at_end) {
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'' or c == '`') {
                quote = c;
                continue;
            }
            if (c == '(') {
                depth += 1;
                continue;
            }
            if (c == ')' and depth > 0) {
                depth -= 1;
                continue;
            }
        }

        if ((at_end or c == ',') and depth == 0) {
            const raw_part = trimASCII(body[part_start..i]);
            part_start = i + 1;
            if (raw_part.len == 0) continue;
            if (isTableConstraint(raw_part)) {
                if (table_pk_column == null) {
                    table_pk_column = extractSinglePkColumn(raw_part);
                }
                continue;
            }
            if (count >= out_cols.len) break;

            const parsed_ident = parseIdentifier(raw_part);
            const name = trimASCII(parsed_ident.ident);
            if (name.len == 0) continue;
            const decl_type = parseDeclaredType(raw_part, parsed_ident.rest_start);
            out_cols[count] = .{ .name = name, .decl_type = decl_type, .def = raw_part };
            count += 1;
        }
    }
    return .{ .column_count = count, .table_pk_column = table_pk_column, .tail = tail };
}

// A column aliases the rowid when its declared type is exactly INTEGER and it
// is the table's single-column primary key (declared inline or as a table
// constraint). Substitution only fires on stored NULLs, so a false positive
// here cannot clobber a real stored value.
pub fn findRowidAliasColumn(cols: []const ColumnDecl, table_pk_column: ?[]const u8) ?usize {
    for (cols, 0..) |col, idx| {
        if (!eqlIgnoreCase(col.decl_type, "INTEGER")) continue;
        if (hasPrimaryKeyClause(col.def)) return idx;
        if (table_pk_column) |pk_name| {
            if (eqlIgnoreCase(col.name, pk_name)) return idx;
        }
    }
    return null;
}

pub fn isWithoutRowid(tail: []const u8) bool {
    var i: usize = 0;
    while (i + 7 <= tail.len) : (i += 1) {
        if (!matchesTokenAt(tail, i, "without")) continue;
        var j = i + 7;
        while (j < tail.len and isASCIIWhitespace(tail[j])) : (j += 1) {}
        if (matchesTokenAt(tail, j, "rowid")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// TSV value/row formatting
// ---------------------------------------------------------------------------

pub fn writeValue(out: *Output, serial: u64, data: []const u8) void {
    switch (serial) {
        0 => out.writeSlice("NULL"),
        1, 2, 3, 4, 5, 6 => out.writeFmt("{d}", .{decodeSignedBigEndian(data)}),
        7 => {
            const f = decodeFloat64BigEndian(data) orelse {
                out.writeSlice("NULL");
                return;
            };
            out.writeFmt("{d}", .{f});
        },
        8 => out.writeSlice("0"),
        9 => out.writeSlice("1"),
        else => {
            if (serial >= 12 and (serial & 1) == 1) {
                out.writeEscapedText(data);
                return;
            }
            if (serial >= 12 and (serial & 1) == 0) {
                out.writeSlice("x'");
                for (data) |b| out.writeFmt("{X:0>2}", .{b});
                out.writeByte('\'');
                return;
            }
            out.writeSlice("NULL");
        },
    }
}

pub fn writeRowTSV(out: *Output, cell: LeafCell, ipk_column: ?usize) bool {
    const header = parseRecordHeader(cell.payload) orelse return false;
    var data_cursor = header.data_offset;
    var i: usize = 0;
    while (i < header.count) : (i += 1) {
        if (i > 0) out.writeByte('\t');
        const serial = header.serials[i];
        const field_size = serialTypeByteSize(serial) orelse return false;
        if (data_cursor + field_size > cell.payload.len) return false;
        const data = cell.payload[data_cursor .. data_cursor + field_size];
        // An INTEGER PRIMARY KEY column aliases the rowid: the record stores
        // NULL and the real value lives in the cell's rowid varint.
        if (serial == 0 and ipk_column != null and i == ipk_column.?) {
            out.writeFmt("{d}", .{cell.rowid});
        } else {
            writeValue(out, serial, data);
        }
        data_cursor += field_size;
        if (out.overflow) return false;
    }
    out.writeByte('\n');
    return !out.overflow;
}
