const std = @import("std");
const ui_font = @import("assets/inter_display_chart_ascii.zig");

// A virtualized orders table: 1,000 rows, 17 rendered at a time, with sort,
// type-to-filter, keyboard row navigation and hover. It is shaped like the
// grids React apps build with react-window or TanStack Table, so the SVG DOM
// update benchmark can compare keyed patching with full replacement.

const DISPLAY_W: i32 = 820;
const DISPLAY_H: i32 = 540;
const OUTPUT_CAP: usize = 65536;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const ROW_COUNT: usize = 1000;
const VISIBLE_ROWS: usize = 17;
const ROW_H: i32 = 24;
const GRID_X: i32 = 24;
const COLUMNS_END_X: i32 = 780;
const SCROLLBAR_X: i32 = 784;
const SCROLLBAR_W: i32 = 12;
const HEADER_Y: i32 = 62;
const HEADER_H: i32 = 30;
const BODY_Y: i32 = HEADER_Y + HEADER_H;
const BODY_H: i32 = ROW_H * @as(i32, VISIBLE_ROWS);
const FOOTER_Y: i32 = BODY_Y + BODY_H + 14;
const FILTER_X: i32 = 536;
const FILTER_Y: i32 = 14;
const FILTER_W: i32 = 260;
const FILTER_H: i32 = 30;
const FILTER_CAP: usize = 24;
const CELL_PAD_X: i32 = 10;
const ROW_TEXT_BASELINE: i32 = 16;
// The saved Inter advances were measured at 28 px; this SVG uses 13 px.
const FONT_SIZE: i32 = 13;
const FONT_METRIC_SIZE: i32 = 28;

const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_CONTROL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_HOME: i32 = 0xFF50;
const XK_UP: i32 = 0xFF52;
const XK_DOWN: i32 = 0xFF54;
const XK_PAGE_UP: i32 = 0xFF55;
const XK_PAGE_DOWN: i32 = 0xFF56;
const XK_END: i32 = 0xFF57;

const C_BG = "#080A12";
const C_PANEL = "#101422";
const C_HEADER = "#161B2C";
const C_HEADER_ACTIVE = "#22305A";
const C_STRIPE = "#0D111C";
const C_HOVER = "#1A2236";
const C_CURSOR = "#2B4278";
const C_ACCENT = "#8FB4FF";
const C_INK = "#F4F7FB";
const C_MUTED = "#A4AEC0";
const C_GRID = "#323A4C";

const Column = struct { label: []const u8, x: i32, w: i32, right: bool = false };
const COLUMNS = [_]Column{
    .{ .label = "Order", .x = GRID_X, .w = 78 },
    .{ .label = "Customer", .x = 102, .w = 196 },
    .{ .label = "Region", .x = 298, .w = 104 },
    .{ .label = "Status", .x = 402, .w = 116 },
    .{ .label = "Date", .x = 518, .w = 112 },
    .{ .label = "Amount", .x = 630, .w = COLUMNS_END_X - 630, .right = true },
};
const COL_ORDER: usize = 0;
const COL_CUSTOMER: usize = 1;
const COL_REGION: usize = 2;
const COL_STATUS: usize = 3;
const COL_DATE: usize = 4;
const COL_AMOUNT: usize = 5;

const FIRST_NAMES = [_][]const u8{ "Avery", "Blake", "Casey", "Devon", "Emery", "Finley", "Harper", "Jordan", "Kai", "Logan", "Morgan", "Parker", "Quinn", "Riley", "Sage", "Taylor" };
const LAST_NAMES = [_][]const u8{ "Adams", "Brooks", "Chen", "Diaz", "Evans", "Fischer", "Garcia", "Hughes", "Ito", "Jensen", "Khan", "Lopez", "Moreau", "Nakamura", "Okafor", "Patel" };
const REGIONS = [_][]const u8{ "North", "South", "East", "West", "Central" };
const Status = struct { label: []const u8, fill: []const u8, ink: []const u8 };
const STATUSES = [_]Status{
    .{ .label = "Pending", .fill = "#4A3A12", .ink = "#FFD27A" },
    .{ .label = "Paid", .fill = "#16305A", .ink = "#9CC2FF" },
    .{ .label = "Shipped", .fill = "#123F33", .ink = "#7FE3C4" },
    .{ .label = "Refunded", .fill = "#3A2152", .ink = "#D1A8FF" },
    .{ .label = "Cancelled", .fill = "#47201F", .ink = "#FF9C94" },
};
// Days in each month of 2026 up to September; order dates cover that span.
const MONTH_DAYS = [_]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30 };
const DATE_SPAN_DAYS: u32 = 273;

const Order = struct {
    id: u32,
    first: u8,
    last: u8,
    region: u8,
    status: u8,
    day: u16,
    cents: u32,
};

const ORDERS: [ROW_COUNT]Order = blk: {
    @setEvalBranchQuota(200_000);
    var rows: [ROW_COUNT]Order = undefined;
    var seed: u32 = 0x9E37_79B9;
    for (&rows, 0..) |*row, i| {
        seed = xorshift32(seed);
        const a = seed;
        seed = xorshift32(seed);
        const b = seed;
        row.* = .{
            .id = 10001 + @as(u32, i),
            .first = @intCast(a % FIRST_NAMES.len),
            .last = @intCast((a >> 8) % LAST_NAMES.len),
            .region = @intCast((a >> 16) % REGIONS.len),
            .status = @intCast((a >> 20) % STATUSES.len),
            .day = @intCast(b % DATE_SPAN_DAYS),
            .cents = 999 + (b >> 9) % 50_000 * (1 + (b >> 4) % 5),
        };
    }
    break :blk rows;
};

var output_buf: [OUTPUT_CAP]u8 = undefined;
var view: [ROW_COUNT]u16 = undefined;
var view_len: usize = 0;
var view_built = false;
var sort_col: usize = COL_ORDER;
var sort_desc = false;
var filter_buf: [FILTER_CAP]u8 = undefined;
var filter_len: usize = 0;
var cursor: usize = 0;
var scroll_top: usize = 0;
// Hover is a visible slot, so scrolling under a still pointer hovers the new row.
var hover_slot: ?usize = null;
var primary_down = false;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

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

export fn begin_update_at(now_ms: i64) void {
    if (transaction_phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    const page: i32 = @intCast(VISIBLE_ROWS);
    const changed = switch (x11_key) {
        XK_UP => moveCursor(-1),
        XK_DOWN => moveCursor(1),
        XK_PAGE_UP => moveCursor(-page),
        XK_PAGE_DOWN => moveCursor(page),
        XK_HOME => moveCursor(-@as(i32, ROW_COUNT)),
        XK_END => moveCursor(@as(i32, ROW_COUNT)),
        XK_BACKSPACE => popFilter(),
        XK_ESCAPE => clearFilter(),
        else => x11_key >= 0x20 and x11_key <= 0x7E and (flags & (FLAG_CONTROL | FLAG_ALT | FLAG_META)) == 0 and pushFilter(@intCast(x11_key)),
    };
    return if (changed) 1 else 0;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    const slot = slotAt(x, y);
    if (!std.meta.eql(hover_slot, slot)) {
        hover_slot = slot;
        changed = true;
    }
    if (down and !primary_down) {
        if (headerColumnAt(x, y)) |col| {
            changed = sortBy(col) or changed;
        } else if (slot) |s| {
            changed = moveCursorTo(scroll_top + s) or changed;
        } else if (x >= SCROLLBAR_X and x < SCROLLBAR_X + SCROLLBAR_W and y >= BODY_Y and y < BODY_Y + BODY_H) {
            const page: i32 = @intCast(VISIBLE_ROWS);
            changed = moveCursor(if (y < thumbY()) -page else page) or changed;
        }
    }
    primary_down = down;
    return if (changed) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    if (!view_built) rebuildView();
    var writer = Writer{};
    drawFrame(&writer) catch @trap();
    transaction_phase = .ready;
    return @intCast(writer.n);
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
    committed_at_ms = begun_at_ms;
    transaction_phase = .ready;
    return begun_at_ms;
}

fn moveCursor(delta: i32) bool {
    if (view_len == 0) return false;
    const last: i64 = @intCast(view_len - 1);
    const next = std.math.clamp(@as(i64, @intCast(cursor)) + delta, 0, last);
    return moveCursorTo(@intCast(next));
}

fn moveCursorTo(index: usize) bool {
    if (index >= view_len or index == cursor) return false;
    cursor = index;
    if (cursor < scroll_top) scroll_top = cursor;
    if (cursor >= scroll_top + VISIBLE_ROWS) scroll_top = cursor + 1 - VISIBLE_ROWS;
    return true;
}

fn sortBy(col: usize) bool {
    if (col == sort_col) {
        sort_desc = !sort_desc;
    } else {
        sort_col = col;
        sort_desc = false;
    }
    rebuildView();
    return true;
}

fn pushFilter(byte: u8) bool {
    if (filter_len >= FILTER_CAP) return false;
    filter_buf[filter_len] = byte;
    filter_len += 1;
    rebuildView();
    return true;
}

fn popFilter() bool {
    if (filter_len == 0) return false;
    filter_len -= 1;
    rebuildView();
    return true;
}

fn clearFilter() bool {
    if (filter_len == 0) return false;
    filter_len = 0;
    rebuildView();
    return true;
}

// Sorting and filtering return to the first row, as most data grids do.
fn rebuildView() void {
    view_len = 0;
    const needle = filter_buf[0..filter_len];
    for (ORDERS, 0..) |order, index| {
        if (matchesFilter(order, needle)) {
            view[view_len] = @intCast(index);
            view_len += 1;
        }
    }
    std.mem.sort(u16, view[0..view_len], {}, orderLessThan);
    cursor = 0;
    scroll_top = 0;
    view_built = true;
}

fn matchesFilter(order: Order, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var name_buf: [32]u8 = undefined;
    return containsIgnoreCase(customerName(&name_buf, order), needle) or
        containsIgnoreCase(REGIONS[order.region], needle) or
        containsIgnoreCase(STATUSES[order.status].label, needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |byte, i| {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(byte)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn orderLessThan(_: void, a_index: u16, b_index: u16) bool {
    const a = ORDERS[a_index];
    const b = ORDERS[b_index];
    const order = compareBy(sort_col, a, b);
    if (order == .eq) return a.id < b.id;
    return if (sort_desc) order == .gt else order == .lt;
}

fn compareBy(col: usize, a: Order, b: Order) std.math.Order {
    return switch (col) {
        COL_CUSTOMER => switch (std.mem.order(u8, FIRST_NAMES[a.first], FIRST_NAMES[b.first])) {
            .eq => std.mem.order(u8, LAST_NAMES[a.last], LAST_NAMES[b.last]),
            else => |order| order,
        },
        COL_REGION => std.mem.order(u8, REGIONS[a.region], REGIONS[b.region]),
        COL_STATUS => std.mem.order(u8, STATUSES[a.status].label, STATUSES[b.status].label),
        COL_DATE => std.math.order(a.day, b.day),
        COL_AMOUNT => std.math.order(a.cents, b.cents),
        else => std.math.order(a.id, b.id),
    };
}

fn slotAt(x: i32, y: i32) ?usize {
    if (x < GRID_X or x >= COLUMNS_END_X or y < BODY_Y or y >= BODY_Y + BODY_H) return null;
    const slot: usize = @intCast(@divTrunc(y - BODY_Y, ROW_H));
    if (scroll_top + slot >= view_len) return null;
    return slot;
}

fn headerColumnAt(x: i32, y: i32) ?usize {
    if (y < HEADER_Y or y >= HEADER_Y + HEADER_H) return null;
    for (COLUMNS, 0..) |col, index| {
        if (x >= col.x and x < col.x + col.w) return index;
    }
    return null;
}

fn thumbY() i32 {
    if (view_len <= VISIBLE_ROWS) return BODY_Y;
    const travel = BODY_H - thumbH();
    const max_top: i64 = @intCast(view_len - VISIBLE_ROWS);
    return BODY_Y + @as(i32, @intCast(@divTrunc(@as(i64, travel) * @as(i64, @intCast(scroll_top)), max_top)));
}

fn thumbH() i32 {
    if (view_len <= VISIBLE_ROWS) return BODY_H;
    const h = @divTrunc(BODY_H * @as(i32, VISIBLE_ROWS), @as(i32, @intCast(view_len)));
    return @max(24, h);
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

    fn escaped(w: *Writer, s: []const u8) !void {
        for (s) |byte| {
            switch (byte) {
                '&' => try w.bytes("&amp;"),
                '<' => try w.bytes("&lt;"),
                '>' => try w.bytes("&gt;"),
                '"' => try w.bytes("&quot;"),
                else => try w.bytes(&.{byte}),
            }
        }
    }
};

// Keyed elements carry data-rev, an FNV-1a digest of their content, so a host
// can skip subtrees that did not change. The element's own attributes are not
// hashed: a row that only moves or changes fill keeps its digest.
// `start` is the start tag without its closing `>`.
fn beginKeyed(w: *Writer, comptime start: []const u8, args: anytype) !usize {
    try w.fmt(start, args);
    try w.bytes(" data-rev=\"00000000\">");
    return w.n;
}

fn endKeyed(w: *Writer, content_at: usize) !void {
    const digest = std.hash.Fnv1a_32.hash(output_buf[content_at..w.n]);
    _ = std.fmt.bufPrint(output_buf[content_at - 10 ..][0..8], "{x:0>8}", .{digest}) catch unreachable;
    try w.bytes("</g>");
}

fn rect(w: *Writer, x: i32, y: i32, width: i32, height: i32, fill: []const u8) !void {
    try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ x, y, width, height, fill });
}

fn outline(w: *Writer, x: i32, y: i32, width: i32, height: i32, stroke: []const u8) !void {
    try w.fmt("<rect x=\"{d}.5\" y=\"{d}.5\" width=\"{d}\" height=\"{d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"1\"/>", .{ x, y, width - 1, height - 1, stroke });
}

fn text(w: *Writer, x: i32, baseline: i32, fill: []const u8, right: bool, label: []const u8) !void {
    try w.fmt("<text x=\"{d}\" y=\"{d}\" fill=\"{s}\"{s}>", .{ x, baseline, fill, if (right) " text-anchor=\"end\"" else "" });
    try w.escaped(label);
    try w.bytes("</text>");
}

fn drawFrame(w: *Writer) !void {
    // The page's universal CSS overrides SVG presentation attributes, so set the size inline.
    try w.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" style=\"font-size:13px\" role=\"img\" aria-label=\"Orders data grid\">", .{ DISPLAY_W, DISPLAY_H, DISPLAY_W, DISPLAY_H });
    try w.bytes("<g font-family=\"QIP Chart Inter, Inter, sans-serif\" font-size=\"13\" font-weight=\"700\">");
    try rect(w, 0, 0, DISPLAY_W, DISPLAY_H, C_BG);
    try w.bytes("<g style=\"font-size:16px\" font-size=\"16\">");
    try text(w, GRID_X, 30, C_INK, false, "Orders");
    try w.bytes("</g>");
    try text(w, GRID_X, 50, C_MUTED, false, "Type to filter. Arrow and Page keys move. Click a header to sort.");
    try drawFilter(w);
    try drawHeader(w);
    try drawRows(w);
    try drawScrollbar(w);
    try drawFooter(w);
    try w.bytes("</g></svg>");
}

fn drawFilter(w: *Writer) !void {
    const content = try beginKeyed(w, "<g data-key=\"filter\"", .{});
    try rect(w, FILTER_X, FILTER_Y, FILTER_W, FILTER_H, C_PANEL);
    try outline(w, FILTER_X, FILTER_Y, FILTER_W, FILTER_H, if (filter_len > 0) C_ACCENT else C_GRID);
    if (filter_len == 0) {
        try text(w, FILTER_X + 12, FILTER_Y + 20, C_MUTED, false, "Filter customer, region, status");
    } else {
        try text(w, FILTER_X + 12, FILTER_Y + 20, C_INK, false, filter_buf[0..filter_len]);
    }
    try endKeyed(w, content);
}

fn drawHeader(w: *Writer) !void {
    const header = try beginKeyed(w, "<g data-key=\"header\"", .{});
    for (COLUMNS, 0..) |col, index| {
        const active = index == sort_col;
        const content = try beginKeyed(w, "<g data-key=\"h{d}\"", .{index});
        try rect(w, col.x, HEADER_Y, col.w, HEADER_H, if (active) C_HEADER_ACTIVE else C_HEADER);
        const label_x = if (col.right) col.x + col.w - CELL_PAD_X - (if (active) @as(i32, 14) else 0) else col.x + CELL_PAD_X;
        try text(w, label_x, HEADER_Y + 20, if (active) C_INK else C_MUTED, col.right, col.label);
        if (active) {
            const ax = if (col.right) col.x + col.w - CELL_PAD_X - 8 else col.x + CELL_PAD_X + textWidth(col.label) + 6;
            const ay = HEADER_Y + 12;
            if (sort_desc) {
                try w.fmt("<path d=\"M{d} {d}h8l-4 6z\" fill=\"{s}\"/>", .{ ax, ay, C_ACCENT });
            } else {
                try w.fmt("<path d=\"M{d} {d}h8l-4 -6z\" fill=\"{s}\"/>", .{ ax, ay + 6, C_ACCENT });
            }
        }
        try endKeyed(w, content);
    }
    try endKeyed(w, header);
}

fn drawRows(w: *Writer) !void {
    const content = try beginKeyed(w, "<g data-key=\"rows\"", .{});
    if (view_len == 0) {
        try w.bytes("<text x=\"");
        try w.fmt("{d}\" y=\"{d}\" fill=\"{s}\">No orders match &quot;", .{ GRID_X + CELL_PAD_X, BODY_Y + 28, C_MUTED });
        try w.escaped(filter_buf[0..filter_len]);
        try w.bytes("&quot;.</text>");
    }
    var slot: usize = 0;
    while (slot < VISIBLE_ROWS and scroll_top + slot < view_len) : (slot += 1) {
        const index = scroll_top + slot;
        try drawRow(w, index, slot);
    }
    try endKeyed(w, content);
}

fn drawRow(w: *Writer, index: usize, slot: usize) !void {
    const order = ORDERS[view[index]];
    const is_cursor = index == cursor;
    const is_hover = if (hover_slot) |s| s == slot else false;
    const fill = if (is_cursor) C_CURSOR else if (is_hover) C_HOVER else if (index % 2 == 1) C_STRIPE else C_BG;
    const y = BODY_Y + @as(i32, @intCast(slot)) * ROW_H;

    // Rows are keyed by order ID and placed with a transform, like a virtualized
    // list. The background fill sits on the row too, so the stripe, hover and
    // scroll position stay out of the row's digest.
    const content = try beginKeyed(w, "<g data-key=\"o{d}\" transform=\"translate(0 {d})\" fill=\"{s}\"", .{ order.id, y, fill });
    try w.fmt("<rect x=\"{d}\" y=\"0\" width=\"{d}\" height=\"{d}\"/>", .{ GRID_X, COLUMNS_END_X - GRID_X, ROW_H });
    if (is_cursor) try rect(w, GRID_X, 0, 3, ROW_H, C_ACCENT);

    var buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "#{d}", .{order.id}) catch unreachable;
    try text(w, COLUMNS[COL_ORDER].x + CELL_PAD_X, ROW_TEXT_BASELINE, C_MUTED, false, id);
    try text(w, COLUMNS[COL_CUSTOMER].x + CELL_PAD_X, ROW_TEXT_BASELINE, C_INK, false, customerName(&buf, order));
    try text(w, COLUMNS[COL_REGION].x + CELL_PAD_X, ROW_TEXT_BASELINE, C_INK, false, REGIONS[order.region]);

    const status = STATUSES[order.status];
    const pill_x = COLUMNS[COL_STATUS].x + CELL_PAD_X - 7;
    try w.fmt("<rect x=\"{d}\" y=\"4\" width=\"{d}\" height=\"16\" rx=\"8\" fill=\"{s}\"/>", .{ pill_x, textWidth(status.label) + 14, status.fill });
    try text(w, COLUMNS[COL_STATUS].x + CELL_PAD_X, ROW_TEXT_BASELINE, status.ink, false, status.label);

    try text(w, COLUMNS[COL_DATE].x + CELL_PAD_X, ROW_TEXT_BASELINE, C_INK, false, formatDate(&buf, order.day));
    const amount_col = COLUMNS[COL_AMOUNT];
    try text(w, amount_col.x + amount_col.w - CELL_PAD_X, ROW_TEXT_BASELINE, C_INK, true, formatAmount(&buf, order.cents));
    try endKeyed(w, content);
}

fn drawScrollbar(w: *Writer) !void {
    const content = try beginKeyed(w, "<g data-key=\"scrollbar\"", .{});
    try rect(w, SCROLLBAR_X, BODY_Y, SCROLLBAR_W, BODY_H, C_PANEL);
    try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\"/>", .{ SCROLLBAR_X + 2, thumbY() + 2, SCROLLBAR_W - 4, thumbH() - 4, C_GRID });
    try endKeyed(w, content);
}

fn drawFooter(w: *Writer) !void {
    var buf: [128]u8 = undefined;
    const first = if (view_len == 0) 0 else scroll_top + 1;
    const last = @min(scroll_top + VISIBLE_ROWS, view_len);
    const summary = std.fmt.bufPrint(&buf, "Rows {d}-{d} of {d}. Sorted by {s}, {s}.", .{
        first,
        last,
        view_len,
        COLUMNS[sort_col].label,
        if (sort_desc) "descending" else "ascending",
    }) catch unreachable;
    try text(w, GRID_X, FOOTER_Y + 10, C_MUTED, false, summary);
    if (view_len > 0) {
        const order = ORDERS[view[cursor]];
        var amount_buf: [32]u8 = undefined;
        var name_buf: [32]u8 = undefined;
        const selected = std.fmt.bufPrint(&buf, "#{d} {s} {s}", .{ order.id, customerName(&name_buf, order), formatAmount(&amount_buf, order.cents) }) catch unreachable;
        try text(w, COLUMNS_END_X, FOOTER_Y + 10, C_INK, true, selected);
    }
}

fn customerName(buf: *[32]u8, order: Order) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ FIRST_NAMES[order.first], LAST_NAMES[order.last] }) catch unreachable;
}

fn formatDate(buf: *[32]u8, day_of_year: u16) []const u8 {
    var day = day_of_year;
    var month: usize = 0;
    while (month + 1 < MONTH_DAYS.len and day >= MONTH_DAYS[month]) : (month += 1) day -= MONTH_DAYS[month];
    return std.fmt.bufPrint(buf, "2026-{d:0>2}-{d:0>2}", .{ month + 1, day + 1 }) catch unreachable;
}

fn formatAmount(buf: *[32]u8, cents: u32) []const u8 {
    const dollars = cents / 100;
    const rest = cents % 100;
    if (dollars >= 1000) {
        return std.fmt.bufPrint(buf, "${d},{d:0>3}.{d:0>2}", .{ dollars / 1000, dollars % 1000, rest }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ dollars, rest }) catch unreachable;
}

fn textWidth(label: []const u8) i32 {
    var width: i32 = 0;
    for (label) |byte| {
        if (byte >= ui_font.ASCII_START and byte <= ui_font.ASCII_END) width += ui_font.advances[byte - ui_font.ASCII_START];
    }
    return @divTrunc(width * FONT_SIZE + FONT_METRIC_SIZE - 1, FONT_METRIC_SIZE);
}

fn xorshift32(seed: u32) u32 {
    var x = seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}
