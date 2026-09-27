import { readFileSync } from "node:fs";

const [componentPath, inputPath] = process.argv.slice(2);
if (!componentPath || !inputPath) {
  throw new Error("usage: node profile.mjs <component.wasm> <input.txt>");
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

const { instance } = await WebAssembly.instantiate(readFileSync("tui/qipdb.wasm"));
instance.exports.uniform_set_columns(120);
instance.exports.uniform_set_lines(45);
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
    .toString("utf8").replace(/\x1b\[[0-9;]*m/g, "");
}

render(form.length);
for (const [time, key] of [[1n, "f"], [2n, "i"]]) {
  instance.exports.begin_update_at(time);
  instance.exports.key_event(key.charCodeAt(0), 1);
  instance.exports.finish_update();
}
const output = render(0);
for (const line of output.split("\n")) {
  if (/RUNTIME|^MEMORY |OUTPUT succeeded|sha256=|trap unsupported/.test(line)) {
    process.stdout.write(`${line}\n`);
  }
}
