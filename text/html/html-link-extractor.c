#include <stdint.h>
#include <stddef.h>

#define INPUT_CAP 65536
#define OUTPUT_CAP 65536

static unsigned char input_buffer[INPUT_CAP];
static unsigned char output_buffer[OUTPUT_CAP];
static const char input_content_type[] = "text/html";

// Extract <a> links and compute a simplified accessible name.
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

enum {
    TAG_NONE = 0,
    TAG_A = 1,
    TAG_IMG = 2,
    TAG_BR = 3,
    TAG_P = 4,
    TAG_LI = 5,
    TAG_SCRIPT = 6,
    TAG_STYLE = 7
};

enum {
    ATTR_NONE = 0,
    ATTR_HREF = 1,
    ATTR_ARIA_LABEL = 2,
    ATTR_ARIA_LABELLEDBY = 3,
    ATTR_ALT = 4,
    ATTR_ID = 5
};

enum {
    NAME_TEXT = 0,
    NAME_LABELLEDBY = 1,
    NAME_LABEL = 2
};

typedef struct {
    uint32_t out;
    int text_started;
    int prev_space;
    int need_sep;
} TextState;

typedef struct {
    int self_closing;
    int href_present;
    uint32_t href_start;
    uint32_t href_len;
    int aria_label_present;
    uint32_t aria_label_start;
    uint32_t aria_label_len;
    int aria_labelledby_present;
    uint32_t aria_labelledby_start;
    uint32_t aria_labelledby_len;
    int alt_present;
    uint32_t alt_start;
    uint32_t alt_len;
    int id_present;
    uint32_t id_start;
    uint32_t id_len;
} Attrs;

static int is_whitespace(unsigned char c) {
    return c == 32 || c == 9 || c == 10 || c == 12 || c == 13;
}

static int is_alpha(unsigned char c) {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

static int is_digit(unsigned char c) {
    return c >= 48 && c <= 57;
}

static int is_hex_digit(unsigned char c) {
    return (c >= 48 && c <= 57) ||
        (c >= 65 && c <= 70) ||
        (c >= 97 && c <= 102);
}

static uint32_t hex_value(unsigned char c) {
    if (c >= 48 && c <= 57) {
        return (uint32_t)(c - 48);
    }
    if (c >= 65 && c <= 70) {
        return (uint32_t)(c - 65 + 10);
    }
    return (uint32_t)(c - 97 + 10);
}

static unsigned char to_lower(unsigned char c) {
    if (c >= 65 && c <= 90) {
        return (unsigned char)(c + 32);
    }
    return c;
}

static int is_name_char(unsigned char c) {
    return is_alpha(c) || is_digit(c) || c == '-' || c == '_' || c == ':';
}

static int match_ci(uint32_t start, uint32_t len, const char *str, uint32_t str_len) {
    uint32_t i = 0;
    if (len != str_len) {
        return 0;
    }
    for (; i < len; i++) {
        if (to_lower(input_buffer[start + i]) != (unsigned char)str[i]) {
            return 0;
        }
    }
    return 1;
}

static int match_ci_range(uint32_t a_start, uint32_t a_len, uint32_t b_start, uint32_t b_len) {
    uint32_t i = 0;
    if (a_len != b_len) {
        return 0;
    }
    for (; i < a_len; i++) {
        if (to_lower(input_buffer[a_start + i]) != to_lower(input_buffer[b_start + i])) {
            return 0;
        }
    }
    return 1;
}

static int match_exact(uint32_t a_start, uint32_t a_len, uint32_t b_start, uint32_t b_len) {
    uint32_t i = 0;
    if (a_len != b_len) {
        return 0;
    }
    for (; i < a_len; i++) {
        if (input_buffer[a_start + i] != input_buffer[b_start + i]) {
            return 0;
        }
    }
    return 1;
}

static int decode_entity(uint32_t pos, uint32_t end, uint32_t *consumed, uint32_t *codepoint) {
    if (pos + 2 >= end || input_buffer[pos] != '&') {
        return 0;
    }
    uint32_t i = pos + 1;
    if (input_buffer[i] == '#') {
        i++;
        int hex = 0;
        if (i < end && (input_buffer[i] == 'x' || input_buffer[i] == 'X')) {
            hex = 1;
            i++;
        }
        uint32_t base = hex ? 16u : 10u;
        uint32_t value = 0;
        uint32_t digits = 0;
        for (; i < end; i++) {
            unsigned char c = input_buffer[i];
            if (c == ';') {
                break;
            }
            uint32_t digit = 0;
            if (hex) {
                if (!is_hex_digit(c)) {
                    return 0;
                }
                digit = hex_value(c);
            } else {
                if (!is_digit(c)) {
                    return 0;
                }
                digit = (uint32_t)(c - 48);
            }
            if (value > (0x10FFFFu - digit) / base) {
                return 0;
            }
            value = value * base + digit;
            digits++;
        }
        if (digits == 0 || i >= end || input_buffer[i] != ';') {
            return 0;
        }
        if ((value >= 0xD800 && value <= 0xDFFF) || value == 0) {
            return 0;
        }
        *consumed = (i - pos) + 1;
        *codepoint = value;
        return 1;
    }

    uint32_t name_start = i;
    while (i < end && is_alpha(input_buffer[i])) {
        i++;
    }
    if (i >= end || input_buffer[i] != ';') {
        return 0;
    }
    uint32_t name_len = i - name_start;
    if (name_len == 3 && match_ci(name_start, name_len, "amp", 3)) {
        *codepoint = '&';
    } else if (name_len == 2 && match_ci(name_start, name_len, "lt", 2)) {
        *codepoint = '<';
    } else if (name_len == 2 && match_ci(name_start, name_len, "gt", 2)) {
        *codepoint = '>';
    } else if (name_len == 4 && match_ci(name_start, name_len, "quot", 4)) {
        *codepoint = '"';
    } else if (name_len == 4 && match_ci(name_start, name_len, "apos", 4)) {
        *codepoint = '\'';
    } else if (name_len == 4 && match_ci(name_start, name_len, "nbsp", 4)) {
        *codepoint = 0xA0;
    } else {
        return 0;
    }
    *consumed = (i - pos) + 1;
    return 1;
}

static int tag_type(uint32_t start, uint32_t len) {
    if (match_ci(start, len, "a", 1)) {
        return TAG_A;
    }
    if (match_ci(start, len, "img", 3)) {
        return TAG_IMG;
    }
    if (match_ci(start, len, "br", 2)) {
        return TAG_BR;
    }
    if (match_ci(start, len, "p", 1)) {
        return TAG_P;
    }
    if (match_ci(start, len, "li", 2)) {
        return TAG_LI;
    }
    if (match_ci(start, len, "script", 6)) {
        return TAG_SCRIPT;
    }
    if (match_ci(start, len, "style", 5)) {
        return TAG_STYLE;
    }
    return TAG_NONE;
}

static int attr_type(uint32_t start, uint32_t len) {
    if (match_ci(start, len, "href", 4)) {
        return ATTR_HREF;
    }
    if (match_ci(start, len, "aria-label", 10)) {
        return ATTR_ARIA_LABEL;
    }
    if (match_ci(start, len, "aria-labelledby", 14)) {
        return ATTR_ARIA_LABELLEDBY;
    }
    if (match_ci(start, len, "alt", 3)) {
        return ATTR_ALT;
    }
    if (match_ci(start, len, "id", 2)) {
        return ATTR_ID;
    }
    return ATTR_NONE;
}

static uint32_t skip_whitespace(uint32_t pos, uint32_t limit) {
    while (pos < limit && is_whitespace(input_buffer[pos])) {
        pos++;
    }
    return pos;
}

static uint32_t skip_to_gt(uint32_t pos, uint32_t limit) {
    while (pos < limit && input_buffer[pos] != '>') {
        pos++;
    }
    if (pos < limit) {
        pos++;
    }
    return pos;
}

static void append_byte(TextState *st, unsigned char b) {
    if (st->out < OUTPUT_CAP) {
        output_buffer[st->out] = b;
        st->out++;
    }
}

static void append_codepoint(TextState *st, uint32_t codepoint) {
    if (codepoint <= 0x7F) {
        append_byte(st, (unsigned char)codepoint);
        return;
    }
    if (codepoint <= 0x7FF) {
        if (st->out + 2 > OUTPUT_CAP) {
            return;
        }
        output_buffer[st->out++] = (unsigned char)(0xC0 | (codepoint >> 6));
        output_buffer[st->out++] = (unsigned char)(0x80 | (codepoint & 0x3F));
        return;
    }
    if (codepoint <= 0xFFFF) {
        if (st->out + 3 > OUTPUT_CAP) {
            return;
        }
        output_buffer[st->out++] = (unsigned char)(0xE0 | (codepoint >> 12));
        output_buffer[st->out++] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3F));
        output_buffer[st->out++] = (unsigned char)(0x80 | (codepoint & 0x3F));
        return;
    }
    if (codepoint <= 0x10FFFF) {
        if (st->out + 4 > OUTPUT_CAP) {
            return;
        }
        output_buffer[st->out++] = (unsigned char)(0xF0 | (codepoint >> 18));
        output_buffer[st->out++] = (unsigned char)(0x80 | ((codepoint >> 12) & 0x3F));
        output_buffer[st->out++] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3F));
        output_buffer[st->out++] = (unsigned char)(0x80 | (codepoint & 0x3F));
    }
}

static void append_decoded_range(TextState *st, uint32_t start, uint32_t len) {
    uint32_t pos = start;
    uint32_t end = start + len;
    while (pos < end) {
        if (input_buffer[pos] == '&') {
            uint32_t consumed = 0;
            uint32_t codepoint = 0;
            if (decode_entity(pos, end, &consumed, &codepoint)) {
                append_codepoint(st, codepoint);
                pos += consumed;
                continue;
            }
        }
        append_byte(st, input_buffer[pos]);
        pos++;
    }
}

static void append_normalized_range(TextState *st, uint32_t start, uint32_t len) {
    uint32_t pos = start;
    uint32_t end = start + len;
    while (pos < end) {
        if (input_buffer[pos] == '&') {
            uint32_t consumed = 0;
            uint32_t codepoint = 0;
            if (decode_entity(pos, end, &consumed, &codepoint)) {
                if ((codepoint <= 0x7F && is_whitespace((unsigned char)codepoint)) ||
                    codepoint == 0xA0) {
                    st->prev_space = 1;
                } else {
                    if (st->need_sep) {
                        append_byte(st, ' ');
                        st->need_sep = 0;
                    }
                    if (st->text_started && st->prev_space) {
                        append_byte(st, ' ');
                    }
                    append_codepoint(st, codepoint);
                    st->text_started = 1;
                    st->prev_space = 0;
                }
                pos += consumed;
                continue;
            }
        }
        unsigned char c = input_buffer[pos];
        if (is_whitespace(c)) {
            st->prev_space = 1;
            pos++;
            continue;
        }
        if (st->need_sep) {
            append_byte(st, ' ');
            st->need_sep = 0;
        }
        if (st->text_started && st->prev_space) {
            append_byte(st, ' ');
        }
        append_byte(st, c);
        st->text_started = 1;
        st->prev_space = 0;
        pos++;
    }
}

static uint32_t parse_attributes(uint32_t pos, uint32_t limit, Attrs *attrs) {
    while (pos < limit) {
        pos = skip_whitespace(pos, limit);
        if (pos >= limit) {
            break;
        }
        if (input_buffer[pos] == '>') {
            pos++;
            break;
        }
        if (input_buffer[pos] == '/' && pos + 1 < limit && input_buffer[pos + 1] == '>') {
            attrs->self_closing = 1;
            pos += 2;
            break;
        }

        uint32_t name_start = pos;
        while (pos < limit && is_name_char(input_buffer[pos])) {
            pos++;
        }
        uint32_t name_len = pos - name_start;
        if (name_len == 0) {
            pos++;
            continue;
        }

        pos = skip_whitespace(pos, limit);
        uint32_t value_start = 0;
        uint32_t value_len = 0;
        int has_value = 0;
        if (pos < limit && input_buffer[pos] == '=') {
            pos++;
            pos = skip_whitespace(pos, limit);
            if (pos < limit && (input_buffer[pos] == '"' || input_buffer[pos] == '\'')) {
                unsigned char quote = input_buffer[pos++];
                value_start = pos;
                while (pos < limit && input_buffer[pos] != quote) {
                    pos++;
                }
                value_len = pos - value_start;
                if (pos < limit) {
                    pos++;
                }
                has_value = 1;
            } else {
                value_start = pos;
                while (pos < limit && !is_whitespace(input_buffer[pos]) &&
                       input_buffer[pos] != '>') {
                    if (input_buffer[pos] == '/' && pos + 1 < limit &&
                        input_buffer[pos + 1] == '>') {
                        break;
                    }
                    pos++;
                }
                value_len = pos - value_start;
                has_value = 1;
            }
        }

        int type = attr_type(name_start, name_len);
        if (type == ATTR_HREF && !attrs->href_present) {
            attrs->href_present = 1;
            if (has_value) {
                attrs->href_start = value_start;
                attrs->href_len = value_len;
            }
        } else if (type == ATTR_ARIA_LABEL && !attrs->aria_label_present) {
            attrs->aria_label_present = 1;
            if (has_value) {
                attrs->aria_label_start = value_start;
                attrs->aria_label_len = value_len;
            }
        } else if (type == ATTR_ARIA_LABELLEDBY && !attrs->aria_labelledby_present) {
            attrs->aria_labelledby_present = 1;
            if (has_value) {
                attrs->aria_labelledby_start = value_start;
                attrs->aria_labelledby_len = value_len;
            }
        } else if (type == ATTR_ALT && !attrs->alt_present) {
            attrs->alt_present = 1;
            if (has_value) {
                attrs->alt_start = value_start;
                attrs->alt_len = value_len;
            }
        } else if (type == ATTR_ID && !attrs->id_present) {
            attrs->id_present = 1;
            if (has_value) {
                attrs->id_start = value_start;
                attrs->id_len = value_len;
            }
        }
    }
    return pos;
}

static void append_text_from_range(TextState *st, uint32_t pos, uint32_t end) {
    while (pos < end) {
        if (input_buffer[pos] != '<') {
            uint32_t text_start = pos;
            while (pos < end && input_buffer[pos] != '<') {
                pos++;
            }
            append_normalized_range(st, text_start, pos - text_start);
            continue;
        }

        pos++;
        if (pos >= end) {
            break;
        }

        unsigned char c = input_buffer[pos];
        if (c == '/') {
            pos++;
            pos = skip_whitespace(pos, end);
            uint32_t tag_start = pos;
            while (pos < end && is_name_char(input_buffer[pos])) {
                pos++;
            }
            uint32_t tag_len = pos - tag_start;
            int type = tag_type(tag_start, tag_len);
            if (type == TAG_P || type == TAG_LI) {
                st->prev_space = 1;
            }
            pos = skip_to_gt(pos, end);
            continue;
        }

        if (c == '!' || c == '?') {
            pos = skip_to_gt(pos, end);
            continue;
        }

        pos = skip_whitespace(pos, end);
        uint32_t tag_start = pos;
        while (pos < end && is_name_char(input_buffer[pos])) {
            pos++;
        }
        uint32_t tag_len = pos - tag_start;
        int type = tag_type(tag_start, tag_len);
        Attrs attrs = {0};
        pos = parse_attributes(pos, end, &attrs);

        if (type == TAG_IMG && attrs.alt_present) {
            append_normalized_range(st, attrs.alt_start, attrs.alt_len);
        }
        if (type == TAG_BR || type == TAG_P || type == TAG_LI) {
            st->prev_space = 1;
        }
    }
}

static uint32_t find_element_end(uint32_t pos, uint32_t input_size,
                                 uint32_t tag_start, uint32_t tag_len, int type) {
    while (pos < input_size) {
        if (input_buffer[pos] != '<') {
            pos++;
            continue;
        }
        uint32_t tag_pos = pos;
        pos++;
        if (pos >= input_size) {
            return input_size;
        }
        unsigned char c = input_buffer[pos];
        if (c == '/') {
            pos++;
            pos = skip_whitespace(pos, input_size);
            uint32_t end_start = pos;
            while (pos < input_size && is_name_char(input_buffer[pos])) {
                pos++;
            }
            uint32_t end_len = pos - end_start;
            if (match_ci_range(end_start, end_len, tag_start, tag_len)) {
                return tag_pos;
            }
            pos = skip_to_gt(pos, input_size);
            continue;
        }
        if (c == '!' || c == '?') {
            pos = skip_to_gt(pos, input_size);
            continue;
        }
        pos = skip_whitespace(pos, input_size);
        uint32_t start_start = pos;
        while (pos < input_size && is_name_char(input_buffer[pos])) {
            pos++;
        }
        uint32_t start_len = pos - start_start;
        if ((type == TAG_P || type == TAG_LI) &&
            match_ci_range(start_start, start_len, tag_start, tag_len)) {
            return tag_pos;
        }
        pos = skip_to_gt(pos, input_size);
    }
    return input_size;
}

static void append_text_for_id(TextState *st, uint32_t id_start, uint32_t id_len,
                               uint32_t input_size) {
    uint32_t pos = 0;
    while (pos < input_size) {
        if (input_buffer[pos] != '<') {
            pos++;
            continue;
        }
        pos++;
        if (pos >= input_size) {
            return;
        }
        unsigned char c = input_buffer[pos];
        if (c == '/' || c == '!' || c == '?') {
            pos = skip_to_gt(pos, input_size);
            continue;
        }

        pos = skip_whitespace(pos, input_size);
        uint32_t tag_start = pos;
        while (pos < input_size && is_name_char(input_buffer[pos])) {
            pos++;
        }
        uint32_t tag_len = pos - tag_start;
        int type = tag_type(tag_start, tag_len);
        Attrs attrs = {0};
        pos = parse_attributes(pos, input_size, &attrs);

        if (!attrs.id_present ||
            !match_exact(attrs.id_start, attrs.id_len, id_start, id_len)) {
            continue;
        }

        if (type == TAG_IMG) {
            if (attrs.alt_present) {
                append_normalized_range(st, attrs.alt_start, attrs.alt_len);
            }
            return;
        }
        if (attrs.self_closing || type == TAG_BR) {
            return;
        }

        uint32_t content_start = pos;
        uint32_t content_end = find_element_end(pos, input_size, tag_start, tag_len, type);
        append_text_from_range(st, content_start, content_end);
        return;
    }
}

static void append_labelledby(TextState *st, uint32_t start, uint32_t len,
                              uint32_t input_size) {
    uint32_t i = 0;
    while (i < len) {
        while (i < len && is_whitespace(input_buffer[start + i])) {
            i++;
        }
        if (i >= len) {
            break;
        }
        uint32_t id_start = start + i;
        while (i < len && !is_whitespace(input_buffer[start + i])) {
            i++;
        }
        uint32_t id_len = (start + i) - id_start;
        if (st->text_started) {
            st->prev_space = 1;
        }
        append_text_for_id(st, id_start, id_len, input_size);
    }
}

static void finalize_anchor(TextState *st, int emit, int name_mode,
                            uint32_t label_start, uint32_t label_len,
                            uint32_t labelledby_start, uint32_t labelledby_len,
                            uint32_t input_size) {
    if (!emit) {
        return;
    }
    if (name_mode == NAME_LABELLEDBY) {
        append_labelledby(st, labelledby_start, labelledby_len, input_size);
    } else if (name_mode == NAME_LABEL) {
        append_normalized_range(st, label_start, label_len);
    }
    append_byte(st, '\n');
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    uint32_t pos = 0;
    int inside_a = 0;
    int emit = 0;
    int name_mode = NAME_TEXT;
    uint32_t label_start = 0;
    uint32_t label_len = 0;
    uint32_t labelledby_start = 0;
    uint32_t labelledby_len = 0;

    TextState state = {0, 0, 0, 0};

    while (pos < input_size) {
        if (input_buffer[pos] != '<') {
            if (inside_a && emit && name_mode == NAME_TEXT) {
                uint32_t text_start = pos;
                while (pos < input_size && input_buffer[pos] != '<') {
                    pos++;
                }
                append_normalized_range(&state, text_start, pos - text_start);
                continue;
            }
            while (pos < input_size && input_buffer[pos] != '<') {
                pos++;
            }
            continue;
        }

        pos++;
        if (pos >= input_size) {
            break;
        }

        unsigned char c = input_buffer[pos];
        if (c == '/') {
            pos++;
            pos = skip_whitespace(pos, input_size);
            uint32_t tag_start = pos;
            while (pos < input_size && is_name_char(input_buffer[pos])) {
                pos++;
            }
            uint32_t tag_len = pos - tag_start;
            int type = tag_type(tag_start, tag_len);
            pos = skip_to_gt(pos, input_size);
            if (inside_a) {
                if (type == TAG_A) {
                    finalize_anchor(&state, emit, name_mode, label_start, label_len,
                                    labelledby_start, labelledby_len, input_size);
                    inside_a = 0;
                    emit = 0;
                    continue;
                }
                if (emit && name_mode == NAME_TEXT && (type == TAG_P || type == TAG_LI)) {
                    state.prev_space = 1;
                }
            }
            continue;
        }

        if (c == '!' || c == '?') {
            pos = skip_to_gt(pos, input_size);
            continue;
        }

        pos = skip_whitespace(pos, input_size);
        uint32_t tag_start = pos;
        while (pos < input_size && is_name_char(input_buffer[pos])) {
            pos++;
        }
        uint32_t tag_len = pos - tag_start;
        int type = tag_type(tag_start, tag_len);
        Attrs attrs = {0};
        pos = parse_attributes(pos, input_size, &attrs);

        if (type == TAG_A) {
            if (inside_a) {
                finalize_anchor(&state, emit, name_mode, label_start, label_len,
                                labelledby_start, labelledby_len, input_size);
            }
            inside_a = 1;
            emit = attrs.href_present;
            name_mode = NAME_TEXT;
            if (attrs.aria_labelledby_present) {
                name_mode = NAME_LABELLEDBY;
                labelledby_start = attrs.aria_labelledby_start;
                labelledby_len = attrs.aria_labelledby_len;
            } else if (attrs.aria_label_present) {
                name_mode = NAME_LABEL;
                label_start = attrs.aria_label_start;
                label_len = attrs.aria_label_len;
            }
            if (emit) {
                append_decoded_range(&state, attrs.href_start, attrs.href_len);
                state.text_started = 0;
                state.prev_space = 0;
                state.need_sep = attrs.href_len > 0 ? 1 : 0;
            } else {
                state.need_sep = 0;
            }
            if (attrs.self_closing) {
                finalize_anchor(&state, emit, name_mode, label_start, label_len,
                                labelledby_start, labelledby_len, input_size);
                inside_a = 0;
                emit = 0;
            }
            continue;
        }

        if (inside_a && emit && name_mode == NAME_TEXT) {
            if (type == TAG_IMG && attrs.alt_present) {
                append_normalized_range(&state, attrs.alt_start, attrs.alt_len);
            }
            if (type == TAG_BR || type == TAG_P || type == TAG_LI) {
                state.prev_space = 1;
            }
        }
    }

    if (inside_a) {
        finalize_anchor(&state, emit, name_mode, label_start, label_len,
                        labelledby_start, labelledby_len, input_size);
    }

    return ((uint64_t)output_ptr() << 32) | (uint32_t)(state.out);
}
