// Run a Content component on one input inside qipdb and print the full screen.
// usage: node profile.mjs <component.wasm> <input> [lines]
import { readFileSync } from "node:fs";

const [componentPath, inputPath, linesArg] = process.argv.slice(2);
if (!componentPath || !inputPath) {
  throw new Error("usage: node profile.mjs <component.wasm> <input> [lines]");
}

const boundary = "uuid-00000000-0000-0000-0000-000000000000";
function multipart(parts) {
  const chunks = [];
  for (const [name, body] of parts) {
    chunks.push(
      Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"; filename="${name}"\r\nContent-Type: application/octet-stream\r\n\r\n`),
      Buffer.from(body),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

const qipdb = new URL("../../tui/qipdb.wasm", import.meta.url);
const { instance } = await WebAssembly.instantiate(readFileSync(qipdb));
instance.exports.uniform_set_columns(160);
instance.exports.uniform_set_lines(Number(linesArg ?? 400));
const form = multipart([
  ["component", readFileSync(componentPath)],
  ["input", readFileSync(inputPath)],
]);
new Uint8Array(instance.exports.memory.buffer, instance.exports.input_ptr(), form.length).set(form);

function render(size) {
  const result = instance.exports.render(size);
  if (result >> 63n) throw new Error("qipdb rejected the input");
  const pointer = Number(result >> 32n);
  const length = Number(result & 0xffff_ffffn);
  return Buffer.from(new Uint8Array(instance.exports.memory.buffer, pointer, length))
    .toString("utf8").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
}

render(form.length);
// Loading resets the 1M default budget; raise it to the maximum afterwards.
instance.exports.uniform_set_instruction_budget(100_000_000);
// "f" runs to completion, "i" collapses the instruction view.
for (const [time, key] of [[1n, "f"], [2n, "i"]]) {
  instance.exports.begin_update_at(time);
  instance.exports.key_event(key.charCodeAt(0), 1);
  instance.exports.finish_update();
}
process.stdout.write(render(0).replace(/[ \t]+$/gm, "").trimEnd() + "\n");
