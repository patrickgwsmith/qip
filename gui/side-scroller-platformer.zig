const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const SCREEN_W: usize = 480;
const SCREEN_H: usize = 270;
const TILE: i32 = 16;
const WORLD_W: usize = 220;
const WORLD_H: usize = 18;
const PIXEL_BYTES: usize = SCREEN_W * SCREEN_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_ENTER: i32 = 0xFF0D;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const KEY_LEFT: u8 = 1 << 0;
const KEY_RIGHT: u8 = 1 << 1;
const KEY_JUMP: u8 = 1 << 2;
const KEY_FIRE: u8 = 1 << 3;

const STEP_MS: i64 = 16;
const MAX_STEPS_PER_TICK: i32 = 8;

const FP: i32 = 256;
const GRAVITY: i32 = 70;
const MAX_FALL: i32 = 900;
const RUN_ACCEL: i32 = 80;
const RUN_DRAG: i32 = 55;
const MAX_RUN: i32 = 620;
const JUMP_VEL: i32 = -1360;
const STOMP_BOUNCE: i32 = -880;

const PLAYER_W: i32 = 12;
const PLAYER_H: i32 = 15;
const ENEMY_W: i32 = 13;
const ENEMY_H: i32 = 12;
const MAX_ENEMIES: usize = 22;
const MAX_FLAMES: usize = 4;

const POWERUP_TILE_X: i32 = 52;
const POWERUP_TILE_Y: i32 = 12;
const POWERUP_W: i32 = 12;
const POWERUP_H: i32 = 12;
const FLAME_SIZE: i32 = 7;
const FLAME_SPEED: i32 = 760;
const FLAME_BOUNCE: i32 = -520;
const FLAME_GRAVITY: i32 = 45;

const Tile = enum(u8) {
    air = 0,
    ground = 1,
    brick = 2,
    block = 3,
    goal = 4,
};

const Enemy = struct {
    x: i32,
    y: i32,
    vx: i32,
    alive: bool,
};

const Flame = struct {
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    alive: bool,
};

const Color = [4]u8;
const C_SKY: Color = .{ 0x8D, 0xD6, 0xF7, 0xFF };
const C_SKY_LOW: Color = .{ 0xBF, 0xEC, 0xFF, 0xFF };
const C_CLOUD: Color = .{ 0xF7, 0xFF, 0xFF, 0xFF };
const C_HILL: Color = .{ 0x63, 0xB5, 0x71, 0xFF };
const C_HILL_DARK: Color = .{ 0x42, 0x8C, 0x5A, 0xFF };
const C_DIRT: Color = .{ 0x9B, 0x67, 0x37, 0xFF };
const C_DIRT_DARK: Color = .{ 0x6D, 0x43, 0x25, 0xFF };
const C_GRASS: Color = .{ 0x36, 0xB2, 0x54, 0xFF };
const C_BRICK: Color = .{ 0xB5, 0x4C, 0x35, 0xFF };
const C_BRICK_DARK: Color = .{ 0x74, 0x2C, 0x28, 0xFF };
const C_BLOCK: Color = .{ 0xE0, 0xA6, 0x3A, 0xFF };
const C_BLOCK_DARK: Color = .{ 0x9C, 0x66, 0x25, 0xFF };
const C_PLAYER: Color = .{ 0x2B, 0x66, 0xD9, 0xFF };
const C_PLAYER_DARK: Color = .{ 0x16, 0x35, 0x7E, 0xFF };
const C_PLAYER_FACE: Color = .{ 0xFF, 0xD0, 0x89, 0xFF };
const C_ENEMY: Color = .{ 0x7C, 0x47, 0x2B, 0xFF };
const C_ENEMY_DARK: Color = .{ 0x3F, 0x23, 0x19, 0xFF };
const C_POWER: Color = .{ 0xFF, 0xF0, 0x70, 0xFF };
const C_POWER_DARK: Color = .{ 0xF2, 0x6B, 0x2D, 0xFF };
const C_FLAME: Color = .{ 0xFF, 0x7A, 0x18, 0xFF };
const C_FLAME_HOT: Color = .{ 0xFF, 0xE0, 0x4E, 0xFF };
const C_FLAME_DARK: Color = .{ 0xD8, 0x32, 0x16, 0xFF };
const C_GOAL: Color = .{ 0xF4, 0xE8, 0x5A, 0xFF };
const C_GOAL_DARK: Color = .{ 0x4B, 0x63, 0x49, 0xFF };
const C_TEXT: Color = .{ 0x1D, 0x27, 0x37, 0xFF };
const C_OVERLAY: Color = .{ 0x08, 0x12, 0x20, 0xAA };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var tiles: [WORLD_H][WORLD_W]Tile = [_][WORLD_W]Tile{[_]Tile{.air} ** WORLD_W} ** WORLD_H;
var enemies: [MAX_ENEMIES]Enemy = undefined;
var flames: [MAX_FLAMES]Flame = [_]Flame{.{ .x = 0, .y = 0, .vx = 0, .vy = 0, .alive = false }} ** MAX_FLAMES;
var enemy_count: usize = 0;

var player_x: i32 = 0;
var player_y: i32 = 0;
var player_vx: i32 = 0;
var player_vy: i32 = 0;
var facing_dir: i32 = 1;
var on_ground: bool = false;
var jump_was_down: bool = false;
var fire_was_down: bool = false;
var keys_down: u8 = 0;
var initialized: bool = false;
var game_over: bool = false;
var won: bool = false;
var powerup_spawned: bool = false;
var powerup_collected: bool = false;
var powerup_x: i32 = 0;
var powerup_y: i32 = 0;
var powerup_vy: i32 = 0;
var has_last_step: bool = false;
var last_step_ms: i64 = 0;
var camera_x: i32 = 0;
const Phase = enum { initializing, ready, updating };
var update_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;

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
    if (update_phase != .ready or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    update_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;

    if (is_down and (x11_key == 'r' or x11_key == 'R' or x11_key == XK_ENTER)) {
        resetGameAt(begun_at_ms);
        return 1;
    }

    const bit: u8 = switch (x11_key) {
        XK_LEFT, 'a', 'A' => KEY_LEFT,
        XK_RIGHT, 'd', 'D' => KEY_RIGHT,
        XK_UP, 'w', 'W', 0x20 => KEY_JUMP,
        'z', 'Z', 'x', 'X' => KEY_FIRE,
        else => return 0,
    };

    if (is_down) {
        keys_down |= bit;
    } else {
        keys_down &= ~bit;
    }
    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    return 0;
}

fn requireEventPhase() void {
    if (update_phase != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (game_over or won) return;

    if (!has_last_step) {
        has_last_step = true;
        last_step_ms = begun_at_ms;
    }

    var elapsed = begun_at_ms - last_step_ms;
    if (elapsed < 0) elapsed = 0;

    var steps: i32 = 0;
    while (elapsed >= STEP_MS and steps < MAX_STEPS_PER_TICK and !game_over and !won) : (steps += 1) {
        stepGame();
        last_step_ms += STEP_MS;
        elapsed -= STEP_MS;
    }
    if (!game_over and !won and elapsed >= STEP_MS) {
        last_step_ms = begun_at_ms;
    }
}

export fn finish_update() i64 {
    if (update_phase != .updating) @trap();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    const wake = if (game_over or won) begun_at_ms else last_step_ms +| STEP_MS;
    update_phase = .ready;
    return wake;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (update_phase != .initializing and update_phase != .ready) @trap();
    if (update_phase == .initializing) resetGameAt(0);
    _ = ktx.writeHeader(&output_buf, SCREEN_W, SCREEN_H) orelse @trap();
    drawFrame();
    update_phase = .ready;
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

export fn test_player_tile_x() i32 {
    if (!initialized) resetGame();
    return @divFloor(fpToPx(player_x), TILE);
}

export fn test_player_tile_y() i32 {
    if (!initialized) resetGame();
    return @divFloor(fpToPx(player_y), TILE);
}

export fn test_game_over() i32 {
    return if (game_over) 1 else 0;
}

export fn test_won() i32 {
    return if (won) 1 else 0;
}

export fn test_has_flames() i32 {
    return if (powerup_collected) 1 else 0;
}

fn resetGame() void {
    initialized = true;
    game_over = false;
    won = false;
    has_last_step = false;
    keys_down = 0;
    jump_was_down = false;
    fire_was_down = false;
    player_x = 3 * TILE * FP;
    player_y = 9 * TILE * FP;
    player_vx = 0;
    player_vy = 0;
    facing_dir = 1;
    on_ground = false;
    camera_x = 0;
    powerup_spawned = false;
    powerup_collected = false;
    powerup_x = 0;
    powerup_y = 0;
    powerup_vy = 0;
    flames = [_]Flame{.{ .x = 0, .y = 0, .vx = 0, .vy = 0, .alive = false }} ** MAX_FLAMES;
    buildLevel();
}

fn resetGameAt(now_ms: i64) void {
    resetGame();
    has_last_step = true;
    last_step_ms = now_ms;
}

fn buildLevel() void {
    tiles = [_][WORLD_W]Tile{[_]Tile{.air} ** WORLD_W} ** WORLD_H;
    enemy_count = 0;

    var x: usize = 0;
    while (x < WORLD_W) : (x += 1) {
        if (isGapColumn(x)) continue;
        tiles[15][x] = .ground;
        tiles[16][x] = .ground;
        tiles[17][x] = .ground;
    }

    addPlatform(14, 10, 14, .ground);
    addPlatform(25, 11, 9, .brick);
    addPlatform(42, 10, 7, .ground);
    addPlatform(58, 12, 13, .ground);
    addPlatform(78, 9, 7, .brick);
    addPlatform(92, 11, 11, .ground);
    addPlatform(116, 10, 8, .brick);
    addPlatform(134, 12, 10, .ground);
    addPlatform(158, 9, 7, .brick);
    addPlatform(178, 11, 12, .ground);

    addBrickRun(18, 9, 5);
    addBrickRun(32, 8, 4);
    addBrickRun(68, 8, 5);
    addBrickRun(106, 7, 4);
    addBrickRun(146, 8, 5);
    addBrickRun(198, 9, 5);

    setTile(POWERUP_TILE_X, POWERUP_TILE_Y, .block);
    setTile(52, 13, .block);
    setTile(53, 13, .block);
    setTile(54, 13, .block);
    setTile(88, 14, .block);
    setTile(89, 14, .block);
    setTile(126, 13, .block);
    setTile(127, 13, .block);
    setTile(128, 13, .block);

    addEnemy(21, 14, -1);
    addEnemy(38, 14, -1);
    addEnemy(63, 11, 1);
    addEnemy(82, 14, -1);
    addEnemy(98, 10, 1);
    addEnemy(121, 14, -1);
    addEnemy(139, 11, 1);
    addEnemy(166, 14, -1);
    addEnemy(184, 10, -1);
    addEnemy(203, 14, -1);

    setTile(WORLD_W - 7, 14, .goal);
    setTile(WORLD_W - 7, 13, .goal);
    setTile(WORLD_W - 7, 12, .goal);
}

fn isGapColumn(x: usize) bool {
    return (x >= 34 and x <= 37) or
        (x >= 72 and x <= 76) or
        (x >= 108 and x <= 112) or
        (x >= 150 and x <= 154) or
        (x >= 193 and x <= 197);
}

fn addPlatform(start_x: usize, y: usize, len: usize, t: Tile) void {
    var i: usize = 0;
    while (i < len) : (i += 1) setTile(@intCast(start_x + i), @intCast(y), t);
}

fn addBrickRun(start_x: i32, y: i32, len: i32) void {
    var i: i32 = 0;
    while (i < len) : (i += 1) setTile(start_x + i, y, .brick);
}

fn addEnemy(tx: i32, ty: i32, dir: i32) void {
    if (enemy_count >= MAX_ENEMIES) return;
    enemies[enemy_count] = .{
        .x = tx * TILE * FP + 2 * FP,
        .y = ty * TILE * FP + 4 * FP,
        .vx = dir * 105,
        .alive = true,
    };
    enemy_count += 1;
}

fn stepGame() void {
    applyPlayerInput();
    movePlayerAxis(true);
    movePlayerAxis(false);
    updatePowerup();
    updateFlames();
    updateEnemies();
    handleFlameContacts();
    handleEnemyContacts();
    updateCamera();

    if (player_y > @as(i32, @intCast(SCREEN_H + TILE * 4)) * FP) {
        game_over = true;
    }

    const goal_px = @as(i32, @intCast(WORLD_W - 8)) * TILE;
    if (fpToPx(player_x) >= goal_px) {
        won = true;
    }
}

fn applyPlayerInput() void {
    const left = (keys_down & KEY_LEFT) != 0;
    const right = (keys_down & KEY_RIGHT) != 0;
    const jump = (keys_down & KEY_JUMP) != 0;
    const fire = (keys_down & KEY_FIRE) != 0;

    if (left and !right) {
        player_vx -= RUN_ACCEL;
        facing_dir = -1;
    } else if (right and !left) {
        player_vx += RUN_ACCEL;
        facing_dir = 1;
    } else {
        if (player_vx > 0) player_vx = @max(0, player_vx - RUN_DRAG);
        if (player_vx < 0) player_vx = @min(0, player_vx + RUN_DRAG);
    }

    player_vx = clampI32(player_vx, -MAX_RUN, MAX_RUN);

    if (jump and !jump_was_down and on_ground) {
        player_vy = JUMP_VEL;
        on_ground = false;
    }
    jump_was_down = jump;

    if (fire and !fire_was_down and powerup_collected) {
        spawnFlame();
    }
    fire_was_down = fire;

    player_vy = @min(player_vy + GRAVITY, MAX_FALL);
}

fn movePlayerAxis(comptime horizontal: bool) void {
    if (horizontal) {
        player_x += player_vx;
        if (player_vx > 0 and rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) {
            if (hitSpecialBlockInRect(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP) and !rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) return;
            player_x = (rightTile(player_x, PLAYER_W * FP) * TILE - PLAYER_W) * FP;
            player_vx = 0;
        } else if (player_vx < 0 and rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) {
            if (hitSpecialBlockInRect(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP) and !rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) return;
            player_x = (leftTile(player_x) + 1) * TILE * FP;
            player_vx = 0;
        }
    } else {
        player_y += player_vy;
        on_ground = false;
        if (player_vy > 0 and rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) {
            if (hitSpecialBlockInRect(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP) and !rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) return;
            player_y = (bottomTile(player_y, PLAYER_H * FP) * TILE - PLAYER_H) * FP;
            player_vy = 0;
            on_ground = true;
        } else if (player_vy < 0 and rectHitsSolid(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP)) {
            smashHeadBlock();
            player_y = (topTile(player_y) + 1) * TILE * FP;
            player_vy = 0;
        }
    }
}

fn hitSpecialBlockInRect(x: i32, y: i32, w: i32, h: i32) bool {
    const tx0 = leftTile(x);
    const tx1 = rightTile(x, w);
    const ty0 = topTile(y);
    const ty1 = bottomTile(y, h);
    var ty = ty0;
    while (ty <= ty1) : (ty += 1) {
        var tx = tx0;
        while (tx <= tx1) : (tx += 1) {
            if (tx == POWERUP_TILE_X and ty == POWERUP_TILE_Y and tileAt(tx, ty) == .block and !powerup_spawned and !powerup_collected) {
                spawnPowerup(tx, ty);
                setTile(tx, ty, .air);
                return true;
            }
        }
    }
    return false;
}

fn updateEnemies() void {
    var i: usize = 0;
    while (i < enemy_count) : (i += 1) {
        if (!enemies[i].alive) continue;
        enemies[i].x += enemies[i].vx;
        if (rectHitsSolid(enemies[i].x, enemies[i].y, ENEMY_W * FP, ENEMY_H * FP)) {
            enemies[i].x -= enemies[i].vx;
            enemies[i].vx = -enemies[i].vx;
        }

        const edge_x = if (enemies[i].vx > 0) enemies[i].x + ENEMY_W * FP + FP else enemies[i].x - FP;
        const foot_y = enemies[i].y + (ENEMY_H + 2) * FP;
        if (!solidAtPx(fpToPx(edge_x), fpToPx(foot_y))) {
            enemies[i].vx = -enemies[i].vx;
        }
    }
}

fn updatePowerup() void {
    if (!powerup_spawned or powerup_collected) return;

    powerup_vy = @min(powerup_vy + GRAVITY, MAX_FALL);
    powerup_y += powerup_vy;

    if (powerup_vy > 0 and rectHitsSolid(powerup_x, powerup_y, POWERUP_W * FP, POWERUP_H * FP)) {
        powerup_y = (bottomTile(powerup_y, POWERUP_H * FP) * TILE - POWERUP_H) * FP;
        powerup_vy = 0;
    }

    if (rectOverlap(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP, powerup_x, powerup_y, POWERUP_W * FP, POWERUP_H * FP)) {
        powerup_collected = true;
    }
}

fn updateFlames() void {
    var i: usize = 0;
    while (i < MAX_FLAMES) : (i += 1) {
        if (!flames[i].alive) continue;

        flames[i].x += flames[i].vx;
        if (rectHitsSolid(flames[i].x, flames[i].y, FLAME_SIZE * FP, FLAME_SIZE * FP)) {
            flames[i].x -= flames[i].vx;
            flames[i].alive = false;
            continue;
        }

        flames[i].vy = @min(flames[i].vy + FLAME_GRAVITY, MAX_FALL);
        flames[i].y += flames[i].vy;
        if (flames[i].vy > 0 and rectHitsSolid(flames[i].x, flames[i].y, FLAME_SIZE * FP, FLAME_SIZE * FP)) {
            flames[i].y = (bottomTile(flames[i].y, FLAME_SIZE * FP) * TILE - FLAME_SIZE) * FP;
            flames[i].vy = FLAME_BOUNCE;
        } else if (flames[i].vy < 0 and rectHitsSolid(flames[i].x, flames[i].y, FLAME_SIZE * FP, FLAME_SIZE * FP)) {
            flames[i].y = (topTile(flames[i].y) + 1) * TILE * FP;
            flames[i].vy = 80;
        }

        const flame_px = fpToPx(flames[i].x);
        if (flame_px < camera_x - 64 or flame_px > camera_x + @as(i32, @intCast(SCREEN_W)) + 96 or fpToPx(flames[i].y) > @as(i32, @intCast(SCREEN_H)) + 48) {
            flames[i].alive = false;
        }
    }
}

fn handleFlameContacts() void {
    var f: usize = 0;
    while (f < MAX_FLAMES) : (f += 1) {
        if (!flames[f].alive) continue;
        var i: usize = 0;
        while (i < enemy_count) : (i += 1) {
            if (!enemies[i].alive) continue;
            if (!rectOverlap(flames[f].x, flames[f].y, FLAME_SIZE * FP, FLAME_SIZE * FP, enemies[i].x, enemies[i].y, ENEMY_W * FP, ENEMY_H * FP)) continue;
            flames[f].alive = false;
            enemies[i].alive = false;
            break;
        }
    }
}

fn handleEnemyContacts() void {
    var i: usize = 0;
    while (i < enemy_count) : (i += 1) {
        if (!enemies[i].alive) continue;
        if (!rectOverlap(player_x, player_y, PLAYER_W * FP, PLAYER_H * FP, enemies[i].x, enemies[i].y, ENEMY_W * FP, ENEMY_H * FP)) continue;

        const player_bottom = player_y + PLAYER_H * FP;
        const enemy_top = enemies[i].y;
        if (player_vy > 0 and player_bottom - enemy_top < 8 * FP) {
            enemies[i].alive = false;
            player_vy = STOMP_BOUNCE;
            on_ground = false;
        } else {
            game_over = true;
        }
    }
}

fn smashHeadBlock() void {
    const cx0 = leftTile(player_x + 2 * FP);
    const cx1 = rightTile(player_x + (PLAYER_W - 2) * FP, 0);
    const ty = topTile(player_y);
    var tx = cx0;
    while (tx <= cx1) : (tx += 1) {
        if (tileAt(tx, ty) == .brick or tileAt(tx, ty) == .block) {
            if (tx == POWERUP_TILE_X and ty == POWERUP_TILE_Y and !powerup_spawned and !powerup_collected) {
                spawnPowerup(tx, ty);
            }
            setTile(tx, ty, .air);
            return;
        }
    }
}

fn spawnPowerup(tx: i32, ty: i32) void {
    powerup_spawned = true;
    powerup_collected = true;
    powerup_x = tx * TILE * FP + 2 * FP;
    powerup_y = (ty - 1) * TILE * FP + 2 * FP;
    powerup_vy = -220;
}

fn spawnFlame() void {
    var slot: ?usize = null;
    var i: usize = 0;
    while (i < MAX_FLAMES) : (i += 1) {
        if (!flames[i].alive) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse 0;
    const dir: i32 = if (facing_dir < 0) -1 else 1;
    flames[idx] = .{
        .x = player_x + if (dir > 0) PLAYER_W * FP else -FLAME_SIZE * FP,
        .y = player_y + 5 * FP,
        .vx = dir * FLAME_SPEED,
        .vy = -160,
        .alive = true,
    };
}

fn rectHitsSolid(x: i32, y: i32, w: i32, h: i32) bool {
    const tx0 = leftTile(x);
    const tx1 = rightTile(x, w);
    const ty0 = topTile(y);
    const ty1 = bottomTile(y, h);
    var ty = ty0;
    while (ty <= ty1) : (ty += 1) {
        var tx = tx0;
        while (tx <= tx1) : (tx += 1) {
            if (isSolid(tileAt(tx, ty))) return true;
        }
    }
    return false;
}

fn solidAtPx(x: i32, y: i32) bool {
    return isSolid(tileAt(@divFloor(x, TILE), @divFloor(y, TILE)));
}

fn isSolid(t: Tile) bool {
    return t == .ground or t == .brick or t == .block;
}

fn tileAt(tx: i32, ty: i32) Tile {
    if (tx < 0 or ty < 0 or tx >= @as(i32, @intCast(WORLD_W)) or ty >= @as(i32, @intCast(WORLD_H))) return .air;
    return tiles[@intCast(ty)][@intCast(tx)];
}

fn setTile(tx: i32, ty: i32, t: Tile) void {
    if (tx < 0 or ty < 0 or tx >= @as(i32, @intCast(WORLD_W)) or ty >= @as(i32, @intCast(WORLD_H))) return;
    tiles[@intCast(ty)][@intCast(tx)] = t;
}

fn leftTile(x: i32) i32 {
    return @divFloor(fpToPx(x), TILE);
}

fn rightTile(x: i32, w: i32) i32 {
    return @divFloor(fpToPx(x + w - 1), TILE);
}

fn topTile(y: i32) i32 {
    return @divFloor(fpToPx(y), TILE);
}

fn bottomTile(y: i32, h: i32) i32 {
    return @divFloor(fpToPx(y + h - 1), TILE);
}

fn rectOverlap(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by;
}

fn updateCamera() void {
    const px = fpToPx(player_x);
    var target = px - @as(i32, @intCast(SCREEN_W / 2)) + 24;
    const max_camera = @as(i32, @intCast(WORLD_W)) * TILE - @as(i32, @intCast(SCREEN_W));
    target = clampI32(target, 0, max_camera);
    camera_x += @divTrunc(target - camera_x, 6);
}

fn drawFrame() void {
    drawSky();
    drawBackground();
    drawTiles();
    drawPowerup();
    drawFlames();
    drawEnemies();
    drawPlayer();
    drawHud();

    if (game_over) drawOverlay("TRY AGAIN  R");
    if (won) drawOverlay("COURSE CLEAR");
}

fn drawSky() void {
    var y: usize = 0;
    while (y < SCREEN_H) : (y += 1) {
        const c = if (y < SCREEN_H / 2) C_SKY else C_SKY_LOW;
        fillRect(0, @intCast(y), @intCast(SCREEN_W), 1, c);
    }
}

fn drawBackground() void {
    drawCloud(34 - @mod(@divFloor(camera_x, 5), 260), 30);
    drawCloud(190 - @mod(@divFloor(camera_x, 6), 300), 54);
    drawCloud(365 - @mod(@divFloor(camera_x, 4), 340), 24);

    drawHill(20 - @mod(@divFloor(camera_x, 3), 260), 195, 78);
    drawHill(180 - @mod(@divFloor(camera_x, 4), 300), 205, 58);
    drawHill(360 - @mod(@divFloor(camera_x, 3), 300), 198, 74);
}

fn drawCloud(x: i32, y: i32) void {
    var xx = x;
    while (xx < @as(i32, @intCast(SCREEN_W))) : (xx += 320) {
        fillRect(xx + 8, y + 8, 54, 13, C_CLOUD);
        fillRect(xx + 18, y, 20, 22, C_CLOUD);
        fillRect(xx + 40, y + 3, 24, 19, C_CLOUD);
    }
}

fn drawHill(x: i32, base_y: i32, h: i32) void {
    var xx = x;
    while (xx < @as(i32, @intCast(SCREEN_W))) : (xx += 300) {
        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const w = (h - row) * 2;
            fillRect(xx + h - @divTrunc(w, 2), base_y - row, w, 1, if (@mod(row, 4) == 0) C_HILL_DARK else C_HILL);
        }
    }
}

fn drawTiles() void {
    const first_tx = @max(0, @divFloor(camera_x, TILE) - 1);
    const last_tx = @min(@as(i32, @intCast(WORLD_W - 1)), @divFloor(camera_x + @as(i32, @intCast(SCREEN_W)), TILE) + 1);
    var ty: i32 = 0;
    while (ty < @as(i32, @intCast(WORLD_H))) : (ty += 1) {
        var tx = first_tx;
        while (tx <= last_tx) : (tx += 1) {
            const t = tileAt(tx, ty);
            if (t == .air) continue;
            drawTile((tx * TILE) - camera_x, ty * TILE, t);
        }
    }
}

fn drawTile(x: i32, y: i32, t: Tile) void {
    switch (t) {
        .air => {},
        .ground => {
            fillRect(x, y, TILE, TILE, C_DIRT);
            fillRect(x, y, TILE, 3, C_GRASS);
            fillRect(x + 1, y + 9, 14, 2, C_DIRT_DARK);
            fillRect(x + 7, y + 3, 2, 13, C_DIRT_DARK);
        },
        .brick => {
            fillRect(x, y, TILE, TILE, C_BRICK);
            fillRect(x, y + 7, TILE, 2, C_BRICK_DARK);
            fillRect(x + 7, y, 2, 7, C_BRICK_DARK);
            fillRect(x + 3, y + 9, 2, 7, C_BRICK_DARK);
            fillRect(x, y, TILE, 1, .{ 0xE0, 0x72, 0x4E, 0xFF });
        },
        .block => {
            fillRect(x, y, TILE, TILE, C_BLOCK);
            fillRect(x + 2, y + 2, TILE - 4, TILE - 4, .{ 0xF4, 0xC5, 0x56, 0xFF });
            fillRect(x, y + TILE - 3, TILE, 3, C_BLOCK_DARK);
            fillRect(x + 7, y + 4, 2, 7, C_BLOCK_DARK);
        },
        .goal => {
            fillRect(x + 6, y, 4, TILE, C_GOAL_DARK);
            fillRect(x + 10, y + 2, 10, 8, C_GOAL);
        },
    }
}

fn drawEnemies() void {
    var i: usize = 0;
    while (i < enemy_count) : (i += 1) {
        if (!enemies[i].alive) continue;
        const x = fpToPx(enemies[i].x) - camera_x;
        const y = fpToPx(enemies[i].y);
        if (x < -20 or x > @as(i32, @intCast(SCREEN_W)) + 20) continue;
        fillRect(x, y + 3, ENEMY_W, ENEMY_H - 3, C_ENEMY);
        fillRect(x + 1, y, ENEMY_W - 2, 5, C_ENEMY);
        fillRect(x + 3, y + 5, 2, 2, C_ENEMY_DARK);
        fillRect(x + 8, y + 5, 2, 2, C_ENEMY_DARK);
        fillRect(x + 1, y + ENEMY_H - 1, 4, 2, C_ENEMY_DARK);
        fillRect(x + 8, y + ENEMY_H - 1, 4, 2, C_ENEMY_DARK);
    }
}

fn drawPowerup() void {
    if (!powerup_spawned or powerup_collected) return;
    const x = fpToPx(powerup_x) - camera_x;
    const y = fpToPx(powerup_y);
    if (x < -20 or x > @as(i32, @intCast(SCREEN_W)) + 20) return;
    fillRect(x + 2, y, 8, 12, C_POWER_DARK);
    fillRect(x, y + 2, 12, 8, C_POWER);
    fillRect(x + 4, y + 3, 4, 6, C_FLAME_HOT);
    fillRect(x + 5, y + 1, 2, 3, C_FLAME);
}

fn drawFlames() void {
    var i: usize = 0;
    while (i < MAX_FLAMES) : (i += 1) {
        if (!flames[i].alive) continue;
        const x = fpToPx(flames[i].x) - camera_x;
        const y = fpToPx(flames[i].y);
        if (x < -20 or x > @as(i32, @intCast(SCREEN_W)) + 20) continue;
        fillRect(x + 1, y + 1, FLAME_SIZE - 2, FLAME_SIZE - 1, C_FLAME);
        fillRect(x + 2, y + 2, FLAME_SIZE - 4, FLAME_SIZE - 3, C_FLAME_HOT);
        fillRect(x, y + 4, 2, 2, C_FLAME_DARK);
        fillRect(x + FLAME_SIZE - 2, y + 1, 2, 2, C_FLAME_DARK);
    }
}

fn drawPlayer() void {
    const x = fpToPx(player_x) - camera_x;
    const y = fpToPx(player_y);
    const body = if (powerup_collected) C_POWER_DARK else C_PLAYER;
    const body_dark = if (powerup_collected) C_FLAME_DARK else C_PLAYER_DARK;
    fillRect(x + 2, y, 8, 5, C_PLAYER_FACE);
    fillRect(x + 1, y + 5, PLAYER_W - 2, 7, body);
    fillRect(x, y + 12, 5, 3, body_dark);
    fillRect(x + 7, y + 12, 5, 3, body_dark);
    fillRect(x + 7, y + 2, 2, 2, C_TEXT);
}

fn drawHud() void {
    drawText(8, 8, if (powerup_collected) "Z/X FLAMES  SPACE JUMP  R RESET" else "SMASH BRICK 32  Z/X AFTER POWER", C_TEXT, 1);
}

fn drawOverlay(text: []const u8) void {
    fillRect(0, 0, @intCast(SCREEN_W), @intCast(SCREEN_H), C_OVERLAY);
    const panel_w: i32 = 188;
    const panel_h: i32 = 54;
    const x = @divTrunc(@as(i32, @intCast(SCREEN_W)) - panel_w, 2);
    const y = @divTrunc(@as(i32, @intCast(SCREEN_H)) - panel_h, 2);
    fillRect(x, y, panel_w, panel_h, .{ 0xF7, 0xFA, 0xF5, 0xFF });
    fillRect(x, y, panel_w, 4, C_GRASS);
    drawText(x + 18, y + 22, text, C_TEXT, 2);
}

fn drawText(x: i32, y: i32, text: []const u8, color: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawChar(x + @as(i32, @intCast(i)) * 6 * scale, y, text[i], color, scale);
    }
}

fn drawChar(x: i32, y: i32, ch: u8, color: Color, scale: i32) void {
    const rows = glyph(ch);
    var row: i32 = 0;
    while (row < 7) : (row += 1) {
        var col: i32 = 0;
        while (col < 5) : (col += 1) {
            if (((rows[@intCast(row)] >> @intCast(4 - col)) & 1) != 0) {
                fillRect(x + col * scale, y + row * scale, scale, scale, color);
            }
        }
    }
}

fn glyph(ch_in: u8) [7]u8 {
    const ch = if (ch_in >= 'a' and ch_in <= 'z') ch_in - 32 else ch_in;
    return switch (ch) {
        'A' => .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'C' => .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
        'D' => .{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E },
        'E' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
        'G' => .{ 0x0E, 0x11, 0x10, 0x13, 0x11, 0x11, 0x0F },
        'I' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F },
        'J' => .{ 0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0C },
        'L' => .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
        'M' => .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
        'O' => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'P' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
        'R' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
        'S' => .{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E },
        'T' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'V' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'W' => .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A },
        'Y' => .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
        '/' => .{ 0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => .{ 0x1F, 0x11, 0x02, 0x04, 0x04, 0, 0x04 },
    };
}

fn fillRect(x0: i32, y0: i32, w0: i32, h0: i32, color: Color) void {
    const x_start = clampI32(x0, 0, @as(i32, @intCast(SCREEN_W)));
    const y_start = clampI32(y0, 0, @as(i32, @intCast(SCREEN_H)));
    const x_end = clampI32(x0 + w0, 0, @as(i32, @intCast(SCREEN_W)));
    const y_end = clampI32(y0 + h0, 0, @as(i32, @intCast(SCREEN_H)));
    if (x_end <= x_start or y_end <= y_start) return;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        while (x < x_end) : (x += 1) {
            const idx = ktx.HEADER_SIZE + (@as(usize, @intCast(y)) * SCREEN_W + @as(usize, @intCast(x))) * 4;
            output_buf[idx + 0] = color[0];
            output_buf[idx + 1] = color[1];
            output_buf[idx + 2] = color[2];
            output_buf[idx + 3] = color[3];
        }
    }
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return @min(@max(v, lo), hi);
}

fn fpToPx(v: i32) i32 {
    return @divFloor(v, FP);
}

test "level has required interactive hazards" {
    buildLevel();
    var gap_count: usize = 0;
    var brick_count: usize = 0;
    var tx: usize = 0;
    while (tx < WORLD_W) : (tx += 1) {
        if (tiles[15][tx] == .air) gap_count += 1;
    }
    var y: usize = 0;
    while (y < WORLD_H) : (y += 1) {
        var x: usize = 0;
        while (x < WORLD_W) : (x += 1) {
            if (tiles[y][x] == .brick or tiles[y][x] == .block) brick_count += 1;
        }
    }
    try std.testing.expect(gap_count >= 20);
    try std.testing.expect(brick_count >= 20);
    try std.testing.expect(enemy_count >= 8);
}
