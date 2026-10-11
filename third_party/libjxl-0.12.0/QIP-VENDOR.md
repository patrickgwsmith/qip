# Vendored libjxl 0.12.0

Source: `https://github.com/libjxl/libjxl/archive/refs/tags/v0.12.0.tar.gz`

Source archive SHA-256:
`03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992`

This directory keeps the complete libjxl 0.12.0 source archive without
changes. The archive does not include its git submodules. The lossy encoder
adds these exact upstream submodule revisions without local changes:

| Dependency | Commit | License |
| --- | --- | --- |
| Brotli | `028fb5a23661f123017c060daa546b55cf4bde29` | MIT |
| Highway | `457c891775a7397bdb0376bb1031e6e027af1c48` | Apache 2.0 |
| skcms | `96d9171c94b937a1b5f0293de7309ac16311b722` | BSD 3-Clause |

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossless.wasm` compiles only fjxl,
`lib/jxl/enc_fast_lossless.cc`, with `FJXL_STANDALONE=1`. That file includes
the header-only `lib/jxl/base` utilities and needs no generated configuration
or other libjxl source. Its AVX2, AVX-512 and NEON paths are disabled on
wasm32, so the build uses fjxl's portable scalar implementation.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossy.wasm` builds the full libjxl
encoder with these three pinned dependencies. Its CMake configuration disables
tools, tests, boxes, JPEG transcoding, and Wasm threads. The build is offline
after the Emscripten 6.0.3 toolchain is installed.

The upstream `.gitignore` contains `/build*`. On a case-insensitive file
system, Git therefore also ignores `BUILD.bazel` and the `BUILDING*.md`
files. Add them with `git add -f` to keep the vendored tree complete. The
fjxl build does not use them.

See `LICENSE` and `PATENTS` for the upstream BSD 3-Clause terms and patent
grant.
