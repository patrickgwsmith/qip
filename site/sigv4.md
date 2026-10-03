<title>AWS SigV4 request signer</title>

# AWS SigV4 request signer

Sign an HTTP request with AWS Signature Version 4 locally in your browser. The
<a href="/multipart/form-data/aws-sigv4-sign.wasm" download><qip-content-size src="/multipart/form-data/aws-sigv4-sign.wasm"></qip-content-size> QIP component</a>
outputs the headers to add to the request. It never sends the request, and your
keys never leave this page.

The form starts with the AWS SigV4 test suite's `get-vanilla` example, which
signs to `5fa00fa3…3fbf31`.

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 860px) {
  .tool-grid { grid-template-columns: 1fr 1fr; }
}
.tool-panel {
  display: grid;
  gap: 0.5rem;
  align-content: start;
}
.tool-panel label {
  display: grid;
  gap: 0.25rem;
}
.tool-panel input,
.tool-panel select,
.tool-panel textarea {
  box-sizing: border-box;
  width: 100%;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.tool-panel textarea {
  resize: vertical;
}
#sigv4-body {
  min-height: 5rem;
}
#sigv4-output {
  min-height: 12rem;
  background: rgba(127, 127, 127, 0.08);
}
.tool-hint {
  font-size: 0.9em;
  opacity: 0.75;
}
.tool-panel .tool-actions {
  margin: 0;
}
.tool-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5rem;
}
.tool-inline {
  display: flex;
  gap: 0.25rem;
}
.tool-inline input {
  flex: 1;
  min-width: 0;
}
.tool-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.tool-status {
  min-height: 1.5rem;
}
</style>

<div class="tool-grid">
  <div class="tool-panel">
    <strong>Request to sign</strong>
    <div class="tool-row">
      <label>Method
        <input id="sigv4-method" value="GET" spellcheck="false" autocapitalize="characters">
      </label>
      <label>Time (UTC)
        <span class="tool-inline">
          <input id="sigv4-time" type="datetime-local" step="1" value="2015-08-30T12:36:00">
          <button id="sigv4-now" type="button">Now</button>
        </span>
      </label>
    </div>
    <label>URL
      <input id="sigv4-url" value="https://example.amazonaws.com/" spellcheck="false">
    </label>
    <div class="tool-row">
      <label>Region
        <input id="sigv4-region" value="us-east-1" spellcheck="false">
      </label>
      <label>Service
        <input id="sigv4-service" value="service" spellcheck="false">
      </label>
    </div>
    <label>Access key ID
      <input id="sigv4-access-key-id" value="AKIDEXAMPLE" spellcheck="false" autocomplete="off">
    </label>
    <label>Secret access key
      <input id="sigv4-secret-access-key" type="password" value="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" spellcheck="false" autocomplete="off">
    </label>
    <label>Session token (optional)
      <input id="sigv4-session-token" spellcheck="false" autocomplete="off">
    </label>
    <label>Body (optional)
      <textarea id="sigv4-body" spellcheck="false"></textarea>
    </label>
  </div>
  <div class="tool-panel">
    <label for="sigv4-output"><strong>Output: signed headers</strong></label>
    <span class="tool-hint">Updates as you type. Add these headers to your HTTP request.</span>
    <textarea id="sigv4-output" spellcheck="false" readonly></textarea>
    <p class="tool-actions">
      <button id="sigv4-copy" type="button">Copy headers</button>
      <span id="sigv4-status" class="tool-status" role="status"></span>
    </p>
  </div>
</div>

<script type="module">
const fields = {
  method: document.getElementById("sigv4-method"),
  url: document.getElementById("sigv4-url"),
  region: document.getElementById("sigv4-region"),
  service: document.getElementById("sigv4-service"),
  access_key_id: document.getElementById("sigv4-access-key-id"),
  secret_access_key: document.getElementById("sigv4-secret-access-key"),
  session_token: document.getElementById("sigv4-session-token"),
  body: document.getElementById("sigv4-body"),
};
const optionalFields = new Set(["session_token", "body"]);
const timeInput = document.getElementById("sigv4-time");
const output = document.getElementById("sigv4-output");
const nowButton = document.getElementById("sigv4-now");
const copyButton = document.getElementById("sigv4-copy");
const status = document.getElementById("sigv4-status");
const typePrefix = "multipart/form-data;boundary=uuid-";
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const module = await WebAssembly.compileStreaming(fetch("/multipart/form-data/aws-sigv4-sign.wasm"));

function formBytes(uuid) {
  const boundary = "uuid-" + uuid;
  let body = "";
  for (const [name, input] of Object.entries(fields)) {
    if (optionalFields.has(name) && input.value === "") continue;
    body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + input.value + "\r\n";
  }
  return textEncoder.encode(body + "--" + boundary + "--\r\n");
}

function sign() {
  const time = Date.parse(timeInput.value + "Z");
  if (!Number.isFinite(time)) {
    output.value = "";
    status.textContent = "Enter a signing time.";
    return;
  }
  const { exports } = new WebAssembly.Instance(module, {});
  const uuid = crypto.randomUUID();
  new Uint8Array(exports.memory.buffer, exports.input_content_type_ptr() + typePrefix.length, 36)
    .set(textEncoder.encode(uuid));
  exports.uniform_set_timestamp(BigInt(Math.floor(time / 1000)));

  const input = formBytes(uuid);
  if (input.length > exports.input_bytes_cap()) {
    output.value = "";
    status.textContent = "Input is larger than the component's " + exports.input_bytes_cap() + " byte limit.";
    return;
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const bits = BigInt.asUintN(64, exports.render(input.length));
  if ((bits & (1n << 63n)) !== 0n) {
    output.value = "";
    status.textContent = "Rejected: check every required field, the URL's percent-escapes and its port.";
    return;
  }
  const length = Number(bits & 0xffff_ffffn);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  output.value = textDecoder.decode(new Uint8Array(exports.memory.buffer, pointer, length));
  status.textContent = "Signed " + fields.method.value + " " + fields.url.value;
}

nowButton.addEventListener("click", () => {
  timeInput.value = new Date().toISOString().slice(0, 19);
  sign();
});
copyButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(output.value);
  status.textContent = "Copied headers.";
});
for (const input of [...Object.values(fields), timeInput]) {
  input.addEventListener("input", sign);
}
sign();
</script>

AWS rejects signatures more than about 15 minutes from its own clock, so press
**Now** before signing a real request. A component can't read the
clock, so the same inputs always give the same signature.

The URL's path and query must already be percent-encoded. `+` is a literal
plus, so write spaces as `%20`. The `Host` header the request sends must match
the URL's host. For S3 services the signed headers include `X-Amz-Content-Sha256`;
other services only fold the body hash into the signature.

Not supported yet: presigned URLs, signing extra headers, and inferring the
region or service from the host.

## Download

- <a href="/multipart/form-data/aws-sigv4-sign.wasm" download>aws-sigv4-sign.wasm</a> — <qip-content-size src="/multipart/form-data/aws-sigv4-sign.wasm"></qip-content-size>

## CLI equivalent

```bash
qip run \
  -F method=GET \
  -F url='https://example.amazonaws.com/' \
  -F region=us-east-1 -F service=service \
  -F access_key_id=AKIDEXAMPLE \
  -F secret_access_key='wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' \
  multipart/form-data/aws-sigv4-sign.wasm -u timestamp=1440938160
```
