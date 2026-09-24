const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 375;
const RENDER_H: usize = 667;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_META: i32 = 1 << 5;
const BTN_PRIMARY: i32 = 1 << 0;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;
const XK_TAB: i32 = 0xFF09;
const XK_ESCAPE: i32 = 0xFF1B;
const DOUBLE_CLICK_MS: i64 = 360;
const BLINK_INTERVAL_MS: i64 = 500;

const SHEET_ROWS: usize = 64;
const SHEET_COLS: usize = 16;
const CELL_CAP: usize = 24;
const CLIP_CAP: usize = CELL_CAP;

const TEXT_SCALE: i32 = 2;
const TITLE_H: i32 = 26;
const TOOL_H: i32 = 34;
const STATUS_H: i32 = 22;
const GRID_X: i32 = 39;
const GRID_Y: i32 = TITLE_H + TOOL_H + 6;
const CELL_W: i32 = 72;
const CELL_H: i32 = 24;
const ROW_HEADER_W: i32 = GRID_X;
const COL_HEADER_H: i32 = 22;
const VISIBLE_COLS: i32 = @divTrunc(@as(i32, @intCast(RENDER_W)) - GRID_X - 2, CELL_W);
const VISIBLE_ROWS: i32 = @divTrunc(@as(i32, @intCast(RENDER_H)) - GRID_Y - COL_HEADER_H - STATUS_H - 2, CELL_H);

const Color = [4]u8;
const C_DESKTOP: Color = .{ 0xB6, 0xC6, 0xD8, 0xFF };
const C_WIN: Color = .{ 0xF7, 0xF7, 0xF3, 0xFF };
const C_PANEL: Color = .{ 0xE7, 0xEA, 0xE2, 0xFF };
const C_GRID: Color = .{ 0xB9, 0xBE, 0xB6, 0xFF };
const C_HEADER: Color = .{ 0xDA, 0xDF, 0xD5, 0xFF };
const C_ACTIVE: Color = .{ 0x1F, 0x62, 0xD4, 0xFF };
const C_EDIT: Color = .{ 0xFF, 0xF8, 0xCC, 0xFF };
const C_TEXT: Color = .{ 0x12, 0x16, 0x18, 0xFF };
const C_DIM: Color = .{ 0x60, 0x66, 0x60, 0xFF };
const C_WHITE: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_FORMULA: Color = .{ 0xFC, 0xFC, 0xFF, 0xFF };

const Cell = struct {
    bytes: [CELL_CAP]u8 = [_]u8{0} ** CELL_CAP,
    len: usize = 0,
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var cells: [SHEET_ROWS][SHEET_COLS]Cell = undefined;
var clipboard: [CLIP_CAP]u8 = [_]u8{0} ** CLIP_CAP;
var clipboard_len: usize = 0;

var active_row: i32 = 0;
var active_col: i32 = 0;
var scroll_row: i32 = 0;
var scroll_col: i32 = 0;
var editing: bool = false;
var edit_buf: [CELL_CAP]u8 = [_]u8{0} ** CELL_CAP;
var edit_len: usize = 0;
var primary_down: bool = false;
var last_primary_click_ms: i64 = -1000000;
var last_primary_click_row: i32 = -1;
var last_primary_click_col: i32 = -1;
var blink_on: bool = true;
var next_blink_at_ms: i64 = 0;
var needs_redraw: bool = true;
var initialized: bool = false;
const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    const shortcut = (flags & (FLAG_CTRL | FLAG_META)) != 0;
    if (shortcut and handleShortcut(x11_key, begun_at_ms)) return 1;

    if (editing) {
        if (handleEditingKey(x11_key, begun_at_ms)) return 1;
    } else {
        if (handleNavigationKey(x11_key, begun_at_ms)) return 1;
    }

    if (isPrintable(x11_key) and !shortcut) {
        if (!editing) beginEdit(false);
        appendEdit(@as(u8, @intCast(x11_key)));
        touch(begun_at_ms);
        return 1;
    }
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const primary = (button_mask & BTN_PRIMARY) != 0;
    if (!primary) {
        primary_down = false;
        return 0;
    }
    if (primary_down) return 0;
    primary_down = true;

    const cell = cellAtPoint(x_px, y_px) orelse return 0;
    const is_double_click = cell.row == last_primary_click_row and
        cell.col == last_primary_click_col and
        begun_at_ms - last_primary_click_ms >= 0 and
        begun_at_ms - last_primary_click_ms <= DOUBLE_CLICK_MS;

    commitEdit();
    active_row = cell.row;
    active_col = cell.col;
    if (is_double_click) beginEdit(true);

    last_primary_click_ms = begun_at_ms;
    last_primary_click_row = cell.row;
    last_primary_click_col = cell.col;

    ensureActiveVisible();
    touch(begun_at_ms);
    return 1;
}

fn requireEventPhase() void {
    if (phase != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (!editing) {
        next_blink_at_ms = 0;
        return;
    }
    if (next_blink_at_ms > 0 and begun_at_ms >= next_blink_at_ms) {
        blink_on = !blink_on;
        next_blink_at_ms = begun_at_ms +| BLINK_INTERVAL_MS;
        needs_redraw = true;
    }
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return if (editing and next_blink_at_ms > begun_at_ms) next_blink_at_ms else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    ensureInit();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
    phase = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf[0])),
        .failed = 0,
    };
}

fn ensureInit() void {
    if (initialized) return;
    initialized = true;
    var r: usize = 0;
    while (r < SHEET_ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < SHEET_COLS) : (c += 1) cells[r][c] = Cell{};
    }
    setCell(0, 0, "Item");
    setCell(0, 1, "Qty");
    setCell(0, 2, "Price");
    setCell(0, 3, "Total");
    setCell(1, 0, "Tea");
    setCell(1, 1, "3");
    setCell(1, 2, "7");
    setCell(1, 3, "=B2*C2");
    setCell(2, 0, "Paper");
    setCell(2, 1, "8");
    setCell(2, 2, "2");
    setCell(2, 3, "=B3*C3");
    setCell(4, 2, "Sum");
    setCell(4, 3, "=D2+D3");
}

fn handleShortcut(key: i32, now_ms: i64) bool {
    switch (key) {
        'c', 'C' => {
            const src = currentText();
            clipboard_len = @min(src.len, CLIP_CAP);
            var i: usize = 0;
            while (i < clipboard_len) : (i += 1) clipboard[i] = src[i];
            touch(now_ms);
            return true;
        },
        'x', 'X' => {
            _ = handleShortcut('c', now_ms);
            clearActive();
            touch(now_ms);
            return true;
        },
        'v', 'V' => {
            commitEdit();
            writeActive(clipboard[0..clipboard_len]);
            touch(now_ms);
            return true;
        },
        else => return false,
    }
}

fn handleEditingKey(key: i32, now_ms: i64) bool {
    switch (key) {
        XK_RETURN => {
            commitEdit();
            moveBy(1, 0);
            touch(now_ms);
            return true;
        },
        XK_TAB => {
            commitEdit();
            moveBy(0, 1);
            touch(now_ms);
            return true;
        },
        XK_ESCAPE => {
            editing = false;
            next_blink_at_ms = 0;
            touch(now_ms);
            return true;
        },
        XK_BACKSPACE => {
            if (edit_len > 0) edit_len -= 1;
            touch(now_ms);
            return true;
        },
        XK_DELETE => {
            edit_len = 0;
            touch(now_ms);
            return true;
        },
        else => return false,
    }
}

fn handleNavigationKey(key: i32, now_ms: i64) bool {
    switch (key) {
        XK_LEFT => moveBy(0, -1),
        XK_RIGHT, XK_TAB => moveBy(0, 1),
        XK_UP => moveBy(-1, 0),
        XK_DOWN, XK_RETURN => moveBy(1, 0),
        XK_HOME => active_col = 0,
        XK_END => active_col = @as(i32, @intCast(SHEET_COLS - 1)),
        XK_BACKSPACE, XK_DELETE => clearActive(),
        else => return false,
    }
    ensureActiveVisible();
    touch(now_ms);
    return true;
}

fn beginEdit(keep_existing: bool) void {
    editing = true;
    edit_len = 0;
    if (keep_existing) {
        const src = activeCell();
        edit_len = src.len;
        var i: usize = 0;
        while (i < edit_len) : (i += 1) edit_buf[i] = src.bytes[i];
    }
}

fn appendEdit(ch: u8) void {
    if (edit_len >= CELL_CAP) return;
    edit_buf[edit_len] = ch;
    edit_len += 1;
}

fn commitEdit() void {
    if (!editing) return;
    writeActive(edit_buf[0..edit_len]);
    editing = false;
    next_blink_at_ms = 0;
}

fn writeActive(text: []const u8) void {
    const r: usize = @intCast(active_row);
    const c: usize = @intCast(active_col);
    const n = @min(text.len, CELL_CAP);
    cells[r][c].len = n;
    var i: usize = 0;
    while (i < n) : (i += 1) cells[r][c].bytes[i] = text[i];
}

fn clearActive() void {
    const r: usize = @intCast(active_row);
    const c: usize = @intCast(active_col);
    cells[r][c].len = 0;
}

fn setCell(row: usize, col: usize, text: []const u8) void {
    const n = @min(text.len, CELL_CAP);
    cells[row][col].len = n;
    var i: usize = 0;
    while (i < n) : (i += 1) cells[row][col].bytes[i] = text[i];
}

fn activeCell() *Cell {
    return &cells[@as(usize, @intCast(active_row))][@as(usize, @intCast(active_col))];
}

fn currentText() []const u8 {
    if (editing) return edit_buf[0..edit_len];
    const cell = activeCell();
    return cell.bytes[0..cell.len];
}

fn moveBy(dr: i32, dc: i32) void {
    active_row = clampI32(active_row + dr, 0, @as(i32, @intCast(SHEET_ROWS - 1)));
    active_col = clampI32(active_col + dc, 0, @as(i32, @intCast(SHEET_COLS - 1)));
    ensureActiveVisible();
}

fn ensureActiveVisible() void {
    if (active_row < scroll_row) scroll_row = active_row;
    if (active_row >= scroll_row + VISIBLE_ROWS) scroll_row = active_row - VISIBLE_ROWS + 1;
    if (active_col < scroll_col) scroll_col = active_col;
    if (active_col >= scroll_col + VISIBLE_COLS) scroll_col = active_col - VISIBLE_COLS + 1;
    scroll_row = clampI32(scroll_row, 0, @as(i32, @intCast(SHEET_ROWS)) - VISIBLE_ROWS);
    scroll_col = clampI32(scroll_col, 0, @as(i32, @intCast(SHEET_COLS)) - VISIBLE_COLS);
}

fn touch(now_ms: i64) void {
    blink_on = true;
    next_blink_at_ms = if (editing) now_ms +| BLINK_INTERVAL_MS else 0;
    needs_redraw = true;
}

const PointCell = struct { row: i32, col: i32 };

fn cellAtPoint(x: i32, y: i32) ?PointCell {
    const body_y = GRID_Y + COL_HEADER_H;
    if (x < GRID_X or y < body_y) return null;
    const view_col = @divTrunc(x - GRID_X, CELL_W);
    const view_row = @divTrunc(y - body_y, CELL_H);
    if (view_col < 0 or view_col >= VISIBLE_COLS) return null;
    if (view_row < 0 or view_row >= VISIBLE_ROWS) return null;
    const row = scroll_row + view_row;
    const col = scroll_col + view_col;
    if (row >= @as(i32, @intCast(SHEET_ROWS)) or col >= @as(i32, @intCast(SHEET_COLS))) return null;
    return .{ .row = row, .col = col };
}

fn drawFrame() void {
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), C_DESKTOP);
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), C_WIN);
    drawTitle();
    drawFormulaBar();
    drawGrid();
    drawStatus();
}

fn drawTitle() void {
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), TITLE_H, C_PANEL);
    drawRect(0, TITLE_H - 1, @as(i32, @intCast(RENDER_W)), 1, C_GRID);
    drawTextScaled(8, 7, "Spreadsheet", C_TEXT, TEXT_SCALE);
}

fn drawFormulaBar() void {
    fillRectI32(0, TITLE_H, @as(i32, @intCast(RENDER_W)), TOOL_H, C_PANEL);
    drawTextScaled(8, TITLE_H + 10, cellNameBuf(active_row, active_col), C_DIM, TEXT_SCALE);
    fillRectI32(58, TITLE_H + 6, @as(i32, @intCast(RENDER_W)) - 66, 22, C_FORMULA);
    drawRect(58, TITLE_H + 6, @as(i32, @intCast(RENDER_W)) - 66, 22, C_GRID);
    drawTextClipped(64, TITLE_H + 12, @as(i32, @intCast(RENDER_W)) - 76, currentText(), C_TEXT, TEXT_SCALE);
}

fn drawGrid() void {
    const body_y = GRID_Y + COL_HEADER_H;
    fillRectI32(0, GRID_Y, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)) - GRID_Y - STATUS_H, C_WHITE);
    fillRectI32(0, GRID_Y, @as(i32, @intCast(RENDER_W)), COL_HEADER_H, C_HEADER);
    fillRectI32(0, body_y, ROW_HEADER_W, @as(i32, @intCast(RENDER_H)) - body_y - STATUS_H, C_HEADER);

    var vc: i32 = 0;
    while (vc < VISIBLE_COLS) : (vc += 1) {
        const col = scroll_col + vc;
        const x = GRID_X + vc * CELL_W;
        fillRectI32(x, GRID_Y, CELL_W, COL_HEADER_H, C_HEADER);
        drawRect(x, GRID_Y, CELL_W, COL_HEADER_H, C_GRID);
        drawTextScaled(x + 8, GRID_Y + 6, colLabelBuf(col), C_DIM, TEXT_SCALE);
    }

    var vr: i32 = 0;
    while (vr < VISIBLE_ROWS) : (vr += 1) {
        const row = scroll_row + vr;
        const y = body_y + vr * CELL_H;
        drawRect(0, y, ROW_HEADER_W, CELL_H, C_GRID);
        drawNumber(6, y + 7, row + 1, C_DIM, TEXT_SCALE);
        vc = 0;
        while (vc < VISIBLE_COLS) : (vc += 1) {
            const col = scroll_col + vc;
            const x = GRID_X + vc * CELL_W;
            const is_active = row == active_row and col == active_col;
            fillRectI32(x, y, CELL_W, CELL_H, if (is_active and editing) C_EDIT else C_WHITE);
            drawRect(x, y, CELL_W, CELL_H, C_GRID);
            if (is_active) drawRect(x + 1, y + 1, CELL_W - 2, CELL_H - 2, C_ACTIVE);
            drawCellText(x + 4, y + 7, CELL_W - 8, @as(usize, @intCast(row)), @as(usize, @intCast(col)), is_active and editing);
            if (is_active and editing and blink_on) {
                const caret_x = x + 4 + @as(i32, @intCast(@min(edit_len, 8))) * 8;
                fillRectI32(caret_x, y + 5, 1, CELL_H - 10, C_ACTIVE);
            }
        }
    }
}

fn drawCellText(x: i32, y: i32, max_w: i32, row: usize, col: usize, is_editing: bool) void {
    if (is_editing) {
        drawTextClipped(x, y, max_w, edit_buf[0..edit_len], C_TEXT, TEXT_SCALE);
        return;
    }
    var value_buf: [CELL_CAP]u8 = undefined;
    const text = displayText(row, col, &value_buf);
    drawTextClipped(x, y, max_w, text, C_TEXT, TEXT_SCALE);
}

fn displayText(row: usize, col: usize, out: *[CELL_CAP]u8) []const u8 {
    const cell = &cells[row][col];
    if (cell.len > 0 and cell.bytes[0] == '=') {
        if (evalFormula(cell.bytes[1..cell.len])) |v| {
            const n = formatIntTo(v, out);
            return out[0..n];
        }
    }
    return cell.bytes[0..cell.len];
}

fn evalFormula(expr: []const u8) ?i32 {
    var pos: usize = 0;
    var acc = parseTerm(expr, &pos) orelse return null;
    while (pos < expr.len) {
        const op = expr[pos];
        if (op != '+' and op != '-' and op != '*') return null;
        pos += 1;
        const rhs = parseTerm(expr, &pos) orelse return null;
        switch (op) {
            '+' => acc += rhs,
            '-' => acc -= rhs,
            '*' => acc *= rhs,
            else => {},
        }
    }
    return acc;
}

fn parseTerm(expr: []const u8, pos: *usize) ?i32 {
    while (pos.* < expr.len and expr[pos.*] == ' ') pos.* += 1;
    if (pos.* >= expr.len) return null;
    const ch = expr[pos.*];
    if (ch >= 'A' and ch <= 'Z') return parseRef(expr, pos, ch - 'A');
    if (ch >= 'a' and ch <= 'z') return parseRef(expr, pos, ch - 'a');
    return parseInt(expr, pos);
}

fn parseRef(expr: []const u8, pos: *usize, col_u8: u8) ?i32 {
    pos.* += 1;
    var row_num: i32 = 0;
    var any = false;
    while (pos.* < expr.len and expr[pos.*] >= '0' and expr[pos.*] <= '9') {
        any = true;
        row_num = row_num * 10 + @as(i32, expr[pos.*] - '0');
        pos.* += 1;
    }
    if (!any or row_num <= 0) return null;
    const row = row_num - 1;
    const col: i32 = @intCast(col_u8);
    if (row < 0 or row >= @as(i32, @intCast(SHEET_ROWS))) return null;
    if (col < 0 or col >= @as(i32, @intCast(SHEET_COLS))) return null;
    const cell = &cells[@as(usize, @intCast(row))][@as(usize, @intCast(col))];
    if (cell.len == 0) return 0;
    if (cell.bytes[0] == '=') return evalFormula(cell.bytes[1..cell.len]);
    var p: usize = 0;
    return parseInt(cell.bytes[0..cell.len], &p);
}

fn parseInt(expr: []const u8, pos: *usize) ?i32 {
    var sign: i32 = 1;
    if (pos.* < expr.len and expr[pos.*] == '-') {
        sign = -1;
        pos.* += 1;
    }
    var v: i32 = 0;
    var any = false;
    while (pos.* < expr.len and expr[pos.*] >= '0' and expr[pos.*] <= '9') {
        any = true;
        v = v * 10 + @as(i32, expr[pos.*] - '0');
        pos.* += 1;
    }
    return if (any) v * sign else null;
}

fn drawStatus() void {
    const y = @as(i32, @intCast(RENDER_H)) - STATUS_H;
    fillRectI32(0, y, @as(i32, @intCast(RENDER_W)), STATUS_H, C_PANEL);
    drawRect(0, y, @as(i32, @intCast(RENDER_W)), 1, C_GRID);
    drawTextClipped(6, y + 7, @as(i32, @intCast(RENDER_W)) - 12, if (editing) "Editing: Enter commits, Esc cancels" else "Arrows move, type edits, Cmd/Ctrl+C/V copies", C_DIM, TEXT_SCALE);
}

var name_buf: [8]u8 = undefined;
var col_buf: [3]u8 = undefined;

fn cellNameBuf(row: i32, col: i32) []const u8 {
    const c = colLabelBuf(col);
    var n: usize = 0;
    var i: usize = 0;
    while (i < c.len and n < name_buf.len) : (i += 1) {
        name_buf[n] = c[i];
        n += 1;
    }
    n += formatIntInto(row + 1, name_buf[n..]);
    return name_buf[0..n];
}

fn colLabelBuf(col: i32) []const u8 {
    if (col < 26) {
        col_buf[0] = @as(u8, @intCast('A' + col));
        return col_buf[0..1];
    }
    col_buf[0] = @as(u8, @intCast('A' + @divTrunc(col, 26) - 1));
    col_buf[1] = @as(u8, @intCast('A' + @mod(col, 26)));
    return col_buf[0..2];
}

fn drawNumber(x: i32, y: i32, n: i32, color: Color, scale: i32) void {
    var buf: [16]u8 = undefined;
    const len = formatIntInto(n, &buf);
    drawTextScaled(x, y, buf[0..len], color, scale);
}

fn formatIntTo(n: i32, out: *[CELL_CAP]u8) usize {
    return formatIntInto(n, out);
}

fn formatIntInto(n: i32, out: []u8) usize {
    if (out.len == 0) return 0;
    if (n == 0) {
        out[0] = '0';
        return 1;
    }
    var value = if (n < 0) -n else n;
    var tmp: [16]u8 = undefined;
    var tlen: usize = 0;
    while (value > 0 and tlen < tmp.len) : (tlen += 1) {
        tmp[tlen] = @as(u8, @intCast('0' + @mod(value, 10)));
        value = @divTrunc(value, 10);
    }
    var i: usize = 0;
    if (n < 0 and i < out.len) {
        out[i] = '-';
        i += 1;
    }
    var j: usize = 0;
    while (j < tlen and i < out.len) : (j += 1) {
        out[i] = tmp[tlen - 1 - j];
        i += 1;
    }
    return i;
}

fn drawTextClipped(x: i32, y: i32, max_w: i32, text: []const u8, c: Color, scale: i32) void {
    const advance = 4 * scale;
    const max_chars: usize = @intCast(@max(0, @divTrunc(max_w, advance)));
    const n = @min(text.len, max_chars);
    drawTextScaled(x, y, text[0..n], c, scale);
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
    }
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            fillRectI32(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, c);
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G', 'g' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q', 'q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z', 'z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => .{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '=' => .{ 0b000, 0b111, 0b000, 0b111, 0b000 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        '.', ',' => .{ 0b000, 0b000, 0b000, 0b000, 0b010 },
        '/', '|' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillRectI32(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(@as(i32, @intCast(RENDER_W)), x + w);
    const y1 = @min(@as(i32, @intCast(RENDER_H)), y + h);
    if (x0 >= x1 or y0 >= y1) return;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const idx: usize = ktx.HEADER_SIZE + @as(usize, @intCast((yy * @as(i32, @intCast(RENDER_W)) + xx) * 4));
            output_buf[idx + 0] = c[0];
            output_buf[idx + 1] = c[1];
            output_buf[idx + 2] = c[2];
            output_buf[idx + 3] = c[3];
        }
    }
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn isPrintable(k: i32) bool {
    return k >= 32 and k <= 126;
}
