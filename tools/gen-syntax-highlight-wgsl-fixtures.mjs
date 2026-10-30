// Regenerates compliance/syntax-highlight-wgsl.fixtures.txt.
//
// Highlight.js 11 has no WGSL grammar, so this file holds the one
// text/html/html-code-syntax-highlight-wgsl.zig follows, and runs it with a
// local copy of Highlight.js to produce the expected HTML:
//
//   node tools/gen-syntax-highlight-wgsl-fixtures.mjs path/to/highlight.js/package
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const KEYWORDS = {
  keyword: ['alias', 'break', 'case', 'const', 'const_assert', 'continue', 'continuing', 'default', 'diagnostic', 'discard', 'else', 'enable', 'fn', 'for', 'if', 'let', 'loop', 'override', 'requires', 'return', 'struct', 'switch', 'var', 'while',
    'function', 'private', 'workgroup', 'uniform', 'storage', 'read', 'write', 'read_write'],
  literal: ['true', 'false'],
  type: ['bool', 'f16', 'f32', 'i32', 'u32', 'vec2', 'vec3', 'vec4',
    'mat2x2', 'mat2x3', 'mat2x4', 'mat3x2', 'mat3x3', 'mat3x4', 'mat4x2', 'mat4x3', 'mat4x4',
    'array', 'atomic', 'ptr', 'sampler', 'sampler_comparison',
    'texture_1d', 'texture_2d', 'texture_2d_array', 'texture_3d', 'texture_cube', 'texture_cube_array',
    'texture_multisampled_2d', 'texture_depth_multisampled_2d', 'texture_external',
    'texture_storage_1d', 'texture_storage_2d', 'texture_storage_2d_array', 'texture_storage_3d',
    'texture_depth_2d', 'texture_depth_2d_array', 'texture_depth_cube', 'texture_depth_cube_array',
    ...['2', '3', '4'].flatMap((n) => ['i', 'u', 'f', 'h'].map((s) => `vec${n}${s}`)),
    ...['2', '3', '4'].flatMap((c) => ['2', '3', '4'].flatMap((r) => ['f', 'h'].map((s) => `mat${c}x${r}${s}`)))],
  built_in: ['bitcast', 'all', 'any', 'select', 'arrayLength',
    'abs', 'acos', 'acosh', 'asin', 'asinh', 'atan', 'atanh', 'atan2', 'ceil', 'clamp', 'cos', 'cosh',
    'countLeadingZeros', 'countOneBits', 'countTrailingZeros', 'cross', 'degrees', 'determinant', 'distance', 'dot',
    'dot4U8Packed', 'dot4I8Packed', 'exp', 'exp2', 'extractBits', 'faceForward', 'firstLeadingBit', 'firstTrailingBit',
    'floor', 'fma', 'fract', 'frexp', 'insertBits', 'inverseSqrt', 'ldexp', 'length', 'log', 'log2', 'max', 'min', 'mix',
    'modf', 'normalize', 'pow', 'quantizeToF16', 'radians', 'reflect', 'refract', 'reverseBits', 'round', 'saturate',
    'sign', 'sin', 'sinh', 'smoothstep', 'sqrt', 'step', 'tan', 'tanh', 'transpose', 'trunc',
    'dpdx', 'dpdxCoarse', 'dpdxFine', 'dpdy', 'dpdyCoarse', 'dpdyFine', 'fwidth', 'fwidthCoarse', 'fwidthFine',
    'textureDimensions', 'textureGather', 'textureGatherCompare', 'textureLoad', 'textureNumLayers', 'textureNumLevels',
    'textureNumSamples', 'textureSample', 'textureSampleBias', 'textureSampleCompare', 'textureSampleCompareLevel',
    'textureSampleGrad', 'textureSampleLevel', 'textureSampleBaseClampToEdge', 'textureStore',
    'atomicLoad', 'atomicStore', 'atomicAdd', 'atomicSub', 'atomicMax', 'atomicMin', 'atomicAnd', 'atomicOr', 'atomicXor',
    'atomicExchange', 'atomicCompareExchangeWeak',
    'pack4x8snorm', 'pack4x8unorm', 'pack4xI8', 'pack4xU8', 'pack4xI8Clamp', 'pack4xU8Clamp',
    'pack2x16snorm', 'pack2x16unorm', 'pack2x16float',
    'unpack4x8snorm', 'unpack4x8unorm', 'unpack4xI8', 'unpack4xU8', 'unpack2x16snorm', 'unpack2x16unorm', 'unpack2x16float',
    'storageBarrier', 'textureBarrier', 'workgroupBarrier', 'workgroupUniformLoad'],
};

export default function wgsl(hljs) {
  const IDENT = /[a-zA-Z_]\w*/;
  const ALL = Object.values(KEYWORDS).flat();
  return {
    name: 'WGSL',
    keywords: KEYWORDS,
    contains: [
      hljs.C_LINE_COMMENT_MODE,
      hljs.COMMENT('/\\*', '\\*/', { contains: ['self'] }),
      { scope: 'meta', match: /@[a-zA-Z_]\w*/ },
      {
        scope: 'number',
        relevance: 0,
        variants: [
          { match: /\b0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)(?:[pP][+-]?\d+[fh]?)?[iu]?/ },
          { match: /\b\d+(?:\.\d*)?(?:[eE][+-]?\d+)?[iufh]?/ },
          { match: /\B\.\d+(?:[eE][+-]?\d+)?[fh]?/ },
        ],
      },
      { match: [/\bfn/, /\s+/, IDENT], scope: { 1: 'keyword', 3: 'title.function' } },
      { match: [/\b(?:struct|alias)/, /\s+/, IDENT], scope: { 1: 'keyword', 3: 'title.class' } },
      { scope: 'punctuation', match: /->/ },
      {
        scope: 'title.function.invoke',
        relevance: 0,
        match: hljs.regex.concat(/\b/, `(?!(?:${ALL.join('|')})\\b)`, IDENT, hljs.regex.lookahead(/\s*\(/)),
      },
    ],
  };
}

const ENTITIES = [['&amp;', '&'], ['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'], ['&#39;', "'"], ['&#34;', '"'], ['&#x27;', "'"], ['&apos;', "'"]];

// Splits escaped code into decoded characters, each with its original text,
// as the Zig port does.
function decode(code) {
  const units = [];
  let i = 0;
  outer: while (i < code.length) {
    if (code[i] === '&') {
      for (const [text, ch] of ENTITIES) {
        if (code.startsWith(text, i)) {
          units.push([ch, text]);
          i += text.length;
          continue outer;
        }
      }
    }
    units.push([code[i], code[i]]);
    i += 1;
  }
  return units;
}

// Highlights escaped code, copying the original escaped text into the output.
function highlightCode(hljs, code) {
  const units = decode(code);
  const html = hljs.highlight(units.map((u) => u[0]).join(''), { language: 'wgsl', ignoreIllegals: true }).value;
  const unescape = { amp: '&', lt: '<', gt: '>', quot: '"', '#x27': "'" };
  let out = '';
  let u = 0;
  for (const m of html.matchAll(/<span class="[^"]*">|<\/span>|&(amp|lt|gt|quot|#x27);|[^<&]+/g)) {
    if (m[0][0] === '<') {
      out += m[0];
      continue;
    }
    const text = m[1] ? unescape[m[1]] : m[0];
    for (let k = 0; k < text.length; k++) {
      out += units[u][1];
      u += 1;
    }
  }
  return out;
}

const cases = [
`@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> out: array<u32>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let size = textureDimensions(src);
  if (any(id.xy >= size)) {
    return;
  }
  let c = textureLoad(src, vec2i(id.xy), 0);
  out[id.y * size.x + id.x] = pack4x8unorm(c);
}`,
`struct VertexOut {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> VertexOut {
  var corners = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var out: VertexOut;
  out.position = vec4f(corners[i], 0.0, 1.0);
  out.uv = corners[i] * 0.5 + 0.5;
  return out;
}`,
`const pi = 3.14159265;
const half = .5f;
const tiny = 1e-6;
const big = 0x7fffffffu;
const hex_float = 0x1.8p3f;
const neg = -2i + 4u + 1.0h;`,
`// TODO: share with the vertex shader.
/* Block comments /* nest */ in WGSL.
   NOTE: so this is still a comment. */
fn luma(c: vec3f) -> f32 {
  return dot(c, vec3f(0.2126, 0.7152, 0.0722)); // Rec. 709
}`,
`alias Color = vec4<f32>;
override strength: f32 = 1.0;
const_assert 2 < 3;

fn shade(c: Color, t: f32) -> Color {
  let k = smoothstep(0.0, 1.0, clamp(t, 0.0, 1.0)) * strength;
  return select(c, mix(c, vec4f(1.0), k), t > 0.5 && t <= 1.0);
}`,
`@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var total = vec3f(0.0);
  for (var i = 0; i < 4; i++) {
    total += sampleAt(pos.xy + vec2f(f32(i), 0.0)).rgb;
  }
  loop {
    if true { break; }
    continuing { }
  }
  return vec4f(total / 4.0, 1.0);
}`,
];

const packageDir = process.argv[2];
if (!packageDir) throw new Error('usage: gen-syntax-highlight-wgsl-fixtures.mjs path/to/highlight.js/package');
const { default: hljs } = await import(pathToFileURL(path.resolve(packageDir, 'lib/core.js')).href);
hljs.registerLanguage('wgsl', wgsl);

const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const fixtures = cases.map((source) => {
  const code = escape(source);
  return `=== INPUT ===\n<pre><code class="language-wgsl">${code}</code></pre>\n=== OUTPUT ===\n<pre><code class="language-wgsl hljs">${highlightCode(hljs, code)}</code></pre>\n=== END ===\n`;
});
const out = new URL('../compliance/syntax-highlight-wgsl.fixtures.txt', import.meta.url);
fs.writeFileSync(out, fixtures.join('\n'));
