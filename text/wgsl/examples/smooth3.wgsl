// Smooths a f32 signal with a 3-tap [1 2 1] / 4 kernel, repeating the edge
// samples. Pipe through it again for a wider blur.
@group(0) @binding(0) var<storage, read> src: array<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let i = id.x;
  let last = arrayLength(&src) - 1u;
  let prev = src[select(i - 1u, 0u, i == 0u)];
  let next = src[min(i + 1u, last)];
  dst[i] = (prev + 2.0 * src[i] + next) * 0.25;
}
