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

## Docs Style Guide

Write for software engineers and technical decision-makers who are short on
time and skeptical of hype. Treat readers as capable of making tradeoffs. Be
engaging, informed, opinionated, and friendly without becoming promotional or
dry. Use ASD-STE100 Simplified Technical English.

- Lead with what the thing does and how it works, not a slogan.
- Prefer mechanics over claims: inputs, outputs, boundaries, commands, files,
  and failure modes.
- Explain tradeoffs directly. Say what QIP gives up as well as what it buys.
- Keep pages easy to scan. Use tight sections, short paragraphs, and bullets
  only when they save time.
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
