//! Assembles WebAssembly text format (WAT) into a binary module.
//!
//! The output matches WABT 1.0.42 `wat2wasm` byte for byte for valid
//! modules: the same type section order, the same element and data segment
//! encodings, minimal LEB128 sizes, and no name section. The component is an
//! assembler, not a validator. It rejects malformed text and unknown names, but
//! it does not type-check instructions. Pipe the output into
//! `application/wasm/wasm-validate-core-2.0.wasm` to validate it.
//!
//! Where WABT departs from the text spec, this follows WABT: raw control
//! characters other than newline are allowed in strings, `\u{...}` takes no
//! underscores, a single `memory.copy`/`table.copy` index is the destination,
//! 32-bit limits are not range-checked, and a type index past the declared
//! types is written as is.
//!
//! Supported: Core 2.0 (multi-value, reference types, bulk memory, SIMD),
//! relaxed SIMD, tail calls, extended constant expressions, threads atomics,
//! multi-memory and 64-bit memory limits. Not supported: exception handling,
//! typed function references, GC, annotations, and `(module binary|quote)`.
//!
//! Folded instructions use an explicit frame stack, so there is no recursion.

const std = @import("std");

const INPUT_CAP: usize = 1 << 20;
// Every construct produces fewer output bytes than the text that spells it,
// except fixed section overhead. Twice the input leaves a wide margin; the
// write guard still reports `limit` if a module ever exceeds it.
const OUTPUT_CAP: usize = 2 * INPUT_CAP + 64;
const CODE_CAP: usize = OUTPUT_CAP;
const MAX_FUNCS: usize = 1 << 16;
const MAX_TYPES: usize = 1 << 16;
const TYPE_POOL_CAP: usize = 1 << 19;
const SIG_SLOTS: usize = 2 * MAX_TYPES;
const NAME_SLOTS: usize = 1 << 17;
const MAX_NAMES: usize = NAME_SLOTS / 2;
// WABT has no nesting or locals limits, so these are sized so that no input
// within INPUT_CAP can reach them. A named local takes at least 14 bytes
// (`(local $a i32)`), an unnamed one 4 (`i32 `), a folded instruction level
// 4 (`(br` and `)`), and a label 6 (`(loop` and `)`).
const MAX_NAMED_LOCALS: usize = INPUT_CAP / 14 + 1;
const LOCAL_SLOTS: usize = 1 << 17;
const MAX_LOCALS: usize = INPUT_CAP / 4 + 1;
const MAX_DEPTH: usize = INPUT_CAP / 4 + 1;
const MAX_LABELS: usize = INPUT_CAP / 6 + 1;
const FLOAT_TEXT_CAP: usize = 1 << 12;

const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var code_buf: [CODE_CAP]u8 = undefined;

// ---------------------------------------------------------------------------
// Failure reporting

const Failure = enum(u32) {
    /// Malformed text: an unexpected token, comment, string or instruction.
    syntax = 0,
    /// An unknown or duplicate `$name`, or a type index outside the declared
    /// types when an inline signature has to be checked against it. Other
    /// out-of-range indices are left to validation.
    name = 1,
    /// A number that is malformed or out of range for its type.
    number = 2,
    /// Valid text for a feature this assembler does not implement.
    unsupported = 3,
    /// The module exceeds one of the fixed capacities.
    limit = 4,
};
const FAILURE_MODES: u32 = 5;

var fail_offset: u32 = 0;
var fail_mode: Failure = .syntax;

const Err = error{Rejected};

fn fail(offset: usize, mode: Failure) Err {
    fail_offset = @intCast(offset);
    fail_mode = mode;
    return error.Rejected;
}

// ---------------------------------------------------------------------------
// Lexer

const Kind = enum(u8) { lparen, rparen, keyword, id, num, string, reserved, eof };

const Tok = struct {
    kind: Kind,
    start: u32,
    end: u32,

    fn text(t: Tok) []const u8 {
        return src[t.start..t.end];
    }
};

var src: []const u8 = &.{};
var pos: usize = 0;

const C_ID: u8 = 1;
const C_SPACE: u8 = 2;
/// Bytes that end a run of plain string characters: `"`, `\`, newline and
/// anything outside ASCII.
const C_STR_STOP: u8 = 4;

const char_class: [256]u8 = blk: {
    var table = [_]u8{0} ** 256;
    for ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&'*+-./:<=>?@\\^_`|~") |c| table[c] |= C_ID;
    for (" \t\n\r") |c| table[c] |= C_SPACE;
    for ("\"\\\n") |c| table[c] |= C_STR_STOP;
    for (0x80..0x100) |c| table[c] |= C_STR_STOP;
    break :blk table;
};

fn isIdChar(c: u8) bool {
    return char_class[c] & C_ID != 0;
}

fn mkTok(kind: Kind, start: usize, end: usize) Tok {
    return .{ .kind = kind, .start = @intCast(start), .end = @intCast(end) };
}

fn skipSpace() Err!void {
    const s = src;
    var p = pos;
    while (true) {
        while (p < s.len and char_class[s[p]] & C_SPACE != 0) p += 1;
        if (p + 1 >= s.len or s[p + 1] != ';') break;
        if (s[p] == ';') {
            // A line comment ends at LF, CR or CRLF.
            p += 2;
            while (p < s.len and s[p] != '\n' and s[p] != '\r') p += 1;
        } else if (s[p] == '(') {
            const start = p;
            var depth: usize = 1;
            p += 2;
            while (depth > 0) {
                if (p + 1 >= s.len) return fail(start, .syntax);
                if (s[p] == '(' and s[p + 1] == ';') {
                    depth += 1;
                    p += 2;
                } else if (s[p] == ';' and s[p + 1] == ')') {
                    depth -= 1;
                    p += 2;
                } else {
                    p += 1;
                }
            }
        } else break;
    }
    pos = p;
}

// Every token is lexed once, before parsing starts. The parser looks ahead
// by rewinding `pos` and later passes revisit whole fields, so each token is
// recorded under the two positions `next` can be asked for it from: where the
// previous token ended and where the token itself starts.
const TokEntry = extern struct {
    start: u32,
    /// The kind in the top byte. Below it, the end offset, except for `(`,
    /// which always ends at `start + 1`: there it is the offset just past
    /// the matching `)`, or 0 when there is none.
    end_kind: u32,
};
const TOK_LOW: u32 = 0xffffff;
var tok_cache: [INPUT_CAP + 1]TokEntry = undefined;
/// Positions below this have an entry for the current input. A lexical error
/// stops the scan here and is reported when the parser reaches it, so that
/// errors still come in the order the parser meets them.
var lexed_upto: usize = 0;
var lex_fail_offset: u32 = 0;
var lex_fail_mode: Failure = .syntax;

fn lexAll() void {
    pos = 0;
    var at: usize = 0;
    // Open parentheses form a list through their own entries until matched.
    var open: u32 = 0;
    var open_depth: usize = 0;
    while (true) {
        const t = lex() catch {
            lexed_upto = at;
            lex_fail_offset = fail_offset;
            lex_fail_mode = fail_mode;
            break;
        };
        var low: u32 = t.end;
        if (t.kind == .lparen) {
            low = open;
            open = t.start;
            open_depth += 1;
        } else if (t.kind == .rparen and open_depth > 0) {
            const link = tok_cache[open].end_kind & TOK_LOW;
            tok_cache[open].end_kind = @as(u32, @intFromEnum(Kind.lparen)) << 24 | t.end;
            open = link;
            open_depth -= 1;
        }
        const e: TokEntry = .{ .start = t.start, .end_kind = @as(u32, @intFromEnum(t.kind)) << 24 | low };
        tok_cache[at] = e;
        tok_cache[t.start] = e;
        if (t.kind == .eof) {
            lexed_upto = src.len + 1;
            break;
        }
        at = t.end;
    }
    while (open_depth > 0) : (open_depth -= 1) {
        const link = tok_cache[open].end_kind & TOK_LOW;
        tok_cache[open].end_kind = @as(u32, @intFromEnum(Kind.lparen)) << 24;
        open = link;
    }
}

/// The offset just past the `)` matching the `(` at `start`, or 0.
fn matchEnd(start: u32) u32 {
    return tok_cache[start].end_kind & TOK_LOW;
}

fn next() Err!Tok {
    const at = pos;
    if (at >= lexed_upto) return fail(lex_fail_offset, lex_fail_mode);
    const e = tok_cache[at];
    const kind: Kind = @enumFromInt(e.end_kind >> 24);
    const end = if (kind == .lparen) e.start + 1 else e.end_kind & TOK_LOW;
    pos = end;
    return .{ .kind = kind, .start = e.start, .end = end };
}

fn lex() Err!Tok {
    try skipSpace();
    const s = src;
    const start = pos;
    if (start >= s.len) return mkTok(.eof, start, start);
    const c = s[start];
    var p = start + 1;
    switch (c) {
        '(' => {
            if (p < s.len and s[p] == '@') return fail(start, .unsupported);
            pos = p;
            return mkTok(.lparen, start, p);
        },
        ')' => {
            pos = p;
            return mkTok(.rparen, start, p);
        },
        '"' => {
            while (true) {
                while (p < s.len and char_class[s[p]] & C_STR_STOP == 0) p += 1;
                if (p >= s.len) return fail(start, .syntax);
                const ch = s[p];
                if (ch == '"') break;
                // Like WABT, only a raw newline ends a string in error; other
                // control characters pass through although the spec forbids them.
                if (ch == '\n') return fail(p, .syntax);
                if (ch >= 0x80) {
                    // Unescaped characters must be valid UTF-8; only escapes
                    // may spell arbitrary bytes.
                    const len = std.unicode.utf8ByteSequenceLength(ch) catch return fail(p, .syntax);
                    if (p + len > s.len) return fail(p, .syntax);
                    _ = std.unicode.utf8Decode(s[p .. p + len]) catch return fail(p, .syntax);
                    p += len;
                    continue;
                }
                p += 2; // A backslash and the character it escapes.
            }
            p += 1;
            // A token must end at whitespace, a parenthesis or a comment.
            if (p < s.len and (s[p] == '"' or isIdChar(s[p]))) return fail(p, .syntax);
            pos = p;
            return mkTok(.string, start, p);
        },
        else => {},
    }
    if (!isIdChar(c)) return fail(start, .syntax);
    while (p < s.len and isIdChar(s[p])) p += 1;
    if (p < s.len and s[p] == '"') return fail(p, .syntax);
    const kind: Kind = switch (c) {
        '$' => if (p - start > 1) .id else .reserved,
        'a'...'z' => .keyword,
        '0'...'9', '+', '-' => .num,
        else => .reserved,
    };
    pos = p;
    return mkTok(kind, start, p);
}

fn load64(s: []const u8) u64 {
    return std.mem.readInt(u64, s[0..8], .little);
}

fn load32(s: []const u8) u32 {
    return std.mem.readInt(u32, s[0..4], .little);
}

/// The 1 to 7 bytes of `s` as one word, without reading past them.
fn loadTail(s: []const u8) u64 {
    const n = s.len;
    if (n >= 4) return load32(s) | @as(u64, load32(s[n - 4 ..])) << @intCast(8 * (n - 4));
    return s[0] | @as(u64, s[n >> 1]) << 8 | @as(u64, s[n - 1]) << 16;
}

/// Hashes names and keywords a word at a time; they are mostly short enough
/// to take one or two steps.
fn hashBytes(seed: u32, s: []const u8) u32 {
    const k: u64 = 0x9e3779b97f4a7c15;
    var h: u64 = (@as(u64, seed) << 32 | s.len) *% k;
    var rest = s;
    while (rest.len >= 8) : (rest = rest[8..]) {
        h = (h ^ load64(rest)) *% k;
        h ^= h >> 32;
    }
    if (rest.len > 0) {
        h = (h ^ loadTail(rest)) *% k;
        h ^= h >> 32;
    }
    return @truncate((h *% k) >> 32);
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    const n = a.len;
    if (n != b.len) return false;
    if (n < 8) return n == 0 or loadTail(a) == loadTail(b);
    var i: usize = 0;
    while (i + 8 < n) : (i += 8) {
        if (load64(a[i..]) != load64(b[i..])) return false;
    }
    return load64(a[n - 8 ..]) == load64(b[n - 8 ..]);
}

fn peek() Err!Tok {
    const save = pos;
    defer pos = save;
    return next();
}

fn isKw(t: Tok, s: []const u8) bool {
    return t.kind == .keyword and eqlBytes(t.text(), s);
}

fn isVar(t: Tok) bool {
    return t.kind == .id or t.kind == .num;
}

fn expect(kind: Kind) Err!Tok {
    const t = try next();
    if (t.kind != kind) return fail(t.start, .syntax);
    return t;
}

fn expectKw(s: []const u8) Err!void {
    const t = try next();
    if (!isKw(t, s)) return fail(t.start, .syntax);
}

/// True when the next tokens are `(` followed by keyword `s`.
fn peekForm(s: []const u8) Err!bool {
    const save = pos;
    defer pos = save;
    if ((try next()).kind != .lparen) return false;
    return isKw(try next(), s);
}

/// Consumes `( s` when the next tokens are that form.
fn openForm(s: []const u8) Err!bool {
    if (!try peekForm(s)) return false;
    _ = try next();
    _ = try next();
    return true;
}

/// Skips to just after the `)` that closes the current form.
fn skipBalanced() Err!void {
    var depth: usize = 1;
    while (depth > 0) {
        const t = try next();
        switch (t.kind) {
            .lparen => {
                const m = matchEnd(t.start);
                if (m != 0) pos = m else depth += 1;
            },
            .rparen => depth -= 1,
            .eof => return fail(t.start, .syntax),
            else => {},
        }
    }
}

fn optId() Err!?Tok {
    const t = try peek();
    if (t.kind != .id) return null;
    _ = try next();
    return t;
}

// ---------------------------------------------------------------------------
// Numbers

fn digitValue(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 255,
    };
}

/// Parses `num` or `0x hexnum`, with `_` allowed only between digits.
fn parseNat(s: []const u8) ?u64 {
    var i: usize = 0;
    var base: u64 = 10;
    if (s.len > 2 and s[0] == '0' and s[1] == 'x') {
        base = 16;
        i = 2;
    }
    if (i >= s.len) return null;
    var value: u64 = 0;
    var after_digit = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') {
            if (!after_digit) return null;
            after_digit = false;
            continue;
        }
        const d = digitValue(c);
        if (d >= base) return null;
        const mul = @mulWithOverflow(value, base);
        if (mul[1] != 0) return null;
        const add = @addWithOverflow(mul[0], d);
        if (add[1] != 0) return null;
        value = add[0];
        after_digit = true;
    }
    if (!after_digit) return null;
    return value;
}

fn natTok(t: Tok) Err!u64 {
    if (t.kind != .num) return fail(t.start, .syntax);
    return parseNat(t.text()) orelse fail(t.start, .number);
}

fn u32Tok(t: Tok) Err!u32 {
    const v = try natTok(t);
    if (v > std.math.maxInt(u32)) return fail(t.start, .number);
    return @intCast(v);
}

/// Parses an `iN` literal and returns its two's-complement bit pattern.
fn intTok(t: Tok, comptime bits: u7) Err!u64 {
    if (t.kind != .num) return fail(t.start, .syntax);
    var s = t.text();
    var negative = false;
    if (s[0] == '+' or s[0] == '-') {
        negative = s[0] == '-';
        s = s[1..];
    }
    const magnitude = parseNat(s) orelse return fail(t.start, .number);
    const mask: u64 = if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << bits) - 1;
    if (negative) {
        if (magnitude > @as(u64, 1) << (bits - 1)) return fail(t.start, .number);
        return (0 -% magnitude) & mask;
    }
    if (magnitude > mask) return fail(t.start, .number);
    return magnitude;
}

fn FloatBits(comptime T: type) type {
    return if (T == f32) u32 else u64;
}

fn floatTok(t: Tok, comptime T: type) Err!FloatBits(T) {
    const Bits = FloatBits(T);
    const mant_bits: u6 = if (T == f32) 23 else 52;
    const exp_mask: Bits = if (T == f32) 0x7f800000 else 0x7ff0000000000000;
    const sign_bit: Bits = @as(Bits, 1) << (if (T == f32) 31 else 63);
    const mant_mask: Bits = (@as(Bits, 1) << mant_bits) - 1;

    if (t.kind != .num and t.kind != .keyword) return fail(t.start, .syntax);
    var s = t.text();
    var negative = false;
    if (s[0] == '+' or s[0] == '-') {
        negative = s[0] == '-';
        s = s[1..];
    }
    var bits: Bits = undefined;
    if (std.mem.eql(u8, s, "inf")) {
        bits = exp_mask;
    } else if (std.mem.eql(u8, s, "nan")) {
        bits = exp_mask | (@as(Bits, 1) << (mant_bits - 1));
    } else if (std.mem.startsWith(u8, s, "nan:0x")) {
        const payload = parseNat(s[4..]) orelse return fail(t.start, .number);
        if (payload == 0 or payload > mant_mask) return fail(t.start, .number);
        bits = exp_mask | @as(Bits, @intCast(payload));
    } else if (s.len > 2 and s[0] == '0' and s[1] == 'x') {
        const v = hexFloatBits(s[2..], mant_bits, if (T == f32) 8 else 11) catch |e| {
            return fail(t.start, if (e == error.Syntax) .syntax else .number);
        };
        bits = @intCast(v);
    } else {
        if (!decimalFloatSyntax(s)) return fail(t.start, .syntax);
        var n: usize = 0;
        for (s) |c| n += @intFromBool(c != '_');
        if (n > FLOAT_TEXT_CAP) return fail(t.start, .limit);
        const v = decimalFloatBits(s, mant_bits, if (T == f32) 8 else 11) orelse return fail(t.start, .number);
        bits = @intCast(v);
    }
    if (negative) bits |= sign_bit;
    return bits;
}

/// Checks a decimal float: `num ('.' num?)? ([eE] [+-]? num)?`.
fn decimalFloatSyntax(s: []const u8) bool {
    var i: usize = 0;
    i = digitRun(s, i, 10) orelse return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i < s.len and s[i] >= '0' and s[i] <= '9') i = digitRun(s, i, 10) orelse return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        i = digitRun(s, i, 10) orelse return false;
    }
    return i == s.len;
}

/// Returns the end of a digit run with `_` only between digits.
fn digitRun(s: []const u8, start: usize, base: u8) ?usize {
    var i = start;
    var after_digit = false;
    while (i < s.len) : (i += 1) {
        if (s[i] == '_') {
            if (!after_digit) return null;
            after_digit = false;
        } else if (digitValue(s[i]) < base) {
            after_digit = true;
        } else break;
    }
    if (!after_digit) return null;
    return i;
}

/// Converts `hexnum ('.' hexfrac?)? ([pP] [+-]? num)?` with round-to-nearest,
/// ties-to-even. Returns the unsigned bit pattern for the target format.
fn hexFloatBits(s: []const u8, comptime mant_bits: u6, comptime exp_bits: u6) error{ Syntax, Range }!u64 {
    var m: u64 = 0;
    var e: i64 = 0;
    var sticky = false;
    var i: usize = 0;

    const int_end = digitRun(s, 0, 16) orelse return error.Syntax;
    while (i < int_end) : (i += 1) {
        if (s[i] == '_') continue;
        const d = digitValue(s[i]);
        if (m >> 60 == 0) {
            m = m * 16 + d;
        } else {
            e += 4;
            if (d != 0) sticky = true;
        }
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i < s.len and digitValue(s[i]) < 16) {
            const frac_end = digitRun(s, i, 16) orelse return error.Syntax;
            while (i < frac_end) : (i += 1) {
                if (s[i] == '_') continue;
                const d = digitValue(s[i]);
                if (m >> 60 == 0) {
                    m = m * 16 + d;
                    e -= 4;
                } else if (d != 0) sticky = true;
            }
        }
    }
    if (i < s.len and (s[i] == 'p' or s[i] == 'P')) {
        i += 1;
        var exp_negative = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            exp_negative = s[i] == '-';
            i += 1;
        }
        const exp_end = digitRun(s, i, 10) orelse return error.Syntax;
        var exp: i64 = 0;
        while (i < exp_end) : (i += 1) {
            if (s[i] == '_') continue;
            if (exp < 1 << 24) exp = exp * 10 + (s[i] - '0');
        }
        e += if (exp_negative) -exp else exp;
    }
    if (i != s.len) return error.Syntax;
    if (m == 0) return 0;

    const bias: i64 = (@as(i64, 1) << (exp_bits - 1)) - 1;
    const emin: i64 = 1 - bias;
    const top: i64 = 63 - @as(i64, @clz(m));
    var exponent: i64 = top + e;
    var shift: i64 = top - mant_bits;
    if (exponent < emin) shift += emin - exponent;

    var q: u64 = 0;
    if (shift > 64) {
        q = 0;
    } else if (shift > 0) {
        const sh: u7 = @intCast(shift);
        const wide: u128 = m;
        const rem: u128 = wide & ((@as(u128, 1) << sh) - 1);
        const half: u128 = @as(u128, 1) << (sh - 1);
        q = @intCast(wide >> sh);
        if (rem > half or (rem == half and (sticky or (q & 1) == 1))) q += 1;
    } else {
        q = m << @intCast(-shift);
    }

    if (exponent < emin) return q; // Subnormal; q == 2^mant_bits is the smallest normal.
    if (q == @as(u64, 1) << (mant_bits + 1)) {
        q >>= 1;
        exponent += 1;
    }
    if (exponent > bias) return error.Range;
    const biased: u64 = @intCast(exponent + bias);
    return (biased << mant_bits) | (q & ((@as(u64, 1) << mant_bits) - 1));
}

// Decimal floats are converted exactly: the digits are held as a decimal
// fraction `0.d0 d1 d2 ... x 10^dp` and multiplied or divided by powers of
// two until the mantissa can be read off, so no digit is ever dropped and
// the result is correctly rounded for any length of input. A literal has at
// most FLOAT_TEXT_CAP digits and each halving adds at most one, with fewer
// than 1300 halvings for a value in range. This is a fraction of the size of
// `std.fmt.parseFloat`, which more than doubled the module's data.
const DEC_CAP: usize = FLOAT_TEXT_CAP + 4096;

var dec_d: [DEC_CAP]u8 = undefined;
var dec_nd: usize = 0;
var dec_dp: i32 = 0;

fn decTrim() void {
    while (dec_nd > 0 and dec_d[dec_nd - 1] == 0) dec_nd -= 1;
    if (dec_nd == 0) dec_dp = 0;
}

/// Divides by 2^k, for k up to 56.
fn decShiftRight(k: u6) void {
    var r: usize = 0;
    var w: usize = 0;
    var n: u64 = 0;
    while (n >> k == 0) : (r += 1) {
        if (r >= dec_nd) {
            if (n == 0) {
                dec_nd = 0;
                dec_dp = 0;
                return;
            }
            while (n >> k == 0) {
                n *= 10;
                r += 1;
            }
            break;
        }
        n = n * 10 + dec_d[r];
    }
    dec_dp -= @as(i32, @intCast(r)) - 1;
    const mask: u64 = (@as(u64, 1) << k) - 1;
    while (r < dec_nd) : (r += 1) {
        const c: u64 = dec_d[r];
        dec_d[w] = @truncate(n >> k);
        w += 1;
        n = (n & mask) * 10 + c;
    }
    while (n > 0 and w < DEC_CAP) {
        dec_d[w] = @truncate(n >> k);
        w += 1;
        n = (n & mask) * 10;
    }
    dec_nd = w;
    decTrim();
}

/// Multiplies by 2^k, for k up to 56.
fn decShiftLeft(k: u6) void {
    var carry: u64 = 0;
    var i = dec_nd;
    while (i > 0) {
        i -= 1;
        const n = (@as(u64, dec_d[i]) << k) + carry;
        const q = n / 10;
        dec_d[i] = @truncate(n - q * 10);
        carry = q;
    }
    if (carry > 0) {
        var extra: usize = 0;
        var c = carry;
        while (c > 0) : (c /= 10) extra += 1;
        std.mem.copyBackwards(u8, dec_d[extra..][0..dec_nd], dec_d[0..dec_nd]);
        i = extra;
        while (i > 0) {
            i -= 1;
            const q = carry / 10;
            dec_d[i] = @truncate(carry - q * 10);
            carry = q;
        }
        dec_nd += extra;
        dec_dp += @intCast(extra);
    }
    decTrim();
}

fn decShift(k: i32) void {
    var n = k;
    while (n > 0) {
        const step = @min(n, 56);
        decShiftLeft(@intCast(step));
        n -= step;
    }
    while (n < 0) {
        const step = @min(-n, 56);
        decShiftRight(@intCast(step));
        n += step;
    }
}

/// Rounds the decimal to an integer, ties to even.
fn decRoundedInteger() u64 {
    var n: u64 = 0;
    var i: usize = 0;
    const dp: usize = if (dec_dp > 0) @intCast(dec_dp) else 0;
    while (i < dp and i < dec_nd) : (i += 1) n = n *% 10 +% dec_d[i];
    while (i < dp) : (i += 1) n *%= 10;
    if (dec_dp >= 0 and dp < dec_nd) {
        var up = dec_d[dp] >= 5;
        // Trailing zeros are trimmed, so a lone 5 is exactly halfway.
        if (dec_d[dp] == 5 and dp + 1 == dec_nd) up = dp > 0 and dec_d[dp - 1] & 1 == 1;
        if (up) n += 1;
    }
    return n;
}

/// Converts a decimal float whose syntax has been checked. Values too small
/// to represent round to zero; values too large return null.
fn decimalFloatBits(s: []const u8, comptime mant_bits: u6, comptime exp_bits: u6) ?u64 {
    const powtab = [9]u8{ 1, 3, 6, 9, 13, 16, 19, 23, 26 };

    dec_nd = 0;
    dec_dp = 0;
    var saw_dot = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') continue;
        if (c == '.') {
            saw_dot = true;
            dec_dp = @intCast(dec_nd);
            continue;
        }
        if (c < '0' or c > '9') break;
        if (c == '0' and dec_nd == 0) {
            dec_dp -= 1;
            continue;
        }
        dec_d[dec_nd] = c - '0';
        dec_nd += 1;
    }
    if (!saw_dot) dec_dp = @intCast(dec_nd);
    if (i < s.len) {
        i += 1;
        var exp_negative = false;
        if (s[i] == '+' or s[i] == '-') {
            exp_negative = s[i] == '-';
            i += 1;
        }
        var e: i32 = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '_') continue;
            if (e < 100000) e = e * 10 + (s[i] - '0');
        }
        dec_dp += if (exp_negative) -e else e;
    }
    decTrim();

    if (dec_nd == 0) return 0;
    if (dec_dp > 310) return null;
    if (dec_dp < -330) return 0;

    const bias: i32 = (@as(i32, 1) << (exp_bits - 1)) - 1;
    const emin: i32 = 1 - bias;
    var exp: i32 = 0;
    // Scale into [0.5, 1), tracking the binary exponent.
    while (dec_dp > 0) {
        const n: i32 = if (dec_dp >= powtab.len) 27 else powtab[@intCast(dec_dp)];
        decShift(-n);
        exp += n;
    }
    while (dec_dp < 0 or (dec_dp == 0 and dec_d[0] < 5)) {
        const n: i32 = if (-dec_dp >= powtab.len) 27 else powtab[@intCast(-dec_dp)];
        decShift(n);
        exp -= n;
    }
    // Now in [1, 2).
    exp -= 1;
    if (exp < emin) {
        const n = emin - exp;
        decShift(-n);
        exp += n;
    }
    if (exp > bias) return null;
    decShift(1 + @as(i32, mant_bits));
    var mant = decRoundedInteger();
    if (mant == @as(u64, 2) << mant_bits) {
        mant >>= 1;
        exp += 1;
        if (exp > bias) return null;
    }
    var biased: u64 = @intCast(exp + bias);
    // Subnormal.
    if (mant & (@as(u64, 1) << mant_bits) == 0) biased = 0;
    return (biased << mant_bits) | (mant & ((@as(u64, 1) << mant_bits) - 1));
}

// ---------------------------------------------------------------------------
// Output

const Out = struct {
    buf: []u8,
    len: usize = 0,
    /// Bytes from `top` to the end of `buf` are the encoded folded
    /// instructions that are still waiting for their operands.
    top: usize,

    fn init(buf: []u8) Out {
        return .{ .buf = buf, .top = buf.len };
    }

    fn byte(o: *Out, b: u8) Err!void {
        if (o.len >= o.top) return fail(pos, .limit);
        o.buf[o.len] = b;
        o.len += 1;
    }

    fn bytes(o: *Out, s: []const u8) Err!void {
        if (s.len > o.top - o.len) return fail(pos, .limit);
        @memcpy(o.buf[o.len..][0..s.len], s);
        o.len += s.len;
    }

    fn uleb(o: *Out, value: u64) Err!void {
        var v = value;
        while (true) {
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) return o.byte(b);
            try o.byte(b | 0x80);
        }
    }

    fn sleb(o: *Out, value: i64) Err!void {
        var v = value;
        while (true) {
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            const done = (v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0);
            if (done) return o.byte(b);
            try o.byte(b | 0x80);
        }
    }

    fn uintLe(o: *Out, value: u64, n: usize) Err!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try o.byte(@truncate(value >> @intCast(8 * i)));
    }

    /// Reserves room for a size prefix. `end` writes the minimal LEB128.
    fn begin(o: *Out) Err!usize {
        if (o.top - o.len < 5) return fail(pos, .limit);
        const start = o.len;
        o.len += 5;
        return start;
    }

    fn end(o: *Out, start: usize) void {
        const size = o.len - start - 5;
        var leb: [5]u8 = undefined;
        var n: usize = 0;
        var v = size;
        while (true) {
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) {
                leb[n] = b;
                n += 1;
                break;
            }
            leb[n] = b | 0x80;
            n += 1;
        }
        @memcpy(o.buf[start..][0..n], leb[0..n]);
        std.mem.copyForwards(u8, o.buf[start + n .. o.len - (5 - n)], o.buf[start + 5 .. o.len]);
        o.len -= 5 - n;
    }

    /// Moves the bytes written since `from` onto the pending stack and
    /// returns how many there were. They always fit: they already lie below
    /// `top`.
    fn stash(o: *Out, from: usize) u32 {
        const n = o.len - from;
        var i = n;
        while (i > 0) {
            i -= 1;
            o.buf[o.top - n + i] = o.buf[from + i];
        }
        o.top -= n;
        o.len = from;
        return @intCast(n);
    }

    /// Appends the newest `n` pending bytes to the output.
    fn unstash(o: *Out, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) o.buf[o.len + i] = o.buf[o.top + i];
        o.len += n;
        o.top += n;
    }
};

// ---------------------------------------------------------------------------
// Names

const Space = enum(u8) { type, func, table, memory, global, elem, data, local };

const NameSlot = struct { start: u32, meta: u32, index: u32, gen: u32 };

const NameTable = struct {
    slots: []NameSlot,
    gen: u32 = 0,
    count: usize = 0,
    cap: usize,

    fn reset(table: *NameTable) void {
        table.gen +%= 1;
        if (table.gen == 0) {
            @memset(table.slots, .{ .start = 0, .meta = 0, .index = 0, .gen = 0 });
            table.gen = 1;
        }
        table.count = 0;
    }

    fn hash(space: Space, s: []const u8) u32 {
        return hashBytes(@intFromEnum(space), s);
    }

    fn matches(slot: NameSlot, space: Space, s: []const u8) bool {
        if (slot.meta != (@as(u32, @intCast(s.len)) << 3 | @intFromEnum(space))) return false;
        return eqlBytes(src[slot.start..][0..s.len], s);
    }

    fn define(table: *NameTable, space: Space, t: Tok, index: u32) Err!void {
        const s = t.text();
        const mask = table.slots.len - 1;
        var h: usize = hash(space, s) & mask;
        while (table.slots[h].gen == table.gen) : (h = (h + 1) & mask) {
            if (matches(table.slots[h], space, s)) return fail(t.start, .name);
        }
        if (table.count >= table.cap) return fail(t.start, .limit);
        table.slots[h] = .{
            .start = t.start,
            .meta = @as(u32, @intCast(s.len)) << 3 | @intFromEnum(space),
            .index = index,
            .gen = table.gen,
        };
        table.count += 1;
    }

    fn lookup(table: *const NameTable, space: Space, s: []const u8) ?u32 {
        const mask = table.slots.len - 1;
        var h: usize = hash(space, s) & mask;
        while (table.slots[h].gen == table.gen) : (h = (h + 1) & mask) {
            if (matches(table.slots[h], space, s)) return table.slots[h].index;
        }
        return null;
    }
};

var name_slots: [NAME_SLOTS]NameSlot = std.mem.zeroes([NAME_SLOTS]NameSlot);
var local_slots: [LOCAL_SLOTS]NameSlot = std.mem.zeroes([LOCAL_SLOTS]NameSlot);
var names: NameTable = .{ .slots = &name_slots, .cap = MAX_NAMES };
var locals: NameTable = .{ .slots = &local_slots, .cap = MAX_NAMED_LOCALS };

fn varIndex(space: Space, t: Tok) Err!u32 {
    switch (t.kind) {
        .id => {
            const table = if (space == .local) &locals else &names;
            return table.lookup(space, t.text()) orelse fail(t.start, .name);
        },
        .num => return u32Tok(t),
        else => return fail(t.start, .syntax),
    }
}

// ---------------------------------------------------------------------------
// Types

var type_off: [MAX_TYPES]u32 = undefined;
var type_np: [MAX_TYPES]u32 = undefined;
var type_nr: [MAX_TYPES]u32 = undefined;
var type_count: u32 = 0;
var type_pool: [TYPE_POOL_CAP]u8 = undefined;
var pool_len: usize = 0;
var sig_index: [SIG_SLOTS]u32 = std.mem.zeroes([SIG_SLOTS]u32);
var sig_gen: [SIG_SLOTS]u32 = std.mem.zeroes([SIG_SLOTS]u32);
var sig_generation: u32 = 0;

const Sig = struct { np: u32, nr: u32 };

fn valType(t: Tok) Err!u8 {
    if (t.kind == .lparen) return fail(t.start, .unsupported);
    if (t.kind != .keyword) return fail(t.start, .syntax);
    const s = t.text();
    const table = [_]struct { []const u8, u8 }{
        .{ "i32", 0x7f },     .{ "i64", 0x7e },       .{ "f32", 0x7d }, .{ "f64", 0x7c },
        .{ "v128", 0x7b },    .{ "funcref", 0x70 },   .{ "externref", 0x6f },
    };
    for (table) |entry| if (std.mem.eql(u8, s, entry[0])) return entry[1];
    return fail(t.start, .syntax);
}

fn isRefTypeKw(t: Tok) bool {
    return isKw(t, "funcref") or isKw(t, "externref");
}

fn poolPut(at: usize, b: u8) Err!void {
    if (at >= TYPE_POOL_CAP) return fail(pos, .limit);
    type_pool[at] = b;
}

/// What `(param $x t)` means where a signature appears.
const ParamNames = enum {
    /// Function definitions: the names become locals.
    bind,
    /// Type definitions: the names are allowed, ignored and may repeat.
    allow,
    /// Imports: the names are ignored but must be distinct.
    distinct,
    /// Block types and `call_indirect`: names are malformed.
    forbid,
};

/// Parses `(param ...)* (result ...)*` into the pool tail without committing.
fn parseSig(param_names: ParamNames) Err!Sig {
    var sig: Sig = .{ .np = 0, .nr = 0 };
    if (param_names == .distinct) locals.reset();
    while (try openForm("param")) {
        if (try optId()) |id| {
            switch (param_names) {
                .forbid => return fail(id.start, .syntax),
                .bind, .distinct => try locals.define(.local, id, sig.np),
                .allow => {},
            }
            try poolPut(pool_len + sig.np, try valType(try next()));
            sig.np += 1;
            _ = try expect(.rparen);
            continue;
        }
        while (true) {
            const t = try next();
            if (t.kind == .rparen) break;
            try poolPut(pool_len + sig.np, try valType(t));
            sig.np += 1;
        }
    }
    while (try openForm("result")) {
        while (true) {
            const t = try next();
            if (t.kind == .rparen) break;
            try poolPut(pool_len + sig.np + sig.nr, try valType(t));
            sig.nr += 1;
        }
    }
    return sig;
}

fn sigHash(off: usize, sig: Sig) u32 {
    var h: u32 = 2166136261 ^ sig.np;
    for (type_pool[off..][0 .. sig.np + sig.nr]) |c| h = (h ^ c) *% 16777619;
    return (h ^ sig.nr) *% 16777619;
}

fn sigEqual(index: u32, off: usize, sig: Sig) bool {
    if (type_np[index] != sig.np or type_nr[index] != sig.nr) return false;
    const n = sig.np + sig.nr;
    return std.mem.eql(u8, type_pool[type_off[index]..][0..n], type_pool[off..][0..n]);
}

/// Finds the first type with the pending signature, or the free slot for it.
fn sigSlot(sig: Sig) struct { slot: usize, found: ?u32 } {
    var h: usize = sigHash(pool_len, sig) & (SIG_SLOTS - 1);
    while (sig_gen[h] == sig_generation) : (h = (h + 1) & (SIG_SLOTS - 1)) {
        if (sigEqual(sig_index[h], pool_len, sig)) return .{ .slot = h, .found = sig_index[h] };
    }
    return .{ .slot = h, .found = null };
}

fn appendType(sig: Sig) Err!u32 {
    if (type_count >= MAX_TYPES) return fail(pos, .limit);
    const index = type_count;
    type_off[index] = @intCast(pool_len);
    type_np[index] = sig.np;
    type_nr[index] = sig.nr;
    pool_len += sig.np + sig.nr;
    type_count += 1;
    return index;
}

/// An explicit `(type ...)` always gets its own index. The first type with a
/// signature is the one that implicit type uses match.
fn addExplicitType(sig: Sig) Err!void {
    const found = sigSlot(sig);
    const index = try appendType(sig);
    if (found.found == null) {
        sig_gen[found.slot] = sig_generation;
        sig_index[found.slot] = index;
    }
}

/// Returns the first type with the pending signature, appending one if none.
fn internSig(sig: Sig) Err!u32 {
    const found = sigSlot(sig);
    if (found.found) |index| return index;
    const index = try appendType(sig);
    sig_gen[found.slot] = sig_generation;
    sig_index[found.slot] = index;
    return index;
}

/// Parses `(type x)? (param ...)* (result ...)*`. With `(type x)`, an inline
/// signature is optional but must match the type exactly.
fn parseTypeUseParts(param_names: ParamNames) Err!struct { explicit: ?u32, sig: Sig } {
    var explicit: ?u32 = null;
    var index_start: u32 = 0;
    if (try openForm("type")) {
        const t = try next();
        explicit = try varIndex(.type, t);
        index_start = t.start;
        _ = try expect(.rparen);
    }
    const sig_start = (try peek()).start;
    const sig = try parseSig(param_names);
    if (explicit) |index| {
        // Like WABT, a numeric index past the declared types is written as
        // is unless an inline signature has to be checked against it.
        if (sig.np + sig.nr != 0) {
            if (index >= type_count) return fail(index_start, .name);
            if (!sigEqual(index, pool_len, sig)) return fail(sig_start, .syntax);
        }
    }
    return .{ .explicit = explicit, .sig = sig };
}

/// Returns the type index of a type use. When `resolve` is false nothing is
/// interned and the result is unused.
fn parseTypeUse(param_names: ParamNames, resolve: bool) Err!u32 {
    const use = try parseTypeUseParts(param_names);
    if (use.explicit) |index| return index;
    if (!resolve) return 0;
    return internSig(use.sig);
}

const BlockType = union(enum) { empty, val: u8, index: u32 };

fn parseBlockType(resolve: bool) Err!BlockType {
    const use = try parseTypeUseParts(.forbid);
    const sig = use.sig;
    if (use.explicit) |index| {
        // WABT writes a missing type as an empty block type.
        if (index >= type_count) return .empty;
        // WABT prints a single-result type use in the short form.
        if (type_np[index] == 0 and type_nr[index] == 0) return .empty;
        if (type_np[index] == 0 and type_nr[index] == 1) return .{ .val = type_pool[type_off[index]] };
        return .{ .index = index };
    }
    if (sig.np == 0 and sig.nr == 0) return .empty;
    if (sig.np == 0 and sig.nr == 1) return .{ .val = type_pool[pool_len] };
    if (!resolve) return .empty;
    return .{ .index = try internSig(sig) };
}

fn writeBlockType(o: *Out, bt: BlockType) Err!void {
    switch (bt) {
        .empty => try o.byte(0x40),
        .val => |v| try o.byte(v),
        .index => |i| try o.sleb(i),
    }
}

// ---------------------------------------------------------------------------
// Instruction table

const Imm = enum(u8) {
    none,
    label,
    br_table,
    func,
    call_indirect,
    local,
    global,
    table,
    memarg,
    memarg_lane,
    lane,
    shuffle,
    i32,
    i64,
    f32,
    f64,
    v128,
    select,
    ref_null,
    mem,
    mem_copy,
    mem_init,
    data,
    table_copy,
    table_init,
    elem,
    fence,
    unsupported,
    // Structure keywords. They share the table so that one lookup classifies
    // any keyword in an instruction position.
    block,
    if_,
    then,
    else_,
    end,
};

const OpGroup = struct { prefix: u8, first: u16, imm: Imm, names: []const u8 };

fn rmw(comptime op: []const u8) []const u8 {
    return "i32.atomic.rmw." ++ op ++ ":2 i64.atomic.rmw." ++ op ++ ":3 i32.atomic.rmw8." ++ op ++
        "_u:0 i32.atomic.rmw16." ++ op ++ "_u:1 i64.atomic.rmw8." ++ op ++ "_u:0 i64.atomic.rmw16." ++ op ++
        "_u:1 i64.atomic.rmw32." ++ op ++ "_u:2 ";
}

// Names take consecutive opcodes from `first`; `_` skips one. `name:N` sets
// the natural alignment exponent of a memory access.
const op_groups = [_]OpGroup{
    .{ .prefix = 0, .first = 0x00, .imm = .none, .names = "unreachable nop" },
    .{ .prefix = 0, .first = 0x02, .imm = .block, .names = "block loop" },
    .{ .prefix = 0, .first = 0x04, .imm = .if_, .names = "if" },
    .{ .prefix = 0, .first = 0x05, .imm = .else_, .names = "else" },
    .{ .prefix = 0, .first = 0x0b, .imm = .end, .names = "end" },
    .{ .prefix = 0, .first = 0, .imm = .then, .names = "then" },
    .{ .prefix = 0, .first = 0x0c, .imm = .label, .names = "br br_if" },
    .{ .prefix = 0, .first = 0x0e, .imm = .br_table, .names = "br_table" },
    .{ .prefix = 0, .first = 0x0f, .imm = .none, .names = "return" },
    .{ .prefix = 0, .first = 0x10, .imm = .func, .names = "call" },
    .{ .prefix = 0, .first = 0x11, .imm = .call_indirect, .names = "call_indirect" },
    .{ .prefix = 0, .first = 0x12, .imm = .func, .names = "return_call" },
    .{ .prefix = 0, .first = 0x13, .imm = .call_indirect, .names = "return_call_indirect" },
    .{ .prefix = 0, .first = 0x1a, .imm = .none, .names = "drop" },
    .{ .prefix = 0, .first = 0x1b, .imm = .select, .names = "select" },
    .{ .prefix = 0, .first = 0x20, .imm = .local, .names = "local.get local.set local.tee" },
    .{ .prefix = 0, .first = 0x23, .imm = .global, .names = "global.get global.set" },
    .{ .prefix = 0, .first = 0x25, .imm = .table, .names = "table.get table.set" },
    .{ .prefix = 0, .first = 0x28, .imm = .memarg, .names = "i32.load:2 i64.load:3 f32.load:2 f64.load:3 i32.load8_s:0 i32.load8_u:0 i32.load16_s:1 i32.load16_u:1 i64.load8_s:0 i64.load8_u:0 i64.load16_s:1 i64.load16_u:1 i64.load32_s:2 i64.load32_u:2 i32.store:2 i64.store:3 f32.store:2 f64.store:3 i32.store8:0 i32.store16:1 i64.store8:0 i64.store16:1 i64.store32:2" },
    .{ .prefix = 0, .first = 0x3f, .imm = .mem, .names = "memory.size memory.grow" },
    .{ .prefix = 0, .first = 0x41, .imm = .i32, .names = "i32.const" },
    .{ .prefix = 0, .first = 0x42, .imm = .i64, .names = "i64.const" },
    .{ .prefix = 0, .first = 0x43, .imm = .f32, .names = "f32.const" },
    .{ .prefix = 0, .first = 0x44, .imm = .f64, .names = "f64.const" },
    .{ .prefix = 0, .first = 0x45, .imm = .none, .names = "i32.eqz i32.eq i32.ne i32.lt_s i32.lt_u i32.gt_s i32.gt_u i32.le_s i32.le_u i32.ge_s i32.ge_u " ++
        "i64.eqz i64.eq i64.ne i64.lt_s i64.lt_u i64.gt_s i64.gt_u i64.le_s i64.le_u i64.ge_s i64.ge_u " ++
        "f32.eq f32.ne f32.lt f32.gt f32.le f32.ge f64.eq f64.ne f64.lt f64.gt f64.le f64.ge " ++
        "i32.clz i32.ctz i32.popcnt i32.add i32.sub i32.mul i32.div_s i32.div_u i32.rem_s i32.rem_u i32.and i32.or i32.xor i32.shl i32.shr_s i32.shr_u i32.rotl i32.rotr " ++
        "i64.clz i64.ctz i64.popcnt i64.add i64.sub i64.mul i64.div_s i64.div_u i64.rem_s i64.rem_u i64.and i64.or i64.xor i64.shl i64.shr_s i64.shr_u i64.rotl i64.rotr " ++
        "f32.abs f32.neg f32.ceil f32.floor f32.trunc f32.nearest f32.sqrt f32.add f32.sub f32.mul f32.div f32.min f32.max f32.copysign " ++
        "f64.abs f64.neg f64.ceil f64.floor f64.trunc f64.nearest f64.sqrt f64.add f64.sub f64.mul f64.div f64.min f64.max f64.copysign " ++
        "i32.wrap_i64 i32.trunc_f32_s i32.trunc_f32_u i32.trunc_f64_s i32.trunc_f64_u i64.extend_i32_s i64.extend_i32_u " ++
        "i64.trunc_f32_s i64.trunc_f32_u i64.trunc_f64_s i64.trunc_f64_u f32.convert_i32_s f32.convert_i32_u f32.convert_i64_s f32.convert_i64_u f32.demote_f64 " ++
        "f64.convert_i32_s f64.convert_i32_u f64.convert_i64_s f64.convert_i64_u f64.promote_f32 " ++
        "i32.reinterpret_f32 i64.reinterpret_f64 f32.reinterpret_i32 f64.reinterpret_i64 " ++
        "i32.extend8_s i32.extend16_s i64.extend8_s i64.extend16_s i64.extend32_s" },
    .{ .prefix = 0, .first = 0xd0, .imm = .ref_null, .names = "ref.null" },
    .{ .prefix = 0, .first = 0xd1, .imm = .none, .names = "ref.is_null" },
    .{ .prefix = 0, .first = 0xd2, .imm = .func, .names = "ref.func" },

    .{ .prefix = 0xfc, .first = 0x00, .imm = .none, .names = "i32.trunc_sat_f32_s i32.trunc_sat_f32_u i32.trunc_sat_f64_s i32.trunc_sat_f64_u i64.trunc_sat_f32_s i64.trunc_sat_f32_u i64.trunc_sat_f64_s i64.trunc_sat_f64_u" },
    .{ .prefix = 0xfc, .first = 0x08, .imm = .mem_init, .names = "memory.init" },
    .{ .prefix = 0xfc, .first = 0x09, .imm = .data, .names = "data.drop" },
    .{ .prefix = 0xfc, .first = 0x0a, .imm = .mem_copy, .names = "memory.copy" },
    .{ .prefix = 0xfc, .first = 0x0b, .imm = .mem, .names = "memory.fill" },
    .{ .prefix = 0xfc, .first = 0x0c, .imm = .table_init, .names = "table.init" },
    .{ .prefix = 0xfc, .first = 0x0d, .imm = .elem, .names = "elem.drop" },
    .{ .prefix = 0xfc, .first = 0x0e, .imm = .table_copy, .names = "table.copy" },
    .{ .prefix = 0xfc, .first = 0x0f, .imm = .table, .names = "table.grow table.size table.fill" },

    .{ .prefix = 0xfd, .first = 0x00, .imm = .memarg, .names = "v128.load:4 v128.load8x8_s:3 v128.load8x8_u:3 v128.load16x4_s:3 v128.load16x4_u:3 v128.load32x2_s:3 v128.load32x2_u:3 v128.load8_splat:0 v128.load16_splat:1 v128.load32_splat:2 v128.load64_splat:3 v128.store:4" },
    .{ .prefix = 0xfd, .first = 0x0c, .imm = .v128, .names = "v128.const" },
    .{ .prefix = 0xfd, .first = 0x0d, .imm = .shuffle, .names = "i8x16.shuffle" },
    .{ .prefix = 0xfd, .first = 0x0e, .imm = .none, .names = "i8x16.swizzle i8x16.splat i16x8.splat i32x4.splat i64x2.splat f32x4.splat f64x2.splat" },
    .{ .prefix = 0xfd, .first = 0x15, .imm = .lane, .names = "i8x16.extract_lane_s i8x16.extract_lane_u i8x16.replace_lane i16x8.extract_lane_s i16x8.extract_lane_u i16x8.replace_lane i32x4.extract_lane i32x4.replace_lane i64x2.extract_lane i64x2.replace_lane f32x4.extract_lane f32x4.replace_lane f64x2.extract_lane f64x2.replace_lane" },
    .{ .prefix = 0xfd, .first = 0x23, .imm = .none, .names = "i8x16.eq i8x16.ne i8x16.lt_s i8x16.lt_u i8x16.gt_s i8x16.gt_u i8x16.le_s i8x16.le_u i8x16.ge_s i8x16.ge_u " ++
        "i16x8.eq i16x8.ne i16x8.lt_s i16x8.lt_u i16x8.gt_s i16x8.gt_u i16x8.le_s i16x8.le_u i16x8.ge_s i16x8.ge_u " ++
        "i32x4.eq i32x4.ne i32x4.lt_s i32x4.lt_u i32x4.gt_s i32x4.gt_u i32x4.le_s i32x4.le_u i32x4.ge_s i32x4.ge_u " ++
        "f32x4.eq f32x4.ne f32x4.lt f32x4.gt f32x4.le f32x4.ge f64x2.eq f64x2.ne f64x2.lt f64x2.gt f64x2.le f64x2.ge " ++
        "v128.not v128.and v128.andnot v128.or v128.xor v128.bitselect v128.any_true" },
    .{ .prefix = 0xfd, .first = 0x54, .imm = .memarg_lane, .names = "v128.load8_lane:0 v128.load16_lane:1 v128.load32_lane:2 v128.load64_lane:3 v128.store8_lane:0 v128.store16_lane:1 v128.store32_lane:2 v128.store64_lane:3" },
    .{ .prefix = 0xfd, .first = 0x5c, .imm = .memarg, .names = "v128.load32_zero:2 v128.load64_zero:3" },
    .{ .prefix = 0xfd, .first = 0x5e, .imm = .none, .names = "f32x4.demote_f64x2_zero f64x2.promote_low_f32x4 " ++
        "i8x16.abs i8x16.neg i8x16.popcnt i8x16.all_true i8x16.bitmask i8x16.narrow_i16x8_s i8x16.narrow_i16x8_u " ++
        "f32x4.ceil f32x4.floor f32x4.trunc f32x4.nearest " ++
        "i8x16.shl i8x16.shr_s i8x16.shr_u i8x16.add i8x16.add_sat_s i8x16.add_sat_u i8x16.sub i8x16.sub_sat_s i8x16.sub_sat_u " ++
        "f64x2.ceil f64x2.floor i8x16.min_s i8x16.min_u i8x16.max_s i8x16.max_u f64x2.trunc i8x16.avgr_u " ++
        "i16x8.extadd_pairwise_i8x16_s i16x8.extadd_pairwise_i8x16_u i32x4.extadd_pairwise_i16x8_s i32x4.extadd_pairwise_i16x8_u " ++
        "i16x8.abs i16x8.neg i16x8.q15mulr_sat_s i16x8.all_true i16x8.bitmask i16x8.narrow_i32x4_s i16x8.narrow_i32x4_u " ++
        "i16x8.extend_low_i8x16_s i16x8.extend_high_i8x16_s i16x8.extend_low_i8x16_u i16x8.extend_high_i8x16_u " ++
        "i16x8.shl i16x8.shr_s i16x8.shr_u i16x8.add i16x8.add_sat_s i16x8.add_sat_u i16x8.sub i16x8.sub_sat_s i16x8.sub_sat_u " ++
        "f64x2.nearest i16x8.mul i16x8.min_s i16x8.min_u i16x8.max_s i16x8.max_u _ i16x8.avgr_u " ++
        "i16x8.extmul_low_i8x16_s i16x8.extmul_high_i8x16_s i16x8.extmul_low_i8x16_u i16x8.extmul_high_i8x16_u " ++
        "i32x4.abs i32x4.neg _ i32x4.all_true i32x4.bitmask _ _ " ++
        "i32x4.extend_low_i16x8_s i32x4.extend_high_i16x8_s i32x4.extend_low_i16x8_u i32x4.extend_high_i16x8_u " ++
        "i32x4.shl i32x4.shr_s i32x4.shr_u i32x4.add _ _ i32x4.sub _ _ _ i32x4.mul i32x4.min_s i32x4.min_u i32x4.max_s i32x4.max_u i32x4.dot_i16x8_s _ " ++
        "i32x4.extmul_low_i16x8_s i32x4.extmul_high_i16x8_s i32x4.extmul_low_i16x8_u i32x4.extmul_high_i16x8_u " ++
        "i64x2.abs i64x2.neg _ i64x2.all_true i64x2.bitmask _ _ " ++
        "i64x2.extend_low_i32x4_s i64x2.extend_high_i32x4_s i64x2.extend_low_i32x4_u i64x2.extend_high_i32x4_u " ++
        "i64x2.shl i64x2.shr_s i64x2.shr_u i64x2.add _ _ i64x2.sub _ _ _ i64x2.mul " ++
        "i64x2.eq i64x2.ne i64x2.lt_s i64x2.gt_s i64x2.le_s i64x2.ge_s " ++
        "i64x2.extmul_low_i32x4_s i64x2.extmul_high_i32x4_s i64x2.extmul_low_i32x4_u i64x2.extmul_high_i32x4_u " ++
        "f32x4.abs f32x4.neg _ f32x4.sqrt f32x4.add f32x4.sub f32x4.mul f32x4.div f32x4.min f32x4.max f32x4.pmin f32x4.pmax " ++
        "f64x2.abs f64x2.neg _ f64x2.sqrt f64x2.add f64x2.sub f64x2.mul f64x2.div f64x2.min f64x2.max f64x2.pmin f64x2.pmax " ++
        "i32x4.trunc_sat_f32x4_s i32x4.trunc_sat_f32x4_u f32x4.convert_i32x4_s f32x4.convert_i32x4_u " ++
        "i32x4.trunc_sat_f64x2_s_zero i32x4.trunc_sat_f64x2_u_zero f64x2.convert_low_i32x4_s f64x2.convert_low_i32x4_u " ++
        "i8x16.relaxed_swizzle i32x4.relaxed_trunc_f32x4_s i32x4.relaxed_trunc_f32x4_u i32x4.relaxed_trunc_f64x2_s_zero i32x4.relaxed_trunc_f64x2_u_zero " ++
        "f32x4.relaxed_madd f32x4.relaxed_nmadd f64x2.relaxed_madd f64x2.relaxed_nmadd " ++
        "i8x16.relaxed_laneselect i16x8.relaxed_laneselect i32x4.relaxed_laneselect i64x2.relaxed_laneselect " ++
        "f32x4.relaxed_min f32x4.relaxed_max f64x2.relaxed_min f64x2.relaxed_max " ++
        "i16x8.relaxed_q15mulr_s i16x8.relaxed_dot_i8x16_i7x16_s i32x4.relaxed_dot_i8x16_i7x16_add_s" },

    .{ .prefix = 0xfe, .first = 0x00, .imm = .memarg, .names = "memory.atomic.notify:2 memory.atomic.wait32:2 memory.atomic.wait64:3" },
    .{ .prefix = 0xfe, .first = 0x03, .imm = .fence, .names = "atomic.fence" },
    .{ .prefix = 0xfe, .first = 0x10, .imm = .memarg, .names = "i32.atomic.load:2 i64.atomic.load:3 i32.atomic.load8_u:0 i32.atomic.load16_u:1 i64.atomic.load8_u:0 i64.atomic.load16_u:1 i64.atomic.load32_u:2 " ++
        "i32.atomic.store:2 i64.atomic.store:3 i32.atomic.store8:0 i32.atomic.store16:1 i64.atomic.store8:0 i64.atomic.store16:1 i64.atomic.store32:2 " ++
        rmw("add") ++ rmw("sub") ++ rmw("and") ++ rmw("or") ++ rmw("xor") ++ rmw("xchg") ++ rmw("cmpxchg") },

    // Recognized so they fail as unsupported features rather than typos.
    .{ .prefix = 0, .first = 0, .imm = .unsupported, .names = "try catch catch_all throw rethrow throw_ref delegate try_table call_ref return_call_ref " ++
        "ref.as_non_null br_on_null br_on_non_null ref.eq br_on_cast br_on_cast_fail ref.test ref.cast " ++
        "i64.add128 i64.sub128 i64.mul_wide_s i64.mul_wide_u" },
};

const Op = struct { name_off: u16, name_len: u8, prefix: u8, code: u16, imm: Imm, align_log2: u8 };

fn opSpecToken(list: []const u8, start: usize) [2]usize {
    var i = start;
    while (i < list.len and list[i] == ' ') i += 1;
    var j = i;
    while (j < list.len and list[j] != ' ') j += 1;
    return .{ i, j };
}

const op_count = blk: {
    @setEvalBranchQuota(1_000_000);
    var count: usize = 0;
    for (op_groups) |group| {
        var i: usize = 0;
        while (true) {
            const r = opSpecToken(group.names, i);
            if (r[0] == r[1]) break;
            if (!std.mem.eql(u8, group.names[r[0]..r[1]], "_")) count += 1;
            i = r[1];
        }
    }
    break :blk count;
};

const OpData = struct { ops: [op_count]Op, names: []const u8 };

const op_data: OpData = blk: {
    @setEvalBranchQuota(4_000_000);
    var ops: [op_count]Op = undefined;
    var blob: []const u8 = "";
    var n: usize = 0;
    for (op_groups) |group| {
        var i: usize = 0;
        var code: u16 = group.first;
        while (true) {
            const r = opSpecToken(group.names, i);
            if (r[0] == r[1]) break;
            i = r[1];
            const spec = group.names[r[0]..r[1]];
            if (std.mem.eql(u8, spec, "_")) {
                code += 1;
                continue;
            }
            var name: []const u8 = spec;
            var align_log2: u8 = 0;
            if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
                name = spec[0..colon];
                align_log2 = spec[colon + 1] - '0';
            }
            ops[n] = .{
                .name_off = blob.len,
                .name_len = name.len,
                .prefix = group.prefix,
                .code = code,
                .imm = group.imm,
                .align_log2 = align_log2,
            };
            blob = blob ++ name;
            n += 1;
            code += 1;
        }
    }
    break :blk .{ .ops = ops, .names = blob };
};

const OP_SLOTS: usize = 2048;

fn opHash(s: []const u8) u32 {
    return hashBytes(0, s);
}

fn opName(op: Op) []const u8 {
    return op_data.names[op.name_off..][0..op.name_len];
}

const op_slots: [OP_SLOTS]u16 = blk: {
    @setEvalBranchQuota(4_000_000);
    var slots = [_]u16{0} ** OP_SLOTS;
    for (op_data.ops, 0..) |op, i| {
        var h = opHash(opName(op)) & (OP_SLOTS - 1);
        while (slots[h] != 0) h = (h + 1) & (OP_SLOTS - 1);
        slots[h] = i + 1;
    }
    break :blk slots;
};

fn lookupOp(s: []const u8) ?*const Op {
    var h = opHash(s) & (OP_SLOTS - 1);
    while (op_slots[h] != 0) : (h = (h + 1) & (OP_SLOTS - 1)) {
        const op = &op_data.ops[op_slots[h] - 1];
        if (eqlBytes(opName(op.*), s)) return op;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Instructions

const FrameKind = enum(u8) {
    /// A folded instruction whose encoding waits on the pending stack.
    plain,
    /// A folded `call_indirect`, encoded when it closes. Its type use may
    /// add a type, and that has to happen after its operands add theirs.
    deferred,
    fblock,
    fif,
    flat,
    flat_if,
};

const NO_ELSE: u32 = std.math.maxInt(u32);

const Frame = struct {
    kind: FrameKind,
    stage: u8 = 0,
    /// plain: the pending byte count. deferred: where the keyword starts.
    /// fif: where the label and block type start, then from `else` on the
    /// output length just after the `else` opcode. flat_if: that length, or
    /// NO_ELSE before `else`.
    at: u32 = 0,
};

var frames: [MAX_DEPTH]Frame = undefined;
var frame_len: usize = 0;
var labels: [MAX_LABELS]Tok = undefined;
var label_len: usize = 0;
var uses_data_count: bool = false;

fn pushFrame(frame: Frame) Err!void {
    if (frame_len >= MAX_DEPTH) return fail(pos, .limit);
    frames[frame_len] = frame;
    frame_len += 1;
}

fn pushLabel(label: ?Tok) Err!void {
    if (label_len >= MAX_LABELS) return fail(pos, .limit);
    labels[label_len] = label orelse mkTok(.eof, 0, 0);
    label_len += 1;
}

fn labelDepth(t: Tok) Err!u32 {
    if (t.kind == .num) return u32Tok(t);
    if (t.kind != .id) return fail(t.start, .syntax);
    var i = label_len;
    while (i > 0) {
        i -= 1;
        if (labels[i].kind == .id and eqlBytes(labels[i].text(), t.text())) return @intCast(label_len - 1 - i);
    }
    return fail(t.start, .name);
}

/// Checks the optional label after `else` or `end` against the open block.
fn checkEndLabel() Err!void {
    const t = try peek();
    if (t.kind != .id) return;
    _ = try next();
    const label = labels[label_len - 1];
    if (label.kind != .id or !eqlBytes(label.text(), t.text())) return fail(t.start, .name);
}

/// Encodes instructions until the `)` that closes the enclosing form, which is
/// left unread. With `single`, encodes exactly one folded instruction.
fn encodeInstrs(o: *Out, single: bool) Err!void {
    frame_len = 0;
    o.top = o.buf.len;
    const base_labels = label_len;
    while (true) {
        const t = try next();
        switch (t.kind) {
            .rparen => {
                if (frame_len == 0) {
                    if (single) return fail(t.start, .syntax);
                    pos = t.start;
                    break;
                }
                try closeFrame(o, t);
                if (single and frame_len == 0) break;
            },
            .lparen => try openFolded(o),
            .keyword => {
                if (single and frame_len == 0) return fail(t.start, .syntax);
                try flatInstr(o, t);
            },
            else => return fail(t.start, .syntax),
        }
    }
    if (label_len != base_labels) return fail(pos, .syntax);
}

fn openFolded(o: *Out) Err!void {
    const kw = try next();
    if (kw.kind != .keyword) return fail(kw.start, .syntax);
    const found = lookupOp(kw.text());
    if (frame_len > 0) {
        const top = &frames[frame_len - 1];
        if (top.kind == .fif) {
            switch (top.stage) {
                0 => if (found != null and found.?.imm == .then) {
                    const save = pos;
                    pos = top.at;
                    const label = try optId();
                    const bt = try parseBlockType(true);
                    pos = save;
                    try o.byte(0x04);
                    try writeBlockType(o, bt);
                    try pushLabel(label);
                    top.stage = 1;
                    return;
                },
                2 => {
                    if (found == null or found.?.imm != .else_) return fail(kw.start, .syntax);
                    try o.byte(0x05);
                    top.at = @intCast(o.len);
                    top.stage = 3;
                    return;
                },
                4 => return fail(kw.start, .syntax),
                else => {},
            }
        }
    }
    const op = found orelse return fail(kw.start, .syntax);
    switch (op.imm) {
        .then, .else_, .end => return fail(kw.start, .syntax),
        .unsupported => return fail(kw.start, .unsupported),
        .block => {
            const label = try optId();
            const bt = try parseBlockType(true);
            try o.byte(@intCast(op.code));
            try writeBlockType(o, bt);
            try pushLabel(label);
            return pushFrame(.{ .kind = .fblock });
        },
        .if_ => {
            const header = pos;
            _ = try optId();
            _ = try parseBlockType(false);
            return pushFrame(.{ .kind = .fif, .at = @intCast(header) });
        },
        .call_indirect => {
            // Parse the immediates now only to find where the operands start.
            const save_len = o.len;
            try emitOp(o, op, true);
            o.len = save_len;
            return pushFrame(.{ .kind = .deferred, .at = kw.start });
        },
        else => {
            // Immediates precede the folded operands but are emitted after
            // them, so the encoding waits on the pending stack.
            const from = o.len;
            try emitOp(o, op, false);
            return pushFrame(.{ .kind = .plain, .at = o.stash(from) });
        },
    }
}

fn closeFrame(o: *Out, rparen: Tok) Err!void {
    const top = &frames[frame_len - 1];
    switch (top.kind) {
        .plain => {
            o.unstash(top.at);
            frame_len -= 1;
        },
        .deferred => {
            const save = pos;
            pos = top.at;
            const kw = try next();
            try emitOp(o, lookupOp(kw.text()).?, false);
            pos = save;
            frame_len -= 1;
        },
        .fblock => {
            try o.byte(0x0b);
            label_len -= 1;
            frame_len -= 1;
        },
        .fif => switch (top.stage) {
            0 => return fail(rparen.start, .syntax),
            1 => top.stage = 2,
            3 => {
                // WABT omits an empty else clause.
                if (o.len == top.at) o.len -= 1;
                top.stage = 4;
            },
            else => {
                try o.byte(0x0b);
                label_len -= 1;
                frame_len -= 1;
            },
        },
        .flat, .flat_if => return fail(rparen.start, .syntax),
    }
}

fn flatInstr(o: *Out, kw: Tok) Err!void {
    if (frame_len > 0) {
        const top = frames[frame_len - 1];
        if (top.kind == .plain or top.kind == .deferred) return fail(kw.start, .syntax);
        if (top.kind == .fif and top.stage != 1 and top.stage != 3) return fail(kw.start, .syntax);
    }
    const op = lookupOp(kw.text()) orelse return fail(kw.start, .syntax);
    switch (op.imm) {
        .block, .if_ => {
            const label = try optId();
            const bt = try parseBlockType(true);
            try o.byte(@intCast(op.code));
            try writeBlockType(o, bt);
            try pushLabel(label);
            return pushFrame(.{ .kind = if (op.imm == .if_) .flat_if else .flat, .at = NO_ELSE });
        },
        .else_ => {
            if (frame_len == 0) return fail(kw.start, .syntax);
            const top = &frames[frame_len - 1];
            if (top.kind != .flat_if or top.at != NO_ELSE) return fail(kw.start, .syntax);
            try checkEndLabel();
            try o.byte(0x05);
            top.at = @intCast(o.len);
        },
        .end => {
            if (frame_len == 0) return fail(kw.start, .syntax);
            const top = frames[frame_len - 1];
            if (top.kind != .flat and top.kind != .flat_if) return fail(kw.start, .syntax);
            try checkEndLabel();
            if (top.kind == .flat_if and o.len == top.at) o.len -= 1;
            try o.byte(0x0b);
            label_len -= 1;
            frame_len -= 1;
        },
        .then => return fail(kw.start, .syntax),
        .unsupported => return fail(kw.start, .unsupported),
        else => return emitOp(o, op, false),
    }
}

/// Parses `memidx? offset=N? align=N?` and writes the memarg.
fn memarg(o: *Out, natural: u8, lane: bool) Err!void {
    var memidx: u32 = 0;
    const t = try peek();
    var has_mem = t.kind == .id;
    if (t.kind == .num) {
        if (!lane) {
            has_mem = true;
        } else {
            const save = pos;
            _ = try next();
            const after = try peek();
            pos = save;
            has_mem = after.kind == .num or (after.kind == .keyword and
                (std.mem.startsWith(u8, after.text(), "offset=") or std.mem.startsWith(u8, after.text(), "align=")));
        }
    }
    if (has_mem) memidx = try varIndex(.memory, try next());

    // The grammar is `offset=`? then `align=`?, in that order.
    var offset: u64 = 0;
    var align_log2: u32 = natural;
    var a = try peek();
    if (a.kind == .keyword and std.mem.startsWith(u8, a.text(), "offset=")) {
        _ = try next();
        offset = parseNat(a.text()[7..]) orelse return fail(a.start, .number);
        a = try peek();
    }
    if (a.kind == .keyword and std.mem.startsWith(u8, a.text(), "align=")) {
        _ = try next();
        const v = parseNat(a.text()[6..]) orelse return fail(a.start, .number);
        if (v == 0 or v & (v - 1) != 0 or v > 1 << 31) return fail(a.start, .number);
        align_log2 = @ctz(v);
    }
    if (memidx != 0) {
        try o.uleb(align_log2 | 0x40);
        try o.uleb(memidx);
    } else {
        try o.uleb(align_log2);
    }
    try o.uleb(offset);
}

fn laneIndex(o: *Out) Err!void {
    const t = try next();
    const v = try natTok(t);
    if (v > 255) return fail(t.start, .number);
    try o.byte(@intCast(v));
}

fn optVar(space: Space) Err!?u32 {
    const t = try peek();
    if (!isVar(t)) return null;
    _ = try next();
    return try varIndex(space, t);
}

fn emitOp(o: *Out, op: *const Op, dry: bool) Err!void {
    if (op.imm == .select) {
        // `select (result t*)*` uses the typed opcode 0x1c.
        const save = pos;
        var n: usize = 0;
        while (try openForm("result")) {
            while ((try next()).kind != .rparen) n += 1;
        }
        if (n == 0 and !try peekFormAt(save, "result")) return o.byte(0x1b);
        pos = save;
        try o.byte(0x1c);
        try o.uleb(n);
        while (try openForm("result")) {
            while (true) {
                const t = try next();
                if (t.kind == .rparen) break;
                try o.byte(try valType(t));
            }
        }
        return;
    }
    if (op.prefix != 0) {
        try o.byte(op.prefix);
        try o.uleb(op.code);
    } else {
        try o.byte(@intCast(op.code));
    }
    switch (op.imm) {
        .none, .unsupported, .select => {},
        .block, .if_, .then, .else_, .end => unreachable,
        .label => try o.uleb(try labelDepth(try next())),
        .br_table => {
            const save = pos;
            var n: usize = 0;
            while (isVar(try peek())) : (n += 1) _ = try next();
            if (n == 0) return fail(pos, .syntax);
            pos = save;
            try o.uleb(n - 1);
            var i: usize = 0;
            while (i < n) : (i += 1) try o.uleb(try labelDepth(try next()));
        },
        .func => try o.uleb(try varIndex(.func, try next())),
        .call_indirect => {
            const table = (try optVar(.table)) orelse 0;
            const type_index = try parseTypeUse(.forbid, !dry);
            try o.uleb(type_index);
            try o.uleb(table);
        },
        .local => try o.uleb(try varIndex(.local, try next())),
        .global => try o.uleb(try varIndex(.global, try next())),
        .table => try o.uleb((try optVar(.table)) orelse 0),
        .memarg => try memarg(o, op.align_log2, false),
        .memarg_lane => {
            try memarg(o, op.align_log2, true);
            try laneIndex(o);
        },
        .lane => try laneIndex(o),
        .shuffle => {
            var i: usize = 0;
            while (i < 16) : (i += 1) try laneIndex(o);
        },
        .i32 => try o.sleb(@as(i32, @bitCast(@as(u32, @intCast(try intTok(try next(), 32)))))),
        .i64 => try o.sleb(@bitCast(try intTok(try next(), 64))),
        .f32 => try o.uintLe(try floatTok(try next(), f32), 4),
        .f64 => try o.uintLe(try floatTok(try next(), f64), 8),
        .v128 => try v128Const(o),
        .ref_null => {
            const t = try next();
            if (isKw(t, "func")) {
                try o.byte(0x70);
            } else if (isKw(t, "extern")) {
                try o.byte(0x6f);
            } else return fail(t.start, if (t.kind == .keyword) .unsupported else .syntax);
        },
        .mem => try o.uleb((try optVar(.memory)) orelse 0),
        // Like WABT, a single index names the destination and the source
        // defaults to 0.
        .mem_copy => {
            const dst = try optVar(.memory);
            const src_mem = if (dst != null) try optVar(.memory) else null;
            try o.uleb(dst orelse 0);
            try o.uleb(src_mem orelse 0);
        },
        .mem_init, .table_init => {
            const first = try next();
            if (!isVar(first)) return fail(first.start, .syntax);
            const outer: Space = if (op.imm == .mem_init) .memory else .table;
            const seg: Space = if (op.imm == .mem_init) .data else .elem;
            var container: u32 = 0;
            var segment: u32 = 0;
            if (isVar(try peek())) {
                container = try varIndex(outer, first);
                segment = try varIndex(seg, try next());
            } else {
                segment = try varIndex(seg, first);
            }
            try o.uleb(segment);
            try o.uleb(container);
            if (op.imm == .mem_init and !dry) uses_data_count = true;
        },
        .data => {
            try o.uleb(try varIndex(.data, try next()));
            if (!dry) uses_data_count = true;
        },
        .table_copy => {
            const dst = try optVar(.table);
            const src_table = if (dst != null) try optVar(.table) else null;
            try o.uleb(dst orelse 0);
            try o.uleb(src_table orelse 0);
        },
        .elem => try o.uleb(try varIndex(.elem, try next())),
        .fence => try o.byte(0x00),
    }
}

fn peekFormAt(at: usize, s: []const u8) Err!bool {
    const save = pos;
    defer pos = save;
    pos = at;
    return peekForm(s);
}

fn v128Const(o: *Out) Err!void {
    const shape = try next();
    const s = shape.text();
    if (shape.kind != .keyword) return fail(shape.start, .syntax);
    if (std.mem.eql(u8, s, "i8x16")) {
        var i: usize = 0;
        while (i < 16) : (i += 1) try o.uintLe(try intTok(try next(), 8), 1);
    } else if (std.mem.eql(u8, s, "i16x8")) {
        var i: usize = 0;
        while (i < 8) : (i += 1) try o.uintLe(try intTok(try next(), 16), 2);
    } else if (std.mem.eql(u8, s, "i32x4")) {
        var i: usize = 0;
        while (i < 4) : (i += 1) try o.uintLe(try intTok(try next(), 32), 4);
    } else if (std.mem.eql(u8, s, "i64x2")) {
        var i: usize = 0;
        while (i < 2) : (i += 1) try o.uintLe(try intTok(try next(), 64), 8);
    } else if (std.mem.eql(u8, s, "f32x4")) {
        var i: usize = 0;
        while (i < 4) : (i += 1) try o.uintLe(try floatTok(try next(), f32), 4);
    } else if (std.mem.eql(u8, s, "f64x2")) {
        var i: usize = 0;
        while (i < 2) : (i += 1) try o.uintLe(try floatTok(try next(), f64), 8);
    } else return fail(shape.start, .syntax);
}

/// Encodes a constant expression body and its `end`, then the closing `)`.
fn constExprThenClose(o: *Out) Err!void {
    try encodeInstrs(o, false);
    try o.byte(0x0b);
    _ = try expect(.rparen);
}

// ---------------------------------------------------------------------------
// Strings

/// Decodes a string token, writing its bytes to `o` when given.
fn decodeString(t: Tok, o: ?*Out) Err!usize {
    if (t.kind != .string) return fail(t.start, .syntax);
    var i: usize = t.start + 1;
    const end = t.end - 1;
    var n: usize = 0;
    while (i < end) {
        const c = src[i];
        if (c != '\\') {
            var j = i + 1;
            while (j < end and src[j] != '\\') j += 1;
            if (o) |out| try out.bytes(src[i..j]);
            n += j - i;
            i = j;
            continue;
        }
        const esc_start = i;
        i += 1;
        const e = src[i];
        i += 1;
        var b: u8 = 0;
        switch (e) {
            't' => b = '\t',
            'n' => b = '\n',
            'r' => b = '\r',
            '"', '\'', '\\' => b = e,
            'u' => {
                if (i >= end or src[i] != '{') return fail(esc_start, .syntax);
                const close = std.mem.indexOfScalarPos(u8, src[0..end], i, '}') orelse return fail(esc_start, .syntax);
                const value = parseHexOnly(src[i + 1 .. close]) orelse return fail(esc_start, .syntax);
                if (value > 0x10ffff or (value >= 0xd800 and value < 0xe000)) return fail(esc_start, .syntax);
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(value), &utf8) catch return fail(esc_start, .syntax);
                if (o) |out| try out.bytes(utf8[0..len]);
                n += len;
                i = close + 1;
                continue;
            },
            else => {
                if (i >= end + 1) return fail(esc_start, .syntax);
                const hi = digitValue(e);
                const lo = if (i < end) digitValue(src[i]) else 255;
                if (hi > 15 or lo > 15) return fail(esc_start, .syntax);
                b = hi * 16 + lo;
                i += 1;
            },
        }
        if (o) |out| try out.byte(b);
        n += 1;
    }
    return n;
}

/// Parses the hex digits of a `\u{...}` escape. Like WABT, underscores are
/// not allowed here even though the spec permits them.
fn parseHexOnly(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (digitValue(c) >= 16) return null;
        if (v > 0x10ffff) return null;
        v = v * 16 + digitValue(c);
    }
    return v;
}

/// Writes an import or export name. Escapes can spell any byte, but a name
/// must still be valid UTF-8 once they are decoded.
fn writeName(o: *Out, t: Tok) Err!void {
    try o.uleb(try decodeString(t, null));
    const start = o.len;
    _ = try decodeString(t, o);
    if (!std.unicode.utf8ValidateSlice(o.buf[start..o.len])) return fail(t.start, .syntax);
}

/// Sums the decoded length of the strings up to the closing `)`.
fn stringsLength() Err!usize {
    const save = pos;
    defer pos = save;
    var total: usize = 0;
    while (true) {
        const t = try next();
        if (t.kind == .rparen) return total;
        total += try decodeString(t, null);
    }
}

fn writeStringsThenClose(o: *Out) Err!void {
    const size = try o.begin();
    while (true) {
        const t = try next();
        if (t.kind == .rparen) break;
        _ = try decodeString(t, o);
    }
    o.end(size);
}

// ---------------------------------------------------------------------------
// Module walk

var func_type: [MAX_FUNCS]u32 = undefined;

const Counts = struct {
    func: u32 = 0,
    table: u32 = 0,
    memory: u32 = 0,
    global: u32 = 0,
    elem: u32 = 0,
    data: u32 = 0,
};

var totals: Counts = .{};
var imported: Counts = .{};
var import_count: u32 = 0;
var export_count: u32 = 0;
var wrapped: bool = false;

fn beginModule() Err!void {
    pos = 0;
    wrapped = false;
    if (try openForm("module")) {
        wrapped = true;
        _ = try optId();
        const t = try peek();
        if (isKw(t, "binary") or isKw(t, "quote")) return fail(t.start, .unsupported);
    }
}

/// Where the `(` of the field that `nextField` last returned starts.
var field_open: u32 = 0;

/// Returns the keyword of the next module field, or null at the end.
fn nextField() Err!?Tok {
    const t = try next();
    if (wrapped) {
        if (t.kind == .rparen) {
            const e = try next();
            if (e.kind != .eof) return fail(e.start, .syntax);
            return null;
        }
    } else if (t.kind == .eof) return null;
    if (t.kind != .lparen) return fail(t.start, .syntax);
    field_open = t.start;
    const kw = try next();
    if (kw.kind != .keyword) return fail(kw.start, .syntax);
    return kw;
}

const FieldKind = enum(u8) { type, import, func, table, memory, global, export_, start, elem, data };

// Pass 1 lexes the whole module and records where each field starts. Every
// later pass jumps straight to the fields it writes, so text is not lexed
// again just to be skipped. The shortest field is 6 bytes, `(func)`.
const MAX_FIELDS: usize = INPUT_CAP / 6 + 2;
var field_kinds: [MAX_FIELDS]FieldKind = undefined;
/// The position just after the field's keyword.
var field_at: [MAX_FIELDS]u32 = undefined;
var field_count: usize = 0;

/// The index space of a `func`, `table`, `memory` or `global` field.
fn fieldSpace(kind: FieldKind) Space {
    return switch (kind) {
        .func => .func,
        .table => .table,
        .memory => .memory,
        .global => .global,
        else => unreachable,
    };
}

fn fieldKind(kw: Tok) Err!FieldKind {
    const table = [_]struct { []const u8, FieldKind }{
        .{ "type", .type },     .{ "import", .import }, .{ "func", .func },   .{ "table", .table },
        .{ "memory", .memory }, .{ "global", .global }, .{ "export", .export_ }, .{ "start", .start },
        .{ "elem", .elem },     .{ "data", .data },
    };
    for (table) |entry| if (isKw(kw, entry[0])) return entry[1];
    if (isKw(kw, "tag") or isKw(kw, "rec")) return fail(kw.start, .unsupported);
    return fail(kw.start, .syntax);
}

fn spaceOfKind(kw: Tok) Err!Space {
    if (isKw(kw, "func")) return .func;
    if (isKw(kw, "table")) return .table;
    if (isKw(kw, "memory")) return .memory;
    if (isKw(kw, "global")) return .global;
    if (isKw(kw, "tag")) return fail(kw.start, .unsupported);
    return fail(kw.start, .syntax);
}

fn countRef(c: *Counts, space: Space) *u32 {
    return switch (space) {
        .func => &c.func,
        .table => &c.table,
        .memory => &c.memory,
        .global => &c.global,
        .elem => &c.elem,
        .data => &c.data,
        else => unreachable,
    };
}

fn exportKindByte(space: Space) u8 {
    return switch (space) {
        .func => 0,
        .table => 1,
        .memory => 2,
        .global => 3,
        else => unreachable,
    };
}

fn skipInlineExports() Err!u32 {
    var n: u32 = 0;
    while (try openForm("export")) : (n += 1) try skipBalanced();
    return n;
}

/// After `(table id? export*`: true when the table carries `(elem ...)`.
fn tableHasInlineElem() Err!bool {
    const save = pos;
    defer pos = save;
    const t = try next();
    if (isKw(t, "i64") or isKw(t, "i32")) return isRefTypeKw(try next()) and try peekForm("elem");
    return isRefTypeKw(t) and try peekForm("elem");
}

/// Pass 1: names, index-space sizes and explicit types.
fn declare() Err!void {
    try beginModule();
    var defs_seen = false;
    var c: Counts = .{};
    while (try nextField()) |kw| {
        const open = field_open;
        const kind = try fieldKind(kw);
        if (field_count >= MAX_FIELDS) return fail(kw.start, .limit);
        field_kinds[field_count] = kind;
        field_at[field_count] = @intCast(pos);
        field_count += 1;
        switch (kind) {
            .type => {
                if (try optId()) |id| try names.define(.type, id, type_count);
                if (!try openForm("func")) return fail((try peek()).start, .unsupported);
                const sig = try parseSig(.allow);
                _ = try expect(.rparen);
                try addExplicitType(sig);
            },
            .import => {
                _ = try expect(.string);
                _ = try expect(.string);
                _ = try expect(.lparen);
                const desc = try next();
                const space = try spaceOfKind(desc);
                if (defs_seen) return fail(kw.start, .syntax);
                if (try optId()) |id| try names.define(space, id, countRef(&c, space).*);
                countRef(&c, space).* += 1;
                countRef(&imported, space).* += 1;
                import_count += 1;
                try skipBalanced();
            },
            .func, .table, .memory, .global => {
                const space = fieldSpace(kind);
                const id = try optId();
                export_count += try skipInlineExports();
                if (try peekForm("import")) {
                    if (defs_seen) return fail(kw.start, .syntax);
                    countRef(&imported, space).* += 1;
                    import_count += 1;
                } else {
                    defs_seen = true;
                    if (space == .table and try tableHasInlineElem()) c.elem += 1;
                    if (space == .memory) {
                        const save = pos;
                        const t = try peek();
                        if (isKw(t, "i64") or isKw(t, "i32")) _ = try next();
                        if (try peekForm("data")) c.data += 1;
                        pos = save;
                    }
                }
                if (id) |name| try names.define(space, name, countRef(&c, space).*);
                countRef(&c, space).* += 1;
            },
            .export_ => export_count += 1,
            .elem => {
                if (try optId()) |id| try names.define(.elem, id, c.elem);
                c.elem += 1;
            },
            .data => {
                if (try optId()) |id| try names.define(.data, id, c.data);
                c.data += 1;
            },
            .start => {},
        }
        // Everything up to here stayed inside the field, so its matching
        // `)` closes it.
        const close = matchEnd(open);
        if (close != 0) pos = close else try skipBalanced();
    }
    if (c.func > MAX_FUNCS) return fail(src.len, .limit);
    totals = c;
}

var local_types: [MAX_LOCALS]u8 = undefined;

/// Pass 2: function types in text order and function bodies.
fn compileFunctions(code: *Out) Err!void {
    var func_index: u32 = 0;
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        switch (kind) {
            .import => {
                pos = at;
                _ = try next();
                _ = try next();
                _ = try expect(.lparen);
                const desc = try next();
                if (isKw(desc, "func")) {
                    _ = try optId();
                    func_type[func_index] = try parseTypeUse(.distinct, true);
                    func_index += 1;
                    _ = try expect(.rparen);
                } else try skipBalanced();
                _ = try expect(.rparen);
            },
            .func => {
                pos = at;
                _ = try optId();
                _ = try skipInlineExports();
                if (try openForm("import")) {
                    try skipBalanced();
                    func_type[func_index] = try parseTypeUse(.distinct, true);
                    _ = try expect(.rparen);
                } else {
                    try compileBody(code, func_index);
                }
                func_index += 1;
            },
            else => {},
        }
    }
    // Constant expressions compiled later must not see the last function's
    // (or import's) parameter and local names.
    locals.reset();
}

fn compileBody(code: *Out, func_index: u32) Err!void {
    locals.reset();
    const type_index = try parseTypeUse(.bind, true);
    func_type[func_index] = type_index;
    const nparams = if (type_index < type_count) type_np[type_index] else 0;
    var nlocals: usize = 0;
    while (try openForm("local")) {
        if (try optId()) |id| {
            if (nlocals >= MAX_LOCALS) return fail(id.start, .limit);
            try locals.define(.local, id, @intCast(nparams + nlocals));
            local_types[nlocals] = try valType(try next());
            nlocals += 1;
            _ = try expect(.rparen);
            continue;
        }
        while (true) {
            const t = try next();
            if (t.kind == .rparen) break;
            if (nlocals >= MAX_LOCALS) return fail(t.start, .limit);
            local_types[nlocals] = try valType(t);
            nlocals += 1;
        }
    }

    const body = try code.begin();
    var groups: usize = 0;
    var i: usize = 0;
    while (i < nlocals) : (i += 1) {
        if (i == 0 or local_types[i] != local_types[i - 1]) groups += 1;
    }
    try code.uleb(groups);
    i = 0;
    while (i < nlocals) {
        var j = i + 1;
        while (j < nlocals and local_types[j] == local_types[i]) j += 1;
        try code.uleb(j - i);
        try code.byte(local_types[i]);
        i = j;
    }
    label_len = 0;
    try constExprThenClose(code);
    code.end(body);
}

fn writeLimits(o: *Out, is64: bool, shared: bool) Err!void {
    const min = try natTok(try next());
    const max_tok = try peek();
    const has_max = max_tok.kind == .num;
    const max = if (has_max) try natTok(try next()) else 0;
    // Like WABT, 32-bit limits are not range-checked; validation rejects
    // values above 2^32 - 1.
    var flags: u8 = if (has_max) 1 else 0;
    if (shared) flags |= 2;
    if (is64) flags |= 4;
    try o.byte(flags);
    try o.uleb(min);
    if (has_max) try o.uleb(max);
}

fn indexType() Err!bool {
    const t = try peek();
    if (isKw(t, "i64")) {
        _ = try next();
        return true;
    }
    if (isKw(t, "i32")) _ = try next();
    return false;
}

/// `i64? min max? reftype )`, written as reftype then limits.
fn tableTypeThenClose(o: *Out) Err!void {
    const is64 = try indexType();
    const save = pos;
    _ = try next();
    if ((try peek()).kind == .num) _ = try next();
    const ref_tok = try next();
    const ref = try valType(ref_tok);
    if (ref != 0x70 and ref != 0x6f) return fail(ref_tok.start, .syntax);
    const after = pos;
    try o.byte(ref);
    pos = save;
    try writeLimits(o, is64, false);
    pos = after;
    _ = try expect(.rparen);
}

/// `i64? min max? shared? )`
fn memTypeThenClose(o: *Out) Err!void {
    return writeLimitsAfterIndexType(o, try indexType());
}

/// `valtype | (mut valtype)`
fn globalType(o: *Out) Err!void {
    if (try openForm("mut")) {
        try o.byte(try valType(try next()));
        try o.byte(1);
        _ = try expect(.rparen);
    } else {
        try o.byte(try valType(try next()));
        try o.byte(0);
    }
}

fn writeImports(o: *Out) Err!void {
    var c: Counts = .{};
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        switch (kind) {
            .import => {
                pos = at;
                try writeName(o, try next());
                try writeName(o, try next());
                _ = try expect(.lparen);
                const space = try spaceOfKind(try next());
                _ = try optId();
                try writeImportDesc(o, space, &c);
                _ = try expect(.rparen);
            },
            .func, .table, .memory, .global => {
                pos = at;
                const space = fieldSpace(kind);
                _ = try optId();
                _ = try skipInlineExports();
                if (try openForm("import")) {
                    try writeName(o, try next());
                    try writeName(o, try next());
                    _ = try expect(.rparen);
                    try writeImportDesc(o, space, &c);
                } else {
                    countRef(&c, space).* += 1;
                }
            },
            else => {},
        }
    }
}

/// Writes an import descriptor and consumes through its closing `)`.
fn writeImportDesc(o: *Out, space: Space, c: *Counts) Err!void {
    try o.byte(exportKindByte(space));
    switch (space) {
        .func => {
            try o.uleb(func_type[c.func]);
            try skipBalanced();
        },
        .table => try tableTypeThenClose(o),
        .memory => try memTypeThenClose(o),
        .global => {
            try globalType(o);
            _ = try expect(.rparen);
        },
        else => unreachable,
    }
    countRef(c, space).* += 1;
}

/// Counts elements in an element list up to `)` without consuming it.
fn countElemItems() Err!u32 {
    const save = pos;
    defer pos = save;
    var n: u32 = 0;
    while (true) {
        const t = try next();
        if (t.kind == .rparen) return n;
        if (t.kind == .lparen) try skipBalanced() else if (!isVar(t)) return fail(t.start, .syntax);
        n += 1;
    }
}

fn writeTables(o: *Out) Err!void {
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        if (kind != .table) continue;
        pos = at;
        _ = try optId();
        _ = try skipInlineExports();
        if (try peekForm("import")) continue;
        if (try tableHasInlineElem()) {
            const is64 = try indexType();
            const ref = try valType(try next());
            _ = try openForm("elem");
            const n = try countElemItems();
            try o.byte(ref);
            try o.byte(if (is64) 5 else 1);
            try o.uleb(n);
            try o.uleb(n);
            try skipBalanced();
            _ = try expect(.rparen);
        } else {
            const t = try peek();
            if (t.kind == .lparen) return fail(t.start, .unsupported);
            try tableTypeThenClose(o);
        }
    }
}

fn writeMemories(o: *Out) Err!void {
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        if (kind != .memory) continue;
        pos = at;
        _ = try optId();
        _ = try skipInlineExports();
        if (try peekForm("import")) continue;
        const is64 = try indexType();
        if (try openForm("data")) {
            const len = try stringsLength();
            const pages = (len + 0xffff) / 0x10000;
            try o.byte(if (is64) 5 else 1);
            try o.uleb(pages);
            try o.uleb(pages);
            try skipBalanced();
            _ = try expect(.rparen);
        } else {
            try writeLimitsAfterIndexType(o, is64);
        }
    }
}

fn writeLimitsAfterIndexType(o: *Out, is64: bool) Err!void {
    const save = pos;
    _ = try next();
    if ((try peek()).kind == .num) _ = try next();
    const shared = isKw(try peek(), "shared");
    pos = save;
    try writeLimits(o, is64, shared);
    if (shared) _ = try next();
    const t = try peek();
    if (t.kind == .lparen) return fail(t.start, .unsupported);
    _ = try expect(.rparen);
}

fn writeGlobals(o: *Out) Err!void {
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        if (kind != .global) continue;
        pos = at;
        _ = try optId();
        _ = try skipInlineExports();
        if (try peekForm("import")) continue;
        try globalType(o);
        label_len = 0;
        try constExprThenClose(o);
    }
}

fn writeExports(o: *Out) Err!void {
    var c: Counts = .{};
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        pos = at;
        switch (kind) {
            .import => {
                _ = try next();
                _ = try next();
                _ = try expect(.lparen);
                const space = try spaceOfKind(try next());
                countRef(&c, space).* += 1;
            },
            .func, .table, .memory, .global => {
                const space = fieldSpace(kind);
                _ = try optId();
                while (try openForm("export")) {
                    try writeName(o, try next());
                    _ = try expect(.rparen);
                    try o.byte(exportKindByte(space));
                    try o.uleb(countRef(&c, space).*);
                }
                countRef(&c, space).* += 1;
            },
            .export_ => {
                try writeName(o, try next());
                _ = try expect(.lparen);
                const space = try spaceOfKind(try next());
                try o.byte(exportKindByte(space));
                try o.uleb(try varIndex(space, try next()));
                _ = try expect(.rparen);
                _ = try expect(.rparen);
            },
            else => {},
        }
    }
}

fn findStart() Err!?u32 {
    var start: ?u32 = null;
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        if (kind != .start) continue;
        // A second start field fails at its keyword.
        if (start != null) return fail(at - 5, .syntax);
        pos = at;
        start = try varIndex(.func, try next());
        _ = try expect(.rparen);
    }
    return start;
}

/// Matches `(ref.func x)`, `(item ref.func x)` or `(item (ref.func x))` and
/// returns `x`. Leaves the position unchanged when the item is anything else.
fn refFuncItem() Err!?Tok {
    const save = pos;
    if ((try next()).kind != .lparen) {
        pos = save;
        return null;
    }
    const kw = try next();
    var closes: usize = 1;
    if (isKw(kw, "item")) {
        const t = try next();
        if (t.kind == .lparen) {
            if (!isKw(try next(), "ref.func")) {
                pos = save;
                return null;
            }
            closes = 2;
        } else if (!isKw(t, "ref.func")) {
            pos = save;
            return null;
        }
    } else if (!isKw(kw, "ref.func")) {
        pos = save;
        return null;
    }
    const v = try next();
    if (!isVar(v)) {
        pos = save;
        return null;
    }
    var i: usize = 0;
    while (i < closes) : (i += 1) {
        if ((try next()).kind != .rparen) {
            pos = save;
            return null;
        }
    }
    return v;
}

const ElemMode = enum { active, passive, declared };

const OffsetSource = union(enum) { at: usize, zero32, zero64 };

/// Writes one element segment from its element list, which starts at `pos`
/// and ends with the `)` of the enclosing form (consumed).
fn writeElemSegment(o: *Out, mode: ElemMode, table: u32, offset: OffsetSource, ref: u8, exprs: bool) Err!void {
    const list = pos;
    var all_ref_func = ref == 0x70;
    var n: u32 = 0;
    while (true) {
        const t = try peek();
        if (t.kind == .rparen) break;
        if (exprs) {
            if (try refFuncItem() == null) {
                all_ref_func = false;
                _ = try expect(.lparen);
                try skipBalanced();
            }
        } else {
            if (!isVar(t)) return fail(t.start, .syntax);
            _ = try next();
        }
        n += 1;
    }

    var flags: u8 = switch (mode) {
        // Flags 0 and 4 imply funcref, so other types name the table.
        .active => if (table != 0 or ref != 0x70) 2 else 0,
        .passive => 1,
        .declared => 3,
    };
    if (!all_ref_func) flags |= 4;
    try o.byte(flags);
    if (flags & 2 != 0 and mode == .active) try o.uleb(table);
    if (mode == .active) {
        switch (offset) {
            .at => |at| {
                pos = at;
                label_len = 0;
                if (try openForm("offset")) {
                    try encodeInstrs(o, false);
                    _ = try expect(.rparen);
                } else {
                    try encodeInstrs(o, true);
                }
                try o.byte(0x0b);
            },
            .zero32 => try o.bytes(&.{ 0x41, 0x00, 0x0b }),
            .zero64 => try o.bytes(&.{ 0x42, 0x00, 0x0b }),
        }
    }
    if (flags & 3 != 0) try o.byte(if (flags & 4 != 0) ref else 0x00);
    try o.uleb(n);

    pos = list;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!exprs) {
            try o.uleb(try varIndex(.func, try next()));
        } else if (all_ref_func) {
            try o.uleb(try varIndex(.func, (try refFuncItem()).?));
        } else {
            label_len = 0;
            if (try openForm("item")) {
                try encodeInstrs(o, false);
                _ = try expect(.rparen);
            } else {
                try encodeInstrs(o, true);
            }
            try o.byte(0x0b);
        }
    }
    _ = try expect(.rparen);
}

fn writeElems(o: *Out) Err!void {
    var table_index: u32 = 0;
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        pos = at;
        if (kind == .import) {
            _ = try next();
            _ = try next();
            _ = try expect(.lparen);
            if (isKw(try next(), "table")) table_index += 1;
        } else if (kind == .table) {
            _ = try optId();
            _ = try skipInlineExports();
            if (try peekForm("import") or !try tableHasInlineElem()) {
                table_index += 1;
                continue;
            }
            const is64 = try indexType();
            const ref = try valType(try next());
            _ = try openForm("elem");
            const exprs = (try peek()).kind == .lparen;
            try writeElemSegment(o, .active, table_index, if (is64) .zero64 else .zero32, ref, exprs);
            _ = try expect(.rparen);
            table_index += 1;
        } else if (kind == .elem) {
            try writeElemField(o);
        }
    }
}

fn writeElemField(o: *Out) Err!void {
    _ = try optId();
    var mode: ElemMode = .passive;
    var table: u32 = 0;
    if (isKw(try peek(), "declare")) {
        _ = try next();
        mode = .declared;
    }
    if (try openForm("table")) {
        table = try varIndex(.table, try next());
        _ = try expect(.rparen);
    } else if ((try peek()).kind == .num) {
        table = try u32Tok(try next());
    }
    var offset: OffsetSource = .zero32;
    if (mode != .declared and (try peek()).kind == .lparen and !try peekForm("item")) {
        offset = .{ .at = pos };
        mode = .active;
        _ = try next();
        try skipBalanced();
    }
    const t = try peek();
    var ref: u8 = 0x70;
    var exprs = false;
    if (isKw(t, "func")) {
        _ = try next();
    } else if (isRefTypeKw(t)) {
        _ = try next();
        ref = try valType(t);
        exprs = true;
    } else if (t.kind == .lparen) {
        return fail(t.start, .unsupported);
    }
    try writeElemSegment(o, mode, table, offset, ref, exprs);
}

fn writeDatas(o: *Out) Err!void {
    var memory_index: u32 = 0;
    for (field_kinds[0..field_count], field_at[0..field_count]) |kind, at| {
        pos = at;
        if (kind == .import) {
            _ = try next();
            _ = try next();
            _ = try expect(.lparen);
            if (isKw(try next(), "memory")) memory_index += 1;
        } else if (kind == .memory) {
            _ = try optId();
            _ = try skipInlineExports();
            if (try peekForm("import")) {
                memory_index += 1;
                continue;
            }
            const is64 = try indexType();
            if (try openForm("data")) {
                if (memory_index != 0) {
                    try o.byte(2);
                    try o.uleb(memory_index);
                } else try o.byte(0);
                try o.bytes(if (is64) &.{ 0x42, 0x00, 0x0b } else &.{ 0x41, 0x00, 0x0b });
                try writeStringsThenClose(o);
            }
            memory_index += 1;
        } else if (kind == .data) {
            try writeDataField(o);
        }
    }
}

fn writeDataField(o: *Out) Err!void {
    _ = try optId();
    var memory: u32 = 0;
    if (try openForm("memory")) {
        memory = try varIndex(.memory, try next());
        _ = try expect(.rparen);
    } else if (isVar(try peek())) {
        memory = try varIndex(.memory, try next());
    }
    if ((try peek()).kind == .lparen) {
        if (memory != 0) {
            try o.byte(2);
            try o.uleb(memory);
        } else try o.byte(0);
        label_len = 0;
        if (try openForm("offset")) {
            try encodeInstrs(o, false);
            _ = try expect(.rparen);
        } else {
            try encodeInstrs(o, true);
        }
        try o.byte(0x0b);
    } else {
        try o.byte(1);
    }
    try writeStringsThenClose(o);
}

fn assemble(code: *const Out) Err!usize {
    var o = Out.init(&output_buf);
    try o.bytes(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    if (type_count > 0) {
        try o.byte(1);
        const s = try o.begin();
        try o.uleb(type_count);
        var i: u32 = 0;
        while (i < type_count) : (i += 1) {
            try o.byte(0x60);
            try o.uleb(type_np[i]);
            try o.bytes(type_pool[type_off[i]..][0..type_np[i]]);
            try o.uleb(type_nr[i]);
            try o.bytes(type_pool[type_off[i] + type_np[i] ..][0..type_nr[i]]);
        }
        o.end(s);
    }
    if (import_count > 0) {
        try o.byte(2);
        const s = try o.begin();
        try o.uleb(import_count);
        try writeImports(&o);
        o.end(s);
    }
    const defined_funcs = totals.func - imported.func;
    if (defined_funcs > 0) {
        try o.byte(3);
        const s = try o.begin();
        try o.uleb(defined_funcs);
        var i: u32 = imported.func;
        while (i < totals.func) : (i += 1) try o.uleb(func_type[i]);
        o.end(s);
    }
    if (totals.table > imported.table) {
        try o.byte(4);
        const s = try o.begin();
        try o.uleb(totals.table - imported.table);
        try writeTables(&o);
        o.end(s);
    }
    if (totals.memory > imported.memory) {
        try o.byte(5);
        const s = try o.begin();
        try o.uleb(totals.memory - imported.memory);
        try writeMemories(&o);
        o.end(s);
    }
    if (totals.global > imported.global) {
        try o.byte(6);
        const s = try o.begin();
        try o.uleb(totals.global - imported.global);
        try writeGlobals(&o);
        o.end(s);
    }
    if (export_count > 0) {
        try o.byte(7);
        const s = try o.begin();
        try o.uleb(export_count);
        try writeExports(&o);
        o.end(s);
    }
    if (try findStart()) |start| {
        try o.byte(8);
        const s = try o.begin();
        try o.uleb(start);
        o.end(s);
    }
    if (totals.elem > 0) {
        try o.byte(9);
        const s = try o.begin();
        try o.uleb(totals.elem);
        try writeElems(&o);
        o.end(s);
    }
    if (uses_data_count and totals.data > 0) {
        try o.byte(12);
        const s = try o.begin();
        try o.uleb(totals.data);
        o.end(s);
    }
    if (defined_funcs > 0) {
        try o.byte(10);
        const s = try o.begin();
        try o.uleb(defined_funcs);
        try o.bytes(code.buf[0..code.len]);
        o.end(s);
    }
    if (totals.data > 0) {
        try o.byte(11);
        const s = try o.begin();
        try o.uleb(totals.data);
        try writeDatas(&o);
        o.end(s);
    }
    return o.len;
}

fn compile(source: []const u8) Err!usize {
    src = source;
    lexAll();
    pos = 0;
    field_count = 0;
    names.reset();
    locals.reset();
    sig_generation +%= 1;
    if (sig_generation == 0) {
        @memset(&sig_gen, 0);
        sig_generation = 1;
    }
    type_count = 0;
    pool_len = 0;
    totals = .{};
    imported = .{};
    import_count = 0;
    export_count = 0;
    uses_data_count = false;
    frame_len = 0;
    label_len = 0;

    try declare();
    var code = Out.init(&code_buf);
    try compileFunctions(&code);
    return assemble(&code);
}

// ---------------------------------------------------------------------------
// QIP exports

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

export fn failure_modes_per_input_offset() u32 {
    return FAILURE_MODES;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
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
// Tests

const testing = std.testing;

fn expectModule(source: []const u8, expected: []const u8) !void {
    const n = compile(source) catch {
        std.debug.print("rejected at {d} mode {s}\n", .{ fail_offset, @tagName(fail_mode) });
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualSlices(u8, expected, output_buf[0..n]);
}

fn expectRejected(source: []const u8, offset: usize, mode: Failure) !void {
    try testing.expectError(error.Rejected, compile(source));
    try testing.expectEqual(mode, fail_mode);
    try testing.expectEqual(@as(u32, @intCast(offset)), fail_offset);
}

const wasm_header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

test "empty module" {
    try expectModule("(module)", &wasm_header);
    try expectModule("", &wasm_header);
    try expectModule(";; nothing\n(module $m (; block (; nested ;) ;))", &wasm_header);
}

test "function with export and folded operands" {
    // Operands of a folded instruction must be folded too, as in WABT.
    try expectRejected("(module (func (i32.add (local.get 0) local.get 1)))", 37, .syntax);
    try expectModule(
        \\(module
        \\  (func $add (export "add") (param $a i32) (param $b i32) (result i32)
        \\    (i32.add (local.get $a) (local.get $b))))
    ,
        &(wasm_header ++ [_]u8{
            0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
            0x03, 0x02, 0x01, 0x00,
            0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00,
            0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
        }),
    );
}

test "integer and float literals" {
    src = "-1 0xffffffff 4294967296 -2147483649 1_000 _1";
    lexAll();
    pos = 0;
    try testing.expectEqual(@as(u64, 0xffffffff), try intTok(try next(), 32));
    try testing.expectEqual(@as(u64, 0xffffffff), try intTok(try next(), 32));
    try testing.expectError(error.Rejected, intTok(try next(), 32));
    try testing.expectError(error.Rejected, intTok(try next(), 32));
    try testing.expectEqual(@as(u64, 1000), try intTok(try next(), 32));
    try testing.expectError(error.Rejected, intTok(try next(), 32));

    src = "0x1p-1 -0 nan -nan:0x200000 inf 0x1.fffffe8p127 0x1.ffffffp127 0x1.000001p0 0x1.000003p0 0x1p-149 0x1p-150 0x1.8p-150 1e39";
    lexAll();
    pos = 0;
    try testing.expectEqual(@as(u32, 0x3f000000), try floatTok(try next(), f32));
    try testing.expectEqual(@as(u32, 0x80000000), try floatTok(try next(), f32));
    try testing.expectEqual(@as(u32, 0x7fc00000), try floatTok(try next(), f32));
    try testing.expectEqual(@as(u32, 0xffa00000), try floatTok(try next(), f32));
    try testing.expectEqual(@as(u32, 0x7f800000), try floatTok(try next(), f32));
    try testing.expectEqual(@as(u32, 0x7f7fffff), try floatTok(try next(), f32)); // below the tie
    try testing.expectError(error.Rejected, floatTok(try next(), f32)); // tie rounds to even: overflow
    try testing.expectEqual(@as(u32, 0x3f800000), try floatTok(try next(), f32)); // tie, even stays
    try testing.expectEqual(@as(u32, 0x3f800002), try floatTok(try next(), f32)); // tie, odd rounds up
    try testing.expectEqual(@as(u32, 0x00000001), try floatTok(try next(), f32));
    try testing.expectEqual(@as(u32, 0x00000000), try floatTok(try next(), f32)); // tie to even zero
    try testing.expectEqual(@as(u32, 0x00000001), try floatTok(try next(), f32));
    try testing.expectError(error.Rejected, floatTok(try next(), f32));

    // Digits past 64 mantissa bits still break a tie. Zig 0.15.2's
    // std.fmt.parseFloat drops them and rounds this down to 0x3ff0000000000000.
    src = "0x1.0000000000000800000001p0 0x1.00000000000008p0";
    lexAll();
    pos = 0;
    try testing.expectEqual(@as(u64, 0x3ff0000000000001), try floatTok(try next(), f64));
    try testing.expectEqual(@as(u64, 0x3ff0000000000000), try floatTok(try next(), f64));
}

test "strings decode escapes" {
    try expectModule(
        \\(module (memory 1) (data (i32.const 0) "a\00\t\u{e9}" "\'"))
    ,
        &(wasm_header ++ [_]u8{
            0x05, 0x03, 0x01, 0x00, 0x01,
            0x0b, 0x0c, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x06, 'a', 0x00, 0x09, 0xc3, 0xa9, '\'',
        }),
    );
}

test "strings must be valid UTF-8 unless escaped" {
    // Unescaped multi-byte characters pass through unchanged.
    try expectModule(
        "(module (memory 1) (data (i32.const 0) \"\xc3\xa9\xe2\x9c\x93\xf0\x9f\x98\x80\"))",
        &(wasm_header ++ [_]u8{
            0x05, 0x03, 0x01, 0x00, 0x01,
            0x0b, 0x0f, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x09, 0xc3, 0xa9, 0xe2, 0x9c, 0x93, 0xf0, 0x9f, 0x98, 0x80,
        }),
    );
    // Escapes may still spell bytes that are not UTF-8 in data.
    try expectModule(
        "(module (memory 1) (data (i32.const 0) \"\\ff\\c3\"))",
        &(wasm_header ++ [_]u8{
            0x05, 0x03, 0x01, 0x00, 0x01,
            0x0b, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x02, 0xff, 0xc3,
        }),
    );
    const prefix = "(module (memory 1) (data (i32.const 0) \"a";
    const at = prefix.len;
    // Lone continuation byte, invalid lead byte, truncated sequence.
    try expectRejected(prefix ++ "\x80\"))", at, .syntax);
    try expectRejected(prefix ++ "\xff\"))", at, .syntax);
    try expectRejected(prefix ++ "\xc3\"))", at, .syntax);
    try expectRejected(prefix ++ "\xe2\x9c\"))", at, .syntax);
    // Overlong encoding and an encoded surrogate.
    try expectRejected(prefix ++ "\xc0\xaf\"))", at, .syntax);
    try expectRejected(prefix ++ "\xed\xa0\x80\"))", at, .syntax);
    // Beyond U+10FFFF.
    try expectRejected(prefix ++ "\xf4\x90\x80\x80\"))", at, .syntax);
    // Export names are checked too, and a truncated sequence at the end of
    // the input does not read past it.
    try expectRejected("(module (func) (export \"\xff\" (func 0)))", 24, .syntax);
    try expectRejected("(module (data \"\xf0\x9f", 15, .syntax);
}

test "rejections report offset and mode" {
    try expectRejected("(module (func i32.frob))", 14, .syntax);
    try expectRejected("(module (func call $missing))", 19, .name);
    try expectRejected("(module (func i32.const 4294967296 drop))", 24, .number);
    try expectRejected("(module (func try))", 14, .unsupported);
    try expectRejected("(module (func (local $x i32) (local $x i32)))", 36, .name);
    try expectRejected("(module (func (block)) (import \"m\" \"f\" (func)))", 24, .syntax);
    // `offset=` must come before `align=`.
    try expectRejected("(module (memory 1) (func (drop (i32.load align=1 offset=2 (i32.const 0)))))", 49, .syntax);
    // Import parameter names must be distinct; type definitions may repeat them.
    try expectRejected("(module (import \"a\" \"b\" (func (param $x i32) (param $x i32))))", 52, .name);
    try expectRejected("(module (func (import \"a\" \"b\") (param $x i32) (param $x i32)))", 53, .name);
    // Function names do not leak into constant expressions.
    try expectRejected("(module (func (param $x i32)) (global i32 (local.get $x)))", 53, .name);
    // The same instance accepts valid input after rejecting.
    try expectModule("(module)", &wasm_header);
}

test "follows WABT where it departs from the spec" {
    // Raw control characters other than a newline are kept in strings.
    try expectModule(
        "(module (data \"\x01\t\x7f\"))",
        &(wasm_header ++ [_]u8{ 0x0b, 0x06, 0x01, 0x01, 0x03, 0x01, 0x09, 0x7f }),
    );
    try expectRejected("(module (data \"a\nb\"))", 16, .syntax);
    // `\u{...}` takes hex digits only, without underscores.
    try expectRejected("(module (data \"\\u{1_0}\"))", 15, .syntax);
    // A single `memory.copy` index is the destination; the source is 0.
    try expectModule(
        "(module (memory 1) (memory 1) (func (memory.copy 1 (i32.const 0) (i32.const 0) (i32.const 0))))",
        &(wasm_header ++ [_]u8{
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
            0x03, 0x02, 0x01, 0x00,
            0x05, 0x05, 0x02, 0x00, 0x01, 0x00, 0x01,
            0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xfc, 0x0a, 0x01, 0x00, 0x0b,
        }),
    );
    // 32-bit limits are written unchecked.
    try expectModule(
        "(module (memory 0 0x1_0000_0000))",
        &(wasm_header ++ [_]u8{ 0x05, 0x08, 0x01, 0x01, 0x00, 0x80, 0x80, 0x80, 0x80, 0x10 }),
    );
    // A type index past the declared types is written as is, and as an
    // empty block type, unless an inline signature must match it.
    try expectModule(
        "(module (func (type 42)))",
        &(wasm_header ++ [_]u8{ 0x03, 0x02, 0x01, 0x2a, 0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b }),
    );
    try expectModule(
        "(module (func (block (type 9))))",
        &(wasm_header ++ [_]u8{
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
            0x03, 0x02, 0x01, 0x00,
            0x0a, 0x07, 0x01, 0x05, 0x00, 0x02, 0x40, 0x0b, 0x0b,
        }),
    );
    try expectRejected("(module (func (type 5) (param i32)))", 20, .name);
    try expectRejected("(module (func (block (type 9) (result i32) (i32.const 0)) drop))", 27, .name);
    // Nesting is not capped below what WABT handles.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendSlice(testing.allocator, "(module (func ");
    for (0..20000) |_| try deep.appendSlice(testing.allocator, "block ");
    for (0..20000) |_| try deep.appendSlice(testing.allocator, "end ");
    try deep.appendSlice(testing.allocator, "))");
    _ = try compile(deep.items);
}

test "every instruction name is unique and opcode table is consistent" {
    for (op_data.ops) |op| {
        const found = lookupOp(opName(op)).?;
        try testing.expectEqual(op.code, found.code);
        try testing.expectEqual(op.prefix, found.prefix);
    }
}
