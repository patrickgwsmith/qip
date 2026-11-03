//! i-regexp-to-wasm: compiles an I-Regexp (RFC 9485) into a QIP Content
//! component that accepts the text the pattern matches and rejects all other
//! text.
//!
//! Input is the pattern as UTF-8, for example `[a-z]{2,8}(-[a-z0-9]+)*`.
//! Output is a Wasm module. The generated component's `render` reads UTF-8
//! text and returns it unchanged when the pattern matches the whole text, as
//! I-Regexp specifies. Otherwise it rejects, and the failure detail is the
//! byte offset of the first code point that no match can continue through,
//! or the text length when the text ends before a match is complete. The
//! generated component has one failure mode per offset.
//!
//! The compiler checks the pattern against the RFC 9485 ABNF, including the
//! rule that `[^]` is not a class. Matching follows XSD semantics: `.` is any
//! code point except U+000A and U+000D, `^` and `$` are ordinary characters,
//! and `\p{..}` / `\P{..}` use the Unicode General Category tables in
//! text/lib/i-regexp-unicode-categories.zig (Unicode 17.0). `\P{C}` and
//! negated classes never match a surrogate, which UTF-8 cannot encode.
//!
//! How it works: the pattern becomes a Thompson NFA over UTF-8 bytes, subset
//! construction turns that NFA into a DFA over byte classes, and partition
//! refinement minimizes the DFA. The generated `render` takes one DFA step
//! per input byte, so its time is linear in the text. It stops at the first
//! byte after which no match is possible. There is no backtracking, so no
//! pattern can make matching slow. The generated module passes
//! wasm-strict-profile, wasm-bounded-loops and wasm-bounded-output. The
//! module does not record its source pattern: a recorded pattern could not
//! be trusted to describe what the module checks, and it would cost bytes.
//!
//! The DFA is emitted in one of two encodings. The table encoding stores a
//! 256-byte class map and a transition table in a data section, and each step
//! is two loads. The code encoding dispatches on the state with br_table and
//! picks the next state with compares and `select`, with no data section.
//! By default the compiler measures both modules with counting passes and
//! emits the smaller, with ties going to the table. The `prefer_table`
//! uniform (0 or 1, default 0) always emits the table, which costs the same
//! per byte for every pattern and is often faster, though not always.
//!
//! The cost moves to compile time. A DFA can need exponentially more states
//! than its pattern has characters, as in `(a|b)*a(a|b){20}`. Such patterns
//! are valid but rejected as too large. These limits apply: 64 levels of
//! group nesting, counted repetitions up to 100000, 200000 NFA states,
//! 30000 DFA states, and a 4 MiB transition table.
//!
//! Rejection detail is `offset * 2 + mode`. Offset is a byte offset in the
//! pattern. Mode 0 is a syntax error at that offset. Mode 1 means the pattern
//! is valid but exceeds a limit, with the offset of the count, group or
//! innermost repetition being expanded, or 0 when the DFA is too large.

const std = @import("std");
const ucd = @import("lib/i-regexp-unicode-categories.zig");

const INPUT_CAP: usize = 16 * 1024;
const TABLE_CAP: usize = 4 * 1024 * 1024;
// The generated module is the transition table plus at most a few hundred
// bytes of code, the class map and a copy of the pattern.
const OUTPUT_CAP: usize = TABLE_CAP + INPUT_CAP + 4096;
const ARENA_CAP: usize = 24 * 1024 * 1024;
const MAX_DEPTH: u32 = 64;
const MAX_COUNT: u32 = 100_000;
const MAX_NFA_STATES: usize = 200_000;
const MAX_DFA_STATES: usize = 30_000;
const TRANS_CAP: usize = 1024 * 1024;
const PAIR_CAP: usize = 1024 * 1024;
// Closure, move and refinement steps; past this the DFA is too large to build.
const WORK_CAP: u64 = 200_000_000;

const OUTPUT_CONTENT_TYPE = "application/wasm";

// Generated component memory: the class map at 0, the transition table at
// TABLE_PTR, then the input region on the next page boundary.
const RUN_INPUT_CAP: u32 = 4 * 1024 * 1024;
const RUN_MAP_PTR: u32 = 0;
const RUN_TABLE_PTR: u32 = 512;
const PAGE: u32 = 64 * 1024;
// The code encoding nests one block per state; above this many states it is
// never considered, as the table is smaller by then anyway.
const MAX_CODE_STATES: u32 = 4096;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var arena_buf: [ARENA_CAP]u8 = undefined;
var trans_buf: [TRANS_CAP]u32 = undefined;
var pair_buf: [PAIR_CAP]u32 = undefined;
var nfa_mark: [MAX_NFA_STATES]u32 = undefined;
var nfa_stack: [MAX_NFA_STATES]u32 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const Failure = enum(u32) { syntax = 0, too_large = 1 };
const FAILURE_MODES: u32 = 2;

const CompileError = error{Rejected};

var fail_offset: u32 = 0;
var fail_mode: Failure = .syntax;

fn fail(offset: usize, mode: Failure) CompileError {
    fail_offset = @intCast(offset);
    fail_mode = mode;
    return error.Rejected;
}

var arena: std.heap.FixedBufferAllocator = undefined;
var work: u64 = 0;

fn alloc() std.mem.Allocator {
    return arena.allocator();
}

fn spend(steps: u64) CompileError!void {
    work += steps;
    if (work > WORK_CAP) return fail(0, .too_large);
}

fn oom() CompileError {
    return fail(0, .too_large);
}

// ---------------------------------------------------------------------------
// Code point sets: sorted, disjoint, non-adjacent inclusive ranges that never
// contain a surrogate.

const Range = struct { lo: u21, hi: u21 };

const MAX_SCALAR: u21 = 0x10FFFF;

fn lessRange(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

// Sorts and merges `ranges` in place, removes surrogates, and returns the set.
fn normalize(ranges: []Range) CompileError![]const Range {
    std.mem.sort(Range, ranges, {}, lessRange);
    var out: std.ArrayList(Range) = .empty;
    for (ranges) |r| {
        if (out.items.len > 0 and r.lo <= @as(u32, out.items[out.items.len - 1].hi) + 1) {
            const last = &out.items[out.items.len - 1];
            last.hi = @max(last.hi, r.hi);
        } else {
            out.append(alloc(), r) catch return oom();
        }
    }
    // Split around the surrogate block D800-DFFF.
    var result: std.ArrayList(Range) = .empty;
    for (out.items) |r| {
        if (r.hi < 0xD800 or r.lo > 0xDFFF) {
            result.append(alloc(), r) catch return oom();
            continue;
        }
        if (r.lo < 0xD800) result.append(alloc(), .{ .lo = r.lo, .hi = 0xD7FF }) catch return oom();
        if (r.hi > 0xDFFF) result.append(alloc(), .{ .lo = 0xE000, .hi = r.hi }) catch return oom();
    }
    return result.items;
}

// Every scalar value not in the normalized set `set`.
fn complement(set: []const Range) CompileError![]const Range {
    var out: std.ArrayList(Range) = .empty;
    var next: u32 = 0;
    for (set) |r| {
        if (r.lo > next) out.append(alloc(), .{ .lo = @intCast(next), .hi = r.lo - 1 }) catch return oom();
        next = @as(u32, r.hi) + 1;
    }
    if (next <= MAX_SCALAR) out.append(alloc(), .{ .lo = @intCast(next), .hi = MAX_SCALAR }) catch return oom();
    return normalize(out.items);
}

fn categorySet(mask: u32) CompileError![]const Range {
    var out: std.ArrayList(Range) = .empty;
    for (ucd.runs, 0..) |run, i| {
        if (mask & (@as(u32, 1) << @intCast(run & 31)) == 0) continue;
        const lo: u21 = @intCast(run >> 5);
        const hi: u21 = if (i + 1 < ucd.runs.len) @intCast((ucd.runs[i + 1] >> 5) - 1) else MAX_SCALAR;
        out.append(alloc(), .{ .lo = lo, .hi = hi }) catch return oom();
    }
    return normalize(out.items);
}

fn catBit(c: ucd.Category) u32 {
    return @as(u32, 1) << @intFromEnum(c);
}

// The category mask named by `major` and an optional `minor` letter, or null
// when the grammar does not allow the name.
fn categoryMask(major: u21, minor: ?u21) ?u32 {
    const C = ucd.Category;
    const groups = [_]struct { major: u8, minors: []const u8, cats: []const C }{
        .{ .major = 'L', .minors = "ultmo", .cats = &.{ .lu, .ll, .lt, .lm, .lo } },
        .{ .major = 'M', .minors = "nce", .cats = &.{ .mn, .mc, .me } },
        .{ .major = 'N', .minors = "dlo", .cats = &.{ .nd, .nl, .no } },
        .{ .major = 'P', .minors = "cdseifo", .cats = &.{ .pc, .pd, .ps, .pe, .pi, .pf, .po } },
        .{ .major = 'Z', .minors = "slp", .cats = &.{ .zs, .zl, .zp } },
        .{ .major = 'S', .minors = "mcko", .cats = &.{ .sm, .sc, .sk, .so } },
        .{ .major = 'C', .minors = "cfon", .cats = &.{ .cc, .cf, .co, .cn } },
    };
    for (groups) |g| {
        if (major != g.major) continue;
        var mask: u32 = 0;
        for (g.minors, g.cats) |m, c| {
            if (minor == null or minor.? == m) mask |= catBit(c);
        }
        return if (mask == 0) null else mask;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Parser: RFC 9485 Figure 1, producing a syntax tree.

const Node = union(enum) {
    set: []const Range,
    cat: []const *const Node,
    alt: []const *const Node,
    repeat: struct { child: *const Node, min: u32, max: ?u32, offset: u32 },
    group: struct { child: *const Node, offset: u32 },
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    const Decoded = struct { cp: u21, len: u3 };

    fn decode(p: *Parser, at: usize) CompileError!?Decoded {
        if (at >= p.src.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(p.src[at]) catch return fail(at, .syntax);
        if (at + len > p.src.len) return fail(at, .syntax);
        const cp = std.unicode.utf8Decode(p.src[at .. at + len]) catch return fail(at, .syntax);
        return .{ .cp = cp, .len = len };
    }

    fn peek(p: *Parser) CompileError!?u21 {
        const d = try p.decode(p.pos) orelse return null;
        return d.cp;
    }

    fn peekAt(p: *Parser, ahead: usize) CompileError!?u21 {
        var at = p.pos;
        for (0..ahead) |_| {
            const d = try p.decode(at) orelse return null;
            at += d.len;
        }
        const d = try p.decode(at) orelse return null;
        return d.cp;
    }

    fn advance(p: *Parser) CompileError!u21 {
        const d = try p.decode(p.pos) orelse return fail(p.pos, .syntax);
        p.pos += d.len;
        return d.cp;
    }

    fn expect(p: *Parser, c: u21) CompileError!void {
        if (try p.peek() != c) return fail(p.pos, .syntax);
        p.pos += 1;
    }

    fn newNode(n: Node) CompileError!*const Node {
        const node = alloc().create(Node) catch return oom();
        node.* = n;
        return node;
    }

    fn single(cp: u21) CompileError!*const Node {
        const r = alloc().alloc(Range, 1) catch return oom();
        r[0] = .{ .lo = cp, .hi = cp };
        return newNode(.{ .set = r });
    }

    fn parseAlt(p: *Parser, depth: u32) CompileError!*const Node {
        var branches: std.ArrayList(*const Node) = .empty;
        while (true) {
            branches.append(alloc(), try p.parseBranch(depth)) catch return oom();
            if (try p.peek() != '|') break;
            p.pos += 1;
        }
        if (branches.items.len == 1) return branches.items[0];
        return newNode(.{ .alt = branches.items });
    }

    fn parseBranch(p: *Parser, depth: u32) CompileError!*const Node {
        var pieces: std.ArrayList(*const Node) = .empty;
        while (try p.peek()) |c| {
            if (c == '|' or c == ')') break;
            pieces.append(alloc(), try p.parsePiece(depth)) catch return oom();
        }
        if (pieces.items.len == 1) return pieces.items[0];
        return newNode(.{ .cat = pieces.items });
    }

    fn parseCount(p: *Parser) CompileError!u32 {
        const start = p.pos;
        var value: u32 = 0;
        while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') : (p.pos += 1) {
            value = @min(value * 10 + (p.src[p.pos] - '0'), MAX_COUNT + 1);
        }
        if (p.pos == start) return fail(p.pos, .syntax);
        if (value > MAX_COUNT) return fail(start, .too_large);
        return value;
    }

    fn parsePiece(p: *Parser, depth: u32) CompileError!*const Node {
        const atom = try p.parseAtom(depth);
        const offset: u32 = @intCast(p.pos);
        const c = try p.peek() orelse return atom;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (c) {
            '*' => p.pos += 1,
            '+' => {
                p.pos += 1;
                min = 1;
            },
            '?' => {
                p.pos += 1;
                max = 1;
            },
            '{' => {
                p.pos += 1;
                min = try p.parseCount();
                max = min;
                if (try p.peek() == ',') {
                    p.pos += 1;
                    max = null;
                    if (try p.peek() != '}') {
                        const at = p.pos;
                        const m = try p.parseCount();
                        if (m < min) return fail(at, .syntax);
                        max = m;
                    }
                }
                try p.expect('}');
            },
            else => return atom,
        }
        return newNode(.{ .repeat = .{ .child = atom, .min = min, .max = max, .offset = offset } });
    }

    fn isNormalChar(c: u21) bool {
        return switch (c) {
            '(', ')', '*', '+', '.', '?', '[', '\\', ']', '{', '|', '}' => false,
            else => true,
        };
    }

    fn parseAtom(p: *Parser, depth: u32) CompileError!*const Node {
        const start = p.pos;
        const c = try p.advance();
        switch (c) {
            '(' => {
                if (depth >= MAX_DEPTH) return fail(start, .too_large);
                const inner = try p.parseAlt(depth + 1);
                try p.expect(')');
                return newNode(.{ .group = .{ .child = inner, .offset = @intCast(start) } });
            },
            '.' => {
                var r = [_]Range{ .{ .lo = 0, .hi = 0x09 }, .{ .lo = 0x0B, .hi = 0x0C }, .{ .lo = 0x0E, .hi = MAX_SCALAR } };
                return newNode(.{ .set = try normalize(&r) });
            },
            '\\' => {
                p.pos = start;
                return switch (try p.parseEscape()) {
                    .char => |cp| single(cp),
                    .set => |s| newNode(.{ .set = s }),
                };
            },
            '[' => {
                p.pos = start;
                return newNode(.{ .set = try p.parseClassExpr() });
            },
            else => {
                if (!isNormalChar(c)) return fail(start, .syntax);
                return single(c);
            },
        }
    }

    const Escape = union(enum) { char: u21, set: []const Range };

    // SingleCharEsc or charClassEsc, starting at the backslash.
    fn parseEscape(p: *Parser) CompileError!Escape {
        const start = p.pos;
        try p.expect('\\');
        const c = try p.peek() orelse return fail(start, .syntax);
        switch (c) {
            '(', ')', '*', '+', '-', '.', '?', '[', '\\', ']', '^', '{', '|', '}' => {
                p.pos += 1;
                return .{ .char = c };
            },
            'n' => {
                p.pos += 1;
                return .{ .char = '\n' };
            },
            'r' => {
                p.pos += 1;
                return .{ .char = '\r' };
            },
            't' => {
                p.pos += 1;
                return .{ .char = '\t' };
            },
            'p', 'P' => {
                p.pos += 1;
                try p.expect('{');
                const name_at = p.pos;
                const major = try p.advance();
                var minor: ?u21 = null;
                if (try p.peek() != '}') minor = try p.advance();
                const mask = categoryMask(major, minor) orelse return fail(name_at, .syntax);
                try p.expect('}');
                const set = try categorySet(mask);
                return .{ .set = if (c == 'P') try complement(set) else set };
            },
            else => return fail(start, .syntax),
        }
    }

    // CCchar: a class character or a SingleCharEsc, for one end of a range.
    fn parseClassChar(p: *Parser) CompileError!u21 {
        const start = p.pos;
        const c = try p.peek() orelse return fail(start, .syntax);
        switch (c) {
            '-', '[', ']' => return fail(start, .syntax),
            '\\' => return switch (try p.parseEscape()) {
                .char => |cp| cp,
                .set => fail(start, .syntax),
            },
            else => return p.advance(),
        }
    }

    // charClassExpr = "[" [ "^" ] ( "-" / CCE1 ) *CCE1 [ "-" ] "]"
    fn parseClassExpr(p: *Parser) CompileError![]const Range {
        try p.expect('[');
        var negate = false;
        if (try p.peek() == '^') {
            p.pos += 1;
            negate = true;
        }
        var ranges: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            const c = try p.peek() orelse return fail(p.pos, .syntax);
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            if (c == '-') {
                // A leading "-" or a trailing "-" just before "]".
                if (!first and try p.peekAt(1) != ']') return fail(p.pos, .syntax);
                p.pos += 1;
                ranges.append(alloc(), .{ .lo = '-', .hi = '-' }) catch return oom();
                first = false;
                continue;
            }
            first = false;
            if (c == '\\') {
                const n = try p.peekAt(1);
                if (n == 'p' or n == 'P') {
                    const set = (try p.parseEscape()).set;
                    ranges.appendSlice(alloc(), set) catch return oom();
                    continue;
                }
            }
            const lo = try p.parseClassChar();
            var hi = lo;
            if (try p.peek() == '-' and try p.peekAt(1) != ']') {
                p.pos += 1;
                const at = p.pos;
                hi = try p.parseClassChar();
                if (hi < lo) return fail(at, .syntax);
            }
            ranges.append(alloc(), .{ .lo = lo, .hi = hi }) catch return oom();
        }
        const set = try normalize(ranges.items);
        return if (negate) complement(set) else set;
    }
};

fn parse(src: []const u8) CompileError!*const Node {
    var p = Parser{ .src = src };
    const node = try p.parseAlt(0);
    if (p.pos != src.len) return fail(p.pos, .syntax);
    return node;
}

// ---------------------------------------------------------------------------
// NFA over bytes. Fork states have any number of epsilon targets; a fork with
// none is a state that matches nothing.

const NState = struct {
    kind: enum(u8) { byte, fork, match },
    lo: u8 = 0,
    hi: u8 = 0,
    next: u32 = 0,
    targets: []const u32 = &.{},
};

var nfa: std.ArrayList(NState) = .empty;
var byte_bounds: [257]bool = undefined;

fn addState(s: NState, offset: u32) CompileError!u32 {
    if (nfa.items.len >= MAX_NFA_STATES) return fail(offset, .too_large);
    nfa.append(alloc(), s) catch return fail(offset, .too_large);
    return @intCast(nfa.items.len - 1);
}

fn fork(targets: []const u32, offset: u32) CompileError!u32 {
    if (targets.len == 1) return targets[0];
    const t = alloc().dupe(u32, targets) catch return fail(offset, .too_large);
    return addState(.{ .kind = .fork, .targets = t }, offset);
}

fn encodeUtf8(cp: u21, out: *[4]u8) u3 {
    return std.unicode.utf8Encode(cp, out) catch unreachable;
}

const utf8_max = [_]u21{ 0x7F, 0x7FF, 0xFFFF, MAX_SCALAR };

// Appends to `entries` one byte chain per UTF-8 byte-range sequence of
// [lo, hi], each ending at `out`. This splits ranges the way
// regex-syntax's Utf8Sequences does, so every chain is a product of byte
// ranges that encodes exactly a subrange of [lo, hi].
fn utf8Chains(r: Range, out: u32, entries: *std.ArrayList(u32), offset: u32) CompileError!void {
    var stack: [64]Range = undefined;
    var sp: usize = 1;
    stack[0] = r;
    outer: while (sp > 0) {
        sp -= 1;
        const lo: u32 = stack[sp].lo;
        const hi: u32 = stack[sp].hi;
        // Split where the encoded length changes.
        for (utf8_max[0..3]) |m| {
            if (lo <= m and hi > m) {
                stack[sp] = .{ .lo = @intCast(m + 1), .hi = @intCast(hi) };
                stack[sp + 1] = .{ .lo = @intCast(lo), .hi = m };
                sp += 2;
                continue :outer;
            }
        }
        const len: u5 = if (hi <= 0x7F) 1 else if (hi <= 0x7FF) 2 else if (hi <= 0xFFFF) 3 else 4;
        var i: u5 = 1;
        while (i < len) : (i += 1) {
            const m: u32 = (@as(u32, 1) << (6 * i)) - 1;
            if (lo & ~m != hi & ~m) {
                if (lo & m != 0) {
                    stack[sp] = .{ .lo = @intCast((lo | m) + 1), .hi = @intCast(hi) };
                    stack[sp + 1] = .{ .lo = @intCast(lo), .hi = @intCast(lo | m) };
                    sp += 2;
                    continue :outer;
                }
                if (hi & m != m) {
                    stack[sp] = .{ .lo = @intCast(hi & ~m), .hi = @intCast(hi) };
                    stack[sp + 1] = .{ .lo = @intCast(lo), .hi = @intCast((hi & ~m) - 1) };
                    sp += 2;
                    continue :outer;
                }
            }
        }
        var a: [4]u8 = undefined;
        var b: [4]u8 = undefined;
        const n = encodeUtf8(@intCast(lo), &a);
        _ = encodeUtf8(@intCast(hi), &b);
        var next = out;
        var k: usize = n;
        while (k > 0) {
            k -= 1;
            byte_bounds[a[k]] = true;
            byte_bounds[@as(usize, b[k]) + 1] = true;
            next = try addState(.{ .kind = .byte, .lo = a[k], .hi = b[k], .next = next }, offset);
        }
        entries.append(alloc(), next) catch return fail(offset, .too_large);
    }
}

// Builds `node` so that a match continues at `out`, and returns its entry.
fn build(node: *const Node, out: u32, offset: u32) CompileError!u32 {
    switch (node.*) {
        .set => |set| {
            var entries: std.ArrayList(u32) = .empty;
            for (set) |r| try utf8Chains(r, out, &entries, offset);
            return fork(entries.items, offset);
        },
        .cat => |items| {
            var s = out;
            var i = items.len;
            while (i > 0) {
                i -= 1;
                s = try build(items[i], s, offset);
            }
            return s;
        },
        .alt => |items| {
            const entries = alloc().alloc(u32, items.len) catch return fail(offset, .too_large);
            for (items, entries) |item, *e| e.* = try build(item, out, offset);
            return fork(entries, offset);
        },
        .group => |g| return build(g.child, out, g.offset),
        .repeat => |r| {
            var s = out;
            if (r.max) |max| {
                for (0..max - r.min) |_| {
                    const e = try build(r.child, s, r.offset);
                    s = try addState(.{ .kind = .fork, .targets = try pair(e, out, r.offset) }, r.offset);
                }
            } else {
                const loop = try addState(.{ .kind = .fork }, r.offset);
                const e = try build(r.child, loop, r.offset);
                nfa.items[loop].targets = try pair(e, out, r.offset);
                s = loop;
            }
            for (0..r.min) |_| s = try build(r.child, s, r.offset);
            return s;
        },
    }
}

fn pair(a: u32, b: u32, offset: u32) CompileError![]const u32 {
    const t = alloc().alloc(u32, 2) catch return fail(offset, .too_large);
    t[0] = a;
    t[1] = b;
    return t;
}

// ---------------------------------------------------------------------------
// Subset construction over byte classes.

var class_of: [256]u8 = undefined;
var class_count: u32 = 0;
var class_rep: [256]u8 = undefined;

fn computeClasses() void {
    class_count = 0;
    var c: u32 = 0;
    while (c < 256) : (c += 1) {
        if (c > 0 and byte_bounds[c]) class_count += 1;
        class_of[c] = @intCast(class_count);
        if (c == 0 or byte_bounds[c]) class_rep[class_count] = @intCast(c);
    }
    class_count += 1;
}

const SetContext = struct {
    pub fn hash(_: SetContext, key: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }
    pub fn eql(_: SetContext, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

const Dfa = struct {
    count: u32,
    accept: []bool,
    trans: []u32, // count * class_count
    start: u32,
};

var mark_gen: u32 = 0;

// Sorted byte and match states reachable from `seeds` by epsilon moves,
// written to `out`. Returns the count.
fn closure(seeds: []const u32, out: *std.ArrayList(u32)) CompileError!void {
    out.clearRetainingCapacity();
    mark_gen += 1;
    var sp: usize = 0;
    for (seeds) |s| {
        if (nfa_mark[s] == mark_gen) continue;
        nfa_mark[s] = mark_gen;
        nfa_stack[sp] = s;
        sp += 1;
    }
    var steps: u64 = 0;
    while (sp > 0) {
        sp -= 1;
        const s = nfa_stack[sp];
        steps += 1;
        const st = nfa.items[s];
        if (st.kind == .fork) {
            for (st.targets) |t| {
                if (nfa_mark[t] == mark_gen) continue;
                nfa_mark[t] = mark_gen;
                nfa_stack[sp] = t;
                sp += 1;
            }
        } else {
            out.append(alloc(), s) catch return oom();
        }
    }
    try spend(steps);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
}

fn determinize(start_nfa: u32) CompileError!Dfa {
    var map: std.HashMapUnmanaged([]const u32, u32, SetContext, 80) = .empty;
    map.ensureTotalCapacityContext(alloc(), MAX_DFA_STATES + 1, .{}) catch return oom();
    var sets: std.ArrayList([]const u32) = .empty;
    sets.ensureTotalCapacity(alloc(), MAX_DFA_STATES) catch return oom();

    // State 0 is the empty set: no match is possible.
    sets.appendAssumeCapacity(&.{});
    map.putAssumeCapacityContext(&.{}, 0, .{});

    var scratch: std.ArrayList(u32) = .empty;
    try closure(&.{start_nfa}, &scratch);
    const start = try intern(&map, &sets, scratch.items);

    var counts: [257]u32 = undefined;
    var d: usize = 0;
    while (d < sets.items.len) : (d += 1) {
        const row = d * class_count;
        if (row + class_count > TRANS_CAP) return fail(0, .too_large);
        const set = sets.items[d];
        // Bucket each byte state's successor by the classes its range covers.
        @memset(counts[0 .. class_count + 1], 0);
        var total: usize = 0;
        for (set) |s| {
            const st = nfa.items[s];
            if (st.kind != .byte) continue;
            for (@as(usize, class_of[st.lo])..@as(usize, class_of[st.hi]) + 1) |c| counts[c + 1] += 1;
            total += @as(usize, class_of[st.hi]) - class_of[st.lo] + 1;
        }
        if (total > PAIR_CAP) return fail(0, .too_large);
        try spend(set.len + total);
        for (1..class_count + 1) |c| counts[c] += counts[c - 1];
        var fill: [256]u32 = undefined;
        @memcpy(fill[0..class_count], counts[0..class_count]);
        for (set) |s| {
            const st = nfa.items[s];
            if (st.kind != .byte) continue;
            for (@as(usize, class_of[st.lo])..@as(usize, class_of[st.hi]) + 1) |c| {
                pair_buf[fill[c]] = st.next;
                fill[c] += 1;
            }
        }
        for (0..class_count) |c| {
            const seeds = pair_buf[counts[c]..counts[c + 1]];
            if (seeds.len == 0) {
                trans_buf[row + c] = 0;
                continue;
            }
            try closure(seeds, &scratch);
            trans_buf[row + c] = try intern(&map, &sets, scratch.items);
        }
    }

    const count: u32 = @intCast(sets.items.len);
    const accept = alloc().alloc(bool, count) catch return oom();
    const match_state: u32 = 0; // the NFA's first state is the match state
    for (sets.items, accept) |set, *a| {
        a.* = set.len > 0 and set[0] == match_state;
    }
    return .{ .count = count, .accept = accept, .trans = trans_buf[0 .. count * class_count], .start = start };
}

fn intern(
    map: *std.HashMapUnmanaged([]const u32, u32, SetContext, 80),
    sets: *std.ArrayList([]const u32),
    set: []const u32,
) CompileError!u32 {
    if (map.getContext(set, .{})) |id| return id;
    if (sets.items.len >= MAX_DFA_STATES) return fail(0, .too_large);
    const owned = alloc().dupe(u32, set) catch return oom();
    const id: u32 = @intCast(sets.items.len);
    sets.appendAssumeCapacity(owned);
    map.putAssumeCapacityContext(owned, id, .{});
    return id;
}

// ---------------------------------------------------------------------------
// Minimization by partition refinement (Moore). Each round splits blocks by
// the blocks of their successors until no block splits.

const SigContext = struct {
    block: []const u32,
    trans: []const u32,
    width: u32,

    pub fn hash(ctx: SigContext, s: u32) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&ctx.block[s]));
        for (ctx.trans[s * ctx.width ..][0..ctx.width]) |t| h.update(std.mem.asBytes(&ctx.block[t]));
        return h.final();
    }

    pub fn eql(ctx: SigContext, a: u32, b: u32) bool {
        if (ctx.block[a] != ctx.block[b]) return false;
        const ta = ctx.trans[a * ctx.width ..][0..ctx.width];
        const tb = ctx.trans[b * ctx.width ..][0..ctx.width];
        for (ta, tb) |x, y| if (ctx.block[x] != ctx.block[y]) return false;
        return true;
    }
};

// Returns the block of each state, numbered by first appearance in state
// order, or null when refinement would exceed the work budget.
fn minimize(dfa: Dfa) CompileError!?struct { block: []u32, count: u32 } {
    const n = dfa.count;
    var block = alloc().alloc(u32, n) catch return oom();
    var next = alloc().alloc(u32, n) catch return oom();
    // Initial partition: rejecting states, then accepting ones.
    var blocks: u32 = 0;
    var seen = [2]?u32{ null, null };
    for (0..n) |s| {
        const k = @intFromBool(dfa.accept[s]);
        if (seen[k] == null) {
            seen[k] = blocks;
            blocks += 1;
        }
        block[s] = seen[k].?;
    }
    var map: std.HashMapUnmanaged(u32, u32, SigContext, 80) = .empty;
    map.ensureTotalCapacityContext(alloc(), n, .{ .block = block, .trans = dfa.trans, .width = class_count }) catch return oom();
    while (true) {
        const round_cost = @as(u64, n) * (class_count + 1);
        if (work + round_cost > WORK_CAP) return null;
        work += round_cost;
        const ctx = SigContext{ .block = block, .trans = dfa.trans, .width = class_count };
        map.clearRetainingCapacity();
        var new_blocks: u32 = 0;
        for (0..n) |s| {
            const gop = map.getOrPutAssumeCapacityContext(@intCast(s), ctx);
            if (!gop.found_existing) {
                gop.value_ptr.* = new_blocks;
                new_blocks += 1;
            }
            next[s] = gop.value_ptr.*;
        }
        std.mem.swap([]u32, &block, &next);
        if (new_blocks == blocks) break;
        blocks = new_blocks;
    }
    return .{ .block = block, .count = blocks };
}

// ---------------------------------------------------------------------------
// The final DFA: state 0 is dead, rejecting states follow, accepting states
// come last, and byte classes with identical columns are merged.

const Final = struct {
    states: u32,
    classes: u32,
    accept_from: u32,
    start: u32,
    map: [256]u8,
    trans: []u32, // states * classes, next state indices
};

fn finalize(dfa: Dfa) CompileError!Final {
    var block: []u32 = undefined;
    var blocks: u32 = undefined;
    if (try minimize(dfa)) |m| {
        block = m.block;
        blocks = m.count;
    } else {
        block = alloc().alloc(u32, dfa.count) catch return oom();
        for (block, 0..) |*b, i| b.* = @intCast(i);
        blocks = dfa.count;
    }
    // Representative state of each block, and its order: dead first.
    const rep = alloc().alloc(u32, blocks) catch return oom();
    const have = alloc().alloc(bool, blocks) catch return oom();
    @memset(have, false);
    for (0..dfa.count) |s| {
        if (!have[block[s]]) {
            have[block[s]] = true;
            rep[block[s]] = @intCast(s);
        }
    }
    const order = alloc().alloc(u32, blocks) catch return oom();
    const index = alloc().alloc(u32, blocks) catch return oom();
    var k: u32 = 0;
    order[k] = block[0];
    k += 1;
    for (0..2) |pass| {
        for (0..blocks) |b| {
            if (b == block[0]) continue;
            if (dfa.accept[rep[b]] != (pass == 1)) continue;
            order[k] = @intCast(b);
            k += 1;
        }
    }
    var accept_from: u32 = blocks;
    for (order, 0..) |b, i| {
        index[b] = @intCast(i);
        if (dfa.accept[rep[b]] and accept_from == blocks) accept_from = @intCast(i);
    }

    // Merge byte classes whose columns agree.
    var merged: [256]u8 = undefined;
    var column_of: [256]u32 = undefined;
    var classes: u32 = 0;
    for (0..class_count) |c| {
        var found: ?u32 = null;
        for (0..classes) |m| {
            const other = column_of[m];
            var same = true;
            for (order) |b| {
                const row = rep[b] * class_count;
                if (block[dfa.trans[row + c]] != block[dfa.trans[row + other]]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                found = @intCast(m);
                break;
            }
        }
        try spend(@as(u64, blocks) * classes);
        if (found) |m| {
            merged[c] = @intCast(m);
        } else {
            column_of[classes] = @intCast(c);
            merged[c] = @intCast(classes);
            classes += 1;
        }
    }

    if (@as(u64, blocks) * classes > TRANS_CAP) return fail(0, .too_large);
    const trans = alloc().alloc(u32, blocks * classes) catch return oom();
    for (order, 0..) |b, i| {
        const row = rep[b] * class_count;
        for (0..classes) |m| {
            trans[i * classes + m] = index[block[dfa.trans[row + column_of[m]]]];
        }
    }
    var map: [256]u8 = undefined;
    for (0..256) |byte| map[byte] = merged[class_of[byte]];
    return .{
        .states = blocks,
        .classes = classes,
        .accept_from = accept_from,
        .start = index[block[dfa.start]],
        .map = map,
        .trans = trans,
    };
}

// ---------------------------------------------------------------------------
// Module assembly

// With `counting` set, a Buf writes nothing and only advances `len`, so the
// emitters can measure a module's exact size before writing it.
const Buf = struct {
    bytes: []u8,
    len: usize = 0,
    counting: bool = false,

    fn byte(self: *Buf, b: u8) CompileError!void {
        if (self.counting) {
            self.len += 1;
            return;
        }
        if (self.len >= self.bytes.len) return fail(0, .too_large);
        self.bytes[self.len] = b;
        self.len += 1;
    }

    fn raw(self: *Buf, data: []const u8) CompileError!void {
        if (self.counting) {
            self.len += data.len;
            return;
        }
        if (self.len + data.len > self.bytes.len) return fail(0, .too_large);
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn uleb(self: *Buf, value_in: u64) CompileError!void {
        var value = value_in;
        while (true) {
            const b: u8 = @truncate(value & 0x7f);
            value >>= 7;
            if (value == 0) return self.byte(b);
            try self.byte(b | 0x80);
        }
    }

    fn sleb(self: *Buf, value_in: i64) CompileError!void {
        var value = value_in;
        while (true) {
            const b: u8 = @truncate(@as(u64, @bitCast(value)) & 0x7f);
            value >>= 7;
            const done = (value == 0 and b & 0x40 == 0) or (value == -1 and b & 0x40 != 0);
            if (done) return self.byte(b);
            try self.byte(b | 0x80);
        }
    }

    fn name(self: *Buf, s: []const u8) CompileError!void {
        try self.uleb(s.len);
        try self.raw(s);
    }

    fn i32Const(self: *Buf, v: u32) CompileError!void {
        try self.byte(0x41);
        try self.sleb(@as(i32, @bitCast(v)));
    }

    // A 5-byte padded size placeholder, patched by endSize.
    fn beginSize(self: *Buf) CompileError!usize {
        const at = self.len;
        try self.raw(&.{ 0x80, 0x80, 0x80, 0x80, 0x00 });
        return at;
    }

    fn endSize(self: *Buf, at: usize) void {
        if (self.counting) return;
        var size: u32 = @intCast(self.len - at - 5);
        for (0..5) |i| {
            const b: u8 = @truncate(size & 0x7f);
            size >>= 7;
            self.bytes[at + i] = if (i < 4) b | 0x80 else b;
        }
    }

    fn load(self: *Buf, op: u8, align_log2: u8, offset: u32) CompileError!void {
        try self.byte(op);
        try self.byte(align_log2);
        try self.uleb(offset);
    }
};

const OP_LOAD8_U: u8 = 0x2d;
const OP_LOAD16_U: u8 = 0x2f;
const OP_LOAD32: u8 = 0x28;

fn emitGetter(w: *Buf, value: u32) CompileError!void {
    const at = try w.beginSize();
    try w.byte(0);
    try w.i32Const(value);
    try w.byte(0x0b);
    w.endSize(at);
}

const Encoding = enum { table, code };

// The table layout: entry width, row size, and where the input region starts.
const TableLayout = struct {
    width: u32,
    row_size: u32,
    table_size: u32,
    wide_map: bool,
    run_input_ptr: u32,
};

fn tableLayout(f: Final) CompileError!TableLayout {
    // Entry width: rows are stored premultiplied as byte offsets into the
    // table, so the loop adds the class offset and loads the next row.
    const row_bytes_1 = @as(u64, f.classes);
    const width: u32 = if ((f.states - 1) * row_bytes_1 <= 0xFF) 1 else if ((f.states - 1) * row_bytes_1 * 2 <= 0xFFFF) 2 else 4;
    const row_size: u32 = f.classes * width;
    const table_size: u32 = f.states * row_size;
    if (table_size > TABLE_CAP) return fail(0, .too_large);
    return .{
        .width = width,
        .row_size = row_size,
        .table_size = table_size,
        // The class map holds class * width; u8 entries when they fit.
        .wide_map = (f.classes - 1) * width > 0xFF,
        .run_input_ptr = std.mem.alignForward(u32, RUN_TABLE_PTR + table_size, PAGE),
    };
}

// Picks the encoding to emit. With prefer_table set it is always the table.
// Otherwise both modules are measured with counting passes and the smaller
// one wins, with ties going to the table.
fn chooseEncoding(f: Final, table_only: bool) CompileError!Encoding {
    if (table_only or f.states > MAX_CODE_STATES) return .table;
    var table = Buf{ .bytes = &.{}, .counting = true };
    try emitModule(&table, f, .table);
    try spend(@as(u64, f.states) * 256);
    var code = Buf{ .bytes = &.{}, .counting = true };
    try emitModule(&code, f, .code);
    return if (code.len < table.len) .code else .table;
}

fn emitModule(w: *Buf, f: Final, encoding: Encoding) CompileError!void {
    const layout = try tableLayout(f);
    // The code encoding has no data, so its input starts at address 0.
    const run_input_ptr = if (encoding == .table) layout.run_input_ptr else 0;
    const pages = (run_input_ptr + RUN_INPUT_CAP) / PAGE;

    try w.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    try w.byte(1); // type section
    var at = try w.beginSize();
    try w.raw(&.{ 2, 0x60, 0, 1, 0x7f, 0x60, 1, 0x7f, 1, 0x7e });
    w.endSize(at);

    try w.byte(3); // function section
    at = try w.beginSize();
    try w.raw(&.{ 5, 0, 0, 0, 0, 1 });
    w.endSize(at);

    try w.byte(5); // memory section: fixed size
    at = try w.beginSize();
    try w.raw(&.{ 1, 1 });
    try w.uleb(pages);
    try w.uleb(pages);
    w.endSize(at);

    try w.byte(7); // export section
    at = try w.beginSize();
    try w.uleb(6);
    try w.name("memory");
    try w.raw(&.{ 2, 0 });
    const exports = [_][]const u8{ "input_ptr", "input_utf8_cap", "output_utf8_cap", "failure_modes_per_input_offset", "render" };
    for (exports, 0..) |e, i| {
        try w.name(e);
        try w.byte(0);
        try w.uleb(i);
    }
    w.endSize(at);

    try w.byte(10); // code section
    at = try w.beginSize();
    try w.uleb(5);
    try emitGetter(w, run_input_ptr);
    try emitGetter(w, RUN_INPUT_CAP);
    try emitGetter(w, RUN_INPUT_CAP);
    try emitGetter(w, 1);
    switch (encoding) {
        .table => try emitTableRender(w, f, layout),
        .code => try emitCodeRender(w, f),
    }
    w.endSize(at);

    if (encoding == .table) {
        try w.byte(11); // data section: class map and transition table
        at = try w.beginSize();
        try w.raw(&.{ 1, 0 });
        try w.i32Const(RUN_MAP_PTR);
        try w.byte(0x0b);
        try w.uleb(RUN_TABLE_PTR + layout.table_size);
        var map_bytes: [RUN_TABLE_PTR]u8 = @splat(0);
        for (f.map, 0..) |c, b| {
            const v: u32 = @as(u32, c) * layout.width;
            if (layout.wide_map) {
                std.mem.writeInt(u16, map_bytes[b * 2 ..][0..2], @intCast(v), .little);
            } else {
                map_bytes[b] = @intCast(v);
            }
        }
        try w.raw(&map_bytes);
        if (w.counting) {
            w.len += layout.table_size;
        } else {
            if (w.len + layout.table_size > w.bytes.len) return fail(0, .too_large);
            for (f.trans) |t| {
                const v = t * layout.row_size;
                switch (layout.width) {
                    1 => w.bytes[w.len] = @intCast(v),
                    2 => std.mem.writeInt(u16, w.bytes[w.len..][0..2], @intCast(v), .little),
                    else => std.mem.writeInt(u32, w.bytes[w.len..][0..4], v, .little),
                }
                w.len += layout.width;
            }
        }
        w.endSize(at);
    }
}

// The input-cap guard at the start of both render bodies.
fn emitInputGuard(w: *Buf) CompileError!void {
    // A host that exceeds the input capacity violates the contract.
    try w.raw(&.{ 0x20, 0 });
    try w.i32Const(RUN_INPUT_CAP);
    try w.raw(&.{ 0x4b, 0x04, 0x40, 0x00, 0x0b }); // i32.gt_u if unreachable end
}

// The shared epilogue. Expects local 1 = i and local `state` = the final
// state (a row offset for the table, an index for code), with `accept_at`
// the first accepting value in the same units.
fn emitEpilogue(w: *Buf, state: u8, accept_at: u32, run_input_ptr: u32) CompileError!void {
    // Success: size = n, high word = input pointer.
    try w.raw(&.{ 0x20, 0, 0x21, 3 });
    try w.i32Const(run_input_ptr);
    try w.raw(&.{ 0x21, 4 });
    // state < accept_at: reject at i, backed up to its code point's first byte.
    try w.raw(&.{ 0x20, state });
    try w.i32Const(accept_at);
    try w.raw(&.{ 0x49, 0x04, 0x40 }); // i32.lt_u if
    try w.i32Const(0x80000000);
    try w.raw(&.{ 0x21, 4, 0x20, 1, 0x21, 3 });
    for (0..3) |_| {
        // if size < n and (input[size] & 0xC0) == 0x80: size -= 1
        try w.raw(&.{ 0x20, 3, 0x20, 0, 0x49, 0x04, 0x40, 0x20, 3 });
        try w.load(OP_LOAD8_U, 0, run_input_ptr);
        try w.raw(&.{ 0x41, 0xc0, 0x01, 0x71, 0x41, 0x80, 0x01, 0x46, 0x04, 0x40 });
        try w.raw(&.{ 0x20, 3, 0x41, 1, 0x6b, 0x21, 3, 0x0b, 0x0b });
    }
    try w.byte(0x0b); // end if
    // The output proof: size > cap traps, then pack the result.
    try w.raw(&.{ 0x20, 3 });
    try w.i32Const(RUN_INPUT_CAP);
    try w.raw(&.{ 0x4b, 0x04, 0x40, 0x00, 0x0b });
    try w.raw(&.{ 0x20, 4, 0xad, 0x42, 32, 0x86, 0x20, 3, 0xad, 0x84, 0x0b });
}

// The code encoding's render(n): locals 1 = i, 2 = state, 3 = size or
// failure offset, 4 = high word, 5 = the current byte. Each iteration
// dispatches on the state with br_table. Each state's case starts from its
// most common next state and, for every other next state, uses `select` to
// replace it when the byte falls in that state's byte ranges. The cases have
// no branches of their own, and the loop has the same counter and exit as
// the table encoding.
fn emitCodeRender(w: *Buf, f: Final) CompileError!void {
    const at = try w.beginSize();
    try w.raw(&.{ 1, 5, 0x7f });
    try emitInputGuard(w);
    try w.i32Const(f.start);
    try w.raw(&.{ 0x21, 2 });
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 }); // block loop
    try w.raw(&.{ 0x20, 1, 0x20, 0, 0x4f, 0x0d, 1 }); // i >= n: br_if 1
    try w.raw(&.{ 0x20, 1 });
    try w.load(OP_LOAD8_U, 0, 0);
    try w.raw(&.{ 0x21, 5 });
    // One block for the switch's exit, then one per state.
    const k = f.states;
    try w.raw(&.{ 0x02, 0x40 });
    for (0..k) |_| try w.raw(&.{ 0x02, 0x40 });
    try w.raw(&.{ 0x20, 2, 0x0e });
    try w.uleb(k - 1);
    for (0..k - 1) |s| try w.uleb(s);
    try w.uleb(k - 1);
    for (0..k) |s| {
        try w.byte(0x0b); // end of state s's block: its case follows
        try emitCase(w, f, @intCast(s));
        try w.raw(&.{ 0x21, 2 });
        if (s + 1 < k) {
            try w.byte(0x0c); // br to the switch's exit
            try w.uleb(k - 1 - s);
        }
    }
    try w.byte(0x0b); // end of the switch
    try w.raw(&.{ 0x20, 2, 0x45, 0x0d, 1 }); // state == 0 (dead): br_if 1
    try w.raw(&.{ 0x20, 1, 0x41, 1, 0x6a, 0x21, 1 }); // i += 1
    try w.raw(&.{ 0x0c, 0, 0x0b, 0x0b }); // br 0 end end
    try emitEpilogue(w, 2, f.accept_from, 0);
    w.endSize(at);
}

// Pushes state s's next state for the byte in local 5.
fn emitCase(w: *Buf, f: Final, s: u32) CompileError!void {
    var next: [256]u32 = undefined;
    for (0..256) |b| next[b] = f.trans[s * f.classes + f.map[b]];
    // The next state covering the most bytes is the starting value.
    var targets: [256]u32 = undefined;
    var counts: [256]u32 = undefined;
    var distinct: usize = 0;
    for (next) |t| {
        const i = std.mem.indexOfScalar(u32, targets[0..distinct], t) orelse blk: {
            targets[distinct] = t;
            counts[distinct] = 0;
            distinct += 1;
            break :blk distinct - 1;
        };
        counts[i] += 1;
    }
    var best: u32 = targets[0];
    var best_count: u32 = 0;
    for (targets[0..distinct], counts[0..distinct]) |t, c| {
        if (c > best_count) {
            best = t;
            best_count = c;
        }
    }
    try w.i32Const(best);
    // Every other next state, in byte order of first appearance.
    var done: [256]bool = @splat(false);
    for (0..256) |b0| {
        const t = next[b0];
        if (t == best or done[b0]) continue;
        try w.i32Const(t);
        // Condition: the byte is outside every range that leads to t, ANDed
        // over the ranges, so `select` keeps the value below it.
        var ranges: u32 = 0;
        var b: usize = b0;
        while (b < 256) {
            if (next[b] != t) {
                b += 1;
                continue;
            }
            const lo = b;
            while (b < 256 and next[b] == t) : (b += 1) done[b] = true;
            const hi = b - 1;
            try w.raw(&.{ 0x20, 5 });
            if (lo == hi) {
                try w.i32Const(@intCast(lo));
                try w.byte(0x47); // i32.ne
            } else if (lo == 0) {
                try w.i32Const(@intCast(hi));
                try w.byte(0x4b); // i32.gt_u
            } else if (hi == 255) {
                try w.i32Const(@intCast(lo));
                try w.byte(0x49); // i32.lt_u
            } else {
                try w.i32Const(@intCast(lo));
                try w.byte(0x6b); // i32.sub
                try w.i32Const(@intCast(hi - lo));
                try w.byte(0x4b); // i32.gt_u
            }
            if (ranges > 0) try w.byte(0x71); // i32.and
            ranges += 1;
        }
        try w.byte(0x1b); // select
    }
}

// The table encoding's render(n): locals 1 = i, 2 = row, 3 = size or
// failure offset, 4 = high word.
fn emitTableRender(w: *Buf, f: Final, layout: TableLayout) CompileError!void {
    const width = layout.width;
    const row_size = layout.row_size;
    const run_input_ptr = layout.run_input_ptr;
    const at = try w.beginSize();
    try w.raw(&.{ 1, 4, 0x7f });
    try emitInputGuard(w);
    try w.i32Const(f.start * row_size);
    try w.raw(&.{ 0x21, 2 });
    // block loop: i >= n exits; row = table[row + map[input[i]]]; row == 0
    // (dead) exits with i < n; i += 1.
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.raw(&.{ 0x20, 1, 0x20, 0, 0x4f, 0x0d, 1 }); // i >= n: br_if 1
    try w.raw(&.{ 0x20, 2, 0x20, 1 });
    try w.load(OP_LOAD8_U, 0, run_input_ptr);
    if (layout.wide_map) {
        try w.raw(&.{ 0x41, 1, 0x74 }); // i32.const 1 i32.shl
        try w.load(OP_LOAD16_U, 1, RUN_MAP_PTR);
    } else {
        try w.load(OP_LOAD8_U, 0, RUN_MAP_PTR);
    }
    try w.byte(0x6a); // i32.add
    switch (width) {
        1 => try w.load(OP_LOAD8_U, 0, RUN_TABLE_PTR),
        2 => try w.load(OP_LOAD16_U, 1, RUN_TABLE_PTR),
        else => try w.load(OP_LOAD32, 2, RUN_TABLE_PTR),
    }
    try w.raw(&.{ 0x22, 2, 0x45, 0x0d, 1 }); // local.tee row i32.eqz br_if 1
    try w.raw(&.{ 0x20, 1, 0x41, 1, 0x6a, 0x21, 1 }); // i += 1
    try w.raw(&.{ 0x0c, 0, 0x0b, 0x0b }); // br 0 end end

    try emitEpilogue(w, 2, f.accept_from * row_size, run_input_ptr);
    w.endSize(at);
}

fn compile(src: []const u8) CompileError!usize {
    arena = std.heap.FixedBufferAllocator.init(&arena_buf);
    work = 0;
    nfa = .empty;
    @memset(&byte_bounds, false);
    byte_bounds[0] = true;
    @memset(&nfa_mark, 0);
    mark_gen = 0;

    const tree = try parse(src);
    const match_state = try addState(.{ .kind = .match }, 0);
    std.debug.assert(match_state == 0);
    const start = try build(tree, match_state, 0);
    computeClasses();
    const dfa = try determinize(start);
    const f = try finalize(dfa);
    const encoding = try chooseEncoding(f, prefer_table);
    var w = Buf{ .bytes = &output_buf };
    try emitModule(&w, f, encoding);
    return w.len;
}

// ---------------------------------------------------------------------------
// QIP exports

// Uniform `prefer_table`: 0 (the default) emits whichever encoding gives the
// smaller module; 1 always emits the transition table. Like every content
// uniform it applies to one render.
var prefer_table: bool = false;

export fn uniform_set_prefer_table(value: u32) u32 {
    prefer_table = value != 0;
    return @intFromBool(prefer_table);
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn failure_modes_per_input_offset() u32 {
    return FAILURE_MODES;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    defer prefer_table = false;
    const size = compile(input_buf[0..input_size]) catch {
        return .{
            .output_size_or_failure = fail_offset * FAILURE_MODES + @intFromEnum(fail_mode),
            .output_ptr = 0,
            .failed = 1,
        };
    };
    return .{
        .output_size_or_failure = @intCast(size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

// ---------------------------------------------------------------------------
// Tests: run the final DFA directly, as the generated render does.

fn testCompile(pattern: []const u8) !Final {
    arena = std.heap.FixedBufferAllocator.init(&arena_buf);
    work = 0;
    nfa = .empty;
    @memset(&byte_bounds, false);
    byte_bounds[0] = true;
    @memset(&nfa_mark, 0);
    mark_gen = 0;
    const tree = try parse(pattern);
    _ = try addState(.{ .kind = .match }, 0);
    const start = try build(tree, 0, 0);
    computeClasses();
    return finalize(try determinize(start));
}

fn testMatch(pattern: []const u8, text: []const u8) !bool {
    const f = try testCompile(pattern);
    var s = f.start;
    for (text) |b| {
        s = f.trans[s * f.classes + f.map[b]];
        if (s == 0) return false;
    }
    return s >= f.accept_from;
}

fn expectRejected(pattern: []const u8, offset: u32, mode: Failure) !void {
    try std.testing.expectError(error.Rejected, testCompile(pattern));
    try std.testing.expectEqual(mode, fail_mode);
    try std.testing.expectEqual(offset, fail_offset);
}

test "whole-string matching" {
    try std.testing.expect(try testMatch("abc", "abc"));
    try std.testing.expect(!try testMatch("abc", "abcd"));
    try std.testing.expect(!try testMatch("abc", "xabc"));
    try std.testing.expect(try testMatch("", ""));
    try std.testing.expect(!try testMatch("", "a"));
    try std.testing.expect(try testMatch("a|", ""));
    try std.testing.expect(try testMatch("(a|bc)*d", "abcad"));
    try std.testing.expect(try testMatch("^$", "^$"));
}

test "quantifiers" {
    try std.testing.expect(try testMatch("a{2,3}", "aa"));
    try std.testing.expect(try testMatch("a{2,3}", "aaa"));
    try std.testing.expect(!try testMatch("a{2,3}", "aaaa"));
    try std.testing.expect(try testMatch("a{2,}", "aaaaaa"));
    try std.testing.expect(!try testMatch("a{2}", "a"));
    try std.testing.expect(try testMatch("a{0}", ""));
    try std.testing.expect(try testMatch("(a*)*b", "aaab"));
    try std.testing.expect(try testMatch("(a?){3}", "aa"));
}

test "dot excludes newline and carriage return" {
    try std.testing.expect(try testMatch(".", "é"));
    try std.testing.expect(try testMatch(".", "\u{10FFFF}"));
    try std.testing.expect(!try testMatch(".", "\n"));
    try std.testing.expect(!try testMatch(".", "\r"));
    try std.testing.expect(!try testMatch(".", "ab"));
}

test "classes and escapes" {
    try std.testing.expect(try testMatch("[a-c]+", "abcba"));
    try std.testing.expect(!try testMatch("[^a-c]", "b"));
    try std.testing.expect(try testMatch("[^a-c]", "\u{1F600}"));
    try std.testing.expect(try testMatch("[-a]", "-"));
    try std.testing.expect(try testMatch("[a-]", "-"));
    try std.testing.expect(try testMatch("[--]", "-"));
    try std.testing.expect(try testMatch("[^^]", "a"));
    try std.testing.expect(!try testMatch("[^^]", "^"));
    try std.testing.expect(try testMatch("[\\[\\]]{2}", "[]"));
    try std.testing.expect(try testMatch("\\n\\r\\t", "\n\r\t"));
    try std.testing.expect(try testMatch("[\\--\\.]", "."));
    try std.testing.expect(try testMatch("\\p{Lu}\\p{Ll}+", "Ωmega"));
    try std.testing.expect(!try testMatch("\\p{L}", "1"));
    try std.testing.expect(try testMatch("\\P{L}", "1"));
    try std.testing.expect(try testMatch("[\\p{Nd}x]+", "x٣1"));
    try std.testing.expect(try testMatch("\\p{Cn}", "\u{378}"));
    try std.testing.expect(try testMatch("[^\\p{L}\\P{L}]|z", "z"));
    try std.testing.expect(!try testMatch("[^\\p{L}\\P{L}]", "z"));
}

test "syntax errors report the offset" {
    try expectRejected("[^]", 2, .syntax);
    try expectRejected("[]", 1, .syntax);
    try expectRejected("a**", 2, .syntax);
    try expectRejected("(a", 2, .syntax);
    try expectRejected("a)", 1, .syntax);
    try expectRejected("\\d", 0, .syntax);
    try expectRejected("\\p{Lc}", 3, .syntax);
    try expectRejected("a{3,2}", 4, .syntax);
    try expectRejected("a{,2}", 2, .syntax);
    try expectRejected("[z-a]", 3, .syntax);
    try expectRejected("[a-c-e]", 4, .syntax);
    try expectRejected("[a[]", 2, .syntax);
    try expectRejected("{", 0, .syntax);
    try expectRejected("]", 0, .syntax);
}

test "limits are reported as too large" {
    try expectRejected("a{100001}", 2, .too_large);
    try expectRejected("(a|b)*a(a|b){20}", 0, .too_large);
    try expectRejected("((a{100}){100}){100}", 3, .too_large);
}

test "minimized table is small" {
    const f = try testCompile("(a|b)*abb");
    // Dead plus the 4 states of the classic minimal DFA.
    try std.testing.expectEqual(@as(u32, 5), f.states);
    try std.testing.expectEqual(@as(u32, 3), f.classes);
}
