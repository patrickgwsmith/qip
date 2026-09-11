# Recipes

This document defines how recipe QIP components are discovered from disk.

## Root

- Recipe root directory is discovered from the site root as `_recipes` by default.
- `--recipes <dir>` overrides discovery for shared or unusual layouts.
- Recipes are grouped by exact MIME type:
  - `_recipes/text/markdown/`
  - `_recipes/text/html/`
  - `_recipes/text/javascript/`
  - `_recipes/image/png/`
  - `_recipes/application/warc/`

Given MIME `type/subtype`, recipe directory is:

- `<recipe-root>/<type>/<subtype>/`

## WARC Recipes

`application/warc` recipes run at the whole-site layer instead of one page at a time. You can use them for site-wide transforms, such as adding trailing-slash redirects, verifying there are no broken links, or using the path to modify body content.

- Directory: `_recipes/application/warc/`
- Typical use:
  - link integrity checks on the full routed archive
  - JavaScript module import checks across rendered HTML
  - archive rewrites before export (for example tar/static packaging pipelines)
- Example filenames:
  - `10-warc-check-broken-links.wasm`
  - `20-warc-check-broken-module-imports.wasm`
  - `30-add-sitemap-xml.wasm`
  - `40-warc-add-open-graph-image-meta.wasm`

### Debugging broken links

`warc-check-broken-links.wasm` traps when an internal HTML link does not
resolve. For links to HTML pages, it also checks that a URL fragment matches an
`id` attribute or an `<a name>` target. It decodes percent-encoded fragments
before matching them. Fragments on non-HTML resources are left to the client
that handles that format.

To inspect missing paths, run the same archive through
`warc-extract-broken-links.wasm`:

```sh
qip router warc ./site --view-source \
  | qip run application/warc/warc-extract-broken-links.wasm
```

The result is another `application/warc` archive. It keeps only response pages containing broken links and reduces each HTML body to the exact opening tags with broken `href`, `src`, `action`, `data`, or `srcset` values. An archive with no broken links contains only a `warcinfo` record; WARC 1.1 does not define a zero-record archive.

### Rendering referenced content sizes

`recipes/application/warc/25-add-content-size.wasm` fills
`<qip-content-size>` elements from the response body stored at an absolute
site path:

```html
<qip-content-size src="/example.wasm"></qip-content-size>
```

Bodies below 1,000 bytes render as bytes. Larger bodies render as decimal
kilobytes with two fractional digits. The recipe updates the enclosing HTTP
and WARC content lengths. During single-route development, the router adds
direct static `src` dependencies to the subset WARC. An unresolved size path
is an error instead of producing a plausible size.

The rewrite preserves the input record's `WARC-Date`, `WARC-Record-ID`,
`WARC-Target-URI`, content type, and extension fields, then emits the record as
WARC 1.1. Because the HTML and HTTP block changed, it removes stale
`WARC-Block-Digest` and `WARC-Payload-Digest` fields. It also removes HTTP
`ETag`, `Content-MD5`, and `Digest` validators rather than claiming they still
describe the rewritten body. Records with no content-size replacement keep
their metadata and payload.

### Writing WARC transforms

An `application/warc -> application/warc` recipe receives standards-valid WARC
1.1 and must return standards-valid WARC 1.1. In particular:

- preserve `WARC-Type`, `WARC-Date`, `WARC-Record-ID`, and all extension fields;
- preserve unknown fields rather than rebuilding a short allowlist;
- recalculate the WARC and HTTP `Content-Length` values after a rewrite;
- remove or regenerate block and payload digests when their bytes change; and
- remove or regenerate HTTP entity validators when the HTTP body changes.

The router validates the final archive after the full recipe chain. This keeps
the trust boundary at export: malformed output traps or fails the command
instead of being written to disk.

### Turning URI lists into redirects

`application/warc/warc-text-uri-list-to-redirect.wasm` rewrites
each `text/uri-list` HTTP response in a WARC into `302 Found`. The first
non-empty, non-comment line becomes the `Location` header; a UTF-8 BOM on the
first line and surrounding whitespace are ignored. A URI list without a target
traps.

The standard recipe list runs this component before the other WARC transforms.
The router itself does not parse URI lists: it builds an ordinary WARC response
and runs the configured recipe chain. Other HTTP hosts can use the same
component without reproducing redirect behavior in host code.

### Loading custom elements selectively

`application/warc/warc-add-custom-element-scripts.wasm` connects element routes to the pages that use them. It discovers top-level `/elements/<tag-name>.js` responses in the archive, detects matching custom-element tags in each HTML response, and inserts one external module script per used element:

```html
<script type="module" src="/elements/qip-edit.js"></script>
```

The recipe ignores tag-shaped text in comments, `script`, `style`, `textarea`, and `title` content. Existing scripts are not inserted again. Nested routes such as `/elements/lib/shared.js` remain available to imports but are not treated as entrypoints.

Run this recipe late in the WARC chain so it sees elements introduced by earlier transforms. This repository links it as `99-add-custom-element-scripts.wasm`. During single-route development, the router includes transformed top-level element modules in the subset WARC so discovery has the same inputs as a whole-site export.

## Execution Context

WARC recipes can run in two useful scopes. Pick the scope based on the question you are answering.

- Subset/path scope (faster iteration):
  - `qip router dev` applies WARC recipe behavior on the currently resolved response.
  - `qip router get` / `qip router head` let you inspect one routed path.
- Whole-site scope (final archive behavior):
  - `qip router warc <site> ...` enumerates the full routed site, builds one WARC, then applies `_recipes/application/warc/*`.

Use subset scope while developing recipe logic. Use whole-site scope before publishing so final archive semantics are still exercised.

```sh
# Fast single-path iteration:
qip router get ./site /docs/router

# Final whole-site run:
qip router warc ./site
```

## Content Recipe CSV

Content Recipe CSV is the canonical machine-readable description of an
ordered Content component pipeline. It uses the ordinary `text/csv` media
type. Each row records the component path and the effective contract on both
sides of that step:

```csv
path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes
/text/markdown/commonmark.0.31.2.wasm,utf8,text/markdown,2097152,utf8,text/html,2097152
/text/html/html-to-accessibility-tree.wasm,utf8,text/html,262144,utf8,text/markdown,1048576
```

Rows execute in file order. The first data row is step 1; a separate step
column would duplicate the record order and create another value that could
disagree with it. A recipe contains at least one data row.

The canonical serialization is UTF-8 without a byte-order mark, uses LF line
endings, and ends with one LF. Fields cannot contain CR or LF. A field is
quoted only when it contains a comma or double quote, and a double quote in a
quoted field is written twice. The header and column order are exact.

The columns have these meanings:

- `path` is the component reference passed to the generated or executing host.
- `input_encoding` and `output_encoding` are exactly `utf8` or `bytes`. They
  select the corresponding `*_utf8_cap` or `*_bytes_cap` ABI exports.
- `input_mime` and `output_mime` are canonical lowercase MIME types. They are
  the effective types at that step after generic-component inheritance has
  been planned.
- `input_capacity_bytes` and `output_capacity_bytes` are unsigned decimal
  `u32` byte counts without grouping separators or leading zeroes.

Adjacent rows follow the normal Content composition rules: output and input
MIME types match exactly, equal encodings connect, and UTF-8 output may widen
to a bytes input. A bytes output cannot narrow implicitly to UTF-8.

Capacity metadata does not make a recipe invalid when one output maximum is
larger than the next input maximum. The actual intermediate value may fit.
Tools may report that comparison as a warning or enforce it with semantics
equivalent to `--capacities-must-fit`. At execution time, the loaded Wasm
module's capacity exports remain authoritative if an artifact at a recorded
path has changed.

The component finder catalog uses the same header and row schema. It is a
curated graph of format converters, not an inventory of every Content
component. Generic transforms, same-type transforms, and infrastructure such
as Content Recipe CSV source generators stay out of the finder by remaining
absent from that catalog.

## Planning And Dry Runs

`qip dry run` resolves and validates the same ordered component pipeline as
`qip run`, but does not read input, call `render`, or write output:

```sh
qip dry run \
  text/markdown/commonmark.0.31.2.wasm \
  text/html/html-page-wrap.wasm
```

The report is intended to be useful in CI logs without another formatting
step:

```text
Pipeline compatible: 2 step(s)
1. text/markdown/commonmark.0.31.2.wasm — Content
   Input:  encoding=UTF-8, type=text/markdown, capacity=2.0 MiB (2097152 bytes)
   Output: encoding=UTF-8, type=text/html, capacity=2.0 MiB (2097152 bytes)
   Buffers: 4.0 MiB (4194304 bytes)
2. text/html/html-page-wrap.wasm — Content
   Input:  encoding=UTF-8, type=text/html, capacity=256.0 KiB (262144 bytes)
   Output: encoding=UTF-8, type=text/html, capacity=512.0 KiB (524288 bytes)
   Buffers: 768.0 KiB (786432 bytes)
   Note: step 2 (text/html/html-page-wrap.wasm): previous output capacity 2.0 MiB (2097152 bytes) exceeds this input capacity 256.0 KiB (262144 bytes); qip run remains valid when the actual intermediate output fits
Total declared buffer capacity: 4.8 MiB (4980736 bytes)
Warnings: 1
```

A compatible plan exits successfully. Invalid component contracts, uniforms,
encoding or MIME composition, and module-policy violations return a non-zero
exit status.

## Runtime Failures

When a recipe step fails, the host reports its one-based position and component
path before the component error:

```text
step 2 (bytes/zlib-decompress.wasm): rejected input
```

The same format applies to `qip run` pipelines and router recipe chains. This
lets a log identify the failing component even when a recipe uses the same
component more than once.

A component can reject expected input without trapping. Its `render` result
sets the failure bit. The CLI does not read output from a rejected result. If
the component supplies an input offset, the message is more specific:

```text
step 3 (text/utf8-must-be-valid.wasm): rejected input at input offset 17
```

The input offset is diagnostic data. Recipe logic must not treat it as a stable
error code. Every rejected result stops the recipe, and no output from that
step is used.

A trap is different. The CLI reports `render trapped` and discards the Wasm
instance because its memory may contain partial output or state. Capacity,
content-type, and uniform failures use the same `step N (component)` prefix.

Use `--capacities-must-fit` to turn capacity warnings into errors:

```sh
qip dry run --capacities-must-fit \
  text/markdown/commonmark.0.31.2.wasm \
  text/html/html-page-wrap.wasm
```

The check requires each Content component's declared maximum output capacity
to fit the next Content component's input capacity. This is useful in CI and
when refining component contracts: without the flag, the pipeline remains
valid when its actual intermediate values fit. Tile capacities are per-tile
working buffers rather than whole-image Content capacities, so the Tile
contract validates those separately.

The host first extracts a plain description for each recipe step: component
kind, input and output encoding, optional MIME types, declared buffer
capacities, and Tile halo or Interactive frame dimensions. A pure planner then
validates those values and returns the ordered plan used by both commands. The
dry-run output prints every step and the sum of its declared input/output
buffer capacities. An in-place Tile buffer appears as both input and output but
is counted once.

Composition is directional and based only on the ordered step descriptions.
The planner does not inspect example input bytes or use browser/runtime
heuristics, so the same component artifacts and uniforms produce the same plan
or the same error.

The host validates arbitrary bytes once when they enter the UTF-8 domain. It
then carries the UTF-8 guarantee through `output_utf8_cap` and
`input_utf8_cap` stages without rescanning every intermediate value. Encoding a
native string as UTF-8 also establishes the guarantee. If a bytes-producing
stage breaks the chain, a later UTF-8 stage requires explicit host validation
or a bytes-to-UTF-8 validator.

The planner applies these rules:

- UTF-8 may flow into a raw-bytes input. This is safe widening: UTF-8 is already
  bytes, and browser hosts encode the string before calling a bytes component.
  Raw bytes never flow implicitly into a UTF-8 input.
- A step with a declared input MIME type requires the current type to match
  exactly. An unspecified current type does not satisfy a declared type.
- A step with no input MIME type is generic and accepts the current type when
  the encoding matches.
- A declared output MIME type replaces the current type. Generic same-encoding
  transforms preserve it. Raw bytes converted to UTF-8 produce an unspecified
  MIME type.
- Direct `qip run` input has no MIME channel, so the first step's declared input
  type expresses the user's intent. This exception applies only at the pipeline
  boundary, not between steps.
- A Tile group is an explicit image bridge: it accepts `image/bmp` raw bytes,
  processes RGBA32Float tiles internally, and returns `image/bmp` raw bytes.

There is no generic bytes-to-pixels rule. Image tiling is available only
through that explicit bridge, which keeps text, opaque binary data, and pixel
buffers from being guessed into one another.

The encoding relationship is small:

```text
Content encodings

raw bytes
└── valid UTF-8

Allowed widening:  UTF-8 ──> raw bytes
Rejected narrowing: raw bytes -X-> UTF-8

Explicit Tile bridge (not subtyping)

image/bmp raw bytes
        │ host decodes
        v
RGBA32Float tiles (width × height × 4 channels, in-place)
        │ host encodes
        v
image/bmp raw bytes
```

RGBA32Float pixels are physically held in linear memory, but they are not an
opaque Content `bytes` value. Their dimensions, channels, coordinates, tile
size, and halo are part of the Tile contract. Only the host's explicit image
bridge may cross that boundary.

For example, this plan decodes SVG Content to BMP, applies an in-place Tile
filter, then passes BMP Content to the ICO encoder:

```sh
qip dry run \
  image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm \
  components/rgba/brightness.wasm -u brightness=0.1 \
  image/bmp/bmp-to-ico.wasm
```

The middle step reports `RGBA32Float tile` for its input and output encoding;
the adjacent Content steps report `image/bmp` raw bytes at the bridge.

Capacity maxima do not make two steps incompatible by themselves: an upstream
component may declare a larger output buffer while producing an actual value
that fits the next input buffer. Dry run reports this as a warning because only
execution can determine the intermediate byte count.

## Host And URLs

`qip router warc` controls canonical route host via `--host <host>`. We prefer setting this explicitly for production builds so recipe logic that reads target URLs sees stable, deploy-intended origins.

Example:

```sh
qip router warc ./site --host https://qip.dev
```

## Adding Routes

WARC recipes can synthesize or rewrite archive records, which means they can add output routes (for example `/sitemap.xml`) when they emit additional WARC records.

- In this repo, route assets like `/favicon.ico` and `/robots.txt` are present in the content/static output.
- `recipes/application/warc/30-add-sitemap-xml.wasm` preserves the input archive
  and adds `/sitemap.xml` from its successful HTML responses. Set `--host`
  explicitly when building so the generated locations use the production
  origin.
- `application/warc/warc-to-sitemap.wasm` is the terminal
  `application/warc` to `application/xml` form when a standalone sitemap body,
  rather than an added route, is wanted.
- `recipes/application/warc/35-add-search-index.wasm` runs after page recipes
  have added stable `h2` fragment IDs. It appends a flat CSV target table and
  first-character posting shards under `/search/v1/`.

The search target table relates sections without storing a document tree:

```csv
target,url,label
2-0,/docs/abc,ABC documentation
2-3,/docs/abc#portable,ABC documentation — Portable
```

The part before `-` identifies the page and the part after it identifies a
section. Search can therefore combine terms found in different sections of
the same page. It links to a fragment when one section matches the whole
query, or to the page when the matches are spread across sections.

Posting shards keep the indexed term first and sort by that field:

```csv
term,target,weight
component,2-3,4
portable,2-3,12
```

The mandatory header means every posting begins after a newline. A browser can
find a prefix with `"\n" + prefix`, scan the contiguous matching rows, and
avoid parsing unrelated rows. The build step folds page-title, heading, and
body importance into the integer weight; the browser only adds weights after
grouping targets by page.

## Ordering

- Recipe execution order is determined by a required two-digit prefix.
- Prefix range is `00` to `99`.
- Lower number runs first.

Filename format:

- `NN-name.wasm`
- `NN` is two ASCII digits.
- `name` is ASCII-only.

Disabled filename format:

- `-NN-name.wasm`
- Leading `-` means the recipe is disabled and must be ignored.
- Example: `-10-normalize.wasm`

Examples:

- `10-normalize.wasm`
- `20-markdown-render.wasm`
- `90-html-wrap.wasm`
- `-10-normalize.wasm` (disabled)

## Tie-Breaking

- Primary sort: numeric prefix ascending.
- Secondary sort: full filename lexicographic ascending.

## Validation

Host should reject recipe entries if:

- filename is non-ASCII
- filename does not match either `NN-name.wasm` or `-NN-name.wasm`

Host should ignore non-`.wasm` files in the recipes tree.

## Scope

- This contract only defines recipe discovery and order.
- Which MIME type applies to a content file is determined by routing/build logic.
- Nested `_recipes` directories are reserved for future path-scoped recipes and are not active in this version.
