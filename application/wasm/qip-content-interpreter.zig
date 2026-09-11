//! Runs one QIP Content component with the bounded Zig Wasm interpreter.
//!
//! Input is `multipart/form-data`: the required `component` part contains the
//! target `application/wasm` bytes and the optional `input` part contains its
//! exact Content input. Optional `uniforms[key]` parts configure the target.
//! Successful output is the target's raw output bytes.
//! The wrapper declares `application/octet-stream` because QIP content-type
//! metadata is static while the nested component's type is known only at run
//! time.

const std = @import("std");
const interpreter = @import("wasm_interpreter");

const MULTIPART_OVERHEAD_CAP: usize = 32 * 1024;
const MAX_TARGET_INPUT_BYTES: usize = 8 * 1024 * 1024;
const INPUT_CAP: usize = interpreter.MAX_MODULE_BYTES + MAX_TARGET_INPUT_BYTES + MULTIPART_OVERHEAD_CAP;
const OUTPUT_CAP: usize = interpreter.MAX_TARGET_MEMORY_BYTES;
const DEFAULT_INSTRUCTION_BUDGET: u32 = 1_000_000;
const MAX_INSTRUCTION_BUDGET: u32 = 10_000_000;
const MAX_TARGET_UNIFORMS: usize = 64;
const TYPE_PREFIX = "multipart/form-data;boundary=uuid-";
const DEFAULT_UUID = "00000000-0000-0000-0000-000000000000";
const OUTPUT_CONTENT_TYPE = "application/octet-stream";
const UNIFORM_FIELD_PREFIX = "uniforms[";

var input_content_type = (TYPE_PREFIX ++ DEFAULT_UUID).*;
var input_buf: [INPUT_CAP]u8 = undefined;
var machine: interpreter.Machine = undefined;
var instruction_budget: u32 = DEFAULT_INSTRUCTION_BUDGET;

const MultipartError = error{
    InvalidBoundary,
    InvalidMultipart,
    InvalidHeader,
    MissingComponent,
    DuplicatePart,
    UnknownPart,
    TooManyUniforms,
    InvalidUniformKey,
    InvalidUniformValue,
};

const FormUniform = struct {
    key: []const u8,
    value: []const u8,
};

const RunInput = struct {
    component: []const u8,
    target_input: []const u8 = &.{},
    uniforms: [MAX_TARGET_UNIFORMS]FormUniform = undefined,
    uniform_count: usize = 0,
};

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

export fn output_bytes_cap() u32 {
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

export fn uniform_set_instruction_budget(value: u32) u32 {
    instruction_budget = std.math.clamp(value, 1, MAX_INSTRUCTION_BUDGET);
    return instruction_budget;
}

fn rejected() RenderResult {
    return .{ .output_size = 0, .output_ptr = 0, .failed = 1 };
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    defer instruction_budget = DEFAULT_INSTRUCTION_BUDGET;

    const request = parseMultipart(input_buf[0..input_size]) catch return rejected();
    machine.loadWithInput(request.component, request.target_input) catch return rejected();
    _ = machine.contentContract() catch return rejected();
    var remaining_budget: usize = instruction_budget;
    for (request.uniforms[0..request.uniform_count]) |uniform| {
        applyTargetUniform(uniform, remaining_budget) catch return rejected();
        if (machine.counters.instructions > remaining_budget) return rejected();
        remaining_budget -= @intCast(machine.counters.instructions);
    }
    if (remaining_budget == 0) return rejected();
    machine.beginRender() catch return rejected();
    machine.continueFor(remaining_budget);
    const maybe_output = machine.contentOutput() catch return rejected();
    const output = maybe_output orelse return rejected();
    return switch (output) {
        .accepted => |bytes| .{
            .output_size = @intCast(bytes.len),
            .output_ptr = @intCast(@intFromPtr(bytes.ptr)),
            .failed = 0,
        },
        .rejected => rejected(),
    };
}

fn validUniformKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 63 or key[0] < 'a' or key[0] > 'z' or key[key.len - 1] == '_') return false;
    var previous_underscore = false;
    for (key) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_';
        if (!valid or (byte == '_' and previous_underscore)) return false;
        previous_underscore = byte == '_';
    }
    return true;
}

fn parseInteger(comptime T: type, raw: []const u8) MultipartError!T {
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        const U = std.meta.Int(.unsigned, @bitSizeOf(T));
        const bits = std.fmt.parseUnsigned(U, raw[2..], 16) catch return error.InvalidUniformValue;
        return @bitCast(bits);
    }
    return std.fmt.parseInt(T, raw, 10) catch return error.InvalidUniformValue;
}

fn uniformValue(raw: []const u8, value_type: interpreter.ValType) MultipartError!interpreter.Value {
    return switch (value_type) {
        .i32 => std.fmt.parseUnsigned(u32, raw, 10) catch blk: {
            if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
                break :blk std.fmt.parseUnsigned(u32, raw[2..], 16) catch return error.InvalidUniformValue;
            }
            return error.InvalidUniformValue;
        },
        .i64 => @as(u64, @bitCast(try parseInteger(i64, raw))),
        .f32 => @as(u32, @bitCast(std.fmt.parseFloat(f32, raw) catch return error.InvalidUniformValue)),
        .f64 => @as(u64, @bitCast(std.fmt.parseFloat(f64, raw) catch return error.InvalidUniformValue)),
        .v128 => error.InvalidUniformValue,
    };
}

fn applyTargetUniform(uniform: FormUniform, budget: usize) (MultipartError || interpreter.Error)!void {
    var export_name: ["uniform_set_".len + 63]u8 = undefined;
    @memcpy(export_name[0.."uniform_set_".len], "uniform_set_");
    @memcpy(export_name["uniform_set_".len .. "uniform_set_".len + uniform.key.len], uniform.key);
    const name = export_name[0 .. "uniform_set_".len + uniform.key.len];
    const function_index = machine.functionExportIndex(name) orelse return error.InvalidUniformKey;
    const signature = machine.functionSignature(function_index) orelse return error.InvalidUniformKey;
    if (signature.parameters.len != 1 or signature.result == null or signature.result.? != signature.parameters[0] or
        signature.parameters[0] == .v128)
    {
        return error.InvalidUniformValue;
    }
    const value = try uniformValue(uniform.value, signature.parameters[0]);
    _ = try machine.invokeScalarSetter(name, value, signature.parameters[0], budget);
}

fn readBoundary(out: *[TYPE_PREFIX.len + DEFAULT_UUID.len]u8) MultipartError![]const u8 {
    // The host can rewrite the UUID between renders, outside Zig's view.
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

fn dispositionName(value: []const u8) MultipartError![]const u8 {
    var fields = std.mem.splitScalar(u8, value, ';');
    if (!std.ascii.eqlIgnoreCase(trimOWS(fields.next() orelse return error.InvalidHeader), "form-data")) {
        return error.InvalidHeader;
    }
    var result: ?[]const u8 = null;
    while (fields.next()) |raw_field| {
        const field = trimOWS(raw_field);
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidHeader;
        const key = trimOWS(field[0..equal]);
        const raw_value = trimOWS(field[equal + 1 ..]);
        if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') return error.InvalidHeader;
        const quoted = raw_value[1 .. raw_value.len - 1];
        if (std.mem.indexOfAny(u8, quoted, "\"\\\r\n") != null) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(key, "name")) {
            if (result != null) return error.InvalidHeader;
            result = quoted;
        }
    }
    return result orelse error.InvalidHeader;
}

fn parseHeaders(block: []const u8) MultipartError![]const u8 {
    var disposition: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return error.InvalidHeader;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const key = line[0..colon];
        const value = trimOWS(line[colon + 1 ..]);
        if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
            if (disposition != null) return error.InvalidHeader;
            disposition = try dispositionName(value);
        } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
            if (value.len == 0) return error.InvalidHeader;
        } else {
            return error.InvalidHeader;
        }
    }
    return disposition orelse error.InvalidHeader;
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

fn parseMultipart(input: []const u8) MultipartError!RunInput {
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
    var target_input: ?[]const u8 = null;
    var uniforms: [MAX_TARGET_UNIFORMS]FormUniform = undefined;
    var uniform_count: usize = 0;
    var cursor: usize = opening.len;
    while (true) {
        const header_end = std.mem.indexOfPos(u8, input, cursor, "\r\n\r\n") orelse return error.InvalidMultipart;
        if (header_end - cursor > 16 * 1024) return error.InvalidHeader;
        const name = try parseHeaders(input[cursor..header_end]);
        const body_start = header_end + 4;
        const marker_at = findBoundary(input, body_start, &marker) orelse return error.InvalidMultipart;
        const body = input[body_start..marker_at];
        if (std.mem.eql(u8, name, "component")) {
            if (component != null) return error.DuplicatePart;
            component = body;
        } else if (std.mem.eql(u8, name, "input")) {
            if (target_input != null) return error.DuplicatePart;
            target_input = body;
        } else if (std.mem.startsWith(u8, name, UNIFORM_FIELD_PREFIX) and std.mem.endsWith(u8, name, "]")) {
            const key = name[UNIFORM_FIELD_PREFIX.len .. name.len - 1];
            if (!validUniformKey(key)) return error.InvalidUniformKey;
            for (uniforms[0..uniform_count]) |uniform| {
                if (std.mem.eql(u8, uniform.key, key)) return error.DuplicatePart;
            }
            if (uniform_count == uniforms.len) return error.TooManyUniforms;
            uniforms[uniform_count] = .{ .key = key, .value = body };
            uniform_count += 1;
        } else {
            return error.UnknownPart;
        }

        cursor = marker_at + marker.len;
        if (cursor + 2 > input.len) return error.InvalidMultipart;
        if (std.mem.eql(u8, input[cursor .. cursor + 2], "--")) {
            cursor += 2;
            if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "\r\n")) cursor += 2;
            if (cursor != input.len) return error.InvalidMultipart;
            var result: RunInput = .{
                .component = component orelse return error.MissingComponent,
                .target_input = target_input orelse &.{},
            };
            std.mem.sort(FormUniform, uniforms[0..uniform_count], {}, struct {
                fn lessThan(_: void, left: FormUniform, right: FormUniform) bool {
                    return std.mem.order(u8, left.key, right.key) == .lt;
                }
            }.lessThan);
            @memcpy(result.uniforms[0..uniform_count], uniforms[0..uniform_count]);
            result.uniform_count = uniform_count;
            return result;
        }
        if (!std.mem.eql(u8, input[cursor .. cursor + 2], "\r\n")) return error.InvalidMultipart;
        cursor += 2;
    }
}

test "parses component and optional input parts" {
    const body = "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"component\"\r\n\r\n" ++
        "wasm\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"input\"\r\n\r\n" ++
        "hello\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    const parsed = try parseMultipart(body);
    try std.testing.expectEqualStrings("wasm", parsed.component);
    try std.testing.expectEqualStrings("hello", parsed.target_input);
}

test "requires the component part" {
    const body = "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"input\"\r\n\r\n" ++
        "hello\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    try std.testing.expectError(error.MissingComponent, parseMultipart(body));
}

test "parses and sorts prefixed uniform parts" {
    const body = "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"component\"\r\n\r\n" ++
        "wasm\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"uniforms[zebra]\"\r\n\r\n" ++
        "2\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"uniforms[alpha]\"\r\n\r\n" ++
        "1\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    const parsed = try parseMultipart(body);
    try std.testing.expectEqual(@as(usize, 2), parsed.uniform_count);
    try std.testing.expectEqualStrings("alpha", parsed.uniforms[0].key);
    try std.testing.expectEqualStrings("1", parsed.uniforms[0].value);
    try std.testing.expectEqualStrings("zebra", parsed.uniforms[1].key);
    try std.testing.expectEqualStrings("2", parsed.uniforms[1].value);
}

test "rejects bare and malformed uniform field names" {
    const bare = "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"component\"\r\n\r\n" ++
        "wasm\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"cols\"\r\n\r\n" ++
        "40\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    try std.testing.expectError(error.UnknownPart, parseMultipart(bare));

    const malformed = "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"component\"\r\n\r\n" ++
        "wasm\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000\r\n" ++
        "Content-Disposition: form-data; name=\"uniforms[bad-key]\"\r\n\r\n" ++
        "40\r\n" ++
        "--uuid-00000000-0000-0000-0000-000000000000--\r\n";
    try std.testing.expectError(error.InvalidUniformKey, parseMultipart(malformed));
}
