#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkGraphics.h"
#include "include/core/SkPath.h"
#include "include/core/SkRSXform.h"
#include "include/core/SkStream.h"
#include "include/core/SkTextBlob.h"
#include "include/ports/SkFontMgr_data.h"
#include "include/utils/SkNoDrawCanvas.h"
#include "include/utils/SkParsePath.h"
#include "modules/svg/include/SkSVGDOM.h"
#include "src/core/SkTextBlobPriv.h"
#include "src/xml/SkDOM.h"

// Fonts come from multipart/related parts after the SVG root; none are embedded.
#define INPUT_CAP (32u * 1024u * 1024u)
#define MAX_PARTS 64u
#define OUTPUT_CAP (16u * 1024u * 1024u)
#define ARENA_CAP (128u * 1024u * 1024u)
#define NO_BLOCK UINT32_MAX

static uint8_t input_buf[INPUT_CAP + 1u] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));

typedef struct ArenaBlock {
  uint32_t size;
  uint32_t next;
  uint32_t prev;
  uint32_t is_free;
} ArenaBlock;

static size_t arena_used;
static size_t arena_peak;
static size_t arena_alloc_count;
static size_t arena_largest;
static size_t arena_failed_size;
static size_t arena_free_count_value;
static size_t arena_free_unmatched_count_value;
static bool constructors_called;

extern "C" void __wasm_call_ctors(void);

static uint32_t align16(size_t size) {
  if (size == 0) size = 1;
  if (size > UINT32_MAX - 15u) return 0;
  return ((uint32_t)size + 15u) & ~15u;
}

static void split_block(uint32_t offset, ArenaBlock* block, uint32_t wanted) {
  if (block->size >= wanted + sizeof(ArenaBlock) + 16u) {
    uint32_t new_offset = offset + (uint32_t)sizeof(ArenaBlock) + wanted;
    ArenaBlock* split = (ArenaBlock*)(void*)(arena + new_offset);
    split->size = block->size - wanted - (uint32_t)sizeof(ArenaBlock);
    split->next = block->next;
    split->prev = offset;
    split->is_free = 1;
    if (block->next != NO_BLOCK) {
      ((ArenaBlock*)(void*)(arena + block->next))->prev = new_offset;
    }
    block->next = new_offset;
    block->size = wanted;
  }
}

extern "C" void* malloc(size_t size) {
  uint32_t wanted = align16(size);
  uint32_t offset = 0;
  ArenaBlock* block;
  if (wanted == 0) {
    arena_failed_size = size;
    return nullptr;
  }
  while (offset != NO_BLOCK) {
    block = (ArenaBlock*)(void*)(arena + offset);
    if (block->is_free && block->size >= wanted) break;
    offset = block->next;
  }
  if (offset == NO_BLOCK) {
    arena_failed_size = size;
    return nullptr;
  }
  split_block(offset, block, wanted);
  block->is_free = 0;
  arena_used += block->size;
  if (arena_used > arena_peak) arena_peak = arena_used;
  if (size > arena_largest) arena_largest = size;
  ++arena_alloc_count;
  return (uint8_t*)block + sizeof(ArenaBlock);
}

extern "C" void* calloc(size_t count, size_t size) {
  if (count != 0 && size > SIZE_MAX / count) return nullptr;
  size_t total = count * size;
  void* result = malloc(total);
  if (result != nullptr) memset(result, 0, total);
  return result;
}

// Emscripten's freestanding environment setup bypasses interposed malloc.
extern "C" void* emscripten_builtin_malloc(size_t size) { return malloc(size); }

extern "C" __attribute__((noreturn)) void abort(void) { __builtin_trap(); }

// The C runtime may query locale variables; this module has an empty environment.
extern "C" char* getenv(const char*) { return nullptr; }

extern "C" int __cxa_atexit(void (*)(void*), void*, void*) { return 0; }

extern "C" void* emscripten_memcpy_big(void* destination,
                                        const void* source, size_t size) {
  uint8_t* out = (uint8_t*)destination;
  const uint8_t* in = (const uint8_t*)source;
  for (size_t i = 0; i < size; ++i) out[i] = in[i];
  return destination;
}

static ArenaBlock* block_for_pointer(void* ptr) {
  if (ptr == nullptr) return nullptr;
  uintptr_t address = (uintptr_t)ptr;
  uintptr_t arena_address = (uintptr_t)arena;
  if (address < arena_address + sizeof(ArenaBlock) ||
      address - arena_address >= ARENA_CAP) {
    return nullptr;
  }
  ArenaBlock* block =
      (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
  if (block->is_free) return nullptr;
  return block;
}

extern "C" size_t malloc_usable_size(void* ptr) {
  ArenaBlock* block = block_for_pointer(ptr);
  return block ? block->size : 0;
}

extern "C" void free(void* ptr) {
  if (ptr == nullptr) return;
  ++arena_free_count_value;
  ArenaBlock* block = block_for_pointer(ptr);
  if (block == nullptr) {
    ++arena_free_unmatched_count_value;
    return;
  }
  block->is_free = 1;
  arena_used -= block->size;
  if (block->next != NO_BLOCK) {
    ArenaBlock* next = (ArenaBlock*)(void*)(arena + block->next);
    if (next->is_free) {
      block->size += (uint32_t)sizeof(ArenaBlock) + next->size;
      block->next = next->next;
      if (next->next != NO_BLOCK) {
        ((ArenaBlock*)(void*)(arena + next->next))->prev =
            (uint32_t)((uint8_t*)block - arena);
      }
    }
  }
  if (block->prev != NO_BLOCK) {
    ArenaBlock* prev = (ArenaBlock*)(void*)(arena + block->prev);
    if (prev->is_free) {
      prev->size += (uint32_t)sizeof(ArenaBlock) + block->size;
      prev->next = block->next;
      if (block->next != NO_BLOCK) {
        ((ArenaBlock*)(void*)(arena + block->next))->prev = block->prev;
      }
    }
  }
}

extern "C" void* realloc(void* ptr, size_t size) {
  if (ptr == nullptr) return malloc(size);
  if (size == 0) {
    free(ptr);
    return nullptr;
  }
  ArenaBlock* block = block_for_pointer(ptr);
  if (block == nullptr) {
    arena_failed_size = size;
    return nullptr;
  }
  uint32_t wanted = align16(size);
  if (wanted == 0) {
    arena_failed_size = size;
    return nullptr;
  }
  uint32_t offset = (uint32_t)((uint8_t*)block - arena);
  uint32_t old_size = block->size;
  if (wanted <= old_size) {
    split_block(offset, block, wanted);
    arena_used -= old_size - block->size;
    return ptr;
  }
  if (block->next != NO_BLOCK) {
    ArenaBlock* next = (ArenaBlock*)(void*)(arena + block->next);
    uint64_t combined =
        (uint64_t)block->size + sizeof(ArenaBlock) + next->size;
    if (next->is_free && combined >= wanted) {
      block->size = (uint32_t)combined;
      block->next = next->next;
      if (next->next != NO_BLOCK) {
        ((ArenaBlock*)(void*)(arena + next->next))->prev = offset;
      }
      split_block(offset, block, wanted);
      arena_used += block->size - old_size;
      if (arena_used > arena_peak) arena_peak = arena_used;
      return ptr;
    }
  }
  void* replacement = malloc(size);
  if (replacement == nullptr) return nullptr;
  memcpy(replacement, ptr, old_size < size ? old_size : size);
  free(ptr);
  return replacement;
}

static void arena_reset(void) {
  ArenaBlock* first = (ArenaBlock*)(void*)arena;
  arena_used = 0;
  arena_peak = 0;
  arena_alloc_count = 0;
  arena_largest = 0;
  arena_failed_size = 0;
  arena_free_count_value = 0;
  arena_free_unmatched_count_value = 0;
  first->size = ARENA_CAP - (uint32_t)sizeof(ArenaBlock);
  first->next = NO_BLOCK;
  first->prev = NO_BLOCK;
  first->is_free = 1;
}

extern "C" uint32_t input_ptr() { return (uint32_t)(uintptr_t)input_buf; }
extern "C" uint32_t input_bytes_cap() { return INPUT_CAP; }
extern "C" uint32_t output_utf8_cap() { return OUTPUT_CAP; }
extern "C" uint32_t failure_modes_per_input_offset() { return 1; }
#define RELATED_TYPE_PREFIX "multipart/related;type=\"image/svg+xml\";boundary="
#define DEFAULT_BOUNDARY "uuid-00000000-0000-0000-0000-000000000000"
#define BOUNDARY_SIZE (sizeof(DEFAULT_BOUNDARY) - 1)
// Not const: the host may replace the boundary UUID before each render.
static char input_content_type[] = RELATED_TYPE_PREFIX DEFAULT_BOUNDARY;
static const char output_content_type[] = "image/svg+xml";
extern "C" uint32_t input_content_type_ptr() { return (uint32_t)(uintptr_t)input_content_type; }
extern "C" uint32_t input_content_type_size() { return sizeof(input_content_type) - 1; }
extern "C" uint32_t output_content_type_ptr() { return (uint32_t)(uintptr_t)output_content_type; }
extern "C" uint32_t output_content_type_size() { return sizeof(output_content_type) - 1; }
extern "C" uint32_t arena_peak_bytes() { return arena_peak; }
extern "C" uint32_t arena_live_bytes() { return arena_used; }
extern "C" uint32_t arena_failed_allocation() { return arena_failed_size; }
extern "C" uint32_t arena_free_unmatched_count() { return arena_free_unmatched_count_value; }

// Text layout attributes that do nothing on the replacement <path>.
static const char* const kTextOnlyAttributes[] = {
    "x", "y", "dx", "dy", "rotate", "textLength", "lengthAdjust", "xml:space",
    "font", "font-family", "font-size", "font-size-adjust", "font-stretch", "font-style",
    "font-variant", "font-weight", "text-anchor", "letter-spacing", "word-spacing",
    "text-decoration", "text-rendering", "dominant-baseline", "alignment-baseline",
    "baseline-shift", "writing-mode", "direction", "unicode-bidi",
};

// Attributes SkSVGText reads for layout on the <text> element itself.
static const char* const kTextLayoutAttributes[] = {
    "x", "y", "dx", "dy", "rotate", "xml:space",
    "font-family", "font-size", "font-style", "font-weight", "text-anchor",
};

// Inherited properties SkSVGText reads from ancestors.
static const char* const kInheritedAttributes[] = {
    "font-family", "font-size", "font-style", "font-weight", "text-anchor",
};

template <size_t N>
static bool listed(const char* const (&names)[N], const char* name) {
  for (const char* candidate : names) {
    if (!strcmp(candidate, name)) return true;
  }
  return false;
}

static bool is_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

static void append_escaped(std::string* out, const char* text, bool attribute) {
  for (; *text; ++text) {
    switch (*text) {
      case '&': *out += "&amp;"; break;
      case '<': *out += "&lt;"; break;
      case '>': *out += "&gt;"; break;
      case '"':
        if (attribute) {
          *out += "&quot;";
          break;
        }
        [[fallthrough]];
      default: *out += *text;
    }
  }
}

static void append_attribute(std::string* out, const char* name, const char* value) {
  *out += ' ';
  *out += name;
  *out += "=\"";
  append_escaped(out, value, true);
  *out += '"';
}

static void append_node(std::string* out, const SkDOM& dom, const SkDOM::Node* node) {
  if (dom.getType(node) == SkDOM::kText_Type) {
    append_escaped(out, dom.getName(node), false);
    return;
  }
  const char* name = dom.getName(node);
  *out += '<';
  *out += name;
  SkDOM::AttrIter iter(dom, node);
  const char* value;
  while (const char* attribute = iter.next(&value)) append_attribute(out, attribute, value);
  const SkDOM::Node* child = dom.getFirstChild(node);
  if (!child) {
    *out += "/>";
    return;
  }
  *out += '>';
  for (; child; child = dom.getNextSibling(child)) append_node(out, dom, child);
  *out += "</";
  *out += name;
  *out += '>';
}

// Keeps only the font and text-anchor declarations of a style attribute.
static void append_text_style(std::string* out, const char* style) {
  std::string kept;
  while (*style) {
    const char* end = strchr(style, ';');
    if (!end) end = style + strlen(style);
    while (style < end && is_space(*style)) ++style;
    if (!strncmp(style, "font", 4) || !strncmp(style, "text-anchor", 11)) {
      kept.append(style, end - style);
      kept += ';';
    }
    style = *end ? end + 1 : end;
  }
  if (!kept.empty()) append_attribute(out, "style", kept.c_str());
}

template <size_t N>
static void append_layout_attributes(std::string* out, const SkDOM& dom, const SkDOM::Node* node,
                                     const char* const (&names)[N]) {
  SkDOM::AttrIter iter(dom, node);
  const char* value;
  while (const char* name = iter.next(&value)) {
    if (!strcmp(name, "style")) {
      append_text_style(out, value);
    } else if (listed(names, name)) {
      append_attribute(out, name, value);
    }
  }
}

// Writes the viewport that percentages in x, y and font-size resolve against.
static void append_viewport(std::string* out, const SkDOM& dom, const SkDOM::Node* svg) {
  if (const char* view_box = dom.findAttr(svg, "viewBox")) {
    float box[4];
    int count = 0;
    char* end = (char*)view_box;
    while (count < 4) {
      while (is_space(*end) || *end == ',') ++end;
      const char* start = end;
      box[count] = strtof(start, &end);
      if (end == start) break;
      ++count;
    }
    if (count == 4 && box[2] > 0 && box[3] > 0) {
      char number[32];
      snprintf(number, sizeof(number), "%.9g", box[2]);
      append_attribute(out, "width", number);
      snprintf(number, sizeof(number), "%.9g", box[3]);
      append_attribute(out, "height", number);
      return;
    }
  }
  if (const char* width = dom.findAttr(svg, "width")) append_attribute(out, "width", width);
  if (const char* height = dom.findAttr(svg, "height")) append_attribute(out, "height", height);
}

static const SkDOM::Node* find_id(const SkDOM& dom, const SkDOM::Node* node, const char* id) {
  if (dom.getType(node) != SkDOM::kElement_Type) return nullptr;
  const char* value = dom.findAttr(node, "id");
  if (value && !strcmp(value, id)) return node;
  for (auto* child = dom.getFirstChild(node); child; child = dom.getNextSibling(child)) {
    if (auto* found = find_id(dom, child, id)) return found;
  }
  return nullptr;
}

// Copies the paths that <textPath> children follow.
static void append_text_path_targets(std::string* out, const SkDOM& dom, const SkDOM::Node* root,
                                     const SkDOM::Node* node) {
  if (dom.getType(node) != SkDOM::kElement_Type) return;
  if (!strcmp(dom.getName(node), "textPath")) {
    const char* href = dom.findAttr(node, "href");
    if (!href) href = dom.findAttr(node, "xlink:href");
    if (href && href[0] == '#') {
      if (auto* target = find_id(dom, root, href + 1)) append_node(out, dom, target);
    }
  }
  for (auto* child = dom.getFirstChild(node); child; child = dom.getNextSibling(child)) {
    append_text_path_targets(out, dom, root, child);
  }
}

struct TextElement {
  const SkDOM::Node* node;
  std::vector<const SkDOM::Node*> ancestors;
};

static void find_texts(const SkDOM& dom, const SkDOM::Node* node,
                       std::vector<const SkDOM::Node*>* ancestors,
                       std::vector<TextElement>* texts) {
  if (dom.getType(node) != SkDOM::kElement_Type) return;
  if (!strcmp(dom.getName(node), "text")) {
    texts->push_back({node, *ancestors});
    return;
  }
  ancestors->push_back(node);
  for (auto* child = dom.getFirstChild(node); child; child = dom.getNextSibling(child)) {
    find_texts(dom, child, ancestors, texts);
  }
  ancestors->pop_back();
}

// A document holding one <text> and the layout properties it inherits. It has
// no transforms, so Skia lays the glyphs out in the <text> user space.
static std::string layout_document(const SkDOM& dom, const SkDOM::Node* root,
                                   const TextElement& text) {
  std::string out = "<svg";
  for (auto it = text.ancestors.rbegin(); it != text.ancestors.rend(); ++it) {
    if (!strcmp(dom.getName(*it), "svg")) {
      append_viewport(&out, dom, *it);
      break;
    }
  }
  // A fill guarantees that Skia draws every glyph run once.
  out += " fill=\"black\"><defs>";
  append_text_path_targets(&out, dom, root, text.node);
  out += "</defs>";
  for (auto* ancestor : text.ancestors) {
    out += "<g";
    append_layout_attributes(&out, dom, ancestor, kInheritedAttributes);
    out += '>';
  }
  out += "<text";
  append_layout_attributes(&out, dom, text.node, kTextLayoutAttributes);
  out += '>';
  for (auto* child = dom.getFirstChild(text.node); child; child = dom.getNextSibling(child)) {
    append_node(&out, dom, child);
  }
  out += "</text>";
  for (size_t i = 0; i < text.ancestors.size(); ++i) out += "</g>";
  out += "</svg>";
  return out;
}

// Collects the outlines of the glyph runs that SkSVGText draws.
class GlyphPathCanvas final : public SkNoDrawCanvas {
 public:
  GlyphPathCanvas() : SkNoDrawCanvas(1, 1) {}
  SkPath path;

 protected:
  void onDrawTextBlob(const SkTextBlob* blob, SkScalar x, SkScalar y, const SkPaint&) override {
    // SkSVGText draws each run once to fill and again to stroke.
    if (has_blob && blob->uniqueID() == last_blob) return;
    has_blob = true;
    last_blob = blob->uniqueID();
    SkMatrix base = this->getTotalMatrix();
    base.preTranslate(x, y);
    for (SkTextBlobRunIterator it(blob); !it.done(); it.next()) {
      if (it.positioning() != SkTextBlobRunIterator::kRSXform_Positioning) continue;
      struct Context {
        SkPath* path;
        const SkMatrix* base;
        const SkRSXform* xform;
      } context = {&path, &base, it.xforms()};
      it.font().getPaths(it.glyphs(), it.glyphCount(),
                         [](const SkPath* glyph, const SkMatrix& matrix, void* raw) {
                           auto* context = (Context*)raw;
                           SkMatrix glyph_matrix;
                           glyph_matrix.setRSXform(*context->xform++);
                           if (!glyph || !glyph_matrix.isFinite()) return;
                           glyph_matrix.postConcat(*context->base);
                           glyph_matrix.preConcat(matrix);
                           context->path->addPath(*glyph, glyph_matrix);
                         },
                         &context);
    }
  }

 private:
  bool has_blob = false;
  uint32_t last_blob = 0;
};

static bool text_outline(const std::string& document, const sk_sp<SkFontMgr>& fonts,
                         SkPath* path) {
  SkMemoryStream stream(document.data(), document.size(), false);
  auto svg = SkSVGDOM::Builder().setFontManager(fonts).make(stream);
  if (!svg) return false;
  GlyphPathCanvas canvas;
  svg->render(&canvas);
  *path = canvas.path;
  return true;
}

static std::string path_element(const SkDOM& dom, const SkDOM::Node* text, const SkPath& path) {
  std::string out = "<path";
  SkDOM::AttrIter iter(dom, text);
  const char* value;
  while (const char* name = iter.next(&value)) {
    if (!listed(kTextOnlyAttributes, name) && strcmp(name, "d")) {
      append_attribute(&out, name, value);
    }
  }
  append_attribute(&out, "d", SkParsePath::ToSVGString(path).c_str());
  // Keep accessible names and descriptions; the characters become the outline.
  std::string described;
  for (auto* child = dom.getFirstChild(text); child; child = dom.getNextSibling(child)) {
    if (dom.getType(child) != SkDOM::kElement_Type) continue;
    if (!strcmp(dom.getName(child), "title") || !strcmp(dom.getName(child), "desc")) {
      append_node(&described, dom, child);
    }
  }
  if (described.empty()) {
    out += "/>";
  } else {
    out += '>';
    out += described;
    out += "</path>";
  }
  return out;
}

struct SourceSpan {
  size_t start;
  size_t end;
};

static bool starts_with(const char* data, size_t size, size_t at, const char* prefix) {
  size_t length = strlen(prefix);
  return at + length <= size && !memcmp(data + at, prefix, length);
}

// Skips a comment, CDATA section, processing instruction, or declaration
// starting at '<'. Returns the offset after it, or 0 when `at` starts a tag.
static size_t skip_markup(const char* data, size_t size, size_t at) {
  const char* close = nullptr;
  if (starts_with(data, size, at, "<!--")) close = "-->";
  else if (starts_with(data, size, at, "<![CDATA[")) close = "]]>";
  else if (starts_with(data, size, at, "<?")) close = "?>";
  if (close) {
    size_t length = strlen(close);
    for (size_t i = at + 2; i + length <= size; ++i) {
      if (!memcmp(data + i, close, length)) return i + length;
    }
    return size;
  }
  if (starts_with(data, size, at, "<!")) {
    int depth = 0;
    for (size_t i = at + 2; i < size; ++i) {
      if (data[i] == '[') ++depth;
      else if (data[i] == ']') --depth;
      else if (data[i] == '>' && depth <= 0) return i + 1;
    }
    return size;
  }
  return 0;
}

// Returns the offset after the '>' that ends the tag starting at `at`.
static size_t tag_end(const char* data, size_t size, size_t at) {
  char quote = 0;
  for (size_t i = at + 1; i < size; ++i) {
    if (quote) {
      if (data[i] == quote) quote = 0;
    } else if (data[i] == '"' || data[i] == '\'') {
      quote = data[i];
    } else if (data[i] == '>') {
      return i + 1;
    }
  }
  return 0;
}

static bool is_tag(const char* data, size_t size, size_t at, const char* name) {
  size_t end = at + strlen(name);
  return starts_with(data, size, at, name) && end < size &&
         (is_space(data[end]) || data[end] == '>' || data[end] == '/');
}

// Finds each <text> element in source order, matching SkDOM's document order.
static bool find_text_spans(const char* data, size_t size, std::vector<SourceSpan>* spans) {
  size_t at = 0;
  while (at < size) {
    const char* next = (const char*)memchr(data + at, '<', size - at);
    if (!next) return true;
    at = next - data;
    if (size_t skipped = skip_markup(data, size, at)) {
      at = skipped;
      continue;
    }
    size_t end = tag_end(data, size, at);
    if (!end) return false;
    if (!is_tag(data, size, at, "<text")) {
      at = end;
      continue;
    }
    size_t start = at;
    if (data[end - 2] != '/') {
      // Find the matching </text>, skipping nested markup.
      int depth = 1;
      while (depth) {
        next = (const char*)memchr(data + end, '<', size - end);
        if (!next) return false;
        at = next - data;
        if (size_t skipped = skip_markup(data, size, at)) {
          end = skipped;
          continue;
        }
        end = tag_end(data, size, at);
        if (!end) return false;
        if (is_tag(data, size, at, "</text")) --depth;
        else if (is_tag(data, size, at, "<text") && data[end - 2] != '/') ++depth;
      }
    }
    spans->push_back({start, end});
    at = end;
  }
  return true;
}

static uint32_t convert(const uint8_t* svg, size_t svg_size, sk_sp<SkData>* font_data,
                        size_t font_count) {
  const char* source = (const char*)svg;
  SkMemoryStream stream(svg, svg_size, false);
  SkDOM dom;
  const SkDOM::Node* root = dom.build(stream);
  if (!root || strcmp(dom.getName(root), "svg")) return 0;
  std::vector<TextElement> texts;
  std::vector<const SkDOM::Node*> ancestors;
  find_texts(dom, root, &ancestors, &texts);
  std::vector<SourceSpan> spans;
  if (!find_text_spans(source, svg_size, &spans) || spans.size() != texts.size()) return 0;
  auto fonts = SkFontMgr_New_Custom_Data(SkSpan<sk_sp<SkData>>(font_data, font_count));
  // The font manager skips data FreeType cannot open; reject it instead.
  for (size_t i = 0; i < font_count; ++i) {
    if (!fonts->makeFromData(font_data[i])) return 0;
  }
  std::string out;
  size_t copied = 0;
  for (size_t i = 0; i < texts.size(); ++i) {
    SkPath path;
    if (!text_outline(layout_document(dom, root, texts[i]), fonts, &path)) return 0;
    out.append(source + copied, spans[i].start - copied);
    out += path_element(dom, texts[i].node, path);
    copied = spans[i].end;
    if (out.size() > OUTPUT_CAP) return 0;
  }
  out.append(source + copied, svg_size - copied);
  if (out.size() > OUTPUT_CAP) return 0;
  memcpy(output_buf, out.data(), out.size());
  return (uint32_t)out.size();
}

static const uint8_t* find_bytes(const uint8_t* start, const uint8_t* end,
                                 const char* needle, size_t needle_size) {
  for (const uint8_t* at = start; (size_t)(end - at) >= needle_size; ++at) {
    if (memcmp(at, needle, needle_size) == 0) return at;
  }
  return nullptr;
}

static bool equals_ignore_case(const uint8_t* bytes, size_t size, const char* lower) {
  size_t lower_size = strlen(lower);
  if (size != lower_size) return false;
  for (size_t i = 0; i < size; ++i) {
    uint8_t byte = bytes[i];
    if (byte >= 'A' && byte <= 'Z') byte += 'a' - 'A';
    if (byte != (uint8_t)lower[i]) return false;
  }
  return true;
}

static void trim_ows(const uint8_t** start, const uint8_t** end) {
  while (*start < *end && (**start == ' ' || **start == '\t')) ++*start;
  while (*end > *start && ((*end)[-1] == ' ' || (*end)[-1] == '\t')) --*end;
}

enum PartKind { PART_INVALID, PART_SVG, PART_FONT };

// Returns the part's kind from its single Content-Type header. Other headers,
// such as Content-ID, carry no meaning here.
static PartKind part_kind(const uint8_t* start, const uint8_t* end) {
  PartKind kind = PART_INVALID;
  bool seen_type = false;
  while (start < end) {
    const uint8_t* line_end = find_bytes(start, end, "\r\n", 2);
    if (!line_end) line_end = end;
    if (line_end == start || *start == ' ' || *start == '\t') return PART_INVALID;
    const uint8_t* colon = (const uint8_t*)memchr(start, ':', line_end - start);
    if (!colon) return PART_INVALID;
    if (equals_ignore_case(start, colon - start, "content-type")) {
      if (seen_type) return PART_INVALID;
      seen_type = true;
      const uint8_t* value = colon + 1;
      const uint8_t* value_end = (const uint8_t*)memchr(value, ';', line_end - value);
      if (!value_end) value_end = line_end;
      trim_ows(&value, &value_end);
      size_t size = value_end - value;
      // FreeType detects the font format from its bytes, not from this type.
      if (equals_ignore_case(value, size, "image/svg+xml")) kind = PART_SVG;
      else if (equals_ignore_case(value, size, "font/ttf") ||
               equals_ignore_case(value, size, "font/otf") ||
               equals_ignore_case(value, size, "font/woff") ||
               equals_ignore_case(value, size, "font/woff2")) kind = PART_FONT;
    } else if (equals_ignore_case(start, colon - start, "content-transfer-encoding")) {
      return PART_INVALID;
    }
    start = line_end == end ? end : line_end + 2;
  }
  return kind;
}

static bool read_boundary(char* out) {
  const size_t prefix_size = sizeof(RELATED_TYPE_PREFIX) - 1;
  char type[sizeof(input_content_type)];
  // Volatile loads observe host edits made after instantiation.
  for (size_t i = 0; i < sizeof(type); ++i) type[i] = ((volatile char*)input_content_type)[i];
  if (memcmp(type, RELATED_TYPE_PREFIX "uuid-", prefix_size + 5) != 0) return false;
  for (size_t i = 0; i < 36; ++i) {
    char c = type[prefix_size + 5 + i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return false;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
      return false;
    }
  }
  memcpy(out, type + prefix_size, BOUNDARY_SIZE);
  return true;
}

// Parses the SVG root and font parts, then outlines text with only those fonts.
static uint32_t convert_related(uint32_t input_size) {
  char opening[2 + BOUNDARY_SIZE + 2], marker[4 + BOUNDARY_SIZE];
  if (!read_boundary(opening + 2)) return 0;
  opening[0] = opening[1] = '-';
  opening[sizeof(opening) - 2] = '\r';
  opening[sizeof(opening) - 1] = '\n';
  memcpy(marker, "\r\n--", 4);
  memcpy(marker + 4, opening + 2, BOUNDARY_SIZE);

  const uint8_t* input = input_buf;
  const uint8_t* end = input + input_size;
  if (input_size < sizeof(opening) || memcmp(input, opening, sizeof(opening)) != 0) return 0;
  const uint8_t* cursor = input + sizeof(opening);
  const uint8_t* svg = nullptr;
  size_t svg_size = 0, font_count = 0;
  sk_sp<SkData> fonts[MAX_PARTS - 1];
  for (uint32_t part = 0;; ++part) {
    if (part == MAX_PARTS) return 0;
    const uint8_t* header_end = find_bytes(cursor, end, "\r\n\r\n", 4);
    if (!header_end) return 0;
    PartKind kind = part_kind(cursor, header_end);
    // The root must be the SVG; every later part must be a font.
    if (kind != (part == 0 ? PART_SVG : PART_FONT)) return 0;
    const uint8_t* body = header_end + 4;
    const uint8_t* body_end = body;
    for (;;) {
      body_end = find_bytes(body_end, end, marker, sizeof(marker));
      if (!body_end) return 0;
      const uint8_t* suffix = body_end + sizeof(marker);
      if (end - suffix >= 2 && (memcmp(suffix, "\r\n", 2) == 0 || memcmp(suffix, "--", 2) == 0)) break;
      ++body_end;
    }
    if (part == 0) {
      svg = body;
      svg_size = body_end - body;
    } else {
      // The input buffer outlives the font manager, which ends with this call.
      fonts[font_count++] = SkData::MakeWithoutCopy(body, body_end - body);
    }
    cursor = body_end + sizeof(marker);
    if (memcmp(cursor, "--", 2) == 0) {
      cursor += 2;
      if (end - cursor >= 2 && memcmp(cursor, "\r\n", 2) == 0) cursor += 2;
      if (cursor != end) return 0;
      break;
    }
    cursor += 2;
  }
  return convert(svg, svg_size, fonts, font_count);
}

extern "C" uint64_t render(uint32_t input_size) {
  if (input_size > INPUT_CAP) __builtin_trap();
  if (!constructors_called) {
    arena_reset();
    __wasm_call_ctors();
    constructors_called = true;
  }
  // Skia retains module-lifetime singletons. Reclaim render storage without
  // resetting the arena under those singletons.
  arena_peak = arena_used;
  arena_failed_size = 0;
  arena_free_unmatched_count_value = 0;
  uint32_t output_size = convert_related(input_size);
  SkGraphics::PurgeAllCaches();
  if (!output_size || arena_failed_size || arena_free_unmatched_count_value) {
    return UINT64_C(0x8000000000000000);
  }
  return ((uint64_t)(uintptr_t)output_buf << 32) | output_size;
}
