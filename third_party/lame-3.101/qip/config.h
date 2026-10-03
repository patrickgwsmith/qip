/* wasm32 configuration for the direct Clang build of libmp3lame used by
   audio/wav/wav-to-mp3-lossy.wasm. Replaces the autoconf-generated config.h. */
#ifndef QIP_LAME_CONFIG_H
#define QIP_LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1

/* wasm32 is little-endian with IEEE 754 binary32 and binary64 floats. */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

#endif
