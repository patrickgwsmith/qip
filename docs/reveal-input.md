# State as Input (Proposal)

**Status: pending design.** This page specifies a proposed optional export. No component or host is required to implement it yet. It does not change the current [Content](/docs/content-component) or [Time and Events](/docs/time-and-events) contracts until adopted.

A component may be able to express its current state as ordinary input. For example, a search interface might reveal:

```text id="9cj2lq"
q=&sort=relevance
```

before it has rendered anything. A host can inspect those values, present native controls, change the input, and render the component.

A timed or evented component can also accumulate state that its initial input no longer describes: a selected date, a search query, an open panel, or a position in an animation. The same operation can reveal that current state as input. A host can save the bytes, create another instance of the same component, and supply them to its first `render`.

This makes two useful models possible:

```text id="5ifc1c"
Stateless

host-owned input ──► render(n) ──► output
       ▲
       │
 reveal_input()


Stateful

initial input ──► component state ──► output
                       │
                       │ reveal_input()
                       ▼
                     input
```

A component chooses its input representation and must be able to read revealed input again.

The core question answered by the export is:

> **What input represents this component now?**

The host does not need to know how the component represents state internally or which earlier operations caused that state to change.

The contract has two important properties:

**Restorable.** `reveal_input()` produces valid input that a fresh instance of the same component artifact MUST accept. After a successful render, it restores equivalent observable state; before the first render, it provides valid default input for initialization.

**Read-only.** `reveal_input()` MUST NOT change the component's committed state.

QIP components are deterministic and have no access to outside state, clocks, randomness, or I/O except through their explicit inputs and calls. The same component state therefore produces the same revealed input without requiring a separate determinism rule for this export.

This is useful for native host controls, discovering defaults, persistence, transfer between hosts, and interfaces that rebuild a component when form input changes. It costs input capacity and, when state is not already kept as input, code for producing and restoring the representation.

A component does not need this export if the host already has all the input needed to reproduce its current behavior.

## Proposed Export

```text id="0i0h78"
reveal_input() -> i32
```

The export is optional. A component that exports it MUST also export `input_ptr()` and exactly one of `input_utf8_cap()` or `input_bytes_cap()`.

An inputless generator cannot export `reveal_input()` under this design. A generator that wants to reveal its state must accept input, including valid zero-length input if it wants to retain its inputless start behavior.

`reveal_input()` makes the component's current state available as valid input at `input_ptr()` and returns its length in bytes.

The host does not need to know whether those bytes were already present, were maintained as working storage, or were materialized by the call.

The length MUST be in `0..input_capacity`, inclusive. The bytes MUST obey the declared UTF-8 or arbitrary-byte input rule and any declared input content type.

The returned bytes MUST be accepted as initial input by a fresh instance of the *same component artifact*. Its first `render(revealed_size)` MUST NOT recoverably reject those bytes.

The return value is an unsigned 32-bit size, not a pointer or a packed `render` result. No bit, including the high bit, signals an error.

`reveal_input()` has no recoverable rejection. If a component cannot represent its state within its declared input capacity, it must not offer this export. A violated precondition or broken component invariant traps. After a trap, the host discards the instance and reads no revealed input bytes.

The exception is a component whose preceding `render` recoverably rejected its input. The behavior of `reveal_input()` in that state is unspecified, as described below.

## Default Input

A host MAY call `reveal_input()` immediately after instantiating a component, before its first `render`.

At this point, `reveal_input()` returns the component's **default input**.

For example, a component with `application/x-www-form-urlencoded` input might reveal:

```text id="t9bxxi"
q=&sort=relevance
```

A host can use this input without first asking the component to render. It might inspect the fields, present native controls, modify documented editable values, and supply the resulting bytes to the first `render(input_size)`.

Default input MUST use the component's input format, but it need not be accepted by `render`. For example, it may leave required fields empty for the user to fill in. A component whose default input can be rejected MUST reject it as an ordinary failure (see [Failures and errors](/docs/content-component#failures-and-errors)), not trap.

Calling `reveal_input()` before the first render does not initialize the component, render output, advance time, or otherwise advance its lifecycle. It only makes the input representation of its default state available.

Bytes a host has written to the input buffer but has not supplied to a component call are not necessarily the component's current state. A pre-render `reveal_input()` may overwrite those bytes with the default input. The host MUST keep its own copy if it still needs them.

## When It May Run

A host MAY call `reveal_input()` whenever no update is open.

For example, it may call it:

- immediately after instantiation;
- after a successful `render`;
- after `finish_update()`; or
- after another `reveal_input()`.

Calling `reveal_input()` between `begin_update_at()` and `finish_update()` is a contract violation and traps.

After a recoverable `render` rejection, the behavior of `reveal_input()` is unspecified until a later `render` succeeds. It MAY make input available or trap. The host MUST NOT rely on either behavior, assume that previously revealed input remains available, or read the input buffer as revealed state.

A component may choose to make its default input available after a rejected render. This can be a convenient implementation strategy, but the host MUST NOT rely on it.

A rejected render may have changed the input buffer or other working memory before finding the error. A host that retries MUST write fresh input bytes before calling `render` again. A later successful render restores the usual `reveal_input()` guarantees.

This proposal does not otherwise prescribe which component operations may affect what a later `reveal_input()` reveals. Those effects belong to the contracts of those operations.

## Read-only

`reveal_input()` MUST NOT change the component's committed state: the state from
which later renders and updates proceed. This does not preserve earlier memory
views or uncommitted bytes that a host wrote into the input buffer.

In particular, it MUST NOT advance time, process events, render output, or open or finish an update.

It MAY modify module memory as necessary to make the revealed input available at `input_ptr()`. It may also perform internal bookkeeping that has no observable effect on subsequent component behavior.

For example, a component may encode an internal tree or rope into its input buffer when `reveal_input()` is called. It may not reset a counter, move a selection, advance an animation, or otherwise alter the state being represented merely because the host asked to reveal it.

Its result MUST be independent of the *current values* of public uniforms. Effects of earlier operations involving uniforms may be represented in the component's current state and therefore in revealed input.

Because QIP execution is deterministic, repeated calls to `reveal_input()` with no intervening component call or host memory write necessarily return the same result. This follows from the existing QIP execution model rather than imposing an additional property on `reveal_input()`.

## Input as Working Storage

A component MAY use its input buffer as working storage.

For example, a text editor could keep its editable text directly in the input buffer. For such a component, `reveal_input()` might need to do little more than return the current length.

Another component may consume input and construct completely different internal data structures. Its `reveal_input()` may need to encode those structures back into the declared input representation.

These are implementation details. A host MUST NOT know or care which approach a component uses.

A host MUST NOT inspect the input buffer to infer current state before `reveal_input()` returns. Only the returned range is guaranteed to contain the revealed input representation.

The host MUST copy those bytes before another component call or host write to module memory can change them.

A `reveal_input()` call may overwrite an earlier output range that aliases the input buffer. A host that needs that output MUST copy it first. `reveal_input()` may therefore invalidate a previous output view through aliasing, although it does not render new output.

The current Content contract permits output to alias input only when `render` returns an immutable slice of that input; newly written output must be disjoint. Allowing an in-place output transform would require a separate change to that rule. This proposal does not otherwise define whether component operations may mutate input.

## Stateless Components

`reveal_input()` does not imply that a component is stateful.

A form-driven Content component can use host-owned input as the complete description of each render:

```text id="56mzgz"
q=web
    ↓
render(n)
    ↓
output

q=webassembly
    ↓
render(n)
    ↓
output
```

Each render can be treated as an independent input-to-output transformation. The host owns the changing form state.

Such a component does not need `begin_update_at()`, `finish_update()`, or events merely to edit text.

`reveal_input()` can still be useful before rendering to expose the component's default input:

```text id="pm6lgc"
instantiate
    ↓
reveal_input()
    ↓
q=
```

The host can modify that input and supply it to `render`.

This is particularly useful for text-input TUIs. A browser host could use an HTML `<input>`, a macOS host could use an `NSTextField`, a Windows host could use a native text control, and a terminal host could use its own line editor.

The host handles Unicode text entry, input method composition, selection, clipboard operations, platform editing shortcuts, accessibility, and similar native behavior. It then encodes the resulting value into the component's declared input representation.

For example:

```text id="lcp05u"
instantiate
    ↓
reveal_input()
    ↓
q=
    ↓
host presents native text field
    ↓
user enters "webassembly"
    ↓
q=webassembly
    ↓
render(n)
    ↓
output
```

No keyboard events or update loop are required for the text editing itself.

Events remain useful for interaction that is naturally event-driven, such as navigation, shortcuts, pointer interaction, games, or other behavior that should be handled by the component rather than by a native host control.

The distinction is:

```text id="ojq9c9"
input    describes content or state
events   describe interaction
```

A component may use either model or combine them.

## Timed and Evented Components

A timed or evented component may use `reveal_input()` to make its current state portable.

For example:

```text id="5z74qf"
render(initial_input_size)

begin_update_at(now_ms)
set update uniforms
send events
finish_update()

size = reveal_input()
copy memory[input_ptr() .. input_ptr() + size]
```

The revealed input can then be stored, transmitted, duplicated, or supplied to another instance.

In this case, `reveal_input()` provides snapshot-like behavior without defining a separate snapshot representation: the snapshot is ordinary component input.

Updates may affect what a later `reveal_input()` reveals. This proposal does not require the host to know which internal state changed or how the revealed representation is produced.

## Restorable

Bytes returned by `reveal_input()` MUST be accepted as initial input by a fresh instance of the same component artifact. Its first `render(revealed_size)` MUST succeed rather than recoverably reject those bytes.

If `reveal_input()` ran after a successful render, the fresh instance MUST then
have equivalent observable state to the source instance at the reveal call.
If it ran before the source instance's first render, compare the two instances
*after each has rendered the revealed default input* with the same initial
uniforms. There is no rendered state to compare before initialization.

Equivalence includes subsequent rendered output and the behavior of later updates for the same future inputs. It does not require identical private memory, pointer values, caches, data structures, or other implementation details.

Compare renders with the same presentation-uniform values, and compare updates with the same event sequence, update-uniform values, and elapsed times.

A new instance has a new host clock. If state depends on time, the revealed input MUST preserve enough information to resume it on that new clock; it cannot require the host to reuse the old instance's absolute `now_ms` values.

Historical uniform effects that changed relevant state MUST be represented by the revealed input. A fresh instance MUST NOT require an out-of-band copy of the old instance's memory, events, source bytes, uniform history, or other host state.

This guarantee concerns the component's observable behavior. It does not promise that a host can arbitrarily edit revealed bytes and obtain another valid state. A component must separately define which input fields are user-editable.

## Host Sequences

A timed or evented host can persist and restore a component:

```text id="edmoxj"
instantiate component
write initial input at input_ptr, if any
set initial uniforms, if any
render(initial_input_size)

begin_update_at(now_ms)                   # optional, repeatable
set update uniforms and send events
finish_update()

copy any output that must remain available
size = reveal_input()                     # no update open
copy memory[input_ptr() .. input_ptr() + size]

instantiate the same component artifact
write copied bytes at the new input_ptr
render(size)                              # MUST succeed
```

A stateless form-driven host can instead begin by asking the component for its default input:

```text id="l1rj38"
instantiate component
size = reveal_input()
copy memory[input_ptr() .. input_ptr() + size]

present host-native controls
edit documented input fields

write edited input at input_ptr
render(edited_input_size)
```

The host checks input capacity and UTF-8 rules as it does for ordinary Content input. It treats revealed bytes as component input when storing or transmitting them.

If the artifact changes, migration is the application's responsibility. This proposal does not define a cross-version state format.

## Input Discovery

A host can inspect the declared [input content type](/docs/formats) and call `reveal_input()` before rendering to learn the component's default input values.

For an `application/x-www-form-urlencoded` component, the default input might be:

```text id="ql7wko"
q=&sort=relevance
```

The empty values are still present, allowing a host to discover the keys `q` and `sort` and potentially present controls for them.

The MIME type specifies the encoding. It does not specify labels, field types, allowed values, validation rules, or whether every key is user-editable. Keys may also vary with state.

A host that needs a stable form schema must obtain that information from an additional convention or application configuration.

`reveal_input()` therefore reveals concrete input, not an input schema.

## Text Input in a TUI

A query-driven [TUI](/docs/tui-components) could accept `application/x-www-form-urlencoded` input containing a `q` field.

A browser host could show a real text input. A terminal host could show its own line editor beside the rendered output. Other native hosts can use their platform text controls.

Those hosts collect text using their native editing systems and encode the resulting value as UTF-8 form data. QIP does not need to model IME composition, selection, paste, accessibility editing behavior, or ordinary text entry as keyboard events.

For a stateless component, the host can keep the evolving form state and supply each version directly to `render`:

```text id="pychvm"
reveal_input() -> q=

host edits:
q=w
    ↓
render(n)

host edits:
q=wa
    ↓
render(n)

host edits:
q=wasm
    ↓
render(n)
```

The component does not need an update loop merely to receive edited text.

For a stateful component, one possible flow is:

```text id="99ysn7"
reveal current input
        ↓
change a documented editable field such as q
        ↓
create a fresh instance
        ↓
supply the edited input to its first render
```

The component must define how other fields preserve state and how it treats edits to unknown or invalid fields.

The current Time and Events contract uses initial input on the first `render`; later presentation uses the existing timed or evented state. This proposal does not add a live input-submission operation to an existing timed or evented instance.

A host that needs to change input on an existing stateful instance still needs a separate event or update contract, or it can create a fresh instance.

## When Not to Use `reveal_input()`

Do not export `reveal_input()` merely because a component accepts input.

A Markdown renderer, image decoder, PDF viewer, image cropper, or similar Content component may already receive everything it needs as host-owned source input. If the host can retain those bytes directly, revealing them again provides little value.

Avoid `reveal_input()` when the component cannot represent its default state as valid bounded input, when its complete restorable state cannot fit within its declared input capacity, or when restoration requires host resources not represented by its input.

Use an application-level persistence format when state must survive changes to the component artifact or be interpreted independently of it.
