const PLAYERS: usize = 3;
const HUMAN: usize = 0;
const MAX_DICE: usize = 5;
const MAX_TOTAL_DICE: usize = PLAYERS * MAX_DICE;

const RENDER_W: usize = 920;
const RENDER_H: usize = 580;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const BTN_PRIMARY: i32 = 1 << 0;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_RETURN: i32 = 0xFF0D;

const PHASE_PLAYER_TURN: u8 = 0;
const PHASE_AI_WAIT: u8 = 1;
const PHASE_REVEAL: u8 = 2;
const PHASE_GAME_OVER: u8 = 3;

const REVEAL_NONE: u8 = 0;
const REVEAL_BLUFF: u8 = 1;
const REVEAL_SPOT: u8 = 2;

const AI_DELAY_MIN_MS: i32 = 500;
const AI_DELAY_VAR_MS: i32 = 600;
const REVEAL_HOLD_MS: i32 = 2100;

const Color = [4]u8;

const COLOR_BG_TOP: Color = .{ 0x0D, 0x1B, 0x2A, 0xFF };
const COLOR_BG_BOTTOM: Color = .{ 0x12, 0x2A, 0x3D, 0xFF };
const COLOR_FELT_TOP: Color = .{ 0x0F, 0x6A, 0x69, 0xFF };
const COLOR_FELT_BOTTOM: Color = .{ 0x0A, 0x4D, 0x54, 0xFF };
const COLOR_PANEL: Color = .{ 0xF8, 0xFB, 0xFF, 0xFF };
const COLOR_PANEL_DARK: Color = .{ 0xC9, 0xD4, 0xE3, 0xFF };
const COLOR_PANEL_TEXT: Color = .{ 0x1D, 0x2A, 0x3A, 0xFF };
const COLOR_DIE: Color = .{ 0xFE, 0xFE, 0xFC, 0xFF };
const COLOR_DIE_EDGE: Color = .{ 0x29, 0x2F, 0x36, 0xFF };
const COLOR_PIP: Color = .{ 0x1A, 0x20, 0x28, 0xFF };
const COLOR_HIDDEN_DIE: Color = .{ 0x95, 0xA4, 0xB8, 0xFF };
const COLOR_ACTIVE: Color = .{ 0x37, 0xB0, 0xFF, 0xFF };
const COLOR_ACTION: Color = .{ 0xE3, 0xED, 0xFA, 0xFF };
const COLOR_ACTION_TEXT: Color = .{ 0x17, 0x28, 0x3A, 0xFF };
const COLOR_ACTION_OFF: Color = .{ 0x9D, 0xAC, 0xBF, 0xFF };
const COLOR_GOOD: Color = .{ 0x1B, 0x9A, 0x67, 0xFF };
const COLOR_BAD: Color = .{ 0xD2, 0x43, 0x5A, 0xFF };
const COLOR_MUTED: Color = .{ 0xE9, 0xF0, 0xF8, 0xFF };
const COLOR_SHADOW: Color = .{ 0x08, 0x12, 0x1F, 0xFF };
const COLOR_TITLE: Color = .{ 0xD9, 0xEE, 0xFF, 0xFF };
const COLOR_RAISE: Color = .{ 0x38, 0x8B, 0xF2, 0xFF };
const COLOR_BLUFF: Color = .{ 0xE2, 0x59, 0x67, 0xFF };
const COLOR_SPOT: Color = .{ 0x26, 0xA6, 0x7C, 0xFF };

const FONT_DIGITS = [10][7]u8{
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

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;

var dice_count: [PLAYERS]u8 = [_]u8{MAX_DICE} ** PLAYERS;
var dice_values: [PLAYERS][MAX_DICE]u8 = [_][MAX_DICE]u8{[_]u8{1} ** MAX_DICE} ** PLAYERS;

var round_starter: usize = 0;
var turn_player: usize = 0;

var bid_qty: u8 = 0;
var bid_face: u8 = 0;
var bid_player: usize = 0;

var draft_qty: u8 = 1;
var draft_face: u8 = 1;

var phase: u8 = PHASE_PLAYER_TURN;
var reveal_kind: u8 = REVEAL_NONE;
var reveal_caller: usize = 0;
var reveal_total: u8 = 0;
var reveal_deadline_ms: i64 = 0;
var ai_due_ms: i64 = 0;
var winner: i32 = -1;

var primary_down: bool = false;
var initialized: bool = false;
var needs_redraw: bool = true;

var rng_state: u32 = 0xA36F51A3;
var game_count: u32 = 0;

const ActionRects = struct {
    qty_down: Rect,
    qty_up: Rect,
    face_down: Rect,
    face_up: Rect,
    raise_btn: Rect,
    bluff_btn: Rect,
    spot_btn: Rect,
};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const ACTION_RECTS = ActionRects{
    .qty_down = .{ .x = 252, .y = 382, .w = 38, .h = 34 },
    .qty_up = .{ .x = 384, .y = 382, .w = 38, .h = 34 },
    .face_down = .{ .x = 498, .y = 382, .w = 38, .h = 34 },
    .face_up = .{ .x = 630, .y = 382, .w = 38, .h = 34 },
    .raise_btn = .{ .x = 250, .y = 440, .w = 128, .h = 48 },
    .bluff_btn = .{ .x = 395, .y = 440, .w = 128, .h = 48 },
    .spot_btn = .{ .x = 540, .y = 440, .w = 128, .h = 48 },
};

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
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    const has_shortcut_modifier = (flags & (FLAG_CTRL | FLAG_ALT | FLAG_META)) != 0;
    if (!has_shortcut_modifier and (x11_key == 0x72 or x11_key == 0x52)) {
        resetGame(begun_at_ms);
        return 1;
    }

    if (phase == PHASE_GAME_OVER) return 0;
    if (phase != PHASE_PLAYER_TURN or turn_player != HUMAN) return 0;

    switch (x11_key) {
        XK_UP, 0x77, 0x57 => {
            adjustDraftQty(1);
            return 1;
        },
        XK_DOWN, 0x73, 0x53 => {
            adjustDraftQty(-1);
            return 1;
        },
        XK_RIGHT, 0x64, 0x44 => {
            adjustDraftFace(1);
            return 1;
        },
        XK_LEFT, 0x61, 0x41 => {
            adjustDraftFace(-1);
            return 1;
        },
        XK_RETURN, 0x20 => {
            return if (performRaise()) 1 else 0;
        },
        0x63, 0x43 => {
            return if (performCallBluff()) 1 else 0;
        },
        0x78, 0x58 => {
            return if (performCallSpot()) 1 else 0;
        },
        else => return 0,
    }
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();

    const is_primary = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    if (is_primary and !primary_down) {
        changed = handlePrimaryPress(x_px, y_px);
    }

    primary_down = is_primary;
    return if (changed) 1 else 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (phase == PHASE_AI_WAIT and begun_at_ms >= ai_due_ms) {
        runAiTurn(begun_at_ms);
    }

    if (phase == PHASE_REVEAL and begun_at_ms >= reveal_deadline_ms) {
        advanceAfterReveal(begun_at_ms);
    }
}

export fn finish_update() i64 {
    requireUpdate();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    if (phase == PHASE_AI_WAIT) return ai_due_ms;
    if (phase == PHASE_REVEAL) return reveal_deadline_ms;
    return begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or (lifecycle_state != .initializing and lifecycle_state != .ready)) @trap();
    if (!initialized) resetGame(0);
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

fn resetGame(now_ms: i64) void {
    initialized = true;
    primary_down = false;
    game_count +%= 1;
    rng_state +%= 0x9E3779B9 + game_count *% 0x85EBCA6B;

    var i: usize = 0;
    while (i < PLAYERS) : (i += 1) {
        dice_count[i] = MAX_DICE;
    }

    winner = -1;
    round_starter = @as(usize, @intCast(rngNext() % PLAYERS));
    startRound(now_ms, round_starter);
}

fn startRound(now_ms: i64, starter: usize) void {
    round_starter = starter;
    bid_qty = 0;
    bid_face = 0;
    bid_player = starter;
    reveal_kind = REVEAL_NONE;

    rollAllAliveDice();

    turn_player = nextAliveFrom(starter, true);
    if (turn_player == HUMAN) {
        phase = PHASE_PLAYER_TURN;
    } else {
        phase = PHASE_AI_WAIT;
        ai_due_ms = now_ms + @as(i64, AI_DELAY_MIN_MS) + @as(i64, @intCast(rngNext() % @as(u32, @intCast(AI_DELAY_VAR_MS))));
    }

    resetDraftToMinimumLegal();
    needs_redraw = true;
}

fn rollAllAliveDice() void {
    var p: usize = 0;
    while (p < PLAYERS) : (p += 1) {
        const count = dice_count[p];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            dice_values[p][i] = 1 + @as(u8, @intCast(rngNext() % 6));
        }
    }
}

fn runAiTurn(now_ms: i64) void {
    if (phase != PHASE_AI_WAIT) return;
    if (turn_player == HUMAN) {
        phase = PHASE_PLAYER_TURN;
        needs_redraw = true;
        return;
    }

    var action_done = false;

    if (bid_qty == 0) {
        const opening = aiChooseOpeningBid(turn_player);
        setBid(opening.qty, opening.face, turn_player);
        action_done = true;
    } else {
        const decision = aiChooseAction(turn_player);
        switch (decision.kind) {
            0 => {
                setBid(decision.qty, decision.face, turn_player);
                action_done = true;
            },
            1 => {
                resolveBluff(turn_player, now_ms);
                action_done = true;
            },
            else => {
                resolveSpotOn(turn_player, now_ms);
                action_done = true;
            },
        }
    }

    if (!action_done) return;

    if (phase == PHASE_AI_WAIT) {
        advanceTurnAfterRaise(now_ms);
    }
    needs_redraw = true;
}

const AIDecision = struct {
    kind: u8, // 0 raise, 1 bluff, 2 spot
    qty: u8,
    face: u8,
};

const Bid = struct {
    qty: u8,
    face: u8,
};

fn aiChooseOpeningBid(player: usize) Bid {
    var counts: [7]u8 = [_]u8{0} ** 7;
    const count = dice_count[player];
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const d = dice_values[player][i];
        counts[d] += 1;
    }

    var best_face: u8 = 1;
    var best_qty: u8 = 0;
    var face: u8 = 1;
    while (face <= 6) : (face += 1) {
        if (counts[face] > best_qty or (counts[face] == best_qty and face < best_face)) {
            best_face = face;
            best_qty = counts[face];
        }
    }

    if (best_qty == 0) best_qty = 1;
    if (best_qty > maxTotalDiceAlive()) best_qty = maxTotalDiceAlive();

    return .{ .qty = best_qty, .face = best_face };
}

fn aiChooseAction(player: usize) AIDecision {
    var counts: [7]u8 = [_]u8{0} ** 7;
    const count = dice_count[player];
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const d = dice_values[player][i];
        counts[d] += 1;
    }

    const alive_total = maxTotalDiceAlive();
    const unknown = alive_total - count;
    const expected_extra = @as(u8, @intCast((unknown + 5) / 6));
    const likely = counts[bid_face] + expected_extra;

    const risk_raw = @as(i32, bid_qty) - @as(i32, likely);
    const confidence_roll = @as(i32, @intCast(rngNext() % 100));

    if (risk_raw >= 2 and confidence_roll < 82) {
        return .{ .kind = 1, .qty = 0, .face = 0 };
    }

    if (risk_raw == 0 and confidence_roll < 14) {
        return .{ .kind = 2, .qty = 0, .face = 0 };
    }

    var min_qty: u8 = 1;
    var min_face: u8 = 1;
    minimumLegalBid(&min_qty, &min_face);

    var best = Bid{ .qty = min_qty, .face = min_face };
    var best_score: i32 = -999;

    var q: u8 = min_qty;
    while (q <= alive_total) : (q += 1) {
        var f: u8 = 1;
        while (f <= 6) : (f += 1) {
            if (!isBidHigherThanCurrent(q, f)) continue;
            const support = counts[f] + expected_extra;
            const slack = @as(i32, support) - @as(i32, q);
            var score = slack * 7 - @as(i32, f) + @as(i32, @intCast(rngNext() % 7));
            if (q == min_qty and f == min_face) score += 2;
            if (score > best_score) {
                best_score = score;
                best = .{ .qty = q, .face = f };
            }
        }
    }

    if (best_score < -5 and confidence_roll < 65) {
        return .{ .kind = 1, .qty = 0, .face = 0 };
    }

    return .{ .kind = 0, .qty = best.qty, .face = best.face };
}

fn performRaise() bool {
    if (phase != PHASE_PLAYER_TURN or turn_player != HUMAN) return false;
    if (!isBidHigherThanCurrent(draft_qty, draft_face)) return false;

    setBid(draft_qty, draft_face, HUMAN);
    advanceTurnAfterRaise(begun_at_ms);
    needs_redraw = true;
    return true;
}

fn performCallBluff() bool {
    if (phase != PHASE_PLAYER_TURN or turn_player != HUMAN) return false;
    if (bid_qty == 0) return false;
    resolveBluff(HUMAN, begun_at_ms);
    needs_redraw = true;
    return true;
}

fn performCallSpot() bool {
    if (phase != PHASE_PLAYER_TURN or turn_player != HUMAN) return false;
    if (bid_qty == 0) return false;
    resolveSpotOn(HUMAN, begun_at_ms);
    needs_redraw = true;
    return true;
}

fn setBid(qty: u8, face: u8, player: usize) void {
    bid_qty = qty;
    bid_face = face;
    bid_player = player;
    resetDraftToMinimumLegal();
}

fn resolveBluff(caller: usize, now_ms: i64) void {
    const total = countFaceAcrossAlive(bid_face);
    reveal_kind = REVEAL_BLUFF;
    reveal_caller = caller;
    reveal_total = total;

    if (total >= bid_qty) {
        loseOneDie(caller);
    } else {
        loseOneDie(bid_player);
    }

    phase = PHASE_REVEAL;
    reveal_deadline_ms = now_ms + @as(i64, REVEAL_HOLD_MS);
    needs_redraw = true;
}

fn resolveSpotOn(caller: usize, now_ms: i64) void {
    const total = countFaceAcrossAlive(bid_face);
    reveal_kind = REVEAL_SPOT;
    reveal_caller = caller;
    reveal_total = total;

    if (total == bid_qty) {
        var p: usize = 0;
        while (p < PLAYERS) : (p += 1) {
            if (p == caller) continue;
            loseOneDie(p);
        }
    } else {
        loseOneDie(caller);
    }

    phase = PHASE_REVEAL;
    reveal_deadline_ms = now_ms + @as(i64, REVEAL_HOLD_MS);
    needs_redraw = true;
}

fn loseOneDie(player: usize) void {
    if (dice_count[player] == 0) return;
    dice_count[player] -= 1;
}

fn advanceAfterReveal(now_ms: i64) void {
    const alive = countAlivePlayers();
    if (alive <= 1) {
        winner = @as(i32, @intCast(lastAlivePlayer()));
        phase = PHASE_GAME_OVER;
        needs_redraw = true;
        return;
    }

    const next_starter = prevAliveFrom(round_starter, false);
    startRound(now_ms, next_starter);
}

fn advanceTurnAfterRaise(now_ms: i64) void {
    turn_player = nextAliveFrom(turn_player, false);
    if (turn_player == HUMAN) {
        phase = PHASE_PLAYER_TURN;
        resetDraftToMinimumLegal();
    } else {
        phase = PHASE_AI_WAIT;
        ai_due_ms = now_ms + @as(i64, AI_DELAY_MIN_MS) + @as(i64, @intCast(rngNext() % @as(u32, @intCast(AI_DELAY_VAR_MS))));
    }
}

fn adjustDraftQty(delta: i32) void {
    const min_bid = minimumLegalBidValue();
    const min_qty = @as(i32, min_bid.qty);
    const min_face = min_bid.face;
    var q = @as(i32, draft_qty) + delta;
    if (q < min_qty) q = min_qty;
    const max_qty = @as(i32, maxTotalDiceAlive());
    if (q > max_qty) q = max_qty;
    draft_qty = @as(u8, @intCast(q));

    if (draft_qty == min_qty and draft_face < min_face) {
        draft_face = min_face;
    }
    needs_redraw = true;
}

fn adjustDraftFace(delta: i32) void {
    var f = @as(i32, draft_face) + delta;
    if (f < 1) f = 1;
    if (f > 6) f = 6;
    draft_face = @as(u8, @intCast(f));

    if (!isBidHigherThanCurrent(draft_qty, draft_face)) {
        if (draft_qty < maxTotalDiceAlive()) {
            draft_qty += 1;
        }
        if (!isBidHigherThanCurrent(draft_qty, draft_face)) {
            const min_bid = minimumLegalBidValue();
            if (draft_qty == bid_qty) {
                draft_face = min_bid.face;
            }
        }
    }
    needs_redraw = true;
}

fn resetDraftToMinimumLegal() void {
    const min_bid = minimumLegalBidValue();
    draft_qty = min_bid.qty;
    draft_face = min_bid.face;
}

fn minimumLegalBid(out_qty: *u8, out_face: *u8) void {
    const min_bid = minimumLegalBidValue();
    out_qty.* = min_bid.qty;
    out_face.* = min_bid.face;
}

const MinBid = struct {
    qty: u8,
    face: u8,
};

fn minimumLegalBidValue() MinBid {
    if (bid_qty == 0) return .{ .qty = 1, .face = 1 };
    if (bid_face < 6) return .{ .qty = bid_qty, .face = bid_face + 1 };
    return .{ .qty = bid_qty + 1, .face = 1 };
}

fn isBidHigherThanCurrent(qty: u8, face: u8) bool {
    if (face < 1 or face > 6) return false;
    if (qty == 0) return false;
    if (qty > maxTotalDiceAlive()) return false;
    if (bid_qty == 0) return true;
    if (qty > bid_qty) return true;
    if (qty == bid_qty and face > bid_face) return true;
    return false;
}

fn handlePrimaryPress(x_px: i32, y_px: i32) bool {
    if (phase == PHASE_GAME_OVER) {
        resetGame(begun_at_ms);
        return true;
    }

    if (phase != PHASE_PLAYER_TURN or turn_player != HUMAN) return false;

    if (pointInRect(x_px, y_px, ACTION_RECTS.qty_down)) {
        adjustDraftQty(-1);
        return true;
    }
    if (pointInRect(x_px, y_px, ACTION_RECTS.qty_up)) {
        adjustDraftQty(1);
        return true;
    }
    if (pointInRect(x_px, y_px, ACTION_RECTS.face_down)) {
        adjustDraftFace(-1);
        return true;
    }
    if (pointInRect(x_px, y_px, ACTION_RECTS.face_up)) {
        adjustDraftFace(1);
        return true;
    }

    if (pointInRect(x_px, y_px, ACTION_RECTS.raise_btn)) {
        return performRaise();
    }
    if (pointInRect(x_px, y_px, ACTION_RECTS.bluff_btn)) {
        return performCallBluff();
    }
    if (pointInRect(x_px, y_px, ACTION_RECTS.spot_btn)) {
        return performCallSpot();
    }

    return false;
}

fn countFaceAcrossAlive(face: u8) u8 {
    var total: u8 = 0;
    var p: usize = 0;
    while (p < PLAYERS) : (p += 1) {
        const count = dice_count[p];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (dice_values[p][i] == face) total += 1;
        }
    }
    return total;
}

fn nextAliveFrom(start: usize, include_start: bool) usize {
    var i: usize = 0;
    while (i < PLAYERS) : (i += 1) {
        const off: usize = if (include_start) i else i + 1;
        const idx = (start + off) % PLAYERS;
        if (dice_count[idx] > 0) return idx;
    }
    return HUMAN;
}

fn prevAliveFrom(start: usize, include_start: bool) usize {
    var i: usize = 0;
    while (i < PLAYERS) : (i += 1) {
        const off: usize = if (include_start) i else i + 1;
        const idx = (start + PLAYERS - (off % PLAYERS)) % PLAYERS;
        if (dice_count[idx] > 0) return idx;
    }
    return HUMAN;
}

fn countAlivePlayers() u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < PLAYERS) : (i += 1) {
        if (dice_count[i] > 0) n += 1;
    }
    return n;
}

fn maxTotalDiceAlive() u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < PLAYERS) : (i += 1) {
        n += dice_count[i];
    }
    return n;
}

fn lastAlivePlayer() usize {
    var i: usize = 0;
    while (i < PLAYERS) : (i += 1) {
        if (dice_count[i] > 0) return i;
    }
    return HUMAN;
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn drawFrame() void {
    fillVerticalGradient(0, 0, @intCast(RENDER_W), @intCast(RENDER_H), COLOR_BG_TOP, COLOR_BG_BOTTOM);
    fillVerticalGradient(26, 24, 868, 530, COLOR_FELT_TOP, COLOR_FELT_BOTTOM);
    drawRoundedPanel(26, 24, 868, 530, 18, COLOR_FELT_TOP, COLOR_PANEL_DARK);
    drawText5x7(334, 36, "LIARS DICE", 3, COLOR_TITLE);
    drawText5x7(350, 58, "RDR STYLE 3P", 2, COLOR_TITLE);

    drawPlayerPanel(1, 84, 72, 300, 132);
    drawPlayerPanel(2, 536, 72, 300, 132);
    drawPlayerPanel(0, 232, 216, 456, 164);

    drawCenterPanel();
    drawBottomStatus();
}

fn drawPlayerPanel(player: usize, x: i32, y: i32, w: i32, h: i32) void {
    var panel = COLOR_PANEL;
    if (dice_count[player] == 0) panel = COLOR_ACTION_OFF;
    drawRoundedPanel(x, y, w, h, 12, panel, COLOR_PANEL_DARK);

    var border_color = COLOR_PANEL_DARK;
    if (turn_player == player and phase != PHASE_GAME_OVER) border_color = COLOR_ACTIVE;
    drawRoundedBorder(x, y, w, h, 12, border_color, panel, 3);

    if (player == HUMAN) {
        drawText5x7(x + 16, y + 14, "YOU", 3, COLOR_PANEL_TEXT);
    } else if (player == 1) {
        drawText5x7(x + 16, y + 14, "CPU1", 3, COLOR_PANEL_TEXT);
    } else {
        drawText5x7(x + 16, y + 14, "CPU2", 3, COLOR_PANEL_TEXT);
    }

    drawText5x7(x + w - 130, y + 16, "DICE", 2, COLOR_PANEL_TEXT);
    drawDigit(@intCast(x + w - 64), @intCast(y + 16), dice_count[player], 3, COLOR_PANEL_TEXT);

    const reveal = phase == PHASE_REVEAL or phase == PHASE_GAME_OVER;
    const show_values = (player == HUMAN) or reveal;

    const count = dice_count[player];
    if (count == 0) {
        drawText5x7(x + 98, y + 66, "OUT", 3, COLOR_PANEL_TEXT);
        return;
    }

    const die_size: i32 = if (player == HUMAN) 44 else 34;
    const gap: i32 = if (player == HUMAN) 14 else 10;
    const row_w = @as(i32, count) * die_size + @as(i32, count - 1) * gap;
    var dx = x + @divFloor(w - row_w, 2);
    const dy = y + h - die_size - 20;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (show_values) {
            drawDieFace(dx, dy, die_size, dice_values[player][i], false);
        } else {
            drawDieFace(dx, dy, die_size, 0, true);
        }
        dx += die_size + gap;
    }
}

fn drawCenterPanel() void {
    drawRoundedPanel(194, 390, 532, 118, 12, COLOR_PANEL, COLOR_PANEL_DARK);

    drawText5x7(214, 404, "QTY", 2, COLOR_PANEL_TEXT);
    drawText5x7(462, 404, "FACE", 2, COLOR_PANEL_TEXT);

    drawValueAdjust(ACTION_RECTS.qty_down, "-", COLOR_ACTION_TEXT);
    drawValueAdjust(ACTION_RECTS.qty_up, "+", COLOR_ACTION_TEXT);
    drawValueAdjust(ACTION_RECTS.face_down, "-", COLOR_ACTION_TEXT);
    drawValueAdjust(ACTION_RECTS.face_up, "+", COLOR_ACTION_TEXT);

    drawNumber(322, 398, draft_qty, 4, COLOR_PANEL_TEXT);
    drawDieFace(556, 398, 56, draft_face, false);

    drawActionButton(ACTION_RECTS.raise_btn, "RAISE", canRaiseNow());
    drawActionButton(ACTION_RECTS.bluff_btn, "BLUFF", canChallengeNow());
    drawActionButton(ACTION_RECTS.spot_btn, "SPOT", canChallengeNow());
}

fn drawBottomStatus() void {
    drawRoundedPanel(194, 520, 532, 30, 9, COLOR_MUTED, COLOR_PANEL_DARK);

    if (phase == PHASE_GAME_OVER) {
        if (winner == HUMAN) {
            drawText5x7(212, 527, "WINNER YOU   PRESS R", 2, COLOR_PANEL_TEXT);
        } else {
            drawText5x7(212, 527, "WINNER CPU   PRESS R", 2, COLOR_PANEL_TEXT);
            if (winner == 2) drawDigit(408, 527, 2, 2, COLOR_PANEL_TEXT) else drawDigit(408, 527, 1, 2, COLOR_PANEL_TEXT);
        }
        return;
    }

    drawText5x7(212, 527, "BID", 2, COLOR_PANEL_TEXT);
    if (bid_qty == 0) {
        drawText5x7(256, 527, "NONE", 2, COLOR_PANEL_TEXT);
    } else {
        drawNumber(256, 527, bid_qty, 2, COLOR_PANEL_TEXT);
        drawDieFace(290, 525, 18, bid_face, false);
        drawText5x7(318, 527, "BY", 2, COLOR_PANEL_TEXT);
        if (bid_player == HUMAN) {
            drawText5x7(350, 527, "YOU", 2, COLOR_PANEL_TEXT);
        } else if (bid_player == 1) {
            drawText5x7(350, 527, "CPU1", 2, COLOR_PANEL_TEXT);
        } else {
            drawText5x7(350, 527, "CPU2", 2, COLOR_PANEL_TEXT);
        }
    }

    if (phase == PHASE_REVEAL) {
        drawRevealMessage(470, 527);
    } else if (turn_player == HUMAN) {
        drawText5x7(470, 527, "ENTER RAISE  C BLUFF  X SPOT", 2, COLOR_PANEL_TEXT);
    } else {
        drawText5x7(470, 527, "CPU TURN", 2, COLOR_PANEL_TEXT);
    }
}

fn drawRevealMessage(x: i32, y: i32) void {
    if (reveal_kind == REVEAL_BLUFF) {
        if (reveal_total >= bid_qty) {
            drawText5x7(x, y, "BLUFF FAIL", 2, COLOR_BAD);
        } else {
            drawText5x7(x, y, "BLUFF GOOD", 2, COLOR_GOOD);
        }
    } else if (reveal_kind == REVEAL_SPOT) {
        if (reveal_total == bid_qty) {
            drawText5x7(x, y, "SPOT ON", 2, COLOR_GOOD);
        } else {
            drawText5x7(x, y, "SPOT MISS", 2, COLOR_BAD);
        }
    }

    drawText5x7(x + 132, y, "TOTAL", 2, COLOR_PANEL_TEXT);
    drawNumber(x + 198, y, reveal_total, 2, COLOR_PANEL_TEXT);
}

fn canRaiseNow() bool {
    return phase == PHASE_PLAYER_TURN and turn_player == HUMAN and isBidHigherThanCurrent(draft_qty, draft_face);
}

fn canChallengeNow() bool {
    return phase == PHASE_PLAYER_TURN and turn_player == HUMAN and bid_qty > 0;
}

fn drawActionButton(rect: Rect, label: []const u8, enabled: bool) void {
    var base = COLOR_ACTION;
    if (label.len > 0) {
        switch (label[0]) {
            'R' => base = COLOR_RAISE,
            'B' => base = COLOR_BLUFF,
            'S' => base = COLOR_SPOT,
            else => {},
        }
    }
    const bg = if (enabled) base else COLOR_ACTION_OFF;
    const fg = if (enabled) COLOR_PANEL else COLOR_MUTED;
    drawRoundedPanel(rect.x, rect.y, rect.w, rect.h, 8, bg, COLOR_PANEL_DARK);

    const text_w = @as(i32, @intCast(label.len)) * 6 * 2;
    const tx = rect.x + @divFloor(rect.w - text_w, 2);
    drawText5x7(tx, rect.y + 16, label, 2, fg);
}

fn drawValueAdjust(rect: Rect, text: []const u8, color: Color) void {
    drawRoundedPanel(rect.x, rect.y, rect.w, rect.h, 6, COLOR_ACTION, COLOR_PANEL_DARK);
    const tx = rect.x + @divFloor(rect.w - 10, 2);
    const ty = rect.y + 9;
    drawText5x7(tx, ty, text, 2, color);
}

fn drawDieFace(x: i32, y: i32, size: i32, value: u8, hidden: bool) void {
    const die_color = if (hidden) COLOR_HIDDEN_DIE else COLOR_DIE;
    fillRect(x, y, size, size, die_color);
    drawRectStroke(x, y, size, size, COLOR_DIE_EDGE, 2);

    if (hidden) return;

    const pad = @divFloor(size, 5);
    const p = @max(2, @divFloor(size, 10));
    const lx = x + pad;
    const cx = x + @divFloor(size, 2);
    const rx = x + size - pad;
    const ty = y + pad;
    const cy = y + @divFloor(size, 2);
    const by = y + size - pad;

    switch (value) {
        1 => {
            drawPip(cx, cy, p);
        },
        2 => {
            drawPip(lx, ty, p);
            drawPip(rx, by, p);
        },
        3 => {
            drawPip(lx, ty, p);
            drawPip(cx, cy, p);
            drawPip(rx, by, p);
        },
        4 => {
            drawPip(lx, ty, p);
            drawPip(rx, ty, p);
            drawPip(lx, by, p);
            drawPip(rx, by, p);
        },
        5 => {
            drawPip(lx, ty, p);
            drawPip(rx, ty, p);
            drawPip(cx, cy, p);
            drawPip(lx, by, p);
            drawPip(rx, by, p);
        },
        6 => {
            drawPip(lx, ty, p);
            drawPip(rx, ty, p);
            drawPip(lx, cy, p);
            drawPip(rx, cy, p);
            drawPip(lx, by, p);
            drawPip(rx, by, p);
        },
        else => {},
    }
}

fn drawPip(cx: i32, cy: i32, r: i32) void {
    var yy: i32 = -r;
    while (yy <= r) : (yy += 1) {
        var xx: i32 = -r;
        while (xx <= r) : (xx += 1) {
            if (xx * xx + yy * yy <= r * r) {
                putPixel(cx + xx, cy + yy, COLOR_PIP);
            }
        }
    }
}

fn drawDigit(x: i32, y: i32, digit: u8, scale: i32, color: Color) void {
    if (digit > 9) return;
    const glyph = FONT_DIGITS[digit];
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        var bit: usize = 0;
        while (bit < 5) : (bit += 1) {
            const shift = @as(u3, @intCast(4 - bit));
            if (((glyph[row] >> shift) & 1) == 0) continue;
            fillRect(
                x + @as(i32, @intCast(bit)) * scale,
                y + @as(i32, @intCast(row)) * scale,
                scale,
                scale,
                color,
            );
        }
    }
}

fn drawNumber(x: i32, y: i32, value: u8, scale: i32, color: Color) void {
    if (value < 10) {
        drawDigit(x, y, value, scale, color);
        return;
    }
    const tens = value / 10;
    const ones = value % 10;
    drawDigit(x, y, tens, scale, color);
    drawDigit(x + 6 * scale, y, ones, scale, color);
}

fn drawText5x7(x: i32, y: i32, text: []const u8, scale: i32, color: Color) void {
    var cursor_x = x;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == ' ') {
            cursor_x += 6 * scale;
            continue;
        }
        drawGlyph5x7(cursor_x, y, ch, scale, color);
        cursor_x += 6 * scale;
    }
}

fn drawGlyph5x7(x: i32, y: i32, ch: u8, scale: i32, color: Color) void {
    const glyph = glyphFor(ch);
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        var bit: usize = 0;
        while (bit < 5) : (bit += 1) {
            const shift = @as(u3, @intCast(4 - bit));
            if (((glyph[row] >> shift) & 1) == 0) continue;
            fillRect(
                x + @as(i32, @intCast(bit)) * scale,
                y + @as(i32, @intCast(row)) * scale,
                scale,
                scale,
                color,
            );
        }
    }
}

fn glyphFor(ch_in: u8) [7]u8 {
    var ch = ch_in;
    if (ch >= 'a' and ch <= 'z') ch -= 32;
    return switch (ch) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00001, 0b00001, 0b00001, 0b00001, 0b10001, 0b10001, 0b01110 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '0' => FONT_DIGITS[0],
        '1' => FONT_DIGITS[1],
        '2' => FONT_DIGITS[2],
        '3' => FONT_DIGITS[3],
        '4' => FONT_DIGITS[4],
        '5' => FONT_DIGITS[5],
        '6' => FONT_DIGITS[6],
        '7' => FONT_DIGITS[7],
        '8' => FONT_DIGITS[8],
        '9' => FONT_DIGITS[9],
        '+' => .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        else => .{ 0b11111, 0b00001, 0b00110, 0b00100, 0b00000, 0b00100, 0b00000 },
    };
}

fn fillVerticalGradient(x: i32, y: i32, w: i32, h: i32, top: Color, bottom: Color) void {
    if (h <= 0 or w <= 0) return;
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        const denom = if (h <= 1) 1 else h - 1;
        const r = lerpChannel(top[0], bottom[0], yy, denom);
        const g = lerpChannel(top[1], bottom[1], yy, denom);
        const b = lerpChannel(top[2], bottom[2], yy, denom);
        const a = lerpChannel(top[3], bottom[3], yy, denom);
        fillRect(x, y + yy, w, 1, .{ r, g, b, a });
    }
}

fn lerpChannel(a: u8, b: u8, num: i32, den: i32) u8 {
    const ai = @as(i32, a);
    const bi = @as(i32, b);
    const v = ai + @divTrunc((bi - ai) * num, den);
    return @as(u8, @intCast(@max(0, @min(255, v))));
}

fn drawRoundedPanel(x: i32, y: i32, w: i32, h: i32, radius: i32, bg: Color, border: Color) void {
    fillRoundedRect(x + 3, y + 4, w, h, radius, COLOR_SHADOW);
    fillRoundedRect(x, y, w, h, radius, border);
    fillRoundedRect(x + 2, y + 2, w - 4, h - 4, @max(0, radius - 2), bg);
}

fn drawRoundedBorder(x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color, inner: Color, thickness: i32) void {
    fillRoundedRect(x, y, w, h, radius, color);
    fillRoundedRect(x + thickness, y + thickness, w - thickness * 2, h - thickness * 2, @max(0, radius - thickness), inner);
}

fn fillRoundedRect(x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void {
    if (w <= 0 or h <= 0) return;
    const r = @max(0, @min(radius, @divFloor(@min(w, h), 2)));
    if (r == 0) {
        if (color[3] != 0) fillRect(x, y, w, h, color);
        return;
    }

    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            var keep = true;
            if (xx < r and yy < r) {
                const dx = r - 1 - xx;
                const dy = r - 1 - yy;
                keep = dx * dx + dy * dy <= (r - 1) * (r - 1);
            } else if (xx >= w - r and yy < r) {
                const dx = xx - (w - r);
                const dy = r - 1 - yy;
                keep = dx * dx + dy * dy <= (r - 1) * (r - 1);
            } else if (xx < r and yy >= h - r) {
                const dx = r - 1 - xx;
                const dy = yy - (h - r);
                keep = dx * dx + dy * dy <= (r - 1) * (r - 1);
            } else if (xx >= w - r and yy >= h - r) {
                const dx = xx - (w - r);
                const dy = yy - (h - r);
                keep = dx * dx + dy * dy <= (r - 1) * (r - 1);
            }
            if (keep and color[3] != 0) {
                putPixel(x + xx, y + yy, color);
            }
        }
    }
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, color: Color) void {
    var yy = y;
    while (yy < y + h) : (yy += 1) {
        var xx = x;
        while (xx < x + w) : (xx += 1) {
            putPixel(xx, yy, color);
        }
    }
}

fn drawRectStroke(x: i32, y: i32, w: i32, h: i32, color: Color, thickness: i32) void {
    fillRect(x, y, w, thickness, color);
    fillRect(x, y + h - thickness, w, thickness, color);
    fillRect(x, y, thickness, h, color);
    fillRect(x + w - thickness, y, thickness, h, color);
}

fn putPixel(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0) return;
    if (x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;

    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    output_buf[idx] = color[0];
    output_buf[idx + 1] = color[1];
    output_buf[idx + 2] = color[2];
    output_buf[idx + 3] = color[3];
}

fn pointInRect(px: i32, py: i32, rect: Rect) bool {
    return px >= rect.x and py >= rect.y and px < rect.x + rect.w and py < rect.y + rect.h;
}
const ktx = @import("ktx2_rgba8_srgb");
