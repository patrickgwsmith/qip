// Plans pixel kernels: WGSL point kernels, each `fn name(c: vec4f) -> vec4f`,
// as accepted by wgsl-compute-to-wasm.wasm.
//
// fusePixelKernels() joins consecutive kernels into one kernel source. The
// compiler turns it into one Tile component that applies them in order to
// each pixel, so the pixels stay f32 between stages and the host makes one
// tile pass instead of one per stage.
//
// pixelKernelsToComputeShader() wraps a kernel source in WebGPU compute
// entry points that run the same kernels over an array<vec4f>, one entry
// point per pass. A kernel that calls `sample(dx, dy)` starts a pass, since
// it reads its neighbors' results from the pass before.

const TOKEN = /\/\/[^\n]*|\/\*[\s\S]*?\*\/|[A-Za-z_][A-Za-z0-9_]*|\s+|./g;

function isIdentifier(token) {
  return /^[A-Za-z_]/.test(token);
}

function isTrivia(token) {
  return /^\s/.test(token) || token.startsWith("//") || token.startsWith("/*");
}

// Names declared at module scope with `override`, `const` or `fn`, in
// source order, the names of the `fn` kernels, and the kernels that sample.
function moduleNames(tokens) {
  const names = new Set();
  const kernels = [];
  const sampling = new Set();
  let depth = 0;
  let declaring = null;
  let previous = "";
  for (const token of tokens) {
    if (isTrivia(token)) continue;
    if (token === "{" || token === "(") depth += 1;
    else if (token === "}" || token === ")") depth -= 1;
    else if (declaring && isIdentifier(token)) {
      names.add(token);
      if (declaring === "fn") kernels.push(token);
      declaring = null;
    } else if (depth === 0 && (token === "override" || token === "const" || token === "fn")) {
      declaring = token;
    } else if (depth > 0 && token === "sample" && previous !== "." && kernels.length > 0) {
      sampling.add(kernels.at(-1));
    }
    previous = token;
  }
  return { names, kernels, sampling };
}

// Lists the kernel function names of a kernel source, in the order the
// compiled Tile component applies them.
export function pixelKernelNames(source) {
  return moduleNames(source.match(TOKEN) ?? []).kernels;
}

// Groups the kernels into passes: each kernel that samples starts one, and
// point kernels join the pass before them.
export function pixelKernelPasses(source) {
  const { kernels, sampling } = moduleNames(source.match(TOKEN) ?? []);
  const passes = [];
  for (const name of kernels) {
    if (passes.length === 0 || sampling.has(name)) passes.push([]);
    passes.at(-1).push(name);
  }
  return passes;
}

// Fuses consecutive pixel kernel sources into one. Module-scope names in
// stage i get the prefix `s<i>_`, so overrides do not collide; `uniforms[i]`
// maps each of stage i's override names to its name in the fused source.
export function fusePixelKernels(sources) {
  const parts = [];
  const uniforms = [];
  sources.forEach((source, stage) => {
    const tokens = source.match(TOKEN) ?? [];
    const { names } = moduleNames(tokens);
    const prefix = `s${stage}_`;
    const renamed = new Map();
    let previous = "";
    const out = tokens.map((token) => {
      // `c.r` is a member, not a reference to a module-scope `r`.
      const member = previous === ".";
      if (!isTrivia(token)) previous = token;
      if (member || !names.has(token)) return token;
      renamed.set(token, prefix + token);
      return prefix + token;
    });
    const overrides = new Map();
    let declaringOverride = false;
    for (const token of tokens) {
      if (isTrivia(token)) continue;
      if (declaringOverride) overrides.set(token, renamed.get(token));
      declaringOverride = token === "override";
    }
    parts.push(`// Stage ${stage}\n${out.join("").trim()}\n`);
    uniforms.push(overrides);
  });
  return { source: parts.join("\n"), uniforms };
}

// Maps per-stage uniform values to the fused source's override names.
export function fusedUniformValues(uniforms, stageValues) {
  const values = {};
  stageValues.forEach((stage, i) => {
    for (const [name, value] of Object.entries(stage ?? {})) {
      const fused = uniforms[i].get(name);
      if (!fused) throw new Error(`stage ${i} has no uniform ${name}`);
      values[fused] = value;
    }
  });
  return values;
}

// A WebGPU compute shader with one entry point per pass, `qip_pass0` and on.
// Each reads `qip_src` and writes `qip_dst`, one invocation per pixel, so a
// caller dispatches them in order and swaps the buffers between passes. When
// a kernel samples, the shader declares `qip_width` and `qip_height`
// overrides for the image size, and samples clamp to the image's edges.
export function pixelKernelsToComputeShader(source, workgroupSize = 64) {
  const passes = pixelKernelPasses(source);
  const samples = moduleNames(source.match(TOKEN) ?? []).sampling.size > 0;
  const sampling = samples
    ? `
override qip_width: u32;
override qip_height: u32;
var<private> qip_pos: vec2i;

fn sample(dx: i32, dy: i32) -> vec4f {
  let last = vec2i(i32(qip_width), i32(qip_height)) - 1;
  let p = clamp(qip_pos + vec2i(dx, dy), vec2i(0), last);
  return qip_src[u32(p.y) * qip_width + u32(p.x)];
}
`
    : "";
  const position = samples ? "\n  qip_pos = vec2i(i32(id.x % qip_width), i32(id.x / qip_width));" : "";
  const entries = passes.map(
    (names, i) => `
@compute @workgroup_size(${workgroupSize})
fn qip_pass${i}(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&qip_dst) { return; }${position}
  var c = qip_src[id.x];
${names.map((name) => `  c = ${name}(c);`).join("\n")}
  qip_dst[id.x] = c;
}
`,
  );
  return `${source.trim()}

@group(0) @binding(0) var<storage, read> qip_src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> qip_dst: array<vec4f>;
${sampling}${entries.join("")}`;
}
