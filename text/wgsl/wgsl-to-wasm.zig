//! wgsl-to-wasm: compiles a small subset of WGSL compute and fragment shaders
//! into a QIP Content component, or pixel kernels into a Tile component.
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
//! Compiler uniform `vectorize_invocations=1` enables four-wide whole-function
//! vectorization for compute shaders with separate input/output buffers and
//! identity output indices. It defaults to 0 and resets after each compilation.
//! Uniform values stay scalar, varying values occupy SIMD lanes, and divergent
//! control flow uses masks, including the final partial batch of invocations.
//! Dependencies, non-identity stores, Tile kernels, or exhausted optimization
//! budgets retain the original scalar module. Generated modules keep the ABI;
//! an optimized module records byte 4 in `qip.vectorize_invocations` metadata.
//! Scalar buffer elements at `id.x` load and store as whole v128s.
//!
//! Byte shaders vectorize further, 16 bytes per i8x16 operation, when each
//! byte of a u32 element maps independently:
//!
//!   let b = unpack4xU8(src[id.x]);
//!   let k = (b | vec4u(32u)) - vec4u(97u);
//!   dst[id.x] = pack4xU8(b + select(vec4u(0u), vec4u(13u), k < vec4u(13u)));
//!
//! Every vec4u must come from `unpack4xU8(src[id.x])` and literals through
//! `+ - & | ^ ~`, shifts by a splatted literal, comparisons, `select`, `min`,
//! `max` and `clamp`, every store must be `dst[id.x] = pack4xU8(...)`, and
//! the only branches are bounds guards on `id.x` and `arrayLength`. The
//! compiler then evaluates the shader in u32 and in u8 arithmetic for all 256
//! values of each input byte, and uses i8x16 only if every stored byte agrees.
//!
//! Accepted subset:
//!
//! - Module scope: `override` and `const` with a literal initializer, at most
//!   one `var<storage, read>` and one `var<storage, read_write>` of
//!   `array<f32|i32|u32|vec4f>`, and one `@compute` function. Both buffers
//!   must have the same element size. A shader with only a read_write buffer
//!   transforms the input in place. Names must be declared before use.
//! - Constant arrays, in a module with a `@compute` or `@fragment` entry:
//!   `const name = array<T, N>(...)`, `array(...)` or `const name:
//!   array<T, N> = ...`, with T f32, i32, u32 or vecNf and literal elements
//!   (vecNf elements as constructors of literals). They go into a data
//!   segment, and `name[i]` reads `min(u32(i), N - 1)`, as Dawn clamps.
//!   Shaders that index them are not vectorized.
//! - Helpers: in a module with a `@compute` or `@fragment` entry, every other
//!   `fn` is a helper compiled to its own Wasm function. Helpers come before
//!   the entry and call only helpers above them, so there is no recursion.
//!   They take up to 8 scalar or vector parameters, may return a value (and
//!   then must end with `return expr;`) or nothing, and may be called as a
//!   statement. Shaders that call helpers are not vectorized.
//! - Entry parameter: none, or `@builtin(global_invocation_id)` as `vec3<u32>`;
//!   only `.x`, `.y` and `.z` are readable, and `.y` and `.z` are always 0.
//! - Statements: `let`, `var`, `const`, assignment and compound assignment to
//!   `var` or to one lane of a vector var (`v.a *= 0.5;`), `++`, `--`, whole
//!   buffer element stores, `if`/`else if`/`else`, blocks, `return`, calls,
//!   `_ = expr;`, and constant-bounded loops:
//!   `for (var i = start; i < N; i++) { ... }` with `<`, `<=`, `>` or `>=`,
//!   `i++`, `i--`, `i += C`, `i -= C`, `i = i + C` or `i = i - C`, where N and
//!   C are integer literals or consts, the step runs the comparison's way and
//!   cannot wrap past N, and the body does not assign `i`. `break` and
//!   `continue` work inside them. Loops compile to counted Wasm loops that
//!   wasm-bounded-loops proves, and keep the scalar path when vectorized.
//! - Expressions: bool, i32, u32 and f32 scalars, abstract integer and float
//!   literals, arithmetic, comparison, logical and bitwise operators, buffer
//!   element loads, `arrayLength(&buffer)`, scalar conversions such as
//!   `f32(x)`, and `abs`, `sign`, `min`, `max`, `clamp`, `select`, `sqrt`,
//!   `inverseSqrt`, `floor`, `ceil`, `trunc`, `round`, `fract`, `mix`,
//!   `step`, `smoothstep`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`,
//!   `atan2`, `tanh`, `exp`, `exp2`, `log`, `log2`, `pow`, and `length` and
//!   `distance` (as `abs`) (see "Transcendental builtins" for accuracy).
//! - `vec2f`, `vec3f` and `vec4f` (or `vecN<f32>`) each lower to one v128:
//!   constructors `vecNf()`, `vecNf(s)`, `vecNf(v)`, and any mix of scalars
//!   and vectors that supplies N lanes, such as `vec4f(c.rgb, 1.0)`; members
//!   `.x` to `.w` or `.r` to `.a`, where one letter reads a lane and two to
//!   four letters swizzle (`c.bgr`, `c.xxxx`); `+ - * / %` lane-wise, with a
//!   scalar operand splatted; unary `-`; the f32 builtins above lane-wise,
//!   with every argument of `step`, `smoothstep`, `pow` and `atan2` the same
//!   vector type; `dot`, `length`, `distance` and `normalize`, as the square
//!   root of the sum of squares in lane order; and `mix(a, b, t)` as
//!   a * (1 - t) + b * t, with t a vector or an f32.
//!   Buffers hold only `vec4f` vectors. Swizzle assignment and float vector
//!   comparisons are unsupported.
//! - `vec4u` (or `vec4<u32>`) lowers to one i32x4: constructors from four
//!   u32s, a splat, a `vec4u` or a `vec4f` (saturating); `+ - *` with a u32
//!   splatted; `& | ^ ~`, `<<` and `>>` (per lane, modulo 32) and comparisons
//!   between two vec4u, which give a `vec4<bool>` of 0 or -1 lanes that
//!   supports `& | !` and locals; `select` with a `vec4<bool>` or a bool;
//!   `min`, `max` and `clamp`; members and two- or four-lane swizzles;
//!   `vec4f(v)`; `unpack4xU8(u32)` and `pack4xU8(vec4u)`, which keeps the low
//!   byte of each lane. Buffers cannot hold them, and `/`, `%`, `any` and `all`
//!   are unsupported.
//!
//! Fragment shaders: a module whose entry is `@fragment` runs it once per
//! RGBA32F pixel of the input and writes the returned colour:
//!
//!   @group(0) @binding(0) var src: texture_2d<f32>;
//!   @fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
//!     return textureLoad(src, vec2i(pos.xy), 0) * 0.5;
//!   }
//!
//! The parameter is optional, and the result must be `@location(0) vec4f`.
//! The component exports `uniform_set_width` (u32, default 0), which a host
//! sets to the image width before each render; width 0 or a partial row is
//! rejected, so the shader cannot declare an override named `width`. `pos` is
//! the pixel centre `(x + 0.5, y + 0.5, 0, 1)`, as for a full-viewport triangle
//! at depth 0. At most one `texture_2d<f32>` is the input image:
//! `textureDimensions(t)` is a `vec2u`, and `textureLoad(t, coords, level)`
//! takes `vec2i` or `vec2u` coordinates, clamped as Dawn's robustness does,
//! `min(u32(c), size - 1)`, so a negative coordinate reads the last column or
//! row (WGSL allows any texel or zero). A level other than 0 reads zero. `discard` returns transparent black, which matches a target
//! cleared to transparent black. Storage buffers are unsupported here.
//! `dpdx`, `dpdy` and `fwidth`, and their Fine and Coarse forms, take an f32
//! or float vector. A module that calls them runs its pixels in 2x2 quads
//! with helper lanes past odd edges, and every form is the fine derivative,
//! as Chrome computes on Metal; see emitQuadLoops. There, a `discard` inside
//! control flow demotes the invocation, which runs on and returns zero.
//! `vec2i` and `vec2u` (or `vec2<i32>`, `vec2<u32>`) support constructors from
//! scalars, splats, conversions to and from `vec2f`, members and swizzles of
//! up to two lanes, and lane-wise `+ - *` with a scalar splatted.
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
//! f32 precision between stages. Its final statement must be `return expr;`.
//! Overrides become uniforms as in compute shaders, but keep the value the
//! host last set, because the host sets them once per image.
//!
//! A kernel may also read its neighbors with `sample(dx, dy)`, the previous
//! stage's pixel at that offset, where `c` is `sample(0, 0)`:
//!
//!   fn blur(c: vec4f) -> vec4f {
//!     return (sample(-1, 0) + c + sample(1, 0)) / 3.0;
//!   }
//!
//! Each offset must be an integer literal or `const`, so the compiler knows
//! the footprint without running the kernel: a kernel's halo is its largest
//! |dx| or |dy|, and the module's halo is the sum over its kernels, at most
//! 32. A module whose kernels sample exports `calculate_halo_px` and
//! `uniform_set_width_and_height`. Each sampling kernel starts a pass that
//! reads the previous pass's output and writes a region that shrinks by the
//! kernel's halo, so the last pass writes the 64x64 core; point kernels join
//! the pass before them. Samples are clamped to the image, as the host clamps
//! the halo, so a fused module gives the same pixels as running each kernel
//! as its own stage.
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
const MAX_HELPERS: usize = 64;
const MAX_CONST_ARRAYS: usize = 32;
// Constant arrays live in a data segment in the second half of page 0, above
// the derivative banks.
const CONST_DATA_PTR: u32 = 32 * 1024;
const CONST_DATA_CAP: usize = 32 * 1024;
const MAX_PARAMS: usize = 8;
const HELPER_CODE_CAP: usize = 64 * 1024;

const INPUT_CONTENT_TYPE = "text/wgsl";
const OUTPUT_CONTENT_TYPE = "application/wasm";

// Generated component memory: page 0 is unused, then the input and output
// regions. An in-place shader returns its input region as output.
const RUN_INPUT_PTR: u32 = 64 * 1024;
const RUN_BYTES_CAP: u32 = 4 * 1024 * 1024;
const RUN_OUTPUT_PTR: u32 = RUN_INPUT_PTR + RUN_BYTES_CAP;
const RUN_PAGES: u32 = (RUN_OUTPUT_PTR + RUN_BYTES_CAP) / (64 * 1024);

// Generated component function and global indices.
const FN_RENDER: u32 = 4;
const FN_MAIN: u32 = 5;
const FN_FIRST_SETTER: u32 = 6;
const GLOBAL_COUNT: u32 = 0;
const GLOBAL_FIRST_OVERRIDE: u32 = 1;

// Generated Tile component: one page holds the 64x64 RGBA32F tile. With a
// halo, the tile buffer is (64 + 2 * halo) pixels square, and a scratch
// buffer of the same size follows it.
const TILE_INPUT_PTR: u32 = 0;
const TILE_SIZE: u32 = 64;
const MAX_HALO: u32 = 32;
const FN_TILE: u32 = 2;
// Only modules whose kernels sample have `sample`, so kernels follow it there.
const FN_SAMPLE: u32 = 3;
// Tile state globals, after the overrides in a module whose kernels sample.
const TileState = enum(u32) { width, height, x0, y0, col, row, lo, hi };

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var body_buf: [BODY_CAP]u8 = undefined;
var kernel_code_buf: [KERNEL_CODE_CAP]u8 = undefined;
var helper_code_buf: [HELPER_CODE_CAP]u8 = undefined;
var const_data: [CONST_DATA_CAP]u8 = undefined;
var const_data_len: usize = 0;
const ConstArray = struct { name: Token, elem: Ty, len: u32, offset: u32 };
var const_arrays: [MAX_CONST_ARRAYS]ConstArray = undefined;
var const_array_count: usize = 0;

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

const Ty = enum(u8) { void, bool, i32, u32, f32, vec2f, vec3f, vec4f, vec2i, vec2u, vec4u, vec4b, abstract_int, abstract_float };

// Every vector lowers to one v128; lanes past its length are unused.
fn isVec(t: Ty) bool {
    return t == .vec2f or t == .vec3f or t == .vec4f;
}

// `vec2i` and `vec2u` exist for texture coordinates and dimensions: they
// support constructors, conversions, members, and lane-wise `+ - *`.
// `vec4u` is one u32 per lane of an i32x4 for byte work: it adds bitwise
// operators, shifts, comparisons into `vec4<bool>` (`vec4b`, 0 or -1 lanes),
// `select`, `min`, `max`, `clamp`, `unpack4xU8` and `pack4xU8`.
fn isIVec(t: Ty) bool {
    return t == .vec2i or t == .vec2u or t == .vec4u;
}

fn ivecElem(t: Ty) Ty {
    return if (t == .vec2i) .i32 else .u32;
}

// The `vecN<u32>` for a swizzle of `len` integer lanes.
fn ivecOf(source: Ty, len: u8) Ty {
    return if (len == 4) .vec4u else if (source == .vec2i) .vec2i else .vec2u;
}

fn vecLen(t: Ty) u8 {
    return switch (t) {
        .vec2f, .vec2i, .vec2u => 2,
        .vec3f => 3,
        .vec4f, .vec4u, .vec4b => 4,
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
        .vec2f, .vec3f, .vec4f, .vec2i, .vec2u, .vec4u, .vec4b => 0x7b,
        else => 0x7f,
    };
}

// log2 of a buffer element's byte size.
fn elemShift(t: Ty) u5 {
    return if (isVec(t)) 4 else 2;
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

// A scalar type, `vecNf` or `vecN<f32>` for N in 2..4, `vec2i`, `vec2u`,
// `vec2<i32>`, `vec2<u32>`, `vec4u`, `vec4<u32>` or `vec4<bool>`.
fn parseType() CompileError!Ty {
    const t = peek();
    if (vecWordLen(t, true)) |len| {
        _ = advance();
        return vecOf(len);
    }
    if (isWord(t, "vec2i") or isWord(t, "vec2u") or isWord(t, "vec4u")) {
        _ = advance();
        return if (isWord(t, "vec2i")) .vec2i else if (isWord(t, "vec2u")) .vec2u else .vec4u;
    }
    const len = vecWordLen(t, false) orelse return parseScalarType();
    _ = advance();
    _ = try expect(.lt);
    const elem = peek();
    const int_elem = isWord(elem, "i32") or isWord(elem, "u32");
    const wide = len == 4 and (isWord(elem, "u32") or isWord(elem, "bool"));
    if (!isWord(elem, "f32") and !(int_elem and len == 2) and !wide) return fail(elem.start, .unsupported);
    _ = advance();
    if (peek().kind == .shr) {
        // `array<vec4<f32>>` lexes its closing `>>` as one token: consume half.
        tokens[pos].kind = .gt;
        tokens[pos].start += 1;
        tokens[pos].len = 1;
    } else {
        _ = try expect(.gt);
    }
    if (wide) return if (isWord(elem, "bool")) .vec4b else .vec4u;
    if (int_elem) return if (isWord(elem, "i32")) .vec2i else .vec2u;
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

const Local = struct { name: Token, index: u32, ty: Ty, mutable: bool, const_value: ?ConstFloat = null };
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
// Fragment shaders: the entry is `@fragment`, and the optional texture is the
// input image.
var fragment_entry = false;
var in_fragment = false;
var texture_name: ?Token = null;
// A module with a `@compute` or `@fragment` entry treats its other functions
// as helpers, compiled to Wasm functions after the entry, in source order.
// Without one, every function is a pixel kernel.
var stage_module = false;
// A fragment module that calls dpdx, dpdy or fwidth (or their Fine and Coarse
// forms) runs its pixels in 2x2 quads; see emitDerivRender.
var fragment_module = false;
var uses_derivatives = false;
const Helper = struct { name: Token, params: [MAX_PARAMS]Ty, param_count: u8, ret: Ty };
var helpers: [MAX_HELPERS]Helper = undefined;
var helper_count: usize = 0;
var helper_code: Buf = .{ .bytes = &helper_code_buf };
// The function being parsed: its Wasm parameter count, which precedes its
// locals, and its WGSL result type (void for a compute entry).
var param_count: u32 = 1;
var return_ty: Ty = .void;
// A call statement may call a helper without a result.
var allow_void_call = false;
// Pixel kernels: code entries are complete once each kernel is parsed.
var kernel_count: usize = 0;
var in_kernel = false;
var kernel_returned = false;
// Each kernel's halo, the largest |dx| or |dy| it samples, and their sum.
var kernel_halos: [MAX_KERNELS]u8 = undefined;
var kernel_samples: [MAX_KERNELS]bool = undefined;
var tile_halo: u32 = 0;
var tile_samples = false;

// Opt-in, bounded compute IR. Capture only after the scalar parser validates
// each expression. If this budget is exceeded, retain the scalar compilation.
const IR_NODE_CAP = 8192;
const IR_STMT_CAP = 2048;
const Expr = struct { start: u16 = 0, len: u16 = 0 };
const StmtKind = enum { declare, assign, store, if_head, else_head, end_if, ret, discard };
const Stmt = struct {
    kind: StmtKind,
    expr: Expr = .{},
    index_expr: Expr = .{},
    local: u32 = 0,
    ty: Ty = .void,
    op: Tk = .eq,
    lane: u8 = 255,
};
var ir_nodes: [IR_NODE_CAP]Node = undefined;
var ir_stmts: [IR_STMT_CAP]Stmt = undefined;
var ir_node_len: usize = 0;
var ir_stmt_len: usize = 0;
var ir_complete = false;
var last_expr = Expr{};
var vectorize_invocations: u32 = 0;
var vectorized = false;
// The byte path's entry loops over every element itself and stores each one.
var byte_kernel = false;
var scalar_code = Buf{ .bytes = &kernel_code_buf };

fn rememberExpr(root: u16) void {
    last_expr = .{};
    if (!ir_complete) return;
    const len = @as(usize, root) + 1;
    if (len > IR_NODE_CAP - ir_node_len) {
        ir_complete = false;
        return;
    }
    last_expr = .{ .start = @intCast(ir_node_len), .len = @intCast(len) };
    @memcpy(ir_nodes[ir_node_len..][0..len], nodes[0..len]);
    ir_node_len += len;
}

fn rememberLiteral(lit: Literal) void {
    if (!ir_complete) return;
    if (ir_node_len == IR_NODE_CAP) {
        ir_complete = false;
        return;
    }
    last_expr = .{ .start = @intCast(ir_node_len), .len = 1 };
    ir_nodes[ir_node_len] = .{ .kind = .lit, .ty = lit.ty, .lit = lit, .offset = 0 };
    ir_node_len += 1;
}

fn rememberStmt(stmt: Stmt) void {
    if (!ir_complete) return;
    if (ir_stmt_len == IR_STMT_CAP) {
        ir_complete = false;
        return;
    }
    ir_stmts[ir_stmt_len] = stmt;
    ir_stmt_len += 1;
}

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
    if (texture_name) |t| if (sameName(t, name)) return true;
    if (lookupHelper(name) != null) return true;
    if (lookupConstArray(name) != null) return true;
    return false;
}

fn lookupConstArray(name: Token) ?usize {
    for (const_arrays[0..const_array_count], 0..) |a, i| if (sameName(a.name, name)) return i;
    return null;
}

fn lookupHelper(name: Token) ?usize {
    for (helpers[0..helper_count], 0..) |h, i| if (sameName(h.name, name)) return i;
    return null;
}

fn helperFn(index: usize) u32 {
    return @intCast(FN_MAIN + 1 + @intFromBool(uses_derivatives) + index);
}

// Derivative modules: the function that records an argument and returns its
// derivative follows the entry, and five globals follow width and height.
const FN_DERIV: u32 = FN_MAIN + 1;
const DerivState = enum(u32) { count, lane, pass, discarded, overflow };
fn derivGlobal(state: DerivState) u32 {
    return globalWidth() + 2 + @intFromEnum(state);
}
// Each of up to DERIV_CALLS derivative calls per invocation stores its
// argument for the quad's four lanes in the pass's bank, in page 0.
const DERIV_CALLS: u32 = 256;
const DERIV_BANK: u32 = DERIV_CALLS * 64;
const DERIV_PASSES: u32 = 8;

fn lookupLocal(name: Token) ?Local {
    var i = scope_len;
    while (i > 0) {
        i -= 1;
        if (sameName(scope[i].name, name)) return scope[i];
    }
    return null;
}

fn allocLocal(ty: Ty) CompileError!u32 {
    if (batch_temps) return batchTemp(ty);
    return allocPersistent(ty);
}

fn allocPersistent(ty: Ty) CompileError!u32 {
    if (local_count >= MAX_LOCALS) return fail(peek().start, .unsupported);
    local_types[local_count] = valType(ty);
    local_count += 1;
    return @intCast(param_count + local_count - 1); // after the parameters
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
const SIMD_I32X4_EXTRACT_LANE: u32 = 27;
const SIMD_I32X4_REPLACE_LANE: u32 = 28;
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
const SIMD_I32X4_MUL: u32 = 181;
const SIMD_I32X4_EQ: u32 = 55;
const SIMD_I32X4_ALL_TRUE: u32 = 163;

fn literalValue(lit: Literal) i32 {
    return @truncate(lit.int_value);
}

fn emitLiteral(w: *Buf, lit: Literal) CompileError!void {
    if (lit.ty == .f32) return w.f32Const(@floatCast(lit.float_value));
    if (isVec(lit.ty) or isIVec(lit.ty)) {
        // Only the zero vector is a literal.
        try w.simd(SIMD_CONST);
        return w.raw(&([_]u8{0} ** 16));
    }
    try w.i32Const(literalValue(lit));
}

// ---------------------------------------------------------------------------
// Expressions

const NodeKind = enum(u8) { lit, local, override, gid_x, array_len, load, lane, swizzle, unary, binary, call, sample, texture_dims, user_call, const_load };

const Callee = enum(u8) { abs, sign, min, max, clamp, select, sqrt, inverse_sqrt, floor, ceil, trunc, round, fract, sin, cos, tan, asin, acos, atan, atan2, tanh, exp, exp2, log, log2, pow, step, smoothstep, dot, length, distance, normalize, mix, to_f32, to_i32, to_u32, to_bool, vec2f, vec3f, vec4f, vec2i, vec2u, vec4u, texture_load, dpdx, dpdy, fwidth, unpack4xU8, pack4xU8 };

const Node = struct {
    kind: NodeKind,
    // Tk for unary and binary, Callee for call, buffer 0/1 for load, index
    // for lane, and source lanes packed two bits each for swizzle. A sample
    // keeps its offsets in `lit.int_value` (dx) and `ref` (dy, as i32 bits).
    op: u8 = 0,
    ty: Ty,
    opnd_ty: Ty = .void,
    kids: [4]u16 = .{ 0, 0, 0, 0 },
    argc: u8 = 0,
    ref: u32 = 0,
    lit: Literal = .{ .ty = .void },
    offset: u32,
};

const ConstFloat = struct { len: u8 = 1, values: [4]f64 = .{ 0, 0, 0, 0 } };

fn constFloat(index: u16) ?ConstFloat {
    const node = nodes[index];
    switch (node.kind) {
        .lit => {
            if (node.ty == .bool) return null;
            const value: f64 = if (node.ty == .abstract_int or node.ty == .i32 or node.ty == .u32)
                @floatFromInt(node.lit.int_value)
            else
                node.lit.float_value;
            return .{ .len = vecLen(node.ty), .values = .{ value, value, value, value } };
        },
        .local => {
            for (scope[0..scope_len]) |local| {
                if (local.index == node.ref) return local.const_value;
            }
            return null;
        },
        .unary => {
            if (@as(Tk, @enumFromInt(node.op)) != .minus) return null;
            var value = constFloat(node.kids[0]) orelse return null;
            for (value.values[0..value.len]) |*lane| lane.* = -lane.*;
            return value;
        },
        .binary => {
            const op: Tk = @enumFromInt(node.op);
            if (op != .plus and op != .minus and op != .star and op != .slash) return null;
            const a = constFloat(node.kids[0]) orelse return null;
            const b = constFloat(node.kids[1]) orelse return null;
            var result = ConstFloat{ .len = @max(a.len, b.len) };
            for (0..result.len) |lane| {
                const x = a.values[if (a.len == 1) 0 else lane];
                const y = b.values[if (b.len == 1) 0 else lane];
                const value = switch (op) {
                    .plus => x + y,
                    .minus => x - y,
                    .star => x * y,
                    .slash => x / y,
                    else => unreachable,
                };
                result.values[lane] = if (node.ty == .f32 or isVec(node.ty)) @as(f64, @floatCast(@as(f32, @floatCast(value)))) else value;
            }
            return result;
        },
        .call => {
            const callee: Callee = @enumFromInt(node.op);
            if (callee == .to_f32) {
                var value = constFloat(node.kids[0]) orelse return null;
                value.values[0] = @as(f64, @floatCast(@as(f32, @floatCast(value.values[0]))));
                return value;
            }
            if (callee != .vec2f and callee != .vec3f and callee != .vec4f) return null;
            var result = ConstFloat{ .len = vecLen(node.ty) };
            if (node.argc == 1) {
                const value = constFloat(node.kids[0]) orelse return null;
                for (0..result.len) |lane| result.values[lane] = @as(f32, @floatCast(value.values[if (value.len == 1) 0 else lane]));
                return result;
            }
            var lane: usize = 0;
            for (node.kids[0..node.argc]) |kid| {
                const value = constFloat(kid) orelse return null;
                for (value.values[0..value.len]) |part| {
                    result.values[lane] = @as(f32, @floatCast(part));
                    lane += 1;
                }
            }
            return result;
        },
        .lane, .swizzle => {
            const source = constFloat(node.kids[0]) orelse return null;
            var result = ConstFloat{ .len = vecLen(node.ty) };
            for (0..result.len) |lane| {
                const source_lane = if (node.kind == .lane) node.op else (node.op >> @intCast(2 * lane)) & 3;
                result.values[lane] = source.values[source_lane];
            }
            return result;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Whole-function vectorization across four independent compute invocations.
// Uniform values retain their original Wasm representation. A varying scalar
// is one v128; a varying WGSL vector is one v128 per component (SoA).
const BatchValue = struct { ty: Ty, varying: bool = false, literal: bool = false, regs: [4]u32 = .{ 0, 0, 0, 0 }, constant: ?u32 = null };
var batch_locals: [MAX_LOCALS + 1]BatchValue = undefined;
var batch_varying: [MAX_LOCALS + 1]bool = undefined;
var batch_values: [MAX_NODES]BatchValue = undefined;
var batch_flags: [MAX_NODES]bool = undefined;
var batch_temps = false;
var batch_temp_regs: [3][MAX_LOCALS]u32 = undefined;
var batch_temp_len: [3]usize = .{ 0, 0, 0 };
var batch_temp_used: [3]usize = .{ 0, 0, 0 };
var batch_active: u32 = 0;
var batch_alive: u32 = 0;
const BatchSplat = struct { bits: u32, reg: u32, count: u32, float: bool };
// A bounded pool of repeated literal splats. Uncached constants stay inline;
// bitwise keys preserve distinctions such as positive and negative zero.
var batch_splats: [32]BatchSplat = undefined;
var batch_splat_len: usize = 0;

fn findBatchSplat(bits: u32, float: bool) ?u32 {
    for (batch_splats[0..batch_splat_len]) |s| {
        if (s.bits == bits and s.float == float and s.count >= 3) return s.reg;
    }
    return null;
}

fn emitBatchSplats() CompileError!void {
    batch_splat_len = 0;
    for (ir_nodes[0..ir_node_len]) |node| {
        if (node.kind != .lit or isVec(node.ty) or node.ty == .bool) continue;
        const float = node.ty == .f32;
        const bits: u32 = if (float) @bitCast(@as(f32, @floatCast(node.lit.float_value))) else @bitCast(literalValue(node.lit));
        var found = false;
        for (batch_splats[0..batch_splat_len]) |*s| {
            if (s.bits == bits and s.float == float) {
                s.count += 1;
                found = true;
                break;
            }
        }
        if (!found and batch_splat_len < batch_splats.len) {
            batch_splats[batch_splat_len] = .{ .bits = bits, .float = float, .count = 1, .reg = 0 };
            batch_splat_len += 1;
        }
    }
    for (batch_splats[0..batch_splat_len]) |*s| {
        if (s.count < 3) continue;
        s.reg = try allocPersistent(.vec4f);
        if (s.float) try body.f32Const(@bitCast(s.bits)) else try body.i32Const(@bitCast(s.bits));
        try body.simd(if (s.float) SIMD_F32X4_SPLAT else 17);
        try body.localSet(s.reg);
    }
}

fn nodeArity(node: Node) usize {
    return switch (node.kind) {
        .binary => 2,
        .call => node.argc,
        .load, .lane, .swizzle, .unary => 1,
        else => 0,
    };
}

fn invocationIndependent() bool {
    for (ir_nodes[0..ir_node_len]) |node| {
        if (node.kind == .sample or (node.kind == .load and node.op != 0)) return false;
        // Helper calls and integer vectors keep the scalar path.
        if (node.kind == .user_call or node.kind == .const_load or isIVec(node.ty) or isIVec(node.opnd_ty) or node.ty == .vec4b) return false;
    }
    var identities = [_]bool{false} ** (MAX_LOCALS + 1);
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (stmt.kind == .declare) {
            const root = ir_nodes[stmt.expr.start + stmt.expr.len - 1];
            identities[stmt.local] = stmt.expr.len == 1 and (root.kind == .gid_x or (root.kind == .local and identities[root.ref]));
        } else if (stmt.kind == .assign) {
            identities[stmt.local] = false;
        } else if (stmt.kind == .store) {
            const root = ir_nodes[stmt.index_expr.start + stmt.index_expr.len - 1];
            if (stmt.index_expr.len != 1 or !(root.kind == .gid_x or (root.kind == .local and identities[root.ref]))) return false;
        }
    }
    return true;
}

fn exprVarying(expr: Expr) bool {
    if (expr.len == 0) return false;
    for (ir_nodes[expr.start..][0..expr.len], 0..) |node, i| {
        var varying = node.kind == .gid_x or (node.kind == .local and batch_varying[node.ref]);
        for (node.kids[0..nodeArity(node)]) |kid| varying = varying or batch_flags[kid];
        batch_flags[i] = varying;
    }
    return batch_flags[expr.len - 1];
}

fn analyzeBatchUniformity() void {
    @memset(&batch_varying, false);
    // Monotonic fixed point: each changing pass marks at least one of the
    // bounded original local IDs varying. No shader code executes here.
    for (0..MAX_LOCALS + 1) |_| {
        var changed = false;
        var control = false;
        var alive = false;
        var parents: [MAX_BLOCKS]bool = undefined;
        var depth: usize = 0;
        for (ir_stmts[0..ir_stmt_len]) |stmt| {
            const varying = exprVarying(stmt.expr);
            switch (stmt.kind) {
                .declare, .assign => {
                    if ((varying or (stmt.kind == .assign and control)) and !batch_varying[stmt.local]) {
                        batch_varying[stmt.local] = true;
                        changed = true;
                    }
                },
                .if_head => {
                    parents[depth] = control;
                    depth += 1;
                    control = control or varying;
                },
                .end_if => {
                    depth -= 1;
                    control = parents[depth] or alive;
                },
                .ret => {
                    alive = alive or control;
                    control = control or alive;
                },
                else => {},
            }
        }
        if (!changed) break;
    }
}

fn batchTemp(ty: Ty) CompileError!u32 {
    const kind: usize = if (isVec(ty)) 2 else if (ty == .f32) 1 else 0;
    const i = batch_temp_used[kind];
    if (i >= MAX_LOCALS) return fail(0, .unsupported);
    batch_temp_used[kind] += 1;
    if (i == batch_temp_len[kind]) {
        batch_temp_regs[kind][i] = try allocPersistent(ty);
        batch_temp_len[kind] += 1;
    }
    return batch_temp_regs[kind][i];
}

fn batchValue(ty: Ty, varying: bool, persistent: bool) CompileError!BatchValue {
    var value = BatchValue{ .ty = ty, .varying = varying };
    for (0..if (varying) vecLen(ty) else 1) |i| {
        const rt: Ty = if (varying) .vec4f else ty;
        value.regs[i] = if (persistent) try allocPersistent(rt) else try batchTemp(rt);
    }
    return value;
}

fn batchSplat(ty: Ty) CompileError!void {
    if (ty == .bool) {
        // Scalar booleans use 0/1; SIMD masks use 0/-1.
        try body.i32Const(-1);
        try body.byte(0x6c);
    }
    try body.simd(if (ty == .f32) SIMD_F32X4_SPLAT else 17); // i32x4.splat
}

fn batchUniformGet(value: BatchValue) CompileError!void {
    if (!value.literal) return body.localGet(value.regs[0]);
    if (value.ty == .f32) return body.f32Const(@bitCast(value.constant.?));
    if (isVec(value.ty)) {
        try body.simd(SIMD_CONST);
        return body.raw(&([_]u8{0} ** 16));
    }
    return body.i32Const(@bitCast(value.constant.?));
}

fn batchGet(value: BatchValue, component: usize) CompileError!void {
    if (value.literal and !isVec(value.ty) and value.ty != .bool) {
        if (findBatchSplat(value.constant.?, value.ty == .f32)) |reg| return body.localGet(reg);
    }
    if (value.varying) {
        try body.localGet(value.regs[if (isVec(value.ty)) component else 0]);
    } else {
        try batchUniformGet(value);
    }
    if (!value.varying) {
        if (isVec(value.ty)) try body.simdLane(SIMD_F32X4_EXTRACT_LANE, @intCast(component));
        try batchSplat(if (isVec(value.ty)) .f32 else value.ty);
    }
}

fn batchConst(value: i32) CompileError!void {
    if (findBatchSplat(@bitCast(value), false)) |reg| return body.localGet(reg);
    try body.i32Const(value);
    try body.simd(17);
}

fn batchFloat(value: f32) CompileError!void {
    if (findBatchSplat(@bitCast(value), true)) |reg| return body.localGet(reg);
    try body.f32Const(value);
    try body.simd(SIMD_F32X4_SPLAT);
}

fn batchBinary(kind: Tk, ty: Ty, a: BatchValue, b: BatchValue, component: usize) CompileError!void {
    const lane_ty: Ty = if (isVec(ty)) .f32 else ty;
    if (isInt(lane_ty) and (kind == .shl or kind == .shr) and !b.varying) {
        try batchGet(a, component);
        try batchUniformGet(b);
        return body.simd(if (kind == .shl) 171 else if (lane_ty == .i32) 172 else 173);
    }
    if (lane_ty == .u32 and (kind == .slash or kind == .percent)) {
        if (b.constant) |divisor| return batchUnsignedConstantDivide(a, divisor, kind == .percent);
    }
    if (isInt(lane_ty) and (kind == .slash or kind == .percent or kind == .shl or kind == .shr)) {
        // SIMD has no integer division, remainder, or per-lane shift counts.
        // Use the existing nontrapping scalar rules for these operations.
        const result = try batchTemp(.vec4f);
        try batchConst(0);
        try body.localSet(result);
        for (0..4) |lane| {
            try body.localGet(result);
            try batchGet(a, component);
            try body.simdLane(27, @intCast(lane)); // i32x4.extract_lane
            try batchGet(b, component);
            try body.simdLane(27, @intCast(lane));
            try emitArith(kind, lane_ty);
            try body.simdLane(28, @intCast(lane)); // i32x4.replace_lane
            try body.localSet(result);
        }
        return body.localGet(result);
    }
    try batchGet(a, component);
    try batchGet(b, component);
    if (lane_ty == .f32 and (kind == .plus or kind == .minus or kind == .star or kind == .slash or kind == .percent))
        return emitVecArith(kind, .vec4f, .vec4f);
    const signed = lane_ty == .i32;
    const op: u32 = switch (kind) {
        .plus => 174,
        .minus => 177,
        .star => 181,
        .amp, .amp_amp => 78,
        .pipe, .pipe_pipe => 80,
        .caret => 81,
        .eq_eq => if (lane_ty == .f32) 65 else 55,
        .bang_eq => if (lane_ty == .f32) 66 else 56,
        .lt => if (lane_ty == .f32) 67 else if (signed) 57 else 58,
        .gt => if (lane_ty == .f32) 68 else if (signed) 59 else 60,
        .le => if (lane_ty == .f32) 69 else if (signed) 61 else 62,
        .ge => if (lane_ty == .f32) 70 else if (signed) 63 else 64,
        else => return fail(0, .unsupported),
    };
    try body.simd(op);
}

fn batchUnsignedConstantDivide(a: BatchValue, divisor: u32, remainder: bool) CompileError!void {
    if (divisor == 0 or divisor == 1) {
        if (remainder) return batchConst(0);
        return batchGet(a, 0);
    }
    if (std.math.isPowerOfTwo(divisor)) {
        try batchGet(a, 0);
        if (remainder) {
            try batchConst(@bitCast(divisor - 1));
            return body.simd(78);
        }
        try body.i32Const(@intCast(@ctz(divisor)));
        return body.simd(173);
    }
    // q0=floor(x*floor(2^32/d)/2^32) is at most one below floor(x/d).
    // Its remainder cannot wrap because q0*d <= x. One unsigned comparison
    // corrects both quotient and remainder for every u32 input and divisor.
    const multiplier: u32 = @intCast((@as(u64, 1) << 32) / divisor);
    const low = try batchTemp(.vec4f);
    const quotient = try batchTemp(.vec4f);
    const rest = try batchTemp(.vec4f);
    try batchGet(a, 0);
    try batchConst(@bitCast(multiplier));
    try body.simd(222); // i64x2.extmul_low_i32x4_u
    try body.i32Const(32);
    try body.simd(205); // i64x2.shr_u
    try body.localSet(low);
    try batchGet(a, 0);
    try batchConst(@bitCast(multiplier));
    try body.simd(223); // i64x2.extmul_high_i32x4_u
    try body.i32Const(32);
    try body.simd(205);
    const high = try batchTemp(.vec4f);
    try body.localSet(high);
    try body.localGet(low);
    try body.localGet(high);
    try emitLaneShuffle(.{ 0, 2, 4, 6 });
    try body.localSet(quotient);
    try batchGet(a, 0);
    try body.localGet(quotient);
    try batchConst(@bitCast(divisor));
    try body.simd(181);
    try body.simd(177);
    try body.localSet(rest);
    if (remainder) try body.localGet(rest) else try body.localGet(quotient);
    try body.localGet(rest);
    try batchConst(@bitCast(divisor));
    try body.simd(64); // i32x4.ge_u
    if (remainder) {
        try batchConst(@bitCast(divisor));
        try body.simd(78);
    }
    try body.simd(177);
}

fn batchMinMax(ty: Ty, max: bool) CompileError!void {
    try body.simd(if (ty == .f32 or isVec(ty))
        (if (max) SIMD_F32X4_MAX else SIMD_F32X4_MIN)
    else if (ty == .i32) (if (max) @as(u32, 184) else 182) else (if (max) @as(u32, 185) else 183));
}

// A local declared as `id.x` (or another such local) and never assigned.
var batch_identity: [MAX_LOCALS + 1]bool = undefined;

fn analyzeBatchIdentities() void {
    @memset(&batch_identity, false);
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (stmt.kind != .declare) continue;
        const root = ir_nodes[stmt.expr.start + stmt.expr.len - 1];
        batch_identity[stmt.local] = stmt.expr.len == 1 and (root.kind == .gid_x or (root.kind == .local and batch_identity[root.ref]));
    }
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (stmt.kind == .assign) batch_identity[stmt.local] = false;
    }
}

fn isIdentityIndex(index: Node) bool {
    return index.kind == .gid_x or (index.kind == .local and batch_identity[index.ref]);
}

fn batchLoad(node: Node, index: BatchValue, out: BatchValue, contiguous: bool) CompileError!void {
    if (contiguous and !isVec(node.ty)) {
        // Lanes id.x .. id.x + 3 are adjacent elements. Absent tail lanes
        // read zero, as an out-of-range load does; the read itself stays
        // inside the input capacity, a multiple of 16 bytes.
        try body.localGet(0);
        try body.i32Const(2);
        try body.byte(0x74);
        try body.simd(SIMD_LOAD);
        try body.byte(2);
        try body.uleb(bufferBase(0));
        try body.localGet(batch_alive);
        try body.simd(78); // v128.and
        return body.localSet(out.regs[0]);
    }
    for (0..vecLen(node.ty)) |component| {
        try batchConst(0);
        try body.localSet(out.regs[component]);
        for (0..4) |lane| {
            try body.localGet(out.regs[component]);
            try batchGet(index, 0);
            try body.simdLane(27, @intCast(lane));
            const address = try batchTemp(.u32);
            try body.localTee(address);
            try body.byte(0x23);
            try body.uleb(GLOBAL_COUNT);
            try body.raw(&.{ 0x49, 0x04, if (node.ty == .f32 or isVec(node.ty)) @as(u8, 0x7d) else 0x7f });
            try body.localGet(address);
            try body.i32Const(elemShift(node.ty));
            try body.byte(0x74);
            try body.byte(if (node.ty == .f32 or isVec(node.ty)) 0x2a else 0x28);
            try body.byte(2);
            try body.uleb(bufferBase(0) + component * 4);
            try body.byte(0x05);
            try emitLiteral(&body, .{ .ty = if (isVec(node.ty)) .f32 else node.ty });
            try body.byte(0x0b);
            try body.simdLane(if (node.ty == .f32 or isVec(node.ty)) SIMD_F32X4_REPLACE_LANE else 28, @intCast(lane));
            try body.localSet(out.regs[component]);
        }
    }
}

fn batchExpr(expr: Expr) CompileError!BatchValue {
    const expr_nodes = ir_nodes[expr.start..][0..expr.len];
    @memcpy(nodes[0..expr.len], expr_nodes);
    for (expr_nodes, 0..) |node_in, i| {
        const node = node_in;
        var varying = node.kind == .gid_x or (node.kind == .local and batch_varying[node.ref]);
        for (node.kids[0..nodeArity(node)]) |kid| varying = varying or batch_values[kid].varying;
        if (node.kind == .local) {
            batch_values[i] = batch_locals[node.ref];
            continue;
        }
        // Literals need no temporary local. Component extraction and
        // swizzling of SoA vectors only rename existing registers.
        if (node.kind == .lit) {
            batch_values[i] = .{ .ty = node.ty, .literal = true, .constant = if (node.ty == .f32) @bitCast(@as(f32, @floatCast(node.lit.float_value))) else @bitCast(literalValue(node.lit)) };
            continue;
        }
        const a = if (nodeArity(node) > 0) batch_values[node.kids[0]] else BatchValue{ .ty = .void };
        const b = if (nodeArity(node) > 1) batch_values[node.kids[1]] else a;
        const t = if (nodeArity(node) > 2) batch_values[node.kids[2]] else a;
        if (varying and a.varying and (node.kind == .lane or node.kind == .swizzle)) {
            var alias = BatchValue{ .ty = node.ty, .varying = true };
            for (0..vecLen(node.ty)) |component| {
                alias.regs[component] = a.regs[if (node.kind == .lane) node.op else (node.op >> @intCast(2 * component)) & 3];
            }
            batch_values[i] = alias;
            continue;
        }
        var out = try batchValue(node.ty, varying, false);
        batch_values[i] = out;
        if (!varying) {
            for (node.kids[0..nodeArity(node)]) |kid| try batchUniformGet(batch_values[kid]);
            try emitNode(node);
            try body.localSet(out.regs[0]);
            continue;
        }
        if (node.kind == .load) {
            try batchLoad(node, a, out, isIdentityIndex(expr_nodes[node.kids[0]]));
            continue;
        }
        if (node.kind == .gid_x) {
            try body.localGet(0);
            try body.simd(17);
            try body.simd(SIMD_CONST);
            try body.raw(&.{ 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 });
            try body.simd(174);
            try body.localSet(out.regs[0]);
            continue;
        }
        if (node.kind == .call and (@as(Callee, @enumFromInt(node.op)) == .vec2f or
            @as(Callee, @enumFromInt(node.op)) == .vec3f or @as(Callee, @enumFromInt(node.op)) == .vec4f))
        {
            var component: usize = 0;
            for (node.kids[0..node.argc]) |kid| {
                const arg = batch_values[kid];
                const count = if (node.argc == 1 and !isVec(arg.ty)) vecLen(node.ty) else vecLen(arg.ty);
                for (0..count) |c| {
                    if (arg.varying) {
                        out.regs[component] = arg.regs[if (isVec(arg.ty)) c else 0];
                    } else {
                        try batchGet(arg, if (isVec(arg.ty)) c else 0);
                        try body.localSet(out.regs[component]);
                    }
                    component += 1;
                }
            }
            batch_values[i] = out;
            continue;
        }
        if (node.kind == .call and @as(Callee, @enumFromInt(node.op)) == .dot) {
            for (0..vecLen(a.ty)) |component| {
                try batchGet(a, component);
                try batchGet(b, component);
                try body.simd(SIMD_F32X4_MUL);
                if (component != 0) try body.simd(SIMD_F32X4_ADD);
            }
            try body.localSet(out.regs[0]);
            continue;
        }
        if (node.kind == .call) switch (@as(Callee, @enumFromInt(node.op))) {
            .length, .distance, .normalize => |callee| {
                // sqrt of the sum of squares in component order, as emitDot.
                const length = try batchTemp(.vec4f);
                for (0..vecLen(a.ty)) |component| {
                    try batchGet(a, component);
                    if (callee == .distance) {
                        try batchGet(b, component);
                        try body.simd(SIMD_F32X4_SUB);
                    }
                    if (!isVec(a.ty)) {
                        try body.simd(SIMD_F32X4_ABS);
                        break;
                    }
                    try body.localTee(length);
                    try body.localGet(length);
                    try body.simd(SIMD_F32X4_MUL);
                    if (component != 0) try body.simd(SIMD_F32X4_ADD);
                }
                if (isVec(a.ty)) try body.simd(SIMD_F32X4_SQRT);
                try body.localSet(length);
                if (callee != .normalize) {
                    try body.localGet(length);
                    try body.localSet(out.regs[0]);
                } else for (0..vecLen(a.ty)) |component| {
                    try batchGet(a, component);
                    try body.localGet(length);
                    try body.simd(SIMD_F32X4_DIV);
                    try body.localSet(out.regs[component]);
                }
                continue;
            },
            else => {},
        };
        for (0..vecLen(node.ty)) |component| {
            switch (node.kind) {
                .lane => try batchGet(a, node.op),
                .swizzle => try batchGet(a, (node.op >> @intCast(2 * component)) & 3),
                .binary => try batchBinary(@enumFromInt(node.op), if (isVec(node.ty)) node.ty else node.opnd_ty, a, b, component),
                .unary => {
                    try batchGet(a, component);
                    try body.simd(switch (@as(Tk, @enumFromInt(node.op))) {
                        .minus => if (node.ty == .f32 or isVec(node.ty)) SIMD_F32X4_NEG else 161,
                        .bang, .tilde => 77,
                        else => return fail(0, .unsupported),
                    });
                },
                .call => switch (@as(Callee, @enumFromInt(node.op))) {
                    .select => {
                        try batchGet(b, component);
                        try batchGet(a, component);
                        try batchGet(t, 0);
                        try body.simd(82); // v128.bitselect
                    },
                    .mix => {
                        try batchGet(a, component);
                        try batchFloat(1);
                        try batchGet(t, component);
                        try body.simd(SIMD_F32X4_SUB);
                        try body.simd(SIMD_F32X4_MUL);
                        try batchGet(b, component);
                        try batchGet(t, component);
                        try body.simd(SIMD_F32X4_MUL);
                        try body.simd(SIMD_F32X4_ADD);
                    },
                    .min, .max, .clamp => |callee| {
                        try batchGet(a, component);
                        try batchGet(b, component);
                        try batchMinMax(node.ty, callee != .min);
                        if (callee == .clamp) {
                            try batchGet(t, component);
                            try batchMinMax(node.ty, false);
                        }
                    },
                    .to_f32, .to_i32, .to_u32, .to_bool => {
                        try batchGet(a, 0);
                        if (node.ty == .bool) {
                            if (a.ty == .f32) try batchFloat(0) else try batchConst(0);
                            try body.simd(if (a.ty == .f32) 66 else 56);
                        } else if (a.ty == .bool) {
                            try batchConst(1);
                            try body.simd(78);
                            if (node.ty == .f32) try body.simd(251);
                        } else if (node.ty != a.ty and (node.ty == .f32 or a.ty == .f32)) {
                            try body.simd(if (node.ty == .f32) (if (a.ty == .i32) @as(u32, 250) else 251) else (if (node.ty == .i32) @as(u32, 248) else 249));
                        }
                    },
                    .abs, .sqrt, .floor, .ceil, .trunc, .round => |callee| {
                        try batchGet(a, component);
                        if (callee == .abs and node.ty == .u32) {} else try body.simd(switch (callee) {
                            .abs => if (node.ty == .i32) 160 else SIMD_F32X4_ABS,
                            .sqrt => SIMD_F32X4_SQRT,
                            .floor => SIMD_F32X4_FLOOR,
                            .ceil => SIMD_F32X4_CEIL,
                            .trunc => SIMD_F32X4_TRUNC,
                            else => SIMD_F32X4_NEAREST,
                        });
                    },
                    .sign => |callee| {
                        try batchGet(a, component);
                        if (node.ty == .i32) try emitSignInt(true) else try emitMath(callee, .vec4f);
                    },
                    .inverse_sqrt, .fract, .sin, .cos, .tan, .asin, .acos, .atan, .atan2, .tanh, .exp, .exp2, .log, .log2, .pow, .step, .smoothstep => |callee| {
                        try batchGet(a, component);
                        if (node.argc > 1) try batchGet(b, component);
                        if (node.argc > 2) try batchGet(t, component);
                        try emitMath(callee, .vec4f);
                    },
                    else => return fail(0, .unsupported),
                },
                else => return fail(0, .unsupported),
            }
            try body.localSet(out.regs[component]);
        }
    }
    return batch_values[expr.len - 1];
}

fn batchAssign(destination: BatchValue, value: BatchValue, masked: bool, lane: u8) CompileError!void {
    if (!destination.varying) {
        try batchUniformGet(value);
        if (lane != 255) {
            // A uniform lane write still uses the existing packed WGSL vector.
            const rhs = try batchTemp(.f32);
            try body.localSet(rhs);
            try body.localGet(destination.regs[0]);
            try body.localGet(rhs);
            try body.simdLane(SIMD_F32X4_REPLACE_LANE, lane);
        }
        return body.localSet(destination.regs[0]);
    }
    for (0..if (lane == 255) vecLen(destination.ty) else 1) |i| {
        const c = if (lane == 255) i else lane;
        try batchGet(value, if (lane == 255) i else 0);
        if (masked) {
            try body.localGet(destination.regs[c]);
            try body.localGet(batch_active);
            try body.simd(82);
        }
        try body.localSet(destination.regs[c]);
    }
}

fn batchStore(value: BatchValue) CompileError!void {
    // Store indices are identities, so four scalar lanes are one contiguous
    // v128 when every lane stores. Otherwise only active lanes are written.
    if (!isVec(value.ty)) {
        try body.localGet(batch_active);
        try body.simd(SIMD_I32X4_ALL_TRUE);
        try body.raw(&.{ 0x04, 0x40 });
        try body.localGet(0);
        try body.i32Const(2);
        try body.byte(0x74);
        try batchGet(value, 0);
        try body.simd(SIMD_STORE);
        try body.byte(2);
        try body.uleb(bufferBase(1));
        try body.byte(0x05);
    }
    for (0..4) |lane| {
        try body.localGet(batch_active);
        try body.simdLane(27, @intCast(lane));
        try body.raw(&.{ 0x04, 0x40 });
        try body.localGet(0);
        try body.i32Const(@intCast(lane));
        try body.byte(0x6a);
        try body.i32Const(elemShift(value.ty));
        try body.byte(0x74);
        if (isVec(value.ty)) {
            try batchConst(0);
            for (0..4) |component| {
                try batchGet(value, component);
                try body.simdLane(SIMD_F32X4_EXTRACT_LANE, @intCast(lane));
                try body.simdLane(SIMD_F32X4_REPLACE_LANE, @intCast(component));
            }
            try body.simd(SIMD_STORE);
        } else {
            try batchGet(value, 0);
            try body.simdLane(if (value.ty == .f32) SIMD_F32X4_EXTRACT_LANE else 27, @intCast(lane));
            try body.byte(if (value.ty == .f32) 0x38 else 0x36);
        }
        try body.byte(elemShift(value.ty));
        try body.uleb(bufferBase(1));
        try body.byte(0x0b);
    }
    if (!isVec(value.ty)) try body.byte(0x0b);
}

fn emitInvocationBatch() CompileError!bool {
    analyzeBatchUniformity();
    analyzeBatchIdentities();
    body.len = 0;
    local_count = 0;
    batch_temp_len = .{ 0, 0, 0 };
    batch_temp_used = .{ 0, 0, 0 };
    batch_temps = false;
    batch_active = try allocPersistent(.vec4f);
    batch_alive = try allocPersistent(.vec4f);
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (stmt.kind == .declare) batch_locals[stmt.local] = try batchValue(stmt.ty, batch_varying[stmt.local], true);
    }
    const Mask = struct { parent: u32, condition: u32, guarded: bool, divergent: bool };
    var masks: [MAX_BLOCKS]Mask = undefined;
    var depth: usize = 0;
    try emitBatchSplats();
    batch_temps = true;
    defer batch_temps = false;
    // Only existing invocations are alive, including the final partial batch.
    try body.localGet(0);
    try body.simd(17);
    try body.simd(SIMD_CONST);
    try body.raw(&.{ 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 });
    try body.simd(174);
    try body.byte(0x23);
    try body.uleb(GLOBAL_COUNT);
    try body.simd(17);
    try body.simd(58); // i32x4.lt_u
    try body.localTee(batch_alive);
    try body.localSet(batch_active);
    for (ir_stmts[0..ir_stmt_len], 0..) |stmt, stmt_index| {
        batch_temp_used = .{ 0, 0, 0 };
        switch (stmt.kind) {
            .declare, .assign => {
                const value = try batchExpr(stmt.expr);
                var result = value;
                const dest = batch_locals[stmt.local];
                if (stmt.op != .eq) {
                    var a = dest;
                    const ty: Ty = if (stmt.lane == 255) dest.ty else .f32;
                    if (stmt.lane != 255) {
                        a.ty = .f32;
                        if (a.varying) a.regs[0] = dest.regs[stmt.lane] else {
                            const reg = try batchTemp(.f32);
                            try body.localGet(dest.regs[0]);
                            try body.simdLane(SIMD_F32X4_EXTRACT_LANE, stmt.lane);
                            try body.localSet(reg);
                            a.regs[0] = reg;
                        }
                    }
                    result = try batchValue(ty, dest.varying, false);
                    if (dest.varying) {
                        for (0..vecLen(ty)) |component| {
                            try batchBinary(stmt.op, ty, a, value, component);
                            try body.localSet(result.regs[component]);
                        }
                    } else {
                        try body.localGet(a.regs[0]);
                        try batchUniformGet(value);
                        if (isVec(ty)) try emitVecArith(stmt.op, a.ty, value.ty) else try emitArith(stmt.op, ty);
                        try body.localSet(result.regs[0]);
                    }
                }
                // Only divergent control needs to preserve other live lanes.
                // Unconditional writes to dead/tail lanes cannot reach stores.
                try batchAssign(dest, result, stmt.kind == .assign and depth > 0 and masks[depth - 1].divergent, stmt.lane);
            },
            .store => try batchStore(try batchExpr(stmt.expr)),
            .if_head => {
                const condition = try batchExpr(stmt.expr);
                // A tiny divergent assignment is already protected by its
                // lane mask. Avoid a horizontal mask test and CPU branch.
                // Keep uniform branches and larger bodies guarded so inactive
                // octaves, gathers and other expensive work are skipped.
                var guarded = true;
                if (condition.varying and stmt_index + 2 < ir_stmt_len) {
                    const next = ir_stmts[stmt_index + 1];
                    if (next.kind == .assign and next.expr.len <= 8 and ir_stmts[stmt_index + 2].kind == .end_if) {
                        guarded = false;
                        for (ir_nodes[next.expr.start..][0..next.expr.len]) |node| {
                            if (node.kind == .load) guarded = true;
                        }
                    }
                }
                const mask = Mask{ .parent = try allocPersistent(.vec4f), .condition = try allocPersistent(.vec4f), .guarded = guarded, .divergent = condition.varying or (depth > 0 and masks[depth - 1].divergent) };
                masks[depth] = mask;
                depth += 1;
                try body.localGet(batch_active);
                try body.localTee(mask.parent);
                try batchGet(condition, 0);
                try body.localTee(mask.condition);
                try body.simd(78);
                try body.localTee(batch_active);
                if (guarded) {
                    try body.simd(83);
                    try body.raw(&.{ 0x04, 0x40 });
                } else try body.byte(0x1a);
            },
            .else_head => {
                const mask = masks[depth - 1];
                try body.byte(0x0b);
                try body.localGet(mask.parent);
                try body.localGet(mask.condition);
                try body.simd(79); // parent & ~condition
                try body.localGet(batch_alive);
                try body.simd(78);
                try body.localTee(batch_active);
                try body.simd(83);
                try body.raw(&.{ 0x04, 0x40 });
            },
            .end_if => {
                depth -= 1;
                if (masks[depth].guarded) try body.byte(0x0b);
                try body.localGet(masks[depth].parent);
                try body.localGet(batch_alive);
                try body.simd(78);
                try body.localSet(batch_active);
            },
            .ret => {
                try body.localGet(batch_alive);
                try body.localGet(batch_active);
                try body.simd(79);
                try body.localTee(batch_alive);
                try body.simd(83);
                try body.raw(&.{ 0x45, 0x04, 0x40, 0x0f, 0x0b });
                try batchConst(0);
                try body.localSet(batch_active);
            },
            .discard => _ = try batchExpr(stmt.expr),
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Byte vectorization: four invocations of a shader that maps each byte of a
// u32 element independently, as one i8x16. It applies when every vec4u value
// comes from `unpack4xU8(src[id.x])`, literals, and lane-wise operators, and
// every store is `dst[id.x] = pack4xU8(...)`, so output byte c of an element
// depends only on input byte c. Lanes then need only 8 bits if the result
// agrees: the compiler evaluates the shader in u32 and in u8 arithmetic for
// all 256 values of each input byte and keeps this path only if every stored
// byte matches. Bounds guards such as `if (i < arrayLength(&src))` hold for
// every live invocation. Anything else keeps the other paths.

const ByteClass = enum(u8) { other, index, alen, word, bytes, mask, cbytes, cscalar, known_true, known_false, packed_word };
var byte_class: [MAX_NODES]ByteClass = undefined;
var byte_const: [MAX_NODES][4]u32 = undefined;
var byte_local_class: [MAX_LOCALS + 1]ByteClass = undefined;
var byte_local_const: [MAX_LOCALS + 1][4]u32 = undefined;
var byte_local_reg: [MAX_LOCALS + 1]u32 = undefined;
var byte_v32: [MAX_NODES]u32 = undefined;
var byte_v8: [MAX_NODES]u8 = undefined;
var byte_local_v32: [MAX_LOCALS + 1]u32 = undefined;
var byte_local_v8: [MAX_LOCALS + 1]u8 = undefined;

fn byteDomain(class: ByteClass) bool {
    return class == .bytes or class == .cbytes or class == .cscalar;
}

fn splatConst(values: [4]u32) bool {
    return values[0] == values[1] and values[1] == values[2] and values[2] == values[3];
}

// Classifies each node of `expr` into byte_class; `.other` marks a node
// outside the byte subset.
fn classifyByteExpr(expr: Expr) void {
    if (expr.len == 0) return;
    const expr_nodes = ir_nodes[expr.start..][0..expr.len];
    for (expr_nodes, 0..) |node, i| {
        const k = node.kids;
        const ka = if (nodeArity(node) > 0) byte_class[k[0]] else ByteClass.other;
        const kb = if (nodeArity(node) > 1) byte_class[k[1]] else ByteClass.other;
        var class = ByteClass.other;
        byte_const[i] = .{ 0, 0, 0, 0 };
        switch (node.kind) {
            .lit => if (isInt(node.ty)) {
                class = .cscalar;
                byte_const[i] = @splat(@bitCast(literalValue(node.lit)));
            } else if (node.ty == .vec4u) {
                class = .cbytes; // the zero vector
            },
            .local => {
                class = byte_local_class[node.ref];
                byte_const[i] = byte_local_const[node.ref];
            },
            .gid_x => class = .index,
            .array_len => class = .alen,
            .load => if (node.op == 0 and node.ty == .u32 and ka == .index) {
                class = .word;
            },
            .unary => {
                const op: Tk = @enumFromInt(node.op);
                if (op == .tilde and node.ty == .vec4u and byteDomain(ka)) class = .bytes;
                if (op == .bang and ka == .mask) class = .mask;
            },
            .binary => {
                const op: Tk = @enumFromInt(node.op);
                const both = byteDomain(ka) and byteDomain(kb);
                if (node.ty == .vec4u and both) switch (op) {
                    .plus, .minus, .amp, .pipe, .caret => class = .bytes,
                    // i8x16 shifts take one count for every lane.
                    .shl, .shr => if (kb == .cbytes and splatConst(byte_const[k[1]])) {
                        class = .bytes;
                    },
                    else => {},
                } else if (node.ty == .vec4b and node.opnd_ty == .vec4u and both) {
                    class = .mask;
                } else if (node.ty == .vec4b and ka == .mask and kb == .mask) {
                    class = .mask;
                } else if (node.ty == .bool) {
                    // Every live invocation has id.x < arrayLength.
                    const index_first = ka == .index and kb == .alen;
                    const alen_first = ka == .alen and kb == .index;
                    if ((index_first and op == .lt) or (alen_first and op == .gt) or
                        (index_first and op == .bang_eq) or (alen_first and op == .bang_eq)) class = .known_true;
                    if ((index_first and op == .ge) or (alen_first and op == .le) or
                        (index_first and op == .eq_eq) or (alen_first and op == .eq_eq)) class = .known_false;
                }
            },
            .call => switch (@as(Callee, @enumFromInt(node.op))) {
                .unpack4xU8 => if (ka == .word) {
                    class = .bytes;
                },
                .pack4xU8 => if (byteDomain(ka)) {
                    class = .packed_word;
                },
                .vec4u => if (node.argc == 1 and ka == .cscalar) {
                    class = .cbytes;
                    byte_const[i] = byte_const[k[0]];
                } else if (node.argc == 1 and (ka == .bytes or ka == .cbytes)) {
                    class = ka;
                    byte_const[i] = byte_const[k[0]];
                } else if (node.argc == 4) {
                    class = .cbytes;
                    for (0..4) |c| {
                        if (byte_class[k[c]] != .cscalar) class = .other;
                        byte_const[i][c] = byte_const[k[c]][0];
                    }
                },
                .select => if (node.ty == .vec4u and byteDomain(ka) and byteDomain(kb) and byte_class[k[2]] == .mask) {
                    class = .bytes;
                },
                .min, .max => if (node.ty == .vec4u and byteDomain(ka) and byteDomain(kb)) {
                    class = .bytes;
                },
                .clamp => if (node.ty == .vec4u and byteDomain(ka) and byteDomain(kb) and byteDomain(byte_class[k[2]])) {
                    class = .bytes;
                },
                else => {},
            },
            else => {},
        }
        byte_class[i] = class;
    }
}

// Scans the statements once for eligibility, recording each local's class.
fn byteKernelEligible() bool {
    if (input_buffer.elem != .u32 or output_buffer.elem != .u32) return false;
    for (ir_nodes[0..ir_node_len]) |node| if (node.kind == .override) return false;
    var skip_depth: usize = 0;
    var depth: usize = 0;
    var stores: usize = 0;
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (skip_depth > 0) {
            if (stmt.kind == .if_head) skip_depth += 1;
            if (stmt.kind == .else_head and skip_depth == 1) return false;
            if (stmt.kind == .end_if) skip_depth -= 1;
            continue;
        }
        classifyByteExpr(stmt.expr);
        const root = if (stmt.expr.len > 0) byte_class[stmt.expr.len - 1] else ByteClass.other;
        switch (stmt.kind) {
            .declare => {
                switch (root) {
                    .index, .word, .bytes, .mask, .cbytes, .cscalar => {},
                    else => return false,
                }
                byte_local_class[stmt.local] = root;
                byte_local_const[stmt.local] = byte_const[stmt.expr.len - 1];
            },
            .store => {
                if (root != .packed_word) return false;
                stores += 1;
            },
            .if_head => switch (root) {
                .known_true => depth += 1,
                // The body never runs, so it needs no other checks.
                .known_false => skip_depth = 1,
                else => return false,
            },
            .end_if => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => return false,
        }
    }
    // Every store indexes with id.x itself.
    analyzeBatchIdentities();
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (stmt.kind != .store) continue;
        if (stmt.index_expr.len != 1 or !isIdentityIndex(ir_nodes[stmt.index_expr.start])) return false;
    }
    return stores > 0;
}

// Evaluates the classified nodes of `expr` for one input byte and lane, in
// u32 (WGSL) and in u8 (the i8x16 lowering) arithmetic.
fn evalByteExpr(expr: Expr, lane: usize, byte: u8) void {
    const expr_nodes = ir_nodes[expr.start..][0..expr.len];
    for (expr_nodes, 0..) |node, i| {
        if (!byteDomain(byte_class[i]) and byte_class[i] != .mask and byte_class[i] != .packed_word) continue;
        const k = node.kids;
        if (node.kind == .local) {
            byte_v32[i] = byte_local_v32[node.ref];
            byte_v8[i] = byte_local_v8[node.ref];
            if (byte_class[i] == .cbytes) {
                byte_v32[i] = byte_const[i][lane];
                byte_v8[i] = @truncate(byte_const[i][lane]);
            }
            continue;
        }
        if (byte_class[i] == .cbytes or byte_class[i] == .cscalar) {
            byte_v32[i] = byte_const[i][lane];
            byte_v8[i] = @truncate(byte_const[i][lane]);
            continue;
        }
        const a32 = byte_v32[k[0]];
        const b32 = byte_v32[k[1]];
        const a8 = byte_v8[k[0]];
        const b8 = byte_v8[k[1]];
        var r32: u32 = 0;
        var r8: u8 = 0;
        switch (node.kind) {
            .unary => {
                r32 = if (node.ty == .vec4b) @intFromBool(a32 == 0) else ~a32;
                r8 = if (node.ty == .vec4b) @intFromBool(a8 == 0) else ~a8;
            },
            .binary => {
                const op: Tk = @enumFromInt(node.op);
                if (node.ty == .vec4b) {
                    r32 = @intFromBool(switch (op) {
                        .amp => a32 != 0 and b32 != 0,
                        .pipe => a32 != 0 or b32 != 0,
                        .eq_eq => a32 == b32,
                        .bang_eq => a32 != b32,
                        .lt => a32 < b32,
                        .gt => a32 > b32,
                        .le => a32 <= b32,
                        else => a32 >= b32,
                    });
                    r8 = @intFromBool(switch (op) {
                        .amp => a8 != 0 and b8 != 0,
                        .pipe => a8 != 0 or b8 != 0,
                        .eq_eq => a8 == b8,
                        .bang_eq => a8 != b8,
                        .lt => a8 < b8,
                        .gt => a8 > b8,
                        .le => a8 <= b8,
                        else => a8 >= b8,
                    });
                } else switch (op) {
                    .plus => {
                        r32 = a32 +% b32;
                        r8 = a8 +% b8;
                    },
                    .minus => {
                        r32 = a32 -% b32;
                        r8 = a8 -% b8;
                    },
                    .amp => {
                        r32 = a32 & b32;
                        r8 = a8 & b8;
                    },
                    .pipe => {
                        r32 = a32 | b32;
                        r8 = a8 | b8;
                    },
                    .caret => {
                        r32 = a32 ^ b32;
                        r8 = a8 ^ b8;
                    },
                    // WGSL and Wasm shift by the count modulo the lane width.
                    .shl => {
                        r32 = a32 << @intCast(b32 & 31);
                        r8 = a8 << @intCast(b32 & 7);
                    },
                    else => {
                        r32 = a32 >> @intCast(b32 & 31);
                        r8 = a8 >> @intCast(b32 & 7);
                    },
                }
            },
            .call => switch (@as(Callee, @enumFromInt(node.op))) {
                .unpack4xU8 => {
                    r32 = byte;
                    r8 = byte;
                },
                .pack4xU8, .vec4u => {
                    r32 = a32;
                    r8 = a8;
                },
                .select => {
                    const pick = byte_v32[k[2]] != 0;
                    // The lowering selects with the u8 mask.
                    r32 = if (pick) b32 else a32;
                    r8 = if (byte_v8[k[2]] != 0) b8 else a8;
                },
                .min => {
                    r32 = @min(a32, b32);
                    r8 = @min(a8, b8);
                },
                .max => {
                    r32 = @max(a32, b32);
                    r8 = @max(a8, b8);
                },
                else => { // clamp(e, low, high) = min(max(e, low), high)
                    r32 = @min(@max(a32, b32), byte_v32[k[2]]);
                    r8 = @min(@max(a8, b8), byte_v8[k[2]]);
                },
            },
            else => unreachable,
        }
        byte_v32[i] = r32;
        byte_v8[i] = r8;
    }
}

// True when the u8 lowering stores the low byte of the u32 result for every
// input byte value in every lane.
fn byteLoweringExact() bool {
    for (0..4) |lane| for (0..256) |b| {
        var skip_depth: usize = 0;
        for (ir_stmts[0..ir_stmt_len]) |stmt| {
            if (skip_depth > 0) {
                if (stmt.kind == .if_head) skip_depth += 1;
                if (stmt.kind == .end_if) skip_depth -= 1;
                continue;
            }
            if (stmt.kind == .if_head) {
                classifyByteExpr(stmt.expr);
                if (byte_class[stmt.expr.len - 1] == .known_false) skip_depth = 1;
                continue;
            }
            if (stmt.kind != .declare and stmt.kind != .store) continue;
            classifyByteExpr(stmt.expr);
            evalByteExpr(stmt.expr, lane, @intCast(b));
            const root = stmt.expr.len - 1;
            if (stmt.kind == .declare) {
                byte_local_v32[stmt.local] = byte_v32[root];
                byte_local_v8[stmt.local] = byte_v8[root];
            } else if (@as(u8, @truncate(byte_v32[root])) != byte_v8[root]) {
                return false;
            }
        }
    };
    return true;
}

// Byte constants live in locals set before the loop.
const ByteConst = struct { bytes: [4]u8, reg: u32 };
var byte_consts: [32]ByteConst = undefined;
var byte_const_len: usize = 0;

fn emitByteConst(values: [4]u32) CompileError!void {
    var bytes: [4]u8 = undefined;
    for (&bytes, values) |*b, v| b.* = @truncate(v);
    for (byte_consts[0..byte_const_len]) |c| {
        if (std.mem.eql(u8, &c.bytes, &bytes)) return body.localGet(c.reg);
    }
    if (byte_const_len < byte_consts.len) {
        const reg = try allocPersistent(.vec4u);
        byte_consts[byte_const_len] = .{ .bytes = bytes, .reg = reg };
        byte_const_len += 1;
        return body.localGet(reg);
    }
    try body.simd(SIMD_CONST);
    for (0..4) |_| try body.raw(&bytes);
}

// Emits node `i` of `expr_nodes` as an i8x16, from its operands down.
fn emitByteNode(expr_nodes: []const Node, i: usize, source: u32) CompileError!void {
    const node = expr_nodes[i];
    const k = node.kids;
    switch (byte_class[i]) {
        .cbytes, .cscalar => return emitByteConst(byte_const[i]),
        else => {},
    }
    if (node.kind == .local) return body.localGet(byte_local_reg[node.ref]);
    switch (node.kind) {
        .unary => {
            try emitByteNode(expr_nodes, k[0], source);
            try body.simd(77); // v128.not
        },
        .binary => {
            const op: Tk = @enumFromInt(node.op);
            try emitByteNode(expr_nodes, k[0], source);
            if (op == .shl or op == .shr) {
                try body.i32Const(@bitCast(byte_const[k[1]][0]));
                return body.simd(if (op == .shl) @as(u32, 107) else 109); // i8x16.shl, shr_u
            }
            try emitByteNode(expr_nodes, k[1], source);
            try body.simd(if (node.ty == .vec4b and node.opnd_ty == .vec4u) switch (op) {
                .eq_eq => @as(u32, 35),
                .bang_eq => 36,
                .lt => 38,
                .gt => 40,
                .le => 42,
                else => 44,
            } else switch (op) {
                .plus => @as(u32, 110), // i8x16.add
                .minus => 113, // i8x16.sub
                .amp => SIMD_V128_AND,
                .pipe => SIMD_V128_OR,
                else => SIMD_V128_XOR,
            });
        },
        .call => switch (@as(Callee, @enumFromInt(node.op))) {
            .unpack4xU8 => try body.localGet(source),
            .pack4xU8, .vec4u => try emitByteNode(expr_nodes, k[0], source),
            .select => {
                try emitByteNode(expr_nodes, k[1], source);
                try emitByteNode(expr_nodes, k[0], source);
                try emitByteNode(expr_nodes, k[2], source);
                try body.simd(SIMD_V128_BITSELECT);
            },
            .min, .max => |callee| {
                try emitByteNode(expr_nodes, k[0], source);
                try emitByteNode(expr_nodes, k[1], source);
                try body.simd(if (callee == .min) @as(u32, 119) else 121); // i8x16.min_u, max_u
            },
            else => {
                try emitByteNode(expr_nodes, k[0], source);
                try emitByteNode(expr_nodes, k[1], source);
                try body.simd(121);
                try emitByteNode(expr_nodes, k[2], source);
                try body.simd(119);
            },
        },
        else => return fail(node.offset, .unsupported),
    }
}

// Emits one batch at id.x (local 0): elements id.x .. id.x + 3. A `tail`
// batch stores only the elements below the count; the read stays inside the
// input capacity, a multiple of 16 bytes.
fn emitByteBody(source: u32, value: u32, tail: bool) CompileError!void {
    try body.localGet(0);
    try body.i32Const(2);
    try body.byte(0x74);
    try body.simd(SIMD_LOAD);
    try body.byte(2);
    try body.uleb(bufferBase(0));
    try body.localSet(source);
    var skip_depth: usize = 0;
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (skip_depth > 0) {
            if (stmt.kind == .if_head) skip_depth += 1;
            if (stmt.kind == .end_if) skip_depth -= 1;
            continue;
        }
        if (stmt.kind != .declare and stmt.kind != .store and stmt.kind != .if_head) continue;
        classifyByteExpr(stmt.expr);
        const root = stmt.expr.len - 1;
        const expr_nodes = ir_nodes[stmt.expr.start..][0..stmt.expr.len];
        switch (stmt.kind) {
            .if_head => if (byte_class[root] == .known_false) {
                skip_depth = 1;
            },
            .declare => if (byte_class[root] == .bytes or byte_class[root] == .mask) {
                try emitByteNode(expr_nodes, root, source);
                try body.localSet(byte_local_reg[stmt.local]);
            },
            else => if (!tail) {
                try body.localGet(0);
                try body.i32Const(2);
                try body.byte(0x74);
                try emitByteNode(expr_nodes, root, source);
                try body.simd(SIMD_STORE);
                try body.byte(2);
                try body.uleb(bufferBase(1));
            } else {
                try emitByteNode(expr_nodes, root, source);
                try body.localSet(value);
                for (0..3) |lane| {
                    try body.localGet(0);
                    try body.i32Const(@intCast(lane));
                    try body.byte(0x6a);
                    try body.byte(0x23);
                    try body.uleb(GLOBAL_COUNT);
                    try body.raw(&.{ 0x49, 0x04, 0x40 }); // i32.lt_u if
                    try body.localGet(0);
                    try body.i32Const(@intCast(lane));
                    try body.byte(0x6a);
                    try body.i32Const(2);
                    try body.byte(0x74);
                    try body.localGet(value);
                    try body.simdLane(SIMD_I32X4_EXTRACT_LANE, @intCast(lane));
                    try body.raw(&.{ 0x36, 2 });
                    try body.uleb(bufferBase(1));
                    try body.byte(0x0b);
                }
            },
        }
    }
}

fn emitByteBatch() CompileError!bool {
    if (!byteKernelEligible() or !byteLoweringExact()) return false;
    body.len = 0;
    local_count = 0;
    const source = try allocPersistent(.vec4u);
    const value = try allocPersistent(.vec4u);
    const full = try allocPersistent(.u32);
    for (ir_stmts[0..ir_stmt_len]) |stmt| {
        if (stmt.kind == .declare) byte_local_reg[stmt.local] = try allocPersistent(.vec4u);
    }
    // A first pass finds the constants; the code starts again after it.
    byte_const_len = 0;
    try emitByteBody(source, value, false);
    body.len = 0;
    for (byte_consts[0..byte_const_len]) |c| {
        try body.simd(SIMD_CONST);
        for (0..4) |_| try body.raw(&c.bytes);
        try body.localSet(c.reg);
    }
    // for (id.x = 0; id.x < count & ~3; id.x += 4): render calls this once.
    try body.byte(0x23);
    try body.uleb(GLOBAL_COUNT);
    try body.i32Const(-4);
    try body.byte(0x71);
    try body.localSet(full);
    try body.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try body.localGet(0);
    try body.localGet(full);
    try body.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
    try emitByteBody(source, value, false);
    try body.localGet(0);
    try body.i32Const(4);
    try body.byte(0x6a);
    try body.localSet(0);
    try body.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    // One to three remaining elements.
    try body.localGet(0);
    try body.byte(0x23);
    try body.uleb(GLOBAL_COUNT);
    try body.raw(&.{ 0x49, 0x04, 0x40 }); // i32.lt_u if
    try emitByteBody(source, value, true);
    try body.byte(0x0b);
    return true;
}

const OpKind = enum(u8) { paren, call, user_call, bracket, unary, binary };

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
        .bang => at == .bool or at == .vec4b,
        .tilde => isInt(at) or at == .vec4u,
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
    if (at == .vec4b or bt == .vec4b) {
        // `&` and `|` lane-wise on comparison results.
        if (at != bt or !(kind == .amp or kind == .pipe)) return fail(entry.offset, .type_mismatch);
        _ = try pushNode(.{ .kind = .binary, .op = entry.op, .ty = at, .opnd_ty = at, .kids = .{ a, b, 0, 0 }, .offset = entry.offset });
        return;
    }
    if (isIVec(at) or isIVec(bt)) {
        // `+ - *` lane-wise on vec2i, vec2u or vec4u, with a scalar
        // splatted; on two vec4u also `& | ^`, shifts and comparisons.
        const arith = kind == .plus or kind == .minus or kind == .star;
        const vt = if (isIVec(at)) at else bt;
        const elem = ivecElem(vt);
        const lanes_ok = (at == vt or convertible(at, elem)) and (bt == vt or convertible(bt, elem));
        ty = vt;
        if (vt == .vec4u and !arith) {
            switch (kind) {
                .amp, .pipe, .caret => if (at != vt or bt != vt) return fail(entry.offset, .type_mismatch),
                .shl, .shr => {
                    if (at != vt or bt != vt) return fail(entry.offset, .type_mismatch);
                    try checkShiftCount(b, entry.offset);
                },
                .lt, .gt, .le, .ge, .eq_eq, .bang_eq => {
                    if (at != vt or bt != vt) return fail(entry.offset, .type_mismatch);
                    ty = .vec4b;
                },
                .slash, .percent => return fail(entry.offset, .unsupported),
                else => return fail(entry.offset, .type_mismatch),
            }
        } else {
            if (!arith) return fail(entry.offset, if (kind == .slash or kind == .percent) .unsupported else .type_mismatch);
            if (!lanes_ok) return fail(entry.offset, .type_mismatch);
        }
        _ = try pushNode(.{ .kind = .binary, .op = entry.op, .ty = ty, .opnd_ty = vt, .kids = .{ a, b, 0, 0 }, .offset = entry.offset });
        return;
    }
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
            try checkShiftCount(b, entry.offset);
            opnd = at;
            ty = at;
        },
        else => return fail(entry.offset, .syntax),
    }
    _ = try pushNode(.{ .kind = .binary, .op = entry.op, .ty = ty, .opnd_ty = opnd, .kids = .{ a, b, 0, 0 }, .offset = entry.offset });
}

// The largest lane of a constant integer expression, or null if any lane is
// not known at compile time.
fn constIntMax(index: u16) ?f64 {
    const node = nodes[index];
    if (node.kind == .call) switch (@as(Callee, @enumFromInt(node.op))) {
        .to_u32, .to_i32, .vec2i, .vec2u, .vec4u => {
            var max: ?f64 = null;
            for (node.kids[0..node.argc]) |kid| {
                const value = constIntMax(kid) orelse return null;
                max = if (max) |m| @max(m, value) else value;
            }
            return max;
        },
        else => {},
    };
    const value = constFloat(index) orelse return null;
    var max = value.values[0];
    for (value.values[1..value.len]) |lane| max = @max(max, lane);
    return max;
}

// WGSL makes a constant shift count of 32 or more a shader-creation error.
fn checkShiftCount(count: u16, offset: u32) CompileError!void {
    if (constIntMax(count)) |max| {
        if (max >= 32) return fail(offset, .type_mismatch);
    }
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
        if (kind == .paren or kind == .call or kind == .user_call or kind == .bracket) return i;
    }
    return null;
}

// Applies every operator above the innermost open paren, call or bracket.
fn reduceToOpen() CompileError!void {
    try reduceWhile(0);
}

fn lookupCallee(name: []const u8) ?Callee {
    const table = [_]struct { []const u8, Callee }{
        .{ "abs", .abs },               .{ "min", .min },                  .{ "max", .max },       .{ "clamp", .clamp },
        .{ "select", .select },         .{ "sqrt", .sqrt },                .{ "floor", .floor },   .{ "ceil", .ceil },
        .{ "trunc", .trunc },           .{ "round", .round },              .{ "dot", .dot },       .{ "mix", .mix },
        .{ "fract", .fract },           .{ "sin", .sin },                  .{ "cos", .cos },       .{ "exp", .exp },
        .{ "exp2", .exp2 },             .{ "log", .log },                  .{ "log2", .log2 },     .{ "pow", .pow },
        .{ "sign", .sign },             .{ "tan", .tan },                  .{ "asin", .asin },     .{ "acos", .acos },
        .{ "atan", .atan },             .{ "atan2", .atan2 },              .{ "tanh", .tanh },     .{ "step", .step },
        .{ "smoothstep", .smoothstep }, .{ "inverseSqrt", .inverse_sqrt }, .{ "length", .length }, .{ "distance", .distance },
        .{ "normalize", .normalize },   .{ "f32", .to_f32 },               .{ "i32", .to_i32 },    .{ "u32", .to_u32 },
        .{ "bool", .to_bool },          .{ "vec2f", .vec2f },              .{ "vec3f", .vec3f },   .{ "vec4f", .vec4f },
        .{ "vec2i", .vec2i },           .{ "vec2u", .vec2u },              .{ "vec4u", .vec4u },   .{ "unpack4xU8", .unpack4xU8 },
        .{ "pack4xU8", .pack4xU8 },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    // Chrome on Metal computes every form per row and column of the quad, so
    // the coarse forms are the fine ones, which WGSL permits.
    const derivs = [_]struct { []const u8, Callee }{
        .{ "dpdx", .dpdx },     .{ "dpdxFine", .dpdx },     .{ "dpdxCoarse", .dpdx },
        .{ "dpdy", .dpdy },     .{ "dpdyFine", .dpdy },     .{ "dpdyCoarse", .dpdy },
        .{ "fwidth", .fwidth }, .{ "fwidthFine", .fwidth }, .{ "fwidthCoarse", .fwidth },
    };
    for (derivs) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
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
        .vec2i => .vec2i,
        .vec2u => .vec2u,
        .vec4u => .vec4u,
        else => null,
    };
}

fn applyCall(entry: OpEntry, argc: u8) CompileError!void {
    const callee: Callee = @enumFromInt(entry.op);
    const want: u8 = switch (callee) {
        .min, .max, .dot, .pow, .atan2, .step, .distance => 2,
        .clamp, .select, .mix, .smoothstep => 3,
        .vec2f, .vec3f, .vec4f, .vec2i, .vec2u, .vec4u => @min(argc, vecLen(conversionTarget(callee).?)),
        .texture_load => 2,
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
        .abs, .sign => {
            if (!isNumeric(t0) and !isVec(t0)) return fail(entry.offset, .type_mismatch);
            if (callee == .sign and t0 == .u32) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = t0;
        },
        .min, .max, .clamp => {
            opnd = try unify(t0, nodes[kids[1]].ty, entry.offset);
            if (callee == .clamp) opnd = try unify(opnd, nodes[kids[2]].ty, entry.offset);
            if (!isNumeric(opnd) and !isVec(opnd) and opnd != .vec4u) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .select => {
            // A vec4u selects per lane with a vec4<bool>, or whole with a bool.
            opnd = try unify(t0, nodes[kids[1]].ty, entry.offset);
            const ct = nodes[kids[2]].ty;
            const cond_ok = ct == .bool or (opnd == .vec4u and ct == .vec4b);
            if (!(isScalar(opnd) or isVec(opnd) or opnd == .vec4u) or !cond_ok) return fail(entry.offset, .type_mismatch);
            ty = opnd;
        },
        .unpack4xU8 => {
            if (!convertible(t0, .u32)) return fail(entry.offset, .type_mismatch);
            opnd = .u32;
            ty = .vec4u;
        },
        .pack4xU8 => {
            if (t0 != .vec4u) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = .u32;
        },
        .dpdx, .dpdy, .fwidth => {
            // Derivatives exist only in fragment shaders.
            if (!uses_derivatives) return fail(entry.offset, .unsupported);
            ty = if (isVec(t0)) t0 else .f32;
            if (!(t0 == .f32 or isVec(t0) or isAbstract(t0))) return fail(entry.offset, .type_mismatch);
            opnd = ty;
        },
        .sqrt, .inverse_sqrt, .floor, .ceil, .trunc, .round, .fract, .sin, .cos, .tan, .asin, .acos, .atan, .tanh, .exp, .exp2, .log, .log2 => {
            ty = if (isVec(t0)) t0 else .f32;
            if (!(t0 == .f32 or isVec(t0) or isAbstract(t0))) return fail(entry.offset, .type_mismatch);
            opnd = ty;
        },
        .pow, .atan2, .step, .smoothstep => {
            opnd = try unify(t0, nodes[kids[1]].ty, entry.offset);
            if (callee == .smoothstep) opnd = try unify(opnd, nodes[kids[2]].ty, entry.offset);
            if (!isVec(opnd)) opnd = if (convertible(opnd, .f32)) .f32 else return fail(entry.offset, .type_mismatch);
            if (callee == .smoothstep) {
                if (constFloat(kids[0])) |low| {
                    if (constFloat(kids[1])) |high| {
                        for (0..low.len) |lane| {
                            const low_f32: f32 = @floatCast(low.values[lane]);
                            const high_f32: f32 = @floatCast(high.values[lane]);
                            if (low_f32 == high_f32) return fail(entry.offset, .type_mismatch);
                        }
                    }
                }
            }
            ty = opnd;
        },
        .length, .distance, .normalize => {
            // length(e) and distance(a, b) of an f32 or vector are an f32;
            // normalize(v) takes a vector only.
            opnd = if (callee == .distance) try unify(t0, nodes[kids[1]].ty, entry.offset) else t0;
            if (!isVec(opnd)) opnd = if (callee != .normalize and convertible(opnd, .f32)) .f32 else return fail(entry.offset, .type_mismatch);
            ty = if (callee == .normalize) opnd else .f32;
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
            opnd = t0;
            // vec2f(v) converts a vec2i or vec2u lane-wise, vec4f(v) a vec4u.
            if (argc == 1 and isIVec(t0)) {
                if (vecLen(ty) != vecLen(t0)) return fail(entry.offset, .type_mismatch);
                _ = try pushNode(.{ .kind = .call, .op = entry.op, .ty = ty, .opnd_ty = opnd, .kids = kids, .argc = argc, .offset = entry.offset });
                return;
            }
            var lanes: u8 = 0;
            for (kids[0..argc]) |kid| {
                const kt = nodes[kid].ty;
                if (!(convertible(kt, .f32) or isVec(kt))) return fail(nodes[kid].offset, .type_mismatch);
                lanes += vecLen(kt);
            }
            const ok = if (argc == 1) (t0 == ty or !isVec(t0)) else lanes == vecLen(ty);
            if (!ok) return fail(entry.offset, .type_mismatch);
        },
        .vec2i, .vec2u, .vec4u => {
            // vec2i(s) splats, vec2i(a, b) takes two scalars of the element
            // type, and vec2i(v) converts any vec2; vec4u likewise with four.
            ty = conversionTarget(callee).?;
            opnd = t0;
            const elem = ivecElem(ty);
            var ok = if (argc == 1)
                ((t0 == .vec2f or t0 == .vec4f or isIVec(t0)) and vecLen(t0) == vecLen(ty)) or convertible(t0, elem)
            else
                true;
            if (argc > 1) for (kids[0..argc]) |kid| {
                ok = ok and convertible(nodes[kid].ty, elem);
            };
            if (!ok) return fail(entry.offset, .type_mismatch);
        },
        .texture_load => {
            // textureLoad(t, coords, level) after the texture argument.
            if (!isIVec(t0) or vecLen(t0) != 2 or !isInt(nodes[kids[1]].ty)) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = .vec4f;
        },
        .to_f32, .to_i32, .to_u32, .to_bool => {
            if (!isScalar(t0)) return fail(entry.offset, .type_mismatch);
            opnd = t0;
            ty = conversionTarget(callee).?;
        },
    }
    _ = try pushNode(.{ .kind = .call, .op = entry.op, .ty = ty, .opnd_ty = opnd, .kids = kids, .argc = argc, .offset = entry.offset });
}

// A call of helper `entry.op`. Each argument takes its parameter's type now,
// so the call node needs no record of its arguments: in postfix order they
// are already on the Wasm stack.
fn applyUserCall(entry: OpEntry, argc: u8) CompileError!void {
    const h = helpers[entry.op];
    if (argc != h.param_count or val_len < argc) return fail(entry.offset, .type_mismatch);
    if (h.ret == .void and !allow_void_call) return fail(entry.offset, .type_mismatch);
    var i: usize = argc;
    while (i > 0) {
        i -= 1;
        try setNodeTy(popVal(), h.params[i]);
    }
    _ = try pushNode(.{ .kind = .user_call, .op = entry.op, .ty = h.ret, .argc = argc, .offset = entry.offset });
}

fn applyLoad(entry: OpEntry) CompileError!void {
    if (val_len < 1) return fail(entry.offset, .syntax);
    const index = popVal();
    const it = nodes[index].ty;
    if (!isInt(it)) return fail(nodes[index].offset, .type_mismatch);
    if (entry.op >= 2) {
        // Bracket ops 2 and up index constant array op - 2.
        const array = const_arrays[entry.op - 2];
        _ = try pushNode(.{ .kind = .const_load, .op = entry.op - 2, .ty = array.elem, .opnd_ty = it, .kids = .{ index, 0, 0, 0 }, .offset = entry.offset });
        return;
    }
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

// A sample offset: an integer literal or `const`, optionally negated, so the
// halo is known at compile time.
fn parseSampleOffset() CompileError!i32 {
    const negate = peek().kind == .minus;
    if (negate) _ = advance();
    const t = advance();
    var lit: Literal = undefined;
    if (t.kind == .int_lit) {
        lit = try intLiteral(t);
    } else if (t.kind == .ident) {
        lit = for (consts[0..const_count]) |c| {
            if (sameName(c.name, t)) break c.value;
        } else return fail(t.start, .unsupported); // a runtime offset
    } else {
        return fail(t.start, .unsupported);
    }
    if (lit.ty != .abstract_int and lit.ty != .i32) return fail(t.start, .type_mismatch);
    if (@abs(lit.int_value) > MAX_HALO) return fail(t.start, .unsupported);
    return @intCast(if (negate) -lit.int_value else lit.int_value);
}

// `sample(dx, dy)` in a pixel kernel; the name is the current token.
fn parseSample(t: Token) CompileError!bool {
    if (!in_kernel) return fail(t.start, .unsupported);
    pos += 2;
    const dx = try parseSampleOffset();
    _ = try expect(.comma);
    const dy = try parseSampleOffset();
    if (peek().kind == .comma) _ = advance();
    _ = try expect(.r_paren);
    const reach: u8 = @intCast(@max(@abs(dx), @abs(dy)));
    kernel_samples[kernel_count] = true;
    const halo = &kernel_halos[kernel_count];
    if (reach > halo.*) {
        if (tile_halo + reach > MAX_HALO) return fail(t.start, .unsupported);
        halo.* = reach;
    }
    _ = try pushNode(.{ .kind = .sample, .ty = .vec4f, .lit = .{ .ty = .i32, .int_value = dx }, .ref = @bitCast(dy), .offset = t.start });
    return true;
}

// Parses an operand that starts with an identifier. Returns true when the
// operand is complete and false when it opened a call or index.
fn parseIdentOperand() CompileError!bool {
    const t = peek();
    const name = text(t);
    const next = peekAt(1);
    if (vecWordLen(t, false) == 4 and next.kind == .lt and isWord(peekAt(2), "u32") and
        peekAt(3).kind == .gt and peekAt(4).kind == .l_paren)
    {
        pos += 3;
        return parseConstructorCall(t, .vec4u);
    }
    if (vecWordLen(t, false) == 2 and next.kind == .lt and (isWord(peekAt(2), "i32") or isWord(peekAt(2), "u32")) and
        peekAt(3).kind == .gt and peekAt(4).kind == .l_paren)
    {
        const callee: Callee = if (isWord(peekAt(2), "i32")) .vec2i else .vec2u;
        pos += 3;
        return parseConstructorCall(t, callee);
    }
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
        if (std.mem.eql(u8, name, "sample")) return parseSample(t);
        if (lookupHelper(t)) |index| {
            pos += 2;
            if (peek().kind == .r_paren) {
                _ = advance();
                try applyUserCall(.{ .kind = .user_call, .op = @intCast(index), .offset = t.start }, 0);
                return true;
            }
            try pushOp(.{ .kind = .user_call, .op = @intCast(index), .offset = t.start });
            return false;
        }
        if (std.mem.eql(u8, name, "textureDimensions") or std.mem.eql(u8, name, "textureLoad")) {
            pos += 2;
            const tex = try expect(.ident);
            const known = if (texture_name) |tn| sameName(tn, tex) else false;
            if (!known) return fail(tex.start, .name);
            if (std.mem.eql(u8, name, "textureLoad")) {
                _ = try expect(.comma);
                try pushOp(.{ .kind = .call, .op = @intFromEnum(Callee.texture_load), .offset = t.start });
                return false;
            }
            if (peek().kind == .comma) return fail(peek().start, .unsupported); // a mip level
            _ = try expect(.r_paren);
            _ = try pushNode(.{ .kind = .texture_dims, .ty = .vec2u, .offset = t.start });
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
    if (lookupConstArray(t)) |index| {
        if (next.kind != .l_bracket) return fail(next.start, .unsupported); // a whole-array value
        pos += 2;
        try pushOp(.{ .kind = .bracket, .op = @intCast(2 + index), .offset = t.start });
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
                    if (open.kind != .call and open.kind != .user_call) break;
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
                    .user_call => try applyUserCall(open, open.argc + 1),
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
                if (!isVec(vt) and !isIVec(vt)) return fail(t.start, .type_mismatch);
                const swizzle = try parseSwizzle(member, vt);
                if (isIVec(vt)) {
                    // Integer vectors have two or four lanes, so a swizzle does too.
                    if (swizzle.len == 3) return fail(member.start, .unsupported);
                    const ty = if (swizzle.len == 1) ivecElem(vt) else ivecOf(vt, swizzle.len);
                    const kind: NodeKind = if (swizzle.len == 1) .lane else .swizzle;
                    const op = if (swizzle.len == 1) swizzle.lanes[0] else swizzle.packedLanes();
                    _ = try pushNode(.{ .kind = kind, .op = op, .ty = ty, .opnd_ty = vt, .kids = .{ v, 0, 0, 0 }, .offset = member.start });
                } else if (swizzle.len == 1) {
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
        if (top.kind == .paren or top.kind == .call or top.kind == .user_call or top.kind == .bracket) return fail(top.offset, .syntax);
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
            } else if (isIVec(node.ty)) {
                for (node.kids[0..2]) |kid| try setNodeTy(kid, if (isIVec(nodes[kid].ty)) node.ty else ivecElem(node.ty));
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
                    .abs, .sign, .min, .max, .clamp => {
                        node.opnd_ty = node.ty;
                        for (node.kids[0..node.argc]) |kid| try setNodeTy(kid, node.ty);
                    },
                    .select => {
                        node.opnd_ty = node.ty;
                        try setNodeTy(node.kids[0], node.ty);
                        try setNodeTy(node.kids[1], node.ty);
                    },
                    .sqrt, .inverse_sqrt, .floor, .ceil, .trunc, .round, .fract, .sin, .cos, .tan, .asin, .acos, .atan, .tanh, .exp, .exp2, .log, .log2, .dpdx, .dpdy, .fwidth => try setNodeTy(node.kids[0], node.ty),
                    .pow, .atan2, .step, .smoothstep => for (node.kids[0..node.argc]) |kid| try setNodeTy(kid, node.ty),
                    .length, .distance, .normalize => for (node.kids[0..node.argc]) |kid| try setNodeTy(kid, node.opnd_ty),
                    .dot => {},
                    .mix => {
                        try setNodeTy(node.kids[0], node.ty);
                        try setNodeTy(node.kids[1], node.ty);
                        const t = node.kids[2];
                        try setNodeTy(t, if (isVec(nodes[t].ty)) node.ty else .f32);
                    },
                    .vec2f, .vec3f, .vec4f => for (node.kids[0..node.argc]) |kid| {
                        if (!isVec(nodes[kid].ty) and !isIVec(nodes[kid].ty)) try setNodeTy(kid, .f32);
                    },
                    .vec2i, .vec2u, .vec4u => for (node.kids[0..node.argc]) |kid| {
                        if (!isVec(nodes[kid].ty) and !isIVec(nodes[kid].ty)) try setNodeTy(kid, ivecElem(node.ty));
                    },
                    .unpack4xU8 => try setNodeTy(node.kids[0], .u32),
                    .pack4xU8 => {},
                    .texture_load => {
                        const level = node.kids[1];
                        try setNodeTy(level, defaultTy(nodes[level].ty));
                    },
                    .to_f32, .to_i32, .to_u32, .to_bool => {
                        const arg = node.opnd_ty;
                        node.opnd_ty = if (isAbstract(arg) and convertible(arg, node.ty)) node.ty else defaultTy(arg);
                        try setNodeTy(node.kids[0], node.opnd_ty);
                    },
                }
            },
            .load, .const_load => {
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
    if (ty == .vec4u) return body.simd(if (is_max) @as(u32, 185) else 183); // i32x4.max_u, min_u
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

// Stack: [a, b] where each is a vec2i/vec2u or a scalar to splat.
fn emitIVecArith(kind: Tk, a_ty: Ty, b_ty: Ty) CompileError!void {
    if (!isIVec(b_ty)) try body.simd(SIMD_I32X4_SPLAT);
    if (!isIVec(a_ty)) {
        const tb = try allocLocal(.vec2i);
        try body.localSet(tb);
        try body.simd(SIMD_I32X4_SPLAT);
        try body.localGet(tb);
    }
    try body.simd(switch (kind) {
        .plus => SIMD_I32X4_ADD,
        .minus => SIMD_I32X4_SUB,
        .star => SIMD_I32X4_MUL,
        .amp => SIMD_V128_AND,
        .pipe => SIMD_V128_OR,
        .caret => SIMD_V128_XOR,
        else => unreachable,
    });
}

// Stack: [a, b] as vec4u. Shifts each lane of a by the same lane of b modulo
// 32, as WGSL and i32.shl do. A splatted amount is one i32x4 shift.
fn emitIVecShift(kind: Tk, amount: Node) CompileError!void {
    const op: u32 = if (kind == .shl) SIMD_I32X4_SHL else SIMD_I32X4_SHR_U;
    if (amount.kind == .call and @as(Callee, @enumFromInt(amount.op)) == .vec4u and amount.argc == 1 and !isIVec(nodes[amount.kids[0]].ty)) {
        try body.simdLane(SIMD_I32X4_EXTRACT_LANE, 0);
        return body.simd(op);
    }
    const tb = try allocLocal(.vec4u);
    const ta = try allocLocal(.vec4u);
    try body.localSet(tb);
    try body.localTee(ta);
    for (0..4) |lane| {
        try body.localGet(ta);
        try body.simdLane(SIMD_I32X4_EXTRACT_LANE, @intCast(lane));
        try body.localGet(tb);
        try body.simdLane(SIMD_I32X4_EXTRACT_LANE, @intCast(lane));
        try body.byte(if (kind == .shl) 0x74 else 0x76);
        try body.simdLane(SIMD_I32X4_REPLACE_LANE, @intCast(lane));
    }
}

// Stack: [a, b] as vec4u. Lane-wise unsigned comparison into 0 or -1 lanes.
fn emitIVecCompare(kind: Tk) CompileError!void {
    try body.simd(switch (kind) {
        .eq_eq => @as(u32, 55),
        .bang_eq => 56,
        .lt => 58,
        .gt => 60,
        .le => 62,
        else => 64,
    });
}

// Stack: [x: u32]. Its four bytes, low first, as vec4u lanes.
fn emitUnpack4xU8() CompileError!void {
    try body.simd(SIMD_I32X4_SPLAT);
    try body.simd(137); // i16x8.extend_low_i8x16_u
    try body.simd(169); // i32x4.extend_low_i16x8_u
}

// Stack: [v: vec4u]. The low byte of each lane, lane 0 lowest, as a u32.
fn emitPack4xU8() CompileError!void {
    const t = try allocLocal(.vec4u);
    try body.localTee(t);
    try body.localGet(t);
    try body.simd(SIMD_I8X16_SHUFFLE);
    try body.raw(&.{ 0, 4, 8, 12, 0, 4, 8, 12, 0, 4, 8, 12, 0, 4, 8, 12 });
    try body.simdLane(SIMD_I32X4_EXTRACT_LANE, 0);
}

// Stack: [i32]. Limits a texel coordinate to size - 1 as unsigned, where size
// is the global after the overrides plus `axis`.
fn emitClampCoord(axis: u32) CompileError!void {
    const t = try allocLocal(.i32);
    const m = try allocLocal(.i32);
    try body.localTee(t);
    try body.byte(0x23);
    try body.uleb(globalWidth() + axis);
    try body.i32Const(1);
    try body.byte(0x6b); // i32.sub
    try body.localTee(m);
    try body.localGet(t);
    try body.localGet(m);
    try body.byte(0x49); // i32.lt_u
    try body.byte(0x1b); // select
}

// Stack: [coords, level]. Out-of-range coordinates are clamped as Dawn's
// robustness does, `min(u32(c), size - 1)`, so a negative vec2i coordinate
// reads the last column or row; WGSL allows any texel or zero. A level other
// than 0 reads zero.
fn emitTextureLoad() CompileError!void {
    const level = try allocLocal(.i32);
    const coords = try allocLocal(.vec2i);
    try body.localSet(level);
    try body.localSet(coords);
    try body.raw(&.{ 0x02, 0x7b }); // block (result v128)
    try body.simd(SIMD_CONST);
    try body.raw(&([_]u8{0} ** 16));
    try body.localGet(level);
    try body.raw(&.{ 0x0d, 0x00, 0x1a }); // br_if 0 drop
    try body.localGet(coords);
    try body.simdLane(SIMD_I32X4_EXTRACT_LANE, 1);
    try emitClampCoord(1);
    try body.byte(0x23);
    try body.uleb(globalWidth());
    try body.byte(0x6c); // i32.mul
    try body.localGet(coords);
    try body.simdLane(SIMD_I32X4_EXTRACT_LANE, 0);
    try emitClampCoord(0);
    try body.byte(0x6a); // i32.add
    try body.i32Const(4);
    try body.byte(0x74); // i32.shl
    try body.simd(SIMD_LOAD);
    try body.byte(4);
    try body.uleb(RUN_INPUT_PTR);
    try body.byte(0x0b);
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

// ---------------------------------------------------------------------------
// Transcendental builtins
//
// sin, cos, tan, asin, acos, atan, tanh, exp2 and log2 are range reduction
// plus minimax polynomials (Cephes sinf/cosf, asinf, atanf, tanhf, exp2f and
// logf), lowered inline to f32x4 code; exp, log and pow are composed from
// them as WGSL defines them, pow(x, y) being exp2(y * log2(x)). Only
// correctly rounded f32 add, sub, mul, div and sqrt are used, never fused
// multiply-add, so every host computes the same bits, and scalar, vector and
// vectorized invocations agree. A scalar is splatted, computed in all four
// lanes and extracted. Measured worst errors against double precision, all
// within WGSL's f32 accuracy bounds:
//
// - sin, cos: 2^-23.6 absolute (1.5 ULP) in [-pi, pi], where WGSL allows
//   2^-11, and the same through |x| < 8192, where reduction by pi/2 in three
//   parts is exact; 2^-20 at |x| = 1e5. Any finite x gives a result in
//   [-1, 1]; infinity and NaN give NaN.
// - exp2: 1.2 ULP, exact at integers, with gradual underflow; +inf from
//   x >= 128 and 0 below -150.
// - exp: 1.4 ULP, reducing by ln(2) in two parts rather than rounding
//   x * log2(e); +inf above 88.73 and 0 below -103.98.
// - log2, log: 1.8 ULP, 2^-23.7 absolute in [0.5, 2], and exact log2 at
//   powers of two, including subnormal input; 0 gives -inf, +inf gives +inf,
//   and negative input or NaN gives NaN. log(x) is log2(x) * ln(2).
// - pow: log2's error is multiplied by y * log2(x), so pow is a few ULP near
//   1 and about 40 ULP for x < 10, |y| < 4, as WGSL's definition allows;
//   x < 0 gives NaN and pow(0, 0) is NaN, as on GPUs.
// - tan: 2.8 ULP through |x| < 8000, from the shared sin/cos reduction as
//   sin(r) / cos(r), or -cos(r) / sin(r) in odd quadrants.
// - asin: 2.1 ULP and acos: 1.2 ULP, reducing above |x| = 0.5 through
//   sqrt((1 - |x|) / 2) so that acos near 1 keeps its relative accuracy;
//   NaN outside [-1, 1].
// - atan: 1.7 ULP; atan2(y, x): 2.4e-7 absolute, from atan of
//   min(|x|, |y|) / max(|x|, |y|) reflected by the signs, matching libm on
//   +-0, +-inf and NaN, where WGSL leaves it undefined. Being absolute, the
//   error is many ULP when the result is near zero (|y| much less than x).
// - tanh: 1.2 ULP, polynomial below |x| = 0.625 and 1 - 2 / (e^(2|x|) + 1)
//   above, so it reaches +-1 rather than NaN.
// - inverseSqrt: 1.5 ULP, as 1 / sqrt(x), within WGSL's 2 ULP.
// - fract(x) is x - floor(x), so fract(-1e-8) rounds to 1.0, as in WGSL.
// - sign keeps +-0 and NaN; step(edge, x) is 1.0 where edge <= x;
//   smoothstep is WGSL's t * t * (3 - 2t). Reversed edges are defined;
//   equal constant edges are rejected.

const SIMD_F32X4_EQ: u32 = 65;
const SIMD_F32X4_NE: u32 = 66;
const SIMD_F32X4_LT: u32 = 67;
const SIMD_F32X4_GT: u32 = 68;
const SIMD_F32X4_LE: u32 = 69;
const SIMD_F32X4_GE: u32 = 70;
const SIMD_V128_AND: u32 = 78;
const SIMD_V128_OR: u32 = 80;
const SIMD_V128_XOR: u32 = 81;
const SIMD_V128_BITSELECT: u32 = 82;
const SIMD_I32X4_SPLAT: u32 = 17;
const SIMD_I32X4_SHL: u32 = 171;
const SIMD_I32X4_SHR_S: u32 = 172;
const SIMD_I32X4_SHR_U: u32 = 173;
const SIMD_I32X4_ADD: u32 = 174;
const SIMD_I32X4_SUB: u32 = 177;
const SIMD_I32X4_TRUNC_SAT_F32X4_S: u32 = 248;
const SIMD_F32X4_CONVERT_I32X4_S: u32 = 250;

// Cephes sinf and cosf on [-pi/4, pi/4], highest degree first.
const SIN_POLY = [_]f32{ -1.9515295891e-4, 8.3321608736e-3, -1.6666654611e-1 };
const COS_POLY = [_]f32{ 2.443315711809948e-5, -1.388731625493765e-3, 4.166664568298827e-2 };
// pi/2 as three parts; k * PIO2_1 and k * PIO2_2 are exact for |k| < 2^13.
const PIO2_1: f32 = 1.5703125;
const PIO2_2: f32 = 4.837512969970703125e-4;
const PIO2_3: f32 = 7.54978995489188216e-8;
// Cephes atanf on [-tan(pi/8), tan(pi/8)], asinf on [0, 0.25] in z = u * u,
// and tanhf on [0, 0.625^2].
const ATAN_POLY = [_]f32{ 8.05374449538e-2, -1.38776856032e-1, 1.99777106478e-1, -3.33329491539e-1 };
const ASIN_POLY = [_]f32{ 4.2163199048e-2, 2.4181311049e-2, 4.5470025998e-2, 7.4953002686e-2, 1.6666752422e-1 };
const TANH_POLY = [_]f32{ -5.70498872745e-3, 2.06390887954e-2, -5.37397155531e-2, 1.33314422036e-1, -3.33332819422e-1 };
// Cephes exp2f: 2^f = 1 + f * P(f) on [-0.5, 0.5].
const EXP2_POLY = [_]f32{ 1.535336188319500e-4, 1.339887440266574e-3, 9.618437357674640e-3, 5.550332471162809e-2, 2.402264791363012e-1, 6.931472028550421e-1 };
// ln(2) as two parts (Cephes expf); n * LN2_1 is exact for |n| < 2^15.
const LN2_1: f32 = 0.693359375;
const LN2_2: f32 = -2.12194440e-4;
// Cephes logf: ln(1 + t) = t - t^2 / 2 + t^3 * P(t) on [sqrt(1/2) - 1, sqrt(2) - 1].
const LOG_POLY = [_]f32{ 7.0376836292e-2, -1.1514610310e-1, 1.1676998740e-1, -1.2420140846e-1, 1.4249322787e-1, -1.6668057665e-1, 2.0000714765e-1, -2.4999993993e-1, 3.3333331174e-1 };

fn mathSplat(value: f32) CompileError!void {
    try body.f32Const(value);
    try body.simd(SIMD_F32X4_SPLAT);
}

fn mathSplatInt(value: i32) CompileError!void {
    try body.i32Const(value);
    try body.simd(SIMD_I32X4_SPLAT);
}

// Leaves poly[0] * x^(n-1) + ... + poly[n-1] by Horner's rule, x a local.
fn mathHorner(x: u32, poly: []const f32) CompileError!void {
    try mathSplat(poly[0]);
    for (poly[1..]) |c| {
        try body.localGet(x);
        try body.simd(SIMD_F32X4_MUL);
        try mathSplat(c);
        try body.simd(SIMD_F32X4_ADD);
    }
}

// Stack: [k] i32x4. Leaves all ones in the lanes where k is odd.
fn mathOddMask() CompileError!void {
    try body.i32Const(31);
    try body.simd(SIMD_I32X4_SHL);
    try body.i32Const(31);
    try body.simd(SIMD_I32X4_SHR_S);
}

// Stack: [x] f32x4. Leaves sin(x), cos(x) when `callee` is .cos, or
// tan(x) when .tan.
fn emitSinCos(callee: Callee) CompileError!void {
    const x = try allocLocal(.vec4f); // later sin(r)
    const k = try allocLocal(.vec4f); // later the quadrant as i32
    const r = try allocLocal(.vec4f);
    const z = try allocLocal(.vec4f);
    // k = nearest(x * 2/pi), r = x - k * pi/2
    try body.localTee(x);
    try mathSplat(2.0 / std.math.pi);
    try body.simd(SIMD_F32X4_MUL);
    try body.simd(SIMD_F32X4_NEAREST);
    try body.localSet(k);
    try body.localGet(x);
    for ([_]f32{ PIO2_1, PIO2_2, PIO2_3 }) |part| {
        try body.localGet(k);
        try mathSplat(part);
        try body.simd(SIMD_F32X4_MUL);
        try body.simd(SIMD_F32X4_SUB);
    }
    // Beyond exact reduction r is meaningless; bound it so z stays finite
    // and the result in [-1, 1]. Inside, |r| <= pi/4.
    try mathSplat(1);
    try body.simd(SIMD_F32X4_MIN);
    try mathSplat(-1);
    try body.simd(SIMD_F32X4_MAX);
    try body.localTee(r);
    try body.localGet(r);
    try body.simd(SIMD_F32X4_MUL);
    try body.localSet(z);
    // sin(r) = r + r * z * S(z)
    try mathHorner(z, &SIN_POLY);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(r);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(r);
    try body.simd(SIMD_F32X4_ADD);
    try body.localSet(x);
    try body.localGet(k);
    try body.simd(SIMD_I32X4_TRUNC_SAT_F32X4_S);
    if (callee == .cos) {
        try mathSplatInt(1);
        try body.simd(SIMD_I32X4_ADD);
    }
    try body.localSet(k);
    // cos(r) = 1 - z / 2 + z * z * C(z)
    try mathHorner(z, &COS_POLY);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(z);
    try mathSplat(0.5);
    try body.simd(SIMD_F32X4_MUL);
    try body.simd(SIMD_F32X4_SUB);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_ADD);
    if (callee == .tan) {
        // tan(x) is sin(r) / cos(r), or -cos(r) / sin(r) in odd quadrants.
        try body.localSet(z);
        try body.localGet(z);
        try body.simd(SIMD_F32X4_NEG);
        try body.localGet(x);
        try body.localGet(k);
        try mathOddMask();
        try body.simd(SIMD_V128_BITSELECT);
        try body.localGet(x);
        try body.localGet(z);
        try body.localGet(k);
        try mathOddMask();
        try body.simd(SIMD_V128_BITSELECT);
        return body.simd(SIMD_F32X4_DIV);
    }
    // Odd quadrants take cos(r); quadrants 2 and 3 negate.
    try body.localGet(x);
    try body.localGet(k);
    try mathOddMask();
    try body.simd(SIMD_V128_BITSELECT);
    try body.localGet(k);
    try body.i32Const(30);
    try body.simd(SIMD_I32X4_SHL);
    try mathSplatInt(std.math.minInt(i32));
    try body.simd(SIMD_V128_AND);
    try body.simd(SIMD_V128_XOR);
}

// Stack: [x] f32x4. Leaves 2^x, or e^x when `natural`.
fn emitExp2(natural: bool) CompileError!void {
    const x = try allocLocal(.vec4f); // later f, then n / 2
    const n = try allocLocal(.vec4f); // later as i32
    const p = try allocLocal(.vec4f);
    // Clamp so that each half of the exponent stays normal; NaN passes.
    const scale: f32 = if (natural) std.math.ln2 else 1;
    try mathSplat(-151 * scale);
    try body.simd(SIMD_F32X4_MAX);
    try mathSplat(129 * scale);
    try body.simd(SIMD_F32X4_MIN);
    try body.localTee(x);
    if (natural) {
        try mathSplat(std.math.log2e);
        try body.simd(SIMD_F32X4_MUL);
    }
    try body.simd(SIMD_F32X4_NEAREST);
    try body.localTee(n);
    // f = x - n, or (x - n * ln(2)) * log2(e) with ln(2) in two parts so
    // that the reduction is exact rather than rounding x * log2(e).
    try body.localGet(x);
    if (natural) {
        for ([_]f32{ LN2_1, LN2_2 }) |part| {
            try body.localGet(n);
            try mathSplat(part);
            try body.simd(SIMD_F32X4_MUL);
            try body.simd(SIMD_F32X4_SUB);
        }
        try mathSplat(std.math.log2e);
        try body.simd(SIMD_F32X4_MUL);
    } else {
        try body.localGet(n);
        try body.simd(SIMD_F32X4_SUB);
    }
    try body.localSet(x);
    try body.simd(SIMD_I32X4_TRUNC_SAT_F32X4_S);
    try body.localSet(n);
    // 2^f = 1 + f * P(f)
    try mathHorner(x, &EXP2_POLY);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_MUL);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_ADD);
    try body.localSet(p);
    // Scale by 2^(n >> 1) and then 2^(n - (n >> 1)), so 2^128 overflows
    // and subnormal results round once.
    try body.localGet(p);
    try body.localGet(n);
    try body.i32Const(1);
    try body.simd(SIMD_I32X4_SHR_S);
    try body.localTee(x);
    try mathSplatInt(127);
    try body.simd(SIMD_I32X4_ADD);
    try body.i32Const(23);
    try body.simd(SIMD_I32X4_SHL);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(n);
    try body.localGet(x);
    try body.simd(SIMD_I32X4_SUB);
    try mathSplatInt(127);
    try body.simd(SIMD_I32X4_ADD);
    try body.i32Const(23);
    try body.simd(SIMD_I32X4_SHL);
    try body.simd(SIMD_F32X4_MUL);
}

// Stack: [x] f32x4. Leaves log2(x).
fn emitLog2() CompileError!void {
    const x = try allocLocal(.vec4f);
    const m = try allocLocal(.vec4f); // the mantissa, later t = m - 1
    const e = try allocLocal(.vec4f); // the exponent as i32, later f32
    const mask = try allocLocal(.vec4f);
    const z = try allocLocal(.vec4f);
    // Subnormal input is scaled by 2^23 first.
    try body.localTee(x);
    try mathSplat(std.math.floatMin(f32));
    try body.simd(SIMD_F32X4_LT);
    try body.localSet(mask);
    try body.localGet(x);
    try mathSplat(0x1p23);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(x);
    try body.localGet(mask);
    try body.simd(SIMD_V128_BITSELECT);
    try body.localTee(m);
    try body.i32Const(23);
    try body.simd(SIMD_I32X4_SHR_U);
    try mathSplatInt(127);
    try body.simd(SIMD_I32X4_SUB);
    try body.localGet(mask);
    try mathSplatInt(23);
    try body.simd(SIMD_V128_AND);
    try body.simd(SIMD_I32X4_SUB);
    try body.localSet(e);
    // m in [1, 2), then halved above sqrt(2) so that t = m - 1 is small.
    try body.localGet(m);
    try mathSplatInt(0x007fffff);
    try body.simd(SIMD_V128_AND);
    try mathSplatInt(0x3f800000);
    try body.simd(SIMD_V128_OR);
    try body.localTee(m);
    try mathSplat(std.math.sqrt2);
    try body.simd(SIMD_F32X4_GT);
    try body.localSet(mask);
    try body.localGet(m);
    try mathSplat(0.5);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(m);
    try body.localGet(mask);
    try body.simd(SIMD_V128_BITSELECT);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_SUB);
    try body.localTee(m);
    try body.localGet(m);
    try body.simd(SIMD_F32X4_MUL);
    try body.localSet(z);
    // A true mask is -1, so subtracting it adds one to the exponent.
    try body.localGet(e);
    try body.localGet(mask);
    try body.simd(SIMD_I32X4_SUB);
    try body.simd(SIMD_F32X4_CONVERT_I32X4_S);
    try body.localSet(e);
    // ln(m) = t + (t * z * P(t) - z / 2), then log2(x) = e + ln(m) * log2(e)
    try mathHorner(m, &LOG_POLY);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(m);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(z);
    try mathSplat(0.5);
    try body.simd(SIMD_F32X4_MUL);
    try body.simd(SIMD_F32X4_SUB);
    try body.localGet(m);
    try body.simd(SIMD_F32X4_ADD);
    try mathSplat(std.math.log2e);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(e);
    try body.simd(SIMD_F32X4_ADD);
    // Negative input and NaN give NaN, 0 gives -inf, and +inf stays.
    try mathSplat(std.math.nan(f32));
    try body.localGet(x);
    try mathSplat(0);
    try body.simd(SIMD_F32X4_GE);
    try body.simd(SIMD_V128_BITSELECT);
    try body.localSet(z);
    try mathSplat(-std.math.inf(f32));
    try body.localGet(z);
    try body.localGet(x);
    try mathSplat(0);
    try body.simd(SIMD_F32X4_EQ);
    try body.simd(SIMD_V128_BITSELECT);
    try body.localSet(z);
    try body.localGet(x);
    try body.localGet(z);
    try body.localGet(x);
    try mathSplat(std.math.inf(f32));
    try body.simd(SIMD_F32X4_EQ);
    try body.simd(SIMD_V128_BITSELECT);
}

// Stack: [x] f32x4. Leaves x with the sign of `sign`, a local.
fn mathCopySign(sign: u32) CompileError!void {
    try mathSplatInt(0x7fffffff);
    try body.simd(SIMD_V128_AND);
    try body.localGet(sign);
    try mathSplatInt(std.math.minInt(i32));
    try body.simd(SIMD_V128_AND);
    try body.simd(SIMD_V128_OR);
}

// Stack: [a, b, mask]. Leaves a where mask is set and b elsewhere.
fn mathSelect() CompileError!void {
    try body.simd(SIMD_V128_BITSELECT);
}

// Stack: [x] f32x4 with x >= 0 or NaN. Leaves atan(x): Cephes atanf
// reduces to |t| <= tan(pi/8) by atan(x) = pi/2 + atan(-1/x) above
// tan(3pi/8) and pi/4 + atan((x - 1)/(x + 1)) above tan(pi/8).
fn emitAtanPositive() CompileError!void {
    const x = try allocLocal(.vec4f);
    const big = try allocLocal(.vec4f);
    const mid = try allocLocal(.vec4f);
    const t = try allocLocal(.vec4f);
    const z = try allocLocal(.vec4f);
    try body.localTee(x);
    try mathSplat(2.414213562373095);
    try body.simd(SIMD_F32X4_GT);
    try body.localSet(big);
    try body.localGet(x);
    try mathSplat(0.4142135623730950);
    try body.simd(SIMD_F32X4_GT);
    try body.localSet(mid);
    // t = -1 / x, (x - 1) / (x + 1) or x
    try mathSplat(-1);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_DIV);
    try body.localGet(x);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_SUB);
    try body.localGet(x);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_ADD);
    try body.simd(SIMD_F32X4_DIV);
    try body.localGet(x);
    try body.localGet(mid);
    try mathSelect();
    try body.localGet(big);
    try mathSelect();
    try body.localTee(t);
    try body.localGet(t);
    try body.simd(SIMD_F32X4_MUL);
    try body.localSet(z);
    // atan(t) = t + t * z * P(z)
    try mathHorner(z, &ATAN_POLY);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(t);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(t);
    try body.simd(SIMD_F32X4_ADD);
    try mathSplat(std.math.pi / 2.0);
    try mathSplat(std.math.pi / 4.0);
    try mathSplat(0);
    try body.localGet(mid);
    try mathSelect();
    try body.localGet(big);
    try mathSelect();
    try body.simd(SIMD_F32X4_ADD);
}

// Stack: [y] f32x4, with x a local. Leaves atan2(y, x) from the atan of
// min(|x|, |y|) / max(|x|, |y|) in [0, 1], reflected into the quadrant.
// atan2(+-0, +0) is +-0 and atan2(+-0, -0) is +-pi; both infinite gives
// +-pi/4 or +-3pi/4, as libm does.
fn emitAtan2(x: u32) CompileError!void {
    const y = try allocLocal(.vec4f);
    const ax = try allocLocal(.vec4f);
    const ay = try allocLocal(.vec4f);
    const lo = try allocLocal(.vec4f);
    const r = try allocLocal(.vec4f);
    try body.localTee(y);
    try body.simd(SIMD_F32X4_ABS);
    try body.localSet(ay);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_ABS);
    try body.localSet(ax);
    // min / max, with 0 / 0 taken as 0 and inf / inf as 1
    try body.localGet(ax);
    try body.localGet(ay);
    try body.simd(SIMD_F32X4_MIN);
    try body.localTee(lo);
    try body.localGet(ax);
    try body.localGet(ay);
    try body.simd(SIMD_F32X4_MAX);
    try body.localTee(r);
    try body.simd(SIMD_F32X4_DIV);
    try mathSplat(0);
    try body.localGet(r);
    try mathSplat(0);
    try body.simd(SIMD_F32X4_NE);
    try mathSelect();
    try body.localSet(r);
    try mathSplat(1);
    try body.localGet(r);
    try body.localGet(lo);
    try mathSplat(std.math.inf(f32));
    try body.simd(SIMD_F32X4_EQ);
    try mathSelect();
    try emitAtanPositive();
    try body.localSet(r);
    // pi/2 - r when |y| > |x|, then pi - r when x < 0
    try mathSplat(std.math.pi / 2.0);
    try body.localGet(r);
    try body.simd(SIMD_F32X4_SUB);
    try body.localGet(r);
    try body.localGet(ay);
    try body.localGet(ax);
    try body.simd(SIMD_F32X4_GT);
    try mathSelect();
    try body.localSet(r);
    // the sign bit rather than x < 0, so that x = -0 counts as negative
    try mathSplat(std.math.pi);
    try body.localGet(r);
    try body.simd(SIMD_F32X4_SUB);
    try body.localGet(r);
    try body.localGet(x);
    try body.i32Const(31);
    try body.simd(SIMD_I32X4_SHR_S);
    try mathSelect();
    try mathCopySign(y);
}

// Stack: [x] f32x4. Leaves asin(x), or acos(x) when `cosine`. Cephes asinf:
// above |x| = 0.5, asin(|x|) = pi/2 - 2 * asin(sqrt((1 - |x|) / 2)), and
// asin(u) = u + u * z * P(z) with z = u * u. Outside [-1, 1] the square
// root of a negative gives NaN.
fn emitAsinAcos(cosine: bool) CompileError!void {
    const x = try allocLocal(.vec4f);
    const big = try allocLocal(.vec4f);
    const u = try allocLocal(.vec4f);
    const z = try allocLocal(.vec4f);
    try body.localTee(x);
    try body.simd(SIMD_F32X4_ABS);
    try body.localTee(u);
    try mathSplat(0.5);
    try body.simd(SIMD_F32X4_GT);
    try body.localSet(big);
    // z = (1 - |x|) / 2 or x * x, and u = sqrt(z) or x (|x| for asin)
    try mathSplat(1);
    try body.localGet(u);
    try body.simd(SIMD_F32X4_SUB);
    try mathSplat(0.5);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(x);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(big);
    try mathSelect();
    try body.localTee(z);
    try body.simd(SIMD_F32X4_SQRT);
    if (cosine) try body.localGet(x) else try body.localGet(u);
    try body.localGet(big);
    try mathSelect();
    try body.localSet(u);
    try mathHorner(z, &ASIN_POLY);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(u);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(u);
    try body.simd(SIMD_F32X4_ADD);
    try body.localSet(u);
    if (cosine) {
        // 2p for x > 0.5, pi - 2p for x < -0.5, and pi/2 - p between.
        try body.localGet(u);
        try body.localGet(u);
        try body.simd(SIMD_F32X4_ADD);
        try body.localSet(z);
        try body.localGet(z);
        try mathSplat(std.math.pi);
        try body.localGet(z);
        try body.simd(SIMD_F32X4_SUB);
        try body.localGet(x);
        try mathSplat(0);
        try body.simd(SIMD_F32X4_GT);
        try mathSelect();
        try mathSplat(std.math.pi / 2.0);
        try body.localGet(u);
        try body.simd(SIMD_F32X4_SUB);
        try body.localGet(big);
        return mathSelect();
    }
    // pi/2 - 2p above 0.5, with the sign of x.
    try mathSplat(std.math.pi / 2.0);
    try body.localGet(u);
    try body.localGet(u);
    try body.simd(SIMD_F32X4_ADD);
    try body.simd(SIMD_F32X4_SUB);
    try body.localGet(u);
    try body.localGet(big);
    try mathSelect();
    try mathCopySign(x);
}

// Stack: [x] f32x4. Leaves tanh(x): Cephes tanhf's x + x * z * P(z) below
// |x| = 0.625, and 1 - 2 / (e^(2|x|) + 1) with the sign of x above, which
// reaches 1 when e^(2|x|) overflows.
fn emitTanh() CompileError!void {
    const x = try allocLocal(.vec4f);
    const z = try allocLocal(.vec4f);
    const big = try allocLocal(.vec4f);
    try body.localTee(x);
    try body.simd(SIMD_F32X4_ABS);
    try body.localTee(z);
    try mathSplat(0.625);
    try body.simd(SIMD_F32X4_GT);
    try body.localSet(big);
    try mathSplat(1);
    try mathSplat(2);
    try body.localGet(z);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_ADD);
    try emitExp2(true);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_ADD);
    try body.simd(SIMD_F32X4_DIV);
    try body.simd(SIMD_F32X4_SUB);
    try mathCopySign(x);
    try body.localGet(x);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_MUL);
    try body.localSet(z);
    try mathHorner(z, &TANH_POLY);
    try body.localGet(z);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_MUL);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_ADD);
    try body.localGet(big);
    try mathSelect();
}

// Stack: [low] f32x4, with high and x locals. Leaves WGSL's t * t * (3 - 2t)
// where t = clamp((x - low) / (high - low), 0, 1).
fn emitSmoothstep(high: u32, x: u32) CompileError!void {
    const low = try allocLocal(.vec4f);
    const t = try allocLocal(.vec4f);
    try body.localSet(low);
    try body.localGet(x);
    try body.localGet(low);
    try body.simd(SIMD_F32X4_SUB);
    try body.localGet(high);
    try body.localGet(low);
    try body.simd(SIMD_F32X4_SUB);
    try body.simd(SIMD_F32X4_DIV);
    try mathSplat(0);
    try body.simd(SIMD_F32X4_MAX);
    try mathSplat(1);
    try body.simd(SIMD_F32X4_MIN);
    try body.localTee(t);
    try body.localGet(t);
    try body.simd(SIMD_F32X4_MUL);
    try mathSplat(3);
    try body.localGet(t);
    try body.localGet(t);
    try body.simd(SIMD_F32X4_ADD);
    try body.simd(SIMD_F32X4_SUB);
    try body.simd(SIMD_F32X4_MUL);
}

// Stack: [x] f32x4. Leaves 1 or -1 with the sign of x, or x when it is
// zero (keeping -0) or NaN.
fn emitSignFloat() CompileError!void {
    const x = try allocLocal(.vec4f);
    try body.localSet(x);
    try mathSplat(1);
    try mathCopySign(x);
    try body.localGet(x);
    try body.localGet(x);
    try mathSplat(0);
    try body.simd(SIMD_F32X4_NE);
    try body.localGet(x);
    try body.localGet(x);
    try body.simd(SIMD_F32X4_EQ);
    try body.simd(SIMD_V128_AND);
    try mathSelect();
}

// Stack: [x] as i32, or i32x4 when `simd`. Leaves sign(x) as -1, 0 or 1.
fn emitSignInt(simd: bool) CompileError!void {
    if (simd) {
        // A true mask is -1, so (x < 0) - (x > 0) is the sign.
        const x = try allocLocal(.vec4f);
        try body.localTee(x);
        try mathSplatInt(0);
        try body.simd(57); // i32x4.lt_s
        try body.localGet(x);
        try mathSplatInt(0);
        try body.simd(59); // i32x4.gt_s
        return body.simd(SIMD_I32X4_SUB);
    }
    const x = try allocLocal(.i32);
    try body.localTee(x);
    try body.i32Const(0);
    try body.byte(0x4a); // i32.gt_s
    try body.localGet(x);
    try body.i32Const(0);
    try body.byte(0x48); // i32.lt_s
    try body.byte(0x6b); // i32.sub
}

// Stack: the call's arguments as `ty`, an f32 or a vector. Leaves the result.
fn emitMath(callee: Callee, ty: Ty) CompileError!void {
    const scalar = !isVec(ty);
    if (callee == .fract) {
        const t = try allocLocal(ty);
        try body.localTee(t);
        try body.localGet(t);
        try emitFloatOp(ty, 0x8e, SIMD_F32X4_FLOOR);
        return emitFloatOp(ty, 0x93, SIMD_F32X4_SUB);
    }
    // Later arguments go to locals, leaving the first on the stack.
    var args: [3]u32 = undefined;
    var i: usize = switch (callee) {
        .pow, .atan2, .step => 2,
        .smoothstep => 3,
        else => 1,
    };
    while (i > 1) {
        i -= 1;
        args[i] = try allocLocal(.vec4f);
        if (scalar) try body.simd(SIMD_F32X4_SPLAT);
        try body.localSet(args[i]);
    }
    if (scalar) try body.simd(SIMD_F32X4_SPLAT);
    switch (callee) {
        .sin, .cos, .tan => try emitSinCos(callee),
        .asin => try emitAsinAcos(false),
        .acos => try emitAsinAcos(true),
        .atan => {
            const x = try allocLocal(.vec4f);
            try body.localTee(x);
            try body.simd(SIMD_F32X4_ABS);
            try emitAtanPositive();
            try mathCopySign(x);
        },
        .atan2 => try emitAtan2(args[1]),
        .tanh => try emitTanh(),
        .sign => try emitSignFloat(),
        .inverse_sqrt => {
            const x = try allocLocal(.vec4f);
            try body.localSet(x);
            try mathSplat(1);
            try body.localGet(x);
            try body.simd(SIMD_F32X4_SQRT);
            try body.simd(SIMD_F32X4_DIV);
        },
        .step => {
            // 1.0 where edge <= x, else 0.0
            try body.localGet(args[1]);
            try body.simd(SIMD_F32X4_LE);
            try mathSplat(1);
            try body.simd(SIMD_V128_AND);
        },
        .smoothstep => try emitSmoothstep(args[1], args[2]),
        .exp2 => try emitExp2(false),
        .exp => try emitExp2(true),
        .log2 => try emitLog2(),
        .log => {
            try emitLog2();
            try mathSplat(std.math.ln2);
            try body.simd(SIMD_F32X4_MUL);
        },
        .pow => {
            try emitLog2();
            try body.localGet(args[1]);
            try body.simd(SIMD_F32X4_MUL);
            try emitExp2(false);
        },
        else => unreachable,
    }
    if (scalar) try body.simdLane(SIMD_F32X4_EXTRACT_LANE, 0);
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
        .sample => {
            try body.i32Const(@intCast(node.lit.int_value));
            try body.i32Const(@bitCast(node.ref));
            try body.byte(0x10);
            try body.uleb(FN_SAMPLE);
        },
        .lane => try body.simdLane(if (isIVec(node.opnd_ty)) SIMD_I32X4_EXTRACT_LANE else SIMD_F32X4_EXTRACT_LANE, node.op),
        .user_call => {
            try body.byte(0x10);
            try body.uleb(helperFn(node.op));
        },
        .const_load => {
            // An index past the end reads the last element, as Dawn clamps
            // `min(u32(i), n - 1)`; WGSL allows any element or zero.
            const array = const_arrays[node.op];
            const t = try allocLocal(.u32);
            try body.localTee(t);
            try body.i32Const(@bitCast(array.len - 1));
            try body.localGet(t);
            try body.i32Const(@bitCast(array.len - 1));
            try body.raw(&.{ 0x49, 0x1b }); // i32.lt_u select
            try body.i32Const(elemShift(array.elem));
            try body.byte(0x74);
            switch (array.elem) {
                .f32 => try body.byte(0x2a),
                .i32, .u32 => try body.byte(0x28),
                else => try body.simd(SIMD_LOAD),
            }
            try body.byte(elemShift(array.elem));
            try body.uleb(CONST_DATA_PTR + array.offset);
        },
        .texture_dims => {
            try body.byte(0x23);
            try body.uleb(globalWidth());
            try body.simd(SIMD_I32X4_SPLAT);
            try body.byte(0x23);
            try body.uleb(globalWidth() + 1);
            try body.simdLane(SIMD_I32X4_REPLACE_LANE, 1);
        },
        .swizzle => try emitSwizzle(node.op, vecLen(node.ty)),
        .unary => switch (@as(Tk, @enumFromInt(node.op))) {
            .minus => if (isVec(node.ty)) try body.simd(SIMD_F32X4_NEG) else if (node.ty == .f32) try body.byte(0x8c) else {
                try body.i32Const(-1);
                try body.byte(0x6c);
            },
            .bang => if (node.ty == .vec4b) try body.simd(77) else try body.byte(0x45),
            .tilde => if (node.ty == .vec4u) try body.simd(77) else {
                try body.i32Const(-1);
                try body.byte(0x73);
            },
            else => unreachable,
        },
        .binary => {
            const kind: Tk = @enumFromInt(node.op);
            if (isVec(node.ty)) return emitVecArith(kind, nodes[node.kids[0]].ty, nodes[node.kids[1]].ty);
            if (node.ty == .vec4b) {
                if (node.opnd_ty == .vec4u) return emitIVecCompare(kind);
                return body.simd(if (kind == .amp) SIMD_V128_AND else SIMD_V128_OR);
            }
            if (kind == .shl or kind == .shr) if (node.ty == .vec4u) return emitIVecShift(kind, nodes[node.kids[1]]);
            if (isIVec(node.ty)) return emitIVecArith(kind, nodes[node.kids[0]].ty, nodes[node.kids[1]].ty);
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
                // WGSL select(f, t, cond) is Wasm select(t, f, cond), or
                // v128.bitselect(t, f, cond) for a vec4<bool> condition.
                const cond_ty = nodes[node.kids[2]].ty;
                const tc = try allocLocal(cond_ty);
                const tt = try allocLocal(node.ty);
                const tf = try allocLocal(node.ty);
                try body.localSet(tc);
                try body.localSet(tt);
                try body.localSet(tf);
                try body.localGet(tt);
                try body.localGet(tf);
                try body.localGet(tc);
                if (cond_ty == .vec4b) try body.simd(SIMD_V128_BITSELECT) else try body.byte(0x1b);
            },
            .unpack4xU8 => try emitUnpack4xU8(),
            .pack4xU8 => try emitPack4xU8(),
            .sqrt => try emitFloatOp(node.ty, 0x91, SIMD_F32X4_SQRT),
            .floor => try emitFloatOp(node.ty, 0x8e, SIMD_F32X4_FLOOR),
            .ceil => try emitFloatOp(node.ty, 0x8d, SIMD_F32X4_CEIL),
            .trunc => try emitFloatOp(node.ty, 0x8f, SIMD_F32X4_TRUNC),
            // nearest: ties to even, as in WGSL
            .round => try emitFloatOp(node.ty, 0x90, SIMD_F32X4_NEAREST),
            .dot => try emitDot(vecLen(node.opnd_ty)),
            .mix => try emitMix(node.ty, nodes[node.kids[2]].ty),
            .sign => |callee| if (node.ty == .i32) try emitSignInt(false) else try emitMath(callee, node.ty),
            .inverse_sqrt, .fract, .sin, .cos, .tan, .asin, .acos, .atan, .atan2, .tanh, .exp, .exp2, .log, .log2, .pow, .step, .smoothstep => |callee| try emitMath(callee, node.ty),
            .length, .distance => |callee| {
                if (callee == .distance) try emitFloatOp(node.opnd_ty, 0x93, SIMD_F32X4_SUB);
                if (!isVec(node.opnd_ty)) return body.byte(0x8b); // f32.abs
                const t = try allocLocal(.vec4f);
                try body.localTee(t);
                try body.localGet(t);
                try emitDot(vecLen(node.opnd_ty));
                try body.byte(0x91); // f32.sqrt
            },
            .normalize => {
                // v / sqrt(dot(v, v))
                const t = try allocLocal(.vec4f);
                try body.localTee(t);
                try body.localGet(t);
                try body.localGet(t);
                try emitDot(vecLen(node.ty));
                try body.byte(0x91);
                try body.simd(SIMD_F32X4_SPLAT);
                try body.simd(SIMD_F32X4_DIV);
            },
            .to_f32, .to_i32, .to_u32, .to_bool => try emitConvert(node.opnd_ty, node.ty),
            .vec2f, .vec3f, .vec4f => if (node.argc > 1) try emitVecConstruct(node) else if (isIVec(node.opnd_ty)) {
                try body.simd(SIMD_F32X4_CONVERT_I32X4_S + @intFromBool(node.opnd_ty != .vec2i));
            } else if (!isVec(node.opnd_ty)) {
                try body.simd(SIMD_F32X4_SPLAT);
            },
            .vec2i, .vec2u, .vec4u => if (node.argc > 1) {
                var temps: [4]u32 = undefined;
                var lane: usize = node.argc;
                while (lane > 1) {
                    lane -= 1;
                    temps[lane] = try allocLocal(.i32);
                    try body.localSet(temps[lane]);
                }
                try body.simd(SIMD_I32X4_SPLAT);
                for (1..node.argc) |l| {
                    try body.localGet(temps[l]);
                    try body.simdLane(SIMD_I32X4_REPLACE_LANE, @intCast(l));
                }
            } else if (node.opnd_ty == .vec2f or node.opnd_ty == .vec4f) {
                // Saturating, as WGSL's float-to-integer conversion.
                try body.simd(SIMD_I32X4_TRUNC_SAT_F32X4_S + @intFromBool(node.ty != .vec2i));
            } else if (!isIVec(node.opnd_ty)) {
                try body.simd(SIMD_I32X4_SPLAT);
            },
            .texture_load => try emitTextureLoad(),
            .dpdx, .dpdy, .fwidth => |callee| {
                if (!isVec(node.ty)) try body.simd(SIMD_F32X4_SPLAT);
                try body.i32Const(@intFromEnum(callee) - @intFromEnum(Callee.dpdx));
                try body.byte(0x10);
                try body.uleb(FN_DERIV);
                if (!isVec(node.ty)) try body.simdLane(SIMD_F32X4_EXTRACT_LANE, 0);
            },
        },
    }
}

fn emitExpr(root: u16, want: ?Ty) CompileError!Ty {
    try concretize(root, want);
    rememberExpr(root);
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

const BlockKind = enum(u8) { func, plain, if_then, if_else, loop_body };
// A loop body also records its counter local, step and type, for the
// increment its closing brace emits.
const Block = struct { kind: BlockKind, scope_mark: usize, extra_ends: u32 = 0, counter: u32 = 0, step: i64 = 0 };

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

fn parseDeclaration(mutable: bool, is_const: bool) CompileError!void {
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
        rememberLiteral(.{ .ty = ty });
    }
    _ = try expect(.semicolon);
    const const_value = if (is_const) constFloat(@intCast(node_len - 1)) else null;
    // Declare after the initializer so that `let x = x + 1;` sees the outer x.
    const index = try declareLocal(name, ty, mutable);
    scope[scope_len - 1].const_value = const_value;
    try body.localSet(index);
    rememberStmt(.{ .kind = .declare, .expr = last_expr, .local = index, .ty = ty });
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
    rememberStmt(.{ .kind = .assign, .expr = last_expr, .local = local.index, .ty = local.ty, .op = compoundOp(op_tok.kind) orelse .eq, .lane = lane });
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
            rememberLiteral(.{ .ty = local.ty, .int_value = 1 });
        } else {
            const rhs_want: Ty = if (op == .shl or op == .shr) .u32 else local.ty;
            const rhs = try parseExpr();
            if (op == .shl or op == .shr) try checkShiftCount(rhs, op_tok.start);
            _ = try emitExpr(rhs, rhs_want);
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
    rememberStmt(.{ .kind = .assign, .expr = last_expr, .local = local.index, .ty = local.ty, .op = compoundOp(op_tok.kind) orelse .eq });
}

fn parseStore(id: u8) CompileError!void {
    const name = advance();
    if (id != 1) return fail(name.start, .type_mismatch); // read-only buffer
    _ = try expect(.l_bracket);
    const index_ty = try compileExpr(null);
    const index_expr = last_expr;
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
    rememberStmt(.{ .kind = .store, .expr = last_expr, .index_expr = index_expr, .ty = elem });
}

fn emitEnds(count: u32) CompileError!void {
    var i: u32 = 0;
    while (i < count) : (i += 1) try body.byte(0x0b);
}

fn parseIfHead(extra_ends: u32) CompileError!void {
    _ = try compileExpr(.bool);
    rememberStmt(.{ .kind = .if_head, .expr = last_expr });
    _ = try expect(.l_brace);
    try body.raw(&.{ 0x04, 0x40 });
    try pushBlock(.{ .kind = .if_then, .scope_mark = scope_len, .extra_ends = extra_ends });
}

// An integer literal or `const`, optionally negated, of type `ty`.
fn parseLoopConst(ty: Ty) CompileError!i64 {
    const negate = peek().kind == .minus;
    if (negate) _ = advance();
    const t = advance();
    var lit: Literal = undefined;
    if (t.kind == .int_lit) {
        lit = try intLiteral(t);
    } else if (t.kind == .ident) {
        lit = for (consts[0..const_count]) |c| {
            if (sameName(c.name, t)) break c.value;
        } else return fail(t.start, .unsupported); // a runtime bound
    } else {
        return fail(t.start, .unsupported);
    }
    if (negate) {
        if (lit.ty == .u32) return fail(t.start, .type_mismatch);
        lit.int_value = -lit.int_value;
    }
    try concretizeLiteral(&lit, ty, t.start);
    return lit.int_value;
}

// `for (var i = init; i < N; i++) { ... }`: the bound N and the step are
// integer literals or consts, the comparison runs the same way as the step,
// and the body cannot assign `i`. It compiles to a counted Wasm loop that
// wasm-bounded-loops proves:
//
//   block $break  loop $top  (i >= N) br_if $break  block $continue
//     body
//   end  i += step  br $top  end end
fn parseFor() CompileError!void {
    _ = advance();
    _ = try expect(.l_paren);
    _ = try expectWord("var");
    const name = try expect(.ident);
    var declared: ?Ty = null;
    if (peek().kind == .colon) {
        _ = advance();
        declared = try parseType();
    }
    _ = try expect(.eq);
    const init_at = peek().start;
    const ty = try compileExpr(declared);
    if (ty != .i32 and ty != .u32) return fail(init_at, .type_mismatch);
    _ = try expect(.semicolon);
    // The counter's scope is the loop; the body sees it as immutable.
    try pushBlock(.{ .kind = .plain, .scope_mark = scope_len });
    const counter = try declareLocal(name, ty, false);
    try body.localSet(counter);
    // Loops are not vectorized.
    ir_complete = false;

    const cond = try expect(.ident);
    if (!sameName(cond, name)) return fail(cond.start, .unsupported);
    const cmp = advance();
    switch (cmp.kind) {
        .lt, .le, .gt, .ge => {},
        else => return fail(cmp.start, .unsupported),
    }
    const bound = try parseLoopConst(ty);
    _ = try expect(.semicolon);

    const update = try expect(.ident);
    if (!sameName(update, name)) return fail(update.start, .unsupported);
    const op = advance();
    const step: i64 = switch (op.kind) {
        .plus_plus => 1,
        .minus_minus => -1,
        .plus_eq => try parseLoopConst(ty),
        .minus_eq => -(try parseLoopConst(ty)),
        .eq => blk: {
            const again = try expect(.ident);
            if (!sameName(again, name)) return fail(again.start, .unsupported);
            const sign = advance();
            if (sign.kind != .plus and sign.kind != .minus) return fail(sign.start, .unsupported);
            const amount = try parseLoopConst(ty);
            break :blk if (sign.kind == .plus) amount else -amount;
        },
        else => return fail(op.start, .unsupported),
    };
    const up = cmp.kind == .lt or cmp.kind == .le;
    if (step == 0 or (step > 0) != up) return fail(op.start, .unsupported);
    // The step past the last iteration must not wrap, or the loop would not end.
    const lo: i64 = if (ty == .i32) std.math.minInt(i32) else 0;
    const hi: i64 = if (ty == .i32) std.math.maxInt(i32) else std.math.maxInt(u32);
    const last: i64 = switch (cmp.kind) {
        .lt => bound - 1,
        .gt => bound + 1,
        else => bound,
    };
    if (last + step > hi or last + step < lo) return fail(op.start, .unsupported);
    _ = try expect(.r_paren);
    _ = try expect(.l_brace);

    try body.raw(&.{ 0x02, 0x40, 0x03, 0x40 }); // block loop
    try body.localGet(counter);
    try body.i32Const(@truncate(bound));
    // The exit test is the comparison's negation.
    const signed = ty == .i32;
    try body.byte(switch (cmp.kind) {
        .lt => if (signed) @as(u8, 0x4e) else 0x4f, // ge
        .le => if (signed) @as(u8, 0x4a) else 0x4b, // gt
        .gt => if (signed) @as(u8, 0x4c) else 0x4d, // le
        else => if (signed) @as(u8, 0x48) else 0x49, // lt
    });
    try body.raw(&.{ 0x0d, 0x01, 0x02, 0x40 }); // br_if $break block $continue
    try pushBlock(.{ .kind = .loop_body, .scope_mark = scope_len, .counter = counter, .step = step });
}

// `break;` or `continue;` in a loop body: a branch to $break or $continue
// past the Wasm frames that ifs opened inside the body.
fn parseLoopBranch(is_break: bool) CompileError!void {
    const t = advance();
    var depth: u32 = 0;
    var i = block_len;
    const found = while (i > 0) {
        i -= 1;
        switch (blocks[i].kind) {
            .loop_body => break true,
            .if_then, .if_else => depth += 1 + blocks[i].extra_ends,
            .func => break false,
            .plain => {},
        }
    } else false;
    if (!found) return fail(t.start, .unsupported); // outside a loop
    if (is_break and isWord(peek(), "if")) return fail(peek().start, .unsupported);
    _ = try expect(.semicolon);
    try body.byte(0x0c); // br
    try body.uleb(depth + @as(u32, if (is_break) 2 else 0));
}

fn closeBlock() CompileError!void {
    _ = advance();
    block_len -= 1;
    const block = blocks[block_len];
    scope_len = block.scope_mark;
    switch (block.kind) {
        .func, .plain => {},
        .loop_body => {
            try body.byte(0x0b); // end $continue
            try body.localGet(block.counter);
            try body.i32Const(@truncate(block.step));
            try body.byte(0x6a); // i32.add
            try body.localSet(block.counter);
            try body.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br $top end end
            // Close the scope that holds the counter.
            block_len -= 1;
            scope_len = blocks[block_len].scope_mark;
        },
        .if_then => {
            if (isWord(peek(), "else")) {
                _ = advance();
                try body.byte(0x05);
                rememberStmt(.{ .kind = .else_head });
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
                for (0..1 + block.extra_ends) |_| rememberStmt(.{ .kind = .end_if });
            }
        },
        .if_else => {
            try emitEnds(1 + block.extra_ends);
            for (0..1 + block.extra_ends) |_| rememberStmt(.{ .kind = .end_if });
        },
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
        return parseDeclaration(false, std.mem.eql(u8, word, "const"));
    }
    if (std.mem.eql(u8, word, "var")) {
        _ = advance();
        if (peek().kind == .lt) return fail(peek().start, .unsupported);
        return parseDeclaration(true, false);
    }
    if (std.mem.eql(u8, word, "if")) {
        _ = advance();
        return parseIfHead(0);
    }
    if (std.mem.eql(u8, word, "for")) return parseFor();
    if (std.mem.eql(u8, word, "break") or std.mem.eql(u8, word, "continue")) return parseLoopBranch(std.mem.eql(u8, word, "break"));
    if (std.mem.eql(u8, word, "return")) {
        _ = advance();
        if (return_ty != .void) {
            _ = try compileExpr(return_ty);
            if (block_len == 1) kernel_returned = true;
            if (in_fragment and uses_derivatives) {
                // A demoted invocation returns zero.
                try body.simd(SIMD_CONST);
                try body.raw(&([_]u8{0} ** 16));
                try body.byte(0x23);
                try body.uleb(derivGlobal(.discarded));
                try body.byte(0x45); // i32.eqz
                try body.raw(&.{ 0x1c, 0x01, 0x7b }); // select (result v128)
            }
        } else if (peek().kind != .semicolon) {
            return fail(peek().start, .unsupported);
        }
        _ = try expect(.semicolon);
        rememberStmt(.{ .kind = .ret });
        return body.byte(0x0f);
    }
    if (std.mem.eql(u8, word, "_")) {
        _ = advance();
        _ = try expect(.eq);
        _ = try compileExpr(null);
        _ = try expect(.semicolon);
        rememberStmt(.{ .kind = .discard, .expr = last_expr });
        return body.byte(0x1a); // drop
    }
    if (in_fragment and std.mem.eql(u8, word, "discard")) {
        // The output starts transparent black and a discarded fragment
        // writes nothing, so returning zero leaves the same pixel. With
        // derivatives, a discard nested in control flow demotes the
        // invocation instead, as on a GPU: it runs on so its quad neighbours
        // see its values, and its returns give zero.
        _ = advance();
        _ = try expect(.semicolon);
        if (uses_derivatives and block_len > 1) {
            try body.i32Const(1);
            try body.byte(0x24);
            return body.uleb(derivGlobal(.discarded));
        }
        if (block_len == 1) kernel_returned = true;
        try body.simd(SIMD_CONST);
        try body.raw(&([_]u8{0} ** 16));
        return body.byte(0x0f);
    }
    const unsupported_words = [_][]const u8{ "while", "loop", "switch", "discard", "const_assert" };
    for (unsupported_words) |w| if (std.mem.eql(u8, word, w)) return fail(t.start, .unsupported);
    if (lookupLocal(t)) |local| return parseLocalAssignment(local);
    if (bufferId(t)) |id| return parseStore(id);
    if (lookupHelper(t) != null and peekAt(1).kind == .l_paren) {
        // A call statement drops any result.
        allow_void_call = true;
        const ty = compileExpr(null) catch |err| {
            allow_void_call = false;
            return err;
        };
        allow_void_call = false;
        _ = try expect(.semicolon);
        rememberStmt(.{ .kind = .discard, .expr = last_expr });
        if (ty != .void) try body.byte(0x1a); // drop
        return;
    }
    if (moduleNameTaken(t)) return fail(t.start, .type_mismatch);
    if (peekAt(1).kind == .l_paren) return fail(t.start, .unsupported); // function call statement
    return fail(t.start, .name);
}

// ---------------------------------------------------------------------------
// Module scope

const Attributes = struct { compute: bool = false, fragment: bool = false, builtin_gid: bool = false, builtin_position: bool = false, location0: bool = false, other_builtin: ?u32 = null };

fn parseAttributes() CompileError!Attributes {
    var attrs = Attributes{};
    while (peek().kind == .at) {
        _ = advance();
        const name = try expect(.ident);
        if (isWord(name, "compute")) attrs.compute = true;
        if (isWord(name, "fragment")) attrs.fragment = true;
        if (isWord(name, "vertex")) return fail(name.start, .unsupported);
        if (peek().kind != .l_paren) continue;
        if (isWord(name, "builtin")) {
            _ = advance();
            const arg = try expect(.ident);
            if (isWord(arg, "global_invocation_id")) {
                attrs.builtin_gid = true;
            } else if (isWord(arg, "position")) {
                attrs.builtin_position = true;
            } else {
                attrs.other_builtin = arg.start;
            }
            _ = try expect(.r_paren);
            continue;
        }
        if (isWord(name, "location")) {
            _ = advance();
            const arg = try expect(.int_lit);
            const lit = try intLiteral(arg);
            if (lit.int_value != 0) return fail(arg.start, .unsupported); // one colour output
            attrs.location0 = true;
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

// `array<T, N>` after its `array` token; T is f32, i32, u32 or vecNf.
fn parseArrayType(len: *?u32) CompileError!Ty {
    _ = try expect(.lt);
    const elem_at = peek().start;
    const elem = try parseType();
    if (elem == .bool or elem == .vec4b or isIVec(elem)) return fail(elem_at, .unsupported);
    _ = try expect(.comma);
    const n = try expect(.int_lit);
    const lit = try intLiteral(n);
    if (lit.int_value < 1 or lit.int_value > CONST_DATA_CAP) return fail(n.start, .unsupported);
    len.* = @intCast(lit.int_value);
    _ = try expect(.gt);
    return elem;
}

// `const name = array<T, N>(e0, e1, ...);`, `array(...)`, or with the type
// after the name. Elements are literals, or vecNf constructors of literals.
// The values go into the module's data segment.
fn parseConstArray(name: Token, declared_elem: ?Ty, declared_len: ?u32) CompileError!void {
    if (const_array_count >= MAX_CONST_ARRAYS) return fail(name.start, .unsupported);
    const array_tok = try expectWord("array");
    var elem = declared_elem;
    var len = declared_len;
    if (peek().kind == .lt) {
        var written_len: ?u32 = null;
        const written = try parseArrayType(&written_len);
        if ((elem != null and elem.? != written) or (len != null and len.? != written_len.?)) return fail(array_tok.start, .type_mismatch);
        elem = written;
        len = written_len;
    }
    _ = try expect(.l_paren);
    const offset: u32 = @intCast(const_data_len);
    var count: u32 = 0;
    while (peek().kind != .r_paren) {
        const at = peek().start;
        var lanes: [4]Literal = undefined;
        var lane_count: u8 = 1;
        var vec_ty: ?Ty = null;
        if (vecWordLen(peek(), true)) |n| {
            _ = advance();
            vec_ty = vecOf(n);
        } else if (vecWordLen(peek(), false)) |n| {
            _ = advance();
            _ = try expect(.lt);
            _ = try expectWord("f32");
            _ = try expect(.gt);
            vec_ty = vecOf(n);
        }
        if (vec_ty) |vt| {
            _ = try expect(.l_paren);
            lane_count = vecLen(vt);
            for (0..lane_count) |i| {
                if (i > 0) _ = try expect(.comma);
                const lane_at = peek().start;
                lanes[i] = try parseConstLiteral();
                try concretizeLiteral(&lanes[i], .f32, lane_at);
            }
            _ = try expect(.r_paren);
        } else {
            lanes[0] = try parseConstLiteral();
        }
        const ty = vec_ty orelse defaultTy(lanes[0].ty);
        if (elem == null) elem = ty;
        if (vec_ty == null) {
            try concretizeLiteral(&lanes[0], elem.?, at);
        } else if (elem.? != ty) {
            return fail(at, .type_mismatch);
        }
        if (elem.? == .bool) return fail(at, .unsupported);
        const size = @as(usize, 1) << elemShift(elem.?);
        if (const_data_len + size > CONST_DATA_CAP) return fail(at, .unsupported);
        @memset(const_data[const_data_len..][0..size], 0);
        for (lanes[0..lane_count], 0..) |lit, i| {
            const bits: u32 = if (elem.? == .f32 or vec_ty != null) @bitCast(@as(f32, @floatCast(lit.float_value))) else @truncate(@as(u64, @bitCast(lit.int_value)));
            std.mem.writeInt(u32, const_data[const_data_len + 4 * i ..][0..4], bits, .little);
        }
        const_data_len += size;
        count += 1;
        if (peek().kind != .comma) break;
        _ = advance();
    }
    _ = try expect(.r_paren);
    _ = try expect(.semicolon);
    if (count == 0 or (len != null and len.? != count)) return fail(array_tok.start, .type_mismatch);
    const_arrays[const_array_count] = .{ .name = name, .elem = elem.?, .len = count, .offset = offset };
    const_array_count += 1;
}

fn parseModuleConst() CompileError!void {
    const name = try expect(.ident);
    if (moduleNameTaken(name)) return fail(name.start, .name);
    if (isWord(peekAt(1), "array") or (peek().kind == .colon and isWord(peekAt(1), "array"))) {
        // Constant arrays need a stage entry's memory layout.
        if (!stage_module) return fail(name.start, .unsupported);
        var elem: ?Ty = null;
        var len: ?u32 = null;
        if (peek().kind == .colon) {
            _ = advance();
            _ = try expectWord("array");
            elem = try parseArrayType(&len);
        }
        _ = try expect(.eq);
        return parseConstArray(name, elem, len);
    }
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

// `var name: texture_2d<f32>;`, the fragment shader's input image.
fn parseTextureVar() CompileError!void {
    const name = try expect(.ident);
    if (moduleNameTaken(name)) return fail(name.start, .name);
    if (texture_name != null or kernel_count > 0) return fail(name.start, .unsupported);
    _ = try expect(.colon);
    const ty = try expect(.ident);
    if (!isWord(ty, "texture_2d")) return fail(ty.start, .unsupported);
    _ = try expect(.lt);
    _ = try expectWord("f32");
    _ = try expect(.gt);
    _ = try expect(.semicolon);
    texture_name = name;
}

fn parseBufferVar() CompileError!void {
    const open = peek();
    if (open.kind == .ident and peekAt(1).kind == .colon and isWord(peekAt(2), "texture_2d")) return parseTextureVar();
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
    if (kernel_count > 0 or fragment_entry) return fail(name.start, .unsupported); // pixel kernels own the tile
    _ = try expect(.colon);
    const array_tok = try expect(.ident);
    if (!isWord(array_tok, "array")) return fail(array_tok.start, .unsupported);
    _ = try expect(.lt);
    const elem_at = peek().start;
    const elem = try parseType();
    if (elem == .bool) return fail(elem_at, .type_mismatch);
    if (elem == .vec2f or elem == .vec3f or elem == .vec4b or isIVec(elem)) return fail(elem_at, .unsupported);
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
    param_count = 1;
    return_ty = .void;
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
    param_count = 1;
    return_ty = .vec4f;
    in_kernel = true;
    kernel_returned = false;
    kernel_halos[kernel_count] = 0;
    kernel_samples[kernel_count] = false;
    while (block_len > 0) {
        if (peek().kind == .eof) return fail(peek().start, .syntax);
        try parseStatement();
    }
    in_kernel = false;
    // Every path must return; requiring a final `return` proves that simply.
    if (!kernel_returned) return fail(tokens[pos - 1].start, .unsupported);
    try emitFunction(&kernel_code);
    tile_halo += kernel_halos[kernel_count];
    tile_samples = tile_samples or kernel_samples[kernel_count];
    kernel_count += 1;
}

// `@fragment fn name(@builtin(position) p: vec4f) -> @location(0) vec4f`
// runs once per pixel of the input image and returns its colour.
fn parseFragment(fn_tok: Token) CompileError!void {
    if (have_entry or kernel_count > 0 or input_buffer.declared or output_buffer.declared) return fail(fn_tok.start, .unsupported);
    have_entry = true;
    fragment_entry = true;
    _ = try expect(.ident);
    _ = try expect(.l_paren);
    var param: ?Token = null;
    if (peek().kind != .r_paren) {
        const param_attrs = try parseAttributes();
        if (param_attrs.other_builtin) |at| return fail(at, .unsupported);
        const name = try expect(.ident);
        if (!param_attrs.builtin_position) return fail(name.start, .unsupported); // a varying input
        if (moduleNameTaken(name)) return fail(name.start, .name);
        _ = try expect(.colon);
        const ty_at = peek().start;
        if (try parseType() != .vec4f) return fail(ty_at, .type_mismatch);
        if (peek().kind == .comma) {
            _ = advance();
            if (peek().kind != .r_paren) return fail(peek().start, .unsupported);
        }
        param = name;
    }
    _ = try expect(.r_paren);
    _ = try expect(.arrow);
    const result_attrs = try parseAttributes();
    if (result_attrs.other_builtin) |at| return fail(at, .unsupported); // frag_depth
    const result_at = peek().start;
    if (!result_attrs.location0) return fail(result_at, .unsupported);
    if (try parseType() != .vec4f) return fail(result_at, .type_mismatch);
    _ = try expect(.l_brace);
    block_len = 0;
    try pushBlock(.{ .kind = .func, .scope_mark = 0 });
    // The position is Wasm local 0 whether or not the shader names it.
    scope_len = 0;
    if (param) |name| {
        scope[0] = .{ .name = name, .index = 0, .ty = .vec4f, .mutable = false };
        scope_len = 1;
    }
    local_count = 0;
    body.len = 0;
    param_count = 1;
    return_ty = .vec4f;
    in_fragment = true;
    kernel_returned = false;
    while (block_len > 0) {
        if (peek().kind == .eof) return fail(peek().start, .syntax);
        try parseStatement();
    }
    in_fragment = false;
    if (!kernel_returned) return fail(tokens[pos - 1].start, .unsupported);
}

// `fn name(a: T, ...) -> R { ... }` in a module with a stage entry: a helper
// compiled to its own Wasm function. Helpers come before the entry, and each
// calls only those above it, so there is no recursion, as WGSL requires.
fn parseHelper(fn_tok: Token) CompileError!void {
    if (have_entry) return fail(fn_tok.start, .unsupported); // after the entry
    if (helper_count >= MAX_HELPERS) return fail(fn_tok.start, .unsupported);
    const name = try expect(.ident);
    if (moduleNameTaken(name) or lookupCallee(text(name)) != null) return fail(name.start, .name);
    var h = Helper{ .name = name, .params = undefined, .param_count = 0, .ret = .void };
    _ = try expect(.l_paren);
    block_len = 0;
    try pushBlock(.{ .kind = .func, .scope_mark = 0 });
    scope_len = 0;
    while (peek().kind != .r_paren) {
        if (peek().kind == .at) return fail(peek().start, .unsupported); // a builtin or location
        const param = try expect(.ident);
        if (moduleNameTaken(param) or sameName(param, name)) return fail(param.start, .name);
        for (scope[0..scope_len]) |local| if (sameName(local.name, param)) return fail(param.start, .name);
        if (h.param_count >= MAX_PARAMS) return fail(param.start, .unsupported);
        _ = try expect(.colon);
        const ty = try parseType();
        // WGSL parameters are immutable; parameter i is Wasm local i.
        scope[scope_len] = .{ .name = param, .index = h.param_count, .ty = ty, .mutable = false };
        scope_len += 1;
        h.params[h.param_count] = ty;
        h.param_count += 1;
        if (peek().kind != .comma) break;
        _ = advance();
    }
    _ = try expect(.r_paren);
    if (peek().kind == .arrow) {
        _ = advance();
        if (peek().kind == .at) return fail(peek().start, .unsupported);
        h.ret = try parseType();
    }
    _ = try expect(.l_brace);
    local_count = 0;
    body.len = 0;
    param_count = h.param_count;
    return_ty = h.ret;
    kernel_returned = false;
    // The vectorizer's IR records only the entry.
    const ir_was_complete = ir_complete;
    ir_complete = false;
    while (block_len > 0) {
        if (peek().kind == .eof) return fail(peek().start, .syntax);
        try parseStatement();
    }
    ir_complete = ir_was_complete;
    if (h.ret != .void and !kernel_returned) return fail(tokens[pos - 1].start, .unsupported);
    try emitFunction(&helper_code);
    helpers[helper_count] = h;
    helper_count += 1;
    body.len = 0;
    local_count = 0;
    scope_len = 0;
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
    if (std.mem.eql(u8, word, "fn")) {
        if (attrs.fragment) return parseFragment(t);
        if (attrs.compute) return parseEntry(t);
        return if (stage_module) parseHelper(t) else parseKernel(t);
    }
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
    // $i and $result. Both loop variants use the fixed element-count bound.
    try w.raw(&.{ 2, 1, 0x7f, 1, 0x7e });
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
    if (byte_kernel) {
        // The byte path stores every element, so it needs no zero fill.
        try w.i32Const(0);
        try w.byte(0x10);
        try w.uleb(FN_MAIN);
    } else if (input_buffer.declared) {
        try w.i32Const(@bitCast(RUN_OUTPUT_PTR));
        try w.i32Const(0);
        try w.localGet(0);
        try w.raw(&.{ 0xfc, 0x0b, 0x00 }); // memory.fill
    }
    // for (i = 0; i < count; i += vectorized ? 4 : 1) main(i)
    // The input cap keeps either counter far below unsigned overflow.
    if (!byte_kernel) {
        try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
        try w.localGet(1);
        try w.byte(0x23);
        try w.uleb(GLOBAL_COUNT);
        try w.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
        try w.localGet(1);
        try w.byte(0x10);
        try w.uleb(FN_MAIN);
        try w.localGet(1);
        try w.i32Const(if (vectorized) 4 else 1);
        try w.byte(0x6a);
        try w.localSet(1);
        try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    }
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

// A fragment module's `width` uniform and the derived height follow the
// overrides.
fn globalWidth() u32 {
    return @intCast(GLOBAL_FIRST_OVERRIDE + override_count);
}

// Fragment render: one call of the entry per pixel, in row order, with the
// pixel centre as the position. The `width` uniform gives the rows.
fn emitFragmentRender(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    // $x, $y and $p, then $result, then $width, and for derivative modules
    // $lane, $px, $py, $k and $eq, then $v, then the loop bounds $rows,
    // $cols and $slots.
    if (uses_derivatives) {
        try w.raw(&.{ 5, 3, 0x7f, 1, 0x7e, 6, 0x7f, 1, 0x7b, 3, 0x7f });
    } else {
        try w.raw(&.{ 3, 3, 0x7f, 1, 0x7e, 1, 0x7f });
    }
    try w.localGet(0);
    try w.i32Const(@bitCast(RUN_BYTES_CAP));
    try w.raw(&.{ 0x4b, 0x04, 0x40, 0x00, 0x0b }); // i32.gt_u if unreachable end
    try w.raw(&.{ 0x02, 0x40 }); // block $done
    // A partial pixel fails where it starts.
    try w.localGet(0);
    try w.i32Const(-16);
    try w.byte(0x71); // i32.and
    try emitFailResult(w);
    try w.localGet(0);
    try w.i32Const(15);
    try w.raw(&.{ 0x71, 0x0d, 0x00 }); // i32.and br_if $done
    try w.localGet(0);
    try w.i32Const(4);
    try w.byte(0x76); // i32.shr_u
    try w.byte(0x24);
    try w.uleb(GLOBAL_COUNT);
    // Width 0 fails at offset 0. The guard on the local is the shape
    // wasm-nontrapping-divides proves safe.
    try w.i32Const(0);
    try emitFailResult(w);
    try w.byte(0x23);
    try w.uleb(globalWidth());
    try w.localTee(5);
    try w.raw(&.{ 0x45, 0x0d, 0x00 }); // i32.eqz br_if $done
    // A partial row fails where it starts.
    try w.byte(0x23);
    try w.uleb(GLOBAL_COUNT);
    try w.localGet(5);
    try w.byte(0x6e); // i32.div_u
    try w.byte(0x24);
    try w.uleb(globalWidth() + 1);
    try w.byte(0x23);
    try w.uleb(globalWidth() + 1);
    try w.localGet(5);
    try w.byte(0x6c); // i32.mul
    try w.i32Const(4);
    try w.byte(0x74); // i32.shl
    try emitFailResult(w);
    try w.byte(0x23);
    try w.uleb(GLOBAL_COUNT);
    try w.localGet(5);
    try w.raw(&.{ 0x70, 0x0d, 0x00 }); // i32.rem_u br_if $done
    if (uses_derivatives) return emitQuadLoops(w, at);
    try w.i32Const(@bitCast(RUN_OUTPUT_PTR));
    try w.localSet(3);
    // for (y = 0; y < height; y++) for (x = 0; x < width; x++)
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(2);
    try w.byte(0x23);
    try w.uleb(globalWidth() + 1);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
    try w.i32Const(0);
    try w.localSet(1);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(1);
    try w.byte(0x23);
    try w.uleb(globalWidth());
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    try w.localGet(3);
    // position = vec4f(x + 0.5, y + 0.5, 0.0, 1.0)
    try w.simd(SIMD_CONST);
    for ([_]f32{ 0.5, 0.5, 0.0, 1.0 }) |lane| {
        const bits: u32 = @bitCast(lane);
        try w.raw(&.{ @truncate(bits), @truncate(bits >> 8), @truncate(bits >> 16), @truncate(bits >> 24) });
    }
    for (0..2) |lane| {
        try w.localGet(@intCast(1 + lane));
        try w.byte(0xb3); // f32.convert_i32_u
        try w.f32Const(0.5);
        try w.byte(0x92);
        try w.simdLane(SIMD_F32X4_REPLACE_LANE, @intCast(lane));
    }
    try w.byte(0x10);
    try w.uleb(FN_MAIN);
    try w.simd(SIMD_STORE);
    try w.raw(&.{ 4, 0 });
    try w.localGet(3);
    try w.i32Const(16);
    try w.byte(0x6a);
    try w.localSet(3);
    try w.localGet(1);
    try w.i32Const(1);
    try w.byte(0x6a);
    try w.localSet(1);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    try w.localGet(2);
    try w.i32Const(1);
    try w.byte(0x6a);
    try w.localSet(2);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b });
    try w.localGet(0);
    try w.byte(0xad); // i64.extend_i32_u
    try w.byte(0x42);
    try w.sleb(@as(i64, RUN_OUTPUT_PTR) << 32);
    try w.byte(0x84);
    try w.localSet(4);
    try w.byte(0x0b); // end $done
    // Each render starts from the authored uniform defaults and width 0.
    try emitResetOverrides(w);
    try w.i32Const(0);
    try w.byte(0x24);
    try w.uleb(globalWidth());
    try w.localGet(4);
    try w.byte(0x0b);
    w.endSize(at);
}

// Pushes the position vec4f(px + 0.5, py + 0.5, 0, 1) from two i32 locals.
fn emitPosition(w: *Buf, px: u32, py: u32) CompileError!void {
    try w.simd(SIMD_CONST);
    for ([_]f32{ 0.5, 0.5, 0.0, 1.0 }) |lane| {
        const bits: u32 = @bitCast(lane);
        try w.raw(&.{ @truncate(bits), @truncate(bits >> 8), @truncate(bits >> 16), @truncate(bits >> 24) });
    }
    for ([_]u32{ px, py }, 0..) |local, lane| {
        try w.localGet(local);
        try w.byte(0xb3); // f32.convert_i32_u
        try w.f32Const(0.5);
        try w.byte(0x92);
        try w.simdLane(SIMD_F32X4_REPLACE_LANE, @intCast(lane));
    }
}

// The rest of a derivative module's render, after the size checks. Pixels run
// in 2x2 quads, lanes 0-3 being (0,0), (1,0), (0,1) and (1,1), with lanes
// outside the image run as GPU helper invocations whose output is dropped.
// WGSL requires derivatives in uniform control flow, so each lane makes the
// same sequence of derivative calls. Each pass runs the four lanes in turn:
// a call stores its argument in this pass's bank and returns the derivative
// of the previous pass's values. A pass whose values match the previous
// pass's has consistent derivatives, so its output stands; nested
// derivatives take one more pass per level, up to DERIV_PASSES.
fn emitQuadLoops(w: *Buf, at: usize) CompileError!void {
    const qx = 1;
    const qy = 2;
    const pass = 3;
    const lane = 6;
    const px = 7;
    const py = 8;
    const k = 9;
    const eq = 10;
    const v = 11;
    const rows = 12;
    const cols = 13;
    const slots = 14;
    try w.i32Const(0);
    try w.byte(0x24);
    try w.uleb(derivGlobal(.overflow));
    // wasm-bounded-loops wants each bound in a local.
    try w.byte(0x23);
    try w.uleb(globalWidth() + 1);
    try w.raw(&.{ 0x41, 1, 0x6a, 0x41, 1, 0x76 }); // (height + 1) >> 1
    try w.localSet(rows);
    try w.localGet(5);
    try w.raw(&.{ 0x41, 1, 0x6a, 0x41, 1, 0x76 });
    try w.localSet(cols);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 }); // rows of quads
    try w.localGet(qy);
    try w.localGet(rows);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    try w.i32Const(0);
    try w.localSet(qx);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 }); // quads in the row
    try w.localGet(qx);
    try w.localGet(cols);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    try w.i32Const(0);
    try w.localSet(pass);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 }); // passes
    try w.localGet(pass);
    try w.i32Const(DERIV_PASSES);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    try w.localGet(pass);
    try w.byte(0x24);
    try w.uleb(derivGlobal(.pass));
    try w.i32Const(0);
    try w.localSet(lane);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 }); // lanes
    try w.localGet(lane);
    try w.i32Const(4);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    for ([_]DerivState{ .count, .discarded }) |state| {
        try w.i32Const(0);
        try w.byte(0x24);
        try w.uleb(derivGlobal(state));
    }
    try w.localGet(lane);
    try w.byte(0x24);
    try w.uleb(derivGlobal(.lane));
    // px = 2 * qx + (lane & 1), py = 2 * qy + (lane >> 1)
    try w.localGet(qx);
    try w.raw(&.{ 0x41, 1, 0x74 });
    try w.localGet(lane);
    try w.raw(&.{ 0x41, 1, 0x71, 0x6a });
    try w.localSet(px);
    try w.localGet(qy);
    try w.raw(&.{ 0x41, 1, 0x74 });
    try w.localGet(lane);
    try w.raw(&.{ 0x41, 1, 0x76, 0x6a });
    try w.localSet(py);
    try emitPosition(w, px, py);
    try w.byte(0x10);
    try w.uleb(FN_MAIN);
    try w.localSet(v);
    // Store only pixels inside the image; the last pass's store stands.
    try w.localGet(px);
    try w.localGet(5);
    try w.byte(0x49);
    try w.localGet(py);
    try w.byte(0x23);
    try w.uleb(globalWidth() + 1);
    try w.raw(&.{ 0x49, 0x71, 0x04, 0x40 }); // i32.lt_u i32.and if
    try w.localGet(py);
    try w.localGet(5);
    try w.byte(0x6c);
    try w.localGet(px);
    try w.raw(&.{ 0x6a, 0x41, 4, 0x74 });
    try w.localGet(v);
    try w.simd(SIMD_STORE);
    try w.byte(4);
    try w.uleb(RUN_OUTPUT_PTR);
    try w.byte(0x0b);
    try w.localGet(lane);
    try w.raw(&.{ 0x41, 1, 0x6a });
    try w.localSet(lane);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    // No derivative calls: the first pass is final.
    try w.byte(0x23);
    try w.uleb(derivGlobal(.count));
    try w.raw(&.{ 0x45, 0x0d, 0x01 }); // i32.eqz br_if (end passes)
    try w.localGet(pass);
    try w.raw(&.{ 0x04, 0x40 }); // if a later pass
    try w.i32Const(1);
    try w.localSet(eq);
    try w.i32Const(0);
    try w.localSet(k);
    try w.byte(0x23);
    try w.uleb(derivGlobal(.count));
    try w.raw(&.{ 0x41, 2, 0x74 }); // four lanes per call
    try w.localSet(slots);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(k);
    try w.localGet(slots);
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    for ([_]u32{ 0, DERIV_BANK }) |offset| {
        try w.localGet(k);
        try w.raw(&.{ 0x41, 4, 0x74 });
        try w.simd(SIMD_LOAD);
        try w.byte(4);
        try w.uleb(offset);
    }
    try w.simd(SIMD_I32X4_EQ);
    try w.simd(SIMD_I32X4_ALL_TRUE);
    try w.localGet(eq);
    try w.byte(0x71);
    try w.localSet(eq);
    try w.localGet(k);
    try w.raw(&.{ 0x41, 1, 0x6a });
    try w.localSet(k);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b });
    try w.localGet(eq);
    try w.raw(&.{ 0x0d, 0x02, 0x0b }); // br_if (end passes) end
    try w.localGet(pass);
    try w.raw(&.{ 0x41, 1, 0x6a });
    try w.localSet(pass);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b });
    try w.localGet(qx);
    try w.raw(&.{ 0x41, 1, 0x6a });
    try w.localSet(qx);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b });
    try w.localGet(qy);
    try w.raw(&.{ 0x41, 1, 0x6a });
    try w.localSet(qy);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b });
    // More than DERIV_CALLS derivative calls per pixel fails at offset 0.
    try w.localGet(0);
    try w.byte(0xad);
    try w.byte(0x42);
    try w.sleb(@as(i64, RUN_OUTPUT_PTR) << 32);
    try w.byte(0x84);
    try w.localSet(4);
    try w.i32Const(0);
    try emitFailResultIf(w, derivGlobal(.overflow));
    try w.byte(0x0b); // end $done
    try emitResetOverrides(w);
    try w.i32Const(0);
    try w.byte(0x24);
    try w.uleb(globalWidth());
    try w.localGet(4);
    try w.byte(0x0b);
    w.endSize(at);
}

// Stack: [offset]. Sets the render result to a failure at that offset when
// the global is nonzero.
fn emitFailResultIf(w: *Buf, global: u32) CompileError!void {
    try w.byte(0xad); // i64.extend_i32_u
    try w.byte(0x42);
    try w.sleb(std.math.minInt(i64));
    try w.byte(0x84); // i64.or
    try w.localGet(4);
    try w.byte(0x23);
    try w.uleb(global);
    try w.byte(0x1b); // select
    try w.localSet(4);
}

// FN_DERIV(v, kind): records v for this lane as the next derivative call, and
// returns dpdx (kind 0), dpdy (1) or fwidth (2) of the previous pass's values.
fn emitDerivFunction(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    // $k, $cur, $prev and $lane, then $dx and $dy.
    try w.raw(&.{ 2, 4, 0x7f, 2, 0x7b });
    const k = 2;
    const cur = 3;
    const prev = 4;
    const lane = 5;
    const dx = 6;
    const dy = 7;
    try w.byte(0x23);
    try w.uleb(derivGlobal(.count));
    try w.localTee(k);
    try w.i32Const(DERIV_CALLS);
    try w.raw(&.{ 0x4f, 0x04, 0x40 }); // i32.ge_u if
    try w.i32Const(1);
    try w.byte(0x24);
    try w.uleb(derivGlobal(.overflow));
    try w.simd(SIMD_CONST);
    try w.raw(&([_]u8{0} ** 16));
    try w.raw(&.{ 0x0f, 0x0b }); // return end
    try w.localGet(k);
    try w.raw(&.{ 0x41, 1, 0x6a });
    try w.byte(0x24);
    try w.uleb(derivGlobal(.count));
    try w.byte(0x23);
    try w.uleb(derivGlobal(.lane));
    try w.localSet(lane);
    // cur = (pass & 1) * DERIV_BANK + k * 64; prev is the other bank.
    try w.byte(0x23);
    try w.uleb(derivGlobal(.pass));
    try w.raw(&.{ 0x41, 1, 0x71 });
    try w.i32Const(DERIV_BANK);
    try w.byte(0x6c);
    try w.localGet(k);
    try w.raw(&.{ 0x41, 6, 0x74, 0x6a });
    try w.localTee(cur);
    try w.i32Const(DERIV_BANK);
    try w.byte(0x73); // i32.xor
    try w.localSet(prev);
    try w.localGet(cur);
    try w.localGet(lane);
    try w.raw(&.{ 0x41, 4, 0x74, 0x6a });
    try w.localGet(0);
    try w.simd(SIMD_STORE);
    try w.raw(&.{ 4, 0 });
    // dx = prev[lane | 1] - prev[lane & 2]; dy = prev[lane | 2] - prev[lane & 1]
    for ([_]struct { u8, u8, u32 }{ .{ 1, 2, dx }, .{ 2, 1, dy } }) |axis| {
        for ([_]u8{ 0x72, 0x71 }, [_]u8{ axis[0], axis[1] }) |op, mask| {
            try w.localGet(prev);
            try w.localGet(lane);
            try w.raw(&.{ 0x41, mask, op, 0x41, 4, 0x74, 0x6a }); // i32.or/and, shl 4, add
            try w.simd(SIMD_LOAD);
            try w.raw(&.{ 4, 0 });
        }
        try w.simd(SIMD_F32X4_SUB);
        try w.localSet(axis[2]);
    }
    try w.localGet(dx);
    try w.localGet(dy);
    try w.localGet(dx);
    try w.simd(SIMD_F32X4_ABS);
    try w.localGet(dy);
    try w.simd(SIMD_F32X4_ABS);
    try w.simd(SIMD_F32X4_ADD);
    try w.localGet(1);
    try w.raw(&.{ 0x41, 1, 0x46 }); // kind == 1
    try w.raw(&.{ 0x1c, 0x01, 0x7b }); // dy or fwidth
    try w.localGet(1);
    try w.byte(0x45); // kind == 0
    try w.raw(&.{ 0x1c, 0x01, 0x7b });
    try w.byte(0x0b);
    w.endSize(at);
}

// Stack: [offset]. Sets the render result to a failure at that offset.
fn emitFailResult(w: *Buf) CompileError!void {
    try w.byte(0xad); // i64.extend_i32_u
    try w.byte(0x42);
    try w.sleb(std.math.minInt(i64));
    try w.byte(0x84); // i64.or
    try w.localSet(4);
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

    const extra: u32 = @intFromBool(fragment_entry); // the width uniform
    const deriv: u32 = @intFromBool(uses_derivatives); // FN_DERIV
    const first_setter: u32 = @intCast(FN_FIRST_SETTER + deriv + helper_count);
    try w.byte(1); // type section
    var at = try w.beginSize();
    try w.uleb(6 + extra + deriv + helper_count);
    try w.raw(&.{ 0x60, 0, 1, 0x7f }); // 0: () -> i32
    try w.raw(&.{ 0x60, 1, 0x7f, 1, 0x7e }); // 1: (i32) -> i64
    try w.raw(&.{ 0x60, 1, 0x7f, 0 }); // 2: (i32) -> ()
    try w.raw(&.{ 0x60, 1, 0x7d, 1, 0x7d }); // 3: (f32) -> f32
    try w.raw(&.{ 0x60, 1, 0x7f, 1, 0x7f }); // 4: (i32) -> i32
    try w.raw(&.{ 0x60, 1, 0x7e, 1, 0x7e }); // 5: (i64) -> i64
    if (fragment_entry) try w.raw(&.{ 0x60, 1, 0x7b, 1, 0x7b }); // 6: (v128) -> v128
    if (uses_derivatives) try w.raw(&.{ 0x60, 2, 0x7b, 0x7f, 1, 0x7b }); // 7: (v128, i32) -> v128
    // One type per helper, in order.
    for (helpers[0..helper_count]) |h| {
        try w.byte(0x60);
        try w.uleb(h.param_count);
        for (h.params[0..h.param_count]) |ty| try w.byte(valType(ty));
        if (h.ret == .void) try w.byte(0) else try w.raw(&.{ 1, valType(h.ret) });
    }
    w.endSize(at);

    try w.byte(3); // function section
    at = try w.beginSize();
    try w.uleb(first_setter + override_count + extra);
    try w.raw(&.{ 0, 0, 0, 0, 1, if (fragment_entry) 6 else 2 });
    if (uses_derivatives) try w.byte(7);
    for (0..helper_count) |i| try w.uleb(6 + extra + deriv + i);
    for (overrides[0..override_count]) |o| try w.byte(setterType(o.ty));
    if (fragment_entry) try w.byte(4);
    w.endSize(at);

    try w.byte(5); // memory section: fixed size
    at = try w.beginSize();
    try w.raw(&.{ 1, 1 });
    try w.uleb(RUN_PAGES);
    try w.uleb(RUN_PAGES);
    w.endSize(at);

    try w.byte(6); // global section
    at = try w.beginSize();
    try w.uleb(1 + override_count + 2 * extra + 5 * deriv);
    try w.raw(&.{ 0x7f, 1, 0x41, 0, 0x0b }); // element count
    for (overrides[0..override_count]) |o| {
        try w.raw(&.{ valType(o.ty), 1 });
        try emitLiteral(&w, o.value);
        try w.byte(0x0b);
    }
    // Fragment width and height.
    for (0..2 * extra + 5 * deriv) |_| try w.raw(&.{ 0x7f, 1, 0x41, 0, 0x0b });
    w.endSize(at);

    try w.byte(7); // export section
    at = try w.beginSize();
    try w.uleb(6 + override_count + extra);
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
        try w.uleb(first_setter + i);
    }
    if (fragment_entry) {
        try w.name("uniform_set_width");
        try w.byte(0);
        try w.uleb(first_setter + override_count);
    }
    w.endSize(at);

    try w.byte(10); // code section
    at = try w.beginSize();
    try w.uleb(first_setter + override_count + extra);
    try emitGetter(&w, RUN_INPUT_PTR);
    try emitGetter(&w, RUN_BYTES_CAP);
    try emitGetter(&w, RUN_BYTES_CAP);
    try emitGetter(&w, 1);
    if (fragment_entry) try emitFragmentRender(&w) else try emitRender(&w);
    if (!vectorized and scalar_code.len != 0) try w.raw(scalar_code.bytes[0..scalar_code.len]) else try emitFunction(&w);
    if (uses_derivatives) try emitDerivFunction(&w);
    try w.raw(helper_code.bytes[0..helper_code.len]);
    for (overrides[0..override_count], 0..) |o, i| try emitSetter(&w, @intCast(GLOBAL_FIRST_OVERRIDE + i), o.ty);
    if (fragment_entry) try emitSetter(&w, globalWidth(), .u32);
    w.endSize(at);

    if (const_data_len > 0) {
        try w.byte(11); // data section: the constant arrays
        at = try w.beginSize();
        try w.raw(&.{ 1, 0 }); // one active segment in memory 0
        try w.i32Const(@bitCast(CONST_DATA_PTR));
        try w.byte(0x0b);
        try w.uleb(const_data_len);
        try w.raw(const_data[0..const_data_len]);
        w.endSize(at);
    }

    if (vectorized) {
        try w.byte(0);
        at = try w.beginSize();
        try w.name("qip.vectorize_invocations");
        try w.byte(4);
        w.endSize(at);
    }

    return w.len;
}

fn tileSpan() u32 {
    return TILE_SIZE + 2 * tile_halo;
}

fn tileBytes() u32 {
    return tileSpan() * tileSpan() * 16;
}

// Sampling passes write here, then copy their region back to the tile.
fn scratchPtr() u32 {
    return TILE_INPUT_PTR + tileBytes();
}

fn firstKernelFn() u32 {
    return if (tile_samples) FN_SAMPLE + 1 else FN_SAMPLE;
}

fn stateGlobal(state: TileState) u32 {
    return @intCast(GLOBAL_FIRST_OVERRIDE + override_count + @intFromEnum(state));
}

fn globalGet(w: *Buf, state: TileState) CompileError!void {
    try w.byte(0x23);
    try w.uleb(stateGlobal(state));
}

fn globalSet(w: *Buf, state: TileState) CompileError!void {
    try w.byte(0x24);
    try w.uleb(stateGlobal(state));
}

fn emitKernelCalls(w: *Buf, from: usize, to: usize) CompileError!void {
    for (from..to) |k| {
        try w.byte(0x10);
        try w.uleb(firstKernelFn() + k);
    }
}

// for (p = 0; p < tile bytes; p += 16) store(p, kernels(load(p))), in place.
fn emitPointPass(w: *Buf, p: u32, from: usize, to: usize) CompileError!void {
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(p);
    try w.i32Const(@bitCast(tileBytes()));
    try w.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
    try w.localGet(p);
    try w.localGet(p);
    try w.simd(SIMD_LOAD);
    try w.byte(4);
    try w.uleb(TILE_INPUT_PTR);
    try emitKernelCalls(w, from, to);
    try w.simd(SIMD_STORE);
    try w.byte(4);
    try w.uleb(TILE_INPUT_PTR);
    try w.localGet(p);
    try w.i32Const(16);
    try w.byte(0x6a);
    try w.localSet(p);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
}

// Locals of the tile function in a module whose kernels sample.
const TILE_ROW: u32 = 2;
const TILE_COL: u32 = 3;
const TILE_P: u32 = 4;

// Runs kernels [from, to) on rows and columns [inset, span - inset) into
// the scratch buffer, with samples reading [read, span - read), then copies
// those rows back so the next pass reads them in place.
fn emitSamplePass(w: *Buf, from: usize, to: usize, read: u32, inset: u32) CompileError!void {
    const span = tileSpan();
    try w.i32Const(@intCast(read));
    try globalSet(w, .lo);
    try w.i32Const(@intCast(span - 1 - read));
    try globalSet(w, .hi);
    try w.i32Const(@intCast(inset));
    try w.localSet(TILE_ROW);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(TILE_ROW);
    try w.i32Const(@intCast(span - inset));
    try w.raw(&.{ 0x4f, 0x0d, 0x01 }); // i32.ge_u br_if 1
    try w.localGet(TILE_ROW);
    try globalSet(w, .row);
    try w.i32Const(@intCast(inset));
    try w.localSet(TILE_COL);
    try w.raw(&.{ 0x02, 0x40, 0x03, 0x40 });
    try w.localGet(TILE_COL);
    try w.i32Const(@intCast(span - inset));
    try w.raw(&.{ 0x4f, 0x0d, 0x01 });
    try w.localGet(TILE_COL);
    try globalSet(w, .col);
    // p = (row * span + col) * 16
    try w.localGet(TILE_ROW);
    try w.i32Const(@intCast(span));
    try w.byte(0x6c);
    try w.localGet(TILE_COL);
    try w.byte(0x6a);
    try w.i32Const(4);
    try w.byte(0x74);
    try w.localTee(TILE_P);
    try w.localGet(TILE_P);
    try w.simd(SIMD_LOAD);
    try w.byte(4);
    try w.uleb(TILE_INPUT_PTR);
    try emitKernelCalls(w, from, to);
    try w.simd(SIMD_STORE);
    try w.byte(4);
    try w.uleb(scratchPtr());
    try w.localGet(TILE_COL);
    try w.i32Const(1);
    try w.byte(0x6a);
    try w.localSet(TILE_COL);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b }); // br 0 end end
    try w.localGet(TILE_ROW);
    try w.i32Const(1);
    try w.byte(0x6a);
    try w.localSet(TILE_ROW);
    try w.raw(&.{ 0x0c, 0x00, 0x0b, 0x0b });
    // The copy also moves scratch columns outside the region, but no later
    // pass reads them.
    const start = (inset * span + inset) * 16;
    const end = ((span - 1 - inset) * span + span - inset) * 16;
    try w.i32Const(@intCast(TILE_INPUT_PTR + start));
    try w.i32Const(@intCast(scratchPtr() + start));
    try w.i32Const(@intCast(end - start));
    try w.raw(&.{ 0xfc, 0x0a, 0x00, 0x00 }); // memory.copy
}

fn emitTile(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    if (!tile_samples) {
        try w.raw(&.{ 1, 1, 0x7f }); // (local $p i32) after the x and y parameters
        try emitPointPass(w, 2, 0, kernel_count);
        try w.byte(0x0b);
        w.endSize(at);
        return;
    }
    try w.raw(&.{ 1, 3, 0x7f }); // (local $row i32) (local $col i32) (local $p i32)
    // The host passes the buffer's top-left pixel, the core's minus the halo.
    try w.localGet(0);
    try w.raw(&.{ 0xfc, 0x00 }); // i32.trunc_sat_f32_s
    try globalSet(w, .x0);
    try w.localGet(1);
    try w.raw(&.{ 0xfc, 0x00 });
    try globalSet(w, .y0);
    // Point kernels before the first sampling kernel run on the whole buffer.
    var k: usize = 0;
    while (k < kernel_count and !kernel_samples[k]) k += 1;
    if (k > 0) try emitPointPass(w, TILE_P, 0, k);
    var inset: u32 = 0;
    while (k < kernel_count) {
        var end = k + 1;
        while (end < kernel_count and !kernel_samples[end]) end += 1;
        const read = inset;
        inset += kernel_halos[k];
        try emitSamplePass(w, k, end, read, inset);
        k = end;
    }
    try w.byte(0x0b);
    w.endSize(at);
}

// v = max(v, m) or min(v, m), signed.
fn emitKeep(w: *Buf, v: u32, m: u32, is_max: bool) CompileError!void {
    try w.localGet(v);
    try w.localGet(m);
    try w.localGet(v);
    try w.localGet(m);
    try w.byte(if (is_max) 0x4a else 0x48); // i32.gt_s or i32.lt_s
    try w.byte(0x1b); // select
    try w.localSet(v);
}

// out = the buffer index of pos + d, clamped to the image and then to the
// pass's read region.
fn emitSampleAxis(w: *Buf, d: u32, out: u32, at: TileState, origin: TileState, size: TileState) CompileError!void {
    const m: u32 = 4;
    try globalGet(w, at);
    try w.localGet(d);
    try w.byte(0x6a);
    try globalGet(w, origin);
    try w.byte(0x6a);
    try w.localSet(out);
    try globalGet(w, size);
    try w.i32Const(1);
    try w.byte(0x6b);
    try w.localSet(m);
    try emitKeep(w, out, m, false);
    try w.i32Const(0);
    try w.localSet(m);
    try emitKeep(w, out, m, true);
    try w.localGet(out);
    try globalGet(w, origin);
    try w.byte(0x6b);
    try w.localSet(out);
    try globalGet(w, .lo);
    try w.localSet(m);
    try emitKeep(w, out, m, true);
    try globalGet(w, .hi);
    try w.localSet(m);
    try emitKeep(w, out, m, false);
}

// sample(dx, dy) -> vec4f, reading the tile buffer.
fn emitSample(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    try w.raw(&.{ 1, 3, 0x7f }); // (local $col i32) (local $row i32) (local $m i32)
    try emitSampleAxis(w, 0, 2, .col, .x0, .width);
    try emitSampleAxis(w, 1, 3, .row, .y0, .height);
    try w.localGet(3);
    try w.i32Const(@intCast(tileSpan()));
    try w.byte(0x6c);
    try w.localGet(2);
    try w.byte(0x6a);
    try w.i32Const(4);
    try w.byte(0x74);
    try w.simd(SIMD_LOAD);
    try w.byte(4);
    try w.uleb(TILE_INPUT_PTR);
    try w.byte(0x0b);
    w.endSize(at);
}

fn emitSetWidthAndHeight(w: *Buf) CompileError!void {
    const at = try w.beginSize();
    try w.byte(0);
    try w.localGet(0);
    try w.raw(&.{ 0xfc, 0x00 }); // i32.trunc_sat_f32_s
    try globalSet(w, .width);
    try w.localGet(1);
    try w.raw(&.{ 0xfc, 0x00 });
    try globalSet(w, .height);
    try w.byte(0x0b);
    w.endSize(at);
}

// A Tile component that runs the pixel kernels in source order.
fn emitTileModule() CompileError!usize {
    var w = Buf{ .bytes = &output_buf };
    try w.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // Functions after the setters, in a module whose kernels sample.
    const extra: u32 = if (tile_samples) 2 else 0;
    const first_setter = firstKernelFn() + kernel_count;
    const fn_count = first_setter + override_count + extra;

    // Setter types keep their indices from emitModule (see setterType).
    try w.byte(1); // type section
    var at = try w.beginSize();
    try w.uleb(if (tile_samples) 7 else 6);
    try w.raw(&.{ 0x60, 0, 1, 0x7f }); // 0: () -> i32
    try w.raw(&.{ 0x60, 2, 0x7d, 0x7d, 0 }); // 1: (f32, f32) -> ()
    try w.raw(&.{ 0x60, 1, 0x7b, 1, 0x7b }); // 2: (v128) -> v128
    try w.raw(&.{ 0x60, 1, 0x7d, 1, 0x7d }); // 3: (f32) -> f32
    try w.raw(&.{ 0x60, 1, 0x7f, 1, 0x7f }); // 4: (i32) -> i32
    try w.raw(&.{ 0x60, 1, 0x7e, 1, 0x7e }); // 5: (i64) -> i64
    if (tile_samples) try w.raw(&.{ 0x60, 2, 0x7f, 0x7f, 1, 0x7b }); // 6: (i32, i32) -> v128
    w.endSize(at);

    try w.byte(3); // function section
    at = try w.beginSize();
    try w.uleb(fn_count);
    try w.raw(&.{ 0, 0, 1 });
    if (tile_samples) try w.byte(6);
    for (0..kernel_count) |_| try w.byte(2);
    for (overrides[0..override_count]) |o| try w.byte(setterType(o.ty));
    if (tile_samples) try w.raw(&.{ 0, 1 });
    w.endSize(at);

    try w.byte(5); // memory section: fixed size
    at = try w.beginSize();
    const pages: u32 = if (tile_samples) (scratchPtr() + tileBytes() + 0xffff) / 0x10000 else 1;
    try w.raw(&.{ 1, 1 });
    try w.uleb(pages);
    try w.uleb(pages);
    w.endSize(at);

    try w.byte(6); // global section
    at = try w.beginSize();
    const state_count: u32 = if (tile_samples) @typeInfo(TileState).@"enum".fields.len else 0;
    try w.uleb(1 + override_count + state_count);
    // Unused here; it keeps override globals at GLOBAL_FIRST_OVERRIDE.
    try w.raw(&.{ 0x7f, 0, 0x41, 0, 0x0b });
    for (overrides[0..override_count]) |o| {
        try w.raw(&.{ valType(o.ty), 1 });
        try emitLiteral(&w, o.value);
        try w.byte(0x0b);
    }
    for (0..state_count) |i| {
        const state: TileState = @enumFromInt(i);
        // Without uniform_set_width_and_height, samples clamp only to the tile.
        const initial: i32 = if (state == .width or state == .height) std.math.maxInt(i32) else 0;
        try w.raw(&.{ 0x7f, 1 });
        try w.i32Const(initial);
        try w.byte(0x0b);
    }
    w.endSize(at);

    try w.byte(7); // export section
    at = try w.beginSize();
    try w.uleb(4 + override_count + extra);
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
        try w.uleb(first_setter + i);
    }
    if (tile_samples) {
        try w.name("calculate_halo_px");
        try w.byte(0);
        try w.uleb(first_setter + override_count);
        try w.name("uniform_set_width_and_height");
        try w.byte(0);
        try w.uleb(first_setter + override_count + 1);
    }
    w.endSize(at);

    try w.byte(10); // code section
    at = try w.beginSize();
    try w.uleb(fn_count);
    try emitGetter(&w, TILE_INPUT_PTR);
    try emitGetter(&w, tileBytes());
    try emitTile(&w);
    if (tile_samples) try emitSample(&w);
    try w.raw(kernel_code_buf[0..kernel_code.len]);
    for (overrides[0..override_count], 0..) |o, i| try emitSetter(&w, @intCast(GLOBAL_FIRST_OVERRIDE + i), o.ty);
    if (tile_samples) {
        try emitGetter(&w, tile_halo);
        try emitSetWidthAndHeight(&w);
    }
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
    fragment_entry = false;
    in_fragment = false;
    texture_name = null;
    helper_count = 0;
    helper_code.len = 0;
    const_array_count = 0;
    const_data_len = 0;
    param_count = 1;
    return_ty = .void;
    allow_void_call = false;
    local_count = 0;
    scope_len = 0;
    block_len = 0;
    body.len = 0;
    kernel_count = 0;
    kernel_code.len = 0;
    in_kernel = false;
    tile_halo = 0;
    tile_samples = false;
    ir_node_len = 0;
    ir_stmt_len = 0;
    ir_complete = vectorize_invocations != 0;
    vectorized = false;
    byte_kernel = false;
    scalar_code.len = 0;
    try lex();
    stage_module = false;
    fragment_module = false;
    uses_derivatives = false;
    for (tokens[0..tok_count], tokens[1 .. tok_count + 1]) |at, word| {
        if (at.kind == .at and (isWord(word, "compute") or isWord(word, "fragment"))) stage_module = true;
        if (at.kind == .at and isWord(word, "fragment")) fragment_module = true;
    }
    if (fragment_module) for (tokens[0..tok_count], tokens[1 .. tok_count + 1]) |t, next| {
        const callee = if (t.kind == .ident and next.kind == .l_paren) lookupCallee(text(t)) else null;
        if (callee == .dpdx or callee == .dpdy or callee == .fwidth) uses_derivatives = true;
    };
    while (peek().kind != .eof) try parseTopLevel();
    if (texture_name) |t| if (!fragment_entry) return fail(t.start, .unsupported);
    if (kernel_count > 0) return emitTileModule();
    if (fragment_entry) {
        // `width` is the fragment module's own uniform.
        for (overrides[0..override_count]) |o| if (isWord(o.name, "width")) return fail(o.name.start, .name);
        return emitModule();
    }
    if (!have_entry or !output_buffer.declared) return fail(@intCast(source.len), .unsupported);
    if (ir_complete and input_buffer.declared) {
        const bytes = byteKernelEligible();
        if (bytes or invocationIndependent()) {
            // Keep the validated scalar function only for safe compilation fallback.
            emitFunction(&scalar_code) catch {
                scalar_code.len = 0;
                return emitModule();
            };
            vectorized = (if (bytes) emitByteBatch() else emitInvocationBatch()) catch false;
            byte_kernel = bytes and vectorized;
        }
    }
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
    defer vectorize_invocations = 0;
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

export fn uniform_set_vectorize_invocations(value: u32) u32 {
    vectorize_invocations = @intFromBool(value != 0);
    return vectorize_invocations;
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
        \\@compute @workgroup_size(1) fn main() { while (true) {} }
    ;
    try expectRejected(loop_shader, std.mem.indexOf(u8, loop_shader, "while").?, .unsupported);
    const sample = "@vertex fn main() {}";
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

test "rejects vec4u features outside the subset" {
    const head =
        \\@group(0) @binding(0) var<storage, read_write> v: array<u32>;
        \\@compute @workgroup_size(1) fn main() { let b = unpack4xU8(v[0]);
    ;
    const divide = head ++ " let a = b / vec4u(2u); }";
    try expectRejected(divide, std.mem.indexOf(u8, divide, "/").?, .unsupported);
    // WGSL splats a scalar only for arithmetic, not for bitwise operators,
    // shifts or comparisons.
    const scalar_and = head ++ " let a = b & 1u; }";
    try expectRejected(scalar_and, std.mem.indexOf(u8, scalar_and, "&").?, .type_mismatch);
    const scalar_compare = head ++ " let a = b < 13u; }";
    try expectRejected(scalar_compare, std.mem.indexOf(u8, scalar_compare, "< 13u").?, .type_mismatch);
    const three = head ++ " let a = b.xyz; }";
    try expectRejected(three, std.mem.indexOf(u8, three, "xyz").?, .unsupported);
    const mask_math = head ++ " let a = (b < b) + (b < b); }";
    try expectRejected(mask_math, std.mem.indexOf(u8, mask_math, "+").?, .type_mismatch);
    const pack_scalar = head ++ " let a = pack4xU8(1u); }";
    try expectRejected(pack_scalar, std.mem.indexOf(u8, pack_scalar, "pack4xU8(1").?, .type_mismatch);
    const buffer = "@group(0) @binding(0) var<storage, read_write> v: array<vec4u>;";
    try expectRejected(buffer, std.mem.indexOf(u8, buffer, "vec4u").?, .unsupported);
}

test "vectorizes byte shaders as i8x16 only when every stored byte agrees" {
    const rot13 =
        \\@group(0) @binding(0) var<storage, read> src: array<u32>;
        \\@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
        \\@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {
        \\  if (id.x >= arrayLength(&src)) { return; }
        \\  let b = unpack4xU8(src[id.x]);
        \\  let k = (b | vec4u(32u)) - vec4u(97u);
        \\  dst[id.x] = pack4xU8(b + select(vec4u(0u), select(vec4u(243u), vec4u(13u), k < vec4u(13u)), k < vec4u(26u)));
        \\}
    ;
    vectorize_invocations = 1;
    var size = try compile(rot13);
    try testing.expect(byte_kernel);
    try testing.expect(std.mem.indexOf(u8, output_buf[0..size], "qip.vectorize_invocations") != null);
    // A u32 shift by 8 clears the byte; an i8x16 shift counts modulo 8.
    const shift = std.mem.replaceOwned(u8, testing.allocator, rot13, "b + select", "(b >> vec4u(8u)) + select") catch unreachable;
    defer testing.allocator.free(shift);
    vectorize_invocations = 1;
    size = try compile(shift);
    try testing.expect(!byte_kernel and !vectorized);
    vectorize_invocations = 0;
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

test "derives a sampling module's halo from its constant offsets" {
    const shader =
        \\const R = 2;
        \\fn blur(c: vec4f) -> vec4f { return (sample(-1, 0) + c + sample(1, 1)) / 3.0; }
        \\fn darken(c: vec4f) -> vec4f { return c * 0.5; }
        \\fn wide(c: vec4f) -> vec4f { return sample(0, -R); }
    ;
    const size = try compile(shader);
    const module = output_buf[0..size];
    try testing.expectEqual(@as(u32, 3), tile_halo);
    try testing.expect(std.mem.indexOf(u8, module, "calculate_halo_px") != null);
    try testing.expect(std.mem.indexOf(u8, module, "uniform_set_width_and_height") != null);
    // sample(-1, 0) is i32.const -1, i32.const 0, call FN_SAMPLE.
    try testing.expect(std.mem.indexOf(u8, module, &.{ 0x41, 0x7f, 0x41, 0x00, 0x10, FN_SAMPLE }) != null);
}

test "rejects sample offsets that are not constant or are too far" {
    const runtime = "fn k(c: vec4f) -> vec4f { let d = 1; return sample(d, 0); }";
    try expectRejected(runtime, std.mem.indexOf(u8, runtime, "d, 0").?, .unsupported);
    const far = "fn k(c: vec4f) -> vec4f { return sample(0, -33); }";
    try expectRejected(far, std.mem.indexOf(u8, far, "33").?, .unsupported);
    const unsigned = "fn k(c: vec4f) -> vec4f { return sample(1u, 0); }";
    try expectRejected(unsigned, std.mem.indexOf(u8, unsigned, "1u").?, .type_mismatch);
    const total =
        \\fn a(c: vec4f) -> vec4f { return sample(20, 0); }
        \\fn b(c: vec4f) -> vec4f { return sample(0, 13); }
    ;
    try expectRejected(total, std.mem.lastIndexOf(u8, total, "sample").?, .unsupported);
    const compute =
        \\@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;
        \\@compute @workgroup_size(64) fn main() { v[0] = sample(0, 0); }
    ;
    try expectRejected(compute, std.mem.indexOf(u8, compute, "sample").?, .unsupported);
}

test "compiles a fragment shader with a texture and a width uniform" {
    const shader =
        \\override gain: f32 = 1.0;
        \\@group(0) @binding(0) var src: texture_2d<f32>;
        \\@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\  let size = vec2f(textureDimensions(src));
        \\  let p = vec2i(pos.xy) + vec2i(1, 0);
        \\  if pos.x > size.x - 1.0 { discard; }
        \\  return textureLoad(src, p, 0) * gain;
        \\}
    ;
    const size = try compile(shader);
    const module = output_buf[0..size];
    try testing.expect(std.mem.indexOf(u8, module, "uniform_set_gain") != null);
    try testing.expect(std.mem.indexOf(u8, module, "uniform_set_width") != null);
    // Without a texture, the input still sets the image size.
    _ = try compile("@fragment fn f() -> @location(0) vec4f { return vec4f(1.0); }");
}

test "rejects fragment shaders outside the subset" {
    const no_return = "@fragment fn f(@builtin(position) p: vec4f) -> @location(0) vec4f { let a = 1.0; }";
    try expectRejected(no_return, no_return.len - 1, .unsupported);
    const location1 = "@fragment fn f() -> @location(1) vec4f { return vec4f(); }";
    try expectRejected(location1, std.mem.indexOf(u8, location1, "1)").?, .unsupported);
    const varying = "@fragment fn f(@location(0) uv: vec2f) -> @location(0) vec4f { return vec4f(); }";
    try expectRejected(varying, std.mem.indexOf(u8, varying, "uv").?, .unsupported);
    const width = "override width: u32 = 1; @fragment fn f() -> @location(0) vec4f { return vec4f(); }";
    try expectRejected(width, 9, .name);
    const buffer =
        \\@group(0) @binding(0) var<storage, read> b: array<f32>;
        \\@fragment fn f() -> @location(0) vec4f { return vec4f(); }
    ;
    try expectRejected(buffer, std.mem.indexOf(u8, buffer, "@fragment").? + 10, .unsupported);
    const compute_texture =
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> v: array<f32>;
        \\@compute @workgroup_size(1) fn main() {}
    ;
    try expectRejected(compute_texture, std.mem.indexOf(u8, compute_texture, "t:").?, .unsupported);
    const ivec_divide = "@fragment fn f() -> @location(0) vec4f { let a = vec2i(4, 2) / 2; return vec4f(); }";
    try expectRejected(ivec_divide, std.mem.indexOf(u8, ivec_divide, "/").?, .unsupported);
    const ivec3 = "@fragment fn f() -> @location(0) vec4f { let a = vec2i(4, 2).xyx; return vec4f(); }";
    try expectRejected(ivec3, std.mem.indexOf(u8, ivec3, "xyx").?, .unsupported);
    const mixed = "@fragment fn f() -> @location(0) vec4f { let a = vec2i(4, 2u); return vec4f(); }";
    try expectRejected(mixed, std.mem.indexOf(u8, mixed, "vec2i").?, .type_mismatch);
    const unknown = "@fragment fn f() -> @location(0) vec4f { return textureLoad(t, vec2i(), 0); }";
    try expectRejected(unknown, std.mem.indexOf(u8, unknown, "t,").?, .name);
    const discard_compute =
        \\@group(0) @binding(0) var<storage, read_write> v: array<f32>;
        \\@compute @workgroup_size(1) fn main() { discard; }
    ;
    try expectRejected(discard_compute, std.mem.indexOf(u8, discard_compute, "discard").?, .unsupported);
}

test "smoothstep rejects equal constant edges but permits runtime and reversed edges" {
    const equal = [_][]const u8{
        "fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(0.0, 0.0, c.x)); }",
        "const EDGE = 0.5; fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(EDGE, 0.5, c.x)); }",
        "fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(0.25 + 0.25, 0.5, c.x)); }",
        "fn k(c: vec4f) -> vec4f { const edge = 0.5; return vec4f(smoothstep(edge, 0.5, c.x)); }",
        "fn k(c: vec4f) -> vec4f { return smoothstep(vec4f(0.0, 0.5, 0.0, 0.0), vec4f(1.0, 0.5, 1.0, 1.0), c); }",
    };
    for (equal) |shader| try expectRejected(shader, std.mem.indexOf(u8, shader, "smoothstep").?, .type_mismatch);
    _ = try compile("fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(1.0, 0.0, c.x)); }");
    _ = try compile("fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(c.x, c.x, c.y)); }");
    _ = try compile("override edge: f32 = 0.5; fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(edge, 0.5, c.x)); }");
}
