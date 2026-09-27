const std = @import("std");

const CARD_W = 106;
const CARD_H = 146;
const PILE_Y = 218;
const DECK_X = 824;
const DECK_Y = 220;
const DISCARD_Y = 418;
const DEAL_STEP_MS: i64 = 75;
const OUTPUT_CAP = 96 * 1024;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";
const PRIMARY = 1;
const KEY_DOWN = 1;

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

const GameState = enum { playing, won, stuck };
const Drag = struct {
    pile: u8,
    start_x: i32,
    start_y: i32,
    x: i32,
    y: i32,
    offset_x: i32,
    offset_y: i32,
    active: bool = false,
};

var deck: [52]u8 = undefined;
var deck_pos: u8 = 0;
var piles = [_]Pile{.{}} ** 4;
var discarded: u8 = 0;
var last_discard: ?u8 = null;
var selected: ?u8 = null;
var drag: ?Drag = null;
var primary_down = false;
var game_state: GameState = .playing;
var dealing = false;
var next_deal_pile: u8 = 0;
var next_deal_at: i64 = 0;
var seed: u32 = 0x7ac3e521;
var games: u32 = 0;
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

export fn render(input_size: u32) u64 {
    if (input_size != 0 or updating) @trap();
    if (!initialized) {
        newGame(seed, 0);
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
    advanceDeal(now_ms);
}

export fn finish_update() i64 {
    if (!updating) @trap();
    updating = false;
    committed_at = begun_at;
    return if (dealing) next_deal_at else begun_at;
}

export fn key_event(key: i32, flags: i32) i32 {
    if (!updating) @trap();
    if ((flags & KEY_DOWN) == 0) return 0;
    if (key == 'r' or key == 'R' or key == 'n' or key == 'N') {
        restart();
        return 1;
    }
    if (key == ' ' or key == 0xff0d) return @intFromBool(startDeal(begun_at));
    return 0;
}

export fn pointer_event(mask: i32, x: i32, y: i32) i32 {
    if (!updating) @trap();
    const down = (mask & PRIMARY) != 0;
    defer primary_down = down;
    if (down and !primary_down) {
        if (inside(x, y, 848, 24, 112, 38)) {
            restart();
            return 1;
        }
        if (inside(x, y, DECK_X, DECK_Y, CARD_W, CARD_H)) return @intFromBool(startDeal(begun_at));
        if (emptyPileAt(x, y)) |target| {
            if (selected) |source| return @intFromBool(moveToEmpty(source, target));
        }
        drag = hitTop(x, y);
        return 0;
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
                if (emptyPileAt(x, y)) |target| {
                    _ = moveToEmpty(d.pile, target);
                } else if (inside(x, y, DECK_X - 18, DISCARD_Y - 18, CARD_W + 36, CARD_H + 36)) {
                    _ = discardTop(d.pile);
                }
                return 1; // Remove the floating card after any drop.
            }
            if (discardTop(d.pile)) return 1;
            if (hasEmptyPile()) {
                selected = if (selected != null and selected.? == d.pile) null else d.pile;
                return 1;
            }
        }
    }
    return 0;
}

fn restart() void {
    const time_bits: u32 = @truncate(@as(u64, @bitCast(begun_at)));
    newGame(seed ^ time_bits ^ (games *% 0x9e3779b9), begun_at);
}

fn nextRandom() u32 {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

fn newGame(value: u32, now: i64) void {
    seed = if (value == 0) 0x7ac3e521 else value;
    games +%= 1;
    for (&deck, 0..) |*card, i| card.* = @intCast(i);
    var i: usize = deck.len - 1;
    while (i > 0) : (i -= 1) {
        const j: usize = nextRandom() % @as(u32, @intCast(i + 1));
        std.mem.swap(u8, &deck[i], &deck[j]);
    }
    deck_pos = 0;
    piles = [_]Pile{.{}} ** 4;
    discarded = 0;
    last_discard = null;
    selected = null;
    drag = null;
    game_state = .playing;
    dealing = false;
    _ = startDealUnchecked(now);
}

fn startDealUnchecked(now: i64) bool {
    if (deck_pos + 4 > 52) return false;
    selected = null;
    piles[0].push(deck[deck_pos]);
    deck_pos += 1;
    dealing = true;
    next_deal_pile = 1;
    next_deal_at = now + DEAL_STEP_MS;
    return true;
}

fn startDeal(now: i64) bool {
    if (!canDeal()) return false;
    return startDealUnchecked(now);
}

fn advanceDeal(now: i64) void {
    if (!dealing or now < next_deal_at) return;
    piles[next_deal_pile].push(deck[deck_pos]);
    deck_pos += 1;
    next_deal_pile += 1;
    if (next_deal_pile == 4) {
        dealing = false;
        updateGameState();
    } else next_deal_at = now + DEAL_STEP_MS;
}

fn canDeal() bool {
    return game_state == .playing and !dealing and deck_pos + 4 <= 52 and !hasDiscardable();
}

fn hasEmptyPile() bool {
    for (piles) |pile| if (pile.len == 0) return true;
    return false;
}

fn hasDiscardable() bool {
    for (0..4) |i| if (isDiscardable(i)) return true;
    return false;
}

fn rank(card: u8) u8 {
    const raw = card % 13 + 1;
    return if (raw == 1) 14 else raw;
}
fn suit(card: u8) u8 {
    return card / 13;
}
fn red(card: u8) bool {
    return suit(card) == 1 or suit(card) == 2;
}

fn isDiscardable(pile_index: usize) bool {
    const card = piles[pile_index].top() orelse return false;
    for (0..4) |other_index| {
        if (other_index == pile_index) continue;
        const other = piles[other_index].top() orelse continue;
        if (suit(card) == suit(other) and rank(card) < rank(other)) return true;
    }
    return false;
}

fn discardTop(pile_index: usize) bool {
    if (game_state != .playing or dealing or !isDiscardable(pile_index)) return false;
    last_discard = piles[pile_index].pop();
    discarded += 1;
    selected = null;
    updateGameState();
    return true;
}

fn moveToEmpty(source: usize, target: usize) bool {
    if (game_state != .playing or dealing or source == target or piles[source].len == 0 or piles[target].len != 0) return false;
    piles[target].push(piles[source].pop());
    selected = null;
    updateGameState();
    return true;
}

fn updateGameState() void {
    if (deck_pos < 52) {
        game_state = .playing;
        return;
    }
    var total: usize = 0;
    var aces: usize = 0;
    for (piles) |pile| {
        total += pile.len;
        if (pile.top()) |card| if (rank(card) == 14) {
            aces += 1;
        };
    }
    if (total == 4 and aces == 4) {
        game_state = .won;
    } else if (!hasDiscardable() and !hasEmptyPile()) {
        game_state = .stuck;
    } else game_state = .playing;
}

fn pileX(i: usize) i32 {
    return 70 + @as(i32, @intCast(i)) * 176;
}
fn stackGap(i: usize) i32 {
    const count: i32 = piles[i].len;
    if (count <= 1) return 29;
    return @max(6, @min(29, @divTrunc(700 - PILE_Y - CARD_H, count - 1)));
}
fn inside(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}
fn emptyPileAt(x: i32, y: i32) ?u8 {
    for (0..4) |i| {
        if (piles[i].len == 0 and inside(x, y, pileX(i) - 15, PILE_Y - 15, CARD_W + 30, CARD_H + 30)) return @intCast(i);
    }
    return null;
}
fn hitTop(x: i32, y: i32) ?Drag {
    if (game_state != .playing or dealing) return null;
    for (0..4) |i| {
        if (piles[i].len == 0) continue;
        const card_y = PILE_Y + @as(i32, piles[i].len - 1) * stackGap(i);
        if (inside(x, y, pileX(i), card_y, CARD_W, CARD_H)) {
            return .{ .pile = @intCast(i), .start_x = x, .start_y = y, .x = x, .y = y, .offset_x = x - pileX(i), .offset_y = y - card_y };
        }
    }
    return null;
}

const Writer = struct {
    n: usize = 0,
    fn bytes(w: *Writer, s: []const u8) !void {
        if (s.len > OUTPUT_CAP - w.n) return error.Full;
        @memcpy(output_buf[w.n..][0..s.len], s);
        w.n += s.len;
    }
    fn fmt(w: *Writer, comptime format: []const u8, args: anytype) !void {
        const printed = std.fmt.bufPrint(output_buf[w.n..], format, args) catch return error.Full;
        w.n += printed.len;
    }
};

fn rankText(card: u8) []const u8 {
    return switch (rank(card)) {
        14 => "A",
        13 => "K",
        12 => "Q",
        11 => "J",
        10 => "10",
        else => |r| (&[_][]const u8{ "", "", "2", "3", "4", "5", "6", "7", "8", "9" })[r],
    };
}
fn suitText(card: u8) []const u8 {
    return (&[_][]const u8{ "♠", "♥", "♦", "♣" })[suit(card)];
}

fn drawCard(w: *Writer, card: ?u8, x: i32, y: i32, back: bool) !void {
    try w.fmt("<g transform=\"translate({d} {d})\">", .{ x, y });
    try w.bytes("<rect x=\"2\" y=\"5\" width=\"106\" height=\"146\" rx=\"12\" fill=\"#06281f\" opacity=\".28\"/>");
    if (back) {
        try w.bytes("<rect width=\"106\" height=\"146\" rx=\"12\" fill=\"#fbf7ec\" stroke=\"#d6d3c7\"/><rect x=\"5\" y=\"5\" width=\"96\" height=\"136\" rx=\"8\" fill=\"#183f76\"/><rect x=\"10\" y=\"10\" width=\"86\" height=\"126\" rx=\"5\" fill=\"url(#back)\" stroke=\"#9ab9dc\" stroke-width=\"1.2\"/><path d=\"M53 26 78 73 53 120 28 73Z\" fill=\"none\" stroke=\"#b7d4ed\" stroke-width=\"2\"/><circle cx=\"53\" cy=\"73\" r=\"18\" fill=\"#f4e7bd\"/><path d=\"M53 58 65 73 53 88 41 73Z\" fill=\"#204d80\"/>");
    } else if (card) |c| {
        const color = if (red(c)) "#bd3b42" else "#1c3144";
        try w.bytes("<rect width=\"106\" height=\"146\" rx=\"12\" fill=\"url(#face)\" stroke=\"#d2d2cb\"/>");
        try w.fmt("<text x=\"11\" y=\"30\" font-size=\"25\" font-weight=\"700\" fill=\"{s}\">{s}</text>", .{ color, rankText(c) });
        try w.fmt("<text x=\"12\" y=\"51\" font-size=\"21\" fill=\"{s}\">{s}</text>", .{ color, suitText(c) });
        try w.fmt("<text x=\"53\" y=\"94\" text-anchor=\"middle\" font-size=\"49\" fill=\"{s}\">{s}</text>", .{ color, suitText(c) });
        try w.fmt("<text x=\"94\" y=\"137\" text-anchor=\"end\" font-size=\"19\" font-weight=\"700\" fill=\"{s}\">{s}</text>", .{ color, rankText(c) });
    }
    try w.bytes("</g>");
}

fn drawSlot(w: *Writer, x: i32, y: i32, label: []const u8) !void {
    try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"106\" height=\"146\" rx=\"12\" fill=\"#074635\" fill-opacity=\".42\" stroke=\"#b7d8b8\" stroke-opacity=\".34\" stroke-width=\"2\" stroke-dasharray=\"5 6\"/>", .{ x, y });
    try w.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"700\" letter-spacing=\"1.5\" fill=\"#b8ddc2\" opacity=\".7\">{s}</text>", .{ x + 53, y + 78, label });
}

fn drawBoard(w: *Writer) !void {
    try w.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 760\" width=\"1000\" height=\"760\" style=\"font-family:Inter,ui-sans-serif,system-ui,sans-serif;user-select:none\"><defs><linearGradient id=\"felt\" x2=\"0\" y2=\"1\"><stop stop-color=\"#0e6348\"/><stop offset=\"1\" stop-color=\"#074634\"/></linearGradient><linearGradient id=\"face\" x2=\"0\" y2=\"1\"><stop stop-color=\"#fffefa\"/><stop offset=\"1\" stop-color=\"#f2f0e7\"/></linearGradient><pattern id=\"back\" width=\"12\" height=\"12\" patternUnits=\"userSpaceOnUse\"><rect width=\"12\" height=\"12\" fill=\"#204d80\"/><path d=\"M0 0 12 12M12 0 0 12\" stroke=\"#5c87af\" stroke-width=\".7\"/></pattern></defs>");
    try w.bytes("<rect width=\"1000\" height=\"760\" fill=\"url(#felt)\"/><rect x=\"16\" y=\"16\" width=\"968\" height=\"728\" rx=\"22\" fill=\"none\" stroke=\"#9cceac\" opacity=\".2\"/><text x=\"46\" y=\"51\" fill=\"#f5f1dd\" font-size=\"26\" font-weight=\"650\" letter-spacing=\"-.7\">Aces Up</text><text x=\"186\" y=\"50\" fill=\"#b8dbc3\" font-size=\"13\" font-weight=\"600\">IDIOT’S DELIGHT</text>");
    try w.bytes("<rect x=\"848\" y=\"24\" width=\"112\" height=\"38\" rx=\"19\" fill=\"#f5edcf\"/><text x=\"904\" y=\"49\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"700\" fill=\"#124735\">New game</text>");
    try w.bytes("<text x=\"70\" y=\"191\" font-size=\"12\" font-weight=\"700\" letter-spacing=\"2\" fill=\"#c7e3ca\">FOUR PILES</text><text x=\"824\" y=\"191\" font-size=\"12\" font-weight=\"700\" letter-spacing=\"2\" fill=\"#c7e3ca\">DECK</text>");
    try w.fmt("<text x=\"46\" y=\"97\" font-size=\"16\" fill=\"#f2efda\">{d} discarded</text>", .{discarded});
    try w.fmt("<text x=\"46\" y=\"124\" font-size=\"14\" fill=\"#bbdac5\">{s}</text>", .{statusText()});
    for (0..4) |i| {
        const x = pileX(i);
        try drawSlot(w, x, PILE_Y, "EMPTY");
        const gap = stackGap(i);
        for (0..piles[i].len) |index| {
            const is_dragged = if (drag) |d| d.active and d.pile == i and index == piles[i].len - 1 else false;
            if (!is_dragged) try drawCard(w, piles[i].cards[index], x, PILE_Y + @as(i32, @intCast(index)) * gap, false);
        }
        if (piles[i].len > 0) {
            const top_y = PILE_Y + @as(i32, piles[i].len - 1) * gap;
            const is_dragged = if (drag) |d| d.active and d.pile == i else false;
            if (!is_dragged and isDiscardable(i))
                try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"106\" height=\"146\" rx=\"12\" fill=\"none\" stroke=\"#f2c96f\" stroke-width=\"3\"/>", .{ x, top_y });
            if (!is_dragged and selected != null and selected.? == i)
                try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"106\" height=\"146\" rx=\"12\" fill=\"none\" stroke=\"#8acbf1\" stroke-width=\"3\"/>", .{ x, top_y });
        }
    }
    try drawSlot(w, DECK_X, DECK_Y, if (deck_pos == 52) "EMPTY" else "DEAL");
    if (deck_pos < 52) try drawCard(w, null, DECK_X, DECK_Y, true);
    try w.fmt("<text x=\"877\" y=\"389\" text-anchor=\"middle\" font-size=\"13\" fill=\"#cce5ce\">{d} left</text>", .{52 - deck_pos});
    try drawSlot(w, DECK_X, DISCARD_Y, "DISCARD");
    if (last_discard) |card| try drawCard(w, card, DECK_X, DISCARD_Y, false);
    if (drag) |d| {
        if (d.active) try drawCard(w, piles[d.pile].top().?, d.x - d.offset_x, d.y - d.offset_y, false);
    }
    if (game_state != .playing and !dealing) try drawEndOverlay(w);
    try w.bytes("<text x=\"46\" y=\"715\" font-size=\"13\" fill=\"#b9dbc2\">Click gold cards to discard · Drag a top card into an empty pile · Click deck to deal</text></svg>");
}

fn statusText() []const u8 {
    if (dealing) return "Dealing a row…";
    if (game_state == .won) return "Four aces remain. You won.";
    if (game_state == .stuck) return "No moves remain. Start a new game.";
    if (hasDiscardable()) return "Remove a gold-highlighted card.";
    if (hasEmptyPile()) return "Move a top card into the empty pile, or deal.";
    if (deck_pos < 52) return "Deal the next row.";
    return "Keep the four aces.";
}

fn drawEndOverlay(w: *Writer) !void {
    const won = game_state == .won;
    try w.bytes("<rect x=\"290\" y=\"356\" width=\"420\" height=\"134\" rx=\"22\" fill=\"#f8f0d8\" stroke=\"#d5c99f\"/>");
    try w.fmt("<text x=\"500\" y=\"411\" text-anchor=\"middle\" font-size=\"29\" font-weight=\"700\" fill=\"#114b38\">{s}</text>", .{if (won) @as([]const u8, "Four aces remain!") else "No moves remain"});
    try w.fmt("<text x=\"500\" y=\"448\" text-anchor=\"middle\" font-size=\"15\" fill=\"#416e5b\">{s}</text>", .{if (won) @as([]const u8, "You won. Start a new game to play again.") else "Start a new game to try another deal."});
}

test "same-suit lower top card is discardable, with aces high" {
    newGame(12, 0);
    dealing = false;
    piles = [_]Pile{.{}} ** 4;
    piles[0].push(1); // Two of spades.
    piles[1].push(12); // King of spades.
    try std.testing.expect(isDiscardable(0));
    try std.testing.expect(!isDiscardable(1));
    piles[2].push(0); // Ace of spades.
    try std.testing.expect(isDiscardable(1));
    try std.testing.expect(!isDiscardable(2));
}

test "deal allows empty piles but waits for available discards" {
    newGame(12, 0);
    dealing = false;
    piles = [_]Pile{.{}} ** 4;
    for (0..4) |i| piles[i].push(@intCast(i * 13));
    try std.testing.expect(canDeal());
    _ = piles[0].pop();
    try std.testing.expect(canDeal());
    piles[0].push(1);
    piles[1] = .{};
    piles[1].push(12);
    try std.testing.expect(!canDeal());
}

test "four-card deal advances one card at each wake" {
    newGame(12, 0);
    try std.testing.expectEqual(@as(u8, 1), deck_pos);
    advanceDeal(74);
    try std.testing.expectEqual(@as(u8, 1), deck_pos);
    advanceDeal(75);
    try std.testing.expectEqual(@as(u8, 2), deck_pos);
    advanceDeal(150);
    advanceDeal(225);
    try std.testing.expectEqual(@as(u8, 4), deck_pos);
    try std.testing.expect(!dealing);
}

test "four aces win and a blocked final row ends the game" {
    newGame(12, 0);
    dealing = false;
    deck_pos = 52;
    piles = [_]Pile{.{}} ** 4;
    for (0..4) |i| piles[i].push(@intCast(i * 13));
    updateGameState();
    try std.testing.expectEqual(GameState.won, game_state);

    piles[0].cards[0] = 1; // Two of spades, with no higher spade showing.
    updateGameState();
    try std.testing.expectEqual(GameState.stuck, game_state);
}
