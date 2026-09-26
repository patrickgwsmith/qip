# Content Component Contract

A Content component is a WebAssembly module that accepts bounded bytes, performs
one finite operation, and returns bounded bytes. A host writes the input into
module memory, calls `render`, and reads the output range that call returns.
Inputless generators use the same call with an input size of zero. Converters,
validators, formatters, and document or image renderers fit this contract.

The interface is small so a browser, CLI, server, or native app can host the same
module with little setup and in its own language. It needs no WASI implementation
or JavaScript runtime. A normal Content component has no imports and cannot
read an ambient clock, filesystem, network, or environment. The host keeps
those services, authorization, and presentation; it passes only selected bytes
and optional numeric [uniforms](/docs/uniforms). This narrow boundary supports reproducible calls,
but authors must still manage internal state and hosts must still set resource
limits. WASI serves broader programs and remains pre-1.0; its milestone
releases can change interfaces. [WASI roadmap](https://wasi.dev/roadmap)

## How a host calls a component

```text
Host                                Content component
  │                                         │
  ├─ inspect input/output capacities once ─→│
  ├─ write input at input_ptr ─────────────→│ exported memory
  ├─ set optional numeric uniforms ────────→│
  ├─ call render(input_size) ──────────────→│
  │←──────── output pointer and byte count ─┤
  └─ read exactly that output range ───────→│ exported memory
```

The host may reuse an instance and its memory. For each transform call, it checks
`input_size` against the declared capacity, writes the current input at
`input_ptr`, applies uniforms, calls `render(input_size)`, and reads only the
returned range on success. A generator accepts no input; the host applies
uniforms and calls `render(0)`. The host may instead instantiate per call.
With fixed Wasm memory, it can budget memory once up front and reuse it across
renders.

## Exports

A component that accepts input and returns output is a “transform”. One that accepts no input and only has output is a “generator”.

| Export | Rule |
| --- | --- |
| `memory` | Linear memory shared with the host. |
| `input_ptr() -> i32` | Required when the component accepts input; location where the host writes it. |
| `input_utf8_cap() -> i32` **or** `input_bytes_cap() -> i32` | Required with `input_ptr`; exactly one, declaring maximum input bytes and their encoding rule. |
| `input_content_type_ptr() -> i32` **and** `input_content_type_size() -> i32` *(optional)* | Only for components that accept input; an exact input MIME type. Export both or neither. |
| `output_utf8_cap() -> i32` **or** `output_bytes_cap() -> i32` | Exactly one; maximum output bytes and their encoding rule. |
| `output_content_type_ptr() -> i32` **and** `output_content_type_size() -> i32` *(optional)* | An exact output MIME type. Export both or neither. |
| `render(input_size: i32) -> i64` | Returns the current output pointer and byte count, or a recoverable rejection. |
| `failure_modes_per_input_offset() -> i32` *(optional)* | Required only if `render` can return recoverable rejection; declares the number of failure modes per input offset. |

A generator omits all input exports; a partial input interface is invalid.
`utf8` means valid UTF-8; `bytes` allows arbitrary bytes. Inputless generators
can start a pipeline but cannot follow another stage.
The former `output_i32_cap` export is not part of this contract; encode numeric
collections in a documented byte format.

Every pointer, size, capacity, and failure getter in this contract is a
zero-argument function returning `i32`, not an exported global. Its body may
contain only `i32.const` or `global.get` of an immutable module-constant `i32`
global, then `end`: no calls, loops, branches, locals, or memory/table
operations. Values cannot depend on input, uniforms, or earlier renders.
The full transform input region (`input_ptr` through its capacity) must be in
initial memory and disjoint from active data segments. These rules let hosts
inspect the ABI before running component logic.

## Render result

Interpret the `i64` as unsigned bits:

```text
     63 62                           32 31                             0
     +-+-------------------------------+--------------------------------+
     |0|         output pointer        |       output byte count        | success
     +-+-------------------------------+--------------------------------+
     |1|        reserved (zero)        |    optional failure detail     | rejection
     +-+-------------------------------+--------------------------------+
```

On success, the pointer must be below `0x80000000`; the complete range must be
in memory and the size must not exceed the declared output capacity. The size
may use all 32 bits. A zero size is a successful empty output. Each call
returns its own pointer and size; there is no last-output getter.

On rejection, the host stops the pipeline and reads no output.

## Failures and errors

Some operations have no expected error for any input within their declared
capacity. Base64 encoding is one example: every byte string has an encoding.
Such a component returns success for conforming calls and omits
`failure_modes_per_input_offset()`.

Other operations must reject some validly supplied bytes. A Base64 decoder,
for example, can receive invalid characters or padding. It returns an error by
setting the rejection bit in the `render` result. The host can report it and
reuse the instance for another call. A component may report only that the input
was rejected, or spend extra work to identify a position and failure mode. Tracking
detail can cost code size or runtime work, so it is a choice for each component.

A trap means a precondition or internal invariant was violated: for example,
the host passed more bytes than the declared capacity, supplied invalid UTF-8
to a UTF-8 input, or an assertion detected corrupt internal state. Malformed
Base64 within the declared input domain is an ordinary decoding error. After a
trap, memory may hold partial output; the host reads none of it and discards
the instance. A data-preserving transform should trap instead of silently
truncating output.

<h3 id="optional-failure-detail">Optional failure detail</h3>

If `failure_modes_per_input_offset()` returns zero, the low 32 result bits must
be zero. If it returns `N > 0`, the component defines `N` failure modes per
input byte offset. On rejection:

```text
input_offset = failure_detail / N
failure_mode = failure_detail % N
```

The offset is in `0..input_size`, inclusive; `input_size` means the position
after the last byte. Modes are component-specific integers in `0..N - 1`.
Every possible offset and mode must encode in 32 bits.

## Optional content-type metadata

A component can declare an exact input or output MIME type using the optional
getter pairs in the export table. Omit a pair for unknown or generic content.
In particular, generic UTF-8 needs no `text/plain`
and generic bytes need no `application/octet-stream`; those declarations would
needlessly narrow pipeline matching. Use metadata for specific formats such as
`text/markdown` or `image/ktx2`. See [Formats and Encodings](/docs/formats).

Except for multipart below, the value is one lowercase media type with no
whitespace, media ranges, lists, or parameters. Hosts compare it byte for byte;
they do not trim or normalize it. Pointer, size, and bytes are module constants.
In the strict artifact profile, each getter has the constant form described
above, and the bytes occupy initial memory in one non-overlapping active data
segment. A start function or `render` must not assemble them. Tooling can then
read the type from Wasm sections without instantiating the module.

<h3 id="multipart-form-data">Multipart form data</h3>

The only allowed parameterized type is
`multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000`.
The `uuid-` prefix is fixed; the following 36 bytes are a canonical lowercase
UUID (`8-4-4-4-12`, hexadecimal digits and hyphens). The declaration is
unquoted, has no extra whitespace or parameters, and its initial UUID is in
the active data segment. Other parameterized or multipart types are invalid.

Before `render`, the host may replace exactly those 36 bytes in exported memory.
It leaves the pointer, size, prefix, and other bytes unchanged. A producer
reads the current output slot when writing delimiters; a consumer reads its
current input slot when parsing them. To connect them, the host copies the
producer UUID into the consumer slot and updates the pipeline's tracked MIME
type. An external boundary with a different shape or length needs an ingress
adapter or another contract.

For `uuid-<uuid>`, delimiters start `--uuid-<uuid>\r\n` and end
`--uuid-<uuid>--\r\n`; the two leading hyphens are not part of the MIME
parameter. Components must use the slot on every call, not an inlined copy.
A producer rejects a part body that contains a delimiter line for the current
boundary. Tests must replace the default UUID and check both the declared type
and the delimiters. The slot is the sole exception to static MIME bytes, not a
general string uniform. The repository's
`application/wasm/wasm-read-input-content-type.wasm` reads this metadata; it
traps on an invalid static declaration.

## Pipeline composition

The host validates arbitrary bytes before they enter `input_utf8_cap`; encoding
a native string as UTF-8 also establishes the guarantee. A UTF-8 component
can rely on valid input. Its `output_utf8_cap` promises valid output, which a
known-valid next stage can use without rescanning. UTF-8 output can enter a
bytes input. Bytes output can enter a UTF-8 input only after host validation
or an explicit validator. Debug or compliance hosts may check component output
to detect a broken promise.

The host also tracks an optional MIME type:

| Boundary | Rule |
| --- | --- |
| Initial input | A caller-provided type is authoritative. Direct stdin or `-i` input to `qip run` has no separate type channel; without an initial type, the first stage is permitted. |
| Stage input | A declared type must match the tracked type exactly. Without metadata, UTF-8 input accepts any valid UTF-8 and bytes input accepts any bytes. |
| Stage output | A declared type replaces the tracked type. Otherwise UTF-8-to-UTF-8 and output through `output_bytes_cap` preserve it; bytes-to-UTF-8 makes it unspecified. |

## Repeated renders and memory

On every call, a transform reads the current bytes at `input_ptr` and validates
`input_size` inside the component, even if the host checked it. A generator may
treat nonzero `input_size` as a caller violation. Return only the current
output's length and pointer. Keep caches and scratch state consistent when
input or uniforms change. Reset every public uniform to its authored default
before each normal return, including recoverable rejection.

If a transform writes output, its output buffer must be disjoint from input.
It may return an immutable slice of the current input instead, but then it must
not modify that input and the complete slice must fit within `input_size`.
Reserve scratch space explicitly; unused input capacity is not scratch space.
Build fixed memory with an explicit maximum; see [Hard Limits](/docs/hard-limits) and
[Writing QIP Components In Zig](/docs/zig-components).

## Known and untrusted components

An application may trust a component it built, tested, or admitted through a
controlled artifact process. Its wrapper can rely on that component's export,
output-range, and MIME promises, while still checking caller-controlled input
size or rejecting input supplied to a generator.

Core Wasm validation does not prove the Content contract. A host that accepts
arbitrary modules must check exports and signatures, inspect the input region
before copying, and check the returned size and range before reading. It must
also enforce memory and execution limits. Do these checks where arbitrary
modules enter the application; a validated artifact can then use the direct
call flow. [Bounded Output Proofs](/docs/hard-limits#bounded-output-proofs)
describes an optional static check of the output-size promise.

## When to use it

Use Content when one call finishes the job. For example, this pipeline renders
Markdown and wraps the HTML:

```sh
npx @qip.dev/qipx qip.dev run text/markdown/commonmark.0.31.2.wasm \
  text/html/html-page-wrap.wasm < page.md
```

Use [Time and Events](/docs/time-and-events) when a retained instance must
react to scheduled updates or input. Keep database, request, and filesystem
work in the host. Streaming operations or ones that need many host callbacks
may fit another interface better. See [QIP Component Patterns](/docs/module-patterns)
for implementation examples.
