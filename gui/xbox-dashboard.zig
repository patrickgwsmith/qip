// A console dashboard in the style of the original Xbox, drawn at 2x.
//
// A glowing green orb sits on the left with hollow light tubes flowing out of
// it, and four capsule buttons on the right open Memory, Music, Online and
// Settings. Memory lists the saves on the hard disk and a memory unit, and
// saves can be deleted. Music plays a soundtrack: the orb pulses to the beat
// and a visualiser follows the audio output setting. Online runs a connection
// test. Settings changes the glow, background motion, audio output and the
// button guide.
//
// All motion is derived from update time: begin_update_at eases selections and
// advances playback by the time since the previous update, so the same updates
// always produce the same frame. While anything moves, finish_update asks for
// the next frame; once still it stops asking.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const font = @import("inter_regular");

const W: usize = 960;
const H: usize = 720;
const WF: f32 = @floatFromInt(W);
const HF: f32 = @floatFromInt(H);
const PIXEL_BYTES: usize = W * H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const XK_RETURN: i32 = 0xFF0D;
const XK_KP_ENTER: i32 = 0xFF8D;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;

const FRAME_MS: i64 = 16;
const TOAST_MS: i64 = 2000;
const TEST_STEP_MS: i64 = 900;

// ---- Content ---------------------------------------------------------------------

const Section = enum(u8) { memory, music, online, settings };
const section_labels = [4][]const u8{ "Memory", "Music", "Online", "Settings" };

const SaveInfo = struct { title: []const u8, blocks: u16 };
const save_catalog = [_]SaveInfo{
    .{ .title = "Coral Circuit", .blocks = 312 },
    .{ .title = "Northwind Tactics", .blocks = 1040 },
    .{ .title = "Paper Comet", .blocks = 58 },
    .{ .title = "Ironvale Racing", .blocks = 220 },
    .{ .title = "Sunken Bell", .blocks = 96 },
    .{ .title = "Halcyon Arena", .blocks = 412 },
    .{ .title = "Mirefall", .blocks = 140 },
};

const MAX_SAVES = 8;
const Device = struct {
    name: []const u8,
    capacity: u32,
    ids: [MAX_SAVES]u8 = undefined,
    len: u8 = 0,

    fn freeBlocks(self: *const Device) u32 {
        var used: u32 = 0;
        for (self.ids[0..self.len]) |id| used += save_catalog[id].blocks;
        return self.capacity - used;
    }
    fn remove(self: *Device, index: usize) void {
        var i = index;
        while (i + 1 < self.len) : (i += 1) self.ids[i] = self.ids[i + 1];
        self.len -= 1;
    }
};

fn initialDevices() [2]Device {
    var d: [2]Device = .{ .{ .name = "Hard Disk", .capacity = 50000 }, .{ .name = "Memory Unit A", .capacity = 500 } };
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |id| {
        d[0].ids[d[0].len] = id;
        d[0].len += 1;
    }
    for ([_]u8{ 2, 6 }) |id| {
        d[1].ids[d[1].len] = id;
        d[1].len += 1;
    }
    return d;
}

const Track = struct { title: []const u8, seconds: u16, bpm: f32 };
const tracks = [_]Track{
    .{ .title = "Neon Undertow", .seconds = 214, .bpm = 124 },
    .{ .title = "Glasshouse", .seconds = 187, .bpm = 96 },
    .{ .title = "Signal Fires", .seconds = 241, .bpm = 138 },
    .{ .title = "Low Orbit", .seconds = 176, .bpm = 88 },
    .{ .title = "Copperline", .seconds = 203, .bpm = 112 },
};
const ALBUM = "Night Transit";

const test_steps = [_][2][]const u8{
    .{ "Network adapter", "Connected" },
    .{ "IP address", "192.168.1.24" },
    .{ "DNS", "Resolved" },
    .{ "Online service", "No response" },
};

const Setting = enum(u8) { glow, motion, audio, hints };
const SETTING_COUNT = 4;
const setting_labels = [SETTING_COUNT][]const u8{ "Glow", "Background Motion", "Audio Output", "Button Guide" };
const glow_values = [_][]const u8{ "Soft", "Normal", "Bright" };
const audio_values = [_][]const u8{ "Mono", "Stereo", "Surround" };

// ---- State -----------------------------------------------------------------------

const Toast = struct { text: []const u8, start_ms: i64 };

const State = struct {
    in_section: bool = false,
    section: Section = .memory,
    main_sel: u8 = 0,

    devices: [2]Device = initialDevices(),
    device: u8 = 0,
    save_sel: [2]u8 = .{ 0, 0 },
    confirm: bool = false,
    confirm_sel: u8 = 1,

    track_sel: u8 = 0,
    playing: ?u8 = null,
    paused: bool = false,
    play_pos_ms: f64 = 0,

    test_start_ms: ?i64 = null,

    sys_sel: u8 = 0,
    glow: u8 = 1,
    motion: bool = true,
    audio: u8 = 1,
    hints: bool = true,
    value_change_ms: i64 = -100_000,
    value_dir: f32 = 1,

    toast: ?Toast = null,

    // Eased values, advanced in begin_update_at.
    main_f: f32 = 0,
    section_f: f32 = 0,
    device_f: f32 = 0,
    save_f: f32 = 0,
    track_f: f32 = 0,
    sys_f: f32 = 0,
    confirm_open: f32 = 0,
    confirm_f: f32 = 1,
    ambient_t: f64 = 0,
    clock_t: f64 = 0,

    primary_down: bool = false,
    secondary_down: bool = false,
};

const Phase = enum { initializing, ready, updating };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var bg_buf: [PIXEL_BYTES]u8 = undefined;
var bg_ready = false;
var state: State = .{};
var phase: Phase = .initializing;
var now_ms: i64 = 0;
var last_update_ms: i64 = 0;
var committed_at_ms: i64 = 0;

// ---- ABI -------------------------------------------------------------------------

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_BYTES);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(time_ms: i64) void {
    if (phase != .ready) @trap();
    if (time_ms <= 0 or time_ms <= committed_at_ms) @trap();
    now_ms = time_ms;
    phase = .updating;
    const dt: f32 = @floatFromInt(std.math.clamp(time_ms - last_update_ms, 0, 250));
    last_update_ms = time_ms;
    advance(dt);
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    phase = .ready;
    committed_at_ms = now_ms;
    return if (isAnimating()) now_ms + FRAME_MS else now_ms;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    const action: Action = switch (x11_key) {
        XK_UP, 'w', 'W' => .up,
        XK_DOWN, 's', 'S' => .down,
        XK_LEFT => .left,
        XK_RIGHT => .right,
        // A and B are the controller's select and back buttons.
        XK_RETURN, XK_KP_ENTER, ' ', 'a', 'A' => .confirm,
        XK_ESCAPE, XK_BACKSPACE, 'b', 'B' => .back,
        else => return 0,
    };
    return if (perform(action)) 1 else 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireEventPhase();
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;
    const x: f32 = @floatFromInt(x_px);
    const y: f32 = @floatFromInt(y_px);
    var changed = false;

    const hit = hitTest(x, y);
    if (hit) |h| changed = hover(h) or changed;
    if (primary and !state.primary_down) {
        if (hit) |h| {
            changed = activate(h) or changed;
        } else if (state.confirm) {
            changed = perform(.back) or changed;
        }
    }
    if (secondary and !state.secondary_down) {
        // Accept the press even with nothing to close, so no context menu opens.
        _ = perform(.back);
        changed = true;
    }
    state.primary_down = primary;
    state.secondary_down = secondary;
    return if (changed) 1 else 0;
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

fn requireEventPhase() void {
    if (phase != .updating) @trap();
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, W, H) orelse @trap();
    drawFrame();
    phase = .ready;
    return @intCast(OUTPUT_BYTES);
}

// ---- Behaviour -------------------------------------------------------------------

const Action = enum { up, down, left, right, confirm, back };

fn approach(value: *f32, target: f32, dt: f32, tau_ms: f32) void {
    const k = 1 - @exp(-dt / tau_ms);
    value.* += (target - value.*) * k;
    if (@abs(target - value.*) < 0.001) value.* = target;
}

fn advance(dt: f32) void {
    approach(&state.main_f, @floatFromInt(state.main_sel), dt, 70);
    approach(&state.section_f, if (state.in_section) 1 else 0, dt, 110);
    approach(&state.device_f, @floatFromInt(state.device), dt, 70);
    approach(&state.save_f, @floatFromInt(state.save_sel[state.device]), dt, 60);
    approach(&state.track_f, @floatFromInt(state.track_sel), dt, 60);
    approach(&state.sys_f, @floatFromInt(state.sys_sel), dt, 60);
    approach(&state.confirm_open, if (state.confirm) 1 else 0, dt, 60);
    approach(&state.confirm_f, @floatFromInt(state.confirm_sel), dt, 50);
    if (state.motion) state.ambient_t += dt / 1000;
    state.clock_t += dt / 1000;

    if (state.playing) |p| {
        if (!state.paused) {
            state.play_pos_ms += dt;
            const length = @as(f64, @floatFromInt(tracks[p].seconds)) * 1000;
            if (state.play_pos_ms >= length) {
                state.playing = @intCast((p + 1) % tracks.len);
                state.play_pos_ms -= length;
            }
        }
    }
    if (state.toast) |t| {
        if (now_ms - t.start_ms >= TOAST_MS) state.toast = null;
    }
}

fn testRunning() bool {
    const start = state.test_start_ms orelse return false;
    return now_ms - start < TEST_STEP_MS * test_steps.len;
}

fn isAnimating() bool {
    if (state.motion) return true;
    if ((state.playing != null and !state.paused) or testRunning() or state.toast != null) return true;
    if (now_ms - state.value_change_ms < 300) return true;
    const pairs = [_][2]f32{
        .{ state.main_f, @floatFromInt(state.main_sel) },
        .{ state.section_f, if (state.in_section) 1 else 0 },
        .{ state.device_f, @floatFromInt(state.device) },
        .{ state.save_f, @floatFromInt(state.save_sel[state.device]) },
        .{ state.track_f, @floatFromInt(state.track_sel) },
        .{ state.sys_f, @floatFromInt(state.sys_sel) },
        .{ state.confirm_open, if (state.confirm) 1 else 0 },
        .{ state.confirm_f, @floatFromInt(state.confirm_sel) },
    };
    for (pairs) |p| if (p[0] != p[1]) return true;
    return false;
}

fn showToast(text: []const u8) void {
    state.toast = .{ .text = text, .start_ms = now_ms };
}

fn clampStep(v: u8, delta: i32, count: usize) u8 {
    if (count == 0) return 0;
    return @intCast(std.math.clamp(@as(i32, v) + delta, 0, @as(i32, @intCast(count)) - 1));
}

fn wrapStep(v: u8, delta: i32, count: usize) u8 {
    return @intCast(@mod(@as(i32, v) + delta, @as(i32, @intCast(count))));
}

fn openSection() void {
    state.section = @enumFromInt(state.main_sel);
    state.in_section = true;
}

fn perform(action: Action) bool {
    if (state.confirm) {
        switch (action) {
            .left, .up => state.confirm_sel = 0,
            .right, .down => state.confirm_sel = 1,
            .back => state.confirm = false,
            .confirm => {
                if (state.confirm_sel == 0) deleteSelected();
                state.confirm = false;
            },
        }
        return true;
    }
    if (!state.in_section) {
        switch (action) {
            .up, .left => state.main_sel = clampStep(state.main_sel, -1, 4),
            .down, .right => state.main_sel = clampStep(state.main_sel, 1, 4),
            .confirm => openSection(),
            .back => return false,
        }
        return true;
    }
    if (action == .back) {
        state.in_section = false;
        return true;
    }
    switch (state.section) {
        .memory => {
            const dev = &state.devices[state.device];
            const sel = &state.save_sel[state.device];
            switch (action) {
                .left => state.device = 0,
                .right => state.device = 1,
                .up => sel.* = clampStep(sel.*, -1, dev.len),
                .down => sel.* = clampStep(sel.*, 1, dev.len),
                .confirm => if (dev.len > 0) {
                    state.confirm = true;
                    state.confirm_sel = 1;
                    state.confirm_f = 1;
                },
                .back => unreachable,
            }
        },
        .music => switch (action) {
            .up, .left => state.track_sel = clampStep(state.track_sel, -1, tracks.len),
            .down, .right => state.track_sel = clampStep(state.track_sel, 1, tracks.len),
            .confirm => playOrPause(state.track_sel),
            .back => unreachable,
        },
        .online => switch (action) {
            .confirm => {
                if (!testRunning()) state.test_start_ms = now_ms;
            },
            else => return false,
        },
        .settings => switch (action) {
            .up => state.sys_sel = clampStep(state.sys_sel, -1, SETTING_COUNT),
            .down => state.sys_sel = clampStep(state.sys_sel, 1, SETTING_COUNT),
            .left => changeSetting(-1),
            .right, .confirm => changeSetting(1),
            .back => unreachable,
        },
    }
    return true;
}

fn playOrPause(track: u8) void {
    if (state.playing == track) {
        state.paused = !state.paused;
    } else {
        state.playing = track;
        state.paused = false;
        state.play_pos_ms = 0;
    }
}

fn deleteSelected() void {
    const dev = &state.devices[state.device];
    const sel = &state.save_sel[state.device];
    dev.remove(sel.*);
    if (sel.* >= dev.len and sel.* > 0) sel.* -= 1;
    showToast("Saved game deleted");
}

fn changeSetting(delta: i32) void {
    switch (@as(Setting, @enumFromInt(state.sys_sel))) {
        .glow => state.glow = wrapStep(state.glow, delta, glow_values.len),
        .motion => state.motion = !state.motion,
        .audio => state.audio = wrapStep(state.audio, delta, audio_values.len),
        .hints => state.hints = !state.hints,
    }
    state.value_change_ms = now_ms;
    state.value_dir = if (delta < 0) -1 else 1;
}

// ---- Layout and hit testing ------------------------------------------------------

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

const ORB_MAIN_X: f32 = 290;
const ORB_MAIN_Y: f32 = 372;
const ORB_MAIN_R: f32 = 128;
const ORB_SUB_X: f32 = 120;
const ORB_SUB_Y: f32 = 372;
const ORB_SUB_R: f32 = 64;

const BUTTON_X: f32 = 560;
const BUTTON_W: f32 = 320;
const BUTTON_H: f32 = 74;
const BUTTON_Y0: f32 = 196;
const BUTTON_STEP: f32 = 96;

fn buttonRect(i: usize) Rect {
    return .{ .x = BUTTON_X, .y = BUTTON_Y0 + @as(f32, @floatFromInt(i)) * BUTTON_STEP, .w = BUTTON_W, .h = BUTTON_H };
}

const PANEL_X: f32 = 250;
const PANEL_W: f32 = 650;
const LIST_Y: f32 = 214;
const ROW_H: f32 = 58;
const ROW_GAP: f32 = 8;

fn rowRect(i: usize) Rect {
    return .{ .x = PANEL_X, .y = LIST_Y + @as(f32, @floatFromInt(i)) * (ROW_H + ROW_GAP), .w = PANEL_W, .h = ROW_H };
}

fn tabRect(i: usize) Rect {
    return .{ .x = PANEL_X + @as(f32, @floatFromInt(i)) * 230, .y = 132, .w = 214, .h = 50 };
}

const TEST_BUTTON: Rect = .{ .x = PANEL_X, .y = 140, .w = 300, .h = 62 };
const TITLE_RECT: Rect = .{ .x = 30, .y = 30, .w = 600, .h = 90 };

fn confirmPanel() Rect {
    return .{ .x = (WF - 480) / 2, .y = (HF - 230) / 2, .w = 480, .h = 230 };
}

fn confirmButtonRect(i: usize) Rect {
    const p = confirmPanel();
    const bw: f32 = 170;
    const gap: f32 = 24;
    const x0 = p.x + (p.w - 2 * bw - gap) / 2;
    return .{ .x = x0 + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y + p.h - 90, .w = bw, .h = 60 };
}

const FOOTER_Y: f32 = 668;
const FOOTER_PX: f32 = 24;
const Badge = enum { a, b, lr };
const FooterItem = struct { badge: Badge, label: []const u8, action: Action };

fn footerItems(buf: *[3]FooterItem) []const FooterItem {
    var n: usize = 0;
    if (!state.confirm and state.in_section) {
        switch (state.section) {
            .memory => {
                buf[n] = .{ .badge = .lr, .label = "Device", .action = .right };
                n += 1;
            },
            .settings => {
                buf[n] = .{ .badge = .lr, .label = "Change", .action = .right };
                n += 1;
            },
            else => {},
        }
    }
    const a_label: []const u8 = if (state.confirm) "Select" else if (!state.in_section) "Select" else switch (state.section) {
        .memory => "Delete",
        .music => if (state.playing == state.track_sel and !state.paused) "Pause" else "Play",
        .online => "Test",
        .settings => "Change",
    };
    if (!(state.in_section and state.section == .settings and !state.confirm)) {
        buf[n] = .{ .badge = .a, .label = a_label, .action = .confirm };
        n += 1;
    }
    if (state.in_section or state.confirm) {
        buf[n] = .{ .badge = .b, .label = "Back", .action = .back };
        n += 1;
    }
    return buf[0..n];
}

fn footerItemRect(items: []const FooterItem, index: usize) Rect {
    var x: f32 = WF - 64;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const w = 46 + textWidth(items[i].label, FOOTER_PX);
        x -= w;
        if (i == index) return .{ .x = x - 6, .y = FOOTER_Y - 26, .w = w + 12, .h = 52 };
        x -= 36;
    }
    unreachable;
}

const Hit = union(enum) {
    button: u8,
    tab: u8,
    row: u8,
    setting: struct { index: u8, dir: i32 },
    test_button,
    confirm_button: u8,
    confirm_panel,
    back,
    footer: Action,
};

fn hitTest(x: f32, y: f32) ?Hit {
    if (state.hints) {
        var buf: [3]FooterItem = undefined;
        const items = footerItems(&buf);
        for (items, 0..) |item, i| {
            if (footerItemRect(items, i).contains(x, y)) return .{ .footer = item.action };
        }
    }
    if (state.confirm) {
        for (0..2) |i| if (confirmButtonRect(i).contains(x, y)) return .{ .confirm_button = @intCast(i) };
        if (confirmPanel().contains(x, y)) return .confirm_panel;
        return null;
    }
    if (!state.in_section) {
        for (0..4) |i| if (buttonRect(i).contains(x, y)) return .{ .button = @intCast(i) };
        return null;
    }
    if (TITLE_RECT.contains(x, y)) return .back;
    const dx = x - ORB_SUB_X;
    const dy = y - ORB_SUB_Y;
    if (dx * dx + dy * dy < ORB_SUB_R * ORB_SUB_R) return .back;
    switch (state.section) {
        .memory => {
            for (0..2) |i| if (tabRect(i).contains(x, y)) return .{ .tab = @intCast(i) };
            for (0..state.devices[state.device].len) |i| if (rowRect(i).contains(x, y)) return .{ .row = @intCast(i) };
        },
        .music => for (0..tracks.len) |i| if (rowRect(i).contains(x, y)) return .{ .row = @intCast(i) },
        .online => if (TEST_BUTTON.contains(x, y)) return .test_button,
        .settings => for (0..SETTING_COUNT) |i| {
            const r = rowRect(i);
            if (r.contains(x, y)) {
                const dir: i32 = if (x > r.x + r.w - 130) 1 else if (x > r.x + r.w - 320) -1 else 0;
                return .{ .setting = .{ .index = @intCast(i), .dir = dir } };
            }
        },
    }
    return null;
}

fn setSel(field: *u8, value: u8) bool {
    if (field.* == value) return false;
    field.* = value;
    return true;
}

fn hover(h: Hit) bool {
    return switch (h) {
        .button => |i| setSel(&state.main_sel, i),
        .row => |i| switch (state.section) {
            .memory => setSel(&state.save_sel[state.device], i),
            .music => setSel(&state.track_sel, i),
            else => false,
        },
        .setting => |s| setSel(&state.sys_sel, s.index),
        .confirm_button => |i| setSel(&state.confirm_sel, i),
        else => false,
    };
}

fn activate(h: Hit) bool {
    switch (h) {
        .button, .row, .test_button, .confirm_button => return perform(.confirm),
        .tab => |i| return setSel(&state.device, i),
        .setting => |s| {
            changeSetting(if (s.dir < 0) -1 else 1);
            return true;
        },
        .back => return perform(.back),
        .footer => |a| return perform(a),
        .confirm_panel => return false,
    }
}

// ---- Colours ---------------------------------------------------------------------

const Color = [3]u8;
const C_GREEN: Color = .{ 0x6C, 0xD6, 0x2E };
const C_LIME: Color = .{ 0xC6, 0xFF, 0x6E };
const C_TEXT: Color = .{ 0xEA, 0xFF, 0xDC };
const C_DIM: Color = .{ 0x8C, 0xB2, 0x80 };
const C_DARK: Color = .{ 0x06, 0x1A, 0x0A };
const C_PANEL: Color = .{ 0x07, 0x18, 0x0B };

fn mix(a: Color, b: Color, t: f32) Color {
    var out: Color = undefined;
    for (0..3) |i| {
        const av: f32 = @floatFromInt(a[i]);
        const bv: f32 = @floatFromInt(b[i]);
        out[i] = @intFromFloat(std.math.clamp(@round(av + (bv - av) * t), 0, 255));
    }
    return out;
}

fn scale(c: Color, k: f32) Color {
    var out: Color = undefined;
    for (0..3) |i| out[i] = @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(c[i])) * k), 0, 255));
    return out;
}

fn easeOut(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

fn glowLevel() f32 {
    return ([_]f32{ 0.6, 1, 1.45 })[state.glow];
}

// The orb swells on each beat of the playing track.
fn beatPulse() f32 {
    const p = state.playing orelse return 0;
    if (state.paused) return 0;
    const beats = state.play_pos_ms / 60000 * tracks[p].bpm;
    const f: f32 = @floatCast(beats - @floor(beats));
    return @exp(-f * 5);
}

// ---- Frame -----------------------------------------------------------------------

fn drawFrame() void {
    if (!bg_ready) buildBackground();
    @memcpy(output_buf[ktx.HEADER_SIZE..], &bg_buf);
    const s = easeOut(state.section_f);
    const orb_x = ORB_MAIN_X + (ORB_SUB_X - ORB_MAIN_X) * s;
    const orb_y = ORB_MAIN_Y + (ORB_SUB_Y - ORB_MAIN_Y) * s;
    const orb_r = ORB_MAIN_R + (ORB_SUB_R - ORB_MAIN_R) * s;
    drawTubes(orb_x, orb_y, orb_r);
    drawOrb(orb_x, orb_y, orb_r);

    if (state.section_f < 0.999) {
        g_alpha = 1 - state.section_f;
        g_dx = @intFromFloat(@round(240 * s));
        drawMainButtons(orb_x, orb_y, orb_r);
    }
    if (state.section_f > 0.001) {
        g_alpha = state.section_f;
        g_dx = @intFromFloat(@round(120 * (1 - s)));
        drawSection();
    }
    g_alpha = 1;
    g_dx = 0;

    drawConfirm();
    drawToast();
    if (state.hints) drawFooter();
}

// ---- Background, tubes and orb ---------------------------------------------------

fn buildBackground() void {
    bg_ready = true;
    for (0..H) |y| {
        const fy: f32 = @floatFromInt(y);
        for (0..W) |x| {
            const fx: f32 = @floatFromInt(x);
            const dx = (fx - ORB_MAIN_X) / 760;
            const dy = (fy - ORB_MAIN_Y) / 560;
            const g = @exp(-(dx * dx + dy * dy) * 3);
            const vignette = 1 - 0.5 * std.math.clamp((fy / HF - 0.5) * (fy / HF - 0.5) * 4, 0, 1);
            const c = mix(.{ 0x01, 0x05, 0x02 }, .{ 0x0E, 0x34, 0x12 }, g * vignette);
            const d: f32 = @floatFromInt((x * 7 + y * 13) % 4);
            const i = (y * W + x) * 4;
            for (0..3) |ch| bg_buf[i + ch] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(c[ch])) + (d - 1.5) * 0.5, 0, 255));
            bg_buf[i + 3] = 0xFF;
        }
    }
}

const Tube = struct { y: f32, amp: f32, freq: f32, speed: f32, phase: f32, radius: f32, dir: f32 };
const tube_set = [_]Tube{
    .{ .y = -40, .amp = 90, .freq = 0.0042, .speed = 0.35, .phase = 0.0, .radius = 20, .dir = 1 },
    .{ .y = 70, .amp = 70, .freq = 0.0055, .speed = -0.28, .phase = 1.7, .radius = 15, .dir = 1 },
    .{ .y = 170, .amp = 110, .freq = 0.0036, .speed = 0.22, .phase = 3.1, .radius = 24, .dir = 1 },
    .{ .y = -150, .amp = 80, .freq = 0.0048, .speed = -0.31, .phase = 4.4, .radius = 13, .dir = 1 },
    .{ .y = 20, .amp = 120, .freq = 0.0060, .speed = 0.26, .phase = 0.9, .radius = 18, .dir = -1 },
    .{ .y = 240, .amp = 60, .freq = 0.0050, .speed = -0.2, .phase = 2.4, .radius = 14, .dir = -1 },
};

// Hollow tubes of light leave the orb and wander off the edge of the screen.
// Each tube is a curve y = f(x), so each column only visits the rows near it.
fn drawTubes(ox: f32, oy: f32, orb_r: f32) void {
    const t: f32 = @floatCast(state.ambient_t);
    const level = glowLevel() * (0.55 + 0.25 * beatPulse());
    const s = easeOut(state.section_f);
    for (tube_set) |tube| {
        const r = tube.radius * (1 - 0.35 * s);
        const x_start: i32 = if (tube.dir > 0) @intFromFloat(ox) else 0;
        const x_end: i32 = if (tube.dir > 0) @as(i32, W) else @intFromFloat(ox);
        var x = x_start;
        while (x < x_end) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            // Distance from the orb along the tube, 0 at the orb.
            const u = @abs(fx - ox);
            const ease = 1 - @exp(-u / 180);
            const arg = u * tube.freq + t * tube.speed + tube.phase;
            const cy = oy + (tube.y * (1 - 0.3 * s) + tube.amp * @sin(arg)) * ease;
            const slope = (tube.y + tube.amp * @sin(arg)) * (@exp(-u / 180) / 180) + tube.amp * tube.freq * @cos(arg) * ease;
            const stretch = @sqrt(1 + slope * slope);
            const half = r * stretch;
            // Fade in as the tube leaves the orb, and out towards the far edge.
            const fade = std.math.clamp((u - orb_r * 0.6) / 90, 0, 1) * std.math.clamp(1.2 - u / 900, 0.25, 1);
            if (fade <= 0) continue;
            const y0: i32 = @intFromFloat(@max(0, @floor(cy - half - 2)));
            const y1: i32 = @intFromFloat(@min(HF, @ceil(cy + half + 2)));
            var y = y0;
            while (y < y1) : (y += 1) {
                const d = @abs(@as(f32, @floatFromInt(y)) + 0.5 - cy) / half;
                if (d >= 1.1) continue;
                // Bright walls, a faint core, and a soft outer edge.
                const wall = 1 - std.math.clamp(@abs(d - 0.86) / 0.22, 0, 1);
                const core = std.math.clamp(1 - d, 0, 1) * 0.22;
                const v = (wall * wall * 0.8 + core) * fade * level;
                if (v > 0.004) addPixel(x, y, C_GREEN, v * 0.7);
            }
        }
    }
}

fn drawOrb(cx: f32, cy: f32, r_base: f32) void {
    const t: f32 = @floatCast(state.ambient_t);
    const beat = beatPulse();
    const r = r_base * (1 + 0.04 * beat);
    const level = glowLevel();
    addGlow(cx, cy, r * 1.8, r * 1.8, C_GREEN, 0.26 * level * (1 + 0.6 * beat));
    const s = spanOf(cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1);
    var y = s.y0;
    while (y < s.y1) : (y += 1) {
        const ny = (@as(f32, @floatFromInt(y)) + 0.5 - cy) / r;
        var x = s.x0;
        while (x < s.x1) : (x += 1) {
            const nx = (@as(f32, @floatFromInt(x)) + 0.5 - cx) / r;
            const d2 = nx * nx + ny * ny;
            const cov = std.math.clamp((1 - @sqrt(d2)) * r + 0.5, 0, 1);
            if (cov <= 0) continue;
            const nz = @sqrt(@max(0, 1 - d2));
            // Swirling light inside the glass, seen through the sphere's surface.
            const sx = nx / (nz + 0.6);
            const sy = ny / (nz + 0.6);
            const swirl = @sin(sx * 5.5 + t * 0.9 + @sin(sy * 4 - t * 0.6) * 1.6) * @sin(sy * 6.0 - t * 0.7 + @sin(sx * 3 + t * 0.4) * 1.3);
            const inner = 0.5 + 0.5 * swirl;
            const core = @exp(-d2 * 2.2);
            const rim = (1 - nz) * (1 - nz);
            const s1 = @max(0, nx * -0.35 + ny * -0.55 + nz * 0.76);
            const s4 = s1 * s1 * s1 * s1;
            const s16 = s4 * s4 * s4 * s4;
            const spec = s16 * s4 * s4;
            var c = mix(.{ 0x06, 0x2C, 0x0A }, C_GREEN, 0.2 + 0.6 * inner * nz);
            c = mix(c, C_LIME, @min(1, core * (0.7 + 0.5 * beat) * level));
            c = mix(c, .{ 0xB8, 0xFF, 0x80 }, rim * 0.75);
            c = mix(c, .{ 0xFF, 0xFF, 0xF4 }, spec * 0.85);
            blend(x, y, c, cov);
        }
    }
}

// ---- Main buttons ----------------------------------------------------------------

fn drawMainButtons(orb_x: f32, orb_y: f32, orb_r: f32) void {
    const t: f32 = @floatCast(state.clock_t);
    // A lit connector runs from the orb to the selected button.
    const sel_y = BUTTON_Y0 + state.main_f * BUTTON_STEP + BUTTON_H / 2;
    drawConnector(orb_x + orb_r * 0.92, orb_y + (sel_y - orb_y) * 0.25, BUTTON_X + 8, sel_y);

    for (0..4) |i| {
        const r = buttonRect(i);
        const near = std.math.clamp(1 - @abs(state.main_f - @as(f32, @floatFromInt(i))), 0, 1);
        const pulse = 0.85 + 0.15 * @sin(t * 3.0);
        drawCapsule(r, near, pulse);
        const label = section_labels[i];
        const color = mix(C_DIM, mix(C_TEXT, C_DARK, 0.9), near);
        drawText(label, r.x + 44, r.y + r.h / 2 + 12, 34, color, 1);
    }
}

fn drawConnector(x0: f32, y0: f32, x1: f32, y1: f32) void {
    const steps: usize = 48;
    var prev_x = x0;
    var prev_y = y0;
    for (1..steps + 1) |i| {
        const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const e = u * u * (3 - 2 * u);
        const x = x0 + (x1 - x0) * u;
        const y = y0 + (y1 - y0) * e;
        strokeSegment(prev_x, prev_y, x, y, 7, C_GREEN, 0.35);
        strokeSegment(prev_x, prev_y, x, y, 2.2, C_LIME, 0.9);
        prev_x = x;
        prev_y = y;
    }
    addGlow(x1, y1, 34, 26, C_LIME, 0.5);
}

fn drawCapsule(r: Rect, lit: f32, pulse: f32) void {
    const rad = r.h / 2;
    // Chrome rim, then a glass body that lights up when selected.
    fillRoundRectGrad(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, rad + 3, .{ 0x9C, 0xB8, 0x92 }, .{ 0x2C, 0x40, 0x2A }, 1);
    const top = mix(.{ 0x16, 0x3A, 0x18 }, .{ 0xC4, 0xFF, 0x78 }, lit * pulse);
    const bottom = mix(.{ 0x06, 0x1C, 0x08 }, .{ 0x58, 0xC0, 0x22 }, lit * pulse);
    fillRoundRectGrad(r, rad, top, bottom, 1);
    // Glassy highlight across the top half.
    fillRoundRect(.{ .x = r.x + 14, .y = r.y + 5, .w = r.w - 28, .h = r.h * 0.38 }, r.h * 0.19, .{ 0xFF, 0xFF, 0xFF }, 0.05 + 0.15 * lit);
    if (lit > 0.01) addGlow(r.x + r.w / 2, r.y + r.h / 2, r.w * 0.75, r.h * 1.3, C_GREEN, 0.28 * lit * glowLevel());
}

// ---- Sections --------------------------------------------------------------------

fn drawSectionTitle(text: []const u8) void {
    drawChevron(60, 78, 12, -1, C_DIM, 1);
    drawText(text, 86, 94, 48, C_LIME, 1);
}

fn drawSection() void {
    drawSectionTitle(section_labels[@intFromEnum(state.section)]);
    switch (state.section) {
        .memory => drawMemory(),
        .music => drawMusic(),
        .online => drawOnline(),
        .settings => drawSettings(),
    }
}

fn drawRowHighlight(f: f32) void {
    const y = LIST_Y + f * (ROW_H + ROW_GAP);
    const r: Rect = .{ .x = PANEL_X, .y = y, .w = PANEL_W, .h = ROW_H };
    fillRoundRectGrad(r, ROW_H / 2, .{ 0x3A, 0x8A, 0x1E }, .{ 0x1E, 0x5A, 0x10 }, 0.85);
    fillRoundRect(.{ .x = r.x + 16, .y = r.y + 4, .w = r.w - 32, .h = r.h * 0.36 }, r.h * 0.18, .{ 0xFF, 0xFF, 0xFF }, 0.08);
    addGlow(r.x + r.w / 2, r.y + r.h / 2, r.w * 0.6, r.h * 1.2, C_GREEN, 0.14 * glowLevel());
}

fn drawRowBase(i: usize) void {
    fillRoundRect(rowRect(i), ROW_H / 2, C_PANEL, 0.55);
}

fn drawMemory() void {
    // Device tabs.
    const tab_x = PANEL_X + state.device_f * 230;
    fillRoundRect(.{ .x = tab_x, .y = 132, .w = 214, .h = 50 }, 25, .{ 0x2E, 0x6E, 0x1A }, 0.9);
    for (0..2) |i| {
        const r = tabRect(i);
        const near = std.math.clamp(1 - @abs(state.device_f - @as(f32, @floatFromInt(i))), 0, 1);
        drawTextCentered(state.devices[i].name, r.x + r.w / 2, r.y + 34, 24, mix(C_DIM, C_TEXT, near), 1);
    }
    const dev = &state.devices[state.device];
    var free: TextBuf = .{};
    addThousands(&free, dev.freeBlocks());
    free.add(" blocks free");
    const fw = textWidth(free.slice(), 22);
    drawText(free.slice(), PANEL_X + PANEL_W - fw - 8, 165, 22, C_DIM, 1);

    if (dev.len == 0) {
        drawTextCentered("No saved games", PANEL_X + PANEL_W / 2, 330, 30, C_DIM, 1);
        return;
    }
    drawRowHighlight(state.save_f);
    for (dev.ids[0..dev.len], 0..) |id, i| {
        const r = rowRect(i);
        const selected = i == state.save_sel[state.device];
        if (!selected) drawRowBase(i);
        const info = save_catalog[id];
        drawSaveGlyph(r.x + 40, r.y + r.h / 2, id, selected);
        drawText(info.title, r.x + 74, r.y + 38, 26, if (selected) C_TEXT else C_DIM, 1);
        var blocks: TextBuf = .{};
        addThousands(&blocks, info.blocks);
        blocks.add(" blocks");
        const bw = textWidth(blocks.slice(), 22);
        drawText(blocks.slice(), r.x + r.w - 32 - bw, r.y + 37, 22, if (selected) C_TEXT else C_DIM, 1);
    }
}

// A small rounded tile with a two-letter monogram stands in for a save icon.
fn drawSaveGlyph(cx: f32, cy: f32, id: u8, selected: bool) void {
    const hue_colors = [_]Color{ .{ 0x3E, 0x9C, 0xD8 }, .{ 0xD8, 0x8E, 0x3A }, .{ 0xC8, 0x5A, 0xC8 }, .{ 0xC8, 0x48, 0x40 }, .{ 0x40, 0xB0, 0x98 }, .{ 0xD8, 0xC4, 0x46 }, .{ 0x80, 0x7A, 0xE0 } };
    const c = hue_colors[id % hue_colors.len];
    fillRoundRectGrad(.{ .x = cx - 20, .y = cy - 20, .w = 40, .h = 40 }, 9, mix(c, C_TEXT, 0.3), scale(c, 0.6), if (selected) 1 else 0.75);
    var mono: [1]u8 = .{save_catalog[id].title[0]};
    drawTextCentered(&mono, cx, cy + 8, 22, .{ 0x08, 0x10, 0x08 }, 0.85);
}

fn drawMusic() void {
    drawText(ALBUM, PANEL_X + 8, 166, 24, C_DIM, 1);
    drawRowHighlight(state.track_f);
    for (tracks, 0..) |track, i| {
        const r = rowRect(i);
        const selected = i == state.track_sel;
        if (!selected) drawRowBase(i);
        const playing = if (state.playing) |p| p == i else false;
        const color = if (selected) C_TEXT else C_DIM;
        if (playing) {
            drawEqualizer(r.x + 40, r.y + r.h / 2, if (state.paused) 0 else 1);
        } else {
            var num: TextBuf = .{};
            num.addDigits(i + 1, 1);
            drawTextCentered(num.slice(), r.x + 40, r.y + 37, 24, color, 1);
        }
        drawText(track.title, r.x + 74, r.y + 38, 26, if (playing) C_LIME else color, 1);
        var len: TextBuf = .{};
        addClock(&len, @as(f64, @floatFromInt(track.seconds)) * 1000);
        const lw = textWidth(len.slice(), 22);
        drawText(len.slice(), r.x + r.w - 32 - lw, r.y + 37, 22, color, 1);
    }

    // Now playing and the visualiser along the bottom.
    const p = state.playing orelse return;
    const base_y: f32 = 614;
    const track = tracks[p];
    var line: TextBuf = .{};
    line.add(if (state.paused) "Paused  ·  " else "Now playing  ·  ");
    line.add(track.title);
    drawText(line.slice(), PANEL_X + 8, base_y - 8, 22, C_TEXT, 1);
    var time: TextBuf = .{};
    addClock(&time, state.play_pos_ms);
    time.add(" / ");
    addClock(&time, @as(f64, @floatFromInt(track.seconds)) * 1000);
    const tw = textWidth(time.slice(), 22);
    drawText(time.slice(), PANEL_X + PANEL_W - tw - 8, base_y - 8, 22, C_DIM, 1);
    const progress: f32 = @floatCast(state.play_pos_ms / (@as(f64, @floatFromInt(track.seconds)) * 1000));
    const bar: Rect = .{ .x = PANEL_X + 8, .y = base_y + 8, .w = PANEL_W - 16, .h = 6 };
    fillRoundRect(bar, 3, .{ 0x14, 0x34, 0x16 }, 1);
    fillRoundRect(.{ .x = bar.x, .y = bar.y, .w = @max(bar.h, bar.w * progress), .h = bar.h }, 3, C_GREEN, 1);
    drawVisualiser(PANEL_X + 8, base_y - 40, PANEL_W - 16);
}

fn drawEqualizer(cx: f32, cy: f32, live: f32) void {
    const t: f32 = @floatCast(state.play_pos_ms / 1000);
    for (0..3) |k| {
        const fk: f32 = @floatFromInt(k);
        const h = 8 + live * 14 * (0.5 + 0.5 * @sin(t * (7 + fk * 3) + fk * 2));
        fillRoundRect(.{ .x = cx - 13 + fk * 10, .y = cy + 12 - h, .w = 6, .h = h }, 2, C_LIME, 1);
    }
}

// Bars driven by the beat. The audio output setting decides how they group:
// one block for mono, left and right for stereo, five speakers for surround.
fn drawVisualiser(x: f32, bottom: f32, w: f32) void {
    const groups: usize = switch (state.audio) {
        0 => 1,
        1 => 2,
        else => 5,
    };
    const bars_per_group: usize = 30 / groups;
    const gap: f32 = 18;
    const group_w = (w - gap * @as(f32, @floatFromInt(groups - 1))) / @as(f32, @floatFromInt(groups));
    const bar_w = group_w / @as(f32, @floatFromInt(bars_per_group));
    const t: f32 = @floatCast(state.play_pos_ms / 1000);
    const live: f32 = if (state.paused) 0.15 else 1;
    const beat = beatPulse();
    for (0..groups) |g| {
        const gx = x + @as(f32, @floatFromInt(g)) * (group_w + gap);
        const fg: f32 = @floatFromInt(g);
        for (0..bars_per_group) |b| {
            const fb: f32 = @floatFromInt(b);
            const wave = 0.5 + 0.5 * @sin(t * (3.1 + fb * 0.37) + fb * 0.9 + fg * 1.3) * @sin(t * 1.7 + fb * 0.21 + fg);
            const h = 3 + 22 * live * (0.25 * wave + 0.75 * wave * (0.4 + 0.6 * beat));
            fillRoundRect(.{ .x = gx + fb * bar_w + 1, .y = bottom - h, .w = bar_w - 3, .h = h }, 1.5, mix(C_GREEN, C_LIME, wave), 0.85);
        }
    }
}

fn addClock(out: *TextBuf, ms: f64) void {
    const total: u64 = @intFromFloat(@max(0, ms / 1000));
    out.addDigits(total / 60, 1);
    out.add(":");
    out.addDigits(total % 60, 2);
}

fn drawOnline() void {
    const running = testRunning();
    const lit: f32 = if (running) 0.4 else 1;
    drawCapsule(TEST_BUTTON, lit, 1);
    drawTextCentered("Test Connection", TEST_BUTTON.x + TEST_BUTTON.w / 2, TEST_BUTTON.y + 40, 26, mix(C_TEXT, C_DARK, 0.9 * lit), 1);

    const start = state.test_start_ms orelse {
        drawText("Check this console’s network connection.", PANEL_X + 8, 270, 24, C_DIM, 1);
        return;
    };
    const elapsed = now_ms - start;
    const t: f32 = @floatCast(state.clock_t);
    for (test_steps, 0..) |step, i| {
        const r = rowRect(i + 1);
        const begin = @as(i64, @intCast(i)) * TEST_STEP_MS;
        if (elapsed < begin) break;
        drawRowBase(i + 1);
        const done = elapsed >= begin + TEST_STEP_MS;
        const cx = r.x + 40;
        const cy = r.y + r.h / 2;
        const failed = i == test_steps.len - 1;
        if (!done) {
            drawSpinner(cx, cy, t);
        } else if (failed) {
            strokeSegment(cx - 8, cy - 8, cx + 8, cy + 8, 3.4, .{ 0xF0, 0x5A, 0x4A }, 1);
            strokeSegment(cx - 8, cy + 8, cx + 8, cy - 8, 3.4, .{ 0xF0, 0x5A, 0x4A }, 1);
        } else {
            strokeSegment(cx - 10, cy, cx - 3, cy + 8, 3.4, C_LIME, 1);
            strokeSegment(cx - 3, cy + 8, cx + 11, cy - 9, 3.4, C_LIME, 1);
        }
        drawText(step[0], r.x + 74, r.y + 38, 26, C_TEXT, 1);
        if (done) {
            const vw = textWidth(step[1], 22);
            drawText(step[1], r.x + r.w - 32 - vw, r.y + 37, 22, if (failed) .{ 0xF0, 0x8A, 0x7A } else C_DIM, 1);
        }
    }
    if (!running) {
        drawText("The console is working, but this dashboard has nowhere to connect.", PANEL_X + 8, rowRect(test_steps.len + 1).y + 34, 22, C_DIM, 1);
    }
}

fn drawSpinner(cx: f32, cy: f32, t: f32) void {
    for (0..8) |k| {
        const fk: f32 = @floatFromInt(k);
        const a = fk / 8 * 2 * std.math.pi + t * 5;
        const fade = @mod(fk - t * 5 / (2 * std.math.pi) * 8, 8) / 8;
        fillCircle(cx + @cos(a) * 11, cy + @sin(a) * 11, 2.6, C_LIME, 0.25 + 0.75 * (1 - fade));
    }
}

fn settingValue(s: Setting) []const u8 {
    return switch (s) {
        .glow => glow_values[state.glow],
        .motion => if (state.motion) "On" else "Off",
        .audio => audio_values[state.audio],
        .hints => if (state.hints) "Shown" else "Hidden",
    };
}

fn drawSettings() void {
    drawRowHighlight(state.sys_f);
    const vt: f32 = @floatFromInt(now_ms - state.value_change_ms);
    for (0..SETTING_COUNT) |i| {
        const r = rowRect(i);
        const selected = i == state.sys_sel;
        if (!selected) drawRowBase(i);
        drawText(setting_labels[i], r.x + 32, r.y + 38, 26, if (selected) C_TEXT else C_DIM, 1);
        const value = settingValue(@enumFromInt(i));
        const vw = textWidth(value, 24);
        var dx: f32 = 0;
        var va: f32 = 1;
        if (selected and vt < 260) {
            const e = easeOut(vt / 260);
            dx = state.value_dir * 24 * (1 - e);
            va = e;
        }
        const right = r.x + r.w - 32;
        drawText(value, right - 30 - vw + dx, r.y + 37, 24, if (selected) C_TEXT else C_DIM, va);
        if (selected) {
            drawChevron(right - 6, r.y + r.h / 2, 8, 1, C_LIME, 1);
            drawChevron(right - 30 - vw - 22, r.y + r.h / 2, 8, -1, C_LIME, 1);
        }
    }
}

// ---- Overlays --------------------------------------------------------------------

fn drawConfirm() void {
    const open = state.confirm_open;
    if (open <= 0.001) return;
    darken(0.55 * open);
    if (!state.confirm) return;
    g_alpha = open;
    defer g_alpha = 1;
    const p = confirmPanel();
    fillRoundRectGrad(.{ .x = p.x - 3, .y = p.y - 3, .w = p.w + 6, .h = p.h + 6 }, 27, .{ 0x9C, 0xB8, 0x92 }, .{ 0x2C, 0x40, 0x2A }, 1);
    fillRoundRectGrad(p, 24, .{ 0x10, 0x30, 0x12 }, C_PANEL, 0.98);
    const dev = &state.devices[state.device];
    const info = save_catalog[dev.ids[state.save_sel[state.device]]];
    drawTextCentered("Delete this saved game?", p.x + p.w / 2, p.y + 62, 28, C_TEXT, 1);
    drawTextCentered(info.title, p.x + p.w / 2, p.y + 98, 22, C_DIM, 1);
    const labels = [2][]const u8{ "Yes", "No" };
    for (labels, 0..) |l, i| {
        const r = confirmButtonRect(i);
        const near = std.math.clamp(1 - @abs(state.confirm_f - @as(f32, @floatFromInt(i))), 0, 1);
        drawCapsule(r, near, 1);
        drawTextCentered(l, r.x + r.w / 2, r.y + 39, 26, mix(C_DIM, mix(C_TEXT, C_DARK, 0.9), near), 1);
    }
}

fn drawToast() void {
    const t = state.toast orelse return;
    const age: f32 = @floatFromInt(now_ms - t.start_ms);
    const fade_in = std.math.clamp(age / 180, 0, 1);
    const fade_out = std.math.clamp((@as(f32, @floatFromInt(TOAST_MS)) - age) / 300, 0, 1);
    const alpha = @min(fade_in, fade_out);
    const w = textWidth(t.text, 24) + 64;
    const y = FOOTER_Y - 90 + (1 - easeOut(fade_in)) * 16;
    const r: Rect = .{ .x = PANEL_X + (PANEL_W - w) / 2, .y = y - 28, .w = w, .h = 56 };
    fillRoundRect(r, 28, .{ 0x9C, 0xB8, 0x92 }, 0.6 * alpha);
    fillRoundRect(.{ .x = r.x + 2, .y = r.y + 2, .w = r.w - 4, .h = r.h - 4 }, 26, C_PANEL, 0.96 * alpha);
    drawTextCentered(t.text, r.x + r.w / 2, y + 9, 24, C_TEXT, alpha);
}

fn drawFooter() void {
    var buf: [3]FooterItem = undefined;
    const items = footerItems(&buf);
    for (items, 0..) |item, i| {
        const r = footerItemRect(items, i);
        const bx = r.x + 6 + 17;
        drawBadge(item.badge, bx, FOOTER_Y);
        drawText(item.label, bx + 28, FOOTER_Y + 9, FOOTER_PX, C_DIM, 1);
    }
}

fn drawBadge(badge: Badge, cx: f32, cy: f32) void {
    switch (badge) {
        .a, .b => {
            const c: Color = if (badge == .a) .{ 0x5C, 0xC0, 0x22 } else .{ 0xDA, 0x3E, 0x30 };
            fillCircle(cx, cy, 17, mix(c, C_TEXT, 0.35), 1);
            fillCircle(cx, cy, 15, c, 1);
            fillRoundRect(.{ .x = cx - 10, .y = cy - 12, .w = 20, .h = 9 }, 4.5, .{ 0xFF, 0xFF, 0xFF }, 0.25);
            drawTextCentered(if (badge == .a) "A" else "B", cx, cy + 7.5, 20, .{ 0xFF, 0xFF, 0xFF }, 1);
        },
        .lr => {
            fillCircle(cx, cy, 17, .{ 0x9C, 0xB8, 0x92 }, 1);
            fillCircle(cx, cy, 15, .{ 0x1A, 0x2C, 0x1A }, 1);
            drawChevron(cx - 4.5, cy, 5, -1, C_TEXT, 1);
            drawChevron(cx + 4.5, cy, 5, 1, C_TEXT, 1);
        },
    }
}

fn drawChevron(cx: f32, cy: f32, size: f32, dir: f32, c: Color, alpha: f32) void {
    strokeSegment(cx - dir * size * 0.5, cy - size, cx + dir * size * 0.5, cy, 2.6, c, alpha);
    strokeSegment(cx + dir * size * 0.5, cy, cx - dir * size * 0.5, cy + size, 2.6, c, alpha);
}

// ---- Number formatting -----------------------------------------------------------

const TextBuf = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    fn add(self: *TextBuf, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn addDigits(self: *TextBuf, value: u64, min_digits: usize) void {
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        var v = value;
        while (v > 0 or n < min_digits) : (n += 1) {
            tmp[tmp.len - 1 - n] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
        self.add(tmp[tmp.len - n ..]);
    }

    fn slice(self: *const TextBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn addThousands(out: *TextBuf, value: u32) void {
    if (value >= 1000) {
        out.addDigits(value / 1000, 1);
        out.add(",");
        out.addDigits(value % 1000, 3);
    } else {
        out.addDigits(value, 1);
    }
}

// ---- Glyphs ----------------------------------------------------------------------
// Only the glyphs the dashboard can draw are copied out of the font.

const Glyph = struct { codepoint: u21, advance: f32, path: []const u8, index: usize };

const glyph_text = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ,.:/·’?";

const glyph_codepoints = blk: {
    @setEvalBranchQuota(200_000);
    var list: []const u21 = &.{};
    var it = std.unicode.Utf8View.initComptime(glyph_text).iterator();
    while (it.nextCodepoint()) |cp| list = list ++ [_]u21{cp};
    break :blk list[0..list.len].*;
};

const glyphs = blk: {
    @setEvalBranchQuota(200_000);
    var list: [glyph_codepoints.len]Glyph = undefined;
    for (glyph_codepoints, 0..) |cp, i| {
        const index = font.glyphIndex(cp) orelse @compileError("missing glyph");
        list[i] = .{ .codepoint = cp, .advance = font.advances[index], .path = font.glyph_paths[index], .index = index };
    }
    break :blk list;
};

fn glyphFor(cp: u21) ?*const Glyph {
    for (&glyphs) |*g| {
        if (g.codepoint == cp) return g;
    }
    return null;
}

fn textWidth(text: []const u8, size_px: f32) f32 {
    var width: f32 = 0;
    var prev: ?*const Glyph = null;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        const g = glyphFor(cp) orelse continue;
        if (prev) |p| width += @floatFromInt(font.kerning(p.index, g.index));
        width += g.advance;
        prev = g;
    }
    return width * size_px / font.UNITS_PER_EM;
}

fn drawText(text: []const u8, left: f32, baseline: f32, size_px: f32, c: Color, alpha: f32) void {
    const k = size_px / font.UNITS_PER_EM;
    var x = left;
    var prev: ?*const Glyph = null;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        const g = glyphFor(cp) orelse continue;
        if (prev) |p| x += @as(f32, @floatFromInt(font.kerning(p.index, g.index))) * k;
        if (g.path.len > 0) fillGlyph(g.path, x, baseline, k, c, alpha);
        x += g.advance * k;
        prev = g;
    }
}

fn drawTextCentered(text: []const u8, cx: f32, baseline: f32, size_px: f32, c: Color, alpha: f32) void {
    drawText(text, @round(cx - textWidth(text, size_px) / 2), baseline, size_px, c, alpha);
}

// ---- Rasterizer ------------------------------------------------------------------
// Glyph outlines and polygons are flattened to lines and accumulated as signed
// area per pixel, which gives exact coverage for the nonzero fill rule.

const ACC_W: usize = 320;
const ACC_H: usize = 320;
var acc: [ACC_W * ACC_H]f32 = undefined;

const Pt = struct { x: f32, y: f32 };

const Raster = struct {
    left: f32,
    top: f32,
    w: usize,
    h: usize,

    fn begin(min_x: f32, min_y: f32, max_x: f32, max_y: f32) ?Raster {
        if (!(min_x <= max_x) or !(min_y <= max_y)) return null;
        const left = @floor(min_x) - 1;
        const top = @floor(min_y) - 1;
        const w: usize = @min(ACC_W - 2, @as(usize, @intFromFloat(@ceil(max_x) + 1 - left)));
        const h: usize = @min(ACC_H, @as(usize, @intFromFloat(@ceil(max_y) + 1 - top)));
        for (0..h) |y| @memset(acc[y * ACC_W ..][0 .. w + 2], 0);
        return .{ .left = left, .top = top, .w = w, .h = h };
    }

    fn line(self: *Raster, a: Pt, b: Pt) void {
        accumulateLine(.{ .x = a.x - self.left, .y = a.y - self.top }, .{ .x = b.x - self.left, .y = b.y - self.top }, self.w, self.h);
    }

    fn finish(self: *const Raster, c: Color, alpha: f32) void {
        const left_i: i32 = @intFromFloat(self.left);
        const top_i: i32 = @intFromFloat(self.top);
        for (0..self.h) |y| {
            var sum: f32 = 0;
            for (0..self.w) |x| {
                sum += acc[y * ACC_W + x];
                const coverage = @min(1, @abs(sum));
                if (coverage > 0.002) blend(left_i + @as(i32, @intCast(x)), top_i + @as(i32, @intCast(y)), c, coverage * alpha);
            }
        }
    }
};

fn fillPoly(pts: []const Pt, c: Color, alpha: f32) void {
    var min_x = pts[0].x;
    var max_x = pts[0].x;
    var min_y = pts[0].y;
    var max_y = pts[0].y;
    for (pts[1..]) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    }
    var r = Raster.begin(min_x, min_y, max_x, max_y) orelse return;
    for (pts, 0..) |p, i| r.line(p, pts[(i + 1) % pts.len]);
    r.finish(c, alpha);
}

const PathReader = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSpace(self: *PathReader) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == ',')) self.i += 1;
    }

    fn command(self: *PathReader) ?u8 {
        self.skipSpace();
        if (self.i >= self.s.len) return null;
        const ch = self.s[self.i];
        self.i += 1;
        return ch;
    }

    fn number(self: *PathReader) f32 {
        self.skipSpace();
        var negative = false;
        if (self.i < self.s.len and self.s[self.i] == '-') {
            negative = true;
            self.i += 1;
        }
        var value: f32 = 0;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') : (self.i += 1) {
            value = value * 10 + @as(f32, @floatFromInt(self.s[self.i] - '0'));
        }
        if (self.i < self.s.len and self.s[self.i] == '.') {
            self.i += 1;
            var place: f32 = 0.1;
            while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') : (self.i += 1) {
                value += place * @as(f32, @floatFromInt(self.s[self.i] - '0'));
                place *= 0.1;
            }
        }
        return if (negative) -value else value;
    }

    fn point(self: *PathReader) Pt {
        const x = self.number();
        return .{ .x = x, .y = self.number() };
    }
};

const Transform = struct {
    ox: f32,
    oy: f32,
    k: f32,
    fn apply(self: Transform, p: Pt) Pt {
        return .{ .x = p.x * self.k + self.ox, .y = p.y * self.k + self.oy };
    }
};

const Bounds = struct {
    min_x: f32 = std.math.inf(f32),
    min_y: f32 = std.math.inf(f32),
    max_x: f32 = -std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),

    fn line(self: *Bounds, a: Pt, b: Pt) void {
        _ = b;
        self.min_x = @min(self.min_x, a.x);
        self.max_x = @max(self.max_x, a.x);
        self.min_y = @min(self.min_y, a.y);
        self.max_y = @max(self.max_y, a.y);
    }
};

fn walkPath(path: []const u8, xf: Transform, sink: anytype) void {
    var r: PathReader = .{ .s = path };
    var start: Pt = .{ .x = 0, .y = 0 };
    var cur = start;
    while (r.command()) |cmd| {
        switch (cmd) {
            'M' => {
                if (cur.x != start.x or cur.y != start.y) sink.line(xf.apply(cur), xf.apply(start));
                start = r.point();
                cur = start;
            },
            'L' => {
                const p = r.point();
                sink.line(xf.apply(cur), xf.apply(p));
                cur = p;
            },
            'Q' => {
                const c = r.point();
                const p = r.point();
                const steps = 6;
                var prev = cur;
                for (1..steps + 1) |s| {
                    const t = @as(f32, @floatFromInt(s)) / steps;
                    const u = 1 - t;
                    const q: Pt = .{
                        .x = u * u * cur.x + 2 * u * t * c.x + t * t * p.x,
                        .y = u * u * cur.y + 2 * u * t * c.y + t * t * p.y,
                    };
                    sink.line(xf.apply(prev), xf.apply(q));
                    prev = q;
                }
                cur = p;
            },
            'Z' => {
                sink.line(xf.apply(cur), xf.apply(start));
                cur = start;
            },
            else => return,
        }
    }
    if (cur.x != start.x or cur.y != start.y) sink.line(xf.apply(cur), xf.apply(start));
}

fn fillGlyph(path: []const u8, origin_x: f32, origin_y: f32, k: f32, c: Color, alpha: f32) void {
    const xf: Transform = .{ .ox = origin_x, .oy = origin_y, .k = k };
    var bounds: Bounds = .{};
    walkPath(path, xf, &bounds);
    var r = Raster.begin(bounds.min_x, bounds.min_y, bounds.max_x, bounds.max_y) orelse return;
    walkPath(path, xf, &r);
    r.finish(c, alpha);
}

fn accumulateLine(a: Pt, b: Pt, w: usize, h: usize) void {
    if (a.y == b.y) return;
    const dir: f32 = if (a.y < b.y) 1 else -1;
    const p0 = if (a.y < b.y) a else b;
    const p1 = if (a.y < b.y) b else a;
    const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
    var x = p0.x;
    const y_start: usize = @intFromFloat(@max(0, @floor(p0.y)));
    const y_end: usize = @min(h, @as(usize, @intFromFloat(@max(0, @ceil(p1.y)))));
    if (p0.y < 0) x -= p0.y * dxdy;
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const row = y * ACC_W;
        const fy: f32 = @floatFromInt(y);
        const dy = @min(fy + 1, p1.y) - @max(fy, p0.y);
        const xnext = x + dxdy * dy;
        const d = dy * dir;
        const x0 = @max(0, @min(x, xnext));
        const x1 = @min(@as(f32, @floatFromInt(w)), @max(x, xnext));
        const x0floor = @floor(x0);
        const x0i: usize = @intFromFloat(x0floor);
        const x1ceil = @ceil(x1);
        const x1i: usize = @intFromFloat(x1ceil);
        if (x1i <= x0i + 1) {
            const xmf = 0.5 * (x + xnext) - x0floor;
            acc[row + x0i] += d - d * xmf;
            acc[row + x0i + 1] += d * xmf;
        } else {
            const s = 1 / (x1 - x0);
            const x0f = x0 - x0floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = x1 - x1ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            acc[row + x0i] += d * a0;
            if (x1i == x0i + 2) {
                acc[row + x0i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                acc[row + x0i + 1] += d * (a1 - a0);
                var xi = x0i + 2;
                while (xi < x1i - 1) : (xi += 1) acc[row + xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                acc[row + x1i - 1] += d * (1 - a2 - am);
            }
            acc[row + x1i] += d * am;
        }
        x = xnext;
    }
}

// ---- Shapes ----------------------------------------------------------------------

// Content drawn during a screen transition fades and slides by these.
var g_alpha: f32 = 1;
var g_dx: i32 = 0;

const Span = struct { x0: i32, x1: i32, y0: i32, y1: i32 };

fn spanOf(x0: f32, y0: f32, x1: f32, y1: f32) Span {
    return .{
        .x0 = @intFromFloat(std.math.clamp(@floor(x0), -64, WF + 64)),
        .x1 = @intFromFloat(std.math.clamp(@ceil(x1), -64, WF + 64)),
        .y0 = @intFromFloat(std.math.clamp(@floor(y0), 0, HF)),
        .y1 = @intFromFloat(std.math.clamp(@ceil(y1), 0, HF)),
    };
}

// Darkens the whole frame towards black.
fn darken(amount: f32) void {
    const keep: u32 = @intFromFloat(std.math.clamp(@round((1 - amount) * 256), 0, 256));
    const px = output_buf[ktx.HEADER_SIZE..];
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i + 0] = @intCast((@as(u32, px[i + 0]) * keep) >> 8);
        px[i + 1] = @intCast((@as(u32, px[i + 1]) * keep) >> 8);
        px[i + 2] = @intCast((@as(u32, px[i + 2]) * keep) >> 8);
    }
}

fn roundRectCoverage(r: Rect, radius: f32, px: f32, py: f32) f32 {
    const rad = @max(radius, 0.5);
    const hx = r.w * 0.5 - rad;
    const hy = r.h * 0.5 - rad;
    const qx = @max(@abs(px - (r.x + r.w * 0.5)) - hx, 0);
    const qy = @max(@abs(py - (r.y + r.h * 0.5)) - hy, 0);
    return std.math.clamp(rad + 0.5 - @sqrt(qx * qx + qy * qy), 0, 1);
}

fn fillRoundRect(r: Rect, radius: f32, c: Color, alpha: f32) void {
    fillRoundRectGrad(r, radius, c, c, alpha);
}

fn fillRoundRectGrad(r: Rect, radius: f32, top: Color, bottom: Color, alpha: f32) void {
    const s = spanOf(r.x, r.y, r.x + r.w, r.y + r.h);
    var y = s.y0;
    while (y < s.y1) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const c = mix(top, bottom, std.math.clamp((fy - r.y) / r.h, 0, 1));
        var x = s.x0;
        while (x < s.x1) : (x += 1) {
            const cov = roundRectCoverage(r, radius, @as(f32, @floatFromInt(x)) + 0.5, fy);
            if (cov > 0) blend(x, y, c, cov * alpha);
        }
    }
}

fn fillCircle(cx: f32, cy: f32, r: f32, c: Color, alpha: f32) void {
    const s = spanOf(cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1);
    var y = s.y0;
    while (y < s.y1) : (y += 1) {
        var x = s.x0;
        while (x < s.x1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const cov = std.math.clamp(r + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
            if (cov > 0) blend(x, y, c, cov * alpha);
        }
    }
}

fn strokeRing(cx: f32, cy: f32, r: f32, width: f32, c: Color, alpha: f32) void {
    const o = r + width;
    const s = spanOf(cx - o, cy - o, cx + o, cy + o);
    var y = s.y0;
    while (y < s.y1) : (y += 1) {
        var x = s.x0;
        while (x < s.x1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @abs(@sqrt(dx * dx + dy * dy) - r);
            const cov = std.math.clamp(width * 0.5 + 0.5 - d, 0, 1);
            if (cov > 0) blend(x, y, c, cov * alpha);
        }
    }
}

fn strokeSegment(ax: f32, ay: f32, bx: f32, by: f32, width: f32, c: Color, alpha: f32) void {
    const pad = width;
    const s = spanOf(@min(ax, bx) - pad, @min(ay, by) - pad, @max(ax, bx) + pad, @max(ay, by) + pad);
    const vx = bx - ax;
    const vy = by - ay;
    const len2 = @max(vx * vx + vy * vy, 1e-6);
    var y = s.y0;
    while (y < s.y1) : (y += 1) {
        var x = s.x0;
        while (x < s.x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - ax;
            const py = @as(f32, @floatFromInt(y)) + 0.5 - ay;
            const t = std.math.clamp((px * vx + py * vy) / len2, 0, 1);
            const dx = px - vx * t;
            const dy = py - vy * t;
            const cov = std.math.clamp(width * 0.5 + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
            if (cov > 0) blend(x, y, c, cov * alpha);
        }
    }
}

// Adds light with a smooth elliptical falloff.
fn addGlow(cx: f32, cy: f32, rx: f32, ry: f32, c: Color, strength: f32) void {
    if (strength <= 0 or rx <= 0 or ry <= 0) return;
    const s = spanOf(cx - rx, cy - ry, cx + rx, cy + ry);
    var y = s.y0;
    while (y < s.y1) : (y += 1) {
        const dy = (@as(f32, @floatFromInt(y)) + 0.5 - cy) / ry;
        const dy2 = dy * dy;
        if (dy2 >= 1) continue;
        var x = s.x0;
        while (x < s.x1) : (x += 1) {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5 - cx) / rx;
            const d2 = dx * dx + dy2;
            if (d2 >= 1) continue;
            const f = (1 - d2) * (1 - d2);
            addPixel(x, y, c, strength * f);
        }
    }
}

inline fn pixelIndex(x: i32, y: i32) ?usize {
    const xx = x + g_dx;
    if (xx < 0 or y < 0 or xx >= W or y >= H) return null;
    return ktx.HEADER_SIZE + (@as(usize, @intCast(y)) * W + @as(usize, @intCast(xx))) * 4;
}

// Blending works in 8.8 fixed point; it runs for nearly every pixel drawn.
fn blend(x: i32, y: i32, c: Color, coverage: f32) void {
    const a = coverage * g_alpha;
    if (a <= 0.002) return;
    const idx = pixelIndex(x, y) orelse return;
    if (a >= 0.998) {
        output_buf[idx..][0..3].* = c;
        return;
    }
    const k: i32 = @intFromFloat(a * 256 + 0.5);
    inline for (0..3) |i| {
        const dst: i32 = output_buf[idx + i];
        output_buf[idx + i] = @intCast(dst + (((@as(i32, c[i]) - dst) * k + 128) >> 8));
    }
}

fn addPixel(x: i32, y: i32, c: Color, amount: f32) void {
    const a = amount * g_alpha;
    if (a <= 0.002) return;
    const idx = pixelIndex(x, y) orelse return;
    const k: u32 = @intFromFloat(@min(a, 4) * 256 + 0.5);
    inline for (0..3) |i| {
        const v = @as(u32, output_buf[idx + i]) + ((@as(u32, c[i]) * k + 128) >> 8);
        output_buf[idx + i] = @intCast(@min(255, v));
    }
}

// ---- Tests -----------------------------------------------------------------------

fn resetForTest() void {
    state = .{};
    phase = .ready;
    now_ms = 0;
    last_update_ms = 0;
    committed_at_ms = 0;
}

fn keyUpdate(key: i32) void {
    begin_update_at(committed_at_ms + 16);
    _ = key_event(key, FLAG_KEY_DOWN);
    _ = finish_update();
}

fn idle(ms: i64) void {
    const end = committed_at_ms + ms;
    while (committed_at_ms < end) {
        begin_update_at(committed_at_ms + 16);
        _ = finish_update();
    }
}

test "every label has its glyphs" {
    const labels = section_labels ++ setting_labels ++ glow_values ++ audio_values;
    for (labels) |s| {
        var it = (try std.unicode.Utf8View.init(s)).iterator();
        while (it.nextCodepoint()) |cp| try std.testing.expect(glyphFor(cp) != null);
    }
    for (save_catalog) |s| {
        for (s.title) |ch| try std.testing.expect(glyphFor(ch) != null);
    }
}

test "deleting a save asks first and frees its blocks" {
    resetForTest();
    keyUpdate(XK_RETURN); // Memory
    try std.testing.expect(state.in_section);
    keyUpdate(XK_RIGHT); // Memory Unit A
    const free_before = state.devices[1].freeBlocks();
    keyUpdate(XK_DOWN); // Mirefall
    keyUpdate(XK_RETURN);
    try std.testing.expect(state.confirm);
    keyUpdate(XK_RETURN); // "No" is the default
    try std.testing.expectEqual(@as(u8, 2), state.devices[1].len);
    keyUpdate(XK_RETURN);
    keyUpdate(XK_LEFT);
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(@as(u8, 1), state.devices[1].len);
    try std.testing.expectEqual(free_before + 140, state.devices[1].freeBlocks());
    try std.testing.expectEqual(@as(u8, 0), state.save_sel[1]);
}

test "music plays, pauses and moves on to the next track" {
    resetForTest();
    keyUpdate(XK_DOWN);
    keyUpdate(XK_RETURN); // Music
    keyUpdate(XK_DOWN);
    keyUpdate(XK_DOWN);
    keyUpdate(XK_DOWN); // Low Orbit
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(@as(?u8, 3), state.playing);
    idle(1000);
    try std.testing.expect(state.play_pos_ms > 900);
    keyUpdate(XK_RETURN); // Pause
    const pos = state.play_pos_ms;
    idle(1000);
    try std.testing.expectEqual(pos, state.play_pos_ms);
    keyUpdate(XK_RETURN); // Resume
    state.play_pos_ms = 176_000 - 10;
    idle(64);
    try std.testing.expectEqual(@as(?u8, 4), state.playing);
}

test "the dashboard stops asking for frames once still" {
    resetForTest();
    keyUpdate(XK_DOWN);
    keyUpdate(XK_DOWN);
    keyUpdate(XK_DOWN);
    keyUpdate(XK_RETURN); // Settings
    keyUpdate(XK_DOWN); // Background Motion
    keyUpdate(XK_RIGHT);
    try std.testing.expect(!state.motion);
    idle(1000);
    begin_update_at(committed_at_ms + 16);
    try std.testing.expectEqual(now_ms, finish_update());
}

test "the connection test finishes after its steps" {
    resetForTest();
    keyUpdate(XK_DOWN);
    keyUpdate(XK_DOWN);
    keyUpdate(XK_RETURN); // Online
    keyUpdate(XK_RETURN);
    try std.testing.expect(testRunning());
    idle(TEST_STEP_MS * test_steps.len + 16);
    try std.testing.expect(!testRunning());
}
