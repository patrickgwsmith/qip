<title>QIP TUI components</title>

<style>
qip-tui + pre code,
#tui-page-debugger-status + pre code {
  font-size: 1.125rem;
  line-height: 1.5;
}
.tui-flow {
  margin-block: 1.5rem;
  padding: 1rem;
  border: 1px solid color-mix(in srgb, var(--text) 25%, transparent);
  border-radius: 0.75rem;
  background: color-mix(in srgb, var(--bg) 87.5%, white);

  hr {
    margin-bottom: var(--paragraph-leading);
  }

  em {
    display: block;
    text-align: center;
    font-size: 0.875rem;
    margin-bottom: 0.5rem;
  }
}
.tui-flow figcaption {
  text-align: center;
  margin-bottom: 1rem;
  font-size: 150%;
  font-weight: bold;
}
.tui-flow-stage > strong {
  display: block;
  text-align: center;
  margin-bottom: 0.5rem;
}
.tui-flow-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 1.5rem minmax(0, 1.1fr) 1.5rem minmax(0, 1.2fr);
  gap: 0.5rem;
  align-items: center;
}
.tui-flow-inputs {
  display: grid;
  gap: 0.5rem;
}
.tui-flow-card {
  min-width: 0;
  padding: 0.75rem;
  border: 1px solid color-mix(in srgb, var(--text) 30%, transparent);
  border-radius: 0.5rem;
  background: var(--bg);
}
.tui-flow-card strong,
.tui-flow-card small {
  display: block;
}
.tui-flow-card small {
  margin-top: 0.25rem;
  font-size: 0.8125rem;
}
.tui-flow-prepared {
  max-width: 30rem;
  margin: 0.75rem auto 0;
  text-align: center;
}
.tui-flow-arrow {
  color: var(--link);
  font-size: 1.5rem;
  text-align: center;
}
.tui-flow-boundary, .tui-flow-output {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
  justify-content: center;
  margin-top: 1rem;
  padding-top: 1rem;
  border-top: 1px solid color-mix(in srgb, var(--text) 25%, transparent);
  font-size: 0.875rem;
  font-style: italic;
}
.tui-flow-output .tui-flow-arrow {
  font-size: 1.125rem;
}
@media (max-width: 45rem) {
  .tui-flow-row { grid-template-columns: minmax(0, 1fr); }
  .tui-flow-row > .tui-flow-arrow { transform: rotate(90deg); }
}
</style>

# QIP TUI components

QIP TUIs are WebAssembly components that download from the web yet keep your data safe in a sandbox.
The same component works in a terminal via `qiptui` and in the browser via `<qip-tui>`.

<figure class="tui-flow" aria-labelledby="tui-flow-title">
  <figcaption id="tui-flow-title">How qiptui isolates loading from user input:</figcaption>
  <hr>
  <div class="tui-flow-stage">
    <strong>1. Load .wasm module</strong>
    <div class="tui-flow-row">
      <div class="tui-flow-card">
        URL or file path
      </div>
      <span class="tui-flow-arrow" aria-hidden="true">→</span>
      <div class="tui-flow-card">
        Download TUI .wasm
      </div>
      <span class="tui-flow-arrow" aria-hidden="true">→</span>
      <div class="tui-flow-card">
        Instantiate WebAssembly
      </div>
    </div>
  </div>
  <hr>
  <div class="tui-flow-stage">
    <strong>2. Load optional input</strong>
    <div class="tui-flow-row">
      <div class="tui-flow-card">
        <code>-i</code> and <code>-F</code> args
      </div>
      <span class="tui-flow-arrow" aria-hidden="true">→</span>
      <div class="tui-flow-card">
        Read bytes
      </div>
      <span class="tui-flow-arrow" aria-hidden="true">→</span>
      <div class="tui-flow-card">
        Copy to WebAssembly memory
      </div>
    </div>
  </div>
  <hr>
  <div class="tui-flow-stage">
    <strong>3. Interact locally</strong>
    <em>There’s no file or network access from this point.</em>
    <div class="tui-flow-row">
      <div class="tui-flow-inputs">
        <div class="tui-flow-card">
          Keyboard events
        </div>
      </div>
      <span class="tui-flow-arrow" aria-hidden="true">→</span>
      <div class="tui-flow-card">
        Copy data to WebAssembly memory, calls <code>key_event()</code>
      </div>
      <span class="tui-flow-arrow" aria-hidden="true">→</span>
      <div class="tui-flow-card">
        WebAssembly renders output displayed to user
      </div>
    </div>
  </div>
  <hr>
  <em>
    User input cannot trigger any further network activity: no tracking or <a href="https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/">exfiltration</a> of user data.
  </em>
</figure>

## Try the examples

Focus an example below to try it here, or run the command beneath it in your
terminal.

### Browser compatibility

Focus the list and type part of a feature path, such as `backdrop-filter` or
`Navigator.gpu`. Press Enter to compare Chrome, Firefox, Safari, and Edge.
Up and Down select a browser; Page Up and Page Down scroll its support notes.
Escape returns to the search. A `*` marks support with a note, flag, prefix,
alternate name, or partial implementation. The detail pane also shows older
support statements, including removed forms.

<qip-tui aria-label="Browser compatibility finder" height="28rem">
  <source src="/tui/browser-compat-finder.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/browser-compat-finder.wasm
```

This finder contains 13,603 Web API and CSS-property feature entries from
[MDN browser-compat-data 8.1.2](https://www.npmjs.com/package/@mdn/browser-compat-data/v/8.1.2),
built 17 September 2026. It is a fixed snapshot, so check current data
before making a release decision. Browser support can depend on an operating
system, device, flag, or prefix; inspect the selected browser's statements
before treating a version number as unconditional support.

### Media types

Focus the list and type `application/json`, `+xml`, or an RFC number such as
`RFC 8259`. Enter opens the IANA label, references, and record date. Escape
returns to the search. The list keeps IANA's obsolete and deprecated labels.

<qip-tui aria-label="IANA media type finder" height="26rem">
  <source src="/tui/iana-media-type-finder.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/iana-media-type-finder.wasm
```

This finder contains 2,361 records from the [IANA media-type registry](https://www.iana.org/assignments/media-types),
updated 22 September 2026. The registry list names types and references; it
does not map file extensions or prove that a file has the stated format.

### Service ports

Focus the list and type a service such as `https`, a port such as `443`, or
both a port and protocol such as `53 udp`. A number matches that exact port
or a registered range containing it. Enter shows the description, reference,
assignee, dates, and assignment notes. Use Page Up and Page Down to scroll long
notes; Escape returns to the search.

<qip-tui aria-label="IANA service port finder" height="26rem">
  <source src="/tui/iana-service-port-finder.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/iana-service-port-finder.wasm
```

This finder contains 11,723 named rows with a port and transport protocol
from the [IANA service-name and port registry](https://www.iana.org/assignments/service-names-port-numbers),
updated 11 September 2026. It omits unassigned and reserved rows without a
service name. A registration does not identify the traffic on a live port.

### Top-level domains

Focus the list and type a domain such as `.dev`, a type such as `country-code`,
or a manager such as `Charleston Road`. Search also accepts Unicode labels such
as `中国`, while the list shows their ASCII (IDNA) form. Use Up and Down to select
a row, Enter for details, and Escape to clear the filter.

<qip-tui aria-label="Top-level domain finder" height="26rem">
  <source src="/tui/tld-finder.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/tld-finder.wasm
```

The finder contains 1,438 delegated domains from [IANA's root-zone list](https://data.iana.org/TLD/tlds-alpha-by-domain.txt),
with types and managers from the [root-zone database](https://www.iana.org/domains/root/db).
Both were captured on 24 September 2026 (list version `2026092400`). A delegated
domain is not necessarily open for public registration.

### Country finder

Focus the list and type to filter it. For example, try `aud`, `+61`, or `australia`.
Use Up and Down to select a row, Enter for details, and Escape to clear the filter.

<qip-tui aria-label="Country finder" height="26rem">
  <source src="/tui/country-finder.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/country-finder.wasm
```

The list contains 249 ISO alpha-2 entries from a [pinned country-code data snapshot](https://github.com/datasets/country-codes/tree/6a595f1a6f10b3d00175fe67375da88f64f7f76b).
Some calling prefixes include an area prefix, and some places list more than one currency.

### Emoji finder

Focus the list and type a name such as `woman technologist`, an emoji such as
`👩`, or a code point such as `1F469`. Use Up and Down to select a result.
Press Enter to see its code points. Press Tab to show combinations that contain
the selected emoji, then type a partner such as `laptop` or `medium skin tone`.
Select a result and press Tab again to extend it further. Escape returns to
the original search.

<qip-tui aria-label="Emoji finder" height="26rem">
  <source src="/tui/emoji-finder.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/emoji-finder.wasm
```

The finder contains 3,972 fully qualified emoji and emoji components from
[Unicode Emoji 18.0](https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt).
Combination results come from that list; the finder does not join arbitrary
emoji. The glyph you see depends on your system's emoji font. Newer sequences
can appear as separate symbols or missing characters on older systems. The
source data is distributed under the [Unicode License v3](https://www.unicode.org/license.txt).

### Time-zone converter

Focus the grid and type a city or IANA zone name, such as `melbourne` or `london`.
Left and Right change the UTC hour; Up and Down change the UTC day. Press Tab to
enter a UTC date and time as `YYYY-MM-DD HH:MM`. Page Up and Page Down browse
the zone list.

<qip-tui aria-label="Time-zone converter" height="26rem">
  <source src="/tui/time-zone-converter.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/time-zone-converter.wasm
```

The converter uses a fixed [IANA tzdb 2026d snapshot](https://www.iana.org/time-zones/releases/2026d)
for UTC dates from 2020 through 2037. It starts at a sample time, not the
current time. Entering UTC avoids an ambiguous local input during a daylight
saving change.

### Calendar

Focus the calendar and press Up or Down to move between months.

<qip-tui aria-label="Gregorian calendar" height="22rem">
  <source src="/tui/calendar-gregorian.wasm" type="application/wasm" />
</qip-tui>

```sh
npx qiptui qip.dev tui/calendar-gregorian.wasm
```

### Debugger

This demo loads `text/wc.wasm` with sample text. Focus the debugger and press
Space to run it, or `?` to see the keys. Use the [component debugger](/component-debugger)
to inspect a component of your choice. Run the terminal command from the
repository root so it can read `text/wc.wasm`.

<qip-tui id="tui-page-debugger" aria-label="Debugger demo" height="28rem"></qip-tui>
<p id="tui-page-debugger-status" role="status">Loading debugger sample…</p>

```sh
npx qiptui qip.dev -F 'input=Hello' -F component=@text/wc.wasm tui/qipdb.wasm
```

<script type="module">
import "/elements/qip-tui.js";

const debuggerTui = document.getElementById("tui-page-debugger");
const debuggerStatus = document.getElementById("tui-page-debugger-status");
const encoder = new TextEncoder();
const boundary = "uuid-00000000-0000-0000-0000-000000000000";

async function wasm(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

function debuggerInput(component) {
  const before = encoder.encode(
    `--${boundary}\r\nContent-Disposition: form-data; name="input"\r\n\r\nThe quick brown fox jumps over the lazy dog\r\n` +
    `--${boundary}\r\nContent-Disposition: form-data; name="component"; filename="wc.wasm"\r\n` +
    `Content-Type: application/wasm\r\n\r\n`
  );
  const after = encoder.encode(`\r\n--${boundary}--\r\n`);
  const input = new Uint8Array(before.length + component.length + after.length);
  input.set(before);
  input.set(component, before.length);
  input.set(after, before.length + component.length);
  return input;
}

try {
  const [debuggerBytes, componentBytes] = await Promise.all([
    wasm("/tui/qipdb.wasm"),
    wasm("/text/wc.wasm"),
  ]);
  await debuggerTui.load({
    moduleBytes: debuggerBytes,
    inputBytes: debuggerInput(componentBytes),
  });
  debuggerStatus.textContent = "Debugging text/wc.wasm with sample text. Focus the screen to use its keys.";
} catch (error) {
  debuggerStatus.textContent = `Could not load debugger demo: ${error.message}`;
  if (debuggerTui.screen) debuggerTui.screen.textContent = debuggerStatus.textContent;
}
</script>

## How they work

The component keeps its screen state and renders a complete UTF-8 text frame.
The browser element or `qiptui` host sends key events, supplies the screen size,
and redraws the frame. The host handles terminal mode and key decoding when
you run the component in a terminal. See the [TUI contract](/docs/tui-components)
for the input, key, timing, and ANSI rules.

## Why qiptui keeps input local

You can give a TUI a local file with `-i` or named fields with `-F`. This suits
logs, tokens, customer exports, and other data you do not want to upload to a
web tool. `qiptui` reads the files you name and passes their bytes to the Wasm
component in memory. It does not upload those input bytes to the component's
website.

[Simon Willison's lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)
describes the risk when a system combines private data, untrusted content, and
a way to send data out. His article concerns AI agents, but these three
capabilities are also a useful check for remotely downloaded software.
`qiptui` gives the Wasm component no way to make a network request.

Command arguments select the module URLs and paths, including Wasm paths in
`-F` fields. `qiptui` finishes those downloads before it starts reading
keyboard events. The payload bytes read from `-i` or `-F`, and later key events,
cannot change the download targets or trigger another download. This avoids the
kind of state-dependent network request that a CSS `background-image` URL can
make in a web page. Before copying input into the running Wasm instance's
memory, `qiptui` checks that it fits the declared input capacity and memory.
It rejects modules with imports, so the running component
has no file system, process, environment, or network API. It cannot open other
files, list processes, or send the input to a server. The host checks each
rendered frame before writing it to the terminal. A component cannot issue
arbitrary terminal commands.

The boundary applies to the Wasm component, not to the `qiptui` Node.js host.
The host reads the paths you supply and downloads hosted Wasm over HTTPS on each
run. The website can see that download request, and a publisher can change the
Wasm it serves. Use a local Wasm file when you need to inspect a fixed version
or run without contacting the component's website.

## What the sandbox rules out

A TUI cannot work like `ps` or `top`: it cannot inspect live processes. It also
cannot scan a directory, read an environment variable, or query an API on its
own. Give it a file or form field containing the data to inspect. For a live
system monitor or a tool that must discover files itself, use a host program
with those permissions. For browser-hosted graphical applications, browse the
[GUI components](/gui).
