// The validator inside every module json-schema-to-wasm generates. It holds
// no schema of its own: the compiler adds an active data segment that fills
// program_buf with a compiled program (lib/json-schema-program.zig), and the
// marker below tells the compiler where program_buf is.
//
// The generated component is a QIP Content component. Input is one JSON
// instance. On accept the output is the input bytes unchanged. Rejection
// means only that the instance does not conform. Invalid JSON, nesting past
// MAX_DEPTH or a resource limit traps.
//
// Each render parses the instance once into a flat token tape (no tree of
// allocations; containers record where they end so a subtree is skipped in
// one step), then walks the program over the tape. Every $ref, keyword and
// count bound was resolved by the compiler, so evaluation does no lookups by
// name. Regular expressions arrive compiled; their DFA states are built on
// first use in a render.
const std = @import("std");
const js = @import("json-schema-2020-12.zig");
const prog = @import("json-schema-program.zig");

const Node = prog.Node;
const Tok = prog.Tok;
const Str = prog.Str;
const List = prog.List;
const Bounds = prog.Bounds;
const NONE = prog.NONE;
const PROPERTY_SCAN_MAX = 16;

const INPUT_CAP: usize = 4 * 1024 * 1024;
// A token covers at least two input bytes, apart from a lone scalar.
const TOK_CAP: usize = INPUT_CAP / 2 + 2;
const SCRATCH_CAP: usize = 8 * 1024 * 1024;
const ARENA_CAP: usize = 16 * 1024 * 1024;
const PROGRAM_CAP: usize = 8 * 1024 * 1024;
const MAX_DEPTH: usize = js.MAX_DEPTH;
const CONTENT_TYPE = "application/json";

// The input, then strings that needed unescaping, so every tape offset is
// relative to the start of this buffer.
var text_buf: [INPUT_CAP * 2]u8 = undefined;
var toks_buf: [TOK_CAP]Tok = undefined;
var scratch_buf: [SCRATCH_CAP]u8 = undefined;
var arena_buf: [ARENA_CAP]u8 = undefined;
var program_buf: [PROGRAM_CAP]u8 align(16) = undefined;

// Read through a volatile pointer so the initializer stays in the data
// section, where the compiler finds it.
var marker: prog.Marker = .{ .magic = prog.MARKER_MAGIC, .program = &program_buf, .cap = PROGRAM_CAP };

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&text_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

// Accepted output is the input itself.
export fn output_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    const ok = run(input_size) catch @trap();
    if (ok) return .{ .output_size_or_failure = input_size, .output_ptr = @intCast(@intFromPtr(&text_buf)), .failed = 0 };
    return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
}

const Error = js.Error;

// ---------------------------------------------------------------------------
// Program access

const Program = struct {
    nodes: [*]const Node,
    words: [*]const u32,
    toks: [*]const Tok,
    dyns: []const prog.DynAnchor,
    regexes: []const u32, // word indices of RegexHeads
    nums: [*]const prog.Num,
    bytes: [*]const u8,
    root: u32,
};

fn loadProgram() Error!Program {
    const m: *const volatile prog.Marker = &marker;
    const base = m.program;
    const h: *const prog.Header = @ptrCast(@alignCast(base));
    if (!std.mem.eql(u8, &h.magic, &prog.MAGIC)) return error.Unsupported;
    return .{
        .nodes = @ptrCast(@alignCast(base + h.nodes_off)),
        .words = @ptrCast(@alignCast(base + h.words_off)),
        .toks = @ptrCast(@alignCast(base + h.toks_off)),
        .dyns = @as([*]const prog.DynAnchor, @ptrCast(@alignCast(base + h.dyn_off)))[0..h.dyn_count],
        .regexes = @as([*]const u32, @ptrCast(@alignCast(base + h.regexes_off)))[0..h.regex_count],
        .nums = @ptrCast(@alignCast(base + h.nums_off)),
        .bytes = base + h.bytes_off,
        .root = h.root,
    };
}

// ---------------------------------------------------------------------------
// Instance tape

const Tape = struct { toks: [*]const Tok, base: [*]const u8 };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    n: u32 = 0,
    decoded: usize = INPUT_CAP,

    inline fn skipWs(p: *Parser) void {
        while (p.pos < p.src.len) {
            switch (p.src[p.pos]) {
                ' ', '\t', '\n', '\r' => p.pos += 1,
                else => return,
            }
        }
    }

    inline fn push(p: *Parser, tag: u32, off: usize, len: usize) Error!u32 {
        if (p.n >= TOK_CAP) return error.OutOfMemory;
        const i = p.n;
        toks_buf[i] = .{ .tag = tag, .off = @intCast(off), .len = @intCast(len), .end = i + 1 };
        p.n += 1;
        return i;
    }

    fn literal(p: *Parser, word: []const u8, tag: u32) Error!void {
        if (!std.mem.startsWith(u8, p.src[p.pos..], word)) return error.InvalidJson;
        _ = try p.push(tag, p.pos, word.len);
        p.pos += word.len;
    }

    fn number(p: *Parser) Error!void {
        const src = p.src;
        const start = p.pos;
        var i = p.pos;
        if (src[i] == '-') i += 1;
        if (i >= src.len) return error.InvalidJson;
        if (src[i] == '0') {
            i += 1;
        } else if (src[i] >= '1' and src[i] <= '9') {
            while (i < src.len and src[i] >= '0' and src[i] <= '9') i += 1;
        } else return error.InvalidJson;
        if (i < src.len and src[i] == '.') {
            i += 1;
            const digits = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') i += 1;
            if (i == digits) return error.InvalidJson;
        }
        if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
            i += 1;
            if (i < src.len and (src[i] == '+' or src[i] == '-')) i += 1;
            const digits = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') i += 1;
            if (i == digits) return error.InvalidJson;
        }
        _ = try p.push(prog.TAG_NUMBER, start, i - start);
        p.pos = i;
    }

    fn string(p: *Parser) Error!void {
        const src = p.src;
        const start = p.pos + 1;
        var i = start;
        var high: u64 = 0;
        var escaped = false;
        while (true) {
            // Eight bytes at a time while none is a quote, a backslash or a
            // control character. Each test's lowest set bit is exact, so
            // the lowest bit of their union finds the first such byte.
            while (i + 8 <= src.len) {
                const x = std.mem.readInt(u64, src[i..][0..8], .little);
                const ones: u64 = 0x0101010101010101;
                const highs: u64 = 0x8080808080808080;
                const q = x ^ (ones * '"');
                const b = x ^ (ones * '\\');
                const special = ((q -% ones) & ~q) | ((b -% ones) & ~b) | ((x -% ones * 0x20) & ~x);
                const stop = special & highs;
                if (stop == 0) {
                    high |= x;
                    i += 8;
                    continue;
                }
                const n = @ctz(stop) / 8;
                // Bytes before the stop are plain text.
                if (n > 0) high |= x & ((@as(u64, 1) << @intCast(n * 8)) - 1);
                i += n;
                break;
            }
            if (i >= src.len) return error.InvalidJson;
            const c = src[i];
            if (c == '"') break;
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                escaped = true;
                i += 2;
                continue;
            }
            high |= c;
            i += 1;
        }
        const raw = src[start..i];
        p.pos = i + 1;
        if (high & 0x8080808080808080 != 0 and !std.unicode.utf8ValidateSlice(raw)) return error.InvalidJson;
        if (!escaped) {
            _ = try p.push(prog.TAG_STRING, start, raw.len);
            return;
        }
        const out_start = p.decoded;
        const out = text_buf[out_start..];
        var o: usize = 0;
        var k: usize = 0;
        while (k < raw.len) {
            const c = raw[k];
            if (c != '\\') {
                out[o] = c;
                o += 1;
                k += 1;
                continue;
            }
            if (k + 1 >= raw.len) return error.InvalidJson;
            const e = raw[k + 1];
            k += 2;
            const simple: ?u8 = switch (e) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => null,
                else => return error.InvalidJson,
            };
            if (simple) |byte| {
                out[o] = byte;
                o += 1;
                continue;
            }
            var cp = try hex4(raw, k);
            k += 4;
            if (cp >= 0xD800 and cp <= 0xDBFF and k + 6 <= raw.len and raw[k] == '\\' and raw[k + 1] == 'u') {
                const low = try hex4(raw, k + 2);
                if (low >= 0xDC00 and low <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    k += 6;
                }
            }
            o += js.encodeWtf8(cp, out[o..]);
        }
        p.decoded += o;
        _ = try p.push(prog.TAG_STRING, out_start, o);
    }

    fn hex4(raw: []const u8, at: usize) Error!u21 {
        if (at + 4 > raw.len) return error.InvalidJson;
        var value: u21 = 0;
        for (raw[at..][0..4]) |c| {
            const digit: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidJson,
            };
            value = value * 16 + digit;
        }
        return value;
    }

    // Iterative, so nesting depth costs no stack.
    fn parse(p: *Parser) Error!void {
        var stack: [MAX_DEPTH]u32 = undefined;
        var depth: usize = 0;
        p.skipWs();
        value: while (true) {
            if (p.pos >= p.src.len) return error.InvalidJson;
            switch (p.src[p.pos]) {
                '{', '[' => |c| {
                    if (depth >= MAX_DEPTH) return error.TooDeep;
                    const is_object = c == '{';
                    stack[depth] = try p.push(if (is_object) prog.TAG_OBJECT else prog.TAG_ARRAY, p.pos, 0);
                    depth += 1;
                    p.pos += 1;
                    p.skipWs();
                    if (p.pos < p.src.len and p.src[p.pos] == (if (is_object) @as(u8, '}') else ']')) {
                        // Empty: a complete value already.
                        toks_buf[stack[depth - 1]].end = p.n;
                        depth -= 1;
                        p.pos += 1;
                    } else {
                        if (is_object) try p.key();
                        continue :value;
                    }
                },
                '"' => try p.string(),
                't' => try p.literal("true", prog.TAG_TRUE),
                'f' => try p.literal("false", prog.TAG_FALSE),
                'n' => try p.literal("null", prog.TAG_NULL),
                '-', '0'...'9' => try p.number(),
                else => return error.InvalidJson,
            }
            // After a complete value.
            while (true) {
                if (depth == 0) {
                    p.skipWs();
                    if (p.pos != p.src.len) return error.InvalidJson;
                    return;
                }
                p.skipWs();
                if (p.pos >= p.src.len) return error.InvalidJson;
                const top = &toks_buf[stack[depth - 1]];
                const is_object = top.tag == prog.TAG_OBJECT;
                const c = p.src[p.pos];
                if (c == (if (is_object) @as(u8, '}') else ']')) {
                    top.len += 1;
                    top.end = p.n;
                    depth -= 1;
                    p.pos += 1;
                    continue;
                }
                if (c != ',') return error.InvalidJson;
                top.len += 1;
                p.pos += 1;
                p.skipWs();
                if (is_object) try p.key();
                continue :value;
            }
        }
    }

    fn key(p: *Parser) Error!void {
        if (p.pos >= p.src.len or p.src[p.pos] != '"') return error.InvalidJson;
        try p.string();
        p.skipWs();
        if (p.pos >= p.src.len or p.src[p.pos] != ':') return error.InvalidJson;
        p.pos += 1;
        p.skipWs();
    }
};

// ---------------------------------------------------------------------------
// Regular expressions: a lazy DFA over the compiled program
//
// json-schema-to-wasm compiles each pattern into RInsts (see RegexHead), so
// no pattern is parsed here. A DFA state is the set of threads alive after
// some prefix of the text: the consuming instructions they wait at, plus $
// assertions that can only pass at the end. States and their ASCII
// transitions are built on first use and kept for the rest of the render, so
// each ASCII byte after that is one table lookup. A step on a non-ASCII code
// point is computed without caching. An unanchored pattern starts a new
// thread at every position, and reaching match anywhere means the pattern
// matches. Patterns with \b or \B, which look at the next code point, and
// any regex whose DFA outgrows MAX_DFA_STATES or the arena, run the same
// thread sets without caching (a Pike VM).

const MAX_DFA_STATES: usize = 2048;
const UNKNOWN: u32 = 0;
const MATCHED: u32 = 0xFFFF_FFFF;

const DState = struct {
    pcs: []const u32,
    // Whether a pending $ leads to match at the end of a non-empty text:
    // 0 not yet known, 1 no, 2 yes.
    end: u8 = 0,
    next: [128]u32 = [_]u32{UNKNOWN} ** 128, // state index + 1, or MATCHED
};

// Zero-width context for a closure. In DFA mode the end is unknown, so $ is
// kept pending; \b never appears there.
const Ctx = struct { at_start: bool, at_end: bool = false, boundary: bool = false };

const Matcher = struct {
    insts: []const prog.RInst,
    words: [*]const u32,
    anchored: bool,
    dfa: bool,
    states: std.ArrayListUnmanaged(DState) = .empty,
    start: u32 = UNKNOWN,
    marks: []u32,
    stack: []u32,
    set: []u32,
    other: []u32,
    gen: u32 = 0,

    fn init(p: Program, regex: u32) Error!*Matcher {
        const a = arena_fba.allocator();
        const at = p.regexes[regex];
        const head: *const prog.RegexHead = @ptrCast(@alignCast(p.words + at));
        const n = head.inst_count;
        const insts = @as([*]const prog.RInst, @ptrCast(@alignCast(p.words + at + 2)))[0..n];
        const m = try a.create(Matcher);
        const buffers = try a.alloc(u32, n * 5);
        m.* = .{
            .insts = insts,
            .words = p.words,
            .anchored = head.flags & prog.R_ANCHORED != 0,
            .dfa = head.flags & prog.R_BOUNDARY == 0,
            .marks = buffers[0..n],
            .stack = buffers[n .. 3 * n],
            .set = buffers[3 * n .. 4 * n],
            .other = buffers[4 * n ..],
        };
        @memset(m.marks, 0);
        return m;
    }

    fn classHit(m: *const Matcher, inst: prog.RInst, cp: u21) bool {
        const count = inst.b & ~prog.CLASS_NEGATED;
        const ranges = m.words + inst.a;
        // Ranges are sorted and disjoint: binary search.
        var lo: u32 = 0;
        var hi: u32 = count;
        var hit = false;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (cp < ranges[mid * 2]) {
                hi = mid;
            } else if (cp > ranges[mid * 2 + 1]) {
                lo = mid + 1;
            } else {
                hit = true;
                break;
            }
        }
        return hit != (inst.b & prog.CLASS_NEGATED != 0);
    }

    fn consumes(m: *const Matcher, inst: prog.RInst, cp: u21) bool {
        return switch (inst.op) {
            prog.OP_CHAR => inst.a == cp,
            prog.OP_ANY => cp != '\n' and cp != '\r' and cp != 0x2028 and cp != 0x2029,
            prog.OP_CLASS => m.classHit(inst, cp),
            else => false,
        };
    }

    // Adds the threads reachable from pc without consuming input to out.
    // Returns true when one reaches match. ^ passes only at the start; $ is
    // kept in the set, unresolved, unless at_end.
    fn closure(m: *Matcher, out: []u32, count: *usize, pc0: u32, ctx: Ctx) bool {
        var top: usize = 1;
        m.stack[0] = pc0;
        while (top > 0) {
            top -= 1;
            const pc = m.stack[top];
            if (m.marks[pc] == m.gen) continue;
            m.marks[pc] = m.gen;
            const inst = m.insts[pc];
            var follow: ?u32 = null;
            switch (inst.op) {
                prog.OP_MATCH => return true,
                prog.OP_JMP => follow = inst.a,
                prog.OP_SPLIT => {
                    m.stack[top] = inst.b;
                    top += 1;
                    follow = inst.a;
                },
                prog.OP_BOL => if (ctx.at_start) {
                    follow = pc + 1;
                },
                prog.OP_EOL => if (ctx.at_end) {
                    follow = pc + 1;
                } else {
                    out[count.*] = pc;
                    count.* += 1;
                },
                prog.OP_WORD_BOUNDARY => if (ctx.boundary) {
                    follow = pc + 1;
                },
                prog.OP_NOT_WORD_BOUNDARY => if (!ctx.boundary) {
                    follow = pc + 1;
                },
                else => {
                    out[count.*] = pc;
                    count.* += 1;
                },
            }
            if (follow) |next| {
                m.stack[top] = next;
                top += 1;
            }
        }
        return false;
    }

    // Interns the thread set in m.set[0..count] and returns its index + 1.
    fn intern(m: *Matcher, count: usize) Error!u32 {
        const pcs = m.set[0..count];
        // Thread sets are small; insertion sort keeps std's sort out of the
        // module.
        var i: usize = 1;
        while (i < pcs.len) : (i += 1) {
            const x = pcs[i];
            var j = i;
            while (j > 0 and pcs[j - 1] > x) : (j -= 1) pcs[j] = pcs[j - 1];
            pcs[j] = x;
        }
        for (m.states.items, 0..) |st, index| {
            if (std.mem.eql(u32, st.pcs, pcs)) return @intCast(index + 1);
        }
        if (m.states.items.len >= MAX_DFA_STATES) return error.OutOfMemory;
        const a = arena_fba.allocator();
        try m.states.append(a, .{ .pcs = try a.dupe(u32, pcs) });
        return @intCast(m.states.items.len);
    }

    fn startState(m: *Matcher) Error!u32 {
        if (m.start == UNKNOWN) {
            m.gen += 1;
            var count: usize = 0;
            m.start = if (m.closure(m.set, &count, 0, .{ .at_start = true })) MATCHED else try m.intern(count);
        }
        return m.start;
    }

    fn step(m: *Matcher, state: u32, cp: u21) Error!u32 {
        m.gen += 1;
        var count: usize = 0;
        const pcs = m.states.items[state - 1].pcs;
        for (pcs) |pc| {
            if (m.consumes(m.insts[pc], cp) and m.closure(m.set, &count, pc + 1, .{ .at_start = false })) return MATCHED;
        }
        if (!m.anchored and m.closure(m.set, &count, 0, .{ .at_start = false })) return MATCHED;
        return m.intern(count);
    }

    // At the end of the text, does a pending $ lead to match?
    fn acceptsAtEnd(m: *Matcher, state: u32, at_start: bool) bool {
        m.gen += 1;
        var count: usize = 0;
        for (m.states.items[state - 1].pcs) |pc| {
            if (m.insts[pc].op == prog.OP_EOL and m.closure(m.set, &count, pc + 1, .{ .at_start = at_start, .at_end = true })) return true;
        }
        return false;
    }

    fn search(m: *Matcher, text: []const u8) Error!bool {
        if (m.dfa) {
            if (m.searchDfa(text)) |found| return found else |err| switch (err) {
                // The DFA grew too large: this regex uses thread sets from now on.
                error.OutOfMemory => m.dfa = false,
                else => return err,
            }
        }
        return m.searchSets(text);
    }

    fn searchDfa(m: *Matcher, text: []const u8) Error!bool {
        var state = try m.startState();
        var pos: usize = 0;
        while (true) {
            if (state == MATCHED) return true;
            if (m.anchored and m.states.items[state - 1].pcs.len == 0) return false;
            if (pos >= text.len) {
                if (pos == 0) return m.acceptsAtEnd(state, true);
                const st = &m.states.items[state - 1];
                if (st.end == 0) st.end = if (m.acceptsAtEnd(state, false)) 2 else 1;
                return st.end == 2;
            }
            const b = text[pos];
            if (b < 0x80) {
                const slot = &m.states.items[state - 1].next[b];
                if (slot.* == UNKNOWN) {
                    const next = try m.step(state, b);
                    m.states.items[state - 1].next[b] = next;
                }
                state = m.states.items[state - 1].next[b];
                pos += 1;
            } else {
                const d = js.decodeAt(text, pos);
                state = try m.step(state, d.cp);
                pos += d.len;
            }
        }
    }

    fn boundaryAt(text: []const u8, pos: usize, prev_word: bool) bool {
        const next_word = pos < text.len and js.isWordChar(js.decodeAt(text, pos).cp);
        return prev_word != next_word;
    }

    // The same thread sets as the DFA, without caching, and with the exact
    // position known so \b, \B and $ resolve as they go.
    fn searchSets(m: *Matcher, text: []const u8) bool {
        var clist = m.set;
        var nlist = m.other;
        m.gen += 1;
        var ccount: usize = 0;
        if (m.closure(clist, &ccount, 0, .{ .at_start = true, .at_end = text.len == 0, .boundary = boundaryAt(text, 0, false) })) return true;
        var pos: usize = 0;
        while (pos < text.len) {
            const d = js.decodeAt(text, pos);
            const npos = pos + d.len;
            const ctx = Ctx{ .at_start = false, .at_end = npos == text.len, .boundary = boundaryAt(text, npos, js.isWordChar(d.cp)) };
            m.gen += 1;
            var ncount: usize = 0;
            for (clist[0..ccount]) |pc| {
                if (m.consumes(m.insts[pc], d.cp) and m.closure(nlist, &ncount, pc + 1, ctx)) return true;
            }
            if (!m.anchored and m.closure(nlist, &ncount, 0, ctx)) return true;
            if (m.anchored and ncount == 0) return false;
            const tmp = clist;
            clist = nlist;
            nlist = tmp;
            ccount = ncount;
            pos = npos;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Evaluation

var scratch_fba: std.heap.FixedBufferAllocator = undefined;
var arena_fba: std.heap.FixedBufferAllocator = undefined;

const Eval = struct {
    p: Program,
    inst: Tape,
    regex_cache: []?*Matcher,
    scope: [MAX_DEPTH]u32 = undefined,
    scope_len: usize = 0,
    depth: usize = 0,

    inline fn word(e: *const Eval, list: List, i: usize) u32 {
        return e.p.words[list.off + i];
    }

    inline fn pstr(e: *const Eval, s: Str) []const u8 {
        return e.p.bytes[s.off..][0..s.len];
    }

    inline fn text(e: *const Eval, t: Tok) []const u8 {
        return e.inst.base[t.off..][0..t.len];
    }

    fn newBits(len: usize) Error![]u64 {
        const bits = try scratch_fba.allocator().alloc(u64, (len + 63) / 64);
        @memset(bits, 0);
        return bits;
    }

    fn matches(e: *Eval, regex: u32, s: []const u8) Error!bool {
        const m = e.regex_cache[regex] orelse blk: {
            const m = try Matcher.init(e.p, regex);
            e.regex_cache[regex] = m;
            break :blk m;
        };
        return m.search(s);
    }

    // Index of the member value with this key, or null.
    fn member(e: *const Eval, v: u32, name: []const u8) ?u32 {
        const obj = e.inst.toks[v];
        var i = v + 1;
        while (i < obj.end) {
            const k = e.inst.toks[i];
            if (k.len == name.len and std.mem.eql(u8, e.text(k), name)) return i + 1;
            i = e.inst.toks[i + 1].end;
        }
        return null;
    }

    fn validate(e: *Eval, n_in: u32, v: u32, ann: ?[]u64) Error!bool {
        // A node that is only a $ref passes its annotations straight
        // through, so follow it here. Without dynamic anchors the scope it
        // would push is never read.
        var n_idx = n_in;
        if (e.p.dyns.len == 0) {
            var hops: usize = 0;
            while (e.p.nodes[n_idx].flags & prog.F_ONLY_REF != 0) : (hops += 1) {
                if (hops > MAX_DEPTH) return error.TooDeep;
                n_idx = e.p.nodes[n_idx].ref;
            }
        }
        const n = &e.p.nodes[n_idx];
        if (n.flags & (prog.F_FALSE | prog.F_TRUE) != 0) return n.flags & prog.F_TRUE != 0;
        const t = e.inst.toks[v];

        if (n.types != prog.T_ALL) {
            const ok = switch (t.tag) {
                prog.TAG_NULL => n.types & prog.T_NULL != 0,
                prog.TAG_FALSE, prog.TAG_TRUE => n.types & prog.T_BOOLEAN != 0,
                prog.TAG_NUMBER => n.types & prog.T_NUMBER != 0 or
                    (n.types & prog.T_INTEGER != 0 and js.isIntegral(.{ .text = e.text(t) })),
                prog.TAG_STRING => n.types & prog.T_STRING != 0,
                prog.TAG_ARRAY => n.types & prog.T_ARRAY != 0,
                else => n.types & prog.T_OBJECT != 0,
            };
            if (!ok) return false;
        }

        e.depth += 1;
        defer e.depth -= 1;
        if (e.depth > MAX_DEPTH) return error.TooDeep;
        // The dynamic scope only matters to a dynamic $dynamicRef.
        const pushed = e.p.dyns.len > 0 and (e.scope_len == 0 or e.scope[e.scope_len - 1] != n.resource);
        if (pushed) {
            if (e.scope_len >= MAX_DEPTH) return error.TooDeep;
            e.scope[e.scope_len] = n.resource;
            e.scope_len += 1;
        }
        defer if (pushed) {
            e.scope_len -= 1;
        };

        const is_object = t.tag == prog.TAG_OBJECT;
        const is_array = t.tag == prog.TAG_ARRAY;
        const uneval_props = if (is_object) n.uneval_props else NONE;
        const uneval_items = if (is_array) n.uneval_items else NONE;
        const mark = scratch_fba.end_index;
        defer scratch_fba.end_index = mark;
        const own_bits = uneval_props != NONE or uneval_items != NONE;
        const local: ?[]u64 = if (own_bits) try newBits(t.len) else if (is_object or is_array) ann else null;

        if (n.ref != NONE) {
            if (!try e.validate(n.ref, v, local)) return false;
        }
        if (n.dyn_ref != NONE) {
            if (!try e.validate(e.dynamicTarget(n), v, local)) return false;
        }
        var seen: u64 = 0;
        if (!try e.applicators(n, v, t, local, &seen)) return false;
        if (!try e.assertions(n, v, t, seen)) return false;

        if (uneval_items != NONE) {
            const bits = local.?;
            var i = v + 1;
            var index: usize = 0;
            while (i < t.end) : (index += 1) {
                const next = e.inst.toks[i].end;
                if (!bitSet(bits, index)) {
                    if (!try e.validate(uneval_items, i, null)) return false;
                    setBit(bits, index);
                }
                i = next;
            }
        }
        if (uneval_props != NONE) {
            const bits = local.?;
            var i = v + 1;
            var index: usize = 0;
            while (i < t.end) : (index += 1) {
                const next = e.inst.toks[i + 1].end;
                if (!bitSet(bits, index)) {
                    if (!try e.validate(uneval_props, i + 1, null)) return false;
                    setBit(bits, index);
                }
                i = next;
            }
        }
        if (own_bits) {
            if (ann) |out| orBits(out, local.?);
        }
        return true;
    }

    // The outermost resource in the dynamic scope that declares the anchor
    // wins; the compiler already checked the static target declares it.
    fn dynamicTarget(e: *const Eval, n: *const Node) u32 {
        if (n.dyn_name == NONE) return n.dyn_ref;
        for (e.scope[0..e.scope_len]) |resource| {
            for (e.p.dyns) |d| {
                if (d.resource == resource and d.name == n.dyn_name) return d.node;
            }
        }
        return n.dyn_ref;
    }

    fn tryBranch(e: *Eval, sub: u32, v: u32, local: ?[]u64) Error!bool {
        if (local) |bits| {
            const mark = scratch_fba.end_index;
            defer scratch_fba.end_index = mark;
            const tmp = try newBits(bits.len * 64);
            if (!try e.validate(sub, v, tmp)) return false;
            orBits(bits, tmp);
            return true;
        }
        return e.validate(sub, v, null);
    }

    // The first properties entry named name. Lists over PROPERTY_SCAN_MAX
    // entries binary-search the keyTag words alone, then scan the entries
    // sharing that tag; shorter lists are scanned. Both compare the stored
    // keyTag before reading any key bytes. Keys are sorted by tag first, so
    // the scan from the lower bound finds the first of any repeated key.
    inline fn propertyOf(e: *const Eval, n: *const Node, name: []const u8) ?usize {
        return e.property(n.properties, name);
    }

    // Scanning measured faster than binary search up to 16 entries, and
    // stopping the scan early once keys get longer than name slower still.
    inline fn property(e: *const Eval, props: List, name: []const u8) ?usize {
        const tag = prog.keyTag(name);
        var lo: usize = 0;
        if (props.len > PROPERTY_SCAN_MAX) {
            var hi: usize = props.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (e.word(props, mid * 4 + 2) < tag) lo = mid + 1 else hi = mid;
            }
            while (lo < props.len and e.word(props, lo * 4 + 2) == tag) : (lo += 1) {
                if (e.keyEql(props, lo, name, tag)) return lo;
            }
            return null;
        }
        while (lo < props.len) : (lo += 1) {
            if (e.keyEql(props, lo, name, tag)) return lo;
        }
        return null;
    }

    // Whether entry k is name, whose keyTag is tag. Equal tags mean equal
    // lengths below 255 bytes, and equal keys up to three bytes.
    inline fn keyEql(e: *const Eval, props: List, k: usize, name: []const u8, tag: u32) bool {
        if (e.word(props, k * 4 + 2) != tag) return false;
        if (name.len <= 3) return true;
        if (name.len >= 255 and e.word(props, k * 4 + 1) != name.len) return false;
        return std.mem.order(u8, e.p.bytes[e.word(props, k * 4) + 3 ..][0 .. name.len - 3], name[3..]) == .eq;
    }

    // seen collects which properties entries (the first 64) the object has,
    // for required.
    fn applicators(e: *Eval, n: *const Node, v: u32, t: Tok, local: ?[]u64, seen: *u64) Error!bool {
        for (0..n.all_of.len) |i| {
            if (!try e.validate(e.word(n.all_of, i), v, local)) return false;
        }
        if (n.any_of.len > 0) {
            var any = false;
            for (0..n.any_of.len) |i| {
                if (try e.tryBranch(e.word(n.any_of, i), v, local)) {
                    any = true;
                    if (local == null) break;
                }
            }
            if (!any) return false;
        }
        if (n.one_of.len > 0) {
            var passed: usize = 0;
            for (0..n.one_of.len) |i| {
                if (try e.tryBranch(e.word(n.one_of, i), v, local)) passed += 1;
            }
            if (passed != 1) return false;
        }
        if (n.not != NONE) {
            if (try e.validate(n.not, v, null)) return false;
        }
        if (n.if_ != NONE) {
            if (try e.tryBranch(n.if_, v, local)) {
                if (n.then != NONE and !try e.validate(n.then, v, local)) return false;
            } else if (n.else_ != NONE) {
                if (!try e.validate(n.else_, v, local)) return false;
            }
        }
        if (t.tag == prog.TAG_ARRAY and n.flags & prog.F_HAS_ARRAY != 0) {
            var i = v + 1;
            var index: usize = 0;
            while (i < t.end) : (index += 1) {
                const next = e.inst.toks[i].end;
                if (index < n.prefix_items.len) {
                    if (!try e.validate(e.word(n.prefix_items, index), i, null)) return false;
                    if (local) |bits| setBit(bits, index);
                } else if (n.items != NONE) {
                    if (!try e.validate(n.items, i, null)) return false;
                    if (local) |bits| setBit(bits, index);
                }
                i = next;
            }
            if (n.contains != NONE) {
                var found: u32 = 0;
                i = v + 1;
                index = 0;
                while (i < t.end) : (index += 1) {
                    const next = e.inst.toks[i].end;
                    if (try e.validate(n.contains, i, null)) {
                        found += 1;
                        if (local) |bits| setBit(bits, index);
                    }
                    i = next;
                }
                if (!inBounds(found, n.contains_bounds)) return false;
            }
        } else if (t.tag == prog.TAG_OBJECT and n.flags & prog.F_HAS_OBJECT != 0) {
            if (n.flags & prog.F_MATCH_PROPS != 0) {
                var i = v + 1;
                var index: usize = 0;
                while (i < t.end) : (index += 1) {
                    const value = i + 1;
                    const next = e.inst.toks[value].end;
                    const name = e.text(e.inst.toks[i]);
                    var matched = false;
                    if (e.propertyOf(n, name)) |k| {
                        matched = true;
                        if (k < 64) seen.* |= @as(u64, 1) << @intCast(k);
                        if (!try e.validate(e.word(n.properties, k * 4 + 3), value, null)) return false;
                    }
                    var k: usize = 0;
                    while (k < n.pattern_properties.len) : (k += 1) {
                        if (try e.matches(e.word(n.pattern_properties, k * 2), name)) {
                            matched = true;
                            if (!try e.validate(e.word(n.pattern_properties, k * 2 + 1), value, null)) return false;
                        }
                    }
                    if (!matched and n.additional != NONE) {
                        if (!try e.validate(n.additional, value, null)) return false;
                        matched = true;
                    }
                    if (matched) if (local) |bits| setBit(bits, index);
                    i = next;
                }
            }
            var k: usize = 0;
            while (k < n.dependent_schemas.len) : (k += 1) {
                const key = Str{ .off = e.word(n.dependent_schemas, k * 3), .len = e.word(n.dependent_schemas, k * 3 + 1) };
                if (e.member(v, e.pstr(key)) != null) {
                    if (!try e.validate(e.word(n.dependent_schemas, k * 3 + 2), v, local)) return false;
                }
            }
            if (n.property_names != NONE) {
                var i = v + 1;
                while (i < t.end) {
                    if (!try e.validate(n.property_names, i, null)) return false;
                    i = e.inst.toks[i + 1].end;
                }
            }
        }
        return true;
    }

    fn assertions(e: *Eval, n: *const Node, v: u32, t: Tok, seen: u64) Error!bool {
        if (n.const_ != NONE) {
            if (!e.equal(v, n.const_)) return false;
        }
        if (n.flags & prog.F_ENUM != 0) {
            var any = false;
            for (0..n.enum_.len) |i| {
                if (e.equal(v, e.word(n.enum_, i))) {
                    any = true;
                    break;
                }
            }
            if (!any) return false;
        }
        switch (t.tag) {
            prog.TAG_NUMBER => if (n.flags & prog.F_HAS_NUMBER != 0) {
                const x = e.text(t);
                const small = js.smallNumber(x);
                if (n.multiple_of != NONE and !try e.multipleOf(x, small, n.multiple_of)) return false;
                if (n.maximum != NONE and e.order(x, small, n.maximum) == .gt) return false;
                if (n.exclusive_maximum != NONE and e.order(x, small, n.exclusive_maximum) != .lt) return false;
                if (n.minimum != NONE and e.order(x, small, n.minimum) == .lt) return false;
                if (n.exclusive_minimum != NONE and e.order(x, small, n.exclusive_minimum) != .gt) return false;
            },
            prog.TAG_STRING => if (n.flags & prog.F_HAS_STRING != 0) {
                const s = e.text(t);
                if (n.flags & prog.F_LENGTH != 0) {
                    if (!inBounds(@intCast(js.codePointCount(s)), n.string_length)) return false;
                }
                if (n.pattern != NONE and !try e.matches(n.pattern, s)) return false;
            },
            prog.TAG_ARRAY => if (n.flags & prog.F_HAS_ARRAY != 0) {
                if (n.flags & prog.F_ITEMS_COUNT != 0 and !inBounds(t.len, n.items_count)) return false;
                if (n.flags & prog.F_UNIQUE != 0) {
                    var i = v + 1;
                    while (i < t.end) {
                        const next = e.inst.toks[i].end;
                        var j = next;
                        while (j < t.end) {
                            if (tapeEqual(e.inst, i, e.inst, j)) return false;
                            j = e.inst.toks[j].end;
                        }
                        i = next;
                    }
                }
            },
            prog.TAG_OBJECT => if (n.flags & prog.F_HAS_OBJECT != 0) {
                if (n.flags & prog.F_PROPS_COUNT != 0 and !inBounds(t.len, n.props_count)) return false;
                var k: usize = 0;
                while (k < n.required.len) : (k += 1) {
                    const entry = e.word(n.required, k * 3 + 2);
                    if (entry != NONE) {
                        if (seen & (@as(u64, 1) << @intCast(entry)) == 0) return false;
                        continue;
                    }
                    const key = Str{ .off = e.word(n.required, k * 3), .len = e.word(n.required, k * 3 + 1) };
                    if (e.member(v, e.pstr(key)) == null) return false;
                }
                k = 0;
                while (k < n.dependent_required.len) : (k += 1) {
                    const key = Str{ .off = e.word(n.dependent_required, k * 4), .len = e.word(n.dependent_required, k * 4 + 1) };
                    if (e.member(v, e.pstr(key)) == null) continue;
                    const names = List{ .off = e.word(n.dependent_required, k * 4 + 2), .len = e.word(n.dependent_required, k * 4 + 3) };
                    for (0..names.len) |m| {
                        const name = Str{ .off = e.word(names, m * 2), .len = e.word(names, m * 2 + 1) };
                        if (e.member(v, e.pstr(name)) == null) return false;
                    }
                }
            },
            else => {},
        }
        return true;
    }

    // Orders an instance number against a schema number, exactly. When
    // both fit as scaled integers that is one multiply each.
    fn order(e: *const Eval, x: []const u8, small: ?js.SmallNumber, num: u32) std.math.Order {
        const y = e.p.nums[num];
        if (small) |a| if (y.small != 0) {
            if (scaled(a, y)) |pair| return std.math.order(pair[0], pair[1]);
        };
        return js.compareNumbers(x, e.pstr(y.text));
    }

    fn multipleOf(e: *const Eval, x: []const u8, small: ?js.SmallNumber, num: u32) Error!bool {
        const m = e.p.nums[num];
        if (small) |a| if (m.small != 0) {
            if (scaled(a, m)) |pair| {
                if (pair[1] == 0) return false;
                return @rem(pair[0], pair[1]) == 0;
            }
        };
        return js.isMultipleOf(.{ .text = x }, .{ .text = e.pstr(m.text) });
    }

    fn equal(e: *const Eval, v: u32, value_tok: u32) bool {
        return tapeEqual(e.inst, v, .{ .toks = e.p.toks, .base = e.p.bytes }, value_tok);
    }
};

// Both numbers as integers counting the same power of ten, or null when
// scaling would overflow.
fn scaled(a: js.SmallNumber, b: prog.Num) ?[2]i64 {
    if (a.places == b.places) return .{ a.value, b.smallValue() };
    const places = @max(a.places, b.places);
    const x = @mulWithOverflow(a.value, js.pow10[places - a.places]);
    const y = @mulWithOverflow(b.smallValue(), js.pow10[places - b.places]);
    if (x[1] != 0 or y[1] != 0) return null;
    return .{ x[0], y[0] };
}

fn inBounds(count: u32, b: Bounds) bool {
    return count >= b.min and count < b.max_excl;
}

// JSON equality across two tapes: numbers by exact value, objects regardless
// of member order.
pub fn tapeEqual(a: Tape, i: u32, b: Tape, j: u32) bool {
    const x = a.toks[i];
    const y = b.toks[j];
    if (x.tag != y.tag) return false;
    switch (x.tag) {
        prog.TAG_NULL, prog.TAG_FALSE, prog.TAG_TRUE => return true,
        prog.TAG_NUMBER => return js.compareNumbers(a.base[x.off..][0..x.len], b.base[y.off..][0..y.len]) == .eq,
        prog.TAG_STRING => return x.len == y.len and std.mem.eql(u8, a.base[x.off..][0..x.len], b.base[y.off..][0..y.len]),
        prog.TAG_ARRAY => {
            if (x.len != y.len) return false;
            var p = i + 1;
            var q = j + 1;
            while (p < x.end) {
                if (!tapeEqual(a, p, b, q)) return false;
                p = a.toks[p].end;
                q = b.toks[q].end;
            }
            return true;
        },
        else => {
            if (x.len != y.len) return false;
            var p = i + 1;
            outer: while (p < x.end) {
                const key = a.toks[p];
                const name = a.base[key.off..][0..key.len];
                var q = j + 1;
                while (q < y.end) {
                    const other = b.toks[q];
                    if (other.len == key.len and std.mem.eql(u8, b.base[other.off..][0..other.len], name)) {
                        if (!tapeEqual(a, p + 1, b, q + 1)) return false;
                        p = a.toks[p + 1].end;
                        continue :outer;
                    }
                    q = b.toks[q + 1].end;
                }
                return false;
            }
            return true;
        },
    }
}

fn bitSet(bits: []const u64, i: usize) bool {
    return (bits[i / 64] >> @intCast(i % 64)) & 1 != 0;
}

fn setBit(bits: []u64, i: usize) void {
    bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
}

fn orBits(dst: []u64, src: []const u64) void {
    for (dst, src) |*d, s| d.* |= s;
}

fn run(input_size: u32) Error!bool {
    const p = try loadProgram();
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    arena_fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var parser = Parser{ .src = text_buf[0..input_size] };
    try parser.parse();
    const cache = try arena_fba.allocator().alloc(?*Matcher, p.regexes.len);
    @memset(cache, null);
    var e = Eval{ .p = p, .inst = .{ .toks = &toks_buf, .base = &text_buf }, .regex_cache = cache };
    return e.validate(p.root, 0, null);
}

fn testParse(src: []const u8) Error!u32 {
    @memcpy(text_buf[0..src.len], src);
    var p = Parser{ .src = text_buf[0..src.len] };
    try p.parse();
    return p.n;
}

test "tape records counts, ends and decoded strings" {
    const n = try testParse(" {\"a\" : [1, {}, []], \"b\\u00e9\\n\":\"x\"} ");
    // object, "a", array, 1, {}, [], key, "x"
    try std.testing.expectEqual(@as(u32, 8), n);
    const t = toks_buf[0..n];
    try std.testing.expectEqual(prog.TAG_OBJECT, t[0].tag);
    try std.testing.expectEqual(@as(u32, 2), t[0].len);
    try std.testing.expectEqual(@as(u32, 8), t[0].end);
    try std.testing.expectEqual(prog.TAG_ARRAY, t[2].tag);
    try std.testing.expectEqual(@as(u32, 3), t[2].len);
    try std.testing.expectEqual(@as(u32, 6), t[2].end);
    try std.testing.expectEqual(@as(u32, 0), t[4].len);
    try std.testing.expectEqual(@as(u32, 5), t[4].end);
    try std.testing.expectEqualStrings("b\u{e9}\n", text_buf[t[6].off..][0..t[6].len]);
    try std.testing.expectEqualStrings("x", text_buf[t[7].off..][0..t[7].len]);
}

test "tape parser rejects what JSON does not allow" {
    const bad = [_][]const u8{ "", " ", "[1,]", "[,1]", "{\"a\":1,}", "{\"a\" 1}", "{1:2}", "[1 2]", "01", "1.", "-", "\"a", "\"\\x\"", "\"\x01\"", "\"\xff\"", "tru", "[]]", "{}{}", "\"abcdefghijklmn\x1f\"" };
    for (bad) |src| try std.testing.expectError(error.InvalidJson, testParse(src));
    var deep: [MAX_DEPTH + 1]u8 = undefined;
    @memset(&deep, '[');
    try std.testing.expectError(error.TooDeep, testParse(&deep));
}

test "eight-byte string scan agrees with a byte loop" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const alphabet = "abc\"\\\x01\x7f\xc3\xa9 ";
    var src: [40]u8 = undefined;
    for (0..20000) |_| {
        const len = r.intRangeAtMost(usize, 1, src.len - 1);
        src[0] = '"';
        for (src[1..len]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        // Reference: where the string ends, or that it is invalid.
        var i: usize = 1;
        var expect: ?usize = null;
        while (i < len) {
            const c = src[i];
            if (c == '"') {
                expect = i + 1;
                break;
            }
            if (c < 0x20) break;
            i += if (c == '\\') 2 else 1;
        }
        @memcpy(text_buf[0..len], src[0..len]);
        var p = Parser{ .src = text_buf[0..len] };
        if (p.string()) |_| {
            try std.testing.expect(expect != null);
            try std.testing.expectEqual(expect.?, p.pos);
        } else |_| {
            // Invalid escapes and UTF-8 also fail, so only check that an
            // unterminated or control-character string never passes.
        }
    }
}

test "compiled regexes agree with the shared Pike VM, cached and uncached" {
    const patterns = [_][]const u8{ "^[A-Z]{3}-\\d{4}$", "^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$", "a+", "f.o", "^$", "$", "^", "", "[0-9]{2,}", "^(cat|dog)s?$", "x$|^y", "^\\p{Letter}+$", "\\P{Letter}", "[^\\p{Letter}\\d]", "é+", "(a|b)*a(a|b){3}", "\\bcat\\b", "\\Bat", "^\\w+\\b$", "\\b" };
    const texts = [_][]const u8{ "", "a", "ABC-1234", "ABC-12345", "user@example.com", "u@e.c", "foo", "f\no", "xx12", "dogs", "cat", "a cat!", "concat", "x", "y", "zy", "éé", "πλ", "bbbabab", "aaaa", "ab\u{2028}c", "1", " ", "é1" };
    for (patterns) |pattern| {
        arena_fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
        const a = arena_fba.allocator();
        const regex = try js.compileRegex(a, pattern);
        var words: std.ArrayListUnmanaged(u32) = .empty;
        const head = try prog.appendRegex(a, a, &words, regex);
        const p = Program{ .nodes = undefined, .words = words.items.ptr, .toks = undefined, .dyns = &.{}, .regexes = &.{head}, .nums = undefined, .bytes = undefined, .root = 0 };
        const cached = try Matcher.init(p, 0);
        const uncached = try Matcher.init(p, 0);
        uncached.dfa = false;
        // Twice, so the second pass runs on cached transitions.
        for (0..2) |_| for (texts) |text| {
            const mark = scratch_fba.end_index;
            const want = try js.regexSearch(scratch_fba.allocator(), regex, text);
            scratch_fba.end_index = mark;
            try std.testing.expectEqual(want, try cached.search(text));
            try std.testing.expectEqual(want, try uncached.search(text));
        };
    }
}
