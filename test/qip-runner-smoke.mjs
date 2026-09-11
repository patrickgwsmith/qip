import { readFile } from "node:fs/promises";
import {
  contentComponent,
  contentRecipe,
  contentTypeBytes,
  contentTypeUTF8,
} from "../site/qip-runner.js";

const text = contentTypeUTF8();
const markdown = contentTypeUTF8("text/markdown");
const html = contentTypeUTF8("text/html");
const bytes = contentTypeBytes();
const bmp = contentTypeBytes("image/bmp");
const multipart = contentTypeBytes(
  "multipart/form-data;boundary=uuid-12345678-90ab-cdef-1234-567890abcdef",
);

if (!Object.isFrozen(text) || !Object.isFrozen(bmp)) {
  throw new Error("content type constructors must return frozen objects");
}
if (
  text.contentType !== undefined ||
  bmp.contentType !== "image/bmp" ||
  multipart.contentType !== "multipart/form-data;boundary=uuid-12345678-90ab-cdef-1234-567890abcdef"
) {
  throw new Error("content type constructors returned incorrect contracts");
}

const trim = contentComponent(text, (value) => value.trim(), text);
if (trim(" hi ") !== "hi") {
  throw new Error("JavaScript text component failed");
}

const byteEcho = contentComponent(bytes, (value) => value, bytes);
const echoed = byteEcho(new Uint8Array([1, 2]));
if (!(echoed instanceof Uint8Array) || echoed[1] !== 2) {
  throw new Error("JavaScript byte component failed");
}

const textAsBytes = contentRecipe(text, [trim, byteEcho], bytes);
const encodedText = textAsBytes(" hi ");
if (!(encodedText instanceof Uint8Array) || new TextDecoder().decode(encodedText) !== "hi") {
  throw new Error("contentRecipe did not safely widen UTF-8 to raw bytes");
}

const bytesToGenericText = contentComponent(bytes, () => "", text);
const htmlIdentity = contentComponent(html, (value) => value, html);
let rejectedMissingMIMEType = false;
try {
  contentRecipe(bytes, [bytesToGenericText, htmlIdentity], html);
} catch {
  rejectedMissingMIMEType = true;
}
if (!rejectedMissingMIMEType) {
  throw new Error("contentRecipe implicitly coerced an unspecified MIME type to text/html");
}

let rejectedBytesToUTF8 = false;
try {
  contentRecipe(bytes, [byteEcho, trim], text);
} catch {
  rejectedBytesToUTF8 = true;
}
if (!rejectedBytesToUTF8) {
  throw new Error("contentRecipe implicitly coerced raw bytes to UTF-8");
}

const identity = contentRecipe(text, [], text);
if (identity("ok") !== "ok") {
  throw new Error("empty contentRecipe should act as identity");
}

let rejectedBadContract = false;
try {
  contentRecipe({}, [], text);
} catch {
  rejectedBadContract = true;
}
if (!rejectedBadContract) {
  throw new Error("contentRecipe accepted a plain object as a content contract");
}

const forgedComponent = (value) => value;
forgedComponent.input = {};
forgedComponent.output = {};
let rejectedForgedComponent = false;
try {
  contentRecipe(text, [forgedComponent], text);
} catch {
  rejectedForgedComponent = true;
}
if (!rejectedForgedComponent) {
  throw new Error("contentRecipe accepted plain-object component contracts");
}

for (const constructor of [contentTypeUTF8, contentTypeBytes]) {
  for (const contentType of [
    "Text/HTML",
    "text/html; charset=utf-8",
    " text/html",
    "multipart/form-data; boundary=uuid-12345678-90ab-cdef-1234-567890abcdef",
    "multipart/form-data;boundary=qip-12345678-90ab-cdef-1234-567890abcdef",
    "multipart/form-data;boundary=uuid-12345678-90AB-cdef-1234-567890abcdef",
  ]) {
    let rejectedBadContentType = false;
    try {
      constructor(contentType);
    } catch {
      rejectedBadContentType = true;
    }
    if (!rejectedBadContentType) {
      throw new Error(constructor.name + " accepted invalid content type " + contentType);
    }
  }
}

const markdownModule = await WebAssembly.compile(
  await readFile("text/markdown/commonmark.0.31.2.wasm"),
);
const pageModule = await WebAssembly.compile(
  await readFile("text/html/html-page-wrap.wasm"),
);
const formDataToTarModule = await WebAssembly.compile(
  await readFile("multipart/form-data/form-data-to-tar.wasm"),
);
contentComponent(
  contentTypeBytes("multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000"),
  formDataToTarModule,
  contentTypeBytes("application/x-tar"),
);

const markdownToHtml = contentComponent(markdown, markdownModule, html);
const htmlPageWrap = contentComponent(html, pageModule, html);
const renderPage = contentRecipe(markdown, [trim, markdownToHtml, htmlPageWrap], html);
const page = renderPage(" # qip ");

if (typeof page !== "string" || !page.includes("<html")) {
  throw new Error("Wasm-backed contentRecipe failed");
}

const htmlEscapeModule = await WebAssembly.compile(
  await readFile("text/html/html-escape.wasm"),
);
const cHighlightModule = await WebAssembly.compile(
  await readFile("text/html/html-code-syntax-highlight-c.wasm"),
);
const escapeHTML = contentComponent(text, htmlEscapeModule, html);
const highlightC = contentComponent(html, cHighlightModule, html);
const highlightedC = highlightC(
  '<pre><code class="language-c">' +
    escapeHTML("int main(void) { return 0; }") +
    "</code></pre>",
);

if (!highlightedC.includes("hljs-keyword")) {
  throw new Error("generic text to syntax-highlighted HTML pipeline failed");
}

const accessibilityTreeModule = await WebAssembly.compile(
  await readFile("text/html/html-to-accessibility-tree.wasm"),
);
const accessibilityTree = contentComponent(
  html,
  accessibilityTreeModule,
  markdown,
);
if (accessibilityTree("<main><button>Save</button></main>") !==
    "- `main`\n  - `button` **Save**\n") {
  throw new Error("HTML to Markdown accessibility-tree component failed");
}

const luhnModule = await WebAssembly.compile(
  await readFile("text/luhn.wasm"),
);
const luhn = contentComponent(text, luhnModule, text);
if (luhn(" 4992-7398 716 ") !== "49927398716") {
  throw new Error("Wasm-backed component did not accept valid output");
}
let rejected = false;
try {
  luhn("49927398717");
} catch (error) {
  rejected = /component rejected input at input offset 11/.test(error.message);
}
if (!rejected) {
  throw new Error("Wasm-backed component did not report input rejection");
}
