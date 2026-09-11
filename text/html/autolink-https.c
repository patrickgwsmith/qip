#include <stdint.h>
#include <stddef.h>

#define INPUT_CAP (1024 * 1024)
#define OUTPUT_CAP (4 * 1024 * 1024)

static unsigned char input_buffer[INPUT_CAP];
static unsigned char output_buffer[OUTPUT_CAP];
static const char output_content_type[] = "text/html";

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

__attribute__((export_name("output_content_type_ptr")))
uint32_t output_content_type_ptr() {
    return (uint32_t)(uintptr_t)output_content_type;
}

__attribute__((export_name("output_content_type_size")))
uint32_t output_content_type_size() {
    return (uint32_t)(sizeof(output_content_type) - 1);
}

static int is_ws(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static int is_url_stop(unsigned char c) {
    return is_ws(c) || c == '<' || c == '>' || c == '"' || c == '\'' || c == '`';
}

static unsigned char ascii_lower(unsigned char c) {
    if (c >= 'A' && c <= 'Z') {
        return (unsigned char)(c + ('a' - 'A'));
    }
    return c;
}

static int starts_with_https(const unsigned char *s, uint32_t i, uint32_t n) {
    return i + 7 < n &&
           ascii_lower(s[i]) == 'h' &&
           ascii_lower(s[i + 1]) == 't' &&
           ascii_lower(s[i + 2]) == 't' &&
           ascii_lower(s[i + 3]) == 'p' &&
           ascii_lower(s[i + 4]) == 's' &&
           s[i + 5] == ':' &&
           s[i + 6] == '/' &&
           s[i + 7] == '/';
}

static int equals_ci(const unsigned char *s, uint32_t len, const char *lit) {
    uint32_t i = 0;
    while (lit[i] != '\0' && i < 32) {
        if (i >= len) return 0;
        if (ascii_lower(s[i]) != (unsigned char)lit[i]) return 0;
        i++;
    }
    return i == len;
}

static void update_html_context(const unsigned char *s, uint32_t tag_start, uint32_t tag_end, int *raw_text_mode, int *anchor_depth, int *literal_depth) {
    uint32_t p = tag_start + 1;
    uint32_t steps = 0;
    while (p < tag_end && is_ws(s[p]) && steps < INPUT_CAP) { p++; steps++; }
    if (p >= tag_end) return;
    if (s[p] == '!' || s[p] == '?') return;

    int closing = 0;
    if (s[p] == '/') {
        closing = 1;
        p++;
    }
    steps = 0;
    while (p < tag_end && is_ws(s[p]) && steps < INPUT_CAP) { p++; steps++; }
    if (p >= tag_end) return;

    uint32_t name_start = p;
    steps = 0;
    while (p < tag_end && steps < INPUT_CAP) {
        unsigned char c = s[p];
        int alpha_num = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (!alpha_num) break;
        p++;
        steps++;
    }
    uint32_t name_len = p - name_start;
    if (name_len == 0) return;

    if (equals_ci(s + name_start, name_len, "script")) {
        if (closing && *raw_text_mode == 1) *raw_text_mode = 0;
        if (!closing) *raw_text_mode = 1;
        return;
    }
    if (equals_ci(s + name_start, name_len, "style")) {
        if (closing && *raw_text_mode == 2) *raw_text_mode = 0;
        if (!closing) *raw_text_mode = 2;
        return;
    }

    if (equals_ci(s + name_start, name_len, "a")) {
        if (closing) {
            if (*anchor_depth > 0) *anchor_depth -= 1;
        } else {
            *anchor_depth += 1;
        }
        return;
    }

    if (equals_ci(s + name_start, name_len, "pre") ||
        equals_ci(s + name_start, name_len, "code") ||
        equals_ci(s + name_start, name_len, "textarea")) {
        if (closing) {
            if (*literal_depth > 0) *literal_depth -= 1;
        } else {
            *literal_depth += 1;
        }
    }
}

static uint32_t trim_url_end(const unsigned char *s, uint32_t start, uint32_t end) {
    uint32_t steps = 0;
    while (end > start + 8 && steps < INPUT_CAP) {
        unsigned char c = s[end - 1];
        if (c == '.' || c == ',' || c == ';' || c == ':' || c == '!' || c == '?') {
            end--;
            steps++;
            continue;
        }
        if (c == ')' || c == ']' || c == '}') {
            unsigned char open = c == ')' ? '(' : (c == ']' ? '[' : '{');
            uint32_t opens = 0;
            uint32_t closes = 0;
            uint32_t scan_steps = 0;
            for (uint32_t p = start + 8; p < end && scan_steps < INPUT_CAP; p++, scan_steps++) {
                if (s[p] == open) opens++;
                if (s[p] == c) closes++;
            }
            if (closes > opens) {
                end--;
                steps++;
                continue;
            }
        }
        break;
    }
    return end;
}

static int write_slice(uint32_t *out_idx, const unsigned char *s, uint32_t len) {
    if (*out_idx + len > OUTPUT_CAP) {
        return 0;
    }
    for (uint32_t i = 0; i < len && i < OUTPUT_CAP; i++) {
        output_buffer[*out_idx + i] = s[i];
    }
    *out_idx += len;
    return 1;
}

static int write_escaped_attr(uint32_t *out_idx, const unsigned char *s, uint32_t len) {
    for (uint32_t i = 0; i < len && i < INPUT_CAP; i++) {
        unsigned char c = s[i];
        if (c == '&') {
            if (!write_slice(out_idx, (const unsigned char *)"&amp;", 5)) return 0;
        } else if (c == '<') {
            if (!write_slice(out_idx, (const unsigned char *)"&lt;", 4)) return 0;
        } else if (c == '>') {
            if (!write_slice(out_idx, (const unsigned char *)"&gt;", 4)) return 0;
        } else if (c == '"') {
            if (!write_slice(out_idx, (const unsigned char *)"&quot;", 6)) return 0;
        } else {
            if (!write_slice(out_idx, &c, 1)) return 0;
        }
    }
    return 1;
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
        input_size = INPUT_CAP;
    }

    uint32_t out_idx = 0;
    uint32_t i = 0;
    uint32_t tag_start = 0;
    int in_tag = 0;
    unsigned char tag_quote = 0;
    int raw_text_mode = 0; /* 0=none, 1=script, 2=style */
    int anchor_depth = 0;
    int literal_depth = 0;
    uint32_t render_steps = 0;

    while (i < input_size && render_steps < INPUT_CAP) {
        render_steps++;
        unsigned char c = input_buffer[i];

        if (in_tag) {
            if (!write_slice(&out_idx, &c, 1)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            if (tag_quote != 0) {
                if (c == tag_quote) {
                    tag_quote = 0;
                }
            } else {
                if (c == '"' || c == '\'') {
                    tag_quote = c;
                } else if (c == '>') {
                    in_tag = 0;
                    update_html_context(input_buffer, tag_start, i, &raw_text_mode, &anchor_depth, &literal_depth);
                }
            }
            i++;
            continue;
        }

        if (c == '<') {
            tag_start = i;
            in_tag = 1;
            tag_quote = 0;
            if (!write_slice(&out_idx, &c, 1)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            i++;
            continue;
        }

        if (raw_text_mode == 0 && anchor_depth == 0 && literal_depth == 0 && starts_with_https(input_buffer, i, input_size)) {
            uint32_t start = i;
            uint32_t j = i + 8;
            uint32_t url_steps = 0;
            while (j < input_size && !is_url_stop(input_buffer[j]) && url_steps < INPUT_CAP) {
                j++;
                url_steps++;
            }
            uint32_t url_end = trim_url_end(input_buffer, start, j);
            uint32_t url_len = url_end - start;
            if (url_len == 8) {
                if (!write_slice(&out_idx, &c, 1)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
                i++;
                continue;
            }
            if (!write_slice(&out_idx, (const unsigned char *)"<a href=\"", 9)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            if (!write_escaped_attr(&out_idx, input_buffer + start, url_len)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            if (!write_slice(&out_idx, (const unsigned char *)"\">", 2)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            if (!write_slice(&out_idx, input_buffer + start, url_len)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            if (!write_slice(&out_idx, (const unsigned char *)"</a>", 4)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
            i = url_end;
            continue;
        }
        if (!write_slice(&out_idx, &c, 1)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
        i++;
    }

    return ((uint64_t)output_ptr() << 32) | (uint32_t)(out_idx);
}
