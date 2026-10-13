//! wgsl-compute-to-wasm: compiles a small subset of WGSL compute shaders into a
//! QIP Content component.
//!
//! The shader runs once per element of the component's input (4 bytes for a
//! scalar array, 16 for `array<vec4f>`), the way a GPU dispatch runs once per
//! invocation:
//!
//!   override gain: f32 = 2.0;
//!   @group(0) @binding(0) var<storage, read> src: array<f32>;
//!   @group(0) @binding(1) var<storage, read_write> dst: array<f32>;
//!   @compute @workgroup_size(64)
//!   fn main(@builtin(global_invocation_id) id: vec3<u32>) {
//!     dst[id.x] = src[id.x] * gain;
//!   }
//!
//! The generated component's `render(input_size)` rejects input whose size is
//! not a multiple of the element size, sets the element count, and calls
//! the entry point with `id.x` from 0 to count - 1. The output has the same
//! byte length as the input. Each `override` becomes a `uniform_set_<name>`
//! export whose authored default is the override's initializer.
//!
//! Accepted subset:
//!
//! - Module scope: `override` and `const` with a literal initializer, at most
//!   one `var<storage, read>` and one `var<storage, read_write>` of
//!   `array<f32|i32|u32|vec4f>`, and one `@compute` function. Both buffers
//!   must have the same element size. A shader with only a read_write buffer
//!   transforms the input in place. Names must be declared before use.
//! - Entry parameter: none, or `@builtin(global_invocation_id)` as `vec3<u32>`;
//!   only `.x`, `.y` and `.z` are readable, and `.y` and `.z` are always 0.
//! - Statements: `let`, `var`, `const`, assignment and compound assignment to
//!   `var` or to one lane of a vector var (`v.a *= 0.5;`), `++`, `--`, whole
//!   buffer element stores, `if`/`else if`/`else`, blocks, `return;`, and
//!   `_ = expr;`.
//! - Expressions: bool, i32, u32 and f32 scalars, abstract integer and float
//!   literals, arithmetic, comparison, logical and bitwise operators, buffer
//!   element loads, `arrayLength(&buffer)`, scalar conversions such as
//!   `f32(x)`, and `abs`, `min`, `max`, `clamp`, `select`, `sqrt`, `floor`,
//!   `ceil`, `trunc`, `round` and `mix`.
//! - `vec2f`, `vec3f` and `vec4f` (or `vecN<f32>`) each lower to one v128:
//!   constructors `vecNf()`, `vecNf(s)`, `vecNf(v)`, and any mix of scalars
//!   and vectors that supplies N lanes, such as `vec4f(c.rgb, 1.0)`; members
//!   `.x` to `.w` or `.r` to `.a`, where one letter reads a lane and two to
//!   four letters swizzle (`c.bgr`, `c.xxxx`); `+ - * / %` lane-wise, with a
//!   scalar operand splatted; unary `-`; `abs`, `min`, `max`, `clamp`,
//!   `select`, `sqrt`, `floor`, `ceil`, `trunc` and `round`; `dot`; and
//!   `mix(a, b, t)` as a * (1 - t) + b * t, with t a vector or an f32.
//!   Buffers hold only `vec4f` vectors. Swizzle assignment, vector
//!   comparisons and integer or bool vectors are unsupported.
//!
//! Pixel kernels: a module with no `@compute` function and no buffers may
//! instead declare one or more point kernels, each a function that maps one
//! RGBA32F pixel to another:
//!
//!   override brightness: f32 = 0.0;
//!   fn pixel(c: vec4f) -> vec4f {
//!     return vec4f(c.rgb + brightness, c.a);
//!   }
//!
//! This compiles to a Tile component (see IMAGE.md): it exports `memory`,
//! `input_ptr`, `input_bytes_cap` and `tile_rgba32float_64x64`, which applies
//! every kernel to each pixel of the 64x64 tile in place, in source order.
//! Several kernels in one module are therefore a fused pipeline that keeps
//! f32 precision between stages. A kernel reads no other pixel and ignores
//! the tile's position, so it needs no halo. Its final statement must be
//! `return expr;`. Overrides become uniforms as in compute shaders, but keep
//! the value the host last set, because the host sets them once per image.
//!
//! WGSL's defined behavior replaces Wasm traps: integer division by zero
//! returns the dividend, remainder by zero returns 0, signed MIN / -1 returns
//! MIN, float-to-integer conversion saturates, out-of-range loads return 0, and
//! out-of-range stores are dropped. The output buffer starts zeroed.
//!
//! Rejections report `input_offset * 4 + mode`. Modes: 0 syntax error,
//! 1 unsupported WGSL feature or compiler limit, 2 type error, 3 unknown or
//! duplicate name.
//!
//! The compiler has no recursion: expressions are parsed with an explicit
//! operator stack into postfix order, which is also Wasm's evaluation order.

const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 256 * 1024;
const BODY_CAP: usize = 128 * 1024;
const MAX_TOKENS: usize = 16 * 1024;
const MAX_NODES: usize = 512;
const MAX_OPS: usize = 256;
const MAX_LOCALS: usize = 1024;
const MAX_SCOPE_NAMES: usize = 256;
const MAX_BLOCKS: usize = 64;
const MAX_OVERRIDES: usize = 32;
const MAX_CONSTS: usize = 64;
const MAX_KERNELS: usize = 32;
const KERNEL_CODE_CAP: usize = 64 * 1024;

const INPUT_CONTENT_TYPE = "text/wgsl";
const OUTPUT_CONTENT_TYPE = "application/wasm";

// Generated component memory: page 0 is unused, then the input and output
// regions. An in-place shader returns its input region as output.
const RUN_INPUT_PTR: u32 = 64 * 1024;
const RUN_BYTES_CAP: u32 = 1024 * 1024;
const RUN_OUTPUT_PTR: u32 = RUN_INPUT_PTR + RUN_BYTES_CAP;
const RUN_PAGES: u32 = (RUN_OUTPUT_PTR + RUN_BYTES_CAP) / (64 * 1024);

// Generated component function and global indices.
const FN_RENDER: u32 = 4;
const FN_MAIN: u32 = 5;
const FN_FIRST_SETTER: u32 = 6;
const GLOBAL_COUNT: u32 = 0;
const GLOBAL_FIRST_OVERRIDE: u32 = 1;

// Generated Tile component: one page holds the 64x64 RGBA32F tile.
const TILE_INPUT_PTR: u32 = 0;
const TILE_BYTES: u32 = 64 * 64 * 16;
const FN_TILE: u32 = 2;
const FN_FIRST_KERNEL: u32 = 3;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var body_buf: [BODY_CAP]u8 = undefined;
var kernel_code_buf: [KERNEL_CODE_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const Failure = enum(u32) { syntax = 0, unsupported = 1, type_mismatch = 2, name = 3 };
const FAILURE_MODES: u32 = 4;

const CompileError = error{Rejected};

var fail_offset: u32 = 0;
var fail_mode: Failure = .syntax;

fn fail(offset: u32, mode: Failure) CompileError {
    fail_offset = offset;
    fail_mode = mode;
    return error.Rejected;
}

// ---------------------------------------------------------------------------
// Lexer

const Tk = enum(u8) {
    eof,
    ident,
    int_lit,
    float_lit,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    semicolon,
    colon,
    dot,
    at,
    arrow,
    eq,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    lt,
    gt,
    le,
    ge,
    eq_eq,
    bang_eq,
    amp_amp,
    pipe_pipe,
    shl,
    shr,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    shl_eq,
    shr_eq,
    plus_plus,
    minus_minus,
};

const Token = struct { kind: Tk, start: u32, len: u32 };

const Punct = struct { text: []const u8, kind: Tk };

// Longest spellings first so that the first match is the longest.
const puncts = [_]Punct{
    .{ .text = "<<=", .kind = .shl_eq },
    .{ .text = ">>=", .kind = .shr_eq },
    .{ .text = "->", .kind = .arrow },
    .{ .text = "==", .kind = .eq_eq },
    .{ .text = "!=", .kind = .bang_eq },
    .{ .text = "<=", .kind = .le },
    .{ .text = ">=", .kind = .ge },
    .{ .text = "&&", .kind = .amp_amp },
    .{ .text = "||", .kind = .pipe_pipe },
    .{ .text = "<<", .kind = .shl },
    .{ .text = ">>", .kind = .shr },
    .{ .text = "+=", .kind = .plus_eq },
    .{ .text = "-=", .kind = .minus_eq },
    .{ .text = "*=", .kind = .star_eq },
    .{ .text = "/=", .kind = .slash_eq },
    .{ .text = "%=", .kind = .percent_eq },
    .{ .text = "&=", .kind = .amp_eq },
    .{ .text = "|=", .kind = .pipe_eq },
    .{ .text = "^=", .kind = .caret_eq },
    .{ .text = "++", .kind = .plus_plus },
    .{ .text = "--", .kind = .minus_minus },
    .{ .text = "(", .kind = .l_paren },
    .{ .text = ")", .kind = .r_paren },
    .{ .text = "{", .kind = .l_brace },
    .{ .text = "}", .kind = .r_brace },
    .{ .text = "[", .kind = .l_bracket },
    .{ .text = "]", .kind = .r_bracket },
    .{ .text = ",", .kind = .comma },
    .{ .text = ";", .kind = .semicolon },
    .{ .text = ":", .kind = .colon },
    .{ .text = ".", .kind = .dot },
    .{ .text = "@", .kind = .at },
    .{ .text = "=", .kind = .eq },
    .{ .text = "+", .kind = .plus },
    .{ .text = "-", .kind = .minus },
    .{ .text = "*", .kind = .star },
    .{ .text = "/", .kind = .slash },
    .{ .text = "%", .kind = .percent },
    .{ .text = "&", .kind = .amp },
    .{ .text = "|", .kind = .pipe },
    .{ .text = "^", .kind = .caret },
    .{ .text = "~", .kind = .tilde },
    .{ .text = "!", .kind = .bang },
    .{ .text = "<", .kind = .lt },
    .{ .text = ">", .kind = .gt },
};

var src: []const u8 = &.{};
var tokens: [MAX_TOKENS + 1]Token = undefined;
var tok_count: usize = 0;
var pos: usize = 0;

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn scanNumber(start: usize, kind: *Tk) CompileError!usize {
    var i = start;
    if (src[i] == '0' and i + 1 < src.len and (src[i + 1] == 'x' or src[i + 1] == 'X')) {
        i += 2;
        const digits = i;
        while (i < src.len and isHexDigit(src[i])) : (i += 1) {}
        if (i == digits) return fail(@intCast(i), .syntax);
        if (i < src.len and (src[i] == '.' or src[i] == 'p' or src[i] == 'P')) return fail(@intCast(start), .unsupported);
        if (i < src.len and (src[i] == 'i' or src[i] == 'u')) i += 1;
        kind.* = .int_lit;
    } else {
        var is_float = false;
        while (i < src.len and isDigit(src[i])) : (i += 1) {}
        if (i < src.len and src[i] == '.') {
            is_float = true;
            i += 1;
            while (i < src.len and isDigit(src[i])) : (i += 1) {}
        }
        if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
            is_float = true;
            i += 1;
            if (i < src.len and (src[i] == '+' or src[i] == '-')) i += 1;
            const digits = i;
            while (i < src.len and isDigit(src[i])) : (i += 1) {}
            if (i == digits) return fail(@intCast(i), .syntax);
        }
        if (i < src.len and src[i] == 'f') {
            is_float = true;
            i += 1;
        } else if (i < src.len and src[i] == 'h') {
            return fail(@intCast(start), .unsupported); // f16
        } else if (!is_float and i < src.len and (src[i] == 'i' or src[i] == 'u')) {
            i += 1;
        }
        kind.* = if (is_float) .float_lit else .int_lit;
    }
    if (i < src.len and isIdentContinue(src[i])) return fail(@intCast(i), .syntax);
    return i;
}

fn lex() CompileError!void {
    tok_count = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i += 2;
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            // WGSL block comments nest.
            const open = i;
            var depth: u32 = 1;
            i += 2;
            while (i < src.len and depth > 0) {
                if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (i + 1 < src.len and src[i] == '*' and src[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (depth != 0) return fail(@intCast(open), .syntax);
            continue;
        }
        const start = i;
        var kind: Tk = .eof;
        if (isIdentStart(c)) {
            i += 1;
            while (i < src.len and isIdentContinue(src[i])) : (i += 1) {}
            kind = .ident;
        } else if (isDigit(c) or (c == '.' and i + 1 < src.len and isDigit(src[i + 1]))) {
            i = try scanNumber(i, &kind);
        } else {
            for (puncts) |p| {
                if (std.mem.startsWith(u8, src[i..], p.text)) {
                    kind = p.kind;
                    i += p.text.len;
                    break;
                }
            }
            if (kind == .eof) return fail(@intCast(start), .syntax);
        }
        if (tok_count >= MAX_TOKENS) return fail(@intCast(start), .unsupported);
        tokens[tok_count] = .{ .kind = kind, .start = @intCast(start), .len = @intCast(i - start) };
        tok_count += 1;
    }
    tokens[tok_count] = .{ .kind = .eof, .start = @intCast(src.len), .len = 0 };
}

fn peek() Token {
    return tokens[pos];
}

fn peekAt(ahead: usize) Token {
    const i = pos + ahead;
    return if (i < tok_count) tokens[i] else tokens[tok_count];
}

fn text(t: Token) []const u8 {
    return src[t.start..][0..t.len];
}

fn isWord(t: Token, word: []const u8) bool {
    return t.kind == .ident and std.mem.eql(u8, text(t), word);
}

fn advance() Token {
    const t = tokens[pos];
    if (pos < tok_count) pos += 1;
    return t;
}

fn expect(kind: Tk) CompileError!Token {
    const t = peek();
    if (t.kind != kind) return fail(t.start, .syntax);
    return advance();
}

fn expectWord(word: []const u8) CompileError!Token {
    const t = peek();
    if (!isWord(t, word)) return fail(t.start, .syntax);
    return advance();
}

// ---------------------------------------------------------------------------
// Types and names

const Ty = enum(u8) { void, bool, i32, u32, f32, vec2f, vec3f, vec4f, abstract_int, abstract_float };

// Every vector lowers to one v128; lanes past its length are unused.
fn isVec(t: Ty) bool {
    return t == .vec2f or t == .vec3f or t == .vec4f;
}

fn vecLen(t: Ty) u8 {
    return switch (t) {
        .vec2f => 2,
        .vec3f => 3,
        .vec4f => 4,
        else => 1,
    };
}

fn vecOf(len: u8) Ty {
    return switch (len) {
        2 => .vec2f,
        3 => .vec3f,
        else => .vec4f,
    };
}

fn isAbstract(t: Ty) bool {
    return t == .abstract_int or t == .abstract_float;
}

fn isInt(t: Ty) bool {
    return t == .i32 or t == .u32 or t == .abstract_int;
}

fn isNumeric(t: Ty) bool {
    return isInt(t) or t == .f32 or t == .abstract_float;
}

fn isScalar(t: Ty) bool {
    return t == .bool or isNumeric(t);
}

fn defaultTy(t: Ty) Ty {
    return switch (t) {
        .abstract_int => .i32,
        .abstract_float => .f32,
        else => t,
    };
}

fn convertible(from: Ty, to: Ty) bool {
    return switch (from) {
        .abstract_int => to == .i32 or to == .u32 or to == .f32,
        .abstract_float => to == .f32,
        else => from == to,
    };
}

fn unify(a: Ty, b: Ty, offset: u32) CompileError!Ty {
    if (a == b) return a;
    if (isAbstract(a) and isAbstract(b)) return .abstract_float;
    if (isAbstract(a) and convertible(a, b)) return b;
    if (isAbstract(b) and convertible(b, a)) return a;
    return fail(offset, .type_mismatch);
}

fn valType(t: Ty) u8 {
    return switch (t) {
        .f32 => 0x7d,
        .vec2f, .vec3f, .vec4f => 0x7b,
        else => 0x7f,
    };
}

// log2 of a buffer element's byte size.
fn elemShift(t: Ty) u5 {
    return if (t == .vec4f) 4 else 2;
}

fn parseScalarType() CompileError!Ty {
    const t = advance();
    if (t.kind != .ident) return fail(t.start, .syntax);
    const name = text(t);
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    return fail(t.start, .unsupported);
}

// The length of a vector type spelled `vecNf` (`suffixed`) or `vecN`.
fn vecWordLen(t: Token, suffixed: bool) ?u8 {
    const name = text(t);
    if (t.kind != .ident or name.len != (if (suffixed) @as(usize, 5) else 4)) return null;
    if (!std.mem.startsWith(u8, name, "vec") or (suffixed and name[4] != 'f')) return null;
    return if (name[3] >= '2' and name[3] <= '4') name[3] - '0' else null;
}

// A scalar type, `vecNf` or `vecN<f32>` for N in 2..4.
fn parseType() CompileError!Ty {
    const t = peek();
    if (vecWordLen(t, true)) |len| {
        _ = advance();
        return vecOf(len);
    }
    const len = vecWordLen(t, false) orelse return parseScalarType();
    _ = advance();
    _ = try expect(.lt);
    const elem = peek();
    if (!isWord(elem, "f32")) return fail(elem.start, .unsupported);
    _ = advance();
    if (peek().kind == .shr) {
        // `array<vec4<f32>>` lexes its closing `>>` as one token: consume half.
        tokens[pos].kind = .gt;
        tokens[pos].start += 1;
        tokens[pos].len = 1;
    } else {
        _ = try expect(.gt);
    }
    return vecOf(len);
}

const Literal = struct { ty: Ty, int_value: i64 = 0, float_value: f64 = 0 };

fn intLiteral(t: Token) CompileError!Literal {
    var digits = text(t);
    var ty: Ty = .abstract_int;
    const last = digits[digits.len - 1];
    if (last == 'i' or last == 'u') {
        ty = if (last == 'i') .i32 else .u32;
        digits = digits[0 .. digits.len - 1];
    }
    var base: u64 = 10;
    if (digits.len > 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X')) {
        base = 16;
        digits = digits[2..];
    }
    var value: u64 = 0;
    for (digits) |d| {
        const digit: u64 = if (isDigit(d)) d - '0' else (d | 0x20) - 'a' + 10;
        value = value * base + digit;
        if (value > std.math.maxInt(i64)) return fail(t.start, .type_mismatch);
    }
    var lit = Literal{ .ty = .abstract_int, .int_value = @intCast(value) };
    if (ty != .abstract_int) try concretizeLiteral(&lit, ty, t.start);
    return lit;
}

fn floatLiteral(t: Token) CompileError!Literal {
    var digits = text(t);
    const is_f32 = digits[digits.len - 1] == 'f';
    if (is_f32) digits = digits[0 .. digits.len - 1];
    const value = std.fmt.parseFloat(f64, digits) catch return fail(t.start, .syntax);
    var lit = Literal{ .ty = .abstract_float, .float_value = value };
    if (is_f32) try concretizeLiteral(&lit, .f32, t.start);
    return lit;
}

fn concretizeLiteral(lit: *Literal, ty: Ty, offset: u32) CompileError!void {
    if (lit.ty == ty) return;
    if (!convertible(lit.ty, ty)) return fail(offset, .type_mismatch);
    switch (lit.ty) {
        .abstract_int => switch (ty) {
            .i32 => if (lit.int_value < std.math.minInt(i32) or lit.int_value > std.math.maxInt(i32))
                return fail(offset, .type_mismatch),
            .u32 => if (lit.int_value < 0 or lit.int_value > std.math.maxInt(u32))
                return fail(offset, .type_mismatch),
            .f32 => lit.float_value = @floatFromInt(lit.int_value),
            else => unreachable,
        },
        else => {},
    }
    if (ty == .f32) {
        const narrowed: f32 = @floatCast(lit.float_value);
        if (!std.math.isFinite(narrowed)) return fail(offset, .type_mismatch);
        lit.float_value = narrowed;
    }
    lit.ty = ty;
}

// A literal with an optional leading minus sign, for module-scope initializers.
fn parseConstLiteral() CompileError!Literal {
    const negate = peek().kind == .minus;
    if (negate) _ = advance();
    const t = advance();
    var lit: Literal = switch (t.kind) {
        .int_lit => try intLiteral(t),
        .float_lit => try floatLiteral(t),
        .ident => if (!negate and isWord(t, "true"))
            Literal{ .ty = .bool, .int_value = 1 }
        else if (!negate and isWord(t, "false"))
            Literal{ .ty = .bool }
        else
            return fail(t.start, .unsupported),
        else => return fail(t.start, .syntax),
    };
    if (negate) {
        if (lit.ty == .u32) return fail(t.start, .type_mismatch);
        lit.int_value = -lit.int_value;
        lit.float_value = -lit.float_value;
        if (lit.ty == .i32 and lit.int_value < std.math.minInt(i32)) return fail(t.start, .type_mismatch);
    }
    return lit;
}

const Local = struct { name: Token, index: u32, ty: Ty, mutable: bool };
const Override = struct { name: Token, ty: Ty, value: Literal };
const ModuleConst = struct { name: Token, value: Literal };
const Buffer = struct { name: Token, elem: Ty, declared: bool = false };

var scope: [MAX_SCOPE_NAMES]Local = undefined;
var scope_len: usize = 0;
var overrides: [MAX_OVERRIDES]Override = undefined;
var override_count: usize = 0;
var consts: [MAX_CONSTS]ModuleConst = undefined;
var const_count: usize = 0;
var input_buffer: Buffer = undefined;
var output_buffer: Buffer = undefined;
var gid_name: ?Token = null;
var have_entry = false;
// Pixel kernels: code entries are complete once each kernel is parsed.
var kernel_count: usize = 0;
var in_kernel = false;
var kernel_returned = false;

// Main function locals after parameter 0 (`global_invocation_id.x`).
var local_types: [MAX_LOCALS]u8 = undefined;
var local_count: usize = 0;

fn sameName(a: Token, b: Token) bool {
    return std.mem.eql(u8, text(a), text(b));
}

fn moduleNameTaken(name: Token) bool {
    for (overrides[0..override_count]) |o| if (sameName(o.name, name)) return true;
    for (consts[0..const_count]) |c| if (sameName(c.name, name)) return true;
    if (input_buffer.declared and sameName(input_buffer.name, name)) return true;
    if (output_buffer.declared and sameName(output_buffer.name, name)) return true;
    return false;
}

fn lookupLocal(name: Token) ?Local {
    var i = scope_len;
    while (i > 0) {
        i -= 1;
        if (sameName(scope[i].name, name)) return scope[i];
    }
    return null;
}

fn allocLocal(ty: Ty) CompileError!u32 {
    if (local_count >= MAX_LOCALS) return fail(peek().start, .unsupported);
    local_types[local_count] = valType(ty);
    local_count += 1;
    return @intCast(local_count); // index 0 is the parameter
}

// ---------------------------------------------------------------------------
// Byte writers

const Buf = struct {
    bytes: []u8,
    len: usize = 0,

    fn byte(self: *Buf, b: u8) CompileError!void {
        if (self.len >= self.bytes.len) return fail(peek().start, .unsupported);
        self.bytes[self.len] = b;
        self.len += 1;
    }

    fn raw(self: *Buf, bytes: []const u8) CompileError!void {
        for (bytes) |b| try self.byte(b);
    }

    fn uleb(self: *Buf, value_in: u64) CompileError!void {
        var value = value_in;
        while (true) {
            const b: u8 = @intCast(value & 0x7f);
            value >>= 7;
            if (value == 0) return self.byte(b);
            try self.byte(b | 0x80);
        }
    }

    fn sleb(self: *Buf, value_in: i64) CompileError!void {
        var value = value_in;
        while (true) {
            const b: u8 = @intCast(value & 0x7f);
            value >>= 7;
            const done = (value == 0 and (b & 0x40) == 0) or (value == -1 and (b & 0x40) != 0);
            if (done) return self.byte(b);
            try self.byte(b | 0x80);
        }
    }

    fn name(self: *Buf, s: []const u8) CompileError!void {
        try self.uleb(s.len);
        try self.raw(s);
    }

    fn i32Const(self: *Buf, value: i32) CompileError!void {
        try self.byte(0x41);
        try self.sleb(value);
    }

    fn f32Const(self: *Buf, value: f32) CompileError!void {
        try self.byte(0x43);
        const bits: u32 = @bitCast(value);
        try self.raw(&.{ @truncate(bits), @truncate(bits >> 8), @truncate(bits >> 16), @truncate(bits >> 24) });
    }

    fn simd(self: *Buf, op: u32) CompileError!void {
        try self.byte(0xfd);
        try self.uleb(op);
    }

    fn simdLane(self: *Buf, op: u32, lane: u8) CompileError!void {
        try self.simd(op);
        try self.byte(lane);
    }

    fn localGet(self: *Buf, index: u32) CompileError!void {
        try self.byte(0x20);
        try self.uleb(index);
    }

    fn localSet(self: *Buf, index: u32) CompileError!void {
        try self.byte(0x21);
        try self.uleb(index);
    }

    fn localTee(self: *Buf, index: u32) CompileError!void {
        try self.byte(0x22);
        try self.uleb(index);
    }

    // Reserves room for a 5-byte size; `endSize` writes the minimal encoding.
    fn beginSize(self: *Buf) CompileError!usize {
        const at = self.len;
        try self.raw(&.{ 0, 0, 0, 0, 0 });
        return at;
    }

    fn endSize(self: *Buf, at: usize) void {
        const size = self.len - at - 5;
        var leb: [5]u8 = undefined;
        var n: usize = 0;
        var value = size;
        while (true) {
            const b: u8 = @intCast(value & 0x7f);
            value >>= 7;
            leb[n] = if (value == 0) b else b | 0x80;
            n += 1;
            if (value == 0) break;
        }
        std.mem.copyForwards(u8, self.bytes[at + n .. self.len - 5 + n], self.bytes[at + 5 .. self.len]);
        @memcpy(self.bytes[at..][0..n], leb[0..n]);
        self.len -= 5 - n;
    }
};

var body: Buf = .{ .bytes = &body_buf };
var kernel_code: Buf = .{ .bytes = &kernel_code_buf };

// SIMD opcodes, after the 0xfd prefix.
const SIMD_LOAD: u32 = 0;
const SIMD_STORE: u32 = 11;
const SIMD_CONST: u32 = 12;
const SIMD_I8X16_SHUFFLE: u32 = 13;
const SIMD_F32X4_SPLAT: u32 = 19;
const SIMD_F32X4_EXTRACT_LANE: u32 = 31;
const SIMD_F32X4_REPLACE_LANE: u32 = 32;
const SIMD_F32X4_CEIL: u32 = 103;
const SIMD_F32X4_FLOOR: u32 = 104;
const SIMD_F32X4_TRUNC: u32 = 105;
const SIMD_F32X4_NEAREST: u32 = 106;
const SIMD_F32X4_ABS: u32 = 224;
const SIMD_F32X4_NEG: u32 = 225;
const SIMD_F32X4_SQRT: u32 = 227;
const SIMD_F32X4_ADD: u32 = 228;
const SIMD_F32X4_SUB: u32 = 229;
const SIMD_F32X4_MUL: u32 = 230;
const SIMD_F32X4_DIV: u32 = 231;
const SIMD_F32X4_MIN: u32 = 232;
const SIMD_F32X4_MAX: u32 = 233;

fn literalValue(lit: Literal) i32 {
    return @truncate(lit.int_value);
}

fn emitLiteral(w: *Buf, lit: Literal) CompileError!void {
    if (lit.ty == .f32) return w.f32Const(@floatCast(lit.float_value));
    if (isVec(lit.ty)) {
        // Only the zero vector is a literal.
        try w.simd(SIMD_CONST);
        return w.raw(&([_]u8{0} ** 16));
    }
    try w.i32Const(literalValue(lit));
}

// ---------------------------------------------------------------------------
// Expressions

const NodeKind = enum(u8) { lit, local, override, gid_x, array_len, load, lane, swizzle, unary, binary, call };

const Callee = enum(u8) { abs, min, max, clamp, select, sqrt, floor, ceil, trunc, round, dot, mix, to_f32, to_i32, to_u32, to_bool, vec2f, vec3f, vec4f };

const Node = struct {
    kind: NodeKind,
    // Tk for unary and binary, Callee for call, buffer 0/1 for load, index
    // for lane, and source lanes packed two bits each for swizzle.
    op: u8 = 0,
    ty: Ty,
    opnd_ty: Ty = .void,
    kids: [4]u16 = .{ 0, 0, 0, 0 },
    argc: u8 = 0,
    ref: u32 = 0,
    lit: Literal = .{ .ty = .void },
    offset: u32,
};

const OpKind = enum(u8) { paren, call, bracket, unary, binary };

const OpEntry = struct { kind: OpKind, op: u8, prec: u8 = 0, argc: u8 = 0, offset: u32 };

var nodes: [MAX_NODES]Node = undefined;
var node_len: usize = 0;
var ops: [MAX_OPS]OpEntry = undefined;
var op_len: usize = 0;
var vals: [MAX_NODES]u16 = undefined;
var val_len: usize = 0;

const UNARY_PREC: u8 = 11;

fn binaryPrec(kind: Tk) ?u8 {
    return switch (kind) {
        .pipe_pipe => 1,
        .amp_amp => 2,
        .pipe => 3,
        .caret => 4,
        .amp => 5,
        .eq_eq, .bang_eq => 6,
        .lt, .gt, .le, .ge => 7,
        .shl, .shr => 8,
        .plus, .minus => 9,
        .star, .slash, .percent => 10,
        else => null,
    };
}

fn pushNode(node: Node) CompileError!u16 {
    if (node_len >= MAX_NODES) return fail(node.offset, .unsupported);
    nodes[node_len] = node;
    node_len += 1;
    const index: u16 = @intCast(node_len - 1);
    vals[val_len] = index;
    val_len += 1;
    return index;
}

fn popVal() u16 {
    val_len -= 1;
    return vals[val_len];
}

fn pushOp(entry: OpEntry) CompileError!void {
    if (op_len >= MAX_OPS) return fail(entry.offset, .unsupported);
    ops[op_len] = entry;
    op_len += 1;
}

fn applyUnary(entry: OpEntry) CompileError!void {
    if (val_len < 1) return fail(entry.offset, .syntax);
    const a = popVal();
    const at = nodes[a].ty;
    const kind: Tk = @enumFromInt(entry.op);
    // Fold a minus sign into a literal so that `-2147483648` fits in i32.
    if (kind == .minus and nodes[a].kind == .lit and isNumeric(at) and at != .u32) {
        nodes[a].lit.int_value = -nodes[a].lit.int_value;
        nodes[a].lit.float_value = -nodes[a].lit.float_value;
        if (at == .i32 and nodes[a].lit.int_value > std.math.maxInt(i32)) return fail(entry.offset, .type_mismatch);
        nodes[a].offset = entry.offset;
        vals[val_len] = a;
        val_len += 1;
        return;
    }
    const ok = switch (kind) {
        .minus => (isNumeric(at) and at != .u32) or isVec(at),
        .bang => at == .bool,
        .tilde => isInt(at),
        else => false,
    };
    if (!ok) return fail(entry.offset, .type_mismatch);
    _ = try pushNode(.{ .kind = .unary, .op = entry.op, .ty = at, .opnd_ty = at, .kids = .{ a, 0, 0, 0 }, .offset = entry.offset });
}

fn applyBinary(entry: OpEntry) CompileError!void {
    if (val_len < 2) return fail(entry.offset, .syntax);
    const b = popVal();
    const a = popVal();
    const at = nodes[a].ty;
    const bt = nodes[b].ty;
    const kind: Tk = @enumFromInt(entry.op);
    var ty: Ty = undefined;
    var opnd: Ty = undefined;
    if (isVec(at) or isVec(bt)) {
        // Vector arithmetic; a scalar operand is splatted to every lane.
        const arith = switch (kind) {
            .plus, .minus, .star, .slash, .percent => true,
            else => false,
        };
        const vt = if (isVec(at)) at else bt;
        const lanes_ok = (at == vt or convertible(at, .f32)) and (bt == vt or convertible(bt, .f32));
        if (!arith or !lanes_ok) return fail(entry.offset, .type_mismatch);
        _ = try pushNode(.{ .kind = .binary, .op = entry.op, .ty = vt, .opnd_ty = vt, .kids = .{ a, b, 0, 0 }, .offset = entry.offset });
        return;
    }
    switch (kind) {
        .plus, .minus, .star, .slash, .percent => {
            opnd = try unify(at, bt, entry.offset);
            if (!isNumeric(opnd)) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .lt, .gt, .le, .ge => {
            opnd = try unify(at, bt, entry.offset);
            if (!isNumeric(opnd)) return fail(entry.offset, .type_mismatch);
            ty = .bool;
        },
        .eq_eq, .bang_eq => {
            opnd = try unify(at, bt, entry.offset);
            if (!isScalar(opnd)) return fail(entry.offset, .type_mismatch);
            ty = .bool;
        },
        .amp_amp, .pipe_pipe => {
            if (at != .bool or bt != .bool) return fail(entry.offset, .type_mismatch);
            opnd = .bool;
            ty = .bool;
        },
        .amp, .pipe, .caret => {
            opnd = try unify(at, bt, entry.offset);
            if (!(isInt(opnd) or (opnd == .bool and kind != .caret))) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .shl, .shr => {
            if (!isInt(at) or !(bt == .u32 or bt == .abstract_int)) return fail(entry.offset, .type_mismatch);
            opnd = at;
            ty = at;
        },
        else => return fail(entry.offset, .syntax),
    }
    _ = try pushNode(.{ .kind = .binary, .op = entry.op, .ty = ty, .opnd_ty = opnd, .kids = .{ a, b, 0, 0 }, .offset = entry.offset });
}

fn applyOp(entry: OpEntry) CompileError!void {
    switch (entry.kind) {
        .unary => try applyUnary(entry),
        .binary => try applyBinary(entry),
        else => return fail(entry.offset, .syntax),
    }
}

fn reduceWhile(prec: u8) CompileError!void {
    while (op_len > 0) {
        const top = ops[op_len - 1];
        if ((top.kind != .unary and top.kind != .binary) or top.prec < prec) return;
        op_len -= 1;
        try applyOp(top);
    }
}

fn innermostOpen() ?usize {
    var i = op_len;
    while (i > 0) {
        i -= 1;
        const kind = ops[i].kind;
        if (kind == .paren or kind == .call or kind == .bracket) return i;
    }
    return null;
}

// Applies every operator above the innermost open paren, call or bracket.
fn reduceToOpen() CompileError!void {
    try reduceWhile(0);
}

fn lookupCallee(name: []const u8) ?Callee {
    const table = [_]struct { []const u8, Callee }{
        .{ "abs", .abs },       .{ "min", .min },     .{ "max", .max },     .{ "clamp", .clamp },
        .{ "select", .select }, .{ "sqrt", .sqrt },   .{ "floor", .floor }, .{ "ceil", .ceil },
        .{ "trunc", .trunc },   .{ "round", .round }, .{ "dot", .dot },     .{ "mix", .mix },
        .{ "f32", .to_f32 },    .{ "i32", .to_i32 },  .{ "u32", .to_u32 },  .{ "bool", .to_bool },
        .{ "vec2f", .vec2f },   .{ "vec3f", .vec3f }, .{ "vec4f", .vec4f },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    return null;
}

fn conversionTarget(callee: Callee) ?Ty {
    return switch (callee) {
        .to_f32 => .f32,
        .to_i32 => .i32,
        .to_u32 => .u32,
        .to_bool => .bool,
        .vec2f => .vec2f,
        .vec3f => .vec3f,
        .vec4f => .vec4f,
        else => null,
    };
}

fn applyCall(entry: OpEntry, argc: u8) CompileError!void {
    const callee: Callee = @enumFromInt(entry.op);
    const want: u8 = switch (callee) {
        .min, .max, .dot => 2,
        .clamp, .select, .mix => 3,
        .vec2f, .vec3f, .vec4f => @min(argc, vecLen(conversionTarget(callee).?)),
        else => 1,
    };
    if (argc != want or val_len < argc) return fail(entry.offset, .type_mismatch);
    var kids: [4]u16 = .{ 0, 0, 0, 0 };
    var i: usize = argc;
    while (i > 0) {
        i -= 1;
        kids[i] = popVal();
    }
    const t0 = nodes[kids[0]].ty;
    var ty: Ty = undefined;
    var opnd: Ty = undefined;
    switch (callee) {
        .abs => {
            if (!isNumeric(t0) and !isVec(t0)) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = t0;
        },
        .min, .max, .clamp => {
            opnd = try unify(t0, nodes[kids[1]].ty, entry.offset);
            if (callee == .clamp) opnd = try unify(opnd, nodes[kids[2]].ty, entry.offset);
            if (!isNumeric(opnd) and !isVec(opnd)) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .select => {
            opnd = try unify(t0, nodes[kids[1]].ty, entry.offset);
            if (!(isScalar(opnd) or isVec(opnd)) or nodes[kids[2]].ty != .bool) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .sqrt, .floor, .ceil, .trunc, .round => {
            ty = if (isVec(t0)) t0 else .f32;
            if (!(t0 == .f32 or isVec(t0) or isAbstract(t0))) return fail(entry.offset, .type_mismatch);
            opnd = ty;
        },
        .dot => {
            if (!isVec(t0) or nodes[kids[1]].ty != t0) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = .f32;
        },
        .mix => {
            // mix(a, b, t) with t matching a and b, or an f32 for vectors.
            opnd = try unify(t0, nodes[kids[1]].ty, entry.offset);
            if (!isVec(opnd)) opnd = if (convertible(opnd, .f32)) .f32 else return fail(entry.offset, .type_mismatch);
            const tt = nodes[kids[2]].ty;
            if (!(tt == opnd or convertible(tt, .f32))) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .vec2f, .vec3f, .vec4f => {
            // vecN(v) copies, vecN(s) splats, and otherwise the scalar and
            // vector arguments supply exactly N lanes, as in vec4f(v.rgb, 1.0).
            ty = conversionTarget(callee).?;
            var lanes: u8 = 0;
            for (kids[0..argc]) |kid| {
                const kt = nodes[kid].ty;
                if (!(convertible(kt, .f32) or isVec(kt))) return fail(nodes[kid].offset, .type_mismatch);
                lanes += vecLen(kt);
            }
            const ok = if (argc == 1) (t0 == ty or !isVec(t0)) else lanes == vecLen(ty);
            if (!ok) return fail(entry.offset, .type_mismatch);
            opnd = t0;
        },
        .to_f32, .to_i32, .to_u32, .to_bool => {
            if (!isScalar(t0)) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = conversionTarget(callee).?;
        },
    }
    _ = try pushNode(.{ .kind = .call, .op = entry.op, .ty = ty, .opnd_ty = opnd, .kids = kids, .argc = argc, .offset = entry.offset });
}

fn applyLoad(entry: OpEntry) CompileError!void {
    if (val_len < 1) return fail(entry.offset, .syntax);
    const index = popVal();
    const it = nodes[index].ty;
    if (!isInt(it)) return fail(nodes[index].offset, .type_mismatch);
    const buffer = if (entry.op == 0) input_buffer else output_buffer;
    _ = try pushNode(.{ .kind = .load, .op = entry.op, .ty = buffer.elem, .opnd_ty = it, .kids = .{ index, 0, 0, 0 }, .offset = entry.offset });
}

fn bufferId(name: Token) ?u8 {
    if (input_buffer.declared and sameName(input_buffer.name, name)) return 0;
    if (output_buffer.declared and sameName(output_buffer.name, name)) return 1;
    return null;
}

// Opens a call whose callee name is the current token. Returns true when the
// call was a complete zero-argument constructor.
fn parseConstructorCall(t: Token, callee: Callee) CompileError!bool {
    if (peekAt(2).kind == .r_paren) {
        // A zero-argument constructor such as `f32()` is the zero value.
        const target = conversionTarget(callee) orelse return fail(t.start, .type_mismatch);
        pos += 3;
        _ = try pushNode(.{ .kind = .lit, .ty = target, .lit = .{ .ty = target }, .offset = t.start });
        return true;
    }
    pos += 2;
    try pushOp(.{ .kind = .call, .op = @intFromEnum(callee), .offset = t.start });
    return false;
}

// A vector member such as `.x` or `.bgr`: one to four lanes, all named from
// `xyzw` or all from `rgba`, each within the source vector's length.
const Swizzle = struct {
    lanes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u8,

    fn packedLanes(self: Swizzle) u8 {
        var bits: u8 = 0;
        for (self.lanes, 0..) |lane, i| bits |= lane << @intCast(2 * i);
        return bits;
    }
};

fn parseSwizzle(member: Token, source: Ty) CompileError!Swizzle {
    const field = text(member);
    if (field.len == 0 or field.len > 4) return fail(member.start, .name);
    const set: []const u8 = if (std.mem.indexOfScalar(u8, "rgba", field[0]) != null) "rgba" else "xyzw";
    var swizzle = Swizzle{ .len = @intCast(field.len) };
    for (field, 0..) |c, i| {
        const lane = std.mem.indexOfScalar(u8, set, c) orelse return fail(member.start, .name);
        if (lane >= vecLen(source)) return fail(member.start, .name);
        swizzle.lanes[i] = @intCast(lane);
    }
    return swizzle;
}

// Parses an operand that starts with an identifier. Returns true when the
// operand is complete and false when it opened a call or index.
fn parseIdentOperand() CompileError!bool {
    const t = peek();
    const name = text(t);
    const next = peekAt(1);
    if (vecWordLen(t, false)) |len| if (next.kind == .lt and isWord(peekAt(2), "f32") and
        peekAt(3).kind == .gt and peekAt(4).kind == .l_paren)
    {
        // `vec4<f32>(...)` is spelled with three more tokens than `vec4f(...)`.
        pos += 3;
        return parseConstructorCall(t, switch (len) {
            2 => .vec2f,
            3 => .vec3f,
            else => .vec4f,
        });
    };
    if (next.kind == .l_paren) {
        if (std.mem.eql(u8, name, "arrayLength")) {
            _ = advance();
            _ = advance();
            _ = try expect(.amp);
            const buf_tok = try expect(.ident);
            if (bufferId(buf_tok) == null) return fail(buf_tok.start, .name);
            _ = try expect(.r_paren);
            _ = try pushNode(.{ .kind = .array_len, .ty = .u32, .offset = t.start });
            return true;
        }
        const callee = lookupCallee(name) orelse return fail(t.start, .unsupported);
        return parseConstructorCall(t, callee);
    }
    if (isWord(t, "true") or isWord(t, "false")) {
        _ = advance();
        const value: i64 = if (isWord(t, "true")) 1 else 0;
        _ = try pushNode(.{ .kind = .lit, .ty = .bool, .lit = .{ .ty = .bool, .int_value = value }, .offset = t.start });
        return true;
    }
    if (lookupLocal(t)) |local| {
        _ = advance();
        _ = try pushNode(.{ .kind = .local, .ty = local.ty, .ref = local.index, .offset = t.start });
        return true;
    }
    if (gid_name) |gid| if (sameName(gid, t)) {
        _ = advance();
        _ = try expect(.dot);
        const member = try expect(.ident);
        const field = text(member);
        if (std.mem.eql(u8, field, "x")) {
            _ = try pushNode(.{ .kind = .gid_x, .ty = .u32, .offset = t.start });
        } else if (std.mem.eql(u8, field, "y") or std.mem.eql(u8, field, "z")) {
            _ = try pushNode(.{ .kind = .lit, .ty = .u32, .lit = .{ .ty = .u32 }, .offset = t.start });
        } else {
            return fail(member.start, .unsupported);
        }
        return true;
    };
    for (overrides[0..override_count], 0..) |o, i| if (sameName(o.name, t)) {
        _ = advance();
        _ = try pushNode(.{ .kind = .override, .ty = o.ty, .ref = @intCast(i), .offset = t.start });
        return true;
    };
    for (consts[0..const_count]) |c| if (sameName(c.name, t)) {
        _ = advance();
        _ = try pushNode(.{ .kind = .lit, .ty = c.value.ty, .lit = c.value, .offset = t.start });
        return true;
    };
    if (bufferId(t)) |id| {
        if (next.kind != .l_bracket) return fail(next.start, .unsupported);
        pos += 2;
        try pushOp(.{ .kind = .bracket, .op = id, .offset = t.start });
        return false;
    }
    return fail(t.start, .name);
}

// Parses one expression into `nodes` in postfix order and returns its root.
fn parseExpr() CompileError!u16 {
    node_len = 0;
    op_len = 0;
    val_len = 0;
    const start = peek().start;
    var expect_operand = true;
    while (true) {
        const t = peek();
        if (expect_operand) {
            switch (t.kind) {
                .int_lit, .float_lit => {
                    _ = advance();
                    const lit = if (t.kind == .int_lit) try intLiteral(t) else try floatLiteral(t);
                    _ = try pushNode(.{ .kind = .lit, .ty = lit.ty, .lit = lit, .offset = t.start });
                    expect_operand = false;
                },
                .ident => expect_operand = !(try parseIdentOperand()),
                .l_paren => {
                    _ = advance();
                    try pushOp(.{ .kind = .paren, .op = 0, .offset = t.start });
                },
                .minus, .bang, .tilde => {
                    _ = advance();
                    try pushOp(.{ .kind = .unary, .op = @intFromEnum(t.kind), .prec = UNARY_PREC, .offset = t.start });
                },
                .amp, .star => return fail(t.start, .unsupported), // pointers
                else => return fail(t.start, .syntax),
            }
            continue;
        }
        if (binaryPrec(t.kind)) |prec| {
            try reduceWhile(prec);
            _ = advance();
            try pushOp(.{ .kind = .binary, .op = @intFromEnum(t.kind), .prec = prec, .offset = t.start });
            expect_operand = true;
            continue;
        }
        switch (t.kind) {
            .r_paren, .r_bracket, .comma => {
                const open_at = innermostOpen() orelse break;
                const open = ops[open_at];
                if (t.kind == .comma) {
                    if (open.kind != .call) break;
                    try reduceToOpen();
                    ops[op_len - 1].argc += 1;
                    _ = advance();
                    expect_operand = true;
                    continue;
                }
                const matches = if (t.kind == .r_bracket) open.kind == .bracket else open.kind != .bracket;
                if (!matches) return fail(t.start, .syntax);
                try reduceToOpen();
                op_len -= 1;
                _ = advance();
                switch (open.kind) {
                    .call => try applyCall(open, open.argc + 1),
                    .bracket => try applyLoad(open),
                    else => {},
                }
            },
            .dot => {
                // Member access binds tighter than any operator on the stack.
                _ = advance();
                const member = try expect(.ident);
                const v = popVal();
                const vt = nodes[v].ty;
                if (!isVec(vt)) return fail(t.start, .type_mismatch);
                const swizzle = try parseSwizzle(member, vt);
                if (swizzle.len == 1) {
                    _ = try pushNode(.{ .kind = .lane, .op = swizzle.lanes[0], .ty = .f32, .opnd_ty = vt, .kids = .{ v, 0, 0, 0 }, .offset = member.start });
                } else {
                    _ = try pushNode(.{ .kind = .swizzle, .op = swizzle.packedLanes(), .ty = vecOf(swizzle.len), .opnd_ty = vt, .kids = .{ v, 0, 0, 0 }, .offset = member.start });
                }
            },
            .l_bracket => return fail(t.start, .unsupported),
            else => break,
        }
    }
    if (expect_operand) return fail(peek().start, .syntax);
    while (op_len > 0) {
        op_len -= 1;
        const top = ops[op_len];
        if (top.kind == .paren or top.kind == .call or top.kind == .bracket) return fail(top.offset, .syntax);
        try applyOp(top);
    }
    if (val_len != 1) return fail(start, .syntax);
    return vals[0];
}

fn setNodeTy(index: u16, ty: Ty) CompileError!void {
    const node = &nodes[index];
    if (node.ty == ty) return;
    if (!isAbstract(node.ty)) return fail(node.offset, .type_mismatch);
    if (node.kind == .lit) {
        try concretizeLiteral(&node.lit, ty, node.offset);
    } else if (!convertible(node.ty, ty)) {
        return fail(node.offset, .type_mismatch);
    }
    node.ty = ty;
}

// Gives every abstract node a concrete type, from the root down. Parents
// follow their children in postfix order, so a reverse walk visits each
// parent before its children.
fn concretize(root: u16, want: ?Ty) CompileError!void {
    try setNodeTy(root, want orelse defaultTy(nodes[root].ty));
    var i: usize = @as(usize, root) + 1;
    while (i > 0) {
        i -= 1;
        const node = &nodes[i];
        switch (node.kind) {
            .unary => {
                node.opnd_ty = node.ty;
                try setNodeTy(node.kids[0], node.ty);
            },
            .binary => if (isVec(node.ty)) {
                for (node.kids[0..2]) |kid| try setNodeTy(kid, if (isVec(nodes[kid].ty)) node.ty else .f32);
            } else {
                const kind: Tk = @enumFromInt(node.op);
                switch (kind) {
                    .shl, .shr => {
                        node.opnd_ty = node.ty;
                        try setNodeTy(node.kids[0], node.ty);
                        try setNodeTy(node.kids[1], .u32);
                    },
                    .lt, .gt, .le, .ge, .eq_eq, .bang_eq => {
                        node.opnd_ty = defaultTy(node.opnd_ty);
                        try setNodeTy(node.kids[0], node.opnd_ty);
                        try setNodeTy(node.kids[1], node.opnd_ty);
                    },
                    .amp_amp, .pipe_pipe => {},
                    else => {
                        node.opnd_ty = node.ty;
                        try setNodeTy(node.kids[0], node.ty);
                        try setNodeTy(node.kids[1], node.ty);
                    },
                }
            },
            .call => {
                const callee: Callee = @enumFromInt(node.op);
                switch (callee) {
                    .abs, .min, .max, .clamp => {
                        node.opnd_ty = node.ty;
                        for (node.kids[0..node.argc]) |kid| try setNodeTy(kid, node.ty);
                    },
                    .select => {
                        node.opnd_ty = node.ty;
                        try setNodeTy(node.kids[0], node.ty);
                        try setNodeTy(node.kids[1], node.ty);
                    },
                    .sqrt, .floor, .ceil, .trunc, .round => try setNodeTy(node.kids[0], node.ty),
                    .dot => {},
                    .mix => {
                        try setNodeTy(node.kids[0], node.ty);
                        try setNodeTy(node.kids[1], node.ty);
                        const t = node.kids[2];
                        try setNodeTy(t, if (isVec(nodes[t].ty)) node.ty else .f32);
                    },
                    .vec2f, .vec3f, .vec4f => for (node.kids[0..node.argc]) |kid| {
                        if (!isVec(nodes[kid].ty)) try setNodeTy(kid, .f32);
                    },
                    .to_f32, .to_i32, .to_u32, .to_bool => {
                        const arg = node.opnd_ty;
                        node.opnd_ty = if (isAbstract(arg) and convertible(arg, node.ty)) node.ty else defaultTy(arg);
                        try setNodeTy(node.kids[0], node.opnd_ty);
                    },
                }
            },
            .load => {
                node.opnd_ty = if (isAbstract(node.opnd_ty)) .u32 else node.opnd_ty;
                try setNodeTy(node.kids[0], node.opnd_ty);
            },
            else => {},
        }
    }
}

fn bufferBase(id: u8) u32 {
    return if (id == 0 or !input_buffer.declared) RUN_INPUT_PTR else RUN_OUTPUT_PTR;
}

fn emitLoad(elem: Ty, base: u32) CompileError!void {
    // Stack: [index]. Out-of-range loads produce zero.
    const t = try allocLocal(.u32);
    try body.localTee(t);
    try body.byte(0x23);
    try body.uleb(GLOBAL_COUNT);
    try body.byte(0x49); // i32.lt_u
    try body.raw(&.{ 0x04, valType(elem) });
    try body.localGet(t);
    try body.i32Const(elemShift(elem));
    try body.byte(0x74); // i32.shl
    switch (elem) {
        .vec4f => try body.simd(SIMD_LOAD),
        .f32 => try body.byte(0x2a),
        else => try body.byte(0x28),
    }
    try body.byte(elemShift(elem)); // natural alignment
    try body.uleb(base);
    try body.byte(0x05);
    try emitLiteral(&body, .{ .ty = elem });
    try body.byte(0x0b);
}

// Stack: [a, b]. Integer `/` and `%` with WGSL's defined results instead of
// Wasm traps. Each guard is a `br_if` that leaves the block with a fallback
// value, the shape wasm-nontrapping-divides proves safe.
fn emitIntDivide(ty: Ty, remainder: bool) CompileError!void {
    const ta = try allocLocal(ty);
    const tb = try allocLocal(ty);
    try body.localSet(tb);
    try body.localSet(ta);
    try body.raw(&.{ 0x02, 0x7f }); // block (result i32)
    // x / 0 is x; x % 0 is 0.
    if (remainder) try body.i32Const(0) else try body.localGet(ta);
    try body.localGet(tb);
    try body.raw(&.{ 0x45, 0x0d, 0x00, 0x1a }); // i32.eqz br_if 0 drop
    if (ty == .i32) {
        // x / -1 is -x, wrapping so that MIN / -1 is MIN; x % -1 is 0.
        try body.i32Const(0);
        if (!remainder) {
            try body.localGet(ta);
            try body.byte(0x6b); // i32.sub
        }
        try body.localGet(tb);
        try body.i32Const(-1);
        try body.raw(&.{ 0x46, 0x0d, 0x00, 0x1a }); // i32.eq br_if 0 drop
    }
    try body.localGet(ta);
    try body.localGet(tb);
    const signed = ty == .i32;
    try body.byte(if (remainder) (if (signed) @as(u8, 0x6f) else 0x70) else (if (signed) @as(u8, 0x6d) else 0x6e));
    try body.byte(0x0b);
}

// Stack: [a, b]. Selects the smaller (or larger) integer.
fn emitIntMinMax(ty: Ty, is_max: bool) CompileError!void {
    const ta = try allocLocal(ty);
    const tb = try allocLocal(ty);
    try body.localSet(tb);
    try body.localTee(ta);
    try body.localGet(tb);
    try body.localGet(ta);
    try body.localGet(tb);
    const signed = ty == .i32;
    try body.byte(if (is_max) (if (signed) @as(u8, 0x4a) else 0x4b) else (if (signed) @as(u8, 0x48) else 0x49));
    try body.byte(0x1b); // select
}

fn emitMinMax(ty: Ty, is_max: bool) CompileError!void {
    if (ty == .f32) return body.byte(if (is_max) 0x97 else 0x96);
    // f32x4.min and max are lane-wise f32.min and max, NaN handling included.
    if (isVec(ty)) return body.simd(if (is_max) SIMD_F32X4_MAX else SIMD_F32X4_MIN);
    try emitIntMinMax(ty, is_max);
}

fn emitFloatOp(ty: Ty, scalar_op: u8, simd_op: u32) CompileError!void {
    if (isVec(ty)) return body.simd(simd_op);
    try body.byte(scalar_op);
}

fn emitCompare(kind: Tk, ty: Ty) CompileError!void {
    const op: u8 = switch (ty) {
        .f32 => switch (kind) {
            .eq_eq => 0x5b,
            .bang_eq => 0x5c,
            .lt => 0x5d,
            .gt => 0x5e,
            .le => 0x5f,
            else => 0x60,
        },
        .i32 => switch (kind) {
            .eq_eq => 0x46,
            .bang_eq => 0x47,
            .lt => 0x48,
            .gt => 0x4a,
            .le => 0x4c,
            else => 0x4e,
        },
        else => switch (kind) {
            .eq_eq => 0x46,
            .bang_eq => 0x47,
            .lt => 0x49,
            .gt => 0x4b,
            .le => 0x4d,
            else => 0x4f,
        },
    };
    try body.byte(op);
}

// Stack: [a, b]. Emits `a op b` for an arithmetic or bitwise operator.
fn emitArith(kind: Tk, ty: Ty) CompileError!void {
    if (ty == .f32) {
        switch (kind) {
            .plus => try body.byte(0x92),
            .minus => try body.byte(0x93),
            .star => try body.byte(0x94),
            .slash => try body.byte(0x95),
            .percent => {
                // WGSL f32 `%` truncates: a - b * trunc(a / b).
                const ta = try allocLocal(.f32);
                const tb = try allocLocal(.f32);
                try body.localSet(tb);
                try body.localTee(ta);
                try body.localGet(ta);
                try body.localGet(tb);
                try body.raw(&.{ 0x95, 0x8f }); // f32.div, f32.trunc
                try body.localGet(tb);
                try body.raw(&.{ 0x94, 0x93 }); // f32.mul, f32.sub
            },
            else => unreachable,
        }
        return;
    }
    switch (kind) {
        .plus => try body.byte(0x6a),
        .minus => try body.byte(0x6b),
        .star => try body.byte(0x6c),
        .slash => try emitIntDivide(ty, false),
        .percent => try emitIntDivide(ty, true),
        .amp => try body.byte(0x71),
        .pipe => try body.byte(0x72),
        .caret => try body.byte(0x73),
        .shl => try body.byte(0x74),
        .shr => try body.byte(if (ty == .i32) 0x75 else 0x76),
        else => unreachable,
    }
}

// Stack: [a, b] where each is a vector or an f32 to splat. Emits `a op b`.
fn emitVecArith(kind: Tk, a_ty: Ty, b_ty: Ty) CompileError!void {
    if (!isVec(b_ty)) try body.simd(SIMD_F32X4_SPLAT);
    if (!isVec(a_ty)) {
        const tb = try allocLocal(.vec4f);
        try body.localSet(tb);
        try body.simd(SIMD_F32X4_SPLAT);
        try body.localGet(tb);
    }
    switch (kind) {
        .plus => try body.simd(SIMD_F32X4_ADD),
        .minus => try body.simd(SIMD_F32X4_SUB),
        .star => try body.simd(SIMD_F32X4_MUL),
        .slash => try body.simd(SIMD_F32X4_DIV),
        .percent => {
            // Lane-wise a - b * trunc(a / b), as for f32.
            const ta = try allocLocal(.vec4f);
            const tb = try allocLocal(.vec4f);
            try body.localSet(tb);
            try body.localTee(ta);
            try body.localGet(ta);
            try body.localGet(tb);
            try body.simd(SIMD_F32X4_DIV);
            try body.simd(SIMD_F32X4_TRUNC);
            try body.localGet(tb);
            try body.simd(SIMD_F32X4_MUL);
            try body.simd(SIMD_F32X4_SUB);
        },
        else => unreachable,
    }
}

// i8x16.shuffle of [a, b] whose result lane i is f32 lane `lanes[i]`, where
// lanes 0-3 come from a and 4-7 from b.
fn emitLaneShuffle(lanes: [4]u8) CompileError!void {
    try body.simd(SIMD_I8X16_SHUFFLE);
    for (lanes) |lane| for (0..4) |b| try body.byte(lane * 4 + @as(u8, @intCast(b)));
}

// Stack: [args...] of a multi-argument vector constructor, each an f32 or a
// vector. Starts from the first argument and places each later one at its
// lane offset.
fn emitVecConstruct(node: Node) CompileError!void {
    var temps: [4]u32 = undefined;
    var i: usize = node.argc;
    while (i > 1) {
        i -= 1;
        temps[i] = try allocLocal(nodes[node.kids[i]].ty);
        try body.localSet(temps[i]);
    }
    const first = nodes[node.kids[0]].ty;
    if (!isVec(first)) try body.simd(SIMD_F32X4_SPLAT);
    var offset: u8 = vecLen(first);
    for (node.kids[1..node.argc], temps[1..node.argc]) |kid, temp| {
        const kt = nodes[kid].ty;
        try body.localGet(temp);
        if (isVec(kt)) {
            var lanes = [4]u8{ 0, 1, 2, 3 };
            for (0..vecLen(kt)) |j| lanes[offset + j] = 4 + @as(u8, @intCast(j));
            try emitLaneShuffle(lanes);
        } else {
            try body.simdLane(SIMD_F32X4_REPLACE_LANE, offset);
        }
        offset += vecLen(kt);
    }
}

// Stack: [v]. Emits the swizzle whose lanes are packed two bits each.
fn emitSwizzle(lane_bits: u8, len: u8) CompileError!void {
    var lanes: [4]u8 = undefined;
    for (&lanes, 0..) |*lane, i| lane.* = if (i < len) (lane_bits >> @intCast(2 * i)) & 3 else 0;
    // The shuffle reads both operands from the same vector.
    const t = try allocLocal(.vec4f);
    try body.localTee(t);
    try body.localGet(t);
    try emitLaneShuffle(lanes);
}

// Stack: [a, b] as vectors of `len` lanes. Sums the lane-wise products in
// lane order.
fn emitDot(len: u8) CompileError!void {
    try body.simd(SIMD_F32X4_MUL);
    const t = try allocLocal(.vec4f);
    try body.localTee(t);
    try body.simdLane(SIMD_F32X4_EXTRACT_LANE, 0);
    for (1..len) |lane| {
        try body.localGet(t);
        try body.simdLane(SIMD_F32X4_EXTRACT_LANE, @intCast(lane));
        try body.byte(0x92); // f32.add
    }
}

// Stack: [a, b, t] where t is `ty` or an f32 to splat. Emits WGSL's
// a * (1 - t) + b * t.
fn emitMix(ty: Ty, t_ty: Ty) CompileError!void {
    if (isVec(ty) and !isVec(t_ty)) try body.simd(SIMD_F32X4_SPLAT);
    const tt = try allocLocal(ty);
    const tb = try allocLocal(ty);
    try body.localSet(tt);
    try body.localSet(tb);
    try body.f32Const(1);
    if (isVec(ty)) try body.simd(SIMD_F32X4_SPLAT);
    try body.localGet(tt);
    try emitFloatOp(ty, 0x93, SIMD_F32X4_SUB);
    try emitFloatOp(ty, 0x94, SIMD_F32X4_MUL);
    try body.localGet(tb);
    try body.localGet(tt);
    try emitFloatOp(ty, 0x94, SIMD_F32X4_MUL);
    try emitFloatOp(ty, 0x92, SIMD_F32X4_ADD);
}

fn emitConvert(from: Ty, to: Ty) CompileError!void {
    if (from == to) return;
    switch (to) {
        .f32 => switch (from) {
            .i32 => try body.byte(0xb2), // f32.convert_i32_s
            else => try body.byte(0xb3), // f32.convert_i32_u, also bool
        },
        .i32, .u32 => if (from == .f32) {
            // Saturating, as WGSL requires.
            try body.raw(&.{ 0xfc, if (to == .i32) 0x00 else 0x01 });
        },
        .bool => if (from == .f32) {
            try body.f32Const(0);
            try body.byte(0x5c); // f32.ne
        } else {
            try body.i32Const(0);
            try body.byte(0x47); // i32.ne
        },
        else => unreachable,
    }
}

fn emitNode(node: Node) CompileError!void {
    switch (node.kind) {
        .lit => try emitLiteral(&body, node.lit),
        .local => try body.localGet(node.ref),
        .override => {
            try body.byte(0x23);
            try body.uleb(GLOBAL_FIRST_OVERRIDE + node.ref);
        },
        .gid_x => try body.localGet(0),
        .array_len => {
            try body.byte(0x23);
            try body.uleb(GLOBAL_COUNT);
        },
        .load => try emitLoad(node.ty, bufferBase(node.op)),
        .lane => try body.simdLane(SIMD_F32X4_EXTRACT_LANE, node.op),
        .swizzle => try emitSwizzle(node.op, vecLen(node.ty)),
        .unary => switch (@as(Tk, @enumFromInt(node.op))) {
            .minus => if (isVec(node.ty)) try body.simd(SIMD_F32X4_NEG) else if (node.ty == .f32) try body.byte(0x8c) else {
                try body.i32Const(-1);
                try body.byte(0x6c);
            },
            .bang => try body.byte(0x45),
            .tilde => {
                try body.i32Const(-1);
                try body.byte(0x73);
            },
            else => unreachable,
        },
        .binary => {
            const kind: Tk = @enumFromInt(node.op);
            if (isVec(node.ty)) return emitVecArith(kind, nodes[node.kids[0]].ty, nodes[node.kids[1]].ty);
            switch (kind) {
                .lt, .gt, .le, .ge, .eq_eq, .bang_eq => try emitCompare(kind, node.opnd_ty),
                .amp_amp => try body.byte(0x71),
                .pipe_pipe => try body.byte(0x72),
                else => try emitArith(kind, node.ty),
            }
        },
        .call => switch (@as(Callee, @enumFromInt(node.op))) {
            .abs => switch (node.ty) {
                .f32 => try body.byte(0x8b),
                .vec2f, .vec3f, .vec4f => try body.simd(SIMD_F32X4_ABS),
                .i32 => {
                    // (x ^ s) - s where s = x >> 31; abs(MIN) stays MIN.
                    const t = try allocLocal(.i32);
                    const s = try allocLocal(.i32);
                    try body.localTee(t);
                    try body.i32Const(31);
                    try body.byte(0x75);
                    try body.localTee(s);
                    try body.localGet(t);
                    try body.byte(0x73);
                    try body.localGet(s);
                    try body.byte(0x6b);
                },
                else => {},
            },
            .min => try emitMinMax(node.ty, false),
            .max => try emitMinMax(node.ty, true),
            .clamp => {
                // min(max(e, low), high)
                const high = try allocLocal(node.ty);
                try body.localSet(high);
                try emitMinMax(node.ty, true);
                try body.localGet(high);
                try emitMinMax(node.ty, false);
            },
            .select => {
                // WGSL select(f, t, cond) is Wasm select(t, f, cond).
                const tc = try allocLocal(.bool);
                const tt = try allocLocal(node.ty);
                const tf = try allocLocal(node.ty);
                try body.localSet(tc);
                try body.localSet(tt);
                try body.localSet(tf);
                try body.localGet(tt);
                try body.localGet(tf);
                try body.localGet(tc);
                try body.byte(0x1b);
            },
            .sqrt => try emitFloatOp(node.ty, 0x91, SIMD_F32X4_SQRT),
            .floor => try emitFloatOp(node.ty, 0x8e, SIMD_F32X4_FLOOR),
            .ceil => try emitFloatOp(node.ty, 0x8d, SIMD_F32X4_CEIL),
            .trunc => try emitFloatOp(node.ty, 0x8f, SIMD_F32X4_TRUNC),
            // nearest: ties to even, as in WGSL
            .round => try emitFloatOp(node.ty, 0x90, SIMD_F32X4_NEAREST),
            .dot => try emitDot(vecLen(node.opnd_ty)),
            .mix => try emitMix(node.ty, nodes[node.kids[2]].ty),
            .to_f32, .to_i32, .to_u32, .to_bool => try emitConvert(node.opnd_ty, node.ty),
            .vec2f, .vec3f, .vec4f => if (node.argc > 1) try emitVecConstruct(node) else if (!isVec(node.opnd_ty)) {
                try body.simd(SIMD_F32X4_SPLAT);
            },
        },
    }
}

fn emitExpr(root: u16, want: ?Ty) CompileError!Ty {
    try concretize(root, want);
    for (nodes[0 .. @as(usize, root) + 1]) |node| try emitNode(node);
    return nodes[root].ty;
}

// Parses, types and emits one expression. Returns its concrete type.
fn compileExpr(want: ?Ty) CompileError!Ty {
    return emitExpr(try parseExpr(), want);
}

// Compiles the right side of vector arithmetic: a vector of type `ty`, or
// an f32 that is splatted to every lane.
fn compileVecOperand(ty: Ty) CompileError!void {
    const root = try parseExpr();
    const want: Ty = if (isVec(nodes[root].ty)) ty else .f32;
    _ = try emitExpr(root, want);
    if (want == .f32) try body.simd(SIMD_F32X4_SPLAT);
}

// ---------------------------------------------------------------------------
// Statements

const BlockKind = enum(u8) { func, plain, if_then, if_else };
const Block = struct { kind: BlockKind, scope_mark: usize, extra_ends: u32 = 0 };

var blocks: [MAX_BLOCKS]Block = undefined;
var block_len: usize = 0;

fn pushBlock(block: Block) CompileError!void {
    if (block_len >= MAX_BLOCKS) return fail(peek().start, .unsupported);
    blocks[block_len] = block;
    block_len += 1;
}

fn declareLocal(name: Token, ty: Ty, mutable: bool) CompileError!u32 {
    const mark = blocks[block_len - 1].scope_mark;
    for (scope[mark..scope_len]) |local| if (sameName(local.name, name)) return fail(name.start, .name);
    if (scope_len >= MAX_SCOPE_NAMES) return fail(name.start, .unsupported);
    const index = try allocLocal(ty);
    scope[scope_len] = .{ .name = name, .index = index, .ty = ty, .mutable = mutable };
    scope_len += 1;
    return index;
}

fn parseDeclaration(mutable: bool) CompileError!void {
    const name = try expect(.ident);
    var declared: ?Ty = null;
    if (peek().kind == .colon) {
        _ = advance();
        declared = try parseType();
    }
    var ty: Ty = undefined;
    if (peek().kind == .eq) {
        _ = advance();
        ty = try compileExpr(declared);
    } else {
        if (!mutable or declared == null) return fail(peek().start, .syntax);
        ty = declared.?;
        try emitLiteral(&body, .{ .ty = ty });
    }
    _ = try expect(.semicolon);
    // Declare after the initializer so that `let x = x + 1;` sees the outer x.
    const index = try declareLocal(name, ty, mutable);
    try body.localSet(index);
}

fn compoundOp(kind: Tk) ?Tk {
    return switch (kind) {
        .plus_eq, .plus_plus => .plus,
        .minus_eq, .minus_minus => .minus,
        .star_eq => .star,
        .slash_eq => .slash,
        .percent_eq => .percent,
        .amp_eq => .amp,
        .pipe_eq => .pipe,
        .caret_eq => .caret,
        .shl_eq => .shl,
        .shr_eq => .shr,
        else => null,
    };
}

// `v.x = e;` and `v.x op= e;` replace one lane of a vector var.
fn parseLaneAssignment(local: Local) CompileError!void {
    _ = advance();
    const member = try expect(.ident);
    const swizzle = try parseSwizzle(member, local.ty);
    if (swizzle.len != 1) return fail(member.start, .unsupported); // swizzle assignment
    const lane = swizzle.lanes[0];
    try body.localGet(local.index);
    const op_tok = advance();
    if (op_tok.kind == .eq) {
        _ = try compileExpr(.f32);
    } else {
        const op = compoundOp(op_tok.kind) orelse return fail(op_tok.start, .syntax);
        const arith = switch (op_tok.kind) {
            .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => true,
            else => false,
        };
        if (!arith) return fail(op_tok.start, .type_mismatch);
        try body.localGet(local.index);
        try body.simdLane(SIMD_F32X4_EXTRACT_LANE, lane);
        _ = try compileExpr(.f32);
        try emitArith(op, .f32);
    }
    _ = try expect(.semicolon);
    try body.simdLane(SIMD_F32X4_REPLACE_LANE, lane);
    try body.localSet(local.index);
}

fn parseLocalAssignment(local: Local) CompileError!void {
    const name = advance();
    if (!local.mutable) return fail(name.start, .type_mismatch);
    if (peek().kind == .dot) {
        if (!isVec(local.ty)) return fail(peek().start, .type_mismatch);
        return parseLaneAssignment(local);
    }
    const op_tok = advance();
    if (op_tok.kind == .eq) {
        _ = try compileExpr(local.ty);
    } else if (isVec(local.ty)) {
        const arith = switch (op_tok.kind) {
            .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => true,
            else => false,
        };
        if (!arith) return fail(op_tok.start, if (compoundOp(op_tok.kind) != null) .type_mismatch else .syntax);
        try body.localGet(local.index);
        try compileVecOperand(local.ty);
        try emitVecArith(compoundOp(op_tok.kind).?, local.ty, local.ty);
    } else {
        const op = compoundOp(op_tok.kind) orelse return fail(op_tok.start, .syntax);
        try body.localGet(local.index);
        if (op_tok.kind == .plus_plus or op_tok.kind == .minus_minus) {
            if (!isInt(local.ty)) return fail(op_tok.start, .type_mismatch);
            try body.i32Const(1);
        } else {
            const rhs_want: Ty = if (op == .shl or op == .shr) .u32 else local.ty;
            _ = try compileExpr(rhs_want);
        }
        const ok = switch (op) {
            .amp, .pipe, .caret => isInt(local.ty) or (local.ty == .bool and op != .caret),
            .shl, .shr => isInt(local.ty),
            else => isNumeric(local.ty),
        };
        if (!ok) return fail(op_tok.start, .type_mismatch);
        try emitArith(op, local.ty);
    }
    _ = try expect(.semicolon);
    try body.localSet(local.index);
}

fn parseStore(id: u8) CompileError!void {
    const name = advance();
    if (id != 1) return fail(name.start, .type_mismatch); // read-only buffer
    _ = try expect(.l_bracket);
    const index_ty = try compileExpr(null);
    if (!(index_ty == .i32 or index_ty == .u32)) return fail(name.start, .type_mismatch);
    const t_index = try allocLocal(.u32);
    try body.localSet(t_index);
    _ = try expect(.r_bracket);
    const eq = advance();
    const unsupported = compoundOp(eq.kind) != null or eq.kind == .dot; // `dst[i] += e`, `dst[i].x = e`
    if (eq.kind != .eq) return fail(eq.start, if (unsupported) .unsupported else .syntax);
    const elem = output_buffer.elem;
    _ = try compileExpr(elem);
    _ = try expect(.semicolon);
    const t_value = try allocLocal(elem);
    try body.localSet(t_value);
    // Out-of-range stores are dropped.
    try body.localGet(t_index);
    try body.byte(0x23);
    try body.uleb(GLOBAL_COUNT);
    try body.byte(0x49); // i32.lt_u
    try body.raw(&.{ 0x04, 0x40 });
    try body.localGet(t_index);
    try body.i32Const(elemShift(elem));
    try body.byte(0x74);
    try body.localGet(t_value);
    switch (elem) {
        .vec4f => try body.simd(SIMD_STORE),
        .f32 => try body.byte(0x38),
        else => try body.byte(0x36),
    }
    try body.byte(elemShift(elem)); // natural alignment
    try body.uleb(bufferBase(1));
    try body.byte(0x0b);
}

fn emitEnds(count: u32) CompileError!void {
    var i: u32 = 0;
    while (i < count) : (i += 1) try body.byte(0x0b);
}

fn parseIfHead(extra_ends: u32) CompileError!void {
    _ = try compileExpr(.bool);
    _ = try expect(.l_brace);
    try body.raw(&.{ 0x04, 0x40 });
    try pushBlock(.{ .kind = .if_then, .scope_mark = scope_len, .extra_ends = extra_ends });
}

fn closeBlock() CompileError!void {
    _ = advance();
    block_len -= 1;
    const block = blocks[block_len];
    scope_len = block.scope_mark;
    switch (block.kind) {
        .func, .plain => {},
        .if_then => {
            if (isWord(peek(), "else")) {
                _ = advance();
                try body.byte(0x05);
                if (isWord(peek(), "if")) {
                    // `else if` nests a new if inside the else arm.
                    _ = advance();
                    try parseIfHead(block.extra_ends + 1);
                } else {
                    _ = try expect(.l_brace);
                    try pushBlock(.{ .kind = .if_else, .scope_mark = scope_len, .extra_ends = block.extra_ends });
                }
            } else {
                try emitEnds(1 + block.extra_ends);
            }
        },
        .if_else => try emitEnds(1 + block.extra_ends),
    }
}

fn parseStatement() CompileError!void {
    const t = peek();
    if (block_len == 1 and t.kind != .r_brace) kernel_returned = false;
    switch (t.kind) {
        .r_brace => return closeBlock(),
        .l_brace => {
            _ = advance();
            return pushBlock(.{ .kind = .plain, .scope_mark = scope_len });
        },
        .semicolon => {
            _ = advance();
            return;
        },
        .ident => {},
        else => return fail(t.start, .syntax),
    }
    const word = text(t);
    if (std.mem.eql(u8, word, "let") or std.mem.eql(u8, word, "const")) {
        _ = advance();
        return parseDeclaration(false);
    }
    if (std.mem.eql(u8, word, "var")) {
        _ = advance();
        if (peek().kind == .lt) return fail(peek().start, .unsupported);
        return parseDeclaration(true);
    }
    if (std.mem.eql(u8, word, "if")) {
        _ = advance();
        return parseIfHead(0);
    }
    if (std.mem.eql(u8, word, "return")) {
        _ = advance();
        if (in_kernel) {
            _ = try compileExpr(.vec4f);
            if (block_len == 1) kernel_returned = true;
        } else if (peek().kind != .semicolon) {
            return fail(peek().start, .unsupported);
        }
        _ = try expect(.semicolon);
        return body.byte(0x0f);
    }
    if (std.mem.eql(u8, word, "_")) {
        _ = advance();
        _ = try expect(.eq);
        _ = try compileExpr(null);
        _ = try expect(.semicolon);
        return body.byte(0x1a); // drop
    }
    const unsupported_words = [_][]const u8{ "for", "while", "loop", "switch", "break", "continue", "discard", "const_assert" };
    for (unsupported_words) |w| if (std.mem.eql(u8, word, w)) return fail(t.start, .unsupported);
    if (lookupLocal(t)) |local| return parseLocalAssignment(local);
    if (bufferId(t)) |id| return parseStore(id);
    if (moduleNameTaken(t)) return fail(t.start, .type_mismatch);
    if (peekAt(1).kind == .l_paren) return fail(t.start, .unsupported); // function call statement
    return fail(t.start, .name);
}

// ---------------------------------------------------------------------------
// Module scope

const Attributes = struct { compute: bool = false, builtin_gid: bool = false, other_builtin: ?u32 = null };

fn parseAttributes() CompileError!Attributes {
    var attrs = Attributes{};
    while (peek().kind == .at) {
        _ = advance();
        const name = try expect(.ident);
        if (isWord(name, "compute")) attrs.compute = true;
        if (isWord(name, "vertex") or isWord(name, "fragment")) return fail(name.start, .unsupported);
        if (peek().kind != .l_paren) continue;
        if (isWord(name, "builtin")) {
            _ = advance();
            const arg = try expect(.ident);
            if (isWord(arg, "global_invocation_id")) attrs.builtin_gid = true else attrs.other_builtin = arg.start;
            _ = try expect(.r_paren);
            continue;
        }
        // Skip arguments such as @workgroup_size(64) and @binding(0).
        _ = advance();
        var depth: u32 = 1;
        while (depth > 0) {
            const t = advance();
            switch (t.kind) {
                .l_paren => depth += 1,
                .r_paren => depth -= 1,
                .eof => return fail(t.start, .syntax),
                else => {},
            }
        }
    }
    return attrs;
}

fn isUniformKey(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (name[0] < 'a' or name[0] > 'z' or name[name.len - 1] == '_') return false;
    for (name, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or isDigit(c) or c == '_';
        if (!ok) return false;
        if (c == '_' and i > 0 and name[i - 1] == '_') return false;
    }
    return true;
}

fn parseOverride() CompileError!void {
    const name = try expect(.ident);
    if (moduleNameTaken(name)) return fail(name.start, .name);
    // QIP uniform keys are lowercase snake identifiers.
    if (!isUniformKey(text(name))) return fail(name.start, .unsupported);
    if (override_count >= MAX_OVERRIDES) return fail(name.start, .unsupported);
    var declared: ?Ty = null;
    if (peek().kind == .colon) {
        _ = advance();
        declared = try parseScalarType();
    }
    // QIP uniforms need an authored default.
    if (peek().kind != .eq) return fail(peek().start, .unsupported);
    _ = advance();
    const value_at = peek().start;
    var value = try parseConstLiteral();
    try concretizeLiteral(&value, declared orelse defaultTy(value.ty), value_at);
    _ = try expect(.semicolon);
    overrides[override_count] = .{ .name = name, .ty = value.ty, .value = value };
    override_count += 1;
}

fn parseModuleConst() CompileError!void {
    const name = try expect(.ident);
    if (moduleNameTaken(name)) return fail(name.start, .name);
    if (const_count >= MAX_CONSTS) return fail(name.start, .unsupported);
    var declared: ?Ty = null;
    if (peek().kind == .colon) {
        _ = advance();
        declared = try parseScalarType();
    }
    _ = try expect(.eq);
    const value_at = peek().start;
    var value = try parseConstLiteral();
    if (declared) |ty| try concretizeLiteral(&value, ty, value_at);
    _ = try expect(.semicolon);
    consts[const_count] = .{ .name = name, .value = value };
    const_count += 1;
}

fn parseBufferVar() CompileError!void {
    const open = peek();
    if (open.kind != .lt) return fail(open.start, .unsupported); // var<private> by default
    _ = advance();
    const space = try expect(.ident);
    if (!isWord(space, "storage")) return fail(space.start, .unsupported);
    var read_write = false;
    if (peek().kind == .comma) {
        _ = advance();
        const access = try expect(.ident);
        if (isWord(access, "read_write")) {
            read_write = true;
        } else if (!isWord(access, "read")) {
            return fail(access.start, .unsupported);
        }
    }
    _ = try expect(.gt);
    const name = try expect(.ident);
    if (moduleNameTaken(name)) return fail(name.start, .name);
    if (kernel_count > 0) return fail(name.start, .unsupported); // pixel kernels own the tile
    _ = try expect(.colon);
    const array_tok = try expect(.ident);
    if (!isWord(array_tok, "array")) return fail(array_tok.start, .unsupported);
    _ = try expect(.lt);
    const elem_at = peek().start;
    const elem = try parseType();
    if (elem == .bool) return fail(elem_at, .type_mismatch);
    if (elem == .vec2f or elem == .vec3f) return fail(elem_at, .unsupported);
    if (peek().kind == .comma) return fail(peek().start, .unsupported); // fixed-size array
    _ = try expect(.gt);
    _ = try expect(.semicolon);
    const slot = if (read_write) &output_buffer else &input_buffer;
    if (slot.declared) return fail(name.start, .unsupported);
    // Both buffers share one element count, so they share an element size.
    const other = if (read_write) input_buffer else output_buffer;
    if (other.declared and elemShift(other.elem) != elemShift(elem)) return fail(elem_at, .unsupported);
    slot.* = .{ .name = name, .elem = elem, .declared = true };
}

fn parseEntry(fn_tok: Token) CompileError!void {
    if (have_entry or kernel_count > 0) return fail(fn_tok.start, .unsupported);
    have_entry = true;
    _ = try expect(.ident);
    _ = try expect(.l_paren);
    if (peek().kind != .r_paren) {
        const param_attrs = try parseAttributes();
        if (param_attrs.other_builtin) |at| return fail(at, .unsupported);
        const param = try expect(.ident);
        if (!param_attrs.builtin_gid) return fail(param.start, .unsupported);
        _ = try expect(.colon);
        const ty_tok = try expect(.ident);
        if (isWord(ty_tok, "vec3")) {
            _ = try expect(.lt);
            _ = try expectWord("u32");
            _ = try expect(.gt);
        } else if (!isWord(ty_tok, "vec3u")) {
            return fail(ty_tok.start, .type_mismatch);
        }
        if (peek().kind == .comma) {
            _ = advance();
            if (peek().kind != .r_paren) return fail(peek().start, .unsupported);
        }
        gid_name = param;
    }
    _ = try expect(.r_paren);
    if (peek().kind == .arrow) return fail(peek().start, .unsupported);
    _ = try expect(.l_brace);
    block_len = 0;
    scope_len = 0;
    try pushBlock(.{ .kind = .func, .scope_mark = 0 });
    while (block_len > 0) {
        if (peek().kind == .eof) return fail(peek().start, .syntax);
        try parseStatement();
    }
    gid_name = null;
}

// `fn name(c: vec4f) -> vec4f { ... return expr; }` maps one pixel.
fn parseKernel(fn_tok: Token) CompileError!void {
    if (have_entry or input_buffer.declared or output_buffer.declared) return fail(fn_tok.start, .unsupported);
    if (kernel_count >= MAX_KERNELS) return fail(fn_tok.start, .unsupported);
    _ = try expect(.ident);
    _ = try expect(.l_paren);
    const param = try expect(.ident);
    if (moduleNameTaken(param)) return fail(param.start, .name);
    _ = try expect(.colon);
    const param_at = peek().start;
    if (try parseType() != .vec4f) return fail(param_at, .type_mismatch);
    if (peek().kind == .comma) {
        _ = advance();
        if (peek().kind != .r_paren) return fail(peek().start, .unsupported); // a second parameter
    }
    _ = try expect(.r_paren);
    _ = try expect(.arrow);
    const result_at = peek().start;
    if (try parseType() != .vec4f) return fail(result_at, .type_mismatch);
    _ = try expect(.l_brace);
    block_len = 0;
    try pushBlock(.{ .kind = .func, .scope_mark = 0 });
    // The parameter is Wasm local 0, and WGSL parameters are immutable.
    scope[0] = .{ .name = param, .index = 0, .ty = .vec4f, .mutable = false };
    scope_len = 1;
    local_count = 0;
    body.len = 0;
    in_kernel = true;
    kernel_returned = false;
    while (block_len > 0) {
        if (peek().kind == .eof) return fail(peek().start, .syntax);
        try parseStatement();
    }
    in_kernel = false;
    // Every path must return; requiring a final `return` proves that simply.
    if (!kernel_returned) return fail(tokens[pos - 1].start, .unsupported);
    try emitFunction(&kernel_code);
    kernel_count += 1;
}

fn parseTopLevel() CompileError!void {
    const attrs = try parseAttributes();
    const t = advance();
    if (t.kind == .semicolon) return;
    if (t.kind != .ident) return fail(t.start, .syntax);
    const word = text(t);
    if (std.mem.eql(u8, word, "override")) return parseOverride();
    if (std.mem.eql(u8, word, "const")) return parseModuleConst();
    if (std.mem.eql(u8, word, "var")) return parseBufferVar();
    if (std.mem.eql(u8, word, "fn")) return if (attrs.compute) parseEntry(t) else parseKernel(t);
    const unsupported_words = [_][]const u8{ "struct", "alias", "enable", "requires", "diagnostic", "const_assert" };
    for (unsupported_words) |w| if (std.mem.eql(u8, word, w)) return fail(t.start, .unsupported);
    return fail(t.start, .syntax);
}

// ---------------------------------------------------------------------------
// Module assembly

fn setterType(ty: Ty) u8 {
    return switch (ty) {
        .f32 => 3,
        .i32 => 5,
        else => 4,
    };
}

fn emitResetOverrides(w: *Buf) CompileError!void {
    for (overrides[0..override_count], 0..) |o, i| {
        try emitLiteral(w, o.value);
        try w.byte(0x24);
        try w.uleb(GLOBAL_FIRST_OVERRIDE + i);
    }
}

fn emitGetter(w: *Buf, value: u32) CompileError!void {
    const at = try w.beginSize();
    try w.byte(0); // no locals
    try w.i32Const(@bitCast(value));
    try w.byte(0x0b);
    w.endSize(at);
}

fn emitRender(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    try w.raw(&.{ 2, 1, 0x7f, 1, 0x7e }); // (local $i i32) (local $result i64)
    // A host that exceeds the input capacity violates the contract.
    try w.localGet(0);
    try w.i32Const(@bitCast(RUN_BYTES_CAP));
    try w.raw(&.{ 0x4b, 0x04, 0x40, 0x00, 0x0b }); // i32.gt_u if unreachable end
    const shift = elemShift(output_buffer.elem);
    const elem_size = @as(i32, 1) << shift;
    try w.localGet(0);
    try w.i32Const(elem_size - 1);
    try w.raw(&.{ 0x71, 0x04, 0x40 }); // i32.and if
    // Partial element: reject at the offset where it starts.
    try w.localGet(0);
    try w.i32Const(-elem_size);
    try w.raw(&.{ 0x71, 0xad }); // i32.and i64.extend_i32_u
    try w.byte(0x42);
    try w.sleb(std.math.minInt(i64));
    try w.byte(0x84); // i64.or
    try w.localSet(2);
    try w.byte(0x05);
    try w.localGet(0);
    try w.i32Const(shift);
    try w.byte(0x76); // i32.shr_u
    try w.byte(0x24);
    try w.uleb(GLOBAL_COUNT);
    if (input_buffer.declared) {
        try w.i32Const(@bitCast(RUN_OUTPUT_PTR));
        try w.i32Const(0);
        try w.localGet(0);
        try w.raw(&.{ 0xfc, 0x0b, 0x00 }); // memory.fill
    }
    // for (i = 0; i < count; i += 1) main(i)
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(1);
    try w.byte(0x23);
    try w.uleb(GLOBAL_COUNT);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
    try w.localGet(1);
    try w.byte(0x10);
    try w.uleb(FN_MAIN);
    try w.localGet(1);
    try w.i32Const(1);
    try w.byte(0x6a);
    try w.localSet(1);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    try w.localGet(0);
    try w.byte(0xad); // i64.extend_i32_u
    try w.byte(0x42);
    try w.sleb(@as(i64, bufferBase(1)) << 32);
    try w.byte(0x84);
    try w.localSet(2);
    try w.byte(0x0b);
    // Each render starts from the authored uniform defaults.
    try emitResetOverrides(w);
    try w.localGet(2);
    try w.byte(0x0b);
    w.endSize(at);
}

// Writes the function in `body` with its locals as one code entry.
fn emitFunction(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    var runs: u32 = 0;
    var i: usize = 0;
    while (i < local_count) : (i += 1) {
        if (i == 0 or local_types[i] != local_types[i - 1]) runs += 1;
    }
    try w.uleb(runs);
    var run_start: usize = 0;
    i = 1;
    while (i <= local_count) : (i += 1) {
        if (i == local_count or local_types[i] != local_types[run_start]) {
            try w.uleb(i - run_start);
            try w.byte(local_types[run_start]);
            run_start = i;
        }
    }
    try w.raw(body_buf[0..body.len]);
    try w.byte(0x0b);
    w.endSize(at);
}

fn emitSetter(w: *Buf, global: u32, ty: Ty) CompileError!void {
    const at = try w.beginSize();
    try w.byte(0);
    switch (ty) {
        .i32 => {
            // The i64 setter saturates to the i32 range and returns the result.
            const bounds = [_]struct { i64, u8 }{ .{ std.math.minInt(i32), 0x53 }, .{ std.math.maxInt(i32), 0x55 } };
            for (bounds) |bound| {
                try w.localGet(0);
                try w.byte(0x42);
                try w.sleb(bound[0]);
                try w.raw(&.{ bound[1], 0x04, 0x40, 0x42 }); // i64.lt_s/gt_s if i64.const
                try w.sleb(bound[0]);
                try w.localSet(0);
                try w.byte(0x0b);
            }
            try w.localGet(0);
            try w.byte(0xa7); // i32.wrap_i64
        },
        .bool => {
            try w.localGet(0);
            try w.i32Const(0);
            try w.byte(0x47);
        },
        else => try w.localGet(0),
    }
    try w.byte(0x24);
    try w.uleb(global);
    if (ty == .i32) try w.localGet(0) else {
        try w.byte(0x23);
        try w.uleb(global);
    }
    try w.byte(0x0b);
    w.endSize(at);
}

fn emitModule() CompileError!usize {
    var w = Buf{ .bytes = &output_buf };
    try w.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    try w.byte(1); // type section
    var at = try w.beginSize();
    try w.uleb(6);
    try w.raw(&.{ 0x60, 0, 1, 0x7f }); // 0: () -> i32
    try w.raw(&.{ 0x60, 1, 0x7f, 1, 0x7e }); // 1: (i32) -> i64
    try w.raw(&.{ 0x60, 1, 0x7f, 0 }); // 2: (i32) -> ()
    try w.raw(&.{ 0x60, 1, 0x7d, 1, 0x7d }); // 3: (f32) -> f32
    try w.raw(&.{ 0x60, 1, 0x7f, 1, 0x7f }); // 4: (i32) -> i32
    try w.raw(&.{ 0x60, 1, 0x7e, 1, 0x7e }); // 5: (i64) -> i64
    w.endSize(at);

    try w.byte(3); // function section
    at = try w.beginSize();
    try w.uleb(FN_FIRST_SETTER + override_count);
    try w.raw(&.{ 0, 0, 0, 0, 1, 2 });
    for (overrides[0..override_count]) |o| try w.byte(setterType(o.ty));
    w.endSize(at);

    try w.byte(5); // memory section: fixed size
    at = try w.beginSize();
    try w.raw(&.{ 1, 1 });
    try w.uleb(RUN_PAGES);
    try w.uleb(RUN_PAGES);
    w.endSize(at);

    try w.byte(6); // global section
    at = try w.beginSize();
    try w.uleb(1 + override_count);
    try w.raw(&.{ 0x7f, 1, 0x41, 0, 0x0b }); // element count
    for (overrides[0..override_count]) |o| {
        try w.raw(&.{ valType(o.ty), 1 });
        try emitLiteral(&w, o.value);
        try w.byte(0x0b);
    }
    w.endSize(at);

    try w.byte(7); // export section
    at = try w.beginSize();
    try w.uleb(6 + override_count);
    try w.name("memory");
    try w.raw(&.{ 2, 0 });
    const getters = [_][]const u8{ "input_ptr", "input_bytes_cap", "output_bytes_cap", "failure_modes_per_input_offset", "render" };
    for (getters, 0..) |getter, i| {
        try w.name(getter);
        try w.byte(0);
        try w.uleb(i);
    }
    for (overrides[0..override_count], 0..) |o, i| {
        const prefix = "uniform_set_";
        try w.uleb(prefix.len + o.name.len);
        try w.raw(prefix);
        try w.raw(text(o.name));
        try w.byte(0);
        try w.uleb(FN_FIRST_SETTER + i);
    }
    w.endSize(at);

    try w.byte(10); // code section
    at = try w.beginSize();
    try w.uleb(FN_FIRST_SETTER + override_count);
    try emitGetter(&w, RUN_INPUT_PTR);
    try emitGetter(&w, RUN_BYTES_CAP);
    try emitGetter(&w, RUN_BYTES_CAP);
    try emitGetter(&w, 1);
    try emitRender(&w);
    try emitFunction(&w);
    for (overrides[0..override_count], 0..) |o, i| try emitSetter(&w, @intCast(GLOBAL_FIRST_OVERRIDE + i), o.ty);
    w.endSize(at);

    return w.len;
}

fn emitTile(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    try w.raw(&.{ 1, 1, 0x7f }); // (local $p i32) after the x and y parameters
    // for (p = 0; p < TILE_BYTES; p += 16) store(p, kernelN(...kernel0(load(p))))
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(2);
    try w.i32Const(@bitCast(TILE_BYTES));
    try w.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
    try w.localGet(2);
    try w.localGet(2);
    try w.simd(SIMD_LOAD);
    try w.byte(4);
    try w.uleb(TILE_INPUT_PTR);
    for (0..kernel_count) |k| {
        try w.byte(0x10);
        try w.uleb(FN_FIRST_KERNEL + k);
    }
    try w.simd(SIMD_STORE);
    try w.byte(4);
    try w.uleb(TILE_INPUT_PTR);
    try w.localGet(2);
    try w.i32Const(16);
    try w.byte(0x6a);
    try w.localSet(2);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    try w.byte(0x0b);
    w.endSize(at);
}

// A Tile component that runs the pixel kernels in source order.
fn emitTileModule() CompileError!usize {
    var w = Buf{ .bytes = &output_buf };
    try w.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // Setter types keep their indices from emitModule (see setterType).
    try w.byte(1); // type section
    var at = try w.beginSize();
    try w.uleb(6);
    try w.raw(&.{ 0x60, 0, 1, 0x7f }); // 0: () -> i32
    try w.raw(&.{ 0x60, 2, 0x7d, 0x7d, 0 }); // 1: (f32, f32) -> ()
    try w.raw(&.{ 0x60, 1, 0x7b, 1, 0x7b }); // 2: (v128) -> v128
    try w.raw(&.{ 0x60, 1, 0x7d, 1, 0x7d }); // 3: (f32) -> f32
    try w.raw(&.{ 0x60, 1, 0x7f, 1, 0x7f }); // 4: (i32) -> i32
    try w.raw(&.{ 0x60, 1, 0x7e, 1, 0x7e }); // 5: (i64) -> i64
    w.endSize(at);

    try w.byte(3); // function section
    at = try w.beginSize();
    try w.uleb(FN_FIRST_KERNEL + kernel_count + override_count);
    try w.raw(&.{ 0, 0, 1 });
    for (0..kernel_count) |_| try w.byte(2);
    for (overrides[0..override_count]) |o| try w.byte(setterType(o.ty));
    w.endSize(at);

    try w.byte(5); // memory section: one fixed page
    at = try w.beginSize();
    try w.raw(&.{ 1, 1, 1, 1 });
    w.endSize(at);

    try w.byte(6); // global section
    at = try w.beginSize();
    try w.uleb(1 + override_count);
    // Unused here; it keeps override globals at GLOBAL_FIRST_OVERRIDE.
    try w.raw(&.{ 0x7f, 0, 0x41, 0, 0x0b });
    for (overrides[0..override_count]) |o| {
        try w.raw(&.{ valType(o.ty), 1 });
        try emitLiteral(&w, o.value);
        try w.byte(0x0b);
    }
    w.endSize(at);

    try w.byte(7); // export section
    at = try w.beginSize();
    try w.uleb(4 + override_count);
    try w.name("memory");
    try w.raw(&.{ 2, 0 });
    const funcs = [_][]const u8{ "input_ptr", "input_bytes_cap", "tile_rgba32float_64x64" };
    for (funcs, 0..) |func, i| {
        try w.name(func);
        try w.byte(0);
        try w.uleb(i);
    }
    for (overrides[0..override_count], 0..) |o, i| {
        const prefix = "uniform_set_";
        try w.uleb(prefix.len + o.name.len);
        try w.raw(prefix);
        try w.raw(text(o.name));
        try w.byte(0);
        try w.uleb(FN_FIRST_KERNEL + kernel_count + i);
    }
    w.endSize(at);

    try w.byte(10); // code section
    at = try w.beginSize();
    try w.uleb(FN_FIRST_KERNEL + kernel_count + override_count);
    try emitGetter(&w, TILE_INPUT_PTR);
    try emitGetter(&w, TILE_BYTES);
    try emitTile(&w);
    try w.raw(kernel_code_buf[0..kernel_code.len]);
    for (overrides[0..override_count], 0..) |o, i| try emitSetter(&w, @intCast(GLOBAL_FIRST_OVERRIDE + i), o.ty);
    w.endSize(at);

    return w.len;
}

fn compile(source: []const u8) CompileError!usize {
    src = source;
    pos = 0;
    override_count = 0;
    const_count = 0;
    input_buffer = .{ .name = undefined, .elem = .void };
    output_buffer = .{ .name = undefined, .elem = .void };
    gid_name = null;
    have_entry = false;
    local_count = 0;
    scope_len = 0;
    block_len = 0;
    body.len = 0;
    kernel_count = 0;
    kernel_code.len = 0;
    in_kernel = false;
    try lex();
    while (peek().kind != .eof) try parseTopLevel();
    if (kernel_count > 0) return emitTileModule();
    if (!have_entry or !output_buffer.declared) return fail(@intCast(source.len), .unsupported);
    return emitModule();
}

// ---------------------------------------------------------------------------
// QIP exports

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
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

const scale_shader =
    \\override gain: f32 = 2.0;
    \\@group(0) @binding(0) var<storage, read> src: array<f32>;
    \\@group(0) @binding(1) var<storage, read_write> dst: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    \\  dst[id.x] = src[id.x] * gain;
    \\}
;

fn expectRejected(source: []const u8, offset: usize, mode: Failure) !void {
    try testing.expectError(error.Rejected, compile(source));
    try testing.expectEqual(mode, fail_mode);
    try testing.expectEqual(@as(u32, @intCast(offset)), fail_offset);
}

test "compiles a scaling shader to a Wasm module with a gain uniform" {
    const size = try compile(scale_shader);
    const module = output_buf[0..size];
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }, module[0..8]);
    try testing.expect(std.mem.indexOf(u8, module, "uniform_set_gain") != null);
    try testing.expect(std.mem.indexOf(u8, module, "failure_modes_per_input_offset") != null);
}

test "rejects unsupported features at their offset" {
    const loop_shader =
        \\@group(0) @binding(0) var<storage, read_write> v: array<u32>;
        \\@compute @workgroup_size(1) fn main() { for (var i = 0u; i < 4u; i++) {} }
    ;
    try expectRejected(loop_shader, std.mem.indexOf(u8, loop_shader, "for").?, .unsupported);
    const sample = "@fragment fn main() {}";
    try expectRejected(sample, 1, .unsupported);
    try expectRejected("override Gain: f32 = 1.0;", 9, .unsupported);
}

test "rejects type and name errors" {
    const mixed =
        \\@group(0) @binding(0) var<storage, read_write> v: array<f32>;
        \\@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) { v[id.x] = 1u; }
    ;
    try expectRejected(mixed, std.mem.indexOf(u8, mixed, "1u").?, .type_mismatch);
    const unknown =
        \\@group(0) @binding(0) var<storage, read_write> v: array<f32>;
        \\@compute @workgroup_size(1) fn main() { let a = b; }
    ;
    try expectRejected(unknown, std.mem.indexOf(u8, unknown, "b;").?, .name);
    const literal_range =
        \\@group(0) @binding(0) var<storage, read_write> v: array<i32>;
        \\@compute @workgroup_size(1) fn main() { let a: i32 = -2147483648; let b: i32 = 2147483648; }
    ;
    try expectRejected(literal_range, std.mem.lastIndexOf(u8, literal_range, "2147483648;").?, .type_mismatch);
}

test "requires an entry point and an output buffer" {
    try expectRejected("override a = 1;", 15, .unsupported);
    try expectRejected("@compute @workgroup_size(1) fn main() {}", 40, .unsupported);
}

test "compiles vec4f buffers, constructors, lanes and arithmetic" {
    const shader =
        \\@group(0) @binding(0) var<storage, read> src: array<vec4<f32>>;
        \\@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;
        \\@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {
        \\  var c = src[id.x] * 2.0 + vec4<f32>(1.0, 0.0, 0.0, 0.0);
        \\  c.a = src[id.x].a;
        \\  dst[id.x] = clamp(c, vec4f(0.0), vec4f(1));
        \\}
    ;
    const size = try compile(shader);
    const module = output_buf[0..size];
    // f32x4.mul and v128.store appear in the body.
    try testing.expect(std.mem.indexOf(u8, module, &.{ 0xfd, 0xe6, 0x01 }) != null);
    try testing.expect(std.mem.indexOf(u8, module, &.{ 0xfd, 0x0b, 0x04 }) != null);
}

test "compiles swizzles, vec2f and vec3f, dot and mix" {
    const shader =
        \\@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;
        \\@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) {
        \\  let c = v[id.x];
        \\  var rgb: vec3<f32> = c.bgr * 0.5;
        \\  rgb.g += dot(c.xy, vec2f(1, 2));
        \\  let w = mix(rgb, vec3f(c.a), 0.25);
        \\  v[id.x] = vec4f(mix(c.x, 1.0, c.y), w.zx, vec2<f32>(3.0).y);
        \\}
    ;
    const size = try compile(shader);
    const module = output_buf[0..size];
    // i8x16.shuffle for c.bgr: lanes 2, 1, 0 then lane 0 as filler.
    try testing.expect(std.mem.indexOf(u8, module, &.{ 0xfd, 0x0d, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3, 0, 1, 2, 3 }) != null);
}

test "rejects vec4f features outside the subset" {
    const head =
        \\@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;
        \\@compute @workgroup_size(1) fn main() {
    ;
    const swizzle_assign = head ++ " var a = v[0]; a.xy = vec2f(); }";
    try expectRejected(swizzle_assign, std.mem.indexOf(u8, swizzle_assign, "xy =").?, .unsupported);
    const mixed_sets = head ++ " let a = v[0].xg; }";
    try expectRejected(mixed_sets, std.mem.indexOf(u8, mixed_sets, "xg").?, .name);
    const out_of_range = head ++ " let a = v[0].xy.z; }";
    try expectRejected(out_of_range, std.mem.indexOf(u8, out_of_range, "z;").?, .name);
    const lane_count = head ++ " let a = vec4f(v[0].rgb); }";
    try expectRejected(lane_count, std.mem.indexOf(u8, lane_count, "vec4f(v").?, .type_mismatch);
    const dot_sizes = head ++ " let a = dot(v[0], v[0].xyz); }";
    try expectRejected(dot_sizes, std.mem.indexOf(u8, dot_sizes, "dot").?, .type_mismatch);
    const narrow_store = head ++ " v[0] = v[0].rgb; }";
    try expectRejected(narrow_store, std.mem.indexOf(u8, narrow_store, "rgb;").?, .type_mismatch);
    const vec3_buffer = "@group(0) @binding(0) var<storage, read_write> v: array<vec3f>;";
    try expectRejected(vec3_buffer, std.mem.indexOf(u8, vec3_buffer, "vec3f").?, .unsupported);
    const compare = head ++ " let a = v[0] == v[1]; }";
    try expectRejected(compare, std.mem.indexOf(u8, compare, "==").?, .type_mismatch);
    const int_splat = head ++ " let a = vec4f(1i); }";
    try expectRejected(int_splat, std.mem.indexOf(u8, int_splat, "1i").?, .type_mismatch);
    const lane_store = head ++ " v[0].x = 1.0; }";
    try expectRejected(lane_store, std.mem.indexOf(u8, lane_store, ".x").?, .unsupported);
    const mixed =
        \\@group(0) @binding(0) var<storage, read> a: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> b: array<vec4f>;
    ;
    try expectRejected(mixed, std.mem.lastIndexOf(u8, mixed, "vec4f").?, .unsupported);
}

test "compiles pixel kernels to a Tile component that calls them in order" {
    const shader =
        \\override gain: f32 = 1.0;
        \\fn scale(c: vec4f) -> vec4f { return vec4f(c.rgb * gain, c.a); }
        \\fn invert(c: vec4f) -> vec4f {
        \\  if c.a < 0.5 { return c; }
        \\  return vec4f(1.0 - c.rgb, c.a);
        \\}
    ;
    const size = try compile(shader);
    const module = output_buf[0..size];
    try testing.expect(std.mem.indexOf(u8, module, "tile_rgba32float_64x64") != null);
    try testing.expect(std.mem.indexOf(u8, module, "uniform_set_gain") != null);
    try testing.expect(std.mem.indexOf(u8, module, "render") == null);
    // v128.load, then call kernel 0 and kernel 1, then v128.store.
    try testing.expect(std.mem.indexOf(u8, module, &.{ 0xfd, 0x00, 4, 0, 0x10, 3, 0x10, 4, 0xfd, 0x0b, 4, 0 }) != null);
}

test "rejects pixel kernels outside the subset" {
    const no_return = "fn pixel(c: vec4f) -> vec4f { if c.a > 0.0 { return c; } }";
    try expectRejected(no_return, std.mem.lastIndexOf(u8, no_return, "}").?, .unsupported);
    const scalar_param = "fn pixel(c: f32) -> vec4f { return vec4f(c); }";
    try expectRejected(scalar_param, std.mem.indexOf(u8, scalar_param, "f32").?, .type_mismatch);
    const narrow_return = "fn pixel(c: vec4f) -> vec4f { return c.rgb; }";
    try expectRejected(narrow_return, std.mem.indexOf(u8, narrow_return, "rgb").?, .type_mismatch);
    const assign_param = "fn pixel(c: vec4f) -> vec4f { c.r = 0.0; return c; }";
    try expectRejected(assign_param, std.mem.indexOf(u8, assign_param, "c.r").?, .type_mismatch);
    const with_buffer =
        \\@group(0) @binding(0) var<storage, read_write> v: array<f32>;
        \\fn pixel(c: vec4f) -> vec4f { return c; }
    ;
    try expectRejected(with_buffer, std.mem.indexOf(u8, with_buffer, "fn").?, .unsupported);
    const then_buffer =
        \\fn pixel(c: vec4f) -> vec4f { return c; }
        \\@group(0) @binding(0) var<storage, read_write> v: array<f32>;
    ;
    try expectRejected(then_buffer, std.mem.indexOf(u8, then_buffer, "v:").?, .unsupported);
}
