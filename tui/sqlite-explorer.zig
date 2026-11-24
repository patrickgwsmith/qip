//! SQLite Explorer TUI: browse the tables and rows of a SQLite database file
//! in a terminal.
//!
//! Input is an `application/vnd.sqlite3` file, read in place with the shared
//! read-only reader in `application/vnd.sqlite3/lib/sqlite.zig`. A sidebar
//! lists the user tables with their row counts; the main pane shows the
//! selected table as a grid of rows, or its columns and CREATE statement.
//! This is the text-mode counterpart of `gui/sqlite-explorer.zig`.
//!
//! Selecting a table indexes the file offset of every row cell once, so
//! scrolling decodes only the visible rows. Empty input shows how to open a
//! file; files that are not readable UTF-8 rollback-journal databases show
//! the reason instead of the grid.
//!
//! Keys: Tab switches between the table list and the grid. Arrows move, Page
//! Up/Down move a page, Home/End go to the first/last column, and g/G or
//! Ctrl with Home/End go to the first/last row. `[` and `]` select the
//! previous/next table and `s` toggles the schema view.

const std = @import("std");
const sqlite = @import("sqlite");

// ---------------------------------------------------------------------------
// Capacities.

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;
const MAX_TABLES: usize = 256;
const MAX_NAME: usize = 128;
const MAX_ROWS: usize = 1 << 20;
const WIDTH_SAMPLE_ROWS: usize = 200;
const MIN_COL_CHARS: usize = 3;
const MAX_COL_CHARS: usize = 32;
const CELL_TEXT_CAP: usize = 192;
const STATUS_TEXT_CAP: usize = 1024;
const MAX_COLUMNS_UNIFORM: u32 = 240;
const MAX_LINES_UNIFORM: u32 = 100;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

// ---------------------------------------------------------------------------
// Input events.

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_META: i32 = 1 << 5;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_PAGE_UP: i32 = 0xFF55;
const XK_PAGE_DOWN: i32 = 0xFF56;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;
const XK_RETURN: i32 = 0xFF0D;
const XK_TAB: i32 = 0xFF09;
const XK_ISO_LEFT_TAB: i32 = 0xFE20;
const XK_ESCAPE: i32 = 0xFF1B;

// ---------------------------------------------------------------------------
// Styles. Only SGR codes that qiptui accepts: reset, bold, dim, underline,
// and the 8 standard and bright colours.

const SGR_RESET = "\x1b[0m";
const SGR_BOLD = "\x1b[1m";
const SGR_DIM = "\x1b[2m";
const SGR_TITLE = "\x1b[1;96m";
const SGR_HEADING = "\x1b[1m";
const SGR_ACTIVE = "\x1b[1;96m";
const SGR_CURSOR = "\x1b[30;46m";
const SGR_CURSOR_INACTIVE = "\x1b[1;4m";
const SGR_NUMBER = "\x1b[36m";
const SGR_BLOB = "\x1b[35m";
const SGR_ERROR = "\x1b[1;91m";

// ---------------------------------------------------------------------------
// State.

const Phase = enum { initializing, ready, updating };
const Focus = enum { tables, grid };
const View = enum { rows, schema };

const Table = struct {
    name_buf: [MAX_NAME]u8 = undefined,
    name_len: usize = 0,
    root_page: u32 = 0,
    row_count: u64 = 0,
    without_rowid: bool = false,
    damaged: bool = false,

    fn name(self: *const Table) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const ValueKind = enum { null, integer, real, text, blob, missing, damaged };

var input_buf: [INPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var output_len: usize = 0;
var row_offsets: [MAX_ROWS]u32 = undefined;
var tables: [MAX_TABLES]Table = undefined;
var selected: sqlite.SelectedTable = .{};
var cols: [sqlite.MAX_COLUMNS]sqlite.ColumnDecl = undefined;
var scratch_cols: [sqlite.MAX_COLUMNS]sqlite.ColumnDecl = undefined;
var col_chars: [sqlite.MAX_COLUMNS]u8 = undefined;
var col_real: [sqlite.MAX_COLUMNS]bool = undefined;
var synth_names: [sqlite.MAX_COLUMNS][12]u8 = undefined;

var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var columns: usize = 80;
var lines: usize = 24;

var db: sqlite.Db = undefined;
var loaded: bool = false;
var load_error: []const u8 = "";
var table_count: usize = 0;
var tables_truncated: bool = false;

var sel_table: usize = 0;
var col_count: usize = 0;
var ipk_column: ?usize = null;
var indexed_rows: usize = 0;
var rows_truncated: bool = false;
var rows_damaged: bool = false;
var rowid_chars: usize = 5;

var focus: Focus = .tables;
var view: View = .rows;
var cur_row: usize = 0;
var cur_col: usize = 0;
var scroll_row: usize = 0;
var scroll_col: usize = 0;
var sidebar_scroll: usize = 0;
var schema_scroll: usize = 0;

// ---------------------------------------------------------------------------
// Content exports.

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
    return @intCast(@intFromPtr(sqlite.INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return sqlite.INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr("text/plain".ptr));
}

export fn output_content_type_size() u32 {
    return "text/plain".len;
}

/// Terminal width in columns. The host sets it from the terminal size.
export fn uniform_set_columns(value: u32) u32 {
    columns = std.math.clamp(value, 20, MAX_COLUMNS_UNIFORM);
    return @intCast(columns);
}

/// Terminal height in lines. The host sets it from the terminal size.
export fn uniform_set_lines(value: u32) u32 {
    lines = std.math.clamp(value, 6, MAX_LINES_UNIFORM);
    return @intCast(lines);
}

export fn render(input_size: u32) RenderResult {
    switch (phase) {
        .initializing => {
            if (input_size > INPUT_CAP) @trap();
            load(input_buf[0..input_size]);
            phase = .ready;
        },
        .ready => if (input_size != 0) @trap(),
        .updating => @trap(),
    }
    draw();
    return .{
        .output_size_or_failure = @intCast(output_len),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

// ---------------------------------------------------------------------------
// Time and Events exports.

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return begun_at_ms;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & FLAG_KEY_DOWN) == 0 or !loaded) return 0;
    return @intFromBool(handleKey(x11_key, flags));
}

// ---------------------------------------------------------------------------
// Loading.

const ListCtx = struct {};

fn onListTable(_: ListCtx, entry: sqlite.TableEntry) bool {
    if (table_count >= MAX_TABLES) {
        tables_truncated = true;
        return false;
    }
    const t = &tables[table_count];
    t.* = .{};
    t.name_len = @min(entry.name.len, MAX_NAME);
    @memcpy(t.name_buf[0..t.name_len], entry.name[0..t.name_len]);
    t.root_page = entry.root_page;
    const parsed = sqlite.parseColumnsFromCreateSQL(entry.sql, &scratch_cols);
    t.without_rowid = sqlite.isWithoutRowid(parsed.tail);
    table_count += 1;
    return true;
}

fn onCountCell(count: *u64, _: usize) bool {
    count.* += 1;
    return true;
}

fn load(input: []const u8) void {
    loaded = false;
    load_error = "";
    table_count = 0;
    tables_truncated = false;
    if (input.len == 0) return;

    db = sqlite.init(input, &payload_copy_buf) catch |e| {
        load_error = switch (e) {
            error.NotSqlite => "This file is not a SQLite database.",
            error.WalMode => "This database uses WAL mode. Run VACUUM INTO to write a rollback-journal copy.",
            error.UnsupportedEncoding => "This database stores text as UTF-16. Only UTF-8 databases are supported.",
        };
        return;
    };
    sqlite.walkTables(&db, ListCtx{}, onListTable);
    if (db.had_error) {
        table_count = 0;
        load_error = "The database schema could not be read.";
        return;
    }
    for (tables[0..table_count]) |*t| {
        if (t.without_rowid) continue;
        db.had_error = false;
        var count: u64 = 0;
        sqlite.walkTableCellOffsets(&db, t.root_page, &count, onCountCell);
        t.row_count = count;
        t.damaged = db.had_error;
    }
    db.had_error = false;
    loaded = true;
    if (table_count > 0) selectTable(0);
}

const IndexCtx = struct {};

fn onIndexCell(_: IndexCtx, cell_off: usize) bool {
    if (indexed_rows >= MAX_ROWS) {
        rows_truncated = true;
        return false;
    }
    row_offsets[indexed_rows] = @intCast(cell_off);
    indexed_rows += 1;
    return true;
}

fn selectTable(index: usize) void {
    sel_table = index;
    cur_row = 0;
    cur_col = 0;
    scroll_row = 0;
    scroll_col = 0;
    schema_scroll = 0;
    indexed_rows = 0;
    rows_truncated = false;
    rows_damaged = false;
    col_count = 0;
    ipk_column = null;
    rowid_chars = 5;

    db.had_error = false;
    sqlite.selectTable(&db, index, &selected);
    if (!selected.found or db.had_error) {
        db.had_error = false;
        return;
    }
    const parsed = sqlite.parseColumnsFromCreateSQL(selected.sql(), &cols);
    col_count = parsed.column_count;
    ipk_column = sqlite.findRowidAliasColumn(cols[0..col_count], parsed.table_pk_column);
    for (0..col_count) |c| col_real[c] = false;
    if (tables[index].without_rowid) return;

    sqlite.walkTableCellOffsets(&db, tables[index].root_page, IndexCtx{}, onIndexCell);
    rows_damaged = db.had_error;
    db.had_error = false;

    if (col_count == 0) synthesizeColumns();
    for (0..col_count) |c| col_real[c] = hasRealAffinity(cols[c].decl_type);
    measureColumns();
}

// A table whose CREATE statement the reader cannot split into columns still
// has records; name its fields by position from the widest sampled record.
fn synthesizeColumns() void {
    var widest: usize = 0;
    const n = @min(indexed_rows, WIDTH_SAMPLE_ROWS);
    for (row_offsets[0..n]) |off| {
        const cell = sqlite.readLeafTableCell(&db, off) orelse continue;
        const header = sqlite.parseRecordHeader(cell.payload) orelse continue;
        widest = @max(widest, header.count);
    }
    for (0..widest) |i| {
        const label = std.fmt.bufPrint(&synth_names[i], "column {d}", .{i + 1}) catch "column";
        cols[i] = .{ .name = label, .decl_type = "", .def = "" };
    }
    col_count = widest;
}

// Sizes each column to its header and the widest value in the first and
// last WIDTH_SAMPLE_ROWS / 2 rows. Rowids and other keys usually grow with
// the row number, so the tail catches wide values that the head misses.
fn measureColumns() void {
    for (0..col_count) |c| {
        col_chars[c] = @intCast(std.math.clamp(textWidth(cols[c].name), MIN_COL_CHARS, MAX_COL_CHARS));
    }
    const half = WIDTH_SAMPLE_ROWS / 2;
    measureRows(0, @min(indexed_rows, half), false);
    measureRows(@max(half, indexed_rows -| half), indexed_rows, false);
    if (indexed_rows > 0) {
        var row = Row{};
        if (row.load(indexed_rows - 1)) rowid_chars = @max(rowid_chars, decimalWidth(row.rowid));
        if (row.load(0)) rowid_chars = @max(rowid_chars, decimalWidth(row.rowid));
    }
}

/// Widens columns to fit the values in rows `start..end`. With
/// `numbers_only`, only numbers count: a cut-off number shows a different
/// value, while a cut-off text keeps its ellipsis.
fn measureRows(start: usize, end: usize, numbers_only: bool) void {
    var buf: [CELL_TEXT_CAP]u8 = undefined;
    var r = start;
    while (r < end) : (r += 1) {
        var row = Row{};
        if (!row.load(r)) continue;
        for (0..col_count) |c| {
            const v = row.value(c, &buf);
            if (numbers_only and v.kind != .integer and v.kind != .real) continue;
            const chars = std.math.clamp(textWidth(v.text), MIN_COL_CHARS, MAX_COL_CHARS);
            if (chars > col_chars[c]) col_chars[c] = @intCast(chars);
        }
    }
}

// ---------------------------------------------------------------------------
// Row decoding.

const Row = struct {
    rowid: i64 = 0,
    payload: []const u8 = "",
    header: sqlite.SerialHeader = undefined,
    starts: [sqlite.MAX_COLUMNS]u32 = undefined,
    ok: bool = false,

    /// Decodes row `index`. The payload may live in the shared overflow
    /// buffer, so use the row before loading another.
    fn load(self: *Row, index: usize) bool {
        self.ok = false;
        if (index >= indexed_rows) return false;
        db.had_error = false;
        const cell = sqlite.readLeafTableCell(&db, row_offsets[index]) orelse return false;
        self.rowid = cell.rowid;
        self.payload = cell.payload;
        self.header = sqlite.parseRecordHeader(cell.payload) orelse return false;
        var cursor = self.header.data_offset;
        for (0..self.header.count) |i| {
            const size = sqlite.serialTypeByteSize(self.header.serials[i]) orelse return false;
            if (cursor + size > cell.payload.len) return false;
            self.starts[i] = @intCast(cursor);
            cursor += size;
        }
        self.ok = true;
        return true;
    }

    const Value = struct { kind: ValueKind, text: []const u8, bytes: usize = 0 };

    fn value(self: *const Row, col: usize, buf: []u8) Value {
        if (!self.ok) return .{ .kind = .damaged, .text = "unreadable" };
        // Columns added by ALTER TABLE after a row was written are absent
        // from its record; SQLite reads them as the column default.
        if (col >= self.header.count) return .{ .kind = .missing, .text = "NULL" };
        const serial = self.header.serials[col];
        const start: usize = self.starts[col];
        const size = sqlite.serialTypeByteSize(serial) orelse 0;
        const data = self.payload[start .. start + size];
        if (serial == 0 and ipk_column != null and ipk_column.? == col) {
            return .{ .kind = .integer, .text = fmtInt(buf, self.rowid) };
        }
        // SQLite may store a whole REAL as an integer to save space, and
        // converts it back when read.
        if (col_real[col] and serial >= 1 and serial <= 9 and serial != 7) {
            const i: i64 = switch (serial) {
                8 => 0,
                9 => 1,
                else => sqlite.decodeSignedBigEndian(data),
            };
            return .{ .kind = .real, .text = fmtReal(buf, @floatFromInt(i)) };
        }
        return formatValue(serial, data, buf);
    }
};

fn formatValue(serial: u64, data: []const u8, buf: []u8) Row.Value {
    switch (serial) {
        0 => return .{ .kind = .null, .text = "NULL" },
        1, 2, 3, 4, 5, 6 => return .{ .kind = .integer, .text = fmtInt(buf, sqlite.decodeSignedBigEndian(data)) },
        7 => {
            const f = sqlite.decodeFloat64BigEndian(data) orelse return .{ .kind = .null, .text = "NULL" };
            return .{ .kind = .real, .text = fmtReal(buf, f) };
        },
        8 => return .{ .kind = .integer, .text = "0" },
        9 => return .{ .kind = .integer, .text = "1" },
        else => {},
    }
    if (serial >= 13 and (serial & 1) == 1) {
        // Newlines become a pilcrow and other C0 controls a space, so a cell
        // stays on one line. Other unsafe code points are replaced when
        // the text is written to the frame.
        var n: usize = 0;
        for (data) |b| {
            if (b == '\n') {
                if (n + 2 > buf.len) break;
                buf[n] = 0xC2;
                buf[n + 1] = 0xB6;
                n += 2;
                continue;
            }
            if (n >= buf.len) break;
            buf[n] = if (b < 0x20 or b == 0x7F) ' ' else b;
            n += 1;
        }
        return .{ .kind = .text, .text = buf[0..n], .bytes = data.len };
    }
    if (serial >= 12) {
        var n: usize = 0;
        const prefix = "x'";
        @memcpy(buf[0..prefix.len], prefix);
        n = prefix.len;
        const digits = "0123456789ABCDEF";
        for (data) |b| {
            if (n + 3 > buf.len) break;
            buf[n] = digits[b >> 4];
            buf[n + 1] = digits[b & 15];
            n += 2;
        }
        if (n + 1 <= buf.len) {
            buf[n] = '\'';
            n += 1;
        }
        return .{ .kind = .blob, .text = buf[0..n], .bytes = data.len };
    }
    return .{ .kind = .damaged, .text = "?" };
}

fn valueStyle(kind: ValueKind) []const u8 {
    return switch (kind) {
        .null, .missing => SGR_DIM,
        .integer, .real => SGR_NUMBER,
        .blob => SGR_BLOB,
        .damaged => SGR_ERROR,
        .text => "",
    };
}

// ---------------------------------------------------------------------------
// Layout. Line 0 is the title; the last two lines are the status and key
// hints. Between them, the sidebar sits left of a vertical rule and the main
// pane has a table heading, then either the grid (column header, rule, and
// rows) or the schema.

fn bodyTop() usize {
    return 1;
}

fn bodyLines() usize {
    return lines -| 3;
}

fn sidebarWidth() usize {
    if (columns < 48) return 0;
    return std.math.clamp(columns / 4, 14, 28);
}

fn mainLeft() usize {
    const sw = sidebarWidth();
    return if (sw == 0) 0 else sw + 1;
}

fn mainWidth() usize {
    return columns - mainLeft();
}

fn sidebarRows() usize {
    return @max(1, bodyLines() -| 1);
}

fn visibleRows() usize {
    return @max(1, bodyLines() -| gridFirstRow());
}

fn gridFirstRow() usize {
    // The separator is useful when there is room, but a six-line terminal
    // needs that line for the first data row.
    return if (bodyLines() <= 3) 2 else 3;
}

fn schemaVisible() usize {
    return @max(1, bodyLines() -| 1);
}

fn gutterWidth() usize {
    return rowid_chars + 1;
}

/// Each grid column is " value " followed by a one-cell rule.
fn columnSlot(c: usize) usize {
    return @as(usize, col_chars[c]) + 3;
}

/// Index of the first column not fully visible when the grid starts at
/// `scroll_col`.
fn columnsFitting() usize {
    var x = gutterWidth() + 1;
    var c = scroll_col;
    while (c < col_count) : (c += 1) {
        x += columnSlot(c);
        if (x > mainWidth()) break;
    }
    return c;
}

// ---------------------------------------------------------------------------
// Keyboard.

fn handleKey(key: i32, flags: i32) bool {
    const command = (flags & (FLAG_CTRL | FLAG_META)) != 0;
    if (sidebarWidth() == 0) focus = .grid;
    switch (key) {
        XK_TAB, XK_ISO_LEFT_TAB => {
            if (sidebarWidth() == 0) return false;
            focus = if (focus == .tables) .grid else .tables;
            return true;
        },
        '[' => return stepTable(-1),
        ']' => return stepTable(1),
        's', 'S' => {
            if (command) return false;
            view = if (view == .rows) .schema else .rows;
            return true;
        },
        else => {},
    }
    if (table_count == 0) return false;
    if (focus == .tables) return handleTablesKey(key);
    if (view == .schema) return handleSchemaKey(key);
    return handleGridKey(key, command);
}

fn stepTable(delta: i32) bool {
    if (table_count == 0) return false;
    const next = @as(i64, @intCast(sel_table)) + delta;
    if (next < 0 or next >= @as(i64, @intCast(table_count))) return false;
    selectTable(@intCast(next));
    return true;
}

fn selectIfChanged(index: usize) bool {
    if (index == sel_table) return false;
    selectTable(index);
    return true;
}

fn handleTablesKey(key: i32) bool {
    const page = sidebarRows();
    switch (key) {
        XK_UP, 'k' => return stepTable(-1),
        XK_DOWN, 'j' => return stepTable(1),
        XK_HOME, 'g' => return selectIfChanged(0),
        XK_END, 'G' => return selectIfChanged(table_count - 1),
        XK_PAGE_UP => return selectIfChanged(sel_table -| page),
        XK_PAGE_DOWN => return selectIfChanged(@min(table_count - 1, sel_table + page)),
        XK_RETURN, XK_RIGHT, 'l' => {
            focus = .grid;
            return true;
        },
        else => return false,
    }
}

fn handleSchemaKey(key: i32) bool {
    const max = schemaLineCount() -| schemaVisible();
    const before = schema_scroll;
    const page = @max(1, schemaVisible() -| 1);
    switch (key) {
        XK_UP, 'k' => schema_scroll -|= 1,
        XK_DOWN, 'j' => schema_scroll = @min(max, schema_scroll + 1),
        XK_PAGE_UP => schema_scroll -|= page,
        XK_PAGE_DOWN => schema_scroll = @min(max, schema_scroll + page),
        XK_HOME, 'g' => schema_scroll = 0,
        XK_END, 'G' => schema_scroll = max,
        XK_LEFT, 'h' => {
            focus = .tables;
            return true;
        },
        XK_ESCAPE => {
            view = .rows;
            return true;
        },
        else => return false,
    }
    return schema_scroll != before;
}

fn handleGridKey(key: i32, command: bool) bool {
    const before_row = cur_row;
    const before_col = cur_col;
    const last_row = indexed_rows -| 1;
    const last_col = col_count -| 1;
    const page = @max(1, visibleRows() -| 1);
    switch (key) {
        XK_UP, 'k' => cur_row = if (command) 0 else cur_row -| 1,
        XK_DOWN, 'j' => cur_row = if (command) last_row else @min(last_row, cur_row + 1),
        XK_PAGE_UP => cur_row -|= page,
        XK_PAGE_DOWN => cur_row = @min(last_row, cur_row + page),
        'g' => cur_row = 0,
        'G' => cur_row = last_row,
        XK_HOME => {
            if (command) cur_row = 0 else cur_col = 0;
        },
        XK_END => {
            if (command) cur_row = last_row else cur_col = last_col;
        },
        XK_LEFT, 'h' => {
            if (cur_col == 0 and sidebarWidth() > 0) {
                focus = .tables;
                return true;
            }
            cur_col -= 1;
        },
        XK_RIGHT, 'l' => cur_col = @min(last_col, cur_col + 1),
        XK_ESCAPE => {
            if (sidebarWidth() == 0) return false;
            focus = .tables;
            return true;
        },
        else => return false,
    }
    return cur_row != before_row or cur_col != before_col;
}

/// Keeps the cursor and selected table on screen. Runs before every draw,
/// so a terminal resize also scrolls them into view.
fn clampScroll() void {
    if (sidebarWidth() == 0) focus = .grid;
    const page = sidebarRows();
    if (sel_table < sidebar_scroll) sidebar_scroll = sel_table;
    if (sel_table >= sidebar_scroll + page) sidebar_scroll = sel_table + 1 - page;

    const visible = visibleRows();
    if (cur_row < scroll_row) scroll_row = cur_row;
    if (cur_row >= scroll_row + visible) scroll_row = cur_row + 1 - visible;
    scroll_row = @min(scroll_row, indexed_rows -| visible);

    if (cur_col < scroll_col) scroll_col = cur_col;
    while (scroll_col < cur_col and columnsFitting() <= cur_col) scroll_col += 1;

    schema_scroll = @min(schema_scroll, schemaLineCount() -| schemaVisible());
}

// ---------------------------------------------------------------------------
// Frame writer. Tracks the terminal column of the current line so text can
// be cut or padded to an exact width.

const Writer = struct {
    at: usize = 0,
    column: usize = 0,

    fn raw(self: *Writer, bytes: []const u8) void {
        const n = @min(bytes.len, OUTPUT_CAP - self.at);
        @memcpy(output_buf[self.at..][0..n], bytes[0..n]);
        self.at += n;
    }

    fn style(self: *Writer, sgr: []const u8) void {
        if (sgr.len > 0) self.raw(sgr);
    }

    fn reset(self: *Writer) void {
        self.raw(SGR_RESET);
    }

    fn spaces(self: *Writer, count: usize) void {
        for (0..count) |_| self.raw(" ");
        self.column += count;
    }

    fn newline(self: *Writer) void {
        self.raw("\n");
        self.column = 0;
    }

    /// Writes `text` in at most `width` cells, ending with an ellipsis if it
    /// is cut. Returns the cells used.
    fn clipped(self: *Writer, text: []const u8, width: usize) usize {
        if (width == 0) return 0;
        const full = textWidth(text);
        const limit = if (full > width) width - 1 else width;
        var used: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const start = i;
            const cp = nextCodepoint(text, &i);
            const safe = safeCodepoint(cp);
            const w = codepointWidth(safe);
            if (used + w > limit) break;
            if (safe == cp and cp != 0xFFFD) {
                self.raw(text[start..i]);
            } else {
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(safe), &enc) catch 1;
                self.raw(enc[0..n]);
            }
            used += w;
        }
        if (full > width) {
            self.raw("\xe2\x80\xa6");
            used += 1;
        }
        self.column += used;
        return used;
    }

    /// Writes `text` in exactly `width` cells, padded on the left when
    /// `right_align` is set and on the right otherwise.
    fn field(self: *Writer, text: []const u8, width: usize, right_align: bool) void {
        const w = @min(textWidth(text), width);
        if (right_align) self.spaces(width - w);
        const used = self.clipped(text, width);
        if (!right_align) self.spaces(width -| used);
    }

    /// Like `field`, wrapped in an SGR style.
    fn styledField(self: *Writer, sgr: []const u8, text: []const u8, width: usize, right_align: bool) void {
        self.style(sgr);
        self.field(text, width, right_align);
        if (sgr.len > 0) self.reset();
    }
};

// ---------------------------------------------------------------------------
// Drawing.

fn draw() void {
    if (loaded and table_count > 0 and view == .rows) {
        measureRows(scroll_row, @min(indexed_rows, scroll_row + visibleRows()), true);
    }
    clampScroll();

    var w = Writer{};
    drawTitle(&w);
    if (!loaded) {
        drawUnloaded(&w);
        output_len = w.at;
        return;
    }
    for (0..bodyLines()) |line| {
        w.newline();
        const sw = sidebarWidth();
        if (sw > 0) {
            drawSidebarLine(&w, line, sw);
            w.style(SGR_DIM);
            w.raw("\xe2\x94\x82");
            w.column += 1;
            w.reset();
        }
        drawMainLine(&w, line, mainWidth());
    }
    w.newline();
    drawStatus(&w);
    w.newline();
    drawHints(&w);
    w.reset();
    output_len = w.at;
}

fn drawTitle(w: *Writer) void {
    const name = "SQLITE EXPLORER";
    w.styledField(SGR_TITLE, name, @min(name.len, columns), false);
    if (!loaded) return;
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    n += copyInto(buf[n..], "  ");
    n += fmtCountInto(buf[n..], table_count);
    n += copyInto(buf[n..], if (table_count == 1) " table" else " tables");
    n += copyInto(buf[n..], if (tables_truncated) "+ \xc2\xb7 " else " \xc2\xb7 ");
    n += fmtCountInto(buf[n..], db.page_count);
    n += copyInto(buf[n..], if (db.page_count == 1) " page of " else " pages of ");
    n += fmtCountInto(buf[n..], db.page_size);
    n += copyInto(buf[n..], " bytes");
    w.styledField(SGR_DIM, buf[0..n], columns -| w.column, false);
}

fn drawUnloaded(w: *Writer) void {
    w.newline();
    w.newline();
    if (load_error.len > 0) {
        w.styledField(SGR_ERROR, load_error, columns, false);
        w.newline();
        w.newline();
        _ = w.clipped("Open a SQLite 3 database file.", columns);
        return;
    }
    w.styledField(SGR_BOLD, "No database loaded", columns, false);
    w.newline();
    w.newline();
    _ = w.clipped("Pass a SQLite file as input, for example:", columns);
    w.newline();
    w.newline();
    w.spaces(2);
    _ = w.clipped("npx qiptui -i data.sqlite tui/sqlite-explorer.wasm", columns -| 2);
}

fn drawSidebarLine(w: *Writer, line: usize, width: usize) void {
    if (line == 0) {
        w.styledField(SGR_HEADING, " TABLES", width, false);
        return;
    }
    if (table_count == 0) {
        w.styledField(SGR_DIM, if (line == 1) " No tables" else "", width, false);
        return;
    }
    const i = sidebar_scroll + line - 1;
    if (i >= table_count) {
        w.spaces(width);
        return;
    }
    const t = &tables[i];
    var count_buf: [32]u8 = undefined;
    const count_text = if (t.without_rowid)
        "\xe2\x80\x94"
    else if (t.damaged)
        "!"
    else
        count_buf[0..fmtCountInto(&count_buf, t.row_count)];
    const count_w = textWidth(count_text);
    const is_sel = i == sel_table;
    const sgr = if (!is_sel) "" else if (focus == .tables) SGR_CURSOR else SGR_ACTIVE;
    w.style(sgr);
    w.raw(if (is_sel) ">" else " ");
    w.column += 1;
    const name_w = width -| (count_w + 3);
    w.field(t.name(), name_w, false);
    w.spaces(1);
    w.reset();
    w.style(if (is_sel) sgr else SGR_DIM);
    w.field(count_text, width -| (name_w + 2), true);
    w.reset();
}

fn drawMainLine(w: *Writer, line: usize, width: usize) void {
    if (table_count == 0) {
        if (line == 0) w.styledField(SGR_DIM, " This database has no user tables.", width, false);
        return;
    }
    const t = &tables[sel_table];
    if (line == 0) {
        drawTableHeading(w, t, width);
        return;
    }
    if (view == .schema) {
        drawSchemaLine(w, line - 1, width);
        return;
    }
    if (t.without_rowid) {
        if (line == 2) _ = w.clipped(" WITHOUT ROWID tables are not readable yet.", width);
        if (line == 3) w.styledField(SGR_DIM, " Press s to see the schema.", width, false);
        return;
    }
    if (line == 1) return drawColumnHeader(w, width);
    if (gridFirstRow() == 3 and line == 2) return drawHeaderRule(w, width);
    const vr = line - gridFirstRow();
    const r = scroll_row + vr;
    if (r >= indexed_rows) {
        if (vr == 0 and indexed_rows == 0) {
            if (rows_damaged) {
                w.styledField(SGR_ERROR, " The table's B-tree could not be read.", width, false);
            } else w.styledField(SGR_DIM, " This table has no rows.", width, false);
        }
        return;
    }
    drawRow(w, r, width);
}

fn drawTableHeading(w: *Writer, t: *const Table, width: usize) void {
    const tabs_w: usize = 16;
    const left_w = width -| tabs_w;
    var sub_buf: [96]u8 = undefined;
    var n: usize = 0;
    n += copyInto(sub_buf[n..], "  ");
    n += fmtCountInto(sub_buf[n..], col_count);
    n += copyInto(sub_buf[n..], if (col_count == 1) " column" else " columns");
    if (!t.without_rowid) {
        n += copyInto(sub_buf[n..], ", ");
        n += fmtCountInto(sub_buf[n..], t.row_count);
        n += copyInto(sub_buf[n..], if (t.row_count == 1) " row" else " rows");
    }
    w.spaces(@min(1, left_w));
    w.style(SGR_BOLD);
    const name_w = w.clipped(t.name(), (left_w -| 1) * 2 / 3);
    w.reset();
    w.styledField(SGR_DIM, sub_buf[0..n], left_w -| (name_w + 1), false);
    if (width < tabs_w) return;
    w.spaces(1);
    w.styledField(if (view == .rows) SGR_ACTIVE else SGR_DIM, if (view == .rows) "[Rows]" else " Rows ", 6, false);
    w.spaces(1);
    w.styledField(if (view == .schema) SGR_ACTIVE else SGR_DIM, if (view == .schema) "[Schema]" else " Schema ", 8, false);
}

fn drawColumnHeader(w: *Writer, width: usize) void {
    const start = w.column;
    const gutter = gutterWidth();
    w.styledField(SGR_DIM, "rowid", @min(gutter, width), true);
    if (width <= gutter) return;
    w.style(SGR_DIM);
    w.raw(" \xe2\x94\x82");
    w.column += 2;
    w.reset();
    var c = scroll_col;
    while (c < col_count) : (c += 1) {
        const room = width -| (w.column - start);
        if (room == 0) break;
        const slot = columnSlot(c);
        const is_cur = c == cur_col and focus == .grid;
        w.style(if (is_cur) SGR_ACTIVE else SGR_HEADING);
        w.spaces(@min(1, room));
        w.field(cols[c].name, @min(col_chars[c], room -| 1), false);
        w.reset();
        const left = width -| (w.column - start);
        w.spaces(@min(1, left));
        if (left > 1 and slot > 0) {
            w.style(SGR_DIM);
            w.raw("\xe2\x94\x82");
            w.column += 1;
            w.reset();
        }
    }
}

fn drawHeaderRule(w: *Writer, width: usize) void {
    w.style(SGR_DIM);
    const gutter = gutterWidth();
    // The rule ends at the separator after the last column, or at the pane
    // edge if the columns are wider than the pane.
    var end = gutter + 2;
    for (scroll_col..col_count) |c| {
        if (end >= width) break;
        end += columnSlot(c);
    }
    end = @min(end, width);
    var x: usize = 0;
    var next_cross = gutter + 1;
    var c = scroll_col;
    while (x < end) : (x += 1) {
        if (x == next_cross) {
            w.raw(if (c >= col_count or x + 1 == end) "\xe2\x94\xa4" else "\xe2\x94\xbc");
            next_cross += if (c < col_count) columnSlot(c) else width;
            c += 1;
        } else w.raw("\xe2\x94\x80");
    }
    w.column += end;
    w.reset();
}

fn drawRow(w: *Writer, r: usize, width: usize) void {
    const start = w.column;
    var row = Row{};
    _ = row.load(r);
    var rowid_buf: [24]u8 = undefined;
    const rowid_text = if (row.ok) fmtInt(&rowid_buf, row.rowid) else "?";
    const is_cur_row = r == cur_row;
    const gutter = gutterWidth();
    w.styledField(if (is_cur_row) SGR_BOLD else SGR_DIM, rowid_text, @min(gutter, width), true);
    if (width <= gutter) return;
    w.style(SGR_DIM);
    w.raw(" \xe2\x94\x82");
    w.column += 2;
    w.reset();

    var buf: [CELL_TEXT_CAP]u8 = undefined;
    var c = scroll_col;
    while (c < col_count) : (c += 1) {
        const room = width -| (w.column - start);
        if (room == 0) break;
        const v = row.value(c, &buf);
        const is_cur = is_cur_row and c == cur_col;
        const sgr = if (is_cur)
            (if (focus == .grid) SGR_CURSOR else SGR_CURSOR_INACTIVE)
        else
            valueStyle(v.kind);
        const right_align = v.kind == .integer or v.kind == .real;
        const cell_w = @min(@as(usize, col_chars[c]) + 2, room);
        w.style(sgr);
        if (is_cur_row and !is_cur) w.style(SGR_BOLD);
        w.spaces(@min(1, cell_w));
        w.field(v.text, @min(col_chars[c], cell_w -| 1), right_align);
        w.spaces(cell_w -| (@as(usize, col_chars[c]) + 1));
        w.reset();
        if (width > w.column - start) {
            w.style(SGR_DIM);
            w.raw("\xe2\x94\x82");
            w.column += 1;
            w.reset();
        }
    }
}

// The schema view lists each column, then the CREATE statement wrapped to
// the pane width.
const SchemaLine = struct { kind: enum { heading, column, sql, blank }, index: usize, start: usize, end: usize };

fn schemaChars() usize {
    return @max(8, mainWidth() -| 3);
}

fn schemaLineCount() usize {
    if (!loaded or table_count == 0) return 0;
    var count: usize = 0;
    var it = SchemaLines{};
    while (it.next()) |_| count += 1;
    return count;
}

const SchemaLines = struct {
    stage: u8 = 0,
    col: usize = 0,
    pos: usize = 0,

    fn next(self: *SchemaLines) ?SchemaLine {
        const sql = selected.sql();
        const limit = schemaChars();
        switch (self.stage) {
            0 => {
                self.stage = 1;
                return .{ .kind = .heading, .index = 0, .start = 0, .end = 0 };
            },
            1 => {
                if (self.col < col_count) {
                    self.col += 1;
                    return .{ .kind = .column, .index = self.col - 1, .start = 0, .end = 0 };
                }
                self.stage = 2;
                return .{ .kind = .blank, .index = 0, .start = 0, .end = 0 };
            },
            2 => {
                self.stage = 3;
                return .{ .kind = .heading, .index = 1, .start = 0, .end = 0 };
            },
            3 => {
                if (self.pos >= sql.len) return null;
                const start = self.pos;
                var end = start;
                var cells: usize = 0;
                while (end < sql.len and sql[end] != '\n') {
                    var next_i = end;
                    const cw = codepointWidth(safeCodepoint(nextCodepoint(sql, &next_i)));
                    if (cells + cw > limit) break;
                    cells += cw;
                    end = next_i;
                }
                // Prefer breaking a wrapped line after a space.
                if (end < sql.len and sql[end] != '\n') {
                    var b = end;
                    while (b > start + limit / 2 and sql[b - 1] != ' ') b -= 1;
                    if (b > start + limit / 2) end = b;
                }
                if (end == start) end = start + 1;
                self.pos = if (end < sql.len and sql[end] == '\n') end + 1 else end;
                return .{ .kind = .sql, .index = 0, .start = start, .end = end };
            },
            else => return null,
        }
    }
};

fn drawSchemaLine(w: *Writer, vi: usize, width: usize) void {
    const target = schema_scroll + vi;
    var it = SchemaLines{};
    var line: usize = 0;
    while (it.next()) |l| : (line += 1) {
        if (line != target) continue;
        w.spaces(@min(1, width));
        const room = width -| 1;
        switch (l.kind) {
            .heading => w.styledField(SGR_HEADING, if (l.index == 0) "COLUMNS" else "CREATE STATEMENT", room, false),
            .blank => {},
            .column => {
                const col = cols[l.index];
                const name_w: usize = @min(room, 24);
                w.field(col.name, name_w, false);
                const type_text = if (col.decl_type.len > 0) col.decl_type else "(no type)";
                const type_w: usize = @min(room -| (name_w + 1), 18);
                w.spaces(@min(1, room -| name_w));
                w.styledField(if (col.decl_type.len > 0) SGR_NUMBER else SGR_DIM, type_text, type_w, false);
                if (ipk_column != null and ipk_column.? == l.index) {
                    const rest = room -| (name_w + 1 + type_w);
                    w.spaces(@min(1, rest));
                    w.styledField(SGR_DIM, "rowid alias", rest -| 1, false);
                }
            },
            .sql => _ = w.clipped(selected.sql()[l.start..l.end], room),
        }
        return;
    }
}

fn drawStatus(w: *Writer) void {
    if (table_count == 0) return;
    const t = &tables[sel_table];
    var right_buf: [96]u8 = undefined;
    var rn: usize = 0;
    if (view == .rows and indexed_rows > 0) {
        rn += copyInto(right_buf[rn..], "Row ");
        rn += fmtCountInto(right_buf[rn..], cur_row + 1);
        rn += copyInto(right_buf[rn..], " of ");
        rn += fmtCountInto(right_buf[rn..], indexed_rows);
        if (rows_truncated) rn += copyInto(right_buf[rn..], " indexed");
    }
    const right = right_buf[0..rn];
    const right_w = textWidth(right);
    const left_w = columns -| (right_w + if (right_w > 0) @as(usize, 2) else 0);

    if (rows_damaged and view == .rows) {
        w.styledField(SGR_ERROR, "Part of this table's B-tree could not be read; showing the rows before the damage.", left_w, false);
    } else if (focus == .tables or view == .schema or t.without_rowid or indexed_rows == 0 or col_count == 0) {
        w.spaces(left_w);
    } else {
        // Selected cell: column, declared type, storage class, and value.
        var row = Row{};
        _ = row.load(cur_row);
        var value_buf: [STATUS_TEXT_CAP]u8 = undefined;
        const v = row.value(cur_col, &value_buf);
        var label_buf: [192]u8 = undefined;
        var ln: usize = 0;
        ln += copyInto(label_buf[ln..], cols[cur_col].name);
        if (cols[cur_col].decl_type.len > 0) {
            ln += copyInto(label_buf[ln..], " ");
            ln += copyInto(label_buf[ln..], cols[cur_col].decl_type);
        }
        var meta_buf: [64]u8 = undefined;
        var mn: usize = 0;
        mn += copyInto(meta_buf[mn..], switch (v.kind) {
            .null => " \xc2\xb7 null",
            .missing => " \xc2\xb7 absent from record",
            .integer => " \xc2\xb7 integer",
            .real => " \xc2\xb7 real",
            .text => " \xc2\xb7 text",
            .blob => " \xc2\xb7 blob",
            .damaged => " \xc2\xb7 unreadable",
        });
        if (v.kind == .text or v.kind == .blob) {
            mn += copyInto(meta_buf[mn..], ", ");
            mn += fmtCountInto(meta_buf[mn..], v.bytes);
            mn += copyInto(meta_buf[mn..], if (v.bytes == 1) " byte" else " bytes");
        }
        const start = w.column;
        w.style(SGR_BOLD);
        const label_used = w.clipped(label_buf[0..ln], left_w / 3);
        w.reset();
        w.style(SGR_DIM);
        const meta_used = w.clipped(meta_buf[0..mn], left_w -| label_used);
        w.reset();
        const rest = left_w -| (label_used + meta_used);
        w.spaces(@min(2, rest));
        w.styledField(valueStyle(v.kind), v.text, rest -| 2, false);
        w.spaces(left_w -| (w.column - start));
    }
    if (right_w > 0) {
        w.spaces(2);
        w.styledField(SGR_DIM, right, right_w, false);
    }
}

fn drawHints(w: *Writer) void {
    const hint = if (table_count == 0)
        ""
    else if (focus == .tables)
        "Up/Down table  Tab or Enter rows  [ ] table  s schema"
    else if (view == .schema)
        "Up/Down scroll  s or Esc rows  Tab tables  [ ] table"
    else
        "Arrows move  PgUp/PgDn page  g/G first/last row  [ ] table  s schema  Tab tables";
    w.styledField(SGR_DIM, hint, columns, false);
}

// ---------------------------------------------------------------------------
// Text helpers.

fn utf8SeqLen(lead: u8) usize {
    if (lead < 0xC0) return 1;
    if (lead < 0xE0) return 2;
    if (lead < 0xF0) return 3;
    return 4;
}

/// Decodes one UTF-8 sequence at `i.*` and advances past it. Malformed bytes
/// decode to U+FFFD one byte at a time.
fn nextCodepoint(s: []const u8, i: *usize) u32 {
    const b0 = s[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    const len = utf8SeqLen(b0);
    if (b0 < 0xC2 or b0 > 0xF4 or i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    var cp: u32 = b0 & (@as(u8, 0x7F) >> @intCast(len));
    for (1..len) |k| {
        const b = s[i.* + k];
        if ((b & 0xC0) != 0x80) {
            i.* += 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | (b & 0x3F);
    }
    if ((len == 3 and (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF))) or (len == 4 and (cp < 0x10000 or cp > 0x10FFFF))) {
        i.* += 1;
        return 0xFFFD;
    }
    i.* += len;
    return cp;
}

/// Replaces code points that a terminal would act on or that change the
/// display order: C0 and C1 controls, DEL, bidirectional controls, and
/// zero-width or combining marks that this fixed-width layout cannot place.
fn safeCodepoint(cp: u32) u32 {
    if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) return '?';
    if ((cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xFEFF) return '?';
    if ((cp >= 0x0300 and cp <= 0x036F) or (cp >= 0xFE00 and cp <= 0xFE0F)) return '?';
    return cp;
}

/// Terminal cells for a safe code point: 2 for East Asian wide and emoji
/// ranges, 1 otherwise.
fn codepointWidth(cp: u32) usize {
    if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;
    return 1;
}

fn textWidth(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) n += codepointWidth(safeCodepoint(nextCodepoint(s, &i)));
    return n;
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn fmtInt(buf: []u8, v: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

/// Formats like SQLite's CLI: whole numbers keep a ".0" so they read as reals.
fn fmtReal(buf: []u8, f: f64) []const u8 {
    const text = std.fmt.bufPrint(buf, "{d}", .{f}) catch return "?";
    for (text) |ch| {
        if (ch == '.' or ch == 'e' or ch == 'n' or ch == 'i') return text;
    }
    if (text.len + 2 > buf.len) return text;
    buf[text.len] = '.';
    buf[text.len + 1] = '0';
    return buf[0 .. text.len + 2];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (sqlite.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// SQLite's column affinity rules, in order: INT wins, then CHAR/CLOB/TEXT,
/// then BLOB, then REAL/FLOA/DOUB.
fn hasRealAffinity(decl_type: []const u8) bool {
    if (containsIgnoreCase(decl_type, "INT")) return false;
    if (containsIgnoreCase(decl_type, "CHAR") or containsIgnoreCase(decl_type, "CLOB") or containsIgnoreCase(decl_type, "TEXT")) return false;
    if (containsIgnoreCase(decl_type, "BLOB")) return false;
    return containsIgnoreCase(decl_type, "REAL") or containsIgnoreCase(decl_type, "FLOA") or containsIgnoreCase(decl_type, "DOUB");
}

fn decimalWidth(v: i64) usize {
    var buf: [24]u8 = undefined;
    return fmtInt(&buf, v).len;
}

/// Writes `v` with comma thousands separators and returns the length.
fn fmtCountInto(dst: []u8, v: u64) usize {
    var digits: [24]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{v}) catch return 0;
    var n: usize = 0;
    for (d, 0..) |ch, i| {
        if (i > 0 and (d.len - i) % 3 == 0) {
            if (n >= dst.len) break;
            dst[n] = ',';
            n += 1;
        }
        if (n >= dst.len) break;
        dst[n] = ch;
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests.

test "counts use thousands separators" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", buf[0..fmtCountInto(&buf, 0)]);
    try std.testing.expectEqualStrings("1,048,576", buf[0..fmtCountInto(&buf, 1048576)]);
}

test "wide and unsafe code points have terminal widths" {
    try std.testing.expectEqual(@as(usize, 5), textWidth("caf\xc3\xa9!"));
    try std.testing.expectEqual(@as(usize, 4), textWidth("\xe6\x97\xa5\xe6\x9c\xac"));
    try std.testing.expectEqual(@as(u32, '?'), safeCodepoint(0x202E));
    try std.testing.expectEqual(@as(u32, '?'), safeCodepoint(0x9B));
    var i: usize = 0;
    try std.testing.expectEqual(@as(u32, 0xFFFD), nextCodepoint("\xed\xa0\x80", &i));
}

test "text cells stay on one line" {
    var buf: [32]u8 = undefined;
    const v = formatValue(13 + 2 * 5, "a\nb\tc", &buf);
    try std.testing.expectEqual(ValueKind.text, v.kind);
    try std.testing.expectEqualStrings("a\xc2\xb6b c", v.text);
}

test "blobs show hex and reals keep a decimal point" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("x'00ABFF'", formatValue(12 + 2 * 3, "\x00\xab\xff", &buf).text);
    try std.testing.expectEqualStrings("26.0", fmtReal(&buf, 26));
}

test "column affinity follows SQLite's order" {
    try std.testing.expect(hasRealAffinity("FLOAT"));
    try std.testing.expect(!hasRealAffinity("FLOATING POINT"));
    try std.testing.expect(!hasRealAffinity("INTEGER"));
}
