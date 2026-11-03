# qipdo

`qipdo` runs a chain of QIP Content components on input: each component's
output becomes the next one's input. It is `qipx run` without the subcommand.
It requires Node.js 22 or newer.

```sh
echo '<b>hi</b>' | npx qipdo qip.dev text/html/html-escape.wasm
npx qipdo qip.dev -i page.md text/markdown/markdown-basic.wasm -o page.html
npx qipdo --dry-run qip.dev text/markdown/markdown-basic.wasm
```

## Options

| Option | Meaning |
| --- | --- |
| `-i, --input <path>` | Read input from a file instead of stdin |
| `-F, --form <name=value>` | Add a form field, or a typed related part with `-i` (repeatable) |
| `-o, --output <path>` | Write output to a file instead of stdout |
| `-u, --uniform <name=value>` | Set a uniform on the preceding component (repeatable) |
| `--max-memory <bytes>` | Reject modules whose declared memory exceeds bytes |
| `--strict-capacities` | Fail when a step's output capacity exceeds the next step's input capacity |
| `--dry-run` | Check the chain without reading input or rendering |
| `-h, --help` | Show help |
| `--version` | Show the qipdo version |

## Hosts

Dotted DNS names such as `qip.dev` before the first component are hosts.
Options may come before or after them, so `qipdo --dry-run qip.dev a.wasm`
and `qipdo qip.dev --dry-run a.wasm` are the same. The last positional
argument is always a component.

A relative `.wasm` path is read locally if it exists; a missing one is
downloaded from the hosts in order over HTTPS and saved, as `qipx` does.
This applies to components and to `-F @path` and `-F '<path'` fields.

## Capacities

Every component has a fixed input and output capacity. By default a step may
declare a larger output capacity than the next step's input capacity:
`--dry-run` prints a note, and a run fails only when the real intermediate
output doesn't fit. `--strict-capacities` turns the mismatch into an error
before anything runs.

`qipdo` is its own implementation with no dependencies. It shares a test
suite with `qipx run` and the Rust `qipx`, so all three behave the same.

Documentation: https://qip.dev/docs/content-component
