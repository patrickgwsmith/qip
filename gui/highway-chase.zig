const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

// A vertically scrolling road chase in the style of Spy Hunter. The road is
// generated row by row ahead of the player into a fixed ring buffer, so the
// course never ends and memory stays constant.

const SCREEN_W: usize = 320;
const SCREEN_H: usize = 480;
const W: i32 = @intCast(SCREEN_W);
const H: i32 = @intCast(SCREEN_H);
const PIXEL_BYTES: usize = SCREEN_W * SCREEN_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_ENTER: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const KEY_LEFT: u8 = 1 << 0;
const KEY_RIGHT: u8 = 1 << 1;
const KEY_GAS: u8 = 1 << 2;
const KEY_BRAKE: u8 = 1 << 3;
const KEY_FIRE: u8 = 1 << 4;

const STEP_MS: i64 = 16;
const STEP: i32 = 16;
const MAX_STEPS_PER_UPDATE: i32 = 8;

// Positions use 1/256 px fixed point. Speeds are fixed-point px per step.
const FP: i32 = 256;
const MAX_SPEED: i32 = 1640; // About 400 px/s.
const ACCEL: i32 = 14;
const BRAKE: i32 = 44;
const COAST: i32 = 4;
const SHOULDER_SPEED: i32 = MAX_SPEED * 2 / 5;
const SHOULDER_DRAG: i32 = 30;
const STEER_BASE: i32 = 100;

const ROW_PX: i32 = 4;
const ROW_COUNT: usize = 256;
const ROW_MASK: i32 = @intCast(ROW_COUNT - 1);
const ROWS_START: i32 = -64;
const ROWS_AHEAD_PX: i32 = 640;
const SHOULDER_PX: i32 = 12;
const LANE_MIN_PX: i32 = 40;
const FORK_CLOSE_ROWS: i32 = 64;

const PLAYER_SCREEN_Y: i32 = 360;
const CAR_W: i32 = 14;
const CAR_H: i32 = 24;
const TRUCK_W: i32 = 16;
const TRUCK_H: i32 = 40;
const OIL_W: i32 = 18;
const OIL_H: i32 = 12;

const MAX_CARS: usize = 12;
const MAX_BULLETS: usize = 16;
const MAX_OIL: usize = 4;

const START_LIVES: i32 = 3;
const MAX_LIVES: i32 = 6;
const EXTRA_LIFE_POINTS: u32 = 10_000;
const FREE_CAR_MS: i32 = 45_000;
const CRASH_MS: i32 = 1400;
const WRECK_MS: i32 = 700;
const SPIN_MS: i32 = 800;
const INVULN_MS: i32 = 2500;
const FIRE_MS: i32 = 100;
const OIL_COOLDOWN_MS: i32 = 2200;
const OIL_TTL_MS: i32 = 7000;
const FREEZE_MS: i32 = 5000;
const TOUCH_MS: i32 = 2000;
const MESSAGE_MS: i32 = 2000;
const BULLET_SPEED: i32 = 9 * FP;

// World coordinates move back by a multiple of the ring size before i32
// fixed-point positions can overflow, so ring slots keep their rows.
const REBASE_PX: i32 = 1 << 20;
const REBASE_SHIFT_PX: i32 = 1 << 19;

const Color = [4]u8;
const C_GRASS: Color = .{ 0x3C, 0x8A, 0x3E, 0xFF };
const C_GRASS_DARK: Color = .{ 0x2F, 0x70, 0x33, 0xFF };
const C_SHOULDER: Color = .{ 0x8F, 0x86, 0x5A, 0xFF };
const C_ROAD: Color = .{ 0x4A, 0x4D, 0x55, 0xFF };
const C_LINE: Color = .{ 0xEE, 0xEE, 0xE6, 0xFF };
const C_CENTER: Color = .{ 0xF2, 0xC9, 0x3B, 0xFF };
const C_WATER: Color = .{ 0x1E, 0x5E, 0xA8, 0xFF };
const C_WATER_LIGHT: Color = .{ 0x5D, 0x9C, 0xDB, 0xFF };
const C_SAND: Color = .{ 0xD8, 0xC2, 0x84, 0xFF };
const C_RAIL: Color = .{ 0xB4, 0xB8, 0xBE, 0xFF };
const C_RAIL_POST: Color = .{ 0x5E, 0x63, 0x6B, 0xFF };
const C_TREE: Color = .{ 0x1D, 0x54, 0x26, 0xFF };
const C_TREE_LIGHT: Color = .{ 0x3E, 0x7F, 0x3A, 0xFF };
const C_TIRE: Color = .{ 0x15, 0x15, 0x18, 0xFF };
const C_GLASS: Color = .{ 0x2A, 0x3F, 0x66, 0xFF };
const C_HEADLIGHT: Color = .{ 0xFF, 0xF4, 0xB0, 0xFF };
const C_TAILLIGHT: Color = .{ 0xE0, 0x2A, 0x2A, 0xFF };
const C_PLAYER: Color = .{ 0xF2, 0xF4, 0xF7, 0xFF };
const C_PLAYER_ROOF: Color = .{ 0xC9, 0xCF, 0xD8, 0xFF };
const C_PLAYER_STRIPE: Color = .{ 0xD7, 0x26, 0x2E, 0xFF };
const C_RAMMER: Color = .{ 0x2A, 0x2A, 0x33, 0xFF };
const C_RAMMER_ROOF: Color = .{ 0x5B, 0x2A, 0x78, 0xFF };
const C_SPIKE: Color = .{ 0xF5, 0xD0, 0x2E, 0xFF };
const C_WEAVER: Color = .{ 0x55, 0x60, 0x2E, 0xFF };
const C_WEAVER_ROOF: Color = .{ 0x3B, 0x43, 0x1F, 0xFF };
const C_TURRET: Color = .{ 0x9A, 0xA0, 0xA6, 0xFF };
const C_CARGO: Color = .{ 0xDD, 0xDA, 0xD0, 0xFF };
const C_CARGO_EDGE: Color = .{ 0x9E, 0x99, 0x8C, 0xFF };
const C_BULLET: Color = .{ 0xFF, 0xE8, 0x6A, 0xFF };
const C_OIL: Color = .{ 0x0E, 0x0C, 0x10, 0xFF };
const C_OIL_SHINE: Color = .{ 0x4A, 0x3A, 0x60, 0xFF };
const C_FIRE: Color = .{ 0xF2, 0x6B, 0x1D, 0xFF };
const C_FIRE_HOT: Color = .{ 0xFF, 0xD8, 0x4A, 0xFF };
const C_FIRE_CORE: Color = .{ 0xFF, 0xFB, 0xE8, 0xFF };
const C_SMOKE: Color = .{ 0x3A, 0x3A, 0x3E, 0xFF };
const C_CHAR: Color = .{ 0x22, 0x1E, 0x1C, 0xFF };
const C_SPLASH: Color = .{ 0xE6, 0xF4, 0xFF, 0xFF };
const C_HUD: Color = .{ 0x08, 0x0B, 0x12, 0xC8 };
const C_SHADE: Color = .{ 0x06, 0x08, 0x10, 0xA8 };
const C_TEXT: Color = .{ 0xF4, 0xF6, 0xFA, 0xFF };
const C_TEXT_DIM: Color = .{ 0x88, 0x90, 0xA0, 0xFF };
const C_TEXT_SHADOW: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_TITLE: Color = .{ 0xF2, 0x4B, 0x3A, 0xFF };
const C_TITLE_ALT: Color = .{ 0xF5, 0xD0, 0x2E, 0xFF };
const C_WARN: Color = .{ 0xFF, 0x5A, 0x4E, 0xFF };
const C_GOOD: Color = .{ 0x7C, 0xE0, 0x6A, 0xFF };

const CIVILIAN_COLORS = [_]Color{
    .{ 0x2D, 0x6C, 0xDF, 0xFF },
    .{ 0xF2, 0xC2, 0x2E, 0xFF },
    .{ 0x2B, 0xB3, 0xA6, 0xFF },
    .{ 0xE8, 0x7D, 0x2C, 0xFF },
    .{ 0xD9, 0x5C, 0x9B, 0xFF },
};

const Row = struct {
    l: i32 = 0,
    r: i32 = 0,
    // A median exists when ml < mr.
    ml: i32 = 0,
    mr: i32 = 0,
    water: bool = false,
};

const Segment = enum(u8) { cruise, fork, bridge };
const Surface = enum(u8) { road, shoulder, rough, water };

const Kind = enum(u8) { sedan, truck, rammer, weaver };
const CarState = enum(u8) { free, driving, spinning, wrecked };

const Car = struct {
    state: CarState = .free,
    kind: Kind = .sedan,
    x: i32 = 0,
    y: i32 = 0,
    vy: i32 = 0,
    shove: i32 = 0,
    lane: i32 = 0,
    hp: i32 = 0,
    timer: i32 = 0,
    phase: u8 = 0,
    side: i32 = 1,
    color: u8 = 0,
    touched_ms: i32 = 0,
    flash_ms: i32 = 0,
};

const Bullet = struct {
    active: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    vy: i32 = 0,
};

const Oil = struct {
    active: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    ttl_ms: i32 = 0,
};

const Mode = enum(u8) { title, playing, paused, game_over };

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var rows: [ROW_COUNT]Row = [_]Row{.{}} ** ROW_COUNT;
var gen_row: i32 = 0;
var gen_center: i32 = 0;
var gen_half: i32 = 0;
var gen_median: i32 = 0;
var seg: Segment = .cruise;
var seg_rows: i32 = 0;
var seg_center: i32 = 0;
var seg_half: i32 = 0;
var seg_median: i32 = 0;
var bridge_water: bool = false;

var cars: [MAX_CARS]Car = [_]Car{.{}} ** MAX_CARS;
var bullets: [MAX_BULLETS]Bullet = [_]Bullet{.{}} ** MAX_BULLETS;
var oils: [MAX_OIL]Oil = [_]Oil{.{}} ** MAX_OIL;

var mode: Mode = .title;
var keys_down: u8 = 0;
var rng_state: u32 = 0x6C8E9CF5;
var anim_ms: i32 = 0;

var player_x: i32 = 0;
var dist: i32 = 0;
var speed: i32 = 0;
var player_shove: i32 = 0;
var on_shoulder: bool = false;
var crash_ms: i32 = 0;
var crash_water: bool = false;
var invuln_ms: i32 = 0;
var fire_ms: i32 = 0;
var gun_side: i32 = 1;
var oil_ms: i32 = 0;

var lives: i32 = START_LIVES;
var free_ms: i32 = FREE_CAR_MS;
var score: u32 = 0;
var hi_score: u32 = 0;
var next_extra_life: u32 = EXTRA_LIFE_POINTS;
var score_acc: i32 = 0;
var freeze_ms: i32 = 0;
var message_ms: i32 = 0;
var odometer_px: u32 = 0;
var last_spawn_px: i32 = 0;
var spawn_gap_px: i32 = 0;
var rammer_ms: i32 = 0;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var last_step_ms: i64 = 0;

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
    if (phase != .ready or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;

    const bit: u8 = switch (x11_key) {
        XK_LEFT, 'a', 'A' => KEY_LEFT,
        XK_RIGHT, 'd', 'D' => KEY_RIGHT,
        XK_UP, 'w', 'W' => KEY_GAS,
        XK_DOWN, 's', 'S' => KEY_BRAKE,
        ' ', 'z', 'Z' => KEY_FIRE,
        else => 0,
    };
    const was_down = (keys_down & bit) != 0;
    if (bit != 0) {
        if (is_down) keys_down |= bit else keys_down &= ~bit;
    }
    if (!is_down) return if (bit != 0 and was_down) 1 else 0;
    if (bit != 0 and was_down) return 0;

    switch (x11_key) {
        ' ', XK_ENTER => {
            if (mode == .title or mode == .game_over) {
                startGame(begun_at_ms);
                return 1;
            }
            if (mode == .paused and x11_key == XK_ENTER) {
                resume_();
                return 1;
            }
        },
        'p', 'P', XK_ESCAPE => {
            if (mode == .playing) {
                mode = .paused;
                return 1;
            }
            if (mode == .paused) {
                resume_();
                return 1;
            }
            return 0;
        },
        'r', 'R' => {
            startGame(begun_at_ms);
            return 1;
        },
        'x', 'X', 'c', 'C' => return if (dropOil()) 1 else 0,
        else => {},
    }
    return if (bit != 0) 1 else 0;
}

export fn pointer_event(_: i32, _: i32, _: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    return 0;
}

fn requireEventPhase() void {
    if (phase != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (mode != .playing) return;

    var elapsed = begun_at_ms - last_step_ms;
    var steps: i32 = 0;
    while (elapsed >= STEP_MS and steps < MAX_STEPS_PER_UPDATE and mode == .playing) : (steps += 1) {
        stepGame();
        last_step_ms += STEP_MS;
        elapsed -= STEP_MS;
    }
    // Bound work after a long host pause; the chase cannot replay missed
    // collisions cheaply, so it drops the remaining elapsed time.
    if (mode == .playing and elapsed >= STEP_MS) last_step_ms = begun_at_ms;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    const wake = if (mode == .playing) last_step_ms +| STEP_MS else begun_at_ms;
    phase = .ready;
    return wake;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    if (phase == .initializing) resetGame();
    _ = ktx.writeHeader(&output_buf, SCREEN_W, SCREEN_H) orelse @trap();
    drawFrame();
    phase = .ready;
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

// Game state

fn resetGame() void {
    mode = .title;
    cars = [_]Car{.{}} ** MAX_CARS;
    bullets = [_]Bullet{.{}} ** MAX_BULLETS;
    oils = [_]Oil{.{}} ** MAX_OIL;
    anim_ms = 0;
    dist = 0;
    speed = 0;
    player_shove = 0;
    on_shoulder = false;
    crash_ms = 0;
    crash_water = false;
    invuln_ms = 0;
    fire_ms = 0;
    gun_side = 1;
    oil_ms = 0;
    lives = START_LIVES;
    free_ms = FREE_CAR_MS;
    score = 0;
    next_extra_life = EXTRA_LIFE_POINTS;
    score_acc = 0;
    freeze_ms = 0;
    message_ms = 0;
    odometer_px = 0;
    last_spawn_px = 0;
    spawn_gap_px = 160;
    rammer_ms = 9000;

    gen_row = ROWS_START;
    gen_center = @divTrunc(W, 2);
    gen_half = 70;
    gen_median = 0;
    seg = .cruise;
    seg_rows = 120;
    seg_center = gen_center;
    seg_half = gen_half;
    seg_median = 0;
    bridge_water = false;
    ensureRows();
    player_x = laneCenterPx(rowAt(0), 1) * FP;
}

fn startGame(at_ms: i64) void {
    // The start time varies between games, so it seeds a different road.
    rng_state ^= @truncate(@as(u64, @bitCast(at_ms)) *% 0x9E3779B97F4A7C15);
    if (rng_state == 0) rng_state = 0x6C8E9CF5;
    resetGame();
    mode = .playing;
    last_step_ms = at_ms;
}

fn resume_() void {
    mode = .playing;
    last_step_ms = begun_at_ms;
}

fn stepGame() void {
    anim_ms +%= STEP;
    if (free_ms > 0) free_ms -= STEP;
    if (freeze_ms > 0) freeze_ms -= STEP;
    if (message_ms > 0) message_ms -= STEP;
    if (oil_ms > 0) oil_ms -= STEP;
    if (fire_ms > 0) fire_ms -= STEP;

    updatePlayer();
    if (mode != .playing) return;
    ensureRows();
    updateCars();
    updateBullets();
    updateOil();
    resolveCollisions();
    spawnTraffic();
    awardDistance();
    rebaseIfNeeded();
}

fn distPx() i32 {
    return @divFloor(dist, FP);
}

fn updatePlayer() void {
    if (crash_ms > 0) {
        crash_ms -= STEP;
        if (crash_ms <= 0) respawnOrEnd();
        return;
    }
    if (invuln_ms > 0) invuln_ms -= STEP;

    if ((keys_down & KEY_BRAKE) != 0) {
        speed -= BRAKE;
    } else if ((keys_down & KEY_GAS) != 0) {
        speed += ACCEL;
    } else {
        speed -= COAST;
    }
    speed = std.math.clamp(speed, 0, MAX_SPEED);

    var steer: i32 = 0;
    if ((keys_down & KEY_LEFT) != 0) steer -= 1;
    if ((keys_down & KEY_RIGHT) != 0) steer += 1;
    player_x += steer * (STEER_BASE + @divTrunc(speed * 3, 10)) + player_shove;
    player_shove = @divTrunc(player_shove * 3, 4);
    dist += speed;

    const foot = footing(player_x, dist, CAR_W, CAR_H);
    if (foot.off >= 2) {
        crashPlayer(foot.water);
        return;
    }
    on_shoulder = foot.shoulder or foot.off > 0;
    if (on_shoulder and speed > SHOULDER_SPEED) speed = @max(SHOULDER_SPEED, speed - SHOULDER_DRAG);

    if ((keys_down & KEY_FIRE) != 0 and fire_ms <= 0) fireBullet();
}

fn crashPlayer(water: bool) void {
    crash_ms = CRASH_MS;
    crash_water = water;
    speed = 0;
    player_shove = 0;
    on_shoulder = false;
}

fn respawnOrEnd() void {
    if (free_ms <= 0) lives -= 1;
    if (lives <= 0) {
        lives = 0;
        mode = .game_over;
        hi_score = @max(hi_score, score);
        return;
    }
    const row = rowAt(@divFloor(distPx(), ROW_PX));
    player_x = laneCenterPx(row, 1) * FP;
    speed = @divTrunc(MAX_SPEED * 35, 100);
    invuln_ms = INVULN_MS;
    for (&cars) |*car| {
        const dy = car.y - dist;
        if (car.state != .free and dy > -200 * FP and dy < 140 * FP) car.state = .free;
    }
    for (&oils) |*oil| oil.active = false;
}

fn fireBullet() void {
    for (&bullets) |*b| {
        if (b.active) continue;
        b.* = .{
            .active = true,
            .x = player_x + gun_side * 4 * FP,
            .y = dist + @divTrunc(CAR_H, 2) * FP,
            .vy = speed + BULLET_SPEED,
        };
        gun_side = -gun_side;
        fire_ms = FIRE_MS;
        return;
    }
}

fn dropOil() bool {
    if (mode != .playing or crash_ms > 0 or oil_ms > 0) return false;
    for (&oils) |*oil| {
        if (oil.active) continue;
        oil.* = .{
            .active = true,
            .x = player_x,
            .y = dist - (@divTrunc(CAR_H, 2) + 10) * FP,
            .ttl_ms = OIL_TTL_MS,
        };
        oil_ms = OIL_COOLDOWN_MS;
        return true;
    }
    return false;
}

fn updateBullets() void {
    for (&bullets) |*b| {
        if (!b.active) continue;
        b.y += b.vy;
        if (b.y - dist > 460 * FP) {
            b.active = false;
            continue;
        }
        for (&cars) |*car| {
            if (car.state != .driving and car.state != .spinning) continue;
            const hw = @divTrunc(carW(car.kind), 2) * FP;
            const hh = @divTrunc(carH(car.kind), 2) * FP;
            if (@abs(b.x - car.x) > hw or @abs(b.y - car.y) > hh) continue;
            b.active = false;
            car.hp -= 1;
            car.flash_ms = 80;
            if (car.hp <= 0) destroyCar(car, true);
            break;
        }
    }
}

fn updateOil() void {
    for (&oils) |*oil| {
        if (!oil.active) continue;
        oil.ttl_ms -= STEP;
        if (oil.ttl_ms <= 0 or oil.y - dist < -300 * FP) {
            oil.active = false;
            continue;
        }
        for (&cars) |*car| {
            if (car.state != .driving) continue;
            if (!overlaps(oil.x, oil.y, OIL_W, OIL_H, car.x, car.y, carW(car.kind), carH(car.kind))) continue;
            car.state = .spinning;
            car.timer = SPIN_MS;
            car.shove = if ((rngNext() & 1) == 0) 220 else -220;
        }
    }
}

fn destroyCar(car: *Car, by_player: bool) void {
    car.state = .wrecked;
    car.timer = WRECK_MS;
    car.shove = 0;
    switch (car.kind) {
        .sedan, .truck => {
            if (by_player or car.touched_ms > 0) freeze_ms = FREEZE_MS;
        },
        .rammer => addScore(250),
        .weaver => addScore(150),
    }
}

fn addScore(points: u32) void {
    if (freeze_ms > 0) return;
    score +|= points;
    if (score >= next_extra_life) {
        next_extra_life +|= EXTRA_LIFE_POINTS;
        if (lives < MAX_LIVES) {
            lives += 1;
            message_ms = MESSAGE_MS;
        }
    }
}

fn awardDistance() void {
    odometer_px +|= @intCast(@divTrunc(speed, FP));
    if (freeze_ms > 0) {
        score_acc = 0;
        return;
    }
    // One point for each 8 px travelled.
    score_acc += speed;
    const points = score_acc >> 11;
    score_acc &= (1 << 11) - 1;
    if (points > 0) addScore(@intCast(points));
}

fn difficulty() i32 {
    return @intCast(@min(odometer_px / 6000, 8));
}

fn spawnTraffic() void {
    if (crash_ms > 0) return;
    const level = difficulty();

    if (distPx() - last_spawn_px >= spawn_gap_px) {
        if (spawnAhead(level)) {
            last_spawn_px = distPx();
            spawn_gap_px = @max(70, rngRange(110, 250) - level * 14);
        }
    }

    if (speed > MAX_SPEED * 3 / 10) rammer_ms -= STEP;
    if (rammer_ms <= 0) {
        var active: i32 = 0;
        for (cars) |car| {
            if (car.state == .driving and car.kind == .rammer) active += 1;
        }
        if (active < 1 + @divTrunc(level, 3)) _ = spawnRammer();
        rammer_ms = @max(3000, rngRange(6000, 10000) - level * 450);
    }
}

fn freeCarSlot() ?*Car {
    for (&cars) |*car| {
        if (car.state == .free) return car;
    }
    return null;
}

fn spawnAhead(level: i32) bool {
    const y = dist + 420 * FP;
    const lane: i32 = @intCast(rngNext() & 1);
    const x = laneCenterPx(rowAtWorld(y), lane) * FP;
    for (cars) |other| {
        if (other.state == .free) continue;
        if (@abs(other.y - y) < 60 * FP and @abs(other.x - x) < 24 * FP) return false;
    }
    const car = freeCarSlot() orelse return false;
    const roll: i32 = @intCast(rngNext() % 100);
    const weaver_chance = @min(35, 14 + level * 3);
    const kind: Kind = if (roll < weaver_chance) .weaver else if (roll < weaver_chance + 20) .truck else .sedan;
    car.* = .{
        .state = .driving,
        .kind = kind,
        .x = x,
        .y = y,
        .lane = lane,
        .hp = 1,
        .timer = rngRange(600, 1400),
        .color = @intCast(rngNext() % CIVILIAN_COLORS.len),
        .vy = switch (kind) {
            .truck => rngRange(500, 700),
            .weaver => rngRange(700, 900),
            else => rngRange(660, 940),
        },
    };
    return true;
}

fn spawnRammer() bool {
    const car = freeCarSlot() orelse return false;
    const y = dist - 170 * FP;
    const lane: i32 = @intCast(rngNext() & 1);
    car.* = .{
        .state = .driving,
        .kind = .rammer,
        .x = laneCenterPx(rowAtWorld(y), lane) * FP,
        .y = y,
        .vy = speed + 220,
        .lane = lane,
        .hp = 3,
        .side = if (lane == 0) -1 else 1,
    };
    return true;
}

fn updateCars() void {
    for (&cars) |*car| {
        if (car.touched_ms > 0) car.touched_ms -= STEP;
        if (car.flash_ms > 0) car.flash_ms -= STEP;
        switch (car.state) {
            .free => continue,
            .driving => driveCar(car),
            .spinning => {
                car.timer -= STEP;
                car.x += car.shove;
                car.vy -= @divTrunc(car.vy, 16);
                if (car.timer <= 0) {
                    destroyCar(car, false);
                } else if (footing(car.x, car.y, carW(car.kind), carH(car.kind)).off >= 2) {
                    destroyCar(car, false);
                }
            },
            .wrecked => {
                car.timer -= STEP;
                car.vy = @divTrunc(car.vy * 7, 8);
                if (car.timer <= 0) car.state = .free;
            },
        }
        car.y += car.vy;
        const dy = car.y - dist;
        if (dy < -300 * FP or dy > 700 * FP) car.state = .free;
    }
}

fn driveCar(car: *Car) void {
    const row = rowAtWorld(car.y + 48 * FP);
    var target = laneCenterPx(row, car.lane) * FP;
    var lateral: i32 = 150;
    const dy = car.y - dist;
    const player_active = crash_ms <= 0;

    switch (car.kind) {
        .sedan, .truck => {},
        .weaver => {
            lateral = 230;
            car.timer -= STEP;
            if (car.timer <= 0) {
                car.lane ^= 1;
                car.timer = rngRange(900, 1700);
            }
            // Block the player when just ahead of them.
            if (player_active and dy > 0 and dy < 200 * FP) {
                target = blockingTarget(row, player_x);
            }
        },
        .rammer => {
            lateral = 300;
            if (!player_active) {
                car.phase = 2;
            } else switch (car.phase) {
                0 => {
                    car.vy = @min(speed + 220, MAX_SPEED + 260);
                    target = player_x + car.side * (CAR_W + 8) * FP;
                    if (dy > -36 * FP) {
                        car.phase = 1;
                        car.timer = 2600;
                        car.side = if (car.x < player_x) -1 else 1;
                    }
                },
                1 => {
                    car.vy = speed + std.math.clamp(@divTrunc(-dy, 16), -60, 60);
                    target = player_x + car.side * (CAR_W - 4) * FP;
                    car.timer -= STEP;
                    if (car.timer <= 0) {
                        car.phase = 2;
                        car.timer = 1500;
                    }
                },
                else => {
                    car.vy = @max(0, speed - 260);
                    car.timer -= STEP;
                    if (car.timer <= 0) car.phase = 0;
                },
            }
            target = std.math.clamp(target, (row.l + 8) * FP, (row.r - 8) * FP);
        },
    }

    const dx = std.math.clamp(target - car.x, -lateral, lateral);
    car.x += dx + car.shove;
    car.shove = @divTrunc(car.shove * 3, 4);

    if (footing(car.x, car.y, carW(car.kind), carH(car.kind)).off >= 2) {
        destroyCar(car, false);
    }
}

fn blockingTarget(row: Row, x: i32) i32 {
    const px = std.math.clamp(@divFloor(x, FP), row.l + 9, row.r - 9);
    if (row.ml < row.mr and px > row.ml - 9 and px < row.mr + 9) {
        return laneCenterPx(row, if (px < @divTrunc(row.ml + row.mr, 2)) 0 else 1) * FP;
    }
    return px * FP;
}

fn resolveCollisions() void {
    if (crash_ms <= 0 and invuln_ms <= 0) {
        for (&cars) |*car| {
            if (car.state != .driving and car.state != .spinning) continue;
            collidePlayer(car);
        }
    }
    // Keep AI cars from driving through each other.
    for (&cars, 0..) |*a, i| {
        if (a.state != .driving and a.state != .spinning) continue;
        for (cars[i + 1 ..]) |*b| {
            if (b.state != .driving and b.state != .spinning) continue;
            const pen_x = @divTrunc(carW(a.kind) + carW(b.kind), 2) * FP - @as(i32, @intCast(@abs(a.x - b.x)));
            const pen_y = @divTrunc(carH(a.kind) + carH(b.kind), 2) * FP - @as(i32, @intCast(@abs(a.y - b.y)));
            if (pen_x <= 0 or pen_y <= 0) continue;
            const dir: i32 = if (b.x >= a.x) 1 else -1;
            a.x -= dir * @divTrunc(pen_x, 2);
            b.x += dir * @divTrunc(pen_x, 2);
            a.shove = -dir * 120;
            b.shove = dir * 120;
        }
    }
}

fn collidePlayer(car: *Car) void {
    const pen_x = @divTrunc(CAR_W + carW(car.kind), 2) * FP - @as(i32, @intCast(@abs(car.x - player_x)));
    const pen_y = @divTrunc(CAR_H + carH(car.kind), 2) * FP - @as(i32, @intCast(@abs(car.y - dist)));
    if (pen_x <= 0 or pen_y <= 0) return;
    car.touched_ms = TOUCH_MS;

    if (pen_x < pen_y) {
        // Side contact: heavier cars push harder.
        const dir: i32 = if (car.x >= player_x) 1 else -1;
        player_x -= dir * @divTrunc(pen_x, 2);
        car.x += dir * @divTrunc(pen_x, 2);
        const push_player: i32 = switch (car.kind) {
            .rammer => 420,
            .truck => 260,
            else => 160,
        };
        const push_car: i32 = switch (car.kind) {
            .rammer => 200,
            .truck => 150,
            else => 380,
        };
        player_shove = -dir * push_player;
        car.shove = dir * push_car;
        return;
    }

    const reach = @divTrunc(CAR_H + carH(car.kind), 2) * FP;
    if (car.y > dist) {
        // Rear-ending the car ahead.
        dist = car.y - reach;
        speed = @max(0, @min(speed, car.vy) - 64);
        car.vy += 96;
    } else {
        // Hit from behind.
        car.y = dist - reach;
        speed = @min(MAX_SPEED, speed + 96);
        car.vy = @max(0, car.vy - 96);
    }
}

fn rebaseIfNeeded() void {
    if (distPx() < REBASE_PX) return;
    const shift = REBASE_SHIFT_PX * FP;
    dist -= shift;
    for (&cars) |*car| car.y -= shift;
    for (&bullets) |*b| b.y -= shift;
    for (&oils) |*oil| oil.y -= shift;
    gen_row -= @divExact(REBASE_SHIFT_PX, ROW_PX);
    last_spawn_px -= REBASE_SHIFT_PX;
}

// Road generation

fn ensureRows() void {
    while (gen_row * ROW_PX < distPx() + ROWS_AHEAD_PX) generateRow();
}

fn generateRow() void {
    if (seg_rows <= 0 and gen_median == 0 and !bridge_water) pickSegment();

    gen_center = approach(gen_center, seg_center);
    gen_half = approach(gen_half, seg_half);
    gen_median = approach(gen_median, seg_median);
    if (gen_median > 0) gen_half = @max(gen_half, gen_median + LANE_MIN_PX);
    const margin = gen_half + SHOULDER_PX + 14;
    gen_center = std.math.clamp(gen_center, margin, W - margin);

    var water = false;
    switch (seg) {
        .cruise => seg_rows -= 1,
        .fork => {
            seg_rows -= 1;
            if (seg_rows <= FORK_CLOSE_ROWS) {
                seg_median = 0;
                seg_half = 72;
            }
        },
        .bridge => {
            if (!bridge_water and gen_center == seg_center and gen_half == seg_half) bridge_water = true;
            if (bridge_water) {
                water = true;
                seg_rows -= 1;
                if (seg_rows <= 0) bridge_water = false;
            }
        },
    }

    rows[@intCast(gen_row & ROW_MASK)] = .{
        .l = gen_center - gen_half,
        .r = gen_center + gen_half,
        .ml = gen_center - gen_median,
        .mr = gen_center + gen_median,
        .water = water,
    };
    gen_row += 1;
}

fn pickSegment() void {
    const roll = rngNext() % 100;
    if (seg != .cruise or roll < 50) {
        seg = .cruise;
        seg_rows = rngRange(50, 130);
        seg_half = rngRange(56, 84);
        seg_center = rngRange(96, W - 96);
        seg_median = 0;
    } else if (roll < 78) {
        seg = .fork;
        seg_rows = rngRange(150, 220);
        seg_half = 128;
        seg_center = @divTrunc(W, 2);
        seg_median = rngRange(36, 56);
    } else {
        seg = .bridge;
        seg_rows = rngRange(60, 110);
        seg_half = 44;
        seg_center = gen_center;
        seg_median = 0;
        bridge_water = false;
    }
}

fn approach(value: i32, target: i32) i32 {
    if (value < target) return value + 1;
    if (value > target) return value - 1;
    return value;
}

fn rowAt(index: i32) Row {
    const i = std.math.clamp(index, gen_row - @as(i32, ROW_COUNT), gen_row - 1);
    return rows[@intCast(i & ROW_MASK)];
}

fn rowAtWorld(y_fp: i32) Row {
    return rowAt(@divFloor(@divFloor(y_fp, FP), ROW_PX));
}

fn laneCenterPx(row: Row, lane: i32) i32 {
    if (row.ml < row.mr) {
        return if (lane == 0) @divTrunc(row.l + row.ml, 2) else @divTrunc(row.mr + row.r, 2);
    }
    const quarter = @divTrunc(row.r - row.l, 4);
    return if (lane == 0) row.l + quarter else row.r - quarter;
}

fn surfaceInRow(row: Row, x: i32) Surface {
    if (x >= row.l and x < row.r) {
        if (row.ml < row.mr and x >= row.ml and x < row.mr) {
            return if (x < row.ml + SHOULDER_PX or x >= row.mr - SHOULDER_PX) .shoulder else .rough;
        }
        return .road;
    }
    if (row.water) return .water;
    if (x >= row.l - SHOULDER_PX and x < row.r + SHOULDER_PX) return .shoulder;
    return .rough;
}

const Footing = struct { off: u8, shoulder: bool, water: bool };

// Samples the four corners of a car footprint.
fn footing(x_fp: i32, y_fp: i32, w: i32, h: i32) Footing {
    const cx = @divFloor(x_fp, FP);
    const cy = @divFloor(y_fp, FP);
    const hw = @divTrunc(w, 2) - 1;
    const hh = @divTrunc(h, 2) - 2;
    var result: Footing = .{ .off = 0, .shoulder = false, .water = false };
    for ([_]i32{ cy - hh, cy + hh }) |y| {
        const row = rowAt(@divFloor(y, ROW_PX));
        for ([_]i32{ cx - hw, cx + hw }) |x| {
            switch (surfaceInRow(row, x)) {
                .road => {},
                .shoulder => result.shoulder = true,
                .rough => result.off += 1,
                .water => {
                    result.off += 1;
                    result.water = true;
                },
            }
        }
    }
    return result;
}

fn carW(kind: Kind) i32 {
    return if (kind == .truck) TRUCK_W else CAR_W;
}

fn carH(kind: Kind) i32 {
    return if (kind == .truck) TRUCK_H else CAR_H;
}

fn overlaps(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return @abs(ax - bx) * 2 < @as(u32, @intCast((aw + bw) * FP)) and
        @abs(ay - by) * 2 < @as(u32, @intCast((ah + bh) * FP));
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn rngRange(lo: i32, hi: i32) i32 {
    const span: u32 = @intCast(hi - lo + 1);
    return lo + @as(i32, @intCast(rngNext() % span));
}

fn hash32(v: i32) u32 {
    var x: u32 = @bitCast(v);
    x ^= x >> 16;
    x *%= 0x7FEB352D;
    x ^= x >> 15;
    x *%= 0x846CA68B;
    x ^= x >> 16;
    return x;
}

// Drawing

fn screenY(world_fp: i32) i32 {
    return PLAYER_SCREEN_Y - @divFloor(world_fp - dist, FP);
}

fn drawFrame() void {
    drawRoad();
    drawTrees();
    drawOil();
    for (cars) |car| {
        if (car.state == .driving or car.state == .spinning) drawAiCar(car);
    }
    drawPlayer();
    for (cars) |car| {
        if (car.state == .wrecked) drawExplosion(@divFloor(car.x, FP), screenY(car.y), WRECK_MS - car.timer, carW(car.kind), carH(car.kind));
    }
    drawBullets();
    drawHud();
    switch (mode) {
        .title => drawTitle(),
        .paused => drawPaused(),
        .game_over => drawGameOver(),
        .playing => {},
    }
}

fn drawRoad() void {
    const base_px = distPx() + PLAYER_SCREEN_Y;
    var sy: i32 = 0;
    while (sy < H) : (sy += 1) {
        const wy = base_px - sy;
        const ri = @divFloor(wy, ROW_PX);
        const row = rowAt(ri);
        const h = hash32(wy);
        if (row.water) {
            const shore = !rowAt(ri - 1).water or !rowAt(ri + 1).water;
            fillSpan(sy, 0, W, if (shore) C_SAND else C_WATER);
            if (!shore and (h & 3) == 0) {
                const x = @as(i32, @intCast((h >> 8) % SCREEN_W)) + @divTrunc(anim_ms, 60);
                fillSpan(sy, @mod(x, W), @mod(x, W) + 7, C_WATER_LIGHT);
            }
            fillSpan(sy, row.l - 4, row.l, if ((ri & 3) == 0) C_RAIL_POST else C_RAIL);
            fillSpan(sy, row.r, row.r + 4, if ((ri & 3) == 0) C_RAIL_POST else C_RAIL);
        } else {
            fillSpan(sy, 0, W, C_GRASS);
            for ([_]u5{ 0, 10, 20 }) |shift| {
                const x: i32 = @intCast((h >> shift) % SCREEN_W);
                fillSpan(sy, x, x + 2, C_GRASS_DARK);
            }
            fillSpan(sy, row.l - SHOULDER_PX, row.l, C_SHOULDER);
            fillSpan(sy, row.r, row.r + SHOULDER_PX, C_SHOULDER);
        }
        fillSpan(sy, row.l, row.r, C_ROAD);
        fillSpan(sy, row.l + 2, row.l + 4, C_LINE);
        fillSpan(sy, row.r - 4, row.r - 2, C_LINE);
        if (row.ml < row.mr) {
            fillSpan(sy, row.ml, row.mr, C_GRASS);
            fillSpan(sy, row.ml, @min(row.mr, row.ml + SHOULDER_PX), C_SHOULDER);
            fillSpan(sy, @max(row.ml, row.mr - SHOULDER_PX), row.mr, C_SHOULDER);
            fillSpan(sy, row.ml - 4, row.ml - 2, C_LINE);
            fillSpan(sy, row.mr + 2, row.mr + 4, C_LINE);
        } else if ((ri & 7) < 4) {
            const c = @divTrunc(row.l + row.r, 2);
            fillSpan(sy, c - 1, c + 1, C_CENTER);
        }
    }
}

fn drawTrees() void {
    const top = @divFloor(distPx() + PLAYER_SCREEN_Y + 12, ROW_PX);
    const bottom = @divFloor(distPx() + PLAYER_SCREEN_Y - H - 12, ROW_PX);
    var ri = bottom;
    while (ri <= top) : (ri += 1) {
        const h = hash32(ri *% 7919);
        if ((h & 3) != 0) continue;
        const row = rowAt(ri);
        const sy = PLAYER_SCREEN_Y - (ri * ROW_PX + 2 - distPx());
        for ([_]u5{ 4, 16 }) |shift| {
            const tx: i32 = @intCast((h >> shift) % SCREEN_W);
            if (surfaceInRow(row, tx - 8) != .rough or surfaceInRow(row, tx + 8) != .rough or surfaceInRow(row, tx) != .rough) continue;
            fillCircle(tx, sy, 7, C_TREE);
            fillCircle(tx - 2, sy - 2, 3, C_TREE_LIGHT);
        }
    }
}

fn drawOil() void {
    for (oils) |oil| {
        if (!oil.active) continue;
        const cx = @divFloor(oil.x, FP);
        const cy = screenY(oil.y);
        fillCircle(cx - 3, cy, 6, C_OIL);
        fillCircle(cx + 4, cy + 1, 5, C_OIL);
        fillCircle(cx, cy - 2, 4, C_OIL);
        fillRect(cx - 4, cy - 2, 3, 1, C_OIL_SHINE);
    }
}

fn drawBullets() void {
    for (bullets) |b| {
        if (!b.active) continue;
        fillRect(@divFloor(b.x, FP) - 1, screenY(b.y) - 3, 2, 6, C_BULLET);
    }
}

fn drawPlayer() void {
    const cx = @divFloor(player_x, FP);
    if (crash_ms > 0) {
        if (crash_water) {
            drawSplash(cx, PLAYER_SCREEN_Y, CRASH_MS - crash_ms);
        } else {
            drawExplosion(cx, PLAYER_SCREEN_Y, @min(WRECK_MS, CRASH_MS - crash_ms), CAR_W, CAR_H);
        }
        return;
    }
    if (invuln_ms > 0 and @mod(@divTrunc(invuln_ms, 100), 2) == 1) return;
    const rumble: i32 = if (on_shoulder and speed > 0) @mod(@divTrunc(anim_ms, 32), 2) else 0;
    drawCarBody(cx + rumble, PLAYER_SCREEN_Y, CAR_W, CAR_H, C_PLAYER, C_PLAYER_ROOF);
    fillRect(cx + rumble - 3, PLAYER_SCREEN_Y - 12, 2, 6, C_PLAYER_STRIPE);
    fillRect(cx + rumble + 1, PLAYER_SCREEN_Y - 12, 2, 6, C_PLAYER_STRIPE);
    fillRect(cx + rumble - 3, PLAYER_SCREEN_Y + 9, 2, 3, C_PLAYER_STRIPE);
    fillRect(cx + rumble + 1, PLAYER_SCREEN_Y + 9, 2, 3, C_PLAYER_STRIPE);
}

fn drawAiCar(car: Car) void {
    const cx = @divFloor(car.x, FP);
    const cy = screenY(car.y);
    const w = carW(car.kind);
    const h = carH(car.kind);
    if (car.state == .spinning and @mod(@divTrunc(car.timer, 70), 2) == 0) {
        // Spinning cars alternate between upright and sideways frames.
        const body = carColor(car);
        fillRect(cx - @divTrunc(h, 2), cy - @divTrunc(w, 2), h, w, body);
        fillRect(cx - @divTrunc(h, 2) + 6, cy - @divTrunc(w, 2) + 2, 4, w - 4, C_GLASS);
        return;
    }
    if (car.flash_ms > 0) {
        drawCarBody(cx, cy, w, h, C_TEXT, C_TEXT);
        return;
    }
    switch (car.kind) {
        .sedan => drawCarBody(cx, cy, w, h, CIVILIAN_COLORS[car.color], shade(CIVILIAN_COLORS[car.color])),
        .truck => drawTruck(cx, cy, CIVILIAN_COLORS[car.color]),
        .rammer => {
            drawCarBody(cx, cy, w, h, C_RAMMER, C_RAMMER_ROOF);
            const x0 = cx - @divTrunc(w, 2);
            for ([_]i32{ 5, h - 7 }) |oy| {
                fillRect(x0 - 4, cy - @divTrunc(h, 2) + oy, 3, 2, C_SPIKE);
                fillRect(x0 + w + 1, cy - @divTrunc(h, 2) + oy, 3, 2, C_SPIKE);
            }
        },
        .weaver => {
            drawCarBody(cx, cy, w, h, C_WEAVER, C_WEAVER_ROOF);
            fillCircle(cx, cy + 1, 3, C_TURRET);
            fillRect(cx, cy - 7, 1, 6, C_TURRET);
        },
    }
}

fn carColor(car: Car) Color {
    return switch (car.kind) {
        .sedan, .truck => CIVILIAN_COLORS[car.color],
        .rammer => C_RAMMER,
        .weaver => C_WEAVER,
    };
}

fn shade(c: Color) Color {
    return .{ c[0] - c[0] / 5, c[1] - c[1] / 5, c[2] - c[2] / 5, 0xFF };
}

fn drawCarBody(cx: i32, cy: i32, w: i32, h: i32, body: Color, roof: Color) void {
    const x0 = cx - @divTrunc(w, 2);
    const y0 = cy - @divTrunc(h, 2);
    fillRect(x0 - 1, y0 + 3, 3, 6, C_TIRE);
    fillRect(x0 + w - 2, y0 + 3, 3, 6, C_TIRE);
    fillRect(x0 - 1, y0 + h - 9, 3, 6, C_TIRE);
    fillRect(x0 + w - 2, y0 + h - 9, 3, 6, C_TIRE);
    fillRect(x0 + 1, y0, w - 2, h, body);
    fillRect(x0, y0 + 2, w, h - 4, body);
    fillRect(x0 + 2, y0 + 6, w - 4, 4, C_GLASS);
    fillRect(x0 + 2, y0 + 10, w - 4, 7, roof);
    fillRect(x0 + 2, y0 + 17, w - 4, 3, C_GLASS);
    fillRect(x0 + 2, y0, 2, 1, C_HEADLIGHT);
    fillRect(x0 + w - 4, y0, 2, 1, C_HEADLIGHT);
    fillRect(x0 + 1, y0 + h - 1, 3, 1, C_TAILLIGHT);
    fillRect(x0 + w - 4, y0 + h - 1, 3, 1, C_TAILLIGHT);
}

fn drawTruck(cx: i32, cy: i32, cab: Color) void {
    const x0 = cx - @divTrunc(TRUCK_W, 2);
    const y0 = cy - @divTrunc(TRUCK_H, 2);
    fillRect(x0 - 1, y0 + 3, 3, 6, C_TIRE);
    fillRect(x0 + TRUCK_W - 2, y0 + 3, 3, 6, C_TIRE);
    for ([_]i32{ TRUCK_H - 16, TRUCK_H - 8 }) |oy| {
        fillRect(x0 - 1, y0 + oy, 3, 6, C_TIRE);
        fillRect(x0 + TRUCK_W - 2, y0 + oy, 3, 6, C_TIRE);
    }
    fillRect(x0 + 1, y0, TRUCK_W - 2, 12, cab);
    fillRect(x0 + 2, y0 + 3, TRUCK_W - 4, 4, C_GLASS);
    fillRect(x0 + 2, y0, 2, 1, C_HEADLIGHT);
    fillRect(x0 + TRUCK_W - 4, y0, 2, 1, C_HEADLIGHT);
    fillRect(x0, y0 + 13, TRUCK_W, TRUCK_H - 13, C_CARGO_EDGE);
    fillRect(x0 + 1, y0 + 14, TRUCK_W - 2, TRUCK_H - 15, C_CARGO);
    fillRect(x0 + 1, y0 + TRUCK_H - 1, 3, 1, C_TAILLIGHT);
    fillRect(x0 + TRUCK_W - 4, y0 + TRUCK_H - 1, 3, 1, C_TAILLIGHT);
}

fn drawExplosion(cx: i32, cy: i32, age_ms: i32, w: i32, h: i32) void {
    fillRect(cx - @divTrunc(w, 2), cy - @divTrunc(h, 2), w, h, C_CHAR);
    if (age_ms < 400) {
        const r = 4 + @divTrunc(age_ms, 22);
        fillCircle(cx, cy, r, C_FIRE);
        fillCircle(cx, cy, r - 4, C_FIRE_HOT);
        if (age_ms < 200) fillCircle(cx, cy, r - 8, C_FIRE_CORE);
    } else {
        const r = @max(2, 20 - @divTrunc(age_ms - 400, 18));
        fillCircle(cx, cy - 2, r, C_SMOKE);
    }
}

fn drawSplash(cx: i32, cy: i32, age_ms: i32) void {
    const r = 4 + @divTrunc(age_ms, 40);
    ringCircle(cx, cy, r, C_SPLASH);
    if (r > 10) ringCircle(cx, cy, r - 8, C_WATER_LIGHT);
    if (age_ms < 300) fillCircle(cx, cy, 6, C_SPLASH);
}

fn drawHud() void {
    blendRect(0, 0, W, 24, C_HUD);
    drawText(6, 3, 1, "SCORE", C_TEXT_DIM);
    drawNumber(6, 10, 2, score, 6, if (freeze_ms > 0) C_WARN else C_TEXT);
    drawText(66, 3, 1, "HI", C_TEXT_DIM);
    drawNumber(66, 10, 2, @max(hi_score, score), 6, C_TEXT);
    drawText(128, 3, 1, "MPH", C_TEXT_DIM);
    drawNumber(128, 10, 2, @intCast(@divTrunc(speed * 160, MAX_SPEED)), 3, C_TEXT);
    drawText(166, 3, 1, "OIL", C_TEXT_DIM);
    const oil_fill = @divTrunc((OIL_COOLDOWN_MS - @max(0, oil_ms)) * 24, OIL_COOLDOWN_MS);
    fillRect(166, 12, 24, 6, C_HUD);
    fillRect(166, 12, oil_fill, 6, if (oil_ms <= 0) C_GOOD else C_TEXT_DIM);

    var i: i32 = 0;
    while (i < lives) : (i += 1) {
        const x = W - 12 - i * 10;
        fillRect(x, 6, 6, 12, C_PLAYER);
        fillRect(x + 1, 8, 4, 2, C_GLASS);
        fillRect(x + 2, 6, 2, 12, C_PLAYER_STRIPE);
    }

    if (free_ms > 0 and mode != .title) {
        blendRect(6, 28, 98, 12, C_HUD);
        drawText(9, 32, 1, "FREE CARS", C_GOOD);
        fillRect(48, 32, @divTrunc(free_ms * 52, FREE_CAR_MS), 5, C_GOOD);
    }
    if (freeze_ms > 0 and @mod(@divTrunc(freeze_ms, 250), 2) == 0) {
        drawTextCentered(48, 2, "CIVILIAN HIT", C_WARN);
        drawTextCentered(62, 1, "NO SCORE", C_WARN);
    } else if (message_ms > 0) {
        drawTextCentered(48, 2, "EXTRA CAR", C_GOOD);
    }
}

fn drawTitle() void {
    blendRect(0, 0, W, H, C_SHADE);
    drawTextCentered(96, 6, "HIGHWAY", C_TITLE);
    drawTextCentered(138, 6, "CHASE", C_TITLE_ALT);
    drawTextCentered(200, 2, "UP GAS   DOWN BRAKE", C_TEXT);
    drawTextCentered(216, 2, "LEFT RIGHT STEER", C_TEXT);
    drawTextCentered(232, 2, "SPACE FIRE   X OIL", C_TEXT);
    drawTextCentered(248, 2, "P PAUSE   R RESTART", C_TEXT);
    drawTextCentered(280, 2, "RAM ENEMIES OFF THE ROAD", C_TEXT_DIM);
    drawTextCentered(296, 2, "DO NOT HIT CIVILIANS", C_TEXT_DIM);
    drawTextCentered(340, 2, "PRESS SPACE TO START", C_TITLE_ALT);
}

fn drawPaused() void {
    blendRect(0, 0, W, H, C_SHADE);
    drawTextCentered(200, 4, "PAUSED", C_TEXT);
    drawTextCentered(240, 2, "P TO RESUME", C_TEXT_DIM);
}

fn drawGameOver() void {
    blendRect(0, 0, W, H, C_SHADE);
    drawTextCentered(180, 5, "GAME OVER", C_TITLE);
    drawTextCentered(232, 2, if (score >= hi_score and score > 0) "NEW HIGH SCORE" else "FINAL SCORE", C_TEXT_DIM);
    var buf: [10]u8 = undefined;
    drawTextCentered(250, 3, formatNumber(&buf, score, 6), C_TEXT);
    drawTextCentered(300, 2, "PRESS SPACE TO DRIVE", C_TITLE_ALT);
}

// Pixel primitives

fn fillSpan(y: i32, x0: i32, x1: i32, c: Color) void {
    if (y < 0 or y >= H) return;
    const a: usize = @intCast(std.math.clamp(x0, 0, W));
    const b: usize = @intCast(std.math.clamp(x1, 0, W));
    if (a >= b) return;
    const base = ktx.HEADER_SIZE + @as(usize, @intCast(y)) * SCREEN_W * 4;
    var x = a;
    while (x < b) : (x += 1) {
        @memcpy(output_buf[base + x * 4 ..][0..4], &c);
    }
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    var yy = @max(y, 0);
    const y1 = @min(y + h, H);
    while (yy < y1) : (yy += 1) fillSpan(yy, x, x + w, c);
}

fn blendRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    const x0: usize = @intCast(std.math.clamp(x, 0, W));
    const x1: usize = @intCast(std.math.clamp(x + w, 0, W));
    const y0: usize = @intCast(std.math.clamp(y, 0, H));
    const y1: usize = @intCast(std.math.clamp(y + h, 0, H));
    const alpha: u32 = c[3];
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const idx = ktx.HEADER_SIZE + (yy * SCREEN_W + xx) * 4;
            for (0..3) |ch| {
                const dst: u32 = output_buf[idx + ch];
                output_buf[idx + ch] = @intCast((dst * (255 - alpha) + @as(u32, c[ch]) * alpha + 127) / 255);
            }
        }
    }
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    if (r <= 0) return;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = 0;
        while ((dx + 1) * (dx + 1) + dy * dy <= r * r) dx += 1;
        fillSpan(cy + dy, cx - dx, cx + dx + 1, c);
    }
}

fn ringCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = 0;
        while ((dx + 1) * (dx + 1) + dy * dy <= r * r) dx += 1;
        fillSpan(cy + dy, cx - dx, cx - dx + 2, c);
        fillSpan(cy + dy, cx + dx - 1, cx + dx + 1, c);
    }
}

// 3x5 bitmap font: five rows of three bits, top row in the high bits.
fn glyph(ch: u8) u15 {
    return switch (ch) {
        '0' => 0b111_101_101_101_111,
        '1' => 0b010_110_010_010_111,
        '2' => 0b111_001_111_100_111,
        '3' => 0b111_001_111_001_111,
        '4' => 0b101_101_111_001_001,
        '5' => 0b111_100_111_001_111,
        '6' => 0b111_100_111_101_111,
        '7' => 0b111_001_010_010_010,
        '8' => 0b111_101_111_101_111,
        '9' => 0b111_101_111_001_111,
        'A' => 0b010_101_111_101_101,
        'B' => 0b110_101_110_101_110,
        'C' => 0b011_100_100_100_011,
        'D' => 0b110_101_101_101_110,
        'E' => 0b111_100_110_100_111,
        'F' => 0b111_100_110_100_100,
        'G' => 0b011_100_101_101_011,
        'H' => 0b101_101_111_101_101,
        'I' => 0b111_010_010_010_111,
        'J' => 0b001_001_001_101_010,
        'K' => 0b101_101_110_101_101,
        'L' => 0b100_100_100_100_111,
        'M' => 0b101_111_111_101_101,
        'N' => 0b110_101_101_101_101,
        'O' => 0b010_101_101_101_010,
        'P' => 0b110_101_110_100_100,
        'Q' => 0b010_101_101_110_011,
        'R' => 0b110_101_110_101_101,
        'S' => 0b011_100_010_001_110,
        'T' => 0b111_010_010_010_010,
        'U' => 0b101_101_101_101_111,
        'V' => 0b101_101_101_101_010,
        'W' => 0b101_101_111_111_101,
        'X' => 0b101_101_010_101_101,
        'Y' => 0b101_101_010_010_010,
        'Z' => 0b111_001_010_100_111,
        '-' => 0b000_000_111_000_000,
        else => 0,
    };
}

fn drawText(x: i32, y: i32, scale: i32, text: []const u8, c: Color) void {
    if (scale > 1) drawTextRaw(x + 1, y + 1, scale, text, C_TEXT_SHADOW);
    drawTextRaw(x, y, scale, text, c);
}

fn drawTextRaw(x: i32, y: i32, scale: i32, text: []const u8, c: Color) void {
    var cx = x;
    for (text) |ch| {
        const bits = glyph(ch);
        var row: u4 = 0;
        while (row < 5) : (row += 1) {
            var col: u4 = 0;
            while (col < 3) : (col += 1) {
                const shift: u4 = 14 - (row * 3 + col);
                if (((bits >> shift) & 1) != 0) {
                    fillRect(cx + @as(i32, col) * scale, y + @as(i32, row) * scale, scale, scale, c);
                }
            }
        }
        cx += 4 * scale;
    }
}

fn drawTextCentered(y: i32, scale: i32, text: []const u8, c: Color) void {
    const width = @as(i32, @intCast(text.len)) * 4 * scale - scale;
    drawText(@divTrunc(W - width, 2), y, scale, text, c);
}

fn formatNumber(buf: *[10]u8, value: u32, min_digits: usize) []const u8 {
    var v = value;
    var n: usize = 0;
    while (n < buf.len and (v > 0 or n < min_digits)) : (n += 1) {
        buf[buf.len - 1 - n] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[buf.len - n ..];
}

fn drawNumber(x: i32, y: i32, scale: i32, value: u32, min_digits: usize, c: Color) void {
    var buf: [10]u8 = undefined;
    drawText(x, y, scale, formatNumber(&buf, value, min_digits), c);
}

// Tests

fn resetForTest() void {
    phase = .initializing;
    begun_at_ms = 0;
    committed_at_ms = 0;
    time_advanced = false;
    last_step_ms = 0;
    keys_down = 0;
    hi_score = 0;
    rng_state = 0x6C8E9CF5;
}

fn runUpdate(at_ms: i64) i64 {
    begin_update_at(at_ms);
    return finish_update();
}

fn startForTest() i64 {
    resetForTest();
    _ = renderImpl(0);
    begin_update_at(1);
    _ = key_event(' ', FLAG_KEY_DOWN);
    _ = key_event(' ', 0);
    _ = finish_update();
    // Keep tests free of random traffic.
    spawn_gap_px = 1 << 20;
    rammer_ms = 1 << 30;
    return 1;
}

fn holdKey(at_ms: i64, key: i32) void {
    begin_update_at(at_ms);
    _ = key_event(key, FLAG_KEY_DOWN);
    _ = finish_update();
}

test "title waits without wakes, then fixed steps run before events" {
    resetForTest();
    try std.testing.expectEqual(@as(u32, OUTPUT_BYTES), renderImpl(0));
    try std.testing.expectEqual(Mode.title, mode);
    try std.testing.expectEqual(@as(i64, 1), runUpdate(1));

    begin_update_at(2);
    try std.testing.expectEqual(@as(i32, 1), key_event(' ', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i64, 18), finish_update());
    try std.testing.expectEqual(Mode.playing, mode);

    begin_update_at(18);
    try std.testing.expectEqual(@as(i32, 1), key_event(XK_UP, FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), key_event(XK_UP, FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i64, 34), finish_update());
    try std.testing.expectEqual(@as(i32, 0), speed);

    try std.testing.expectEqual(@as(i64, 50), runUpdate(34));
    try std.testing.expectEqual(ACCEL, speed);
}

test "updates keep the published frame until a separate render" {
    var t = startForTest();
    try std.testing.expectEqual(@as(u32, OUTPUT_BYTES), renderImpl(0));
    const before = std.hash.Wyhash.hash(0, &output_buf);
    t += 16;
    holdKey(t, XK_UP);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expect(distPx() > 0);
    try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, &output_buf));
    _ = renderImpl(0);
    try std.testing.expect(before != std.hash.Wyhash.hash(0, &output_buf));
}

test "pause stops the clock and resume does not replay paused time" {
    var t = startForTest();
    t += 16;
    begin_update_at(t);
    try std.testing.expectEqual(@as(i32, 1), key_event('p', FLAG_KEY_DOWN));
    try std.testing.expectEqual(t, finish_update());
    try std.testing.expectEqual(Mode.paused, mode);

    begin_update_at(60_000);
    try std.testing.expectEqual(@as(i32, 1), key_event('p', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i64, 60_016), finish_update());
    try std.testing.expectEqual(FREE_CAR_MS - STEP, free_ms);
}

test "leaving the road crashes, and the free-car timer keeps lives" {
    var t = startForTest();
    player_x = 4 * FP;
    t += 16;
    _ = runUpdate(t);
    try std.testing.expect(crash_ms > 0);
    try std.testing.expect(!crash_water);

    var i: usize = 0;
    while (crash_ms > 0 and i < 200) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(START_LIVES, lives);
    try std.testing.expect(invuln_ms > 0);

    free_ms = 0;
    player_x = (W - 4) * FP;
    t += 16;
    _ = runUpdate(t);
    try std.testing.expect(crash_ms > 0);
    i = 0;
    while (crash_ms > 0 and i < 200) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(START_LIVES - 1, lives);
}

test "losing the last car ends the game and keeps the high score" {
    var t = startForTest();
    free_ms = 0;
    lives = 1;
    score = 1234;
    player_x = 4 * FP;
    var i: usize = 0;
    while (mode == .playing and i < 200) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(Mode.game_over, mode);
    try std.testing.expectEqual(@as(u32, 1234), hi_score);
    t += 16;
    try std.testing.expectEqual(t, runUpdate(t));

    begin_update_at(t + 16);
    try std.testing.expectEqual(@as(i32, 1), key_event(XK_ENTER, FLAG_KEY_DOWN));
    _ = finish_update();
    try std.testing.expectEqual(Mode.playing, mode);
    try std.testing.expectEqual(@as(u32, 0), score);
    try std.testing.expectEqual(@as(u32, 1234), hi_score);
}

fn placeCarAhead(kind: Kind, ahead_px: i32) *Car {
    cars[0] = .{
        .state = .driving,
        .kind = kind,
        .x = player_x,
        .y = dist + ahead_px * FP,
        .vy = 0,
        .lane = 1,
        .hp = if (kind == .rammer) 3 else 1,
        .timer = 5000,
    };
    return &cars[0];
}

test "guns destroy an enemy for points" {
    var t = startForTest();
    const car = placeCarAhead(.weaver, 80);
    t += 16;
    holdKey(t, ' ');
    var i: usize = 0;
    while (car.state == .driving and i < 40) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(CarState.wrecked, car.state);
    try std.testing.expectEqual(@as(u32, 150), score);
    try std.testing.expectEqual(@as(i32, 0), freeze_ms);
}

test "shooting a civilian freezes the score" {
    var t = startForTest();
    const car = placeCarAhead(.sedan, 80);
    t += 16;
    holdKey(t, ' ');
    var i: usize = 0;
    while (car.state == .driving and i < 40) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(CarState.wrecked, car.state);
    try std.testing.expect(freeze_ms > 0);

    t += 16;
    holdKey(t, XK_UP);
    i = 0;
    while (i < 60) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(@as(u32, 0), score);
}

test "oil spins out a car that drives over it" {
    var t = startForTest();
    t += 16;
    begin_update_at(t);
    try std.testing.expectEqual(@as(i32, 1), key_event('x', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), key_event('x', 0));
    try std.testing.expectEqual(@as(i32, 0), key_event('x', FLAG_KEY_DOWN));
    _ = finish_update();

    const car = &cars[0];
    car.* = .{ .state = .driving, .kind = .sedan, .x = oils[0].x, .y = oils[0].y - 40 * FP, .vy = 600, .lane = 1, .hp = 1 };
    var i: usize = 0;
    while (car.state == .driving and i < 40) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(CarState.spinning, car.state);
}

test "a rammer alongside shoves the player sideways" {
    var t = startForTest();
    const start_x = player_x;
    cars[0] = .{ .state = .driving, .kind = .rammer, .x = player_x + (CAR_W + 4) * FP, .y = dist, .vy = 0, .hp = 3, .phase = 1, .side = 1, .timer = 2000 };
    var i: usize = 0;
    while (player_x > start_x - 6 * FP and crash_ms == 0 and i < 60) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expect(player_x <= start_x - 6 * FP or crash_ms > 0);
}

test "late updates run at most eight steps" {
    _ = startForTest();
    try std.testing.expectEqual(@as(i64, 10_016), runUpdate(10_000));
    try std.testing.expectEqual(@as(i64, 10_000), last_step_ms);
    try std.testing.expectEqual(STEP * MAX_STEPS_PER_UPDATE, FREE_CAR_MS - free_ms);
}

test "the largest update time does not overflow the wake" {
    resetForTest();
    _ = renderImpl(0);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), runUpdate(std.math.maxInt(i64)));

    _ = startForTest();
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), runUpdate(std.math.maxInt(i64)));
}

test "generated road keeps two lanes, forks, and bridges inside the screen" {
    resetForTest();
    _ = renderImpl(0);
    var forks: usize = 0;
    var bridges: usize = 0;
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        generateRow();
        const row = rowAt(gen_row - 1);
        try std.testing.expect(row.l - SHOULDER_PX >= 0);
        try std.testing.expect(row.r + SHOULDER_PX <= W);
        if (row.ml < row.mr) {
            try std.testing.expect(!row.water);
            try std.testing.expect(row.ml - row.l >= LANE_MIN_PX);
            try std.testing.expect(row.r - row.mr >= LANE_MIN_PX);
            if (row.mr - row.ml > 2 * SHOULDER_PX) forks += 1;
        } else {
            try std.testing.expect(row.r - row.l >= 2 * 44);
        }
        if (row.water) bridges += 1;
    }
    try std.testing.expect(forks > 0);
    try std.testing.expect(bridges > 0);
}

test "rebasing world coordinates keeps the road under the player" {
    _ = startForTest();
    dist = (REBASE_PX - 1) * FP;
    ensureRows();
    const before = rowAt(@divFloor(distPx() + 40, ROW_PX));
    const t: i64 = 17;
    keys_down = KEY_GAS;
    speed = MAX_SPEED;
    player_x = laneCenterPx(rowAt(@divFloor(distPx(), ROW_PX)), 1) * FP;
    _ = runUpdate(t);
    try std.testing.expect(distPx() < REBASE_PX - REBASE_SHIFT_PX + 16);
    const after = rowAt(@divFloor(distPx() + 40 - @divTrunc(MAX_SPEED, FP), ROW_PX));
    try std.testing.expectEqual(before.l, after.l);
    try std.testing.expectEqual(before.r, after.r);
}
