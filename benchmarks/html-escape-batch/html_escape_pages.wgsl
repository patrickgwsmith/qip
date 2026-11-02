// HTML-escape many pages at once: invocation id.x escapes page id.x.
// pages[p] = (in_off, in_len, out_off, out_len) in bytes; the host sets the
// first three, with out_off a multiple of 4 and room for 6 * in_len bytes.
// src and dst pack four bytes per u32, little-endian.
const CAP: u32 = 524288u;

@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@group(0) @binding(2) var<storage, read_write> pages: array<vec4u>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  if (id.x >= arrayLength(&pages)) { return; }
  let p = pages[id.x];
  var o = p.z;
  var word = 0u;
  for (var i = 0u; i < CAP; i++) {
    if (i >= p.y) { break; }
    let a = p.x + i;
    let b = (src[a >> 2u] >> ((a & 3u) * 8u)) & 0xffu;
    // Entity bytes as two little-endian words, and their length.
    var lo = b;
    var hi = 0u;
    var len = 1u;
    if (b == 38u) { lo = 0x706d6126u; hi = 0x3bu; len = 5u; }        // &amp;
    if (b == 60u) { lo = 0x3b746c26u; len = 4u; }                    // &lt;
    if (b == 62u) { lo = 0x3b746726u; len = 4u; }                    // &gt;
    if (b == 34u) { lo = 0x6f757126u; hi = 0x3b74u; len = 6u; }      // &quot;
    if (b == 39u) { lo = 0x39332326u; hi = 0x3bu; len = 5u; }        // &#39;
    for (var k = 0u; k < 6u; k++) {
      if (k >= len) { break; }
      let e = select(hi >> ((k - 4u) * 8u), lo >> (k * 8u), k < 4u) & 0xffu;
      word |= e << ((o & 3u) * 8u);
      o++;
      if ((o & 3u) == 0u) {
        dst[(o >> 2u) - 1u] = word;
        word = 0u;
      }
    }
  }
  if ((o & 3u) != 0u) { dst[o >> 2u] = word; }
  pages[id.x].w = o - p.z;
}
