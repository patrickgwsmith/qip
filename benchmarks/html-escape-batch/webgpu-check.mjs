// Runs html_escape_pages.wgsl on WebGPU over the site-static pages and checks
// every page against html-escape.wasm.
// deno run --allow-read --unstable-webgpu benchmarks/html-escape-batch/webgpu-check.mjs
const dir = "benchmarks/html-escape-batch/";
const pagesIn = [];
async function walk(root) {
  for await (const e of Deno.readDir(root)) {
    const p = `${root}/${e.name}`;
    if (e.isDirectory) await walk(p);
    else if (p.endsWith(".html")) pagesIn.push(await Deno.readFile(p));
  }
}
await walk("site-static");

const { instance } = await WebAssembly.instantiate(await Deno.readFile("text/html/html-escape.wasm"));
const e = instance.exports;
const want = pagesIn.map((page) => {
  new Uint8Array(e.memory.buffer, e.input_ptr(), page.length).set(page);
  const r = BigInt.asUintN(64, e.render(page.length));
  return new Uint8Array(e.memory.buffer, Number((r >> 32n) & 0x7fffffffn), Number(r & 0xffffffffn)).slice();
});

const table = new Uint32Array(pagesIn.length * 4);
let inOff = 0, outOff = 0;
pagesIn.forEach((page, p) => {
  table.set([inOff, page.length, outOff, 0], p * 4);
  inOff += (page.length + 3) & ~3;
  outOff += (page.length * 6 + 3) & ~3;
});
const src = new Uint8Array(inOff);
pagesIn.forEach((page, p) => src.set(page, table[p * 4]));

const device = await (await navigator.gpu.requestAdapter()).requestDevice({
  requiredLimits: { maxStorageBufferBindingSize: 64 << 20, maxBufferSize: 64 << 20 },
});
const usage = GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST;
const mk = (size) => device.createBuffer({ size, usage });
const srcBuf = mk(src.length), dstBuf = mk(outOff), pageBuf = mk(table.byteLength);
device.queue.writeBuffer(srcBuf, 0, src);
device.queue.writeBuffer(pageBuf, 0, table);
const module = device.createShaderModule({ code: await Deno.readTextFile(dir + "html_escape_pages.wgsl") });
const info = await module.getCompilationInfo();
for (const m of info.messages) console.log(`${m.type}: ${m.message}`);
const pipeline = device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: "main" } });
const bind = device.createBindGroup({
  layout: pipeline.getBindGroupLayout(0),
  entries: [srcBuf, dstBuf, pageBuf].map((buffer, binding) => ({ binding, resource: { buffer } })),
});
const readDst = device.createBuffer({ size: outOff, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
const readPages = device.createBuffer({ size: table.byteLength, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
const t0 = performance.now();
const enc = device.createCommandEncoder();
const pass = enc.beginComputePass();
pass.setPipeline(pipeline);
pass.setBindGroup(0, bind);
pass.dispatchWorkgroups(Math.ceil(pagesIn.length / 64));
pass.end();
enc.copyBufferToBuffer(dstBuf, 0, readDst, 0, outOff);
enc.copyBufferToBuffer(pageBuf, 0, readPages, 0, table.byteLength);
device.queue.submit([enc.finish()]);
await Promise.all([readDst.mapAsync(GPUMapMode.READ), readPages.mapAsync(GPUMapMode.READ)]);
const ms = performance.now() - t0;
const out = new Uint8Array(readDst.getMappedRange());
const got = new Uint32Array(readPages.getMappedRange());
let bad = 0;
pagesIn.forEach((_, p) => {
  const g = out.subarray(got[p * 4 + 2], got[p * 4 + 2] + got[p * 4 + 3]);
  if (g.length !== want[p].length || g.some((b, i) => b !== want[p][i])) bad++;
});
console.log(`${pagesIn.length} pages, ${bad} differ; one dispatch and readback took ${ms.toFixed(1)} ms`);
if (bad) Deno.exit(1);
