# How QIP Works

QIP runs small WebAssembly components behind explicit contracts. The host owns
files, network access, clocks, windows, terminals, and application state. A
component receives only the data and capabilities that the host passes to it.

The usual component is an isolated computation over bytes:

```text
                   composable deterministic contract
               ┌───────────────────────────────────────┐
input bytes ──→ │    isolated imperative computation   │ ──→ output bytes
MIME type       │      mutable memory, loops, SIMD      │     MIME type
uniforms        └───────────────────────────────────────┘
```

The implementation inside the box can use ordinary imperative techniques. The
boundary stays small enough for different hosts and components to agree on.

## The Host And The Component

The host loads and instantiates the component. It decides where input comes
from and where output goes. It also applies memory and execution limits.

The component owns one computation. It has WebAssembly linear memory and its
exported functions, but no ambient filesystem, network, environment, clock,
DOM, database, or package graph. A contract can add a specific capability,
such as time or keyboard events, without exposing the rest of the host.

This division keeps normal application work normal. A web app can query its
database, authorize a request, pass selected bytes to a component, and decide
whether to store or return the output.

## One Component Call

A finite transform uses the [Content component contract](/docs/content-component):

```text
host                         component
 │                              │
 ├─ inspect capacities ────────→│
 ├─ copy input to input_ptr ───→│ memory
 ├─ set uniforms ──────────────→│
 ├─ render(input_size) ────────→│ compute
 │←──────── output pointer/size ┤
 └─ read exactly that range ───→│ memory
```

The component declares whether its input and output are UTF-8 or arbitrary
bytes. It can also declare exact MIME types such as `text/markdown`,
`text/html`, or `image/ktx2`.

`render` returns the output location and byte count. A successful call may
produce an empty output. A fallible component can instead return a recoverable
rejection, optionally with an input offset. A trap means the caller broke a
precondition or the component has a defect; the host discards that instance.

For the exact exports and result bits, use the
[Content component contract](/docs/content-component).

## Pipelines Connect Compatible Formats

A pipeline passes one component's output bytes to the next component. The host
tracks the current MIME type and rejects a stage whose declared input type is
incompatible.

```text
page.md                 fragment HTML                 complete HTML
text/markdown           text/html                     text/html
     │                       │                             │
     ▼                       ▼                             ▼
┌──────────────┐       ┌──────────────┐              application
│ Markdown     │ ────→ │ page wrapper │ ──────────→  response, file,
│ renderer     │       │              │              or next stage
└──────────────┘       └──────────────┘
```

The stages do not call each other. The host calls them in order and performs
the copies. This keeps composition visible in a command, recipe, or host
program:

```bash
qip run text/markdown/commonmark.0.31.2.wasm \
  text/html/html-page-wrap.wasm < page.md
```

Some boundaries carry more than one item. QIP uses KTX2 for canonical raster
images, WARC for a routed collection of web responses, and WebAssembly itself
for components that inspect or transform other components. See
[Formats and Encodings](/docs/formats) for these choices.

## State, Time, And Events

A component can retain mutable state after its initial Content render. The
[Time and Events contract](/docs/time-and-events) lets the host advance that
state with a monotonic time and deliver explicit input events.

```text
time  0        120             455                  900
      │         │               │                    │
      S₀ ─────→ S₁ ───────────→ S₂ ───────────────→ S₃
                wake            user event           wake
```

The host opens an update at a time, supplies any uniform overrides, sends
events, and finishes the update. The component returns the next time at which
it wants to wake. An event can cause an earlier update.

Updating and rendering are separate operations:

```text
time or events ──→ update mutable state ──→ committed state
                                                  │
presentation uniforms ────────────────────────────┤
                                                  ▼
                                               render
                                                  │
                                                  ▼
                                        KTX2, text, ANSI, SVG…
```

Only `render` changes the output buffer. Given the same initial input,
uniforms, update times, and events, a conforming component produces the same
state transitions and rendered bytes.

[GUI components](/docs/gui-components) render KTX2 frames. [TUI
components](/docs/tui-components) render UTF-8 or ANSI frames. Both use the
same state-update model.

## The Same Contract In Different Hosts

The component contract does not prescribe an application framework. Each host
maps its own environment onto the same calls.

| Host | What the host owns | What the component does |
| --- | --- | --- |
| `qip run` or `qipx` | Files, standard input and output, pipeline order | Performs finite Content transforms |
| Browser or native app | Windows, input devices, clocks, display surfaces | Updates state and renders GUI or TUI output |
| QIP Router | Paths, source files, HTTP metadata, response delivery | Transforms one response or a complete WARC archive |
| CI or compliance host | Fixtures, policies, timeouts, expected behavior | Runs the implementation or declares compliance cases |

The host may retain an instance for repeated calls. It must replace an
instance after a trap. Instance ownership and concurrency remain host choices.

## Failures Stop At The Boundary

QIP distinguishes expected invalid input from broken execution:

```text
accepted input  ──→ successful output
invalid input   ──→ recoverable rejection
bad call/defect ──→ trap; discard instance
```

Capacity checks protect input and output copies. Fixed memory prevents an
ordinary component from growing without a declared bound. A host can also set
an execution timeout. These controls constrain resource use; they do not prove
that output is correct or safe for its eventual use.

Read [Hard Limits](/docs/hard-limits) for the execution policy and
[`qip comply`](/docs/comply) for checking behavior against executable cases.

## Follow A Site Build

QIP Router applies the same model at two scales:

```text
source file
    │
    ▼
route-selected Content recipe
Markdown ──→ HTML fragment ──→ complete HTML
    │
    ▼
routed responses as application/warc
    │
    ▼
whole-site components
links ──→ metadata ──→ sitemap ──→ static files
```

The router can read the site tree because it is the host. A response recipe
sees the current response bytes. A whole-site component sees the WARC bytes
that the host deliberately supplies. Neither component receives filesystem or
network access.

See [Router](/docs/router) for path resolution and [Recipes](/docs/recipes) for
selection, ordering, and whole-site processing.

## Where To Go Next

- [QIP Component Contracts](/docs/component-contract) helps you choose the
  contract for a component.
- [Adopting QIP In React](/docs/adopting-qip-in-react) shows one component in
  Next.js Server and Client Components.
- [Architecture Boundaries](/docs/architecture-boundaries) explains where to
  put the boundary in a larger system.
- [Writing QIP Components In Zig](/docs/zig-components) shows how to build a
  component with fixed buffers and memory limits.
