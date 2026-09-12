# QIP Component Contracts

Most QIP components accept content, produce content, and finish. Others keep
running so they can animate, respond to input, or update a screen. The contract
defines which functions the WebAssembly module exposes and the order in which
an application calls them.

## Choose A Contract

| Contract | Use it for | How an application runs it | Maturity |
| --- | --- | --- | --- |
| [Content](/docs/content-component) | Text, binary data, documents, validators, generators, and finite renderers | Write one input, call `render`, and read one output | Mostly stable |
| [Time and Events](/docs/time-and-events) | Retained state, animation, input, and scheduled work | Call update functions as time passes or events arrive, then render the new state | Implemented; evolving |
| [GUI](/docs/gui-components) | Graphical applications, games, simulations, and animation | Render KTX2 frames and display them in a graphical host | Implemented; evolving |
| [TUI](/docs/tui-components) | Keyboard-driven terminal interfaces | Render UTF-8 or ANSI frames and display them in a terminal | Implemented; evolving |
| [Compliance](/docs/comply) | Executable specifications for Content components | Run declared cases against a Content component | Evolving |
| `Tile` | RGBA image filters | Process host-managed 64×64 pixel regions, with optional halo pixels | Evolving |
| `Form` | Prompt-driven, multi-step input | Exchange one field value at a time until completion | Evolving |

Choose Content when each call completes one job. Content can still produce an
image, HTML interface, or other rich result. Use Time and Events when the same
component instance must respond again later.

## Combining Contracts

Components that use Time and Events still use Content for their initial input
and rendered output:

```text
Content            render input -> output
Fallible Content   Content + recoverable rejection
Timed              Content + begin_update_at + finish_update
Eventful           Timed + key, pointer, or other events
```

For example, `components/interactive/gif-player.wasm` begins as fallible
Content. A Content host can supply a GIF and receive its first KTX2 frame. A
Timed host can then select later frames at their deadlines. The player has no
event exports because playback needs no keyboard or pointer input.

The output format determines how an application presents that state:

```text
GUI   Content as KTX2       + optional Time and Events
TUI   Content as UTF-8/ANSI + Time and Events + key_event
```

The linked GUI and TUI pages define their output formats and host rules.
[Uniforms](/docs/uniforms) defines optional numeric settings shared by these
contracts.

## How Tools Select A Contract

The command and a small number of distinguishing exports select the execution
path:

1. A pipeline module with `tile_rgba32float_64x64` uses Tile. Other pipeline
   modules use Content, even if they also export Time and Events.
2. `<qip-play>` runs Time and Events components and presents either a supported
   KTX2 profile or `image/svg+xml`. KTX2 components use the GUI contract; SVG
   components retain the generic Time and Events contract.
3. `qip tui` and `qipx tui` use the TUI contract for the first stage. Later
   stages are finite Content transforms over each rendered frame.
4. `qip form` uses Form.
5. `qip comply --with` uses Compliance and requires an exported `memory` and
   `comply() -> i32` entry point.

`qip run` invokes only Content. It can perform the initial render of a
component with Time and Events, but it does not open updates or deliver
events. When exports overlap, the selected command and the rules above decide
which behavior the host invokes.

## Shared Rules

Pointer, size, and capacity values are zero-argument functions returning
`i32`. A WebAssembly global with the same name does not satisfy a contract.

All components operate within [Hard Limits](/docs/hard-limits).
[Formats and Encodings](/docs/formats) defines the byte formats and MIME
conventions used at composition boundaries. A component must not assume
filesystem, network, environment, clock, or other host access unless its
contract explicitly provides it.

`IMAGE.md` documents the current Tile interface, and [Form ABI](/docs/form_abi)
documents Form. Components may need to be rebuilt when an evolving contract
changes during QIP alpha.
