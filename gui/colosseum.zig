const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

// A first-person walk through the Colosseum in Rome, where gulls wheel over
// the cavea and land on the seats. The level is a set of sectors, as in the
// Build engine behind Duke Nukem 3D: convex rooms with their own floor and
// ceiling planes, joined at their walls. Unlike Doom's 2D BSP, a wall can open
// onto several rooms stacked above one another, so the hypogeum runs under
// the arena floor, the upper ambulatory sits on the lower one, and passages
// and stairs run beneath the seats. Each screen column follows its ray from
// room to room, and every opening it passes narrows the rows it can still
// draw. A second renderer draws the same rooms as a true 3D BSP of polygons,
// front to back, so the two approaches can be compared on one scene.

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

// World units are metres; +x is east and +y is north. The amphitheatre is an
// ellipse centred on the origin with its long axis east to west. Every ring
// is a scaled copy of one ellipse, x = s * EX * cos(a) and y = s * sin(a),
// and cells are cut between two rings along chords. The inner and outer
// chords of a cell are then parallel, so a sloped seating cell is a true
// plane and its neighbours meet it without a step.
const EX: f32 = 1.3;
const NB: i32 = 48;
const DTH: f32 = 2.0 * std.math.pi / 48.0;

const S_ARENA: f32 = 30.0;
const S_POD: f32 = 33.0;
const S_SEAT: f32 = 54.0;
const S_INNER: f32 = 56.0;
const S_SPLIT: f32 = 59.0;
const S_OUTER: f32 = 62.0;
// The outer wall's street face; the arches run through the wall between it
// and S_OUTER as short vaulted passages.
const S_FACE: f32 = 64.5;
const S_CITY: f32 = 84.0;

const POD_Z: f32 = 5.0;
const SEAT_LO: f32 = 5.4;
const SEAT_HI: f32 = 22.0;
const TERRACE_Z: f32 = 22.0;
const PARAPET: f32 = 1.2;
const RAIL: f32 = 1.1;
const G_CEIL: f32 = 9.0;
const U_FLOOR: f32 = 10.0;
const U_CEIL: f32 = 18.0;
const UNDER_CEIL: f32 = 12.4;
const TUNNEL_CEIL: f32 = 4.5;
const DOOR_TOP: f32 = 3.6;
const PIT_Z: f32 = -6.0;
const DECK_UNDER: f32 = -0.4;
const PIT_DOOR_TOP: f32 = -3.5;
const CITY_H: f32 = 16.0;

// The hypogeum is a grid of corridors under the arena. West of DECK_X it is
// open to the sky between walls whose tops are walkable; east of it the
// modern wooden deck covers it.
const DECK_X: f32 = 10.0;
const HY_XS = [_]f32{ -30, -20.5, -19.5, -10.5, -9.5, -0.5, 0.5, DECK_X };
const HY_YS = [_]f32{ -18, -13, -12, -8, -7, -3, -2, 2, 3, 7, 8, 12, 13, 18 };
const HY_X1: f32 = 30.0;
const HY_CENTRE_BAND: usize = 6;
// Under the deck's east end a corridor runs north to south and joins every
// corridor, and in the open part a passage runs north to south under the
// wall tops through the cross wall at x = 0, so no corridor is a dead end.
const CROSS_W: f32 = 3.0;
const HY_PASSAGE_COL: usize = 5;

// Arches in the outer wall, by fraction along each bay's chord.
const ARCH_FS = [_]f32{ 0.225, 0.317, 0.408, 0.5, 0.592, 0.683, 0.775 };
const ARCH_HALF: f32 = 0.275;
const ARCH_G: f32 = 4.5;
const ARCH_U: f32 = 14.0;
const ARCH_RISE: f32 = 2.4;

const INF: f32 = 1.0e4;
// Walls that reach the sky are cut off this high in the polygon BSP.
const WALL_CAP: f32 = 300.0;

// Bays with stairs from the lower ambulatory to the upper one, with stairs
// from the upper ambulatory to the top terrace (two bays each), and with the
// passages from the outside to the arena.
const STAIR_A_BAYS = [_]i32{ 6, 30 };
const STAIR_T_BAYS = [_]i32{ 18, 42 };
const TUNNEL_BAYS = [_]i32{ 0, 24 };
const STAIR_A_STEPS: usize = 20;
const STAIR_T_STEPS: usize = 24;
const LANDING_S: f32 = 43.0;
const LANE_S: f32 = 45.0;
// The emperor's box on the south side of the podium.
const PULVINAR_BAY: i32 = 36;

const STEP_UP: f32 = 0.55;
const PLAYER_H: f32 = 1.8;
const PLAYER_R: f32 = 0.35;
const GRAVITY: f32 = 0.0025;
const JUMP_V: f32 = 0.0742;
const JUMP_SLACK: f32 = 0.1;
const MOVE_STEP: f32 = 0.1;
const TURN_STEP: f32 = 0.042;

const EYE_Z: f32 = 1.6;
const FOCAL: f32 = 340.0;
const HALF_W: f32 = 320.0;
const BASE_HORIZON: f32 = 256.0;
const NEAR: f32 = 0.05;

const LOOK_STEP: f32 = 8.0;
const LOOK_UP_MAX: f32 = 480.0;
const LOOK_DOWN_MAX: f32 = 300.0;
const MOUSE_TURN: f32 = 0.0025;
const MOUSE_LOOK: f32 = FOCAL * MOUSE_TURN;

const MESSAGE_MS: i32 = 2400;

// Gulls soar in wide circles above everything, then land on the seats, the
// parapet, the arena, the hypogeum's wall tops, or the street outside.
const MAX_BIRDS: usize = 40;
const GULLS_DOWN: usize = 12;
const GULL_SPEED: f32 = 0.14; // About 9 m/s.
const GULL_SPAN: f32 = 1.3;
const BIRD_SCALE: f32 = 1.3;
// Every flight between perches and circles stays above the highest wall top.
const CRUISE_Z: f32 = 27.0;
const STARTLE_DIST: f32 = 4.5;

// Pressing G turns the player into a gull. It glides forward all the time,
// sinking slowly; holding forward or Space flaps to climb, and holding back
// dives, which is faster. It cannot pick up tesserae or sit in the box.
const FLY_R: f32 = 0.25;
const FLY_EYE: f32 = 0.1;
const FLY_TOP: f32 = 70.0;
const FLY_GLIDE: f32 = 0.15; // About 9 m/s.
const FLY_CLIMB_SPEED: f32 = 0.12;
const FLY_DIVE_SPEED: f32 = 0.27;
const FLY_ACCEL: f32 = 0.003;
const FLY_SINK: f32 = 0.012;
const FLY_CLIMB: f32 = 0.045;
const FLY_DIVE: f32 = 0.11;
// Clearance above a floor while skimming it, and the ledge it skims over.
const FLY_SKIM: Body = .{ .step = 0.3, .h = 2.0 * FLY_R };

// The sun follows its path over Rome on 21 April, from 10:00 to 14:00 local
// solar time, one hour every 2.5 minutes of play.
const ROME_LATITUDE: f32 = 41.9 * std.math.pi / 180.0;
const SUN_DECLINATION: f32 = 11.6 * std.math.pi / 180.0;
const SUN_FIRST_HOUR: f32 = 10.0;
const SUN_HOURS: f32 = 4.0;
const SUN_DAY_MS: i32 = 600_000;
const SUN_DISC: f32 = 0.022;
const SUN_HALO: f32 = 0.2;

const MAX_PICKUPS: usize = 8;
const ALL_TESSERAE: u8 = 0xFF;
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
const C_MAP_PLAYER: Color = .{ 0x6A, 0xE0, 0xFF, 0xFF };
const C_MAP_BIRD: Color = .{ 0xE8, 0xEC, 0xF0, 0xFF };
const C_TESSERA: Color = .{ 0xE8, 0xDC, 0xC0, 0xFF };
const C_TESSERA_DIM: Color = .{ 0x4A, 0x44, 0x3A, 0xFF };

// Level geometry

const Kind = enum(u8) { outside, arch, parapet, amb_g, amb_u, terrace, seats, podium, arena, deck, wall_top, pit, covered, doorway, tunnel, stair_a, landing, lane_b, stair_t };

// Floors and ceilings are planes z = z0 + gx * x + gy * y.
const Plane = struct { z0: f32, gx: f32 = 0, gy: f32 = 0 };

const Sector = struct {
    kind: Kind,
    floor: Plane,
    ceil: Plane,
    // Open to the sky: no ceiling.
    sky: bool,
    // The bay a ring cell lies in, so shading can find its place on the
    // ring without an arctangent; -1 for the arena and hypogeum.
    bay: i8 = -1,
    first_vert: u32 = 0,
    vert_count: u32 = 0,
    first_edge: u32 = 0,
    edge_count: u32 = 0,
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
};

// A sector's side, cut wherever a neighbour's side begins or ends. Its spans
// stack from the floor to the ceiling: solid wall, an opening into another
// sector, or open sky.
const Edge = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    // Outward unit normal; n . p = d along the line.
    nx: f32,
    ny: f32,
    d: f32,
    len: f32,
    u0: f32,
    sector: u16,
    first_span: u32,
    span_count: u32,
};

const SpanKind = enum(u8) { solid, open, sky };
const WallMat = enum(u8) { travertine, facade, city, brick, tufa, podium, riser };

// Heights at the edge's two ends; the span is linear between them.
const Span = struct {
    lo1: f32,
    lo2: f32,
    hi1: f32,
    hi2: f32,
    kind: SpanKind,
    next: u16 = NO_SECTOR,
    mat: WallMat = .travertine,
    edge: u32 = 0,
};

const MAX_SECTORS: usize = 2048;
const MAX_VERTS: usize = 8192;
const MAX_EDGES: usize = 12288;
const MAX_SPANS: usize = 32768;
const NO_SECTOR: u16 = 0xFFFF;
const NO_EDGE: u32 = 0xFFFF_FFFF;
const MAX_OPEN: usize = 16;
const MAX_CUTS: usize = 96;
const MAX_OVERLAPS: usize = 48;

var sectors: [MAX_SECTORS]Sector = undefined;
var sector_count: usize = 0;
var verts: [MAX_VERTS][2]f32 = undefined;
var vert_count: usize = 0;
var edges: [MAX_EDGES]Edge = undefined;
var edge_count: usize = 0;
var spans: [MAX_SPANS]Span = undefined;
var span_count: usize = 0;
var level_built = false;

// Game state

const BirdMode = enum(u8) { ground, fly, circle };
const Route = enum(u8) { soar, land, depart };

const Bird = struct {
    active: bool = false,
    mode: BirdMode = .ground,
    route: Route = .soar,
    leg: u8 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    hx: f32 = 1,
    hy: f32 = 0,
    tx: f32 = 0,
    ty: f32 = 0,
    tz: f32 = 0,
    speed: f32 = 0,
    cx: f32 = 0,
    cy: f32 = 0,
    r: f32 = 0,
    ang: f32 = 0,
    spin: f32 = 0,
    timer_ms: i32 = 0,
    spot: u8 = 0,
    flap: f32 = 0,
    glide: bool = true,
    light: f32 = 1,
};

// Where a gull may stand, and which way it comes in from: the approach
// point lies along (ox, oy) over open ground.
const Perch = struct { x: f32, y: f32, z: f32, ox: f32, oy: f32 };
const MAX_PERCHES: usize = 48;

const Pickup = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    light: f32 = 1,
};

const Mode = enum(u8) { title, playing, paused, won };
const Engine = enum(u8) { build, bsp };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var depth_buf: [SCREEN_W * SCREEN_H]u16 = undefined;

var birds: [MAX_BIRDS]Bird = [_]Bird{.{}} ** MAX_BIRDS;
var perches: [MAX_PERCHES]Perch = undefined;
var perch_count: usize = 0;
var perch_used: u64 = 0;
var pickups: [MAX_PICKUPS]Pickup = [_]Pickup{.{}} ** MAX_PICKUPS;

var mode: Mode = .title;
var engine: Engine = .build;
var keys_down: u8 = 0;
var pointer_down = false;
var mouse_total_x: i32 = 0;
var mouse_total_y: i32 = 0;
var mouse_used_x: i32 = 0;
var mouse_used_y: i32 = 0;
var jump_held = false;
var map_on = false;
var rng_state: u32 = 0x2F6B_A1C3;
var anim_ms: i32 = 0;
var time_ms: i32 = 0;

var px: f32 = 0;
var py: f32 = 0;
var pz: f32 = 0;
var psec: u16 = 0;
var fall_v: f32 = 0;
// While flying, pz is the gull's body, not the player's feet.
var flying = false;
var fly_speed: f32 = 0;
var fly_flap: f32 = 0;
var pangle: f32 = 0;
var look: f32 = 0;
var tesserae: u8 = 0;
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
// update left. Movement on the title screen or while paused is dropped.
fn applyMouseLook() void {
    if (phase != .updating) return;
    const dx: f32 = @floatFromInt(mouse_total_x -% mouse_used_x);
    const dy: f32 = @floatFromInt(mouse_total_y -% mouse_used_y);
    mouse_used_x = mouse_total_x;
    mouse_used_y = mouse_total_y;
    if (mode != .playing) return;
    pangle = wrapAngle(pangle - dx * MOUSE_TURN);
    look = clampf(look - dy * MOUSE_LOOK, -LOOK_DOWN_MAX, LOOK_UP_MAX);
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
            map_on = !map_on;
            return 1;
        },
        'b', 'B' => {
            setEngine(if (engine == .build) .bsp else .build);
            return 1;
        },
        'g', 'G' => {
            if (mode != .playing) return 0;
            if (flying) land() else takeWing();
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

// Benchmark hooks. A host comparing the two renderers picks one of the fixed
// views below and an engine, then times `render`. Flag 1 picks the polygon
// BSP, and flag 2 replaces textures and lighting with one flat colour per
// surface, which leaves mostly the cost of finding what each pixel sees. The
// view stays until it is set back to -1. Neither hook changes the game.

const View = struct { x: f32, y: f32, z: f32, angle: f32, look: f32 };
const BENCH_VIEWS = [_]View{
    // Outside, facing the arches of the west front.
    .{ .x = -100, .y = -12, .z = EYE_Z, .angle = 0.12, .look = 40 },
    // On the deck, looking west over the open hypogeum.
    .{ .x = 26, .y = -4, .z = EYE_Z, .angle = std.math.pi + 0.15, .look = -60 },
    // Down in a hypogeum corridor, looking east under the deck.
    .{ .x = -25, .y = 5, .z = PIT_Z + EYE_Z, .angle = 0.05, .look = 30 },
    // In the lower ambulatory, looking along its curve.
    .{ .x = 0, .y = 59.5, .z = EYE_Z, .angle = std.math.pi, .look = 0 },
    // On the top terrace, looking across the whole bowl.
    .{ .x = 0, .y = 57, .z = TERRACE_Z + EYE_Z, .angle = -std.math.pi / 2.0, .look = -90 },
    // Climbing the seats, looking along the cavea.
    .{ .x = 50, .y = 26, .z = 0, .angle = 2.4, .look = 20 },
};

var bench_view: i32 = -1;
var flat_shading = false;
const BENCH_BSP: i32 = 1;
const BENCH_FLAT: i32 = 2;

export fn bench_set_view(view: i32, flags: i32) i32 {
    if (phase == .initializing) {
        resetGame();
        phase = .ready;
    }
    flat_shading = false;
    if (view < 0 or view >= BENCH_VIEWS.len) {
        bench_view = -1;
        return 0;
    }
    bench_view = view;
    flat_shading = (flags & BENCH_FLAT) != 0;
    setEngine(if ((flags & BENCH_BSP) != 0) .bsp else .build);
    return 1;
}

// Work counts from the last frame: sector visits for the sector renderer;
// BSP nodes entered and polygons rasterized for the polygon renderer.
export fn bench_stat(which: i32) u32 {
    return switch (which) {
        0 => stat_visits,
        1 => stat_nodes,
        2 => stat_polys,
        3 => @intCast(sector_count),
        4 => @intCast(edge_count),
        5 => @intCast(bsp_poly_count),
        6 => @intCast(bnode_count),
        7 => @intCast(bsp_depth),
        else => 0,
    };
}

fn setEngine(e: Engine) void {
    engine = e;
    if (engine == .bsp) ensureBsp();
}

// Level construction

var unit_pts: [NB][2]f32 = undefined;

fn initUnitPts() void {
    for (&unit_pts, 0..) |*p, k| {
        const th = (@as(f32, @floatFromInt(k)) - 0.5) * DTH;
        p.* = .{ EX * @cos(th), @sin(th) };
    }
}

// Grid vertex k on the unit ring, where bay k begins.
inline fn unitPt(k: i32) [2]f32 {
    return unit_pts[@intCast(@mod(k, NB))];
}

// A point on ring s, a fraction g of the way along the chord from grid
// vertex k to k + 1. Every cell computes shared corners the same way, so
// neighbours agree on them exactly.
fn chordPt(s: f32, k: i32, g: f32) [2]f32 {
    const a = unitPt(k);
    if (g <= 0) return .{ s * a[0], s * a[1] };
    const b = unitPt(k + 1);
    if (g >= 1) return .{ s * b[0], s * b[1] };
    return .{ s * (a[0] + (b[0] - a[0]) * g), s * (a[1] + (b[1] - a[1]) * g) };
}

const ChordPos = struct { k: i32, g: f32, s: f32, chord: f32 };

// The ring, bay, and fraction along the bay's chord of a point in plan.
fn chordCoords(x: f32, y: f32) ChordPos {
    const th = std.math.atan2(y, x / EX);
    return chordIn(@intFromFloat(@floor(th / DTH + 0.5)), x, y);
}

// The same, for a point known to lie in bay k.
inline fn chordIn(k: i32, x: f32, y: f32) ChordPos {
    const a = unitPt(k);
    const b = unitPt(k + 1);
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const c = ey * a[0] - ex * a[1];
    var s = (ey * x - ex * y) / c;
    if (@abs(s) < 1e-3) s = 1e-3;
    const g = ((x / s - a[0]) * ex + (y / s - a[1]) * ey) / (ex * ex + ey * ey);
    return .{ .k = @mod(k, NB), .g = g, .s = s, .chord = @sqrt(ex * ex + ey * ey) * s };
}

// A point's place on the ring, using its sector's bay when it has one.
inline fn ringPos(si: u16, x: f32, y: f32) ChordPos {
    const bay = (&sectors)[si].bay;
    return if (bay >= 0) chordIn(bay, x, y) else chordCoords(x, y);
}

fn level(z: f32) Plane {
    return .{ .z0 = z };
}

inline fn planeZ(p: Plane, x: f32, y: f32) f32 {
    return p.z0 + p.gx * x + p.gy * y;
}

fn planeThrough(a: [3]f32, b: [3]f32, c: [3]f32) Plane {
    const ux = b[0] - a[0];
    const uy = b[1] - a[1];
    const uz = b[2] - a[2];
    const vx = c[0] - a[0];
    const vy = c[1] - a[1];
    const vz = c[2] - a[2];
    const nx = uy * vz - uz * vy;
    const ny = uz * vx - ux * vz;
    const nz = ux * vy - uy * vx;
    const gx = -nx / nz;
    const gy = -ny / nz;
    return .{ .z0 = a[2] - gx * a[0] - gy * a[1], .gx = gx, .gy = gy };
}

fn seatZ(s: f32) f32 {
    return SEAT_LO + (s - S_POD) * (SEAT_HI - SEAT_LO) / (S_SEAT - S_POD);
}

fn beginSector(kind: Kind, floor: Plane, ceil: ?Plane) void {
    if (sector_count >= MAX_SECTORS) @trap();
    (&sectors)[sector_count] = .{ .kind = kind, .floor = floor, .ceil = ceil orelse level(INF), .sky = ceil == null, .first_vert = @intCast(vert_count) };
}

fn addVert(p: [2]f32) void {
    if (vert_count >= MAX_VERTS) @trap();
    (&verts)[vert_count] = p;
    vert_count += 1;
}

fn endSector() void {
    const s = &sectors[sector_count];
    s.vert_count = @as(u32, @intCast(vert_count)) - s.first_vert;
    if (s.vert_count < 3) {
        vert_count = s.first_vert;
        return;
    }
    s.min_x = std.math.inf(f32);
    s.min_y = std.math.inf(f32);
    s.max_x = -std.math.inf(f32);
    s.max_y = -std.math.inf(f32);
    for (verts[s.first_vert..vert_count]) |p| {
        s.min_x = @min(s.min_x, p[0]);
        s.min_y = @min(s.min_y, p[1]);
        s.max_x = @max(s.max_x, p[0]);
        s.max_y = @max(s.max_y, p[1]);
    }
    sector_count += 1;
}

// A cell between rings sa and sb and fractions g0 and g1 of bay k, counter
// clockwise. Outside cells carry the arch points on their inner chord, so
// linking cuts every façade wall at the same places.
fn addCell(kind: Kind, sa: f32, sb: f32, k: i32, g0: f32, g1: f32, floor: Plane, ceil: ?Plane, inner_arches: bool) void {
    beginSector(kind, floor, ceil);
    sectors[sector_count].bay = @intCast(@mod(k, NB));
    addVert(chordPt(sa, k, g0));
    addVert(chordPt(sb, k, g0));
    addVert(chordPt(sb, k, g1));
    addVert(chordPt(sa, k, g1));
    if (inner_arches) {
        var i: usize = ARCH_FS.len;
        while (i > 0) {
            i -= 1;
            const f = ARCH_FS[i];
            if (f > g0 and f < g1) addVert(chordPt(sa, k, f));
        }
    }
    endSector();
}

fn addRect(kind: Kind, x0: f32, y0: f32, x1: f32, y1: f32, floor: Plane, ceil: ?Plane) void {
    beginSector(kind, floor, ceil);
    addVert(.{ x0, y0 });
    addVert(.{ x1, y0 });
    addVert(.{ x1, y1 });
    addVert(.{ x0, y1 });
    endSector();
}

const MAX_CLIP: usize = 96;

// Keeps the part of a convex polygon where a * x + b * y <= c.
fn clipHalf(src: []const [2]f32, dst: *[MAX_CLIP][2]f32, a: f32, b: f32, c: f32) usize {
    var n: usize = 0;
    for (src, 0..) |p, i| {
        const q = src[(i + 1) % src.len];
        const sp = a * p[0] + b * p[1] - c;
        const sq = a * q[0] + b * q[1] - c;
        if (sp <= 0) {
            dst[n] = p;
            n += 1;
        }
        if ((sp < 0 and sq > 0) or (sp > 0 and sq < 0)) {
            const t = sp / (sp - sq);
            dst[n] = .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
            n += 1;
        }
    }
    return n;
}

// The arena floor around the hypogeum: the arena's outline cut into the
// four pieces outside the hypogeum's rectangle.
fn addArenaPiece(cuts: []const [3]f32) void {
    var a: [MAX_CLIP][2]f32 = undefined;
    var b: [MAX_CLIP][2]f32 = undefined;
    var n: usize = 0;
    var k: i32 = 0;
    while (k < NB) : (k += 1) {
        a[n] = chordPt(S_ARENA, k, 0);
        n += 1;
    }
    for (cuts) |cut| {
        n = clipHalf(a[0..n], &b, cut[0], cut[1], cut[2]);
        @memcpy(a[0..n], b[0..n]);
    }
    beginSector(.arena, level(0), null);
    // Drop points that clipping left on top of each other.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = a[i];
        const q = a[(i + 1) % n];
        if (@abs(p[0] - q[0]) + @abs(p[1] - q[1]) > 1e-4) addVert(p);
    }
    endSector();
}

// An arch through the outer wall of bay k: one cell between each pair of
// points in ARCH_FS, so its sides follow the arch's outline. The vault over
// each cell is the plane through the arch's height at both ends of its inner
// chord and their mean at the middle of its outer chord, which keeps it
// within a few centimetres of the arch across the wall's thickness.
fn addArch(k: i32, floor_z: f32, spring: f32) void {
    var i: usize = 0;
    while (i + 1 < ARCH_FS.len) : (i += 1) {
        const g0 = ARCH_FS[i];
        const g1 = ARCH_FS[i + 1];
        const h0 = archCurve(spring, g0);
        const h1 = archCurve(spring, g1);
        const a = chordPt(S_OUTER, k, g0);
        const b = chordPt(S_OUTER, k, g1);
        const m = chordPt(S_FACE, k, (g0 + g1) * 0.5);
        const vault = planeThrough(.{ a[0], a[1], h0 }, .{ b[0], b[1], h1 }, .{ m[0], m[1], (h0 + h1) * 0.5 });
        addCell(.arch, S_OUTER, S_FACE, k, g0, g1, level(floor_z), vault, false);
    }
}

fn isStairA(k: i32) bool {
    for (STAIR_A_BAYS) |b| if (k == b) return true;
    return false;
}

fn isStairT(k: i32) bool {
    for (STAIR_T_BAYS) |b| if (k == b or k == b + 1) return true;
    return false;
}

fn isTunnel(k: i32) bool {
    for (TUNNEL_BAYS) |b| if (k == b) return true;
    return false;
}

fn buildLevel() void {
    if (level_built) return;
    initUnitPts();
    sector_count = 0;
    vert_count = 0;

    var k: i32 = 0;
    while (k < NB) : (k += 1) {
        addCell(.outside, S_FACE, S_CITY, k, 0, 1, level(0), null, true);
        addCell(.amb_g, S_INNER, S_OUTER, k, 0, 1, level(0), level(G_CEIL), false);
        const outer: f32 = if (isStairT(k)) S_SPLIT else S_OUTER;
        addCell(.amb_u, S_INNER, outer, k, 0, 1, level(U_FLOOR), level(U_CEIL), false);
        addArch(k, 0, ARCH_G);
        if (!isStairT(k)) addArch(k, U_FLOOR, ARCH_U);
        addCell(.parapet, S_OUTER, S_FACE, k, 0, 1, level(TERRACE_Z + PARAPET), null, false);
        addCell(.terrace, S_SEAT, outer, k, 0, 1, level(TERRACE_Z), null, false);
        const a = chordPt(S_POD, k, 0);
        const b = chordPt(S_SEAT, k, 0);
        const c = chordPt(S_POD, k, 1);
        const seats = planeThrough(.{ a[0], a[1], SEAT_LO }, .{ b[0], b[1], SEAT_HI }, .{ c[0], c[1], SEAT_LO });
        addCell(.seats, S_POD, S_SEAT, k, 0, 1, seats, null, false);
        addCell(.podium, S_ARENA, S_POD, k, 0, 1, level(POD_Z), null, false);
        if (isTunnel(k)) {
            addCell(.tunnel, S_ARENA, S_POD, k, 0, 1, level(0), level(TUNNEL_CEIL), false);
            addCell(.tunnel, S_POD, S_SEAT, k, 0, 1, level(0), level(TUNNEL_CEIL), false);
            addCell(.tunnel, S_SEAT, S_INNER, k, 0, 1, level(0), level(TUNNEL_CEIL), false);
        }
        if (isStairA(k)) {
            // Steps climb inward from the lower ambulatory to a landing, and
            // a level lane beside them leads back out to the upper one.
            const run = (S_INNER - LANE_S) / @as(f32, STAIR_A_STEPS);
            var i: usize = 0;
            while (i < STAIR_A_STEPS) : (i += 1) {
                const fi: f32 = @floatFromInt(i);
                const z = (fi + 1.0) * (U_FLOOR / @as(f32, STAIR_A_STEPS));
                const s1 = if (i == 0) S_INNER else S_INNER - fi * run;
                const s0 = if (i + 1 == STAIR_A_STEPS) LANE_S else S_INNER - (fi + 1.0) * run;
                addCell(.stair_a, s0, s1, k, 0, 0.5, level(z), level(UNDER_CEIL), false);
            }
            addCell(.landing, LANDING_S, LANE_S, k, 0, 1, level(U_FLOOR), level(UNDER_CEIL), false);
            addCell(.lane_b, LANE_S, S_INNER, k, 0.5, 1, level(U_FLOOR), level(UNDER_CEIL), false);
        }
    }
    // Stairs from the upper ambulatory to the terrace climb along the outer
    // half of two bays, open to the sky.
    for (STAIR_T_BAYS) |b| {
        const per: usize = STAIR_T_STEPS / 2;
        var i: usize = 0;
        while (i < STAIR_T_STEPS) : (i += 1) {
            const bay = b + @as(i32, @intCast(i / per));
            const j: f32 = @floatFromInt(i % per);
            const g0 = j / @as(f32, per);
            const g1 = if (i % per + 1 == per) 1.0 else (j + 1.0) / @as(f32, per);
            const z = U_FLOOR + (@as(f32, @floatFromInt(i)) + 1.0) * ((TERRACE_Z - U_FLOOR) / @as(f32, STAIR_T_STEPS));
            addCell(.stair_t, S_SPLIT, S_OUTER, bay, g0, g1, level(z), null, false);
        }
    }

    // The arena floor and the hypogeum.
    addArenaPiece(&.{.{ 1, 0, HY_XS[0] }});
    addArenaPiece(&.{.{ -1, 0, -HY_X1 }});
    addArenaPiece(&.{ .{ 0, -1, -HY_YS[HY_YS.len - 1] }, .{ -1, 0, -HY_XS[0] }, .{ 1, 0, HY_X1 } });
    addArenaPiece(&.{ .{ 0, 1, HY_YS[0] }, .{ -1, 0, -HY_XS[0] }, .{ 1, 0, HY_X1 } });
    addRect(.deck, DECK_X, HY_YS[0], HY_X1, HY_YS[HY_YS.len - 1], level(0), null);
    const ramp_gx = PIT_Z / (HY_XS[1] - HY_XS[0]);
    const ramp = Plane{ .z0 = -ramp_gx * HY_XS[0], .gx = ramp_gx };
    var band: usize = 0;
    while (band + 1 < HY_YS.len) : (band += 1) {
        const y0 = HY_YS[band];
        const y1 = HY_YS[band + 1];
        const corridor = band % 2 == 0;
        var i: usize = 0;
        while (i + 1 < HY_XS.len) : (i += 1) {
            const x0 = HY_XS[i];
            const x1 = HY_XS[i + 1];
            if (!corridor) {
                if (i == HY_PASSAGE_COL) addRect(.doorway, x0, y0, x1, y1, level(PIT_Z), level(PIT_DOOR_TOP));
                addRect(.wall_top, x0, y0, x1, y1, level(0), null);
            } else if (i % 2 == 0 or band == HY_CENTRE_BAND) {
                const floor = if (i == 0 and band == HY_CENTRE_BAND) ramp else level(PIT_Z);
                addRect(.pit, x0, y0, x1, y1, floor, null);
            } else {
                // A doorway through a cross wall, under the wall's top.
                addRect(.doorway, x0, y0, x1, y1, level(PIT_Z), level(PIT_DOOR_TOP));
                addRect(.wall_top, x0, y0, x1, y1, level(0), null);
            }
        }
        if (corridor) addRect(.covered, DECK_X, y0, HY_X1 - CROSS_W, y1, level(PIT_Z), level(DECK_UNDER));
    }
    addRect(.covered, HY_X1 - CROSS_W, HY_YS[0], HY_X1, HY_YS[HY_YS.len - 1], level(PIT_Z), level(DECK_UNDER));
    linkLevel();
    level_built = true;
}

// Linking finds, for every side of every sector, the sides of other sectors
// that lie on the same line facing the other way. The side is cut where they
// begin and end, and each piece gets the openings its neighbours allow.

const Overlap = struct { sector: u16, lo: f32, hi: f32 };

fn linkLevel() void {
    edge_count = 0;
    span_count = 0;
    for (0..sector_count) |si| {
        const s = &sectors[si];
        s.first_edge = @intCast(edge_count);
        var i: u32 = 0;
        while (i < s.vert_count) : (i += 1) {
            const a = (&verts)[s.first_vert + i];
            const b = (&verts)[s.first_vert + (i + 1) % s.vert_count];
            linkSide(si, a, b);
        }
        s.edge_count = @as(u32, @intCast(edge_count)) - s.first_edge;
    }
}

fn linkSide(si: usize, a: [2]f32, b: [2]f32) void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-4) return;
    const ux = dx / len;
    const uy = dy / len;
    var overlaps: [MAX_OVERLAPS]Overlap = undefined;
    var no: usize = 0;
    var cuts: [MAX_CUTS]f32 = undefined;
    cuts[0] = 0;
    cuts[1] = 1;
    var nc: usize = 2;
    const lo_x = @min(a[0], b[0]) - 0.01;
    const hi_x = @max(a[0], b[0]) + 0.01;
    const lo_y = @min(a[1], b[1]) - 0.01;
    const hi_y = @max(a[1], b[1]) + 0.01;
    for (0..sector_count) |ti| {
        if (ti == si) continue;
        const t = (&sectors)[ti];
        if (t.max_x < lo_x or t.min_x > hi_x or t.max_y < lo_y or t.min_y > hi_y) continue;
        var j: u32 = 0;
        while (j < t.vert_count) : (j += 1) {
            const c = (&verts)[t.first_vert + j];
            const d = (&verts)[t.first_vert + (j + 1) % t.vert_count];
            if ((d[0] - c[0]) * ux + (d[1] - c[1]) * uy >= 0) continue;
            const oc = (c[0] - a[0]) * uy - (c[1] - a[1]) * ux;
            const od = (d[0] - a[0]) * uy - (d[1] - a[1]) * ux;
            if (@abs(oc) > 2e-3 or @abs(od) > 2e-3) continue;
            const pc = ((c[0] - a[0]) * ux + (c[1] - a[1]) * uy) / len;
            const pd = ((d[0] - a[0]) * ux + (d[1] - a[1]) * uy) / len;
            const lo = maxf(0.0, @min(pc, pd));
            const hi = @min(1.0, @max(pc, pd));
            if (hi - lo < 1e-5) continue;
            if (no >= MAX_OVERLAPS or nc + 2 > MAX_CUTS) @trap();
            overlaps[no] = .{ .sector = @intCast(ti), .lo = lo, .hi = hi };
            no += 1;
            cuts[nc] = lo;
            cuts[nc + 1] = hi;
            nc += 2;
        }
    }
    sortFloats(cuts[0..nc]);
    var i: usize = 0;
    while (i + 1 < nc) : (i += 1) {
        const p = cuts[i];
        var j = i + 1;
        while (j < nc and cuts[j] - p < 1e-5) j += 1;
        if (j >= nc) break;
        const q = cuts[j];
        i = j - 1;
        const mid = (p + q) * 0.5;
        var nbs: [MAX_OPEN]u16 = undefined;
        var nn: usize = 0;
        for (overlaps[0..no]) |o| {
            if (o.lo > mid or o.hi < mid) continue;
            var seen = false;
            for (nbs[0..nn]) |s| seen = seen or s == o.sector;
            if (seen or nn >= MAX_OPEN) continue;
            nbs[nn] = o.sector;
            nn += 1;
        }
        const pa: [2]f32 = if (p <= 0) a else .{ a[0] + dx * p, a[1] + dy * p };
        const pb: [2]f32 = if (q >= 1) b else .{ a[0] + dx * q, a[1] + dy * q };
        makeEdge(si, pa, pb, p * len, nbs[0..nn]);
    }
}

fn sortFloats(v: []f32) void {
    var i: usize = 1;
    while (i < v.len) : (i += 1) {
        const x = v[i];
        var j = i;
        while (j > 0 and v[j - 1] > x) : (j -= 1) v[j] = v[j - 1];
        v[j] = x;
    }
}

const Open = struct { next: u16, lo1: f32, lo2: f32, hi1: f32, hi2: f32, kind: SpanKind = .open };

fn ceilZ(s: Sector, x: f32, y: f32) f32 {
    return if (s.sky) INF else planeZ(s.ceil, x, y);
}

fn makeEdge(si: usize, a: [2]f32, b: [2]f32, start_u: f32, nbs: []const u16) void {
    if (edge_count >= MAX_EDGES) @trap();
    const s = (&sectors)[si];
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    const nx = dy / len;
    const ny = -dx / len;
    const ei: u32 = @intCast(edge_count);
    (&edges)[edge_count] = .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .nx = nx, .ny = ny, .d = nx * a[0] + ny * a[1], .len = len, .u0 = start_u, .sector = @intCast(si), .first_span = @intCast(span_count), .span_count = 0 };
    edge_count += 1;

    const f1 = planeZ(s.floor, a[0], a[1]);
    const f2 = planeZ(s.floor, b[0], b[1]);
    const c1 = ceilZ(s, a[0], a[1]);
    const c2 = ceilZ(s, b[0], b[1]);
    var opens: [MAX_OPEN + 1]Open = undefined;
    var n: usize = 0;
    for (nbs) |ti| {
        const t = (&sectors)[ti];
        var o = Open{
            .next = ti,
            .lo1 = @max(f1, planeZ(t.floor, a[0], a[1])),
            .lo2 = @max(f2, planeZ(t.floor, b[0], b[1])),
            .hi1 = @min(c1, ceilZ(t, a[0], a[1])),
            .hi2 = @min(c2, ceilZ(t, b[0], b[1])),
        };
        if (!shapeOpening(si, ti, a, b, &o)) continue;
        if (o.hi1 - o.lo1 < 0.01 and o.hi2 - o.lo2 < 0.01) continue;
        opens[n] = o;
        n += 1;
    }
    // A wall with nothing behind it under the open sky stops at its top.
    if (s.sky and n == 0) {
        const top = wallTop(si, a, b);
        opens[n] = .{ .next = NO_SECTOR, .lo1 = top, .lo2 = top, .hi1 = INF, .hi2 = INF, .kind = .sky };
        n += 1;
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const o = opens[i];
        var j = i;
        while (j > 0 and opens[j - 1].lo1 + opens[j - 1].lo2 > o.lo1 + o.lo2) : (j -= 1) opens[j] = opens[j - 1];
        opens[j] = o;
    }
    const mid: [2]f32 = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
    var cur1 = f1;
    var cur2 = f2;
    for (opens[0..n]) |o| {
        const lo1 = @max(o.lo1, cur1);
        const lo2 = @max(o.lo2, cur2);
        const hi1 = @max(o.hi1, lo1);
        const hi2 = @max(o.hi2, lo2);
        if (lo1 > cur1 + 1e-3 or lo2 > cur2 + 1e-3) addSpan(ei, .{ .lo1 = cur1, .lo2 = cur2, .hi1 = lo1, .hi2 = lo2, .kind = .solid, .mat = solidMat(si, mid, cur1) });
        addSpan(ei, .{ .lo1 = lo1, .lo2 = lo2, .hi1 = hi1, .hi2 = hi2, .kind = o.kind, .next = o.next });
        cur1 = hi1;
        cur2 = hi2;
    }
    if (c1 > cur1 + 1e-3 or c2 > cur2 + 1e-3) addSpan(ei, .{ .lo1 = cur1, .lo2 = cur2, .hi1 = @max(c1, cur1), .hi2 = @max(c2, cur2), .kind = .solid, .mat = solidMat(si, mid, cur1) });
}

fn addSpan(ei: u32, sp: Span) void {
    if (span_count >= MAX_SPANS) @trap();
    var s = sp;
    s.edge = ei;
    (&spans)[span_count] = s;
    span_count += 1;
    (&edges)[ei].span_count += 1;
}

fn pair(a: Kind, b: Kind, x: Kind, y: Kind) bool {
    return (a == x and b == y) or (a == y and b == x);
}

fn otherOf(si: usize, ti: usize, kind: Kind) Sector {
    return if (sectors[si].kind == kind) (&sectors)[si] else (&sectors)[ti];
}

fn archCurve(spring: f32, g: f32) f32 {
    const f = (g - 0.5) / ARCH_HALF;
    return spring + ARCH_RISE * @sqrt(maxf(0.0, 1.0 - f * f));
}

// The arch's top at a fraction along the bay: straight between the points
// in ARCH_FS, so walls cut at other places still trace the same outline.
fn archTop(spring: f32, g: f32) f32 {
    var i: usize = 0;
    while (i + 2 < ARCH_FS.len and g > ARCH_FS[i + 1]) i += 1;
    const g0 = ARCH_FS[i];
    const g1 = ARCH_FS[i + 1];
    const t = clampf((g - g0) / (g1 - g0), 0.0, 1.0);
    return lerp(archCurve(spring, g0), archCurve(spring, g1), t);
}

// Design rules for openings: arches in the outer wall, parapets, balustrades
// beside stairwells, and doorways. Each depends only on the pair of sectors
// and the place, so both sides of a wall agree. Returns false to close it.
fn shapeOpening(si: usize, ti: usize, a: [2]f32, b: [2]f32, o: *Open) bool {
    const ka = (&sectors)[si].kind;
    const kb = (&sectors)[ti].kind;
    // Both faces of an arch follow its curve exactly.
    if ((ka == .arch) != (kb == .arch)) {
        const spring = if (otherOf(si, ti, .arch).floor.z0 < 1.0) ARCH_G else ARCH_U;
        o.hi1 = @min(o.hi1, archTop(spring, chordCoords(a[0], a[1]).g));
        o.hi2 = @min(o.hi2, archTop(spring, chordCoords(b[0], b[1]).g));
        return true;
    }
    if (pair(ka, kb, .podium, .arena)) {
        o.lo1 = @max(o.lo1, POD_Z + PARAPET);
        o.lo2 = @max(o.lo2, POD_Z + PARAPET);
        return true;
    }
    if (pair(ka, kb, .amb_g, .stair_a)) {
        o.hi1 = @min(o.hi1, DOOR_TOP);
        o.hi2 = @min(o.hi2, DOOR_TOP);
        return true;
    }
    if (pair(ka, kb, .amb_u, .stair_a)) return false;
    if (pair(ka, kb, .stair_a, .lane_b)) {
        o.lo1 = @max(o.lo1, U_FLOOR + RAIL);
        o.lo2 = @max(o.lo2, U_FLOOR + RAIL);
        return true;
    }
    if (pair(ka, kb, .terrace, .stair_t)) {
        if (otherOf(si, ti, .stair_t).floor.z0 < TERRACE_Z - 0.6) {
            o.lo1 = @max(o.lo1, TERRACE_Z + RAIL);
            o.lo2 = @max(o.lo2, TERRACE_Z + RAIL);
        }
        return true;
    }
    return true;
}

// Where a wall under the open sky ends when nothing stands behind it: the
// city's buildings around the outside, or a low wall anywhere else.
fn wallTop(si: usize, a: [2]f32, b: [2]f32) f32 {
    const s = (&sectors)[si];
    const floor = @max(planeZ(s.floor, a[0], a[1]), planeZ(s.floor, b[0], b[1]));
    if (s.kind == .outside) return floor + CITY_H;
    return floor + 1.2;
}

fn solidMat(si: usize, mid: [2]f32, z: f32) WallMat {
    const s = (&sectors)[si];
    const p = chordCoords(mid[0], mid[1]);
    return switch (s.kind) {
        .outside => if (p.s > S_CITY - 1.0) .city else .facade,
        .arch, .parapet, .amb_g, .amb_u, .terrace, .stair_t, .landing, .lane_b => .travertine,
        .stair_a => if (z > 0.2 and p.s < S_INNER - 0.1) .riser else .travertine,
        .seats, .podium => .riser,
        .arena, .deck, .wall_top => .podium,
        .pit, .covered, .doorway => .brick,
        .tunnel => .tufa,
    };
}

fn insideSector(si: usize, x: f32, y: f32, eps: f32) bool {
    const s = (&sectors)[si];
    if (x < s.min_x - eps or x > s.max_x + eps or y < s.min_y - eps or y > s.max_y + eps) return false;
    var i = s.first_edge;
    while (i < s.first_edge + s.edge_count) : (i += 1) {
        const e = (&edges)[i];
        if (e.nx * x + e.ny * y - e.d > eps) return false;
    }
    return true;
}

// The sector holding a point: of the sectors stacked over it, the one whose
// floor and ceiling bracket z.
fn sectorAt(x: f32, y: f32, z: f32) u16 {
    var best: u16 = NO_SECTOR;
    var best_floor: f32 = -std.math.inf(f32);
    for (0..sector_count) |si| {
        if (!insideSector(si, x, y, 1e-3)) continue;
        const s = (&sectors)[si];
        const floor = planeZ(s.floor, x, y);
        if (floor > z + 0.05 or ceilZ(s, x, y) < z - 0.05) continue;
        if (floor > best_floor) {
            best = @intCast(si);
            best_floor = floor;
        }
    }
    return best;
}

fn floorAt(si: u16, x: f32, y: f32) f32 {
    return planeZ(sectors[si].floor, x, y);
}

// Walking

fn edgeParam(e: Edge, x: f32, y: f32) f32 {
    return clampf(((x - e.x1) * (e.x2 - e.x1) + (y - e.y1) * (e.y2 - e.y1)) / (e.len * e.len), 0.0, 1.0);
}

// Clamps without the libm calls that @min and @max on floats compile to;
// NaN clamps to lo.
inline fn clampf(v: f32, lo: f32, hi: f32) f32 {
    if (!(v > lo)) return lo;
    if (v > hi) return hi;
    return v;
}

inline fn minf(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

inline fn maxf(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// What has to fit through an opening: how far its sill may rise above the
// bottom of the body, and the body's height. A walker climbs steps; a gull
// in flight clears only what lies below it.
const Body = struct { step: f32, h: f32 };
const WALKER = Body{ .step = STEP_UP, .h = PLAYER_H };

// The sector a body with its bottom at z can pass into through an edge at
// fraction u, or NO_SECTOR. The opening must start no more than a step above
// the bottom and leave room above where the body will be.
fn passTarget(ei: u32, u: f32, z: f32) u16 {
    return passFor(ei, u, z, WALKER);
}

fn passFor(ei: u32, u: f32, z: f32, body: Body) u16 {
    const e = (&edges)[ei];
    var k = e.first_span;
    while (k < e.first_span + e.span_count) : (k += 1) {
        const sp = (&spans)[k];
        if (sp.kind != .open) continue;
        const lo = lerp(sp.lo1, sp.lo2, u);
        const hi = lerp(sp.hi1, sp.hi2, u);
        if (lo <= z + body.step and @max(z, lo) + body.h <= hi + 0.02) return sp.next;
    }
    return NO_SECTOR;
}

var near_secs: [24]u16 = undefined;

// The body's sector and those it could pass into within reach of a point.
fn gatherNear(home: u16, x: f32, y: f32, z: f32, reach: f32, body: Body) usize {
    near_secs[0] = home;
    var n: usize = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = (&sectors)[near_secs[i]];
        var ei = s.first_edge;
        while (ei < s.first_edge + s.edge_count) : (ei += 1) {
            const e = (&edges)[ei];
            const u = edgeParam(e, x, y);
            const cx = lerp(e.x1, e.x2, u);
            const cy = lerp(e.y1, e.y2, u);
            if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > reach * reach) continue;
            const t = passFor(ei, u, z, body);
            if (t == NO_SECTOR) continue;
            var seen = false;
            for (near_secs[0..n]) |q| seen = seen or q == t;
            if (seen or n >= near_secs.len) continue;
            near_secs[n] = t;
            n += 1;
        }
    }
    return n;
}

// Pushes a circle out of every wall it overlaps that it cannot pass.
fn pushOut(x: *f32, y: *f32, z: f32, r: f32, n: usize, body: Body) void {
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        var moved = false;
        for (near_secs[0..n]) |si| {
            const s = (&sectors)[si];
            var ei = s.first_edge;
            while (ei < s.first_edge + s.edge_count) : (ei += 1) {
                const e = (&edges)[ei];
                const u = edgeParam(e, x.*, y.*);
                const ex = x.* - lerp(e.x1, e.x2, u);
                const ey = y.* - lerp(e.y1, e.y2, u);
                const d2 = ex * ex + ey * ey;
                if (d2 >= r * r or d2 < 1e-12) continue;
                if (passFor(ei, u, z, body) != NO_SECTOR) continue;
                const d = @sqrt(d2);
                x.* += ex / d * (r - d);
                y.* += ey / d * (r - d);
                moved = true;
            }
        }
        if (!moved) break;
    }
}

// The first side of a convex sector that a segment or ray from (ox, oy)
// along (dx, dy) leaves through, as a parameter along it. Collinear pieces
// share a line, so the piece holding the crossing point is chosen.
fn exitEdge(si: u16, ox: f32, oy: f32, dx: f32, dy: f32, t_out: *f32) u32 {
    const s = (&sectors)[si];
    var best_t: f32 = INF;
    var best: u32 = NO_EDGE;
    var i = s.first_edge;
    const end = s.first_edge + s.edge_count;
    while (i < end) : (i += 1) {
        const e = (&edges)[i];
        const den = e.nx * dx + e.ny * dy;
        if (den <= 1e-9) continue;
        const t = (e.d - (e.nx * ox + e.ny * oy)) / den;
        if (t < best_t) {
            best_t = t;
            best = i;
        }
    }
    if (best == NO_EDGE) {
        t_out.* = INF;
        return NO_EDGE;
    }
    const hx = ox + dx * best_t;
    const hy = oy + dy * best_t;
    const first = (&edges)[best];
    i = s.first_edge;
    while (i < end) : (i += 1) {
        const e = (&edges)[i];
        if (@abs(e.nx - first.nx) + @abs(e.ny - first.ny) > 1e-4 or @abs(e.d - first.d) > 1e-3) continue;
        const p = ((hx - e.x1) * (e.x2 - e.x1) + (hy - e.y1) * (e.y2 - e.y1)) / (e.len * e.len);
        if (p >= -1e-4 and p <= 1.0 + 1e-4) {
            best = i;
            break;
        }
    }
    t_out.* = best_t;
    return best;
}

// Moves a walker's centre in a straight line, passing from sector to sector
// through the openings it fits. Returns false if a side blocks the way.
fn moveWalker(sec: *u16, x: *f32, y: *f32, z: f32, tx: f32, ty: f32, body: Body) bool {
    var s = sec.*;
    var ox = x.*;
    var oy = y.*;
    var hop: usize = 0;
    while (hop < 8) : (hop += 1) {
        var t: f32 = 0;
        const ei = exitEdge(s, ox, oy, tx - ox, ty - oy, &t);
        if (ei == NO_EDGE or t >= 1.0) {
            sec.* = s;
            x.* = tx;
            y.* = ty;
            return true;
        }
        t = @max(t, 0.0);
        const hx = ox + (tx - ox) * t;
        const hy = oy + (ty - oy) * t;
        const next = passFor(ei, edgeParam(edges[ei], hx, hy), z, body);
        if (next == NO_SECTOR) return false;
        s = next;
        ox = hx;
        oy = hy;
    }
    return false;
}

fn tryMove(mx: f32, my: f32) bool {
    return tryMoveAs(mx, my, pz, PLAYER_R, WALKER);
}

// Moves the player in plan with its bottom at z, sliding along walls.
fn tryMoveAs(mx: f32, my: f32, z: f32, r: f32, body: Body) bool {
    for ([_][2]f32{ .{ mx, my }, .{ mx, 0 }, .{ 0, my } }) |m| {
        if (m[0] == 0 and m[1] == 0) continue;
        var nx = px + m[0];
        var ny = py + m[1];
        const n = gatherNear(psec, nx, ny, z, r + 0.3, body);
        pushOut(&nx, &ny, z, r, n, body);
        var s = psec;
        var x = px;
        var y = py;
        if (moveWalker(&s, &x, &y, z, nx, ny, body)) {
            px = x;
            py = y;
            psec = s;
            return true;
        }
    }
    return false;
}

// Game state

// Where the tesserae lie: a point in plan and the floor height there.
fn tesseraSpot(i: usize) [3]f32 {
    return switch (i) {
        // Under the deck, in the dark.
        0 => .{ 24, 10, PIT_Z },
        // In an open hypogeum corridor.
        1 => .{ -5, -15.5, PIT_Z },
        // In the west passage under the seats.
        2 => withZ(chordPt(44, 24, 0.5), 0),
        // In the lower ambulatory, south.
        3 => withZ(chordPt(59, 36, 0.5), 0),
        // In the upper ambulatory, north-east.
        4 => withZ(chordPt(59, 9, 0.5), U_FLOOR),
        // On a stair landing under the seats.
        5 => withZ(chordPt(44, STAIR_A_BAYS[1], 0.5), U_FLOOR),
        // On the top terrace, west.
        6 => withZ(chordPt(58, 27, 0.5), TERRACE_Z),
        // High on the north seats.
        else => withZ(chordPt(50, 12, 0.5), seatZ(50)),
    };
}

fn withZ(p: [2]f32, z: f32) [3]f32 {
    return .{ p[0], p[1], z };
}

fn resetGame() void {
    buildLevel();
    mode = .title;
    birds = [_]Bird{.{}} ** MAX_BIRDS;
    pickups = [_]Pickup{.{}} ** MAX_PICKUPS;
    anim_ms = 0;
    time_ms = 0;
    px = -96;
    py = -1.5;
    pz = 0;
    psec = sectorAt(px, py, pz + 0.1);
    fall_v = 0;
    flying = false;
    fly_speed = 0;
    fly_flap = 0;
    pangle = 0;
    look = 30;
    tesserae = 0;
    score = 0;
    message = "";
    message_ms = 0;
    placeActors();
}

fn placeActors() void {
    for (0..MAX_PICKUPS) |i| {
        const spot = tesseraSpot(i);
        const z = spot[2];
        const si = sectorAt(spot[0], spot[1], z + 0.5);
        pickups[i] = .{ .active = si != NO_SECTOR, .x = spot[0], .y = spot[1], .z = z, .light = if (si == NO_SECTOR) 1 else lightAt(si, spot[0], spot[1], z + 0.5, 0, 0, 1) };
    }
    buildPerches();
    perch_used = 0;
    var n: usize = 0;
    while (n < MAX_BIRDS) : (n += 1) {
        const b = &birds[n];
        b.* = .{ .active = true, .flap = @floatFromInt(n) };
        if (n < GULLS_DOWN) {
            settle(b, @intCast(n * (perch_count / GULLS_DOWN)));
        } else {
            const c = soarCentre();
            const a = rngFloat(0, 2.0 * std.math.pi);
            const r = rngFloat(12, 36);
            b.x = c[0] + r * @cos(a);
            b.y = c[1] + r * @sin(a);
            b.z = rngFloat(CRUISE_Z, 44);
            circleAround(b, c[0], c[1], soarSpin(), rngRange(4000, 20000));
        }
    }
}

fn addPerch(x: f32, y: f32, z: f32, ox: f32, oy: f32) void {
    if (perch_count >= MAX_PERCHES) return;
    const l = @sqrt(ox * ox + oy * oy);
    perches[perch_count] = .{ .x = x, .y = y, .z = z, .ox = ox / l, .oy = oy / l };
    perch_count += 1;
}

fn buildPerches() void {
    perch_count = 0;
    var k: i32 = 1;
    while (k < NB) : (k += 4) {
        const s: f32 = 39.0 + @as(f32, @floatFromInt(@mod(k, 3))) * 5.0;
        const p = chordPt(s, k, 0.5);
        addPerch(p[0], p[1], seatZ(s), -p[0], -p[1]);
    }
    k = 3;
    while (k < NB) : (k += 6) {
        if (isStairT(k)) continue;
        const p = chordPt((S_OUTER + S_FACE) * 0.5, k, 0.1);
        addPerch(p[0], p[1], TERRACE_Z + PARAPET, -p[0], -p[1]);
    }
    for ([_][2]f32{ .{ 34, 5 }, .{ -34, -6 }, .{ 5, 23 }, .{ -12, -24 }, .{ 15, 10 }, .{ 24, -6 } }) |p| addPerch(p[0], p[1], 0, -p[0], -p[1]);
    for ([_][2]f32{ .{ -15, 7.5 }, .{ -25, -2.5 }, .{ -5, -12.5 } }) |p| addPerch(p[0], p[1], 0, 0, 1);
    for ([_]i32{ 3, 15, 27, 39, 45 }) |kk| {
        const p = chordPt(72, kk, 0.5);
        addPerch(p[0], p[1], 0, p[0], p[1]);
    }
}

fn startGame(at_ms: i64) void {
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

    if (flying) updateFlight() else updatePlayer();
    updateBirds();
    if (!flying) collectPickups();
    if (!flying and tesserae == ALL_TESSERAE and inPulvinar(px, py, pz)) {
        const seconds: u32 = @intCast(@divTrunc(time_ms, 1000));
        score +|= 2000 + (if (seconds < 900) (900 - seconds) * 10 else 0);
        hi_score = @max(hi_score, score);
        mode = .won;
    }
}

fn pulvinarCentre() [2]f32 {
    return chordPt((S_ARENA + S_POD) * 0.5, PULVINAR_BAY, 0.5);
}

fn inPulvinar(x: f32, y: f32, z: f32) bool {
    const c = pulvinarCentre();
    return (x - c[0]) * (x - c[0]) + (y - c[1]) * (y - c[1]) < 2.2 * 2.2 and @abs(z - POD_Z) < 0.3;
}

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
        var mx = f[0] * mf + f[1] * ms;
        var my = f[1] * mf - f[0] * ms;
        const len = @sqrt(mx * mx + my * my);
        mx = mx / len * MOVE_STEP;
        my = my / len * MOVE_STEP;
        _ = tryMove(mx, my);
    }
    fallPlayer();
}

// Step up at once; fall off ledges, come down from jumps, and stop at
// ceilings.
fn fallPlayer() void {
    const floor = floorAt(psec, px, py);
    if (pz > floor or fall_v < 0) {
        fall_v += GRAVITY;
        pz = @max(floor, pz - fall_v);
        if (pz == floor) fall_v = 0;
    } else {
        pz = floor;
        fall_v = 0;
    }
    const s = (&sectors)[psec];
    if (!s.sky) {
        const top = planeZ(s.ceil, px, py) - PLAYER_H;
        if (pz > top) {
            pz = @max(floor, top);
            fall_v = @max(fall_v, 0);
        }
    }
}

fn jump() bool {
    if (flying) return true;
    if (fall_v < 0 or pz - floorAt(psec, px, py) > JUMP_SLACK) return false;
    fall_v = -JUMP_V;
    return true;
}

// Flying

fn takeWing() void {
    flying = true;
    pz = minf(pz + 1.0, ceilZ(sectors[psec], px, py) - FLY_R);
    fly_speed = FLY_CLIMB_SPEED;
    fall_v = 0;
    showMessage("YOU ARE A GULL");
}

// Back on foot where the gull is, with the eye where the gull's was. A
// walker is wider than a gull, so it is pushed off any wall it overlaps,
// then falls to the floor.
fn land() void {
    flying = false;
    const floor = floorAt(psec, px, py);
    pz = maxf(floor, pz + FLY_EYE - EYE_Z);
    const n = gatherNear(psec, px, py, pz, PLAYER_R + 0.3, WALKER);
    var x = px;
    var y = py;
    pushOut(&x, &y, pz, PLAYER_R, n, WALKER);
    var s = psec;
    var hx = px;
    var hy = py;
    if (moveWalker(&s, &hx, &hy, pz, x, y, WALKER)) {
        px = hx;
        py = hy;
        psec = s;
    }
    fall_v = 0;
    showMessage("ON FOOT");
}

fn updateFlight() void {
    var turn: f32 = 0;
    if ((keys_down & (KEY_TURN_L | KEY_STRAFE_L)) != 0) turn += 1;
    if ((keys_down & (KEY_TURN_R | KEY_STRAFE_R)) != 0) turn -= 1;
    pangle = wrapAngle(pangle + turn * TURN_STEP);
    if ((keys_down & KEY_LOOK_UP) != 0) look = @min(LOOK_UP_MAX, look + LOOK_STEP);
    if ((keys_down & KEY_LOOK_DOWN) != 0) look = @max(-LOOK_DOWN_MAX, look - LOOK_STEP);

    const climb = (keys_down & KEY_FWD) != 0 or jump_held;
    const dive = (keys_down & KEY_BACK) != 0 and !climb;
    const target: f32 = if (climb) FLY_CLIMB_SPEED else if (dive) FLY_DIVE_SPEED else FLY_GLIDE;
    fly_speed += clampf(target - fly_speed, -FLY_ACCEL, FLY_ACCEL);
    const dz: f32 = if (climb) FLY_CLIMB else if (dive) -FLY_DIVE else -FLY_SINK;
    if (climb) fly_flap += 0.35;
    if (fly_flap > 2.0 * std.math.pi) fly_flap -= 2.0 * std.math.pi;

    // Up or down within the room first, then forward at the new height.
    const s = (&sectors)[psec];
    pz = clampf(pz + dz, planeZ(s.floor, px, py) + FLY_R, minf(ceilZ(s, px, py) - FLY_R, FLY_TOP));
    const f = forward();
    if (!tryMoveAs(f[0] * fly_speed, f[1] * fly_speed, pz - FLY_R, FLY_R, FLY_SKIM)) fly_speed *= 0.5;
    // Skimming up a slope or over a ledge lifts the gull clear of it.
    const t = (&sectors)[psec];
    pz = clampf(pz, planeZ(t.floor, px, py) + FLY_R, maxf(planeZ(t.floor, px, py) + FLY_R, ceilZ(t, px, py) - FLY_R));
}

fn collectPickups() void {
    for (&pickups, 0..) |*p, i| {
        if (!p.active) continue;
        const dx = p.x - px;
        const dy = p.y - py;
        if (dx * dx + dy * dy > 1.0 or @abs(p.z - pz) > 1.5) continue;
        p.active = false;
        tesserae |= @as(u8, 1) << @intCast(i);
        score +|= 500;
        showMessage(if (tesserae == ALL_TESSERAE) "TO THE EMPERORS BOX" else "A TESSERA");
    }
}

fn showMessage(text: []const u8) void {
    message = text;
    message_ms = MESSAGE_MS;
}

// Gulls

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

fn rngFloat(lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * @as(f32, @floatFromInt(rngNext() & 0xFFFF)) / 65535.0;
}

fn soarSpin() f32 {
    return if ((rngNext() & 1) == 0) GULL_SPEED * 0.9 else -GULL_SPEED * 0.9;
}

fn soarCentre() [2]f32 {
    const p = chordPt(rngFloat(0, 70), rngRange(0, NB - 1), rngFloat(0, 1));
    return p;
}

fn flyTo(b: *Bird, x: f32, y: f32, z: f32, speed: f32) void {
    b.mode = .fly;
    b.tx = x;
    b.ty = y;
    b.tz = z;
    b.speed = speed;
}

fn circleAround(b: *Bird, cx: f32, cy: f32, speed: f32, ms: i32) void {
    const dx = b.x - cx;
    const dy = b.y - cy;
    b.mode = .circle;
    b.route = .soar;
    b.leg = 0;
    b.cx = cx;
    b.cy = cy;
    b.r = @max(4.0, @sqrt(dx * dx + dy * dy));
    b.ang = std.math.atan2(dy, dx);
    b.spin = speed / b.r;
    b.timer_ms = ms;
}

fn settle(b: *Bird, spot: u8) void {
    const p = perches[spot];
    b.mode = .ground;
    b.spot = spot;
    b.x = p.x;
    b.y = p.y;
    b.z = p.z;
    b.hx = -p.ox;
    b.hy = -p.oy;
    b.timer_ms = rngRange(8000, 30000);
    b.glide = true;
    perch_used |= @as(u64, 1) << @intCast(spot);
    const si = sectorAt(p.x, p.y, p.z + 0.3);
    b.light = if (si == NO_SECTOR) 1 else lightAt(si, p.x, p.y, p.z + 0.3, 0, 0, 1);
}

fn freePerch() ?u8 {
    var tries: usize = 0;
    while (tries < 6) : (tries += 1) {
        const i: u8 = @intCast(rngNext() % @as(u32, @intCast(perch_count)));
        if ((perch_used >> @intCast(i)) & 1 != 0) continue;
        const p = perches[i];
        if ((p.x - px) * (p.x - px) + (p.y - py) * (p.y - py) < 100) continue;
        return i;
    }
    return null;
}

fn approach(p: Perch, out: f32, up: f32) [3]f32 {
    return .{ p.x + p.ox * out, p.y + p.oy * out, p.z + up };
}

// A leg has ended; start the next one.
fn nextLeg(b: *Bird) void {
    b.leg += 1;
    switch (b.route) {
        .soar => {
            if (b.leg == 1) {
                if (rngNext() % 3 == 0) {
                    if (freePerch()) |i| {
                        b.route = .land;
                        b.leg = 0;
                        b.spot = i;
                        perch_used |= @as(u64, 1) << @intCast(i);
                        const a = approach(perches[i], 6, 7);
                        flyTo(b, a[0], a[1], @max(CRUISE_Z, b.z), GULL_SPEED);
                        return;
                    }
                }
                const c = soarCentre();
                const r = rngFloat(12, 36);
                const a = rngFloat(0, 2.0 * std.math.pi);
                b.cx = c[0];
                b.cy = c[1];
                flyTo(b, c[0] + r * @cos(a), c[1] + r * @sin(a), rngFloat(CRUISE_Z, 44), GULL_SPEED);
            } else {
                circleAround(b, b.cx, b.cy, soarSpin(), rngRange(5000, 20000));
            }
        },
        .land => {
            const p = perches[b.spot];
            switch (b.leg) {
                1 => {
                    const a = approach(p, 6, 7);
                    flyTo(b, a[0], a[1], a[2], GULL_SPEED * 0.8);
                },
                2 => flyTo(b, p.x, p.y, p.z, GULL_SPEED * 0.6),
                else => settle(b, b.spot),
            }
        },
        .depart => {
            switch (b.leg) {
                1 => flyTo(b, b.x, b.y, CRUISE_Z + rngFloat(0, 10), GULL_SPEED),
                else => {
                    const c = soarCentre();
                    b.cx = c[0];
                    b.cy = c[1];
                    circleAround(b, c[0], c[1], soarSpin(), rngRange(5000, 20000));
                },
            }
        },
    }
}

fn takeOff(b: *Bird) void {
    perch_used &= ~(@as(u64, 1) << @intCast(b.spot));
    b.route = .depart;
    b.leg = 0;
    b.glide = false;
    const a = approach(perches[b.spot], 4, 6);
    flyTo(b, a[0], a[1], a[2], GULL_SPEED * 0.8);
}

fn updateBirds() void {
    for (&birds, 0..) |*b, i| {
        if (!b.active) continue;
        switch (b.mode) {
            .ground => {
                const dx = b.x - px;
                const dy = b.y - py;
                b.timer_ms -= STEP;
                // Gulls take no notice of another gull.
                const near = !flying and dx * dx + dy * dy < STARTLE_DIST * STARTLE_DIST and @abs(pz - b.z) < 2.5;
                if (near or b.timer_ms <= 0) {
                    takeOff(b);
                } else if (rngNext() % 160 == 0) {
                    // Look about.
                    const a = std.math.atan2(b.hy, b.hx) + rngFloat(-1.2, 1.2);
                    b.hx = @cos(a);
                    b.hy = @sin(a);
                }
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
                b.glide = dz < 0.1 * d;
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
                // Soaring gulls flap in short bursts between long glides.
                b.glide = @mod(@divTrunc(anim_ms + @as(i32, @intCast(i)) * 211, 900), 5) != 0;
                b.timer_ms -= STEP;
                if (b.timer_ms <= 0) nextLeg(b);
            },
        }
        if (!b.glide) b.flap += 0.32;
        if (b.flap > 2.0 * std.math.pi) b.flap -= 2.0 * std.math.pi;
    }
}

// Lighting

fn sunHour() f32 {
    const f = @as(f32, @floatFromInt(@mod(time_ms, SUN_DAY_MS))) / @as(f32, @floatFromInt(SUN_DAY_MS));
    return SUN_FIRST_HOUR + f * SUN_HOURS;
}

// The unit vector toward the sun, east, north, up, from its hour angle and
// declination at Rome's latitude.
fn sunDir() [3]f32 {
    const h = (sunHour() - 12.0) * (std.math.pi / 12.0);
    const sl = @sin(ROME_LATITUDE);
    const cl = @cos(ROME_LATITUDE);
    const sd = @sin(SUN_DECLINATION);
    const cd = @cos(SUN_DECLINATION);
    return .{ -cd * @sin(h), cl * sd - sl * cd * @cos(h), sl * sd + cl * cd * @cos(h) };
}

var sun: [3]f32 = .{ 0, -0.6, 0.8 };

inline fn splat(v: f32) Rgb {
    return @splat(v);
}

inline fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    return a + (b - a) * splat(t);
}

inline fn frac(v: f32) f32 {
    return v - @floor(v);
}

inline fn hash2(x: i32, y: i32) u32 {
    var h: u32 = @bitCast(x *% 374761393 +% y *% 668265263);
    h = (h ^ (h >> 13)) *% 1274126177;
    return h ^ (h >> 16);
}

inline fn hashf(x: i32, y: i32) f32 {
    return @as(f32, @floatFromInt(hash2(x, y) & 0xFFFF)) / 65535.0;
}

inline fn cell(v: f32) i32 {
    return @intFromFloat(clampf(@floor(v), -1.0e6, 1.0e6));
}

inline fn valueNoise(x: f32, y: f32) f32 {
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

// Light falling on a surface with normal n in sector si: sky and sun in the
// open, light from the arches in the ambulatories, and a dim glow in the
// passages under the seats and the deck.
fn lightAt(si: u16, x: f32, y: f32, z: f32, nx: f32, ny: f32, nz: f32) f32 {
    const s = (&sectors)[si];
    const sun_on = maxf(0.0, nx * sun[0] + ny * sun[1] + nz * sun[2]);
    return switch (s.kind) {
        .outside, .parapet, .terrace, .seats, .podium, .arena, .deck, .wall_top, .stair_t => 0.5 + 0.1 * nz + 0.62 * sun_on,
        .arch => 0.67 + 0.15 * clampf((ringPos(si, x, y).s - S_OUTER) / (S_FACE - S_OUTER), 0.0, 1.0),
        .pit => pitLight(si, x, y, z, nz, sun_on),
        .amb_g, .amb_u => blk: {
            const f = clampf((ringPos(si, x, y).s - S_INNER) / (S_OUTER - S_INNER), 0.0, 1.0);
            break :blk 0.17 + 0.5 * f * f;
        },
        // Daylight comes in under the deck's west edge, and a little falls
        // through the gap where its east end meets the arena floor.
        .covered => 0.07 + 0.3 * clampf(1.0 - (x - DECK_X) / 9.0, 0.0, 1.0) + 0.12 * clampf((x - (HY_X1 - CROSS_W - 2.0)) / 2.0, 0.0, 1.0),
        .doorway => 0.24,
        .tunnel => blk: {
            const p = ringPos(si, x, y).s;
            break :blk 0.16 + 0.5 * clampf(@max((S_POD - p) / 3.0, (p - (S_INNER - 4.0)) / 4.0), 0.0, 1.0);
        },
        .stair_a, .landing, .lane_b => 0.2 + 0.25 * clampf((ringPos(si, x, y).s - (S_INNER - 4.0)) / 4.0, 0.0, 1.0),
    };
}

// The hypogeum gets less sky the deeper it goes, and the sun reaches a point
// only if its line to the sun leaves through the corridor's open top.
fn pitLight(si: u16, x: f32, y: f32, z: f32, nz: f32, sun_on: f32) f32 {
    const s = (&sectors)[si];
    var light = 0.2 + 0.32 * clampf((z - PIT_Z) / -PIT_Z, 0.0, 1.0) + 0.08 * nz;
    if (sun_on > 0) {
        var lit = z >= -0.01;
        if (!lit) {
            const k = -z / sun[2];
            const tx = x + sun[0] * k;
            const ty = y + sun[1] * k;
            lit = ty >= s.min_y - 0.01 and ty <= s.max_y + 0.01 and tx > HY_XS[0] and tx < DECK_X;
            if (lit and @abs(s.min_y - HY_YS[HY_CENTRE_BAND]) > 0.01) {
                var i: usize = 1;
                while (i + 1 < HY_XS.len) : (i += 2) lit = lit and (tx < HY_XS[i] or tx > HY_XS[i + 1]);
            }
        }
        if (lit) light += 0.62 * sun_on;
    }
    return light;
}

const HAZE: Rgb = .{ 0.8, 0.8, 0.8 };

inline fn haze(c: Rgb, t: f32, open: bool) Rgb {
    if (open) return mix(c, HAZE, clampf(t / 700.0, 0.0, 0.45));
    return c * splat(clampf(1.0 - t * 0.012, 0.35, 1.0));
}

// Materials

const TRAV: Rgb = .{ 0.82, 0.76, 0.64 };
const TRAV_DARK: Rgb = .{ 0.6, 0.55, 0.46 };
const BRICK: Rgb = .{ 0.64, 0.37, 0.27 };
const BRICK_AVG: Rgb = .{ 0.63, 0.42, 0.32 };
const MORTAR: Rgb = .{ 0.72, 0.68, 0.6 };
const TUFA: Rgb = .{ 0.62, 0.58, 0.47 };
const SAND: Rgb = .{ 0.86, 0.74, 0.54 };
const WOOD: Rgb = .{ 0.56, 0.41, 0.27 };
const MARBLE: Rgb = .{ 0.9, 0.88, 0.84 };
const EARTH: Rgb = .{ 0.5, 0.42, 0.32 };
const GRASS: Rgb = .{ 0.4, 0.48, 0.27 };

const FACADE_COLORS = [_]Rgb{
    .{ 0.86, 0.6, 0.3 },
    .{ 0.76, 0.4, 0.27 },
    .{ 0.93, 0.8, 0.52 },
    .{ 0.86, 0.58, 0.5 },
    .{ 0.9, 0.84, 0.7 },
};

fn speckle(c: Rgb, u: f32, v: f32, amount: f32) Rgb {
    const n = hashf(cell(u), cell(v));
    return c * splat(1.0 - amount + n * amount * 2.0);
}

// Courses of travertine blocks, with the pits left where the iron clamps
// were robbed from the joints in the Middle Ages.
fn travertine(u: f32, z: f32, t: f32) Rgb {
    const row = cell(z / 0.62);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 0.75;
    const bu = (u + off) / 1.5;
    const weather = 0.82 + 0.26 * valueNoise(u * 1.3, z * 0.25);
    if (t > 45) return TRAV * splat(0.92 * weather);
    if (frac(z / 0.62) < 0.05 or frac(bu) < 0.03) return TRAV_DARK * splat(weather);
    const h = hash2(cell(bu), row);
    if ((h & 7) == 0) {
        const hx = frac(bu) * 1.5 - 0.1;
        const hz = frac(z / 0.62) * 0.62 - 0.31;
        if (hx * hx + hz * hz < 0.012) return .{ 0.24, 0.21, 0.17 };
    }
    return TRAV * splat((0.88 + 0.16 * hashf(cell(bu), row)) * weather);
}

// Roman brick facing, with bands of tufa blocks; it blurs to its average
// colour in the distance rather than shimmering.
fn brick(u: f32, z: f32, t: f32) Rgb {
    const tone = 0.88 + 0.22 * valueNoise(u * 0.4, z * 0.6);
    if (t > 24) return BRICK_AVG * splat(tone);
    var c: Rgb = undefined;
    if (frac(z / 1.6) < 0.22) {
        const row = cell(z / 0.18);
        const off: f32 = if (@mod(row, 2) == 0) 0 else 0.15;
        c = if (frac(z / 0.18) < 0.15 or frac((u + off) / 0.3) < 0.1) MORTAR else speckle(TUFA, (u + off) / 0.3, @floatFromInt(row), 0.08);
    } else {
        const row = cell(z / 0.075);
        const off: f32 = if (@mod(row, 2) == 0) 0 else 0.2;
        c = if (frac(z / 0.075) < 0.3 or frac((u + off) / 0.4) < 0.05) MORTAR else BRICK * splat(0.85 + 0.3 * hashf(cell((u + off) / 0.4), row));
    }
    return mix(c * splat(tone), BRICK_AVG * splat(tone), clampf((t - 10.0) / 14.0, 0.0, 1.0));
}

fn tufa(u: f32, z: f32) Rgb {
    const row = cell(z / 0.6);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 0.6;
    if (frac(z / 0.6) < 0.05 or frac((u + off) / 1.2) < 0.03) return TUFA * splat(0.7);
    return speckle(TUFA, (u + off) / 1.2, @floatFromInt(row), 0.08);
}

// The outer face: arches between engaged half-columns, Tuscan below and
// Ionic above, with entablatures and the parapet of the top terrace. The
// lower arches are numbered, as the real ones are.
fn colosseumFacade(p: ChordPos, z: f32, u: f32, t: f32) Rgb {
    const g = p.g;
    var c = travertine(u, z, t);
    if (z < 0.4) return TRAV_DARK;
    for ([_]f32{ 8.6, 18.0 }) |base| {
        const dz = z - base;
        if (dz >= 0 and dz < 1.6) {
            if (dz < 0.35) return TRAV * splat(0.95);
            if (dz < 0.95) return TRAV * splat(0.82 + 0.06 * valueNoise(u * 2.0, 0));
            if (frac(u / 0.25) < 0.5 and dz > 1.3) return TRAV * splat(0.7);
            return TRAV * splat(1.02);
        }
    }
    if (z > 22.9) return TRAV * splat(0.98);
    // Engaged half-columns, shaded as cylinders.
    const dg = minf(@abs(g), @abs(1.0 - g)) * p.chord;
    if (dg < 0.6 and z < 22.0 and !(z > 19.6 and z < 20.0)) {
        const k = clampf(dg / 0.6, 0.0, 1.0);
        const cap = (z > 8.0 and z < 8.6) or (z > 17.4 and z < 18.0);
        return TRAV * splat(@as(f32, if (cap) 1.05 else 0.8) + 0.3 * @sqrt(1.0 - k * k));
    }
    // Voussoirs and imposts around each arch.
    if (g > ARCH_FS[0] and g < ARCH_FS[ARCH_FS.len - 1]) {
        for ([_]f32{ ARCH_G, ARCH_U }) |spring| {
            const top = archTop(spring, g);
            if (z > top and z < top + 0.6) {
                const ang = std.math.atan2(z - spring, (g - 0.5) * p.chord);
                return if (frac(ang * 11.0 / std.math.pi) < 0.08) TRAV_DARK else TRAV * splat(0.97);
            }
            if (@abs(z - spring) < 0.15) return TRAV * splat(1.02);
        }
        // The arch number over each ground-floor arch.
        if (z > 7.3 and z < 7.9 and @abs(g - 0.5) < 0.07) {
            const bit: u5 = @intCast(std.math.clamp(@as(i32, @intFromFloat((g - 0.43) / 0.14 * 7.0)), 0, 6));
            if ((hash2(p.k, 11) >> bit) & 1 != 0 and frac((g - 0.43) / 0.02) < 0.5) return .{ 0.3, 0.26, 0.22 };
        }
    }
    if (z > 20.0) {
        // Pilasters and small windows in the attic band.
        if (dg < 0.4) return TRAV * splat(1.0);
        if (@abs(g - 0.5) < 0.08 and z > 20.6 and z < 21.6) return .{ 0.16, 0.14, 0.13 };
    }
    c = c * splat(0.94);
    return c;
}

fn cityFacade(u: f32, z: f32) Rgb {
    const variant = hash2(cell(u / 11.0), 3) % FACADE_COLORS.len;
    const wall = FACADE_COLORS[variant] * splat(0.9 + 0.1 * valueNoise(u * 0.6, z * 0.5));
    if (z < 0.4) return TRAV * splat(0.8);
    if (z > CITY_H - 0.6) return if (z < CITY_H - 0.45) Rgb{ 0.3, 0.2, 0.15 } else Rgb{ 0.45, 0.3, 0.2 };
    if (z < 3.6) {
        const bay = frac(u / 3.6) * 3.6;
        const dx = bay - 1.8;
        const top = 2.4 + @sqrt(maxf(0.0, 1.0 - dx * dx)) * 0.6;
        if (@abs(dx) < 1.0 and z < top) return if ((hash2(cell(u / 3.6), 5) & 3) == 0) Rgb{ 0.55, 0.38, 0.18 } else Rgb{ 0.1, 0.09, 0.09 };
        if (@abs(dx) < 1.15 and z < top + 0.15) return TRAV;
        return wall * splat(0.94);
    }
    const zf = @mod(z - 3.85, 3.1);
    const bay = frac(u / 3.0) * 3.0;
    if (zf > 0.7 and zf < 2.5 and bay > 1.0 and bay < 2.0) {
        if (bay < 1.06 or bay > 1.94 or zf > 2.44) return .{ 0.92, 0.9, 0.84 };
        return .{ 0.13, 0.15, 0.19 };
    }
    if (zf > 0.7 and zf < 2.5 and ((bay > 0.62 and bay < 1.0) or (bay > 2.0 and bay < 2.38))) {
        return if (frac(zf / 0.12) < 0.3) Rgb{ 0.17, 0.3, 0.21 } else Rgb{ 0.24, 0.42, 0.3 };
    }
    return wall;
}

// The marble-faced wall round the arena, with an inscription on the
// parapet above it.
fn podiumWall(u: f32, z: f32) Rgb {
    if (z < 0.3) return MARBLE * splat(0.62);
    if (z < 4.2) {
        if (frac(u / 2.4) < 0.02 or frac(z / 1.4) < 0.02) return MARBLE * splat(0.7);
        return MARBLE * splat(0.84 + 0.12 * valueNoise(u * 0.9, z * 0.7));
    }
    if (z < 5.0) return MARBLE * splat(if (frac(z / 0.2) < 0.5) 0.95 else 0.78);
    if (z > 5.45 and z < 5.85) {
        const gx = cell(u / 0.09);
        const gz = cell((z - 5.45) / 0.08);
        if (@mod(cell(u / 0.36), 5) != 4 and (hash2(gx, gz) & 3) != 0 and @mod(gx, 4) != 3) return .{ 0.46, 0.14, 0.12 };
    }
    return MARBLE * splat(0.9);
}

fn wallAlbedo(sp: Span, x: f32, y: f32, z: f32, t: f32) Rgb {
    const e = (&edges)[sp.edge];
    const u = e.u0 + @sqrt((x - e.x1) * (x - e.x1) + (y - e.y1) * (y - e.y1));
    return switch (sp.mat) {
        .travertine => travertine(u, z, t),
        .facade => colosseumFacade(ringPos(e.sector, x, y), z, u, t),
        .city => cityFacade(u + e.x1 * 0.37, z),
        .brick => brick(u + e.x1 + e.y1, z, t),
        .tufa => tufa(u, z),
        .podium => podiumWall(u + e.x1, z),
        .riser => travertine(u * 2.0, z * 3.0, t) * splat(0.82),
    };
}

fn floorAlbedo(si: u16, x: f32, y: f32, t: f32) Rgb {
    const kind = (&sectors)[si].kind;
    const c = switch (kind) {
        .outside => streetFloor(ringPos(si, x, y), x, y),
        .arch, .amb_g, .amb_u, .tunnel, .landing, .lane_b, .stair_a, .stair_t, .doorway => slabs(x, y),
        .terrace, .parapet => terraceFloor(x, y),
        .seats => seatFloor(ringPos(si, x, y), x, y),
        .podium => podiumFloor(x, y),
        .arena => sandFloor(x, y),
        .deck => deckFloor(x, y),
        .wall_top => wallTopFloor(x, y),
        .pit, .covered => earthFloor(x, y),
    };
    const far = clampf((t - 22.0) / 50.0, 0.0, 0.7);
    if (far <= 0) return c;
    return mix(c, floorAverage(kind), far);
}

fn floorAverage(kind: Kind) Rgb {
    return switch (kind) {
        .outside => .{ 0.42, 0.4, 0.37 },
        .arch, .amb_g, .amb_u, .tunnel, .landing, .lane_b, .stair_a, .stair_t, .doorway => TRAV * splat(0.82),
        .terrace, .parapet => .{ 0.66, 0.5, 0.4 },
        .seats => .{ 0.68, 0.56, 0.44 },
        .podium => MARBLE * splat(0.85),
        .arena => SAND * splat(0.95),
        .deck => WOOD,
        .wall_top => .{ 0.56, 0.44, 0.32 },
        .pit, .covered => EARTH,
    };
}

fn streetFloor(p: ChordPos, x: f32, y: f32) Rgb {
    if (p.s < 70.0) {
        // Ancient travertine paving round the building.
        const sx = x / 2.2;
        const sy = y / 1.4;
        if (frac(sx) < 0.03 or frac(sy) < 0.04) return TRAV * splat(0.6);
        return TRAV * splat(0.78 + 0.14 * hashf(cell(sx), cell(sy)));
    }
    const u = (x + y) * 0.7071 / 0.42;
    const v = (x - y) * 0.7071 / 0.42;
    if (frac(u) < 0.1 or frac(v) < 0.1) return .{ 0.22, 0.21, 0.2 };
    return Rgb{ 0.42, 0.4, 0.37 } * splat(0.85 + 0.3 * hashf(cell(u), cell(v)));
}

fn slabs(x: f32, y: f32) Rgb {
    const row = cell(y / 1.2);
    const off: f32 = if (@mod(row, 2) == 0) 0 else 0.9;
    const sx = (x + off) / 1.8;
    if (frac(y / 1.2) < 0.03 or frac(sx) < 0.02) return TRAV * splat(0.58);
    return TRAV * splat(0.7 + 0.16 * hashf(cell(sx), row));
}

// Worn travertine on the walkway round the top, patched with brick and
// grown with grass where the slabs are lost.
fn terraceFloor(x: f32, y: f32) Rgb {
    const n = valueNoise(x * 0.25, y * 0.25) * 0.7 + valueNoise(x * 1.5, y * 1.5) * 0.3;
    if (n > 0.66) return GRASS * splat(0.75 + 0.35 * hashf(cell(x * 9.0), cell(y * 9.0)));
    if (n > 0.56) {
        const row = cell(y / 0.075);
        if (frac(y / 0.075) < 0.3 or frac((x + @as(f32, @floatFromInt(@mod(row, 2))) * 0.15) / 0.3) < 0.06) return MORTAR * splat(0.8);
        return BRICK * splat(0.82 + 0.25 * hashf(cell(x / 0.3), row));
    }
    return slabs(x, y) * splat(1.08);
}

// Rows of seats run along the ring, with stairs down the cavea in every
// other bay. Much of the marble is gone, leaving the brick vaults beneath,
// with grass along the edges of the gaps.
fn seatFloor(p: ChordPos, x: f32, y: f32) Rgb {
    const row = cell(p.s / 0.8);
    const f = frac(p.s / 0.8);
    if (@abs(p.g - 0.5) < 0.05 and @mod(p.k, 2) == 0) {
        return if (frac(p.s / 0.4) < 0.3) TRAV_DARK else TRAV * splat(0.88);
    }
    const ruin = valueNoise(x * 0.07, y * 0.07) * 0.65 + valueNoise(x * 0.35, y * 0.35) * 0.35;
    if (ruin > 0.58) {
        if (ruin < 0.61) return GRASS * splat(0.8 + 0.3 * hashf(cell(x * 5.0), cell(y * 5.0)));
        return brick(p.g * p.chord, p.s * 0.6, 0) * splat(if (f < 0.35) 0.7 else 0.92);
    }
    const along = p.g * p.chord;
    const block = cell(along / 1.3 + @as(f32, @floatFromInt(@mod(row, 2))) * 0.5);
    if (frac(along / 1.3 + @as(f32, @floatFromInt(@mod(row, 2))) * 0.5) < 0.02) return MARBLE * splat(0.55);
    const tone = 0.86 + 0.14 * hashf(row, block);
    // The riser at the back of each seat reads as a darker band.
    return MARBLE * splat(@as(f32, if (f < 0.3) 0.62 else if (f < 0.36) 1.0 else 0.9) * tone);
}

fn podiumFloor(x: f32, y: f32) Rgb {
    var c = slabs(x, y) * splat(1.12);
    const pc = pulvinarCentre();
    const dx = x - pc[0];
    const dy = y - pc[1];
    if (dx * dx + dy * dy < 2.2 * 2.2) {
        // The emperor's box, in purple, glowing once every tessera is found.
        c = if (frac((dx + dy) / 0.6) < 0.5) Rgb{ 0.42, 0.14, 0.36 } else Rgb{ 0.5, 0.2, 0.44 };
        if (tesserae == ALL_TESSERAE) c = c + splat(0.25 + 0.15 * @sin(@as(f32, @floatFromInt(anim_ms)) * 0.006));
    }
    return c;
}

fn sandFloor(x: f32, y: f32) Rgb {
    const n = valueNoise(x * 0.7, y * 0.7) * 0.6 + valueNoise(x * 4.0, y * 4.0) * 0.4;
    const rake = 0.96 + 0.04 * @sin(y * 9.0 + n * 3.0);
    return SAND * splat((0.84 + 0.22 * n) * rake);
}

fn deckFloor(x: f32, y: f32) Rgb {
    const plank = cell(y / 0.3);
    const off = hashf(plank, 9) * 4.0;
    if (frac(y / 0.3) < 0.08 or frac((x + off) / 4.0) < 0.006) return WOOD * splat(0.45);
    return WOOD * splat(0.82 + 0.3 * hashf(plank, cell((x + off) / 4.0)) + 0.06 * @sin(x * 7.0 + off));
}

fn wallTopFloor(x: f32, y: f32) Rgb {
    if (valueNoise(x * 1.2, y * 1.2) > 0.68) return GRASS * splat(0.9);
    const row = cell(x / 0.3);
    if (frac(x / 0.3) < 0.1 or frac((y + @as(f32, @floatFromInt(@mod(row, 2))) * 0.1) / 0.2) < 0.15) return MORTAR * splat(0.8);
    return BRICK * splat(0.82 + 0.25 * hashf(row, cell(y / 0.2)));
}

fn earthFloor(x: f32, y: f32) Rgb {
    const n = valueNoise(x * 0.9, y * 0.9);
    if (n > 0.72) return GRASS * splat(0.75 + 0.3 * hashf(cell(x * 8), cell(y * 8)));
    const st = hashf(cell(x * 3.0), cell(y * 3.0));
    if (st > 0.86) return TUFA * splat(0.75);
    return EARTH * splat(0.82 + 0.3 * n);
}

fn ceilAlbedo(si: u16, x: f32, y: f32, t: f32) Rgb {
    return switch ((&sectors)[si].kind) {
        .amb_g, .amb_u => blk: {
            // Transverse arches between the bays of the vault.
            const p = ringPos(si, x, y);
            const d = minf(@abs(p.g), @abs(1.0 - p.g)) * p.chord;
            if (d < 0.5) break :blk TRAV * splat(0.8);
            const across = clampf((p.s - S_INNER) / (S_OUTER - S_INNER), 0.0, 1.0) - 0.5;
            break :blk brick(p.g * p.chord, p.s, t) * splat(0.8 + 0.3 * (0.25 - across * across) * 4.0);
        },
        // Voussoirs run through the wall over each arch.
        .arch => blk: {
            const p = ringPos(si, x, y);
            break :blk travertine(p.s * 1.6, p.g * p.chord, t) * splat(0.9);
        },
        .covered => blk: {
            if (frac(x / 2.0) < 0.1) break :blk WOOD * splat(0.35);
            break :blk deckFloor(x, y) * splat(0.55);
        },
        else => brick(x + y, x - y, t) * splat(0.85),
    };
}

fn skyColor(rx: f32, ry: f32, vz: f32) Rgb {
    if (flat_shading) return .{ 0.5, 0.7, 0.9 };
    const len = @sqrt(rx * rx + ry * ry + vz * vz);
    const el = clampf(vz / len, 0.0, 1.0);
    var c = mix(.{ 0.92, 0.86, 0.74 }, .{ 0.32, 0.54, 0.86 }, @sqrt(el));
    const sd = (rx * sun[0] + ry * sun[1] + vz * sun[2]) / len;
    if (sd > @cos(SUN_HALO)) {
        const ang = @sqrt(maxf(0.0, 2.0 * (1.0 - sd)));
        const g = 1.0 - ang / SUN_HALO;
        c = mix(c, .{ 1.0, 0.96, 0.84 }, g * g * 0.3);
        c = mix(c, .{ 1.0, 0.99, 0.94 }, clampf((SUN_DISC - ang) / 0.004 + 0.5, 0.0, 1.0));
    }
    if (vz > 0.02) {
        const k = 1.0 / vz;
        const drift = @as(f32, @floatFromInt(anim_ms)) * 0.00005;
        const n = valueNoise(rx * k * 1.4 + drift, ry * k * 2.8) * 0.65 + valueNoise(rx * k * 4.0, ry * k * 6.0) * 0.35;
        const cloud = clampf((n - 0.55) * 3.0, 0.0, 1.0) * clampf(el * 4.0, 0.0, 1.0);
        c = mix(c, .{ 0.98, 0.95, 0.9 }, cloud * 0.8);
    }
    return c;
}

// Shading shared by both renderers. Each takes the pixel's view ray, with
// a forward component of one, and its depth along that ray.

inline fn planeNormal(p: Plane) [3]f32 {
    const l = @sqrt(p.gx * p.gx + p.gy * p.gy + 1.0);
    return .{ -p.gx / l, -p.gy / l, 1.0 / l };
}

fn flatColor(seed: u32) Rgb {
    const h = hash2(@bitCast(seed), 77);
    return .{ @as(f32, @floatFromInt(h & 0xFF)) / 255.0, @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0, @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0 };
}

fn shadeFloor(si: u16, rx: f32, ry: f32, vz: f32, t: f32) Rgb {
    if (flat_shading) return flatColor(si);
    const s = (&sectors)[si];
    const x = cam_x + rx * t;
    const y = cam_y + ry * t;
    const n = planeNormal(s.floor);
    const albedo = floorAlbedo(si, x, y, t);
    return haze(albedo * splat(lightAt(si, x, y, cam_z + vz * t, n[0], n[1], n[2])), t, s.sky);
}

fn shadeCeil(si: u16, rx: f32, ry: f32, vz: f32, t: f32) Rgb {
    if (flat_shading) return flatColor(@as(u32, si) + 0x10000);
    const x = cam_x + rx * t;
    const y = cam_y + ry * t;
    return haze(ceilAlbedo(si, x, y, t) * splat(lightAt(si, x, y, cam_z + vz * t, 0, 0, -1) * 0.9), t, false);
}

fn shadeWall(span_i: u32, rx: f32, ry: f32, vz: f32, t: f32) Rgb {
    if (flat_shading) return flatColor(span_i + 0x20000);
    const sp = (&spans)[span_i];
    const e = (&edges)[sp.edge];
    const s = (&sectors)[e.sector];
    const x = cam_x + rx * t;
    const y = cam_y + ry * t;
    const z = cam_z + vz * t;
    const albedo = wallAlbedo(sp, x, y, z, t);
    return haze(albedo * splat(lightAt(e.sector, x, y, z, -e.nx, -e.ny, 0)), t, s.sky);
}

// Rendering

var cam_x: f32 = 0;
var cam_y: f32 = 0;
var cam_z: f32 = EYE_Z;
var cam_fx: f32 = 1;
var cam_fy: f32 = 0;
var cam_rx: f32 = 0;
var cam_ry: f32 = -1;
var cam_sec: u16 = 0;
var horizon: f32 = BASE_HORIZON;

fn setCamera(x: f32, y: f32, z: f32, angle: f32, look_px: f32, sec: u16) void {
    horizon = BASE_HORIZON + look_px;
    cam_x = x;
    cam_y = y;
    cam_sec = sec;
    cam_z = z;
    if (sec != NO_SECTOR) {
        const s = (&sectors)[sec];
        cam_z = clampf(z, planeZ(s.floor, x, y) + 0.05, ceilZ(s, x, y) - 0.05);
    }
    cam_fx = @cos(angle);
    cam_fy = @sin(angle);
    cam_rx = cam_fy;
    cam_ry = -cam_fx;
}

inline fn putPixel(x: usize, y: usize, c: Rgb) void {
    const idx = ktx.HEADER_SIZE + (y * SCREEN_W + x) * 4;
    const v = @as(u32, toByte(c[0])) | @as(u32, toByte(c[1])) << 8 | @as(u32, toByte(c[2])) << 16 | 0xFF00_0000;
    std.mem.writeInt(u32, output_buf[idx..][0..4], v, .little);
}

fn readPixel(x: usize, y: usize) Rgb {
    const idx = ktx.HEADER_SIZE + (y * SCREEN_W + x) * 4;
    return .{
        @as(f32, @floatFromInt(output_buf[idx])) / 255.0,
        @as(f32, @floatFromInt(output_buf[idx + 1])) / 255.0,
        @as(f32, @floatFromInt(output_buf[idx + 2])) / 255.0,
    };
}

inline fn toByte(v: f32) u8 {
    return @intFromFloat(clampf(v, 0.0, 1.0) * 255.0 + 0.5);
}

inline fn depthCode(t: f32) u16 {
    if (!(t < 2000.0)) return DEPTH_SKY;
    return @intFromFloat(@max(t, 0.0) * DEPTH_SCALE);
}

inline fn project(z: f32, t: f32) f32 {
    return horizon - (z - cam_z) * FOCAL / maxf(t, 1e-4);
}

// The first row whose centre lies below screen height b, within [lo, hi].
fn rowSplit(b: f32, lo: u16, hi: u16) u16 {
    const r = @ceil(clampf(b, -2.0, @as(f32, SCREEN_H) + 2.0) - 0.5);
    const ri: i32 = @intFromFloat(r);
    return @intCast(std.math.clamp(ri, @as(i32, lo), @as(i32, hi)));
}

inline fn rowVz(y: usize) f32 {
    return (horizon - (@as(f32, @floatFromInt(y)) + 0.5)) / FOCAL;
}

fn drawSky(c: usize, rx: f32, ry: f32, y0: usize, y1: usize) void {
    var y = y0;
    while (y < y1) : (y += 1) {
        putPixel(c, y, skyColor(rx, ry, rowVz(y)));
        depth_buf[y * SCREEN_W + c] = DEPTH_SKY;
    }
}

// The sector renderer

// A window of rows [y0, y1) in one column that sees into a sector, which the
// column's ray enters at depth t_in.
const Visit = struct { sec: u16, t_in: f32, y0: u16, y1: u16 };
const MAX_VISITS: usize = 96;
const MAX_COLUMN_VISITS: usize = 400;

var stat_visits: u32 = 0;

fn drawBuild() void {
    stat_visits = 0;
    var stack: [MAX_VISITS]Visit = undefined;
    var c: usize = 0;
    while (c < SCREEN_W) : (c += 1) {
        const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
        const rx = cam_fx + sl * cam_rx;
        const ry = cam_fy + sl * cam_ry;
        stack[0] = .{ .sec = cam_sec, .t_in = 0, .y0 = 0, .y1 = SCREEN_H };
        var sp: usize = if (cam_sec == NO_SECTOR) 0 else 1;
        if (sp == 0) drawSky(c, rx, ry, 0, SCREEN_H);
        var guard: usize = 0;
        while (sp > 0) {
            sp -= 1;
            const v = stack[sp];
            guard += 1;
            if (guard > MAX_COLUMN_VISITS) {
                drawSky(c, rx, ry, v.y0, v.y1);
                continue;
            }
            stat_visits += 1;
            sp = visitSector(c, rx, ry, v, &stack, sp);
        }
    }
}

// Draws what a window sees of one sector: floor rows below the far side's
// foot, ceiling rows above its head, and between them the spans of the side
// the ray leaves through. Each opening becomes a narrower window into the
// sector behind it.
fn visitSector(c: usize, rx: f32, ry: f32, v: Visit, stack: *[MAX_VISITS]Visit, sp_in: usize) usize {
    var sp = sp_in;
    const s = (&sectors)[v.sec];
    var t_out: f32 = 0;
    const ei = exitEdge(v.sec, cam_x, cam_y, rx, ry, &t_out);
    if (ei == NO_EDGE) {
        drawSky(c, rx, ry, v.y0, v.y1);
        return sp;
    }
    t_out = maxf(t_out, v.t_in);
    const hx = cam_x + rx * t_out;
    const hy = cam_y + ry * t_out;
    const split_f = rowSplit(project(planeZ(s.floor, hx, hy), t_out), v.y0, v.y1);
    drawFlats(c, rx, ry, v.sec, false, v.t_in, t_out, split_f, v.y1);
    var split_c = v.y0;
    if (!s.sky) {
        split_c = rowSplit(project(planeZ(s.ceil, hx, hy), t_out), v.y0, split_f);
        drawFlats(c, rx, ry, v.sec, true, v.t_in, t_out, v.y0, split_c);
    }
    if (split_c >= split_f) return sp;
    const e = (&edges)[ei];
    const u = edgeParam(e, hx, hy);
    var bot = split_f;
    var k = e.first_span;
    const last = e.first_span + e.span_count;
    while (k < last and bot > split_c) : (k += 1) {
        const span = (&spans)[k];
        const top = if (k + 1 == last) split_c else rowSplit(project(lerp(span.hi1, span.hi2, u), t_out), split_c, bot);
        if (top < bot) {
            switch (span.kind) {
                .solid => {
                    var y: usize = top;
                    while (y < bot) : (y += 1) {
                        putPixel(c, y, shadeWall(k, rx, ry, rowVz(y), t_out));
                        depth_buf[y * SCREEN_W + c] = depthCode(t_out);
                    }
                },
                .sky => drawSky(c, rx, ry, top, bot),
                .open => {
                    if (sp >= MAX_VISITS) {
                        drawSky(c, rx, ry, top, bot);
                    } else {
                        stack[sp] = .{ .sec = span.next, .t_in = t_out, .y0 = top, .y1 = bot };
                        sp += 1;
                    }
                },
            }
        }
        bot = top;
    }
    return sp;
}

// Floor or ceiling rows of a sector, cast per pixel onto its plane and kept
// between where the ray enters and leaves the sector.
fn drawFlats(c: usize, rx: f32, ry: f32, si: u16, is_ceil: bool, t_in: f32, t_out: f32, y0: usize, y1: usize) void {
    if (y0 >= y1) return;
    const s = (&sectors)[si];
    const p = if (is_ceil) s.ceil else s.floor;
    const slope = p.gx * rx + p.gy * ry;
    const rise = planeZ(p, cam_x, cam_y) - cam_z;
    var y = y0;
    while (y < y1) : (y += 1) {
        const vz = rowVz(y);
        const den = vz - slope;
        var t = t_out;
        if ((!is_ceil and den < -1e-6) or (is_ceil and den > 1e-6)) t = rise / den;
        t = clampf(t, maxf(t_in, NEAR), maxf(t_out, NEAR));
        putPixel(c, y, if (is_ceil) shadeCeil(si, rx, ry, vz, t) else shadeFloor(si, rx, ry, vz, t));
        depth_buf[y * SCREEN_W + c] = depthCode(t);
    }
}

// The polygon BSP renderer
//
// The same sectors become convex polygons in 3D: every floor, ceiling, and
// solid span. A BSP built from the polygons' own planes orders them front to
// back from any eye. The walk culls subtrees whose bounding boxes are off
// screen or fall only on pixels already drawn, rasterizes each polygon that
// faces the eye, and shades only pixels nothing nearer has covered. It has
// no precomputed visibility set, as Quake had.

const MAX_POLYS: usize = 49152;
const MAX_PVERTS: usize = 262144;
const MAX_BNODES: usize = 40960;
const MAX_POLY_N: usize = 32;
const BSP_STACK: usize = 512;
const SURF_FLOOR: u32 = 0;
const SURF_CEIL: u32 = 1 << 30;
const SURF_WALL: u32 = 2 << 30;
const SURF_INDEX: u32 = (1 << 30) - 1;

const Poly = struct { first: u32, n: u32, surf: u32, nx: f32, ny: f32, nz: f32, d: f32 };
const BNode = struct {
    nx: f32,
    ny: f32,
    nz: f32,
    d: f32,
    front: i32 = -1,
    back: i32 = -1,
    first: u32 = 0,
    count: u32 = 0,
    lo: [3]f32 = .{ 0, 0, 0 },
    hi: [3]f32 = .{ 0, 0, 0 },
};

var polys: [MAX_POLYS]Poly = undefined;
var poly_count: usize = 0;
var pverts: [MAX_PVERTS][3]f32 = undefined;
var pvert_count: usize = 0;
var bnodes: [MAX_BNODES]BNode = undefined;
var bnode_count: usize = 0;
var bsp_polys: [MAX_POLYS]u32 = undefined;
var bsp_poly_count: usize = 0;
var bsp_depth: usize = 0;
var bsp_ready = false;
var bsp_scratch: [MAX_POLYS]u32 = undefined;
var bsp_front: [MAX_POLYS]u32 = undefined;
var bsp_back: [MAX_POLYS]u32 = undefined;

fn addPoly(pts: []const [3]f32, surf: u32, n: [3]f32) void {
    if (pts.len < 3) return;
    if (poly_count >= MAX_POLYS or pvert_count + pts.len > MAX_PVERTS) @trap();
    (&polys)[poly_count] = .{ .first = @intCast(pvert_count), .n = @intCast(pts.len), .surf = surf, .nx = n[0], .ny = n[1], .nz = n[2], .d = n[0] * pts[0][0] + n[1] * pts[0][1] + n[2] * pts[0][2] };
    @memcpy(pverts[pvert_count .. pvert_count + pts.len], pts);
    pvert_count += pts.len;
    poly_count += 1;
}

fn genPolys() void {
    poly_count = 0;
    pvert_count = 0;
    var pts: [MAX_POLY_N][3]f32 = undefined;
    for (0..sector_count) |si| {
        const s = (&sectors)[si];
        const n = @min(s.vert_count, MAX_POLY_N);
        const fn_ = planeNormal(s.floor);
        for (0..n) |i| {
            const p = (&verts)[s.first_vert + i];
            pts[i] = .{ p[0], p[1], planeZ(s.floor, p[0], p[1]) };
        }
        addPoly(pts[0..n], SURF_FLOOR | @as(u32, @intCast(si)), fn_);
        if (!s.sky) {
            for (0..n) |i| {
                const p = (&verts)[s.first_vert + n - 1 - i];
                pts[i] = .{ p[0], p[1], planeZ(s.ceil, p[0], p[1]) };
            }
            const cn = planeNormal(s.ceil);
            addPoly(pts[0..n], SURF_CEIL | @as(u32, @intCast(si)), .{ -cn[0], -cn[1], -cn[2] });
        }
        var ei = s.first_edge;
        while (ei < s.first_edge + s.edge_count) : (ei += 1) {
            const e = (&edges)[ei];
            var k = e.first_span;
            while (k < e.first_span + e.span_count) : (k += 1) {
                const sp = (&spans)[k];
                if (sp.kind != .solid) continue;
                const hi1 = @min(sp.hi1, WALL_CAP);
                const hi2 = @min(sp.hi2, WALL_CAP);
                var m: usize = 0;
                pts[m] = .{ e.x1, e.y1, sp.lo1 };
                m += 1;
                pts[m] = .{ e.x2, e.y2, sp.lo2 };
                m += 1;
                if (hi2 - sp.lo2 > 1e-4) {
                    pts[m] = .{ e.x2, e.y2, hi2 };
                    m += 1;
                }
                if (hi1 - sp.lo1 > 1e-4) {
                    pts[m] = .{ e.x1, e.y1, hi1 };
                    m += 1;
                }
                addPoly(pts[0..m], SURF_WALL | k, .{ -e.nx, -e.ny, 0 });
            }
        }
    }
}

fn polySide(p: Poly, nx: f32, ny: f32, nz: f32, d: f32) Class {
    var front = false;
    var back = false;
    for (pverts[p.first .. p.first + p.n]) |v| {
        const s = nx * v[0] + ny * v[1] + nz * v[2] - d;
        if (s > 1e-3) front = true;
        if (s < -1e-3) back = true;
    }
    if (front and back) return .split;
    if (front) return .front;
    if (back) return .back;
    return .on;
}

const Class = enum { on, front, back, split };

fn splitPoly(pi: u32, nx: f32, ny: f32, nz: f32, d: f32, out_front: *u32, out_back: *u32) void {
    const p = (&polys)[pi];
    var f: [MAX_POLY_N][3]f32 = undefined;
    var b: [MAX_POLY_N][3]f32 = undefined;
    var nf: usize = 0;
    var nb: usize = 0;
    var i: u32 = 0;
    while (i < p.n) : (i += 1) {
        const a = (&pverts)[p.first + i];
        const c = (&pverts)[p.first + (i + 1) % p.n];
        const sa = nx * a[0] + ny * a[1] + nz * a[2] - d;
        const sc = nx * c[0] + ny * c[1] + nz * c[2] - d;
        if (sa >= -1e-3 and nf < MAX_POLY_N) {
            f[nf] = a;
            nf += 1;
        }
        if (sa <= 1e-3 and nb < MAX_POLY_N) {
            b[nb] = a;
            nb += 1;
        }
        if ((sa > 1e-3 and sc < -1e-3) or (sa < -1e-3 and sc > 1e-3)) {
            const t = sa / (sa - sc);
            const m: [3]f32 = .{ a[0] + (c[0] - a[0]) * t, a[1] + (c[1] - a[1]) * t, a[2] + (c[2] - a[2]) * t };
            if (nf < MAX_POLY_N) {
                f[nf] = m;
                nf += 1;
            }
            if (nb < MAX_POLY_N) {
                b[nb] = m;
                nb += 1;
            }
        }
    }
    out_front.* = @intCast(poly_count);
    addPoly(f[0..nf], p.surf, .{ p.nx, p.ny, p.nz });
    out_back.* = @intCast(poly_count);
    addPoly(b[0..nb], p.surf, .{ p.nx, p.ny, p.nz });
}

fn chooseBspSplitter(list: []const u32) usize {
    const tries: usize = if (list.len > 4000) 6 else if (list.len > 500) 12 else 20;
    const stride = @max(1, list.len / tries);
    var best: usize = 0;
    var best_score: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i < list.len) : (i += stride) {
        const c = (&polys)[list[i]];
        var front: usize = 0;
        var back: usize = 0;
        var splits: usize = 0;
        for (list) |pi| {
            switch (polySide(polys[pi], c.nx, c.ny, c.nz, c.d)) {
                .on => {},
                .front => front += 1,
                .back => back += 1,
                .split => splits += 1,
            }
        }
        const balance = if (front > back) front - back else back - front;
        const score_ = splits * 6 + balance;
        if (score_ < best_score) {
            best_score = score_;
            best = i;
        }
    }
    return best;
}

const BspItem = struct { start: usize, len: usize, parent: i32, is_front: bool, depth: usize };

// Built without recursion, as the 2D tree in Rotunda is: each pending list
// sits at the top of the scratch array, and a partition writes its back
// list then its front list over its parent.
fn buildBsp3() void {
    genPolys();
    bnode_count = 0;
    bsp_poly_count = 0;
    bsp_depth = 0;
    const base = poly_count;
    for (0..base) |i| bsp_scratch[i] = @intCast(i);
    var stack: [BSP_STACK]BspItem = undefined;
    stack[0] = .{ .start = 0, .len = base, .parent = -1, .is_front = true, .depth = 1 };
    var sp: usize = 1;
    var guard: usize = 0;
    while (sp > 0 and guard < MAX_BNODES * 2) : (guard += 1) {
        sp -= 1;
        const item = stack[sp];
        if (item.len == 0) continue;
        if (bnode_count >= MAX_BNODES) @trap();
        bsp_depth = @max(bsp_depth, item.depth);
        const list = bsp_scratch[item.start .. item.start + item.len];
        const c = (&polys)[list[chooseBspSplitter(list)]];
        const ni = bnode_count;
        bnode_count += 1;
        (&bnodes)[ni] = .{ .nx = c.nx, .ny = c.ny, .nz = c.nz, .d = c.d, .first = @intCast(bsp_poly_count) };
        if (item.parent >= 0) {
            const parent = &bnodes[@intCast(item.parent)];
            if (item.is_front) parent.front = @intCast(ni) else parent.back = @intCast(ni);
        }
        var nf: usize = 0;
        var nb: usize = 0;
        for (list) |pi| {
            switch (polySide(polys[pi], c.nx, c.ny, c.nz, c.d)) {
                .on => {
                    (&bsp_polys)[bsp_poly_count] = pi;
                    bsp_poly_count += 1;
                },
                .front => {
                    bsp_front[nf] = pi;
                    nf += 1;
                },
                .back => {
                    bsp_back[nb] = pi;
                    nb += 1;
                },
                .split => {
                    var f: u32 = 0;
                    var b: u32 = 0;
                    splitPoly(pi, c.nx, c.ny, c.nz, c.d, &f, &b);
                    bsp_front[nf] = f;
                    nf += 1;
                    bsp_back[nb] = b;
                    nb += 1;
                },
            }
        }
        (&bnodes)[ni].count = @as(u32, @intCast(bsp_poly_count)) - (&bnodes)[ni].first;
        if (item.start + nb + nf > MAX_POLYS or sp + 2 > BSP_STACK) @trap();
        @memcpy(bsp_scratch[item.start .. item.start + nb], bsp_back[0..nb]);
        @memcpy(bsp_scratch[item.start + nb .. item.start + nb + nf], bsp_front[0..nf]);
        stack[sp] = .{ .start = item.start, .len = nb, .parent = @intCast(ni), .is_front = false, .depth = item.depth + 1 };
        stack[sp + 1] = .{ .start = item.start + nb, .len = nf, .parent = @intCast(ni), .is_front = true, .depth = item.depth + 1 };
        sp += 2;
    }
    // Children come after their parents, so a backward pass gathers bounds.
    var i = bnode_count;
    while (i > 0) {
        i -= 1;
        const n = &bnodes[i];
        var lo: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
        var hi: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (bsp_polys[n.first .. n.first + n.count]) |pi| {
            const p = (&polys)[pi];
            for (pverts[p.first .. p.first + p.n]) |v| {
                for (0..3) |a| {
                    lo[a] = @min(lo[a], v[a]);
                    hi[a] = @max(hi[a], v[a]);
                }
            }
        }
        for ([_]i32{ n.front, n.back }) |ch| {
            if (ch < 0) continue;
            const cn = (&bnodes)[@intCast(ch)];
            for (0..3) |a| {
                lo[a] = @min(lo[a], cn.lo[a]);
                hi[a] = @max(hi[a], cn.hi[a]);
            }
        }
        n.lo = lo;
        n.hi = hi;
    }
}

fn ensureBsp() void {
    if (bsp_ready or !level_built) return;
    buildBsp3();
    bsp_ready = true;
}

const TILE: usize = 8;
const TILES_X: usize = SCREEN_W / TILE;
const TILES_Y: usize = SCREEN_H / TILE;

var covered: [SCREEN_W * SCREEN_H]u8 = undefined;
var row_left: [SCREEN_H]u16 = undefined;
var tile_left: [TILES_X * TILES_Y]u8 = undefined;
var pixels_left: u32 = 0;
var stat_nodes: u32 = 0;
var stat_polys: u32 = 0;

const BspVisit = struct { node: i32, draw: bool };

fn drawBsp() void {
    @memset(&covered, 0);
    @memset(&row_left, SCREEN_W);
    @memset(&tile_left, TILE * TILE);
    pixels_left = SCREEN_W * SCREEN_H;
    stat_nodes = 0;
    stat_polys = 0;
    if (bnode_count > 0) {
        var stack: [BSP_STACK]BspVisit = undefined;
        stack[0] = .{ .node = 0, .draw = false };
        var sp: usize = 1;
        while (sp > 0 and pixels_left > 0) {
            sp -= 1;
            const v = stack[sp];
            if (v.node < 0) continue;
            const n = (&bnodes)[@intCast(v.node)];
            if (v.draw) {
                for (bsp_polys[n.first .. n.first + n.count]) |pi| {
                    const p = (&polys)[pi];
                    if (p.nx * cam_x + p.ny * cam_y + p.nz * cam_z - p.d <= 0) continue;
                    rasterPoly(p);
                }
                continue;
            }
            if (!boxVisible(n.lo, n.hi)) continue;
            stat_nodes += 1;
            const front = n.nx * cam_x + n.ny * cam_y + n.nz * cam_z - n.d >= 0;
            if (sp + 3 > BSP_STACK) @trap();
            stack[sp] = .{ .node = if (front) n.back else n.front, .draw = false };
            stack[sp + 1] = .{ .node = v.node, .draw = true };
            stack[sp + 2] = .{ .node = if (front) n.front else n.back, .draw = false };
            sp += 3;
        }
    }
    // Whatever no polygon covered is sky.
    if (pixels_left > 0) {
        var c: usize = 0;
        while (c < SCREEN_W) : (c += 1) {
            const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
            const rx = cam_fx + sl * cam_rx;
            const ry = cam_fy + sl * cam_ry;
            var y: usize = 0;
            while (y < SCREEN_H) : (y += 1) {
                if (covered[y * SCREEN_W + c] != 0) continue;
                putPixel(c, y, skyColor(rx, ry, rowVz(y)));
                depth_buf[y * SCREEN_W + c] = DEPTH_SKY;
            }
        }
    }
}

// Whether any uncovered pixel could show part of a box: its corners'
// screen bounds, or the whole screen if it reaches behind the eye.
fn boxVisible(lo: [3]f32, hi: [3]f32) bool {
    var x0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    var behind: usize = 0;
    for (0..8) |i| {
        const x = if (i & 1 != 0) hi[0] else lo[0];
        const y = if (i & 2 != 0) hi[1] else lo[1];
        const z = if (i & 4 != 0) hi[2] else lo[2];
        const rx = x - cam_x;
        const ry = y - cam_y;
        const d = rx * cam_fx + ry * cam_fy;
        if (d < NEAR) {
            behind += 1;
            continue;
        }
        const sx = HALF_W + (rx * cam_rx + ry * cam_ry) * FOCAL / d;
        const sy = horizon - (z - cam_z) * FOCAL / d;
        x0 = @min(x0, sx);
        x1 = @max(x1, sx);
        y0 = @min(y0, sy);
        y1 = @max(y1, sy);
    }
    if (behind == 8) return false;
    var c0: usize = 0;
    var c1: usize = SCREEN_W;
    var r0: usize = 0;
    var r1: usize = SCREEN_H;
    if (behind == 0) {
        if (x1 < 0 or x0 > HALF_W * 2.0 or y1 < 0 or y0 > @as(f32, SCREEN_H)) return false;
        c0 = @intFromFloat(clampf(@floor(x0), 0.0, HALF_W * 2.0 - 1.0));
        c1 = @intFromFloat(clampf(@ceil(x1), 1.0, HALF_W * 2.0));
        r0 = @intFromFloat(clampf(@floor(y0), 0.0, @as(f32, SCREEN_H) - 1.0));
        r1 = @intFromFloat(clampf(@ceil(y1), 1.0, @as(f32, SCREEN_H)));
    }
    var ty = r0 / TILE;
    while (ty * TILE < r1) : (ty += 1) {
        var tx = c0 / TILE;
        while (tx * TILE < c1) : (tx += 1) {
            if (tile_left[ty * TILES_X + tx] != 0) return true;
        }
    }
    return false;
}

fn rasterPoly(p: Poly) void {
    // To view space: right, depth, height above the eye.
    var a: [MAX_POLY_N][3]f32 = undefined;
    var n: usize = 0;
    for (pverts[p.first .. p.first + p.n]) |v| {
        const rx = v[0] - cam_x;
        const ry = v[1] - cam_y;
        a[n] = .{ rx * cam_rx + ry * cam_ry, rx * cam_fx + ry * cam_fy, v[2] - cam_z };
        n += 1;
    }
    // Clip to the near plane.
    var b: [MAX_POLY_N + 2][2]f32 = undefined;
    var m: usize = 0;
    for (0..n) |i| {
        const q = a[i];
        const r = a[(i + 1) % n];
        if (q[1] >= NEAR and m < b.len) {
            b[m] = .{ HALF_W + q[0] * FOCAL / q[1], horizon - q[2] * FOCAL / q[1] };
            m += 1;
        }
        if ((q[1] >= NEAR) != (r[1] >= NEAR) and m < b.len) {
            const t = (NEAR - q[1]) / (r[1] - q[1]);
            const x = q[0] + (r[0] - q[0]) * t;
            const z = q[2] + (r[2] - q[2]) * t;
            b[m] = .{ HALF_W + x * FOCAL / NEAR, horizon - z * FOCAL / NEAR };
            m += 1;
        }
    }
    if (m < 3) return;
    var ymin: f32 = std.math.inf(f32);
    var ymax: f32 = -std.math.inf(f32);
    for (b[0..m]) |q| {
        ymin = @min(ymin, q[1]);
        ymax = @max(ymax, q[1]);
    }
    const r0: usize = @intFromFloat(clampf(@ceil(ymin - 0.5), 0.0, @as(f32, SCREEN_H)));
    const r1: usize = @intFromFloat(clampf(@ceil(ymax - 0.5), 0.0, @as(f32, SCREEN_H)));
    if (r0 >= r1) return;
    stat_polys += 1;
    const kind = p.surf & ~SURF_INDEX;
    const idx = p.surf & SURF_INDEX;
    const pn = p.nx * cam_x + p.ny * cam_y + p.nz * cam_z;
    var r = r0;
    while (r < r1) : (r += 1) {
        if (row_left[r] == 0) continue;
        const yc = @as(f32, @floatFromInt(r)) + 0.5;
        var xl: f32 = std.math.inf(f32);
        var xr: f32 = -std.math.inf(f32);
        for (0..m) |i| {
            const q = b[i];
            const s = b[(i + 1) % m];
            if ((q[1] <= yc and s[1] > yc) or (s[1] <= yc and q[1] > yc)) {
                const x = q[0] + (yc - q[1]) * (s[0] - q[0]) / (s[1] - q[1]);
                xl = @min(xl, x);
                xr = @max(xr, x);
            }
        }
        if (!(xl < xr)) continue;
        const c0: usize = @intFromFloat(clampf(@ceil(xl - 0.5), 0.0, HALF_W * 2.0));
        const c1: usize = @intFromFloat(clampf(@ceil(xr - 0.5), 0.0, HALF_W * 2.0));
        const vz = (horizon - yc) / FOCAL;
        var c = c0;
        const row = r * SCREEN_W;
        while (c < c1) : (c += 1) {
            if (covered[row + c] != 0) continue;
            const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / FOCAL;
            const rx = cam_fx + sl * cam_rx;
            const ry = cam_fy + sl * cam_ry;
            const den = p.nx * rx + p.ny * ry + p.nz * vz;
            if (den > -1e-9) continue;
            const t = maxf((p.d - pn) / den, NEAR);
            const color = switch (kind) {
                SURF_FLOOR => shadeFloor(@intCast(idx), rx, ry, vz, t),
                SURF_CEIL => shadeCeil(@intCast(idx), rx, ry, vz, t),
                else => shadeWall(idx, rx, ry, vz, t),
            };
            putPixel(c, r, color);
            depth_buf[row + c] = depthCode(t);
            covered[row + c] = 1;
            row_left[r] -= 1;
            tile_left[(r / TILE) * TILES_X + c / TILE] -= 1;
            pixels_left -= 1;
        }
    }
}

fn drawScene() void {
    sun = sunDir();
    if (engine == .bsp and bsp_ready) drawBsp() else drawBuild();
}

// Sprites

const SpriteKind = enum(u8) { gull, flyer, tessera };
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
    for (birds, 0..) |b, i| {
        if (!b.active) continue;
        if (b.mode == .ground) {
            n = pushSprite(n, b.x, b.y, b.z, 0.7 * BIRD_SCALE, 0.5 * BIRD_SCALE, .gull, @intCast(i));
        } else {
            const span = BIRD_SCALE * GULL_SPAN;
            n = pushSprite(n, b.x, b.y, b.z - span * 0.3, span, span * 0.6, .flyer, @intCast(i));
        }
    }
    const t: f32 = @as(f32, @floatFromInt(anim_ms)) * 0.001;
    for (pickups, 0..) |p, i| {
        if (!p.active) continue;
        n = pushSprite(n, p.x, p.y, p.z + 0.7 + 0.1 * @sin(t * 2.0 + @as(f32, @floatFromInt(i))), 0.7, 0.7, .tessera, @intCast(i));
    }
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
    const x0: usize = @intFromFloat(clampf(@ceil(sx - s.w * 0.5 * scale - 0.5), 0.0, HALF_W * 2.0));
    const x1: usize = @intFromFloat(clampf(@ceil(sx + s.w * 0.5 * scale - 0.5), 0.0, HALF_W * 2.0));
    const y0: usize = @intFromFloat(clampf(@ceil(y_top - 0.5), 0.0, @as(f32, SCREEN_H)));
    const y1: usize = @intFromFloat(clampf(@ceil(y_bot - 0.5), 0.0, @as(f32, SCREEN_H)));
    if (x0 >= x1 or y0 >= y1) return;
    const light: f32 = switch (s.kind) {
        .gull => birds[s.index].light,
        .flyer => 1.0,
        .tessera => pickups[s.index].light,
    };
    const open = s.kind == .flyer;
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
            if (s.kind == .tessera) {
                col = col * splat(maxf(0.55, light * 1.3));
            } else {
                col = haze(col * splat(light * 1.15), s.depth, open or light > 0.6);
            }
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
        .gull => shadeGull(birds[s.index], s.h / BIRD_SCALE, mx / BIRD_SCALE, my / BIRD_SCALE),
        .flyer => shadeFlyer(birds[s.index], s.w / BIRD_SCALE, s.h / BIRD_SCALE, mx / BIRD_SCALE, my / BIRD_SCALE),
        .tessera => shadeTessera(s.index, mx, my - 0.35),
    };
}

fn rgba(c: Rgb, a: f32) Rgba {
    return .{ c[0], c[1], c[2], a };
}

const CLEAR: Rgba = .{ 0, 0, 0, 0 };
const GULL_WHITE: Rgb = .{ 0.95, 0.95, 0.94 };
const GULL_GREY: Rgb = .{ 0.62, 0.66, 0.72 };
const GULL_BLACK: Rgb = .{ 0.1, 0.1, 0.11 };
const GULL_BEAK: Rgb = .{ 0.95, 0.8, 0.2 };

fn noseSign(b: Bird) f32 {
    return if (b.hx * cam_rx + b.hy * cam_ry < 0) -1 else 1;
}

// A gull standing in profile, white with a grey back, black wing tips, and
// a yellow bill; mx runs toward its head and y is height above its feet.
fn shadeGull(b: Bird, h: f32, mx: f32, my: f32) Rgba {
    const x = mx * noseSign(b);
    const y = h - my;
    const hdx = x - 0.16;
    const hdy = y - 0.36;
    if (hdx * hdx + hdy * hdy < 0.065 * 0.065) {
        const ex = hdx - 0.02;
        const ey = hdy - 0.015;
        if (ex * ex + ey * ey < 0.011 * 0.011) return rgba(.{ 0.1, 0.1, 0.1 }, 1);
        return rgba(GULL_WHITE, 1);
    }
    if (x > 0.21 and x < 0.31 and @abs(y - 0.35 + (x - 0.21) * 0.25) < 0.016) {
        if (x > 0.27 and y < 0.345) return rgba(.{ 0.85, 0.2, 0.15 }, 1);
        return rgba(GULL_BEAK, 1);
    }
    const nx = x - 0.12;
    const ny = y - 0.28;
    if (nx * nx / (0.05 * 0.05) + ny * ny / (0.09 * 0.09) < 1) return rgba(GULL_WHITE, 1);
    const ex = (x + 0.02) / 0.2;
    const ey = (y - 0.2) / 0.1;
    if (ex * ex + ey * ey < 1) {
        if (ey > 0.1 - ex * 0.2) return rgba(GULL_GREY, 1);
        return rgba(GULL_WHITE * splat(0.9 + 0.1 * (1.0 - ey * ey)), 1);
    }
    // Black wing tips over the tail.
    if (x < -0.18 and x > -0.33 and @abs(y - 0.22 - (x + 0.18) * 0.2) < 0.025) return rgba(GULL_BLACK, 1);
    for ([_]f32{ -0.02, 0.04 }) |lx| {
        if (@abs(x - lx) < 0.012 and y < 0.11) return rgba(.{ 0.9, 0.62, 0.5 }, 1);
    }
    return CLEAR;
}

// A gull in flight: long narrow wings, foreshortened when seen end on, with
// black tips, beating or held level for a glide.
fn shadeFlyer(b: Bird, w: f32, h: f32, mx: f32, my: f32) Rgba {
    const y = my - h * 0.5;
    var vx = b.x - cam_x;
    var vy = b.y - cam_y;
    const vz = b.z - cam_z;
    const vl = @sqrt(vx * vx + vy * vy + vz * vz);
    vx /= vl;
    vy /= vl;
    const toward_wing = b.hy * vx - b.hx * vy;
    const spread = @sqrt(@max(0.08, 1.0 - toward_wing * toward_wing));
    const toward_nose = b.hx * vx + b.hy * vy;
    const side = @sqrt(maxf(0.0, 1.0 - toward_nose * toward_nose));
    const half_body = 0.2 * side + 0.05;
    const x = mx * noseSign(b);
    const bx = x / half_body;
    const by = y / 0.05;
    if (bx * bx + by * by < 1) return rgba(GULL_WHITE * splat(0.85 + 0.15 * (1.0 - by * by)), 1);
    const hdx = x - half_body;
    if (hdx * hdx + y * y < 0.045 * 0.045) return rgba(GULL_WHITE, 1);
    if (side > 0.3 and hdx > 0 and hdx < 0.07 * side and @abs(y + 0.005) < 0.012) return rgba(GULL_BEAK, 1);
    const half = w * 0.5 * spread;
    const ax = @abs(mx);
    if (ax >= half) return CLEAR;
    const t = ax / half;
    const lift: f32 = if (b.glide) 0.05 else @sin(b.flap) * 0.3;
    // Gull wings bend at the wrist.
    const wy = -lift * half * t - (if (b.glide) 0.04 * maxf(0.0, t - 0.5) else 0.0);
    const thick = 0.055 * (1.0 - 0.6 * t) + 0.01;
    if (@abs(y - wy) >= thick) return CLEAR;
    if (t > 0.78) return rgba(GULL_BLACK, 1);
    if (y - wy < -thick * 0.2) return rgba(GULL_GREY, 1);
    return rgba(GULL_WHITE * splat(0.92), 1);
}

// A bone entry token, turning slowly, with its seat number cut into it.
fn shadeTessera(i: u8, mx: f32, my: f32) Rgba {
    const t: f32 = @as(f32, @floatFromInt(anim_ms)) * 0.0015 + @as(f32, @floatFromInt(i));
    const sq = @abs(@cos(t));
    const w = 0.22 * @max(0.12, sq);
    const ex = mx / w;
    const ey = my / 0.22;
    const d2 = ex * ex + ey * ey;
    if (d2 < 1) {
        if (sq > 0.4 and @abs(ex) < 0.12 and ey > -0.6 and ey < 0.6) return rgba(.{ 0.35, 0.25, 0.15 }, 1);
        return rgba(Rgb{ 0.92, 0.86, 0.7 } * splat(0.8 + 0.25 * (1.0 - d2)), 1);
    }
    const r = @sqrt(mx * mx + my * my);
    if (r < 0.36) {
        const k = 1.0 - (r - 0.22) / 0.14;
        return rgba(.{ 1.0, 0.9, 0.6 }, clampf(k * k * 0.5, 0.0, 1.0));
    }
    return CLEAR;
}

// Overlays

fn drawFrame() void {
    if (bench_view >= 0) {
        const v = BENCH_VIEWS[@intCast(bench_view)];
        const z = if (v.z == 0) seatZ(chordCoords(v.x, v.y).s) + EYE_Z else v.z;
        setCamera(v.x, v.y, z, v.angle, v.look, sectorAt(v.x, v.y, z));
        drawScene();
        drawSprites();
        return;
    }
    if (mode == .title) {
        const z = TERRACE_Z + EYE_Z;
        setCamera(0, 57, z, -std.math.pi / 2.0 + 0.1, -45, sectorAt(0, 57, z));
    } else {
        setCamera(px, py, pz + (if (flying) FLY_EYE else EYE_Z), pangle, look, psec);
    }
    drawScene();
    drawSprites();
    if (mode != .title) {
        if (flying) drawWings();
        if (map_on) drawMap();
        drawHud();
    }
    switch (mode) {
        .title => drawTitle(),
        .paused => drawPaused(),
        .won => drawEnd("AVE IMPERATOR", C_TITLE),
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
    drawText(6 * UI, H - 16 * UI, 1, "TESSERAE", C_TEXT_DIM);
    var i: usize = 0;
    while (i < MAX_PICKUPS) : (i += 1) {
        const x: i32 = (52 + @as(i32, @intCast(i)) * 13) * UI;
        if ((tesserae >> @intCast(i)) & 1 != 0) {
            fillCircle(x, H - 10 * UI, 4 * UI, C_TESSERA);
        } else {
            ringCircle(x, H - 10 * UI, 4 * UI, C_TESSERA_DIM);
        }
    }
    drawText(166 * UI, H - 16 * UI, 1, "SCORE", C_TEXT_DIM);
    drawNumber(188 * UI, H - 17 * UI, 2, score, 5, C_TEXT);
    drawTime(W - 38 * UI, H - 16 * UI, 1);
    if (flying) {
        // The gull's height above the street, in metres.
        drawText(W - 60 * UI, 4 * UI, 1, "GULL", C_TEXT);
        drawNumber(W - 36 * UI, 4 * UI, 1, @intFromFloat(clampf(@round(pz), 0.0, 999.0)), 1, C_TEXT);
        drawText(W - 16 * UI, 4 * UI, 1, "M", C_TEXT_DIM);
    }
    drawText(4 * UI, 4 * UI, 1, if (engine == .bsp) "BSP 3D" else "SECTORS", C_TEXT_DIM);
    drawNumber(36 * UI, 4 * UI, 1, if (engine == .bsp) stat_polys else stat_visits, 1, C_TEXT_DIM);
    if (message_ms > 0) drawTextCentered(24 * UI, 2, message, if (tesserae == ALL_TESSERAE) C_TITLE else C_TEXT);
}

// The gull's own wings at the sides of the view, beating while it climbs
// and held out flat while it glides.
fn drawWings() void {
    const lift = @sin(fly_flap) * (if ((keys_down & KEY_FWD) != 0 or jump_held) @as(f32, 70) else 0);
    const len: i32 = 150 * UI;
    const ui: f32 = @floatFromInt(UI);
    const root_y: f32 = @as(f32, @floatFromInt(H)) - 46.0 * ui;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        // t runs from the wing tip at the screen's edge to its root.
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(len));
        const cy = root_y + (1.0 - t) * (16.0 * ui - lift) - (1.0 - t) * (1.0 - t) * 10.0 * ui;
        const half = (3.0 + 9.0 * t) * ui;
        const c: Color = if (t < 0.22) .{ 0x1A, 0x1A, 0x1C, 0xFF } else .{ 0xEE, 0xEE, 0xEC, 0xFF };
        const y0: i32 = @intFromFloat(cy - half);
        const h: i32 = @intFromFloat(half * 2.0);
        fillRect(i, y0, 1, h, c);
        fillRect(W - 1 - i, y0, 1, h, c);
        // The grey back of the wing along its leading edge.
        if (t >= 0.22) {
            fillRect(i, y0, 1, @divTrunc(h, 3), .{ 0x9E, 0xA8, 0xB4, 0xFF });
            fillRect(W - 1 - i, y0, 1, @divTrunc(h, 3), .{ 0x9E, 0xA8, 0xB4, 0xFF });
        }
    }
}

const MAP_SCALE: f32 = 1.0 * @as(f32, UI);

fn mapPoint(x: f32, y: f32) [2]i32 {
    return .{
        @intFromFloat(clampf(@as(f32, 160 * UI) + x * MAP_SCALE, -2000, 2000)),
        @intFromFloat(clampf(@as(f32, 112 * UI) - y * MAP_SCALE, -2000, 2000)),
    };
}

// The plan of the level the player stands on: walls with solid spans at
// the player's height are bright, and the rest are dim.
fn drawMap() void {
    blendRect(46 * UI, 18 * UI, 228 * UI, 188 * UI, C_MAP_BG);
    for (edges[0..edge_count]) |e| {
        var here = false;
        var any = false;
        var k = e.first_span;
        while (k < e.first_span + e.span_count) : (k += 1) {
            const sp = (&spans)[k];
            if (sp.kind != .solid) continue;
            any = true;
            if (@min(sp.lo1, sp.lo2) < pz + 1.8 and @max(sp.hi1, sp.hi2) > pz + 0.3) here = true;
        }
        if (!any) continue;
        const a = mapPoint(e.x1, e.y1);
        const b = mapPoint(e.x2, e.y2);
        if (here) drawLine(a[0], a[1], b[0], b[1], C_MAP_WALL) else if (@abs(floorAt(e.sector, e.x1, e.y1) - pz) < 3.0) drawLine(a[0], a[1], b[0], b[1], C_MAP_DIM);
    }
    for (pickups) |p| {
        if (!p.active) continue;
        const m = mapPoint(p.x, p.y);
        fillRect(m[0] - 2, m[1] - 2, 5, 5, C_TESSERA);
    }
    for (birds) |b| {
        if (!b.active) continue;
        const m = mapPoint(b.x, b.y);
        fillRect(m[0], m[1], 2, 2, C_MAP_BIRD);
    }
    const pc = mapPoint(pulvinarCentre()[0], pulvinarCentre()[1]);
    ringCircle(pc[0], pc[1], 4 * UI, .{ 0xB0, 0x50, 0xA0, 0xFF });
    const p = mapPoint(px, py);
    const f = forward();
    fillRect(p[0] - 2, p[1] - 2, 5, 5, C_MAP_PLAYER);
    drawLine(p[0], p[1], p[0] + @as(i32, @intFromFloat(f[0] * 14)), p[1] - @as(i32, @intFromFloat(f[1] * 14)), C_MAP_PLAYER);
    drawText(52 * UI, 22 * UI, 1, "MAP", C_TITLE);
}

fn drawTitle() void {
    blendRect(0, 0, W, H, .{ 0x06, 0x05, 0x08, 0x70 });
    drawTextCentered(30 * UI, 6, "COLOSSEUM", C_TITLE);
    drawTextCentered(66 * UI, 2, "AMPHITHEATRUM FLAVIUM - ROME", C_TEXT);
    drawTextCentered(96 * UI, 1, "UP DOWN OR W S MOVE   LEFT RIGHT TURN   A D STRAFE", C_TEXT);
    drawTextCentered(106 * UI, 1, "Q E OR PAGE UP DOWN LOOK   SPACE JUMP", C_TEXT);
    drawTextCentered(116 * UI, 1, "G FLY AS A GULL   M MAP   B SECTORS OR BSP 3D   P PAUSE   R RESTART", C_TEXT);
    drawTextCentered(138 * UI, 2, "FIND THE EIGHT TESSERAE", C_TEXT);
    drawTextCentered(156 * UI, 2, "THEN TAKE THE EMPERORS BOX", C_TEXT);
    drawTextCentered(192 * UI, 2, "PRESS SPACE TO START", C_TITLE_ALT);
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
    map_on = false;
    bench_view = -1;
    engine = .build;
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

test "title renders and the views render with both engines" {
    resetForTest();
    _ = renderImpl(0);
    _ = renderImpl(0);
    var v: i32 = 0;
    while (v < BENCH_VIEWS.len) : (v += 1) {
        try std.testing.expectEqual(@as(i32, 1), bench_set_view(v, 0));
        _ = renderImpl(0);
        try std.testing.expectEqual(@as(i32, 1), bench_set_view(v, 1));
        _ = renderImpl(0);
    }
    _ = bench_set_view(-1, 0);
}

test "every sector is convex and wound counter-clockwise" {
    resetForTest();
    _ = renderImpl(0);
    for (sectors[0..sector_count]) |s| {
        var i: u32 = 0;
        while (i < s.vert_count) : (i += 1) {
            const a = verts[s.first_vert + i];
            const b = verts[s.first_vert + (i + 1) % s.vert_count];
            const c = verts[s.first_vert + (i + 2) % s.vert_count];
            const cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
            try std.testing.expect(cross > -1e-3);
        }
    }
}

// The far side of an opening at a point: the bottom and top of the span in
// the sector beyond that opens back, on its edge through the point.
fn backSpan(next: u16, from: u16, x: f32, y: f32) ?[2]f32 {
    const t = sectors[next];
    var ei = t.first_edge;
    while (ei < t.first_edge + t.edge_count) : (ei += 1) {
        const e = edges[ei];
        if (@abs(e.nx * x + e.ny * y - e.d) > 2e-3) continue;
        const p = ((x - e.x1) * (e.x2 - e.x1) + (y - e.y1) * (e.y2 - e.y1)) / (e.len * e.len);
        if (p < 0 or p > 1) continue;
        var k = e.first_span;
        while (k < e.first_span + e.span_count) : (k += 1) {
            const sp = spans[k];
            if (sp.kind == .open and sp.next == from) return .{ lerp(sp.lo1, sp.lo2, p), @min(INF, lerp(sp.hi1, sp.hi2, p)) };
        }
    }
    return null;
}

test "openings match from both sides and walls under the sky have tops" {
    resetForTest();
    _ = renderImpl(0);
    var opens: usize = 0;
    for (edges[0..edge_count]) |e| {
        var k = e.first_span;
        var below = planeZ(sectors[e.sector].floor, e.x1, e.y1);
        while (k < e.first_span + e.span_count) : (k += 1) {
            const sp = spans[k];
            // Spans stack without gaps from the floor up.
            try std.testing.expectApproxEqAbs(below, sp.lo1, 1e-3);
            below = sp.hi1;
            if (sp.kind == .solid) try std.testing.expect(@max(sp.hi1, sp.hi2) < 1000);
            if (sp.kind != .open) continue;
            opens += 1;
            const back = backSpan(sp.next, e.sector, (e.x1 + e.x2) * 0.5, (e.y1 + e.y2) * 0.5) orelse return error.MissingBackSpan;
            try std.testing.expectApproxEqAbs((sp.lo1 + sp.lo2) * 0.5, back[0], 0.02);
            try std.testing.expectApproxEqAbs(@min(INF, (sp.hi1 + sp.hi2) * 0.5), back[1], 0.02);
        }
    }
    try std.testing.expect(opens > 1000);
}

test "rooms stack: sectors overlap in plan at different heights" {
    resetForTest();
    _ = renderImpl(0);
    // The two ambulatories and the terrace over the north arches.
    const p = chordPt(59, 12, 0.5);
    try std.testing.expectEqual(Kind.amb_g, sectors[sectorAt(p[0], p[1], 1)].kind);
    try std.testing.expectEqual(Kind.amb_u, sectors[sectorAt(p[0], p[1], 11)].kind);
    try std.testing.expectEqual(Kind.terrace, sectors[sectorAt(p[0], p[1], 23)].kind);
    try std.testing.expectEqual(NO_SECTOR, sectorAt(p[0], p[1], 9.5));
    // A hypogeum doorway under a wall top, and covered corridors under the deck.
    try std.testing.expectEqual(Kind.doorway, sectors[sectorAt(-20, 5, -5)].kind);
    try std.testing.expectEqual(Kind.wall_top, sectors[sectorAt(-20, 5, 0.5)].kind);
    try std.testing.expectEqual(Kind.covered, sectors[sectorAt(20, 5, -5)].kind);
    try std.testing.expectEqual(Kind.deck, sectors[sectorAt(20, 5, 0.5)].kind);
    // The west passage runs under the seats.
    const w = chordPt(44, 24, 0.5);
    try std.testing.expectEqual(Kind.tunnel, sectors[sectorAt(w[0], w[1], 1)].kind);
    try std.testing.expectEqual(Kind.seats, sectors[sectorAt(w[0], w[1], 20)].kind);
}

// Walks the player toward each point in turn, as a held forward key would.
fn walkRoute(points: []const [2]f32, kinds: *[32]Kind, nk: *usize) !void {
    for (points) |target| {
        var steps: usize = 0;
        while (steps < 3000) : (steps += 1) {
            const dx = target[0] - px;
            const dy = target[1] - py;
            if (dx * dx + dy * dy < 0.2 * 0.2) break;
            pangle = std.math.atan2(dy, dx);
            keys_down = KEY_FWD;
            stepGame();
            const k = sectors[psec].kind;
            if (nk.* == 0 or kinds[nk.* - 1] != k) {
                if (nk.* < kinds.len) {
                    kinds[nk.*] = k;
                    nk.* += 1;
                }
            }
        } else return error.Stuck;
    }
    keys_down = 0;
    var settle_steps: usize = 0;
    while (settle_steps < 200) : (settle_steps += 1) stepGame();
}

fn visited(kinds: []const Kind, k: Kind) bool {
    for (kinds) |q| if (q == k) return true;
    return false;
}

test "a walk from the street through the west passage reaches the hypogeum" {
    _ = startForTest();
    var kinds: [32]Kind = undefined;
    var nk: usize = 0;
    try walkRoute(&.{ .{ -84, 0 }, .{ -74, 0 }, .{ -60, 0 }, .{ -42, 0 }, .{ -35, 0 }, .{ -29, 0 }, .{ -22, 0 }, .{ -15, 0.5 } }, &kinds, &nk);
    try std.testing.expectEqual(Kind.pit, sectors[psec].kind);
    try std.testing.expectApproxEqAbs(PIT_Z, pz, 0.01);
    for ([_]Kind{ .outside, .amb_g, .tunnel, .arena, .pit }) |k| try std.testing.expect(visited(kinds[0..nk], k));
    // And back up the ramp.
    try walkRoute(&.{ .{ -22, 0 }, .{ -34, 0 } }, &kinds, &nk);
    try std.testing.expectEqual(Kind.arena, sectors[psec].kind);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pz, 0.01);
}

fn teleport(x: f32, y: f32, z: f32) void {
    px = x;
    py = y;
    pz = z;
    psec = sectorAt(x, y, z + 0.1);
    fall_v = 0;
}

test "stairs climb from the lower ambulatory to the top and down the seats to the box" {
    _ = startForTest();
    const g = chordPt(59, 30, 0.25);
    teleport(g[0], g[1], 0);
    var route: [64][2]f32 = undefined;
    var n: usize = 0;
    for ([_][3]f32{ .{ 55.7, 30, 0.25 }, .{ 45.4, 30, 0.25 }, .{ 44, 30, 0.5 }, .{ 46, 30, 0.75 }, .{ 55.5, 30, 0.75 }, .{ 58, 30, 0.75 } }) |w| {
        route[n] = chordPt(w[0], @intFromFloat(w[1]), w[2]);
        n += 1;
    }
    var kinds: [32]Kind = undefined;
    var nk: usize = 0;
    try walkRoute(route[0..n], &kinds, &nk);
    try std.testing.expectEqual(Kind.amb_u, sectors[psec].kind);
    try std.testing.expectApproxEqAbs(U_FLOOR, pz, 0.01);
    for ([_]Kind{ .amb_g, .stair_a, .landing, .lane_b }) |k| try std.testing.expect(visited(kinds[0..nk], k));

    // Round the upper ambulatory, up the open stair to the terrace.
    n = 0;
    var k: i32 = 31;
    while (k <= 41) : (k += 1) {
        route[n] = chordPt(58.5, k, 0.5);
        n += 1;
    }
    for ([_][3]f32{ .{ 60.5, 41, 0.6 }, .{ 60.5, 42, 0.1 }, .{ 60.5, 42, 0.6 }, .{ 60.5, 43, 0.2 }, .{ 60.5, 43, 0.95 }, .{ 58, 44, 0.3 } }) |w| {
        route[n] = chordPt(w[0], @intFromFloat(w[1]), w[2]);
        n += 1;
    }
    nk = 0;
    try walkRoute(route[0..n], &kinds, &nk);
    try std.testing.expectEqual(Kind.terrace, sectors[psec].kind);
    try std.testing.expectApproxEqAbs(TERRACE_Z, pz, 0.01);
    try std.testing.expect(visited(kinds[0..nk], .stair_t));

    // Down the seats onto the podium and along it to the emperor's box.
    n = 0;
    for ([_][3]f32{ .{ 50, 44, 0.3 }, .{ 34, 44, 0.3 }, .{ 31.5, 44, 0.3 } }) |w| {
        route[n] = chordPt(w[0], @intFromFloat(w[1]), w[2]);
        n += 1;
    }
    k = 43;
    while (k >= 36) : (k -= 1) {
        route[n] = chordPt(31.5, k, 0.5);
        n += 1;
    }
    nk = 0;
    try walkRoute(route[0..n], &kinds, &nk);
    try std.testing.expectEqual(Kind.podium, sectors[psec].kind);
    try std.testing.expect(inPulvinar(px, py, pz));
}

// Whether a walker standing in one sector, raised by lift, can pass into
// another anywhere along their shared sides.
fn canStep(from: u16, to: u16, lift: f32) bool {
    const s = sectors[from];
    var ei = s.first_edge;
    while (ei < s.first_edge + s.edge_count) : (ei += 1) {
        const e = edges[ei];
        var j: usize = 0;
        while (j <= 8) : (j += 1) {
            const u = @as(f32, @floatFromInt(j)) / 8.0;
            const z = planeZ(s.floor, lerp(e.x1, e.x2, u), lerp(e.y1, e.y2, u)) + lift;
            if (passTarget(ei, u, z) == to) return true;
        }
    }
    return false;
}

test "every room you can walk, jump, or fall into leads back to the street" {
    resetForTest();
    _ = renderImpl(0);
    const jump_h = JUMP_V * JUMP_V / (2.0 * GRAVITY);
    var reach = [_]bool{false} ** MAX_SECTORS;
    var home = [_]bool{false} ** MAX_SECTORS;
    reach[psec] = true;
    home[psec] = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (0..sector_count) |a| for (0..sector_count) |b| {
            const ai: u16 = @intCast(a);
            const bi: u16 = @intCast(b);
            if (reach[a] and !reach[b] and (canStep(ai, bi, 0) or canStep(ai, bi, jump_h))) {
                reach[b] = true;
                changed = true;
            }
            // The way back may not depend on a jump.
            if (home[b] and !home[a] and canStep(ai, bi, 0)) {
                home[a] = true;
                changed = true;
            }
        };
    }
    for (0..sector_count) |si| {
        try std.testing.expect(reach[si]);
        if (!home[si]) {
            std.debug.print("no way back from sector {d} ({s})\n", .{ si, @tagName(sectors[si].kind) });
            return error.Trapped;
        }
    }
}

// Runs whole updates of the game, as a host would, with keys held.
fn flySteps(at_ms: *i64, steps: usize, keys: u8) void {
    keys_down = keys;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        at_ms.* += STEP_MS;
        _ = runUpdate(at_ms.*);
    }
}

fn pressKey(at_ms: *i64, key: i32) void {
    at_ms.* += 1;
    begin_update_at(at_ms.*);
    _ = key_event(key, FLAG_KEY_DOWN);
    _ = key_event(key, 0);
    _ = finish_update();
}

test "a gull climbs out of a hypogeum corridor and lands in the arena" {
    var t = startForTest();
    teleport(-25, -15.5, PIT_Z);
    pangle = 0;
    pressKey(&t, 'g');
    try std.testing.expect(flying);
    // Climb along the corridor until clear of its walls, then glide north
    // over the wall tops and the arena.
    flySteps(&t, 300, KEY_FWD);
    try std.testing.expect(pz > 5.0);
    pangle = std.math.pi / 2.0;
    flySteps(&t, 240, 0);
    try std.testing.expect(py > HY_YS[HY_YS.len - 1]);
    pressKey(&t, 'G');
    try std.testing.expect(!flying);
    flySteps(&t, 200, 0);
    try std.testing.expectEqual(Kind.arena, sectors[psec].kind);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pz, 0.01);
    // As a gull it picks nothing up.
    try std.testing.expectEqual(@as(u8, 0), tesserae);
}

test "a gull in flight stays in the air of the room it is in" {
    var t = startForTest();
    pressKey(&t, 'g');
    var leg: usize = 0;
    while (leg < 40) : (leg += 1) {
        // Wander: turn, then climb, glide, or dive at random.
        pangle = wrapAngle(pangle + rngFloat(-2.0, 2.0));
        const keys: u8 = switch (rngNext() % 3) {
            0 => KEY_FWD,
            1 => 0,
            else => KEY_BACK,
        };
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            flySteps(&t, 1, keys);
            const s = sectors[psec];
            try std.testing.expect(insideSector(psec, px, py, 0.02));
            try std.testing.expect(pz >= planeZ(s.floor, px, py) + FLY_R - 0.01);
            try std.testing.expect(pz <= ceilZ(s, px, py) - FLY_R + 0.01);
        }
    }
    pressKey(&t, 'g');
    flySteps(&t, 400, 0);
    try std.testing.expectApproxEqAbs(floorAt(psec, px, py), pz, 0.01);
}

test "walls, piers, and the podium parapet stop the player" {
    _ = startForTest();
    // Into a pier between two arches.
    const pier = chordPt(66, 23, 1.0);
    teleport(pier[0], pier[1], 0);
    const into = chordPt(50, 23, 1.0);
    pangle = std.math.atan2(into[1] - py, into[0] - px);
    keys_down = KEY_FWD;
    var i: usize = 0;
    while (i < 200) : (i += 1) stepGame();
    try std.testing.expectEqual(Kind.outside, sectors[psec].kind);
    try std.testing.expect(chordCoords(px, py).s > S_OUTER);
    // From the arena toward the podium: the wall is too high to climb.
    teleport(0, 25, 0);
    pangle = std.math.pi / 2.0;
    i = 0;
    while (i < 200) : (i += 1) stepGame();
    try std.testing.expectEqual(Kind.arena, sectors[psec].kind);
    try std.testing.expect(chordCoords(px, py).s < S_ARENA);
    // Off a hypogeum wall top into a corridor.
    keys_down = 0;
    teleport(-15, 7.5, 0);
    keys_down = KEY_FWD;
    pangle = -std.math.pi / 2.0;
    i = 0;
    while (i < 200) : (i += 1) stepGame();
    try std.testing.expectEqual(Kind.pit, sectors[psec].kind);
    try std.testing.expectApproxEqAbs(PIT_Z, pz, 0.01);
}

test "tesserae, perches, and the start lie on floors" {
    resetForTest();
    _ = renderImpl(0);
    try std.testing.expect(psec != NO_SECTOR);
    try std.testing.expectEqual(Kind.outside, sectors[psec].kind);
    for (pickups) |p| {
        try std.testing.expect(p.active);
        const si = sectorAt(p.x, p.y, p.z + 0.5);
        try std.testing.expectApproxEqAbs(p.z, floorAt(si, p.x, p.y), 0.05);
    }
    for (perches[0..perch_count]) |p| {
        const si = sectorAt(p.x, p.y, p.z + 0.3);
        try std.testing.expect(si != NO_SECTOR);
        try std.testing.expect(sectors[si].sky);
    }
}

test "every tessera then the emperor's box wins" {
    _ = startForTest();
    for (pickups) |p| {
        teleport(p.x, p.y, p.z);
        stepGame();
    }
    try std.testing.expectEqual(ALL_TESSERAE, tesserae);
    try std.testing.expectEqual(Mode.playing, mode);
    const c = pulvinarCentre();
    teleport(c[0], c[1], POD_Z);
    stepGame();
    try std.testing.expectEqual(Mode.won, mode);
    try std.testing.expect(score > 4000);
}

test "gulls keep to open air and land only on perches" {
    _ = startForTest();
    teleport(0, 0, 0);
    var landings: usize = 0;
    var step: usize = 0;
    while (step < 180 * 1000 / 16) : (step += 1) {
        var was_ground: [MAX_BIRDS]bool = undefined;
        for (birds, 0..) |b, i| was_ground[i] = b.mode == .ground;
        updateBirds();
        for (birds, 0..) |b, i| {
            if (b.mode == .ground) {
                if (!was_ground[i]) landings += 1;
                const p = perches[b.spot];
                try std.testing.expectEqual(p.z, b.z);
                continue;
            }
            if (b.z > TERRACE_Z + PARAPET + 0.5) continue;
            const si = sectorAt(b.x, b.y, b.z);
            if (si == NO_SECTOR or !sectors[si].sky) return error.GullInWall;
        }
    }
    try std.testing.expect(landings > 5);
}

test "both renderers draw the same picture" {
    resetForTest();
    _ = renderImpl(0);
    var v: i32 = 0;
    while (v < BENCH_VIEWS.len) : (v += 1) {
        _ = bench_set_view(v, 0);
        _ = renderImpl(0);
        const a = output_buf;
        const da = depth_buf;
        _ = bench_set_view(v, 1);
        _ = renderImpl(0);
        var same: usize = 0;
        var i: usize = 0;
        while (i < SCREEN_W * SCREEN_H) : (i += 1) {
            const o = ktx.HEADER_SIZE + i * 4;
            var ok = true;
            for (0..3) |ch| ok = ok and @abs(@as(i32, a[o + ch]) - @as(i32, output_buf[o + ch])) <= 8;
            const za: f32 = @floatFromInt(da[i]);
            const zb: f32 = @floatFromInt(depth_buf[i]);
            ok = ok and @abs(za - zb) <= 0.02 * za + 4;
            if (ok) same += 1;
        }
        try std.testing.expect(same * 100 >= SCREEN_W * SCREEN_H * 99);
    }
    _ = bench_set_view(-1, 0);
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
    try std.testing.expectEqual(@as(i64, 34), finish_update());
    const x0 = px;
    try std.testing.expectEqual(@as(i64, 50), runUpdate(34));
    try std.testing.expectApproxEqAbs(x0 + MOVE_STEP, px, 1e-4);
}

test "pause stops the clock and B swaps renderers" {
    var t = startForTest();
    t += 16;
    _ = runUpdate(t);
    begin_update_at(t + 1);
    try std.testing.expectEqual(@as(i32, 1), key_event('p', FLAG_KEY_DOWN));
    try std.testing.expectEqual(t + 1, finish_update());
    const frozen = time_ms;
    _ = runUpdate(t + 5000);
    try std.testing.expectEqual(frozen, time_ms);
    begin_update_at(t + 5001);
    try std.testing.expectEqual(@as(i32, 1), key_event('b', FLAG_KEY_DOWN));
    _ = finish_update();
    try std.testing.expectEqual(Engine.bsp, engine);
    try std.testing.expect(bsp_ready);
    _ = renderImpl(0);
    try std.testing.expect(stat_polys > 0);
}

test "locked pointer movement turns and tilts the view once" {
    _ = startForTest();
    const a0 = pangle;
    begin_update_at(2);
    _ = uniform_set_pointer_total_movement_x(100);
    _ = uniform_set_pointer_total_movement_y(-40);
    _ = finish_update();
    try std.testing.expectApproxEqAbs(wrapAngle(a0 - 100 * MOUSE_TURN), pangle, 1e-5);
    const l = look;
    _ = uniform_set_pointer_total_movement_x(100);
    begin_update_at(3);
    _ = uniform_set_pointer_total_movement_x(100);
    _ = uniform_set_pointer_total_movement_y(-40);
    _ = finish_update();
    try std.testing.expectApproxEqAbs(wrapAngle(a0 - 100 * MOUSE_TURN), pangle, 1e-5);
    try std.testing.expectEqual(l, look);
}
