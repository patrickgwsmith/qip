# Add Open Graph Images To A WARC With Inter

`warc-add-open-graph-image-inter-png.wasm` takes an `application/warc` archive
and returns it with a 1200×630 title card for each HTML page. For each page it
adds a PNG response record and `og:image`, `twitter:card`, and `twitter:image`
meta tags. It draws Inter Display glyph outlines straight to pixels in one
pass, with no SVG step and no separate rasterize and encode components.

The qip.dev site uses it as the WARC recipe
`10-add-open-graph-image-inter-png.wasm`, so `qip router warc ./site` adds an
image for every page:

```bash
qip router warc ./site --host https://qip.dev -o site.warc
```

You can also run it on an existing archive:

```bash
qip run -i site.warc -o site-with-og.warc \
  application/warc/warc-add-open-graph-image-inter-png.wasm \
  -u background_color_rgba=0x4b2e83ff -u text_color_rgba=0xffffffff
```

## Which pages get an image

The component changes a record only when all of these are true:

- It is a `response` record with HTTP status 200 and a `text/html` or
  `application/xhtml+xml` content type.
- Its head has no `og:image` or `twitter:image` meta tag, other than
  [template tags](#customize-a-pages-card). Pages that declare their own
  image are left byte for byte unchanged.
- It has title text: the head's `<title>`, or the first `<h1>` when the
  title is missing or has no characters the font can draw. Tags inside the
  `<h1>` are dropped, and character references such as `&amp;` and
  `&#x2014;` are decoded.

The image path follows `warc-add-open-graph-image-meta.wasm`: `/` maps to
`/_og/index.png`, and `/docs/formats` and `/docs/formats.html` map to
`/_og/docs/formats.png`. The meta tags use an absolute URL, such as
`https://qip.dev/_og/docs/formats.png`, when the page's `WARC-Target-URI` has
an origin, because the Open Graph protocol expects an absolute URL and some
crawlers ignore relative ones. A bare-path target URI gives a root-relative
URL.

The PNG record goes directly after its page and copies the page's
`WARC-Date`. Its `WARC-Record-ID` is derived from the image URL, so the same
site produces the same archive.

When the archive already has a record for the image path, the meta tags
point at that record and the component renders nothing. Pages that map to a
path an earlier page already rendered behave the same way. To replace
pre-rendered images in a site's `_og` directory, run the router with
`--exclude _og`.

## Customize a page's card

A page can set its own card text and colors with an `og:image` or
`twitter:image` tag whose URL is a `/_og/….png` path with a query string:

```html
<meta property="og:image" content="/_og/index.png?primary=A+new+way+to+render&amp;secondary=qip.dev+WebAssembly+everywhere">
```

In a Markdown page, put the tag at the top with the `<title>` so it moves
into `<head>`. The component renders the card from the query and replaces the
tag with the usual three tags, pointing at the path without the query:
`https://qip.dev/_og/index.png`. The query never reaches the published page,
so a static export has a file at that path.

The query takes these parameters. Others, such as a `v=2` cache buster, are
ignored.

- `primary`: the main text, in place of the page title. When it is missing
  or has nothing the font can draw, the title or first `<h1>` is used.
- `secondary`: a smaller line below the primary text, in Regular, auto-fit
  from 44px down to 24px. It takes at most a third of the card's height, and
  the primary text fits in the rest. The two are centered together.
- `text_color_rgba`, `background_color_rgba`, `font_weight`, and
  `font_max_size`: the [uniforms](#uniforms), for this page only. Numbers are
  decimal or `0x` hex, such as `0x4b2e83ff`. A value that doesn't parse is
  ignored.

Values are URL-encoded: `+` or `%20` for a space, `%26` for `&`. Write `&`
between parameters as `&amp;` in HTML, though a bare `&` also works.

The image path is the template's path, not the one derived from the page's
URL, so pages can choose their own. Any origin in the template is replaced
with the page's. When a page has both an `og:image` and a `twitter:image`
template, the first one's query is used and both tags are replaced. A page
that mixes a template with an image tag that isn't one is left unchanged.

## Layout and pixels

The layout matches `text-to-og-image-svg-inter.wasm`: a left-aligned title at
a 96px margin, vertically centered within 72px margins. Auto-fit chooses the
largest even font size from 112px down to 32px at which the wrapped title
fits. It uses Inter Display's proportional advances and pair kerning.

Coverage is the exact area of each pixel under the outlines, so edges have
256 levels. On qip.dev titles, the mean channel difference from the SVG
pipeline's 4×4 supersampled output is 0.3 out of 255.

The PNG is 8-bit indexed color. Palette entry N is the text color composited
over the background at N/255 coverage in sRGB, which is how SVG composites.
A background with alpha below `0xff` adds a `tRNS` chunk.

Blank rows above and below the text are encoded as DEFLATE runs without
per-byte work. Only the rows with text go through the shared compressor in
`bytes/lib/deflate.zig`. On the qip.dev archive, the component adds 153 cards
in about 2 seconds, with an average size of 12 KB.

## Uniforms

- `text_color_rgba`: packed `0xRRGGBBAA`; the default is `0x101010ff`.
- `background_color_rgba`: packed `0xRRGGBBAA`; the default is `0xeecc33ff`.
- `font_weight`: values below 550 select Regular 400; other values select
  Bold 700. The default is 700.
- `font_max_size`: `0` uses the 112px auto-fit ceiling. Other values set a
  ceiling clamped to 32–160px.

Uniforms reset to these defaults after each render.

## Limits

- Glyph coverage is the same as `text-to-og-image-svg-inter.wasm`: printable
  ASCII, U+00A0–U+00FF, and common title punctuation. Other characters are
  skipped, not replaced. A page whose title has no supported characters gets
  no image.
- Titles longer than 300 characters are cut and end with an ellipsis. A title
  with a word too wide for the card at 32px gets no image.
- There is no logo or background image. For custom designs,
  render images with your own pipeline and let
  `warc-add-open-graph-image-meta.wasm` add the tags.
- Each site build renders every card again. The images are not cached
  between builds.
