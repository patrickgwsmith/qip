// Mirrors a width-wide image of 16-byte pixels (RGBA32F) horizontally,
// vertically, or both.
override width: u32 = 256;
override horizontal: u32 = 1;
override vertical: u32 = 0;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let height = arrayLength(&src) / width;
  var x = id.x % width;
  var y = id.x / width;
  if horizontal != 0u { x = width - 1u - x; }
  if vertical != 0u { y = height - 1u - y; }
  dst[id.x] = src[y * width + x];
}
