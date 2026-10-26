<title>Build a site and blog with QIP Router</title>
<meta name="description" content="Build a site and blog with QIP Router: Markdown pages, a shared layout, a stylesheet, redirects, SEO meta tags, and a static export with broken-link checking.">
<link rel="canonical" href="https://qip.dev/docs/router-tutorial">
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"TechArticle","headline":"Build a site and blog with QIP Router","description":"Markdown pages, a shared layout, a stylesheet, redirects, SEO meta tags, and a static export with broken-link checking.","url":"https://qip.dev/docs/router-tutorial","proficiencyLevel":"Beginner","dependencies":"Node.js 22 or newer, curl","timeRequired":"PT15M"}
</script>

# Build a site and blog with QIP Router

This tutorial starts from an empty folder and ends with a static site you can deploy anywhere. You need Node.js 22 or newer and `curl`. Each step downloads a small, sandboxed `.wasm` component from qip.dev and drops it into the site.

## 1. Serve a folder

Create a folder with one page:

```sh
mkdir my-site
printf '# My Site\n\nWelcome. Read the [blog](/blog).\n' > my-site/index.md
npx qip-router dev ./my-site
```

Open <http://127.0.0.1:4000>. You'll see the Markdown source as plain text, because the site has no recipes yet. QIP Router doesn't build anything in: every transformation is a recipe step you can see in the folder.

Leave the dev server running. A hard reload in the browser picks up new files and recipes.

## 2. Turn Markdown into HTML

Markdown pages run through `_recipes/text/markdown/`, in the order of each file's number. Add a GitHub Flavored Markdown renderer, followed by a step that wraps the result in an HTML document:

```sh
curl --create-dirs -o my-site/_recipes/text/markdown/10-gfm.wasm \
  https://qip.dev/text/markdown/gfm-commonmark.0.31.2.wasm
curl -o my-site/_recipes/text/markdown/80-document-wrap.wasm \
  https://qip.dev/text/html/html-document-wrap.wasm
```

Reload the page, and it's now HTML. The document wrapper uses the page's first `<h1>` as its `<title>`.

The numbers leave room. To add syntax highlighting later, drop a step numbered between 10 and 80 into the same folder. To turn a step off, rename it so it starts with `-`, such as `-10-gfm.wasm`.

## 3. Add a blog

Folders are routes, so a blog is a folder:

```sh
mkdir my-site/blog
```

Create `my-site/blog/index.md`, which is the page at `/blog`:

```markdown
# Blog

- [Hello, world](/blog/hello-world) — October 2026
```

Create `my-site/blog/hello-world.md`, which is the page at `/blog/hello-world`:

```markdown
<meta name="description" content="The first post on my new site.">

# Hello, world

This site is a folder of Markdown files.

| Feature | Supported |
| --- | --- |
| Tables | Yes |
```

The `<meta>` tag at the top of the post moves into the page's `<head>`. This is how you set what search engines and link previews show: `<meta>`, `<link>`, `<title>`, and `<script type="application/ld+json">` tags at the very top of a page all move into `<head>`, in place of front matter. Add `<link rel="canonical" href="…">` here too once you know your domain.

List the routes to check that the files are where you expect:

```sh
npx qip-router list ./my-site
```

```txt
GET	/	text/html
GET	/blog	text/html
GET	/blog/hello-world	text/html
GET	/blog/hello-world.md	text/markdown
…
```

Every page also keeps its Markdown source at its `.md` path.

## 4. Share a layout and stylesheet

Add the recipe that applies layouts to every page. It runs over the whole site, so it goes in `_recipes/application/warc/`:

```sh
curl --create-dirs -o my-site/_recipes/application/warc/20-main-layout.wasm \
  https://qip.dev/application/warc/warc-apply-main-layout.wasm
```

Now declare a layout at the top of `my-site/index.md`. A layout on `/` applies to every page on the site:

```markdown
<qip-main-layout>
<link rel="stylesheet" href="/styles.css">
<nav><a href="/">Home</a> <a href="/blog">Blog</a></nav>
<article><slot></slot></article>
<footer>© 2026 Me</footer>
</qip-main-layout>

# My Site

Welcome. Read the [blog](/blog).
```

Each page's content goes in place of `<slot>`. Links to the current page get `aria-current="page"`, so you can style them. Keep the layout free of blank lines, because a blank line ends an HTML block in Markdown.

A layout on `/blog` would apply only to `/blog` and the pages below it, and would go inside the site layout's slot. See [Main layouts](/docs/router-spec#main-layouts) for named slots and nesting.

Any file that isn't a page is served at its own path, so `my-site/styles.css` is `/styles.css`:

```css
body { font: 18px/1.5 system-ui; max-width: 40em; margin: 0 auto; padding: 1em; }
nav a[aria-current="page"] { font-weight: bold; }
```

## 5. Add a redirect

A `.uri` file holds one URL to redirect to. Add the recipe that turns these files into redirects, then create one:

```sh
curl -o my-site/_recipes/application/warc/05-redirects.wasm \
  https://qip.dev/application/warc/warc-text-uri-list-to-redirect.wasm
printf '/blog/hello-world\n' > my-site/first-post.uri
```

`/first-post` now responds with `302 Found` and `Location: /blog/hello-world`.

## 6. Inspect from the terminal

Every command runs the same pipeline as the dev server:

```sh
npx qip-router get ./my-site /blog            # the rendered HTML
npx qip-router head ./my-site /first-post     # status and headers
npx qip-router kindred ./my-site /blog/hello-world
```

`kindred` lists the pages that whole-site recipes can see while rendering one page. For `/blog/hello-world`, that's `/` and `/blog`, which is how the layout on `/` reaches the post.

## 7. Build and deploy

Export the site as one WARC archive, check its links, and convert it to static files:

```sh
npx qip-router warc ./my-site \
  | npx @qip.dev/qipx qip.dev run \
      application/warc/warc-check-broken-links.wasm \
      application/warc/warc-to-static-tar-no-trailing-slash.wasm \
  > site.tar
mkdir -p dist && tar -xf site.tar -C dist
```

`qipx` downloads each component from qip.dev on first use and saves it under `application/warc/`. If a page links to a path that doesn't exist, the link check fails and the command exits with an error, so a broken site never reaches `site.tar`. The error gives the archive offset of the first broken link and a mode: 0 for a missing page, 1 for a page that returns an error status, 2 for a missing `#fragment`, and 3 for a link that can't resolve to a path on the site.

`dist/` contains `index.html`, `blog.html`, `blog/hello-world.html`, `styles.css`, and a `_redirects` file for your redirects. Upload it to any static host that serves `/blog` from `blog.html`, such as Cloudflare Pages or Netlify.

## Where to go next

- Browse [text components](/text) for more Markdown and HTML steps, such as syntax highlighting.
- Read the [Router Specification](/docs/router-spec) for the exact routing and recipe rules.
- See how [qip.dev's own site](https://github.com/royalicing/qip/tree/main/site) adds search, a sitemap, and Open Graph images with more recipes.
