# Play Wasm From URL

Load a complete wasm module from the URL query and render it with `<qip-play>`.

- Query param: `?wasm=<base64-or-base64url>`
- This page converts it to `data:application/wasm;base64,...` and mounts `<qip-play>` dynamically.

More interactive pages:

- [Interactive index](/play)
- [Sudoku](/play-sudoku)
- [Liar's Dice](/play-liars-dice)

<template id="qip-play-runtime-trigger">
  <qip-play>
    <source src="/gui/sudoku.wasm" type="application/wasm" />
  </qip-play>
</template>

<form id="wasm-form" aria-labelledby="wasm-form-heading">
  <h3 id="wasm-form-heading">Wasm In Query</h3>
  <p><code>application/wasm → qip-play frame</code></p>

  <p>
    <label for="wasm-input">Base64 / Base64URL module bytes:</label>
  </p>
  <textarea id="wasm-input" rows="8" style="width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, monospace"></textarea>

  <p>
    <button type="button" id="load-query">Load from query</button>
    <button type="button" id="load-now">Render module</button>
    <button type="button" id="update-url">Update URL</button>
  </p>

  <p>
    <label for="data-uri-output">Data URI (<code>&lt;source src=...&gt;</code>):</label>
  </p>
  <textarea id="data-uri-output" rows="3" readonly style="width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, monospace"></textarea>

  <p id="status" role="status" aria-live="polite"></p>
</form>

<div id="play-host"></div>

<script type="module">
const wasmInput = document.getElementById("wasm-input");
const dataURIOutput = document.getElementById("data-uri-output");
const statusEl = document.getElementById("status");
const playHost = document.getElementById("play-host");

const btnLoadQuery = document.getElementById("load-query");
const btnLoadNow = document.getElementById("load-now");
const btnUpdateURL = document.getElementById("update-url");

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.style.color = isError ? "#b00020" : "inherit";
}

function normalizeBase64(raw) {
  let s = (raw || "").trim();
  if (s === "") {
    throw new Error("Missing base64 module bytes");
  }

  s = s.replace(/\s+/g, "");
  s = s.replace(/-/g, "+").replace(/_/g, "/");

  const rem = s.length % 4;
  if (rem === 2) s += "==";
  else if (rem === 3) s += "=";
  else if (rem === 1) throw new Error("Invalid base64 length");

  if (!/^[A-Za-z0-9+/=]+$/.test(s)) {
    throw new Error("Base64 contains invalid characters");
  }

  // Validate decode.
  atob(s);
  return s;
}

function toBase64URL(b64) {
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function toDataURI(b64) {
  return "data:application/wasm;base64," + b64;
}

function mountPlay(dataURI) {
  playHost.replaceChildren();

  const play = document.createElement("qip-play");
  play.setAttribute("log", "");

  const source = document.createElement("source");
  source.setAttribute("src", dataURI);
  source.setAttribute("type", "application/wasm");

  play.appendChild(source);
  playHost.appendChild(play);
}

function readQueryWasmRaw() {
  const p = new URLSearchParams(location.search);
  return p.get("wasm") || p.get("wasm_b64") || "";
}

function renderFromInput() {
  try {
    const b64 = normalizeBase64(wasmInput.value);
    const dataURI = toDataURI(b64);
    dataURIOutput.value = dataURI;
    mountPlay(dataURI);
    setStatus("Rendered module from query/input.");
    return b64;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    setStatus(message, true);
    throw err;
  }
}

function loadFromQuery() {
  const raw = readQueryWasmRaw();
  if (!raw) {
    setStatus("No ?wasm= query param found.", true);
    return;
  }
  wasmInput.value = raw;
  try {
    renderFromInput();
  } catch (_) {
    // status already set
  }
}

function updateURLFromInput() {
  try {
    const b64 = normalizeBase64(wasmInput.value);
    const b64url = toBase64URL(b64);
    const next = new URL(location.href);
    next.searchParams.set("wasm", b64url);
    history.replaceState(null, "", next.toString());
    setStatus("Updated URL query with ?wasm=... (base64url)");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    setStatus(message, true);
  }
}

btnLoadQuery.addEventListener("click", loadFromQuery);
btnLoadNow.addEventListener("click", () => {
  try {
    renderFromInput();
  } catch (_) {
    // status already set
  }
});
btnUpdateURL.addEventListener("click", updateURLFromInput);

if (readQueryWasmRaw()) {
  loadFromQuery();
} else {
  setStatus("Paste module base64 and click Render module, or open with ?wasm=...");
}
</script>
