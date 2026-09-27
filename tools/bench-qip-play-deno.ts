const paths = Deno.args;
if (paths.length === 0) {
  console.error("Usage: deno run --allow-read tools/bench-qip-play-deno.ts <module.wasm> [module2.wasm ...]");
  Deno.exit(2);
}

const warmup = Number(Deno.env.get("QIP_PLAY_BENCH_WARMUP") || 20);
const runs = Number(Deno.env.get("QIP_PLAY_BENCH_RUNS") || 120);

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * p) - 1));
  return sorted[idx];
}

function mean(values: number[]): number {
  return values.reduce((acc, n) => acc + n, 0) / values.length;
}

function stddev(values: number[], avg: number): number {
  const variance = values.reduce((acc, n) => {
    const d = n - avg;
    return acc + d * d;
  }, 0) / values.length;
  return Math.sqrt(variance);
}

function requiredExport<T>(exports: WebAssembly.Exports, name: string): T {
  const value = exports[name];
  if (value === undefined) throw new Error(`missing ${name}`);
  return value as T;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const stable = new Uint8Array(bytes.byteLength);
  stable.set(bytes);
  const hash = await crypto.subtle.digest("SHA-256", stable.buffer);
  return [...new Uint8Array(hash)].map((n) => n.toString(16).padStart(2, "0")).join("");
}

async function bench(path: string) {
  const bytes = await Deno.readFile(path);
  const instantiated = await WebAssembly.instantiate(bytes, {});
  const instance = instantiated.instance;
  const exports = instance.exports;

  const memory = requiredExport<WebAssembly.Memory>(exports, "memory");
  const outputBytesCap = requiredExport<() => number>(exports, "output_bytes_cap");
  const outputContentTypePtr = requiredExport<() => number>(exports, "output_content_type_ptr");
  const outputContentTypeSize = requiredExport<() => number>(exports, "output_content_type_size");
  requiredExport<(nowMS: bigint) => void>(exports, "begin_update_at");
  requiredExport<() => bigint>(exports, "finish_update");
  const render = requiredExport<(inputSize: number) => bigint>(exports, "render");

  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(memory.buffer, outputContentTypePtr(), outputContentTypeSize()),
  );
  if (contentType.split(";")[0].trim() !== "image/ktx2") {
    throw new Error(`${path}: qip-play output must be image/ktx2`);
  }

  let packed = render(0);
  if ((packed & 0x8000_0000_0000_0000n) !== 0n) {
    throw new Error(`${path}: initial Content input was rejected`);
  }
  for (let i = 0; i < warmup; i++) packed = render(0);

  const samples: number[] = [];
  for (let i = 0; i < runs; i++) {
    const start = performance.now();
    packed = render(0);
    samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);
  if ((packed & 0x8000_0000_0000_0000n) !== 0n) {
    throw new Error(`${path}: Content input was rejected`);
  }
  const outputLength = Number(packed & 0xffff_ffffn);
  if (outputLength > outputBytesCap()) {
    throw new Error(`${path}: render returned output outside output_bytes_cap`);
  }

  const ptr = Number((packed >> 32n) & 0x7fff_ffffn);
  const output = new Uint8Array(memory.buffer, ptr, outputLength);
  const outputView = new DataView(memory.buffer, ptr, outputLength);
  const avg = mean(samples);
  return {
    path,
    bytes: bytes.byteLength,
    width: outputView.getUint32(20, true),
    height: outputView.getUint32(24, true),
    mean: avg,
    stddev: stddev(samples, avg),
    min: samples[0],
    p50: percentile(samples, 0.5),
    p95: percentile(samples, 0.95),
    max: samples[samples.length - 1],
    sha256: await sha256Hex(output),
  };
}

const results = [];
for (const path of paths) results.push(await bench(path));

const firstHash = results[0].sha256;
const outputsMatch = results.every((r) => r.sha256 === firstHash);
console.log(outputsMatch ? "qip-play deno bench: outputs match" : "qip-play deno bench: outputs differ");
console.log(`  warmup: ${warmup}`);
console.log(`  runs:   ${runs}`);
console.log("");
for (const r of results) {
  console.log(r.path);
  console.log(`  canvas: ${r.width}x${r.height}`);
  console.log(`  wasm:   ${r.bytes} bytes`);
  console.log(`  render: mean ${r.mean.toFixed(3)} ms +/- ${r.stddev.toFixed(3)} ms [min ${r.min.toFixed(3)}, p50 ${r.p50.toFixed(3)}, p95 ${r.p95.toFixed(3)}, max ${r.max.toFixed(3)}]`);
  console.log(`  sha256: ${r.sha256}`);
  console.log("");
}
