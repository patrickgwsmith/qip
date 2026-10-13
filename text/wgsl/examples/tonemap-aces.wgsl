// HDR to display: exposure, then Krzysztof Narkowicz's ACES filmic fit, then
// clamped to [0, 1]. Linear RGBA32F in and out; alpha is kept.
override exposure: f32 = 1.0;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let c = src[id.x];
  let x = c.rgb * exposure;
  let mapped = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
  dst[id.x] = vec4f(clamp(mapped, vec3f(0.0), vec3f(1.0)), c.a);
}
