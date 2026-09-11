package ktx2_rgba32float_bt709_linear_resize_up_mitchell_odin_simd

import "base:intrinsics"
import "core:math"

MAX_PIXELS :: 25_000_000
MAX_DIMENSION :: 8192
HEADER_SIZE :: 224
CAP :: HEADER_SIZE + MAX_PIXELS * 16
MAX_AXIS_WEIGHTS :: MAX_DIMENSION * 8
Vec4 :: #simd[4]f32

input_buf: [CAP]u8
output_buf: [CAP]u8
intermediate: [MAX_PIXELS]f32
axis_first: [MAX_DIMENSION]u16
axis_offsets: [MAX_DIMENSION + 1]u32
axis_weights: [MAX_AXIS_WEIGHTS]f32
target_width: u32
target_height: u32
content_type := [10]u8{'i', 'm', 'a', 'g', 'e', '/', 'k', 't', 'x', '2'}

IDENTIFIER := [12]u8{0xab, 'K', 'T', 'X', ' ', '2', '0', 0xbb, 0x0d, 0x0a, 0x1a, 0x0a}
DFD := [92]u8{
	0x5c, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x58, 0, 1, 1, 1, 0,
	0, 0, 0, 0, 0x10, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0x1f, 0xc0, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
	0x20, 0, 0x1f, 0xc1, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
	0x40, 0, 0x1f, 0xc2, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
	0x60, 0, 0x1f, 0xcf, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
}
KVD := [24]u8{
	0x12, 0, 0, 0, 'K', 'T', 'X', 'o', 'r', 'i', 'e', 'n',
	't', 'a', 't', 'i', 'o', 'n', 0, 'r', 'd', 0, 0, 0,
}

read_u32 :: proc "contextless" (data: [^]u8, offset: int) -> u32 {
	return u32(data[offset]) | u32(data[offset + 1]) << 8 |
	       u32(data[offset + 2]) << 16 | u32(data[offset + 3]) << 24
}

read_u64 :: proc "contextless" (data: [^]u8, offset: int) -> u64 {
	return u64(read_u32(data, offset)) | u64(read_u32(data, offset + 4)) << 32
}

write_u32 :: proc "contextless" (data: [^]u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

write_u64 :: proc "contextless" (data: [^]u8, offset: int, value: u64) {
	write_u32(data, offset, u32(value))
	write_u32(data, offset + 4, u32(value >> 32))
}

equal_bytes :: proc "contextless" (data: [^]u8, offset: int, expected: [^]u8, count: int) -> bool {
	for i in 0..<count {
		if data[offset + i] != expected[i] do return false
	}
	return true
}

parse_input :: proc "contextless" (input_size: int) -> (width, height, pixel_count: int, ok: bool) {
	if input_size < HEADER_SIZE || !equal_bytes(&input_buf[0], 0, &IDENTIFIER[0], len(IDENTIFIER)) do return
	if read_u32(&input_buf[0], 12) != 109 || read_u32(&input_buf[0], 16) != 4 do return
	width = int(read_u32(&input_buf[0], 20))
	height = int(read_u32(&input_buf[0], 24))
	if width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION do return
	pixel_count = width * height
	if pixel_count > MAX_PIXELS || input_size != HEADER_SIZE + pixel_count * 16 do return
	if read_u32(&input_buf[0], 28) != 0 || read_u32(&input_buf[0], 32) != 0 ||
	   read_u32(&input_buf[0], 36) != 1 || read_u32(&input_buf[0], 40) != 1 ||
	   read_u32(&input_buf[0], 44) != 0 || read_u32(&input_buf[0], 48) != 104 ||
	   read_u32(&input_buf[0], 52) != len(DFD) || read_u32(&input_buf[0], 56) != 196 ||
	   read_u32(&input_buf[0], 60) != len(KVD) {
		return
	}
	pixel_bytes := u64(pixel_count * 16)
	if read_u64(&input_buf[0], 64) != 0 || read_u64(&input_buf[0], 72) != 0 ||
	   read_u64(&input_buf[0], 80) != HEADER_SIZE || read_u64(&input_buf[0], 88) != pixel_bytes ||
	   read_u64(&input_buf[0], 96) != pixel_bytes {
		return
	}
	if !equal_bytes(&input_buf[0], 104, &DFD[0], len(DFD)) ||
	   !equal_bytes(&input_buf[0], 196, &KVD[0], len(KVD)) {
		return
	}
	ok = true
	return
}

mitchell :: proc "contextless" (value: f32) -> f32 {
	x := abs(value)
	if x >= 2 do return 0
	if x < 1 do return ((7*x - 12)*x*x + f32(16.0/3.0)) / 6
	return (((f32(-7.0/3.0)*x + 12)*x - 20)*x + f32(32.0/3.0)) / 6
}

build_axis_plan :: proc "contextless" (source_size, destination_size: int) {
	if source_size == destination_size {
		axis_offsets[0] = 0
		for index in 0..<destination_size {
			axis_first[index] = u16(index)
			axis_weights[index] = 1
			axis_offsets[index + 1] = u32(index + 1)
		}
		return
	}

	scale := f32(destination_size) / f32(source_size)
	weight_cursor := 0
	axis_offsets[0] = 0
	for destination in 0..<destination_size {
		center := (f32(destination) + 0.5) / scale - 0.5
		first_unclamped := i32(math.ceil(center - 2))
		last_unclamped := i32(math.floor(center + 2))
		first := max(first_unclamped, 0)
		last := min(last_unclamped, i32(source_size - 1))
		if first > last do intrinsics.trap()
		axis_first[destination] = u16(first)

		start := weight_cursor
		stored_count := int(last - first + 1)
		if weight_cursor + stored_count > MAX_AXIS_WEIGHTS do intrinsics.trap()
		for index in weight_cursor..<weight_cursor + stored_count do axis_weights[index] = 0
		weight_cursor += stored_count

		for source := first_unclamped; source <= last_unclamped; source += 1 {
			clamped_source := min(max(source, first), last)
			weight := mitchell(f32(source) - center)
			axis_weights[start + int(clamped_source - first)] += weight
		}

		total: f32
		for index in start..<weight_cursor do total += axis_weights[index]
		if !(abs(total) >= 0.000001) do intrinsics.trap()
		for index in start..<weight_cursor do axis_weights[index] /= total
		axis_offsets[destination + 1] = u32(weight_cursor)
	}
}

source_channel :: proc "contextless" (pixels: [^]f32, pixel, channel: int) -> f32 {
	offset := pixel * 4
	alpha := pixels[offset + 3]
	if channel == 3 do return alpha
	return pixels[offset + channel] * alpha
}

horizontal_pass :: proc "contextless" (source: [^]f32, source_width, source_height, destination_width, channel: int) {
	for y in 0..<source_height {
		for x in 0..<destination_width {
			sum: f32
			source_x := int(axis_first[x])
			weight_index := int(axis_offsets[x])
			weight_end := int(axis_offsets[x + 1])
			for weight_index < weight_end {
				sum += source_channel(source, y*source_width + source_x, channel) * axis_weights[weight_index]
				source_x += 1
				weight_index += 1
			}
			intermediate[y*destination_width + x] = sum
		}
	}
}

vertical_pass :: proc "contextless" (destination_width, destination_height, channel: int, destination: [^]f32) {
	for y in 0..<destination_height {
		x := 0
		for x + 4 <= destination_width {
			sum: Vec4
			source_y := int(axis_first[y])
			weight_index := int(axis_offsets[y])
			weight_end := int(axis_offsets[y + 1])
			for weight_index < weight_end {
				samples := intrinsics.unaligned_load(cast(^Vec4)(&intermediate[source_y*destination_width + x]))
				weight: Vec4 = axis_weights[weight_index]
				sum = intrinsics.simd_add(sum, intrinsics.simd_mul(samples, weight))
				source_y += 1
				weight_index += 1
			}
			lanes := transmute([4]f32)sum
			for lane in 0..<4 {
				offset := (y*destination_width + x + lane) * 4
				if channel == 3 {
					destination[offset + 3] = min(f32(1), max(f32(0), lanes[lane]))
				} else {
					alpha := destination[offset + 3]
					destination[offset + channel] = lanes[lane] / alpha if alpha > 0.000001 else 0
				}
			}
			x += 4
		}
		for x < destination_width {
			sum: f32
			source_y := int(axis_first[y])
			weight_index := int(axis_offsets[y])
			weight_end := int(axis_offsets[y + 1])
			for weight_index < weight_end {
				sum += intermediate[source_y*destination_width + x] * axis_weights[weight_index]
				source_y += 1
				weight_index += 1
			}
			offset := (y*destination_width + x) * 4
			if channel == 3 {
				destination[offset + 3] = min(f32(1), max(f32(0), sum))
			} else {
				alpha := destination[offset + 3]
				destination[offset + channel] = sum / alpha if alpha > 0.000001 else 0
			}
			x += 1
		}
	}
}

@(export)
input_ptr :: proc "contextless" () -> u32 { return u32(uintptr(&input_buf[0])) }
@(export)
input_bytes_cap :: proc "contextless" () -> u32 { return CAP }
@(export)
output_bytes_cap :: proc "contextless" () -> u32 { return CAP }
@(export)
input_content_type_ptr :: proc "contextless" () -> u32 { return u32(uintptr(&content_type[0])) }
@(export)
input_content_type_size :: proc "contextless" () -> u32 { return len(content_type) }
@(export)
output_content_type_ptr :: proc "contextless" () -> u32 { return u32(uintptr(&content_type[0])) }
@(export)
output_content_type_size :: proc "contextless" () -> u32 { return len(content_type) }
@(export)
failure_modes_per_input_offset :: proc "contextless" () -> u32 { return 0 }
@(export)
uniform_set_width :: proc "contextless" (value: u32) -> u32 {
	target_width = min(value, MAX_DIMENSION)
	return target_width
}
@(export)
uniform_set_height :: proc "contextless" (value: u32) -> u32 {
	target_height = min(value, MAX_DIMENSION)
	return target_height
}

@(export)
render :: proc "contextless" (input_size: u32) -> u64 {
	source_width, source_height, _, ok := parse_input(int(input_size))
	if !ok do intrinsics.trap()
	width, height := int(target_width), int(target_height)
	target_width, target_height = 0, 0
	if width == 0 && height == 0 {
		width, height = source_width*2, source_height*2
	} else if width == 0 {
		width = max(1, (height*source_width + source_height/2) / source_height)
	} else if height == 0 {
		height = max(1, (width*source_height + source_width/2) / source_width)
	}
	if width < source_width || height < source_height || width > MAX_DIMENSION || height > MAX_DIMENSION || width*height > MAX_PIXELS {
		return u64(1) << 63
	}

	for index in 0..<HEADER_SIZE do output_buf[index] = input_buf[index]
	write_u32(&output_buf[0], 20, u32(width))
	write_u32(&output_buf[0], 24, u32(height))
	pixel_bytes := u64(width*height*16)
	write_u64(&output_buf[0], 88, pixel_bytes)
	write_u64(&output_buf[0], 96, pixel_bytes)

	source := cast([^]f32)(&input_buf[HEADER_SIZE])
	destination := cast([^]f32)(&output_buf[HEADER_SIZE])
	build_axis_plan(source_width, width)
	horizontal_pass(source, source_width, source_height, width, 3)
	build_axis_plan(source_height, height)
	vertical_pass(width, height, 3, destination)
	for channel in 0..<3 {
		build_axis_plan(source_width, width)
		horizontal_pass(source, source_width, source_height, width, channel)
		build_axis_plan(source_height, height)
		vertical_pass(width, height, channel, destination)
	}

	output_size := u32(HEADER_SIZE + int(pixel_bytes))
	return u64(output_size) | u64(u32(uintptr(&output_buf[0]))) << 32
}
