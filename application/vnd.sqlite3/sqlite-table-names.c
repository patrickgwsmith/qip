#include <stdint.h>
#include <stddef.h>

#define INPUT_CAP (5u * 1024u * 1024u)
#define OUTPUT_CAP (256u * 1024u)

static unsigned char input_buffer[INPUT_CAP];
static unsigned char output_buffer[OUTPUT_CAP];
static const char input_content_type[] = "application/vnd.sqlite3";
static uint32_t output_len;
static int output_overflow;
static uint32_t page_size;
static uint32_t page_count;

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

__attribute__((export_name("output_utf8_cap")))
uint32_t output_utf8_cap() {
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

static uint16_t read_u16_be(uint32_t off, uint32_t size, int *ok) {
    if (off + 2 > size) {
        *ok = 0;
        return 0;
    }
    *ok = 1;
    return (uint16_t)((input_buffer[off] << 8) | input_buffer[off + 1]);
}

static uint32_t read_u32_be(uint32_t off, uint32_t size, int *ok) {
    if (off + 4 > size) {
        *ok = 0;
        return 0;
    }
    *ok = 1;
    return ((uint32_t)input_buffer[off] << 24) |
           ((uint32_t)input_buffer[off + 1] << 16) |
           ((uint32_t)input_buffer[off + 2] << 8) |
           ((uint32_t)input_buffer[off + 3]);
}

static uint64_t read_varint(uint32_t off, uint32_t size, uint32_t *used) {
    uint64_t v = 0;
    *used = 0;
    for (uint32_t i = 0; i < 9; i++) {
        if (off + i >= size) {
            *used = 0;
            return 0;
        }
        unsigned char c = input_buffer[off + i];
        if (i == 8) {
            v = (v << 8) | (uint64_t)c;
            *used = 9;
            return v;
        }
        v = (v << 7) | (uint64_t)(c & 0x7F);
        if ((c & 0x80) == 0) {
            *used = i + 1;
            return v;
        }
    }
    return v;
}

static void output_append(const unsigned char *data, uint32_t len) {
    if (output_overflow || len == 0) {
        return;
    }
    if (output_len + len > OUTPUT_CAP) {
        output_overflow = 1;
        return;
    }
    for (uint32_t i = 0; i < len; i++) {
        output_buffer[output_len + i] = data[i];
    }
    output_len += len;
}

static void output_append_byte(unsigned char c) {
    if (output_overflow) {
        return;
    }
    if (output_len + 1 > OUTPUT_CAP) {
        output_overflow = 1;
        return;
    }
    output_buffer[output_len++] = c;
}

static int bytes_eq(const unsigned char *a, uint32_t a_len, const char *b, uint32_t b_len) {
    if (a_len != b_len) {
        return 0;
    }
    for (uint32_t i = 0; i < a_len; i++) {
        if (a[i] != (unsigned char)b[i]) {
            return 0;
        }
    }
    return 1;
}

static int bytes_prefix(const unsigned char *a, uint32_t a_len, const char *b, uint32_t b_len) {
    if (a_len < b_len) {
        return 0;
    }
    for (uint32_t i = 0; i < b_len; i++) {
        if (a[i] != (unsigned char)b[i]) {
            return 0;
        }
    }
    return 1;
}

static uint32_t serial_size(uint64_t serial) {
    if (serial == 0) return 0;
    if (serial == 1) return 1;
    if (serial == 2) return 2;
    if (serial == 3) return 3;
    if (serial == 4) return 4;
    if (serial == 5) return 6;
    if (serial == 6) return 8;
    if (serial == 7) return 8;
    if (serial == 8) return 0;
    if (serial == 9) return 0;
    if (serial >= 12) {
        if ((serial & 1u) == 0) {
            return (uint32_t)((serial - 12) / 2);
        }
        return (uint32_t)((serial - 13) / 2);
    }
    return 0;
}

static int serial_is_text(uint64_t serial) {
    return serial >= 13 && (serial & 1u);
}

static void parse_schema_record(const unsigned char *payload, uint32_t payload_size) {
    uint32_t used = 0;
    if (payload_size == 0) {
        return;
    }
    uint64_t header_size = read_varint((uint32_t)(payload - input_buffer), (uint32_t)(payload - input_buffer + payload_size), &used);
    if (used == 0 || header_size > payload_size) {
        return;
    }
    uint32_t header_off = used;
    uint64_t serials[5] = {0, 0, 0, 0, 0};
    uint32_t serial_count = 0;

    while (header_off < header_size && serial_count < 5) {
        uint32_t vused = 0;
        uint64_t val = read_varint((uint32_t)(payload - input_buffer) + header_off,
                                   (uint32_t)(payload - input_buffer + payload_size),
                                   &vused);
        if (vused == 0) {
            return;
        }
        serials[serial_count++] = val;
        header_off += vused;
    }

    uint32_t data_off = (uint32_t)header_size;
    const unsigned char *type_ptr = NULL;
    uint32_t type_len = 0;
    const unsigned char *name_ptr = NULL;
    uint32_t name_len = 0;

    for (uint32_t i = 0; i < serial_count; i++) {
        uint32_t size = serial_size(serials[i]);
        if (data_off + size > payload_size) {
            return;
        }
        if (i == 0 && serial_is_text(serials[i])) {
            type_ptr = payload + data_off;
            type_len = size;
        }
        if (i == 1 && serial_is_text(serials[i])) {
            name_ptr = payload + data_off;
            name_len = size;
        }
        data_off += size;
    }

    if (type_ptr == NULL || name_ptr == NULL) {
        return;
    }
    if (!bytes_eq(type_ptr, type_len, "table", 5)) {
        return;
    }
    if (bytes_prefix(name_ptr, name_len, "sqlite_", 7)) {
        return;
    }

    output_append(name_ptr, name_len);
    output_append_byte('\n');
}

static void parse_table_leaf(uint32_t page_num, uint32_t input_size) {
    if (page_num == 0 || page_num > page_count) {
        return;
    }
    uint32_t page_offset = (page_num - 1) * page_size;
    if (page_offset >= input_size) {
        return;
    }
    uint32_t header_offset = page_offset + (page_num == 1 ? 100u : 0u);
    if (header_offset + 8 > input_size) {
        return;
    }
    unsigned char page_type = input_buffer[header_offset];
    if (page_type == 0x05) {
        int ok = 0;
        uint16_t cell_count = read_u16_be(header_offset + 3, input_size, &ok);
        if (!ok) {
            return;
        }
        uint32_t cell_ptrs = header_offset + 12;
        for (uint16_t i = 0; i < cell_count; i++) {
            uint32_t ptr_off = cell_ptrs + (uint32_t)i * 2u;
            uint16_t cell_ptr = read_u16_be(ptr_off, input_size, &ok);
            if (!ok) {
                return;
            }
            uint32_t cell_off = page_offset + cell_ptr;
            if (cell_off + 4 > input_size) {
                return;
            }
            uint32_t child = read_u32_be(cell_off, input_size, &ok);
            if (!ok) {
                return;
            }
            parse_table_leaf(child, input_size);
        }
        uint32_t right_ptr = read_u32_be(header_offset + 8, input_size, &ok);
        if (ok) {
            parse_table_leaf(right_ptr, input_size);
        }
        return;
    }
    if (page_type != 0x0d) {
        return;
    }

    int ok = 0;
    uint16_t cell_count = read_u16_be(header_offset + 3, input_size, &ok);
    if (!ok) {
        return;
    }
    uint32_t cell_ptrs = header_offset + 8;

    for (uint16_t i = 0; i < cell_count; i++) {
        uint32_t ptr_off = cell_ptrs + (uint32_t)i * 2u;
        uint16_t cell_ptr = read_u16_be(ptr_off, input_size, &ok);
        if (!ok) {
            return;
        }
        uint32_t cell_off = page_offset + cell_ptr;
        if (cell_off >= input_size) {
            return;
        }
        uint32_t used1 = 0;
        uint64_t payload_size = read_varint(cell_off, input_size, &used1);
        if (used1 == 0) {
            return;
        }
        uint32_t used2 = 0;
        (void)read_varint(cell_off + used1, input_size, &used2);
        if (used2 == 0) {
            return;
        }
        uint32_t payload_off = cell_off + used1 + used2;
        if (payload_off + payload_size > input_size) {
            return;
        }
        parse_schema_record(input_buffer + payload_off, (uint32_t)payload_size);
    }
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
        input_size = INPUT_CAP;
    }
    output_len = 0;
    output_overflow = 0;

    if (input_size < 100) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }
    const char magic[] = "SQLite format 3\000";
    for (uint32_t i = 0; i < 16; i++) {
        if (input_buffer[i] != (unsigned char)magic[i]) {
            return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
        }
    }

    int ok = 0;
    uint16_t ps = read_u16_be(16, input_size, &ok);
    if (!ok) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }
    if (ps == 1) {
        page_size = 65536u;
    } else {
        page_size = ps;
    }
    if (page_size == 0) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }
    page_count = (input_size + page_size - 1) / page_size;

    parse_table_leaf(1, input_size);

    if (output_len > 0 && output_buffer[output_len - 1] == '\n') {
        output_len--;
    }
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(output_len);
}
