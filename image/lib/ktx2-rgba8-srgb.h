#ifndef QIP_KTX2_RGBA8_SRGB_H
#define QIP_KTX2_RGBA8_SRGB_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define QIP_KTX2_RGBA8_HEADER_SIZE 224u
#define QIP_KTX2_RGBA8_MAX_PIXELS 25000000u
#define QIP_KTX2_RGBA8_MAX_DIMENSION 8192u
#define QIP_KTX2_RGBA8_MAX_FILE_SIZE \
  (QIP_KTX2_RGBA8_HEADER_SIZE + QIP_KTX2_RGBA8_MAX_PIXELS * 4u)

typedef struct {
  uint32_t width;
  uint32_t height;
  size_t pixel_bytes;
  uint8_t* pixels;
  int is_rgba;
} QipKtx2Rgba8Image;

static const uint8_t qip_ktx2_identifier[12] = {
    0xab, 'K', 'T', 'X', ' ', '2', '0', 0xbb, 0x0d, 0x0a, 0x1a, 0x0a,
};

static const uint8_t qip_ktx2_rgba8_dfd[92] = {
    0x5c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x58, 0x00, 0x01, 0x01, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x07, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x07, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x07, 0x1f,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
};

static const uint8_t qip_ktx2_bgra8_dfd[92] = {
    0x5c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x58, 0x00, 0x01, 0x01, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x07, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x07, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x07, 0x1f,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0x00, 0x00,
};

static const uint8_t qip_ktx2_rgba8_kvd[24] = {
    0x12, 0x00, 0x00, 0x00,
    'K',  'T',  'X',  'o',
    'r',  'i',  'e',  'n',
    't',  'a',  't',  'i',
    'o',  'n',  0x00, 'r',
    'd',  0x00, 0x00, 0x00,
};

static uint32_t qip_ktx2_read_u32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t qip_ktx2_read_u64(const uint8_t* p) {
  return (uint64_t)qip_ktx2_read_u32(p) |
         ((uint64_t)qip_ktx2_read_u32(p + 4) << 32);
}

static void qip_ktx2_write_u32(uint8_t* p, uint32_t value) {
  p[0] = (uint8_t)value;
  p[1] = (uint8_t)(value >> 8);
  p[2] = (uint8_t)(value >> 16);
  p[3] = (uint8_t)(value >> 24);
}

static void qip_ktx2_write_u64(uint8_t* p, uint64_t value) {
  qip_ktx2_write_u32(p, (uint32_t)value);
  qip_ktx2_write_u32(p + 4, (uint32_t)(value >> 32));
}

static int qip_ktx2_rgba8_dimensions(uint32_t width, uint32_t height,
                                     size_t* pixel_bytes) {
  const uint64_t count = (uint64_t)width * height;
  if (width == 0 || height == 0 || width > QIP_KTX2_RGBA8_MAX_DIMENSION ||
      height > QIP_KTX2_RGBA8_MAX_DIMENSION ||
      count > QIP_KTX2_RGBA8_MAX_PIXELS) {
    return 0;
  }
  *pixel_bytes = (size_t)count * 4u;
  return 1;
}

static int qip_ktx2_srgb8_parse(uint8_t* data, size_t size,
                                QipKtx2Rgba8Image* image) {
  uint32_t width;
  uint32_t height;
  uint32_t vk_format;
  const uint8_t* expected_dfd;
  size_t pixel_bytes;
  if (size < QIP_KTX2_RGBA8_HEADER_SIZE ||
      memcmp(data, qip_ktx2_identifier, sizeof(qip_ktx2_identifier)) != 0 ||
      qip_ktx2_read_u32(data + 16) != 1) {
    return 0;
  }
  vk_format = qip_ktx2_read_u32(data + 12);
  if (vk_format == 43) {
    expected_dfd = qip_ktx2_rgba8_dfd;
    image->is_rgba = 1;
  } else if (vk_format == 50) {
    expected_dfd = qip_ktx2_bgra8_dfd;
    image->is_rgba = 0;
  } else {
    return 0;
  }
  width = qip_ktx2_read_u32(data + 20);
  height = qip_ktx2_read_u32(data + 24);
  if (!qip_ktx2_rgba8_dimensions(width, height, &pixel_bytes) ||
      size != QIP_KTX2_RGBA8_HEADER_SIZE + pixel_bytes ||
      qip_ktx2_read_u32(data + 28) != 0 ||
      qip_ktx2_read_u32(data + 32) != 0 ||
      qip_ktx2_read_u32(data + 36) != 1 ||
      qip_ktx2_read_u32(data + 40) != 1 ||
      qip_ktx2_read_u32(data + 44) != 0 ||
      qip_ktx2_read_u32(data + 48) != 104 ||
      qip_ktx2_read_u32(data + 52) != sizeof(qip_ktx2_rgba8_dfd) ||
      qip_ktx2_read_u32(data + 56) != 196 ||
      qip_ktx2_read_u32(data + 60) != sizeof(qip_ktx2_rgba8_kvd) ||
      qip_ktx2_read_u64(data + 64) != 0 ||
      qip_ktx2_read_u64(data + 72) != 0 ||
      qip_ktx2_read_u64(data + 80) != QIP_KTX2_RGBA8_HEADER_SIZE ||
      qip_ktx2_read_u64(data + 88) != pixel_bytes ||
      qip_ktx2_read_u64(data + 96) != pixel_bytes ||
      memcmp(data + 104, expected_dfd,
             sizeof(qip_ktx2_rgba8_dfd)) != 0 ||
      memcmp(data + 196, qip_ktx2_rgba8_kvd,
             sizeof(qip_ktx2_rgba8_kvd)) != 0) {
    return 0;
  }
  image->width = width;
  image->height = height;
  image->pixel_bytes = pixel_bytes;
  image->pixels = data + QIP_KTX2_RGBA8_HEADER_SIZE;
  return 1;
}

static int qip_ktx2_rgba8_parse(uint8_t* data, size_t size,
                                QipKtx2Rgba8Image* image) {
  return qip_ktx2_srgb8_parse(data, size, image) && image->is_rgba;
}

static size_t qip_ktx2_rgba8_write_header(uint8_t* output, size_t capacity,
                                          uint32_t width, uint32_t height) {
  size_t pixel_bytes;
  size_t size;
  if (!qip_ktx2_rgba8_dimensions(width, height, &pixel_bytes)) return 0;
  size = QIP_KTX2_RGBA8_HEADER_SIZE + pixel_bytes;
  if (capacity < size) return 0;
  memset(output, 0, QIP_KTX2_RGBA8_HEADER_SIZE);
  memcpy(output, qip_ktx2_identifier, sizeof(qip_ktx2_identifier));
  qip_ktx2_write_u32(output + 12, 43);
  qip_ktx2_write_u32(output + 16, 1);
  qip_ktx2_write_u32(output + 20, width);
  qip_ktx2_write_u32(output + 24, height);
  qip_ktx2_write_u32(output + 36, 1);
  qip_ktx2_write_u32(output + 40, 1);
  qip_ktx2_write_u32(output + 48, 104);
  qip_ktx2_write_u32(output + 52, sizeof(qip_ktx2_rgba8_dfd));
  qip_ktx2_write_u32(output + 56, 196);
  qip_ktx2_write_u32(output + 60, sizeof(qip_ktx2_rgba8_kvd));
  qip_ktx2_write_u64(output + 80, QIP_KTX2_RGBA8_HEADER_SIZE);
  qip_ktx2_write_u64(output + 88, pixel_bytes);
  qip_ktx2_write_u64(output + 96, pixel_bytes);
  memcpy(output + 104, qip_ktx2_rgba8_dfd, sizeof(qip_ktx2_rgba8_dfd));
  memcpy(output + 196, qip_ktx2_rgba8_kvd, sizeof(qip_ktx2_rgba8_kvd));
  return size;
}

#endif
