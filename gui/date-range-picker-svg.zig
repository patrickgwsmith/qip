const std = @import("std");

// A two-month check-in/check-out picker, shaped like the range pickers React
// apps build for bookings: past and booked dates are disabled, hovering after a
// check-in previews the stay, and arrows, Page keys and Enter work without a
// pointer. The SVG DOM update benchmark replays its frames.

const DISPLAY_W: i32 = 820;
const DISPLAY_H: i32 = 480;
const OUTPUT_CAP: usize = 65536;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const CELL_W: i32 = 48;
const CELL_H: i32 = 42;
const PANEL_W: i32 = CELL_W * 7;
const PANEL_X = [_]i32{ 50, 434 };
const MONTH_TITLE_BASELINE: i32 = 94;
const WEEKDAY_BASELINE: i32 = 132;
const GRID_Y: i32 = 146;
const GRID_ROWS: i32 = 6;
const NAV_Y: i32 = 72;
const NAV_SIZE: i32 = 32;
const PREV_X: i32 = PANEL_X[0];
const NEXT_X: i32 = PANEL_X[1] + PANEL_W - NAV_SIZE;
const FOOTER_BASELINE: i32 = 440;
const CLEAR_X: i32 = NEXT_X + NAV_SIZE - 80;
const CLEAR_Y: i32 = 418;
const CLEAR_W: i32 = 80;
const CLEAR_H: i32 = 32;
const MAX_NIGHTS: i32 = 30;

const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_ENTER: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_PAGE_UP: i32 = 0xFF55;
const XK_PAGE_DOWN: i32 = 0xFF56;

const C_BG = "#080A12";
const C_PANEL = "#101422";
const C_RANGE = "#1E2B4D";
const C_PREVIEW = "#151D33";
const C_HOVER = "#22305A";
const C_ACCENT = "#8FB4FF";
const C_INK = "#F4F7FB";
const C_ON_ACCENT = "#080A12";
const C_MUTED = "#A4AEC0";
const C_DISABLED = "#4C5468";
const C_GRID = "#323A4C";

const MONTH_NAMES = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const WEEKDAY_LABELS = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
const WEEKDAY_NAMES = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

// Day numbers count from 1970-01-01. The picker opens on a fixed date so its
// output does not depend on the host clock.
const FIRST_BOOKABLE: i32 = daysFromCivil(2026, 10, 5);
const MIN_VIEW_MONTH: i32 = 2026 * 12 + 9;
const MAX_VIEW_MONTH: i32 = MIN_VIEW_MONTH + 22;
const LAST_BOOKABLE: i32 = monthStart(MAX_VIEW_MONTH + 2) - 1;

var output_buf: [OUTPUT_CAP]u8 = undefined;
var view_month: i32 = MIN_VIEW_MONTH;
var focus_day: i32 = FIRST_BOOKABLE;
var check_in: ?i32 = null;
var check_out: ?i32 = null;
var hover_day: ?i32 = null;
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
    const changed = switch (x11_key) {
        XK_LEFT => moveFocus(focus_day - 1),
        XK_RIGHT => moveFocus(focus_day + 1),
        XK_UP => moveFocus(focus_day - 7),
        XK_DOWN => moveFocus(focus_day + 7),
        XK_PAGE_UP => moveFocus(addMonths(focus_day, -1)),
        XK_PAGE_DOWN => moveFocus(addMonths(focus_day, 1)),
        XK_ENTER, ' ' => choose(focus_day),
        XK_ESCAPE => clearRange(),
        else => false,
    };
    return if (changed) 1 else 0;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    const day = dayAt(x, y);
    if (!std.meta.eql(hover_day, day)) {
        hover_day = day;
        changed = true;
    }
    if (down and !primary_down) {
        if (day) |d| {
            if (d != focus_day and d >= FIRST_BOOKABLE) {
                focus_day = d;
                changed = true;
            }
            changed = choose(d) or changed;
        } else if (hit(x, y, PREV_X, NAV_Y, NAV_SIZE, NAV_SIZE)) {
            changed = showMonth(view_month - 1) or changed;
        } else if (hit(x, y, NEXT_X, NAV_Y, NAV_SIZE, NAV_SIZE)) {
            changed = showMonth(view_month + 1) or changed;
        } else if (hit(x, y, CLEAR_X, CLEAR_Y, CLEAR_W, CLEAR_H)) {
            changed = clearRange() or changed;
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

fn moveFocus(target: i32) bool {
    const day = std.math.clamp(target, FIRST_BOOKABLE, LAST_BOOKABLE);
    if (day == focus_day) return false;
    focus_day = day;
    const month = monthOf(day);
    if (month < view_month) view_month = month;
    if (month > view_month + 1) view_month = month - 1;
    return true;
}

fn showMonth(month: i32) bool {
    const next = std.math.clamp(month, MIN_VIEW_MONTH, MAX_VIEW_MONTH);
    if (next == view_month) return false;
    view_month = next;
    return true;
}

// The first pick sets check-in. A later, valid pick sets check-out; any other
// pick starts a new stay.
fn choose(day: i32) bool {
    if (!isAvailable(day)) return false;
    if (check_in) |start| {
        if (check_out == null and stayIsValid(start, day)) {
            check_out = day;
            return true;
        }
    }
    check_in = day;
    check_out = null;
    return true;
}

fn clearRange() bool {
    if (check_in == null) return false;
    check_in = null;
    check_out = null;
    return true;
}

fn isAvailable(day: i32) bool {
    if (day < FIRST_BOOKABLE or day > LAST_BOOKABLE) return false;
    // A fixed hash books about one day in ten.
    var hash = @as(u32, @bitCast(day)) *% 0x9E37_79B1;
    hash ^= hash >> 15;
    hash *%= 0x85EB_CA77;
    hash ^= hash >> 13;
    return hash % 10 != 0;
}

fn stayIsValid(start: i32, end: i32) bool {
    if (end <= start or end - start > MAX_NIGHTS or !isAvailable(end)) return false;
    var day = start + 1;
    while (day < end) : (day += 1) {
        if (!isAvailable(day)) return false;
    }
    return true;
}

// Returns the check-out day to draw: the chosen one, or a preview while the
// pointer or keyboard focus rests on a valid later day.
fn shownCheckOut() ?i32 {
    if (check_out) |end| return end;
    const start = check_in orelse return null;
    const candidate = hover_day orelse focus_day;
    return if (stayIsValid(start, candidate)) candidate else null;
}

fn dayAt(x: i32, y: i32) ?i32 {
    if (y < GRID_Y or y >= GRID_Y + GRID_ROWS * CELL_H) return null;
    for (PANEL_X, 0..) |panel_x, panel| {
        if (x < panel_x or x >= panel_x + PANEL_W) continue;
        const month = view_month + @as(i32, @intCast(panel));
        const first = monthStart(month);
        const cell = @divTrunc(y - GRID_Y, CELL_H) * 7 + @divTrunc(x - panel_x, CELL_W);
        const index = cell - weekday(first);
        if (index < 0 or index >= monthStart(month + 1) - first) return null;
        return first + index;
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

// Keyed elements carry data-rev, an FNV-1a digest of their content, so a host
// can skip subtrees that did not change. The element's own attributes are not
// hashed: a month panel that only moves keeps its digest.
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

fn rect(w: *Writer, x: i32, y: i32, width: i32, height: i32, radius: i32, fill: []const u8) !void {
    try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\" fill=\"{s}\"/>", .{ x, y, width, height, radius, fill });
}

fn text(w: *Writer, x: i32, baseline: i32, fill: []const u8, anchor: []const u8, label: []const u8) !void {
    try w.fmt("<text x=\"{d}\" y=\"{d}\" fill=\"{s}\" text-anchor=\"{s}\">{s}</text>", .{ x, baseline, fill, anchor, label });
}

fn drawFrame(w: *Writer) !void {
    // The page's universal CSS overrides SVG presentation attributes, so set the size inline.
    try w.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" style=\"font-size:14px\" role=\"img\" aria-label=\"Check-in and check-out date picker\">", .{ DISPLAY_W, DISPLAY_H, DISPLAY_W, DISPLAY_H });
    try w.bytes("<g font-family=\"QIP Chart Inter, Inter, sans-serif\" font-size=\"14\" font-weight=\"700\">");
    try rect(w, 0, 0, DISPLAY_W, DISPLAY_H, 0, C_BG);
    try w.bytes("<g style=\"font-size:16px\" font-size=\"16\">");
    try text(w, PANEL_X[0], 34, C_INK, "start", "Choose your dates");
    try w.bytes("</g>");
    try text(w, PANEL_X[0], 54, C_MUTED, "start", "Click or press Enter to pick check-in, then check-out. Arrows move by day, Page keys by month.");
    try navButton(w, "prev", PREV_X, view_month > MIN_VIEW_MONTH, "M19 9l-7 7 7 7");
    try navButton(w, "next", NEXT_X, view_month < MAX_VIEW_MONTH, "M13 9l7 7-7 7");
    try drawMonth(w, view_month, PANEL_X[0]);
    try drawMonth(w, view_month + 1, PANEL_X[1]);
    try drawFooter(w);
    try w.bytes("</g></svg>");
}

fn navButton(w: *Writer, key: []const u8, x: i32, enabled: bool, chevron: []const u8) !void {
    const ink = if (enabled) C_INK else C_DISABLED;
    const content = try beginKeyed(w, "<g data-key=\"{s}\" transform=\"translate({d} {d})\"", .{ key, x, NAV_Y });
    try rect(w, 0, 0, NAV_SIZE, NAV_SIZE, 8, C_PANEL);
    try w.fmt("<path d=\"{s}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>", .{ chevron, ink });
    try endKeyed(w, content);
}

// Panels are keyed by month, so paging forward can move the right panel left.
fn drawMonth(w: *Writer, month: i32, panel_x: i32) !void {
    const year = @divFloor(month, 12);
    const month_index: usize = @intCast(@mod(month, 12));
    const content = try beginKeyed(w, "<g data-key=\"m{d}-{d:0>2}\" transform=\"translate({d} 0)\"", .{ year, month_index + 1, panel_x });
    try w.fmt("<text x=\"{d}\" y=\"{d}\" fill=\"{s}\" text-anchor=\"middle\">{s} {d}</text>", .{ @divTrunc(PANEL_W, 2), MONTH_TITLE_BASELINE, C_INK, MONTH_NAMES[month_index], year });
    for (WEEKDAY_LABELS, 0..) |label, col| {
        try text(w, @as(i32, @intCast(col)) * CELL_W + @divTrunc(CELL_W, 2), WEEKDAY_BASELINE, C_MUTED, "middle", label);
    }
    const first = monthStart(month);
    const offset = weekday(first);
    const end = monthStart(month + 1);
    var day = first;
    while (day < end) : (day += 1) {
        try drawDay(w, day, day - first + offset);
    }
    try endKeyed(w, content);
}

fn drawDay(w: *Writer, day: i32, cell: i32) !void {
    const x = @mod(cell, 7) * CELL_W;
    const y = GRID_Y + @divTrunc(cell, 7) * CELL_H;
    const civil = civilFromDays(day);
    const available = isAvailable(day);
    const shown_out = shownCheckOut();
    const preview = check_out == null;
    const is_start = if (check_in) |start| day == start else false;
    const is_end = if (shown_out) |end| day == end else false;
    const in_band = if (check_in) |start| (if (shown_out) |end| day >= start and day <= end else false) else false;
    const is_hover = if (hover_day) |h| h == day and available else false;

    // Zig prints a sign on padded signed integers, so pad unsigned values.
    const content = try beginKeyed(w, "<g data-key=\"d{d}{d:0>2}{d:0>2}\"", .{ civil.year, @as(u32, @intCast(civil.month)), @as(u32, @intCast(civil.day)) });
    // The band joins check-in to check-out; the dot marks the ends and hover.
    var band_x = x;
    var band_w: i32 = CELL_W;
    if (is_start and !is_end) {
        band_x = x + @divTrunc(CELL_W, 2);
        band_w = @divTrunc(CELL_W, 2);
    } else if (is_end and !is_start) {
        band_w = @divTrunc(CELL_W, 2);
    }
    try rect(w, band_x, y + 3, band_w, CELL_H - 6, 0, if (!in_band) "none" else if (preview) C_PREVIEW else C_RANGE);
    const dot_fill = if (is_start or (is_end and !preview)) C_ACCENT else if (is_end) C_HOVER else if (is_hover) C_PANEL else "none";
    try rect(w, x + 4, y + 3, CELL_W - 8, CELL_H - 6, @divTrunc(CELL_H - 6, 2), dot_fill);

    const ink = if (!available) C_DISABLED else if (is_start or (is_end and !preview)) C_ON_ACCENT else C_INK;
    var label_buf: [4]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{d}", .{civil.day}) catch unreachable;
    try text(w, x + @divTrunc(CELL_W, 2), y + 26, ink, "middle", label);
    if (!available and day >= FIRST_BOOKABLE) {
        try w.fmt("<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"1.5\"/>", .{ x + 16, y + 21, x + CELL_W - 16, y + 21, C_DISABLED });
    }
    if (day == focus_day) {
        try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"2\"/>", .{ x + 3, y + 2, CELL_W - 6, CELL_H - 4, @divTrunc(CELL_H - 4, 2), C_ACCENT });
    }
    try endKeyed(w, content);
}

fn drawFooter(w: *Writer) !void {
    var buf: [128]u8 = undefined;
    var in_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const summary = if (check_in) |start| (if (check_out) |end|
        std.fmt.bufPrint(&buf, "Check-in {s}. Check-out {s}. {d} {s}.", .{ formatDay(&in_buf, start), formatDay(&out_buf, end), end - start, if (end - start == 1) "night" else "nights" }) catch unreachable
    else
        std.fmt.bufPrint(&buf, "Check-in {s}. Now pick check-out, up to {d} nights later.", .{ formatDay(&in_buf, start), MAX_NIGHTS }) catch unreachable) else "Pick a check-in date. Crossed-out dates are booked.";
    try text(w, PANEL_X[0], FOOTER_BASELINE, C_INK, "start", summary);
    const content = try beginKeyed(w, "<g data-key=\"clear\" transform=\"translate({d} {d})\"", .{ CLEAR_X, CLEAR_Y });
    try rect(w, 0, 0, CLEAR_W, CLEAR_H, 8, C_PANEL);
    try w.fmt("<rect x=\"0.5\" y=\"0.5\" width=\"{d}\" height=\"{d}\" rx=\"8\" fill=\"none\" stroke=\"{s}\"/>", .{ CLEAR_W - 1, CLEAR_H - 1, C_GRID });
    try text(w, @divTrunc(CLEAR_W, 2), 21, if (check_in == null) C_DISABLED else C_INK, "middle", "Clear");
    try endKeyed(w, content);
}

fn formatDay(buf: *[32]u8, day: i32) []const u8 {
    const civil = civilFromDays(day);
    const month_name = MONTH_NAMES[@intCast(civil.month - 1)];
    return std.fmt.bufPrint(buf, "{s} {d} {s}", .{ WEEKDAY_NAMES[@intCast(weekday(day))], civil.day, month_name[0..3] }) catch unreachable;
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

const Civil = struct { year: i32, month: i32, day: i32 };

// Howard Hinnant's days_from_civil and civil_from_days.
fn daysFromCivil(year: i32, month: i32, day: i32) i32 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days: i32) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i32, if (month <= 2) 1 else 0);
    return .{ .year = year, .month = month, .day = doy - @divTrunc(153 * mp + 2, 5) + 1 };
}

// Monday is 0. 1970-01-01 was a Thursday.
fn weekday(day: i32) i32 {
    return @mod(day + 3, 7);
}

fn monthStart(month: i32) i32 {
    return daysFromCivil(@divFloor(month, 12), @mod(month, 12) + 1, 1);
}

fn monthOf(day: i32) i32 {
    const civil = civilFromDays(day);
    return civil.year * 12 + civil.month - 1;
}

fn addMonths(day: i32, delta: i32) i32 {
    const civil = civilFromDays(day);
    const month = civil.year * 12 + civil.month - 1 + delta;
    const first = monthStart(month);
    return first + @min(civil.day, monthStart(month + 1) - first) - 1;
}
