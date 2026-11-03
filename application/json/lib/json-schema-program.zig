// The compiled form of a JSON Schema that json-schema-to-wasm writes and
// json-schema-runtime reads. Both sides are wasm32 little-endian and share
// these extern structs, so the program is used in place without decoding.
//
// Layout: a Header, then the node, word, value-token and dynamic-anchor
// arrays, then a byte pool. Every offset is from the start of the program
// and 4-byte aligned. Each array element is a whole number of u32 words.
//
// A Node is one schema object or boolean schema. Absent single subschemas are
// NONE; absent lists have len 0. Lists live in the word array, and a List's
// len counts entries, not words:
//   all_of, any_of, one_of, prefix_items   node indices
//   properties                             (key Str, keyTag, node) as 4
//                                          words each, sorted by keyOrder
//   dependent_schemas                      (key Str, node) as 3 words each
//   pattern_properties                     (regex, node) as 2 words each
//   enum_                                  value-token indices
//   required                               (key Str, properties entry or NONE)
//                                          as 3 words each
//   dependent_required                     (key Str, List of key Strs) as 4 words
// Strings (keys, number texts) are Str ranges in the byte pool.
// Number keywords index the number array: each Num keeps the exact text and,
// when it has at most 18 digits and no exponent, the same value as an
// integer count of 10^-places for the fast path.
// const and enum values are stored as a token tape, the same Tok format the
// runtime parses the instance into, so one equality check serves both.
const std = @import("std");

pub const MAGIC = "qip.json-schema6".*;

// A properties key's length (capped at 255) in the top byte and its first
// three bytes below it, big-endian and zero-padded, stored with each entry.
// One compare of this word settles nearly every pair, and keys of up to
// three bytes never touch the byte pool.
pub fn keyTag(s: []const u8) u32 {
    var w: u32 = @intCast(@min(s.len, 255));
    for (0..3) |i| w = (w << 8) | (if (i < s.len) s[i] else 0);
    return w;
}

// The order properties keys are sorted in: by keyTag, then length, then
// bytes. Below 255 bytes that is length then bytes. The sort is stable, so
// of repeated keys the first one written comes first.
pub fn keyOrder(a: []const u8, b: []const u8) std.math.Order {
    const ta = keyTag(a);
    const tb = keyTag(b);
    if (ta != tb) return std.math.order(ta, tb);
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}

// The runtime keeps one Marker in its data section naming the address and
// size of the buffer its program goes in. The compiler finds it by MAGIC.
pub const MARKER_MAGIC = "qip.json-schema@".*;
pub const Marker = extern struct {
    magic: [16]u8,
    program: [*]align(16) const u8,
    cap: u32,
};
pub const NONE: u32 = 0xFFFF_FFFF;
// Count bounds: a count c passes when min <= c < max_excl. Unbounded is
// UNBOUNDED, which no count reaches because inputs are far smaller.
pub const UNBOUNDED: u32 = 0xFFFF_FFFF;

pub const Str = extern struct { off: u32 = 0, len: u32 = 0 };
pub const List = extern struct { off: u32 = 0, len: u32 = 0 };
pub const Bounds = extern struct { min: u32 = 0, max_excl: u32 = UNBOUNDED };

pub const Header = extern struct {
    magic: [16]u8 = MAGIC,
    root: u32 = 0,
    node_count: u32 = 0,
    nodes_off: u32 = 0,
    words_count: u32 = 0,
    words_off: u32 = 0,
    toks_count: u32 = 0,
    toks_off: u32 = 0,
    dyn_count: u32 = 0,
    dyn_off: u32 = 0,
    regex_count: u32 = 0,
    regexes_off: u32 = 0, // regex_count u32 word indices of RegexHeads
    num_count: u32 = 0,
    nums_off: u32 = 0,
    bytes_off: u32 = 0,
    bytes_len: u32 = 0,
    total_len: u32 = 0,
};

// Type bits for Node.types.
pub const T_NULL: u32 = 1 << 0;
pub const T_BOOLEAN: u32 = 1 << 1;
pub const T_INTEGER: u32 = 1 << 2; // integral numbers only
pub const T_NUMBER: u32 = 1 << 3;
pub const T_STRING: u32 = 1 << 4;
pub const T_ARRAY: u32 = 1 << 5;
pub const T_OBJECT: u32 = 1 << 6;
pub const T_ALL: u32 = 0x7F;

// Node.flags.
pub const F_FALSE: u32 = 1 << 0; // boolean schema false
pub const F_TRUE: u32 = 1 << 1; // boolean schema true, or {} with nothing to check
pub const F_UNIQUE: u32 = 1 << 2;
pub const F_CONTAINS_BOUNDS: u32 = 1 << 3; // contains_bounds came from minContains/maxContains
pub const F_HAS_NUMBER: u32 = 1 << 4; // any of multiple_of..exclusive_minimum
pub const F_HAS_STRING: u32 = 1 << 5; // length bounds or pattern
pub const F_HAS_ARRAY: u32 = 1 << 6; // array applicators or assertions
pub const F_HAS_OBJECT: u32 = 1 << 7; // object applicators or assertions
pub const F_LENGTH: u32 = 1 << 8; // string_length is set
pub const F_ITEMS_COUNT: u32 = 1 << 9;
pub const F_PROPS_COUNT: u32 = 1 << 10;
pub const F_MATCH_PROPS: u32 = 1 << 11; // properties, patternProperties or additionalProperties
pub const F_ENUM: u32 = 1 << 12; // enum is present, possibly empty
pub const F_ONLY_REF: u32 = 1 << 13; // $ref is the node's only keyword

pub const Node = extern struct {
    flags: u32 = 0,
    types: u32 = T_ALL,
    resource: u32 = 0,
    ref: u32 = NONE,
    dyn_ref: u32 = NONE, // static target of $dynamicRef
    dyn_name: u32 = NONE, // anchor name id when the reference is dynamic
    all_of: List = .{},
    any_of: List = .{},
    one_of: List = .{},
    not: u32 = NONE,
    if_: u32 = NONE,
    then: u32 = NONE,
    else_: u32 = NONE,
    prefix_items: List = .{},
    items: u32 = NONE,
    contains: u32 = NONE,
    contains_bounds: Bounds = .{ .min = 1 },
    properties: List = .{},
    pattern_properties: List = .{},
    additional: u32 = NONE,
    dependent_schemas: List = .{},
    property_names: u32 = NONE,
    uneval_items: u32 = NONE,
    uneval_props: u32 = NONE,
    const_: u32 = NONE,
    enum_: List = .{},
    multiple_of: u32 = NONE,
    maximum: u32 = NONE,
    exclusive_maximum: u32 = NONE,
    minimum: u32 = NONE,
    exclusive_minimum: u32 = NONE,
    string_length: Bounds = .{},
    pattern: u32 = NONE,
    items_count: Bounds = .{},
    props_count: Bounds = .{},
    required: List = .{},
    dependent_required: List = .{},
};

pub const Num = extern struct {
    text: Str,
    value_lo: u32 = 0,
    value_hi: u32 = 0,
    places: u32 = 0,
    small: u32 = 0, // 1 when value and places hold the number

    pub fn smallValue(n: Num) i64 {
        return @bitCast(@as(u64, n.value_hi) << 32 | n.value_lo);
    }
};

pub const DynAnchor = extern struct { resource: u32, name: u32, node: u32 };

// Regular expressions arrive compiled. Header.regexes_off holds regex_count
// word indices; each points at a RegexHead in the word array, followed by
// inst_count RInsts (3 words each). A class's ranges are sorted, merged,
// inclusive code point pairs elsewhere in the word array, with \p{Letter}
// already expanded, so the runtime needs no regex parser or Unicode table.
pub const RegexHead = extern struct { inst_count: u32, flags: u32 };
pub const R_ANCHORED: u32 = 1 << 0; // starts with ^ outside any group
pub const R_BOUNDARY: u32 = 1 << 1; // uses \b or \B

pub const RInst = extern struct { op: u32, a: u32 = 0, b: u32 = 0 };
pub const OP_CHAR: u32 = 0; // a = code point
pub const OP_ANY: u32 = 1; // any code point but a line terminator
pub const OP_CLASS: u32 = 2; // a = word index of ranges, b = range count | CLASS_NEGATED
pub const OP_SPLIT: u32 = 3; // a, b = targets, a preferred
pub const OP_JMP: u32 = 4; // a = target
pub const OP_BOL: u32 = 5;
pub const OP_EOL: u32 = 6;
pub const OP_WORD_BOUNDARY: u32 = 7;
pub const OP_NOT_WORD_BOUNDARY: u32 = 8;
pub const OP_MATCH: u32 = 9;
pub const CLASS_NEGATED: u32 = 1 << 31;

// One JSON value on a tape. Containers are followed by their contents in
// order (objects as key token then value tokens); `end` is the index just
// past the value, so a subtree is skipped in one step.
pub const Tok = extern struct {
    tag: u32,
    off: u32, // number text or decoded string, in the tape's byte base
    len: u32, // byte length, or child count for arrays and objects
    end: u32,
};

pub const TAG_NULL: u32 = 0;
pub const TAG_FALSE: u32 = 1;
pub const TAG_TRUE: u32 = 2;
pub const TAG_NUMBER: u32 = 3;
pub const TAG_STRING: u32 = 4;
pub const TAG_ARRAY: u32 = 5;
pub const TAG_OBJECT: u32 = 6;

comptime {
    for (.{ Header, Node, DynAnchor, Tok, Str, List, Bounds, Num, RegexHead, RInst }) |T| {
        std.debug.assert(@sizeOf(T) % 4 == 0);
        std.debug.assert(@alignOf(T) == 4);
    }
}

// Writes a compiled regex into the word array as RegexHead + RInsts + class
// ranges, and returns the word index of the head. Used by the compiler (and
// the runtime's tests); the runtime itself never calls it, so the regex
// parser and Unicode table stay out of generated modules.
const js = @import("json-schema-2020-12.zig");

pub fn appendRegex(alloc: std.mem.Allocator, scratch: std.mem.Allocator, words: *std.ArrayListUnmanaged(u32), r: js.Regex) js.Error!u32 {
    const head: u32 = @intCast(words.items.len);
    var flags: u32 = if (r.anchored) R_ANCHORED else 0;
    for (r.insts) |inst| {
        if (inst == .word_boundary or inst == .not_word_boundary) flags |= R_BOUNDARY;
    }
    try words.appendSlice(alloc, &@as([2]u32, @bitCast(RegexHead{ .inst_count = @intCast(r.insts.len), .flags = flags })));
    const insts_at = words.items.len;
    try words.appendNTimes(alloc, 0, r.insts.len * 3);
    for (r.insts, 0..) |inst, k| {
        const out: RInst = switch (inst) {
            .char => |cp| .{ .op = OP_CHAR, .a = cp },
            .any => .{ .op = OP_ANY },
            .class => |cl| blk: {
                const ranges = try classRanges(scratch, cl);
                const at: u32 = @intCast(words.items.len);
                for (ranges) |rg| try words.appendSlice(alloc, &.{ rg[0], rg[1] });
                break :blk .{ .op = OP_CLASS, .a = at, .b = @as(u32, @intCast(ranges.len)) | (if (cl.negated) CLASS_NEGATED else 0) };
            },
            .split => |t| .{ .op = OP_SPLIT, .a = t[0], .b = t[1] },
            .jmp => |t| .{ .op = OP_JMP, .a = t },
            .bol => .{ .op = OP_BOL },
            .eol => .{ .op = OP_EOL },
            .word_boundary => .{ .op = OP_WORD_BOUNDARY },
            .not_word_boundary => .{ .op = OP_NOT_WORD_BOUNDARY },
            .match => .{ .op = OP_MATCH },
        };
        @memcpy(words.items[insts_at + k * 3 ..][0..3], &@as([3]u32, @bitCast(out)));
    }
    return head;
}

// A class's code points as sorted, merged ranges, with \p{Letter} and
// \P{Letter} expanded. Negation stays a flag.
fn classRanges(alloc: std.mem.Allocator, cl: js.Class) js.Error![]const [2]u21 {
    var all: std.ArrayListUnmanaged([2]u21) = .empty;
    try all.appendSlice(alloc, cl.ranges);
    if (cl.letter or cl.not_letter) {
        const letters = try alloc.alloc([2]u21, js.unicode_letter.ranges.len);
        for (letters, 0..) |*r, k| r.* = js.unicode_letter.range(k);
        if (cl.letter) try all.appendSlice(alloc, letters);
        if (cl.not_letter) try all.appendSlice(alloc, try js.complement(alloc, letters));
    }
    std.mem.sort([2]u21, all.items, {}, struct {
        fn lt(_: void, x: [2]u21, y: [2]u21) bool {
            return x[0] < y[0];
        }
    }.lt);
    var n: usize = 0;
    for (all.items) |r| {
        if (n > 0 and @as(u32, r[0]) <= @as(u32, all.items[n - 1][1]) + 1) {
            all.items[n - 1][1] = @max(all.items[n - 1][1], r[1]);
        } else {
            all.items[n] = r;
            n += 1;
        }
    }
    return all.items[0..n];
}
