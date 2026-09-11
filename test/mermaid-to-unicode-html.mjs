import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runComplianceComponent } from "./lib/compliance-harness.mjs";

const moduleUrl = new URL(
  "../text/vnd.mermaid/mermaid-to-unicode-html.wasm",
  import.meta.url,
);
const complianceUrl = new URL(
  "../compliance/mermaid-to-unicode-html.comply.wasm",
  import.meta.url,
);
const [moduleBytes, complianceBytes] = await Promise.all([
  readFile(moduleUrl),
  readFile(complianceUrl),
]);

function readString(exports, ptrName, sizeName) {
  return Buffer.from(
    exports.memory.buffer,
    exports[ptrName](),
    exports[sizeName](),
  ).toString();
}

function render(exports, input) {
  new Uint8Array(
    exports.memory.buffer,
    exports.input_ptr(),
    input.length,
  ).set(input);
  const outputSize = qipRenderSize(exports, input.length);
  return Buffer.from(
    exports.memory.buffer,
    qipRenderedOutputPointer(exports),
    outputSize,
  );
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

// Hashes below pin byte-for-byte HTML from Simon Willison's published WASM.

test("declares Mermaid input and HTML output", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  assert.equal(
    readString(instance.exports, "input_content_type_ptr", "input_content_type_size"),
    "text/vnd.mermaid",
  );
  assert.equal(
    readString(instance.exports, "output_content_type_ptr", "output_content_type_size"),
    "text/html",
  );
});

test("one instance satisfies every equality case across repeated renders", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  for (const entry of cases.filter((entry) => entry.expected !== null)) {
    assert.deepEqual(render(instance.exports, entry.input), entry.expected);
  }
});

test("invalid UTF-8 traps", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  assert.throws(() => render(instance.exports, Buffer.from([0xc3, 0x28])));
});

test("flowcharts render bounded retry edges", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  const input = Buffer.from(`graph TD
    Start[Empty input] --> Journey{Journey valid?}
    Journey -->|yes| Answers{Answers valid?}
    Journey -->|no| JourneyError[Journey error and retry]
    Answers -->|yes| Check(Check availability)
    Answers -->|no| AnswerError[Prompt error and retry]
    Check -.-> Failed[Route suspended and restart]
    Check ==> Complete[Complete and buy ticket]
    JourneyError -->|retry journey| Journey
    AnswerError -->|retry answer| Answers`);
  const output = render(instance.exports, input).toString();
  assert.match(output, /retry journey/);
  assert.match(output, /retry answer/);
  assert.match(output, /▶/);
});

test("flowcharts accept Mermaid minimum-length solid arrows", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  const ordinary = Buffer.from(`flowchart TD
    A[Start] --> B{Is it?}
    B -->|Yes| C[OK]
    C --> D[Rethink]
    D --> B
    B -->|No| E[End]`);
  const oneExtra = Buffer.from(`flowchart TD
    A[Start] --> B{Is it?}
    B -->|Yes| C[OK]
    C --> D[Rethink]
    D --> B
    B --->|No| E[End]`);
  const twoExtra = Buffer.from(`flowchart TD
    A[Start] --> B{Is it?}
    B -->|Yes| C[OK]
    C --> D[Rethink]
    D --> B
    B ---->|No| E[End]`);
  const expected = render(instance.exports, ordinary);
  assert.deepEqual(render(instance.exports, oneExtra), expected);
  assert.deepEqual(render(instance.exports, twoExtra), expected);
  assert.equal(sha256(expected), "e7a3f66acc1f23f5660daacf28c021e0a1e71f36a1c7a8c379eea0d4128e9458");
});

test("state diagrams render Mermaid's cyclic Still example", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  const input = Buffer.from(`stateDiagram-v2
    [*] --> Still
    Still --> [*]
    Still --> Moving
    Moving --> Still
    Moving --> Crash
    Crash --> [*]`);
  const output = render(instance.exports, input).toString();
  assert.match(output, /Still/);
  assert.match(output, /Moving/);
  assert.match(output, /Crash/);
  assert.match(output, /◄/);
  assert.equal(sha256(output), "d7836c4b0343bf1968455763f69a3cb8d34e20993cee295587b02d08b13c538c");
});

test("flowcharts render sixteen nodes with independent retries", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  const input = Buffer.from(`graph TD
    Origin[Choose origin] --> Destination{Destination valid?}
    Destination -->|yes| Date(Choose date)
    Destination -->|no| DestinationError[Destination error]
    Date --> Service(Choose service)
    Service --> Seat{Seat selected?}
    Seat -->|yes| Passenger{Passenger name valid?}
    Seat -->|no| SeatError[Seat error]
    Passenger -->|yes| Baggage{Baggage selected?}
    Passenger -->|no| PassengerError[Passenger error]
    Baggage -->|yes| Route{Route operating?}
    Baggage -->|no| BaggageError[Baggage error]
    Route -->|yes| Availability{Service available?}
    Route -->|no| Failed[Terminal failure and restart]
    Availability -->|yes| Complete[Complete and buy ticket]
    Availability -->|no| ServiceError[Service error]
    DestinationError -->|retry| Destination
    SeatError -->|retry| Seat
    PassengerError -->|retry| Passenger
    BaggageError -->|retry| Baggage
    ServiceError -->|retry| Service`);
  const output = render(instance.exports, input).toString();
  assert.match(output, /Choose origin/);
  assert.match(output, /Complete and buy ticket/);
  const plain = output.replace(/<[^>]+>/g, "");
  assert.equal(plain.match(/retry/g)?.length, 5);
  assert.equal(Math.max(...plain.split("\n").map((line) => [...line].length)), 115);
  assert.equal(sha256(output), "f5076a7d3b30ef20824b3933914ebfb76c52fd680c060cda7b86978cf63aab8c");
});

test("flowcharts reject a seventeenth node", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  const input = Buffer.from(`graph TD
    N01 --> N02
    N02 --> N03
    N03 --> N04
    N04 --> N05
    N05 --> N06
    N06 --> N07
    N07 --> N08
    N08 --> N09
    N09 --> N10
    N10 --> N11
    N11 --> N12
    N12 --> N13
    N13 --> N14
    N14 --> N15
    N15 --> N16
    N16 --> N17`);
  assert.throws(() => render(instance.exports, input));
});

test("renderer stays substantially smaller than the 163 KB reference", () => {
  assert.ok(moduleBytes.length < 33 * 1024, `module grew to ${moduleBytes.length} bytes`);
});
