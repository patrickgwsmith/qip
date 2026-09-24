<title>QIP: reproducible rendering components</title>

<style>
.hero-left {
    padding-bottom: 1lh;

    a {
        text-align: center;
        display: inline-block;
        padding: 0.5lh 1.5em;
        border: 1px solid currentColor;
        border-radius: 10000px;
        text-decoration: none;

        &:hover {
            background: rgba(255, 255, 255, 0.125);
        }
    }
}

@media (min-width: 940px) {
    .hero-left {
        max-width: 48%;
        float: left;
    }
    .hero-right {
        max-width: 48%;
        float: right;
    }
    hr { clear: both }
}
</style>

<section class="hero-left">

<h1>Easy to write, fast to run, hard to break.</h1>

<p>QIP components are Quick, Isolated & Portable.</p>

<a href="/docs">Read the docs</a>

</section>

<section class="hero-right">

## Reproducible rendering across every platform.

QIP Components are self-contained WebAssembly modules that run like small rendering functions. They render text, images, archives, sites, and interactive pixels from explicit inputs, primitive uniforms, and event/tick calls.

They are fast for you to create with coding agents and fast for users to run.

Same input, same output, everywhere: browser, server, CLI, native, CI, mobile, and edge. If it renders today, QIP is designed to make it render the same tomorrow.

Use QIP to add portable pockets of purity to existing applications, then compose pocket-sized pipelines when a workflow grows. QIP is designed for agents to rip: big room to optimize, small surface to attack. Components have enough scope for meaningful generation and optimization, with explicit contracts and quarantine from filesystem, network, secrets, environment, and dependencies by default.

</section>

---

## Content-first components

```bash
du -h components/text/markdown/commonmark.0.31.2.wasm
# 48K    components/text/markdown/commonmark.0.31.2.wasm

echo "# A Markdown renderer that works identically cross-platform!" \
| qip run components/text/markdown/commonmark.0.31.2.wasm
# <h1>A Markdown renderer that works identically cross-platform!<h1>
```

QIP components render content. Pass content in, get content out, and use MIME types to describe what is flowing through the system. It is webby in the same way HTTP is request -> response, but it is not tied to HTML, JavaScript, Custom Elements, props, imports, or app schemas.

A component can turn one content type into another, and a pipeline can turn Markdown into HTML, URLs into QR codes, SVG into bitmap images, or WARC archives into deployable websites. Missing something? Prompt a small component and add it to your collection.

## Browser rendering

Load the exact same Markdown component in the browser with the `<qip-preview>` custom HTML element:

<pre><code class="language-html">&lt;form aria-label=&quot;Markdown to HTML&quot;&gt;
    &lt;qip-preview&gt;
        &lt;source src=&quot;/components/text/markdown/commonmark.0.31.2.wasm&quot; type=&quot;application/wasm&quot; /&gt;
        &lt;textarea name=&quot;input&quot; rows=&quot;3&quot; placeholder=&quot;Write some Markdown&quot;
        &gt;# A Markdown renderer that works identically cross-platform! Try typing…&lt;/textarea&gt;
        &lt;output name=&quot;output&quot;&gt;&lt;/output&gt;
    &lt;/qip-preview&gt;
&lt;/form&gt;
</code></pre>

<form aria-label="Markdown to HTML">
    <qip-preview>
        <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
        <textarea name="input" rows="3" placeholder="Write some Markdown"
        ># A Markdown renderer that works identically cross-platform! Try typing…</textarea>
        <output name="output"></output>
    </qip-preview>
</form>

## Interactive components

Interactive QIP Components receive keyboard & pointer events and render out pixels.

<qip-play log>
  <source src="/gui/sudoku.wasm" type="application/wasm" />
</qip-play>

See [`/play`](/play) for more interactive examples, or [`/charts`](/charts) for chart-focused components.

## Private utilities

These pages run QIP components in your browser:

- [Markdown to HTML](/markdown-to-html)
- [JSON prettifier](/json-prettify)
- [CSS minifier](/css-minifier)
- [JPEG location stripper](/jpeg-location-stripper)
- [Image color palette extractor](/image-color-palette)

## Interactive explainers

- [Cache-Control request chains](/cache-control)
- [Flexbox and SwiftUI layout](/layout-systems)
- [Browser security: CORS, CSRF, and XSS](/browser-security)
- [Web mechanics: TLS, DNS, page loading, and cookies](/web-mechanics)
- [Page load waterfall](/page-load-waterfall)

## Portable pipelines of purity

QIP can take Markdown files and render a website:

```txt
site/
  index.md
  docs/router.md
  _recipes/text/markdown/10-markdown-basic.wasm
  _gui/sudoku.wasm
```

```bash
# Make a HEAD request to the /about page
qip router head ./site /about

# Make a GET request to the /about page
qip router get ./site /about

# Copy a component to syntax highlight bash code
cp syntax-highlight-bash.wasm ./site/_recipes/text/markdown/20-syntax-highlight-bash.wasm

# Run a dev server
qip dev ./site

# Generate an archive of the entire site with view source enabled
qip router warc ./site --view-source
```

Recipes allow each MIME type to be processed by a series of QIP component steps. Each source file is transformed by the recipe and becomes a webpage route. The same components can be rendered in the browser via custom HTML elements.

If it works here, it works there. If it works today, it'll work tomorrow. Build a pipeline where it first helps, then carry it to browser, native mobile, server, CLI, CI, or edge with the same components and the same rendering behavior.

QIP turns performance work into portable component work. Every QIP pipeline stage is a benchmark boundary: feed it input, measure it, optimize it, and compare the output bytes. If the bytes still match and the stopwatch got faster, ship the same `.wasm` module everywhere that component runs. If it is fast today, it should remain fast tomorrow. Agents get enough scope to use Zig or C compilers, explicit memory layouts, and SIMD, while the Wasm sandbox keeps optimization inside portable code instead of host-specific GPU, filesystem, or platform side effects.

## Software today never stops

Modern software depends on libraries, frameworks, and platforms that are continuously changing.

Docker can package that world, but it preserves the idea that a small rendering function needs a whole application environment around it. QIP is for application output that needs to be portable, predictable, testable, and hard to break.

## Reproducible rendering

**QIP Components** are self-contained WebAssembly modules with strict input and output. The output of one component can become the input of the next, allowing you to compose deterministic pipelines that keep working across platforms and over time.

- **Reproducible Rendering:** same component, same input, same uniforms or event transcript, same output.
- **Content-First Components:** pass content in, get content out, and use MIME types instead of framework props, imports, schemas, or UI-only component trees.
- **Portable Pipelines of Purity:** build a pipeline once, then carry it across platforms with the same components, same outputs, and no ambient host state.
- **Designed for Agents to Rip:** big room to optimize, small surface to attack. Components have enough scope for meaningful generation and optimization, with deterministic output checks and sandboxed host access to keep changes reviewable.

All these properties combined give you predictability. Reproducible rendering makes tests sharper because output drift is visible. Portable pipelines of purity make adoption less fragile because a working pipeline can move from web to native mobile, server, CLI, CI, or edge without changing its rendering contract. Agent-friendly components let you experiment with generated and optimized code without handing it filesystem, network, or secret access.

You do not rewrite an application around QIP. You add portable pockets of purity where behavior and performance need to stay stable, then grow those pockets into pipelines when the workflow deserves it.

## Learn more

- [Why QIP](/docs)
- [How QIP Works](/docs/how-it-works)
- [QIP Component Contract](/docs/component-contract)
- [Router Specification](/docs/router)
