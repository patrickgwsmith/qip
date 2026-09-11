# Mermaid to Unicode HTML

`mermaid-to-unicode-html.wasm` converts a strict Mermaid subset into the
span-styled Unicode box art used by Simon Willison's grok-mermaid tool.

The Content component accepts `text/vnd.mermaid` and returns a `text/html`
fragment. The fragment contains styled `<span>` runs and newline-separated
rows; the host supplies the surrounding `<pre>`.

## Supported subset

- simple top-to-bottom and left-to-right flow edges, plus rooted top-to-bottom
  flow trees with no more than 16 nodes, 32 edges, and two forward children per
  node; solid feedback edges declared after the forward tree can return to
  ancestor nodes; extra dashes in solid arrows such as `--->` and `---->` are
  accepted but do not increase the rank distance; ranks, feedback lanes, and
  HTML spans match Simon's renderer for supported tree shapes
- two left-to-right subgraphs, each containing one edge, joined by one labelled
  edge; node labels wrap at 24 columns for up to four lines
- sequence diagrams with `participant`/`actor` declarations, aliases,
  activation markers, adjacent calls, and adjacent dashed replies
- the start → state → fork → retry/end state-machine form, with an optional
  second back-edge to the state before the fork; and the three-state linear
  cycle used in Mermaid's `Still` → `Moving` → `Crash` example
- one class with direct subclasses, fields, and methods
- linear ER chains with attributes, relationship labels, and `1`, `0..*`,
  and `1..*` cardinalities

Blank and whitespace-only input produces empty output. The parser traps on
invalid UTF-8, unsupported diagram families, malformed statements, and graph
shapes outside this initial subset. Like Simon's parser, a graph statement with
a valid node and dangling trailing arrow renders the partial graph. It does not
otherwise fall back to a framed source listing.

The Unicode canvas is 512 columns by 512 rows. A graph that satisfies the node
and edge limits can still trap when its labels and feedback lanes exceed that
canvas.

Mermaid.js-only `classDef`, `class`, `style`, `linkStyle`, and `click`
directives are ignored where applicable: they do not change terminal box art.

## Compatibility

`compliance/mermaid-to-unicode-html.fixtures.txt` contains 38 canonical
byte-for-byte HTML fixtures derived independently from the published reference
renderer. The strict comply component adds one embedded trailing-space fixture,
17 layout-equivalent syntax variations, and six rejection cases, for 62 cases
in total.

To run the same cases against this module and Simon's reference WASM:

```sh
node tools/mermaid-duel.mjs /path/to/grok-mermaid.wasm
```

The duel treats a QIP trap and Simon's framed `mermaid: ...` fallback as
equivalent rejection outcomes. Successful renders must still match byte for
byte.

The renderer deliberately preserves several visible reference quirks:

- flowchart decision nodes use rounded boxes rather than diamond outlines
- state start and end markers are both rendered as `●`
- class siblings are vertically centre-aligned
- cross-subgraph arrows attach to the group frames
- sequence message text uses the node-text span role, not the edge-label role

There is no max-width uniform. Width limiting in the reference swaps the
diagram for a framed source listing rather than laying it out differently.
