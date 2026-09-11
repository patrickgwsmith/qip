package wc_odin

import "base:intrinsics"

INPUT_CAP :: 4 * 1024 * 1024
OUTPUT_CAP :: 128

Counts :: struct {
	lines: u64,
	words: u64,
	bytes: u64,
}

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

is_whitespace_byte :: proc "contextless" (b: u8) -> bool {
	return b == ' ' || (b >= 0x09 && b <= 0x0d)
}

count_wc :: proc "contextless" (input_size: u32) -> Counts {
	lines: u64 = 0
	words: u64 = 0
	in_word := false

	for i: u32 = 0; i < input_size; i += 1 {
		b := input_buf[i]
		if b == '\n' {
			lines += 1
		}

		if is_whitespace_byte(b) {
			in_word = false
		} else if !in_word {
			words += 1
			in_word = true
		}
	}

	return Counts{lines = lines, words = words, bytes = u64(input_size)}
}

append_byte :: proc "contextless" (index: ^u32, b: u8) {
	if index^ >= OUTPUT_CAP {
		intrinsics.trap()
	}
	output_buf[index^] = b
	index^ += 1
}

append_right_aligned_u64 :: proc "contextless" (index: ^u32, value: u64, width: u32) {
	digits_rev: [20]u8
	digits_len: u32 = 0
	n := value

	if n == 0 {
		digits_rev[0] = '0'
		digits_len = 1
	} else {
		for n > 0 {
			d := u8(n % 10)
			digits_rev[digits_len] = '0' + d
			digits_len += 1
			n /= 10
		}
	}

	pad: u32 = 0
	if digits_len < width {
		pad = width - digits_len
	}
	for i: u32 = 0; i < pad; i += 1 {
		append_byte(index, ' ')
	}

	i := digits_len
	for i > 0 {
		i -= 1
		append_byte(index, digits_rev[i])
	}
}

format_counts :: proc "contextless" (counts: Counts) -> u32 {
	index: u32 = 0
	append_right_aligned_u64(&index, counts.lines, 8)
	append_right_aligned_u64(&index, counts.words, 8)
	append_right_aligned_u64(&index, counts.bytes, 8)
	return index
}

@(export)
render :: proc "contextless" (input_size: u32) -> u64 {
	if input_size > INPUT_CAP {
		intrinsics.trap()
	}
	output_size := format_counts(count_wc(input_size))
	return (u64(u32(uintptr(&output_buf[0]))) << 32) | u64(output_size)
}
