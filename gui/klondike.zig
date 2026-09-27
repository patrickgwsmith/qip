const std = @import("std");

const W = 1000;
const H = 760;
const CARD_W = 106;
const CARD_H = 146;
const LEFT = 46;
const GAP = 34;
const TOP_Y = 82;
const TABLEAU_Y = 292;
const OUTPUT_CAP = 96 * 1024;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";
const PRIMARY = 1;
const KEY_DOWN = 1;
const DEFAULT_SEED: u32 = 0x482ce17b;

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

var stock = Pile{};
var waste = Pile{};
var tableau = [_]Pile{.{}} ** 7;
var face_down = [_]u8{0} ** 7;
var foundation = [_]u8{0} ** 4;
var drag: ?Drag = null;
var hovered: ?Hover = null;
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
    return committed_at;
}

export fn key_event(key: i32, flags: i32) i32 {
    if (!updating) @trap();
    if ((flags & KEY_DOWN) == 0) return 0;
    if (key == 'n' or key == 'N' or key == 'r' or key == 'R') {
        const time_bits: u32 = @truncate(@as(u64, @bitCast(begun_at)));
        newGame(requested_seed ^ time_bits ^ (deals *% 0x9e3779b9));
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
    if (down and !primary_down) {
        const had_hover = hovered != null;
        hovered = null;
        if (inside(x, y, 845, 24, 112, 38)) {
            const time_bits: u32 = @truncate(@as(u64, @bitCast(begun_at)));
            newGame(requested_seed ^ time_bits ^ (deals *% 0x9e3779b9));
            return 1;
        }
        if (inside(x, y, colX(0), TOP_Y, CARD_W, CARD_H)) return @intFromBool(drawStock() or had_hover);
        drag = hitCard(x, y);
        return @intFromBool(drag != null or had_hover);
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

fn autoFoundation(d: Drag) bool {
    return moveToFoundation(d);
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
    if (back) {
        try w.bytes("<rect width=\"106\" height=\"146\" rx=\"12\" fill=\"#fbf7ec\" stroke=\"#d6d3c7\"/><rect x=\"5\" y=\"5\" width=\"96\" height=\"136\" rx=\"8\" fill=\"#183f76\"/><rect x=\"10\" y=\"10\" width=\"86\" height=\"126\" rx=\"5\" fill=\"url(#back)\" stroke=\"#9ab9dc\" stroke-width=\"1.2\"/><path d=\"M53 26 78 73 53 120 28 73Z\" fill=\"none\" stroke=\"#b7d4ed\" stroke-width=\"2\"/><circle cx=\"53\" cy=\"73\" r=\"18\" fill=\"#f4e7bd\"/><path d=\"M53 58 65 73 53 88 41 73Z\" fill=\"#204d80\"/>");
    } else if (card) |c| {
        const color = if (red(c)) "#bd3b42" else "#1c3144";
        try w.bytes("<rect width=\"106\" height=\"146\" rx=\"12\" fill=\"url(#face)\" stroke=\"#d2d2cb\"/>");
        try w.fmt("<text x=\"11\" y=\"30\" font-size=\"25\" font-weight=\"700\" fill=\"{s}\">{s}</text>", .{ color, rankText(c) });
        try drawSuit(w, c, 11, 34, 21);
        try drawSuit(w, c, 29, 51, 49);
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
        if (foundation[f] > 0 and !dragging_foundation) try drawCard(w, @intCast(f * 13 + foundation[f] - 1), x, TOP_Y, false);
    }
    for (0..7) |col| {
        const x = colX(col);
        try drawSlot(w, x, TABLEAU_Y, "");
        const gap = tableauGap(col);
        for (0..tableau[col].len) |i| {
            if (drag) |d| {
                if (d.active and d.source == .tableau and d.pile == col and i >= d.index) continue;
            }
            const y = TABLEAU_Y + @as(i32, @intCast(i)) * gap;
            const hidden = i < face_down[col];
            try drawCard(w, if (hidden) null else tableau[col].cards[i], x, y, hidden);
        }
    }
    if (hovered) |h| {
        if (drag == null) try drawCard(w, tableau[h.col].cards[h.index], colX(h.col) + 8, TABLEAU_Y + @as(i32, @intCast(h.index)) * tableauGap(h.col) - 8, false);
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
    var won = true;
    for (foundation) |n| if (n != 13) {
        won = false;
    };
    if (won) {
        try w.bytes("<rect x=\"315\" y=\"326\" width=\"370\" height=\"120\" rx=\"22\" fill=\"#f8f0d8\"/><text x=\"500\" y=\"380\" text-anchor=\"middle\" font-size=\"29\" font-weight=\"700\" fill=\"#114b38\">You won!</text><text x=\"500\" y=\"411\" text-anchor=\"middle\" font-size=\"15\" fill=\"#416e5b\">Start a new game to play again.</text>");
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
