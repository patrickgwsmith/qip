#include <stddef.h>
#include <stdint.h>

#define INPUT_CAP (1024 * 1024)
// A link adds a second URL and 15 wrapper bytes. Each URL has at least nine
// bytes, and adjacent URLs need at least one stop byte between them.
#define MAX_LINKS ((INPUT_CAP + 1) / 10)
#define OUTPUT_CAP (2 * INPUT_CAP + 14 * MAX_LINKS + 1)

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

static uint32_t output_ptr() {
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

static int is_ascii_alnum(unsigned char c) {
    return (c >= '0' && c <= '9') ||
           (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z');
}

static int is_url_stop(unsigned char c) {
    return is_ws(c) || c == '<' || c == '>' || c == '"' || c == '\'' || c == '`';
}

static unsigned char ascii_lower(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return (unsigned char)(c + ('a' - 'A'));
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

static int can_start_url(const unsigned char *s, uint32_t i) {
    if (i == 0) return 1;
    unsigned char previous = s[i - 1];
    return !is_ascii_alnum(previous) && previous != '_';
}

typedef enum {
    ELEMENT_OTHER,
    ELEMENT_A,
    ELEMENT_PRE,
    ELEMENT_CODE,
    ELEMENT_STYLE,
    ELEMENT_TITLE,
    ELEMENT_SCRIPT,
    ELEMENT_TEXTAREA,
} element_kind;

#define PACK1(a) ((uint64_t)(a))
#define PACK3(a, b, c) (PACK1(a) | ((uint64_t)(b) << 8) | ((uint64_t)(c) << 16))
#define PACK4(a, b, c, d) (PACK3(a, b, c) | ((uint64_t)(d) << 24))
#define PACK5(a, b, c, d, e) (PACK4(a, b, c, d) | ((uint64_t)(e) << 32))
#define PACK6(a, b, c, d, e, f) (PACK5(a, b, c, d, e) | ((uint64_t)(f) << 40))
#define PACK8(a, b, c, d, e, f, g, h) (PACK6(a, b, c, d, e, f) | ((uint64_t)(g) << 48) | ((uint64_t)(h) << 56))

static element_kind classify_element(const unsigned char *name, uint32_t len) {
    if (len > 8) return ELEMENT_OTHER;
    uint64_t packed = 0;
    for (uint32_t i = 0; i < len; i++) {
        packed |= (uint64_t)ascii_lower(name[i]) << (i * 8);
    }
    switch (packed) {
        case PACK1('a'): return ELEMENT_A;
        case PACK3('p', 'r', 'e'): return ELEMENT_PRE;
        case PACK4('c', 'o', 'd', 'e'): return ELEMENT_CODE;
        case PACK5('s', 't', 'y', 'l', 'e'): return ELEMENT_STYLE;
        case PACK5('t', 'i', 't', 'l', 'e'): return ELEMENT_TITLE;
        case PACK6('s', 'c', 'r', 'i', 'p', 't'): return ELEMENT_SCRIPT;
        case PACK8('t', 'e', 'x', 't', 'a', 'r', 'e', 'a'): return ELEMENT_TEXTAREA;
    }
    return ELEMENT_OTHER;
}

static int is_raw_element(element_kind kind) {
    return kind == ELEMENT_SCRIPT || kind == ELEMENT_STYLE ||
           kind == ELEMENT_TITLE || kind == ELEMENT_TEXTAREA;
}

static uint32_t find_tag_end(const unsigned char *s, uint32_t start, uint32_t n) {
    unsigned char quote = 0;
    for (uint32_t p = start + 1; p < n; p++) {
        unsigned char c = s[p];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' || c == '\'') {
            quote = c;
        } else if (c == '>') {
            return p + 1;
        }
    }
    return n;
}

static uint32_t find_comment_end(const unsigned char *s, uint32_t start, uint32_t n) {
    for (uint32_t p = start + 4; p + 2 < n; p++) {
        if (s[p] == '-' && s[p + 1] == '-' && s[p + 2] == '>') return p + 3;
    }
    return n;
}

static void update_html_context(
    const unsigned char *s,
    uint32_t tag_start,
    uint32_t tag_end,
    element_kind *raw_element,
    uint32_t *anchor_depth,
    uint32_t *literal_depth
) {
    uint32_t p = tag_start + 1;
    while (p < tag_end && is_ws(s[p])) p++;
    if (p >= tag_end || s[p] == '!' || s[p] == '?') return;

    int closing = 0;
    if (s[p] == '/') {
        closing = 1;
        p++;
        while (p < tag_end && is_ws(s[p])) p++;
    }

    uint32_t name_start = p;
    while (p < tag_end && is_ascii_alnum(s[p])) p++;
    if (p == name_start) return;

    uint32_t tail = tag_end;
    while (tail > p && is_ws(s[tail - 1])) tail--;
    int self_closing = tail > p && s[tail - 1] == '/';
    element_kind kind = classify_element(s + name_start, p - name_start);

    if (is_raw_element(kind)) {
        if (!closing && !self_closing) *raw_element = kind;
        return;
    }
    if (kind == ELEMENT_A) {
        if (closing) {
            if (*anchor_depth > 0) (*anchor_depth)--;
        } else if (!self_closing) {
            (*anchor_depth)++;
        }
        return;
    }
    if (kind == ELEMENT_PRE || kind == ELEMENT_CODE) {
        if (closing) {
            if (*literal_depth > 0) (*literal_depth)--;
        } else if (!self_closing) {
            (*literal_depth)++;
        }
    }
}

static int raw_close_at(const unsigned char *s, uint32_t p, uint32_t n, element_kind raw_element) {
    if (p + 3 >= n || s[p] != '<' || s[p + 1] != '/') return 0;
    uint32_t name_start = p + 2;
    uint32_t name_len = 0;
    while (name_start + name_len < n && is_ascii_alnum(s[name_start + name_len])) name_len++;
    if (classify_element(s + name_start, name_len) != raw_element) return 0;
    if (name_start + name_len >= n) return 0;
    unsigned char after = s[name_start + name_len];
    return is_ws(after) || after == '>' || after == '/';
}

static uint32_t find_raw_close_end(const unsigned char *s, uint32_t start, uint32_t n, element_kind raw_element) {
    for (uint32_t p = start; p < n; p++) {
        if (!raw_close_at(s, p, n, raw_element)) continue;
        uint32_t end = find_tag_end(s, p, n);
        if (end > p && s[end - 1] == '>') return end;
        return 0;
    }
    return 0;
}

static uint32_t trim_url_end(const unsigned char *s, uint32_t start, uint32_t end) {
    uint32_t round_open = 0, round_close = 0;
    uint32_t square_open = 0, square_close = 0;
    uint32_t curly_open = 0, curly_close = 0;
    for (uint32_t p = start + 8; p < end; p++) {
        switch (s[p]) {
            case '(': round_open++; break;
            case ')': round_close++; break;
            case '[': square_open++; break;
            case ']': square_close++; break;
            case '{': curly_open++; break;
            case '}': curly_close++; break;
        }
    }

    while (end > start + 8) {
        unsigned char c = s[end - 1];
        if (c == '.' || c == ',' || c == ';' || c == ':' || c == '!' || c == '?') {
            end--;
        } else if (c == ')' && round_close > round_open) {
            round_close--;
            end--;
        } else if (c == ']' && square_close > square_open) {
            square_close--;
            end--;
        } else if (c == '}' && curly_close > curly_open) {
            curly_close--;
            end--;
        } else {
            break;
        }
    }
    return end;
}

__attribute__((noinline))
static uint32_t write_slice(uint32_t out_idx, const unsigned char *s, uint32_t len) {
    if (len > OUTPUT_CAP - out_idx) return UINT32_MAX;
    __builtin_memcpy(output_buffer + out_idx, s, len);
    return out_idx + len;
}

static uint64_t result(uint32_t output_size) {
    return ((uint64_t)output_ptr() << 32) | output_size;
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) input_size = INPUT_CAP;

    static const unsigned char link_open[] = "<a href=\"";
    static const unsigned char link_middle[] = "\">";
    static const unsigned char link_close[] = "</a>";
    uint32_t out_idx = 0;
    uint32_t i = 0;
    element_kind raw_element = ELEMENT_OTHER;
    uint32_t anchor_depth = 0;
    uint32_t literal_depth = 0;

#define WRITE_SLICE(bytes, len) do { \
    uint32_t next_out_idx = write_slice(out_idx, (bytes), (len)); \
    if (next_out_idx == UINT32_MAX) __builtin_trap(); \
    out_idx = next_out_idx; \
} while (0)

    while (i < input_size) {
        if (raw_element != ELEMENT_OTHER) {
            uint32_t end = find_raw_close_end(input_buffer, i, input_size, raw_element);
            if (end == 0) end = input_size;
            WRITE_SLICE(input_buffer + i, end - i);
            i = end;
            if (end < input_size || (end > 0 && input_buffer[end - 1] == '>')) raw_element = ELEMENT_OTHER;
            continue;
        }

        if (i + 3 < input_size && input_buffer[i] == '<' && input_buffer[i + 1] == '!' && input_buffer[i + 2] == '-' && input_buffer[i + 3] == '-') {
            uint32_t end = find_comment_end(input_buffer, i, input_size);
            WRITE_SLICE(input_buffer + i, end - i);
            i = end;
            continue;
        }

        if (input_buffer[i] == '<') {
            uint32_t end = find_tag_end(input_buffer, i, input_size);
            WRITE_SLICE(input_buffer + i, end - i);
            if (end > i && input_buffer[end - 1] == '>') {
                update_html_context(input_buffer, i, end - 1, &raw_element, &anchor_depth, &literal_depth);
            }
            i = end;
            continue;
        }

        if (anchor_depth != 0 || literal_depth != 0) {
            uint32_t end = i + 1;
            while (end < input_size && input_buffer[end] != '<') end++;
            WRITE_SLICE(input_buffer + i, end - i);
            i = end;
            continue;
        }

        uint32_t candidate = i;
        while (candidate < input_size) {
            unsigned char c = input_buffer[candidate];
            if (c == '<') break;
            if ((c == 'h' || c == 'H') && can_start_url(input_buffer, candidate) && starts_with_https(input_buffer, candidate, input_size)) break;
            candidate++;
        }
        if (candidate > i) {
            WRITE_SLICE(input_buffer + i, candidate - i);
            i = candidate;
            continue;
        }
        if (candidate == input_size || input_buffer[candidate] == '<') continue;

        uint32_t end = candidate + 8;
        while (end < input_size && !is_url_stop(input_buffer[end])) end++;
        uint32_t url_end = trim_url_end(input_buffer, candidate, end);
        uint32_t url_len = url_end - candidate;
        if (url_len == 8) {
            WRITE_SLICE(input_buffer + candidate, 1);
            i = candidate + 1;
            continue;
        }

        WRITE_SLICE(link_open, sizeof(link_open) - 1);
        WRITE_SLICE(input_buffer + candidate, url_len);
        WRITE_SLICE(link_middle, sizeof(link_middle) - 1);
        WRITE_SLICE(input_buffer + candidate, url_len);
        WRITE_SLICE(link_close, sizeof(link_close) - 1);
        i = url_end;
    }

#undef WRITE_SLICE
    return result(out_idx);
}
