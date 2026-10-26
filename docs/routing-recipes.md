# File Routing And Recipe Orchestration

QIP routes files from a content tree and applies recipe components based on the source MIME type.

Use this page as the operational summary. The normative route rules live in the [Router Specification](/docs/router-spec), and recipe discovery/order is defined in [Recipes](/docs/recipes).

## Content Discovery

The router walks the site root and builds routes from regular content files. It skips project directories that are not ordinary pages:

- `_recipes`
- `_components`
- `_elements`

Those directories hold QIP components, custom-element modules, and host configuration. A file such as `site/_recipes/text/markdown/10-render.wasm` is not registered as a public content route, so `/_recipes/text/markdown/10-render.wasm` returns `404`.

Relative content paths must be UTF-8, use `/` separators, and avoid `.` or `..` path segments. During local discovery, QIP tracks visited directories so symlink loops do not recurse forever.

## Pretty Routes And Source Routes

Document files get browser-friendly routes and extension-exact source routes.

| Source file | Pretty route | Source route | Behavior |
| --- | --- | --- | --- |
| `site/index.md` | `/` | `/index.md` | pretty route runs markdown recipes |
| `site/docs/index.md` | `/docs` | `/docs/index.md` | pretty route runs markdown recipes |
| `site/contact.html` | `/contact` | `/contact.html` | pretty route serves HTML |
| `site/images/logo.png` | none | `/images/logo.png` | served as image bytes |
| `site/start.uri` | `/start` | `/start.uri` | pretty route redirects |

Request the source route when you want the raw file bytes. Request the pretty route when you want the routed response after applicable recipes.

Route conflicts fail at load time. For example, `site/about.md` and `site/about.html` both want `/about`; QIP rejects that layout instead of choosing one at runtime.

## Recipe Execution

Recipes run by source MIME type. A Markdown page uses `_recipes/text/markdown/*.wasm`; an HTML page uses `_recipes/text/html/*.wasm`.

Recipe filenames must use a numeric prefix:

- `NN-name.wasm` for an active recipe
- `-NN-name.wasm` for a disabled recipe

QIP runs active recipes in ascending prefix order. Duplicate active prefixes in the same MIME directory are an error.

Example:

```txt
site/
  about.md
  _recipes/text/markdown/10-markdown-render.wasm
  _recipes/text/markdown/20-html-wrap.wasm
```

For `/about`, QIP reads `about.md`, runs `10-markdown-render.wasm`, then runs `20-html-wrap.wasm`. For `/about.md`, QIP serves the raw Markdown source route and does not run the markdown recipe chain.

## WARC Recipes

Ordinary content recipes only see the current response. Use `application/warc` recipes for whole-site work such as link checks, sitemap generation, redirects, or export rewrites.

During development, use single-path commands for faster feedback:

```sh
qip router get ./site /docs/router
qip router head ./site /docs/router
```

Before publishing, run the whole-site path:

```sh
qip router warc ./site
```

## Dev Reload

`qip router dev` reloads route and recipe state on browser hard reload, recipe file changes, or `SIGHUP`. If a reload fails, the previous valid state keeps serving.

This avoids background polling as the primary mental model: edit a file, reload the browser or send `SIGHUP`, and QIP rebuilds the relevant route state.

## Troubleshooting

- Recipe is not running:
  Check that the file is in `<recipe-root>/<type>/<subtype>/`, that the source file's MIME type matches that directory, and that the recipe filename starts with a two-digit prefix.
- You are seeing rendered HTML but wanted raw Markdown:
  Request the extension-exact source route, such as `/docs/router.md`.
- Duplicate prefix error:
  Two active recipe files in one MIME directory start with the same `NN`. Rename one or disable it with a leading `-`.
- Form component is missing:
  Check that `<qip-form>` has one direct `<source>` and that its `src` resolves to an `application/wasm` component route.

## When Not To Use This Model

Do not use a per-content recipe for work that needs whole-site context. Link checks, sitemap generation, and route synthesis belong in `application/warc` recipes because they operate over the routed archive.

Do not put nested recipe folders under `_recipes/<type>/<subtype>/` expecting path-scoped behavior. QIP currently reads only the immediate MIME directory; nested recipe roots are reserved for future routing rules.
