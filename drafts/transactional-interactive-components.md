# Earlier Transactional Content, Timed, And Interactive Proposal

> The Timed and Eventful lifecycle has moved to the revised [Time and
> Events](/docs/time-and-events) contract.
> The `begin_at`/`commit` design below records the earlier experiment and is
> retained while remaining components migrate. New implementations use
> `begin_update_at`/`finish_update`; `commit` is only for recoverable Content
> input rejection.

This page records the capability ladder behind the Content `commit` contract
and proposes its Timed and Interactive extensions. The Content call sequence is
now defined in [Content Component Contract](/docs/content-component). The first
experimental Timed component and host path now exercise `begin_at`, `commit`,
complete uniforms, renderless transactions, and KTX2 output. A second component
now exercises transactional key and pointer events. The remaining Timed and
Interactive details are still design work;
the current capability ABI is documented in [Time and
Events](/docs/time-and-events).

The design keeps immediate Content rendering and adds `commit` when a component
supports recoverable rejection. A Timed component adds a monotonic
clock and retained state, so it always needs a commit boundary. An Interactive
component adds ordered events to the same transaction. Only analysis of the
compiled Wasm can show whether a valid call can trap; the exports do not answer
that question.

```text
Content
  render input -> output

Transactional Content
  Content
  + provisional output
  + commit rejection

Timed
  Transactional Content
  + begin_at
  + retained state
  + monotonic time
  + scheduled wakes

Interactive
  Timed
  + ordered events
```

This structure covers an HTML renderer at the Content level, a GIF animation at
the Timed level, and an editor or game at the Interactive level. An animation
does not need placeholder event exports. A component that does not retain state
stays on the simpler Content lifecycle.

### Costs Of The Transactional Extension

Timed and Interactive components gain atomic updates, but the host and
component both do more work:

- The host must track transaction phase, committed time, wake time, and its own
  revision or epoch. A plain Content call does not need this bookkeeping.
- Every transaction repeats the complete uniform set. This makes each proposed
  state explicit, but it adds calls and prevents uniforms from serving as
  retained component state.
- Strictly increasing time requires the host to batch events which occur at one
  observed time. A host may need a logical timestamp when two transactions
  would otherwise use the same millisecond.
- Atomic rejection requires rollback storage or reversible operations inside
  the component. The cost can be significant for documents, frame histories,
  and large game worlds.
- `commit` reports acceptance and the next wake through one signed integer.
  Negative details are diagnostic only, and the ABI does not carry a host-led
  replication revision or reset epoch.

Do not add Timed or Interactive behavior to a stateless transform solely for a
uniform call pattern. Keep it as Content unless it must retain time or logical
state between calls.

These contracts do not require pixel output. `render` can produce KTX2,
HTML, SVG, a UTF-8 xterm-compatible terminal stream, or another declared
Content format. Time and events extend the execution model, not the output
encoding.

### First Timed Implementation

`components/interactive/god-rays-optimized.zig` is the first event-free Timed
component. A new instance starts with the time-zero transaction open. The host
sets all 26 declared uniforms, calls `render(0)`, and calls `commit()`. Later
transactions start with a strictly increasing `begin_at(now_ms)`. They may
commit without rendering while the page is hidden; the output bytes then remain
the previous accepted frame.

The component writes a canonical 640×360 `ktx2-r8g8b8a8-srgb` image. The
experimental Timed path in `site/_elements/qip-play.js` reads the dimensions
from KTX2 instead of framebuffer dimension exports. It coexists with the
legacy `tick` and raw-RGBA path.

`test/god-rays-optimized-timed.mjs` checks the component lifecycle directly.
`test/qip-play-debug-stats.mjs` runs the browser host logic against the tracked
Wasm file. This implementation tests the proposed Timed layer. It does not yet
settle uniform discovery, event signatures, or the complete Interactive state
machine.

### First Interactive Implementation

`components/interactive/tic-tac-toe-sun-moon.zig` adds timestamp-free key and
pointer events to the Timed lifecycle. It has no uniforms, so its complete
uniform set is empty. The component copies committed game state into staged
state at `begin_at`, applies ordered events to the staged state, and publishes
that state only when `commit` accepts the transaction.

The experiment retains the current event result convention: `1` means the
event changed logical or visible state, and `0` means it was ignored. The host
uses that result to avoid rendering an unchanged board. `commit` still decides
whether the complete transaction is accepted. This convention is implemented
for evaluation; the normative event result contract remains open.

`test/tic-tac-toe-interactive.mjs` checks atomic event commits, rejected reset
rollback, timestamp-free signatures, strict time, and KTX2 output. The
`<qip-play>` host test also proves that queued DOM events run after `begin_at`
and before the optional render.

`calculator` and `snake` are the next two migrations. Calculator batches a
sequence such as `2`, `+`, `3`, `=` into one transaction. Snake combines an
event with time advancement and returns its next 120 ms wake. A renderless
Snake transaction advances committed game state without replacing its KTX2
frame.

`render-counts` makes transaction ordering visible. It counts begun
transactions, accepted commits, renders, key events, and pointer events. Event
times come from the enclosing `begin_at` call. The accepted-commit count shown
in a frame excludes that frame's later commit because only `render` may publish
new output.

`mandelbrot` covers retained event state without scheduled wakes.
`perlin-noise` covers held keys, renderless time advancement, and a 16 ms wake.
Perlin calculates long time jumps without stepping through every missed wake.

### Event-Owned Values Are Not Uniforms

`cover-flow` and `shadow-rendering` previously exported uniforms for values
that their events also changed. No host in this repository used those exports.
The migration removes them. Cover Flow retains its feature flags, and Shadow
Rendering retains its six slider values, as component-owned state.

This keeps the current uniform rule simple: the host supplies uniforms, while
events change retained component state. A future component which needs host
configuration only during initialization will need a separate contract. The
current proposal does not define initialization-only uniforms.

## Content May Add Commit

A Content component without `commit` cannot reject a conforming call and remain
usable. If `render` returns, its returned length and output bytes are immediately
valid. If it traps, the host ignores the output, does not call `commit`, discards
the Wasm instance, and creates a new instance before another call.

The allowed input is more than a capacity. It includes the declared encoding,
format, uniforms, and call order. For any call which satisfies those
preconditions, `render` must return normally. A trap means either that the host
broke a precondition or that the component has an implementation defect.
Components may use this rule to avoid repeating validation already guaranteed
by an earlier pipeline stage.

A static analyzer may prove that the compiled Wasm cannot trap when the host
follows the contract. The proof includes input size, valid UTF-8 when declared,
valid call order, and all accepted uniform values. It
must cover every reachable explicit trap, memory or table bounds failure,
integer division trap, float-to-integer conversion trap, indirect call, and
call-stack path. Rebuilding the Wasm requires repeating the proof.

This proof comes from the analyzer, not from an export. The analyzer can also
prove a component with `commit`: expected failures then reach `commit`, while
valid call sequences contain no emergency stop. Without this proof, a host must
remain prepared for a trap whether or not the component exports `commit`.

The two properties are independent:

| `commit` | Static analysis proves valid calls cannot trap | Meaning |
| --- | --- | --- |
| Absent | Absent | Immediate output after return; a trap remains possible |
| Absent | Present | No recoverable rejection is needed and valid calls cannot trap |
| Present | Absent | Rejection is recoverable where implemented; other paths may still trap |
| Present | Present | Expected failures reject and every valid protocol path avoids traps |

The capacity export sets the largest input the host may pass.
`input_bytes_cap` allows any byte string up to that size. `input_utf8_cap`
allows any valid UTF-8 string up to that size; the host validates UTF-8 before
calling a known component. A case converter can therefore omit its own UTF-8
validator without needing to reject malformed UTF-8.

Exact content-type metadata declares a format precondition or guarantee. An
expensive PNG transform may therefore require a valid supported `image/png`
input and trap if the caller passes malformed bytes. At an untrusted input
boundary, the host must not treat a file extension or claimed MIME type as
proof. It can first run a PNG validator which accepts arbitrary bytes, exports
`commit`, and passes accepted bytes through as validated `image/png`. Later PNG
stages can rely on that guarantee without parsing the file twice solely for
validation.

A transactional Content invocation is finite:

```text
uniform_set_<key>(value)
output_size = render(input_size)
result = commit()
```

The transaction is implicitly open. The host writes the input, applies
uniforms, calls `render`, and then calls `commit`. `render` writes provisional
output and returns its provisional byte length. Only an accepted `commit`
makes that length and those bytes valid.

Content has no clock or scheduled wake:

```text
commit() < 0   rejected
commit() == 0  accepted
```

This distinguishes valid empty output from invalid input:

```text
render(input_size) -> 0
commit() -> 0          # accepted empty output

render(input_size) -> 0
commit() -> bitcast_i64(0xc000000000000000)  # invalid input at byte zero
```

Every negative Content result means rejection. Its magnitude is optional debug
information, not application control flow. A component may use this diagnostic
form:

```text
bit 63      error
bit 62      invalid input
bits 61-32  reserved; zero for now
bits 31-0   input byte offset or consumed byte count
```

Bit 63 makes the `i64` negative. Bit 62 distinguishes invalid input from another
processing failure such as output exhaustion. The low word records the first
invalid byte, end-of-input for truncation, or the number of input bytes consumed
before processing stopped. A component which cannot provide a useful position
uses zero. Reporting a position is helpful, not required.

In unsigned construction notation:

```text
error              = 0x8000_0000_0000_0000
invalid_input      = 0x4000_0000_0000_0000
detail_mask        = 0x0000_0000_ffff_ffff

output_exhausted   = error | consumed_input_bytes
validation_failure = error | invalid_input | invalid_input_offset
```

The component bitcasts the constructed `u64` to the returned `i64`. This keeps
all `u32` details, including zero and `UINT32_MAX`, distinct from acceptance.
Hosts treat every negative value as rejection and must not depend on the flags
or detail until a later contract standardizes more than their diagnostic use.
An invalid-input result with zero detail is complete and valid. A component may
leave a source TODO when reporting the exact offset would require more parser
work.

When a Content component exports `commit`, `render` must return normally for
recoverable failures inside its declared input domain. It marks the transaction
invalid instead of trapping. `commit` then rejects and clears pending internal
state. The host ignores the provisional length and output bytes. `commit` must
not trap.

A trap means that the host violated a declared precondition or the component
encountered an unrecoverable defect. Capacity alone does not define the input
domain: malformed UTF-8 violates `input_utf8_cap`, and malformed PNG violates a
component's valid-PNG precondition. After a trap, `commit` does not run and the
host discards the instance without reading output.

A validator has a wider input domain than the components which follow it. For
example, a UTF-8 validator accepts arbitrary bytes, so malformed UTF-8 is a
recoverable rejection for that validator. A Unicode case converter accepts
host-validated UTF-8, so the same malformed bytes violate its precondition and
may trap. Components do not have to validate every byte against guarantees
already established by the host or an earlier validator.

Every Content `render` consumes and resets the public uniform values to their
authored defaults, including after valid empty output or expected failure. A
failable component retains any private normalized candidate values needed by
`commit`. No uniform setter is legal between
`render` and `commit`. If a transaction omits rendering, `commit` consumes and
resets its uniforms instead.

## Timed Adds Transactions

A Timed component retains logical state between calls. It adds `begin_at` to
the Content exports:

```text
begin_at(now_ms: i64)
commit() -> i64
```

A new Timed instance has an implicit initial transaction open at time `0`. This
is the same call shape as Content and renders the first frame:

```text
set every uniform
output_size = render(input_size)
result = commit()
```

The component acts as a Content component for this invocation. `render` is
required and is the final staged operation. An accepted commit establishes both
the initial logical state and output at time `0`.

A later transaction is:

```text
begin_at(now_ms)
uniform_set_<first>(value)
uniform_set_<second>(value)
commit()
```

Every declared uniform must be supplied at least once. A uniform may be set
more than once; its last staged value wins. The complete set is validated as
one candidate, so related values such as width and height do not depend on
setter order.

An accepted transaction replaces the committed logical state atomically. A
rejected normal transaction retains the preceding state. Reset rejection is an
open decision below. In all cases, the pending transaction closes and its
staged values are cleared. Rendering is optional for later transactions. If
present, `render(0)` is the final staged operation before `commit`.

This replaces `tick`. Advancing an animation is a transaction without events:

```text
begin_at(next_wake_at_ms)
set every uniform
commit()
```

The host may commit while the component is offscreen. Time and state do not
depend on whether the host asks for pixels.

## Interactive Adds Events

An Interactive component accepts events after it has received the complete
uniform set:

```text
begin_at(now_ms)
set every uniform
key_event(...)
pointer_event(...)
commit()
```

All events in the transaction occur at the time passed to `begin_at`. Event
exports do not need their own timestamps. Calls are ordered and observe earlier
events in the same transaction. The component publishes none of their effects
unless `commit` accepts the complete transaction.

The host must set every uniform before it sends any event. This ordering lets
an event interpret pointer coordinates, insertion ranges, and other values
against one complete proposed configuration.

Optional event capabilities can extend the body. For example,
`paste_input_event(input_size)` can read a bounded payload that the host wrote
at `input_ptr`. The host must keep those bytes unchanged until `commit`
returns. An optional document snapshot output is a separate feature and is
outside this proposal.

## Transaction State Machine

Timed and Interactive components need an internal phase because their
transactions span several host calls. A Content validator can be smaller: it
only needs to preserve acceptance or rejection between `render` and `commit`.
A zero return from `render` is not enough because it can mean either valid empty
output or provisional failure.

The combined transaction state is one of:

```text
ready
receiving_uniforms
receiving_events
awaiting_commit
invalid
```

`ready` means there is no open Timed or Interactive transaction. The component
can accept `begin_at`. A new Content or Timed instance instead starts in
`receiving_uniforms` with an implicit time-zero transaction. A plain Content
component returns to `receiving_uniforms` after every commit so the next
invocation is implicitly open.

```text
ready
  `- begin_at() -----------> receiving_uniforms

receiving_uniforms
  |-- uniform_set_*() -----> receiving_uniforms
  |-- first event ---------> receiving_events
  |-- successful render() -> awaiting_commit
  |-- failed render() -----> invalid
  |-- valid commit() ------> ready
  `-- validation failure --> invalid

receiving_events
  |-- event() -------------> receiving_events
  |-- successful render() -> awaiting_commit
  |-- failed render() -----> invalid
  |-- valid commit() ------> ready
  `-- invalid field order -> invalid

awaiting_commit
  `-- commit() ------------> ready or receiving_uniforms

invalid
  |-- render() returns 0 --> invalid
  `-- commit rejection ----> ready or receiving_uniforms
```

The destination after commit depends on the component type and transaction mode:

- Content immediately opens its next implicit invocation and returns to
  `receiving_uniforms`.
- Initial and reset Timed or Interactive transactions enter `ready`.
- Normal Timed or Interactive transactions also enter `ready`.

`awaiting_commit` means `render` completed successfully, including when it
produced zero bytes. `invalid` means the pending transaction must reject. A
component enters `invalid` when `render` encounters an expected failure, when a
required uniform is missing, or when uniform and event ordering is invalid.
`render` in this sink state returns zero without changing the outcome, so the
host can still reach `commit` and let the component clean up.

The phase controls call order:

| Phase | Calls accepted by the transaction |
| --- | --- |
| `receiving_uniforms` | Uniform setters; first event or `render` after all required uniforms; renderless `commit` for a normal Timed transaction |
| `receiving_events` | More events, optional `render`, or renderless `commit` |
| `awaiting_commit` | `commit` only |
| `invalid` | Neutral event or setter returns if needed, `render` returning zero, then rejecting `commit` |
| `ready` | `begin_at` only |

Calling `begin_at` outside `ready`, calling another operation after a successful
`render`, or otherwise violating a hard call-phase precondition is host protocol
misuse. The final contract must specify which non-commit calls trap. `commit`
itself must always return without trapping; when the phase cannot be committed,
it returns a negative protocol diagnostic. Once an ordinary validation failure
has moved a transaction to `invalid`, the component must preserve control flow
through `commit`.

The first event is valid only after every declared uniform has been supplied.
Calling an event earlier, or calling a uniform setter after event reception has
started, makes the open transaction invalid. Its eventual `commit` rejects and
rolls back the whole transaction.

`commit` with no events is valid after every uniform has been supplied. This is
the normal Timed lifecycle. A component with no declared uniforms can move
directly from `begin_at` to events or `commit`.

The initial implicit transaction and an explicit time-zero reset require
`render(input_size)`. For these transactions, calling `commit` before `render`
makes the transaction invalid. After `render`, only `commit` is legal. A later
Timed or Interactive transaction may omit rendering so an offscreen component
can advance state without producing output.

Calling `commit` when there is no implicit or explicit transaction is also host
protocol misuse. Even then, `commit` must return a negative protocol diagnostic
rather than trap. Invalid uniform values and invalid event combinations are
ordinary transaction rejection, not host protocol misuse.

### Minimal Failable Content State

A small Content validator does not need separate `ready` and
`receiving_uniforms` phases. It can store only the pending commit result.
`render` initializes that result to rejection, validates and produces
provisional output, then changes the result to acceptance only on its complete
success path. `commit` returns the pending result and clears it without
trapping. Uniform setters do not need to change the phase; `render` consumes and
resets their values before it returns.

If `render` traps, the host does not call `commit`. It discards the instance, so
the component does not need a lazy recovery state for the next invocation.

### Implementing Rollback

The contract requires atomic state changes. It does not require separate
committed and working objects.

A component can keep one committed object and copy it to a working object at
`begin_at`. Events change the working object. An accepted `commit` copies the
working object back. This keeps the committed object unchanged while the
transaction is open, but a successful transaction can copy the full state more
than once.

A component can instead save one rollback snapshot at `begin_at` and let events
change its normal state directly. An accepted `commit` keeps that state without
another copy. A rejected commit restores the snapshot. `paint` uses this model
because its bitmap and undo bitmap make repeated successful copies expensive.

The rollback-snapshot model has limits:

- Every transaction still copies all snapshotted state once. Large documents
  or game worlds may need an undo log, copy-on-write storage, or two state
  buffers with cheap ownership changes.
- A shallow copy is not enough for state which owns mutable data through
  pointers or indexes into a changing allocator. The snapshot must own the old
  data or record how to reverse each change.
- Staged state temporarily occupies the component's normal globals. This is
  safe for current single-threaded components without re-entrant imports. A
  future component that allows concurrent or re-entrant observation needs a
  separate working object or another isolation mechanism.
- A component may exclude a render cache or scratch buffer only when that data
  cannot change accepted behavior. Logical state, random-number state, input
  gestures, animation progress, and document data must roll back together.
- A single published output buffer cannot recover its previous bytes after
  `render` overwrites them. The component must decide every recoverable failure
  before writing output, or render into a private provisional buffer and copy
  it to the published buffer only after success. A successful `render` must not
  be followed by a commit-time validation failure.

The transaction boundary therefore adds memory traffic and implementation
work. Small state machines can use a complete snapshot. Components with large
or complex state should choose a storage strategy explicitly and test both the
accepted and rejected paths.

## Reset And Source Replacement

The initial time-zero transaction is implicitly open. The host does not call
`begin_at(0)` on a new instance. On an existing Timed or Interactive instance,
`begin_at(0)` explicitly opens the same lifecycle as a reset. It starts a new
document or simulation epoch instead of proposing the next time in the current
epoch.

A reset transaction starts from component defaults, receives the complete
uniform set, and can acquire a new external source. For example, a GIF viewer
can use it for its initial GIF and when the user opens another GIF. An editor
can use it when the user opens another document. The reset's rendered output is
provisional until `commit` accepts it.

```text
begin_at(0)
set every uniform
output_size = render(input_size)
result = commit()
```

`render(input_size)` supplies the source length, as it does for Content. It is
required and is the final staged operation before `commit`. This avoids a
separate source-input event and lets a Timed or Interactive component render its
first frame through the Content call shape.

`begin_at(0)` invalidates the previous rendered output. A rejected reset does
not need to restore its bytes; the host ignores the provisional output. The
final contract must decide whether rejection retains the previous logical state
or leaves the component at an empty time-zero state.

A successful reset starts a new epoch—the generation of state created by that
reset—at time `0`. A timestamp therefore identifies state only within one
epoch. Hosts that cache or replicate state must track the epoch or their own
revision as well as `committed_at_ms`.

## Time, Rejection, And Scheduled Wakes

Time is host-provided monotonic elapsed time, not wall-clock time. Within one
epoch:

```text
begin_at(now_ms) requires now_ms > previously_committed_now_ms when now_ms != 0
```

`begin_at(0)` is the reset exception. A host that violates the normal-time
precondition gets an immediate trap. Events with the same timestamp must
therefore be batched into one transaction. A host that needs a transaction
after another event in the same observed millisecond can use a logical
monotonic value:

```text
transaction_time = max(observed_now_ms, committed_now_ms + 1)
```

For the implicit initial transaction and an explicit time-zero reset, `commit`
uses any negative diagnostic result to report rejection:

```text
<0  rejected
 0  accepted; no wake is scheduled
>0  accepted; result is next_wake_at_ms
```

For a normal transaction after `begin_at(now_ms)`, `commit()` returns either a
negative rejection bitfield or one accepted timeline value:

```text
result < 0             rejected; committed time remains unchanged
result == begun_at_ms  accepted; no wake is scheduled
result > begun_at_ms   accepted; result is next_wake_at_ms
```

A nonnegative result below `begun_at_ms` is an invalid component result. The
host already stores the preceding committed time and does not need `commit` to
return it on rejection.

For example, with committed time `100`:

```text
begin_at(120)
commit() -> negative error  # rejected; committed time remains 100

begin_at(120)
commit() -> 120  # accepted; no wake

begin_at(120)
commit() -> 150  # accepted; wake at 150
```

A scheduled wake must be strictly later than the transaction time. When a
transaction is rejected, the preceding wake schedule also remains active. The
host already has that schedule from the preceding accepted commit.

Within an epoch, the committed timestamp is the state version. A replication
system can associate its own host-led revision with the epoch and timestamp.

## Render Stages Output

`render` is optional in a normal Timed or Interactive transaction. When it is
present, it deterministically materializes the proposed state at the
transaction time and then moves the transaction to `awaiting_commit`.

```text
begin_at(now_ms)
set every uniform
send optional events
output_size = render(0)  # optional; final staged operation
result = commit()
```

Only `render` may modify the output buffer. `begin_at`, uniform setters, events,
and `commit` do not modify it.

- A transaction that omits `render` leaves the preceding output intact whether
  commit accepts or rejects it.
- A transaction that calls `render` replaces the output with provisional bytes.
- If commit accepts, the provisional length and bytes become the output for the
  newly committed state.
- If commit rejects, the host must treat the provisional length and bytes as
  logically erased. Their physical memory contents are unspecified, and the
  component does not restore the preceding output.

The output is undefined until the first accepted transaction that includes
`render`. After that, the host can track:

```text
committed_epoch  epoch of the latest accepted logical state
committed_at_ms  time of the latest accepted logical state
output_epoch     epoch currently stored at output_ptr
output_at_ms     time currently stored at output_ptr
```

For example:

```text
committed_epoch = 3
committed_at_ms = 42
output_epoch = 3
output_at_ms = 39
```

This is valid. A background host may accept transactions without rendering.
When it becomes visible, it opens a later transaction and includes `render(0)`
before commit. If it had already rendered the current state but purged only its
GPU texture, it can read the unchanged bytes at `output_ptr` again.

Recoverable render failures inside the declared input domain, such as a
validator finding invalid source bytes or related dimensions failing joint
validation, make the transaction invalid without trapping. The following
`commit` rejects it and gives the component its cleanup boundary. Input outside
the declared encoding or format precondition may trap; the host then discards
the instance without calling `commit`.

## Output Formats

Timed and Interactive output retains the Content model: `render` produces
bytes in the component's declared output format. The execution model does not
require an image. A terminal component can produce a bounded xterm-compatible
text stream, and a document interface can produce HTML or SVG.

### KTX2 Frame Output

The primary pixel output uses QIP's narrow uncompressed
`image/ktx2` `VK_FORMAT_R8G8B8A8_SRGB` profile. The KTX2 header carries the
actual width and height, so the contract does not need separate
`render_width_px` and `render_height_px` exports. The fixed profile lets a host
validate the small header and address the tightly packed RGBA8 payload without
a general KTX2 decoder.

The component exports a fixed output capacity large enough for its compile-time
maximum dimensions. `render` returns the actual KTX2 byte length. Width and
height may be uniforms, but the host must supply them with every Timed or
Interactive transaction and `commit` validates them together.

Presentation size remains a host concern. A browser can scale the committed
framebuffer to its CSS dimensions without changing the component's output.

See [Formats and Encodings](/docs/formats#image-container-names-and-pixel-format-names)
for the canonical KTX2 profile.

## Host Loops

A Timed host loop has no event calls:

```text
begin_at(now_ms)
set every uniform
if visible:
    output_size = render(0)
result = commit()

if result > now_ms:
    schedule result
```

An Interactive loop adds events after uniforms:

```text
begin_at(now_ms)
set every uniform
send ordered events
if visible:
    output_size = render(0)
result = commit()

if result > now_ms:
    schedule result
```

The host reads `output_size` and the output bytes only when the transaction both
included `render` and committed successfully. It should omit `render` when the
component is not visible.

## When Not To Use Transactions

Content adds `commit` only when it needs to distinguish accepted output from
ordinary rejection. A component which has no values to reject does not need the
export, but that omission alone does not prove that valid calls cannot trap. Do
not add `begin_at` to a finite converter only to add another export. `begin_at`
adds retained state, clock management, and replay obligations.

Use Timed when state must advance even when the host does not render output. Add
events only when external interaction changes that state.

## First Content Migration Candidate

`components/multipart/form-data/form-data-to-tar.zig` is a useful first
candidate for rejection through `commit`. Its parser already reports
specific errors for invalid multipart syntax, invalid headers, unsafe paths,
duplicate names, too many parts, and output overflow. The exported `render`
currently converts every one of those expected errors into `@trap()`:

```zig
return @intCast(run(input_buf[0..input_size]) catch @trap());
```

The parser can also write one or more provisional TAR entries before finding a
later invalid part. Under the proposed contract, `render` can retain the parser
error, return normally, and let `commit` reject. The host ignores the partial
TAR, while the component clears its pending state and remains reusable.

`components/text/utf8-must-be-valid.zig` is a smaller second candidate. Its
purpose is to reject invalid UTF-8, and it currently uses traps for every invalid
sequence. It must advertise `input_bytes_cap`, because advertising
`input_utf8_cap` makes the host reject malformed UTF-8 before the component can
inspect it. Its output can share the input buffer: accepted bytes are already
the desired UTF-8 output. Converting it would provide a narrow conformance
fixture for valid empty output versus rejected input, but it exercises less
cleanup behavior than the multipart converter.

`components/text/utf8-must-be-ascii.zig` has the same assertion-gate shape. It
traps on the first byte above `0x7f`; under this proposal it marks the render
invalid and lets `commit` reject. The ASCII and UTF-8 components together can
exercise rejection near the start, middle, and end of an otherwise preserved
input.

## Initial Repository Failure Audit

This is a targeted audit, not a complete classification of every component.
It separates three cases that a source search for traps alone cannot find.

### Definite Current Mismatches

- `components/text/utf8-must-be-valid.zig` declares `input_utf8_cap` while its
  purpose is to receive and reject invalid UTF-8. The host-visible input
  contract excludes its rejection corpus. It also copies accepted input even
  though `output_ptr` can safely identify the same bytes.
- `components/bytes/zlib-decompress.zig` returns zero for malformed streams.
  A valid zlib stream can also decompress to zero bytes, so its return value
  cannot distinguish success from failure.
- `components/image/png/png-to-bmp-b8g8r8a8-srgb.zig`,
  `components/image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.zig`, and
  `components/image/gif/gifsicle-optimize.zig` return zero on parse or decode
  failure. Zero is a byte count in the current Content contract, not rejection.
- `components/image/bmp/bmp-double2.zig` also returns zero for malformed or
  unsupported BMP input. It has the same ambiguity.
The PNG and JPEG paths need an explicit boundary decision. A decoder may accept
arbitrary claimed-format bytes and reject malformed data through `commit`, or
it may require a valid supported image and rely on a validator at the untrusted
input boundary. Its documentation and recipes must make that precondition
clear.

The audit also found two ambiguous zero returns which did not need `commit`.
`e164.zig` now defines no digits as valid empty extraction and has enough space
for its leading `+`. `extract-title-text.zig` now proves output cannot exceed
the selected source title and advertises an output capacity equal to its input
capacity. Their implementation tests exercise the exact capacity bounds;
Compliance oracles cover their behavior without prescribing those capacities.

### Likely Nontrapping Candidates

These components appear able to return normally for every allowed input if
their static bounds are verified:

- `components/bytes/bytes-to-sha256.zig`, `base64-encode.wat`, and
  `crc32-hex.wat`;
- `components/text/trim.c`, Unicode uppercase and lowercase, and other generic
  UTF-8 rewrites whose expansion fits the advertised output capacity;
- generators with no caller-provided source input; and
- extractors such as `youtube-id-extractor.zig` when no match is valid empty
  output and the implementation proves that output cannot exceed capacity.

An overflow check does not by itself require `commit`. If capacities and the
algorithm prove that the branch is unreachable for every valid call, it is a
defensive assertion. Record that proof in tests or with a guard the output-bound
analyzer recognizes instead of relying on an assumption.
Choose the output capacity by deriving it from the allowed inputs and the
transform's maximum expansion, rather than by selecting a convenient round
buffer size. Include prefixes, separators, padding, escaping, headers, and
flush output in the formula. For compressed formats, input byte capacity alone
may not bound decoded output; add explicit limits such as dimensions,
uncompressed bytes, or entry count and derive the output capacity from those
limits. [Writing QIP Components In Zig](/docs/zig-components) gives source and
test patterns for these proofs.

### Components That Normally Need Commit

Validators and assertion gates accept a wider input domain and reject values
which do not establish their promised output guarantee. They need `commit`
unless they deliberately return a diagnostic as successful output. A reporter
that returns an `error` row is not failing if that row is its documented result;
callers can pipeline it as data.

A PNG, JPEG, GIF, BMP, ZIP, PDF, Wasm, JSON, or similar parser does not need
`commit` merely because malformed examples of that format exist. It can require
validated input and trap when the caller breaks that precondition. Use a
separate pass-through validator with `commit` when untrusted bytes must enter
such a pipeline. A combined validate-and-transform component may instead accept
arbitrary bytes and reject malformed data itself.

`svg-to-data-uri.zig` can require valid `image/svg+xml` and avoid reparsing it.
At an untrusted boundary, place an SVG validator before it or use a combined
component which validates and converts.

## Compliance Oracle Changes

Cases inside a validator's declared input domain which fail its promised output
guarantee become `must_reject` cases. The Compliance host:

1. Writes the declared input and applies the case's uniforms.
2. Calls `render` and requires it to return normally.
3. Calls `commit` and requires rejection.
4. Fails the case if either call traps or commit accepts.

`must_trap` remains appropriate for a declared precondition violation. For
example, malformed UTF-8 may trap in a component which advertises
`input_utf8_cap`. The UTF-8 validator instead advertises `input_bytes_cap`, so
its malformed-UTF-8 corpus uses `must_reject`. Oracles must state which domain
they are testing rather than assuming every parser validates arbitrary bytes.

`must_reject` accepts every negative Content `commit` result. It may record the
raw value for debugging, but an oracle must not depend on a specific negative
detail unless a later contract standardizes it.

`must_render_exactly` and `must_render_into` also call `commit` after `render`.
They compare or expose the provisional output only after commit accepts it. This
lets a valid expected output contain zero bytes without colliding with
rejection.

`set_uniform_u32` applies a setter to the next case only. An oracle must call it
again before every case which needs a non-default uniform. The bridge does not
retain desired values between cases. This keeps each oracle case explicit and
keeps the bridge stateless between transactions.

## Migration TODO

The Content part is being migrated now. One event-free Timed component and
three event-driven Interactive components share the new host path;
the general Timed and Interactive contracts remain proposed. Migration requires
coordinated changes because source and compiled `.wasm` files are tracked
together.

### Resolve Contract Details

- [x] Ratify `commit() -> i64` as the way to reject input without trapping. Do
  not interpret absence of the export as proof that valid calls cannot trap.
- [ ] Define how static analysis proves that valid calls to one compiled Wasm
  cannot trap, including host preconditions, covered trap instructions, the
  Wasm file's identity, and invalidation after rebuild.
- [ ] Make the analyzer conservative: return proven or unknown, report every
  unresolved trap site, and never infer a proof from test or fuzz coverage.
- [ ] Define the scope of this proof separately from host cancellation, fuel or
  timeout exhaustion, and failure to instantiate within a host memory policy.
- [ ] Define each set of allowed inputs precisely: byte capacity,
  host-validated UTF-8, valid declared formats, supported format profiles,
  uniforms, and call order.
- [ ] Define repeated Content invocations on a reused instance, including when
  the next implicit transaction opens after `commit`.
- [ ] Specify the normative Content, Timed, and Interactive phase-transition
  tables and classify each illegal call as transaction rejection or a trapping
  host protocol violation.
- [ ] Define how validators refine arbitrary bytes into a valid declared format
  without inventing replacement MIME types. Document when recipe inputs come
  from an untrusted boundary and therefore require validation.
- [ ] Require `commit` not to trap. A normal `render` return is followed by one
  commit; a trapped render is followed by instance disposal, not commit.
- [ ] Decide whether epoch or host-led revision identity remains entirely in
  the host or needs a component export or transaction field.
- [ ] Decide whether a rejected `begin_at(0)` reset retains the previous logical
  state or leaves an empty time-zero state. Its provisional output is invalid in
  either case.
- [ ] Decide whether `begin_at` while not `ready` and `commit` while `ready`
  trap or follow another explicit protocol-error rule.
- [ ] Specify setter return values during a transaction. The current Uniform
  contract returns an independently clamped value, while `commit` must remain
  authoritative for validation involving more than one uniform.
- [ ] Specify how generic hosts discover every required uniform and its authored
  default, type, bounds, step, and enum values. A complete transaction cannot
  depend on reading persistent setter state.
- [ ] Specify event return values and distinguish an ignored event from a call
  that makes the transaction invalid.
- [ ] Confirm that Compliance `set_uniform_u32` retains a bridge-side desired
  map, returns the provisional applied value, and replays the complete map before
  every case.
- [ ] Specify the provisional `render` return value after expected failure. The
  following `commit` result remains authoritative, including when the valid
  output length is zero.
- [ ] Ratify the negative `i64` diagnostic layout: error sign bit, invalid-input
  bit, reserved bits, and low `u32` input offset or consumed byte count.
- [ ] Define optional input events, including input capacity, byte lifetime,
  insertion ranges, and text coordinate units.
- [ ] Defer optional document snapshot output to a separate proposal.
- [ ] Explore physical zero-fill after rejection only as a future optional
  guarantee. It is not required by this proposal; define its range, cost, and
  behavior for shared input/output buffers before adopting it.

### Update Specifications And Detection

- [ ] Replace the current Interactive contract after the Timed and Interactive
  design is accepted. The Content contract now includes optional `commit`.
- [ ] Detect Content by `render`, failable Content by `render + commit`, Timed
  by `begin_at`, and Interactive by event exports.
- [ ] Update [Uniforms](/docs/uniforms) with Content reset semantics, complete
  Timed transaction semantics, and uniform/event ordering.
- [ ] Update [Formats and Encodings](/docs/formats) to define canonical
  `ktx2-r8g8b8a8-srgb` as the primary pixel output without restricting Timed
  and Interactive components to pixels.
- [ ] Add `must_reject` to the standalone example hosts. The Go bridge and
  `qipx` JavaScript bridge now support it. Use it for validator failures inside
  the declared input domain. Keep `must_trap` for declared precondition
  violations and deliberate broken-component fixtures.
- [ ] Add a Compliance operation that distinguishes accepted empty output from
  rejected output after `render` returns zero.
- [ ] Update Compliance archive case names and grammar from `must_trap` to
  `must_reject` where the input is an ordinary rejected value.
- [ ] Update Hard Limits if transaction bookkeeping, KTX2 capacities, or new
  signatures change validation or memory policy.
- [ ] Update testing and performance guidance for deterministic materialization,
  hidden-host commits, and cached output bytes.

### Migrate Hosts

- [ ] Make every Content host call `commit` when it is exported and read
  provisional output only after acceptance. The QIP CLI, Go Compliance bridge,
  and `qipx` now do this. Without `commit`, read output after `render` returns
  and treat a trap as instance failure.
- [ ] Support legacy trap-based Content during migration. Never use missing
  `commit` as a substitute for static analysis of possible traps.
- [ ] Update the Go runtime and dry-run validator in `main.go`,
  `qip_runtime_run.go`, and `qip_runtime_dry.go`.
- [x] Add an event-free Timed path to `<qip-play>` which builds complete
  transactions, decodes the `commit` timeline result, and parses canonical
  KTX2. Keep the legacy Interactive path during migration.
- [x] Add an experimental Interactive path to `<qip-play>` which batches
  timestamp-free key and pointer events inside the Timed transaction.
- [ ] Ratify event signatures and return values before treating that path as
  the replacement Interactive contract.
- [ ] Update other browser and package hosts that currently detect `tick`, raw
  RGBA output, or static framebuffer dimensions.
- [ ] Track committed and output epochs and timestamps independently in hosts.
  Preserve the last wake schedule after rejection.
- [ ] Add background-tab coverage: commit without rendering, then render only
  in a later transaction when visible.
- [ ] Add output-cache coverage: purge the host or GPU copy, reread unchanged
  Wasm output bytes, and avoid a redundant render.
- [ ] Decide how host-led replication revisions map to committed timestamps and
  how replicas detect missing or out-of-order transactions before `begin_at`.

### Migrate Components And Tests

- [ ] First repair and prove components that return normally for every allowed
  input. Remove zero returns that can mean either error or empty output without
  adding `commit`.
- [ ] Then add `commit` to components that can reject values in their declared
  set of allowed inputs.
- [ ] Inventory `@trap()` and `catch @trap()` paths in Content components. For
  each one, record the violated precondition or invariant. Convert it to pending
  rejection only when it is reachable from a conforming call.
- [ ] Inventory `return 0`, `orelse return 0`, and `catch return 0` failure
  paths. Zero remains successful empty output and must not encode rejection.
- [ ] Classify every Content component by two independent properties:
  rejection through `commit`, and static analysis of possible traps.
  Record unresolved output-bound and MIME-validation assumptions.
- [ ] When either pass updates a Content component with uniforms, reset every
  public uniform to its authored default after every normal render outcome. Add
  a repeated-render test which omits setters on the second render.
- [ ] Use `drafts/content-failure-and-uniform-audit.md` as the temporary working
  component list, then delete it when permanent tests and docs cover every row.
- [ ] Migrate `components/multipart/form-data/form-data-to-tar.zig` first. Test
  invalid multipart after a valid part so rejection covers partial output.
- [x] Migrate `components/text/utf8-must-be-valid.zig` as a small rejection and
  valid-empty-output conformance fixture.
- [x] Migrate `components/text/utf8-must-be-ascii.zig` with a declared input
  domain and cover rejection at several input offsets.
- [ ] Add state-machine tests for valid zero-byte output, failed render followed
  by commit, commit before required render, render twice, setters after render,
  events before complete uniforms, and valid reuse after rejection.
- [ ] Add a generic Content contract harness for static ABI analysis,
  fresh-versus-reused differential renders, uniform-reset checks, output-range
  mutation snapshots, negative-result decoding, and recovery after rejection.
- [ ] Fuzz input bytes and lifecycle action sequences. Save minimized inputs
  together with uniforms, transaction times, and the call trace.
- [ ] Test validation offsets at the start, middle, and end of input and
  processing progress at `0`, `1`, and `UINT32_MAX`.
- [ ] Permit a top-of-source TODO for missing invalid-input offsets. Do not
  block commit migration when invalid-input rejection with zero detail works.
- [ ] Add discard-and-reinstantiate tests for documented parser-library traps;
  do not claim same-instance recovery for those cases.
- [x] Migrate `god-rays-optimized` as an animation with no events to prove the
  Timed layer.
- [x] Migrate `tic-tac-toe-sun-moon` as the first small event-driven component.
- [x] Migrate `calculator` to cover several ordered events in one transaction.
- [x] Migrate `snake` to combine events, time advancement, scheduled wakes, and
  renderless commits.
- [x] Remove unused uniforms from `cover-flow` and `shadow-rendering`, then
  migrate both with event-owned retained state.
- [x] Migrate `render-counts` as the transaction-order debugging component.
- [x] Migrate `mandelbrot` as an event-driven component without scheduled
  wakes.
- [x] Migrate `perlin-noise` with held-key time advancement and bounded
  catch-up work.
- [x] Migrate `moon-phases` with source input read by terminal `render` and
  date navigation retained as transaction state.
- [x] Migrate `cover-flow-lofi` and `dock-magnification` with renderless
  animation commits and deterministic reset.
- [x] Migrate `layout-systems`, `browser-security`, and `graph-calculator` as
  event-driven components with no scheduled wake.
- [x] Migrate `tile-world-12x12` and `tetris` with bounded late-time catch-up,
  and migrate `web-mechanics` as an event-driven component.
- [x] Migrate `ieee-754-floats`, `shutterstock-earnings`, and
  `openai-anthropic-arr` with renderless selection transactions.
- [x] Migrate `formula-1-map` with retained map state and
  `page-load-waterfall` with commit-scheduled playback.
- [x] Migrate `photo-light-table` with its private background cache and
  `xbox-dashboard` with a pulse derived from transaction time.
- [x] Migrate `paint` with transactional document and undo state, and
  `ps2-menu` with time-derived pulse and flash animation.
- [x] Migrate `aces-up` with commit-scheduled deal animation, and migrate the
  original `god-rays` port as an event-free Timed renderer with complete
  uniforms.
- [x] Migrate `sudoku` with deterministic puzzle reset, and migrate
  `webos-card-view` with renderless animation commits.
- [ ] Replace `tick(now_ms)` with `begin_at(now_ms)`, complete uniform calls, and
  `commit()`.
- [ ] Remove timestamps from key and pointer event exports.
- [ ] Replace raw framebuffer and dimension exports with canonical KTX2 output
  and a fixed compile-time output capacity.
- [ ] Rebuild every changed `.wasm` artifact with the Makefile.
- [ ] Update direct Wasm, host-loop, browser, protocol-error, rollback, KTX2,
  timestamp, scheduled-wake, and deterministic-render tests.
- [ ] Add tests proving that no call except `render` modifies the output buffer.
- [ ] Add tests for missing uniforms, uniforms after the first event, events
  before all uniforms, rejected commits, and strict `begin_at` time.
- [ ] Rewrite the assertion, transformer, converter, reporter, extractor,
  repeated-render, and boundary-test advice in
  [QIP Content Component Patterns](/docs/module-patterns) around commit rejection.
- [ ] Run narrow tests while iterating, then `make -j test` and
  `make -j site-static` after the coordinated migration.
