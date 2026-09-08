# Adopting QIP In React

You can add QIP to an existing React application without replacing React,
Next.js, routing, authentication, storage, or deployment. Start with one
bounded operation. The application passes bytes to a WebAssembly component and
uses the returned bytes as normal application data.

This guide adds the existing E.164 phone-number normalizer to a Next.js
application. The same `.wasm` file runs in a Server Component and a Client
Component.

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

Open `http://localhost:3000`. Edit the phone number in the Client Component and
compare its result with the Server Component result.

The example's preparation script copies
`components/text/e164.wasm` to `public/qip-components/e164.wasm`. A real
application can put a reviewed component in its own public or server asset
directory instead.

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

The example keeps this wrapper in `lib/qip-content.js` so both execution paths
use the same contract code.

## Run It In A Server Component

Load the module once from the server's filesystem and reuse the instance for
synchronous calls:

```js
import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";

import { createTextRenderer } from "./qip-content.js";

const componentPath = path.join(
  process.cwd(),
  "public",
  "qip-components",
  "e164.wasm",
);
const module = new WebAssembly.Module(readFileSync(componentPath));
const instance = new WebAssembly.Instance(module, {});

export const normalizeE164 = createTextRenderer(instance.exports);
```

Call the wrapper as an ordinary function in a Server Component:

```jsx
import { normalizeE164 } from "../lib/e164-server.js";

export default function Page() {
  const normalized = normalizeE164("+1 (212) 555-0100");
  return <output>{normalized}</output>;
}
```

This path works well when the input already lives on the server or when the
server needs the canonical result.

## Run It In A Client Component

The browser can fetch the same file and create its own instance:

```jsx
"use client";

import { useEffect, useState } from "react";
import { createTextRenderer } from "../lib/qip-content.js";

let rendererPromise;

function loadRenderer() {
  rendererPromise ??= WebAssembly.instantiateStreaming(
    fetch("/qip-components/e164.wasm"),
    {},
  ).then(({ instance }) => createTextRenderer(instance.exports));
  return rendererPromise;
}

export function PhoneNumberInput() {
  const [source, setSource] = useState("+1 (212) 555-0100");
  const [normalize, setNormalize] = useState(null);

  useEffect(() => {
    loadRenderer().then((loaded) => setNormalize(() => loaded));
  }, []);

  const output = normalize ? normalize(source) : "Loading component…";

  return (
    <label>
      Phone number
      <input
        value={source}
        onChange={(event) => setSource(event.target.value)}
      />
      <output>{output}</output>
    </label>
  );
}
```

`instantiateStreaming` requires the server to return the file with
`Content-Type: application/wasm`. Next.js serves a `.wasm` file from `public`
with this type.

The module-level promise prevents each render from loading another copy. Each
browser tab still creates its own component instance.

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

This example returns plain text, which React escapes when it renders the
string. HTML and arbitrary SVG need more care. QIP isolation limits what a
component can access, but it does not make active output safe. Sanitize
untrusted HTML before you pass it to `dangerouslySetInnerHTML`.

## Test And Deploy It

The example's Node test instantiates the same component and checks valid and
invalid input. `npm run build` then checks both Next.js execution paths.

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
