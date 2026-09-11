#include <limits.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <avif/avif.h>

#if defined(QIP_AVIF_INPUT_KTX2_SRGB8_EITHER) || defined(QIP_AVIF_DECODE_TO_KTX2)
#include "../lib/ktx2-rgba8-srgb.h"
#endif

#ifdef QIP_AVIF_DECODE_TO_KTX2
#define MAX_PIXELS 25000000u
#else
#define MAX_PIXELS 12000000u
#endif
#define MAX_DIMENSION 8192u
#define BMP_HEADER_CAP (64u * 1024u)
#ifdef QIP_AVIF_DECODE_TO_KTX2
#define INPUT_CAP (64u * 1024u * 1024u)
#define OUTPUT_CAP QIP_KTX2_RGBA8_MAX_FILE_SIZE
#elif defined(QIP_AVIF_INPUT_KTX2_SRGB8_EITHER)
#define INPUT_CAP (MAX_PIXELS * 4u + QIP_KTX2_RGBA8_HEADER_SIZE)
#define OUTPUT_CAP (64u * 1024u * 1024u)
#else
#define INPUT_CAP (MAX_PIXELS * 4u + BMP_HEADER_CAP)
#define OUTPUT_CAP (64u * 1024u * 1024u)
#endif
#define ARENA_CAP (768u * 1024u * 1024u)
#define ROW_CAP (4u * MAX_DIMENSION)

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));
static uint8_t row_scratch[ROW_CAP] __attribute__((aligned(16)));

static size_t arena_used;
static size_t arena_peak;
static size_t arena_alloc_count_value;
static size_t arena_largest;
static size_t arena_failed_size;
static size_t arena_free_count_value;
static size_t arena_free_matched_count_value;
static size_t arena_free_unmatched_count_value;

static uint32_t quality = 70;
static uint32_t quality_alpha = 100;
static uint32_t speed = 8;
static uint32_t subsample = 0;

typedef struct ArenaBlock {
  uint32_t size;
  uint32_t next;
  uint32_t prev;
  uint32_t is_free;
} ArenaBlock;

#define NO_BLOCK UINT32_MAX

static void arena_reset(void) {
  ArenaBlock* const first = (ArenaBlock*)(void*)arena;
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

// AV1 encoder failures are fatal to this request. QIP reports the failure by
// trapping, so the codec does not need Emscripten's stack-unwinding runtime.
int setjmp(jmp_buf env) {
  (void)env;
  return 0;
}

void longjmp(jmp_buf env, int value) {
  (void)env;
  (void)value;
  __builtin_trap();
}

void _emscripten_throw_longjmp(void) { __builtin_trap(); }

// The selected codec sources contain optional diagnostics and file-based
// helpers. They are not reachable from this memory-only encoder, but the C
// compiler still retains their references in some AOM translation units. Keep
// those references freestanding instead of importing WASI stdio.
void* stderr;
void* __wrap_fopen(const char* filename, const char* mode) {
  (void)filename;
  (void)mode;
  return NULL;
}
int __wrap_fclose(void* stream) {
  (void)stream;
  return -1;
}
size_t __wrap_fread(void* ptr, size_t size, size_t count, void* stream) {
  (void)ptr;
  (void)size;
  (void)count;
  (void)stream;
  return 0;
}
size_t __wrap_fwrite(const void* ptr, size_t size, size_t count, void* stream) {
  (void)ptr;
  (void)size;
  (void)count;
  (void)stream;
  return 0;
}
int __wrap_fseek(void* stream, long offset, int origin) {
  (void)stream;
  (void)offset;
  (void)origin;
  return -1;
}
int __wrap_feof(void* stream) {
  (void)stream;
  return 1;
}
int __wrap_fputc(int value, void* stream) {
  (void)value;
  (void)stream;
  return -1;
}
int __wrap_fscanf(void* stream, const char* format, ...) {
  (void)stream;
  (void)format;
  return -1;
}
int __wrap_fiprintf(void* stream, const char* format, ...) {
  (void)stream;
  (void)format;
  return 0;
}
int __wrap___small_fprintf(void* stream, const char* format, ...) {
  (void)stream;
  (void)format;
  return 0;
}

// libavif only uses the clock for default metadata. Set fixed timestamps so
// repeated renders are deterministic and do not import a host clock.
time_t time(time_t* value) {
  if (value != NULL) *value = (time_t)1;
  return (time_t)1;
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

#ifdef QIP_AVIF_DECODE_TO_KTX2
static const char input_content_type[] = "image/avif";
static const char output_content_type[] = "image/ktx2";
#elif defined(QIP_AVIF_INPUT_KTX2_SRGB8_EITHER)
static const char input_content_type[] = "image/ktx2";
static const char output_content_type[] = "image/avif";
#else
static const char input_content_type[] = "image/bmp";
static const char output_content_type[] = "image/avif";
#endif

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

uint32_t uniform_set_quality_alpha(uint32_t value) {
  quality_alpha = value > 100 ? 100 : value;
  return quality_alpha;
}

uint32_t uniform_set_speed(uint32_t value) {
  speed = value > 10 ? 10 : value;
  return speed;
}

uint32_t uniform_set_subsample(uint32_t value) {
  subsample = value > 2 ? 2 : value;
  return subsample;
}

uint32_t arena_peak_bytes(void) { return (uint32_t)arena_peak; }
uint32_t arena_allocation_count(void) {
  return (uint32_t)arena_alloc_count_value;
}
uint32_t arena_largest_allocation(void) { return (uint32_t)arena_largest; }
uint32_t arena_failed_allocation(void) { return (uint32_t)arena_failed_size; }
uint32_t arena_free_count(void) { return (uint32_t)arena_free_count_value; }
uint32_t arena_free_matched_count(void) {
  return (uint32_t)arena_free_matched_count_value;
}
uint32_t arena_free_unmatched_count(void) {
  return (uint32_t)arena_free_unmatched_count_value;
}

static uint16_t read_u16_le(const uint8_t* p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_u32_le(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static avifPixelFormat pixel_format(void) {
  switch (subsample) {
    case 1:
      return AVIF_PIXEL_FORMAT_YUV422;
    case 2:
      return AVIF_PIXEL_FORMAT_YUV444;
    default:
      return AVIF_PIXEL_FORMAT_YUV420;
  }
}

static int has_transparency(const uint8_t* pixels, size_t pixel_bytes) {
  size_t i;
  for (i = 3; i < pixel_bytes; i += 4) {
    if (pixels[i] != 255) return 1;
  }
  return 0;
}

#ifdef QIP_AVIF_DECODE_TO_KTX2
uint64_t render(uint32_t input_size_value) {
  size_t input_size = input_size_value;
  avifDecoder* decoder = NULL;
  avifRGBImage rgb;
  avifResult result;
  size_t output_size = 0;

  arena_reset();
  if (input_size == 0 || input_size > INPUT_CAP) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  decoder = avifDecoderCreate();
  if (decoder == NULL) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  decoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
  decoder->maxThreads = 1;
  decoder->allowProgressive = AVIF_FALSE;
  decoder->allowIncremental = AVIF_FALSE;
  decoder->ignoreExif = AVIF_TRUE;
  decoder->ignoreXMP = AVIF_TRUE;
  decoder->imageSizeLimit = MAX_PIXELS;
  decoder->imageDimensionLimit = MAX_DIMENSION;
  decoder->imageCountLimit = 1;
  result = avifDecoderSetIOMemory(decoder, input_buf, input_size);
  if (result != AVIF_RESULT_OK) goto cleanup_decoder;
  result = avifDecoderParse(decoder);
  if (result != AVIF_RESULT_OK || decoder->imageCount != 1 ||
      decoder->image == NULL || decoder->image->width == 0 ||
      decoder->image->height == 0 || decoder->image->width > MAX_DIMENSION ||
      decoder->image->height > MAX_DIMENSION ||
      (uint64_t)decoder->image->width * decoder->image->height > MAX_PIXELS) {
    goto cleanup_decoder;
  }
  result = avifDecoderNextImage(decoder);
  if (result != AVIF_RESULT_OK) goto cleanup_decoder;
  // This component promises an sRGB KTX2 DFD. Do not silently relabel
  // explicitly wide-gamut, HDR, or ICC-managed samples as sRGB. Unspecified
  // CICP remains accepted under the component's documented sRGB assumption.
  if (decoder->image->icc.size != 0 ||
      (decoder->image->colorPrimaries != AVIF_COLOR_PRIMARIES_UNKNOWN &&
       decoder->image->colorPrimaries != AVIF_COLOR_PRIMARIES_UNSPECIFIED &&
       decoder->image->colorPrimaries != AVIF_COLOR_PRIMARIES_BT709) ||
      (decoder->image->transferCharacteristics !=
           AVIF_TRANSFER_CHARACTERISTICS_UNKNOWN &&
       decoder->image->transferCharacteristics !=
           AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED &&
       decoder->image->transferCharacteristics !=
           AVIF_TRANSFER_CHARACTERISTICS_SRGB)) {
    result = AVIF_RESULT_NOT_IMPLEMENTED;
    goto cleanup_decoder;
  }
  output_size = qip_ktx2_rgba8_write_header(
      output_buf, OUTPUT_CAP, decoder->image->width, decoder->image->height);
  if (output_size == 0) goto cleanup_decoder;
  avifRGBImageSetDefaults(&rgb, decoder->image);
  rgb.depth = 8;
  rgb.format = AVIF_RGB_FORMAT_RGBA;
  rgb.pixels = output_buf + QIP_KTX2_RGBA8_HEADER_SIZE;
  rgb.rowBytes = decoder->image->width * 4u;
  rgb.chromaUpsampling = AVIF_CHROMA_UPSAMPLING_BEST_QUALITY;
  result = avifImageYUVToRGB(decoder->image, &rgb);

cleanup_decoder:
  avifDecoderDestroy(decoder);
  if (result != AVIF_RESULT_OK || output_size > OUTPUT_CAP) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  return ((uint64_t)output_ptr() << 32) | (uint32_t)((uint32_t)output_size);
}
#else
uint64_t render(uint32_t input_size_value) {
  size_t input_size = input_size_value;
#ifndef QIP_AVIF_INPUT_KTX2_SRGB8_EITHER
  uint32_t pixel_offset;
  uint32_t dib_size;
  uint32_t width_u;
  uint32_t height_bits;
  uint32_t compression;
  int32_t height_signed;
  uint32_t y;
#else
  QipKtx2Rgba8Image ktx_image;
#endif
  int32_t width;
  uint32_t height;
  size_t pixel_bytes;
  size_t row_bytes;
  uint8_t* pixels;
  int transparent;
  avifImage* image = NULL;
  avifEncoder* encoder = NULL;
  avifRWData encoded = AVIF_DATA_EMPTY;
  avifRGBImage rgb;
  avifResult result = AVIF_RESULT_UNKNOWN_ERROR;
  size_t output_size = 0;

  arena_reset();
  if (input_size > INPUT_CAP) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
#ifdef QIP_AVIF_INPUT_KTX2_SRGB8_EITHER
  if (!qip_ktx2_srgb8_parse(input_buf, input_size, &ktx_image) ||
      ktx_image.width > MAX_DIMENSION || ktx_image.height > MAX_DIMENSION ||
      (uint64_t)ktx_image.width * ktx_image.height > MAX_PIXELS) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  width = (int32_t)ktx_image.width;
  height = ktx_image.height;
  pixel_bytes = ktx_image.pixel_bytes;
  row_bytes = (size_t)width * 4u;
  pixels = ktx_image.pixels;
#else
  if (input_size < 54 || input_buf[0] != 'B' || input_buf[1] != 'M') return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  pixel_offset = read_u32_le(input_buf + 10);
  dib_size = read_u32_le(input_buf + 14);
  width_u = read_u32_le(input_buf + 18);
  height_bits = read_u32_le(input_buf + 22);
  compression = read_u32_le(input_buf + 30);
  width = (int32_t)width_u;
  height_signed = (int32_t)height_bits;
  if (dib_size < 40 || pixel_offset < 14u + dib_size ||
      read_u16_le(input_buf + 26) != 1 ||
      read_u16_le(input_buf + 28) != 32 || width <= 0 ||
      (uint32_t)width > MAX_DIMENSION || height_signed == 0 ||
      height_signed == INT32_MIN) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  if (compression != 0 &&
      (compression != 3 || dib_size < 124 || pixel_offset < 138 ||
       read_u32_le(input_buf + 54) != 0x00ff0000u ||
       read_u32_le(input_buf + 58) != 0x0000ff00u ||
       read_u32_le(input_buf + 62) != 0x000000ffu ||
       read_u32_le(input_buf + 66) != 0xff000000u)) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  height = (uint32_t)(height_signed < 0 ? -height_signed : height_signed);
  if (height > MAX_DIMENSION ||
      (uint64_t)(uint32_t)width * height > MAX_PIXELS ||
      (size_t)width > SIZE_MAX / 4u / height) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }
  row_bytes = (size_t)width * 4u;
  pixel_bytes = row_bytes * height;
  if (pixel_offset > input_size || pixel_bytes > input_size - pixel_offset) {
    return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  }

  // The input is disposable. Move pixels to an aligned base and normalize
  // bottom-up BMP storage in place for libavif's BGRA reader.
  memmove(input_buf, input_buf + pixel_offset, pixel_bytes);
  if (height_signed > 0) {
    for (y = 0; y < height / 2u; ++y) {
      uint8_t* const top = input_buf + (size_t)y * row_bytes;
      uint8_t* const bottom =
          input_buf + (size_t)(height - 1u - y) * row_bytes;
      memcpy(row_scratch, top, row_bytes);
      memcpy(top, bottom, row_bytes);
      memcpy(bottom, row_scratch, row_bytes);
    }
  }
  pixels = input_buf;
#endif

  transparent = has_transparency(pixels, pixel_bytes);

  image = avifImageCreate(width, height, 8, pixel_format());
  if (image == NULL) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  // Both accepted input profiles contain BT.709-primary sRGB samples. Record
  // that interpretation explicitly instead of emitting unspecified CICP.
  // libavif's RGB-to-YUV path uses BT.601 matrix coefficients for ordinary
  // 8-bit RGB when no wider-gamut matrix is requested.
  image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
  image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
  image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;
  avifRGBImageSetDefaults(&rgb, image);
#ifdef QIP_AVIF_INPUT_KTX2_SRGB8_EITHER
  rgb.format = ktx_image.is_rgba ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_BGRA;
#else
  rgb.format = AVIF_RGB_FORMAT_BGRA;
#endif
  rgb.pixels = pixels;
  rgb.rowBytes = (uint32_t)row_bytes;
  rgb.ignoreAlpha = transparent ? AVIF_FALSE : AVIF_TRUE;
  rgb.chromaDownsampling = AVIF_CHROMA_DOWNSAMPLING_BEST_QUALITY;
  result = avifImageRGBToYUV(image, &rgb);
  if (result != AVIF_RESULT_OK) goto cleanup;

  encoder = avifEncoderCreate();
  if (encoder == NULL) goto cleanup;
  encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
  encoder->maxThreads = 1;
  encoder->speed = (int)speed;
  encoder->quality = (int)quality;
  encoder->qualityAlpha = (int)quality_alpha;
  encoder->creationTime = 1;
  encoder->modificationTime = 1;
  result = avifEncoderWrite(encoder, image, &encoded);
  if (result != AVIF_RESULT_OK || encoded.size > OUTPUT_CAP) goto cleanup;
  output_size = encoded.size;
  memcpy(output_buf, encoded.data, encoded.size);

cleanup:
  avifRWDataFree(&encoded);
  if (encoder != NULL) avifEncoderDestroy(encoder);
  if (image != NULL) avifImageDestroy(image);
  if (result != AVIF_RESULT_OK || output_size > OUTPUT_CAP) return ((uint64_t)output_ptr() << 32) | (uint32_t)(0);
  return ((uint64_t)output_ptr() << 32) | (uint32_t)((uint32_t)output_size);
}
#endif
