// Brightness in [-1, 1]. Positive pushes toward white, negative toward black.
override brightness: f32 = 0.0;

fn pixel(c: vec4f) -> vec4f {
  let b = clamp(brightness, -1.0, 1.0);
  let rgb = select(c.rgb * (1.0 + b), c.rgb + (1.0 - c.rgb) * b, b >= 0.0);
  return vec4f(clamp(rgb, vec3f(0.0), vec3f(1.0)), c.a);
}
