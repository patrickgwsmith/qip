const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

// HoverCraftsman. It is 1998 and your startup's office is a large orange
// hovercraft on San Francisco Bay. Walk the cabin, write the investor demo at
// the 17 inch CRT in your cubicle, upload it over the satellite link, and
// bring the office alongside the investors' pier before five o'clock.
//
// The craft and the bay are each a true 3D BSP of convex polygons, as in
// Halo's structure BSP. The craft's tree is built in the craft's own frame
// and moves with it. Each frame walks the craft's tree front to back, then
// the bay's tree into whatever pixels the craft left uncovered: from inside
// the cabin those are the windows. From outside, the bay's pixels are depth
// tested against the craft's instead.
//
// The craft handles as a hovercraft does. Its rudders sit in the propellers'
// wash, so closing the throttle takes most of the steering away. Turning
// changes the heading first; the momentum carries on the old way, and the
// thrust, once rotated, bends the course only gradually.

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
const XK_TAB: i32 = 0xFF09;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_KEY_REPEAT: i32 = 1 << 1;

const KEY_FWD: u8 = 1 << 0;
const KEY_BACK: u8 = 1 << 1;
const KEY_TURN_L: u8 = 1 << 2;
const KEY_TURN_R: u8 = 1 << 3;
const KEY_STRAFE_L: u8 = 1 << 4;
const KEY_STRAFE_R: u8 = 1 << 5;
const KEY_LOOK_UP: u8 = 1 << 6;
const KEY_LOOK_DOWN: u8 = 1 << 7;
const KEYS_HELM: u8 = KEY_FWD | KEY_BACK | KEY_TURN_L | KEY_TURN_R | KEY_STRAFE_L | KEY_STRAFE_R;

const STEP_MS: i64 = 16;
const STEP: i32 = 16;
const DT: f32 = 0.016;
const MAX_STEPS_PER_UPDATE: i32 = 8;

// World units are metres. In the bay +x is east and +y is north. In the
// craft's own frame +x is the bow, +y is the port (left) side, and z = 0 is
// the cabin floor.

// The craft is 40 m long and 18 m wide. The cabin floor rides 1.8 m above
// the water on a full cushion and 1.0 m when the skirt is down.
const CRAFT_HALF_L: f32 = 20.0;
const CRAFT_HALF_W: f32 = 9.0;
const DECK_SETTLED: f32 = 1.0;
const DECK_HOVER: f32 = 1.8;

// Handling, per unit mass. Full throttle gives 2 m/s^2 and a top speed of
// 20 m/s (39 knots) in still air. Sideways the skirt drags a little more
// than fore and aft, but not much: there are no tyres. The linear terms are
// the skirt on the water and go with the craft's speed over it; the square
// ones are the air on the hull and go with its speed through the air, so the
// wind blows the craft about. Broadside on, the hull shows the air more than
// twice the area it does end on.
const A_THRUST: f32 = 2.0;
const REVERSE_MAX: f32 = 0.4;
const DRAG_U_LIN: f32 = 0.03;
const DRAG_U_QUAD: f32 = 0.0035;
const DRAG_V_LIN: f32 = 0.1;
const DRAG_V_QUAD: f32 = 0.008;
// Yaw from the rudders grows with the air across them: the propellers'
// wash, which reverse pitch mostly blows away from them, and a little from
// the craft's own speed.
const RUDDER_YAW: f32 = 0.55;
const RAM_AIR: f32 = 0.025;
const REVERSE_WASH: f32 = 0.15;
// The rudders turn the wash sideways, so the craft first skids out of a turn.
const RUDDER_SIDE: f32 = 0.12;
const YAW_DAMP_LIN: f32 = 0.9;
const YAW_DAMP_QUAD: f32 = 0.6;
// The fins and rudders at the stern swing the bow toward the direction of
// travel through the air, as a weathervane does: stopped, into the wind.
const WEATHERCOCK: f32 = 0.0012;
// With the cushion gone the skirt drags on the surface.
const SKIRT_FRICTION: f32 = 2.5;
const MUD_DRAG: f32 = 0.08;
const GRAVITY: f32 = 9.81;
const LIFT_RATE: f32 = 0.35;
const THROTTLE_RATE: f32 = 0.5;
const RUDDER_RATE: f32 = 2.5;
const RUDDER_RETURN: f32 = 3.0;
const YAW_INERTIA: f32 = (40.0 * 40.0 + 18.0 * 18.0) / 12.0;
const RESTITUTION: f32 = 0.3;
const SAFE_IMPACT: f32 = 1.5;
const DAMAGE_PER_MS: f32 = 6.0;
// The hull's plan, for collisions, as circles along the keel.
const HULL_CIRCLES = [_]f32{ -13.0, -6.5, 0.0, 6.5, 13.0 };
const HULL_R: f32 = 8.6;

// The working day runs from 09:00 to 17:00 in ten minutes of play.
const DAY_MS: i32 = 600_000;
const FIRST_HOUR: f32 = 9.0;
const DAY_HOURS: f32 = 8.0;
// Keystrokes to finish the demo, and how long the upload takes on a locked
// 64 kbit/s link.
const CODE_KEYS: u16 = 160;
const CODE_CHARS_PER_KEY: u32 = 3;
const UPLOAD_MS: i32 = 25_000;
// The dish on the roof loses the satellite when the craft yaws faster than
// it can track, or under the bridge, and takes a while to find it again.
const SAT_ACQUIRE_MS: i32 = 2500;
const SAT_MAX_YAW: f32 = 0.1;

// The summer sea breeze, in through the Golden Gate from the west-north-west.
// It is light in the morning and fills in from eleven o'clock to a steady
// 20 knots by three, gusting a fifth either way and swinging a few degrees.
const WIND_FROM_DEG: f32 = 285.0;
const WIND_FILLS = [2]f32{ 11.0, 15.0 };
const WIND_MORNING: f32 = 3.0;
const WIND_AFTERNOON: f32 = 10.0;
const WIND_GUST: f32 = 0.2;
const WIND_SWING: f32 = 0.12;

// The sun over San Francisco (37.8 N) in late June.
const SF_LATITUDE: f32 = 37.8 * std.math.pi / 180.0;
const SUN_DECLINATION: f32 = 23.0 * std.math.pi / 180.0;

const WALK_STEP: f32 = 0.06;
const TURN_STEP: f32 = 0.042;
const PLAYER_R: f32 = 0.3;
const WALK_EYE: f32 = 1.65;
const LURCH: f32 = 0.35;

const FOCAL: f32 = 340.0;
const CRT_FOCAL: f32 = 700.0;
const HALF_W: f32 = 320.0;
const BASE_HORIZON: f32 = 240.0;
const NEAR: f32 = 0.05;
const LOOK_STEP: f32 = 8.0;
const LOOK_UP_MAX: f32 = 300.0;
const LOOK_DOWN_MAX: f32 = 300.0;
const MOUSE_TURN: f32 = 0.0025;
const MOUSE_LOOK: f32 = FOCAL * MOUSE_TURN;
const HEAD_YAW_MAX: f32 = 1.3;
const CRT_LOOK: f32 = -164.0;
const HELM_LOOK: f32 = -24.0;

const MESSAGE_MS: i32 = 3000;

// The cabin, in the craft's frame. The windscreen leans back like the
// Mercedes C111's: its inner face is at x = 16 on the floor and moves aft
// 0.6 m for every metre up.
const CABIN_REAR: f32 = -13.5;
const CABIN_SIDE: f32 = 8.0;
const WALL_T: f32 = 0.4;
const CEIL: f32 = 3.0;
const ROOF: f32 = 3.3;
const SCREEN_FOOT: f32 = 16.0;
const SCREEN_LEAN: f32 = 0.6;
const CHEEK_X: f32 = 14.0;
// Cubicles run along both sides of the aisle, four to a side.
const CUBE_XS = [_]f32{ 5.5, 1.0, -3.5, -8.0 };
const CUBE_LEN: f32 = 4.5;
const AISLE: f32 = 3.0;
const PARTITION_H: f32 = 1.5;
// Your cubicle is the first on the port side, behind the helm.
const DESK_X: f32 = CUBE_XS[0] + CUBE_LEN * 0.5;
const CRT_FRONT: f32 = 7.2;
const CRT_Z0: f32 = 0.84;
// The 17 inch tube's visible area, 32.5 by 24.4 cm.
const CRT_W: f32 = 0.325;
const CRT_HT: f32 = 0.244;
const CHAIR_Y: f32 = 6.3;
const SEAT_EYE: [3]f32 = .{ DESK_X, 6.56, 1.18 };
const DESK_STAND: [2]f32 = .{ DESK_X, 5.2 };
const HELM: [2]f32 = .{ 12.0, 0.0 };
const HELM_EYE: [3]f32 = .{ 12.15, 0.0, 1.32 };
const HELM_STAND: [2]f32 = .{ 10.6, 0.0 };

// The bay. The office leaves its own pier in the south, passes under the
// bridge, and must stop in the berth beside the investors' pier in the north.
const START: [2]f32 = .{ 0.0, -40.0 };
const BRIDGE_Y: f32 = 900.0;
const BRIDGE_HALF: f32 = 12.0;
const BRIDGE_DECK: f32 = 17.0;
const BERTH: [2]f32 = .{ 1984.0, 2462.0 };
const BERTH_HALF: [2]f32 = .{ 10.0, 24.0 };
const DOCK_SPEED: f32 = 0.8;
// The autopilot's route, as a hovercraft can go: south of the rocks and the
// first reef, over the Middle Ground, through the bridge's navigation span,
// across the flats past the reefs and through the gap between two of them,
// and up to the berth along a straight final approach. It stops on the
// berth's upwind side: holding station it swings head to wind, and its
// stern must clear the pier as it turns.
const ROUTE = [_][2]f32{ .{ 0, 60 }, .{ 40, 140 }, .{ 370, 20 }, .{ 640, 250 }, .{ 900, 450 }, .{ 1100, 820 }, .{ 1130, 1000 }, .{ 1735, 1700 }, .{ 1775, 2140 }, .{ 1965, 2260 }, .{ BERTH[0] - 8, BERTH[1] } };
const AP_CRUISE: f32 = 11.0;
const AP_BRAKE: f32 = 0.3;
const AP_GAIN: f32 = 0.35;
const AP_REACH: f32 = 45.0;
// This close to the end of its route, in a breeze, it holds station.
const AP_HOLD: f32 = 30.0;

// A rival startup is pitching to the same investors, and races you there in
// a speedboat. It waits beside your pier until you leave it, or until ten
// o'clock if you haven't, then keeps to the buoyed deep-water channel:
// north of the rocks, through the navigation span, and up the east side of
// the bay, the long way round the flats, to the far side of the investors'
// pier. It cruises at 17 m/s, a little under the office's top speed, but it
// corners and stops far more sharply, so only the shallows can beat it.
const RIVAL_MOORING: [3]f32 = .{ 32, 5, std.math.pi / 2.0 };
const RIVAL_BERTH: [2]f32 = .{ 2022, 2420 };
const RIVAL_ROUTE = [_][2]f32{ .{ 30, 60 }, .{ 150, 450 }, .{ 320, 660 }, .{ 1080, 840 }, .{ 1160, 980 }, .{ 2250, 1180 }, .{ 2560, 1500 }, .{ 2580, 2200 }, .{ 2060, 2300 }, RIVAL_BERTH };
const RIVAL_LEAVES_MS: i32 = DAY_MS / 8;
const RIVAL_CRUISE: f32 = 17.0;
const RIVAL_ACCEL: f32 = 2.5;
const RIVAL_BRAKE: f32 = 3.0;
const RIVAL_TURN: f32 = 0.45;
const RIVAL_REACH: f32 = 50.0;
const RIVAL_HALF_L: f32 = 5.5;
const RIVAL_HALF_W: f32 = 1.7;
// The speedboat planes on the water and shows the air far less of itself
// for its weight than the office does. At its cruise in still air, the air
// is this share of the drag its engine works against, and it makes this
// much leeway, as a share of the wind across it.
const RIVAL_AIR: f32 = 0.15;
const RIVAL_LEEWAY: f32 = 0.04;

const MAX_GULLS: usize = 12;

const Rgb = @Vector(3, f32);
const Rgba = @Vector(4, f32);
const Color = [4]u8;

const C_HUD: Color = .{ 0x08, 0x07, 0x0A, 0xC0 };
const C_PANEL: Color = .{ 0x14, 0x12, 0x10, 0xE8 };
const C_SHADE: Color = .{ 0x06, 0x05, 0x08, 0xB0 };
const C_TEXT: Color = .{ 0xF4, 0xF0, 0xE6, 0xFF };
const C_TEXT_DIM: Color = .{ 0x9A, 0x92, 0x84, 0xFF };
const C_TEXT_SHADOW: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_TITLE: Color = .{ 0xF5, 0x7A, 0x1E, 0xFF };
const C_TITLE_ALT: Color = .{ 0xF2, 0xC2, 0x4E, 0xFF };
const C_GOOD: Color = .{ 0x6C, 0xE0, 0x7A, 0xFF };
const C_BAD: Color = .{ 0xF0, 0x50, 0x40, 0xFF };
const C_GAUGE: Color = .{ 0x40, 0x3A, 0x34, 0xFF };
const C_NEEDLE: Color = .{ 0xF5, 0x7A, 0x1E, 0xFF };
const C_VELOCITY: Color = .{ 0x6A, 0xE0, 0xFF, 0xFF };
const C_WIND: Color = .{ 0xD0, 0xF0, 0xC0, 0xFF };
const C_MAP_BG: Color = .{ 0x05, 0x10, 0x16, 0xD0 };
const C_MAP_LAND: Color = .{ 0x9A, 0x8A, 0x5A, 0xFF };
const C_MAP_SAND: Color = .{ 0x6A, 0x60, 0x44, 0xFF };
const C_MAP_ROUTE: Color = .{ 0x50, 0x70, 0x80, 0xFF };
const C_MAP_FLATS: Color = .{ 0x2A, 0x50, 0x48, 0xFF };

const Mode = enum(u8) { title, walking, cubicle, dashboard, paused, gameover };
const Outcome = enum(u8) { none, funded, late, wrecked, scooped };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var zbuf: [SCREEN_W * SCREEN_H]f32 = undefined;

var mode: Mode = .title;
var paused_from: Mode = .walking;
var outcome: Outcome = .none;
var keys_down: u8 = 0;
var pointer_down = false;
var mouse_total_x: i32 = 0;
var mouse_total_y: i32 = 0;
var mouse_used_x: i32 = 0;
var mouse_used_y: i32 = 0;
var map_on = false;
var chase_cam = false;
var rng_state: u32 = 0x5EED_1998;
var anim_ms: i32 = 0;
var time_ms: i32 = 0;
var message: []const u8 = "";
var message_ms: i32 = 0;
var shake_ms: i32 = 0;

// The craft.
var cr_x: f32 = 0;
var cr_y: f32 = 0;
var cr_h: f32 = 0;
var cr_vx: f32 = 0;
var cr_vy: f32 = 0;
var cr_r: f32 = 0;
// Its last acceleration in its own frame, which throws a walker about.
var cr_au: f32 = 0;
var cr_av: f32 = 0;
var throttle: f32 = 0;
var rudder: f32 = 0;
var lift: f32 = 0;
var lift_on = false;
var autopilot = false;
var ap_wp: usize = 0;
var hull: f32 = 100;
var sat_ms: i32 = 0;
var on_mud = false;
// Holds the wind off, for tests of the handling in still air.
var still_air = false;

// The rival's speedboat: where it is, which way it points, how fast it is
// going, and which of its route's points it is making for.
const Rival = enum(u8) { moored, racing, docked };
var rival: Rival = .moored;
var rv_x: f32 = 0;
var rv_y: f32 = 0;
var rv_h: f32 = 0;
var rv_speed: f32 = 0;
var rv_leg: usize = 0;

// The player, in the craft's frame.
var px: f32 = 0;
var py: f32 = 0;
var pangle: f32 = 0;
var pvx: f32 = 0;
var pvy: f32 = 0;
var look: f32 = 0;
var head_yaw: f32 = 0;
var bob: f32 = 0;

// The work.
var code_keys: u16 = 0;
var uploading = false;
var upload_ms: i32 = 0;
var docked = false;
var waiting_told = false;
var score: u32 = 0;
var hi_score: u32 = 0;

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

fn isPlaying(m: Mode) bool {
    return m == .walking or m == .cubicle or m == .dashboard;
}

// Turns the view only during an update, so a render sees the same view the
// update left. Walking turns the body; seated, the head turns within reach.
fn applyMouseLook() void {
    if (phase != .updating) return;
    const dx: f32 = @floatFromInt(mouse_total_x -% mouse_used_x);
    const dy: f32 = @floatFromInt(mouse_total_y -% mouse_used_y);
    mouse_used_x = mouse_total_x;
    mouse_used_y = mouse_total_y;
    if (!isPlaying(mode)) return;
    if (mode == .walking) {
        pangle = wrapAngle(pangle - dx * MOUSE_TURN);
    } else {
        head_yaw = clampf(head_yaw - dx * MOUSE_TURN, -HEAD_YAW_MAX, HEAD_YAW_MAX);
    }
    look = clampf(look - dy * MOUSE_LOOK, -LOOK_DOWN_MAX, LOOK_UP_MAX);
}

fn keyBit(x11_key: i32) u8 {
    return switch (x11_key) {
        XK_UP, 'w', 'W' => KEY_FWD,
        XK_DOWN, 's', 'S' => KEY_BACK,
        XK_LEFT => KEY_TURN_L,
        XK_RIGHT => KEY_TURN_R,
        'a', 'A' => KEY_STRAFE_L,
        'd', 'D' => KEY_STRAFE_R,
        XK_PAGE_UP => KEY_LOOK_UP,
        XK_PAGE_DOWN => KEY_LOOK_DOWN,
        else => 0,
    };
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    const is_repeat = (flags & FLAG_KEY_REPEAT) != 0;

    const bit = keyBit(x11_key);
    const was_down = (keys_down & bit) != 0;
    if (bit != 0) {
        if (is_down) keys_down |= bit else keys_down &= ~bit;
    }
    if (!is_down) return if (bit != 0 and was_down) 1 else 0;

    switch (mode) {
        .title, .gameover => {
            if (x11_key == ' ' or x11_key == XK_ENTER) {
                startGame(begun_at_ms);
                return 1;
            }
            return 0;
        },
        .paused => switch (x11_key) {
            'p', 'P', XK_ESCAPE, XK_ENTER => {
                resume_();
                return 1;
            },
            'r', 'R' => {
                startGame(begun_at_ms);
                return 1;
            },
            else => return 0,
        },
        // At the keyboard every printable key is code, but holding one down
        // writes nothing more. Tab stands up.
        .cubicle => switch (x11_key) {
            XK_ESCAPE => return pause(),
            XK_TAB => {
                standUp();
                return 1;
            },
            XK_ENTER => {
                startUpload();
                return 1;
            },
            0x21...0x7E => {
                if (is_repeat) return 0;
                typeKey();
                return 1;
            },
            else => return 0,
        },
        .walking => switch (x11_key) {
            'p', 'P', XK_ESCAPE => return pause(),
            'e', 'E', XK_ENTER => {
                interact();
                return 1;
            },
            'm', 'M' => {
                map_on = !map_on;
                return 1;
            },
            else => return if (bit != 0 and !was_down) 1 else 0,
        },
        .dashboard => {
            // Taking the controls disengages the autopilot.
            if ((bit & KEYS_HELM) != 0 and autopilot) {
                autopilot = false;
                showMessage("AUTOPILOT OFF");
            }
            switch (x11_key) {
                'p', 'P', XK_ESCAPE => return pause(),
                'e', 'E', XK_TAB => {
                    standUp();
                    return 1;
                },
                'l', 'L' => {
                    lift_on = !lift_on;
                    showMessage(if (lift_on) "LIFT FANS ON" else "LIFT FANS OFF");
                    return 1;
                },
                't', 'T' => {
                    setAutopilot(!autopilot);
                    return 1;
                },
                'c', 'C' => {
                    chase_cam = !chase_cam;
                    return 1;
                },
                'x', 'X' => {
                    throttle = 0;
                    return 1;
                },
                'm', 'M' => {
                    map_on = !map_on;
                    return 1;
                },
                'r', 'R' => {
                    setRadarRange(@intCast((radar_range + 1) % RADAR_RANGES.len));
                    return 1;
                },
                else => return if (bit != 0 and !was_down) 1 else 0,
            }
        },
    }
}

export fn pointer_event(button_mask: i32, _: i32, _: i32) i32 {
    requireEventPhase();
    advanceUpdateTime();
    const down = (button_mask & 1) != 0;
    const was_down = pointer_down;
    pointer_down = down;
    if (!down or was_down) return 0;
    if (mode == .title) {
        startGame(begun_at_ms);
        return 1;
    }
    return 0;
}

fn requireEventPhase() void {
    if (phase != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (!isPlaying(mode)) return;

    var elapsed = begun_at_ms - last_step_ms;
    var steps: i32 = 0;
    while (elapsed >= STEP_MS and steps < MAX_STEPS_PER_UPDATE and isPlaying(mode)) : (steps += 1) {
        stepGame();
        last_step_ms += STEP_MS;
        elapsed -= STEP_MS;
    }
    // Bound work after a long host pause by dropping the remaining backlog.
    if (isPlaying(mode) and elapsed >= STEP_MS) last_step_ms = begun_at_ms;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    const wake = if (isPlaying(mode)) last_step_ms +| STEP_MS else begun_at_ms;
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

// Benchmark hooks. A host picks one of the fixed views below and times
// `render`. Flag 2 replaces textures and lighting with one flat colour per
// surface; flag 4 draws every polygon into a depth buffer in the order it was
// built, without the BSP, as a reference. The view stays until it is set back
// to -1. Neither hook changes the game.

// A craft placement (x, y, heading) and an eye, either in the craft's frame
// or in the bay's.
const View = struct { craft: [3]f32, local: bool, eye: [3]f32, angle: f32, look: f32, focal: f32 };
const BENCH_VIEWS = [_]View{
    // Walking up the aisle toward the helm.
    .{ .craft = .{ START[0], START[1], std.math.pi / 2.0 }, .local = true, .eye = .{ -11, 0, WALK_EYE }, .angle = 0, .look = -10, .focal = FOCAL },
    // At the desk, in front of the CRT.
    .{ .craft = .{ START[0], START[1], std.math.pi / 2.0 }, .local = true, .eye = SEAT_EYE, .angle = std.math.pi / 2.0, .look = CRT_LOOK, .focal = CRT_FOCAL },
    // At the helm, out through the windscreen toward the bridge.
    .{ .craft = .{ 600, 300, 0.9 }, .local = true, .eye = HELM_EYE, .angle = 0, .look = HELM_LOOK, .focal = FOCAL },
    // Behind the craft as it heads for the bridge.
    .{ .craft = .{ 1100, 700, std.math.pi / 2.0 }, .local = false, .eye = .{ 1100, 645, 24 }, .angle = std.math.pi / 2.0, .look = -120, .focal = FOCAL },
    // From the investors' pier, looking down the bay at the craft coming in.
    .{ .craft = .{ BERTH[0], BERTH[1] - 130, std.math.pi / 2.0 }, .local = false, .eye = .{ 2010, 2400, 7 }, .angle = -1.95, .look = -40, .focal = FOCAL },
    // Behind the craft running along the north shore toward the berth.
    .{ .craft = .{ 1720, 2630, 0.15 }, .local = false, .eye = .{ 1660, 2600, 14 }, .angle = 0.55, .look = -50, .focal = FOCAL },
    // Behind the craft crossing the flats toward the gap between two reefs.
    .{ .craft = .{ 1700, 1830, 1.45 }, .local = false, .eye = .{ 1690, 1770, 14 }, .angle = 1.42, .look = -50, .focal = FOCAL },
};

var bench_view: i32 = -1;
var flat_shading = false;
var reference_render = false;
const BENCH_FLAT: i32 = 2;
const BENCH_REFERENCE: i32 = 4;

export fn bench_set_view(view: i32, flags: i32) i32 {
    if (phase == .initializing) {
        resetGame();
        phase = .ready;
    }
    flat_shading = false;
    reference_render = false;
    if (view < 0 or view >= BENCH_VIEWS.len) {
        bench_view = -1;
        return 0;
    }
    bench_view = view;
    flat_shading = (flags & BENCH_FLAT) != 0;
    reference_render = (flags & BENCH_REFERENCE) != 0;
    return 1;
}

// Work counts: polygons drawn and BSP nodes entered in the last frame, then
// the sizes and depths of the two trees.
export fn bench_stat(which: i32) u32 {
    return switch (which) {
        0 => stat_polys,
        1 => stat_nodes,
        2 => @intCast(craft_tree.polys),
        3 => @intCast(world_tree.polys),
        4 => @intCast(bnode_count),
        5 => @intCast(@max(craft_tree.depth, world_tree.depth)),
        else => 0,
    };
}

// Small maths

// Clamps without the libm calls that @min and @max on floats compile to;
// NaN clamps to lo.
inline fn clampf(v: f32, lo: f32, hi: f32) f32 {
    if (v > hi) return hi;
    if (v >= lo) return v;
    return lo;
}

inline fn minf(a: f32, b: f32) f32 {
    return if (b < a) b else a;
}

inline fn maxf(a: f32, b: f32) f32 {
    return if (b > a) b else a;
}

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn approach(v: f32, target: f32, step: f32) f32 {
    if (v < target) return minf(target, v + step);
    return maxf(target, v - step);
}

fn wrapAngle(a: f32) f32 {
    return a - 2.0 * std.math.pi * @round(a / (2.0 * std.math.pi));
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn rngFloat(lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * @as(f32, @floatFromInt(rngNext() & 0xFFFF)) / 65535.0;
}

// From the craft's frame to the bay's, and back.
fn toWorld(lx: f32, ly: f32) [2]f32 {
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    return .{ cr_x + lx * c - ly * s, cr_y + lx * s + ly * c };
}

fn toLocal(wx: f32, wy: f32) [2]f32 {
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    const dx = wx - cr_x;
    const dy = wy - cr_y;
    return .{ dx * c + dy * s, -dx * s + dy * c };
}

fn deckZ() f32 {
    return lerp(DECK_SETTLED, DECK_HOVER, lift) + craftGround();
}

fn crSpeed() f32 {
    return @sqrt(cr_vx * cr_vx + cr_vy * cr_vy);
}

// Game state

fn resetGame() void {
    buildLevel();
    mode = .title;
    outcome = .none;
    time_ms = 0;
    anim_ms = 0;
    message = "";
    message_ms = 0;
    shake_ms = 0;
    cr_x = START[0];
    cr_y = START[1];
    cr_h = std.math.pi / 2.0;
    chase_h = cr_h;
    cr_vx = 0;
    cr_vy = 0;
    cr_r = 0;
    cr_au = 0;
    cr_av = 0;
    throttle = 0;
    rudder = 0;
    lift = 0;
    lift_on = false;
    autopilot = false;
    ap_wp = 0;
    hull = 100;
    sat_ms = SAT_ACQUIRE_MS;
    on_mud = false;
    still_air = false;
    craft_wake.len = 0;
    rival_wake.len = 0;
    rival = .moored;
    rv_x = RIVAL_MOORING[0];
    rv_y = RIVAL_MOORING[1];
    rv_h = RIVAL_MOORING[2];
    rv_speed = 0;
    rv_leg = 0;
    resetRadar();
    chase_cam = false;
    map_on = false;
    code_keys = 0;
    uploading = false;
    upload_ms = 0;
    docked = false;
    waiting_told = false;
    score = 0;
    placeAtDesk();
    resetGulls();
}

fn startGame(at_ms: i64) void {
    rng_state ^= @truncate(@as(u64, @bitCast(at_ms)) *% 0x9E3779B97F4A7C15);
    if (rng_state == 0) rng_state = 0x5EED_1998;
    resetGame();
    mode = .cubicle;
    showMessage("YOU HAVE NEW MAIL");
    last_step_ms = at_ms;
}

fn pause() i32 {
    paused_from = mode;
    mode = .paused;
    return 1;
}

fn resume_() void {
    mode = paused_from;
    last_step_ms = begun_at_ms;
}

fn showMessage(text: []const u8) void {
    message = text;
    message_ms = MESSAGE_MS;
}

fn stepGame() void {
    anim_ms +%= STEP;
    time_ms +|= STEP;
    if (message_ms > 0) message_ms -= STEP;
    if (shake_ms > 0) shake_ms -= STEP;
    chase_h = wrapAngle(chase_h + wrapAngle(cr_h - chase_h) * 0.03);

    lift = approach(lift, if (lift_on) 1.0 else 0.0, LIFT_RATE * DT);
    if (autopilot) {
        runAutopilot();
    } else if (mode == .dashboard) {
        helmControls();
    } else {
        // Nobody at the helm: the rudders centre and the throttle stays put.
        rudder = approach(rudder, 0, RUDDER_RETURN * DT);
    }
    stepCraft();
    stepRival();
    collideCraft();
    stepRadar();
    recordWakes();
    updateSatellite();
    updatePlayer();
    updateGulls();
    updateObjectives();
}

fn helmControls() void {
    if ((keys_down & KEY_FWD) != 0) throttle += THROTTLE_RATE * DT;
    if ((keys_down & KEY_BACK) != 0) throttle -= THROTTLE_RATE * DT;
    throttle = clampf(throttle, -REVERSE_MAX, 1.0);
    var steer: f32 = 0;
    if ((keys_down & (KEY_TURN_R | KEY_STRAFE_R)) != 0) steer += 1;
    if ((keys_down & (KEY_TURN_L | KEY_STRAFE_L)) != 0) steer -= 1;
    rudder = if (steer != 0) approach(rudder, steer, RUDDER_RATE * DT) else approach(rudder, 0, RUDDER_RETURN * DT);
}

// The wind

// The sea breeze's mean speed, with no gusts in it, from the clock.
fn windMean() f32 {
    if (still_air) return 0;
    const t = clampf((hourNow() - WIND_FILLS[0]) / (WIND_FILLS[1] - WIND_FILLS[0]), 0, 1);
    return lerp(WIND_MORNING, WIND_AFTERNOON, t * t * (3.0 - 2.0 * t));
}

// The air's velocity over the bay, east and north. The gusts and swings are
// a few slow waves out of step, the same everywhere on the bay.
fn wind() [2]f32 {
    const mean = windMean();
    if (mean <= 0) return .{ 0, 0 };
    const t = @as(f32, @floatFromInt(time_ms)) * 0.001;
    const gust = 0.5 * @sin(t * 0.23) + 0.3 * @sin(t * 0.61 + 1.3) + 0.2 * @sin(t * 1.7 + 0.4);
    const swing = 0.6 * @sin(t * 0.11 + 2.0) + 0.4 * @sin(t * 0.37);
    const speed = mean * (1.0 + WIND_GUST * gust);
    // Away from the compass bearing it comes from.
    const b = WIND_FROM_DEG * std.math.pi / 180.0 + WIND_SWING * swing;
    return .{ -@sin(b) * speed, -@cos(b) * speed };
}

// The craft's air drag less what it would be in still air, in the bay's
// frame: the push of the wind alone, which the autopilot leans against.
fn windPush() [2]f32 {
    const w = wind();
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    const u = cr_vx * c + cr_vy * s;
    const v = -cr_vx * s + cr_vy * c;
    const ua = u - (w[0] * c + w[1] * s);
    const va = v - (-w[0] * s + w[1] * c);
    const pu = DRAG_U_QUAD * (@abs(u) * u - @abs(ua) * ua);
    const pv = DRAG_V_QUAD * (@abs(v) * v - @abs(va) * va);
    return .{ pu * c - pv * s, pu * s + pv * c };
}

// The hovercraft

// One step of the craft's motion in its own frame: u forward, v to port.
// Positive rudder steers to starboard (clockwise from above).
fn stepCraft() void {
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    var u = cr_vx * c + cr_vy * s;
    var v = -cr_vx * s + cr_vy * c;
    // The craft's way through the air, which the wind adds to or takes from.
    const w = wind();
    const ua = u - (w[0] * c + w[1] * s);
    const va = v - (-w[0] * s + w[1] * c);
    const ground = groundAt(cr_x, cr_y);
    const mud: f32 = if (onMud(cr_x, cr_y)) MUD_DRAG else ground.drag;
    on_mud = mud > 0;
    // On a beach the craft slides back down unless the thrust holds it.
    const gu = -GRAVITY * (ground.gx * c + ground.gy * s);
    const gv = -GRAVITY * (-ground.gx * s + ground.gy * c);

    const wash = maxf(throttle, 0) + REVERSE_WASH * maxf(-throttle, 0);
    const air = wash + RAM_AIR * @abs(ua);
    const airspeed = @sqrt(ua * ua + va * va);
    const au = throttle * A_THRUST + gu - (DRAG_U_LIN + mud) * u - DRAG_U_QUAD * @abs(ua) * ua;
    const av = rudder * maxf(throttle, 0) * A_THRUST * RUDDER_SIDE + gv - (DRAG_V_LIN + mud) * v - DRAG_V_QUAD * @abs(va) * va;
    const ar = -rudder * RUDDER_YAW * air + WEATHERCOCK * va * airspeed - (YAW_DAMP_LIN + YAW_DAMP_QUAD * @abs(cr_r)) * cr_r;
    const u_was = u;
    const v_was = v;
    u += au * DT;
    v += av * DT;
    cr_r += ar * DT;

    // As the cushion goes the skirt drags on the water and stops the craft.
    const settle = 1.0 - clampf((lift - 0.3) / 0.6, 0.0, 1.0);
    if (settle > 0) {
        const dec = settle * SKIRT_FRICTION * DT;
        const sp = @sqrt(u * u + v * v);
        if (sp <= dec) {
            u = 0;
            v = 0;
        } else {
            u -= u / sp * dec;
            v -= v / sp * dec;
        }
        const rdec = settle * 0.6 * DT;
        cr_r = if (@abs(cr_r) <= rdec) 0 else cr_r - std.math.sign(cr_r) * rdec;
    }
    cr_au = (u - u_was) / DT;
    cr_av = (v - v_was) / DT;
    cr_vx = u * c - v * s;
    cr_vy = u * s + v * c;
    cr_x += cr_vx * DT;
    cr_y += cr_vy * DT;
    cr_h = wrapAngle(cr_h + cr_r * DT);
}

const Contact = struct { nx: f32, ny: f32, depth: f32 };

// Where a circle overlaps a convex obstacle, the way out and how far.
fn obstacleContact(o: Obstacle, x: f32, y: f32, r: f32) ?Contact {
    if (o.n == 0) {
        const dx = x - o.cx;
        const dy = y - o.cy;
        const d = @sqrt(dx * dx + dy * dy);
        if (d >= o.r + r) return null;
        if (d < 1e-4) return .{ .nx = 1, .ny = 0, .depth = o.r + r };
        return .{ .nx = dx / d, .ny = dy / d, .depth = o.r + r - d };
    }
    const pts = obs_verts[o.first .. o.first + o.n];
    var inside = true;
    var best_d: f32 = -std.math.inf(f32);
    var best_n: [2]f32 = .{ 1, 0 };
    var near_d2: f32 = std.math.inf(f32);
    var closest: [2]f32 = .{ 0, 0 };
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        const len = @sqrt(ex * ex + ey * ey);
        const nx = ey / len;
        const ny = -ex / len;
        const d = nx * (x - a[0]) + ny * (y - a[1]);
        if (d > 0) inside = false;
        if (d > best_d) {
            best_d = d;
            best_n = .{ nx, ny };
        }
        const t = clampf(((x - a[0]) * ex + (y - a[1]) * ey) / (len * len), 0.0, 1.0);
        const cx = a[0] + ex * t;
        const cy = a[1] + ey * t;
        const d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy);
        if (d2 < near_d2) {
            near_d2 = d2;
            closest = .{ cx, cy };
        }
    }
    if (inside) return .{ .nx = best_n[0], .ny = best_n[1], .depth = r - best_d };
    const d = @sqrt(near_d2);
    if (d >= r) return null;
    return .{ .nx = (x - closest[0]) / d, .ny = (y - closest[1]) / d, .depth = r - d };
}

// Pushes the hull out of whatever it hit and bounces it off, spinning it
// about its centre if the blow was off centre. Hard knocks dent the hull.
// The rival's speedboat counts too, as two circles along its keel, but it
// holds its course whatever hits it.
fn collideCraft() void {
    var worst: f32 = 0;
    for (obstacles[0..obstacle_count]) |o| worst = maxf(worst, bump(o, 0, 0));
    const rc = @cos(rv_h);
    const rs = @sin(rv_h);
    const rv = rivalVelocity();
    for ([_]f32{ -2.6, 2.6 }) |lx| {
        const o: Obstacle = .{ .cx = rv_x + rc * lx, .cy = rv_y + rs * lx, .r = 2.9 };
        worst = maxf(worst, bump(o, rv[0], rv[1]));
    }
    if (worst > SAFE_IMPACT) {
        hull = maxf(0, hull - (worst - SAFE_IMPACT) * DAMAGE_PER_MS);
        shake_ms = 500;
        showMessage(if (hull > 0) "CRUNCH" else "THE HULL IS BREACHED");
    } else if (worst > 0.3) {
        shake_ms = @max(shake_ms, 200);
    }
}

// One obstacle against the hull, which may itself be moving at (ovx, ovy).
// Returns how fast the worst of its blows closed.
fn bump(o: Obstacle, ovx: f32, ovy: f32) f32 {
    const dx = o.cx - cr_x;
    const dy = o.cy - cr_y;
    const reach = o.r + CRAFT_HALF_L + 2.0;
    if (dx * dx + dy * dy > reach * reach) return 0;
    var worst: f32 = 0;
    for (HULL_CIRCLES) |lx| {
        const p = toWorld(lx, 0);
        const ct = obstacleContact(o, p[0], p[1], HULL_R) orelse continue;
        cr_x += ct.nx * ct.depth;
        cr_y += ct.ny * ct.depth;
        // The point of contact relative to the centre.
        const rx = p[0] - ct.nx * HULL_R + ct.nx * ct.depth - cr_x;
        const ry = p[1] - ct.ny * HULL_R + ct.ny * ct.depth - cr_y;
        const vpx = cr_vx - cr_r * ry - ovx;
        const vpy = cr_vy + cr_r * rx - ovy;
        const vn = vpx * ct.nx + vpy * ct.ny;
        if (vn >= 0) continue;
        const rn = rx * ct.ny - ry * ct.nx;
        const j = -(1.0 + RESTITUTION) * vn / (1.0 + rn * rn / YAW_INERTIA);
        cr_vx += j * ct.nx;
        cr_vy += j * ct.ny;
        cr_r += rn * j / YAW_INERTIA;
        // Scraping along slows the craft too.
        cr_vx *= 0.97;
        cr_vy *= 0.97;
        const lc = toLocalDir(ct.nx, ct.ny);
        cr_au += lc[0] * j / DT;
        cr_av += lc[1] * j / DT;
        worst = maxf(worst, -vn);
    }
    return worst;
}

fn toLocalDir(x: f32, y: f32) [2]f32 {
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    return .{ x * c + y * s, -x * s + y * c };
}

fn underBridge() bool {
    return @abs(cr_y - BRIDGE_Y) < BRIDGE_HALF + 4.0;
}

fn satLocked() bool {
    return sat_ms >= SAT_ACQUIRE_MS;
}

fn uploaded() bool {
    return upload_ms >= UPLOAD_MS;
}

fn updateSatellite() void {
    const ok = @abs(cr_r) < SAT_MAX_YAW and !underBridge();
    sat_ms = if (ok) @min(sat_ms + STEP, SAT_ACQUIRE_MS) else 0;
    if (uploading and satLocked()) {
        upload_ms += STEP;
        if (uploaded()) {
            uploading = false;
            showMessage("DEMO UPLOADED - NOW DOCK AT SAND HILL PIER");
        }
    }
}

fn inBerth() bool {
    return @abs(cr_x - BERTH[0]) < BERTH_HALF[0] and @abs(cr_y - BERTH[1]) < BERTH_HALF[1];
}

fn updateObjectives() void {
    docked = inBerth() and crSpeed() < DOCK_SPEED;
    if (docked) {
        if (uploaded()) {
            endGame(.funded);
            return;
        }
        if (!waiting_told) {
            waiting_told = true;
            showMessage("THE INVESTORS WANT THE DEMO UPLOADED");
        }
    } else if (!inBerth()) {
        waiting_told = false;
    }
    if (hull <= 0) {
        endGame(.wrecked);
        return;
    }
    if (rival == .docked) {
        endGame(.scooped);
        return;
    }
    if (time_ms >= DAY_MS) endGame(.late);
}

fn endGame(o: Outcome) void {
    outcome = o;
    mode = .gameover;
    autopilot = false;
    if (o == .funded) {
        const left: u32 = @intCast(@max(0, @divTrunc(DAY_MS - time_ms, 100)));
        score = 5000 + left + @as(u32, @intFromFloat(hull)) * 30;
    } else {
        score = @as(u32, code_keys) * 10 + @as(u32, @intCast(@divTrunc(@min(upload_ms, UPLOAD_MS), 100)));
    }
    hi_score = @max(hi_score, score);
}

// The autopilot

fn setAutopilot(on: bool) void {
    autopilot = on;
    if (!on) {
        showMessage("AUTOPILOT OFF");
        return;
    }
    // Rejoin the route at the nearest leg ahead.
    var best: usize = 0;
    var best_d: f32 = std.math.inf(f32);
    for (ROUTE, 0..) |p, i| {
        const d = (p[0] - cr_x) * (p[0] - cr_x) + (p[1] - cr_y) * (p[1] - cr_y);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    if (best + 1 < ROUTE.len) {
        const a = ROUTE[best];
        const b = ROUTE[best + 1];
        if ((cr_x - a[0]) * (b[0] - a[0]) + (cr_y - a[1]) * (b[1] - a[1]) > 0) best += 1;
    }
    ap_wp = best;
    showMessage("AUTOPILOT ON - SAND HILL PIER");
}

fn runAutopilot() void {
    flyRoute(&ROUTE, AP_CRUISE, AP_BRAKE);
}

// Flies the route as a hovercraft pilot would. It works out the
// acceleration that would turn the craft's velocity into the one it wants,
// then points the thrust that way: the bow if it can, the stern with reverse
// pitch if that is nearer. It slows early for corners and the berth, since
// stopping means turning the thrust against the momentum, and keeps some
// throttle on while it turns so the rudders have air.
fn flyRoute(route: []const [2]f32, cruise: f32, brake: f32) void {
    lift_on = true;
    if (lift < 0.85) {
        throttle = approach(throttle, 0, 0.8 * DT);
        rudder = approach(rudder, 0, RUDDER_RETURN * DT);
        return;
    }
    var dx = route[ap_wp][0] - cr_x;
    var dy = route[ap_wp][1] - cr_y;
    var dist = @sqrt(dx * dx + dy * dy);
    while (ap_wp + 1 < route.len and dist < AP_REACH) {
        ap_wp += 1;
        dx = route[ap_wp][0] - cr_x;
        dy = route[ap_wp][1] - cr_y;
        dist = @sqrt(dx * dx + dy * dy);
    }
    var vdes: f32 = cruise;
    if (ap_wp + 1 == route.len) {
        vdes = minf(vdes, @sqrt(2.0 * brake * maxf(dist - 2.0, 0)));
    } else {
        const nx = route[ap_wp + 1][0] - route[ap_wp][0];
        const ny = route[ap_wp + 1][1] - route[ap_wp][1];
        const cosang = (dx * nx + dy * ny) / maxf(dist * @sqrt(nx * nx + ny * ny), 1e-3);
        // Slow for a sharp corner: the momentum has to be turned too.
        const ease = (cosang + 1.0) * 0.5;
        const v_corner = lerp(3.0, cruise, ease * ease * ease);
        vdes = minf(vdes, @sqrt(v_corner * v_corner + 2.0 * brake * maxf(dist - AP_REACH, 0)));
    }
    const k = if (dist > 0.01) vdes / dist else 0;
    const speed = crSpeed();
    const drag = DRAG_U_LIN + DRAG_U_QUAD * speed;
    // It leans into the wind as well, so crosswinds don't set it off the route.
    const push = windPush();
    const ax = AP_GAIN * (dx * k - cr_vx) + drag * cr_vx - push[0];
    const ay = AP_GAIN * (dy * k - cr_vy) + drag * cr_vy - push[1];
    const amag = @sqrt(ax * ax + ay * ay);

    var want_h = cr_h;
    var want_t: f32 = 0;
    if (amag > 0.03) {
        const at = std.math.atan2(ay, ax);
        const err_f = wrapAngle(at - cr_h);
        if (@abs(err_f) <= 2.2) {
            want_h = at;
            want_t = clampf(amag / A_THRUST, 0, 1) * maxf(0, @cos(err_f));
        } else {
            want_h = wrapAngle(at + std.math.pi);
            want_t = -clampf(amag / A_THRUST, 0, REVERSE_MAX) * maxf(0, @cos(wrapAngle(want_h - cr_h)));
        }
    }
    // Coming in to stop in a breeze it turns head to wind, as a hovercraft
    // pilot docks, where the fins hold it anyway. It keeps the bow within
    // about 35 degrees of the wind and works the pitch fore and aft, so it
    // brakes and edges across by angling off the wind. Swinging the thrust
    // round as above would sweep the stern about the berth.
    const w = wind();
    const wsp = @sqrt(w[0] * w[0] + w[1] * w[1]);
    if (ap_wp + 1 == route.len and dist < AP_HOLD and wsp > 2.0) {
        const up = std.math.atan2(-w[1], -w[0]);
        const along = ax * @cos(up) + ay * @sin(up);
        const across = -ax * @sin(up) + ay * @cos(up);
        const off = clampf(std.math.atan2(across, @abs(along)), -0.6, 0.6);
        want_h = wrapAngle(up + if (along >= 0) off else -off);
        want_t = clampf((ax * @cos(want_h) + ay * @sin(want_h)) / A_THRUST, -REVERSE_MAX, 1);
    }
    const err = wrapAngle(want_h - cr_h);
    if (want_t >= 0 and @abs(err) > 0.15) want_t = maxf(want_t, minf(0.3, @abs(err) * 0.35));
    const turn = 2.2 * err - 1.8 * cr_r;
    throttle = approach(throttle, want_t, 0.8 * DT);
    rudder = approach(rudder, clampf(-turn, -1, 1), RUDDER_RATE * DT);
}

// The rival

// The speedboat's flat-out speed in the wind along its heading, positive
// astern. Its engine's push, which makes RIVAL_CRUISE in still air, balances
// the water's drag on the hull and the air's on what stands above it, each
// going with the square of the speed through it.
fn rivalCruise(along: f32) f32 {
    const a = RIVAL_AIR * along;
    return a + @sqrt(maxf(a * a - RIVAL_AIR * along * along + RIVAL_CRUISE * RIVAL_CRUISE, 0));
}

// The speedboat's velocity over the bay: ahead at its speed through the
// water, and sideways with the leeway the wind gives it.
fn rivalVelocity() [2]f32 {
    const c = @cos(rv_h);
    const s = @sin(rv_h);
    var vx = c * rv_speed;
    var vy = s * rv_speed;
    if (rival == .racing) {
        const w = wind();
        const across = (-w[0] * s + w[1] * c) * RIVAL_LEEWAY;
        vx -= s * across;
        vy += c * across;
    }
    return .{ vx, vy };
}

// Drives the speedboat down its channel. It steers for each point of its
// route in turn, turning no faster than RIVAL_TURN, and slows for sharp
// corners and to come alongside the pier. A headwind slows it a little, a
// following wind speeds it a little, and its leeway is steered out as it
// makes for each point.
fn stepRival() void {
    switch (rival) {
        .docked => return,
        .moored => {
            const dx = cr_x - START[0];
            const dy = cr_y - START[1];
            if (time_ms < RIVAL_LEAVES_MS and dx * dx + dy * dy < 60 * 60) return;
            rival = .racing;
            showMessage("THE RIVAL SPEEDBOAT IS AWAY");
        },
        .racing => {},
    }
    var dx = RIVAL_ROUTE[rv_leg][0] - rv_x;
    var dy = RIVAL_ROUTE[rv_leg][1] - rv_y;
    var dist = @sqrt(dx * dx + dy * dy);
    while (rv_leg + 1 < RIVAL_ROUTE.len and dist < RIVAL_REACH) {
        rv_leg += 1;
        dx = RIVAL_ROUTE[rv_leg][0] - rv_x;
        dy = RIVAL_ROUTE[rv_leg][1] - rv_y;
        dist = @sqrt(dx * dx + dy * dy);
    }
    const w = wind();
    const cruise = rivalCruise(w[0] * @cos(rv_h) + w[1] * @sin(rv_h));
    var vdes: f32 = cruise;
    if (rv_leg + 1 == RIVAL_ROUTE.len) {
        if (dist < 3.0) {
            rival = .docked;
            rv_speed = 0;
            return;
        }
        vdes = minf(vdes, @sqrt(2.0 * RIVAL_BRAKE * maxf(dist - 2.0, 0)) + 1.0);
    } else {
        const nx = RIVAL_ROUTE[rv_leg + 1][0] - RIVAL_ROUTE[rv_leg][0];
        const ny = RIVAL_ROUTE[rv_leg + 1][1] - RIVAL_ROUTE[rv_leg][1];
        const cosang = (dx * nx + dy * ny) / maxf(dist * @sqrt(nx * nx + ny * ny), 1e-3);
        const ease = (cosang + 1.0) * 0.5;
        const v_corner = lerp(7.0, cruise, ease * ease);
        vdes = minf(vdes, @sqrt(v_corner * v_corner + 2.0 * RIVAL_BRAKE * maxf(dist - RIVAL_REACH, 0)));
    }
    rv_speed = if (rv_speed < vdes) minf(vdes, rv_speed + RIVAL_ACCEL * DT) else maxf(vdes, rv_speed - RIVAL_BRAKE * DT);
    const err = wrapAngle(std.math.atan2(dy, dx) - rv_h);
    rv_h = wrapAngle(rv_h + clampf(err * 1.5, -RIVAL_TURN, RIVAL_TURN) * DT);
    const v = rivalVelocity();
    rv_x += v[0] * DT;
    rv_y += v[1] * DT;
}

// How far the speedboat still has to go along its route.
fn rivalToGo() f32 {
    if (rival == .docked) return 0;
    var d = @sqrt((RIVAL_ROUTE[rv_leg][0] - rv_x) * (RIVAL_ROUTE[rv_leg][0] - rv_x) + (RIVAL_ROUTE[rv_leg][1] - rv_y) * (RIVAL_ROUTE[rv_leg][1] - rv_y));
    var i = rv_leg;
    while (i + 1 < RIVAL_ROUTE.len) : (i += 1) {
        const ex = RIVAL_ROUTE[i + 1][0] - RIVAL_ROUTE[i][0];
        const ey = RIVAL_ROUTE[i + 1][1] - RIVAL_ROUTE[i][1];
        d += @sqrt(ex * ex + ey * ey);
    }
    return d;
}

// Walking about the cabin

fn sitAtDesk() void {
    mode = .cubicle;
    placeAtDesk();
}

fn placeAtDesk() void {
    px = DESK_X;
    py = CHAIR_Y;
    pangle = std.math.pi / 2.0;
    look = 0;
    head_yaw = 0;
}

fn standUp() void {
    if (mode == .cubicle) {
        px = DESK_STAND[0];
        py = DESK_STAND[1];
        pangle = -std.math.pi / 2.0;
    } else {
        px = HELM_STAND[0];
        py = HELM_STAND[1];
        pangle = 0;
        chase_cam = false;
    }
    pvx = 0;
    pvy = 0;
    look = 0;
    head_yaw = 0;
    mode = .walking;
}

fn near(x: f32, y: f32, r: f32) bool {
    return (px - x) * (px - x) + (py - y) * (py - y) < r * r;
}

fn interact() void {
    if (near(DESK_X, CHAIR_Y, 1.4)) {
        sitAtDesk();
        return;
    }
    if (near(HELM[0], HELM[1], 1.6)) {
        mode = .dashboard;
        look = 0;
        head_yaw = 0;
        return;
    }
    for (CUBE_XS, 0..) |x0, i| {
        for ([_]f32{ 1, -1 }) |side| {
            if (i == 0 and side > 0) continue;
            if (near(x0 + CUBE_LEN * 0.5, side * CHAIR_Y, 1.4)) {
                showMessage(OTHER_DESKS[(i * 2 + @as(usize, if (side > 0) 0 else 1)) % OTHER_DESKS.len]);
                return;
            }
        }
    }
    showMessage("E AT YOUR DESK OR THE HELM");
}

const OTHER_DESKS = [_][]const u8{
    "THATS DAVES DESK",
    "PRIYAS DESK - DO NOT TOUCH",
    "THE CTO IS AT A CONFERENCE",
    "SOMEONES TAMAGOTCHI IS HUNGRY",
    "A STACK OF ZIP DISKS",
    "STOCK OPTIONS PAPERWORK",
    "A NERF GUN AND A PALM PILOT",
    "THE INTERN IS AT LUNCH",
};

fn typeKey() void {
    if (code_keys < CODE_KEYS) {
        code_keys += 1;
        if (code_keys == CODE_KEYS) showMessage("DEMO BUILT - PRESS ENTER TO UPLOAD");
    }
}

fn startUpload() void {
    if (code_keys < CODE_KEYS) {
        showMessage("FINISH WRITING THE DEMO FIRST");
    } else if (uploaded()) {
        showMessage("ALREADY UPLOADED");
    } else if (!uploading) {
        uploading = true;
        showMessage("UPLOADING OVER THE SATELLITE LINK");
    }
}

fn updatePlayer() void {
    if (mode != .walking) {
        if ((keys_down & KEY_LOOK_UP) != 0) look = minf(LOOK_UP_MAX, look + LOOK_STEP);
        if ((keys_down & KEY_LOOK_DOWN) != 0) look = maxf(-LOOK_DOWN_MAX, look - LOOK_STEP);
        return;
    }
    var turn: f32 = 0;
    if ((keys_down & KEY_TURN_L) != 0) turn += 1;
    if ((keys_down & KEY_TURN_R) != 0) turn -= 1;
    pangle = wrapAngle(pangle + turn * TURN_STEP);
    if ((keys_down & KEY_LOOK_UP) != 0) look = minf(LOOK_UP_MAX, look + LOOK_STEP);
    if ((keys_down & KEY_LOOK_DOWN) != 0) look = maxf(-LOOK_DOWN_MAX, look - LOOK_STEP);

    const fx = @cos(pangle);
    const fy = @sin(pangle);
    var mf: f32 = 0;
    var ms: f32 = 0;
    if ((keys_down & KEY_FWD) != 0) mf += 1;
    if ((keys_down & KEY_BACK) != 0) mf -= 1;
    if ((keys_down & KEY_STRAFE_R) != 0) ms += 1;
    if ((keys_down & KEY_STRAFE_L) != 0) ms -= 1;
    var mx: f32 = 0;
    var my: f32 = 0;
    if (mf != 0 or ms != 0) {
        mx = fx * mf + fy * ms;
        my = fy * mf - fx * ms;
        const len = @sqrt(mx * mx + my * my);
        mx = mx / len * WALK_STEP;
        my = my / len * WALK_STEP;
        bob += 0.2;
    }
    // The craft's accelerations throw you the other way.
    pvx = (pvx - cr_au * LURCH * DT) * 0.9;
    pvy = (pvy - cr_av * LURCH * DT) * 0.9;
    mx += pvx * DT;
    my += pvy * DT;
    movePlayer(mx, my);
}

fn movePlayer(dx: f32, dy: f32) void {
    const steps: usize = @intFromFloat(clampf(@ceil(@sqrt(dx * dx + dy * dy) / 0.1), 1, 20));
    const sx = dx / @as(f32, @floatFromInt(steps));
    const sy = dy / @as(f32, @floatFromInt(steps));
    for (0..steps) |_| {
        px += sx;
        py += sy;
        px = clampf(px, CABIN_REAR + PLAYER_R, SCREEN_FOOT - SCREEN_LEAN * 1.0 - PLAYER_R);
        py = clampf(py, -CABIN_SIDE + PLAYER_R, CABIN_SIDE - PLAYER_R);
        for (0..2) |_| {
            for (cboxes[0..cbox_count]) |b| pushOutOfBox(b);
        }
    }
}

fn pushOutOfBox(b: [4]f32) void {
    const cx = clampf(px, b[0], b[2]);
    const cy = clampf(py, b[1], b[3]);
    const dx = px - cx;
    const dy = py - cy;
    const d2 = dx * dx + dy * dy;
    if (d2 >= PLAYER_R * PLAYER_R) return;
    if (d2 > 1e-8) {
        const d = @sqrt(d2);
        px = cx + dx / d * PLAYER_R;
        py = cy + dy / d * PLAYER_R;
        return;
    }
    // The centre is inside: leave by the nearest side.
    const left = px - b[0];
    const right = b[2] - px;
    const down = py - b[1];
    const up = b[3] - py;
    const m = minf(minf(left, right), minf(down, up));
    if (m == left) px = b[0] - PLAYER_R else if (m == right) px = b[2] + PLAYER_R else if (m == down) py = b[1] - PLAYER_R else py = b[3] + PLAYER_R;
}

// Gulls follow the craft, as they follow boats, and wheel over the piers
// and the rocks.

const Gull = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    z: f32 = 20,
    r: f32 = 30,
    ang: f32 = 0,
    spin: f32 = 1,
    follow: bool = false,
    ox: f32 = 0,
    oy: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    hx: f32 = 1,
    hy: f32 = 0,
    flap: f32 = 0,
    glide: bool = true,
    timer_ms: i32 = 0,
};

var gulls: [MAX_GULLS]Gull = [_]Gull{.{}} ** MAX_GULLS;
const GULL_SPEED: f32 = 9.0;
const GULL_SPAN: f32 = 1.3;

fn resetGulls() void {
    const haunts = [_][3]f32{ .{ 19, -60, 14 }, .{ 420, 380, 30 }, .{ 2007, 2450, 16 }, .{ 1400, 420, 26 }, .{ 1900, 1500, 40 }, .{ 1100, 900, 24 } };
    for (&gulls, 0..) |*g, i| {
        g.* = .{};
        g.follow = i < 5;
        g.ox = rngFloat(-30, 30);
        g.oy = rngFloat(-30, 30);
        if (g.follow) {
            g.cx = cr_x + g.ox;
            g.cy = cr_y + g.oy;
            g.z = rngFloat(8, 18);
        } else {
            const hp = haunts[i % haunts.len];
            g.cx = hp[0] + rngFloat(-20, 20);
            g.cy = hp[1] + rngFloat(-20, 20);
            g.z = hp[2] + rngFloat(-3, 6);
        }
        g.r = rngFloat(14, 34);
        g.ang = rngFloat(0, 2.0 * std.math.pi);
        g.spin = if (rngNext() & 1 == 0) 1 else -1;
        g.timer_ms = @intCast(rngNext() % 3000);
        placeGull(g);
    }
}

fn placeGull(g: *Gull) void {
    g.x = g.cx + g.r * @cos(g.ang);
    g.y = g.cy + g.r * @sin(g.ang);
    g.hx = -@sin(g.ang) * g.spin;
    g.hy = @cos(g.ang) * g.spin;
}

fn updateGulls() void {
    for (&gulls) |*g| {
        if (g.follow) {
            // They hang behind and above the stern.
            const b = toWorld(-30 + g.ox * 0.5, g.oy);
            g.cx += (b[0] - g.cx) * 0.02;
            g.cy += (b[1] - g.cy) * 0.02;
        }
        g.ang = wrapAngle(g.ang + g.spin * GULL_SPEED / g.r * DT);
        placeGull(g);
        g.timer_ms -= STEP;
        if (g.timer_ms <= 0) {
            g.glide = !g.glide;
            g.timer_ms = if (g.glide) @intCast(1500 + rngNext() % 3000) else @intCast(500 + rngNext() % 900);
        }
        g.flap = if (g.glide) 0 else g.flap + 0.45;
    }
}

// Level geometry
//
// Everything is built from convex polygons: the craft's in its own frame,
// the bay's in the bay's. Each polygon points at a surface, which holds its
// material and a texture frame (an origin and u and v axes), so splitting a
// polygon in the BSP keeps its texture where it was.

const Mat = enum(u8) {
    water,
    mud,
    sand,
    land,
    seawall,
    shed,
    shed_roof,
    tree,
    trunk,
    scrub,
    hills,
    rock,
    rock_top,
    concrete,
    wood,
    sign,
    bridge,
    building,
    ship,
    ship_deck,
    ship_white,
    container,
    lighthouse,
    buoy_red,
    buoy_green,
    buoy_yellow,
    speedboat,
    boat_deck,
    boat_glass,
    skin,
    hull,
    hull_band,
    hull_name,
    hull_dark,
    deck,
    skirt,
    roof,
    radome,
    duct_in,
    prop,
    rudder,
    nav_red,
    nav_green,
    frame,
    carpet,
    ceiling,
    light_panel,
    wall_in,
    partition,
    desk,
    crt_case,
    crt_mine,
    crt_saver,
    keyboard,
    chair,
    console,
    console_glow,
    whiteboard,
    rack,
    cooler,
    bottle,
    foosball,
    pizza,
};

const Surf = struct { mat: Mat, inside: bool, seed: u16, o: [3]f32, u: [3]f32, v: [3]f32 };
const Poly = struct { first: u32, n: u32, surf: u32, nx: f32, ny: f32, nz: f32, d: f32 };
const Tree = struct { root: i32 = -1, first: usize = 0, polys: usize = 0, depth: usize = 0 };

const MAX_SURFS: usize = 8192;
const MAX_POLYS: usize = 24576;
const MAX_PVERTS: usize = 131072;
const MAX_BNODES: usize = 16384;
const MAX_POLY_N: usize = 32;
const BSP_STACK: usize = 512;

var surfs: [MAX_SURFS]Surf = undefined;
var surf_count: usize = 0;
var polys: [MAX_POLYS]Poly = undefined;
var poly_count: usize = 0;
var pverts: [MAX_PVERTS][3]f32 = undefined;
var pvert_count: usize = 0;
var craft_tree: Tree = .{};
var world_tree: Tree = .{};
var level_built = false;

// Bay obstacles in plan: convex polygons wound counter-clockwise, or
// circles when n is 0.
const Obstacle = struct { cx: f32, cy: f32, r: f32, first: u32 = 0, n: u32 = 0 };
const MAX_OBSTACLES: usize = 160;
const MAX_OBS_VERTS: usize = 1024;
var obstacles: [MAX_OBSTACLES]Obstacle = undefined;
var obstacle_count: usize = 0;
var obs_verts: [MAX_OBS_VERTS][2]f32 = undefined;
var obs_vert_count: usize = 0;

// Furniture in the cabin's plan, as boxes (x0, y0, x1, y1) a walker cannot
// enter.
const MAX_CBOXES: usize = 96;
var cboxes: [MAX_CBOXES][4]f32 = undefined;
var cbox_count: usize = 0;

// The mud flats east of the route, where the skirt drags a little more.
const MUD = [_][2]f32{ .{ 2150, 80 }, .{ 2700, 80 }, .{ 2760, 400 }, .{ 2600, 650 }, .{ 2250, 620 }, .{ 2100, 300 } };

// Builders tag what they add as inside the cabin or not, and with a seed
// that varies the texture.
var cur_inside = false;
var cur_seed: u16 = 0;

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn scale3(a: [3]f32, k: f32) [3]f32 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}

fn norm3(a: [3]f32) [3]f32 {
    const l = @sqrt(dot3(a, a));
    return if (l > 0) scale3(a, 1.0 / l) else .{ 0, 0, 1 };
}

fn centroid(pts: []const [3]f32) [3]f32 {
    var c: [3]f32 = .{ 0, 0, 0 };
    for (pts) |p| {
        for (0..3) |a| c[a] += p[a];
    }
    return scale3(c, 1.0 / @as(f32, @floatFromInt(pts.len)));
}

// Newell's normal of a planar polygon.
fn newell(pts: []const [3]f32) [3]f32 {
    var n: [3]f32 = .{ 0, 0, 0 };
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        n[0] += (a[1] - b[1]) * (a[2] + b[2]);
        n[1] += (a[2] - b[2]) * (a[0] + b[0]);
        n[2] += (a[0] - b[0]) * (a[1] + b[1]);
    }
    return norm3(n);
}

// Materials shaded from position alone, whose faces share one surface for
// each seed, which must be below SHARED_SEEDS.
const SHARED_SEEDS: usize = 32;
const NO_SURF = std.math.maxInt(u32);
var shared_surfs: [4][SHARED_SEEDS]u32 = undefined;

fn sharedSlot(mat: Mat) ?usize {
    return switch (mat) {
        .tree => 0,
        .trunk => 1,
        .scrub => 2,
        .shed_roof => 3,
        else => null,
    };
}

fn addSurf(mat: Mat, o: [3]f32, u: [3]f32, v: [3]f32) u32 {
    if (sharedSlot(mat)) |k| {
        if (cur_inside or cur_seed >= SHARED_SEEDS) @trap();
        const at = &shared_surfs[k][cur_seed];
        if (at.* == NO_SURF) at.* = @intCast(surf_count) else return at.*;
    }
    if (surf_count >= MAX_SURFS) @trap();
    surfs[surf_count] = .{ .mat = mat, .inside = cur_inside, .seed = cur_seed, .o = o, .u = u, .v = v };
    surf_count += 1;
    return @intCast(surf_count - 1);
}

fn addPoly(pts: []const [3]f32, surf: u32, n: [3]f32) void {
    if (pts.len < 3) return;
    if (poly_count >= MAX_POLYS or pvert_count + pts.len > MAX_PVERTS) @trap();
    polys[poly_count] = .{ .first = @intCast(pvert_count), .n = @intCast(pts.len), .surf = surf, .nx = n[0], .ny = n[1], .nz = n[2], .d = dot3(n, pts[0]) };
    @memcpy(pverts[pvert_count .. pvert_count + pts.len], pts);
    pvert_count += pts.len;
    poly_count += 1;
}

// A face whose normal points along `out` rather than against it, with a
// texture frame running along the face and up it, in metres.
fn face(pts: []const [3]f32, mat: Mat, out: [3]f32) void {
    var n = newell(pts);
    if (dot3(n, out) < 0) n = scale3(n, -1);
    var u: [3]f32 = .{ 1, 0, 0 };
    var v: [3]f32 = .{ 0, 1, 0 };
    if (@abs(n[2]) < 0.7) {
        u = norm3(.{ -n[1], n[0], 0 });
        v = .{ 0, 0, 1 };
    }
    addPoly(pts, addSurf(mat, pts[0], u, v), n);
}

// A face with its own texture frame, so that (u, v) runs 0 to 1 across a
// screen or a sign as its viewer reads it.
fn faceUV(pts: []const [3]f32, mat: Mat, out: [3]f32, o: [3]f32, u: [3]f32, v: [3]f32) void {
    var n = newell(pts);
    if (dot3(n, out) < 0) n = scale3(n, -1);
    addPoly(pts, addSurf(mat, o, u, v), n);
}

// A face pointing away from a point inside the solid it bounds.
fn faceAway(pts: []const [3]f32, mat: Mat, inner: [3]f32) void {
    face(pts, mat, sub3(centroid(pts), inner));
}

const NO_BOTTOM: u8 = 1 << 4;
const NO_TOP: u8 = 1 << 5;

// An axis-aligned box; `skip` leaves out faces: bits 0 to 3 for -x, +x, -y,
// +y, then NO_BOTTOM and NO_TOP.
fn boxM(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32, side: Mat, top: Mat, skip: u8) void {
    const xa = minf(x0, x1);
    const xb = maxf(x0, x1);
    const ya = minf(y0, y1);
    const yb = maxf(y0, y1);
    if (skip & 1 == 0) face(&.{ .{ xa, ya, z0 }, .{ xa, yb, z0 }, .{ xa, yb, z1 }, .{ xa, ya, z1 } }, side, .{ -1, 0, 0 });
    if (skip & 2 == 0) face(&.{ .{ xb, ya, z0 }, .{ xb, yb, z0 }, .{ xb, yb, z1 }, .{ xb, ya, z1 } }, side, .{ 1, 0, 0 });
    if (skip & 4 == 0) face(&.{ .{ xa, ya, z0 }, .{ xb, ya, z0 }, .{ xb, ya, z1 }, .{ xa, ya, z1 } }, side, .{ 0, -1, 0 });
    if (skip & 8 == 0) face(&.{ .{ xa, yb, z0 }, .{ xb, yb, z0 }, .{ xb, yb, z1 }, .{ xa, yb, z1 } }, side, .{ 0, 1, 0 });
    if (skip & NO_BOTTOM == 0) face(&.{ .{ xa, ya, z0 }, .{ xb, ya, z0 }, .{ xb, yb, z0 }, .{ xa, yb, z0 } }, top, .{ 0, 0, -1 });
    if (skip & NO_TOP == 0) face(&.{ .{ xa, ya, z1 }, .{ xb, ya, z1 }, .{ xb, yb, z1 }, .{ xa, yb, z1 } }, top, .{ 0, 0, 1 });
}

fn box(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32, mat: Mat) void {
    boxM(x0, y0, z0, x1, y1, z1, mat, mat, 0);
}

// A convex solid from eight corners: the bottom four counter-clockwise from
// above, then the top four over them.
fn hexa(c: [8][3]f32, side: Mat, top: Mat) void {
    const mid = centroid(&c);
    faceAway(&.{ c[0], c[3], c[2], c[1] }, top, mid);
    faceAway(&.{ c[4], c[5], c[6], c[7] }, top, mid);
    faceAway(&.{ c[0], c[1], c[5], c[4] }, side, mid);
    faceAway(&.{ c[1], c[2], c[6], c[5] }, side, mid);
    faceAway(&.{ c[2], c[3], c[7], c[6] }, side, mid);
    faceAway(&.{ c[3], c[0], c[4], c[7] }, side, mid);
}

// A box turned by angle a about (cx, cy), with half sizes hx and hy.
fn turnedBox(cx: f32, cy: f32, a: f32, hx: f32, hy: f32, z0: f32, z1: f32, side: Mat, top: Mat) void {
    const c = @cos(a);
    const s = @sin(a);
    var k: [8][3]f32 = undefined;
    const corners = [_][2]f32{ .{ -hx, -hy }, .{ hx, -hy }, .{ hx, hy }, .{ -hx, hy } };
    for (corners, 0..) |p, i| {
        const x = cx + p[0] * c - p[1] * s;
        const y = cy + p[0] * s + p[1] * c;
        k[i] = .{ x, y, z0 };
        k[i + 4] = .{ x, y, z1 };
    }
    hexa(k, side, top);
}

const Cap = enum { flat, cone, none };

// A frustum round a vertical axis: n sides, radius r at z0 narrowing by
// `taper` at z1, closed by a flat top or a cone up to `apex`.
fn prism(cx: f32, cy: f32, r: f32, n: usize, z0: f32, z1: f32, taper: f32, side: Mat, top: Mat, cap: Cap, apex: f32) void {
    var ring: [MAX_POLY_N][3]f32 = undefined;
    var ring_top: [MAX_POLY_N][3]f32 = undefined;
    for (0..n) |i| {
        const a = (@as(f32, @floatFromInt(i)) + 0.5) * 2.0 * std.math.pi / @as(f32, @floatFromInt(n));
        ring[i] = .{ cx + r * @cos(a), cy + r * @sin(a), z0 };
        ring_top[i] = .{ cx + r * taper * @cos(a), cy + r * taper * @sin(a), z1 };
    }
    const axis: [3]f32 = .{ cx, cy, (z0 + z1) * 0.5 };
    for (0..n) |i| {
        const j = (i + 1) % n;
        const q = [_][3]f32{ ring[i], ring[j], ring_top[j], ring_top[i] };
        var out = sub3(centroid(&q), axis);
        out[2] = 0;
        face(&q, side, out);
    }
    switch (cap) {
        .flat => face(ring_top[0..n], top, .{ 0, 0, 1 }),
        .cone => for (0..n) |i| {
            const j = (i + 1) % n;
            const tri = [_][3]f32{ ring_top[i], ring_top[j], .{ cx, cy, apex } };
            faceAway(&tri, top, .{ cx, cy, z1 - 1.0 });
        },
        .none => {},
    }
}

// A vertical prism over a convex outline in plan.
fn extrude(pts: []const [2]f32, z0: f32, z1: f32, side: Mat, top: Mat) void {
    var ring: [MAX_POLY_N][3]f32 = undefined;
    var c: [2]f32 = .{ 0, 0 };
    for (pts) |p| {
        c[0] += p[0];
        c[1] += p[1];
    }
    c[0] /= @floatFromInt(pts.len);
    c[1] /= @floatFromInt(pts.len);
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        const q = [_][3]f32{ .{ a[0], a[1], z0 }, .{ b[0], b[1], z0 }, .{ b[0], b[1], z1 }, .{ a[0], a[1], z1 } };
        face(&q, side, .{ (a[0] + b[0]) * 0.5 - c[0], (a[1] + b[1]) * 0.5 - c[1], 0 });
        ring[i] = .{ a[0], a[1], z1 };
    }
    face(ring[0..pts.len], top, .{ 0, 0, 1 });
}

const Hole = struct { u0: f32, u1: f32, z0: f32, z1: f32 };

const WallSpec = struct {
    a: [2]f32,
    b: [2]f32,
    // Outward unit normal of the outer face, in plan.
    n: [2]f32,
    z0: f32,
    z1: f32,
    thick: f32,
    // How far the wall leans back per metre up.
    lean: f32 = 0,
    out: Mat,
    in: Mat,
    jamb: Mat = .frame,
};

fn wallPoint(w: WallSpec, u: f32, z: f32, d: f32) [3]f32 {
    const dx = w.b[0] - w.a[0];
    const dy = w.b[1] - w.a[1];
    const len = @sqrt(dx * dx + dy * dy);
    const off = d - w.lean * z;
    return .{ w.a[0] + dx / len * u + w.n[0] * off, w.a[1] + dy / len * u + w.n[1] * off, z };
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

// A thick wall with rectangular openings. Its faces are cut on a grid at
// every opening's edges, solid cells in a row are merged, and each opening
// gets a sill, a head, and two sides through the wall's thickness.
fn holeyWall(w: WallSpec, holes: []const Hole) void {
    const dx = w.b[0] - w.a[0];
    const dy = w.b[1] - w.a[1];
    const len = @sqrt(dx * dx + dy * dy);
    var us: [40]f32 = undefined;
    var zs: [40]f32 = undefined;
    var nu: usize = 0;
    var nz: usize = 0;
    us[nu] = 0;
    nu += 1;
    us[nu] = len;
    nu += 1;
    zs[nz] = w.z0;
    nz += 1;
    zs[nz] = w.z1;
    nz += 1;
    for (holes) |h| {
        us[nu] = h.u0;
        us[nu + 1] = h.u1;
        nu += 2;
        zs[nz] = h.z0;
        zs[nz + 1] = h.z1;
        nz += 2;
    }
    sortFloats(us[0..nu]);
    sortFloats(zs[0..nz]);
    const out3: [3]f32 = .{ w.n[0], w.n[1], 0 };
    const in3: [3]f32 = .{ -w.n[0], -w.n[1], 0 };
    var k: usize = 0;
    while (k + 1 < nz) : (k += 1) {
        const za = zs[k];
        const zb = zs[k + 1];
        if (zb - za < 1e-4) continue;
        const zm = (za + zb) * 0.5;
        var start: ?f32 = null;
        var end: f32 = 0;
        var i: usize = 0;
        while (i <= nu) : (i += 1) {
            // One past the last interval closes any run still open.
            var solid = false;
            if (i + 1 < nu) {
                const ua = us[i];
                const ub = us[i + 1];
                if (ub - ua < 1e-4) continue;
                const um = (ua + ub) * 0.5;
                solid = true;
                for (holes) |h| {
                    if (um > h.u0 and um < h.u1 and zm > h.z0 and zm < h.z1) solid = false;
                }
                if (solid) {
                    if (start == null) start = ua;
                    end = ub;
                    continue;
                }
            }
            if (start) |s| {
                const o = [_][3]f32{ wallPoint(w, s, za, 0), wallPoint(w, end, za, 0), wallPoint(w, end, zb, 0), wallPoint(w, s, zb, 0) };
                face(&o, w.out, out3);
                cur_inside = true;
                const q = [_][3]f32{ wallPoint(w, s, za, -w.thick), wallPoint(w, end, za, -w.thick), wallPoint(w, end, zb, -w.thick), wallPoint(w, s, zb, -w.thick) };
                face(&q, w.in, in3);
                cur_inside = false;
                start = null;
            }
        }
    }
    const t = -w.thick;
    const along: [3]f32 = .{ dx / len, dy / len, 0 };
    cur_inside = true;
    for (holes) |h| {
        face(&.{ wallPoint(w, h.u0, h.z0, 0), wallPoint(w, h.u1, h.z0, 0), wallPoint(w, h.u1, h.z0, t), wallPoint(w, h.u0, h.z0, t) }, w.jamb, .{ 0, 0, 1 });
        face(&.{ wallPoint(w, h.u0, h.z1, 0), wallPoint(w, h.u1, h.z1, 0), wallPoint(w, h.u1, h.z1, t), wallPoint(w, h.u0, h.z1, t) }, w.jamb, .{ 0, 0, -1 });
        face(&.{ wallPoint(w, h.u0, h.z0, 0), wallPoint(w, h.u0, h.z1, 0), wallPoint(w, h.u0, h.z1, t), wallPoint(w, h.u0, h.z0, t) }, w.jamb, along);
        face(&.{ wallPoint(w, h.u1, h.z0, 0), wallPoint(w, h.u1, h.z1, 0), wallPoint(w, h.u1, h.z1, t), wallPoint(w, h.u1, h.z0, t) }, w.jamb, scale3(along, -1));
    }
    cur_inside = false;
}

fn addCbox(x0: f32, y0: f32, x1: f32, y1: f32) void {
    if (cbox_count >= MAX_CBOXES) @trap();
    cboxes[cbox_count] = .{ minf(x0, x1), minf(y0, y1), maxf(x0, x1), maxf(y0, y1) };
    cbox_count += 1;
}

fn addObstaclePoly(pts: []const [2]f32) void {
    if (obstacle_count >= MAX_OBSTACLES or obs_vert_count + pts.len > MAX_OBS_VERTS) @trap();
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (pts) |p| {
        cx += p[0];
        cy += p[1];
    }
    cx /= @floatFromInt(pts.len);
    cy /= @floatFromInt(pts.len);
    var r: f32 = 0;
    for (pts) |p| r = maxf(r, @sqrt((p[0] - cx) * (p[0] - cx) + (p[1] - cy) * (p[1] - cy)));
    @memcpy(obs_verts[obs_vert_count .. obs_vert_count + pts.len], pts);
    obstacles[obstacle_count] = .{ .cx = cx, .cy = cy, .r = r, .first = @intCast(obs_vert_count), .n = @intCast(pts.len) };
    obs_vert_count += pts.len;
    obstacle_count += 1;
}

fn addObstacleRect(x0: f32, y0: f32, x1: f32, y1: f32) void {
    addObstaclePoly(&.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } });
}

fn addObstacleCircle(x: f32, y: f32, r: f32) void {
    if (obstacle_count >= MAX_OBSTACLES) @trap();
    obstacles[obstacle_count] = .{ .cx = x, .cy = y, .r = r };
    obstacle_count += 1;
}

fn insideConvex(pts: []const [2]f32, x: f32, y: f32) bool {
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        if ((b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]) < 0) return false;
    }
    return true;
}

fn onMud(x: f32, y: f32) bool {
    return insideConvex(&MUD, x, y);
}

const Ground = struct { z: f32 = 0, gx: f32 = 0, gy: f32 = 0, drag: f32 = 0 };

// The height of the beach or sandbank at a point, its slope, and how hard
// the sand drags at the skirt. Each beach face is a plane, so the height
// falls linearly with the distance past the rock along the nearest face's
// outward normal, and a sandbank's falls the same way past its crest.
fn groundAt(x: f32, y: f32) Ground {
    const n: f32 = @floatFromInt(ISLAND_SIDES);
    const apothem = @cos(std.math.pi / n);
    for (ISLANDS) |isl| {
        const dx = x - isl.x;
        const dy = y - isl.y;
        if (dx * dx + dy * dy > isl.r * isl.r) continue;
        var best: f32 = -std.math.inf(f32);
        var bn: [2]f32 = .{ 1, 0 };
        for (0..ISLAND_SIDES) |k| {
            const a = (@as(f32, @floatFromInt(k)) + 1.0) * 2.0 * std.math.pi / n;
            const d = dx * @cos(a) + dy * @sin(a);
            if (d > best) {
                best = d;
                bn = .{ @cos(a), @sin(a) };
            }
        }
        const run = (isl.r - isl.rock) * apothem;
        const t = (isl.r * apothem - best) / run;
        if (t <= 0) continue;
        if (t >= 1) return .{ .z = isl.beach, .drag = MUD_DRAG };
        const k = isl.beach / run;
        return .{ .z = isl.beach * t, .gx = -k * bn[0], .gy = -k * bn[1], .drag = MUD_DRAG };
    }
    for (BANKS, &BANK_OUTLINES) |b, *o| {
        if (x < o.lo[0] - BANK_RUN or x > o.hi[0] + BANK_RUN or y < o.lo[1] - BANK_RUN or y > o.hi[1] + BANK_RUN) continue;
        var best: f32 = -std.math.inf(f32);
        var bi: usize = 0;
        for (0..o.n) |i| {
            const d = o.ns[i][0] * x + o.ns[i][1] * y - o.ds[i];
            if (d > best) {
                best = d;
                bi = i;
            }
        }
        if (best >= BANK_RUN) continue;
        if (best <= 0) return .{ .z = b.h, .drag = BANK_DRAG };
        const k = b.h / BANK_RUN;
        return .{ .z = b.h - k * best, .gx = -k * o.ns[bi][0], .gy = -k * o.ns[bi][1], .drag = BANK_DRAG };
    }
    return .{};
}

// How high the beach lifts the craft. It can't pitch, so it rides at the
// mean of the ground under its corners, or higher if its middle is.
fn craftGround() f32 {
    const corners = [_][2]f32{ .{ CRAFT_HALF_L, CRAFT_HALF_W }, .{ CRAFT_HALF_L, -CRAFT_HALF_W }, .{ -CRAFT_HALF_L, CRAFT_HALF_W }, .{ -CRAFT_HALF_L, -CRAFT_HALF_W } };
    var sum: f32 = 0;
    for (corners) |p| {
        const w = toWorld(p[0], p[1]);
        sum += groundAt(w[0], w[1]).z;
    }
    return maxf(sum / corners.len, groundAt(cr_x, cr_y).z);
}

// The craft's plan: a long octagon, pointed a little at the bow.
const HULL_PLAN = [_][2]f32{ .{ 20, -5 }, .{ 20, 5 }, .{ 17, 9 }, .{ -18, 9 }, .{ -20, 7 }, .{ -20, -7 }, .{ -18, -9 }, .{ 17, -9 } };

// The outline pushed out by d, each corner moved along its bisector so the
// rings' sides stay parallel and the skirt's bands are planar.
fn offsetPlan(d: f32, z: f32, out: *[HULL_PLAN.len][3]f32) void {
    const n = HULL_PLAN.len;
    for (0..n) |i| {
        const p = HULL_PLAN[(i + n - 1) % n];
        const c = HULL_PLAN[i];
        const q = HULL_PLAN[(i + 1) % n];
        const n1 = norm3(.{ c[1] - p[1], -(c[0] - p[0]), 0 });
        const n2 = norm3(.{ q[1] - c[1], -(q[0] - c[0]), 0 });
        const b = norm3(.{ n1[0] + n2[0], n1[1] + n2[1], 0 });
        const k = d / dot3(b, n1);
        out[i] = .{ c[0] + b[0] * k, c[1] + b[1] * k, z };
    }
}

fn buildLevel() void {
    if (level_built) return;
    bakeRipples();
    surf_count = 0;
    for (&shared_surfs) |*row| @memset(row, NO_SURF);
    poly_count = 0;
    pvert_count = 0;
    obstacle_count = 0;
    obs_vert_count = 0;
    cbox_count = 0;
    buildCraft();
    const craft_end = poly_count;
    buildBay();
    const base = poly_count;
    bnode_count = 0;
    craft_tree = buildTree(0, craft_end);
    world_tree = buildTree(craft_end, base - craft_end);
    if (pvert_count + 4 > MAX_PVERTS) @trap();
    rudder_verts = pvert_count;
    pvert_count += 4;
    // The speedboat's faces in its own frame, then room for them moved to
    // where it is.
    boat_polys = poly_count;
    boat_verts = pvert_count;
    buildSpeedboat();
    boat_polys_end = poly_count;
    boat_moved = pvert_count;
    if (2 * pvert_count - boat_verts > MAX_PVERTS) @trap();
    pvert_count += boat_moved - boat_verts;
    level_built = true;
}

// The rival's speedboat, 11 m long, in its own frame: x forward, y to port,
// z up from the waterline. A white hull with a pointed bow, a windscreen, a
// bench seat, twin outboards and its driver in a yellow lifejacket.
fn buildSpeedboat() void {
    cur_inside = false;
    cur_seed = 0;
    extrude(&.{ .{ RIVAL_HALF_L, 0 }, .{ 2.8, RIVAL_HALF_W }, .{ -RIVAL_HALF_L, RIVAL_HALF_W }, .{ -RIVAL_HALF_L, -RIVAL_HALF_W }, .{ 2.8, -RIVAL_HALF_W } }, -0.3, 0.9, .speedboat, .boat_deck);
    const screen = [_][3]f32{ .{ 1.2, -1.35, 0.9 }, .{ 1.2, 1.35, 0.9 }, .{ 0.6, 1.2, 1.7 }, .{ 0.6, -1.2, 1.7 } };
    face(&screen, .boat_glass, .{ 1, 0, 0.6 });
    face(&screen, .boat_glass, .{ -1, 0, -0.6 });
    boxM(-1.6, -1.2, 0.9, -0.6, 1.2, 1.35, .chair, .chair, NO_BOTTOM);
    boxM(-1.85, -1.2, 0.9, -1.6, 1.2, 1.9, .chair, .chair, NO_BOTTOM);
    boxM(-6.2, -0.8, 0.0, -RIVAL_HALF_L, 0.8, 1.4, .hull_dark, .hull_dark, NO_BOTTOM);
    boxM(-1.3, -0.85, 1.35, -0.9, -0.25, 2.05, .buoy_yellow, .buoy_yellow, NO_BOTTOM);
    boxM(-1.22, -0.72, 2.05, -0.98, -0.38, 2.35, .skin, .skin, NO_BOTTOM);
}

fn buildCraft() void {
    cur_seed = 0;
    // Lower hull and deck, just under the cabin floor so they never fight it.
    const deck_z: f32 = -0.02;
    var top: [HULL_PLAN.len][3]f32 = undefined;
    var bot: [HULL_PLAN.len][3]f32 = undefined;
    offsetPlan(0, deck_z, &top);
    offsetPlan(0, -1.0, &bot);
    cur_inside = false;
    face(&top, .deck, .{ 0, 0, 1 });
    for (0..HULL_PLAN.len) |i| {
        const j = (i + 1) % HULL_PLAN.len;
        const q = [_][3]f32{ bot[i], bot[j], top[j], top[i] };
        const out = sub3(centroid(&q), .{ 0, 0, -0.5 });
        // The long sides carry the company's name, read from outside.
        if (i == 2) {
            faceUV(&q, .hull_name, out, .{ 17, 9, deck_z }, .{ -1.0 / 35.0, 0, 0 }, .{ 0, 0, -1.0 / 0.98 });
        } else if (i == 6) {
            faceUV(&q, .hull_name, out, .{ -18, -9, deck_z }, .{ 1.0 / 35.0, 0, 0 }, .{ 0, 0, -1.0 / 0.98 });
        } else {
            face(&q, .hull, .{ out[0], out[1], 0 });
        }
    }
    // The skirt bulges out round the hull and tucks in at the water.
    var s1: [HULL_PLAN.len][3]f32 = undefined;
    var s2: [HULL_PLAN.len][3]f32 = undefined;
    offsetPlan(0.7, -1.4, &s1);
    offsetPlan(0.25, -2.0, &s2);
    for (0..HULL_PLAN.len) |i| {
        const j = (i + 1) % HULL_PLAN.len;
        const q1 = [_][3]f32{ bot[i], bot[j], s1[j], s1[i] };
        const c1 = centroid(&q1);
        face(&q1, .skirt, .{ c1[0], c1[1], 0.3 * @sqrt(c1[0] * c1[0] + c1[1] * c1[1]) });
        const q2 = [_][3]f32{ s1[i], s1[j], s2[j], s2[i] };
        const c2 = centroid(&q2);
        face(&q2, .skirt, .{ c2[0], c2[1], -0.3 * @sqrt(c2[0] * c2[0] + c2[1] * c2[1]) });
    }

    // The cabin. Its outer faces are orange with a black band through the
    // windows; inside it is office beige.
    const outer = CABIN_SIDE + WALL_T;
    const rear_out = CABIN_REAR - WALL_T;
    var windows: [9]Hole = undefined;
    for (0..9) |k| {
        const xc = -11.5 + 2.9 * @as(f32, @floatFromInt(k));
        windows[k] = .{ .u0 = xc - 1.0 - rear_out, .u1 = xc + 1.0 - rear_out, .z0 = 1.0, .z1 = 2.2 };
    }
    holeyWall(.{ .a = .{ rear_out, outer }, .b = .{ CHEEK_X, outer }, .n = .{ 0, 1 }, .z0 = deck_z, .z1 = ROOF, .thick = WALL_T, .out = .hull_band, .in = .wall_in }, &windows);
    holeyWall(.{ .a = .{ rear_out, -outer }, .b = .{ CHEEK_X, -outer }, .n = .{ 0, -1 }, .z0 = deck_z, .z1 = ROOF, .thick = WALL_T, .out = .hull_band, .in = .wall_in }, &windows);
    holeyWall(.{ .a = .{ rear_out, -outer }, .b = .{ rear_out, outer }, .n = .{ -1, 0 }, .z0 = deck_z, .z1 = ROOF, .thick = WALL_T, .out = .hull_band, .in = .wall_in }, &.{.{ .u0 = outer - 1.5, .u1 = outer + 1.5, .z0 = 1.2, .z1 = 2.2 }});
    // The windscreen: three panes in a wall leaning back like the C111's.
    const panes = [_]Hole{
        .{ .u0 = 1.2, .u1 = 5.9, .z0 = 1.05, .z1 = 2.75 },
        .{ .u0 = 6.1, .u1 = 10.7, .z0 = 1.05, .z1 = 2.75 },
        .{ .u0 = 10.9, .u1 = 15.6, .z0 = 1.05, .z1 = 2.75 },
    };
    holeyWall(.{ .a = .{ SCREEN_FOOT + WALL_T, -outer }, .b = .{ SCREEN_FOOT + WALL_T, outer }, .n = .{ 1, 0 }, .z0 = deck_z, .z1 = ROOF, .thick = WALL_T, .lean = SCREEN_LEAN, .out = .hull_dark, .in = .wall_in }, &panes);
    // Where the side walls meet the leaning windscreen.
    for ([_]f32{ 1, -1 }) |side| {
        face(&.{ .{ CHEEK_X, side * outer, deck_z }, .{ SCREEN_FOOT + WALL_T, side * outer, deck_z }, .{ SCREEN_FOOT + WALL_T - SCREEN_LEAN * ROOF, side * outer, ROOF }, .{ CHEEK_X, side * outer, ROOF } }, .hull_band, .{ 0, side, 0 });
        cur_inside = true;
        face(&.{ .{ CHEEK_X, side * CABIN_SIDE, 0 }, .{ SCREEN_FOOT, side * CABIN_SIDE, 0 }, .{ SCREEN_FOOT - SCREEN_LEAN * ROOF, side * CABIN_SIDE, ROOF }, .{ CHEEK_X, side * CABIN_SIDE, ROOF } }, .wall_in, .{ 0, -side, 0 });
        cur_inside = false;
    }
    const roof_front = SCREEN_FOOT + WALL_T - SCREEN_LEAN * ROOF;
    face(&.{ .{ rear_out, -outer, ROOF }, .{ roof_front, -outer, ROOF }, .{ roof_front, outer, ROOF }, .{ rear_out, outer, ROOF } }, .roof, .{ 0, 0, 1 });

    // On the roof: the satellite dish's radome and a radio mast.
    prism(-4, 0, 1.3, 10, ROOF, ROOF + 0.9, 1.0, .radome, .radome, .cone, ROOF + 1.7);
    box(-8.05, -0.05, ROOF, -7.95, 0.05, ROOF + 3.0, .hull_dark);
    // Port and starboard lights.
    box(13.4, outer, 2.9, 13.8, outer + 0.15, 3.1, .nav_red);
    box(13.4, -outer - 0.15, 2.9, 13.8, -outer, 3.1, .nav_green);

    // Two ducted propellers on the after deck. Their rudders turn, so they
    // are drawn each frame instead (drawRudders).
    for ([_]f32{ 4.6, -4.6 }) |yc| duct(yc);
    rudder_surf = addSurf(.rudder, .{ RUDDER_X, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 });

    // Inside.
    cur_inside = true;
    face(&.{ .{ CABIN_REAR, -CABIN_SIDE, 0 }, .{ SCREEN_FOOT, -CABIN_SIDE, 0 }, .{ SCREEN_FOOT, CABIN_SIDE, 0 }, .{ CABIN_REAR, CABIN_SIDE, 0 } }, .carpet, .{ 0, 0, 1 });
    const ceil_front = SCREEN_FOOT - SCREEN_LEAN * CEIL;
    face(&.{ .{ CABIN_REAR, -CABIN_SIDE, CEIL }, .{ ceil_front, -CABIN_SIDE, CEIL }, .{ ceil_front, CABIN_SIDE, CEIL }, .{ CABIN_REAR, CABIN_SIDE, CEIL } }, .ceiling, .{ 0, 0, -1 });
    for ([_]f32{ -11.5, -7.0, -2.5, 2.0, 6.5, 11.0 }) |lx| {
        for ([_]f32{ -5.5, 0, 5.5 }) |ly| {
            face(&.{ .{ lx - 0.6, ly - 0.3, CEIL - 0.02 }, .{ lx + 0.6, ly - 0.3, CEIL - 0.02 }, .{ lx + 0.6, ly + 0.3, CEIL - 0.02 }, .{ lx - 0.6, ly + 0.3, CEIL - 0.02 } }, .light_panel, .{ 0, 0, -1 });
        }
    }

    // The helm: a console under the windscreen with its screens, and the
    // pilot's seat.
    hexa(.{
        .{ 13.2, -3.2, 0 },    .{ 15.2, -3.2, 0 },   .{ 15.2, 3.2, 0 },   .{ 13.2, 3.2, 0 },
        .{ 13.2, -3.2, 0.95 }, .{ 15.2, -3.2, 1.1 }, .{ 15.2, 3.2, 1.1 }, .{ 13.2, 3.2, 0.95 },
    }, .console, .console);
    addCbox(13.2, -3.2, 15.2, 3.2);
    {
        const lift_z = 0.006;
        const za = 0.95 + 0.15 * (13.5 - 13.2) / 2.0 + lift_z;
        const zb = 0.95 + 0.15 * (14.9 - 13.2) / 2.0 + lift_z;
        const q = [_][3]f32{ .{ 13.5, 2.6, za }, .{ 13.5, -2.6, za }, .{ 14.9, -2.6, zb }, .{ 14.9, 2.6, zb } };
        faceUV(&q, .console_glow, .{ -0.075, 0, 1 }, .{ 13.5, 2.6, za }, .{ 0, -1.0 / 5.2, 0 }, .{ 1.0 / 1.4, 0, 0 });
    }
    chair(HELM[0], HELM[1], 0);
    addCbox(11.55, -0.3, 12.3, 0.3);

    // Eight cubicles. Yours is the first on the port side.
    for (CUBE_XS, 0..) |x0, i| {
        for ([_]f32{ 1, -1 }) |side| {
            cur_seed = @intCast(i * 2 + @as(usize, if (side > 0) 0 else 1));
            cubicle(x0, side, i == 0 and side > 0);
        }
    }
    cur_seed = 0;
    for ([_]f32{ 1, -1 }) |side| {
        partition(CUBE_XS[0] + CUBE_LEN - 0.03, side * AISLE, CUBE_XS[0] + CUBE_LEN + 0.03, side * CABIN_SIDE);
    }

    // The back of the office: the server rack and the satellite modem, a
    // water cooler, the whiteboard, and the foosball table.
    box(-13.5, -8.0, 0, -12.7, -6.9, 2.0, .rack);
    addCbox(-13.5, -8.0, -12.7, -6.9);
    box(-13.45, 6.6, 0, -13.0, 7.05, 1.0, .cooler);
    prism(-13.22, 6.83, 0.17, 8, 1.0, 1.42, 0.9, .bottle, .bottle, .flat, 0);
    addCbox(-13.5, 6.6, -13.0, 7.05);
    boxM(-11.6, -0.75, 0, -10.0, 0.75, 0.9, .wood, .foosball, 0);
    addCbox(-11.6, -0.75, -10.0, 0.75);
    faceUV(&.{ .{ CABIN_REAR + 0.01, 2.0, 0.9 }, .{ CABIN_REAR + 0.01, 6.0, 0.9 }, .{ CABIN_REAR + 0.01, 6.0, 2.1 }, .{ CABIN_REAR + 0.01, 2.0, 2.1 } }, .whiteboard, .{ 1, 0, 0 }, .{ CABIN_REAR + 0.01, 2.0, 2.1 }, .{ 0, 1.0 / 4.0, 0 }, .{ 0, 0, -1.0 / 1.2 });
    cur_inside = false;
}

// A duct of twelve sides round an axis running fore and aft, with the
// propeller's disc inside it.
fn duct(yc: f32) void {
    const n: usize = 12;
    const zc: f32 = 2.75;
    const ro: f32 = 2.7;
    const ri: f32 = 2.4;
    const xa: f32 = -19.4;
    const xb: f32 = -15.6;
    var disc_f: [12][3]f32 = undefined;
    var disc_b: [12][3]f32 = undefined;
    for (0..n) |i| {
        const a0 = (@as(f32, @floatFromInt(i)) + 0.5) * 2.0 * std.math.pi / 12.0;
        const a1 = (@as(f32, @floatFromInt(i)) + 1.5) * 2.0 * std.math.pi / 12.0;
        const c0 = @cos(a0);
        const s0 = @sin(a0);
        const c1 = @cos(a1);
        const s1 = @sin(a1);
        const outer0a: [3]f32 = .{ xa, yc + ro * c0, zc + ro * s0 };
        const outer1a: [3]f32 = .{ xa, yc + ro * c1, zc + ro * s1 };
        const outer0b: [3]f32 = .{ xb, yc + ro * c0, zc + ro * s0 };
        const outer1b: [3]f32 = .{ xb, yc + ro * c1, zc + ro * s1 };
        const inner0a: [3]f32 = .{ xa, yc + ri * c0, zc + ri * s0 };
        const inner1a: [3]f32 = .{ xa, yc + ri * c1, zc + ri * s1 };
        const inner0b: [3]f32 = .{ xb, yc + ri * c0, zc + ri * s0 };
        const inner1b: [3]f32 = .{ xb, yc + ri * c1, zc + ri * s1 };
        const mid_c = (c0 + c1) * 0.5;
        const mid_s = (s0 + s1) * 0.5;
        face(&.{ outer0a, outer1a, outer1b, outer0b }, .hull, .{ 0, mid_c, mid_s });
        face(&.{ inner0a, inner1a, inner1b, inner0b }, .duct_in, .{ 0, -mid_c, -mid_s });
        face(&.{ outer0a, outer1a, inner1a, inner0a }, .hull_dark, .{ -1, 0, 0 });
        face(&.{ outer0b, outer1b, inner1b, inner0b }, .hull_dark, .{ 1, 0, 0 });
        disc_f[i] = .{ -17.1, yc + ri * c0, zc + ri * s0 };
        disc_b[i] = .{ -17.2, yc + ri * c0, zc + ri * s0 };
    }
    faceUV(&disc_f, .prop, .{ 1, 0, 0 }, .{ -17.1, yc, zc }, .{ 0, 1, 0 }, .{ 0, 0, 1 });
    faceUV(&disc_b, .prop, .{ -1, 0, 0 }, .{ -17.2, yc, zc }, .{ 0, 1, 0 }, .{ 0, 0, 1 });
}

// An office chair facing along `facing` (radians in the craft's plan).
fn chair(x: f32, y: f32, facing: f32) void {
    const c = @cos(facing);
    const s = @sin(facing);
    turnedBox(x, y, facing, 0.27, 0.27, 0.38, 0.5, .chair, .chair);
    turnedBox(x - c * 0.34, y - s * 0.34, facing, 0.06, 0.25, 0.5, 1.25, .chair, .chair);
    turnedBox(x, y, facing, 0.04, 0.04, 0.0, 0.38, .frame, .frame);
}

fn partition(x0: f32, y0: f32, x1: f32, y1: f32) void {
    box(x0, y0, 0, x1, y1, PARTITION_H, .partition);
    addCbox(x0, y0, x1, y1);
}

// One cubicle: low partitions, a desk under the window, a 17 inch CRT and
// keyboard, and a chair. `side` is 1 for port and -1 for starboard.
fn cubicle(x0: f32, side: f32, mine: bool) void {
    partition(x0 + 1.25, side * (AISLE - 0.03), x0 + CUBE_LEN, side * (AISLE + 0.03));
    partition(x0, side * (AISLE - 0.03), x0 + 0.25, side * (AISLE + 0.03));
    partition(x0 - 0.03, side * AISLE, x0 + 0.03, side * CABIN_SIDE);
    // Desk top, pedestal, and modesty panel.
    box(x0 + 0.6, side * 6.75, 0.72, x0 + 3.9, side * 7.95, 0.76, .desk);
    box(x0 + 3.2, side * 6.8, 0, x0 + 3.9, side * 7.9, 0.72, .desk);
    box(x0 + 0.6, side * 7.88, 0.1, x0 + 3.2, side * 7.92, 0.72, .desk);
    addCbox(x0 + 0.6, side * 6.75, x0 + 3.9, side * 7.95);
    // The monitor: a deep beige box narrowing to the back, on a stand.
    const cx = x0 + CUBE_LEN * 0.5;
    const f = side * CRT_FRONT;
    const b = side * (CRT_FRONT + 0.43);
    box(cx - 0.12, side * 7.3, 0.76, cx + 0.12, side * 7.55, CRT_Z0 - 0.03, .crt_case);
    hexa(.{
        .{ cx - 0.205, f, CRT_Z0 - 0.03 }, .{ cx + 0.205, f, CRT_Z0 - 0.03 }, .{ cx + 0.14, b, CRT_Z0 + 0.03 }, .{ cx - 0.14, b, CRT_Z0 + 0.03 },
        .{ cx - 0.205, f, CRT_Z0 + 0.37 }, .{ cx + 0.205, f, CRT_Z0 + 0.37 }, .{ cx + 0.14, b, CRT_Z0 + 0.3 },  .{ cx - 0.14, b, CRT_Z0 + 0.3 },
    }, .crt_case, .crt_case);
    const sy = f - side * 0.004;
    const zt = CRT_Z0 + 0.17 + CRT_HT * 0.5;
    const zb = zt - CRT_HT;
    const q = [_][3]f32{ .{ cx - CRT_W * 0.5, sy, zb }, .{ cx + CRT_W * 0.5, sy, zb }, .{ cx + CRT_W * 0.5, sy, zt }, .{ cx - CRT_W * 0.5, sy, zt } };
    // Read from the chair: across to the sitter's right, and down.
    const o: [3]f32 = .{ cx - side * CRT_W * 0.5, sy, zt };
    faceUV(&q, if (mine) .crt_mine else .crt_saver, .{ 0, -side, 0 }, o, .{ side / CRT_W, 0, 0 }, .{ 0, 0, -1.0 / CRT_HT });
    box(cx - 0.23, side * 6.85, 0.76, cx + 0.23, side * 7.03, 0.785, .keyboard);
    if (cur_seed == 5) box(x0 + 0.8, side * 7.3, 0.76, x0 + 1.25, side * 7.75, 0.81, .pizza);
    chair(cx, side * CHAIR_Y, if (side > 0) std.math.pi / 2.0 else -std.math.pi / 2.0);
}

// The bay

// Each island is a sand beach rising gently from the water, which a
// hovercraft can ride up, round a rock with steep sides, which it can't.
const Island = struct { x: f32, y: f32, r: f32, rock: f32, beach: f32, h: f32, taper: f32 };
const ISLANDS = [_]Island{
    .{ .x = 420, .y = 380, .r = 110, .rock = 72, .beach = 2.4, .h = 16, .taper = 0.85 },
    .{ .x = 1900, .y = 1500, .r = 160, .rock = 105, .beach = 3.0, .h = 28, .taper = 0.8 },
    .{ .x = 700, .y = 1750, .r = 95, .rock = 62, .beach = 2.0, .h = 12, .taper = 0.85 },
};
const ISLAND_SIDES: usize = 10;
const SHIP_C: [2]f32 = .{ 1400, 420 };
const SHIP_A: f32 = 0.4;
const SHIP_PLAN = [_][2]f32{ .{ -110, -16 }, .{ 95, -16 }, .{ 120, 0 }, .{ 95, 16 }, .{ -110, 16 } };
const BRIDGE_X0: f32 = -900;
const BRIDGE_X1: f32 = 2900;
const PIER_STEP: f32 = 80;
const PIER_X0: f32 = -780;
const PIER_COUNT: usize = 47;
// The navigation span leaves out two piers; its towers stand either side.
const NAV_SKIP = [_]usize{ 23, 24 };
const NAV_TOWERS = [_]usize{ 22, 25 };

// Shallows, sandbanks and reefs. The flats are broad stretches of shallow
// water: the Middle Ground between the rocks and the freighter, and a great
// sweep north of the bridge that keeps boats to the east side of the bay.
// Sandbanks barely dry, low enough for the skirt to ride over. Reefs are
// rock just awash, marked by the surf breaking over them, and they stop a
// hovercraft as surely as a boat. More of all three lie toward the end.

// A convex outline wound counter-clockwise, with each edge's outward normal
// and offset, and its bounds.
const MAX_OUTLINE: usize = 8;
const Outline = struct { n: usize, pts: [MAX_OUTLINE][2]f32, ns: [MAX_OUTLINE][2]f32, ds: [MAX_OUTLINE]f32, lo: [2]f32, hi: [2]f32 };

fn outline(pts: []const [2]f32) Outline {
    var o: Outline = .{ .n = pts.len, .pts = undefined, .ns = undefined, .ds = undefined, .lo = pts[0], .hi = pts[0] };
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        const l = @sqrt(ex * ex + ey * ey);
        o.pts[i] = a;
        o.ns[i] = .{ ey / l, -ex / l };
        o.ds[i] = o.ns[i][0] * a[0] + o.ns[i][1] * a[1];
        o.lo = .{ minf(o.lo[0], a[0]), minf(o.lo[1], a[1]) };
        o.hi = .{ maxf(o.hi[0], a[0]), maxf(o.hi[1], a[1]) };
    }
    return o;
}

// How far a point is outside an outline, past its furthest edge: exact off
// the middle of an edge, a little short of it off a corner, and less than
// zero inside.
fn outside(o: *const Outline, x: f32, y: f32) f32 {
    var d: f32 = -std.math.inf(f32);
    for (0..o.n) |i| d = maxf(d, o.ns[i][0] * x + o.ns[i][1] * y - o.ds[i]);
    return d;
}

// A patch of the bay hl along its length and hw across either side of its
// centre, turned by a, with its corners cut off.
const Patch = struct { x: f32, y: f32, hl: f32, hw: f32, a: f32 };

fn patchOutline(p: Patch) Outline {
    const k = minf(p.hw * 0.6, p.hl * 0.4);
    const corners = [_][2]f32{ .{ p.hl, -p.hw + k }, .{ p.hl, p.hw - k }, .{ p.hl - k, p.hw }, .{ -p.hl + k, p.hw }, .{ -p.hl, p.hw - k }, .{ -p.hl, -p.hw + k }, .{ -p.hl + k, -p.hw }, .{ p.hl - k, -p.hw } };
    const c = @cos(p.a);
    const s = @sin(p.a);
    var pts: [corners.len][2]f32 = undefined;
    for (corners, 0..) |q, i| pts[i] = .{ p.x + q[0] * c - q[1] * s, p.y + q[0] * s + q[1] * c };
    return outline(&pts);
}

// Each sandbank's crest, h above the water, slopes down over BANK_RUN to the
// water's edge, and the bottom shelves away from there over BANK_SHELF. On
// the sand the skirt drags a little, far less than on a beach.
const Bank = struct { p: Patch, h: f32 };
const BANKS = [_]Bank{
    // The Middle Ground.
    .{ .p = .{ .x = 640, .y = 300, .hl = 150, .hw = 35, .a = 0.6 }, .h = 0.5 },
    .{ .p = .{ .x = 1000, .y = 450, .hl = 80, .hw = 30, .a = 1.2 }, .h = 0.4 },
    // The flats.
    .{ .p = .{ .x = 1330, .y = 1400, .hl = 170, .hw = 45, .a = 0.25 }, .h = 0.6 },
    .{ .p = .{ .x = 1640, .y = 1880, .hl = 90, .hw = 40, .a = 0.2 }, .h = 0.5 },
    .{ .p = .{ .x = 1250, .y = 1900, .hl = 140, .hw = 50, .a = -0.4 }, .h = 0.5 },
    .{ .p = .{ .x = 2150, .y = 1750, .hl = 150, .hw = 40, .a = 1.3 }, .h = 0.6 },
    .{ .p = .{ .x = 2250, .y = 2050, .hl = 90, .hw = 30, .a = 0.6 }, .h = 0.4 },
};
const BANK_RUN: f32 = 25;
const BANK_SHELF: f32 = 50;
const BANK_DRAG: f32 = 0.01;

// The reefs, whose surf breaks REEF_SURF either side of their edges. Two of
// them leave a gap about 60 m wide on the way to the berth.
const REEFS = [_]Patch{
    .{ .x = 300, .y = 110, .hl = 35, .hw = 14, .a = 0.3 },
    .{ .x = 830, .y = 560, .hl = 55, .hw = 18, .a = -0.7 },
    .{ .x = 1550, .y = 1720, .hl = 80, .hw = 22, .a = 2.6 },
    .{ .x = 1690, .y = 2030, .hl = 50, .hw = 16, .a = 0.3 },
    .{ .x = 1850, .y = 2090, .hl = 50, .hw = 16, .a = 0.3 },
    .{ .x = 2060, .y = 1980, .hl = 60, .hw = 20, .a = -0.5 },
    .{ .x = 1050, .y = 2250, .hl = 70, .hw = 20, .a = 0.2 },
};
const REEF_SHELF: f32 = 30;
const REEF_SURF: f32 = 9;

// The flats, whose bottom comes up to FLAT_K of the way to a beach's, over
// FLAT_SHELF in from their edges.
const FLATS = [_][]const [2]f32{
    &.{ .{ 450, 60 }, .{ 900, 120 }, .{ 1150, 420 }, .{ 1000, 620 }, .{ 600, 520 }, .{ 440, 250 } },
    &.{ .{ 1250, 1300 }, .{ 2100, 1290 }, .{ 2420, 1700 }, .{ 2380, 2120 }, .{ 1880, 2280 }, .{ 900, 2450 }, .{ 600, 2050 } },
};
const FLAT_SHELF: f32 = 80;
const FLAT_K: f32 = 0.5;

const BANK_OUTLINES = blk: {
    var os: [BANKS.len]Outline = undefined;
    for (BANKS, 0..) |b, i| os[i] = patchOutline(b.p);
    break :blk os;
};
const REEF_OUTLINES = blk: {
    var os: [REEFS.len]Outline = undefined;
    for (REEFS, 0..) |r, i| os[i] = patchOutline(r);
    break :blk os;
};
const FLAT_OUTLINES = blk: {
    var os: [FLATS.len]Outline = undefined;
    for (FLATS, 0..) |f, i| os[i] = outline(f);
    break :blk os;
};

fn shipPoint(p: [2]f32) [2]f32 {
    const c = @cos(SHIP_A);
    const s = @sin(SHIP_A);
    return .{ SHIP_C[0] + p[0] * c - p[1] * s, SHIP_C[1] + p[0] * s + p[1] * c };
}

fn buoy(x: f32, y: f32, mat: Mat) void {
    prism(x, y, 0.8, 6, 0, 2.0, 0.8, mat, mat, .cone, 2.9);
    addObstacleCircle(x, y, 1.0);
}

// The shores round the bay, as boxes (x0, y0, x1, y1) of land behind a
// seawall, and the hills behind them as (x, y, radius, height).
const SHORES = [_][4]f32{ .{ -1000, -420, 3000, -300 }, .{ -1000, 2700, 3000, 2820 }, .{ -1000, -300, -800, 2700 }, .{ 2800, -300, 3000, 2700 } };
const SHORE_Z: f32 = 3.0;
const HILLS = [_][4]f32{
    .{ -1700, 1200, 750, 300 }, .{ 1000, 3700, 1100, 420 },  .{ 3800, 1400, 900, 250 },  .{ 900, -1400, 1000, 200 },
    .{ 3500, 3400, 850, 350 },  .{ -1500, -1000, 700, 260 }, .{ -1300, 3400, 800, 380 }, .{ 2600, -1300, 800, 180 },
};
// The investors' office, which nothing else on the shore may crowd.
const OFFICE = [4]f32{ 1950, 2725, 2070, 2770 };

// Each shore in its own frame, in the order of SHORES: where its seawall
// starts, the directions along the wall and inland, how long and deep it
// is, and how much of it is sheds rather than trees. A quayside road runs
// along each, ROAD_W0 to ROAD_W1 in from the wall.
const Strip = struct { o: [2]f32, a: [2]f32, n: [2]f32, len: f32, depth: f32, sheds: f32 };
const STRIPS = [_]Strip{
    .{ .o = .{ -800, -300 }, .a = .{ 1, 0 }, .n = .{ 0, -1 }, .len = 3600, .depth = 120, .sheds = 0.55 },
    .{ .o = .{ -800, 2700 }, .a = .{ 1, 0 }, .n = .{ 0, 1 }, .len = 3600, .depth = 120, .sheds = 0.35 },
    .{ .o = .{ -800, -300 }, .a = .{ 0, 1 }, .n = .{ -1, 0 }, .len = 3000, .depth = 200, .sheds = 0.4 },
    .{ .o = .{ 2800, -300 }, .a = .{ 0, 1 }, .n = .{ 1, 0 }, .len = 3000, .depth = 200, .sheds = 0.3 },
};
const ROAD_W0: f32 = 6;
const ROAD_W1: f32 = 13;

fn stripPoint(st: Strip, u: f32, w: f32, z: f32) [3]f32 {
    return .{ st.o[0] + st.a[0] * u + st.n[0] * w, st.o[1] + st.a[1] * u + st.n[1] * w, z };
}

// The shore's layout is drawn from its own generator, so it never changes
// with the game's.
var shore_rng: u32 = 0;

fn shoreRand(lo: f32, hi: f32) f32 {
    shore_rng ^= shore_rng << 13;
    shore_rng ^= shore_rng >> 17;
    shore_rng ^= shore_rng << 5;
    return lo + (hi - lo) * @as(f32, @floatFromInt(shore_rng & 0xFFFF)) / 65535.0;
}

// Whether a point on the shore is at least r clear of the hills' feet and
// the investors' office.
fn shoreClear(p: [3]f32, r: f32) bool {
    for (HILLS) |h| {
        const dx = p[0] - h[0];
        const dy = p[1] - h[1];
        if (dx * dx + dy * dy < (h[2] + r) * (h[2] + r)) return false;
    }
    return p[0] < OFFICE[0] - r or p[0] > OFFICE[2] + r or p[1] < OFFICE[1] - r or p[1] > OFFICE[3] + r;
}

// A shed `len` along the shore and `dep` deep, `w0` in from the seawall,
// with walls h high under a pitched roof whose ridge runs along the shore,
// or a flat one when pitch is 0. A concrete apron runs from the road to its
// doors.
fn shed(st: Strip, ua: f32, w0: f32, len: f32, dep: f32, h: f32, pitch: f32) void {
    const z0 = SHORE_Z;
    const ze = z0 + h;
    face(&.{ stripPoint(st, ua, ROAD_W1, z0 + 0.02), stripPoint(st, ua + len, ROAD_W1, z0 + 0.02), stripPoint(st, ua + len, w0, z0 + 0.02), stripPoint(st, ua, w0, z0 + 0.02) }, .concrete, .{ 0, 0, 1 });
    const a = stripPoint(st, ua, w0, z0);
    const c = stripPoint(st, ua + len, w0 + dep, z0);
    if (pitch == 0) {
        boxM(a[0], a[1], z0, c[0], c[1], ze, .shed, .shed_roof, NO_BOTTOM);
        return;
    }
    const mid = stripPoint(st, ua + len * 0.5, w0 + dep * 0.5, z0 + h * 0.5);
    const zr = ze + pitch;
    const corner = [_][2]f32{ .{ ua, w0 }, .{ ua + len, w0 }, .{ ua + len, w0 + dep }, .{ ua, w0 + dep } };
    var lo: [4][3]f32 = undefined;
    var hi: [4][3]f32 = undefined;
    for (corner, 0..) |k, i| {
        lo[i] = stripPoint(st, k[0], k[1], z0);
        hi[i] = stripPoint(st, k[0], k[1], ze);
    }
    const r0 = stripPoint(st, ua, w0 + dep * 0.5, zr);
    const r1 = stripPoint(st, ua + len, w0 + dep * 0.5, zr);
    faceAway(&.{ lo[0], lo[1], hi[1], hi[0] }, .shed, mid);
    faceAway(&.{ lo[3], lo[2], hi[2], hi[3] }, .shed, mid);
    faceAway(&.{ lo[0], lo[3], hi[3], r0, hi[0] }, .shed, mid);
    faceAway(&.{ lo[1], lo[2], hi[2], r1, hi[1] }, .shed, mid);
    faceAway(&.{ hi[0], hi[1], r1, r0 }, .shed_roof, mid);
    faceAway(&.{ hi[3], hi[2], r1, r0 }, .shed_roof, mid);
}

// A tree on the shore: a trunk under a five-sided crown, which narrows
// from a flat underside to a cone, tall and slim for a cypress and broad
// for an oak. The crown's planes all pass clear of the trunk, and the BSP
// never splits along the trunk's own, so neither cuts the other.
fn plantTree(x: f32, y: f32, r: f32, h: f32, cypress: bool) void {
    const z = SHORE_Z;
    const base = z + (if (cypress) @as(f32, 0.8) else h * 0.25);
    prism(x, y, 0.25 + r * 0.04, 3, z, base, 1.0, .trunk, .trunk, .none, 0);
    const shoulder = base + (z + h - base) * (if (cypress) @as(f32, 0.15) else 0.45);
    prism(x, y, r, 5, base, shoulder, if (cypress) @as(f32, 0.85) else 0.8, .tree, .tree, .cone, z + h);
    var ring: [5][3]f32 = undefined;
    for (0..5) |i| {
        const a = (@as(f32, @floatFromInt(i)) + 0.5) * 2.0 * std.math.pi / 5.0;
        ring[i] = .{ x + r * @cos(a), y + r * @sin(a), base };
    }
    face(&ring, .tree, .{ 0, 0, -1 });
}

// A low clump of scrub.
fn bush(x: f32, y: f32, r: f32) void {
    prism(x, y, r, 5, SHORE_Z, SHORE_Z + r * 0.3, 0.75, .scrub, .scrub, .cone, SHORE_Z + r * 0.65);
}

// Trees scattered over a stretch of shore, n of them, oaks with the odd
// cypress, and clumps of scrub among them.
fn grove(st: Strip, ua: f32, ub: f32, w0: f32, w1: f32, n: usize) void {
    for (0..n) |_| {
        const r = shoreRand(2.5, 5.0);
        const p = stripPoint(st, shoreRand(ua, ub), shoreRand(w0, w1), 0);
        if (!shoreClear(p, r + 2)) continue;
        cur_seed = @intFromFloat(shoreRand(0, 7.99));
        if (shoreRand(0, 1) < 0.25) plantTree(p[0], p[1], r * 0.7, shoreRand(10, 16), true) else plantTree(p[0], p[1], r, shoreRand(7, 12), false);
    }
    for (0..@intFromFloat(shoreRand(1, 3.99))) |_| {
        const p = stripPoint(st, shoreRand(ua, ub), shoreRand(ROAD_W1 + 4, w1), 0);
        if (shoreClear(p, 6)) bush(p[0], p[1], shoreRand(2.5, 5));
    }
}

// Along each shore, plots in turn: a shed or two on hardstanding, or a
// grove. Sheds keep a seed with the shore's index in its low two bits and
// a colour above them.
fn buildShore() void {
    shore_rng = 0x2545F491;
    for (STRIPS, 0..) |st, si| {
        var u = shoreRand(10, 40);
        while (u < st.len - 50) {
            const len = shoreRand(35, 80);
            const dep = shoreRand(22, 38);
            const w0 = shoreRand(ROAD_W1 + 6, ROAD_W1 + 12);
            const fits = shoreClear(stripPoint(st, u, w0, 0), 12) and shoreClear(stripPoint(st, u + len, w0, 0), 12) and
                shoreClear(stripPoint(st, u, w0 + dep, 0), 12) and shoreClear(stripPoint(st, u + len, w0 + dep, 0), 12);
            if (fits and shoreRand(0, 1) < st.sheds) {
                cur_seed = @intCast(si | (@as(usize, @intFromFloat(shoreRand(0, 7.99))) << 2));
                const flat = shoreRand(0, 1) < 0.3;
                shed(st, u, w0, len, dep, if (flat) shoreRand(8, 13) else shoreRand(6, 9), if (flat) 0 else shoreRand(2, 4));
                const back = w0 + dep + 14;
                if (st.depth - back > 50 and shoreRand(0, 1) < 0.6) {
                    const dep2 = shoreRand(25, @min(45, st.depth - back - 15));
                    const len2 = shoreRand(30, len);
                    const at = u + shoreRand(0, len - len2);
                    if (shoreClear(stripPoint(st, at, back + dep2, 0), 12) and shoreClear(stripPoint(st, at + len2, back + dep2, 0), 12)) {
                        cur_seed = @intCast(si | (@as(usize, @intFromFloat(shoreRand(0, 7.99))) << 2));
                        shed(st, at, back, len2, dep2, shoreRand(6, 10), shoreRand(2, 3.5));
                    }
                } else if (shoreRand(0, 1) < 0.5) {
                    grove(st, u, u + len, back, st.depth - 6, 3);
                }
            } else {
                grove(st, u, u + len, ROAD_W1 + 4, st.depth - 6, @intFromFloat(shoreRand(3, 7.99)));
            }
            u += len + shoreRand(12, 30);
        }
    }
    // The investors' grounds, planted on either side of their office.
    for (0..4) |k| {
        const y = OFFICE[1] + 4 + 13 * @as(f32, @floatFromInt(k));
        cur_seed = @intCast(k);
        plantTree(OFFICE[0] - 12, y, 3.5, 10, k % 2 == 1);
        plantTree(OFFICE[2] + 12, y, 3.5, 10, k % 2 == 0);
    }
    cur_seed = 0;
}

fn buildBay() void {
    cur_inside = false;
    cur_seed = 0;
    face(&.{ .{ -9000, -9000, 0 }, .{ 12000, -9000, 0 }, .{ 12000, 12000, 0 }, .{ -9000, 12000, 0 } }, .water, .{ 0, 0, 1 });
    var mud: [MUD.len][3]f32 = undefined;
    for (MUD, 0..) |p, i| mud[i] = .{ p[0], p[1], 0.04 };
    face(&mud, .mud, .{ 0, 0, 1 });

    // The shores, walled, with sheds and trees along them, and the hills
    // behind them.
    for (SHORES, 0..) |s, i| {
        cur_seed = @intCast(i);
        boxM(s[0], s[1], 0, s[2], s[3], SHORE_Z, .seawall, .land, NO_BOTTOM);
        addObstacleRect(s[0], s[1], s[2], s[3]);
    }
    buildShore();
    for (HILLS, 0..) |h, i| {
        cur_seed = @intCast(i);
        prism(h[0], h[1], h[2], 9, 0, h[3], 0.3, .hills, .hills, .flat, 0);
    }
    cur_seed = 0;

    // The company's pier, with its sign facing the berth.
    boxM(14, -300, 0, 24, 30, 2.6, .concrete, .wood, NO_BOTTOM);
    addObstacleRect(14, -300, 24, 30);
    box(14.2, -32, 2.6, 14.6, -8, 5.2, .wood);
    cur_seed = 0;
    faceUV(&.{ .{ 14.18, -31, 2.8 }, .{ 14.18, -9, 2.8 }, .{ 14.18, -9, 5.0 }, .{ 14.18, -31, 5.0 } }, .sign, .{ -1, 0, 0 }, .{ 14.18, -9, 5.0 }, .{ 0, -1.0 / 22.0, 0 }, .{ 0, 0, -1.0 / 2.2 });

    // The bridge: a deck high overhead on piers every 80 m, with a wide
    // navigation span between two towers.
    boxM(BRIDGE_X0, BRIDGE_Y - BRIDGE_HALF, BRIDGE_DECK, BRIDGE_X1, BRIDGE_Y + BRIDGE_HALF, BRIDGE_DECK + 2.0, .bridge, .concrete, 0);
    for (0..PIER_COUNT) |k| {
        if (k == NAV_SKIP[0] or k == NAV_SKIP[1]) continue;
        const x = PIER_X0 + PIER_STEP * @as(f32, @floatFromInt(k));
        const tower = k == NAV_TOWERS[0] or k == NAV_TOWERS[1];
        const top: f32 = if (tower) 48 else BRIDGE_DECK;
        const hw: f32 = if (tower) 4.0 else 2.5;
        boxM(x - hw, BRIDGE_Y - BRIDGE_HALF - 2, 0, x + hw, BRIDGE_Y + BRIDGE_HALF + 2, top, .bridge, .bridge, NO_BOTTOM | (if (tower) 0 else NO_TOP));
        addObstacleRect(x - hw, BRIDGE_Y - BRIDGE_HALF - 2, x + hw, BRIDGE_Y + BRIDGE_HALF + 2);
    }

    // Rocky islands ringed with beaches, one with a lighthouse.
    for (ISLANDS, 0..) |isl, i| {
        cur_seed = @intCast(i);
        prism(isl.x, isl.y, isl.r, ISLAND_SIDES, 0, isl.beach, isl.rock / isl.r, .sand, .sand, .none, 0);
        prism(isl.x, isl.y, isl.rock, ISLAND_SIDES, isl.beach, isl.h, isl.taper, .rock, .rock_top, .flat, 0);
        var plan: [ISLAND_SIDES][2]f32 = undefined;
        for (0..ISLAND_SIDES) |k| {
            const a = (@as(f32, @floatFromInt(k)) + 0.5) * 2.0 * std.math.pi / @as(f32, @floatFromInt(ISLAND_SIDES));
            plan[k] = .{ isl.x + isl.rock * @cos(a), isl.y + isl.rock * @sin(a) };
        }
        addObstaclePoly(&plan);
    }
    cur_seed = 0;
    prism(1900, 1500, 3.0, 8, 28, 40, 0.8, .lighthouse, .lighthouse, .flat, 0);
    prism(1900, 1500, 2.6, 8, 40, 42, 1.0, .frame, .buoy_red, .cone, 44);

    // A freighter at anchor, loaded with containers.
    var plan: [SHIP_PLAN.len][2]f32 = undefined;
    for (SHIP_PLAN, 0..) |p, i| plan[i] = shipPoint(p);
    extrude(&plan, 0, 14, .ship, .ship_deck);
    addObstaclePoly(&plan);
    var k: usize = 0;
    while (k < 7) : (k += 1) {
        cur_seed = @intCast(k + 3);
        const along = -60 + 22 * @as(f32, @floatFromInt(k));
        const c = shipPoint(.{ along, 0 });
        turnedBox(c[0], c[1], SHIP_A, 9.5, 12.5, 14, 14 + 2.6 * @as(f32, @floatFromInt(2 + (k * 5) % 3)), .container, .container);
    }
    cur_seed = 0;
    const house = shipPoint(.{ -95, 0 });
    turnedBox(house[0], house[1], SHIP_A, 9, 13, 14, 32, .ship_white, .ship_white);

    // The investors' pier, its sign, and their office on the shore.
    boxM(2000, 2350, 0, 2014, 2700, 2.6, .concrete, .wood, NO_BOTTOM);
    addObstacleRect(2000, 2350, 2014, 2700);
    box(1999.6, 2440, 2.6, 2000, 2484, 7.0, .wood);
    cur_seed = 1;
    faceUV(&.{ .{ 1999.58, 2442, 2.8 }, .{ 1999.58, 2482, 2.8 }, .{ 1999.58, 2482, 6.8 }, .{ 1999.58, 2442, 6.8 } }, .sign, .{ -1, 0, 0 }, .{ 1999.58, 2482, 6.8 }, .{ 0, -1.0 / 40.0, 0 }, .{ 0, 0, -1.0 / 4.0 });
    cur_seed = 0;
    boxM(OFFICE[0], OFFICE[1], SHORE_Z, OFFICE[2], OFFICE[3], 18, .building, .concrete, NO_BOTTOM);

    // The sandbanks, and the reefs' rocks.
    for (BANKS, &BANK_OUTLINES) |b, *o| sandbank(o, b.h);
    for (REEFS, &REEF_OUTLINES, 0..) |r, *o, i| reef(r, o, i);
    cur_seed = 0;

    // Buoys either side of the deep-water channel, red to starboard heading
    // out, leaving out the legs under the bridge and up to the pier, and
    // yellow ones marking the berth.
    var i: usize = 1;
    while (i + 1 < RIVAL_ROUTE.len) : (i += 1) {
        if (i == 4) continue;
        const a = RIVAL_ROUTE[i - 1];
        const b = RIVAL_ROUTE[i];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len = @sqrt(dx * dx + dy * dy);
        const m: [2]f32 = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
        buoy(m[0] + dy / len * 35, m[1] - dx / len * 35, .buoy_red);
        buoy(m[0] - dy / len * 35, m[1] + dx / len * 35, .buoy_green);
    }
    buoy(BERTH[0] - 36, BERTH[1] - 30, .buoy_yellow);
    buoy(BERTH[0] - 36, BERTH[1] + 30, .buoy_yellow);
}

// A sandbank: its flat crest, and a face sloping down to the water from each
// edge. Each corner of the foot is pushed out along its bisector, so the
// faces are planar and meet the crest's edges in parallel lines.
fn sandbank(o: *const Outline, h: f32) void {
    var top: [MAX_OUTLINE][3]f32 = undefined;
    var foot: [MAX_OUTLINE][3]f32 = undefined;
    for (0..o.n) |i| {
        const n1 = o.ns[(i + o.n - 1) % o.n];
        const n2 = o.ns[i];
        const b = norm3(.{ n1[0] + n2[0], n1[1] + n2[1], 0 });
        const k = BANK_RUN / (b[0] * n2[0] + b[1] * n2[1]);
        top[i] = .{ o.pts[i][0], o.pts[i][1], h };
        foot[i] = .{ o.pts[i][0] + b[0] * k, o.pts[i][1] + b[1] * k, 0 };
    }
    for (0..o.n) |i| {
        const j = (i + 1) % o.n;
        face(&.{ foot[i], foot[j], top[j], top[i] }, .sand, .{ o.ns[i][0], o.ns[i][1], 0 });
    }
    face(top[0..o.n], .sand, .{ 0, 0, 1 });
}

// A reef: a few rocks just breaking the surface along its length, and the
// whole of it in the bay's obstacles.
fn reef(p: Patch, o: *const Outline, i: usize) void {
    const c = @cos(p.a);
    const s = @sin(p.a);
    for ([_][3]f32{ .{ -0.55, 0.2, 0.35 }, .{ 0.05, -0.25, 0.45 }, .{ 0.6, 0.15, 0.3 } }, 0..) |q, k| {
        const lx = q[0] * p.hl;
        const ly = q[1] * p.hw;
        const r = q[2] * p.hw;
        cur_seed = @intCast((i * 3 + k) % SHARED_SEEDS);
        const h = 0.4 + 0.1 * r;
        prism(p.x + lx * c - ly * s, p.y + lx * s + ly * c, r, 5, 0, h, 0.6, .rock, .rock, .cone, h + 0.3 * r);
    }
    addObstaclePoly(o.pts[0..o.n]);
}

// The BSP
//
// Each tree is built from its polygons' own planes, so it orders them
// front to back from any eye. Building runs without recursion: each pending
// list sits at the top of the scratch array, and a partition writes its back
// list then its front list over its parent.

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

var bnodes: [MAX_BNODES]BNode = undefined;
var bnode_count: usize = 0;
var bsp_polys: [MAX_POLYS]u32 = undefined;
var bsp_poly_count: usize = 0;
var bsp_scratch: [MAX_POLYS]u32 = undefined;
var bsp_front: [MAX_POLYS]u32 = undefined;
var bsp_back: [MAX_POLYS]u32 = undefined;

const Class = enum { on, front, back, split };

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

fn splitPoly(pi: u32, nx: f32, ny: f32, nz: f32, d: f32, out_front: *u32, out_back: *u32) void {
    const p = polys[pi];
    var f: [MAX_POLY_N][3]f32 = undefined;
    var b: [MAX_POLY_N][3]f32 = undefined;
    var nf: usize = 0;
    var nb: usize = 0;
    var i: u32 = 0;
    while (i < p.n) : (i += 1) {
        const a = pverts[p.first + i];
        const c = pverts[p.first + (i + 1) % p.n];
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

// A splitting plane, and the polygon it came from, if any, which lies on it
// whatever rounding says.
const Plane = struct { nx: f32, ny: f32, nz: f32, d: f32, src: u32 = NO_SRC };
const NO_SRC = std.math.maxInt(u32);

// How badly a plane divides a list: the polygons it splits, weighted, plus
// how uneven it leaves the two sides. A plane that holds none of them and
// leaves one side empty makes no progress, so it never wins.
fn splitScore(list: []const u32, c: Plane) usize {
    var front: usize = 0;
    var back: usize = 0;
    var on: usize = 0;
    var splits: usize = 0;
    for (list) |pi| {
        switch (if (pi == c.src) .on else polySide(polys[pi], c.nx, c.ny, c.nz, c.d)) {
            .on => on += 1,
            .front => front += 1,
            .back => back += 1,
            .split => splits += 1,
        }
    }
    if (on == 0 and (front == 0 or back == 0)) return std.math.maxInt(usize);
    const balance = if (front > back) front - back else back - front;
    return splits * 60 + balance;
}

// Of a few candidates spread through the list, the plane that splits the
// fewest polygons and leaves the two sides most even. Long lists also try
// upright planes across the bay, which can pass between the trees and sheds
// along a shore where any of their own faces' planes would cut through
// dozens of them.
fn chooseSplitter(list: []const u32) Plane {
    const tries: usize = if (list.len > 2000) 8 else if (list.len > 300) 16 else 24;
    const stride = @max(1, list.len / tries);
    var best: Plane = undefined;
    var best_score: usize = std.math.maxInt(usize);
    // A trunk's planes run up through its crown, so trunks are only tried
    // when nothing else is.
    for ([_]bool{ false, true }) |trunks| {
        if (best_score != std.math.maxInt(usize)) break;
        var i: usize = 0;
        while (i < list.len) : (i += stride) {
            const p = polys[list[i]];
            if ((surfs[p.surf].mat == .trunk) != trunks) continue;
            const c: Plane = .{ .nx = p.nx, .ny = p.ny, .nz = p.nz, .d = p.d, .src = list[i] };
            const score_ = splitScore(list, c);
            if (score_ < best_score) {
                best_score = score_;
                best = c;
            }
        }
    }
    if (list.len < 64) return best;
    var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (list) |pi| {
        const p = polys[pi];
        const v = pverts[p.first];
        for (0..2) |a| {
            lo[a] = @min(lo[a], v[a]);
            hi[a] = @max(hi[a], v[a]);
        }
    }
    for (0..2) |a| {
        for (1..12) |k| {
            const at = lo[a] + (hi[a] - lo[a]) * @as(f32, @floatFromInt(k)) / 12.0;
            const c: Plane = .{ .nx = if (a == 0) 1 else 0, .ny = if (a == 1) 1 else 0, .nz = 0, .d = at };
            const score_ = splitScore(list, c);
            if (score_ < best_score) {
                best_score = score_;
                best = c;
            }
        }
    }
    return best;
}

const BspItem = struct { start: usize, len: usize, parent: i32, is_front: bool, depth: usize };

fn buildTree(first: usize, count: usize) Tree {
    var tree: Tree = .{ .root = @intCast(bnode_count), .first = first, .polys = count };
    for (0..count) |i| bsp_scratch[i] = @intCast(first + i);
    var stack: [BSP_STACK]BspItem = undefined;
    stack[0] = .{ .start = 0, .len = count, .parent = -1, .is_front = true, .depth = 1 };
    var sp: usize = 1;
    const node0 = bnode_count;
    while (sp > 0) {
        sp -= 1;
        const item = stack[sp];
        if (item.len == 0) continue;
        if (bnode_count >= MAX_BNODES) @trap();
        tree.depth = @max(tree.depth, item.depth);
        const list = bsp_scratch[item.start .. item.start + item.len];
        const c = chooseSplitter(list);
        const ni = bnode_count;
        bnode_count += 1;
        bnodes[ni] = .{ .nx = c.nx, .ny = c.ny, .nz = c.nz, .d = c.d, .first = @intCast(bsp_poly_count) };
        if (item.parent >= 0) {
            const parent = &bnodes[@intCast(item.parent)];
            if (item.is_front) parent.front = @intCast(ni) else parent.back = @intCast(ni);
        }
        var nf: usize = 0;
        var nb: usize = 0;
        for (list) |pi| {
            switch (if (pi == c.src) .on else polySide(polys[pi], c.nx, c.ny, c.nz, c.d)) {
                .on => {
                    bsp_polys[bsp_poly_count] = pi;
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
        bnodes[ni].count = @as(u32, @intCast(bsp_poly_count)) - bnodes[ni].first;
        if (item.start + nb + nf > MAX_POLYS or sp + 2 > BSP_STACK) @trap();
        @memcpy(bsp_scratch[item.start .. item.start + nb], bsp_back[0..nb]);
        @memcpy(bsp_scratch[item.start + nb .. item.start + nb + nf], bsp_front[0..nf]);
        stack[sp] = .{ .start = item.start, .len = nb, .parent = @intCast(ni), .is_front = false, .depth = item.depth + 1 };
        stack[sp + 1] = .{ .start = item.start + nb, .len = nf, .parent = @intCast(ni), .is_front = true, .depth = item.depth + 1 };
        sp += 2;
    }
    if (bnode_count == node0) tree.root = -1;
    // Children come after their parents, so a backward pass gathers bounds.
    var i = bnode_count;
    while (i > node0) {
        i -= 1;
        const n = &bnodes[i];
        var lo: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
        var hi: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (bsp_polys[n.first .. n.first + n.count]) |pi| {
            const p = polys[pi];
            for (pverts[p.first .. p.first + p.n]) |v| {
                for (0..3) |a| {
                    lo[a] = @min(lo[a], v[a]);
                    hi[a] = @max(hi[a], v[a]);
                }
            }
        }
        for ([_]i32{ n.front, n.back }) |ch| {
            if (ch < 0) continue;
            const cn = bnodes[@intCast(ch)];
            for (0..3) |a| {
                lo[a] = @min(lo[a], cn.lo[a]);
                hi[a] = @max(hi[a], cn.hi[a]);
            }
        }
        n.lo = lo;
        n.hi = hi;
    }
    return tree;
}

// Lighting

fn hourNow() f32 {
    return FIRST_HOUR + DAY_HOURS * @as(f32, @floatFromInt(@min(time_ms, DAY_MS))) / @as(f32, @floatFromInt(DAY_MS));
}

// The unit vector toward the sun, east, north, up, from its hour angle and
// declination at San Francisco's latitude.
fn sunDir() [3]f32 {
    const h = (hourNow() - 12.0) * (std.math.pi / 12.0);
    const sl = @sin(SF_LATITUDE);
    const cl = @cos(SF_LATITUDE);
    const sd = @sin(SUN_DECLINATION);
    const cd = @cos(SUN_DECLINATION);
    return .{ -cd * @sin(h), cl * sd - sl * cd * @cos(h), sl * sd + cl * cd * @cos(h) };
}

var sun: [3]f32 = .{ 0, -0.5, 0.85 };
// The craft's heading as a rotation, worked out once a frame for the water.
var frame_c: f32 = 1;
var frame_s: f32 = 0;
var frame_deck: f32 = DECK_HOVER;
// The sun in the frame of the pass being drawn.
var sun_pass: [3]f32 = .{ 0, -0.5, 0.85 };

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

fn rgbHex(v: u32) Rgb {
    return .{ @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0, @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0, @as(f32, @floatFromInt(v & 0xFF)) / 255.0 };
}

// Fluorescent panels in rows down the cabin, and daylight from the windows
// along the sides.
fn interiorLight(n: [3]f32, x: f32, y: f32) f32 {
    var l = 0.5 + 0.26 * maxf(0, n[2]) - 0.1 * maxf(0, -n[2]);
    const dx = frac((x + 11.5) / 4.5 + 0.5) - 0.5;
    const dy = frac((y + 5.5) / 5.5 + 0.5) - 0.5;
    l += 0.14 * clampf(1.0 - 3.0 * (dx * dx + dy * dy), 0, 1) * maxf(0.3, n[2]);
    l += 0.16 * clampf((@abs(y) - 5.0) / 3.0, 0, 1) * clampf(sun[2] * 1.5, 0.3, 1);
    return l;
}

fn outdoorLight(n: [3]f32) f32 {
    return 0.42 + 0.1 * n[2] + 0.68 * maxf(0, n[0] * sun_pass[0] + n[1] * sun_pass[1] + n[2] * sun_pass[2]);
}

const FOG: Rgb = .{ 0.8, 0.83, 0.86 };

// Bay haze, thickest toward the Golden Gate's afternoon fog.
inline fn fog(c: Rgb, t: f32) Rgb {
    return mix(c, FOG, clampf(t / (t + 2600.0), 0, 0.85));
}

fn skyColor(rx: f32, ry: f32, vz: f32, clouds: bool) Rgb {
    if (flat_shading) return .{ 0.5, 0.7, 0.9 };
    const len = @sqrt(rx * rx + ry * ry + vz * vz);
    const el = clampf(vz / len, 0.0, 1.0);
    var c = mix(FOG, .{ 0.34, 0.55, 0.85 }, @sqrt(el));
    const sd = (rx * sun[0] + ry * sun[1] + vz * sun[2]) / len;
    if (sd > 0.98) {
        const g = (sd - 0.98) / 0.02;
        c = mix(c, .{ 1.0, 0.97, 0.88 }, g * g * 0.35);
        if (sd > 0.9997) c = .{ 1.0, 0.99, 0.95 };
    }
    if (clouds and vz > 0.02) {
        const k = 1.0 / vz;
        const drift = @as(f32, @floatFromInt(anim_ms)) * 0.00003;
        const n = valueNoise(rx * k * 0.9 + drift, ry * k * 1.8) * 0.65 + valueNoise(rx * k * 3.0, ry * k * 4.5) * 0.35;
        const cloud = clampf((n - 0.58) * 3.0, 0.0, 1.0) * clampf(el * 5.0, 0.0, 1.0);
        c = mix(c, .{ 0.97, 0.96, 0.94 }, cloud * 0.75);
    }
    return c;
}

// Materials

fn surfUV(s: Surf, x: f32, y: f32, z: f32) [2]f32 {
    const d: [3]f32 = .{ x - s.o[0], y - s.o[1], z - s.o[2] };
    return .{ dot3(d, s.u), dot3(d, s.v) };
}

// Whether (cx, cy), in the font's pixels, falls on a lit pixel of text.
fn textBit(text: []const u8, cx: f32, cy: f32) bool {
    if (cx < 0 or cy < 0 or cy >= 5) return false;
    const col: usize = @intFromFloat(cx);
    const ch = col / 4;
    const bx = col % 4;
    if (ch >= text.len or bx == 3) return false;
    const row: u4 = @intFromFloat(cy);
    const shift: u4 = 14 - (row * 3 + @as(u4, @intCast(bx)));
    return ((glyph(text[ch]) >> shift) & 1) != 0;
}

// Text centred on a face whose (u, v) runs 0 to 1, with aspect its width
// over its height, filling at most `fill` of the height.
fn signText(text: []const u8, u: f32, v: f32, aspect: f32, fill: f32) bool {
    const cols: f32 = @floatFromInt(text.len * 4 - 1);
    var pv = fill / 5.0;
    var pu = pv / aspect;
    if (pu * cols > 0.92) {
        pu = 0.92 / cols;
        pv = pu * aspect;
    }
    return textBit(text, (u - (0.5 - pu * cols * 0.5)) / pu, (v - (0.5 - pv * 2.5)) / pv);
}

const SIGNS = [_][]const u8{ "HOVERCRAFTSMAN HQ", "SAND HILL CAPITAL" };
const CONTAINER_COLORS = [_]Rgb{ .{ 0.32, 0.52, 0.68 }, .{ 0.62, 0.2, 0.13 }, .{ 0.22, 0.42, 0.28 }, .{ 0.85, 0.5, 0.15 }, .{ 0.55, 0.55, 0.55 }, .{ 0.7, 0.62, 0.2 } };
// The Mercedes C111's orange.
const ORANGE: Rgb = .{ 0.95, 0.4, 0.07 };
const BLACK_GLOSS: Rgb = .{ 0.035, 0.035, 0.04 };

const SHED_COLORS = [_]Rgb{ .{ 0.82, 0.78, 0.66 }, .{ 0.55, 0.26, 0.2 }, .{ 0.45, 0.55, 0.47 }, .{ 0.5, 0.56, 0.62 }, .{ 0.72, 0.72, 0.7 }, .{ 0.35, 0.5, 0.52 }, .{ 0.7, 0.6, 0.45 }, .{ 0.88, 0.87, 0.83 } };
// Live oak, eucalyptus, and a darker green for cypress and pine.
const TREE_COLORS = [_]Rgb{ .{ 0.17, 0.25, 0.11 }, .{ 0.3, 0.36, 0.26 }, .{ 0.12, 0.2, 0.11 }, .{ 0.2, 0.28, 0.13 } };

// The shore's ground: grass, gold where it has dried and green where it
// hasn't, with dark patches of scrub, trodden paths, and the quayside road.
fn landColor(x: f32, y: f32, t: f32) Rgb {
    for (STRIPS) |st| {
        const dx = x - st.o[0];
        const dy = y - st.o[1];
        const w = dx * st.n[0] + dy * st.n[1];
        const u = dx * st.a[0] + dy * st.a[1];
        if (w > ROAD_W0 and w < ROAD_W1 and u > -ROAD_W1 and u < st.len + ROAD_W1) {
            const line = @abs(w - (ROAD_W0 + ROAD_W1) * 0.5) < 0.15 and frac(u / 6.0) < 0.5 and t < 120.0;
            return if (line) Rgb{ 0.82, 0.78, 0.55 } else splat(0.27 + 0.05 * ripple(x * 0.9, y * 0.9));
        }
    }
    const fine = ripple(x * 0.35, y * 0.35);
    const green = valueNoise(x * 0.012, y * 0.012);
    var c = mix(.{ 0.62, 0.54, 0.32 }, .{ 0.38, 0.45, 0.22 }, clampf(green * 1.8 - 0.5, 0, 1)) * splat(0.88 + 0.22 * fine);
    const scrub = valueNoise(x * 0.04 + 31.0, y * 0.04) * 0.75 + ripple(x * 0.6, y * 0.6) * 0.25;
    c = mix(c, Rgb{ 0.22, 0.27, 0.14 } * splat(0.8 + 0.4 * fine), clampf((scrub - 0.58) * 10.0, 0, 1));
    const path = @abs(valueNoise(x * 0.008 + 5.0, y * 0.008) - 0.5);
    return mix(c, .{ 0.56, 0.47, 0.35 }, clampf((0.012 - path) * 150.0, 0, 0.85));
}

fn flatColor(seed: u32) Rgb {
    const h = hash2(@bitCast(seed), 77);
    return .{ @as(f32, @floatFromInt(h & 0xFF)) / 255.0, @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0, @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0 };
}

// The colour of a polygon's surface at depth t along a pixel's view ray,
// which has a forward component of one. Positions are in the frame of the
// pass being drawn.
fn shade(p: Poly, rx: f32, ry: f32, vz: f32, t: f32) Rgb {
    if (flat_shading) return flatColor(p.surf);
    const s = surfs[p.surf];
    const x = cam_x + rx * t;
    const y = cam_y + ry * t;
    const z = cam_z + vz * t;
    const n: [3]f32 = .{ p.nx, p.ny, p.nz };
    var albedo: Rgb = .{ 0.5, 0.5, 0.5 };
    var emit: Rgb = .{ 0, 0, 0 };
    var gloss: f32 = 0;
    switch (s.mat) {
        .water => return shadeWater(x, y, rx, ry, vz, t),
        .crt_mine => {
            const uv = surfUV(s, x, y, z);
            return crtPixel(uv[0], uv[1]);
        },
        .crt_saver => {
            const uv = surfUV(s, x, y, z);
            return saverPixel(uv[0], uv[1], s.seed);
        },
        .console_glow => {
            const uv = surfUV(s, x, y, z);
            return consolePixel(uv[0], uv[1]);
        },
        .light_panel => {
            const g = if (frac(x * 10.0) < 0.12 or frac(y * 10.0) < 0.12) @as(f32, 0.9) else 1.0;
            return splat(1.08 * g) * Rgb{ 1.0, 1.0, 0.96 };
        },
        .nav_red => return .{ 1.0, 0.15, 0.1 },
        .nav_green => return .{ 0.2, 1.0, 0.35 },
        .mud => {
            const nz = valueNoise(x * 0.08, y * 0.08) * 0.6 + valueNoise(x * 0.6, y * 0.6) * 0.4;
            albedo = mix(.{ 0.3, 0.27, 0.21 }, .{ 0.45, 0.39, 0.3 }, nz);
            gloss = 0.25 * clampf((0.55 - nz) * 4.0, 0, 1);
        },
        .sand => {
            // Wet and darker near the water, with ripples across the slope,
            // and on the low sand, puddles left by the tide.
            const wave = 0.5 + 0.5 * @sin((x + y) * 0.7 + valueNoise(x * 0.05, y * 0.05) * 6.0);
            albedo = mix(.{ 0.5, 0.44, 0.31 }, .{ 0.8, 0.72, 0.52 }, clampf(z * 0.6 + 0.1, 0, 1)) * splat(0.94 + 0.06 * wave);
            gloss = 0.3 * clampf(1.0 - z * 1.5, 0, 1);
            if (z < 0.8) {
                const pools = clampf((valueNoise(x * 0.06 + 3.0, y * 0.06) - 0.58) * 6.0, 0, 1) * clampf((0.8 - z) * 3.0, 0, 1);
                albedo = mix(albedo, .{ 0.3, 0.33, 0.28 }, pools * 0.7);
                gloss = maxf(gloss, 0.75 * pools);
            }
        },
        .land => albedo = landColor(x, y, t),
        .seawall => {
            const k = hashf(cell(x * 0.7 + y * 0.7), cell(z * 1.5));
            albedo = splat(0.38 + 0.18 * k) * Rgb{ 1.0, 0.97, 0.92 };
        },
        .shed => {
            // Ribbed cladding, with roller doors on the side facing the
            // water.
            const uv = surfUV(s, x, y, z);
            const st = STRIPS[s.seed & 3];
            const rib = 1.0 + 0.08 * @sin(uv[0] * 21.0) * clampf(1.0 - t / 80.0, 0, 1);
            albedo = SHED_COLORS[(s.seed >> 2) % SHED_COLORS.len] * splat(rib);
            const seaward = n[0] * st.n[0] + n[1] * st.n[1] < -0.5;
            if (seaward and z < SHORE_Z + 4.5 and frac(uv[0] / 16.0) > 0.2 and frac(uv[0] / 16.0) < 0.55) {
                albedo = splat(if (frac(z * 3.0) < 0.12) 0.4 else 0.5);
            }
        },
        .shed_roof => {
            // Corrugated iron, its ribs running down the slope, streaked
            // with rust.
            const st = STRIPS[s.seed & 3];
            const along = x * st.a[0] + y * st.a[1];
            const rib = 1.0 + 0.1 * @sin(along * 25.0) * clampf(1.0 - t / 60.0, 0, 1);
            const rust = valueNoise(along * 0.3, z * 2.0 + x * st.n[0] * 0.5 + y * st.n[1] * 0.5);
            const base: Rgb = if ((s.seed >> 2) % 3 == 0) .{ 0.5, 0.25, 0.18 } else .{ 0.6, 0.61, 0.6 };
            albedo = mix(base, .{ 0.45, 0.3, 0.2 }, clampf(rust * 1.5 - 0.8, 0, 0.6)) * splat(rib);
            gloss = 0.08;
        },
        .tree => {
            // Leaf clumps, which blur together further off.
            const leaves = ripple(x * 1.3 + z * 0.7, y * 1.3 - z * 0.7);
            albedo = TREE_COLORS[s.seed % TREE_COLORS.len] * splat(1.0 + (leaves - 0.5) * 0.7 * clampf(1.0 - t / 150.0, 0, 1));
        },
        .trunk => albedo = .{ 0.3, 0.25, 0.2 },
        .scrub => albedo = Rgb{ 0.3, 0.32, 0.18 } * splat(0.8 + 0.4 * ripple(x * 1.7 + z, y * 1.7)),
        .hills => {
            const k = valueNoise(x * 0.004 + @as(f32, @floatFromInt(s.seed)), y * 0.004) * 0.7 + valueNoise(x * 0.02, y * 0.02) * 0.3;
            albedo = mix(.{ 0.3, 0.36, 0.22 }, .{ 0.62, 0.54, 0.33 }, clampf(k * 1.3 - 0.15 + z * 0.0008, 0, 1));
            // Chaparral in the gullies, thinning out up the slopes.
            const chaparral = valueNoise(x * 0.012 + 17.0, y * 0.012) - z * 0.0006;
            albedo = mix(albedo, .{ 0.24, 0.29, 0.16 }, clampf((chaparral - 0.5) * 3.0, 0, 0.55));
        },
        .rock => {
            const band = hashf(cell(z * 1.2), @intCast(s.seed));
            albedo = splat(0.36 + 0.12 * band + 0.08 * valueNoise(x * 0.3 + y * 0.3, z * 0.5)) * Rgb{ 1.0, 0.94, 0.86 };
        },
        .rock_top => albedo = mix(.{ 0.42, 0.42, 0.26 }, .{ 0.6, 0.54, 0.34 }, valueNoise(x * 0.06, y * 0.06)),
        .concrete => {
            const seam = frac(x * 0.25) < 0.02 or frac(y * 0.25) < 0.02;
            albedo = splat(if (seam) 0.45 else 0.6 + 0.05 * valueNoise(x * 0.5, y * 0.5));
        },
        .wood => {
            const plank = hashf(cell(x * 4.0 + y * 0.01), cell(y * 0.3));
            albedo = Rgb{ 0.46, 0.34, 0.23 } * splat(0.9 + 0.15 * plank);
        },
        .sign => {
            const uv = surfUV(s, x, y, z);
            const border = uv[0] < 0.015 or uv[0] > 0.985 or uv[1] < 0.06 or uv[1] > 0.94;
            const text = signText(SIGNS[s.seed % SIGNS.len], uv[0], uv[1], 10.0, 0.6);
            albedo = if (text) (if (s.seed == 0) ORANGE else Rgb{ 0.1, 0.12, 0.3 }) else if (border) Rgb{ 0.15, 0.15, 0.15 } else Rgb{ 0.93, 0.92, 0.88 };
        },
        .bridge => albedo = splat(if (n[2] < -0.5) 0.38 else 0.6) * Rgb{ 1.0, 0.98, 0.95 },
        .building => {
            const win = frac(z / 3.5) > 0.3 and frac((x + y) / 2.5) > 0.15;
            albedo = if (win) Rgb{ 0.25, 0.32, 0.38 } else Rgb{ 0.85, 0.83, 0.78 };
            gloss = if (win) 0.4 else 0;
        },
        .ship => albedo = if (z < 4.0) Rgb{ 0.45, 0.13, 0.1 } else Rgb{ 0.1, 0.12, 0.17 } * splat(0.85 + 0.3 * valueNoise(x * 0.2 + y * 0.2, z * 0.05)),
        .ship_deck => albedo = .{ 0.25, 0.35, 0.26 },
        .ship_white => albedo = if (z > 27 and z < 29 and @abs(n[2]) < 0.5) Rgb{ 0.08, 0.1, 0.12 } else Rgb{ 0.88, 0.88, 0.85 },
        .container => {
            const uv = surfUV(s, x, y, z);
            albedo = CONTAINER_COLORS[s.seed % CONTAINER_COLORS.len] * splat(if (frac(uv[0] * 3.0) < 0.5) 0.85 else 1.0);
        },
        .lighthouse => albedo = if (z > 34 and z < 37) Rgb{ 0.75, 0.12, 0.1 } else Rgb{ 0.93, 0.93, 0.9 },
        .buoy_red => albedo = .{ 0.8, 0.12, 0.1 },
        .buoy_green => albedo = .{ 0.1, 0.55, 0.2 },
        .buoy_yellow => albedo = .{ 0.95, 0.8, 0.1 },
        .speedboat => {
            // White, with a red stripe along the sheer and a black boot-top.
            albedo = if (z < 0.25) Rgb{ 0.1, 0.1, 0.12 } else if (z > 0.5 and z < 0.68) Rgb{ 0.75, 0.08, 0.1 } else Rgb{ 0.92, 0.92, 0.9 };
            gloss = 0.3;
        },
        .boat_deck => albedo = .{ 0.84, 0.8, 0.72 },
        .boat_glass => {
            albedo = .{ 0.08, 0.1, 0.13 };
            gloss = 0.5;
        },
        .skin => albedo = .{ 0.78, 0.58, 0.45 },
        .hull, .roof => {
            albedo = ORANGE;
            gloss = 0.22;
        },
        .hull_band => {
            const band = z > 0.85 and z < 2.35;
            albedo = if (band) BLACK_GLOSS else ORANGE;
            gloss = if (band) 0.35 else 0.22;
        },
        .hull_name => {
            const uv = surfUV(s, x, y, z);
            albedo = if (signText("HOVERCRAFTSMAN", uv[0], uv[1], 35.0 / 0.98, 0.62)) BLACK_GLOSS else ORANGE;
            gloss = 0.22;
        },
        .hull_dark => {
            albedo = BLACK_GLOSS;
            gloss = 0.35;
        },
        .deck => albedo = splat(if (frac(x * 4.0) < 0.2 and frac(y * 4.0) < 0.2) 0.3 else 0.4),
        .skirt => {
            const finger = frac((x + y) * 1.4) < 0.08;
            albedo = splat(if (finger) 0.02 else 0.07);
        },
        .radome => albedo = .{ 0.92, 0.92, 0.88 },
        .duct_in => albedo = splat(0.12),
        .prop => return propPixel(s, x, y, z),
        .rudder => albedo = .{ 0.9, 0.9, 0.87 },
        .frame => albedo = .{ 0.14, 0.14, 0.15 },
        .carpet => {
            // Confetti flecks, which blur into the base colour further off.
            const speck = hashf(cell(x * 30.0), cell(y * 30.0));
            const fleck = if (speck > 0.96) Rgb{ 0.62, 0.28, 0.42 } else if (speck > 0.92) Rgb{ 0.25, 0.55, 0.55 } else Rgb{ 0.22, 0.25, 0.34 };
            albedo = mix(fleck, .{ 0.24, 0.27, 0.35 }, clampf((t - 2.0) / 5.0, 0, 1));
        },
        .ceiling => {
            const grid = frac(x / 0.6) < 0.03 or frac(y / 0.6) < 0.03;
            albedo = splat(if (grid) 0.6 else 0.86);
        },
        .wall_in => albedo = .{ 0.8, 0.76, 0.68 },
        .partition => albedo = if (z > PARTITION_H - 0.04) Rgb{ 0.72, 0.72, 0.74 } else Rgb{ 0.4, 0.45, 0.54 } * splat(0.9 + 0.2 * hashf(cell(x * 60.0 + y * 60.0), cell(z * 60.0))),
        .desk => albedo = .{ 0.63, 0.61, 0.57 },
        .crt_case => {
            // Vent slots on the back of the tube.
            const vents = n[2] > 0.3 and frac(x * 40.0 + y * 40.0) < 0.35;
            albedo = if (vents) Rgb{ 0.5, 0.47, 0.4 } else Rgb{ 0.82, 0.78, 0.67 };
        },
        .keyboard => {
            const gap = n[2] > 0.5 and (frac(x / 0.019) < 0.18 or frac(y / 0.019) < 0.18);
            albedo = if (gap) Rgb{ 0.5, 0.48, 0.42 } else Rgb{ 0.84, 0.81, 0.72 };
        },
        .chair => albedo = .{ 0.13, 0.15, 0.26 },
        .console => albedo = .{ 0.18, 0.18, 0.2 },
        .whiteboard => {
            const uv = surfUV(s, x, y, z);
            albedo = whiteboardPixel(uv[0], uv[1]);
        },
        .rack => {
            albedo = splat(0.07);
            if (n[0] > 0.5) {
                const row = cell(z * 22.0);
                const col = cell(y * 30.0);
                if (frac(z * 22.0) > 0.6 and frac(y * 30.0) > 0.6) {
                    const on = hash2(row * 7 + col, @divTrunc(anim_ms, 180) + row) & 3 != 0;
                    if (on) emit = if (hash2(row, col) & 1 == 0) Rgb{ 0.1, 0.9, 0.2 } else Rgb{ 0.95, 0.6, 0.1 };
                }
            }
        },
        .cooler => albedo = .{ 0.88, 0.88, 0.86 },
        .bottle => {
            albedo = .{ 0.45, 0.65, 0.85 };
            emit = .{ 0.05, 0.08, 0.12 };
        },
        .foosball => {
            const line = @abs(x + 10.8) < 0.01 or frac(y * 2.0) < 0.02;
            albedo = if (line) Rgb{ 0.85, 0.85, 0.85 } else Rgb{ 0.15, 0.45, 0.2 };
        },
        .pizza => albedo = if (n[2] > 0.5 and @abs(frac(x * 4.0) - 0.5) < 0.2) Rgb{ 0.7, 0.2, 0.15 } else Rgb{ 0.72, 0.58, 0.38 },
    }
    const light = if (s.inside) interiorLight(n, x, y) else outdoorLight(n);
    var c = albedo * splat(light) + emit;
    if (gloss > 0) {
        // A glossy coat reflects the sky, more at grazing angles.
        const len = @sqrt(rx * rx + ry * ry + vz * vz);
        const dn = (rx * n[0] + ry * n[1] + vz * n[2]) / len;
        const f = 1.0 + dn;
        const fres = 0.06 + 0.94 * f * f * f * f * f;
        const r: [3]f32 = .{ rx / len - 2 * dn * n[0], ry / len - 2 * dn * n[1], vz / len - 2 * dn * n[2] };
        const refl = if (s.inside) Rgb{ 0.75, 0.74, 0.7 } else skyColor(r[0], r[1], r[2], false);
        c = mix(c, refl, gloss * fres + gloss * 0.15);
    }
    if (!s.inside) c = fog(c, t);
    return c;
}

// Value noise baked into a tiling table at startup, so the water's ripples
// cost a few loads a pixel rather than four hashes.
const RIPPLE_N: usize = 64;
var ripple_tex: [RIPPLE_N * RIPPLE_N]f32 = undefined;
var ripple_ready = false;

fn bakeRipples() void {
    if (ripple_ready) return;
    for (0..RIPPLE_N) |j| {
        for (0..RIPPLE_N) |i| {
            const fi: f32 = @floatFromInt(i);
            const fj: f32 = @floatFromInt(j);
            // Two octaves that wrap at the table's edge.
            var v: f32 = 0;
            for ([_]f32{ 8, 16 }, [_]f32{ 0.65, 0.35 }) |period, w| {
                const k = period / @as(f32, RIPPLE_N);
                const x = fi * k;
                const y = fj * k;
                const ix = cell(x);
                const iy = cell(y);
                const p: i32 = @intFromFloat(period);
                const fx = frac(x);
                const fy = frac(y);
                const sx = fx * fx * (3 - 2 * fx);
                const sy = fy * fy * (3 - 2 * fy);
                const a = hashf(@mod(ix, p), @mod(iy, p));
                const b = hashf(@mod(ix + 1, p), @mod(iy, p));
                const c = hashf(@mod(ix, p), @mod(iy + 1, p));
                const d = hashf(@mod(ix + 1, p), @mod(iy + 1, p));
                v += w * (a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy);
            }
            ripple_tex[j * RIPPLE_N + i] = v;
        }
    }
    ripple_ready = true;
}

// The table sampled bilinearly, one texel per unit.
inline fn ripple(x: f32, y: f32) f32 {
    const ix = cell(x);
    const iy = cell(y);
    const fx = frac(x);
    const fy = frac(y);
    const m: i32 = RIPPLE_N - 1;
    const x0: usize = @intCast(ix & m);
    const y0: usize = @intCast(iy & m);
    const x1: usize = @intCast((ix + 1) & m);
    const y1: usize = @intCast((iy + 1) & m);
    const a = ripple_tex[y0 * RIPPLE_N + x0];
    const b = ripple_tex[y0 * RIPPLE_N + x1];
    const c = ripple_tex[y1 * RIPPLE_N + x0];
    const d = ripple_tex[y1 * RIPPLE_N + x1];
    return lerp(lerp(a, b, fx), lerp(c, d, fx), fy);
}

// How far the sea floor shelves out past each beach and the mud flats, in
// metres. Within it the water turns lighter as the bottom comes up.
const BEACH_SHELF: f32 = 40;
const MUD_SHELF: f32 = 60;

// Outward unit normals of the islands' faces, in the order groundAt uses.
const ISLAND_NORMALS = blk: {
    var ns: [ISLAND_SIDES][2]f32 = undefined;
    for (0..ISLAND_SIDES) |k| {
        const a = (@as(f32, @floatFromInt(k)) + 1.0) * 2.0 * std.math.pi / @as(f32, @floatFromInt(ISLAND_SIDES));
        ns[k] = .{ @cos(a), @sin(a) };
    }
    break :blk ns;
};

// Outward unit normals of the mud flats' edges, for distances to them.
const MUD_NORMALS = blk: {
    var ns: [MUD.len][2]f32 = undefined;
    for (MUD, 0..) |a, i| {
        const b = MUD[(i + 1) % MUD.len];
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        const l = @sqrt(ex * ex + ey * ey);
        ns[i] = .{ ey / l, -ex / l };
    }
    break :blk ns;
};

// How shallow the water is at a point, from 0 in open water to 1 at the
// edge of a beach, a sandbank, a reef or the mud flats, and whether the
// shallowest of them is the mud. Over a reef, how much of the bottom is rock
// and how hard the surf breaks, both from 0 to 1. Distances follow the same
// faces as the beaches and banks, so the shallows hug them.
const Shallows = struct { k: f32 = 0, mud: bool = false, rock: f32 = 0, surf: f32 = 0 };

inline fn nearOutline(o: *const Outline, x: f32, y: f32, r: f32) bool {
    return x > o.lo[0] - r and x < o.hi[0] + r and y > o.lo[1] - r and y < o.hi[1] + r;
}

// Which shallows can reach each 100 m square of the bay, as bits: the
// islands, the mud flats, the flats, the banks, then the reefs. Most of the
// bay's water is reached by none of them, or one.
const SHOAL_CELL: f32 = 100;
const SHOAL_X0: f32 = -800;
const SHOAL_Y0: f32 = -300;
const SHOAL_W: usize = 36;
const SHOAL_H: usize = 30;
const BIT_MUD: u5 = ISLANDS.len;
const BIT_FLATS: u5 = BIT_MUD + 1;
const BIT_BANKS: u5 = BIT_FLATS + FLATS.len;
const BIT_REEFS: u5 = BIT_BANKS + BANKS.len;
const SHOAL_GRID = blk: {
    @setEvalBranchQuota(200_000);
    if (BIT_REEFS + REEFS.len > 32) @compileError("too many shallows for the grid's bits");
    var reach: [BIT_REEFS + REEFS.len][4]f32 = undefined;
    for (ISLANDS, 0..) |isl, i| reach[i] = .{ isl.x - isl.r - BEACH_SHELF, isl.y - isl.r - BEACH_SHELF, isl.x + isl.r + BEACH_SHELF, isl.y + isl.r + BEACH_SHELF };
    reach[BIT_MUD] = .{ 2100 - MUD_SHELF, 80 - MUD_SHELF, 2760 + MUD_SHELF, 650 + MUD_SHELF };
    for (FLAT_OUTLINES, 0..) |o, i| reach[BIT_FLATS + i] = .{ o.lo[0] - FLAT_SHELF, o.lo[1] - FLAT_SHELF, o.hi[0] + FLAT_SHELF, o.hi[1] + FLAT_SHELF };
    for (BANK_OUTLINES, 0..) |o, i| reach[BIT_BANKS + i] = .{ o.lo[0] - BANK_RUN - BANK_SHELF, o.lo[1] - BANK_RUN - BANK_SHELF, o.hi[0] + BANK_RUN + BANK_SHELF, o.hi[1] + BANK_RUN + BANK_SHELF };
    for (REEF_OUTLINES, 0..) |o, i| reach[BIT_REEFS + i] = .{ o.lo[0] - REEF_SHELF, o.lo[1] - REEF_SHELF, o.hi[0] + REEF_SHELF, o.hi[1] + REEF_SHELF };
    var grid: [SHOAL_W * SHOAL_H]u32 = undefined;
    for (0..SHOAL_H) |j| {
        for (0..SHOAL_W) |i| {
            const x0 = SHOAL_X0 + @as(f32, @floatFromInt(i)) * SHOAL_CELL;
            const y0 = SHOAL_Y0 + @as(f32, @floatFromInt(j)) * SHOAL_CELL;
            var bits: u32 = 0;
            for (reach, 0..) |r, b| {
                if (r[0] < x0 + SHOAL_CELL and r[2] > x0 and r[1] < y0 + SHOAL_CELL and r[3] > y0) bits |= @as(u32, 1) << b;
            }
            grid[j * SHOAL_W + i] = bits;
        }
    }
    break :blk grid;
};

inline fn hasBit(bits: u32, b: usize) bool {
    return (bits >> @intCast(b)) & 1 != 0;
}

fn shallowsAt(x: f32, y: f32) Shallows {
    var sh: Shallows = .{};
    const gx = (x - SHOAL_X0) / SHOAL_CELL;
    const gy = (y - SHOAL_Y0) / SHOAL_CELL;
    if (!(gx >= 0 and gy >= 0 and gx < SHOAL_W and gy < SHOAL_H)) return sh;
    const bits = SHOAL_GRID[@as(usize, @intFromFloat(gy)) * SHOAL_W + @as(usize, @intFromFloat(gx))];
    if (bits == 0) return sh;
    const n: f32 = @floatFromInt(ISLAND_SIDES);
    const apothem = @cos(std.math.pi / n);
    for (ISLANDS, 0..) |isl, b| {
        if (!hasBit(bits, b)) continue;
        const dx = x - isl.x;
        const dy = y - isl.y;
        const reach = isl.r + BEACH_SHELF;
        if (dx * dx + dy * dy > reach * reach) continue;
        var best: f32 = -std.math.inf(f32);
        for (ISLAND_NORMALS) |nv| best = maxf(best, dx * nv[0] + dy * nv[1]);
        const out = maxf(best - isl.r * apothem, 0);
        if (out < BEACH_SHELF) sh.k = maxf(sh.k, 1.0 - out / BEACH_SHELF);
    }
    if (hasBit(bits, BIT_MUD) and x > 2100 - MUD_SHELF and x < 2760 + MUD_SHELF and y > 80 - MUD_SHELF and y < 650 + MUD_SHELF) {
        var out: f32 = 0;
        for (MUD, MUD_NORMALS) |a, nv| out = maxf(out, (x - a[0]) * nv[0] + (y - a[1]) * nv[1]);
        if (out < MUD_SHELF and 1.0 - out / MUD_SHELF > sh.k) sh = .{ .k = 1.0 - out / MUD_SHELF, .mud = true };
    }
    for (&FLAT_OUTLINES, 0..) |*o, i| {
        if (!hasBit(bits, BIT_FLATS + i) or !nearOutline(o, x, y, FLAT_SHELF)) continue;
        const out = outside(o, x, y);
        if (out >= FLAT_SHELF) continue;
        // Uneven inside, by up to a fifth either way.
        const lumps = (ripple(x * 0.006 + 7.0, y * 0.006) - 0.5) * 0.4 * clampf(-out / 60.0, 0, 1);
        sh.k = maxf(sh.k, FLAT_K * (clampf(1.0 - out / FLAT_SHELF, 0, 1) + lumps));
    }
    for (&BANK_OUTLINES, 0..) |*o, i| {
        if (!hasBit(bits, BIT_BANKS + i) or !nearOutline(o, x, y, BANK_RUN + BANK_SHELF)) continue;
        const out = outside(o, x, y) - BANK_RUN;
        if (out < BANK_SHELF) sh.k = maxf(sh.k, 1.0 - maxf(out, 0) / BANK_SHELF);
    }
    for (&REEF_OUTLINES, 0..) |*o, i| {
        if (!hasBit(bits, BIT_REEFS + i) or !nearOutline(o, x, y, REEF_SHELF)) continue;
        const out = outside(o, x, y);
        if (out >= REEF_SHELF) continue;
        sh.k = maxf(sh.k, 1.0 - maxf(out, 0) / REEF_SHELF);
        sh.rock = maxf(sh.rock, clampf(1.0 - out / 10.0, 0, 1));
        // Hardest at the edge, where the swell first meets the rock.
        sh.surf = maxf(sh.surf, if (out > 0) clampf(1.0 - out / REEF_SURF, 0, 1) else maxf(0.45, 1.0 + out / REEF_SURF));
    }
    return sh;
}

// How rough the open bay is, from 0 to 1. It raises the ripples over deep
// water, the share of it broken by whitecaps and the radar's sea clutter.
// It follows the breeze's mean, not its gusts, and is set once a frame; the
// benchmark views keep a moderate sea so their timings stay comparable.
const BENCH_CHOP: f32 = 0.6;
var chop: f32 = BENCH_CHOP;

// Calm at 4 knots, 0.6 at about 16 knots, when whitecaps are everywhere.
fn seaState() f32 {
    return clampf((windMean() - 2.0) / 10.0, 0, 1);
}

// Whitecaps, from 0 to 1: short streaks of foam where a fine crest breaks,
// in the patches where a broad swell is high, and only over open water. They
// start to break in a breeze of about 7 knots. Far off they would shimmer,
// so they give way to their average, a paler sea.
fn whitecap(x: f32, y: f32, t: f32, open: f32, tt: f32) f32 {
    if (t >= 1500.0 or open <= 0.3 or chop <= 0.15) return 0;
    const swell = ripple(x * 0.03 - tt * 0.02, y * 0.03 + 51.0);
    const patch = clampf((swell - (0.55 - 0.15 * chop)) * 8.0, 0, 1) * clampf((open - 0.3) * 2.0, 0, 1) * clampf((chop - 0.15) * 3.0, 0, 1);
    if (patch <= 0) return 0;
    var broken: f32 = 0;
    if (t < 180.0) {
        const crest = ripple(x * 3.2 + tt * 1.2, y * 1.5 + 23.0) * 0.7 + ripple(x * 6.1 + 17.0, y * 4.3 - tt * 0.8) * 0.3;
        broken = clampf((crest - 0.63) * 20.0, 0, 1);
    }
    const fade = clampf((t - 80.0) / 100.0, 0, 1);
    return patch * lerp(broken, 0.06, fade) * (1.0 - t / 1500.0);
}

// The water's own colour, before any reflection: deep green-blue, with the
// bottom showing through over the shallows, and dark weedy rock over a reef.
fn waterBody(x: f32, y: f32, sh: Shallows) Rgb {
    const deep: Rgb = .{ 0.09, 0.19, 0.21 };
    if (sh.k <= 0) return deep;
    // A wavering edge, so the shallows don't trace the beach's facets.
    const k = clampf(sh.k * (0.8 + 0.5 * ripple(x * 0.5 + 37.0, y * 0.5)), 0, 1);
    var bed: Rgb = if (sh.mud) .{ 0.25, 0.3, 0.22 } else .{ 0.3, 0.48, 0.38 };
    if (sh.rock > 0) bed = mix(bed, .{ 0.13, 0.15, 0.1 }, sh.rock * (0.55 + 0.45 * ripple(x * 0.8, y * 0.8 + 19.0)));
    return mix(deep, bed, k);
}

// The bay: a rippled surface that reflects the sky, more at a glancing
// angle, with the sun's glitter, the craft's shadow and the foam churned up
// round its skirt. Its wake is laid over afterwards. Over the shallows the
// bottom shows through, sandy green off the beaches and murky off the mud.
// The chop builds over deep water, where the wind has room to raise it, and
// breaks into whitecaps there; the shallows flatten it.
fn shadeWater(x: f32, y: f32, rx: f32, ry: f32, vz: f32, t: f32) Rgb {
    const tt = @as(f32, @floatFromInt(anim_ms)) * 0.001;
    const sh = shallowsAt(x, y);
    const open = 1.0 - sh.k;
    // Ripples fade out with distance, and far off the surface is flat.
    var nx: f32 = 0;
    var ny: f32 = 0;
    if (t < 450.0) {
        const amp = (0.05 * (1.0 - t / 500.0) + 0.008) * (0.4 + 0.6 * open + 0.6 * chop * open);
        nx = (ripple(x * 0.3 + tt * 0.35, y * 0.3) - 0.5) * amp * 2.0;
        ny = (ripple(x * 0.3 + 11.0, y * 0.3 + tt * 0.3) - 0.5) * amp * 2.0;
    }
    const cap = whitecap(x, y, t, open, tt);
    const nl = @sqrt(nx * nx + ny * ny + 1.0);
    nx /= nl;
    ny /= nl;
    const nz = 1.0 / nl;
    const len = @sqrt(rx * rx + ry * ry + vz * vz);
    const dx = rx / len;
    const dy = ry / len;
    const dz = vz / len;
    const dn = dx * nx + dy * ny + dz * nz;
    const r: [3]f32 = .{ dx - 2 * dn * nx, dy - 2 * dn * ny, dz - 2 * dn * nz };
    const f = clampf(1.0 + dn, 0, 1);
    const f2 = f * f;
    const fres = 0.02 + 0.98 * f2 * f2 * f;
    const base = waterBody(x, y, sh) * splat(0.5 + 0.5 * clampf(sun[2] * 1.2, 0, 1));
    var c = mix(base, mix(FOG, .{ 0.34, 0.55, 0.85 }, clampf(r[2], 0, 1) * (2.0 - clampf(r[2], 0, 1))), fres);
    var g = maxf(0, r[0] * sun[0] + r[1] * sun[1] + r[2] * sun[2]);
    inline for (0..7) |_| g *= g;
    var lit: f32 = 1;
    if (cap > 0) {
        c = mix(c, splat(0.95), cap * 0.9);
        g *= 1.0 - cap;
    }
    if (sh.surf > 0) {
        // Surf breaking over a reef, churning as the swell runs through it.
        // Far off it gives way to its average, as the whitecaps do.
        var foam = sh.surf * 0.5;
        if (t < 250.0) {
            const churn = ripple(x * 0.45 + tt * 0.9, y * 0.45 - tt * 0.5) * 0.6 + ripple(x * 1.3 - tt * 1.1, y * 1.3 + tt * 0.7) * 0.4;
            foam = lerp(clampf((churn - 0.62 + 0.22 * sh.surf) * 5.0, 0, 1), foam, clampf((t - 120.0) / 130.0, 0, 1));
        }
        c = mix(c, splat(0.94), foam * 0.9);
        g *= 1.0 - foam;
    }

    // Everything near the craft, in its frame.
    const wx = x - cr_x;
    const wy = y - cr_y;
    if (wx * wx + wy * wy < 600 * 600) {
        const k = (frame_deck + 1.0) / maxf(sun[2], 0.2);
        const sx = wx + sun[0] * k;
        const sy = wy + sun[1] * k;
        if (@abs(sx * frame_c + sy * frame_s) < CRAFT_HALF_L and @abs(-sx * frame_s + sy * frame_c) < CRAFT_HALF_W) {
            lit = 0.55;
            c = c * splat(0.6);
        }
        var foam: f32 = 0;
        if (lift > 0.3) {
            const ox = maxf(@abs(wx * frame_c + wy * frame_s) - CRAFT_HALF_L, 0);
            const oy = maxf(@abs(-wx * frame_s + wy * frame_c) - CRAFT_HALF_W, 0);
            const out = @sqrt(ox * ox + oy * oy);
            if (out < 4.0) foam = maxf(foam, (1.0 - out / 4.0) * (lift - 0.3) * (0.5 + 0.5 * valueNoise(x * 2.0 + tt * 3.0, y * 2.0)));
        }
        c = mix(c, splat(0.92 * lit), clampf(foam, 0, 1) * 0.8);
    }
    c += splat(g * 1.6 * lit);
    return fog(c, t);
}

fn propPixel(s: Surf, x: f32, y: f32, z: f32) Rgb {
    const d: [3]f32 = .{ x - s.o[0], y - s.o[1], z - s.o[2] };
    const a = dot3(d, s.u);
    const b = dot3(d, s.v);
    const r = @sqrt(a * a + b * b);
    if (r < 0.35) return splat(0.1);
    const spin = @abs(throttle) * 0.9 + 0.1 * lift;
    const phi = std.math.atan2(b, a) - @as(f32, @floatFromInt(anim_ms)) * 0.001 * 6.0 * spin;
    const blade = 0.5 + 0.5 * @cos(4.0 * phi);
    const sharp = blade * blade * blade * blade;
    const k = lerp(sharp, 0.35 + 0.1 * blade, clampf(spin * 2.0, 0, 1));
    return mix(splat(0.06), splat(0.5), k) * splat(outdoorLight(.{ 0, 0, 0.3 }));
}

// The screens on the helm console: the radar, head up, and the compass and
// DGPS readouts in amber. v runs forward from the pilot and u to starboard.
fn consolePixel(u: f32, v: f32) Rgb {
    if (u < 0.45) {
        const cu = (u - 0.225) * 5.2 / 1.4;
        const cv = v - 0.5;
        const r = @sqrt(cu * cu + cv * cv);
        if (r > 0.45) return .{ 0.02, 0.03, 0.05 };
        const ring = @abs(frac(r / 0.45 * 3.0 + 0.5) - 0.5) < 0.025 or (@abs(cu) < 0.004 and cv > 0);
        const c = radarRgb(radarLevel(cv / 0.45, -cu / 0.45));
        return if (ring) c + Rgb{ 0.12, 0.18, 0.24 } else c;
    }
    // Text five font pixels high, a line to each sixth of the screen.
    const pv: f32 = 0.028;
    const pu = pv * 1.4 / 5.2;
    const line = @floor((0.97 - v) / (1.0 / 6.0));
    if (line >= 0 and line < 6) {
        const top = 0.97 - line / 6.0;
        if (textBit(readouts[@intFromFloat(line)], (u - 0.52) / pu, (top - v) / pv)) return .{ 0.95, 0.6, 0.15 };
    }
    return .{ 0.08, 0.05, 0.02 };
}

fn whiteboardPixel(u: f32, v: f32) Rgb {
    const lines = [_][]const u8{ "Q3 PLAN", "1 SHIP DEMO", "2 GET FUNDED", "3 IPO 1999" };
    for (lines, 0..) |l, i| {
        const fi: f32 = @floatFromInt(i);
        if (textBit(l, (u - 0.06) / 0.0105, (v - 0.1 - fi * 0.2) / 0.032)) return if (i == 0) Rgb{ 0.7, 0.1, 0.1 } else Rgb{ 0.1, 0.15, 0.5 };
    }
    // A hockey-stick growth chart.
    const gx = (u - 0.62) / 0.33;
    if (gx > 0 and gx < 1) {
        const gy = 0.85 - 0.6 * gx * gx * gx;
        if (@abs(v - gy) < 0.012 or (@abs(gx) < 0.01 and v > 0.2 and v < 0.85)) return .{ 0.1, 0.45, 0.15 };
        if (@abs(v - 0.85) < 0.008) return .{ 0.1, 0.1, 0.1 };
    }
    return .{ 0.95, 0.95, 0.93 };
}

// The 17 inch CRT

const CRT_PX_W: usize = 192;
const CRT_PX_H: usize = 144;
var crt: [CRT_PX_W * CRT_PX_H]u32 = undefined;

// Lines of the demo, a Perl CGI script that draws a hovercraft fleet
// tracker, revealed a few characters a keystroke.
const CODE = [_][]const u8{
    "#!/USR/BIN/PERL -W",
    "# HOVERTRACK 0.9 - DEMO BUILD",
    "USE STRICT;",
    "USE CGI QW(:STANDARD);",
    "USE DBI;",
    "",
    "MY $Q = CGI->NEW;",
    "MY $DBH = DBI->CONNECT('DBI:MYSQL:HT',",
    "    'DEMO', 'HUNTER2');",
    "PRINT $Q->HEADER('TEXT/HTML');",
    "PRINT '<HTML><BODY BGCOLOR=#FF7A1E>';",
    "PRINT '<BLINK>HOVERTRACK</BLINK>';",
    "",
    "SUB FLEET {",
    "  MY $STH = $DBH->PREPARE(",
    "    'SELECT ID,LAT,LON FROM CRAFT');",
    "  $STH->EXECUTE;",
    "  WHILE (MY @R = $STH->FETCHROW) {",
    "    PRINT \"<TR><TD>$R[0]</TD>\";",
    "    PRINT \"<TD>$R[1],$R[2]</TD></TR>\";",
    "  }",
    "}",
    "",
    "SUB DRIFT {",
    "  MY ($HDG, $VX, $VY) = @_;",
    "  RETURN ATAN2($VY, $VX) - $HDG;",
    "}",
    "",
    "PRINT '<TABLE BORDER=1>';",
    "FLEET();",
    "PRINT '</TABLE>';",
    "PRINT '<IMG SRC=/UNDERCONSTRUCTION.GIF>';",
    "PRINT '<P>BEST VIEWED IN NETSCAPE 4';",
    "PRINT '</BODY></HTML>';",
    "# Y2K SAFE (PROBABLY)",
    "1;",
};

fn codeChars() u32 {
    var n: u32 = 0;
    for (CODE) |l| n += @intCast(l.len + 1);
    return n;
}

fn crtFill(x: i32, y: i32, w: i32, h: i32, c: u32) void {
    const x0: usize = @intCast(std.math.clamp(x, 0, @as(i32, CRT_PX_W)));
    const x1: usize = @intCast(std.math.clamp(x + w, 0, @as(i32, CRT_PX_W)));
    const y0: usize = @intCast(std.math.clamp(y, 0, @as(i32, CRT_PX_H)));
    const y1: usize = @intCast(std.math.clamp(y + h, 0, @as(i32, CRT_PX_H)));
    var yy = y0;
    while (yy < y1) : (yy += 1) @memset(crt[yy * CRT_PX_W + x0 .. yy * CRT_PX_W + x1], c);
}

fn crtText(x: i32, y: i32, text: []const u8, c: u32) void {
    var cx = x;
    for (text) |ch| {
        const bits = glyph(ch);
        var row: u4 = 0;
        while (row < 5) : (row += 1) {
            var col: u4 = 0;
            while (col < 3) : (col += 1) {
                const shift: u4 = 14 - (row * 3 + col);
                if (((bits >> shift) & 1) != 0) crtFill(cx + col, y + row, 1, 1, c);
            }
        }
        cx += 4;
    }
}

fn clockText(buf: *[5]u8) []const u8 {
    const minutes: u32 = @intFromFloat(hourNow() * 60.0);
    const h = minutes / 60;
    const m = minutes % 60;
    buf.* = .{ '0' + @as(u8, @intCast(h / 10)), '0' + @as(u8, @intCast(h % 10)), ':', '0' + @as(u8, @intCast(m / 10)), '0' + @as(u8, @intCast(m % 10)) };
    return buf[0..];
}

// Draws the screen of your machine: the CEO's mail before you start, then
// the demo's code in Emacs, with the build, link, and upload below it.
fn drawCrt() void {
    crtFill(0, 0, CRT_PX_W, CRT_PX_H, 0x008080);
    crtFill(3, 3, 186, 126, 0xC0C0C0);
    crtFill(4, 4, 184, 9, 0x000080);
    const mail = code_keys == 0;
    crtText(6, 6, if (mail) "EUDORA - INBOX" else "DEMO.PL - EMACS", 0xFFFFFF);
    crtFill(5, 14, 182, 84, 0xFFFFFF);
    if (mail) {
        const lines = [_][]const u8{
            "FROM: CEO   SUBJ: DEMO DAY!!",
            "SAND HILL CAPITAL WANT A LIVE",
            "DEMO BY 5PM. AT THEIR PIER.",
            "OUR RIVAL IS RACING US THERE",
            "BY SPEEDBOAT. FIRST ONE WINS",
            "1 TYPE TO WRITE THE DEMO",
            "2 ENTER UPLOADS IT BY SATELLITE",
            "  (HOLD STILL OR LOSE THE LINK)",
            "3 TAKE THE HELM AND STOP US IN",
            "  THEIR BERTH. CUT ACROSS THE",
            "  SHALLOWS, MIND THE REEFS",
            "T IS AUTOPILOT. TAB STANDS UP",
        };
        for (lines, 0..) |l, i| crtText(7, 16 + @as(i32, @intCast(i)) * 7, l, 0x000000);
    } else {
        // The last dozen lines up to the cursor.
        const total = @min(@as(u32, code_keys) * CODE_CHARS_PER_KEY * codeChars() / (CODE_KEYS * CODE_CHARS_PER_KEY), codeChars());
        var shown: [12][]const u8 = undefined;
        var count: usize = 0;
        var left = total;
        for (CODE) |l| {
            if (left == 0) break;
            const take: u32 = @min(left, @as(u32, @intCast(l.len)));
            if (count == shown.len) {
                std.mem.copyForwards([]const u8, shown[0 .. shown.len - 1], shown[1..]);
                count -= 1;
            }
            shown[count] = l[0..take];
            count += 1;
            left -= @min(left, @as(u32, @intCast(l.len + 1)));
        }
        for (shown[0..count], 0..) |l, i| {
            const col: u32 = if (l.len > 0 and l[0] == '#') 0xB22222 else if (std.mem.startsWith(u8, l, "SUB") or std.mem.startsWith(u8, l, "USE") or std.mem.startsWith(u8, l, "MY ")) 0x0000A0 else 0x000000;
            crtText(7, 16 + @as(i32, @intCast(i)) * 7, l, col);
        }
        if (code_keys < CODE_KEYS and @mod(@divTrunc(anim_ms, 400), 2) == 0) {
            const cl = if (count > 0) shown[count - 1].len else 0;
            crtFill(7 + @as(i32, @intCast(cl)) * 4, 16 + @as(i32, @intCast(@max(count, 1) - 1)) * 7, 3, 5, 0x000000);
        }
    }
    // The status lines.
    crtFill(5, 99, 182, 29, 0xC0C0C0);
    crtText(7, 101, "BUILD", 0x000000);
    crtFill(30, 101, 102, 5, 0x808080);
    crtFill(31, 102, @intCast(@as(u32, code_keys) * 100 / CODE_KEYS), 3, 0x000080);
    crtText(7, 110, "SAT", 0x000000);
    const locked = satLocked();
    crtText(30, 110, if (locked) "LOCKED 64K" else if (underBridge()) "BLOCKED" else "SEARCHING", if (locked) 0x006400 else 0xA00000);
    crtText(7, 119, "UPLOAD", 0x000000);
    crtFill(34, 119, 102, 5, 0x808080);
    crtFill(35, 120, @intCast(@divTrunc(@min(upload_ms, UPLOAD_MS) * 100, UPLOAD_MS)), 3, if (uploaded()) 0x006400 else 0x000080);
    if (uploading and !locked and @mod(@divTrunc(anim_ms, 300), 2) == 0) crtText(140, 119, "WAIT", 0xA00000);
    if (uploaded()) crtText(140, 119, "DONE", 0x006400);
    // The taskbar.
    crtFill(0, 133, CRT_PX_W, 11, 0xC0C0C0);
    crtFill(0, 133, CRT_PX_W, 1, 0xFFFFFF);
    crtFill(2, 135, 26, 8, 0xA0A0A0);
    crtText(4, 137, "START", 0x000000);
    var buf: [5]u8 = undefined;
    crtText(CRT_PX_W - 24, 137, clockText(&buf), 0x000000);
}

// A pixel of the tube: the picture bulges with the glass and darkens at
// the corners, between faint scan lines.
fn crtPixel(u: f32, v: f32) Rgb {
    const cu = u - 0.5;
    const cv = v - 0.5;
    const r2 = cu * cu + cv * cv;
    const bu = 0.5 + cu * (1.0 + 0.08 * r2);
    const bv = 0.5 + cv * (1.0 + 0.08 * r2);
    if (bu < 0.0 or bu >= 1.0 or bv < 0.0 or bv >= 1.0) return splat(0.03);
    const ix: usize = @intFromFloat(bu * @as(f32, CRT_PX_W));
    const fy = bv * @as(f32, CRT_PX_H);
    const iy: usize = @intFromFloat(fy);
    var c = rgbHex(crt[@min(iy, CRT_PX_H - 1) * CRT_PX_W + @min(ix, CRT_PX_W - 1)]);
    const scan = 0.82 + 0.18 * @sin(frac(fy) * std.math.pi);
    c = c * splat(scan * (1.0 - 0.9 * r2)) * splat(0.95);
    return c + splat(0.03);
}

// Everyone else's monitor shows a starfield screen saver, or is off.
fn saverPixel(u: f32, v: f32, seed: u16) Rgb {
    if (seed % 3 == 2) return splat(0.05 + 0.04 * (1.0 - v));
    const t = @as(f32, @floatFromInt(anim_ms)) * 0.0002 + @as(f32, @floatFromInt(seed)) * 0.37;
    var c = splat(0.015);
    inline for (0..3) |k| {
        const depth = frac(t + @as(f32, @floatFromInt(k)) / 3.0);
        const zoom = 1.0 / (0.08 + depth * 1.2);
        const sx = (u - 0.5) * zoom * 6.0 + 50.0;
        const sy = (v - 0.5) * zoom * 4.5 + 50.0;
        const h = hashf(cell(sx), cell(sy) + @as(i32, @intCast(k)) * 101 + @as(i32, seed) * 7);
        const dx = frac(sx) - 0.5;
        const dy = frac(sy) - 0.5;
        if (h > 0.9 and dx * dx + dy * dy < 0.04) c += splat((1.0 - depth) * 0.9);
    }
    return c;
}

// Rendering

var cam_x: f32 = 0;
var cam_y: f32 = 0;
var cam_z: f32 = 0;
var cam_fx: f32 = 1;
var cam_fy: f32 = 0;
var cam_rx: f32 = 0;
var cam_ry: f32 = -1;
var horizon: f32 = BASE_HORIZON;
var focal: f32 = FOCAL;

// The eye, in the bay's frame, and whether it is inside the cabin.
var eye_x: f32 = 0;
var eye_y: f32 = 0;
var eye_z: f32 = 0;
var eye_angle: f32 = 0;
var eye_inside = false;
// The chase camera swings round after the heading, not instantly.
var chase_h: f32 = 0;

fn setPassCamera(x: f32, y: f32, z: f32, angle: f32) void {
    cam_x = x;
    cam_y = y;
    cam_z = z;
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

inline fn rowVz(y: usize) f32 {
    return (horizon - (@as(f32, @floatFromInt(y)) + 0.5)) / focal;
}

// The two passes share these: which pixels each has covered (bit 1 for the
// craft, bit 2 for the bay), and counts of what is left in each row and in
// each 8 by 8 tile, so whole subtrees can be skipped once their screen
// bounds are covered.
const TILE: usize = 8;
const TILES_X: usize = SCREEN_W / TILE;
const TILES_Y: usize = SCREEN_H / TILE;
const COVER_CRAFT: u8 = 1;
const COVER_BAY: u8 = 2;

var covered: [SCREEN_W * SCREEN_H]u8 = undefined;
var row_left: [SCREEN_H]u16 = undefined;
var tile_left: [TILES_X * TILES_Y]u8 = undefined;
var pixels_left: u32 = 0;
var stat_nodes: u32 = 0;
var stat_polys: u32 = 0;

// How a pass treats pixels: skip those covered by any bit in `block`, and
// with `depth_test`, keep the nearer of this pass and the craft's where the
// craft got there first. `count` keeps the tallies for culling.
const PassRules = struct { bit: u8, block: u8, depth_test: bool, count: bool = true };

fn resetCounts() void {
    @memset(&row_left, SCREEN_W);
    @memset(&tile_left, TILE * TILE);
    pixels_left = SCREEN_W * SCREEN_H;
}

fn drawScene() void {
    sun = sunDir();
    frame_c = @cos(cr_h);
    frame_s = @sin(cr_h);
    frame_deck = deckZ();
    @memset(&covered, 0);
    @memset(&zbuf, std.math.inf(f32));
    resetCounts();
    stat_nodes = 0;
    stat_polys = 0;
    const deck = deckZ();
    const l = toLocal(eye_x, eye_y);
    const c = @cos(-cr_h);
    const s = @sin(-cr_h);
    const craft_sun: [3]f32 = .{ sun[0] * c - sun[1] * s, sun[0] * s + sun[1] * c, sun[2] };

    if (reference_render) {
        // Every polygon, in the order built, into the depth buffer.
        const rules: PassRules = .{ .bit = COVER_CRAFT, .block = 0, .depth_test = true, .count = false };
        setPassCamera(l[0], l[1], eye_z - deck, eye_angle - cr_h);
        sun_pass = craft_sun;
        for (craft_tree.first..craft_tree.first + craft_tree.polys) |i| drawPoly(polys[i], rules);
        drawRudders(rules);
        setPassCamera(eye_x, eye_y, eye_z, eye_angle);
        sun_pass = sun;
        for (world_tree.first..world_tree.first + world_tree.polys) |i| drawPoly(polys[i], rules);
        drawSpeedboat(rules);
    } else {
        setPassCamera(l[0], l[1], eye_z - deck, eye_angle - cr_h);
        sun_pass = craft_sun;
        drawTree(craft_tree, .{ .bit = COVER_CRAFT, .block = COVER_CRAFT, .depth_test = false });
        // Left out of the tallies: culling only gets a little less eager.
        drawRudders(.{ .bit = COVER_CRAFT, .block = 0, .depth_test = true, .count = false });
        setPassCamera(eye_x, eye_y, eye_z, eye_angle);
        sun_pass = sun;
        if (eye_inside) {
            // From inside, whatever the cabin covered is final, and the bay
            // only shows through the windows.
            drawTree(world_tree, .{ .bit = COVER_BAY, .block = COVER_CRAFT | COVER_BAY, .depth_test = false });
        } else {
            resetCounts();
            drawTree(world_tree, .{ .bit = COVER_BAY, .block = COVER_BAY, .depth_test = true });
        }
        drawSpeedboat(.{ .bit = COVER_BAY, .block = 0, .depth_test = true, .count = false });
    }
    // Whatever nothing covered is sky.
    setPassCamera(eye_x, eye_y, eye_z, eye_angle);
    var col: usize = 0;
    while (col < SCREEN_W) : (col += 1) {
        const sl = (@as(f32, @floatFromInt(col)) + 0.5 - HALF_W) / focal;
        const rx = cam_fx + sl * cam_rx;
        const ry = cam_fy + sl * cam_ry;
        var y: usize = 0;
        while (y < SCREEN_H) : (y += 1) {
            if (covered[y * SCREEN_W + col] != 0) continue;
            putPixel(col, y, skyColor(rx, ry, rowVz(y), true));
        }
    }
}

// The four rudders, two in each propeller's wash, hinged at their leading
// edges just aft of the ducts. They swing with the helm, so instead of
// sitting in the craft's tree they are drawn after it, depth tested, from
// faces made each frame in a few spare vertices.
const RUDDER_X: f32 = -19.6;
const RUDDER_CHORD: f32 = 1.9;
const RUDDER_HALF_T: f32 = 0.08;
const RUDDER_Z0: f32 = 0.4;
const RUDDER_Z1: f32 = 5.0;
const RUDDER_SWING: f32 = 0.5;
const RUDDER_YS = [_]f32{ 5.7, 3.5, -3.5, -5.7 };
var rudder_surf: u32 = 0;
var rudder_verts: usize = 0;

fn drawRudders(rules: PassRules) void {
    // Positive rudder swings the trailing edges to starboard.
    const a = rudder * RUDDER_SWING;
    const c = @cos(a);
    const s = @sin(a);
    const plan = [4][2]f32{ .{ 0, RUDDER_HALF_T }, .{ 0, -RUDDER_HALF_T }, .{ -RUDDER_CHORD, -RUDDER_HALF_T }, .{ -RUDDER_CHORD, RUDDER_HALF_T } };
    for (RUDDER_YS) |yc| {
        var bot: [4][3]f32 = undefined;
        var top: [4][3]f32 = undefined;
        for (plan, 0..) |q, i| {
            const x = RUDDER_X + q[0] * c - q[1] * s;
            const y = yc + q[0] * s + q[1] * c;
            bot[i] = .{ x, y, RUDDER_Z0 };
            top[i] = .{ x, y, RUDDER_Z1 };
        }
        const mid: [3]f32 = .{ RUDDER_X - 0.5 * RUDDER_CHORD * c, yc - 0.5 * RUDDER_CHORD * s, 0.5 * (RUDDER_Z0 + RUDDER_Z1) };
        rudderFace(.{ bot[0], bot[3], bot[2], bot[1] }, mid, rules);
        rudderFace(top, mid, rules);
        for (0..4) |i| {
            const j = (i + 1) % 4;
            rudderFace(.{ bot[i], bot[j], top[j], top[i] }, mid, rules);
        }
    }
}

fn rudderFace(pts: [4][3]f32, mid: [3]f32, rules: PassRules) void {
    var n = newell(&pts);
    if (dot3(n, sub3(centroid(&pts), mid)) < 0) n = scale3(n, -1);
    @memcpy(pverts[rudder_verts .. rudder_verts + 4], &pts);
    drawPoly(.{ .first = @intCast(rudder_verts), .n = 4, .surf = rudder_surf, .nx = n[0], .ny = n[1], .nz = n[2], .d = dot3(n, pts[0]) }, rules);
}

// The speedboat moves, so it is drawn like the rudders: after the bay, depth
// tested, its faces turned and moved each frame from its own frame into
// spare vertices.
var boat_polys: usize = 0;
var boat_polys_end: usize = 0;
var boat_verts: usize = 0;
var boat_moved: usize = 0;

fn drawSpeedboat(rules: PassRules) void {
    const dx = rv_x - cam_x;
    const dy = rv_y - cam_y;
    if (dx * cam_fx + dy * cam_fy < -RIVAL_HALF_L - 1.0 or dx * dx + dy * dy > 3000 * 3000) return;
    const c = @cos(rv_h);
    const s = @sin(rv_h);
    const shift = boat_moved - boat_verts;
    for (boat_verts..boat_moved) |i| {
        const v = pverts[i];
        pverts[i + shift] = .{ rv_x + v[0] * c - v[1] * s, rv_y + v[0] * s + v[1] * c, v[2] };
    }
    for (polys[boat_polys..boat_polys_end]) |p| {
        const nx = p.nx * c - p.ny * s;
        const ny = p.nx * s + p.ny * c;
        const first = p.first + @as(u32, @intCast(shift));
        const v0 = pverts[first];
        drawPoly(.{ .first = first, .n = p.n, .surf = p.surf, .nx = nx, .ny = ny, .nz = p.nz, .d = nx * v0[0] + ny * v0[1] + p.nz * v0[2] }, rules);
    }
}

const BspVisit = struct { node: i32, draw: bool };

// Walks a tree front to back from the pass's eye, drawing each node's
// polygons between its far and near subtrees and skipping subtrees whose
// bounds fall only on covered pixels.
fn drawTree(tree: Tree, rules: PassRules) void {
    if (tree.root < 0) return;
    var stack: [BSP_STACK]BspVisit = undefined;
    stack[0] = .{ .node = tree.root, .draw = false };
    var sp: usize = 1;
    while (sp > 0 and pixels_left > 0) {
        sp -= 1;
        const v = stack[sp];
        if (v.node < 0) continue;
        const n = bnodes[@intCast(v.node)];
        if (v.draw) {
            for (bsp_polys[n.first .. n.first + n.count]) |pi| drawPoly(polys[pi], rules);
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

fn drawPoly(p: Poly, rules: PassRules) void {
    // Polygons face one way only.
    if (p.nx * cam_x + p.ny * cam_y + p.nz * cam_z - p.d <= 0) return;
    rasterPoly(p, rules);
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
        const sx = HALF_W + (rx * cam_rx + ry * cam_ry) * focal / d;
        const sy = horizon - (z - cam_z) * focal / d;
        x0 = minf(x0, sx);
        x1 = maxf(x1, sx);
        y0 = minf(y0, sy);
        y1 = maxf(y1, sy);
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

fn rasterPoly(p: Poly, rules: PassRules) void {
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
            b[m] = .{ HALF_W + q[0] * focal / q[1], horizon - q[2] * focal / q[1] };
            m += 1;
        }
        if ((q[1] >= NEAR) != (r[1] >= NEAR) and m < b.len) {
            const t = (NEAR - q[1]) / (r[1] - q[1]);
            const x = q[0] + (r[0] - q[0]) * t;
            const z = q[2] + (r[2] - q[2]) * t;
            b[m] = .{ HALF_W + x * focal / NEAR, horizon - z * focal / NEAR };
            m += 1;
        }
    }
    if (m < 3) return;
    var ymin: f32 = std.math.inf(f32);
    var ymax: f32 = -std.math.inf(f32);
    for (b[0..m]) |q| {
        ymin = minf(ymin, q[1]);
        ymax = maxf(ymax, q[1]);
    }
    const r0: usize = @intFromFloat(clampf(@ceil(ymin - 0.5), 0.0, @as(f32, SCREEN_H)));
    const r1: usize = @intFromFloat(clampf(@ceil(ymax - 0.5), 0.0, @as(f32, SCREEN_H)));
    if (r0 >= r1) return;
    stat_polys += 1;
    const pn = p.nx * cam_x + p.ny * cam_y + p.nz * cam_z;
    var r = r0;
    while (r < r1) : (r += 1) {
        if (rules.count and row_left[r] == 0) continue;
        const yc = @as(f32, @floatFromInt(r)) + 0.5;
        var xl: f32 = std.math.inf(f32);
        var xr: f32 = -std.math.inf(f32);
        for (0..m) |i| {
            const q = b[i];
            const s = b[(i + 1) % m];
            if ((q[1] <= yc and s[1] > yc) or (s[1] <= yc and q[1] > yc)) {
                const x = q[0] + (yc - q[1]) * (s[0] - q[0]) / (s[1] - q[1]);
                xl = minf(xl, x);
                xr = maxf(xr, x);
            }
        }
        if (!(xl < xr)) continue;
        const c0: usize = @intFromFloat(clampf(@ceil(xl - 0.5), 0.0, HALF_W * 2.0));
        const c1: usize = @intFromFloat(clampf(@ceil(xr - 0.5), 0.0, HALF_W * 2.0));
        const vz = (horizon - yc) / focal;
        var c = c0;
        const row = r * SCREEN_W;
        while (c < c1) : (c += 1) {
            const cv = covered[row + c];
            if ((cv & rules.block) != 0) continue;
            const sl = (@as(f32, @floatFromInt(c)) + 0.5 - HALF_W) / focal;
            const rx = cam_fx + sl * cam_rx;
            const ry = cam_fy + sl * cam_ry;
            const den = p.nx * rx + p.ny * ry + p.nz * vz;
            if (den > -1e-9) continue;
            const t = maxf((p.d - pn) / den, NEAR);
            const hidden = rules.depth_test and zbuf[row + c] <= t;
            if (!hidden) {
                putPixel(c, r, shade(p, rx, ry, vz, t));
                zbuf[row + c] = t;
            }
            covered[row + c] = cv | rules.bit;
            if (rules.count) {
                row_left[r] -= 1;
                tile_left[(r / TILE) * TILES_X + c / TILE] -= 1;
                pixels_left -= 1;
            }
        }
    }
}

// Gulls

const GULL_WHITE: Rgb = .{ 0.95, 0.95, 0.94 };
const GULL_GREY: Rgb = .{ 0.62, 0.66, 0.72 };
const GULL_BLACK: Rgb = .{ 0.1, 0.1, 0.11 };
const GULL_BEAK: Rgb = .{ 0.95, 0.8, 0.2 };

fn rgba(c: Rgb, a: f32) Rgba {
    return .{ c[0], c[1], c[2], a };
}

const CLEAR: Rgba = .{ 0, 0, 0, 0 };

// A gull in flight: long narrow wings, foreshortened when seen end on, with
// black tips, beating or held level for a glide.
fn shadeGull(g: Gull, w: f32, h: f32, mx: f32, my: f32) Rgba {
    const y = my - h * 0.5;
    var vx = g.x - cam_x;
    var vy = g.y - cam_y;
    const vz = g.z - cam_z;
    const vl = @sqrt(vx * vx + vy * vy + vz * vz);
    vx /= vl;
    vy /= vl;
    const toward_wing = g.hy * vx - g.hx * vy;
    const spread = @sqrt(maxf(0.08, 1.0 - toward_wing * toward_wing));
    const toward_nose = g.hx * vx + g.hy * vy;
    const side = @sqrt(maxf(0.0, 1.0 - toward_nose * toward_nose));
    const half_body = 0.2 * side + 0.05;
    const nose: f32 = if (g.hx * cam_rx + g.hy * cam_ry < 0) -1 else 1;
    const x = mx * nose;
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
    const lift_: f32 = if (g.glide) 0.05 else @sin(g.flap) * 0.3;
    const wy = -lift_ * half * t - (if (g.glide) 0.04 * maxf(0.0, t - 0.5) else 0.0);
    const thick = 0.055 * (1.0 - 0.6 * t) + 0.01;
    if (@abs(y - wy) >= thick) return CLEAR;
    if (t > 0.78) return rgba(GULL_BLACK, 1);
    if (y - wy < -thick * 0.2) return rgba(GULL_GREY, 1);
    return rgba(GULL_WHITE * splat(0.92), 1);
}

fn drawGulls() void {
    setPassCamera(eye_x, eye_y, eye_z, eye_angle);
    sun_pass = sun;
    var order: [MAX_GULLS]usize = undefined;
    var depths: [MAX_GULLS]f32 = undefined;
    var n: usize = 0;
    for (gulls, 0..) |g, i| {
        const d = (g.x - cam_x) * cam_fx + (g.y - cam_y) * cam_fy;
        if (d < 1.0) continue;
        var j = n;
        while (j > 0 and depths[j - 1] < d) : (j -= 1) {
            depths[j] = depths[j - 1];
            order[j] = order[j - 1];
        }
        depths[j] = d;
        order[j] = i;
        n += 1;
    }
    for (order[0..n], depths[0..n]) |i, d| drawGull(gulls[i], d);
}

fn drawGull(g: Gull, depth: f32) void {
    const span = GULL_SPAN * 1.3;
    const w = span;
    const h = span * 0.6;
    const z0 = g.z - span * 0.3;
    const cx = (g.x - cam_x) * cam_rx + (g.y - cam_y) * cam_ry;
    const scale = focal / depth;
    const sx = HALF_W + cx * scale;
    const y_top = horizon - (z0 + h - cam_z) * scale;
    const y_bot = horizon - (z0 - cam_z) * scale;
    const x0: usize = @intFromFloat(clampf(@ceil(sx - w * 0.5 * scale - 0.5), 0.0, HALF_W * 2.0));
    const x1: usize = @intFromFloat(clampf(@ceil(sx + w * 0.5 * scale - 0.5), 0.0, HALF_W * 2.0));
    const y0: usize = @intFromFloat(clampf(@ceil(y_top - 0.5), 0.0, @as(f32, SCREEN_H)));
    const y1: usize = @intFromFloat(clampf(@ceil(y_bot - 0.5), 0.0, @as(f32, SCREEN_H)));
    if (x0 >= x1 or y0 >= y1) return;
    var c = x0;
    while (c < x1) : (c += 1) {
        const mx = (@as(f32, @floatFromInt(c)) + 0.5 - sx) / scale;
        var y = y0;
        while (y < y1) : (y += 1) {
            if (zbuf[y * SCREEN_W + c] <= depth) continue;
            const my = (@as(f32, @floatFromInt(y)) + 0.5 - y_top) / scale;
            const px_ = shadeGull(g, w / 1.3, h / 1.3, mx / 1.3, my / 1.3);
            if (px_[3] <= 0.01) continue;
            putPixel(c, y, fog(Rgb{ px_[0], px_[1], px_[2] } * splat(outdoorLight(.{ 0, 0, 1 }) * 0.9), depth));
        }
    }
}

// Wake

// The wake lies where the stern has been rather than swinging round behind
// it: a ring of the stern's last positions, one every WAKE_STEP metres, each
// with the time, speed and course it was laid down at. Each frame every
// stretch between two of them is drawn as a long Gaussian splat lying on the
// water: the churned track down the middle, and an arm either side. The arms
// leave each point at 19.5 degrees to its course, so they spread at 0.354 of
// the speed it was laid down at, and go on spreading after the craft has
// turned or stopped. The splats keep the brightest foam at each pixel rather
// than piling up where they overlap, and it is all laid over in one pass.
const WAKE_N: usize = 128;
const WAKE_STEP: f32 = 4.0;
const WAKE_LIFE: f32 = 20.0;

const WakePoint = struct {
    x: f32,
    y: f32,
    // The course, as a unit vector.
    ux: f32,
    uy: f32,
    speed: f32,
    // When it was laid down, and how far along the track.
    t: f32,
    dist: f32,
    // How hard the skirt was churning the water, from 0 to 1.
    churn: f32,
};

// The craft and the rival's speedboat each leave a wake: the half-width of
// the churned track behind them, and how far out to the side the arms begin.
const Wake = struct {
    pts: [WAKE_N]WakePoint = undefined,
    next: usize = 0,
    len: usize = 0,
    track: f32,
    beam: f32,
};

var craft_wake: Wake = .{ .track = 11.0, .beam = CRAFT_HALF_W };
var rival_wake: Wake = .{ .track = 3.0, .beam = RIVAL_HALF_W };
var wake_clock: f32 = 0;
var wake_foam: [SCREEN_W * SCREEN_H]u8 = undefined;
var wake_rows: [2]usize = .{ 0, 0 };

fn sternPoint() WakePoint {
    const speed = crSpeed();
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    const x = cr_x - c * CRAFT_HALF_L * 0.8;
    const y = cr_y - s * CRAFT_HALF_L * 0.8;
    const afloat: f32 = if (groundAt(x, y).z > 0) 0 else 1;
    return .{
        .x = x,
        .y = y,
        .ux = if (speed > 0.5) cr_vx / speed else c,
        .uy = if (speed > 0.5) cr_vy / speed else s,
        .speed = speed,
        .t = wake_clock,
        .dist = 0,
        .churn = clampf((lift - 0.3) / 0.6, 0, 1) * afloat,
    };
}

// The speedboat's stern, where its outboards churn the water.
fn rivalStern() WakePoint {
    const c = @cos(rv_h);
    const s = @sin(rv_h);
    return .{ .x = rv_x - c * RIVAL_HALF_L, .y = rv_y - s * RIVAL_HALF_L, .ux = c, .uy = s, .speed = rv_speed, .t = wake_clock, .dist = 0, .churn = 1 };
}

fn newestWake(w: *const Wake) WakePoint {
    return w.pts[(w.next + WAKE_N - 1) % WAKE_N];
}

fn recordWakes() void {
    wake_clock += DT;
    recordWake(&craft_wake, sternPoint());
    if (rival == .racing) recordWake(&rival_wake, rivalStern());
}

fn recordWake(w: *Wake, point: WakePoint) void {
    var p = point;
    if (w.len > 0) {
        const last = newestWake(w);
        const dx = p.x - last.x;
        const dy = p.y - last.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d < WAKE_STEP) return;
        // Too far for one step: the craft has been put somewhere else.
        if (d > 40.0) {
            w.len = 0;
        } else {
            p.dist = last.dist + d;
        }
    }
    w.pts[w.next] = p;
    w.next = (w.next + 1) % WAKE_N;
    w.len = @min(w.len + 1, WAKE_N);
}

// One end of a splat: where it is, its half-width, how strong its foam is,
// and how far along the track.
const WakeEnd = struct { x: f32, y: f32, r: f32, f: f32, dist: f32 };

fn drawWake() void {
    if (craft_wake.len == 0 and rival_wake.len == 0) return;
    setPassCamera(eye_x, eye_y, eye_z, eye_angle);
    if (cam_z < 0.2) return;
    @memset(&wake_foam, 0);
    wake_rows = .{ SCREEN_H, 0 };
    const tt = @as(f32, @floatFromInt(anim_ms)) * 0.001;
    layTrack(&craft_wake, sternPoint(), tt);
    if (rival == .racing) layTrack(&rival_wake, rivalStern(), tt);
    var row = wake_rows[0];
    while (row < wake_rows[1]) : (row += 1) {
        const d = cam_z * focal / (@as(f32, @floatFromInt(row)) + 0.5 - horizon);
        const foam = fog(splat(0.92), d);
        for (0..SCREEN_W) |col| {
            const v = wake_foam[row * SCREEN_W + col];
            if (v == 0) continue;
            putPixel(col, row, mix(readPixel(col, row), foam, @as(f32, @floatFromInt(v)) * (0.8 / 255.0)));
        }
    }
}

// Lays one wake's splats, with head the stern, where the stretch still being
// laid ends.
fn layTrack(w: *const Wake, stern: WakePoint, tt: f32) void {
    if (w.len == 0) return;
    var head = stern;
    const last = newestWake(w);
    head.dist = last.dist + @sqrt((head.x - last.x) * (head.x - last.x) + (head.y - last.y) * (head.y - last.y));
    // Old track is wide, so one splat spans several points, up to half its
    // width or a bend, which saves going over the same pixels again and
    // again. The arms are narrower and step more finely.
    var mid = w.pts[(w.next + WAKE_N - w.len) % WAKE_N];
    var arms = mid;
    for (1..w.len + 1) |i| {
        const p = if (i < w.len) w.pts[(w.next + WAKE_N - w.len + i) % WAKE_N] else head;
        if (wake_clock - p.t >= WAKE_LIFE) {
            mid = p;
            arms = p;
            continue;
        }
        const last_one = i == w.len;
        const m = wakeEnd(w, mid, 0);
        if (last_one or p.dist - mid.dist >= m.r * 0.5 or mid.ux * p.ux + mid.uy * p.uy < 0.97) {
            layWake(m, wakeEnd(w, p, 0), false, tt);
            mid = p;
        }
        if (last_one or p.dist - arms.dist >= wakeEnd(w, arms, 1).r * 0.5 or arms.ux * p.ux + arms.uy * p.uy < 0.97) {
            layWake(wakeEnd(w, arms, 1), wakeEnd(w, p, 1), true, tt);
            layWake(wakeEnd(w, arms, -1), wakeEnd(w, p, -1), true, tt);
            arms = p;
        }
    }
}

// The middle of the track (side 0) or an arm (side 1 or -1) at a point. The
// track widens a little with age; the arms run out to the side.
fn wakeEnd(w: *const Wake, p: WakePoint, side: f32) WakeEnd {
    const age = wake_clock - p.t;
    const fade = clampf(1.0 - age / WAKE_LIFE, 0, 1) * p.churn;
    const run = p.speed * age;
    if (side == 0) return .{ .x = p.x, .y = p.y, .r = w.track + run * 0.1, .f = fade * clampf((p.speed - 0.8) / 2.0, 0, 1), .dist = p.dist };
    const out = side * (w.beam + run * 0.354);
    return .{
        .x = p.x - p.uy * out,
        .y = p.y + p.ux * out,
        .r = 1.8 + run * 0.03,
        .f = fade * clampf((p.speed - 2.0) / 10.0, 0, 1),
        .dist = p.dist,
    };
}

// A splat lying on the water between two ends, its foam falling off as a
// Gaussian from the line joining them. Rows run from the far edge of its
// bounding box to the near; along each the box gives the columns to visit.
// Where something stands in front of the water it is left alone.
fn layWake(a: WakeEnd, b: WakeEnd, arm: bool, tt: f32) void {
    if (a.f <= 0 and b.f <= 0) return;
    const rmax = maxf(a.r, b.r);
    const min_x = minf(a.x, b.x) - rmax;
    const max_x = maxf(a.x, b.x) + rmax;
    const min_y = minf(a.y, b.y) - rmax;
    const max_y = maxf(a.y, b.y) + rmax;
    var dmin: f32 = std.math.inf(f32);
    var dmax: f32 = -std.math.inf(f32);
    for ([_][2]f32{ .{ min_x, min_y }, .{ max_x, min_y }, .{ min_x, max_y }, .{ max_x, max_y } }) |q| {
        const d = (q[0] - cam_x) * cam_fx + (q[1] - cam_y) * cam_fy;
        dmin = minf(dmin, d);
        dmax = maxf(dmax, d);
    }
    if (dmax < 1.0) return;
    dmin = maxf(dmin, 0.5);
    const r0: usize = @intFromFloat(clampf(@ceil(horizon + cam_z * focal / dmax - 0.5), 0.0, @as(f32, SCREEN_H)));
    const r1: usize = @intFromFloat(clampf(@ceil(horizon + cam_z * focal / dmin - 0.5), 0.0, @as(f32, SCREEN_H)));
    if (r0 >= r1) return;
    wake_rows = .{ @min(wake_rows[0], r0), @max(wake_rows[1], r1) };
    const ex = b.x - a.x;
    const ey = b.y - a.y;
    const len2 = ex * ex + ey * ey + 1e-6;
    const edge = @exp(@as(f32, -3.5));
    // Up close, where a pixel is under a fifth of a metre, the foam is
    // worked out once for each 2 by 2 block.
    const fine_until = horizon + cam_z * 5.0;
    var row = r0;
    while (row < r1) {
        const n: usize = if (@as(f32, @floatFromInt(row)) < fine_until) 1 else 2;
        row -= row % n;
        defer row += n;
        const d = cam_z * focal / (@as(f32, @floatFromInt(row)) + 0.5 * @as(f32, @floatFromInt(n)) - horizon);
        const ox = cam_x + cam_fx * d;
        const oy = cam_y + cam_fy * d;
        // Where along the row, in metres to the right, it crosses the box.
        var lo: f32 = -std.math.inf(f32);
        var hi: f32 = std.math.inf(f32);
        if (@abs(cam_rx) > 1e-6) {
            const l0 = (min_x - ox) / cam_rx;
            const l1 = (max_x - ox) / cam_rx;
            lo = maxf(lo, minf(l0, l1));
            hi = minf(hi, maxf(l0, l1));
        } else if (ox < min_x or ox > max_x) continue;
        if (@abs(cam_ry) > 1e-6) {
            const l0 = (min_y - oy) / cam_ry;
            const l1 = (max_y - oy) / cam_ry;
            lo = maxf(lo, minf(l0, l1));
            hi = minf(hi, maxf(l0, l1));
        } else if (oy < min_y or oy > max_y) continue;
        if (!(lo < hi)) continue;
        const k = focal / d;
        const c0: usize = @intFromFloat(clampf(@ceil(HALF_W + lo * k - 0.5), 0.0, HALF_W * 2.0));
        const c1: usize = @intFromFloat(clampf(@ceil(HALF_W + hi * k - 0.5), 0.0, HALF_W * 2.0));
        const rows = @min(n, SCREEN_H - row);
        var col = c0 - c0 % n;
        while (col < c1) : (col += n) {
            const cols = @min(n, SCREEN_W - col);
            // The pixels of the block that show water, and the least foam
            // already on them.
            var open: u4 = 0;
            var least: u8 = 255;
            for (0..rows) |i| for (0..cols) |j| {
                const idx = (row + i) * SCREEN_W + col + j;
                if (zbuf[idx] >= d * 0.99) {
                    open |= @as(u4, 1) << @intCast(i * 2 + j);
                    least = @min(least, wake_foam[idx]);
                }
            };
            if (open == 0) continue;
            const l = (@as(f32, @floatFromInt(col)) + 0.5 * @as(f32, @floatFromInt(n)) - HALF_W) / k;
            const wx = ox + cam_rx * l;
            const wy = oy + cam_ry * l;
            const qx = wx - a.x;
            const qy = wy - a.y;
            const t = clampf((qx * ex + qy * ey) / len2, 0, 1);
            const dx = qx - ex * t;
            const dy = qy - ey * t;
            const r = lerp(a.r, b.r, t);
            const q2 = (dx * dx + dy * dy) / (r * r);
            if (q2 >= 1) continue;
            var f = lerp(a.f, b.f, t) * (@exp(-3.5 * q2) - edge) / (1.0 - edge);
            // Skip the noise where this splat can't beat what's there.
            if (f * (if (arm) @as(f32, 0.65) else 1.3) * 255.0 <= @as(f32, @floatFromInt(least))) continue;
            const along = lerp(a.dist, b.dist, t);
            const side = @sqrt(dx * dx + dy * dy);
            if (arm) {
                // Broken into crests.
                const crests = 0.5 + 0.5 * @sin(along * 0.9 - side * 0.3);
                f *= (0.2 + 0.45 * crests) * (0.5 + 0.5 * valueNoise(along * 0.2, side * 0.2));
            } else {
                // Drawn out into streaks along the track.
                const streak = valueNoise(side * 0.8, along * 0.03 + tt * 0.2);
                f *= 0.25 + 0.45 * valueNoise(wx * 0.9, wy * 0.9 + tt) + 0.6 * streak * streak;
            }
            const v: u8 = @intFromFloat(clampf(f, 0, 1) * 255.0);
            for (0..rows) |i| for (0..cols) |j| {
                if ((open >> @intCast(i * 2 + j)) & 1 == 0) continue;
                const idx = (row + i) * SCREEN_W + col + j;
                if (v > wake_foam[idx]) wake_foam[idx] = v;
            };
        }
    }
}

// Spray

// Spray thrown off the skirt: puffs that fly out and up, slow in the air,
// fall back and thin away, left behind as the craft runs on. Each puff is
// worked out afresh every frame from its slot and the clock, and assumes the
// craft has kept its current velocity since it was thrown.
const SPRAY_N: usize = 96;
const SPRAY_LIFE: f32 = 1.2;

fn drawSpray() void {
    const speed = crSpeed();
    const c = @cos(cr_h);
    const s = @sin(cr_h);
    const slip = @abs(-cr_vx * s + cr_vy * c);
    const cushion = clampf((lift - 0.3) / 0.6, 0, 1);
    const amount = clampf((speed - 3.0) / 14.0 + slip * 0.08, 0, 1) * cushion * (0.5 + 0.5 * (1.0 - shallowsAt(cr_x, cr_y).k));
    if (amount <= 0) return;
    setPassCamera(eye_x, eye_y, eye_z, eye_angle);
    sun_pass = sun;
    const base_z = craftGround() + 0.4;
    const light = outdoorLight(.{ 0, 0, 1 });
    const now = @as(f32, @floatFromInt(anim_ms)) * 0.001 / SPRAY_LIFE;
    const air = wind();
    var puffs: [SPRAY_N]Puff = undefined;
    var n: usize = 0;
    for (0..SPRAY_N) |i| {
        const slot: i32 = @intCast(i);
        const cycle_f = now + hashf(slot, 7);
        const life = frac(cycle_f);
        const seed = hash2(slot, cell(cycle_f));
        const r = @as(f32, @floatFromInt(seed & 0xFFFF)) / 65535.0;
        const r2 = @as(f32, @floatFromInt((seed >> 16) & 0xFFFF)) / 65535.0;
        if (r * 0.999 >= amount) continue;
        // Mostly off the sides, forward of the stern, and some off the bow.
        var lx: f32 = undefined;
        var ly: f32 = undefined;
        var ox: f32 = 0;
        var oy: f32 = 0;
        if (r2 < 0.2) {
            lx = CRAFT_HALF_L;
            ly = (r2 * 10.0 - 1.0) * CRAFT_HALF_W;
            ox = 1;
        } else {
            const side: f32 = if ((seed & 0x1_0000) != 0) 1 else -1;
            lx = lerp(-CRAFT_HALF_L * 0.5, CRAFT_HALF_L, (r2 - 0.2) / 0.8);
            ly = side * CRAFT_HALF_W;
            oy = side;
        }
        const age = life * SPRAY_LIFE;
        // Out at 3 to 7 m/s and more when fast, up at 3 to 6, carried on a
        // little by the skirt, and slowed by the air until it goes with the
        // wind.
        const out = 3.0 + 4.0 * frac(r2 * 5.7) + speed * 0.15;
        const up = 3.0 + 3.0 * frac(r * 7.31);
        const dragged = age / (1.0 + 0.75 * age);
        const launch_x = cr_x - cr_vx * age + lx * c - ly * s;
        const launch_y = cr_y - cr_vy * age + lx * s + ly * c;
        const wx = launch_x + ((ox * c - oy * s) * out + cr_vx * 0.4 - air[0]) * dragged + air[0] * age;
        const wy = launch_y + ((ox * s + oy * c) * out + cr_vy * 0.4 - air[1]) * dragged + air[1] * age;
        var wz = base_z + up * dragged - 0.5 * GRAVITY * age * age;
        var alpha = (1.0 - life) * 0.7;
        // Spray that has fallen back lies on the water as foam and thins
        // away there, rather than vanishing as it touches.
        if (wz < 0) {
            alpha *= clampf(1.0 + wz / 0.8, 0, 1);
            if (alpha <= 0.01) continue;
            wz = 0;
        }
        const depth = (wx - cam_x) * cam_fx + (wy - cam_y) * cam_fy;
        if (depth < 2.0) continue;
        // Its velocity relative to the craft, which the camera follows.
        const fling = 1.0 / ((1.0 + 0.75 * age) * (1.0 + 0.75 * age));
        const vx = ((ox * c - oy * s) * out + cr_vx * 0.4 - air[0]) * fling + air[0] - cr_vx;
        const vy = ((ox * s + oy * c) * out + cr_vy * 0.4 - air[1]) * fling + air[1] - cr_vy;
        const vz = up * fling - GRAVITY * age;
        // Dense droplets scatter white; thin spray takes on the colour of the
        // water it was torn from.
        const body = waterBody(launch_x, launch_y, shallowsAt(launch_x, launch_y)) * splat(2.6);
        const tint = mix(body, splat(0.95), 0.55 + 0.3 * frac(r2 * 13.7)) * splat(light);
        const p: Puff = .{
            .x = wx,
            .y = wy,
            .z = wz,
            .radius = 1.0 + 4.0 * life,
            .depth = depth,
            .vr = vx * cam_rx + vy * cam_ry,
            .vz = vz,
            .tint = tint,
            .alpha = alpha,
        };
        var j = n;
        while (j > 0 and puffs[j - 1].depth < depth) : (j -= 1) puffs[j] = puffs[j - 1];
        puffs[j] = p;
        n += 1;
    }
    for (puffs[0..n]) |p| drawPuff(p);
}

const Puff = struct {
    x: f32,
    y: f32,
    z: f32,
    radius: f32,
    depth: f32,
    // Velocity across the view and up.
    vr: f32,
    vz: f32,
    tint: Rgb,
    alpha: f32,
};

// An elliptical Gaussian splat, blended over whatever is drawn behind it.
// It is drawn out along its motion, squashed into a sheet as it nears the
// water, lit from above and brighter looking toward the sun. Rather than a
// hard depth test, each pixel treats the puff as a ball and shows the part of
// it in front of the surface behind, so it fades into the water instead of
// being cut off along the waterline.
fn drawPuff(p: Puff) void {
    const scale = focal / p.depth;
    const sx = HALF_W + ((p.x - cam_x) * cam_rx + (p.y - cam_y) * cam_ry) * scale;
    const sy = horizon - (p.z - cam_z) * scale;
    const ry_w = minf(p.radius, maxf(p.z + 0.3, p.radius * 0.35));
    const rx_w = p.radius * (1.0 + 0.5 * (1.0 - ry_w / p.radius));
    const prx = rx_w * scale;
    const pry = ry_w * scale;
    if (prx < 0.5) return;
    // Stretch along the motion on screen, up to double.
    const vlen = @sqrt(p.vr * p.vr + p.vz * p.vz);
    const stretch = 1.0 + minf(vlen * 0.08, 1.0);
    const ux = if (vlen > 1e-3) p.vr / vlen else 1.0;
    const uy = if (vlen > 1e-3) -p.vz / vlen else 0.0;
    const squeeze = 1.0 - 1.0 / stretch;
    const reach = minf(maxf(prx, pry) * stretch, 120.0);
    const x0: usize = @intFromFloat(clampf(@ceil(sx - reach - 0.5), 0.0, HALF_W * 2.0));
    const x1: usize = @intFromFloat(clampf(@ceil(sx + reach - 0.5), 0.0, HALF_W * 2.0));
    const y0: usize = @intFromFloat(clampf(@ceil(sy - reach - 0.5), 0.0, @as(f32, SCREEN_H)));
    const y1: usize = @intFromFloat(clampf(@ceil(sy + reach - 0.5), 0.0, @as(f32, SCREEN_H)));
    const toward_sun = maxf(0, cam_fx * sun[0] + cam_fy * sun[1]);
    const glow = 1.0 + 0.35 * toward_sun * toward_sun * toward_sun;
    const top_lit = 0.18 * clampf(sun[2] * 2.0, 0, 1);
    const tint = fog(p.tint * splat(glow), p.depth);
    const edge = @exp(@as(f32, -3.5));
    var row = y0;
    while (row < y1) : (row += 1) {
        const oy = @as(f32, @floatFromInt(row)) + 0.5 - sy;
        var col = x0;
        while (col < x1) : (col += 1) {
            const ox = @as(f32, @floatFromInt(col)) + 0.5 - sx;
            const along = (ox * ux + oy * uy) * squeeze;
            const dx = (ox - along * ux) / prx;
            const dy = (oy - along * uy) / pry;
            const d2 = dx * dx + dy * dy;
            if (d2 >= 1) continue;
            const behind = zbuf[row * SCREEN_W + col];
            const half = p.radius * @sqrt(1.0 - d2);
            const shown = clampf((behind - p.depth + half) / (2.0 * half + 0.3), 0, 1);
            if (shown <= 0) continue;
            const w = (@exp(-3.5 * d2) - edge) / (1.0 - edge);
            const lit = tint * splat(1.0 - top_lit * dy);
            putPixel(col, row, mix(readPixel(col, row), lit, p.alpha * w * shown));
        }
    }
}

// The view

// Where the eye is for the current mode: in the cabin for walking, the
// desk, and the helm; behind the craft for the chase camera; and outside
// looking at it on the title and end screens.
fn setEye() void {
    focal = FOCAL;
    horizon = BASE_HORIZON;
    const view = if (mode == .paused) paused_from else mode;
    switch (view) {
        .walking => localEye(px, py, WALK_EYE + 0.03 * @sin(bob), pangle, look),
        .cubicle => {
            focal = CRT_FOCAL;
            localEye(SEAT_EYE[0], SEAT_EYE[1], SEAT_EYE[2], std.math.pi / 2.0 + head_yaw, CRT_LOOK + look * CRT_FOCAL / FOCAL);
        },
        .dashboard => {
            if (chase_cam) {
                eye_angle = chase_h;
                eye_x = cr_x - @cos(chase_h) * 55.0;
                eye_y = cr_y - @sin(chase_h) * 55.0;
                eye_z = 22.0;
                horizon = BASE_HORIZON - 120.0;
                eye_inside = false;
            } else {
                localEye(HELM_EYE[0], HELM_EYE[1], HELM_EYE[2], head_yaw, HELM_LOOK + look);
            }
        },
        else => {
            const a = cr_h + 2.3;
            eye_x = cr_x + @cos(a) * 62.0;
            eye_y = cr_y + @sin(a) * 62.0;
            eye_z = 14.0;
            eye_angle = a + std.math.pi;
            horizon = BASE_HORIZON - 55.0;
            eye_inside = false;
        },
    }
    if (shake_ms > 0 and eye_inside) {
        const k = @as(f32, @floatFromInt(shake_ms)) / 500.0 * 0.06;
        eye_x += (hashf(anim_ms, 1) - 0.5) * k;
        eye_z += (hashf(anim_ms, 2) - 0.5) * k;
    }
}

fn localEye(lx: f32, ly: f32, lz: f32, angle: f32, lk: f32) void {
    const w = toWorld(lx, ly);
    eye_x = w[0];
    eye_y = w[1];
    eye_z = deckZ() + lz;
    eye_angle = cr_h + angle;
    horizon = BASE_HORIZON + lk;
    eye_inside = true;
}

fn drawFrame() void {
    drawCrt();
    updateReadouts();
    chop = if (bench_view >= 0) BENCH_CHOP else seaState();
    if (bench_view >= 0) {
        const v = BENCH_VIEWS[@intCast(bench_view)];
        const saved = .{ cr_x, cr_y, cr_h };
        cr_x = v.craft[0];
        cr_y = v.craft[1];
        cr_h = v.craft[2];
        focal = v.focal;
        if (v.local) {
            localEye(v.eye[0], v.eye[1], v.eye[2], v.angle, v.look);
        } else {
            eye_x = v.eye[0];
            eye_y = v.eye[1];
            eye_z = v.eye[2];
            eye_angle = v.angle;
            horizon = BASE_HORIZON + v.look;
            eye_inside = false;
        }
        drawScene();
        drawGulls();
        drawSpray();
        cr_x = saved[0];
        cr_y = saved[1];
        cr_h = saved[2];
        return;
    }
    setEye();
    drawScene();
    drawWake();
    drawGulls();
    drawSpray();
    const view = if (mode == .paused) paused_from else mode;
    switch (view) {
        .walking => drawWalkingHud(),
        .cubicle => drawDeskHud(),
        .dashboard => drawDashboard(),
        else => {},
    }
    if (isPlaying(view) and map_on and view != .cubicle) drawMap();
    if (isPlaying(view) and message_ms > 0) drawTextCentered(30 * UI, 2, message, C_TITLE_ALT);
    switch (mode) {
        .title => drawTitle(),
        .paused => drawPaused(),
        .gameover => drawGameOver(),
        else => {},
    }
}

// The bridge's electronics, the best money could buy in 1998: a colour
// raster radar with ARPA target tracking, a fluxgate compass, and a DGPS
// receiver corrected by the Coast Guard's beacon on Angel Island, all wired
// to a vector chart that watches the course ahead for reefs.

// The antenna turns at 24 rpm. The picture is kept as it was scanned: an
// echo strength for each of RADAR_BEARINGS true bearings, out over
// RADAR_BINS steps of range. Bearing i lies at world angle i of them round
// from east; the antenna turns clockwise, so the index counts down.
const RADAR_RPM: f32 = 24.0;
const RADAR_BEARINGS: usize = 256;
const RADAR_BINS: usize = 64;
const NM: f32 = 1852.0;
const RADAR_RANGES = [_]f32{ 0.25 * NM, 0.5 * NM, 0.75 * NM, 1.5 * NM };
const RADAR_RANGE_TEXT = [_][]const u8{ ".25NM", ".5NM", ".75NM", "1.5NM" };
const RADAR_RANGE_MESSAGE = [_][]const u8{ "RADAR 0.25 NM", "RADAR 0.5 NM", "RADAR 0.75 NM", "RADAR 1.5 NM" };
const RADAR_START_RANGE: u8 = 2;
// Sea clutter close in, which the sensitivity time control mostly takes out.
const CLUTTER_RANGE: f32 = 250.0;
// The ARPA acquires a target after this many sweeps that paint it, and
// draws its true course and speed this far ahead.
const ARPA_ACQUIRE: u8 = 3;
const ARPA_VECTOR_S: f32 = 60.0;
// The chart looks this far along the course over ground for reefs.
const CHART_LOOKAHEAD_S: f32 = 30.0;
// DGPS positions, from the office's pier at the origin.
const ORIGIN_LAT_MIN: f32 = 37.0 * 60.0 + 47.5;
const ORIGIN_LON_MIN: f32 = 122.0 * 60.0 + 23.0;

var radar: [RADAR_BEARINGS * RADAR_BINS]u8 = [_]u8{0} ** (RADAR_BEARINGS * RADAR_BINS);
var radar_range: u8 = RADAR_START_RANGE;
// Where the antenna points, in bearings, and how many sweeps it has made.
var radar_pos: f32 = 0;
var radar_sweeps: u32 = 0;
// The ARPA's track of the speedboat: how many sweeps in a row have painted
// it, where and when it was last painted, and its estimated velocity.
var arpa_hits: u8 = 0;
var arpa_painted = false;
var arpa_ms: i32 = 0;
var arpa_x: f32 = 0;
var arpa_y: f32 = 0;
var arpa_vx: f32 = 0;
var arpa_vy: f32 = 0;

fn resetRadar() void {
    @memset(&radar, 0);
    radar_range = RADAR_START_RANGE;
    radar_pos = 0;
    radar_sweeps = 0;
    arpa_hits = 0;
    arpa_painted = false;
}

fn setRadarRange(r: u8) void {
    radar_range = r;
    // A new range starts a fresh picture, and the ARPA keeps its track.
    @memset(&radar, 0);
    showMessage(RADAR_RANGE_MESSAGE[r]);
}

const Echo = struct { k: f32 = 0, solid: bool = false, rival: bool = false };

// What the radar sees at a point, within tol of it: shores, piers and the
// freighter strongest, and solid, so they shadow what lies behind them; the
// bridge's deck, which the beam passes under; buoys with their reflectors;
// the speedboat; reefs' rocks awash, broken up; and the sandbanks faintly.
fn radarEcho(x: f32, y: f32, tol: f32) Echo {
    const grain = hashf(cell(x * 0.15), cell(y * 0.15));
    var e: Echo = .{};
    const rx = x - rv_x;
    const ry = y - rv_y;
    if (rx * rx + ry * ry < (RIVAL_HALF_L + tol) * (RIVAL_HALF_L + tol)) e = .{ .k = 0.75, .rival = true };
    if (x > BRIDGE_X0 and x < BRIDGE_X1 and @abs(y - BRIDGE_Y) < BRIDGE_HALF + tol) e.k = maxf(e.k, 0.85);
    for (&REEF_OUTLINES) |*o| {
        if (!nearOutline(o, x, y, tol) or outside(o, x, y) > tol) continue;
        e.k = maxf(e.k, 0.3 + 0.5 * grain);
        return e;
    }
    for (ISLANDS) |isl| {
        const dx = x - isl.x;
        const dy = y - isl.y;
        const d2 = dx * dx + dy * dy;
        if (d2 > (isl.r + tol) * (isl.r + tol)) continue;
        if (d2 < (isl.rock + tol) * (isl.rock + tol)) return .{ .k = 1, .solid = true };
        e.k = maxf(e.k, 0.45 + 0.2 * grain);
    }
    for (obstacles[0..obstacle_count]) |o| {
        const dx = x - o.cx;
        const dy = y - o.cy;
        if (dx * dx + dy * dy > (o.r + tol) * (o.r + tol)) continue;
        if (o.n == 0) {
            e.k = maxf(e.k, 0.8);
            continue;
        }
        const pts = obs_verts[o.first .. o.first + o.n];
        var out: f32 = -std.math.inf(f32);
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            const ex = b[0] - a[0];
            const ey = b[1] - a[1];
            out = maxf(out, (ey * (x - a[0]) - ex * (y - a[1])) / @sqrt(ex * ex + ey * ey));
        }
        if (out < tol) return .{ .k = 1, .solid = true };
    }
    for (&BANK_OUTLINES) |*o| {
        if (nearOutline(o, x, y, tol) and outside(o, x, y) < tol) e.k = maxf(e.k, 0.1 + 0.15 * grain);
    }
    return e;
}

// Scans one bearing out from the craft. Behind a run of solid echoes the
// beam is mostly spent, so land casts a shadow.
fn scanBearing(i: usize) void {
    const a = (@as(f32, @floatFromInt(i)) + 0.5) * 2.0 * std.math.pi / @as(f32, RADAR_BEARINGS);
    const dx = @cos(a);
    const dy = @sin(a);
    const step = RADAR_RANGES[radar_range] / @as(f32, RADAR_BINS);
    var beam: f32 = 1;
    var solid: u32 = 0;
    for (0..RADAR_BINS) |b| {
        const r = (@as(f32, @floatFromInt(b)) + 0.5) * step;
        const x = cr_x + dx * r;
        const y = cr_y + dy * r;
        const e = radarEcho(x, y, step * 0.5);
        var k = e.k * beam;
        if (r < CLUTTER_RANGE) {
            const sea = 1.0 - shallowsAt(x, y).k;
            const fade = 1.0 - r / CLUTTER_RANGE;
            k = maxf(k, hashf(@intCast(i), @as(i32, @intCast(b)) + @as(i32, @intCast(radar_sweeps % 4096)) * 131) * 0.4 * chop * sea * fade * fade);
        }
        radar[i * RADAR_BINS + b] = @intFromFloat(clampf(k, 0, 1) * 255.0);
        if (e.rival and beam > 0.5) paintRival();
        solid = if (e.solid) solid + 1 else 0;
        if (solid >= 2) beam = minf(beam, 0.12);
    }
}

// The ARPA updates its track each sweep that paints the speedboat,
// smoothing the velocity it measures between paints.
fn paintRival() void {
    if (arpa_painted) return;
    arpa_painted = true;
    if (arpa_hits > 0) {
        const dt = @as(f32, @floatFromInt(time_ms - arpa_ms)) * 0.001;
        if (dt > 0.5) {
            const vx = (rv_x - arpa_x) / dt;
            const vy = (rv_y - arpa_y) / dt;
            const k: f32 = if (arpa_hits == 1) 1.0 else 0.5;
            arpa_vx += (vx - arpa_vx) * k;
            arpa_vy += (vy - arpa_vy) * k;
        }
    } else {
        arpa_vx = 0;
        arpa_vy = 0;
    }
    arpa_x = rv_x;
    arpa_y = rv_y;
    arpa_ms = time_ms;
    arpa_hits +|= 1;
}

fn stepRadar() void {
    const n: f32 = @floatFromInt(RADAR_BEARINGS);
    const was = radar_pos;
    radar_pos -= RADAR_RPM / 60.0 * DT * n;
    var i: i32 = @intFromFloat(@floor(was));
    const to: i32 = @intFromFloat(@floor(radar_pos));
    while (i > to) : (i -= 1) scanBearing(@intCast(@mod(i, @as(i32, RADAR_BEARINGS))));
    if (radar_pos < 0) {
        // A full sweep: a target it didn't paint is lost.
        radar_pos += n;
        radar_sweeps +%= 1;
        if (!arpa_painted) arpa_hits = 0;
        arpa_painted = false;
    }
}

fn arpaTracking() bool {
    return arpa_hits >= ARPA_ACQUIRE;
}

// Where the ARPA puts the target now, from its last paint.
fn arpaNow() [2]f32 {
    const dt = @as(f32, @floatFromInt(time_ms - arpa_ms)) * 0.001;
    return .{ arpa_x + arpa_vx * dt, arpa_y + arpa_vy * dt };
}

// The closest point of approach to the tracked target, in metres, and the
// time to it in seconds, or null once it is opening.
fn arpaCpa() ?[2]f32 {
    const p = arpaNow();
    const px_ = p[0] - cr_x;
    const py_ = p[1] - cr_y;
    const wx = arpa_vx - cr_vx;
    const wy = arpa_vy - cr_vy;
    const w2 = wx * wx + wy * wy;
    if (w2 < 0.01) return null;
    const t = -(px_ * wx + py_ * wy) / w2;
    if (t <= 0) return null;
    const cx = px_ + wx * t;
    const cy = py_ + wy * t;
    return .{ @sqrt(cx * cx + cy * cy), t };
}

// The radar's level at a point of the display, given in the craft's frame
// as a share of the range ahead and to port, with the afterglow of the
// sweep: brightest just behind the antenna.
fn radarLevel(fwd: f32, port: f32) f32 {
    const r = @sqrt(fwd * fwd + port * port);
    if (r >= 1) return 0;
    const n: f32 = @floatFromInt(RADAR_BEARINGS);
    var a = (cr_h + std.math.atan2(port, fwd)) / (2.0 * std.math.pi) * n;
    a = a - @floor(a / n) * n;
    const i = @min(@as(usize, @intFromFloat(a)), RADAR_BEARINGS - 1);
    const b = @min(@as(usize, @intFromFloat(r * @as(f32, RADAR_BINS))), RADAR_BINS - 1);
    const k = @as(f32, @floatFromInt(radar[i * RADAR_BINS + b])) / 255.0;
    var age = a - radar_pos;
    age = (age - @floor(age / n) * n) / n;
    return k * (1.0 - 0.35 * age);
}

// The colour display's echo levels: weak green, yellow, then red.
fn radarRgb(k: f32) Rgb {
    if (k < 0.07) return .{ 0.01, 0.03, 0.09 };
    if (k < 0.28) return Rgb{ 0.05, 0.3, 0.15 } * splat(0.6 + k * 1.5);
    if (k < 0.55) return Rgb{ 0.95, 0.8, 0.15 } * splat(0.5 + k);
    return Rgb{ 1.0, 0.35, 0.15 } * splat(minf(0.4 + k * 0.7, 1.0));
}

// How far along the course over ground the chart finds a reef, if the
// craft would reach it in the next CHART_LOOKAHEAD_S.
fn chartAlarm() ?f32 {
    const sp = crSpeed();
    if (sp < 2) return null;
    const ux = cr_vx / sp;
    const uy = cr_vy / sp;
    const reach = sp * CHART_LOOKAHEAD_S;
    var d: f32 = 0;
    while (d < reach) : (d += 10) {
        const x = cr_x + ux * d;
        const y = cr_y + uy * d;
        for (&REEF_OUTLINES) |*o| {
            if (nearOutline(o, x, y, CRAFT_HALF_W) and outside(o, x, y) < CRAFT_HALF_W) return d;
        }
    }
    return null;
}

// A compass bearing in whole degrees, from a world angle.
fn compassDeg(a: f32) u32 {
    var d = 90.0 - a * 180.0 / std.math.pi;
    d -= @floor(d / 360.0) * 360.0;
    return @as(u32, @intFromFloat(d + 0.5)) % 360;
}

// Degrees and thousandths of a minute, as DGPS gives them: "37 48.123N".
fn formatDegMin(buf: []u8, minutes: f32, hemi: u8) []const u8 {
    const total: u32 = @intFromFloat(minutes * 1000.0 + 0.5);
    const deg = total / 60_000;
    const rest = total % 60_000;
    var w = std.io.fixedBufferStream(buf);
    w.writer().print("{d} {d:0>2}.{d:0>3}{c}", .{ deg, rest / 1000, rest % 1000, hemi }) catch {};
    return w.getWritten();
}

// The console's amber readouts, written once a frame.
var readout_bufs: [6][14]u8 = undefined;
var readouts: [6][]const u8 = .{""} ** 6;

fn updateReadouts() void {
    const sp = crSpeed();
    readouts[0] = std.fmt.bufPrint(&readout_bufs[0], "HDG {d:0>3}", .{compassDeg(cr_h)}) catch "";
    const tenths: u32 = @intFromFloat(sp * 1.944 * 10.0 + 0.5);
    readouts[1] = std.fmt.bufPrint(&readout_bufs[1], "SOG {d}.{d}KT", .{ tenths / 10, tenths % 10 }) catch "";
    readouts[2] = if (sp > 0.5) (std.fmt.bufPrint(&readout_bufs[2], "COG {d:0>3}", .{compassDeg(std.math.atan2(cr_vy, cr_vx))}) catch "") else "COG ---";
    readouts[3] = formatDegMin(&readout_bufs[3], ORIGIN_LAT_MIN + cr_y / NM, 'N');
    readouts[4] = formatDegMin(&readout_bufs[4], ORIGIN_LON_MIN - cr_x / (NM * @cos(SF_LATITUDE)), 'W');
    readouts[5] = "DGPS FIX";
}

// Overlays

fn pct(v: i32, of: i32) u32 {
    return @intCast(@divTrunc(@min(@max(v, 0), of) * 100, of));
}

fn drawStatusLine() void {
    blendRect(0, 0, W, 12 * UI, C_HUD);
    var buf: [5]u8 = undefined;
    drawText(4 * UI, 3 * UI, 1, clockText(&buf), C_TEXT);
    drawText(30 * UI, 3 * UI, 1, "BUILD", C_TEXT_DIM);
    drawNumber(52 * UI, 3 * UI, 1, @as(u32, code_keys) * 100 / CODE_KEYS, 1, if (code_keys >= CODE_KEYS) C_GOOD else C_TEXT);
    drawText(70 * UI, 3 * UI, 1, "UPLOAD", C_TEXT_DIM);
    drawNumber(96 * UI, 3 * UI, 1, pct(upload_ms, UPLOAD_MS), 1, if (uploaded()) C_GOOD else C_TEXT);
    drawText(114 * UI, 3 * UI, 1, "SAT", C_TEXT_DIM);
    drawText(128 * UI, 3 * UI, 1, if (satLocked()) "LOCK" else "LOST", if (satLocked()) C_GOOD else C_BAD);
    drawText(150 * UI, 3 * UI, 1, "HULL", C_TEXT_DIM);
    drawNumber(170 * UI, 3 * UI, 1, @intFromFloat(hull), 1, if (hull > 50) C_TEXT else C_BAD);
    drawText(190 * UI, 3 * UI, 1, craftState(), if (autopilot) C_GOOD else C_TEXT_DIM);
    // How far the rival's speedboat still has to go round its channel.
    drawText(236 * UI, 3 * UI, 1, "RIVAL", C_TEXT_DIM);
    if (rival == .moored) {
        drawText(258 * UI, 3 * UI, 1, "MOORED", C_TEXT_DIM);
    } else {
        drawNumber(258 * UI, 3 * UI, 1, @intFromFloat(rivalToGo()), 1, C_BAD);
        drawText(282 * UI, 3 * UI, 1, "M TO GO", C_TEXT_DIM);
    }
}

fn craftState() []const u8 {
    if (autopilot) return "AUTOPILOT";
    if (lift < 0.3) return if (lift_on) "LIFTING" else "STILL";
    if (!lift_on) return "SETTLING";
    return if (crSpeed() > 0.5) "DRIVING" else "HOVERING";
}

fn drawWalkingHud() void {
    drawStatusLine();
    fillRect(W / 2 - 1, H / 2 - 1, 3, 3, C_TEXT);
    var hint: []const u8 = "";
    if (near(DESK_X, CHAIR_Y, 1.4)) hint = "E  SIT AT YOUR DESK" else if (near(HELM[0], HELM[1], 1.6)) hint = "E  TAKE THE HELM";
    if (hint.len > 0) drawTextCentered(150 * UI, 2, hint, C_TEXT);
    blendRect(0, H - 12 * UI, W, 12 * UI, C_HUD);
    drawTextCentered(H - 9 * UI, 1, "ARROWS OR WASD WALK   MOUSE LOOK   E USE   M MAP   ESC PAUSE", C_TEXT_DIM);
}

fn drawDeskHud() void {
    blendRect(0, H - 12 * UI, W, 12 * UI, C_HUD);
    drawTextCentered(H - 9 * UI, 1, "TYPE TO CODE   ENTER UPLOAD   TAB STAND UP   ESC PAUSE", C_TEXT_DIM);
}

const PANEL_Y: i32 = 160;

// The helm's instruments. The dial shows the craft from above, nose up,
// with its velocity as an arrow: when the arrow and the nose disagree, the
// craft is sliding, and a vane on its card shows where the wind comes from.
// Beside it are the berth's range and the DGPS position, and the radar.
fn drawDashboard() void {
    drawStatusLine();
    const y0 = PANEL_Y * UI;
    blendRect(0, y0, W, H - y0, C_PANEL);
    // Throttle, reverse below the line.
    drawText(6 * UI, (PANEL_Y + 4) * UI, 1, "THR", C_TEXT_DIM);
    const bar_top = PANEL_Y + 12;
    const bar_h: i32 = 52;
    fillRect(8 * UI, bar_top * UI, 8 * UI, bar_h * UI, C_GAUGE);
    const zero = bar_top + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bar_h)) / 1.4));
    const ty = zero - @as(i32, @intFromFloat(throttle * @as(f32, @floatFromInt(bar_h)) / 1.4));
    if (ty < zero) fillRect(8 * UI, ty * UI, 8 * UI, (zero - ty) * UI, C_NEEDLE) else fillRect(8 * UI, zero * UI, 8 * UI, (ty - zero) * UI, C_BAD);
    fillRect(6 * UI, zero * UI, 12 * UI, UI, C_TEXT);
    // Lift fans.
    drawText(22 * UI, (PANEL_Y + 4) * UI, 1, "LIFT", C_TEXT_DIM);
    fillRect(26 * UI, bar_top * UI, 8 * UI, bar_h * UI, C_GAUGE);
    const lh: i32 = @intFromFloat(lift * @as(f32, @floatFromInt(bar_h)));
    fillRect(26 * UI, (bar_top + bar_h - lh) * UI, 8 * UI, lh * UI, if (lift_on) C_GOOD else C_TEXT_DIM);
    // Rudder.
    drawText(46 * UI, (PANEL_Y + 4) * UI, 1, "RUDDER", C_TEXT_DIM);
    fillRect(46 * UI, (PANEL_Y + 12) * UI, 80 * UI, 6 * UI, C_GAUGE);
    fillRect(85 * UI, (PANEL_Y + 11) * UI, UI, 8 * UI, C_TEXT_DIM);
    const rx: i32 = 86 + @as(i32, @intFromFloat(rudder * 38.0));
    fillRect((rx - 1) * UI, (PANEL_Y + 10) * UI, 3 * UI, 10 * UI, C_NEEDLE);
    // Speed in knots.
    const knots: u32 = @intFromFloat(crSpeed() * 1.944 + 0.5);
    drawNumber(46 * UI, (PANEL_Y + 26) * UI, 3, knots, 1, C_TEXT);
    drawText(72 * UI, (PANEL_Y + 32) * UI, 1, "KNOTS", C_TEXT_DIM);
    drawText(46 * UI, (PANEL_Y + 48) * UI, 1, craftState(), if (autopilot) C_GOOD else C_TEXT);
    drawText(46 * UI, (PANEL_Y + 58) * UI, 1, readouts[0], C_TEXT);
    drawText(82 * UI, (PANEL_Y + 58) * UI, 1, readouts[2], C_VELOCITY);
    // The drift dial, inside the fluxgate compass's card, which turns so the
    // bow is always up.
    const dcx: i32 = 160 * UI;
    const dcy: i32 = (PANEL_Y + 30) * UI;
    const dr: i32 = 24 * UI;
    ringCircle(dcx, dcy, dr, C_GAUGE);
    for (0..12) |k| {
        const card = toLocalDir(@cos(@as(f32, @floatFromInt(k)) * std.math.pi / 6.0), @sin(@as(f32, @floatFromInt(k)) * std.math.pi / 6.0));
        const rf: f32 = @floatFromInt(dr);
        if (k == 3) {
            drawText(dcx - @as(i32, @intFromFloat(card[1] * rf * 0.72)) - UI, dcy - @as(i32, @intFromFloat(card[0] * rf * 0.72)) - 2 * UI, 1, "N", C_TITLE_ALT);
            continue;
        }
        drawLine(dcx - @as(i32, @intFromFloat(card[1] * rf * 0.84)), dcy - @as(i32, @intFromFloat(card[0] * rf * 0.84)), dcx - @as(i32, @intFromFloat(card[1] * rf)), dcy - @as(i32, @intFromFloat(card[0] * rf)), C_TEXT_DIM);
    }
    // The true wind, from the masthead vane and anemometer corrected for the
    // craft's own way: a vane on the card where it comes from, and its speed.
    const w = wind();
    const wsp = @sqrt(w[0] * w[0] + w[1] * w[1]);
    drawText(88 * UI, (PANEL_Y + 48) * UI, 1, "WIND", C_TEXT_DIM);
    drawNumber(106 * UI, (PANEL_Y + 48) * UI, 1, @intFromFloat(wsp * 1.944 + 0.5), 1, C_WIND);
    if (wsp > 0.5) {
        const from = toLocalDir(-w[0] / wsp, -w[1] / wsp);
        const rf: f32 = @floatFromInt(dr);
        const vane_x = dcx - @as(i32, @intFromFloat(from[1] * rf * 1.12));
        const vane_y = dcy - @as(i32, @intFromFloat(from[0] * rf * 1.12));
        drawLine(vane_x, vane_y, dcx - @as(i32, @intFromFloat(from[1] * rf * 0.62)), dcy - @as(i32, @intFromFloat(from[0] * rf * 0.62)), C_WIND);
        fillRect(vane_x - UI, vane_y - UI, 3 * UI, 3 * UI, C_WIND);
    }
    drawLine(dcx, dcy - 9 * UI, dcx - 4 * UI, dcy + 7 * UI, C_TEXT);
    drawLine(dcx, dcy - 9 * UI, dcx + 4 * UI, dcy + 7 * UI, C_TEXT);
    drawLine(dcx - 4 * UI, dcy + 7 * UI, dcx + 4 * UI, dcy + 7 * UI, C_TEXT);
    const lv = toLocalDir(cr_vx, cr_vy);
    const sp = crSpeed();
    if (sp > 0.2) {
        const k = @as(f32, @floatFromInt(dr)) * minf(1.0, sp / 16.0) / sp;
        const ex = dcx - @as(i32, @intFromFloat(lv[1] * k));
        const ey = dcy - @as(i32, @intFromFloat(lv[0] * k));
        drawLine(dcx, dcy, ex, ey, C_VELOCITY);
        drawLine(dcx + 1, dcy, ex + 1, ey, C_VELOCITY);
        fillRect(ex - UI, ey - UI, 3 * UI, 3 * UI, C_VELOCITY);
    }
    drawText(138 * UI, (PANEL_Y + 58) * UI, 1, "DRIFT", C_TEXT_DIM);
    const drift: u32 = if (sp > 0.5) @intFromFloat(@abs(std.math.atan2(lv[1], lv[0])) * 180.0 / std.math.pi + 0.5) else 0;
    drawNumber(162 * UI, (PANEL_Y + 58) * UI, 1, drift, 1, if (drift > 30) C_TITLE_ALT else C_TEXT);
    // The berth: range and which way it lies from the bow.
    drawText(192 * UI, (PANEL_Y + 4) * UI, 1, "SAND HILL PIER", C_TEXT_DIM);
    const bx = BERTH[0] - cr_x;
    const by = BERTH[1] - cr_y;
    const dist = @sqrt(bx * bx + by * by);
    drawNumber(192 * UI, (PANEL_Y + 12) * UI, 2, @intFromFloat(dist), 1, C_TEXT);
    drawText(226 * UI, (PANEL_Y + 17) * UI, 1, "M", C_TEXT_DIM);
    const bl = toLocalDir(bx, by);
    const bd = @sqrt(bl[0] * bl[0] + bl[1] * bl[1]);
    if (bd > 1) {
        const ax: i32 = 241 * UI;
        const ay: i32 = (PANEL_Y + 17) * UI;
        drawLine(ax, ay, ax - @as(i32, @intFromFloat(bl[1] / bd * 7 * UI)), ay - @as(i32, @intFromFloat(bl[0] / bd * 7 * UI)), C_TITLE_ALT);
        fillRect(ax - UI, ay - UI, 3 * UI, 3 * UI, C_TITLE_ALT);
    }
    // The DGPS position, and the chart's warning of a reef on the course.
    drawText(192 * UI, (PANEL_Y + 30) * UI, 1, readouts[5], C_GOOD);
    drawText(192 * UI, (PANEL_Y + 38) * UI, 1, readouts[3], C_TEXT);
    drawText(192 * UI, (PANEL_Y + 45) * UI, 1, readouts[4], C_TEXT);
    if (docked) {
        drawText(192 * UI, (PANEL_Y + 56) * UI, 1, "IN THE BERTH", C_GOOD);
    } else if (chartAlarm()) |d| {
        if (@mod(@divTrunc(anim_ms, 250), 2) == 0) {
            drawText(192 * UI, (PANEL_Y + 56) * UI, 1, "REEF", C_BAD);
            drawNumber(212 * UI, (PANEL_Y + 56) * UI, 1, @intFromFloat(d), 1, C_BAD);
            drawText(228 * UI, (PANEL_Y + 56) * UI, 1, "M", C_BAD);
        }
    }
    drawRadar(286 * UI, (PANEL_Y + 34) * UI, 31 * UI);
    drawText(4 * UI, (PANEL_Y + 68) * UI, 1, "W S THROTTLE  A D RUDDER  L LIFT  X CUT", C_TEXT_DIM);
    drawText(4 * UI, (PANEL_Y + 75) * UI, 1, "T AUTOPILOT  R RANGE  C CAMERA  M MAP  E STAND", C_TEXT_DIM);
}

// The radar's display, head up, with its range rings, the heading line,
// the sweep, north on the bearing ring, the berth as a DGPS waypoint, and
// the ARPA's symbol and true vector on the speedboat once it has it.
fn drawRadar(cx: i32, cy: i32, r: i32) void {
    const rf: f32 = @floatFromInt(r);
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        const y = cy + dy;
        if (y < 0 or y >= H) continue;
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy > r * r) continue;
            const x = cx + dx;
            if (x < 0 or x >= W) continue;
            const k = radarLevel(-@as(f32, @floatFromInt(dy)) / rf, -@as(f32, @floatFromInt(dx)) / rf);
            const c = radarRgb(k);
            const idx = ktx.HEADER_SIZE + (@as(usize, @intCast(y)) * SCREEN_W + @as(usize, @intCast(x))) * 4;
            inline for (0..3) |ch| output_buf[idx + ch] = @intFromFloat(clampf(c[ch], 0, 1) * 255.0);
            output_buf[idx + 3] = 0xFF;
        }
    }
    const ring: Color = .{ 0x30, 0x48, 0x60, 0xFF };
    ringCircle(cx, cy, @divTrunc(r, 3), ring);
    ringCircle(cx, cy, @divTrunc(r * 2, 3), ring);
    ringCircle(cx, cy, r, C_GAUGE);
    drawLine(cx, cy, cx, cy - r, .{ 0xB0, 0xB8, 0xC0, 0xFF });
    // The sweep.
    const sweep = toLocalDir(@cos(radar_pos / @as(f32, RADAR_BEARINGS) * 2.0 * std.math.pi), @sin(radar_pos / @as(f32, RADAR_BEARINGS) * 2.0 * std.math.pi));
    drawLine(cx, cy, cx - @as(i32, @intFromFloat(sweep[1] * rf)), cy - @as(i32, @intFromFloat(sweep[0] * rf)), .{ 0x50, 0xA0, 0x70, 0xFF });
    const north = toLocalDir(0, 1);
    drawText(cx - @as(i32, @intFromFloat(north[1] * (rf - 4 * UI))) - UI, cy - @as(i32, @intFromFloat(north[0] * (rf - 4 * UI))) - 2 * UI, 1, "N", C_TITLE_ALT);
    const s = rf / RADAR_RANGES[radar_range];
    if (radarPoint(BERTH[0], BERTH[1], cx, cy, s, rf)) |p| ringCircle(p[0], p[1], 2 * UI, C_GOOD);
    if (arpaTracking()) {
        const a = arpaNow();
        if (radarPoint(a[0], a[1], cx, cy, s, rf)) |p| {
            ringCircle(p[0], p[1], 3 * UI, C_TEXT);
            const v = toLocalDir(arpa_vx, arpa_vy);
            drawLine(p[0], p[1], p[0] - @as(i32, @intFromFloat(v[1] * ARPA_VECTOR_S * s)), p[1] - @as(i32, @intFromFloat(v[0] * ARPA_VECTOR_S * s)), C_TEXT);
        }
    }
    fillRect(cx - UI / 2, cy - UI / 2, UI, UI, C_TEXT);
    drawText(cx - r - 2 * UI, cy + r + 2 * UI, 1, RADAR_RANGE_TEXT[radar_range], C_TEXT_DIM);
    // The ARPA's closest approach to the speedboat, and how long until it.
    if (!arpaTracking()) return;
    const tx = cx - r - 2 * UI;
    const ty = cy + r + 9 * UI;
    if (arpaCpa()) |cpa| {
        const hundredths: u32 = @intFromFloat(@min(cpa[0] / NM * 100.0 + 0.5, 99.0));
        var buf: [16]u8 = undefined;
        const secs: u32 = @intFromFloat(@min(cpa[1], 5999.0));
        const text = std.fmt.bufPrint(&buf, "CPA.{d:0>2}NM {d}:{d:0>2}", .{ hundredths, secs / 60, secs % 60 }) catch "";
        drawText(tx, ty, 1, text, C_TEXT);
    } else {
        drawText(tx, ty, 1, "ARPA OPENING", C_TEXT_DIM);
    }
}

// Where a point of the bay falls on the radar's display, if on it.
fn radarPoint(x: f32, y: f32, cx: i32, cy: i32, s: f32, rf: f32) ?[2]i32 {
    const l = toLocalDir(x - cr_x, y - cr_y);
    const px_ = -l[1] * s;
    const py_ = -l[0] * s;
    if (px_ * px_ + py_ * py_ > rf * rf) return null;
    return .{ cx + @as(i32, @intFromFloat(px_)), cy + @as(i32, @intFromFloat(py_)) };
}

const MAP_X0: f32 = -950;
const MAP_Y1: f32 = 2850;
const MAP_SCALE: f32 = 0.03 * @as(f32, UI);

fn mapPoint(x: f32, y: f32) [2]i32 {
    return .{
        @intFromFloat(clampf(@as(f32, 200 * UI) + (x - MAP_X0) * MAP_SCALE, -2000, 2000)),
        @intFromFloat(clampf(@as(f32, 16 * UI) + (MAP_Y1 - y) * MAP_SCALE, -2000, 2000)),
    };
}

fn mapOutline(o: *const Outline, c: Color) void {
    for (0..o.n) |i| {
        const p = o.pts[i];
        const q = o.pts[(i + 1) % o.n];
        const m0 = mapPoint(p[0], p[1]);
        const m1 = mapPoint(q[0], q[1]);
        drawLine(m0[0], m0[1], m1[0], m1[1], c);
    }
}

// A chart of the bay: the flats, sandbanks, obstacles and reefs, the route,
// the berth, the rival's speedboat (red), and the craft with its heading
// (white) and its course (blue).
fn drawMap() void {
    const a = mapPoint(MAP_X0, MAP_Y1);
    const b = mapPoint(3050, -450);
    blendRect(a[0], a[1], b[0] - a[0], b[1] - a[1], C_MAP_BG);
    for (&FLAT_OUTLINES) |*o| mapOutline(o, C_MAP_FLATS);
    for (&BANK_OUTLINES) |*o| mapOutline(o, C_MAP_SAND);
    for (ISLANDS) |isl| {
        const n: f32 = @floatFromInt(ISLAND_SIDES);
        for (0..ISLAND_SIDES) |k| {
            const a0 = (@as(f32, @floatFromInt(k)) + 0.5) * 2.0 * std.math.pi / n;
            const a1 = a0 + 2.0 * std.math.pi / n;
            const m0 = mapPoint(isl.x + isl.r * @cos(a0), isl.y + isl.r * @sin(a0));
            const m1 = mapPoint(isl.x + isl.r * @cos(a1), isl.y + isl.r * @sin(a1));
            drawLine(m0[0], m0[1], m1[0], m1[1], C_MAP_SAND);
        }
    }
    for (obstacles[0..obstacle_count]) |o| {
        if (o.n == 0) {
            const p = mapPoint(o.cx, o.cy);
            fillRect(p[0], p[1], 1, 1, C_TITLE_ALT);
            continue;
        }
        const pts = obs_verts[o.first .. o.first + o.n];
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            const m0 = mapPoint(p[0], p[1]);
            const m1 = mapPoint(q[0], q[1]);
            drawLine(m0[0], m0[1], m1[0], m1[1], C_MAP_LAND);
        }
    }
    for (&REEF_OUTLINES) |*o| mapOutline(o, C_BAD);
    const b0 = mapPoint(BRIDGE_X0, BRIDGE_Y);
    const b1 = mapPoint(BRIDGE_X1, BRIDGE_Y);
    drawLine(b0[0], b0[1], b1[0], b1[1], C_TEXT_DIM);
    for (ROUTE[0 .. ROUTE.len - 1], 0..) |p, i| {
        const q = ROUTE[i + 1];
        const m0 = mapPoint(p[0], p[1]);
        const m1 = mapPoint(q[0], q[1]);
        drawLine(m0[0], m0[1], m1[0], m1[1], C_MAP_ROUTE);
    }
    const bp = mapPoint(BERTH[0], BERTH[1]);
    ringCircle(bp[0], bp[1], 3 * UI, C_GOOD);
    const r = mapPoint(rv_x, rv_y);
    drawLine(r[0], r[1], r[0] + @as(i32, @intFromFloat(@cos(rv_h) * 6 * UI)), r[1] - @as(i32, @intFromFloat(@sin(rv_h) * 6 * UI)), C_BAD);
    fillRect(r[0] - UI, r[1] - UI, 2 * UI, 2 * UI, C_BAD);
    const c = mapPoint(cr_x, cr_y);
    const hx = @cos(cr_h);
    const hy = @sin(cr_h);
    drawLine(c[0], c[1], c[0] + @as(i32, @intFromFloat(hx * 10 * UI)), c[1] - @as(i32, @intFromFloat(hy * 10 * UI)), C_TEXT);
    const sp = crSpeed();
    if (sp > 0.5) drawLine(c[0], c[1], c[0] + @as(i32, @intFromFloat(cr_vx / sp * 10 * UI)), c[1] - @as(i32, @intFromFloat(cr_vy / sp * 10 * UI)), C_VELOCITY);
    fillRect(c[0] - UI, c[1] - UI, 3 * UI, 3 * UI, C_TITLE);
}

fn drawTitle() void {
    blendRect(0, 0, W, H, .{ 0x06, 0x05, 0x08, 0x60 });
    drawTextCentered(24 * UI, 5, "HOVERCRAFTSMAN", C_TITLE);
    drawTextCentered(54 * UI, 2, "SAN FRANCISCO BAY - 1998", C_TEXT);
    drawTextCentered(80 * UI, 1, "YOUR STARTUP'S OFFICE IS AN ORANGE HOVERCRAFT", C_TEXT);
    drawTextCentered(90 * UI, 1, "WRITE THE DEMO ON YOUR 17 INCH CRT, UPLOAD IT BY SATELLITE,", C_TEXT);
    drawTextCentered(100 * UI, 1, "AND STOP IN THE BERTH AT SAND HILL PIER BEFORE 5PM", C_TEXT);
    drawTextCentered(110 * UI, 1, "BEFORE YOUR RIVAL'S SPEEDBOAT GETS THERE", C_TEXT);
    drawTextCentered(128 * UI, 1, "A HOVERCRAFT HAS NO TYRES: TURNING CHANGES WHERE IT POINTS,", C_TEXT_DIM);
    drawTextCentered(138 * UI, 1, "NOT WHERE IT GOES. LESS THROTTLE MEANS LESS STEERING.", C_TEXT_DIM);
    drawTextCentered(148 * UI, 1, "IT CAN CROSS SANDBANKS AND SHALLOWS THE SPEEDBOAT CAN'T, BUT NOT REEFS.", C_TEXT_DIM);
    drawTextCentered(170 * UI, 2, "PRESS SPACE TO START", C_TITLE_ALT);
    if (hi_score > 0) {
        var buf: [10]u8 = undefined;
        drawText(6 * UI, H - 10 * UI, 1, "HI", C_TEXT_DIM);
        drawText(18 * UI, H - 10 * UI, 1, formatNumber(&buf, hi_score, 1), C_TEXT);
    }
}

fn drawPaused() void {
    blendRect(0, 0, W, H, C_SHADE);
    drawTextCentered(80 * UI, 4, "PAUSED", C_TEXT);
    drawTextCentered(112 * UI, 2, "P TO RESUME   R TO RESTART", C_TEXT_DIM);
    var buf: [10]u8 = undefined;
    drawText(60 * UI, 150 * UI, 1, "CRAFT BSP POLYGONS", C_TEXT_DIM);
    drawText(160 * UI, 150 * UI, 1, formatNumber(&buf, @intCast(craft_tree.polys), 1), C_TEXT);
    drawText(60 * UI, 160 * UI, 1, "BAY BSP POLYGONS", C_TEXT_DIM);
    drawText(160 * UI, 160 * UI, 1, formatNumber(&buf, @intCast(world_tree.polys), 1), C_TEXT);
    drawText(60 * UI, 170 * UI, 1, "DRAWN LAST FRAME", C_TEXT_DIM);
    drawText(160 * UI, 170 * UI, 1, formatNumber(&buf, stat_polys, 1), C_TEXT);
}

fn drawGameOver() void {
    blendRect(0, 0, W, H, C_SHADE);
    const title: []const u8 = switch (outcome) {
        .funded => "FUNDED!",
        .late => "TOO LATE",
        .wrecked => "SHIPWRECKED",
        .scooped => "SCOOPED",
        .none => "GAME OVER",
    };
    const line: []const u8 = switch (outcome) {
        .funded => "SAND HILL CAPITAL LEAD YOUR SERIES A",
        .late => "THE INVESTORS WENT HOME AT FIVE",
        .wrecked => "THE OFFICE IS TAKING ON WATER",
        .scooped => "THE SPEEDBOAT PITCHED FIRST",
        .none => "",
    };
    drawTextCentered(56 * UI, 4, title, if (outcome == .funded) C_GOOD else C_BAD);
    drawTextCentered(90 * UI, 2, line, C_TEXT);
    drawTextCentered(118 * UI, 2, if (score >= hi_score and score > 0) "NEW HIGH SCORE" else "SCORE", C_TEXT_DIM);
    var buf: [10]u8 = undefined;
    drawTextCentered(134 * UI, 3, formatNumber(&buf, score, 1), C_TEXT);
    drawTextCentered(186 * UI, 2, "PRESS SPACE TO PLAY AGAIN", C_TITLE_ALT);
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
// Lower case draws as upper case.
fn glyph(ch_in: u8) u15 {
    const ch = std.ascii.toUpper(ch_in);
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
        '.' => 0b000_000_000_000_010,
        ',' => 0b000_000_000_010_100,
        ':' => 0b000_010_000_010_000,
        ';' => 0b000_010_000_010_100,
        '!' => 0b010_010_010_000_010,
        '?' => 0b110_001_010_000_010,
        '/' => 0b001_001_010_100_100,
        '(' => 0b001_010_010_010_001,
        ')' => 0b100_010_010_010_100,
        '#' => 0b101_111_101_111_101,
        '$' => 0b011_110_010_011_110,
        '=' => 0b000_111_000_111_000,
        '<' => 0b001_010_100_010_001,
        '>' => 0b100_010_001_010_100,
        '{' => 0b011_010_110_010_011,
        '}' => 0b110_010_011_010_110,
        '[' => 0b011_010_010_010_011,
        ']' => 0b110_010_010_010_110,
        '\'' => 0b010_010_000_000_000,
        '"' => 0b101_101_000_000_000,
        '_' => 0b000_000_000_000_111,
        '@' => 0b111_101_111_100_011,
        '%' => 0b101_001_010_100_101,
        '*' => 0b000_101_010_101_000,
        '&' => 0b010_101_010_101_011,
        '|' => 0b010_010_010_010_010,
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
    hi_score = 0;
    bench_view = -1;
    flat_shading = false;
    reference_render = false;
    rng_state = 0x5EED_1998;
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

fn press(at: i64, key: i32) void {
    begin_update_at(at);
    _ = key_event(key, FLAG_KEY_DOWN);
    _ = key_event(key, 0);
    _ = finish_update();
}

// Puts the craft on a full cushion, heading east at a speed, with nobody at
// the helm, in still air.
fn hoverForTest(speed: f32) void {
    mode = .walking;
    still_air = true;
    lift_on = true;
    lift = 1;
    cr_h = 0;
    cr_r = 0;
    cr_vx = speed;
    cr_vy = 0;
    cr_x = 1300;
    cr_y = 1250;
    autopilot = false;
}

fn courseOff() f32 {
    return wrapAngle(std.math.atan2(cr_vy, cr_vx) - cr_h);
}

test "title renders, then every view renders inside and out" {
    resetForTest();
    try std.testing.expectEqual(@as(u32, OUTPUT_BYTES), renderImpl(0));
    try std.testing.expectEqual(Mode.title, mode);
    try std.testing.expect(craft_tree.polys > 300);
    try std.testing.expect(world_tree.polys > 300);
    var v: i32 = 0;
    while (v < BENCH_VIEWS.len) : (v += 1) {
        try std.testing.expectEqual(@as(i32, 1), bench_set_view(v, 0));
        _ = renderImpl(0);
        try std.testing.expect(stat_polys > 0);
    }
    try std.testing.expectEqual(@as(i32, 0), bench_set_view(-1, 0));
}

test "the BSP draws the same picture as a plain depth buffer" {
    resetForTest();
    _ = renderImpl(0);
    var v: i32 = 0;
    while (v < BENCH_VIEWS.len) : (v += 1) {
        _ = bench_set_view(v, 0);
        _ = renderImpl(0);
        const a = output_buf;
        _ = bench_set_view(v, BENCH_REFERENCE);
        _ = renderImpl(0);
        var same: usize = 0;
        var i: usize = 0;
        while (i < SCREEN_W * SCREEN_H) : (i += 1) {
            const o = ktx.HEADER_SIZE + i * 4;
            var ok = true;
            for (0..3) |ch| ok = ok and @abs(@as(i32, a[o + ch]) - @as(i32, output_buf[o + ch])) <= 8;
            if (ok) same += 1;
        }
        try std.testing.expect(same * 1000 >= SCREEN_W * SCREEN_H * 995);
    }
    _ = bench_set_view(-1, 0);
}

test "from the desk the CRT fills the middle of the view" {
    _ = startForTest();
    try std.testing.expectEqual(Mode.cubicle, mode);
    _ = renderImpl(0);
    const mid = (SCREEN_H / 2) * SCREEN_W + SCREEN_W / 2;
    try std.testing.expectEqual(COVER_CRAFT, covered[mid]);
    try std.testing.expect(zbuf[mid] > 0.5 and zbuf[mid] < 0.8);
}

test "typing writes the demo; held keys and Enter too early do nothing" {
    var t = startForTest();
    t += 1;
    begin_update_at(t);
    try std.testing.expectEqual(@as(i32, 1), key_event('k', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), key_event('k', FLAG_KEY_DOWN | FLAG_KEY_REPEAT));
    _ = key_event('k', 0);
    _ = finish_update();
    try std.testing.expectEqual(@as(u16, 1), code_keys);
    t += 1;
    press(t, XK_ENTER);
    try std.testing.expect(!uploading);
    while (code_keys < CODE_KEYS) {
        t += 1;
        press(t, 'w');
    }
    try std.testing.expectEqual(Mode.cubicle, mode);
    t += 1;
    press(t, XK_ENTER);
    try std.testing.expect(uploading);
}

// Walks toward each point in turn, as a held forward key would.
fn walkTo(points: []const [2]f32, at: *i64) !void {
    for (points) |p| {
        var guard: usize = 0;
        while ((px - p[0]) * (px - p[0]) + (py - p[1]) * (py - p[1]) > 0.04) : (guard += 1) {
            if (guard > 2000) return error.Stuck;
            pangle = std.math.atan2(p[1] - py, p[0] - px);
            keys_down = KEY_FWD;
            at.* += 16;
            _ = runUpdate(at.*);
        }
    }
    keys_down = 0;
}

test "stand up, walk out of the cubicle to the helm, take it, and stand again" {
    var t = startForTest();
    t += 1;
    press(t, XK_TAB);
    try std.testing.expectEqual(Mode.walking, mode);
    try walkTo(&.{ .{ 6.25, 4.6 }, .{ 6.25, 1.5 }, .{ 10.6, 0.5 }, .{ 10.8, 0 } }, &t);
    t += 1;
    press(t, 'e');
    try std.testing.expectEqual(Mode.dashboard, mode);
    _ = renderImpl(0);
    t += 1;
    press(t, 'e');
    try std.testing.expectEqual(Mode.walking, mode);
}

test "partitions and the cabin walls stop a walker" {
    var t = startForTest();
    t += 1;
    press(t, XK_TAB);
    // Straight at the aisle partition in front of your cubicle.
    try std.testing.expectError(error.Stuck, walkTo(&.{.{ 8.5, 0 }}, &t));
    try std.testing.expect(py > AISLE);
    teleportWalker(0, 0);
    try std.testing.expectError(error.Stuck, walkTo(&.{.{ 0, -12 }}, &t));
    try std.testing.expect(py > -CABIN_SIDE);
}

fn teleportWalker(x: f32, y: f32) void {
    px = x;
    py = y;
    pvx = 0;
    pvy = 0;
}

test "pause keeps the mode it came from and stops the clock" {
    var t = startForTest();
    t += 16;
    _ = runUpdate(t);
    t += 1;
    begin_update_at(t);
    try std.testing.expectEqual(@as(i32, 1), key_event(XK_ESCAPE, FLAG_KEY_DOWN));
    try std.testing.expectEqual(t, finish_update());
    try std.testing.expectEqual(Mode.paused, mode);
    const frozen = time_ms;
    _ = runUpdate(t + 5000);
    try std.testing.expectEqual(frozen, time_ms);
    _ = renderImpl(0);
    press(t + 5001, 'p');
    try std.testing.expectEqual(Mode.cubicle, mode);
}

test "title waits without wakes, then fixed steps run before events" {
    resetForTest();
    _ = renderImpl(0);
    try std.testing.expectEqual(@as(i64, 1), runUpdate(1));
    begin_update_at(2);
    try std.testing.expectEqual(@as(i32, 1), key_event(' ', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i64, 18), finish_update());
    try std.testing.expectEqual(Mode.cubicle, mode);
    try std.testing.expectEqual(@as(i64, 34), runUpdate(18));
    try std.testing.expectEqual(@as(i32, 16), time_ms);
}

test "with the skirt down the craft stays put at full throttle" {
    _ = startForTest();
    mode = .walking;
    throttle = 1;
    rudder = 1;
    for (0..600) |_| stepGame();
    try std.testing.expectApproxEqAbs(START[0], cr_x, 1e-3);
    try std.testing.expectApproxEqAbs(START[1], cr_y, 1e-3);
    lift_on = true;
    rudder = 0;
    for (0..600) |_| stepGame();
    try std.testing.expect(cr_y > START[1] + 20);
}

test "closing the throttle takes the steering away" {
    _ = startForTest();
    hoverForTest(12);
    throttle = 1;
    rudder = 1;
    for (0..60) |_| stepCraft();
    const powered = @abs(cr_r);
    hoverForTest(12);
    throttle = 0;
    rudder = 1;
    for (0..60) |_| stepCraft();
    const coasting = @abs(cr_r);
    try std.testing.expect(powered > 2.5 * coasting);
    // Stopped, with the throttle closed, the rudders do nothing at all.
    hoverForTest(0);
    throttle = 0;
    rudder = 1;
    for (0..120) |_| stepCraft();
    try std.testing.expectApproxEqAbs(@as(f32, 0), cr_r, 1e-6);
}

test "the heading turns long before the course does" {
    _ = startForTest();
    hoverForTest(14);
    throttle = 1;
    rudder = -1;
    var steps: usize = 0;
    while (cr_h < std.math.pi / 2.0 and steps < 2000) : (steps += 1) stepCraft();
    try std.testing.expect(steps < 2000);
    // Pointing north, but still going mostly east.
    try std.testing.expect(@abs(courseOff()) > std.math.pi / 4.0);
    rudder = 0;
    for (0..1600) |_| stepCraft();
    try std.testing.expect(@abs(courseOff()) < 0.25);
}

test "hitting a bridge pier dents the hull and the craft stays out of it" {
    _ = startForTest();
    hoverForTest(0);
    cr_x = PIER_X0;
    cr_y = BRIDGE_Y - 60;
    cr_h = std.math.pi / 2.0;
    cr_vy = 9;
    throttle = 0.4;
    for (0..400) |_| {
        stepGame();
        if (mode != .walking) break;
    }
    try std.testing.expect(hull < 100);
    for (HULL_CIRCLES) |lx| {
        const p = toWorld(lx, 0);
        for (obstacles[0..obstacle_count]) |o| {
            if (obstacleContact(o, p[0], p[1], HULL_R)) |ct| try std.testing.expect(ct.depth < 0.5);
        }
    }
}

test "sheds, trees and scrub stand on the shores, clear of the hills and the office" {
    resetForTest();
    _ = renderImpl(0);
    var counts = [_]usize{0} ** 3;
    for (polys[world_tree.first .. world_tree.first + world_tree.polys]) |p| {
        const k: usize = switch (surfs[p.surf].mat) {
            .shed => 0,
            .tree => 1,
            .scrub => 2,
            .trunk, .shed_roof => 3,
            else => continue,
        };
        if (k < counts.len) counts[k] += 1;
        for (pverts[p.first .. p.first + p.n]) |v| {
            var ashore = false;
            for (SHORES) |s| ashore = ashore or (v[0] >= s[0] - 0.01 and v[0] <= s[2] + 0.01 and v[1] >= s[1] - 0.01 and v[1] <= s[3] + 0.01);
            try std.testing.expect(ashore and v[2] >= SHORE_Z - 0.01);
            try std.testing.expect(shoreClear(v, 0));
        }
    }
    // Four walls to a shed, eleven faces to a tree's crown and ten to a
    // clump of scrub: dozens of sheds and hundreds of trees and clumps.
    try std.testing.expect(counts[0] > 4 * 60 and counts[1] > 11 * 300 and counts[2] > 10 * 120);
    // The BSP stays well inside its tables.
    try std.testing.expect(bnode_count < MAX_BNODES * 3 / 4 and poly_count < MAX_POLYS * 3 / 4);
}

test "the water shelves up to the beaches, banks, reefs and mud flats, and is deep elsewhere" {
    bakeRipples();
    const apothem = @cos(std.math.pi / @as(f32, @floatFromInt(ISLAND_SIDES)));
    for (ISLANDS) |isl| {
        // Straight out from the middle of a face. The flats round an island
        // can make the water past its own shelf shallow too.
        const a = 2.0 * std.math.pi / @as(f32, @floatFromInt(ISLAND_SIDES));
        const edge = isl.r * apothem;
        const at = struct {
            fn f(i: Island, ang: f32, d: f32) Shallows {
                return shallowsAt(i.x + d * @cos(ang), i.y + d * @sin(ang));
            }
        }.f;
        try std.testing.expectApproxEqAbs(@as(f32, 1), at(isl, a, edge + 0.01).k, 0.01);
        try std.testing.expect(at(isl, a, edge + BEACH_SHELF * 0.5).k > 0.49);
        try std.testing.expect(!at(isl, a, edge + 1).mud);
    }
    // Off the middle of each bank's and reef's long side, at the water's
    // edge and past the shelf. Only the reefs break and show rock.
    for (BANKS, &BANK_OUTLINES) |b, *o| {
        const n = o.ns[2];
        const m: [2]f32 = .{ (o.pts[2][0] + o.pts[3][0]) * 0.5, (o.pts[2][1] + o.pts[3][1]) * 0.5 };
        const edge = shallowsAt(m[0] + n[0] * (BANK_RUN + 0.5), m[1] + n[1] * (BANK_RUN + 0.5));
        try std.testing.expect(edge.k > 0.98 and edge.surf == 0 and edge.rock == 0);
        try std.testing.expect(shallowsAt(m[0] + n[0] * (BANK_RUN + BANK_SHELF + 1), m[1] + n[1] * (BANK_RUN + BANK_SHELF + 1)).k < edge.k - 0.3);
        try std.testing.expectApproxEqAbs(b.h, groundAt(b.p.x, b.p.y).z, 1e-4);
        try std.testing.expectEqual(@as(f32, 0), groundAt(m[0] + n[0] * (BANK_RUN + 0.5), m[1] + n[1] * (BANK_RUN + 0.5)).z);
    }
    for (REEFS, &REEF_OUTLINES) |r, *o| {
        const n = o.ns[2];
        const m: [2]f32 = .{ (o.pts[2][0] + o.pts[3][0]) * 0.5, (o.pts[2][1] + o.pts[3][1]) * 0.5 };
        const edge = shallowsAt(m[0] + n[0] * 0.5, m[1] + n[1] * 0.5);
        try std.testing.expect(edge.k > 0.98 and edge.surf > 0.9 and edge.rock > 0.9);
        const inside = shallowsAt(r.x, r.y);
        try std.testing.expect(inside.surf >= 0.45 and inside.rock == 1);
        try std.testing.expectEqual(@as(f32, 0), shallowsAt(m[0] + n[0] * (REEF_SURF + 1), m[1] + n[1] * (REEF_SURF + 1)).surf);
        // Reefs aren't ground: the craft hits them instead.
        try std.testing.expectEqual(@as(f32, 0), groundAt(r.x, r.y).z);
    }
    // Inside the flats, and well clear of them.
    try std.testing.expect(shallowsAt(1500, 2200).k > FLAT_K * 0.75);
    try std.testing.expectEqual(@as(f32, 0), shallowsAt(1100, 1100).k);
    // Just off the mud flats' southern edge, and past its shelf.
    const off = shallowsAt(2400, 80 - 5);
    try std.testing.expect(off.mud and off.k > 0.85);
    try std.testing.expectEqual(@as(f32, 0), shallowsAt(2400, 80 - MUD_SHELF - 1).k);
    // Both piers, both berths and the navigation span are in open water.
    for ([_][2]f32{ START, BERTH, .{ RIVAL_MOORING[0], RIVAL_MOORING[1] }, RIVAL_BERTH, .{ 1100, BRIDGE_Y } }) |p| {
        try std.testing.expectEqual(@as(f32, 0), shallowsAt(p[0], p[1]).k);
    }
}

test "the beaches rise from the water to the foot of the rock" {
    const apothem = @cos(std.math.pi / @as(f32, @floatFromInt(ISLAND_SIDES)));
    for (ISLANDS) |isl| {
        for (0..ISLAND_SIDES) |k| {
            // Midway along each face, and part way to its corner.
            const a = (@as(f32, @floatFromInt(k)) + 1.0) * 2.0 * std.math.pi / @as(f32, @floatFromInt(ISLAND_SIDES)) + 0.1;
            const reach = apothem / @cos(0.1);
            const at = struct {
                fn f(i: Island, ang: f32, d: f32) f32 {
                    return groundAt(i.x + d * @cos(ang), i.y + d * @sin(ang)).z;
                }
            }.f;
            try std.testing.expectApproxEqAbs(@as(f32, 0), at(isl, a, isl.r * reach + 0.5), 1e-4);
            try std.testing.expectApproxEqAbs(isl.beach * 0.5, at(isl, a, (isl.r + isl.rock) * 0.5 * reach), 0.01);
            try std.testing.expectApproxEqAbs(isl.beach, at(isl, a, isl.rock * reach - 0.01), 0.01);
        }
    }
}

test "a coasting craft rides up a beach and slides back down unhurt" {
    _ = startForTest();
    const isl = ISLANDS[0];
    hoverForTest(6);
    cr_x = isl.x - isl.r - CRAFT_HALF_L - 5;
    cr_y = isl.y;
    throttle = 0;
    var top: f32 = 0;
    var came_back = false;
    for (0..1500) |_| {
        stepGame();
        top = maxf(top, craftGround());
        if (top > 0 and cr_vx < -0.2) came_back = true;
    }
    try std.testing.expect(top > 0.5);
    try std.testing.expect(came_back);
    try std.testing.expectEqual(@as(f32, 100), hull);
    try std.testing.expectEqual(Mode.walking, mode);
}

test "under power the craft climbs a beach and lifts the cabin with it" {
    _ = startForTest();
    const isl = ISLANDS[1];
    hoverForTest(2);
    cr_x = isl.x - isl.r - CRAFT_HALF_L;
    cr_y = isl.y;
    throttle = 1;
    const deck_was = deckZ();
    var deck_top = deck_was;
    for (0..600) |_| {
        stepGame();
        deck_top = maxf(deck_top, deckZ());
    }
    try std.testing.expect(deck_top > deck_was + 0.4 * isl.beach);
    // Only the rock stops it.
    try std.testing.expect(cr_x > isl.x - isl.r);
}

test "full throttle tops out at 20 m/s" {
    _ = startForTest();
    hoverForTest(0);
    throttle = 1;
    // Held in open water, so only thrust and drag act.
    for (0..4000) |_| {
        stepCraft();
        cr_x = 1300;
        cr_y = 1250;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 20), crSpeed(), 0.05);
}

test "whitecaps break the open bay but not the shallows" {
    bakeRipples();
    chop = BENCH_CHOP;
    var caps: f32 = 0;
    var n: f32 = 0;
    var y: f32 = 0;
    while (y < 400) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 400) : (x += 0.5) {
            caps += whitecap(1000 + x, 1000 + y, 40, 1, 0);
            try std.testing.expectEqual(@as(f32, 0), whitecap(1000 + x, 1000 + y, 40, 0.2, 0));
            n += 1;
        }
    }
    // A few percent of the open water is foam.
    try std.testing.expect(caps / n > 0.01 and caps / n < 0.1);
}

test "spray flies off a fast craft and none off a still one" {
    _ = startForTest();
    mode = .dashboard;
    chase_cam = true;
    var counts: [2]u32 = undefined;
    for ([_]f32{ 0, 19 }, 0..) |speed, i| {
        hoverForTest(speed);
        mode = .dashboard;
        chase_h = cr_h;
        setEye();
        drawScene();
        const before = output_buf;
        drawSpray();
        var changed: u32 = 0;
        for (before, output_buf) |a, b| changed += @intFromBool(a != b);
        counts[i] = changed;
    }
    try std.testing.expectEqual(@as(u32, 0), counts[0]);
    try std.testing.expect(counts[1] > 2000);
}

test "the wake stays where it was laid when the craft turns away" {
    _ = startForTest();
    hoverForTest(15);
    throttle = 1;
    craft_wake.len = 0;
    for (0..250) |_| {
        stepCraft();
        recordWakes();
    }
    try std.testing.expect(craft_wake.len > 10);
    // Looking north from high over the water south of the run.
    const view = struct {
        fn foam() [SCREEN_W * SCREEN_H]u8 {
            eye_x = 1330;
            eye_y = 1100;
            eye_z = 60;
            eye_angle = std.math.pi / 2.0;
            horizon = BASE_HORIZON;
            focal = FOCAL;
            eye_inside = false;
            drawScene();
            drawWake();
            return wake_foam;
        }
    };
    const laid = view.foam();
    // Swing the craft north at once and run on.
    cr_h = std.math.pi / 2.0;
    cr_vx = 0;
    cr_vy = 15;
    for (0..120) |_| {
        stepCraft();
        recordWakes();
    }
    const later = view.foam();
    var before: u32 = 0;
    var kept: u32 = 0;
    for (laid, later) |a, b| {
        if (a < 20) continue;
        before += 1;
        kept += @intFromBool(b > 0);
    }
    try std.testing.expect(before > 2000);
    try std.testing.expect(kept * 10 >= before * 8);
}

test "the upload needs a steady satellite link" {
    _ = startForTest();
    code_keys = CODE_KEYS;
    hoverForTest(8);
    mode = .dashboard;
    throttle = 0.8;
    keys_down = KEY_TURN_R;
    for (0..100) |_| stepGame();
    startUpload();
    try std.testing.expect(uploading);
    for (0..300) |_| stepGame();
    try std.testing.expect(@abs(cr_r) > SAT_MAX_YAW);
    try std.testing.expectEqual(@as(i32, 0), upload_ms);
    keys_down = 0;
    throttle = 0;
    for (0..3000) |_| stepGame();
    try std.testing.expect(uploaded());
}

test "the autopilot is too careful to win the race, but never scratches the hull" {
    _ = startForTest();
    mode = .walking;
    setAutopilot(true);
    var steps: usize = 0;
    while (steps < DAY_MS / STEP and mode == .walking) : (steps += 1) stepGame();
    try std.testing.expectEqual(Outcome.scooped, outcome);
    try std.testing.expectEqual(@as(f32, 100), hull);
    // Well past the bridge and over the flats, but not yet home.
    try std.testing.expect(cr_y > BRIDGE_Y + 500 and !inBerth());
}

test "from the bridge the autopilot brings the office into the berth first" {
    _ = startForTest();
    mode = .walking;
    // On the route just through the navigation span, heading north, and
    // already well clear of the pier, so the speedboat leaves at once.
    hoverForTest(0);
    cr_x = ROUTE[5][0];
    cr_y = ROUTE[5][1];
    cr_h = std.math.pi / 2.0;
    setAutopilot(true);
    var reached = false;
    var steps: usize = 0;
    while (steps < DAY_MS / STEP and mode == .walking) : (steps += 1) {
        stepGame();
        if (docked and @abs(cr_r) < 0.05) {
            reached = true;
            break;
        }
    }
    try std.testing.expect(reached);
    try std.testing.expectEqual(@as(f32, 100), hull);
    try std.testing.expectEqual(Rival.racing, rival);
    // With the demo uploaded, docking wins.
    upload_ms = UPLOAD_MS;
    stepGame();
    try std.testing.expectEqual(Mode.gameover, mode);
    try std.testing.expectEqual(Outcome.funded, outcome);
    try std.testing.expect(score > 5000);
}

// Flies the office along a route as a driver at the helm would, with the
// speedboat racing it, until one of them has won or the clock runs out.
fn raceForTest(route: []const [2]f32, cruise: f32, brake: f32) void {
    mode = .walking;
    setAutopilot(true);
    autopilot = false;
    upload_ms = UPLOAD_MS;
    var steps: usize = 0;
    while (steps < DAY_MS / STEP and mode == .walking) : (steps += 1) {
        time_ms += STEP;
        lift = approach(lift, 1, LIFT_RATE * DT);
        flyRoute(route, cruise, brake);
        stepCraft();
        stepRival();
        collideCraft();
        updateObjectives();
    }
}

test "flown hard across the shallows the office beats the speedboat" {
    _ = startForTest();
    raceForTest(&ROUTE, 17, 0.6);
    try std.testing.expectEqual(Outcome.funded, outcome);
    try std.testing.expectEqual(Rival.racing, rival);
    try std.testing.expect(hull > 90);
    // With some way still to go.
    try std.testing.expect(rivalToGo() > 100);
}

test "the speedboat leaves when the office does, or at ten o'clock" {
    _ = startForTest();
    mode = .walking;
    for (0..100) |_| stepGame();
    try std.testing.expectEqual(Rival.moored, rival);
    cr_y = START[1] + 70;
    stepGame();
    try std.testing.expectEqual(Rival.racing, rival);
    _ = startForTest();
    mode = .walking;
    time_ms = RIVAL_LEAVES_MS - 2 * STEP;
    stepGame();
    try std.testing.expectEqual(Rival.moored, rival);
    stepGame();
    stepGame();
    try std.testing.expectEqual(Rival.racing, rival);
}

test "the speedboat keeps to the deep channel, clear of everything, and docks" {
    _ = startForTest();
    mode = .walking;
    rival = .racing;
    // In the full afternoon breeze, which sets it furthest off its line.
    time_ms = DAY_MS * 6 / 8;
    var steps: usize = 0;
    var deepest_miss: f32 = 0;
    while (rival != .docked and steps < DAY_MS / STEP) : (steps += 1) {
        time_ms += STEP;
        stepRival();
        const sh = shallowsAt(rv_x, rv_y);
        deepest_miss = maxf(deepest_miss, sh.k);
        try std.testing.expectEqual(@as(f32, 0), sh.surf);
        try std.testing.expectEqual(@as(f32, 0), groundAt(rv_x, rv_y).z);
        for (obstacles[0..obstacle_count]) |o| try std.testing.expect(obstacleContact(o, rv_x, rv_y, RIVAL_HALF_L + 1) == null);
    }
    try std.testing.expectEqual(Rival.docked, rival);
    try std.testing.expect(deepest_miss < 0.05);
    try std.testing.expect(@abs(rv_x - RIVAL_BERTH[0]) < 3 and @abs(rv_y - RIVAL_BERTH[1]) < 3);
    // Docking ends the day for the office.
    stepGame();
    try std.testing.expectEqual(Outcome.scooped, outcome);
}

test "a sandbank carries the craft over it, but a reef stops it" {
    _ = startForTest();
    // North across the big bank on the flats.
    const bank = BANKS[2].p;
    hoverForTest(12);
    cr_x = bank.x;
    cr_y = bank.y - 140;
    cr_h = std.math.pi / 2.0;
    cr_vx = 0;
    cr_vy = 12;
    throttle = 0.6;
    var top: f32 = 0;
    for (0..2000) |_| {
        stepGame();
        top = maxf(top, craftGround());
        if (cr_y > bank.y + 140) break;
    }
    try std.testing.expect(cr_y > bank.y + 140);
    try std.testing.expect(top > 0.5 * BANKS[2].h);
    try std.testing.expectEqual(@as(f32, 100), hull);
    // Square on at the long reef, which dents the hull and holds it off.
    const r = REEFS[2];
    hoverForTest(9);
    const out: [2]f32 = .{ -@sin(r.a), @cos(r.a) };
    cr_x = r.x + out[0] * 80;
    cr_y = r.y + out[1] * 80;
    cr_h = std.math.atan2(-out[1], -out[0]);
    cr_vx = -out[0] * 9;
    cr_vy = -out[1] * 9;
    throttle = 0.5;
    for (0..600) |_| stepGame();
    try std.testing.expect(hull < 100);
    for (HULL_CIRCLES) |lx| {
        const p = toWorld(lx, 0);
        for (obstacles[0..obstacle_count]) |o| {
            if (obstacleContact(o, p[0], p[1], HULL_R)) |ct| try std.testing.expect(ct.depth < 0.5);
        }
    }
    try std.testing.expect(outside(&REEF_OUTLINES[2], cr_x, cr_y) > 0);
}

test "five o'clock ends the day" {
    var t = startForTest();
    time_ms = DAY_MS - 32;
    t += 64;
    _ = runUpdate(t);
    try std.testing.expectEqual(Mode.gameover, mode);
    try std.testing.expectEqual(Outcome.late, outcome);
    _ = renderImpl(0);
    press(t + 1, ' ');
    try std.testing.expectEqual(Mode.cubicle, mode);
}

test "seated, the mouse turns the head; walking, it turns the body" {
    _ = startForTest();
    begin_update_at(2);
    _ = uniform_set_pointer_total_movement_x(100);
    _ = finish_update();
    try std.testing.expectApproxEqAbs(-100 * MOUSE_TURN, head_yaw, 1e-5);
    press(3, XK_TAB);
    const a0 = pangle;
    begin_update_at(4);
    _ = uniform_set_pointer_total_movement_x(200);
    _ = finish_update();
    try std.testing.expectApproxEqAbs(wrapAngle(a0 - 100 * MOUSE_TURN), pangle, 1e-5);
}

test "taking the controls disengages the autopilot" {
    var t = startForTest();
    mode = .dashboard;
    t += 1;
    press(t, 't');
    try std.testing.expect(autopilot);
    t += 1;
    press(t, 'a');
    try std.testing.expect(!autopilot);
}

fn sweepRadarForTest(sweeps: usize) void {
    for (0..sweeps * 157) |_| {
        time_ms += STEP;
        stepRadar();
    }
}

test "the radar paints the bridge and the islands, and land shadows what lies behind it" {
    _ = startForTest();
    // Due north, 200 m short of the bridge, and an island's rock beyond it.
    const isl = ISLANDS[1];
    cr_x = isl.x;
    cr_y = BRIDGE_Y - 200;
    sweepRadarForTest(1);
    const step = RADAR_RANGES[radar_range] / @as(f32, RADAR_BINS);
    const north = RADAR_BEARINGS / 4;
    const row = radar[north * RADAR_BINS ..][0..RADAR_BINS];
    try std.testing.expect(row[@intFromFloat(200 / step)] > 180);
    const near_rock: usize = @intFromFloat((isl.y - isl.rock - cr_y) / step + 1);
    const far_rock: usize = @intFromFloat((isl.y + isl.rock - cr_y) / step - 1);
    try std.testing.expect(row[near_rock] > 200);
    // Behind the rock the beam is spent.
    for (row[far_rock + 2 ..]) |k| try std.testing.expect(k <= 31);
    // A reef breaks up into speckle, weaker than solid land.
    const r = REEFS[2];
    cr_x = r.x;
    cr_y = r.y - 300;
    @memset(&radar, 0);
    sweepRadarForTest(1);
    var reef_top: u8 = 0;
    for (0..8) |b| reef_top = @max(reef_top, radar[north * RADAR_BINS + @as(usize, @intFromFloat(300 / step)) - 4 + b]);
    try std.testing.expect(reef_top > 70 and reef_top < 230);
}

test "the ARPA acquires the speedboat, tracks its velocity, and loses it out of range" {
    _ = startForTest();
    rival = .racing;
    rv_leg = 5;
    rv_x = RIVAL_ROUTE[4][0];
    rv_y = RIVAL_ROUTE[4][1];
    const a = RIVAL_ROUTE[5];
    rv_h = std.math.atan2(a[1] - rv_y, a[0] - rv_x);
    rv_speed = RIVAL_CRUISE;
    // Still, south of the leg the speedboat runs along.
    cr_x = rv_x + 500;
    cr_y = rv_y - 50;
    for (0..4 * 157) |_| {
        time_ms += STEP;
        stepRival();
        stepRadar();
    }
    try std.testing.expect(arpaTracking());
    const v = rivalVelocity();
    try std.testing.expectApproxEqAbs(v[0], arpa_vx, 1.0);
    try std.testing.expectApproxEqAbs(v[1], arpa_vy, 1.0);
    const now = arpaNow();
    try std.testing.expect(@abs(now[0] - rv_x) < 15 and @abs(now[1] - rv_y) < 15);
    const cpa = arpaCpa().?;
    try std.testing.expect(cpa[0] < 250 and cpa[1] > 0);
    cr_x += 5000;
    sweepRadarForTest(2);
    try std.testing.expect(!arpaTracking());
}

test "the chart warns of a reef ahead on the course, and the readouts give heading and position" {
    _ = startForTest();
    const r = REEFS[2];
    const out: [2]f32 = .{ -@sin(r.a), @cos(r.a) };
    cr_x = r.x + out[0] * 200;
    cr_y = r.y + out[1] * 200;
    cr_vx = -out[0] * 10;
    cr_vy = -out[1] * 10;
    const d = chartAlarm().?;
    try std.testing.expect(d > 120 and d < 200);
    cr_vx = -cr_vx;
    cr_vy = -cr_vy;
    try std.testing.expect(chartAlarm() == null);
    try std.testing.expectEqual(@as(u32, 0), compassDeg(std.math.pi / 2.0));
    try std.testing.expectEqual(@as(u32, 90), compassDeg(0));
    try std.testing.expectEqual(@as(u32, 270), compassDeg(std.math.pi));
    var buf: [14]u8 = undefined;
    try std.testing.expectEqualStrings("37 47.500N", formatDegMin(&buf, ORIGIN_LAT_MIN, 'N'));
    try std.testing.expectEqualStrings("122 24.000W", formatDegMin(&buf, ORIGIN_LON_MIN + 1.0, 'W'));
    cr_h = std.math.pi / 2.0;
    updateReadouts();
    try std.testing.expectEqualStrings("HDG 000", readouts[0]);
}

test "R steps the radar's range at the helm" {
    var t = startForTest();
    mode = .dashboard;
    t += 1;
    press(t, 'r');
    try std.testing.expectEqual(@as(u8, 3), radar_range);
    t += 1;
    press(t, 'r');
    try std.testing.expectEqual(@as(u8, 0), radar_range);
}


// The craft's top speed heading at a world angle, with the wind as it is at
// two o'clock, held in open water.
fn topSpeedForTest(heading: f32) f32 {
    hoverForTest(0);
    still_air = false;
    time_ms = DAY_MS * 6 / 8;
    cr_h = heading;
    throttle = 1;
    for (0..4000) |_| {
        stepCraft();
        cr_x = 1300;
        cr_y = 1250;
        cr_h = heading;
        cr_r = 0;
    }
    const v = crSpeed();
    return v;
}

test "the sea breeze fills in through the day, from the west-north-west" {
    _ = startForTest();
    try std.testing.expectApproxEqAbs(WIND_MORNING, windMean(), 1e-4);
    time_ms = DAY_MS * 6 / 8;
    try std.testing.expectApproxEqAbs(WIND_AFTERNOON, windMean(), 1e-4);
    // Over a few minutes of gusts it blows from 285 degrees, give or take.
    var lo: f32 = 100;
    var hi: f32 = 0;
    for (0..300) |_| {
        time_ms += 1000;
        const w = wind();
        const sp = @sqrt(w[0] * w[0] + w[1] * w[1]);
        lo = minf(lo, sp);
        hi = maxf(hi, sp);
        const from = compassDeg(std.math.atan2(-w[1], -w[0]));
        try std.testing.expect(from > 270 and from < 300);
    }
    try std.testing.expect(lo < WIND_AFTERNOON * 0.9 and hi > WIND_AFTERNOON * 1.1);
    try std.testing.expect(hi < WIND_AFTERNOON * (1.0 + WIND_GUST) + 0.01);
    // The sea is calm in the morning and breaks into whitecaps by afternoon.
    time_ms = 0;
    try std.testing.expect(seaState() <= 0.15);
    time_ms = DAY_MS * 6 / 8;
    try std.testing.expect(seaState() > 0.6);
}

test "the wind turns a hovering craft head to wind and blows it astern, but not with the skirt down" {
    _ = startForTest();
    hoverForTest(0);
    still_air = false;
    time_ms = DAY_MS * 6 / 8;
    throttle = 0;
    // Beam on, bow north.
    cr_h = std.math.pi / 2.0;
    for (0..60 * 63) |_| stepCraft();
    const w = wind();
    const wsp = @sqrt(w[0] * w[0] + w[1] * w[1]);
    // Head to wind, give or take its swings.
    try std.testing.expect(@abs(wrapAngle(cr_h - std.math.atan2(-w[1], -w[0]))) < 0.35);
    const dx = cr_x - 1300;
    const dy = cr_y - 1250;
    const d = @sqrt(dx * dx + dy * dy);
    try std.testing.expect(d > 100);
    try std.testing.expect((dx * w[0] + dy * w[1]) / (d * wsp) > 0.9);
    // Settled on its skirt, the craft stays where it is.
    hoverForTest(0);
    still_air = false;
    lift_on = false;
    lift = 0;
    for (0..60 * 63) |_| stepCraft();
    try std.testing.expectApproxEqAbs(@as(f32, 1300), cr_x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1250), cr_y, 1e-3);
}

test "into the wind the office is slowed far more than the speedboat" {
    _ = startForTest();
    time_ms = DAY_MS * 6 / 8;
    const w = wind();
    const wsp = @sqrt(w[0] * w[0] + w[1] * w[1]);
    const toward = std.math.atan2(w[1], w[0]);
    const into = topSpeedForTest(wrapAngle(toward + std.math.pi));
    const down = topSpeedForTest(toward);
    try std.testing.expect(into < 14 and down > 24);
    try std.testing.expectApproxEqAbs(RIVAL_CRUISE, rivalCruise(0), 1e-4);
    const boat_into = rivalCruise(-wsp);
    const boat_down = rivalCruise(wsp);
    try std.testing.expect(boat_into < RIVAL_CRUISE - 1 and boat_into > RIVAL_CRUISE - 3);
    try std.testing.expect(boat_down > RIVAL_CRUISE + 0.5 and boat_down < RIVAL_CRUISE + 2);
    // Across the wind the speedboat makes a little leeway downwind.
    rival = .racing;
    rv_h = wrapAngle(toward + std.math.pi / 2.0);
    rv_speed = RIVAL_CRUISE;
    const v = rivalVelocity();
    const lee = (v[0] * w[0] + v[1] * w[1]) / wsp;
    try std.testing.expect(lee > 0.2 and lee < 0.8);
}

test "the autopilot docks head to wind and holds the berth as the breeze fills in" {
    // At noon, as it fills, and at two and four, in the full breeze.
    for ([_]i32{ 3, 5, 7 }) |eighth| {
        _ = startForTest();
        mode = .walking;
        hoverForTest(0);
        still_air = false;
        time_ms = @divTrunc(DAY_MS * eighth, 8);
        cr_x = ROUTE[ROUTE.len - 2][0];
        cr_y = ROUTE[ROUTE.len - 2][1];
        cr_h = std.math.pi / 2.0;
        setAutopilot(true);
        var held: usize = 0;
        for (0..120 * 63) |k| {
            time_ms += STEP;
            lift = approach(lift, 1, LIFT_RATE * DT);
            runAutopilot();
            stepCraft();
            collideCraft();
            if (k >= 60 * 63 and inBerth()) held += 1;
        }
        try std.testing.expectEqual(@as(f32, 100), hull);
        // In the berth for most of the second minute, and head to wind.
        try std.testing.expect(held > 50 * 63);
        try std.testing.expect(inBerth());
        const w = wind();
        try std.testing.expect(@abs(wrapAngle(cr_h - std.math.atan2(-w[1], -w[0]))) < 0.7);
    }
}
