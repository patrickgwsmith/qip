#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "ktx2-rgba8-srgb.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkGraphics.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/ports/SkFontMgr_data.h"
#include "modules/svg/include/SkSVGDOM.h"
#include "modules/svg/include/SkSVGSVG.h"

// Fonts come from multipart/related parts after the SVG root; none are embedded.
#define INPUT_CAP (32u * 1024u * 1024u)
#define MAX_PARTS 64u
#define OUTPUT_CAP QIP_KTX2_RGBA8_MAX_FILE_SIZE
#define ARENA_CAP (384u * 1024u * 1024u)
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
static uint32_t requested_width;
static uint32_t requested_height;
static uint32_t background_color_rgba;
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


static void reset_uniforms() {
  requested_width = 0;
  requested_height = 0;
  background_color_rgba = 0;
}

extern "C" uint32_t input_ptr() { return (uint32_t)(uintptr_t)input_buf; }
extern "C" uint32_t input_bytes_cap() { return INPUT_CAP; }
extern "C" uint32_t output_bytes_cap() { return OUTPUT_CAP; }
extern "C" uint32_t failure_modes_per_input_offset() { return 1; }
#define RELATED_TYPE_PREFIX "multipart/related;type=\"image/svg+xml\";boundary="
#define DEFAULT_BOUNDARY "uuid-00000000-0000-0000-0000-000000000000"
#define BOUNDARY_SIZE (sizeof(DEFAULT_BOUNDARY) - 1)
// Not const: the host may replace the boundary UUID before each render.
static char input_content_type[] = RELATED_TYPE_PREFIX DEFAULT_BOUNDARY;
static const char output_content_type[] =
    "image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB";
extern "C" uint32_t input_content_type_ptr() { return (uint32_t)(uintptr_t)input_content_type; }
extern "C" uint32_t input_content_type_size() { return sizeof(input_content_type) - 1; }
extern "C" uint32_t output_content_type_ptr() { return (uint32_t)(uintptr_t)output_content_type; }
extern "C" uint32_t output_content_type_size() { return sizeof(output_content_type) - 1; }
extern "C" uint32_t uniform_set_width(uint32_t value) {
  requested_width = value > QIP_KTX2_RGBA8_MAX_DIMENSION ? QIP_KTX2_RGBA8_MAX_DIMENSION : value;
  return requested_width;
}
extern "C" uint32_t uniform_set_height(uint32_t value) {
  requested_height = value > QIP_KTX2_RGBA8_MAX_DIMENSION ? QIP_KTX2_RGBA8_MAX_DIMENSION : value;
  return requested_height;
}
extern "C" uint32_t uniform_set_background_color_rgba(uint32_t value) {
  background_color_rgba = value;
  return value;
}
extern "C" uint32_t arena_peak_bytes() { return arena_peak; }
extern "C" uint32_t arena_live_bytes() { return arena_used; }
extern "C" uint32_t arena_failed_allocation() { return arena_failed_size; }
extern "C" uint32_t arena_free_unmatched_count() { return arena_free_unmatched_count_value; }

static uint32_t dimension(float value) {
  if (!(value > 0) || value > QIP_KTX2_RGBA8_MAX_DIMENSION) return 0;
  uint32_t rounded = (uint32_t)(value + 0.5f);
  return rounded ? rounded : 1;
}

static uint32_t rasterize(const uint8_t* svg, size_t svg_size, sk_sp<SkData>* fonts,
                          size_t font_count, uint32_t width, uint32_t height, uint32_t rgba) {
  SkMemoryStream stream(svg, svg_size, false);
  auto font_manager = SkFontMgr_New_Custom_Data(SkSpan<sk_sp<SkData>>(fonts, font_count));
  // The font manager skips data FreeType cannot open; reject it instead.
  for (size_t i = 0; i < font_count; ++i) {
    if (!font_manager->makeFromData(fonts[i])) return 0;
  }
  auto dom = SkSVGDOM::Builder().setFontManager(font_manager).make(stream);
  if (!dom || !dom->getRoot()) return 0;
  auto* root = dom->getRoot();
  SkSize intrinsic = dom->containerSize();
  if (!(intrinsic.width() > 0) || !(intrinsic.height() > 0)) {
    if (root->getViewBox().isValid()) {
      intrinsic = SkSize::Make(root->getViewBox()->width(), root->getViewBox()->height());
    } else {
      intrinsic = SkSize::Make(300, 150);
    }
  }
  if (!width) width = dimension(intrinsic.width());
  if (!height) height = dimension(intrinsic.height());
  size_t pixel_bytes;
  if (!qip_ktx2_rgba8_dimensions(width, height, &pixel_bytes)) return 0;
  // Preserve SVG coordinates while fitting the drawing into the chosen viewport.
  if (!root->getViewBox().isValid()) {
    root->setViewBox(SkRect::MakeWH(intrinsic.width(), intrinsic.height()));
  }
  root->setWidth(SkSVGLength((float)width));
  root->setHeight(SkSVGLength((float)height));
  dom->setContainerSize(SkSize::Make((float)width, (float)height));
  auto info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType,
                                kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
  auto surface = SkSurfaces::Raster(info);
  if (!surface) return 0;
  SkCanvas* canvas = surface->getCanvas();
  canvas->clear(SkColorSetARGB(rgba & 255, rgba >> 24, (rgba >> 16) & 255, (rgba >> 8) & 255));
  dom->render(canvas);
  uint32_t size = (uint32_t)qip_ktx2_rgba8_write_header(output_buf, OUTPUT_CAP, width, height);
  auto straight = info.makeAlphaType(kUnpremul_SkAlphaType);
  if (!surface->readPixels(straight, output_buf + QIP_KTX2_RGBA8_HEADER_SIZE, width * 4, 0, 0)) return 0;
  return size;
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

// Parses the SVG root and font parts, then rasterizes with only those fonts.
static uint32_t rasterize_related(uint32_t input_size, uint32_t width, uint32_t height, uint32_t rgba) {
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
  return rasterize(svg, svg_size, fonts, font_count, width, height, rgba);
}

extern "C" uint64_t render(uint32_t input_size) {
  const uint32_t width = requested_width;
  const uint32_t height = requested_height;
  const uint32_t rgba = background_color_rgba;
  reset_uniforms();
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
  uint32_t output_size = rasterize_related(input_size, width, height, rgba);
  SkGraphics::PurgeAllCaches();
  if (!output_size || arena_failed_size || arena_free_unmatched_count_value) {
    return UINT64_C(0x8000000000000000);
  }
  return ((uint64_t)(uintptr_t)output_buf << 32) | output_size;
}
