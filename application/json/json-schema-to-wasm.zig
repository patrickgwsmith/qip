// Compiles a JSON Schema (draft 2020-12) into a QIP Content component that
// validates instances against it.
//
// Input is one JSON envelope, the same one json-schema-2020-12-must-be-valid
// takes but without "instance":
//
//   {"schema": <schema>, "schemas": {"<uri>": <schema>}}
//
// "schemas" is optional and supplies documents for remote $ref, keyed by
// absolute URI. The 2020-12 meta-schemas are built in. Output is a Wasm
// module. The generated component reads one JSON instance and outputs it
// unchanged when it conforms; otherwise it rejects. Invalid JSON traps. It
// accepts and rejects exactly what json-schema-2020-12-must-be-valid does
// for the same schema, and passes the same 1,298 suite cases.
//
// What the compiler does ahead of time: parses and indexes every document,
// resolves each $ref and $anchor to a node, decides which $dynamicRefs are
// dynamic, keeps only the keywords of active vocabularies, turns type into
// a bit mask, minLength-style numbers into integer bounds, const and enum
// into value tapes, and checks every keyword's value and every regular
// expression. The generated module does none of that per render.
//
// How the module is built: the output is lib/json-schema-runtime.wasm, a
// fixed evaluator, plus one more active data segment holding the compiled
// program (lib/json-schema-program.zig), placed at the address the runtime's
// marker names. A `qip.json-schema` custom section keeps the input envelope,
// so the module says which schema it checks.
//
// Rejection means the input cannot be compiled: invalid JSON, a missing,
// unknown or repeated envelope key ("instance" included), a malformed
// keyword value, a $ref that does not resolve, a regular expression outside
// the supported subset, a multipleOf with more than 37 significant digits, a
// required vocabulary this compiler does not know, or nesting past 512.
// Resource limits trap.
//
// Unlike json-schema-2020-12-must-be-valid, which only notices a malformed
// keyword when an instance reaches it, the compiler checks every keyword
// that can apply.
const std = @import("std");
const js = @import("lib/json-schema-2020-12.zig");
const prog = @import("lib/json-schema-program.zig");

const runtime_wasm = @embedFile("lib/json-schema-runtime.wasm");

const Value = js.Value;
const Member = js.Member;
const Node = prog.Node;
const Tok = prog.Tok;
const Str = prog.Str;
const List = prog.List;
const Bounds = prog.Bounds;
const NONE = prog.NONE;

const INPUT_CAP: usize = 4 * 1024 * 1024;
const ARENA_CAP: usize = 64 * 1024 * 1024;
const SCRATCH_CAP: usize = 1024 * 1024;
const PROGRAM_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = runtime_wasm.len + PROGRAM_CAP + INPUT_CAP + 1024;
const INPUT_CONTENT_TYPE = "application/json";
const OUTPUT_CONTENT_TYPE = "application/wasm";
const CUSTOM_SECTION = "qip.json-schema";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var arena_buf: [ARENA_CAP]u8 = undefined;
var scratch_buf: [SCRATCH_CAP]u8 = undefined;
var program_buf: [PROGRAM_CAP]u8 align(16) = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
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

// Rejection carries no detail.
export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    const size = compile(input_buf[0..input_size]) catch |err| switch (err) {
        error.OutOfMemory => @trap(),
        else => return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 },
    };
    return .{ .output_size_or_failure = @intCast(size), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

const Error = js.Error;

// ---------------------------------------------------------------------------
// Schema to program

// Strings interned to small ids: resource base URIs and dynamic anchor names.
const Interner = struct {
    items: std.ArrayListUnmanaged([]const u8) = .empty,

    fn id(in: *Interner, alloc: std.mem.Allocator, s: []const u8) Error!u32 {
        for (in.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, s)) return @intCast(i);
        }
        try in.items.append(alloc, s);
        return @intCast(in.items.items.len - 1);
    }

    fn find(in: *const Interner, s: []const u8) ?u32 {
        for (in.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, s)) return @intCast(i);
        }
        return null;
    }
};

const Compiler = struct {
    st: *js.State,
    alloc: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    words: std.ArrayListUnmanaged(u32) = .empty,
    toks: std.ArrayListUnmanaged(Tok) = .empty,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    dyns: std.ArrayListUnmanaged(prog.DynAnchor) = .empty,
    regexes: std.ArrayListUnmanaged(Str) = .empty,
    nums: std.ArrayListUnmanaged(prog.Num) = .empty,
    regex_sources: Interner = .{},
    node_of: js.PtrTable = .{},
    work: std.ArrayListUnmanaged(*const Value) = .empty,
    resources: Interner = .{},
    anchor_names: Interner = .{},

    fn nodeFor(c: *Compiler, v: *const Value) Error!u32 {
        if (c.node_of.get(@intFromPtr(v))) |i| return @intCast(i - 1);
        const i: u32 = @intCast(c.nodes.items.len);
        try c.nodes.append(c.alloc, .{});
        try c.node_of.put(c.alloc, @intFromPtr(v), i + 1);
        try c.work.append(c.alloc, v);
        return i;
    }

    fn str(c: *Compiler, s: []const u8) Error!Str {
        const off: u32 = @intCast(c.bytes.items.len);
        try c.bytes.appendSlice(c.alloc, s);
        return .{ .off = off, .len = @intCast(s.len) };
    }

    // len counts entries, each `stride` words.
    fn list(c: *Compiler, items: []const u32, stride: usize) Error!List {
        const off: u32 = @intCast(c.words.items.len);
        try c.words.appendSlice(c.alloc, items);
        return .{ .off = off, .len = @intCast(items.len / stride) };
    }

    fn regex(c: *Compiler, pattern: []const u8) Error!u32 {
        if (c.regex_sources.find(pattern)) |i| return i;
        // Compiled here only to reject what the runtime could not run.
        const mark = c.st.scratch.end_index;
        defer c.st.scratch.end_index = mark;
        _ = try js.compileRegex(c.st.scratch.allocator(), pattern);
        const i = try c.regex_sources.id(c.alloc, pattern);
        try c.regexes.append(c.alloc, try c.str(pattern));
        return i;
    }

    // Appends a JSON value to the value tape and returns its index.
    fn value(c: *Compiler, v: *const Value) Error!u32 {
        const i: u32 = @intCast(c.toks.items.len);
        switch (v.*) {
            .null => try c.pushTok(prog.TAG_NULL, .{}),
            .boolean => |b| try c.pushTok(if (b) prog.TAG_TRUE else prog.TAG_FALSE, .{}),
            .number => |n| try c.pushTok(prog.TAG_NUMBER, try c.str(n.text)),
            .string => |s| try c.pushTok(prog.TAG_STRING, try c.str(s)),
            .array => |items| {
                try c.pushTok(prog.TAG_ARRAY, .{ .len = @intCast(items.len) });
                for (items) |*item| _ = try c.value(item);
            },
            .object => |members| {
                try c.pushTok(prog.TAG_OBJECT, .{ .len = @intCast(members.len) });
                for (members) |*m| {
                    try c.pushTok(prog.TAG_STRING, try c.str(m.key));
                    _ = try c.value(&m.value);
                }
            },
        }
        c.toks.items[i].end = @intCast(c.toks.items.len);
        return i;
    }

    fn pushTok(c: *Compiler, tag: u32, s: Str) Error!void {
        const i: u32 = @intCast(c.toks.items.len);
        try c.toks.append(c.alloc, .{ .tag = tag, .off = s.off, .len = s.len, .end = i + 1 });
    }

    fn subschemas(c: *Compiler, v: *const Value) Error!List {
        if (v.* != .array) return error.BadSchema;
        const ids = try c.alloc.alloc(u32, v.array.len);
        for (v.array, ids) |*sub, *id| id.* = try c.nodeFor(sub);
        return c.list(ids, 1);
    }

    // (key, node) pairs for properties and dependentSchemas.
    fn keyed(c: *Compiler, v: *const Value) Error!List {
        if (v.* != .object) return error.BadSchema;
        const out = try c.alloc.alloc(u32, v.object.len * 3);
        for (v.object, 0..) |*m, i| {
            const key = try c.str(m.key);
            out[i * 3] = key.off;
            out[i * 3 + 1] = key.len;
            out[i * 3 + 2] = try c.nodeFor(&m.value);
        }
        return c.list(out, 3);
    }

    fn names(c: *Compiler, v: *const Value) Error!List {
        if (v.* != .array) return error.BadSchema;
        const out = try c.alloc.alloc(u32, v.array.len * 2);
        for (v.array, 0..) |name, i| {
            if (name != .string) return error.BadSchema;
            const s = try c.str(name.string);
            out[i * 2] = s.off;
            out[i * 2 + 1] = s.len;
        }
        return c.list(out, 2);
    }

    fn number(c: *Compiler, v: *const Value) Error!u32 {
        if (v.* != .number) return error.BadSchema;
        var n = prog.Num{ .text = try c.str(v.number.text) };
        if (js.smallNumber(v.number.text)) |small| {
            const bits: u64 = @bitCast(small.value);
            n.value_lo = @truncate(bits);
            n.value_hi = @truncate(bits >> 32);
            n.places = small.places;
            n.small = 1;
        }
        try c.nums.append(c.alloc, n);
        return @intCast(c.nums.items.len - 1);
    }

    // required names, each with the index of the same key in this node's
    // properties (or NONE), so the runtime can answer from the properties
    // pass instead of searching the object again.
    fn required(c: *Compiler, v: *const Value, properties: ?*const Value) Error!List {
        if (v.* != .array) return error.BadSchema;
        const out = try c.alloc.alloc(u32, v.array.len * 3);
        for (v.array, 0..) |name, i| {
            if (name != .string) return error.BadSchema;
            const s = try c.str(name.string);
            out[i * 3] = s.off;
            out[i * 3 + 1] = s.len;
            out[i * 3 + 2] = NONE;
            if (properties) |p| if (p.* == .object and p.object.len <= 64) {
                for (p.object, 0..) |m, k| {
                    if (std.mem.eql(u8, m.key, name.string)) {
                        out[i * 3 + 2] = @intCast(k);
                        break;
                    }
                }
            };
        }
        return c.list(out, 3);
    }

    fn compileNode(c: *Compiler, v: *const Value) Error!void {
        const idx: u32 = @intCast(c.node_of.get(@intFromPtr(v)).? - 1);
        var n = Node{};
        switch (v.*) {
            .boolean => |b| {
                n.flags = if (b) prog.F_TRUE else prog.F_FALSE;
                c.nodes.items[idx] = n;
                return;
            },
            .object => {},
            else => return error.BadSchema,
        }
        const info = try c.st.infoOf(v);
        const kw = info.kw orelse return error.BadSchema;
        const vocab = info.vocab;
        n.resource = try c.resources.id(c.alloc, info.base);

        if (kw.@"$ref") |ref| n.ref = try c.nodeFor(try c.st.resolveRef(ref, info.base));
        if (kw.@"$dynamicRef") |ref| {
            n.dyn_ref = try c.nodeFor(try c.st.resolveRef(ref, info.base));
            // Dynamic only when the static target declares a $dynamicAnchor
            // of the same name, as in State.resolveDynamicRef.
            const uri = try js.resolveUri(c.alloc, info.base, ref.string);
            const parts = js.splitFragment(uri);
            if (parts.fragment.len > 0 and parts.fragment[0] != '/') {
                const key = try std.mem.concat(c.alloc, u8, &.{ parts.base, "#", parts.fragment });
                if (c.st.dynamic_anchors.get(key) != null) n.dyn_name = try c.anchor_names.id(c.alloc, parts.fragment);
            }
        }

        if (vocab.applicator) {
            if (kw.@"allOf") |l| n.all_of = try c.subschemas(l);
            if (kw.@"anyOf") |l| n.any_of = try c.subschemas(l);
            if (kw.@"oneOf") |l| n.one_of = try c.subschemas(l);
            if (kw.@"not") |s| n.not = try c.nodeFor(s);
            if (kw.@"if") |s| {
                n.if_ = try c.nodeFor(s);
                if (kw.@"then") |t| n.then = try c.nodeFor(t);
                if (kw.@"else") |t| n.else_ = try c.nodeFor(t);
            }
            if (kw.@"prefixItems") |l| n.prefix_items = try c.subschemas(l);
            if (kw.@"items") |s| n.items = try c.nodeFor(s);
            if (kw.@"contains") |s| {
                n.contains = try c.nodeFor(s);
                // minContains and maxContains belong to the validation
                // vocabulary; without it contains needs one match.
                if (vocab.validation) {
                    if (kw.@"minContains") |m| n.contains_bounds.min = (try countBounds(m)).min;
                    if (kw.@"maxContains") |m| n.contains_bounds.max_excl = (try countBounds(m)).max_excl;
                }
            }
            if (kw.@"properties") |p| n.properties = try c.keyed(p);
            if (kw.@"patternProperties") |p| {
                if (p.* != .object) return error.BadSchema;
                const out = try c.alloc.alloc(u32, p.object.len * 2);
                for (p.object, 0..) |*m, i| {
                    out[i * 2] = try c.regex(m.key);
                    out[i * 2 + 1] = try c.nodeFor(&m.value);
                }
                n.pattern_properties = try c.list(out, 2);
            }
            if (kw.@"additionalProperties") |s| n.additional = try c.nodeFor(s);
            if (kw.@"dependentSchemas") |d| n.dependent_schemas = try c.keyed(d);
            if (kw.@"propertyNames") |s| n.property_names = try c.nodeFor(s);
        }
        if (vocab.unevaluated) {
            if (kw.@"unevaluatedItems") |s| n.uneval_items = try c.nodeFor(s);
            if (kw.@"unevaluatedProperties") |s| n.uneval_props = try c.nodeFor(s);
        }
        if (vocab.validation) {
            if (kw.@"type") |t| n.types = try typeMask(t);
            if (kw.@"const") |k| n.const_ = try c.value(k);
            if (kw.@"enum") |e| {
                if (e.* != .array) return error.BadSchema;
                const out = try c.alloc.alloc(u32, e.array.len);
                for (e.array, out) |*option, *o| o.* = try c.value(option);
                n.enum_ = try c.list(out, 1);
                n.flags |= prog.F_ENUM;
            }
            if (kw.@"multipleOf") |m| {
                if (m.* != .number) return error.BadSchema;
                // Past 37 significant digits the exact remainder would not
                // fit in a u128.
                if (js.decimal(m.number.text).digitCount() > 37) return error.Unsupported;
                n.multiple_of = try c.number(m);
            }
            if (kw.@"maximum") |m| n.maximum = try c.number(m);
            if (kw.@"exclusiveMaximum") |m| n.exclusive_maximum = try c.number(m);
            if (kw.@"minimum") |m| n.minimum = try c.number(m);
            if (kw.@"exclusiveMinimum") |m| n.exclusive_minimum = try c.number(m);
            if (kw.@"maxLength") |m| n.string_length.max_excl = (try countBounds(m)).max_excl;
            if (kw.@"minLength") |m| n.string_length.min = (try countBounds(m)).min;
            if (kw.@"pattern") |p| {
                if (p.* != .string) return error.BadSchema;
                n.pattern = try c.regex(p.string);
            }
            if (kw.@"maxItems") |m| n.items_count.max_excl = (try countBounds(m)).max_excl;
            if (kw.@"minItems") |m| n.items_count.min = (try countBounds(m)).min;
            if (kw.@"uniqueItems") |u| {
                if (u.* == .boolean and u.boolean) n.flags |= prog.F_UNIQUE;
            }
            if (kw.@"maxProperties") |m| n.props_count.max_excl = (try countBounds(m)).max_excl;
            if (kw.@"minProperties") |m| n.props_count.min = (try countBounds(m)).min;
            if (kw.@"required") |r| n.required = try c.required(r, if (vocab.applicator) kw.@"properties" else null);
            if (kw.@"dependentRequired") |d| {
                if (d.* != .object) return error.BadSchema;
                const inner = try c.alloc.alloc(List, d.object.len);
                for (d.object, inner) |*m, *l| l.* = try c.names(&m.value);
                const out = try c.alloc.alloc(u32, d.object.len * 4);
                for (d.object, inner, 0..) |*m, l, i| {
                    const key = try c.str(m.key);
                    out[i * 4] = key.off;
                    out[i * 4 + 1] = key.len;
                    out[i * 4 + 2] = l.off;
                    out[i * 4 + 3] = l.len;
                }
                n.dependent_required = try c.list(out, 4);
            }
        }

        const default_bounds = Bounds{};
        if (!std.meta.eql(n.string_length, default_bounds)) n.flags |= prog.F_LENGTH;
        if (!std.meta.eql(n.items_count, default_bounds)) n.flags |= prog.F_ITEMS_COUNT;
        if (!std.meta.eql(n.props_count, default_bounds)) n.flags |= prog.F_PROPS_COUNT;
        if (n.multiple_of != NONE or n.maximum != NONE or n.exclusive_maximum != NONE or n.minimum != NONE or n.exclusive_minimum != NONE) n.flags |= prog.F_HAS_NUMBER;
        if (n.flags & prog.F_LENGTH != 0 or n.pattern != NONE) n.flags |= prog.F_HAS_STRING;
        if (n.prefix_items.len > 0 or n.items != NONE or n.contains != NONE or n.flags & (prog.F_ITEMS_COUNT | prog.F_UNIQUE) != 0) n.flags |= prog.F_HAS_ARRAY;
        if (n.properties.len > 0 or n.pattern_properties.len > 0 or n.additional != NONE) n.flags |= prog.F_MATCH_PROPS;
        if (n.flags & prog.F_MATCH_PROPS != 0 or n.dependent_schemas.len > 0 or n.property_names != NONE or
            n.required.len > 0 or n.dependent_required.len > 0 or n.flags & prog.F_PROPS_COUNT != 0) n.flags |= prog.F_HAS_OBJECT;

        // A schema with nothing to check passes everything.
        var empty = Node{};
        empty.resource = n.resource;
        if (std.mem.eql(u8, std.mem.asBytes(&empty), std.mem.asBytes(&n))) n.flags = prog.F_TRUE;
        empty.ref = n.ref;
        if (n.ref != NONE and std.mem.eql(u8, std.mem.asBytes(&empty), std.mem.asBytes(&n))) n.flags = prog.F_ONLY_REF;
        c.nodes.items[idx] = n;
    }

    // Compiles every node reachable from the root, then the targets of
    // dynamic anchors that a dynamic $dynamicRef could select, until no new
    // node appears.
    fn run(c: *Compiler, root: *const Value) Error!u32 {
        const root_idx = try c.nodeFor(root);
        while (true) {
            while (c.work.pop()) |v| try c.compileNode(v);
            const before = c.nodes.items.len;
            for (c.st.dynamic_anchors.items.items) |entry| {
                const hash = std.mem.indexOfScalar(u8, entry.key, '#') orelse continue;
                const name = c.anchor_names.find(entry.key[hash + 1 ..]) orelse continue;
                const resource = try c.resources.id(c.alloc, entry.key[0..hash]);
                const node = try c.nodeFor(entry.val);
                var known = false;
                for (c.dyns.items) |d| {
                    if (d.resource == resource and d.name == name) known = true;
                }
                if (!known) try c.dyns.append(c.alloc, .{ .resource = resource, .name = name, .node = node });
            }
            if (c.work.items.len == 0 and c.nodes.items.len == before) break;
        }
        return root_idx;
    }

    // Lays the program out as lib/json-schema-program.zig describes.
    fn emit(c: *Compiler, root: u32, out: []align(16) u8) Error![]const u8 {
        var h = prog.Header{ .root = root };
        var off: usize = @sizeOf(prog.Header);
        h.node_count = @intCast(c.nodes.items.len);
        h.nodes_off = @intCast(off);
        off += c.nodes.items.len * @sizeOf(Node);
        h.words_count = @intCast(c.words.items.len);
        h.words_off = @intCast(off);
        off += c.words.items.len * 4;
        h.toks_count = @intCast(c.toks.items.len);
        h.toks_off = @intCast(off);
        off += c.toks.items.len * @sizeOf(Tok);
        h.dyn_count = @intCast(c.dyns.items.len);
        h.dyn_off = @intCast(off);
        off += c.dyns.items.len * @sizeOf(prog.DynAnchor);
        h.regex_count = @intCast(c.regexes.items.len);
        h.regexes_off = @intCast(off);
        off += c.regexes.items.len * @sizeOf(Str);
        h.num_count = @intCast(c.nums.items.len);
        h.nums_off = @intCast(off);
        off += c.nums.items.len * @sizeOf(prog.Num);
        h.bytes_off = @intCast(off);
        h.bytes_len = @intCast(c.bytes.items.len);
        off += c.bytes.items.len;
        if (off > out.len) return error.OutOfMemory;
        h.total_len = @intCast(off);
        @memcpy(out[0..@sizeOf(prog.Header)], std.mem.asBytes(&h));
        @memcpy(out[h.nodes_off..][0 .. c.nodes.items.len * @sizeOf(Node)], std.mem.sliceAsBytes(c.nodes.items));
        @memcpy(out[h.words_off..][0 .. c.words.items.len * 4], std.mem.sliceAsBytes(c.words.items));
        @memcpy(out[h.toks_off..][0 .. c.toks.items.len * @sizeOf(Tok)], std.mem.sliceAsBytes(c.toks.items));
        @memcpy(out[h.dyn_off..][0 .. c.dyns.items.len * @sizeOf(prog.DynAnchor)], std.mem.sliceAsBytes(c.dyns.items));
        @memcpy(out[h.regexes_off..][0 .. c.regexes.items.len * @sizeOf(Str)], std.mem.sliceAsBytes(c.regexes.items));
        @memcpy(out[h.nums_off..][0 .. c.nums.items.len * @sizeOf(prog.Num)], std.mem.sliceAsBytes(c.nums.items));
        @memcpy(out[h.bytes_off..][0..c.bytes.items.len], c.bytes.items);
        return out[0..off];
    }
};

fn typeMask(t: *const Value) Error!u32 {
    switch (t.*) {
        .string => |name| return typeBit(name),
        .array => |names| {
            var mask: u32 = 0;
            for (names) |name| {
                if (name != .string) return error.BadSchema;
                mask |= typeBit(name.string);
            }
            return mask;
        },
        else => return error.BadSchema,
    }
}

fn typeBit(name: []const u8) u32 {
    const table = .{
        .{ "null", prog.T_NULL },
        .{ "boolean", prog.T_BOOLEAN },
        .{ "integer", prog.T_INTEGER },
        .{ "number", prog.T_NUMBER },
        .{ "string", prog.T_STRING },
        .{ "array", prog.T_ARRAY },
        .{ "object", prog.T_OBJECT },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    // An unknown type name matches nothing.
    return 0;
}

// The integer bounds a count must fall in for a schema number used as a
// minimum (count >= ceil(v)) or a maximum (count <= floor(v)), saturated at
// what a u32 count can reach.
fn countBounds(v: *const Value) Error!Bounds {
    if (v.* != .number) return error.BadSchema;
    const text = v.number.text;
    const d = js.decimal(text);
    if (d.isZero()) return .{ .min = 0, .max_excl = 1 };
    // Negative: every count is at least it, and none is at most it.
    if (text[0] == '-') return .{ .min = 0, .max_excl = 0 };
    const int_digits = d.exp + @as(i64, @intCast(d.digitCount()));
    if (int_digits > 10) return .{ .min = prog.UNBOUNDED, .max_excl = prog.UNBOUNDED };
    var floor: u64 = 0;
    var i: i64 = 0;
    while (i < int_digits) : (i += 1) {
        const index: usize = @intCast(i);
        const digit: u64 = if (index < d.digitCount()) d.digit(d.lead + index) else 0;
        floor = floor * 10 + digit;
    }
    const fraction = int_digits < @as(i64, @intCast(d.digitCount()));
    const ceil = floor + @intFromBool(fraction);
    return .{
        .min = @intCast(@min(ceil, prog.UNBOUNDED)),
        .max_excl = @intCast(@min(floor + 1, prog.UNBOUNDED)),
    };
}

// ---------------------------------------------------------------------------
// Module assembly

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn bytes(w: *Writer, s: []const u8) Error!void {
        if (w.len + s.len > w.buf.len) return error.OutOfMemory;
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
    }

    fn byte(w: *Writer, b: u8) Error!void {
        try w.bytes(&.{b});
    }

    fn uleb(w: *Writer, value: u64) Error!void {
        var v = value;
        while (true) {
            const b: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if (v == 0) return w.byte(b);
            try w.byte(b | 0x80);
        }
    }

    fn sleb(w: *Writer, value: i64) Error!void {
        var v = value;
        while (true) {
            const b: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if ((v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0)) return w.byte(b);
            try w.byte(b | 0x80);
        }
    }
};

fn ulebLen(value: u64) usize {
    var n: usize = 1;
    var v = value >> 7;
    while (v != 0) : (v >>= 7) n += 1;
    return n;
}

const Leb = struct { value: u64, len: usize };

fn readUleb(b: []const u8, at: usize) Leb {
    var value: u64 = 0;
    var shift: u6 = 0;
    var i = at;
    while (true) : (i += 1) {
        value |= @as(u64, b[i] & 0x7F) << shift;
        if (b[i] & 0x80 == 0) return .{ .value = value, .len = i + 1 - at };
        shift += 7;
    }
}

const Placement = struct { addr: u32, cap: u32 };

// Where the runtime expects its program, from the marker in its data.
const placement: Placement = blk: {
    @setEvalBranchQuota(runtime_wasm.len * 20);
    const magic = &prog.MARKER_MAGIC;
    const at = std.mem.indexOf(u8, runtime_wasm, magic) orelse @compileError("runtime marker not found");
    if (std.mem.indexOfPos(u8, runtime_wasm, at + 1, magic) != null) @compileError("runtime marker is not unique");
    break :blk .{
        .addr = std.mem.readInt(u32, runtime_wasm[at + 16 ..][0..4], .little),
        .cap = std.mem.readInt(u32, runtime_wasm[at + 20 ..][0..4], .little),
    };
};

// Copies the runtime, adding one active data segment for the program to the
// data section (and its count section, when present), then appends the
// custom section.
fn assemble(program: []const u8, source: []const u8, out: []u8) Error!usize {
    if (program.len > placement.cap) return error.OutOfMemory;
    var w = Writer{ .buf = out };
    try w.bytes(runtime_wasm[0..8]);
    var pos: usize = 8;
    var saw_data = false;
    while (pos < runtime_wasm.len) {
        const id = runtime_wasm[pos];
        const size = readUleb(runtime_wasm, pos + 1);
        const body_start = pos + 1 + size.len;
        const body = runtime_wasm[body_start..][0..@intCast(size.value)];
        pos = body_start + body.len;
        switch (id) {
            11 => {
                saw_data = true;
                const count = readUleb(body, 0);
                var seg_buf: [32]u8 = undefined;
                var seg = Writer{ .buf = &seg_buf };
                try seg.byte(0); // active, memory 0
                try seg.byte(0x41); // i32.const
                try seg.sleb(placement.addr);
                try seg.byte(0x0B);
                try seg.uleb(program.len);
                const new_size = ulebLen(count.value + 1) + (body.len - count.len) + seg.len + program.len;
                try w.byte(11);
                try w.uleb(new_size);
                try w.uleb(count.value + 1);
                try w.bytes(body[count.len..]);
                try w.bytes(seg.buf[0..seg.len]);
                try w.bytes(program);
            },
            12 => {
                const count = readUleb(body, 0);
                try w.byte(12);
                try w.uleb(ulebLen(count.value + 1));
                try w.uleb(count.value + 1);
            },
            else => {
                try w.byte(id);
                try w.uleb(body.len);
                try w.bytes(body);
            },
        }
    }
    if (!saw_data) return error.Unsupported;
    try w.byte(0);
    try w.uleb(ulebLen(CUSTOM_SECTION.len) + CUSTOM_SECTION.len + source.len);
    try w.uleb(CUSTOM_SECTION.len);
    try w.bytes(CUSTOM_SECTION);
    try w.bytes(source);
    return w.len;
}

var arena_fba: std.heap.FixedBufferAllocator = undefined;
var scratch_fba: std.heap.FixedBufferAllocator = undefined;

fn compile(input: []const u8) Error!usize {
    arena_fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const alloc = arena_fba.allocator();
    const env = try js.parseEnvelope(alloc, input);
    if (env.instance != null) return error.InvalidEnvelope;
    var st = js.State{ .alloc = alloc, .scratch = &scratch_fba };
    const root = try st.loadEnvelope(env);
    var c = Compiler{ .st = &st, .alloc = alloc };
    const root_idx = try c.run(root);
    const program = try c.emit(root_idx, &program_buf);
    return assemble(program, input, &output_buf);
}

test "count bounds round toward what a count can satisfy" {
    const cases = [_]struct { text: []const u8, min: u32, max_excl: u32 }{
        .{ .text = "0", .min = 0, .max_excl = 1 },
        .{ .text = "2", .min = 2, .max_excl = 3 },
        .{ .text = "2.0", .min = 2, .max_excl = 3 },
        .{ .text = "1.5", .min = 2, .max_excl = 2 },
        .{ .text = "0.5", .min = 1, .max_excl = 1 },
        .{ .text = "-1", .min = 0, .max_excl = 0 },
        .{ .text = "-0.5", .min = 0, .max_excl = 0 },
        .{ .text = "1e2", .min = 100, .max_excl = 101 },
        .{ .text = "1e400", .min = prog.UNBOUNDED, .max_excl = prog.UNBOUNDED },
        .{ .text = "4294967295", .min = prog.UNBOUNDED, .max_excl = prog.UNBOUNDED },
        .{ .text = "4294967294", .min = 4294967294, .max_excl = prog.UNBOUNDED },
    };
    for (cases) |case| {
        const v = Value{ .number = .{ .text = case.text } };
        const b = try countBounds(&v);
        try std.testing.expectEqual(case.min, b.min);
        try std.testing.expectEqual(case.max_excl, b.max_excl);
    }
}

test "LEB128 writers match the reader" {
    var buf: [16]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 300, 56627024, 0xFFFF_FFFF }) |v| {
        var w = Writer{ .buf = &buf };
        try w.uleb(v);
        try std.testing.expectEqual(ulebLen(v), w.len);
        try std.testing.expectEqual(v, readUleb(&buf, 0).value);
    }
    // i32.const needs signed LEB128: values with bit 6 set in the last
    // group take an extra byte.
    for ([_]i64{ 0, 63, 64, 8191, 8192, 56627024, 0x7FFF_FFFF }) |v| {
        var w = Writer{ .buf = &buf };
        try w.sleb(v);
        var value: i64 = 0;
        var shift: u6 = 0;
        for (buf[0..w.len]) |b| {
            value |= @as(i64, b & 0x7F) << shift;
            shift += 7;
        }
        if (buf[w.len - 1] & 0x40 != 0) value |= @as(i64, -1) << shift;
        try std.testing.expectEqual(v, value);
    }
}

test {
    _ = js;
}
