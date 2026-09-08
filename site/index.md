<title>QIP: a new way to render</title>

<style>
h1 + a, nav > a  {
    text-align: center;
    display: inline-block;
    margin-bottom: var(--paragraph-leading);
    padding: 0.5lh 1.5em;
    border: 1px solid currentColor;
    border-radius: 10000px;
    text-decoration: none;

    &:hover {
        background: rgba(255, 255, 255, 0.125);
    }
}

qip-edit source { display: none }

.browser-preview-demo {
    gap: 0.5lh;
}

.browser-preview-view {
    display: contents;
    gap: 0.5lh;
}

.browser-preview-output {
    display: block;
    padding: 0;
    overflow: auto;
}

.browser-preview-output pre {
    margin: 0;
    padding: 0.5rlh 1em;
    max-height: 8lh;
}

.browser-preview-output iframe {
    display: block;
    width: 100%;
    height: 100%;
    border: 0;
    background: white;
}

.macintosh-1bit-comparison {
    display: flex;
    flex-wrap: nowrap;
    gap: 24px;
    max-width: 100%;
    overflow-x: auto;
    padding-bottom: 0.5lh;
}

.macintosh-1bit-comparison figure {
    flex: 0 0 512px;
    margin: 0;
}

.macintosh-1bit-comparison qip-play {
    cursor: none;
    image-rendering: pixelated;
}

.macintosh-1bit-comparison figcaption {
    margin-top: 0.25lh;
}
</style>

<h1>Components that are<br> <em>Quick</em> to make/maintain/run, <em>Isolated</em> from net/disk/deps, <em>Portable</em> to web/server/native.</h1>

<a href="/docs">Read the docs</a>

QIP components are fast to create with coding agents and fast for users to run.

Users get small `.wasm` modules that load quickly. You get code small enough to review.

Render across browser, server, mobile, native, CLI, and CI. Same input, same output everywhere.

---

## Today we grant every line of code the world

Most software is built with layers of frameworks, packages, platforms, and operating-system features. It means even a tiny calculation assumes availability of installed packages, environment variables, filesystem layout, network services, locale, clocks, and the exact setup of the machine around it.

Containers can precisely package that environment. This is useful for full applications, but for a text/image transformation, validator, calculation, or small interactive tool, it is often more machinery than the work requires. Our defaults expand the security boundary that every line of code gets and now AI coding raises the stakes.

QIP uses a narrower boundary: explicit input, output, memory, and zero host access. That makes small components easier to create, test, and review — including code written by coding agents.

## Components that render any content

Use QIP components for text, images, documents, archives, interactive UI, or any MIME type.

Just like the web is `request -> response`, QIP components are `input -> output`. Yet QIP components are not tied to HTML or JavaScript: they take any content as input and render any content as output.

Your components can render Markdown into HTML, URLs into QR codes, SVG into bitmap images, SQLite databases into CSV, or WARC archives into deployable websites. Missing something? Prompt a small component and add it to your collection.

```bash
echo "# A Markdown renderer that works _identically_ on any platform" \
| qip run components/text/markdown/gfm-commonmark.0.31.2.wasm
# <h1>A Markdown renderer that works <em>identically</em> on any platform<h1>
```

<nav>
<a href="/markdown-to-html">Try our GitHub-Flavored Markdown renderer</a>
</nav>

## Portable pipelines of purity

You can pipe one component into another step-by-step like a recipe.

Make a recipe you like? It will work identically on mobile, in a browser, in your CI pipeline, or on Windows. You can be confident if it works here, it works there.

For example, one component can render Markdown to HTML, then it passes that to the next component to highlight TSX code blocks:

```bash
printf '%s\n' \
  '# Markdown with code snippet' \
  '' \
  '```tsx' \
  'const pi: number = 3.14;' \
  '```' \
| qip run \
  components/text/markdown/gfm-commonmark.0.31.2.wasm \
  components/text/html/html-code-syntax-highlight-tsx.wasm

# <h1>Markdown with code snippet</h1>
# <pre><code class="language-tsx hljs"><span class="hljs-keyword">const</span> pi: <span class="hljs-type">number</span> = <span class="hljs-number">3.14</span>;
# </code></pre>
```

## Browser rendering

You can render the same QIP components in the browser:

<form class="browser-preview-demo" aria-label="Markdown to HTML">
    <qip-edit>
        <source src="/text/markdown/gfm-commonmark.0.31.2.wasm" type="application/wasm" />
        <source src="/text/html/html-code-syntax-highlight-tsx.wasm" type="application/wasm" />
        <source src="/text/html/html-add-highlight-stylesheet-night-owl.wasm" type="application/wasm" />
        <label class="browser-preview-view">
            <strong>Markdown input</strong>
            <textarea name="input" rows="5"># Markdown with highlighted code&#10;```tsx&#10;const pi: number = 3.14;&#10;```</textarea>
        </label>
        <section class="browser-preview-view" aria-labelledby="home-html-preview-heading">
            <strong id="home-html-preview-heading">HTML output</strong>
            <output name="output" class="browser-preview-output">
                <iframe title="Rendered HTML preview" sandbox></iframe>
            </output>
        </section>
    </qip-edit>
</form>

Use the `<qip-edit>` custom element to render a series of QIP components with user `<input>`.

<pre><code class="language-html">&lt;form aria-label=&quot;Markdown to HTML&quot;&gt;
    &lt;qip-edit&gt;
        &lt;source src=&quot;/text/markdown/gfm-commonmark.0.31.2.wasm&quot; type=&quot;application/wasm&quot; /&gt;
        &lt;source src=&quot;/text/html/html-code-syntax-highlight-tsx.wasm&quot; type=&quot;application/wasm&quot; /&gt;
        &lt;textarea name=&quot;input&quot; rows=&quot;5&quot;&gt;# Markdown with highlighted code
```tsx
const pi: number = 3.14;
```&lt;/textarea&gt;
        &lt;output name=&quot;output&quot;&gt;&lt;iframe title=&quot;Rendered HTML preview&quot; sandbox&gt;&lt;/iframe&gt;&lt;/output&gt;
    &lt;/qip-edit&gt;
&lt;/form&gt;
</code></pre>

## The website router without bitrot

Markdown… Recipes… We can compose this into a static website generator. Each file gets rendered by a recipe of QIP components based on its MIME type. These become the HTTP response bodies.

Every component is replaceable. Don’t like the Markdown renderer? Swap it out.

And every page route becomes combined into a `.warc` Web Archive. This allows you to do site-wide transforms. Need a plugin to generate OG images? Vibe-code one.

First, create a folder of Markdown and images files and use `qip router` to render a website:

```txt
site/
  index.md
  about.md
  docs/index.md
  docs/install.md
  _recipes/text/markdown/10-commonmark.0.31.2.wasm
```

```bash
# Run a dev server on port 4114
qip router dev ./site -p 4114

# Make a HEAD request to the /about page
qip router head ./site /about

# Make a GET request to the /about page
# This works even with no dev server running, letting your coding agent test things
qip router get ./site /about

# Copy a component to syntax highlight bash code
cp html-code-syntax-highlight-bash.wasm ./site/_recipes/text/markdown/20-html-code-syntax-highlight-bash.wasm

# Generate an archive of the entire site with view source enabled to share your components
qip router warc ./site --view-source
```

The same components that you use to render the static site can run in the browser via JavaScript. There’s no such thing as a “server component” or “client component”: they are the same component.

Because components are self-contained, maintenance becomes a breeze. Don't worry about needing to update your dependencies every few months so your site still builds. Your site is content plus some `.wasm` files and a little bit of glue to connect the two. Bitrot be gone!

## Cross-platform `<canvas>` components

QIP Interactive Components receive keyboard & pointer events and render out pixels.

Use `<qip-play>` to render them in the browser, or use our SDK to render them in Swift.

<div style="display:flex;flex-wrap:wrap;gap:24px;align-items:flex-start">
  <qip-play canvas-width="min(180px, 100%)" canvas-height="auto" touch-action="pan-y" style="cursor:grab">
    <source class="home-chronograph-source" src="/interactive/chronograph.wasm" type="application/wasm" data-uniform-current_seconds="0" data-uniform-hdr="0" />
  </qip-play>
  <qip-play canvas-width="min(180px, 100%)" canvas-height="auto" touch-action="pan-y" style="cursor:grab">
    <source class="home-chronograph-source" src="/interactive/chronograph.wasm" type="application/wasm" data-uniform-current_seconds="0" data-uniform-hdr="1" />
  </qip-play>
</div>

<script type="module">
const currentSeconds = String((Date.now() / 1000) % 60);
for (const source of document.querySelectorAll(".home-chronograph-source")) {
  source.setAttribute("data-uniform-current_seconds", currentSeconds);
}
</script>

A small JavaScript host passes the current second once as a uniform. The Timed
component then advances from the explicit lifecycle timestamps and requests an
update every 200 ms, matching the five steps per second of an 18,000 vph
mechanical movement. That keeps the clock input explicit without giving Wasm
ambient clock access. The first instance emits the compatible RGBA8 sRGB
profile. The second emits linear Display P3 float pixels with HDR highlights.
`<qip-play>` uses a float16 canvas when the browser supports one and tone maps
the same highlights for an 8-bit canvas otherwise.
Drag either watch horizontally to tilt it. The component redraws its SDF dial
directly through a one-axis transform, moves the crystal and bezel
reflections with the angle, and returns to rest at 60 Hz after release.
Vertical touch gestures remain available for page scrolling.

---

The same component can keep its working display in the original Macintosh
512×342 one-bit format, then expand it only when QIP asks for output. Drag its
window or disk, or open a menu. Each bitmap pixel is one CSS pixel; Retina
displays expand it to device pixels without smoothing.

<div class="macintosh-1bit-comparison" aria-label="One-bit Macintosh SDR, pink, orange, and yellow comparison">
  <figure>
    <qip-play canvas-width="512px" canvas-height="342px">
      <qip-step name="desktop">
        <source src="/interactive/macintosh-1bit.wasm" type="application/wasm" />
      </qip-step>
    </qip-play>
    <figcaption>RGBA8 sRGB</figcaption>
  </figure>
  <figure>
    <qip-play debug canvas-width="512px" canvas-height="342px">
      <qip-step name="desktop">
        <source src="/interactive/macintosh-1bit.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="duotone">
        <source
          src="/image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm"
          type="application/wasm"
        />
      </qip-step>
    </qip-play>
    <figcaption>HDR pink · RGBA32F display-p3-linear</figcaption>
  </figure>
  <figure>
    <qip-play canvas-width="512px" canvas-height="342px">
      <qip-step name="desktop">
        <source src="/interactive/macintosh-1bit.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="duotone">
        <source
          src="/image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm"
          type="application/wasm"
          data-uniform-highlight_r="2.4"
          data-uniform-highlight_g="0.42"
          data-uniform-highlight_b="0.015"
        />
      </qip-step>
    </qip-play>
    <figcaption>HDR orange · RGBA32F display-p3-linear</figcaption>
  </figure>
  <figure>
    <qip-play canvas-width="512px" canvas-height="342px">
      <qip-step name="desktop">
        <source src="/interactive/macintosh-1bit.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="duotone">
        <source
          src="/image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm"
          type="application/wasm"
          data-uniform-highlight_r="2.4"
          data-uniform-highlight_g="1.65"
          data-uniform-highlight_b="0.04"
        />
      </qip-step>
    </qip-play>
    <figcaption>HDR yellow · RGBA32F display-p3-linear</figcaption>
  </figure>
</div>

Every desktop instance draws into a packed 21,888-byte bitplane and emits the
same RGBA8 sRGB frame. The color pipelines then give that ordinary frame to the
same finite Content component. Uniforms map black to near-black ink and white
to HDR pink, orange, or yellow in linear Display P3. Debug metrics on the pink
example break out the cost and memory of each `<qip-step>`.

---

<qip-play canvas-width="720px" canvas-height="auto">
  <source src="/interactive/cover-flow.wasm" type="application/wasm" />
</qip-play>

---

<qip-play canvas-width="820px" canvas-height="auto">
  <source src="/interactive/openai-anthropic-arr.wasm" type="application/wasm" />
</qip-play>

---

<qip-play canvas-width="min(762px, 100%)" canvas-height="auto">
  <source src="/interactive/sudoku.wasm" type="application/wasm" />
</qip-play>

---

See [`/play`](/play) for more interactive examples, or [`/charts`](/charts) for chart-focused components.

## Tools without the trackers

Ever need to generate a favicon or decode base64 and find yourself on a site with more ad banners than inputs? [Here](/tools) are some open source utilities that you can download the `.wasm` to and run locally.

- [Markdown to HTML](/markdown-to-html)
- [QR code maker](/qr)
- [Mermaid renderer](/mermaid)
- [Base64 encoder and decoder](/base64)
- [Currency formatter](/currency)
- [Unicode transforms](/unicode)
- [JSON prettifier](/json-prettify)
- [CSS minifier](/css-minifier)

Want another? Request me to make one.

## FAQ

### How is QIP different from WASI?

WASI is useful when a WebAssembly program needs operating-system-like capabilities. QIP is purposefully much narrower. A QIP component gets bytes from the host, transforms them, and returns bytes. It cannot access the filesystem, network, environment, clock, or secrets.

That smaller contract allow components to run easily in browsers, mobile apps, servers, CI, and native hosts. It also makes the attack-surface much narrower.

### How is QIP different from React?

React has become the default choice for making web apps and many native apps. Adopting React usually means adopting JavaScript full-stack. QIP wants to be platform and language agnostic: you can write QIP components in anything that compiles to `.wasm` and you can run `.wasm` modules pretty much in any modern platform. Because QIP Components are just WebAssembly they work in React (TODO: React QIP documentation page).

### How is QIP different from Flutter?

Flutter follows the write-once, run-anywhere philosophy. QIP is also write-once, run-anywhere but is designed to be embedded inside existing apps. You don’t have to port your entire app to QIP and WebAssembly.

This means you can make the most of native tooling and frameworks with proper UI controls and tight integration with the target platform. And then you sprinkle in QIP components where they make sense for their cross-platform or security benefit.

Flutter helps you write one app for many platforms. QIP helps you write one component for many apps.

## Learn more

- [Why QIP](/docs)
- [Adopting QIP in React](/docs/adopting-qip-in-react)
- [How QIP Works](/docs/how-it-works)
- [QIP Component Contract](/docs/component-contract)
- [Router Specification](/docs/router)
