import { readFile } from "node:fs/promises";

const [fixturePath, modulePath] = process.argv.slice(2);
if (!fixturePath || !modulePath) {
  console.error("usage: node tools/check-unicode-nfc.mjs NormalizationTest.txt module.wasm");
  process.exit(2);
}

const [fixture, moduleBytes] = await Promise.all([
  readFile(fixturePath, "utf8"),
  readFile(modulePath),
]);
if (!fixture.includes("NormalizationTest-17.0.0.txt")) {
  throw new Error("expected the Unicode 17.0.0 normalization test suite");
}

const { instance } = await WebAssembly.instantiate(moduleBytes);
const component = instance.exports;
const readI32 = (name) => typeof component[name] === "function"
  ? component[name]()
  : component[name].value;
const inputPointer = readI32("input_ptr");
const inputCapacity = readI32("input_utf8_cap");

function utf8(sequence) {
  const text = sequence.trim().split(/ +/)
    .filter(Boolean)
    .map((hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .join("");
  return Buffer.from(text, "utf8");
}

function normalize(input) {
  if (input.byteLength > inputCapacity) throw new RangeError("test input exceeds component capacity");
  new Uint8Array(component.memory.buffer, inputPointer, input.byteLength).set(input);
  const packed = BigInt.asUintN(64, component.render(input.byteLength));
  if (packed >> 63n) throw new Error("component rejected a conformance input");
  const outputLength = Number(packed & 0xffff_ffffn);
  const outputPointer = Number((packed >> 32n) & 0x7fff_ffffn);
  return Buffer.from(new Uint8Array(component.memory.buffer, outputPointer, outputLength));
}

let relationships = 0;
let failureCount = 0;
const failures = [];
for (const line of fixture.split("\n")) {
  if (!/^[0-9A-F]/.test(line)) continue;
  const columns = line.split(";").slice(0, 5).map(utf8);
  const cases = [
    [columns[0], columns[1]],
    [columns[1], columns[1]],
    [columns[2], columns[1]],
    [columns[3], columns[3]],
    [columns[4], columns[3]],
  ];
  for (const [input, expected] of cases) {
    relationships++;
    if (!normalize(input).equals(expected)) {
      failureCount++;
      if (failures.length < 20) failures.push(line);
    }
  }
}

if (failureCount > 0) {
  console.error(`FAIL ${modulePath}: ${failureCount}/${relationships} NFC relationships failed`);
  for (const line of failures) console.error(`  ${line}`);
  process.exit(1);
}
console.log(`PASS ${modulePath}: ${relationships} Unicode 17.0.0 NFC relationships`);
