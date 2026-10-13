// Interleaved stereo f32 samples (L, R, L, R, ...) to mid/side, or back again
// with the same shader: M = (L + R) * k, S = (L - R) * k. With k = 0.5 it
// encodes; run the result with k=1 to decode. Set width below 1 to narrow the
// stereo image and above 1 to widen it.
override k: f32 = 0.5;
override width: f32 = 1.0;

@group(0) @binding(0) var<storage, read> src: array<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let frame = id.x & ~1u;
  let a = src[frame];
  let b = src[frame + 1u];
  let first = (id.x & 1u) == 0u;
  dst[id.x] = select((a - b) * k * width, (a + b) * k, first);
}
