#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "src/webp/decode.h"

#ifdef QIP_WEBP_OUTPUT_KTX2_RGBA8
#include "../lib/ktx2-rgba8-srgb.h"
#endif

#define MAX_PIXELS 25000000u
#define MAX_DIMENSION 8192u
#define INPUT_CAP (64u * 1024u * 1024u)
#ifdef QIP_WEBP_OUTPUT_KTX2_RGBA8
#define OUTPUT_HEADER_SIZE QIP_KTX2_RGBA8_HEADER_SIZE
#else
#define OUTPUT_HEADER_SIZE 54u
#endif
#define OUTPUT_CAP (MAX_PIXELS * 4u + OUTPUT_HEADER_SIZE)
#define ARENA_CAP (256u * 1024u * 1024u)

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));

static size_t arena_used;
static size_t arena_peak;
static size_t arena_alloc_count;
static size_t arena_largest;
static size_t arena_failed_size;
static size_t arena_free_count_value;
static size_t arena_free_unmatched_count_value;

typedef struct ArenaBlock {
  uint32_t size;
  uint32_t next;
  uint32_t prev;
  uint32_t is_free;
} ArenaBlock;

#define NO_BLOCK UINT32_MAX

void* malloc(size_t size) {
  size_t aligned;
  uint32_t offset = 0;
  ArenaBlock* block;
  void* result;
  if (size == 0) size = 1;
  if (size > UINT32_MAX - 15u) return NULL;
  aligned = (size + 15u) & ~(size_t)15u;
  while (offset != NO_BLOCK) {
    block = (ArenaBlock*)(void*)(arena + offset);
    if (block->is_free && block->size >= aligned) break;
    offset = block->next;
  }
  if (offset == NO_BLOCK) {
    arena_failed_size = size;
    return NULL;
  }
  if (block->size >= aligned + sizeof(ArenaBlock) + 16u) {
    const uint32_t new_offset =
        offset + (uint32_t)sizeof(ArenaBlock) + (uint32_t)aligned;
    ArenaBlock* const split = (ArenaBlock*)(void*)(arena + new_offset);
    split->size =
        block->size - (uint32_t)aligned - (uint32_t)sizeof(ArenaBlock);
    split->next = block->next;
    split->prev = offset;
    split->is_free = 1;
    if (block->next != NO_BLOCK) {
      ((ArenaBlock*)(void*)(arena + block->next))->prev = new_offset;
    }
    block->next = new_offset;
    block->size = (uint32_t)aligned;
  }
  block->is_free = 0;
  result = (uint8_t*)block + sizeof(ArenaBlock);
  arena_used += block->size;
  if (arena_used > arena_peak) arena_peak = arena_used;
  if (size > arena_largest) arena_largest = size;
  ++arena_alloc_count;
  return result;
}

void* calloc(size_t count, size_t size) {
  size_t total;
  void* result;
  if (count != 0 && size > SIZE_MAX / count) return NULL;
  total = count * size;
  result = malloc(total);
  if (result != NULL) memset(result, 0, total);
  return result;
}

void free(void* ptr) {
  uintptr_t address;
  uintptr_t arena_address;
  ArenaBlock* block;
  if (ptr == NULL) return;
  ++arena_free_count_value;
  address = (uintptr_t)ptr;
  arena_address = (uintptr_t)arena;
  if (address < arena_address + sizeof(ArenaBlock) ||
      address - arena_address >= ARENA_CAP) {
    ++arena_free_unmatched_count_value;
    return;
  }
  block = (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
  if (block->is_free) {
    ++arena_free_unmatched_count_value;
    return;
  }
  block->is_free = 1;
  arena_used -= block->size;
  if (block->next != NO_BLOCK) {
    ArenaBlock* const next = (ArenaBlock*)(void*)(arena + block->next);
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
    ArenaBlock* const prev = (ArenaBlock*)(void*)(arena + block->prev);
    if (prev->is_free) {
      prev->size += (uint32_t)sizeof(ArenaBlock) + block->size;
      prev->next = block->next;
      if (block->next != NO_BLOCK) {
        ((ArenaBlock*)(void*)(arena + block->next))->prev = block->prev;
      }
    }
  }
}

static void arena_reset(void) {
  ArenaBlock* const first = (ArenaBlock*)(void*)arena;
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

static void write_u16_le(uint8_t* p, uint16_t value) {
  p[0] = (uint8_t)value;
  p[1] = (uint8_t)(value >> 8);
}

static void write_u32_le(uint8_t* p, uint32_t value) {
  p[0] = (uint8_t)value;
  p[1] = (uint8_t)(value >> 8);
  p[2] = (uint8_t)(value >> 16);
  p[3] = (uint8_t)(value >> 24);
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/webp";
#ifdef QIP_WEBP_OUTPUT_KTX2_RGBA8
static const char output_content_type[] = "image/ktx2";
#else
static const char output_content_type[] = "image/bmp";
#endif

uint32_t input_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)input_content_type;
}
uint32_t input_content_type_size(void) {
  return (uint32_t)(sizeof(input_content_type) - 1);
}
uint32_t output_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)output_content_type;
}
uint32_t output_content_type_size(void) {
  return (uint32_t)(sizeof(output_content_type) - 1);
}

uint32_t arena_peak_bytes(void) { return (uint32_t)arena_peak; }
uint32_t arena_live_bytes(void) { return (uint32_t)arena_used; }
uint32_t arena_allocation_count(void) {
  return (uint32_t)arena_alloc_count;
}
uint32_t arena_largest_allocation(void) {
  return (uint32_t)arena_largest;
}
uint32_t arena_failed_allocation(void) {
  return (uint32_t)arena_failed_size;
}
uint32_t arena_free_count(void) {
  return (uint32_t)arena_free_count_value;
}
uint32_t arena_free_unmatched_count(void) {
  return (uint32_t)arena_free_unmatched_count_value;
}

uint64_t render(uint32_t input_size_value) {
  WebPBitstreamFeatures features;
  VP8StatusCode status;
  uint64_t pixel_count;
  uint32_t pixel_bytes;
  uint32_t output_size;
  uint8_t* decoded;

  if (input_size_value > INPUT_CAP) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  arena_reset();

  status = WebPGetFeatures(input_buf, input_size_value, &features);
  if (status != VP8_STATUS_OK || features.width <= 0 || features.height <= 0 ||
      (uint32_t)features.width > MAX_DIMENSION ||
      (uint32_t)features.height > MAX_DIMENSION || features.has_animation) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  pixel_count = (uint64_t)(uint32_t)features.width *
                (uint64_t)(uint32_t)features.height;
  if (pixel_count > MAX_PIXELS) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  pixel_bytes = (uint32_t)(pixel_count * 4u);
  output_size = OUTPUT_HEADER_SIZE + pixel_bytes;

#ifdef QIP_WEBP_OUTPUT_KTX2_RGBA8
  decoded = WebPDecodeRGBAInto(input_buf, input_size_value,
                               output_buf + OUTPUT_HEADER_SIZE, pixel_bytes,
                               features.width * 4);
#else
  decoded = WebPDecodeBGRAInto(input_buf, input_size_value,
                               output_buf + OUTPUT_HEADER_SIZE, pixel_bytes,
                               features.width * 4);
#endif
  if (decoded == NULL || arena_failed_size != 0) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);

#ifdef QIP_WEBP_OUTPUT_KTX2_RGBA8
  if (qip_ktx2_rgba8_write_header(output_buf, OUTPUT_CAP,
                                   (uint32_t)features.width,
                                   (uint32_t)features.height) != output_size) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
#else
  memset(output_buf, 0, OUTPUT_HEADER_SIZE);
  output_buf[0] = 'B';
  output_buf[1] = 'M';
  write_u32_le(output_buf + 2, output_size);
  write_u32_le(output_buf + 10, OUTPUT_HEADER_SIZE);
  write_u32_le(output_buf + 14, 40);
  write_u32_le(output_buf + 18, (uint32_t)features.width);
  write_u32_le(output_buf + 22, (uint32_t)(-features.height));
  write_u16_le(output_buf + 26, 1);
  write_u16_le(output_buf + 28, 32);
  write_u32_le(output_buf + 34, pixel_bytes);
  write_u32_le(output_buf + 38, 2835);
  write_u32_le(output_buf + 42, 2835);
#endif
  return ((uint64_t)output_ptr() << 32) | (uint32_t)(output_size);
}
