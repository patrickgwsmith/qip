#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "jpeglib.h"

#include "../lib/ktx2-rgba8-srgb.h"

#define INPUT_CAP (64u * 1024u * 1024u)
#define OUTPUT_CAP QIP_KTX2_RGBA8_MAX_FILE_SIZE
/* Progressive JPEG retains one coefficient array for the full image.  The
 * 336 MiB arena covers 25 MP 4:4:4 images, as it does for MozJPEG's trellis
 * encoder. */
#define ARENA_CAP (336u * 1024u * 1024u)
#define NO_BLOCK UINT32_MAX

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

static void arena_reset(void) {
  ArenaBlock* first = (ArenaBlock*)(void*)arena;
  arena_used = 0;
  first->size = ARENA_CAP - (uint32_t)sizeof(ArenaBlock);
  first->next = NO_BLOCK;
  first->prev = NO_BLOCK;
  first->is_free = 1;
}

static uint32_t align16(size_t size) {
  if (size == 0) size = 1;
  if (size > UINT32_MAX - 15u) return 0;
  return ((uint32_t)size + 15u) & ~15u;
}

static void split_block(uint32_t offset, ArenaBlock* block, uint32_t wanted) {
  if (block->size >= wanted + sizeof(ArenaBlock) + 16u) {
    uint32_t next_offset = offset + (uint32_t)sizeof(ArenaBlock) + wanted;
    ArenaBlock* next = (ArenaBlock*)(void*)(arena + next_offset);
    next->size = block->size - wanted - (uint32_t)sizeof(ArenaBlock);
    next->next = block->next;
    next->prev = offset;
    next->is_free = 1;
    if (block->next != NO_BLOCK)
      ((ArenaBlock*)(void*)(arena + block->next))->prev = next_offset;
    block->next = next_offset;
    block->size = wanted;
  }
}

void* malloc(size_t size) {
  uint32_t wanted = align16(size);
  uint32_t offset = 0;
  ArenaBlock* block;
  if (wanted == 0) return NULL;
  while (offset != NO_BLOCK) {
    block = (ArenaBlock*)(void*)(arena + offset);
    if (block->is_free && block->size >= wanted) break;
    offset = block->next;
  }
  if (offset == NO_BLOCK) return NULL;
  split_block(offset, block, wanted);
  block->is_free = 0;
  arena_used += block->size;
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

static ArenaBlock* block_for_pointer(void* ptr) {
  uintptr_t address;
  uintptr_t base;
  ArenaBlock* block;
  if (ptr == NULL) return NULL;
  address = (uintptr_t)ptr;
  base = (uintptr_t)arena;
  if (address < base + sizeof(ArenaBlock) || address >= base + ARENA_CAP)
    return NULL;
  block = (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
  return block->is_free ? NULL : block;
}

void free(void* ptr) {
  ArenaBlock* block;
  if (ptr == NULL) return;
  block = block_for_pointer(ptr);
  if (block == NULL) return;
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
  block = block_for_pointer(ptr);
  if (block == NULL) return NULL;
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
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/jpeg";
static const char output_content_type[] = "image/ktx2";
uint32_t input_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)input_content_type;
}
uint32_t input_content_type_size(void) { return sizeof(input_content_type) - 1; }
uint32_t output_content_type_ptr(void) {
  return (uint32_t)(uintptr_t)output_content_type;
}
uint32_t output_content_type_size(void) { return sizeof(output_content_type) - 1; }

static uint16_t read_u16_be(const uint8_t* bytes) {
  return ((uint16_t)bytes[0] << 8) | bytes[1];
}

/* Keep unsupported coding processes out of libjpeg's fatal error path. The
 * entropy parser remains libjpeg's responsibility once the header identifies
 * a supported Huffman, 8-bit sequential or progressive image. */
static int has_supported_frame_header(const uint8_t* bytes, size_t size) {
  size_t offset = 2;
  int saw_frame = 0;
  if (size < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return 0;
  while (offset < size) {
    uint8_t marker;
    uint16_t length;
    const uint8_t* segment;
    if (bytes[offset++] != 0xff) return 0;
    while (offset < size && bytes[offset] == 0xff) ++offset;
    if (offset >= size) return 0;
    marker = bytes[offset++];
    if (marker == 0xd9) return 0;
    if (marker == 0xda) return saw_frame;
    if (marker == 0x00 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7))
      return 0;
    if (offset + 2 > size) return 0;
    length = read_u16_be(bytes + offset);
    if (length < 2 || (size_t)length > size - offset) return 0;
    segment = bytes + offset + 2;
    if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 &&
        marker != 0xc8 && marker != 0xcc) {
      if (saw_frame || (marker != 0xc0 && marker != 0xc1 && marker != 0xc2) ||
          length < 8 || segment[0] != 8 || (segment[5] != 1 && segment[5] != 3) ||
          length != (uint16_t)(8u + 3u * segment[5]))
        return 0;
      saw_frame = 1;
    }
    offset += length;
  }
  return 0;
}

uint64_t render(uint32_t input_size_value) {
  struct jpeg_decompress_struct cinfo;
  struct jpeg_error_mgr errors;
  size_t output_size;
  uint32_t y;

  if (input_size_value > INPUT_CAP ||
      !has_supported_frame_header(input_buf, input_size_value))
    return (uint64_t)(uintptr_t)output_buf << 32;
  arena_reset();
  memset(&errors, 0, sizeof(errors));
  cinfo.err = &errors;
  errors.error_exit = qip_error_exit;
  errors.emit_message = qip_emit_message;
  errors.output_message = qip_output_message;
  errors.format_message = qip_format_message;
  errors.reset_error_mgr = qip_reset_error;
  jpeg_create_decompress(&cinfo);
  jpeg_mem_src(&cinfo, input_buf, input_size_value);
  if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK ||
      cinfo.image_width == 0 || cinfo.image_height == 0 ||
      cinfo.image_width > QIP_KTX2_RGBA8_MAX_DIMENSION ||
      cinfo.image_height > QIP_KTX2_RGBA8_MAX_DIMENSION ||
      (uint64_t)cinfo.image_width * cinfo.image_height > QIP_KTX2_RGBA8_MAX_PIXELS) {
    jpeg_destroy_decompress(&cinfo);
    return (uint64_t)(uintptr_t)output_buf << 32;
  }
  cinfo.out_color_space = JCS_EXT_RGBA;
  cinfo.do_fancy_upsampling = TRUE;
  cinfo.dct_method = JDCT_ISLOW;
  cinfo.mem->max_memory_to_use = 0;
  if (!jpeg_start_decompress(&cinfo) || cinfo.output_components != 4 ||
      cinfo.output_width != cinfo.image_width ||
      cinfo.output_height != cinfo.image_height) {
    jpeg_destroy_decompress(&cinfo);
    return (uint64_t)(uintptr_t)output_buf << 32;
  }
  output_size = qip_ktx2_rgba8_write_header(output_buf, OUTPUT_CAP,
                                             cinfo.output_width,
                                             cinfo.output_height);
  if (output_size == 0) {
    jpeg_destroy_decompress(&cinfo);
    return (uint64_t)(uintptr_t)output_buf << 32;
  }
  for (y = 0; y < cinfo.output_height; ++y) {
    JSAMPROW row = output_buf + QIP_KTX2_RGBA8_HEADER_SIZE +
        (size_t)y * cinfo.output_width * 4u;
    if (jpeg_read_scanlines(&cinfo, &row, 1) != 1) __builtin_trap();
  }
  if (!jpeg_finish_decompress(&cinfo)) __builtin_trap();
  jpeg_destroy_decompress(&cinfo);
  if (arena_used != 0) __builtin_trap();
  return ((uint64_t)(uintptr_t)output_buf << 32) | (uint32_t)output_size;
}
