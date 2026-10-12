const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

// A first-person exploration game set in the Pantheon in Rome, where pigeons
// and swifts fly in and out through the oculus. The level's walls are
// 2D line segments compiled into a binary space partition (BSP) at startup.
// Each frame walks the tree front to back from the eye, so the first wall to
// claim a screen column is the nearest one, and the walk stops once every
// column is claimed. Floors are sectors with their own planes, so they can be
// raised, lowered, or sloped into ramps; two-sided step lines in the same tree
// mark where one sector meets another. Floors, step faces, ceilings, the
// coffered dome, the oculus, and its sunbeam are then cast per pixel, with a
// depth buffer so birds can fly above walls and behind the dome. The same tree
// answers line-of-sight and collision queries.

const SCREEN_W: usize = 640;
const SCREEN_H: usize = 480;
const W: i32 = @intCast(SCREEN_W);
const H: i32 = @intCast(SCREEN_H);
// Overlays are laid out on a 320 by 240 grid and drawn this many times larger.
const UI: i32 = 2;
const PIXEL_BYTES: usize = SCREEN_W * SCREEN_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_PAGE_UP: i32 = 0xFF55;
const XK_PAGE_DOWN: i32 = 0xFF56;
const XK_ENTER: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const KEY_FWD: u8 = 1 << 0;
const KEY_BACK: u8 = 1 << 1;
const KEY_TURN_L: u8 = 1 << 2;
const KEY_TURN_R: u8 = 1 << 3;
const KEY_STRAFE_L: u8 = 1 << 4;
const KEY_STRAFE_R: u8 = 1 << 5;
const KEY_LOOK_UP: u8 = 1 << 6;
const KEY_LOOK_DOWN: u8 = 1 << 7;

const STEP_MS: i64 = 16;
const STEP: i32 = 16;
const MAX_STEPS_PER_UPDATE: i32 = 8;

// World units are metres; +x is east and +y is north. The rotunda is centred
// on the origin and the portico faces north onto the piazza. Heights are
// squashed from the real building so the dome stays in view.
const R: f32 = 21.6;
const WALL_H: f32 = 11.0;
const DOME_H: f32 = 12.0;
const DOME_K: f32 = R / DOME_H;
const ZTOP: f32 = WALL_H + DOME_H;
const OCULUS_R: f32 = 4.1;
const DOOR_HALF: f32 = 3.5;
const DOOR_LEAF_Y: f32 = 26.2;
const PORTICO_BACK: f32 = 30.0;
const PORTICO_FRONT: f32 = 46.0;
const PORTICO_HALF: f32 = 17.5;
const OBELISK_X: f32 = 0.0;
const OBELISK_Y: f32 = 68.0;
const BASIN_R: f32 = 4.2;

// The portico stands on a terrace above the piazza, reached by a cordonata
// (a broad ribbed ramp). Inside, a ramp climbs to a raised floor in the apse.
const PIAZZA_Z: f32 = -1.5;
const TERRACE_Y: f32 = 49.0;
const RAMP_HALF: f32 = 10.0;
const RAMP_FOOT_Y: f32 = 58.0;
const APSE_Z: f32 = 0.9;
const APSE_LIP: f32 = @sqrt(R * R - NICHE_SEMI_W * NICHE_SEMI_W);
const APSE_RAMP_HALF: f32 = 2.6;
const APSE_RAMP_LEN: f32 = 5.0;
const STEP_UP: f32 = 0.5;
const GRAVITY: f32 = 0.0025; // Metres per step per step, about 9.8 m/s/s.
// A jump rises about 1.1 m, so with the step allowance it clears the 1.5 m
// terrace edge and the apse ledge.
const JUMP_V: f32 = 0.0742;
// Walking down a ramp lags its surface slightly, so jumps allow some slack.
const JUMP_SLACK: f32 = 0.1;

const EYE_Z: f32 = 1.6;
const FOCAL: f32 = 340.0;
const HALF_W: f32 = 320.0;
const BASE_HORIZON: f32 = 256.0;
const NEAR: f32 = 0.05;

// Looking up or down shears the view, as in Heretic and Duke Nukem 3D: the
// horizon row moves and walls stay vertical. Looking well up shows the oculus.
const LOOK_STEP: f32 = 8.0;
const LOOK_UP_MAX: f32 = 480.0;
const LOOK_DOWN_MAX: f32 = 160.0;
const TITLE_LOOK: f32 = 340.0;
// Mouse look under pointer lock, per CSS pixel of movement. Looking up and
// down moves the horizon by FOCAL times the angle, so both axes turn the view
// at the same rate near the centre of the frame.
const MOUSE_TURN: f32 = 0.0025;
const MOUSE_LOOK: f32 = FOCAL * MOUSE_TURN;

const PLAYER_R: f32 = 0.35;
const MOVE_STEP: f32 = 0.096;
const TURN_STEP: f32 = 0.042;

const MESSAGE_MS: i32 = 2400;

// Birds. Pigeons walk the floors and take off when the player comes close;
// swifts circle under the dome and over the building. Both use the oculus.
const MAX_BIRDS: usize = 28;
const PIGEON_R: f32 = 0.15;
const PIGEON_WALK: f32 = 0.012;
const PIGEON_SPEED: f32 = 0.12; // About 7.5 m/s.
const SWIFT_SPEED: f32 = 0.19; // About 12 m/s.
const PIGEON_SPAN: f32 = 0.8;
const SWIFT_SPAN: f32 = 0.55;
// Birds are drawn larger than life so they read at a distance.
const BIRD_SCALE: f32 = 1.4;
const STARTLE_DIST: f32 = 3.2;
// Flights over the piazza stay above every wall top.
const CRUISE_Z: f32 = WALL_H + 2.0;
// Birds line up below the oculus and leave or arrive well above it.
const OCULUS_BELOW_Z: f32 = ZTOP - 4.0;
const OCULUS_ABOVE_Z: f32 = ZTOP + 5.0;
const SPIRAL_R: f32 = 9.0;
const ROTUNDA_SPOT_R: f32 = 13.0;
const ROTUNDA_WALK_R: f32 = 14.5;
const OUTSIDE_CY: f32 = 20.0;

const SUN_ELEVATION: f32 = 0.87; // About 50 degrees.
const SUN_AZ0: f32 = -std.math.pi / 2.0 - 0.7;
const SUN_DRIFT_PER_MS: f32 = 0.000012;

// Showers come and go. Rain falls on the open piazza around the player and,
// inside, only in the column under the oculus.
const MAX_OCULUS_DROPS: usize = 480;
const MAX_OPEN_DROPS: usize = 1200;
const MAX_SPLASHES: usize = 128;
const RAIN_FALL: f32 = 0.144; // About 9 m/s.
const RAIN_STREAK: f32 = 0.55;
const RAIN_TOP: f32 = ZTOP + 1.5;
const RAIN_NEAR: f32 = 1.0;
const OPEN_RAIN_HALF: f32 = 15.0;
const OPEN_RAIN_H: f32 = 14.0;
const DEAD_Z: f32 = -1000.0;
const SPLASH_MS: i32 = 224;
const SHOWER_MS: i32 = 45000;
const DRY_SPELL_MS: i32 = 40000;
const RAIN_FADE: f32 = 1.0 / 240.0; // Four seconds to start or stop.
// The drains take a share of the standing water each step, so the floor
// fills to about 0.85 in a long shower and empties within a minute after.
const PUDDLE_DRAIN: f32 = 0.0016;
const PUDDLE_FILL: f32 = 0.85 * PUDDLE_DRAIN;
const WET_REACH: f32 = OCULUS_R + 1.6;
// The Pantheon's floor has 22 small drain holes under the oculus.
const DRAIN_COUNT: f32 = 22.0;
const DRAIN_R: f32 = 3.0;
const DRAIN_HOLE: f32 = 0.08;

const MAX_BASE: usize = 640;
const MAX_SEGS: usize = 2048;
const MAX_NODES: usize = 2048;
const SCRATCH: usize = 4096;
const MAX_STACK: usize = 256;
const NO_SEG: u16 = 0xFFFF;
const MAX_EVENTS: usize = 8;
const EPS: f32 = 1e-3;

const MAX_PICKUPS: usize = 7;
const MAX_SPRITES: usize = MAX_BIRDS + MAX_PICKUPS;
const DEPTH_SKY: u16 = 0xFFFF;
const DEPTH_SCALE: f32 = 32.0;

const Rgb = @Vector(3, f32);
const Rgba = @Vector(4, f32);
const Color = [4]u8;

const C_HUD: Color = .{ 0x08, 0x07, 0x0A, 0xC0 };
const C_SHADE: Color = .{ 0x06, 0x05, 0x08, 0xB0 };
const C_TEXT: Color = .{ 0xF4, 0xF0, 0xE6, 0xFF };
const C_TEXT_DIM: Color = .{ 0x9A, 0x92, 0x84, 0xFF };
const C_TEXT_SHADOW: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_TITLE: Color = .{ 0xF2, 0xC2, 0x4E, 0xFF };
const C_TITLE_ALT: Color = .{ 0xE8, 0x5B, 0x3C, 0xFF };
const C_MAP_BG: Color = .{ 0x05, 0x06, 0x0A, 0xC8 };
const C_MAP_WALL: Color = .{ 0xD8, 0xD0, 0xBC, 0xFF };
const C_MAP_DIM: Color = .{ 0x50, 0x4C, 0x46, 0xFF };
const C_MAP_STEP: Color = .{ 0xC8, 0x8E, 0x3C, 0xFF };
const C_MAP_PLAYER: Color = .{ 0x6A, 0xE0, 0xFF, 0xFF };
const C_MAP_BIRD: Color = .{ 0xB8, 0xC4, 0xD8, 0xFF };

const PLANET_NAMES = [_][]const u8{ "SOL", "LUNA", "MARS", "MERCURIUS", "IUPPITER", "VENUS", "SATURNUS" };
const PLANET_MESSAGES = [_][]const u8{
    "SIGIL OF SOL",
    "SIGIL OF LUNA",
    "SIGIL OF MARS",
    "SIGIL OF MERCURIUS",
    "SIGIL OF IUPPITER",
    "SIGIL OF VENUS",
    "SIGIL OF SATURNUS",
};
const PLANET_COLORS = [_]Rgb{
    .{ 1.0, 0.82, 0.25 },
    .{ 0.86, 0.9, 0.98 },
    .{ 0.95, 0.26, 0.18 },
    .{ 0.4, 0.88, 0.92 },
    .{ 0.66, 0.42, 0.95 },
    .{ 0.42, 0.92, 0.5 },
    .{ 0.56, 0.62, 0.78 },
};
const ALL_SIGILS: u8 = 0x7F;

const FACADE_COLORS = [_]Rgb{
    .{ 0.86, 0.6, 0.3 },
    .{ 0.76, 0.4, 0.27 },
    .{ 0.93, 0.8, 0.52 },
    .{ 0.86, 0.58, 0.5 },
    .{ 0.9, 0.84, 0.7 },
};

// Level geometry

const Mat = enum(u8) { rotunda, niche, corridor, portico, granite_grey, granite_pink, giallo, facade, obelisk, terrace_step, apse_step };

// Floors are planes z = z0 + gx * x + gy * y. Ceilings stay level.
const Sector = enum(u8) { ground, piazza, cordonata, apse, apse_ramp };
const Plane = struct { z0: f32, gx: f32 = 0, gy: f32 = 0 };
const CORDONATA_GY: f32 = PIAZZA_Z / (RAMP_FOOT_Y - TERRACE_Y);
const APSE_RAMP_GY: f32 = -APSE_Z / APSE_RAMP_LEN;
const PLANES = [_]Plane{
    .{ .z0 = 0 },
    .{ .z0 = PIAZZA_Z },
    .{ .z0 = -CORDONATA_GY * TERRACE_Y, .gy = CORDONATA_GY },
    .{ .z0 = APSE_Z },
    .{ .z0 = APSE_Z + APSE_RAMP_GY * APSE_LIP, .gy = APSE_RAMP_GY },
};

const Seg = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    // Distance along the original wall at x1, y1, so split pieces keep their
    // texture alignment.
    u0: f32 = 0,
    mat: Mat,
    variant: u8 = 0,
    // A portal is a two-sided step line between sectors: it never blocks,
    // and it shows a step face where the far floor is higher.
    portal: bool = false,
    front: Sector = .ground,
    back: Sector = .ground,
};

// A node's splitter is the line through one of its segments. Every segment
// on that line is stored at the node; the rest go to the front (left of the
// line direction) or back subtree. Walls face their left side.
const Node = struct {
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    front: i16 = -1,
    back: i16 = -1,
    first: u16 = 0,
    count: u16 = 0,
};

const Niche = struct { deg: f32, semi: bool, columns: bool };
const NICHES = [_]Niche{
    .{ .deg = 135, .semi = false, .columns = true },
    .{ .deg = 180, .semi = true, .columns = true },
    .{ .deg = 225, .semi = false, .columns = true },
    .{ .deg = 270, .semi = true, .columns = false },
    .{ .deg = 315, .semi = false, .columns = true },
    .{ .deg = 360, .semi = true, .columns = true },
    .{ .deg = 405, .semi = false, .columns = true },
};
const NICHE_SEMI_W: f32 = 4.0;
const NICHE_SEMI_STRAIGHT: f32 = 0.6;
const NICHE_RECT_W: f32 = 3.4;
const NICHE_RECT_D: f32 = 2.6;
const ARC_STEP: f32 = 7.5 * std.math.pi / 180.0;

var base_segs: [MAX_BASE]Seg = undefined;
var base_count: usize = 0;
var segs: [MAX_SEGS]Seg = undefined;
var seg_count: usize = 0;
var nodes: [MAX_NODES]Node = undefined;
var node_count: usize = 0;
var bsp_depth: usize = 0;
var level_built = false;
var niche_spots: [NICHES.len][2]f32 = undefined;

var pen_x: f32 = 0;
var pen_y: f32 = 0;
var pen_mat: Mat = .rotunda;
var facade_variant: u8 = 0;

// Game state

const BirdKind = enum(u8) { pigeon, swift };
const BirdMode = enum(u8) { ground, fly, circle };
// A flight is a fixed series of legs, each a straight line to a waypoint or
// an arc around a centre that ends after a time or at a height.
const Route = enum(u8) { hop, piazza, out_oculus, in_oculus, swift };

const Bird = struct {
    active: bool = false,
    kind: BirdKind = .pigeon,
    mode: BirdMode = .ground,
    route: Route = .hop,
    leg: u8 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    // Facing in the plane.
    hx: f32 = 1,
    hy: f32 = 0,
    // Straight legs.
    tx: f32 = 0,
    ty: f32 = 0,
    tz: f32 = 0,
    speed: f32 = 0,
    // Arcs.
    cx: f32 = 0,
    cy: f32 = 0,
    r: f32 = 0,
    ang: f32 = 0,
    spin: f32 = 0,
    climb: f32 = 0,
    z_end: f32 = 0,
    // Where a pigeon will land.
    lx: f32 = 0,
    ly: f32 = 0,
    timer_ms: i32 = 0,
    peck_ms: i32 = 0,
    flap: f32 = 0,
    glide: bool = false,
};

const Pickup = struct {
    active: bool = false,
    planet: u8 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

const Drop = struct { x: f32 = 0, y: f32 = 0, z: f32 = DEAD_Z };
const Splash = struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, age_ms: i32 = SPLASH_MS, seed: u32 = 0 };

const Mode = enum(u8) { title, playing, paused, won };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
// Depth along the view axis for each pixel, so birds can pass behind walls,
// ceilings, and the dome and show through the oculus.
var depth_buf: [SCREEN_W * SCREEN_H]u16 = undefined;

var birds: [MAX_BIRDS]Bird = [_]Bird{.{}} ** MAX_BIRDS;
var pickups: [MAX_PICKUPS]Pickup = [_]Pickup{.{}} ** MAX_PICKUPS;

var oculus_drops: [MAX_OCULUS_DROPS]Drop = undefined;
var open_drops: [MAX_OPEN_DROPS]Drop = undefined;
var splashes: [MAX_SPLASHES]Splash = undefined;
var splash_next: usize = 0;
// Rain has its own generator so the weather does not change the birds.
var rain_rng: u32 = 0x6C8E_9CF5;
var raining = true;
var weather_ms: i32 = SHOWER_MS;
// How hard it is raining, 0 to 1, easing between showers and dry spells.
var rain: f32 = 0;
// Standing water on the rotunda floor, and how wet the open paving is.
var puddle: f32 = 0;
var wet_out: f32 = 0;

var mode: Mode = .title;
var keys_down: u8 = 0;
var pointer_down = false;
// The host's running totals of locked pointer movement, and the totals the
// view has already turned by. Only the difference turns the view, so the
// host can pass the same totals again before a render.
var mouse_total_x: i32 = 0;
var mouse_total_y: i32 = 0;
var mouse_used_x: i32 = 0;
var mouse_used_y: i32 = 0;
var jump_held = false;
var map_mode: u8 = 0;
var rng_state: u32 = 0x2F6B_A1C3;
var anim_ms: i32 = 0;
var time_ms: i32 = 0;

var px: f32 = 0;
var py: f32 = 0;
var pz: f32 = 0;
var fall_v: f32 = 0;
var pangle: f32 = 0;
var look: f32 = 0;
var sigils: u8 = 0;
var score: u32 = 0;
var hi_score: u32 = 0;
var message: []const u8 = "";
var message_ms: i32 = 0;

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

export fn uniform_set_pointer_total_movement_x(value: i32) i32 {
    mouse_total_x = value;
    applyMouseLook();
    return value;
}

export fn uniform_set_pointer_total_movement_y(value: i32) i32 {
    mouse_total_y = value;
    applyMouseLook();
    return value;
}

// Turns the view only during an update, so a render sees the same view the
// update left. Movement on the title screen or while paused is dropped
// rather than saved up for the next game.
fn applyMouseLook() void {
    if (phase != .updating) return;
    const dx: f32 = @floatFromInt(mouse_total_x -% mouse_used_x);
    const dy: f32 = @floatFromInt(mouse_total_y -% mouse_used_y);
    mouse_used_x = mouse_total_x;
    mouse_used_y = mouse_total_y;
    if (mode != .playing) return;
    pangle = wrapAngle(pangle - dx * MOUSE_TURN);
    look = std.math.clamp(look - dy * MOUSE_LOOK, -LOOK_DOWN_MAX, LOOK_UP_MAX);
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;

    const bit: u8 = switch (x11_key) {
        XK_UP, 'w', 'W' => KEY_FWD,
        XK_DOWN, 's', 'S' => KEY_BACK,
        XK_LEFT => KEY_TURN_L,
        XK_RIGHT => KEY_TURN_R,
        'a', 'A' => KEY_STRAFE_L,
        'd', 'D' => KEY_STRAFE_R,
        XK_PAGE_UP, 'q', 'Q' => KEY_LOOK_UP,
        XK_PAGE_DOWN, 'e', 'E' => KEY_LOOK_DOWN,
        else => 0,
    };
    const was_down = (keys_down & bit) != 0;
    if (bit != 0) {
        if (is_down) keys_down |= bit else keys_down &= ~bit;
    }
    // Each jump needs a fresh press, so key repeat does not bounce.
    const jump_was_held = jump_held;
    if (x11_key == ' ') jump_held = is_down;
    if (!is_down) return if (bit != 0 and was_down) 1 else 0;
    if (bit != 0 and was_down) return 0;

    switch (x11_key) {
        ' ', XK_ENTER => {
            if (mode == .title or mode == .won) {
                startGame(begun_at_ms);
                return 1;
            }
            if (mode == .paused and x11_key == XK_ENTER) {
                resume_();
                return 1;
            }
            if (mode == .playing and x11_key == ' ' and !jump_was_held) return if (jump()) 1 else 0;
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
        'm', 'M' => {
            map_mode = (map_mode + 1) % 3;
            return 1;
        },
        't', 'T' => {
            if (mode != .playing) return 0;
            setRaining(!raining);
            return 1;
        },
        else => {},
    }
    return if (bit != 0) 1 else 0;
}

export fn pointer_event(button_mask: i32, _: i32, _: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const down = (button_mask & 1) != 0;
    const was_down = pointer_down;
    pointer_down = down;
    if (!down or was_down) return 0;
    switch (mode) {
        .title, .won => {
            startGame(begun_at_ms);
            return 1;
        },
        .playing, .paused => return 0,
    }
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
    // Bound work after a long host pause by dropping the remaining backlog.
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

// Level construction

fn buildLevel() void {
    if (level_built) return;
    base_count = 0;
    buildOutline();
    buildPillars();
    buildSteps();
    buildBsp();
    level_built = true;
}

fn addSeg(x1: f32, y1: f32, x2: f32, y2: f32, mat: Mat, variant: u8, start_u: f32) void {
    if (@abs(x2 - x1) + @abs(y2 - y1) < 1e-4) return;
    if (base_count >= MAX_BASE) @trap();
    base_segs[base_count] = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .u0 = start_u, .mat = mat, .variant = variant };
    base_count += 1;
}

fn penMove(x: f32, y: f32) void {
    pen_x = x;
    pen_y = y;
}

fn penLine(x: f32, y: f32) void {
    addSeg(pen_x, pen_y, x, y, pen_mat, 0, 0);
    penMove(x, y);
}

// Piazza walls are split into building-wide pieces with their own colours.
fn penFacade(x: f32, y: f32) void {
    const len = @sqrt((x - pen_x) * (x - pen_x) + (y - pen_y) * (y - pen_y));
    const n: usize = @max(1, @as(usize, @intFromFloat(@round(len / 9.0))));
    const sx = pen_x;
    const sy = pen_y;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const nx = sx + (x - sx) * f;
        const ny = sy + (y - sy) * f;
        addSeg(pen_x, pen_y, nx, ny, .facade, facade_variant, 0);
        facade_variant = (facade_variant + 3) % @as(u8, FACADE_COLORS.len);
        penMove(nx, ny);
    }
}

fn polar(r: f32, a: f32) [2]f32 {
    return .{ r * @cos(a), r * @sin(a) };
}

fn penArc(a0: f32, a1: f32) void {
    const n: usize = @max(1, @as(usize, @intFromFloat(@ceil((a1 - a0) / ARC_STEP))));
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const a = a0 + (a1 - a0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const p = polar(R, a);
        penLine(p[0], p[1]);
    }
}

fn nicheHalfWidth(n: Niche) f32 {
    return if (n.semi) NICHE_SEMI_W else NICHE_RECT_W;
}

// The playable area is one counter-clockwise outline (rotunda, entrance,
// portico, piazza). Pillars are clockwise holes inside it.
fn buildOutline() void {
    const door_y = @sqrt(R * R - DOOR_HALF * DOOR_HALF);
    // The open bronze door leaves line the outer end of the entrance.
    penMove(DOOR_HALF, door_y);
    pen_mat = .portico;
    penLine(DOOR_HALF, DOOR_LEAF_Y);
    pen_mat = .corridor;
    penLine(DOOR_HALF, PORTICO_BACK);
    pen_mat = .portico;
    penLine(7.5, PORTICO_BACK);
    penLine(7.5, 27);
    penLine(12.5, 27);
    penLine(12.5, PORTICO_BACK);
    penLine(PORTICO_HALF, PORTICO_BACK);
    penLine(PORTICO_HALF, PORTICO_FRONT);
    facade_variant = 0;
    penFacade(32, 48);
    penFacade(34, 82);
    penFacade(12, 90);
    penFacade(-10, 88);
    penFacade(-34, 80);
    penFacade(-32, 48);
    penFacade(-PORTICO_HALF, PORTICO_FRONT);
    pen_mat = .portico;
    penLine(-PORTICO_HALF, PORTICO_BACK);
    penLine(-12.5, PORTICO_BACK);
    penLine(-12.5, 27);
    penLine(-7.5, 27);
    penLine(-7.5, PORTICO_BACK);
    penLine(-DOOR_HALF, PORTICO_BACK);
    pen_mat = .corridor;
    penLine(-DOOR_HALF, DOOR_LEAF_Y);
    pen_mat = .portico;
    penLine(-DOOR_HALF, door_y);

    const door_a = std.math.acos(DOOR_HALF / R);
    var a = std.math.pi - door_a;
    for (NICHES, 0..) |niche, i| {
        const theta = niche.deg * std.math.pi / 180.0;
        const w = nicheHalfWidth(niche);
        const alpha = std.math.asin(w / R);
        pen_mat = .rotunda;
        penArc(a, theta - alpha);
        pen_mat = .niche;
        const rx = @cos(theta);
        const ry = @sin(theta);
        const tx = -ry;
        const ty = rx;
        const m = R * @cos(alpha);
        if (niche.semi) {
            const qr = m + NICHE_SEMI_STRAIGHT;
            penLine(qr * rx - w * tx, qr * ry - w * ty);
            var k: usize = 1;
            while (k <= 8) : (k += 1) {
                const phi = std.math.pi * @as(f32, @floatFromInt(k)) / 8.0;
                const c = @cos(phi);
                const s = @sin(phi);
                penLine(qr * rx + w * (-c * tx + s * rx), qr * ry + w * (-c * ty + s * ry));
            }
            niche_spots[i] = .{ (qr + w * 0.45) * rx, (qr + w * 0.45) * ry };
        } else {
            const br = m + NICHE_RECT_D;
            penLine(br * rx - w * tx, br * ry - w * ty);
            penLine(br * rx + w * tx, br * ry + w * ty);
            niche_spots[i] = .{ (m + NICHE_RECT_D * 0.5) * rx, (m + NICHE_RECT_D * 0.5) * ry };
        }
        const end = polar(R, theta + alpha);
        penLine(end[0], end[1]);
        a = theta + alpha;
    }
    pen_mat = .rotunda;
    penArc(a, 2.0 * std.math.pi + door_a);
}

fn addPillar(cx: f32, cy: f32, r: f32, sides: usize, mat: Mat, rot: f32) void {
    const n: f32 = @floatFromInt(sides);
    const side_len = 2.0 * r * @sin(std.math.pi / n);
    var i: usize = 0;
    while (i < sides) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const a0 = rot - 2.0 * std.math.pi * fi / n;
        const a1 = rot - 2.0 * std.math.pi * (fi + 1.0) / n;
        addSeg(cx + r * @cos(a0), cy + r * @sin(a0), cx + r * @cos(a1), cy + r * @sin(a1), mat, 0, fi * side_len);
    }
}

const PORTICO_COLUMN_XS = [_]f32{ -15.75, -11.25, -6.75, -2.25, 2.25, 6.75, 11.25, 15.75 };

fn buildPillars() void {
    for (PORTICO_COLUMN_XS) |x| addPillar(x, 44.0, 0.8, 8, .granite_grey, std.math.pi / 8.0);
    for ([_]f32{ -15.75, -11.25, 11.25, 15.75 }) |x| {
        addPillar(x, 39.5, 0.8, 8, .granite_pink, std.math.pi / 8.0);
        addPillar(x, 35.0, 0.8, 8, .granite_pink, std.math.pi / 8.0);
    }
    for (NICHES) |niche| {
        if (!niche.columns) continue;
        const theta = niche.deg * std.math.pi / 180.0;
        const w = nicheHalfWidth(niche);
        const m = R * @cos(std.math.asin(w / R)) + 0.2;
        const rx = @cos(theta);
        const ry = @sin(theta);
        for ([_]f32{ -0.55, 0.55 }) |f| {
            addPillar(m * rx - f * w * ry, m * ry + f * w * rx, 0.5, 8, .giallo, theta);
        }
    }
    addPillar(OBELISK_X, OBELISK_Y, 0.95, 4, .obelisk, std.math.pi / 4.0);
}

fn addPortal(x1: f32, y1: f32, x2: f32, y2: f32, mat: Mat, front: Sector, back: Sector) void {
    addSeg(x1, y1, x2, y2, mat, 0, 0);
    base_segs[base_count - 1].portal = true;
    base_segs[base_count - 1].front = front;
    base_segs[base_count - 1].back = back;
}

// Step lines around the terrace, the cordonata, and the apse. The front
// sector is on the left of each line's direction.
fn buildSteps() void {
    const ts: Mat = .terrace_step;
    addPortal(-PORTICO_HALF, TERRACE_Y, -RAMP_HALF, TERRACE_Y, ts, .piazza, .ground);
    addPortal(-RAMP_HALF, TERRACE_Y, RAMP_HALF, TERRACE_Y, ts, .cordonata, .ground);
    addPortal(RAMP_HALF, TERRACE_Y, PORTICO_HALF, TERRACE_Y, ts, .piazza, .ground);
    addPortal(-RAMP_HALF, RAMP_FOOT_Y, RAMP_HALF, RAMP_FOOT_Y, ts, .piazza, .cordonata);
    addPortal(RAMP_HALF, TERRACE_Y, RAMP_HALF, RAMP_FOOT_Y, ts, .cordonata, .piazza);
    addPortal(-RAMP_HALF, TERRACE_Y, -RAMP_HALF, RAMP_FOOT_Y, ts, .piazza, .cordonata);
    addPortal(PORTICO_HALF, PORTICO_FRONT, PORTICO_HALF, TERRACE_Y, ts, .ground, .piazza);
    addPortal(-PORTICO_HALF, PORTICO_FRONT, -PORTICO_HALF, TERRACE_Y, ts, .piazza, .ground);

    const as: Mat = .apse_step;
    const lip = -APSE_LIP;
    const foot = lip + APSE_RAMP_LEN;
    addPortal(-NICHE_SEMI_W, lip, -APSE_RAMP_HALF, lip, as, .ground, .apse);
    addPortal(-APSE_RAMP_HALF, lip, APSE_RAMP_HALF, lip, as, .apse_ramp, .apse);
    addPortal(APSE_RAMP_HALF, lip, NICHE_SEMI_W, lip, as, .ground, .apse);
    addPortal(-APSE_RAMP_HALF, foot, APSE_RAMP_HALF, foot, as, .ground, .apse_ramp);
    addPortal(APSE_RAMP_HALF, lip, APSE_RAMP_HALF, foot, as, .apse_ramp, .ground);
    addPortal(-APSE_RAMP_HALF, lip, -APSE_RAMP_HALF, foot, as, .ground, .apse_ramp);
}

fn sectorAt(x: f32, y: f32) Sector {
    if (y >= PORTICO_FRONT) {
        if (@abs(x) <= PORTICO_HALF and y < TERRACE_Y) return .ground;
        if (@abs(x) <= RAMP_HALF and y < RAMP_FOOT_Y) return .cordonata;
        return .piazza;
    }
    // Inside the building, only the apse reaches past its lip.
    if (y < -APSE_LIP) return .apse;
    if (@abs(x) <= APSE_RAMP_HALF and y < -APSE_LIP + APSE_RAMP_LEN) return .apse_ramp;
    return .ground;
}

fn planeZ(sec: Sector, x: f32, y: f32) f32 {
    const p = PLANES[@intFromEnum(sec)];
    return p.z0 + p.gx * x + p.gy * y;
}

fn floorAt(x: f32, y: f32) f32 {
    return planeZ(sectorAt(x, y), x, y);
}

// The highest floor under a walker's footprint.
fn footHeight(x: f32, y: f32, r: f32) f32 {
    var z = floorAt(x, y);
    for ([_][2]f32{ .{ r, 0 }, .{ -r, 0 }, .{ 0, r }, .{ 0, -r } }) |o| z = @max(z, floorAt(x + o[0], y + o[1]));
    return z;
}

// BSP construction

const Line = struct { x: f32, y: f32, dx: f32, dy: f32 };

fn lineOf(s: Seg) Line {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const len = @sqrt(dx * dx + dy * dy);
    return .{ .x = s.x1, .y = s.y1, .dx = dx / len, .dy = dy / len };
}

// Signed distance from a line; positive is on its left (front) side.
fn sideOf(l: Line, x: f32, y: f32) f32 {
    return l.dx * (y - l.y) - l.dy * (x - l.x);
}

fn nodeLine(n: Node) Line {
    return .{ .x = n.x, .y = n.y, .dx = n.dx, .dy = n.dy };
}

const Class = enum { on, front, back, split };

fn classify(l: Line, s: Seg) Class {
    const s1 = sideOf(l, s.x1, s.y1);
    const s2 = sideOf(l, s.x2, s.y2);
    if (@abs(s1) < EPS and @abs(s2) < EPS) return .on;
    if (s1 > -EPS and s2 > -EPS) return .front;
    if (s1 < EPS and s2 < EPS) return .back;
    return .split;
}

fn chooseSplitter(list: []const Seg) usize {
    const stride = @max(1, list.len / 24);
    var best: usize = 0;
    var best_score: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i < list.len) : (i += stride) {
        const l = lineOf(list[i]);
        var front: usize = 0;
        var back: usize = 0;
        var splits: usize = 0;
        for (list) |s| {
            switch (classify(l, s)) {
                .on => {},
                .front => front += 1,
                .back => back += 1,
                .split => splits += 1,
            }
        }
        const balance = if (front > back) front - back else back - front;
        const score_ = splits * 8 + balance;
        if (score_ < best_score) {
            best_score = score_;
            best = i;
        }
    }
    return best;
}

var scratch: [SCRATCH]Seg = undefined;
var tmp_front: [SCRATCH]Seg = undefined;
var tmp_back: [SCRATCH]Seg = undefined;

const BuildItem = struct { start: usize, len: usize, parent: i16, is_front: bool, depth: usize };

// Builds without recursion. Each pending list sits at the top of `scratch`;
// a partition writes the back list then the front list over its parent, and
// the front list is built next, so lists never overlap.
fn buildBsp() void {
    seg_count = 0;
    node_count = 0;
    bsp_depth = 0;
    @memcpy(scratch[0..base_count], base_segs[0..base_count]);
    var stack: [MAX_STACK]BuildItem = undefined;
    var sp: usize = 0;
    stack[0] = .{ .start = 0, .len = base_count, .parent = -1, .is_front = true, .depth = 1 };
    sp = 1;
    var guard: usize = 0;
    while (sp > 0 and guard < MAX_NODES * 2) : (guard += 1) {
        sp -= 1;
        const item = stack[sp];
        if (item.len == 0) continue;
        if (node_count >= MAX_NODES) @trap();
        bsp_depth = @max(bsp_depth, item.depth);
        const list = scratch[item.start .. item.start + item.len];
        const l = lineOf(list[chooseSplitter(list)]);
        const ni = node_count;
        node_count += 1;
        nodes[ni] = .{ .x = l.x, .y = l.y, .dx = l.dx, .dy = l.dy, .first = @intCast(seg_count) };
        if (item.parent >= 0) {
            const parent = &nodes[@intCast(item.parent)];
            if (item.is_front) parent.front = @intCast(ni) else parent.back = @intCast(ni);
        }

        var nf: usize = 0;
        var nb: usize = 0;
        for (list) |s| {
            if (nf + 2 > SCRATCH or nb + 2 > SCRATCH) @trap();
            switch (classify(l, s)) {
                .on => {
                    if (seg_count >= MAX_SEGS) @trap();
                    segs[seg_count] = s;
                    seg_count += 1;
                },
                .front => {
                    tmp_front[nf] = s;
                    nf += 1;
                },
                .back => {
                    tmp_back[nb] = s;
                    nb += 1;
                },
                .split => {
                    const s1 = sideOf(l, s.x1, s.y1);
                    const s2 = sideOf(l, s.x2, s.y2);
                    const t = s1 / (s1 - s2);
                    const mx = s.x1 + (s.x2 - s.x1) * t;
                    const my = s.y1 + (s.y2 - s.y1) * t;
                    const len = @sqrt((s.x2 - s.x1) * (s.x2 - s.x1) + (s.y2 - s.y1) * (s.y2 - s.y1));
                    var a = s;
                    a.x2 = mx;
                    a.y2 = my;
                    var b = s;
                    b.x1 = mx;
                    b.y1 = my;
                    b.u0 = s.u0 + len * t;
                    if (s1 > 0) {
                        tmp_front[nf] = a;
                        tmp_back[nb] = b;
                    } else {
                        tmp_back[nb] = a;
                        tmp_front[nf] = b;
                    }
                    nf += 1;
                    nb += 1;
                },
            }
        }
        nodes[ni].count = @intCast(seg_count - nodes[ni].first);
        if (item.start + nb + nf > SCRATCH or sp + 2 > MAX_STACK) @trap();
        @memcpy(scratch[item.start .. item.start + nb], tmp_back[0..nb]);
        @memcpy(scratch[item.start + nb .. item.start + nb + nf], tmp_front[0..nf]);
        stack[sp] = .{ .start = item.start, .len = nb, .parent = @intCast(ni), .is_front = false, .depth = item.depth + 1 };
        stack[sp + 1] = .{ .start = item.start + nb, .len = nf, .parent = @intCast(ni), .is_front = true, .depth = item.depth + 1 };
        sp += 2;
    }
}

// BSP queries

const RayItem = struct { node: i16, t0: f32, t1: f32, check: bool };

// Returns the nearest wall crossing along o + t*d for t in [0, t_max], or
// t_max when the path is clear. Near subtrees are searched before the
// segments on the splitter and the far subtree, so the first hit wins.
fn rayCast(ox: f32, oy: f32, dx: f32, dy: f32, t_max: f32) f32 {
    if (node_count == 0) return t_max;
    var stack: [MAX_STACK]RayItem = undefined;
    stack[0] = .{ .node = 0, .t0 = 0, .t1 = t_max, .check = false };
    var sp: usize = 1;
    var guard: usize = 0;
    while (sp > 0 and guard < MAX_NODES * 4) : (guard += 1) {
        sp -= 1;
        const it = stack[sp];
        if (it.node < 0) continue;
        const n = nodes[@intCast(it.node)];
        if (it.check) {
            const hx = ox + dx * it.t0;
            const hy = oy + dy * it.t0;
            for (segs[n.first .. n.first + n.count]) |s| {
                if (!s.portal and pointWithinSeg(s, hx, hy)) return it.t0;
            }
            continue;
        }
        const so = sideOf(nodeLine(n), ox, oy);
        const ds = n.dx * dy - n.dy * dx;
        const s0 = so + ds * it.t0;
        const s1 = so + ds * it.t1;
        const near_front = if (@abs(s0) > EPS) s0 > 0 else s1 > 0;
        const near = if (near_front) n.front else n.back;
        const far = if (near_front) n.back else n.front;
        if (sp + 3 > MAX_STACK) @trap();
        if ((s0 > EPS and s1 < -EPS) or (s0 < -EPS and s1 > EPS)) {
            const ts = -so / ds;
            stack[sp] = .{ .node = far, .t0 = ts, .t1 = it.t1, .check = false };
            stack[sp + 1] = .{ .node = it.node, .t0 = ts, .t1 = ts, .check = true };
            stack[sp + 2] = .{ .node = near, .t0 = it.t0, .t1 = ts, .check = false };
            sp += 3;
        } else {
            stack[sp] = .{ .node = near, .t0 = it.t0, .t1 = it.t1, .check = false };
            sp += 1;
        }
    }
    return t_max;
}

fn pointWithinSeg(s: Seg, x: f32, y: f32) bool {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const len2 = dx * dx + dy * dy;
    const t = ((x - s.x1) * dx + (y - s.y1) * dy) / len2;
    return t >= -1e-4 and t <= 1.0 + 1e-4;
}

fn lineClear(ax: f32, ay: f32, bx: f32, by: f32) bool {
    return rayCast(ax, ay, bx - ax, by - ay, 1.0) >= 1.0;
}

// Pushes a circle out of every wall it overlaps. Only subtrees whose
// half-plane the circle touches are visited.
fn resolveCircle(x: *f32, y: *f32, r: f32) bool {
    var pushed = false;
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        var moved = false;
        var stack: [MAX_STACK]i16 = undefined;
        stack[0] = 0;
        var sp: usize = if (node_count > 0) 1 else 0;
        var guard: usize = 0;
        while (sp > 0 and guard < MAX_NODES) : (guard += 1) {
            sp -= 1;
            const n = nodes[@intCast(stack[sp])];
            const s = sideOf(nodeLine(n), x.*, y.*);
            if (sp + 2 > MAX_STACK) @trap();
            if (s > -r and n.front >= 0) {
                stack[sp] = n.front;
                sp += 1;
            }
            if (s < r and n.back >= 0) {
                stack[sp] = n.back;
                sp += 1;
            }
            if (@abs(s) >= r) continue;
            for (segs[n.first .. n.first + n.count]) |seg| {
                if (seg.portal) continue;
                const c = closestOnSeg(seg, x.*, y.*);
                const ex = x.* - c[0];
                const ey = y.* - c[1];
                const d2 = ex * ex + ey * ey;
                if (d2 >= r * r or d2 < 1e-12) continue;
                const d = @sqrt(d2);
                x.* += ex / d * (r - d);
                y.* += ey / d * (r - d);
                moved = true;
                pushed = true;
            }
        }
        if (!moved) break;
    }
    return pushed;
}

fn closestOnSeg(s: Seg, x: f32, y: f32) [2]f32 {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const t = std.math.clamp(((x - s.x1) * dx + (y - s.y1) * dy) / (dx * dx + dy * dy), 0.0, 1.0);
    return .{ s.x1 + dx * t, s.y1 + dy * t };
}

fn spotClear(x: f32, y: f32, r: f32) bool {
    var cx = x;
    var cy = y;
    return !resolveCircle(&cx, &cy, r);
}

// Moves a walker standing at height z, sliding along walls and then along
// each axis, unless the floor ahead rises more than a step. Walking off a
// ledge is allowed.
fn tryMove(x: *f32, y: *f32, mx: f32, my: f32, r: f32, z: f32) bool {
    const limit = @max(z + STEP_UP, footHeight(x.*, y.*, r));
    for ([_][2]f32{ .{ mx, my }, .{ mx, 0 }, .{ 0, my } }) |m| {
        if (m[0] == 0 and m[1] == 0) continue;
        var nx = x.* + m[0];
        var ny = y.* + m[1];
        _ = resolveCircle(&nx, &ny, r);
        if (footHeight(nx, ny, r) > limit) continue;
        x.* = nx;
        y.* = ny;
        return true;
    }
    return false;
}

// Game state

fn resetGame() void {
    buildLevel();
    mode = .title;
    birds = [_]Bird{.{}} ** MAX_BIRDS;
    pickups = [_]Pickup{.{}} ** MAX_PICKUPS;
    anim_ms = 0;
    time_ms = 0;
    px = 0;
    py = 84;
    pz = floorAt(px, py);
    fall_v = 0;
    pangle = -std.math.pi / 2.0;
    look = 0;
    sigils = 0;
    score = 0;
    message = "";
    message_ms = 0;
    resetRain();
    placeActors();
}

// Pigeons start on the piazza and the rotunda floor; swifts start half under
// the dome and half above the building, so the oculus is busy from the start.
const PIGEON_SPOTS = [_][2]f32{
    .{ -14, 74 }, .{ -11, 76 }, .{ 12, 72 }, .{ 15, 70 },  .{ 8, 80 },
    .{ -20, 60 }, .{ 22, 62 },  .{ 4, 56 },  .{ -6, 82 },  .{ -3, 6 },
    .{ 4, 3 },    .{ -6, -9 },  .{ 9, -5 },  .{ 1, -12 },
};
const SWIFTS_INSIDE: usize = 5;
const SWIFTS_OUTSIDE: usize = 5;
// Planet order around the niches, starting north-west and running CCW.
const NICHE_PLANETS = [_]u8{ 3, 2, 4, 0, 6, 1, 5 };

fn placeActors() void {
    for (NICHE_PLANETS, 0..) |planet, i| {
        pickups[i] = .{ .active = true, .planet = planet, .x = niche_spots[i][0], .y = niche_spots[i][1] };
    }
    var n: usize = 0;
    for (PIGEON_SPOTS) |spot| {
        const a = rngFloat(0, 2.0 * std.math.pi);
        birds[n] = .{ .active = true, .kind = .pigeon, .x = spot[0], .y = spot[1], .z = floorAt(spot[0], spot[1]), .hx = @cos(a), .hy = @sin(a), .timer_ms = rngRange(3000, 16000) };
        n += 1;
    }
    var i: usize = 0;
    while (i < SWIFTS_INSIDE + SWIFTS_OUTSIDE) : (i += 1) {
        const b = &birds[n];
        n += 1;
        b.* = .{ .active = true, .kind = .swift, .route = .swift, .flap = @floatFromInt(i) };
        if (i < SWIFTS_INSIDE) {
            const p = insideSwiftSpot();
            b.x = p[0];
            b.y = p[1];
            b.z = p[2];
            b.leg = 0;
            circleAround(b, 0, 0, swiftSpin(), rngRange(1500, 9000), 0, 0);
        } else {
            const p = outsideSwiftSpot();
            b.x = p[0];
            b.y = p[1];
            b.z = p[2];
            b.leg = 4;
            circleAround(b, 0, OUTSIDE_CY, swiftSpin(), rngRange(1500, 9000), 0, 0);
        }
    }
}

fn startGame(at_ms: i64) void {
    // The start time varies between games, so it seeds the birds.
    rng_state ^= @truncate(@as(u64, @bitCast(at_ms)) *% 0x9E3779B97F4A7C15);
    if (rng_state == 0) rng_state = 0x2F6B_A1C3;
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
    time_ms +|= STEP;
    if (message_ms > 0) message_ms -= STEP;

    updatePlayer();
    updateBirds();
    updateRain();
    collectPickups();
    if (sigils == ALL_SIGILS and beamAt(px, py, pz) > 0.5) {
        const seconds: u32 = @intCast(@divTrunc(time_ms, 1000));
        score +|= 2000 + (if (seconds < 600) (600 - seconds) * 10 else 0);
        hi_score = @max(hi_score, score);
        mode = .won;
    }
}

// Keeps a heading within -pi to pi, however far a fast mouse turned it.
fn wrapAngle(a: f32) f32 {
    return a - 2.0 * std.math.pi * @round(a / (2.0 * std.math.pi));
}

fn forward() [2]f32 {
    return .{ @cos(pangle), @sin(pangle) };
}

fn updatePlayer() void {
    var turn: f32 = 0;
    if ((keys_down & KEY_TURN_L) != 0) turn += 1;
    if ((keys_down & KEY_TURN_R) != 0) turn -= 1;
    pangle = wrapAngle(pangle + turn * TURN_STEP);
    if ((keys_down & KEY_LOOK_UP) != 0) look = @min(LOOK_UP_MAX, look + LOOK_STEP);
    if ((keys_down & KEY_LOOK_DOWN) != 0) look = @max(-LOOK_DOWN_MAX, look - LOOK_STEP);

    const f = forward();
    var mf: f32 = 0;
    var ms: f32 = 0;
    if ((keys_down & KEY_FWD) != 0) mf += 1;
    if ((keys_down & KEY_BACK) != 0) mf -= 1;
    if ((keys_down & KEY_STRAFE_R) != 0) ms += 1;
    if ((keys_down & KEY_STRAFE_L) != 0) ms -= 1;
    if (mf != 0 or ms != 0) {
        // Right is the forward vector turned clockwise.
        var mx = f[0] * mf + f[1] * ms;
        var my = f[1] * mf - f[0] * ms;
        const len = @sqrt(mx * mx + my * my);
        mx = mx / len * MOVE_STEP;
        my = my / len * MOVE_STEP;
        _ = tryMove(&px, &py, mx, my, PLAYER_R, pz);
    }
    // Step up at once; fall off ledges and come down from jumps.
    const floor = floorAt(px, py);
    if (pz > floor or fall_v < 0) {
        fall_v += GRAVITY;
        pz = @max(floor, pz - fall_v);
        if (pz == floor) fall_v = 0;
    } else {
        pz = floor;
        fall_v = 0;
    }
}

// Jumps only from the ground, not in mid-air.
fn jump() bool {
    if (fall_v < 0 or pz - floorAt(px, py) > JUMP_SLACK) return false;
    fall_v = -JUMP_V;
    return true;
}

fn collectPickups() void {
    for (&pickups) |*p| {
        if (!p.active) continue;
        const dx = p.x - px;
        const dy = p.y - py;
        if (dx * dx + dy * dy > 1.0) continue;
        p.active = false;
        sigils |= @as(u8, 1) << @intCast(p.planet);
        score +|= 500;
        if (sigils == ALL_SIGILS) {
            showMessage("STAND IN THE SUNBEAM");
        } else {
            showMessage(PLANET_MESSAGES[p.planet]);
        }
    }
}

fn showMessage(text: []const u8) void {
    message = text;
    message_ms = MESSAGE_MS;
}

// Birds

fn inRotunda(x: f32, y: f32) bool {
    return x * x + y * y < R * R;
}

// Height of the roof over a point: the dome inside the drum, and flat
// ceilings over the entrance and portico. The piazza is open.
fn roofAt(x: f32, y: f32) f32 {
    if (y >= PORTICO_FRONT) return std.math.inf(f32);
    const r2 = x * x + y * y;
    if (r2 < R * R) return WALL_H + DOME_H * @sqrt(1.0 - r2 / (R * R));
    return WALL_H;
}

// Where a pigeon may walk: the middle of the rotunda, or the open piazza
// away from the fountain basin.
fn pigeonGround(x: f32, y: f32, rotunda: bool) bool {
    if (rotunda) return x * x + y * y < ROTUNDA_WALK_R * ROTUNDA_WALK_R;
    if (y < 51 or y > 86 or @abs(x) > 27) return false;
    const ox = x - OBELISK_X;
    const oy = y - OBELISK_Y;
    return ox * ox + oy * oy > (BASIN_R + 0.4) * (BASIN_R + 0.4);
}

fn rngFloat(lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * @as(f32, @floatFromInt(rngNext() & 0xFFFF)) / 65535.0;
}

fn swiftSpin() f32 {
    return if ((rngNext() & 1) == 0) SWIFT_SPEED else -SWIFT_SPEED;
}

fn insideSwiftSpot() [3]f32 {
    const p = polar(rngFloat(6, 13), rngFloat(0, 2.0 * std.math.pi));
    return .{ p[0], p[1], rngFloat(7, 15) };
}

fn outsideSwiftSpot() [3]f32 {
    const p = polar(rngFloat(12, 28), rngFloat(0, 2.0 * std.math.pi));
    return .{ p[0], p[1] + OUTSIDE_CY, rngFloat(26, 34) };
}

fn rotundaSpot() [2]f32 {
    return polar(@sqrt(rngFloat(0, 1)) * ROTUNDA_SPOT_R, rngFloat(0, 2.0 * std.math.pi));
}

// A clear piazza spot, preferably away from the player.
fn piazzaSpot() [2]f32 {
    var spot: [2]f32 = .{ 0, 80 };
    var tries: usize = 0;
    while (tries < 16) : (tries += 1) {
        const x = rngFloat(-24, 24);
        const y = rngFloat(52, 84);
        if (!pigeonGround(x, y, false) or !spotClear(x, y, 0.4)) continue;
        spot = .{ x, y };
        if ((x - px) * (x - px) + (y - py) * (y - py) > 64) break;
    }
    return spot;
}

fn flyTo(b: *Bird, x: f32, y: f32, z: f32, speed: f32) void {
    b.mode = .fly;
    b.tx = x;
    b.ty = y;
    b.tz = z;
    b.speed = speed;
}

// Arcs start from where the bird is. A climbing arc ends at z_end; a level
// one ends after `ms`.
fn circleAround(b: *Bird, cx: f32, cy: f32, speed: f32, ms: i32, climb: f32, z_end: f32) void {
    const dx = b.x - cx;
    const dy = b.y - cy;
    b.mode = .circle;
    b.cx = cx;
    b.cy = cy;
    b.r = @max(1.0, @sqrt(dx * dx + dy * dy));
    b.ang = std.math.atan2(dy, dx);
    b.spin = speed / b.r;
    b.timer_ms = ms;
    b.climb = climb;
    b.z_end = z_end;
}

fn land(b: *Bird) void {
    b.mode = .ground;
    b.z = floorAt(b.x, b.y);
    b.timer_ms = rngRange(6000, 20000);
    b.peck_ms = 0;
}

fn rotundaPigeons() usize {
    var n: usize = 0;
    for (birds) |b| {
        if (b.active and b.kind == .pigeon and inRotunda(b.x, b.y) and b.z < WALL_H) n += 1;
    }
    return n;
}

fn takeOff(b: *Bird) void {
    b.leg = 0;
    b.glide = false;
    if (inRotunda(b.x, b.y)) {
        if (rngNext() % 3 != 0) {
            // Spiral up and out through the oculus.
            b.route = .out_oculus;
            const p = polar(SPIRAL_R, std.math.atan2(b.y, b.x));
            flyTo(b, p[0], p[1], 3.5, PIGEON_SPEED);
        } else {
            b.route = .hop;
            const s = rotundaSpot();
            b.lx = s[0];
            b.ly = s[1];
            flyTo(b, (b.x + s[0]) * 0.5, (b.y + s[1]) * 0.5, 2.5, PIGEON_SPEED * 0.8);
        }
        return;
    }
    // Climb away from the player, or straight up if a wall is in the way.
    b.route = .piazza;
    var dx = b.x - px;
    var dy = b.y - py;
    const d = @sqrt(dx * dx + dy * dy);
    if (d > 0.01) {
        dx /= d;
        dy /= d;
    } else {
        dx = b.hx;
        dy = b.hy;
    }
    var cx = b.x + dx * 2.5;
    var cy = b.y + dy * 2.5;
    if (!lineClear(b.x, b.y, cx, cy)) {
        cx = b.x;
        cy = b.y;
    }
    flyTo(b, cx, cy, CRUISE_Z, PIGEON_SPEED);
}

// Called when a leg ends; starts the next one.
fn nextLeg(b: *Bird) void {
    b.leg += 1;
    const jitter = polar(rngFloat(0, 0.6), rngFloat(0, 2.0 * std.math.pi));
    switch (b.route) {
        .hop => switch (b.leg) {
            1 => flyTo(b, b.lx, b.ly, floorAt(b.lx, b.ly), PIGEON_SPEED * 0.7),
            else => land(b),
        },
        .piazza => switch (b.leg) {
            1 => {
                // Wheel around a point off to one side.
                const side: f32 = if ((rngNext() & 1) == 0) 1 else -1;
                const spin = if (side > 0) PIGEON_SPEED else -PIGEON_SPEED;
                circleAround(b, b.x - b.hy * 7 * side, b.y + b.hx * 7 * side, spin, rngRange(2500, 6000), 0, 0);
            },
            2 => {
                const want_in = (rotundaPigeons() < 5 and rngNext() % 2 == 0) or rngNext() % 8 == 0;
                if (want_in) {
                    b.route = .in_oculus;
                    b.leg = 0;
                    flyTo(b, jitter[0], jitter[1], OCULUS_ABOVE_Z, PIGEON_SPEED);
                    return;
                }
                const s = piazzaSpot();
                b.lx = s[0];
                b.ly = s[1];
                // Glide down the last few metres toward the spot when the
                // way is clear, otherwise drop straight onto it.
                var ux = s[0] - b.x;
                var uy = s[1] - b.y;
                const d = @max(0.01, @sqrt(ux * ux + uy * uy));
                ux /= d;
                uy /= d;
                var ax = s[0] - ux * 3;
                var ay = s[1] - uy * 3;
                if (!lineClear(ax, ay, s[0], s[1])) {
                    ax = s[0];
                    ay = s[1];
                }
                flyTo(b, ax, ay, CRUISE_Z, PIGEON_SPEED);
            },
            3 => flyTo(b, b.lx, b.ly, floorAt(b.lx, b.ly), PIGEON_SPEED * 0.7),
            else => land(b),
        },
        .out_oculus => switch (b.leg) {
            1 => circleAround(b, 0, 0, PIGEON_SPEED * 0.9, 0, 0.025, 15),
            2 => flyTo(b, jitter[0], jitter[1], OCULUS_BELOW_Z, PIGEON_SPEED),
            3 => flyTo(b, jitter[0], jitter[1], OCULUS_ABOVE_Z, PIGEON_SPEED * 0.8),
            4 => flyTo(b, rngFloat(-12, 12), 62, CRUISE_Z + 2, PIGEON_SPEED),
            else => {
                b.route = .piazza;
                b.leg = 0;
                nextLeg(b);
            },
        },
        .in_oculus => switch (b.leg) {
            1 => flyTo(b, jitter[0], jitter[1], OCULUS_BELOW_Z, PIGEON_SPEED * 0.8),
            2 => {
                const p = polar(SPIRAL_R, rngFloat(0, 2.0 * std.math.pi));
                flyTo(b, p[0], p[1], 12, PIGEON_SPEED);
            },
            3 => circleAround(b, 0, 0, -PIGEON_SPEED * 0.9, 0, -0.03, 3),
            4 => {
                const s = rotundaSpot();
                b.lx = s[0];
                b.ly = s[1];
                flyTo(b, s[0], s[1], floorAt(s[0], s[1]), PIGEON_SPEED * 0.7);
            },
            else => land(b),
        },
        // Swifts loop forever: circle under the dome, out through the
        // oculus, circle over the building, and back in.
        .swift => {
            b.leg %= 8;
            switch (b.leg) {
                0 => circleAround(b, 0, 0, swiftSpin(), rngRange(4000, 12000), 0, 0),
                1, 6 => flyTo(b, jitter[0], jitter[1], OCULUS_BELOW_Z, SWIFT_SPEED),
                2, 5 => flyTo(b, jitter[0], jitter[1], OCULUS_ABOVE_Z, SWIFT_SPEED),
                3 => {
                    const p = outsideSwiftSpot();
                    flyTo(b, p[0], p[1], p[2], SWIFT_SPEED);
                },
                4 => circleAround(b, 0, OUTSIDE_CY, swiftSpin(), rngRange(5000, 14000), 0, 0),
                else => {
                    const p = insideSwiftSpot();
                    flyTo(b, p[0], p[1], p[2], SWIFT_SPEED);
                },
            }
        },
    }
}

fn updateBirds() void {
    for (&birds, 0..) |*b, i| {
        if (!b.active) continue;
        switch (b.mode) {
            .ground => {
                walkPigeon(b);
                continue;
            },
            .fly => {
                const dx = b.tx - b.x;
                const dy = b.ty - b.y;
                const dz = b.tz - b.z;
                const d = @sqrt(dx * dx + dy * dy + dz * dz);
                const flat = @sqrt(dx * dx + dy * dy);
                if (flat > d * 0.3 and flat > 1e-4) {
                    b.hx = dx / flat;
                    b.hy = dy / flat;
                }
                b.glide = dz < -0.3 * d;
                if (d <= b.speed) {
                    b.x = b.tx;
                    b.y = b.ty;
                    b.z = b.tz;
                    nextLeg(b);
                } else {
                    const k = b.speed / d;
                    b.x += dx * k;
                    b.y += dy * k;
                    b.z += dz * k;
                }
            },
            .circle => {
                b.ang += b.spin;
                b.x = b.cx + b.r * @cos(b.ang);
                b.y = b.cy + b.r * @sin(b.ang);
                const dir: f32 = if (b.spin > 0) 1 else -1;
                b.hx = -@sin(b.ang) * dir;
                b.hy = @cos(b.ang) * dir;
                b.glide = b.climb <= 0;
                var done = false;
                if (b.climb != 0) {
                    b.z += b.climb;
                    done = if (b.climb > 0) b.z >= b.z_end else b.z <= b.z_end;
                } else {
                    b.timer_ms -= STEP;
                    done = b.timer_ms <= 0;
                }
                if (done) nextLeg(b);
            },
        }
        // Swifts flicker their wings in bursts between glides; pigeons flap
        // when climbing or level and hold a V when gliding down or wheeling.
        if (b.kind == .swift) b.glide = @mod(@divTrunc(anim_ms + @as(i32, @intCast(i)) * 137, 260), 3) != 0;
        if (!b.glide) b.flap += if (b.kind == .swift) 0.9 else 0.5;
        if (b.flap > 2.0 * std.math.pi) b.flap -= 2.0 * std.math.pi;
    }
}

fn walkPigeon(b: *Bird) void {
    const dx = b.x - px;
    const dy = b.y - py;
    if (dx * dx + dy * dy < STARTLE_DIST * STARTLE_DIST and @abs(pz - b.z) < 2.0) {
        takeOff(b);
        return;
    }
    b.timer_ms -= STEP;
    if (b.timer_ms <= 0) {
        if (rngNext() % 3 == 0) {
            takeOff(b);
            return;
        }
        b.timer_ms = rngRange(4000, 12000);
    }
    if (b.peck_ms > 0) {
        b.peck_ms -= STEP;
        return;
    }
    if (rngNext() % 90 == 0) {
        b.peck_ms = rngRange(300, 900);
        return;
    }
    if (rngNext() % 70 == 0) {
        const a = std.math.atan2(b.hy, b.hx) + rngFloat(-1.5, 1.5);
        b.hx = @cos(a);
        b.hy = @sin(a);
    }
    var x = b.x;
    var y = b.y;
    const moved = tryMove(&x, &y, b.hx * PIGEON_WALK, b.hy * PIGEON_WALK, PIGEON_R, b.z);
    if (!moved or !pigeonGround(x, y, inRotunda(b.x, b.y))) {
        b.hx = -b.hx;
        b.hy = -b.hy;
        return;
    }
    b.x = x;
    b.y = y;
    b.z = floorAt(x, y);
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

// Rain

// Each game opens in a shower that has been falling for a while, so the
// floor under the oculus is already wet.
fn resetRain() void {
    rain_rng = (rng_state ^ 0x6C8E_9CF5) | 1;
    raining = true;
    weather_ms = SHOWER_MS;
    rain = 1;
    puddle = 0.6;
    wet_out = 0.7;
    for (&oculus_drops) |*d| spawnOculusDrop(d, true);
    for (&open_drops) |*d| spawnOpenDrop(d, true);
    splashes = [_]Splash{.{}} ** MAX_SPLASHES;
    splash_next = 0;
}

fn setRaining(on: bool) void {
    raining = on;
    weather_ms = if (on) SHOWER_MS else DRY_SPELL_MS;
}

fn rainNext() u32 {
    rain_rng ^= rain_rng << 13;
    rain_rng ^= rain_rng >> 17;
    rain_rng ^= rain_rng << 5;
    return rain_rng;
}

fn rainFloat(lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * @as(f32, @floatFromInt(rainNext() & 0xFFFF)) / 65535.0;
}

// Drops past the share the rain's strength allows stay hidden, so showers
// thicken and thin out rather than switching on and off.
fn dropShown(i: usize, n: usize) bool {
    return @as(f32, @floatFromInt(i)) < rain * @as(f32, @floatFromInt(n));
}

// A drop somewhere in the column under the oculus: anywhere along it when
// the rain starts, otherwise at the top.
fn spawnOculusDrop(d: *Drop, anywhere: bool) void {
    const p = polar(@sqrt(rainFloat(0, 1)) * (OCULUS_R - 0.1), rainFloat(0, 2.0 * std.math.pi));
    const floor = floorAt(p[0], p[1]);
    d.* = .{ .x = p[0], .y = p[1], .z = if (anywhere) rainFloat(floor, RAIN_TOP) else RAIN_TOP - rainFloat(0, RAIN_FALL) };
}

// A drop over open ground near the player. The piazza is the only open
// ground, so a player deep under cover has none.
fn spawnOpenDrop(d: *Drop, anywhere: bool) void {
    const y0 = @max(py - OPEN_RAIN_HALF, PORTICO_FRONT);
    const y1 = py + OPEN_RAIN_HALF;
    if (y0 >= y1) {
        d.z = DEAD_Z;
        return;
    }
    const x = px + rainFloat(-OPEN_RAIN_HALF, OPEN_RAIN_HALF);
    const y = rainFloat(y0, y1);
    const floor = floorAt(x, y);
    d.* = .{ .x = x, .y = y, .z = floor + if (anywhere) rainFloat(0, OPEN_RAIN_H) else OPEN_RAIN_H - rainFloat(0, RAIN_FALL) };
}

fn addSplash(x: f32, y: f32, z: f32) void {
    splashes[splash_next] = .{ .x = x, .y = y, .z = z, .age_ms = 0, .seed = rainNext() };
    splash_next = (splash_next + 1) % MAX_SPLASHES;
}

fn updateRain() void {
    weather_ms -= STEP;
    if (weather_ms <= 0) setRaining(!raining);
    rain = if (raining) @min(1.0, rain + RAIN_FADE) else @max(0.0, rain - RAIN_FADE);
    puddle = std.math.clamp(puddle + rain * PUDDLE_FILL - puddle * PUDDLE_DRAIN, 0.0, 1.0);
    // Paving in the open soaks quickly and dries slowly.
    wet_out += (rain - wet_out) * @as(f32, if (rain > wet_out) 0.004 else 0.0008);

    for (&oculus_drops, 0..) |*d, i| {
        d.z -= RAIN_FALL;
        const floor = floorAt(d.x, d.y);
        if (d.z > floor) continue;
        if (dropShown(i, MAX_OCULUS_DROPS)) addSplash(d.x, d.y, floor);
        spawnOculusDrop(d, false);
    }
    for (&open_drops, 0..) |*d, i| {
        // Keep the open rain centred on the player as they walk.
        if (d.z == DEAD_Z or @abs(d.x - px) > OPEN_RAIN_HALF + 1.0 or @abs(d.y - py) > OPEN_RAIN_HALF + 1.0) {
            spawnOpenDrop(d, true);
            continue;
        }
        d.z -= RAIN_FALL;
        const floor = floorAt(d.x, d.y);
        if (d.z > floor) continue;
        const dx = d.x - px;
        const dy = d.y - py;
        if (dropShown(i, MAX_OPEN_DROPS) and dx * dx + dy * dy < 12.0 * 12.0) addSplash(d.x, d.y, floor);
        spawnOpenDrop(d, false);
    }
    for (&splashes) |*s| {
        if (s.age_ms < SPLASH_MS) s.age_ms += STEP;
    }
}

// Lighting

fn sunDir() [3]f32 {
    const az = SUN_AZ0 + @as(f32, @floatFromInt(time_ms)) * SUN_DRIFT_PER_MS;
    const ce = @cos(SUN_ELEVATION);
    return .{ ce * @cos(az), ce * @sin(az), @sin(SUN_ELEVATION) };
}

var sun: [3]f32 = .{ 0, -1, 0 };

// How strongly the sunbeam through the oculus lights a point, 0 to 1.
fn beamAt(x: f32, y: f32, z: f32) f32 {
    const s = sunDir();
    if (z >= ZTOP) return 0;
    const k = (ZTOP - z) / s[2];
    const tx = x + s[0] * k;
    const ty = y + s[1] * k;
    const d2 = tx * tx + ty * ty;
    if (d2 >= OCULUS_R * OCULUS_R) return 0;
    if (x * x + y * y > (R + 5) * (R + 5) or y > PORTICO_BACK) return 0;
    return std.math.clamp((OCULUS_R - @sqrt(d2)) / 0.5, 0.0, 1.0);
}

fn beamAtCached(x: f32, y: f32, z: f32) f32 {
    if (z >= ZTOP) return 0;
    const k = (ZTOP - z) / sun[2];
    const tx = x + sun[0] * k;
    const ty = y + sun[1] * k;
    const d2 = tx * tx + ty * ty;
    if (d2 >= OCULUS_R * OCULUS_R) return 0;
    if (x * x + y * y > (R + 5) * (R + 5) or y > PORTICO_BACK) return 0;
    return std.math.clamp((OCULUS_R - @sqrt(d2)) / 0.5, 0.0, 1.0);
}

const Region = enum { rotunda, corridor, portico, piazza };

fn regionAt(x: f32, y: f32) Region {
    if (y >= PORTICO_FRONT) return .piazza;
    if (y >= 26.5) return .portico;
    if (x * x + y * y < R * R or y < @sqrt(R * R - DOOR_HALF * DOOR_HALF)) return .rotunda;
    return .corridor;
}

// Cloud dims the daylight and, more, the sun, for the frame being drawn.
var day_light: f32 = 1;
var sun_k: f32 = 1;

fn ambientAt(x: f32, y: f32) f32 {
    const light: f32 = switch (regionAt(x, y)) {
        .piazza => 1.0,
        .portico => 0.42 + 0.4 * std.math.clamp((y - PORTICO_BACK) / (PORTICO_FRONT - PORTICO_BACK), 0.0, 1.0),
        .corridor => 0.4,
        .rotunda => 0.36 + 0.2 * (1.0 - @min(1.0, @sqrt(x * x + y * y) / R)),
    };
    return light * day_light;
}

const WARM: Rgb = .{ 1.0, 0.9, 0.72 };

fn lit(albedo: Rgb, light: f32, beam: f32) Rgb {
    return albedo * splat(light) + albedo * WARM * splat(beam * 1.05 * sun_k);
}

fn splat(v: f32) Rgb {
    return @splat(v);
}

fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    return a + (b - a) * splat(t);
}

fn frac(v: f32) f32 {
    return v - @floor(v);
}

fn hash2(x: i32, y: i32) u32 {
    var h: u32 = @bitCast(x *% 374761393 +% y *% 668265263);
    h = (h ^ (h >> 13)) *% 1274126177;
    return h ^ (h >> 16);
}

fn hashf(x: i32, y: i32) f32 {
    return @as(f32, @floatFromInt(hash2(x, y) & 0xFFFF)) / 65535.0;
}

fn cell(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@floor(v), -1.0e6, 1.0e6));
}

fn valueNoise(x: f32, y: f32) f32 {
    const ix = cell(x);
    const iy = cell(y);
    const fx = frac(x);
    const fy = frac(y);
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    const a = hashf(ix, iy);
    const b = hashf(ix + 1, iy);
    const c = hashf(ix, iy + 1);
    const d = hashf(ix + 1, iy + 1);
    return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy;
}

fn fog(c: Rgb, t: f32, outdoor: bool) Rgb {
    // Rain thickens the haze over the piazza and turns it grey.
    if (outdoor) return mix(c, mix(.{ 0.82, 0.8, 0.76 }, .{ 0.6, 0.62, 0.65 }, rain), std.math.clamp(t / (260.0 - 170.0 * rain), 0.0, 0.45 + 0.2 * rain));
    return c * splat(std.math.clamp(1.0 - t * 0.008, 0.45, 1.0));
}

// Materials

const MARBLE_WHITE: Rgb = .{ 0.9, 0.88, 0.84 };
const GIALLO: Rgb = .{ 0.86, 0.73, 0.46 };
const PORPHYRY: Rgb = .{ 0.5, 0.2, 0.22 };
const SERPENTINE: Rgb = .{ 0.26, 0.4, 0.3 };
const GRANITE_GREY: Rgb = .{ 0.56, 0.56, 0.57 };
const GRANITE_PINK: Rgb = .{ 0.74, 0.53, 0.5 };
const TRAVERTINE: Rgb = .{ 0.85, 0.79, 0.65 };
const BRONZE: Rgb = .{ 0.5, 0.37, 0.2 };

fn speckle(c: Rgb, u: f32, v: f32, amount: f32) Rgb {
    const n = hashf(cell(u), cell(v));
    return c * splat(1.0 - amount + n * amount * 2.0);
}

fn wallAlbedo(s: Seg, u: f32, z: f32, hx: f32, hy: f32) Rgb {
    return switch (s.mat) {
        .rotunda => rotundaWall((std.math.atan2(hy, hx) + std.math.pi) * R, z, false),
        .niche => rotundaWall(u, z, true),
        .corridor => bronzeDoor(u, z),
        .portico => travertineWall(u, z),
        .granite_grey => columnShaft(u, z, GRANITE_GREY),
        .granite_pink => columnShaft(u, z, GRANITE_PINK),
        .giallo => columnShaft(u, z, GIALLO),
        .facade => facade(u, z, s.variant),
        .obelisk => obelisk(u, z),
        .terrace_step, .apse_step => stepFace(s.mat, u, z),
    };
}

// Faces of steps and ramp sides; h is the height above the lower floor.
fn stepFace(mat: Mat, u: f32, h: f32) Rgb {
    if (mat == .apse_step) {
        if (frac(h / 0.3) < 0.12) return MARBLE_WHITE * splat(0.92);
        return speckle(GIALLO, u * 16, h * 16, 0.07);
    }
    const row = cell(h / 0.5);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 0.6;
    if (frac(h / 0.5) < 0.08 or frac((u + off) / 1.2) < 0.03) return TRAVERTINE * splat(0.66);
    return speckle(TRAVERTINE * splat(0.88), (u + off) / 1.2, @floatFromInt(row), 0.06);
}

fn rotundaWall(u: f32, z: f32, recess: bool) Rgb {
    if (z < 0.35) return .{ 0.38, 0.31, 0.31 };
    if (z < 6.4) {
        const pu = frac(u / 3.4) * 3.4;
        var c: Rgb = undefined;
        if (pu < 0.7) {
            if (z > 5.7) {
                c = if (frac(u * 3.0 + z * 2.0) < 0.3) MARBLE_WHITE * splat(0.8) else MARBLE_WHITE;
            } else {
                c = if (frac(pu / 0.14) < 0.28) GIALLO * splat(0.82) else GIALLO;
            }
        } else {
            c = MARBLE_WHITE;
            const v = valueNoise(u * 1.7, z * 1.3);
            if (@abs(v - 0.5) < 0.035) c = .{ 0.62, 0.48, 0.56 };
            if (pu > 1.05 and pu < 3.05 and z > 1.2 and z < 5.3) {
                if (pu < 1.13 or pu > 2.97 or z < 1.28 or z > 5.22) {
                    c = .{ 0.74, 0.69, 0.6 };
                } else {
                    const bay = cell(u / 3.4);
                    c = if (@mod(bay, 2) == 0) PORPHYRY else SERPENTINE;
                    c = speckle(c, u * 18, z * 18, 0.08);
                }
            }
        }
        return if (recess) c * splat(0.8) else c;
    }
    if (z < 7.2) {
        if (z > 6.5 and z < 6.8) return .{ 0.55, 0.25, 0.25 };
        if (z > 6.85 and z < 7.0 and frac(u / 0.3) < 0.5) return .{ 0.68, 0.66, 0.62 };
        return MARBLE_WHITE;
    }
    if (z < 10.4) {
        const pu = frac((u + 1.7) / 3.4) * 3.4 - 1.7;
        const apu = @abs(pu);
        if (apu > 1.45) return .{ 0.8, 0.68, 0.46 };
        if (z > 9.7 and z < 10.1 and apu < 0.85 - (z - 9.7) * 2.0) return MARBLE_WHITE;
        if (apu < 0.75 and z > 7.7 and z < 9.7) {
            if (apu > 0.63 or z < 7.82 or z > 9.58) return MARBLE_WHITE;
            return .{ 0.48, 0.22, 0.24 };
        }
        return .{ 0.84, 0.8, 0.74 };
    }
    if (z < 10.5) return .{ 0.6, 0.58, 0.55 };
    return MARBLE_WHITE;
}

fn bronzeDoor(u: f32, z: f32) Rgb {
    if (z > 9.2) return travertineWall(u, z);
    const pu = frac(u / 1.8);
    const pv = frac(z / 2.2);
    if (pu < 0.08 or pu > 0.92 or pv < 0.07 or pv > 0.93) {
        if (frac(u / 0.3) < 0.18 and (pv < 0.07 or pv > 0.93)) return .{ 0.85, 0.7, 0.4 };
        return .{ 0.64, 0.5, 0.28 };
    }
    return speckle(BRONZE, u * 10, z * 10, 0.06);
}

fn travertineWall(u: f32, z: f32) Rgb {
    if (z < 0.5) return TRAVERTINE * splat(0.78);
    if (z > 9.6) {
        if (z < 9.75 or (z > 10.3 and z < 10.4)) return TRAVERTINE * splat(0.7);
        return .{ 0.9, 0.87, 0.8 };
    }
    if (frac(u / 4.5) < 0.12) return .{ 0.9, 0.85, 0.72 };
    const row = cell(z / 0.62);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 0.9;
    if (frac(z / 0.62) < 0.05 or frac((u + off) / 1.8) < 0.025) return TRAVERTINE * splat(0.76);
    return speckle(TRAVERTINE, (u + off) / 1.8, @floatFromInt(row), 0.05);
}

fn columnShaft(u: f32, z: f32, base: Rgb) Rgb {
    if (z < 0.6) return if (@abs(z - 0.3) < 0.06) MARBLE_WHITE * splat(0.72) else MARBLE_WHITE;
    if (z < 9.4) return speckle(base, u * 30, z * 30, 0.07);
    if (z < 10.3) {
        const leaf = frac(u * 2.5) - 0.5;
        const zz = frac((z - 9.4) / 0.3);
        return if (leaf * leaf * 4.0 > zz) MARBLE_WHITE * splat(0.7) else MARBLE_WHITE;
    }
    if (frac((z - 10.3) / 0.23) < 0.12) return TRAVERTINE * splat(0.72);
    return .{ 0.88, 0.84, 0.74 };
}

fn facade(u: f32, z: f32, variant: u8) Rgb {
    const wall = FACADE_COLORS[variant % FACADE_COLORS.len] * splat(0.9 + 0.1 * valueNoise(u * 0.6, z * 0.5));
    if (z < 0.4) return TRAVERTINE * splat(0.8);
    if (z > 10.4) return if (z < 10.55) Rgb{ 0.3, 0.2, 0.15 } else Rgb{ 0.45, 0.3, 0.2 };
    if (z < 3.6) {
        const bay = frac(u / 3.6) * 3.6;
        const dx = bay - 1.8;
        const top = 2.4 + @sqrt(@max(0.0, 1.0 - dx * dx)) * 0.6;
        if (@abs(dx) < 1.0 and z < top) {
            const shop = (hash2(cell(u / 3.6), variant) & 3) == 0;
            return if (shop) Rgb{ 0.55, 0.38, 0.18 } else Rgb{ 0.1, 0.09, 0.09 };
        }
        if (@abs(dx) < 1.15 and z < top + 0.15) return TRAVERTINE;
        return wall * splat(0.94);
    }
    if (z < 3.85) return .{ 0.9, 0.86, 0.76 };
    const zf = @mod(z - 3.85, 3.1);
    const bay = frac(u / 3.0) * 3.0;
    if (zf > 0.6 and zf < 0.7 and bay > 0.9 and bay < 2.1) return .{ 0.92, 0.9, 0.84 };
    if (zf > 0.7 and zf < 2.5) {
        if (bay > 1.0 and bay < 2.0) {
            if (bay < 1.06 or bay > 1.94 or zf > 2.44) return .{ 0.92, 0.9, 0.84 };
            return if (@abs(bay - 1.5) < 0.03) Rgb{ 0.8, 0.78, 0.72 } else Rgb{ 0.13, 0.15, 0.19 };
        }
        if ((bay > 0.62 and bay < 1.0) or (bay > 2.0 and bay < 2.38)) {
            return if (frac(zf / 0.12) < 0.3) Rgb{ 0.17, 0.3, 0.21 } else Rgb{ 0.24, 0.42, 0.3 };
        }
    }
    return wall;
}

fn obelisk(u: f32, z: f32) Rgb {
    if (z > 10.4) return .{ 0.86, 0.7, 0.32 };
    if (z < 1.2) return TRAVERTINE * splat(0.85);
    const face = frac(u / 1.343);
    if (face > 0.3 and face < 0.7) {
        const gx = cell((face - 0.3) / 0.1);
        const gz = cell(z / 0.35);
        if ((hash2(gx + cell(u / 1.343) * 7, gz) & 3) == 0) return .{ 0.4, 0.22, 0.2 };
    }
    return speckle(.{ 0.62, 0.37, 0.32 }, u * 24, z * 24, 0.08);
}

fn onTerrace(x: f32, y: f32) bool {
    return y >= PORTICO_FRONT and y < TERRACE_Y and @abs(x) <= PORTICO_HALF;
}

fn floorAlbedo(x: f32, y: f32) Rgb {
    switch (sectorAt(x, y)) {
        .cordonata => return cordonata(x, y),
        .apse_ramp => return apseRamp(x, y),
        else => {},
    }
    if (onTerrace(x, y)) return porticoFloor(x, y);
    return switch (regionAt(x, y)) {
        .rotunda => drainHole(x, y) orelse pantheonFloor(x, y),
        .corridor => corridorFloor(x, y),
        .portico => porticoFloor(x, y),
        .piazza => piazzaFloor(x, y),
    };
}

// Alternating squares holding circles and squares, after the original
// granite, porphyry, and giallo antico pavement.
fn pantheonFloor(x: f32, y: f32) Rgb {
    const size: f32 = 2.4;
    const gx = x / size + 0.5;
    const gy = y / size + 0.5;
    const fx = frac(gx) - 0.5;
    const fy = frac(gy) - 0.5;
    const i = cell(gx);
    const j = cell(gy);
    if (@abs(fx) > 0.485 or @abs(fy) > 0.485) return .{ 0.66, 0.62, 0.56 };
    if (@mod(i + j, 2) == 0) {
        const r2 = fx * fx + fy * fy;
        if (r2 < 0.33 * 0.33) return speckle(PORPHYRY, x * 14, y * 14, 0.07);
        if (r2 < 0.37 * 0.37) return GIALLO;
        return speckle(GRANITE_GREY, x * 14, y * 14, 0.08);
    }
    const m = @max(@abs(fx), @abs(fy));
    if (m < 0.25) return speckle(if (@mod(i, 2) == 0) SERPENTINE else PORPHYRY, x * 14, y * 14, 0.07);
    if (m < 0.29) return GRANITE_GREY * splat(0.8);
    return GIALLO;
}

fn corridorFloor(x: f32, y: f32) Rgb {
    if (@abs(x) > DOOR_HALF - 0.4 or frac(y / 1.75) < 0.06) return MARBLE_WHITE * splat(0.9);
    return speckle(PORPHYRY, x * 12, y * 12, 0.06);
}

fn porticoFloor(x: f32, y: f32) Rgb {
    const row = cell(y / 1.5);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 1.5;
    const sx = (x + off) / 3.0;
    if (frac(y / 1.5) < 0.025 or frac(sx) < 0.012) return TRAVERTINE * splat(0.68);
    return TRAVERTINE * splat(0.9 + 0.12 * hashf(cell(sx), row));
}

// Brick between travertine ribs that give a grip on the slope.
fn cordonata(x: f32, y: f32) Rgb {
    const rib = frac((y - TERRACE_Y) / 0.9);
    if (rib < 0.14) return TRAVERTINE * splat(if (rib < 0.04) 0.7 else 0.95);
    if (@abs(x) > RAMP_HALF - 0.45) return TRAVERTINE * splat(0.86);
    const row = cell(y / 0.15);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 0.15;
    if (frac(y / 0.15) < 0.14 or frac((x + off) / 0.3) < 0.07) return .{ 0.5, 0.45, 0.4 };
    return Rgb{ 0.62, 0.33, 0.22 } * splat(0.85 + 0.25 * hashf(cell((x + off) / 0.3), row));
}

fn apseRamp(x: f32, y: f32) Rgb {
    if (frac((y + APSE_LIP) / 0.7) < 0.12) return MARBLE_WHITE * splat(0.9);
    if (@abs(x) > APSE_RAMP_HALF - 0.35) return speckle(PORPHYRY, x * 14, y * 14, 0.07);
    return speckle(GIALLO, x * 14, y * 14, 0.07);
}

fn piazzaFloor(x: f32, y: f32) Rgb {
    const ox = x - OBELISK_X;
    const oy = y - OBELISK_Y;
    const r2 = ox * ox + oy * oy;
    if (r2 < BASIN_R * BASIN_R) {
        if (r2 > (BASIN_R - 0.6) * (BASIN_R - 0.6)) return .{ 0.88, 0.84, 0.74 };
        const ripple = @sin(@sqrt(r2) * 5.0 - @as(f32, @floatFromInt(anim_ms)) * 0.004);
        return Rgb{ 0.28, 0.48, 0.56 } + splat(ripple * 0.04);
    }
    const u = (x + y) * 0.7071 / 0.42;
    const v = (x - y) * 0.7071 / 0.42;
    if (frac(u) < 0.1 or frac(v) < 0.1) return .{ 0.22, 0.21, 0.2 };
    return Rgb{ 0.4, 0.38, 0.36 } * splat(0.85 + 0.3 * hashf(cell(u), cell(v)));
}

// The drains: a ring of small holes cut through the paving, each in a
// darker collar of stone.
fn drainHole(x: f32, y: f32) ?Rgb {
    const r2 = x * x + y * y;
    const band = DRAIN_R + DRAIN_HOLE * 1.6;
    if (r2 > band * band or r2 < (DRAIN_R - DRAIN_HOLE * 1.6) * (DRAIN_R - DRAIN_HOLE * 1.6)) return null;
    const pitch = 2.0 * std.math.pi / DRAIN_COUNT;
    const a = @round(std.math.atan2(y, x) / pitch) * pitch;
    const dx = x - DRAIN_R * @cos(a);
    const dy = y - DRAIN_R * @sin(a);
    const d2 = dx * dx + dy * dy;
    if (d2 < DRAIN_HOLE * DRAIN_HOLE) return .{ 0.04, 0.04, 0.05 };
    if (d2 < DRAIN_HOLE * DRAIN_HOLE * 2.5) return GRANITE_GREY * splat(0.55);
    return null;
}

// Wet stone is darker and, seen at a low angle, gives back the grey sky.
fn wetten(c: Rgb, wet: f32, vz: f32) Rgb {
    const grazing = 1.0 - std.math.clamp(-vz * 1.6, 0.0, 1.0);
    return mix(c, mix(c * splat(0.52), Rgb{ 0.44, 0.46, 0.5 } * splat(day_light), 0.5 * grazing), wet);
}

// Water on the rotunda floor spreads a little past the rain under the
// oculus. As the drains take it away the wet patch shrinks back to them.
// The water mirrors the oculus where the reflected view ray passes out
// through it, and while it rains, drops ring the surface.
fn wetRotunda(c: Rgb, x: f32, y: f32, rx: f32, ry: f32, vz: f32, t: f32) Rgb {
    const reach = DRAIN_R + (WET_REACH - DRAIN_R) * std.math.clamp((puddle - 0.05) * 1.6, 0.0, 1.0);
    var r = @sqrt(x * x + y * y);
    // A ragged edge; the noise moves it by at most 0.45 m.
    if (r > reach + 0.45) return c;
    if (r > reach - 0.95) r += (valueNoise(x * 1.3, y * 1.3) - 0.5) * 0.9;
    const wet = std.math.clamp((reach - r) / 0.5, 0.0, 1.0) * std.math.clamp(puddle * 4.0, 0.0, 1.0);
    if (wet <= 0) return c;
    var out = wetten(c, wet, vz);
    if (vz < -1e-3) {
        const k = ZTOP / -vz;
        const qx = x + rx * k;
        const qy = y + ry * k;
        if (qx * qx + qy * qy < OCULUS_R * OCULUS_R) {
            const grazing = 1.0 - std.math.clamp(-vz * 1.6, 0.0, 1.0);
            out = mix(out, skyColor(rx, ry, -vz), wet * (0.3 + 0.4 * grazing));
        }
    }
    // Rings smaller than a pixel are not worth drawing.
    if (rain > 0 and r < OCULUS_R and t < 16.0) {
        const gx = x * 2.5;
        const gy = y * 2.5;
        const ix = cell(gx);
        const iy = cell(gy);
        const h = hash2(ix, iy);
        if (@as(f32, @floatFromInt(h & 0xFF)) < rain * 200.0) {
            const cx = @as(f32, @floatFromInt(ix)) + 0.3 + 0.4 * hashf(iy, ix);
            const cy = @as(f32, @floatFromInt(iy)) + 0.3 + 0.4 * hashf(ix + 7, iy);
            const ring = frac(@as(f32, @floatFromInt(anim_ms)) * 0.0021 + @as(f32, @floatFromInt(h >> 16)) / 65536.0);
            const d = @sqrt((gx - cx) * (gx - cx) + (gy - cy) * (gy - cy));
            if (@abs(d - ring * 0.45) < 0.05) out += splat(0.22 * (1.0 - ring) * wet);
        }
    }
    return out;
}

// Rendering

var col_depth: [SCREEN_W]f32 = undefined;
var col_seg: [SCREEN_W]u16 = undefined;
var cols_left: usize = 0;
var seg_order: [MAX_SEGS]u16 = undefined;
var order_next: u16 = 0;
var stat_nodes: u32 = 0;
var stat_segs: u32 = 0;

// Step lines each column crosses before its wall, nearest first: the depth
// and the sector beyond.
var ev_n: [SCREEN_W]u8 = undefined;
var ev_depth: [SCREEN_W][MAX_EVENTS]f32 = undefined;
var ev_sec: [SCREEN_W][MAX_EVENTS]Sector = undefined;
var ev_seg: [SCREEN_W][MAX_EVENTS]u16 = undefined;

var cam_x: f32 = 0;
var cam_y: f32 = 0;
var cam_z: f32 = EYE_Z;
var cam_sec: Sector = .ground;
var cam_fx: f32 = 0;
var cam_fy: f32 = 1;
var cam_rx: f32 = 1;
var cam_ry: f32 = 0;
var horizon: f32 = BASE_HORIZON;

fn setCamera(x: f32, y: f32, z: f32, angle: f32, look_px: f32) void {
    horizon = BASE_HORIZON + look_px;
    cam_x = x;
    cam_y = y;
    cam_z = z;
    cam_sec = sectorAt(x, y);
    cam_fx = @cos(angle);
    cam_fy = @sin(angle);
    cam_rx = cam_fy;
    cam_ry = -cam_fx;
}

const Visit = struct { node: i16, draw: bool };

// Walks the BSP front to back from the camera. A node's near subtree is
// drawn before the walls on its splitter, and those before the far subtree.
// Each column keeps the first wall that reaches it, which is the nearest,
// and records the step lines it crosses on the way, in depth order.
fn castWalls() void {
    @memset(&col_seg, NO_SEG);
    @memset(&col_depth, std.math.inf(f32));
    @memset(&ev_n, 0);
    @memset(seg_order[0..seg_count], NO_SEG);
    cols_left = SCREEN_W;
    order_next = 0;
    stat_nodes = 0;
    stat_segs = 0;
    if (node_count == 0) return;
    var stack: [MAX_STACK]Visit = undefined;
    stack[0] = .{ .node = 0, .draw = false };
    var sp: usize = 1;
    var guard: usize = 0;
    while (sp > 0 and cols_left > 0 and guard < MAX_NODES * 3) : (guard += 1) {
        sp -= 1;
        const v = stack[sp];
        if (v.node < 0) continue;
        const n = nodes[@intCast(v.node)];
        if (v.draw) {
            var i: usize = n.first;
            while (i < n.first + n.count) : (i += 1) drawSegColumns(i);
            continue;
        }
        stat_nodes += 1;
        const front = sideOf(nodeLine(n), cam_x, cam_y) >= 0;
        if (sp + 3 > MAX_STACK) @trap();
        stack[sp] = .{ .node = if (front) n.back else n.front, .draw = false };
        stack[sp + 1] = .{ .node = v.node, .draw = true };
        stack[sp + 2] = .{ .node = if (front) n.front else n.back, .draw = false };
        sp += 3;
    }
}

fn drawSegColumns(i: usize) void {
    const s = segs[i];
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    // Walls only face their left side; step lines face both ways.
    const cam_left = dx * (cam_y - s.y1) - dy * (cam_x - s.x1) > 0;
    if (!cam_left and !s.portal) return;
    var ax = (s.x1 - cam_x) * cam_rx + (s.y1 - cam_y) * cam_ry;
    var az = (s.x1 - cam_x) * cam_fx + (s.y1 - cam_y) * cam_fy;
    var bx = (s.x2 - cam_x) * cam_rx + (s.y2 - cam_y) * cam_ry;
    var bz = (s.x2 - cam_x) * cam_fx + (s.y2 - cam_y) * cam_fy;
    if (az < NEAR and bz < NEAR) return;
    if (az < NEAR) {
        const t = (NEAR - az) / (bz - az);
        ax += (bx - ax) * t;
        az = NEAR;
    } else if (bz < NEAR) {
        const t = (NEAR - bz) / (az - bz);
        bx += (ax - bx) * t;
        bz = NEAR;
    }
    const sa = HALF_W + ax * FOCAL / az;
    const sb = HALF_W + bx * FOCAL / bz;
    const lo = std.math.clamp(@min(sa, sb), -1.0, HALF_W * 2.0 + 1.0);
    const hi = std.math.clamp(@max(sa, sb), -1.0, HALF_W * 2.0 + 1.0);
    const c0: usize = @intFromFloat(std.math.clamp(@ceil(lo - 0.5), 0.0, HALF_W * 2.0));
    const c1: usize = @intFromFloat(std.math.clamp(@ceil(hi - 0.5), 0.0, HALF_W * 2.0));
    if (c0 >= c1) return;
    if (seg_order[i] == NO_SEG) {
        seg_order[i] = order_next;
        order_next +|= 1;
        stat_segs += 1;
    }
    const ex = bx - ax;
    const ez = bz - az;
    var c = c0;
    while (c < c1) : (c += 1) {
        if (col_seg[c] != NO_SEG) continue;
        const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
        const den = ex - sl * ez;
        const t = if (@abs(den) < 1e-9) 0.0 else std.math.clamp((sl * az - ax) / den, 0.0, 1.0);
        if (s.portal) {
            const k = ev_n[c];
            if (k >= MAX_EVENTS) continue;
            ev_depth[c][k] = az + t * ez;
            ev_sec[c][k] = if (cam_left) s.back else s.front;
            ev_seg[c][k] = @intCast(i);
            ev_n[c] = k + 1;
            continue;
        }
        col_seg[c] = @intCast(i);
        col_depth[c] = az + t * ez;
        cols_left -= 1;
    }
}

fn putPixel(x: usize, y: usize, c: Rgb) void {
    const idx = ktx.HEADER_SIZE + (y * SCREEN_W + x) * 4;
    output_buf[idx] = toByte(c[0]);
    output_buf[idx + 1] = toByte(c[1]);
    output_buf[idx + 2] = toByte(c[2]);
    output_buf[idx + 3] = 0xFF;
}

fn readPixel(x: usize, y: usize) Rgb {
    const idx = ktx.HEADER_SIZE + (y * SCREEN_W + x) * 4;
    return .{
        @as(f32, @floatFromInt(output_buf[idx])) / 255.0,
        @as(f32, @floatFromInt(output_buf[idx + 1])) / 255.0,
        @as(f32, @floatFromInt(output_buf[idx + 2])) / 255.0,
    };
}

fn toByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

fn depthCode(t: f32) u16 {
    if (!(t < 2000.0)) return DEPTH_SKY;
    return @intFromFloat(@max(t, 0.0) * DEPTH_SCALE);
}

// Birds whose shadows can fall through the oculus this frame.
var beam_birds: [MAX_BIRDS]u8 = undefined;
var beam_bird_n: usize = 0;

fn findBeamBirds() void {
    beam_bird_n = 0;
    for (birds, 0..) |b, i| {
        if (!b.active or b.mode == .ground) continue;
        // Follow the sunlight from the bird back to the oculus plane; this
        // works for birds above the oculus too.
        const k = (ZTOP - b.z) / sun[2];
        const tx = b.x + sun[0] * k;
        const ty = b.y + sun[1] * k;
        const reach = OCULUS_R + PIGEON_SPAN * BIRD_SCALE;
        if (tx * tx + ty * ty >= reach * reach) continue;
        beam_birds[beam_bird_n] = @intCast(i);
        beam_bird_n += 1;
    }
}

// The sunbeam at a point, less any bird between it and the sun.
fn sunlit(x: f32, y: f32, z: f32) f32 {
    const beam = beamAtCached(x, y, z);
    if (beam <= 0) return 0;
    for (beam_birds[0..beam_bird_n]) |i| {
        if (birdShadow(birds[i], x, y, z)) return beam * 0.15;
    }
    return beam;
}

// Whether the bird's outline, wings spread, blocks the sun from a point.
fn birdShadow(b: Bird, x: f32, y: f32, z: f32) bool {
    const k = (b.z - z) / sun[2];
    if (k <= 0) return false;
    const ox = (x + sun[0] * k - b.x) / BIRD_SCALE;
    const oy = (y + sun[1] * k - b.y) / BIRD_SCALE;
    const along = ox * b.hx + oy * b.hy;
    const across = @abs(oy * b.hx - ox * b.hy);
    const span: f32 = if (b.kind == .swift) SWIFT_SPAN else PIGEON_SPAN;
    const len: f32 = if (b.kind == .swift) 0.2 else 0.32;
    if (@abs(along) < len * 0.5 and across < 0.06) return true;
    const half = span * 0.5;
    if (across >= half) return false;
    const t = across / half;
    // Swift wings sweep back into a crescent.
    const sweep: f32 = if (b.kind == .swift) -0.12 * t * t else 0;
    const base_chord: f32 = if (b.kind == .swift) 0.07 else 0.11;
    const chord = base_chord * (1.0 - 0.6 * t);
    return @abs(along - sweep) < chord;
}

const BeamRay = struct {
    wx: f32,
    wy: f32,
    wz: f32,
    e: f32,
    bx: f32,
    by: f32,
    bz: f32,
    len: f32,
};

var beam_ray: BeamRay = undefined;

fn prepareBeam() void {
    beam_ray = .{
        .wx = cam_x,
        .wy = cam_y,
        .wz = cam_z - ZTOP,
        .e = 0,
        .bx = -sun[0],
        .by = -sun[1],
        .bz = -sun[2],
        .len = ZTOP / sun[2],
    };
    beam_ray.e = beam_ray.bx * beam_ray.wx + beam_ray.by * beam_ray.wy + beam_ray.bz * beam_ray.wz;
}

// Dust glowing in the sunbeam: the view ray's closest approach to the beam
// axis, counted only in front of whatever the pixel hit.
fn beamGlow(rx: f32, ry: f32, vz: f32, t_hit: f32) f32 {
    const b = beam_ray;
    const a = rx * rx + ry * ry + vz * vz;
    const bb = rx * b.bx + ry * b.by + vz * b.bz;
    const d = rx * b.wx + ry * b.wy + vz * b.wz;
    const denom = a - bb * bb;
    if (denom < 1e-6) return 0;
    // The closest approach to the beam's axis, clamped to the stretch from
    // the oculus to the floor so the glow fades rather than stopping dead.
    const tb = std.math.clamp((a * b.e - bb * d) / denom, 0.0, b.len);
    const tv = (tb * bb - d) / a;
    if (tv <= 0 or tv >= t_hit) return 0;
    const qx = b.wx + tv * rx - tb * b.bx;
    const qy = b.wy + tv * ry - tb * b.by;
    const qz = b.wz + tv * vz - tb * b.bz;
    const d2 = qx * qx + qy * qy + qz * qz;
    if (d2 >= OCULUS_R * OCULUS_R) return 0;
    const f = 1.0 - @sqrt(d2) / OCULUS_R;
    return f * f * 0.32;
}

// Spray in the column of rain under the oculus: the more of the column a
// view ray crosses before it hits something, the paler it gets. Where a
// screen column's rays enter and leave the column in plan is the same for
// every row, so it is found once per screen column.
const MistSpan = struct { t0: f32 = 0, t1: f32 = 0, k: f32 = 0 };

fn mistSpan(rx: f32, ry: f32) MistSpan {
    if (rain <= 0) return .{};
    const a = rx * rx + ry * ry;
    const b = cam_x * rx + cam_y * ry;
    const c = cam_x * cam_x + cam_y * cam_y - OCULUS_R * OCULUS_R;
    const disc = b * b - a * c;
    if (disc <= 0) return .{};
    const root = @sqrt(disc);
    return .{ .t0 = @max(0.0, (-b - root) / a), .t1 = (-b + root) / a, .k = a };
}

fn rainMist(m: MistSpan, vz: f32, t_hit: f32) f32 {
    var t1 = @min(t_hit, m.t1);
    // Only between the floor and the oculus.
    if (vz > 1e-6) {
        t1 = @min(t1, (ZTOP - cam_z) / vz);
    } else if (vz < -1e-6) {
        t1 = @min(t1, -cam_z / vz);
    }
    if (t1 <= m.t0) return 0;
    return @min(0.35, (t1 - m.t0) * @sqrt(m.k + vz * vz) * 0.022 * rain);
}

fn skyColor(rx: f32, ry: f32, vz: f32) Rgb {
    const len = @sqrt(rx * rx + ry * ry + vz * vz);
    const el = std.math.clamp(vz / len, 0.0, 1.0);
    var c = mix(.{ 0.92, 0.84, 0.7 }, .{ 0.3, 0.52, 0.84 }, @sqrt(el));
    const sd = (rx * sun[0] + ry * sun[1] + vz * sun[2]) / len;
    if (sd > 0.97) c = mix(c, .{ 1.0, 0.98, 0.9 }, std.math.clamp((sd - 0.97) / 0.025, 0.0, 1.0));
    if (vz > 0.02) {
        const k = 1.0 / vz;
        const drift = @as(f32, @floatFromInt(anim_ms)) * 0.00005;
        const n = valueNoise(rx * k * 1.4 + drift, ry * k * 2.8) * 0.65 + valueNoise(rx * k * 4.0, ry * k * 6.0) * 0.35;
        const cloud = std.math.clamp((n - 0.55) * 3.0, 0.0, 1.0) * std.math.clamp(el * 4.0, 0.0, 1.0);
        c = mix(c, .{ 0.98, 0.95, 0.9 }, cloud * 0.8);
    }
    // Rain cloud: a flat grey, a little lighter overhead.
    return mix(c, mix(.{ 0.5, 0.52, 0.56 }, .{ 0.66, 0.68, 0.72 }, el), rain * 0.8);
}

// Coffer rows of the dome by elevation angle, each about as tall as one of
// its 28 bays is wide.
const COFFER_ROWS = [_]f32{ 0.06, 0.284, 0.499, 0.696, 0.868, 1.013 };

fn domeColor(qx: f32, qy: f32, rx: f32, ry: f32, vz: f32, t_base: f32, out_t: *f32) Rgb {
    const dz = vz * DOME_K;
    const a = rx * rx + ry * ry + dz * dz;
    const b = 2.0 * (qx * rx + qy * ry);
    const c = qx * qx + qy * qy - R * R;
    const disc = @max(0.0, b * b - 4.0 * a * c);
    const sv = (-b + @sqrt(disc)) / (2.0 * a);
    const hx = qx + sv * rx;
    const hy = qy + sv * ry;
    const hz = sv * dz;
    out_t.* = t_base + sv;
    const rho = @sqrt(hx * hx + hy * hy);
    if (rho < OCULUS_R) {
        out_t.* = std.math.inf(f32);
        return skyColor(rx, ry, vz);
    }
    const el = std.math.atan2(hz, rho);
    const light = 0.3 + 0.55 * (hz / R) * (hz / R);
    if (rho < OCULUS_R + 0.35) return Rgb{ 0.62, 0.47, 0.26 } * splat(light + 0.25);
    var albedo: Rgb = .{ 0.82, 0.79, 0.74 };
    if (el > COFFER_ROWS[0] and el < COFFER_ROWS[COFFER_ROWS.len - 1]) {
        var row: usize = 0;
        while (row + 2 < COFFER_ROWS.len and el > COFFER_ROWS[row + 1]) row += 1;
        const fv = (el - COFFER_ROWS[row]) / (COFFER_ROWS[row + 1] - COFFER_ROWS[row]);
        const fu = frac((std.math.atan2(hy, hx) + std.math.pi) / (2.0 * std.math.pi) * 28.0);
        const edge = @min(@min(fu, 1.0 - fu), @min(fv, 1.0 - fv));
        if (edge > 0.12) {
            // Stepped recesses: lower lips catch light from the oculus.
            const step: f32 = if (edge < 0.2) 0.86 else if (edge < 0.28) 0.74 else 0.64;
            const lower_lip = fv < @min(fu, 1.0 - fu);
            albedo = albedo * splat(if (lower_lip) step + 0.1 else step);
            const cu = fu - 0.5;
            const cv = fv - 0.5;
            if (cu * cu + cv * cv < 0.008) albedo = .{ 0.78, 0.62, 0.3 };
        }
    }
    return albedo * splat(light);
}

fn ceilingFlat(x: f32, y: f32) Rgb {
    if (y < 21.5) {
        // Half-domes over the niches.
        return MARBLE_WHITE * splat(if (frac(std.math.atan2(y, x) * 9.0) < 0.12) 0.72 else 0.84);
    }
    const bx = frac(x / 4.5);
    if (bx < 0.08 or bx > 0.92) return .{ 0.5, 0.37, 0.24 };
    if (frac(y / 1.5) < 0.12) return .{ 0.4, 0.3, 0.2 };
    return .{ 0.28, 0.2, 0.14 };
}

const BandKind = enum { floor, step, wall };

// A run of rows in one column, from `top` down to the band below it.
const Band = struct {
    top: f32,
    kind: BandKind,
    sec: Sector = .ground,
    near: f32 = NEAR,
    far: f32 = 0,
    seg: u16 = NO_SEG,
    base: f32 = 0,
};

fn project(z: f32, depth: f32) f32 {
    return horizon - (z - cam_z) * FOCAL / depth;
}

// Lighting for a vertical face seen from the camera at world point x, y.
fn faceLight(s: Seg, x: f32, y: f32, outdoor: bool) f32 {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const len = @sqrt(dx * dx + dy * dy);
    var nx = -dy / len;
    var ny = dx / len;
    if (nx * (cam_x - x) + ny * (cam_y - y) < 0) {
        nx = -nx;
        ny = -ny;
    }
    if (outdoor) return (0.62 + 0.5 * sun_k * @max(0.0, -(sun[0] * nx + sun[1] * ny)) + 0.08 * ny) * day_light;
    return ambientAt(x, y) * (0.8 + 0.22 * (0.6 * nx + 0.8 * ny));
}

fn segU(s: Seg, x: f32, y: f32) f32 {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    return s.u0 + ((x - s.x1) * dx + (y - s.y1) * dy) / @sqrt(dx * dx + dy * dy);
}

fn drawScene() void {
    sun = sunDir();
    sun_k = 1.0 - 0.6 * rain;
    day_light = 1.0 - 0.2 * rain;
    prepareBeam();
    findBeamBirds();
    castWalls();
    var c: usize = 0;
    while (c < SCREEN_W) : (c += 1) {
        const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
        const rx = cam_fx + sl * cam_rx;
        const ry = cam_fy + sl * cam_ry;
        const depth = col_depth[c];
        const si = col_seg[c];

        // Bands from the bottom of the screen up. Each step line ends the
        // floor in front of it and, where the far floor is higher, adds a
        // step face. Bands hidden below an earlier one are dropped.
        var bands: [MAX_EVENTS * 2 + 2]Band = undefined;
        var nb: usize = 0;
        var clip: f32 = @floatFromInt(SCREEN_H);
        var sec = cam_sec;
        var near: f32 = NEAR;
        var k: usize = 0;
        while (k < ev_n[c]) : (k += 1) {
            const d = ev_depth[c][k];
            const hx = cam_x + rx * d;
            const hy = cam_y + ry * d;
            const next = ev_sec[c][k];
            const z_here = planeZ(sec, hx, hy);
            const z_next = planeZ(next, hx, hy);
            const y_here = project(z_here, d);
            if (y_here < clip) {
                bands[nb] = .{ .top = y_here, .kind = .floor, .sec = sec, .near = near, .far = d };
                nb += 1;
                clip = y_here;
            }
            const y_next = project(z_next, d);
            if (y_next < clip) {
                bands[nb] = .{ .top = y_next, .kind = .step, .far = d, .seg = ev_seg[c][k], .base = @min(z_here, z_next) };
                nb += 1;
                clip = y_next;
            }
            sec = next;
            near = d;
        }
        var seg: Seg = undefined;
        var u: f32 = 0;
        var wx: f32 = 0;
        var wy: f32 = 0;
        var wall_light: f32 = 0;
        var outdoor_wall = false;
        if (si != NO_SEG) {
            seg = segs[si];
            wx = cam_x + rx * depth;
            wy = cam_y + ry * depth;
            u = segU(seg, wx, wy);
            outdoor_wall = regionAt(wx, wy) == .piazza;
            wall_light = faceLight(seg, wx, wy, outdoor_wall);
            const z_floor = planeZ(sec, wx, wy);
            const y_floor = project(z_floor, depth);
            if (y_floor < clip) {
                bands[nb] = .{ .top = y_floor, .kind = .floor, .sec = sec, .near = near, .far = depth };
                nb += 1;
                clip = y_floor;
            }
            const y_top = project(WALL_H, depth);
            if (y_top < clip) {
                bands[nb] = .{ .top = y_top, .kind = .wall, .far = depth, .base = z_floor };
                nb += 1;
            }
        } else if (horizon < clip) {
            bands[nb] = .{ .top = horizon, .kind = .floor, .sec = sec, .near = near, .far = 1000 };
            nb += 1;
        }

        const lift = WALL_H - cam_z;
        const mist = mistSpan(rx, ry);
        var bi: usize = 0;
        var y: usize = SCREEN_H;
        while (y > 0) {
            y -= 1;
            const yc = @as(f32, @floatFromInt(y)) + 0.5;
            const vz = (horizon - yc) / FOCAL;
            while (bi < nb and yc < bands[bi].top) bi += 1;
            var color: Rgb = undefined;
            var t_hit: f32 = undefined;
            if (bi == nb) {
                const t = lift / @max(vz, 1e-3);
                const hx = cam_x + rx * t;
                const hy = cam_y + ry * t;
                t_hit = t;
                if (hx * hx + hy * hy < R * R) {
                    color = domeColor(hx, hy, rx, ry, vz, t, &t_hit);
                    color = fog(color, t_hit, false);
                } else if (hy < PORTICO_FRONT) {
                    color = fog(ceilingFlat(hx, hy) * splat(ambientAt(hx, hy) * 0.85), t, false);
                } else {
                    color = skyColor(rx, ry, vz);
                    t_hit = std.math.inf(f32);
                }
            } else {
                const b = bands[bi];
                switch (b.kind) {
                    .wall => {
                        const z = cam_z + vz * depth;
                        // Piazza walls keep their doors and plinths at street level.
                        const zt = if (seg.mat == .facade or seg.mat == .obelisk) z - b.base else z;
                        const albedo = wallAlbedo(seg, u, zt, wx, wy);
                        if (outdoor_wall) {
                            color = fog(albedo * splat(wall_light), depth, true);
                        } else {
                            color = fog(lit(albedo, wall_light, sunlit(wx, wy, z)), depth, false);
                        }
                        t_hit = depth;
                    },
                    .step => {
                        const s = segs[b.seg];
                        const hx = cam_x + rx * b.far;
                        const hy = cam_y + ry * b.far;
                        const z = cam_z + vz * b.far;
                        const albedo = stepFace(s.mat, segU(s, hx, hy), z - b.base);
                        const outdoor = regionAt(hx, hy) == .piazza;
                        const light = faceLight(s, hx, hy, outdoor);
                        if (outdoor) {
                            color = fog(albedo * splat(light), b.far, true);
                        } else {
                            color = fog(lit(albedo, light, sunlit(hx, hy, z)), b.far, false);
                        }
                        t_hit = b.far;
                    },
                    .floor => {
                        const p = PLANES[@intFromEnum(b.sec)];
                        const den = vz - (p.gx * rx + p.gy * ry);
                        var t = if (den < -1e-6) (planeZ(b.sec, cam_x, cam_y) - cam_z) / den else b.far;
                        t = std.math.clamp(t, b.near, b.far);
                        const hx = cam_x + rx * t;
                        const hy = cam_y + ry * t;
                        const albedo = floorAlbedo(hx, hy);
                        const far = std.math.clamp((t - 18.0) / 40.0, 0.0, 0.6);
                        var smooth = mix(albedo, floorAverage(hx, hy), far);
                        const outdoor = hy >= PORTICO_FRONT;
                        if (outdoor) {
                            if (wet_out > 0.01) smooth = wetten(smooth, wet_out * 0.8, vz);
                        } else if (puddle > 0.01 and hx * hx + hy * hy < WET_REACH * WET_REACH) {
                            smooth = wetRotunda(smooth, hx, hy, rx, ry, vz, t);
                        }
                        color = fog(lit(smooth, ambientAt(hx, hy), sunlit(hx, hy, cam_z + vz * t)), t, outdoor);
                        t_hit = t;
                    },
                }
            }
            const glow = beamGlow(rx, ry, vz, t_hit);
            if (glow > 0) color += WARM * splat(glow * sun_k);
            if (mist.t1 > mist.t0) color = mix(color, RAIN_COLOR * splat(day_light * 0.8), rainMist(mist, vz, t_hit));
            putPixel(c, y, color);
            depth_buf[y * SCREEN_W + c] = depthCode(t_hit);
        }
    }
}

fn floorAverage(x: f32, y: f32) Rgb {
    switch (sectorAt(x, y)) {
        .cordonata => return .{ 0.62, 0.42, 0.32 },
        .apse_ramp => return GIALLO * splat(0.9),
        else => {},
    }
    if (onTerrace(x, y)) return TRAVERTINE * splat(0.92);
    return switch (regionAt(x, y)) {
        .rotunda => .{ 0.62, 0.52, 0.42 },
        .corridor => .{ 0.56, 0.32, 0.3 },
        .portico => TRAVERTINE * splat(0.92),
        .piazza => .{ 0.36, 0.34, 0.32 },
    };
}

// Sprites

const SpriteKind = enum(u8) { pigeon, flyer, sigil };
const Sprite = struct {
    depth: f32,
    x: f32,
    y: f32,
    z0: f32,
    w: f32,
    h: f32,
    kind: SpriteKind,
    index: u8,
};

var sprites: [MAX_SPRITES]Sprite = undefined;

fn drawSprites() void {
    var n: usize = 0;
    const t: f32 = @as(f32, @floatFromInt(anim_ms)) * 0.001;
    for (birds, 0..) |b, i| {
        if (!b.active) continue;
        if (b.mode == .ground) {
            n = pushSprite(n, b.x, b.y, b.z, 0.55 * BIRD_SCALE, 0.34 * BIRD_SCALE, .pigeon, @intCast(i));
        } else {
            const span = BIRD_SCALE * @as(f32, if (b.kind == .swift) SWIFT_SPAN else PIGEON_SPAN);
            n = pushSprite(n, b.x, b.y, b.z - span * 0.3, span, span * 0.6, .flyer, @intCast(i));
        }
    }
    for (pickups, 0..) |p, i| {
        if (!p.active) continue;
        const floor = floorAt(p.x, p.y);
        n = pushSprite(n, p.x, p.y, floor + 0.9 + 0.12 * @sin(t * 2.0 + @as(f32, @floatFromInt(i))), 0.8, 0.8, .sigil, @intCast(i));
    }
    // Painter's order: farthest first.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const s = sprites[i];
        var j = i;
        while (j > 0 and sprites[j - 1].depth < s.depth) : (j -= 1) sprites[j] = sprites[j - 1];
        sprites[j] = s;
    }
    for (sprites[0..n]) |s| drawSprite(s);
}

fn pushSprite(n: usize, x: f32, y: f32, z0: f32, w: f32, h: f32, kind: SpriteKind, index: u8) usize {
    if (n >= MAX_SPRITES) return n;
    const depth = (x - cam_x) * cam_fx + (y - cam_y) * cam_fy;
    if (depth < 0.2) return n;
    sprites[n] = .{ .depth = depth, .x = x, .y = y, .z0 = z0, .w = w, .h = h, .kind = kind, .index = index };
    return n + 1;
}

fn drawSprite(s: Sprite) void {
    const cx = (s.x - cam_x) * cam_rx + (s.y - cam_y) * cam_ry;
    const scale = FOCAL / s.depth;
    const sx = HALF_W + cx * scale;
    const y_top = horizon - (s.z0 + s.h - cam_z) * scale;
    const y_bot = horizon - (s.z0 - cam_z) * scale;
    const x0: usize = @intFromFloat(std.math.clamp(@ceil(sx - s.w * 0.5 * scale - 0.5), 0.0, HALF_W * 2.0));
    const x1: usize = @intFromFloat(std.math.clamp(@ceil(sx + s.w * 0.5 * scale - 0.5), 0.0, HALF_W * 2.0));
    const y0: usize = @intFromFloat(std.math.clamp(@ceil(y_top - 0.5), 0.0, @as(f32, SCREEN_H)));
    const y1: usize = @intFromFloat(std.math.clamp(@ceil(y_bot - 0.5), 0.0, @as(f32, SCREEN_H)));
    if (x0 >= x1 or y0 >= y1) return;
    const zc = s.z0 + s.h * 0.5;
    const outdoor = regionAt(s.x, s.y) == .piazza or zc > roofAt(s.x, s.y);
    const light = ambientAt(s.x, s.y) + beamAtCached(s.x, s.y, zc) * 0.9 * sun_k;
    // Every pixel already drawn nearer than the sprite hides it: walls,
    // floors and step faces in front, and ceilings and the dome above.
    const code = depthCode(s.depth);
    var c = x0;
    while (c < x1) : (c += 1) {
        const mx = (@as(f32, @floatFromInt(c)) + 0.5 - sx) / scale;
        var y = y0;
        while (y < y1) : (y += 1) {
            if (depth_buf[y * SCREEN_W + c] <= code) continue;
            const my = (@as(f32, @floatFromInt(y)) + 0.5 - y_top) / scale;
            const px_ = spriteShade(s, mx, my);
            if (px_[3] <= 0.01) continue;
            var col: Rgb = .{ px_[0], px_[1], px_[2] };
            if (s.kind != .sigil) col = fog(col * splat(if (outdoor) 1.0 else light * 1.25), s.depth, outdoor);
            if (px_[3] >= 0.99) {
                putPixel(c, y, col);
            } else {
                putPixel(c, y, mix(readPixel(c, y), col, px_[3]));
            }
        }
    }
}

fn spriteShade(s: Sprite, mx: f32, my: f32) Rgba {
    return switch (s.kind) {
        .pigeon => shadePigeon(birds[s.index], s.h / BIRD_SCALE, mx / BIRD_SCALE, my / BIRD_SCALE),
        .flyer => shadeFlyer(birds[s.index], s.w / BIRD_SCALE, s.h / BIRD_SCALE, mx / BIRD_SCALE, my / BIRD_SCALE),
        .sigil => shadeSigil(pickups[s.index].planet, mx, my - 0.4),
    };
}

fn rgba(c: Rgb, a: f32) Rgba {
    return .{ c[0], c[1], c[2], a };
}

const CLEAR: Rgba = .{ 0, 0, 0, 0 };

const PIGEON_GREY: Rgb = .{ 0.56, 0.58, 0.64 };
const PIGEON_DARK: Rgb = .{ 0.3, 0.31, 0.36 };
const PIGEON_NECK: Rgb = .{ 0.33, 0.5, 0.44 };
const SWIFT_BROWN: Rgb = .{ 0.13, 0.11, 0.1 };

// Which way the bird's head points across the screen.
fn noseSign(b: Bird) f32 {
    return if (b.hx * cam_rx + b.hy * cam_ry < 0) -1 else 1;
}

// A pigeon on the ground in profile; mx runs toward its head and y is the
// height above its feet.
fn shadePigeon(b: Bird, h: f32, mx: f32, my: f32) Rgba {
    const x = mx * noseSign(b);
    const y = h - my;
    const peck = b.peck_ms > 0 and @mod(@divTrunc(b.peck_ms, 150), 2) == 0;
    const head_x: f32 = if (peck) 0.17 else 0.13;
    const head_y: f32 = if (peck) 0.07 else 0.25;
    const hdx = x - head_x;
    const hdy = y - head_y;
    if (hdx * hdx + hdy * hdy < 0.05 * 0.05) {
        const ex = hdx - 0.018;
        const ey = hdy - 0.012;
        if (ex * ex + ey * ey < 0.012 * 0.012) return rgba(.{ 0.95, 0.5, 0.15 }, 1);
        return rgba(PIGEON_GREY * splat(0.9), 1);
    }
    if (x > head_x + 0.04 and x < head_x + 0.08 and @abs(hdy + 0.005 - (x - head_x - 0.04) * 0.2) < 0.012) return rgba(.{ 0.25, 0.22, 0.22 }, 1);
    // Iridescent neck between the head and the breast.
    const nx = x - (0.02 + head_x) * 0.5 - 0.03;
    const ny = y - (0.16 + head_y) * 0.5;
    if (nx * nx / (0.06 * 0.06) + ny * ny / (0.08 * 0.08) < 1) return rgba(PIGEON_NECK * splat(0.9 + 0.3 * @sin(y * 60.0)), 1);
    const ex = (x + 0.02) / 0.16;
    const ey = (y - 0.14) / 0.085;
    if (ex * ex + ey * ey < 1) {
        // Two dark bars across the folded wing.
        if (x > -0.1 and x < 0.02 and (@abs(y - 0.16 + x * 0.3) < 0.012 or @abs(y - 0.125 + x * 0.3) < 0.012)) return rgba(.{ 0.12, 0.12, 0.14 }, 1);
        return rgba(PIGEON_GREY * splat(0.85 + 0.25 * (1.0 - ex * ex)), 1);
    }
    if (x < -0.12 and x > -0.26 and @abs(y - 0.15 - (x + 0.12) * 0.25) < 0.028) return rgba(PIGEON_DARK, 1);
    for ([_]f32{ -0.01, 0.035 }) |lx| {
        if (@abs(x - lx) < 0.01 and y < 0.07) return rgba(.{ 0.85, 0.4, 0.45 }, 1);
    }
    return CLEAR;
}

// A bird in flight, wings spread across the box and foreshortened when seen
// end on. Its body lies along the screen by how far it is turned side on.
fn shadeFlyer(b: Bird, w: f32, h: f32, mx: f32, my: f32) Rgba {
    const y = my - h * 0.5;
    var vx = b.x - cam_x;
    var vy = b.y - cam_y;
    const vz = b.z - cam_z;
    const vl = @sqrt(vx * vx + vy * vy + vz * vz);
    vx /= vl;
    vy /= vl;
    const swift = b.kind == .swift;
    const toward_wing = b.hy * vx - b.hx * vy;
    const spread = @sqrt(@max(0.08, 1.0 - toward_wing * toward_wing));
    const toward_nose = b.hx * vx + b.hy * vy;
    const side = @sqrt(@max(0.0, 1.0 - toward_nose * toward_nose));
    const len: f32 = if (swift) 0.2 else 0.32;
    const half_body = len * 0.5 * side + 0.04;
    const x = mx * noseSign(b);
    const body: Rgb = if (swift) SWIFT_BROWN else PIGEON_GREY;
    // Body and head.
    const bx = x / half_body;
    const by = y / 0.045;
    if (bx * bx + by * by < 1) return rgba(body * splat(0.85 + 0.2 * (1.0 - by * by)), 1);
    if (!swift) {
        const hdx = x - half_body;
        if (hdx * hdx + y * y < 0.045 * 0.045) return rgba(PIGEON_GREY * splat(0.9), 1);
    }
    // Tail behind the body: forked for a swift, fanned for a pigeon.
    if (side > 0.3 and x < -half_body * 0.6 and x > -half_body - 0.1 * side) {
        const tx = -(x + half_body * 0.6);
        const fork = if (swift) @abs(@abs(y) - tx * 0.35) < 0.012 else @abs(y) < 0.02 + tx * 0.2;
        if (fork) return rgba(if (swift) SWIFT_BROWN else PIGEON_DARK, 1);
    }
    const half = w * 0.5 * spread;
    const ax = @abs(mx);
    if (ax >= half) return CLEAR;
    const t = ax / half;
    // Tips rise and fall with the wingbeat; gliding wings hold a shallow V.
    const lift: f32 = if (b.glide) 0.12 else @sin(b.flap) * 0.32;
    var wy = -lift * half * t;
    if (swift) wy += 0.08 * t * t * spread;
    const base_thick: f32 = if (swift) 0.035 else 0.06;
    const thick = base_thick * (1.0 - 0.7 * t) + 0.01;
    if (@abs(y - wy) >= thick) return CLEAR;
    if (swift) return rgba(SWIFT_BROWN * splat(1.1 - 0.3 * t), 1);
    if (t > 0.72) return rgba(PIGEON_DARK * splat(0.8), 1);
    return rgba(PIGEON_GREY * splat(1.0 - 0.15 * t), 1);
}

fn shadeSigil(planet: u8, mx: f32, my: f32) Rgba {
    const c = PLANET_COLORS[planet];
    const d2 = mx * mx + my * my;
    if (planet == 6) {
        // Saturn's ring, hidden where it passes behind the planet.
        const ring = mx * mx + (my * 3.0) * (my * 3.0);
        if (ring > 0.09 and ring < 0.13 and !(d2 < 0.04 and my < 0)) return rgba(c * splat(1.2), 1);
    }
    if (d2 < 0.04) {
        const lx = mx + 0.08;
        const ly = my + 0.08;
        const hi = std.math.clamp(1.0 - (lx * lx + ly * ly) / 0.04, 0.0, 1.0);
        return rgba(c * splat(0.7 + 0.5 * hi) + splat(hi * hi * 0.4), 1);
    }
    const t: f32 = @as(f32, @floatFromInt(anim_ms)) * 0.001;
    const tw = 0.3 + 0.12 * @sin(t * 5.0 + @as(f32, @floatFromInt(planet)));
    if ((@abs(mx) < 0.012 or @abs(my) < 0.012) and d2 < tw * tw) return rgba(c + splat(0.3), 0.9);
    if (d2 < 0.16) {
        const k = 1.0 - (@sqrt(d2) - 0.2) / 0.2;
        return rgba(c, k * k * 0.55);
    }
    return CLEAR;
}

// Rain is drawn last, as faint streaks and splashes tested against the depth
// of each pixel, so it shows in front of walls and the dome but not through
// them.
fn drawRain() void {
    if (rain <= 0) return;
    for (oculus_drops, 0..) |d, i| {
        if (dropShown(i, MAX_OCULUS_DROPS)) drawStreak(d);
    }
    for (open_drops, 0..) |d, i| {
        if (d.z != DEAD_Z and dropShown(i, MAX_OPEN_DROPS)) drawStreak(d);
    }
    for (splashes) |s| {
        if (s.age_ms < SPLASH_MS) drawSplash(s);
    }
}

const RAIN_COLOR: Rgb = .{ 0.9, 0.92, 0.97 };

// Lit by the sky, and bright where a drop falls through the sunbeam.
fn rainShade(x: f32, y: f32, z: f32) Rgb {
    return RAIN_COLOR * splat(day_light) + WARM * splat(beamAtCached(x, y, z) * sun_k * 0.6);
}

// Falling drops blur into vertical streaks, and the sheared view keeps
// verticals upright, so each is a run of rows in one or two columns.
fn drawStreak(d: Drop) void {
    const fwd = (d.x - cam_x) * cam_fx + (d.y - cam_y) * cam_fy;
    if (fwd < RAIN_NEAR) return;
    const scale = FOCAL / fwd;
    const sx = HALF_W + ((d.x - cam_x) * cam_rx + (d.y - cam_y) * cam_ry) * scale;
    if (!(sx >= 0 and sx < HALF_W * 2.0)) return;
    const y_top = horizon - (d.z + RAIN_STREAK - cam_z) * scale;
    const y_bot = horizon - (d.z - cam_z) * scale;
    if (y_bot < 0 or y_top >= @as(f32, SCREEN_H)) return;
    const alpha = 0.42 * std.math.clamp(1.4 - fwd / 30.0, 0.0, 1.0);
    if (alpha <= 0.01) return;
    const beam = beamAtCached(d.x, d.y, d.z) * sun_k;
    const col = rainShade(d.x, d.y, d.z);
    const a = @min(0.8, alpha * (1.0 + beam * 1.5));
    const code = depthCode(fwd - 0.05);
    const y0: usize = @intFromFloat(std.math.clamp(@ceil(y_top - 0.5), 0.0, @as(f32, SCREEN_H)));
    const y1: usize = @max(y0 + 1, @as(usize, @intFromFloat(std.math.clamp(@ceil(y_bot - 0.5), 0.0, @as(f32, SCREEN_H)))));
    const c: usize = @intFromFloat(sx);
    const wide = fwd < 4.0 and c + 1 < SCREEN_W;
    const len: f32 = @floatFromInt(y1 - y0);
    var y = y0;
    while (y < y1 and y < SCREEN_H) : (y += 1) {
        // The head of the streak is brighter than its tail.
        const k = a * (0.4 + 0.6 * (@as(f32, @floatFromInt(y - y0)) + 0.5) / len);
        blendRain(c, y, code, col, k);
        if (wide) blendRain(c + 1, y, code, col, k * 0.6);
    }
}

fn blendRain(c: usize, y: usize, code: u16, col: Rgb, a: f32) void {
    if (depth_buf[y * SCREEN_W + c] <= code) return;
    putPixel(c, y, mix(readPixel(c, y), col, a));
}

// A splash throws a few droplets up and out from where the drop landed.
fn drawSplash(s: Splash) void {
    const f = @as(f32, @floatFromInt(s.age_ms)) / @as(f32, SPLASH_MS);
    const col = rainShade(s.x, s.y, s.z + 0.05) + splat(0.1);
    var k: u5 = 0;
    while (k < 4) : (k += 1) {
        const ang = @as(f32, @floatFromInt((s.seed >> (k * 5)) & 31)) * (2.0 * std.math.pi / 32.0);
        const reach = (0.05 + 0.03 * @as(f32, @floatFromInt(k & 1))) + f * 0.1;
        const x = s.x + @cos(ang) * reach;
        const y = s.y + @sin(ang) * reach;
        const z = s.z + 0.5 * f * (1.0 - f) * (0.4 + 0.2 * @as(f32, @floatFromInt(k & 2)));
        const fwd = (x - cam_x) * cam_fx + (y - cam_y) * cam_fy;
        if (fwd < RAIN_NEAR or fwd > 18.0) continue;
        const scale = FOCAL / fwd;
        const sx = HALF_W + ((x - cam_x) * cam_rx + (y - cam_y) * cam_ry) * scale;
        const sy = horizon - (z - cam_z) * scale;
        if (!(sx >= 0 and sx < HALF_W * 2.0 and sy >= 0 and sy < @as(f32, SCREEN_H))) continue;
        const a = 0.75 * (1.0 - f) * std.math.clamp(1.6 - fwd / 12.0, 0.0, 1.0);
        blendRain(@intFromFloat(sx), @intFromFloat(sy), depthCode(fwd - 0.08), col, a);
    }
}

// Overlays

fn drawFrame() void {
    if (mode == .title) {
        setCamera(0, -19.0, EYE_Z, std.math.pi / 2.0 + 0.12, TITLE_LOOK);
    } else {
        setCamera(px, py, pz + EYE_Z, pangle, look);
    }
    drawScene();
    drawSprites();
    drawRain();
    if (mode != .title) {
        if (map_mode > 0) drawMap();
        drawHud();
    }
    switch (mode) {
        .title => drawTitle(),
        .paused => drawPaused(),
        .won => drawEnd("THE GODS ARE APPEASED", C_TITLE),
        .playing => {},
    }
}

fn drawTime(x: i32, y: i32, scale: i32) void {
    const seconds: u32 = @intCast(@divTrunc(time_ms, 1000));
    var buf: [10]u8 = undefined;
    drawText(x, y, scale, formatNumber(&buf, seconds / 60, 2), C_TEXT);
    drawText(x + 8 * scale * UI, y, scale, "-", C_TEXT_DIM);
    drawText(x + 12 * scale * UI, y, scale, formatNumber(&buf, seconds % 60, 2), C_TEXT);
}

fn drawHud() void {
    blendRect(0, H - 20 * UI, W, 20 * UI, C_HUD);
    drawText(6 * UI, H - 16 * UI, 1, "SIGILS", C_TEXT_DIM);
    var i: usize = 0;
    while (i < PLANET_COLORS.len) : (i += 1) {
        const x: i32 = (44 + @as(i32, @intCast(i)) * 15) * UI;
        const pc = PLANET_COLORS[i];
        const c: Color = .{ toByte(pc[0]), toByte(pc[1]), toByte(pc[2]), 0xFF };
        if ((sigils >> @intCast(i)) & 1 != 0) {
            fillCircle(x, H - 10 * UI, 5 * UI, c);
        } else {
            ringCircle(x, H - 10 * UI, 5 * UI, .{ c[0] / 3, c[1] / 3, c[2] / 3, 0xFF });
        }
    }
    drawText(186 * UI, H - 16 * UI, 1, "SCORE", C_TEXT_DIM);
    drawNumber(208 * UI, H - 17 * UI, 2, score, 5, C_TEXT);
    drawTime(W - 38 * UI, H - 16 * UI, 1);
    if (message_ms > 0) drawTextCentered(24 * UI, 2, message, if (sigils == ALL_SIGILS) C_TITLE else C_TEXT);
}

const MAP_SCALE: f32 = 1.55 * @as(f32, UI);

fn mapPoint(x: f32, y: f32) [2]i32 {
    return .{
        @intFromFloat(std.math.clamp(@as(f32, 160 * UI) + x * MAP_SCALE, -2000, 2000)),
        @intFromFloat(std.math.clamp(@as(f32, 176 * UI) - y * MAP_SCALE, -2000, 2000)),
    };
}

// The map draws the BSP's wall pieces. In order mode each piece is coloured
// by when the last frame's front-to-back walk reached it: near walls are
// bright, later ones fade, and back-facing or culled pieces stay dim.
fn drawMap() void {
    blendRect(46 * UI, 8 * UI, 228 * UI, 206 * UI, C_MAP_BG);
    const span: f32 = @floatFromInt(@max(order_next, 1));
    for (segs[0..seg_count], 0..) |s, i| {
        const a = mapPoint(s.x1, s.y1);
        const b = mapPoint(s.x2, s.y2);
        var c = if (s.portal) C_MAP_STEP else C_MAP_WALL;
        if (map_mode == 2) {
            if (seg_order[i] == NO_SEG) {
                c = C_MAP_DIM;
            } else {
                const f = @as(f32, @floatFromInt(seg_order[i])) / span;
                c = .{ toByte(1.0 - f * 0.7), toByte(0.9 - f * 0.5), toByte(0.3 + f * 0.6), 0xFF };
            }
        }
        drawLine(a[0], a[1], b[0], b[1], c);
    }
    for (pickups) |p| {
        if (!p.active) continue;
        const m = mapPoint(p.x, p.y);
        const pc = PLANET_COLORS[p.planet];
        fillRect(m[0] - 2, m[1] - 2, 5, 5, .{ toByte(pc[0]), toByte(pc[1]), toByte(pc[2]), 0xFF });
    }
    for (birds) |b| {
        if (!b.active) continue;
        const m = mapPoint(b.x, b.y);
        fillRect(m[0], m[1], 2, 2, C_MAP_BIRD);
    }
    const s = sunDir();
    const k = ZTOP / s[2];
    const spot = mapPoint(-s[0] * k, -s[1] * k);
    ringCircle(spot[0], spot[1], @intFromFloat(OCULUS_R * MAP_SCALE), C_TITLE);
    const p = mapPoint(px, py);
    const f = forward();
    fillRect(p[0] - 2, p[1] - 2, 5, 5, C_MAP_PLAYER);
    drawLine(p[0], p[1], p[0] + @as(i32, @intFromFloat(f[0] * 14)), p[1] - @as(i32, @intFromFloat(f[1] * 14)), C_MAP_PLAYER);
    if (map_mode == 2) {
        drawText(52 * UI, 12 * UI, 1, "BSP FRONT TO BACK", C_TITLE);
        drawText(52 * UI, 20 * UI, 1, "NODES", C_TEXT_DIM);
        drawNumber(76 * UI, 20 * UI, 1, stat_nodes, 1, C_TEXT);
        drawText(100 * UI, 20 * UI, 1, "WALLS", C_TEXT_DIM);
        drawNumber(124 * UI, 20 * UI, 1, stat_segs, 1, C_TEXT);
        drawText(148 * UI, 20 * UI, 1, "OF", C_TEXT_DIM);
        drawNumber(160 * UI, 20 * UI, 1, @intCast(seg_count), 1, C_TEXT);
    } else {
        drawText(52 * UI, 12 * UI, 1, "MAP", C_TITLE);
    }
}

fn drawTitle() void {
    blendRect(0, 0, W, H, .{ 0x06, 0x05, 0x08, 0x70 });
    drawTextCentered(34 * UI, 6, "ROTUNDA", C_TITLE);
    drawTextCentered(70 * UI, 2, "THE PANTHEON - ROME", C_TEXT);
    drawTextCentered(100 * UI, 1, "UP DOWN OR W S MOVE   LEFT RIGHT TURN", C_TEXT);
    drawTextCentered(110 * UI, 1, "A D STRAFE   Q E OR PAGE UP DOWN LOOK", C_TEXT);
    drawTextCentered(120 * UI, 1, "M MAP AND BSP ORDER   T RAIN   P PAUSE   R RESTART", C_TEXT);
    drawTextCentered(142 * UI, 2, "TAKE THE SEVEN PLANETARY SIGILS", C_TEXT);
    drawTextCentered(160 * UI, 2, "THEN STAND IN THE SUNBEAM", C_TEXT);
    drawTextCentered(196 * UI, 2, "PRESS SPACE TO START", C_TITLE_ALT);
    if (hi_score > 0) {
        var buf: [10]u8 = undefined;
        drawText(6 * UI, H - 10 * UI, 1, "HI", C_TEXT_DIM);
        drawText(18 * UI, H - 10 * UI, 1, formatNumber(&buf, hi_score, 1), C_TEXT);
    }
}

fn drawPaused() void {
    blendRect(0, 0, W, H, C_SHADE);
    drawTextCentered(96 * UI, 4, "PAUSED", C_TEXT);
    drawTextCentered(130 * UI, 2, "P TO RESUME", C_TEXT_DIM);
}

fn drawEnd(title: []const u8, color: Color) void {
    blendRect(0, 0, W, H, C_SHADE);
    drawTextCentered(70 * UI, 3, title, color);
    drawTextCentered(106 * UI, 2, if (score >= hi_score and score > 0) "NEW HIGH SCORE" else "FINAL SCORE", C_TEXT_DIM);
    var buf: [10]u8 = undefined;
    drawTextCentered(124 * UI, 3, formatNumber(&buf, score, 1), C_TEXT);
    drawTextCentered(160 * UI, 1, "TIME", C_TEXT_DIM);
    drawTime(W / 2 - 20 * UI, 170 * UI, 2);
    drawTextCentered(200 * UI, 2, "PRESS SPACE TO PLAY", C_TITLE_ALT);
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

fn drawLine(x0: i32, y0: i32, x1: i32, y1: i32, c: Color) void {
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    var x = x0;
    var y = y0;
    var steps: i32 = 0;
    const max_steps = dx - dy + 1;
    while (steps < max_steps) : (steps += 1) {
        if (x >= 0 and x < W and y >= 0 and y < H) fillSpan(y, x, x + 1, c);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
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
        fillSpan(cy + dy, cx - dx, cx - dx + 1, c);
        fillSpan(cy + dy, cx + dx, cx + dx + 1, c);
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
        '+' => 0b000_010_111_010_000,
        else => 0,
    };
}

fn drawText(x: i32, y: i32, scale: i32, text: []const u8, c: Color) void {
    drawTextRaw(x + UI, y + UI, scale * UI, text, C_TEXT_SHADOW);
    drawTextRaw(x, y, scale * UI, text, c);
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
    const width = (@as(i32, @intCast(text.len)) * 4 * scale - scale) * UI;
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
    pointer_down = false;
    mouse_total_x = 0;
    mouse_total_y = 0;
    mouse_used_x = 0;
    mouse_used_y = 0;
    jump_held = false;
    hi_score = 0;
    map_mode = 0;
    rng_state = 0x2F6B_A1C3;
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
    return 1;
}

fn holdKeys(at_ms: i64, keys: u8) void {
    begin_update_at(at_ms);
    keys_down = keys;
    _ = finish_update();
}

fn runSteps(t: *i64, count: usize) void {
    var i: usize = 0;
    while (i < count and mode == .playing) : (i += 1) {
        t.* += 16;
        _ = runUpdate(t.*);
    }
}

// Nearest front-facing wall along a camera column, by checking every
// original wall rather than walking the tree. Returns null when the ray
// grazes a wall end, where either answer is right.
fn bruteDepth(c: usize) ?f32 {
    const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
    const rx = cam_fx + sl * cam_rx;
    const ry = cam_fy + sl * cam_ry;
    var strict = std.math.inf(f32);
    var loose = std.math.inf(f32);
    for (base_segs[0..base_count]) |s| {
        if (s.portal) continue;
        const dx = s.x2 - s.x1;
        const dy = s.y2 - s.y1;
        if (dx * (cam_y - s.y1) - dy * (cam_x - s.x1) <= 0) continue;
        const den = rx * dy - ry * dx;
        if (@abs(den) < 1e-9) continue;
        const ox = s.x1 - cam_x;
        const oy = s.y1 - cam_y;
        const t = (ox * dy - oy * dx) / den;
        const k = (ox * ry - oy * rx) / den;
        if (t <= NEAR) continue;
        if (k > 1e-3 and k < 1 - 1e-3) strict = @min(strict, t);
        if (k >= -1e-3 and k <= 1 + 1e-3) loose = @min(loose, t);
    }
    if (@abs(strict - loose) > 1e-3) return null;
    return strict;
}

const TEST_SPOTS = [_][2]f32{
    .{ 0, 0 },    .{ 0, -18 },  .{ 15, 8 },   .{ -16, -9 }, .{ 23.5, 0 }, .{ 0, -24 },
    .{ 0, 25 },   .{ 0, 33 },   .{ -14, 41 }, .{ 10, 28.5 }, .{ 0, 50 },  .{ 20, 60 },
    .{ -25, 75 }, .{ 0, 84 },   .{ 5, 70 },   .{ -9, 45.5 },
};

test "BSP keeps every wall and stays shallow" {
    resetForTest();
    _ = renderImpl(0);
    var base_len: f32 = 0;
    for (base_segs[0..base_count]) |s| base_len += @sqrt((s.x2 - s.x1) * (s.x2 - s.x1) + (s.y2 - s.y1) * (s.y2 - s.y1));
    var bsp_len: f32 = 0;
    for (segs[0..seg_count]) |s| bsp_len += @sqrt((s.x2 - s.x1) * (s.x2 - s.x1) + (s.y2 - s.y1) * (s.y2 - s.y1));
    try std.testing.expectApproxEqAbs(base_len, bsp_len, 0.01);
    try std.testing.expect(seg_count >= base_count);
    try std.testing.expect(seg_count < MAX_SEGS);
    try std.testing.expect(bsp_depth < 64);
    var stored: usize = 0;
    for (nodes[0..node_count]) |n| stored += n.count;
    try std.testing.expectEqual(seg_count, stored);
}

test "front-to-back walk matches brute-force ray casts in every column" {
    resetForTest();
    _ = renderImpl(0);
    var grazing: usize = 0;
    for (TEST_SPOTS) |spot| {
        try std.testing.expect(spotClear(spot[0], spot[1], PLAYER_R));
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            setCamera(spot[0], spot[1], floorAt(spot[0], spot[1]) + EYE_Z, @as(f32, @floatFromInt(k)) * std.math.pi / 4.0 + 0.1, 0);
            castWalls();
            try std.testing.expectEqual(@as(usize, 0), cols_left);
            var c: usize = 0;
            while (c < SCREEN_W) : (c += 1) {
                const want = bruteDepth(c) orelse {
                    grazing += 1;
                    continue;
                };
                try std.testing.expect(std.math.isFinite(want));
                try std.testing.expectApproxEqAbs(want, col_depth[c], 0.002 * want + 0.002);
            }
        }
    }
    try std.testing.expect(grazing < TEST_SPOTS.len * 8 * SCREEN_W / 100);
}

test "the walk stops once every column has a wall" {
    resetForTest();
    _ = renderImpl(0);
    setCamera(0, 0, EYE_Z, 0, 0);
    castWalls();
    try std.testing.expect(stat_nodes < node_count);
    try std.testing.expect(stat_segs < seg_count / 2);
}

test "BSP ray casts agree with brute force" {
    resetForTest();
    _ = renderImpl(0);
    for (TEST_SPOTS) |spot| {
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a = @as(f32, @floatFromInt(k)) * std.math.pi / 8.0 + 0.05;
            const dx = @cos(a);
            const dy = @sin(a);
            const t = rayCast(spot[0], spot[1], dx, dy, 200);
            var best: f32 = 200;
            for (base_segs[0..base_count]) |s| {
                if (s.portal) continue;
                const sx = s.x2 - s.x1;
                const sy = s.y2 - s.y1;
                const den = dx * sy - dy * sx;
                if (@abs(den) < 1e-9) continue;
                const ox = s.x1 - spot[0];
                const oy = s.y1 - spot[1];
                const tt = (ox * sy - oy * sx) / den;
                const kk = (ox * dy - oy * dx) / den;
                if (tt > 0 and kk >= 0 and kk <= 1) best = @min(best, tt);
            }
            try std.testing.expectApproxEqAbs(best, t, 0.002);
        }
    }
}

test "start, pigeon, and sigil spots are clear of walls" {
    resetForTest();
    _ = renderImpl(0);
    try std.testing.expect(spotClear(0, 84, PLAYER_R));
    for (PIGEON_SPOTS) |spot| {
        try std.testing.expect(spotClear(spot[0], spot[1], PIGEON_R));
        try std.testing.expect(pigeonGround(spot[0], spot[1], inRotunda(spot[0], spot[1])));
    }
    for (pickups) |p| try std.testing.expect(p.active and spotClear(p.x, p.y, 0.3));
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
    try std.testing.expectEqual(@as(f32, 84), py);

    try std.testing.expectEqual(@as(i64, 50), runUpdate(34));
    try std.testing.expectApproxEqAbs(@as(f32, 84) - MOVE_STEP, py, 1e-4);
}

test "updates keep the published frame until a separate render" {
    var t = startForTest();
    try std.testing.expectEqual(@as(u32, OUTPUT_BYTES), renderImpl(0));
    const before = std.hash.Wyhash.hash(0, &output_buf);
    t += 16;
    holdKeys(t, KEY_FWD | KEY_TURN_L);
    runSteps(&t, 20);
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
    const paused_time = time_ms;

    begin_update_at(60_000);
    try std.testing.expectEqual(@as(i32, 1), key_event('p', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i64, 60_016), finish_update());
    try std.testing.expectEqual(paused_time, time_ms);
}

test "late updates run at most eight steps" {
    _ = startForTest();
    try std.testing.expectEqual(@as(i64, 10_016), runUpdate(10_000));
    try std.testing.expectEqual(@as(i64, 10_000), last_step_ms);
    try std.testing.expectEqual(STEP * MAX_STEPS_PER_UPDATE, time_ms);
}

test "the largest update time does not overflow the wake" {
    resetForTest();
    _ = renderImpl(0);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), runUpdate(std.math.maxInt(i64)));

    _ = startForTest();
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), runUpdate(std.math.maxInt(i64)));
}

test "walls and columns stop the player" {
    var t = startForTest();
    // Walk east from the rotunda centre into the drum wall between niches.
    px = 0;
    py = -9;
    pangle = 0;
    t += 16;
    holdKeys(t, KEY_FWD);
    runSteps(&t, 400);
    try std.testing.expect(px * px + py * py < R * R);
    try std.testing.expect(px > 15);

    // Walk north into a front portico column.
    px = 2.25;
    py = 40;
    pangle = std.math.pi / 2.0;
    runSteps(&t, 120);
    try std.testing.expect(py < 44.0 - 0.8);
}

test "all seven sigils win in the sunbeam" {
    var t = startForTest();
    // The early sunbeam falls in the north-east niche (pickup 6), so take
    // that sigil first and finish in the east niche (pickup 5).
    for ([_]usize{ 6, 0, 1, 2, 3, 4 }) |i| {
        const p = pickups[i];
        px = p.x;
        py = p.y;
        t += 16;
        _ = runUpdate(t);
        try std.testing.expect(!pickups[i].active);
    }
    px = pickups[5].x;
    py = pickups[5].y;
    t += 16;
    _ = runUpdate(t);
    try std.testing.expectEqual(ALL_SIGILS, sigils);
    try std.testing.expectEqual(Mode.playing, mode);

    const s = sunDir();
    const k = ZTOP / s[2];
    px = -s[0] * k;
    py = -s[1] * k;
    t += 16;
    _ = runUpdate(t);
    try std.testing.expectEqual(Mode.won, mode);
    try std.testing.expect(hi_score > 7 * 500);
    try std.testing.expectEqual(t, runUpdate(t + 16) - 16);
}

test "step lines separate the sectors they name" {
    resetForTest();
    _ = renderImpl(0);
    var portals: usize = 0;
    for (base_segs[0..base_count]) |s| {
        if (!s.portal) continue;
        portals += 1;
        const l = lineOf(s);
        const mx = (s.x1 + s.x2) * 0.5;
        const my = (s.y1 + s.y2) * 0.5;
        try std.testing.expectEqual(s.front, sectorAt(mx - l.dy * 0.01, my + l.dx * 0.01));
        try std.testing.expectEqual(s.back, sectorAt(mx + l.dy * 0.01, my - l.dx * 0.01));
        try std.testing.expect(s.front != s.back);
    }
    try std.testing.expectEqual(@as(usize, 14), portals);
}

test "ramps meet their landings without a step and are gentle enough to walk" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), planeZ(.cordonata, 0, TERRACE_Y), 1e-4);
    try std.testing.expectApproxEqAbs(PIAZZA_Z, planeZ(.cordonata, 3, RAMP_FOOT_Y), 1e-4);
    try std.testing.expectApproxEqAbs(APSE_Z, planeZ(.apse_ramp, 0, -APSE_LIP), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), planeZ(.apse_ramp, 1, -APSE_LIP + APSE_RAMP_LEN), 1e-4);
    try std.testing.expect(@abs(CORDONATA_GY) * 2 * PLAYER_R < STEP_UP);
    try std.testing.expect(@abs(APSE_RAMP_GY) * 2 * PLAYER_R < STEP_UP);
    try std.testing.expect(-PIAZZA_Z > STEP_UP and APSE_Z > STEP_UP);
}

test "step-line crossings in every column match brute force" {
    resetForTest();
    _ = renderImpl(0);
    const spots = TEST_SPOTS ++ [_][2]f32{ .{ 14, 60 }, .{ 0, 62 }, .{ -12, 52 }, .{ 0, -14 }, .{ 1.5, -19 }, .{ 0, -23.5 }, .{ 14, 47.5 } };
    var grazing: usize = 0;
    var crossings: usize = 0;
    for (spots) |spot| {
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            setCamera(spot[0], spot[1], floorAt(spot[0], spot[1]) + EYE_Z, @as(f32, @floatFromInt(k)) * std.math.pi / 4.0 + 0.1, 0);
            castWalls();
            var c: usize = 0;
            columns: while (c < SCREEN_W) : (c += 1) {
                const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
                const rx = cam_fx + sl * cam_rx;
                const ry = cam_fy + sl * cam_ry;
                var depths: [16]f32 = undefined;
                var secs: [16]Sector = undefined;
                var n: usize = 0;
                for (base_segs[0..base_count]) |s| {
                    if (!s.portal) continue;
                    const dx = s.x2 - s.x1;
                    const dy = s.y2 - s.y1;
                    const den = rx * dy - ry * dx;
                    if (@abs(den) < 1e-9) continue;
                    const ox = s.x1 - cam_x;
                    const oy = s.y1 - cam_y;
                    const t = (ox * dy - oy * dx) / den;
                    const along = (ox * ry - oy * rx) / den;
                    if (t <= NEAR or t >= col_depth[c] + 1e-3) continue;
                    if (along < -1e-3 or along > 1 + 1e-3) continue;
                    if (along < 1e-3 or along > 1 - 1e-3 or t > col_depth[c] - 1e-3) {
                        grazing += 1;
                        continue :columns;
                    }
                    const cam_left = dx * (cam_y - s.y1) - dy * (cam_x - s.x1) > 0;
                    // Insert in depth order.
                    var j = n;
                    while (j > 0 and depths[j - 1] > t) : (j -= 1) {
                        depths[j] = depths[j - 1];
                        secs[j] = secs[j - 1];
                    }
                    depths[j] = t;
                    secs[j] = if (cam_left) s.back else s.front;
                    n += 1;
                }
                try std.testing.expect(n <= MAX_EVENTS);
                try std.testing.expectEqual(n, @as(usize, ev_n[c]));
                for (0..n) |i| {
                    try std.testing.expectApproxEqAbs(depths[i], ev_depth[c][i], 0.002 * depths[i] + 0.002);
                    try std.testing.expectEqual(secs[i], ev_sec[c][i]);
                }
                crossings += n;
                // Each stretch between crossings, up to the wall, lies in the
                // sector the column tracked for it.
                var from: f32 = 0;
                var sec = cam_sec;
                for (0..n + 1) |i| {
                    const to = if (i < n) depths[i] else col_depth[c];
                    const mid = (from + to) * 0.5;
                    if (to - from > 0.02) try std.testing.expectEqual(sectorAt(cam_x + rx * mid, cam_y + ry * mid), sec);
                    if (i < n) sec = secs[i];
                    from = to;
                }
            }
        }
    }
    try std.testing.expect(crossings > 1000);
    try std.testing.expect(grazing < spots.len * 8 * SCREEN_W / 100);
}

test "a step face rises where the far floor is higher" {
    resetForTest();
    _ = renderImpl(0);
    setCamera(14, 60, PIAZZA_Z + EYE_Z, -std.math.pi / 2.0, 0);
    drawScene();
    const c = SCREEN_W / 2;
    const d = 60 - TERRACE_Y;
    try std.testing.expectEqual(@as(u8, 1), ev_n[c]);
    try std.testing.expectApproxEqAbs(@as(f32, d), ev_depth[c][0], 0.01);
    try std.testing.expectEqual(Sector.ground, ev_sec[c][0]);
    // Rows between the piazza's edge and the terrace's edge show the face,
    // at the step line's depth.
    const top: usize = @intFromFloat(@ceil(project(0, d)));
    const bottom: usize = @intFromFloat(@floor(project(PIAZZA_Z, d)));
    try std.testing.expect(bottom > top + 20);
    var y = top + 1;
    while (y < bottom) : (y += 1) {
        const got = @as(f32, @floatFromInt(depth_buf[y * SCREEN_W + c])) / DEPTH_SCALE;
        try std.testing.expectApproxEqAbs(@as(f32, d), got, 0.05);
    }
}

test "the player walks up the cordonata onto the terrace" {
    var t = startForTest();
    px = 0;
    py = 62;
    pangle = -std.math.pi / 2.0;
    t += 16;
    _ = runUpdate(t);
    try std.testing.expectEqual(PIAZZA_Z, pz);
    holdKeys(t + 16, KEY_FWD);
    t += 16;
    runSteps(&t, 160);
    try std.testing.expect(py < TERRACE_Y);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pz, 1e-4);
}

test "a terrace edge blocks climbing but not dropping off" {
    var t = startForTest();
    px = 14;
    py = 53;
    pangle = -std.math.pi / 2.0;
    holdKeys(t + 16, KEY_FWD);
    t += 16;
    runSteps(&t, 80);
    try std.testing.expect(py > TERRACE_Y + PLAYER_R - 0.01);
    try std.testing.expectApproxEqAbs(PIAZZA_Z, pz, 1e-4);

    px = 14;
    py = 47.5;
    pz = 0;
    pangle = std.math.pi / 2.0;
    runSteps(&t, 25);
    try std.testing.expect(py > TERRACE_Y);
    // Still falling.
    try std.testing.expect(pz < 0 and pz > PIAZZA_Z);
    runSteps(&t, 40);
    try std.testing.expectEqual(PIAZZA_Z, pz);
}

test "jumping climbs the terrace edge and the apse ledge" {
    var t = startForTest();
    px = 14;
    py = 51;
    pangle = -std.math.pi / 2.0;
    t += 16;
    begin_update_at(t);
    keys_down = KEY_FWD;
    try std.testing.expectEqual(@as(i32, 1), key_event(' ', FLAG_KEY_DOWN));
    // A held key repeating does nothing, and neither does a press in mid-air.
    try std.testing.expectEqual(@as(i32, 0), key_event(' ', FLAG_KEY_DOWN));
    _ = key_event(' ', 0);
    _ = finish_update();
    runSteps(&t, 10);
    begin_update_at(t + 16);
    t += 16;
    try std.testing.expectEqual(@as(i32, 0), key_event(' ', FLAG_KEY_DOWN));
    _ = key_event(' ', 0);
    _ = finish_update();
    runSteps(&t, 80);
    try std.testing.expect(py < TERRACE_Y - PLAYER_R);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pz, 1e-4);
    try std.testing.expectEqual(@as(f32, 0), fall_v);

    // Off-centre at the apse, where walking in is blocked by the ledge.
    px = 3.3;
    py = -12;
    pz = 0;
    pangle = -std.math.pi / 2.0;
    holdKeys(t + 16, KEY_FWD);
    t += 16;
    runSteps(&t, 120);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pz, 1e-4);
    begin_update_at(t + 16);
    t += 16;
    try std.testing.expectEqual(@as(i32, 1), key_event(' ', FLAG_KEY_DOWN));
    _ = key_event(' ', 0);
    _ = finish_update();
    runSteps(&t, 80);
    try std.testing.expectApproxEqAbs(APSE_Z, pz, 1e-4);
}


test "a click starts the game and does nothing while playing" {
    resetForTest();
    _ = renderImpl(0);
    begin_update_at(1);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(1, 10, 10));
    try std.testing.expectEqual(Mode.playing, mode);
    try std.testing.expectEqual(@as(i32, 0), pointer_event(0, 10, 10));
    try std.testing.expectEqual(@as(i32, 0), pointer_event(1, 10, 10));
    _ = finish_update();
}

test "looking up shows the oculus and looking ahead does not" {
    resetForTest();
    _ = renderImpl(0);
    for ([_]f32{ 0, LOOK_UP_MAX }) |look_px| {
        // Facing south, away from the door and the open piazza.
        setCamera(0, 16, EYE_Z, -std.math.pi / 2.0, look_px);
        drawScene();
        var sky: usize = 0;
        for (depth_buf) |d| {
            if (d == DEPTH_SKY) sky += 1;
        }
        if (look_px == 0) {
            try std.testing.expectEqual(@as(usize, 0), sky);
        } else {
            try std.testing.expect(sky > 100);
        }
    }
}

test "look keys tilt the view within limits" {
    var t = startForTest();
    holdKeys(t + 16, KEY_LOOK_UP);
    t += 16;
    runSteps(&t, 200);
    try std.testing.expectEqual(LOOK_UP_MAX, look);
    holdKeys(t + 16, KEY_LOOK_DOWN);
    t += 16;
    runSteps(&t, 200);
    try std.testing.expectEqual(-LOOK_DOWN_MAX, look);
}

test "locked pointer movement turns and tilts the view once" {
    resetForTest();
    _ = renderImpl(0);
    // Movement on the title screen is dropped, not saved for the game.
    begin_update_at(1);
    _ = uniform_set_pointer_total_movement_x(500);
    _ = uniform_set_pointer_total_movement_y(500);
    _ = key_event(' ', FLAG_KEY_DOWN);
    _ = key_event(' ', 0);
    _ = finish_update();
    try std.testing.expectEqual(-std.math.pi / 2.0, pangle);
    try std.testing.expectEqual(@as(f32, 0), look);

    // Right and up turns right and looks up; the render's reapply does nothing.
    begin_update_at(2);
    _ = uniform_set_pointer_total_movement_x(600);
    _ = uniform_set_pointer_total_movement_y(450);
    _ = finish_update();
    const turned = pangle;
    try std.testing.expectApproxEqAbs(-std.math.pi / 2.0 - 100 * MOUSE_TURN, turned, 1e-5);
    try std.testing.expectApproxEqAbs(50 * MOUSE_LOOK, look, 1e-4);
    _ = uniform_set_pointer_total_movement_x(600);
    _ = uniform_set_pointer_total_movement_y(450);
    _ = renderImpl(0);
    begin_update_at(3);
    _ = uniform_set_pointer_total_movement_x(600);
    _ = uniform_set_pointer_total_movement_y(450);
    _ = finish_update();
    try std.testing.expectEqual(turned, pangle);

    // Movement made between an update and a render waits for the next update.
    _ = uniform_set_pointer_total_movement_x(700);
    try std.testing.expectEqual(turned, pangle);
    begin_update_at(4);
    _ = uniform_set_pointer_total_movement_x(700);
    _ = finish_update();
    try std.testing.expectApproxEqAbs(turned - 100 * MOUSE_TURN, pangle, 1e-5);

    // Looking stays within the key limits, and big turns stay within -pi to pi.
    begin_update_at(5);
    _ = uniform_set_pointer_total_movement_x(-20000);
    _ = uniform_set_pointer_total_movement_y(-20000);
    _ = finish_update();
    try std.testing.expectEqual(LOOK_UP_MAX, look);
    try std.testing.expect(@abs(pangle) <= std.math.pi);
    begin_update_at(6);
    _ = uniform_set_pointer_total_movement_y(20000);
    _ = finish_update();
    try std.testing.expectEqual(-LOOK_DOWN_MAX, look);
}

test "a pigeon flies off when the player comes close and lands again" {
    var t = startForTest();
    const b = &birds[0];
    try std.testing.expectEqual(BirdMode.ground, b.mode);
    px = b.x + 1.0;
    py = b.y;
    t += 16;
    _ = runUpdate(t);
    try std.testing.expect(b.mode != .ground);
    // Step back into the portico, out of the way, and wait.
    px = 0;
    py = 36;
    var i: usize = 0;
    while (b.mode != .ground and i < 4000) : (i += 1) {
        t += 16;
        _ = runUpdate(t);
    }
    try std.testing.expectEqual(BirdMode.ground, b.mode);
    try std.testing.expectApproxEqAbs(floorAt(b.x, b.y), b.z, 1e-4);
    try std.testing.expect(spotClear(b.x, b.y, PIGEON_R));
}

const Shelter = struct {
    fn roofed(_: f32, y: f32) bool {
        return y < PORTICO_FRONT;
    }
    fn under(x: f32, y: f32, z: f32) bool {
        return roofed(x, y) and z < roofAt(x, y);
    }
};

// Startles a pigeon every few seconds and follows every bird for three
// minutes. Low flights must not cross walls, and the only way between the
// building's inside and the sky above its roof is the oculus.
test "birds stay clear of walls and roofs and use the oculus both ways" {
    var t = startForTest();
    var prev: [MAX_BIRDS][3]f32 = undefined;
    for (birds, 0..) |b, i| prev[i] = .{ b.x, b.y, b.z };
    var ups: usize = 0;
    var downs: usize = 0;
    var pigeon_ups: usize = 0;
    var landed_inside: usize = 0;
    var step: usize = 0;
    while (step < 180 * 1000 / 16) : (step += 1) {
        if (step % 200 == 0) {
            // Walk up to the next grounded pigeon.
            var k: usize = 0;
            while (k < MAX_BIRDS) : (k += 1) {
                const b = birds[(step / 200 + k) % MAX_BIRDS];
                if (b.active and b.mode == .ground) {
                    px = b.x + 1.0;
                    py = b.y;
                    pz = floorAt(px, py);
                    break;
                }
            }
        }
        t += 16;
        _ = runUpdate(t);
        for (birds, 0..) |b, i| {
            if (!b.active) continue;
            const p0 = prev[i];
            prev[i] = .{ b.x, b.y, b.z };
            try std.testing.expect(b.z >= floorAt(b.x, b.y) - 1e-3);
            if (p0[2] < WALL_H and b.z < WALL_H) try std.testing.expect(lineClear(p0[0], p0[1], b.x, b.y));
            const was = Shelter.under(p0[0], p0[1], p0[2]);
            const now = Shelter.under(b.x, b.y, b.z);
            if (was != now) {
                if (Shelter.roofed(p0[0], p0[1]) and Shelter.roofed(b.x, b.y)) {
                    try std.testing.expect(p0[0] * p0[0] + p0[1] * p0[1] < OCULUS_R * OCULUS_R);
                    try std.testing.expect(b.x * b.x + b.y * b.y < OCULUS_R * OCULUS_R);
                } else {
                    // Under the portico's open front.
                    try std.testing.expect(@max(p0[2], b.z) < WALL_H);
                }
            }
            if ((p0[2] < ZTOP) != (b.z < ZTOP) and b.x * b.x + b.y * b.y < OCULUS_R * OCULUS_R) {
                if (b.z > p0[2]) ups += 1 else downs += 1;
                if (b.kind == .pigeon and b.z > p0[2]) pigeon_ups += 1;
            }
            if (b.kind == .pigeon and b.mode == .ground and b.route == .in_oculus and p0[2] > b.z + 1e-4) landed_inside += 1;
        }
    }
    try std.testing.expect(ups >= 10);
    try std.testing.expect(downs >= 10);
    try std.testing.expect(pigeon_ups >= 2);
    try std.testing.expect(landed_inside >= 1);
}

test "a bird in the sunbeam shades the floor below it" {
    resetForTest();
    _ = renderImpl(0);
    sun = sunDir();
    // The middle of the sunlit patch on the floor.
    const k = ZTOP / sun[2];
    const fx = -sun[0] * k;
    const fy = -sun[1] * k;
    try std.testing.expect(beamAtCached(fx, fy, 0) > 0.9);
    birds = [_]Bird{.{}} ** MAX_BIRDS;
    const up = 8.0 / sun[2];
    birds[0] = .{ .active = true, .kind = .pigeon, .mode = .fly, .x = fx + sun[0] * up, .y = fy + sun[1] * up, .z = 8 };
    findBeamBirds();
    try std.testing.expectEqual(@as(usize, 1), beam_bird_n);
    try std.testing.expect(sunlit(fx, fy, 0) < 0.3);
    try std.testing.expect(sunlit(fx + 1.5, fy, 0) > 0.9);
}

// Walks from the piazza through the portico into the rotunda in a shower.
// Inside, rain only falls in the column under the oculus, and outside only
// over open ground.
test "rain falls only through the oculus and on open ground" {
    var t = startForTest();
    try std.testing.expect(raining and rain == 1);
    const route = [_][2]f32{ .{ 0, 70 }, .{ 12, 58 }, .{ 0, 47 }, .{ 0, 38 }, .{ 0, 10 }, .{ 0, 0 } };
    var landed_inside: usize = 0;
    var landed_outside: usize = 0;
    for (route) |spot| {
        px = spot[0];
        py = spot[1];
        pz = floorAt(px, py);
        var step: usize = 0;
        while (step < 300) : (step += 1) {
            t += 16;
            _ = runUpdate(t);
            for (oculus_drops) |d| {
                try std.testing.expect(d.x * d.x + d.y * d.y < OCULUS_R * OCULUS_R);
                try std.testing.expect(d.z > floorAt(d.x, d.y) and d.z <= RAIN_TOP);
            }
            for (open_drops) |d| {
                if (d.z == DEAD_Z) continue;
                try std.testing.expect(!Shelter.roofed(d.x, d.y));
                try std.testing.expect(d.z > floorAt(d.x, d.y));
            }
            for (splashes) |s| {
                if (s.age_ms != STEP) continue;
                if (inRotunda(s.x, s.y)) landed_inside += 1 else landed_outside += 1;
            }
        }
    }
    try std.testing.expect(landed_inside > 100);
    try std.testing.expect(landed_outside > 100);
}

test "the drains empty the rotunda floor after a shower" {
    var t = startForTest();
    runSteps(&t, 40 * 1000 / 16);
    try std.testing.expect(puddle > 0.7);
    begin_update_at(t + 1);
    try std.testing.expectEqual(@as(i32, 1), key_event('t', FLAG_KEY_DOWN));
    _ = finish_update();
    t += 1;
    try std.testing.expect(!raining);
    runSteps(&t, 38 * 1000 / 16);
    try std.testing.expectEqual(@as(f32, 0), rain);
    try std.testing.expect(puddle < 0.03);
    // The dry spell ends in another shower.
    runSteps(&t, @intCast(@divTrunc(weather_ms, STEP) + 1));
    try std.testing.expect(raining);
}

var test_frame: [PIXEL_BYTES]u8 = undefined;

test "rain shows under the oculus and the drains ring the wet floor" {
    resetForTest();
    _ = renderImpl(0);
    // From the side of the rotunda, facing the rain across the middle.
    setCamera(0, 14, EYE_Z, -std.math.pi / 2.0, 120);
    drawScene();
    @memcpy(&test_frame, output_buf[ktx.HEADER_SIZE..]);
    drawRain();
    var changed: usize = 0;
    var i: usize = 0;
    while (i < PIXEL_BYTES) : (i += 4) {
        if (!std.mem.eql(u8, test_frame[i .. i + 3], output_buf[ktx.HEADER_SIZE + i ..][0..3])) changed += 1;
    }
    try std.testing.expect(changed > 500);
    rain = 0;
    drawScene();
    @memcpy(&test_frame, output_buf[ktx.HEADER_SIZE..]);
    drawRain();
    try std.testing.expect(std.mem.eql(u8, &test_frame, output_buf[ktx.HEADER_SIZE..]));

    // Wet stone under the oculus is darker than dry stone.
    puddle = 0.6;
    const dry = pantheonFloor(1.2, 1.2);
    const wet = wetRotunda(dry, 1.2, 1.2, 0, 1, -0.5, 4);
    try std.testing.expect(wet[0] + wet[1] + wet[2] < (dry[0] + dry[1] + dry[2]) * 0.8);
    try std.testing.expectEqual(dry, wetRotunda(dry, 0, -WET_REACH, 0, 1, -0.5, 4));

    // Twenty-two holes around the ring, none elsewhere.
    var holes: usize = 0;
    var was_hole = drainHole(DRAIN_R, 0) != null;
    var a: f32 = 0;
    while (a < 2.0 * std.math.pi) : (a += 0.0005) {
        const p = polar(DRAIN_R, a);
        const hole = drainHole(p[0], p[1]) != null;
        if (hole and !was_hole) holes += 1;
        was_hole = hole;
    }
    try std.testing.expectEqual(@as(usize, 22), holes);
    try std.testing.expect(drainHole(0, 0) == null);
    try std.testing.expect(drainHole(DRAIN_R + 0.5, 0) == null);
}

test "DIAG sector chain" {
    resetForTest();
    _ = renderImpl(0);
    var bad_frames: usize = 0;
    var frames: usize = 0;
    var bad_cols: usize = 0;
    var overflow: usize = 0;
    var printed: usize = 0;
    var gx: f32 = -20;
    while (gx <= 20) : (gx += 0.37) {
        var gy: f32 = -24;
        while (gy <= 66) : (gy += 0.41) {
            if (gy < PORTICO_FRONT and gy > 30 and @abs(gx) > PORTICO_HALF - 0.4) continue;
            if (gy <= 30 and gx * gx + gy * gy > (R - 0.4) * (R - 0.4)) continue;
            if (gy >= PORTICO_FRONT - 0.4 and @abs(gx) > PORTICO_HALF - 0.4 and (gy < 48.5 or @abs(gx) > 30)) continue;
            if (gy > 30 and gy < PORTICO_FRONT and gy < 33 and @abs(gx) > 7) continue;
            var in_pillar = false;
            for (PORTICO_COLUMN_XS) |qx| {
                for ([_]f32{ 44, 39.5, 35 }) |qy| {
                    if ((gx - qx) * (gx - qx) + (gy - qy) * (gy - qy) < 1.44) in_pillar = true;
                }
            }
            if (in_pillar) continue;
            if ((gx - OBELISK_X) * (gx - OBELISK_X) + (gy - OBELISK_Y) * (gy - OBELISK_Y) < 2.5) continue;
            var k: usize = 0;
            while (k < 24) : (k += 1) {
                const ang = @as(f32, @floatFromInt(k)) * std.math.pi / 12.0 + 0.013;
                var pd: f32 = 1e9;
                for (base_segs[0..base_count]) |s| {
                    if (!s.portal) continue;
                    const dx = s.x2 - s.x1;
                    const dy = s.y2 - s.y1;
                    const tt = std.math.clamp(((gx - s.x1) * dx + (gy - s.y1) * dy) / (dx * dx + dy * dy), 0, 1);
                    const ex = s.x1 + tt * dx - gx;
                    const ey = s.y1 + tt * dy - gy;
                    pd = @min(pd, @sqrt(ex * ex + ey * ey));
                }
                if (pd < 0.08) continue;
                setCamera(gx, gy, floorAt(gx, gy) + EYE_Z, ang, 0);
                castWalls();
                frames += 1;
                var frame_bad = false;
                var c: usize = 0;
                while (c < SCREEN_W) : (c += 1) {
                    if (ev_n[c] >= MAX_EVENTS) overflow += 1;
                    const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
                    const rx = cam_fx + sl * cam_rx;
                    const ry = cam_fy + sl * cam_ry;
                    var from: f32 = 0;
                    var sec = cam_sec;
                    const n = ev_n[c];
                    const end = if (col_depth[c] < 1000) col_depth[c] else 300;
                    var i: usize = 0;
                    while (i <= n) : (i += 1) {
                        const to = if (i < n) ev_depth[c][i] else end;
                        const mid = (from + to) * 0.5;
                        if (to - from > 0.05 and sectorAt(cam_x + rx * mid, cam_y + ry * mid) != sec) {
                            bad_cols += 1;
                            frame_bad = true;
                            if (printed < 40) {
                                printed += 1;
                                std.debug.print("cam ({d:.2},{d:.2}) ang {d:.2} col {d} span {d}/{d} [{d:.3},{d:.3}] chain {s} real {s}\n", .{ gx, gy, ang, c, i, n, from, to, @tagName(sec), @tagName(sectorAt(cam_x + rx * mid, cam_y + ry * mid)) });
                            }
                            break;
                        }
                        if (i < n) sec = ev_sec[c][i];
                        from = to;
                    }
                }
                if (frame_bad) bad_frames += 1;
            }
        }
    }
    std.debug.print("frames {d} bad_frames {d} bad_cols {d} overflow {d}\n", .{ frames, bad_frames, bad_cols, overflow });
}
