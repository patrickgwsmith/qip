<title>DNS over HTTPS lookup</title>

# DNS over HTTPS lookup

Type a name and a record type. A QIP component encodes the question as an RFC 1035 DNS message, your browser sends it to a public resolver over RFC 8484 DNS over HTTPS (DoH), and a second component decodes the reply into the text layout that `dig` prints.

**Network tool:** When you press **Look up**, your browser sends the name, record type, and DNSSEC setting as a DNS query in the displayed request URL to the selected resolver, Cloudflare or Google. The resolver receives the query and the request's source IP address. Editing the form and using **Decode a message** do not send your input to a resolver.

<style>
.dns-form {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: end;
}
.dns-form label {
  display: inline-grid;
  gap: 0.25rem;
}
.dns-form label[hidden] {
  display: none;
}
.dns-form input[type="text"],
.dns-form select {
  font: inherit;
}
.dns-form #dns-name {
  width: 18em;
}
.dns-form .dns-check {
  display: inline-flex;
  gap: 0.35rem;
  align-items: center;
}
.dns-status {
  min-height: 1.5rem;
}
.dns-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 860px) {
  .dns-grid { grid-template-columns: minmax(0, 1fr) minmax(0, 2fr); }
}
.dns-panel {
  display: grid;
  gap: 0.5rem;
  align-content: start;
  min-width: 0;
}
.dns-panel pre,
.dns-panel textarea {
  box-sizing: border-box;
  width: 100%;
  margin: 0;
  padding: 0.5rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
}
.dns-panel pre {
  min-height: 4rem;
  overflow-x: auto;
}
.dns-panel .dns-hex {
  white-space: pre-wrap;
  word-break: break-all;
}
.dns-panel textarea {
  min-height: 8rem;
  resize: vertical;
}
.dns-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
</style>

<form id="dns-form" class="dns-form">
  <label>
    Name
    <input id="dns-name" type="text" value="cloudflare.com" spellcheck="false" autocapitalize="off" autocomplete="off" required />
  </label>
  <label>
    Type
    <select id="dns-type">
      <optgroup label="Common">
        <option>A</option>
        <option>AAAA</option>
        <option>CNAME</option>
        <option>MX</option>
        <option>TXT</option>
        <option>NS</option>
        <option>SOA</option>
        <option>CAA</option>
        <option selected>HTTPS</option>
        <option>SVCB</option>
        <option>SRV</option>
        <option>PTR</option>
      </optgroup>
      <optgroup label="DNSSEC">
        <option>DNSKEY</option>
        <option>DS</option>
        <option>RRSIG</option>
        <option>NSEC</option>
        <option>NSEC3</option>
        <option>NSEC3PARAM</option>
        <option>CDS</option>
        <option>CDNSKEY</option>
      </optgroup>
      <optgroup label="Keys and certificates">
        <option>TLSA</option>
        <option>SMIMEA</option>
        <option>SSHFP</option>
        <option>OPENPGPKEY</option>
        <option>CERT</option>
        <option>IPSECKEY</option>
      </optgroup>
      <optgroup label="Less common">
        <option>NAPTR</option>
        <option>URI</option>
        <option>DNAME</option>
        <option>ZONEMD</option>
        <option>CSYNC</option>
        <option>LOC</option>
        <option>HINFO</option>
        <option>RP</option>
        <option>AFSDB</option>
        <option>APL</option>
        <option>DHCID</option>
        <option>HIP</option>
        <option>KX</option>
        <option>SPF</option>
        <option>EUI48</option>
        <option>EUI64</option>
        <option>NULL</option>
        <option>KEY</option>
        <option>SIG</option>
        <option>ANY</option>
      </optgroup>
      <option value="other">Other…</option>
    </select>
  </label>
  <label id="dns-other-type-label" hidden>
    Other type
    <input id="dns-other-type" type="text" placeholder="TYPE65" spellcheck="false" autocapitalize="off" autocomplete="off" />
  </label>
  <label>
    Resolver
    <select id="dns-provider">
      <option value="https://cloudflare-dns.com/dns-query">Cloudflare (cloudflare-dns.com)</option>
      <option value="https://dns.google/dns-query">Google (dns.google)</option>
    </select>
  </label>
  <label class="dns-check">
    <input id="dns-dnssec" type="checkbox" checked />
    DNSSEC records
  </label>
  <button type="submit">Look up</button>
</form>

<p id="dns-status" class="dns-status" role="status"></p>

<div class="dns-grid">
  <div class="dns-panel">
    <strong>Request URL</strong>
    <pre id="dns-url" class="dns-hex"></pre>
    <strong>Query message (<span id="dns-query-size">0</span> bytes)</strong>
    <pre id="dns-query-hex" class="dns-hex"></pre>
    <strong>Response message (<span id="dns-response-size">0</span> bytes)</strong>
    <pre id="dns-response-hex" class="dns-hex"></pre>
  </div>
  <div class="dns-panel">
    <strong>Decoded response</strong>
    <pre id="dns-output" aria-live="polite"></pre>
  </div>
</div>

## Decode a message

Paste a DNS message as hex or as base64url, such as the `dns` parameter of a DoH GET URL. Nothing is sent.

<div class="dns-panel">
  <label class="dns-panel">
    <strong>Message</strong>
    <textarea id="dns-paste" spellcheck="false">AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB</textarea>
  </label>
  <p class="dns-actions">
    <button id="dns-decode" type="button">Decode</button>
    <span id="dns-decode-status" class="dns-status" role="status"></span>
  </p>
  <pre id="dns-decode-output"></pre>
</div>

<script type="module">
const form = document.getElementById("dns-form");
const nameInput = document.getElementById("dns-name");
const typeSelect = document.getElementById("dns-type");
const otherTypeLabel = document.getElementById("dns-other-type-label");
const otherTypeInput = document.getElementById("dns-other-type");
const providerSelect = document.getElementById("dns-provider");
const dnssecInput = document.getElementById("dns-dnssec");
const status = document.getElementById("dns-status");
const urlOutput = document.getElementById("dns-url");
const queryHex = document.getElementById("dns-query-hex");
const querySize = document.getElementById("dns-query-size");
const responseHex = document.getElementById("dns-response-hex");
const responseSize = document.getElementById("dns-response-size");
const output = document.getElementById("dns-output");
const pasteInput = document.getElementById("dns-paste");
const decodeButton = document.getElementById("dns-decode");
const decodeStatus = document.getElementById("dns-decode-status");
const decodeOutput = document.getElementById("dns-decode-output");
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const [queryModule, textModule] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/application/dns-message/dns-query-to-dns-message.wasm")),
  WebAssembly.compileStreaming(fetch("/application/dns-message/dns-message-to-text.wasm")),
]);
// The decoder reserves about 32 MiB, so the page keeps one instance.
const textExports = new WebAssembly.Instance(textModule, {}).exports;

// Copies input into the component, runs render, and returns the output bytes,
// or throws with the byte offset the component rejected.
function run(exports, input, cap) {
  if (input.length > cap) {
    throw Error("Input is larger than the component's " + cap + " byte limit.");
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const bits = BigInt.asUintN(64, exports.render(input.length));
  const size = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    throw Error("Rejected at byte offset " + size + ".");
  }
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  return new Uint8Array(exports.memory.buffer, pointer, size).slice();
}

function encodeQuery(question, dnssecOK) {
  const { exports } = new WebAssembly.Instance(queryModule, {});
  exports.uniform_set_dnssec_ok(dnssecOK ? 1 : 0);
  return run(exports, textEncoder.encode(question), exports.input_utf8_cap());
}

function decodeMessage(bytes) {
  return textDecoder.decode(run(textExports, bytes, textExports.input_bytes_cap()));
}

function toHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(" ");
}

function toBase64URL(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromPasted(text) {
  const trimmed = text.trim();
  const hex = trimmed.replace(/0x|[\s:,]/gi, "");
  // Unseparated hex is also valid base64, so any even run of hex digits is
  // read as hex. Real base64url messages almost always contain other letters.
  if (hex.length > 0 && hex.length % 2 === 0 && /^[0-9a-f]+$/i.test(hex)) {
    return Uint8Array.from(hex.match(/../g), (pair) => Number.parseInt(pair, 16));
  }
  const base64 = trimmed.replace(/^.*[?&]dns=/, "").replace(/&.*$/, "").replaceAll("-", "+").replaceAll("_", "/");
  try {
    const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
  } catch {
    throw Error("Enter hex bytes or base64url.");
  }
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

let lookupCount = 0;
let requestURL = null;
let shownResponseURL = null;

function clearResponse() {
  responseHex.textContent = "";
  responseSize.textContent = "0";
  output.textContent = "";
  shownResponseURL = null;
}

// Encodes the form into a query and shows the request URL and query bytes.
// A response from a different request is cleared so the panels always match.
function updateRequest() {
  const name = nameInput.value.trim();
  const otherType = typeSelect.value === "other";
  otherTypeLabel.hidden = !otherType;
  otherTypeInput.required = otherType;
  const recordType = otherType ? otherTypeInput.value.trim() : typeSelect.value;
  const question = name + " " + recordType;
  requestURL = null;
  urlOutput.textContent = "";
  queryHex.textContent = "";
  querySize.textContent = "0";
  // The encoder reads a lone "HTTPS" as a name with type A, so an empty name
  // must not reach it.
  if (name === "") {
    status.textContent = "Enter a name to look up.";
  } else if (recordType === "") {
    status.textContent = "Enter a record type, such as TYPE65.";
  } else try {
    const query = encodeQuery(question, dnssecInput.checked);
    // RFC 8484 GET has no request headers to preflight, and HTTP caches can
    // share it because the message ID is 0.
    requestURL = providerSelect.value + "?dns=" + toBase64URL(query);
    urlOutput.textContent = requestURL;
    queryHex.textContent = toHex(query);
    querySize.textContent = String(query.length);
    if (shownResponseURL !== requestURL) status.textContent = "";
  } catch (error) {
    status.textContent = "Could not encode “" + question + "”: " + errorMessage(error);
  }
  if (shownResponseURL !== requestURL) clearResponse();
}

async function lookup() {
  const lookupID = ++lookupCount;
  updateRequest();
  const url = requestURL;
  if (url === null) return;
  clearResponse();
  status.textContent = "Asking " + new URL(url).host + "…";

  let response;
  let elapsed;
  try {
    // Timed from the request to the last response byte, so it includes DNS,
    // the TLS handshake on a first lookup, and any HTTP cache hit.
    const start = performance.now();
    const res = await fetch(url);
    if (!res.ok) throw Error("HTTP " + res.status);
    response = new Uint8Array(await res.arrayBuffer());
    elapsed = performance.now() - start;
  } catch (error) {
    if (lookupID !== lookupCount || url !== requestURL) return;
    status.textContent = "Request failed: " + errorMessage(error);
    return;
  }
  if (lookupID !== lookupCount || url !== requestURL) return;
  shownResponseURL = url;
  responseHex.textContent = toHex(response);
  responseSize.textContent = String(response.length);
  try {
    output.textContent = decodeMessage(response);
    status.textContent = "Answered by " + new URL(url).host + " in " + Math.round(elapsed) + " ms.";
  } catch (error) {
    status.textContent = "Could not decode the response: " + errorMessage(error);
  }
}

function decodePasted() {
  decodeOutput.textContent = "";
  try {
    const bytes = fromPasted(pasteInput.value);
    decodeOutput.textContent = decodeMessage(bytes);
    decodeStatus.textContent = "Decoded " + bytes.length + " bytes.";
  } catch (error) {
    decodeStatus.textContent = errorMessage(error);
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  lookup();
});
form.addEventListener("input", updateRequest);
form.addEventListener("change", updateRequest);
decodeButton.addEventListener("click", decodePasted);

updateRequest();
decodePasted();
</script>

## How it works

- [`dns-query-to-dns-message.wasm`](/application/dns-message/dns-query-to-dns-message.wasm) turns `cloudflare.com HTTPS` into a query message. The message ID is 0, as RFC 8484 recommends, so identical queries share one HTTP cache entry. **DNSSEC records** sets the EDNS DO flag.
- The page sends the query with an RFC 8484 GET, putting the message in the `dns` parameter as base64url. Both resolvers allow cross-origin GET requests. Google rejects the CORS preflight that a POST with `content-type: application/dns-message` needs, so the page doesn't use POST.
- [`dns-message-to-text.wasm`](/application/dns-message/dns-message-to-text.wasm) decodes the reply, including EDNS options such as Extended DNS Errors. It rejects a malformed message with the byte offset of the problem.

The same components work in a terminal:

```bash
printf 'cloudflare.com HTTPS' |
  qip run application/dns-message/dns-query-to-dns-message.wasm -u dnssec_ok=1 |
  curl -s --header 'content-type: application/dns-message' --data-binary @- https://cloudflare-dns.com/dns-query |
  qip run application/dns-message/dns-message-to-text.wasm
```

Cloudflare and Google each publish their own privacy policy for their public resolvers.
