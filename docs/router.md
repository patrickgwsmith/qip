# Router Specification

QIP Router turns a content tree into deterministic HTTP responses. It reads a directory of Markdown, HTML, images, scripts, WebAssembly components, and recipe modules, then produces the same responses in local development, CLI rendering, and WARC export.

Use the dependency-free Node package for normal site work:

```sh
npx qip-router dev ./site
```

We prefer a small set of explicit routing rules because site authors, recipe authors, and export tooling should all be able to predict the same response for the same input files.

This document defines `qip-router`, including its development server, single-route rendering, route listing, and WARC export.

## Site Root

`npx qip-router dev` and the other `qip-router` subcommands take one local site directory.

A typical site root contains Markdown pages, static files, browser assets, and optional project directories:

```txt
site/
  index.md
  about.md
  docs/
    router.md
  images/
    logo.png
    open-graph-card.png
  data/
    component-catalog.csv
  robots.txt
  favicon.ico
  styles.css
  app.js
  _recipes/
    text/markdown/10-markdown-basic.wasm
    text/markdown/80-html-page-wrap.wasm
    application/warc/20-check-links.wasm
  _components/
    form/contact.wasm
    gui/side-scroller-platformer.wasm
  _elements/
    qip-edit.js
    qip-search.js
```

`index.md` becomes `/`. Markdown pages also get extensionless pretty routes, such as `about.md` becoming `/about`. Static assets keep their file paths, such as `/images/logo.png`, `/robots.txt`, and `/styles.css`.

This repository's site is a working reference: <https://github.com/royalicing/qip/tree/main/site>.

## Project Directories

The router reserves three exact top-level directory names:

- `_recipes`: content and archive recipe components
- `_components`: browser-loadable QIP components
- `_elements`: browser custom-element modules

Reserved project directories must not be routed as content. Other underscore paths, such as `_og/card.png`, are ordinary content unless a future spec reserves them.

The router auto-discovers these project directories under the site root:

| Role | Default directory | Override flag |
| --- | --- | --- |
| Recipes | `<site>/_recipes` | `--recipes <dir>` |
| Components | `<site>/_components` | `--components <dir>` |
| Elements | `<site>/_elements` | `--elements <dir>` |

The recipe and component flags override auto-discovery. Element modules always belong to the site because they define site-owned browser behavior. This keeps the common command short while allowing shared recipe and component directories:

```sh
npx qip-router dev ./site
npx qip-router dev ./site --recipes ../shared-recipes
```

Local project directories may be real directories or symlinks. Symlinks are the preferred way to share recipes across sites without introducing a config file. Remote object stores such as S3 do not have symlinks, so shared project directories must be copied or handled by future remote-root support.

Nested `_recipes`, `_components`, and `_elements` directories are reserved for future path-scoped behavior. The router must not use nested project directories in this version.

## Request Paths

Request paths must be canonicalized before route lookup.

- An empty path must become `/`.
- A path without a leading slash must be treated as if it had one.
- Dot segments must be cleaned with URL-path semantics.
- The router uses no trailing slash as the canonical form. `/docs/` must redirect to `/docs`.
- A canonicalization redirect must preserve the query string.

The router should not allow two different content files to claim the same request path. If route construction finds a duplicate path for different files, it must fail before serving.

## File Paths

Content files are discovered by walking the site root.

- Regular files must be routable.
- Directories must be walked recursively.
- Symlinks may point at regular files or directories.
- Symlink cycles must not recurse forever.
- Top-level router project directories must be skipped.
- Content paths must be valid UTF-8.
- Content paths must not start with `/`.
- Content paths must not contain backslashes.
- Content paths must already be clean relative paths; `.` and `..` forms must be rejected.

These rules keep file paths portable and make route generation reviewable.

## File To Route Mapping

Every content file must receive a source route:

```txt
site root:    site/
file:         docs/router.md
source route: /docs/router.md
```

Some file types also receive a pretty route:

| File extension | Pretty route rule |
| --- | --- |
| `.html` | remove the extension |
| `.md` | remove the extension |
| `.markdown` | remove the extension |
| `.uri` | remove the extension |
| `.uris` | remove the extension |

Example:

```txt
site/docs/router.md -> /docs/router.md and /docs/router
```

Other file types should not receive a pretty route. They are served only at their source route.

## Parent Pages

An `index` file defines the page for its parent path. This is how the router represents directory-level pages without inventing a separate directory object.

Examples:

```txt
site/index.md          -> /index.md and /
site/docs/index.md     -> /docs/index.md and /docs
site/docs/reference.md -> /docs/reference.md and /docs/reference
```

The canonical parent path must not end in `/` under the current trailing-slash policy. A request for `/docs/` must redirect to `/docs`.

Parent pages also matter for WARC-level context. When an application-WARC recipe transforms `/docs/reference`, the router may provide context records for `/` and `/docs` if those paths resolve to HTML pages. Recipe authors should treat those records as context, not as the target response.

## Source MIME

The router determines source MIME from the file extension.

- `.md` and `.markdown` must be `text/markdown`.
- `.uri` and `.uris` must be `text/uri-list`.
- Other extensions should use the platform MIME table.
- Unknown extensions must fall back to `application/octet-stream`.
- MIME parameters from platform lookup should be stripped for route matching.

The source MIME selects content recipes. The response MIME may differ after transformation.

## Redirect Files

Files with source MIME `text/uri-list` are redirects.

The router must read the first non-empty, non-comment line as the redirect target.

- A leading UTF-8 byte-order mark on the first line must be ignored.
- Blank lines must be ignored.
- Lines starting with `#` must be ignored.
- The first remaining line must become the `Location` header.
- The response status must be `302 Found`.
- Content recipes must not run for redirect files.

Example:

```txt
# site/start.uri
/docs/how-it-works
```

This creates `/start.uri` and `/start`; both resolve to a redirect with `Location: /docs/how-it-works`.

## Content Recipes

Content recipes transform individual content responses. They are discovered under:

```txt
site/_recipes/<type>/<subtype>/*.wasm
```

For example, `site/_recipes/text/markdown/*.wasm` applies to content whose source MIME is `text/markdown`. If `--recipes <dir>` is provided, the router must use `<dir>/<type>/<subtype>/*.wasm` instead.

Recipe files must have a numeric order prefix, such as `11-autolink-https.wasm`. The router must order recipe steps by numeric prefix, then by filename. Duplicate numeric prefixes within one MIME recipe chain must fail route loading. A leading `-` disables a recipe file.

Content recipe selection must be based on source MIME, not on the request path extension or output MIME.

Markdown has one special rule:

- Markdown pretty routes such as `/docs/router` should run `text/markdown` recipes.
- Markdown source routes such as `/docs/router.md` must not run `text/markdown` recipes.

This preserves a raw source URL while still giving authors a clean page URL.

For other MIME types, if a recipe chain exists for the source MIME, the chain should run for the routed content response.

When a recipe chain runs for `text/markdown`, the router treats the response as `text/html; charset=utf-8`. Recipe modules should still declare their output content type when a different result is intended.

Nested recipe roots are not active in this version. A file at `site/docs/_recipes/text/markdown/40-docs-sidebar.wasm` must not affect `/docs/router`. If path-scoped recipes are added later, they should merge by numeric prefix and should keep duplicate-prefix failures.

## Form Elements

`<qip-form>` is an ordinary site-owned custom element. It declares its Wasm dependency with exactly one direct `<source>`:

```html
<qip-form>
  <source src="/form/contact.wasm" type="application/wasm">
</qip-form>
```

The element module at `/elements/qip-form.js` fetches and instantiates that component. The Router does not interpret the form markup, embed module bytes, or maintain a separate form namespace. Missing sources and incompatible modules fail in the element at activation time.

## Component Assets

`.wasm` files under `site/_components`, or under `--components <dir>` when provided, must be served as browser-loadable QIP component assets at:

```txt
/<relative-path>.wasm
```

Component asset paths must be valid UTF-8, clean relative paths, and must not start with `/`. Non-`.wasm` files in the component root should be ignored.

Direct paths let a qipx host map `text/markdown/render.wasm` to `https://example.com/text/markdown/render.wasm` without a site-specific prefix.

Component assets must use `application/wasm`. They are not content pages and should not run content recipes.

## Element Modules

JavaScript files under `site/_elements` are served at matching paths under `/elements`:

```txt
site/_elements/qip-edit.js   -> /elements/qip-edit.js
site/_elements/lib/dom.js   -> /elements/lib/dom.js
```

Each file runs the site's `text/javascript` recipe chain before it is served or archived. This is where a site can minify, check, or otherwise transform its custom-element code.

A top-level filename containing a hyphen is an element entrypoint: `copy-code.js` corresponds to `<copy-code>`. Nested files remain importable dependencies but do not imply custom-element names. The router only provides the routes; selective script insertion is performed by an application-WARC recipe such as `warc-add-custom-element-scripts.wasm`.

## Application WARC Recipes

`site/_recipes/application/warc/*.wasm` is the archive-level recipe layer. It works on WARC records, not raw page bodies. If `--recipes <dir>` is provided, the router must use `<dir>/application/warc/*.wasm` instead.

In `npx qip-router warc`, the router must:

1. Enumerate routed content, component asset, and element module paths.
2. Resolve each path to an HTTP response.
3. Build a WARC 1.1 response record for each response.
4. Run the `application/warc` recipe chain over the whole archive, if one exists.
5. Validate the transformed archive and emit it only when every record remains
   structurally valid.

Every emitted record includes `WARC-Type`, `WARC-Date`, `WARC-Record-ID`, and
`Content-Length`. Response blocks contain a complete HTTP response with its own
recalculated `Content-Length`. The exporter uses the fixed capture time
`2000-01-01T00:00:00Z` and derives record UUIDs from the target URI and response
bytes. Given the same routes and content, the archive bytes are reproducible.

The validator runs after the WARC recipe chain, not just before it. A recipe
that drops a mandatory field, emits WARC 1.0, misstates a block length, or
returns an incomplete HTTP response makes the router fail instead of writing a
plausible but invalid archive.

In `npx qip-router dev`, `npx qip-router get`, and `npx qip-router head`, the router should apply the same WARC recipe layer to the single requested response so local preview matches archive export.

### Kindred Routes

For a single-response WARC transformation, the router adds the target's kindred routes before its record. These are its parent pages and direct sibling resources discovered in the target HTML:

- `/`
- each parent page path of the target, such as `/docs` for `/docs/router`
- static assets referenced by any `src` attribute in the target HTML
- static assets referenced by `<link href>` when `rel` contains `stylesheet`, `manifest`, `preload`, `modulepreload`, or `prefetch`
- transformed top-level element entrypoints, so WARC recipes can selectively load them

Parent pages must be `200 OK` HTML. They let WARC recipes copy navigation and other shared structure into descendant pages, serving a role similar to layouts in other routers.

The shallow dependency scan ignores comments and raw text such as script bodies. HTML tag names, attribute names, and `rel` tokens must be lowercase. It includes site-relative, non-HTML files served directly from the filesystem without a content recipe; component WASM files qualify. HTML, redirects, missing or external targets, synthetic routes, and recipe-transformed content are ignored. Paths are deduplicated after dropping queries and fragments, referenced assets are not scanned recursively, and a page may contribute at most 256 unique paths.

These rules give WARC recipes access to direct static dependencies without turning a single-route request into a whole-site build.

The target response must be selected from the transformed WARC by exact target URI.

## Route Listing

`npx qip-router list` must list all routable content, component asset, and element module paths known before WARC recipe synthesis.

Each listed route must include:

- method: `GET` and `HEAD`
- request path
- media type without parameters

`npx qip-router list` should not list routes synthesized only by an `application/warc` recipe, because those routes are created after the content router has already enumerated the base site.

## Commands

Run the zero-dependency Node package without installing it globally:

```sh
npx qip-router dev ./site
npx qip-router get ./site /docs/router
npx qip-router head ./site /docs/router
npx qip-router kindred ./site /docs/router
npx qip-router list ./site
npx qip-router warc ./site -o site.warc
```

`npx qip-router dev <content_dir> ...` must serve the same route resolution pipeline used by the other subcommands. Existing files are read for each request. A browser hard reload refreshes the route table and recipe modules, so newly added files and changed recipes take effect without restarting the process.

`get <content_dir> <path> ...` must resolve one path through the dev-route pipeline and write the response body.

`head <content_dir> <path> ...` must resolve one path through the dev-route pipeline and write headers/log output without a response body.

`kindred <content_dir> <path> ...` must list the GET request paths that the router supplies as Kindred Route context before the target response. For `/docs/router`, this includes parent pages such as `/` and `/docs` when they resolve to HTML. HTML targets can also contribute direct site-relative non-HTML `src` and eligible `<link href>` dependencies.

`list <content_dir> ...` must print the base route table.

`warc <content_dir> ...` must emit a WARC archive. Use `-o <path>` or `--output <path>` to write it to a file; without that option, the command writes the archive to stdout.

The archive conforms to [WARC 1.1](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/).
This command is intended for deterministic application builds rather than
forensic capture: its fixed `WARC-Date` records the build convention, not a
network retrieval time.

The project directory flags are overrides, not requirements:

```sh
npx qip-router dev ./site
npx qip-router get ./site /docs/router
npx qip-router warc ./site -o site.warc
npx qip-router warc ./site --recipes ../shared-recipes --components ../shared-components --elements ../shared-elements -o site.warc
```

## When Not To Use The Router

Do not use the router for ad hoc byte processing. Use [`qipx run`](/docs/qipx) when you have a direct input-to-output Content component pipeline and no request paths.

Do not use content recipes for site-wide checks such as broken-link validation. Use `application/warc` recipes because they can see the routed archive as a whole.
