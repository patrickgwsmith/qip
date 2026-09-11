#include <stdint.h>

#define INPUT_CAP (4u * 1024u * 1024u)
#define OUTPUT_CAP (4u * 1024u * 1024u)

static char input_buffer[INPUT_CAP];

__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t input_utf8_cap() {
    return sizeof(input_buffer);
}

__attribute__((export_name("output_utf8_cap")))
uint32_t output_utf8_cap() {
    return OUTPUT_CAP;
}

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
        __builtin_trap();
    }

    uint32_t start = 0;
    while (start < input_size && is_space(input_buffer[start])) {
        start++;
    }

    uint32_t end = input_size;
    while (end > start && is_space(input_buffer[end - 1])) {
        end--;
    }

    uint32_t out_len = end - start;

    return ((uint64_t)(input_ptr() + start) << 32) | out_len;
}
