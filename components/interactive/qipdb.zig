//! Instruction-step debugger for integer and selected SIMD QIP Content components.
//!
//! Input is `multipart/form-data`: a required `component` file part contains the
//! target `application/wasm` module and an optional `input` part contains exact
//! bytes for its Content call. Its `text/plain` presentation is intentionally
//! useful in a terminal as well as a browser.

const std = @import("std");
const interpreter = @import("wasm_interpreter");
const wasm_counts = @import("wasm_counts");

const MULTIPART_OVERHEAD_CAP: usize = 32 * 1024;
const MAX_TARGET_INPUT_BYTES: usize = 8 * 1024 * 1024;
const INPUT_CAP: usize = interpreter.MAX_MODULE_BYTES + MAX_TARGET_INPUT_BYTES + MULTIPART_OVERHEAD_CAP;
const OUTPUT_CAP: usize = 512 * 1024;
const TYPE_PREFIX = "multipart/form-data;boundary=uuid-";
const DEFAULT_UUID = "00000000-0000-0000-0000-000000000000";
const OUTPUT_CONTENT_TYPE = "text/plain";
const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;
const XK_F5: i32 = 0xffc2;
const XK_F10: i32 = 0xffc7;
const XK_F11: i32 = 0xffc8;
const XK_UP: i32 = 0xff52;
const XK_DOWN: i32 = 0xff54;
const XK_BACKSPACE: i32 = 0xff08;
const XK_ENTER: i32 = 0xff0d;
const XK_ESCAPE: i32 = 0xff1b;
const DEFAULT_INSTRUCTION_BUDGET: u32 = 1_000_000;
const MAX_INSTRUCTION_BUDGET: u32 = 100_000_000;
const REPLAY_INSTRUCTION_CAP: usize = MAX_INSTRUCTION_BUDGET;
const MEMORY_VIEW_BYTES: usize = 128;
const MEMORY_ACCESS_CONTEXT_ROWS: usize = 3;
const INSTRUCTION_MARKER_WIDTH: usize = 3;
const DEFAULT_INSTRUCTION_WINDOW_LINES: usize = 11;
const MAX_INSTRUCTION_WINDOW_LINES: usize = 2048;
const MAX_INSTRUCTION_INDENT: usize = 4;
const COLUMN_BUFFER_CAP: usize = 256 * 1024;
const LEFT_COLUMN_WIDTH: usize = 44;

const SGR_RESET = "\x1b[0m";
const SGR_BOLD = "\x1b[1m";
const SGR_UNDERLINE = "\x1b[4m";
const SGR_CONTROL_KEY = "\x1b[1;97m";
const SGR_DIM = "\x1b[2m";
const SGR_ERROR = "\x1b[1;91m";
const SGR_WARNING = "\x1b[1;93m";
const SGR_STATUS_READY = "\x1b[96m";
const SGR_STATUS_PAUSED = "\x1b[93m";
const SGR_STATUS_COMPLETE = "\x1b[92m";
const SGR_STATUS_FAILED = "\x1b[91m";
const SGR_INSTRUCTION = "\x1b[93m";
const SGR_STORAGE = "\x1b[34m";
const SGR_READ = "\x1b[95m";
const SGR_READ_ACCESS = "\x1b[4;95m";
const SGR_WRITE = "\x1b[92m";
const SGR_WRITE_TARGET = "\x1b[1;92m";
const SGR_WRITE_ACCESS = "\x1b[1;4;92m";
const SGR_VALUE = "\x1b[94m";
const SGR_CONTROL_FLOW = "\x1b[36m";
const SGR_LOOP_CALL = "\x1b[96m";
const SGR_SELECTED_VALUE = "\x1b[4;94m";
const SGR_MEMORY_DATA = "\x1b[33m";
const SGR_MEMORY_INPUT = "\x1b[34m";
const SGR_MEMORY_INPUT_ACCESS = "\x1b[4;34m";
const SGR_MEMORY_WRITTEN = SGR_WRITE;

var input_buf: [INPUT_CAP]u8 = undefined;
var input_content_type = (TYPE_PREFIX ++ DEFAULT_UUID).*;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var left_column_buf: [COLUMN_BUFFER_CAP]u8 = undefined;
var right_column_buf: [COLUMN_BUFFER_CAP]u8 = undefined;
var machine: interpreter.Machine = undefined;
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var instruction_budget: u32 = DEFAULT_INSTRUCTION_BUDGET;
var last_command_budget: u32 = DEFAULT_INSTRUCTION_BUDGET;
var load_error: ?LoadError = null;
var memory_view_visible = true;
var memory_map_visible = false;
var memory_view_offset: usize = 0;
var memory_view_bytes: usize = MEMORY_VIEW_BYTES;
var memory_address_entry = false;
var memory_address_value: u32 = 0;
var memory_address_digits: u8 = 0;
var breakpoint_entry: BreakpointEntry = .none;
var help_visible = false;
var host_input_stop_visible = false;
var step_replay_available = false;
var step_replay_count: usize = 0;
var step_replay_target: u32 = std.math.maxInt(u32);
var recent_local_write: ?u32 = null;
var recent_local_write_frame_count: usize = 0;
var recent_global_write: ?u32 = null;
var viewport_columns: u32 = std.math.maxInt(u32);
var viewport_lines: u32 = std.math.maxInt(u32);
var output_digest: [32]u8 = undefined;
var output_digest_valid = false;
var render_stack_pointer: ?StackPointerPattern = null;
var static_counts: ?wasm_counts.Counts = null;
var component_path: []const u8 = &.{};
var counters_expanded = false;
var variable_format: VariableFormat = .hex;

const Phase = enum { initializing, ready, updating };
const VariableFormat = enum { hex, decimal, ascii };
const BreakpointEntry = enum { none, condition, memory };
const BreakpointKind = enum { simd, memory_write };

const MultipartError = error{
    InvalidBoundary,
    InvalidMultipart,
    InvalidHeader,
    MissingComponent,
    DuplicatePart,
    UnknownPart,
};

const LoadError = interpreter.Error || MultipartError;

const DebugInput = struct {
    component: []const u8,
    component_path: ?[]const u8 = null,
    target_input: []const u8 = &.{},
};

const FormDisposition = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
};

const StackPointerPattern = struct {
    global_index: u32,
    local_index: u32,
    frame_size: u32,
    entry_read: u32,
    allocation_write: u32,
    restoration_write: u32,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(&input_content_type));
}

export fn input_content_type_size() u32 {
    return input_content_type.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn target_input_ptr() u32 {
    return machine.inputPointer() catch @trap() orelse @trap();
}

fn readBoundary(out: *[TYPE_PREFIX.len + DEFAULT_UUID.len]u8) MultipartError![]const u8 {
    for (&input_content_type, 0..) |*byte, index| {
        out[index] = @as(*volatile u8, @ptrCast(byte)).*;
    }
    if (!std.mem.eql(u8, out[0..TYPE_PREFIX.len], TYPE_PREFIX)) return error.InvalidBoundary;
    const uuid = out[TYPE_PREFIX.len..];
    for (uuid, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidBoundary;
        } else if (!std.ascii.isHex(byte) or (byte >= 'A' and byte <= 'F')) {
            return error.InvalidBoundary;
        }
    }
    return out["multipart/form-data;boundary=".len..];
}

fn trimOWS(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn parseDisposition(value: []const u8) MultipartError!FormDisposition {
    var fields = std.mem.splitScalar(u8, value, ';');
    if (!std.ascii.eqlIgnoreCase(trimOWS(fields.next() orelse return error.InvalidHeader), "form-data")) {
        return error.InvalidHeader;
    }
    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    while (fields.next()) |raw_field| {
        const field = trimOWS(raw_field);
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidHeader;
        const key = trimOWS(field[0..equal]);
        const raw_value = trimOWS(field[equal + 1 ..]);
        if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') return error.InvalidHeader;
        const quoted = raw_value[1 .. raw_value.len - 1];
        if (std.mem.indexOfAny(u8, quoted, "\"\\\r\n") != null) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(key, "name")) {
            if (name != null) return error.InvalidHeader;
            name = quoted;
        } else if (std.ascii.eqlIgnoreCase(key, "filename")) {
            if (filename != null) return error.InvalidHeader;
            filename = quoted;
        }
    }
    return .{ .name = name orelse return error.InvalidHeader, .filename = filename };
}

fn parseHeaders(block: []const u8) MultipartError!FormDisposition {
    var disposition: ?FormDisposition = null;
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return error.InvalidHeader;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const key = line[0..colon];
        const value = trimOWS(line[colon + 1 ..]);
        if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
            if (disposition != null) return error.InvalidHeader;
            disposition = try parseDisposition(value);
        } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
            if (value.len == 0) return error.InvalidHeader;
        } else {
            return error.InvalidHeader;
        }
    }
    return disposition orelse error.InvalidHeader;
}

fn safeComponentPath(filename: ?[]const u8) ?[]const u8 {
    const path = filename orelse return null;
    if (path.len == 0 or path.len > 255 or path[0] == '/' or !std.mem.endsWith(u8, path, ".wasm")) return null;
    for (path) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '+', '-', '/' => {},
        else => return null,
    };
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
    }
    return path;
}

fn findBoundary(input: []const u8, start: usize, marker: []const u8) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, input, cursor, marker)) |at| {
        const suffix = at + marker.len;
        if (suffix + 2 <= input.len and
            (std.mem.eql(u8, input[suffix .. suffix + 2], "\r\n") or
                std.mem.eql(u8, input[suffix .. suffix + 2], "--"))) return at;
        cursor = at + 1;
    }
    return null;
}

fn parseMultipart(input: []const u8) MultipartError!DebugInput {
    var type_bytes: [TYPE_PREFIX.len + DEFAULT_UUID.len]u8 = undefined;
    const boundary = try readBoundary(&type_bytes);
    var opening: [2 + "uuid-".len + DEFAULT_UUID.len + 2]u8 = undefined;
    opening[0] = '-';
    opening[1] = '-';
    @memcpy(opening[2 .. opening.len - 2], boundary);
    opening[opening.len - 2] = '\r';
    opening[opening.len - 1] = '\n';
    if (!std.mem.startsWith(u8, input, &opening)) return error.InvalidMultipart;

    var marker: [4 + "uuid-".len + DEFAULT_UUID.len]u8 = undefined;
    @memcpy(marker[0..4], "\r\n--");
    @memcpy(marker[4..], boundary);

    var component: ?[]const u8 = null;
    var parsed_component_path: ?[]const u8 = null;
    var target_input: ?[]const u8 = null;
    var cursor: usize = opening.len;
    while (true) {
        const header_end = std.mem.indexOfPos(u8, input, cursor, "\r\n\r\n") orelse return error.InvalidMultipart;
        if (header_end - cursor > 16 * 1024) return error.InvalidHeader;
        const disposition = try parseHeaders(input[cursor..header_end]);
        const body_start = header_end + 4;
        const marker_at = findBoundary(input, body_start, &marker) orelse return error.InvalidMultipart;
        const body = input[body_start..marker_at];
        if (std.mem.eql(u8, disposition.name, "component")) {
            if (component != null) return error.DuplicatePart;
            component = body;
            parsed_component_path = safeComponentPath(disposition.filename);
        } else if (std.mem.eql(u8, disposition.name, "input")) {
            if (target_input != null) return error.DuplicatePart;
            target_input = body;
        } else {
            return error.UnknownPart;
        }

        cursor = marker_at + marker.len;
        if (cursor + 2 > input.len) return error.InvalidMultipart;
        if (std.mem.eql(u8, input[cursor .. cursor + 2], "--")) {
            cursor += 2;
            if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "\r\n")) cursor += 2;
            if (cursor != input.len) return error.InvalidMultipart;
            return .{
                .component = component orelse return error.MissingComponent,
                .component_path = parsed_component_path,
                .target_input = target_input orelse &.{},
            };
        }
        if (!std.mem.eql(u8, input[cursor .. cursor + 2], "\r\n")) return error.InvalidMultipart;
        cursor += 2;
    }
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn uniform_set_instruction_budget(value: u32) u32 {
    instruction_budget = std.math.clamp(value, 1, MAX_INSTRUCTION_BUDGET);
    return instruction_budget;
}

export fn uniform_set_columns(value: u32) u32 {
    viewport_columns = @max(value, 1);
    return viewport_columns;
}

export fn uniform_set_lines(value: u32) u32 {
    viewport_lines = @max(value, 1);
    return viewport_lines;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    if (x11_key == '[' and (flags & FLAG_ALT) != 0 and (flags & (FLAG_SHIFT | FLAG_CTRL | FLAG_META)) == 0) {
        if (load_error != null) return 0;
        stepBackward();
        return 1;
    }
    if ((flags & (FLAG_CTRL | FLAG_ALT | FLAG_META)) != 0) return 0;
    if (breakpoint_entry != .none) {
        const breakpoint = breakpointForKey(x11_key) orelse return 1;
        const accesses_before = machine.counters.memory_reads + machine.counters.memory_writes;
        continueToBreakpoint(breakpoint, instruction_budget);
        output_digest_valid = false;
        const following_output = followCompletedOutput();
        const following_store = !following_output and followCurrentStoreTarget();
        if (!following_output and !following_store and machine.counters.memory_reads + machine.counters.memory_writes != accesses_before) {
            followLastMemoryAccess();
        }
        return 1;
    }
    if (x11_key == '?') {
        help_visible = !help_visible;
        return 1;
    }
    if (memory_address_entry) return handleMemoryAddressKey(x11_key);
    if (x11_key == 'i' or x11_key == 'I') {
        if (static_counts == null) return 0;
        counters_expanded = !counters_expanded;
        return 1;
    }
    if (x11_key == 'v') {
        variable_format = switch (variable_format) {
            .hex => .decimal,
            .decimal => .ascii,
            .ascii => .hex,
        };
        return 1;
    }
    if (load_error != null) return 0;
    if (x11_key == 'm' or x11_key == 'M') {
        if (machine.memory_size == 0) return 0;
        memory_map_visible = !memory_map_visible;
        return 1;
    }

    if (machine.status == .halted or machine.status == .trapped) switch (x11_key) {
        XK_F5, XK_F10, XK_F11, XK_DOWN, ' ', 'b', 'B', 'c', 'C', 'n', 'N', 's', 'S', 'f', 'F' => return 1,
        else => {},
    };

    const accesses_before = machine.counters.memory_reads + machine.counters.memory_writes;
    var execution_command = false;
    switch (x11_key) {
        'b', 'B' => {
            breakpoint_entry = .condition;
            return 1;
        },
        XK_F5, ' ', 'c', 'C' => {
            execution_command = true;
            continueExecution(instruction_budget);
        },
        XK_F10, 'n', 'N' => {
            execution_command = true;
            if (atHostInputStop()) {
                host_input_stop_visible = false;
            } else {
                disableStepReplay();
                const instruction_before = machine.current_instruction;
                const frame_count_before = machine.frame_count;
                const instructions_before = machine.counters.instructions;
                clearRecentValueWrite();
                last_command_budget = instruction_budget;
                machine.stepOver(instruction_budget);
                rememberValueWrite(instruction_before, frame_count_before, instructions_before);
            }
        },
        XK_F11 => {
            execution_command = true;
            if ((flags & FLAG_SHIFT) != 0) {
                finishFrame(instruction_budget);
            } else {
                stepInto();
            }
        },
        's', 'S' => {
            execution_command = true;
            stepInto();
        },
        'f', 'F' => {
            execution_command = true;
            finishFrame(instruction_budget);
        },
        'x', 'X' => {
            memory_map_visible = false;
            memory_address_entry = true;
            memory_address_value = 0;
            memory_address_digits = 0;
        },
        XK_UP => {
            stepBackward();
            return 1;
        },
        XK_DOWN => {
            execution_command = true;
            stepInto();
        },
        'r', 'R' => {
            machine.restart() catch |err| {
                load_error = err;
                return 1;
            };
            resetMemoryView();
            host_input_stop_visible = true;
            step_replay_available = true;
            step_replay_count = 0;
            step_replay_target = std.math.maxInt(u32);
            clearRecentValueWrite();
            output_digest_valid = false;
            breakpoint_entry = .none;
        },
        else => return 0,
    }
    if (execution_command) output_digest_valid = false;
    const following_output = execution_command and followCompletedOutput();
    const following_store = !following_output and execution_command and followCurrentStoreTarget();
    if (!following_output and !following_store and machine.counters.memory_reads + machine.counters.memory_writes != accesses_before) {
        followLastMemoryAccess();
    }
    return 1;
}

fn breakpointForKey(x11_key: i32) ?BreakpointKind {
    if (x11_key == XK_ESCAPE) {
        breakpoint_entry = .none;
        return null;
    }
    return switch (breakpoint_entry) {
        .none => null,
        .condition => switch (x11_key) {
            's', 'S' => finishBreakpointEntry(.simd),
            'm', 'M' => blk: {
                breakpoint_entry = .memory;
                break :blk null;
            },
            else => null,
        },
        .memory => switch (x11_key) {
            'w', 'W' => finishBreakpointEntry(.memory_write),
            else => null,
        },
    };
}

fn finishBreakpointEntry(kind: BreakpointKind) BreakpointKind {
    breakpoint_entry = .none;
    return kind;
}

fn stepInto() void {
    if (atHostInputStop()) {
        host_input_stop_visible = false;
        return;
    }
    const previous_instruction = machine.current_instruction;
    const frame_count_before = machine.frame_count;
    const instructions_before = machine.counters.instructions;
    clearRecentValueWrite();
    if (!machine.step()) return;
    rememberValueWrite(previous_instruction, frame_count_before, instructions_before);
    if (!step_replay_available or step_replay_count >= REPLAY_INSTRUCTION_CAP) {
        disableStepReplay();
        return;
    }
    step_replay_count += 1;
    step_replay_target = previous_instruction;
}

fn continueExecution(budget: u32) void {
    host_input_stop_visible = false;
    const can_replay = step_replay_available and step_replay_count == machine.counters.instructions;
    const instructions_before = machine.counters.instructions;
    clearRecentValueWrite();
    last_command_budget = budget;
    machine.continueFor(budget);
    if (!can_replay or machine.counters.instructions == instructions_before or machine.counters.instructions > REPLAY_INSTRUCTION_CAP) {
        disableStepReplay();
        return;
    }
    step_replay_available = true;
    step_replay_count = @intCast(machine.counters.instructions);
    step_replay_target = machine.last_executed_instruction;
}

fn continueToBreakpoint(kind: BreakpointKind, budget: u32) void {
    const was_at_host_input = atHostInputStop();
    host_input_stop_visible = false;
    const can_replay = step_replay_available and step_replay_count == machine.counters.instructions;
    const instructions_before = machine.counters.instructions;
    clearRecentValueWrite();
    last_command_budget = budget;
    machine.budget_exhausted = false;

    var executed: u32 = 0;
    if (!was_at_host_input and machine.status == .ready) {
        _ = machine.step();
        executed = 1;
    }
    while (machine.status == .ready and !currentMatchesBreakpoint(kind)) {
        if (executed >= budget) {
            machine.budget_exhausted = true;
            break;
        }
        _ = machine.step();
        executed += 1;
    }

    if (!can_replay or machine.counters.instructions == instructions_before or machine.counters.instructions > REPLAY_INSTRUCTION_CAP) {
        disableStepReplay();
        return;
    }
    step_replay_available = true;
    step_replay_count = @intCast(machine.counters.instructions);
    step_replay_target = machine.last_executed_instruction;
}

fn currentMatchesBreakpoint(kind: BreakpointKind) bool {
    const instruction = machine.current() orelse return false;
    return switch (kind) {
        .simd => instruction.op == 0xfd,
        .memory_write => isMemoryWriteInstruction(instruction),
    };
}

fn isMemoryWriteInstruction(instruction: interpreter.Instruction) bool {
    if (instruction.op >= 0x36 and instruction.op <= 0x3e) return true;
    if (instruction.op == 0xfc) return instruction.immediate == 10 or instruction.immediate == 11;
    return instruction.op == 0xfd and interpreter.simdSubopcode(instruction) == 11;
}

fn finishFrame(budget: u32) void {
    host_input_stop_visible = false;
    const can_replay = step_replay_available and step_replay_count == machine.counters.instructions;
    const instructions_before = machine.counters.instructions;
    clearRecentValueWrite();
    last_command_budget = budget;
    machine.stepOut(budget);
    if (!can_replay or machine.counters.instructions == instructions_before or machine.counters.instructions > REPLAY_INSTRUCTION_CAP) {
        disableStepReplay();
        return;
    }
    step_replay_available = true;
    step_replay_count = @intCast(machine.counters.instructions);
    step_replay_target = machine.last_executed_instruction;
}

fn disableStepReplay() void {
    step_replay_available = false;
    step_replay_count = 0;
    step_replay_target = std.math.maxInt(u32);
}

fn clearRecentValueWrite() void {
    recent_local_write = null;
    recent_local_write_frame_count = 0;
    recent_global_write = null;
}

fn rememberValueWrite(instruction_index: u32, frame_count_before: usize, instructions_before: u64) void {
    if (machine.counters.instructions != instructions_before + 1 or
        machine.frame_count != frame_count_before or
        instruction_index >= machine.instruction_count) return;
    const instruction = machine.instructions[instruction_index];
    if (instruction.op == 0x21 or instruction.op == 0x22) {
        recent_local_write = @intCast(instruction.immediate);
        recent_local_write_frame_count = machine.frame_count;
    } else if (instruction.op == 0x24) {
        recent_global_write = @intCast(instruction.immediate);
    }
}

fn stepBackward() void {
    if (!step_replay_available) return;
    if (step_replay_count == 0) {
        if (!atHostInputStop() and machine.status == .ready and machine.counters.instructions == 0) {
            host_input_stop_visible = true;
            resetMemoryView();
            clearRecentValueWrite();
        }
        return;
    }
    output_digest_valid = false;
    const replay_count = step_replay_count - 1;
    machine.restart() catch |err| {
        load_error = err;
        disableStepReplay();
        return;
    };
    host_input_stop_visible = false;
    resetMemoryView();
    clearRecentValueWrite();
    step_replay_target = std.math.maxInt(u32);
    var replayed: usize = 0;
    while (replayed < replay_count and replayed < REPLAY_INSTRUCTION_CAP) : (replayed += 1) {
        const previous_instruction = machine.current_instruction;
        const frame_count_before = machine.frame_count;
        const instructions_before = machine.counters.instructions;
        clearRecentValueWrite();
        if (!machine.step()) {
            disableStepReplay();
            return;
        }
        rememberValueWrite(previous_instruction, frame_count_before, instructions_before);
        step_replay_target = previous_instruction;
    }
    step_replay_count = replay_count;
    if (!followCurrentStoreTarget()) followLastMemoryAccess();
}

fn resetMemoryView() void {
    memory_view_visible = true;
    memory_view_offset = 0;
    memory_view_bytes = MEMORY_VIEW_BYTES;
    const input_address = machine.inputPointer() catch return;
    if (input_address) |address| {
        if (address < machine.memory_size) {
            memory_view_offset = @as(usize, address) & ~@as(usize, 15);
        }
    }
}

fn handleMemoryAddressKey(x11_key: i32) i32 {
    switch (x11_key) {
        XK_ESCAPE => {
            memory_address_entry = false;
            return 1;
        },
        XK_BACKSPACE => {
            if (memory_address_digits > 0) {
                memory_address_value >>= 4;
                memory_address_digits -= 1;
            }
            return 1;
        },
        XK_ENTER => {
            if (memory_address_digits > 0 and machine.memory_size > 0) {
                memory_view_offset = @min(@as(usize, memory_address_value), machine.memory_size - 1);
                memory_view_bytes = MEMORY_VIEW_BYTES;
                memory_view_visible = true;
            }
            memory_address_entry = false;
            return 1;
        },
        XK_UP => {
            pageMemoryBackward();
            return 1;
        },
        XK_DOWN => {
            pageMemoryForward();
            return 1;
        },
        'i', 'I' => {
            const pointer = inputMemoryPointer() orelse return 0;
            showMemoryAt(pointer);
            return 1;
        },
        'o', 'O' => {
            const pointer = outputMemoryPointer() orelse return 0;
            showMemoryAt(pointer);
            return 1;
        },
        'r', 'R' => {
            if (!machine.last_read_access.valid) return 0;
            showMemoryAccessWithContext(machine.last_read_access);
            return 1;
        },
        'w', 'W' => {
            if (!machine.last_write_access.valid) return 0;
            showMemoryAccessWithContext(machine.last_write_access);
            return 1;
        },
        else => {},
    }
    const digit = hexDigit(x11_key) orelse return 0;
    if (memory_address_digits < 8) {
        memory_address_value = (memory_address_value << 4) | digit;
        memory_address_digits += 1;
    }
    return 1;
}

fn showMemoryAt(address: u32) void {
    if (machine.memory_size == 0) return;
    memory_view_offset = @min(@as(usize, address), machine.memory_size - 1);
    memory_view_bytes = MEMORY_VIEW_BYTES;
    memory_view_visible = true;
    memory_address_entry = false;
}

fn showMemoryAccessWithContext(access: interpreter.MemoryEvent) void {
    if (!access.valid or machine.memory_size == 0) return;
    const access_row = @as(usize, access.address) & ~@as(usize, 15);
    memory_view_offset = access_row -| MEMORY_ACCESS_CONTEXT_ROWS * 16;
    memory_view_bytes = MEMORY_VIEW_BYTES;
    memory_view_visible = true;
    memory_address_entry = false;
}

fn inputMemoryPointer() ?u32 {
    const pointer = machine.inputPointer() catch return null;
    const address = pointer orelse return null;
    if (address >= machine.memory_size) return null;
    return address;
}

fn outputMemoryPointer() ?u32 {
    if (machine.status != .halted) return null;
    if ((machine.result >> 63) != 0) return null;
    const size: u32 = @truncate(machine.result);
    const pointer: u32 = @as(u32, @truncate(machine.result >> 32)) & 0x7fff_ffff;
    if (pointer > machine.memory_size or size > machine.memory_size - pointer) return null;
    return pointer;
}

fn finalOutputDigest() ?*const [32]u8 {
    const pointer = outputMemoryPointer() orelse return null;
    const size: u32 = @truncate(machine.result);
    const start: usize = pointer;
    const end = start + @as(usize, size);
    if (!output_digest_valid) {
        std.crypto.hash.sha2.Sha256.hash(machine.memory[start..end], &output_digest, .{});
        output_digest_valid = true;
    }
    return &output_digest;
}

fn followCompletedOutput() bool {
    const pointer = outputMemoryPointer() orelse return false;
    showMemoryAt(pointer);
    return true;
}

fn hexDigit(key: i32) ?u32 {
    return switch (key) {
        '0'...'9' => @intCast(key - '0'),
        'a'...'f' => @intCast(key - 'a' + 10),
        'A'...'F' => @intCast(key - 'A' + 10),
        else => null,
    };
}

fn pageMemoryBackward() void {
    memory_view_visible = true;
    memory_view_bytes = MEMORY_VIEW_BYTES;
    memory_view_offset -|= MEMORY_VIEW_BYTES;
}

fn pageMemoryForward() void {
    memory_view_visible = true;
    memory_view_bytes = MEMORY_VIEW_BYTES;
    if (machine.memory_size == 0) return;
    memory_view_offset = @min(memory_view_offset + MEMORY_VIEW_BYTES, machine.memory_size - 1);
}

fn followLastMemoryAccess() void {
    if (!machine.last_access.valid) return;
    showMemoryAccessWithContext(machine.last_access);
}

fn followCurrentStoreTarget() bool {
    const target = currentStoreTarget() orelse return false;
    showMemoryAccessWithContext(target);
    return true;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    instruction_budget = DEFAULT_INSTRUCTION_BUDGET;
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return begun_at_ms;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    if (phase == .updating) @trap();
    if (phase == .initializing) {
        load_error = null;
        memory_view_visible = true;
        memory_map_visible = false;
        memory_view_offset = 0;
        memory_view_bytes = MEMORY_VIEW_BYTES;
        memory_address_entry = false;
        memory_address_value = 0;
        memory_address_digits = 0;
        breakpoint_entry = .none;
        help_visible = false;
        host_input_stop_visible = false;
        counters_expanded = false;
        variable_format = .hex;
        step_replay_available = false;
        step_replay_count = 0;
        step_replay_target = std.math.maxInt(u32);
        instruction_budget = DEFAULT_INSTRUCTION_BUDGET;
        last_command_budget = DEFAULT_INSTRUCTION_BUDGET;
        output_digest_valid = false;
        render_stack_pointer = null;
        static_counts = null;
        component_path = &.{};
        clearRecentValueWrite();
        const debug_input = parseMultipart(input_buf[0..input_size]) catch |err| {
            load_error = err;
            phase = .ready;
            const size = fitOutputToViewport(renderText());
            return .{
                .output_size = @intCast(size),
                .output_ptr = @intCast(@intFromPtr(&output_buf)),
                .failed = 0,
            };
        };
        static_counts = wasm_counts.analyze(debug_input.component) catch null;
        component_path = debug_input.component_path orelse &.{};
        machine.loadWithInput(debug_input.component, debug_input.target_input) catch |err| {
            load_error = err;
        };
        if (load_error == null) {
            render_stack_pointer = inferRenderStackPointer();
            resetMemoryView();
            host_input_stop_visible = true;
            step_replay_available = true;
        }
        phase = .ready;
    } else if (input_size != 0) {
        @trap();
    }

    const size = fitOutputToViewport(renderText());
    return .{
        .output_size = @intCast(size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

const Writer = struct {
    buffer: []u8,
    offset: usize = 0,

    fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    fn text(self: *Writer, value: []const u8) void {
        const amount = @min(value.len, self.buffer.len - self.offset);
        @memcpy(self.buffer[self.offset .. self.offset + amount], value[0..amount]);
        self.offset += amount;
    }

    fn raw(self: *Writer, value: []const u8) void {
        const amount = @min(value.len, self.buffer.len - self.offset);
        @memcpy(self.buffer[self.offset .. self.offset + amount], value[0..amount]);
        self.offset += amount;
    }

    fn styled(self: *Writer, comptime style: []const u8, value: []const u8) void {
        self.raw(style);
        self.text(value);
        self.raw(SGR_RESET);
    }

    fn print(self: *Writer, comptime format: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(self.buffer[self.offset..], format, args) catch return;
        self.offset += rendered.len;
    }
};

fn fitOutputToViewport(size: usize) usize {
    if (viewport_columns == std.math.maxInt(u32) and viewport_lines == std.math.maxInt(u32)) return size;

    const max_columns: usize = viewport_columns;
    const max_lines: usize = viewport_lines;
    var read_offset: usize = 0;
    var write_offset: usize = 0;
    var line: usize = 0;
    var column: usize = 0;
    var clipped = false;

    while (read_offset < size) {
        const byte = output_buf[read_offset];
        if (byte == 0x1b) {
            const end = std.mem.indexOfScalarPos(u8, output_buf[0..size], read_offset + 1, 'm') orelse break;
            const sequence_end = end + 1;
            std.mem.copyForwards(u8, output_buf[write_offset..][0 .. sequence_end - read_offset], output_buf[read_offset..sequence_end]);
            write_offset += sequence_end - read_offset;
            read_offset = sequence_end;
            continue;
        }
        if (byte == '\n') {
            if (line + 1 >= max_lines) {
                clipped = true;
                break;
            }
            output_buf[write_offset] = byte;
            write_offset += 1;
            read_offset += 1;
            line += 1;
            column = 0;
            continue;
        }

        const sequence_length: usize = if (byte < 0x80)
            1
        else if (byte < 0xe0)
            2
        else if (byte < 0xf0)
            3
        else
            4;
        if (column < max_columns) {
            std.mem.copyForwards(u8, output_buf[write_offset..][0..sequence_length], output_buf[read_offset..][0..sequence_length]);
            write_offset += sequence_length;
        } else {
            clipped = true;
        }
        read_offset += sequence_length;
        column += 1;
    }

    if (read_offset < size) clipped = true;
    if (clipped and write_offset + SGR_RESET.len <= output_buf.len) {
        @memcpy(output_buf[write_offset..][0..SGR_RESET.len], SGR_RESET);
        write_offset += SGR_RESET.len;
    }
    return write_offset;
}

fn renderCodeOffset(out: *Writer, value: u32) void {
    out.raw(SGR_DIM);
    out.print("0x{x:0>6}", .{value});
    out.raw(SGR_RESET);
}

fn renderHex32(out: *Writer, value: u32) void {
    out.raw(SGR_VALUE);
    out.print("0x{x:0>8}", .{value});
    out.raw(SGR_RESET);
}

fn renderBareHex32(out: *Writer, value: u32) void {
    out.raw(SGR_VALUE);
    out.print("{x:0>8}", .{value});
    out.raw(SGR_RESET);
}

fn renderHex64(out: *Writer, value: u64) void {
    out.raw(SGR_VALUE);
    out.print("0x{x:0>16}", .{value});
    out.raw(SGR_RESET);
}

fn renderDecimalScalarBare(out: *Writer, value_type: interpreter.ValType, value: interpreter.Value) void {
    switch (value_type) {
        .i32, .f32 => out.print("{d}", .{@as(i32, @bitCast(@as(u32, @truncate(value))))}),
        .i64, .f64 => out.print("{d}", .{@as(i64, @bitCast(@as(u64, @truncate(value))))}),
        .v128 => unreachable,
    }
}

fn renderAsciiScalarBare(out: *Writer, value_type: interpreter.ValType, value: interpreter.Value) void {
    const width: usize = switch (value_type) {
        .i32, .f32 => 4,
        .i64, .f64 => 8,
        .v128 => unreachable,
    };
    var text = [_]u8{'.'} ** 10;
    text[0] = '|';
    text[width + 1] = '|';
    for (0..width) |index| {
        const byte: u8 = @truncate(value >> @intCast(index * 8));
        text[index + 1] = if (byte >= 0x20 and byte <= 0x7e) byte else '.';
    }
    out.text(text[0 .. width + 2]);
}

fn renderTypedScalarBare(out: *Writer, value_type: interpreter.ValType, value: interpreter.Value) void {
    switch (variable_format) {
        .decimal => {
            renderDecimalScalarBare(out, value_type, value);
            return;
        },
        .ascii => {
            renderAsciiScalarBare(out, value_type, value);
            return;
        },
        .hex => {},
    }
    switch (value_type) {
        .i32, .f32 => out.print("0x{x:0>8}", .{@as(u32, @truncate(value))}),
        .i64, .f64 => out.print("0x{x:0>16}", .{@as(u64, @truncate(value))}),
        .v128 => unreachable,
    }
}

fn renderStorageScalarBare(out: *Writer, value_type: interpreter.ValType, value: interpreter.Value) void {
    switch (variable_format) {
        .decimal => {
            renderDecimalScalarBare(out, value_type, value);
            return;
        },
        .ascii => {
            renderAsciiScalarBare(out, value_type, value);
            return;
        },
        .hex => {},
    }
    out.print("0x{x:0>16}", .{@as(u64, @truncate(value))});
}

fn renderStorageScalar(out: *Writer, value_type: interpreter.ValType, value: interpreter.Value) void {
    out.raw(SGR_VALUE);
    renderStorageScalarBare(out, value_type, value);
    out.raw(SGR_RESET);
}

fn instructionStyle(op: u8) []const u8 {
    if (isWriteInstruction(op)) return SGR_WRITE;
    if (op == 0x20 or op == 0x23 or (op >= 0x28 and op <= 0x35)) return SGR_READ;
    if (op == 0x03 or op == 0x10 or op == 0x11) return SGR_LOOP_CALL;
    if (op == 0x1b) return SGR_CONTROL_FLOW;
    return switch (op) {
        0x00...0x02, 0x04...0x0f => SGR_CONTROL_FLOW,
        else => SGR_INSTRUCTION,
    };
}

fn instructionStyleAt(index: u32) []const u8 {
    if (branchTargetsLoop(index)) return SGR_LOOP_CALL;
    const instruction = machine.instructions[index];
    if (instruction.op == 0xfd) return switch (interpreter.simdSubopcode(instruction)) {
        0, 93 => SGR_READ,
        11 => SGR_WRITE,
        else => SGR_INSTRUCTION,
    };
    return instructionStyle(instruction.op);
}

fn renderOpcodeName(out: *Writer, instruction: interpreter.Instruction, style: []const u8) void {
    switch (instruction.op) {
        0x20...0x22 => {
            out.raw(SGR_STORAGE);
            out.text("local");
            out.raw(style);
            out.text(switch (instruction.op) {
                0x20 => ".get",
                0x21 => ".set",
                0x22 => ".tee",
                else => unreachable,
            });
            out.raw(SGR_RESET);
        },
        0x23, 0x24 => {
            out.raw(SGR_STORAGE);
            out.text("global");
            out.raw(style);
            out.text(if (instruction.op == 0x23) ".get" else ".set");
            out.raw(SGR_RESET);
        },
        0x28...0x35 => {
            const name = interpreter.opcodeName(instruction.op);
            const separator = std.mem.indexOfScalar(u8, name, '.') orelse unreachable;
            out.raw(SGR_INSTRUCTION);
            out.text(name[0..separator]);
            out.raw(SGR_READ);
            out.text(name[separator..]);
            out.raw(SGR_RESET);
        },
        0x36...0x3e => {
            const name = interpreter.opcodeName(instruction.op);
            const separator = std.mem.indexOfScalar(u8, name, '.') orelse unreachable;
            out.raw(SGR_INSTRUCTION);
            out.text(name[0..separator]);
            out.raw(SGR_WRITE);
            out.text(name[separator..]);
            out.raw(SGR_RESET);
        },
        0xfc => {
            const name = interpreter.instructionName(instruction);
            const separator = std.mem.indexOfScalar(u8, name, '.') orelse unreachable;
            out.raw(SGR_INSTRUCTION);
            out.text(name[0..separator]);
            out.raw(SGR_WRITE);
            out.text(name[separator..]);
            out.raw(SGR_RESET);
        },
        0xfd => {
            const name = interpreter.instructionName(instruction);
            const separator = std.mem.indexOfScalar(u8, name, '.');
            if (separator) |at| {
                out.raw(SGR_INSTRUCTION);
                out.text(name[0..at]);
                out.raw(style);
                out.text(name[at..]);
                out.raw(SGR_RESET);
            } else {
                out.raw(style);
                out.text(name);
            }
        },
        else => {
            out.raw(style);
            out.text(interpreter.opcodeName(instruction.op));
        },
    }
}

fn branchTargetsLoop(index: u32) bool {
    if (index >= machine.instruction_count) return false;
    const branch = machine.instructions[index];
    if (branch.op != 0x0c and branch.op != 0x0d) return false;
    if (branch.immediate >= branch.depth) return false;
    const target_depth = branch.depth - 1 - @as(u16, @intCast(branch.immediate));
    var cursor: usize = index;
    while (cursor > 0) {
        cursor -= 1;
        const candidate = machine.instructions[cursor];
        if ((candidate.op == 0x02 or candidate.op == 0x03 or candidate.op == 0x04) and
            candidate.depth == target_depth and candidate.match >= index)
            return candidate.op == 0x03;
    }
    return false;
}

fn isWriteInstruction(op: u8) bool {
    return op == 0x21 or op == 0x22 or op == 0x24 or (op >= 0x36 and op <= 0x3e) or op == 0xfc;
}

fn storeWidth(op: u8) ?u8 {
    return switch (op) {
        0x36, 0x38 => 4,
        0x37, 0x39 => 8,
        0x3a, 0x3c => 1,
        0x3b, 0x3d => 2,
        0x3e => 4,
        else => null,
    };
}

fn currentStoreTarget() ?interpreter.MemoryEvent {
    if (atHostInputStop()) return null;
    if (machine.current_instruction >= machine.instruction_count) return null;
    const instruction = machine.instructions[machine.current_instruction];
    if (instruction.op == 0xfd and interpreter.simdSubopcode(instruction) == 11) {
        if (machine.stack_count < 2 or machine.stack_types[machine.stack_count - 2] != .i32) return null;
        const address: u32 = @truncate(machine.stack[machine.stack_count - 2]);
        const effective = @as(u64, address) + interpreter.simdImmediate(instruction);
        if (effective + 16 > machine.memory_size) return null;
        return .{ .valid = true, .address = @intCast(effective), .width = 16 };
    }
    if (instruction.op == 0xfc and (instruction.immediate == 10 or instruction.immediate == 11)) {
        if (machine.stack_count < 3) return null;
        const address_index = machine.stack_count - 3;
        const length_index = machine.stack_count - 1;
        if (machine.stack_types[address_index] != .i32 or machine.stack_types[length_index] != .i32) return null;
        const address: u32 = @truncate(machine.stack[address_index]);
        const length: u32 = @truncate(machine.stack[length_index]);
        if (length == 0 or @as(u64, address) + length > machine.memory_size) return null;
        return .{ .valid = true, .address = address, .width = length };
    }
    if (machine.stack_count < 2) return null;
    const width = storeWidth(instruction.op) orelse return null;
    const address_index = machine.stack_count - 2;
    if (machine.stack_types[address_index] != .i32) return null;
    const address: u32 = @truncate(machine.stack[address_index]);
    const effective = @as(u64, address) + instruction.immediate;
    if (effective + width > machine.memory_size) return null;
    return .{ .valid = true, .address = @intCast(effective), .width = width };
}

fn memoryWriteHighlight() interpreter.MemoryEvent {
    if (currentStoreTarget()) |target| return target;
    return .{};
}

fn renderText() usize {
    var out = Writer.init(&output_buf);

    renderCounters(&out, load_error == null);

    if (breakpoint_entry != .none) renderBreakpointPrompt(&out);

    if (help_visible) {
        renderHelp(&out);
        out.text("\n");
    }

    if (load_error) |err| {
        out.raw(SGR_ERROR);
        out.print("INPUT  rejected  reason {s}", .{@errorName(err)});
        out.raw(SGR_RESET);
        out.text("\n\n");
        out.text("Initial profile: wasm32, memory up to 128 MiB, no imports or table\n");
        out.text("mutation, scalar i32/i64, direct/indirect calls, active data/elements.\n");
        return out.offset;
    }

    if (memory_address_entry or memory_view_visible) {
        out.styled(SGR_BOLD, "MEMORY");
        out.text("  ");
        renderMemorySize(&out, machine.memory_size);
        out.print("  pages={d}  reads=", .{machine.memory_pages});
        out.raw(SGR_READ);
        out.print("{d}", .{machine.counters.memory_reads});
        out.raw(SGR_RESET);
        out.text(" writes=");
        out.raw(SGR_WRITE);
        out.print("{d}", .{machine.counters.memory_writes});
        out.raw(SGR_RESET);
        out.text("  ");
        out.styled(SGR_CONTROL_KEY, "x");
        out.text(" examine  ");
        out.styled(SGR_CONTROL_KEY, "m");
        out.text(if (memory_map_visible) " bytes\n" else " map\n");
        if (memory_map_visible)
            renderMemoryMap(&out)
        else
            renderMemory(&out);
        out.text("\n");
    }

    renderExecutionColumns(&out);
    if (machine.status == .halted) {
        const result_size: u32 = @truncate(machine.result);
        const result_pointer: u32 = @as(u32, @truncate(machine.result >> 32)) & 0x7fff_ffff;
        out.text("\n");
        out.styled(SGR_BOLD, "OUTPUT");
        out.text(if ((machine.result >> 63) == 0) " succeeded" else " failed");
        out.print(" size={d} ptr=", .{result_size});
        renderHex32(&out, result_pointer);
        out.text(" packed=");
        renderHex64(&out, machine.result);
        out.text("\n");
        if (finalOutputDigest()) |digest| {
            out.text("  sha256=");
            out.raw(SGR_VALUE);
            for (digest) |byte| out.print("{x:0>2}", .{byte});
            out.raw(SGR_RESET);
            out.text("\n");
        }
    }

    return out.offset;
}

fn renderBreakpointPrompt(out: *Writer) void {
    out.styled(SGR_BOLD, if (breakpoint_entry == .memory) "BREAK MEMORY" else "BREAK");
    out.text("  ");
    if (breakpoint_entry == .memory) {
        out.styled(SGR_CONTROL_KEY, "W");
        out.text(" next write  ");
    } else {
        out.styled(SGR_CONTROL_KEY, "S");
        out.text(" next SIMD  ");
        out.styled(SGR_CONTROL_KEY, "M");
        out.text(" memory  ");
    }
    out.styled(SGR_CONTROL_KEY, "Esc");
    out.text(" cancel\n");
}

fn renderMemorySize(out: *Writer, byte_count: usize) void {
    const kib = 1024;
    const mib = 1024 * kib;
    if (byte_count >= mib and byte_count % mib == 0) {
        out.print("{d} MiB", .{byte_count / mib});
    } else if (byte_count >= kib and byte_count % kib == 0) {
        out.print("{d} KiB", .{byte_count / kib});
    } else {
        out.print("{d} B", .{byte_count});
    }
}

fn renderComponentSummary(out: *Writer, max_columns: usize) void {
    const input_type = componentInputType();
    const output_type = componentOutputType();

    if (component_path.len != 0) {
        const compact_input = compactContentType(input_type);
        const compact_output = compactContentType(output_type);
        const fixed_columns = 6 + decimalDigits(machine.module.len);
        const variable_columns = max_columns -| fixed_columns;
        var path_columns = @min(component_path.len, variable_columns);
        var input_columns = @min(compact_input.len, 24);
        var output_columns = @min(compact_output.len, 24);
        while (path_columns + input_columns + output_columns > variable_columns) {
            if (path_columns > 8)
                path_columns -= 1
            else if (output_columns >= input_columns and output_columns > 3)
                output_columns -= 1
            else if (input_columns > 3)
                input_columns -= 1
            else
                break;
        }
        renderSummaryPath(out, component_path, path_columns);
        out.text(" ");
        renderSummaryType(out, compact_input, input_columns);
        out.text(" → ");
        renderSummaryType(out, compact_output, output_columns);
        out.print(" {d}B\n", .{machine.module.len});
        return;
    }

    out.styled(SGR_BOLD, "WASM");
    out.text("  ");
    out.raw(SGR_DIM);
    out.print("{d} B", .{machine.module.len});
    out.raw(SGR_RESET);
    out.text("  QIP  ");

    const fixed_columns = 18 + decimalDigits(machine.module.len);
    const type_columns = max_columns -| fixed_columns;
    var input_columns = @min(input_type.len, 24);
    var output_columns = @min(output_type.len, 24);
    while (input_columns + output_columns > type_columns) {
        if (output_columns >= input_columns and output_columns > 3)
            output_columns -= 1
        else if (input_columns > 3)
            input_columns -= 1
        else
            break;
    }
    renderSummaryType(out, input_type, input_columns);
    out.text(" → ");
    renderSummaryType(out, output_type, output_columns);
    out.text("\n");
}

fn compactContentType(content_type: []const u8) []const u8 {
    return if (std.mem.eql(u8, content_type, "UTF-8")) "utf-8" else content_type;
}

fn renderSummaryPath(out: *Writer, path: []const u8, max_bytes: usize) void {
    if (path.len <= max_bytes) {
        out.text(path);
        return;
    }
    if (max_bytes <= 3) {
        out.text("..."[0..max_bytes]);
        return;
    }
    const remaining = max_bytes - 3;
    const prefix = remaining / 3;
    out.text(path[0..prefix]);
    out.text("...");
    out.text(path[path.len - (remaining - prefix) ..]);
}

fn renderQipSummary(out: *Writer, max_columns: usize) void {
    const input_type = componentInputType();
    const output_type = componentOutputType();
    const input_capacity = machine.inputCapacity() catch null;
    const output_capacity = machine.outputCapacity() catch null;
    const no_input = !machine.hasFunctionExport("input_ptr") and
        !machine.hasFunctionExport("input_utf8_cap") and
        !machine.hasFunctionExport("input_bytes_cap");

    out.styled(SGR_BOLD, "QIP");
    out.text("      ");
    const fixed_columns = "QIP      ".len + " → ".len +
        "  input-capacity=".len + capacityTextLength(input_capacity, no_input) +
        "  output-capacity=".len + capacityTextLength(output_capacity, false);
    const type_columns = max_columns -| fixed_columns;
    var input_columns = @min(input_type.len, 24);
    var output_columns = @min(output_type.len, 24);
    while (input_columns + output_columns > type_columns) {
        if (output_columns >= input_columns and output_columns > 3)
            output_columns -= 1
        else if (input_columns > 3)
            input_columns -= 1
        else
            break;
    }
    renderSummaryType(out, input_type, input_columns);
    out.text(" → ");
    renderSummaryType(out, output_type, output_columns);
    out.text("  input-capacity=");
    if (input_capacity) |capacity| {
        out.raw(SGR_VALUE);
        out.print("{d}", .{capacity});
        out.raw(SGR_RESET);
        out.text(" B");
    } else if (no_input) {
        out.raw(SGR_DIM);
        out.text("none");
        out.raw(SGR_RESET);
    } else {
        out.raw(SGR_ERROR);
        out.text("unknown");
        out.raw(SGR_RESET);
    }
    out.text("  output-capacity=");
    if (output_capacity) |capacity| {
        out.raw(SGR_VALUE);
        out.print("{d}", .{capacity});
        out.raw(SGR_RESET);
        out.text(" B");
    } else {
        out.raw(SGR_ERROR);
        out.text("unknown");
        out.raw(SGR_RESET);
    }
    out.text("\n");
}

fn capacityTextLength(capacity: ?u32, absent: bool) usize {
    if (capacity) |value| return decimalDigits(value) + " B".len;
    return if (absent) "none".len else "unknown".len;
}

fn decimalDigits(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn componentInputType() []const u8 {
    if (declaredContentType("input_content_type_ptr", "input_content_type_size")) |content_type| {
        return content_type;
    }
    if (machine.hasFunctionExport("input_utf8_cap")) return "UTF-8";
    if (machine.hasFunctionExport("input_bytes_cap")) return "bytes";
    return "no input";
}

fn componentOutputType() []const u8 {
    if (declaredContentType("output_content_type_ptr", "output_content_type_size")) |content_type| {
        return content_type;
    }
    if (machine.hasFunctionExport("output_utf8_cap")) return "UTF-8";
    if (machine.hasFunctionExport("output_bytes_cap")) return "bytes";
    return "unknown";
}

fn declaredContentType(pointer_export: []const u8, size_export: []const u8) ?[]const u8 {
    const maybe_bytes = machine.staticExportedBytes(pointer_export, size_export) catch return null;
    const bytes = maybe_bytes orelse return null;
    const end = std.mem.indexOfScalar(u8, bytes, ';') orelse bytes.len;
    const base_type = bytes[0..end];
    if (base_type.len < 3 or base_type.len > 127) return null;
    var slash = false;
    for (base_type) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '&', '^', '_', '.', '+', '-' => {},
        '/' => slash = true,
        else => return null,
    };
    return if (slash) base_type else null;
}

fn renderSummaryType(out: *Writer, content_type: []const u8, max_bytes: usize) void {
    if (content_type.len <= max_bytes) {
        out.text(content_type);
        return;
    }
    out.text(content_type[0 .. max_bytes - 3]);
    out.text("...");
}

fn renderHelp(out: *Writer) void {
    out.styled(SGR_BOLD, "HELP");
    out.text("  ");
    out.styled(SGR_CONTROL_KEY, "?");
    out.text(" close\n");
    out.text("  STATUS  ");
    out.styled(SGR_STATUS_READY, "●");
    out.text(" at instruction  ");
    out.styled(SGR_STATUS_PAUSED, "●");
    out.text(" budget exhausted  ");
    out.styled(SGR_STATUS_COMPLETE, "●");
    out.text(" completed  ");
    out.styled(SGR_STATUS_FAILED, "●");
    out.text(" failed/trapped\n");
    out.text("  COLOR LEGEND\n");
    out.text("    ");
    out.styled(SGR_INSTRUCTION, "i32.add");
    out.text(" ordinary  ");
    out.styled(SGR_STORAGE, "local/global");
    out.text(" storage  ");
    out.styled(SGR_READ, ".get/.load");
    out.text(" read\n");
    out.text("    ");
    out.styled(SGR_WRITE, ".set/.store");
    out.text(" write  ");
    out.styled(SGR_CONTROL_FLOW, "if/select");
    out.text(" control  ");
    out.styled(SGR_LOOP_CALL, "loop/call");
    out.text(" loops and calls\n");
    out.text("    ");
    out.styled(SGR_VALUE, "0x00000000");
    out.text(" value\n");
    out.text("  VARIABLES\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "v");
    out.text(" cycle hex/decimal/ASCII\n");
    out.text("  EXECUTION\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "↓ / S / F11");
    out.text(" step into       ");
    out.styled(SGR_CONTROL_KEY, "N / F10");
    out.text(" step over\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "↑ / Alt-[");
    out.text(" step back       ");
    out.styled(SGR_CONTROL_KEY, "F / Shift-F11");
    out.text(" finish function\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "Space / C / F5");
    out.text(" continue        ");
    out.styled(SGR_CONTROL_KEY, "R");
    out.text(" restart        ");
    out.styled(SGR_CONTROL_KEY, "I");
    out.text(" counters\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "B S");
    out.text(" next SIMD      ");
    out.styled(SGR_CONTROL_KEY, "B M W");
    out.text(" next memory write\n");
    out.text("  MEMORY\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "M");
    out.text(" map/bytes\n");
    out.text("    MAP CELL  ▘/▝ top read/write  ▖/▗ bottom read/write  ");
    out.styled(SGR_DIM, "░");
    out.text(" untouched\n");
    out.text("              ▀/▄ page read+written  █ both pages read+written\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "X");
    out.text(" examine          ");
    out.styled(SGR_CONTROL_KEY, "0-9 / A-F");
    out.text(" enter address\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "X I / X O");
    out.text(" input/output     ");
    out.styled(SGR_CONTROL_KEY, "X R / X W");
    out.text(" last read/write\n");
    out.text("    ");
    out.styled(SGR_CONTROL_KEY, "X ↑ / X ↓");
    out.text(" page memory      ");
    out.styled(SGR_CONTROL_KEY, "Backspace / Enter / Esc");
    out.text(" edit/accept/cancel\n");
}

fn renderCounters(out: *Writer, include_runtime: bool) void {
    out.styled(SGR_BOLD, "qipdb");
    out.text("  ");
    renderStatusLight(out);
    const counts = static_counts orelse {
        if (include_runtime) out.print("  executed={d}", .{machine.counters.instructions});
        out.text("\n");
        return;
    };
    out.text("  ");
    out.styled(SGR_CONTROL_KEY, "i");
    out.text(if (counters_expanded) " collapse" else " expand");
    out.text("  ");
    out.styled(SGR_CONTROL_KEY, "?");
    out.text(" help");
    if (!counters_expanded) {
        if (include_runtime) {
            if (machine.counters.instructions == 0) {
                out.text("  ");
                renderComponentSummary(out, 52);
                return;
            }
            out.print("  executed={d}  calls=", .{machine.counters.instructions});
            out.raw(SGR_LOOP_CALL);
            out.print("{d}", .{machine.counters.calls});
            out.raw(SGR_RESET);
            out.text("  iterations=");
            out.raw(SGR_LOOP_CALL);
            out.print("{d}", .{machine.counters.loop_iterations});
            out.raw(SGR_RESET);
            out.text("\n");
        } else {
            out.print("  instructions={d}  functions={d}  loops=", .{
                counts.function_instructions,
                counts.functions_defined + counts.functions_imported,
            });
            out.raw(SGR_LOOP_CALL);
            out.print("{d}", .{counts.loops});
            out.raw(SGR_RESET);
            out.text("\n");
        }
        return;
    }

    out.text("\n");
    out.text("  ");
    out.styled(SGR_BOLD, "WASM");
    out.text("     ");
    out.raw(SGR_DIM);
    if (component_path.len != 0) {
        out.text(component_path);
        out.text("  ");
    }
    out.print("{d} B", .{machine.module.len});
    out.raw(SGR_RESET);
    out.text("\n");
    out.text("  ");
    renderQipSummary(out, 78);
    out.print("  EXPORTS  functions={d}  tables={d}  memories={d}  globals={d}  tags={d}\n", .{
        counts.functions_exported,
        counts.tables_exported,
        counts.memories_exported,
        counts.globals_exported,
        counts.tags_exported,
    });
    if (include_runtime) {
        out.print("  RUNTIME  executed={d}  branches-taken={d}  calls={d}  returns={d}  indirect={d}\n", .{
            machine.counters.instructions,
            machine.counters.branches,
            machine.counters.calls,
            machine.counters.returns,
            machine.counters.indirect_calls,
        });
    }
    out.print("  CODE     instructions={d}  functions={d}  globals={d}\n", .{
        counts.function_instructions,
        counts.functions_defined + counts.functions_imported,
        counts.globals_defined + counts.globals_imported,
    });
    out.print("  CONTROL  loops={d}  branch-sites={d}  conditional-sites={d}\n", .{
        counts.loops,
        counts.branches,
        counts.conditional_branches,
    });
    out.print("  CALLS    direct={d}  call_indirect={d}  return_call_indirect={d}  call_ref={d}\n", .{
        counts.calls_direct_local + counts.calls_direct_imported,
        counts.call_indirect,
        counts.return_call_indirect,
        counts.call_ref,
    });
    out.print("  TABLES   tables={d}  fixed={d}  initial-slots={d}  maximum-slots={d}\n", .{
        counts.tables_defined + counts.tables_imported,
        counts.tables_fixed_size,
        counts.table_initial_slots,
        counts.table_maximum_slots,
    });
    out.print("  TYPES    funcref={d}  externref={d}  typed-reference={d}  table64={d}\n", .{
        counts.tables_funcref,
        counts.tables_externref,
        counts.tables_typed_reference,
        counts.tables_table64,
    });
    out.print("  ELEMENTS active={d}  passive={d}  declarative={d}  initializers={d}\n", .{
        counts.active_element_segments,
        counts.passive_element_segments,
        counts.declarative_element_segments,
        counts.element_initializers,
    });
    out.print("  TABLEOPS get={d} set={d} init={d} drop={d} copy={d} grow={d} size={d} fill={d}\n", .{
        counts.table_get,
        counts.table_set,
        counts.table_init,
        counts.elem_drop,
        counts.table_copy,
        counts.table_grow,
        counts.table_size,
        counts.table_fill,
    });
    out.print("  REFS     null={d}  is-null={d}  func={d}\n", .{
        counts.ref_null,
        counts.ref_is_null,
        counts.ref_func,
    });
    out.print("  SIMD     instructions={d}  v128-types={d}\n", .{
        counts.simd_instructions,
        counts.v128_types,
    });
    out.print("  MEMORY   load-sites={d}  store-sites={d}  copies={d}  fills={d}\n", .{
        counts.memory_loads,
        counts.memory_stores,
        counts.memory_copies,
        counts.memory_fills,
    });
    out.print("  TRAPS    potential-sites={d}  explicit={d}  memory={d}  table={d}\n", .{
        counts.potentially_trapping_instructions,
        counts.explicit_traps,
        counts.potentially_trapping_memory,
        counts.potentially_trapping_table,
    });
    out.print("           division={d}  remainder={d}  float-to-int={d}  call-ref={d}\n", .{
        counts.integer_divisions,
        counts.integer_remainders,
        counts.trapping_float_to_int,
        counts.call_ref,
    });
    if (include_runtime) renderFunctionGraph(out);
}

fn renderStatusLight(out: *Writer) void {
    const style = if (load_error != null)
        SGR_STATUS_FAILED
    else switch (machine.status) {
        .empty => SGR_DIM,
        .ready => if (machine.budget_exhausted) SGR_STATUS_PAUSED else SGR_STATUS_READY,
        .halted => if ((machine.result >> 63) == 0) SGR_STATUS_COMPLETE else SGR_STATUS_FAILED,
        .trapped => SGR_STATUS_FAILED,
    };
    out.raw(style);
    out.text("●");
    out.raw(SGR_RESET);
}

fn renderExecutionColumns(out: *Writer) void {
    const preceding_lines = std.mem.count(u8, out.buffer[0..out.offset], "\n");
    const instruction_window_lines = instructionWindowLines(preceding_lines);
    var left = Writer.init(&left_column_buf);
    left.styled(SGR_BOLD, "INSTRUCTIONS");
    left.text("  ");
    if (machine.status == .halted or machine.status == .trapped) {
        left.styled(SGR_CONTROL_KEY, "r");
        left.text(" restart\n");
    } else {
        left.styled(SGR_CONTROL_KEY, "Space");
        if (machine.budget_exhausted)
            left.text(" continue\n")
        else
            left.text(" run\n");
    }
    if (machine.status == .trapped) {
        left.raw(SGR_ERROR);
        left.print("  trap {s}", .{interpreter.trapName(machine.trap)});
        left.raw(SGR_RESET);
        left.text("\n");
    }
    if (machine.budget_exhausted) {
        left.raw(SGR_WARNING);
        left.print("  paused: {d}-instruction budget", .{last_command_budget});
        left.raw(SGR_RESET);
        left.text("\n");
    }
    renderInstructions(&left, instruction_window_lines);

    var right = Writer.init(&right_column_buf);
    right.styled(SGR_BOLD, "STACKS/LOCALS");
    right.text("  ");
    right.styled(SGR_CONTROL_KEY, "v");
    right.text(switch (variable_format) {
        .hex => " decimal",
        .decimal => " ASCII",
        .ascii => " hex",
    });
    right.text("\n");
    renderGlobals(&right);
    renderStacks(&right);

    var left_offset: usize = 0;
    var right_offset: usize = 0;
    while (left_offset < left.offset or right_offset < right.offset) {
        const left_end = lineEnd(left.buffer[0..left.offset], left_offset);
        const right_end = lineEnd(right.buffer[0..right.offset], right_offset);
        const left_line = left.buffer[left_offset..left_end];
        const right_line = right.buffer[right_offset..right_end];
        out.text(left_line);
        if (right_line.len > 0) {
            const left_visible = visibleTextWidth(left_line);
            if (left_visible < LEFT_COLUMN_WIDTH) writeSpaces(out, LEFT_COLUMN_WIDTH - left_visible);
            out.text(" ");
            out.text(right_line);
        }
        out.text("\n");
        left_offset = nextLineOffset(left.buffer[0..left.offset], left_end);
        right_offset = nextLineOffset(right.buffer[0..right.offset], right_end);
    }
}

fn visibleTextWidth(value: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == 0x1b and index + 1 < value.len and value[index + 1] == '[') {
            index += 2;
            while (index < value.len and value[index] != 'm') index += 1;
            if (index < value.len) index += 1;
            continue;
        }
        if ((value[index] & 0xc0) != 0x80) width += 1;
        index += 1;
    }
    return width;
}

fn lineEnd(buffer: []const u8, start: usize) usize {
    if (start >= buffer.len) return start;
    return std.mem.indexOfScalarPos(u8, buffer, start, '\n') orelse buffer.len;
}

fn nextLineOffset(buffer: []const u8, end: usize) usize {
    return if (end < buffer.len) end + 1 else end;
}

fn writeSpaces(out: *Writer, amount: usize) void {
    const spaces = "                                                                                ";
    var remaining = amount;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        out.text(spaces[0..chunk]);
        remaining -= chunk;
    }
}

fn renderInstructions(out: *Writer, window_lines: usize) void {
    const current = machine.current_instruction;
    const host_input_visible = renderHostInput(out);
    if (current >= machine.instruction_count) {
        const final_instruction = if (step_replay_target < machine.instruction_count)
            step_replay_target
        else
            machine.last_executed_instruction;
        if (final_instruction < machine.instruction_count)
            renderInstructionLine(out, final_instruction, current, .{}, false, instructionIndent(machine.instructions[final_instruction]));
        return;
    }
    const current_function = machine.instructions[current].function_index;
    const current_index: usize = @intCast(current);
    const display_current = if (host_input_visible) std.math.maxInt(u32) else current;
    const targets: interpreter.StepTargets = if (host_input_visible)
        .{ .into = current }
    else
        machine.stepTargets();
    var function_first = current_index;
    while (function_first > 0 and machine.instructions[function_first - 1].function_index == current_function) function_first -= 1;
    var function_end = current_index + 1;
    while (function_end < machine.instruction_count and machine.instructions[function_end].function_index == current_function) function_end += 1;
    var window = instructionWindow(current_index, function_first, function_end, window_lines);
    if (host_input_visible and window.end - window.first == window_lines) window.end -= 1;
    const indent_base = instructionWindowIndentBase(window);
    var current_call_target: ?u32 = null;
    var i: usize = window.first;
    while (i < window.end) : (i += 1) {
        const instruction = machine.instructions[i];
        renderInstructionLine(out, @intCast(i), display_current, targets, false, indent_base);
        if (instruction.op == 0x10 or (instruction.op == 0x11 and i == display_current)) {
            const target = renderCallPreview(out, instruction, display_current, targets);
            if (i == display_current) current_call_target = target;
        }
    }
    renderTargetsOutsideFunction(out, current_function, targets, current_call_target);
    renderTargetsOutsideWindow(out, current_function, window.first, window.end, targets, current_call_target, indent_base);
    renderReplayTargetOutsideWindow(out, window.first, window.end, indent_base);
}

fn renderHostInput(out: *Writer) bool {
    if (!atHostInputStop()) return false;
    out.styled(SGR_CONTROL_KEY, "=>");
    out.text(" ");
    out.raw(SGR_UNDERLINE);
    out.text("host ");
    const input_pointer = machine.inputPointer() catch null;
    if (input_pointer) |pointer| {
        out.text("wrote ");
        out.raw(SGR_VALUE);
        out.print("{d}", .{machine.target_input.len});
        out.raw(SGR_RESET);
        out.raw(SGR_UNDERLINE);
        out.text(" B input at ");
        renderHex32(out, pointer);
    } else {
        out.text("passed no component input");
    }
    out.raw(SGR_RESET);
    out.text("\n");
    return true;
}

fn atHostInputStop() bool {
    return host_input_stop_visible and machine.status == .ready and machine.counters.instructions == 0;
}

const InstructionWindow = struct {
    first: usize,
    end: usize,
};

fn instructionWindowLines(preceding_lines: usize) usize {
    if (viewport_lines == std.math.maxInt(u32)) return DEFAULT_INSTRUCTION_WINDOW_LINES;
    const available = @as(usize, viewport_lines) -| preceding_lines -| 1;
    return std.math.clamp(available, DEFAULT_INSTRUCTION_WINDOW_LINES, MAX_INSTRUCTION_WINDOW_LINES);
}

fn instructionWindow(current: usize, function_first: usize, function_end: usize, window_lines: usize) InstructionWindow {
    const previous = @min(current - function_first, window_lines / 2);
    var first = current - previous;
    const end = @min(function_end, first + window_lines);
    const missing = window_lines -| (end - first);
    first -= @min(missing, first - function_first);
    return .{ .first = first, .end = end };
}

fn instructionWindowIndentBase(window: InstructionWindow) usize {
    var base: usize = std.math.maxInt(usize);
    for (machine.instructions[window.first..window.end]) |instruction| {
        base = @min(base, instructionIndent(instruction));
    }
    return if (base == std.math.maxInt(usize)) 0 else base;
}

fn renderInstructionLine(out: *Writer, index: u32, current: u32, targets: interpreter.StepTargets, child: bool, indent_base: usize) void {
    const instruction = machine.instructions[index];
    const is_current = index == current;
    renderInstructionMarkers(out, index, current, targets);
    if (is_current) out.raw(SGR_UNDERLINE);
    if (child) out.text("  ");
    const indent = @min(instructionIndent(instruction) -| indent_base, MAX_INSTRUCTION_INDENT);
    writeSpaces(out, indent);
    out.print("f{d} ", .{instruction.function_index});
    renderCodeOffset(out, instruction.byte_offset);
    if (is_current) out.raw(SGR_UNDERLINE);
    out.text(" ");
    renderOpcodeName(out, instruction, instructionStyleAt(index));
    if (is_current) out.raw(SGR_UNDERLINE);
    switch (instruction.op) {
        0x10 => out.print(" f{d}", .{instruction.immediate}),
        0x11 => out.print(" (type {d})", .{interpreter.indirectTypeIndex(instruction)}),
        0x0c, 0x0d, 0x20...0x24, 0x28...0x3e, 0x41, 0x42 => out.print(" {d}", .{instruction.immediate}),
        else => {},
    }
    if (instruction.op == 0xfd) switch (interpreter.simdSubopcode(instruction)) {
        0, 11, 93 => out.print(" {d}", .{interpreter.simdImmediate(instruction)}),
        else => {},
    };
    if (instruction.op == 0x03) out.print(" iterations={d}", .{machine.loop_counts[index]});
    out.raw(SGR_RESET);
    if (is_current) out.raw(SGR_UNDERLINE);
    renderStackPointerAnnotation(out, index);
    out.raw(SGR_RESET);
    out.text("\n");
    const continuation_indent = INSTRUCTION_MARKER_WIDTH + 1 + @as(usize, @intFromBool(child)) * 2;
    if (instruction.op == 0x10 or instruction.op == 0x11) {
        var signature_buffer: [512]u8 = undefined;
        var signature = Writer.init(&signature_buffer);
        if (instruction.op == 0x10)
            renderFunctionSignature(&signature, @intCast(instruction.immediate))
        else
            renderTypeSignature(&signature, interpreter.indirectTypeIndex(instruction));
        renderIndentedLines(out, continuation_indent, indent, signature.buffer[0..signature.offset]);
    }
}

fn renderStackPointerAnnotation(out: *Writer, index: u32) void {
    const pattern = render_stack_pointer orelse return;
    if (index != pattern.entry_read and index != pattern.allocation_write and index != pattern.restoration_write) return;
    out.raw(SGR_STORAGE);
    if (index == pattern.entry_read) {
        out.text("  stack pointer");
    } else if (index == pattern.allocation_write) {
        out.print("  allocate {d} B", .{pattern.frame_size});
    } else if (index == pattern.restoration_write) {
        out.print("  restore {d} B", .{pattern.frame_size});
    }
    out.raw(SGR_RESET);
}

fn inferRenderStackPointer() ?StackPointerPattern {
    var first: usize = 0;
    while (first < machine.instruction_count and machine.instructions[first].function_index != machine.render_function) : (first += 1) {}
    if (first + 5 > machine.instruction_count) return null;

    const entry_read = machine.instructions[first];
    const frame_size_instruction = machine.instructions[first + 1];
    const subtract = machine.instructions[first + 2];
    const save_base = machine.instructions[first + 3];
    const allocation_write = machine.instructions[first + 4];
    if (entry_read.function_index != machine.render_function or
        frame_size_instruction.function_index != machine.render_function or
        subtract.function_index != machine.render_function or
        save_base.function_index != machine.render_function or
        allocation_write.function_index != machine.render_function or
        entry_read.depth != 0 or
        entry_read.op != 0x23 or
        frame_size_instruction.op != 0x41 or
        subtract.op != 0x6b or
        save_base.op != 0x22 or
        allocation_write.op != 0x24 or
        allocation_write.immediate != entry_read.immediate)
        return null;

    const global_index: u32 = @intCast(entry_read.immediate);
    const frame_size: u32 = @truncate(frame_size_instruction.immediate);
    if (global_index >= machine.global_count or
        machine.globals[global_index].value_type != .i32 or
        !machine.globals[global_index].mutable or
        frame_size == 0 or
        frame_size > machine.memory_size)
        return null;

    var restoration_write: ?u32 = null;
    var global_write_count: usize = 0;
    var i = first;
    while (i < machine.instruction_count and machine.instructions[i].function_index == machine.render_function) : (i += 1) {
        const instruction = machine.instructions[i];
        if (i != first + 3 and (instruction.op == 0x21 or instruction.op == 0x22) and
            instruction.immediate == save_base.immediate)
            return null;
        if (instruction.op == 0x24 and instruction.immediate == global_index) {
            global_write_count += 1;
            if (i >= first + 8 and instruction.depth == 0) {
                const restore_base = machine.instructions[i - 3];
                const restore_size = machine.instructions[i - 2];
                const add = machine.instructions[i - 1];
                if (restore_base.op == 0x20 and restore_base.immediate == save_base.immediate and
                    restore_size.op == 0x41 and @as(u32, @truncate(restore_size.immediate)) == frame_size and
                    add.op == 0x6a)
                {
                    if (restoration_write != null) return null;
                    restoration_write = @intCast(i);
                }
            }
        }
    }
    const restoration = restoration_write orelse return null;
    if (global_write_count != 2) return null;

    i = first + 5;
    while (i < restoration) : (i += 1) {
        const instruction = machine.instructions[i];
        if (instruction.op == 0x0f or
            ((instruction.op == 0x0c or instruction.op == 0x0d) and instruction.immediate >= instruction.depth))
            return null;
    }

    return .{
        .global_index = global_index,
        .local_index = @intCast(save_base.immediate),
        .frame_size = frame_size,
        .entry_read = @intCast(first),
        .allocation_write = @intCast(first + 4),
        .restoration_write = restoration,
    };
}

fn instructionIndent(instruction: interpreter.Instruction) usize {
    const closes_block = instruction.op == 0x05 or instruction.op == 0x0b;
    return instruction.depth -| @intFromBool(closes_block);
}

fn renderIndentedLines(out: *Writer, indent: usize, extra_indent: usize, value: []const u8) void {
    var offset: usize = 0;
    while (offset < value.len) {
        const end = lineEnd(value, offset);
        writeSpaces(out, indent);
        writeSpaces(out, extra_indent);
        out.text(value[offset..end]);
        out.text("\n");
        offset = nextLineOffset(value, end);
    }
}

const StackPreview = struct {
    value: interpreter.Value,
    value_type: interpreter.ValType,
};

const TransferKind = enum { get, set };

const LocalTransfer = struct {
    kind: TransferKind,
    slot_index: usize,
    stack_index: usize,
    value: interpreter.Value,
    value_type: interpreter.ValType,
};

const GlobalTransfer = struct {
    kind: TransferKind,
    global_index: usize,
    stack_index: usize,
    value: interpreter.Value,
    value_type: interpreter.ValType,
};

const TransferConnector = enum { none, line, source, destination };
const StackDataflowConnector = enum { first_input, input, instruction, output };

fn currentStackPreview(instruction: interpreter.Instruction) ?StackPreview {
    if (instruction.op == 0xfd) {
        const subopcode = interpreter.simdSubopcode(instruction);
        if (subopcode == 12) {
            const offset: usize = interpreter.simdImmediate(instruction);
            if (offset + 16 > machine.module.len) return null;
            return .{
                .value = std.mem.readInt(u128, machine.module[offset..][0..16], .little),
                .value_type = .v128,
            };
        }
        if (subopcode == 0 or subopcode == 93) {
            if (machine.stack_count < 1 or machine.stack_types[machine.stack_count - 1] != .i32) return null;
            const address: u32 = @truncate(machine.stack[machine.stack_count - 1]);
            const effective = @as(u64, address) + interpreter.simdImmediate(instruction);
            const width: usize = if (subopcode == 0) 16 else 8;
            if (effective + width > machine.memory_size) return null;
            const start: usize = @intCast(effective);
            const value = if (subopcode == 0)
                std.mem.readInt(u128, machine.memory[start..][0..16], .little)
            else
                @as(u128, std.mem.readInt(u64, machine.memory[start..][0..8], .little));
            return .{ .value = value, .value_type = .v128 };
        }
        if (subopcode == 13) {
            if (machine.stack_count < 2 or
                machine.stack_types[machine.stack_count - 2] != .v128 or
                machine.stack_types[machine.stack_count - 1] != .v128)
                return null;
            const offset: usize = interpreter.simdImmediate(instruction);
            if (offset + 16 > machine.module.len) return null;
            const value = interpreter.i8x16Shuffle(
                machine.stack[machine.stack_count - 2],
                machine.stack[machine.stack_count - 1],
                machine.module[offset..][0..16],
            ) catch return null;
            return .{ .value = value, .value_type = .v128 };
        }
        if (subopcode == 110) {
            if (machine.stack_count < 2 or
                machine.stack_types[machine.stack_count - 2] != .v128 or
                machine.stack_types[machine.stack_count - 1] != .v128)
                return null;
            return .{
                .value = interpreter.i8x16Add(
                    machine.stack[machine.stack_count - 2],
                    machine.stack[machine.stack_count - 1],
                ),
                .value_type = .v128,
            };
        }
        return null;
    }
    if (instruction.op >= 0x41 and instruction.op <= 0x44) {
        return .{
            .value = instruction.immediate,
            .value_type = switch (instruction.op) {
                0x41 => .i32,
                0x42 => .i64,
                0x43 => .f32,
                0x44 => .f64,
                else => unreachable,
            },
        };
    }
    if (instruction.op == 0x1b) {
        if (machine.stack_count < 3) return null;
        const condition = machine.stack[machine.stack_count - 1];
        const chosen = if (@as(u32, @truncate(condition)) != 0)
            machine.stack_count - 3
        else
            machine.stack_count - 2;
        return .{ .value = machine.stack[chosen], .value_type = machine.stack_types[chosen] };
    }
    if (instruction.op == 0x45 or instruction.op == 0x50) {
        if (machine.stack_count < 1) return null;
        const value = machine.stack[machine.stack_count - 1];
        const result: interpreter.Value = switch (instruction.op) {
            0x45 => @intFromBool(@as(u32, @truncate(value)) == 0),
            0x50 => @intFromBool(value == 0),
            else => unreachable,
        };
        return .{ .value = result, .value_type = .i32 };
    }
    if (instruction.op == 0xa7 or instruction.op == 0xac or instruction.op == 0xad or
        (instruction.op >= 0xc0 and instruction.op <= 0xc4))
    {
        if (machine.stack_count < 1) return null;
        const value = machine.stack[machine.stack_count - 1];
        return switch (instruction.op) {
            0xa7 => .{ .value = @as(u32, @truncate(value)), .value_type = .i32 },
            0xac => .{ .value = @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(value))))))), .value_type = .i64 },
            0xad => .{ .value = @as(u32, @truncate(value)), .value_type = .i64 },
            0xc0 => .{ .value = @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(value))))))), .value_type = .i32 },
            0xc1 => .{ .value = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(value))))))), .value_type = .i32 },
            0xc2 => .{ .value = @as(u64, @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(value))))))), .value_type = .i64 },
            0xc3 => .{ .value = @as(u64, @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(value))))))), .value_type = .i64 },
            0xc4 => .{ .value = @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(value))))))), .value_type = .i64 },
            else => unreachable,
        };
    }
    if (machine.stack_count < 2) return null;
    const left = machine.stack[machine.stack_count - 2];
    const right = machine.stack[machine.stack_count - 1];
    const result: interpreter.Value = switch (instruction.op) {
        0x46 => @intFromBool(@as(u32, @truncate(left)) == @as(u32, @truncate(right))),
        0x47 => @intFromBool(@as(u32, @truncate(left)) != @as(u32, @truncate(right))),
        0x48 => @intFromBool(@as(i32, @bitCast(@as(u32, @truncate(left)))) < @as(i32, @bitCast(@as(u32, @truncate(right))))),
        0x49 => @intFromBool(@as(u32, @truncate(left)) < @as(u32, @truncate(right))),
        0x4a => @intFromBool(@as(i32, @bitCast(@as(u32, @truncate(left)))) > @as(i32, @bitCast(@as(u32, @truncate(right))))),
        0x4b => @intFromBool(@as(u32, @truncate(left)) > @as(u32, @truncate(right))),
        0x4c => @intFromBool(@as(i32, @bitCast(@as(u32, @truncate(left)))) <= @as(i32, @bitCast(@as(u32, @truncate(right))))),
        0x4d => @intFromBool(@as(u32, @truncate(left)) <= @as(u32, @truncate(right))),
        0x4e => @intFromBool(@as(i32, @bitCast(@as(u32, @truncate(left)))) >= @as(i32, @bitCast(@as(u32, @truncate(right))))),
        0x4f => @intFromBool(@as(u32, @truncate(left)) >= @as(u32, @truncate(right))),
        0x51 => @intFromBool(@as(u64, @truncate(left)) == @as(u64, @truncate(right))),
        0x52 => @intFromBool(@as(u64, @truncate(left)) != @as(u64, @truncate(right))),
        0x53 => @intFromBool(@as(i64, @bitCast(@as(u64, @truncate(left)))) < @as(i64, @bitCast(@as(u64, @truncate(right))))),
        0x54 => @intFromBool(@as(u64, @truncate(left)) < @as(u64, @truncate(right))),
        0x55 => @intFromBool(@as(i64, @bitCast(@as(u64, @truncate(left)))) > @as(i64, @bitCast(@as(u64, @truncate(right))))),
        0x56 => @intFromBool(@as(u64, @truncate(left)) > @as(u64, @truncate(right))),
        0x57 => @intFromBool(@as(i64, @bitCast(@as(u64, @truncate(left)))) <= @as(i64, @bitCast(@as(u64, @truncate(right))))),
        0x58 => @intFromBool(@as(u64, @truncate(left)) <= @as(u64, @truncate(right))),
        0x59 => @intFromBool(@as(i64, @bitCast(@as(u64, @truncate(left)))) >= @as(i64, @bitCast(@as(u64, @truncate(right))))),
        0x5a => @intFromBool(@as(u64, @truncate(left)) >= @as(u64, @truncate(right))),
        0x6a => @as(u32, @truncate(left)) +% @as(u32, @truncate(right)),
        0x6b => @as(u32, @truncate(left)) -% @as(u32, @truncate(right)),
        0x6c => @as(u32, @truncate(left)) *% @as(u32, @truncate(right)),
        0x71 => @as(u32, @truncate(left)) & @as(u32, @truncate(right)),
        0x72 => @as(u32, @truncate(left)) | @as(u32, @truncate(right)),
        0x73 => @as(u32, @truncate(left)) ^ @as(u32, @truncate(right)),
        0x74 => @as(u32, @truncate(left)) << @intCast(right & 31),
        0x75 => @as(u32, @bitCast(@as(i32, @bitCast(@as(u32, @truncate(left)))) >> @intCast(right & 31))),
        0x76 => @as(u32, @truncate(left)) >> @intCast(right & 31),
        0x77 => std.math.rotl(u32, @truncate(left), @as(u32, @truncate(right))),
        0x78 => std.math.rotr(u32, @truncate(left), @as(u32, @truncate(right))),
        0x7c => @as(u64, @truncate(left)) +% @as(u64, @truncate(right)),
        0x7d => @as(u64, @truncate(left)) -% @as(u64, @truncate(right)),
        0x7e => @as(u64, @truncate(left)) *% @as(u64, @truncate(right)),
        0x83 => @as(u64, @truncate(left)) & @as(u64, @truncate(right)),
        0x84 => @as(u64, @truncate(left)) | @as(u64, @truncate(right)),
        0x85 => @as(u64, @truncate(left)) ^ @as(u64, @truncate(right)),
        0x86 => @as(u64, @truncate(left)) << @intCast(right & 63),
        0x87 => @as(u64, @bitCast(@as(i64, @bitCast(@as(u64, @truncate(left)))) >> @intCast(right & 63))),
        0x88 => @as(u64, @truncate(left)) >> @intCast(right & 63),
        0x89 => std.math.rotl(u64, @truncate(left), @as(u64, @truncate(right))),
        0x8a => std.math.rotr(u64, @truncate(left), @as(u64, @truncate(right))),
        else => return null,
    };
    const value_type: interpreter.ValType = if (instruction.op <= 0x78) .i32 else .i64;
    return .{ .value = result, .value_type = value_type };
}

fn renderCurrentStackPreview(out: *Writer) void {
    if (atHostInputStop()) return;
    if (machine.current_instruction >= machine.instruction_count) return;
    const instruction = machine.instructions[machine.current_instruction];
    if (instruction.op == 0xfc) {
        renderCurrentBulkMemoryPreview(out, instruction);
        return;
    }
    const preview = currentStackPreview(instruction) orelse return;
    const style = instructionStyleAt(machine.current_instruction);
    const stack_dataflow = machine.currentStackInputCount() > 0;
    if (stack_dataflow)
        renderStackDataflowConnector(out, .instruction, style)
    else
        out.text("  ");
    renderOpcodeName(out, instruction, style);
    out.raw(SGR_RESET);
    out.text("\n");
    if (stack_dataflow)
        renderStackDataflowConnector(out, .output, style)
    else {
        out.raw(style);
        out.text("   ──▶ ");
        out.raw(SGR_RESET);
    }
    out.text("next stack[");
    out.print("{d}] ", .{machine.stack_count - machine.currentStackInputCount()});
    out.raw(SGR_RESET);
    renderTypedValue(out, preview.value_type, preview.value);
    out.raw(SGR_RESET);
    out.text("\n");
}

fn renderCurrentBulkMemoryPreview(out: *Writer, instruction: interpreter.Instruction) void {
    if (machine.stack_count < 3) return;
    const destination: u32 = @truncate(machine.stack[machine.stack_count - 3]);
    const operand: u32 = @truncate(machine.stack[machine.stack_count - 2]);
    const length: u32 = @truncate(machine.stack[machine.stack_count - 1]);
    out.text("  ");
    renderOpcodeName(out, instruction, SGR_WRITE);
    out.text("\n");
    out.raw(SGR_WRITE_TARGET);
    out.text("   ──▶ dst ");
    renderBareHex32(out, destination);
    out.raw(SGR_WRITE_TARGET);
    out.print("+{d}\n", .{length});
    if (instruction.immediate == 10) {
        out.raw(SGR_READ);
        out.text("       src ");
        renderBareHex32(out, operand);
        out.raw(SGR_RESET);
        out.text("\n");
    } else if (instruction.immediate == 11) {
        out.raw(SGR_INSTRUCTION);
        out.print("       byte {x:0>2}\n", .{@as(u8, @truncate(operand))});
        out.raw(SGR_RESET);
    }
}

fn renderTypedValue(out: *Writer, value_type: interpreter.ValType, value: interpreter.Value) void {
    switch (value_type) {
        .i32, .f32 => {
            out.print("{s} ", .{@tagName(value_type)});
            out.raw(SGR_VALUE);
            renderTypedScalarBare(out, value_type, value);
            out.raw(SGR_RESET);
        },
        .i64, .f64 => {
            out.print("{s} ", .{@tagName(value_type)});
            out.raw(SGR_VALUE);
            renderTypedScalarBare(out, value_type, value);
            out.raw(SGR_RESET);
        },
        .v128 => {
            out.text("v128 ");
            out.raw(SGR_VALUE);
            out.print("0x{x:0>16}", .{@as(u64, @truncate(value >> 64))});
            out.raw(SGR_RESET);
            out.text("\n      ");
            out.raw(SGR_VALUE);
            out.print("0x{x:0>16}", .{@as(u64, @truncate(value))});
            out.raw(SGR_RESET);
        },
    }
}

fn renderFunctionSignature(out: *Writer, function_index: u32) void {
    const signature = machine.functionSignature(function_index) orelse return;
    renderSignature(out, signature);
}

fn renderTypeSignature(out: *Writer, type_index: u32) void {
    const signature = machine.typeSignature(type_index) orelse return;
    renderSignature(out, signature);
}

fn renderSignature(out: *Writer, signature: interpreter.FunctionSignature) void {
    if (signature.parameters.len > 1) {
        for (signature.parameters) |parameter| out.print(";; (param {s})\n", .{@tagName(parameter)});
        out.text(";; (result");
        if (signature.result) |result| out.print(" {s}", .{@tagName(result)});
        out.text(")");
        return;
    }
    out.text(";; (param");
    for (signature.parameters) |parameter| out.print(" {s}", .{@tagName(parameter)});
    out.text(") (result");
    if (signature.result) |result| out.print(" {s}", .{@tagName(result)});
    out.text(")");
}

fn renderInstructionMarkers(out: *Writer, index: u32, current: u32, targets: interpreter.StepTargets) void {
    var length: usize = 0;
    if (step_replay_available and step_replay_count > 0 and index == step_replay_target) {
        out.styled(SGR_CONTROL_KEY, "↑");
        length += 1;
    }
    if (index == current) {
        out.styled(SGR_CONTROL_KEY, "=>");
        length += 2;
    }
    if (index == targets.into) {
        out.styled(SGR_CONTROL_KEY, "↓");
        length += 1;
    }
    if (index == targets.over and targets.over != targets.into) {
        out.styled(SGR_CONTROL_KEY, "n");
        length += 1;
    }
    if (index == targets.out) {
        out.styled(SGR_CONTROL_KEY, "f");
        length += 1;
    }
    if (machine.counters.instructions >= 2 and index == restartTarget()) {
        out.styled(SGR_CONTROL_KEY, "r");
        length += 1;
    }
    writeSpaces(out, INSTRUCTION_MARKER_WIDTH -| length);
}

fn renderReplayTargetOutsideWindow(out: *Writer, first: usize, end: usize, indent_base: usize) void {
    if (!step_replay_available or step_replay_count == 0 or step_replay_target >= machine.instruction_count) return;
    if (step_replay_target >= first and step_replay_target < end) return;
    const targets = machine.stepTargets();
    if (step_replay_target == targets.into or step_replay_target == targets.over or step_replay_target == targets.out) return;
    renderInstructionLine(out, step_replay_target, machine.current_instruction, targets, false, indent_base);
}

fn restartTarget() u32 {
    for (machine.instructions[0..machine.instruction_count], 0..) |instruction, index| {
        if (instruction.function_index == machine.render_function) return @intCast(index);
    }
    return std.math.maxInt(u32);
}

fn renderCallPreview(out: *Writer, call: interpreter.Instruction, current: u32, targets: interpreter.StepTargets) ?u32 {
    const function_index = machine.callTarget(call) orelse return null;
    for (machine.instructions[0..machine.instruction_count], 0..) |instruction, index| {
        if (instruction.function_index != function_index) continue;
        const target: u32 = @intCast(index);
        renderInstructionLine(out, target, current, targets, true, instructionIndent(instruction));
        writeSpaces(out, INSTRUCTION_MARKER_WIDTH + 1);
        out.text("…\n");
        return target;
    }
    return null;
}

fn renderTargetsOutsideFunction(out: *Writer, current_function: u32, targets: interpreter.StepTargets, skip: ?u32) void {
    const target_list = [_]u32{ targets.into, targets.over, targets.out };
    for (target_list, 0..) |target, target_index| {
        if (target >= machine.instruction_count) continue;
        if (skip != null and target == skip.?) continue;
        if (machine.instructions[target].function_index == current_function) continue;
        var duplicate = false;
        for (target_list[0..target_index]) |earlier| {
            if (earlier == target) duplicate = true;
        }
        if (!duplicate) renderInstructionLine(out, target, machine.current_instruction, targets, false, instructionIndent(machine.instructions[target]));
    }
}

fn renderTargetsOutsideWindow(out: *Writer, current_function: u32, first: usize, end: usize, targets: interpreter.StepTargets, skip: ?u32, indent_base: usize) void {
    const target_list = [_]u32{ targets.into, targets.over, targets.out };
    for (target_list, 0..) |target, target_index| {
        if (target >= machine.instruction_count) continue;
        if (skip != null and target == skip.?) continue;
        if (machine.instructions[target].function_index != current_function) continue;
        if (target >= first and target < end) continue;
        var duplicate = false;
        for (target_list[0..target_index]) |earlier| {
            if (earlier == target) duplicate = true;
        }
        if (!duplicate) renderInstructionLine(out, target, machine.current_instruction, targets, false, indent_base);
    }
}

fn renderStacks(out: *Writer) void {
    const frame_index = if (machine.frame_count == 0) null else machine.frame_count - 1;
    const local_transfer = if (frame_index) |index| currentLocalTransfer(index) else null;
    const global_transfer = currentGlobalTransfer();
    const stack_dataflow = hasStackDataflowPreview();
    const stack_dataflow_style = if (machine.current_instruction < machine.instruction_count)
        instructionStyleAt(machine.current_instruction)
    else
        SGR_RESET;
    if (frame_index == null) {
        out.text("  calls empty\n");
        renderStackSlice(out, 0, machine.stack_count, true, local_transfer, global_transfer, stack_dataflow, stack_dataflow_style);
        return;
    }

    const active_frame = frame_index.?;
    renderFrameHeading(out, active_frame, 0, if (global_transfer) |transfer| transfer.kind else null, false);
    renderFrameValues(out, active_frame, if (global_transfer) |transfer| transfer.kind else null);
    renderStackSlice(
        out,
        machine.frames[active_frame].stack_base,
        machine.stack_count,
        true,
        local_transfer,
        global_transfer,
        stack_dataflow,
        stack_dataflow_style,
    );
    renderNextStackValues(out, local_transfer, global_transfer);
    renderCurrentStackPreview(out);

    var count: usize = 1;
    var i = active_frame;
    while (i > 0 and count < 12) : (count += 1) {
        i -= 1;
        renderFrameHeading(out, i, count, null, true);
        renderStackSlice(out, machine.frames[i].stack_base, machine.frames[i + 1].stack_base, false, null, null, false, SGR_RESET);
    }
}

fn renderFrameHeading(out: *Writer, frame_index: usize, count: usize, transfer_kind: ?TransferKind, dimmed: bool) void {
    if (transfer_kind) |kind|
        renderTopLevelTransferConnector(out, .line, kind)
    else
        out.text("  ");
    if (dimmed) out.raw(SGR_DIM);
    const frame = machine.frames[frame_index];
    if (machine.functionName(frame.function_index)) |name| {
        const shown_name = name[0..@min(name.len, 16)];
        out.print("#{d} f{d} {s}{s}", .{
            count,
            frame.function_index,
            shown_name,
            if (shown_name.len < name.len) "…" else "",
        });
    } else {
        out.print("#{d} f{d}", .{ count, frame.function_index });
    }
    if (dimmed) out.raw(SGR_RESET);
    out.text("\n");
}

fn renderStackSlice(
    out: *Writer,
    raw_start: usize,
    end: usize,
    active: bool,
    local_transfer: ?LocalTransfer,
    global_transfer: ?GlobalTransfer,
    stack_dataflow: bool,
    stack_dataflow_style: []const u8,
) void {
    const first_shown = machine.stack_count - @min(machine.stack_count, 12);
    const start = @max(raw_start, first_shown);
    if (start >= end) {
        if (!active) return;
        if (global_transfer != null)
            renderTransferConnector(out, .line, global_transfer.?.kind)
        else if (local_transfer != null and local_transfer.?.kind == .get)
            renderTransferConnector(out, .line, .get)
        else
            out.text("    ");
        out.text("stack empty\n");
        return;
    }
    const input_count = if (active) @min(machine.currentStackInputCount(), machine.stack_count) else 0;
    const first_input = machine.stack_count - input_count;
    const input_style = if (active and machine.current_instruction < machine.instruction_count)
        instructionStyleAt(machine.current_instruction)
    else
        SGR_RESET;
    var i = start;
    while (i < end) : (i += 1) {
        const transfer_source = active and local_transfer != null and
            local_transfer.?.kind == .set and
            local_transfer.?.stack_index == i;
        if (active and local_transfer != null) {
            const transfer = local_transfer.?;
            renderTransferConnector(out, if (transfer_source) .source else .line, transfer.kind);
        } else if (active and global_transfer != null) {
            const transfer = global_transfer.?;
            const global_source = transfer.kind == .set and transfer.stack_index == i;
            renderTransferConnector(out, if (global_source) .source else .line, transfer.kind);
        } else if (active and stack_dataflow and i >= first_input) {
            renderStackDataflowConnector(out, if (i == first_input) .first_input else .input, stack_dataflow_style);
        } else {
            out.text("    ");
        }
        if (!active) out.raw(SGR_DIM);
        if (active and i >= first_input) {
            const style = currentStackInputStyle(i, input_style);
            out.raw(style);
            out.print("stack[{d}] {s} ", .{ i, @tagName(machine.stack_types[i]) });
            switch (machine.stack_types[i]) {
                .i32, .f32, .i64, .f64 => renderTypedScalarBare(out, machine.stack_types[i], machine.stack[i]),
                .v128 => out.print("0x{x:0>16}\n              0x{x:0>16}", .{
                    @as(u64, @truncate(machine.stack[i] >> 64)),
                    @as(u64, @truncate(machine.stack[i])),
                }),
            }
            out.raw(SGR_RESET);
        } else {
            out.print("stack[{d}] ", .{i});
            renderTypedValue(out, machine.stack_types[i], machine.stack[i]);
        }
        if (!active) out.raw(SGR_RESET);
        out.text("\n");
    }
}

fn renderNextStackValues(out: *Writer, local_transfer: ?LocalTransfer, global_transfer: ?GlobalTransfer) void {
    if (local_transfer) |transfer| {
        if (transfer.kind == .get) {
            renderTransferConnector(out, .destination, transfer.kind);
            out.raw(SGR_READ);
            out.text("next stack[");
            out.print("{d}] ", .{transfer.stack_index});
            renderTypedValue(out, transfer.value_type, transfer.value);
            out.raw(SGR_RESET);
            out.text("\n");
        }
    }
    if (global_transfer) |transfer| {
        if (transfer.kind == .get) {
            renderTransferConnector(out, .destination, transfer.kind);
            out.raw(SGR_READ);
            out.print("next stack[{d}] ", .{transfer.stack_index});
            renderTypedValue(out, transfer.value_type, transfer.value);
            out.raw(SGR_RESET);
            out.text("\n");
        }
    }
}

fn hasStackDataflowPreview() bool {
    if (atHostInputStop() or machine.current_instruction >= machine.instruction_count) return false;
    if (machine.currentStackInputCount() == 0) return false;
    return currentStackPreview(machine.instructions[machine.current_instruction]) != null;
}

fn currentStackInputStyle(stack_index: usize, default: []const u8) []const u8 {
    if (machine.current_instruction >= machine.instruction_count) return default;
    const instruction = machine.instructions[machine.current_instruction];
    if (instruction.op == 0xfc and machine.stack_count >= 3) {
        if (stack_index == machine.stack_count - 3) return SGR_WRITE_TARGET;
        if (instruction.immediate == 10 and stack_index == machine.stack_count - 2) return SGR_READ;
        return SGR_INSTRUCTION;
    }
    if (instruction.op != 0x1b or machine.stack_count < 3) return default;
    const condition = machine.stack[machine.stack_count - 1];
    const chosen = if (@as(u32, @truncate(condition)) != 0)
        machine.stack_count - 3
    else
        machine.stack_count - 2;
    return if (stack_index == chosen) SGR_SELECTED_VALUE else default;
}

fn renderGlobals(out: *Writer) void {
    if (machine.global_count == 0) {
        out.text("  globals none\n");
        return;
    }
    const read_target = currentGlobalReadTarget();
    const write_target = recentGlobalWriteTarget();
    const shown = @min(machine.global_count, 12);
    const transfer = currentGlobalTransfer();
    for (machine.globals[0..shown], 0..) |global, index| {
        const highlight_style: ?[]const u8 = if (read_target != null and read_target.? == index)
            SGR_READ
        else if (write_target != null and write_target.? == index)
            SGR_WRITE_TARGET
        else
            null;
        if (transfer) |active_transfer| {
            const connector: TransferConnector = if (index == active_transfer.global_index)
                if (active_transfer.kind == .get) .source else .none
            else if (index > active_transfer.global_index)
                .line
            else
                .none;
            renderTopLevelTransferConnector(out, connector, active_transfer.kind);
        } else {
            out.text("  ");
        }
        if (highlight_style) |style| out.raw(style);
        out.print("global[{d}] ", .{index});
        if (highlight_style != null) {
            if (global.value_type == .v128)
                out.print("v128 0x{x:0>16}\n               0x{x:0>16}", .{
                    @as(u64, @truncate(global.value >> 64)),
                    @as(u64, @truncate(global.value)),
                })
            else
                renderStorageScalarBare(out, global.value_type, global.value);
            out.raw(SGR_RESET);
        } else {
            if (global.value_type == .v128)
                renderTypedValue(out, global.value_type, global.value)
            else
                renderStorageScalar(out, global.value_type, global.value);
        }
        out.text("\n");
        if (transfer) |active_transfer| {
            if (active_transfer.kind == .set and index == active_transfer.global_index) {
                renderTopLevelTransferConnector(out, .destination, active_transfer.kind);
                renderNextStorageValue(out, "global", active_transfer.global_index, active_transfer.value_type, active_transfer.value);
            }
        }
        if (render_stack_pointer) |pattern| {
            if (pattern.global_index == index) {
                if (transfer != null and index >= transfer.?.global_index)
                    renderTransferConnector(out, .line, transfer.?.kind)
                else
                    out.text("    ");
                out.styled(SGR_STORAGE, "stack pointer (inferred)");
                out.text("\n");
            }
        }
    }
    if (shown < machine.global_count) {
        if (transfer != null and transfer.?.global_index < shown)
            renderTopLevelTransferConnector(out, .line, transfer.?.kind)
        else
            out.text("  ");
        out.print("... {d} more globals\n", .{machine.global_count - shown});
    }
}

fn currentGlobalTransfer() ?GlobalTransfer {
    if (atHostInputStop()) return null;
    if (machine.current_instruction >= machine.instruction_count) return null;
    const instruction = machine.instructions[machine.current_instruction];
    if (instruction.op != 0x23 and instruction.op != 0x24) return null;
    const global_index: usize = @intCast(instruction.immediate);
    if (global_index >= machine.global_count or global_index >= 12) return null;
    const global = machine.globals[global_index];
    if (instruction.op == 0x23) {
        return .{
            .kind = .get,
            .global_index = global_index,
            .stack_index = machine.stack_count,
            .value = global.value,
            .value_type = global.value_type,
        };
    }
    if (machine.stack_count == 0) return null;
    return .{
        .kind = .set,
        .global_index = global_index,
        .stack_index = machine.stack_count - 1,
        .value = machine.stack[machine.stack_count - 1],
        .value_type = machine.stack_types[machine.stack_count - 1],
    };
}

fn currentGlobalReadTarget() ?usize {
    if (atHostInputStop()) return null;
    if (machine.current_instruction >= machine.instruction_count) return null;
    const instruction = machine.instructions[machine.current_instruction];
    if (instruction.op != 0x23) return null;
    return @intCast(instruction.immediate);
}

fn recentGlobalWriteTarget() ?usize {
    if (recent_global_write) |target| return @intCast(target);
    return null;
}

fn renderFrameValues(out: *Writer, frame_index: usize, global_transfer_kind: ?TransferKind) void {
    const parameters = machine.frameParameters(frame_index);
    const locals = machine.frameDefinedLocals(frame_index);
    if (parameters.len == 0 and locals.len == 0) {
        if (global_transfer_kind) |kind|
            renderTransferConnector(out, .line, kind)
        else
            out.text("    ");
        out.text("params none   locals none\n");
        return;
    }
    const transfer = currentLocalTransfer(frame_index);
    const read_target = if (transfer != null and transfer.?.kind == .get) transfer.?.slot_index else null;
    const write_target = recentLocalWriteTarget(frame_index);
    const parameter_read_target = if (read_target != null and read_target.? < parameters.len) read_target else null;
    const local_read_target = if (read_target != null and read_target.? >= parameters.len)
        read_target.? - parameters.len
    else
        null;
    const parameter_write_target = if (write_target != null and write_target.? < parameters.len) write_target else null;
    const local_write_target = if (write_target != null and write_target.? >= parameters.len)
        write_target.? - parameters.len
    else
        null;
    renderValueSlots(out, "param", parameters, parameter_read_target, parameter_write_target, transfer, 0, global_transfer_kind);
    renderValueSlots(out, "local", locals, local_read_target, local_write_target, transfer, parameters.len, global_transfer_kind);
}

fn currentLocalTransfer(frame_index: usize) ?LocalTransfer {
    if (atHostInputStop()) return null;
    if (frame_index + 1 != machine.frame_count or machine.current_instruction >= machine.instruction_count) return null;
    const instruction = machine.instructions[machine.current_instruction];
    if (instruction.op < 0x20 or instruction.op > 0x22) return null;
    const frame = machine.frames[frame_index];
    const slot_index: usize = @intCast(instruction.immediate);
    if (slot_index >= frame.locals_count) return null;
    const absolute_slot = frame.locals_base + slot_index;
    if (instruction.op == 0x20) {
        return .{
            .kind = .get,
            .slot_index = slot_index,
            .stack_index = machine.stack_count,
            .value = machine.locals[absolute_slot],
            .value_type = machine.local_types[absolute_slot],
        };
    }
    if (machine.stack_count == 0) return null;
    return .{
        .kind = .set,
        .slot_index = slot_index,
        .stack_index = machine.stack_count - 1,
        .value = machine.stack[machine.stack_count - 1],
        .value_type = machine.stack_types[machine.stack_count - 1],
    };
}

fn recentLocalWriteTarget(frame_index: usize) ?usize {
    if (frame_index + 1 != machine.frame_count) return null;
    if (recent_local_write_frame_count == machine.frame_count) {
        if (recent_local_write) |target| return @intCast(target);
    }
    return null;
}

fn renderValueSlots(
    out: *Writer,
    label: []const u8,
    values: []const interpreter.Value,
    read_target: ?usize,
    write_target: ?usize,
    transfer: ?LocalTransfer,
    slot_offset: usize,
    global_transfer_kind: ?TransferKind,
) void {
    if (values.len == 0) {
        if (transfer != null and transfer.?.slot_index < slot_offset)
            renderTransferConnector(out, .line, transfer.?.kind)
        else if (global_transfer_kind) |kind|
            renderTransferConnector(out, .line, kind)
        else
            out.text("    ");
        out.print("{s}s none\n", .{label});
        return;
    }
    const shown = @min(values.len, 12);
    for (values[0..shown], 0..) |value, index| {
        const is_read_target = read_target != null and read_target.? == index;
        const is_write_target = write_target != null and write_target.? == index;
        const style: ?[]const u8 = if (is_read_target)
            SGR_READ
        else if (is_write_target)
            SGR_WRITE_TARGET
        else
            null;
        const connector: TransferConnector = if (transfer) |active_transfer| blk: {
            const slot_index = slot_offset + index;
            if (slot_index == active_transfer.slot_index) {
                break :blk if (active_transfer.kind == .get) .source else .none;
            }
            break :blk if (slot_index > active_transfer.slot_index) .line else .none;
        } else .none;
        if (transfer) |active_transfer|
            renderTransferConnector(out, connector, active_transfer.kind)
        else if (global_transfer_kind) |kind|
            renderTransferConnector(out, .line, kind)
        else
            out.text("    ");
        if (style) |active_style| out.raw(active_style);
        out.print("{s}[{d}] ", .{ label, index });
        const value_type = machine.local_types[machine.frames[machine.frame_count - 1].locals_base + slot_offset + index];
        if (style != null) {
            if (value_type == .v128)
                out.print("v128 0x{x:0>16}\n               0x{x:0>16}", .{
                    @as(u64, @truncate(value >> 64)),
                    @as(u64, @truncate(value)),
                })
            else
                renderStorageScalarBare(out, value_type, value);
            out.raw(SGR_RESET);
        } else {
            if (value_type == .v128)
                renderTypedValue(out, value_type, value)
            else
                renderStorageScalar(out, value_type, value);
        }
        out.text("\n");
        if (transfer) |active_transfer| {
            const slot_index = slot_offset + index;
            if (active_transfer.kind == .set and slot_index == active_transfer.slot_index) {
                renderTransferConnector(out, .destination, active_transfer.kind);
                renderNextStorageValue(out, label, index, active_transfer.value_type, active_transfer.value);
            }
        }
    }
    if (shown < values.len) {
        if (transfer != null and transfer.?.slot_index < slot_offset + shown)
            renderTransferConnector(out, .line, transfer.?.kind)
        else if (global_transfer_kind) |kind|
            renderTransferConnector(out, .line, kind)
        else
            out.text("    ");
        out.print("... {d} more {s}s\n", .{ values.len - shown, label });
    }
}

fn renderNextStorageValue(out: *Writer, label: []const u8, index: usize, value_type: interpreter.ValType, value: interpreter.Value) void {
    out.raw(SGR_WRITE);
    out.print("next {s}[{d}] ", .{ label, index });
    renderTypedValue(out, value_type, value);
    out.raw(SGR_RESET);
    out.text("\n");
}

fn renderTransferConnector(out: *Writer, connector: TransferConnector, kind: TransferKind) void {
    if (connector == .none) {
        out.text("    ");
        return;
    }
    out.raw(if (kind == .get) SGR_READ else SGR_WRITE);
    out.text(switch (connector) {
        .none => unreachable,
        .line => "│   ",
        .source => if (kind == .get) "┌─  " else "└─  ",
        .destination => if (kind == .get) "└─▶ " else "┌─▶ ",
    });
    out.raw(SGR_RESET);
}

fn renderStackDataflowConnector(out: *Writer, connector: StackDataflowConnector, style: []const u8) void {
    out.raw(style);
    out.text(switch (connector) {
        .first_input => "┌─  ",
        .input => "├─  ",
        .instruction => "├─  ",
        .output => "└─▶ ",
    });
    out.raw(SGR_RESET);
}

fn renderTopLevelTransferConnector(out: *Writer, connector: TransferConnector, kind: TransferKind) void {
    if (connector == .none) {
        out.text("  ");
        return;
    }
    out.raw(if (kind == .get) SGR_READ else SGR_WRITE);
    out.text(switch (connector) {
        .none => unreachable,
        .line => "│ ",
        .source => if (kind == .get) "┌─" else "└─",
        .destination => if (kind == .get) "└▶" else "┌▶",
    });
    out.raw(SGR_RESET);
}

fn renderFunctionGraph(out: *Writer) void {
    var order: [interpreter.MAX_FUNCTIONS]u32 = undefined;
    const function_count = collectReachableFunctions(&order);
    out.print("  FUNCTIONS reachable={d}/{d}  ", .{ function_count, machine.function_count });
    out.raw(SGR_LOOP_CALL);
    out.text("→ direct  ⇢ possible indirect");
    out.raw(SGR_RESET);
    out.text("\n");
    for (order[0..function_count]) |function_index| {
        out.print("    f{d}", .{function_index});
        if (machine.functionName(function_index)) |name| {
            const shown_name = name[0..@min(name.len, 18)];
            out.print(" {s}{s}", .{ shown_name, if (shown_name.len < name.len) "…" else "" });
        }
        out.text("  calls=");
        out.raw(SGR_LOOP_CALL);
        out.print("{d}", .{machine.function_invocations[function_index]});
        out.raw(SGR_RESET);
        renderFunctionCallEdges(out, function_index);
        out.text("\n");
        renderFunctionLoops(out, function_index);
    }
}

fn collectReachableFunctions(order: *[interpreter.MAX_FUNCTIONS]u32) usize {
    if (machine.function_count == 0 or machine.render_function >= machine.function_count) return 0;
    var seen = [_]bool{false} ** interpreter.MAX_FUNCTIONS;
    seen[machine.render_function] = true;
    order[0] = machine.render_function;
    var count: usize = 1;
    var cursor: usize = 0;
    while (cursor < count) : (cursor += 1) {
        const caller = order[cursor];
        const range = machine.functionInstructionRange(caller) orelse continue;
        for (machine.instructions[range.first..range.end]) |instruction| {
            if (instruction.op == 0x10) {
                appendReachableFunction(order, &seen, &count, @intCast(instruction.immediate));
            } else if (instruction.op == 0x11) {
                var target: u32 = 0;
                while (target < machine.function_count) : (target += 1) {
                    if (machine.indirectCallMayTarget(instruction, target)) {
                        appendReachableFunction(order, &seen, &count, target);
                    }
                }
            }
        }
    }
    return count;
}

fn appendReachableFunction(
    order: *[interpreter.MAX_FUNCTIONS]u32,
    seen: *[interpreter.MAX_FUNCTIONS]bool,
    count: *usize,
    function_index: u32,
) void {
    if (function_index >= machine.function_count or seen[function_index]) return;
    seen[function_index] = true;
    order[count.*] = function_index;
    count.* += 1;
}

fn renderFunctionCallEdges(out: *Writer, caller: u32) void {
    const range = machine.functionInstructionRange(caller) orelse return;
    var direct_sites = [_]u32{0} ** interpreter.MAX_FUNCTIONS;
    var indirect_targets = [_]bool{false} ** interpreter.MAX_FUNCTIONS;
    for (machine.instructions[range.first..range.end]) |instruction| {
        if (instruction.op == 0x10) {
            const target: u32 = @intCast(instruction.immediate);
            if (target < machine.function_count) direct_sites[target] +|= 1;
        } else if (instruction.op == 0x11) {
            var target: u32 = 0;
            while (target < machine.function_count) : (target += 1) {
                if (machine.indirectCallMayTarget(instruction, target)) indirect_targets[target] = true;
            }
        }
    }

    var total: usize = 0;
    for (0..machine.function_count) |target| {
        if (direct_sites[target] != 0 or indirect_targets[target]) total += 1;
    }
    if (total == 0) return;

    var shown: usize = 0;
    out.raw(SGR_LOOP_CALL);
    inline for (0..2) |edge_kind| {
        var group_started = false;
        for (0..machine.function_count) |target| {
            const matches = if (edge_kind == 0)
                direct_sites[target] != 0
            else
                direct_sites[target] == 0 and indirect_targets[target];
            if (!matches or shown == 4) continue;
            if (!group_started) {
                out.text(if (edge_kind == 0) "  → " else "  ⇢ ");
                group_started = true;
            } else {
                out.text(", ");
            }
            out.print("f{d}", .{target});
            if (direct_sites[target] > 1) out.print(" ×{d}", .{direct_sites[target]});
            shown += 1;
        }
    }
    if (shown < total) out.print("  … +{d}", .{total - shown});
    out.raw(SGR_RESET);
}

fn renderFunctionLoops(out: *Writer, function_index: u32) void {
    const range = machine.functionInstructionRange(function_index) orelse return;
    var i: usize = range.first;
    while (i < range.end) : (i += 1) {
        const instruction = machine.instructions[i];
        if (instruction.op != 0x03) continue;
        out.text("      ");
        out.raw(SGR_LOOP_CALL);
        out.text("loop");
        out.raw(SGR_RESET);
        out.text(" ");
        renderCodeOffset(out, instruction.byte_offset);
        out.text("  iterations=");
        out.raw(SGR_LOOP_CALL);
        out.print("{d}", .{machine.loop_counts[i]});
        out.raw(SGR_RESET);
        out.text("\n");
    }
}

fn renderMemoryMap(out: *Writer) void {
    if (machine.memory_pages == 0) return;
    out.text("  KEY  ▘/▝ top read/write  ▖/▗ bottom read/write  ▀/▄ both  █ all  ");
    out.styled(SGR_DIM, "░");
    out.text(" untouched\n");
    const page_count: usize = machine.memory_pages;
    const default_columns: usize = 80;
    const viewport_width: usize = if (viewport_columns == std.math.maxInt(u32))
        default_columns
    else
        @intCast(viewport_columns);
    const row_prefix_columns: usize = 12;
    const usable_columns: usize = if (viewport_width > row_prefix_columns) viewport_width - row_prefix_columns else 1;
    const columns = usable_columns;
    const current_page = @min(memory_view_offset / interpreter.WASM_PAGE_BYTES, page_count - 1);
    const pages_per_row: usize = columns * 2;
    const row_count = (page_count + pages_per_row - 1) / pages_per_row;
    for (0..row_count) |row| {
        const first_page = row * pages_per_row;
        out.text("  ");
        renderBareHex32(out, @intCast(first_page * interpreter.WASM_PAGE_BYTES));
        out.text("  ");
        const remaining_pages = page_count - first_page;
        const cells = @min(columns, (remaining_pages + 1) / 2);
        for (0..cells) |cell| {
            const top_page = first_page + cell * 2;
            const bottom_page = top_page + 1;
            if (current_page == top_page or current_page == bottom_page) out.raw(SGR_UNDERLINE);
            const top = memoryMapActivityBits(machine.memoryPageActivity(top_page), true);
            const bottom = if (bottom_page < page_count)
                memoryMapActivityBits(machine.memoryPageActivity(bottom_page), false)
            else
                0;
            const bits = top | bottom;
            if (bits == 0) out.raw(SGR_DIM);
            out.text(memoryMapGlyph(bits));
            out.raw(SGR_RESET);
        }
        out.text("\n");
    }
}

fn memoryMapActivityBits(activity: interpreter.MemoryPageActivity, top: bool) u4 {
    const read: u4 = if (top) 0b0001 else 0b0100;
    const written: u4 = if (top) 0b0010 else 0b1000;
    return switch (activity) {
        .untouched => 0,
        .read => read,
        .written => written,
        .read_written => read | written,
    };
}

fn memoryMapGlyph(bits: u4) []const u8 {
    return switch (bits) {
        0x0 => "░",
        0x1 => "▘",
        0x2 => "▝",
        0x3 => "▀",
        0x4 => "▖",
        0x5 => "▌",
        0x6 => "▞",
        0x7 => "▛",
        0x8 => "▗",
        0x9 => "▚",
        0xa => "▐",
        0xb => "▜",
        0xc => "▄",
        0xd => "▙",
        0xe => "▟",
        0xf => "█",
    };
}

fn renderMemory(out: *Writer) void {
    if (memory_address_entry) {
        out.text("  ");
        out.styled(SGR_CONTROL_KEY, "x");
        out.text(" address ");
        renderHex32(out, memory_address_value);
        out.print(" ({d}/8)", .{memory_address_digits});
        if (inputMemoryPointer() != null) {
            out.text("  ");
            out.styled(SGR_CONTROL_KEY, "i");
            out.text(" input");
        }
        if (outputMemoryPointer() != null) {
            out.text("  ");
            out.styled(SGR_CONTROL_KEY, "o");
            out.text(" output");
        }
        if (machine.last_read_access.valid) {
            out.text("  ");
            out.styled(SGR_CONTROL_KEY, "r");
            out.text(" last-read");
        }
        if (machine.last_write_access.valid) {
            out.text("  ");
            out.styled(SGR_CONTROL_KEY, "w");
            out.text(" last-write");
        }
        out.text("\n  ");
        out.styled(SGR_CONTROL_KEY, "↑/↓");
        out.text(" page  ");
        out.styled(SGR_CONTROL_KEY, "0-9/a-f");
        out.text(" hex  ");
        out.styled(SGR_CONTROL_KEY, "Backspace");
        out.text(" edit  ");
        out.styled(SGR_CONTROL_KEY, "Enter");
        out.text(" accept  ");
        out.styled(SGR_CONTROL_KEY, "Esc");
        out.text(" cancel\n");
    }
    if (!memory_view_visible or machine.memory_size == 0) {
        out.text("  press ");
        out.styled(SGR_CONTROL_KEY, "X");
        out.text(", type a hexadecimal linear-memory address, then press ");
        out.styled(SGR_CONTROL_KEY, "Enter");
        out.text("\n");
        return;
    }

    const end = @min(machine.memory_size, memory_view_offset + memory_view_bytes);
    var row = memory_view_offset;
    const write_highlight = memoryWriteHighlight();
    const input_highlight = hostInputHighlight();
    const write_start: usize = write_highlight.address;
    const write_end = write_start + @as(usize, write_highlight.width);
    while (row < end) : (row += 16) {
        const row_end = @min(end, row + 16);
        out.text("  ");
        renderBareHex32(out, @intCast(row));
        out.text("  ");
        var column: usize = 0;
        var active_style: []const u8 = "";
        while (column < 16) : (column += 1) {
            const address = row + column;
            const style = memoryDisplayByteStyle(address, write_highlight, input_highlight, write_start, write_end);
            const access_style = std.mem.eql(u8, style, SGR_READ_ACCESS) or
                std.mem.eql(u8, style, SGR_WRITE_ACCESS) or
                std.mem.eql(u8, style, SGR_MEMORY_INPUT_ACCESS);
            if (access_style) {
                if (active_style.len != 0) out.raw(SGR_RESET);
                out.raw(style);
                if (address < row_end)
                    out.print("{x:0>2}", .{machine.memory[address]})
                else
                    out.text("  ");
                out.raw(SGR_RESET);
                out.text(" ");
                active_style = "";
                if (column == 7) out.text(" ");
                continue;
            }
            if (!std.mem.eql(u8, style, active_style)) {
                if (column != 0) out.raw(SGR_RESET);
                out.raw(style);
                active_style = style;
            }
            if (address < row_end)
                out.print("{x:0>2} ", .{machine.memory[address]})
            else
                out.text("   ");
            if (column == 7) out.text(" ");
        }
        out.raw(SGR_RESET);
        out.text(" |");
        column = 0;
        active_style = "";
        while (column < 16) : (column += 1) {
            const address = row + column;
            if (address >= row_end) {
                out.text(" ");
                continue;
            }
            const style = memoryDisplayByteStyle(address, write_highlight, input_highlight, write_start, write_end);
            if (!std.mem.eql(u8, style, active_style)) {
                if (column != 0) out.raw(SGR_RESET);
                out.raw(style);
                active_style = style;
            }
            const byte = machine.memory[address];
            out.print("{c}", .{if (byte >= 0x20 and byte <= 0x7e) byte else '.'});
        }
        out.raw(SGR_RESET);
        out.text("|\n");
    }
}

fn memoryByteStyle(address: usize, write_highlight: interpreter.MemoryEvent, write_start: usize, write_end: usize) []const u8 {
    if (write_highlight.valid and address >= write_start and address < write_end) return SGR_WRITE_TARGET;
    return memoryProvenanceStyle(machine.memoryByteProvenance(address));
}

fn memoryDisplayByteStyle(address: usize, write_highlight: interpreter.MemoryEvent, input_highlight: interpreter.MemoryEvent, write_start: usize, write_end: usize) []const u8 {
    if (machine.last_access.valid) {
        const access_start: usize = machine.last_access.address;
        const access_end = @min(machine.memory_size, access_start + @as(usize, machine.last_access.width));
        if (address >= access_start and address < access_end) {
            return if (machine.last_access_kind == .write) SGR_WRITE_ACCESS else SGR_READ_ACCESS;
        }
    }
    if (memoryEventContains(machine.last_read_access, address)) return SGR_READ_ACCESS;
    if (memoryEventContains(machine.last_write_access, address)) return SGR_WRITE_ACCESS;
    if (memoryEventContains(input_highlight, address)) return SGR_MEMORY_INPUT_ACCESS;
    return memoryByteStyle(address, write_highlight, write_start, write_end);
}

fn hostInputHighlight() interpreter.MemoryEvent {
    if (machine.counters.instructions != 0 or machine.target_input.len == 0) return .{};
    const address = (machine.inputPointer() catch return .{}) orelse return .{};
    return .{
        .valid = true,
        .address = address,
        .width = @intCast(machine.target_input.len),
    };
}

fn memoryEventContains(event: interpreter.MemoryEvent, address: usize) bool {
    if (!event.valid) return false;
    const start: usize = event.address;
    const end = @min(machine.memory_size, start + @as(usize, event.width));
    return address >= start and address < end;
}

fn memoryProvenanceStyle(provenance: interpreter.MemoryByteProvenance) []const u8 {
    return switch (provenance) {
        .untouched => SGR_DIM,
        .data => SGR_MEMORY_DATA,
        .input => SGR_MEMORY_INPUT,
        .written => SGR_MEMORY_WRITTEN,
    };
}

test "parses component and input multipart parts" {
    const body =
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"component\"; filename=\"counter.wasm\"\r\n" ++
        "Content-Type: application/wasm\r\n\r\n" ++
        "wasm bytes\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"input\"; filename=\"input.txt\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n" ++
        "one two\n\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    const parsed = try parseMultipart(body);
    try std.testing.expectEqualStrings("wasm bytes", parsed.component);
    try std.testing.expectEqualStrings("counter.wasm", parsed.component_path.?);
    try std.testing.expectEqualStrings("one two\n", parsed.target_input);
}

test "only displays safe relative component filenames" {
    try std.testing.expectEqualStrings("text/rgb-to-hex.wasm", safeComponentPath("text/rgb-to-hex.wasm").?);
    try std.testing.expect(safeComponentPath("../private/component.wasm") == null);
    try std.testing.expect(safeComponentPath("component\x1b[31m.wasm") == null);
    try std.testing.expect(safeComponentPath("/absolute/component.wasm") == null);
    try std.testing.expect(safeComponentPath("component.txt") == null);
}

test "requires a component multipart part" {
    const body =
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"input\"\r\n\r\n" ++
        "hello\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    try std.testing.expectError(error.MissingComponent, parseMultipart(body));
}

test "indents structured control bodies and aligns closing instructions" {
    try std.testing.expectEqual(@as(usize, 0), instructionIndent(.{ .op = 0x02, .function_index = 0, .byte_offset = 0, .depth = 0 }));
    try std.testing.expectEqual(@as(usize, 1), instructionIndent(.{ .op = 0x20, .function_index = 0, .byte_offset = 1, .depth = 1 }));
    try std.testing.expectEqual(@as(usize, 0), instructionIndent(.{ .op = 0x05, .function_index = 0, .byte_offset = 2, .depth = 1 }));
    try std.testing.expectEqual(@as(usize, 0), instructionIndent(.{ .op = 0x0b, .function_index = 0, .byte_offset = 3, .depth = 1 }));
}

test "keeps the instruction window full at function boundaries" {
    try std.testing.expectEqual(InstructionWindow{ .first = 0, .end = 11 }, instructionWindow(0, 0, 20, 11));
    try std.testing.expectEqual(InstructionWindow{ .first = 0, .end = 11 }, instructionWindow(1, 0, 20, 11));
    try std.testing.expectEqual(InstructionWindow{ .first = 0, .end = 11 }, instructionWindow(5, 0, 20, 11));
    try std.testing.expectEqual(InstructionWindow{ .first = 1, .end = 12 }, instructionWindow(6, 0, 20, 11));
    try std.testing.expectEqual(InstructionWindow{ .first = 9, .end = 20 }, instructionWindow(19, 0, 20, 11));
    try std.testing.expectEqual(InstructionWindow{ .first = 7, .end = 12 }, instructionWindow(7, 7, 12, 11));
    try std.testing.expectEqual(InstructionWindow{ .first = 151, .end = 650 }, instructionWindow(400, 0, 1000, 499));
}

test "uses a taller viewport for more instruction lines" {
    const previous_lines = viewport_lines;
    defer viewport_lines = previous_lines;

    viewport_lines = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(usize, 11), instructionWindowLines(11));
    viewport_lines = 24;
    try std.testing.expectEqual(@as(usize, 12), instructionWindowLines(11));
    viewport_lines = 512;
    try std.testing.expectEqual(@as(usize, 500), instructionWindowLines(11));
    viewport_lines = std.math.maxInt(u32) - 1;
    try std.testing.expectEqual(MAX_INSTRUCTION_WINDOW_LINES, instructionWindowLines(0));
}

test "measures styled lines without a fixed line-count limit" {
    try std.testing.expectEqual(@as(usize, 5), visibleTextWidth("\x1b[1mAé中\x1b[0mBC"));
}

test "identifies instructions that write linear memory" {
    const base = interpreter.Instruction{ .op = 0x01, .function_index = 0, .byte_offset = 0 };
    try std.testing.expect(isMemoryWriteInstruction(.{ .op = 0x36, .function_index = 0, .byte_offset = 0 }));
    try std.testing.expect(isMemoryWriteInstruction(.{ .op = 0xfc, .function_index = 0, .byte_offset = 0, .immediate = 10 }));
    try std.testing.expect(isMemoryWriteInstruction(.{ .op = 0xfc, .function_index = 0, .byte_offset = 0, .immediate = 11 }));
    try std.testing.expect(isMemoryWriteInstruction(.{ .op = 0xfd, .function_index = 0, .byte_offset = 0, .immediate = 11 }));
    try std.testing.expect(!isMemoryWriteInstruction(.{ .op = 0x21, .function_index = 0, .byte_offset = 0 }));
    try std.testing.expect(!isMemoryWriteInstruction(.{ .op = 0xfc, .function_index = 0, .byte_offset = 0, .immediate = 12 }));
    try std.testing.expect(!isMemoryWriteInstruction(base));
}

test "assigns opcode colors by instruction family" {
    try std.testing.expectEqualStrings(SGR_LOOP_CALL, instructionStyle(0x03));
    try std.testing.expectEqualStrings(SGR_LOOP_CALL, instructionStyle(0x10));
    try std.testing.expectEqualStrings(SGR_LOOP_CALL, instructionStyle(0x11));
    try std.testing.expectEqualStrings(SGR_CONTROL_FLOW, instructionStyle(0x1b));
    try std.testing.expectEqualStrings(SGR_READ, instructionStyle(0x20));
    try std.testing.expectEqualStrings(SGR_WRITE, instructionStyle(0x21));
    try std.testing.expectEqualStrings(SGR_WRITE, instructionStyle(0x22));
    try std.testing.expectEqualStrings(SGR_READ, instructionStyle(0x23));
    try std.testing.expectEqualStrings(SGR_WRITE, instructionStyle(0x24));
    try std.testing.expectEqualStrings(SGR_WRITE, instructionStyle(0x36));
    try std.testing.expectEqualStrings(SGR_WRITE, instructionStyle(0x3e));
    try std.testing.expectEqualStrings(SGR_WRITE, instructionStyle(0xfc));
    try std.testing.expectEqualStrings(SGR_INSTRUCTION, instructionStyle(0x41));
    try std.testing.expectEqualStrings(SGR_INSTRUCTION, instructionStyle(0x44));
    try std.testing.expectEqualStrings(SGR_INSTRUCTION, instructionStyle(0x1a));
}

test "formats scalar variables as signed decimal and little-endian ASCII" {
    defer variable_format = .hex;

    var decimal_buffer: [64]u8 = undefined;
    var decimal = Writer.init(&decimal_buffer);
    variable_format = .decimal;
    renderTypedValue(&decimal, .i32, std.math.maxInt(u32));
    try std.testing.expectEqualStrings("i32 \x1b[94m-1\x1b[0m", decimal.buffer[0..decimal.offset]);

    var ascii_buffer: [64]u8 = undefined;
    var ascii = Writer.init(&ascii_buffer);
    variable_format = .ascii;
    renderTypedValue(&ascii, .i64, 0x57202c6f6c6c6548);
    try std.testing.expectEqualStrings("i64 \x1b[94m|Hello, W|\x1b[0m", ascii.buffer[0..ascii.offset]);
}

test "previews numeric constants on the next stack" {
    const cases = [_]struct {
        op: u8,
        value: u64,
        value_type: interpreter.ValType,
    }{
        .{ .op = 0x41, .value = 90, .value_type = .i32 },
        .{ .op = 0x42, .value = 90, .value_type = .i64 },
        .{ .op = 0x43, .value = 0x3fc00000, .value_type = .f32 },
        .{ .op = 0x44, .value = 0x3ff8000000000000, .value_type = .f64 },
    };
    for (cases) |case| {
        const preview = currentStackPreview(.{
            .op = case.op,
            .function_index = 0,
            .byte_offset = 0,
            .immediate = case.value,
        }).?;
        try std.testing.expectEqual(case.value, preview.value);
        try std.testing.expectEqual(case.value_type, preview.value_type);
    }
}

test "formats Wasm memory in the largest exact binary unit" {
    var buffer: [32]u8 = undefined;
    var writer = Writer.init(&buffer);
    renderMemorySize(&writer, 256 * 1024);
    try std.testing.expectEqualStrings("256 KiB", buffer[0..writer.offset]);

    writer = Writer.init(&buffer);
    renderMemorySize(&writer, 8 * 1024 * 1024);
    try std.testing.expectEqualStrings("8 MiB", buffer[0..writer.offset]);

    writer = Writer.init(&buffer);
    renderMemorySize(&writer, 5 * 1024 * 1024 + 64 * 1024);
    try std.testing.expectEqualStrings("5184 KiB", buffer[0..writer.offset]);
}

test "maps two pages of read and write activity into Unicode quadrants" {
    try std.testing.expectEqual(@as(u4, 0b0001), memoryMapActivityBits(.read, true));
    try std.testing.expectEqual(@as(u4, 0b0010), memoryMapActivityBits(.written, true));
    try std.testing.expectEqual(@as(u4, 0b0100), memoryMapActivityBits(.read, false));
    try std.testing.expectEqual(@as(u4, 0b1000), memoryMapActivityBits(.written, false));
    try std.testing.expectEqualStrings("▚", memoryMapGlyph(0b1001));
    try std.testing.expectEqualStrings("▞", memoryMapGlyph(0b0110));
    try std.testing.expectEqualStrings("█", memoryMapGlyph(0b1111));
}

test "viewport uniforms clip complete bottom rows and visible columns" {
    const source = "\x1b[1mABCDE\x1b[0m\n12345\nlast";
    @memcpy(output_buf[0..source.len], source);
    try std.testing.expectEqual(@as(u32, 3), uniform_set_columns(3));
    try std.testing.expectEqual(@as(u32, 2), uniform_set_lines(2));
    const size = fitOutputToViewport(source.len);
    try std.testing.expectEqualStrings("\x1b[1mABC\x1b[0m\n123\x1b[0m", output_buf[0..size]);
    try std.testing.expectEqual(@as(u32, 1), uniform_set_columns(0));
    try std.testing.expectEqual(@as(u32, 1), uniform_set_lines(0));
    viewport_columns = std.math.maxInt(u32);
    viewport_lines = std.math.maxInt(u32);
}

test "steps a render function and counts a loop" {
    // A hand-encoded module equivalent to:
    // render(n): i=0; loop { i += 1; if i < 3 br loop }; return i as i64.
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7e,
        0x03, 0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01,
        0x01, 0x01, 0x07, 0x0a, 0x01, 0x06, 'r',  'e',
        'n',  'd',  'e',  'r',  0x00, 0x00, 0x0a, 0x1c,
        0x01, 0x1a, 0x01, 0x01, 0x7f, 0x41, 0x00, 0x21,
        0x01, 0x03, 0x40, 0x20, 0x01, 0x41, 0x01, 0x6a,
        0x22, 0x01, 0x41, 0x03, 0x49, 0x0d, 0x00, 0x0b,
        0x20, 0x01, 0xad, 0x0b,
    };
    try machine.load(&wasm);
    var loop_branch: ?u32 = null;
    for (machine.instructions[0..machine.instruction_count], 0..) |instruction, index| {
        if (instruction.op == 0x0d) loop_branch = @intCast(index);
    }
    try std.testing.expect(loop_branch != null);
    try std.testing.expect(branchTargetsLoop(loop_branch.?));
    try std.testing.expectEqualStrings(SGR_LOOP_CALL, instructionStyleAt(loop_branch.?));
    const signature = machine.functionSignature(0).?;
    try std.testing.expectEqualSlices(interpreter.ValType, &.{.i32}, signature.parameters);
    try std.testing.expectEqual(interpreter.ValType.i64, signature.result.?);
    try std.testing.expectEqualSlices(interpreter.Value, &.{0}, machine.frameParameters(0));
    try std.testing.expectEqualSlices(interpreter.Value, &.{0}, machine.frameDefinedLocals(0));
    const initial_screen = output_buf[0..renderText()];
    try std.testing.expect(std.mem.indexOf(u8, initial_screen, "loop iterations=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial_screen, "[LOOP]") == null);
    try std.testing.expect(std.mem.indexOf(u8, initial_screen, "loop   iterations=") == null);
    for (0..7) |_| _ = machine.step();
    try std.testing.expectEqualSlices(interpreter.Value, &.{1}, machine.frameDefinedLocals(0));
    _ = machine.step();
    const comparison = currentStackPreview(machine.instructions[machine.current_instruction]).?;
    try std.testing.expectEqual(interpreter.ValType.i32, comparison.value_type);
    try std.testing.expectEqual(@as(interpreter.Value, 1), comparison.value);
    const comparison_screen = output_buf[0..renderText()];
    try std.testing.expect(std.mem.indexOf(u8, comparison_screen, "i32.lt_u") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_screen, "i32 \x1b[94m0x00000001\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_screen, "┌─  \x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_screen, "├─  \x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_screen, "├─  \x1b[0m\x1b[93mi32.lt_u") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_screen, "└─▶ \x1b[0mnext stack[0]") != null);
    machine.continueFor(100);
    try std.testing.expectEqual(interpreter.Status.halted, machine.status);
    try std.testing.expectEqual(@as(u64, 3), machine.result);
    try std.testing.expectEqual(@as(u64, 2), machine.counters.loop_iterations);
}

test "retains the most recent memory access" {
    // render(n): memory[16] = 0x44; discard memory[16]; return 0.
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7e,
        0x03, 0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01,
        0x01, 0x01, 0x07, 0x0a, 0x01, 0x06, 'r',  'e',
        'n',  'd',  'e',  'r',  0x00, 0x00, 0x0a, 0x14,
        0x01, 0x12, 0x00, 0x41, 0x10, 0x41, 0xc4, 0x00,
        0x3a, 0x00, 0x00, 0x41, 0x10, 0x2d, 0x00, 0x00,
        0x1a, 0x42, 0x00, 0x0b, 0x0b, 0x07, 0x01, 0x00,
        0x41, 0x10, 0x0b, 0x01, 0x00,
    };
    try machine.load(&wasm);
    machine.stack[0] = 16;
    machine.stack_types[0] = .i32;
    machine.stack_count = 1;
    var load_name_buffer: [64]u8 = undefined;
    var load_name = Writer.init(&load_name_buffer);
    renderOpcodeName(&load_name, .{ .op = 0x2d, .function_index = 0, .byte_offset = 0 }, instructionStyle(0x2d));
    try std.testing.expectEqualStrings("\x1b[93mi32\x1b[95m.load8_u\x1b[0m", load_name.buffer[0..load_name.offset]);
    try machine.restart();
    memory_view_visible = true;
    memory_view_offset = 0;
    const initial_memory = output_buf[0..renderText()];
    try std.testing.expectEqual(interpreter.MemoryByteProvenance.data, machine.memoryByteProvenance(16));
    try std.testing.expect(std.mem.indexOf(u8, initial_memory, "\x1b[33m00 ") != null);
    _ = machine.step();
    _ = machine.step();
    const before_store = output_buf[0..renderText()];
    try std.testing.expect(std.mem.indexOf(u8, before_store, "\x1b[93mi32\x1b[92m.store8\x1b[0m\x1b[4m 0\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, before_store, "\x1b[1;92m00 \x1b[0m") != null);
    _ = machine.step();
    const after_store = output_buf[0..renderText()];
    try std.testing.expect(std.mem.indexOf(u8, after_store, "\x1b[1;4;92m44\x1b[0m ") != null);
    machine.continueFor(100);
    try std.testing.expectEqual(interpreter.Status.halted, machine.status);
    try std.testing.expectEqual(interpreter.MemoryAccessKind.read, machine.last_access_kind);
    try std.testing.expectEqual(@as(u32, 16), machine.last_access.address);
    try std.testing.expectEqual(@as(u32, 1), machine.last_access.width);
    try std.testing.expectEqual(@as(u32, 16), machine.last_read_access.address);
    try std.testing.expectEqual(@as(u32, 16), machine.last_write_access.address);

    const screen = output_buf[0..renderText()];
    try std.testing.expect(std.mem.indexOf(u8, screen, "last read \x1b[0m\x1b[94m0x00000010") == null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "\x1b[4;95m44\x1b[0m ") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "\x1b[4;95mD\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "^^") == null);
}
