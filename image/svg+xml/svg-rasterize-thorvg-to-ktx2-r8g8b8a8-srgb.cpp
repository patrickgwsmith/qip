#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "thorvg.h"
#include "ktx2-rgba8-srgb.h"

#define INPUT_CAP (1024u * 1024u)
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

static void reset_uniforms(void) {
  requested_width = 0;
  requested_height = 0;
  background_color_rgba = 0;
}

static uint32_t resolve_dimension(uint32_t requested, float intrinsic) {
  if (requested != 0) return requested;
  if (!(intrinsic > 0.0f) || intrinsic > (float)QIP_KTX2_RGBA8_MAX_DIMENSION) {
    return 0;
  }
  uint32_t rounded = (uint32_t)(intrinsic + 0.5f);
  return rounded == 0 ? 1 : rounded;
}

static void fill_background(uint32_t* pixels, size_t count, uint32_t rgba) {
  uint32_t r = rgba >> 24;
  uint32_t g = (rgba >> 16) & 0xffu;
  uint32_t b = (rgba >> 8) & 0xffu;
  uint32_t a = rgba & 0xffu;
  uint32_t abgr = r | (g << 8) | (b << 16) | (a << 24);
  for (size_t i = 0; i < count; ++i) pixels[i] = abgr;
}

extern "C" uint32_t input_ptr(void) {
  return (uint32_t)(uintptr_t)input_buf;
}

extern "C" uint32_t input_bytes_cap(void) { return INPUT_CAP; }

static uint32_t output_ptr(void) {
  return (uint32_t)(uintptr_t)output_buf;
}

extern "C" uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/svg+xml";
static const char output_content_type[] = "image/ktx2";

extern "C" uint32_t input_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)input_content_type;
}

extern "C" uint32_t input_content_type_size(void) {
  return (uint32_t)(sizeof(input_content_type) - 1u);
}

extern "C" uint32_t output_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)output_content_type;
}

extern "C" uint32_t output_content_type_size(void) {
  return (uint32_t)(sizeof(output_content_type) - 1u);
}

extern "C" uint32_t uniform_set_width(uint32_t value) {
  requested_width = value <= QIP_KTX2_RGBA8_MAX_DIMENSION ? value : 0;
  return requested_width;
}

extern "C" uint32_t uniform_set_height(uint32_t value) {
  requested_height = value <= QIP_KTX2_RGBA8_MAX_DIMENSION ? value : 0;
  return requested_height;
}

extern "C" uint32_t uniform_set_background_color_rgba(uint32_t value) {
  background_color_rgba = value;
  return value;
}

extern "C" uint32_t arena_peak_bytes(void) { return (uint32_t)arena_peak; }
extern "C" uint32_t arena_live_bytes(void) { return (uint32_t)arena_used; }
extern "C" uint32_t arena_allocation_count(void) {
  return (uint32_t)arena_alloc_count;
}
extern "C" uint32_t arena_largest_allocation(void) {
  return (uint32_t)arena_largest;
}
extern "C" uint32_t arena_failed_allocation(void) {
  return (uint32_t)arena_failed_size;
}
extern "C" uint32_t arena_free_count(void) {
  return (uint32_t)arena_free_count_value;
}
extern "C" uint32_t arena_free_unmatched_count(void) {
  return (uint32_t)arena_free_unmatched_count_value;
}

extern "C" uint64_t render(uint32_t input_size) {
  uint32_t output_size = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t* pixels = nullptr;
  size_t pixel_bytes = 0;
  float intrinsic_width = 0.0f;
  float intrinsic_height = 0.0f;
  tvg::Picture* picture = nullptr;
  tvg::SwCanvas* canvas = nullptr;
  bool initialized = false;
  bool picture_owned_by_canvas = false;

  if (!constructors_called) {
    __wasm_call_ctors();
    constructors_called = true;
  }
  arena_reset();
  if (input_size == 0 || input_size > INPUT_CAP) goto cleanup;
  input_buf[input_size] = 0;

  if (tvg::Initializer::init(0) != tvg::Result::Success) goto cleanup;
  initialized = true;
  picture = tvg::Picture::gen();
  if (picture == nullptr) goto cleanup;
  if (picture->load((const char*)input_buf, input_size, "svg", nullptr, false) !=
      tvg::Result::Success) {
    goto cleanup;
  }

  if (picture->size(&intrinsic_width, &intrinsic_height) !=
      tvg::Result::Success) {
    goto cleanup;
  }
  width = resolve_dimension(requested_width, intrinsic_width);
  height = resolve_dimension(requested_height, intrinsic_height);
  if (!qip_ktx2_rgba8_dimensions(width, height, &pixel_bytes)) goto cleanup;
  if (picture->size((float)width, (float)height) != tvg::Result::Success) {
    goto cleanup;
  }
  output_size = (uint32_t)qip_ktx2_rgba8_write_header(
      output_buf, OUTPUT_CAP, width, height);
  if (output_size == 0) goto cleanup;

  pixels = (uint32_t*)(void*)(output_buf + QIP_KTX2_RGBA8_HEADER_SIZE);
  fill_background(pixels, pixel_bytes / 4u, background_color_rgba);
  canvas = tvg::SwCanvas::gen(tvg::EngineOption::Default);
  if (canvas == nullptr) goto cleanup;
  if (canvas->target(pixels, width, width, height, tvg::ColorSpace::ABGR8888S) !=
      tvg::Result::Success) {
    goto cleanup;
  }
  if (canvas->add(picture) != tvg::Result::Success) goto cleanup;
  picture_owned_by_canvas = true;
  if (canvas->draw(false) != tvg::Result::Success) goto cleanup;
  if (canvas->sync() != tvg::Result::Success) goto cleanup;

cleanup:
  if (canvas != nullptr) delete canvas;
  if (picture != nullptr && !picture_owned_by_canvas) tvg::Paint::rel(picture);
  if (initialized) tvg::Initializer::term();
  reset_uniforms();
  if (arena_failed_size != 0 || arena_free_unmatched_count_value != 0 ||
      arena_used != 0) {
    output_size = 0;
  }
  return ((uint64_t)output_ptr() << 32) | output_size;
}
