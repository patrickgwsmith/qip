# Architecture boundaries

This page is for engineers deciding whether to move part of an existing
application behind a QIP boundary, and for the reviewers who approve that
change. It covers what a component can reach, what belongs inside one, where it
runs, and what the boundary costs.

QIP runs selected computations behind a narrow WebAssembly boundary inside a
normal application. The host supplies input bytes and uniforms, and may grant
capabilities such as Time and Events. The component returns output bytes. Run
the code you trust least where it can reach least.

QIP is not an application framework or a service boundary. Your application
keeps its routing, authentication, database, and deployment, and calls a
component where it would otherwise call a library function.

```text
┌──────────────────────── trusted application ────────────────────────┐
│ authorize request → query database → choose component               │
│                                         │                           │
│                                  explicit bytes                     │
│                                         ▼                           │
│                                ┌─────────────────┐                  │
│                                │  QIP component  │                  │
│                                └─────────────────┘                  │
│                                         │                           │
│                                  output bytes                       │
│                                         ▼                           │
│                         validate → store or respond                 │
└─────────────────────────────────────────────────────────────────────┘
```

## Components get only what the host passes

A normal QIP component receives no ambient filesystem, network, environment,
clock, DOM, database, or secrets. Its host imports define what it can do.
Without additional imports, a component cannot directly:

- read application secrets or environment variables;
- query a database;
- open files or sockets;
- inspect process globals or the DOM;
- install or load packages; or
- call platform APIs.

```text
ambient design:    code ──→ reaches into process and platform state

QIP design:        host ──→ bytes, uniforms, time, events ──→ component
                     ↑                                            │
                     └───────────── declared output ──────────────┘
```

This is the main reason to add the boundary. Code that cannot reach secrets,
files, the network, or the DOM is easier to approve, including generated or
third-party code that you did not write. Review becomes concrete: inspect the
imports and the bytes supplied at each call. Fixed memory and host timeouts
also limit resource use, and explicit capabilities make a component easier to
run in another host.

Content components receive input bytes and uniforms. A host can add the Time
and Events capability for retained state. Compliance oracles receive only the
small bridge used to declare cases. A new capability should name the data or
operation that the host is granting.

### Time is an input

A QIP component does not call a clock. The host passes `now_ms` to
`begin_update_at`, which makes each instant part of the recorded call sequence.
A test can supply exact boundaries, long delays, and overflow cases without
installing a fake clock. The component returns the next absolute time at which
it wants an update, while the host remains responsible for waiting. TigerBeetle
describes the same design move in
[Tracking Time Without Clock](https://tigerbeetle.com/blog/2025-10-21-clockless-time/).

### Isolation limits reach, not correctness

WebAssembly isolation does not prove that a component is correct. A component
can return malformed JSON, inaccurate calculations, misleading pixels, or
unsafe HTML. It can also consume its full declared memory or run until the host
timeout. Validate on both sides of the component:

```text
untrusted bytes → validate format → transform → validate or escape for use
                       │                              │
                 component input               application boundary
```

A known component may rely on its declared input profile. The application must
establish that profile where untrusted data enters. A generic host that accepts
arbitrary Wasm must also validate the module, its QIP exports, and its memory
ranges before execution.

Check output for its destination. HTML may need sanitizing or a sandboxed
preview. A file path needs path policy. A returned Wasm module needs validation
before execution. An image still needs size limits before decoding or
allocation.

## What goes in a component

A good component performs a finite operation with a clear input, output, and
failure policy. Examples in this repository include:

- Markdown to HTML;
- HTML validation and accessibility analysis;
- JSON formatting and CSV extraction;
- image decoding, resizing, filtering, and encoding;
- URL to QR-code SVG;
- text or HTML rendering to SVG;
- GUI and terminal state machines; and
- WebAssembly validation, inspection, translation, and instrumentation.

Use a component when portability, deterministic behavior, isolation, or exact
testing justifies an explicit byte boundary. A normal library call is simpler
when those properties do not buy anything for the application.

### Choose the bytes that cross

The boundary should preserve the information needed by the next stage without
exposing the host's internal objects.

| Boundary | Use it when | Repository example |
| --- | --- | --- |
| One value or document | One operation consumes and produces finite content | Markdown to HTML, JSON formatting, URL to SVG |
| Canonical raster image | Several components need direct pixel access | QIP KTX2 profiles between image components |
| Routed site | A transform needs to inspect or change several responses | WARC link checking, metadata, and static export |
| Retained render state | Time or user input changes later output | GUI and TUI components |
| WebAssembly module | A component inspects or transforms another component | Wasm checks, counts, translators, and instrumentation |

Prefer an existing format with a precise profile. Add an application-specific
format when existing formats cannot preserve the required semantics. Do not
pass a database handle or application object graph merely to avoid defining
the bytes.

See [Formats and Encodings](/docs/formats) for QIP's current boundaries.

## Where components fit

### A transform inside an application

An application loads or receives data, calls one or more components, and then
continues in normal code:

```text
app data → serialize → component pipeline → validate output → app data
```

This works well for converters, validators, formatters, and renderers shared by
web, server, CLI, CI, native, or mobile applications.

### A content or whole-site pipeline

QIP Router can select a Content recipe from a source MIME type and apply it to
one response. It can then package every routed response as WARC and run
whole-site components.

```text
source bytes → response recipe → routed response
                                      │
all routed responses ─────────────────┘
              │
              ▼
            WARC → check links → add routes → static output
```

Keep filesystem discovery and HTTP delivery in the router. Keep byte-level
response and archive transforms in components.

### A GUI or TUI render loop

The host owns the clock, input devices, and presentation surface. The component
owns retained state and renders the current view.

```text
clock + events → component state → KTX2 frame → graphical host
                                └→ ANSI text  → terminal host
```

Use [GUI Components](/docs/gui-components) or [TUI Components](/docs/tui-components)
for these output conventions.

### Components that process components

WebAssembly can cross the Content boundary like any other binary format. This
lets one component inspect or transform another without putting the operation
in every host:

```text
component.wasm → Wasm checker or translator → report, source, or component.wasm
```

The outer component still has bounded memory and no ambient host access. The
host decides whether a returned module is trusted enough to execute.

<h3 id="server-or-browser">Server or browser</h3>

The same component can run in either place. The right location depends on the
data and the authority of the result. A server does not make HTML safe, and a
browser does not make a result authoritative.

| Run on the server when | Run in the browser when |
| --- | --- |
| The result controls acceptance, authorization, billing, storage, or publication. | The result is a preview or presentation detail. |
| The input contains server-side or shared private data. | A local file should remain on the user's device. |
| All clients need one canonical result for caching, indexing, or reproducibility. | Low latency, offline use, or interactive rendering is useful. |
| Output must be checked before another user receives it. | Output can go to a non-active sink such as pixels, a canvas, or `textContent`. |

Because one component runs in both, a hybrid design is cheap:

1. Run the component in the browser for an immediate preview.
2. Submit the source data to the server.
3. Run the component again on the server for the canonical result.
4. Validate or sanitize the output before the host stores or serves it.

Run presentation near the user. Run security decisions where the application
holds authority.

## Your application keeps its authority

The host keeps work that depends on application authority or platform
integration:

- routing, authentication, authorization, and sessions;
- database queries, transactions, and object models;
- filesystem and network access;
- logging, metrics, tracing, queues, and background jobs;
- framework lifecycle, window management, and device APIs; and
- decisions about where component output is stored, displayed, or sent.

Normal application code can run before, after, or between QIP components. The
host fetches the required data and passes only the relevant bytes into the
component.

Your existing web security controls stay where they are. Authentication,
authorization, CSRF protection, output escaping, HTML sanitizing, Content
Security Policy, and browser-origin decisions remain the application's
responsibility. QIP reduces a component's blast radius; it does not replace
these controls.

### Keep CSRF protection in the host

Cross-Site Request Forgery (CSRF) is a property of the HTTP request and
session, not of the component that processes the request body. Check
authorization and CSRF protection before invoking a component for a
state-changing request. A component result is not proof that the user intended
the request.

```text
HTTP request → host: authenticate, authorize, check CSRF → QIP component
```

CSRF tokens belong to the host. Prefer letting the host add the CSRF field
around the component's HTML. If the component must render the complete form,
pass the token as an explicit, opaque input, which keeps execution
deterministic, and escape it for its HTML context. Do not ask the component to
generate the token, and do not put it in URLs, logs, shared caches, snapshots,
or diagnostic output.

Use the application's existing CSRF support. The
[OWASP CSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)
covers tokens, Fetch Metadata, origin checks, and `SameSite` cookies.

### Treat HTML and SVG as active output

A component that cannot access the DOM, cookies, or network can still return
unsafe HTML. The browser runs that HTML with the authority of the page if the
host puts it into an unsafe DOM sink.

- Insert plain text with a text API such as `textContent`.
- Escape values for the HTML, attribute, URL, CSS, or JavaScript context in
  which they appear.
- Sanitize untrusted HTML with a maintained sanitizer before insertion.
- Treat arbitrary SVG as active content when it is inserted as document
  markup.
- Prefer pixels, a canvas, or another non-markup output for an untrusted
  visual preview when those formats meet the requirement.

Content Security Policy and Trusted Types add protection, but they do not
remove the need for correct escaping and sanitizing. The
[OWASP XSS Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html)
lists the controls for each browser context.

An existing XSS flaw can also change browser-side component inputs, bypass the
component, or submit requests as the user. Do not rely on browser-side
component output for authorization or another security decision.

## What the boundary costs

The boundary is not free:

- The host may need to serialize data and copy bytes into and out of linear
  memory.
- Components need explicit capacities, failure behavior, formats, and
  lifecycle rules.
- Host-specific objects and APIs require adapters instead of direct calls.
- Debugging crosses a host/component boundary rather than one native call
  stack.
- Wasm artifacts must be built, tested, versioned, and distributed with their
  source.
- Fixed memory is a poor fit for operations whose working set has no useful
  bound.

These costs are worthwhile when the boundary improves portability, review,
testing, replacement, or containment. They are overhead when the code is
already trusted, local, and tightly coupled to one host.

### When not to use QIP

Keep work in normal host code when it needs live database access, open-ended
networking, secrets, platform UI APIs, framework lifecycle hooks, background
services, or large shared mutable state.

Do not split a coherent operation into many components only to maximize the
number of boundaries. Each boundary should identify useful data, isolate code
with a different trust or lifecycle, or enable reuse across hosts.

## Checklist

Before adding a component, answer these questions:

1. What precise operation moves behind the boundary?
2. Which bytes, MIME type, uniforms, time, or events does it receive?
3. Which output and failure states can it produce?
4. What remains in the host?
5. Where is untrusted input validated?
6. How is output checked or escaped for its destination?
7. What memory and execution limits apply?
8. Does the boundary justify serialization, copying, and adapter code?

If the answers are short and testable, the boundary is probably at a useful
level. If they reproduce the application's object model or require broad host
access, keep the operation in the host or choose a narrower component.
