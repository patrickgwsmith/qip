#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jpeglib.h"
#include "jerror.h"

#ifdef QIP_JPEG_INPUT_KTX2_SRGB8_EITHER
#include "../lib/ktx2-rgba8-srgb.h"
#endif

#define MAX_PIXELS 25000000u
#define MAX_DIMENSION 8192u
#define BMP_HEADER_CAP (64u * 1024u)
#ifdef QIP_JPEG_INPUT_KTX2_SRGB8_EITHER
#define INPUT_CAP (MAX_PIXELS * 4u + QIP_KTX2_RGBA8_HEADER_SIZE)
#else
#define INPUT_CAP (MAX_PIXELS * 4u + BMP_HEADER_CAP)
#endif
#define OUTPUT_CAP (80u * 1024u * 1024u)
#define ARENA_CAP (336u * 1024u * 1024u)
#define ROW_CAP (3u * MAX_DIMENSION)

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));
static uint8_t row_buf[ROW_CAP] __attribute__((aligned(16)));

static uint32_t quality = 85;
static uint32_t subsample = 2;
static uint32_t background_color_rgb = 0xffffffu;
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

void* malloc(size_t size) {
  uint32_t offset = 0;
  size_t aligned;
  ArenaBlock* block;
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
    uint32_t split_offset = offset + (uint32_t)sizeof(ArenaBlock) + (uint32_t)aligned;
    ArenaBlock* split = (ArenaBlock*)(void*)(arena + split_offset);
    split->size = block->size - (uint32_t)aligned - (uint32_t)sizeof(ArenaBlock);
    split->next = block->next;
    split->prev = offset;
    split->is_free = 1;
    if (block->next != NO_BLOCK)
      ((ArenaBlock*)(void*)(arena + block->next))->prev = split_offset;
    block->next = split_offset;
    block->size = (uint32_t)aligned;
  }
  block->is_free = 0;
  arena_used += block->size;
  if (arena_used > arena_peak) arena_peak = arena_used;
  if (size > arena_largest) arena_largest = size;
  ++arena_alloc_count;
  return (uint8_t*)block + sizeof(ArenaBlock);
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
  uintptr_t base;
  ArenaBlock* block;
  if (ptr == NULL) return;
  ++arena_free_count_value;
  address = (uintptr_t)ptr;
  base = (uintptr_t)arena;
  if (address < base + sizeof(ArenaBlock) || address >= base + ARENA_CAP) {
    ++arena_free_unmatched_count_value;
    return;
  }
  block = (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
  if (block->is_free || block->size > arena_used) {
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
      if (next->next != NO_BLOCK)
        ((ArenaBlock*)(void*)(arena + next->next))->prev =
            (uint32_t)((uint8_t*)block - arena);
    }
  }
  if (block->prev != NO_BLOCK) {
    ArenaBlock* prev = (ArenaBlock*)(void*)(arena + block->prev);
    if (prev->is_free) {
      prev->size += (uint32_t)sizeof(ArenaBlock) + block->size;
      prev->next = block->next;
      if (block->next != NO_BLOCK)
        ((ArenaBlock*)(void*)(arena + block->next))->prev = block->prev;
    }
  }
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

char* getenv(const char* name) {
  (void)name;
  return NULL;
}

static uint16_t read_u16_le(const uint8_t* p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_u32_le(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

typedef struct FixedDestination {
  struct jpeg_destination_mgr pub;
  size_t size;
} FixedDestination;

static void destination_init(j_compress_ptr cinfo) {
  FixedDestination* dest = (FixedDestination*)cinfo->dest;
  dest->pub.next_output_byte = output_buf;
  dest->pub.free_in_buffer = OUTPUT_CAP;
  dest->size = 0;
}

static boolean destination_full(j_compress_ptr cinfo) {
  ERREXIT(cinfo, JERR_BUFFER_SIZE);
  return FALSE;
}

static void destination_term(j_compress_ptr cinfo) {
  FixedDestination* dest = (FixedDestination*)cinfo->dest;
  dest->size = OUTPUT_CAP - dest->pub.free_in_buffer;
}

static void qip_error_exit(j_common_ptr cinfo) {
  (void)cinfo;
  __builtin_trap();
}

static void qip_output_message(j_common_ptr cinfo) { (void)cinfo; }
static void qip_emit_message(j_common_ptr cinfo, int level) {
  if (level < 0) ++cinfo->err->num_warnings;
}
static void qip_format_message(j_common_ptr cinfo, char* buffer) {
  (void)cinfo;
  buffer[0] = 0;
}
static void qip_reset_error(j_common_ptr cinfo) {
  cinfo->err->num_warnings = 0;
  cinfo->err->msg_code = 0;
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

#ifdef QIP_JPEG_INPUT_KTX2_SRGB8_EITHER
static const char input_content_type[] = "image/ktx2";
#else
static const char input_content_type[] = "image/bmp";
#endif
static const char output_content_type[] = "image/jpeg";
uint32_t input_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)input_content_type;
}
uint32_t input_content_type_size(void) { return sizeof(input_content_type) - 1; }
uint32_t output_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)output_content_type;
}
uint32_t output_content_type_size(void) { return sizeof(output_content_type) - 1; }

uint32_t uniform_set_quality(uint32_t value) {
  quality = value > 100 ? 100 : value;
  if (quality == 0) quality = 1;
  return quality;
}
uint32_t uniform_set_subsample(uint32_t value) {
  subsample = value > 2 ? 2 : value;
  return subsample;
}
uint32_t uniform_set_background_color_rgb(uint32_t value) {
  background_color_rgb = value & 0xffffffu;
  return background_color_rgb;
}

uint32_t arena_peak_bytes(void) { return (uint32_t)arena_peak; }
uint32_t arena_live_bytes(void) { return (uint32_t)arena_used; }
uint32_t arena_allocation_count(void) { return (uint32_t)arena_alloc_count; }
uint32_t arena_largest_allocation(void) { return (uint32_t)arena_largest; }
uint32_t arena_failed_allocation(void) { return (uint32_t)arena_failed_size; }
uint32_t arena_free_count(void) { return (uint32_t)arena_free_count_value; }
uint32_t arena_free_unmatched_count(void) {
  return (uint32_t)arena_free_unmatched_count_value;
}

uint64_t render(uint32_t input_size_value) {
  size_t input_size = input_size_value;
#ifndef QIP_JPEG_INPUT_KTX2_SRGB8_EITHER
  uint32_t pixel_offset, dib_size, width_bits, height_bits, compression;
  uint32_t file_size;
  int32_t height_signed;
  int has_explicit_alpha = 0;
#else
  QipKtx2Rgba8Image ktx_image;
  int has_explicit_alpha = 1;
#endif
  uint32_t height, stride, y;
  int32_t width;
  const uint8_t* pixels;
  int source_is_rgba = 0;
  struct jpeg_compress_struct cinfo;
  struct jpeg_error_mgr errors;
  FixedDestination destination;

  arena_reset();
#ifdef QIP_JPEG_INPUT_KTX2_SRGB8_EITHER
  if (input_size > INPUT_CAP ||
      !qip_ktx2_srgb8_parse(input_buf, input_size, &ktx_image)) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  width = (int32_t)ktx_image.width;
  height = ktx_image.height;
  stride = (uint32_t)width * 4u;
  pixels = ktx_image.pixels;
  source_is_rgba = ktx_image.is_rgba;
#else
  if (input_size > INPUT_CAP || input_size < 54 || input_buf[0] != 'B' ||
      input_buf[1] != 'M')
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  file_size = read_u32_le(input_buf + 2);
  pixel_offset = read_u32_le(input_buf + 10);
  dib_size = read_u32_le(input_buf + 14);
  width_bits = read_u32_le(input_buf + 18);
  height_bits = read_u32_le(input_buf + 22);
  compression = read_u32_le(input_buf + 30);
  width = (int32_t)width_bits;
  height_signed = (int32_t)height_bits;
  if (file_size != input_size || dib_size < 40 || pixel_offset < 14u + dib_size ||
      read_u16_le(input_buf + 26) != 1 || read_u16_le(input_buf + 28) != 32 ||
      width <= 0 || (uint32_t)width > MAX_DIMENSION || height_signed == 0 ||
      height_signed == INT32_MIN)
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  if (compression == 3) {
    if (dib_size < 124 || pixel_offset < 138 ||
        read_u32_le(input_buf + 54) != 0x00ff0000u ||
        read_u32_le(input_buf + 58) != 0x0000ff00u ||
        read_u32_le(input_buf + 62) != 0x000000ffu ||
        read_u32_le(input_buf + 66) != 0xff000000u)
      return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    has_explicit_alpha = 1;
  } else if (compression != 0) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  } else if (dib_size >= 124 && pixel_offset >= 138 &&
             read_u32_le(input_buf + 66) != 0) {
    uint32_t red = read_u32_le(input_buf + 54);
    uint32_t green = read_u32_le(input_buf + 58);
    uint32_t blue = read_u32_le(input_buf + 62);
    if (read_u32_le(input_buf + 66) != 0xff000000u ||
        !((red == 0 && green == 0 && blue == 0) ||
          (red == 0x00ff0000u && green == 0x0000ff00u &&
           blue == 0x000000ffu)))
      return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    has_explicit_alpha = 1;
  }
  height = (uint32_t)(height_signed < 0 ? -height_signed : height_signed);
  if (height > MAX_DIMENSION || (uint64_t)(uint32_t)width * height > MAX_PIXELS)
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  stride = (uint32_t)width * 4u;
  if (pixel_offset > input_size || (size_t)stride * height > input_size - pixel_offset)
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  pixels = input_buf + pixel_offset;
#endif

  memset(&errors, 0, sizeof(errors));
  cinfo.err = &errors;
  errors.error_exit = qip_error_exit;
  errors.emit_message = qip_emit_message;
  errors.output_message = qip_output_message;
  errors.format_message = qip_format_message;
  errors.reset_error_mgr = qip_reset_error;
  jpeg_create_compress(&cinfo);
  destination.pub.init_destination = destination_init;
  destination.pub.empty_output_buffer = destination_full;
  destination.pub.term_destination = destination_term;
  cinfo.dest = &destination.pub;
  cinfo.image_width = (JDIMENSION)width;
  cinfo.image_height = (JDIMENSION)height;
  cinfo.input_components = 3;
  cinfo.in_color_space = JCS_RGB;
  jpeg_set_defaults(&cinfo);
  jpeg_set_quality(&cinfo, (int)quality, TRUE);
  // MozJPEG defaults to progressive output. QIP's current JPEG decoder is a
  // deliberately baseline decoder, so retain trellis quantization and
  // optimized Huffman coding while emitting one sequential scan.
  cinfo.scan_info = NULL;
  cinfo.num_scans = 0;
  cinfo.optimize_coding = TRUE;
  jpeg_c_set_bool_param(&cinfo, JBOOLEAN_OPTIMIZE_SCANS, FALSE);
  cinfo.comp_info[0].h_samp_factor = subsample == 0 ? 1 : 2;
  cinfo.comp_info[0].v_samp_factor = subsample == 2 ? 2 : 1;
  cinfo.comp_info[1].h_samp_factor = 1;
  cinfo.comp_info[1].v_samp_factor = 1;
  cinfo.comp_info[2].h_samp_factor = 1;
  cinfo.comp_info[2].v_samp_factor = 1;
  cinfo.mem->max_memory_to_use = 0;
  jpeg_start_compress(&cinfo, TRUE);

  for (y = 0; y < height; ++y) {
#ifdef QIP_JPEG_INPUT_KTX2_SRGB8_EITHER
    uint32_t source_y = y;
#else
    uint32_t source_y = height_signed > 0 ? height - 1u - y : y;
#endif
    const uint8_t* source = pixels + (size_t)source_y * stride;
    uint32_t x;
    JSAMPROW row = row_buf;
    for (x = 0; x < (uint32_t)width; ++x) {
      uint32_t blue = source[(size_t)x * 4u + (source_is_rgba ? 2u : 0u)];
      uint32_t green = source[(size_t)x * 4u + 1u];
      uint32_t red = source[(size_t)x * 4u + (source_is_rgba ? 0u : 2u)];
      if (has_explicit_alpha) {
        uint32_t alpha = source[(size_t)x * 4u + 3u];
        uint32_t inverse = 255u - alpha;
        blue = (blue * alpha + (background_color_rgb & 0xffu) * inverse + 127u) / 255u;
        green = (green * alpha + ((background_color_rgb >> 8) & 0xffu) * inverse + 127u) / 255u;
        red = (red * alpha + ((background_color_rgb >> 16) & 0xffu) * inverse + 127u) / 255u;
      }
      row_buf[(size_t)x * 3u + 0u] = (uint8_t)red;
      row_buf[(size_t)x * 3u + 1u] = (uint8_t)green;
      row_buf[(size_t)x * 3u + 2u] = (uint8_t)blue;
    }
    if (jpeg_write_scanlines(&cinfo, &row, 1) != 1) __builtin_trap();
  }
  jpeg_finish_compress(&cinfo);
  jpeg_destroy_compress(&cinfo);
  if (destination.size > UINT32_MAX || arena_used != 0 ||
      arena_free_unmatched_count_value != 0)
    __builtin_trap();
  return ((uint64_t)output_ptr() << 32) | (uint32_t)((uint32_t)destination.size);
}
