# qip-router

`qip-router` serves a QIP content directory with Node.js. It reads content,
recipes, component assets, and custom-element modules directly from the
filesystem, and runs QIP components with Node's WebAssembly runtime.

Documentation: <https://qip.dev/docs/router>

```sh
npx qip-router dev -C ./site
```

The package has no runtime dependencies. It requires Node.js 22 or newer.

## Commands

```sh
qip-router dev -C ./site
qip-router get -C ./site /docs/router
qip-router head -C ./site /docs/router
qip-router kindred -C ./site /docs/router
qip-router list -C ./site
qip-router warc -C ./site -o site.warc
```

`-C <dir>` or `--cwd <dir>` sets the content directory. Without it, the
current directory is the content root, so `cd site && qip-router get /` also
works. The content directory used to be a positional argument; passing one
now fails with the `-C` form to use instead.

Project directories are discovered below the content root:

```text
site/
  _recipes/
  _components/
  _elements/
  index.md
```

They can also be supplied separately:

```sh
qip-router dev -C ./site \
  --recipes ./recipes \
  --components ./components \
  --elements ./elements
```

Use `--include <path>` and `--exclude <path>` to route only part of the
content. Both flags can be repeated, and every command accepts them. The router
routes the files under any include path, or all files when there are none, and
removes the files under any exclude path:

```sh
qip-router warc -C ./site --exclude blog/drafts -o site.warc
qip-router dev -C ./site --include blog --include about.md
```

Either flag also skips dot paths such as `.env`, unless an include path names
them. Parent pages outside the filters still supply their layouts. Details are
in the [router specification](https://qip.dev/docs/router-spec#content-filters).

The development server listens on `127.0.0.1:4000` by default. Existing
content files are read for each request. A browser hard refresh reloads the
route table and recipe modules, so newly added files and changed recipes take
effect without restarting the process.

## JavaScript API

The executable is also an ES module:

```js
import { createQIPRouter } from "qip-router";

const router = await createQIPRouter({ contentRoot: "./site" });
const server = await router.listen({ port: 4000 });
```

`router.fetch(request)` returns a standard Fetch API `Response`, which lets QIP
Router mount inside Hono, Workers-style runtimes, and other Fetch-native hosts.
`router.get(path)` and `router.head(path)` resolve requests without opening a
network socket and return `{ status, headers, body }`. `router.head(path)` sets
HEAD headers such as `content-length`, but its `body` is an empty `Uint8Array`.
`router.kindred(path)` lists the parent pages and direct `src` or eligible
`<link href>` dependencies supplied as Kindred Route context for one path.
`router.resolve(method, path)` is available when the method is
dynamic. The `include` and `exclude` options take arrays of paths and work like
the command-line flags.
`router.warc()` returns the transformed full-site WARC as a `Uint8Array`.
`router.warc({ checkKindred: true })`, or `qip-router warc --check-kindred` on
the command line, also reruns each page's WARC recipes with only its Kindred
Routes, as dev does, and rejects if any page's output differs. Pages are
checked in parallel on a pool of worker threads, one per CPU core. If one page's
WARC recipes run longer than 5 seconds (`kindredPageTimeoutMs`), the check stops
there and rejects, without checking the remaining pages.

```js
app.all("/docs/*", async (c) => {
  const url = new URL(c.req.url);
  url.pathname = url.pathname.slice("/docs".length) || "/";
  return router.fetch(new Request(url, c.req.raw));
});
```

## Current boundary

The Node router implements content recipes, raw Markdown routes, component
and element assets, Kindred Route WARC transforms, and lazy full-site-derived
routes. Its page and full-site WARC output are tested byte-for-byte against
the Go router.

Recipe execution is synchronous WebAssembly. A component that does not return
can therefore block the Node process. Use the Go router when execution
timeouts are required; a future Node isolation layer can use worker threads
without adding a package dependency.
