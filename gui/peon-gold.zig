const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_ESCAPE: i32 = 0xFF1B;

const FLAG_KEY_DOWN: i32 = 1 << 0;

const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const STEP_MS: i64 = 16;
const MAX_STEPS_PER_UPDATE: i32 = 8;

const FP_SHIFT: i32 = 8;
const FP_ONE: i32 = 1 << FP_SHIFT;

const PEON_SIZE: i32 = 10;
const PEON_SPEED_EMPTY_FP: i32 = 2 * FP_ONE;
const PEON_SPEED_LOADED_FP: i32 = @divFloor(3 * FP_ONE, 2);

const MINE_X: i32 = 232;
const MINE_Y: i32 = 58;
const MINE_W: i32 = 68;
const MINE_H: i32 = 58;

const HALL_X: i32 = 34;
const HALL_Y: i32 = 132;
const HALL_W: i32 = 70;
const HALL_H: i32 = 62;

const MINING_STEPS: i32 = 52;
const DEPOSIT_STEPS: i32 = 10;
const GOLD_PER_TRIP: i32 = 100;
const START_MINE_GOLD: i32 = 3000;
const PEON_SPAWN_COST: i32 = 300;
const MAX_PEONS: usize = 8;

const Color = [4]u8;
const C_BG: Color = .{ 0xA8, 0x9D, 0x6A, 0xFF };
const C_BG_DUNE: Color = .{ 0xC5, 0xB7, 0x7A, 0xFF };
const C_HUD: Color = .{ 0x20, 0x1F, 0x26, 0xFF };
const C_MINE: Color = .{ 0x6E, 0x64, 0x58, 0xFF };
const C_MINE_GOLD: Color = .{ 0xE8, 0xC7, 0x50, 0xFF };
const C_HALL: Color = .{ 0x5A, 0x34, 0x1F, 0xFF };
const C_HALL_ROOF: Color = .{ 0xA6, 0x65, 0x30, 0xFF };
const C_PEON: Color = .{ 0x4C, 0xB3, 0x62, 0xFF };
const C_PEON_SEL: Color = .{ 0xD8, 0xFF, 0x7A, 0xFF };
const C_PEON_BAG: Color = .{ 0xF1, 0xD0, 0x65, 0xFF };
const C_CURSOR: Color = .{ 0x9D, 0xEC, 0xFF, 0xFF };
const C_NUMBER: Color = .{ 0xF4, 0xE6, 0x9B, 0xFF };

const Order = enum(u8) {
    none,
    move,
    gather,
};

const PeonState = enum(u8) {
    idle,
    moving,
    mining,
    depositing,
};

const MoveTarget = enum(u8) {
    point,
    mine,
    hall,
};

const CommandMode = enum(u8) {
    smart,
    move,
    harvest,
};

const Peon = struct {
    x_fp: i32,
    y_fp: i32,
    target_x_fp: i32,
    target_y_fp: i32,
    order: Order,
    state: PeonState,
    move_target: MoveTarget,
    state_timer_steps: i32,
    carry_gold: i32,
};

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;

var initialized: bool = false;
var needs_redraw: bool = true;

var has_last_tick: bool = false;
var last_tick_ms: i64 = 0;

var selected_peon: i32 = 0;
var cmd_mode: CommandMode = .smart;

var peons: [MAX_PEONS]Peon = undefined;
var peon_count: usize = 0;
var collected_gold: i32 = 0;
var mine_gold_left: i32 = START_MINE_GOLD;

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const LifecycleState = enum { initializing, ready, updating };
var lifecycle_state: LifecycleState = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced = false;

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle_state != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    lifecycle_state = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;

    switch (x11_key) {
        'r', 'R' => {
            resetGame(begun_at_ms);
            return 1;
        },
        'p', 'P' => {
            selectNextPeon();
            needs_redraw = true;
            return 1;
        },
        'b', 'B' => {
            _ = trySpawnPeon();
            needs_redraw = true;
            return 1;
        },
        'm', 'M' => {
            cmd_mode = .move;
            needs_redraw = true;
            return 1;
        },
        'h', 'H', 'g', 'G' => {
            cmd_mode = .harvest;
            needs_redraw = true;
            return 1;
        },
        's', 'S' => {
            stopPeon();
            cmd_mode = .smart;
            needs_redraw = true;
            return 1;
        },
        XK_ESCAPE => {
            cmd_mode = .smart;
            needs_redraw = true;
            return 1;
        },
        XK_LEFT => {
            if (selectedPeon()) |peon| issueMovePeon(peon, @divFloor(peon.x_fp, FP_ONE) - 16, @divFloor(peon.y_fp, FP_ONE));
            return 1;
        },
        XK_RIGHT => {
            if (selectedPeon()) |peon| issueMovePeon(peon, @divFloor(peon.x_fp, FP_ONE) + 16, @divFloor(peon.y_fp, FP_ONE));
            return 1;
        },
        XK_UP => {
            if (selectedPeon()) |peon| issueMovePeon(peon, @divFloor(peon.x_fp, FP_ONE), @divFloor(peon.y_fp, FP_ONE) - 16);
            return 1;
        },
        XK_DOWN => {
            if (selectedPeon()) |peon| issueMovePeon(peon, @divFloor(peon.x_fp, FP_ONE), @divFloor(peon.y_fp, FP_ONE) + 16);
            return 1;
        },
        else => return 0,
    }
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    if (x_px < 0 or y_px < 0 or x_px >= @as(i32, @intCast(RENDER_W)) or y_px >= @as(i32, @intCast(RENDER_H))) return 0;

    const primary = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;

    if (primary) {
        selected_peon = peonIndexAt(x_px, y_px);
        needs_redraw = true;
        return 1;
    }

    if (secondary) {
        const peon = selectedPeon() orelse return 0;
        const clicked_mine = mineContains(x_px, y_px);
        switch (cmd_mode) {
            .move => issueMovePeon(peon, x_px, y_px),
            .harvest => {
                if (clicked_mine) issueGatherOrder(peon) else issueMovePeon(peon, x_px, y_px);
            },
            .smart => {
                if (clicked_mine) issueGatherOrder(peon) else issueMovePeon(peon, x_px, y_px);
            },
        }

        if (cmd_mode != .smart) cmd_mode = .smart;
        needs_redraw = true;
        return 1;
    }

    return 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;

    var elapsed = begun_at_ms - last_tick_ms;
    if (elapsed < 0) elapsed = 0;

    var steps: i32 = 0;
    while (elapsed >= STEP_MS and steps < MAX_STEPS_PER_UPDATE) : (steps += 1) {
        stepGame();
        last_tick_ms += STEP_MS;
        elapsed -= STEP_MS;
    }
    if (elapsed >= STEP_MS) last_tick_ms = begun_at_ms;
}

export fn finish_update() i64 {
    requireUpdate();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    return last_tick_ms +| STEP_MS;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or (lifecycle_state != .initializing and lifecycle_state != .ready)) @trap();
    if (lifecycle_state == .initializing) ensureInitialized(0);
    drawScene();
    needs_redraw = false;
    _ = ktx.writeHeader(&ktx_buf, RENDER_W, RENDER_H) orelse @trap();
    @memcpy(ktx_buf[ktx.HEADER_SIZE..], output_buf[0..]);
    lifecycle_state = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&ktx_buf[0])),
        .failed = 0,
    };
}

fn ensureInitialized(now_ms: i64) void {
    if (initialized) return;
    resetGame(now_ms);
    initialized = true;
}

fn resetGame(now_ms: i64) void {
    selected_peon = 0;
    cmd_mode = .smart;

    peon_count = 1;
    peons[0] = newPeonAt(HALL_X + 18, HALL_Y + HALL_H - 14);
    collected_gold = 0;
    mine_gold_left = START_MINE_GOLD;

    has_last_tick = true;
    last_tick_ms = now_ms;
    needs_redraw = true;
}

fn stopPeon() void {
    if (selectedPeon()) |peon| {
        peon.order = .none;
        peon.state = .idle;
        peon.move_target = .point;
        peon.state_timer_steps = 0;
    }
}

fn newPeonAt(x_px: i32, y_px: i32) Peon {
    const x_fp = x_px * FP_ONE;
    const y_fp = y_px * FP_ONE;
    return .{
        .x_fp = x_fp,
        .y_fp = y_fp,
        .target_x_fp = x_fp,
        .target_y_fp = y_fp,
        .order = .none,
        .state = .idle,
        .move_target = .point,
        .state_timer_steps = 0,
        .carry_gold = 0,
    };
}

fn selectedPeon() ?*Peon {
    if (selected_peon < 0) return null;
    const idx = @as(usize, @intCast(selected_peon));
    if (idx >= peon_count) return null;
    return &peons[idx];
}

fn selectNextPeon() void {
    if (peon_count == 0) {
        selected_peon = -1;
        return;
    }
    if (selected_peon < 0) {
        selected_peon = 0;
        return;
    }
    selected_peon = @as(i32, @intCast((@as(usize, @intCast(selected_peon)) + 1) % peon_count));
}

fn trySpawnPeon() bool {
    if (collected_gold < PEON_SPAWN_COST or peon_count >= MAX_PEONS) return false;

    collected_gold -= PEON_SPAWN_COST;
    const slot = peon_count;
    const offset_x = @as(i32, @intCast((slot % 4) * 12));
    const offset_y = @as(i32, @intCast((slot / 4) * 12));
    peons[slot] = newPeonAt(HALL_X + 18 + offset_x, HALL_Y + HALL_H - 14 - offset_y);
    peon_count += 1;
    selected_peon = @as(i32, @intCast(slot));
    return true;
}

fn issueMovePeon(peon: *Peon, x_px: i32, y_px: i32) void {
    const clamped_x = clampI32(x_px, 4, @as(i32, @intCast(RENDER_W)) - 4);
    const clamped_y = clampI32(y_px, 26, @as(i32, @intCast(RENDER_H)) - 4);
    peon.target_x_fp = clamped_x * FP_ONE;
    peon.target_y_fp = clamped_y * FP_ONE;
    peon.order = .move;
    peon.state = .moving;
    peon.move_target = .point;
}

fn issueGatherOrder(peon: *Peon) void {
    peon.order = .gather;
    if (peon.carry_gold > 0) {
        setTargetToHall(peon);
        peon.state = .moving;
        peon.move_target = .hall;
        return;
    }

    if (mine_gold_left <= 0) {
        peon.order = .none;
        peon.state = .idle;
        return;
    }

    setTargetToMine(peon);
    peon.state = .moving;
    peon.move_target = .mine;
}

fn setTargetToMine(peon: *Peon) void {
    peon.target_x_fp = (MINE_X + @divFloor(MINE_W, 2)) * FP_ONE;
    peon.target_y_fp = (MINE_Y + MINE_H - 6) * FP_ONE;
}

fn setTargetToHall(peon: *Peon) void {
    peon.target_x_fp = (HALL_X + @divFloor(HALL_W, 2)) * FP_ONE;
    peon.target_y_fp = (HALL_Y + 12) * FP_ONE;
}

fn stepGame() void {
    var i: usize = 0;
    while (i < peon_count) : (i += 1) {
        stepPeon(&peons[i]);
    }

    needs_redraw = true;
}

fn stepPeon(peon: *Peon) void {
    switch (peon.state) {
        .idle => {},
        .moving => {
            const speed = if (peon.carry_gold > 0) PEON_SPEED_LOADED_FP else PEON_SPEED_EMPTY_FP;
            if (moveTowardsTarget(peon, speed)) {
                switch (peon.order) {
                    .none => peon.state = .idle,
                    .move => {
                        peon.order = .none;
                        peon.state = .idle;
                    },
                    .gather => {
                        if (peon.move_target == .mine) {
                            if (mine_gold_left > 0 and peon.carry_gold == 0) {
                                peon.state = .mining;
                                peon.state_timer_steps = MINING_STEPS;
                            } else if (peon.carry_gold > 0) {
                                setTargetToHall(peon);
                                peon.move_target = .hall;
                                peon.state = .moving;
                            } else {
                                peon.order = .none;
                                peon.state = .idle;
                            }
                        } else if (peon.move_target == .hall) {
                            if (peon.carry_gold > 0) {
                                peon.state = .depositing;
                                peon.state_timer_steps = DEPOSIT_STEPS;
                            } else if (mine_gold_left > 0) {
                                setTargetToMine(peon);
                                peon.move_target = .mine;
                                peon.state = .moving;
                            } else {
                                peon.order = .none;
                                peon.state = .idle;
                            }
                        } else {
                            peon.state = .idle;
                        }
                    },
                }
            }
        },
        .mining => {
            if (peon.state_timer_steps > 0) {
                peon.state_timer_steps -= 1;
            } else {
                const mined = @min(GOLD_PER_TRIP, mine_gold_left);
                if (mined > 0) {
                    peon.carry_gold = mined;
                    mine_gold_left -= mined;
                    setTargetToHall(peon);
                    peon.move_target = .hall;
                    peon.state = .moving;
                } else {
                    peon.order = .none;
                    peon.state = .idle;
                }
            }
        },
        .depositing => {
            if (peon.state_timer_steps > 0) {
                peon.state_timer_steps -= 1;
            } else {
                collected_gold += peon.carry_gold;
                peon.carry_gold = 0;
                if (peon.order == .gather and mine_gold_left > 0) {
                    setTargetToMine(peon);
                    peon.move_target = .mine;
                    peon.state = .moving;
                } else {
                    peon.order = .none;
                    peon.state = .idle;
                }
            }
        },
    }
}

fn moveTowardsTarget(peon: *Peon, speed_fp: i32) bool {
    const dx = peon.target_x_fp - peon.x_fp;
    const dy = peon.target_y_fp - peon.y_fp;
    if (absI32(dx) <= speed_fp and absI32(dy) <= speed_fp) {
        peon.x_fp = peon.target_x_fp;
        peon.y_fp = peon.target_y_fp;
        return true;
    }

    if (dx > 0) peon.x_fp += @min(dx, speed_fp) else if (dx < 0) peon.x_fp -= @min(-dx, speed_fp);
    if (dy > 0) peon.y_fp += @min(dy, speed_fp) else if (dy < 0) peon.y_fp -= @min(-dy, speed_fp);
    return false;
}

fn mineContains(x: i32, y: i32) bool {
    return x >= MINE_X and y >= MINE_Y and x < MINE_X + MINE_W and y < MINE_Y + MINE_H;
}

fn peonIndexAt(x: i32, y: i32) i32 {
    var i = peon_count;
    while (i > 0) {
        i -= 1;
        if (peonContains(&peons[i], x, y)) return @as(i32, @intCast(i));
    }
    return -1;
}

fn peonContains(peon: *const Peon, x: i32, y: i32) bool {
    const px = @divFloor(peon.x_fp, FP_ONE);
    const py = @divFloor(peon.y_fp, FP_ONE);
    const r = @divFloor(PEON_SIZE, 2);
    return x >= px - r and y >= py - r and x < px + r and y < py + r;
}

fn drawScene() void {
    drawBackground();
    drawMine();
    drawHall();
    drawPeons();
    drawTargetMarkers();
    drawHud();
}

fn drawBackground() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);

    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const y = 26 + i * 26;
        fillRect(0, y, RENDER_W, 10, C_BG_DUNE);
    }

    // Simple river to break up terrain.
    var y: usize = 26;
    while (y < RENDER_H) : (y += 1) {
        const wobble = @as(i32, @intCast((y * 5) % 31)) - 15;
        const cx = 170 + wobble;
        fillRectI32(cx - 10, @as(i32, @intCast(y)), 20, 1, .{ 0x7A, 0xA7, 0xB2, 0xFF });
    }
}

fn drawMine() void {
    fillRectI32(MINE_X, MINE_Y, MINE_W, MINE_H, C_MINE);
    fillRectI32(MINE_X + 6, MINE_Y + 8, MINE_W - 12, MINE_H - 14, .{ 0x57, 0x4F, 0x45, 0xFF });
    fillRectI32(MINE_X + 18, MINE_Y + 18, 10, 8, C_MINE_GOLD);
    fillRectI32(MINE_X + 36, MINE_Y + 25, 12, 9, C_MINE_GOLD);
    fillRectI32(MINE_X + 50, MINE_Y + 14, 8, 7, C_MINE_GOLD);
}

fn drawHall() void {
    fillRectI32(HALL_X, HALL_Y, HALL_W, HALL_H, C_HALL);
    fillRectI32(HALL_X + 4, HALL_Y + 4, HALL_W - 8, 16, C_HALL_ROOF);
    fillRectI32(HALL_X + 28, HALL_Y + 24, 14, HALL_H - 24, .{ 0x2C, 0x18, 0x0D, 0xFF });
}

fn drawPeons() void {
    var i: usize = 0;
    while (i < peon_count) : (i += 1) {
        drawPeon(&peons[i], selected_peon == @as(i32, @intCast(i)));
    }
}

fn drawPeon(peon: *const Peon, selected: bool) void {
    const x = @divFloor(peon.x_fp, FP_ONE);
    const y = @divFloor(peon.y_fp, FP_ONE);
    const r = @divFloor(PEON_SIZE, 2);

    if (selected) {
        fillRectI32(x - r - 2, y - r - 2, PEON_SIZE + 4, PEON_SIZE + 4, C_PEON_SEL);
    }

    fillRectI32(x - r, y - r, PEON_SIZE, PEON_SIZE, C_PEON);
    fillRectI32(x - 1, y - r - 1, 3, 2, .{ 0xE7, 0xF5, 0xC0, 0xFF });

    if (peon.carry_gold > 0) {
        fillRectI32(x + r - 2, y + 1, 4, 4, C_PEON_BAG);
    }
}

fn drawTargetMarkers() void {
    var i: usize = 0;
    while (i < peon_count) : (i += 1) {
        if (peons[i].state == .moving) drawTargetMarker(&peons[i]);
    }
}

fn drawTargetMarker(peon: *const Peon) void {
    const tx = @divFloor(peon.target_x_fp, FP_ONE);
    const ty = @divFloor(peon.target_y_fp, FP_ONE);
    fillRectI32(tx - 4, ty - 1, 9, 2, C_CURSOR);
    fillRectI32(tx - 1, ty - 4, 2, 9, C_CURSOR);
}

fn drawHud() void {
    fillRect(0, 0, RENDER_W, 22, C_HUD);

    // Gold icon and number.
    fillRect(6, 6, 10, 10, C_MINE_GOLD);
    drawNumber(24, 8, collected_gold, C_NUMBER);

    // Carrying indicator.
    fillRect(124, 6, 8, 10, C_PEON_BAG);
    drawNumber(136, 8, selectedCarryGold(), C_NUMBER);

    // Mine remaining.
    fillRect(210, 6, 8, 10, C_MINE);
    drawNumber(222, 8, mine_gold_left, .{ 0xCB, 0xD6, 0xE6, 0xFF });

    // Mode tabs.
    drawModeTab(260, cmd_mode == .smart, .{ 0x5D, 0xB4, 0xD5, 0xFF });
    drawModeTab(280, cmd_mode == .move, .{ 0xD1, 0xAF, 0x56, 0xFF });
    drawModeTab(300, cmd_mode == .harvest, .{ 0x74, 0xD0, 0x7A, 0xFF });

    // Unit count and spawn availability.
    fillRect(176, 6, 8, 10, if (canSpawnPeon()) C_PEON_SEL else C_PEON);
    drawNumber(188, 8, @as(i32, @intCast(peon_count)), C_NUMBER);
}

fn selectedCarryGold() i32 {
    if (selectedPeon()) |peon| return peon.carry_gold;
    return 0;
}

fn canSpawnPeon() bool {
    return collected_gold >= PEON_SPAWN_COST and peon_count < MAX_PEONS;
}

fn drawModeTab(x: i32, active: bool, color: Color) void {
    fillRectI32(x, 5, 14, 12, .{ 0x2A, 0x2A, 0x32, 0xFF });
    if (active) fillRectI32(x + 2, 7, 10, 8, color);
}

fn drawNumber(x0: i32, y0: i32, n: i32, color: Color) void {
    var value = if (n < 0) 0 else n;
    var digits: [12]u8 = undefined;
    var count: usize = 0;
    if (value == 0) {
        digits[0] = 0;
        count = 1;
    } else {
        while (value > 0 and count < digits.len) : (count += 1) {
            digits[count] = @as(u8, @intCast(@mod(value, 10)));
            value = @divFloor(value, 10);
        }
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const d = digits[count - 1 - i];
        drawDigit(x0 + @as(i32, @intCast(i * 4)), y0, d, color);
    }
}

fn drawDigit(x0: i32, y0: i32, digit: u8, color: Color) void {
    const rows = switch (digit) {
        0 => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        1 => [_]u8{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        2 => [_]u8{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        3 => [_]u8{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        4 => [_]u8{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        5 => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        6 => [_]u8{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        7 => [_]u8{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        8 => [_]u8{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        9 => [_]u8{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };

    var y: usize = 0;
    while (y < 5) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            if ((rows[y] & (@as(u8, 1) << @as(u3, @intCast(2 - x)))) != 0) {
                setPixelI32(x0 + @as(i32, @intCast(x)), y0 + @as(i32, @intCast(y)), color);
            }
        }
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    setPixel(@as(usize, @intCast(x)), @as(usize, @intCast(y)), c);
}

fn setPixel(x: usize, y: usize, c: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, c: Color) void {
    if (w == 0 or h == 0) return;
    var y = y0;
    while (y < y0 + h and y < RENDER_H) : (y += 1) {
        var x = x0;
        while (x < x0 + w and x < RENDER_W) : (x += 1) {
            setPixel(x, y, c);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = clampI32(x0, 0, @as(i32, @intCast(RENDER_W)));
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ex = clampI32(x0 + w, 0, @as(i32, @intCast(RENDER_W)));
    const ey = clampI32(y0 + h, 0, @as(i32, @intCast(RENDER_H)));
    if (sx >= ex or sy >= ey) return;
    fillRect(@as(usize, @intCast(sx)), @as(usize, @intCast(sy)), @as(usize, @intCast(ex - sx)), @as(usize, @intCast(ey - sy)), c);
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

test "right click mine sets gather order" {
    resetGame(0);
    const peon = selectedPeon().?;
    issueGatherOrder(peon);
    try std.testing.expect(peon.order == .gather);
    try std.testing.expect(peon.state == .moving);
    try std.testing.expect(peon.move_target == .mine);
}

test "deposit increments collected gold" {
    resetGame(0);
    const peon = selectedPeon().?;
    peon.order = .gather;
    peon.state = .depositing;
    peon.state_timer_steps = 0;
    peon.carry_gold = 100;
    mine_gold_left = 0;
    collected_gold = 50;

    stepGame();

    try std.testing.expect(collected_gold == 150);
    try std.testing.expect(peon.carry_gold == 0);
}

test "spawning costs gold and selects new peon" {
    resetGame(0);
    collected_gold = PEON_SPAWN_COST;

    try std.testing.expect(trySpawnPeon());

    try std.testing.expect(peon_count == 2);
    try std.testing.expect(collected_gold == 0);
    try std.testing.expect(selected_peon == 1);
}

test "spawning requires enough gold" {
    resetGame(0);
    collected_gold = PEON_SPAWN_COST - 1;

    try std.testing.expect(!trySpawnPeon());

    try std.testing.expect(peon_count == 1);
    try std.testing.expect(collected_gold == PEON_SPAWN_COST - 1);
}
