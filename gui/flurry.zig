// Flurry, the Mac OS X screensaver, with its Classic preset: 5 streams in tie-dye
// colors. A port of Calum Robinson's code as distributed in xscreensaver
// (hacks/glx/flurry*.c), BSD licensed: qip.dev/licenses/flurry-LICENSE.txt.
//
// The component keeps Flurry's state between frames: 3,600 smoke particles
// integrated under the sparks' gravity, and the framebuffer itself. Each 20 ms
// step darkens the previous frame by alpha = 5 * dt (0.1), as Flurry's
// translucent black rectangle does, then adds this frame's smoke quads.
const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 640;
const RENDER_H: usize = 400;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

// Flurry is "designed to run at" about 50 fps; faster rates saturate the
// additive blending. The component steps at exactly that rate.
const STEP_MS: i64 = 20;
const DT: f32 = 0.02;
const MAX_STEPS_PER_UPDATE: i64 = 4;

const NUM_PARTICLES: usize = 3600;
const STREAMS: usize = 5;
const STREAM_EXPANSION: f32 = 10000.0;
const STREAM_SIZE: f32 = 25000.0;
const STREAM_SPEED: f32 = 450.0;
const GRAVITY: f32 = 1500000.0;
const STREAM_BIAS: f32 = 7.0;
const INCOHESION: f32 = 0.07;
const COLOR_INCOHERENCE: f32 = 0.15;
const FIELD_RANGE: f32 = 1000.0;
const SERAPH_DISTANCE: f32 = 2000.0;
const STAR_MYSTERY: f32 = 5.0;
const COLOR_SEED: f64 = 37.0;
const START_TIME: f64 = 100.0;
// Flurry divides 42.5 by dframe / fTime. fTime starts at a random 0..300 s,
// so that ratio is far below the frame rate for the first minutes and gravity
// is many times stronger. This uses the value it settles towards at 50 fps.
const FRAME_RATE_MODIFIER: f32 = 42.5 / 50.0;
const FADE_ALPHA: f32 = 5.0 * DT;
// brite = pow(dt, 0.75) * 10, the per-frame smoke brightness.
const BRIGHTNESS: f32 = 0.5318296;

var output_buf: [OUTPUT_BYTES]u8 = undefined;
// The persistent framebuffer, RGB in [0, 1], as GL's would be.
var frame: [RENDER_W * RENDER_H * 3]f32 = [_]f32{0} ** (RENDER_W * RENDER_H * 3);
var atlas: [256 * 256]u8 = undefined;

const Particle = struct {
    pos: [3]f32 = .{ 0, 0, 0 },
    old: [3]f32 = .{ 0, 0, 0 },
    delta: [3]f32 = .{ 0, 0, 0 },
    color: [4]f32 = .{ 0, 0, 0, 0 },
    born: f64 = 0,
    anim: u8 = 0,
    dead: bool = true,
};

var particles: [NUM_PARTICLES]Particle = undefined;
var next_particle: usize = 0;
var star_old: [3]f32 = .{ 0, 0, 0 };
var first_step: bool = true;
var last_particle_time: f64 = 0;
var sim_time: f64 = START_TIME;
var rng_state: u32 = 0x1234_5678;
var initialized: bool = false;

const Phase = enum { initializing, ready, updating };

var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
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
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    ensureInitialized();
    if (last_step_ms == 0) last_step_ms = begun_at_ms;
    var steps = @divFloor(begun_at_ms - last_step_ms, STEP_MS);
    // After a stall, run a few steps and drop the rest of the backlog.
    if (steps > MAX_STEPS_PER_UPDATE) {
        last_step_ms = begun_at_ms - MAX_STEPS_PER_UPDATE * STEP_MS;
        steps = MAX_STEPS_PER_UPDATE;
    }
    var i: i64 = 0;
    while (i < steps) : (i += 1) stepFrame();
    last_step_ms += steps * STEP_MS;
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return last_step_ms + STEP_MS;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    ensureInitialized();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    const pixels = output_buf[ktx.HEADER_SIZE..];
    for (0..RENDER_W * RENDER_H) |p| {
        for (0..3) |c| pixels[p * 4 + c] = @intFromFloat(@round(frame[p * 3 + c] * 255.0));
        pixels[p * 4 + 3] = 255;
    }
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

fn ensureInitialized() void {
    if (initialized) return;
    initialized = true;
    // Set at startup so the array stays out of the module's data segment.
    for (&particles) |*p| p.* = .{};
    makeAtlas();
    // InitSmoke: the star's "previous" position starts at random.
    for (&star_old) |*v| v.* = frand(200.0) - 100.0;
}

// ---- Randomness: Flurry's frand and RandBell ----

fn nextRandom() u32 {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

fn frand(max: f32) f32 {
    return @as(f32, @floatFromInt(nextRandom() >> 8)) / 16777216.0 * max;
}

// Always <= 0: -(three uniform halves) * scale.
fn randBell(scale: f32) f32 {
    return scale * -(frand(0.5) + frand(0.5) + frand(0.5));
}

// ---- The star and sparks: closed-form functions of time ----

fn orbit(t: f64, mystery: f64, cf_add: f64, range: f64) [3]f32 {
    const angle = t * (2.0 * std.math.pi * 12.0 / 16384.0);
    const cf = (@cos(7.0 * angle) + @cos(3.0 * angle) + @cos(13.0 * angle)) / 6.0 + cf_add;
    const p = 2.0 * std.math.pi * mystery / 1800.0;
    const x = range * cf * @cos(11.0 * (p + 3.0 * angle));
    const y = range * cf * @sin(12.0 * (p + 4.0 * angle));
    const z = range * @cos(23.0 * (p + 12.0 * angle));
    var r = angle * 0.501 + 5.01 * mystery / 1800.0;
    var c = @cos(r);
    var s = @sin(r);
    const x1 = x * c - y * s;
    const y1 = y * c + x * s;
    const x2 = x1 * c - z * s;
    const z2 = z * c + x1 * s;
    const y3 = y1 * c - z2 * s;
    const z3 = z2 * c + y1 * s + SERAPH_DISTANCE;
    r = angle * 2.501 + 85.01 * mystery / 1800.0;
    c = @cos(r);
    s = @sin(r);
    return .{ @floatCast(x2 * c - y3 * s), @floatCast(y3 * c + x2 * s), @floatCast(z3) };
}

fn sparkMystery(i: usize) f64 {
    return @floatFromInt(1800 * (i + 1) / 13);
}

fn starPosition(t: f64) [3]f32 {
    return orbit(t, STAR_MYSTERY, 0.75, 250.0);
}

fn sparkPosition(t: f64, i: usize) [3]f32 {
    return orbit(t, sparkMystery(i), 2.0, FIELD_RANGE);
}

// UpdateSparkColour in tie-dye mode, which cycles every 4.5 s.
fn sparkColor(t: f64, i: usize) [3]f32 {
    const angle = t * (2.0 * std.math.pi * 12.0 / 16384.0);
    const p = 2.0 * std.math.pi * sparkMystery(i) / 1800.0;
    const cycle = 4.5;
    const rot = 2.0 * std.math.pi / cycle;
    const ct = t + COLOR_SEED;
    return .{
        @floatCast(0.109375 * (@cos(ct * rot) + 1.0) + 0.0625 * (0.5 + @cos(15.0 * (p + 3.0 * angle)) + @sin(7.0 * (p + angle)))),
        @floatCast(0.109375 * (@cos((ct + cycle / 3.0) * rot) + 1.0) + 0.0625 * (0.5 + @sin(p + angle))),
        @floatCast(0.109375 * (@cos((ct + cycle * 2.0 / 3.0) * rot) + 1.0) + 0.0625 * (0.5 + @cos(37.0 * (p + angle)))),
    };
}

// ---- One 20 ms frame: fade, update the smoke, draw it ----

fn stepFrame() void {
    for (&frame) |*v| v.* *= 1.0 - FADE_ALPHA;
    sim_time += DT;
    updateSmoke();
    drawSmoke();
    for (&frame) |*v| v.* = @min(v.*, 1.0);
}

fn updateSmoke() void {
    const star = starPosition(sim_time);
    var sparks: [STREAMS][3]f32 = undefined;
    for (0..STREAMS) |i| sparks[i] = sparkPosition(sim_time, i);
    const drag: f32 = @floatCast(std.math.pow(f64, 0.9965, DT * 85.0));

    // Each frame, release one puff per stream from the star, heading for its
    // spark and away from the star's motion.
    if (first_step) {
        first_step = false;
        last_particle_time = sim_time;
    } else if (sim_time - last_particle_time >= 1.0 / 121.0) {
        var away: [3]f32 = undefined;
        for (0..3) |a| away[a] = (star_old[a] - star[a]) * 5.0;
        for (0..STREAMS) |i| {
            const p = &particles[next_particle];
            const color = sparkColor(sim_time, i);
            const coherence = @max(0.0, 1.0 + randBell(0.25 * INCOHESION));
            var d: [3]f32 = undefined;
            for (0..3) |a| d[a] = star[a] - sparks[i][a];
            const mag = STREAM_SPEED * coherence / @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
            for (0..3) |a| {
                p.pos[a] = star[a];
                p.old[a] = star[a];
                p.delta[a] = away[a] - d[a] * mag;
            }
            for (0..3) |c| p.color[c] = color[c] * (1.0 + randBell(COLOR_INCOHERENCE));
            p.color[3] = 0.85 * (1.0 + randBell(0.5 * COLOR_INCOHERENCE));
            p.born = sim_time;
            p.dead = false;
            p.anim = @intCast(nextRandom() & 63);
            next_particle = (next_particle + 1) % NUM_PARTICLES;
        }
        last_particle_time = sim_time;
    }
    star_old = star;

    // Every spark pulls every particle by inverse-square gravity, its own
    // stream's spark 8 times as hard.
    for (&particles, 0..) |*p, n| {
        if (p.dead) continue;
        var delta = p.delta;
        for (0..STREAMS) |j| {
            const dx = p.pos[0] - sparks[j][0];
            const dy = p.pos[1] - sparks[j][1];
            const dz = p.pos[2] - sparks[j][2];
            const r2 = dx * dx + dy * dy + dz * dz;
            var f = GRAVITY / r2 * FRAME_RATE_MODIFIER;
            if (n % STREAMS == j) f *= 1.0 + STREAM_BIAS;
            const mag = f / @sqrt(r2);
            delta[0] -= dx * mag;
            delta[1] -= dy * mag;
            delta[2] -= dz * mag;
        }
        for (&delta) |*v| v.* *= drag;
        if (delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] >= 25000000.0) {
            p.dead = true;
            continue;
        }
        p.delta = delta;
        p.old = p.pos;
        for (0..3) |a| p.pos[a] += delta[a] * DT;
    }
}

const Vertex = struct { x: f32, y: f32, u: f32, v: f32 };

// DrawSmoke_Scalar: each particle is a textured quad stretched along its
// motion this frame, a smoke frame from the atlas, added to the framebuffer.
fn drawSmoke() void {
    const w_f: f32 = @floatFromInt(RENDER_W);
    const h_f: f32 = @floatFromInt(RENDER_H);
    const ratio = w_f / 1024.0;
    const max_width = (STREAM_SIZE + 2.5 * STREAM_EXPANSION) * ratio;
    for (&particles) |*p| {
        if (p.dead) continue;
        const age: f32 = @floatCast(sim_time - p.born);
        const width = (STREAM_SIZE + age * STREAM_EXPANSION) * ratio;
        if (width >= max_width) {
            p.dead = true;
            continue;
        }
        const z = p.pos[2];
        const oz = p.old[2];
        const sx = p.pos[0] * w_f / z + w_f * 0.5;
        const sy = p.pos[1] * w_f / z + h_f * 0.5;
        if (sx > w_f + 50.0 or sx < -50.0 or sy > h_f + 50.0 or sy < -50.0 or z < 25.0 or oz < 25.0) continue;
        const w = @max(1.0, width / z);
        const ow = @max(1.0, width / oz);
        const ox = p.old[0] * w_f / oz + w_f * 0.5;
        const oy = p.old[1] * w_f / oz + h_f * 0.5;
        const dx = sx - ox;
        const dy = sy - oy;
        const d = fastDistance2D(dx, dy);
        const sm = if (d != 0) w / d else 0;
        const os = if (d != 0) ow / d else 0;
        const m = 1.0 + sm;

        p.anim = (p.anim + 1) & 63;
        const u_0 = @as(f32, @floatFromInt(p.anim & 7)) * 0.125;
        const v_0 = @as(f32, @floatFromInt(p.anim >> 3)) * 0.125;
        const cm = (1.375 - width / max_width) * BRIGHTNESS;
        // GL clamps vertex colors to [0, 1]. GL_MODULATE scales color and
        // alpha by the luminance-alpha texel, then GL_SRC_ALPHA, GL_ONE adds
        // rgb * alpha.
        const alpha = std.math.clamp(p.color[3] * cm, 0.0, 1.0);
        var color: [3]f32 = undefined;
        for (0..3) |c| color[c] = std.math.clamp(p.color[c] * cm, 0.0, 1.0) * alpha;
        const a = Vertex{ .x = sx + dx * m - dy * sm, .y = sy + dy * m + dx * sm, .u = u_0, .v = v_0 };
        const b = Vertex{ .x = sx + dx * m + dy * sm, .y = sy + dy * m - dx * sm, .u = u_0, .v = v_0 + 0.125 };
        const c = Vertex{ .x = ox - dx * m + dy * os, .y = oy - dy * m - dx * os, .u = u_0 + 0.125, .v = v_0 + 0.125 };
        const e = Vertex{ .x = ox - dx * m - dy * os, .y = oy - dy * m + dx * os, .u = u_0 + 0.125, .v = v_0 };
        drawTriangle(a, b, c, color);
        drawTriangle(a, c, e, color);
    }
}

// Distance with about 3.5% error, as Flurry computes it.
fn fastDistance2D(x_in: f32, y_in: f32) f32 {
    const x = @abs(x_in);
    const y = @abs(y_in);
    const mn = @min(x, y);
    return x + y - mn * 0.5 - mn * 0.25 + mn * 0.0625;
}

fn drawTriangle(a: Vertex, b: Vertex, c: Vertex, color: [3]f32) void {
    const area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (area == 0) return;
    const min_x = @max(0.0, @floor(@min(a.x, @min(b.x, c.x))));
    const max_x = @min(@as(f32, RENDER_W - 1), @ceil(@max(a.x, @max(b.x, c.x))));
    const min_y = @max(0.0, @floor(@min(a.y, @min(b.y, c.y))));
    const max_y = @min(@as(f32, RENDER_H - 1), @ceil(@max(a.y, @max(b.y, c.y))));
    if (min_x > max_x or min_y > max_y) return;
    var y: usize = @intFromFloat(min_y);
    while (y <= @as(usize, @intFromFloat(max_y))) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        // GL's origin is the bottom left; output rows run top down.
        const row = (RENDER_H - 1 - y) * RENDER_W;
        var x: usize = @intFromFloat(min_x);
        while (x <= @as(usize, @intFromFloat(max_x))) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area;
            const w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area;
            const w2 = 1.0 - w0 - w1;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;
            const t = sampleAtlas(w0 * a.u + w1 * b.u + w2 * c.u, w0 * a.v + w1 * b.v + w2 * c.v);
            const k = t * t;
            const o = (row + x) * 3;
            frame[o] += color[0] * k;
            frame[o + 1] += color[1] * k;
            frame[o + 2] += color[2] * k;
        }
    }
}

// Bilinear, repeating, like the GL texture at full size.
fn sampleAtlas(u: f32, v: f32) f32 {
    const x = u * 256.0 - 0.5;
    const y = v * 256.0 - 0.5;
    const fx0 = @floor(x);
    const fy0 = @floor(y);
    const fx = x - fx0;
    const fy = y - fy0;
    const x0: i32 = @intFromFloat(fx0);
    const y0: i32 = @intFromFloat(fy0);
    const t00 = atlasAt(x0, y0);
    const t10 = atlasAt(x0 + 1, y0);
    const t01 = atlasAt(x0, y0 + 1);
    const t11 = atlasAt(x0 + 1, y0 + 1);
    return ((t00 * (1 - fx) + t10 * fx) * (1 - fy) + (t01 * (1 - fx) + t11 * fx) * fy) / 255.0;
}

fn atlasAt(x: i32, y: i32) f32 {
    const xi: usize = @intCast(x & 255);
    const yi: usize = @intCast(y & 255);
    return @floatFromInt(atlas[yi * 256 + xi]);
}

// ---- The smoke texture: 64 frames of speckled, smoothed puffs ----

var small: [32 * 32]u8 = undefined;
var small_first: bool = true;

fn radial(i: usize, j: usize) f32 {
    const di = @as(f32, @floatFromInt(i)) - 15.5;
    const dj = @as(f32, @floatFromInt(j)) - 15.5;
    const r = @sqrt(di * di + dj * dj);
    return if (r > 15.0) 0.0 else 255.0 * @cos(r * std.math.pi / 31.0);
}

fn makeSmallTexture() void {
    for (0..32) |i| {
        for (0..32) |j| {
            const t = radial(i, j);
            small[i * 32 + j] = if (small_first)
                @intFromFloat(t)
            else
                @intFromFloat(@min(255.0, (t + 2.0 * @as(f32, @floatFromInt(small[i * 32 + j]))) / 3.0));
        }
    }
    small_first = false;
    // SpeckleTexture: random walks up and down by doubling amounts.
    for (2..30) |i| {
        for (2..30) |j| {
            var speck: u32 = 1;
            while (speck <= 32 and nextRandom() & 1 != 0) : (speck += speck) {
                small[i * 32 + j] = @intCast(@min(255, @as(u32, small[i * 32 + j]) + speck));
            }
            speck = 1;
            while (speck <= 32 and nextRandom() & 1 != 0) : (speck += speck) {
                small[i * 32 + j] = @intCast(@max(0, @as(i32, small[i * 32 + j]) - @as(i32, @intCast(speck))));
            }
        }
    }
    smoothTexture();
    smoothTexture();
}

fn smoothTexture() void {
    var filtered = small;
    for (1..31) |i| {
        for (1..31) |j| {
            const sum = @as(u32, small[i * 32 + j]) * 4 + small[(i - 1) * 32 + j] + small[(i + 1) * 32 + j] + small[i * 32 + j - 1] + small[i * 32 + j + 1];
            filtered[i * 32 + j] = @intCast(sum / 8);
        }
    }
    small = filtered;
}

fn makeAtlas() void {
    for (0..8) |i| {
        for (0..8) |j| {
            if (i == 7 and j == 7) {
                // The last frame blends into the first, so the loop is smooth.
                for (0..32) |a| {
                    for (0..32) |b| small[a * 32 + b] = @intCast((@as(u32, small[a * 32 + b]) + atlas[a * 256 + b]) / 2);
                }
            } else {
                makeSmallTexture();
            }
            for (0..32) |a| {
                for (0..32) |b| atlas[(i * 32 + a) * 256 + j * 32 + b] = small[a * 32 + b];
            }
        }
    }
}

test "sparks follow Flurry's closed-form orbits" {
    // The C code puts every spark about seraphDistance in front of the eye.
    for (0..STREAMS) |i| {
        const p = sparkPosition(140.0, i);
        try std.testing.expect(p[2] > 0.0 and p[2] < 4500.0);
    }
    try std.testing.expectEqual(@as(f64, 138), sparkMystery(0));
    try std.testing.expectEqual(@as(f64, 692), sparkMystery(4));
}

test "a frame fades the previous one and adds smoke" {
    ensureInitialized();
    for (0..200) |_| stepFrame();
    var alive: usize = 0;
    for (particles) |p| alive += @intFromBool(!p.dead);
    // 5 puffs per 20 ms frame, each living 2.5 s.
    try std.testing.expect(alive > 500 and alive <= 625);
    var lit: usize = 0;
    for (frame) |v| {
        try std.testing.expect(v >= 0.0 and v <= 1.0);
        lit += @intFromBool(v > 0.05);
    }
    try std.testing.expect(lit > 1000);
    // With no new smoke, 53 fades take every value below 1/255.
    for (&particles) |*p| p.dead = true;
    for (0..53) |_| {
        for (&frame) |*v| v.* *= 1.0 - FADE_ALPHA;
    }
    for (frame) |v| try std.testing.expect(v < 1.0 / 255.0);
}
