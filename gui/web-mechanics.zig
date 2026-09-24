const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 640;
const RENDER_H: usize = 420;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const BTN_PRIMARY: i32 = 1 << 0;

const Color = [4]u8;
const C_BG: Color = .{ 0xF7, 0xF4, 0xEC, 0xFF };
const C_PANEL: Color = .{ 0xFF, 0xFD, 0xF8, 0xFF };
const C_INK: Color = .{ 0x18, 0x1A, 0x1F, 0xFF };
const C_MUTED: Color = .{ 0x66, 0x63, 0x5C, 0xFF };
const C_LINE: Color = .{ 0xB8, 0xB0, 0xA4, 0xFF };
const C_ACTIVE: Color = .{ 0xEE, 0xCC, 0x33, 0xFF };
const C_BLUE: Color = .{ 0xD7, 0xEC, 0xF8, 0xFF };
const C_GREEN: Color = .{ 0xD9, 0xEF, 0xE3, 0xFF };
const C_ORANGE: Color = .{ 0xF7, 0xDF, 0xD3, 0xFF };
const C_RED: Color = .{ 0xC8, 0x42, 0x42, 0xFF };
const C_OK: Color = .{ 0x35, 0x8E, 0x64, 0xFF };
const C_PATH: Color = .{ 0x20, 0x7A, 0xB8, 0xFF };

const Topic = enum(u8) { tls, dns, page, cookies };
const Scenario = enum(u8) { a, b, c, d };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var topic: Topic = .tls;
var scenario: Scenario = .a;
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
    transaction_phase = .updating;
}

export fn key_event(_: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    return 0;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    if (down and !primary_down) {
        if (hit(x, y, 20, 52, 78, 24)) {
            topic = .tls;
            scenario = .a;
        } else if (hit(x, y, 108, 52, 78, 24)) {
            topic = .dns;
            scenario = .a;
        } else if (hit(x, y, 196, 52, 88, 24)) {
            topic = .page;
            scenario = .a;
        } else if (hit(x, y, 294, 52, 98, 24)) {
            topic = .cookies;
            scenario = .a;
        } else if (hit(x, y, 20, 86, 132, 24)) {
            scenario = .a;
        } else if (hit(x, y, 162, 86, 132, 24)) {
            scenario = .b;
        } else if (hit(x, y, 304, 86, 132, 24)) {
            scenario = .c;
        } else if (hit(x, y, 446, 86, 132, 24)) {
            scenario = .d;
        }
    }
    primary_down = down;
    return 1;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
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
    committed_at_ms = begun_at_ms;
    transaction_phase = .ready;
    return begun_at_ms;
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn drawFrame() void {
    fillRect(0, 0, @intCast(RENDER_W), @intCast(RENDER_H), C_BG);
    drawText(20, 18, "WEB MECHANICS EXPLAINERS", C_INK);
    drawText(20, 34, "SEQUENCES FOR SECURITY AND PERFORMANCE", C_MUTED);
    button(20, 52, 78, "TLS", topic == .tls);
    button(108, 52, 78, "DNS", topic == .dns);
    button(196, 52, 88, "PAGE", topic == .page);
    button(294, 52, 98, "COOKIES", topic == .cookies);
    drawScenarioButtons();
    switch (topic) {
        .tls => drawTLS(),
        .dns => drawDNS(),
        .page => drawPage(),
        .cookies => drawCookies(),
    }
}

fn drawScenarioButtons() void {
    switch (topic) {
        .tls => {
            button(20, 86, 132, "TLS 1.2", scenario == .a);
            button(162, 86, 132, "TLS 1.3", scenario == .b);
            button(304, 86, 132, "RESUME", scenario == .c);
            button(446, 86, 132, "KEYS", scenario == .d);
        },
        .dns => {
            button(20, 86, 132, "COLD", scenario == .a);
            button(162, 86, 132, "CACHE HIT", scenario == .b);
            button(304, 86, 132, "TTL CHANGE", scenario == .c);
            button(446, 86, 132, "MANY NAMES", scenario == .d);
        },
        .page => {
            button(20, 86, 132, "PARSE", scenario == .a);
            button(162, 86, 132, "CSS BLOCKS", scenario == .b);
            button(304, 86, 132, "SCRIPTS", scenario == .c);
            button(446, 86, 132, "DEFER ASYNC", scenario == .d);
        },
        .cookies => {
            button(20, 86, 132, "TOP NAV", scenario == .a);
            button(162, 86, 132, "FORM POST", scenario == .b);
            button(304, 86, 132, "FETCH IFRAME", scenario == .c);
            button(446, 86, 132, "IMAGE", scenario == .d);
        },
    }
}

fn drawTLS() void {
    title("TLS HANDSHAKE ROUND TRIPS");
    actor3("CLIENT", "NETWORK", "SERVER");
    switch (scenario) {
        .a => {
            msg(126, 158, 510, "CLIENTHELLO", C_PATH);
            msg(510, 190, 126, "SERVERHELLO CERT KEYEX", C_PATH);
            msg(126, 222, 510, "CLIENT KEYEX FINISHED", C_PATH);
            msg(510, 254, 126, "SERVER FINISHED", C_PATH);
            msg(126, 286, 510, "APP DATA STARTS", C_OK);
            note("TLS 1.2 USUALLY NEEDS TWO ROUND TRIPS BEFORE APPLICATION DATA CAN FLOW.");
        },
        .b => {
            msg(126, 166, 510, "CLIENTHELLO KEY SHARE", C_PATH);
            msg(510, 206, 126, "SERVERHELLO CERT FINISHED", C_PATH);
            msg(126, 246, 510, "FINISHED + APP DATA", C_OK);
            note("TLS 1.3 MOVES KEY AGREEMENT EARLIER. APP DATA CAN START AFTER ONE ROUND TRIP.");
        },
        .c => {
            msg(126, 174, 510, "CLIENTHELLO PSK", C_PATH);
            msg(126, 210, 510, "EARLY DATA OPTIONAL", C_OK);
            msg(510, 250, 126, "SERVER FINISHED", C_PATH);
            note("RESUMPTION REUSES A PREVIOUS SECRET. TLS 1.3 CAN SEND 0 RTT EARLY DATA WITH REPLAY TRADEOFFS.");
        },
        .d => {
            box(42, 154, 120, 50, "RANDOMS", C_BLUE);
            box(260, 154, 120, 50, "KEY SHARE", C_GREEN);
            box(478, 154, 120, 50, "TRAFFIC KEYS", C_ORANGE);
            msg(102, 238, 538, "BOTH SIDES DERIVE SAME SECRETS", C_OK);
            note("THE SYMMETRIC TRAFFIC KEYS ARE NOT SENT. BOTH SIDES DERIVE THEM FROM HANDSHAKE INPUTS.");
        },
    }
}

fn drawDNS() void {
    title("DNS RESOLUTION AND TTL");
    switch (scenario) {
        .a => {
            actor5("BROWSER", "OS", "RESOLVER", "ROOT", "AUTH");
            msg(76, 156, 190, "MISS", C_PATH);
            msg(190, 186, 306, "MISS", C_PATH);
            msg(306, 216, 422, "ASK .COM", C_PATH);
            msg(422, 246, 538, "ASK AUTH", C_PATH);
            msg(538, 276, 76, "A 203.0.113.7 TTL 300", C_OK);
            note("A COLD LOOKUP WALKS THROUGH CACHE LAYERS UNTIL AN AUTHORITATIVE ANSWER IS FOUND.");
        },
        .b => {
            actor5("BROWSER", "OS", "RESOLVER", "ROOT", "AUTH");
            msg(76, 182, 190, "HIT TTL LEFT", C_OK);
            msg(190, 222, 76, "IP RETURNED", C_OK);
            note("CACHE HITS SKIP THE REST OF THE TREE. TTL IS WHY REPEATED LOOKUPS ARE CHEAP.");
        },
        .c => {
            actor5("OLD IP", "CACHE", "TTL", "AUTH", "NEW IP");
            box(48, 164, 110, 44, "203.0.113.7", C_ORANGE);
            box(266, 164, 110, 44, "TTL 300", C_BLUE);
            box(484, 164, 110, 44, "203.0.113.9", C_GREEN);
            msg(100, 238, 540, "CHANGE AT AUTH DOES NOT ERASE CACHES", C_RED);
            note("WHEN A RECORD CHANGES, EXISTING CACHES CAN KEEP THE OLD ANSWER UNTIL TTL EXPIRES.");
        },
        .d => {
            actor5("PAGE", "API", "IMG", "CDN", "AUTH");
            msg(76, 162, 190, "DNS", C_PATH);
            msg(76, 202, 306, "DNS", C_PATH);
            msg(76, 242, 422, "DNS", C_PATH);
            msg(76, 282, 538, "DNS", C_PATH);
            note("EACH NEW HOSTNAME CAN ADD DNS AND CONNECTION SETUP. FEWER OR WARMER HOSTS REDUCE STARTUP COST.");
        },
    }
}

fn drawPage() void {
    title("PAGE LOAD: LOAD VS EXECUTE");
    actor5("HTML", "SCANNER", "CSS", "JS", "PAINT");
    switch (scenario) {
        .a => {
            msg(76, 160, 190, "PARSE TOKENS", C_PATH);
            msg(190, 200, 306, "DISCOVER CSS IMG JS", C_PATH);
            msg(76, 240, 422, "DOM BUILDS", C_OK);
            msg(422, 280, 538, "LAYOUT PAINT", C_OK);
            note("THE PARSER BUILDS DOM WHILE A PRELOAD SCANNER CAN START FETCHES BEFORE PARSE REACHES THEM.");
        },
        .b => {
            msg(76, 160, 306, "LINK STYLESHEET", C_PATH);
            msg(306, 204, 538, "CSSOM NEEDED", C_RED);
            msg(538, 250, 538, "PAINT WAITS", C_RED);
            note("CSS DOES NOT BLOCK HTML PARSING FOREVER, BUT IT BLOCKS RENDERING BECAUSE STYLE IS NEEDED TO PAINT.");
        },
        .c => {
            msg(76, 160, 422, "CLASSIC SCRIPT", C_RED);
            msg(422, 204, 76, "PARSE PAUSES", C_RED);
            msg(422, 248, 306, "MAY WAIT FOR CSS", C_RED);
            note("A CLASSIC SCRIPT WITHOUT DEFER OR ASYNC CAN BLOCK PARSING AND MAY WAIT FOR PRIOR CSS.");
        },
        .d => {
            msg(76, 156, 422, "DEFER FETCHES", C_PATH);
            msg(76, 196, 422, "ASYNC FETCHES", C_PATH);
            msg(422, 236, 76, "ASYNC RUNS WHEN READY", C_RED);
            msg(422, 276, 538, "DEFER RUNS AFTER PARSE", C_OK);
            note("ASYNC OPTIMIZES INDEPENDENT SCRIPTS. DEFER PRESERVES ORDER AND WAITS UNTIL PARSING FINISHES.");
        },
    }
}

fn drawCookies() void {
    title("COOKIES AND SAMESITE");
    actor3("SITE A", "BROWSER", "SITE B");
    switch (scenario) {
        .a => {
            msg(126, 170, 510, "TOP LEVEL GET", C_PATH);
            msg(320, 210, 510, "LAX COOKIE SENT", C_OK);
            note("SAMESITE LAX COOKIES ARE SENT ON TOP LEVEL SAFE NAVIGATIONS SUCH AS CLICKING A LINK.");
        },
        .b => {
            msg(126, 170, 510, "CROSS SITE POST", C_RED);
            msg(320, 214, 510, "LAX COOKIE BLOCKED", C_RED);
            note("LAX USUALLY BLOCKS COOKIES ON CROSS SITE POST. STRICT IS TIGHTER. NONE REQUIRES SECURE.");
        },
        .c => {
            msg(126, 164, 510, "IFRAME OR FETCH", C_RED);
            msg(320, 206, 510, "STRICT LAX BLOCK", C_RED);
            msg(320, 248, 510, "NONE MAY SEND", C_PATH);
            note("SUBRESOURCE AND FETCH CONTEXTS ARE WHERE SAMESITE PROTECTS AGAINST MANY CSRF PATTERNS.");
        },
        .d => {
            msg(126, 170, 510, "IMG SRC", C_RED);
            msg(320, 214, 510, "REQUEST CAN HAPPEN", C_PATH);
            msg(510, 258, 126, "JS CANNOT READ", C_OK);
            note("COOKIES ARE ABOUT WHAT THE BROWSER SENDS. CORS IS ABOUT WHETHER JAVASCRIPT CAN READ RESPONSES.");
        },
    }
}

fn actor3(a: []const u8, b: []const u8, c: []const u8) void {
    box(28, 128, 110, 42, a, C_ORANGE);
    box(265, 128, 110, 42, b, C_BLUE);
    box(502, 128, 110, 42, c, C_GREEN);
}

fn actor5(a: []const u8, b: []const u8, c: []const u8, d: []const u8, e: []const u8) void {
    box(28, 128, 96, 38, a, C_BLUE);
    box(150, 128, 96, 38, b, C_GREEN);
    box(272, 128, 96, 38, c, C_ORANGE);
    box(394, 128, 96, 38, d, C_BLUE);
    box(516, 128, 96, 38, e, C_GREEN);
}

fn title(text: []const u8) void {
    drawText(20, 114, text, C_INK);
}

fn note(text: []const u8) void {
    fillRect(20, 326, 600, 66, C_PANEL);
    drawBorder(20, 326, 600, 66, C_LINE);
    drawWrappedText(34, 342, 68, text, C_MUTED);
}

fn msg(x0: i32, y: i32, x1: i32, label: []const u8, c: Color) void {
    arrow(x0, y, x1, y, c);
    const tx = @min(x0, x1) + 12;
    drawWrappedText(tx, y - 13, 32, label, C_INK);
}

fn button(x: i32, y: i32, w: i32, label: []const u8, active: bool) void {
    fillRect(x, y, w, 24, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, 24, C_INK);
    drawText(x + 8, y + 8, label, C_INK);
}

fn box(x: i32, y: i32, w: i32, h: i32, label: []const u8, color: Color) void {
    fillRect(x, y, w, h, color);
    drawBorder(x, y, w, h, C_INK);
    drawWrappedText(x + 8, y + @divTrunc(h, 2) - 8, @intCast(@divTrunc(w - 16, 8)), label, C_INK);
}

fn arrow(x0: i32, y0: i32, x1: i32, y1: i32, c: Color) void {
    if (x0 <= x1) {
        fillRect(x0, y0, x1 - x0, 2, c);
        fillRect(x1 - 8, y1 - 4, 8, 2, c);
        fillRect(x1 - 8, y1 + 4, 8, 2, c);
    } else {
        fillRect(x1, y0, x0 - x1, 2, c);
        fillRect(x1, y1 - 4, 8, 2, c);
        fillRect(x1, y1 + 4, 8, 2, c);
    }
}

fn drawWrappedText(x: i32, y: i32, max_chars: usize, text: []const u8, c: Color) void {
    var start: usize = 0;
    var line: usize = 0;
    while (start < text.len and line < 5) : (line += 1) {
        var end = @min(text.len, start + max_chars);
        if (end < text.len) {
            var scan = end;
            while (scan > start and text[scan] != ' ') : (scan -= 1) {}
            if (scan > start) end = scan;
        }
        drawText(x, y + @as(i32, @intCast(line * 14)), trim(text[start..end]), c);
        start = end;
        while (start < text.len and text[start] == ' ') start += 1;
    }
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b = s.len;
    while (a < b and s[a] == ' ') a += 1;
    while (b > a and s[b - 1] == ' ') b -= 1;
    return s[a..b];
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    drawTextScaled(x, y, text, c, 2);
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len and i < 96) : (i += 1) {
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
            fillRect(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, c);
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

fn drawBorder(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRect(x, y, w, 1, c);
    fillRect(x, y, 1, h, c);
    fillRect(x, y + h - 1, w, 1, c);
    fillRect(x + w - 1, y, 1, h, c);
}

fn fillRect(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = @max(0, x0);
    const sy = @max(0, y0);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x0 + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y0 + h);
    if (sx >= ex or sy >= ey) return;
    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) {
            const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
            pixel_buf[idx + 0] = c[0];
            pixel_buf[idx + 1] = c[1];
            pixel_buf[idx + 2] = c[2];
            pixel_buf[idx + 3] = c[3];
        }
    }
}

test "starts on TLS 1.2" {
    try std.testing.expect(topic == .tls);
    try std.testing.expect(scenario == .a);
}
