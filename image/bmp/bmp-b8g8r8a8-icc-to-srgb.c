#include <limits.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "lcms2.h"

#define MAX_PIXELS 25000000u
#define MAX_DIMENSION 8192u
#define BMP_HEADER_CAP (64u * 1024u)
#define INPUT_CAP (MAX_PIXELS * 4u + BMP_HEADER_CAP)
#define OUTPUT_CAP (MAX_PIXELS * 4u + 54u)
#define ARENA_CAP (256u * 1024u * 1024u)
#define BMP_FILE_HEADER_SIZE 14u
#define BMP_INFO_HEADER_SIZE 40u
#define BMP_V5_HEADER_SIZE 124u
#define PROFILE_EMBEDDED 0x4d424544u /* 'MEBD' in little-endian storage. */
#define PROFILE_LINKED 0x4c494e4bu   /* 'LINK' in little-endian storage. */
#define LCS_SRGB 0x73524742u         /* 'sRGB' in little-endian storage. */

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));

static size_t arena_used;
static size_t arena_peak;
static size_t arena_alloc_count_value;
static size_t arena_largest;
static size_t arena_failed_size;
static size_t arena_free_count_value;
static size_t arena_free_matched_count_value;
static size_t arena_free_unmatched_count_value;
static int arena_initialized;

// Satisfy libc's weak environment aliases without retaining its WASI-backed
// environment constructor. This component has no process environment.
char** __environ = NULL;

typedef struct ArenaBlock {
  uint32_t size;
  uint32_t next;
  uint32_t prev;
  uint32_t is_free;
} ArenaBlock;

#define NO_BLOCK UINT32_MAX

static void arena_reset(void) {
  ArenaBlock* const first = (ArenaBlock*)(void*)arena;
  arena_initialized = 1;
  arena_used = 0;
  arena_peak = 0;
  arena_alloc_count_value = 0;
  arena_largest = 0;
  arena_failed_size = 0;
  arena_free_count_value = 0;
  arena_free_matched_count_value = 0;
  arena_free_unmatched_count_value = 0;
  first->size = ARENA_CAP - (uint32_t)sizeof(ArenaBlock);
  first->next = NO_BLOCK;
  first->prev = NO_BLOCK;
  first->is_free = 1;
}

static void arena_initialize_if_needed(void) {
  ArenaBlock* const first = (ArenaBlock*)(void*)arena;
  if (arena_initialized) return;
  arena_initialized = 1;
  first->size = ARENA_CAP - (uint32_t)sizeof(ArenaBlock);
  first->next = NO_BLOCK;
  first->prev = NO_BLOCK;
  first->is_free = 1;
}

void* malloc(size_t size) {
  size_t aligned;
  uint32_t offset = 0;
  ArenaBlock* block;
  void* result;

  arena_initialize_if_needed();
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
    const uint32_t new_offset = offset + (uint32_t)sizeof(ArenaBlock) +
                                (uint32_t)aligned;
    ArenaBlock* const split = (ArenaBlock*)(void*)(arena + new_offset);
    split->size = block->size - (uint32_t)aligned -
                  (uint32_t)sizeof(ArenaBlock);
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
  ++arena_alloc_count_value;
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
  ++arena_free_matched_count_value;
}

void* realloc(void* ptr, size_t size) {
  ArenaBlock* block;
  void* result;
  size_t copy_size;

  if (ptr == NULL) return malloc(size);
  if (size == 0) {
    free(ptr);
    return NULL;
  }
  block = (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
  if (block->size >= size) return ptr;
  result = malloc(size);
  if (result == NULL) return NULL;
  copy_size = block->size < size ? block->size : size;
  memcpy(result, ptr, copy_size);
  free(ptr);
  return result;
}

// The component does not use Little CMS file APIs. These wrappers keep
// accidental references from pulling a filesystem or WASI dependency into
// the final module.
FILE* __wrap_fopen(const char* filename, const char* mode) {
  (void)filename;
  (void)mode;
  return NULL;
}
int __wrap_fclose(FILE* stream) {
  (void)stream;
  return -1;
}
size_t __wrap_fread(void* ptr, size_t size, size_t count, FILE* stream) {
  (void)ptr;
  (void)size;
  (void)count;
  (void)stream;
  return 0;
}
size_t __wrap_fwrite(const void* ptr, size_t size, size_t count, FILE* stream) {
  (void)ptr;
  (void)size;
  (void)count;
  (void)stream;
  return 0;
}
int __wrap_fseek(FILE* stream, long offset, int origin) {
  (void)stream;
  (void)offset;
  (void)origin;
  return -1;
}
long __wrap_ftell(FILE* stream) {
  (void)stream;
  return -1;
}
int __wrap_feof(FILE* stream) {
  (void)stream;
  return 1;
}
int __wrap_ferror(FILE* stream) {
  (void)stream;
  return 1;
}
int __wrap_fflush(FILE* stream) {
  (void)stream;
  return 0;
}
int __wrap_remove(const char* filename) {
  (void)filename;
  return -1;
}

// Profile creation and transformation must not read a host clock.
time_t time(time_t* value) {
  if (value != NULL) *value = (time_t)1;
  return (time_t)1;
}

static uint16_t read_u16_le(const uint8_t* p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_u32_le(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
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

static void write_i32_le(uint8_t* p, int32_t value) {
  write_u32_le(p, (uint32_t)value);
}

static void lcms_log_error(cmsContext context, cmsUInt32Number code,
                           const char* text) {
  (void)context;
  (void)code;
  (void)text;
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/bmp";
static const char output_content_type[] = "image/bmp";
uint32_t input_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)input_content_type;
}
uint32_t input_content_type_size(void) { return sizeof(input_content_type) - 1; }
uint32_t output_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)output_content_type;
}
uint32_t output_content_type_size(void) {
  return sizeof(output_content_type) - 1;
}

uint32_t arena_peak_bytes(void) { return (uint32_t)arena_peak; }
uint32_t arena_allocation_count(void) {
  return (uint32_t)arena_alloc_count_value;
}
uint32_t arena_largest_allocation(void) { return (uint32_t)arena_largest; }
uint32_t arena_failed_allocation(void) {
  return (uint32_t)arena_failed_size;
}
uint32_t arena_free_count(void) {
  return (uint32_t)arena_free_count_value;
}
uint32_t arena_free_matched_count(void) {
  return (uint32_t)arena_free_matched_count_value;
}
uint32_t arena_free_unmatched_count(void) {
  return (uint32_t)arena_free_unmatched_count_value;
}

static int parse_bmp(size_t input_size, int32_t* width_out, uint32_t* height_out,
                     int* top_down_out, size_t* pixel_offset_out,
                     size_t* pixel_bytes_out, const uint8_t** profile_out,
                     uint32_t* profile_size_out) {
  uint32_t pixel_offset;
  uint32_t dib_size;
  int32_t width;
  int32_t height_signed;
  uint32_t compression;
  uint32_t height;
  size_t pixel_bytes;
  size_t profile_offset;
  uint32_t profile_data;
  uint32_t profile_size;
  uint32_t color_space;

  if (input_size < 54 || input_buf[0] != 'B' || input_buf[1] != 'M') return 0;
  pixel_offset = read_u32_le(input_buf + 10);
  dib_size = read_u32_le(input_buf + 14);
  width = (int32_t)read_u32_le(input_buf + 18);
  height_signed = (int32_t)read_u32_le(input_buf + 22);
  compression = read_u32_le(input_buf + 30);
  if (dib_size != BMP_INFO_HEADER_SIZE && dib_size != BMP_V5_HEADER_SIZE) {
    return 0;
  }
  if (pixel_offset < BMP_FILE_HEADER_SIZE + dib_size ||
      read_u16_le(input_buf + 26) != 1 || read_u16_le(input_buf + 28) != 32 ||
      width <= 0 || (uint32_t)width > MAX_DIMENSION || height_signed == 0 ||
      height_signed == INT32_MIN) {
    return 0;
  }
  if (compression != 0 &&
      (compression != 3 || dib_size != BMP_V5_HEADER_SIZE ||
       pixel_offset < 138 || read_u32_le(input_buf + 54) != 0x00ff0000u ||
       read_u32_le(input_buf + 58) != 0x0000ff00u ||
       read_u32_le(input_buf + 62) != 0x000000ffu ||
       read_u32_le(input_buf + 66) != 0xff000000u)) {
    return 0;
  }
  height = (uint32_t)(height_signed < 0 ? -height_signed : height_signed);
  if (height > MAX_DIMENSION ||
      (uint64_t)(uint32_t)width * height > MAX_PIXELS ||
      (size_t)width > SIZE_MAX / 4u / height) {
    return 0;
  }
  pixel_bytes = (size_t)width * 4u * height;
  if (pixel_offset > input_size || pixel_bytes > input_size - pixel_offset) {
    return 0;
  }

  *profile_out = NULL;
  *profile_size_out = 0;
  if (dib_size == BMP_V5_HEADER_SIZE) {
    color_space = read_u32_le(input_buf + 70);
    if (color_space == PROFILE_LINKED) return 0;
    if (color_space != LCS_SRGB && color_space != PROFILE_EMBEDDED) return 0;
    if (color_space == PROFILE_EMBEDDED) {
      profile_data = read_u32_le(input_buf + 126);
      profile_size = read_u32_le(input_buf + 130);
      if (profile_size == 0 || profile_size > BMP_HEADER_CAP ||
          profile_data < BMP_V5_HEADER_SIZE ||
          profile_data > SIZE_MAX - BMP_FILE_HEADER_SIZE) {
        return 0;
      }
      profile_offset = BMP_FILE_HEADER_SIZE + (size_t)profile_data;
      if (profile_offset < pixel_offset + pixel_bytes ||
          profile_offset > input_size ||
          profile_size > input_size - profile_offset) {
        return 0;
      }
      *profile_out = input_buf + profile_offset;
      *profile_size_out = profile_size;
    }
  }

  *width_out = width;
  *height_out = height;
  *top_down_out = height_signed < 0;
  *pixel_offset_out = pixel_offset;
  *pixel_bytes_out = pixel_bytes;
  return 1;
}

static void write_bmp_header(int32_t width, uint32_t height,
                             uint32_t pixel_bytes) {
  memset(output_buf, 0, 54);
  output_buf[0] = 'B';
  output_buf[1] = 'M';
  write_u32_le(output_buf + 2, 54u + pixel_bytes);
  write_u32_le(output_buf + 10, 54);
  write_u32_le(output_buf + 14, BMP_INFO_HEADER_SIZE);
  write_i32_le(output_buf + 18, width);
  write_i32_le(output_buf + 22, (int32_t)height);
  write_u16_le(output_buf + 26, 1);
  write_u16_le(output_buf + 28, 32);
  write_u32_le(output_buf + 30, 0);
  write_u32_le(output_buf + 34, pixel_bytes);
}

uint64_t render(uint32_t input_size_value) {
  size_t input_size = input_size_value;
  int32_t width;
  uint32_t height;
  int top_down;
  size_t pixel_offset;
  size_t pixel_bytes;
  size_t row_bytes;
  size_t y;
  const uint8_t* profile_data;
  uint32_t profile_size;
  cmsHPROFILE input_profile = NULL;
  cmsHPROFILE output_profile = NULL;
  cmsHTRANSFORM transform = NULL;

  arena_reset();
  if (input_size > INPUT_CAP) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  if (!parse_bmp(input_size, &width, &height, &top_down, &pixel_offset,
                 &pixel_bytes, &profile_data, &profile_size)) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }

  write_bmp_header(width, height, (uint32_t)pixel_bytes);
  row_bytes = (size_t)width * 4u;
  for (y = 0; y < height; ++y) {
    const size_t destination_y = top_down ? height - 1u - y : y;
    memcpy(output_buf + 54 + destination_y * row_bytes,
           input_buf + pixel_offset + y * row_bytes, row_bytes);
  }

  // A legacy BMP and a V5 BMP marked sRGB already use the canonical QIP
  // interchange space. Copy those pixels without a color-management round
  // trip so the component remains lossless for the common case.
  if (profile_data == NULL) return ((uint64_t)output_ptr() << 32) | (uint32_t)(54u + (uint32_t)pixel_bytes);

  cmsSetLogErrorHandler(lcms_log_error);
  input_profile = cmsOpenProfileFromMem(profile_data, profile_size);
  output_profile = cmsCreate_sRGBProfile();
  if (input_profile == NULL || output_profile == NULL) goto cleanup;
  transform = cmsCreateTransform(input_profile, TYPE_BGRA_8, output_profile,
                                 TYPE_BGRA_8, INTENT_PERCEPTUAL,
                                 cmsFLAGS_COPY_ALPHA | cmsFLAGS_LOWRESPRECALC);
  if (transform == NULL) goto cleanup;
  cmsDoTransform(transform, output_buf + 54, output_buf + 54,
                 (cmsUInt32Number)(pixel_bytes / 4u));

cleanup:
  if (transform != NULL) cmsDeleteTransform(transform);
  if (output_profile != NULL) cmsCloseProfile(output_profile);
  if (input_profile != NULL) cmsCloseProfile(input_profile);
  if (transform == NULL || input_profile == NULL || output_profile == NULL) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  return ((uint64_t)output_ptr() << 32) | (uint32_t)(54u + (uint32_t)pixel_bytes);
}
