#include <stdint.h>
#ifdef QIP_SIMD
#include <wasm_simd128.h>
#endif

#define CAP 65536u

static uint8_t input[CAP];
static uint8_t output[CAP];

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input; }
uint32_t input_utf8_cap(void) { return CAP; }
uint32_t output_bytes_cap(void) { return CAP; }
uint32_t failure_modes_per_input_offset(void) { return 1; }

static int32_t value(uint8_t c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static uint64_t fail(uint32_t offset) { return UINT64_C(1) << 63 | offset; }

#ifdef QIP_SIMD
// Decode four complete, unpadded quartets. The scalar tail checks padding and
// reports the precise failing input offset when a vector contains bad data.
static int decode_16(uint32_t in, uint32_t out) {
    v128_t x = wasm_v128_load(input + in);
    v128_t upper = wasm_v128_and(wasm_u8x16_ge(x, wasm_i8x16_splat('A')),
                                  wasm_u8x16_le(x, wasm_i8x16_splat('Z')));
    v128_t lower = wasm_v128_and(wasm_u8x16_ge(x, wasm_i8x16_splat('a')),
                                  wasm_u8x16_le(x, wasm_i8x16_splat('z')));
    v128_t digit = wasm_v128_and(wasm_u8x16_ge(x, wasm_i8x16_splat('0')),
                                  wasm_u8x16_le(x, wasm_i8x16_splat('9')));
    v128_t plus = wasm_i8x16_eq(x, wasm_i8x16_splat('+'));
    v128_t slash = wasm_i8x16_eq(x, wasm_i8x16_splat('/'));
    v128_t valid = wasm_v128_or(wasm_v128_or(upper, lower),
                    wasm_v128_or(digit, wasm_v128_or(plus, slash)));
    if (wasm_i8x16_bitmask(valid) != 0xffff) return 0;

    v128_t v = wasm_v128_or(
        wasm_v128_or(wasm_v128_and(upper, wasm_i8x16_sub(x, wasm_i8x16_splat('A'))),
                     wasm_v128_and(lower, wasm_i8x16_sub(x, wasm_i8x16_splat('a' - 26)))),
        wasm_v128_or(wasm_v128_and(digit, wasm_i8x16_add(wasm_i8x16_sub(x, wasm_i8x16_splat('0')), wasm_i8x16_splat(52))),
                     wasm_v128_or(wasm_v128_and(plus, wasm_i8x16_splat(62)),
                                  wasm_v128_and(slash, wasm_i8x16_splat(63)))));
    v128_t y = wasm_v128_or(
        wasm_v128_or(wasm_i32x4_shl(wasm_v128_and(v, wasm_i32x4_splat(0x3f)), 2),
                     wasm_u32x4_shr(wasm_v128_and(v, wasm_i32x4_splat(0x3000)), 12)),
        wasm_v128_or(
            wasm_v128_or(wasm_i32x4_shl(wasm_v128_and(v, wasm_i32x4_splat(0xf00)), 4),
                         wasm_u32x4_shr(wasm_v128_and(v, wasm_i32x4_splat(0x3c0000)), 10)),
            wasm_v128_or(wasm_i32x4_shl(wasm_v128_and(v, wasm_i32x4_splat(0x30000)), 6),
                         wasm_u32x4_shr(wasm_v128_and(v, wasm_i32x4_splat(0x3f000000)), 8))));
    v128_t packed = wasm_i8x16_shuffle(y, y, 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 0, 0, 0, 0);
    wasm_v128_store(output + out, packed);
    return 1;
}
#endif

uint64_t render(uint32_t size) {
    if (size > CAP) __builtin_trap();
    if (size & 3u) return fail(size);

    uint32_t out = 0;
    uint32_t i = 0;
#ifdef QIP_SIMD
    while (i + 16 < size && decode_16(i, out)) {
        i += 16;
        out += 12;
    }
#endif
    for (; i < size; i += 4) {
        int32_t a = value(input[i]);
        if (a < 0) return fail(i);
        int32_t b = value(input[i + 1]);
        if (b < 0) return fail(i + 1);
        uint8_t c = input[i + 2], d = input[i + 3];
        if (c == '=') {
            if (d != '=' || i + 4 != size) return fail(i + 2);
            if (b & 15) return fail(i + 1);
            output[out++] = (uint8_t)((a << 2) | (b >> 4));
            break;
        }
        int32_t cv = value(c);
        if (cv < 0) return fail(i + 2);
        if (d == '=') {
            if (i + 4 != size) return fail(i + 3);
            if (cv & 3) return fail(i + 2);
            output[out++] = (uint8_t)((a << 2) | (b >> 4));
            output[out++] = (uint8_t)((b << 4) | (cv >> 2));
            break;
        }
        int32_t dv = value(d);
        if (dv < 0) return fail(i + 3);
        output[out++] = (uint8_t)((a << 2) | (b >> 4));
        output[out++] = (uint8_t)((b << 4) | (cv >> 2));
        output[out++] = (uint8_t)((cv << 6) | dv);
    }
    return ((uint64_t)(uintptr_t)output << 32) | out;
}
