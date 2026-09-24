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
const C_BROWSER: Color = .{ 0xD7, 0xEC, 0xF8, 0xFF };
const C_SERVER: Color = .{ 0xD9, 0xEF, 0xE3, 0xFF };
const C_ATTACK: Color = .{ 0xF7, 0xDF, 0xD3, 0xFF };
const C_WARN: Color = .{ 0xC8, 0x42, 0x42, 0xFF };
const C_OK: Color = .{ 0x35, 0x8E, 0x64, 0xFF };
const C_BLUE: Color = .{ 0x20, 0x7A, 0xB8, 0xFF };

const Topic = enum(u8) { cors, csrf, xss };
const Scenario = enum(u8) { a, b, c, d };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var topic: Topic = .cors;
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
        if (hit(x, y, 20, 52, 86, 24)) {
            topic = .cors;
            scenario = .a;
        } else if (hit(x, y, 116, 52, 86, 24)) {
            topic = .csrf;
            scenario = .a;
        } else if (hit(x, y, 212, 52, 86, 24)) {
            topic = .xss;
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
    drawText(20, 18, "BROWSER SECURITY EXPLAINERS", C_INK);
    drawText(20, 34, "TAP A TOPIC AND A SCENARIO", C_MUTED);

    button(20, 52, 86, "CORS", topic == .cors);
    button(116, 52, 86, "CSRF", topic == .csrf);
    button(212, 52, 86, "XSS", topic == .xss);

    drawScenarioButtons();

    switch (topic) {
        .cors => drawCORS(),
        .csrf => drawCSRF(),
        .xss => drawXSS(),
    }
}

fn drawScenarioButtons() void {
    switch (topic) {
        .cors => {
            button(20, 86, 132, "SAME GET", scenario == .a);
            button(162, 86, 132, "CROSS GET", scenario == .b);
            button(304, 86, 132, "JSON POST", scenario == .c);
            button(446, 86, 132, "MANY HOSTS", scenario == .d);
        },
        .csrf => {
            button(20, 86, 132, "COOKIE SENT", scenario == .a);
            button(162, 86, 132, "SAMESITE", scenario == .b);
            button(304, 86, 132, "TOKEN", scenario == .c);
            button(446, 86, 132, "GET RISK", scenario == .d);
        },
        .xss => {
            button(20, 86, 132, "REFLECTED", scenario == .a);
            button(162, 86, 132, "STORED", scenario == .b);
            button(304, 86, 132, "DOM XSS", scenario == .c);
            button(446, 86, 132, "ESCAPED", scenario == .d);
        },
    }
}

fn drawCORS() void {
    drawActors("PAGE A", "API B", "BROWSER");
    switch (scenario) {
        .a => {
            title("SAME ORIGIN GET");
            arrow(130, 190, 290, 190, C_OK);
            step(40, 245, "1 PAGE REQUESTS /DATA");
            step(235, 245, "2 SAME ORIGIN");
            step(430, 245, "3 NO CORS CHECK");
            note("SAME SCHEME HOST PORT MEANS NORMAL REQUEST. NO PREFLIGHT AND NO CORS HEADER NEEDED.");
        },
        .b => {
            title("CROSS ORIGIN SIMPLE GET");
            arrow(130, 190, 290, 190, C_BLUE);
            arrow(350, 190, 510, 190, C_BLUE);
            step(40, 245, "1 JS FETCH API B");
            step(235, 245, "2 BROWSER SENDS GET");
            step(430, 245, "3 JS CAN READ ONLY IF ACAO MATCHES");
            note("CORS DOES NOT STOP THE GET. IT CONTROLS WHETHER JAVASCRIPT CAN READ THE RESPONSE.");
        },
        .c => {
            title("JSON POST WITH PREFLIGHT");
            arrow(130, 168, 510, 168, C_WARN);
            arrow(510, 194, 130, 194, C_WARN);
            arrow(130, 222, 510, 222, C_BLUE);
            step(32, 260, "1 OPTIONS PREFLIGHT");
            step(226, 260, "2 ALLOW METHODS HEADERS");
            step(420, 260, "3 THEN POST JSON");
            note("POST WITH APPLICATION JSON IS NOT SIMPLE. THE OPTIONS ROUND TRIP IS EXTRA LATENCY.");
        },
        .d => {
            title("MANY DOMAINS COST TIME");
            box(52, 154, 100, 44, "DNS API", C_ATTACK);
            box(196, 154, 100, 44, "DNS IMG", C_ATTACK);
            box(340, 154, 100, 44, "DNS CDN", C_ATTACK);
            box(484, 154, 100, 44, "DNS AUTH", C_ATTACK);
            arrow(102, 220, 536, 220, C_WARN);
            step(40, 260, "DNS");
            step(190, 260, "TCP TLS");
            step(340, 260, "REQUEST");
            step(490, 260, "CORS MAY ADD OPTIONS");
            note("EACH NEW HOST CAN ADD DNS AND CONNECTION SETUP. CORS PREFLIGHT ADDS ANOTHER REQUEST AFTER THAT.");
        },
    }
}

fn drawCSRF() void {
    drawActors("EVIL SITE", "BANK", "BROWSER");
    switch (scenario) {
        .a => {
            title("CSRF USES THE VICTIM BROWSER");
            arrow(130, 190, 510, 190, C_WARN);
            step(32, 246, "1 VICTIM VISITS EVIL");
            step(226, 246, "2 FORM POSTS TO BANK");
            step(420, 246, "3 BANK COOKIE IS SENT");
            note("THE ATTACKER CANNOT READ THE RESPONSE. THE PROBLEM IS THAT THE BROWSER SENDS AUTH COOKIES.");
        },
        .b => {
            title("SAMESITE COOKIES REDUCE RISK");
            arrow(130, 190, 510, 190, C_LINE);
            box(350, 166, 150, 48, "COOKIE BLOCKED", C_PANEL);
            step(40, 246, "CROSS SITE POST");
            step(250, 246, "SAMESITE LAX STRICT");
            step(460, 246, "NO SESSION");
            note("SAMESITE CHANGES WHEN COOKIES ARE ATTACHED TO CROSS SITE REQUESTS.");
        },
        .c => {
            title("CSRF TOKEN PROVES PAGE ORIGIN");
            arrow(130, 190, 510, 190, C_OK);
            box(250, 166, 140, 48, "TOKEN MATCHES", C_SERVER);
            step(40, 246, "FORM HAS SECRET");
            step(250, 246, "SERVER CHECKS");
            step(460, 246, "ALLOW");
            note("A TOKEN IN THE PAGE BODY IS NOT AVAILABLE TO AN ATTACKER SITE BECAUSE SOP BLOCKS READING IT.");
        },
        .d => {
            title("GET MUST NOT CHANGE STATE");
            arrow(130, 190, 510, 190, C_WARN);
            step(40, 246, "IMG SRC TO BANK");
            step(250, 246, "BROWSER SENDS GET");
            step(460, 246, "BAD IF IT DELETES");
            note("STATE CHANGES ON GET ARE DANGEROUS. IMAGES LINKS AND PREFETCHES CAN TRIGGER THEM.");
        },
    }
}

fn drawXSS() void {
    drawActors("INPUT", "APP", "USER");
    switch (scenario) {
        .a => {
            title("REFLECTED XSS");
            arrow(130, 190, 510, 190, C_WARN);
            step(32, 246, "1 URL HAS SCRIPT");
            step(226, 246, "2 APP ECHOS HTML");
            step(420, 246, "3 SCRIPT RUNS AS APP");
            note("XSS MEANS ATTACKER CODE RUNS IN YOUR ORIGIN. IT CAN READ PAGE DATA AND ACT AS THE USER.");
        },
        .b => {
            title("STORED XSS");
            arrow(130, 176, 315, 176, C_WARN);
            arrow(315, 206, 510, 206, C_WARN);
            step(40, 246, "SAVE COMMENT");
            step(250, 246, "DATABASE STORES SCRIPT");
            step(460, 246, "EVERY VIEWER RUNS IT");
            note("STORED XSS IS WORSE BECAUSE ONE BAD INPUT CAN ATTACK MANY FUTURE VISITORS.");
        },
        .c => {
            title("DOM XSS");
            arrow(130, 190, 510, 190, C_WARN);
            step(40, 246, "HASH OR QUERY");
            step(250, 246, "CLIENT JS BUILDS HTML");
            step(460, 246, "SCRIPT EXECUTES");
            note("THE SERVER MAY BE FINE. UNSAFE CLIENT SIDE HTML ASSEMBLY CAN STILL CREATE XSS.");
        },
        .d => {
            title("ESCAPE BY CONTEXT");
            arrow(130, 190, 510, 190, C_OK);
            box(244, 166, 150, 48, "TEXT NODE", C_SERVER);
            step(40, 246, "USER INPUT");
            step(250, 246, "ESCAPE HTML");
            step(460, 246, "RENDER TEXT");
            note("ESCAPING TURNS MARKUP INTO TEXT. ATTRIBUTE URL CSS AND JS CONTEXTS NEED THEIR OWN RULES.");
        },
    }
}

fn drawActors(left: []const u8, right: []const u8, middle: []const u8) void {
    box(28, 140, 110, 60, left, C_ATTACK);
    box(265, 140, 110, 60, middle, C_BROWSER);
    box(502, 140, 110, 60, right, C_SERVER);
}

fn title(text: []const u8) void {
    drawText(20, 120, text, C_INK);
}

fn step(x: i32, y: i32, text: []const u8) void {
    drawWrappedText(x, y, 22, text, C_INK);
}

fn note(text: []const u8) void {
    fillRect(20, 322, 600, 70, C_PANEL);
    drawBorder(20, 322, 600, 70, C_LINE);
    drawWrappedText(34, 340, 68, text, C_MUTED);
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

test "topic switching starts with cors" {
    try std.testing.expect(topic == .cors);
}
