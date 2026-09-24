const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 375;
const RENDER_H: usize = 667;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;

const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_SHIFT_L: i32 = 0xFFE1;
const XK_SHIFT_R: i32 = 0xFFE2;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;
const XK_PAGE_UP: i32 = 0xFF55;
const XK_PAGE_DOWN: i32 = 0xFF56;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;
const XK_TAB: i32 = 0xFF09;
const DOUBLE_CLICK_MS: i64 = 360;
const BLINK_INTERVAL_MS: i64 = 500;

const DOC_CAP: usize = 8192;
const CLIP_CAP: usize = 2048;

const WINDOW_X: i32 = 0;
const WINDOW_Y: i32 = 0;
const WINDOW_W: i32 = RENDER_W;
const WINDOW_H: i32 = RENDER_H;
const TITLE_H: i32 = 18;
const MENU_H: i32 = 14;

const TEXT_X: i32 = WINDOW_X + 8;
const TEXT_Y: i32 = WINDOW_Y + TITLE_H + MENU_H + 6;
const TEXT_W: i32 = WINDOW_W - 16;
const TEXT_H: i32 = WINDOW_H - TITLE_H - MENU_H - 14;
const CHAR_W: i32 = 8;
const LINE_H: i32 = 16;
const VIEW_COLS: i32 = @divTrunc(TEXT_W, CHAR_W);
const VIEW_ROWS: i32 = @divTrunc(TEXT_H, LINE_H);

const Color = [4]u8;
const C_DESKTOP: Color = .{ 0x9F, 0xB6, 0xD2, 0xFF };
const C_WIN: Color = .{ 0xF4, 0xF4, 0xF4, 0xFF };
const C_WIN_DARK: Color = .{ 0x68, 0x68, 0x68, 0xFF };
const C_TITLE_TOP: Color = .{ 0xD8, 0xD8, 0xD8, 0xFF };
const C_TITLE_BOTTOM: Color = .{ 0xB0, 0xB0, 0xB0, 0xFF };
const C_TEXT_BG: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_TEXT: Color = .{ 0x11, 0x11, 0x11, 0xFF };
const C_DIM: Color = .{ 0x55, 0x55, 0x55, 0xFF };
const C_SEL: Color = .{ 0x1F, 0x62, 0xD4, 0xFF };
const C_SEL_TEXT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_CARET: Color = .{ 0x10, 0x10, 0x10, 0xFF };

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
const Range = struct { start: usize, end: usize };

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;

var doc: [DOC_CAP]u8 = undefined;
var doc_len: usize = 0;

var undo_doc: [DOC_CAP]u8 = undefined;
var undo_len: usize = 0;
var undo_caret: usize = 0;
var undo_anchor: usize = 0;
var has_undo: bool = false;

var clipboard: [CLIP_CAP]u8 = undefined;
var clipboard_len: usize = 0;
var scratch: [DOC_CAP]u8 = undefined;

var caret: usize = 0;
var anchor: usize = 0;

var scroll_line: i32 = 0;
var scroll_col: i32 = 0;
var preferred_col: i32 = -1;

var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;
var mouse_selecting: bool = false;
var last_primary_click_ms: i64 = -1000000;
var last_primary_click_idx: usize = 0;
var shift_down: bool = false;

var blink_on: bool = true;
var next_blink_at_ms: i64 = BLINK_INTERVAL_MS;
var needs_redraw: bool = true;
var initialized: bool = false;

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const LifecycleState = enum { initializing, ready, updating };
var lifecycle_state: LifecycleState = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced = false;

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle_state != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    lifecycle_state = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    const key_down = (flags & FLAG_KEY_DOWN) != 0;
    const shift_flag = (flags & FLAG_SHIFT) != 0;

    if (x11_key == XK_SHIFT_L or x11_key == XK_SHIFT_R) {
        shift_down = key_down;
        return 1;
    }
    shift_down = shift_flag;

    if (!key_down) return 0;

    const extend = (flags & FLAG_SHIFT) != 0;
    const control = (flags & FLAG_CTRL) != 0;
    const shortcut_mod = (flags & (FLAG_CTRL | FLAG_META)) != 0;
    const command = (flags & FLAG_META) != 0;
    const alt = (flags & FLAG_ALT) != 0;

    if (shortcut_mod and handleShortcut(x11_key, control, command)) {
        touchAfterEdit(begun_at_ms);
        return 1;
    }

    if (alt and !command and handleLineSwapKey(x11_key)) {
        touchAfterEdit(begun_at_ms);
        return 1;
    }

    if (handleNavKey(x11_key, extend, alt, command)) {
        touchAfterNav(begun_at_ms);
        return 1;
    }

    if (handleEditKey(x11_key, alt, command)) {
        touchAfterEdit(begun_at_ms);
        return 1;
    }

    if (isPrintable(x11_key) and !shortcut_mod and !alt) {
        const ch: u8 = @as(u8, @intCast(x11_key));
        if (insertSlice(&[_]u8{ch})) touchAfterEdit(begun_at_ms);
        return 1;
    }

    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    return pointerEventAt(button_mask, x_px, y_px, begun_at_ms);
}

fn pointerEventAt(button_mask: i32, x_px: i32, y_px: i32, now_ms: i64) i32 {
    pointer_x = x_px;
    pointer_y = y_px;
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;

    if (secondary and !secondary_down) {
        // Simple context behavior: select word-ish token by line click.
        const idx = textIndexAtPoint(x_px, y_px);
        caret = idx;
        anchor = idx;
        preferred_col = -1;
        mouse_selecting = false;
        touchAfterNav(now_ms);
    }

    if (primary and !primary_down) {
        const idx = textIndexAtPoint(x_px, y_px);
        const in_text = pointInRect(x_px, y_px, .{ .x = TEXT_X, .y = TEXT_Y, .w = TEXT_W, .h = TEXT_H });
        const extend_selection = shift_down and in_text;
        const near_last = absI32(@as(i32, @intCast(idx)) - @as(i32, @intCast(last_primary_click_idx))) <= 1;
        const is_double = !extend_selection and in_text and (now_ms - last_primary_click_ms) >= 0 and (now_ms - last_primary_click_ms) <= DOUBLE_CLICK_MS and near_last;
        const checkbox_mark = if (!extend_selection and in_text) markdownCheckboxMarkAt(doc[0..doc_len], idx) else null;
        if (checkbox_mark) |mark_idx| {
            pushUndo();
            doc[mark_idx] = if (doc[mark_idx] == ' ') 'x' else ' ';
            mouse_selecting = false;
            last_primary_click_ms = -1000000;
            blink_on = true;
            next_blink_at_ms = now_ms +| BLINK_INTERVAL_MS;
            needs_redraw = true;
        } else if (extend_selection) {
            caret = idx;
            preferred_col = -1;
            mouse_selecting = true;
        } else if (is_double) {
            selectWordAt(idx);
            mouse_selecting = false;
        } else {
            caret = idx;
            anchor = idx;
            preferred_col = -1;
            mouse_selecting = in_text;
        }
        if (in_text) {
            last_primary_click_ms = now_ms;
            last_primary_click_idx = idx;
        }
        touchAfterNav(now_ms);
    } else if (primary and primary_down and mouse_selecting) {
        const idx = textIndexAtPoint(x_px, y_px);
        caret = idx;
        ensureCaretVisible();
        touchAfterNav(now_ms);
    } else if (!primary and primary_down) {
        mouse_selecting = false;
        touchAfterNav(now_ms);
    }

    primary_down = primary;
    secondary_down = secondary;
    return if (needs_redraw) 1 else 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (next_blink_at_ms > 0 and begun_at_ms >= next_blink_at_ms) {
        blink_on = !blink_on;
        next_blink_at_ms = begun_at_ms +| BLINK_INTERVAL_MS;
        needs_redraw = true;
    }
}

export fn finish_update() i64 {
    requireUpdate();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    return if (next_blink_at_ms > begun_at_ms) next_blink_at_ms else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or (lifecycle_state != .initializing and lifecycle_state != .ready)) @trap();
    ensureInit();
    drawFrame();
    needs_redraw = false;
    _ = ktx.writeHeader(&ktx_buf, RENDER_W, RENDER_H) orelse @trap();
    @memcpy(ktx_buf[ktx.HEADER_SIZE..], output_buf[0..]);
    lifecycle_state = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&ktx_buf[0])),
        .failed = 0,
    };
}

fn ensureInit() void {
    if (initialized) return;
    initialized = true;
    resetState();
}

fn resetState() void {
    doc_len = 0;
    clipboard_len = 0;
    has_undo = false;
    caret = 0;
    anchor = 0;
    scroll_line = 0;
    scroll_col = 0;
    preferred_col = -1;
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    mouse_selecting = false;
    last_primary_click_ms = -1000000;
    last_primary_click_idx = 0;
    shift_down = false;
    blink_on = true;
    next_blink_at_ms = BLINK_INTERVAL_MS;

    _ = insertSliceRaw("Untitled.txt\n\nThis is a plain text document.\nUse keyboard and mouse selection.\n\nShortcuts:\n- Ctrl/Cmd+A Select All\n- Ctrl/Cmd+C Copy\n- Ctrl/Cmd+X Cut\n- Ctrl/Cmd+V Paste\n- Ctrl/Cmd+Z Undo\n");
    caret = doc_len;
    anchor = caret;
    ensureCaretVisible();
    needs_redraw = true;
}

fn touchAfterEdit(now_ms: i64) void {
    preferred_col = -1;
    ensureCaretVisible();
    blink_on = true;
    next_blink_at_ms = now_ms +| BLINK_INTERVAL_MS;
    needs_redraw = true;
}

fn touchAfterNav(now_ms: i64) void {
    ensureCaretVisible();
    blink_on = true;
    next_blink_at_ms = now_ms +| BLINK_INTERVAL_MS;
    needs_redraw = true;
}

fn handleShortcut(key: i32, control: bool, command: bool) bool {
    switch (key) {
        'a', 'A' => {
            anchor = 0;
            caret = doc_len;
            return true;
        },
        'c', 'C' => {
            copySelectionToClipboard();
            return true;
        },
        'x', 'X' => {
            if (!hasSelection()) return true;
            pushUndo();
            copySelectionToClipboard();
            _ = deleteSelection();
            return true;
        },
        'v', 'V' => {
            if (clipboard_len == 0) return true;
            pushUndo();
            _ = replaceSelectionWith(clipboard[0..clipboard_len]);
            return true;
        },
        'z', 'Z' => {
            undo();
            return true;
        },
        't', 'T' => {
            if (!control or command) return false;
            pushUndo();
            return transposeChars();
        },
        else => return false,
    }
}

fn handleLineSwapKey(key: i32) bool {
    switch (key) {
        XK_UP => {
            pushUndo();
            _ = swapLineUp();
            return true;
        },
        XK_DOWN => {
            pushUndo();
            _ = swapLineDown();
            return true;
        },
        else => return false,
    }
}

fn handleNavKey(key: i32, extend: bool, alt: bool, command: bool) bool {
    switch (key) {
        XK_LEFT => {
            if (command) moveHome(extend) else if (alt) moveWordLeft(extend) else moveLeft(extend);
            preferred_col = -1;
            return true;
        },
        XK_RIGHT => {
            if (command) moveEnd(extend) else if (alt) moveWordRight(extend) else moveRight(extend);
            preferred_col = -1;
            return true;
        },
        XK_UP => {
            if (command) moveDocStart(extend) else moveVertical(-1, extend);
            return true;
        },
        XK_DOWN => {
            if (command) moveDocEnd(extend) else moveVertical(1, extend);
            return true;
        },
        XK_HOME => {
            moveHome(extend);
            preferred_col = -1;
            return true;
        },
        XK_END => {
            moveEnd(extend);
            preferred_col = -1;
            return true;
        },
        XK_PAGE_UP => {
            moveVertical(-VIEW_ROWS, extend);
            return true;
        },
        XK_PAGE_DOWN => {
            moveVertical(VIEW_ROWS, extend);
            return true;
        },
        else => return false,
    }
}

fn handleEditKey(key: i32, alt: bool, command: bool) bool {
    switch (key) {
        XK_BACKSPACE => {
            pushUndo();
            if (command) return deleteToLineStart();
            if (alt) return deleteWordBackward();
            return backspace();
        },
        XK_DELETE => {
            pushUndo();
            if (command) return deleteToLineEnd();
            if (alt) return deleteWordForward();
            return deleteForward();
        },
        XK_RETURN => {
            pushUndo();
            return insertSlice(&[_]u8{'\n'});
        },
        XK_TAB => {
            pushUndo();
            return insertSlice("    ");
        },
        else => return false,
    }
}

fn isPrintable(k: i32) bool {
    return k >= 32 and k <= 126;
}

fn moveLeft(extend: bool) void {
    if (!extend and hasSelection()) {
        caret = selectionRange().start;
        anchor = caret;
        return;
    }
    if (caret > 0) caret -= 1;
    if (!extend) anchor = caret;
}

fn moveRight(extend: bool) void {
    if (!extend and hasSelection()) {
        caret = selectionRange().end;
        anchor = caret;
        return;
    }
    if (caret < doc_len) caret += 1;
    if (!extend) anchor = caret;
}

fn moveHome(extend: bool) void {
    caret = lineStartAt(caret);
    if (!extend) anchor = caret;
}

fn moveEnd(extend: bool) void {
    caret = lineEndAt(caret);
    if (!extend) anchor = caret;
}

fn moveVertical(delta_lines: i32, extend: bool) void {
    const line = lineNumberAt(caret);
    const col = colAt(caret);
    if (preferred_col < 0) preferred_col = col;
    const target_line = @max(0, line + delta_lines);
    caret = indexAtLineCol(target_line, preferred_col);
    if (!extend) anchor = caret;
}

fn moveDocStart(extend: bool) void {
    caret = 0;
    if (!extend) anchor = caret;
}

fn moveDocEnd(extend: bool) void {
    caret = doc_len;
    if (!extend) anchor = caret;
}

fn moveWordLeft(extend: bool) void {
    if (!extend and hasSelection()) {
        caret = selectionRange().start;
        anchor = caret;
        return;
    }
    var i = caret;
    if (i == 0) {
        if (!extend) anchor = caret;
        return;
    }
    i -= 1;
    while (i > 0 and isSkippableWordBoundary(doc[i])) : (i -= 1) {}
    while (i > 0 and !isSkippableWordBoundary(doc[i - 1])) : (i -= 1) {}
    caret = i;
    if (!extend) anchor = caret;
}

fn moveWordRight(extend: bool) void {
    if (!extend and hasSelection()) {
        caret = selectionRange().end;
        anchor = caret;
        return;
    }
    var i = caret;
    while (i < doc_len and isSkippableWordBoundary(doc[i])) : (i += 1) {}
    while (i < doc_len and !isSkippableWordBoundary(doc[i])) : (i += 1) {}
    caret = i;
    if (!extend) anchor = caret;
}

fn hasSelection() bool {
    return caret != anchor;
}

fn selectionRange() Range {
    if (caret <= anchor) return .{ .start = caret, .end = anchor };
    return .{ .start = anchor, .end = caret };
}

fn copySelectionToClipboard() void {
    if (!hasSelection()) {
        clipboard_len = 0;
        return;
    }
    const sel = selectionRange();
    const count = @min(CLIP_CAP, sel.end - sel.start);
    var i: usize = 0;
    while (i < count) : (i += 1) clipboard[i] = doc[sel.start + i];
    clipboard_len = count;
}

fn replaceSelectionWith(text: []const u8) bool {
    _ = deleteSelection();
    return insertSlice(text);
}

fn deleteSelection() bool {
    if (!hasSelection()) return false;
    const sel = selectionRange();
    const remove_count = sel.end - sel.start;
    if (remove_count == 0) return false;
    var i = sel.start;
    while (i + remove_count < doc_len) : (i += 1) {
        doc[i] = doc[i + remove_count];
    }
    doc_len -= remove_count;
    caret = sel.start;
    anchor = caret;
    return true;
}

fn insertSlice(text: []const u8) bool {
    const to_insert = @min(text.len, DOC_CAP - doc_len + (if (hasSelection()) selectionRange().end - selectionRange().start else 0));
    if (to_insert == 0) return false;
    _ = deleteSelection();
    if (doc_len + to_insert > DOC_CAP) return false;

    var i: usize = doc_len;
    while (i > caret) : (i -= 1) {
        doc[i + to_insert - 1] = doc[i - 1];
    }
    var j: usize = 0;
    while (j < to_insert) : (j += 1) doc[caret + j] = text[j];
    doc_len += to_insert;
    caret += to_insert;
    anchor = caret;
    return true;
}

fn insertSliceRaw(text: []const u8) bool {
    if (text.len > DOC_CAP - doc_len) return false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        doc[doc_len + i] = text[i];
    }
    doc_len += text.len;
    return true;
}

fn backspace() bool {
    if (deleteSelection()) return true;
    if (caret == 0) return false;
    var i = caret - 1;
    while (i + 1 < doc_len) : (i += 1) {
        doc[i] = doc[i + 1];
    }
    doc_len -= 1;
    caret -= 1;
    anchor = caret;
    return true;
}

fn deleteForward() bool {
    if (deleteSelection()) return true;
    if (caret >= doc_len) return false;
    var i = caret;
    while (i + 1 < doc_len) : (i += 1) {
        doc[i] = doc[i + 1];
    }
    doc_len -= 1;
    anchor = caret;
    return true;
}

fn deleteWordBackward() bool {
    if (deleteSelection()) return true;
    if (caret == 0) return false;
    const end = caret;
    moveWordLeft(false);
    anchor = end;
    return deleteSelection();
}

fn deleteWordForward() bool {
    if (deleteSelection()) return true;
    if (caret >= doc_len) return false;
    const start = caret;
    moveWordRight(false);
    anchor = caret;
    caret = start;
    return deleteSelection();
}

fn deleteToLineStart() bool {
    if (deleteSelection()) return true;
    const start = lineStartAt(caret);
    if (start >= caret) return false;
    anchor = caret;
    caret = start;
    return deleteSelection();
}

fn deleteToLineEnd() bool {
    if (deleteSelection()) return true;
    const line_end = lineEndAt(caret);
    if (line_end <= caret) return false;
    anchor = line_end;
    return deleteSelection();
}

fn swapLineUp() bool {
    const current_start = lineStartAt(caret);
    if (current_start == 0) return false;
    const previous_start = lineStartAt(current_start - 1);
    return swapAdjacentLines(previous_start);
}

fn swapLineDown() bool {
    const current_start = lineStartAt(caret);
    const current_end = lineEndAt(current_start);
    if (current_end >= doc_len or doc[current_end] != '\n') return false;
    return swapAdjacentLines(current_start);
}

fn swapAdjacentLines(first_start: usize) bool {
    const first_end = lineEndAt(first_start);
    if (first_end >= doc_len or doc[first_end] != '\n') return false;
    const second_start = first_end + 1;
    if (second_start > doc_len) return false;
    const second_end = lineEndAt(second_start);
    const second_has_nl = second_end < doc_len and doc[second_end] == '\n';
    const region_end = second_end + @as(usize, if (second_has_nl) 1 else 0);

    const first_len = first_end - first_start;
    const second_len = second_end - second_start;
    const region_len = region_end - first_start;

    var w: usize = 0;
    var i = second_start;
    while (i < second_end) : (i += 1) {
        scratch[w] = doc[i];
        w += 1;
    }
    scratch[w] = '\n';
    w += 1;
    i = first_start;
    while (i < first_end) : (i += 1) {
        scratch[w] = doc[i];
        w += 1;
    }
    if (second_has_nl) {
        scratch[w] = '\n';
        w += 1;
    }
    if (w != region_len) return false;

    i = 0;
    while (i < region_len) : (i += 1) {
        doc[first_start + i] = scratch[i];
    }

    caret = remapAfterAdjacentLineSwap(caret, first_start, first_len, second_len);
    anchor = remapAfterAdjacentLineSwap(anchor, first_start, first_len, second_len);
    preferred_col = -1;
    return true;
}

fn remapAfterAdjacentLineSwap(pos: usize, first_start: usize, first_len: usize, second_len: usize) usize {
    const sep1 = first_start + first_len;
    const second_start = sep1 + 1;
    const second_end = second_start + second_len;

    if (pos < first_start or pos > second_end) return pos;
    if (pos < sep1) return pos + second_len + 1; // first line text
    if (pos == sep1) return first_start + second_len; // separator between lines
    if (pos < second_end) return pos - (first_len + 1); // second line text
    return pos; // trailing separator after second line (if present)
}

fn transposeChars() bool {
    if (hasSelection()) return false;
    if (doc_len < 2 or caret == 0) return false;

    // Emacs-style: at end of line/buffer, transpose the two chars before point.
    var left: usize = undefined;
    var right: usize = undefined;
    if (caret >= doc_len or doc[caret] == '\n') {
        if (caret < 2) return false;
        left = caret - 2;
        right = caret - 1;
    } else {
        left = caret - 1;
        right = caret;
    }

    if (right >= doc_len) return false;
    const tmp = doc[left];
    doc[left] = doc[right];
    doc[right] = tmp;

    if (caret < doc_len) caret += 1;
    anchor = caret;
    return true;
}

fn pushUndo() void {
    if (has_undo and undo_len == doc_len and undo_caret == caret and undo_anchor == anchor) return;
    var i: usize = 0;
    while (i < doc_len) : (i += 1) undo_doc[i] = doc[i];
    undo_len = doc_len;
    undo_caret = caret;
    undo_anchor = anchor;
    has_undo = true;
}

fn undo() void {
    if (!has_undo) return;
    var i: usize = 0;
    while (i < undo_len) : (i += 1) doc[i] = undo_doc[i];
    doc_len = undo_len;
    caret = @min(undo_caret, doc_len);
    anchor = @min(undo_anchor, doc_len);
    has_undo = false;
}

fn lineStartAt(idx: usize) usize {
    var i = @min(idx, doc_len);
    while (i > 0 and doc[i - 1] != '\n') : (i -= 1) {}
    return i;
}

fn lineEndAt(idx: usize) usize {
    var i = @min(idx, doc_len);
    while (i < doc_len and doc[i] != '\n') : (i += 1) {}
    return i;
}

fn lineNumberAt(idx: usize) i32 {
    const end = @min(idx, doc_len);
    var i: usize = 0;
    var line: i32 = 0;
    while (i < end) : (i += 1) {
        if (doc[i] == '\n') line += 1;
    }
    return line;
}

fn colAt(idx: usize) i32 {
    return @as(i32, @intCast(@min(idx, doc_len) - lineStartAt(idx)));
}

fn lineStartFor(line_no: i32) usize {
    if (line_no <= 0) return 0;
    var i: usize = 0;
    var line: i32 = 0;
    while (i < doc_len and line < line_no) : (i += 1) {
        if (doc[i] == '\n') line += 1;
    }
    return i;
}

fn indexAtLineCol(line_no: i32, col_no: i32) usize {
    const start = lineStartFor(line_no);
    const end = lineEndAt(start);
    const c = @max(0, col_no);
    return @min(end, start + @as(usize, @intCast(c)));
}

fn lineCount() i32 {
    if (doc_len == 0) return 1;
    var lines: i32 = 1;
    var i: usize = 0;
    while (i < doc_len) : (i += 1) {
        if (doc[i] == '\n') lines += 1;
    }
    return lines;
}

fn ensureCaretVisible() void {
    const line = lineNumberAt(caret);
    const col = colAt(caret);

    if (line < scroll_line) scroll_line = line;
    if (line >= scroll_line + VIEW_ROWS) scroll_line = line - VIEW_ROWS + 1;
    if (col < scroll_col) scroll_col = col;
    if (col >= scroll_col + VIEW_COLS) scroll_col = col - VIEW_COLS + 1;

    const max_scroll_line = @max(0, lineCount() - VIEW_ROWS);
    if (scroll_line > max_scroll_line) scroll_line = max_scroll_line;
    if (scroll_line < 0) scroll_line = 0;
    if (scroll_col < 0) scroll_col = 0;
}

fn textIndexAtPoint(x: i32, y: i32) usize {
    const clamped_x = clampI32(x, TEXT_X, TEXT_X + TEXT_W - 1);
    const clamped_y = clampI32(y, TEXT_Y, TEXT_Y + TEXT_H - 1);
    const line = scroll_line + @divTrunc(clamped_y - TEXT_Y, LINE_H);
    const col = scroll_col + @divTrunc(clamped_x - TEXT_X, CHAR_W);
    return indexAtLineCol(line, col);
}

fn markdownCheckboxMarkAt(text: []const u8, clicked_idx: usize) ?usize {
    if (clicked_idx >= text.len) return null;

    var line_start = clicked_idx;
    while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}

    var marker = line_start;
    while (marker < text.len and (text[marker] == ' ' or text[marker] == '\t')) : (marker += 1) {}
    if (marker + 4 >= text.len) return null;
    if (text[marker] != '-' and text[marker] != '*' and text[marker] != '+') return null;
    if (text[marker + 1] != ' ' or text[marker + 2] != '[' or text[marker + 4] != ']') return null;
    if (text[marker + 3] != ' ' and text[marker + 3] != 'x' and text[marker + 3] != 'X') return null;
    if (clicked_idx != marker + 3) return null;
    return marker + 3;
}

test "Markdown checkbox hit target covers only the mark" {
    const unchecked = "- [ ] first\n";
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt(unchecked, 2));
    try std.testing.expectEqual(@as(?usize, 3), markdownCheckboxMarkAt(unchecked, 3));
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt(unchecked, 4));
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt(unchecked, 5));

    const checked = "  * [X] second\n";
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt(checked, 4));
    try std.testing.expectEqual(@as(?usize, 5), markdownCheckboxMarkAt(checked, 5));
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt(checked, 6));
}

test "Markdown checkbox hit target rejects non-task syntax" {
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt("text [ ] inline\n", 6));
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt("- [y] invalid\n", 3));
    try std.testing.expectEqual(@as(?usize, null), markdownCheckboxMarkAt("-  [ ] extra space\n", 4));
}

test "clicking a Markdown checkbox toggles it" {
    const line = "- [ ] task\n";
    initialized = true;
    doc_len = line.len;
    @memcpy(doc[0..doc_len], line);
    caret = 8;
    anchor = 7;
    scroll_line = 0;
    scroll_col = 0;
    preferred_col = 6;
    primary_down = false;
    secondary_down = false;
    shift_down = false;
    has_undo = false;
    defer initialized = false;

    const left_bracket_x = TEXT_X + 2 * CHAR_W + 1;
    const checkbox_x = TEXT_X + 3 * CHAR_W + 1;
    const checkbox_y = TEXT_Y + 1;

    _ = pointerEventAt(BTN_PRIMARY, left_bracket_x, checkbox_y, 10);
    try std.testing.expectEqual(@as(u8, ' '), doc[3]);
    try std.testing.expectEqual(@as(usize, 2), caret);
    try std.testing.expectEqual(@as(usize, 2), anchor);
    _ = pointerEventAt(0, left_bracket_x, checkbox_y, 11);

    caret = 8;
    anchor = 7;
    preferred_col = 6;
    _ = pointerEventAt(BTN_PRIMARY, checkbox_x, checkbox_y, 100);
    try std.testing.expectEqual(@as(u8, 'x'), doc[3]);
    try std.testing.expectEqual(@as(usize, 8), caret);
    try std.testing.expectEqual(@as(usize, 7), anchor);
    try std.testing.expectEqual(@as(i32, 6), preferred_col);

    _ = pointerEventAt(0, checkbox_x, checkbox_y, 101);
    _ = pointerEventAt(BTN_PRIMARY, checkbox_x, checkbox_y, 200);
    try std.testing.expectEqual(@as(u8, ' '), doc[3]);
    try std.testing.expectEqual(@as(usize, 8), caret);
    try std.testing.expectEqual(@as(usize, 7), anchor);
    try std.testing.expectEqual(@as(i32, 6), preferred_col);
}

fn selectWordAt(idx: usize) void {
    const r = wordRangeAt(idx);
    anchor = r.start;
    caret = r.end;
    preferred_col = -1;
}

fn wordRangeAt(idx: usize) Range {
    if (doc_len == 0) return .{ .start = 0, .end = 0 };
    var pos = @min(idx, doc_len - 1);
    if (idx == doc_len and doc_len > 0 and doc[doc_len - 1] == '\n') {
        pos = doc_len - 1;
    }
    const cls = charClass(doc[pos]);
    var start = pos;
    while (start > 0 and charClass(doc[start - 1]) == cls) : (start -= 1) {}
    var end = pos + 1;
    while (end < doc_len and charClass(doc[end]) == cls) : (end += 1) {}
    return .{ .start = start, .end = end };
}

const CharClass = enum(u2) { word, space, punct, newline };

fn charClass(ch: u8) CharClass {
    if (ch == '\n') return .newline;
    if (ch == ' ' or ch == '\t') return .space;
    if (isWordChar(ch)) return .word;
    return .punct;
}

fn isWordChar(ch: u8) bool {
    if (ch >= 'a' and ch <= 'z') return true;
    if (ch >= 'A' and ch <= 'Z') return true;
    if (ch >= '0' and ch <= '9') return true;
    return ch == '_' or ch == '\'';
}

fn isSkippableWordBoundary(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or (!isWordChar(ch));
}

fn drawFrame() void {
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), C_DESKTOP);
    drawWindow();
}

fn drawWindow() void {
    fillRectI32(WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H, C_WIN);
    drawRect(WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H, C_WIN_DARK);

    drawVerticalGradient(WINDOW_X + 1, WINDOW_Y + 1, WINDOW_W - 2, TITLE_H - 2, C_TITLE_TOP, C_TITLE_BOTTOM);
    drawRect(WINDOW_X + 1, WINDOW_Y + TITLE_H - 1, WINDOW_W - 2, 1, C_WIN_DARK);
    drawTextScaled(WINDOW_X + 8, WINDOW_Y + 5, "TextEdit", C_TEXT, 1);

    fillRectI32(WINDOW_X + 1, WINDOW_Y + TITLE_H, WINDOW_W - 2, MENU_H, .{ 0xE5, 0xE5, 0xE5, 0xFF });
    drawRect(WINDOW_X + 1, WINDOW_Y + TITLE_H + MENU_H - 1, WINDOW_W - 2, 1, .{ 0xB2, 0xB2, 0xB2, 0xFF });
    drawTextScaled(WINDOW_X + 8, WINDOW_Y + TITLE_H + 4, "File Edit Format View Help", C_DIM, 1);

    fillRectI32(TEXT_X - 1, TEXT_Y - 1, TEXT_W + 2, TEXT_H + 2, C_WIN_DARK);
    fillRectI32(TEXT_X, TEXT_Y, TEXT_W, TEXT_H, C_TEXT_BG);
    drawDocumentText();
    drawStatusBar();
}

fn drawDocumentText() void {
    const sel = selectionRange();
    const has_sel = hasSelection();

    var row: i32 = 0;
    while (row < VIEW_ROWS) : (row += 1) {
        const line_no = scroll_line + row;
        const line_start = lineStartFor(line_no);
        if (line_start > doc_len) break;
        if (line_start == doc_len and line_no > lineNumberAt(doc_len)) break;
        const line_end = lineEndAt(line_start);

        const visible_start = @min(line_end, line_start + @as(usize, @intCast(scroll_col)));
        const visible_end = @min(line_end, visible_start + @as(usize, @intCast(VIEW_COLS)));
        const y = TEXT_Y + row * LINE_H;
        const newline_selected = has_sel and line_end < doc_len and line_end >= sel.start and line_end < sel.end;
        const line_selected_start = @max(sel.start, line_start);
        const line_has_selected_chars = has_sel and line_selected_start < line_end;
        var newline_fill_x0 = TEXT_X;
        if (line_has_selected_chars) {
            if (line_selected_start <= visible_start) {
                newline_fill_x0 = TEXT_X;
            } else if (line_selected_start >= visible_end) {
                newline_fill_x0 = TEXT_X + TEXT_W;
            } else {
                newline_fill_x0 = TEXT_X + @as(i32, @intCast(line_selected_start - visible_start)) * CHAR_W;
            }
        }
        if (newline_selected) {
            const w = (TEXT_X + TEXT_W) - newline_fill_x0;
            if (w > 0) fillRectI32(newline_fill_x0, y, w, LINE_H, C_SEL);
        }

        var i = visible_start;
        while (i < visible_end) : (i += 1) {
            const x = TEXT_X + @as(i32, @intCast(i - visible_start)) * CHAR_W;
            if (has_sel and i >= sel.start and i < sel.end) {
                fillRectI32(x, y, CHAR_W, LINE_H, C_SEL);
            }
            const ch = doc[i];
            drawTextScaled(x + 1, y + 3, &[_]u8{ch}, if (has_sel and i >= sel.start and i < sel.end) C_SEL_TEXT else C_TEXT, 2);
        }
    }

    if (blink_on) drawCaret();
    drawScrollBar();
}

fn drawCaret() void {
    if (hasSelection()) return;
    const line = lineNumberAt(caret);
    const col = colAt(caret);
    if (line < scroll_line or line >= scroll_line + VIEW_ROWS) return;
    if (col < scroll_col or col > scroll_col + VIEW_COLS) return;
    const x = TEXT_X + (col - scroll_col) * CHAR_W;
    const y = TEXT_Y + (line - scroll_line) * LINE_H;
    fillRectI32(x, y + 1, 1, LINE_H - 2, C_CARET);
}

fn drawScrollBar() void {
    const bar_x = TEXT_X + TEXT_W - 8;
    const bar_y = TEXT_Y + 1;
    const bar_h = TEXT_H - 2;
    fillRectI32(bar_x, bar_y, 7, bar_h, .{ 0xEE, 0xEE, 0xEE, 0xFF });
    drawRect(bar_x, bar_y, 7, bar_h, .{ 0xC2, 0xC2, 0xC2, 0xFF });

    const lines = lineCount();
    if (lines <= VIEW_ROWS) {
        fillRectI32(bar_x + 1, bar_y + 1, 5, bar_h - 2, .{ 0xD8, 0xD8, 0xD8, 0xFF });
        return;
    }

    const thumb_h = @max(8, @divTrunc(bar_h * VIEW_ROWS, lines));
    const max_scroll = @max(1, lines - VIEW_ROWS);
    const travel = bar_h - thumb_h;
    const thumb_y = bar_y + @divTrunc(scroll_line * travel, max_scroll);
    fillRectI32(bar_x + 1, thumb_y, 5, thumb_h, .{ 0xB7, 0xB7, 0xB7, 0xFF });
    drawRect(bar_x + 1, thumb_y, 5, thumb_h, .{ 0x8D, 0x8D, 0x8D, 0xFF });
}

fn drawStatusBar() void {
    const y = WINDOW_Y + WINDOW_H - 10;
    fillRectI32(WINDOW_X + 1, y, WINDOW_W - 2, 9, .{ 0xE5, 0xE5, 0xE5, 0xFF });
    drawRect(WINDOW_X + 1, y, WINDOW_W - 2, 1, .{ 0xBC, 0xBC, 0xBC, 0xFF });

    const line = lineNumberAt(caret) + 1;
    const col = colAt(caret) + 1;
    drawTextScaled(WINDOW_X + 6, y + 2, "Ln", C_DIM, 1);
    drawNumber(WINDOW_X + 18, y + 2, line, C_DIM);
    drawTextScaled(WINDOW_X + 46, y + 2, "Col", C_DIM, 1);
    drawNumber(WINDOW_X + 66, y + 2, col, C_DIM);
    drawTextScaled(WINDOW_X + 104, y + 2, "Chars", C_DIM, 1);
    drawNumber(WINDOW_X + 134, y + 2, @as(i32, @intCast(doc_len)), C_DIM);
}

fn drawNumber(x: i32, y: i32, n: i32, color: Color) void {
    var buf: [16]u8 = undefined;
    const len = formatInt(n, &buf);
    drawTextScaled(x, y, buf[0..len], color, 1);
}

fn formatInt(n: i32, out: []u8) usize {
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

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn drawVerticalGradient(x: i32, y: i32, w: i32, h: i32, top: Color, bottom: Color) void {
    if (w <= 0 or h <= 0) return;
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        const t = @divTrunc(yy * 255, @max(1, h - 1));
        const c: Color = .{
            lerpU8(top[0], bottom[0], t),
            lerpU8(top[1], bottom[1], t),
            lerpU8(top[2], bottom[2], t),
            0xFF,
        };
        fillRectI32(x, y + yy, w, 1, c);
    }
}

fn lerpU8(a: u8, b: u8, t255: i32) u8 {
    const inv = 255 - t255;
    const v = @divTrunc(@as(i32, a) * inv + @as(i32, b) * t255 + 127, 255);
    return @as(u8, @intCast(clampI32(v, 0, 255)));
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
            fillRectI32(
                x + @as(i32, @intCast(rx)) * scale,
                y + @as(i32, @intCast(ry)) * scale,
                scale,
                scale,
                c,
            );
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
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        ',' => .{ 0b000, 0b000, 0b000, 0b010, 0b100 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        ';' => .{ 0b000, 0b010, 0b000, 0b010, 0b100 },
        '!' => .{ 0b010, 0b010, 0b010, 0b000, 0b010 },
        '?' => .{ 0b111, 0b001, 0b011, 0b000, 0b010 },
        '"' => .{ 0b101, 0b101, 0b000, 0b000, 0b000 },
        '\'' => .{ 0b010, 0b010, 0b000, 0b000, 0b000 },
        '(' => .{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => .{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '[' => .{ 0b011, 0b010, 0b010, 0b010, 0b011 },
        ']' => .{ 0b110, 0b010, 0b010, 0b010, 0b110 },
        '{' => .{ 0b001, 0b010, 0b110, 0b010, 0b001 },
        '}' => .{ 0b100, 0b010, 0b011, 0b010, 0b100 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '\\' => .{ 0b100, 0b100, 0b010, 0b001, 0b001 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => .{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '=' => .{ 0b000, 0b111, 0b000, 0b111, 0b000 },
        '_' => .{ 0b000, 0b000, 0b000, 0b000, 0b111 },
        '|' => .{ 0b010, 0b010, 0b010, 0b010, 0b010 },
        '#' => .{ 0b101, 0b111, 0b101, 0b111, 0b101 },
        '$' => .{ 0b010, 0b111, 0b110, 0b011, 0b111 },
        '%' => .{ 0b101, 0b001, 0b010, 0b100, 0b101 },
        '&' => .{ 0b010, 0b101, 0b010, 0b101, 0b011 },
        '@' => .{ 0b111, 0b101, 0b111, 0b100, 0b111 },
        '^' => .{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '`' => .{ 0b010, 0b001, 0b000, 0b000, 0b000 },
        '~' => .{ 0b000, 0b011, 0b110, 0b000, 0b000 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) setPixelI32(x, y, c);
        }
    }
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) setPixelI32(x, y, c);
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}
