// Quantizes f32 values in [0, 1] to `levels` steps, adding hashed noise first
// so smooth gradients turn into fine grain instead of visible bands. The noise
// is a PCG hash of each index and `seed`, so output is deterministic. Set
// amount=0 for plain rounding.
override levels: f32 = 4.0;
override amount: f32 = 1.0;
override seed: u32 = 0;

@group(0) @binding(0) var<storage, read_write> data: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let state = (id.x ^ (seed * 0x9e3779b9u)) * 747796405u + 2891336453u;
  let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
  let h = (word >> 22u) ^ word;
  // 24 random bits as a float in [-0.5, 0.5).
  let noise = f32(h >> 8u) / 16777216.0 - 0.5;
  let steps = levels - 1.0;
  let q = floor(data[id.x] * steps + 0.5 + noise * amount);
  data[id.x] = clamp(q, 0.0, steps) / steps;
}
