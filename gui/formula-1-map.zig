const ktx = @import("ktx2_rgba8_srgb");
const world_land = @import("assets/world_land_110m.zig");

const RENDER_W: usize = 960;
const RENDER_H: usize = 560;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_ESCAPE: i32 = 0xFF1B;

const BASE_SCALE: f64 = 500.0;
const MIN_ZOOM: f64 = 0.86;
const MAX_ZOOM: f64 = 11.0;

const Color = [4]u8;
const C_OCEAN_TOP: Color = .{ 0xB9, 0xDA, 0xE4, 0xFF };
const C_OCEAN_BOTTOM: Color = .{ 0x86, 0xB8, 0xCA, 0xFF };
const C_GRID: Color = .{ 0xD9, 0xEA, 0xEF, 0xFF };
const C_LAND: Color = .{ 0xD8, 0xD1, 0xA9, 0xFF };
const C_LAND_DARK: Color = .{ 0x9B, 0x9C, 0x75, 0xFF };
const C_MARKER: Color = .{ 0xE1, 0x06, 0x00, 0xFF };
const C_MARKER_DARK: Color = .{ 0x8F, 0x08, 0x08, 0xFF };
const C_WHITE: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_PANEL: Color = .{ 0xF7, 0xF5, 0xEC, 0xFF };
const C_PANEL_SHADOW: Color = .{ 0x58, 0x74, 0x7D, 0xFF };
const C_TEXT: Color = .{ 0x1D, 0x28, 0x2C, 0xFF };
const C_MUTED: Color = .{ 0x5D, 0x6B, 0x70, 0xFF };
const C_BUTTON: Color = .{ 0xF2, 0xF0, 0xE7, 0xFF };
const C_BUTTON_ACTIVE: Color = .{ 0xFF, 0xD5, 0x3C, 0xFF };

const GeoPoint = struct {
    lon: f64,
    lat: f64,
};

const PointF = struct {
    x: f64,
    y: f64,
};

const Venue = struct {
    round: u8,
    lon: f64,
    lat: f64,
    city: []const u8,
    circuit: []const u8,
    gp: []const u8,
};

// Venue list follows the official 2026 F1 race calendar:
// https://www.formula1.com/en/racing/2026
// Coordinates are approximate circuit locations.
const venues = [_]Venue{
    .{ .round = 1, .lon = 144.9680, .lat = -37.8497, .city = "MELBOURNE", .circuit = "ALBERT PARK", .gp = "AUSTRALIAN GP" },
    .{ .round = 2, .lon = 121.2200, .lat = 31.3389, .city = "SHANGHAI", .circuit = "SHANGHAI INTL", .gp = "CHINESE GP" },
    .{ .round = 3, .lon = 136.5410, .lat = 34.8431, .city = "SUZUKA", .circuit = "SUZUKA", .gp = "JAPANESE GP" },
    .{ .round = 4, .lon = -80.2389, .lat = 25.9581, .city = "MIAMI", .circuit = "MIAMI AUTODROME", .gp = "MIAMI GP" },
    .{ .round = 5, .lon = -73.5228, .lat = 45.5001, .city = "MONTREAL", .circuit = "GILLES VILLENEUVE", .gp = "CANADIAN GP" },
    .{ .round = 6, .lon = 7.4206, .lat = 43.7347, .city = "MONACO", .circuit = "CIRCUIT DE MONACO", .gp = "MONACO GP" },
    .{ .round = 7, .lon = 2.2611, .lat = 41.5700, .city = "BARCELONA", .circuit = "CATALUNYA", .gp = "BARCELONA GP" },
    .{ .round = 8, .lon = 14.7647, .lat = 47.2197, .city = "SPIELBERG", .circuit = "RED BULL RING", .gp = "AUSTRIAN GP" },
    .{ .round = 9, .lon = -1.0147, .lat = 52.0733, .city = "SILVERSTONE", .circuit = "SILVERSTONE", .gp = "BRITISH GP" },
    .{ .round = 10, .lon = 5.9714, .lat = 50.4372, .city = "SPA", .circuit = "SPA FRANCORCHAMPS", .gp = "BELGIAN GP" },
    .{ .round = 11, .lon = 19.2526, .lat = 47.5830, .city = "BUDAPEST", .circuit = "HUNGARORING", .gp = "HUNGARIAN GP" },
    .{ .round = 12, .lon = 4.5409, .lat = 52.3888, .city = "ZANDVOORT", .circuit = "ZANDVOORT", .gp = "DUTCH GP" },
    .{ .round = 13, .lon = 9.2811, .lat = 45.6156, .city = "MONZA", .circuit = "MONZA", .gp = "ITALIAN GP" },
    .{ .round = 14, .lon = -3.6160, .lat = 40.4630, .city = "MADRID", .circuit = "MADRING", .gp = "SPANISH GP" },
    .{ .round = 15, .lon = 49.8533, .lat = 40.3725, .city = "BAKU", .circuit = "BAKU CITY", .gp = "AZERBAIJAN GP" },
    .{ .round = 16, .lon = 103.8640, .lat = 1.2914, .city = "SINGAPORE", .circuit = "MARINA BAY", .gp = "SINGAPORE GP" },
    .{ .round = 17, .lon = -97.6411, .lat = 30.1328, .city = "AUSTIN", .circuit = "COTA", .gp = "UNITED STATES GP" },
    .{ .round = 18, .lon = -99.0907, .lat = 19.4042, .city = "MEXICO CITY", .circuit = "HERMANOS RODRIGUEZ", .gp = "MEXICO CITY GP" },
    .{ .round = 19, .lon = -46.6997, .lat = -23.7036, .city = "SAO PAULO", .circuit = "INTERLAGOS", .gp = "SAO PAULO GP" },
    .{ .round = 20, .lon = -115.1728, .lat = 36.1147, .city = "LAS VEGAS", .circuit = "LAS VEGAS STRIP", .gp = "LAS VEGAS GP" },
    .{ .round = 21, .lon = 51.4542, .lat = 25.4900, .city = "LUSAIL", .circuit = "LUSAIL", .gp = "QATAR GP" },
    .{ .round = 22, .lon = 54.6031, .lat = 24.4672, .city = "ABU DHABI", .circuit = "YAS MARINA", .gp = "ABU DHABI GP" },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var center_lon: f64 = 8.0;
var center_lat: f64 = 9.0;
var zoom: f64 = 1.05;
var selected_index: usize = 8;
var hover_index: i32 = -1;
var primary_down: bool = false;
var dragging_map: bool = false;
var last_pointer_x: i32 = 0;
var last_pointer_y: i32 = 0;
var drag_pixels: i32 = 0;

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

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    const scale = currentScale();
    switch (x11_key) {
        '+', '=' => zoomAt(1.28, @as(i32, @intCast(RENDER_W / 2)), @as(i32, @intCast(RENDER_H / 2))),
        '-' => zoomAt(1.0 / 1.28, @as(i32, @intCast(RENDER_W / 2)), @as(i32, @intCast(RENDER_H / 2))),
        '0', XK_ESCAPE => resetView(),
        XK_LEFT => panBy(@as(f64, -42.0), 0, scale),
        XK_RIGHT => panBy(@as(f64, 42.0), 0, scale),
        XK_UP => panBy(0, @as(f64, -32.0), scale),
        XK_DOWN => panBy(0, @as(f64, 32.0), scale),
        else => return 0,
    }
    clampView();
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    if (down and !primary_down) {
        last_pointer_x = x_px;
        last_pointer_y = y_px;
        drag_pixels = 0;
        dragging_map = false;

        if (hit(x_px, y_px, 18, 18, 34, 34)) {
            zoomAt(1.28, @as(i32, @intCast(RENDER_W / 2)), @as(i32, @intCast(RENDER_H / 2)));
            changed = true;
        } else if (hit(x_px, y_px, 18, 56, 34, 34)) {
            zoomAt(1.0 / 1.28, @as(i32, @intCast(RENDER_W / 2)), @as(i32, @intCast(RENDER_H / 2)));
            changed = true;
        } else if (hit(x_px, y_px, 18, 94, 34, 34)) {
            resetView();
            changed = true;
        } else {
            if (hitVenueAt(x_px, y_px)) |idx| {
                selected_index = idx;
                changed = true;
            }
            dragging_map = true;
        }
    } else if (down and primary_down and dragging_map) {
        const dx = x_px - last_pointer_x;
        const dy = y_px - last_pointer_y;
        if (dx != 0 or dy != 0) {
            panBy(@as(f64, @floatFromInt(dx)), @as(f64, @floatFromInt(dy)), currentScale());
            drag_pixels += absI32(dx) + absI32(dy);
            last_pointer_x = x_px;
            last_pointer_y = y_px;
            changed = true;
        }
    } else if (!down and primary_down) {
        if (drag_pixels < 5) {
            if (hitVenueAt(x_px, y_px)) |idx| {
                selected_index = idx;
                changed = true;
            }
        }
        dragging_map = false;
    } else if (!down) {
        const new_hover = if (hitVenueAt(x_px, y_px)) |idx| @as(i32, @intCast(idx)) else -1;
        if (new_hover != hover_index) {
            hover_index = new_hover;
            changed = true;
        }
    }

    primary_down = down;
    if (changed) clampView();
    return if (changed) 1 else 0;
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

fn resetView() void {
    center_lon = 8.0;
    center_lat = 9.0;
    zoom = 1.05;
}

fn currentScale() f64 {
    return BASE_SCALE * zoom;
}

fn zoomAt(factor: f64, anchor_x: i32, anchor_y: i32) void {
    const before = screenToGeo(anchor_x, anchor_y);
    zoom = clampF64(zoom * factor, MIN_ZOOM, MAX_ZOOM);
    const scale = currentScale();
    const dx = (@as(f64, @floatFromInt(anchor_x)) - @as(f64, @floatFromInt(RENDER_W)) * 0.5) / scale;
    const dy = (@as(f64, @floatFromInt(anchor_y)) - @as(f64, @floatFromInt(RENDER_H)) * 0.5) / scale;
    center_lon = before.lon - dx * 180.0;
    center_lat = before.lat + dy * 180.0;
}

fn panBy(dx_px: f64, dy_px: f64, scale: f64) void {
    center_lon -= dx_px / scale * 180.0;
    center_lat += dy_px / scale * 180.0;
}

fn clampView() void {
    center_lat = clampF64(center_lat, -82.0, 82.0);
    while (center_lon < -180.0) center_lon += 360.0;
    while (center_lon > 180.0) center_lon -= 360.0;
    zoom = clampF64(zoom, MIN_ZOOM, MAX_ZOOM);
}

fn screenToGeo(x: i32, y: i32) GeoPoint {
    const scale = currentScale();
    const dx = (@as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(RENDER_W)) * 0.5) / scale;
    const dy = (@as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(RENDER_H)) * 0.5) / scale;
    return .{
        .lon = center_lon + dx * 180.0,
        .lat = center_lat - dy * 180.0,
    };
}

fn project(lon: f64, lat: f64) PointF {
    const scale = currentScale();
    return .{
        .x = @as(f64, @floatFromInt(RENDER_W)) * 0.5 + ((lon - center_lon) / 180.0) * scale,
        .y = @as(f64, @floatFromInt(RENDER_H)) * 0.5 + ((center_lat - lat) / 180.0) * scale,
    };
}

fn displayLon(lon: f64) f64 {
    var out = lon;
    while (out - center_lon > 180.0) out -= 360.0;
    while (out - center_lon < -180.0) out += 360.0;
    return out;
}

fn drawFrame() void {
    drawOcean();
    drawGrid();
    drawLandMasses();
    drawVenues();
    drawChrome();
}

fn drawOcean() void {
    var y: usize = 0;
    while (y < RENDER_H) : (y += 1) {
        const t = @as(u32, @intCast((y * 255) / (RENDER_H - 1)));
        const c = lerpColor(C_OCEAN_TOP, C_OCEAN_BOTTOM, t);
        fillRect(0, @as(i32, @intCast(y)), @as(i32, @intCast(RENDER_W)), 1, c);
    }
}

fn drawGrid() void {
    var lon: i32 = -180;
    while (lon <= 180) : (lon += 30) {
        drawGeoLineRepeated(@as(f64, @floatFromInt(lon)), -80.0, @as(f64, @floatFromInt(lon)), 80.0, C_GRID);
    }

    var lat: i32 = -60;
    while (lat <= 75) : (lat += 15) {
        drawGeoLineRepeated(-180.0, @as(f64, @floatFromInt(lat)), 180.0, @as(f64, @floatFromInt(lat)), C_GRID);
    }
}

fn drawLandMasses() void {
    var i: usize = 0;
    while (i < world_land.rings.len) : (i += 1) {
        drawLandRingRepeated(world_land.rings[i]);
    }
}

fn drawLandRingRepeated(ring: world_land.Ring) void {
    drawLandRing(ring, -360.0);
    drawLandRing(ring, 0.0);
    drawLandRing(ring, 360.0);
}

fn drawLandRing(ring: world_land.Ring, lon_offset: f64) void {
    if (ring.len < 3) return;
    if (!ringNearViewportX(ring, lon_offset)) return;

    var min_y = @as(i32, @intFromFloat(@floor(projectY(coordToDeg(ring.max_lat)))));
    var max_y = @as(i32, @intFromFloat(@ceil(projectY(coordToDeg(ring.min_lat)))));
    if (max_y < 0 or min_y >= @as(i32, @intCast(RENDER_H))) return;
    min_y = @max(0, min_y);
    max_y = @min(@as(i32, @intCast(RENDER_H - 1)), max_y);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const scan_y = @as(f64, @floatFromInt(y)) + 0.5;
        var xs: [256]f64 = undefined;
        var n: usize = 0;

        var b: u16 = 0;
        while (b < ring.len) : (b += 1) {
            const a = if (b == 0) ring.len - 1 else b - 1;
            const p0 = landPoint(ring, a);
            const p1 = landPoint(ring, b);
            const y0 = projectY(coordToDeg(p0.lat));
            const y1 = projectY(coordToDeg(p1.lat));
            if ((y0 <= scan_y and y1 > scan_y) or (y1 <= scan_y and y0 > scan_y)) {
                var lon0 = coordToDeg(p0.lon) + lon_offset;
                var lon1 = coordToDeg(p1.lon) + lon_offset;
                adjustEdgeLongitudes(&lon0, &lon1);
                const x0 = projectX(lon0);
                const x1 = projectX(lon1);
                const t = (scan_y - y0) / (y1 - y0);
                if (n < xs.len) {
                    xs[n] = x0 + t * (x1 - x0);
                    n += 1;
                }
            }
        }

        sortF64(xs[0..n]);
        var pair: usize = 0;
        while (pair + 1 < n) : (pair += 2) {
            const x0 = @as(i32, @intFromFloat(@ceil(xs[pair])));
            const x1 = @as(i32, @intFromFloat(@floor(xs[pair + 1])));
            if (x1 >= x0) fillRect(x0, y, x1 - x0 + 1, 1, C_LAND);
        }
    }

    var p: u16 = 0;
    while (p < ring.len) : (p += 1) {
        const q = if (p + 1 == ring.len) 0 else p + 1;
        const p0 = landPoint(ring, p);
        const p1 = landPoint(ring, q);
        var lon0 = coordToDeg(p0.lon) + lon_offset;
        var lon1 = coordToDeg(p1.lon) + lon_offset;
        adjustEdgeLongitudes(&lon0, &lon1);
        drawGeoLine(lon0, coordToDeg(p0.lat), lon1, coordToDeg(p1.lat), C_LAND_DARK);
    }
}

fn landPoint(ring: world_land.Ring, index: u16) world_land.Coord {
    return world_land.points[@as(usize, ring.start) + @as(usize, index)];
}

fn coordToDeg(value: anytype) f64 {
    return @as(f64, @floatFromInt(value)) * world_land.SCALE;
}

fn ringNearViewportX(ring: world_land.Ring, lon_offset: f64) bool {
    const x0 = projectX(coordToDeg(ring.min_lon) + lon_offset);
    const x1 = projectX(coordToDeg(ring.max_lon) + lon_offset);
    return @max(x0, x1) >= -32.0 and @min(x0, x1) <= @as(f64, @floatFromInt(RENDER_W)) + 32.0;
}

fn projectX(lon: f64) f64 {
    return @as(f64, @floatFromInt(RENDER_W)) * 0.5 + ((lon - center_lon) / 180.0) * currentScale();
}

fn projectY(lat: f64) f64 {
    return @as(f64, @floatFromInt(RENDER_H)) * 0.5 + ((center_lat - lat) / 180.0) * currentScale();
}

fn adjustEdgeLongitudes(lon0: *f64, lon1: *f64) void {
    while (lon1.* - lon0.* > 180.0) lon1.* -= 360.0;
    while (lon1.* - lon0.* < -180.0) lon1.* += 360.0;
}

fn drawGeoLineRepeated(lon0: f64, lat0: f64, lon1: f64, lat1: f64, c: Color) void {
    drawGeoLine(lon0 - 360.0, lat0, lon1 - 360.0, lat1, c);
    drawGeoLine(lon0, lat0, lon1, lat1, c);
    drawGeoLine(lon0 + 360.0, lat0, lon1 + 360.0, lat1, c);
}

fn drawGeoLine(lon0: f64, lat0: f64, lon1: f64, lat1: f64, c: Color) void {
    const p0 = project(lon0, lat0);
    const p1 = project(lon1, lat1);
    drawLine(
        @as(i32, @intFromFloat(@round(p0.x))),
        @as(i32, @intFromFloat(@round(p0.y))),
        @as(i32, @intFromFloat(@round(p1.x))),
        @as(i32, @intFromFloat(@round(p1.y))),
        c,
    );
}

fn drawVenues() void {
    var i: usize = 0;
    while (i < venues.len) : (i += 1) {
        const p = venueScreen(i);
        if (!nearViewport(p, 42.0)) continue;

        const active = @as(i32, @intCast(i)) == hover_index or i == selected_index;
        if (active) fillCircle(@intFromFloat(@round(p.x)), @intFromFloat(@round(p.y)), 11, C_WHITE);
        fillCircle(@intFromFloat(@round(p.x)), @intFromFloat(@round(p.y)), if (active) 8 else 6, C_MARKER_DARK);
        fillCircle(@intFromFloat(@round(p.x)), @intFromFloat(@round(p.y)), if (active) 6 else 4, C_MARKER);

        var round_buf: [3]u8 = undefined;
        const label = roundText(&round_buf, venues[i].round);
        const tx = @as(i32, @intFromFloat(@round(p.x))) - @divTrunc(textWidth(label, 1), 2);
        drawText(tx, @as(i32, @intFromFloat(@round(p.y))) - 3, label, C_WHITE, 1);

        if (zoom >= 2.1 and !active) {
            drawSmallVenueLabel(i, p);
        }
    }

    if (hover_index >= 0) {
        drawVenueCallout(@as(usize, @intCast(hover_index)));
    } else {
        drawVenueCallout(selected_index);
    }
}

fn drawSmallVenueLabel(index: usize, p: PointF) void {
    const v = venues[index];
    const text = v.city;
    const w = textWidth(text, 1) + 8;
    var x = @as(i32, @intFromFloat(@round(p.x))) + 8;
    var y = @as(i32, @intFromFloat(@round(p.y))) - 7;
    if (x + w > @as(i32, @intCast(RENDER_W)) - 4) x = @as(i32, @intFromFloat(@round(p.x))) - w - 8;
    if (y < 4) y = 4;
    if (y > @as(i32, @intCast(RENDER_H)) - 18) y = @as(i32, @intCast(RENDER_H)) - 18;
    fillRect(x, y, w, 14, C_PANEL);
    drawRect(x, y, w, 14, C_PANEL_SHADOW);
    drawText(x + 4, y + 3, text, C_TEXT, 1);
}

fn drawVenueCallout(index: usize) void {
    const v = venues[index];
    const p = venueScreen(index);

    const w0 = textWidth(v.city, 2);
    const w1 = textWidth(v.circuit, 1);
    const w2 = textWidth(v.gp, 1);
    const w = @max(@max(w0, w1), w2) + 24;
    const h = 58;
    var x = @as(i32, @intFromFloat(@round(p.x))) + 18;
    var y = @as(i32, @intFromFloat(@round(p.y))) - 18;
    if (x + w > @as(i32, @intCast(RENDER_W)) - 12) x = @as(i32, @intFromFloat(@round(p.x))) - w - 18;
    if (y + h > @as(i32, @intCast(RENDER_H)) - 12) y = @as(i32, @intCast(RENDER_H)) - h - 12;
    if (y < 12) y = 12;
    if (x < 64) x = 64;

    drawLine(@as(i32, @intFromFloat(@round(p.x))), @as(i32, @intFromFloat(@round(p.y))), x, y + 18, C_MARKER_DARK);
    fillRect(x + 3, y + 3, w, h, C_PANEL_SHADOW);
    fillRect(x, y, w, h, C_PANEL);
    drawRect(x, y, w, h, C_TEXT);

    var round_buf: [8]u8 = undefined;
    drawText(x + 10, y + 8, roundLine(&round_buf, v.round), C_MARKER_DARK, 1);
    drawText(x + 10, y + 22, v.city, C_TEXT, 2);
    drawText(x + 10, y + 42, v.gp, C_MUTED, 1);
}

fn drawChrome() void {
    drawButton(18, 18, "+", false);
    drawButton(18, 56, "-", false);
    drawButton(18, 94, "0", false);

    const panel_x = 626;
    const panel_y = 18;
    const panel_w = 316;
    const panel_h = 90;
    fillRect(panel_x + 3, panel_y + 3, panel_w, panel_h, C_PANEL_SHADOW);
    fillRect(panel_x, panel_y, panel_w, panel_h, C_PANEL);
    drawRect(panel_x, panel_y, panel_w, panel_h, C_TEXT);

    drawText(panel_x + 14, panel_y + 12, "2026 F1 VENUES", C_MUTED, 2);
    drawText(panel_x + 14, panel_y + 37, venues[selected_index].city, C_TEXT, 2);
    drawText(panel_x + 14, panel_y + 60, venues[selected_index].circuit, C_MUTED, 1);
    drawText(panel_x + 14, panel_y + 73, venues[selected_index].gp, C_MARKER_DARK, 1);

    var count_buf: [12]u8 = undefined;
    drawText(18, @as(i32, @intCast(RENDER_H)) - 24, venueCountText(&count_buf), C_TEXT, 1);
}

fn drawButton(x: i32, y: i32, label: []const u8, active: bool) void {
    fillRect(x + 2, y + 2, 34, 34, C_PANEL_SHADOW);
    fillRect(x, y, 34, 34, if (active) C_BUTTON_ACTIVE else C_BUTTON);
    drawRect(x, y, 34, 34, C_TEXT);
    drawText(x + 13, y + 10, label, C_TEXT, 2);
}

fn hitVenueAt(x: i32, y: i32) ?usize {
    var i: usize = venues.len;
    while (i > 0) {
        i -= 1;
        const p = venueScreen(i);
        const dx = @as(i32, @intFromFloat(@round(p.x))) - x;
        const dy = @as(i32, @intFromFloat(@round(p.y))) - y;
        if (dx * dx + dy * dy <= 14 * 14) return i;
    }
    return null;
}

fn venueScreen(index: usize) PointF {
    const v = venues[index];
    return project(displayLon(v.lon), v.lat);
}

fn nearViewport(p: PointF, margin: f64) bool {
    return p.x >= -margin and p.y >= -margin and p.x <= @as(f64, @floatFromInt(RENDER_W)) + margin and p.y <= @as(f64, @floatFromInt(RENDER_H)) + margin;
}

fn roundText(buf: *[3]u8, round: u8) []const u8 {
    if (round < 10) {
        buf[0] = '0' + round;
        return buf[0..1];
    }
    buf[0] = '0' + @divTrunc(round, 10);
    buf[1] = '0' + @mod(round, 10);
    return buf[0..2];
}

fn roundLine(buf: *[8]u8, round: u8) []const u8 {
    buf[0] = 'R';
    if (round < 10) {
        buf[1] = '0' + round;
        return buf[0..2];
    }
    buf[1] = '0' + @divTrunc(round, 10);
    buf[2] = '0' + @mod(round, 10);
    return buf[0..3];
}

fn venueCountText(buf: *[12]u8) []const u8 {
    buf[0] = '2';
    buf[1] = '2';
    buf[2] = ' ';
    buf[3] = 'V';
    buf[4] = 'E';
    buf[5] = 'N';
    buf[6] = 'U';
    buf[7] = 'E';
    buf[8] = 'S';
    return buf[0..9];
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var cursor = x;
    var i: usize = 0;
    while (i < text.len and i < 40) : (i += 1) {
        drawChar(cursor, y, text[i], c, scale);
        cursor += 4 * scale;
    }
}

fn textWidth(text: []const u8, scale: i32) i32 {
    return @as(i32, @intCast(text.len)) * 4 * scale;
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) != 0) {
                fillRect(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, c);
            }
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N' => .{ 0b101, 0b111, 0b111, 0b111, 0b101 },
        'O' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P' => .{ 0b111, 0b101, 0b111, 0b100, 0b100 },
        'Q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '.' => .{ 0b000, 0b000, 0b000, 0b000, 0b010 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        else => .{ 0, 0, 0, 0, 0 },
    };
}

fn drawLine(x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, c: Color) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const x1 = x1_in;
    const y1 = y1_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    while (true) {
        setPixel(x0, y0, c);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = -r;
    while (y <= r) : (y += 1) {
        var x = -r;
        while (x <= r) : (x += 1) {
            if (x * x + y * y <= r * r) setPixel(cx + x, cy + y, c);
        }
    }
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    drawLine(x, y, x + w - 1, y, c);
    drawLine(x, y, x, y + h - 1, c);
    drawLine(x + w - 1, y, x + w - 1, y + h - 1, c);
    drawLine(x, y + h - 1, x + w - 1, y + h - 1, c);
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = @max(0, x);
    const sy = @max(0, y);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y + h);
    if (sx >= ex or sy >= ey) return;

    var yy = sy;
    while (yy < ey) : (yy += 1) {
        var xx = sx;
        while (xx < ex) : (xx += 1) setPixel(xx, yy, c);
    }
}

fn setPixel(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const ux = @as(usize, @intCast(x));
    const uy = @as(usize, @intCast(y));
    const idx = (uy * RENDER_W + ux) * 4;
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn lerpColor(a: Color, b: Color, t: u32) Color {
    const inv = 255 - t;
    return .{
        @as(u8, @intCast((@as(u32, a[0]) * inv + @as(u32, b[0]) * t) / 255)),
        @as(u8, @intCast((@as(u32, a[1]) * inv + @as(u32, b[1]) * t) / 255)),
        @as(u8, @intCast((@as(u32, a[2]) * inv + @as(u32, b[2]) * t) / 255)),
        0xFF,
    };
}

fn sortF64(values: []f64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const v = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > v) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = v;
    }
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn clampF64(v: f64, min_v: f64, max_v: f64) f64 {
    return if (v < min_v) min_v else if (v > max_v) max_v else v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}
