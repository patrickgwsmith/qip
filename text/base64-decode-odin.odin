package base64_decode_odin

import "base:intrinsics"

CAP :: 65536
input: [CAP]u8
output: [CAP]u8

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

@(export)
render :: proc "contextless" (size: u32) -> u64 {
	if size > CAP { intrinsics.trap() }
	if size & 3 != 0 { return fail(size) }
	out: u32 = 0
	for i: u32 = 0; i < size; i += 4 {
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
	}
	return (u64(u32(uintptr(&output[0]))) << 32) | u64(out)
}
