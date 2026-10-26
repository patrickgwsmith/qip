<title>QIP Router</title>
<meta name="description" content="QIP Router is a static site generator built on the file system: folders are routes, each content type runs a numbered WebAssembly recipe pipeline, and every page renders to WARC.">
<link rel="canonical" href="https://qip.dev/docs/router">
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"TechArticle","headline":"QIP Router","description":"A static site generator built on the file system: folders are routes, each content type runs a numbered WebAssembly recipe pipeline, and every page renders to WARC.","url":"https://qip.dev/docs/router","about":{"@type":"SoftwareApplication","name":"qip-router","applicationCategory":"DeveloperApplication","operatingSystem":"Node.js 22+","url":"https://www.npmjs.com/package/qip-router","offers":{"@type":"Offer","price":"0","priceCurrency":"USD"}}}
</script>

# QIP Router

Your folders are your routes, each content type runs a numbered Wasm recipe pipeline, and every page renders to WARC, which you can inspect with `qip-router`.

```sh
npx qip-router dev ./site
```

There is no config file, no plugin API, and no template language. QIP Router needs Node.js 22 or newer and has no dependencies.

## The four ideas

**Folders are routes.** `site/index.md` is `/`, `site/blog/hello.md` is `/blog/hello`, and `site/styles.css` is `/styles.css`. A `.uri` file containing one URL is a redirect.

**Recipes instead of plugins.** A recipe is a folder of numbered `.wasm` files named after a MIME type. Every Markdown page runs through `_recipes/text/markdown/` in number order, such as `10-gfm.wasm` and then `80-document-wrap.wasm`. You add a step by dropping in a file, reorder by renaming, and turn one off by prefixing it with `-`. Each step is a sandboxed QIP component with no access to the file system or network, so a step downloaded from someone else can only transform the bytes it is given.

**Layouts are markup.** A page shares its navigation and footer with every page below it by declaring a `<qip-main-layout>` with a `<slot>`. There is no separate templates folder, front matter, or partial syntax.

**WARC is the build output.** `qip-router warc` writes the whole site as one [WARC](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/) web archive. Whole-site steps, such as sitemaps, link checking, and Open Graph images, are recipes over that archive under `_recipes/application/warc/`. The dev server, `get`, and the export all run the same pipeline, so the page you preview is byte-for-byte the page you deploy.

## Coming from another static site generator

| You know | In QIP Router |
| --- | --- |
| `_config.yml`, `astro.config.mjs`, `eleventy.config.js` | No config. The site folder and its `_recipes`, `_components`, and `_elements` folders are the configuration. |
| Plugins and markdown-it/remark options | Numbered `.wasm` steps in `_recipes/text/markdown/` |
| Shiki, Prism, or highlight.js | One step per language, such as `21-html-code-syntax-highlight-zig.wasm`, plus a theme step such as `29-add-highlight-stylesheet-night-owl.wasm`. Code is highlighted at build time, so pages ship no highlighting JavaScript. |
| `npm update`, lockfiles, and plugins that break on a major version | Each step is one self-contained `.wasm` file with no dependencies. Its only contract is bytes in, bytes out, so a step you copied into your site keeps producing the same output until you replace the file. |
| Layouts, templates, partials | `<qip-main-layout>` in a parent page, filled by `<slot>` |
| Front matter `title` and `description` | The first `<h1>` becomes the `<title>`. `<meta>`, `<link>`, `<title>`, and JSON-LD tags at the top of a page move into `<head>`. |
| Permalinks | The file path, minus `.md`. URLs have no trailing slash, and `/blog/` redirects to `/blog`. |
| `_redirects` or redirect plugins | A `.uri` file containing the target URL |
| `public/` or passthrough copy | Every other file is served at its own path. |
| `_site/` or `dist/` | A `.warc` archive, converted to a static `.tar` for any static host |
| Build hooks and post-processing | Recipes in `_recipes/application/warc/` |

## Look inside any page

Every command resolves through the same pipeline as the dev server, so you can debug a page from the terminal:

```sh
npx qip-router list ./site                 # every route and its media type
npx qip-router get ./site /blog/hello      # the rendered body
npx qip-router head ./site /blog/hello     # status and headers
npx qip-router kindred ./site /blog/hello  # the parent pages and assets its recipes can see
npx qip-router warc ./site -o site.warc    # the whole site as one archive
```

Each Markdown page also keeps its source at its `.md` path, such as `/blog/hello.md`, which is handy for readers, AI agents, and `llms.txt` files.

## Get started

- **[Build a site and blog](/docs/router-tutorial)**: start from an empty folder and end with a deployable static site, in about 15 minutes.
- **[Router Specification](/docs/router-spec)**: the exact rules for routes, recipes, layouts, Kindred Routes, and WARC export.
- **[Recipe Layout](/docs/recipes)**: how recipe steps are validated and ordered.
- **[qip.dev's own site](https://github.com/royalicing/qip/tree/main/site)**: a working example, with syntax highlighting, search, a sitemap, and Open Graph images.

## When not to use it

QIP Router is for sites made of files. Use [`qipx run`](/docs/qipx) to transform bytes with no URLs involved. QIP Router has no server-side rendering per request, database, or client-side framework. The output is static files, which you can enhance with custom elements in `_elements/`.
