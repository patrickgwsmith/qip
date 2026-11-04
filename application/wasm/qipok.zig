//! Checks a QIP Content component against Compliance oracles, like `qipok`,
//! inside the bounded Zig Wasm interpreter.
//!
//! Input is `multipart/form-data`. The required `component` part contains the
//! implementation, and one or more `suite` parts contain Compliance oracles.
//! The oracle and the implementation run on two interpreter machines. When the
//! oracle calls a `qip.*` bridge import, its machine pauses, the implementation
//! renders the case on its own machine, and the oracle resumes with the result.
//!
//! Output is a plain-text report in the `qipok` format: one PASS or FAIL line
//! for the implementation's Content contract and for each suite, then a
//! `pass=… fail=… total=…` summary. A malformed request is a Content rejection.

const std = @import("std");
const interpreter = @import("wasm_interpreter");
const request = @import("content_interpreter_request");

/// Oracles in this repo declare at most 31 pages (about 2 MiB).
const ORACLE_MEMORY_BYTES: usize = 16 * 1024 * 1024;
/// The rest of the 256 MiB component memory goes to the implementation.
const IMPLEMENTATION_MEMORY_BYTES: usize = 176 * 1024 * 1024;
const MAX_SUITES: usize = 32;
const INPUT_CAP: usize = 2 * interpreter.MAX_MODULE_BYTES + 64 * 1024;
const OUTPUT_CAP: usize = 256 * 1024;
const DEFAULT_INSTRUCTION_BUDGET: u32 = 100_000_000;
const MAX_FAILURE_NOTES: usize = 5;
const PREVIEW_BYTES: usize = 256;
const OUTPUT_CONTENT_TYPE = "text/plain";

const OracleMachine = interpreter.MachineWithMemory(ORACLE_MEMORY_BYTES);
const ImplementationMachine = interpreter.MachineWithMemory(IMPLEMENTATION_MEMORY_BYTES);

var input_content_type = request.default_content_type;
var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var oracle: OracleMachine = undefined;
var implementation: ImplementationMachine = undefined;

var instruction_budget: u32 = DEFAULT_INSTRUCTION_BUDGET;
var seed: u32 = 0;
var seed_requested = false;

const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
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

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

/// Seed passed to each oracle's `uniform_set_seed`. A suite without that
/// export fails when a seed is set, as with `qipok --seed`.
export fn uniform_set_seed(value: u32) u32 {
    seed = value;
    seed_requested = true;
    return value;
}

/// Most instructions for one implementation render, one uniform setter, or
/// the oracle's work between two bridge calls. Exceeding it traps that call.
export fn uniform_set_instruction_budget(value: u32) u32 {
    instruction_budget = @max(value, 1);
    return instruction_budget;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    defer {
        instruction_budget = DEFAULT_INSTRUCTION_BUDGET;
        seed_requested = false;
        seed = 0;
    }
    const parsed = parseRequest(input_buf[0..input_size]) catch return .{ .output_size = 0, .output_ptr = 0, .failed = 1 };
    var report = Report{};
    check(parsed, &report);
    const bytes = report.finish();
    return .{ .output_size = @intCast(bytes.len), .output_ptr = @intCast(@intFromPtr(bytes.ptr)), .failed = 0 };
}

// ---------------------------------------------------------------------------
// Request

const Module = struct {
    bytes: []const u8,
    label: []const u8,
};

const Request = struct {
    component: Module,
    suites: [MAX_SUITES]Module = undefined,
    suite_count: usize = 0,
};

fn parseRequest(input: []const u8) !Request {
    var parts = try request.PartIterator.init(input, &input_content_type);
    var component: ?Module = null;
    var result: Request = .{ .component = undefined };
    while (try parts.next()) |part| {
        if (std.mem.eql(u8, part.name, "component")) {
            if (component != null) return error.DuplicatePart;
            component = .{ .bytes = part.body, .label = part.filename orelse "component" };
        } else if (std.mem.eql(u8, part.name, "suite")) {
            if (result.suite_count == MAX_SUITES) return error.TooManySuites;
            result.suites[result.suite_count] = .{ .bytes = part.body, .label = part.filename orelse "suite" };
            result.suite_count += 1;
        } else {
            return error.UnknownPart;
        }
    }
    result.component = component orelse return error.MissingComponent;
    return result;
}

// ---------------------------------------------------------------------------
// Report

const Report = struct {
    len: usize = 0,
    truncated: bool = false,
    pass: u32 = 0,
    fail: u32 = 0,
    seed_used: bool = false,

    fn write(self: *Report, bytes: []const u8) void {
        const reserve = 128; // Room for the truncation note and summary.
        const room = (OUTPUT_CAP - reserve) -| self.len;
        if (bytes.len > room) self.truncated = true;
        const count = @min(bytes.len, room);
        @memcpy(output_buf[self.len..][0..count], bytes[0..count]);
        self.len += count;
    }

    fn print(self: *Report, comptime format: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, format, args) catch blk: {
            self.truncated = true;
            break :blk buf[0..];
        };
        self.write(text);
    }

    /// Writes untrusted text with control characters replaced, like qipok's
    /// displayText.
    fn display(self: *Report, text: []const u8) void {
        var buf: [256]u8 = undefined;
        var index: usize = 0;
        while (index < text.len) {
            const end = @min(text.len, index + buf.len);
            for (text[index..end], 0..) |byte, i| buf[i] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
            self.write(buf[0 .. end - index]);
            index = end;
        }
    }

    fn finish(self: *Report) []const u8 {
        if (self.truncated) {
            const note = "… report truncated\n";
            @memcpy(output_buf[self.len..][0..note.len], note);
            self.len += note.len;
        }
        var buf: [96]u8 = undefined;
        const summary = if (self.seed_used)
            std.fmt.bufPrint(&buf, "\npass={d} fail={d} total={d} seed={d}\n", .{ self.pass, self.fail, self.pass + self.fail, seed }) catch unreachable
        else
            std.fmt.bufPrint(&buf, "\npass={d} fail={d} total={d}\n", .{ self.pass, self.fail, self.pass + self.fail }) catch unreachable;
        @memcpy(output_buf[self.len..][0..summary.len], summary);
        self.len += summary.len;
        return output_buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Checking

const Contract = struct {
    input_pointer: u32,
    input_capacity: u32,
    has_failure: bool,
};

var contract: Contract = undefined;

fn check(parsed: Request, report: *Report) void {
    contract = loadImplementation(parsed.component.bytes) catch |err| {
        report.write("FAIL ");
        report.display(parsed.component.label);
        report.print(": {s}\n", .{implementationErrorText(err)});
        report.fail += 1;
        return;
    };
    report.write("PASS ");
    report.display(parsed.component.label);
    report.write("\n");
    report.pass += 1;

    for (parsed.suites[0..parsed.suite_count]) |suite| {
        var run = SuiteRun{};
        const outcome = run.execute(suite.bytes);
        if (run.seed_used) report.seed_used = true;
        report.write(if (outcome == null) "PASS " else "FAIL ");
        report.display(parsed.component.label);
        report.write(" --suite ");
        report.display(suite.label);
        if (outcome) |message| {
            report.write(": ");
            report.display(message);
            report.write("\n");
            report.write(run.notes[0..run.notes_len]);
            report.fail += 1;
        } else {
            report.print(" ({d} cases)\n", .{run.next});
            report.pass += 1;
        }
    }
}

const LoadError = interpreter.Error || error{MissingInputPointer};

fn loadImplementation(bytes: []const u8) LoadError!Contract {
    try implementation.loadWithOptions(bytes, &.{}, .{});
    const content = try implementation.contentContract();
    return .{
        .input_pointer = content.input_pointer orelse return error.MissingInputPointer,
        .input_capacity = content.input_capacity.?,
        .has_failure = implementation.hasFunctionExport("failure_modes_per_input_offset"),
    };
}

fn implementationErrorText(err: LoadError) []const u8 {
    return switch (err) {
        error.MissingInputPointer => "implementation input_ptr unavailable",
        error.MissingRender => "missing render(i32) -> i64 export",
        error.InvalidRenderSignature => "render must be (i32) -> i64",
        error.MissingMemoryExport => "missing memory export",
        error.MissingOutputCapacity => "missing output_utf8_cap or output_bytes_cap export",
        error.MemoryTooLarge => "declared memory is larger than the interpreter holds",
        error.UnsupportedFeature => "uses a Wasm feature that the interpreter does not support",
        else => @errorName(err),
    };
}

const Rendered = union(enum) {
    output: []const u8,
    rejected: u32,
    trapped: []const u8,
    failed: []const u8,
};

fn renderImplementation(input: []const u8) Rendered {
    if (input.len > contract.input_capacity) return .{ .failed = "input length exceeds implementation input cap" };
    implementation.hostWrite(contract.input_pointer, input) catch return .{ .failed = "implementation input buffer out of range" };
    implementation.beginExport("render", &.{@as(interpreter.Value, input.len)}) catch |err| return .{ .failed = @errorName(err) };
    implementation.continueFor(instruction_budget);
    switch (implementation.status) {
        .halted => {
            const output = implementation.contentOutput() catch return .{ .failed = "implementation output out of range" };
            return switch (output.?) {
                .accepted => |bytes| .{ .output = bytes },
                .rejected => |detail| if (contract.has_failure)
                    .{ .rejected = detail }
                else
                    .{ .failed = "implementation returned failure without failure_modes_per_input_offset" },
            };
        },
        .trapped, .ready => {
            const reason = if (implementation.status == .ready) "instruction budget exceeded" else interpreter.trapName(implementation.trap);
            // A trapped instance cannot continue, so start from fresh memory
            // and globals, as the bridge reinstantiates the implementation.
            implementation.restart() catch return .{ .failed = "could not restart implementation after trap" };
            return .{ .trapped = reason };
        },
        .awaiting_host, .empty => return .{ .failed = "implementation did not run" },
    }
}

const bridge_imports = [_][]const u8{
    "must_render_exactly",
    "must_trap",
    "must_reject",
    "must_render_into",
    "must_render_into_emit_error",
    "must_render_into_finish",
    "set_uniform_u32",
};

const SuiteRun = struct {
    next: u64 = 0,
    open_render_into: ?u64 = null,
    open_render_into_failed: bool = false,
    open_render_into_errors: u32 = 0,
    fail_count: u64 = 0,
    note_count: usize = 0,
    notes: [8 * 1024]u8 = undefined,
    notes_len: usize = 0,
    seed_used: bool = false,
    protocol_error: ?[]const u8 = null,
    message_buf: [256]u8 = undefined,
    violation_buf: [256]u8 = undefined,

    fn message(self: *SuiteRun, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&self.message_buf, format, args) catch "message too long";
    }

    fn violation(self: *SuiteRun, comptime format: []const u8, args: anytype) void {
        if (self.protocol_error != null) return;
        self.protocol_error = std.fmt.bufPrint(&self.violation_buf, format, args) catch "message too long";
    }

    fn note(self: *SuiteRun, comptime format: []const u8, args: anytype) void {
        const room = self.notes[self.notes_len..];
        const text = std.fmt.bufPrint(room, format, args) catch return;
        self.notes_len += text.len;
    }

    fn noteBytes(self: *SuiteRun, label: []const u8, bytes: []const u8) void {
        const preview = bytes[0..@min(bytes.len, PREVIEW_BYTES)];
        self.note("    {s}_utf8_preview=", .{label});
        for (preview) |byte| {
            if (byte >= 0x20 and byte <= 0x7e) self.note("{c}", .{byte}) else self.note("\\x{x:0>2}", .{byte});
        }
        self.note("\n    {s}_hex_preview=", .{label});
        for (preview, 0..) |byte, i| self.note("{s}{x:0>2}", .{ if (i == 0) "" else " ", byte });
        self.note("\n", .{});
    }

    fn recordFailure(self: *SuiteRun, ordinal: u64, kind: []const u8, input: ?[]const u8, expected: ?[]const u8, actual: ?[]const u8) void {
        self.fail_count += 1;
        self.recordNote(ordinal, kind, input, expected, actual);
    }

    fn recordNote(self: *SuiteRun, ordinal: u64, kind: []const u8, input: ?[]const u8, expected: ?[]const u8, actual: ?[]const u8) void {
        if (self.note_count == MAX_FAILURE_NOTES) return;
        self.note_count += 1;
        self.note("  case {d}: {s}\n", .{ ordinal, kind });
        if (input) |bytes| self.noteBytes("input", bytes);
        if (expected) |bytes| self.noteBytes("expected_output", bytes);
        if (actual) |bytes| self.noteBytes("actual_output", bytes);
    }

    /// Runs one oracle against a fresh implementation. Returns null when every
    /// case passes, or the failure message.
    fn execute(self: *SuiteRun, wasm: []const u8) ?[]const u8 {
        implementation.restart() catch return "implementation could not be restarted";
        oracle.loadWithOptions(wasm, &.{}, .{ .function_imports = true, .render = false }) catch |err| {
            return self.message("Compliance oracle could not be loaded: {s}", .{@errorName(err)});
        };
        for (0..oracle.import_count) |index| {
            const name = oracle.importName(@intCast(index)).?;
            const known = for (bridge_imports) |bridge| {
                if (std.mem.eql(u8, name.name, bridge)) break true;
            } else false;
            if (!std.mem.eql(u8, name.module, "qip") or !known) {
                return self.message("Compliance oracle import {s}.{s} is not part of the qip bridge", .{ name.module, name.name });
            }
        }

        if (seed_requested) {
            const setter = request.uniformSetterName(&oracle, "seed") orelse
                return "seed given but Compliance oracle does not export uniform_set_seed";
            self.seed_used = true;
            // Oracle seed setters take a u32 and may or may not return it.
            oracle.beginExport(setter, &.{seed}) catch |err| {
                return self.message("{s} failed: {s}", .{ setter, @errorName(err) });
            };
            oracle.continueFor(instruction_budget);
            if (oracle.status != .halted) return self.message("{s} did not finish", .{setter});
        }

        const comply_index = oracle.functionExportIndex("comply") orelse return "Compliance oracle must export comply() -> i32";
        const signature = oracle.functionSignature(comply_index) orelse return "Compliance oracle must export comply() -> i32";
        if (signature.parameters.len != 0 or signature.result != .i32) return "comply must be () -> i32";
        oracle.beginExport("comply", &.{}) catch |err| return self.message("comply() could not start: {s}", .{@errorName(err)});

        while (true) {
            oracle.continueFor(instruction_budget);
            switch (oracle.status) {
                .awaiting_host => {
                    const result = self.handleBridgeCall();
                    if (self.protocol_error) |text| return self.message("bridge protocol violation: {s}", .{text});
                    oracle.resumeHostCall(@as(interpreter.Value, @as(u32, @bitCast(result)))) catch |err| {
                        return self.message("oracle could not resume: {s}", .{@errorName(err)});
                    };
                },
                .halted => break,
                .trapped => return self.message("comply() trapped: {s}", .{interpreter.trapName(oracle.trap)}),
                .ready => return "comply() exceeded the instruction budget between bridge calls",
                .empty => return "comply() did not run",
            }
        }

        if (self.open_render_into) |ordinal| return self.message("comply() returned with must_render_into case {d} still open", .{ordinal});
        const declared: i32 = @bitCast(@as(u32, @truncate(oracle.result)));
        if (declared <= 0) return self.message("comply() declared no cases (returned {d})", .{declared});
        if (@as(u64, @intCast(declared)) != self.next & 0x7fff_ffff) {
            return self.message("comply() returned {d} cases but host counted {d}", .{ declared, self.next });
        }
        if (self.fail_count > 0) {
            if (self.fail_count > self.note_count) {
                self.note("  … and {d} more failing case(s); reproduce via (component, seed, ordinal)\n", .{self.fail_count - self.note_count});
            }
            return self.message("{d}/{d} cases failed", .{ self.fail_count, self.next });
        }
        return null;
    }

    fn arg(index: usize) u64 {
        const args = oracle.host_call.args();
        return if (index < args.len) @truncate(args[index]) else 0;
    }

    fn arg32(index: usize) u32 {
        return @truncate(arg(index));
    }

    fn caseOpen(self: *SuiteRun, ordinal: u64, kind: []const u8) bool {
        if (self.open_render_into) |open| {
            self.violation("{s} at ordinal {d} inside open must_render_into case {d}", .{ kind, ordinal, open });
            return false;
        }
        if (ordinal != self.next) {
            self.violation("{s} declared ordinal {d}, host expected {d}", .{ kind, ordinal, self.next });
            return false;
        }
        return true;
    }

    fn handleBridgeCall(self: *SuiteRun) i32 {
        const name = oracle.importName(oracle.host_call.function_index).?.name;
        if (std.mem.eql(u8, name, "must_render_exactly")) return self.mustRenderExactly();
        if (std.mem.eql(u8, name, "must_trap")) return self.mustTrap();
        if (std.mem.eql(u8, name, "must_reject")) return self.mustReject();
        if (std.mem.eql(u8, name, "must_render_into")) return self.mustRenderInto();
        if (std.mem.eql(u8, name, "must_render_into_emit_error")) return self.mustRenderIntoEmitError();
        if (std.mem.eql(u8, name, "must_render_into_finish")) return self.mustRenderIntoFinish();
        if (std.mem.eql(u8, name, "set_uniform_u32")) return self.setUniformU32();
        self.violation("unknown bridge import {s}", .{name});
        return 0;
    }

    fn mustRenderExactly(self: *SuiteRun) i32 {
        const ordinal = arg(0);
        if (!self.caseOpen(ordinal, "must_render_exactly")) return 0;
        self.next += 1;
        const input = oracle.hostRead(arg32(1), arg32(2));
        const expected = oracle.hostRead(arg32(3), arg32(4));
        if (input == null or expected == null) {
            self.violation("must_render_exactly pointers out of range at ordinal {d}", .{ordinal});
            return 0;
        }
        switch (renderImplementation(input.?)) {
            .output => |actual| {
                if (std.mem.eql(u8, actual, expected.?)) return 1;
                self.recordFailure(ordinal, "output mismatch", input, expected, actual);
            },
            .rejected => |detail| self.recordFailure(ordinal, self.message("unexpected rejection (failure detail {d})", .{detail}), input, expected, null),
            .trapped => |reason| self.recordFailure(ordinal, self.message("trapped: {s}", .{reason}), input, expected, null),
            .failed => |reason| self.recordFailure(ordinal, self.message("could not render: {s}", .{reason}), input, expected, null),
        }
        return 0;
    }

    fn mustTrap(self: *SuiteRun) i32 {
        const ordinal = arg(0);
        if (!self.caseOpen(ordinal, "must_trap")) return 0;
        self.next += 1;
        const input = oracle.hostRead(arg32(1), arg32(2)) orelse {
            self.violation("must_trap pointer out of range at ordinal {d}", .{ordinal});
            return 0;
        };
        switch (renderImplementation(input)) {
            .trapped => return 1,
            .output => |actual| self.recordFailure(ordinal, "expected trap, got output", input, null, actual),
            .rejected => |detail| self.recordFailure(ordinal, self.message("expected trap, got rejection (failure detail {d})", .{detail}), input, null, null),
            .failed => |reason| self.recordFailure(ordinal, self.message("expected trap, could not render: {s}", .{reason}), input, null, null),
        }
        return 0;
    }

    fn mustReject(self: *SuiteRun) i32 {
        const ordinal = arg(0);
        if (!self.caseOpen(ordinal, "must_reject")) return 0;
        self.next += 1;
        const input = oracle.hostRead(arg32(1), arg32(2)) orelse {
            self.violation("must_reject pointer out of range at ordinal {d}", .{ordinal});
            return 0;
        };
        if (!contract.has_failure) {
            self.recordFailure(ordinal, "expected rejection, but implementation does not export failure_modes_per_input_offset", input, null, null);
            return 0;
        }
        switch (renderImplementation(input)) {
            .rejected => return 1,
            .output => |actual| self.recordFailure(ordinal, "expected rejection, render was accepted", input, null, actual),
            .trapped => |reason| self.recordFailure(ordinal, self.message("expected rejection, render trapped: {s}", .{reason}), input, null, null),
            .failed => |reason| self.recordFailure(ordinal, self.message("expected rejection, could not render: {s}", .{reason}), input, null, null),
        }
        return 0;
    }

    fn mustRenderInto(self: *SuiteRun) i32 {
        const ordinal = arg(0);
        if (self.open_render_into) |open| {
            self.violation("must_render_into opened ordinal {d} while ordinal {d} is still open", .{ ordinal, open });
            return -1;
        }
        if (ordinal != self.next) {
            self.violation("must_render_into opened ordinal {d}, host expected {d}", .{ ordinal, self.next });
            return -1;
        }
        self.open_render_into = ordinal;
        self.open_render_into_failed = true;
        self.open_render_into_errors = 0;
        const input = oracle.hostRead(arg32(1), arg32(2)) orelse {
            self.violation("must_render_into pointer out of range at ordinal {d}", .{ordinal});
            return -1;
        };
        const output = switch (renderImplementation(input)) {
            .output => |bytes| bytes,
            else => return -1,
        };
        if (output.len > arg32(4)) return -2;
        oracle.hostWrite(arg32(3), output) catch {
            self.violation("must_render_into out pointer out of range at ordinal {d}", .{ordinal});
            return -1;
        };
        self.open_render_into_failed = false;
        return @intCast(output.len);
    }

    fn mustRenderIntoEmitError(self: *SuiteRun) i32 {
        const ordinal = arg(0);
        if (self.open_render_into != ordinal) {
            self.violation("must_render_into_emit_error ordinal {d} does not match open must_render_into case", .{ordinal});
            return 0;
        }
        const text = oracle.hostRead(arg32(1), arg32(2)) orelse {
            self.violation("must_render_into_emit_error message pointer out of range at ordinal {d}", .{ordinal});
            return 0;
        };
        self.open_render_into_errors += 1;
        if (self.note_count < MAX_FAILURE_NOTES) {
            self.note_count += 1;
            self.note("  case {d}: render_into error: ", .{ordinal});
            for (text) |byte| self.note("{c}", .{if (byte < 0x20 or byte == 0x7f) '?' else byte});
            self.note("\n", .{});
        }
        return 1;
    }

    fn mustRenderIntoFinish(self: *SuiteRun) i32 {
        const ordinal = arg(0);
        const error_count = arg32(1);
        if (self.open_render_into != ordinal) {
            self.violation("must_render_into_finish ordinal {d} does not match open must_render_into case", .{ordinal});
            return 0;
        }
        if (error_count != self.open_render_into_errors) {
            self.violation("must_render_into_finish ordinal {d} reported {d} errors, host observed {d}", .{ ordinal, error_count, self.open_render_into_errors });
            return 0;
        }
        if (self.open_render_into_failed and error_count == 0) {
            self.violation("must_render_into_finish ordinal {d} reported 0 errors after render failure", .{ordinal});
            return 0;
        }
        if (error_count > 0) self.fail_count += 1;
        self.open_render_into = null;
        self.open_render_into_failed = false;
        self.open_render_into_errors = 0;
        self.next += 1;
        return 1;
    }

    fn setUniformU32(self: *SuiteRun) i32 {
        if (self.open_render_into) |open| {
            self.violation("set_uniform_u32 called inside open must_render_into case {d}", .{open});
            return 0;
        }
        const name_len = arg32(1);
        if (name_len == 0 or name_len > 128) {
            self.violation("set_uniform_u32 name length {d} is outside 1..128", .{name_len});
            return 0;
        }
        const name = oracle.hostRead(arg32(0), name_len) orelse {
            self.violation("set_uniform_u32 name pointer out of range", .{});
            return 0;
        };
        if (!request.validUniformKey(name)) {
            self.violation("set_uniform_u32 name is not a valid uniform key", .{});
            return 0;
        }
        const setter = request.uniformSetterName(&implementation, name) orelse {
            self.violation("implementation does not export uniform_set_{s}", .{name});
            return 0;
        };
        const applied = implementation.invokeScalarSetter(setter, arg32(2), .i32, instruction_budget) catch |err| {
            self.violation("{s} failed: {s}", .{ setter, @errorName(err) });
            return 0;
        };
        return @bitCast(@as(u32, @truncate(applied)));
    }
};

test "parses component and repeated suite parts" {
    const boundary = "--uuid-00000000-0000-0000-0000-000000000000";
    const body = boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"component\"; filename=\"impl.wasm\"\r\n\r\n" ++
        "impl\r\n" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"suite\"; filename=\"a.comply.wasm\"\r\n\r\n" ++
        "a\r\n" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"suite\"\r\n\r\n" ++
        "b\r\n" ++ boundary ++ "--\r\n";
    const parsed = try parseRequest(body);
    try std.testing.expectEqualStrings("impl", parsed.component.bytes);
    try std.testing.expectEqualStrings("impl.wasm", parsed.component.label);
    try std.testing.expectEqual(@as(usize, 2), parsed.suite_count);
    try std.testing.expectEqualStrings("a.comply.wasm", parsed.suites[0].label);
    try std.testing.expectEqualStrings("suite", parsed.suites[1].label);
    try std.testing.expectEqualStrings("b", parsed.suites[1].bytes);
}
