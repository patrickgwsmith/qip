# AGENTS Notes

Project docs are written for coding agents as well as people. Read the relevant
page before changing a contract or workflow; do not repeat protocols here.

## Workflow

- Use the `Makefile`. Pass `-j` for builds and tests, but run benchmarks without
  competing CPU-heavy work.
- Source and compiled `.wasm` files are tracked together. Rebuild the artifact
  after changing its source.
- Use narrow test targets while iterating. Run `make -j test` after changing
  shared code, build or test wiring, or multiple components.
- Run `make -j site-static` after changing docs navigation, routes, links, or
  referenced modules. It checks for broken links and missing module imports.
- Use `agent-browser` for interactive browser checks, including page console
  output. Prefer it to launching a headless browser directly.

## Project References

- [QIP Component Contracts](docs/component-contract.md) is the contract index.
- Read [Hard Limits](docs/hard-limits.md) before changing memory, loop,
  division, import, or execution policy.
- Read [Formats and Encodings](docs/formats.md) before choosing MIME metadata or
  interchange formats.
- Use [IMAGE.md](IMAGE.md) for Tile filters. Register new filters in the
  `image.html` menu, template, and `FILTER_DEFS`.
- Use [Writing QIP Components In Zig](docs/zig-components.md) for Zig.
- Use [Building C Libraries As QIP Components](docs/c-wasm-toolchains.md) for
  C. Vendor source, license, version, archive checksum, and target configuration
  so developers do not need system libraries.
- Follow [Benchmarking Components](docs/benchmarking-components.md) for
  performance work.

## Docs and site style guide

Write for software engineers and technical decision-makers who are short on
time and skeptical of hype. Treat readers as capable of making tradeoffs. Be
engaging, informed, and friendly without becoming promotional or dry. State
opinions when explaining tradeoffs; state contract rules neutrally. Use
ASD-STE100 Simplified Technical English.

Choose tone and focus by the reader's task, not only by the sidebar group:

- Write QIP spec and other reference pages neutrally. Cover their stated scope
  completely and precisely enough that readers can quote a rule.
- Make start-to-finish tutorials warm and encouraging, with a predictable path
  to a working result. This includes relevant Making components and adoption
  guides.
- Make focused how-to pages terse and direct. Give steps and expected outcomes,
  including in relevant Making components and Running guides.
- Use concrete examples to explain mechanisms on conceptual pages, including
  general "why" and "how it works" pages. Use an analogy only when it makes a
  specific mechanism clearer.
- In optimization writeups, report the method, measurements, and limits of the
  result instead of presenting the work as a tutorial.
- Make browser tool pages task-first and brief. Use a short introduction that
  names the input and result, then put the working controls and output in view.
  Show essential limits and errors beside the relevant controls. Put longer
  explanations, downloads, CLI use, and implementation detail below the tool
  for readers who want to learn more. Do not make people read an explanation
  before they can use the tool.
- Keep component catalogs and tool indexes concise and neutral. Group entries
  by the work they do or the format they accept, and describe each link with a
  concrete input, output, or action.
- Make interactive demo pages inviting and brief. Tell visitors what to try and
  how to control it; add technical explanation only when it helps them
  understand the behavior they can see.
- Make landing and general overview pages welcoming and concrete. Show one
  working example or clear path into the site, and support broad claims with
  mechanics or evidence.

For every docs or site page:

- Lead with what the thing does and how it works, not a slogan.
- Prefer mechanics over claims: inputs, outputs, boundaries, commands, files,
  and failure modes.
- Explain tradeoffs directly. Say what QIP gives up as well as what it buys.
- Keep pages easy to scan. Use tight sections, short paragraphs, and bullets
  only when they save time.
- Use sentence case for headings on docs pages (`#` through `######`): capitalize
  the first word and proper names or acronyms. Navigation labels may use title
  case.
- Define a term when it first appears, before using it to explain another rule.
- Make headings describe the section's content so readers can scan the page.
- Use imperative verbs for procedure steps, such as "Run `make -j site-static`."
- Make link text name its destination, not "here" or "link". Explain each code
  block in the surrounding prose.
- Use practical examples from this repository: commands, module paths, recipes,
  ABI calls, and component pipelines.
- Use `claim -> reason -> example` when drafting, but do not expose those labels
  in reader-facing prose.
- Avoid sales language and fake confidence. Do not write "X matters" or "the
  important part is" without naming a precise consequence.
- Avoid absolute claims unless they describe a hard contract requirement.
- Include "when not to use this" guidance for adoption, architecture, and
  workflow pages.
- Keep normal application concerns normal. Explain when QIP belongs inside an
  existing app rather than replacing the application's architecture.
- Do not use an unnamed abstraction to make a conclusion sound authoritative.
  If prose says a result is wrong, a question is wrong, or something matters,
  name the criterion, the failure, and what the reader should do next. For
  example: "Compare speed only if the decoded images match pixel for pixel.
  Otherwise, you are making incorrect output faster." Avoid phrases such as
  "the wrong question", "what matters", or "the result" when the sentence does
  not identify them.

## Inspiration when writing components

- https://matklad.github.io/2026/09/02/static-allocation-constant-work.html
- https://easylang.online/blog/branchless
