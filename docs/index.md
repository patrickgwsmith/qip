# QIP Docs

A QIP Component is a self-contained WebAssembly module with strict input and output. One component's output can become the next component's input, so useful pieces can grow into repeatable recipes.

You can be confident recipes will work identically on mobile, in a browser, in your CI pipeline, on Windows, or whatever comes next. Because components are self-contained with no required dependencies, they can keep working for years.

Your users get small `.wasm` modules that load fast, and you get small amounts of code that are easy to review. You can run AI-generated code without handing it the keys to your machine.

A small function that transforms data should not need a whole application environment around it. Putting them in QIP allows them to become cross-platform, predictable, hard to break, and easy to test.

Components, AI coding, security: you can pick all three.

## Principles

- **Quarantined:** components run in a deterministic sandbox with zero access to the host: no filesystem, no network, and no environment access.
- **Reproducible:** same component, same input/uniforms/events, same output.
- **Portable:** the same `.wasm` runs in the browser, server, CLI, native apps, CI, mobile, and edge.
- **Immutable:** components are self-contained with no required dependencies, so once you have a working component it keeps working with no updates required.
- **Composable:** components pipe together like Unix tools.
- **Agent-friendly:** small modules are easier to generate, review, benchmark, optimize, and replace.

## Names In These Docs

QIP is the portable standard of component contracts, documented in these pages.

[`qipx`](/docs/qipx) is the focused Node.js command-line host for Content and
TUI components, and Compliance oracles. This
repo also contains browser JavaScript hosts such as `<qip-edit>` and
`<qip-play>`, a Go host for repository and router workflows, and native
implementations such as Swift.

## QIP Spec

If you want to send someone the current QIP spec, send them these pages:

- [QIP Component Contracts](/docs/component-contract): the component types, their execution models, maturity, and how hosts distinguish them.
- [Content Component Contract](/docs/content-component): the memory ABI, render lifecycle, content types, and composition rules for finite transforms.
- [Time and Events](/docs/time-and-events): retained state, update transactions, event ordering, wake deadlines, and separate presentation.
- [GUI Components](/docs/gui-components): the composed KTX2 output and browser-host contract.
- [TUI Components](/docs/tui-components): the composed UTF-8, ANSI SGR, keyboard-input, and terminal-host contract.
- [`qip comply`](/docs/comply): the Compliance oracle bridge, ordered oracle calls, memory ownership, and executable conformance checks.
- [Uniforms](/docs/uniforms): optional numeric component configuration and host application rules.
- [Hard Limits](/docs/hard-limits): the constrained WebAssembly subset QIP components should stay inside.
- [Formats and Encodings](/docs/formats): the MIME type and byte-format conventions that let components compose cleanly.

The current Tile and Form interfaces are evolving:

- The repository's `IMAGE.md` for Tile components.
- [Form ABI](/docs/form_abi) for Form components.

[`qipx` CLI](/docs/qipx), [Router](/docs/router), [Recipes](/docs/recipes), and [Browser Elements](/docs/qip-elements) are reference implementation and tooling docs. They are useful when building with this repo, but they are not the core QIP component spec.

## Why WebAssembly

WebAssembly gives QIP a compact execution target with wide runtime support.

A normal execution component is a WebAssembly binary with explicit exports and no imports. By default, QIP gives it no filesystem, network, environment, clock, or secrets. The host writes input bytes into component memory, calls a known export such as `render(input_size)`, then reads output bytes back. Compliance oracles use only the narrow `qip` oracle bridge documented in [`qip comply`](/docs/comply); that bridge does not expose general host capabilities.

That shape gives the host a deterministic execution boundary: the same component bytes and input bytes are guaranteed produce the same output bytes. Components stay small enough to test, benchmark, and replace when better code appears.

PDF/A, PDF/X, and PDF/UA are not replacements for PDF; they are constrained ways to use PDF for archiving, print exchange, and accessibility. QIP plays the same role for WebAssembly: every QIP component is a WebAssembly module, but not every WebAssembly module is a QIP component.

## Why Not WASI

WASI helps WebAssembly programs behave more like portable command-line or server programs. That is the right shape when code needs file descriptors, clocks, randomness, environment variables, sockets, or a virtual filesystem.

QIP is deliberately narrower. QIP is for components that should not need those capabilities. If a component transforms Markdown, validates UTF-8, renders an image tile, or emits an interactive frame, the host can pass the required bytes in and read bytes back out. The component does not need to explore the filesystem, network, clock, environment, or secrets around it.

That narrower subset is easier to run in browsers, easier to inspect, easier to reproducibly test by comparing outputs, and easier to use safely with AI-generated code. If a component needs database access, user settings, or files, your app should fetch that data and pass in the specific bytes the component is allowed to see.

For the concrete runtime limits, see [Hard Limits](/docs/hard-limits). For the boundary model, see [Architecture And Boundaries](/docs/architecture-boundaries).

## Content-First Not File-First

QIP treats content as bytes with MIME types, not as files with special build-system meaning.

That is why recipes are selected by MIME type, why Content components can convert/assert/refine, and why our router works with `application/warc` instead of a particular static-file layout.

For example, `qip router warc ./site` produces a `application/warc` Web Archive. Another component can check for broken links, add extra endpoints, insert meta tags or stylesheets, and turn the archive into a static tarball to be deployed.

## Adopting QIP In An Existing App

QIP fits into existing apps when a small content transform should work the same across platforms, or when generated code should run without filesystem, network, environment, or secret access.

Keep the app in charge of routing, auth, storage, and product workflow. Move a small deterministic transformation into a QIP component: render Markdown, validate HTML, normalize an identifier, transform an image, or generate a QR code. The component gets only the bytes the app passes in, and the app gets portable behavior it can test by comparing output bytes.

See [Adopting QIP In React](/docs/adopting-qip-in-react) for a complete Next.js
Server Component and Client Component example.


<nav class="docs-sidebar" aria-label="Docs">
<ol>
<li><span class="docs-section">Getting Started</span>
<ol>
<li><a href="/docs">Why QIP Exists</a></li>
<li><a href="/docs/how-it-works">How QIP Works</a></li>
<li><a href="/docs/adopting-qip-in-react">Adopting QIP In React</a></li>
<li><a href="/docs/architecture-boundaries">Architecture And Boundaries</a></li>
</ol>
</li>
<li><span class="docs-section">Running</span>
<ol>
<li><a href="/docs/qipx">qipx cli</a></li>
<li><a href="/docs/qip-elements">Browser Elements</a></li>
<li><a hidden href="/docs/javascript-runner">JavaScript Renderer Annotated Source</a></li>
<li><a href="/docs/running-in-javascript">Running In JavaScript</a></li>
<li><a href="/docs/running-in-swift">Running In Swift</a></li>
<li><a href="/docs/running-in-java">Running In Java</a></li>
<li><a href="/docs/running-in-python">Running In Python</a></li>
<li><a href="/docs/running-in-go">Running In Go</a></li>
<li><a href="/docs/running-in-dotnet">Running In .NET</a></li>
<li><a href="/docs/running-in-ruby">Running In Ruby</a></li>
</ol>
</li>
<li><span class="docs-section">QIP spec</span>
<ol>
<li><a href="/docs/component-contract">Component Contracts</a></li>
<li><a href="/docs/content-component">Content Component</a></li>
<li><a href="/docs/time-and-events">Time And Events</a></li>
<li><a href="/docs/gui-components">GUI Components</a></li>
<li><a href="/docs/tui-components">TUI Components</a></li>
<li><a href="/docs/uniforms">Uniforms</a></li>
<li><a href="/docs/hard-limits">Hard Limits</a></li>
<li><a href="/docs/formats">Formats and Encodings</a></li>
<li><a hidden href="/docs/form_abi">Form ABI!</a></li>
<li><a href="/docs/comply">Comply</a></li>
</ol>
</li>
<li><span class="docs-section">Making components</span>
<ol>
<li><a href="/docs/module-patterns">QIP Component Patterns</a></li>
<li><a href="/docs/zig-components">Writing QIP Components In Zig</a></li>
<li><a href="/docs/c-wasm-toolchains">Building C Libraries As QIP Components</a></li>
<li><a href="/docs/benchmarking-components">Benchmarking Components</a></li>
<li><a href="/docs/tracing">Tracing</a></li>
<li><a href="/docs/qip-content-interpreter">Running A Content Component In The QIP Interpreter</a></li>
<li><a href="/docs/wasm-counts">Counting A WebAssembly Module</a></li>
<li><a href="/docs/render-cyclomatic-complexity">Render-Reachable WebAssembly Cyclomatic Complexity</a></li>
<li><a href="/docs/nontrapping-divides">Proving Non-Trapping Divides</a></li>
<li><a href="/docs/interactive-rendering-performance">Interactive Rendering Performance</a></li>
<li><a href="/docs/testing-gui-components">Testing GUI Components</a></li>
</ol>
</li>
<li><span class="docs-section">Router</span>
<ol>
<li><a href="/docs/router">Router</a></li>
<li><a href="/docs/content">Content Layout</a></li>
<li><a href="/docs/recipes">Recipe Layout</a></li>
<li><a href="/docs/routing-recipes">File Routing & Recipe Orchestration</a></li>
<li><a hidden href="/docs/visitor_router_abi_v0">Visitor Router ABI v0</a></li>
</ol>
</li>
</ol>
</nav>
