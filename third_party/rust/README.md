# Vendored Rust packages

These Cargo packages are build inputs for QIP components. Builds use the local
paths and do not download package source.

| Package | Version | Cargo package SHA-256 | License | Upstream |
| --- | --- | --- | --- | --- |
| `wasmparser` | 0.252.0 | `d3eb099dcadcde5be9eef55e3a337128efd4e44b4c93122487e4d2e4e1c6627c` | Apache-2.0 with LLVM exception, Apache-2.0, or MIT | <https://github.com/bytecodealliance/wasm-tools/tree/main/crates/wasmparser> |
| `bitflags` | 2.13.0 | `b4388bee8683e3d04af747c73422af53102d2bd24d9eadb6cbc100baef4b43f8` | MIT or Apache-2.0 | <https://github.com/bitflags/bitflags/tree/2.13.0> |
| `jxl` | 0.7.4 | `43b041e4bd5bb931cf73b271bc3304eb135bb473914877d64bf77fdf5b4d4687` | BSD-3-Clause | <https://github.com/libjxl/jxl-rs> |
| `jxl_simd` | 0.7.4 | `ba1f65c01a3f807385be7a1200f78b9d958bff1321b753b859ecfcba63a0642d` | BSD-3-Clause | <https://github.com/libjxl/jxl-rs> |
| `jxl_transforms` | 0.7.4 | `8f72e196c6c1e938a4c7e2175d7c83464fa9e7f587224d310cac15d83fc80a37` | BSD-3-Clause | <https://github.com/libjxl/jxl-rs> |
| `jxl_macros` | 0.7.4 | `7401c9c53e44e2efa17d7562c613f0972b93cf134aa91f08c14e00c8278ce663` | BSD-3-Clause | <https://github.com/libjxl/jxl-rs> |
| `array-init` | 2.1.0 | `3d62b7694a562cdf5a74227903507c56ab2cc8bdd1f781ed5cb4cf9c9f810bfc` | MIT or Apache-2.0 | <https://github.com/Manishearth/array-init> |
| `byteorder` | 1.5.0 | `1fd0f2584146f6f2ef48085050886acf353beff7305ebd1ae69500e27c67f64b` | Unlicense or MIT | <https://github.com/BurntSushi/byteorder> |
| `num-derive` | 0.4.2 | `ed3955f1a9c7c0c15e092f9c887db08b1fc683305fdf6eb6684f22555355e202` | MIT or Apache-2.0 | <https://github.com/rust-num/num-derive> |
| `num-traits` | 0.2.19 | `071dfc062690e90b734c0b2273ce72ad0ffa95f0c74596bc250dcfd960262841` | MIT or Apache-2.0 | <https://github.com/rust-num/num-traits> |
| `thiserror` | 2.0.21 | `09e52cb86a36cede5cb101bf8908837b3e4c6e5e59fe7fd85c23fb56200d189e` | MIT or Apache-2.0 | <https://github.com/dtolnay/thiserror> |
| `thiserror-impl` | 2.0.21 | `fe5197923287db20a58125f0bc85c062f7f2c892de97b18c356f9efb14b28524` | MIT or Apache-2.0 | <https://github.com/dtolnay/thiserror> |
| `proc-macro2` | 1.0.107 | `985e7ec9bb745e6ce6535b544d84d6cd6f7ad8bd711c398938ae983b91a766d9` | MIT or Apache-2.0 | <https://github.com/dtolnay/proc-macro2> |
| `quote` | 1.0.47 | `1fbf4db142a473a8d80c26bbf18454ed458bf8d26c8219c331daecfdbd079001` | MIT or Apache-2.0 | <https://github.com/dtolnay/quote> |
| `syn` | 2.0.119 | `872831b642d1a07999a962a351ed35b955ea2cfc8f3862091e2a240a84f17297` | MIT or Apache-2.0 | <https://github.com/dtolnay/syn> |
| `syn` | 3.0.6 | `8593e8e72159ed2257d083c7a454a85cbf854f37a0966d8d483aff8c8a3ebcee` | MIT or Apache-2.0 | <https://github.com/dtolnay/syn> |
| `unicode-ident` | 1.0.26 | `d245f478577f809a851594d02313b640fb437e0bb33866753cff937863096954` | (MIT or Apache-2.0) and Unicode-3.0 | <https://github.com/dtolnay/unicode-ident> |
| `autocfg` | 1.5.1 | `f2032f911046de80f0a198e0901378627c33f59ea0ac00e363d481118bd70a53` | Apache-2.0 or MIT | <https://github.com/cuviper/autocfg> |

The package archives came from crates.io. Each package directory also contains
Cargo's per-file checksum manifest and the upstream license files.

`jxl-to-ktx2-r8g8b8a8-srgb.wasm` uses the `jxl` crate and the packages after
it in the table. `jxl_macros`, `num-derive`, `thiserror-impl`, `proc-macro2`,
`quote`, `syn` and `unicode-ident` are procedural-macro build dependencies
and are not linked into the component. `cargo vendor --versioned-dirs`
produced these directories with `jxl = { version = "=0.7.4",
default-features = false, features = ["simd128"] }`.
