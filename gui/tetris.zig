const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const BOARD_W: usize = 10;
const BOARD_H: usize = 20;
const TILE: usize = 14;

const SIDE_W: usize = 86;
const PAD: usize = 12;

const PLAY_W: usize = BOARD_W * TILE;
const PLAY_H: usize = BOARD_H * TILE;

const RENDER_W: usize = PAD * 3 + PLAY_W + SIDE_W;
const RENDER_H: usize = PAD * 2 + PLAY_H;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const DROP_MS: i64 = 520;
const MAX_CATCH_UP_DROPS: i64 = BOARD_H + 4;

const Color = [4]u8;
const COLOR_BG: Color = .{ 0x10, 0x12, 0x18, 0xFF };
const COLOR_WELL: Color = .{ 0x17, 0x1B, 0x24, 0xFF };
const COLOR_GRID: Color = .{ 0x1D, 0x23, 0x30, 0xFF };
const COLOR_OVERLAY: Color = .{ 0x0A, 0x0C, 0x12, 0xC8 };

const PIECE_COLORS = [_]Color{
    .{ 0x40, 0xE0, 0xE8, 0xFF }, // I
    .{ 0xF0, 0xD4, 0x3C, 0xFF }, // O
    .{ 0xA7, 0x5E, 0xF0, 0xFF }, // T
    .{ 0x4C, 0xC6, 0x4B, 0xFF }, // S
    .{ 0xF0, 0x5A, 0x5A, 0xFF }, // Z
    .{ 0x4A, 0x79, 0xF2, 0xFF }, // J
    .{ 0xF2, 0x98, 0x42, 0xFF }, // L
};

// 7 pieces x 4 rotations, each rotation is 16-bit 4x4 mask.
const SHAPES = [_][4]u16{
    // I
    .{ 0x0F00, 0x2222, 0x00F0, 0x4444 },
    // O
    .{ 0x6600, 0x6600, 0x6600, 0x6600 },
    // T
    .{ 0x4E00, 0x4640, 0x0E40, 0x4C40 },
    // S
    .{ 0x6C00, 0x4620, 0x06C0, 0x8C40 },
    // Z
    .{ 0xC600, 0x2640, 0x0C60, 0x4C80 },
    // J
    .{ 0x8E00, 0x6440, 0x0E20, 0x44C0 },
    // L
    .{ 0x2E00, 0x4460, 0x0E80, 0xC440 },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var board: [BOARD_H][BOARD_W]u8 = [_][BOARD_W]u8{[_]u8{0} ** BOARD_W} ** BOARD_H;

var cur_type: u8 = 0;
var cur_rot: u8 = 0;
var cur_x: i32 = 3;
var cur_y: i32 = 0;

var next_type: u8 = 0;
var rng_state: u32 = 0xCAFEB157;

var has_last_drop: bool = false;
var last_drop_ms: i64 = 0;

var score: i32 = 0;
var lines_cleared: i32 = 0;
var paused: bool = false;
var game_over: bool = false;
var initialized: bool = false;
var needs_redraw: bool = true;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var next_wake_at_ms: i64 = 0;

const WELL_X: usize = PAD;
const WELL_Y: usize = PAD;
const SIDE_X: usize = WELL_X + PLAY_W + PAD;

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

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;
    switch (x11_key) {
        0x72, 0x52 => resetGame(), // r/R
        0x20 => { // space hard drop
            if (game_over) {
                resetGame();
            } else if (!paused) {
                while (tryMove(0, 1)) {}
                lockPiece();
            }
        },
        0x70, 0x50 => { // p/P pause
            if (!game_over) {
                paused = !paused;
                needs_redraw = true;
            }
        },
        else => {
            if (paused or game_over) return 0;
            switch (x11_key) {
                XK_LEFT => _ = tryMove(-1, 0),
                XK_RIGHT => _ = tryMove(1, 0),
                XK_DOWN => {
                    if (!tryMove(0, 1)) lockPiece();
                },
                XK_UP => _ = tryRotate(1),
                else => return 0,
            }
        },
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    return 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (!initialized) {
        resetGame();
        has_last_drop = true;
        last_drop_ms = 0;
    }
    if (game_over or paused) {
        next_wake_at_ms = begun_at_ms;
        return;
    }

    if (!has_last_drop) {
        has_last_drop = true;
        last_drop_ms = begun_at_ms;
    }
    var elapsed = begun_at_ms - last_drop_ms;
    if (elapsed < 0) elapsed = 0;

    const available_drops = @divFloor(elapsed, DROP_MS);
    const drops = @min(available_drops, MAX_CATCH_UP_DROPS);
    var i: i64 = 0;
    while (i < drops and !game_over and !paused) : (i += 1) {
        if (!tryMove(0, 1)) {
            lockPiece();
        }
    }
    last_drop_ms = if (available_drops > MAX_CATCH_UP_DROPS)
        begun_at_ms
    else
        last_drop_ms + drops * DROP_MS;

    next_wake_at_ms = if (!game_over and !paused and last_drop_ms <= std.math.maxInt(i64) - DROP_MS)
        last_drop_ms + DROP_MS
    else
        begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    if (!initialized) {
        resetGame();
        has_last_drop = true;
        last_drop_ms = 0;
    }
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    needs_redraw = false;
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
    next_wake_at_ms = if (!game_over and !paused and last_drop_ms <= std.math.maxInt(i64) - DROP_MS)
        last_drop_ms + DROP_MS
    else
        begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn resetGame() void {
    initialized = true;
    board = [_][BOARD_W]u8{[_]u8{0} ** BOARD_W} ** BOARD_H;
    score = 0;
    lines_cleared = 0;
    paused = false;
    game_over = false;
    has_last_drop = false;
    last_drop_ms = 0;
    rng_state +%= 0x9E3779B9;
    next_type = @intCast(rngNext() % 7);
    spawnPiece();
    needs_redraw = true;
}

fn spawnPiece() void {
    cur_type = next_type;
    next_type = @intCast(rngNext() % 7);
    cur_rot = 0;
    cur_x = 3;
    cur_y = -1;
    if (collides(cur_x, cur_y, cur_type, cur_rot)) {
        game_over = true;
    }
}

fn lockPiece() void {
    const mask: u16 = SHAPES[cur_type][cur_rot];
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(15 - i);
        if ((mask & bit) == 0) continue;
        const x = cur_x + @as(i32, @intCast(i % 4));
        const y = cur_y + @as(i32, @intCast(i / 4));
        if (y < 0 or y >= @as(i32, @intCast(BOARD_H)) or x < 0 or x >= @as(i32, @intCast(BOARD_W))) continue;
        board[@intCast(y)][@intCast(x)] = cur_type + 1;
    }
    clearLines();
    spawnPiece();
    needs_redraw = true;
}

fn clearLines() void {
    var y: i32 = @intCast(BOARD_H - 1);
    var cleared: i32 = 0;
    while (y >= 0) : (y -= 1) {
        var full = true;
        var x: usize = 0;
        while (x < BOARD_W) : (x += 1) {
            if (board[@intCast(y)][x] == 0) {
                full = false;
                break;
            }
        }
        if (!full) continue;
        cleared += 1;
        var yy: i32 = y;
        while (yy > 0) : (yy -= 1) {
            board[@intCast(yy)] = board[@intCast(yy - 1)];
        }
        board[0] = [_]u8{0} ** BOARD_W;
        y += 1;
    }
    if (cleared > 0) {
        lines_cleared += cleared;
        score += switch (cleared) {
            1 => 100,
            2 => 300,
            3 => 500,
            else => 800,
        };
    }
}

fn tryMove(dx: i32, dy: i32) bool {
    const nx = cur_x + dx;
    const ny = cur_y + dy;
    if (collides(nx, ny, cur_type, cur_rot)) return false;
    cur_x = nx;
    cur_y = ny;
    return true;
}

fn tryRotate(delta: i32) bool {
    var nr: i32 = @intCast(cur_rot);
    nr = @mod(nr + delta + 4, 4);
    const rot: u8 = @intCast(nr);
    if (!collides(cur_x, cur_y, cur_type, rot)) {
        cur_rot = rot;
        return true;
    }
    if (!collides(cur_x - 1, cur_y, cur_type, rot)) {
        cur_x -= 1;
        cur_rot = rot;
        return true;
    }
    if (!collides(cur_x + 1, cur_y, cur_type, rot)) {
        cur_x += 1;
        cur_rot = rot;
        return true;
    }
    return false;
}

fn collides(px: i32, py: i32, ptype: u8, prot: u8) bool {
    const mask: u16 = SHAPES[ptype][prot];
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(15 - i);
        if ((mask & bit) == 0) continue;
        const x = px + @as(i32, @intCast(i % 4));
        const y = py + @as(i32, @intCast(i / 4));
        if (x < 0 or x >= @as(i32, @intCast(BOARD_W)) or y >= @as(i32, @intCast(BOARD_H))) {
            return true;
        }
        if (y >= 0 and board[@intCast(y)][@intCast(x)] != 0) {
            return true;
        }
    }
    return false;
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
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawWell();
    drawBoard();
    drawCurrentPiece();
    drawSidePanel();
    if (paused or game_over) drawOverlay();
}

fn drawWell() void {
    fillRect(WELL_X, WELL_Y, PLAY_W, PLAY_H, COLOR_WELL);
    var y: usize = 0;
    while (y < BOARD_H) : (y += 1) {
        var x: usize = 0;
        while (x < BOARD_W) : (x += 1) {
            if (((x + y) & 1) == 0) {
                fillRect(WELL_X + x * TILE, WELL_Y + y * TILE, TILE, TILE, COLOR_GRID);
            }
        }
    }
    drawStroke(WELL_X, WELL_Y, PLAY_W, PLAY_H, 2, .{ 0x3A, 0x43, 0x58, 0xFF });
}

fn drawBoard() void {
    var y: usize = 0;
    while (y < BOARD_H) : (y += 1) {
        var x: usize = 0;
        while (x < BOARD_W) : (x += 1) {
            const cell = board[y][x];
            if (cell == 0) continue;
            drawTile(@intCast(x), @intCast(y), PIECE_COLORS[cell - 1]);
        }
    }
}

fn drawCurrentPiece() void {
    const mask: u16 = SHAPES[cur_type][cur_rot];
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(15 - i);
        if ((mask & bit) == 0) continue;
        const x = cur_x + @as(i32, @intCast(i % 4));
        const y = cur_y + @as(i32, @intCast(i / 4));
        if (y < 0) continue;
        drawTile(x, y, PIECE_COLORS[cur_type]);
    }
}

fn drawSidePanel() void {
    fillRect(SIDE_X, WELL_Y, SIDE_W, PLAY_H, .{ 0x15, 0x1A, 0x25, 0xFF });
    drawStroke(SIDE_X, WELL_Y, SIDE_W, PLAY_H, 2, .{ 0x31, 0x3A, 0x4E, 0xFF });

    // Next piece preview area.
    const px = SIDE_X + 14;
    const py = WELL_Y + 24;
    fillRect(px, py, 58, 58, .{ 0x20, 0x26, 0x34, 0xFF });
    drawStroke(px, py, 58, 58, 2, .{ 0x3A, 0x43, 0x58, 0xFF });

    const mask: u16 = SHAPES[next_type][0];
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(15 - i);
        if ((mask & bit) == 0) continue;
        const gx: usize = i % 4;
        const gy: usize = i / 4;
        const tx = px + 8 + gx * 10;
        const ty = py + 8 + gy * 10;
        fillRect(tx, ty, 9, 9, PIECE_COLORS[next_type]);
    }

    // Tiny score bars (text-free but still readable).
    const score_h: usize = @intCast(@min(@divFloor(score, 100), 12));
    const lines_h: usize = @intCast(@min(lines_cleared, 12));
    fillRect(SIDE_X + 18, WELL_Y + 120 + (12 - score_h) * 6, 14, score_h * 6, .{ 0x5E, 0xB2, 0xF3, 0xFF });
    fillRect(SIDE_X + 50, WELL_Y + 120 + (12 - lines_h) * 6, 14, lines_h * 6, .{ 0x76, 0xD4, 0x67, 0xFF });
}

fn drawOverlay() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_OVERLAY);
    const w: usize = 140;
    const h: usize = 72;
    const x = (RENDER_W - w) / 2;
    const y = (RENDER_H - h) / 2;
    fillRect(x, y, w, h, .{ 0xF2, 0xF5, 0xFA, 0xFF });
    drawStroke(x, y, w, h, 5, if (game_over) .{ 0xE5, 0x5A, 0x5A, 0xFF } else .{ 0xF0, 0xC4, 0x52, 0xFF });
}

fn drawTile(tx: i32, ty: i32, color: Color) void {
    if (tx < 0 or ty < 0) return;
    const x: usize = @intCast(tx);
    const y: usize = @intCast(ty);
    if (x >= BOARD_W or y >= BOARD_H) return;
    const px = WELL_X + x * TILE;
    const py = WELL_Y + y * TILE;
    fillRect(px + 1, py + 1, TILE - 2, TILE - 2, color);
}

fn drawStroke(x0: usize, y0: usize, w: usize, h: usize, t: usize, color: Color) void {
    fillRect(x0, y0, w, t, color);
    fillRect(x0, y0 + h - t, w, t, color);
    fillRect(x0, y0, t, h, color);
    fillRect(x0 + w - t, y0, t, h, color);
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            const idx = (y * RENDER_W + x) * 4;
            pixel_buf[idx + 0] = color[0];
            pixel_buf[idx + 1] = color[1];
            pixel_buf[idx + 2] = color[2];
            pixel_buf[idx + 3] = color[3];
        }
    }
}

test "late transactions discard drop backlog after the bounded catch-up" {
    resetGame();
    has_last_drop = true;
    last_drop_ms = 0;
    begun_at_ms = std.math.maxInt(i64);
    time_advanced = false;

    advanceTransactionTime();

    try std.testing.expectEqual(std.math.maxInt(i64), last_drop_ms);
    try std.testing.expectEqual(std.math.maxInt(i64), next_wake_at_ms);
}
