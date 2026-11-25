// A console menu in the style of the PlayStation 2 browser, drawn at 2x.
//
// The main menu offers Browser and System Configuration over a slowly turning
// field of light pillars. The browser lists two memory cards and a disc tray;
// opening a card shows its saves as spinning icons, and each save can be
// copied to the other card or deleted. System Configuration changes the
// language (every label is translated), the accent colour, background motion
// and the button guide, and shows console information.
//
// All motion is derived from update time: begin_update_at eases selections and
// advances transitions by the time since the previous update, so the same
// updates always produce the same frame. While anything moves, finish_update
// asks for the next frame; once still (background motion off, nothing easing)
// it stops asking.

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
const TRANSITION_MS: f32 = 320;
const COPY_MS: i64 = 1400;
const TOAST_MS: i64 = 2200;
const CARD_KB: u32 = 8192;

// ---- Text ------------------------------------------------------------------------

const Lang = enum(u8) { en, fr, de, es, it };
const LANG_COUNT = 5;
const language_names = [LANG_COUNT][]const u8{ "English", "Français", "Deutsch", "Español", "Italiano" };

const S = enum {
    browser,
    system,
    browser_caption,
    system_caption,
    card1,
    card2,
    disc,
    no_disc,
    saves,
    save_one,
    kb_free,
    kb,
    no_data,
    copy,
    delete,
    cancel,
    confirm_delete,
    yes,
    no,
    copying,
    copied,
    deleted,
    no_space,
    already,
    enter,
    back,
    change,
    language,
    accent,
    blue,
    violet,
    teal,
    ambient,
    on,
    off,
    hints,
    shown,
    hidden,
    info,
    version,
    resolution,
};

const strings = std.enums.directEnumArray(S, [LANG_COUNT][]const u8, 0, .{
    .browser = .{ "Browser", "Navigateur", "Browser", "Explorador", "Browser" },
    .system = .{ "System Configuration", "Configuration système", "Systemkonfiguration", "Configuración del sistema", "Configurazione di sistema" },
    .browser_caption = .{ "Memory cards and discs", "Cartes mémoire et disques", "Memory Cards und Discs", "Tarjetas de memoria y discos", "Memory card e dischi" },
    .system_caption = .{ "Language, colour and console details", "Langue, couleur et informations", "Sprache, Farbe und Konsolendetails", "Idioma, color y datos de la consola", "Lingua, colore e dettagli della console" },
    .card1 = .{ "Memory Card (Slot 1)", "Carte mémoire (fente 1)", "Memory Card (Steckplatz 1)", "Tarjeta de memoria (ranura 1)", "Memory card (slot 1)" },
    .card2 = .{ "Memory Card (Slot 2)", "Carte mémoire (fente 2)", "Memory Card (Steckplatz 2)", "Tarjeta de memoria (ranura 2)", "Memory card (slot 2)" },
    .disc = .{ "Disc", "Disque", "Disc", "Disco", "Disco" },
    .no_disc = .{ "No disc inserted", "Aucun disque inséré", "Keine Disc eingelegt", "No hay ningún disco", "Nessun disco inserito" },
    .saves = .{ "saves", "sauvegardes", "Spielstände", "partidas", "salvataggi" },
    .save_one = .{ "save", "sauvegarde", "Spielstand", "partida", "salvataggio" },
    .kb_free = .{ "KB free", "Ko libres", "KB frei", "KB libres", "KB liberi" },
    .kb = .{ "KB", "Ko", "KB", "KB", "KB" },
    .no_data = .{ "No data", "Aucune donnée", "Keine Daten", "Sin datos", "Nessun dato" },
    .copy = .{ "Copy", "Copier", "Kopieren", "Copiar", "Copia" },
    .delete = .{ "Delete", "Supprimer", "Löschen", "Eliminar", "Elimina" },
    .cancel = .{ "Cancel", "Annuler", "Abbrechen", "Cancelar", "Annulla" },
    .confirm_delete = .{ "Delete this data?", "Supprimer ces données ?", "Diese Daten löschen?", "¿Eliminar estos datos?", "Eliminare questi dati?" },
    .yes = .{ "Yes", "Oui", "Ja", "Sí", "Sì" },
    .no = .{ "No", "Non", "Nein", "No", "No" },
    .copying = .{ "Copying…", "Copie en cours…", "Wird kopiert…", "Copiando…", "Copia in corso…" },
    .copied = .{ "Copy complete", "Copie terminée", "Kopieren abgeschlossen", "Copia completada", "Copia completata" },
    .deleted = .{ "Data deleted", "Données supprimées", "Daten gelöscht", "Datos eliminados", "Dati eliminati" },
    .no_space = .{ "Not enough free space", "Espace libre insuffisant", "Nicht genug freier Speicher", "Espacio libre insuficiente", "Spazio libero insufficiente" },
    .already = .{ "Already on the other card", "Déjà sur l’autre carte", "Bereits auf der anderen Karte", "Ya está en la otra tarjeta", "Già presente sull’altra card" },
    .enter = .{ "Enter", "Valider", "Auswählen", "Aceptar", "Conferma" },
    .back = .{ "Back", "Retour", "Zurück", "Atrás", "Indietro" },
    .change = .{ "Change", "Modifier", "Ändern", "Cambiar", "Cambia" },
    .language = .{ "Language", "Langue", "Sprache", "Idioma", "Lingua" },
    .accent = .{ "Accent Colour", "Couleur d’accent", "Akzentfarbe", "Color de acento", "Colore di accento" },
    .blue = .{ "Blue", "Bleu", "Blau", "Azul", "Blu" },
    .violet = .{ "Violet", "Violet", "Violett", "Violeta", "Viola" },
    .teal = .{ "Teal", "Turquoise", "Türkis", "Turquesa", "Turchese" },
    .ambient = .{ "Background Motion", "Animation du fond", "Hintergrundbewegung", "Movimiento de fondo", "Movimento dello sfondo" },
    .on = .{ "On", "Activée", "Ein", "Activado", "Attivo" },
    .off = .{ "Off", "Désactivée", "Aus", "Desactivado", "Disattivo" },
    .hints = .{ "Button Guide", "Guide des touches", "Tastenhilfe", "Guía de botones", "Guida ai tasti" },
    .shown = .{ "Shown", "Affiché", "Sichtbar", "Visible", "Visibile" },
    .hidden = .{ "Hidden", "Masqué", "Ausgeblendet", "Oculta", "Nascosta" },
    .info = .{ "Console Information", "Informations console", "Konsoleninformationen", "Información de la consola", "Informazioni console" },
    .version = .{ "Menu version", "Version du menu", "Menüversion", "Versión del menú", "Versione del menu" },
    .resolution = .{ "Resolution", "Résolution", "Auflösung", "Resolución", "Risoluzione" },
});

fn tr(s: S) []const u8 {
    return strings[@intFromEnum(s)][@intFromEnum(state.lang)];
}

// ---- Saves -----------------------------------------------------------------------

const Shape = enum(u8) { cube, gem };
const SaveInfo = struct { title: []const u8, kb: u16, hue: f32, shape: Shape, date: []const u8 };

const catalog = [_]SaveInfo{
    .{ .title = "Skyline Rally", .kb = 412, .hue = 0.58, .shape = .cube, .date = "2003/11/04  21:17" },
    .{ .title = "Lantern Keep", .kb = 1184, .hue = 0.08, .shape = .gem, .date = "2003/12/19  18:02" },
    .{ .title = "Orbital Drift", .kb = 96, .hue = 0.76, .shape = .cube, .date = "2004/01/02  09:44" },
    .{ .title = "Moss & Marrow", .kb = 520, .hue = 0.31, .shape = .gem, .date = "2004/02/14  23:51" },
    .{ .title = "Tidebreaker", .kb = 2048, .hue = 0.50, .shape = .cube, .date = "2004/03/08  16:20" },
    .{ .title = "Glass Harbour", .kb = 734, .hue = 0.90, .shape = .gem, .date = "2004/04/27  12:05" },
    .{ .title = "Ember Trail", .kb = 288, .hue = 0.02, .shape = .cube, .date = "2004/05/30  20:38" },
};

const MAX_SAVES = 8;
const Card = struct {
    ids: [MAX_SAVES]u8 = undefined,
    len: u8 = 0,

    fn usedKb(self: *const Card) u32 {
        var total: u32 = 0;
        for (self.ids[0..self.len]) |id| total += catalog[id].kb;
        return total;
    }
    fn freeKb(self: *const Card) u32 {
        return CARD_KB - self.usedKb();
    }
    fn has(self: *const Card, id: u8) bool {
        return std.mem.indexOfScalar(u8, self.ids[0..self.len], id) != null;
    }
    fn remove(self: *Card, index: usize) void {
        var i = index;
        while (i + 1 < self.len) : (i += 1) self.ids[i] = self.ids[i + 1];
        self.len -= 1;
    }
    fn add(self: *Card, id: u8) void {
        self.ids[self.len] = id;
        self.len += 1;
    }
};

fn initialCards() [2]Card {
    var cards: [2]Card = .{ .{}, .{} };
    for ([_]u8{ 0, 1, 2, 3, 4 }) |id| cards[0].add(id);
    for ([_]u8{ 5, 6 }) |id| cards[1].add(id);
    return cards;
}

// ---- State -----------------------------------------------------------------------

const Screen = enum(u8) { main, browser, card, system };
const Overlay = enum(u8) { none, options, confirm, copying, info };
const Setting = enum(u8) { language, accent, ambient, hints, info };
const SETTING_COUNT = 5;

const Toast = struct { text: S, start_ms: i64 };

const State = struct {
    screen: Screen = .main,
    prev_screen: Screen = .main,
    trans_start_ms: i64 = -100_000,
    trans_dir: f32 = 1,

    main_sel: u8 = 0,
    browser_sel: u8 = 0,
    card_slot: u8 = 0,
    card_sel: [2]u8 = .{ 0, 0 },
    sys_sel: u8 = 0,
    overlay: Overlay = .none,
    overlay_sel: u8 = 0,

    cards: [2]Card = initialCards(),
    copy_start_ms: i64 = 0,
    copy_id: u8 = 0,
    toast: ?Toast = null,
    value_change_ms: i64 = -100_000,
    value_dir: f32 = 1,
    shake_start_ms: i64 = -100_000,

    lang: Lang = .en,
    accent: u8 = 0,
    ambient: bool = true,
    hints: bool = true,

    // Eased positions, advanced in begin_update_at.
    main_f: f32 = 0,
    browser_f: f32 = 0,
    card_f: f32 = 0,
    sys_f: f32 = 0,
    overlay_f: f32 = 0,
    overlay_open: f32 = 0,
    pillar_level: f32 = 1,
    ambient_t: f64 = 0,
    spin_t: f64 = 0,

    hover: bool = false,
    primary_down: bool = false,
    secondary_down: bool = false,
};

const Phase = enum { initializing, ready, updating };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var bg_buf: [PIXEL_BYTES]u8 = undefined;
var bg_accent: u8 = 0xFF;
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
        XK_LEFT, 'a', 'A' => .left,
        XK_RIGHT, 'd', 'D' => .right,
        XK_RETURN, XK_KP_ENTER, ' ', 'x', 'X' => .confirm,
        XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => .back,
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
    // Hovering moves the selection like the d-pad would.
    if (hit) |h| changed = hover(h) or changed;
    const pressed = primary and !state.primary_down;
    if (pressed) {
        if (hit) |h| {
            changed = activate(h) or changed;
        } else if (state.overlay != .none and state.overlay != .copying) {
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
    approach(&state.browser_f, @floatFromInt(state.browser_sel), dt, 80);
    approach(&state.card_f, @floatFromInt(state.card_sel[state.card_slot]), dt, 70);
    approach(&state.sys_f, @floatFromInt(state.sys_sel), dt, 60);
    approach(&state.overlay_f, @floatFromInt(state.overlay_sel), dt, 50);
    approach(&state.overlay_open, if (state.overlay != .none) 1 else 0, dt, 60);
    // The pillars step back behind the denser screens.
    approach(&state.pillar_level, if (state.screen == .main) 1 else 0.5, dt, 160);
    if (state.ambient) state.ambient_t += dt / 1000;
    state.spin_t += dt / 1000;

    if (state.overlay == .copying and now_ms - state.copy_start_ms >= COPY_MS) finishCopy();
    if (state.toast) |t| {
        if (now_ms - t.start_ms >= TOAST_MS) state.toast = null;
    }
}

fn isAnimating() bool {
    if (state.ambient) return true;
    if (state.screen == .card or state.overlay == .copying or state.toast != null) return true;
    if (transitionProgress() < 1) return true;
    if (now_ms - state.value_change_ms < 300 or now_ms - state.shake_start_ms < 500) return true;
    const pairs = [_][2]f32{
        .{ state.main_f, @floatFromInt(state.main_sel) },
        .{ state.browser_f, @floatFromInt(state.browser_sel) },
        .{ state.card_f, @floatFromInt(state.card_sel[state.card_slot]) },
        .{ state.sys_f, @floatFromInt(state.sys_sel) },
        .{ state.overlay_f, @floatFromInt(state.overlay_sel) },
        .{ state.overlay_open, if (state.overlay != .none) 1 else 0 },
        .{ state.pillar_level, if (state.screen == .main) 1 else 0.5 },
    };
    for (pairs) |p| if (p[0] != p[1]) return true;
    return false;
}

fn transitionProgress() f32 {
    const t: f32 = @floatFromInt(now_ms - state.trans_start_ms);
    return std.math.clamp(t / TRANSITION_MS, 0, 1);
}

fn goTo(screen: Screen, dir: f32) void {
    state.prev_screen = state.screen;
    state.screen = screen;
    state.trans_start_ms = now_ms;
    state.trans_dir = dir;
}

fn showToast(text: S) void {
    state.toast = .{ .text = text, .start_ms = now_ms };
}

fn openOverlay(o: Overlay, sel: u8) void {
    state.overlay = o;
    state.overlay_sel = sel;
    state.overlay_f = @floatFromInt(sel);
}

fn wrapStep(v: u8, delta: i32, count: usize) u8 {
    const n: i32 = @intCast(count);
    return @intCast(@mod(@as(i32, v) + delta, n));
}

fn clampStep(v: u8, delta: i32, count: usize) u8 {
    if (count == 0) return 0;
    return @intCast(std.math.clamp(@as(i32, v) + delta, 0, @as(i32, @intCast(count)) - 1));
}

fn perform(action: Action) bool {
    if (state.overlay != .none) return performOverlay(action);
    switch (state.screen) {
        .main => switch (action) {
            .up, .left => state.main_sel = wrapStep(state.main_sel, -1, 2),
            .down, .right => state.main_sel = wrapStep(state.main_sel, 1, 2),
            .confirm => goTo(if (state.main_sel == 0) .browser else .system, 1),
            .back => return false,
        },
        .browser => switch (action) {
            .left, .up => state.browser_sel = clampStep(state.browser_sel, -1, 3),
            .right, .down => state.browser_sel = clampStep(state.browser_sel, 1, 3),
            .confirm => openDevice(),
            .back => goTo(.main, -1),
        },
        .card => {
            const card = &state.cards[state.card_slot];
            const sel = &state.card_sel[state.card_slot];
            switch (action) {
                .left => sel.* = clampStep(sel.*, -1, card.len),
                .right => sel.* = clampStep(sel.*, 1, card.len),
                .up => sel.* = if (sel.* >= 4) sel.* - 4 else sel.*,
                .down => sel.* = if (sel.* + 4 < card.len) sel.* + 4 else sel.*,
                .confirm => if (card.len > 0) openOverlay(.options, 0),
                .back => goTo(.browser, -1),
            }
        },
        .system => switch (action) {
            .up => state.sys_sel = clampStep(state.sys_sel, -1, SETTING_COUNT),
            .down => state.sys_sel = clampStep(state.sys_sel, 1, SETTING_COUNT),
            .left => changeSetting(-1),
            .right => changeSetting(1),
            .confirm => if (@as(Setting, @enumFromInt(state.sys_sel)) == .info) openOverlay(.info, 0) else changeSetting(1),
            .back => goTo(.main, -1),
        },
    }
    return true;
}

fn openDevice() void {
    switch (state.browser_sel) {
        0, 1 => {
            state.card_slot = state.browser_sel;
            state.card_f = @floatFromInt(state.card_sel[state.card_slot]);
            goTo(.card, 1);
        },
        else => {
            state.shake_start_ms = now_ms;
            showToast(.no_disc);
        },
    }
}

fn performOverlay(action: Action) bool {
    switch (state.overlay) {
        .none => return false,
        .copying => return false,
        .info => switch (action) {
            .confirm, .back => state.overlay = .none,
            else => return false,
        },
        .options => switch (action) {
            .up, .left => state.overlay_sel = clampStep(state.overlay_sel, -1, 3),
            .down, .right => state.overlay_sel = clampStep(state.overlay_sel, 1, 3),
            .back => state.overlay = .none,
            .confirm => switch (state.overlay_sel) {
                0 => startCopy(),
                1 => openOverlay(.confirm, 1),
                else => state.overlay = .none,
            },
        },
        .confirm => switch (action) {
            .left, .up => state.overlay_sel = 0,
            .right, .down => state.overlay_sel = 1,
            .back => state.overlay = .none,
            .confirm => {
                if (state.overlay_sel == 0) deleteSelected();
                state.overlay = .none;
            },
        },
    }
    return true;
}

fn selectedSaveId() u8 {
    const card = &state.cards[state.card_slot];
    return card.ids[state.card_sel[state.card_slot]];
}

fn startCopy() void {
    const id = selectedSaveId();
    const other = &state.cards[1 - state.card_slot];
    if (other.has(id)) {
        state.overlay = .none;
        showToast(.already);
    } else if (other.freeKb() < catalog[id].kb or other.len >= MAX_SAVES) {
        state.overlay = .none;
        showToast(.no_space);
    } else {
        state.overlay = .copying;
        state.copy_start_ms = now_ms;
        state.copy_id = id;
    }
}

fn finishCopy() void {
    state.cards[1 - state.card_slot].add(state.copy_id);
    state.overlay = .none;
    showToast(.copied);
}

fn deleteSelected() void {
    const card = &state.cards[state.card_slot];
    const sel = &state.card_sel[state.card_slot];
    card.remove(sel.*);
    if (sel.* >= card.len and sel.* > 0) sel.* -= 1;
    showToast(.deleted);
}

fn changeSetting(delta: i32) void {
    switch (@as(Setting, @enumFromInt(state.sys_sel))) {
        .language => state.lang = @enumFromInt(wrapStep(@intFromEnum(state.lang), delta, LANG_COUNT)),
        .accent => state.accent = wrapStep(state.accent, delta, accents.len),
        .ambient => state.ambient = !state.ambient,
        .hints => state.hints = !state.hints,
        .info => return,
    }
    state.value_change_ms = now_ms;
    state.value_dir = if (delta < 0) -1 else 1;
}

// ---- Hit testing -----------------------------------------------------------------

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

const Hit = union(enum) {
    main_item: u8,
    device: u8,
    save: u8,
    setting: struct { index: u8, dir: i32 },
    option: u8,
    title_back,
    footer: Action,
    overlay_panel,
};

const MAIN_X: f32 = 112;
const MAIN_BASE_Y = [2]f32{ 318, 418 };
const MAIN_PX: f32 = 46;

fn mainItemRect(i: usize) Rect {
    return .{ .x = MAIN_X - 60, .y = MAIN_BASE_Y[i] - 62, .w = 640, .h = 92 };
}

const DEVICE_Y: f32 = 320;
fn deviceX(i: usize) f32 {
    return 240 + @as(f32, @floatFromInt(i)) * 240;
}
fn deviceRect(i: usize) Rect {
    return .{ .x = deviceX(i) - 110, .y = DEVICE_Y - 140, .w = 220, .h = 260 };
}

const GRID_X: f32 = 120;
const GRID_Y: f32 = 176;
const CELL: f32 = 180;
fn saveCellRect(i: usize) Rect {
    const col: f32 = @floatFromInt(i % 4);
    const row: f32 = @floatFromInt(i / 4);
    return .{ .x = GRID_X + col * CELL, .y = GRID_Y + row * CELL, .w = CELL, .h = CELL };
}

const ROW_X: f32 = 72;
const ROW_W: f32 = WF - 144;
const ROW_Y: f32 = 178;
const ROW_H: f32 = 64;
const ROW_GAP: f32 = 12;
fn settingRect(i: usize) Rect {
    return .{ .x = ROW_X, .y = ROW_Y + @as(f32, @floatFromInt(i)) * (ROW_H + ROW_GAP), .w = ROW_W, .h = ROW_H };
}

const TITLE_RECT: Rect = .{ .x = 40, .y = 40, .w = 620, .h = 84 };

const PANEL_W: f32 = 460;
fn overlayPanel() Rect {
    const h: f32 = switch (state.overlay) {
        .options => 300,
        .confirm => 220,
        .copying => 190,
        .info => 300,
        .none => 0,
    };
    const w: f32 = if (state.overlay == .info) 620 else PANEL_W;
    return .{ .x = (WF - w) / 2, .y = (HF - h) / 2 - 10, .w = w, .h = h };
}
fn optionRect(i: usize) Rect {
    const p = overlayPanel();
    return .{ .x = p.x + 24, .y = p.y + 94 + @as(f32, @floatFromInt(i)) * 62, .w = p.w - 48, .h = 54 };
}
fn confirmButtonRect(i: usize) Rect {
    const p = overlayPanel();
    const bw: f32 = 170;
    const gap: f32 = 24;
    const x0 = p.x + (p.w - 2 * bw - gap) / 2;
    return .{ .x = x0 + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y + p.h - 92, .w = bw, .h = 58 };
}

const FOOTER_Y: f32 = 664;
const FOOTER_PX: f32 = 24;
const FooterItem = struct { badge: Badge, label: S, action: Action };
const Badge = enum { cross, circle, arrows };

fn footerItems(buf: *[3]FooterItem) []const FooterItem {
    var n: usize = 0;
    if (state.overlay == .copying) return buf[0..0];
    if (state.overlay == .none and state.screen == .system) {
        buf[n] = .{ .badge = .arrows, .label = .change, .action = .right };
        n += 1;
    }
    buf[n] = .{ .badge = .cross, .label = .enter, .action = .confirm };
    n += 1;
    if (state.screen != .main or state.overlay != .none) {
        buf[n] = .{ .badge = .circle, .label = .back, .action = .back };
        n += 1;
    }
    return buf[0..n];
}

fn footerItemRect(items: []const FooterItem, index: usize) Rect {
    var x: f32 = 72;
    for (items, 0..) |item, i| {
        const w = 44 + textWidth(tr(item.label), FOOTER_PX);
        if (i == index) return .{ .x = x - 6, .y = FOOTER_Y - 26, .w = w + 12, .h = 52 };
        x += w + 40;
    }
    unreachable;
}

fn hitTest(x: f32, y: f32) ?Hit {
    if (state.hints) {
        var buf: [3]FooterItem = undefined;
        const items = footerItems(&buf);
        for (items, 0..) |item, i| {
            if (footerItemRect(items, i).contains(x, y)) return .{ .footer = item.action };
        }
    }
    if (state.overlay != .none) {
        switch (state.overlay) {
            .options => for (0..3) |i| {
                if (optionRect(i).contains(x, y)) return .{ .option = @intCast(i) };
            },
            .confirm => for (0..2) |i| {
                if (confirmButtonRect(i).contains(x, y)) return .{ .option = @intCast(i) };
            },
            else => {},
        }
        if (overlayPanel().contains(x, y)) return .overlay_panel;
        return null;
    }
    if (state.screen != .main and TITLE_RECT.contains(x, y)) return .title_back;
    switch (state.screen) {
        .main => for (0..2) |i| {
            if (mainItemRect(i).contains(x, y)) return .{ .main_item = @intCast(i) };
        },
        .browser => for (0..3) |i| {
            if (deviceRect(i).contains(x, y)) return .{ .device = @intCast(i) };
        },
        .card => for (0..state.cards[state.card_slot].len) |i| {
            if (saveCellRect(i).contains(x, y)) return .{ .save = @intCast(i) };
        },
        .system => for (0..SETTING_COUNT) |i| {
            const r = settingRect(i);
            if (r.contains(x, y)) {
                const dir: i32 = if (x > r.x + r.w - 150) 1 else if (x > r.x + r.w - 330) -1 else 0;
                return .{ .setting = .{ .index = @intCast(i), .dir = dir } };
            }
        },
    }
    return null;
}

fn hover(h: Hit) bool {
    switch (h) {
        .main_item => |i| return setSel(&state.main_sel, i),
        .device => |i| return setSel(&state.browser_sel, i),
        .save => |i| return setSel(&state.card_sel[state.card_slot], i),
        .setting => |s| return setSel(&state.sys_sel, s.index),
        .option => |i| return setSel(&state.overlay_sel, i),
        else => return false,
    }
}

fn setSel(field: *u8, value: u8) bool {
    if (field.* == value) return false;
    field.* = value;
    return true;
}

fn activate(h: Hit) bool {
    switch (h) {
        .main_item, .device, .save, .option => return perform(.confirm),
        .setting => |s| {
            if (@as(Setting, @enumFromInt(s.index)) == .info) return perform(.confirm);
            changeSetting(if (s.dir < 0) -1 else 1);
            return true;
        },
        .title_back => return perform(.back),
        .footer => |a| return perform(a),
        .overlay_panel => return if (state.overlay == .info) perform(.back) else false,
    }
}

// ---- Colours ---------------------------------------------------------------------

const Color = [3]u8;
const accents = [_]Color{ .{ 0x5C, 0x9E, 0xFF }, .{ 0xA4, 0x82, 0xFF }, .{ 0x3E, 0xD8, 0xC6 } };
const C_TEXT: Color = .{ 0xF2, 0xF6, 0xFF };
const C_DIM: Color = .{ 0x9A, 0xA8, 0xC4 };
const C_PANEL: Color = .{ 0x0A, 0x10, 0x22 };

fn accent() Color {
    return accents[state.accent];
}

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

fn hsv(h: f32, s: f32, v: f32) Color {
    const hh = (h - @floor(h)) * 6;
    const i: u32 = @intFromFloat(@floor(hh));
    const f = hh - @floor(hh);
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const t = v * (1 - s * (1 - f));
    const rgb: [3]f32 = switch (i % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{
        @intFromFloat(std.math.clamp(rgb[0] * 255, 0, 255)),
        @intFromFloat(std.math.clamp(rgb[1] * 255, 0, 255)),
        @intFromFloat(std.math.clamp(rgb[2] * 255, 0, 255)),
    };
}

fn easeOut(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

// ---- Frame -----------------------------------------------------------------------

fn drawFrame() void {
    if (bg_accent != state.accent) buildBackground();
    @memcpy(output_buf[ktx.HEADER_SIZE..], &bg_buf);
    drawPillars();
    drawMotes();

    const t = transitionProgress();
    if (t < 1) {
        const e = easeOut(t);
        if (t < 0.45) {
            g_alpha = 1 - t / 0.45;
            g_dx = @intFromFloat(@round(-state.trans_dir * 70 * e));
            drawScreen(state.prev_screen);
        }
        g_alpha = std.math.clamp((t - 0.2) / 0.8, 0, 1);
        g_dx = @intFromFloat(@round(state.trans_dir * 70 * (1 - e)));
        drawScreen(state.screen);
        g_alpha = 1;
        g_dx = 0;
    } else {
        drawScreen(state.screen);
    }

    drawOverlay();
    drawToast();
    if (state.hints) drawFooter();
}

fn drawScreen(screen: Screen) void {
    switch (screen) {
        .main => drawMain(),
        .browser => drawBrowser(),
        .card => drawCard(),
        .system => drawSystem(),
    }
}

// ---- Background ------------------------------------------------------------------

const HORIZON: f32 = 330;

fn buildBackground() void {
    bg_accent = state.accent;
    const a = accent();
    const top: Color = .{ 0x01, 0x02, 0x07 };
    const bottom = mix(.{ 0x03, 0x06, 0x14 }, a, 0.05);
    const haze = mix(.{ 0x05, 0x0B, 0x22 }, a, 0.35);
    for (0..H) |y| {
        const fy: f32 = @floatFromInt(y);
        const base = mix(top, bottom, fy / HF);
        for (0..W) |x| {
            const fx: f32 = @floatFromInt(x);
            const dx = (fx - WF * 0.5) / (WF * 0.75);
            const dy = (fy - HORIZON) / 150;
            const glow = @exp(-(dx * dx + dy * dy));
            const c = mix(base, haze, glow * 0.55);
            // A little ordered dither keeps the gradient from banding.
            const d: f32 = @floatFromInt((x * 7 + y * 13) % 4);
            const i = (y * W + x) * 4;
            for (0..3) |ch| bg_buf[i + ch] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(c[ch])) + (d - 1.5) * 0.5, 0, 255));
            bg_buf[i + 3] = 0xFF;
        }
    }
}

// A grid of translucent light pillars on a dark floor, rising and falling and
// turning slowly about the middle of the field.
fn drawPillars() void {
    const t: f32 = @floatCast(state.ambient_t);
    const yaw = t * 0.045 + 0.35;
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    const focal: f32 = 560;
    const cam_h: f32 = 1.5;
    const center_z: f32 = 8.5;
    const a = accent();
    const tint = mix(a, C_TEXT, 0.25);
    const level = state.pillar_level;
    var j: i32 = -5;
    while (j <= 5) : (j += 1) {
        var i: i32 = -6;
        while (i <= 6) : (i += 1) {
            const gx = @as(f32, @floatFromInt(i)) * 1.5;
            const gz = @as(f32, @floatFromInt(j)) * 1.5;
            const x = gx * cy - gz * sy;
            const z = center_z + gx * sy + gz * cy;
            if (z < 2.2) continue;
            const fog = std.math.pow(f32, std.math.clamp(1 - (z - 2.2) / 13, 0, 1), 1.6);
            if (fog <= 0.01) continue;
            const fi: f32 = @floatFromInt(i);
            const fj: f32 = @floatFromInt(j);
            const wave = 0.5 + 0.5 * @sin(t * 0.55 + fi * 0.9 + fj * 1.7);
            const swell = 0.5 + 0.5 * @sin(t * 0.21 + fi * 0.37 - fj * 0.53);
            const height = 0.35 + 2.4 * wave * swell;
            const k = focal / z;
            const sx = WF * 0.5 + x * k;
            const half_w = 0.16 * k;
            if (sx + half_w < 0 or sx - half_w > WF) continue;
            const floor_y = HORIZON + cam_h * k;
            const top_y = HORIZON + (cam_h - height) * k;
            drawPillar(sx, half_w, top_y, floor_y, tint, fog * 0.3 * level);
            addGlow(sx, top_y, half_w * 1.9, half_w * 0.8, tint, fog * 0.6 * level);
        }
    }
}

fn drawPillar(cx: f32, half_w: f32, top: f32, floor: f32, c: Color, strength: f32) void {
    const x0: i32 = @intFromFloat(@max(0, @floor(cx - half_w)));
    const x1: i32 = @intFromFloat(@min(WF, @ceil(cx + half_w)));
    const reflect = (floor - top) * 0.35;
    const y0: i32 = @intFromFloat(@max(0, @floor(top)));
    const y1: i32 = @intFromFloat(@min(HF, @ceil(floor + reflect)));
    if (x0 >= x1 or y0 >= y1) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        var v: f32 = undefined;
        if (fy <= floor) {
            const u = (floor - fy) / @max(1, floor - top);
            v = 0.25 + 0.75 * u * u;
            if (fy < top + 1) v *= fy - top;
        } else {
            const u = 1 - (fy - floor) / reflect;
            v = 0.18 * u * u;
        }
        var x = x0;
        while (x < x1) : (x += 1) {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5 - cx) / half_w;
            const h = 1 - dx * dx;
            if (h <= 0) continue;
            addPixel(x, y, c, strength * v * h);
        }
    }
}

fn hash01(n: u32) f32 {
    var h = n *% 0x9E3779B1;
    h ^= h >> 15;
    h *%= 0x85EBCA77;
    h ^= h >> 13;
    return @as(f32, @floatFromInt(h & 0xFFFF)) / 65535.0;
}

fn drawMotes() void {
    const t: f32 = @floatCast(state.ambient_t);
    const tint = mix(accent(), C_TEXT, 0.6);
    for (0..26) |n| {
        const id: u32 = @intCast(n);
        const speed = 0.012 + hash01(id * 3 + 1) * 0.02;
        const phase_y = hash01(id * 3 + 2) + t * speed;
        const y = HF + 40 - (phase_y - @floor(phase_y)) * (HF + 80);
        const x = hash01(id * 3) * WF + @sin(t * 0.3 + @as(f32, @floatFromInt(n))) * 24;
        const r = 3 + hash01(id * 7) * 7;
        const twinkle = 0.55 + 0.45 * @sin(t * (1 + hash01(id * 5)) * 2 + @as(f32, @floatFromInt(n)));
        addGlow(x, y, r * 3, r * 3, tint, 0.22 * twinkle);
        addGlow(x, y, r * 0.8, r * 0.8, C_TEXT, 0.5 * twinkle);
    }
}

// ---- Main menu -------------------------------------------------------------------

fn drawMain() void {
    const a = accent();
    const t: f32 = @floatCast(state.spin_t);
    const items = [2]S{ .browser, .system };
    const captions = [2]S{ .browser_caption, .system_caption };

    // The glow behind the selection glides between the two items.
    const gy = MAIN_BASE_Y[0] + (MAIN_BASE_Y[1] - MAIN_BASE_Y[0]) * state.main_f - MAIN_PX * 0.36;
    const sel_w = textWidth(tr(items[state.main_sel]), MAIN_PX);
    addGlow(MAIN_X + sel_w * 0.5, gy, sel_w * 0.5 + 140, 64, a, 0.30);
    const pulse = 0.8 + 0.2 * @sin(t * 3.2);
    addGlow(MAIN_X - 34, gy, 30, 30, a, 0.75 * pulse);
    fillCircle(MAIN_X - 34, gy, 6.5, C_TEXT, 0.95);

    for (items, 0..) |item, i| {
        const fi: f32 = @floatFromInt(i);
        const near = std.math.clamp(1 - @abs(state.main_f - fi), 0, 1);
        const color = mix(C_DIM, C_TEXT, near);
        drawText(tr(item), MAIN_X, MAIN_BASE_Y[i], MAIN_PX, color, 0.55 + 0.45 * near);
        if (near > 0.01) drawText(tr(captions[i]), MAIN_X + 2, MAIN_BASE_Y[i] + 38, 22, C_DIM, near);
    }
}

// ---- Browser ---------------------------------------------------------------------

fn drawTitle(text: []const u8, subtitle: ?[]const u8) void {
    const a = accent();
    drawChevron(66, 86, 11, -1, C_DIM, 1);
    addGlow(98, 86, 22, 22, a, 0.6);
    fillCircle(98, 86, 5, C_TEXT, 0.95);
    drawText(text, 122, 101, 40, C_TEXT, 1);
    if (subtitle) |s| drawText(s, 124, 136, 22, C_DIM, 1);
}

fn drawBrowser() void {
    drawTitle(tr(.browser), null);
    const t: f32 = @floatCast(state.spin_t);
    for (0..3) |i| {
        const fi: f32 = @floatFromInt(i);
        const near = std.math.clamp(1 - @abs(state.browser_f - fi), 0, 1);
        const sz = 1 + 0.16 * near;
        var cx = deviceX(i);
        const bob = @sin(t * 2.0 + fi) * 5 * near;
        if (i == 2) {
            const st: f32 = @floatFromInt(now_ms - state.shake_start_ms);
            if (st < 500) cx += @sin(st / 22) * 10 * (1 - st / 500);
        }
        const cy = DEVICE_Y - bob;
        addGlow(cx, DEVICE_Y + 92, 110 * sz, 20 * sz, accent(), 0.35 * near);
        const alpha = 0.55 + 0.45 * near;
        switch (i) {
            0, 1 => drawMemoryCard(cx, cy, sz, @intCast(i + 1), alpha),
            else => drawDisc(cx, cy, 70 * sz, t, alpha * 0.55),
        }
    }

    const sel = state.browser_sel;
    const name = switch (sel) {
        0 => tr(.card1),
        1 => tr(.card2),
        else => tr(.disc),
    };
    drawTextCentered(name, WF / 2, 520, 34, C_TEXT, 1);
    var line: TextBuf = .{};
    if (sel < 2) {
        cardSummary(&line, &state.cards[sel]);
    } else {
        line.add(tr(.no_disc));
    }
    drawTextCentered(line.slice(), WF / 2, 560, 24, C_DIM, 1);
}

fn cardSummary(line: *TextBuf, card: *const Card) void {
    if (card.len == 0) {
        line.add(tr(.no_data));
    } else {
        line.addDigits(card.len, 1);
        line.add(" ");
        line.add(if (card.len == 1) tr(.save_one) else tr(.saves));
    }
    line.add("  ·  ");
    addThousands(line, card.freeKb());
    line.add(" ");
    line.add(tr(.kb_free));
}

fn drawMemoryCard(cx: f32, cy: f32, s: f32, slot: u8, alpha: f32) void {
    const w = 96 * s;
    const h = 128 * s;
    const x = cx - w / 2;
    const y = cy - h / 2;
    fillRoundRectGrad(.{ .x = x, .y = y, .w = w, .h = h }, 10 * s, .{ 0x3A, 0x42, 0x54 }, .{ 0x1A, 0x1F, 0x2B }, alpha);
    fillRoundRect(.{ .x = x + 2 * s, .y = y + 2 * s, .w = w - 4 * s, .h = 3 * s }, 1.5 * s, .{ 0x9A, 0xA6, 0xC0 }, alpha * 0.5);
    const label: Rect = .{ .x = x + 12 * s, .y = y + 16 * s, .w = w - 24 * s, .h = 58 * s };
    fillRoundRectGrad(label, 6 * s, mix(accent(), C_TEXT, 0.35), scale(accent(), 0.75), alpha);
    var digit: [1]u8 = .{'0' + slot};
    drawTextCentered(&digit, cx, label.y + label.h / 2 + 15 * s, 40 * s, .{ 0x0B, 0x12, 0x28 }, alpha);
    // Gold contacts along the bottom edge.
    for (0..7) |k| {
        const kx = x + 15 * s + @as(f32, @floatFromInt(k)) * 10 * s;
        fillRoundRect(.{ .x = kx, .y = y + h - 26 * s, .w = 6 * s, .h = 14 * s }, 1.5 * s, .{ 0xD4, 0xB0, 0x5A }, alpha);
    }
}

fn drawDisc(cx: f32, cy: f32, r: f32, t: f32, alpha: f32) void {
    const x0: i32 = @intFromFloat(@floor(cx - r - 1));
    const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
    const y0: i32 = @intFromFloat(@floor(cy - r - 1));
    const y1: i32 = @intFromFloat(@ceil(cy + r + 1));
    const hole = r * 0.16;
    const hub = r * 0.34;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            const cov = @min(std.math.clamp(r + 0.5 - d, 0, 1), std.math.clamp(d - hole + 0.5, 0, 1));
            if (cov <= 0) continue;
            const ang = std.math.atan2(dy, dx);
            const sheen = 0.5 + 0.5 * @cos(2 * ang + t * 0.8);
            var c = mix(.{ 0x8C, 0x96, 0xA8 }, .{ 0xE8, 0xEE, 0xF8 }, sheen);
            if (d > hub) {
                c = mix(c, hsv(ang / (2 * std.math.pi) * 2 + t * 0.05 + d / r * 0.4, 0.55, 1), 0.3 * sheen);
            } else {
                c = mix(c, .{ 0xC8, 0xD0, 0xDC }, 0.6);
            }
            blend(x, y, c, cov * alpha);
        }
    }
}

// ---- Memory card contents --------------------------------------------------------

fn drawCard() void {
    const card = &state.cards[state.card_slot];
    var summary: TextBuf = .{};
    cardSummary(&summary, card);
    drawTitle(tr(if (state.card_slot == 0) .card1 else .card2), summary.slice());

    // Capacity bar in the top right.
    const bar: Rect = .{ .x = WF - 72 - 220, .y = 82, .w = 220, .h = 10 };
    fillRoundRect(bar, 5, .{ 0x22, 0x2A, 0x40 }, 1);
    const used = @as(f32, @floatFromInt(card.usedKb())) / @as(f32, @floatFromInt(CARD_KB));
    if (used > 0) fillRoundRect(.{ .x = bar.x, .y = bar.y, .w = @max(bar.h, bar.w * used), .h = bar.h }, 5, accent(), 1);

    if (card.len == 0) {
        drawTextCentered(tr(.no_data), WF / 2, 360, 34, C_DIM, 1);
        return;
    }

    const t: f32 = @floatCast(state.spin_t);
    const sel = state.card_sel[state.card_slot];
    // A soft highlight glides between cells.
    const col_f = @mod(state.card_f, 4);
    const row_f = @floor(state.card_f / 4);
    const hx = GRID_X + col_f * CELL + CELL / 2;
    const hy = GRID_Y + row_f * CELL + CELL / 2;
    fillRoundRect(.{ .x = hx - CELL / 2 + 10, .y = hy - CELL / 2 + 10, .w = CELL - 20, .h = CELL - 20 }, 18, accent(), 0.12);
    addGlow(hx, hy + 50, 80, 18, accent(), 0.4);

    for (card.ids[0..card.len], 0..) |id, i| {
        const r = saveCellRect(i);
        const info = catalog[id];
        const selected = i == sel;
        const spin = if (selected) t * 1.6 else 0.6 + @as(f32, @floatFromInt(i)) * 0.4;
        const size: f32 = if (selected) 64 else 52;
        const bob: f32 = if (selected) @sin(t * 2.4) * 4 else 0;
        drawSaveIcon(r.x + r.w / 2, r.y + r.h / 2 - 6 - bob, size, spin, info, if (selected) 1 else 0.7);
    }

    const info = catalog[card.ids[sel]];
    drawTextCentered(info.title, WF / 2, 572, 34, C_TEXT, 1);
    var detail: TextBuf = .{};
    addThousands(&detail, info.kb);
    detail.add(" ");
    detail.add(tr(.kb));
    detail.add("   ·   ");
    detail.add(info.date);
    drawTextCentered(detail.slice(), WF / 2, 608, 22, C_DIM, 1);
}

const V3 = struct { x: f32, y: f32, z: f32 };

fn sub3(a: V3, b: V3) V3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}
fn cross3(a: V3, b: V3) V3 {
    return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
}
fn dot3(a: V3, b: V3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
fn norm3(a: V3) V3 {
    const l = @sqrt(dot3(a, a));
    return .{ .x = a.x / l, .y = a.y / l, .z = a.z / l };
}

const cube_verts = [_]V3{
    .{ .x = -1, .y = -1, .z = -1 }, .{ .x = 1, .y = -1, .z = -1 }, .{ .x = 1, .y = 1, .z = -1 }, .{ .x = -1, .y = 1, .z = -1 },
    .{ .x = -1, .y = -1, .z = 1 },  .{ .x = 1, .y = -1, .z = 1 },  .{ .x = 1, .y = 1, .z = 1 },  .{ .x = -1, .y = 1, .z = 1 },
};
const cube_faces = [_][4]u8{ .{ 0, 1, 2, 3 }, .{ 4, 5, 6, 7 }, .{ 0, 1, 5, 4 }, .{ 3, 2, 6, 7 }, .{ 0, 3, 7, 4 }, .{ 1, 2, 6, 5 } };
const gem_verts = [_]V3{
    .{ .x = 1.15, .y = 0, .z = 0 }, .{ .x = -1.15, .y = 0, .z = 0 }, .{ .x = 0, .y = 1.6, .z = 0 },
    .{ .x = 0, .y = -1.6, .z = 0 }, .{ .x = 0, .y = 0, .z = 1.15 }, .{ .x = 0, .y = 0, .z = -1.15 },
};
const gem_faces = [_][3]u8{ .{ 0, 2, 4 }, .{ 4, 2, 1 }, .{ 1, 2, 5 }, .{ 5, 2, 0 }, .{ 0, 3, 4 }, .{ 4, 3, 1 }, .{ 1, 3, 5 }, .{ 5, 3, 0 } };

fn drawSaveIcon(cx: f32, cy: f32, size: f32, spin: f32, info: SaveInfo, alpha: f32) void {
    const yaw = spin;
    const pitch: f32 = -0.42;
    var pts: [8]V3 = undefined;
    const verts: []const V3 = if (info.shape == .cube) &cube_verts else &gem_verts;
    for (verts, 0..) |v, i| {
        const s = 0.62 * size;
        const x1 = v.x * @cos(yaw) - v.z * @sin(yaw);
        const z1 = v.x * @sin(yaw) + v.z * @cos(yaw);
        const y2 = v.y * @cos(pitch) - z1 * @sin(pitch);
        const z2 = v.y * @sin(pitch) + z1 * @cos(pitch);
        pts[i] = .{ .x = x1 * s, .y = y2 * s, .z = z2 * s };
    }
    const light = norm3(.{ .x = -0.45, .y = 0.75, .z = -0.55 });
    const base = hsv(info.hue, 0.6, 1);
    addGlow(cx, cy, size * 1.5, size * 1.5, base, 0.16 * alpha);
    if (info.shape == .cube) {
        for (cube_faces) |f| drawFace(&pts, &f, cx, cy, base, light, alpha);
    } else {
        for (gem_faces) |f| drawFace(&pts, &f, cx, cy, base, light, alpha);
    }
}

fn drawFace(pts: []const V3, face: []const u8, cx: f32, cy: f32, base: Color, light: V3, alpha: f32) void {
    var n = cross3(sub3(pts[face[1]], pts[face[0]]), sub3(pts[face[2]], pts[face[0]]));
    var centroid: V3 = .{ .x = 0, .y = 0, .z = 0 };
    for (face) |i| {
        centroid.x += pts[i].x;
        centroid.y += pts[i].y;
        centroid.z += pts[i].z;
    }
    if (dot3(n, centroid) < 0) n = .{ .x = -n.x, .y = -n.y, .z = -n.z };
    // The viewer looks along +z, so faces pointing at -z are visible.
    if (n.z >= 0) return;
    n = norm3(n);
    const lambert = @max(0, dot3(n, light));
    const c = mix(scale(base, 0.28), mix(base, C_TEXT, 0.25), lambert);
    var poly: [4]Pt = undefined;
    for (face, 0..) |i, k| poly[k] = .{ .x = cx + pts[i].x, .y = cy - pts[i].y };
    fillPoly(poly[0..face.len], c, alpha * 0.96);
}

// ---- System configuration --------------------------------------------------------

fn settingLabel(s: Setting) S {
    return switch (s) {
        .language => .language,
        .accent => .accent,
        .ambient => .ambient,
        .hints => .hints,
        .info => .info,
    };
}

fn settingValue(s: Setting) []const u8 {
    return switch (s) {
        .language => language_names[@intFromEnum(state.lang)],
        .accent => tr(([_]S{ .blue, .violet, .teal })[state.accent]),
        .ambient => tr(if (state.ambient) .on else .off),
        .hints => tr(if (state.hints) .shown else .hidden),
        .info => "",
    };
}

fn drawSystem() void {
    drawTitle(tr(.system), null);
    const a = accent();
    const hy = ROW_Y + state.sys_f * (ROW_H + ROW_GAP);
    fillRoundRect(.{ .x = ROW_X, .y = hy, .w = ROW_W, .h = ROW_H }, 14, a, 0.16);
    fillRoundRect(.{ .x = ROW_X, .y = hy + 14, .w = 5, .h = ROW_H - 28 }, 2.5, a, 1);
    addGlow(ROW_X + 40, hy + ROW_H / 2, 160, 34, a, 0.18);

    const vt: f32 = @floatFromInt(now_ms - state.value_change_ms);
    for (0..SETTING_COUNT) |i| {
        const r = settingRect(i);
        const setting: Setting = @enumFromInt(i);
        const selected = i == state.sys_sel;
        const baseline = r.y + r.h / 2 + 10;
        drawText(tr(settingLabel(setting)), r.x + 32, baseline, 28, if (selected) C_TEXT else C_DIM, 1);
        const right = r.x + r.w - 32;
        if (setting == .info) {
            drawChevron(right - 6, r.y + r.h / 2, 9, 1, if (selected) C_TEXT else C_DIM, 1);
            continue;
        }
        const value = settingValue(setting);
        const vw = textWidth(value, 26);
        var dx: f32 = 0;
        var va: f32 = 1;
        if (selected and vt < 260) {
            const e = easeOut(vt / 260);
            dx = state.value_dir * 26 * (1 - e);
            va = e;
        }
        const vx = right - 34 - vw + dx;
        drawText(value, vx, baseline, 26, if (selected) C_TEXT else C_DIM, va);
        if (selected) {
            drawChevron(right - 6, r.y + r.h / 2, 9, 1, a, 1);
            drawChevron(right - 34 - vw - 26, r.y + r.h / 2, 9, -1, a, 1);
        }
    }
}

// ---- Overlays --------------------------------------------------------------------

fn drawPanel(p: Rect, alpha: f32) void {
    fillRoundRect(.{ .x = p.x - 1.5, .y = p.y - 1.5, .w = p.w + 3, .h = p.h + 3 }, 21.5, mix(accent(), C_TEXT, 0.2), 0.45 * alpha);
    fillRoundRectGrad(p, 20, .{ 0x12, 0x1A, 0x34 }, C_PANEL, 0.97 * alpha);
}

fn drawOverlay() void {
    const open = state.overlay_open;
    if (open <= 0.001) return;
    darken(0.5 * open);
    if (state.overlay == .none) return;
    g_alpha = open;
    defer g_alpha = 1;
    const p = overlayPanel();
    drawPanel(p, 1);
    const a = accent();
    switch (state.overlay) {
        .none => {},
        .options => {
            drawText(catalog[selectedSaveId()].title, p.x + 32, p.y + 58, 28, C_TEXT, 1);
            const hy = optionRect(0).y + state.overlay_f * 62;
            fillRoundRect(.{ .x = p.x + 24, .y = hy, .w = p.w - 48, .h = 54 }, 12, a, 0.22);
            const labels = [3]S{ .copy, .delete, .cancel };
            for (labels, 0..) |l, i| {
                const r = optionRect(i);
                drawText(tr(l), r.x + 24, r.y + 37, 26, if (i == state.overlay_sel) C_TEXT else C_DIM, 1);
            }
        },
        .confirm => {
            drawTextCentered(tr(.confirm_delete), p.x + p.w / 2, p.y + 66, 28, C_TEXT, 1);
            drawTextCentered(catalog[selectedSaveId()].title, p.x + p.w / 2, p.y + 102, 22, C_DIM, 1);
            const labels = [2]S{ .yes, .no };
            for (labels, 0..) |l, i| {
                const r = confirmButtonRect(i);
                const near = std.math.clamp(1 - @abs(state.overlay_f - @as(f32, @floatFromInt(i))), 0, 1);
                fillRoundRect(r, 14, a, 0.1 + 0.25 * near);
                drawTextCentered(tr(l), r.x + r.w / 2, r.y + 38, 26, mix(C_DIM, C_TEXT, near), 1);
            }
        },
        .copying => {
            drawTextCentered(tr(.copying), p.x + p.w / 2, p.y + 64, 28, C_TEXT, 1);
            drawTextCentered(catalog[state.copy_id].title, p.x + p.w / 2, p.y + 100, 22, C_DIM, 1);
            const progress = std.math.clamp(@as(f32, @floatFromInt(now_ms - state.copy_start_ms)) / @as(f32, @floatFromInt(COPY_MS)), 0, 1);
            const bar: Rect = .{ .x = p.x + 48, .y = p.y + 132, .w = p.w - 96, .h = 12 };
            fillRoundRect(bar, 6, .{ 0x22, 0x2A, 0x40 }, 1);
            fillRoundRect(.{ .x = bar.x, .y = bar.y, .w = @max(bar.h, bar.w * progress), .h = bar.h }, 6, a, 1);
            addGlow(bar.x + bar.w * progress, bar.y + 6, 30, 14, a, 0.6);
        },
        .info => {
            drawText(tr(.info), p.x + 36, p.y + 64, 30, C_TEXT, 1);
            const rows = 4;
            for (0..rows) |i| {
                const y = p.y + 124 + @as(f32, @floatFromInt(i)) * 46;
                var value: TextBuf = .{};
                const label: []const u8 = switch (i) {
                    0 => blk: {
                        value.add("2.00");
                        break :blk tr(.version);
                    },
                    1 => blk: {
                        value.add("960 × 720");
                        break :blk tr(.resolution);
                    },
                    2 => blk: {
                        cardSummary(&value, &state.cards[0]);
                        break :blk tr(.card1);
                    },
                    else => blk: {
                        cardSummary(&value, &state.cards[1]);
                        break :blk tr(.card2);
                    },
                };
                drawText(label, p.x + 36, y, 22, C_DIM, 1);
                drawText(value.slice(), p.x + p.w - 36 - textWidth(value.slice(), 22), y, 22, C_TEXT, 1);
            }
        },
    }
}

fn drawToast() void {
    const t = state.toast orelse return;
    const age: f32 = @floatFromInt(now_ms - t.start_ms);
    const fade_in = std.math.clamp(age / 180, 0, 1);
    const fade_out = std.math.clamp((@as(f32, @floatFromInt(TOAST_MS)) - age) / 300, 0, 1);
    const alpha = @min(fade_in, fade_out);
    const text = tr(t.text);
    const w = textWidth(text, 24) + 64;
    const y = FOOTER_Y - 88 + (1 - easeOut(fade_in)) * 16;
    const r: Rect = .{ .x = (WF - w) / 2, .y = y - 28, .w = w, .h = 56 };
    fillRoundRect(r, 28, mix(accent(), C_TEXT, 0.2), 0.4 * alpha);
    fillRoundRect(.{ .x = r.x + 1.5, .y = r.y + 1.5, .w = r.w - 3, .h = r.h - 3 }, 26.5, C_PANEL, 0.95 * alpha);
    drawTextCentered(text, WF / 2, y + 9, 24, C_TEXT, alpha);
}

fn drawFooter() void {
    var buf: [3]FooterItem = undefined;
    const items = footerItems(&buf);
    for (items, 0..) |item, i| {
        const r = footerItemRect(items, i);
        const bx = r.x + 6 + 17;
        drawBadge(item.badge, bx, FOOTER_Y);
        drawText(tr(item.label), bx + 27, FOOTER_Y + 9, FOOTER_PX, C_DIM, 1);
    }
}

fn drawBadge(badge: Badge, cx: f32, cy: f32) void {
    fillCircle(cx, cy, 16, .{ 0x1A, 0x22, 0x38 }, 1);
    strokeRing(cx, cy, 15.5, 1.5, .{ 0x4A, 0x56, 0x74 }, 1);
    switch (badge) {
        .cross => {
            const c: Color = .{ 0x86, 0xAE, 0xFF };
            strokeSegment(cx - 6.5, cy - 6.5, cx + 6.5, cy + 6.5, 2.6, c, 1);
            strokeSegment(cx - 6.5, cy + 6.5, cx + 6.5, cy - 6.5, 2.6, c, 1);
        },
        .circle => strokeRing(cx, cy, 7.5, 2.6, .{ 0xFF, 0x74, 0x82 }, 1),
        .arrows => {
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
    const sep: []const u8 = switch (state.lang) {
        .en => ",",
        .fr => " ",
        .de, .es, .it => ".",
    };
    if (value >= 1000) {
        out.addDigits(value / 1000, 1);
        out.add(sep);
        out.addDigits(value % 1000, 3);
    } else {
        out.addDigits(value, 1);
    }
}

// ---- Glyphs ----------------------------------------------------------------------
// Only the glyphs the menu can draw are copied out of the font.

const Glyph = struct { codepoint: u21, advance: f32, path: []const u8, index: usize };

const extra_text = "0123456789 ,.·×&/:()…’?¿";

fn hasCodepoint(list: []const u21, cp: u21) bool {
    for (list) |c| if (c == cp) return true;
    return false;
}

const glyph_codepoints = blk: {
    @setEvalBranchQuota(2_000_000);
    var list: []const u21 = &.{};
    var all: []const []const u8 = &.{ extra_text };
    for (strings) |row| {
        for (row) |s| all = all ++ [_][]const u8{s};
    }
    for (language_names) |s| all = all ++ [_][]const u8{s};
    for (catalog) |c| all = all ++ [_][]const u8{ c.title, c.date };
    for (all) |s| {
        var it = std.unicode.Utf8View.initComptime(s).iterator();
        while (it.nextCodepoint()) |cp| {
            if (!hasCodepoint(list, cp)) list = list ++ [_]u21{cp};
        }
    }
    break :blk list[0..list.len].*;
};

const glyphs = blk: {
    @setEvalBranchQuota(2_000_000);
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

test "every label in every language has its glyphs" {
    for (strings) |row| {
        for (row) |s| {
            var it = (try std.unicode.Utf8View.init(s)).iterator();
            while (it.nextCodepoint()) |cp| try std.testing.expect(glyphFor(cp) != null);
        }
    }
}

test "copying a save fills the other card after the progress bar" {
    resetForTest();
    keyUpdate(XK_RETURN); // Browser
    keyUpdate(XK_RETURN); // Memory card 1
    try std.testing.expectEqual(Screen.card, state.screen);
    keyUpdate(XK_RIGHT);
    keyUpdate(XK_RIGHT);
    keyUpdate(XK_RIGHT);
    keyUpdate(XK_RIGHT); // Tidebreaker, 2,048 KB
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(Overlay.options, state.overlay);
    keyUpdate(XK_RETURN); // Copy
    try std.testing.expectEqual(Overlay.copying, state.overlay);
    const free_before = state.cards[1].freeKb();
    idle(COPY_MS + 32);
    try std.testing.expectEqual(Overlay.none, state.overlay);
    try std.testing.expectEqual(@as(u8, 3), state.cards[1].len);
    try std.testing.expectEqual(free_before - 2048, state.cards[1].freeKb());
    // A second copy is refused.
    keyUpdate(XK_RETURN);
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(Overlay.none, state.overlay);
    try std.testing.expectEqual(S.already, state.toast.?.text);
}

test "deleting asks first and keeps the selection on the card" {
    resetForTest();
    keyUpdate(XK_RETURN);
    keyUpdate(XK_RIGHT); // Slot 2
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(@as(u8, 1), state.card_slot);
    keyUpdate(XK_RIGHT);
    keyUpdate(XK_RETURN);
    keyUpdate(XK_DOWN); // Delete
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(Overlay.confirm, state.overlay);
    try std.testing.expectEqual(@as(u8, 1), state.overlay_sel); // "No" by default
    keyUpdate(XK_LEFT);
    keyUpdate(XK_RETURN);
    try std.testing.expectEqual(@as(u8, 1), state.cards[1].len);
    try std.testing.expectEqual(@as(u8, 0), state.card_sel[1]);
    keyUpdate(XK_ESCAPE);
    keyUpdate(XK_ESCAPE);
    try std.testing.expectEqual(Screen.main, state.screen);
}

test "the menu settles and stops asking for frames when motion is off" {
    resetForTest();
    keyUpdate(XK_DOWN);
    keyUpdate(XK_RETURN); // System Configuration
    keyUpdate(XK_DOWN);
    keyUpdate(XK_DOWN); // Background Motion
    keyUpdate(XK_RIGHT);
    try std.testing.expect(!state.ambient);
    idle(1000);
    begin_update_at(committed_at_ms + 16);
    try std.testing.expectEqual(now_ms, finish_update());
}

test "language changes the labels and number separators" {
    resetForTest();
    keyUpdate(XK_DOWN);
    keyUpdate(XK_RETURN);
    keyUpdate(XK_RIGHT); // Français
    try std.testing.expectEqualStrings("Configuration système", tr(.system));
    var t: TextBuf = .{};
    addThousands(&t, 3932);
    try std.testing.expectEqualStrings("3 932", t.slice());
}
