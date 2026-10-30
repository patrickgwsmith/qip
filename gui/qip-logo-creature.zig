// QIP logo creature: the twelve bars of the QIP header logo spring apart on
// hover and rearrange into a small character or a three-letter term (.SVG, .PNG,
// TUI|, a neon underlined GUI), painted with a random OKLCH palette. Leaving puts the bars back into
// the logo; the next hover builds the next shape. Press (or Space/Enter) pins
// it in place.
//
// Output is image/svg+xml in an 800 × 600 viewBox, so <qip-play> maps pointer
// coordinates without extra attributes.
const std = @import("std");

const W = 800;
const H = 600;
const UNIT: f64 = 30; // one logo grid cell in SVG pixels
// Logo centre. 395 rather than 400 puts the logo's left edge at x = 170, so at
// the site header's 1/10 scale it lands on a whole pixel (17 px).
const LOGO_X: f64 = 395;
const LOGO_Y: f64 = 300;
const FEET_X: f64 = 400; // creature origin: centre of its feet on the ground
const FEET_Y: f64 = 560;
const OUTPUT_CAP = 16384;
const STEP_S: f64 = 0.004;
const FRAME_MS: i64 = 16;
const IDLE_FRAME_MS: i64 = 33;
const STAGGER_MS: f64 = 22;
const INTRO_SHOW_MS: i64 = 900;
const INTRO_HIDE_MS: i64 = 3200;

var output_buf: [OUTPUT_CAP]u8 = undefined;
var input_mime = "image/svg+xml".*;
var output_mime = "image/svg+xml".*;

// The logo's bars, in the order they appear in recipes/text/markdown/header.html.
const Size = struct { w: f64, h: f64 };
const sizes = [12]Size{
    .{ .w = 5, .h = 1 }, // 0  Q top
    .{ .w = 1, .h = 3 }, // 1  Q left
    .{ .w = 1, .h = 3 }, // 2  Q right
    .{ .w = 5, .h = 1 }, // 3  Q bottom
    .{ .w = 1, .h = 2 }, // 4  Q tail
    .{ .w = 3, .h = 1 }, // 5  I top
    .{ .w = 1, .h = 2 }, // 6  I stem
    .{ .w = 3, .h = 1 }, // 7  I bottom
    .{ .w = 1, .h = 6 }, // 8  P stem
    .{ .w = 5, .h = 1 }, // 9  P top
    .{ .w = 1, .h = 3 }, // 10 P right
    .{ .w = 5, .h = 1 }, // 11 P middle
};

// Logo bar centres relative to the logo centre, in grid cells (16 × 6 grid, y 5–11).
const logo = [12][2]f64{
    .{ -5, -2.5 }, .{ -7, -0.5 }, .{ -3, -0.5 }, .{ -5, 0.5 }, .{ -5, 2 },
    .{ 0, -2.5 },  .{ 0, -1 },    .{ 0, 0.5 },
    .{ 3, 0 },     .{ 5, -2.5 },  .{ 7, -0.5 },  .{ 5, 0.5 },
};

// ink is the site text color, used for the text cursor after a word.
const Role = enum(u2) { main, secondary, accent, ink };

// An idle wiggle rotates a bar about a pivot given in the bar's own coordinates.
const Wiggle = struct { deg: f32, hz: f32, phase: f32 = 0, px: f32 = 0, py: f32 = 0 };

// f32 and an optional wiggle keep the 108 poses small: they are most of the
// module's data.
const Pose = struct {
    x: f32,
    y: f32,
    a: f32 = 0,
    role: Role = .main,
    bob: bool = true,
    bob_phase: f32 = 0,
    wig: ?*const Wiggle = null,
    // Assembly start in ms; negative means a random stagger.
    delay_ms: f32 = -1,
};

const Creature = struct {
    poses: [12]Pose,
    order: [12]u8,
    eyes: []const [2]f64 = &.{},
    eye_r: f64 = 0,
    // Eyes that sit in a gap between bars show the page behind them, so they
    // draw in the light ink color rather than dark.
    light_eyes: bool = false,
    lean: f64 = 4,
    shadow: bool = true,
    caret: ?u8 = null, // the bar that blinks as a text cursor
    dot: ?u8 = null, // the bar that shrinks to the period of a file extension
    underline: ?u8 = null, // the 6-cell half of the rule under GUI
    // Neon sign: each tube cycles through hues and the whole word glows.
    neon: bool = false,
    // CRT terminal: the whole word, cursor included, in one phosphor color with a bloom.
    phosphor: bool = false,
};

// Creature coordinates are grid cells from the centre of the feet; y grows down.

const RayOpts = struct {
    role: Role = .main,
    bob: bool = true,
    // Swings about the ray's start, like a limb from its joint.
    swing: ?Wiggle = null,
};

/// Lays bar i from a start point along a direction in degrees (0 is right,
/// -90 is up), so limbs can be placed by their joint rather than their centre.
fn ray(comptime i: usize, comptime from: [2]f64, comptime deg: f64, comptime o: RayOpts) Pose {
    const r = deg * std.math.pi / 180;
    const half = barLength(i) / 2;
    const upright = sizes[i].h > sizes[i].w;
    const wig: ?*const Wiggle = if (o.swing) |w| blk: {
        var s = w;
        if (upright) s.py = @floatCast(-half) else s.px = @floatCast(-half);
        const final = s;
        break :blk &final;
    } else null;
    return .{
        .x = @floatCast(from[0] + half * @cos(r)),
        .y = @floatCast(from[1] + half * @sin(r)),
        .a = @floatCast(if (upright) deg - 90 else deg),
        .role = o.role,
        .bob = o.bob,
        .wig = wig,
    };
}

// Front on: a domed shell on four legs, eyes up on stalks and two claws
// held out wide, their pincers snapping.
const crab = Creature{
    .poses = .{
        ray(0, .{ -2.8, -3.3 }, -152, .{}), // left arm
        ray(1, .{ -1.9, -2.6 }, 125, .{ .role = .secondary, .bob = false }), // left outer leg
        ray(2, .{ -0.9, -2.8 }, 108, .{ .role = .secondary, .bob = false }), // left inner leg
        ray(3, .{ 2.8, -3.3 }, -28, .{}), // right arm
        ray(4, .{ -0.8, -4.9 }, -100, .{ .role = .accent }), // left eye stalk
        ray(5, .{ 0.9, -2.8 }, 72, .{ .role = .secondary, .bob = false }), // right inner leg
        ray(6, .{ 0.8, -4.9 }, -80, .{ .role = .accent }), // right eye stalk
        .{ .x = 0, .y = -4.5 }, // shell dome
        .{ .x = 0, .y = -3.5, .a = 90 }, // shell
        ray(9, .{ -7.0, -5.5 }, -68, .{ .role = .secondary, .swing = .{ .deg = 10, .hz = 1.4 } }), // left pincer, snapping
        ray(10, .{ 1.9, -2.6 }, 55, .{ .role = .secondary, .bob = false }), // right outer leg
        ray(11, .{ 7.0, -5.5 }, -112, .{ .role = .secondary, .swing = .{ .deg = -10, .hz = 1.4, .phase = 2 } }), // right pincer, snapping
    },
    .order = .{ 1, 2, 5, 10, 4, 6, 0, 9, 3, 11, 7, 8 },
    .eyes = &.{ .{ -1.15, -7.25 }, .{ 1.15, -7.25 } },
    .eye_r = 0.55,
    .light_eyes = true,
};

// Side on, facing right: the 6-cell bar is the long neck, with a mane
// behind it, two horns and a swishing tail.
const giraffe = Creature{
    .poses = .{
        .{ .x = 0, .y = -3.5 }, // belly
        .{ .x = -2, .y = -1.5, .bob = false }, // hind leg
        .{ .x = 2, .y = -1.5, .bob = false }, // foreleg
        .{ .x = 0.2, .y = -4.5, .a = -5 }, // back
        ray(4, .{ 4.3, -11.3 }, -100, .{ .role = .accent }), // horn
        ray(5, .{ -0.8, -2.9 }, 90, .{ .role = .secondary, .bob = false }), // far hind leg
        ray(6, .{ 5.0, -11.3 }, -80, .{ .role = .accent }), // horn
        .{ .x = 5.1, .y = -10.8, .a = 12 }, // head
        ray(8, .{ 2.0, -4.6 }, -70, .{}), // neck
        ray(9, .{ -2.4, -4.6 }, 108, .{ .role = .secondary, .swing = .{ .deg = 10, .hz = 0.8 } }), // tail
        .{ .x = 0.8, .y = -1.5, .role = .secondary, .bob = false }, // far foreleg
        ray(11, .{ 1.2, -4.9 }, -71, .{ .role = .accent }), // mane
    },
    .order = .{ 5, 10, 9, 11, 1, 2, 0, 3, 8, 4, 6, 7 },
    .eyes = &.{.{ 4.65, -10.85 }},
    .eye_r = 0.4,
};

// Side on, facing right: the Q's ring is the shell with a curl inside, on a
// long foot, with one long and one short eye stalk.
const snail = Creature{
    .poses = .{
        .{ .x = -1.0, .y = -5.5 }, // shell top
        .{ .x = -3.0, .y = -3.5 }, // shell back
        .{ .x = 1.0, .y = -3.5 }, // shell front
        .{ .x = -1.0, .y = -1.5 }, // shell bottom
        .{ .x = -0.5, .y = -3.5, .a = 90, .role = .accent }, // curl
        ray(5, .{ 2.4, -0.9 }, -84, .{ .role = .secondary }), // neck
        ray(6, .{ 2.7, -3.6 }, -105, .{ .role = .secondary, .swing = .{ .deg = 7, .hz = 0.6, .phase = 1 } }), // short eye stalk
        ray(7, .{ 3.4, -3.6 }, -65, .{ .role = .secondary, .swing = .{ .deg = 8, .hz = 0.5 } }), // long eye stalk
        .{ .x = 0.5, .y = -0.5, .a = 90, .role = .secondary, .bob = false }, // foot
        .{ .x = 0.5, .y = -0.5, .bob = false, .role = .secondary }, // foot, under the shell
        ray(10, .{ 3.3, -0.9 }, -84, .{ .role = .secondary }), // neck
        .{ .x = -3.0, .y = -0.5, .role = .secondary, .bob = false }, // tail of the foot
    },
    .order = .{ 9, 11, 8, 5, 10, 6, 7, 4, 0, 1, 2, 3 },
    .eyes = &.{ .{ 2.1, -5.85 }, .{ 4.8, -6.65 } },
    .eye_r = 0.45,
    .light_eyes = true,
};

// Side on, facing right, standing on one leg with the other folded up and an
// S-curved neck.
const flamingo = Creature{
    .poses = .{
        .{ .x = 0.3, .y = -7.3, .a = -6 }, // body
        ray(1, .{ 0.4, -6.2 }, 58, .{ .role = .accent }), // thigh, folded
        ray(2, .{ 1.99, -3.66 }, 150, .{ .role = .accent }), // shin, folded
        .{ .x = 0.0, .y = -6.5, .a = -6 }, // belly
        ray(4, .{ 1.7, -14.2 }, 0, .{}), // head
        ray(5, .{ 2.9, -10.6 }, -112, .{}), // upper neck
        ray(6, .{ 3.5, -14.2 }, 55, .{ .role = .accent }), // beak
        ray(7, .{ -2.0, -7.9 }, 198, .{ .role = .secondary, .swing = .{ .deg = 6, .hz = 0.9 } }), // tail
        ray(8, .{ 0, 0 }, -90, .{ .role = .accent, .bob = false }), // standing leg
        .{ .x = 0.0, .y = -8.1, .a = -8 }, // back
        ray(10, .{ 2.2, -7.9 }, -72, .{}), // lower neck
        .{ .x = -0.4, .y = -7.6, .a = -12, .role = .secondary, .wig = &.{ .deg = 4, .hz = 0.7, .px = 2.5 } }, // wing
    },
    .order = .{ 8, 2, 1, 7, 3, 0, 9, 10, 5, 4, 6, 11 },
    .eyes = &.{.{ 2.4, -14.2 }},
    .eye_r = 0.36,
};

const bird = Creature{
    .poses = .{
        .{ .x = 0.6, .y = -6.5 }, // body row
        .{ .x = -0.5, .y = -1.5, .role = .accent, .bob = false }, // leg
        .{ .x = 1, .y = -1.5, .role = .accent, .bob = false }, // leg
        .{ .x = 0.4, .y = -3.5, .role = .secondary }, // body row
        .{ .x = 5.1, .y = -8, .a = 100, .role = .accent }, // beak
        .{ .x = 2.8, .y = -8.5 }, // head
        .{ .x = 2, .y = -9.9, .a = -25, .role = .accent, .wig = &.{ .deg = 9, .hz = 1.7, .py = 1 } }, // crest
        .{ .x = 2.6, .y = -7.5 }, // head
        .{ .x = -5.22, .y = -6.27, .a = 115, .role = .secondary, .wig = &.{ .deg = 6, .hz = 1.1, .py = -3 } }, // tail
        .{ .x = 0, .y = -5.5 }, // body row
        .{ .x = -0.3, .y = -5.2, .a = 70, .role = .accent, .wig = &.{ .deg = 10, .hz = 2.2, .py = -1.5 } }, // wing
        .{ .x = 0, .y = -4.5, .role = .secondary }, // body row
    },
    .order = .{ 8, 1, 2, 3, 11, 9, 0, 10, 7, 5, 4, 6 },
    .eyes = &.{.{ 3.4, -8.1 }},
    .eye_r = 0.45,
};

/// Five arms from a pentagon of the 3-cell bars, standing on the lower two.
/// The 6-cell bar is the top arm; the 2-cell bars make a smile.
fn starfish() Creature {
    @setEvalBranchQuota(20000);
    const cy: f64 = -6.9;
    const arm_bars = [5]u8{ 8, 0, 9, 11, 3 };
    const ring_bars = [5]u8{ 5, 1, 10, 2, 7 };
    const arm_wiggles = [5]Wiggle{
        .{ .deg = 5, .hz = 0.6 },
        .{ .deg = 16, .hz = 1.4 }, // waving
        .{ .deg = 0, .hz = 0 },
        .{ .deg = 0, .hz = 0 },
        .{ .deg = -6, .hz = 0.7, .phase = 1 },
    };
    var c = Creature{ .poses = undefined, .order = undefined, .light_eyes = true };
    for (0..5) |k| {
        const deg = -90.0 + 72.0 * @as(f64, @floatFromInt(k));
        const r = deg * std.math.pi / 180;
        const i = arm_bars[k];
        const len = barLength(i);
        const d = 2.2 + len / 2;
        const upright = sizes[i].h > sizes[i].w;
        const leg = k == 2 or k == 3;
        // Swing from the arm's root, where it meets the middle.
        const wig = blk: {
            var w = arm_wiggles[k];
            if (upright) w.py = @floatCast(-len / 2) else w.px = @floatCast(-len / 2);
            break :blk w;
        };
        c.poses[i] = .{
            .x = @floatCast(d * @cos(r)),
            .y = @floatCast(cy + d * @sin(r)),
            .a = @floatCast(if (upright) deg - 90 else deg),
            .bob = !leg,
            .wig = if (wig.deg == 0) null else &wig,
        };
        // The side between this arm and the next, square to their bisector.
        const mid = (deg + 36) * std.math.pi / 180;
        const j = ring_bars[k];
        const side_deg = deg + 36 + 90;
        c.poses[j] = .{
            .x = @floatCast(2.06 * @cos(mid)),
            .y = @floatCast(cy + 2.06 * @sin(mid)),
            .a = @floatCast(if (sizes[j].h > sizes[j].w) side_deg - 90 else side_deg),
            .role = .secondary,
        };
    }
    c.poses[4] = .{ .x = -0.5, .y = @floatCast(cy + 0.75), .a = 30 - 90, .role = .accent };
    c.poses[6] = .{ .x = 0.5, .y = @floatCast(cy + 0.75), .a = -30 - 90, .role = .accent };
    c.order = .{ 8, 0, 9, 11, 3, 5, 1, 10, 2, 7, 4, 6 };
    c.eyes = &.{ .{ -0.65, cy - 0.65 }, .{ 0.65, cy - 0.65 } };
    c.eye_r = 0.65;
    return c;
}

const starfish_creature = starfish();

// ---------------------------------------------------------------- words
//
// Three-letter terms in a 3 × 5 cell bar font. File formats get a leading
// period (.SVG); TUI gets a blinking caret (TUI|) on a phosphor screen and GUI a neon underline. Each
// way the 6-cell bar is the mark: no letter stroke is long enough to hide it,
// so as a period it is the one bar that shrinks, to a single cell. As the
// underline it lies end to end with GUI's spare 3-cell bar, one rule exactly
// as wide as the word. Each stroke names a bar
// length and its centreline end points, in cells from the letter's top left.
// word() gives every stroke a free logo bar of that length; bars left over
// hide under the shortest stroke that covers them.

const Seg = struct { len: f64, ax: f64, ay: f64, bx: f64, by: f64 };
const Glyph = struct { width: f64, segs: []const Seg };

fn hbar(len: f64, x: f64, row: f64) Seg {
    return .{ .len = len, .ax = x, .ay = row + 0.5, .bx = x + len, .by = row + 0.5 };
}

fn vbar(len: f64, col: f64, y: f64) Seg {
    return .{ .len = len, .ax = col + 0.5, .ay = y, .bx = col + 0.5, .by = y + len };
}

fn slant(len: f64, ax: f64, ay: f64, bx: f64, by: f64) Seg {
    return .{ .len = len, .ax = ax, .ay = ay, .bx = bx, .by = by };
}

const glyph_c = Glyph{ .width = 3, .segs = &.{ vbar(5, 0, 0), hbar(3, 0, 0), hbar(3, 0, 4) } };
const glyph_g = Glyph{ .width = 3, .segs = &.{ vbar(5, 0, 0), hbar(3, 0, 0), hbar(3, 0, 4), vbar(3, 2, 2) } };
const glyph_i = Glyph{ .width = 1, .segs = &.{vbar(5, 0, 0)} };
const glyph_n = Glyph{ .width = 3, .segs = &.{ vbar(5, 0, 0), vbar(5, 2, 0), slant(3, 0.5, 0.5, 2.5, 4.5) } };
const glyph_p = Glyph{ .width = 3, .segs = &.{ vbar(5, 0, 0), hbar(2, 1, 0), hbar(2, 1, 2), vbar(3, 2, 0) } };
const glyph_s = Glyph{ .width = 3, .segs = &.{ hbar(3, 0, 0), vbar(2, 0, 0), hbar(3, 0, 2), vbar(2, 2, 3), hbar(3, 0, 4) } };
// An angular S for words that need the 5-cell bars elsewhere: short top and
// bottom bars joined by one long diagonal spine.
const glyph_s_angular = Glyph{ .width = 3, .segs = &.{ hbar(2, 1, 0), slant(5, 0.5, 0.5, 2.5, 4.5), hbar(2, 0, 4) } };
const glyph_t = Glyph{ .width = 3, .segs = &.{ hbar(3, 0, 0), vbar(5, 1, 0) } };
const glyph_u = Glyph{ .width = 3, .segs = &.{ vbar(5, 0, 0), vbar(5, 2, 0), hbar(3, 0, 4) } };
const glyph_v = Glyph{ .width = 3, .segs = &.{ slant(5, 0.5, 0, 1.5, 5), slant(5, 2.5, 0, 1.5, 5) } };
const glyph_z = Glyph{ .width = 3, .segs = &.{ hbar(3, 0, 0), hbar(3, 0, 4), slant(5, 2.5, 0.5, 0.5, 4.5) } };

const Placed = struct { seg: Seg, letter: usize };

fn barLength(i: usize) f64 {
    return @max(sizes[i].w, sizes[i].h);
}

fn place(i: usize, p: Placed, k: usize, width: f64, height: f64, letters: usize) Pose {
    const s = p.seg;
    var a = std.math.atan2(s.by - s.ay, s.bx - s.ax) * 180 / std.math.pi;
    if (sizes[i].h > sizes[i].w) a -= 90;
    while (a > 90) a -= 180;
    while (a <= -90) a += 180;
    return .{
        // Centred on the logo, so the word replaces it in place.
        .x = @floatCast((s.ax + s.bx) / 2 - width / 2 + (LOGO_X - FEET_X) / UNIT),
        .y = @floatCast((s.ay + s.by) / 2 - height / 2 + (LOGO_Y - FEET_Y) / UNIT),
        .a = @floatCast(a),
        .role = switch (p.letter) {
            1 => .secondary,
            2 => .accent,
            3 => .ink,
            else => .main,
        },
        .bob = p.letter < letters,
        .bob_phase = @as(f32, @floatFromInt(p.letter)) * 1.2,
        // Strokes land left to right, as if typed.
        .delay_ms = @as(f32, @floatFromInt(k)) * 32,
    };
}

const Mark = enum { caret, dot, underline };

fn word(comptime mark: Mark, comptime glyphs: []const Glyph) Creature {
    comptime {
        @setEvalBranchQuota(50000);
        var segs: [12]Placed = undefined;
        var n: usize = 0;
        var x: f64 = 0;
        // The period lands first, as if typed; it sits on the baseline.
        if (mark == .dot) {
            segs[n] = .{ .seg = .{ .len = 6, .ax = 0.5, .ay = 4, .bx = 0.5, .by = 5 }, .letter = glyphs.len };
            n += 1;
            x = 2;
        }
        for (glyphs, 0..) |g, li| {
            for (g.segs) |s| {
                segs[n] = .{ .seg = .{ .len = s.len, .ax = s.ax + x, .ay = s.ay, .bx = s.bx + x, .by = s.by }, .letter = li };
                n += 1;
            }
            x += g.width + 1;
        }
        const mark_seg = if (mark == .dot) 0 else n;
        if (mark == .caret) {
            segs[n] = .{ .seg = vbar(6, x, -0.5), .letter = glyphs.len };
            n += 1;
        }
        // An underline a cell's gap below the baseline: the 6-cell bar then
        // a 3-cell bar, end to end.
        if (mark == .underline) {
            if (x - 1 != 9) @compileError("the underline spans a 9-cell word");
            for ([_]Seg{ hbar(6, 0, 6), hbar(3, 6, 6) }) |s| {
                segs[n] = .{ .seg = s, .letter = glyphs.len };
                n += 1;
            }
        }
        const width = switch (mark) {
            .caret => x + 1,
            .dot, .underline => x - 1,
        };
        const height: f64 = if (mark == .underline) 7 else 5;

        var poses: [12]Pose = undefined;
        var used = [_]bool{false} ** 12;
        var seg_bar: [12]u8 = undefined;
        for (segs[0..n], 0..) |p, k| {
            const i = for (0..12) |b| {
                if (!used[b] and barLength(b) == p.seg.len) break b;
            } else @compileError("no free logo bar for a stroke");
            used[i] = true;
            seg_bar[k] = i;
            poses[i] = place(i, p, k, width, height, glyphs.len);
        }
        // Spares draw first so the stroke they hide under covers them.
        var order: [12]u8 = undefined;
        var spares: usize = 0;
        for (0..12) |i| if (!used[i]) {
            var host: ?usize = null;
            for (segs[0..n], 0..) |p, k| {
                if (mark == .dot and k == mark_seg) continue; // a one-cell period hides nothing
                if (p.seg.len >= barLength(i) and (host == null or p.seg.len < segs[host.?].seg.len)) host = k;
            }
            poses[i] = place(i, segs[host.?], host.?, width, height, glyphs.len);
            order[spares] = i;
            spares += 1;
        };
        for (0..n) |k| order[spares + k] = seg_bar[k];
        var c = Creature{ .poses = poses, .order = order, .lean = 0, .shadow = false };
        switch (mark) {
            .caret => {
                c.caret = seg_bar[mark_seg];
                c.phosphor = true;
            },
            .dot => c.dot = seg_bar[mark_seg],
            .underline => {
                c.underline = seg_bar[mark_seg];
                c.neon = true;
            },
        }
        return c;
    }
}

const word_svg = word(.dot, &.{ glyph_s_angular, glyph_v, glyph_g });
const word_csv = word(.dot, &.{ glyph_c, glyph_s, glyph_v });
const word_png = word(.dot, &.{ glyph_p, glyph_n, glyph_g });
const word_zig = word(.dot, &.{ glyph_z, glyph_i, glyph_g });
const word_tui = word(.caret, &.{ glyph_t, glyph_u, glyph_i });
const word_gui = word(.underline, &.{ glyph_g, glyph_u, glyph_i });

// Characters and terms take turns; each list cycles at its own length.
const characters = [_]*const Creature{ &crab, &bird, &giraffe, &starfish_creature, &snail, &flamingo };
const terms = [_]*const Creature{ &word_svg, &word_csv, &word_png, &word_zig, &word_tui, &word_gui };
const creatures = characters ++ terms;

const Bar = struct {
    x: f64 = 0,
    y: f64 = 0,
    a: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    va: f64 = 0,
    tx: f64 = 0,
    ty: f64 = 0,
    ta: f64 = 0,
    delay_s: f64 = 0,
};

const Lab = struct { l: f64, a: f64, b: f64 };

var bars: [12]Bar = undefined;
var palette: [3]Lab = undefined;
const rest_color = oklch(0.73, 0.18, 50); // the site's link orange
const eye_color = oklch(0.2, 0.015, 52.85);
const ink_color = oklch(0.9155, 0.0391, 68.55);
const blush_color = oklch(0.72, 0.14, 10);

var shape_n: usize = 0;
var current: *const Creature = &crab;
var assembled = false;
var pinned = false;
var hover_suppressed = false;
var hovering = false;
var pointer_down = false;
var blend: f64 = 0;
var blend_v: f64 = 0;
var look_x: f64 = 0;
var look_y: f64 = 0;
var look_tx: f64 = 0;
var look_ty: f64 = 0;
var idle_s: f64 = 0;
var blink_at_s: f64 = 2;
var blink_start_s: f64 = -1;
// Happy ^ ^ eyes show between these times; joy eases towards that.
var happy_from_s: f64 = 0;
var happy_until_s: f64 = 0;
var joy: f64 = 0;
var rng: u32 = 0x9E3779B9;
var intro: enum { pending, showing, done } = .pending;
var intro_origin_ms: i64 = 0;

var initialized = false;
var updating = false;
var begun_at: i64 = 0;
var committed_at: i64 = 0;
var assembled_this_update = false;

export fn input_ptr() i32 { return 0; }
export fn input_utf8_cap() i32 { return 0; }
export fn output_utf8_cap() i32 { return OUTPUT_CAP; }
export fn input_content_type_ptr() i32 { return @intCast(@intFromPtr(&input_mime)); }
export fn input_content_type_size() i32 { return input_mime.len; }
export fn output_content_type_ptr() i32 { return @intCast(@intFromPtr(&output_mime)); }
export fn output_content_type_size() i32 { return output_mime.len; }

/// Seeds the palette and spin choices. Hosts pass a random value for a
/// different look on each load; the same seed replays the same sequence.
export fn uniform_set_seed(value: u32) u32 {
    rng = if (value == 0) 0x9E3779B9 else value;
    return rng;
}

/// 0 skips the intro, for hosts like the site header where it would replay
/// on every page load. Any other value keeps it.
export fn uniform_set_intro(value: u32) u32 {
    if (value == 0 and intro == .pending) intro = .done;
    return @intFromBool(intro != .done);
}

fn random() f64 {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return @as(f64, @floatFromInt(rng)) / 4294967296.0;
}

fn init() void {
    for (&bars, 0..) |*b, i| {
        b.* = .{};
        b.x = LOGO_X + logo[i][0] * UNIT;
        b.y = LOGO_Y + logo[i][1] * UNIT;
        b.tx = b.x;
        b.ty = b.y;
    }
    palette = .{ rest_color, rest_color, rest_color };
    initialized = true;
}

// ---------------------------------------------------------------- colour

/// @sin and @cos reduce huge angles with compiler_rt's rem_pio2_large, which brings in
/// about 6 KB of code and tables. Our angles grow only with seconds of idle
/// time, so folding into a quarter turn and a Taylor series is plenty.
fn sin(x: f64) f64 {
    const k = @round(x / (std.math.pi / 2.0));
    // pi/2 split in two so the fold stays exact for large k.
    const r = (x - k * 1.5707963267341256) - k * 6.077100506506192e-11;
    const r2 = r * r;
    const s = r * (1 - r2 / 6 * (1 - r2 / 20 * (1 - r2 / 42 * (1 - r2 / 72 * (1 - r2 / 110 * (1 - r2 / 156 * (1 - r2 / 210)))))));
    const c = 1 - r2 / 2 * (1 - r2 / 12 * (1 - r2 / 30 * (1 - r2 / 56 * (1 - r2 / 90 * (1 - r2 / 132 * (1 - r2 / 182 * (1 - r2 / 240)))))));
    const q: u2 = @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(@mod(k, 4))))));
    return switch (q) {
        0 => s,
        1 => c,
        2 => -s,
        3 => -c,
    };
}

fn cos(x: f64) f64 {
    return sin(x + std.math.pi / 2.0);
}

fn oklch(l: f64, c: f64, h_deg: f64) Lab {
    const h = h_deg * std.math.pi / 180.0;
    return .{ .l = l, .a = c * cos(h), .b = c * sin(h) };
}

fn linearRgb(c: Lab) [3]f64 {
    const l_ = c.l + 0.3963377774 * c.a + 0.2158037573 * c.b;
    const m_ = c.l - 0.1055613458 * c.a - 0.0638541728 * c.b;
    const s_ = c.l - 0.0894841775 * c.a - 1.2914855480 * c.b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

fn inGamut(c: Lab) bool {
    for (linearRgb(c)) |v| if (v < -0.0005 or v > 1.0005) return false;
    return true;
}

/// Lowers chroma until the colour fits in sRGB, keeping lightness and hue.
fn fitted(l: f64, c: f64, h: f64) Lab {
    var chroma = c;
    var lab = oklch(l, chroma, h);
    while (!inGamut(lab) and chroma > 0.005) {
        chroma *= 0.92;
        lab = oklch(l, chroma, h);
    }
    return lab;
}

fn encode(v: f64) u8 {
    const x = std.math.clamp(v, 0, 1);
    const e = if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(e * 255));
}

fn mix(a: Lab, b: Lab, t: f64) Lab {
    return .{ .l = a.l + (b.l - a.l) * t, .a = a.a + (b.a - a.a) * t, .b = a.b + (b.b - a.b) * t };
}

fn newPalette() void {
    const h = random() * 360;
    // Analogous, split-complementary or triadic harmonies around a random hue.
    const scheme = random();
    const second: f64 = if (scheme < 0.4) 32 else if (scheme < 0.75) 150 else 120;
    const accent: f64 = if (scheme < 0.4) 180 else if (scheme < 0.75) 210 else 240;
    palette = .{
        fitted(0.74 + random() * 0.06, 0.13 + random() * 0.04, h),
        fitted(0.6 + random() * 0.06, 0.12 + random() * 0.03, h + second),
        fitted(0.84, 0.14 + random() * 0.03, h + accent),
    };
}

// ---------------------------------------------------------------- motion

fn creature() *const Creature {
    return current;
}

/// Gives each bar a new target, a staggered start and sometimes an extra
/// whole turn so the bars tumble rather than slide.
fn retarget(to_creature: bool) void {
    var rank: [12]u8 = undefined;
    for (&rank, 0..) |*r, i| r.* = @intCast(i);
    var i: usize = rank.len;
    while (i > 1) : (i -= 1) {
        const j: usize = @intFromFloat(random() * @as(f64, @floatFromInt(i)));
        std.mem.swap(u8, &rank[i - 1], &rank[j]);
    }
    for (&bars, 0..) |*b, k| {
        var base: f64 = 0;
        b.delay_s = @as(f64, @floatFromInt(rank[k])) * STAGGER_MS / 1000;
        if (to_creature) {
            const p = creature().poses[k];
            b.tx = FEET_X + p.x * UNIT;
            b.ty = FEET_Y + p.y * UNIT;
            base = p.a;
            if (p.delay_ms >= 0) b.delay_s = p.delay_ms / 1000;
        } else {
            b.tx = LOGO_X + logo[k][0] * UNIT;
            b.ty = LOGO_Y + logo[k][1] * UNIT;
        }
        const turns = @round((b.a - base) / 360);
        const roll = random();
        const spin: f64 = if (roll < 0.22) -1 else if (roll < 0.44) 1 else 0;
        b.ta = base + (turns + spin) * 360;
    }
}

fn beHappy(from_s: f64, for_s: f64) void {
    happy_from_s = from_s;
    happy_until_s = from_s + for_s;
}

fn assemble() void {
    const turn = shape_n / 2;
    current = if (shape_n % 2 == 0) characters[turn % characters.len] else terms[turn % terms.len];
    shape_n = (shape_n + 1) % (2 * characters.len * terms.len);
    newPalette();
    assembled = true;
    assembled_this_update = true;
    blink_at_s = idle_s + 2.4 + random() * 1.5;
    // A greeting smile once the bars have landed.
    beHappy(idle_s + 0.75, 1.1);
    retarget(true);
}

fn disassemble() void {
    assembled = false;
    retarget(false);
}

fn stepBar(b: *Bar, dt: f64) void {
    if (b.delay_s > 0) {
        b.delay_s -= dt;
        return;
    }
    const k = 210.0;
    const c = 17.0;
    b.vx += (k * (b.tx - b.x) - c * b.vx) * dt;
    b.vy += (k * (b.ty - b.y) - c * b.vy) * dt;
    b.va += (170.0 * (b.ta - b.a) - 15.0 * b.va) * dt;
    b.x += b.vx * dt;
    b.y += b.vy * dt;
    b.a += b.va * dt;
}

fn barSettled(b: *const Bar) bool {
    return b.delay_s <= 0 and @abs(b.tx - b.x) < 0.02 and @abs(b.ty - b.y) < 0.02 and @abs(b.ta - b.a) < 0.02 and
        @abs(b.vx) < 0.05 and @abs(b.vy) < 0.05 and @abs(b.va) < 0.05;
}

fn barsSettled() bool {
    for (&bars) |*b| if (!barSettled(b)) return false;
    return true;
}

fn blendSettled() bool {
    const target: f64 = if (assembled) 1 else 0;
    return @abs(blend - target) < 0.001 and @abs(blend_v) < 0.005;
}

fn lookSettled() bool {
    return @abs(look_x - look_tx) < 0.002 and @abs(look_y - look_ty) < 0.002;
}

fn joyTarget() f64 {
    return if (assembled and idle_s >= happy_from_s and idle_s < happy_until_s) 1 else 0;
}

fn joySettled() bool {
    return @abs(joy - joyTarget()) < 0.002;
}

fn advance(seconds: f64) void {
    var left = @min(seconds, 0.25);
    const target: f64 = if (assembled) 1 else 0;
    while (left > 0) {
        const dt = @min(left, STEP_S);
        left -= dt;
        for (&bars) |*b| stepBar(b, dt);
        blend_v += (60.0 * (target - blend) - 15.5 * blend_v) * dt;
        blend += blend_v * dt;
        const follow = 1 - @exp(-dt * 9);
        look_x += (look_tx - look_x) * follow;
        look_y += (look_ty - look_y) * follow;
        joy += (joyTarget() - joy) * (1 - @exp(-dt * 16));
        if (blend > 0.001) idle_s += dt;
    }
    if (joySettled()) joy = joyTarget();
    for (&bars) |*b| if (barSettled(b)) {
        b.* = .{ .x = b.tx, .y = b.ty, .a = b.ta, .tx = b.tx, .ty = b.ty, .ta = b.ta };
    };
    if (blendSettled()) {
        blend = target;
        blend_v = 0;
    }
    if (lookSettled()) {
        look_x = look_tx;
        look_y = look_ty;
    }
    if (assembled and blend > 0.5 and idle_s >= blink_at_s) {
        if (joy > 0.01) {
            blink_at_s = happy_until_s + 0.8;
        } else if (random() < 0.2) {
            // Now and then a happy squint instead of a blink.
            beHappy(idle_s, 1.0 + random() * 0.6);
            blink_at_s = happy_until_s + 1.5 + random() * 2;
        } else {
            blink_start_s = idle_s;
            // Mostly single blinks, sometimes a quick double.
            blink_at_s = idle_s + if (random() < 0.2) 0.32 else 2.4 + random() * 2.6;
        }
    }
}

// ---------------------------------------------------------------- lifecycle

export fn begin_update_at(now_ms: i64) void {
    if (!initialized or updating or now_ms <= committed_at or now_ms <= 0) @trap();
    updating = true;
    begun_at = now_ms;
    assembled_this_update = false;
    if (intro_origin_ms == 0) intro_origin_ms = now_ms;
}

export fn finish_update() i64 {
    if (!updating) @trap();
    if (committed_at > 0) advance(@as(f64, @floatFromInt(begun_at - committed_at)) / 1000);
    // A short intro so the page shows what hovering does.
    if (intro == .pending and begun_at - intro_origin_ms >= INTRO_SHOW_MS) {
        intro = .showing;
        assemble();
    } else if (intro == .showing and begun_at - intro_origin_ms >= INTRO_HIDE_MS) {
        intro = .done;
        if (!hovering and !pinned) disassemble();
    }
    updating = false;
    committed_at = begun_at;
    const moving = !barsSettled() or !blendSettled() or !lookSettled() or !joySettled();
    if (moving) return begun_at + FRAME_MS;
    if (blend > 0.001) return begun_at + IDLE_FRAME_MS;
    return switch (intro) {
        .pending => intro_origin_ms + INTRO_SHOW_MS,
        .showing => intro_origin_ms + INTRO_HIDE_MS,
        .done => begun_at,
    };
}

export fn pointer_event(mask: i32, x: i32, y: i32) i32 {
    if (!updating) @trap();
    const inside = x >= 0 and y >= 0 and x < W and y < H;
    var changed = false;
    if (!inside) {
        hovering = false;
        pointer_down = false;
        hover_suppressed = false;
        look_tx = 0;
        look_ty = 0;
        if (assembled and !pinned and intro != .showing) {
            disassemble();
            changed = true;
        }
        return @intFromBool(changed);
    }
    const was_down = hovering and pointer_down;
    hovering = true;
    if (intro != .done) intro = .done;
    look_tx = std.math.clamp((@as(f64, @floatFromInt(x)) - FEET_X) / 400, -1, 1);
    look_ty = std.math.clamp((@as(f64, @floatFromInt(y)) - 330) / 300, -1, 1);
    if (!assembled and !hover_suppressed) {
        assemble();
        changed = true;
    }
    const down = mask & 1 != 0;
    if (down and !was_down) {
        togglePin();
        changed = true;
    }
    pointer_down = down;
    return @intFromBool(changed);
}

fn togglePin() void {
    if (pinned) {
        pinned = false;
        hover_suppressed = hovering;
        disassemble();
    } else {
        pinned = true;
        if (!assembled) {
            assemble();
        } else if (!assembled_this_update) {
            newPalette();
            beHappy(idle_s, 1.3);
        }
    }
}

export fn key_event(key: i32, flags: i32) i32 {
    if (!updating) @trap();
    if (flags & 1 == 0) return 0;
    intro = .done;
    switch (key) {
        ' ', 0xff0d => togglePin(),
        'c', 'C' => {
            if (!assembled) return 0;
            newPalette();
            beHappy(idle_s, 0.9);
        },
        'n', 'N' => {
            pinned = true;
            assemble();
        },
        else => return 0,
    }
    return 1;
}

// ---------------------------------------------------------------- SVG

const Writer = struct {
    n: usize = 0,
    fn bytes(w: *Writer, s: []const u8) !void {
        if (s.len > OUTPUT_CAP - w.n) return error.Full;
        @memcpy(output_buf[w.n..][0..s.len], s);
        w.n += s.len;
    }
    /// Writes `f` with each `{d:.N}` replaced by the next number, fixed to N
    /// places. std.fmt's float printing would bring in Ryu's tables and a copy
    /// of its formatter per format string, more than doubling the module.
    fn fmt(w: *Writer, comptime f: []const u8, args: anytype) !void {
        comptime var i = 0;
        comptime var arg = 0;
        inline while (comptime std.mem.indexOfScalarPos(u8, f, i, '{')) |open| {
            const close = comptime std.mem.indexOfScalarPos(u8, f, open, '}').?;
            const spec = f[open + 1 .. close];
            if (comptime !(spec.len == 4 and std.mem.startsWith(u8, spec, "d:.") and spec[3] >= '0' and spec[3] <= '3')) @compileError("unsupported format: {" ++ spec ++ "}");
            try w.bytes(f[i..open]);
            try w.num(args[arg], spec[3] - '0');
            arg += 1;
            i = close + 1;
        }
        try w.bytes(f[i..]);
    }
    /// `places` is a runtime value so there's one copy of this, not one per count.
    noinline fn num(w: *Writer, v: f64, places: u8) !void {
        const scales = [_]f64{ 1, 10, 100, 1000 };
        const scaled = @round(@abs(v) * scales[places]);
        // Coordinates stay well inside this; anything else is drawn at 0.
        const r: u64 = if (scaled < 1e15) @intFromFloat(scaled) else 0;
        var buf: [24]u8 = undefined;
        var at: usize = buf.len;
        var rest = r;
        var digits: usize = 0;
        while (digits <= places or rest != 0) : (digits += 1) {
            if (digits == places and places > 0) {
                at -= 1;
                buf[at] = '.';
            }
            at -= 1;
            buf[at] = '0' + @as(u8, @intCast(rest % 10));
            rest /= 10;
        }
        if (v < 0 and r != 0) {
            at -= 1;
            buf[at] = '-';
        }
        try w.bytes(buf[at..]);
    }
    fn color(w: *Writer, c: Lab) !void {
        const rgb = linearRgb(c);
        const hex = "0123456789ABCDEF";
        var buf: [7]u8 = undefined;
        buf[0] = '#';
        for (0..3) |k| {
            const b = encode(rgb[k]);
            buf[1 + k * 2] = hex[b >> 4];
            buf[2 + k * 2] = hex[b & 15];
        }
        try w.bytes(&buf);
    }
};

/// Gentle breathing for everything above the legs; letters of a word take
/// turns, so the breath runs along it as a wave.
fn bobOffset(phase: f64) f64 {
    return sin(idle_s * std.math.tau * 0.55 - phase) * 0.12 * UNIT * blend;
}

/// A terminal-style cursor: steady while the bars move, blinking once settled.
fn caretHidden() bool {
    return blend > 0.98 and @mod(idle_s, 1.06) >= 0.53;
}

fn blinkScale() f64 {
    if (blink_start_s < 0) return 1;
    const t = (idle_s - blink_start_s) / 0.14;
    if (t >= 1) return 1;
    return @max(0.08, @abs(t * 2 - 1));
}

/// Neon tubes: each letter and the underline take their own hue, and every
/// NEON_STEP_S the sign switches to the next set of hues. The switch ripples
/// tube by tube along the word, and each tube stutters as it relights.
const NEON_STEP_S: f64 = 4.0;

fn neonColor(slot: usize) Lab {
    const t = idle_s - @as(f64, @floatFromInt(slot)) * 0.07;
    const step = @floor(t / NEON_STEP_S);
    const since = t - step * NEON_STEP_S;
    const base = std.math.atan2(palette[0].b, palette[0].a) * 180 / std.math.pi;
    const lit = fitted(0.8, 0.2, base + @as(f64, @floatFromInt(slot)) * 90 + step * 137.5);
    const stutter = since < 0.05 or (since >= 0.1 and since < 0.13);
    return if (step >= 1 and stutter) mix(eye_color, lit, 0.35) else lit;
}

/// Monochrome CRT phosphors of the late 1970s and 1980s, plus the orange gas
/// plasma of early portables. The palette's hue picks one, so `C` swaps tubes.
const phosphors = [_]Lab{
    fitted(0.87, 0.29, 142), // P1 green, as on the Apple II and IBM 3270
    fitted(0.92, 0.2, 128), // P31 green, as on the VT100
    fitted(0.82, 0.17, 75), // P3 amber, as on the IBM 5151 and Wyse terminals
    fitted(0.72, 0.2, 42), // orange gas plasma, as on the GRiD Compass and IBM P70
    fitted(0.95, 0.025, 240), // P4 white, as on the Mac 128K
};

fn phosphorColor() Lab {
    const hue = std.math.atan2(palette[0].b, palette[0].a) / std.math.tau + 0.5;
    const n: f64 = @floatFromInt(phosphors.len);
    return phosphors[@min(phosphors.len - 1, @as(usize, @intFromFloat(hue * n)))];
}

fn writeBar(w: *Writer, i: usize) !void {
    const b = bars[i];
    const pose = creature().poses[i];
    var x = b.x;
    var y = b.y;
    var a = b.a;
    if (pose.bob) y += bobOffset(pose.bob_phase);
    if (pose.wig != null and blend > 0) {
        const wig = pose.wig.?;
        // Rotate about the pivot so tails wag from their base.
        const swing = sin(idle_s * std.math.tau * wig.hz + wig.phase) * wig.deg * blend;
        const r = a * std.math.pi / 180;
        const px = (wig.px * cos(r) - wig.py * sin(r)) * UNIT;
        const py = (wig.px * sin(r) + wig.py * cos(r)) * UNIT;
        const s = swing * std.math.pi / 180;
        x += px - (px * cos(s) - py * sin(s));
        y += py - (px * sin(s) + py * cos(s));
        a += swing;
    }
    var s = sizes[i];
    const shown = std.math.clamp(blend, 0, 1);
    const is_dot = if (creature().dot) |d| d == i else false;
    if (is_dot) {
        // The period draws in from the full bar as the word forms.
        s.w += (1 - s.w) * shown;
        s.h += (1 - s.h) * shown;
    }
    const color = if (creature().neon)
        neonColor(@intFromEnum(pose.role))
    else if (creature().phosphor)
        phosphorColor()
    else if (pose.role == .ink) ink_color else palette[@intFromEnum(pose.role)];
    const fill = mix(rest_color, color, shown);
    try w.fmt("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.0}\" rx=\"{d:.1}\" fill=\"", .{
        -s.w * UNIT / 2, -s.h * UNIT / 2, s.w * UNIT, s.h * UNIT, shown * 5,
    });
    try w.color(fill);
    try w.fmt("\" transform=\"translate({d:.2} {d:.2}) rotate({d:.2})\"", .{ x, y, @mod(a, 360) });
    const is_caret = if (creature().caret) |c| c == i else false;
    if (is_caret and assembled and caretHidden()) try w.bytes(" opacity=\"0\"");
    try w.bytes("/>");
}

/// Solid dark pills that look where the pointer is, squash shut to blink and
/// turn into ^ ^ arcs with a blush while happy.
fn writeEye(w: *Writer, c: *const Creature, e: [2]f64, alpha: f64) !void {
    const ew = c.eye_r * 0.95 * UNIT;
    const color = if (c.light_eyes) ink_color else eye_color;
    const eh = c.eye_r * 1.55 * UNIT;
    const x = FEET_X + e[0] * UNIT + look_x * 0.2 * UNIT;
    const y = FEET_Y + e[1] * UNIT + bobOffset(0) + look_y * 0.12 * UNIT;
    try w.fmt("<g class=\"eye\" opacity=\"{d:.3}\" transform=\"translate({d:.2} {d:.2})\">", .{ alpha, x, y });
    if (joy > 0.01) {
        try w.fmt("<ellipse cx=\"0\" cy=\"{d:.1}\" rx=\"{d:.1}\" ry=\"{d:.1}\" opacity=\"{d:.3}\" fill=\"", .{ eh * 0.62, ew * 0.7, ew * 0.34, joy * 0.6 });
        try w.color(blush_color);
        try w.bytes("\"/>");
    }
    if (joy < 0.5) {
        // Squash towards a slit on the way to blinking or smiling.
        const open = @min(blinkScale(), 1 - joy * 2);
        const h = @max(eh * open, ew * 0.28);
        try w.fmt("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"{d:.1}\" fill=\"", .{ -ew / 2, -h / 2, ew, h, @min(ew, h) / 2 });
        try w.color(color);
        try w.bytes("\"/>");
        if (open > 0.6 and !c.light_eyes) {
            try w.fmt("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"#fff\" opacity=\"0.9\"/>", .{ ew * 0.14, -h * 0.24, ew * 0.2 });
        }
    } else {
        const lift = (joy - 0.5) * 2 * ew * 1.5;
        try w.fmt("<path d=\"M{d:.1} {d:.1}Q0 {d:.1} {d:.1} {d:.1}\" fill=\"none\" stroke-width=\"{d:.1}\" stroke-linecap=\"round\" stroke=\"", .{
            -ew * 0.75, ew * 0.3, ew * 0.3 - lift, ew * 0.75, ew * 0.3, ew * 0.42,
        });
        try w.color(color);
        try w.bytes("\"/>");
    }
    try w.bytes("</g>");
}

fn writeSvg() !usize {
    var w = Writer{};
    const shown = std.math.clamp(blend, 0, 1);
    try w.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\" viewBox=\"0 0 800 600\">");
    const c = creature();
    if (shown > 0.001 and c.shadow) {
        try w.fmt("<ellipse cx=\"{d:.0}\" cy=\"{d:.0}\" rx=\"{d:.1}\" ry=\"9\" fill=\"#000\" opacity=\"{d:.3}\"/>", .{
            FEET_X, FEET_Y + 4, 150 - 20 * sin(idle_s * std.math.tau * 0.55) * shown, 0.3 * shown,
        });
    }
    // Neon words glow: a blurred, brightened copy of the bars under the bars.
    const glow = c.neon and shown > 0.001;
    if (glow) {
        try w.fmt("<defs><filter id=\"neon\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"800\" height=\"600\">" ++
            "<feGaussianBlur stdDeviation=\"9\"/><feComponentTransfer><feFuncA type=\"linear\" slope=\"{d:.3}\"/></feComponentTransfer>" ++
            "<feMerge><feMergeNode/><feMergeNode in=\"SourceGraphic\"/></feMerge></filter></defs>", .{1.6 * shown});
    }
    // Phosphor words bloom like text on a CRT: a tight halo hugging each
    // stroke and a wide, faint one lighting the glass around the word.
    const bloom = c.phosphor and shown > 0.001;
    if (bloom) {
        try w.fmt("<defs><filter id=\"phosphor\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"800\" height=\"600\">" ++
            "<feGaussianBlur in=\"SourceGraphic\" stdDeviation=\"4\" result=\"near\"/>" ++
            "<feGaussianBlur in=\"SourceGraphic\" stdDeviation=\"18\"/><feComponentTransfer result=\"far\"><feFuncA type=\"linear\" slope=\"{d:.3}\"/></feComponentTransfer>" ++
            "<feMerge><feMergeNode in=\"far\"/><feMergeNode in=\"near\"/><feMergeNode in=\"SourceGraphic\"/></feMerge></filter></defs>", .{0.9 * shown});
    }
    try w.fmt("<g transform=\"rotate({d:.2} {d:.0} {d:.0})\"", .{ look_x * c.lean * shown, FEET_X, FEET_Y });
    try w.bytes(if (glow) " filter=\"url(#neon)\">" else if (bloom) " filter=\"url(#phosphor)\">" else ">");
    const eye_alpha = std.math.clamp((shown - 0.55) / 0.35, 0, 1);
    // The resting logo draws in header order so its SVG is the same every time.
    const logo_order = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const order = if (!assembled and shown == 0) logo_order else c.order;
    for (order) |i| try writeBar(&w, i);
    if (eye_alpha > 0) for (c.eyes) |e| try writeEye(&w, c, e, eye_alpha);
    try w.bytes("</g></svg>");
    return w.n;
}

export fn render(input_size: u32) u64 {
    if (updating or input_size != 0) @trap();
    if (!initialized) init();
    const n = writeSvg() catch @trap();
    return (@as(u64, @intCast(@intFromPtr(&output_buf))) << 32) | @as(u64, @intCast(n));
}

// ---------------------------------------------------------------- tests

test "every creature uses each logo bar once and the rest pose is the logo" {
    for (creatures) |c| {
        var seen = [_]bool{false} ** 12;
        for (c.order) |i| {
            try std.testing.expect(!seen[i]);
            seen[i] = true;
        }
    }
    init();
    try std.testing.expectEqual(LOGO_X - 5 * UNIT, bars[0].x);
}

test "words centre on the logo and their caret, period or underline is the 6-cell bar" {
    for (creatures) |c| {
        const mark = c.caret orelse c.dot orelse c.underline orelse continue;
        try std.testing.expect(@intFromBool(c.caret != null) + @intFromBool(c.dot != null) + @intFromBool(c.underline != null) == 1);
        try std.testing.expectEqual(c.underline != null, c.neon);
        try std.testing.expectEqual(c.caret != null, c.phosphor);
        try std.testing.expectEqual(@as(f64, 6), barLength(mark));
        var lo: f64 = 1e9;
        var hi: f64 = -1e9;
        for (c.poses, 0..) |p, i| {
            // The period is drawn one cell square; the rest at their own size, as rotated.
            const s = if (mark == i and c.dot != null) Size{ .w = 1, .h = 1 } else sizes[i];
            const r = p.a * std.math.pi / 180;
            const half = @abs(s.w / 2 * @cos(r)) + @abs(s.h / 2 * @sin(r));
            lo = @min(lo, FEET_X + p.x * UNIT - half * UNIT);
            hi = @max(hi, FEET_X + p.x * UNIT + half * UNIT);
        }
        // Diagonal corners land within a pixel of their letter's cell edge.
        try std.testing.expectApproxEqAbs(LOGO_X, (lo + hi) / 2, 1);
    }
}

test "palettes stay inside sRGB" {
    rng = 1234;
    for (0..200) |_| {
        newPalette();
        for (palette) |c| try std.testing.expect(inGamut(c));
    }
    for (phosphors) |c| try std.testing.expect(inGamut(c));
}

test "every phosphor is reachable from some palette hue" {
    var seen = [_]bool{false} ** phosphors.len;
    for (0..360) |deg| {
        palette[0] = oklch(0.75, 0.15, @floatFromInt(deg));
        const p = phosphorColor();
        for (phosphors, 0..) |q, k| {
            if (q.l == p.l and q.a == p.a and q.b == p.b) seen[k] = true;
        }
    }
    for (seen) |s| try std.testing.expect(s);
}

test "sin and cos match std across the angles the animation uses" {
    var x: f64 = -2000;
    while (x < 2000) : (x += 0.37) {
        try std.testing.expectApproxEqAbs(@sin(x), sin(x), 1e-12);
        try std.testing.expectApproxEqAbs(@cos(x), cos(x), 1e-12);
    }
}

test "numbers print with fixed places" {
    var w = Writer{};
    try w.fmt("{d:.0} {d:.1} {d:.2} {d:.3} {d:.1} {d:.1}", .{ 564.0, -0.04, 12.345, 0.0004, -3.25, 1e20 });
    try std.testing.expectEqualStrings("564 0.0 12.35 0.000 -3.3 0.0", output_buf[0..w.n]);
}
