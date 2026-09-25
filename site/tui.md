<title>QIP TUI components</title>

<style>
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

## Components

- [`calendar-gregorian.wasm`](/tui/calendar-gregorian.wasm) shows a Gregorian month. Up and Down move between months.
- [`qipdb.wasm`](/tui/qipdb.wasm) inspects and runs a supplied Wasm component. Pass the component and its input as multipart fields.

For example:

```sh
npx qiptui qip.dev tui/calendar-gregorian.wasm
npx qiptui qip.dev -F 'input=Hello' -F component=@text/wc.wasm tui/qipdb.wasm
```

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
