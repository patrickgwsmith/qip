//! Case viewer for QIP Compliance oracles.
//!
//! Input is the bytes of a `*.comply.wasm` oracle. The viewer runs the
//! oracle's `comply()` export in the qipdb interpreter and answers its `qip.*`
//! bridge imports itself, so it needs no implementation. It records the input
//! and expected output of each `must_render_exactly`, `must_trap`, and
//! `must_reject` case. `must_render_into` cases check output inside the oracle,
//! so they have no fixed expected output; the viewer counts and skips them.
//!
//! The optional `seed` uniform is passed to the oracle's `uniform_set_seed`.
//! The oracle runs in instruction chunks across timed updates, so the list
//! fills while a large suite loads.

const std = @import("std");
const interpreter = @import("wasm_interpreter");

const INPUT_CAP: usize = interpreter.MAX_MODULE_BYTES;
const OUTPUT_CAP: usize = 512 * 1024;
const MAX_CASES: usize = 65536;
const ARENA_CAP: usize = 16 * 1024 * 1024;
const MAX_UNIFORM_EVENTS: usize = 4096;
const DETAIL_CAP: usize = 1024 * 1024;
const MAX_DETAIL_LINES: usize = 32768;
const CHUNK_INSTRUCTIONS: usize = 4_000_000;
const SETTER_INSTRUCTIONS: usize = 1_000_000;
const OUTPUT_CONTENT_TYPE = "text/plain";

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const XK_UP: i32 = 0xff52;
const XK_DOWN: i32 = 0xff54;
const XK_PAGE_UP: i32 = 0xff55;
const XK_PAGE_DOWN: i32 = 0xff56;
const XK_HOME: i32 = 0xff50;
const XK_END: i32 = 0xff57;

const SGR_RESET = "\x1b[0m";
const SGR_BOLD = "\x1b[1m";
const SGR_DIM = "\x1b[2m";
const SGR_SELECTED = "\x1b[1;96m";
const SGR_LABEL = "\x1b[1;93m";
const SGR_ERROR = "\x1b[1;91m";
const SGR_WARNING = "\x1b[93m";
const SGR_LOADING = "\x1b[96m";
const SGR_DONE = "\x1b[92m";
const SGR_ESCAPE = "\x1b[35m";

const Kind = enum(u8) {
    exact,
    trap,
    reject,

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .exact => "exact",
            .trap => "trap",
            .reject => "reject",
        };
    }

    fn bridgeName(self: Kind) []const u8 {
        return switch (self) {
            .exact => "must_render_exactly",
            .trap => "must_trap",
            .reject => "must_reject",
        };
    }
};

const Span = struct {
    offset: u32 = 0,
    len: u32 = 0,
};

const Case = struct {
    ordinal: u64,
    kind: Kind,
    input: Span,
    expected: Span,
    /// Number of uniform events applied before this case.
    uniform_events: u32,
};

const UniformEvent = struct {
    name: Span,
    value: u32,
};

const Phase = enum { initial, ready, updating };
const RunState = enum { idle, loading, done, limit, failed };

var input_buf: [INPUT_CAP]u8 = undefined;
var input_len: usize = 0;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var detail_buf: [DETAIL_CAP]u8 = undefined;
var detail_lines: [MAX_DETAIL_LINES]Span = undefined;
var arena: [ARENA_CAP]u8 = undefined;
var arena_len: usize = 0;
var cases: [MAX_CASES]Case = undefined;
var case_count: usize = 0;
var uniform_events: [MAX_UNIFORM_EVENTS]UniformEvent = undefined;
var uniform_event_count: usize = 0;
var machine: interpreter.Machine = undefined;

var phase: Phase = .initial;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var columns: usize = 80;
var lines: usize = 24;

var run_state: RunState = .idle;
var failure: []const u8 = "";
var failure_buf: [256]u8 = undefined;
var next_ordinal: u64 = 0;
var open_render_into: ?u64 = null;
var skipped_render_into: u64 = 0;
var declared_cases: ?u32 = null;
var instructions_run: u64 = 0;
var oracle_has_seed = false;
var requested_seed: u32 = 0;
var seed_requested = false;
var seed_step: i64 = 0;
var loaded_seed: ?u32 = null;

var selected: usize = 0;
var list_top: usize = 0;
var detail_offset: usize = 0;
var hex_view = false;
var help_visible = false;

// ---------------------------------------------------------------------------
// Content and Time and Events exports

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn uniform_set_columns(value: u32) u32 {
    columns = @max(20, @min(value, 400));
    return @intCast(columns);
}

export fn uniform_set_lines(value: u32) u32 {
    lines = @max(6, @min(value, 200));
    return @intCast(lines);
}

/// Seed passed to the oracle's `uniform_set_seed`. Without it, the oracle uses
/// its own default seed.
export fn uniform_set_seed(value: u32) u32 {
    requested_seed = value;
    seed_requested = true;
    return value;
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    return if (handleKey(x11_key, flags)) 1 else 0;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    if (run_state == .idle and input_len > 0) startRun();
    if (run_state == .loading) runChunk(CHUNK_INSTRUCTIONS);
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return if (run_state == .loading) committed_at_ms + 1 else committed_at_ms;
}

export fn render(size: u32) packed struct(u64) { output_size: u32, output_ptr: u31, failed: u1 } {
    if (phase == .updating or size > INPUT_CAP) @trap();
    if (phase == .initial) {
        input_len = size;
        phase = .ready;
        startRun();
    } else if (effectiveSeed() != loaded_seed and oracle_has_seed) {
        startRun();
    }
    const length = draw();
    return .{ .output_size = @intCast(length), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

/// Number of recorded cases, for hosts and tests.
export fn case_total() u32 {
    return @intCast(case_count);
}

/// 1 while the oracle is still running.
export fn loading() u32 {
    return if (run_state == .loading) 1 else 0;
}

// ---------------------------------------------------------------------------
// Running the oracle

fn effectiveSeed() ?u32 {
    if (!seed_requested and seed_step == 0) return null;
    const base: i64 = requested_seed;
    return @truncate(@as(u64, @bitCast(base + seed_step)));
}

fn fail(comptime format: []const u8, args: anytype) void {
    failure = std.fmt.bufPrint(&failure_buf, format, args) catch "oracle failed";
    run_state = .failed;
}

fn startRun() void {
    arena_len = 0;
    case_count = 0;
    uniform_event_count = 0;
    next_ordinal = 0;
    open_render_into = null;
    skipped_render_into = 0;
    declared_cases = null;
    instructions_run = 0;
    selected = 0;
    list_top = 0;
    detail_offset = 0;
    failure = "";
    run_state = .loading;

    if (input_len == 0) return fail("No input. Pass a Compliance oracle such as -i name.comply.wasm.", .{});
    machine.loadWithOptions(input_buf[0..input_len], &.{}, .{ .function_imports = true, .render = false }) catch |err| {
        return fail("Could not load the oracle: {s}", .{@errorName(err)});
    };
    for (0..machine.import_count) |index| {
        const name = machine.importName(@intCast(index)).?;
        if (!std.mem.eql(u8, name.module, "qip")) {
            return fail("Unsupported import {s}.{s}; oracles import only from \"qip\".", .{ name.module, name.name });
        }
    }
    if (!machine.hasFunctionExport("comply")) return fail("The module does not export comply() -> i32.", .{});

    oracle_has_seed = machine.hasFunctionExport("uniform_set_seed");
    const seed = effectiveSeed();
    loaded_seed = seed;
    if (seed) |value| if (oracle_has_seed) {
        machine.beginExport("uniform_set_seed", &.{value}) catch |err| {
            return fail("Could not call uniform_set_seed: {s}", .{@errorName(err)});
        };
        machine.continueFor(SETTER_INSTRUCTIONS);
        if (machine.status != .halted) return fail("uniform_set_seed did not finish.", .{});
    };
    machine.beginExport("comply", &.{}) catch |err| {
        return fail("Could not call comply(): {s}", .{@errorName(err)});
    };
}

fn runChunk(budget: usize) void {
    var remaining = budget;
    while (run_state == .loading) {
        const before = machine.counters.instructions;
        machine.continueFor(remaining);
        const used: usize = @intCast(machine.counters.instructions - before);
        instructions_run += used;
        remaining -|= used;
        switch (machine.status) {
            .awaiting_host => handleHostCall(),
            .halted => return finishRun(),
            .trapped => return fail("comply() trapped at case {d}: {s}", .{ next_ordinal, interpreter.trapName(machine.trap) }),
            .ready, .empty => return,
        }
        if (remaining == 0) return;
    }
}

fn finishRun() void {
    if (open_render_into) |ordinal| return fail("comply() returned with must_render_into case {d} still open.", .{ordinal});
    const declared: i32 = @bitCast(@as(u32, @truncate(machine.result)));
    if (declared <= 0) return fail("comply() declared no cases (returned {d}).", .{declared});
    declared_cases = @intCast(declared);
    if (@as(u64, @intCast(declared)) != next_ordinal) {
        return fail("comply() returned {d} cases but the bridge counted {d}.", .{ declared, next_ordinal });
    }
    run_state = .done;
}

fn arg(index: usize) u64 {
    const args = machine.host_call.args();
    return if (index < args.len) @truncate(args[index]) else 0;
}

fn arg32(index: usize) u32 {
    return @truncate(arg(index));
}

fn oracleBytes(ptr: u32, len: u32) ?[]const u8 {
    const end = @as(u64, ptr) + len;
    if (end > machine.memory_size) return null;
    return machine.memory[ptr..@intCast(end)];
}

fn store(bytes: []const u8) ?Span {
    if (bytes.len > ARENA_CAP - arena_len) return null;
    const span = Span{ .offset = @intCast(arena_len), .len = @intCast(bytes.len) };
    @memcpy(arena[arena_len..][0..bytes.len], bytes);
    arena_len += bytes.len;
    return span;
}

fn spanBytes(span: Span) []const u8 {
    return arena[span.offset..][0..span.len];
}

fn resumeOracle(value: ?u32) void {
    machine.resumeHostCall(if (value) |v| @as(interpreter.Value, v) else null) catch |err| {
        fail("Could not resume the oracle: {s}", .{@errorName(err)});
    };
}

fn handleHostCall() void {
    const name = machine.importName(machine.host_call.function_index).?.name;
    if (std.mem.eql(u8, name, "must_render_exactly")) {
        recordCase(.exact, arg32(1), arg32(2), arg32(3), arg32(4), true);
    } else if (std.mem.eql(u8, name, "must_trap")) {
        recordCase(.trap, arg32(1), arg32(2), 0, 0, false);
    } else if (std.mem.eql(u8, name, "must_reject")) {
        recordCase(.reject, arg32(1), arg32(2), 0, 0, false);
    } else if (std.mem.eql(u8, name, "must_render_into")) {
        const ordinal = arg(0);
        if (!caseOpen(ordinal, name)) return;
        open_render_into = ordinal;
        // The viewer has no implementation, so report a failed render. The
        // oracle then emits an error and finishes the case.
        resumeOracle(0xffff_ffff);
    } else if (std.mem.eql(u8, name, "must_render_into_emit_error")) {
        if (open_render_into != arg(0)) return fail("must_render_into_emit_error for case {d} does not match the open case.", .{arg(0)});
        resumeOracle(1);
    } else if (std.mem.eql(u8, name, "must_render_into_finish")) {
        if (open_render_into != arg(0)) return fail("must_render_into_finish for case {d} does not match the open case.", .{arg(0)});
        open_render_into = null;
        next_ordinal += 1;
        skipped_render_into += 1;
        resumeOracle(1);
    } else if (std.mem.eql(u8, name, "set_uniform_u32")) {
        recordUniform(arg32(0), arg32(1), arg32(2));
    } else {
        fail("Unsupported bridge import qip.{s}.", .{name});
    }
}

fn caseOpen(ordinal: u64, name: []const u8) bool {
    if (open_render_into) |open| {
        fail("{s} for case {d} inside open must_render_into case {d}.", .{ name, ordinal, open });
        return false;
    }
    if (ordinal != next_ordinal) {
        fail("{s} declared case {d}; expected case {d}.", .{ name, ordinal, next_ordinal });
        return false;
    }
    return true;
}

fn recordCase(kind: Kind, in_ptr: u32, in_len: u32, exp_ptr: u32, exp_len: u32, has_expected: bool) void {
    const ordinal = arg(0);
    if (!caseOpen(ordinal, kind.bridgeName())) return;
    const input = oracleBytes(in_ptr, in_len) orelse return fail("Case {d} input is outside oracle memory.", .{ordinal});
    const expected = if (has_expected)
        oracleBytes(exp_ptr, exp_len) orelse return fail("Case {d} expected output is outside oracle memory.", .{ordinal})
    else
        &.{};
    if (case_count == MAX_CASES) {
        run_state = .limit;
        return;
    }
    const input_span = store(input) orelse {
        run_state = .limit;
        return;
    };
    const expected_span = store(expected) orelse {
        run_state = .limit;
        return;
    };
    cases[case_count] = .{
        .ordinal = ordinal,
        .kind = kind,
        .input = input_span,
        .expected = expected_span,
        .uniform_events = @intCast(uniform_event_count),
    };
    case_count += 1;
    next_ordinal += 1;
    resumeOracle(1);
}

fn recordUniform(name_ptr: u32, name_len: u32, value: u32) void {
    if (open_render_into) |open| return fail("set_uniform_u32 inside open must_render_into case {d}.", .{open});
    if (name_len == 0 or name_len > 128) return fail("set_uniform_u32 name length {d} is outside 1..128.", .{name_len});
    const name = oracleBytes(name_ptr, name_len) orelse return fail("set_uniform_u32 name is outside oracle memory.", .{});
    // Oracles often reapply the same value before each case; record changes only.
    var index = uniform_event_count;
    while (index > 0) {
        index -= 1;
        const event = uniform_events[index];
        if (!std.mem.eql(u8, spanBytes(event.name), name)) continue;
        if (event.value == value) return resumeOracle(value);
        break;
    }
    if (uniform_event_count == MAX_UNIFORM_EVENTS) {
        run_state = .limit;
        return;
    }
    const span = store(name) orelse {
        run_state = .limit;
        return;
    };
    uniform_events[uniform_event_count] = .{ .name = span, .value = value };
    uniform_event_count += 1;
    // An implementation returns the applied value; echo it so the oracle continues.
    resumeOracle(value);
}

// ---------------------------------------------------------------------------
// Keys

fn listRows() usize {
    // Header, column labels, divider, detail, and footer share the screen.
    const usable = lines -| 4;
    return @max(1, usable - detailRows());
}

fn detailRows() usize {
    const usable = lines -| 4;
    return @max(1, usable * 11 / 20);
}

fn handleKey(key: i32, flags: i32) bool {
    if (help_visible) {
        help_visible = false;
        return true;
    }
    const old_selected = selected;
    const old_offset = detail_offset;
    const page = listRows();
    const shift = (flags & FLAG_SHIFT) != 0;
    const last = case_count -| 1;
    switch (key) {
        XK_UP => if (shift) {
            detail_offset -|= 1;
        } else {
            selected -|= 1;
        },
        XK_DOWN => if (shift) {
            detail_offset += 1;
        } else {
            selected = @min(selected + 1, last);
        },
        'k' => selected -|= 1,
        'j' => selected = @min(selected + 1, last),
        'K' => detail_offset -|= 1,
        'J' => detail_offset += 1,
        XK_PAGE_UP => selected -|= page,
        XK_PAGE_DOWN => selected = @min(selected + page, last),
        XK_HOME, 'g' => selected = 0,
        XK_END, 'G' => selected = last,
        'x' => {
            hex_view = !hex_view;
            detail_offset = 0;
            return true;
        },
        '+', '=', '-' => {
            if (!oracle_has_seed) return false;
            if (key == '-') seed_step -= 1 else seed_step += 1;
            startRun();
            return true;
        },
        '?' => {
            help_visible = true;
            return true;
        },
        else => return false,
    }
    if (selected != old_selected) detail_offset = 0;
    return selected != old_selected or detail_offset != old_offset;
}

// ---------------------------------------------------------------------------
// Drawing

const Writer = struct {
    buffer: []u8,
    offset: usize = 0,

    fn raw(self: *Writer, value: []const u8) void {
        const amount = @min(value.len, self.buffer.len - self.offset);
        @memcpy(self.buffer[self.offset..][0..amount], value[0..amount]);
        self.offset += amount;
    }

    fn print(self: *Writer, comptime format: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(self.buffer[self.offset..], format, args) catch return;
        self.offset += rendered.len;
    }

    fn styled(self: *Writer, style: []const u8, value: []const u8) void {
        self.raw(style);
        self.raw(value);
        self.raw(SGR_RESET);
    }
};

/// Writes text clipped to a column budget. Returns the columns used. Each code
/// point counts as one column; wide characters can overflow by their width.
fn clipped(w: *Writer, text: []const u8, budget: usize) usize {
    var used: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = @min(text.len - index, std.unicode.utf8ByteSequenceLength(text[index]) catch 1);
        const sequence = text[index..][0..length];
        const code_point = std.unicode.utf8Decode(sequence) catch 0;
        const width = codePointWidth(code_point);
        if (used + width > budget) break;
        w.raw(sequence);
        index += length;
        used += width;
    }
    return used;
}

fn pad(w: *Writer, count: usize) void {
    for (0..count) |_| w.raw(" ");
}

fn groupedNumber(buffer: []u8, value: u64) []const u8 {
    var digits: [32]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "?";
    var out: usize = 0;
    for (plain, 0..) |digit, index| {
        if (index != 0 and (plain.len - index) % 3 == 0) {
            buffer[out] = ',';
            out += 1;
        }
        buffer[out] = digit;
        out += 1;
    }
    return buffer[0..out];
}

fn byteSize(buffer: []u8, value: usize) []const u8 {
    if (value < 10 * 1024) return std.fmt.bufPrint(buffer, "{d} B", .{value}) catch "?";
    if (value < 10 * 1024 * 1024) return std.fmt.bufPrint(buffer, "{d} KiB", .{value / 1024}) catch "?";
    return std.fmt.bufPrint(buffer, "{d} MiB", .{value / (1024 * 1024)}) catch "?";
}

/// How one code point appears on screen.
const Visible = union(enum) {
    text: []const u8,
    escape: []const u8,
    newline,
};

fn isEscapedCodePoint(code_point: u21) bool {
    return code_point < 0x20 or (code_point >= 0x7f and code_point <= 0x9f) or
        (code_point >= 0x200b and code_point <= 0x200f) or
        (code_point >= 0x202a and code_point <= 0x202e) or
        (code_point >= 0x2066 and code_point <= 0x2069) or
        (code_point >= 0xfdd0 and code_point <= 0xfdef) or
        (code_point & 0xfffe) == 0xfffe or code_point == 0xfeff;
}

/// Iterates UTF-8 text as visible units. Controls become control pictures,
/// and other invisible or terminal-unsafe code points become ⟨U+XXXX⟩.
const VisibleIterator = struct {
    bytes: []const u8,
    index: usize = 0,
    scratch: [16]u8 = undefined,

    fn next(self: *VisibleIterator) ?Visible {
        if (self.index >= self.bytes.len) return null;
        const length = std.unicode.utf8ByteSequenceLength(self.bytes[self.index]) catch unreachable;
        const sequence = self.bytes[self.index..][0..length];
        self.index += length;
        const code_point = std.unicode.utf8Decode(sequence) catch unreachable;
        if (code_point == '\n') return .newline;
        if (!isEscapedCodePoint(code_point)) return .{ .text = sequence };
        if (code_point < 0x20 or code_point == 0x7f) {
            const picture: u21 = if (code_point == 0x7f) 0x2421 else 0x2400 + code_point;
            const picture_length = std.unicode.utf8Encode(picture, &self.scratch) catch unreachable;
            return .{ .escape = self.scratch[0..picture_length] };
        }
        return .{ .escape = std.fmt.bufPrint(&self.scratch, "⟨U+{X:0>4}⟩", .{code_point}) catch unreachable };
    }
};

/// Approximate terminal columns for one code point: zero for combining marks,
/// two for East Asian wide characters and most emoji, otherwise one.
fn codePointWidth(code_point: u21) usize {
    if ((code_point >= 0x0300 and code_point <= 0x036f) or (code_point >= 0x1ab0 and code_point <= 0x1aff) or
        (code_point >= 0x20d0 and code_point <= 0x20ff) or (code_point >= 0xfe00 and code_point <= 0xfe0f) or
        (code_point >= 0xfe20 and code_point <= 0xfe2f)) return 0;
    if ((code_point >= 0x1100 and code_point <= 0x115f) or (code_point >= 0x2e80 and code_point <= 0xa4cf) or
        (code_point >= 0xac00 and code_point <= 0xd7a3) or (code_point >= 0xf900 and code_point <= 0xfaff) or
        (code_point >= 0xfe30 and code_point <= 0xfe4f) or (code_point >= 0xff00 and code_point <= 0xff60) or
        (code_point >= 0xffe0 and code_point <= 0xffe6) or (code_point >= 0x1f300 and code_point <= 0x1f64f) or
        (code_point >= 0x1f900 and code_point <= 0x1faff) or (code_point >= 0x20000 and code_point <= 0x3fffd)) return 2;
    return 1;
}

fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return text.len;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |code_point| width += codePointWidth(code_point);
    return width;
}

fn unitWidth(unit: Visible) usize {
    return switch (unit) {
        .text => |text| textWidth(text),
        .escape => |text| textWidth(text),
        .newline => 1,
    };
}

/// Writes a one-line preview of case bytes.
fn preview(w: *Writer, bytes: []const u8, budget: usize) usize {
    if (budget == 0) return 0;
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        var used: usize = 0;
        w.raw(SGR_DIM);
        for (bytes) |byte| {
            if (used + 3 > budget) break;
            if (used != 0) w.raw(" ");
            w.print("{x:0>2}", .{byte});
            used += if (used == 0) 2 else 3;
        }
        w.raw(SGR_RESET);
        return used;
    }
    if (bytes.len == 0) {
        w.styled(SGR_DIM, "(empty)"[0..@min(7, budget)]);
        return @min(7, budget);
    }
    var total: usize = 0;
    var measure = VisibleIterator{ .bytes = bytes };
    while (measure.next()) |unit| {
        total += unitWidth(unit);
        if (total > budget) break;
    }
    const limit = if (total > budget) budget - 1 else budget;
    var used: usize = 0;
    var iterator = VisibleIterator{ .bytes = bytes };
    while (iterator.next()) |unit| {
        const text, const style = switch (unit) {
            .text => |text| .{ text, "" },
            .escape => |text| .{ text, SGR_ESCAPE },
            .newline => .{ "␊", SGR_ESCAPE },
        };
        const width = unitWidth(unit);
        if (used + width > limit) break;
        if (style.len > 0) w.styled(style, text) else w.raw(text);
        used += width;
    }
    if (total > budget) {
        w.styled(SGR_DIM, "…");
        used += 1;
    }
    return used;
}

/// Builds wrapped detail lines in `detail_buf`.
const DetailBuilder = struct {
    width: usize,
    offset: usize = 0,
    count: usize = 0,
    line_start: usize = 0,
    column: usize = 0,

    fn put(self: *DetailBuilder, bytes: []const u8) void {
        const amount = @min(bytes.len, DETAIL_CAP - self.offset);
        @memcpy(detail_buf[self.offset..][0..amount], bytes[0..amount]);
        self.offset += amount;
    }

    fn endLine(self: *DetailBuilder) void {
        if (self.count < MAX_DETAIL_LINES) {
            detail_lines[self.count] = .{ .offset = @intCast(self.line_start), .len = @intCast(self.offset - self.line_start) };
            self.count += 1;
        }
        self.line_start = self.offset;
        self.column = 0;
    }

    fn full(self: *const DetailBuilder) bool {
        return self.count >= MAX_DETAIL_LINES or self.offset + 64 >= DETAIL_CAP;
    }

    fn line(self: *DetailBuilder, comptime format: []const u8, args: anytype) void {
        var scratch: [512]u8 = undefined;
        self.put(std.fmt.bufPrint(&scratch, format, args) catch "");
        self.endLine();
    }

    /// Appends a unit that occupies `width` columns, wrapping first if needed.
    fn unit(self: *DetailBuilder, style: []const u8, value: []const u8, width: usize) void {
        if (self.column + width > self.width and self.column > 2) {
            self.endLine();
            self.put("  ");
            self.column = 2;
        }
        if (style.len > 0) self.put(style);
        self.put(value);
        if (style.len > 0) self.put(SGR_RESET);
        self.column += width;
    }

    fn wrappedText(self: *DetailBuilder, bytes: []const u8) void {
        self.put("  ");
        self.column = 2;
        var iterator = VisibleIterator{ .bytes = bytes };
        while (iterator.next()) |visible| {
            if (self.full()) break;
            switch (visible) {
                .text => |value| self.unit("", value, textWidth(value)),
                .escape => |value| self.unit(SGR_ESCAPE, value, textWidth(value)),
                .newline => {
                    self.unit(SGR_DIM, "↵", 1);
                    self.endLine();
                    self.put("  ");
                    self.column = 2;
                },
            }
        }
        self.endLine();
    }

    fn hexDump(self: *DetailBuilder, bytes: []const u8) void {
        // "  0000  hh hh …  ascii": 4 columns per byte plus 10 for the offset.
        const per_row = @max(4, ((self.width -| 10) / 4) / 4 * 4);
        var row: usize = 0;
        while (row < bytes.len) : (row += per_row) {
            if (self.full()) break;
            const chunk = bytes[row..@min(bytes.len, row + per_row)];
            var scratch: [16]u8 = undefined;
            self.put(SGR_DIM);
            self.put(std.fmt.bufPrint(&scratch, "  {x:0>6}  ", .{row}) catch "");
            self.put(SGR_RESET);
            for (0..per_row) |index| {
                if (index < chunk.len) {
                    self.put(std.fmt.bufPrint(&scratch, "{x:0>2} ", .{chunk[index]}) catch "");
                } else self.put("   ");
            }
            self.put(" ");
            for (chunk) |byte| {
                if (byte >= 0x20 and byte < 0x7f) self.put(&.{byte}) else self.put("·");
            }
            self.endLine();
        }
        if (bytes.len == 0) self.line("  {s}(empty){s}", .{ SGR_DIM, SGR_RESET });
    }

    fn bytesSection(self: *DetailBuilder, label: []const u8, bytes: []const u8) void {
        var size_buf: [32]u8 = undefined;
        const utf8 = std.unicode.utf8ValidateSlice(bytes);
        const encoding = if (!utf8) "not UTF-8, hex" else if (hex_view) "UTF-8, hex" else "UTF-8";
        self.line("{s}{s}{s} {s}· {s} · {s}{s}", .{ SGR_LABEL, label, SGR_RESET, SGR_DIM, byteSize(&size_buf, bytes.len), encoding, SGR_RESET });
        if (!utf8 or hex_view) {
            self.hexDump(bytes);
        } else if (bytes.len == 0) {
            self.line("  {s}(empty){s}", .{ SGR_DIM, SGR_RESET });
        } else {
            self.wrappedText(bytes);
        }
    }
};

fn buildDetail(case: Case, width: usize) usize {
    var builder = DetailBuilder{ .width = width };
    var number_buf: [32]u8 = undefined;
    builder.put(SGR_BOLD);
    builder.put("Case ");
    builder.put(groupedNumber(&number_buf, case.ordinal));
    builder.put(SGR_RESET);
    builder.put(" · ");
    builder.put(case.kind.bridgeName());
    builder.endLine();
    if (case.uniform_events > 0) {
        builder.put(SGR_DIM);
        builder.put("Uniforms:");
        // Show the latest value of each uniform name applied before this case.
        var shown: usize = 0;
        var index = case.uniform_events;
        while (index > 0 and shown < 8) {
            index -= 1;
            const event = uniform_events[index];
            const name = spanBytes(event.name);
            var seen = false;
            for (uniform_events[index + 1 .. case.uniform_events]) |later| {
                if (std.mem.eql(u8, spanBytes(later.name), name)) seen = true;
            }
            if (seen) continue;
            var value_buf: [16]u8 = undefined;
            builder.put(" ");
            builder.put(name);
            builder.put("=");
            builder.put(std.fmt.bufPrint(&value_buf, "{d}", .{event.value}) catch "?");
            shown += 1;
        }
        builder.put(SGR_RESET);
        builder.endLine();
    }
    builder.bytesSection("Input", spanBytes(case.input));
    switch (case.kind) {
        .exact => builder.bytesSection("Expected output", spanBytes(case.expected)),
        .trap => builder.line("{s}Expected{s} the implementation traps.", .{ SGR_LABEL, SGR_RESET }),
        .reject => builder.line("{s}Expected{s} the implementation rejects the input.", .{ SGR_LABEL, SGR_RESET }),
    }
    return builder.count;
}

fn drawHeader(w: *Writer) void {
    var number_buf: [32]u8 = undefined;
    var used: usize = 0;
    w.raw(SGR_BOLD);
    used += clipped(w, "Compliance cases", columns);
    w.raw(SGR_RESET);
    var scratch: [160]u8 = undefined;
    const count_text = std.fmt.bufPrint(&scratch, "  {s} case{s}", .{ groupedNumber(&number_buf, case_count), if (case_count == 1) "" else "s" }) catch "";
    used += clipped(w, count_text, columns -| used);
    if (oracle_has_seed) {
        const seed_text = if (loaded_seed) |seed|
            std.fmt.bufPrint(&scratch, "  seed {d}", .{seed}) catch ""
        else
            "  default seed";
        used += clipped(w, seed_text, columns -| used);
    } else if (seed_requested and run_state != .failed) {
        w.raw(SGR_WARNING);
        const ignored = std.fmt.bufPrint(&scratch, "  seed {d} ignored: no uniform_set_seed", .{requested_seed}) catch "";
        used += clipped(w, ignored, columns -| used);
        w.raw(SGR_RESET);
    }
    if (skipped_render_into > 0) {
        w.raw(SGR_DIM);
        const skipped = std.fmt.bufPrint(&scratch, "  {s} must_render_into skipped", .{groupedNumber(&number_buf, skipped_render_into)}) catch "";
        used += clipped(w, skipped, columns -| used);
        w.raw(SGR_RESET);
    }
    const status, const style = switch (run_state) {
        .idle, .loading => .{ "  ● running", SGR_LOADING },
        .done => .{ "  ● done", SGR_DONE },
        .limit => .{ "  ● stopped at viewer limit", SGR_WARNING },
        .failed => .{ "  ● failed", SGR_ERROR },
    };
    w.raw(style);
    used += clipped(w, status, columns -| used);
    w.raw(SGR_RESET);
    w.raw("\n");
}

fn ordinalWidth() usize {
    var digits: usize = 1;
    var value: u64 = if (case_count == 0) 0 else cases[case_count - 1].ordinal;
    while (value >= 10) : (value /= 10) digits += 1;
    return @max(4, digits);
}

fn drawList(w: *Writer, rows: usize) void {
    const ordinal_width = ordinalWidth();
    const fixed = 2 + ordinal_width + 2 + 6 + 2;
    const remaining = columns -| fixed;
    const input_width = remaining / 2;
    const expected_width = remaining - input_width -| 2;

    w.raw(SGR_DIM);
    var used: usize = clipped(w, "  #", columns);
    pad(w, (2 + ordinal_width + 2) -| used);
    used = 2 + ordinal_width + 2;
    used += clipped(w, "kind    ", columns -| used);
    used += clipped(w, "input", columns -| used);
    if (expected_width > 0) {
        pad(w, input_width + 2 -| 5);
        _ = clipped(w, "expected", expected_width);
    }
    w.raw(SGR_RESET);
    w.raw("\n");

    if (selected < list_top) list_top = selected;
    if (selected >= list_top + rows) list_top = selected + 1 - rows;
    for (0..rows) |row| {
        const index = list_top + row;
        if (index >= case_count) {
            if (row == 0 and case_count == 0) {
                const message = switch (run_state) {
                    .failed => "",
                    .idle, .loading => "  Running comply()…",
                    else => if (skipped_render_into > 0)
                        "  Every case uses must_render_into, so none have a fixed expected output."
                    else
                        "  No cases.",
                };
                w.raw(SGR_DIM);
                _ = clipped(w, message, columns);
                w.raw(SGR_RESET);
            }
            w.raw("\n");
            continue;
        }
        const case = cases[index];
        const is_selected = index == selected;
        w.raw(if (is_selected) SGR_SELECTED else SGR_DIM);
        w.raw(if (is_selected) "> " else "  ");
        w.print("{d:0>[1]}", .{ case.ordinal, ordinal_width });
        w.raw(SGR_RESET);
        w.raw("  ");
        if (is_selected) w.raw(SGR_BOLD);
        w.raw(case.kind.label());
        pad(w, 6 - case.kind.label().len);
        if (is_selected) w.raw(SGR_RESET);
        w.raw("  ");
        const input_used = preview(w, spanBytes(case.input), input_width);
        if (expected_width > 0) {
            pad(w, input_width + 2 -| input_used);
            switch (case.kind) {
                .exact => _ = preview(w, spanBytes(case.expected), expected_width),
                .trap => w.styled(SGR_DIM, "(must trap)"),
                .reject => w.styled(SGR_DIM, "(must reject)"),
            }
        }
        w.raw("\n");
    }
}

fn drawDetail(w: *Writer, rows: usize) void {
    w.raw(SGR_DIM);
    for (0..columns) |_| w.raw("─");
    w.raw(SGR_RESET);
    w.raw("\n");

    var count: usize = 0;
    if (run_state == .failed) {
        count = 0;
        var builder = DetailBuilder{ .width = columns };
        builder.put(SGR_ERROR);
        builder.put("Error: ");
        builder.put(SGR_RESET);
        builder.put(failure);
        builder.endLine();
        count = builder.count;
    } else if (case_count > 0) {
        count = buildDetail(cases[@min(selected, case_count - 1)], columns);
    }
    detail_offset = @min(detail_offset, count -| rows);
    for (0..rows) |row| {
        const index = detail_offset + row;
        if (index < count) {
            const span = detail_lines[index];
            w.raw(detail_buf[span.offset..][0..span.len]);
        }
        w.raw("\n");
    }
    if (count > rows) {
        // Replace the last row's line break with a scroll hint on the footer.
        detail_more = .{ .first = detail_offset + 1, .last = @min(count, detail_offset + rows), .total = count };
    } else detail_more = null;
}

var detail_more: ?struct { first: usize, last: usize, total: usize } = null;

fn drawFooter(w: *Writer) void {
    w.raw(SGR_DIM);
    var scratch: [160]u8 = undefined;
    var used: usize = 0;
    if (detail_more) |more| {
        const text = std.fmt.bufPrint(&scratch, "lines {d}–{d} of {d}  ", .{ more.first, more.last, more.total }) catch "";
        used += clipped(w, text, columns);
    }
    const keys = if (oracle_has_seed)
        "↑↓ case  PgUp/PgDn page  J/K detail  x hex  +/- seed  ? help"
    else
        "↑↓ case  PgUp/PgDn page  J/K detail  x hex  ? help";
    _ = clipped(w, keys, columns -| used);
    w.raw(SGR_RESET);
}

const HELP_LINES = [_][]const u8{
    SGR_BOLD ++ "Compliance case viewer" ++ SGR_RESET,
    "",
    "Lists the cases that a Compliance oracle declares when comply() runs.",
    "No implementation runs, so the list shows inputs and expected outputs",
    "only. must_render_into cases check output inside the oracle, so they",
    "have no fixed expected output and are skipped.",
    "",
    "  Up/Down, j/k        select a case",
    "  Page Up/Page Down   move a page of cases",
    "  Home/End, g/G       first or last case",
    "  Shift-Up/Down, K/J  scroll the case details",
    "  x                   show text or hex",
    "  + / -               run again with the next or previous seed",
    "  ?                   this help; any key closes it",
    "",
    "Text shows controls as ␀–␟ and other invisible code points as ⟨U+XXXX⟩.",
    "Each line break shows ↵. Bytes that are not UTF-8 always show as hex.",
    "Set a starting seed with -u seed=N.",
};

fn draw() usize {
    var w = Writer{ .buffer = &output_buf };
    if (help_visible) {
        for (HELP_LINES, 0..) |line, index| {
            if (index >= lines) break;
            if (index != 0) w.raw("\n");
            _ = clipped(&w, line, columns + 16);
        }
        return w.offset;
    }
    drawHeader(&w);
    const list_rows = listRows();
    const detail_rows = detailRows();
    drawList(&w, list_rows);
    drawDetail(&w, detail_rows);
    drawFooter(&w);
    return w.offset;
}

// ---------------------------------------------------------------------------
// Tests

test "visible iterator escapes controls and invisible code points" {
    var iterator = VisibleIterator{ .bytes = "a\r\x00\u{0081}\u{202e}\n" };
    try std.testing.expectEqualStrings("a", iterator.next().?.text);
    try std.testing.expectEqualStrings("␍", iterator.next().?.escape);
    try std.testing.expectEqualStrings("␀", iterator.next().?.escape);
    try std.testing.expectEqualStrings("⟨U+0081⟩", iterator.next().?.escape);
    try std.testing.expectEqualStrings("⟨U+202E⟩", iterator.next().?.escape);
    try std.testing.expect(iterator.next().? == .newline);
    try std.testing.expect(iterator.next() == null);
}

test "grouped numbers use thousands separators" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("6,835", groupedNumber(&buffer, 6835));
    try std.testing.expectEqualStrings("12", groupedNumber(&buffer, 12));
    try std.testing.expectEqualStrings("1,000,000", groupedNumber(&buffer, 1_000_000));
}
