# AVIF QIP build inputs

The BMP AVIF component vendors these upstream source archives. The source
trees are kept in the repository so rebuilding does not require a system AVIF
installation or network access.

| Source | Version | Archive SHA-256 | License files |
|---|---|---|---|
| libavif | 1.4.1 | `d4aea31a4becb3273ba7968221be2e48148ba05eb8a68d14e671963e17785648` | `third_party/libavif-1.4.1/LICENSE` |
| libaom | 3.13.0 | `513f104c8003ac3ac30c7f1a65dd3cfe516a35f15badcd1db3dde0cdfbd5ddf6` | `third_party/libaom-3.13.0/LICENSE`, `third_party/libaom-3.13.0/PATENTS` |

The archive hashes identify the upstream release archives used to populate
the vendored trees. The full license files remain alongside the source; AOM's
license also covers its patent grant and third-party notices.

The Makefile builds both libraries with Emscripten 2.0.34 and links them into
`image/bmp/bmp-b8g8r8a8-srgb-to-avif.wasm` using direct Clang/wasm-ld:

- libaom: `AOM_TARGET_CPU=generic`, encoder only, no decoder, multithreading,
  runtime CPU detection, WebM I/O, accounting, inspection, tests, examples,
  docs, or NASM
- libavif: static AOM encoder, no decoder, libyuv, SharpYUV, JPEG, PNG, apps,
  or tests
- both: `-O3`, LTO, `-msimd128`, `-mbulk-memory`, and QIP's local setjmp
  compatibility header
- link: no entry point, fixed 1 GiB initial and maximum memory, dead-code
  elimination, and no Emscripten JavaScript runtime

The adapter supplies QIP's fixed arena allocator and wraps the optional stdio
symbols retained by some codec translation units. Those wrappers intentionally
return failure: the content component only accepts memory buffers and has no
filesystem or WASI imports.
