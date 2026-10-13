// Swaps the byte order of every 32-bit word, such as big-endian network or
// file-format integers into little-endian ones.
@group(0) @binding(0) var<storage, read_write> words: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let w = words[id.x];
  words[id.x] = (w >> 24u) | ((w >> 8u) & 0xff00u) | ((w << 8u) & 0xff0000u) | (w << 24u);
}
