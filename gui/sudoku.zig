const ktx = @import("ktx2_rgba8_srgb");

const GRID: usize = 9;
const CELLS: usize = GRID * GRID;
const BOX: usize = 3;

const CELL_PX: usize = 54;
const BOARD_PX: usize = GRID * CELL_PX;

const OUTER_X: usize = 18;
const OUTER_TOP: usize = 18;
const OUTER_BOTTOM: usize = 18;

const BOARD_X: usize = OUTER_X;
const BOARD_Y: usize = OUTER_TOP;

const CONTROLS_GAP: usize = 24;
const CONTROLS_W: usize = 216;
const CONTROLS_X: usize = BOARD_X + BOARD_PX + CONTROLS_GAP;

const NUMBER_BUTTON_PX: usize = 56;
const NUMBER_BUTTON_GAP: usize = 8;
const NUMBER_GRID_PX: usize = NUMBER_BUTTON_PX * 3 + NUMBER_BUTTON_GAP * 2;
const NUMBER_PAD_X: usize = CONTROLS_X + (CONTROLS_W - NUMBER_GRID_PX) / 2;

const ACTION_BUTTON_H: usize = 56;
const ACTION_BUTTON_W: usize = (NUMBER_GRID_PX - NUMBER_BUTTON_GAP) / 2;
const CONTROL_GROUP_H: usize = NUMBER_GRID_PX + NUMBER_BUTTON_GAP + NUMBER_BUTTON_PX;
const NUMBER_PAD_Y: usize = BOARD_Y + (BOARD_PX - CONTROL_GROUP_H) / 2;
const CLEAR_X: usize = NUMBER_PAD_X + (NUMBER_GRID_PX - NUMBER_BUTTON_PX) / 2;
const CLEAR_Y: usize = NUMBER_PAD_Y + NUMBER_GRID_PX + NUMBER_BUTTON_GAP;
const NEW_X: usize = NUMBER_PAD_X + (NUMBER_GRID_PX - ACTION_BUTTON_W) / 2;
const NEW_Y: usize = BOARD_Y + BOARD_PX - ACTION_BUTTON_H;

const RENDER_W: usize = CONTROLS_X + CONTROLS_W + OUTER_X;
const RENDER_H: usize = OUTER_TOP + BOARD_PX + OUTER_BOTTOM;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const BTN_PRIMARY: i32 = 1 << 0;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;

const XK_KP_0: i32 = 0xFFB0;
const XK_KP_1: i32 = 0xFFB1;
const XK_KP_9: i32 = 0xFFB9;

const LARGE_SCALE: usize = 6;
const SMALL_SCALE: usize = 2;
const CANDIDATE_SLOT_PX: usize = CELL_PX / 3;

comptime {
    if (CELL_PX % 3 != 0 or CELL_PX % LARGE_SCALE != 0) {
        @compileError("Sudoku cells must align to candidate thirds and large glyph pixels");
    }
}

const Color = [4]u8;

const COLOR_BG: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const COLOR_BOARD: Color = COLOR_BG;
const COLOR_BOX_ODD: Color = COLOR_BOARD;
const COLOR_BOX_EVEN: Color = COLOR_BOARD;
const COLOR_GRID_THIN: Color = .{ 0x4A, 0x4A, 0x46, 0xFF };
const COLOR_GRID_BOLD: Color = .{ 0xF5, 0xF5, 0xF0, 0xFF };
const COLOR_SELECTED: Color = .{ 0xF2, 0xC9, 0x4C, 0xFF };
const COLOR_SELECTED_INK: Color = .{ 0x0F, 0x0F, 0x0E, 0xFF };
const COLOR_HOVER: Color = .{ 0x35, 0x2C, 0x11, 0xFF };
const COLOR_CANDIDATE_HOVER: Color = .{ 0xD2, 0xAD, 0x43, 0xFF };
const COLOR_CANDIDATE_HOVER_INK: Color = .{ 0x80, 0x6B, 0x2D, 0xFF };
const COLOR_SELECTED_CONFLICT: Color = .{ 0x78, 0x18, 0x0C, 0xFF };
const COLOR_GIVEN: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const COLOR_VALUE: Color = COLOR_SELECTED;
const COLOR_CONFLICT: Color = .{ 0xFF, 0x6B, 0x57, 0xFF };
const COLOR_CAND: Color = .{ 0xA8, 0xA8, 0xA0, 0xFF };
const COLOR_CONTROL_BG: Color = .{ 0x1C, 0x20, 0x24, 0xFF };
const COLOR_CONTROL_HOVER: Color = .{ 0x3C, 0x39, 0x2A, 0xFF };
const COLOR_CONTROL_BORDER: Color = .{ 0x82, 0x8B, 0x94, 0xFF };

const DIGIT_BITMAPS = [10][7]u8{
    .{ 0b11111, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b11111 },
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    .{ 0b11111, 0b00001, 0b00001, 0b11111, 0b10000, 0b10000, 0b11111 },
    .{ 0b11111, 0b00001, 0b00001, 0b01111, 0b00001, 0b00001, 0b11111 },
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b00001, 0b00001, 0b00001 },
    .{ 0b11111, 0b10000, 0b10000, 0b11111, 0b00001, 0b00001, 0b11111 },
    .{ 0b11111, 0b10000, 0b10000, 0b11111, 0b10001, 0b10001, 0b11111 },
    .{ 0b11111, 0b00001, 0b00001, 0b00010, 0b00100, 0b00100, 0b00100 },
    .{ 0b11111, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b11111 },
    .{ 0b11111, 0b10001, 0b10001, 0b11111, 0b00001, 0b00001, 0b11111 },
};
const X_BITMAP = [7]u8{
    0b00000,
    0b10001,
    0b01010,
    0b00100,
    0b01010,
    0b10001,
    0b00000,
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;

var givens: [CELLS]u8 = [_]u8{0} ** CELLS;
var values: [CELLS]u8 = [_]u8{0} ** CELLS;
var cands: [CELLS]u16 = [_]u16{0} ** CELLS;

var selected_idx: usize = 0;
var hovered_idx: usize = CELLS;
var hovered_candidate: usize = 0;
var hovered_control: u8 = 0;

var rng_state: u32 = 0xC13FA9A9;
var game_counter: u32 = 0;

var primary_down: bool = false;
var initialized: bool = false;
var needs_redraw: bool = true;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

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
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    if (!initialized) resetPuzzle();

    const has_shortcut_modifier = (flags & (FLAG_CTRL | FLAG_ALT | FLAG_META)) != 0;

    if (!has_shortcut_modifier and (x11_key == 0x72 or x11_key == 0x52 or x11_key == 0x6E or x11_key == 0x4E or x11_key == XK_RETURN)) {
        resetPuzzle();
        return 1;
    }

    switch (x11_key) {
        XK_LEFT => {
            moveSelection(-1, 0);
            return 1;
        },
        XK_RIGHT => {
            moveSelection(1, 0);
            return 1;
        },
        XK_UP => {
            moveSelection(0, -1);
            return 1;
        },
        XK_DOWN => {
            moveSelection(0, 1);
            return 1;
        },
        XK_BACKSPACE, XK_DELETE, 0x30, XK_KP_0 => {
            if (clearSelectedCell()) return 1;
            return 0;
        },
        else => {},
    }

    const digit = decodeDigitKey(x11_key);
    if (digit != 0) {
        const candidate_mode = (flags & (FLAG_SHIFT | FLAG_CTRL)) != 0;
        if (candidate_mode) {
            if (toggleCandidateSelectedCell(digit)) return 1;
            return 0;
        }
        if (setSelectedCellValue(digit)) return 1;
        return 0;
    }

    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if (!initialized) resetPuzzle();

    const is_primary = (button_mask & BTN_PRIMARY) != 0;

    var changed = updateHover(x_px, y_px);

    if (is_primary and !primary_down) {
        changed = handlePrimaryPress(x_px, y_px) or changed;
    }

    primary_down = is_primary;

    return if (changed) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    if (!initialized) resetPuzzle();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
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

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    if (!initialized) resetPuzzle();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return begun_at_ms;
}

fn resetState() void {
    givens = [_]u8{0} ** CELLS;
    values = [_]u8{0} ** CELLS;
    cands = [_]u16{0} ** CELLS;
    selected_idx = 0;
    hovered_idx = CELLS;
    hovered_candidate = 0;
    hovered_control = 0;
    rng_state = 0xC13FA9A9;
    game_counter = 0;
    primary_down = false;
    initialized = false;
    needs_redraw = true;
}

fn resetPuzzle() void {
    initialized = true;
    primary_down = false;
    hovered_idx = CELLS;
    hovered_candidate = 0;
    hovered_control = 0;
    game_counter +%= 1;
    rng_state +%= 0x9E3779B9 + game_counter *% 0x85EBCA6B;

    generatePuzzle();
    selectFirstEditableCell();
    needs_redraw = true;
}

fn selectFirstEditableCell() void {
    selected_idx = 0;
    while (selected_idx < CELLS and givens[selected_idx] != 0) : (selected_idx += 1) {}
    if (selected_idx == CELLS) selected_idx = 0;
}

fn generatePuzzle() void {
    var solved: [CELLS]u8 = [_]u8{0} ** CELLS;
    buildSolvedGrid(&solved);

    values = solved;
    cands = [_]u16{0} ** CELLS;

    var indices: [CELLS]u8 = undefined;
    var i: usize = 0;
    while (i < CELLS) : (i += 1) {
        indices[i] = @as(u8, @intCast(i));
    }
    shuffleU8(&indices);

    const clue_target: usize = 30 + @as(usize, @intCast(rngNext() % 9)); // 30..38 clues
    var clues_remaining: usize = CELLS;

    i = 0;
    while (i < CELLS and clues_remaining > clue_target) : (i += 1) {
        const idx: usize = @intCast(indices[i]);
        const prev = values[idx];
        values[idx] = 0;

        // Keep this removal only when the puzzle still has exactly one solution.
        if (solutionCountUpTo(values, 2) != 1) {
            values[idx] = prev;
        } else {
            clues_remaining -= 1;
        }
    }

    givens = values;
}

fn buildSolvedGrid(out: *[CELLS]u8) void {
    var digit_map: [9]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    shuffleU8(&digit_map);

    var band_order: [3]u8 = .{ 0, 1, 2 };
    var stack_order: [3]u8 = .{ 0, 1, 2 };
    shuffleU8(&band_order);
    shuffleU8(&stack_order);

    var row_order: [9]u8 = undefined;
    var col_order: [9]u8 = undefined;

    var b: usize = 0;
    while (b < 3) : (b += 1) {
        var rows_local: [3]u8 = .{ 0, 1, 2 };
        var cols_local: [3]u8 = .{ 0, 1, 2 };
        shuffleU8(&rows_local);
        shuffleU8(&cols_local);

        var k: usize = 0;
        while (k < 3) : (k += 1) {
            row_order[b * 3 + k] = band_order[b] * 3 + rows_local[k];
            col_order[b * 3 + k] = stack_order[b] * 3 + cols_local[k];
        }
    }

    var r: usize = 0;
    while (r < GRID) : (r += 1) {
        var c: usize = 0;
        while (c < GRID) : (c += 1) {
            const rr = row_order[r];
            const cc = col_order[c];
            const idx = (@as(usize, rr) * 3 + @divFloor(@as(usize, rr), 3) + @as(usize, cc)) % 9;
            out[r * GRID + c] = digit_map[idx];
        }
    }
}

fn decodeDigitKey(key: i32) u8 {
    if (key >= 0x31 and key <= 0x39) {
        return @as(u8, @intCast(key - 0x30));
    }
    if (key >= XK_KP_1 and key <= XK_KP_9) {
        return @as(u8, @intCast(key - XK_KP_0));
    }
    return 0;
}

fn moveSelection(dx: i32, dy: i32) void {
    var x: i32 = @intCast(selected_idx % GRID);
    var y: i32 = @intCast(selected_idx / GRID);

    while (true) {
        x += dx;
        y += dy;

        if (x < 0 or x >= GRID or y < 0 or y >= GRID) return;

        const xu: usize = @intCast(x);
        const yu: usize = @intCast(y);
        const next_idx: usize = yu * GRID + xu;
        if (givens[next_idx] == 0) {
            selected_idx = next_idx;
            needs_redraw = true;
            return;
        }
    }
}

fn clearSelectedCell() bool {
    if (givens[selected_idx] != 0) return false;
    const had_value = values[selected_idx] != 0;
    const had_cands = cands[selected_idx] != 0;
    values[selected_idx] = 0;
    cands[selected_idx] = 0;
    if (had_value or had_cands) {
        needs_redraw = true;
        return true;
    }
    return false;
}

fn setSelectedCellValue(digit: u8) bool {
    if (digit < 1 or digit > 9) return false;
    if (givens[selected_idx] != 0) return false;

    if (values[selected_idx] == digit and cands[selected_idx] == 0) return false;

    values[selected_idx] = digit;
    cands[selected_idx] = 0;
    needs_redraw = true;
    return true;
}

fn toggleCandidateSelectedCell(digit: u8) bool {
    if (digit < 1 or digit > 9) return false;
    if (givens[selected_idx] != 0) return false;

    values[selected_idx] = 0;

    const bit: u16 = @as(u16, 1) << @as(u4, @intCast(digit - 1));
    cands[selected_idx] ^= bit;
    needs_redraw = true;
    return true;
}

fn handlePrimaryPress(x_px: i32, y_px: i32) bool {
    const digit = numberPadDigitAt(x_px, y_px);
    if (digit != 0) return setSelectedCellValue(digit);

    if (pointInRect(x_px, y_px, CLEAR_X, CLEAR_Y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX)) {
        return clearSelectedCell();
    }

    if (pointInRect(x_px, y_px, NEW_X, NEW_Y, ACTION_BUTTON_W, ACTION_BUTTON_H)) {
        resetPuzzle();
        return true;
    }

    const maybe_hit = locateGrid(x_px, y_px);
    if (maybe_hit == null) return false;

    const hit = maybe_hit.?;
    const idx = hit.cell_idx;
    if (givens[idx] != 0) return false;

    if (idx != selected_idx) {
        selected_idx = idx;
        needs_redraw = true;
        return true;
    }

    if (values[idx] != 0) return false;

    return toggleCandidateSelectedCell(@intCast(hit.placeholder_idx + @as(usize, 1)));
}

const GridHit = struct {
    cell_idx: usize,
    placeholder_idx: usize,
};

fn locateGrid(x_px: i32, y_px: i32) ?GridHit {
    const bx: i32 = @intCast(BOARD_X);
    const by: i32 = @intCast(BOARD_Y);
    const board_px_i32: i32 = @intCast(BOARD_PX);

    if (x_px < bx or y_px < by) return null;
    if (x_px >= bx + board_px_i32 or y_px >= by + board_px_i32) return null;

    const lx_i32 = x_px - bx;
    const ly_i32 = y_px - by;

    const lx: usize = @intCast(lx_i32);
    const ly: usize = @intCast(ly_i32);

    const cx = lx / CELL_PX;
    const cy = ly / CELL_PX;

    const cell_x = lx % CELL_PX;
    const cell_y = ly % CELL_PX;
    const placeholder_x: usize = @min(cell_x / CANDIDATE_SLOT_PX, @as(usize, 2));
    const placeholder_y: usize = @min(cell_y / CANDIDATE_SLOT_PX, @as(usize, 2));
    const placeholder_idx: usize = placeholder_y * @as(usize, 3) + placeholder_x;

    return GridHit{
        .cell_idx = cy * GRID + cx,
        .placeholder_idx = placeholder_idx,
    };
}

fn numberPadDigitAt(x_px: i32, y_px: i32) u8 {
    if (!pointInRect(x_px, y_px, NUMBER_PAD_X, NUMBER_PAD_Y, NUMBER_GRID_PX, NUMBER_GRID_PX)) return 0;

    const local_x: usize = @intCast(x_px - @as(i32, @intCast(NUMBER_PAD_X)));
    const local_y: usize = @intCast(y_px - @as(i32, @intCast(NUMBER_PAD_Y)));
    const stride = NUMBER_BUTTON_PX + NUMBER_BUTTON_GAP;
    const col = local_x / stride;
    const row = local_y / stride;
    if (col >= 3 or row >= 3) return 0;
    if ((local_x % stride) >= NUMBER_BUTTON_PX or (local_y % stride) >= NUMBER_BUTTON_PX) return 0;

    return @as(u8, @intCast(row * 3 + col + 1));
}

fn pointInRect(x_px: i32, y_px: i32, x: usize, y: usize, w: usize, h: usize) bool {
    if (x_px < 0 or y_px < 0) return false;
    const px: usize = @intCast(x_px);
    const py: usize = @intCast(y_px);
    return px >= x and px < x + w and py >= y and py < y + h;
}

fn updateHover(x_px: i32, y_px: i32) bool {
    const previous_cell = visibleHoveredCell();
    const previous_candidate = visibleHoveredCandidate();
    const previous_control = visibleHoveredControl();
    const maybe_hit = locateGrid(x_px, y_px);
    hovered_idx = if (maybe_hit != null and givens[maybe_hit.?.cell_idx] == 0)
        maybe_hit.?.cell_idx
    else
        CELLS;
    hovered_candidate = if (maybe_hit != null and
        maybe_hit.?.cell_idx == selected_idx and
        givens[selected_idx] == 0 and
        values[selected_idx] == 0)
        maybe_hit.?.placeholder_idx + @as(usize, 1)
    else
        0;
    hovered_control = numberPadDigitAt(x_px, y_px);
    if (hovered_control == 0 and pointInRect(x_px, y_px, CLEAR_X, CLEAR_Y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX)) {
        hovered_control = 10;
    } else if (hovered_control == 0 and pointInRect(x_px, y_px, NEW_X, NEW_Y, ACTION_BUTTON_W, ACTION_BUTTON_H)) {
        hovered_control = 11;
    }
    return previous_cell != visibleHoveredCell() or
        previous_candidate != visibleHoveredCandidate() or
        previous_control != visibleHoveredControl();
}

fn visibleHoveredCell() usize {
    if (hovered_idx >= CELLS or hovered_idx == selected_idx) return CELLS;
    return hovered_idx;
}

fn visibleHoveredCandidate() usize {
    if (hovered_idx != selected_idx or givens[selected_idx] != 0 or values[selected_idx] != 0) return 0;
    return hovered_candidate;
}

fn visibleHoveredControl() u8 {
    if (hovered_control == values[selected_idx]) return 0;
    if (hovered_control == 10 and values[selected_idx] == 0 and cands[selected_idx] == 0) return 0;
    return hovered_control;
}

fn solutionCountUpTo(puzzle: [CELLS]u8, limit: u8) u8 {
    var grid = puzzle;
    var count: u8 = 0;
    solveCountRecursive(&grid, limit, &count);
    return count;
}

fn solveCountRecursive(grid: *[CELLS]u8, limit: u8, count: *u8) void {
    if (count.* >= limit) return;

    var best_idx: usize = 0;
    var best_mask: u16 = 0;
    var best_count: u8 = 10;
    var found_empty = false;

    var idx: usize = 0;
    while (idx < CELLS) : (idx += 1) {
        if (grid.*[idx] != 0) continue;
        found_empty = true;
        const mask = candidateMask(grid.*, idx);
        const n: u8 = @intCast(@popCount(mask));
        if (n == 0) return; // dead end
        if (n < best_count) {
            best_count = n;
            best_idx = idx;
            best_mask = mask;
            if (n == 1) break;
        }
    }

    if (!found_empty) {
        count.* += 1;
        return;
    }

    var mask = best_mask;
    while (mask != 0 and count.* < limit) {
        const bit: u16 = mask & (~mask +% 1);
        mask ^= bit;

        const digit_idx: u4 = @intCast(@ctz(bit));
        const digit: u8 = @as(u8, digit_idx) + 1;

        grid.*[best_idx] = digit;
        solveCountRecursive(grid, limit, count);
        grid.*[best_idx] = 0;
    }
}

fn candidateMask(grid: [CELLS]u8, idx: usize) u16 {
    if (grid[idx] != 0) return 0;

    const row = idx / GRID;
    const col = idx % GRID;
    var used: u16 = 0;

    var c: usize = 0;
    while (c < GRID) : (c += 1) {
        const v = grid[row * GRID + c];
        if (v != 0) {
            used |= @as(u16, 1) << @as(u4, @intCast(v - 1));
        }
    }

    var r: usize = 0;
    while (r < GRID) : (r += 1) {
        const v = grid[r * GRID + col];
        if (v != 0) {
            used |= @as(u16, 1) << @as(u4, @intCast(v - 1));
        }
    }

    const box_row = (row / BOX) * BOX;
    const box_col = (col / BOX) * BOX;
    r = 0;
    while (r < BOX) : (r += 1) {
        c = 0;
        while (c < BOX) : (c += 1) {
            const v = grid[(box_row + r) * GRID + (box_col + c)];
            if (v != 0) {
                used |= @as(u16, 1) << @as(u4, @intCast(v - 1));
            }
        }
    }

    return @as(u16, 0x01FF) & ~used;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawBoardBackground();
    drawHover();
    drawSelection();
    drawCandidateHover();
    drawGrid();
    drawValuesAndCandidates();
    drawControls();
}

fn drawHover() void {
    const idx = visibleHoveredCell();
    if (idx >= CELLS) return;
    const px = BOARD_X + (idx % GRID) * CELL_PX;
    const py = BOARD_Y + (idx / GRID) * CELL_PX;
    fillRect(px, py, CELL_PX, CELL_PX, COLOR_HOVER);
}

fn drawCandidateHover() void {
    const digit = visibleHoveredCandidate();
    if (digit < 1 or digit > 9) return;

    const pos: usize = digit - 1;
    const sx = pos % 3;
    const sy = pos / 3;
    const cell_x = BOARD_X + (selected_idx % GRID) * CELL_PX;
    const cell_y = BOARD_Y + (selected_idx / GRID) * CELL_PX;
    const slot_x = cell_x + sx * CANDIDATE_SLOT_PX;
    const slot_y = cell_y + sy * CANDIDATE_SLOT_PX;
    fillRect(slot_x, slot_y, CANDIDATE_SLOT_PX, CANDIDATE_SLOT_PX, COLOR_CANDIDATE_HOVER);

    const bit: u16 = @as(u16, 1) << @as(u4, @intCast(digit - 1));
    if ((cands[selected_idx] & bit) != 0) return;
    const gw = 5 * SMALL_SCALE;
    const gh = 7 * SMALL_SCALE;
    const x = slot_x + (CANDIDATE_SLOT_PX - gw) / 2;
    const y = slot_y + (CANDIDATE_SLOT_PX - gh) / 2;
    drawDigitGlyph(@intCast(digit), x, y, SMALL_SCALE, COLOR_CANDIDATE_HOVER_INK);
}

fn drawBoardBackground() void {
    fillRect(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX, COLOR_BOARD);

    var by: usize = 0;
    while (by < BOX) : (by += 1) {
        var bx: usize = 0;
        while (bx < BOX) : (bx += 1) {
            const color = if (((bx + by) & 1) == 0) COLOR_BOX_EVEN else COLOR_BOX_ODD;
            fillRect(
                BOARD_X + bx * CELL_PX * BOX,
                BOARD_Y + by * CELL_PX * BOX,
                CELL_PX * BOX,
                CELL_PX * BOX,
                color,
            );
        }
    }
}

fn drawSelection() void {
    const sx = selected_idx % GRID;
    const sy = selected_idx / GRID;
    const px = BOARD_X + sx * CELL_PX;
    const py = BOARD_Y + sy * CELL_PX;
    fillRect(px, py, CELL_PX, CELL_PX, COLOR_SELECTED);
}

fn drawGrid() void {
    var i: usize = 0;
    while (i <= GRID) : (i += 1) {
        const is_bold = (i % BOX) == 0;
        const color = if (is_bold) COLOR_GRID_BOLD else COLOR_GRID_THIN;

        const x = BOARD_X + i * CELL_PX;
        const y = BOARD_Y + i * CELL_PX;

        const thickness: usize = if (is_bold) 2 else 1;
        fillRect(x, BOARD_Y, thickness, BOARD_PX + 1, color);
        fillRect(BOARD_X, y, BOARD_PX + 1, thickness, color);
    }
}

fn drawValuesAndCandidates() void {
    var idx: usize = 0;
    while (idx < CELLS) : (idx += 1) {
        const v = values[idx];
        const x = idx % GRID;
        const y = idx / GRID;
        const px = BOARD_X + x * CELL_PX;
        const py = BOARD_Y + y * CELL_PX;

        if (v != 0) {
            const is_given = givens[idx] != 0;
            const is_selected = idx == selected_idx;
            const color = if (isConflictAt(idx))
                if (is_selected) COLOR_SELECTED_CONFLICT else COLOR_CONFLICT
            else if (is_selected)
                COLOR_SELECTED_INK
            else if (is_given)
                COLOR_GIVEN
            else
                COLOR_VALUE;
            drawLargeDigit(v, px, py, color);
        } else {
            const color = if (idx == selected_idx) COLOR_SELECTED_INK else COLOR_CAND;
            drawCandidateDigits(cands[idx], px, py, color);
        }
    }
}

fn drawLargeDigit(digit: u8, cell_x: usize, cell_y: usize, color: Color) void {
    const gw = 5 * LARGE_SCALE;
    const gh = 7 * LARGE_SCALE;
    const x = cell_x + (CELL_PX - gw) / 2;
    const y = cell_y + (CELL_PX - gh) / 2;
    drawDigitGlyph(digit, x, y, LARGE_SCALE, color);
}

fn drawCandidateDigits(mask: u16, cell_x: usize, cell_y: usize, color: Color) void {
    if (mask == 0) return;

    const gw = 5 * SMALL_SCALE;
    const gh = 7 * SMALL_SCALE;
    var d: u8 = 1;
    while (d <= 9) : (d += 1) {
        const bit: u16 = @as(u16, 1) << @as(u4, @intCast(d - 1));
        if ((mask & bit) == 0) continue;

        const pos: usize = d - 1;
        const sx = pos % 3;
        const sy = pos / 3;

        const x = cell_x + sx * CANDIDATE_SLOT_PX + (CANDIDATE_SLOT_PX - gw) / 2;
        const y = cell_y + sy * CANDIDATE_SLOT_PX + (CANDIDATE_SLOT_PX - gh) / 2;

        drawDigitGlyph(d, x, y, SMALL_SCALE, color);
    }
}

fn drawControls() void {
    const editable = givens[selected_idx] == 0;
    const selected_value = values[selected_idx];

    var digit: u8 = 1;
    while (digit <= 9) : (digit += 1) {
        const pos: usize = digit - 1;
        const col = pos % 3;
        const row = pos / 3;
        const x = NUMBER_PAD_X + col * (NUMBER_BUTTON_PX + NUMBER_BUTTON_GAP);
        const y = NUMBER_PAD_Y + row * (NUMBER_BUTTON_PX + NUMBER_BUTTON_GAP);
        const active = selected_value == digit;
        const hovered = visibleHoveredControl() == digit;
        const border = if (active) COLOR_SELECTED else if (editable) COLOR_CONTROL_BORDER else COLOR_GRID_THIN;
        const fill = if (active) COLOR_SELECTED else if (hovered) COLOR_CONTROL_HOVER else COLOR_CONTROL_BG;
        const ink = if (active) COLOR_SELECTED_INK else if (editable) COLOR_GIVEN else COLOR_GRID_THIN;

        fillRect(x, y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX, fill);
        drawRectOutline(x, y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX, 2, border);
        drawLargeDigit(digit, x, y, ink);
    }

    const clear_active = editable and values[selected_idx] == 0 and cands[selected_idx] == 0;
    const clear_hovered = visibleHoveredControl() == 10;
    const clear_fill = if (clear_active) COLOR_SELECTED else if (clear_hovered) COLOR_CONTROL_HOVER else COLOR_CONTROL_BG;
    const clear_border = if (clear_active) COLOR_SELECTED else COLOR_CONTROL_BORDER;
    const clear_ink = if (clear_active) COLOR_SELECTED_INK else COLOR_GIVEN;
    fillRect(CLEAR_X, CLEAR_Y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX, clear_fill);
    drawRectOutline(CLEAR_X, CLEAR_Y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX, 2, clear_border);
    drawXIcon(CLEAR_X, CLEAR_Y, NUMBER_BUTTON_PX, NUMBER_BUTTON_PX, clear_ink);

    drawActionButton(NEW_X, NEW_Y, visibleHoveredControl() == 11);
    drawDiceIcon(NEW_X, NEW_Y, ACTION_BUTTON_W, ACTION_BUTTON_H, COLOR_GIVEN);
}

fn drawActionButton(x: usize, y: usize, hovered: bool) void {
    const fill = if (hovered) COLOR_CONTROL_HOVER else COLOR_CONTROL_BG;
    fillRect(x, y, ACTION_BUTTON_W, ACTION_BUTTON_H, fill);
    drawRectOutline(x, y, ACTION_BUTTON_W, ACTION_BUTTON_H, 2, COLOR_CONTROL_BORDER);
}

fn drawXIcon(button_x: usize, button_y: usize, button_w: usize, button_h: usize, color: Color) void {
    const glyph_w = 5 * LARGE_SCALE;
    const glyph_h = 7 * LARGE_SCALE;
    const x0 = button_x + (button_w - glyph_w) / 2;
    const y0 = button_y + (button_h - glyph_h) / 2;
    drawBitmapGlyph(X_BITMAP, x0, y0, LARGE_SCALE, color);
}

fn drawDiceIcon(button_x: usize, button_y: usize, button_w: usize, button_h: usize, color: Color) void {
    const size: usize = 28;
    const x0 = button_x + (button_w - size) / 2;
    const y0 = button_y + (button_h - size) / 2;
    drawRectOutline(x0, y0, size, size, 2, color);
    fillRect(x0 + 6, y0 + 6, 4, 4, color);
    fillRect(x0 + size - 10, y0 + 6, 4, 4, color);
    fillRect(x0 + (size - 4) / 2, y0 + (size - 4) / 2, 4, 4, color);
    fillRect(x0 + 6, y0 + size - 10, 4, 4, color);
    fillRect(x0 + size - 10, y0 + size - 10, 4, 4, color);
}

fn drawDigitGlyph(digit: u8, x0: usize, y0: usize, scale: usize, color: Color) void {
    if (digit < 1 or digit > 9) return;
    drawBitmapGlyph(DIGIT_BITMAPS[digit], x0, y0, scale, color);
}

fn drawBitmapGlyph(glyph: [7]u8, x0: usize, y0: usize, scale: usize, color: Color) void {
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const bit = 4 - col;
            if (((glyph[row] >> @as(u3, @intCast(bit))) & 1) == 0) continue;
            fillRect(x0 + col * scale, y0 + row * scale, scale, scale, color);
        }
    }
}

fn isConflictAt(idx: usize) bool {
    const v = values[idx];
    if (v == 0) return false;

    const x = idx % GRID;
    const y = idx / GRID;

    var c: usize = 0;
    while (c < GRID) : (c += 1) {
        if (c == x) continue;
        if (values[y * GRID + c] == v) return true;
    }

    var r: usize = 0;
    while (r < GRID) : (r += 1) {
        if (r == y) continue;
        if (values[r * GRID + x] == v) return true;
    }

    const box_x = (x / BOX) * BOX;
    const box_y = (y / BOX) * BOX;

    r = 0;
    while (r < BOX) : (r += 1) {
        c = 0;
        while (c < BOX) : (c += 1) {
            const xx = box_x + c;
            const yy = box_y + r;
            const peer_idx = yy * GRID + xx;
            if (peer_idx == idx) continue;
            if (values[peer_idx] == v) return true;
        }
    }

    return false;
}

fn setPixel(x: usize, y: usize, color: Color) void {
    if (x >= RENDER_W or y >= RENDER_H) return;
    const off = (y * RENDER_W + x) * 4;
    pixel_buf[off + 0] = color[0];
    pixel_buf[off + 1] = color[1];
    pixel_buf[off + 2] = color[2];
    pixel_buf[off + 3] = color[3];
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, color: Color) void {
    if (w == 0 or h == 0) return;
    const x1 = @min(x + w, RENDER_W);
    const y1 = @min(y + h, RENDER_H);

    var yy = y;
    while (yy < y1) : (yy += 1) {
        var xx = x;
        while (xx < x1) : (xx += 1) {
            setPixel(xx, yy, color);
        }
    }
}

fn drawRectOutline(x: usize, y: usize, w: usize, h: usize, thickness: usize, color: Color) void {
    fillRect(x, y, w, thickness, color);
    fillRect(x, y + h - thickness, w, thickness, color);
    fillRect(x, y, thickness, h, color);
    fillRect(x + w - thickness, y, thickness, h, color);
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn shuffleU8(arr: anytype) void {
    const T = @TypeOf(arr.*);
    const info = @typeInfo(T);
    comptime {
        if (info != .array or info.array.child != u8) {
            @compileError("shuffleU8 expects *[N]u8");
        }
    }

    const len = info.array.len;
    if (len <= 1) return;

    var i: usize = len - 1;
    while (i > 0) : (i -= 1) {
        const j = @as(usize, @intCast(rngNext() % @as(u32, @intCast(i + 1))));
        const tmp = arr.*[i];
        arr.*[i] = arr.*[j];
        arr.*[j] = tmp;
    }
}
