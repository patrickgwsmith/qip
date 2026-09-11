#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "src/webp/encode.h"

#define MAX_PIXELS 25000000u
#define MAX_DIMENSION 8192u
#define BMP_HEADER_CAP (64u * 1024u)
#define INPUT_CAP (MAX_PIXELS * 4u + BMP_HEADER_CAP)
#define OUTPUT_CAP (64u * 1024u * 1024u)
#define ARENA_CAP (256u * 1024u * 1024u)
#define ROW_CAP (4u * MAX_DIMENSION)

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));
static uint8_t row_scratch[ROW_CAP] __attribute__((aligned(16)));

static size_t arena_used;
static size_t arena_peak;
static size_t arena_alloc_count;
static size_t arena_largest;
static size_t arena_failed_size;
static size_t arena_free_count_value;
static size_t arena_free_null_count_value;
static size_t arena_free_matched_count_value;
static size_t arena_free_unmatched_count_value;
static size_t arena_freed_bytes_value;
static uint32_t arena_event_serial;
static uint32_t arena_sizes[256];
static uint32_t arena_offsets[256];
static uint32_t arena_allocation_events[256];
static uint32_t arena_free_events[256];
static uint32_t quality = 95;
static uint32_t method = 4;
static uint32_t sharp_yuv = 1;
static uint32_t low_memory = 1;
static uint32_t background_color_rgb = 0xffffffu;

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
  ++arena_event_serial;
  if (arena_alloc_count < sizeof(arena_sizes) / sizeof(arena_sizes[0])) {
    arena_sizes[arena_alloc_count] = (uint32_t)size;
    arena_offsets[arena_alloc_count] = (uint32_t)((uint8_t*)result - arena);
    arena_allocation_events[arena_alloc_count] = arena_event_serial;
    arena_free_events[arena_alloc_count] = 0;
  }
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
  size_t i;
  uintptr_t address;
  uintptr_t arena_address;
  if (ptr == NULL) {
    ++arena_free_null_count_value;
    return;
  }
  ++arena_free_count_value;
  ++arena_event_serial;
  address = (uintptr_t)ptr;
  arena_address = (uintptr_t)arena;
  if (address >= arena_address + sizeof(ArenaBlock) &&
      address - arena_address < ARENA_CAP) {
    const uint32_t offset = (uint32_t)(address - arena_address);
    const size_t recorded = arena_alloc_count < 256 ? arena_alloc_count : 256;
    ArenaBlock* block = (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
    const uint32_t freed_size = block->size;
    if (!block->is_free) {
      block->is_free = 1;
      arena_used -= freed_size;
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
    for (i = recorded; i > 0; --i) {
      if (arena_offsets[i - 1] == offset && arena_free_events[i - 1] == 0) {
        ++arena_free_matched_count_value;
        arena_freed_bytes_value += arena_sizes[i - 1];
        arena_free_events[i - 1] = arena_event_serial;
        return;
      }
    }
  }
  ++arena_free_unmatched_count_value;
}

static void arena_reset(void) {
  arena_used = 0;
  arena_peak = 0;
  arena_alloc_count = 0;
  arena_largest = 0;
  arena_failed_size = 0;
  arena_free_count_value = 0;
  arena_free_null_count_value = 0;
  arena_free_matched_count_value = 0;
  arena_free_unmatched_count_value = 0;
  arena_freed_bytes_value = 0;
  arena_event_serial = 0;
  {
    ArenaBlock* const first = (ArenaBlock*)(void*)arena;
    first->size = ARENA_CAP - (uint32_t)sizeof(ArenaBlock);
    first->next = NO_BLOCK;
    first->prev = NO_BLOCK;
    first->is_free = 1;
  }
}

static uint16_t read_u16_le(const uint8_t* p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_u32_le(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

typedef struct {
  size_t size;
  int overflow;
} FixedWriter;

static int write_output(const uint8_t* data, size_t data_size,
                        const WebPPicture* picture) {
  FixedWriter* const writer = (FixedWriter*)picture->custom_ptr;
  if (data_size > OUTPUT_CAP - writer->size) {
    writer->overflow = 1;
    return 0;
  }
  memcpy(output_buf + writer->size, data, data_size);
  writer->size += data_size;
  return 1;
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/bmp";
static const char output_content_type[] = "image/webp";
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
  return quality;
}
uint32_t uniform_set_method(uint32_t value) {
  method = value > 6 ? 6 : value;
  return method;
}
uint32_t uniform_set_sharp_yuv(uint32_t value) {
  sharp_yuv = value != 0;
  return sharp_yuv;
}
uint32_t uniform_set_low_memory(uint32_t value) {
  low_memory = value != 0;
  return low_memory;
}

uint32_t uniform_set_background_color_rgb(uint32_t value) {
  background_color_rgb = value & 0xffffffu;
  return background_color_rgb;
}

uint32_t arena_peak_bytes(void) { return (uint32_t)arena_peak; }
uint32_t arena_allocation_count(void) { return (uint32_t)arena_alloc_count; }
uint32_t arena_largest_allocation(void) { return (uint32_t)arena_largest; }
uint32_t arena_failed_allocation(void) { return (uint32_t)arena_failed_size; }
uint32_t arena_free_count(void) { return (uint32_t)arena_free_count_value; }
uint32_t arena_free_null_count(void) {
  return (uint32_t)arena_free_null_count_value;
}
uint32_t arena_free_matched_count(void) {
  return (uint32_t)arena_free_matched_count_value;
}
uint32_t arena_free_unmatched_count(void) {
  return (uint32_t)arena_free_unmatched_count_value;
}
uint32_t arena_freed_bytes(void) { return (uint32_t)arena_freed_bytes_value; }
uint32_t arena_allocation_size(uint32_t index) {
  if (index >= arena_alloc_count || index >= 256) return 0;
  return arena_sizes[index];
}
uint32_t arena_allocation_event(uint32_t index) {
  if (index >= arena_alloc_count || index >= 256) return 0;
  return arena_allocation_events[index];
}
uint32_t arena_allocation_free_event(uint32_t index) {
  if (index >= arena_alloc_count || index >= 256) return 0;
  return arena_free_events[index];
}

uint64_t render(uint32_t input_size_value) {
  size_t input_size = input_size_value;
  uint32_t pixel_offset, dib_size, width_u, height_bits;
  uint32_t compression, bpp;
  int32_t width, height_signed;
  uint32_t height, src_stride;
  size_t source_bytes, pixel_bytes;
  uint32_t y;
  int has_explicit_alpha = 0;
  WebPConfig config;
  WebPPicture picture;
  FixedWriter writer = {0, 0};
  int ok;

  arena_reset();
  if (input_size > INPUT_CAP) input_size = INPUT_CAP;
  if (input_size < 54 || input_buf[0] != 'B' || input_buf[1] != 'M') return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  pixel_offset = read_u32_le(input_buf + 10);
  dib_size = read_u32_le(input_buf + 14);
  width_u = read_u32_le(input_buf + 18);
  height_bits = read_u32_le(input_buf + 22);
  width = (int32_t)width_u;
  height_signed = (int32_t)height_bits;
  bpp = read_u16_le(input_buf + 28);
  compression = read_u32_le(input_buf + 30);

  if (dib_size < 40 || pixel_offset < 14u + dib_size ||
      read_u16_le(input_buf + 26) != 1 ||
      width <= 0 || (uint32_t)width > MAX_DIMENSION || height_signed == 0 ||
      height_signed == INT32_MIN) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  if (bpp == 24) {
    if (compression != 0) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  } else if (bpp == 32) {
    if (compression == 3) {
      if (dib_size < 124 || pixel_offset < 138 ||
          read_u32_le(input_buf + 54) != 0x00ff0000u ||
          read_u32_le(input_buf + 58) != 0x0000ff00u ||
          read_u32_le(input_buf + 62) != 0x000000ffu ||
          read_u32_le(input_buf + 66) != 0xff000000u) {
        return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
      }
      has_explicit_alpha = 1;
    } else if (compression == 0) {
      if (dib_size >= 124 && pixel_offset >= 138 &&
          read_u32_le(input_buf + 66) != 0) {
        const uint32_t red = read_u32_le(input_buf + 54);
        const uint32_t green = read_u32_le(input_buf + 58);
        const uint32_t blue = read_u32_le(input_buf + 62);
        if (read_u32_le(input_buf + 66) != 0xff000000u ||
            !((red == 0 && green == 0 && blue == 0) ||
              (red == 0x00ff0000u && green == 0x0000ff00u &&
               blue == 0x000000ffu))) {
          return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
        }
        has_explicit_alpha = 1;
      }
    } else {
      return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
    }
  } else {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }

  height = (uint32_t)(height_signed < 0 ? -height_signed : height_signed);
  if (height > MAX_DIMENSION ||
      (uint64_t)(uint32_t)width * height > MAX_PIXELS) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  src_stride =
      (uint32_t)((((uint64_t)(uint32_t)width * bpp + 31u) / 32u) * 4u);
  source_bytes = (size_t)src_stride * height;
  pixel_bytes = (size_t)(uint32_t)width * 4u * height;
  if (pixel_offset > input_size || source_bytes > input_size - pixel_offset ||
      pixel_bytes > INPUT_CAP) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }

  memmove(input_buf, input_buf + pixel_offset, source_bytes);
  if (bpp == 24) {
    // Expand backwards so the disposable input buffer is also the 32-bit
    // staging buffer. This preserves unread BGR rows while removing padding.
    for (y = height; y > 0; --y) {
      const uint32_t row = y - 1u;
      uint8_t* const src = input_buf + (size_t)row * src_stride;
      uint8_t* const dst =
          input_buf + (size_t)row * (uint32_t)width * 4u;
      uint32_t x;
      for (x = (uint32_t)width; x > 0; --x) {
        const uint32_t column = x - 1u;
        const uint8_t blue = src[(size_t)column * 3u + 0u];
        const uint8_t green = src[(size_t)column * 3u + 1u];
        const uint8_t red = src[(size_t)column * 3u + 2u];
        dst[(size_t)column * 4u + 0u] = blue;
        dst[(size_t)column * 4u + 1u] = green;
        dst[(size_t)column * 4u + 2u] = red;
        dst[(size_t)column * 4u + 3u] = 255;
      }
    }
  } else {
    const uint8_t bg_r = (uint8_t)(background_color_rgb >> 16);
    const uint8_t bg_g = (uint8_t)(background_color_rgb >> 8);
    const uint8_t bg_b = (uint8_t)background_color_rgb;
    size_t offset;
    for (offset = 0; offset < pixel_bytes; offset += 4u) {
      uint8_t* const pixel = input_buf + offset;
      if (has_explicit_alpha) {
        const uint32_t alpha = pixel[3];
        const uint32_t inverse = 255u - alpha;
        pixel[0] =
            (uint8_t)((pixel[0] * alpha + bg_b * inverse + 127u) / 255u);
        pixel[1] =
            (uint8_t)((pixel[1] * alpha + bg_g * inverse + 127u) / 255u);
        pixel[2] =
            (uint8_t)((pixel[2] * alpha + bg_r * inverse + 127u) / 255u);
      }
      pixel[3] = 255;
    }
  }

  if (height_signed > 0) {
    const size_t row_bytes = (size_t)(uint32_t)width * 4u;
    for (y = 0; y < height / 2u; ++y) {
      uint8_t* const top = input_buf + (size_t)y * row_bytes;
      uint8_t* const bottom = input_buf + (size_t)(height - 1u - y) * row_bytes;
      memcpy(row_scratch, top, row_bytes);
      memcpy(top, bottom, row_bytes);
      memcpy(bottom, row_scratch, row_bytes);
    }
  }

  if (!WebPConfigInit(&config) || !WebPPictureInit(&picture)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  config.lossless = 0;
  config.quality = (float)quality;
  config.method = (int)method;
  config.thread_level = 0;
  config.use_sharp_yuv = (int)sharp_yuv;
  config.low_memory = (int)low_memory;

  picture.use_argb = 1;
  picture.width = width;
  picture.height = (int)height;
  picture.argb = (uint32_t*)(void*)input_buf;
  picture.argb_stride = width;
  picture.writer = write_output;
  picture.custom_ptr = &writer;

  if (!WebPValidateConfig(&config)) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  ok = WebPEncode(&config, &picture);
  WebPPictureFree(&picture);
  if (!ok || writer.overflow || writer.size > UINT32_MAX) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  return ((uint64_t)output_ptr() << 32) | (uint32_t)((uint32_t)writer.size);
}
