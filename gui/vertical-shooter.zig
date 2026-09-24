const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 240;
const RENDER_H: usize = 240;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_ENTER: i32 = 0xFF0D;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

const KEY_UP: u8 = 1 << 0;
const KEY_DOWN: u8 = 1 << 1;
const KEY_LEFT: u8 = 1 << 2;
const KEY_RIGHT: u8 = 1 << 3;
const KEY_FIRE: u8 = 1 << 4;

const STEP_MS: i64 = 16;
const MAX_STEPS_PER_UPDATE: i32 = 8;

const FP_SHIFT: i32 = 8;
const FP_ONE: i32 = 1 << FP_SHIFT;

const PLAYER_W: i32 = 14;
const PLAYER_H: i32 = 12;
const PLAYER_SPEED_FP: i32 = 3 * FP_ONE;
const PLAYER_START_X_FP: i32 = (@as(i32, @intCast(RENDER_W)) / 2) * FP_ONE;
const PLAYER_START_Y_FP: i32 = (@as(i32, @intCast(RENDER_H)) - 30) * FP_ONE;
const PLAYER_MAX_HEALTH: i32 = 5;
const PLAYER_INVULN_STEPS: i32 = 45;

const BULLET_SPEED_FP: i32 = -6 * FP_ONE;
const BULLET_SPEED_SPRAY_FP: i32 = -5 * FP_ONE;
const BULLET_SPRAY_SIDE_VX_FP: i32 = 2 * FP_ONE;
const BULLET_COOLDOWN_SINGLE_STEPS: i32 = 6;
const BULLET_COOLDOWN_SPRAY_STEPS: i32 = 11;
const MAX_BULLETS: usize = 64;

const ENEMY_BASE_SCROLL_FP: i32 = 1 * FP_ONE;
const WAVE_SPACING_PX: i32 = 24;
const MAX_ENEMIES: usize = 64;
const MAX_ENEMY_SHOTS: usize = 96;
const ENEMY_SHOT_BASE_SPEED_FP: i32 = 3 * FP_ONE;

const MAX_PICKUPS: usize = 24;
const PICKUP_SPEED_FP: i32 = 2 * FP_ONE;
const HEALTH_DROP_CHANCE_DENOM: u32 = 10;
const WEAPON_DROP_CHANCE_DENOM: u32 = 12;

const Color = [4]u8;
const COLOR_BG: Color = .{ 0x05, 0x08, 0x14, 0xFF };
const COLOR_STAR: Color = .{ 0xA8, 0xB8, 0xD6, 0xFF };
const COLOR_PLAYER: Color = .{ 0x5E, 0xDA, 0xFF, 0xFF };
const COLOR_PLAYER_ACCENT: Color = .{ 0xC9, 0xF7, 0xFF, 0xFF };
const COLOR_BULLET: Color = .{ 0xFF, 0xE1, 0x65, 0xFF };
const COLOR_ENEMY: Color = .{ 0xFF, 0x68, 0x58, 0xFF };
const COLOR_ENEMY_TOUGH: Color = .{ 0xFF, 0x9A, 0x3E, 0xFF };
const COLOR_GAME_OVER: Color = .{ 0xF5, 0xD2, 0x58, 0xFF };
const COLOR_ENEMY_SHOT: Color = .{ 0xFF, 0x93, 0xB9, 0xFF };
const COLOR_PICKUP_HEALTH: Color = .{ 0x62, 0xF0, 0x8A, 0xFF };
const COLOR_PICKUP_WEAPON: Color = .{ 0x8A, 0x8B, 0xFF, 0xFF };

const Bullet = struct {
    active: bool = false,
    x_fp: i32 = 0,
    y_fp: i32 = 0,
    vx_fp: i32 = 0,
    vy_fp: i32 = 0,
};

const Enemy = struct {
    active: bool = false,
    x_fp: i32 = 0,
    y_fp: i32 = 0,
    vx_fp: i32 = 0,
    vy_fp: i32 = 0,
    w: i32 = 12,
    h: i32 = 10,
    hp: i32 = 1,
};

const EnemyShot = struct {
    active: bool = false,
    x_fp: i32 = 0,
    y_fp: i32 = 0,
    vx_fp: i32 = 0,
    vy_fp: i32 = ENEMY_SHOT_BASE_SPEED_FP,
    damage: i32 = 1,
};

const PickupKind = enum(u8) {
    health,
    weapon,
};

const Pickup = struct {
    active: bool = false,
    x_fp: i32 = 0,
    y_fp: i32 = 0,
    vy_fp: i32 = PICKUP_SPEED_FP,
    kind: PickupKind = .health,
};

const WeaponMode = enum(u8) {
    single,
    spray,
};

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;

var initialized: bool = false;
var needs_redraw: bool = true;

var keys_down: u8 = 0;
var has_last_tick: bool = false;
var last_tick_ms: i64 = 0;

var player_x_fp: i32 = PLAYER_START_X_FP;
var player_y_fp: i32 = PLAYER_START_Y_FP;
var fire_cooldown_steps: i32 = 0;
var player_health: i32 = PLAYER_MAX_HEALTH;
var player_invuln_steps: i32 = 0;
var weapon_mode: WeaponMode = .single;
var weapon_spray_unlocked: bool = false;

var score: i32 = 0;
var world_distance_px: i32 = 0;
var wave_index: i32 = 0;
var seed: u32 = 0xB16B_00B5;
var rng_state: u32 = 0x1234_5678;
var game_over: bool = false;

var bullets: [MAX_BULLETS]Bullet = [_]Bullet{.{}} ** MAX_BULLETS;
var enemies: [MAX_ENEMIES]Enemy = [_]Enemy{.{}} ** MAX_ENEMIES;
var enemy_shots: [MAX_ENEMY_SHOTS]EnemyShot = [_]EnemyShot{.{}} ** MAX_ENEMY_SHOTS;
var pickups: [MAX_PICKUPS]Pickup = [_]Pickup{.{}} ** MAX_PICKUPS;

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

    if (x11_key == XK_ENTER and is_down and game_over) {
        resetGame(begun_at_ms);
        return 1;
    }

    if (is_down and (x11_key == 'r' or x11_key == 'R')) {
        resetGame(begun_at_ms);
        return 1;
    }

    if (is_down and (x11_key == 'x' or x11_key == 'X')) {
        if (weapon_spray_unlocked) {
            weapon_mode = if (weapon_mode == .single) .spray else .single;
            needs_redraw = true;
        }
        return 1;
    }

    if (is_down and x11_key == '1') {
        weapon_mode = .single;
        needs_redraw = true;
        return 1;
    }

    if (is_down and x11_key == '2') {
        if (weapon_spray_unlocked) {
            weapon_mode = .spray;
            needs_redraw = true;
        }
        return 1;
    }

    const key_bit: u8 = switch (x11_key) {
        XK_UP => KEY_UP,
        XK_DOWN => KEY_DOWN,
        XK_LEFT => KEY_LEFT,
        XK_RIGHT => KEY_RIGHT,
        ' ' => KEY_FIRE,
        'z' => KEY_FIRE,
        'Z' => KEY_FIRE,
        else => return 0,
    };

    if (is_down) {
        keys_down |= key_bit;
    } else {
        keys_down &= ~key_bit;
    }

    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    if (game_over) return 0;
    if ((button_mask & BTN_PRIMARY) == 0) return 0;

    if (x_px < 0 or x_px >= @as(i32, @intCast(RENDER_W)) or y_px < 0 or y_px >= @as(i32, @intCast(RENDER_H))) {
        return 0;
    }

    player_x_fp = x_px * FP_ONE;
    player_y_fp = y_px * FP_ONE;
    clampPlayer();
    fireWeapon();
    needs_redraw = true;
    return 1;
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
    drawGame();
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
    const now_bits: u32 = @truncate(@as(u64, @bitCast(now_ms)));
    seed = mix32(seed ^ now_bits ^ 0x9E37_79B9);

    player_x_fp = PLAYER_START_X_FP;
    player_y_fp = PLAYER_START_Y_FP;
    fire_cooldown_steps = 0;
    player_health = PLAYER_MAX_HEALTH;
    player_invuln_steps = 0;
    weapon_mode = .single;
    weapon_spray_unlocked = false;
    score = 0;
    world_distance_px = 0;
    wave_index = 0;
    game_over = false;
    keys_down = 0;
    has_last_tick = true;
    last_tick_ms = now_ms;
    rng_state = mix32(seed ^ 0xA5A5_5A5A);

    for (&bullets) |*b| b.* = .{};
    for (&enemies) |*e| e.* = .{};
    for (&enemy_shots) |*s| s.* = .{};
    for (&pickups) |*p| p.* = .{};

    needs_redraw = true;
}

fn stepGame() void {
    if (game_over) {
        needs_redraw = true;
        return;
    }

    movePlayer();
    if (player_invuln_steps > 0) player_invuln_steps -= 1;

    if (fire_cooldown_steps > 0) fire_cooldown_steps -= 1;
    if ((keys_down & KEY_FIRE) != 0 and fire_cooldown_steps <= 0) {
        fireWeapon();
        fire_cooldown_steps = currentFireCooldownSteps();
    }

    world_distance_px += 1;
    spawnWaves();

    updateBullets();
    updateEnemies();
    updateEnemyShots();
    updatePickups();
    handleCollisions();

    needs_redraw = true;
}

fn movePlayer() void {
    const up = (keys_down & KEY_UP) != 0;
    const down = (keys_down & KEY_DOWN) != 0;
    const left = (keys_down & KEY_LEFT) != 0;
    const right = (keys_down & KEY_RIGHT) != 0;

    if (up and !down) player_y_fp -= PLAYER_SPEED_FP;
    if (down and !up) player_y_fp += PLAYER_SPEED_FP;
    if (left and !right) player_x_fp -= PLAYER_SPEED_FP;
    if (right and !left) player_x_fp += PLAYER_SPEED_FP;

    clampPlayer();
}

fn clampPlayer() void {
    const min_x = (PLAYER_W / 2) * FP_ONE;
    const max_x = (@as(i32, @intCast(RENDER_W)) - PLAYER_W / 2 - 1) * FP_ONE;
    const min_y = (@as(i32, @intCast(RENDER_H / 2))) * FP_ONE;
    const max_y = (@as(i32, @intCast(RENDER_H)) - PLAYER_H / 2 - 2) * FP_ONE;

    if (player_x_fp < min_x) player_x_fp = min_x;
    if (player_x_fp > max_x) player_x_fp = max_x;
    if (player_y_fp < min_y) player_y_fp = min_y;
    if (player_y_fp > max_y) player_y_fp = max_y;
}

fn currentFireCooldownSteps() i32 {
    return switch (weapon_mode) {
        .single => BULLET_COOLDOWN_SINGLE_STEPS,
        .spray => BULLET_COOLDOWN_SPRAY_STEPS,
    };
}

fn playerMotionShotBias() struct { vx: i32, vy: i32 } {
    var vx: i32 = 0;
    var vy: i32 = 0;
    const up = (keys_down & KEY_UP) != 0;
    const down = (keys_down & KEY_DOWN) != 0;
    const left = (keys_down & KEY_LEFT) != 0;
    const right = (keys_down & KEY_RIGHT) != 0;

    if (left and !right) vx = -@divFloor(PLAYER_SPEED_FP, 2);
    if (right and !left) vx = @divFloor(PLAYER_SPEED_FP, 2);
    if (up and !down) vy = -@divFloor(PLAYER_SPEED_FP, 3);
    if (down and !up) vy = @divFloor(PLAYER_SPEED_FP, 3);
    return .{ .vx = vx, .vy = vy };
}

fn fireWeapon() void {
    const y0 = player_y_fp - @divFloor(PLAYER_H, 2) * FP_ONE;
    const bias = playerMotionShotBias();
    switch (weapon_mode) {
        .single => {
            spawnBulletWithVelocity(player_x_fp, y0, bias.vx, BULLET_SPEED_FP + bias.vy);
        },
        .spray => {
            spawnBulletWithVelocity(player_x_fp - 4 * FP_ONE, y0, -BULLET_SPRAY_SIDE_VX_FP + bias.vx, BULLET_SPEED_SPRAY_FP + bias.vy);
            spawnBulletWithVelocity(player_x_fp, y0, bias.vx, BULLET_SPEED_SPRAY_FP + bias.vy);
            spawnBulletWithVelocity(player_x_fp + 4 * FP_ONE, y0, BULLET_SPRAY_SIDE_VX_FP + bias.vx, BULLET_SPEED_SPRAY_FP + bias.vy);
        },
    }
}

fn spawnBulletWithVelocity(x_fp: i32, y_fp: i32, vx_fp: i32, vy_fp: i32) void {
    var i: usize = 0;
    while (i < bullets.len) : (i += 1) {
        if (!bullets[i].active) {
            bullets[i].active = true;
            bullets[i].x_fp = x_fp;
            bullets[i].y_fp = y_fp;
            bullets[i].vx_fp = vx_fp;
            bullets[i].vy_fp = vy_fp;
            return;
        }
    }
}

fn spawnEnemy(x_px: i32, y_px: i32, vx_fp: i32, vy_fp: i32, hp: i32, w: i32, h: i32) void {
    var i: usize = 0;
    while (i < enemies.len) : (i += 1) {
        if (!enemies[i].active) {
            enemies[i].active = true;
            enemies[i].x_fp = x_px * FP_ONE;
            enemies[i].y_fp = y_px * FP_ONE;
            enemies[i].vx_fp = vx_fp;
            enemies[i].vy_fp = vy_fp;
            enemies[i].hp = hp;
            enemies[i].w = w;
            enemies[i].h = h;
            return;
        }
    }
}

fn spawnWaves() void {
    const target_wave = @divFloor(world_distance_px, WAVE_SPACING_PX);
    while (wave_index <= target_wave) : (wave_index += 1) {
        spawnWave(wave_index);
    }
}

fn spawnWave(idx: i32) void {
    const h = mix32(seed ^ @as(u32, @bitCast(idx)));

    // Keep wave density moderate so the game stays readable.
    if ((h % 11) == 0) return;

    const open_w = @as(i32, @intCast(RENDER_W)) - 24;
    const lane_count: i32 = 6;
    const lane_w = @divFloor(open_w, lane_count);

    const pattern = h % 4;
    const enemy_hp: i32 = if ((h & 0x30) == 0x30) 2 else 1;
    const enemy_w: i32 = if (enemy_hp == 2) 14 else 12;
    const enemy_h: i32 = if (enemy_hp == 2) 12 else 10;
    const vy = (1 + @as(i32, @intCast((h >> 8) % 3))) * FP_ONE;

    switch (pattern) {
        0 => {
            const count: i32 = 2 + @as(i32, @intCast((h >> 12) % 3));
            var i: i32 = 0;
            while (i < count) : (i += 1) {
                const lane = @mod(i + @as(i32, @intCast((h >> 16) % @as(u32, @intCast(lane_count)))), lane_count);
                const x = 12 + lane * lane_w + lane_w / 2;
                spawnEnemy(x, -12 - i * 16, 0, vy, enemy_hp, enemy_w, enemy_h);
            }
        },
        1 => {
            const center_lane = @as(i32, @intCast((h >> 16) % @as(u32, @intCast(lane_count - 2)))) + 1;
            spawnEnemy(12 + (center_lane - 1) * lane_w + lane_w / 2, -12, FP_ONE, vy, enemy_hp, enemy_w, enemy_h);
            spawnEnemy(12 + center_lane * lane_w + lane_w / 2, -28, 0, vy + FP_ONE / 2, enemy_hp, enemy_w, enemy_h);
            spawnEnemy(12 + (center_lane + 1) * lane_w + lane_w / 2, -12, -FP_ONE, vy, enemy_hp, enemy_w, enemy_h);
        },
        2 => {
            const lane = @as(i32, @intCast((h >> 20) % @as(u32, @intCast(lane_count))));
            const x = 12 + lane * lane_w + lane_w / 2;
            spawnEnemy(x, -18, 0, vy + FP_ONE / 2, enemy_hp + 1, 16, 14);
        },
        else => {
            const from_left = (h & 0x8000_0000) == 0;
            const start_x = if (from_left) 10 else @as(i32, @intCast(RENDER_W)) - 10;
            const vx = if (from_left) FP_ONE else -FP_ONE;
            const count: i32 = 3;
            var i: i32 = 0;
            while (i < count) : (i += 1) {
                spawnEnemy(start_x, -10 - i * 20, vx, vy, enemy_hp, enemy_w, enemy_h);
            }
        },
    }
}

fn updateBullets() void {
    for (&bullets) |*b| {
        if (!b.active) continue;
        b.x_fp += b.vx_fp;
        b.y_fp += b.vy_fp;
        const x_px = @divFloor(b.x_fp, FP_ONE);
        const y_px = @divFloor(b.y_fp, FP_ONE);
        if (y_px < -24 or x_px < -20 or x_px > @as(i32, @intCast(RENDER_W)) + 20) {
            b.active = false;
        }
    }
}

fn updateEnemies() void {
    for (&enemies) |*e| {
        if (!e.active) continue;
        e.x_fp += e.vx_fp;
        e.y_fp += e.vy_fp + ENEMY_BASE_SCROLL_FP;

        const x_px = @divFloor(e.x_fp, FP_ONE);
        const y_px = @divFloor(e.y_fp, FP_ONE);

        if (x_px < -32 or x_px > @as(i32, @intCast(RENDER_W)) + 32 or y_px > @as(i32, @intCast(RENDER_H)) + 32) {
            e.active = false;
            continue;
        }

        if (y_px < 8 or y_px > @as(i32, @intCast(RENDER_H)) - 10) continue;

        // Stronger/larger enemies can shoot back.
        const is_shooter = e.hp >= 2 or e.w >= 14 or e.h >= 12;
        if (!is_shooter) continue;

        // Tuned to feel threatening without flooding the screen.
        const chance_denom: u32 = if (e.hp >= 3) 20 else 30;
        if ((nextRand32() % chance_denom) != 0) continue;

        const dx = player_x_fp - e.x_fp;
        var vx = @divTrunc(dx, 24);
        if (vx > FP_ONE * 2) vx = FP_ONE * 2;
        if (vx < -FP_ONE * 2) vx = -FP_ONE * 2;
        const vy = ENEMY_SHOT_BASE_SPEED_FP + @divFloor((e.hp - 1) * FP_ONE, 2) + @divFloor(e.vy_fp, 3);
        spawnEnemyShot(e.x_fp, e.y_fp + @divFloor(e.h, 2) * FP_ONE, vx + @divFloor(e.vx_fp, 2), vy, if (e.hp >= 3) 2 else 1);
    }
}

fn spawnEnemyShot(x_fp: i32, y_fp: i32, vx_fp: i32, vy_fp: i32, damage: i32) void {
    var i: usize = 0;
    while (i < enemy_shots.len) : (i += 1) {
        if (!enemy_shots[i].active) {
            enemy_shots[i].active = true;
            enemy_shots[i].x_fp = x_fp;
            enemy_shots[i].y_fp = y_fp;
            enemy_shots[i].vx_fp = vx_fp;
            enemy_shots[i].vy_fp = vy_fp;
            enemy_shots[i].damage = damage;
            return;
        }
    }
}

fn updateEnemyShots() void {
    for (&enemy_shots) |*s| {
        if (!s.active) continue;
        s.x_fp += s.vx_fp;
        s.y_fp += s.vy_fp;
        const x_px = @divFloor(s.x_fp, FP_ONE);
        const y_px = @divFloor(s.y_fp, FP_ONE);
        if (y_px > @as(i32, @intCast(RENDER_H)) + 20 or x_px < -20 or x_px > @as(i32, @intCast(RENDER_W)) + 20) {
            s.active = false;
        }
    }
}

fn spawnPickup(kind: PickupKind, x_px: i32, y_px: i32) void {
    var i: usize = 0;
    while (i < pickups.len) : (i += 1) {
        if (!pickups[i].active) {
            pickups[i].active = true;
            pickups[i].kind = kind;
            pickups[i].x_fp = x_px * FP_ONE;
            pickups[i].y_fp = y_px * FP_ONE;
            pickups[i].vy_fp = PICKUP_SPEED_FP;
            return;
        }
    }
}

fn maybeDropPickup(enemy_x: i32, enemy_y: i32, enemy_w: i32, enemy_h: i32) void {
    const is_big = enemy_w >= 14 or enemy_h >= 12;
    if (!is_big) return;

    const r = nextRand32();
    if ((r % HEALTH_DROP_CHANCE_DENOM) == 0) {
        spawnPickup(.health, enemy_x, enemy_y);
        return;
    }
    if ((r % WEAPON_DROP_CHANCE_DENOM) == 0) {
        spawnPickup(.weapon, enemy_x, enemy_y);
    }
}

fn updatePickups() void {
    for (&pickups) |*p| {
        if (!p.active) continue;
        p.y_fp += p.vy_fp;
        const y_px = @divFloor(p.y_fp, FP_ONE);
        if (y_px > @as(i32, @intCast(RENDER_H)) + 16) {
            p.active = false;
        }
    }
}

fn handleCollisions() void {
    for (&bullets) |*b| {
        if (!b.active) continue;

        const bx = @divFloor(b.x_fp, FP_ONE);
        const by = @divFloor(b.y_fp, FP_ONE);

        for (&enemies) |*e| {
            if (!e.active) continue;

            const ex = @divFloor(e.x_fp, FP_ONE);
            const ey = @divFloor(e.y_fp, FP_ONE);

            if (rectsOverlap(bx - 1, by - 6, 3, 8, ex - @divFloor(e.w, 2), ey - @divFloor(e.h, 2), e.w, e.h)) {
                b.active = false;
                e.hp -= 1;
                if (e.hp <= 0) {
                    maybeDropPickup(ex, ey, e.w, e.h);
                    e.active = false;
                    score += 10;
                }
                break;
            }
        }

        if (!b.active) continue;
        for (&enemy_shots) |*s| {
            if (!s.active) continue;
            const sx = @divFloor(s.x_fp, FP_ONE);
            const sy = @divFloor(s.y_fp, FP_ONE);
            if (rectsOverlap(bx - 1, by - 6, 3, 8, sx - 2, sy - 3, 4, 6)) {
                b.active = false;
                s.active = false;
                break;
            }
        }
    }

    const pxc = @divFloor(player_x_fp, FP_ONE);
    const pyc = @divFloor(player_y_fp, FP_ONE);

    for (&pickups) |*p| {
        if (!p.active) continue;
        const kx = @divFloor(p.x_fp, FP_ONE);
        const ky = @divFloor(p.y_fp, FP_ONE);
        if (!rectsOverlap(pxc - @divFloor(PLAYER_W, 2), pyc - @divFloor(PLAYER_H, 2), PLAYER_W, PLAYER_H, kx - 4, ky - 4, 8, 8)) continue;

        switch (p.kind) {
            .health => {
                if (player_health < PLAYER_MAX_HEALTH) player_health += 1;
            },
            .weapon => {
                weapon_spray_unlocked = true;
                weapon_mode = .spray;
            },
        }
        p.active = false;
    }

    if (player_invuln_steps <= 0) {
        const px = @divFloor(player_x_fp, FP_ONE) - PLAYER_W / 2;
        const py = @divFloor(player_y_fp, FP_ONE) - PLAYER_H / 2;

        for (&enemy_shots) |*s| {
            if (!s.active) continue;
            const sx = @divFloor(s.x_fp, FP_ONE);
            const sy = @divFloor(s.y_fp, FP_ONE);
            if (!rectsOverlap(px, py, PLAYER_W, PLAYER_H, sx - 2, sy - 3, 4, 6)) continue;

            player_health -= s.damage;
            s.active = false;
            if (player_health <= 0) {
                player_health = 0;
                game_over = true;
            } else {
                player_invuln_steps = PLAYER_INVULN_STEPS;
            }
            return;
        }
    }

    if (player_invuln_steps <= 0) {
        const px = @divFloor(player_x_fp, FP_ONE) - PLAYER_W / 2;
        const py = @divFloor(player_y_fp, FP_ONE) - PLAYER_H / 2;

        for (&enemies) |*e| {
            if (!e.active) continue;
            const ex = @divFloor(e.x_fp, FP_ONE) - @divFloor(e.w, 2);
            const ey = @divFloor(e.y_fp, FP_ONE) - @divFloor(e.h, 2);

            if (rectsOverlap(px, py, PLAYER_W, PLAYER_H, ex, ey, e.w, e.h)) {
                // Colliding enemies deal 1 for light ships, 2 for tougher ones.
                const damage: i32 = if (e.hp >= 2 or e.w >= 14) 2 else 1;
                player_health -= damage;
                if (player_health <= 0) {
                    player_health = 0;
                    game_over = true;
                } else {
                    player_invuln_steps = PLAYER_INVULN_STEPS;
                }
                e.active = false;
                return;
            }
        }
    }
}

fn rectsOverlap(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by;
}

fn drawGame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawStarField();
    drawEnemies();
    drawEnemyShots();
    drawPickups();
    drawBullets();
    drawPlayer();
    drawHud();
    if (game_over) drawGameOverStripe();
}

fn drawStarField() void {
    var i: usize = 0;
    while (i < 96) : (i += 1) {
        const seed_i = mix32(seed ^ @as(u32, @intCast(i *% 0x45d9f3b)));
        const x = @as(usize, @intCast(seed_i % @as(u32, @intCast(RENDER_W))));
        const phase = @as(i32, @intCast((seed_i >> 8) % @as(u32, @intCast(RENDER_H))));
        const y = @as(usize, @intCast(@mod(phase + world_distance_px * (1 + @as(i32, @intCast((seed_i >> 16) % 3))), @as(i32, @intCast(RENDER_H)))));

        const c = if ((seed_i & 0x7) == 0) COLOR_PLAYER_ACCENT else COLOR_STAR;
        setPixel(x, y, c);
    }
}

fn drawPlayer() void {
    if (player_invuln_steps > 0 and @mod(player_invuln_steps, 6) < 3) return;

    const cx = @divFloor(player_x_fp, FP_ONE);
    const cy = @divFloor(player_y_fp, FP_ONE);
    const x0 = cx - PLAYER_W / 2;
    const y0 = cy - PLAYER_H / 2;

    fillRectI32(x0 + 2, y0 + 2, PLAYER_W - 4, PLAYER_H - 2, COLOR_PLAYER);
    fillRectI32(cx - 1, y0, 3, PLAYER_H, COLOR_PLAYER_ACCENT);
    fillRectI32(x0, y0 + 5, PLAYER_W, 2, COLOR_PLAYER_ACCENT);
}

fn drawBullets() void {
    for (bullets) |b| {
        if (!b.active) continue;
        const x = @divFloor(b.x_fp, FP_ONE);
        const y = @divFloor(b.y_fp, FP_ONE);
        fillRectI32(x - 1, y - 6, 3, 8, COLOR_BULLET);
    }
}

fn drawEnemies() void {
    for (enemies) |e| {
        if (!e.active) continue;
        const x = @divFloor(e.x_fp, FP_ONE);
        const y = @divFloor(e.y_fp, FP_ONE);
        const c = if (e.hp >= 2) COLOR_ENEMY_TOUGH else COLOR_ENEMY;

        fillRectI32(x - @divFloor(e.w, 2), y - @divFloor(e.h, 2), e.w, e.h, c);
        fillRectI32(x - 1, y - @divFloor(e.h, 2) - 2, 3, 2, c);
    }
}

fn drawEnemyShots() void {
    for (enemy_shots) |s| {
        if (!s.active) continue;
        const x = @divFloor(s.x_fp, FP_ONE);
        const y = @divFloor(s.y_fp, FP_ONE);
        fillRectI32(x - 1, y - 3, 3, 6, COLOR_ENEMY_SHOT);
    }
}

fn drawPickups() void {
    for (pickups) |p| {
        if (!p.active) continue;
        const x = @divFloor(p.x_fp, FP_ONE);
        const y = @divFloor(p.y_fp, FP_ONE);
        switch (p.kind) {
            .health => {
                fillRectI32(x - 4, y - 1, 8, 2, COLOR_PICKUP_HEALTH);
                fillRectI32(x - 1, y - 4, 2, 8, COLOR_PICKUP_HEALTH);
            },
            .weapon => {
                fillRectI32(x - 4, y - 4, 8, 8, COLOR_PICKUP_WEAPON);
                fillRectI32(x - 2, y - 2, 4, 4, .{ 0xD2, 0xD4, 0xFF, 0xFF });
            },
        }
    }
}

fn drawHud() void {
    // Top progress strip and score bars.
    fillRect(0, 0, RENDER_W, 8, .{ 0x11, 0x1A, 0x31, 0xFF });

    const score_units = @divFloor(score, 10);
    const meter = @min(@as(usize, @intCast(score_units)), RENDER_W - 2);
    fillRect(1, 1, meter, 3, .{ 0x5C, 0xF0, 0x9D, 0xFF });

    const wave_mod = @mod(wave_index, @as(i32, @intCast(RENDER_W - 2)));
    fillRect(@as(usize, @intCast(1 + wave_mod)), 5, 6, 2, .{ 0xF8, 0xD2, 0x73, 0xFF });

    // Health bar on the top-right.
    const bar_w: usize = 60;
    const bar_h: usize = 5;
    const bar_x: usize = RENDER_W - bar_w - 4;
    const bar_y: usize = 1;
    fillRect(bar_x, bar_y, bar_w, bar_h, .{ 0x3A, 0x1B, 0x22, 0xFF });
    const hp_w = @as(usize, @intCast(@divFloor(player_health * @as(i32, @intCast(bar_w)), PLAYER_MAX_HEALTH)));
    const hp_color: Color = if (player_health >= 3) .{ 0x58, 0xE8, 0x78, 0xFF } else if (player_health >= 2) .{ 0xF2, 0xC5, 0x55, 0xFF } else .{ 0xF0, 0x62, 0x5C, 0xFF };
    fillRect(bar_x, bar_y, hp_w, bar_h, hp_color);

    // Weapon indicator at top-left.
    fillRect(2, 9, 38, 8, .{ 0x10, 0x16, 0x2C, 0xFF });
    if (weapon_mode == .single) {
        fillRect(4, 11, 10, 4, .{ 0xFF, 0xE1, 0x65, 0xFF });
        if (weapon_spray_unlocked) fillRect(16, 11, 4, 4, .{ 0x7A, 0x88, 0xC9, 0xFF });
    } else {
        fillRect(4, 11, 3, 4, .{ 0xFF, 0xE1, 0x65, 0xFF });
        fillRect(10, 11, 3, 4, .{ 0xFF, 0xE1, 0x65, 0xFF });
        fillRect(16, 11, 3, 4, .{ 0xFF, 0xE1, 0x65, 0xFF });
    }
}

fn drawGameOverStripe() void {
    const y = @divFloor(@as(i32, @intCast(RENDER_H)), 2) - 12;
    fillRectI32(0, y, @as(i32, @intCast(RENDER_W)), 24, .{ 0x1F, 0x0E, 0x0E, 0xE8 });

    // Minimal geometric text substitute.
    const mid = @divFloor(@as(i32, @intCast(RENDER_W)), 2);
    fillRectI32(mid - 56, y + 8, 22, 8, COLOR_GAME_OVER);
    fillRectI32(mid - 28, y + 8, 8, 8, COLOR_GAME_OVER);
    fillRectI32(mid - 14, y + 8, 8, 8, COLOR_GAME_OVER);
    fillRectI32(mid + 1, y + 8, 22, 8, COLOR_GAME_OVER);
    fillRectI32(mid + 29, y + 8, 22, 8, COLOR_GAME_OVER);
}

fn setPixel(x: usize, y: usize, color: Color) void {
    if (x >= RENDER_W or y >= RENDER_H) return;
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = color[0];
    output_buf[idx + 1] = color[1];
    output_buf[idx + 2] = color[2];
    output_buf[idx + 3] = color[3];
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    if (w == 0 or h == 0) return;

    var y = y0;
    while (y < y0 + h and y < RENDER_H) : (y += 1) {
        var x = x0;
        while (x < x0 + w and x < RENDER_W) : (x += 1) {
            setPixel(x, y, color);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, color: Color) void {
    if (w <= 0 or h <= 0) return;

    const sx = @max(0, x0);
    const sy = @max(0, y0);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x0 + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y0 + h);
    if (sx >= ex or sy >= ey) return;

    fillRect(
        @as(usize, @intCast(sx)),
        @as(usize, @intCast(sy)),
        @as(usize, @intCast(ex - sx)),
        @as(usize, @intCast(ey - sy)),
        color,
    );
}

fn mix32(x: u32) u32 {
    var z = x +% 0x9E37_79B9;
    z ^= z >> 16;
    z *%= 0x7FEB_352D;
    z ^= z >> 15;
    z *%= 0x846C_A68B;
    z ^= z >> 16;
    return z;
}

fn nextRand32() u32 {
    rng_state = mix32(rng_state ^ 0xA341_316C);
    return rng_state;
}

test "spawn wave creates at least one enemy" {
    for (&enemies) |*e| e.* = .{};
    seed = 0x1234_5678;

    spawnWave(3);

    var count: usize = 0;
    for (enemies) |e| {
        if (e.active) count += 1;
    }
    try std.testing.expect(count > 0);
}

test "bullet damages enemy" {
    for (&enemies) |*e| e.* = .{};
    for (&bullets) |*b| b.* = .{};
    score = 0;

    spawnEnemy(40, 40, 0, 0, 1, 12, 10);
    bullets[0] = .{ .active = true, .x_fp = 40 * FP_ONE, .y_fp = 40 * FP_ONE, .vy_fp = BULLET_SPEED_FP };

    handleCollisions();

    try std.testing.expect(!bullets[0].active);
    try std.testing.expect(!enemies[0].active);
    try std.testing.expect(score == 10);
}

test "player takes damage and survives hit" {
    for (&enemies) |*e| e.* = .{};
    player_x_fp = 80 * FP_ONE;
    player_y_fp = 240 * FP_ONE;
    player_health = PLAYER_MAX_HEALTH;
    player_invuln_steps = 0;
    game_over = false;

    spawnEnemy(80, 240, 0, 0, 1, 12, 10);
    handleCollisions();

    try std.testing.expect(player_health == PLAYER_MAX_HEALTH - 1);
    try std.testing.expect(player_invuln_steps > 0);
    try std.testing.expect(!game_over);
}

test "weapon pickup unlocks spray" {
    for (&pickups) |*p| p.* = .{};
    player_x_fp = 100 * FP_ONE;
    player_y_fp = 250 * FP_ONE;
    weapon_spray_unlocked = false;
    weapon_mode = .single;

    spawnPickup(.weapon, 100, 250);
    handleCollisions();

    try std.testing.expect(weapon_spray_unlocked);
    try std.testing.expect(weapon_mode == .spray);
}

test "player bullet cancels enemy shot" {
    for (&bullets) |*b| b.* = .{};
    for (&enemy_shots) |*s| s.* = .{};

    bullets[0] = .{ .active = true, .x_fp = 120 * FP_ONE, .y_fp = 120 * FP_ONE, .vx_fp = 0, .vy_fp = BULLET_SPEED_FP };
    enemy_shots[0] = .{ .active = true, .x_fp = 120 * FP_ONE, .y_fp = 120 * FP_ONE, .vx_fp = 0, .vy_fp = ENEMY_SHOT_BASE_SPEED_FP, .damage = 1 };

    handleCollisions();

    try std.testing.expect(!bullets[0].active);
    try std.testing.expect(!enemy_shots[0].active);
}
