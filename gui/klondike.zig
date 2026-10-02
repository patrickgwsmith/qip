const std = @import("std");

const W = 1000;
const H = 760;
const CARD_W = 106;
const CARD_H = 146;
const LEFT = 46;
const GAP = 34;
const TOP_Y = 82;
const TABLEAU_Y = 292;
// The win cascade stamps up to ~4.4k card copies; each is a short <use>.
const OUTPUT_CAP = 320 * 1024;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";
const PRIMARY = 1;
const KEY_DOWN = 1;
const DEFAULT_SEED: u32 = 0x482ce17b;
const FLIGHT_MS = 240;
const FRAME_MS = 16;
const POKE = 12;
const LAUNCH_MS = 200;
const TRAIL_EVERY = 2;
const FLOOR: f32 = H - CARD_H;
const GRAVITY: f32 = 0.9;
const BOUNCE: f32 = 0.78;

const Pile = struct {
    cards: [52]u8 = undefined,
    len: u8 = 0,

    fn push(p: *Pile, card: u8) void {
        if (p.len >= 52) @trap();
        p.cards[p.len] = card;
        p.len += 1;
    }
    fn pop(p: *Pile) u8 {
        if (p.len == 0) @trap();
        p.len -= 1;
        return p.cards[p.len];
    }
    fn top(p: *const Pile) ?u8 {
        return if (p.len == 0) null else p.cards[p.len - 1];
    }
};

const SourceKind = enum { tableau, waste, foundation };
const Drag = struct {
    source: SourceKind,
    pile: u8,
    index: u8,
    start_x: i32,
    start_y: i32,
    x: i32,
    y: i32,
    offset_x: i32,
    offset_y: i32,
    active: bool = false,
};
const Hover = struct { col: u8, index: u8 };
// A clicked card glides from its old spot to its foundation. Game state moves
// at once; only the drawing lags behind, so input never waits on the animation.
const Flight = struct { card: u8, from_x: i32, from_y: i32, start: i64 };
// After a win, cards leave the foundations one by one, Windows-style, bouncing
// along the floor and leaving a trail. Every frame re-simulates from the start
// time, so the cascade needs no state beyond when it began.
const Bouncer = struct { x: f32, y: f32, vx: f32, vy: f32 };

var stock = Pile{};
var waste = Pile{};
var tableau = [_]Pile{.{}} ** 7;
var face_down = [_]u8{0} ** 7;
var foundation = [_]u8{0} ** 4;
var drag: ?Drag = null;
var hovered: ?Hover = null;
var flight: ?Flight = null;
var cascade_at: ?i64 = null;
var cascade_skipped = false;
var primary_down = false;
var seed: u32 = DEFAULT_SEED;
var requested_seed: u32 = DEFAULT_SEED;
var deals: u32 = 0;
var moves: u32 = 0;
var initialized = false;
var updating = false;
var begun_at: i64 = 0;
var committed_at: i64 = 0;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return 0;
}
export fn input_bytes_cap() u32 {
    return 0;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn uniform_set_seed(value: u32) u32 {
    requested_seed = if (value == 0) DEFAULT_SEED else value;
    return requested_seed;
}

export fn render(input_size: u32) u64 {
    if (updating or input_size != 0) @trap();
    if (!initialized) {
        newGame(requested_seed);
        initialized = true;
    }
    var w = Writer{};
    drawBoard(&w) catch @trap();
    return (@as(u64, @intCast(@intFromPtr(&output_buf))) << 32) | @as(u64, @intCast(w.n));
}

export fn begin_update_at(now_ms: i64) void {
    if (!initialized or updating or now_ms <= 0 or now_ms <= committed_at) @trap();
    begun_at = now_ms;
    updating = true;
}

export fn finish_update() i64 {
    if (!updating) @trap();
    updating = false;
    committed_at = begun_at;
    var wake = committed_at;
    if (flight) |f| {
        const end = f.start + FLIGHT_MS;
        if (end > committed_at) {
            wake = @min(committed_at + FRAME_MS, end);
        } else flight = null;
    }
    if (cascade_at == null and won()) cascade_at = if (flight) |f| f.start + FLIGHT_MS else committed_at;
    if (wake == committed_at and cascadeRunning(committed_at)) wake = committed_at + FRAME_MS;
    return wake;
}

export fn key_event(key: i32, flags: i32) i32 {
    if (!updating) @trap();
    if ((flags & KEY_DOWN) == 0) return 0;
    if (key == 'n' or key == 'N' or key == 'r' or key == 'R') {
        dealFresh();
        return 1;
    }
    if (key == ' ' or key == 0xff0d) {
        if (drag != null) return 0;
        return @intFromBool(drawStock());
    }
    return 0;
}

export fn pointer_event(mask: i32, x: i32, y: i32) i32 {
    if (!updating) @trap();
    const down = (mask & PRIMARY) != 0;
    defer primary_down = down;
    if (cascade_at != null) {
        // The board is finished: a press skips the cascade or starts a new game.
        if (!down or primary_down) return 0;
        const finished = !cascadeRunning(begun_at);
        if (inside(x, y, 845, 24, 112, 38) or (finished and inside(x, y, WIN_BUTTON_X, WIN_BUTTON_Y, 112, 38))) {
            dealFresh();
            return 1;
        }
        if (finished) return 0;
        cascade_skipped = true;
        flight = null;
        return 1;
    }
    if (down and !primary_down) {
        const had_overlay = hovered != null or flight != null;
        hovered = null;
        flight = null; // A new press lands any card still in flight.
        if (inside(x, y, 845, 24, 112, 38)) {
            dealFresh();
            return 1;
        }
        if (inside(x, y, colX(0), TOP_Y, CARD_W, CARD_H)) return @intFromBool(drawStock() or had_overlay);
        drag = hitCard(x, y);
        return @intFromBool(drag != null or had_overlay);
    }
    if (down and primary_down) {
        if (drag) |*d| {
            d.x = x;
            d.y = y;
            if (@abs(x - d.start_x) + @abs(y - d.start_y) > 5) d.active = true;
            return @intFromBool(d.active);
        }
    }
    if (!down and primary_down) {
        if (drag) |d| {
            drag = null;
            if (d.active) {
                _ = drop(d, x, y);
                return 1; // Clear the dragged-card overlay even after an invalid drop.
            }
            return @intFromBool(autoFoundation(d));
        }
    }
    if (!down) {
        const next = hoverAt(x, y);
        if (hovered == null and next == null) return 0;
        if (hovered != null and next != null and hovered.?.col == next.?.col and hovered.?.index == next.?.index) return 0;
        hovered = next;
        return 1;
    }
    return 0;
}

fn rank(card: u8) u8 {
    return card % 13 + 1;
}
fn suit(card: u8) u8 {
    return card / 13;
}
fn red(card: u8) bool {
    return suit(card) == 1 or suit(card) == 2;
}
fn colX(col: usize) i32 {
    return LEFT + @as(i32, @intCast(col)) * (CARD_W + GAP);
}
fn inside(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

fn nextRandom() u32 {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

// The "You won!" panel carries its own New game button.
const WIN_BUTTON_X = 444;
const WIN_BUTTON_Y = 406;

fn dealFresh() void {
    const time_bits: u32 = @truncate(@as(u64, @bitCast(begun_at)));
    newGame(requested_seed ^ time_bits ^ (deals *% 0x9e3779b9));
}

fn newGame(value: u32) void {
    seed = if (value == 0) DEFAULT_SEED else value;
    deals +%= 1;
    moves = 0;
    stock = .{};
    waste = .{};
    tableau = [_]Pile{.{}} ** 7;
    face_down = [_]u8{0} ** 7;
    foundation = [_]u8{0} ** 4;
    drag = null;
    hovered = null;
    flight = null;
    cascade_at = null;
    cascade_skipped = false;
    var deck: [52]u8 = undefined;
    for (&deck, 0..) |*card, i| card.* = @intCast(i);
    var i: usize = deck.len - 1;
    while (i > 0) : (i -= 1) {
        const j: usize = nextRandom() % @as(u32, @intCast(i + 1));
        std.mem.swap(u8, &deck[i], &deck[j]);
    }
    var pos: usize = 0;
    for (0..7) |col| {
        for (0..col + 1) |_| {
            tableau[col].push(deck[pos]);
            pos += 1;
        }
        face_down[col] = @intCast(col);
    }
    while (pos < deck.len) : (pos += 1) stock.push(deck[pos]);
}

fn drawStock() bool {
    if (stock.len > 0) {
        waste.push(stock.pop());
    } else if (waste.len > 0) {
        while (waste.len > 0) stock.push(waste.pop());
    } else return false;
    moves += 1;
    return true;
}

fn tableauGap(col: usize) i32 {
    const n: i32 = @intCast(tableau[col].len);
    if (n <= 1) return 30;
    return @min(30, @max(16, @divTrunc(600 - TABLEAU_Y - CARD_H, n - 1)));
}

fn sourceCard(d: Drag) u8 {
    return switch (d.source) {
        .tableau => tableau[d.pile].cards[d.index],
        .waste => waste.top().?,
        .foundation => d.pile * 13 + foundation[d.pile] - 1,
    };
}

fn hitCard(x: i32, y: i32) ?Drag {
    if (inside(x, y, colX(1), TOP_Y, CARD_W, CARD_H) and waste.len > 0)
        return .{ .source = .waste, .pile = 0, .index = waste.len - 1, .start_x = x, .start_y = y, .x = x, .y = y, .offset_x = x - colX(1), .offset_y = y - TOP_Y };
    for (0..4) |f| {
        const bx = colX(f + 3);
        if (inside(x, y, bx, TOP_Y, CARD_W, CARD_H) and foundation[f] > 0)
            return .{ .source = .foundation, .pile = @intCast(f), .index = foundation[f] - 1, .start_x = x, .start_y = y, .x = x, .y = y, .offset_x = x - bx, .offset_y = y - TOP_Y };
    }
    for (0..7) |col| {
        const p = &tableau[col];
        if (p.len == 0) continue;
        const gap = tableauGap(col);
        for (0..p.len) |rev| {
            const i = @as(usize, p.len) - 1 - rev;
            if (i < face_down[col]) break;
            const cy = TABLEAU_Y + @as(i32, @intCast(i)) * gap;
            if (inside(x, y, colX(col), cy, CARD_W, CARD_H))
                return .{ .source = .tableau, .pile = @intCast(col), .index = @intCast(i), .start_x = x, .start_y = y, .x = x, .y = y, .offset_x = x - colX(col), .offset_y = y - cy };
        }
    }
    return null;
}

fn hoverAt(x: i32, y: i32) ?Hover {
    const card = hitCard(x, y) orelse return null;
    if (card.source != .tableau or card.index + 1 >= tableau[card.pile].len) return null;
    return .{ .col = card.pile, .index = card.index };
}

fn canTableau(card: u8, col: usize) bool {
    const target = tableau[col].top() orelse return rank(card) == 13;
    return rank(target) == rank(card) + 1 and red(target) != red(card);
}

fn canFoundation(card: u8) bool {
    return foundation[suit(card)] + 1 == rank(card);
}

fn removeSource(d: Drag) void {
    switch (d.source) {
        .waste => _ = waste.pop(),
        .foundation => foundation[d.pile] -= 1,
        .tableau => {
            tableau[d.pile].len = d.index;
            if (tableau[d.pile].len > 0 and face_down[d.pile] == tableau[d.pile].len)
                face_down[d.pile] -= 1;
        },
    }
}

fn moveToTableau(d: Drag, col: usize) bool {
    if (d.source == .tableau and d.pile == col) return false;
    const card = sourceCard(d);
    if (!canTableau(card, col)) return false;
    if (d.source == .tableau) {
        const from = &tableau[d.pile];
        const count: usize = from.len - d.index;
        for (0..count) |i| tableau[col].push(from.cards[@as(usize, d.index) + i]);
    } else tableau[col].push(card);
    removeSource(d);
    moves += 1;
    return true;
}

fn moveToFoundation(d: Drag) bool {
    if (d.source == .foundation) return false;
    if (d.source == .tableau and d.index != tableau[d.pile].len - 1) return false;
    const card = sourceCard(d);
    if (!canFoundation(card)) return false;
    removeSource(d);
    foundation[suit(card)] += 1;
    moves += 1;
    return true;
}

fn sourcePos(d: Drag) [2]i32 {
    return switch (d.source) {
        .tableau => .{ colX(d.pile), TABLEAU_Y + @as(i32, d.index) * tableauGap(d.pile) },
        .waste => .{ colX(1), TOP_Y },
        .foundation => .{ colX(@as(usize, d.pile) + 3), TOP_Y },
    };
}

fn autoFoundation(d: Drag) bool {
    const from = sourcePos(d);
    const card = sourceCard(d);
    if (!moveToFoundation(d)) return false;
    flight = .{ .card = card, .from_x = from[0], .from_y = from[1], .start = begun_at };
    return true;
}

fn flightPos(f: Flight) [2]i32 {
    const to_x = colX(@as(usize, suit(f.card)) + 3);
    const t: i64 = @min(FLIGHT_MS, @max(0, committed_at - f.start));
    // Cubic ease-out in thousandths: 1 - (1 - t)^3.
    const rest = 1000 - @divTrunc(t * 1000, FLIGHT_MS);
    const eased: i32 = @intCast(1000 - @divTrunc(rest * rest * rest, 1_000_000));
    return .{
        f.from_x + @divTrunc((to_x - f.from_x) * eased, 1000),
        f.from_y + @divTrunc((TOP_Y - f.from_y) * eased, 1000),
    };
}

fn won() bool {
    for (foundation) |n| if (n != 13) return false;
    return true;
}

// Kings leave first, cycling through the four foundations.
fn cascadeCard(k: usize) u8 {
    return @intCast((k % 4) * 13 + 12 - k / 4);
}

fn launch(k: usize) Bouncer {
    var h: u32 = seed ^ (@as(u32, @intCast(k + 1)) *% 0x9e3779b9);
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    const speed: f32 = @floatFromInt(6 + h % 7);
    return .{
        .x = @floatFromInt(colX(k % 4 + 3)),
        .y = TOP_Y,
        .vx = if ((h >> 8) & 1 == 0) -speed else speed,
        .vy = @as(f32, @floatFromInt((h >> 12) % 12)) - 9,
    };
}

fn advance(b: *Bouncer) void {
    b.x += b.vx;
    b.vy += GRAVITY;
    b.y += b.vy;
    if (b.y > FLOOR) {
        b.y = FLOOR;
        b.vy = -b.vy * BOUNCE;
    }
}

fn offscreen(b: Bouncer) bool {
    return b.x < -CARD_W or b.x > W;
}

fn cascadeEnd(start: i64) i64 {
    var end = start;
    for (0..52) |k| {
        var b = launch(k);
        var steps: i64 = 0;
        while (!offscreen(b)) : (steps += 1) advance(&b);
        end = @max(end, start + @as(i64, @intCast(k)) * LAUNCH_MS + steps * FRAME_MS);
    }
    return end;
}

fn cascadeRunning(now: i64) bool {
    const start = cascade_at orelse return false;
    return !cascade_skipped and now < cascadeEnd(start);
}

fn cascadeElapsed() i64 {
    if (cascade_skipped) return std.math.maxInt(i32);
    return committed_at - (cascade_at orelse return -1);
}

fn cascadeLaunched(f: usize) u8 {
    const elapsed = cascadeElapsed();
    if (elapsed < 0) return 0;
    const count: usize = @intCast(@min(52, @divTrunc(elapsed, LAUNCH_MS) + 1));
    return @intCast(count / 4 + @intFromBool(count % 4 > f));
}

fn drawCascade(w: *Writer) !void {
    const elapsed = cascadeElapsed();
    if (elapsed < 0) return;
    const count: usize = @intCast(@min(52, @divTrunc(elapsed, LAUNCH_MS) + 1));
    try w.bytes("<defs>");
    for (0..count) |k| {
        try w.fmt("<g id=\"kc{d}\">", .{cascadeCard(k)});
        try drawFace(w, cascadeCard(k), false);
        try w.bytes("</g>");
    }
    try w.bytes("</defs>");
    for (0..count) |k| {
        const steps = @divTrunc(elapsed - @as(i64, @intCast(k)) * LAUNCH_MS, FRAME_MS);
        var b = launch(k);
        var i: i64 = 0;
        while (!offscreen(b)) : (i += 1) {
            if (i == steps or @mod(i, TRAIL_EVERY) == 0)
                try w.fmt("<use href=\"#kc{d}\" x=\"{d}\" y=\"{d}\"/>", .{ cascadeCard(k), @as(i32, @intFromFloat(@round(b.x))), @as(i32, @intFromFloat(@round(b.y))) });
            if (i == steps) break;
            advance(&b);
        }
    }
}

fn drop(d: Drag, x: i32, y: i32) bool {
    if (y >= TOP_Y - 20 and y < TOP_Y + CARD_H + 30) {
        for (0..4) |f| {
            if (inside(x, y, colX(f + 3) - 17, TOP_Y - 20, CARD_W + 34, CARD_H + 40) and suit(sourceCard(d)) == f)
                return moveToFoundation(d);
        }
    }
    if (y >= TABLEAU_Y - 36) {
        for (0..7) |col| {
            if (x >= colX(col) - 17 and x < colX(col) + CARD_W + 17)
                return moveToTableau(d, col);
        }
    }
    return false;
}

const Writer = struct {
    n: usize = 0,
    fn bytes(w: *Writer, s: []const u8) !void {
        if (s.len > OUTPUT_CAP - w.n) return error.Full;
        @memcpy(output_buf[w.n..][0..s.len], s);
        w.n += s.len;
    }
    fn fmt(w: *Writer, comptime format: []const u8, args: anytype) !void {
        const s = std.fmt.bufPrint(output_buf[w.n..], format, args) catch return error.Full;
        w.n += s.len;
    }
};

fn rankText(card: u8) []const u8 {
    return switch (rank(card)) {
        1 => "A",
        11 => "J",
        12 => "Q",
        13 => "K",
        10 => "10",
        else => |r| (&[_][]const u8{ "", "", "2", "3", "4", "5", "6", "7", "8", "9" })[r],
    };
}
// Approximate advance width of the 20 px bold rank, so the suit beneath it can be centred.
fn rankWidth(card: u8) i32 {
    return switch (rank(card)) {
        1 => 14,
        10 => 25,
        11 => 11,
        12 => 15,
        13 => 14,
        else => 12,
    };
}
fn suitName(s: usize) []const u8 {
    return (&[_][]const u8{ "SPADES", "HEARTS", "DIAMONDS", "CLUBS" })[s];
}

fn drawSuit(w: *Writer, card: u8, x: i32, y: i32, size: i32) !void {
    const shape = suit(card);
    const names = [_][]const u8{ "spades", "hearts", "diamonds", "clubs" };
    const color = if (shape == 1 or shape == 2) "#bd3b42" else if (shape == 0) "#1c3144" else "#194d39";
    try w.fmt("<svg x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 40 40\" data-suit=\"{s}\" fill=\"{s}\">", .{ x, y, size, size, names[shape], color });
    switch (shape) {
        0 => try w.bytes("<path d=\"M20 2C15 10 4 17 4 27c0 8 8 12 14 7l2-3 2 3c6 5 14 1 14-7C36 17 25 10 20 2Z M16 31c1 5 0 7-5 8h18c-5-1-6-3-5-8Z\"/>"),
        1 => try w.bytes("<path d=\"M20 38C17 34 2 23 2 14 2 7 6 3 12 3c4 0 7 3 8 6 1-3 4-6 8-6 6 0 10 4 10 11 0 9-15 20-18 24Z\"/>"),
        2 => try w.bytes("<path d=\"M20 2 38 20 20 38 2 20Z\"/>"),
        else => try w.bytes("<path d=\"M16 16h8v18h-8Z\"/><circle cx=\"20\" cy=\"11\" r=\"9\"/><circle cx=\"10\" cy=\"25\" r=\"9\"/><circle cx=\"30\" cy=\"25\" r=\"9\"/><path d=\"M17 22h6v10c0 3 2 5 6 7H11c4-2 6-4 6-7Z\"/>"),
    }
    try w.bytes("</svg>");
}

fn drawCard(w: *Writer, card: ?u8, x: i32, y: i32, back: bool) !void {
    try w.fmt("<g transform=\"translate({d} {d})\">", .{ x, y });
    try w.bytes("<rect x=\"2\" y=\"5\" width=\"106\" height=\"146\" rx=\"12\" fill=\"#06281f\" opacity=\".28\"/>");
    try drawFace(w, card, back);
    try w.bytes("</g>");
}

fn drawFace(w: *Writer, card: ?u8, back: bool) !void {
    if (back) {
        try w.bytes("<rect width=\"106\" height=\"146\" rx=\"12\" fill=\"#fbf7ec\" stroke=\"#d6d3c7\"/><rect x=\"5\" y=\"5\" width=\"96\" height=\"136\" rx=\"8\" fill=\"#183f76\"/><rect x=\"10\" y=\"10\" width=\"86\" height=\"126\" rx=\"5\" fill=\"url(#back)\" stroke=\"#9ab9dc\" stroke-width=\"1.2\"/><path d=\"M53 26 78 73 53 120 28 73Z\" fill=\"none\" stroke=\"#b7d4ed\" stroke-width=\"2\"/><circle cx=\"53\" cy=\"73\" r=\"18\" fill=\"#f4e7bd\"/><path d=\"M53 58 65 73 53 88 41 73Z\" fill=\"#204d80\"/>");
    } else if (card) |c| {
        const color = if (red(c)) "#bd3b42" else "#1c3144";
        try w.bytes("<rect width=\"106\" height=\"146\" rx=\"12\" fill=\"url(#face)\" stroke=\"#d2d2cb\"/>");
        try drawIndex(w, c, color);
        try drawSuit(w, c, 29, 51, 49);
        // The bottom-right index is the top-left one turned upside down, as on a real card.
        try w.bytes("<g transform=\"rotate(180 53 73)\">");
        try drawIndex(w, c, color);
        try w.bytes("</g>");
    }
}

fn drawIndex(w: *Writer, c: u8, color: []const u8) !void {
    // The rank sits in the top 16 px so it stays readable in the tightest tableau fan.
    try w.fmt("<text x=\"8\" y=\"19\" font-size=\"20\" font-weight=\"700\" fill=\"{s}\">{s}</text>", .{ color, rankText(c) });
    // As on a standard deck, the small suit is centred beneath the rank.
    try drawSuit(w, c, 8 + @divTrunc(rankWidth(c), 2) - 7, 23, 14);
}

fn drawSlot(w: *Writer, x: i32, y: i32, label: []const u8) !void {
    try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"106\" height=\"146\" rx=\"12\" fill=\"#074635\" fill-opacity=\".42\" stroke=\"#b7d8b8\" stroke-opacity=\".34\" stroke-width=\"2\" stroke-dasharray=\"5 6\"/>", .{ x, y });
    try w.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"700\" letter-spacing=\"1.5\" fill=\"#b8ddc2\" opacity=\".7\">{s}</text>", .{ x + 53, y + 78, label });
}

fn drawBoard(w: *Writer) !void {
    try w.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 760\" width=\"1000\" height=\"760\" style=\"font-family:Inter,ui-sans-serif,system-ui,sans-serif;user-select:none\"><defs><linearGradient id=\"felt\" x2=\"0\" y2=\"1\"><stop stop-color=\"#0e6348\"/><stop offset=\"1\" stop-color=\"#074634\"/></linearGradient><linearGradient id=\"face\" x2=\"0\" y2=\"1\"><stop stop-color=\"#fffefa\"/><stop offset=\"1\" stop-color=\"#f2f0e7\"/></linearGradient><pattern id=\"back\" width=\"12\" height=\"12\" patternUnits=\"userSpaceOnUse\"><rect width=\"12\" height=\"12\" fill=\"#204d80\"/><path d=\"M0 0 12 12M12 0 0 12\" stroke=\"#5c87af\" stroke-width=\".7\"/></pattern></defs>");
    try w.bytes("<rect width=\"1000\" height=\"760\" fill=\"url(#felt)\"/><rect x=\"16\" y=\"16\" width=\"968\" height=\"728\" rx=\"22\" fill=\"none\" stroke=\"#9cceac\" opacity=\".2\"/><text x=\"46\" y=\"51\" fill=\"#f5f1dd\" font-size=\"26\" font-weight=\"650\" letter-spacing=\"-.7\">Klondike</text><text x=\"196\" y=\"50\" fill=\"#b8dbc3\" font-size=\"13\" font-weight=\"600\">DRAW ONE</text>");
    try w.bytes("<rect x=\"845\" y=\"24\" width=\"112\" height=\"38\" rx=\"19\" fill=\"#f5edcf\"/><text x=\"901\" y=\"49\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"700\" fill=\"#124735\">New game</text>");
    try w.bytes("<text x=\"46\" y=\"246\" font-size=\"12\" font-weight=\"700\" letter-spacing=\"2\" fill=\"#c7e3ca\">TABLEAU</text>");
    try w.fmt("<text x=\"780\" y=\"246\" text-anchor=\"end\" font-size=\"12\" fill=\"#c7e3ca\">{d} {s}</text>", .{ moves, if (moves == 1) @as([]const u8, "move") else "moves" });
    try drawSlot(w, colX(0), TOP_Y, if (stock.len == 0 and waste.len > 0) "REDEAL" else "STOCK");
    try drawSlot(w, colX(1), TOP_Y, "WASTE");
    if (stock.len > 0) try drawCard(w, null, colX(0), TOP_Y, true);
    if (waste.top()) |card| {
        const dragging_waste = if (drag) |d| d.active and d.source == .waste else false;
        if (dragging_waste) {
            if (waste.len > 1) try drawCard(w, waste.cards[waste.len - 2], colX(1), TOP_Y, false);
        } else try drawCard(w, card, colX(1), TOP_Y, false);
    }
    for (0..4) |f| {
        const x = colX(f + 3);
        try drawSlot(w, x, TOP_Y, suitName(f));
        const dragging_foundation = if (drag) |d| d.active and d.source == .foundation and d.pile == f else false;
        const landing = if (flight) |fl| suit(fl.card) == f else false;
        const shown = foundation[f] - @intFromBool(dragging_foundation or landing) - cascadeLaunched(f);
        if (shown > 0) try drawCard(w, @intCast(f * 13 + shown - 1), x, TOP_Y, false);
    }
    for (0..7) |col| {
        const x = colX(col);
        try drawSlot(w, x, TABLEAU_Y, "");
        const gap = tableauGap(col);
        for (0..tableau[col].len) |i| {
            if (drag) |d| {
                if (d.active and d.source == .tableau and d.pile == col and i >= d.index) continue;
            }
            // A hovered covered card pokes up from its stack to show more of itself.
            const poked = if (hovered) |h| drag == null and h.col == col and h.index == i else false;
            const y = TABLEAU_Y + @as(i32, @intCast(i)) * gap - if (poked) @as(i32, POKE) else 0;
            const hidden = i < face_down[col];
            try drawCard(w, if (hidden) null else tableau[col].cards[i], x, y, hidden);
        }
    }
    if (flight) |f| {
        const pos = flightPos(f);
        try drawCard(w, f.card, pos[0], pos[1], false);
    }
    if (drag) |d| {
        if (d.active) {
            const x = d.x - d.offset_x;
            const y = d.y - d.offset_y;
            if (d.source == .tableau) {
                const gap = tableauGap(d.pile);
                for (d.index..tableau[d.pile].len) |i|
                    try drawCard(w, tableau[d.pile].cards[i], x, y + @as(i32, @intCast(i - d.index)) * gap, false);
            } else {
                try drawCard(w, sourceCard(d), x, y, false);
            }
        }
    }
    try drawCascade(w);
    if (cascade_at != null and !cascadeRunning(committed_at)) {
        try w.fmt("<rect x=\"315\" y=\"306\" width=\"370\" height=\"160\" rx=\"22\" fill=\"#f8f0d8\"/><text x=\"500\" y=\"356\" text-anchor=\"middle\" font-size=\"29\" font-weight=\"700\" fill=\"#114b38\">You won!</text><text x=\"500\" y=\"385\" text-anchor=\"middle\" font-size=\"15\" fill=\"#416e5b\">Finished in {d} moves.</text>", .{moves});
        try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"112\" height=\"38\" rx=\"19\" fill=\"#124735\"/><text x=\"500\" y=\"{d}\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"700\" fill=\"#f5edcf\">New game</text>", .{ WIN_BUTTON_X, WIN_BUTTON_Y, WIN_BUTTON_Y + 25 });
    }
    try w.bytes("<text x=\"46\" y=\"715\" font-size=\"13\" fill=\"#b9dbc2\">Drag cards to move · Click a top card to send it to a foundation · Click stock to draw</text></svg>");
}

test "draw one and recycle keep all cards" {
    newGame(123);
    try std.testing.expectEqual(@as(u8, 24), stock.len);
    for (0..24) |_| try std.testing.expect(drawStock());
    try std.testing.expectEqual(@as(u8, 0), stock.len);
    try std.testing.expectEqual(@as(u8, 24), waste.len);
    try std.testing.expect(drawStock());
    try std.testing.expectEqual(@as(u8, 24), stock.len);
    try std.testing.expectEqual(@as(u8, 0), waste.len);
}

test "tableau moves reveal the newly exposed card" {
    newGame(123);
    tableau[0] = .{};
    tableau[1] = .{};
    tableau[0].push(0); // Face-down ace of spades.
    tableau[0].push(24); // Queen of hearts
    face_down[0] = 1;
    const d = Drag{ .source = .tableau, .pile = 0, .index = 1, .start_x = 0, .start_y = 0, .x = 0, .y = 0, .offset_x = 0, .offset_y = 0 };
    tableau[1].push(25); // King of hearts cannot take a red queen.
    try std.testing.expect(!moveToTableau(d, 1));
    tableau[1].cards[0] = 51; // Black king can take the red queen.
    try std.testing.expect(moveToTableau(d, 1));
    try std.testing.expectEqual(@as(u8, 0), face_down[0]);
    try std.testing.expectEqual(@as(u8, 2), tableau[1].len);
}

test "foundations accept one card at a time in suit order" {
    newGame(321);
    waste = .{};
    waste.push(13); // Ace of hearts.
    const ace = Drag{ .source = .waste, .pile = 0, .index = 0, .start_x = 0, .start_y = 0, .x = 0, .y = 0, .offset_x = 0, .offset_y = 0 };
    try std.testing.expect(moveToFoundation(ace));
    try std.testing.expectEqual(@as(u8, 1), foundation[1]);
    try std.testing.expectEqual(@as(u8, 0), waste.len);
    waste.push(15); // Three of hearts cannot skip the two.
    try std.testing.expect(!moveToFoundation(ace));
    try std.testing.expectEqual(@as(u8, 1), foundation[1]);
    try std.testing.expectEqual(@as(u8, 1), waste.len);
}

test "a win cascades every card off the foundations and fits the output" {
    newGame(777);
    initialized = true;
    stock = .{};
    waste = .{};
    tableau = [_]Pile{.{}} ** 7;
    foundation = [_]u8{13} ** 4;
    committed_at = 1000;
    begin_update_at(2000);
    try std.testing.expectEqual(@as(i64, 2016), finish_update());
    try std.testing.expectEqual(@as(?i64, 2000), cascade_at);
    begin_update_at(2500);
    _ = finish_update();
    try std.testing.expectEqual(@as(u8, 1), cascadeLaunched(0));
    try std.testing.expectEqual(@as(u8, 1), cascadeLaunched(2));
    try std.testing.expectEqual(@as(u8, 0), cascadeLaunched(3));
    _ = render(0);
    begin_update_at(2600);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(1, 500, 500)); // Skip.
    try std.testing.expectEqual(@as(i64, 2600), finish_update());
    const packed_out = render(0);
    const svg = output_buf[0..@as(u32, @truncate(packed_out))];
    try std.testing.expect(std.mem.indexOf(u8, svg, "You won!") != null);
    for (0..4) |f| try std.testing.expectEqual(@as(u8, 13), cascadeLaunched(f));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, svg, "New game")); // Header and panel buttons.
    begin_update_at(2700);
    try std.testing.expectEqual(@as(i32, 0), pointer_event(0, 500, 425)); // Release from the skip.
    _ = finish_update();
    begin_update_at(2800);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(1, 500, 425)); // Panel button deals again.
    _ = finish_update();
    try std.testing.expectEqual(@as(?i64, null), cascade_at);
    try std.testing.expectEqual(@as(u8, 0), foundation[0]);
}
