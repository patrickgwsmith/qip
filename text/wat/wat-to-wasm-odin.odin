// Assembles WebAssembly text format (WAT) into a binary module.
//
// This is an Odin port of `wat-to-wasm.zig` and is meant to produce the same
// bytes and the same rejections for every input. Like the Zig module, the
// output matches WABT 1.0.42 `wat2wasm` byte for byte for valid modules: the
// same type section order, the same element and data segment encodings,
// minimal LEB128 sizes, and no name section. The component is an assembler,
// not a validator. It rejects malformed text and unknown names, but it does
// not type-check instructions. Pipe the output into
// `application/wasm/wasm-validate-core-2.0.wasm` to validate it.
//
// Where WABT departs from the text spec, this follows WABT: raw control
// characters other than newline are allowed in strings, `\u{...}` takes no
// underscores, a single `memory.copy`/`table.copy` index is the destination,
// 32-bit limits are not range-checked, and a type index past the declared
// types is written as is.
//
// Supported: Core 2.0 (multi-value, reference types, bulk memory, SIMD),
// relaxed SIMD, tail calls, extended constant expressions, threads atomics,
// multi-memory and 64-bit memory limits. Not supported: exception handling,
// typed function references, GC, annotations, and `(module binary|quote)`.
//
// Folded instructions use an explicit frame stack, so there is no recursion.
//
// One difference from the Zig source, which does not change behaviour: the
// opcode table is built on the first call instead of at compile time.
package wat_to_wasm_odin

import "base:intrinsics"

INPUT_CAP :: 1 << 20
// Every construct produces fewer output bytes than the text that spells it,
// except fixed section overhead. Twice the input leaves a wide margin; the
// write guard still reports `limit` if a module ever exceeds it.
OUTPUT_CAP :: 2 * INPUT_CAP + 64
CODE_CAP :: OUTPUT_CAP
MAX_FUNCS :: 1 << 16
MAX_TYPES :: 1 << 16
TYPE_POOL_CAP :: 1 << 19
SIG_SLOTS :: 2 * MAX_TYPES
NAME_SLOTS :: 1 << 17
MAX_NAMES :: NAME_SLOTS / 2
// WABT has no nesting or locals limits, so these are sized so that no input
// within INPUT_CAP can reach them. A named local takes at least 14 bytes
// (`(local $a i32)`), an unnamed one 4 (`i32 `), a folded instruction level
// 4 (`(br` and `)`), and a label 6 (`(loop` and `)`).
MAX_NAMED_LOCALS :: INPUT_CAP / 14 + 1
LOCAL_SLOTS :: 1 << 17
MAX_LOCALS :: INPUT_CAP / 4 + 1
MAX_DEPTH :: INPUT_CAP / 4 + 1
MAX_LABELS :: INPUT_CAP / 6 + 1
FLOAT_TEXT_CAP :: 1 << 12

output_content_type := "application/wasm"

input_buf: [INPUT_CAP]u8
output_buf: [OUTPUT_CAP]u8
code_buf: [CODE_CAP]u8

// ---------------------------------------------------------------------------
// Failure reporting

Failure :: enum u32 {
	// Malformed text: an unexpected token, comment, string or instruction.
	Syntax      = 0,
	// An unknown or duplicate `$name`, or a type index outside the declared
	// types when an inline signature has to be checked against it. Other
	// out-of-range indices are left to validation.
	Name        = 1,
	// A number that is malformed or out of range for its type.
	Number      = 2,
	// Valid text for a feature this assembler does not implement.
	Unsupported = 3,
	// The module exceeds one of the fixed capacities.
	Limit       = 4,
}
FAILURE_MODES :: 5

fail_offset: u32
fail_mode: Failure

// Records the failure and returns false, the "rejected" value that every
// fallible procedure here returns last and propagates with `or_return`.
fail :: proc "contextless" (offset: int, mode: Failure) -> bool {
	fail_offset = u32(offset)
	fail_mode = mode
	return false
}

// ---------------------------------------------------------------------------
// Lexer

Kind :: enum u8 {
	LParen,
	RParen,
	Keyword,
	Id,
	Num,
	String,
	Reserved,
	EOF,
}

Tok :: struct {
	kind:  Kind,
	start: int,
	end:   int,
}

src: []u8
pos: int

text :: #force_inline proc "contextless" (t: Tok) -> string {
	return string(src[t.start:t.end])
}

// Inlined so that a comparison against a literal checks its length first and
// never leaves the caller; most keyword tests fail on the length alone.
str_eq :: #force_inline proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}

load64 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return intrinsics.unaligned_load((^u64)(p))
}

load32 :: #force_inline proc "contextless" (p: [^]u8) -> u32 {
	return intrinsics.unaligned_load((^u32)(p))
}

// The `n` bytes at `p`, 1 to 7 of them, as one word, without reading past
// them.
load_tail :: #force_inline proc "contextless" (p: [^]u8, n: int) -> u64 {
	if n >= 4 { return u64(load32(p)) | u64(load32(p[n - 4:])) << uint(8 * (n - 4)) }
	return u64(p[0]) | u64(p[n >> 1]) << 8 | u64(p[n - 1]) << 16
}

// Hashes names and keywords a word at a time; they are mostly short enough
// to take one or two steps.
hash_bytes :: proc "contextless" (seed: u32, s: string) -> u32 {
	K :: 0x9e3779b97f4a7c15
	p := raw_data(s)
	n := len(s)
	h := (u64(seed) << 32 | u64(n)) * K
	for ; n >= 8; n -= 8 {
		h = (h ~ load64(p)) * K
		h ~= h >> 32
		p = p[8:]
	}
	if n > 0 {
		h = (h ~ load_tail(p, n)) * K
		h ~= h >> 32
	}
	return u32((h * K) >> 32)
}

eql_bytes :: proc "contextless" (a, b: string) -> bool {
	n := len(a)
	if n != len(b) { return false }
	pa := raw_data(a)
	pb := raw_data(b)
	if n < 8 { return n == 0 || load_tail(pa, n) == load_tail(pb, n) }
	for i := 0; i + 8 < n; i += 8 {
		if load64(pa[i:]) != load64(pb[i:]) { return false }
	}
	return load64(pa[n - 8:]) == load64(pb[n - 8:])
}

has_prefix :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && str_eq(s[:len(prefix)], prefix)
}

C_ID :: 1
C_SPACE :: 2
// Bytes that end a run of plain string characters: `"`, `\`, newline and
// anything outside ASCII.
C_STR_STOP :: 4

// A table rather than a switch: every input byte is classified at least once,
// and the lookup inlines where a switch became a call.
@(rodata)
char_class := [256]u8 {
	'0' ..= '9' = C_ID, 'A' ..= 'Z' = C_ID, 'a' ..= 'z' = C_ID,
	'!' = C_ID, '#' = C_ID, '$' = C_ID, '%' = C_ID, '&' = C_ID, '\'' = C_ID, '*' = C_ID, '+' = C_ID,
	'-' = C_ID, '.' = C_ID, '/' = C_ID, ':' = C_ID, '<' = C_ID, '=' = C_ID, '>' = C_ID, '?' = C_ID,
	'@' = C_ID, '^' = C_ID, '_' = C_ID, '`' = C_ID, '|' = C_ID, '~' = C_ID,
	'\\' = C_ID | C_STR_STOP, '"' = C_STR_STOP, '\n' = C_SPACE | C_STR_STOP,
	' ' = C_SPACE, '\t' = C_SPACE, '\r' = C_SPACE,
	0x80 ..= 0xff = C_STR_STOP,
}

is_idchar :: #force_inline proc "contextless" (c: u8) -> bool {
	return char_class[c] & C_ID != 0
}

// Returns the length of the well-formed UTF-8 sequence at `i`, or 0 when the
// bytes there are truncated, overlong, a surrogate or beyond U+10FFFF.
utf8_seq_len :: proc "contextless" (s: []u8, i: int) -> int {
	cont :: #force_inline proc "contextless" (b: u8) -> bool {
		return b & 0xc0 == 0x80
	}
	n := len(s)
	b := s[i]
	switch {
	case b < 0x80:
		return 1
	case b >= 0xc2 && b <= 0xdf:
		if i + 1 < n && cont(s[i + 1]) { return 2 }
	case b >= 0xe0 && b <= 0xef:
		if i + 2 >= n || !cont(s[i + 1]) || !cont(s[i + 2]) { return 0 }
		if b == 0xe0 && s[i + 1] < 0xa0 { return 0 }
		if b == 0xed && s[i + 1] >= 0xa0 { return 0 }
		return 3
	case b >= 0xf0 && b <= 0xf4:
		if i + 3 >= n || !cont(s[i + 1]) || !cont(s[i + 2]) || !cont(s[i + 3]) { return 0 }
		if b == 0xf0 && s[i + 1] < 0x90 { return 0 }
		if b == 0xf4 && s[i + 1] >= 0x90 { return 0 }
		return 4
	}
	return 0
}

utf8_valid :: proc "contextless" (s: []u8) -> bool {
	i := 0
	for i < len(s) {
		n := utf8_seq_len(s, i)
		if n == 0 { return false }
		i += n
	}
	return true
}

skip_space :: proc "contextless" () -> bool {
	s := raw_data(src)
	n := len(src)
	p := pos
	for {
		for p < n && char_class[s[p]] & C_SPACE != 0 { p += 1 }
		if p + 1 >= n || s[p + 1] != ';' { break }
		if s[p] == ';' {
			// A line comment ends at LF, CR or CRLF.
			p += 2
			for p < n && s[p] != '\n' && s[p] != '\r' { p += 1 }
		} else if s[p] == '(' {
			start := p
			depth := 1
			p += 2
			for depth > 0 {
				if p + 1 >= n { return fail(start, .Syntax) }
				if s[p] == '(' && s[p + 1] == ';' {
					depth += 1
					p += 2
				} else if s[p] == ';' && s[p + 1] == ')' {
					depth -= 1
					p += 2
				} else {
					p += 1
				}
			}
		} else {
			break
		}
	}
	pos = p
	return true
}

// Every token is lexed once, before parsing starts. The parser looks ahead
// by rewinding `pos` and later passes revisit whole fields, so each token is
// recorded under the two positions `next` can be asked for it from: where the
// previous token ended and where the token itself starts.
Tok_Entry :: struct {
	start:    u32,
	// The kind in the top byte. Below it, the end offset, except for `(`,
	// which always ends at `start + 1`: there it is the offset just past
	// the matching `)`, or 0 when there is none.
	end_kind: u32,
}
TOK_LOW :: 0xffffff
LPAREN_BITS :: u32(Kind.LParen) << 24
tok_cache: [INPUT_CAP + 1]Tok_Entry
// Positions below this have an entry for the current input. A lexical error
// stops the scan here and is reported when the parser reaches it, so that
// errors still come in the order the parser meets them.
lexed_upto: int
lex_fail_offset: u32
lex_fail_mode: Failure

lex_all :: proc "contextless" () {
	pos = 0
	at := 0
	// Open parentheses form a list through their own entries until matched.
	open: u32 = 0
	open_depth := 0
	for {
		t, ok := lex()
		if !ok {
			lexed_upto = at
			lex_fail_offset = fail_offset
			lex_fail_mode = fail_mode
			break
		}
		low := u32(t.end)
		if t.kind == .LParen {
			low = open
			open = u32(t.start)
			open_depth += 1
		} else if t.kind == .RParen && open_depth > 0 {
			link := tok_cache[open].end_kind & TOK_LOW
			tok_cache[open].end_kind = LPAREN_BITS | u32(t.end)
			open = link
			open_depth -= 1
		}
		e := Tok_Entry{u32(t.start), u32(t.kind) << 24 | low}
		tok_cache[at] = e
		tok_cache[t.start] = e
		if t.kind == .EOF {
			lexed_upto = len(src) + 1
			break
		}
		at = t.end
	}
	for ; open_depth > 0; open_depth -= 1 {
		link := tok_cache[open].end_kind & TOK_LOW
		tok_cache[open].end_kind = LPAREN_BITS
		open = link
	}
}

// The offset just past the `)` matching the `(` at `start`, or 0.
match_end :: #force_inline proc "contextless" (start: int) -> int {
	return int(tok_cache[start].end_kind & TOK_LOW)
}

next :: proc "contextless" () -> (res: Tok, ok: bool) {
	at := pos
	if at >= lexed_upto {
		fail(int(lex_fail_offset), lex_fail_mode)
		return
	}
	e := tok_cache[at]
	kind := Kind(e.end_kind >> 24)
	end := int(e.start + 1 if kind == .LParen else e.end_kind & TOK_LOW)
	pos = end
	return Tok{kind, int(e.start), end}, true
}

lex :: proc "contextless" () -> (res: Tok, ok: bool) {
	skip_space() or_return
	s := raw_data(src)
	n := len(src)
	start := pos
	if start >= n { return Tok{.EOF, start, start}, true }
	c := s[start]
	p := start + 1
	switch c {
	case '(':
		if p < n && s[p] == '@' {
			fail(start, .Unsupported)
			return
		}
		pos = p
		return Tok{.LParen, start, p}, true
	case ')':
		pos = p
		return Tok{.RParen, start, p}, true
	case '"':
		for {
			for p < n && char_class[s[p]] & C_STR_STOP == 0 { p += 1 }
			if p >= n {
				fail(start, .Syntax)
				return
			}
			ch := s[p]
			if ch == '"' { break }
			// Like WABT, only a raw newline ends a string in error; other
			// control characters pass through although the spec forbids them.
			if ch == '\n' {
				fail(p, .Syntax)
				return
			}
			if ch >= 0x80 {
				// Unescaped characters must be valid UTF-8; only escapes
				// may spell arbitrary bytes.
				seq := utf8_seq_len(src, p)
				if seq == 0 {
					fail(p, .Syntax)
					return
				}
				p += seq
				continue
			}
			p += 2 // A backslash and the character it escapes.
		}
		p += 1
		// A token must end at whitespace, a parenthesis or a comment.
		if p < n && (s[p] == '"' || is_idchar(s[p])) {
			fail(p, .Syntax)
			return
		}
		pos = p
		return Tok{.String, start, p}, true
	}
	if !is_idchar(c) {
		fail(start, .Syntax)
		return
	}
	for p < n && is_idchar(s[p]) { p += 1 }
	if p < n && s[p] == '"' {
		fail(p, .Syntax)
		return
	}
	kind: Kind
	switch c {
	case '$':
		kind = .Id if p - start > 1 else .Reserved
	case 'a' ..= 'z':
		kind = .Keyword
	case '0' ..= '9', '+', '-':
		kind = .Num
	case:
		kind = .Reserved
	}
	pos = p
	return Tok{kind, start, p}, true
}

peek :: proc "contextless" () -> (res: Tok, ok: bool) {
	save := pos
	res, ok = next()
	pos = save
	return
}

is_kw :: proc "contextless" (t: Tok, s: string) -> bool {
	return t.kind == .Keyword && str_eq(text(t), s)
}

is_var :: proc "contextless" (t: Tok) -> bool {
	return t.kind == .Id || t.kind == .Num
}

expect :: proc "contextless" (kind: Kind) -> (res: Tok, ok: bool) {
	res = next() or_return
	if res.kind != kind {
		fail(res.start, .Syntax)
		return
	}
	return res, true
}

// True when the next tokens are `(` followed by keyword `s`.
peek_form :: proc "contextless" (s: string) -> (res: bool, ok: bool) {
	save := pos
	defer pos = save
	first := next() or_return
	if first.kind != .LParen { return false, true }
	second := next() or_return
	return is_kw(second, s), true
}

peek_form_at :: proc "contextless" (at: int, s: string) -> (res: bool, ok: bool) {
	save := pos
	pos = at
	res, ok = peek_form(s)
	pos = save
	return
}

// Consumes `( s` when the next tokens are that form.
open_form :: proc "contextless" (s: string) -> (res: bool, ok: bool) {
	if !(peek_form(s) or_return) { return false, true }
	_ = next() or_return
	_ = next() or_return
	return true, true
}

// Skips to just after the `)` that closes the current form.
skip_balanced :: proc "contextless" () -> bool {
	depth := 1
	for depth > 0 {
		t := next() or_return
		#partial switch t.kind {
		case .LParen:
			if m := match_end(t.start); m != 0 {
				pos = m
			} else {
				depth += 1
			}
		case .RParen:
			depth -= 1
		case .EOF:
			return fail(t.start, .Syntax)
		}
	}
	return true
}

opt_id :: proc "contextless" () -> (res: Tok, found: bool, ok: bool) {
	t := peek() or_return
	if t.kind != .Id { return {}, false, true }
	_ = next() or_return
	return t, true, true
}

// ---------------------------------------------------------------------------
// Numbers

digit_value :: proc "contextless" (c: u8) -> u8 {
	switch c {
	case '0' ..= '9':
		return c - '0'
	case 'a' ..= 'f':
		return c - 'a' + 10
	case 'A' ..= 'F':
		return c - 'A' + 10
	}
	return 255
}

// Parses `num` or `0x hexnum`, with `_` allowed only between digits.
parse_nat :: proc "contextless" (s: string) -> (value: u64, valid: bool) {
	i := 0
	base: u64 = 10
	if len(s) > 2 && s[0] == '0' && s[1] == 'x' {
		base = 16
		i = 2
	}
	if i >= len(s) { return 0, false }
	after_digit := false
	for ; i < len(s); i += 1 {
		c := s[i]
		if c == '_' {
			if !after_digit { return 0, false }
			after_digit = false
			continue
		}
		d := u64(digit_value(c))
		if d >= base { return 0, false }
		if value > (max(u64) - d) / base { return 0, false }
		value = value * base + d
		after_digit = true
	}
	if !after_digit { return 0, false }
	return value, true
}

nat_tok :: proc "contextless" (t: Tok) -> (res: u64, ok: bool) {
	if t.kind != .Num {
		fail(t.start, .Syntax)
		return
	}
	v, valid := parse_nat(text(t))
	if !valid {
		fail(t.start, .Number)
		return
	}
	return v, true
}

u32_tok :: proc "contextless" (t: Tok) -> (res: u32, ok: bool) {
	v := nat_tok(t) or_return
	if v > u64(max(u32)) {
		fail(t.start, .Number)
		return
	}
	return u32(v), true
}

// Parses an `iN` literal and returns its two's-complement bit pattern.
int_tok :: proc "contextless" (t: Tok, bits: uint) -> (res: u64, ok: bool) {
	if t.kind != .Num {
		fail(t.start, .Syntax)
		return
	}
	s := text(t)
	negative := false
	if s[0] == '+' || s[0] == '-' {
		negative = s[0] == '-'
		s = s[1:]
	}
	magnitude, valid := parse_nat(s)
	if !valid {
		fail(t.start, .Number)
		return
	}
	mask: u64 = max(u64) if bits == 64 else (u64(1) << bits) - 1
	if negative {
		if magnitude > u64(1) << (bits - 1) {
			fail(t.start, .Number)
			return
		}
		return (0 - magnitude) & mask, true
	}
	if magnitude > mask {
		fail(t.start, .Number)
		return
	}
	return magnitude, true
}

// Parses an `fN` literal and returns its bit pattern in the low bits.
float_tok :: proc "contextless" (t: Tok, is64: bool) -> (res: u64, ok: bool) {
	mant_bits: uint = 52 if is64 else 23
	exp_bits: uint = 11 if is64 else 8
	exp_mask: u64 = 0x7ff0000000000000 if is64 else 0x7f800000
	sign_bit: u64 = u64(1) << (63 if is64 else 31)
	mant_mask: u64 = (u64(1) << mant_bits) - 1

	if t.kind != .Num && t.kind != .Keyword {
		fail(t.start, .Syntax)
		return
	}
	s := text(t)
	negative := false
	if s[0] == '+' || s[0] == '-' {
		negative = s[0] == '-'
		s = s[1:]
	}
	bits: u64
	if s == "inf" {
		bits = exp_mask
	} else if s == "nan" {
		bits = exp_mask | (u64(1) << (mant_bits - 1))
	} else if has_prefix(s, "nan:0x") {
		payload, valid := parse_nat(s[4:])
		if !valid || payload == 0 || payload > mant_mask {
			fail(t.start, .Number)
			return
		}
		bits = exp_mask | payload
	} else if len(s) > 2 && s[0] == '0' && s[1] == 'x' {
		v, err := hex_float_bits(s[2:], mant_bits, exp_bits)
		if err != .None {
			fail(t.start, .Syntax if err == .Syntax else .Number)
			return
		}
		bits = v
	} else {
		if !decimal_float_syntax(s) {
			fail(t.start, .Syntax)
			return
		}
		chars := 0
		for i in 0 ..< len(s) {
			if s[i] != '_' { chars += 1 }
		}
		if chars > FLOAT_TEXT_CAP {
			fail(t.start, .Limit)
			return
		}
		v, overflow := decimal_float_bits(s, mant_bits, exp_bits)
		if overflow {
			fail(t.start, .Number)
			return
		}
		bits = v
	}
	if negative { bits |= sign_bit }
	return bits, true
}

// Checks a decimal float: `num ('.' num?)? ([eE] [+-]? num)?`.
decimal_float_syntax :: proc "contextless" (s: string) -> bool {
	i, valid := digit_run(s, 0, 10)
	if !valid { return false }
	if i < len(s) && s[i] == '.' {
		i += 1
		if i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i, valid = digit_run(s, i, 10)
			if !valid { return false }
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') { i += 1 }
		i, valid = digit_run(s, i, 10)
		if !valid { return false }
	}
	return i == len(s)
}

// Returns the end of a digit run with `_` only between digits.
digit_run :: proc "contextless" (s: string, start: int, base: u8) -> (end: int, valid: bool) {
	i := start
	after_digit := false
	for ; i < len(s); i += 1 {
		if s[i] == '_' {
			if !after_digit { return 0, false }
			after_digit = false
		} else if digit_value(s[i]) < base {
			after_digit = true
		} else {
			break
		}
	}
	if !after_digit { return 0, false }
	return i, true
}

Hex_Float_Error :: enum u8 {
	None,
	Syntax,
	Range,
}

// Converts `hexnum ('.' hexfrac?)? ([pP] [+-]? num)?` with round-to-nearest,
// ties-to-even. Returns the unsigned bit pattern for the target format.
hex_float_bits :: proc "contextless" (s: string, mant_bits, exp_bits: uint) -> (bits: u64, err: Hex_Float_Error) {
	m: u64 = 0
	e: i64 = 0
	sticky := false
	i := 0

	int_end, int_valid := digit_run(s, 0, 16)
	if !int_valid { return 0, .Syntax }
	for ; i < int_end; i += 1 {
		if s[i] == '_' { continue }
		d := u64(digit_value(s[i]))
		if m >> 60 == 0 {
			m = m * 16 + d
		} else {
			e += 4
			if d != 0 { sticky = true }
		}
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		if i < len(s) && digit_value(s[i]) < 16 {
			frac_end, frac_valid := digit_run(s, i, 16)
			if !frac_valid { return 0, .Syntax }
			for ; i < frac_end; i += 1 {
				if s[i] == '_' { continue }
				d := u64(digit_value(s[i]))
				if m >> 60 == 0 {
					m = m * 16 + d
					e -= 4
				} else if d != 0 {
					sticky = true
				}
			}
		}
	}
	if i < len(s) && (s[i] == 'p' || s[i] == 'P') {
		i += 1
		exp_negative := false
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			exp_negative = s[i] == '-'
			i += 1
		}
		exp_end, exp_valid := digit_run(s, i, 10)
		if !exp_valid { return 0, .Syntax }
		exp: i64 = 0
		for ; i < exp_end; i += 1 {
			if s[i] == '_' { continue }
			if exp < 1 << 24 { exp = exp * 10 + i64(s[i] - '0') }
		}
		e += -exp if exp_negative else exp
	}
	if i != len(s) { return 0, .Syntax }
	if m == 0 { return 0, .None }

	bias: i64 = (i64(1) << (exp_bits - 1)) - 1
	emin: i64 = 1 - bias
	top: i64 = 63 - i64(intrinsics.count_leading_zeros(m))
	exponent: i64 = top + e
	shift: i64 = top - i64(mant_bits)
	if exponent < emin { shift += emin - exponent }

	q: u64 = 0
	if shift > 64 {
		q = 0
	} else if shift == 64 {
		// Everything is below the rounding point and the quotient is even.
		half := u64(1) << 63
		if m > half || (m == half && sticky) { q = 1 }
	} else if shift > 0 {
		sh := uint(shift)
		rem := m & ((u64(1) << sh) - 1)
		half := u64(1) << (sh - 1)
		q = m >> sh
		if rem > half || (rem == half && (sticky || q & 1 == 1)) { q += 1 }
	} else {
		q = m << uint(-shift)
	}

	if exponent < emin { return q, .None } 	// Subnormal; q == 2^mant_bits is the smallest normal.
	if q == u64(1) << (mant_bits + 1) {
		q >>= 1
		exponent += 1
	}
	if exponent > bias { return 0, .Range }
	biased := u64(exponent + bias)
	return (biased << mant_bits) | (q & ((u64(1) << mant_bits) - 1)), .None
}

// Decimal floats are converted exactly: the digits are held as a decimal
// fraction `0.d0 d1 d2 ... x 10^dp` and multiplied or divided by powers of
// two until the mantissa can be read off, so no digit is ever dropped and
// the result is correctly rounded for any length of input. A literal has at
// most FLOAT_TEXT_CAP digits and each halving adds at most one, with fewer
// than 1300 halvings for a value in range.
DEC_CAP :: FLOAT_TEXT_CAP + 4096

dec_d: [DEC_CAP]u8
dec_nd: int
dec_dp: int

dec_trim :: proc "contextless" () {
	for dec_nd > 0 && dec_d[dec_nd - 1] == 0 { dec_nd -= 1 }
	if dec_nd == 0 { dec_dp = 0 }
}

// Divides by 2^k, for k up to 56.
dec_shift_right :: proc "contextless" (k: uint) {
	r := 0
	w := 0
	n: u64 = 0
	for ; n >> k == 0; r += 1 {
		if r >= dec_nd {
			if n == 0 {
				dec_nd = 0
				dec_dp = 0
				return
			}
			for n >> k == 0 {
				n *= 10
				r += 1
			}
			break
		}
		n = n * 10 + u64(dec_d[r])
	}
	dec_dp -= r - 1
	mask: u64 = (u64(1) << k) - 1
	for ; r < dec_nd; r += 1 {
		c := u64(dec_d[r])
		dec_d[w] = u8(n >> k)
		w += 1
		n = (n & mask) * 10 + c
	}
	for n > 0 && w < DEC_CAP {
		dec_d[w] = u8(n >> k)
		w += 1
		n = (n & mask) * 10
	}
	dec_nd = w
	dec_trim()
}

// Multiplies by 2^k, for k up to 56.
dec_shift_left :: proc "contextless" (k: uint) {
	carry: u64 = 0
	for i := dec_nd - 1; i >= 0; i -= 1 {
		n := (u64(dec_d[i]) << k) + carry
		q := n / 10
		dec_d[i] = u8(n - q * 10)
		carry = q
	}
	if carry > 0 {
		extra := 0
		for c := carry; c > 0; c /= 10 { extra += 1 }
		intrinsics.mem_copy(&dec_d[extra], &dec_d[0], dec_nd)
		for i := extra - 1; i >= 0; i -= 1 {
			q := carry / 10
			dec_d[i] = u8(carry - q * 10)
			carry = q
		}
		dec_nd += extra
		dec_dp += extra
	}
	dec_trim()
}

dec_shift :: proc "contextless" (k: int) {
	n := k
	for n > 0 {
		step := min(n, 56)
		dec_shift_left(uint(step))
		n -= step
	}
	for n < 0 {
		step := min(-n, 56)
		dec_shift_right(uint(step))
		n += step
	}
}

// Rounds the decimal to an integer, ties to even.
dec_rounded_integer :: proc "contextless" () -> u64 {
	n: u64 = 0
	i := 0
	for ; i < dec_dp && i < dec_nd; i += 1 { n = n * 10 + u64(dec_d[i]) }
	for ; i < dec_dp; i += 1 { n *= 10 }
	if dec_dp >= 0 && dec_dp < dec_nd {
		up := dec_d[dec_dp] >= 5
		// Trailing zeros are trimmed, so a lone 5 is exactly halfway.
		if dec_d[dec_dp] == 5 && dec_dp + 1 == dec_nd {
			up = dec_dp > 0 && dec_d[dec_dp - 1] & 1 == 1
		}
		if up { n += 1 }
	}
	return n
}

// Converts a decimal float whose syntax has been checked. Values too small
// to represent round to zero; values too large report overflow.
decimal_float_bits :: proc "contextless" (s: string, mant_bits, exp_bits: uint) -> (bits: u64, overflow: bool) {
	POWTAB := [9]int{1, 3, 6, 9, 13, 16, 19, 23, 26}

	dec_nd = 0
	dec_dp = 0
	saw_dot := false
	i := 0
	for ; i < len(s); i += 1 {
		c := s[i]
		if c == '_' { continue }
		if c == '.' {
			saw_dot = true
			dec_dp = dec_nd
			continue
		}
		if c < '0' || c > '9' { break }
		if c == '0' && dec_nd == 0 {
			dec_dp -= 1
			continue
		}
		dec_d[dec_nd] = c - '0'
		dec_nd += 1
	}
	if !saw_dot { dec_dp = dec_nd }
	if i < len(s) {
		i += 1
		exp_negative := false
		if s[i] == '+' || s[i] == '-' {
			exp_negative = s[i] == '-'
			i += 1
		}
		e := 0
		for ; i < len(s); i += 1 {
			if s[i] == '_' { continue }
			if e < 100000 { e = e * 10 + int(s[i] - '0') }
		}
		dec_dp += -e if exp_negative else e
	}
	dec_trim()

	if dec_nd == 0 { return 0, false }
	if dec_dp > 310 { return 0, true }
	if dec_dp < -330 { return 0, false }

	bias := (1 << (exp_bits - 1)) - 1
	emin := 1 - bias
	exp := 0
	// Scale into [0.5, 1), tracking the binary exponent.
	for dec_dp > 0 {
		n := 27 if dec_dp >= len(POWTAB) else POWTAB[dec_dp]
		dec_shift(-n)
		exp += n
	}
	for dec_dp < 0 || (dec_dp == 0 && dec_d[0] < 5) {
		n := 27 if -dec_dp >= len(POWTAB) else POWTAB[-dec_dp]
		dec_shift(n)
		exp -= n
	}
	// Now in [1, 2).
	exp -= 1
	if exp < emin {
		n := emin - exp
		dec_shift(-n)
		exp += n
	}
	if exp > bias { return 0, true }
	dec_shift(int(1 + mant_bits))
	mant := dec_rounded_integer()
	if mant == u64(2) << mant_bits {
		mant >>= 1
		exp += 1
		if exp > bias { return 0, true }
	}
	biased := u64(exp + bias)
	// Subnormal.
	if mant & (u64(1) << mant_bits) == 0 { biased = 0 }
	return (biased << mant_bits) | (mant & ((u64(1) << mant_bits) - 1)), false
}

// ---------------------------------------------------------------------------
// Output

Out :: struct {
	buf: []u8,
	len: int,
	// Bytes from `top` to the end of `buf` are the encoded folded
	// instructions that are still waiting for their operands.
	top: int,
}

out_init :: proc "contextless" (buf: []u8) -> Out {
	return Out{buf, 0, len(buf)}
}

put :: proc "contextless" (o: ^Out, b: u8) -> bool {
	if o.len >= o.top { return fail(pos, .Limit) }
	o.buf[o.len] = b
	o.len += 1
	return true
}

put_bytes :: proc "contextless" (o: ^Out, s: []u8) -> bool {
	if len(s) > o.top - o.len { return fail(pos, .Limit) }
	if len(s) > 0 {
		intrinsics.mem_copy_non_overlapping(&o.buf[o.len], raw_data(s), len(s))
	}
	o.len += len(s)
	return true
}

put3 :: proc "contextless" (o: ^Out, a, b, c: u8) -> bool {
	put(o, a) or_return
	put(o, b) or_return
	return put(o, c)
}

uleb_u64 :: proc "contextless" (o: ^Out, value: u64) -> bool {
	v := value
	for {
		b := u8(v & 0x7f)
		v >>= 7
		if v == 0 { return put(o, b) }
		put(o, b | 0x80) or_return
	}
}

uleb_u32 :: proc "contextless" (o: ^Out, value: u32) -> bool {
	return uleb_u64(o, u64(value))
}

uleb_int :: proc "contextless" (o: ^Out, value: int) -> bool {
	return uleb_u64(o, u64(value))
}

uleb :: proc {
	uleb_u64,
	uleb_u32,
	uleb_int,
}

sleb :: proc "contextless" (o: ^Out, value: i64) -> bool {
	v := value
	for {
		b := u8(v & 0x7f)
		v >>= 7
		done := (v == 0 && b & 0x40 == 0) || (v == -1 && b & 0x40 != 0)
		if done { return put(o, b) }
		put(o, b | 0x80) or_return
	}
}

uint_le :: proc "contextless" (o: ^Out, value: u64, n: uint) -> bool {
	for i: uint = 0; i < n; i += 1 {
		put(o, u8(value >> (8 * i))) or_return
	}
	return true
}

// Reserves room for a size prefix. `end_size` writes the minimal LEB128.
begin_size :: proc "contextless" (o: ^Out) -> (start: int, ok: bool) {
	if o.top - o.len < 5 {
		fail(pos, .Limit)
		return
	}
	start = o.len
	o.len += 5
	return start, true
}

end_size :: proc "contextless" (o: ^Out, start: int) {
	size := o.len - start - 5
	leb: [5]u8
	n := 0
	v := u32(size)
	for {
		b := u8(v & 0x7f)
		v >>= 7
		if v == 0 {
			leb[n] = b
			n += 1
			break
		}
		leb[n] = b | 0x80
		n += 1
	}
	base := raw_data(o.buf)
	for i in 0 ..< n { base[start + i] = leb[i] }
	if size > 0 {
		intrinsics.mem_copy(&base[start + n], &base[start + 5], size)
	}
	o.len -= 5 - n
}

// Moves the bytes written since `from` onto the pending stack and returns
// how many there were. They always fit: they already lie below `top`.
stash :: proc "contextless" (o: ^Out, from: int) -> int {
	n := o.len - from
	base := raw_data(o.buf)
	for i := n - 1; i >= 0; i -= 1 { base[o.top - n + i] = base[from + i] }
	o.top -= n
	o.len = from
	return n
}

// Appends the newest `n` pending bytes to the output.
unstash :: proc "contextless" (o: ^Out, n: int) {
	base := raw_data(o.buf)
	for i in 0 ..< n { base[o.len + i] = base[o.top + i] }
	o.len += n
	o.top += n
}

// ---------------------------------------------------------------------------
// Names

Space :: enum u8 {
	Type,
	Func,
	Table,
	Memory,
	Global,
	Elem,
	Data,
	Local,
}

Name_Slot :: struct {
	start: u32,
	meta:  u32,
	index: u32,
	gen:   u32,
}

Name_Table :: struct {
	slots: []Name_Slot,
	gen:   u32,
	count: int,
	cap:   int,
}

name_slots: [NAME_SLOTS]Name_Slot
local_slots: [LOCAL_SLOTS]Name_Slot
names: Name_Table
locals: Name_Table

table_reset :: proc "contextless" (table: ^Name_Table) {
	table.gen += 1
	if table.gen == 0 {
		for &slot in table.slots { slot = {} }
		table.gen = 1
	}
	table.count = 0
}

name_hash :: proc "contextless" (space: Space, s: string) -> u32 {
	return hash_bytes(u32(space), s)
}

name_matches :: proc "contextless" (slot: Name_Slot, space: Space, s: string) -> bool {
	if slot.meta != (u32(len(s)) << 3 | u32(space)) { return false }
	return eql_bytes(string(src[slot.start:][:len(s)]), s)
}

define :: proc "contextless" (table: ^Name_Table, space: Space, t: Tok, index: u32) -> bool {
	s := text(t)
	mask := u32(len(table.slots) - 1)
	h := name_hash(space, s) & mask
	for ; table.slots[h].gen == table.gen; h = (h + 1) & mask {
		if name_matches(table.slots[h], space, s) { return fail(t.start, .Name) }
	}
	if table.count >= table.cap { return fail(t.start, .Limit) }
	table.slots[h] = Name_Slot {
		start = u32(t.start),
		meta  = u32(len(s)) << 3 | u32(space),
		index = index,
		gen   = table.gen,
	}
	table.count += 1
	return true
}

lookup :: proc "contextless" (table: ^Name_Table, space: Space, s: string) -> (index: u32, found: bool) {
	mask := u32(len(table.slots) - 1)
	h := name_hash(space, s) & mask
	for ; table.slots[h].gen == table.gen; h = (h + 1) & mask {
		if name_matches(table.slots[h], space, s) { return table.slots[h].index, true }
	}
	return 0, false
}

var_index :: proc "contextless" (space: Space, t: Tok) -> (res: u32, ok: bool) {
	#partial switch t.kind {
	case .Id:
		index, found := lookup(&locals if space == .Local else &names, space, text(t))
		if !found {
			fail(t.start, .Name)
			return
		}
		return index, true
	case .Num:
		return u32_tok(t)
	}
	fail(t.start, .Syntax)
	return
}

// ---------------------------------------------------------------------------
// Types

type_off: [MAX_TYPES]u32
type_np: [MAX_TYPES]u32
type_nr: [MAX_TYPES]u32
type_count: u32
type_pool: [TYPE_POOL_CAP]u8
pool_len: u32
sig_index: [SIG_SLOTS]u32
sig_gen: [SIG_SLOTS]u32
sig_generation: u32

Sig :: struct {
	np: u32,
	nr: u32,
}

valtype :: proc "contextless" (t: Tok) -> (res: u8, ok: bool) {
	if t.kind == .LParen {
		fail(t.start, .Unsupported)
		return
	}
	if t.kind == .Keyword {
		switch text(t) {
		case "i32":
			return 0x7f, true
		case "i64":
			return 0x7e, true
		case "f32":
			return 0x7d, true
		case "f64":
			return 0x7c, true
		case "v128":
			return 0x7b, true
		case "funcref":
			return 0x70, true
		case "externref":
			return 0x6f, true
		}
	}
	fail(t.start, .Syntax)
	return
}

is_ref_type_kw :: proc "contextless" (t: Tok) -> bool {
	return is_kw(t, "funcref") || is_kw(t, "externref")
}

pool_put :: proc "contextless" (at: u32, b: u8) -> bool {
	if at >= TYPE_POOL_CAP { return fail(pos, .Limit) }
	type_pool[at] = b
	return true
}

// What `(param $x t)` means where a signature appears.
Param_Names :: enum u8 {
	// Function definitions: the names become locals.
	Bind,
	// Type definitions: the names are allowed, ignored and may repeat.
	Allow,
	// Imports: the names are ignored but must be distinct.
	Distinct,
	// Block types and `call_indirect`: names are malformed.
	Forbid,
}

// Parses `(param ...)* (result ...)*` into the pool tail without committing.
parse_sig :: proc "contextless" (param_names: Param_Names) -> (sig: Sig, ok: bool) {
	if param_names == .Distinct { table_reset(&locals) }
	for open_form("param") or_return {
		id, has_id := opt_id() or_return
		if has_id {
			switch param_names {
			case .Forbid:
				fail(id.start, .Syntax)
				return
			case .Bind, .Distinct:
				define(&locals, .Local, id, sig.np) or_return
			case .Allow:
			}
			pool_put(pool_len + sig.np, valtype(next() or_return) or_return) or_return
			sig.np += 1
			_ = expect(.RParen) or_return
			continue
		}
		for {
			t := next() or_return
			if t.kind == .RParen { break }
			pool_put(pool_len + sig.np, valtype(t) or_return) or_return
			sig.np += 1
		}
	}
	for open_form("result") or_return {
		for {
			t := next() or_return
			if t.kind == .RParen { break }
			pool_put(pool_len + sig.np + sig.nr, valtype(t) or_return) or_return
			sig.nr += 1
		}
	}
	return sig, true
}

sig_hash :: proc "contextless" (off: u32, sig: Sig) -> u32 {
	h: u32 = 2166136261 ~ sig.np
	for i in off ..< off + sig.np + sig.nr { h = (h ~ u32(type_pool[i])) * 16777619 }
	return (h ~ sig.nr) * 16777619
}

sig_equal :: proc "contextless" (index: u32, off: u32, sig: Sig) -> bool {
	if type_np[index] != sig.np || type_nr[index] != sig.nr { return false }
	a := type_off[index]
	for i in 0 ..< sig.np + sig.nr {
		if type_pool[a + i] != type_pool[off + i] { return false }
	}
	return true
}

// Finds the first type with the pending signature, or the free slot for it.
sig_slot :: proc "contextless" (sig: Sig) -> (slot: u32, index: u32, found: bool) {
	h := sig_hash(pool_len, sig) & (SIG_SLOTS - 1)
	for ; sig_gen[h] == sig_generation; h = (h + 1) & (SIG_SLOTS - 1) {
		if sig_equal(sig_index[h], pool_len, sig) { return h, sig_index[h], true }
	}
	return h, 0, false
}

append_type :: proc "contextless" (sig: Sig) -> (index: u32, ok: bool) {
	if type_count >= MAX_TYPES {
		fail(pos, .Limit)
		return
	}
	index = type_count
	type_off[index] = pool_len
	type_np[index] = sig.np
	type_nr[index] = sig.nr
	pool_len += sig.np + sig.nr
	type_count += 1
	return index, true
}

// An explicit `(type ...)` always gets its own index. The first type with a
// signature is the one that implicit type uses match.
add_explicit_type :: proc "contextless" (sig: Sig) -> bool {
	slot, _, found := sig_slot(sig)
	index := append_type(sig) or_return
	if !found {
		sig_gen[slot] = sig_generation
		sig_index[slot] = index
	}
	return true
}

// Returns the first type with the pending signature, appending one if none.
intern_sig :: proc "contextless" (sig: Sig) -> (res: u32, ok: bool) {
	slot, existing, found := sig_slot(sig)
	if found { return existing, true }
	index := append_type(sig) or_return
	sig_gen[slot] = sig_generation
	sig_index[slot] = index
	return index, true
}

Type_Use :: struct {
	explicit:     u32,
	has_explicit: bool,
	sig:          Sig,
}

// Parses `(type x)? (param ...)* (result ...)*`. With `(type x)`, an inline
// signature is optional but must match the type exactly.
parse_type_use_parts :: proc "contextless" (param_names: Param_Names) -> (use: Type_Use, ok: bool) {
	index_start := 0
	if open_form("type") or_return {
		t := next() or_return
		use.explicit = var_index(.Type, t) or_return
		use.has_explicit = true
		index_start = t.start
		_ = expect(.RParen) or_return
	}
	sig_start := (peek() or_return).start
	use.sig = parse_sig(param_names) or_return
	// Like WABT, a numeric index past the declared types is written as is
	// unless an inline signature has to be checked against it.
	if use.has_explicit && use.sig.np + use.sig.nr != 0 {
		if use.explicit >= type_count {
			fail(index_start, .Name)
			return
		}
		if !sig_equal(use.explicit, pool_len, use.sig) {
			fail(sig_start, .Syntax)
			return
		}
	}
	return use, true
}

// Returns the type index of a type use. When `resolve` is false nothing is
// interned and the result is unused.
parse_type_use :: proc "contextless" (param_names: Param_Names, resolve: bool) -> (res: u32, ok: bool) {
	use := parse_type_use_parts(param_names) or_return
	if use.has_explicit { return use.explicit, true }
	if !resolve { return 0, true }
	return intern_sig(use.sig)
}

Block_Type_Kind :: enum u8 {
	Empty,
	Val,
	Index,
}

Block_Type :: struct {
	kind:  Block_Type_Kind,
	value: u32,
}

parse_block_type :: proc "contextless" (resolve: bool) -> (res: Block_Type, ok: bool) {
	use := parse_type_use_parts(.Forbid) or_return
	sig := use.sig
	if use.has_explicit {
		index := use.explicit
		// WABT writes a missing type as an empty block type.
		if index >= type_count { return {.Empty, 0}, true }
		// WABT prints a single-result type use in the short form.
		if type_np[index] == 0 && type_nr[index] == 0 { return {.Empty, 0}, true }
		if type_np[index] == 0 && type_nr[index] == 1 { return {.Val, u32(type_pool[type_off[index]])}, true }
		return {.Index, index}, true
	}
	if sig.np == 0 && sig.nr == 0 { return {.Empty, 0}, true }
	if sig.np == 0 && sig.nr == 1 { return {.Val, u32(type_pool[pool_len])}, true }
	if !resolve { return {.Empty, 0}, true }
	return {.Index, intern_sig(sig) or_return}, true
}

write_block_type :: proc "contextless" (o: ^Out, bt: Block_Type) -> bool {
	switch bt.kind {
	case .Empty:
		return put(o, 0x40)
	case .Val:
		return put(o, u8(bt.value))
	case .Index:
		return sleb(o, i64(bt.value))
	}
	return true
}

// ---------------------------------------------------------------------------
// Instruction table

Imm :: enum u8 {
	None,
	Label,
	Br_Table,
	Func,
	Call_Indirect,
	Local,
	Global,
	Table,
	Memarg,
	Memarg_Lane,
	Lane,
	Shuffle,
	I32,
	I64,
	F32,
	F64,
	V128,
	Select,
	Ref_Null,
	Mem,
	Mem_Copy,
	Mem_Init,
	Data,
	Table_Copy,
	Table_Init,
	Elem,
	Fence,
	Unsupported,
	// Structure keywords. They share the table so that one lookup classifies
	// any keyword in an instruction position.
	Block,
	If,
	Then,
	Else,
	End,
}

Op_Group :: struct {
	prefix: u8,
	first:  u16,
	imm:    Imm,
	names:  string,
}

// Names take consecutive opcodes from `first`; `_` skips one. `name:N` sets
// the natural alignment exponent of a memory access.
@(rodata)
op_groups := [?]Op_Group {
	{0, 0x00, .None, "unreachable nop"},
	{0, 0x02, .Block, "block loop"},
	{0, 0x04, .If, "if"},
	{0, 0x05, .Else, "else"},
	{0, 0x0b, .End, "end"},
	{0, 0, .Then, "then"},
	{0, 0x0c, .Label, "br br_if"},
	{0, 0x0e, .Br_Table, "br_table"},
	{0, 0x0f, .None, "return"},
	{0, 0x10, .Func, "call"},
	{0, 0x11, .Call_Indirect, "call_indirect"},
	{0, 0x12, .Func, "return_call"},
	{0, 0x13, .Call_Indirect, "return_call_indirect"},
	{0, 0x1a, .None, "drop"},
	{0, 0x1b, .Select, "select"},
	{0, 0x20, .Local, "local.get local.set local.tee"},
	{0, 0x23, .Global, "global.get global.set"},
	{0, 0x25, .Table, "table.get table.set"},
	{0, 0x28, .Memarg, "i32.load:2 i64.load:3 f32.load:2 f64.load:3 i32.load8_s:0 i32.load8_u:0 i32.load16_s:1 i32.load16_u:1 i64.load8_s:0 i64.load8_u:0 i64.load16_s:1 i64.load16_u:1 i64.load32_s:2 i64.load32_u:2 i32.store:2 i64.store:3 f32.store:2 f64.store:3 i32.store8:0 i32.store16:1 i64.store8:0 i64.store16:1 i64.store32:2"},
	{0, 0x3f, .Mem, "memory.size memory.grow"},
	{0, 0x41, .I32, "i32.const"},
	{0, 0x42, .I64, "i64.const"},
	{0, 0x43, .F32, "f32.const"},
	{0, 0x44, .F64, "f64.const"},
	{0, 0x45, .None, "i32.eqz i32.eq i32.ne i32.lt_s i32.lt_u i32.gt_s i32.gt_u i32.le_s i32.le_u i32.ge_s i32.ge_u " +
		"i64.eqz i64.eq i64.ne i64.lt_s i64.lt_u i64.gt_s i64.gt_u i64.le_s i64.le_u i64.ge_s i64.ge_u " +
		"f32.eq f32.ne f32.lt f32.gt f32.le f32.ge f64.eq f64.ne f64.lt f64.gt f64.le f64.ge " +
		"i32.clz i32.ctz i32.popcnt i32.add i32.sub i32.mul i32.div_s i32.div_u i32.rem_s i32.rem_u i32.and i32.or i32.xor i32.shl i32.shr_s i32.shr_u i32.rotl i32.rotr " +
		"i64.clz i64.ctz i64.popcnt i64.add i64.sub i64.mul i64.div_s i64.div_u i64.rem_s i64.rem_u i64.and i64.or i64.xor i64.shl i64.shr_s i64.shr_u i64.rotl i64.rotr " +
		"f32.abs f32.neg f32.ceil f32.floor f32.trunc f32.nearest f32.sqrt f32.add f32.sub f32.mul f32.div f32.min f32.max f32.copysign " +
		"f64.abs f64.neg f64.ceil f64.floor f64.trunc f64.nearest f64.sqrt f64.add f64.sub f64.mul f64.div f64.min f64.max f64.copysign " +
		"i32.wrap_i64 i32.trunc_f32_s i32.trunc_f32_u i32.trunc_f64_s i32.trunc_f64_u i64.extend_i32_s i64.extend_i32_u " +
		"i64.trunc_f32_s i64.trunc_f32_u i64.trunc_f64_s i64.trunc_f64_u f32.convert_i32_s f32.convert_i32_u f32.convert_i64_s f32.convert_i64_u f32.demote_f64 " +
		"f64.convert_i32_s f64.convert_i32_u f64.convert_i64_s f64.convert_i64_u f64.promote_f32 " +
		"i32.reinterpret_f32 i64.reinterpret_f64 f32.reinterpret_i32 f64.reinterpret_i64 " +
		"i32.extend8_s i32.extend16_s i64.extend8_s i64.extend16_s i64.extend32_s"},
	{0, 0xd0, .Ref_Null, "ref.null"},
	{0, 0xd1, .None, "ref.is_null"},
	{0, 0xd2, .Func, "ref.func"},

	{0xfc, 0x00, .None, "i32.trunc_sat_f32_s i32.trunc_sat_f32_u i32.trunc_sat_f64_s i32.trunc_sat_f64_u i64.trunc_sat_f32_s i64.trunc_sat_f32_u i64.trunc_sat_f64_s i64.trunc_sat_f64_u"},
	{0xfc, 0x08, .Mem_Init, "memory.init"},
	{0xfc, 0x09, .Data, "data.drop"},
	{0xfc, 0x0a, .Mem_Copy, "memory.copy"},
	{0xfc, 0x0b, .Mem, "memory.fill"},
	{0xfc, 0x0c, .Table_Init, "table.init"},
	{0xfc, 0x0d, .Elem, "elem.drop"},
	{0xfc, 0x0e, .Table_Copy, "table.copy"},
	{0xfc, 0x0f, .Table, "table.grow table.size table.fill"},

	{0xfd, 0x00, .Memarg, "v128.load:4 v128.load8x8_s:3 v128.load8x8_u:3 v128.load16x4_s:3 v128.load16x4_u:3 v128.load32x2_s:3 v128.load32x2_u:3 v128.load8_splat:0 v128.load16_splat:1 v128.load32_splat:2 v128.load64_splat:3 v128.store:4"},
	{0xfd, 0x0c, .V128, "v128.const"},
	{0xfd, 0x0d, .Shuffle, "i8x16.shuffle"},
	{0xfd, 0x0e, .None, "i8x16.swizzle i8x16.splat i16x8.splat i32x4.splat i64x2.splat f32x4.splat f64x2.splat"},
	{0xfd, 0x15, .Lane, "i8x16.extract_lane_s i8x16.extract_lane_u i8x16.replace_lane i16x8.extract_lane_s i16x8.extract_lane_u i16x8.replace_lane i32x4.extract_lane i32x4.replace_lane i64x2.extract_lane i64x2.replace_lane f32x4.extract_lane f32x4.replace_lane f64x2.extract_lane f64x2.replace_lane"},
	{0xfd, 0x23, .None, "i8x16.eq i8x16.ne i8x16.lt_s i8x16.lt_u i8x16.gt_s i8x16.gt_u i8x16.le_s i8x16.le_u i8x16.ge_s i8x16.ge_u " +
		"i16x8.eq i16x8.ne i16x8.lt_s i16x8.lt_u i16x8.gt_s i16x8.gt_u i16x8.le_s i16x8.le_u i16x8.ge_s i16x8.ge_u " +
		"i32x4.eq i32x4.ne i32x4.lt_s i32x4.lt_u i32x4.gt_s i32x4.gt_u i32x4.le_s i32x4.le_u i32x4.ge_s i32x4.ge_u " +
		"f32x4.eq f32x4.ne f32x4.lt f32x4.gt f32x4.le f32x4.ge f64x2.eq f64x2.ne f64x2.lt f64x2.gt f64x2.le f64x2.ge " +
		"v128.not v128.and v128.andnot v128.or v128.xor v128.bitselect v128.any_true"},
	{0xfd, 0x54, .Memarg_Lane, "v128.load8_lane:0 v128.load16_lane:1 v128.load32_lane:2 v128.load64_lane:3 v128.store8_lane:0 v128.store16_lane:1 v128.store32_lane:2 v128.store64_lane:3"},
	{0xfd, 0x5c, .Memarg, "v128.load32_zero:2 v128.load64_zero:3"},
	{0xfd, 0x5e, .None, "f32x4.demote_f64x2_zero f64x2.promote_low_f32x4 " +
		"i8x16.abs i8x16.neg i8x16.popcnt i8x16.all_true i8x16.bitmask i8x16.narrow_i16x8_s i8x16.narrow_i16x8_u " +
		"f32x4.ceil f32x4.floor f32x4.trunc f32x4.nearest " +
		"i8x16.shl i8x16.shr_s i8x16.shr_u i8x16.add i8x16.add_sat_s i8x16.add_sat_u i8x16.sub i8x16.sub_sat_s i8x16.sub_sat_u " +
		"f64x2.ceil f64x2.floor i8x16.min_s i8x16.min_u i8x16.max_s i8x16.max_u f64x2.trunc i8x16.avgr_u " +
		"i16x8.extadd_pairwise_i8x16_s i16x8.extadd_pairwise_i8x16_u i32x4.extadd_pairwise_i16x8_s i32x4.extadd_pairwise_i16x8_u " +
		"i16x8.abs i16x8.neg i16x8.q15mulr_sat_s i16x8.all_true i16x8.bitmask i16x8.narrow_i32x4_s i16x8.narrow_i32x4_u " +
		"i16x8.extend_low_i8x16_s i16x8.extend_high_i8x16_s i16x8.extend_low_i8x16_u i16x8.extend_high_i8x16_u " +
		"i16x8.shl i16x8.shr_s i16x8.shr_u i16x8.add i16x8.add_sat_s i16x8.add_sat_u i16x8.sub i16x8.sub_sat_s i16x8.sub_sat_u " +
		"f64x2.nearest i16x8.mul i16x8.min_s i16x8.min_u i16x8.max_s i16x8.max_u _ i16x8.avgr_u " +
		"i16x8.extmul_low_i8x16_s i16x8.extmul_high_i8x16_s i16x8.extmul_low_i8x16_u i16x8.extmul_high_i8x16_u " +
		"i32x4.abs i32x4.neg _ i32x4.all_true i32x4.bitmask _ _ " +
		"i32x4.extend_low_i16x8_s i32x4.extend_high_i16x8_s i32x4.extend_low_i16x8_u i32x4.extend_high_i16x8_u " +
		"i32x4.shl i32x4.shr_s i32x4.shr_u i32x4.add _ _ i32x4.sub _ _ _ i32x4.mul i32x4.min_s i32x4.min_u i32x4.max_s i32x4.max_u i32x4.dot_i16x8_s _ " +
		"i32x4.extmul_low_i16x8_s i32x4.extmul_high_i16x8_s i32x4.extmul_low_i16x8_u i32x4.extmul_high_i16x8_u " +
		"i64x2.abs i64x2.neg _ i64x2.all_true i64x2.bitmask _ _ " +
		"i64x2.extend_low_i32x4_s i64x2.extend_high_i32x4_s i64x2.extend_low_i32x4_u i64x2.extend_high_i32x4_u " +
		"i64x2.shl i64x2.shr_s i64x2.shr_u i64x2.add _ _ i64x2.sub _ _ _ i64x2.mul " +
		"i64x2.eq i64x2.ne i64x2.lt_s i64x2.gt_s i64x2.le_s i64x2.ge_s " +
		"i64x2.extmul_low_i32x4_s i64x2.extmul_high_i32x4_s i64x2.extmul_low_i32x4_u i64x2.extmul_high_i32x4_u " +
		"f32x4.abs f32x4.neg _ f32x4.sqrt f32x4.add f32x4.sub f32x4.mul f32x4.div f32x4.min f32x4.max f32x4.pmin f32x4.pmax " +
		"f64x2.abs f64x2.neg _ f64x2.sqrt f64x2.add f64x2.sub f64x2.mul f64x2.div f64x2.min f64x2.max f64x2.pmin f64x2.pmax " +
		"i32x4.trunc_sat_f32x4_s i32x4.trunc_sat_f32x4_u f32x4.convert_i32x4_s f32x4.convert_i32x4_u " +
		"i32x4.trunc_sat_f64x2_s_zero i32x4.trunc_sat_f64x2_u_zero f64x2.convert_low_i32x4_s f64x2.convert_low_i32x4_u " +
		"i8x16.relaxed_swizzle i32x4.relaxed_trunc_f32x4_s i32x4.relaxed_trunc_f32x4_u i32x4.relaxed_trunc_f64x2_s_zero i32x4.relaxed_trunc_f64x2_u_zero " +
		"f32x4.relaxed_madd f32x4.relaxed_nmadd f64x2.relaxed_madd f64x2.relaxed_nmadd " +
		"i8x16.relaxed_laneselect i16x8.relaxed_laneselect i32x4.relaxed_laneselect i64x2.relaxed_laneselect " +
		"f32x4.relaxed_min f32x4.relaxed_max f64x2.relaxed_min f64x2.relaxed_max " +
		"i16x8.relaxed_q15mulr_s i16x8.relaxed_dot_i8x16_i7x16_s i32x4.relaxed_dot_i8x16_i7x16_add_s"},

	{0xfe, 0x00, .Memarg, "memory.atomic.notify:2 memory.atomic.wait32:2 memory.atomic.wait64:3"},
	{0xfe, 0x03, .Fence, "atomic.fence"},
	// The read-modify-write instructions that follow from 0x1e are generated
	// from `rmw_ops` and `rmw_forms`.
	{0xfe, 0x10, .Memarg, "i32.atomic.load:2 i64.atomic.load:3 i32.atomic.load8_u:0 i32.atomic.load16_u:1 i64.atomic.load8_u:0 i64.atomic.load16_u:1 i64.atomic.load32_u:2 " +
		"i32.atomic.store:2 i64.atomic.store:3 i32.atomic.store8:0 i32.atomic.store16:1 i64.atomic.store8:0 i64.atomic.store16:1 i64.atomic.store32:2"},

	// Recognized so they fail as unsupported features rather than typos.
	{0, 0, .Unsupported, "try catch catch_all throw rethrow throw_ref delegate try_table call_ref return_call_ref " +
		"ref.as_non_null br_on_null br_on_non_null ref.eq br_on_cast br_on_cast_fail ref.test ref.cast " +
		"i64.add128 i64.sub128 i64.mul_wide_s i64.mul_wide_u"},
}

Rmw_Form :: struct {
	head:       string,
	tail:       string,
	align_log2: u8,
}

RMW_FIRST :: 0x1e

@(rodata)
rmw_ops := [?]string{"add", "sub", "and", "or", "xor", "xchg", "cmpxchg"}

@(rodata)
rmw_forms := [?]Rmw_Form {
	{"i32.atomic.rmw.", "", 2},
	{"i64.atomic.rmw.", "", 3},
	{"i32.atomic.rmw8.", "_u", 0},
	{"i32.atomic.rmw16.", "_u", 1},
	{"i64.atomic.rmw8.", "_u", 0},
	{"i64.atomic.rmw16.", "_u", 1},
	{"i64.atomic.rmw32.", "_u", 2},
}

Op :: struct {
	name:       string,
	code:       u16,
	prefix:     u8,
	imm:        Imm,
	align_log2: u8,
}

MAX_OPS :: 640
OP_SLOTS :: 2048
RMW_NAME_CAP :: 1536

ops: [MAX_OPS]Op
op_count: int
op_slots: [OP_SLOTS]u16
rmw_names: [RMW_NAME_CAP]u8
ops_ready: bool

op_hash :: proc "contextless" (s: string) -> u32 {
	return hash_bytes(0, s)
}

add_op :: proc "contextless" (name: string, prefix: u8, code: u16, imm: Imm, align_log2: u8) {
	if op_count >= MAX_OPS { intrinsics.trap() }
	ops[op_count] = Op{name, code, prefix, imm, align_log2}
	op_count += 1
	h := op_hash(name) & (OP_SLOTS - 1)
	for op_slots[h] != 0 { h = (h + 1) & (OP_SLOTS - 1) }
	op_slots[h] = u16(op_count)
}

// Builds the opcode table and its hash index. Runs once per instance.
init_ops :: proc "contextless" () {
	for group in op_groups {
		list := group.names
		code := group.first
		i := 0
		for {
			for i < len(list) && list[i] == ' ' { i += 1 }
			j := i
			for j < len(list) && list[j] != ' ' { j += 1 }
			if i == j { break }
			spec := list[i:j]
			i = j
			if spec == "_" {
				code += 1
				continue
			}
			name := spec
			align_log2: u8 = 0
			if n := len(spec); n > 2 && spec[n - 2] == ':' {
				name = spec[:n - 2]
				align_log2 = spec[n - 1] - '0'
			}
			add_op(name, group.prefix, code, group.imm, align_log2)
			code += 1
		}
	}

	code: u16 = RMW_FIRST
	w := 0
	for op in rmw_ops {
		for form in rmw_forms {
			start := w
			for part in ([3]string{form.head, op, form.tail}) {
				if w + len(part) > RMW_NAME_CAP { intrinsics.trap() }
				for i in 0 ..< len(part) {
					rmw_names[w] = part[i]
					w += 1
				}
			}
			add_op(string(rmw_names[start:w]), 0xfe, code, .Memarg, form.align_log2)
			code += 1
		}
	}
	ops_ready = true
}

lookup_op :: proc "contextless" (s: string) -> ^Op {
	h := op_hash(s) & (OP_SLOTS - 1)
	for ; op_slots[h] != 0; h = (h + 1) & (OP_SLOTS - 1) {
		op := &ops[op_slots[h] - 1]
		if eql_bytes(op.name, s) { return op }
	}
	return nil
}

// ---------------------------------------------------------------------------
// Instructions

Frame_Kind :: enum u8 {
	// A folded instruction whose encoding waits on the pending stack.
	Plain,
	// A folded `call_indirect`, encoded when it closes. Its type use may add
	// a type, and that has to happen after its operands add theirs.
	Deferred,
	FBlock,
	FIf,
	Flat,
	Flat_If,
}

NO_ELSE :: -1

Frame :: struct {
	kind:  Frame_Kind,
	stage: u8,
	// Plain: the pending byte count. Deferred: where the keyword starts.
	// FIf: where the label and block type start, then from `else` on the
	// output length just after the `else` opcode. Flat_If: that length, or
	// NO_ELSE before `else`.
	at:    int,
}

frames: [MAX_DEPTH]Frame
frame_len: int
labels: [MAX_LABELS]Tok
label_len: int
uses_data_count: bool

push_frame :: proc "contextless" (kind: Frame_Kind, at: int = 0) -> bool {
	if frame_len >= MAX_DEPTH { return fail(pos, .Limit) }
	frames[frame_len] = Frame{kind, 0, at}
	frame_len += 1
	return true
}

// Pushes a block label; an unlabelled block pushes an EOF token.
push_label :: proc "contextless" (label: Tok, has_label: bool) -> bool {
	if label_len >= MAX_LABELS { return fail(pos, .Limit) }
	labels[label_len] = label if has_label else Tok{.EOF, 0, 0}
	label_len += 1
	return true
}

label_depth :: proc "contextless" (t: Tok) -> (res: u32, ok: bool) {
	if t.kind == .Num { return u32_tok(t) }
	if t.kind != .Id {
		fail(t.start, .Syntax)
		return
	}
	for i := label_len - 1; i >= 0; i -= 1 {
		if labels[i].kind == .Id && eql_bytes(text(labels[i]), text(t)) { return u32(label_len - 1 - i), true }
	}
	fail(t.start, .Name)
	return
}

// Checks the optional label after `else` or `end` against the open block.
check_end_label :: proc "contextless" () -> bool {
	t := peek() or_return
	if t.kind != .Id { return true }
	_ = next() or_return
	label := labels[label_len - 1]
	if label.kind != .Id || !eql_bytes(text(label), text(t)) { return fail(t.start, .Name) }
	return true
}

// Encodes instructions until the `)` that closes the enclosing form, which is
// left unread. With `single`, encodes exactly one folded instruction.
encode_instrs :: proc "contextless" (o: ^Out, single: bool) -> bool {
	frame_len = 0
	o.top = len(o.buf)
	base_labels := label_len
	loop: for {
		t := next() or_return
		#partial switch t.kind {
		case .RParen:
			if frame_len == 0 {
				if single { return fail(t.start, .Syntax) }
				pos = t.start
				break loop
			}
			close_frame(o, t) or_return
			if single && frame_len == 0 { break loop }
		case .LParen:
			open_folded(o) or_return
		case .Keyword:
			if single && frame_len == 0 { return fail(t.start, .Syntax) }
			flat_instr(o, t) or_return
		case:
			return fail(t.start, .Syntax)
		}
	}
	if label_len != base_labels { return fail(pos, .Syntax) }
	return true
}

open_folded :: proc "contextless" (o: ^Out) -> bool {
	kw := next() or_return
	if kw.kind != .Keyword { return fail(kw.start, .Syntax) }
	op := lookup_op(text(kw))
	if frame_len > 0 {
		top := &frames[frame_len - 1]
		if top.kind == .FIf {
			switch top.stage {
			case 0:
				if op != nil && op.imm == .Then {
					save := pos
					pos = top.at
					label, has_label := opt_id() or_return
					bt := parse_block_type(true) or_return
					pos = save
					put(o, 0x04) or_return
					write_block_type(o, bt) or_return
					push_label(label, has_label) or_return
					top.stage = 1
					return true
				}
			case 2:
				if op == nil || op.imm != .Else { return fail(kw.start, .Syntax) }
				put(o, 0x05) or_return
				top.at = o.len
				top.stage = 3
				return true
			case 4:
				return fail(kw.start, .Syntax)
			}
		}
	}
	if op == nil { return fail(kw.start, .Syntax) }
	#partial switch op.imm {
	case .Then, .Else, .End:
		return fail(kw.start, .Syntax)
	case .Unsupported:
		return fail(kw.start, .Unsupported)
	case .Block:
		label, has_label := opt_id() or_return
		bt := parse_block_type(true) or_return
		put(o, u8(op.code)) or_return
		write_block_type(o, bt) or_return
		push_label(label, has_label) or_return
		return push_frame(.FBlock)
	case .If:
		header := pos
		_, _ = opt_id() or_return
		_ = parse_block_type(false) or_return
		return push_frame(.FIf, header)
	case .Call_Indirect:
		// Parse the immediates now only to find where the operands start.
		save_len := o.len
		emit_op(o, op, true) or_return
		o.len = save_len
		return push_frame(.Deferred, kw.start)
	}
	// Immediates precede the folded operands but are emitted after them, so
	// the encoding waits on the pending stack.
	from := o.len
	emit_op(o, op, false) or_return
	return push_frame(.Plain, stash(o, from))
}

close_frame :: proc "contextless" (o: ^Out, rparen: Tok) -> bool {
	top := &frames[frame_len - 1]
	switch top.kind {
	case .Plain:
		unstash(o, top.at)
		frame_len -= 1
	case .Deferred:
		save := pos
		pos = top.at
		kw := next() or_return
		emit_op(o, lookup_op(text(kw)), false) or_return
		pos = save
		frame_len -= 1
	case .FBlock:
		put(o, 0x0b) or_return
		label_len -= 1
		frame_len -= 1
	case .FIf:
		switch top.stage {
		case 0:
			return fail(rparen.start, .Syntax)
		case 1:
			top.stage = 2
		case 3:
			// WABT omits an empty else clause.
			if o.len == top.at { o.len -= 1 }
			top.stage = 4
		case:
			put(o, 0x0b) or_return
			label_len -= 1
			frame_len -= 1
		}
	case .Flat, .Flat_If:
		return fail(rparen.start, .Syntax)
	}
	return true
}

flat_instr :: proc "contextless" (o: ^Out, kw: Tok) -> bool {
	if frame_len > 0 {
		top := frames[frame_len - 1]
		if top.kind == .Plain || top.kind == .Deferred { return fail(kw.start, .Syntax) }
		if top.kind == .FIf && top.stage != 1 && top.stage != 3 { return fail(kw.start, .Syntax) }
	}
	op := lookup_op(text(kw))
	if op == nil { return fail(kw.start, .Syntax) }
	#partial switch op.imm {
	case .Block, .If:
		label, has_label := opt_id() or_return
		bt := parse_block_type(true) or_return
		put(o, u8(op.code)) or_return
		write_block_type(o, bt) or_return
		push_label(label, has_label) or_return
		return push_frame(.Flat_If if op.imm == .If else .Flat, NO_ELSE)
	case .Else:
		if frame_len == 0 { return fail(kw.start, .Syntax) }
		top := &frames[frame_len - 1]
		if top.kind != .Flat_If || top.at != NO_ELSE { return fail(kw.start, .Syntax) }
		check_end_label() or_return
		put(o, 0x05) or_return
		top.at = o.len
		return true
	case .End:
		if frame_len == 0 { return fail(kw.start, .Syntax) }
		top := frames[frame_len - 1]
		if top.kind != .Flat && top.kind != .Flat_If { return fail(kw.start, .Syntax) }
		check_end_label() or_return
		if top.kind == .Flat_If && o.len == top.at { o.len -= 1 }
		put(o, 0x0b) or_return
		label_len -= 1
		frame_len -= 1
		return true
	case .Then:
		return fail(kw.start, .Syntax)
	case .Unsupported:
		return fail(kw.start, .Unsupported)
	}
	return emit_op(o, op, false)
}

// Parses `memidx? offset=N? align=N?` and writes the memarg.
memarg :: proc "contextless" (o: ^Out, natural: u8, lane: bool) -> bool {
	memidx: u32 = 0
	t := peek() or_return
	has_mem := t.kind == .Id
	if t.kind == .Num {
		if !lane {
			has_mem = true
		} else {
			save := pos
			_ = next() or_return
			after := peek() or_return
			pos = save
			has_mem =
				after.kind == .Num ||
				(after.kind == .Keyword && (has_prefix(text(after), "offset=") || has_prefix(text(after), "align=")))
		}
	}
	if has_mem { memidx = var_index(.Memory, next() or_return) or_return }

	// The grammar is `offset=`? then `align=`?, in that order.
	offset: u64 = 0
	align_log2 := u32(natural)
	a := peek() or_return
	if a.kind == .Keyword && has_prefix(text(a), "offset=") {
		_ = next() or_return
		v, valid := parse_nat(text(a)[7:])
		if !valid { return fail(a.start, .Number) }
		offset = v
		a = peek() or_return
	}
	if a.kind == .Keyword && has_prefix(text(a), "align=") {
		_ = next() or_return
		v, valid := parse_nat(text(a)[6:])
		if !valid { return fail(a.start, .Number) }
		if v == 0 || v & (v - 1) != 0 || v > 1 << 31 { return fail(a.start, .Number) }
		align_log2 = u32(intrinsics.count_trailing_zeros(v))
	}
	if memidx != 0 {
		uleb(o, align_log2 | 0x40) or_return
		uleb(o, memidx) or_return
	} else {
		uleb(o, align_log2) or_return
	}
	return uleb(o, offset)
}

lane_index :: proc "contextless" (o: ^Out) -> bool {
	t := next() or_return
	v := nat_tok(t) or_return
	if v > 255 { return fail(t.start, .Number) }
	return put(o, u8(v))
}

// Reads an index when one is next; `res` is 0 otherwise.
opt_var :: proc "contextless" (space: Space) -> (res: u32, found: bool, ok: bool) {
	t := peek() or_return
	if !is_var(t) { return 0, false, true }
	_ = next() or_return
	res = var_index(space, t) or_return
	return res, true, true
}

emit_op :: proc "contextless" (o: ^Out, op: ^Op, dry: bool) -> bool {
	if op.imm == .Select {
		// `select (result t*)*` uses the typed opcode 0x1c.
		save := pos
		n := 0
		for open_form("result") or_return {
			for (next() or_return).kind != .RParen { n += 1 }
		}
		if n == 0 && !(peek_form_at(save, "result") or_return) { return put(o, 0x1b) }
		pos = save
		put(o, 0x1c) or_return
		uleb(o, n) or_return
		for open_form("result") or_return {
			for {
				t := next() or_return
				if t.kind == .RParen { break }
				put(o, valtype(t) or_return) or_return
			}
		}
		return true
	}
	if op.prefix != 0 {
		put(o, op.prefix) or_return
		uleb(o, u32(op.code)) or_return
	} else {
		put(o, u8(op.code)) or_return
	}
	switch op.imm {
	case .None, .Unsupported, .Select, .Block, .If, .Then, .Else, .End:
	case .Label:
		uleb(o, label_depth(next() or_return) or_return) or_return
	case .Br_Table:
		save := pos
		n := 0
		for is_var(peek() or_return) {
			_ = next() or_return
			n += 1
		}
		if n == 0 { return fail(pos, .Syntax) }
		pos = save
		uleb(o, n - 1) or_return
		for _ in 0 ..< n {
			uleb(o, label_depth(next() or_return) or_return) or_return
		}
	case .Func:
		uleb(o, var_index(.Func, next() or_return) or_return) or_return
	case .Call_Indirect:
		table, _ := opt_var(.Table) or_return
		type_index := parse_type_use(.Forbid, !dry) or_return
		uleb(o, type_index) or_return
		uleb(o, table) or_return
	case .Local:
		uleb(o, var_index(.Local, next() or_return) or_return) or_return
	case .Global:
		uleb(o, var_index(.Global, next() or_return) or_return) or_return
	case .Table:
		table, _ := opt_var(.Table) or_return
		uleb(o, table) or_return
	case .Memarg:
		memarg(o, op.align_log2, false) or_return
	case .Memarg_Lane:
		memarg(o, op.align_log2, true) or_return
		lane_index(o) or_return
	case .Lane:
		lane_index(o) or_return
	case .Shuffle:
		for _ in 0 ..< 16 { lane_index(o) or_return }
	case .I32:
		v := int_tok(next() or_return, 32) or_return
		sleb(o, i64(i32(u32(v)))) or_return
	case .I64:
		v := int_tok(next() or_return, 64) or_return
		sleb(o, i64(v)) or_return
	case .F32:
		uint_le(o, float_tok(next() or_return, false) or_return, 4) or_return
	case .F64:
		uint_le(o, float_tok(next() or_return, true) or_return, 8) or_return
	case .V128:
		v128_const(o) or_return
	case .Ref_Null:
		t := next() or_return
		if is_kw(t, "func") {
			put(o, 0x70) or_return
		} else if is_kw(t, "extern") {
			put(o, 0x6f) or_return
		} else {
			return fail(t.start, .Unsupported if t.kind == .Keyword else .Syntax)
		}
	case .Mem:
		mem, _ := opt_var(.Memory) or_return
		uleb(o, mem) or_return
	case .Mem_Copy, .Table_Copy:
		// Like WABT, a single index names the destination and the source
		// defaults to 0.
		space: Space = .Memory if op.imm == .Mem_Copy else .Table
		dst, has_dst := opt_var(space) or_return
		source: u32 = 0
		if has_dst { source, _ = opt_var(space) or_return }
		uleb(o, dst) or_return
		uleb(o, source) or_return
	case .Mem_Init, .Table_Init:
		first := next() or_return
		if !is_var(first) { return fail(first.start, .Syntax) }
		outer: Space = .Memory if op.imm == .Mem_Init else .Table
		seg: Space = .Data if op.imm == .Mem_Init else .Elem
		container: u32 = 0
		segment: u32 = 0
		if is_var(peek() or_return) {
			container = var_index(outer, first) or_return
			segment = var_index(seg, next() or_return) or_return
		} else {
			segment = var_index(seg, first) or_return
		}
		uleb(o, segment) or_return
		uleb(o, container) or_return
		if op.imm == .Mem_Init && !dry { uses_data_count = true }
	case .Data:
		uleb(o, var_index(.Data, next() or_return) or_return) or_return
		if !dry { uses_data_count = true }
	case .Elem:
		uleb(o, var_index(.Elem, next() or_return) or_return) or_return
	case .Fence:
		put(o, 0x00) or_return
	}
	return true
}

v128_const :: proc "contextless" (o: ^Out) -> bool {
	shape := next() or_return
	if shape.kind != .Keyword { return fail(shape.start, .Syntax) }
	switch text(shape) {
	case "i8x16":
		for _ in 0 ..< 16 { uint_le(o, int_tok(next() or_return, 8) or_return, 1) or_return }
	case "i16x8":
		for _ in 0 ..< 8 { uint_le(o, int_tok(next() or_return, 16) or_return, 2) or_return }
	case "i32x4":
		for _ in 0 ..< 4 { uint_le(o, int_tok(next() or_return, 32) or_return, 4) or_return }
	case "i64x2":
		for _ in 0 ..< 2 { uint_le(o, int_tok(next() or_return, 64) or_return, 8) or_return }
	case "f32x4":
		for _ in 0 ..< 4 { uint_le(o, float_tok(next() or_return, false) or_return, 4) or_return }
	case "f64x2":
		for _ in 0 ..< 2 { uint_le(o, float_tok(next() or_return, true) or_return, 8) or_return }
	case:
		return fail(shape.start, .Syntax)
	}
	return true
}

// Encodes a constant expression body and its `end`, then the closing `)`.
const_expr_then_close :: proc "contextless" (o: ^Out) -> bool {
	encode_instrs(o, false) or_return
	put(o, 0x0b) or_return
	_ = expect(.RParen) or_return
	return true
}

// ---------------------------------------------------------------------------
// Strings

// Decodes a string token, writing its bytes to `o` unless it is nil.
decode_string :: proc "contextless" (t: Tok, o: ^Out) -> (n: int, ok: bool) {
	if t.kind != .String {
		fail(t.start, .Syntax)
		return
	}
	i := t.start + 1
	end := t.end - 1
	for i < end {
		c := src[i]
		if c != '\\' {
			j := i + 1
			for j < end && src[j] != '\\' { j += 1 }
			if o != nil { put_bytes(o, src[i:j]) or_return }
			n += j - i
			i = j
			continue
		}
		esc_start := i
		i += 1
		e := src[i]
		i += 1
		b: u8 = 0
		switch e {
		case 't':
			b = '\t'
		case 'n':
			b = '\n'
		case 'r':
			b = '\r'
		case '"', '\'', '\\':
			b = e
		case 'u':
			if i >= end || src[i] != '{' {
				fail(esc_start, .Syntax)
				return
			}
			close := i
			for close < end && src[close] != '}' { close += 1 }
			if close >= end {
				fail(esc_start, .Syntax)
				return
			}
			value, valid := parse_hex_only(string(src[i + 1:close]))
			if !valid || value > 0x10ffff || (value >= 0xd800 && value < 0xe000) {
				fail(esc_start, .Syntax)
				return
			}
			utf8: [4]u8
			size := utf8_encode(u32(value), &utf8)
			if o != nil { put_bytes(o, utf8[:size]) or_return }
			n += size
			i = close + 1
			continue
		case:
			hi := digit_value(e)
			lo: u8 = digit_value(src[i]) if i < end else 255
			if hi > 15 || lo > 15 {
				fail(esc_start, .Syntax)
				return
			}
			b = hi * 16 + lo
			i += 1
		}
		if o != nil { put(o, b) or_return }
		n += 1
	}
	return n, true
}

utf8_encode :: proc "contextless" (c: u32, out: ^[4]u8) -> int {
	switch {
	case c < 0x80:
		out[0] = u8(c)
		return 1
	case c < 0x800:
		out[0] = u8(0xc0 | c >> 6)
		out[1] = u8(0x80 | c & 0x3f)
		return 2
	case c < 0x10000:
		out[0] = u8(0xe0 | c >> 12)
		out[1] = u8(0x80 | (c >> 6) & 0x3f)
		out[2] = u8(0x80 | c & 0x3f)
		return 3
	}
	out[0] = u8(0xf0 | c >> 18)
	out[1] = u8(0x80 | (c >> 12) & 0x3f)
	out[2] = u8(0x80 | (c >> 6) & 0x3f)
	out[3] = u8(0x80 | c & 0x3f)
	return 4
}

// Parses the hex digits of a `\u{...}` escape. Like WABT, underscores are
// not allowed here even though the spec permits them.
parse_hex_only :: proc "contextless" (s: string) -> (value: u64, valid: bool) {
	if len(s) == 0 { return 0, false }
	for i in 0 ..< len(s) {
		d := digit_value(s[i])
		if d >= 16 { return 0, false }
		if value > 0x10ffff { return 0, false }
		value = value * 16 + u64(d)
	}
	return value, true
}

// Writes an import or export name. Escapes can spell any byte, but a name
// must still be valid UTF-8 once they are decoded.
write_name :: proc "contextless" (o: ^Out, t: Tok) -> bool {
	uleb(o, decode_string(t, nil) or_return) or_return
	start := o.len
	_ = decode_string(t, o) or_return
	if !utf8_valid(o.buf[start:o.len]) { return fail(t.start, .Syntax) }
	return true
}

// Sums the decoded length of the strings up to the closing `)`.
strings_length :: proc "contextless" () -> (total: int, ok: bool) {
	save := pos
	defer pos = save
	for {
		t := next() or_return
		if t.kind == .RParen { return total, true }
		total += decode_string(t, nil) or_return
	}
}

write_strings_then_close :: proc "contextless" (o: ^Out) -> bool {
	size := begin_size(o) or_return
	for {
		t := next() or_return
		if t.kind == .RParen { break }
		_ = decode_string(t, o) or_return
	}
	end_size(o, size)
	return true
}

// ---------------------------------------------------------------------------
// Module walk

func_type: [MAX_FUNCS]u32

// Sizes of the index spaces. Only the spaces up to `Data` are counted.
Counts :: [Space]u32

totals: Counts
imported: Counts
import_count: u32
export_count: u32
wrapped: bool

begin_module :: proc "contextless" () -> bool {
	pos = 0
	wrapped = false
	if open_form("module") or_return {
		wrapped = true
		_, _ = opt_id() or_return
		t := peek() or_return
		if is_kw(t, "binary") || is_kw(t, "quote") { return fail(t.start, .Unsupported) }
	}
	return true
}

// Where the `(` of the field that `next_field` last returned starts.
field_open: int

// Returns the keyword of the next module field; `more` is false at the end.
next_field :: proc "contextless" () -> (kw: Tok, more: bool, ok: bool) {
	t := next() or_return
	if wrapped {
		if t.kind == .RParen {
			e := next() or_return
			if e.kind != .EOF {
				fail(e.start, .Syntax)
				return
			}
			return {}, false, true
		}
	} else if t.kind == .EOF {
		return {}, false, true
	}
	if t.kind != .LParen {
		fail(t.start, .Syntax)
		return
	}
	field_open = t.start
	kw = next() or_return
	if kw.kind != .Keyword {
		fail(kw.start, .Syntax)
		return
	}
	return kw, true, true
}

Field_Kind :: enum u8 {
	Type,
	Import,
	Func,
	Table,
	Memory,
	Global,
	Export,
	Start,
	Elem,
	Data,
}

field_kind :: proc "contextless" (kw: Tok) -> (res: Field_Kind, ok: bool) {
	if kw.kind == .Keyword {
		switch text(kw) {
		case "type":
			return .Type, true
		case "import":
			return .Import, true
		case "func":
			return .Func, true
		case "table":
			return .Table, true
		case "memory":
			return .Memory, true
		case "global":
			return .Global, true
		case "export":
			return .Export, true
		case "start":
			return .Start, true
		case "elem":
			return .Elem, true
		case "data":
			return .Data, true
		case "tag", "rec":
			fail(kw.start, .Unsupported)
			return
		}
	}
	fail(kw.start, .Syntax)
	return
}

space_of_kind :: proc "contextless" (kw: Tok) -> (res: Space, ok: bool) {
	if is_kw(kw, "func") { return .Func, true }
	if is_kw(kw, "table") { return .Table, true }
	if is_kw(kw, "memory") { return .Memory, true }
	if is_kw(kw, "global") { return .Global, true }
	fail(kw.start, .Unsupported if is_kw(kw, "tag") else .Syntax)
	return
}

// The export and import descriptor byte for func, table, memory and global.
export_kind_byte :: proc "contextless" (space: Space) -> u8 {
	return u8(space) - u8(Space.Func)
}

skip_inline_exports :: proc "contextless" () -> (n: u32, ok: bool) {
	for open_form("export") or_return {
		skip_balanced() or_return
		n += 1
	}
	return n, true
}

// After `(table id? export*`: true when the table carries `(elem ...)`.
table_has_inline_elem :: proc "contextless" () -> (res: bool, ok: bool) {
	save := pos
	defer pos = save
	t := next() or_return
	if is_kw(t, "i64") || is_kw(t, "i32") { t = next() or_return }
	if !is_ref_type_kw(t) { return false, true }
	return peek_form("elem")
}

// Pass 1 lexes the whole module and records where each field starts. Every
// later pass jumps straight to the fields it writes, so text is not lexed
// again just to be skipped. The shortest field is 6 bytes, `(func)`.
MAX_FIELDS :: INPUT_CAP / 6 + 2
field_kinds: [MAX_FIELDS]Field_Kind
// The position just after each field's keyword.
field_at: [MAX_FIELDS]u32
field_count: int

// The index space of a `func`, `table`, `memory` or `global` field.
field_space :: #force_inline proc "contextless" (kind: Field_Kind) -> Space {
	return Space(u8(kind) - u8(Field_Kind.Func) + u8(Space.Func))
}

// Pass 1: names, index-space sizes and explicit types.
declare :: proc "contextless" () -> bool {
	begin_module() or_return
	defs_seen := false
	c: Counts
	for {
		kw, more := next_field() or_return
		if !more { break }
		open := field_open
		kind := field_kind(kw) or_return
		if field_count >= MAX_FIELDS { return fail(kw.start, .Limit) }
		field_kinds[field_count] = kind
		field_at[field_count] = u32(pos)
		field_count += 1
		switch kind {
		case .Type:
			id, has_id := opt_id() or_return
			if has_id { define(&names, .Type, id, type_count) or_return }
			if !(open_form("func") or_return) { return fail((peek() or_return).start, .Unsupported) }
			sig := parse_sig(.Allow) or_return
			_ = expect(.RParen) or_return
			add_explicit_type(sig) or_return
		case .Import:
			_ = expect(.String) or_return
			_ = expect(.String) or_return
			_ = expect(.LParen) or_return
			desc := next() or_return
			space := space_of_kind(desc) or_return
			if defs_seen { return fail(kw.start, .Syntax) }
			id, has_id := opt_id() or_return
			if has_id { define(&names, space, id, c[space]) or_return }
			c[space] += 1
			imported[space] += 1
			import_count += 1
			skip_balanced() or_return
		case .Func, .Table, .Memory, .Global:
			space := field_space(kind)
			id, has_id := opt_id() or_return
			export_count += skip_inline_exports() or_return
			if peek_form("import") or_return {
				if defs_seen { return fail(kw.start, .Syntax) }
				imported[space] += 1
				import_count += 1
			} else {
				defs_seen = true
				if space == .Table && (table_has_inline_elem() or_return) { c[.Elem] += 1 }
				if space == .Memory {
					save := pos
					t := peek() or_return
					if is_kw(t, "i64") || is_kw(t, "i32") { _ = next() or_return }
					if peek_form("data") or_return { c[.Data] += 1 }
					pos = save
				}
			}
			if has_id { define(&names, space, id, c[space]) or_return }
			c[space] += 1
		case .Export:
			export_count += 1
		case .Elem:
			id, has_id := opt_id() or_return
			if has_id { define(&names, .Elem, id, c[.Elem]) or_return }
			c[.Elem] += 1
		case .Data:
			id, has_id := opt_id() or_return
			if has_id { define(&names, .Data, id, c[.Data]) or_return }
			c[.Data] += 1
		case .Start:
		}
		// Everything up to here stayed inside the field, so its matching
		// `)` closes it.
		if close := match_end(open); close != 0 {
			pos = close
		} else {
			skip_balanced() or_return
		}
	}
	if c[.Func] > MAX_FUNCS { return fail(len(src), .Limit) }
	totals = c
	return true
}

local_types: [MAX_LOCALS]u8

// Pass 2: function types in text order and function bodies.
compile_functions :: proc "contextless" (code: ^Out) -> bool {
	func_index: u32 = 0
	for f in 0 ..< field_count {
		#partial switch field_kinds[f] {
		case .Import:
			pos = int(field_at[f])
			_ = next() or_return
			_ = next() or_return
			_ = expect(.LParen) or_return
			desc := next() or_return
			if is_kw(desc, "func") {
				_, _ = opt_id() or_return
				func_type[func_index] = parse_type_use(.Distinct, true) or_return
				func_index += 1
				_ = expect(.RParen) or_return
			} else {
				skip_balanced() or_return
			}
			_ = expect(.RParen) or_return
		case .Func:
			pos = int(field_at[f])
			_, _ = opt_id() or_return
			_ = skip_inline_exports() or_return
			if open_form("import") or_return {
				skip_balanced() or_return
				func_type[func_index] = parse_type_use(.Distinct, true) or_return
				_ = expect(.RParen) or_return
			} else {
				compile_body(code, func_index) or_return
			}
			func_index += 1
		}
	}
	// Constant expressions compiled later must not see the last function's
	// (or import's) parameter and local names.
	table_reset(&locals)
	return true
}

compile_body :: proc "contextless" (code: ^Out, func_index: u32) -> bool {
	table_reset(&locals)
	type_index := parse_type_use(.Bind, true) or_return
	func_type[func_index] = type_index
	nparams: u32 = type_np[type_index] if type_index < type_count else 0
	nlocals := 0
	for open_form("local") or_return {
		id, has_id := opt_id() or_return
		if has_id {
			if nlocals >= MAX_LOCALS { return fail(id.start, .Limit) }
			define(&locals, .Local, id, nparams + u32(nlocals)) or_return
			local_types[nlocals] = valtype(next() or_return) or_return
			nlocals += 1
			_ = expect(.RParen) or_return
			continue
		}
		for {
			t := next() or_return
			if t.kind == .RParen { break }
			if nlocals >= MAX_LOCALS { return fail(t.start, .Limit) }
			local_types[nlocals] = valtype(t) or_return
			nlocals += 1
		}
	}

	body := begin_size(code) or_return
	groups := 0
	for i in 0 ..< nlocals {
		if i == 0 || local_types[i] != local_types[i - 1] { groups += 1 }
	}
	uleb(code, groups) or_return
	for i := 0; i < nlocals; {
		j := i + 1
		for j < nlocals && local_types[j] == local_types[i] { j += 1 }
		uleb(code, j - i) or_return
		put(code, local_types[i]) or_return
		i = j
	}
	label_len = 0
	const_expr_then_close(code) or_return
	end_size(code, body)
	return true
}

write_limits :: proc "contextless" (o: ^Out, is64: bool, shared: bool) -> bool {
	lo := nat_tok(next() or_return) or_return
	has_max := (peek() or_return).kind == .Num
	hi: u64 = 0
	if has_max { hi = nat_tok(next() or_return) or_return }
	// Like WABT, 32-bit limits are not range-checked; validation rejects
	// values above 2^32 - 1.
	flags: u8 = 1 if has_max else 0
	if shared { flags |= 2 }
	if is64 { flags |= 4 }
	put(o, flags) or_return
	uleb(o, lo) or_return
	if has_max { uleb(o, hi) or_return }
	return true
}

index_type :: proc "contextless" () -> (is64: bool, ok: bool) {
	t := peek() or_return
	if is_kw(t, "i64") {
		_ = next() or_return
		return true, true
	}
	if is_kw(t, "i32") { _ = next() or_return }
	return false, true
}

// `i64? min max? reftype )`, written as reftype then limits.
table_type_then_close :: proc "contextless" (o: ^Out) -> bool {
	is64 := index_type() or_return
	save := pos
	_ = next() or_return
	if (peek() or_return).kind == .Num { _ = next() or_return }
	ref_tok := next() or_return
	ref := valtype(ref_tok) or_return
	if ref != 0x70 && ref != 0x6f { return fail(ref_tok.start, .Syntax) }
	after := pos
	put(o, ref) or_return
	pos = save
	write_limits(o, is64, false) or_return
	pos = after
	_ = expect(.RParen) or_return
	return true
}

// `i64? min max? shared? )`
mem_type_then_close :: proc "contextless" (o: ^Out) -> bool {
	return write_limits_after_index_type(o, index_type() or_return)
}

write_limits_after_index_type :: proc "contextless" (o: ^Out, is64: bool) -> bool {
	save := pos
	_ = next() or_return
	if (peek() or_return).kind == .Num { _ = next() or_return }
	shared := is_kw(peek() or_return, "shared")
	pos = save
	write_limits(o, is64, shared) or_return
	if shared { _ = next() or_return }
	t := peek() or_return
	if t.kind == .LParen { return fail(t.start, .Unsupported) }
	_ = expect(.RParen) or_return
	return true
}

// `valtype | (mut valtype)`
global_type :: proc "contextless" (o: ^Out) -> bool {
	if open_form("mut") or_return {
		put(o, valtype(next() or_return) or_return) or_return
		put(o, 1) or_return
		_ = expect(.RParen) or_return
	} else {
		put(o, valtype(next() or_return) or_return) or_return
		put(o, 0) or_return
	}
	return true
}

write_imports :: proc "contextless" (o: ^Out) -> bool {
	c: Counts
	for f in 0 ..< field_count {
		kind := field_kinds[f]
		#partial switch kind {
		case .Import:
			pos = int(field_at[f])
			write_name(o, next() or_return) or_return
			write_name(o, next() or_return) or_return
			_ = expect(.LParen) or_return
			space := space_of_kind(next() or_return) or_return
			_, _ = opt_id() or_return
			write_import_desc(o, space, &c) or_return
			_ = expect(.RParen) or_return
		case .Func, .Table, .Memory, .Global:
			pos = int(field_at[f])
			space := field_space(kind)
			_, _ = opt_id() or_return
			_ = skip_inline_exports() or_return
			if open_form("import") or_return {
				write_name(o, next() or_return) or_return
				write_name(o, next() or_return) or_return
				_ = expect(.RParen) or_return
				write_import_desc(o, space, &c) or_return
			} else {
				c[space] += 1
			}
		}
	}
	return true
}

// Writes an import descriptor and consumes through its closing `)`.
write_import_desc :: proc "contextless" (o: ^Out, space: Space, c: ^Counts) -> bool {
	put(o, export_kind_byte(space)) or_return
	#partial switch space {
	case .Func:
		uleb(o, func_type[c[.Func]]) or_return
		skip_balanced() or_return
	case .Table:
		table_type_then_close(o) or_return
	case .Memory:
		mem_type_then_close(o) or_return
	case .Global:
		global_type(o) or_return
		_ = expect(.RParen) or_return
	}
	c[space] += 1
	return true
}

// Counts elements in an element list up to `)` without consuming it.
count_elem_items :: proc "contextless" () -> (n: u32, ok: bool) {
	save := pos
	defer pos = save
	for {
		t := next() or_return
		if t.kind == .RParen { return n, true }
		if t.kind == .LParen {
			skip_balanced() or_return
		} else if !is_var(t) {
			fail(t.start, .Syntax)
			return
		}
		n += 1
	}
}

write_tables :: proc "contextless" (o: ^Out) -> bool {
	for f in 0 ..< field_count {
		if field_kinds[f] != .Table { continue }
		pos = int(field_at[f])
		_, _ = opt_id() or_return
		_ = skip_inline_exports() or_return
		if peek_form("import") or_return { continue }
		if table_has_inline_elem() or_return {
			is64 := index_type() or_return
			ref := valtype(next() or_return) or_return
			_ = open_form("elem") or_return
			n := count_elem_items() or_return
			put(o, ref) or_return
			put(o, 5 if is64 else 1) or_return
			uleb(o, n) or_return
			uleb(o, n) or_return
			skip_balanced() or_return
			_ = expect(.RParen) or_return
		} else {
			t := peek() or_return
			if t.kind == .LParen { return fail(t.start, .Unsupported) }
			table_type_then_close(o) or_return
		}
	}
	return true
}

write_memories :: proc "contextless" (o: ^Out) -> bool {
	for f in 0 ..< field_count {
		if field_kinds[f] != .Memory { continue }
		pos = int(field_at[f])
		_, _ = opt_id() or_return
		_ = skip_inline_exports() or_return
		if peek_form("import") or_return { continue }
		is64 := index_type() or_return
		if open_form("data") or_return {
			size := strings_length() or_return
			pages := (size + 0xffff) / 0x10000
			put(o, 5 if is64 else 1) or_return
			uleb(o, pages) or_return
			uleb(o, pages) or_return
			skip_balanced() or_return
			_ = expect(.RParen) or_return
		} else {
			write_limits_after_index_type(o, is64) or_return
		}
	}
	return true
}

write_globals :: proc "contextless" (o: ^Out) -> bool {
	for f in 0 ..< field_count {
		if field_kinds[f] != .Global { continue }
		pos = int(field_at[f])
		_, _ = opt_id() or_return
		_ = skip_inline_exports() or_return
		if peek_form("import") or_return { continue }
		global_type(o) or_return
		label_len = 0
		const_expr_then_close(o) or_return
	}
	return true
}

write_exports :: proc "contextless" (o: ^Out) -> bool {
	c: Counts
	for f in 0 ..< field_count {
		kind := field_kinds[f]
		pos = int(field_at[f])
		#partial switch kind {
		case .Import:
			_ = next() or_return
			_ = next() or_return
			_ = expect(.LParen) or_return
			space := space_of_kind(next() or_return) or_return
			c[space] += 1
		case .Func, .Table, .Memory, .Global:
			space := field_space(kind)
			_, _ = opt_id() or_return
			for open_form("export") or_return {
				write_name(o, next() or_return) or_return
				_ = expect(.RParen) or_return
				put(o, export_kind_byte(space)) or_return
				uleb(o, c[space]) or_return
			}
			c[space] += 1
		case .Export:
			write_name(o, next() or_return) or_return
			_ = expect(.LParen) or_return
			space := space_of_kind(next() or_return) or_return
			put(o, export_kind_byte(space)) or_return
			uleb(o, var_index(space, next() or_return) or_return) or_return
			_ = expect(.RParen) or_return
			_ = expect(.RParen) or_return
		}
	}
	return true
}

find_start :: proc "contextless" () -> (start: u32, found: bool, ok: bool) {
	for f in 0 ..< field_count {
		if field_kinds[f] != .Start { continue }
		// A second start field fails at its keyword.
		if found {
			fail(int(field_at[f]) - 5, .Syntax)
			return
		}
		pos = int(field_at[f])
		start = var_index(.Func, next() or_return) or_return
		found = true
		_ = expect(.RParen) or_return
	}
	return start, found, true
}

// Matches `(ref.func x)`, `(item ref.func x)` or `(item (ref.func x))` and
// returns `x`. Leaves the position unchanged when the item is anything else.
ref_func_item :: proc "contextless" () -> (res: Tok, found: bool, ok: bool) {
	save := pos
	res, found = ref_func_item_at_pos() or_return
	if !found { pos = save }
	return res, found, true
}

ref_func_item_at_pos :: proc "contextless" () -> (res: Tok, found: bool, ok: bool) {
	if (next() or_return).kind != .LParen { return {}, false, true }
	kw := next() or_return
	closes := 1
	if is_kw(kw, "item") {
		t := next() or_return
		if t.kind == .LParen {
			if !is_kw(next() or_return, "ref.func") { return {}, false, true }
			closes = 2
		} else if !is_kw(t, "ref.func") {
			return {}, false, true
		}
	} else if !is_kw(kw, "ref.func") {
		return {}, false, true
	}
	v := next() or_return
	if !is_var(v) { return {}, false, true }
	for _ in 0 ..< closes {
		if (next() or_return).kind != .RParen { return {}, false, true }
	}
	return v, true, true
}

Elem_Mode :: enum u8 {
	Active,
	Passive,
	Declared,
}

Offset_Kind :: enum u8 {
	At,
	Zero32,
	Zero64,
}

Offset_Source :: struct {
	kind: Offset_Kind,
	at:   int,
}

// Encodes `(offset instr*)` or a single folded instruction, then `end`.
offset_expr :: proc "contextless" (o: ^Out, wrapper: string) -> bool {
	label_len = 0
	if open_form(wrapper) or_return {
		encode_instrs(o, false) or_return
		_ = expect(.RParen) or_return
	} else {
		encode_instrs(o, true) or_return
	}
	return put(o, 0x0b)
}

// Writes one element segment from its element list, which starts at `pos`
// and ends with the `)` of the enclosing form (consumed).
write_elem_segment :: proc "contextless" (o: ^Out, mode: Elem_Mode, table: u32, offset: Offset_Source, ref: u8, exprs: bool) -> bool {
	list := pos
	all_ref_func := ref == 0x70
	n: u32 = 0
	for {
		t := peek() or_return
		if t.kind == .RParen { break }
		if exprs {
			_, found := ref_func_item() or_return
			if !found {
				all_ref_func = false
				_ = expect(.LParen) or_return
				skip_balanced() or_return
			}
		} else {
			if !is_var(t) { return fail(t.start, .Syntax) }
			_ = next() or_return
		}
		n += 1
	}

	flags: u8
	switch mode {
	case .Active:
		// Flags 0 and 4 imply funcref, so other types name the table.
		flags = 2 if table != 0 || ref != 0x70 else 0
	case .Passive:
		flags = 1
	case .Declared:
		flags = 3
	}
	if !all_ref_func { flags |= 4 }
	put(o, flags) or_return
	if flags & 2 != 0 && mode == .Active { uleb(o, table) or_return }
	if mode == .Active {
		switch offset.kind {
		case .At:
			pos = offset.at
			offset_expr(o, "offset") or_return
		case .Zero32:
			put3(o, 0x41, 0x00, 0x0b) or_return
		case .Zero64:
			put3(o, 0x42, 0x00, 0x0b) or_return
		}
	}
	if flags & 3 != 0 { put(o, ref if flags & 4 != 0 else 0x00) or_return }
	uleb(o, n) or_return

	pos = list
	for _ in 0 ..< n {
		if !exprs {
			uleb(o, var_index(.Func, next() or_return) or_return) or_return
		} else if all_ref_func {
			v, _ := ref_func_item() or_return
			uleb(o, var_index(.Func, v) or_return) or_return
		} else {
			offset_expr(o, "item") or_return
		}
	}
	_ = expect(.RParen) or_return
	return true
}

write_elems :: proc "contextless" (o: ^Out) -> bool {
	table_index: u32 = 0
	for f in 0 ..< field_count {
		kind := field_kinds[f]
		pos = int(field_at[f])
		if kind == .Import {
			_ = next() or_return
			_ = next() or_return
			_ = expect(.LParen) or_return
			if is_kw(next() or_return, "table") { table_index += 1 }
		} else if kind == .Table {
			_, _ = opt_id() or_return
			_ = skip_inline_exports() or_return
			if (peek_form("import") or_return) || !(table_has_inline_elem() or_return) {
				table_index += 1
				continue
			}
			is64 := index_type() or_return
			ref := valtype(next() or_return) or_return
			_ = open_form("elem") or_return
			exprs := (peek() or_return).kind == .LParen
			zero := Offset_Source{.Zero64 if is64 else .Zero32, 0}
			write_elem_segment(o, .Active, table_index, zero, ref, exprs) or_return
			_ = expect(.RParen) or_return
			table_index += 1
		} else if kind == .Elem {
			write_elem_field(o) or_return
		}
	}
	return true
}

write_elem_field :: proc "contextless" (o: ^Out) -> bool {
	_, _ = opt_id() or_return
	mode: Elem_Mode = .Passive
	table: u32 = 0
	if is_kw(peek() or_return, "declare") {
		_ = next() or_return
		mode = .Declared
	}
	if open_form("table") or_return {
		table = var_index(.Table, next() or_return) or_return
		_ = expect(.RParen) or_return
	} else if (peek() or_return).kind == .Num {
		table = u32_tok(next() or_return) or_return
	}
	offset := Offset_Source{.Zero32, 0}
	if mode != .Declared && (peek() or_return).kind == .LParen && !(peek_form("item") or_return) {
		offset = Offset_Source{.At, pos}
		mode = .Active
		_ = next() or_return
		skip_balanced() or_return
	}
	t := peek() or_return
	ref: u8 = 0x70
	exprs := false
	if is_kw(t, "func") {
		_ = next() or_return
	} else if is_ref_type_kw(t) {
		_ = next() or_return
		ref = valtype(t) or_return
		exprs = true
	} else if t.kind == .LParen {
		return fail(t.start, .Unsupported)
	}
	return write_elem_segment(o, mode, table, offset, ref, exprs)
}

// Writes the header of an active data segment up to its offset expression.
active_data_header :: proc "contextless" (o: ^Out, memory: u32) -> bool {
	if memory != 0 {
		put(o, 2) or_return
		return uleb(o, memory)
	}
	return put(o, 0)
}

write_datas :: proc "contextless" (o: ^Out) -> bool {
	memory_index: u32 = 0
	for f in 0 ..< field_count {
		kind := field_kinds[f]
		pos = int(field_at[f])
		if kind == .Import {
			_ = next() or_return
			_ = next() or_return
			_ = expect(.LParen) or_return
			if is_kw(next() or_return, "memory") { memory_index += 1 }
		} else if kind == .Memory {
			_, _ = opt_id() or_return
			_ = skip_inline_exports() or_return
			if peek_form("import") or_return {
				memory_index += 1
				continue
			}
			is64 := index_type() or_return
			if open_form("data") or_return {
				active_data_header(o, memory_index) or_return
				put3(o, 0x42 if is64 else 0x41, 0x00, 0x0b) or_return
				write_strings_then_close(o) or_return
			}
			memory_index += 1
		} else if kind == .Data {
			write_data_field(o) or_return
		}
	}
	return true
}

write_data_field :: proc "contextless" (o: ^Out) -> bool {
	_, _ = opt_id() or_return
	memory: u32 = 0
	if open_form("memory") or_return {
		memory = var_index(.Memory, next() or_return) or_return
		_ = expect(.RParen) or_return
	} else if is_var(peek() or_return) {
		memory = var_index(.Memory, next() or_return) or_return
	}
	if (peek() or_return).kind == .LParen {
		active_data_header(o, memory) or_return
		offset_expr(o, "offset") or_return
	} else {
		put(o, 1) or_return
	}
	return write_strings_then_close(o)
}

assemble :: proc "contextless" (code: ^Out) -> (size: int, ok: bool) {
	out := out_init(output_buf[:])
	o := &out
	put_bytes(o, {0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00}) or_return

	if type_count > 0 {
		put(o, 1) or_return
		s := begin_size(o) or_return
		uleb(o, type_count) or_return
		for i in 0 ..< type_count {
			put(o, 0x60) or_return
			uleb(o, type_np[i]) or_return
			put_bytes(o, type_pool[type_off[i]:][:type_np[i]]) or_return
			uleb(o, type_nr[i]) or_return
			put_bytes(o, type_pool[type_off[i] + type_np[i]:][:type_nr[i]]) or_return
		}
		end_size(o, s)
	}
	if import_count > 0 {
		put(o, 2) or_return
		s := begin_size(o) or_return
		uleb(o, import_count) or_return
		write_imports(o) or_return
		end_size(o, s)
	}
	defined_funcs := totals[.Func] - imported[.Func]
	if defined_funcs > 0 {
		put(o, 3) or_return
		s := begin_size(o) or_return
		uleb(o, defined_funcs) or_return
		for i in imported[.Func] ..< totals[.Func] { uleb(o, func_type[i]) or_return }
		end_size(o, s)
	}
	if totals[.Table] > imported[.Table] {
		put(o, 4) or_return
		s := begin_size(o) or_return
		uleb(o, totals[.Table] - imported[.Table]) or_return
		write_tables(o) or_return
		end_size(o, s)
	}
	if totals[.Memory] > imported[.Memory] {
		put(o, 5) or_return
		s := begin_size(o) or_return
		uleb(o, totals[.Memory] - imported[.Memory]) or_return
		write_memories(o) or_return
		end_size(o, s)
	}
	if totals[.Global] > imported[.Global] {
		put(o, 6) or_return
		s := begin_size(o) or_return
		uleb(o, totals[.Global] - imported[.Global]) or_return
		write_globals(o) or_return
		end_size(o, s)
	}
	if export_count > 0 {
		put(o, 7) or_return
		s := begin_size(o) or_return
		uleb(o, export_count) or_return
		write_exports(o) or_return
		end_size(o, s)
	}
	start, has_start := find_start() or_return
	if has_start {
		put(o, 8) or_return
		s := begin_size(o) or_return
		uleb(o, start) or_return
		end_size(o, s)
	}
	if totals[.Elem] > 0 {
		put(o, 9) or_return
		s := begin_size(o) or_return
		uleb(o, totals[.Elem]) or_return
		write_elems(o) or_return
		end_size(o, s)
	}
	if uses_data_count && totals[.Data] > 0 {
		put(o, 12) or_return
		s := begin_size(o) or_return
		uleb(o, totals[.Data]) or_return
		end_size(o, s)
	}
	if defined_funcs > 0 {
		put(o, 10) or_return
		s := begin_size(o) or_return
		uleb(o, defined_funcs) or_return
		put_bytes(o, code.buf[:code.len]) or_return
		end_size(o, s)
	}
	if totals[.Data] > 0 {
		put(o, 11) or_return
		s := begin_size(o) or_return
		uleb(o, totals[.Data]) or_return
		write_datas(o) or_return
		end_size(o, s)
	}
	return o.len, true
}

compile :: proc "contextless" (source: []u8) -> (size: int, ok: bool) {
	if !ops_ready { init_ops() }
	src = source
	lex_all()
	pos = 0
	field_count = 0
	names.slots = name_slots[:]
	names.cap = MAX_NAMES
	locals.slots = local_slots[:]
	locals.cap = MAX_NAMED_LOCALS
	table_reset(&names)
	table_reset(&locals)
	sig_generation += 1
	if sig_generation == 0 {
		for &g in sig_gen { g = 0 }
		sig_generation = 1
	}
	type_count = 0
	pool_len = 0
	totals = {}
	imported = {}
	import_count = 0
	export_count = 0
	uses_data_count = false
	frame_len = 0
	label_len = 0

	declare() or_return
	code := out_init(code_buf[:])
	compile_functions(&code) or_return
	return assemble(&code)
}

// ---------------------------------------------------------------------------
// QIP exports

@(export)
input_ptr :: proc "contextless" () -> u32 {
	return u32(uintptr(&input_buf[0]))
}

@(export)
input_utf8_cap :: proc "contextless" () -> u32 {
	return INPUT_CAP
}

@(export)
output_bytes_cap :: proc "contextless" () -> u32 {
	return OUTPUT_CAP
}

@(export)
output_content_type_ptr :: proc "contextless" () -> u32 {
	return u32(uintptr(raw_data(output_content_type)))
}

@(export)
output_content_type_size :: proc "contextless" () -> u32 {
	return u32(len(output_content_type))
}

@(export)
failure_modes_per_input_offset :: proc "contextless" () -> u32 {
	return FAILURE_MODES
}

// Returns the output size in the low 32 bits and the output pointer in the
// next 31. When the top bit is set the input was rejected and the low 32
// bits hold `input_offset * FAILURE_MODES + failure_mode`.
@(export)
render :: proc "contextless" (input_size: u32) -> u64 {
	if input_size > INPUT_CAP { intrinsics.trap() }
	size, ok := compile(input_buf[:input_size])
	if !ok {
		return (u64(1) << 63) | u64(fail_offset * FAILURE_MODES + u32(fail_mode))
	}
	return (u64(uintptr(&output_buf[0])) << 32) | u64(size)
}
