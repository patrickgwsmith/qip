const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const XK_RETURN: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;

const C_WHITE: [4]u8 = .{ 0xE8, 0xF5, 0xFF, 0xFF };
const C_TEXT: [4]u8 = .{ 0xC4, 0xE0, 0xF8, 0xFF };
const C_TEXT_DIM: [4]u8 = .{ 0x83, 0xA8, 0xD0, 0xFF };

const MAIN_LEFT_X: i32 = 44;
const MAIN_TOP_Y: i32 = 64;
const MAIN_ROW_W: i32 = 230;
const MAIN_ROW_H: i32 = 34;
const MAIN_ROW_GAP: i32 = 15;

const PANEL_X: i32 = 28;
const PANEL_Y: i32 = 30;
const PANEL_W: i32 = 264;
const PANEL_H: i32 = 166;

const Mode = enum(u8) {
    main,
    browser,
    system_config,
};

const MainChoice = enum(u8) {
    browser,
    system_config,
};

const SystemItem = enum(u8) {
    language,
    clock,
    date,
    video_out,
    dvd_mode,
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var initialized: bool = false;
var needs_redraw: bool = true;

var mode: Mode = .main;
var main_choice: MainChoice = .browser;
var browser_selection: i32 = 0;
var browser_flash: i32 = 0;
var system_selection: i32 = 0;

var language_idx: i32 = 0;
var clock_idx: i32 = 0;
var date_idx: i32 = 0;
var video_idx: i32 = 0;
var dvd_idx: i32 = 0;

var pulse: i32 = 0;
var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;
var last_frame_index: i64 = 0;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var next_wake_at_ms: i64 = 0;

const browser_items = [_][]const u8{
    "MEMORY CARD (PS2) SLOT 1",
    "MEMORY CARD (PS2) SLOT 2",
    "DISC",
};

const browser_subtitles = [_][]const u8{
    "8MB FREE",
    "NO DATA",
    "PLAYSTATION 2 FORMAT DISC",
};

const system_items = [_][]const u8{
    "LANGUAGE",
    "CLOCK ADJUST",
    "DATE FORMAT",
    "COMPONENT VIDEO OUT",
    "DVD PLAYER",
};

const language_values = [_][]const u8{ "ENGLISH", "FRANCAIS", "DEUTSCH", "ESPANOL", "ITALIANO" };
const clock_values = [_][]const u8{ "24 HOUR", "12 HOUR" };
const date_values = [_][]const u8{ "DD/MM/YYYY", "MM/DD/YYYY", "YYYY/MM/DD" };
const video_values = [_][]const u8{ "Y Cb/Pb Cr/Pr", "RGB" };
const dvd_values = [_][]const u8{ "NORMAL", "WIDE", "FULL" };

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

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
    if (transaction_phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    next_wake_at_ms = now_ms;
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (mode) {
        .main => switch (x11_key) {
            XK_UP, XK_LEFT, 'w', 'W', 'a', 'A' => stepMainChoice(-1),
            XK_DOWN, XK_RIGHT, 's', 'S', 'd', 'D' => stepMainChoice(1),
            XK_RETURN, ' ', 'x', 'X' => openMainChoice(),
            else => return 0,
        },
        .browser => switch (x11_key) {
            XK_UP, 'w', 'W' => stepBrowser(-1),
            XK_DOWN, 's', 'S' => stepBrowser(1),
            XK_RETURN, ' ', 'x', 'X' => browser_flash = 18,
            XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => closePanel(),
            else => return 0,
        },
        .system_config => switch (x11_key) {
            XK_UP, 'w', 'W' => stepSystemSelection(-1),
            XK_DOWN, 's', 'S' => stepSystemSelection(1),
            XK_LEFT, 'a', 'A' => adjustCurrentSystemValue(-1),
            XK_RIGHT, 'd', 'D' => adjustCurrentSystemValue(1),
            XK_RETURN, ' ', 'x', 'X' => adjustCurrentSystemValue(1),
            XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => closePanel(),
            else => return 0,
        },
    }

    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    ensureInit();
    pointer_x = x_px;
    pointer_y = y_px;

    const down = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;

    switch (mode) {
        .main => {
            if (mainChoiceAt(x_px, y_px)) |choice| {
                main_choice = choice;
                needs_redraw = true;
                if (down and !primary_down) {
                    openMainChoice();
                    needs_redraw = true;
                }
            }
        },
        .browser => {
            if (down and !primary_down) {
                if (panelBackAt(x_px, y_px)) {
                    closePanel();
                } else if (browserRowAt(x_px, y_px)) |idx| {
                    browser_selection = idx;
                    browser_flash = 18;
                }
                needs_redraw = true;
            } else if (browserRowAt(x_px, y_px)) |idx| {
                if (browser_selection != idx) {
                    browser_selection = idx;
                    needs_redraw = true;
                }
            }
        },
        .system_config => {
            if (down and !primary_down) {
                if (panelBackAt(x_px, y_px)) {
                    closePanel();
                } else if (systemRowAt(x_px, y_px)) |idx| {
                    system_selection = idx;
                    if (valueAreaAt(x_px, y_px)) |direction| {
                        adjustCurrentSystemValue(direction);
                    }
                }
                needs_redraw = true;
            } else if (systemRowAt(x_px, y_px)) |idx| {
                if (system_selection != idx) {
                    system_selection = idx;
                    needs_redraw = true;
                }
            }
        },
    }

    if (secondary and !secondary_down and mode != .main) {
        closePanel();
        needs_redraw = true;
    }

    primary_down = down;
    secondary_down = secondary;
    return if (needs_redraw) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    ensureInit();
    const frame_index = @divTrunc(begun_at_ms, 16);
    pulse = @intCast(@mod(frame_index, 4096));
    if (browser_flash > 0 and frame_index > last_frame_index) {
        const elapsed = @min(frame_index - last_frame_index, @as(i64, browser_flash));
        browser_flash -= @intCast(elapsed);
    }
    last_frame_index = frame_index;
    needs_redraw = true;
    next_wake_at_ms = if (begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    ensureInit();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    transaction_phase = .ready;
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

export fn finish_update() i64 {
    if (transaction_phase != .updating) @trap();
    advanceTransactionTime();
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn ensureInit() void {
    if (initialized) return;
    resetState();
    initialized = true;
}

fn resetState() void {
    mode = .main;
    main_choice = .browser;
    browser_selection = 0;
    browser_flash = 0;
    system_selection = 0;
    language_idx = 0;
    clock_idx = 0;
    date_idx = 0;
    video_idx = 0;
    dvd_idx = 0;
    pulse = 0;
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    needs_redraw = true;
    last_frame_index = 0;
}

fn mainChoiceLabel(choice: MainChoice) []const u8 {
    return switch (choice) {
        .browser => "BROWSER",
        .system_config => "SYSTEM CONFIGURATION",
    };
}

fn openMainChoice() void {
    mode = switch (main_choice) {
        .browser => .browser,
        .system_config => .system_config,
    };
}

fn closePanel() void {
    mode = .main;
}

fn stepMainChoice(delta: i32) void {
    const current = @as(i32, @intFromEnum(main_choice));
    const next = @mod(current + delta + 2, 2);
    main_choice = @as(MainChoice, @enumFromInt(@as(u8, @intCast(next))));
}

fn stepBrowser(delta: i32) void {
    browser_selection = @mod(browser_selection + delta + @as(i32, @intCast(browser_items.len)), @as(i32, @intCast(browser_items.len)));
}

fn stepSystemSelection(delta: i32) void {
    system_selection = @mod(system_selection + delta + @as(i32, @intCast(system_items.len)), @as(i32, @intCast(system_items.len)));
}

fn adjustCurrentSystemValue(delta: i32) void {
    const item = @as(SystemItem, @enumFromInt(@as(u8, @intCast(system_selection))));
    switch (item) {
        .language => language_idx = stepBounded(language_idx, delta, @as(i32, @intCast(language_values.len))),
        .clock => clock_idx = stepBounded(clock_idx, delta, @as(i32, @intCast(clock_values.len))),
        .date => date_idx = stepBounded(date_idx, delta, @as(i32, @intCast(date_values.len))),
        .video_out => video_idx = stepBounded(video_idx, delta, @as(i32, @intCast(video_values.len))),
        .dvd_mode => dvd_idx = stepBounded(dvd_idx, delta, @as(i32, @intCast(dvd_values.len))),
    }
}

fn stepBounded(current: i32, delta: i32, count: i32) i32 {
    return @mod(current + delta + count, count);
}

fn systemValueLabel(index: i32) []const u8 {
    const item = @as(SystemItem, @enumFromInt(@as(u8, @intCast(index))));
    return switch (item) {
        .language => language_values[@as(usize, @intCast(language_idx))],
        .clock => clock_values[@as(usize, @intCast(clock_idx))],
        .date => date_values[@as(usize, @intCast(date_idx))],
        .video_out => video_values[@as(usize, @intCast(video_idx))],
        .dvd_mode => dvd_values[@as(usize, @intCast(dvd_idx))],
    };
}

fn mainChoiceAt(x: i32, y: i32) ?MainChoice {
    var i: i32 = 0;
    while (i < 2) : (i += 1) {
        const row = Rect{
            .x = MAIN_LEFT_X,
            .y = MAIN_TOP_Y + i * (MAIN_ROW_H + MAIN_ROW_GAP),
            .w = MAIN_ROW_W,
            .h = MAIN_ROW_H,
        };
        if (pointInRect(x, y, row)) {
            return @as(MainChoice, @enumFromInt(@as(u8, @intCast(i))));
        }
    }
    return null;
}

fn browserRowAt(x: i32, y: i32) ?i32 {
    var i: i32 = 0;
    while (i < @as(i32, @intCast(browser_items.len))) : (i += 1) {
        const row = Rect{
            .x = PANEL_X + 18,
            .y = PANEL_Y + 33 + i * 34,
            .w = PANEL_W - 36,
            .h = 28,
        };
        if (pointInRect(x, y, row)) return i;
    }
    return null;
}

fn systemRowAt(x: i32, y: i32) ?i32 {
    var i: i32 = 0;
    while (i < @as(i32, @intCast(system_items.len))) : (i += 1) {
        const row = Rect{
            .x = PANEL_X + 14,
            .y = PANEL_Y + 30 + i * 25,
            .w = PANEL_W - 28,
            .h = 21,
        };
        if (pointInRect(x, y, row)) return i;
    }
    return null;
}

fn valueAreaAt(x: i32, y: i32) ?i32 {
    const row = PANEL_Y + 30 + system_selection * 25;
    const left = Rect{ .x = PANEL_X + 170, .y = row + 2, .w = 8, .h = 17 };
    const right = Rect{ .x = PANEL_X + PANEL_W - 22, .y = row + 2, .w = 8, .h = 17 };
    if (pointInRect(x, y, left)) return -1;
    if (pointInRect(x, y, right)) return 1;
    return null;
}

fn panelBackAt(x: i32, y: i32) bool {
    return pointInRect(x, y, .{ .x = PANEL_X + PANEL_W - 52, .y = PANEL_Y + PANEL_H - 18, .w = 40, .h = 12 });
}

fn drawFrame() void {
    drawBackground();
    drawTopBrand();
    switch (mode) {
        .main => drawMainMenu(),
        .browser => drawBrowserPanel(),
        .system_config => drawSystemPanel(),
    }
    drawBottomHelp();
}

fn drawBackground() void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        const grad = @divTrunc(y * 74, @as(i32, @intCast(RENDER_H)));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 1) {
            const wave_x = ((x * 5 + pulse) & 63) - 31;
            const wave_y = ((y * 3 - @divTrunc(pulse, 2)) & 63) - 31;
            const b = clampU8(46, grad + @divTrunc(wave_x, 4));
            const g = clampU8(16, @divTrunc(grad, 3) + @divTrunc(wave_y, 9));
            const r = clampU8(2, @divTrunc(wave_x + wave_y, 24));
            setPixelI32(x, y, .{ r, g, b, 0xFF });
        }
    }

    var column: i32 = 0;
    while (column < 5) : (column += 1) {
        const cx = 34 + column * 62 + @divTrunc((((pulse + column * 73) & 255) - 127), 16);
        const alpha = @as(u8, @intCast(36 + ((pulse + column * 43) & 31)));
        blendRectI32(cx, 8, 2, @as(i32, @intCast(RENDER_H - 16)), .{ 0x90, 0xC0, 0xFF, alpha });
    }

    drawEnergyOrb(82, 96, 31, .{ 0x8E, 0xCC, 0xFF, 0x52 });
    drawEnergyOrb(240, 54, 22, .{ 0x74, 0xB4, 0xF6, 0x45 });
    drawEnergyOrb(274, 168, 27, .{ 0x68, 0xAA, 0xEE, 0x38 });
}

fn drawEnergyOrb(cx: i32, cy: i32, radius: i32, color: [4]u8) void {
    var y = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const d2 = dx * dx + dy * dy;
            if (d2 > radius * radius) continue;
            const shell = radius * radius - d2;
            const a = @as(i32, color[3]) + @divTrunc(shell, @max(1, radius));
            blendPixelI32(x, y, .{ color[0], color[1], color[2], @as(u8, @intCast(clampI32(a, 0, 150))) });
        }
    }
}

fn drawTopBrand() void {
    blendRectI32(0, 0, @as(i32, @intCast(RENDER_W)), 20, .{ 0x04, 0x14, 0x2A, 0xC8 });
    drawTextScaled(9, 7, "PLAYSTATION 2", C_WHITE, 2);
    if (mode == .main) {
        drawTextScaled(220, 7, "BROWSER", if (main_choice == .browser) C_TEXT else C_TEXT_DIM, 1);
        drawTextScaled(258, 7, "SYSTEM", if (main_choice == .system_config) C_TEXT else C_TEXT_DIM, 1);
    } else if (mode == .browser) {
        drawTextScaled(256, 7, "BROWSER", C_TEXT, 1);
    } else {
        drawTextScaled(252, 7, "SYSTEM", C_TEXT, 1);
    }
}

fn drawMainMenu() void {
    var i: i32 = 0;
    while (i < 2) : (i += 1) {
        const row_y = MAIN_TOP_Y + i * (MAIN_ROW_H + MAIN_ROW_GAP);
        const choice = @as(MainChoice, @enumFromInt(@as(u8, @intCast(i))));
        const selected = choice == main_choice;
        const glow = @as(i32, @intCast(((pulse + i * 147) & 127)));
        const alpha = if (selected) 120 + @divTrunc(glow, 2) else 56;
        blendRoundedRect(MAIN_LEFT_X, row_y, MAIN_ROW_W, MAIN_ROW_H, 7, .{ 0x84, 0xB8, 0xF0, @as(u8, @intCast(alpha)) });
        drawRoundedRectOutline(MAIN_LEFT_X, row_y, MAIN_ROW_W, MAIN_ROW_H, 7, if (selected) .{ 0xD8, 0xED, 0xFF, 0xFF } else .{ 0x67, 0x93, 0xC0, 0xFF });

        drawMenuGlyph(choice, MAIN_LEFT_X + 13, row_y + 8);
        drawTextScaled(MAIN_LEFT_X + 34, row_y + 12, mainChoiceLabel(choice), if (selected) C_WHITE else C_TEXT, 2);
    }

    drawTextScaled(74, 176, "X ENTER", C_TEXT_DIM, 2);
    drawTextScaled(160, 176, "O BACK", C_TEXT_DIM, 2);
}

fn drawMenuGlyph(choice: MainChoice, x: i32, y: i32) void {
    if (choice == .browser) {
        drawRect(x, y, 14, 10, .{ 0xE2, 0xF3, 0xFF, 0xFF });
        drawLine(x + 7, y, x + 7, y + 9, .{ 0xE2, 0xF3, 0xFF, 0xFF });
        drawLine(x, y + 4, x + 13, y + 4, .{ 0xE2, 0xF3, 0xFF, 0xFF });
    } else {
        drawRect(x + 1, y + 1, 12, 8, .{ 0xE2, 0xF3, 0xFF, 0xFF });
        fillRectI32(x + 3, y + 3, 2, 2, .{ 0xE2, 0xF3, 0xFF, 0xFF });
        fillRectI32(x + 6, y + 3, 2, 2, .{ 0xE2, 0xF3, 0xFF, 0xFF });
        fillRectI32(x + 9, y + 3, 2, 2, .{ 0xE2, 0xF3, 0xFF, 0xFF });
    }
}

fn drawBrowserPanel() void {
    drawPanelShell("BROWSER");

    var i: i32 = 0;
    while (i < @as(i32, @intCast(browser_items.len))) : (i += 1) {
        const row_y = PANEL_Y + 33 + i * 34;
        const selected = i == browser_selection;
        if (selected) {
            const pulse_alpha: i32 = if (browser_flash > 0) 170 else 126;
            blendRoundedRect(PANEL_X + 18, row_y, PANEL_W - 36, 28, 5, .{ 0x9E, 0xCE, 0xFA, @as(u8, @intCast(pulse_alpha)) });
        } else {
            blendRoundedRect(PANEL_X + 18, row_y, PANEL_W - 36, 28, 5, .{ 0x4E, 0x79, 0xA8, 0x64 });
        }

        drawRoundedRectOutline(PANEL_X + 18, row_y, PANEL_W - 36, 28, 5, if (selected) .{ 0xE0, 0xF3, 0xFF, 0xFF } else .{ 0x88, 0xAE, 0xD4, 0xFF });
        drawDiscGlyph(PANEL_X + 24, row_y + 7, selected);
        drawTextScaled(PANEL_X + 42, row_y + 7, browser_items[@as(usize, @intCast(i))], if (selected) C_WHITE else C_TEXT, 1);
        drawTextScaled(PANEL_X + 42, row_y + 16, browser_subtitles[@as(usize, @intCast(i))], C_TEXT_DIM, 1);
    }
}

fn drawSystemPanel() void {
    drawPanelShell("SYSTEM CONFIGURATION");

    var i: i32 = 0;
    while (i < @as(i32, @intCast(system_items.len))) : (i += 1) {
        const row_y = PANEL_Y + 30 + i * 25;
        const selected = i == system_selection;
        if (selected) {
            blendRoundedRect(PANEL_X + 14, row_y, PANEL_W - 28, 21, 4, .{ 0xA7, 0xD2, 0xFA, 0xB0 });
        } else {
            blendRoundedRect(PANEL_X + 14, row_y, PANEL_W - 28, 21, 4, .{ 0x4D, 0x74, 0x9E, 0x64 });
        }
        drawTextScaled(PANEL_X + 20, row_y + 7, system_items[@as(usize, @intCast(i))], if (selected) C_WHITE else C_TEXT, 1);

        const value = systemValueLabel(i);
        const value_x = PANEL_X + 179;
        drawTextScaled(value_x, row_y + 7, value, if (selected) C_WHITE else C_TEXT_DIM, 1);
        drawTextScaled(PANEL_X + 171, row_y + 7, "<", if (selected) C_WHITE else C_TEXT_DIM, 1);
        drawTextScaled(PANEL_X + PANEL_W - 22, row_y + 7, ">", if (selected) C_WHITE else C_TEXT_DIM, 1);
    }
}

fn drawPanelShell(title: []const u8) void {
    blendRoundedRect(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 8, .{ 0x0B, 0x24, 0x44, 0xD8 });
    drawRoundedRectOutline(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 8, .{ 0x9A, 0xBF, 0xE8, 0xFF });
    drawTextScaled(PANEL_X + 12, PANEL_Y + 11, title, C_WHITE, 2);
    drawTextScaled(PANEL_X + PANEL_W - 47, PANEL_Y + PANEL_H - 14, "BACK", C_TEXT_DIM, 1);
}

fn drawBottomHelp() void {
    blendRectI32(0, @as(i32, @intCast(RENDER_H - 20)), @as(i32, @intCast(RENDER_W)), 20, .{ 0x03, 0x12, 0x24, 0xB8 });
    if (mode == .main) {
        drawTextScaled(9, 206, "D-PAD MOVE", C_TEXT_DIM, 1);
        drawTextScaled(100, 206, "X ENTER", C_TEXT_DIM, 1);
    } else {
        drawTextScaled(9, 206, "X SELECT", C_TEXT_DIM, 1);
        drawTextScaled(88, 206, "O BACK", C_TEXT_DIM, 1);
        if (mode == .system_config) drawTextScaled(157, 206, "LEFT/RIGHT CHANGE", C_TEXT_DIM, 1);
    }
}

fn drawDiscGlyph(x: i32, y: i32, selected: bool) void {
    const outer = if (selected) [4]u8{ 0xEE, 0xF8, 0xFF, 0xFF } else [4]u8{ 0xAE, 0xCB, 0xE8, 0xFF };
    const inner = if (selected) [4]u8{ 0x8B, 0xB7, 0xE4, 0xFF } else [4]u8{ 0x66, 0x8D, 0xB4, 0xFF };
    fillCircle(x + 5, y + 5, 5, outer);
    fillCircle(x + 5, y + 5, 2, inner);
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn blendRoundedRect(x: i32, y: i32, w: i32, h: i32, radius: i32, color: [4]u8) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            if (!insideRoundedRect(xx, yy, w, h, radius)) continue;
            blendPixelI32(x + xx, y + yy, color);
        }
    }
}

fn drawRoundedRectOutline(x: i32, y: i32, w: i32, h: i32, radius: i32, color: [4]u8) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            if (!insideRoundedRect(xx, yy, w, h, radius)) continue;
            const in_prev = insideRoundedRect(xx - 1, yy, w, h, radius) and insideRoundedRect(xx + 1, yy, w, h, radius) and insideRoundedRect(xx, yy - 1, w, h, radius) and insideRoundedRect(xx, yy + 1, w, h, radius);
            if (!in_prev) setPixelI32(x + xx, y + yy, color);
        }
    }
}

fn insideRoundedRect(x: i32, y: i32, w: i32, h: i32, r: i32) bool {
    if (x < 0 or y < 0 or x >= w or y >= h) return false;
    const rx = if (x < r) r - x else if (x >= w - r) x - (w - r - 1) else 0;
    const ry = if (y < r) r - y else if (y >= h - r) y - (h - r - 1) else 0;
    if (rx == 0 or ry == 0) return true;
    return rx * rx + ry * ry <= r * r;
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: [4]u8) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn drawLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: [4]u8) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setPixelI32(x0, y0, c);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: [4]u8, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
    }
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: [4]u8, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            fillRectI32(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, c);
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G', 'g' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q', 'q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z', 'z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '(' => .{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => .{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillCircle(cx: i32, cy: i32, radius: i32, c: [4]u8) void {
    var y = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= radius * radius) setPixelI32(x, y, c);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: [4]u8) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) setPixelI32(x, y, c);
    }
}

fn blendRectI32(x0: i32, y0: i32, w: i32, h: i32, c: [4]u8) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) blendPixelI32(x, y, c);
    }
}

fn blendPixelI32(x: i32, y: i32, src: [4]u8) void {
    if (src[3] == 0) return;
    if (src[3] == 0xFF) {
        setPixelI32(x, y, src);
        return;
    }
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const alpha = @as(u16, src[3]);
    const inv = 255 - alpha;
    pixel_buf[idx + 0] = blendChannel(src[0], pixel_buf[idx + 0], alpha, inv);
    pixel_buf[idx + 1] = blendChannel(src[1], pixel_buf[idx + 1], alpha, inv);
    pixel_buf[idx + 2] = blendChannel(src[2], pixel_buf[idx + 2], alpha, inv);
    pixel_buf[idx + 3] = 0xFF;
}

fn blendChannel(src: u8, dst: u8, alpha: u16, inv: u16) u8 {
    return @as(u8, @intCast(@divTrunc(@as(u16, src) * alpha + @as(u16, dst) * inv + 127, 255)));
}

fn setPixelI32(x: i32, y: i32, c: [4]u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn clampU8(base: u8, delta: i32) u8 {
    const v = @as(i32, base) + delta;
    return @as(u8, @intCast(clampI32(v, 0, 255)));
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}
