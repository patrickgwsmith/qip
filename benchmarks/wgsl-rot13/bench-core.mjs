// Host-neutral ROT13 benchmark: WebGPU against the same WGSL compiled to
// wasm, and a hand-written Zig SIMD wasm baseline. See bench.mjs (Deno) and
// bench.html (browser).
//
// Every timing is end to end for one request on warmed, reused resources:
// wasm copies input in, calls render and copies output out; WebGPU writes the
// input buffer, dispatches, copies to a staging buffer, maps it and copies the
// result out. Every output is checked against the Zig baseline.

// The site's largest markdown pages, repeated to fill each input.
export const CORPUS_FILES = [
  "site/wgsl.md",
  "site/svg-dom-update-benchmark.md",
  "site/flurry.md",
  "site/component-debugger.md",
  "site/recipes.md",
  "site/tui.md",
];

const WASM_CAP = 4 * 1024 * 1024;
const DISPATCH_BYTES = 65535 * 64 * 4; // the most one dispatch can cover with 64-wide workgroups

// `read(path)` returns bytes for a repo-relative path; `log` prints a line.
export async function runBenchmark({ read, log, runs: RUNS = 30, runtime = "" }) {
  const parts = await Promise.all(CORPUS_FILES.map(read));
  function corpus(size) {
    const out = new Uint8Array(size);
    let o = 0;
    while (o < size) {
      for (const p of parts) {
        const n = Math.min(p.length, size - o);
        out.set(p.subarray(0, n), o);
        o += n;
        if (o === size) break;
      }
    }
    return out;
  }

  async function loadWasm(name) {
    const bytes = await read(`benchmarks/wgsl-rot13/${name}`);
    const { instance } = await WebAssembly.instantiate(bytes, {});
    const e = instance.exports;
    const inPtr = e.input_ptr();
    return (input) => {
      // `input` may exceed the 4 MiB capacity; process it as 4 MiB requests.
      const out = new Uint8Array(input.length);
      for (let o = 0; o < input.length; o += WASM_CAP) {
        const chunk = input.subarray(o, o + WASM_CAP);
        new Uint8Array(e.memory.buffer, inPtr, chunk.length).set(chunk);
        const r = e.render(chunk.length);
        const len = Number(r & 0xffffffffn);
        const ptr = Number((r >> 32n) & 0x7fffffffn);
        if (r >> 63n) throw new Error(`${name} rejected input`);
        out.set(new Uint8Array(e.memory.buffer, ptr, len), o);
      }
      return out;
    };
  }

  async function makeGpu(maxBytes) {
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter) throw new Error("no WebGPU adapter");
    const hasTimestamps = adapter.features.has("timestamp-query");
    const device = await adapter.requestDevice({
      requiredFeatures: hasTimestamps ? ["timestamp-query"] : [],
      requiredLimits: {
        maxBufferSize: Math.min(adapter.limits.maxBufferSize, maxBytes),
        maxStorageBufferBindingSize: Math.min(adapter.limits.maxStorageBufferBindingSize, DISPATCH_BYTES),
      },
    });
    const code = new TextDecoder().decode(await read("benchmarks/wgsl-rot13/rot13.wgsl"));
    const module = device.createShaderModule({ code });
    const pipeline = device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: "main" } });
    const src = device.createBuffer({ size: maxBytes, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    const dst = device.createBuffer({ size: maxBytes, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
    const staging = device.createBuffer({ size: maxBytes, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
    const querySet = hasTimestamps ? device.createQuerySet({ type: "timestamp", count: 2 }) : null;
    const queryBuf = hasTimestamps
      ? device.createBuffer({ size: 16, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC })
      : null;
    const queryRead = hasTimestamps
      ? device.createBuffer({ size: 16, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST })
      : null;
    const groupCache = new Map();
    const bindGroup = (offset, size) => {
      const key = `${offset}:${size}`;
      let g = groupCache.get(key);
      if (!g) {
        g = device.createBindGroup({
          layout: pipeline.getBindGroupLayout(0),
          entries: [
            { binding: 0, resource: { buffer: src, offset, size } },
            { binding: 1, resource: { buffer: dst, offset, size } },
          ],
        });
        groupCache.set(key, g);
      }
      return g;
    };

    // Returns the output and the GPU-side kernel time in ms (or NaN).
    async function run(input, { timestamps = false } = {}) {
      const n = input.length;
      device.queue.writeBuffer(src, 0, input);
      const enc = device.createCommandEncoder();
      const ts = timestamps && querySet;
      const pass = enc.beginComputePass(
        ts ? { timestampWrites: { querySet, beginningOfPassWriteIndex: 0, endOfPassWriteIndex: 1 } } : {},
      );
      pass.setPipeline(pipeline);
      for (let o = 0; o < n; o += DISPATCH_BYTES) {
        const size = Math.min(DISPATCH_BYTES, n - o);
        pass.setBindGroup(0, bindGroup(o, size));
        pass.dispatchWorkgroups(Math.ceil(size / 4 / 64));
      }
      pass.end();
      enc.copyBufferToBuffer(dst, 0, staging, 0, n);
      if (ts) {
        enc.resolveQuerySet(querySet, 0, 2, queryBuf, 0);
        enc.copyBufferToBuffer(queryBuf, 0, queryRead, 0, 16);
      }
      device.queue.submit([enc.finish()]);
      await staging.mapAsync(GPUMapMode.READ, 0, n);
      const out = new Uint8Array(staging.getMappedRange(0, n)).slice();
      staging.unmap();
      let kernelMs = NaN;
      if (ts) {
        await queryRead.mapAsync(GPUMapMode.READ);
        const t = new BigUint64Array(queryRead.getMappedRange());
        kernelMs = Number(t[1] - t[0]) / 1e6;
        queryRead.unmap();
      }
      return { out, kernelMs };
    }
    const info = adapter.info ?? {};
    return { run, hasTimestamps, name: [info.vendor, info.architecture, info.device, info.description].filter(Boolean).join(" ") };
  }

  function stats(samples) {
    const s = [...samples].sort((a, b) => a - b);
    const mean = s.reduce((a, b) => a + b, 0) / s.length;
    return { mean, min: s[0], p50: s[Math.floor(s.length / 2)], p95: s[Math.min(s.length - 1, Math.floor(s.length * 0.95))] };
  }

  function equal(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  // Each sample repeats `fn` until it has run for at least 2 ms, so that
  // coarse browser timers still resolve sub-millisecond calls.
  async function time(fn, runs) {
    for (let i = 0; i < 3; i++) await fn(); // warm up
    let reps = 0;
    const c0 = performance.now();
    while (performance.now() - c0 < 2) {
      await fn();
      reps++;
    }
    const t = [];
    for (let i = 0; i < runs; i++) {
      const t0 = performance.now();
      for (let r = 0; r < reps; r++) await fn();
      t.push((performance.now() - t0) / reps);
    }
    return stats(t);
  }

  const KiB = 1024, MiB = 1024 * KiB;
  // [label, bytes per input, inputs]. A batch is one GPU submission over the
  // concatenated inputs, and one wasm render per input.
  const cases = [
    ["4 KiB", 4 * KiB, 1],
    ["64 KiB", 64 * KiB, 1],
    ["1 MiB", MiB, 1],
    ["4 MiB", 4 * MiB, 1],
    ["153 × 8 KiB pages", 8 * KiB, 153],
    ["16 MiB", 4 * MiB, 4],
    ["64 MiB", 4 * MiB, 16],
    ["128 MiB", 4 * MiB, 32],
  ];
  const maxBytes = Math.max(...cases.map(([, b, n]) => b * n));
  const text = corpus(maxBytes);

  const zig = await loadWasm("rot13_zig_simd.wasm");
  const wgslScalar = await loadWasm("rot13_wgsl.wasm");
  const wgslVec = await loadWasm("rot13_wgsl_vec4.wasm");
  const gpu = await makeGpu(maxBytes);

  log(runtime);
  log(`GPU adapter: ${gpu.name || "(no info)"}; timestamp-query: ${gpu.hasTimestamps}`);
  log(`${RUNS} measured runs per case after 3 warm-ups; times in ms (mean / p95)\n`);

  const fmt = (s) => `${s.mean.toFixed(3)} / ${s.p95.toFixed(3)}`;
  const rows = [];
  for (const [label, per, count] of cases) {
    const input = text.subarray(0, per * count);
    const want = zig(input);
    // The batch case runs one wasm render per page, and one GPU dispatch for all.
    const perInput = (f) => () => {
      for (let o = 0; o < input.length; o += per) f(input.subarray(o, o + per));
    };
    for (const [n, f] of [["wgsl scalar", wgslScalar], ["wgsl vec4", wgslVec]]) {
      if (!equal(f(input), want)) throw new Error(`${n} mismatch at ${label}`);
    }
    const g = await gpu.run(input, { timestamps: true });
    if (!equal(g.out, want)) throw new Error(`GPU mismatch at ${label}`);

    const runs = input.length >= 64 * MiB ? Math.max(5, Math.floor(RUNS / 3)) : RUNS;
    const r = {
      label,
      zig: await time(perInput(zig), runs),
      scalar: await time(perInput(wgslScalar), runs),
      vec: await time(perInput(wgslVec), runs),
      gpu: await time(() => gpu.run(input), runs),
    };
    const kernel = [];
    for (let i = 0; i < Math.min(runs, 10); i++) kernel.push((await gpu.run(input, { timestamps: true })).kernelMs);
    r.kernel = stats(kernel);
    rows.push(r);
    log(
      `${label.padEnd(18)} zig-simd ${fmt(r.zig)} | wgsl→wasm ${fmt(r.scalar)} | wgsl→wasm vec4 ${fmt(r.vec)} | ` +
        `WebGPU ${fmt(r.gpu)} (kernel ${r.kernel.mean.toFixed(3)})`,
    );
  }

  log("\n| Input | Zig SIMD wasm | WGSL→wasm | WGSL→wasm vec4 | WebGPU end to end | WebGPU kernel only | GPU vs best wasm |");
  log("| --- | ---: | ---: | ---: | ---: | ---: | ---: |");
  for (const r of rows) {
    const best = Math.min(r.zig.mean, r.scalar.mean, r.vec.mean);
    const ratio = r.gpu.mean / best;
    const verdict = ratio > 1 ? `${ratio.toFixed(1)}× slower` : `${(1 / ratio).toFixed(1)}× faster`;
    log(
      `| ${r.label} | ${r.zig.mean.toFixed(3)} | ${r.scalar.mean.toFixed(3)} | ${r.vec.mean.toFixed(3)} | ` +
        `${r.gpu.mean.toFixed(3)} | ${Number.isNaN(r.kernel.mean) ? "n/a" : r.kernel.mean.toFixed(3)} | ${verdict} |`,
    );
  }
  return rows;
}
