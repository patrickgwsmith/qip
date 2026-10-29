const DISPLAY_W = 720;
const DISPLAY_H = 480;
// Renders at 2x like gui/cover-flow.wasm, and is displayed at DISPLAY_W.
const SCALE = 2;
const RENDER_W = DISPLAY_W * SCALE;
const RENDER_H = DISPLAY_H * SCALE;
const COVER = 190 * SCALE;
const TEX_SIZE = 256;
const CENTER_X = RENDER_W / 2;
const FEATURE_LIGHTING = 1 << 2;
const FEATURE_SPRING = 1 << 3;
const MODULE_URL = import.meta.url;
const MODULE_BYTES_FALLBACK = 35572;

// Geometry after the 2006-era iTunes/iPod layout, matching gui/cover-flow.zig:
// one cover faces the viewer, and the rest stand in two tight stacks turned
// ~70 degrees towards the center, all at the same depth.
const COVER_CENTER_Y = 168 * SCALE;
const FOCAL = 780 * SCALE;
const SIDE_YAW = 1.22;
const SIDE_OFFSET = 165 * SCALE;
const SIDE_SPACING = 34 * SCALE;
const SIDE_DEPTH = 120 * SCALE;
const CENTER_SLIDE = 60 * SCALE;
const SIDE_DARKEN_MAX = 90;
// Each cover is mirrored in a black glossy floor. The mirror image starts
// REFLECTION_ALPHA/255 bright at the cover's bottom edge and fades linearly
// to black over REFLECTION_SPAN of the cover's height.
const REFLECTION_GAP = 2 * SCALE;
const REFLECTION_SPAN = 0.55;
const REFLECTION_ALPHA = 92;

// Text is set in Inter Display, the same font the Wasm component rasterizes.
const FONT_FAMILY = "Cover Flow Inter Display";
const TITLE_SIZE = 17 * SCALE;
const TITLE_BASELINE = 394 * SCALE;
const ARTIST_SIZE = 13 * SCALE;
const ARTIST_BASELINE = 416 * SCALE;
const FLAG_SIZE = 10 * SCALE;
const FLAG_BASELINE = 24 * SCALE;

// The iTunes-style scroll bar. Dragging the thumb scrubs through the covers,
// and pressing the track jumps the thumb to the pointer.
const SCROLL_TRACK_W = 300 * SCALE;
const SCROLL_TRACK_H = 12 * SCALE;
const SCROLL_TRACK_X = CENTER_X - SCROLL_TRACK_W / 2;
const SCROLL_TRACK_Y = 442 * SCALE;
// Presses this far above or below the track still grab it.
const SCROLL_HIT_SLOP = 8 * SCALE;

const albums = [
  { title: "Midnight Run", artist: "The Arcades", a: [0x13, 0x29, 0x5b, 0xff], b: [0xe7, 0x46, 0x8a, 0xff], c: [0x42, 0xdf, 0xe7, 0xff], motif: 0 },
  { title: "Glass Houses", artist: "North Pier", a: [0xd9, 0xe8, 0xf0, 0xff], b: [0x1e, 0x73, 0x8f, 0xff], c: [0x0f, 0x21, 0x2c, 0xff], motif: 1 },
  { title: "Low Sun", artist: "June Atlas", a: [0xf1, 0xb1, 0x49, 0xff], b: [0xd8, 0x42, 0x3b, 0xff], c: [0x39, 0x20, 0x45, 0xff], motif: 2 },
  { title: "Tape Echo", artist: "Mono Field", a: [0x21, 0x24, 0x26, 0xff], b: [0xdb, 0xd2, 0xb4, 0xff], c: [0x9b, 0xe2, 0x80, 0xff], motif: 3 },
  { title: "Ocean Static", artist: "The Signals", a: [0x04, 0x3b, 0x53, 0xff], b: [0x11, 0xa6, 0xc7, 0xff], c: [0xee, 0xf6, 0xff, 0xff], motif: 4 },
  { title: "Red Line", artist: "City Index", a: [0x24, 0x11, 0x16, 0xff], b: [0xb9, 0x1f, 0x36, 0xff], c: [0xf6, 0xe5, 0xb7, 0xff], motif: 5 },
  { title: "Soft Circuits", artist: "Ada View", a: [0x61, 0x78, 0x8a, 0xff], b: [0xe7, 0xe0, 0xc4, 0xff], c: [0x1c, 0x32, 0x45, 0xff], motif: 6 },
  { title: "Late Checkout", artist: "Hotel Mirror", a: [0x12, 0x16, 0x1c, 0xff], b: [0xc4, 0xa0, 0x5e, 0xff], c: [0x79, 0xd3, 0xff, 0xff], motif: 7 },
  { title: "Blueprints", artist: "Paper Tiger", a: [0xf8, 0xf6, 0xed, 0xff], b: [0x2d, 0x5d, 0x8f, 0xff], c: [0xe2, 0x51, 0x43, 0xff], motif: 8 },
  { title: "After Hours", artist: "Black Rain", a: [0x08, 0x08, 0x0d, 0xff], b: [0x5e, 0x44, 0x8f, 0xff], c: [0xf1, 0x5a, 0x7b, 0xff], motif: 9 },
];

const fontsReady = typeof FontFace === "undefined"
  ? Promise.resolve()
  : Promise.all([
    new FontFace(FONT_FAMILY, "url(/fonts/InterDisplay-Regular.ttf)", { weight: "400" }),
    new FontFace(FONT_FAMILY, "url(/fonts/InterDisplay-Bold.ttf)", { weight: "700" }),
  ].map((face) => face.load().then((loaded) => document.fonts.add(loaded))));

const quadVS = `#version 300 es
layout(location=0) in vec2 a_pos;
uniform vec4 u_rect;
out vec2 v_uv;
void main() {
  vec2 p = mix(u_rect.xy, u_rect.zw, a_pos);
  v_uv = a_pos;
  gl_Position = vec4((p.x / float(${RENDER_W})) * 2.0 - 1.0, 1.0 - (p.y / float(${RENDER_H})) * 2.0, 0.0, 1.0);
}`;

const textureFS = `#version 300 es
precision highp float;
precision highp int;
uniform sampler2D u_tex;
uniform float u_m[9];
uniform vec3 u_top;
uniform vec3 u_right;
uniform vec3 u_bottom;
uniform vec3 u_left;
uniform int u_reflection;
uniform int u_darken;
out vec4 out_color;

bool edgeInside(vec3 e, float x, float y) {
  return e.x * x + e.y * y + e.z >= 0.0;
}

int coverage4(float x, float y) {
  int covered = 0;
  for (int i = 0; i < 4; i++) {
    float ox = (i & 1) == 0 ? 0.25 : 0.75;
    float oy = (i & 2) == 0 ? 0.25 : 0.75;
    float sx = x + ox;
    float sy = y + oy;
    if (edgeInside(u_top, sx, sy) &&
        edgeInside(u_right, sx, sy) &&
        edgeInside(u_bottom, sx, sy) &&
        edgeInside(u_left, sx, sy)) {
      covered++;
    }
  }
  return covered;
}

vec3 texelRGB(int x, int y) {
  return texelFetch(u_tex, ivec2(x, y), 0).rgb * 255.0;
}

vec3 bilinear(float u, float v) {
  int x0 = clamp(int(floor(u)), 0, ${TEX_SIZE - 1});
  int y0 = clamp(int(floor(v)), 0, ${TEX_SIZE - 1});
  int x1 = min(x0 + 1, ${TEX_SIZE - 1});
  int y1 = min(y0 + 1, ${TEX_SIZE - 1});
  float tx = u - float(x0);
  float ty = v - float(y0);
  vec3 top = floor(texelRGB(x0, y0) + (texelRGB(x1, y0) - texelRGB(x0, y0)) * tx + 0.5);
  vec3 bottom = floor(texelRGB(x0, y1) + (texelRGB(x1, y1) - texelRGB(x0, y1)) * tx + 0.5);
  return floor(top + (bottom - top) * ty + 0.5);
}

vec3 shade(vec3 c, float u_mid, int darken) {
  int s = darken + int(abs(u_mid - 128.0)) / 11;
  float factor = float(clamp(255 - s, 0, 255));
  return floor(c * factor / 255.0);
}

void main() {
  float px = floor(gl_FragCoord.x);
  float py = floor(float(${RENDER_H}) - gl_FragCoord.y);
  int cov = coverage4(px, py);
  if (cov <= 0) discard;

  float x = px + 0.5;
  float y = py + 0.5;
  float d = u_m[6] * x + u_m[7] * y + u_m[8];
  if (abs(d) < 0.0001) discard;
  float u = (u_m[0] * x + u_m[1] * y + u_m[2]) / d;
  float v = (u_m[3] * x + u_m[4] * y + u_m[5]) / d;
  if (u < -0.002 || u > 1.002 || v < -0.002 || v > 1.002) discard;

  float uf = clamp(u, 0.0, 1.0) * 255.0;
  float vc = clamp(v, 0.0, 1.0);
  // A reflection quad's v runs from 0 at the cover's bottom edge to 1 where
  // the fade reaches black, so it samples the bottom of the cover, flipped.
  float vf = u_reflection != 0 ? 255.0 - vc * (255.0 * ${REFLECTION_SPAN}) : vc * 255.0;
  vec3 c = shade(bilinear(uf, vf), floor(uf + 0.5), u_darken);
  // Reflections fade towards black rather than transparent, so nearer ones
  // hide farther ones, as in the Wasm renderer.
  if (u_reflection != 0) c = floor(c * floor(float(${REFLECTION_ALPHA}) * (1.0 - vc) + 0.5) / 255.0);
  float alpha = cov == 4 ? 255.0 : float(cov * 63);
  out_color = vec4(c / 255.0, alpha / 255.0);
}`;

const imageFS = `#version 300 es
precision mediump float;
uniform sampler2D u_tex;
in vec2 v_uv;
out vec4 out_color;
void main() {
  out_color = texture(u_tex, v_uv);
}`;

// Horizontal capsule with a vertical top-to-bottom gradient and an
// antialiased edge.
const capsuleFS = `#version 300 es
precision highp float;
uniform vec4 u_box;
uniform vec3 u_top;
uniform vec3 u_bottom;
out vec4 out_color;
void main() {
  float px = floor(gl_FragCoord.x) + 0.5;
  float py = floor(float(${RENDER_H}) - gl_FragCoord.y) + 0.5;
  float r = u_box.w * 0.5;
  float cy = u_box.y + r;
  float left = u_box.x + r;
  float right = max(left, u_box.x + u_box.z - r);
  vec2 delta = vec2(px - clamp(px, left, right), py - cy);
  float coverage = clamp(r - length(delta) + 0.5, 0.0, 1.0);
  if (coverage <= 0.0) discard;
  vec3 c = floor(mix(u_top, u_bottom, (py - u_box.y) / u_box.w) + 0.5);
  out_color = vec4(c / 255.0, coverage);
}`;

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

function divTrunc(a, b) {
  return a < 0 ? Math.ceil(a / b) : Math.trunc(a / b);
}

function mod(a, b) {
  return ((a % b) + b) % b;
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function smoothstep(edge0, edge1, x) {
  const t = clamp((x - edge0) / (edge1 - edge0), 0, 1);
  return t * t * (3 - 2 * t);
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  return `${(bytes / 1024).toFixed(1)} KB`;
}

function moduleByteSize() {
  const entry = performance.getEntriesByName(MODULE_URL).at(-1);
  if (entry && entry.decodedBodySize > 0) return entry.decodedBodySize;
  return MODULE_BYTES_FALLBACK;
}

function rgba(r, g, b, a = 255) {
  return [clamp(r | 0, 0, 255), clamp(g | 0, 0, 255), clamp(b | 0, 0, 255), clamp(a | 0, 0, 255)];
}

function mixColor(a, b, t) {
  t = clamp(t, 0, 255);
  return rgba(
    a[0] + divTrunc((b[0] - a[0]) * t, 255),
    a[1] + divTrunc((b[1] - a[1]) * t, 255),
    a[2] + divTrunc((b[2] - a[2]) * t, 255),
    255,
  );
}

function addColor(c, delta) {
  return rgba(c[0] + delta, c[1] + delta, c[2] + delta, c[3]);
}

function shadeColor(c, darken) {
  const factor = clamp(255 - darken, 0, 255);
  return rgba(
    divTrunc(c[0] * factor, 255),
    divTrunc(c[1] * factor, 255),
    divTrunc(c[2] * factor, 255),
    c[3],
  );
}

function circle(u, v, cx, cy, r) {
  const dx = u - cx;
  const dy = v - cy;
  return dx * dx + dy * dy <= r * r;
}

function sampleAlbum(albumIndex, u, v) {
  const album = albums[albumIndex];
  let base = mixColor(album.a, album.b, clamp(divTrunc((u + v) * 255, 510), 0, 255));
  const grain = ((u * 17 + v * 29 + album.motif * 37) & 31) - 15;
  base = addColor(base, grain);

  switch (album.motif) {
    case 0:
      if (Math.abs(u - v) < 9 || Math.abs((255 - u) - v) < 8) base = mixColor(base, album.c, 180);
      if (circle(u, v, 128, 116, 42)) base = mixColor(base, [0x10, 0x10, 0x18, 0xff], 130);
      break;
    case 1:
      if (mod(divTrunc(u, 28), 2) === 0 || mod(divTrunc(v, 25), 2) === 0) base = mixColor(base, album.c, 78);
      if (Math.abs(u - 132) < 3) base = mixColor(base, [255, 255, 255, 255], 150);
      break;
    case 2:
      if (circle(u, v, 128, 132, 70)) base = mixColor(base, album.a, 170);
      if (v > 154 && ((u + v) & 18) < 7) base = mixColor(base, album.c, 92);
      break;
    case 3:
      if (circle(u, v, 128, 128, 72) && !circle(u, v, 128, 128, 32)) base = mixColor(base, album.c, 165);
      if (Math.abs(v - 128) < 4 || Math.abs(u - 128) < 4) base = mixColor(base, [0x12, 0x12, 0x12, 0xff], 160);
      break;
    case 4: {
      const wave = mod(u + divTrunc(v * v, 37), 42);
      if (wave < 12) base = mixColor(base, album.c, 130);
      if (v < 52) base = mixColor(base, [0x02, 0x18, 0x2a, 0xff], 120);
      break;
    }
    case 5:
      if (Math.abs(u - 128) < 18 || Math.abs(v - 128) < 18) base = mixColor(base, album.b, 160);
      if (Math.abs(u - v) < 5) base = mixColor(base, album.c, 180);
      break;
    case 6:
      if (mod(divTrunc(u, 32) + divTrunc(v, 32), 2) === 0) base = mixColor(base, album.b, 90);
      if (Math.abs(u - 64) < 4 || Math.abs(u - 192) < 4 || Math.abs(v - 64) < 4 || Math.abs(v - 192) < 4) base = mixColor(base, album.c, 150);
      break;
    case 7:
      if (u > 70 && u < 185 && v > 42 && v < 210) base = mixColor(base, album.b, 105);
      if (Math.abs(u - 128) + Math.abs(v - 126) < 62) base = mixColor(base, album.c, 125);
      break;
    case 8:
      if (mod(u + 2 * v, 47) < 4 || mod(2 * u + v, 53) < 4) base = mixColor(base, album.b, 150);
      if (u > 40 && u < 214 && v > 56 && v < 196 && ((u + v) & 16) === 0) base = mixColor(base, album.c, 80);
      break;
    default:
      if (circle(u, v, 92, 96, 44) || circle(u, v, 164, 160, 52)) base = mixColor(base, album.b, 170);
      if (Math.abs(u - 128) < 5) base = mixColor(base, album.c, 130);
      break;
  }

  if (u < 8 || u > 247 || v < 8 || v > 247) base = shadeColor(base, 58);
  return base;
}

function makeAlbumTextureBytes(albumIndex) {
  const bytes = new Uint8Array(TEX_SIZE * TEX_SIZE * 4);
  let p = 0;
  for (let v = 0; v < TEX_SIZE; v++) {
    for (let u = 0; u < TEX_SIZE; u++) {
      const c = sampleAlbum(albumIndex, u, v);
      bytes[p++] = c[0];
      bytes[p++] = c[1];
      bytes[p++] = c[2];
      bytes[p++] = c[3];
    }
  }
  return bytes;
}

function projectCoverCorner(localX, localY, xWorld, zWorld, cosY, sinY) {
  const rotatedX = localX * cosY;
  const rotatedZ = -localX * sinY;
  const z = zWorld + rotatedZ;
  const perspective = FOCAL / (FOCAL + z);
  return {
    x: Math.round(CENTER_X + (xWorld + rotatedX) * perspective),
    y: Math.round(COVER_CENTER_Y + localY * perspective),
  };
}

function coverPose(selectedQ8, index) {
  const rel = (index * 256 - selectedQ8) / 256;
  const ad = Math.abs(rel);
  const sign = rel < 0 ? -1 : 1;
  const turn = smoothstep(0.1, 0.9, ad);
  // Side covers turn to face the center, so their inner edges tuck behind
  // their neighbors and only the nearer, outer edges show.
  const yaw = sign * turn * SIDE_YAW;
  const cosY = Math.cos(yaw);
  const sinY = Math.sin(yaw);
  const sideX = sign * (SIDE_OFFSET + (ad - 1) * SIDE_SPACING);
  const xWorld = lerp(rel * CENTER_SLIDE, sideX, turn);
  const zWorld = turn * SIDE_DEPTH;
  const half = COVER * 0.5;
  // The reflection is the cover mirrored in the floor plane at its bottom
  // edge, trimmed to the part that is still visible before it fades out.
  const mirrorTop = half + REFLECTION_GAP;
  const mirrorBottom = mirrorTop + 2 * half * REFLECTION_SPAN;
  const corner = (x, y) => projectCoverCorner(x, y, xWorld, zWorld, cosY, sinY);
  return {
    q: { tl: corner(-half, -half), tr: corner(half, -half), br: corner(half, half), bl: corner(-half, half) },
    reflectionQ: { tl: corner(-half, mirrorTop), tr: corner(half, mirrorTop), br: corner(half, mirrorBottom), bl: corner(-half, mirrorBottom) },
    facing: clamp(cosY, 0, 1),
  };
}

function quadArea(q) {
  const p = [q.tl, q.tr, q.br, q.bl];
  let area = 0;
  for (let i = 0; i < 4; i++) {
    const a = p[i], b = p[(i + 1) & 3];
    area += a.x * b.y - a.y * b.x;
  }
  return area;
}

function makeEdge(a, b, sign) {
  const edgeX = b.x - a.x;
  const edgeY = b.y - a.y;
  return [-edgeY * sign, edgeX * sign, (edgeY * a.x - edgeX * a.y) * sign];
}

function makeEdges(q) {
  const sign = quadArea(q) >= 0 ? 1 : -1;
  return {
    top: makeEdge(q.tl, q.tr, sign),
    right: makeEdge(q.tr, q.br, sign),
    bottom: makeEdge(q.br, q.bl, sign),
    left: makeEdge(q.bl, q.tl, sign),
  };
}

function inverseHomography(q) {
  const x0 = q.tl.x, y0 = q.tl.y;
  const x1 = q.tr.x, y1 = q.tr.y;
  const x2 = q.br.x, y2 = q.br.y;
  const x3 = q.bl.x, y3 = q.bl.y;
  const dx1 = x1 - x2, dy1 = y1 - y2;
  const dx2 = x3 - x2, dy2 = y3 - y2;
  const dx3 = x0 - x1 + x2 - x3, dy3 = y0 - y1 + y2 - y3;
  let g = 0, h = 0;
  if (Math.abs(dx3) > 0.0001 || Math.abs(dy3) > 0.0001) {
    const det = dx1 * dy2 - dx2 * dy1;
    if (Math.abs(det) < 0.0001) return null;
    g = (dx3 * dy2 - dx2 * dy3) / det;
    h = (dx1 * dy3 - dx3 * dy1) / det;
  }
  return invertMatrix3([
    x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
    y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
    g, h, 1,
  ]);
}

function invertMatrix3(m) {
  const c00 = m[4] * m[8] - m[5] * m[7];
  const c01 = -(m[3] * m[8] - m[5] * m[6]);
  const c02 = m[3] * m[7] - m[4] * m[6];
  const c10 = -(m[1] * m[8] - m[2] * m[7]);
  const c11 = m[0] * m[8] - m[2] * m[6];
  const c12 = -(m[0] * m[7] - m[1] * m[6]);
  const c20 = m[1] * m[5] - m[2] * m[4];
  const c21 = -(m[0] * m[5] - m[2] * m[3]);
  const c22 = m[0] * m[4] - m[1] * m[3];
  const det = m[0] * c00 + m[1] * c01 + m[2] * c02;
  if (Math.abs(det) < 0.0001) return null;
  const inv = 1 / det;
  return [c00 * inv, c10 * inv, c20 * inv, c01 * inv, c11 * inv, c21 * inv, c02 * inv, c12 * inv, c22 * inv];
}

function min4(a, b, c, d) {
  return Math.min(Math.min(a, b), Math.min(c, d));
}

function max4(a, b, c, d) {
  return Math.max(Math.max(a, b), Math.max(c, d));
}

function createShader(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader) || "shader compile failed");
  }
  return shader;
}

function createProgram(gl, vsSource, fsSource) {
  const program = gl.createProgram();
  gl.attachShader(program, createShader(gl, gl.VERTEX_SHADER, vsSource));
  gl.attachShader(program, createShader(gl, gl.FRAGMENT_SHADER, fsSource));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || "program link failed");
  }
  return program;
}

function getUniforms(gl, program, spec) {
  const out = {};
  for (const [key, name] of Object.entries(spec)) out[key] = gl.getUniformLocation(program, name);
  return out;
}

function createTexture(gl, width, height, source, filter = gl.NEAREST) {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  if (source instanceof Uint8Array) {
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, source);
  } else {
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, source);
  }
  return tex;
}

function fontFor(weight, size) {
  return `${weight} ${size}px "${FONT_FAMILY}", "Inter Display", Inter, system-ui, sans-serif`;
}

const measureContext = typeof document === "undefined" ? null : document.createElement("canvas").getContext("2d");

function textWidth(text, weight, size) {
  measureContext.font = fontFor(weight, size);
  measureContext.fontKerning = "normal";
  return measureContext.measureText(text).width;
}

class CoverFlowWebGL2 extends HTMLElement {
  connectedCallback() {
    this.selectedQ8 = 3 * 256;
    this.targetQ8 = 3 * 256;
    this.velocityQ8 = 0;
    this.springVelocityQ8 = 0;
    this.primaryDown = false;
    this.pressX = 0;
    this.lastX = 0;
    this.lastDX = 0;
    this.pressSelectedQ8 = 0;
    this.scrubActive = false;
    this.scrubGrabDX = 0;
    this.featureMask = FEATURE_LIGHTING | FEATURE_SPRING;
    this.renderCount = 0;
    this.lastRenderMs = 0;
    this.sourceBytes = moduleByteSize();
    this.textCache = new Map();

    this.canvas = document.createElement("canvas");
    this.canvas.width = RENDER_W;
    this.canvas.height = RENDER_H;
    this.canvas.tabIndex = 0;
    this.canvas.style.display = "block";
    this.canvas.style.width = `${DISPLAY_W}px`;
    this.canvas.style.maxWidth = "100%";
    this.canvas.style.height = "auto";
    this.canvas.style.touchAction = "none";

    this.stats = document.createElement("div");
    this.stats.style.boxSizing = "border-box";
    this.stats.style.marginTop = "6px";
    this.stats.style.maxWidth = `${DISPLAY_W}px`;
    this.stats.style.font = "11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
    this.stats.style.color = "#666";
    this.stats.style.lineHeight = "1.35";

    this.replaceChildren(this.canvas, this.stats);
    this.initGL();
    this.attachInput();
    this.renderFrame();
    // Redraw once Inter has loaded, replacing text set in a fallback font.
    fontsReady.then(() => {
      this.clearTextCache();
      this.renderFrame();
    }, () => {});
  }

  initGL() {
    const gl = this.canvas.getContext("webgl2", { alpha: false, antialias: false, desynchronized: true });
    if (!gl) throw new Error("WebGL2 is unavailable");
    this.gl = gl;
    gl.viewport(0, 0, RENDER_W, RENDER_H);
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    this.quadProgram = createProgram(gl, quadVS, textureFS);
    this.imageProgram = createProgram(gl, quadVS, imageFS);
    this.capsuleProgram = createProgram(gl, quadVS, capsuleFS);
    this.uniforms = {
      quad: getUniforms(gl, this.quadProgram, {
        rect: "u_rect",
        tex: "u_tex",
        m: "u_m[0]",
        top: "u_top",
        right: "u_right",
        bottom: "u_bottom",
        left: "u_left",
        reflection: "u_reflection",
        darken: "u_darken",
      }),
      image: getUniforms(gl, this.imageProgram, { rect: "u_rect", tex: "u_tex" }),
      capsule: getUniforms(gl, this.capsuleProgram, { rect: "u_rect", box: "u_box", top: "u_top", bottom: "u_bottom" }),
    };

    this.rectBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.rectBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);

    this.albumTextures = albums.map((_, i) => createTexture(gl, TEX_SIZE, TEX_SIZE, makeAlbumTextureBytes(i), gl.NEAREST));
  }

  attachInput() {
    this.canvas.addEventListener("click", () => this.canvas.focus());
    this.canvas.addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft" || event.key === "a" || event.key === "A") {
        this.stepSelection(-1);
      } else if (event.key === "ArrowRight" || event.key === "d" || event.key === "D") {
        this.stepSelection(1);
      } else if (event.key === "Home") {
        this.setSelection(0);
      } else if (event.key === "End") {
        this.setSelection(albums.length - 1);
      } else if (event.key === "l" || event.key === "L") {
        this.featureMask ^= FEATURE_LIGHTING;
      } else if (event.key === "s" || event.key === "S") {
        this.featureMask ^= FEATURE_SPRING;
      } else {
        return;
      }
      event.preventDefault();
      this.schedule();
    });
    this.canvas.addEventListener("pointerdown", (event) => {
      if (this.primaryDown) return;
      this.canvas.setPointerCapture(event.pointerId);
      this.canvas.focus();
      const p = this.canvasPoint(event);
      if (this.scrollBarHit(p.x, p.y)) {
        const thumb = this.scrollThumb();
        this.scrubActive = true;
        this.scrubGrabDX = p.x >= thumb.x && p.x < thumb.x + thumb.w ? p.x - thumb.x : divTrunc(thumb.w, 2);
        this.scrubTo(p.x);
      } else {
        this.pressX = p.x;
        this.lastX = p.x;
        this.lastDX = 0;
        this.pressSelectedQ8 = this.selectedQ8;
        this.targetQ8 = this.selectedQ8;
        this.velocityQ8 = 0;
        this.springVelocityQ8 = 0;
      }
      this.primaryDown = true;
      this.schedule();
    });
    this.canvas.addEventListener("pointermove", (event) => {
      if (!this.primaryDown) return;
      const p = this.canvasPoint(event);
      const wasSelectedQ8 = this.selectedQ8;
      if (this.scrubActive) {
        this.scrubTo(p.x);
      } else {
        const dx = p.x - this.pressX;
        this.lastDX = p.x - this.lastX;
        this.lastX = p.x;
        this.selectedQ8 = this.clampSelected(this.pressSelectedQ8 - divTrunc(dx * 256, 129 * SCALE), true);
        this.targetQ8 = this.selectedQ8;
        this.velocityQ8 = divTrunc(-this.lastDX * 256, 129 * SCALE);
        this.springVelocityQ8 = 0;
      }
      // A held pointer that hasn't moved the covers leaves the frame unchanged.
      if (this.selectedQ8 !== wasSelectedQ8) this.schedule();
    });
    const finishPointer = (event) => {
      if (!this.primaryDown) return;
      const p = this.canvasPoint(event);
      if (this.scrubActive) {
        this.scrubActive = false;
        this.targetQ8 = this.nearestIndex() * 256;
      } else if (Math.abs(p.x - this.pressX) < 5 * SCALE) {
        const hit = this.hitAlbum(p.x, p.y);
        if (hit >= 0) this.setSelection(hit);
      }
      this.primaryDown = false;
      this.schedule();
    };
    this.canvas.addEventListener("pointerup", finishPointer);
    this.canvas.addEventListener("pointercancel", finishPointer);
    this.canvas.addEventListener("contextmenu", (event) => event.preventDefault());
  }

  canvasPoint(event) {
    const r = this.canvas.getBoundingClientRect();
    return {
      x: Math.round((event.clientX - r.left) * (RENDER_W / r.width)),
      y: Math.round((event.clientY - r.top) * (RENDER_H / r.height)),
    };
  }

  clampSelected(value, overscroll) {
    const maxQ8 = (albums.length - 1) * 256;
    return overscroll ? clamp(value, -120, maxQ8 + 120) : clamp(value, 0, maxQ8);
  }

  nearestIndex() {
    return clamp(divTrunc(this.selectedQ8 + 128, 256), 0, albums.length - 1);
  }

  targetIndex() {
    return clamp(divTrunc(this.targetQ8 + 128, 256), 0, albums.length - 1);
  }

  setSelection(index) {
    this.targetQ8 = this.clampSelected(index * 256, false);
    this.velocityQ8 = 0;
    this.springVelocityQ8 = 0;
  }

  stepSelection(delta) {
    this.setSelection(this.nearestIndex() + delta);
  }

  scrollThumbWidth() {
    return Math.max(SCROLL_TRACK_H * 3, divTrunc(SCROLL_TRACK_W * 2, albums.length));
  }

  scrollThumb() {
    const w = this.scrollThumbWidth();
    const maxQ8 = (albums.length - 1) * 256;
    const posQ8 = clamp(this.selectedQ8, 0, maxQ8);
    return { x: SCROLL_TRACK_X + divTrunc((SCROLL_TRACK_W - w) * posQ8, Math.max(1, maxQ8)), w };
  }

  scrollBarHit(x, y) {
    return x >= SCROLL_TRACK_X - SCROLL_HIT_SLOP && x < SCROLL_TRACK_X + SCROLL_TRACK_W + SCROLL_HIT_SLOP &&
      y >= SCROLL_TRACK_Y - SCROLL_HIT_SLOP && y < SCROLL_TRACK_Y + SCROLL_TRACK_H + SCROLL_HIT_SLOP;
  }

  // Places the thumb's left edge at x - scrubGrabDX and moves the covers to
  // match, without snapping to an album until the pointer is released.
  scrubTo(x) {
    const maxQ8 = (albums.length - 1) * 256;
    const travel = Math.max(1, SCROLL_TRACK_W - this.scrollThumbWidth());
    const offset = clamp(x - this.scrubGrabDX - SCROLL_TRACK_X, 0, travel);
    this.selectedQ8 = divTrunc(offset * maxQ8 + divTrunc(travel, 2), travel);
    this.targetQ8 = this.selectedQ8;
    this.velocityQ8 = 0;
    this.springVelocityQ8 = 0;
  }

  tick() {
    if (this.primaryDown) return;
    if (this.velocityQ8 !== 0) {
      this.selectedQ8 = this.clampSelected(this.selectedQ8 + this.velocityQ8, true);
      this.velocityQ8 = divTrunc(this.velocityQ8 * 88, 100);
      if (Math.abs(this.velocityQ8) < 3) {
        this.velocityQ8 = 0;
        this.targetQ8 = this.nearestIndex() * 256;
        this.springVelocityQ8 = 0;
      }
      return;
    }
    const delta = this.targetQ8 - this.selectedQ8;
    if ((this.featureMask & FEATURE_SPRING) !== 0) {
      if (Math.abs(delta) > 1 || Math.abs(this.springVelocityQ8) > 2) {
        this.springVelocityQ8 += divTrunc(delta, 7);
        this.springVelocityQ8 = divTrunc(this.springVelocityQ8 * 72, 100);
        if (this.springVelocityQ8 === 0 && delta !== 0) this.springVelocityQ8 = delta < 0 ? -1 : 1;
        this.selectedQ8 += this.springVelocityQ8;
      } else {
        this.selectedQ8 = this.targetQ8;
        this.springVelocityQ8 = 0;
      }
    } else if (Math.abs(delta) > 1) {
      let step = divTrunc(delta, 6);
      if (step === 0) step = delta < 0 ? -1 : 1;
      this.selectedQ8 += step;
    } else {
      this.selectedQ8 = this.targetQ8;
    }
  }

  // Nothing animates while the pointer is held; pointer moves drive the
  // frames instead.
  animating() {
    return !this.primaryDown && (
      this.velocityQ8 !== 0 ||
      Math.abs(this.targetQ8 - this.selectedQ8) > 1 ||
      Math.abs(this.springVelocityQ8) > 2
    );
  }

  schedule() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = 0;
      this.tick();
      this.renderFrame();
      if (this.animating()) this.schedule();
    });
  }

  useProgram(program) {
    const gl = this.gl;
    gl.useProgram(program);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.rectBuffer);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  }

  setRect(location, x0, y0, x1, y1) {
    this.gl.uniform4f(location, x0, y0, x1, y1);
  }

  drawTexture(tex, x0, y0, x1, y1) {
    const gl = this.gl;
    this.useProgram(this.imageProgram);
    this.setRect(this.uniforms.image.rect, x0, y0, x1, y1);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(this.uniforms.image.tex, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  fillCapsule(x, y, w, h, top, bottom) {
    if (w <= 0 || h <= 0) return;
    const gl = this.gl;
    this.useProgram(this.capsuleProgram);
    this.setRect(this.uniforms.capsule.rect, x, y, x + w, y + h);
    gl.uniform4f(this.uniforms.capsule.box, x, y, w, h);
    gl.uniform3f(this.uniforms.capsule.top, top[0], top[1], top[2]);
    gl.uniform3f(this.uniforms.capsule.bottom, bottom[0], bottom[1], bottom[2]);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawTexturedQuad(reflection, q, albumIndex, darken) {
    const inv = inverseHomography(q);
    if (!inv) return;
    const minX = clamp(min4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, RENDER_W - 1);
    const maxX = clamp(max4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, RENDER_W - 1);
    const minY = clamp(min4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, RENDER_H - 1);
    const maxY = clamp(max4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, RENDER_H - 1);
    const edges = makeEdges(q);
    const gl = this.gl;
    this.useProgram(this.quadProgram);
    this.setRect(this.uniforms.quad.rect, minX, minY, maxX + 1, maxY + 1);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.albumTextures[albumIndex]);
    gl.uniform1i(this.uniforms.quad.tex, 0);
    gl.uniform1fv(this.uniforms.quad.m, inv);
    gl.uniform3fv(this.uniforms.quad.top, edges.top);
    gl.uniform3fv(this.uniforms.quad.right, edges.right);
    gl.uniform3fv(this.uniforms.quad.bottom, edges.bottom);
    gl.uniform3fv(this.uniforms.quad.left, edges.left);
    gl.uniform1i(this.uniforms.quad.reflection, reflection ? 1 : 0);
    gl.uniform1i(this.uniforms.quad.darken, darken);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  clearTextCache() {
    for (const item of this.textCache.values()) this.gl.deleteTexture(item.tex);
    this.textCache.clear();
  }

  // Sets one line of text with the browser's kerning into a texture, cached
  // by content, and draws it with its baseline at y.
  drawText(x, baseline, text, weight, size, color) {
    const key = `${text}|${weight}|${size}|${color.join(",")}`;
    let item = this.textCache.get(key);
    if (!item) {
      const pad = 2;
      const canvas = document.createElement("canvas");
      let ctx = canvas.getContext("2d");
      ctx.font = fontFor(weight, size);
      ctx.fontKerning = "normal";
      const metrics = ctx.measureText(text);
      const ascent = Math.ceil(metrics.fontBoundingBoxAscent ?? size);
      const descent = Math.ceil(metrics.fontBoundingBoxDescent ?? size * 0.3);
      canvas.width = Math.max(1, Math.ceil(metrics.width) + pad * 2);
      canvas.height = ascent + descent + pad * 2;
      // Resizing resets the context's state.
      ctx = canvas.getContext("2d");
      ctx.font = fontFor(weight, size);
      ctx.fontKerning = "normal";
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = `rgb(${color[0]}, ${color[1]}, ${color[2]})`;
      ctx.fillText(text, pad, pad + ascent);
      item = {
        tex: createTexture(this.gl, canvas.width, canvas.height, canvas, this.gl.NEAREST),
        w: canvas.width,
        h: canvas.height,
        dx: -pad,
        dy: -(pad + ascent),
      };
      this.textCache.set(key, item);
    }
    const left = Math.round(x) + item.dx;
    const top = Math.round(baseline) + item.dy;
    this.drawTexture(item.tex, left, top, left + item.w, top + item.h);
  }

  drawTextCentered(centerX, baseline, text, weight, size, color) {
    this.drawText(Math.round(centerX - textWidth(text, weight, size) * 0.5), baseline, text, weight, size, color);
  }

  drawScrollBar() {
    const x = SCROLL_TRACK_X;
    const y = SCROLL_TRACK_Y;
    const w = SCROLL_TRACK_W;
    const h = SCROLL_TRACK_H;
    this.fillCapsule(x, y, w, h, [0x50, 0x50, 0x50], [0x3a, 0x3a, 0x3a]);
    this.fillCapsule(x + SCALE, y + SCALE, w - 2 * SCALE, h - 2 * SCALE, [0x0c, 0x0c, 0x0c], [0x1e, 0x1e, 0x1e]);

    const thumb = this.scrollThumb();
    // The thumb brightens while it is held.
    const lift = this.scrubActive ? 0x1c : 0;
    const lit = (v) => [v + lift, v + lift, v + lift];
    this.fillCapsule(thumb.x, y, thumb.w, h, lit(0xb4), lit(0x70));
    this.fillCapsule(thumb.x + SCALE, y + SCALE, thumb.w - 2 * SCALE, h - 2 * SCALE, lit(0x8c), lit(0x50));
  }

  drawChrome() {
    const flagX = 16 * SCALE;
    this.drawFlagLabel(flagX, "L LIGHT", (this.featureMask & FEATURE_LIGHTING) !== 0);
    this.drawFlagLabel(flagX + textWidth("L LIGHT", 400, FLAG_SIZE) + 14 * SCALE, "S SPRING", (this.featureMask & FEATURE_SPRING) !== 0);
    const album = albums[this.targetIndex()];
    this.drawTextCentered(CENTER_X, TITLE_BASELINE, album.title, 700, TITLE_SIZE, [0xff, 0xff, 0xff]);
    this.drawTextCentered(CENTER_X, ARTIST_BASELINE, album.artist, 400, ARTIST_SIZE, [0x9a, 0x9a, 0x9a]);
    this.drawScrollBar();
  }

  drawFlagLabel(x, label, enabled) {
    this.drawText(x, FLAG_BASELINE, label, 400, FLAG_SIZE, enabled ? [0x8a, 0x8a, 0x8a] : [0x40, 0x40, 0x40]);
  }

  hitAlbum(x, y) {
    let best = -1;
    let bestAbs = 100000;
    for (let i = 0; i < albums.length; i++) {
      const dQ8 = i * 256 - this.selectedQ8;
      if (Math.abs(dQ8) > 4 * 256) continue;
      const q = coverPose(this.selectedQ8, i).q;
      if (x >= min4(q.tl.x, q.tr.x, q.br.x, q.bl.x) &&
          x <= max4(q.tl.x, q.tr.x, q.br.x, q.bl.x) &&
          y >= min4(q.tl.y, q.tr.y, q.br.y, q.bl.y) &&
          y <= max4(q.tl.y, q.tr.y, q.br.y, q.bl.y)) {
        const ad = Math.abs(dQ8);
        if (ad < bestAbs) {
          bestAbs = ad;
          best = i;
        }
      }
    }
    return best;
  }

  // Draws the outermost covers first and the centered one last, so nearer
  // covers, and their reflections, hide the ones behind them.
  drawBackToFront(covers, reflection) {
    const nearest = this.nearestIndex();
    const draw = (idx) => {
      const cover = covers.get(idx);
      if (cover) this.drawTexturedQuad(reflection, reflection ? cover.reflectionQ : cover.q, idx, cover.darken);
    };
    for (let pass = 5; pass >= 1; pass--) {
      draw(nearest - pass);
      draw(nearest + pass);
    }
    draw(nearest);
  }

  renderFrame() {
    const start = performance.now();
    const gl = this.gl;
    // The original stage is pure black: no floor line, glow or vignette.
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const lighting = (this.featureMask & FEATURE_LIGHTING) !== 0;
    const covers = new Map();
    const nearest = this.nearestIndex();
    for (let idx = Math.max(0, nearest - 5); idx <= Math.min(albums.length - 1, nearest + 5); idx++) {
      const pose = coverPose(this.selectedQ8, idx);
      // With lighting on, side covers darken as they turn away from the viewer.
      pose.darken = lighting ? Math.round((1 - pose.facing) * SIDE_DARKEN_MAX) : 0;
      covers.set(idx, pose);
    }
    this.drawBackToFront(covers, true);
    this.drawBackToFront(covers, false);
    this.drawChrome();
    gl.flush();
    this.lastRenderMs = performance.now() - start;
    this.renderCount += 1;
    this.updateStats();
  }

  updateStats() {
    const size = this.sourceBytes > 0 ? ` | JS ${formatBytes(this.sourceBytes)}` : "";
    this.stats.textContent = `WebGL2 render ${this.lastRenderMs.toFixed(3)} ms | frames ${this.renderCount}${size} | canvas ${RENDER_W}x${RENDER_H}`;
  }
}

if (!customElements.get("cover-flow-webgl2")) {
  customElements.define("cover-flow-webgl2", CoverFlowWebGL2);
}
