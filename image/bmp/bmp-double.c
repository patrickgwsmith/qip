#include <stdint.h>
#include <stddef.h>

#define INPUT_CAP (8 * 1024 * 1024)
#define OUTPUT_CAP (32 * 1024 * 1024)

static unsigned char input_buffer[INPUT_CAP];
static unsigned char output_buffer[OUTPUT_CAP];
static const char input_content_type[] = "image/bmp";
static const char output_content_type[] = "image/bmp";

__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_bytes_cap")))
uint32_t input_bytes_cap() {
    return INPUT_CAP;
}

static uint32_t
output_ptr() {
    return (uint32_t)(uintptr_t)output_buffer;
}

__attribute__((export_name("output_bytes_cap")))
uint32_t output_bytes_cap() {
    return OUTPUT_CAP;
}

__attribute__((export_name("input_content_type_ptr")))
uint32_t input_content_type_ptr() {
    return (uint32_t)(uintptr_t)input_content_type;
}

__attribute__((export_name("input_content_type_size")))
uint32_t input_content_type_size() {
    return (uint32_t)(sizeof(input_content_type) - 1);
}

__attribute__((export_name("output_content_type_ptr")))
uint32_t output_content_type_ptr() {
    return (uint32_t)(uintptr_t)output_content_type;
}

__attribute__((export_name("output_content_type_size")))
uint32_t output_content_type_size() {
    return (uint32_t)(sizeof(output_content_type) - 1);
}

static uint16_t read_u16_le(uint32_t off) {
    return (uint16_t)(input_buffer[off] | (input_buffer[off + 1] << 8));
}

static uint32_t read_u32_le(uint32_t off) {
    return (uint32_t)(input_buffer[off] |
        (input_buffer[off + 1] << 8) |
        (input_buffer[off + 2] << 16) |
        (input_buffer[off + 3] << 24));
}

static int32_t read_i32_le(uint32_t off) {
    return (int32_t)read_u32_le(off);
}

static void write_u16_le(uint32_t off, uint16_t value) {
    output_buffer[off] = (unsigned char)(value & 0xFF);
    output_buffer[off + 1] = (unsigned char)((value >> 8) & 0xFF);
}

static void write_u32_le(uint32_t off, uint32_t value) {
    output_buffer[off] = (unsigned char)(value & 0xFF);
    output_buffer[off + 1] = (unsigned char)((value >> 8) & 0xFF);
    output_buffer[off + 2] = (unsigned char)((value >> 16) & 0xFF);
    output_buffer[off + 3] = (unsigned char)((value >> 24) & 0xFF);
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size < 54) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }
    if (input_buffer[0] != 'B' || input_buffer[1] != 'M') {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    uint32_t pixel_offset = read_u32_le(10);
    uint32_t dib_size = read_u32_le(14);
    if (pixel_offset < 54 || dib_size < 40) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    int32_t width = read_i32_le(18);
    int32_t height = read_i32_le(22);
    uint16_t planes = read_u16_le(26);
    uint16_t bpp = read_u16_le(28);
    uint32_t compression = read_u32_le(30);

    if (planes != 1 || bpp != 32 || compression != 0) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }
    if (width <= 0 || height == 0) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    int top_down = 0;
    uint32_t abs_height = (uint32_t)height;
    if (height < 0) {
        top_down = 1;
        abs_height = (uint32_t)(-height);
    }

    uint32_t uwidth = (uint32_t)width;
    uint32_t src_stride = uwidth * 4u;
    uint64_t src_pixels = (uint64_t)src_stride * (uint64_t)abs_height;
    if (pixel_offset + src_pixels > input_size) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    uint32_t out_width = uwidth * 2u;
    uint32_t out_height = abs_height * 2u;
    uint32_t out_stride = out_width * 4u;
    uint64_t out_pixels = (uint64_t)out_stride * (uint64_t)out_height;
    uint64_t out_size = (uint64_t)pixel_offset + out_pixels;
    if (out_size > OUTPUT_CAP) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    // Copy header and update size fields.
    for (uint32_t i = 0; i < pixel_offset; i++) {
        output_buffer[i] = input_buffer[i];
    }
    write_u32_le(2, (uint32_t)out_size);
    write_u32_le(18, out_width);
    write_u32_le(22, top_down ? (uint32_t)(-((int32_t)out_height)) : out_height);
    write_u32_le(34, (uint32_t)out_pixels);

    const unsigned char *src = input_buffer + pixel_offset;
    unsigned char *dst = output_buffer + pixel_offset;

    for (uint32_t y = 0; y < abs_height; y++) {
        uint32_t src_row = top_down ? y : (abs_height - 1 - y);
        uint32_t out_y0 = y * 2u;
        uint32_t out_y1 = out_y0 + 1u;
        uint32_t dst_row0 = top_down ? out_y0 : (out_height - 1 - out_y0);
        uint32_t dst_row1 = top_down ? out_y1 : (out_height - 1 - out_y1);
        const unsigned char *src_row_ptr = src + src_row * src_stride;
        unsigned char *dst_row_ptr0 = dst + dst_row0 * out_stride;
        unsigned char *dst_row_ptr1 = dst + dst_row1 * out_stride;

        for (uint32_t x = 0; x < uwidth; x++) {
            const unsigned char *px = src_row_ptr + x * 4u;
            uint32_t out_x = x * 2u;
            unsigned char *d0 = dst_row_ptr0 + out_x * 4u;
            unsigned char *d1 = dst_row_ptr1 + out_x * 4u;

            d0[0] = px[0]; d0[1] = px[1]; d0[2] = px[2]; d0[3] = px[3];
            d0[4] = px[0]; d0[5] = px[1]; d0[6] = px[2]; d0[7] = px[3];

            d1[0] = px[0]; d1[1] = px[1]; d1[2] = px[2]; d1[3] = px[3];
            d1[4] = px[0]; d1[5] = px[1]; d1[6] = px[2]; d1[7] = px[3];
        }
    }

    return ((uint64_t)output_ptr() << 32) | (uint32_t)((uint32_t)out_size);
}
