package hello_odin

import "base:intrinsics"

INPUT_CAP :: 64 * 1024
OUTPUT_CAP :: 64 * 1024
PREFIX_LEN :: 7
DEFAULT_LEN :: 5

input_buf: [INPUT_CAP]u8
output_buf: [OUTPUT_CAP]u8

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

@(export)
render :: proc "contextless" (input_size: u32) -> u64 {
	if input_size > INPUT_CAP || input_size + PREFIX_LEN > OUTPUT_CAP {
		intrinsics.trap()
	}

	prefix := "Hello, "
	for i in 0..<PREFIX_LEN {
		output_buf[i] = prefix[i]
	}

	if input_size > 0 {
		for i: u32 = 0; i < input_size; i += 1 {
			output_buf[PREFIX_LEN + int(i)] = input_buf[i]
		}
		return (u64(u32(uintptr(&output_buf[0]))) << 32) | u64(PREFIX_LEN + input_size)
	}

	default_name := "World"
	for i in 0..<DEFAULT_LEN {
		output_buf[PREFIX_LEN + i] = default_name[i]
	}
	return (u64(u32(uintptr(&output_buf[0]))) << 32) | u64(PREFIX_LEN + DEFAULT_LEN)
}
