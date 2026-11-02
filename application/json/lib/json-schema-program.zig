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
//   properties, dependent_schemas          (key Str, node) as 3 words each
//   pattern_properties                     (regex, node) as 2 words each
//   enum_                                  value-token indices
//   required                               (key Str, properties entry or NONE)
//                                          as 3 words each
//   dependent_required                     (key Str, List of key Strs) as 4 words
// Strings (keys, number texts, regex sources) are Str ranges in the byte pool.
// Number keywords index the number array: each Num keeps the exact text and,
// when it has at most 18 digits and no exponent, the same value as an
// integer count of 10^-places for the fast path.
// const and enum values are stored as a token tape, the same Tok format the
// runtime parses the instance into, so one equality check serves both.
const std = @import("std");

pub const MAGIC = "qip.json-schema1".*;

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
    regexes_off: u32 = 0, // regex_count Strs, pattern sources
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
    for (.{ Header, Node, DynAnchor, Tok, Str, List, Bounds, Num }) |T| {
        std.debug.assert(@sizeOf(T) % 4 == 0);
        std.debug.assert(@alignOf(T) == 4);
    }
}
