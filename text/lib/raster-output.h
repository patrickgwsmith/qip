#ifndef QIP_TEXT_RASTER_OUTPUT_H
#define QIP_TEXT_RASTER_OUTPUT_H

#include <stddef.h>
#include <stdint.h>

#ifdef QIP_TEXT_OUTPUT_KTX2
#include "../../image/lib/ktx2-rgba8-srgb.h"
#define QIP_TEXT_RASTER_HEADER_SIZE QIP_KTX2_RGBA8_HEADER_SIZE
#define QIP_TEXT_RASTER_CONTENT_TYPE "image/ktx2"
#else
#define QIP_TEXT_RASTER_HEADER_SIZE 54u
#define QIP_TEXT_RASTER_CONTENT_TYPE "image/bmp"
#endif

static uint64_t qip_text_raster_init(uint8_t* output, size_t capacity,
                                     uint32_t width, uint32_t height) {
  const uint64_t pixels = (uint64_t)width * height * 4u;
  const uint64_t total = QIP_TEXT_RASTER_HEADER_SIZE + pixels;
  if (total > capacity) return 0;
#ifdef QIP_TEXT_OUTPUT_KTX2
  return qip_ktx2_rgba8_write_header(output, capacity, width, height);
#else
  output[0] = 'B';
  output[1] = 'M';
  output[2] = (uint8_t)total;
  output[3] = (uint8_t)(total >> 8);
  output[4] = (uint8_t)(total >> 16);
  output[5] = (uint8_t)(total >> 24);
  output[6] = output[7] = output[8] = output[9] = 0;
  output[10] = 54;
  output[11] = output[12] = output[13] = 0;
  output[14] = 40;
  output[15] = output[16] = output[17] = 0;
  output[18] = (uint8_t)width;
  output[19] = (uint8_t)(width >> 8);
  output[20] = (uint8_t)(width >> 16);
  output[21] = (uint8_t)(width >> 24);
  output[22] = (uint8_t)height;
  output[23] = (uint8_t)(height >> 8);
  output[24] = (uint8_t)(height >> 16);
  output[25] = (uint8_t)(height >> 24);
  output[26] = 1;
  output[27] = 0;
  output[28] = 32;
  output[29] = 0;
  output[30] = output[31] = output[32] = output[33] = 0;
  output[34] = (uint8_t)pixels;
  output[35] = (uint8_t)(pixels >> 8);
  output[36] = (uint8_t)(pixels >> 16);
  output[37] = (uint8_t)(pixels >> 24);
  output[38] = 0x13;
  output[39] = 0x0b;
  output[40] = output[41] = 0;
  output[42] = 0x13;
  output[43] = 0x0b;
  output[44] = output[45] = 0;
  output[46] = output[47] = output[48] = output[49] = 0;
  output[50] = output[51] = output[52] = output[53] = 0;
  return total;
#endif
}

static void qip_text_raster_set_pixel(uint8_t* output, uint32_t width,
                                      uint32_t height, uint32_t x, uint32_t y,
                                      uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  if (x >= width || y >= height) return;
#ifdef QIP_TEXT_OUTPUT_KTX2
  const size_t offset = QIP_TEXT_RASTER_HEADER_SIZE + ((size_t)y * width + x) * 4u;
  output[offset] = r;
  output[offset + 1] = g;
  output[offset + 2] = b;
#else
  const size_t offset = QIP_TEXT_RASTER_HEADER_SIZE + ((size_t)(height - 1 - y) * width + x) * 4u;
  output[offset] = b;
  output[offset + 1] = g;
  output[offset + 2] = r;
#endif
  output[offset + 3] = a;
}

static void qip_text_raster_fill(uint8_t* output, uint64_t total,
                                 uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  for (uint64_t offset = QIP_TEXT_RASTER_HEADER_SIZE; offset < total; offset += 4) {
#ifdef QIP_TEXT_OUTPUT_KTX2
    output[offset] = r;
    output[offset + 1] = g;
    output[offset + 2] = b;
#else
    output[offset] = b;
    output[offset + 1] = g;
    output[offset + 2] = r;
#endif
    output[offset + 3] = a;
  }
}

#endif
