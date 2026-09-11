#include <stdint.h>
#include <stddef.h>
#include "../lib/raster-output.h"

#define INPUT_CAP 65536
#define OUTPUT_CAP (8 * 1024 * 1024)
#define GLYPH_W 8
#define GLYPH_H 8
#define LEADING 4
#define ROW_H (GLYPH_H + LEADING)
#define COLS 80

static unsigned char input_buffer[INPUT_CAP];
static unsigned char output_buffer[OUTPUT_CAP];
static const char input_content_type[] = "text/x-c";
static const char output_content_type[] = QIP_TEXT_RASTER_CONTENT_TYPE;

__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t input_utf8_cap() {
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

typedef struct {
    unsigned char r;
    unsigned char g;
    unsigned char b;
    unsigned char a;
} Color;

static void set_pixel(uint32_t width, uint32_t height, uint32_t x, uint32_t y, Color c) {
    if (x >= width || y >= height) {
        return;
    }
    qip_text_raster_set_pixel(output_buffer, width, height, x, y, c.r, c.g, c.b, c.a);
}

/* Public domain font data from https://github.com/dhepper/font8x8 */
static const unsigned char font8x8_basic[128][8] = {
    { 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    { 0x7E,0x81,0xA5,0x81,0xBD,0x99,0x81,0x7E },
    { 0x7E,0xFF,0xDB,0xFF,0xC3,0xE7,0xFF,0x7E },
    { 0x6C,0xFE,0xFE,0xFE,0x7C,0x38,0x10,0x00 },
    { 0x10,0x38,0x7C,0xFE,0x7C,0x38,0x10,0x00 },
    { 0x38,0x7C,0x38,0xFE,0xFE,0xD6,0x10,0x38 },
    { 0x10,0x38,0x7C,0xFE,0xFE,0x7C,0x10,0x38 },
    { 0x00,0x00,0x18,0x3C,0x3C,0x18,0x00,0x00 },
    { 0xFF,0xFF,0xE7,0xC3,0xC3,0xE7,0xFF,0xFF },
    { 0x00,0x3C,0x66,0x42,0x42,0x66,0x3C,0x00 },
    { 0xFF,0xC3,0x99,0xBD,0xBD,0x99,0xC3,0xFF },
    { 0x0F,0x07,0x0F,0x7D,0xCC,0xCC,0xCC,0x78 },
    { 0x3C,0x66,0x66,0x66,0x3C,0x18,0x7E,0x18 },
    { 0x3F,0x33,0x3F,0x30,0x30,0x70,0xF0,0xE0 },
    { 0x7F,0x63,0x7F,0x63,0x63,0x67,0xE6,0xC0 },
    { 0x99,0x5A,0x3C,0xE7,0xE7,0x3C,0x5A,0x99 },
    { 0x80,0xE0,0xF8,0xFE,0xF8,0xE0,0x80,0x00 },
    { 0x02,0x0E,0x3E,0xFE,0x3E,0x0E,0x02,0x00 },
    { 0x18,0x3C,0x7E,0x18,0x18,0x7E,0x3C,0x18 },
    { 0x66,0x66,0x66,0x66,0x66,0x00,0x66,0x00 },
    { 0x7F,0xDB,0xDB,0x7B,0x1B,0x1B,0x1B,0x00 },
    { 0x3E,0x61,0x3C,0x66,0x66,0x3C,0x86,0x7C },
    { 0x00,0x00,0x00,0x00,0x7E,0x7E,0x7E,0x00 },
    { 0x18,0x3C,0x7E,0x18,0x7E,0x3C,0x18,0xFF },
    { 0x18,0x3C,0x7E,0x18,0x18,0x18,0x18,0x00 },
    { 0x18,0x18,0x18,0x18,0x7E,0x3C,0x18,0x00 },
    { 0x00,0x18,0x0C,0xFE,0x0C,0x18,0x00,0x00 },
    { 0x00,0x30,0x60,0xFE,0x60,0x30,0x00,0x00 },
    { 0x00,0x00,0xC0,0xC0,0xC0,0xFE,0x00,0x00 },
    { 0x00,0x24,0x66,0xFF,0x66,0x24,0x00,0x00 },
    { 0x00,0x18,0x3C,0x7E,0xFF,0xFF,0x00,0x00 },
    { 0x00,0xFF,0xFF,0x7E,0x3C,0x18,0x00,0x00 },
    { 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    { 0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00 },
    { 0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00 },
    { 0x66,0x66,0xFF,0x66,0xFF,0x66,0x66,0x00 },
    { 0x18,0x3E,0x60,0x3C,0x06,0x7C,0x18,0x00 },
    { 0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00 },
    { 0x38,0x6C,0x38,0x76,0xDC,0xCC,0x76,0x00 },
    { 0x30,0x30,0x60,0x00,0x00,0x00,0x00,0x00 },
    { 0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00 },
    { 0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00 },
    { 0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00 },
    { 0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00 },
    { 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30 },
    { 0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00 },
    { 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00 },
    { 0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00 },
    { 0x7C,0xC6,0xCE,0xD6,0xE6,0xC6,0x7C,0x00 },
    { 0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00 },
    { 0x7C,0xC6,0x0E,0x1C,0x70,0xC0,0xFE,0x00 },
    { 0x7C,0xC6,0x06,0x3C,0x06,0xC6,0x7C,0x00 },
    { 0x1C,0x3C,0x6C,0xCC,0xFE,0x0C,0x1E,0x00 },
    { 0xFE,0xC0,0xFC,0x06,0x06,0xC6,0x7C,0x00 },
    { 0x3C,0x60,0xC0,0xFC,0xC6,0xC6,0x7C,0x00 },
    { 0xFE,0xC6,0x0C,0x18,0x30,0x30,0x30,0x00 },
    { 0x7C,0xC6,0xC6,0x7C,0xC6,0xC6,0x7C,0x00 },
    { 0x7C,0xC6,0xC6,0x7E,0x06,0x0C,0x78,0x00 },
    { 0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00 },
    { 0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30 },
    { 0x0E,0x1C,0x38,0x70,0x38,0x1C,0x0E,0x00 },
    { 0x00,0x00,0x7E,0x00,0x00,0x7E,0x00,0x00 },
    { 0x70,0x38,0x1C,0x0E,0x1C,0x38,0x70,0x00 },
    { 0x7C,0xC6,0x0E,0x1C,0x18,0x00,0x18,0x00 },
    { 0x7C,0xC6,0xDE,0xDE,0xDE,0xC0,0x78,0x00 },
    { 0x38,0x6C,0xC6,0xC6,0xFE,0xC6,0xC6,0x00 },
    { 0xFC,0x66,0x66,0x7C,0x66,0x66,0xFC,0x00 },
    { 0x3C,0x66,0xC0,0xC0,0xC0,0x66,0x3C,0x00 },
    { 0xF8,0x6C,0x66,0x66,0x66,0x6C,0xF8,0x00 },
    { 0xFE,0x62,0x68,0x78,0x68,0x62,0xFE,0x00 },
    { 0xFE,0x62,0x68,0x78,0x68,0x60,0xF0,0x00 },
    { 0x3C,0x66,0xC0,0xC0,0xCE,0x66,0x3E,0x00 },
    { 0xC6,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0x00 },
    { 0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00 },
    { 0x1E,0x0C,0x0C,0x0C,0xCC,0xCC,0x78,0x00 },
    { 0xE6,0x66,0x6C,0x78,0x6C,0x66,0xE6,0x00 },
    { 0xF0,0x60,0x60,0x60,0x62,0x66,0xFE,0x00 },
    { 0xC6,0xEE,0xFE,0xFE,0xD6,0xC6,0xC6,0x00 },
    { 0xC6,0xE6,0xF6,0xDE,0xCE,0xC6,0xC6,0x00 },
    { 0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00 },
    { 0xFC,0x66,0x66,0x7C,0x60,0x60,0xF0,0x00 },
    { 0x7C,0xC6,0xC6,0xC6,0xD6,0xCC,0x7A,0x00 },
    { 0xFC,0x66,0x66,0x7C,0x6C,0x66,0xE6,0x00 },
    { 0x7C,0xC6,0x60,0x38,0x0C,0xC6,0x7C,0x00 },
    { 0x7E,0x7E,0x5A,0x18,0x18,0x18,0x3C,0x00 },
    { 0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00 },
    { 0xC6,0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x00 },
    { 0xC6,0xC6,0xC6,0xD6,0xFE,0xEE,0xC6,0x00 },
    { 0xC6,0xC6,0x6C,0x38,0x38,0x6C,0xC6,0x00 },
    { 0x66,0x66,0x66,0x3C,0x18,0x18,0x3C,0x00 },
    { 0xFE,0xC6,0x8C,0x18,0x32,0x66,0xFE,0x00 },
    { 0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00 },
    { 0xC0,0x60,0x30,0x18,0x0C,0x06,0x02,0x00 },
    { 0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00 },
    { 0x10,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00 },
    { 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF },
    { 0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00 },
    { 0x00,0x00,0x7C,0x06,0x7E,0xC6,0x7E,0x00 },
    { 0xE0,0x60,0x7C,0x66,0x66,0x66,0xDC,0x00 },
    { 0x00,0x00,0x7C,0xC6,0xC0,0xC6,0x7C,0x00 },
    { 0x1C,0x0C,0x7C,0xCC,0xCC,0xCC,0x76,0x00 },
    { 0x00,0x00,0x7C,0xC6,0xFE,0xC0,0x7C,0x00 },
    { 0x3C,0x66,0x60,0xF8,0x60,0x60,0xF0,0x00 },
    { 0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0xF8 },
    { 0xE0,0x60,0x6C,0x76,0x66,0x66,0xE6,0x00 },
    { 0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00 },
    { 0x0C,0x00,0x1C,0x0C,0x0C,0xCC,0xCC,0x78 },
    { 0xE0,0x60,0x66,0x6C,0x78,0x6C,0xE6,0x00 },
    { 0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00 },
    { 0x00,0x00,0xEC,0xFE,0xD6,0xD6,0xC6,0x00 },
    { 0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x00 },
    { 0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0x00 },
    { 0x00,0x00,0xDC,0x66,0x66,0x7C,0x60,0xF0 },
    { 0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0x1E },
    { 0x00,0x00,0xDC,0x76,0x66,0x60,0xF0,0x00 },
    { 0x00,0x00,0x7E,0xC0,0x7C,0x06,0xFC,0x00 },
    { 0x30,0x30,0xFC,0x30,0x30,0x36,0x1C,0x00 },
    { 0x00,0x00,0xCC,0xCC,0xCC,0xCC,0x76,0x00 },
    { 0x00,0x00,0xC6,0xC6,0xC6,0x6C,0x38,0x00 },
    { 0x00,0x00,0xC6,0xD6,0xD6,0xFE,0x6C,0x00 },
    { 0x00,0x00,0xC6,0x6C,0x38,0x6C,0xC6,0x00 },
    { 0x00,0x00,0xC6,0xC6,0xC6,0x7E,0x06,0xFC },
    { 0x00,0x00,0xFE,0x4C,0x18,0x32,0xFE,0x00 },
    { 0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00 },
    { 0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00 },
    { 0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00 },
    { 0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00 },
    { 0x00,0x10,0x38,0x6C,0xC6,0xC6,0xFE,0x00 }
};

static uint32_t count_rows(uint32_t input_size) {
    uint32_t rows = 1;
    uint32_t col = 0;
    uint32_t i = 0;
    while (i < input_size) {
        unsigned char c = input_buffer[i];
        if (c == '\r') {
            if (i + 1 < input_size && input_buffer[i + 1] == '\n') {
                i++;
            }
            rows++;
            col = 0;
            i++;
            continue;
        }
        if (c == '\n') {
            rows++;
            col = 0;
            i++;
            continue;
        }
        if (c == '\t') {
            uint32_t spaces = 4 - (col % 4);
            col += spaces;
            while (col >= COLS) {
                rows++;
                col = 0;
            }
            i++;
            continue;
        }
        col++;
        if (col >= COLS) {
            rows++;
            col = 0;
        }
        i++;
    }
    return rows;
}

static int is_alpha(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

static int is_digit(unsigned char c) {
    return c >= '0' && c <= '9';
}

static int is_ident_start(unsigned char c) {
    return is_alpha(c) || c == '_' || c == '$';
}

static int is_ident_char(unsigned char c) {
    return is_ident_start(c) || is_digit(c);
}

static int match_kw(uint32_t start, uint32_t len, const char *kw) {
    uint32_t i = 0;
    while (i < len && kw[i]) {
        if (input_buffer[start + i] != (unsigned char)kw[i]) {
            return 0;
        }
        i++;
    }
    return i == len && kw[i] == 0;
}

static int is_keyword(uint32_t start, uint32_t len) {
    switch (len) {
        case 2:
            return match_kw(start, len, "if") || match_kw(start, len, "do");
        case 3:
            return match_kw(start, len, "for") || match_kw(start, len, "int");
        case 4:
            return match_kw(start, len, "auto") || match_kw(start, len, "case") ||
                   match_kw(start, len, "bool") || match_kw(start, len, "char") ||
                   match_kw(start, len, "else") || match_kw(start, len, "enum") ||
                   match_kw(start, len, "goto") || match_kw(start, len, "long") ||
                   match_kw(start, len, "true") || match_kw(start, len, "void");
        case 5:
            return match_kw(start, len, "_Bool") || match_kw(start, len, "break") ||
                   match_kw(start, len, "const") || match_kw(start, len, "false") ||
                   match_kw(start, len, "float") || match_kw(start, len, "short") ||
                   match_kw(start, len, "union") || match_kw(start, len, "while");
        case 6:
            return match_kw(start, len, "double") || match_kw(start, len, "extern") ||
                   match_kw(start, len, "inline") || match_kw(start, len, "return") ||
                   match_kw(start, len, "signed") || match_kw(start, len, "sizeof") ||
                   match_kw(start, len, "static") || match_kw(start, len, "struct") ||
                   match_kw(start, len, "switch") || match_kw(start, len, "typeof");
        case 7:
            return match_kw(start, len, "_Alignas") || match_kw(start, len, "_Alignof") ||
                   match_kw(start, len, "_Atomic") || match_kw(start, len, "_BitInt") ||
                   match_kw(start, len, "alignas") || match_kw(start, len, "alignof") ||
                   match_kw(start, len, "default") || match_kw(start, len, "nullptr") ||
                   match_kw(start, len, "typedef");
        case 8:
            return match_kw(start, len, "_Complex") || match_kw(start, len, "_Generic") ||
                   match_kw(start, len, "continue") || match_kw(start, len, "register") ||
                   match_kw(start, len, "restrict") || match_kw(start, len, "unsigned") ||
                   match_kw(start, len, "volatile");
        case 9:
            return match_kw(start, len, "_Noreturn") || match_kw(start, len, "constexpr");
        case 10:
            return match_kw(start, len, "_Imaginary");
        case 12:
            return match_kw(start, len, "thread_local");
        case 13:
            return match_kw(start, len, "_Thread_local") ||
                   match_kw(start, len, "static_assert") ||
                   match_kw(start, len, "typeof_unqual");
        case 14:
            return match_kw(start, len, "_Static_assert");
    }
    return 0;
}

static void draw_glyph(uint32_t width, uint32_t height, uint32_t row, uint32_t col,
                       unsigned char glyph, Color color) {
    if (glyph < 32 || glyph >= 128) {
        glyph = '?';
    }
    uint32_t base_x = col * GLYPH_W;
    uint32_t base_y = row * ROW_H;
    for (uint32_t gy = 0; gy < GLYPH_H; gy++) {
        unsigned char bits = font8x8_basic[glyph][gy];
        for (uint32_t gx = 0; gx < GLYPH_W; gx++) {
            if (bits & (1u << (7u - gx))) {
                set_pixel(width, height, base_x + gx, base_y + gy, color);
            }
        }
    }
}

static void draw_char(uint32_t width, uint32_t height, uint32_t *row, uint32_t *col,
                      uint32_t rows, unsigned char glyph, Color color) {
    if (*row >= rows) {
        return;
    }
    draw_glyph(width, height, *row, *col, glyph, color);
    (*col)++;
    if (*col >= COLS) {
        (*row)++;
        *col = 0;
    }
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
        input_size = INPUT_CAP;
    }

    const Color bg = { 0x16, 0x1b, 0x22, 0xFF };
    const Color fg = { 0xc9, 0xd1, 0xd9, 0xFF };
    const Color kw = { 0xff, 0x7b, 0x72, 0xFF };
    const Color str = { 0xa5, 0xd6, 0xff, 0xFF };
    const Color com = { 0x8b, 0x94, 0x9e, 0xFF };
    const Color num = { 0x79, 0xc0, 0xff, 0xFF };
    const Color pp = { 0xd2, 0xa8, 0xff, 0xFF };

    uint32_t rows = count_rows(input_size);
    uint32_t width = COLS * GLYPH_W;
    uint32_t height = rows * ROW_H;
    uint64_t pixel_bytes = (uint64_t)width * (uint64_t)height * 4u;
    uint64_t total = QIP_TEXT_RASTER_HEADER_SIZE + pixel_bytes;
    if (total > OUTPUT_CAP) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    // Clear header area and fill background pixels.
    for (uint32_t i = 0; i < QIP_TEXT_RASTER_HEADER_SIZE; i++) {
        output_buffer[i] = 0;
    }
    qip_text_raster_fill(output_buffer, total, bg.r, bg.g, bg.b, bg.a);

    if (qip_text_raster_init(output_buffer, OUTPUT_CAP, width, height) != total) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }

    uint32_t col = 0;
    uint32_t row = 0;
    uint32_t i = 0;
    int in_string = 0;
    int in_line_comment = 0;
    int in_block_comment = 0;
    unsigned char quote = 0;
    int escape = 0;
    int line_start = 1;

    while (i < input_size && row < rows) {
        unsigned char c = input_buffer[i];
        if (c == '\r' || c == '\n') {
            in_line_comment = 0;
            if (c == '\r' && i + 1 < input_size && input_buffer[i + 1] == '\n') {
                i++;
            }
            row++;
            col = 0;
            in_string = 0;
            escape = 0;
            line_start = 1;
            i++;
            continue;
        }

        if (line_start && (c == ' ' || c == '\t')) {
            if (c == '\t') {
                uint32_t spaces = 4 - (col % 4);
                col += spaces;
                while (col >= COLS) {
                    row++;
                    col = 0;
                    if (row >= rows) break;
                }
            } else {
                draw_char(width, height, &row, &col, rows, c, fg);
            }
            i++;
            continue;
        }

        if (c == '\t') {
            uint32_t spaces = 4 - (col % 4);
            col += spaces;
            while (col >= COLS) {
                row++;
                col = 0;
                if (row >= rows) break;
            }
            i++;
            continue;
        }

        if (line_start && c == '#') {
            draw_char(width, height, &row, &col, rows, c, pp);
            i++;
            while (i < input_size) {
                unsigned char ws = input_buffer[i];
                if (ws == ' ' || ws == '\t') {
                    draw_char(width, height, &row, &col, rows, ws, fg);
                    i++;
                    continue;
                }
                break;
            }
            if (i < input_size && is_ident_start(input_buffer[i])) {
                uint32_t start = i;
                i++;
                while (i < input_size && is_ident_char(input_buffer[i])) {
                    i++;
                }
                uint32_t len = i - start;
                for (uint32_t j = 0; j < len; j++) {
                    draw_char(width, height, &row, &col, rows, input_buffer[start + j], pp);
                    if (row >= rows) {
                        break;
                    }
                }
            }
            line_start = 0;
            continue;
        }

        line_start = 0;

        if (in_string) {
            draw_char(width, height, &row, &col, rows, c, str);
            if (escape) {
                escape = 0;
            } else if (c == '\\') {
                escape = 1;
            } else if (c == quote) {
                in_string = 0;
            }
            i++;
            continue;
        }

        if (in_line_comment) {
            draw_char(width, height, &row, &col, rows, c, com);
            i++;
            continue;
        }

        if (in_block_comment) {
            if (c == '*' && i + 1 < input_size && input_buffer[i + 1] == '/') {
                draw_char(width, height, &row, &col, rows, '*', com);
                draw_char(width, height, &row, &col, rows, '/', com);
                i += 2;
                in_block_comment = 0;
                continue;
            }
            draw_char(width, height, &row, &col, rows, c, com);
            i++;
            continue;
        }

        if (c == '/' && i + 1 < input_size) {
            unsigned char next = input_buffer[i + 1];
            if (next == '/') {
                draw_char(width, height, &row, &col, rows, '/', com);
                draw_char(width, height, &row, &col, rows, '/', com);
                i += 2;
                in_line_comment = 1;
                continue;
            }
            if (next == '*') {
                draw_char(width, height, &row, &col, rows, '/', com);
                draw_char(width, height, &row, &col, rows, '*', com);
                i += 2;
                in_block_comment = 1;
                continue;
            }
        }

        if (c == '\'' || c == '"' || c == '`') {
            in_string = 1;
            quote = c;
            escape = 0;
            draw_char(width, height, &row, &col, rows, c, str);
            i++;
            continue;
        }

        if (is_digit(c) || (c == '.' && i + 1 < input_size && is_digit(input_buffer[i + 1]))) {
            uint32_t start = i;
            i++;
            while (i < input_size) {
                unsigned char nc = input_buffer[i];
                if (is_digit(nc) || is_alpha(nc) || nc == '.' || nc == '_' || nc == '\'') {
                    i++;
                    continue;
                }
                if ((nc == '+' || nc == '-') && i > start) {
                    unsigned char prev = input_buffer[i - 1];
                    if (prev == 'e' || prev == 'E' || prev == 'p' || prev == 'P') {
                        i++;
                        continue;
                    }
                }
                break;
            }
            uint32_t len = i - start;
            for (uint32_t j = 0; j < len; j++) {
                draw_char(width, height, &row, &col, rows, input_buffer[start + j], num);
                if (row >= rows) {
                    break;
                }
            }
            continue;
        }

        if (is_ident_start(c)) {
            uint32_t start = i;
            i++;
            while (i < input_size && is_ident_char(input_buffer[i])) {
                i++;
            }
            uint32_t len = i - start;
            Color color = is_keyword(start, len) ? kw : fg;
            for (uint32_t j = 0; j < len; j++) {
                draw_char(width, height, &row, &col, rows, input_buffer[start + j], color);
                if (row >= rows) {
                    break;
                }
            }
            continue;
        }

        draw_char(width, height, &row, &col, rows, c, fg);
        i++;
    }

    return ((uint64_t)output_ptr() << 32) | (uint32_t)((uint32_t)total);
}
