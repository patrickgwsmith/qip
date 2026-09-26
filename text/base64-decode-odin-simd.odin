package base64_decode_odin_simd

import "base:intrinsics"

CAP :: 65536
input: [CAP]u8
output: [CAP]u8
Vec16 :: #simd[16]u8
Vec4_U32 :: #simd[4]u32

@(export)
input_ptr :: proc "contextless" () -> u32 { return u32(uintptr(&input[0])) }
@(export)
input_utf8_cap :: proc "contextless" () -> u32 { return CAP }
@(export)
output_bytes_cap :: proc "contextless" () -> u32 { return CAP }
@(export)
failure_modes_per_input_offset :: proc "contextless" () -> u32 { return 1 }

value :: proc "contextless" (c: u8) -> i32 {
	if c >= 'A' && c <= 'Z' { return i32(c) - 'A' }
	if c >= 'a' && c <= 'z' { return i32(c) - 'a' + 26 }
	if c >= '0' && c <= '9' { return i32(c) - '0' + 52 }
	if c == '+' { return 62 }
	if c == '/' { return 63 }
	return -1
}

fail :: proc "contextless" (offset: u32) -> u64 { return (u64(1) << 63) | u64(offset) }

decode_16 :: proc "contextless" (input_offset, out: u32) -> bool {
	x := transmute(Vec16)(transmute(^[16]u8)&input[input_offset])^
	upper := intrinsics.simd_bit_and(intrinsics.simd_lanes_ge(x, Vec16('A')), intrinsics.simd_lanes_le(x, Vec16('Z')))
	lower := intrinsics.simd_bit_and(intrinsics.simd_lanes_ge(x, Vec16('a')), intrinsics.simd_lanes_le(x, Vec16('z')))
	digit := intrinsics.simd_bit_and(intrinsics.simd_lanes_ge(x, Vec16('0')), intrinsics.simd_lanes_le(x, Vec16('9')))
	plus := intrinsics.simd_lanes_eq(x, Vec16('+'))
	slash := intrinsics.simd_lanes_eq(x, Vec16('/'))
	valid := intrinsics.simd_bit_or(intrinsics.simd_bit_or(upper, lower), intrinsics.simd_bit_or(digit, intrinsics.simd_bit_or(plus, slash)))
	if intrinsics.simd_reduce_and(valid) != 255 { return false }
	v := intrinsics.simd_bit_or(
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_and(upper, intrinsics.simd_sub(x, Vec16('A'))),
			intrinsics.simd_bit_and(lower, intrinsics.simd_sub(x, Vec16('a' - 26)))),
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_and(digit, intrinsics.simd_add(intrinsics.simd_sub(x, Vec16('0')), Vec16(52))),
			intrinsics.simd_bit_or(intrinsics.simd_bit_and(plus, Vec16(62)), intrinsics.simd_bit_and(slash, Vec16(63)))))
	w := transmute(Vec4_U32)v
	y := intrinsics.simd_bit_or(
		intrinsics.simd_bit_or(
			intrinsics.simd_shl(intrinsics.simd_bit_and(w, Vec4_U32(0x3f)), Vec4_U32(2)),
			intrinsics.simd_shr(intrinsics.simd_bit_and(w, Vec4_U32(0x3000)), Vec4_U32(12))),
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_or(
				intrinsics.simd_shl(intrinsics.simd_bit_and(w, Vec4_U32(0xf00)), Vec4_U32(4)),
				intrinsics.simd_shr(intrinsics.simd_bit_and(w, Vec4_U32(0x3c0000)), Vec4_U32(10))),
			intrinsics.simd_bit_or(
				intrinsics.simd_shl(intrinsics.simd_bit_and(w, Vec4_U32(0x30000)), Vec4_U32(6)),
				intrinsics.simd_shr(intrinsics.simd_bit_and(w, Vec4_U32(0x3f000000)), Vec4_U32(8)))))
	y_bytes := transmute(Vec16)y
	packed := intrinsics.simd_shuffle(y_bytes, y_bytes, 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 0, 0, 0, 0)
	(transmute(^[16]u8)&output[out])^ = transmute([16]u8)packed
	return true
}

@(export)
render :: proc "contextless" (size: u32) -> u64 {
	if size > CAP { intrinsics.trap() }
	if size & 3 != 0 { return fail(size) }
	out: u32 = 0
	i: u32 = 0
	for i + 16 < size && decode_16(i, out) {
		i += 16
		out += 12
	}
	for i < size {
		a := value(input[i])
		if a < 0 { return fail(i) }
		b := value(input[i + 1])
		if b < 0 { return fail(i + 1) }
		c, d := input[i + 2], input[i + 3]
		if c == '=' {
			if d != '=' || i + 4 != size { return fail(i + 2) }
			if b & 15 != 0 { return fail(i + 1) }
			output[out] = u8((a << 2) | (b >> 4))
			out += 1
			break
		}
		cv := value(c)
		if cv < 0 { return fail(i + 2) }
		if d == '=' {
			if i + 4 != size { return fail(i + 3) }
			if cv & 3 != 0 { return fail(i + 2) }
			output[out] = u8((a << 2) | (b >> 4))
			output[out + 1] = u8((b << 4) | (cv >> 2))
			out += 2
			break
		}
		dv := value(d)
		if dv < 0 { return fail(i + 3) }
		output[out] = u8((a << 2) | (b >> 4))
		output[out + 1] = u8((b << 4) | (cv >> 2))
		output[out + 2] = u8((cv << 6) | dv)
		out += 3
		i += 4
	}
	return (u64(u32(uintptr(&output[0]))) << 32) | u64(out)
}
