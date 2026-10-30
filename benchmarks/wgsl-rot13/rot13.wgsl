// ROT13 over ASCII letters, four bytes per u32 word. Other bytes pass through.
// Input length must be a multiple of 4; pad with zeros.
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;

// Maps one byte lane in place; `w` is the whole word.
// k is the byte's offset from 'a' after folding to lower case; it wraps for
// bytes below 'a', so k < 26 selects letters only.
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let i = id.x;
  if (i < arrayLength(&src)) {
    let w = src[i];
    let b0 = w & 0xffu;
    let b1 = (w >> 8u) & 0xffu;
    let b2 = (w >> 16u) & 0xffu;
    let b3 = w >> 24u;
    let k0 = (b0 | 0x20u) - 97u;
    let k1 = (b1 | 0x20u) - 97u;
    let k2 = (b2 | 0x20u) - 97u;
    let k3 = (b3 | 0x20u) - 97u;
    let d0 = select(0u, select(0xfffffff3u, 13u, k0 < 13u), k0 < 26u);
    let d1 = select(0u, select(0xfffffff3u, 13u, k1 < 13u), k1 < 26u);
    let d2 = select(0u, select(0xfffffff3u, 13u, k2 < 13u), k2 < 26u);
    let d3 = select(0u, select(0xfffffff3u, 13u, k3 < 13u), k3 < 26u);
    dst[i] = ((b0 + d0) & 0xffu) | (((b1 + d1) & 0xffu) << 8u)
      | (((b2 + d2) & 0xffu) << 16u) | ((b3 + d3) << 24u);
  }
}
