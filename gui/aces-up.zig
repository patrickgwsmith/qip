const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const NUM_CARDS: usize = 52;
const NUM_PILES: usize = 4;
const MAX_PILE: usize = 52;

const CARD_W: usize = 68;
const CARD_H: usize = 96;
const STACK_DY: usize = 18;
const DEAL_STEP_MS: i64 = 75;

const PAD_X: usize = 16;
const PAD_Y: usize = 16;
const GAP_X: usize = 18;
const SIDE_W: usize = CARD_W + 28;

const BOARD_W: usize = NUM_PILES * CARD_W + (NUM_PILES - 1) * GAP_X;
const BOARD_H: usize = CARD_H + (13 - 1) * STACK_DY;

const RENDER_W: usize = PAD_X * 3 + BOARD_W + SIDE_W;
const RENDER_H: usize = PAD_Y * 2 + BOARD_H + 20;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const SIDE_X: usize = PAD_X * 2 + BOARD_W;
const DECK_X: usize = SIDE_X + @divFloor(SIDE_W - CARD_W, 2);
const DECK_Y: usize = PAD_Y;
const DISCARD_X: usize = DECK_X;
const DISCARD_Y: usize = DECK_Y + CARD_H + 26;

const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_RETURN: i32 = 0xFF0D;

const STATE_PLAYING: u8 = 0;
const STATE_WIN: u8 = 1;
const STATE_LOSS: u8 = 2;

const Color = [4]u8;
const COLOR_BG: Color = .{ 0x0D, 0x5A, 0x32, 0xFF };
const COLOR_SLOT: Color = .{ 0x16, 0x6B, 0x40, 0xFF };
const COLOR_SLOT_EDGE: Color = .{ 0x0A, 0x3B, 0x20, 0xFF };
const COLOR_CARD: Color = .{ 0xF9, 0xFB, 0xFF, 0xFF };
const COLOR_CARD_EDGE: Color = .{ 0x23, 0x2D, 0x38, 0xFF };
const COLOR_RED: Color = .{ 0xB8, 0x18, 0x2A, 0xFF };
const COLOR_BLACK: Color = .{ 0x12, 0x1A, 0x22, 0xFF };
const COLOR_SELECT: Color = .{ 0xFF, 0xCF, 0x44, 0xFF };
const COLOR_DISCARDABLE: Color = .{ 0x6E, 0xC1, 0xF4, 0xFF };
const COLOR_OVERLAY: Color = .{ 0x10, 0x15, 0x1D, 0xCC };
const COLOR_PANEL: Color = .{ 0xF2, 0xF6, 0xFA, 0xFF };
const COLOR_WIN: Color = .{ 0xF2, 0xC2, 0x1C, 0xFF };
const COLOR_LOSS: Color = .{ 0x7A, 0x8B, 0x9C, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;

var deck: [NUM_CARDS]u8 = undefined;
var deck_pos: usize = 0;
var rng_state: u32 = 0x9E3779B9;
var game_count: u32 = 0;

var piles: [NUM_PILES][MAX_PILE]u8 = undefined;
var pile_lens: [NUM_PILES]u8 = [_]u8{0} ** NUM_PILES;
var discard_count: u8 = 0;

var selected_pile: i32 = -1;
var primary_down: bool = false;
var game_state: u8 = STATE_PLAYING;
var needs_redraw: bool = true;
var initialized: bool = false;
var dealing: bool = false;
var deal_next_pile: u8 = 0;
var deal_next_ms: i64 = 0;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var next_wake_at_ms: i64 = 0;

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
    if (transaction_phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    next_wake_at_ms = now_ms;
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;

    if (x11_key == 0x72 or x11_key == 0x52) {
        resetGame();
        return 1;
    }

    if (x11_key == XK_RETURN or x11_key == 0x20) {
        if (tryDealRow()) return 1;
    }
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const is_down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    if (is_down and !primary_down) {
        changed = handlePrimaryPress(x_px, y_px);
    }

    primary_down = is_down;
    return if (changed) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (!initialized) {
        resetGame();
    }
    if (dealing) {
        stepDeal(begun_at_ms);
    }
    next_wake_at_ms = if (dealing) deal_next_ms else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    if (!initialized) {
        resetGame();
        if (dealing) stepDeal(0);
    }
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    transaction_phase = .ready;
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
    if (transaction_phase != .updating) @trap();
    advanceTransactionTime();
    next_wake_at_ms = if (dealing) deal_next_ms else begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn resetState() void {
    deck = [_]u8{0} ** NUM_CARDS;
    deck_pos = 0;
    rng_state = 0x9E3779B9;
    game_count = 0;
    piles = [_][MAX_PILE]u8{[_]u8{0} ** MAX_PILE} ** NUM_PILES;
    pile_lens = [_]u8{0} ** NUM_PILES;
    discard_count = 0;
    selected_pile = -1;
    primary_down = false;
    game_state = STATE_PLAYING;
    needs_redraw = true;
    initialized = false;
    dealing = false;
    deal_next_pile = 0;
    deal_next_ms = 0;
}

fn resetGame() void {
    initialized = true;
    game_count +%= 1;
    rng_state +%= 0xA341316C + game_count *% 0xC8013EA4;

    var i: usize = 0;
    while (i < NUM_CARDS) : (i += 1) {
        deck[i] = @intCast(i);
    }
    shuffleDeck();
    deck_pos = 0;

    pile_lens = [_]u8{0} ** NUM_PILES;
    discard_count = 0;
    selected_pile = -1;
    primary_down = false;
    game_state = STATE_PLAYING;
    dealing = false;
    deal_next_pile = 0;
    deal_next_ms = 0;

    _ = startDealRow(true);
    needs_redraw = true;
}

fn shuffleDeck() void {
    var i: usize = NUM_CARDS - 1;
    while (i > 0) : (i -= 1) {
        const j = @as(usize, @intCast(rngNext() % @as(u32, @intCast(i + 1))));
        const t = deck[i];
        deck[i] = deck[j];
        deck[j] = t;
    }
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn startDealRow(force: bool) bool {
    if (dealing) return false;
    if (!force and !canDealRow()) return false;
    selected_pile = -1;
    dealing = true;
    deal_next_pile = 0;
    deal_next_ms = 0;
    needs_redraw = true;
    return true;
}

fn tryDealRow() bool {
    if (game_state != STATE_PLAYING) {
        resetGame();
        return true;
    }
    return startDealRow(false);
}

fn canDealRow() bool {
    if (deck_pos + NUM_PILES > NUM_CARDS) return false;
    if (hasEmptyPile()) return false;
    if (hasDiscardableMoves()) return false;
    return true;
}

fn stepDeal(now_ms: i64) void {
    if (!dealing) return;
    if (deal_next_ms == 0) {
        deal_next_ms = now_ms;
    }

    if (now_ms < deal_next_ms) return;
    if (deal_next_pile >= NUM_PILES or deck_pos >= NUM_CARDS) {
        dealing = false;
        updateGameState();
        return;
    }

    const pile_idx: usize = @intCast(deal_next_pile);
    const c = deck[deck_pos];
    deck_pos += 1;
    pushCard(pile_idx, c);
    deal_next_pile += 1;
    needs_redraw = true;
    deal_next_ms = now_ms + DEAL_STEP_MS;

    if (deal_next_pile >= NUM_PILES) {
        dealing = false;
        updateGameState();
    }
}

fn pushCard(pile_idx: usize, card: u8) void {
    const n = pile_lens[pile_idx];
    piles[pile_idx][n] = card;
    pile_lens[pile_idx] = n + 1;
}

fn popCard(pile_idx: usize) u8 {
    const n = pile_lens[pile_idx] - 1;
    pile_lens[pile_idx] = n;
    return piles[pile_idx][n];
}

fn topCard(pile_idx: usize) ?u8 {
    const n = pile_lens[pile_idx];
    if (n == 0) return null;
    return piles[pile_idx][n - 1];
}

fn handlePrimaryPress(x_px: i32, y_px: i32) bool {
    if (game_state != STATE_PLAYING) {
        resetGame();
        return true;
    }
    if (dealing) return false;

    if (pointInRect(x_px, y_px, @intCast(DECK_X), @intCast(DECK_Y), @intCast(CARD_W), @intCast(CARD_H))) {
        return tryDealRow();
    }

    const maybe_pile = pileAtPoint(x_px, y_px);
    if (maybe_pile == null) {
        return false;
    }
    const pile = maybe_pile.?;

    if (selected_pile >= 0) {
        const src: usize = @intCast(selected_pile);
        if (pile == src) {
            selected_pile = -1;
            needs_redraw = true;
            return true;
        }
        if (pile_lens[pile] == 0 and pile_lens[src] > 0) {
            const c = popCard(src);
            pushCard(pile, c);
            selected_pile = -1;
            updateGameState();
            needs_redraw = true;
            return true;
        }
        if (pile_lens[pile] > 0) {
            selected_pile = @intCast(pile);
            needs_redraw = true;
            return true;
        }
    }

    if (pile_lens[pile] == 0) {
        return false;
    }

    if (isDiscardable(pile)) {
        _ = popCard(pile);
        discard_count +%= 1;
        selected_pile = -1;
        updateGameState();
        needs_redraw = true;
        return true;
    }

    if (hasEmptyPile()) {
        selected_pile = @intCast(pile);
        needs_redraw = true;
        return true;
    }

    return false;
}

fn updateGameState() void {
    if (isWin()) {
        game_state = STATE_WIN;
        return;
    }
    if (deck_pos >= NUM_CARDS and !hasDiscardableMoves() and !hasEmptyPile()) {
        game_state = STATE_LOSS;
        return;
    }
    game_state = STATE_PLAYING;
}

fn isWin() bool {
    if (deck_pos < NUM_CARDS) return false;
    if (totalCardsInPiles() != 4) return false;

    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        const c = topCard(i) orelse return false;
        if (rankOf(c) != 1) return false;
    }
    return true;
}

fn totalCardsInPiles() usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        total += pile_lens[i];
    }
    return total;
}

fn allPilesOccupied() bool {
    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        if (pile_lens[i] == 0) return false;
    }
    return true;
}

fn hasEmptyPile() bool {
    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        if (pile_lens[i] == 0) return true;
    }
    return false;
}

fn hasDiscardableMoves() bool {
    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        if (isDiscardable(i)) return true;
    }
    return false;
}

fn isDiscardable(pile_idx: usize) bool {
    const card = topCard(pile_idx) orelse return false;
    const suit = suitOf(card);
    const rank = rankOf(card);

    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        if (i == pile_idx) continue;
        const other = topCard(i) orelse continue;
        if (suitOf(other) == suit and rankOf(other) > rank) {
            return true;
        }
    }
    return false;
}

fn pileAtPoint(x_px: i32, y_px: i32) ?usize {
    const by: i32 = @intCast(PAD_Y);
    if (y_px < by) return null;

    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        const x0: i32 = @intCast(pileX(i));
        const x1: i32 = @intCast(pileX(i) + CARD_W);
        if (x_px < x0 or x_px >= x1) continue;

        const len = pile_lens[i];
        const pile_h: i32 = if (len == 0) @intCast(CARD_H) else @intCast(CARD_H + (@as(usize, len - 1) * STACK_DY));
        const y0 = by;
        const y1 = by + pile_h;
        if (y_px >= y0 and y_px < y1) return i;
    }

    return null;
}

fn pileX(i: usize) usize {
    return PAD_X + i * (CARD_W + GAP_X);
}

fn rankOf(card: u8) u8 {
    const raw = (card % 13) + 1;
    // Aces Up is "Aces high": A > K > Q ... > 2.
    return if (raw == 1) 14 else raw;
}

fn suitOf(card: u8) u8 {
    return card / 13;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawDeckArea();
    drawPiles();
    if (game_state != STATE_PLAYING) {
        drawEndOverlay();
    }
}

fn drawDeckArea() void {
    fillRect(SIDE_X, 0, RENDER_W - SIDE_X, RENDER_H, COLOR_SLOT_EDGE);

    drawCardSlot(DECK_X, DECK_Y);
    drawCardSlot(DISCARD_X, DISCARD_Y);

    const remain = NUM_CARDS - deck_pos;
    if (remain > 0) {
        var layers = @min(@divFloor(remain + 2, 3), 8);
        while (layers > 0) : (layers -= 1) {
            const dx = layers - 1;
            const dy = @divFloor(layers - 1, 2);
            drawCardBack(DECK_X + dx, DECK_Y + dy);
        }
    }

    const dcount: usize = @intCast(discard_count);
    if (dcount > 0) {
        var dlayers = @min(@divFloor(dcount + 1, 2), 8);
        while (dlayers > 0) : (dlayers -= 1) {
            const dx = dlayers - 1;
            const dy = @divFloor(dlayers - 1, 2);
            drawCardBack(DISCARD_X + dx, DISCARD_Y + dy);
        }
    }

    if (dealing and deal_next_pile < NUM_PILES and deck_pos > 0) {
        const target_x = pileX(@intCast(deal_next_pile));
        const target_y = PAD_Y + (@as(usize, pile_lens[@intCast(deal_next_pile)]) * STACK_DY);
        const mid_x = @divFloor(DECK_X + target_x, 2);
        const mid_y = @divFloor(DECK_Y + target_y, 2);
        drawCardBack(mid_x, mid_y);
    }

    if (game_state == STATE_PLAYING and canDealRow()) {
        drawRectStroke(DECK_X, DECK_Y, CARD_W, CARD_H, 3, COLOR_SELECT);
    }
}

fn drawPiles() void {
    var i: usize = 0;
    while (i < NUM_PILES) : (i += 1) {
        const x = pileX(i);
        const y = PAD_Y;
        drawCardSlot(x, y);

        const len = pile_lens[i];
        var n: usize = 0;
        while (n < len) : (n += 1) {
            const card = piles[i][n];
            const cy = y + n * STACK_DY;
            drawCard(x, cy, card);
        }

        if (len > 0 and isDiscardable(i)) {
            const top_y = y + (len - 1) * STACK_DY;
            drawRectStroke(x + 2, top_y + 2, CARD_W - 4, CARD_H - 4, 2, COLOR_DISCARDABLE);
        }

        if (selected_pile >= 0 and @as(usize, @intCast(selected_pile)) == i) {
            const sy = if (len == 0) y else y + (len - 1) * STACK_DY;
            drawRectStroke(x, sy, CARD_W, CARD_H, 3, COLOR_SELECT);
        }
    }
}

fn drawCardSlot(x: usize, y: usize) void {
    fillRect(x, y, CARD_W, CARD_H, COLOR_SLOT);
    drawRectStroke(x, y, CARD_W, CARD_H, 2, COLOR_SLOT_EDGE);
}

fn drawCard(x: usize, y: usize, card: u8) void {
    fillRect(x, y, CARD_W, CARD_H, COLOR_CARD);
    drawRectStroke(x, y, CARD_W, CARD_H, 2, COLOR_CARD_EDGE);

    const rank = rankOf(card);
    const suit = suitOf(card);
    const ink = if (suit == 1 or suit == 2) COLOR_RED else COLOR_BLACK;

    var label: [2]u8 = undefined;
    const label_len = rankLabel(rank, &label);
    drawText5x7(x + 6, y + 7, label[0..label_len], ink, 2);
    drawSuitIcon(@intCast(x + 14), @intCast(y + 29), 8, suit, ink);
    drawSuitIcon(@intCast(x + CARD_W / 2), @intCast(y + CARD_H / 2 + 4), 15, suit, ink);
}

fn drawCardBack(x: usize, y: usize) void {
    const back_a: Color = .{ 0x27, 0x4D, 0x8A, 0xFF };
    const back_b: Color = .{ 0x5C, 0x8A, 0xD6, 0xFF };
    fillRect(x, y, CARD_W, CARD_H, back_a);
    drawRectStroke(x, y, CARD_W, CARD_H, 2, COLOR_CARD_EDGE);

    var yy: usize = 6;
    while (yy + 6 < CARD_H) : (yy += 12) {
        fillRect(x + 6, y + yy, CARD_W - 12, 2, back_b);
    }
}

fn drawEndOverlay() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_OVERLAY);

    const panel_w: usize = 210;
    const panel_h: usize = 150;
    const px = (RENDER_W - panel_w) / 2;
    const py = (RENDER_H - panel_h) / 2;
    fillRect(px, py, panel_w, panel_h, COLOR_PANEL);

    const accent = if (game_state == STATE_WIN) COLOR_WIN else COLOR_LOSS;
    drawRectStroke(px, py, panel_w, panel_h, 6, accent);

    if (game_state == STATE_WIN) {
        drawSuitIcon(@intCast(px + 50), @intCast(py + 60), 18, 0, COLOR_BLACK);
        drawSuitIcon(@intCast(px + 85), @intCast(py + 60), 18, 1, COLOR_RED);
        drawSuitIcon(@intCast(px + 120), @intCast(py + 60), 18, 2, COLOR_RED);
        drawSuitIcon(@intCast(px + 155), @intCast(py + 60), 18, 3, COLOR_BLACK);
    } else {
        drawSuitIcon(@intCast(px + 78), @intCast(py + 60), 20, 2, COLOR_RED);
        drawSuitIcon(@intCast(px + 132), @intCast(py + 60), 20, 3, COLOR_BLACK);
    }

    fillRect(px + 82, py + 115, 10, 10, accent);
    fillRect(px + 118, py + 115, 10, 10, accent);
}

fn rankLabel(rank: u8, out: *[2]u8) usize {
    return switch (rank) {
        1 => blk: {
            out[0] = 'A';
            break :blk 1;
        },
        2...9 => blk: {
            out[0] = @as(u8, '0') + rank;
            break :blk 1;
        },
        10 => blk: {
            out[0] = '1';
            out[1] = '0';
            break :blk 2;
        },
        11 => blk: {
            out[0] = 'J';
            break :blk 1;
        },
        12 => blk: {
            out[0] = 'Q';
            break :blk 1;
        },
        13 => blk: {
            out[0] = 'K';
            break :blk 1;
        },
        else => blk: {
            out[0] = '?';
            break :blk 1;
        },
    };
}

fn drawSuitIcon(cx: i32, cy: i32, r: i32, suit: u8, color: Color) void {
    switch (suit) {
        0 => drawClub(cx, cy, r, color),
        1 => drawDiamond(cx, cy, r, color),
        2 => drawHeart(cx, cy, r, color),
        else => drawSpade(cx, cy, r, color),
    }
}

fn drawHeart(cx: i32, cy: i32, r: i32, color: Color) void {
    const d = @divFloor(r, 2);
    drawFilledCircle(cx - d, cy - d, d, color);
    drawFilledCircle(cx + d, cy - d, d, color);
    var y: i32 = 0;
    while (y <= r) : (y += 1) {
        const half = @divFloor((r - y) * 2, 3);
        drawHLine(cx - half, cx + half, cy + y - d, color);
    }
}

fn drawDiamond(cx: i32, cy: i32, r: i32, color: Color) void {
    var y: i32 = -r;
    while (y <= r) : (y += 1) {
        const half = r - absI32(y);
        drawHLine(cx - half, cx + half, cy + y, color);
    }
}

fn drawClub(cx: i32, cy: i32, r: i32, color: Color) void {
    const d = @divFloor(r * 2, 3);
    const c = @divFloor(r, 2);
    drawFilledCircle(cx, cy - c, d, color);
    drawFilledCircle(cx - d, cy + c, d, color);
    drawFilledCircle(cx + d, cy + c, d, color);
    fillRectI32(cx - @divFloor(r, 4), cy + c, @divFloor(r, 2), r + 1, color);
}

fn drawSpade(cx: i32, cy: i32, r: i32, color: Color) void {
    const d = @divFloor(r, 2);
    drawFilledCircle(cx - d, cy - d, d, color);
    drawFilledCircle(cx + d, cy - d, d, color);
    var y: i32 = 0;
    while (y <= r) : (y += 1) {
        const half = @divFloor((r - y) * 2, 3);
        drawHLine(cx - half, cx + half, cy - y + d, color);
    }
    fillRectI32(cx - @divFloor(r, 4), cy + d, @divFloor(r, 2), r + 1, color);
}

fn drawText5x7(x0: usize, y0: usize, s: []const u8, color: Color, scale: usize) void {
    var x = x0;
    for (s) |ch| {
        drawGlyph5x7(x, y0, ch, color, scale);
        x += 6 * scale;
    }
}

fn drawGlyph5x7(x0: usize, y0: usize, ch: u8, color: Color, scale: usize) void {
    const rows = glyphRows(ch);
    var y: usize = 0;
    while (y < 7) : (y += 1) {
        const bits = rows[y];
        var x: usize = 0;
        while (x < 5) : (x += 1) {
            const mask: u8 = @as(u8, 1) << @intCast(4 - x);
            if ((bits & mask) != 0) {
                fillRect(x0 + x * scale, y0 + y * scale, scale, scale, color);
            }
        }
    }
}

fn glyphRows(ch: u8) [7]u8 {
    return switch (ch) {
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        else => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b00100, 0b00000, 0b00100 },
    };
}

fn drawRectStroke(x: usize, y: usize, w: usize, h: usize, t: usize, color: Color) void {
    fillRect(x, y, w, t, color);
    fillRect(x, y + h - t, w, t, color);
    fillRect(x, y, t, h, color);
    fillRect(x + w - t, y, t, h, color);
}

fn drawHLine(x0: i32, x1: i32, y: i32, color: Color) void {
    var x = x0;
    while (x <= x1) : (x += 1) {
        setPixelI32(x, y, color);
    }
}

fn drawFilledCircle(cx: i32, cy: i32, radius: i32, color: Color) void {
    const r2 = radius * radius;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) {
                setPixelI32(cx + dx, cy + dy, color);
            }
        }
    }
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            setPixel(x, y, color);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            setPixelI32(x, y, color);
        }
    }
}

fn setPixelI32(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= RENDER_W or uy >= RENDER_H) return;
    setPixel(ux, uy, color);
}

fn setPixel(x: usize, y: usize, color: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    pixel_buf[idx + 0] = color[0];
    pixel_buf[idx + 1] = color[1];
    pixel_buf[idx + 2] = color[2];
    pixel_buf[idx + 3] = color[3];
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn pointInRect(x: i32, y: i32, rx: i32, ry: i32, rw: i32, rh: i32) bool {
    return x >= rx and y >= ry and x < rx + rw and y < ry + rh;
}

test "discardable detection works for same suit lower rank" {
    pile_lens = [_]u8{ 1, 1, 0, 0 };
    piles[0][0] = 5; // 6 clubs
    piles[1][0] = 0; // Ace clubs
    try std.testing.expect(isDiscardable(0));
    try std.testing.expect(!isDiscardable(1)); // ace is highest, never discarded by lower rank
}

test "rank label for ten is two chars" {
    var out: [2]u8 = undefined;
    const n = rankLabel(10, &out);
    try std.testing.expect(n == 2);
    try std.testing.expect(out[0] == '1' and out[1] == '0');
}
