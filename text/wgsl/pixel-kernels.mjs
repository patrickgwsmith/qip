// Plans pixel kernels: WGSL point kernels, each `fn name(c: vec4f) -> vec4f`,
// as accepted by wgsl-compute-to-wasm.wasm.
//
// fusePixelKernels() joins consecutive kernels into one kernel source. The
// compiler turns it into one Tile component that applies them in order to
// each pixel, so the pixels stay f32 between stages and the host makes one
// tile pass instead of one per stage.
//
// pixelKernelsToComputeShader() wraps a kernel source in a WebGPU compute
// entry point that runs the same kernels over an array<vec4f>.

const TOKEN = /\/\/[^\n]*|\/\*[\s\S]*?\*\/|[A-Za-z_][A-Za-z0-9_]*|\s+|./g;

function isIdentifier(token) {
  return /^[A-Za-z_]/.test(token);
}

function isTrivia(token) {
  return /^\s/.test(token) || token.startsWith("//") || token.startsWith("/*");
}

// Names declared at module scope with `override`, `const` or `fn`, in
// source order, and the names of the `fn` kernels.
function moduleNames(tokens) {
  const names = new Set();
  const kernels = [];
  let depth = 0;
  let declaring = null;
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
    }
  }
  return { names, kernels };
}

// Lists the kernel function names of a kernel source, in the order the
// compiled Tile component applies them.
export function pixelKernelNames(source) {
  return moduleNames(source.match(TOKEN) ?? []).kernels;
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

// A WebGPU compute shader that applies the source's kernels in order to
// each element of `qip_src` and writes `qip_dst`, one invocation per pixel.
export function pixelKernelsToComputeShader(source, workgroupSize = 64) {
  const calls = pixelKernelNames(source).map((name) => `  c = ${name}(c);`);
  return `${source.trim()}

@group(0) @binding(0) var<storage, read> qip_src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> qip_dst: array<vec4f>;

@compute @workgroup_size(${workgroupSize})
fn qip_main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&qip_dst) { return; }
  var c = qip_src[id.x];
${calls.join("\n")}
  qip_dst[id.x] = c;
}
`;
}
