const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 760;
const RENDER_H: usize = 590;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const BTN_PRIMARY: i32 = 1 << 0;
const TIMELINE_NORMAL_MAX_MS: i32 = 4200;
const TIMELINE_ANNOYANCE_MAX_MS: i32 = 7200;
const PLAY_HOLD_MS: i32 = 2000;
const ANNOY_COOKIE: i32 = 1;
const ANNOY_CHAT: i32 = 2;
const ANNOY_PROMO: i32 = 4;

const Color = [4]u8;
const C_BG: Color = .{ 0xF7, 0xF4, 0xEC, 0xFF };
const C_PANEL: Color = .{ 0xFF, 0xFD, 0xF8, 0xFF };
const C_INK: Color = .{ 0x18, 0x1A, 0x1F, 0xFF };
const C_MUTED: Color = .{ 0x66, 0x63, 0x5C, 0xFF };
const C_LINE: Color = .{ 0xB8, 0xB0, 0xA4, 0xFF };
const C_ACTIVE: Color = .{ 0xF0, 0xE4, 0x42, 0xFF };
const C_DNS: Color = .{ 0x56, 0xB4, 0xE9, 0xFF };
const C_CONN: Color = .{ 0x66, 0xC2, 0xA5, 0xFF };
const C_TLS: Color = .{ 0xCC, 0x79, 0xA7, 0xFF };
const C_WAIT: Color = .{ 0xFC, 0x8D, 0x62, 0xFF };
const C_ORANGE: Color = .{ 0xFC, 0xD5, 0x9B, 0xFF };
const C_BODY: Color = .{ 0x8D, 0xA0, 0xCB, 0xFF };
const C_CACHE: Color = .{ 0xF0, 0xE4, 0x42, 0xFF };
const C_MARK: Color = .{ 0xD5, 0x5E, 0x00, 0xFF };
const C_OK: Color = .{ 0x00, 0x9E, 0x73, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var search_page = false;
var spa_style = false;
var tls13 = true;
var warm_assets = false;
var separate_cdn = true;
var far_server = false;
var airport_wifi = false;
var budget_phone = false;
var separate_api = true;
var cloud_db = false;
var n_plus_one = false;
var annoyance: i32 = 0;
var primary_down = false;
var playing = false;
var play_start_ms: i64 = 0;
var play_elapsed_ms: i32 = 0;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var next_wake_at_ms: i64 = 0;

const Timing = struct {
    html_ttfb: i32,
    app_start: i32,
    db_start: i32,
    db_done: i32,
    html_done: i32,
    css_done: i32,
    js_done: i32,
    image_done: i32,
    font_done: i32,
    api_done: i32,
    chat_js_done: i32,
    first_paint: i32,
    lcp: i32,
    readable: i32,
    usable: i32,
    annoyance_at: i32,
    annoyance_done: i32,
    fouc_start: i32,
    fouc_end: i32,
};

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

export fn key_event(_: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    return 0;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    const now_ms = begun_at_ms;
    if (!playing) return;
    const t = compute();
    const hide_at = t.usable + 180 + PLAY_HOLD_MS;
    const elapsed_i64 = now_ms - play_start_ms;
    play_elapsed_ms = @as(i32, @intCast(@min(@max(elapsed_i64, @as(i64, 0)), @as(i64, hide_at))));
    if (play_elapsed_ms >= hide_at) {
        playing = false;
        play_elapsed_ms = 0;
        next_wake_at_ms = now_ms;
        return;
    }
    next_wake_at_ms = if (now_ms <= std.math.maxInt(i64) - 33) now_ms + 33 else now_ms;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;
    if (down and !primary_down) {
        if (hit(x, y, 20, 40, 96, 24)) changed = setBool(&search_page, false);
        if (hit(x, y, 116, 40, 86, 24)) changed = setBool(&search_page, true);
        if (hit(x, y, 20, 70, 110, 24)) changed = flip(&spa_style);
        if (hit(x, y, 140, 70, 66, 24)) changed = flip(&separate_cdn);
        if (isSearch() and hit(x, y, 216, 70, 110, 24)) changed = flip(&cloud_db);
        if (isSearch() and hit(x, y, 336, 70, 150, 24)) changed = flip(&n_plus_one);
        if (isSearch() and hit(x, y, 496, 70, 120, 24)) changed = flip(&separate_api);
        if (hit(x, y, 20, 100, 28, 24)) changed = setBool(&airport_wifi, false);
        if (hit(x, y, 52, 100, 28, 24)) changed = setBool(&airport_wifi, true);
        if (hit(x, y, 92, 100, 36, 24)) changed = setBool(&budget_phone, false);
        if (hit(x, y, 132, 100, 28, 24)) changed = setBool(&budget_phone, true);
        if (hit(x, y, 172, 100, 150, 24)) changed = flip(&far_server);
        if (hit(x, y, 334, 100, 110, 24)) changed = flip(&tls13);
        if (hit(x, y, 456, 100, 90, 24)) changed = flip(&warm_assets);
        if (hit(x, y, 20, 130, 82, 24)) changed = toggleAnnoyance(ANNOY_COOKIE);
        if (hit(x, y, 112, 130, 74, 24)) changed = toggleAnnoyance(ANNOY_CHAT);
        if (hit(x, y, 196, 130, 74, 24)) changed = toggleAnnoyance(ANNOY_PROMO);
        if (hit(x, y, 670, 130, 70, 24)) {
            playing = true;
            play_start_ms = begun_at_ms;
            play_elapsed_ms = 0;
            changed = true;
        } else if (changed) {
            playing = false;
            play_elapsed_ms = 0;
        }
    }
    primary_down = down;
    return if (changed) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn flip(value: *bool) bool {
    value.* = !value.*;
    return true;
}

fn setBool(value: *bool, new_value: bool) bool {
    if (value.* == new_value) return false;
    value.* = new_value;
    return true;
}

fn toggleAnnoyance(flag: i32) bool {
    annoyance = annoyance ^ flag;
    return true;
}

fn hasAnnoyance(flag: i32) bool {
    return (annoyance & flag) != 0;
}

fn isSearch() bool {
    return search_page;
}

fn isSpa() bool {
    return spa_style;
}

fn usesBackend() bool {
    return isSearch();
}

fn pageLabel() []const u8 {
    return if (isSearch()) "SEARCH" else "LANDING";
}

fn renderLabel() []const u8 {
    return if (isSpa()) "SPA" else "SERVER";
}

fn apiLabel() []const u8 {
    return if (separate_api) "api. DOMAIN" else "/API PATH";
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
    advanceTransactionTime();
    next_wake_at_ms = if (playing and begun_at_ms <= std.math.maxInt(i64) - 33) begun_at_ms + 33 else begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn originRtt() i32 {
    return (if (far_server) @as(i32, 230) else @as(i32, 35)) + networkPenalty();
}

fn cdnRtt() i32 {
    return @as(i32, 45) + networkPenalty();
}

fn networkPenalty() i32 {
    return if (airport_wifi) @as(i32, 45) else @as(i32, 0);
}

fn dnsCostFor(route_rtt: i32) i32 {
    return @divTrunc(route_rtt, 2) + if (airport_wifi) @as(i32, 20) else @as(i32, 4);
}

fn tcpCostFor(route_rtt: i32) i32 {
    return route_rtt;
}

fn handshakeCostFor(route_rtt: i32) i32 {
    return if (tls13) route_rtt else route_rtt * 2;
}

fn requestCostFor(route_rtt: i32) i32 {
    return @divTrunc(route_rtt, 2) + if (airport_wifi) @as(i32, 25) else @as(i32, 6);
}

fn dnsCost() i32 {
    return dnsCostFor(originRtt());
}

fn tcpCost() i32 {
    return tcpCostFor(originRtt());
}

fn handshakeCost() i32 {
    return handshakeCostFor(originRtt());
}

fn requestCost() i32 {
    return requestCostFor(originRtt());
}

fn cdnRequestCost() i32 {
    return requestCostFor(cdnRtt());
}

fn transferCost(base: i32) i32 {
    return if (airport_wifi) base * 2 + 35 else base;
}

fn cpuCost(base: i32) i32 {
    return if (budget_phone) base * 3 else base;
}

fn connectCost() i32 {
    return connectCostFor(originRtt());
}

fn cdnConnectCost() i32 {
    return connectCostFor(cdnRtt());
}

fn connectCostFor(route_rtt: i32) i32 {
    return dnsCostFor(route_rtt) + tcpCostFor(route_rtt) + handshakeCostFor(route_rtt);
}

fn apiDnsCost() i32 {
    return if (warm_assets) @as(i32, 6) else dnsCostFor(originRtt());
}

fn apiConnectCost() i32 {
    if (!separate_api) return 0;
    return apiDnsCost() + tcpCostFor(originRtt()) + handshakeCostFor(originRtt());
}

fn apiRequestCost() i32 {
    return requestCost();
}

fn dbRtt() i32 {
    return if (cloud_db) @as(i32, 45) else @as(i32, 4);
}

fn dbQueryCount() i32 {
    return if (n_plus_one) @as(i32, 11) else @as(i32, 1);
}

fn dbCost() i32 {
    if (!usesBackend()) return 0;
    return dbQueryCount() * dbRtt() + if (n_plus_one) @as(i32, 30) else @as(i32, 18);
}

fn annoyanceCost() i32 {
    var cost: i32 = 0;
    if (hasAnnoyance(ANNOY_COOKIE)) cost += 650;
    if (hasAnnoyance(ANNOY_CHAT)) cost += 850;
    if (hasAnnoyance(ANNOY_PROMO)) cost += 1450;
    return cost;
}

fn compute() Timing {
    const html_req = requestCost();
    const server_render_db = isSearch() and !isSpa();
    const spa_api_db = isSearch() and isSpa();
    const base_server: i32 = if (isSpa()) 45 else if (isSearch()) 80 else 70;
    const app_start = connectCost() + html_req;
    const db_start = if (server_render_db) app_start + 25 else 0;
    const db_done = if (server_render_db) db_start + dbCost() else 0;
    const server = base_server + if (server_render_db) dbCost() else 0;
    const html_body = transferCost(if (isSpa()) 18 else if (isSearch()) 48 else 36);
    const html_ttfb = connectCost() + html_req + server;
    const html_done = html_ttfb + html_body;

    const asset_conn = if (separate_cdn) cdnConnectCost() else 0;
    const asset_req = if (separate_cdn) cdnRequestCost() else requestCost();
    const asset_start = html_done - @min(18, html_body);
    const css_parse = cpuCost(18);
    const css_done = if (warm_assets) asset_start + 10 + css_parse else asset_start + asset_conn + asset_req + transferCost(42) + css_parse;
    const image_count: i32 = if (isSearch()) 5 else 1;
    const image_transfer = transferCost(82) + if (isSearch()) transferCost(36) * (image_count - 1) else 0;
    const image_done = if (warm_assets) html_done + 12 + if (isSearch()) @as(i32, 18) else @as(i32, 0) else html_done + asset_conn + asset_req + image_transfer;
    const font_done = if (warm_assets) css_done + 10 else css_done + requestCost() + transferCost(54);
    const js_cpu = cpuCost(if (isSpa()) 70 else 16);
    const js_done = if (isSpa()) (if (warm_assets) html_done + 18 + js_cpu else html_done + asset_conn + asset_req + transferCost(96) + js_cpu) else html_done + cpuCost(8);
    const chat_js_done = if (hasAnnoyance(ANNOY_CHAT)) html_done + asset_conn + asset_req + transferCost(64) + cpuCost(55) else html_done;
    const api_conn = if (isSpa()) apiConnectCost() else 0;
    const api_req = if (isSpa()) apiRequestCost() else 0;
    const api_db_start = if (isSpa()) js_done + api_conn + api_req + 20 else 0;
    const api_db_done = if (spa_api_db) api_db_start + dbCost() else api_db_start;
    const api_done = if (isSpa()) api_db_done + 80 + transferCost(if (isSearch()) 30 else 18) else html_done;
    const effective_db_start = if (spa_api_db) api_db_start else db_start;
    const effective_db_done = if (spa_api_db) api_db_done else db_done;
    const first_paint = @max(html_done, css_done) + cpuCost(18);
    const lcp = if (isSpa()) @max(@max(api_done, css_done), font_done) + cpuCost(20) else @max(image_done, css_done) + cpuCost(16);
    const readable = @max(lcp, font_done) + if (hasAnnoyance(ANNOY_COOKIE)) @as(i32, 650) else @as(i32, 0);
    const annoyance_at = if (annoyance == 0) 0 else @max(readable + 180, if (hasAnnoyance(ANNOY_CHAT)) chat_js_done else readable);
    const annoyance_done = if (annoyance == 0) readable else annoyance_at + annoyanceCost();
    const usable_base = if (isSpa()) @max(api_done, js_done) else readable;
    const usable = @max(usable_base, annoyance_done);
    return .{
        .html_ttfb = html_ttfb,
        .app_start = app_start,
        .db_start = effective_db_start,
        .db_done = effective_db_done,
        .html_done = html_done,
        .css_done = css_done,
        .js_done = js_done,
        .image_done = image_done,
        .font_done = font_done,
        .api_done = api_done,
        .chat_js_done = chat_js_done,
        .first_paint = first_paint,
        .lcp = lcp,
        .readable = readable,
        .usable = usable,
        .annoyance_at = annoyance_at,
        .annoyance_done = annoyance_done,
        .fouc_start = html_done,
        .fouc_end = css_done,
    };
}

fn drawFrame() void {
    fillRect(0, 0, @intCast(RENDER_W), @intCast(RENDER_H), C_BG);
    drawText(20, 18, "PAGE LOAD WATERFALL", C_INK);
    pageRadio(20, 40, search_page);
    button(20, 70, 110, renderLabel(), isSpa());
    checkboxButton(140, 70, 66, "CDN", separate_cdn);
    if (isSearch()) {
        button(216, 70, 110, if (cloud_db) "CLOUD DB" else "LOCAL DB", cloud_db);
        button(336, 70, 150, if (n_plus_one) "N+1 QUERIES" else "BATCHED DB", n_plus_one);
        button(496, 70, 120, apiLabel(), separate_api);
    }
    networkChoice(20, 100, airport_wifi);
    deviceChoice(92, 100, budget_phone);
    button(172, 100, 150, if (far_server) "WORLD AWAY" else "NEAR SERVER", far_server);
    button(334, 100, 110, if (tls13) "TLS 1.3" else "TLS 1.2", tls13);
    checkboxButton(456, 100, 90, "CACHED", warm_assets);
    checkboxButton(20, 130, 82, "COOKIE", hasAnnoyance(ANNOY_COOKIE));
    checkboxButton(112, 130, 74, "CHAT", hasAnnoyance(ANNOY_CHAT));
    checkboxButton(196, 130, 74, "PROMO", hasAnnoyance(ANNOY_PROMO));
    button(670, 130, 70, if (playing) "PLAYING" else "PLAY", playing);
    legend();

    const t = compute();
    const max_t = timelineMaxMS();
    axis(max_t);
    rows(t, max_t);
    markers(t, max_t);
    summary(t);
    if (playing) drawPlaybackOverlay(t, max_t);
}

fn timelineMaxMS() i32 {
    return if (annoyance == 0) TIMELINE_NORMAL_MAX_MS else TIMELINE_ANNOYANCE_MAX_MS;
}

fn rows(t: Timing, max_t: i32) void {
    const y0: i32 = 200;
    const html_server = if (isSpa()) @as(i32, 45) else if (isSearch()) @as(i32, 80) else @as(i32, 70);
    rowLabel(20, y0 + 5, "HTML");
    connectionSetup(130, y0, 0, max_t);
    waterfall(130, y0, connectCost(), t.html_ttfb - html_server, max_t, "REQ", C_CONN);
    waterfall(130, y0, t.html_ttfb - html_server, t.html_ttfb, max_t, if (isSearch()) "APP" else "TTFB", C_WAIT);
    waterfall(130, y0, t.html_ttfb, t.html_done, max_t, "BODY", C_BODY);

    rowLabel(20, y0 + 40, "DB");
    if (usesBackend()) {
        waterfall(130, y0 + 35, t.db_start, t.db_done, max_t, if (n_plus_one) "N+1" else "QUERY", if (cloud_db) C_WAIT else C_CONN);
    } else {
        waterfall(130, y0 + 35, t.html_done, t.html_done + 8, max_t, "NONE", C_LINE);
    }

    const asset_start = t.html_done - 18;
    rowLabel(20, y0 + 75, "CSS");
    if (warm_assets) {
        waterfall(130, y0 + 70, asset_start, t.css_done, max_t, "CACHE", C_CACHE);
    } else {
        assetSetup(130, y0 + 70, asset_start, max_t);
        waterfall(130, y0 + 70, t.css_done - 42, t.css_done, max_t, "CSS", C_BODY);
    }

    rowLabel(20, y0 + 110, if (isSearch()) "5 IMAGES" else "HERO IMG");
    if (warm_assets) {
        waterfall(130, y0 + 105, t.html_done, t.image_done, max_t, "CACHE", C_CACHE);
    } else {
        assetSetup(130, y0 + 105, t.html_done, max_t);
        waterfall(130, y0 + 105, t.image_done - if (isSearch()) transferCost(36) else transferCost(82), t.image_done, max_t, if (isSearch()) "IMG 5" else "IMAGE", C_BODY);
    }

    rowLabel(20, y0 + 145, "FONT");
    if (warm_assets) {
        waterfall(130, y0 + 140, t.css_done, t.font_done, max_t, "CACHE", C_CACHE);
    } else {
        waterfall(130, y0 + 140, t.css_done, t.font_done, max_t, "FONT", C_BODY);
    }

    rowLabel(20, y0 + 180, "JS");
    if (isSpa()) {
        if (warm_assets) {
            waterfall(130, y0 + 175, t.html_done, t.js_done, max_t, "CACHE", C_CACHE);
        } else {
            assetSetup(130, y0 + 175, t.html_done, max_t);
            waterfall(130, y0 + 175, t.js_done - 96, t.js_done, max_t, "JS", C_BODY);
        }
    } else {
        waterfall(130, y0 + 175, t.html_done, t.html_done + 8, max_t, "NONE", C_LINE);
    }

    rowLabel(20, y0 + 215, "API");
    if (isSpa()) {
        if (separate_api) apiConnectionSetup(130, y0 + 210, t.js_done, max_t) else waterfall(130, y0 + 210, t.js_done, t.js_done + apiRequestCost(), max_t, "REUSE", C_CONN);
        waterfall(130, y0 + 210, t.api_done - 80 - transferCost(30), t.api_done - transferCost(30), max_t, "API", C_WAIT);
        waterfall(130, y0 + 210, t.api_done - transferCost(30), t.api_done, max_t, "DATA", C_BODY);
    } else {
        waterfall(130, y0 + 210, t.html_done, t.html_done + 8, max_t, "IN HTML", C_CACHE);
    }

    rowLabel(20, y0 + 250, "CHAT JS");
    if (hasAnnoyance(ANNOY_CHAT)) {
        const start = t.html_done;
        const script_conn = if (separate_cdn) cdnConnectCost() else 0;
        const script_req = if (separate_cdn) cdnRequestCost() else requestCost();
        if (separate_cdn) cdnConnectionSetup(130, y0 + 245, start, max_t) else waterfall(130, y0 + 245, start, start + script_req, max_t, "REUSE", C_CONN);
        waterfall(130, y0 + 245, start + script_conn + script_req, start + script_conn + script_req + transferCost(64), max_t, "CHAT", C_WAIT);
        waterfall(130, y0 + 245, start + script_conn + script_req + transferCost(64), t.chat_js_done, max_t, "EXEC", C_MARK);
    } else {
        waterfall(130, y0 + 245, t.html_done, t.html_done + 8, max_t, "NONE", C_LINE);
    }
}

fn assetSetup(x: i32, y: i32, start: i32, max_t: i32) void {
    if (separate_cdn) {
        cdnConnectionSetup(x, y, start, max_t);
        waterfall(x, y, start + cdnConnectCost(), start + cdnConnectCost() + cdnRequestCost(), max_t, "REQ", C_CONN);
    } else {
        waterfall(x, y, start, start + requestCost(), max_t, "REUSE", C_CONN);
    }
}

fn connectionSetup(x: i32, y: i32, start: i32, max_t: i32) void {
    connectionSetupFor(x, y, start, max_t, originRtt());
}

fn apiConnectionSetup(x: i32, y: i32, start: i32, max_t: i32) void {
    var cursor = start;
    const dns = apiDnsCost();
    waterfall(x, y, cursor, cursor + dns, max_t, if (warm_assets) "DNS CACHE" else "DNS", if (warm_assets) C_CACHE else C_DNS);
    cursor += dns;
    const tcp = tcpCostFor(originRtt());
    waterfall(x, y, cursor, cursor + tcp, max_t, "TCP", C_CONN);
    cursor += tcp;
    waterfall(x, y, cursor, start + apiConnectCost(), max_t, if (tls13) "TLS13" else "TLS12", C_TLS);
}

fn cdnConnectionSetup(x: i32, y: i32, start: i32, max_t: i32) void {
    connectionSetupFor(x, y, start, max_t, cdnRtt());
}

fn connectionSetupFor(x: i32, y: i32, start: i32, max_t: i32, route_rtt: i32) void {
    const dns = dnsCostFor(route_rtt);
    const tcp = tcpCostFor(route_rtt);
    waterfall(x, y, start, start + dns, max_t, "DNS", C_DNS);
    waterfall(x, y, start + dns, start + dns + tcp, max_t, "TCP", C_CONN);
    waterfall(x, y, start + dns + tcp, start + connectCostFor(route_rtt), max_t, if (tls13) "TLS13" else "TLS12", C_TLS);
}

fn waterfall(x: i32, y: i32, start: i32, end: i32, max_t: i32, label: []const u8, c: Color) void {
    const scale_w: i32 = 570;
    const sx = x + @divTrunc(start * scale_w, max_t);
    const ex = x + @divTrunc(end * scale_w, max_t);
    fillRect(sx, y, @max(3, ex - sx), 18, c);
    drawBorder(sx, y, @max(3, ex - sx), 18, C_INK);
    if (ex - sx > 46) drawText(sx + 4, y + 5, label, C_INK);
}

fn markers(t: Timing, max_t: i32) void {
    marker(t.html_ttfb, max_t, "TTFB", 142, C_MARK);
    marker(t.first_paint, max_t, "FP", 372, C_OK);
    if (t.fouc_end > t.fouc_start + 20) {
        band(t.fouc_start, t.fouc_end, max_t, "FOUC");
    }
    marker(t.lcp, max_t, "LCP", 424, C_MARK);
    marker(t.readable, max_t, "READ", 450, C_OK);
    marker(t.usable, max_t, "USE", 476, C_MARK);
}

fn marker(ms: i32, max_t: i32, label: []const u8, y: i32, c: Color) void {
    const x = 130 + @divTrunc(ms * 570, max_t);
    fillRect(x, 192, 2, 310, c);
    drawText(x + 4, y, label, c);
    var buf: [20]u8 = undefined;
    drawText(x + 4, y + 13, fmtMS(&buf, ms), c);
}

fn band(start: i32, end: i32, max_t: i32, label: []const u8) void {
    const x0 = 130 + @divTrunc(start * 570, max_t);
    const x1 = 130 + @divTrunc(end * 570, max_t);
    fillRect(x0, 344, @max(2, x1 - x0), 8, C_ORANGE);
    drawText(x0 + 3, 334, label, C_MARK);
}

fn axis(max_t: i32) void {
    drawLine(130, 178, 700, 178, C_LINE);
    var tick_ms: i32 = 0;
    while (tick_ms <= max_t) : (tick_ms += 100) {
        const x = 130 + @divTrunc(tick_ms * 570, max_t);
        fillRect(x, 174, 1, 328, C_LINE);
        var buf: [20]u8 = undefined;
        if (@mod(tick_ms, 600) == 0) drawText(x - 16, 160, fmtMS(&buf, tick_ms), C_MUTED);
    }
}

fn summary(t: Timing) void {
    fillRect(20, 535, 720, 40, C_PANEL);
    drawBorder(20, 535, 720, 40, C_LINE);
    var buf1: [20]u8 = undefined;
    var buf2: [20]u8 = undefined;
    var buf3: [20]u8 = undefined;
    drawText(34, 548, "TTFB", C_MUTED);
    drawText(86, 548, fmtMS(&buf1, t.html_ttfb), C_INK);
    drawText(180, 548, "READABLE", C_MUTED);
    drawText(278, 548, fmtMS(&buf2, t.readable), C_INK);
    drawText(410, 548, "CAN USE", C_MUTED);
    drawText(490, 548, fmtMS(&buf3, t.usable), C_INK);
    drawText(570, 548, summaryLabel(), if (isSpa() or isSearch() or budget_phone or airport_wifi or annoyance != 0) C_MARK else C_OK);
}

fn summaryLabel() []const u8 {
    if (airport_wifi) return "NETWORK LATENCY";
    if (far_server) return "FAR ORIGIN";
    if (budget_phone) return "SLOW CPU";
    if (annoyance != 0) return "UX INTERRUPTION";
    if (isSearch()) return "DB WAIT";
    return if (isSpa()) "JS + API WAIT" else "HTML CONTENT";
}

fn drawPlaybackOverlay(t: Timing, max_t: i32) void {
    const visible_ms = playbackVisibleMS(t);
    const playhead = 130 + @divTrunc(@min(visible_ms, max_t) * 570, max_t);
    fillRect(playhead, 178, 2, 306, C_INK);

    const x: i32 = 410;
    const y: i32 = 176;
    const w: i32 = 320;
    const h: i32 = 276;
    fillRect(x + 5, y + 5, w, h, .{ 0xD8, 0xD2, 0xC7, 0xFF });
    fillRect(x, y, w, h, C_PANEL);
    drawBorder(x, y, w, h, C_INK);
    fillRect(x, y, w, 24, C_INK);
    drawText(x + 8, y + 7, "BROWSER PREVIEW", C_PANEL);
    var buf: [20]u8 = undefined;
    drawText(x + w - 64, y + 7, fmtMS(&buf, visible_ms), C_ACTIVE);

    fillRect(x + 12, y + 34, w - 24, h - 46, .{ 0xFF, 0xFF, 0xFF, 0xFF });
    drawBorder(x + 12, y + 34, w - 24, h - 46, C_LINE);
    fillRect(x + 12, y + 34, w - 24, 22, .{ 0xF0, 0xF0, 0xEC, 0xFF });
    drawText(x + 22, y + 42, if (isSpa()) "APP + API" else "WWW.EXAMPLE", C_MUTED);

    const viewport_x = x + 26;
    const viewport_y = y + 72;
    if (visible_ms < t.html_ttfb) {
        drawCenteredStatus(viewport_x, viewport_y, "CONNECTING");
        return;
    }
    if (visible_ms < t.html_done) {
        drawCenteredStatus(viewport_x, viewport_y, "HTML STREAMING");
        return;
    }

    if (isSpa()) {
        drawSpaPreview(viewport_x, viewport_y, t, visible_ms);
    } else if (isSearch()) {
        drawSearchPreview(viewport_x, viewport_y, t, visible_ms);
    } else {
        drawStaticPreview(viewport_x, viewport_y, t, visible_ms);
    }
    drawAnnoyance(viewport_x, viewport_y, t, visible_ms);
}

fn playbackVisibleMS(t: Timing) i32 {
    return @min(play_elapsed_ms, t.usable + 180);
}

fn drawCenteredStatus(x: i32, y: i32, text: []const u8) void {
    fillRect(x + 22, y + 62, 224, 34, .{ 0xF7, 0xF4, 0xEC, 0xFF });
    drawBorder(x + 22, y + 62, 224, 34, C_LINE);
    drawText(x + 58, y + 74, text, C_MUTED);
}

fn drawStaticPreview(x: i32, y: i32, t: Timing, visible_ms: i32) void {
    const styled = visible_ms >= t.css_done;
    const hero = visible_ms >= t.image_done;
    const lcp_ready = visible_ms >= t.lcp;
    if (!styled) {
        drawText(x, y, "Example News", C_INK);
        drawText(x, y + 24, "A page rendered before CSS.", C_INK);
        drawText(x, y + 48, "HTML can appear early.", C_INK);
        drawText(x, y + 84, "FOUC", C_MARK);
        return;
    }

    fillRect(x, y, 268, 28, C_INK);
    drawText(x + 10, y + 9, "EXAMPLE NEWS", C_PANEL);
    fillRect(x, y + 42, 154, 18, C_ACTIVE);
    fillRect(x, y + 72, 220, 10, C_LINE);
    fillRect(x, y + 90, 184, 10, C_LINE);
    if (hero) {
        fillRect(x + 174, y + 42, 94, 78, C_BODY);
        drawBorder(x + 174, y + 42, 94, 78, C_INK);
        drawText(x + 194, y + 76, "IMAGE", C_INK);
    } else {
        fillRect(x + 174, y + 42, 94, 78, .{ 0xEF, 0xEF, 0xEA, 0xFF });
        drawBorder(x + 174, y + 42, 94, 78, C_LINE);
        drawText(x + 186, y + 76, "LOADING", C_MUTED);
    }
    if (lcp_ready) drawBadge(x + 214, y + 134, if (visible_ms >= t.usable) "USE" else "LCP");
}

fn drawSearchPreview(x: i32, y: i32, t: Timing, visible_ms: i32) void {
    const styled = visible_ms >= t.css_done;
    const results_ready = visible_ms >= t.lcp;
    if (styled) {
        fillRect(x, y, 268, 28, C_INK);
        drawText(x + 10, y + 9, "SEARCH", C_PANEL);
    } else {
        drawText(x, y, "Search", C_INK);
    }
    fillRect(x, y + 42, 210, 18, C_PANEL);
    drawBorder(x, y + 42, 210, 18, C_LINE);
    drawText(x + 8, y + 48, "QUERY", C_MUTED);
    if (!results_ready) {
        skeleton(x, y + 74);
        drawText(x + 64, y + 150, if (usesBackend()) "DATABASE" else "LOADING", C_MARK);
        return;
    }
    fillRect(x, y + 76, 238, 10, C_LINE);
    fillRect(x, y + 96, 190, 10, C_LINE);
    fillRect(x, y + 124, 222, 10, C_LINE);
    drawBadge(x + 214, y + 150, if (visible_ms >= t.usable) "USE" else "READ");
}

fn drawAnnoyance(x: i32, y: i32, t: Timing, visible_ms: i32) void {
    if (annoyance == 0 or visible_ms < t.annoyance_at or visible_ms >= t.annoyance_done) return;
    var start = t.annoyance_at;
    if (hasAnnoyance(ANNOY_COOKIE)) {
        if (visible_ms < start + 650) {
            fillRect(x, y + 28, 268, 24, C_ACTIVE);
            drawBorder(x, y + 28, 268, 24, C_INK);
            drawText(x + 8, y + 36, "COOKIE BANNER", C_INK);
            return;
        }
        start += 650;
    }
    if (hasAnnoyance(ANNOY_CHAT)) {
        if (visible_ms < start + 850) {
            fillRect(x + 210, y + 128, 58, 46, C_TLS);
            drawBorder(x + 210, y + 128, 58, 46, C_INK);
            drawText(x + 222, y + 146, "CHAT", C_INK);
            return;
        }
        start += 850;
    }
    if (hasAnnoyance(ANNOY_PROMO)) {
        fillRect(x, y, 268, 176, .{ 0xDD, 0xDD, 0xDD, 0xEE });
        fillRect(x + 38, y + 38, 192, 98, C_PANEL);
        drawBorder(x + 38, y + 38, 192, 98, C_INK);
        drawText(x + 62, y + 62, "PROMO OFFER", C_INK);
        drawText(x + 84, y + 92, "NOT NOW", C_MUTED);
        drawText(x + 214, y + 48, "X", C_MARK);
        const progress = @min(1000, @max(0, visible_ms - start - 350));
        const cursor_x = x + 120 + @divTrunc(progress * 94, 1000);
        const cursor_y = y + 150 - @divTrunc(progress * 102, 1000);
        fillRect(cursor_x, cursor_y, 10, 14, C_INK);
    }
}

fn drawSpaPreview(x: i32, y: i32, t: Timing, visible_ms: i32) void {
    const styled = visible_ms >= t.css_done;
    const js_ready = visible_ms >= t.js_done;
    const api_ready = visible_ms >= t.api_done;
    if (styled) {
        fillRect(x, y, 268, 28, C_INK);
        drawText(x + 10, y + 9, "DASHBOARD", C_PANEL);
    } else {
        drawText(x, y, "Dashboard", C_INK);
    }

    if (!js_ready) {
        skeleton(x, y + 48);
        drawText(x + 78, y + 128, "APP SHELL", C_MUTED);
        return;
    }
    if (!api_ready) {
        skeleton(x, y + 48);
        drawText(x + 66, y + 128, "FETCHING API", C_MARK);
        return;
    }

    fillRect(x, y + 48, 78, 62, C_ACTIVE);
    fillRect(x + 95, y + 48, 78, 62, C_CACHE);
    fillRect(x + 190, y + 48, 78, 62, C_BODY);
    drawText(x + 16, y + 72, "24K", C_INK);
    drawText(x + 115, y + 72, "91", C_INK);
    drawText(x + 206, y + 72, "8MS", C_INK);
    drawBadge(x + 214, y + 134, if (visible_ms >= t.usable) "USE" else "LCP");
}

fn skeleton(x: i32, y: i32) void {
    fillRect(x, y, 268, 64, .{ 0xF0, 0xF0, 0xEC, 0xFF });
    fillRect(x + 14, y + 16, 98, 12, C_LINE);
    fillRect(x + 14, y + 38, 156, 10, C_LINE);
    fillRect(x + 194, y + 14, 52, 36, C_LINE);
}

fn drawBadge(x: i32, y: i32, text: []const u8) void {
    fillRect(x, y, 42, 20, C_OK);
    drawBorder(x, y, 42, 20, C_INK);
    drawText(x + 8, y + 7, text, C_PANEL);
}

fn legend() void {
    legendItem(420, 18, "DNS", C_DNS);
    legendItem(480, 18, "CONN", C_CONN);
    legendItem(552, 18, "TLS", C_TLS);
    legendItem(612, 18, "WAIT", C_WAIT);
    legendItem(680, 18, "BODY", C_BODY);
    legendItem(420, 34, "CACHE", C_CACHE);
}

fn legendItem(x: i32, y: i32, label: []const u8, c: Color) void {
    fillRect(x, y, 12, 10, c);
    drawBorder(x, y, 12, 10, C_INK);
    drawText(x + 16, y, label, C_MUTED);
}

fn rowLabel(x: i32, y: i32, text: []const u8) void {
    drawText(x, y, text, C_INK);
}

fn pageRadio(x: i32, y: i32, search: bool) void {
    radioPill(x, y, 96, "LANDING", !search);
    radioPill(x + 96, y, 86, "SEARCH", search);
}

fn radioPill(x: i32, y: i32, w: i32, label: []const u8, selected: bool) void {
    const bg = if (selected) C_INK else C_PANEL;
    const fg = if (selected) C_PANEL else C_INK;
    fillRect(x + 3, y, w - 6, 24, bg);
    fillRect(x, y + 3, w, 18, bg);
    drawBorder(x + 3, y, w - 6, 24, C_INK);
    drawBorder(x, y + 3, w, 18, C_INK);
    drawText(x + 12, y + 8, label, fg);
}

fn checkboxButton(x: i32, y: i32, w: i32, label: []const u8, active: bool) void {
    _ = w;
    fillRect(x + 2, y + 6, 12, 12, C_PANEL);
    drawBorder(x + 2, y + 6, 12, 12, C_INK);
    if (active) fillRect(x + 5, y + 9, 6, 6, C_INK);
    drawText(x + 20, y + 8, label, C_INK);
}

fn networkChoice(x: i32, y: i32, poor: bool) void {
    signalChoice(x, y, 4, !poor);
    signalChoice(x + 32, y, 1, poor);
}

fn signalChoice(x: i32, y: i32, bars: i32, selected: bool) void {
    const bg = if (selected) C_INK else C_PANEL;
    const fg = if (selected) C_PANEL else C_INK;
    fillRect(x, y, 28, 24, bg);
    drawBorder(x, y, 28, 24, C_INK);
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const h = 3 + i * 3;
        const bx = x + 5 + i * 5;
        const by = y + 17 - h;
        if (i < bars) {
            fillRect(bx, by, 3, h, fg);
        } else {
            drawBorder(bx, by, 3, h, fg);
        }
    }
}

fn deviceChoice(x: i32, y: i32, budget: bool) void {
    laptopChoice(x, y, !budget);
    phoneChoice(x + 40, y, budget);
}

fn laptopChoice(x: i32, y: i32, selected: bool) void {
    const bg = if (selected) C_INK else C_PANEL;
    const fg = if (selected) C_PANEL else C_INK;
    fillRect(x, y, 36, 24, bg);
    drawBorder(x, y, 36, 24, C_INK);
    drawBorder(x + 6, y + 5, 20, 12, fg);
    fillRect(x + 4, y + 18, 24, 2, fg);
    drawDollar(x + 8, y + 7, fg);
    drawDollar(x + 14, y + 7, fg);
    drawDollar(x + 20, y + 7, fg);
}

fn phoneChoice(x: i32, y: i32, selected: bool) void {
    const bg = if (selected) C_INK else C_PANEL;
    const fg = if (selected) C_PANEL else C_INK;
    fillRect(x, y, 28, 24, bg);
    drawBorder(x, y, 28, 24, C_INK);
    drawBorder(x + 8, y + 4, 12, 17, fg);
    fillRect(x + 13, y + 17, 2, 2, fg);
    drawDollar(x + 11, y + 8, fg);
}

fn drawDollar(x: i32, y: i32, c: Color) void {
    fillRect(x + 2, y, 1, 9, c);
    fillRect(x, y + 1, 5, 1, c);
    fillRect(x, y + 1, 1, 3, c);
    fillRect(x, y + 4, 5, 1, c);
    fillRect(x + 4, y + 4, 1, 3, c);
    fillRect(x, y + 7, 5, 1, c);
}

fn button(x: i32, y: i32, w: i32, label: []const u8, active: bool) void {
    fillRect(x, y, w, 24, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, 24, C_INK);
    drawText(x + 8, y + 8, label, C_INK);
}

fn fmtMS(buf: *[20]u8, n: i32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}ms", .{n}) catch "";
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len and i < 96) : (i += 1) drawChar(x + @as(i32, @intCast(i)) * 8, y, text[i], c);
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const glyph_rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((glyph_rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) != 0) fillRect(x + @as(i32, @intCast(rx * 2)), y + @as(i32, @intCast(ry * 2)), 2, 2, c);
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
        '$' => .{ 0b111, 0b110, 0b111, 0b011, 0b111 },
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
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

fn drawLine(x0: i32, y0: i32, x1: i32, y1: i32, c: Color) void {
    if (y0 == y1) fillRect(@min(x0, x1), y0, if (x1 >= x0) x1 - x0 else x0 - x1, 1, c);
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

test "spa has later lcp than server landing with defaults" {
    search_page = false;
    spa_style = false;
    const server_t = compute();
    spa_style = true;
    const spa_t = compute();
    try std.testing.expect(spa_t.lcp > server_t.lcp);
}
