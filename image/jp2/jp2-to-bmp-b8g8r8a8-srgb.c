#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "openjpeg.h"

#define MAX_PIXELS 25000000u
#define MAX_DIMENSION 8192u
#define INPUT_CAP (64u * 1024u * 1024u)
#define BMP_HEADER_SIZE 54u
#define OUTPUT_CAP (MAX_PIXELS * 4u + BMP_HEADER_SIZE)
#define ARENA_CAP (384u * 1024u * 1024u)
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
static size_t arena_peak;
static size_t arena_alloc_count;
static size_t arena_largest;
static size_t arena_failed_size;
static size_t arena_free_count_value;
static size_t arena_free_unmatched_count_value;

static uint32_t align16(size_t size) {
  if (size == 0) size = 1;
  if (size > UINT32_MAX - 15u) return 0;
  return ((uint32_t)size + 15u) & ~15u;
}

static void split_block(uint32_t offset, ArenaBlock* block,
                        uint32_t wanted) {
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

void* malloc(size_t size) {
  uint32_t wanted = align16(size);
  uint32_t offset = 0;
  ArenaBlock* block;
  if (wanted == 0) {
    arena_failed_size = size;
    return NULL;
  }
  while (offset != NO_BLOCK) {
    block = (ArenaBlock*)(void*)(arena + offset);
    if (block->is_free && block->size >= wanted) break;
    offset = block->next;
  }
  if (offset == NO_BLOCK) {
    arena_failed_size = size;
    return NULL;
  }
  split_block(offset, block, wanted);
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

char* getenv(const char* name) {
  (void)name;
  return NULL;
}

static ArenaBlock* block_for_pointer(void* ptr) {
  uintptr_t address;
  uintptr_t arena_address;
  ArenaBlock* block;
  if (ptr == NULL) return NULL;
  address = (uintptr_t)ptr;
  arena_address = (uintptr_t)arena;
  if (address < arena_address + sizeof(ArenaBlock) ||
      address - arena_address >= ARENA_CAP) {
    return NULL;
  }
  block = (ArenaBlock*)(void*)((uint8_t*)ptr - sizeof(ArenaBlock));
  if (block->is_free) return NULL;
  return block;
}

void free(void* ptr) {
  ArenaBlock* block;
  if (ptr == NULL) return;
  ++arena_free_count_value;
  block = block_for_pointer(ptr);
  if (block == NULL) {
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

void* realloc(void* ptr, size_t size) {
  ArenaBlock* block;
  uint32_t wanted;
  uint32_t offset;
  uint32_t old_size;
  void* replacement;

  if (ptr == NULL) return malloc(size);
  if (size == 0) {
    free(ptr);
    return NULL;
  }
  block = block_for_pointer(ptr);
  if (block == NULL) {
    arena_failed_size = size;
    return NULL;
  }
  wanted = align16(size);
  if (wanted == 0) {
    arena_failed_size = size;
    return NULL;
  }
  offset = (uint32_t)((uint8_t*)block - arena);
  old_size = block->size;
  if (wanted <= old_size) {
    split_block(offset, block, wanted);
    arena_used -= old_size - block->size;
    return ptr;
  }
  if (block->next != NO_BLOCK) {
    ArenaBlock* next = (ArenaBlock*)(void*)(arena + block->next);
    uint64_t combined = (uint64_t)block->size + sizeof(ArenaBlock) + next->size;
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
  replacement = malloc(size);
  if (replacement == NULL) return NULL;
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

typedef struct MemoryStream {
  const uint8_t* data;
  size_t size;
  size_t offset;
} MemoryStream;

static OPJ_SIZE_T stream_read(void* buffer, OPJ_SIZE_T size,
                              void* user_data) {
  MemoryStream* stream = (MemoryStream*)user_data;
  size_t remaining;
  if (stream->offset >= stream->size) return (OPJ_SIZE_T)-1;
  remaining = stream->size - stream->offset;
  if (size > remaining) size = remaining;
  memcpy(buffer, stream->data + stream->offset, size);
  stream->offset += size;
  return size;
}

static OPJ_OFF_T stream_skip(OPJ_OFF_T amount, void* user_data) {
  MemoryStream* stream = (MemoryStream*)user_data;
  size_t remaining;
  if (amount < 0 || stream->offset >= stream->size) return (OPJ_OFF_T)-1;
  remaining = stream->size - stream->offset;
  if ((uint64_t)amount > remaining) amount = (OPJ_OFF_T)remaining;
  stream->offset += (size_t)amount;
  return amount;
}

static OPJ_BOOL stream_seek(OPJ_OFF_T offset, void* user_data) {
  MemoryStream* stream = (MemoryStream*)user_data;
  if (offset < 0 || (uint64_t)offset > stream->size) return OPJ_FALSE;
  stream->offset = (size_t)offset;
  return OPJ_TRUE;
}

static void quiet_message(const char* message, void* user_data) {
  (void)message;
  (void)user_data;
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

static uint8_t sample_to_u8(const opj_image_comp_t* comp, int32_t value) {
  int64_t adjusted = value;
  uint64_t maximum;
  if (comp->prec == 0 || comp->prec > 31) return 0;
  maximum = ((uint64_t)1u << comp->prec) - 1u;
  if (comp->sgnd) adjusted += (int64_t)((uint64_t)1u << (comp->prec - 1u));
  if (adjusted <= 0) return 0;
  if ((uint64_t)adjusted >= maximum) return 255;
  return (uint8_t)(((uint64_t)adjusted * 255u + maximum / 2u) / maximum);
}

static int32_t component_sample(const opj_image_comp_t* comp,
                                uint32_t x, uint32_t y,
                                uint32_t width, uint32_t height) {
  uint32_t sample_x = (uint32_t)(((uint64_t)x * comp->w) / width);
  uint32_t sample_y = (uint32_t)(((uint64_t)y * comp->h) / height);
  if (sample_x >= comp->w) sample_x = comp->w - 1u;
  if (sample_y >= comp->h) sample_y = comp->h - 1u;
  return comp->data[(size_t)sample_y * comp->w + sample_x];
}

static int component_valid(const opj_image_comp_t* comp) {
  return comp->data != NULL && comp->w != 0 && comp->h != 0 &&
         comp->prec != 0 && comp->prec <= 31;
}

static uint8_t clamp_scaled(double value, uint32_t precision) {
  double maximum = (double)(((uint64_t)1u << precision) - 1u);
  if (value <= 0.0) return 0;
  if (value >= maximum) return 255;
  return (uint8_t)(value * 255.0 / maximum + 0.5);
}

static int write_bmp_pixels(const opj_image_t* image,
                            uint32_t width, uint32_t height) {
  uint32_t color_indices[4];
  uint32_t color_count = 0;
  int32_t alpha_index = -1;
  uint32_t component_index;
  uint32_t x;
  uint32_t y;
  OPJ_COLOR_SPACE color_space = image->color_space;

  for (component_index = 0; component_index < image->numcomps;
       ++component_index) {
    const opj_image_comp_t* comp = &image->comps[component_index];
    if (!component_valid(comp)) return 0;
    if (comp->alpha != 0) {
      if (alpha_index >= 0) return 0;
      alpha_index = (int32_t)component_index;
    } else {
      if (color_count == 4) return 0;
      color_indices[color_count++] = component_index;
    }
  }

  if (color_space != OPJ_CLRSPC_SYCC && color_count == 3 &&
      image->comps[color_indices[0]].dx == image->comps[color_indices[0]].dy &&
      image->comps[color_indices[1]].dx != 1) {
    color_space = OPJ_CLRSPC_SYCC;
  } else if (color_count <= 1) {
    color_space = OPJ_CLRSPC_GRAY;
  }

  if (!((color_space == OPJ_CLRSPC_GRAY && color_count == 1) ||
        ((color_space == OPJ_CLRSPC_SRGB ||
          color_space == OPJ_CLRSPC_UNKNOWN ||
          color_space == OPJ_CLRSPC_UNSPECIFIED) && color_count == 3) ||
        ((color_space == OPJ_CLRSPC_SYCC ||
          color_space == OPJ_CLRSPC_EYCC) && color_count == 3) ||
        (color_space == OPJ_CLRSPC_CMYK && color_count == 4))) {
    return 0;
  }

  for (y = 0; y < height; ++y) {
    uint8_t* row = output_buf + BMP_HEADER_SIZE + (size_t)y * width * 4u;
    for (x = 0; x < width; ++x) {
      uint8_t r;
      uint8_t g;
      uint8_t b;
      uint8_t a = 255;

      if (color_space == OPJ_CLRSPC_GRAY) {
        const opj_image_comp_t* gray = &image->comps[color_indices[0]];
        r = g = b = sample_to_u8(
            gray, component_sample(gray, x, y, width, height));
      } else if (color_space == OPJ_CLRSPC_SYCC ||
                 color_space == OPJ_CLRSPC_EYCC) {
        const opj_image_comp_t* yc = &image->comps[color_indices[0]];
        const opj_image_comp_t* cbc = &image->comps[color_indices[1]];
        const opj_image_comp_t* crc = &image->comps[color_indices[2]];
        int32_t yv;
        int32_t cb;
        int32_t cr;
        double offset;
        double maximum;
        if (yc->prec != cbc->prec || yc->prec != crc->prec) return 0;
        yv = component_sample(yc, x, y, width, height);
        cb = component_sample(cbc, x, y, width, height);
        cr = component_sample(crc, x, y, width, height);
        offset = (double)((uint64_t)1u << (yc->prec - 1u));
        if (cbc->sgnd) {
          cb += (int32_t)offset;
        }
        if (crc->sgnd) {
          cr += (int32_t)offset;
        }
        cb -= (int32_t)offset;
        cr -= (int32_t)offset;
        maximum = (double)(((uint64_t)1u << yc->prec) - 1u);
        (void)maximum;
        r = clamp_scaled((double)yv + 1.402 * cr, yc->prec);
        g = clamp_scaled((double)yv - 0.344 * cb - 0.714 * cr, yc->prec);
        b = clamp_scaled((double)yv + 1.772 * cb, yc->prec);
      } else if (color_space == OPJ_CLRSPC_CMYK) {
        const opj_image_comp_t* cc = &image->comps[color_indices[0]];
        const opj_image_comp_t* mc = &image->comps[color_indices[1]];
        const opj_image_comp_t* yc = &image->comps[color_indices[2]];
        const opj_image_comp_t* kc = &image->comps[color_indices[3]];
        uint32_t c = sample_to_u8(cc, component_sample(cc, x, y, width, height));
        uint32_t m = sample_to_u8(mc, component_sample(mc, x, y, width, height));
        uint32_t yy = sample_to_u8(yc, component_sample(yc, x, y, width, height));
        uint32_t k = sample_to_u8(kc, component_sample(kc, x, y, width, height));
        r = (uint8_t)(((255u - c) * (255u - k) + 127u) / 255u);
        g = (uint8_t)(((255u - m) * (255u - k) + 127u) / 255u);
        b = (uint8_t)(((255u - yy) * (255u - k) + 127u) / 255u);
      } else {
        const opj_image_comp_t* rc = &image->comps[color_indices[0]];
        const opj_image_comp_t* gc = &image->comps[color_indices[1]];
        const opj_image_comp_t* bc = &image->comps[color_indices[2]];
        r = sample_to_u8(rc, component_sample(rc, x, y, width, height));
        g = sample_to_u8(gc, component_sample(gc, x, y, width, height));
        b = sample_to_u8(bc, component_sample(bc, x, y, width, height));
      }

      if (alpha_index >= 0) {
        const opj_image_comp_t* ac = &image->comps[(uint32_t)alpha_index];
        a = sample_to_u8(ac, component_sample(ac, x, y, width, height));
      }
      row[x * 4u + 0u] = b;
      row[x * 4u + 1u] = g;
      row[x * 4u + 2u] = r;
      row[x * 4u + 3u] = a;
    }
  }
  return 1;
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "image/jp2";
static const char output_content_type[] = "image/bmp";

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
  opj_dparameters_t parameters;
  opj_codec_t* codec = NULL;
  opj_stream_t* stream = NULL;
  opj_image_t* image = NULL;
  MemoryStream memory_stream;
  uint64_t pixel_count;
  uint32_t width;
  uint32_t height;
  uint32_t pixel_bytes;
  uint32_t output_size = 0;

  if (input_size_value > INPUT_CAP || input_size_value < 12u) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  if (!(input_buf[0] == 0 && input_buf[1] == 0 && input_buf[2] == 0 &&
        input_buf[3] == 12 && input_buf[4] == 'j' && input_buf[5] == 'P' &&
        input_buf[6] == ' ' && input_buf[7] == ' ' && input_buf[8] == 13 &&
        input_buf[9] == 10 && input_buf[10] == 0x87 && input_buf[11] == 10)) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }

  arena_reset();
  memory_stream.data = input_buf;
  memory_stream.size = input_size_value;
  memory_stream.offset = 0;

  opj_set_default_decoder_parameters(&parameters);
  codec = opj_create_decompress(OPJ_CODEC_JP2);
  if (codec == NULL) goto cleanup;
  opj_set_info_handler(codec, quiet_message, NULL);
  opj_set_warning_handler(codec, quiet_message, NULL);
  opj_set_error_handler(codec, quiet_message, NULL);
  if (!opj_setup_decoder(codec, &parameters)) goto cleanup;

  stream = opj_stream_create(64u * 1024u, OPJ_TRUE);
  if (stream == NULL) goto cleanup;
  opj_stream_set_user_data(stream, &memory_stream, NULL);
  opj_stream_set_user_data_length(stream, input_size_value);
  opj_stream_set_read_function(stream, stream_read);
  opj_stream_set_skip_function(stream, stream_skip);
  opj_stream_set_seek_function(stream, stream_seek);

  if (!opj_read_header(stream, codec, &image) || image == NULL) goto cleanup;
  if (image->x1 <= image->x0 || image->y1 <= image->y0) goto cleanup;
  width = image->x1 - image->x0;
  height = image->y1 - image->y0;
  if (width > MAX_DIMENSION || height > MAX_DIMENSION) goto cleanup;
  pixel_count = (uint64_t)width * height;
  if (pixel_count == 0 || pixel_count > MAX_PIXELS) goto cleanup;
  if (!opj_decode(codec, stream, image) || !opj_end_decompress(codec, stream)) {
    goto cleanup;
  }
  if (arena_failed_size != 0) goto cleanup;

  pixel_bytes = (uint32_t)(pixel_count * 4u);
  if (!write_bmp_pixels(image, width, height)) goto cleanup;
  output_size = BMP_HEADER_SIZE + pixel_bytes;
  memset(output_buf, 0, BMP_HEADER_SIZE);
  output_buf[0] = 'B';
  output_buf[1] = 'M';
  write_u32_le(output_buf + 2, output_size);
  write_u32_le(output_buf + 10, BMP_HEADER_SIZE);
  write_u32_le(output_buf + 14, 40);
  write_u32_le(output_buf + 18, width);
  write_u32_le(output_buf + 22, (uint32_t)(-(int32_t)height));
  write_u16_le(output_buf + 26, 1);
  write_u16_le(output_buf + 28, 32);
  write_u32_le(output_buf + 34, pixel_bytes);
  write_u32_le(output_buf + 38, 2835);
  write_u32_le(output_buf + 42, 2835);

cleanup:
  if (image != NULL) opj_image_destroy(image);
  if (stream != NULL) opj_stream_destroy(stream);
  if (codec != NULL) opj_destroy_codec(codec);
  if (arena_failed_size != 0 || arena_free_unmatched_count_value != 0) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  return ((uint64_t)output_ptr() << 32) | (uint32_t)(output_size);
}
