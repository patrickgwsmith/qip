# Content Component Contract

Content components perform finite transformations over text or bytes, or
generate output without an input. For a transform, the host writes input into
WebAssembly memory, applies any uniforms, calls `render(input_size)`, and
decodes the returned output pointer and size. For an inputless generator, the
host applies uniforms and calls `render(0)`. A component can use the same
result to reject input without trapping.

Use this contract for converters, validators, formatters, document renderers,
generators, and pipeline stages. A component can retain this Content interface
while adding later capabilities. For example,
`components/interactive/gif-player.wasm` accepts and renders `image/gif` as
fallible Content, then adds Time to select later frames. It needs no event
exports. Add [Time and Events](/docs/time-and-events) when retained state must
respond to scheduled updates or user input.

## Required Exports

Every Content component exports:

- `memory`
- `render(input_size: i32) -> i64`: transform the input and return the output
  pointer and byte count, or reject the input.
- Either `output_utf8_cap() -> i32` or `output_bytes_cap() -> i32`: maximum output bytes.

A transform additionally exports:

- `input_ptr() -> i32`: offset where the host writes input.
- Exactly one of `input_utf8_cap() -> i32` or `input_bytes_cap() -> i32`:
  maximum input bytes.

An inputless generator exports neither `input_ptr` nor an input-capacity
getter. Its `render` parameter remains present for ABI uniformity and the host
must call it with `0`. A component that exports only one part of the transform
input interface is invalid: `input_ptr` and exactly one input-capacity getter
must either all be present or all be absent.

Every pointer and capacity export is a zero-argument function returning `i32`.
An exported global is rejected. A getter function may read an immutable
internal global when its value is module-constant.

The `utf8` capacity exports declare that the corresponding bytes must be valid UTF-8. The `bytes` variants carry arbitrary binary data.

Inputless generators are the natural source stages for a composition: for
example, a solid-color component can declare `image/ktx2` output and generate
a surface from width, height, and color uniforms. They are not transforms which
happen to ignore copied bytes.

## Render Result

Interpret the `i64` result as 64 unsigned bits.

On success, bit 63 is clear:

```text
 63            32 31                             0
+----------------+--------------------------------+
| output pointer |          output size           |
+----------------+--------------------------------+
```

The output pointer uses 31 bits and must be less than `0x80000000`. The output
size uses all 32 bits. Thus, output can start only in the first 2 GiB of memory,
but its size is not limited to 2 GiB. The complete output range must be in
memory and the output size must not exceed the declared output capacity.

Bit 63 marks recoverable rejection. Bits 32 through 62 are reserved and must be
zero. The low 32 bits contain optional failure detail. The host must not read
output after rejection.

This result makes the output pointer part of the operation that produced it.
The component does not keep a last-output pointer for a later getter call.

## Optional Failure Detail

A component which can reject input without trapping exports:

- `failure_modes_per_input_offset() -> i32`

The export is a static getter. If it is absent, `render` must not return a
result with bit 63 set. A trap is still possible when the caller violates a
precondition or the component has a defect.

A value of `0` means that rejection has no position detail. The low 32 result
bits must be zero. The result reports only accepted or rejected.

A value of `N`, where `N > 0`, defines `N` component-specific failure modes for
each input offset. On rejection, decode the low 32 bits as follows:

```text
input_offset = failure_detail / N
failure_mode = failure_detail % N
```

`input_offset` is in `0..input_size`, inclusive. `input_size` identifies
the position after the final byte. A parser can use the last offset for an
unexpected EOF end of input.

The component defines the meaning of each failure mode. Mode values are from
`0` through `N - 1`. The product of every possible position and `N`, plus its mode, must fit
in 32 bits. A future API could provide message strings for each mode but currently they are just numeric and private to the component.

## UTF-8 Is Validated At Pipeline Edges

The host maintains the UTF-8 guarantee. When arbitrary bytes first enter a
UTF-8 pipeline, the host validates the complete input before it calls a
component with `input_utf8_cap`. Encoding a native string as UTF-8 establishes
the same guarantee without a separate validation pass. Invalid bytes fail at
the host boundary and do not reach `render`.

A component with `input_utf8_cap` may assume that its complete input is valid
UTF-8. It does not need to scan the input again only to validate the encoding.
Passing malformed UTF-8 to that component violates the host contract and may
trap.

A component with `output_utf8_cap` guarantees that every successful output is
valid UTF-8. The host carries that guarantee to the next UTF-8 component without
rescanning the bytes. A UTF-8 output may also flow into `input_bytes_cap`
because every UTF-8 string is a byte string. An `output_bytes_cap` result may
not flow into `input_utf8_cap` until the host validates it or an explicit
bytes-to-UTF-8 validator accepts it.

Compliance tools and debug hosts may validate UTF-8 output to find a defective
component. Production hosts may rely on the output contract between known-valid
components.

## Static ABI Exports

The QIP ABI getters are static exports. When one of these exports is present,
it must be a small, mechanically inspectable function:

- `input_ptr()` when the component is a transform
- `input_utf8_cap()` or `input_bytes_cap()` when the component is a transform
- `output_utf8_cap()`
- `output_bytes_cap()`
- `failure_modes_per_input_offset()`
- `input_content_type_ptr()`
- `input_content_type_size()`
- `output_content_type_ptr()`
- `output_content_type_size()`

The function body must have no calls, loops, branch control flow, local
operations, or memory/table operations. In practice this means a constant getter
such as `i32.const ...; end`, or `global.get` of an immutable module-constant
global followed by `end`.

These values must not depend on input, uniforms, previous renders, or other
mutable state. This lets a host inspect buffer requirements and content-type
metadata without executing component logic. Native translations can also publish
these values as constants.

For a transform, the complete input range, from `input_ptr` through the
selected input capacity, must be within initial memory and must not overlap any
active data segment. Instantiation therefore never writes into bytes owned by
the caller as input. This requirement does not apply to an inputless generator.

## Host Call Flow

For each render request using a known-valid transform, the host:

1. Instantiates or reuses the component.
2. Verifies that `input_size` does not exceed the input capacity.
3. Writes the input bytes at `input_ptr`.
4. Applies any requested [uniforms](/docs/uniforms).
5. Calls `render(input_size)`.
6. Stops if the result reports rejection.
7. Decodes the output pointer and size and reads exactly that output range.

For an inputless generator, the host:

1. Instantiates or reuses the component.
2. Rejects any supplied input bytes; a generator cannot be appended after a
   pipeline stage.
3. Applies any requested [uniforms](/docs/uniforms).
4. Calls `render(0)`.
5. Stops if the result reports rejection.
6. Decodes the output pointer and size and reads exactly that output range.

If `render` traps, the request fails. The host must not read output; memory may
contain stale or partial output. A trap does not undo memory or
global changes, so the host discards that Wasm instance and creates a new one
before another render. A recoverable rejection closes normally, so the host may
reuse the instance for another request.

A valid component guarantees that a successful `render` returns a pointer and
byte count within memory and its declared output capacity. Application wrappers
for a component they trust may rely on those guarantees. For transforms they
still check input size because the caller, not the component, chooses the
input. For generators they require that the supplied input is empty.

## Known And Untrusted Components

A known-valid component is an artifact the application deliberately trusts:
for example, one built and tested with the application or obtained through a
controlled artifact pipeline. Its QIP exports, memory regions, content types,
and render behavior are part of that trust decision. Ordinary wrappers should
use the contract directly instead of repeatedly checking whether the component
honored it.

Arbitrary Wasm is different. Core WebAssembly validation proves that a module
is structurally valid Wasm, not that it implements a QIP contract. A generic
host accepting modules from users or third parties must establish that boundary
itself. Before execution it checks the required exports and their signatures.
Before copying input it checks the advertised input region. After `render` it
checks the returned size and output region before reading component memory. It
also applies the memory and execution policies described in [Hard
Limits](/docs/hard-limits).

These checks belong at the point where arbitrary modules enter the application.
Once an artifact has been admitted as a known-valid component, downstream
wrappers can use the simpler call flow above.

Components can make the successful output-size guarantee statically
certifiable with `components/application/wasm/wasm-bounded-output.wasm`. The
checker recognizes a small compiled-Wasm proof epilogue that traps when the
result exceeds the exact static output capacity. See [Bounded Output
Proofs](/docs/hard-limits#bounded-output-proofs) for the accepted shape and its
limits.

## Repeated Renders

Hosts may run more than one request on the same component instance. Each
transform request uses the bytes currently at `input_ptr`; each generator
request calls `render(0)`.

Component authors should make repeated renders deliberate:

- For transforms, treat the input region as host-owned for the duration of
  each call.
- Return the byte length of the current output, not a cumulative length.
- Return the current output pointer and size from every accepted render.
- Keep caches and scratch state consistent when input bytes or uniforms change.
- Reset every public uniform to its authored default before each normal return
  from `render`, including provisional failure.
- Return recoverable rejection for expected failure inside the declared input
  domain. Trap for a caller precondition violation or an internal defect.

This lets browser hosts retain an instance for many requests and lets wrappers set uniforms immediately before rendering without reinstantiation.

## Optional Content-Type Metadata

A component may declare an exact input or output MIME type with:

- `input_content_type_ptr()` and `input_content_type_size()`
- `output_content_type_ptr()` and `output_content_type_size()`

Both exports in a pointer/size pair must be present. Omit a pair when the content type is unknown or intentionally generic.

An inputless generator must omit `input_content_type_ptr()` and
`input_content_type_size()`: it has no input for which to make a MIME promise.

When present, the value must normally be one lowercase MIME media type, such
as `text/markdown`, `text/html`, or `image/bmp`. Do not include whitespace,
media ranges, comma-separated lists, or parameters such as `charset=utf-8`.
The multipart boundary slot defined below is the only parameter exception.
Hosts otherwise compare these strings exactly; they do not trim, lowercase,
or remove parameters.

Content type is module metadata, not render state. Its pointer, size, and bytes
must not vary with input, uniforms, previous calls, or other runtime state,
except for a host-written multipart boundary UUID as defined below. Modules in
the strict artifact profile make the initial metadata statically readable:

- each pointer and size export is a zero-argument `i32` getter containing
  exactly one `i32.const` or one `global.get` of an immutable constant `i32`
  global, followed by `end`;
- both exports in the pair are present; and
- the referenced bytes are within initial memory and supplied by one
  non-overlapping active data segment, rather than assembled by a start
  function or `render`.

This lets tooling read the declared type directly from Wasm sections without
allocating memory or instantiating and executing the module.

### Multipart Form Data

QIP allow-lists parameterized multipart media types rather than accepting
arbitrary MIME parameters. The initial allow-list contains only
`multipart/form-data`. Other `multipart/*` types and all other parameters
remain invalid until this contract defines their byte layout and host rules.

A component that consumes or produces multipart form data declares exactly
this shape:

```text
multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000
```

The boundary is the five immutable ASCII bytes `uuid-` followed by a mutable
36-byte canonical lowercase UUID. It is unquoted and has no surrounding
whitespace. No other parameters are permitted. The content-type pointer and
size remain module constants; the initial UUID bytes must be present in the
active data segment so static tooling can read a complete valid default.

Before `render`, a host may replace exactly those 36 UUID bytes in exported
memory. It must not change `multipart/form-data;boundary=uuid-`, the pointer,
the size, or any other byte. The replacement must have the canonical UUID
shape `8-4-4-4-12` using lowercase ASCII hexadecimal digits and hyphens. A
host that does not need a distinct boundary leaves the declared default in
place.

This exception is symmetric. A multipart producer reads its current output
boundary slot when rendering delimiters. A multipart consumer reads its
current input boundary slot when parsing them. To connect the two, the host
copies the producer's 36 UUID bytes into the consumer's input slot before
calling the consumer. The host also updates the content type it tracks for the
pipeline, so the producer's output and consumer's input still match exactly.
An exact-length slot does not accept an external multipart boundary of a
different shape or length; an ingress adapter must normalize such a body or
use a component contract designed for the complete external message.

The boundary parameter does not include the two structural hyphens used by
multipart delimiters. For boundary `uuid-<uuid>`, a producer emits:

```text
--uuid-<uuid>\r\n
--uuid-<uuid>--\r\n
```

Component authors must keep the declared slot as the single source of truth.
Code that renders or parses multipart bytes must load the current UUID from
that mutable memory for every request; it must not use an inlined or duplicate
constant. Output components must reject a part body containing a delimiter
line for the current boundary rather than emit ambiguous multipart. Tests must
replace the default UUID and prove that the exported content type and every
rendered or accepted delimiter use the replacement.

The pointer, size, media type, parameter name, `uuid-` prefix, and initial UUID
remain statically inspectable. Only the UUID slot is host-configurable. This
narrow exception preserves ordinary content-type metadata as immutable module
metadata and does not create a general string-uniform mechanism.

The repository includes such a reader as a QIP component. It prints the input
content type, prints an empty line when the pair is omitted, and traps when any
input or output content-type metadata violates the static form:

```bash
qip run -i component.wasm -- \
  components/application/wasm/wasm-read-input-content-type.wasm
```

Do not export catch-all MIME types for data whose generic shape is already
declared by the capacity ABI:

- Omit `text/plain` for generic UTF-8. The `input_utf8_cap` and
  `output_utf8_cap` exports already express that constraint.
- Omit `application/octet-stream` for generic raw bytes. The `input_bytes_cap`
  and `output_bytes_cap` exports already express that constraint.

Adding either MIME type has no descriptive benefit and unnecessarily
constrains recipe composition through exact content-type matching. Export
content-type metadata only when the component requires or guarantees a more
specific format.

## Pipeline Composition

The host tracks an optional content type as bytes pass through a pipeline:

- A caller-provided initial content type is authoritative.
- Direct stdin or `-i` input to `qip run` has no separate content-type channel. When no initial type exists, user intent permits the first stage.
- A declared input content type must exactly match the current pipeline type.
- Without declared input metadata, `input_utf8_cap` accepts any UTF-8 pipeline input and `input_bytes_cap` accepts any bytes.
- An inputless generator is valid only as the first stage and only when the
  caller supplies no input bytes.
- A declared output content type replaces the current pipeline type.
- Without declared output metadata, a UTF-8-to-UTF-8 transform preserves the current type.
- A bytes-to-UTF-8 transform produces new text with an unspecified type.
- Output through `output_bytes_cap` preserves the current type.

These rules let generic operations such as UTF-8 validation or byte-preserving transforms compose without erasing a more precise type, while format converters can explicitly change it.

## Memory And Failure Behavior

- For transforms, keep input and output buffers disjoint when `render` modifies
  output bytes.
- If the returned output pointer is in the declared input region, `render` must
  not modify input. The output is an immutable slice of the supplied input. The
  complete slice must be within the current input size.
- Transforms validate `input_size` inside the component even when the host also
  checks it. A generator may treat a nonzero `input_size` as a caller contract
  violation; a conforming host never makes that call.
- Reserve explicit scratch space rather than assuming unused capacity belongs to the component.
- Return a failure result when a conforming call can reject expected input.
- Trap when the caller violates a declared precondition or an internal
  invariant fails. The host discards the instance after a trap.
- Prefer a trap over silent truncation for data-preserving transforms.
- A successful empty output has an output size of zero. Bit 63 distinguishes it
  from rejection.
- For Zig components, compile with an explicit Wasm memory maximum. See [Writing QIP Components In Zig](/docs/zig-components) and [Hard Limits](/docs/hard-limits).

## Future Numeric Output Shapes

QIP previously supported `output_i32_cap`; it is not part of the current contract. Histograms, masks, label matrices, spectra, and similar results need more than a one-off integer-array export.

A future design should keep three concerns separate:

- Element type, such as `i32`, `u8`, `f32`, or a SIMD lane type.
- Logical shape, such as `[256]`, `[3, 256]`, or `[height, width, bands]`.
- Physical layout, including dense row-major, strides, alignment, tiling, or planar/interleaved data.

Until that design is specified, represent numeric collections through an explicitly documented byte format rather than relying on the removed export.
