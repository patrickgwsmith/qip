# LAME 3.101

Vendored from the upstream LAME 3.101 source archive:

- URL: https://downloads.sourceforge.net/project/lame/lame/3.101/lame-3.101.tar.gz
- SHA-256: `7578af6eebd578b2bd64e468fac4ae1f03670a7e028166e67f855674b9b6aeac`
- License: LGPL, see `COPYING` and `LICENSE`.

The QIP build compiles only the `libmp3lame` encoder sources used by the
`audio/wav/wav-to-mp3-lossy.wasm` component. It does not build the command-line
frontend, decoder library, assembly routines, or vector extension objects.

`qip/config.h` is a small wasm32 configuration header for the direct Clang
build. It assumes little-endian wasm32, ISO C headers, no NASM routines, no
libmpg123 decoder, and no host filesystem.
