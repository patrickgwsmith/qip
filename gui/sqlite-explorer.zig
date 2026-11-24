//! SQLite Explorer: browse the tables and rows of a SQLite database file.
//!
//! Input is an `application/vnd.sqlite3` file, read in place with the shared
//! read-only reader in `application/vnd.sqlite3/lib/sqlite.zig`. A sidebar
//! lists the user tables with their row counts; the main pane shows the
//! selected table as a grid of rows, or its columns and CREATE statement.
//!
//! Selecting a table indexes the file offset of every row cell once, so
//! scrolling decodes only the visible rows. Empty input shows an empty state;
//! files that are not readable UTF-8 rollback-journal databases are rejected.
//!
//! Keys: Tab switches between the table list and the grid. Arrows move,
//! Page Up/Down move a page, Home/End go to the first/last column, and
//! Ctrl/Cmd with Up/Down or Home/End go to the first/last row. `[` and `]`
//! select the previous/next table and `s` toggles the schema view.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const sqlite = @import("sqlite");
const mono_font = @import("jetbrains_mono");
const ui_font = @import("inter_regular");

// ---------------------------------------------------------------------------
// Frame geometry. Layout is in points; the frame is rendered at 2x.

const SCALE: i32 = 2;
const SCALE_F: f32 = @floatFromInt(SCALE);
const W: i32 = 640;
const H: i32 = 400;
const RENDER_W: usize = @intCast(W * SCALE);
const RENDER_H: usize = @intCast(H * SCALE);
const PX_W: i32 = @intCast(RENDER_W);
const PX_H: i32 = @intCast(RENDER_H);
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;

const TITLE_H: i32 = 30;
const STATUS_H: i32 = 22;
const SIDEBAR_W: i32 = 172;
const MAIN_X: i32 = SIDEBAR_W + 1;
const MAIN_HEAD_H: i32 = 30;
const GRID_Y: i32 = TITLE_H + MAIN_HEAD_H;
const COL_HEAD_H: i32 = 20;
const BODY_Y: i32 = GRID_Y + COL_HEAD_H;
const BODY_BOTTOM: i32 = H - STATUS_H;
const ROW_H: i32 = 16;
const VISIBLE_ROWS: i32 = @divTrunc(BODY_BOTTOM - BODY_Y, ROW_H);
const SCROLLBAR_W: i32 = 9;
const GRID_RIGHT: i32 = W - SCROLLBAR_W;
const CHAR_W: i32 = 6;
const CELL_PAD: i32 = 6;
const SIDEBAR_LIST_Y: i32 = TITLE_H + 26;
const SIDEBAR_ITEM_H: i32 = 22;
const SIDEBAR_VISIBLE: i32 = @divTrunc(BODY_BOTTOM - SIDEBAR_LIST_Y, SIDEBAR_ITEM_H);
const SCHEMA_LINE_H: i32 = 14;
const SCHEMA_VISIBLE: i32 = @divTrunc(BODY_BOTTOM - GRID_Y - 8, SCHEMA_LINE_H);
const SCHEMA_CHARS: usize = @intCast(@divTrunc(GRID_RIGHT - MAIN_X - 24, CHAR_W));
const TAB_W: i32 = 64;
const TAB_ROWS_X: i32 = W - 12 - 2 * TAB_W;
const TAB_SCHEMA_X: i32 = W - 12 - TAB_W;
const TAB_Y: i32 = TITLE_H + 6;
const TAB_H: i32 = 18;

// ---------------------------------------------------------------------------
// Capacities.

const INPUT_CAP: usize = 16 * 1024 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;
const MAX_TABLES: usize = 256;
const MAX_NAME: usize = 128;
const MAX_ROWS: usize = 1 << 20;
const WIDTH_SAMPLE_ROWS: usize = 200;
const MIN_COL_CHARS: usize = 4;
const MAX_COL_CHARS: usize = 32;
const CELL_TEXT_CAP: usize = 192;
const STATUS_TEXT_CAP: usize = 512;
const SCHEMA_LINE_CAP: usize = 1024;

const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
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
const BTN_PRIMARY: i32 = 1 << 0;

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
// Colours.

const Color = [4]u8;
fn hex(v: u24) Color {
    return .{ @intCast(v >> 16), @intCast((v >> 8) & 0xFF), @intCast(v & 0xFF), 0xFF };
}
const C_BG = hex(0xFFFFFF);
const C_TITLE = hex(0xE9EAEE);
const C_SIDEBAR = hex(0xF2F3F6);
const C_RULE = hex(0xCDD0D6);
const C_GRID_LINE = hex(0xE6E8EC);
const C_STRIPE = hex(0xF8F9FB);
const C_HEAD = hex(0xF1F2F5);
const C_TEXT = hex(0x1D1F23);
const C_DIM = hex(0x6B7079);
const C_FAINT = hex(0x9AA0A8);
const C_SELECT = hex(0x2F6FEB);
const C_SELECT_SOFT = hex(0xDCE6FB);
const C_SELECT_INACTIVE = hex(0xD8DBE1);
const C_WHITE = hex(0xFFFFFF);
const C_NUMBER = hex(0x1F4E9C);
const C_BLOB = hex(0x7A4FB0);
const C_ERROR = hex(0xB3261E);
const C_THUMB = hex(0xB9BEC6);

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
var output_buf: [OUTPUT_BYTES]u8 = undefined;
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
var is_focused: bool = true;

var db: sqlite.Db = undefined;
var loaded: bool = false;
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

var primary_down: bool = false;
var thumb_drag: bool = false;
var thumb_drag_offset: i32 = 0;

// ---------------------------------------------------------------------------
// Content exports.

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_BYTES;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(sqlite.INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return sqlite.INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

export fn render(input_size: u32) RenderResult {
    switch (phase) {
        .initializing => {
            if (input_size > INPUT_CAP) @trap();
            if (load(input_buf[0..input_size])) |reject_offset| {
                return .{ .output_size_or_failure = reject_offset, .output_ptr = 0, .failed = 1 };
            }
            phase = .ready;
        },
        .ready => if (input_size != 0) @trap(),
        .updating => @trap(),
    }
    present();
    return .{
        .output_size_or_failure = @intCast(OUTPUT_BYTES),
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
    if (loaded and table_count > 0) {
        measureRows(scroll_row, @min(indexed_rows, scroll_row + @as(usize, @intCast(VISIBLE_ROWS))), true);
    }
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return begun_at_ms;
}

// 1 while the host window has focus, 0 while it does not. Defaults to 1.
export fn uniform_set_is_focused(value: u32) u32 {
    is_focused = value != 0;
    return @intFromBool(is_focused);
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & FLAG_KEY_DOWN) == 0 or !loaded) return 0;
    return @intFromBool(handleKey(x11_key, flags));
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (phase != .updating) @trap();
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const x = @divFloor(x_px, SCALE);
    const y = @divFloor(y_px, SCALE);
    if (!primary) {
        const was_dragging = thumb_drag;
        primary_down = false;
        thumb_drag = false;
        return @intFromBool(was_dragging);
    }
    if (!loaded) return 0;
    if (primary_down) {
        if (!thumb_drag) return 0;
        return @intFromBool(dragThumbTo(y));
    }
    primary_down = true;
    return @intFromBool(handlePress(x, y));
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

/// Returns null on success or the input offset at which the file is rejected.
fn load(input: []const u8) ?u32 {
    loaded = false;
    table_count = 0;
    tables_truncated = false;
    if (input.len == 0) return null;

    db = sqlite.init(input, &payload_copy_buf) catch |e| return switch (e) {
        error.NotSqlite => 0,
        error.WalMode => 18,
        error.UnsupportedEncoding => 56,
    };
    sqlite.walkTables(&db, ListCtx{}, onListTable);
    if (db.had_error) {
        table_count = 0;
        return 100;
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
    return null;
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
    ensureSidebarVisible();

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
        col_chars[c] = @intCast(std.math.clamp(glyphCount(cols[c].name), MIN_COL_CHARS, MAX_COL_CHARS));
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
            const chars = std.math.clamp(glyphCount(v.text), MIN_COL_CHARS, MAX_COL_CHARS);
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
        // Newlines become a pilcrow (two bytes in UTF-8) and other controls
        // a space, so a cell stays on one line.
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

// ---------------------------------------------------------------------------
// Keyboard.

fn handleKey(key: i32, flags: i32) bool {
    const command = (flags & (FLAG_CTRL | FLAG_META)) != 0;
    switch (key) {
        XK_TAB, XK_ISO_LEFT_TAB => {
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
    if (view == .schema) return handleSchemaKey(key, command);
    return handleGridKey(key, command);
}

fn stepTable(delta: i32) bool {
    if (table_count == 0) return false;
    const next = @as(i64, @intCast(sel_table)) + delta;
    if (next < 0 or next >= @as(i64, @intCast(table_count))) return false;
    selectTable(@intCast(next));
    return true;
}

fn handleTablesKey(key: i32) bool {
    switch (key) {
        XK_UP => return stepTable(-1),
        XK_DOWN => return stepTable(1),
        XK_HOME => return selectIfChanged(0),
        XK_END => return selectIfChanged(table_count - 1),
        XK_PAGE_UP => return selectIfChanged(sel_table -| @as(usize, @intCast(SIDEBAR_VISIBLE))),
        XK_PAGE_DOWN => return selectIfChanged(@min(table_count - 1, sel_table + @as(usize, @intCast(SIDEBAR_VISIBLE)))),
        XK_RETURN, XK_RIGHT => {
            focus = .grid;
            return true;
        },
        else => return false,
    }
}

fn selectIfChanged(index: usize) bool {
    if (index == sel_table) return false;
    selectTable(index);
    return true;
}

fn handleSchemaKey(key: i32, command: bool) bool {
    const max = schemaMaxScroll();
    const before = schema_scroll;
    const page: usize = @intCast(SCHEMA_VISIBLE - 1);
    switch (key) {
        XK_UP => schema_scroll -|= 1,
        XK_DOWN => schema_scroll = @min(max, schema_scroll + 1),
        XK_PAGE_UP => schema_scroll -|= page,
        XK_PAGE_DOWN => schema_scroll = @min(max, schema_scroll + page),
        XK_HOME => schema_scroll = 0,
        XK_END => schema_scroll = max,
        XK_LEFT => {
            if (command) return false;
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
    const page: usize = @intCast(VISIBLE_ROWS - 1);
    switch (key) {
        XK_UP => cur_row = if (command) 0 else cur_row -| 1,
        XK_DOWN => cur_row = if (command) last_row else @min(last_row, cur_row + 1),
        XK_PAGE_UP => cur_row -|= page,
        XK_PAGE_DOWN => cur_row = @min(last_row, cur_row + page),
        XK_HOME => {
            if (command) cur_row = 0 else cur_col = 0;
        },
        XK_END => {
            if (command) cur_row = last_row else cur_col = last_col;
        },
        XK_LEFT => {
            if (cur_col == 0) {
                focus = .tables;
                return true;
            }
            cur_col -= 1;
        },
        XK_RIGHT => cur_col = @min(last_col, cur_col + 1),
        XK_ESCAPE => {
            focus = .tables;
            return true;
        },
        else => return false,
    }
    ensureCellVisible();
    return cur_row != before_row or cur_col != before_col;
}

fn ensureCellVisible() void {
    const visible: usize = @intCast(VISIBLE_ROWS);
    if (cur_row < scroll_row) scroll_row = cur_row;
    if (cur_row >= scroll_row + visible) scroll_row = cur_row + 1 - visible;
    if (cur_col < scroll_col) scroll_col = cur_col;
    while (scroll_col < cur_col and columnRight(cur_col) > GRID_RIGHT) scroll_col += 1;
}

fn ensureSidebarVisible() void {
    const visible: usize = @intCast(SIDEBAR_VISIBLE);
    if (sel_table < sidebar_scroll) sidebar_scroll = sel_table;
    if (sel_table >= sidebar_scroll + visible) sidebar_scroll = sel_table + 1 - visible;
}

fn maxScrollRow() usize {
    return indexed_rows -| @as(usize, @intCast(VISIBLE_ROWS));
}

// ---------------------------------------------------------------------------
// Pointer.

fn handlePress(x: i32, y: i32) bool {
    if (y < TITLE_H or y >= BODY_BOTTOM) return false;
    if (x < SIDEBAR_W) {
        if (y < SIDEBAR_LIST_Y) return false;
        const index = sidebar_scroll + @as(usize, @intCast(@divTrunc(y - SIDEBAR_LIST_Y, SIDEBAR_ITEM_H)));
        if (index >= table_count) return false;
        const changed = index != sel_table or focus != .tables;
        focus = .tables;
        if (index != sel_table) selectTable(index);
        return changed;
    }
    if (table_count == 0) return false;
    if (y >= TAB_Y and y < TAB_Y + TAB_H) {
        if (x >= TAB_ROWS_X and x < TAB_ROWS_X + TAB_W) return setView(.rows);
        if (x >= TAB_SCHEMA_X and x < TAB_SCHEMA_X + TAB_W) return setView(.schema);
        return false;
    }
    if (view == .schema) return false;
    if (y < BODY_Y) return false;
    if (x >= GRID_RIGHT) return pressScrollbar(y);

    const focus_changed = focus != .grid;
    focus = .grid;
    const r = scroll_row + @as(usize, @intCast(@divTrunc(y - BODY_Y, ROW_H)));
    if (r >= indexed_rows) return focus_changed;
    var c = scroll_col;
    var hit: ?usize = null;
    while (c < col_count) : (c += 1) {
        const left = columnLeft(c);
        if (left >= GRID_RIGHT) break;
        if (x >= left and x < columnRight(c)) {
            hit = c;
            break;
        }
    }
    const before_row = cur_row;
    const before_col = cur_col;
    cur_row = r;
    if (hit) |col| cur_col = col;
    ensureCellVisible();
    return focus_changed or cur_row != before_row or cur_col != before_col;
}

fn setView(v: View) bool {
    if (view == v) return false;
    view = v;
    return true;
}

const Thumb = struct { y: i32, h: i32, track_y: i32, track_h: i32 };

fn thumbGeometry() ?Thumb {
    const visible: usize = @intCast(VISIBLE_ROWS);
    if (indexed_rows <= visible) return null;
    const track_y = BODY_Y + 2;
    const track_h = BODY_BOTTOM - BODY_Y - 4;
    const ratio = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(indexed_rows));
    const h: i32 = @max(18, @as(i32, @intFromFloat(@as(f32, @floatFromInt(track_h)) * ratio)));
    const max = maxScrollRow();
    const t = @as(f32, @floatFromInt(scroll_row)) / @as(f32, @floatFromInt(max));
    const y = track_y + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(track_h - h)) * t)));
    return .{ .y = y, .h = h, .track_y = track_y, .track_h = track_h };
}

fn pressScrollbar(y: i32) bool {
    const thumb = thumbGeometry() orelse return false;
    if (y >= thumb.y and y < thumb.y + thumb.h) {
        thumb_drag = true;
        thumb_drag_offset = y - thumb.y;
        return false;
    }
    const page: usize = @intCast(VISIBLE_ROWS - 1);
    const before = scroll_row;
    scroll_row = if (y < thumb.y) scroll_row -| page else @min(maxScrollRow(), scroll_row + page);
    keepCursorInView();
    return scroll_row != before;
}

fn dragThumbTo(y: i32) bool {
    const thumb = thumbGeometry() orelse return false;
    const span = thumb.track_h - thumb.h;
    if (span <= 0) return false;
    const pos = std.math.clamp(y - thumb_drag_offset - thumb.track_y, 0, span);
    const t = @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(span));
    const before = scroll_row;
    scroll_row = @intFromFloat(@round(t * @as(f32, @floatFromInt(maxScrollRow()))));
    keepCursorInView();
    return scroll_row != before;
}

fn keepCursorInView() void {
    const visible: usize = @intCast(VISIBLE_ROWS);
    if (cur_row < scroll_row) cur_row = scroll_row;
    if (cur_row >= scroll_row + visible) cur_row = scroll_row + visible - 1;
}

// ---------------------------------------------------------------------------
// Column geometry.

fn columnWidth(c: usize) i32 {
    return @as(i32, col_chars[c]) * CHAR_W + 2 * CELL_PAD;
}

fn gutterWidth() i32 {
    return @as(i32, @intCast(rowid_chars)) * CHAR_W + 2 * CELL_PAD;
}

fn columnLeft(c: usize) i32 {
    var x = MAIN_X + gutterWidth();
    var i = scroll_col;
    while (i < c) : (i += 1) x += columnWidth(i);
    return x;
}

fn columnRight(c: usize) i32 {
    return columnLeft(c) + columnWidth(c);
}

// ---------------------------------------------------------------------------
// Drawing.

fn present() void {
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    clipAll();
    fillRect(0, 0, W, H, C_BG);
    drawTitleBar();
    drawStatusBar();
    if (!loaded) {
        drawEmptyState();
        return;
    }
    drawSidebar();
    drawMain();
}

fn drawTitleBar() void {
    fillRect(0, 0, W, TITLE_H, C_TITLE);
    fillRect(0, TITLE_H - 1, W, 1, C_RULE);
    drawUi(12, 19.5, 13, 0.35, "SQLite Explorer", C_TEXT, 200);
    if (!loaded) return;
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    n += fmtCountInto(buf[n..], table_count);
    n += copyInto(buf[n..], if (table_count == 1) " table" else " tables");
    n += copyInto(buf[n..], if (tables_truncated) "+  \xc2\xb7  " else "  \xc2\xb7  ");
    n += fmtCountInto(buf[n..], db.page_count);
    n += copyInto(buf[n..], if (db.page_count == 1) " page of " else " pages of ");
    n += fmtCountInto(buf[n..], db.page_size);
    n += copyInto(buf[n..], " bytes");
    const text = buf[0..n];
    const w = uiWidth(11, text);
    drawUi(@as(f32, @floatFromInt(W - 12)) - w, 19, 11, 0, text, C_DIM, 400);
}

fn drawEmptyState() void {
    const cx: f32 = @floatFromInt(@divTrunc(W, 2));
    const line1 = "No database loaded";
    const line2 = "Pass a SQLite file as input, for example:";
    const line3 = "qipgui gui/sqlite-explorer.wasm -i data.sqlite";
    drawUi(cx - uiWidth(16, line1) / 2, 170, 16, 0.4, line1, C_TEXT, 600);
    drawUi(cx - uiWidth(11, line2) / 2, 196, 11, 0, line2, C_DIM, 600);
    const mono_w: i32 = @intCast(glyphCount(line3) * @as(usize, @intCast(CHAR_W)));
    drawMono(@divTrunc(W - mono_w, 2), 206, line3, 200, C_TEXT);
}

fn drawSidebar() void {
    clipAll();
    fillRect(0, TITLE_H, SIDEBAR_W, BODY_BOTTOM - TITLE_H, C_SIDEBAR);
    fillRect(SIDEBAR_W, TITLE_H, 1, BODY_BOTTOM - TITLE_H, C_RULE);
    drawUi(12, @floatFromInt(TITLE_H + 17), 10, 0.3, "TABLES", C_DIM, 100);

    if (table_count == 0) {
        drawUi(12, @floatFromInt(SIDEBAR_LIST_Y + 15), 11, 0, "No tables", C_FAINT, 140);
        return;
    }
    clipRect(0, SIDEBAR_LIST_Y, SIDEBAR_W, BODY_BOTTOM - SIDEBAR_LIST_Y);
    var vi: i32 = 0;
    while (vi < SIDEBAR_VISIBLE + 1) : (vi += 1) {
        const i = sidebar_scroll + @as(usize, @intCast(vi));
        if (i >= table_count) break;
        const t = &tables[i];
        const y = SIDEBAR_LIST_Y + vi * SIDEBAR_ITEM_H;
        const is_sel = i == sel_table;
        const strong = is_sel and focus == .tables and is_focused;
        if (is_sel) fillRect(6, y + 1, SIDEBAR_W - 12, SIDEBAR_ITEM_H - 2, if (strong) C_SELECT else C_SELECT_INACTIVE);
        var count_buf: [32]u8 = undefined;
        const count_text = if (t.without_rowid)
            "\xe2\x80\x94"
        else if (t.damaged)
            "!"
        else
            count_buf[0..fmtCountInto(&count_buf, t.row_count)];
        const count_w = uiWidth(10, count_text);
        const count_x = @as(f32, @floatFromInt(SIDEBAR_W - 14)) - count_w;
        const base: f32 = @floatFromInt(y + 15);
        drawUi(count_x, base, 10, 0, count_text, if (strong) C_WHITE else C_FAINT, 80);
        drawUi(14, base, 11.5, 0, t.name(), if (strong) C_WHITE else C_TEXT, count_x - 22);
    }
    clipAll();
}

fn drawMain() void {
    clipAll();
    if (table_count == 0) {
        drawUi(@floatFromInt(MAIN_X + 16), @floatFromInt(GRID_Y + 24), 12, 0, "This database has no user tables.", C_DIM, 400);
        return;
    }
    const t = &tables[sel_table];
    const name_max: f32 = @floatFromInt(TAB_ROWS_X - MAIN_X - 24);
    drawUi(@floatFromInt(MAIN_X + 12), @floatFromInt(TITLE_H + 19), 13, 0.35, t.name(), C_TEXT, name_max * 0.6);
    var sub_buf: [96]u8 = undefined;
    var n: usize = 0;
    n += fmtCountInto(sub_buf[n..], col_count);
    n += copyInto(sub_buf[n..], if (col_count == 1) " column" else " columns");
    if (!t.without_rowid) {
        n += copyInto(sub_buf[n..], ", ");
        n += fmtCountInto(sub_buf[n..], t.row_count);
        n += copyInto(sub_buf[n..], if (t.row_count == 1) " row" else " rows");
    }
    const title_w = @min(uiWidth(13, t.name()) + 0.35 * 2, name_max * 0.6);
    const sub_x = @as(f32, @floatFromInt(MAIN_X + 12)) + title_w + 10;
    drawUi(sub_x, @floatFromInt(TITLE_H + 19), 11, 0, sub_buf[0..n], C_DIM, @as(f32, @floatFromInt(TAB_ROWS_X - 12)) - sub_x);
    drawTab(TAB_ROWS_X, "Rows", view == .rows);
    drawTab(TAB_SCHEMA_X, "Schema", view == .schema);
    fillRect(MAIN_X, GRID_Y - 1, W - MAIN_X, 1, C_RULE);

    if (view == .schema) {
        drawSchema();
        return;
    }
    if (t.without_rowid) {
        drawUi(@floatFromInt(MAIN_X + 16), @floatFromInt(GRID_Y + 24), 12, 0, "WITHOUT ROWID tables are not readable yet.", C_DIM, 420);
        drawUi(@floatFromInt(MAIN_X + 16), @floatFromInt(GRID_Y + 42), 11, 0, "Press S to see the schema.", C_FAINT, 420);
        return;
    }
    drawGrid();
}

fn drawTab(x: i32, label: []const u8, active: bool) void {
    if (active) {
        fillRect(x, TAB_Y, TAB_W, TAB_H, C_SELECT_SOFT);
    }
    const w = uiWidth(11, label);
    const lx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(TAB_W)) - w) / 2;
    drawUi(lx, @floatFromInt(TAB_Y + 13), 11, if (active) 0.3 else 0, label, if (active) C_SELECT else C_DIM, 100);
}

fn drawGrid() void {
    const gutter = gutterWidth();
    // Column header.
    clipRect(MAIN_X, GRID_Y, GRID_RIGHT - MAIN_X, BODY_BOTTOM - GRID_Y);
    fillRect(MAIN_X, GRID_Y, W - MAIN_X, COL_HEAD_H, C_HEAD);
    fillRect(MAIN_X, BODY_Y - 1, W - MAIN_X, 1, C_RULE);
    drawUi(@floatFromInt(MAIN_X + CELL_PAD), @floatFromInt(GRID_Y + 14), 10, 0, "rowid", C_FAINT, @floatFromInt(gutter - CELL_PAD));

    var c = scroll_col;
    while (c < col_count) : (c += 1) {
        const left = columnLeft(c);
        if (left >= GRID_RIGHT) break;
        const cw = columnWidth(c);
        fillRect(left, GRID_Y + 4, 1, COL_HEAD_H - 8, C_RULE);
        const is_cur = c == cur_col and focus == .grid;
        clipRect(left, GRID_Y, @min(cw, GRID_RIGHT - left), COL_HEAD_H);
        drawUi(@floatFromInt(left + CELL_PAD), @floatFromInt(GRID_Y + 14), 10.5, 0.3, cols[c].name, if (is_cur) C_SELECT else C_TEXT, @floatFromInt(cw - CELL_PAD * 2));
        clipRect(MAIN_X, GRID_Y, GRID_RIGHT - MAIN_X, BODY_BOTTOM - GRID_Y);
    }

    // Rows.
    var buf: [CELL_TEXT_CAP]u8 = undefined;
    var rowid_buf: [24]u8 = undefined;
    var vr: i32 = 0;
    while (vr < VISIBLE_ROWS) : (vr += 1) {
        const r = scroll_row + @as(usize, @intCast(vr));
        if (r >= indexed_rows) break;
        const y = BODY_Y + vr * ROW_H;
        clipRect(MAIN_X, BODY_Y, GRID_RIGHT - MAIN_X, BODY_BOTTOM - BODY_Y);
        if ((r & 1) == 1) fillRect(MAIN_X, y, GRID_RIGHT - MAIN_X, ROW_H, C_STRIPE);
        const is_cur_row = r == cur_row;
        if (is_cur_row) fillRect(MAIN_X, y, GRID_RIGHT - MAIN_X, ROW_H, C_SELECT_SOFT);
        fillRect(MAIN_X, y + ROW_H - 1, GRID_RIGHT - MAIN_X, 1, C_GRID_LINE);

        var row = Row{};
        _ = row.load(r);
        const rowid_text = if (row.ok) fmtInt(&rowid_buf, row.rowid) else "?";
        const rid_w: i32 = @intCast(glyphCount(rowid_text) * @as(usize, @intCast(CHAR_W)));
        drawMono(MAIN_X + gutter - CELL_PAD - rid_w, y, rowid_text, rowid_chars, C_FAINT);

        c = scroll_col;
        while (c < col_count) : (c += 1) {
            const left = columnLeft(c);
            if (left >= GRID_RIGHT) break;
            const cw = columnWidth(c);
            const visible_w = @min(cw, GRID_RIGHT - left);
            clipRect(left, y, visible_w, ROW_H);
            const is_cur = is_cur_row and c == cur_col;
            const strong = is_cur and focus == .grid and is_focused;
            if (is_cur) fillRect(left, y, cw, ROW_H - 1, if (strong) C_SELECT else C_SELECT_INACTIVE);
            const v = row.value(c, &buf);
            const color: Color = if (strong) C_WHITE else switch (v.kind) {
                .null, .missing => C_FAINT,
                .integer, .real => C_NUMBER,
                .blob => C_BLOB,
                .damaged => C_ERROR,
                .text => C_TEXT,
            };
            const max_chars: usize = col_chars[c];
            const chars = @min(glyphCount(v.text), max_chars);
            const right_align = v.kind == .integer or v.kind == .real;
            const tx = if (right_align) left + cw - CELL_PAD - @as(i32, @intCast(chars)) * CHAR_W else left + CELL_PAD;
            drawMono(tx, y, v.text, max_chars, color);
        }
    }
    clipAll();
    fillRect(MAIN_X + gutter - 1, GRID_Y, 1, BODY_BOTTOM - GRID_Y, C_GRID_LINE);

    // Scrollbar.
    fillRect(GRID_RIGHT, BODY_Y, SCROLLBAR_W, BODY_BOTTOM - BODY_Y, C_HEAD);
    fillRect(GRID_RIGHT, BODY_Y, 1, BODY_BOTTOM - BODY_Y, C_GRID_LINE);
    if (thumbGeometry()) |thumb| {
        fillRect(GRID_RIGHT + 2, thumb.y, SCROLLBAR_W - 4, thumb.h, if (thumb_drag) C_DIM else C_THUMB);
    }

    if (indexed_rows == 0) {
        const msg = if (rows_damaged) "The table's B-tree could not be read." else "This table has no rows.";
        drawUi(@floatFromInt(MAIN_X + 16), @floatFromInt(BODY_Y + 22), 12, 0, msg, if (rows_damaged) C_ERROR else C_DIM, 400);
    }
}

// The schema view lists each column, then the CREATE statement wrapped to
// the pane width.
const SchemaLine = struct { kind: enum { heading, column, sql, blank }, index: usize, start: usize, end: usize };

fn schemaLineCount() usize {
    var count: usize = 0;
    var it = SchemaLines{};
    while (it.next()) |_| count += 1;
    return count;
}

fn schemaMaxScroll() usize {
    return schemaLineCount() -| @as(usize, @intCast(SCHEMA_VISIBLE));
}

const SchemaLines = struct {
    stage: u8 = 0,
    col: usize = 0,
    pos: usize = 0,

    fn next(self: *SchemaLines) ?SchemaLine {
        const sql = selected.sql();
        while (true) {
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
                    var glyphs: usize = 0;
                    while (end < sql.len and sql[end] != '\n' and glyphs < SCHEMA_CHARS) {
                        end += utf8SeqLen(sql[end]);
                        glyphs += 1;
                    }
                    end = @min(end, sql.len);
                    // Prefer breaking a wrapped line after a space.
                    if (end < sql.len and sql[end] != '\n') {
                        var b = end;
                        while (b > start + SCHEMA_CHARS / 2 and sql[b - 1] != ' ') b -= 1;
                        if (b > start + SCHEMA_CHARS / 2) end = b;
                    }
                    self.pos = if (end < sql.len and sql[end] == '\n') end + 1 else end;
                    return .{ .kind = .sql, .index = 0, .start = start, .end = end };
                },
                else => return null,
            }
        }
    }
};

fn drawSchema() void {
    const x0 = MAIN_X + 16;
    clipRect(MAIN_X, GRID_Y, W - MAIN_X, BODY_BOTTOM - GRID_Y);
    var it = SchemaLines{};
    var line: usize = 0;
    const sql = selected.sql();
    while (it.next()) |l| : (line += 1) {
        if (line < schema_scroll) continue;
        const vi: i32 = @intCast(line - schema_scroll);
        if (vi >= SCHEMA_VISIBLE) break;
        const y = GRID_Y + 8 + vi * SCHEMA_LINE_H;
        switch (l.kind) {
            .heading => drawUi(@floatFromInt(x0), @floatFromInt(y + 11), 10, 0.3, if (l.index == 0) "COLUMNS" else "CREATE STATEMENT", C_DIM, 300),
            .blank => {},
            .column => {
                const col = cols[l.index];
                drawMono(x0, y - 1, col.name, 24, C_TEXT);
                const type_text = if (col.decl_type.len > 0) col.decl_type else "(no type)";
                drawMono(x0 + 26 * CHAR_W, y - 1, type_text, 18, if (col.decl_type.len > 0) C_NUMBER else C_FAINT);
                if (ipk_column != null and ipk_column.? == l.index) {
                    drawMono(x0 + 46 * CHAR_W, y - 1, "rowid alias", 14, C_FAINT);
                }
            },
            .sql => drawMono(x0, y - 1, sql[l.start..l.end], SCHEMA_CHARS, C_TEXT),
        }
    }
    clipAll();
}

fn drawStatusBar() void {
    const y = H - STATUS_H;
    fillRect(0, y, W, STATUS_H, C_TITLE);
    fillRect(0, y, W, 1, C_RULE);
    const base: f32 = @floatFromInt(y + 15);
    if (!loaded) return;
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
    const right_w = uiWidth(11, right);
    drawUi(@as(f32, @floatFromInt(W - 12)) - right_w, base, 11, 0, right, C_DIM, 200);
    const left_max = @as(f32, @floatFromInt(W - 36)) - right_w;

    if (rows_damaged and view == .rows) {
        drawUi(12, base, 11, 0, "Part of this table's B-tree could not be read; showing the rows before the damage.", C_ERROR, left_max);
        return;
    }
    if (focus == .tables or view == .schema or t.without_rowid or indexed_rows == 0 or col_count == 0) {
        const hint = if (focus == .tables)
            "Up/Down choose a table. Tab or Return moves to the rows. S shows the schema."
        else if (view == .schema)
            "Up/Down scroll. S or Esc returns to the rows."
        else
            "Tab moves to the table list.";
        drawUi(12, base, 11, 0, hint, C_DIM, left_max);
        return;
    }

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
    ln += copyInto(label_buf[ln..], switch (v.kind) {
        .null => "  \xc2\xb7  null",
        .missing => "  \xc2\xb7  absent from record",
        .integer => "  \xc2\xb7  integer",
        .real => "  \xc2\xb7  real",
        .text => "  \xc2\xb7  text",
        .blob => "  \xc2\xb7  blob",
        .damaged => "  \xc2\xb7  unreadable",
    });
    if (v.kind == .text or v.kind == .blob) {
        ln += copyInto(label_buf[ln..], ", ");
        ln += fmtCountInto(label_buf[ln..], v.bytes);
        ln += copyInto(label_buf[ln..], if (v.bytes == 1) " byte" else " bytes");
    }
    const label = label_buf[0..ln];
    const label_w = @min(uiWidth(11, label) + 0.6, left_max * 0.5);
    drawUi(12, base, 11, 0.3, label, C_TEXT, left_max * 0.5);
    const value_x: i32 = @intFromFloat(@ceil(12 + label_w + 12));
    const value_chars: usize = @intCast(@max(0, @divTrunc(@as(i32, @intFromFloat(left_max)) + 12 - value_x, CHAR_W)));
    drawMono(value_x, y + 4, v.text, value_chars, if (v.kind == .null or v.kind == .missing) C_FAINT else C_TEXT);
}

// ---------------------------------------------------------------------------
// Text: a JetBrains Mono atlas for cells and Inter outlines for labels. The
// rasterizer accumulates signed edge coverage, as in gui/textedit.zig.

const MONO_SIZE_RATIO: f32 = @as(f32, @floatFromInt(CHAR_W * SCALE));
const MONO_CELL_W: usize = @intCast((CHAR_W + 2) * SCALE);
const MONO_CELL_H: usize = @intCast(ROW_H * SCALE);
const MONO_BASELINE: f32 = 12.0;
const MONO_EXTRA = [_]u32{ 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x20AC, 0x2122 };
const MONO_SLOTS: usize = 95 + 96 + MONO_EXTRA.len;
const ELLIPSIS: u32 = 0x2026;
var mono_atlas: [MONO_SLOTS][MONO_CELL_W * MONO_CELL_H]u8 = undefined;
var mono_atlas_ready: bool = false;

fn monoSlot(cp: u32) usize {
    if (cp >= 0x20 and cp <= 0x7E) return cp - 0x20;
    if (cp >= 0xA0 and cp <= 0xFF) return 95 + (cp - 0xA0);
    for (MONO_EXTRA, 0..) |e, i| {
        if (e == cp) return 95 + 96 + i;
    }
    return '?' - 0x20;
}

fn slotCodepoint(slot: usize) u32 {
    if (slot < 95) return @intCast(0x20 + slot);
    if (slot < 95 + 96) return @intCast(0xA0 + slot - 95);
    return MONO_EXTRA[slot - 95 - 96];
}

fn buildMonoAtlas() void {
    if (mono_atlas_ready) return;
    mono_atlas_ready = true;
    const space = mono_font.glyphIndex(' ').?;
    const scale = MONO_SIZE_RATIO / @as(f32, @floatFromInt(mono_font.advances[space]));
    const fallback = mono_font.glyphIndex('?').?;
    for (0..MONO_SLOTS) |s| {
        const g = mono_font.glyphIndex(slotCodepoint(s)) orelse fallback;
        accReset(MONO_CELL_W, MONO_CELL_H);
        accPath(mono_font.glyph_paths[g], scale, SCALE_F, MONO_BASELINE * SCALE_F);
        var sum: f32 = 0;
        for (0..MONO_CELL_W * MONO_CELL_H) |i| {
            sum += acc[i];
            mono_atlas[s][i] = @intFromFloat(@round(coverageToAlpha(sum) * 255));
        }
    }
}

/// Draws monospaced text with the row top at `top` points, truncating with an
/// ellipsis after `max_glyphs`.
fn drawMono(x: i32, top: i32, text: []const u8, max_glyphs: usize, c: Color) void {
    buildMonoAtlas();
    if (max_glyphs == 0) return;
    const total = glyphCount(text);
    const truncate = total > max_glyphs;
    const keep = if (truncate) max_glyphs - 1 else total;
    var i: usize = 0;
    var n: usize = 0;
    while (n < keep and i < text.len) : (n += 1) {
        const cp = nextCodepoint(text, &i);
        drawMonoGlyph(x + @as(i32, @intCast(n)) * CHAR_W, top, cp, c);
    }
    if (truncate) {
        drawMonoGlyph(x + @as(i32, @intCast(n)) * CHAR_W, top, ELLIPSIS, c);
    }
}

fn drawMonoGlyph(x: i32, top: i32, cp: u32, c: Color) void {
    // Controls such as tabs in CREATE statements take one blank cell.
    if (cp <= ' ' or cp == 0x7F or cp == 0xA0) return;
    const g = &mono_atlas[monoSlot(cp)];
    const px0 = x * SCALE - SCALE;
    const py0 = top * SCALE;
    if (px0 + @as(i32, @intCast(MONO_CELL_W)) <= clip_x0 or px0 >= clip_x1) return;
    if (py0 + @as(i32, @intCast(MONO_CELL_H)) <= clip_y0 or py0 >= clip_y1) return;
    for (0..MONO_CELL_H) |cy| {
        for (0..MONO_CELL_W) |cx| {
            const a = g[cy * MONO_CELL_W + cx];
            if (a == 0) continue;
            blendPixel(px0 + @as(i32, @intCast(cx)), py0 + @as(i32, @intCast(cy)), c, @as(f32, @floatFromInt(a)) / 255.0);
        }
    }
}

fn uiAdvance(cp: u32) f32 {
    const g = ui_font.glyphIndex(cp) orelse ui_font.glyphIndex('?').?;
    return @floatFromInt(ui_font.advances[g]);
}

fn uiWidth(size: f32, text: []const u8) f32 {
    const scale = size / ui_font.UNITS_PER_EM;
    var w: f32 = 0;
    var i: usize = 0;
    while (i < text.len) w += uiAdvance(nextCodepoint(text, &i)) * scale;
    return w;
}

/// Draws proportional text with its baseline at `baseline` points. Text wider
/// than `max_w` points is cut and ends with an ellipsis. `weight` smears the
/// outline sideways by that many points for a semibold look.
fn drawUi(x_pt: f32, baseline_pt: f32, size_pt: f32, weight_pt: f32, text: []const u8, c: Color, max_w: f32) void {
    if (text.len == 0 or max_w <= 0) return;
    const scale_pt = size_pt / ui_font.UNITS_PER_EM;
    var end = text.len;
    var ellipsis = false;
    if (uiWidth(size_pt, text) > max_w) {
        ellipsis = true;
        const budget = max_w - uiAdvance(ELLIPSIS) * scale_pt;
        var w: f32 = 0;
        var i: usize = 0;
        end = 0;
        while (i < text.len) {
            const adv = uiAdvance(nextCodepoint(text, &i)) * scale_pt;
            if (w + adv > budget) break;
            w += adv;
            end = i;
        }
    }
    const x = x_pt * SCALE_F;
    const baseline = baseline_pt * SCALE_F;
    const size = size_pt * SCALE_F;
    const weight = weight_pt * SCALE_F;
    const scale = size / ui_font.UNITS_PER_EM;
    const left = @floor(x) - 1;
    const top = @floor(baseline - size) - 1;
    const w_px: usize = @intFromFloat(@ceil(@min(uiWidth(size_pt, text), max_w + 2) * SCALE_F + weight) + 6);
    const h_px: usize = @intFromFloat(@ceil(size * 1.3) + 3);
    accReset(w_px, h_px);
    var pen = x - left;
    const by = baseline - top;
    var i: usize = 0;
    while (i < end) {
        const cp = nextCodepoint(text, &i);
        const g = ui_font.glyphIndex(cp) orelse ui_font.glyphIndex('?').?;
        accPath(ui_font.glyph_paths[g], scale, pen, by);
        if (weight > 0) accPath(ui_font.glyph_paths[g], scale, pen + weight, by);
        pen += @as(f32, @floatFromInt(ui_font.advances[g])) * scale;
    }
    if (ellipsis) {
        if (ui_font.glyphIndex(ELLIPSIS)) |g| {
            accPath(ui_font.glyph_paths[g], scale, pen, by);
        } else {
            const dot = ui_font.glyphIndex('.').?;
            for (0..3) |_| {
                accPath(ui_font.glyph_paths[dot], scale, pen, by);
                pen += @as(f32, @floatFromInt(ui_font.advances[dot])) * scale;
            }
        }
    }
    accBlend(@intFromFloat(left), @intFromFloat(top), c);
}

const ACC_W_MAX: usize = RENDER_W + 8;
const ACC_H_MAX: usize = 64;
var acc: [ACC_W_MAX * ACC_H_MAX + 1]f32 = undefined;
var acc_w: usize = 0;
var acc_h: usize = 0;

fn accReset(w: usize, h: usize) void {
    acc_w = @min(w, ACC_W_MAX);
    acc_h = @min(h, ACC_H_MAX);
    @memset(acc[0 .. acc_w * acc_h + 1], 0);
}

// Signed-area accumulation of one edge, as in font-rs: each row gains the
// edge's coverage, and a running sum across the buffer gives winding.
fn accLine(xa_in: f32, ya: f32, xb_in: f32, yb: f32) void {
    if (ya == yb) return;
    const max_x = @as(f32, @floatFromInt(acc_w)) - 1.001;
    const xa = std.math.clamp(xa_in, 0, max_x);
    const xb = std.math.clamp(xb_in, 0, max_x);
    var dir: f32 = 1;
    var x0 = xa;
    var y0 = ya;
    var x1 = xb;
    var y1 = yb;
    if (ya > yb) {
        dir = -1;
        x0 = xb;
        y0 = yb;
        x1 = xa;
        y1 = ya;
    }
    const dxdy = (x1 - x0) / (y1 - y0);
    var x = x0;
    if (y0 < 0) x -= y0 * dxdy;
    const hf: f32 = @floatFromInt(acc_h);
    const y_end_f = @min(hf, @ceil(y1));
    if (y_end_f <= 0 or y0 >= hf) return;
    const y_start: usize = @intFromFloat(@max(0, @floor(y0)));
    const y_end: usize = @intFromFloat(y_end_f);
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const ls = y * acc_w;
        const dy = @min(yf + 1, y1) - @max(yf, y0);
        const x_next = x + dxdy * dy;
        const d = dy * dir;
        const xl = @min(x, x_next);
        const xr = @max(x, x_next);
        const xl_floor = @floor(xl);
        const xli: usize = @intFromFloat(xl_floor);
        const xr_ceil = @ceil(xr);
        const xri: usize = @intFromFloat(xr_ceil);
        if (xri <= xli + 1) {
            const xmf = 0.5 * (x + x_next) - xl_floor;
            acc[ls + xli] += d - d * xmf;
            acc[ls + xli + 1] += d * xmf;
        } else {
            const s = 1.0 / (xr - xl);
            const xlf = xl - xl_floor;
            const a0 = 0.5 * s * (1 - xlf) * (1 - xlf);
            const xrf = xr - xr_ceil + 1;
            const am = 0.5 * s * xrf * xrf;
            acc[ls + xli] += d * a0;
            if (xri == xli + 2) {
                acc[ls + xli + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - xlf);
                acc[ls + xli + 1] += d * (a1 - a0);
                var xi = xli + 2;
                while (xi < xri - 1) : (xi += 1) acc[ls + xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(xri - xli - 3)) * s;
                acc[ls + xri - 1] += d * (1 - a2 - am);
            }
            acc[ls + xri] += d * am;
        }
        x = x_next;
    }
}

fn accQuad(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) void {
    const ddx = x0 - 2 * x1 + x2;
    const ddy = y0 - 2 * y1 + y2;
    const dev = @sqrt(ddx * ddx + ddy * ddy);
    const n: usize = @intFromFloat(std.math.clamp(@ceil(@sqrt(dev * 2)), 1, 16));
    var px = x0;
    var py = y0;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const mt = 1 - t;
        const qx = mt * mt * x0 + 2 * t * mt * x1 + t * t * x2;
        const qy = mt * mt * y0 + 2 * t * mt * y1 + t * t * y2;
        accLine(px, py, qx, qy);
        px = qx;
        py = qy;
    }
}

const PathReader = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(self: *PathReader) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == ',')) self.i += 1;
    }

    fn peek(self: *PathReader) ?u8 {
        self.skip();
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }

    fn num(self: *PathReader) f32 {
        self.skip();
        var neg = false;
        if (self.i < self.s.len and self.s[self.i] == '-') {
            neg = true;
            self.i += 1;
        }
        var v: f32 = 0;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') : (self.i += 1) {
            v = v * 10 + @as(f32, @floatFromInt(self.s[self.i] - '0'));
        }
        if (self.i < self.s.len and self.s[self.i] == '.') {
            self.i += 1;
            var scale: f32 = 0.1;
            while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') : (self.i += 1) {
                v += @as(f32, @floatFromInt(self.s[self.i] - '0')) * scale;
                scale *= 0.1;
            }
        }
        return if (neg) -v else v;
    }
};

// Adds a glyph outline with its origin at (ox, oy).
fn accPath(path: []const u8, scale: f32, ox: f32, oy: f32) void {
    var r = PathReader{ .s = path };
    var cmd: u8 = 'M';
    var cx: f32 = 0;
    var cy: f32 = 0;
    var sx: f32 = 0;
    var sy: f32 = 0;
    while (r.peek()) |c| {
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
            r.i += 1;
            cmd = c;
            if (c == 'Z' or c == 'z') {
                accLine(cx, cy, sx, sy);
                cx = sx;
                cy = sy;
            }
            continue;
        }
        switch (cmd) {
            'M' => {
                if (cx != sx or cy != sy) accLine(cx, cy, sx, sy);
                cx = ox + r.num() * scale;
                cy = oy + r.num() * scale;
                sx = cx;
                sy = cy;
                cmd = 'L';
            },
            'L' => {
                const x = ox + r.num() * scale;
                const y = oy + r.num() * scale;
                accLine(cx, cy, x, y);
                cx = x;
                cy = y;
            },
            'Q' => {
                const qx = ox + r.num() * scale;
                const qy = oy + r.num() * scale;
                const x = ox + r.num() * scale;
                const y = oy + r.num() * scale;
                accQuad(cx, cy, qx, qy, x, y);
                cx = x;
                cy = y;
            },
            else => r.i += 1,
        }
    }
    if (cx != sx or cy != sy) accLine(cx, cy, sx, sy);
}

fn coverageToAlpha(sum: f32) f32 {
    const cov = @min(1.0, @abs(sum));
    // A slight boost keeps unhinted small type from looking washed out.
    return cov + 0.2 * cov * (1 - cov);
}

fn accBlend(dst_x: i32, dst_y: i32, c: Color) void {
    var sum: f32 = 0;
    var y: usize = 0;
    while (y < acc_h) : (y += 1) {
        var x: usize = 0;
        while (x < acc_w) : (x += 1) {
            sum += acc[y * acc_w + x];
            const a = coverageToAlpha(sum);
            if (a > 0.004) blendPixel(dst_x + @as(i32, @intCast(x)), dst_y + @as(i32, @intCast(y)), c, a);
        }
    }
}

// ---------------------------------------------------------------------------
// Pixels. Every write is limited to the current clip rectangle.

var clip_x0: i32 = 0;
var clip_y0: i32 = 0;
var clip_x1: i32 = PX_W;
var clip_y1: i32 = PX_H;

fn clipAll() void {
    clip_x0 = 0;
    clip_y0 = 0;
    clip_x1 = PX_W;
    clip_y1 = PX_H;
}

fn clipRect(x: i32, y: i32, w: i32, h: i32) void {
    clip_x0 = std.math.clamp(x * SCALE, 0, PX_W);
    clip_y0 = std.math.clamp(y * SCALE, 0, PX_H);
    clip_x1 = std.math.clamp((x + @max(0, w)) * SCALE, 0, PX_W);
    clip_y1 = std.math.clamp((y + @max(0, h)) * SCALE, 0, PX_H);
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const xa = @max(clip_x0, x * SCALE);
    const ya = @max(clip_y0, y * SCALE);
    const xb = @min(clip_x1, (x + w) * SCALE);
    const yb = @min(clip_y1, (y + h) * SCALE);
    var py = ya;
    while (py < yb) : (py += 1) {
        var px = xa;
        while (px < xb) : (px += 1) output_buf[pixelIndex(px, py)..][0..4].* = c;
    }
}

fn pixelIndex(x: i32, y: i32) usize {
    return ktx.HEADER_SIZE + (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
}

fn blendPixel(x: i32, y: i32, c: Color, a: f32) void {
    if (x < clip_x0 or y < clip_y0 or x >= clip_x1 or y >= clip_y1) return;
    const idx = pixelIndex(x, y);
    const t = @min(1.0, a);
    for (0..3) |k| {
        const old: f32 = @floatFromInt(output_buf[idx + k]);
        const target: f32 = @floatFromInt(c[k]);
        output_buf[idx + k] = @intFromFloat(@round(old + (target - old) * t));
    }
    output_buf[idx + 3] = 0xFF;
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
    i.* += len;
    return cp;
}

fn glyphCount(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) _ = nextCodepoint(s, &i);
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
    try std.testing.expectEqualStrings("999", buf[0..fmtCountInto(&buf, 999)]);
    try std.testing.expectEqualStrings("1,000", buf[0..fmtCountInto(&buf, 1000)]);
    try std.testing.expectEqualStrings("1,048,576", buf[0..fmtCountInto(&buf, 1048576)]);
}

test "UTF-8 decoding counts glyphs and replaces malformed bytes" {
    try std.testing.expectEqual(@as(usize, 5), glyphCount("caf\xc3\xa9!"));
    var i: usize = 0;
    try std.testing.expectEqual(@as(u32, 0xFFFD), nextCodepoint("\xff", &i));
    try std.testing.expectEqual(@as(usize, 1), i);
    i = 0;
    try std.testing.expectEqual(@as(u32, 0x2026), nextCodepoint("\xe2\x80\xa6", &i));
}

test "text cells stay on one line" {
    var buf: [32]u8 = undefined;
    const v = formatValue(13 + 2 * 5, "a\nb\tc", &buf);
    try std.testing.expectEqual(ValueKind.text, v.kind);
    try std.testing.expectEqualStrings("a\xc2\xb6b c", v.text);
    try std.testing.expectEqual(@as(usize, 5), v.bytes);
}

test "blobs show hex" {
    var buf: [32]u8 = undefined;
    const v = formatValue(12 + 2 * 3, "\x00\xab\xff", &buf);
    try std.testing.expectEqual(ValueKind.blob, v.kind);
    try std.testing.expectEqualStrings("x'00ABFF'", v.text);
}

test "reals keep a decimal point" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("26.0", fmtReal(&buf, 26));
    try std.testing.expectEqualStrings("7.25", fmtReal(&buf, 7.25));
}

test "column affinity follows SQLite's order" {
    try std.testing.expect(hasRealAffinity("FLOAT"));
    try std.testing.expect(hasRealAffinity("double precision"));
    try std.testing.expect(!hasRealAffinity("FLOATING POINT"));
    try std.testing.expect(!hasRealAffinity("INTEGER"));
    try std.testing.expect(!hasRealAffinity(""));
}
