const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const inter_regular = @import("inter_regular");
const jetbrains_mono = @import("jetbrains_mono");
const buttons = @import("assets/textedit-tiger-buttons.zig");

// A plain-text TextEdit document window in the style of Mac OS X 10.4
// Tiger: a smooth gray title bar with gel buttons directly over the text,
// monospaced document text (JetBrains Mono standing in for Monaco 10), an
// Aqua scroll bar and a grow box. Document text is JetBrains Mono and window
// text is Inter, both rasterized from their outlines with anti-aliasing.
// Lines soft-wrap to the window.
//
// Layout is in points. Frames are drawn at SCALE pixels per point, like a
// Retina display, so a page shows the frame at half its pixel size. Pointer
// coordinates arrive in frame pixels and are divided back into points.

const SCALE: i32 = 2;
const SCALE_F: f32 = @floatFromInt(SCALE);
const POINTS_W: usize = 375;
const POINTS_H: usize = 400;
const RENDER_W: usize = POINTS_W * @as(usize, @intCast(SCALE));
const RENDER_H: usize = POINTS_H * @as(usize, @intCast(SCALE));
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

// Window layout, in points.
const WIN_W: i32 = @intCast(POINTS_W);
const WIN_H: i32 = @intCast(POINTS_H);
// Frame size, in pixels.
const PX_W: i32 = @intCast(RENDER_W);
const PX_H: i32 = @intCast(RENDER_H);
// One device pixel, the width of a separator line.
const HAIRLINE: f32 = 1.0 / SCALE_F;
// Only the top corners are rounded.
const CORNER_R: f32 = 5.0;
// The title bar is 22 points of gradient over a dark rule.
const TITLE_H: i32 = 23;
const CONTENT_TOP: i32 = TITLE_H;
const CONTENT_BOTTOM: i32 = WIN_H;
const SCROLL_W: i32 = 15;

// Document text. JetBrains Mono advances are 600/1000 em, so a 6 point
// advance is 10 point type, matching Monaco 10's cell on a 13 point line.
const CHAR_W: i32 = 6;
const LINE_H: i32 = 13;
const BASELINE: f32 = 10.0;
const TEXT_X: i32 = 6;
const TEXT_Y: i32 = CONTENT_TOP + 2;
const TEXT_W: i32 = WIN_W - TEXT_X - SCROLL_W - 4;
const TEXT_W_PX: i32 = TEXT_W * SCALE;
const TEXT_H: i32 = CONTENT_BOTTOM - TEXT_Y - 4;
const VIEW_ROWS: i32 = @divTrunc(TEXT_H, LINE_H);

// The scroll bar keeps both arrows together at the bottom, above the grow
// box in the window's corner.
const SB_ARROW_H: i32 = 16;
const GROW_H: i32 = 15;

// Top of the arrow buttons, where the track ends in a rounded bowl.
const SB_ARROWS_Y: i32 = CONTENT_BOTTOM - GROW_H - 2 * SB_ARROW_H;
// Above the track sits a cap shaded like the arrow buttons, 5 points deep
// at the middle, whose lower edge is the track's rounded top end. The
// thumb is held 1 point inside each rounded end, as in the scroll bar
// figures in Apple's 2005 Human Interface Guidelines.
const SB_CAP_H: i32 = 5;
// The thumb's travel.
const SB_TRACK_Y: i32 = CONTENT_TOP + SB_CAP_H + 1;
const SB_TRACK_H: i32 = SB_ARROWS_Y - 1 - SB_TRACK_Y;

const Color = [4]u8;
const C_TEXT_BG: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_TEXT: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_SEL: Color = .{ 0xB5, 0xD5, 0xFF, 0xFF };
const C_SEL_INACTIVE: Color = .{ 0xD4, 0xD4, 0xD4, 0xFF };
const C_CARET: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_FRAME: Color = .{ 0xA2, 0xA2, 0xA2, 0xFF };

const Range = struct { start: usize, end: usize };
const Pos = struct { idx: usize, upstream: bool };

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;

var doc: [DOC_CAP]u8 = undefined;
var doc_len: usize = 0;

// One level of undo and redo. An edit snapshots the document first and
// keeps the snapshot only if the document changed; a run of typed
// characters shares one undo step.
var pre_doc: [DOC_CAP]u8 = undefined;
var pre_len: usize = 0;
var pre_caret: usize = 0;
var pre_anchor: usize = 0;
var undo_doc: [DOC_CAP]u8 = undefined;
var undo_len: usize = 0;
var undo_caret: usize = 0;
var undo_anchor: usize = 0;
var has_undo: bool = false;
var redo_doc: [DOC_CAP]u8 = undefined;
var redo_len: usize = 0;
var redo_caret: usize = 0;
var redo_anchor: usize = 0;
var has_redo: bool = false;
var typing_run: bool = false;

// Edits since the document was last saved, counted the way Tiger's
// NSDocument did: each new undo step adds one, Undo takes one away and Redo
// adds it back. The document is Edited while this isn't zero, so typing and
// then deleting it leaves the window Edited until Undo returns to the saved
// state.
var change_count: i32 = 0;

var clipboard: [CLIP_CAP]u8 = undefined;
var clipboard_len: usize = 0;
var scratch: [DOC_CAP]u8 = undefined;

var caret: usize = 0;
var anchor: usize = 0;
// At a soft wrap the same index ends one row and starts the next. Upstream
// shows the caret at the end of the earlier row.
var caret_upstream: bool = false;
var upstream_request: bool = false;

// Visual rows after soft wrapping. Rebuilt from the document when needed.
var row_start: [DOC_CAP + 1]u16 = undefined;
var row_end: [DOC_CAP + 1]u16 = undefined;
var row_count: usize = 1;

var scroll_row: i32 = 0;
// The caret's goal distance from the row start for Up and Down, in frame
// pixels, or -1 when unset.
var preferred_col: i32 = -1;

var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;
var mouse_selecting: bool = false;
var last_primary_click_ms: i64 = -1000000;
var last_primary_click_idx: usize = 0;
var click_count: u8 = 0;
var shift_down: bool = false;
var sb_dragging: bool = false;
var sb_drag_offset: i32 = 0;
// The scroll arrow held down: -1 up, 1 down, 0 none.
var sb_arrow_down: i32 = 0;
// The pointer is over the close, minimize and zoom group, which shows their
// glyphs on all three, as macOS does.
var lights_hover: bool = false;
// The light pressed down, 0 to 2, or -1. It shows pressed only while the
// pointer is still over it.
var lights_pressed: i32 = -1;

var blink_on: bool = true;
var next_blink_at_ms: i64 = BLINK_INTERVAL_MS;
// Whether this is the key window. A host that tracks focus, like
// <qip-play>, sets the is_focused uniform; other hosts leave it on. An
// inactive window draws the way Tiger drew background windows: a paler
// title bar, gray buttons and thumb, a gray selection and no caret.
var is_focused: bool = true;
// Becoming focused restarts the caret blink at the next update.
var blink_restart: bool = false;
var needs_redraw: bool = true;
var initialized: bool = false;

const DEFAULT_TEXT =
    "Welcome to TextEdit\n" ++
    "\n" ++
    "This is a plain text document. Click to place the insertion point, drag to select, double-click to select a word, or triple-click to select a paragraph. Long lines wrap to fit the window.\n" ++
    "\n" ++
    "To do:\n" ++
    "- [x] Open TextEdit\n" ++
    "- [ ] Write something\n" ++
    "- [ ] Click a box to tick it off\n" ++
    "\n" ++
    "Shortcuts:\n" ++
    "  Cmd+A          Select All\n" ++
    "  Cmd+C, X, V    Copy, Cut, Paste\n" ++
    "  Cmd+Z          Undo\n" ++
    "  Shift+Cmd+Z    Redo\n" ++
    "  Option+Up      Move line up\n" ++
    "  Option+Down    Move line down\n";

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

    const before_caret = caret;
    upstream_request = false;
    const handled = handleKey(x11_key, flags);
    if (caret != before_caret or upstream_request) caret_upstream = upstream_request;
    return if (handled) 1 else 0;
}

fn handleKey(x11_key: i32, flags: i32) bool {
    const extend = (flags & FLAG_SHIFT) != 0;
    const control = (flags & FLAG_CTRL) != 0;
    const shortcut_mod = (flags & (FLAG_CTRL | FLAG_META)) != 0;
    const command = (flags & FLAG_META) != 0;
    const alt = (flags & FLAG_ALT) != 0;
    const was_typing = typing_run;
    typing_run = false;

    if (shortcut_mod and (x11_key == 'z' or x11_key == 'Z')) {
        if (extend) _ = redo() else _ = undo();
        touchAfterEdit(begun_at_ms);
        return true;
    }

    snapshot();

    if (shortcut_mod and handleShortcut(x11_key, control, command)) {
        _ = commitUndo(false);
        touchAfterEdit(begun_at_ms);
        return true;
    }

    if (alt and !command and handleLineSwapKey(x11_key)) {
        _ = commitUndo(false);
        touchAfterEdit(begun_at_ms);
        return true;
    }

    if (handleNavKey(x11_key, extend, alt, command)) {
        touchAfterNav(begun_at_ms);
        return true;
    }

    if (handleEditKey(x11_key, alt, command)) {
        _ = commitUndo(false);
        touchAfterEdit(begun_at_ms);
        return true;
    }

    if (isPrintable(x11_key) and !shortcut_mod and !alt) {
        const ch: u8 = @as(u8, @intCast(x11_key));
        if (insertSlice(&[_]u8{ch})) {
            typing_run = was_typing;
            _ = commitUndo(true);
            typing_run = true;
            touchAfterEdit(begun_at_ms);
        }
        return true;
    }

    return false;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    return pointerEventAt(button_mask, @divFloor(x_px, SCALE), @divFloor(y_px, SCALE), begun_at_ms);
}

fn pointerEventAt(button_mask: i32, x_px: i32, y_px: i32, now_ms: i64) i32 {
    const before_caret = caret;
    upstream_request = false;
    const changed = pointerInner(button_mask, x_px, y_px, now_ms);
    if (caret != before_caret or upstream_request) caret_upstream = upstream_request;
    return if (changed or needs_redraw) 1 else 0;
}

fn pointerInner(button_mask: i32, x_px: i32, y_px: i32, now_ms: i64) bool {
    pointer_x = x_px;
    pointer_y = y_px;
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;
    defer {
        primary_down = primary;
        secondary_down = secondary;
    }

    const in_content = y_px >= CONTENT_TOP and y_px < CONTENT_BOTTOM and x_px >= 0 and x_px < WIN_W;
    const in_scroll = in_content and x_px >= WIN_W - SCROLL_W and isScrollable();
    var changed = false;

    // Close, minimize and zoom. Pressing one shows it pressed; releasing
    // does nothing, as there is no window to close, hide or zoom.
    const over_lights = inLightsGroup(x_px, y_px);
    if (over_lights != lights_hover) {
        lights_hover = over_lights;
        changed = true;
    }
    if (lights_pressed >= 0) {
        if (!primary) lights_pressed = -1;
        return true;
    }
    if (primary and !primary_down) {
        if (lightAt(x_px, y_px)) |i| {
            lights_pressed = @intCast(i);
            typing_run = false;
            return true;
        }
    }

    // Scroll bar: drag the thumb, or click the track to jump there.
    if (sb_dragging) {
        if (primary) {
            const before = scroll_row;
            scrollToThumbY(y_px - sb_drag_offset);
            return changed or before != scroll_row;
        }
        sb_dragging = false;
        return true;
    }
    if (sb_arrow_down != 0 and !primary) {
        sb_arrow_down = 0;
        return true;
    }
    if (primary and !primary_down and in_scroll) {
        typing_run = false;
        const arrows_top = SB_ARROWS_Y;
        if (y_px >= arrows_top) {
            // The up arrow sits above the down arrow; the grow box below
            // them does nothing.
            if (y_px >= arrows_top + 2 * SB_ARROW_H) return changed;
            sb_arrow_down = if (y_px < arrows_top + SB_ARROW_H) -1 else 1;
            scroll_row += sb_arrow_down;
            clampScroll();
            return true;
        }
        const thumb = thumbGeometry();
        if (y_px < thumb.y or y_px >= thumb.y + thumb.h) {
            // Clicking the track above or below the thumb pages, as Tiger
            // does by default.
            const page: i32 = @max(1, VIEW_ROWS - 1);
            scroll_row += if (y_px < thumb.y) -page else page;
            clampScroll();
            return true;
        }
        sb_drag_offset = y_px - thumb.y;
        sb_dragging = true;
        return true;
    }

    const in_text = in_content and x_px < WIN_W - SCROLL_W;

    if (secondary and !secondary_down and in_text) {
        const pos = posAtPoint(x_px, y_px);
        if (!hasSelection() or pos.idx < selectionRange().start or pos.idx > selectionRange().end) {
            caret = pos.idx;
            anchor = pos.idx;
            upstream_request = pos.upstream;
        }
        preferred_col = -1;
        mouse_selecting = false;
        typing_run = false;
        touchAfterNav(now_ms);
    }

    if (primary and !primary_down) {
        typing_run = false;
        // Presses in the title bar or below the text change nothing.
        if (!in_text) {
            click_count = 0;
            return changed;
        }
        const pos = posAtPoint(x_px, y_px);
        const char_idx = charIndexAtPoint(x_px, y_px);
        const extend_selection = shift_down;
        const near_last = absI32(@as(i32, @intCast(char_idx)) - @as(i32, @intCast(last_primary_click_idx))) <= 1;
        const since_last = now_ms - last_primary_click_ms;
        const is_repeat = !extend_selection and since_last >= 0 and since_last <= DOUBLE_CLICK_MS and near_last;
        const checkbox_mark = if (!extend_selection) markdownCheckboxMarkAt(doc[0..doc_len], char_idx) else null;
        if (checkbox_mark) |mark_idx| {
            snapshot();
            doc[mark_idx] = if (doc[mark_idx] == ' ') 'x' else ' ';
            _ = commitUndo(false);
            mouse_selecting = false;
            last_primary_click_ms = -1000000;
            click_count = 0;
            blink_on = true;
            next_blink_at_ms = now_ms +| BLINK_INTERVAL_MS;
            needs_redraw = true;
            return true;
        }
        click_count = if (is_repeat) @min(3, click_count + 1) else 1;
        if (extend_selection) {
            caret = pos.idx;
            upstream_request = pos.upstream;
            preferred_col = -1;
            mouse_selecting = true;
        } else if (click_count == 2) {
            selectWordAt(char_idx);
            mouse_selecting = false;
        } else if (click_count == 3) {
            selectParagraphAt(char_idx);
            mouse_selecting = false;
        } else {
            caret = pos.idx;
            anchor = pos.idx;
            upstream_request = pos.upstream;
            preferred_col = -1;
            mouse_selecting = true;
        }
        last_primary_click_ms = now_ms;
        last_primary_click_idx = char_idx;
        touchAfterNav(now_ms);
        return true;
    }
    if (primary and primary_down and mouse_selecting) {
        const pos = posAtPoint(x_px, y_px);
        const moved = pos.idx != caret;
        caret = pos.idx;
        upstream_request = pos.upstream;
        if (moved) {
            ensureCaretVisible();
            touchAfterNav(now_ms);
        }
        return changed or moved;
    }
    if (!primary) mouse_selecting = false;
    return changed;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (blink_restart) {
        blink_restart = false;
        blink_on = true;
        next_blink_at_ms = begun_at_ms +| BLINK_INTERVAL_MS;
    } else if (is_focused and next_blink_at_ms > 0 and begun_at_ms >= next_blink_at_ms) {
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
    // An inactive window has no caret, so it has nothing to wake for.
    return if (is_focused and next_blink_at_ms > begun_at_ms) next_blink_at_ms else begun_at_ms;
}

// 1 while the window has focus, 0 while it doesn't. Defaults to 1.
export fn uniform_set_is_focused(value: u32) u32 {
    const focused = value != 0;
    if (focused != is_focused) {
        is_focused = focused;
        blink_restart = focused;
        blink_on = true;
        needs_redraw = true;
    }
    return @intFromBool(is_focused);
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
    buildDocAtlas();
    resetState();
}

fn resetState() void {
    doc_len = 0;
    clipboard_len = 0;
    has_undo = false;
    has_redo = false;
    typing_run = false;
    caret = 0;
    anchor = 0;
    caret_upstream = false;
    scroll_row = 0;
    preferred_col = -1;
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    mouse_selecting = false;
    last_primary_click_ms = -1000000;
    last_primary_click_idx = 0;
    click_count = 0;
    shift_down = false;
    sb_dragging = false;
    sb_arrow_down = 0;
    lights_hover = false;
    lights_pressed = -1;
    blink_on = true;
    next_blink_at_ms = BLINK_INTERVAL_MS;

    _ = insertSliceRaw(DEFAULT_TEXT);
    markSaved();
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

// ---------------------------------------------------------------------------
// Undo, redo and the Edited state

fn snapshot() void {
    @memcpy(pre_doc[0..doc_len], doc[0..doc_len]);
    pre_len = doc_len;
    pre_caret = caret;
    pre_anchor = anchor;
}

fn changedSinceSnapshot() bool {
    return pre_len != doc_len or !std.mem.eql(u8, pre_doc[0..pre_len], doc[0..doc_len]);
}

// Keeps the snapshot as the undo step if the document changed. When
// `coalesce` is set and a typing run is already open, the run's first
// snapshot stays the undo step.
fn commitUndo(coalesce: bool) bool {
    if (!changedSinceSnapshot()) return false;
    if (!(coalesce and typing_run and has_undo)) {
        @memcpy(undo_doc[0..pre_len], pre_doc[0..pre_len]);
        undo_len = pre_len;
        undo_caret = pre_caret;
        undo_anchor = pre_anchor;
        has_undo = true;
        change_count +|= 1;
    }
    has_redo = false;
    return true;
}

fn undo() bool {
    if (!has_undo) return false;
    @memcpy(redo_doc[0..doc_len], doc[0..doc_len]);
    redo_len = doc_len;
    redo_caret = caret;
    redo_anchor = anchor;
    has_redo = true;
    @memcpy(doc[0..undo_len], undo_doc[0..undo_len]);
    doc_len = undo_len;
    caret = @min(undo_caret, doc_len);
    anchor = @min(undo_anchor, doc_len);
    has_undo = false;
    change_count -|= 1;
    return true;
}

fn redo() bool {
    if (!has_redo) return false;
    @memcpy(undo_doc[0..doc_len], doc[0..doc_len]);
    undo_len = doc_len;
    undo_caret = caret;
    undo_anchor = anchor;
    has_undo = true;
    @memcpy(doc[0..redo_len], redo_doc[0..redo_len]);
    doc_len = redo_len;
    caret = @min(redo_caret, doc_len);
    anchor = @min(redo_anchor, doc_len);
    has_redo = false;
    change_count +|= 1;
    return true;
}

fn markSaved() void {
    change_count = 0;
}

fn isEdited() bool {
    return change_count != 0;
}

// ---------------------------------------------------------------------------
// Keys

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
            copySelectionToClipboard();
            _ = deleteSelection();
            return true;
        },
        'v', 'V' => {
            if (clipboard_len == 0) return true;
            _ = replaceSelectionWith(clipboard[0..clipboard_len]);
            return true;
        },
        't', 'T' => {
            if (!control or command) return false;
            return transposeChars();
        },
        else => return false,
    }
}

fn handleLineSwapKey(key: i32) bool {
    switch (key) {
        XK_UP => {
            _ = swapLineUp();
            return true;
        },
        XK_DOWN => {
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
            if (command) return deleteToLineStart();
            if (alt) return deleteWordBackward();
            return backspace();
        },
        XK_DELETE => {
            if (command) return deleteToLineEnd();
            if (alt) return deleteWordForward();
            return deleteForward();
        },
        XK_RETURN => {
            return insertSlice(&[_]u8{'\n'});
        },
        XK_TAB => {
            return insertSlice("    ");
        },
        else => return false,
    }
}

fn isPrintable(k: i32) bool {
    return k >= 32 and k <= 126;
}

// ---------------------------------------------------------------------------
// Caret movement

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

// Home and End, and Cmd+Left and Cmd+Right, act on the visual row.
fn moveHome(extend: bool) void {
    const r = caretRow();
    caret = row_start[r];
    if (!extend) anchor = caret;
}

fn moveEnd(extend: bool) void {
    const r = caretRow();
    caret = row_end[r];
    upstream_request = isSoftWrapped(r);
    if (!extend) anchor = caret;
}

fn moveVertical(delta_rows: i32, extend: bool) void {
    const r = caretRow();
    if (preferred_col < 0) preferred_col = rowWidthPx(row_start[r], caret);
    const last: i32 = @intCast(row_count - 1);
    const ri: i32 = @intCast(r);
    if (delta_rows < 0 and ri == 0) {
        caret = 0;
    } else if (delta_rows > 0 and ri == last) {
        caret = doc_len;
    } else {
        const target: usize = @intCast(clampI32(ri + delta_rows, 0, last));
        const pos = posAtRowX(target, preferred_col);
        caret = pos.idx;
        upstream_request = pos.upstream;
    }
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

// ---------------------------------------------------------------------------
// Editing primitives

fn copySelectionToClipboard() void {
    if (!hasSelection()) return;
    const sel = selectionRange();
    const count = @min(CLIP_CAP, sel.end - sel.start);
    @memcpy(clipboard[0..count], doc[sel.start .. sel.start + count]);
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
    @memcpy(doc[doc_len .. doc_len + text.len], text);
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
    const start = row_start[caretRow()];
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

    @memcpy(doc[first_start .. first_start + region_len], scratch[0..region_len]);

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

// ---------------------------------------------------------------------------
// Logical lines

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

// ---------------------------------------------------------------------------
// Visual rows (soft wrap)

fn pushRow(start: usize, end: usize) void {
    row_start[row_count] = @intCast(start);
    row_end[row_count] = @intCast(end);
    row_count += 1;
}

// A document character's advance in frame pixels.
fn advPx(ch: u8) i32 {
    return doc_adv[ch];
}

const doc_adv = blk: {
    @setEvalBranchQuota(20_000);
    var out = [_]i32{0} ** 256;
    for (32..127) |ch| {
        out[ch] = CHAR_W * SCALE;
    }
    break :blk out;
};

// The width in frame pixels of the document from `start` to `end`.
fn rowWidthPx(start: usize, end: usize) i32 {
    var w: i32 = 0;
    for (doc[start..end]) |ch| w += advPx(ch);
    return w;
}

// Breaks each logical line into rows no wider than the text column, after
// the last space that fits. Spaces at a break hang past the edge, as in
// TextEdit. A word longer than a row is broken at the edge.
fn relayout() void {
    row_count = 0;
    var start: usize = 0;
    while (true) {
        const le = lineEndAt(start);
        var s = start;
        while (true) {
            // The most characters that fit.
            var fit = s;
            var w: i32 = 0;
            while (fit < le and w + advPx(doc[fit]) <= TEXT_W_PX) : (fit += 1) w += advPx(doc[fit]);
            if (fit >= le) {
                pushRow(s, le);
                break;
            }
            var b = fit;
            if (doc[b] != ' ') {
                while (b > s and doc[b - 1] != ' ') b -= 1;
                if (b == s) b = @max(fit, s + 1);
            }
            while (b < le and doc[b] == ' ') b += 1;
            if (b >= le) {
                pushRow(s, le);
                break;
            }
            pushRow(s, b);
            s = b;
        }
        if (le >= doc_len) break;
        start = le + 1;
    }
}

fn isSoftWrapped(r: usize) bool {
    return r + 1 < row_count and row_start[r + 1] == row_end[r];
}

fn rowOf(idx: usize, upstream: bool) usize {
    var lo: usize = 0;
    var hi: usize = row_count;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (row_start[mid] <= idx) lo = mid else hi = mid;
    }
    if (upstream and lo > 0 and row_start[lo] == idx and isSoftWrapped(lo - 1)) return lo - 1;
    return lo;
}

fn caretRow() usize {
    relayout();
    return rowOf(caret, caret_upstream);
}

// The caret position on row `r` nearest to `x` frame pixels from its start.
fn posAtRowX(r: usize, x: i32) Pos {
    const rs: usize = row_start[r];
    const re: usize = row_end[r];
    var idx = rs;
    var w: i32 = 0;
    while (idx < re) : (idx += 1) {
        const a = advPx(doc[idx]);
        if (x < w + @divTrunc(a, 2)) break;
        w += a;
    }
    return .{ .idx = idx, .upstream = idx == re and isSoftWrapped(r) };
}

fn rowAtY(y: i32) usize {
    const r = scroll_row + @divFloor(y - TEXT_Y, LINE_H);
    return @intCast(clampI32(r, 0, @as(i32, @intCast(row_count)) - 1));
}

// The caret position nearest to a point.
fn posAtPoint(x: i32, y: i32) Pos {
    relayout();
    const r = rowAtY(y);
    return posAtRowX(r, (x - TEXT_X) * SCALE + @divTrunc(SCALE, 2));
}

// The character under a point, or the row end past the last character.
fn charIndexAtPoint(x: i32, y: i32) usize {
    relayout();
    const r = rowAtY(y);
    const px = (x - TEXT_X) * SCALE + @divTrunc(SCALE, 2);
    var idx: usize = row_start[r];
    var w: i32 = 0;
    while (idx < row_end[r]) : (idx += 1) {
        w += advPx(doc[idx]);
        if (px < w) break;
    }
    return idx;
}

fn maxScroll() i32 {
    return @max(0, @as(i32, @intCast(row_count)) - VIEW_ROWS);
}

fn clampScroll() void {
    scroll_row = clampI32(scroll_row, 0, maxScroll());
}

fn ensureCaretVisible() void {
    const r: i32 = @intCast(caretRow());
    if (r < scroll_row) scroll_row = r;
    if (r >= scroll_row + VIEW_ROWS) scroll_row = r - VIEW_ROWS + 1;
    clampScroll();
}

fn isScrollable() bool {
    relayout();
    return @as(i32, @intCast(row_count)) > VIEW_ROWS;
}

const Thumb = struct { y: i32, h: i32 };

fn thumbGeometry() Thumb {
    relayout();
    const total: i32 = @intCast(row_count);
    const h = @max(28, @divTrunc(SB_TRACK_H * VIEW_ROWS, @max(1, total)));
    const travel = SB_TRACK_H - h;
    const max_scroll = @max(1, maxScroll());
    return .{ .y = SB_TRACK_Y + @divTrunc(clampI32(scroll_row, 0, max_scroll) * travel, max_scroll), .h = h };
}

fn scrollToThumbY(thumb_y: i32) void {
    const thumb = thumbGeometry();
    const travel = @max(1, SB_TRACK_H - thumb.h);
    scroll_row = @divTrunc((thumb_y - SB_TRACK_Y) * maxScroll() + @divTrunc(travel, 2), travel);
    clampScroll();
    needs_redraw = true;
}

// ---------------------------------------------------------------------------
// Markdown task boxes

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

fn selectWordAt(idx: usize) void {
    const r = wordRangeAt(idx);
    anchor = r.start;
    caret = r.end;
    preferred_col = -1;
}

fn selectParagraphAt(idx: usize) void {
    const start = lineStartAt(idx);
    const end = lineEndAt(idx);
    anchor = start;
    caret = if (end < doc_len) end + 1 else end;
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

// ---------------------------------------------------------------------------
// Fonts and anti-aliased outline rasterizing

fn Face(comptime F: type, comptime with_em_dash: bool) type {
    return struct {
        const count: usize = 95 + @as(usize, if (with_em_dash) 1 else 0);
        const upem: f32 = F.UNITS_PER_EM;
        const glyph_ids = blk: {
            @setEvalBranchQuota(200_000);
            var ids: [count]usize = undefined;
            for (0..95) |i| ids[i] = F.glyphIndex(32 + i).?;
            if (with_em_dash) ids[95] = F.glyphIndex(0x2014).?;
            break :blk ids;
        };
        const paths = blk: {
            var out: [count][]const u8 = undefined;
            for (0..count) |i| out[i] = F.glyph_paths[glyph_ids[i]];
            break :blk out;
        };
        const advances = blk: {
            var out: [count]u16 = undefined;
            for (0..count) |i| out[i] = F.advances[glyph_ids[i]];
            break :blk out;
        };

        fn slot(ch: u8) ?usize {
            if (ch >= 32 and ch < 32 + count) return ch - 32;
            return null;
        }
    };
}

const MonoFace = Face(jetbrains_mono, false);
const UiFace = Face(inter_regular, false);

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

// Adds a glyph outline in font units (y up) with its origin at (ox, oy).
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

// Document glyphs land on whole pixels, so each is rasterized once. Cells
// start one point left of the pen, for glyphs that overhang it.
const DocFace = MonoFace;
const CELL_W: usize = @as(usize, @intCast(CHAR_W + 2)) * @as(usize, @intCast(SCALE));
const CELL_H: usize = @intCast(LINE_H * SCALE);
var doc_atlas: [95][CELL_W * CELL_H]u8 = undefined;

fn buildDocAtlas() void {
    const scale = @as(f32, @floatFromInt(CHAR_W * SCALE)) / @as(f32, @floatFromInt(DocFace.advances[0]));
    for (0..95) |g| {
        accReset(CELL_W, CELL_H);
        accPath(DocFace.paths[g], scale, SCALE_F, BASELINE * SCALE_F);
        var sum: f32 = 0;
        for (0..CELL_W * CELL_H) |i| {
            sum += acc[i];
            doc_atlas[g][i] = @intFromFloat(@round(coverageToAlpha(sum) * 255));
        }
    }
}

// Draws a document character with its pen at `x_px` frame pixels, on the
// row whose top is `y` points.
fn drawDocChar(x_px: i32, y: i32, ch: u8, c: Color) void {
    if (ch < 33 or ch > 126) return;
    const g = ch - 32;
    for (0..CELL_H) |cy| {
        for (0..CELL_W) |cx| {
            const a = doc_atlas[g][cy * CELL_W + cx];
            if (a == 0) continue;
            blendPixel(x_px - SCALE + @as(i32, @intCast(cx)), y * SCALE + @as(i32, @intCast(cy)), c, @as(f32, @floatFromInt(a)) / 255.0);
        }
    }
}

fn uiWidth(size: f32, text: []const u8) f32 {
    const scale = size / UiFace.upem;
    var w: f32 = 0;
    for (text) |ch| {
        if (UiFace.slot(ch)) |g| w += @as(f32, @floatFromInt(UiFace.advances[g])) * scale;
    }
    return w;
}

// Draws window text with its baseline at `baseline`. `weight` smears the
// outline sideways by that many pixels for a semibold look.
fn drawUiText(x_pt: f32, baseline_pt: f32, size_pt: f32, weight_pt: f32, text: []const u8, c: Color) void {
    const x = x_pt * SCALE_F;
    const baseline = baseline_pt * SCALE_F;
    const size = size_pt * SCALE_F;
    const weight = weight_pt * SCALE_F;
    const scale = size / UiFace.upem;
    const left = @floor(x) - 1;
    const top = @floor(baseline - size) - 1;
    const w: usize = @intFromFloat(@ceil(uiWidth(size_pt, text) * SCALE_F + weight) + 4);
    const h: usize = @intFromFloat(@ceil(size * 1.3) + 3);
    accReset(w, h);
    var pen = x - left;
    const by = baseline - top;
    for (text) |ch| {
        const g = UiFace.slot(ch) orelse continue;
        accPath(UiFace.paths[g], scale, pen, by);
        if (weight > 0) accPath(UiFace.paths[g], scale, pen + weight, by);
        pen += @as(f32, @floatFromInt(UiFace.advances[g])) * scale;
    }
    accBlend(@intFromFloat(left), @intFromFloat(top), c);
}

// ---------------------------------------------------------------------------
// Drawing

fn drawFrame() void {
    relayout();
    clampScroll();
    fillRect(0, 0, WIN_W, WIN_H, C_TEXT_BG);
    drawDocumentText();
    drawScrollBar();
    drawTitleBar();
    shapeWindow();
}

// ---------------------------------------------------------------------------
// Window parts

const WHITE: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const BLACK: Color = .{ 0x00, 0x00, 0x00, 0xFF };

fn mixColor(a: Color, b: Color, t_in: f32) Color {
    const t = std.math.clamp(t_in, 0, 1);
    var out: Color = .{ 0, 0, 0, 0xFF };
    for (0..3) |k| {
        const av: f32 = @floatFromInt(a[k]);
        const bv: f32 = @floatFromInt(b[k]);
        out[k] = @intFromFloat(@round(av + (bv - av) * t));
    }
    return out;
}

fn smoothstep(t_in: f32) f32 {
    const t = std.math.clamp(t_in, 0, 1);
    return t * t * (3 - 2 * t);
}

// The title bar shading, one gray level per point from the top
// border down to the dark rule under the bar.
const TITLE_SHADES = [_]u8{ 0xC0, 0xF9, 0xEF, 0xE8, 0xE6, 0xE6, 0xE6, 0xE4, 0xE3, 0xE2, 0xE0, 0xDF, 0xDD, 0xDB, 0xD9, 0xD7, 0xD6, 0xD3, 0xD1, 0xCF, 0xCC, 0xCA, 0x8C };

// Interpolates a table of shades spread evenly over `t` from 0 to 1.
fn shadeAt(comptime table: []const Color, t_in: f32) Color {
    const t = std.math.clamp(t_in, 0, 1) * @as(f32, @floatFromInt(table.len - 1));
    const i: usize = @intFromFloat(@floor(t));
    if (i + 1 >= table.len) return table[table.len - 1];
    return mixColor(table[i], table[i + 1], t - @as(f32, @floatFromInt(i)));
}

fn gray(v: u8) Color {
    return .{ v, v, v, 0xFF };
}

// A smooth gray title bar, without stripes, over a dark rule.
fn drawTitleBar() void {
    var y: i32 = 0;
    while (y < TITLE_H * SCALE) : (y += 1) {
        const pt: usize = @intCast(@divFloor(y, SCALE));
        var c = gray(TITLE_SHADES[pt]);
        // The second pixel of each point blends toward the next shade.
        if (@mod(y, SCALE) == 1 and pt > 0 and pt + 2 < TITLE_SHADES.len) {
            c = mixColor(c, gray(TITLE_SHADES[pt + 1]), 0.5);
        }
        // An inactive window's bar is paler and flatter, over the same rule.
        if (!is_focused and pt > 0 and pt + 1 < TITLE_SHADES.len) c = mixColor(c, gray(0xF0), 0.6);
        fillRectPx(0, y, PX_W, 1, c);
    }

    // Close, minimize and zoom: Tiger's own gel buttons, rebuilt at 2x from
    // its 1x pixels (tools/gen-textedit-tiger-buttons.mjs). An inactive
    // window shows the same gray gel for all three until the pointer is
    // over them.
    const b = buttons;
    const gray_lights = !is_focused and !lights_hover;
    const sprites = if (gray_lights)
        [_][]const u8{ &b.inactive, &b.inactive, &b.inactive }
    else
        [_][]const u8{ &b.close, &b.minimize, &b.zoom };
    for (sprites, 0..) |sprite, i| {
        const x0 = (b.X_PT + b.SPACING_PT * @as(i32, @intCast(i))) * SCALE;
        drawRgbaSprite(x0, b.Y_PT * SCALE, b.W, b.H, sprite);
    }
    // Pressing a button darkens its gel.
    for (0..3) |i| {
        if (lightShowsPressed(i)) fillCircleAAAlpha(lightCenterX(i), LIGHT_Y, 6.6, BLACK, 0.28);
    }
    // Unsaved changes put a dark dot in the close button, and it stays there
    // while hovering: Tiger shows the × only on a saved window. Hovering
    // shows the other buttons' glyphs either way.
    const edited = isEdited();
    if (lights_hover) drawTigerGlyphs(!edited);
    if (edited) fillCircleAA(LIGHT_X0, LIGHT_Y, 2.5, if (gray_lights) gray(0x5A) else .{ 0x3A, 0x06, 0x02, 0xFF });

    // A document that has never been saved has no proxy icon.
    const title = "Untitled";
    const size: f32 = 13;
    const x0 = @round((@as(f32, @floatFromInt(WIN_W)) - uiWidth(size, title)) / 2);
    drawUiText(x0, 16, size, 0, title, if (is_focused) BLACK else gray(0x80));
}

// Where the close button is centered, how far apart the three buttons are,
// and their radius, in points, measured from Tiger's sprites: each gel's rim
// spans 28 pixels centered 16 pixels into its sprite.
const LIGHT_X0: f32 = 15;
const LIGHT_Y: f32 = 12;
const LIGHT_SPACING: f32 = 21;
const LIGHT_R: f32 = 7;

fn lightCenterX(i: usize) f32 {
    return LIGHT_X0 + LIGHT_SPACING * @as(f32, @floatFromInt(i));
}

// The hover area spans all three buttons and the gaps between them.
fn inLightsGroup(x: i32, y: i32) bool {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    return fx >= LIGHT_X0 - LIGHT_R and fx < lightCenterX(2) + LIGHT_R and
        fy >= LIGHT_Y - LIGHT_R and fy < LIGHT_Y + LIGHT_R;
}

fn lightAt(x: i32, y: i32) ?usize {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    for (0..3) |i| {
        const dx = fx - lightCenterX(i);
        const dy = fy - LIGHT_Y;
        if (dx * dx + dy * dy <= LIGHT_R * LIGHT_R) return i;
    }
    return null;
}

fn lightShowsPressed(i: usize) bool {
    if (lights_pressed != @as(i32, @intCast(i))) return false;
    return lightAt(pointer_x, pointer_y) == i;
}

// A stroke for a Tiger glyph: from (x0, y0) to (x1, y1), in points from the
// button's center, with round ends.
const GlyphStroke = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

// Tiger's ×, − and +: round-ended strokes that sit inside the gel rather
// than on top of it. Each is one shape, so crossing strokes don't darken
// where they overlap, and it tints the gel underneath by multiplying, so the
// gel's shine and shading still show through the glyph.
fn drawTigerGlyphs(with_close: bool) void {
    const d: f32 = 2.4; // half the × diagonal's reach
    const l: f32 = 2.9; // half the − and + length, between cap centers
    const shapes = [3][]const GlyphStroke{
        &.{ .{ .x0 = -d, .y0 = -d, .x1 = d, .y1 = d }, .{ .x0 = -d, .y0 = d, .x1 = d, .y1 = -d } },
        &.{.{ .x0 = -l, .y0 = 0, .x1 = l, .y1 = 0 }},
        &.{ .{ .x0 = -l, .y0 = 0, .x1 = l, .y1 = 0 }, .{ .x0 = 0, .y0 = -l, .x1 = 0, .y1 = l } },
    };
    // What each channel of the gel is multiplied by under full coverage.
    const tints = [3][3]f32{
        .{ 0.30, 0.10, 0.08 }, // dark red
        .{ 0.42, 0.26, 0.04 }, // brown
        .{ 0.10, 0.36, 0.08 }, // dark green
    };
    const half_w: f32 = 0.8 * SCALE_F;
    for (0..3) |i| {
        if (i == 0 and !with_close) continue;
        const cx = lightCenterX(i) * SCALE_F;
        const cy = LIGHT_Y * SCALE_F;
        const reach: i32 = @intFromFloat(@ceil(4.5 * SCALE_F));
        const icx: i32 = @intFromFloat(@floor(cx));
        const icy: i32 = @intFromFloat(@floor(cy));
        var y = icy - reach;
        while (y <= icy + reach) : (y += 1) {
            var x = icx - reach;
            while (x <= icx + reach) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                var dist: f32 = std.math.floatMax(f32);
                for (shapes[i]) |s| {
                    dist = @min(dist, distToSegment(px, py, s.x0 * SCALE_F, s.y0 * SCALE_F, s.x1 * SCALE_F, s.y1 * SCALE_F));
                }
                const cov = std.math.clamp(half_w - dist + 0.5, 0, 1) * 0.9;
                if (cov <= 0 or x < 0 or y < 0 or x >= PX_W or y >= PX_H) continue;
                const idx = pixelIndex(x, y);
                for (0..3) |k| {
                    const old: f32 = @floatFromInt(output_buf[idx + k]);
                    const factor = 1 - cov * (1 - tints[i][k]);
                    output_buf[idx + k] = @intFromFloat(@round(old * factor));
                }
            }
        }
    }
}

fn distToSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    const ex = px - (ax + t * dx);
    const ey = py - (ay + t * dy);
    return @sqrt(ex * ex + ey * ey);
}

// Composites a premultiplied RGBA sprite of `w` by `h` pixels over the frame
// at (x0, y0) in pixels, so the title bar behind it shows through whatever
// its shade.
fn drawRgbaSprite(x0: i32, y0: i32, w: usize, h: usize, rgba: []const u8) void {
    for (0..h) |y| {
        for (0..w) |x| {
            const px = x0 + @as(i32, @intCast(x));
            const py = y0 + @as(i32, @intCast(y));
            if (px < 0 or py < 0 or px >= PX_W or py >= PX_H) continue;
            const src = rgba[(y * w + x) * 4 ..][0..4];
            const a: f32 = @as(f32, @floatFromInt(src[3])) / 255;
            const c = [3]f32{ @floatFromInt(src[0]), @floatFromInt(src[1]), @floatFromInt(src[2]) };
            const dst = output_buf[pixelIndex(px, py)..][0..4];
            for (0..3) |k| {
                const old: f32 = @floatFromInt(dst[k]);
                dst[k] = @intFromFloat(@round(std.math.clamp(c[k] + old * (1 - a), 0, 255)));
            }
            dst[3] = 0xFF;
        }
    }
}

fn hex(v: u24) Color {
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v), 0xFF };
}

// Tiger's scroll bar shading, one color per point column from the left
// border across, measured from the 1x window figures in Apple's 2005
// Human Interface Guidelines. The track is a recessed channel.
const TRACK_SHADES = [_]Color{ hex(0xB9BDC3), hex(0xC1C4CB), hex(0xC8CBD1), hex(0xD4D5DB), hex(0xDBDCE1), hex(0xE3E5E9), hex(0xEBECEF), hex(0xF1F2F3), hex(0xF6F6F8), hex(0xFAFAFB), hex(0xFBFBFB), hex(0xFCFCFD), hex(0xF9F9FA), hex(0xF5F5F6), hex(0xEFF0F2) };
// The arrow buttons: bright on the left, then a soft step down at the
// middle that brightens again toward the right.
const ARROW_SHADES = [_]Color{ hex(0xBCBFC6), hex(0xD3D5DA), hex(0xF3F3F5), hex(0xF8F9FA), hex(0xF9F9FA), hex(0xFAFAFB), hex(0xF6F6F8), hex(0xE1E3E6), hex(0xE7E8EC), hex(0xEDEEF0), hex(0xF5F5F6), hex(0xFCFCFD), hex(0xFEFEFE), hex(0xFAFAFB), hex(0xEFF0F2) };
// The blue thumb's body, inside its one-point rim. The thumb is banded
// across: a pale stripe on the left, a deep one just left of center, then
// brightening toward the right. Down its length the colors swing between
// these darkest and lightest values in a soft 16 point wave, fixed to the
// track so the thumb slides over still stripes.
const THUMB_DARK = [_]Color{ .{ 117, 165, 219, 0xFF }, .{ 138, 189, 230, 0xFF }, .{ 131, 187, 230, 0xFF }, .{ 122, 182, 228, 0xFF }, .{ 62, 149, 216, 0xFF }, .{ 77, 162, 223, 0xFF }, .{ 96, 177, 229, 0xFF }, .{ 115, 193, 237, 0xFF }, .{ 126, 204, 242, 0xFF }, .{ 140, 213, 245, 0xFF }, .{ 127, 205, 242, 0xFF } };
const THUMB_LIGHT = [_]Color{ .{ 123, 179, 226, 0xFF }, .{ 152, 199, 236, 0xFF }, .{ 149, 197, 235, 0xFF }, .{ 141, 193, 233, 0xFF }, .{ 85, 166, 224, 0xFF }, .{ 109, 180, 230, 0xFF }, .{ 125, 193, 236, 0xFF }, .{ 143, 208, 242, 0xFF }, .{ 158, 218, 246, 0xFF }, .{ 170, 227, 248, 0xFF }, .{ 161, 222, 247, 0xFF } };
const THUMB_WAVE_PT: f32 = 16;
// The rounded ends darken to a deep blue, shaded across like the body.
const THUMB_DEEP_L: Color = hex(0x2460B5);
const THUMB_DEEP_R: Color = hex(0x4C9CDB);
// The rim is blue on the left and underneath, dark gray on top and right.
const THUMB_RIM_BLUE: Color = hex(0x295AB1);
const THUMB_RIM_GRAY: Color = hex(0x646B70);
// An inactive window's thumb is an empty outline over a pale body.
const THUMB_INACTIVE = [_]Color{ gray(0xE3), gray(0xF6), gray(0xF6), gray(0xF6), gray(0xDB), gray(0xE7), gray(0xEF), gray(0xF7), gray(0xFF), gray(0xFF), gray(0xFF) };
const THUMB_W_PT: f32 = 13;
// The rim of the track's rounded end above the arrows.
const TRACK_END_RIM: Color = hex(0x8E949A);
const ARROW_GLYPH: Color = hex(0x4D5457);
const ARROW_GLYPH_INACTIVE: Color = hex(0x929699);

// Interpolates a table with one entry per point column, `col` points in.
fn columnShade(table: []const Color, col: f32) Color {
    const last: f32 = @floatFromInt(table.len - 1);
    const c = std.math.clamp(col - 0.5, 0, last);
    const i: usize = @intFromFloat(@floor(c));
    if (i + 1 >= table.len) return table[table.len - 1];
    return mixColor(table[i], table[i + 1], c - @as(f32, @floatFromInt(i)));
}

fn scaleColor(c: Color, f: f32) Color {
    var out: Color = c;
    for (0..3) |k| {
        const v: f32 = @floatFromInt(c[k]);
        out[k] = @intFromFloat(@round(std.math.clamp(v * f, 0, 255)));
    }
    return out;
}

// The scroll bar column. While the whole document fits it is an empty
// track; otherwise it has a thumb and both arrows together at the bottom,
// where the track ends in a rounded bowl that the up arrow wraps around.
// The grow box sits in the corner either way.
fn drawScrollBar() void {
    const left_px = (WIN_W - SCROLL_W) * SCALE;
    const left: f32 = @floatFromInt(WIN_W - SCROLL_W);
    const w = SCROLL_W * SCALE;
    const scrollable = isScrollable();
    const arrows_top = SB_ARROWS_Y;
    const arrows_top_f: f32 = @floatFromInt(arrows_top);
    const track_top = CONTENT_TOP * SCALE;
    const content_top_f: f32 = @floatFromInt(CONTENT_TOP);
    const cap_f: f32 = @floatFromInt(CONTENT_TOP + SB_CAP_H);
    const track_bottom = if (scrollable) arrows_top * SCALE else (CONTENT_BOTTOM - GROW_H) * SCALE;
    // The bowl is the end of a channel 14 points across, past the border.
    const end_r: f32 = 7;
    const end_cx: f32 = 7.5;
    const end_cy = arrows_top_f - end_r;
    // The top end mirrors it, below the cap.
    const top_cy = cap_f + end_r;

    var py = track_top;
    while (py < track_bottom) : (py += 1) {
        const fy = (@as(f32, @floatFromInt(py)) + 0.5) / SCALE_F;
        var px: i32 = 0;
        while (px < w) : (px += 1) {
            const fx = (@as(f32, @floatFromInt(px)) + 0.5) / SCALE_F;
            var c = columnShade(&TRACK_SHADES, fx);
            if (scrollable and arrows_top_f - fy < 12) {
                // The channel darkens into its rounded end, inside a rim.
                const k = 1 - 0.22 * smoothstep(1 - (arrows_top_f - fy) / 12);
                c = scaleColor(c, k);
                if (fy > end_cy) {
                    const dx = fx - end_cx;
                    const dy = fy - end_cy;
                    const d = @sqrt(dx * dx + dy * dy) - end_r;
                    const inside = mixColor(c, TRACK_END_RIM, 1 - smoothstep(-d / 2));
                    // Outside the bowl is the up button's curved top,
                    // which turns blue with the rest of it when pressed.
                    const outside = mixColor(arrowShade(fx, sb_arrow_down == -1), TRACK_END_RIM, 0.3 * (1 - smoothstep(d / 0.8)));
                    c = mixColor(outside, inside, std.math.clamp(0.5 - d * SCALE_F, 0, 1));
                }
            }
            if (scrollable and fy - cap_f < 12) {
                // The same rounded end at the top, under a cap shaded like
                // the bottom of the down arrow turned upside down.
                const k = 1 - 0.22 * smoothstep(1 - (fy - cap_f) / 12);
                c = scaleColor(c, k);
                if (fy < top_cy) {
                    const dx = fx - end_cx;
                    const dy = fy - top_cy;
                    const d = @sqrt(dx * dx + dy * dy) - end_r;
                    const inside = mixColor(c, TRACK_END_RIM, 1 - smoothstep(-d / 2));
                    // Shifted up a point: the title bar's rule is the cap's
                    // dark end, so it starts bright right under the rule.
                    const cap = gelEndShade(columnShade(&ARROW_SHADES, fx), fx, fy - content_top_f + 1);
                    const outside = mixColor(cap, TRACK_END_RIM, 0.3 * (1 - smoothstep(d / 0.8)));
                    c = mixColor(outside, inside, std.math.clamp(0.5 - d * SCALE_F, 0, 1));
                }
            }
            fillRectPx(left_px + px, py, 1, 1, c);
        }
    }

    if (scrollable) drawArrows(left, arrows_top_f);
    drawGrowBox();

    if (scrollable) {
        const thumb = thumbGeometry();
        drawThumb(left, @floatFromInt(thumb.y), @floatFromInt(thumb.h));
    }
}

// The thumb: a pill one point in from the track's left border.
fn drawThumb(left: f32, y: f32, h: f32) void {
    const x = left + 1;
    const tw = THUMB_W_PT;
    const r = tw / 2;
    const cx = x + r;
    var py: i32 = @intFromFloat(@floor((y - 1) * SCALE_F));
    const y_end: i32 = @intFromFloat(@ceil((y + h + 1) * SCALE_F));
    while (py < y_end) : (py += 1) {
        const fy = (@as(f32, @floatFromInt(py)) + 0.5) / SCALE_F;
        var px: i32 = @intFromFloat(@floor((x - 1) * SCALE_F));
        const x_end: i32 = @intFromFloat(@ceil((x + tw + 1) * SCALE_F));
        while (px < x_end) : (px += 1) {
            const fx = (@as(f32, @floatFromInt(px)) + 0.5) / SCALE_F;
            const d = roundRectDistance(fx, fy, x, y, tw, h, r);
            const nx = std.math.clamp((fx - cx) / r, -1, 1);
            const ny: f32 = if (fy < y + r) (fy - (y + r)) / r else if (fy > y + h - r) (fy - (y + h - r)) / r else 0;
            if (d >= 0) {
                // A thin shadow, heaviest on the right.
                if (d < 1) blendPixel(px, py, gray(0x40), (0.12 + 0.45 * @max(nx, 0) + 0.2 * @max(-ny, 0)) * (1 - d));
                continue;
            }
            const ex = fx - cx;
            const arc = @sqrt(@max(0, r * r - ex * ex));
            const d_top = fy - (y + r - arc);
            const d_bottom = (y + h - r + arc) - fy;
            const col = fx - left - 2;
            var c: Color = undefined;
            var rim: Color = undefined;
            const rim_t = std.math.clamp(nx - ny, 0, 1);
            if (is_focused) {
                // The wave is fixed to the track, not the thumb, so the
                // stripes stay put as the thumb slides over them.
                const u = @mod(fy - @as(f32, @floatFromInt(SB_TRACK_Y)) - 4.5, THUMB_WAVE_PT) / THUMB_WAVE_PT;
                const wave = 1 - 4 * @min(u, 1 - u);
                const body = mixColor(columnShade(&THUMB_DARK, col), columnShade(&THUMB_LIGHT, col), (wave + 1) / 2);
                const deep = mixColor(THUMB_DEEP_L, THUMB_DEEP_R, col / 10);
                c = mixColor(deep, body, smoothstep((@min(d_top, d_bottom) - 2.3) / 3));
                rim = mixColor(THUMB_RIM_BLUE, THUMB_RIM_GRAY, rim_t);
            } else {
                c = scaleColor(columnShade(&THUMB_INACTIVE, col), 1 - 0.32 * (1 - smoothstep((d_top - 2) / 4.5)));
                rim = mixColor(gray(0x96), gray(0x6A), rim_t);
            }
            c = mixColor(c, rim, std.math.clamp((d + 1) * SCALE_F + 0.5, 0, 1));
            blendPixel(px, py, c, std.math.clamp(0.5 - d * SCALE_F, 0, 1));
        }
    }
}

// Shades the rounded end of a gel `e` points in from its edge: a dark
// last point, then soft shading over a few more, deepest just left of
// center. Used at the bottom of the down arrow and, flipped, the top cap.
fn gelEndShade(c: Color, fx: f32, e: f32) Color {
    if (e <= 1) return scaleColor(c, 0.8);
    if (e >= 4) return c;
    const up = (e - 1) / 3;
    const dx = (fx - 6.5) / 1.6;
    const across = 0.3 + 0.7 * @exp(-dx * dx);
    return scaleColor(c, 1 - 0.15 * (1 - smoothstep(up)) * (1 - smoothstep(up)) * across);
}

// An arrow button's fill `fx` points across: gray gel, or blue while pressed.
fn arrowShade(fx: f32, pressed: bool) Color {
    if (pressed and fx >= 1) return mixColor(.{ 0x3A, 0x7C, 0xE0, 0xFF }, .{ 0xA8, 0xD8, 0xFF, 0xFF }, smoothstep((fx - 1) / 14));
    return columnShade(&ARROW_SHADES, fx);
}

// Both arrow buttons, `top` points down: up, a divider, then down, whose
// bottom is shaded like the rounded end of a gel.
fn drawArrows(left: f32, top: f32) void {
    const left_px: i32 = @intFromFloat(left * SCALE_F);
    const top_px: i32 = @intFromFloat(top * SCALE_F);
    const w = SCROLL_W * SCALE;
    const h = 2 * SB_ARROW_H * SCALE;
    const bottom = top + @as(f32, @floatFromInt(2 * SB_ARROW_H));
    var py: i32 = 0;
    while (py < h) : (py += 1) {
        const fy = top + (@as(f32, @floatFromInt(py)) + 0.5) / SCALE_F;
        const row = fy - top;
        const down = row >= @as(f32, @floatFromInt(SB_ARROW_H));
        const pressed = if (down) sb_arrow_down == 1 else sb_arrow_down == -1;
        var px: i32 = 0;
        while (px < w) : (px += 1) {
            const fx = (@as(f32, @floatFromInt(px)) + 0.5) / SCALE_F;
            var c = arrowShade(fx, pressed);
            if (row >= 15 and row < 16) {
                c = scaleColor(c, 0.74);
            } else {
                c = gelEndShade(c, fx, bottom - fy);
            }
            fillRectPx(left_px + px, top_px + py, 1, 1, c);
        }
    }

    const glyph_up = if (sb_arrow_down == -1) WHITE else if (is_focused) ARROW_GLYPH else ARROW_GLYPH_INACTIVE;
    const glyph_down = if (sb_arrow_down == 1) WHITE else if (is_focused) ARROW_GLYPH else ARROW_GLYPH_INACTIVE;
    const cx = left + 7.5;
    // Each triangle is about 6.7 points wide and 5.7 tall.
    fillTriangle(cx, top + 4.33, cx - 3.33, top + 10, cx + 3.33, top + 10, glyph_up);
    fillTriangle(cx - 3.33, top + 21, cx + 3.33, top + 21, cx, top + 26.67, glyph_down);
}

// Fills a triangle given in points, antialiased by 4x4 supersampling.
fn fillTriangle(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, c: Color) void {
    const x0: i32 = @intFromFloat(@floor(@min(ax, @min(bx, cx)) * SCALE_F));
    const x1: i32 = @intFromFloat(@ceil(@max(ax, @max(bx, cx)) * SCALE_F));
    const y0: i32 = @intFromFloat(@floor(@min(ay, @min(by, cy)) * SCALE_F));
    const y1: i32 = @intFromFloat(@ceil(@max(ay, @max(by, cy)) * SCALE_F));
    const area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    var py = y0;
    while (py < y1) : (py += 1) {
        var px = x0;
        while (px < x1) : (px += 1) {
            var hits: u32 = 0;
            for (0..4) |sy| {
                for (0..4) |sx| {
                    const fx = (@as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4) / SCALE_F;
                    const fy = (@as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4) / SCALE_F;
                    const e0 = ((bx - ax) * (fy - ay) - (by - ay) * (fx - ax)) * area;
                    const e1 = ((cx - bx) * (fy - by) - (cy - by) * (fx - bx)) * area;
                    const e2 = ((ax - cx) * (fy - cy) - (ay - cy) * (fx - cx)) * area;
                    if (e0 >= 0 and e1 >= 0 and e2 >= 0) hits += 1;
                }
            }
            if (hits > 0) blendPixel(px, py, c, @as(f32, @floatFromInt(hits)) / 16);
        }
    }
}

// The grow box: three diagonal ridges in the window's bottom-right corner.
fn drawGrowBox() void {
    const x0 = (WIN_W - SCROLL_W) * SCALE + 1;
    const y0 = (CONTENT_BOTTOM - GROW_H) * SCALE;
    const w = SCROLL_W * SCALE - 1;
    const h = GROW_H * SCALE;
    fillRectPx(x0, y0, w, h, .{ 0xF4, 0xF4, 0xF4, 0xFF });
    fillRectPx(x0, y0, w, 1, .{ 0x9C, 0x9C, 0x9C, 0xFF });
    const x_end = x0 + w;
    const y_end = y0 + h;
    var py = y0 + 1;
    while (py < y_end) : (py += 1) {
        var px = x0;
        while (px < x_end) : (px += 1) {
            const s = (x_end - px) + (y_end - py);
            if (s < 6 or s > 26) continue;
            const phase = @mod(s - 6, 8);
            if (phase < 2) {
                fillRectPx(px, py, 1, 1, .{ 0x86, 0x86, 0x86, 0xFF });
            } else if (phase < 4) {
                fillRectPx(px, py, 1, 1, WHITE);
            }
        }
    }
}

fn fillCircleAAAlpha(cx_pt: f32, cy_pt: f32, r_pt: f32, c: Color, alpha: f32) void {
    const cx = cx_pt * SCALE_F;
    const cy = cy_pt * SCALE_F;
    const r = r_pt * SCALE_F;
    var y: i32 = @intFromFloat(@floor(cy - r - 1));
    const y_end: i32 = @intFromFloat(@ceil(cy + r + 1));
    while (y <= y_end) : (y += 1) {
        var x: i32 = @intFromFloat(@floor(cx - r - 1));
        const x_end: i32 = @intFromFloat(@ceil(cx + r + 1));
        while (x <= x_end) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const a = std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1) * alpha;
            if (a > 0) blendPixel(x, y, c, a);
        }
    }
}

fn drawDocumentText() void {
    const sel = selectionRange();
    const has_sel = hasSelection();
    const right_edge = TEXT_X + TEXT_W;

    var row: i32 = 0;
    while (row < VIEW_ROWS) : (row += 1) {
        const ri = scroll_row + row;
        if (ri >= @as(i32, @intCast(row_count))) break;
        const r: usize = @intCast(ri);
        const rs: usize = row_start[r];
        const re: usize = row_end[r];
        const y = TEXT_Y + row * LINE_H;

        // A selection starting exactly at a soft wrap begins on the next row.
        const starts_after = sel.start > re or (sel.start == re and isSoftWrapped(r));
        if (has_sel and !starts_after and sel.end > rs) {
            const a = @max(sel.start, rs);
            const b = @min(sel.end, re);
            var x0 = textXPx(rs, a);
            var x1 = textXPx(rs, b);
            // A selection that continues past this row fills to the edge.
            if (sel.end > re) x1 = right_edge * SCALE;
            if (a == rs and r > 0 and sel.start < rs) x0 = TEXT_X * SCALE;
            if (x1 > x0) fillRectPx(x0, y * SCALE, x1 - x0, LINE_H * SCALE, if (is_focused) C_SEL else C_SEL_INACTIVE);
        }

        var x = TEXT_X * SCALE;
        var i = rs;
        while (i < re) : (i += 1) {
            const a = advPx(doc[i]);
            if (x + a > right_edge * SCALE) break;
            drawDocChar(x, y, doc[i], C_TEXT);
            x += a;
        }
    }

    if (is_focused and blink_on and !hasSelection()) drawCaret();
}

// The frame x of the gap before `idx` on the row starting at `rs`, held
// inside the text column.
fn textXPx(rs: usize, idx: usize) i32 {
    return TEXT_X * SCALE + @min(rowWidthPx(rs, idx), TEXT_W_PX);
}

fn drawCaret() void {
    const r = caretRow();
    const ri: i32 = @intCast(r);
    if (ri < scroll_row or ri >= scroll_row + VIEW_ROWS) return;
    const x = textXPx(row_start[r], caret);
    const y = TEXT_Y + (ri - scroll_row) * LINE_H;
    fillRectPx(x - 1, y * SCALE, SCALE, LINE_H * SCALE, C_CARET);
}

// Rounds the window's corners to transparency and adds a hairline frame.
fn shapeWindow() void {
    const wf: f32 = @floatFromInt(PX_W);
    const hf: f32 = @floatFromInt(PX_H);
    const radius = CORNER_R * SCALE_F;
    const band: i32 = @as(i32, @intFromFloat(radius)) + 2;
    var y: i32 = 0;
    while (y < PX_H) : (y += 1) {
        const full_row = y < band or y >= PX_H - band;
        var x: i32 = 0;
        while (x < PX_W) : (x += 1) {
            if (!full_row and x >= 2 and x < PX_W - 2) {
                x = PX_W - 3;
                continue;
            }
            // The bottom corners are square.
            const r = if (y >= @divTrunc(PX_H, 2)) 0 else radius;
            const d = roundRectDistance(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, 0, 0, wf, hf, r);
            const outer = std.math.clamp(0.5 - d, 0, 1);
            const inner = std.math.clamp(0.5 - (d + 1), 0, 1);
            if (outer >= 1 and inner >= 1) continue;
            const idx = pixelIndex(x, y);
            if (outer <= 0) {
                output_buf[idx + 3] = 0;
                continue;
            }
            const frame = (outer - inner) / outer;
            for (0..3) |k| {
                const old: f32 = @floatFromInt(output_buf[idx + k]);
                const target: f32 = @floatFromInt(C_FRAME[k]);
                output_buf[idx + k] = @intFromFloat(@round(old + (target - old) * frame));
            }
            output_buf[idx + 3] = @intFromFloat(@round(outer * 255));
        }
    }
}

fn roundRectDistance(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, r: f32) f32 {
    const qx = @abs(px - (x + w / 2)) - (w / 2 - r);
    const qy = @abs(py - (y + h / 2)) - (h / 2 - r);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
}

fn fillCircleAA(cx_pt: f32, cy_pt: f32, r_pt: f32, c: Color) void {
    const cx = cx_pt * SCALE_F;
    const cy = cy_pt * SCALE_F;
    const r = r_pt * SCALE_F;
    var y: i32 = @intFromFloat(@floor(cy - r - 1));
    const y_end: i32 = @intFromFloat(@ceil(cy + r + 1));
    while (y <= y_end) : (y += 1) {
        var x: i32 = @intFromFloat(@floor(cx - r - 1));
        const x_end: i32 = @intFromFloat(@ceil(cx + r + 1));
        while (x <= x_end) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const a = std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
            if (a > 0) blendPixel(x, y, c, a);
        }
    }
}

// Fills a rectangle given in points.
fn fillRect(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    fillRectPx(x0 * SCALE, y0 * SCALE, w * SCALE, h * SCALE, c);
}

// Fills a rectangle given in fractional points, snapped to whole pixels.
fn fillRectF(x: f32, y: f32, w: f32, h: f32, c: Color) void {
    const x0: i32 = @intFromFloat(@round(x * SCALE_F));
    const y0: i32 = @intFromFloat(@round(y * SCALE_F));
    const x1: i32 = @intFromFloat(@round((x + w) * SCALE_F));
    const y1: i32 = @intFromFloat(@round((y + h) * SCALE_F));
    fillRectPx(x0, y0, x1 - x0, y1 - y0, c);
}

fn fillRectPx(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const xa = @max(0, x0);
    const ya = @max(0, y0);
    const xb = @min(PX_W, x0 + w);
    const yb = @min(PX_H, y0 + h);
    var y = ya;
    while (y < yb) : (y += 1) {
        var x = xa;
        while (x < xb) : (x += 1) {
            const idx = pixelIndex(x, y);
            output_buf[idx..][0..4].* = c;
        }
    }
}

fn pixelIndex(x: i32, y: i32) usize {
    return (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
}

fn blendPixel(x: i32, y: i32, c: Color, a: f32) void {
    if (x < 0 or y < 0 or x >= PX_W or y >= PX_H) return;
    const idx = pixelIndex(x, y);
    const t = @min(1.0, a);
    for (0..3) |k| {
        const old: f32 = @floatFromInt(output_buf[idx + k]);
        const target: f32 = @floatFromInt(c[k]);
        output_buf[idx + k] = @intFromFloat(@round(old + (target - old) * t));
    }
    output_buf[idx + 3] = 0xFF;
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

// ---------------------------------------------------------------------------
// Tests

// Two runs of "a" that fit a row apart but not together.
const WRAP_A: usize = @divTrunc(2 * @divTrunc(TEXT_W_PX, doc_adv['a']), 3);
const WRAP_B: usize = @divTrunc(@divTrunc(TEXT_W_PX, doc_adv['a']), 2);

// A point in the left half of character `idx` of row `r`, in points.
fn pointInChar(r: usize, idx: usize) i32 {
    relayout();
    const x_px = rowWidthPx(row_start[r], idx) + @divTrunc(advPx(doc[idx]), 4);
    return TEXT_X + @divTrunc(x_px, SCALE);
}

fn loadForTest(text: []const u8) void {
    initialized = true;
    doc_len = text.len;
    @memcpy(doc[0..doc_len], text);
    caret = 0;
    anchor = 0;
    caret_upstream = false;
    scroll_row = 0;
    preferred_col = -1;
    primary_down = false;
    secondary_down = false;
    shift_down = false;
    sb_dragging = false;
    has_undo = false;
    has_redo = false;
    typing_run = false;
    change_count = 0;
    click_count = 0;
    last_primary_click_ms = -1000000;
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

test "clicking a Markdown checkbox toggles it and can be undone" {
    loadForTest("- [ ] task\n");
    defer initialized = false;
    caret = 8;
    anchor = 7;
    preferred_col = 6;

    const left_bracket_x = pointInChar(0, 2);
    const checkbox_x = pointInChar(0, 3);
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

    try std.testing.expect(undo());
    try std.testing.expectEqual(@as(u8, 'x'), doc[3]);
}

test "long lines wrap after the last space that fits" {
    // 30 + 1 + 20 characters: the second word does not fit on the first row.
    const text = "a" ** WRAP_A ++ " " ++ "a" ** WRAP_B ++ "\nnext";
    loadForTest(text);
    defer initialized = false;
    relayout();
    try std.testing.expectEqual(@as(usize, 3), row_count);
    try std.testing.expectEqual(@as(u16, 0), row_start[0]);
    try std.testing.expectEqual(@as(u16, WRAP_A + 1), row_end[0]);
    try std.testing.expectEqual(@as(u16, WRAP_A + 1), row_start[1]);
    try std.testing.expectEqual(@as(u16, WRAP_A + 1 + WRAP_B), row_end[1]);
    try std.testing.expect(isSoftWrapped(0));
    try std.testing.expect(!isSoftWrapped(1));

    // A word longer than a row breaks at the edge.
    const fit_x = @divTrunc(TEXT_W_PX, doc_adv['x']);
    loadForTest("x" ** (fit_x + 5));
    relayout();
    try std.testing.expectEqual(@as(usize, 2), row_count);
    try std.testing.expectEqual(@as(u16, fit_x), row_end[0]);
}

test "End on a wrapped row keeps the caret on that row" {
    const text = "a" ** WRAP_A ++ " " ++ "a" ** WRAP_B;
    loadForTest(text);
    defer initialized = false;
    upstream_request = false;
    moveEnd(false);
    caret_upstream = upstream_request;
    try std.testing.expectEqual(@as(usize, WRAP_A + 1), caret);
    try std.testing.expectEqual(@as(usize, 0), caretRow());
    caret_upstream = false;
    try std.testing.expectEqual(@as(usize, 1), caretRow());
}

test "Down keeps the column across wrapped rows" {
    const text = "a" ** WRAP_A ++ " " ++ "a" ** WRAP_B;
    loadForTest(text);
    defer initialized = false;
    caret = 5;
    anchor = 5;
    moveVertical(1, false);
    try std.testing.expectEqual(@as(usize, WRAP_A + 1 + 5), caret);
    moveVertical(1, false);
    try std.testing.expectEqual(doc_len, caret);
}

test "a typing run is one undo step and redo restores it" {
    loadForTest("ab");
    defer initialized = false;
    lifecycle_state = .updating;
    defer lifecycle_state = .initializing;
    caret = 2;
    anchor = 2;
    _ = key_event('c', FLAG_KEY_DOWN);
    _ = key_event('d', FLAG_KEY_DOWN);
    _ = key_event('e', FLAG_KEY_DOWN);
    try std.testing.expectEqualStrings("abcde", doc[0..doc_len]);
    _ = key_event('z', FLAG_KEY_DOWN | FLAG_META);
    try std.testing.expectEqualStrings("ab", doc[0..doc_len]);
    _ = key_event('z', FLAG_KEY_DOWN | FLAG_META | FLAG_SHIFT);
    try std.testing.expectEqualStrings("abcde", doc[0..doc_len]);

    // Moving the caret ends the run.
    _ = key_event(XK_LEFT, FLAG_KEY_DOWN);
    _ = key_event('x', FLAG_KEY_DOWN);
    _ = key_event('z', FLAG_KEY_DOWN | FLAG_META);
    try std.testing.expectEqualStrings("abcde", doc[0..doc_len]);
}

test "triple-click selects the paragraph" {
    loadForTest("one two\nthree\n");
    defer initialized = false;
    const x = pointInChar(0, 5);
    const y = TEXT_Y + 2;
    _ = pointerEventAt(BTN_PRIMARY, x, y, 10);
    _ = pointerEventAt(0, x, y, 20);
    _ = pointerEventAt(BTN_PRIMARY, x, y, 100);
    try std.testing.expectEqual(Range{ .start = 4, .end = 7 }, selectionRange());
    _ = pointerEventAt(0, x, y, 110);
    _ = pointerEventAt(BTN_PRIMARY, x, y, 200);
    try std.testing.expectEqual(Range{ .start = 0, .end = 8 }, selectionRange());
}

test "dragging the scroll bar scrolls without moving the caret" {
    var buf: [400]u8 = undefined;
    for (0..200) |i| {
        buf[i * 2] = 'x';
        buf[i * 2 + 1] = '\n';
    }
    loadForTest(&buf);
    defer initialized = false;
    const sb_x = WIN_W - 6;
    const thumb = thumbGeometry();
    _ = pointerEventAt(BTN_PRIMARY, sb_x, thumb.y + 2, 10);
    _ = pointerEventAt(BTN_PRIMARY, sb_x, CONTENT_BOTTOM + 50, 20);
    try std.testing.expectEqual(maxScroll(), scroll_row);
    try std.testing.expectEqual(@as(usize, 0), caret);
    _ = pointerEventAt(0, sb_x, CONTENT_BOTTOM + 50, 30);
    try std.testing.expect(!sb_dragging);
}

test "glyph atlas has ink for letters and none for space" {
    buildDocAtlas();
    var ink: u32 = 0;
    for (doc_atlas['g' - 32]) |a| ink += a;
    try std.testing.expect(ink > 255 * 10);
    for (doc_atlas[0]) |a| try std.testing.expectEqual(@as(u8, 0), a);
}

test "pointer events in frame pixels map to points" {
    loadForTest("one two\nthree\n");
    defer {
        initialized = false;
        lifecycle_state = .initializing;
        committed_at_ms = 0;
    }
    lifecycle_state = .ready;
    begin_update_at(10);
    // The gap after "one ".
    const x_px = TEXT_X * SCALE + rowWidthPx(0, 4) + 1;
    const y_px = (TEXT_Y + 2) * SCALE;
    _ = pointer_event(BTN_PRIMARY, x_px, y_px);
    _ = finish_update();
    try std.testing.expectEqual(@as(usize, 4), caret);
}

test "frames are twice the point size" {
    try std.testing.expectEqual(@as(usize, 2 * 375), RENDER_W);
    try std.testing.expectEqual(@as(usize, 2 * 400), RENDER_H);
    try std.testing.expectEqual(CELL_H, @as(usize, @intCast(LINE_H * 2)));
}

test "scroll arrows move one row and the track pages" {
    var buf: [400]u8 = undefined;
    for (0..200) |i| {
        buf[i * 2] = 'x';
        buf[i * 2 + 1] = '\n';
    }
    loadForTest(&buf);
    defer initialized = false;
    const sb_x = WIN_W - 7;
    const arrows_top = SB_ARROWS_Y;

    // Down arrow, then up arrow.
    _ = pointerEventAt(BTN_PRIMARY, sb_x, arrows_top + SB_ARROW_H + 4, 10);
    try std.testing.expectEqual(@as(i32, 1), scroll_row);
    try std.testing.expectEqual(@as(i32, 1), sb_arrow_down);
    _ = pointerEventAt(0, sb_x, arrows_top + SB_ARROW_H + 4, 20);
    try std.testing.expectEqual(@as(i32, 0), sb_arrow_down);
    _ = pointerEventAt(BTN_PRIMARY, sb_x, arrows_top + 4, 30);
    try std.testing.expectEqual(@as(i32, 0), scroll_row);
    _ = pointerEventAt(0, sb_x, arrows_top + 4, 40);

    // The track below the thumb pages down by a screen less one row.
    _ = pointerEventAt(BTN_PRIMARY, sb_x, arrows_top - 4, 50);
    try std.testing.expectEqual(VIEW_ROWS - 1, scroll_row);
    try std.testing.expect(!sb_dragging);
    try std.testing.expectEqual(@as(usize, 0), caret);
    _ = pointerEventAt(0, sb_x, arrows_top - 4, 60);
}

test "the thumb stays inside the track's rounded ends" {
    var buf: [400]u8 = undefined;
    for (0..200) |i| {
        buf[i * 2] = 'x';
        buf[i * 2 + 1] = '\n';
    }
    loadForTest(&buf);
    defer initialized = false;
    // At the top it sits below the cap, clear of the title bar.
    try std.testing.expectEqual(CONTENT_TOP + SB_CAP_H + 1, thumbGeometry().y);
    // At the bottom it stops a point above the bowl over the arrows.
    scroll_row = maxScroll();
    const thumb = thumbGeometry();
    try std.testing.expectEqual(SB_ARROWS_Y - 1, thumb.y + thumb.h);
}

test "the window rounds only the top corners" {
    loadForTest("hello\n");
    defer initialized = false;
    drawFrame();
    // Top-left corner pixel is transparent; bottom-left is opaque.
    try std.testing.expectEqual(@as(u8, 0), output_buf[pixelIndex(0, 0) + 3]);
    try std.testing.expectEqual(@as(u8, 0xFF), output_buf[pixelIndex(0, PX_H - 1) + 3]);
}

test "buttons sit seamlessly in the title bar" {
    const b = buttons;
    // RGBA: the sprites carry their own alpha so they composite over the
    // focused or unfocused title bar.
    try std.testing.expectEqual(b.W * b.H * 4, b.close.len);
    try std.testing.expectEqual(b.W * b.H * 4, b.minimize.len);
    try std.testing.expectEqual(b.W * b.H * 4, b.zoom.len);
    loadForTest("hello\n");
    defer initialized = false;
    drawFrame();
    // Each sprite's top row and outer columns match the title bar around
    // them, and its middle shows the button, not the bar.
    for (0..3) |i| {
        const x0 = (b.X_PT + b.SPACING_PT * @as(i32, @intCast(i))) * SCALE;
        const y0 = b.Y_PT * SCALE;
        const w: i32 = @intCast(b.W);
        const h: i32 = @intCast(b.H);
        try std.testing.expectEqualSlices(u8, output_buf[pixelIndex(x0 - 1, y0)..][0..3], output_buf[pixelIndex(x0, y0)..][0..3]);
        var y = y0;
        while (y < y0 + 8) : (y += 1) {
            try std.testing.expectEqualSlices(u8, output_buf[pixelIndex(x0 - 1, y)..][0..3], output_buf[pixelIndex(x0, y)..][0..3]);
            try std.testing.expectEqualSlices(u8, output_buf[pixelIndex(x0 + w, y)..][0..3], output_buf[pixelIndex(x0 + w - 1, y)..][0..3]);
        }
        const mid = output_buf[pixelIndex(x0 + @divTrunc(w, 2), y0 + @divTrunc(h, 2))..][0..3];
        try std.testing.expect(mid[0] != mid[1] or mid[1] != mid[2]);
    }
}

test "an inactive window draws the same gray gel for all three buttons" {
    const b = buttons;
    try std.testing.expectEqual(b.W * b.H * 4, b.inactive.len);
    loadForTest("hello\n");
    defer initialized = false;
    markSaved();
    is_focused = false;
    defer is_focused = true;
    drawFrame();
    const w: i32 = @intCast(b.W);
    const h: i32 = @intCast(b.H);
    const y0 = b.Y_PT * SCALE;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const first = output_buf[pixelIndex(b.X_PT * SCALE + x, y0 + y)..][0..3];
            // Neutral gray, not a tinted version of the colored gel.
            try std.testing.expect(first[0] == first[1] and first[1] == first[2]);
            for (1..3) |i| {
                const x0 = (b.X_PT + b.SPACING_PT * @as(i32, @intCast(i))) * SCALE;
                try std.testing.expectEqualSlices(u8, first, output_buf[pixelIndex(x0 + x, y0 + y)..][0..3]);
            }
        }
    }
}

test "hovering the traffic lights shows their glyphs" {
    loadForTest("hello\n");
    defer initialized = false;
    markSaved();
    drawFrame();
    // A point on the close glyph's cross, outside the unsaved dot.
    const cx: i32 = @as(i32, @intFromFloat(lightCenterX(0) * SCALE_F)) + 3;
    const cy: i32 = @as(i32, @intFromFloat(LIGHT_Y * SCALE_F)) + 3;
    const before = output_buf[pixelIndex(cx, cy)..][0..3].*;

    // The gap between minimize and zoom still counts as the group.
    const gap_x: i32 = @intFromFloat((lightCenterX(1) + LIGHT_SPACING / 2));
    try std.testing.expectEqual(@as(i32, 1), pointerEventAt(0, gap_x, @intFromFloat(LIGHT_Y), 10));
    try std.testing.expect(lights_hover);
    drawFrame();
    const after = output_buf[pixelIndex(cx, cy)..][0..3].*;
    try std.testing.expect(after[0] < before[0]);

    _ = pointerEventAt(0, WIN_W / 2, @intFromFloat(LIGHT_Y), 20);
    try std.testing.expect(!lights_hover);
}

test "Edited counts edits and undos, not text differences" {
    loadForTest("hello\n");
    defer initialized = false;
    try std.testing.expect(!isEdited());

    // Moving the caret doesn't count.
    _ = handleKey(XK_RIGHT, 0);
    try std.testing.expect(!isEdited());
    caret = 5;
    anchor = 5;

    // Typing then deleting leaves the same text but stays Edited.
    _ = handleKey('!', 0);
    try std.testing.expect(isEdited());
    _ = handleKey(XK_BACKSPACE, 0);
    try std.testing.expectEqualStrings("hello\n", doc[0..doc_len]);
    try std.testing.expect(isEdited());

    // Undo takes back the deletion only, so the window is still Edited.
    try std.testing.expect(undo());
    try std.testing.expectEqualStrings("hello!\n", doc[0..doc_len]);
    try std.testing.expect(isEdited());

    // A single edit followed by Undo returns to the saved state, and Redo
    // makes it Edited again.
    loadForTest("hello\n");
    _ = handleKey('a', 0);
    _ = handleKey('b', 0);
    try std.testing.expect(isEdited());
    try std.testing.expect(undo());
    try std.testing.expectEqualStrings("hello\n", doc[0..doc_len]);
    try std.testing.expect(!isEdited());
    try std.testing.expect(redo());
    try std.testing.expect(isEdited());
}

test "hovering an edited window keeps the dot in the close button" {
    loadForTest("hello\n");
    defer initialized = false;
    _ = handleKey('!', 0);
    try std.testing.expect(isEdited());
    drawFrame();
    // The close button looks the same hovered as not, and still has its dot.
    const x0: i32 = @intFromFloat((LIGHT_X0 - LIGHT_R) * SCALE_F);
    const y0: i32 = @intFromFloat((LIGHT_Y - LIGHT_R) * SCALE_F);
    const side: i32 = @intFromFloat(2 * LIGHT_R * SCALE_F);
    var before: [28 * 28 * 3]u8 = undefined;
    var n: usize = 0;
    var y = y0;
    while (y < y0 + side) : (y += 1) {
        var x = x0;
        while (x < x0 + side) : (x += 1) {
            @memcpy(before[n..][0..3], output_buf[pixelIndex(x, y)..][0..3]);
            n += 3;
        }
    }
    _ = pointerEventAt(0, @intFromFloat(lightCenterX(1)), @intFromFloat(LIGHT_Y), 10);
    try std.testing.expect(lights_hover);
    drawFrame();
    n = 0;
    y = y0;
    while (y < y0 + side) : (y += 1) {
        var x = x0;
        while (x < x0 + side) : (x += 1) {
            try std.testing.expectEqualSlices(u8, before[n..][0..3], output_buf[pixelIndex(x, y)..][0..3]);
            n += 3;
        }
    }
    const c = output_buf[pixelIndex(@intFromFloat(LIGHT_X0 * SCALE_F), @intFromFloat(LIGHT_Y * SCALE_F))..][0..3];
    try std.testing.expect(c[0] < 0x60);
}

test "pressing a traffic light darkens it and leaves the text alone" {
    loadForTest("hello\n");
    defer initialized = false;
    caret = 3;
    anchor = 3;
    const x: i32 = @intFromFloat(lightCenterX(1));
    const y: i32 = @intFromFloat(LIGHT_Y);
    _ = pointerEventAt(BTN_PRIMARY, x, y, 10);
    try std.testing.expectEqual(@as(i32, 1), lights_pressed);
    try std.testing.expect(lightShowsPressed(1));
    // Dragging off it shows it unpressed; releasing ends the press.
    _ = pointerEventAt(BTN_PRIMARY, x, TEXT_Y + 2, 20);
    try std.testing.expect(!lightShowsPressed(1));
    _ = pointerEventAt(0, x, TEXT_Y + 2, 30);
    try std.testing.expectEqual(@as(i32, -1), lights_pressed);
    try std.testing.expectEqual(@as(usize, 3), caret);
    try std.testing.expectEqual(@as(usize, 3), anchor);
}

test "pressing the title bar away from the buttons changes nothing" {
    loadForTest("hello\n");
    defer initialized = false;
    caret = 3;
    anchor = 3;
    lights_hover = false;
    needs_redraw = false;
    const x: i32 = @divTrunc(WIN_W, 2);
    const y: i32 = @divTrunc(CONTENT_TOP, 2);
    try std.testing.expectEqual(@as(i32, 0), pointerEventAt(BTN_PRIMARY, x, y, 10));
    try std.testing.expectEqual(@as(i32, 0), pointerEventAt(0, x, y, 20));
    try std.testing.expectEqual(@as(usize, 3), caret);
    try std.testing.expectEqual(@as(usize, 3), anchor);
}
