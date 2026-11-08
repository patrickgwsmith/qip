// Validates a JSON instance against a JSON Schema (draft 2020-12) and, when
// it conforms, outputs the instance bytes unchanged.
//
// Input is one JSON envelope:
//
//   {"schema": <schema>, "instance": <instance>, "schemas": {"<uri>": <schema>}}
//
// "schema" and "instance" are required; "schemas" is optional and supplies
// extra documents for remote $ref, keyed by absolute URI, as ata-validator's
// and @cfworker/json-schema's preloaded schemas are. Keys may come in any
// order. Documents that declare $id are also found by that $id. The 2020-12
// meta-schemas are built in. Nothing is fetched. On accept the output is the
// instance's exact bytes as they appear inside the envelope.
//
// Rejection means one thing: the instance does not conform to the schema.
// Everything else traps: invalid JSON, a missing, unknown or repeated
// envelope key, a non-object "schemas", a
// $ref that does not resolve, a regular expression outside the supported
// subset, a required vocabulary this validator does not know, or a resource
// limit. That keeps a broken schema from looking like an invalid instance.
//
// Keywords follow the core, applicator, unevaluated and validation
// vocabularies. format, content* and the meta-data keywords are annotations
// and never fail validation, as the default 2020-12 dialect specifies.
// Numbers compare exactly by their decimal text, never as floats: 1.0 equals
// 1, 0.0075 is a multiple of 0.0001, and 1e400 is greater than 1e308. A
// multipleOf divisor with more than 37 significant digits traps.
//
// pattern and patternProperties use ECMA-262 syntax with the u flag, matched
// by a linear-time Pike VM: literals, ., ^, $, classes, \d \w \s \b and their
// negations, \p{L}/\p{Letter} and \P{...}, groups, alternation and the
// greedy or lazy quantifiers * + ? {n} {n,} {n,m}. Lookaround and
// backreferences are not supported and trap.
//
// Validation recurses through the schema, so this component does not satisfy
// the strict profile's acyclic call graph. Depth is bounded by MAX_DEPTH.
const std = @import("std");
const js = @import("lib/json-schema-2020-12.zig");

const State = js.State;
const Error = js.Error;

const INPUT_CAP: usize = 4 * 1024 * 1024;
const ARENA_CAP: usize = 48 * 1024 * 1024;
// While the envelope parses, the JSON parser keeps pending children here, up
// to 6 bytes per input byte; the tree it builds in the arena is at most 6 more.
const SCRATCH_CAP: usize = 6 * INPUT_CAP;
const INPUT_CONTENT_TYPE = "application/json";
const OUTPUT_CONTENT_TYPE = "application/json";

var input_buf: [INPUT_CAP]u8 = undefined;
var arena_buf: [ARENA_CAP]u8 = undefined;
var scratch_buf: [SCRATCH_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

// Accepted output is the instance, which is part of the input.
export fn output_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

// Rejection carries no detail: it only says the instance does not conform.
export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];
    const instance = run(input) catch @trap();
    if (instance) |bytes| {
        return .{
            .output_size_or_failure = @intCast(bytes.len),
            .output_ptr = @intCast(@intFromPtr(bytes.ptr)),
            .failed = 0,
        };
    }
    return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
}

// ---------------------------------------------------------------------------

var arena_fba: std.heap.FixedBufferAllocator = undefined;
var scratch_fba: std.heap.FixedBufferAllocator = undefined;

// Returns the instance bytes when they conform, or null when they do not.
fn run(input: []const u8) Error!?[]const u8 {
    arena_fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const alloc = arena_fba.allocator();
    const env = try js.parseEnvelope(alloc, scratch_fba.allocator(), input);
    const instance = env.instance orelse return error.MissingKey;
    var st = State{ .alloc = alloc, .scratch = &scratch_fba };
    const schema = try st.loadEnvelope(env);
    if (try st.validate(schema, instance, null)) return env.instance_bytes;
    return null;
}

test {
    // The shared library's tests run with this file's tests.
    _ = js;
}
