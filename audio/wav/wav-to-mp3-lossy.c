#include <limits.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lame.h"

#define INPUT_CAP (64u * 1024u * 1024u)
#define OUTPUT_CAP (64u * 1024u * 1024u)
#define ARENA_CAP (64u * 1024u * 1024u)
#define ENCODE_SAMPLES 1152u
#define ENCODE_MP3_CAP (8192u + (ENCODE_SAMPLES * 5u / 4u))

static uint8_t input_buf[INPUT_CAP] __attribute__((aligned(16)));
static uint8_t output_buf[OUTPUT_CAP] __attribute__((aligned(16)));
static uint8_t arena[ARENA_CAP] __attribute__((aligned(16)));
static uint8_t mp3_chunk[ENCODE_MP3_CAP] __attribute__((aligned(16)));

static uint32_t bitrate_kbps = 192;
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
  ArenaBlock* block = NULL;
  if (size == 0) size = 1;
  if (size > UINT32_MAX - 15u) return NULL;
  aligned = (size + 15u) & ~(size_t)15u;
  while (offset != NO_BLOCK) {
    block = (ArenaBlock*)(void*)(arena + offset);
    if (block->is_free && block->size >= aligned) break;
    offset = block->next;
  }
  if (offset == NO_BLOCK || block == NULL) {
    arena_failed_size = size;
    return NULL;
  }
  if (block->size >= aligned + sizeof(ArenaBlock) + 16u) {
    uint32_t split_offset =
        offset + (uint32_t)sizeof(ArenaBlock) + (uint32_t)aligned;
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

void exit(int status) {
  (void)status;
  __builtin_trap();
}

int __wrap_printf(const char* format, ...) {
  (void)format;
  return 0;
}

int __wrap_fprintf(FILE* stream, const char* format, ...) {
  (void)stream;
  (void)format;
  return 0;
}

int __wrap_vfprintf(FILE* stream, const char* format, va_list args) {
  (void)stream;
  (void)format;
  (void)args;
  return 0;
}

int __wrap_fflush(FILE* stream) {
  (void)stream;
  return 0;
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

int __wrap_fseek(FILE* stream, long offset, int whence) {
  (void)stream;
  (void)offset;
  (void)whence;
  return -1;
}

long __wrap_ftell(FILE* stream) {
  (void)stream;
  return -1;
}

int __wrap_fclose(FILE* stream) {
  (void)stream;
  return 0;
}

int __wrap_fd_write(int fd, const void* iovs, size_t iovs_len, size_t* nwritten) {
  (void)fd;
  (void)iovs;
  (void)iovs_len;
  if (nwritten != NULL) *nwritten = 0;
  return 0;
}

int __wrap_fd_close(int fd) {
  (void)fd;
  return 0;
}

int __wrap_fd_seek(int fd, long long offset, int whence, unsigned long long* newoffset) {
  (void)fd;
  (void)offset;
  (void)whence;
  if (newoffset != NULL) *newoffset = 0;
  return 0;
}

int __wrap___wasi_fd_write(int fd, const void* iovs, size_t iovs_len, size_t* nwritten) {
  (void)fd;
  (void)iovs;
  (void)iovs_len;
  if (nwritten != NULL) *nwritten = 0;
  return 0;
}

int __wrap___wasi_fd_close(int fd) {
  (void)fd;
  return 0;
}

int __wrap___wasi_fd_seek(int fd, long long offset, int whence, unsigned long long* newoffset) {
  (void)fd;
  (void)offset;
  (void)whence;
  if (newoffset != NULL) *newoffset = 0;
  return 0;
}

static uint16_t read_u16_le(const uint8_t* p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_u32_le(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static int tag_is(const uint8_t* p, const char* tag) {
  return p[0] == (uint8_t)tag[0] && p[1] == (uint8_t)tag[1] &&
         p[2] == (uint8_t)tag[2] && p[3] == (uint8_t)tag[3];
}

uint32_t input_ptr(void) { return (uint32_t)(uintptr_t)input_buf; }
uint32_t input_bytes_cap(void) { return INPUT_CAP; }
static uint32_t output_ptr(void) { return (uint32_t)(uintptr_t)output_buf; }
uint32_t output_bytes_cap(void) { return OUTPUT_CAP; }

static const char input_content_type[] = "audio/wav";
static const char output_content_type[] = "audio/mpeg";
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

uint32_t uniform_set_bitrate_kbps(uint32_t value) {
  if (value < 32) value = 32;
  if (value > 320) value = 320;
  bitrate_kbps = value;
  return bitrate_kbps;
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
  uint32_t offset = 12;
  uint16_t channels = 0;
  uint32_t sample_rate = 0;
  uint16_t bits_per_sample = 0;
  uint16_t block_align = 0;
  uint32_t data_offset = 0;
  uint32_t data_size = 0;
  uint32_t samples_per_channel;
  uint32_t sample_index = 0;
  uint32_t output_size = 0;
  lame_t lame;

  arena_reset();
  if (input_size < 44 || input_size > INPUT_CAP || !tag_is(input_buf, "RIFF") ||
      !tag_is(input_buf + 8, "WAVE"))
    return ((uint64_t)output_ptr() << 32) | 0u;

  while (offset + 8 <= input_size) {
    uint32_t chunk_size = read_u32_le(input_buf + offset + 4);
    uint32_t chunk_data = offset + 8;
    uint32_t next = chunk_data + chunk_size + (chunk_size & 1u);
    if (chunk_data > input_size || chunk_size > input_size - chunk_data ||
        next < chunk_data)
      return ((uint64_t)output_ptr() << 32) | 0u;
    if (tag_is(input_buf + offset, "fmt ")) {
      uint16_t format;
      if (chunk_size < 16) return ((uint64_t)output_ptr() << 32) | 0u;
      format = read_u16_le(input_buf + chunk_data);
      channels = read_u16_le(input_buf + chunk_data + 2);
      sample_rate = read_u32_le(input_buf + chunk_data + 4);
      block_align = read_u16_le(input_buf + chunk_data + 12);
      bits_per_sample = read_u16_le(input_buf + chunk_data + 14);
      if (format != 1 || (channels != 1 && channels != 2) ||
          sample_rate < 8000 || sample_rate > 48000 || bits_per_sample != 16 ||
          block_align != channels * 2u)
        return ((uint64_t)output_ptr() << 32) | 0u;
    } else if (tag_is(input_buf + offset, "data")) {
      data_offset = chunk_data;
      data_size = chunk_size;
    }
    offset = next;
  }
  if (channels == 0 || data_offset == 0 || data_size == 0 ||
      data_size % block_align != 0)
    return ((uint64_t)output_ptr() << 32) | 0u;

  samples_per_channel = data_size / block_align;
  lame = lame_init();
  if (lame == NULL) return ((uint64_t)output_ptr() << 32) | 0u;
  lame_set_num_channels(lame, channels);
  lame_set_in_samplerate(lame, (int)sample_rate);
  lame_set_brate(lame, (int)bitrate_kbps);
  lame_set_quality(lame, 2);
  lame_set_VBR(lame, vbr_off);
  lame_set_bWriteVbrTag(lame, 0);
  lame_set_write_id3tag_automatic(lame, 0);
  lame_set_errorf(lame, NULL);
  lame_set_debugf(lame, NULL);
  lame_set_msgf(lame, NULL);
  if (lame_init_params(lame) < 0) {
    lame_close(lame);
    return ((uint64_t)output_ptr() << 32) | 0u;
  }

  while (sample_index < samples_per_channel) {
    uint32_t todo = samples_per_channel - sample_index;
    const short int* pcm;
    int written;
    if (todo > ENCODE_SAMPLES) todo = ENCODE_SAMPLES;
    pcm = (const short int*)(const void*)(input_buf + data_offset +
                                          (size_t)sample_index * block_align);
    /* lame_encode_buffer_interleaved always reads two channels, even for mono. */
    if (channels == 2)
      written = lame_encode_buffer_interleaved(lame, (short int*)pcm, (int)todo,
                                               mp3_chunk, (int)ENCODE_MP3_CAP);
    else
      written = lame_encode_buffer(lame, pcm, pcm, (int)todo, mp3_chunk,
                                   (int)ENCODE_MP3_CAP);
    if (written < 0 || (uint32_t)written > OUTPUT_CAP - output_size) {
      lame_close(lame);
      return ((uint64_t)output_ptr() << 32) | 0u;
    }
    memcpy(output_buf + output_size, mp3_chunk, (size_t)written);
    output_size += (uint32_t)written;
    sample_index += todo;
  }

  {
    int written = lame_encode_flush(lame, mp3_chunk, (int)ENCODE_MP3_CAP);
    if (written < 0 || (uint32_t)written > OUTPUT_CAP - output_size) {
      lame_close(lame);
      return ((uint64_t)output_ptr() << 32) | 0u;
    }
    memcpy(output_buf + output_size, mp3_chunk, (size_t)written);
    output_size += (uint32_t)written;
  }

  lame_close(lame);
  if (arena_used != 0 || arena_free_unmatched_count_value != 0)
    __builtin_trap();
  return ((uint64_t)output_ptr() << 32) | output_size;
}
