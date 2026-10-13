fn pixel(c: vec4f) -> vec4f {
  return vec4f(1.0 - c.rgb, c.a);
}
