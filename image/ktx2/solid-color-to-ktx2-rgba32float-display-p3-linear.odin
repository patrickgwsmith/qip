package solid_color_to_ktx2_rgba32float_display_p3_linear

import "base:intrinsics"

MAX_PIXELS :: 8_000_000
MAX_DIMENSION :: 8192
HEADER_SIZE :: 224
CAP :: HEADER_SIZE + MAX_PIXELS * 16
DEFAULT_WIDTH :: 1200
DEFAULT_HEIGHT :: 630

buffer: [CAP]u8
width: u32 = DEFAULT_WIDTH
height: u32 = DEFAULT_HEIGHT
color_rgba: u32 = 0x000000ff
content_type := [10]u8{'i', 'm', 'a', 'g', 'e', '/', 'k', 't', 'x', '2'}

IDENTIFIER := [12]u8{0xab, 'K', 'T', 'X', ' ', '2', '0', 0xbb, 0x0d, 0x0a, 0x1a, 0x0a}
DFD := [92]u8{
	0x5c, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x58, 0, 1, 0x0c, 1, 0,
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

write_header :: proc "contextless" (image_width, image_height: int) -> (size: int, ok: bool) {
	if image_width <= 0 || image_height <= 0 || image_width > MAX_DIMENSION || image_height > MAX_DIMENSION do return
	pixel_count := image_width * image_height
	if pixel_count > MAX_PIXELS do return
	size = HEADER_SIZE + pixel_count * 16
	for index in 0..<HEADER_SIZE do buffer[index] = 0
	for index in 0..<len(IDENTIFIER) do buffer[index] = IDENTIFIER[index]
	write_u32(&buffer[0], 12, 109)
	write_u32(&buffer[0], 16, 4)
	write_u32(&buffer[0], 20, u32(image_width))
	write_u32(&buffer[0], 24, u32(image_height))
	write_u32(&buffer[0], 36, 1)
	write_u32(&buffer[0], 40, 1)
	write_u32(&buffer[0], 48, 104)
	write_u32(&buffer[0], 52, u32(len(DFD)))
	write_u32(&buffer[0], 56, 196)
	write_u32(&buffer[0], 60, u32(len(KVD)))
	pixel_bytes := u64(pixel_count * 16)
	write_u64(&buffer[0], 80, HEADER_SIZE)
	write_u64(&buffer[0], 88, pixel_bytes)
	write_u64(&buffer[0], 96, pixel_bytes)
	for index in 0..<len(DFD) do buffer[104 + index] = DFD[index]
	for index in 0..<len(KVD) do buffer[196 + index] = KVD[index]
	ok = true
	return
}

linear_channel :: proc "contextless" (value: u32, shift: u32) -> f32 {
	encoded := f32((value >> shift) & 0xff) / 255
	if encoded <= 0.04045 do return encoded / 12.92
	// Cubic approximation of the sRGB transfer curve. This keeps the
	// freestanding module import-free; the conversion happens once per render.
	return encoded * (encoded * (encoded * 0.305306011 + 0.682171111) + 0.012522878)
}

@(export)
input_ptr :: proc "contextless" () -> u32 { return u32(uintptr(&buffer[0])) }
@(export)
input_bytes_cap :: proc "contextless" () -> u32 { return CAP }
@(export)
output_bytes_cap :: proc "contextless" () -> u32 { return CAP }
@(export)
output_content_type_ptr :: proc "contextless" () -> u32 { return u32(uintptr(&content_type[0])) }
@(export)
output_content_type_size :: proc "contextless" () -> u32 { return len(content_type) }
@(export)
uniform_set_width :: proc "contextless" (value: u32) -> u32 {
	width = max(1, min(value, MAX_DIMENSION))
	return width
}
@(export)
uniform_set_height :: proc "contextless" (value: u32) -> u32 {
	height = max(1, min(value, MAX_DIMENSION))
	return height
}
@(export)
uniform_set_color_rgba :: proc "contextless" (value: u32) -> u32 {
	color_rgba = value
	return color_rgba
}

@(export)
render :: proc "contextless" (_: u32) -> u64 {
	output_size, ok := write_header(int(width), int(height))
	if !ok do return u64(1) << 63
	pixels := cast([^]f32)(&buffer[HEADER_SIZE])
	red := linear_channel(color_rgba, 24)
	green := linear_channel(color_rgba, 16)
	blue := linear_channel(color_rgba, 8)
	alpha := f32(color_rgba & 0xff) / 255
	for pixel in 0..<int(width)*int(height) {
		offset := pixel * 4
		pixels[offset] = red
		pixels[offset + 1] = green
		pixels[offset + 2] = blue
		pixels[offset + 3] = alpha
	}
	return u64(u32(output_size)) | u64(u32(uintptr(&buffer[0]))) << 32
}
