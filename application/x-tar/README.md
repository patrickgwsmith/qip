# TAR to ZIP

`tar-to-zip.wasm` converts one `application/x-tar` archive into an
`application/zip` archive. Each regular file and symbolic link uses raw
DEFLATE when that makes its payload smaller; otherwise it uses ZIP's stored
method. Directories are stored as empty entries.

```sh
qip run \
  -i site.tar \
  -o site.zip \
  application/x-tar/tar-to-zip.wasm
```

The converter accepts POSIX ustar archives, PAX `path`, `linkpath`, `size`, and
`mtime` records, and GNU long-name and long-link records. It preserves entry
order, Unix permissions, symbolic links, and modification times representable
by ZIP's 32-bit extended timestamp.

The component deliberately emits classic ZIP rather than ZIP64. Inputs are
limited to 128 MiB, outputs to 160 MiB, and archives to 65,535 entries. Entries
are compressed in independent 512 KiB batches, so the token scratch buffer is
bounded at 2 MiB regardless of entry size. A small match sample sends
incompressible batches directly to stored DEFLATE blocks; compressible batches
choose fixed or dynamic Huffman codes from their exact bit costs. The complete
entry falls back to ZIP's stored method when the resulting DEFLATE stream is
not smaller.

The 512 KiB batch size and 32-candidate match-chain limit are constants in
`tar-to-zip.zig`; they can be retuned without changing the component protocol.
Resetting match history at each batch boundary gives up some cross-boundary
matches in exchange for bounded scratch memory and predictable work. The
component traps on malformed TAR data, unsupported entry types, unsafe
extraction paths, capacity overflow, and classic-ZIP limit violations.

Use this component when ZIP compatibility at a system boundary is useful.
Keep TAR between components when sequential parsing or richer Unix archive
semantics are more important.

## Recipe books

A recipe book packages a fixed `_recipes` directory for a deployment target
without adding a manifest. Create the input with the platform TAR command:

```sh
COPYFILE_DISABLE=1 /usr/bin/tar -chf recipes.tar _recipes
```

`recipes-tar-to-csv.wasm` produces a deterministic view of the active
pipelines:

```sh
qip run \
  -i recipes.tar \
  -o pipeline.csv \
  application/x-tar/recipes-tar-to-csv.wasm
```

The CSV columns are `source_mime`, `step`, `module`, `bytes`, and `sha256`.
It is useful for inspection and cache keys, but it is not part of deployment
artifacts.

`recipes-tar-to-node-tar.wasm` produces a dependency-free Node recipe book:

```sh
qip run \
  -i recipes.tar \
  -o recipe-book-node.tar \
  application/x-tar/recipes-tar-to-node-tar.wasm
mkdir recipe-book-node
/usr/bin/tar -xf recipe-book-node.tar -C recipe-book-node
```

The output contains only `recipe-book.mjs` and numbered `modules/*.wasm`
files. It needs neither a `package.json` nor the diagnostic CSV. Load it from
an ES module:

```js
import { createRecipeBook } from "./recipe-book-node/recipe-book.mjs";

const recipes = await createRecipeBook();
const result = await recipes.render("text/markdown", "# Hello");
// result.bytes is a Uint8Array; result.contentType is "text/html".
```

The transform accepts active modules at
`_recipes/<type>/<subtype>/NN-name.wasm`, ignores other regular files and
disabled `-NN-name.wasm` modules, and rejects duplicate step numbers. It also
rejects malformed or unsafe TAR paths, special TAR entries, Wasm imports, and
modules without the structural QIP render ABI. The Node loader compiles every
module and checks declared content-type connections once when the recipe book
is created. Calls sharing a source MIME chain are serialized because a QIP
module instance owns mutable input and output memory; different chains can run
concurrently.

Use this target when Node can read adjacent deployment files. A worker target
needs a separate transform because platforms such as Cloudflare Workers bind
Wasm modules at deployment rather than reading them from a filesystem.
