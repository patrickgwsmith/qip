// hello-c.c - qip-compatible WebAssembly module in C
#include <stdint.h>

// Static memory buffers for input and output
static char input_buffer[65536];  // 64KB
static char output_buffer[65536]; // 64KB

// Export the static input pointer and capacities.
__attribute__((export_name("input_ptr")))
uint32_t
input_ptr()
{
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t
input_utf8_cap()
{
    return sizeof(input_buffer);
}

__attribute__((export_name("output_utf8_cap")))
uint32_t
output_utf8_cap()
{
    return sizeof(output_buffer);
}

// Simple memcpy implementation
static void copy_bytes(char *dest, const char *src, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++)
    {
        dest[i] = src[i];
    }
}

// Main entry point
__attribute__((export_name("render")))
uint64_t
render(uint32_t input_size)
{
    // Example: prepend "Hello, " to input
    const char *prefix = "Hello, ";
    const uint32_t prefix_len = 7;

    // Copy prefix to output
    copy_bytes(output_buffer, prefix, prefix_len);

    // Check if we have input
    if (input_size > 0)
    {
        // Copy input after prefix
        copy_bytes(output_buffer + prefix_len, input_buffer, input_size);
        const uint32_t output_size = prefix_len + input_size;
        return ((uint64_t)(uint32_t)(uintptr_t)output_buffer << 32) |
               output_size;
    }

    // No input, default to "World"
    const char *default_name = "World";
    copy_bytes(output_buffer + prefix_len, default_name, 5);
    const uint32_t output_size = prefix_len + 5;
    return ((uint64_t)(uint32_t)(uintptr_t)output_buffer << 32) |
           output_size;
}
