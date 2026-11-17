// Generates gui/assets/textedit-tiger-buttons.zig: Retina (2x) sprites of
// Mac OS X 10.4 Tiger's close, minimize and zoom buttons.
//
//   node tools/gen-textedit-tiger-buttons.mjs > gui/assets/textedit-tiger-buttons.zig
//
// Tiger only shipped 1x window widgets, so there is no 2x original to copy.
// Aqua's gels were drawn in Photoshop as stacked layer styles, so each button
// is drawn here the same way, as resolution-independent layers: a drop shadow
// and a bottom glow outside the gel, a vertical color gradient, a bright
// caustic low in the gel, an inner burn toward the rim, a dark rim stroke and
// a white specular highlight at the top. The layers are rendered at 2x with
// 6x6 supersampling per pixel.
//
// The layer parameters below were fitted to a 1x Tiger screenshot, so that the
// gels rendered at 1x match Tiger's pixels (RMS error about 8 per channel,
// mostly at the rim). To refit them:
//
//   node tools/gen-textedit-tiger-buttons.mjs --fit "Tiger TextEdit.png" [iterations]
//
// The screenshot is https://archive.org/download/mac104-tiger/Tiger%20TextEdit.png
// (1024x768). Its TextEdit window's left edge is at x 0 and its title bar's
// top border at y 21. Its window has unsaved changes, so the fit skips the
// dot in the middle of the close button.
//
// An inactive window shows all three buttons as the same pale gray gel, which
// has its own layer parameters, fitted to figure 13-3 ("Title bar buttons for
// standard windows") of Apple's September 2005 Human Interface Guidelines:
//
//   node tools/gen-textedit-tiger-buttons.mjs --fit-inactive hig-gray.png [iterations]
//
// hig-gray.png is the figure's 1x bitmap of the gray buttons (100x26), with
// the title bar's top border at y 3 and the first gel centered at (25, 15).
import fs from "node:fs";
import zlib from "node:zlib";

// Layers shared by all three gels, in units of the radius R where relevant.
const SHAPE = {
  shA: 0.364, shW: 0.2, shBias: -0.295, // drop shadow: alpha, falloff (pt), bias toward the top
  glA: 0.538, glW: 1.18, // white glow below the gel: alpha, falloff (pt)
  mid: 0.439, // where the gradient's middle color sits, from top 0 to bottom 1
  cRx: 0.808, cY: 0.585, cRy: 0.665, cA: 1, // caustic: radii, center below middle, alpha
  edgeP: 3.644, edgeA: 1, edgeBot: 1, // inner burn: falloff power, alpha, fade toward the bottom
  rimW: 1.096, rimA: 0.5, rimTopDark: 0.219, // rim stroke: width (pt), alpha, darkening at the top
  hRx: 0.663, hY: -0.567, hRy: 0.32, hSoft: 0.696, hFade: 0.567, hA: 1, // specular highlight
};
// Per-gel colors. `top` is mostly hidden under the highlight.
const COLORS = {
  close: { top: [105, 152, 152], mid: [191, 9, 12], bot: [255, 33, 10], glow: [255, 189, 179], rim: [28, 25, 28] },
  minimize: { top: [119, 119, 149], mid: [246, 118, 0], bot: [255, 221, 0], glow: [255, 255, 143], rim: [48, 14, 32] },
  zoom: { top: [122, 114, 151], mid: [66, 152, 1], bot: [122, 255, 0], glow: [222, 255, 151], rim: [21, 18, 31] },
};
const NAMES = ["close", "minimize", "zoom"];

// The inactive gray gel, shared by all three buttons: a very light body with
// a mid-gray rim, fitted to the HIG figure (RMS error about 4).
const SHAPE_INACTIVE = {
  shA: 0.757, shW: 0.1, shBias: -0.416,
  glA: 0.517, glW: 0.977,
  mid: 0.47,
  cRx: 1.258, cY: 0.889, cRy: 0.905, cA: 1.184,
  edgeP: 3.113, edgeA: 0.701, edgeBot: 0.797,
  rimW: 1.147, rimA: 0.395, rimTopDark: 0.237,
  hRx: 0.737, hY: -0.517, hRy: 0.423, hSoft: 0.75, hFade: 0.78, hA: 1.053,
};
const COLOR_INACTIVE = { top: [148, 148, 148], mid: [198, 198, 198], bot: [255, 255, 255], glow: [243, 243, 243], rim: [104, 104, 104] };

// Title bar shades per point from the top border, as in gui/textedit.zig.
// Only the fit uses them: the screenshot's gels sit over this bar.
const SHADES = [0xC0, 0xF9, 0xEF, 0xE8, 0xE6, 0xE6, 0xE6, 0xE4, 0xE3, 0xE2, 0xE0, 0xDF, 0xDD, 0xDB, 0xD9, 0xD7, 0xD6, 0xD3, 0xD1, 0xCF, 0xCC, 0xCA, 0x8C];

// Each button is a 14-point circle centered at (15 + 21 i, 12) points; its
// sprite box is 16x17 points from (7 + 21 i, 4), so the center is (8, 8).
const R = 7, X0 = 7, Y0 = 4, W1 = 16, H1 = 17, CX_BOX = 8, CY_BOX = 8;

const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const mix = (a, b, t) => a.map((v, k) => v + (b[k] - v) * t);
const smooth = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t); };

// The color at (dx, dy) points from the gel's center over a gray title bar.
function shade(dx, dy, bg, S, C) {
  const r = Math.hypot(dx, dy), up = dy / Math.max(r, 1e-6);
  const d = Math.max(0, r - R);
  let out = [bg, bg, bg];
  out = mix(out, [0, 0, 0], clamp(S.shA * Math.exp(-d / S.shW) * (1 - S.shBias * up)));
  out = mix(out, [255, 255, 255], clamp(S.glA * Math.exp(-d / S.glW) * clamp(up)));
  if (r > R) return out;
  const t = clamp((dy / R + 1) / 2);
  let c = t < S.mid ? mix(C.top, C.mid, t / S.mid) : mix(C.mid, C.bot, (t - S.mid) / (1 - S.mid));
  c = mix(c, C.glow, clamp(S.cA * Math.exp(-((dx / (S.cRx * R)) ** 2 + ((dy - S.cY * R) / (S.cRy * R)) ** 2))));
  c = mix(c, C.rim, clamp(Math.pow(r / R, S.edgeP) * S.edgeA * (1 - S.edgeBot * t)));
  const rim = smooth(R - S.rimW - 0.12, R - S.rimW + 0.12, r);
  c = mix(c, mix(C.rim, [0, 0, 0], S.rimTopDark * (1 - t)), clamp(rim * S.rimA));
  const hx = dx / (S.hRx * R), hy = (dy - S.hY * R) / (S.hRy * R);
  const hl = (1 - smooth(1 - S.hSoft, 1, Math.hypot(hx, hy))) * clamp(1 - ((hy + 1) / 2) * S.hFade);
  return mix(c, [255, 255, 255], clamp(hl * S.hA));
}

// A pixel `size` points wide whose top-left corner is (dx, dy) from the center.
function pixel(dx, dy, size, bg, S, C, n) {
  const acc = [0, 0, 0];
  for (let j = 0; j < n; j++) for (let i = 0; i < n; i++) {
    const c = shade(dx + ((i + 0.5) * size) / n, dy + ((j + 0.5) * size) / n, bg, S, C);
    for (let k = 0; k < 3; k++) acc[k] += c[k];
  }
  return acc.map((v) => v / (n * n));
}

function readPng(path) {
  const b = fs.readFileSync(path);
  let o = 8, W = 0, H = 0, ct = 0;
  const idat = [];
  while (o < b.length) {
    const len = b.readUInt32BE(o), t = b.toString("ascii", o + 4, o + 8), d = b.subarray(o + 8, o + 8 + len);
    if (t === "IHDR") { W = d.readUInt32BE(0); H = d.readUInt32BE(4); ct = d[9]; if (d[8] !== 8 || d[12] !== 0) throw new Error("need 8-bit non-interlaced PNG"); }
    if (t === "IDAT") idat.push(d);
    o += 12 + len;
  }
  const bpp = ct === 6 ? 4 : ct === 2 ? 3 : ct === 0 ? 1 : 0;
  if (!bpp) throw new Error("need a gray, RGB or RGBA PNG");
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const st = W * bpp, out = Buffer.alloc(H * st);
  for (let y = 0; y < H; y++) {
    const f = raw[y * (st + 1)];
    for (let x = 0; x < st; x++) {
      const r = raw[y * (st + 1) + 1 + x];
      const a = x >= bpp ? out[y * st + x - bpp] : 0, u = y ? out[(y - 1) * st + x] : 0, c = x >= bpp && y ? out[(y - 1) * st + x - bpp] : 0;
      let v = r;
      if (f === 1) v = r + a; else if (f === 2) v = r + u; else if (f === 3) v = r + ((a + u) >> 1);
      else if (f === 4) { const p = a + u - c, pa = Math.abs(p - a), pb = Math.abs(p - u), pc = Math.abs(p - c); v = r + (pa <= pb && pa <= pc ? a : pb <= pc ? u : c); }
      out[y * st + x] = v & 255;
    }
  }
  return { W, H, px: (x, y) => [0, 1, 2].map((k) => out[(y * W + x) * bpp + (bpp === 1 ? 0 : k)]) };
}

// Coordinate descent on every layer parameter and color in `shape` and
// `colors`, minimizing the squared error of `samples` 1x pixels: each is
// [dx, dy, background, observed RGB] relative to a gel's center.
function descend(shape, colors, samples, iterations) {
  const params = [];
  for (const k of Object.keys(shape)) params.push({ get: () => shape[k], set: (x) => (shape[k] = x), lo: k.endsWith("W") ? 0.1 : -1, hi: 8 });
  for (const [name, C] of Object.entries(colors)) for (const c of Object.keys(C)) for (let k = 0; k < 3; k++) params.push({ get: () => C[c][k], set: (x) => (C[c][k] = x), lo: 0, hi: 255 });
  const err = () => {
    let e = 0;
    for (const [name, dx, dy, bg, o] of samples) {
      const m = pixel(dx, dy, 1, bg, shape, colors[name], 3);
      for (let k = 0; k < 3; k++) e += (m[k] - o[k]) ** 2;
    }
    return e;
  };
  let best = err();
  const steps = params.map((p) => Math.max(0.02, Math.abs(p.get()) * 0.1));
  for (let it = 0; it < iterations; it++) {
    params.forEach((p, i) => {
      const v = p.get();
      for (const s of [1, -1]) {
        p.set(clamp(v + s * steps[i], p.lo, p.hi));
        const e = err();
        if (e < best) { best = e; steps[i] *= 1.3; return; }
      }
      p.set(v);
      steps[i] *= 0.6;
    });
    console.error(`iteration ${it + 1}: rms ${Math.sqrt(best / (3 * samples.length)).toFixed(2)}`);
  }
  const round = (v) => (Array.isArray(v) ? v.map(Math.round) : +v.toFixed(3));
  console.log("shape:", JSON.stringify(Object.fromEntries(Object.entries(shape).map(([k, v]) => [k, round(v)]))));
  for (const [n, C] of Object.entries(colors)) console.log(`${n}:`, JSON.stringify(Object.fromEntries(Object.entries(C).map(([k, v]) => [k, round(v)]))));
}

// The colored gels, against the TextEdit screenshot over our title bar.
function fit(path, iterations) {
  const im = readPng(path), TOP = 21;
  const samples = [];
  NAMES.forEach((name, i) => {
    for (let y = 0; y < H1; y++) for (let x = 0; x < W1; x++) {
      const dx = x - CX_BOX, dy = y - CY_BOX;
      if (i === 0 && Math.hypot(dx + 0.5, dy + 0.5) < 3.6) continue; // the unsaved dot
      samples.push([name, dx, dy, SHADES[Y0 + y], im.px(X0 + 21 * i + x, TOP + Y0 + y)]);
    }
  });
  descend(SHAPE, Object.fromEntries(NAMES.map((n) => [n, COLORS[n]])), samples, iterations);
}

// The gray gel, against the HIG figure over the figure's own title bar,
// read from a column to the right of the buttons.
function fitInactive(path, iterations) {
  const im = readPng(path), TOP = 3, CX = 25;
  const samples = [];
  for (let i = 0; i < 3; i++) {
    for (let y = 0; y < H1; y++) for (let x = 0; x < W1; x++) {
      const bx = CX - CX_BOX + 21 * i + x, by = TOP + Y0 + y;
      samples.push(["inactive", x - CX_BOX, y - CY_BOX, im.px(85, by)[0], im.px(bx, by)]);
    }
  }
  descend(SHAPE_INACTIVE, { inactive: COLOR_INACTIVE }, samples, iterations);
}

if (process.argv[2] === "--fit") {
  fit(process.argv[3], Number(process.argv[4]) || 40);
} else if (process.argv[2] === "--fit-inactive") {
  fitInactive(process.argv[3], Number(process.argv[4]) || 40);
} else {
  const W2 = W1 * 2, H2 = H1 * 2;
  let zig = `// Generated by tools/gen-textedit-tiger-buttons.mjs. Do not edit.
//
// Mac OS X 10.4 Tiger's close, minimize and zoom buttons with their glow,
// and the gray gel an inactive window shows instead, at 2x, drawn from layer
// styles fitted to Tiger's 1x pixels. Each sprite is
// ${W2}x${H2} pixels of premultiplied RGBA, so it composites over whichever
// title bar is drawn (active or inactive), and is drawn with its top-left at
// point (${X0} + 21 * index, ${Y0}).

pub const X_PT: i32 = ${X0};
pub const Y_PT: i32 = ${Y0};
pub const SPACING_PT: i32 = 21;
pub const W: usize = ${W2};
pub const H: usize = ${H2};
`;
  const sprites = [...NAMES.map((n) => [n, SHAPE, COLORS[n]]), ["inactive", SHAPE_INACTIVE, COLOR_INACTIVE]];
  for (const [name, S, C] of sprites) {
    if (name === "inactive") zig += "\n// An inactive window's buttons: one gray gel for all three.";
    zig += `\npub const ${name} = [_]u8{\n`;
    for (let y = 0; y < H2; y++) {
      const row = [];
      for (let x = 0; x < W2; x++) {
        // Every layer is a linear blend over the background, so rendering
        // over black and over white recovers the premultiplied color and the
        // alpha exactly.
        const dx = x / 2 - CX_BOX, dy = y / 2 - CY_BOX;
        const c0 = pixel(dx, dy, 0.5, 0, S, C, 6);
        const c1 = pixel(dx, dy, 0.5, 255, S, C, 6);
        const a = 255 - (c1[0] - c0[0] + c1[1] - c0[1] + c1[2] - c0[2]) / 3;
        for (const v of [...c0, a]) row.push("0x" + Math.round(clamp(v, 0, 255)).toString(16).padStart(2, "0"));
      }
      zig += "    " + row.join(", ") + ",\n";
    }
    zig += "};\n";
  }
  process.stdout.write(zig);
}
