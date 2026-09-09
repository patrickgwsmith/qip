<title>Syntax highlight comparison</title>

# Syntax highlight comparison

QIP can highlight raw JavaScript in one WebAssembly call. The component escapes
the source and adds eight semantic classes. Plain text has no wrapper.

<a href="/text/javascript/javascript-to-syntax-highlight-html.wasm" download><code>javascript-to-syntax-highlight-html.wasm</code> is <qip-content-size src="/text/javascript/javascript-to-syntax-highlight-html.wasm"></qip-content-size></a>.

```sh
qip run -i input.js \
  components/text/javascript/javascript-to-syntax-highlight-html.wasm \
  -o highlighted.html
```

The component accepts `text/javascript` and returns an HTML fragment. It does
not add a `pre` or `code` element.

## The classes

[gpu-lexer](https://gpu-lexer.vercel.app/) compares highlighters through nine
common token types. QIP uses the same vocabulary, but not gpu-lexer's token
decisions. Shiki 4.4.3 is the oracle when the two highlighters disagree. QIP's
HTML classes have a `syntax-` prefix so they do not conflict with application
styles.

| Token | HTML class |
| --- | --- |
| Comment | `syntax-comment` |
| String or regular expression | `syntax-string` |
| Number | `syntax-number` |
| Keyword | `syntax-keyword` |
| Type | `syntax-type` |
| Function | `syntax-function` |
| Constant | `syntax-constant` |
| Operator | `syntax-operator` |
| Plain text | No element |

For example:

```html
<span class="syntax-keyword">const</span> answer
<span class="syntax-operator">=</span>
<span class="syntax-number">42</span>;
```

These are not Shiki CSS classes. [Shiki](https://github.com/shikijs/shiki)
normally returns TextMate scopes, tokens, and theme colors. The smaller QIP
vocabulary keeps presentation separate from token meaning.

## Speed on `three.min.js`

The fixture is the exact
[`three@0.97.0/build/three.min.js`](https://unpkg.com/three@0.97.0/build/three.min.js)
file supplied for this comparison. It is not the current Three.js release. Each
test concatenated ten copies into 5,556,500 bytes of JavaScript.

The CPU tests ran sequentially on an Apple M5 with Node.js 26.8.1 and V8
14.6.202.34. Each library had one warm-up run. QIP, Sugar High, and Prism had
ten measured runs. Starry Night and Shiki had three because each run took more
than ten seconds. gpu-lexer ran in Chrome 152 through WebGPU on the same Apple
GPU. Its browser result is useful, but it is not a Node.js runtime comparison.

| Highlighter | Mean | Input | Returned value |
| --- | ---: | --- | --- |
| Existing QIP HTML component | 267 ms | 5.91 MB escaped HTML | 18.52 MB HTML |
| New QIP semantic component | 319 ms | 5.56 MB raw JavaScript | 26.09 MB HTML |
| gpu-lexer | 633 ms | 5.56 MB raw JavaScript | 1,053,420 token ranges |
| [Sugar High 2.3.1](https://github.com/huozhi/sugar-high) | 1.25 s | 5.56 MB raw JavaScript | 147.50 MB HTML |
| [Prism 1.30.0](https://github.com/PrismJS/prism) | 1.83 s | 5.56 MB raw JavaScript | 59.11 MB HTML |
| [Starry Night 3.11.0](https://github.com/wooorm/starry-night) | 13.19 s | 5.56 MB raw JavaScript | HAST with 1,485,453 nodes |
| Shiki 4.4.3 | 34.59 s | 5.56 MB raw JavaScript | 1,160,820 tokens |

The table measures more than token recognition. HTML generators must allocate
and copy their markup. Starry Night builds a syntax tree. Shiki returns detailed
tokens. gpu-lexer returns source ranges and does not build HTML. Compare the
times only with those output costs in view.

The old QIP component also does a different job. It finds JavaScript and TSX
code blocks inside escaped HTML and adds `hljs-*` classes. The new component
accepts raw JavaScript and gives operators their own class. That output is
larger and took 19% longer in this test.

## The Shiki oracle

The first QIP pass agreed with normalized Shiki output on 89.62% of the
non-whitespace characters in `three.min.js`. The first changes raised agreement
to 95.60%. The four-file oracle then exposed errors that one minified file did
not show.

The current lexer uses declarations, assignments, object properties, member
access, calls, constructors, parameters, and conditional expressions to
classify tokens. It also treats `this` as a constant and words such as `new`
and `typeof` as operators. These rules produced the following scores:

| Fixture | Bytes | First score | Current score |
| --- | ---: | ---: | ---: |
| [React 19.2.8 development](https://unpkg.com/react@19.2.8/cjs/react.development.js) | 47,219 | 93.34% | 100.00% |
| [`three.min.js`](https://unpkg.com/three@0.97.0/build/three.min.js) | 555,650 | 95.60% | 99.97% |
| [Underscore 1.13.8](https://unpkg.com/underscore@1.13.8/underscore.js) | 68,916 | 98.16% | 99.95% |
| [Lodash 4.18.1](https://unpkg.com/lodash@4.18.1/lodash.js) | 545,945 | 99.21% | 99.99% |

React gave the largest improvement and now agrees on every compared character.
Its readable source exposed anonymous functions, function-valued properties,
CommonJS names, uppercase parameter names, and reserved words used as property
names. Three.js exposed constructors without parentheses and nested conditional
expressions.

The comparison uses these rules in order:

| Shiki TextMate scope | Common token |
| --- | --- |
| `comment*` | Comment |
| `string*` or a scope that contains `regexp` | String |
| `constant.numeric*` | Number |
| `keyword.operator*` | Operator |
| `entity.name.function*` or `support.function*` | Function |
| Type, class, interface, enum, or supported class scopes | Type |
| Language constants and language variables | Constant |
| Other `keyword*` or `storage*` scopes | Keyword |
| All other scopes | Plain text |

The score counts matching labels for each non-whitespace source character. The
HTML is also decoded and checked against the input. A highlighter cannot gain
points by dropping source text.

These values are focused JavaScript regression measurements. They are not
comparable to gpu-lexer's published Top-25 score. That score covers 1,069 files,
gives unsupported languages zero, and weights languages by GitHub pusher
counts. The gpu-lexer site does not publish its corpus manifest, adapter tables,
or evaluation program. Its exact percentage cannot be reproduced from the
page.

The remaining differences come from context that a small lexer does not fully
parse and from formatting-sensitive TextMate scopes. For example, Shiki treats
`return` as plain text in `return.5`, and a line break can change whether it
classifies a nearby name as a function or type. QIP keeps Shiki as the oracle,
but it does not add a formatting exception that makes ordinary JavaScript less
consistent. Add a rule only when a reduced case describes useful JavaScript
behavior.

## Run the oracle

The differential runner pins Shiki 4.4.3. It downloads each source file and
checks its byte length and SHA-256 digest before it compares output.

```sh
make -C benchmarks/syntax-highlight-comparison install
make -C benchmarks/syntax-highlight-comparison compare
make -C benchmarks/syntax-highlight-comparison benchmark
```

Use JSON output to inspect confusion matrices and per-class precision and
recall:

```sh
cd benchmarks/syntax-highlight-comparison
npm run compare -- --json react-development
```

The manifest and runner are in
`benchmarks/syntax-highlight-comparison/`. The repository does not store copies
of the third-party source files. The benchmark creates one Wasm instance, runs
one warmup, and measures ten renders. Each sample copies both input and output.

Do not copy these complete files into a Compliance oracle. Use them to find a
disagreement, reduce that disagreement to a short JavaScript example, and add
the example to the exact-output fixture. This keeps the executable contract
small and readable.

The Compliance oracle keeps five small, readable examples stable:

```sh
qip comply \
  components/text/javascript/javascript-to-syntax-highlight-html.wasm \
  --with compliance/syntax-highlight-javascript-semantic.comply.wasm \
  --straight-line-oracles
```

It checks exact HTML for functions, operators, constants, strings, comments,
and escaping. The large `three.min.js` comparison finds broader classification
differences. Both checks are useful: one gives a clear contract, and the other
finds patterns that small examples miss.

## When to use another highlighter

Use this QIP component when you need fast JavaScript highlighting, compact
WebAssembly, and stable semantic classes. Use Shiki when exact TextMate scope
coverage and theme compatibility justify its cost. Use Starry Night when you
need GitHub-compatible `pl-*` classes or a HAST tree. Use Prism or Sugar High
when their existing CSS and browser integration fit the application better.

The QIP lexer uses deliberate heuristics. It does not parse a complete
JavaScript program, and it does not support the language range of Shiki or
Starry Night.
