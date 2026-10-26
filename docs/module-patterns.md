# QIP Content Component Patterns

A Content component receives one bounded input, calls `render`, and produces
one bounded output. Start by deciding what the output means. That choice
determines how malformed input is rejected, whether empty output is valid, and
whether the component belongs in the middle or at the end of a pipeline.

This page covers implementation patterns. The
[Content Component Contract](/docs/content-component) defines the ABI and host
call flow.

An optional `failure_modes_per_input_offset` export declares that a component
can reject expected input without trapping. Its absence does not prove that a
component cannot trap; static analysis must inspect the compiled Wasm to prove
that.

## Choose By Purpose

| Purpose | Successful output | Malformed input | Repository example |
| --- | --- | --- | --- |
| Assertion gate | Original input unchanged | `render` rejection | [`utf8-must-be-valid.wasm`](/text/utf8-must-be-valid.wasm) |
| Transformer | Replacement content | Rejection if cheap, else trap | [`json-prettify.wasm`](/application/json/json-prettify.wasm) |
| Converter | Content in a different format | Rejection if cheap, else trap | [`svg-to-data-uri.wasm`](/image/svg+xml/svg-to-data-uri.wasm) |
| Reporter | Counts, scores, or diagnostics | Rejection if cheap, else trap | [`wasm-counts.wasm`](/application/wasm/wasm-counts.wasm) |
| Extractor or filter | Matching content, which may be empty | Rejection if cheap, else trap | [`wasm-read-input-content-type.wasm`](/application/wasm/wasm-read-input-content-type.wasm) |

These purposes describe data flow. UTF-8 versus arbitrary bytes is a separate
ABI choice, covered under [Choose The Byte Contract](#choose-the-byte-contract).
Several examples predate recoverable rejection and still trap on malformed
input; new components should follow [Reject Or Trap](#reject-or-trap).

## Assertion Gate

Use an assertion gate to enforce an invariant without changing the payload. On
success, return the original bytes and byte count. On failure, reject through
the `render` result so the pipeline stops before an unsafe value reaches another component.

[`utf8-must-be-valid.wasm`](/text/utf8-must-be-valid.wasm) checks
every UTF-8 sequence and preserves valid input. The
[`warc-check-broken-links.wasm`](/application/warc/warc-check-broken-links.wasm)
assertion uses the same shape: it returns the archive unchanged when every
internal link resolves. Otherwise it rejects at the input offset of the first
broken link's attribute value, with mode 0 for a missing page, 1 for a 4xx or
5xx response, 2 for a missing `#fragment`, 3 for a link that cannot resolve to
a path on the site, or 4 for a malformed WARC record.

An assertion may use the input region as its output region when no rewrite is
needed. Otherwise, copy the input to a separate output buffer. In either case,
downstream components must receive exactly the bytes that were checked.

Use [`qip comply`](/docs/comply) when the assertion has reusable pass, equality,
and rejection cases.

## Transformer

Use a transformer when every successful input produces replacement content.
Examples include trimming text, normalizing case, formatting currency,
prettifying JSON, and compressing bytes.

The output may be shorter, the same size, or larger than the input. Choose an
output capacity from the largest supported result, not from a typical fixture.
Trap if the result does not fit. Never return a truncated prefix.

A transformer may write in place only when the algorithm is proven safe for
overlapping input and output. Separate buffers are easier to review when output
can expand or when the parser still needs earlier input bytes.

## Converter

A converter changes the content format. It has the same buffer and failure
rules as a transformer, plus exact input and output MIME metadata.

For example,
[`svg-to-data-uri.wasm`](/image/svg+xml/svg-to-data-uri.wasm)
declares `image/svg+xml -> text/uri-list`. It writes in place from the end of
the shared buffer towards the beginning so percent-encoding cannot overwrite
unread input.

Declare only the format the component actually accepts and emits. Do not use a
broad MIME type to hide unsupported variants. See
[Formats and Encodings](/docs/formats) for repository conventions.

## Reporter

A reporter replaces the input with facts about it. Counts, scores, indexes,
diagnostics, and status records are ordinary successful output.

[`wasm-counts.wasm`](/application/wasm/wasm-counts.wasm) accepts
`application/wasm` and returns deterministic `text/csv`. It reports
measurements without deciding whether the module should pass a policy.

Reporters are normally terminal. If another component follows, it receives the
report, not the original input. Use an assertion gate when the original payload
must continue through the pipeline.

Do not call a reporter a validator merely because it emits `valid` or
`invalid`. Returning `invalid` is still successful execution. Reject when
invalid input must stop the pipeline.

## Extractor Or Filter

An extractor selects part of a valid input. A filter selects zero or more
matching records. Empty output is correct when the input contains no match.

[`wasm-read-input-content-type.wasm`](/application/wasm/wasm-read-input-content-type.wasm)
returns zero bytes when a valid module omits optional input content-type
metadata. Malformed Wasm and invalid metadata trap.

No match does not always mean a zero-byte file.
[`warc-extract-broken-links.wasm`](/application/warc/warc-extract-broken-links.wasm)
returns a valid archive containing no response records when it finds no broken
internal links; the archive still contains its required `warcinfo` record.

Malformed input and output overflow are not “no match”. Reject malformed input
and trap on overflow so callers can distinguish failure from a successful empty
result.

## Reject Or Trap

Rejection and trapping both stop the pipeline and keep partial output out of
the next component. Rejection is better for the person running it: the host
can report the input offset, the failure mode, and a snippet of the input
around it, and it can reuse the instance. A trap only reports that the
component stopped.

Prefer recoverable rejection for malformed input when all three hold:

- **Possible:** your own code detects the failure and can return normally from
  `render`. Nothing it calls aborts on that input.
- **Useful:** the input can be wrong in normal use, such as hand-written
  Markdown, a site's links, an uploaded file, or Base64 from a form. An offset
  points the author at something they can fix.
- **Cheap:** the parser already knows where it is when the check fails, so
  recording the first failing offset costs a few variables, not a second pass,
  extra tables, or a large increase in code size.

Trap for the remaining failures:

- a host ABI precondition was violated, such as an input size above capacity
  or invalid UTF-8 passed to a UTF-8 input;
- output or internal tables exceed the component's fixed capacity;
- an internal invariant that valid control flow must preserve was broken; or
- a wrapped library cannot report failure cleanly.

A wrapper around a C library such as libwebp is the usual example of the last
case. The library decides what malformed input does, its own code may abort,
and it reports a status code rather than a byte offset. Such a wrapper can stay
infallible and trap. If the library already returns an error status, rejecting
with zero failure modes is also cheap, but neither choice proves that `render`
cannot trap.

Returning zero is different from both. It tells the host that the component
succeeded and produced an empty result. Return zero only when empty output is
correct.

Some existing components return zero on parse errors or overflow. Do not copy
that behavior into new components: it makes failure indistinguishable from a
successful empty result. When changing such a component, preserve zero only if
its documented output can legitimately be empty; otherwise, change the failure
path to reject or trap as described above and update its tests.

Trap forms:

```zig
if (output_overflow) @trap();
```

```c
if (output_overflow) __builtin_trap();
```

```wat
(if (local.get $output_overflow)
  (then unreachable))
```

## Render Rejects Expected Input

A Content component that can reject recoverably exports
`failure_modes_per_input_offset`. Without that export, a successful `render`
result is valid output, but `render` may still trap. A host discards the
instance after a trap.

Nontrapping behavior is not declared through export absence. A static analyzer
must inspect the compiled Wasm and prove that valid Content calls cannot trap.
It can prove this for fallible and infallible components.

Use recoverable rejection when a conforming call can still be rejected and
[Reject Or Trap](#reject-or-trap) favors it. A validator which accepts
arbitrary bytes can reject malformed content this way. A transform which
requires already validated input may instead treat malformed content as a
precondition violation. The host ignores the output fields after rejection, so
a partial result cannot enter the next pipeline stage. An accepted zero-byte
output remains distinct from rejection.

After a trap, the host ignores output, discards the Wasm instance, and creates
another instance before a later call.

`input_utf8_cap` makes valid UTF-8 a host-enforced precondition; malformed
UTF-8 is not an allowed input. `input_bytes_cap` allows every byte string within
capacity unless an exact format adds a narrower precondition. Exact content
type metadata requires or guarantees a valid supported instance of that format.
At an untrusted boundary, use a pass-through validator with recoverable
rejection before
components which rely on that guarantee.

For example, an assertion gate can use this shape:

```zig
const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

fn renderOutcome(input_size: u32) RenderOutcome {
    if (input_size > INPUT_CAP) @trap();
    const size: usize = @intCast(input_size);
    if (firstInvalidOffset(input_buf[0..size])) |input_offset| {
        return .{ .output_size_or_failure = input_offset, .output_ptr = 0, .failed = 1 };
    }
    return .{
        .output_size_or_failure = input_size,
        .output_ptr = @intFromPtr(&input_buf),
        .failed = 0,
    };
}

export fn render(input_size: u32) RenderResult {
    const result = renderOutcome(input_size);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}
```

`RenderOutcome` is private. It exists because this component has two normal
outcomes that native Zig tests must inspect: accepted output and recoverable
rejection. Its pointer uses `usize` in native tests. The exported `RenderResult`
packs that outcome into the WebAssembly ABI. Do not add either named type to an
infallible component; return its output size from a private transform when a
test seam is useful, or put a short operation directly in `render`.

This sketch uses one failure mode per input offset. The low 32 bits therefore
hold the rejected input offset directly. A component which provides no offset
detail exports a mode count of zero and sets the low bits to zero. See the
[Content Component Contract](/docs/content-component#optional-failure-detail)
for the complete encoding.

### Several Failure Modes

When the author needs to know why the input was rejected, not only where,
declare `N` modes and encode `input_offset * N + mode`. The host decodes the
pair with division and remainder.
[`warc-check-broken-links.wasm`](/application/warc/warc-check-broken-links.wasm)
uses five modes, from a missing page to a malformed WARC record:

```zig
const FailureMode = enum(u32) {
    missing_resource = 0,
    error_status = 1,
    missing_fragment = 2,
    invalid_url = 3,
    malformed_warc = 4,
};

const FAILURE_MODES: u32 = @typeInfo(FailureMode).@"enum".fields.len;

comptime {
    // Every offset in 0..INPUT_CAP and every mode must fit in the 32-bit detail.
    std.debug.assert(@as(u64, INPUT_CAP + 1) * FAILURE_MODES <= std.math.maxInt(u32) + 1);
}

export fn failure_modes_per_input_offset() u32 {
    return FAILURE_MODES;
}

fn failureDetail(input_offset: usize, mode: FailureMode) u32 {
    return @intCast(input_offset * FAILURE_MODES + @intFromEnum(mode));
}
```

Append new modes at the end so existing numbers keep their meaning, and list
them in the component's documentation. Point the offset at the byte the author
should look at, such as the start of a link's attribute value, rather than the
start of the surrounding record. The host quotes the input around that offset
in its error message.

Testing changes with this boundary. A recoverable invalid case must prove that
`render` returns normally with the failure bit set, output is ignored, and a
later valid render succeeds on the same instance. A precondition case
may use `must_trap`; a validator failure inside its declared byte domain uses
`must_reject`.

## Choose The Byte Contract

Use `input_utf8_cap` or `output_utf8_cap` only when the corresponding bytes
must be valid UTF-8. Use the `bytes` capacity exports for arbitrary binary
data. Capacity values are byte counts in both cases.

Add exact MIME metadata when a component requires or guarantees a specific
format. Omit it for intentionally generic UTF-8 or bytes. The
[Content Component Contract](/docs/content-component#optional-content-type-metadata)
defines composition and metadata inheritance.

## Design For Repeated Renders

Hosts may reuse an instance. A trap stops one call; it does not reset WebAssembly
memory or globals.

Reset cursors, overflow flags, parser state, and allocator telemetry at the
start of each render. Once allocation begins, release temporary allocations
before returning or trapping.

Test an invalid render followed by a valid render on the same instance. This
catches stale output lengths, poisoned parser state, and arenas that were not
reset after rejection.

## Test The Contract Boundary

For each component, cover:

- one representative successful input and exact output;
- malformed input that must reject, with its offset and mode, or must trap
  when the component cannot reject cheaply;
- empty input and no-match input, when either is valid;
- the largest supported input or a focused capacity-boundary case;
- output overflow;
- a rejected render followed by a valid render on the same instance; and
- exact MIME metadata for converters and format-specific components.

Use [Bounded Output Proofs](/docs/hard-limits#bounded-output-proofs) when the
compiled component should carry a statically checkable output bound. Follow
[Benchmarking Components](/docs/benchmarking-components) only after behavior
and limits are stable.

## When Not To Use A Content Component

Add [Time and Events](/docs/time-and-events) when state must remain live across
events and scheduled updates. Use Tile for host-managed image regions and
Form for prompt-driven multi-step input; both are indexed from
[QIP Component Contracts](/docs/component-contract).

Content components require the complete input and maximum output to fit their
declared memory. If the workload requires unbounded streaming or data larger
than a practical fixed memory limit, change the boundary rather than hiding the
stream inside an oversized component.
