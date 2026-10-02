# Running QIP in JavaScript

QIP components can be imported as WebAssembly ES modules and wrapped as
ordinary synchronous JavaScript functions. The wrapper writes directly into
the component's memory, calls `render`, and reads the result. It does not need
generated glue or a QIP JavaScript runtime.

Direct `.wasm` imports depend on support from your runtime or bundler. The
explicit-instantiation fallback uses the same wrapper and contract.

The examples on this page use components built and tested in this repository.
They assume the module is a known-valid QIP component and do not revalidate its
ABI after every call. That trust boundary is different from accepting arbitrary
Wasm supplied by a user or third party; see [Known And Untrusted
Components](/docs/content-component#known-and-untrusted-components) in the
Content contract.

`TextEncoder` always produces valid UTF-8, so these string wrappers already
satisfy `input_utf8_cap`. If input arrives as arbitrary bytes instead, validate
it before the first UTF-8 component. Once a known-valid component returns an
`output_utf8_cap` result, a pipeline may pass those bytes to another UTF-8
component without decoding and validating them again.

## Direct import: E.164

This example wraps the E.164 canonicalizer:

```js
import {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} from "/text/e164.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function decodeRenderResult(value) {
  const bits = BigInt.asUintN(64, value);
  if ((bits >> 63n) !== 0n) throw new Error("rejected input");
  return {
    outputSize: Number(bits & 0xffff_ffffn),
    outputPtr: Number((bits >> 32n) & 0x7fff_ffffn),
  };
}

export function normalizeE164(phoneNumber) {
  const input = new Uint8Array(
    memory.buffer,
    input_ptr(),
    input_utf8_cap(),
  );

  const { read, written } = encoder.encodeInto(phoneNumber, input);
  if (read !== phoneNumber.length) {
    throw new RangeError("phone number exceeds input capacity");
  }

  const { outputPtr, outputSize } = decodeRenderResult(render(written));
  return decoder.decode(
    new Uint8Array(memory.buffer, outputPtr, outputSize),
  );
}

console.log(normalizeE164("+1 (212) 555-0100"));
// +12125550100
```

The input `Uint8Array` is a view over the component's linear memory.
[`encodeInto`](https://developer.mozilla.org/en-US/docs/Web/API/TextEncoder/encodeInto)
writes UTF-8 bytes into that memory directly, avoiding the temporary encoded
array created by `TextEncoder.encode()`.

## GFM CommonMark to HTML

The same wrapper shape works for a larger text transformation. This component
accepts Markdown and returns HTML, including GFM tables and task lists:

```js
import {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} from "/text/markdown/gfm-commonmark.0.31.2.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function decodeRenderResult(value) {
  const bits = BigInt.asUintN(64, value);
  if ((bits >> 63n) !== 0n) throw new Error("rejected input");
  return {
    outputSize: Number(bits & 0xffff_ffffn),
    outputPtr: Number((bits >> 32n) & 0x7fff_ffffn),
  };
}

export function markdownToHTML(markdown) {
  const input = new Uint8Array(
    memory.buffer,
    input_ptr(),
    input_utf8_cap(),
  );

  const { read, written } = encoder.encodeInto(markdown, input);
  if (read !== markdown.length) {
    throw new RangeError("Markdown exceeds input capacity");
  }

  const { outputPtr, outputSize } = decodeRenderResult(render(written));
  return decoder.decode(
    new Uint8Array(memory.buffer, outputPtr, outputSize),
  );
}

const html = markdownToHTML(`
# Release checklist

- [x] Build
- [ ] Deploy
`);
```

The returned string is HTML, not a sanitization policy. Sanitize it before
assigning it to `innerHTML` when the Markdown is untrusted.

This version of the GFM CommonMark component has no uniforms; its behavior is
fixed.

## Currency formatting with a uniform

Uniforms configure a component without changing its content input. The en-US
currency formatter accepts an exact decimal string and uses an ISO 4217 numeric
code to select the currency:

```js
import {
  memory,
  input_ptr,
  input_utf8_cap,
  uniform_set_currency,
  render,
} from "/text/currency-format-en-us.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function decodeRenderResult(value) {
  const bits = BigInt.asUintN(64, value);
  if ((bits >> 63n) !== 0n) throw new Error("rejected input");
  return {
    outputSize: Number(bits & 0xffff_ffffn),
    outputPtr: Number((bits >> 32n) & 0x7fff_ffffn),
  };
}

export function formatCurrency(amount, currency) {
  const input = new Uint8Array(
    memory.buffer,
    input_ptr(),
    input_utf8_cap(),
  );

  const { read, written } = encoder.encodeInto(amount, input);
  if (read !== amount.length) {
    throw new RangeError("amount exceeds input capacity");
  }

  uniform_set_currency(currency);
  const { outputPtr, outputSize } = decodeRenderResult(render(written));
  return decoder.decode(
    new Uint8Array(memory.buffer, outputPtr, outputSize),
  );
}

console.log(formatCurrency("1234567.895", 840));
// $1,234,567.90
```

Call uniform setters after writing the input and before `render()`. Direct
imports generally share one instance, so set every value needed by each
invocation instead of relying on state left by an earlier call. See
[Uniforms](/docs/uniforms) for setter types, returned values, and CLI mapping.

## Capacity and UTF-8 length

`encodeInto` does not throw when its destination is too small. It returns two
progress values:

- `read` is the number of UTF-16 code units consumed from the JavaScript
  string.
- `written` is the number of UTF-8 bytes placed in WebAssembly memory.

The complete input fitted only when `read === source.length`. Pass `written`,
not `read`, to `render`:

```js
const { read, written } = encoder.encodeInto(source, input);
if (read !== source.length) {
  throw new RangeError("input exceeds component capacity");
}

const renderResult = render(written);
```

The distinction is invisible for ASCII but required for other text. JavaScript
strings use UTF-16, while QIP input sizes count UTF-8 bytes. `encodeInto` only
writes complete UTF-8 sequences, so a short destination does not leave a
partial encoded character at the end.

QIP inputs are length-delimited. Do not append a zero terminator unless a
particular non-QIP library interface explicitly requires one.

## Call order

For a UTF-8 content component:

1. Call `input_ptr()` and `input_utf8_cap()`.
2. Create a `Uint8Array` view over that input region.
3. Encode into the view and verify that the full string was read.
4. Call `render(written)` and interpret its `BigInt` as 64 unsigned bits.
5. Stop if bit 63 reports rejection.
6. Decode the output pointer from bits 32 through 62 and the size from bits 0
   through 31. Read exactly that range.

For an explicitly instantiated component:

```js
const result = BigInt.asUintN(64, instance.exports.render(written));
if ((result >> 63n) !== 0n) throw new Error("rejected input");
const outputSize = Number(result & 0xffff_ffffn);
const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
const output = new Uint8Array(
  instance.exports.memory.buffer,
  outputPtr,
  outputSize,
);
```

An `i64` WebAssembly result is a JavaScript `BigInt`. The output pointer belongs
to that render and can change on the next call. If `render()` traps, do not read output;
it may contain stale or partial bytes. Discard that instance and instantiate the
module again before another render.

The returned size and output pointer can be used directly because a valid QIP
component guarantees that they describe output within its declared region.

## JavaScript-specific nuances

- When converting UTF-8 output to a JavaScript string, use
  `new TextDecoder("utf-8", { fatal: true })`. Without `fatal: true`, malformed
  bytes become replacement characters and hide a broken `output_utf8_cap`
  guarantee. A byte-to-byte pipeline does not need to decode intermediate
  UTF-8 output.
- Loading is asynchronous, but `render()` is synchronous. Load or import the
  module before entering code that needs a synchronous result.
- A direct ES module import normally shares one module instance and one memory.
  Do not call a scratch-buffer component concurrently through the same
  instance. Use separate explicit instances for concurrent or isolated work.
- Create memory views at the point of use instead of retaining them. If a
  non-strict module calls `memory.grow`, existing views over an unshared memory
  become detached. Strict QIP modules reject `memory.grow`, but short-lived
  views keep wrappers correct for other modules too.
- A decoded JavaScript string owns its result. A returned `Uint8Array` view does
  not: the next render may overwrite it. Use `.slice()` when binary output must
  survive another call.
- WebAssembly `i32`, `f32`, and `f64` values appear as JavaScript `Number`
  values. An `i64` parameter or result uses `BigInt`.
- A trap throws `WebAssembly.RuntimeError`. Do not read output after a trap, and
  remember that mutations made before the trap are not rolled back.

## Binary components

For `input_bytes_cap`, the caller already has bytes, so copy them directly:

```js
export function runBytes(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError("input must be a Uint8Array");
  }
  if (bytes.length > input_bytes_cap()) {
    throw new RangeError("input exceeds component capacity");
  }

  new Uint8Array(memory.buffer, input_ptr(), bytes.length).set(bytes);
  const { outputPtr, outputSize } = decodeRenderResult(render(bytes.length));
  return new Uint8Array(memory.buffer, outputPtr, outputSize).slice();
}
```

The final `slice()` owns its bytes independently of component memory. Without
it, a later render could overwrite the returned view.

## Traps and reuse

A WebAssembly trap appears as a JavaScript exception. A trap does not roll back
memory or mutable globals. Do not read output after a trap. Discard the instance
and instantiate the module again before another request. Recoverable rejection
returns normally, so the same instance remains reusable.

## Run untrusted Wasm through the QIP host

Core Wasm validation does not establish the QIP contract. Use the `qip` CLI
for a module whose exports and behavior you do not trust. The host checks the
component contract and returned output range and capacity. It rejects memory
growth by default.

Install the Go QIP CLI and put `$(go env GOPATH)/bin` on `PATH`:

```bash
go install github.com/royalicing/qip@latest
```

This Node.js example runs `./component.wasm`, reads stdin, and writes stdout.
A failed host call raises an error. It allows 64 MiB of Wasm linear memory and
one second of component execution, with a five-second limit on the subprocess:

```js
import { spawnSync } from "node:child_process";

const result = spawnSync("qip", [
  "run", "--max-memory", "67108864", "--timeout-ms", "1000",
  "--capacities-must-fit", "./component.wasm",
], { stdio: "inherit", timeout: 5000, killSignal: "SIGKILL" });
if (result.error) throw result.error;
if (result.status !== 0) throw new Error(`QIP host failed: ${result.status}`);
```

Browsers cannot launch this subprocess. A browser that accepts untrusted
Wasm needs contract validation and memory limits before instantiation, plus
an isolated worker that the host can terminate when execution exceeds its
limit. `WebAssembly.instantiate` alone does not supply these controls.

The host uses the module's declared content types; this example does not
assume the output is HTML. Contract checks do not prove that the module
performs the intended transform. The memory limit covers Wasm linear memory,
not the whole host process. See [Hard limits](/docs/hard-limits) for the checks
and their limits. Hosting untrusted Wasm in process requires these validation
and resource controls before using the direct call flow.

## Explicit instantiation

When direct `.wasm` imports are unavailable, only the loading step changes:

```js
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("/text/e164.wasm"),
  {},
);

const {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} = instance.exports;
```

The server must send the module as `Content-Type: application/wasm` for
`instantiateStreaming`. After destructuring the exports, use the same
`normalizeE164` wrapper shown above.

Native browser `import` support for `.wasm` is still less portable than the
WebAssembly JavaScript API, and bundlers differ in how they expose Wasm exports.
Use `instantiateStreaming` when direct imports are unavailable. A restrictive
Content Security Policy may also need to permit WebAssembly compilation.
