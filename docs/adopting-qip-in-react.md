# Adopting QIP In React

You can add QIP to an existing React application without replacing React,
Next.js, routing, authentication, storage, or deployment. Start with one
bounded operation. The application passes bytes to a WebAssembly component and
uses the returned bytes as normal application data.

This guide adds the existing TSX syntax highlighter to a Next.js application.
The server highlights a fixed example while Next.js prerenders the page. The
browser runs the same `.wasm` file again as the user edits TSX.

The complete, tested application is in
[examples/nextjs-qip](https://github.com/royalicing/qip/tree/main/examples/nextjs-qip).

## What Changes

Replace one library call or application helper with a call across the QIP
Content contract:

```text
before: React application → library function → string

after:  React application → QIP component.wasm → string
```

The application still owns data loading, permissions, errors, and the place
where it displays or stores the result. The QIP component receives only the
input bytes that the wrapper writes into its memory.

## Run The Example

From the repository root:

```bash
cd examples/nextjs-qip
npm install
npm test
npm run build
npm run dev
```

Open `http://localhost:3000`. The first highlighted block comes from a cached
Server Component. Edit the second block to see the Client Component run in the
browser.

The example's preparation script copies
`components/text/html/html-code-syntax-highlight-tsx.wasm` to
`public/qip-components/`. A real application can put a reviewed component in
its own public or server asset directory instead.

## Wrap The Content Contract

React does not need a QIP-specific package. A small wrapper writes UTF-8 into
component memory, calls `render`, and decodes the returned bytes:

```js
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function decodeRenderResult(value) {
  const bits = BigInt.asUintN(64, value);
  if ((bits >> 63n) !== 0n) {
    throw new Error("component rejected input");
  }

  return {
    outputPtr: Number((bits >> 32n) & 0x7fff_ffffn),
    outputSize: Number(bits & 0xffff_ffffn),
  };
}

export function createTextRenderer(exports) {
  const { memory, input_ptr, input_utf8_cap, render } = exports;

  return function renderText(source) {
    const input = new Uint8Array(
      memory.buffer,
      input_ptr(),
      input_utf8_cap(),
    );
    const { read, written } = encoder.encodeInto(source, input);

    if (read !== source.length) {
      throw new RangeError("input exceeds component capacity");
    }

    const { outputPtr, outputSize } = decodeRenderResult(render(written));
    return decoder.decode(
      new Uint8Array(memory.buffer, outputPtr, outputSize),
    );
  };
}
```

`read` counts JavaScript UTF-16 code units. `written` counts UTF-8 bytes. Pass
`written` to `render` and check that `read` consumed the complete string.

The highlighter accepts `text/html`, not raw TSX. The example adds a second
small wrapper which escapes the source and puts it in a
`<code class="language-tsx">` element. Both execution paths use these wrappers
from `lib/qip-content.js`.

```js
function escapeHTML(source) {
  return source
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

export function createTSXHighlighter(exports) {
  const renderHTML = createTextRenderer(exports);

  return function highlightTSX(source) {
    const code = escapeHTML(source);
    return renderHTML(
      `<pre><code class="language-tsx">${code}</code></pre>`,
    );
  };
}
```

## Run It In A Server Component

Enable [Cache Components](https://nextjs.org/docs/app/getting-started/caching)
in `next.config.js`:

```js
const nextConfig = {
  cacheComponents: true,
};

export default nextConfig;
```

Then load the module once from the server's filesystem. The exported async
function uses Next.js's [`use cache`](https://nextjs.org/docs/app/api-reference/directives/use-cache)
directive, and its source argument becomes part of the cache key:

```js
import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";
import { cacheLife } from "next/cache";

import { createTSXHighlighter } from "./qip-content.js";

const componentPath = path.join(
  process.cwd(),
  "public",
  "qip-components",
  "html-code-syntax-highlight-tsx.wasm",
);
const module = new WebAssembly.Module(readFileSync(componentPath));
const instance = new WebAssembly.Instance(module, {});
const highlight = createTSXHighlighter(instance.exports);

export async function highlightTSX(source) {
  "use cache";
  cacheLife("max");
  return highlight(source);
}
```

Await the cached function in a Server Component:

```jsx
import { highlightTSX } from "../lib/tsx-server.js";

const source = `export function Greeting({ name }) {
  return <button>Hello, {name}!</button>;
}`;

export default async function Page() {
  const html = await highlightTSX(source);
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
```

`cacheLife("max")` makes the lifetime explicit. Because this call has a fixed
argument during prerendering, its result becomes part of the static page. A
different source string has a different cache entry. For a one-off fixed value,
Next.js can also prerender the synchronous computation without `use cache`.
The directive is useful here because it shows how to reuse results when several
pages highlight the same source.

## Run It In A Client Component

The browser can fetch the same file and create its own instance:

```jsx
"use client";

import { useEffect, useState } from "react";
import { createTSXHighlighter } from "../lib/qip-content.js";

let highlighterPromise;

function loadHighlighter() {
  highlighterPromise ??= WebAssembly.instantiateStreaming(
    fetch("/qip-components/html-code-syntax-highlight-tsx.wasm"),
    {},
  ).then(({ instance }) => createTSXHighlighter(instance.exports));
  return highlighterPromise;
}

export function TSXEditor({ initialValue }) {
  const [source, setSource] = useState(initialValue);
  const [highlight, setHighlight] = useState(null);

  useEffect(() => {
    loadHighlighter().then((loaded) => setHighlight(() => loaded));
  }, []);

  const html = highlight ? highlight(source) : "";

  return (
    <>
      <textarea
        value={source}
        onChange={(event) => setSource(event.target.value)}
      />
      {html ? <div dangerouslySetInnerHTML={{ __html: html }} /> : "Loading…"}
    </>
  );
}
```

`instantiateStreaming` requires the server to return the file with
`Content-Type: application/wasm`. Next.js serves a `.wasm` file from `public`
with this type.

The module-level promise prevents each React render from loading another copy.
Each browser tab still creates its own component instance. Highlighting after
each keystroke is synchronous and does not need an Effect or server request.

## Choose The Server Or Browser

| Run on the server when | Run in the browser when |
| --- | --- |
| The result controls acceptance, storage, or publication. | The result is a preview or presentation detail. |
| The input contains server-side or shared private data. | A local value or file should stay on the user's device. |
| The initial response needs the result. | The interaction needs immediate updates. |
| All clients need one canonical result. | Offline operation is useful. |

You can use both. Run the component in the browser for an immediate preview,
then run it on the server before the application accepts or stores the result.
See [Architecture Boundaries](/docs/architecture-boundaries#choose-the-server-or-browser)
for the full placement and security guidance.

## Handle Failure And Output

Check each boundary explicitly:

- Reject input that exceeds `input_utf8_cap()`.
- Treat a result with its high bit set as a component failure.
- Treat a WebAssembly trap as an exception and discard that instance.
- Do not read output memory after a failure or trap.
- Interpret the output according to its declared MIME type.

This example returns HTML because syntax colors need `<span>` elements. The
wrapper escapes the user's TSX before it constructs the highlighter input. Do
not pass arbitrary user HTML directly to this component: it preserves markup
outside the selected code block.

The example then inserts output from a reviewed, pinned component with
`dangerouslySetInnerHTML`. QIP isolation limits what the component can access,
but it does not make active output safe. If the component or its HTML input is
not trusted, sanitize the result before inserting it into the page.

## Test And Deploy It

The example's Node test instantiates the same component, checks its highlighted
HTML, and verifies that the TSX wrapper escapes a script element. `npm run
build` then checks the cached Server Component and browser Client Component.

Keep the reviewed `.wasm` artifact with the application or copy it during the
build. Do not fetch an unpinned component at request time. If a Client
Component loads the file, remember that users can download it; do not put
secrets in a browser component.

Run a benchmark with representative application data when the transform is on
a hot path. Include serialization, memory copies, and component execution in
the measurement.

## When Not To Use QIP

Use normal application code when the operation needs live database access,
network calls, secrets, React lifecycle state, browser APIs, or large shared
mutable state. A library call is also simpler when portable behavior and the
WebAssembly boundary do not help the application.

## Other Runtimes

The Content contract is the same in every host. These guides cover runtime
loading, failure, and instance ownership:

| Runtime | Guide |
| --- | --- |
| JavaScript | [Running In JavaScript](/docs/running-in-javascript) |
| Swift | [Running In Swift](/docs/running-in-swift) |
| Java | [Running In Java](/docs/running-in-java) |
| Python | [Running In Python](/docs/running-in-python) |
| Go | [Running In Go](/docs/running-in-go) |
| .NET | [Running In .NET](/docs/running-in-dotnet) |
| Ruby | [Running In Ruby](/docs/running-in-ruby) |

If no existing component provides the operation, use
[Writing QIP Components In Zig](/docs/zig-components) or
[Building C Libraries As QIP Components](/docs/c-wasm-toolchains).
