# qipok

`qipok` checks that QIP Content components are ok: that they follow the QIP
Content ABI and the Strict Wasm Profile, and that they pass any Compliance
suites you give it. It is `qipx comply` without the subcommand. It requires
Node.js 22 or newer.

```sh
npx qipok text/hello.wasm
npx qipok text/ --max-memory 16777216
npx qipok text/luhn.wasm --suite compliance/luhn.comply.wasm
npx qipok qip.dev text/cve.wasm --suite compliance/cve.comply.wasm
```

Each check prints `PASS` or `FAIL`, then a summary such as
`pass=2 fail=0 total=2`. `qipok` exits 1 if any check fails.

## Options

| Option | Meaning |
| --- | --- |
| `--suite <suite.wasm>` | Also run a Compliance suite on each component (repeatable) |
| `--seed <n>` | Seed suites that export `uniform_set_seed` (u32) |
| `--max-memory <bytes>` | Reject components whose declared memory exceeds bytes |
| `-h, --help` | Show help |
| `--version` | Show the qipok version |

Directories are searched for `.wasm` files, without following symlinks.

## Suites and seeds

A suite is a `.wasm` Compliance oracle that calls host functions such as
`must_render_exactly` and `must_reject` for each case. A fuzzer is a suite
that generates its cases from a seed: it exports `uniform_set_seed`.

Without `--seed`, each suite that exports `uniform_set_seed` gets a random
u32 seed, and the summary reports it, as in `pass=2 fail=0 total=2 seed=1634851179`.
Pass that value to `--seed` to repeat the run. `--seed` fails a suite that
doesn't export the setter.

## Hosts

Dotted DNS names such as `qip.dev` before the first file or directory are
hosts, unless a file or directory with that name exists locally. Options may
come before or after them. The last positional argument is always a file or
directory.

A relative `.wasm` component or suite is read locally if it exists; a missing
one is downloaded from the hosts in order over HTTPS and saved, as `qipx` does.

`qipok` is its own implementation with no dependencies. It shares a test suite
with `qipx comply` and the Rust `qipx`, so all three behave the same.

Documentation: https://qip.dev/docs/comply
