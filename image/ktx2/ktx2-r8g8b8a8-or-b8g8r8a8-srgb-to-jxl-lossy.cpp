#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "jxl/encode.h"
#include "jxl/color_encoding.h"
#include "ktx2-rgba8-srgb.h"

#define INPUT_CAP QIP_KTX2_RGBA8_MAX_FILE_SIZE
#define OUTPUT_CAP (128u * 1024u * 1024u)
#define ARENA_CAP (448u * 1024u * 1024u)
#define NO_BLOCK UINT32_MAX
#define MAX_EFFORT 9u
#define DEFAULT_EFFORT 5u

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
static float distance = 1.0f;
static uint32_t encoded_channels;
static uint32_t failure_stage;
static uint32_t encoder_error;
static bool constructors_called;
static bool arena_initialized;

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

// libc's diagnostics must not turn this Content component into a WASI module.
extern "C" __attribute__((noreturn)) void __wasi_proc_exit(uint32_t) {
  __builtin_trap();
}
extern "C" int __wasi_fd_close(uint32_t) { return 8; }
extern "C" int __wasi_fd_write(uint32_t, const void*, uint32_t, uint32_t*) {
  return 8;
}
extern "C" int __wasi_fd_seek(uint32_t, int64_t, uint32_t, uint64_t*) {
  return 8;
}

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
  if (block->size == UINT32_MAX) {
    if (block->next >= ARENA_CAP) return nullptr;
    block = (ArenaBlock*)(void*)(arena + block->next);
  }
  if (block->is_free) return nullptr;
  return block;
}

extern "C" int posix_memalign(void** result, size_t alignment, size_t size) {
  if (alignment < sizeof(void*) || (alignment & (alignment - 1u)) != 0) {
    return 22;
  }
  if (alignment <= 16u) {
    *result = malloc(size);
    return *result == nullptr ? 12 : 0;
  }
  if (size > SIZE_MAX - alignment - sizeof(ArenaBlock)) return 12;
  uint8_t* base = (uint8_t*)malloc(size + alignment + sizeof(ArenaBlock));
  if (base == nullptr) return 12;
  uintptr_t aligned = ((uintptr_t)(base + sizeof(ArenaBlock)) + alignment - 1u) &
                      ~(uintptr_t)(alignment - 1u);
  ArenaBlock* marker = (ArenaBlock*)(void*)(aligned - sizeof(ArenaBlock));
  marker->size = UINT32_MAX;
  marker->next = (uint32_t)(base - arena - sizeof(ArenaBlock));
  marker->prev = 0;
  marker->is_free = 0;
  *result = (void*)aligned;
  return 0;
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
  size_t old_size = block->size -
                    ((uint8_t*)ptr - ((uint8_t*)block + sizeof(ArenaBlock)));
  if (size <= old_size) return ptr;
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

static void arena_start_call(void) {
  if (!arena_initialized) {
    arena_reset();
    arena_initialized = true;
  }
  arena_peak = arena_used;
  arena_alloc_count = 0;
  arena_largest = 0;
  arena_failed_size = 0;
  arena_free_count_value = 0;
  arena_free_unmatched_count_value = 0;
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
  effort = value < 1 ? 1 : value > MAX_EFFORT ? MAX_EFFORT : value;
  return effort;
}

extern "C" float uniform_set_distance(float value) {
  if (value >= 0.1f && value <= 15.0f) distance = value;
  return distance;
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
extern "C" uint32_t last_failure_stage(void) { return failure_stage; }
extern "C" uint32_t last_encoder_error(void) { return encoder_error; }

extern "C" uint64_t render(uint32_t input_size) {
  QipKtx2Rgba8Image image;
  JxlEncoder* encoder = nullptr;
  JxlEncoderFrameSettings* settings;
  JxlBasicInfo info;
  JxlColorEncoding color;
  JxlPixelFormat format;
  uint8_t* next_output;
  size_t available;
  JxlEncoderStatus status;
  size_t output_size = 0;

  arena_start_call();
  if (!constructors_called) {
    __wasm_call_ctors();
    constructors_called = true;
  }
  encoded_channels = 0;
  failure_stage = 1;
  encoder_error = 0;
  if (input_size > INPUT_CAP ||
      !qip_ktx2_srgb8_parse(input_buf, input_size, &image)) {
    goto cleanup;
  }
  encoded_channels =
      prepare_pixels(image.pixels, image.pixel_bytes, image.is_rgba);
  failure_stage = 2;
  encoder = JxlEncoderCreate(nullptr);
  if (encoder == nullptr) goto cleanup;
  JxlEncoderInitBasicInfo(&info);
  info.xsize = image.width;
  info.ysize = image.height;
  info.bits_per_sample = 8;
  info.uses_original_profile = JXL_FALSE;
  if (encoded_channels == 4) {
    info.alpha_bits = 8;
    info.num_extra_channels = 1;
  }
  failure_stage = 3;
  if (JxlEncoderSetBasicInfo(encoder, &info) != JXL_ENC_SUCCESS) goto cleanup;
  JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
  failure_stage = 4;
  if (JxlEncoderSetColorEncoding(encoder, &color) != JXL_ENC_SUCCESS) goto cleanup;
  failure_stage = 5;
  settings = JxlEncoderFrameSettingsCreate(encoder, nullptr);
  if (settings == nullptr ||
      JxlEncoderSetFrameDistance(settings, distance) != JXL_ENC_SUCCESS ||
      JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT,
                                       (int)effort) != JXL_ENC_SUCCESS) {
    goto cleanup;
  }
  format.num_channels = encoded_channels;
  format.data_type = JXL_TYPE_UINT8;
  format.endianness = JXL_NATIVE_ENDIAN;
  format.align = 0;
  failure_stage = 6;
  if (JxlEncoderAddImageFrame(settings, &format, image.pixels,
                              (size_t)image.width * image.height * encoded_channels) !=
      JXL_ENC_SUCCESS) {
    goto cleanup;
  }
  JxlEncoderCloseInput(encoder);
  failure_stage = 7;
  next_output = output_buf;
  available = OUTPUT_CAP;
  do {
    status = JxlEncoderProcessOutput(encoder, &next_output, &available);
  } while (status == JXL_ENC_NEED_MORE_OUTPUT && available != 0);
  if (status == JXL_ENC_SUCCESS) {
    output_size = (size_t)(next_output - output_buf);
    failure_stage = 0;
  }

cleanup:
  if (encoder != nullptr) encoder_error = (uint32_t)JxlEncoderGetError(encoder);
  if (encoder != nullptr) JxlEncoderDestroy(encoder);
  // libjxl and libc keep small process-wide caches between calls.
  if (arena_failed_size != 0 || arena_free_unmatched_count_value != 0 ||
      arena_used > 8u * 1024u * 1024u) {
    output_size = 0;
  }
  return ((uint64_t)output_ptr() << 32) | (uint32_t)output_size;
}
