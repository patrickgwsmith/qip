# Writing QIP Components In Zig

Zig works well for QIP components because it can emit small freestanding WebAssembly without bringing a runtime, filesystem, or package graph along for the ride.

The tradeoff is that you are responsible for being explicit about the WebAssembly shape you want. For QIP, that means exporting a small ABI, using fixed buffers, and compiling with a maximum memory size.

## Build With A Memory Maximum

Compile Zig components with `--max-memory` so the component's worst-case linear memory is visible in the Wasm binary. For the cross-language resource policy, including fixed memory and `memory.grow` checks, see [Hard Limits](/docs/hard-limits).

Without this flag, Zig can emit a memory with an initial size but no declared maximum. That still runs in `qip`, but it is harder to inspect and it fails stricter safety checks that require fixed memory. A maximum also keeps review honest: if a component needs 20 MiB, the build command says so.

Use a value that covers static buffers, stack, and compiler-required runtime space:

```bash
zig build-exe component.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --max-memory=1048576 \
  -femit-bin=component.wasm
```

If the cap is too small, Zig/wasm-ld reports the required size. Raise the limit deliberately rather than using a very large default.

When not to use a tight cap:

- Early prototyping, when buffer sizes are still moving.
- Large static tables, where the right cap is easier to choose after the first successful build.
- GUI components with frame buffers, where width, height, and scratch space should be budgeted together.

Even then, add the cap before checking in the module.

## Minimal Infallible Content Component

This component accepts UTF-8 text and returns it unchanged. It cannot reject a
conforming call, so it does not export `failure_modes_per_input_offset`. It can
still trap if the host violates the input-capacity precondition.

```zig
const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;

var input_buf: [INPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();

    return .{
        .output_size = input_size_in,
        .output_ptr = @intCast(@intFromPtr(&input_buf)),
        .failed = 0,
    };
}
```

The anonymous packed struct is the preferred result type for an infallible
component:

```zig
packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
}
```

Zig stores `output_size` in bits 0 through 31, `output_ptr` in bits 32 through
62, and `failed` in bit 63. An infallible component always sets `failed` to
zero. The checked cast to `u31` also verifies that the output pointer is below
2 GiB.

Do not add a second result struct to an infallible component. Put a short
operation directly in `render`. For a larger operation, use private functions
that return their natural result, such as an output byte count. Test parsers,
formatters, and transforms through those private functions with ordinary Zig
slices. Test the packed pointer and failure bit through a WebAssembly runtime,
where pointers use the ABI's 31-bit address range.

Build it:

```bash
zig build-exe echo.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --max-memory=1048576 \
  -femit-bin=echo.wasm
```

Run it:

```bash
printf 'hello' | qip run echo.wasm
```

## Minimal Fallible Content Component

This component accepts arbitrary bytes and returns ASCII input unchanged. A
non-ASCII byte is valid input for the byte contract, but this component cannot
accept it. The component therefore exports `failure_modes_per_input_offset`
and returns the rejected byte offset without trapping.

```zig
const INPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;

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

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

fn renderOutcome(input_size: u32) RenderOutcome {
    if (input_size > INPUT_CAP) @trap();

    const input_size_usize: usize = @intCast(input_size);
    var input_offset: usize = 0;
    while (input_offset < input_size_usize) : (input_offset += 1) {
        if (input_buf[input_offset] > 0x7f) {
            return .{
                .output_size_or_failure = @intCast(input_offset),
                .output_ptr = 0,
                .failed = 1,
            };
        }
    }

    return .{
        .output_size_or_failure = input_size,
        .output_ptr = @intFromPtr(&input_buf),
        .failed = 0,
    };
}

export fn render(input_size: u32) RenderResult {
    const outcome = renderOutcome(input_size);
    return .{
        .output_size_or_failure = outcome.output_size_or_failure,
        .output_ptr = if (outcome.failed == 1) 0 else @intCast(outcome.output_ptr),
        .failed = outcome.failed,
    };
}
```

`RenderResult` is the packed WebAssembly result. `RenderOutcome` is private and
uses a native `usize` pointer. Native Zig tests can call `renderOutcome` to
check acceptance, the first rejected offset, and recovery on the next call.
Test the packed result through a WebAssembly runtime.

## Defaults We Prefer

QIP components age well when their buffer sizes and memory use are obvious from
the source.

Use these defaults unless the module has a concrete reason not to:

- Static input, output, and scratch buffers sized by named constants.
- No allocator for normal content transforms.
- `@trap()` for violated input preconditions, invariants, and proved-unreachable
  output overflow.
- `error` unions internally, converted to `@trap()` at the exported boundary.
- Small exported surface: QIP ABI exports plus intentional `uniform_set_*` functions.
- `usize` for indexing inside Zig; cast at the ABI boundary.
- `u32` for exported pointer and capacity getters. Use the packed `u64`
  result for `render`.
- Simple `while` loops with visible bounds.
- Explicit content-type exports when the module knows its exact input or output format.

Avoid these by default:

- `@panic` for expected validation failures. Use `@trap()` for a precondition or
  invariant failure. Set the render result's `failed` bit when a conforming
  call can be rejected recoverably.
- Heap allocation for ordinary one-input/one-output transforms. Static buffers are easier to inspect and budget.
- Hidden global state that changes `render` behavior unless it is set through a documented uniform.
- Recursion in modules intended to pass strict safety checks.

This does not mean every useful component must be tiny. It means the cost of a component should be visible in constants and exports instead of discovered at runtime.

## Format Directly Into Fixed Output Memory

A QIP content component writes synchronously into its own linear memory. It does
not need a stream abstraction for flushing, backpressure, files, or network
output. Components intended to have no indirect calls should therefore format
directly into their fixed output buffer.

In Zig 0.15.2, `std.fmt.bufPrint` creates a `std.Io.Writer.fixed`. That writer
stores four function pointers for `drain`, `sendFile`, `flush`, and `rebase`.
The resulting Wasm has a five-slot function table and calls `drain` with
`call_indirect`, even though the component only writes to memory. `ReleaseFast`
and LTO do not remove this dispatch. `std.fmt.printInt` uses the same writer and
has the same binary shape.

Use small slice helpers for literals, decimal integers, and hexadecimal values:

```zig
const OutputError = error{OutputOverflow};

fn append(output: []u8, offset: *usize, bytes: []const u8) OutputError!void {
    if (offset.* > output.len or bytes.len > output.len - offset.*)
        return error.OutputOverflow;
    @memcpy(output[offset.*..][0..bytes.len], bytes);
    offset.* += bytes.len;
}

fn appendByte(output: []u8, offset: *usize, byte: u8) OutputError!void {
    if (offset.* >= output.len) return error.OutputOverflow;
    output[offset.*] = byte;
    offset.* += 1;
}

fn appendDecimal(output: []u8, offset: *usize, value: u64) OutputError!void {
    var digits: [20]u8 = undefined;
    var start = digits.len;
    var remaining = value;
    while (true) {
        start -= 1;
        digits[start] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    try append(output, offset, digits[start..]);
}

fn appendSignedDecimal(output: []u8, offset: *usize, value: i64) OutputError!void {
    if (value < 0) try appendByte(output, offset, '-');
    const magnitude: u64 = if (value < 0)
        @as(u64, @intCast(-(value + 1))) + 1
    else
        @intCast(value);
    try appendDecimal(output, offset, magnitude);
}

fn appendHex(
    output: []u8,
    offset: *usize,
    value: u64,
    minimum_digits: usize,
    uppercase: bool,
) OutputError!void {
    if (minimum_digits > 16) return error.OutputOverflow;
    const alphabet = if (uppercase) "0123456789ABCDEF" else "0123456789abcdef";
    var digits: [16]u8 = undefined;
    var start = digits.len;
    var remaining = value;
    const wanted = @max(minimum_digits, 1);
    while (remaining != 0 or digits.len - start < wanted) {
        start -= 1;
        digits[start] = alphabet[@as(u4, @truncate(remaining))];
        remaining >>= 4;
    }
    try append(output, offset, digits[start..]);
}
```

These helpers have no hidden output destination and no flush step. Every write
checks the same buffer and advances one explicit offset. Convert an impossible
`OutputOverflow` to `@trap()` at the component boundary. Preserve it as a
recoverable internal error when valid input can exceed the advertised output
capacity.

A fixed output schema can remove `OutputOverflow` too. Compute the capacity at
comptime from the complete field-name list, separators, and the maximum encoded
width of each value. Use that same list to render the fields so the capacity
and output cannot drift apart. `application/wasm/wasm-counts.zig`
uses this pattern for its CSV header, metric names, and 20-digit `u64` values.

For floating-point text, `std.fmt.float.render` accepts a buffer directly and
does not currently require `std.Io.Writer`. Confirm the final Wasm shape after
every Zig upgrade. A general format string can still be useful when indirect
calls are acceptable; this guidance is for components intended to satisfy the
no-indirect-call profile.

The repository already uses this direct decimal pattern in
`application/zip/zip-to-tar.zig`.
After changing formatting code, inspect the binary rather than assuming that a
source-level direct call remained direct:

```bash
wasm-objdump -x component.wasm
wasm-objdump -d component.wasm | rg call_indirect
```

## Choose The Right Buffers

Use `input_utf8_cap` / `output_utf8_cap` for text and `input_bytes_cap` / `output_bytes_cap` for raw bytes.

`input_utf8_cap` is a precondition maintained by the host. Component code may
assume that the complete input is valid UTF-8 and should not add another full
validation pass only to establish that fact. Check sequence structure only when
the transform already needs it to decode code points. If malformed UTF-8 reaches
`render`, the host broke the contract and the component may trap.

`output_utf8_cap` is a guarantee made by the component. Emit valid UTF-8 on
every successful return. Later UTF-8 stages may trust that guarantee without
rescanning the output.

QIP checks the host side of the capacity contract before writing input and after `render` returns. The component should still check its own assumptions and trap when an invariant fails. That keeps bugs obvious and prevents accidental truncation.

Good defaults:

- Validate `input_size <= INPUT_CAP` even though the host also checks it.
- Trap when a normalizer or transform receives input outside its declared
  encoding or format precondition.
- Trap on output overflow when the component proves that overflow is
  unreachable for every valid in-cap input.
- Return `0` only when empty output is a meaningful success.

For assertion pass-through validators, return the input pointer without copying
the input. A fallible validator accepts a wider input domain and sets the
`failed` result bit when the input does not establish its output guarantee. A
later transform can require that guarantee and trap if the caller breaks the
precondition.

## Derive Output Capacity From Input Capacity

Prefer a mathematical output bound to a guessed output buffer size. Start with
the largest accepted input, find the transform's maximum expansion, and derive
`OUTPUT_CAP` from `INPUT_CAP`.

For example:

```zig
const INPUT_CAP: usize = 1024 * 1024;

// Every input byte can produce at most three output bytes.
const OUTPUT_CAP: usize = 3 * INPUT_CAP;
```

Other common bounds include:

- pass-through, trimming, and extraction: `OUTPUT_CAP = INPUT_CAP`;
- one fixed prefix byte plus filtered input: `OUTPUT_CAP = INPUT_CAP + 1`;
- Base64 encoding: `OUTPUT_CAP = 4 * ceil(INPUT_CAP / 3)`; and
- a UTF-8 rewrite with a proven threefold maximum expansion:
  `OUTPUT_CAP = 3 * INPUT_CAP`.

Prove the bound for the algorithm, not only for current examples. Account for
terminators, separators, headers, padding, escaping, and final flush output.
Check the capacity arithmetic at compile time so an overflowing calculation
cannot silently produce a smaller buffer.

Keep a guard at the write boundary even after proving the bound. If valid input
reaches that guard, the capacity formula, parser, or generated table is wrong.
The guard should trap as an invariant failure; treating it as ordinary invalid
input would hide the broken proof behind a recoverable error.

Put the proof next to the implementation. Use inline Zig tests for:

- an input that realizes the maximum expansion;
- `INPUT_CAP - 1` and `INPUT_CAP` where both boundaries are useful;
- generated tables whose entries must obey the expansion ratio; and
- a direct assertion that the returned size does not exceed `OUTPUT_CAP`.

Input byte length does not bound every output. A small compressed image or
archive can expand to a much larger result. In that case, define and validate
another finite domain limit, such as maximum width, height, pixel count,
uncompressed bytes, archive entries, or nesting depth. Derive the output buffer
from those limits. If a valid in-cap input can still exceed the advertised
output capacity, overflow is an expected input-dependent failure rather than
an invariant. Under the Content contract, `render` sets its `failed` bit and
returns the component's documented failure detail.

Do not increase a derived output capacity to a round memory profile merely for
consistency. Keep formulas exact enough that reviewers can see why overflow is
unreachable, then budget the component's total Wasm memory separately.

## Export Content Types When Known

Content-type exports make pipelines easier to compose and inspect.

```zig
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}
```

Do not export `text/plain` for generic UTF-8 transforms. The UTF-8 cap already communicates that. Export a MIME type when the component requires or guarantees a specific format, such as `application/wasm`, `text/html`, `image/bmp`, or `image/svg+xml`.

## Use Uniforms For Configuration

Prefer uniforms over parsing ad hoc control bytes from the main input.

Uniforms keep the data plane clean: the input stays the content being transformed, while runtime options configure behavior before `render` runs.

```zig
var color_rgba: u32 = 0x000000FF;

export fn uniform_set_color_rgba(value: u32) u32 {
    color_rgba = value;
    return color_rgba;
}
```

Callers pass uniforms next to the module path:

```bash
qip run image/svg+xml/svg-recolor-current-color.wasm -u color_rgba=0xff5511ff
```

Use packed integer uniforms for compact settings like colors, flags, and modes. Use `f32` uniforms for image math where fractional values are natural.

## Keep The Wasm Easy To Inspect

Sandboxing is not enough by itself. Keep the Wasm easy to audit.

For safety-oriented modules, prefer:

- No imports.
- No `memory.grow`.
- No recursion.
- Fixed-bound loops with a visible counter and exit condition.
- No indirect calls unless there is a specific need.
- Fixed memory maximum via `--max-memory`.
- Small exported surface: only the QIP contract and intentional uniforms.

For strict safety-check-clean modules, replace recursion with an explicit stack. A recursive-descent parser with a `MAX_DEPTH` guard is often fine for practical transforms, but it still has a recursive call graph. If the module is a safety gate, validator, or infrastructure component, use iterative traversal so the binary passes no-recursion checks.

For loops, write the bound in the loop condition when possible:

```zig
var i: usize = 0;
while (i < input.len) : (i += 1) {
    // parse one byte or advance deliberately
}
```

The safety checker looks at the final Wasm. It accepts the normal counter-loop shape where a local counter is compared to a bound, updated by `+1` or `-1`, and then branches back. If a loop advances by variable amounts, make every branch either advance or trap; this is easier to review, but it may still need a simpler counter shape if the strict checker cannot prove the bound.

You can inspect the resulting module with WABT:

```bash
wasm-objdump -x component.wasm
```

Look for a memory entry with both initial and max pages:

```text
Memory[1]:
 - memory[0] pages: initial=... max=...
```

## Makefile Pattern

For checked-in modules, prefer the project rule over a one-off command. The Makefile sets a default `ZIG_WASM_MAX_MEMORY` for Zig modules, and individual targets can override it when they need a larger or tighter budget.

```make
ZIG_WASM_MAX_MEMORY ?= 67108864

%.wasm: %.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

bytes/example.wasm: ZIG_WASM_MAX_MEMORY = 1048576
```

Use the generic default for ordinary modules. Add target-specific overrides for modules with large static buffers, frame buffers, embedded tables, or intentionally tighter safety budgets.

For C components compiled through `zig cc`, pass the linker spelling instead:

```make
text/example-c.wasm: text/example-c.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib \
		-Wl,--no-entry -Wl,--max-memory=1048576 \
		-Wl,--export=render -Wl,--export-memory \
		-Wl,--export=input_ptr -Wl,--export=input_utf8_cap \
		-Wl,--export=output_utf8_cap \
		-Oz -o $@
```

Zig uses `--max-memory=...`; `zig cc` passes `-Wl,--max-memory=...` to the Wasm linker.

## Testing And Review

Each component should have at least one direct smoke test through `qip`.

```bash
printf 'hello' | qip run text/your-module.wasm
```

Use inline Zig `test` blocks for checks tied to the implementation. They are
the best place for:

- exact-capacity boundaries;
- internal output-bound proofs;
- invariant traps;
- parser offsets and private state; and
- regression cases tied to that implementation.

Run them directly while iterating:

```bash
zig test text/your-module.zig
```

Keep portable behavior in a Compliance oracle when alternative
implementations should satisfy the same cases. Do not make a portable oracle
match one Zig implementation's exact buffer capacity. Test that boundary in
the Zig source instead, unless the component contract specifies a minimum
capacity for every implementation.

For binary modules, round-trip through files or compare bytes:

```bash
qip run -i input.bin -- bytes/your-module.wasm > /tmp/out.bin
cmp expected.bin /tmp/out.bin
```

For validators, test both success and failure:

```bash
printf 'valid' | qip run text/your-validator.wasm
printf '\xff' | qip run text/your-validator.wasm
```

For a fallible validator, test recovery on a reused instance: reject a range of
invalid inputs, then feed valid input through the same instance and confirm the
result is still correct. Do not reuse an instance after `render` traps. The
host ignores its output and creates a new instance because a trap does not undo
memory or global changes.

Review the binary shape before trusting the source shape:

```bash
wasm-objdump -x bytes/your-module.wasm
qip run -i application/wasm/your-module.wasm -- \
  application/wasm/wasm-validate-core-2.0.wasm \
  application/wasm/wasm-strict-profile.wasm \
  application/wasm/wasm-bounded-loops.wasm
```

`qip score` is deprecated. Use `application/wasm/wasm-validate-core-2.0.wasm` for complete WebAssembly Core 2.0 validation. The Core 1.0 validator remains available for pipelines that must reject later features. Use `application/wasm/wasm-strict-profile.wasm` for fixed memory, no imports, no banned instructions, no recursion, and static content-type metadata. Add `application/wasm/wasm-bounded-loops.wasm` to prove fixed loop bounds. Use `application/wasm/wasm-bounded-output.wasm` when `render` carries the recognized proof that its successful result does not exceed the static output capacity. Use `application/wasm/wasm-counts.wasm` for factual CSV metrics.

The QIP ABI can be expressed in WebAssembly Core 1.0, while the standard
component build targets Core 2.0 features such as bulk memory. Current Chrome,
Firefox, and Safari releases implement the Core 2.0 feature set, but there is no
single browser switch named “Core 2.0”: support arrived feature by feature and
older browsers remain in use. Check the WebAssembly project's
[Feature Status](https://webassembly.org/features/) table for the first browser
version supporting each feature, and use `WebAssembly.validate()` when selecting
an optional optimized component such as a SIMD variant.

## Checklist

- Pick UTF-8 or bytes caps before writing parsing logic.
- Derive the output cap from the accepted input and maximum expansion.
- Keep input, output, and format-specific limits visible as explicit constants.
- Trap on oversized input and on output overflow that violates the proven
  bound. Use the component's documented way of reporting expected
  input-dependent rejection.
- For a fallible component, test rejection followed by valid input on the same
  instance. After a trap, test the next call on a fresh instance.
- Compile with `--max-memory`.
- Run `wasm-objdump -x` and confirm `max=...` is present.
- Check for accidental imports, indirect calls, tables, and recursion.
- Smoke test with `qip run`.
