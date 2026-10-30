// ROT13 over ASCII letters, one byte per vec4u lane. Other bytes pass through.
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let i = id.x;
  if (i < arrayLength(&src)) {
    let b = unpack4xU8(src[i]);
    // Offset from 'a' after folding to lower case; it wraps below 'a'.
    let k = (b | vec4u(32u)) - vec4u(97u);
    let d = select(vec4u(0u), select(vec4u(243u), vec4u(13u), k < vec4u(13u)), k < vec4u(26u));
    dst[i] = pack4xU8(b + d);
  }
}
