#ifndef QIP_TEXT_FREESTANDING_STRING_H
#define QIP_TEXT_FREESTANDING_STRING_H

#include <stddef.h>

static inline void* memcpy(void* destination, const void* source, size_t count) {
  unsigned char* dst = (unsigned char*)destination;
  const unsigned char* src = (const unsigned char*)source;
  while (count--) *dst++ = *src++;
  return destination;
}

static inline void* memset(void* destination, int value, size_t count) {
  unsigned char* dst = (unsigned char*)destination;
  while (count--) *dst++ = (unsigned char)value;
  return destination;
}

static inline int memcmp(const void* left, const void* right, size_t count) {
  const unsigned char* lhs = (const unsigned char*)left;
  const unsigned char* rhs = (const unsigned char*)right;
  while (count--) {
    if (*lhs != *rhs) return *lhs < *rhs ? -1 : 1;
    lhs++;
    rhs++;
  }
  return 0;
}

#endif
