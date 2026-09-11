package utf8_must_be_valid_odin

import "base:intrinsics"

INPUT_CAP :: 1024 * 1024
OUTPUT_CAP :: INPUT_CAP

input_buf: [INPUT_CAP]u8

@(export)
input_ptr :: proc "contextless" () -> u32 {
	return u32(uintptr(&input_buf[0]))
}

@(export)
input_utf8_cap :: proc "contextless" () -> u32 {
	return INPUT_CAP
}

@(export)
output_utf8_cap :: proc "contextless" () -> u32 {
	return OUTPUT_CAP
}

is_continuation :: proc "contextless" (b: u8) -> bool {
	return (b & 0xc0) == 0x80
}

@(export)
render :: proc "contextless" (input_size: u32) -> u64 {
	if input_size > INPUT_CAP {
		intrinsics.trap()
	}

	i: u32 = 0
	for i < input_size {
		b := input_buf[i]
		if b <= 0x7f {
			i += 1
			continue
		}

		if b >= 0xc2 && b <= 0xdf {
			if i + 1 >= input_size {
				intrinsics.trap()
			}
			b2 := input_buf[i + 1]
			if !is_continuation(b2) {
				intrinsics.trap()
			}
			i += 2
			continue
		}

		if b >= 0xe0 && b <= 0xef {
			if i + 2 >= input_size {
				intrinsics.trap()
			}
			b2 := input_buf[i + 1]
			b3 := input_buf[i + 2]
			if !is_continuation(b2) || !is_continuation(b3) {
				intrinsics.trap()
			}
			if b == 0xe0 && b2 < 0xa0 {
				intrinsics.trap()
			}
			if b == 0xed && b2 >= 0xa0 {
				intrinsics.trap()
			}
			i += 3
			continue
		}

		if b >= 0xf0 && b <= 0xf4 {
			if i + 3 >= input_size {
				intrinsics.trap()
			}
			b2 := input_buf[i + 1]
			b3 := input_buf[i + 2]
			b4 := input_buf[i + 3]
			if !is_continuation(b2) || !is_continuation(b3) || !is_continuation(b4) {
				intrinsics.trap()
			}
			if b == 0xf0 && b2 < 0x90 {
				intrinsics.trap()
			}
			if b == 0xf4 && b2 >= 0x90 {
				intrinsics.trap()
			}
			i += 4
			continue
		}

		intrinsics.trap()
	}

	return (u64(input_ptr()) << 32) | u64(input_size)
}
