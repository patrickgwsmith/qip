// Runs bench-core.mjs in Deno, which has WebGPU. From the repository root:
//
//   deno run --allow-read --unstable-webgpu benchmarks/wgsl-rot13/bench.mjs [--runs=30]
//
// Deno resolves each GPU submission by polling, which adds about 13 ms per
// round trip on macOS. Use bench.html for browser WebGPU timings.
import { runBenchmark } from "./bench-core.mjs";

const root = new URL("../../", import.meta.url);
const runs = Number(Deno.args.find((a) => a.startsWith("--runs="))?.slice(7) ?? 30);
await runBenchmark({
  read: (p) => Deno.readFile(new URL(p, root)),
  log: (line) => console.log(line),
  runs,
  runtime: `Deno ${Deno.version.deno}, V8 ${Deno.version.v8}, ${Deno.build.os} ${Deno.build.arch}`,
});
