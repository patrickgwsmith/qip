#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "lib/jxl/enc_fast_lossless.h"
#include "ktx2-rgba8-srgb.h"

#define INPUT_CAP QIP_KTX2_RGBA8_MAX_FILE_SIZE
#define OUTPUT_CAP (128u * 1024u * 1024u)
#define ARENA_CAP (448u * 1024u * 1024u)
#define NO_BLOCK UINT32_MAX
#define MAX_EFFORT 127u
#define DEFAULT_EFFORT 2u

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
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
static uint32_t effort = DEFAULT_EFFORT;
static uint32_t encoded_channels;
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

// libc++'s non-throwing operator new aborts when malloc fails. Trap instead of
// reaching Emscripten's JavaScript abort path.
extern "C" __attribute__((noreturn)) void abort(void) { __builtin_trap(); }

extern "C" int __cxa_atexit(void (*)(void*), void*, void*) { return 0; }

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
  uint32_t old_size = block->size;
  if (align16(size) != 0 && align16(size) <= old_size) return ptr;
  void* replacement = malloc(size);
  if (replacement == nullptr) return nullptr;
  memcpy(replacement, ptr, old_size);
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

// The Content input is disposable. Opaque images are packed to RGB in place so
// the JPEG XL file has no alpha channel; other images become RGBA in place.
static uint32_t prepare_pixels(uint8_t* pixels, size_t pixel_bytes,
                               int is_rgba) {
  const size_t red = is_rgba ? 0u : 2u;
  const size_t blue = is_rgba ? 2u : 0u;
  uint8_t alpha_and = 0xffu;
  size_t in;
  size_t out = 0;
  for (in = 3u; in < pixel_bytes; in += 4u) alpha_and &= pixels[in];
  if (alpha_and == 0xffu) {
    for (in = 0; in < pixel_bytes; in += 4u, out += 3u) {
      const uint8_t r = pixels[in + red];
      const uint8_t g = pixels[in + 1u];
      const uint8_t b = pixels[in + blue];
      pixels[out] = r;
      pixels[out + 1u] = g;
      pixels[out + 2u] = b;
    }
    return 3u;
  }
  if (!is_rgba) {
    for (in = 0; in < pixel_bytes; in += 4u) {
      const uint8_t b = pixels[in];
      pixels[in] = pixels[in + 2u];
      pixels[in + 2u] = b;
    }
  }
  return 4u;
}

typedef struct {
  const uint8_t* pixels;
  size_t row_stride;
  size_t bytes_per_pixel;
} FrameInput;

static const void* frame_input_at(void* opaque, size_t xpos, size_t ypos,
                                  size_t, size_t, size_t* row_offset) {
  const FrameInput* input = (const FrameInput*)opaque;
  *row_offset = input->row_stride;
  return input->pixels + ypos * input->row_stride +
         xpos * input->bytes_per_pixel;
}

static void frame_input_release(void*, const void*) {}

extern "C" uint32_t input_ptr(void) {
  return (uint32_t)(uintptr_t)input_buf;
}

extern "C" uint32_t input_bytes_cap(void) { return INPUT_CAP; }

static uint32_t output_ptr(void) {
  return (uint32_t)(uintptr_t)output_buf;
}

extern "C" uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/ktx2";
static const char output_content_type[] = "image/jxl";

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

extern "C" uint32_t uniform_set_effort(uint32_t value) {
  effort = value > MAX_EFFORT ? MAX_EFFORT : value;
  return effort;
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
extern "C" uint32_t encoded_channel_count(void) { return encoded_channels; }

extern "C" uint64_t render(uint32_t input_size) {
  QipKtx2Rgba8Image image;
  FrameInput frame_input;
  JxlChunkedFrameInputSource source;
  JxlFastLosslessFrameState* frame = nullptr;
  size_t output_size = 0;
  size_t written;

  if (!constructors_called) {
    __wasm_call_ctors();
    constructors_called = true;
  }
  arena_reset();
  encoded_channels = 0;
  if (input_size > INPUT_CAP ||
      !qip_ktx2_srgb8_parse(input_buf, input_size, &image)) {
    goto cleanup;
  }
  encoded_channels =
      prepare_pixels(image.pixels, image.pixel_bytes, image.is_rgba);
  frame_input.pixels = image.pixels;
  frame_input.bytes_per_pixel = encoded_channels;
  frame_input.row_stride = (size_t)image.width * encoded_channels;
  source.opaque = &frame_input;
  source.get_color_channel_data_at = frame_input_at;
  source.release_buffer = frame_input_release;

  frame = JxlFastLosslessPrepareFrame(source, image.width, image.height,
                                      encoded_channels, 8, false, (int)effort,
                                      /*oneshot=*/1);
  if (frame == nullptr) goto cleanup;
  if (!JxlFastLosslessProcessFrame(frame, /*is_last=*/true, nullptr, nullptr,
                                   nullptr)) {
    goto cleanup;
  }
  if (!JxlFastLosslessPrepareHeader(frame, /*add_image_header=*/1,
                                    /*is_last=*/1)) {
    goto cleanup;
  }
  if (JxlFastLosslessMaxRequiredOutput(frame) > OUTPUT_CAP) goto cleanup;
  while ((written = JxlFastLosslessWriteOutput(
              frame, output_buf + output_size, OUTPUT_CAP - output_size)) !=
         0) {
    output_size += written;
  }

cleanup:
  if (frame != nullptr) JxlFastLosslessFreeFrameState(frame);
  if (arena_failed_size != 0 || arena_free_unmatched_count_value != 0 ||
      arena_used != 0) {
    output_size = 0;
  }
  return ((uint64_t)output_ptr() << 32) | (uint32_t)output_size;
}
