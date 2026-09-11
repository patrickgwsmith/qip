import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const modulePath = new URL(
  "../text/html/html-to-accessibility-tree.wasm",
  import.meta.url,
);

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

function renderText(exports, text) {
  const input = encoder.encode(text);
  const inputPtr = readI32Export(exports, "input_ptr");
  const inputCap = readI32Export(exports, "input_utf8_cap");
  assert.ok(input.length <= inputCap);
  new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);

  const result = decodeRenderResult(exports.render(input.length));
  assert.equal(result.failed, false);
  return decoder.decode(
    new Uint8Array(exports.memory.buffer, result.outputPointer, result.value),
  );
}

test("HTML void elements close without a slash", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));
  const input =
    "<main>" +
    '<area aria-hidden=true><base aria-hidden=true><br aria-hidden=true>' +
    '<col aria-hidden=true><embed aria-hidden=true><hr aria-hidden=true>' +
    '<img alt=Logo><input aria-label=Name><link aria-hidden=true>' +
    '<meta aria-hidden=true><param aria-hidden=true><source aria-hidden=true>' +
    '<track aria-hidden=true><wbr aria-hidden=true>' +
    "<button>After</button>" +
    "</main>";

  assert.equal(
    renderText(instance.exports, input),
    "- `main`\n" +
      "  - `img` **Logo**\n" +
      "  - `textbox` **Name**\n" +
      "  - `button` **After**\n",
  );
});

test("only HTML void elements close themselves", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(
      instance.exports,
      '<main><section aria-label="Section" /><button>Inside</button></section></main>',
    ),
    "- `main`\n" +
      "  - `region` **Section**\n" +
      "    - `button` **Inside**\n",
  );
});

test("void end tags do not pop an open ancestor", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(
      instance.exports,
      '<main><section aria-label=Section></img><button>Inside</button></section></main>',
    ),
    "- `main`\n" +
      "  - `region` **Section**\n" +
      "    - `button` **Inside**\n",
  );
});

test("accessible names follow ARIA and HTML precedence", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(
      instance.exports,
      '<span id=visible>Visible label</span><main><button aria-labelledby=visible aria-label=Override>Text</button><label for=email>Email address</label><input id=email placeholder=Fallback><input type=button value=Save><img alt=Logo></main>',
    ),
    "- `main`\n" +
      "  - `button` **Visible label**\n" +
      "  - `textbox` **Email address**\n" +
      "  - `button` **Save**\n" +
      "  - `img` **Logo**\n",
  );
});

test("locked names do not leak descendant text to ancestors", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(
      instance.exports,
      '<main><button aria-label=Save>Visible label</button><button alt=Wrong>Right</button></main>',
    ),
    "- `main`\n" +
      "  - `button` **Save**\n" +
      "  - `button` **Right**\n",
  );
});

test("optional end tags produce sibling accessibility nodes", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(instance.exports, "<ul><li>One<li>Two</ul>"),
    "- `list`\n" +
      "  - `listitem` **One**\n" +
      "  - `listitem` **Two**\n",
  );
});

test("role fallback, aria-hidden tokens, landmarks, and markdown escaping", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(
      instance.exports,
      '<header>Top</header><main><header><h2>Nested</h2></header><div role="bogus button">Save *now*</div><div aria-hidden><button>Visible</button></div><div aria-hidden=1><button>Also visible</button></div></main>',
    ),
    "- `banner`\n" +
      "- `main`\n" +
      "  - `heading` **Nested**\n" +
      "  - `button` **Save \\*now\\***\n" +
      "  - `button` **Visible**\n" +
      "  - `button` **Also visible**\n",
  );
});

test("ARIA references and HTML naming sources follow their precedence", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));

  assert.equal(
    renderText(
      instance.exports,
      '<span id=hidden hidden>Hidden reference</span><span id=one>First</span><span id=empty></span><main><button aria-labelledby="one hidden one" aria-label=Fallback>Text</button><button aria-labelledby=empty aria-label=Fallback>Text</button><label>Wrapped <input></label><input type=image alt=Upload><input type=submit><input type=reset><textarea placeholder=Notes></textarea></main>',
    ),
    "- `main`\n" +
      "  - `button` **First Hidden reference**\n" +
      "  - `button`\n" +
      "  - `textbox` **Wrapped**\n" +
      "  - `button` **Upload**\n" +
      "  - `button` **Submit**\n" +
      "  - `button` **Reset**\n" +
      "  - `textbox` **Notes**\n",
  );
});

test("hidden descendants are excluded and names stay valid UTF-8 when capped", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));
  const longName = "a".repeat(191) + "😀";

  assert.equal(
    renderText(
      instance.exports,
      `<main><button>Show <span aria-hidden=true>Secret</span><img alt=Icon></button><button aria-label="${longName}">Ignored</button></main>`,
    ),
    "- `main`\n" +
      "  - `button` **Show Icon**\n" +
      "    - `img` **Icon**\n" +
      `  - \`button\` **${"a".repeat(191)}**\n`,
  );
});
