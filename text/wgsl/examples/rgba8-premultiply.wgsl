// Premultiplies alpha in raw RGBA8 pixels, read as little-endian u32s
// (byte 0 = R in the low bits, byte 3 = A in the high bits).
@group(0) @binding(0) var<storage, read_write> pixels: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let p = pixels[id.x];
  let a = p >> 24u;
  // x * a / 255, rounded, without a division: (t + 128 + ((t + 128) >> 8)) >> 8.
  var t = (p & 0xffu) * a + 128u;
  let r = (t + (t >> 8u)) >> 8u;
  t = ((p >> 8u) & 0xffu) * a + 128u;
  let g = (t + (t >> 8u)) >> 8u;
  t = ((p >> 16u) & 0xffu) * a + 128u;
  let b = (t + (t >> 8u)) >> 8u;
  pixels[id.x] = r | (g << 8u) | (b << 16u) | (a << 24u);
}
