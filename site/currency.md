<title>Currency formatter</title>

# Currency formatter

Format a decimal amount with currency selected by its ISO 4217 numeric code. Runs locally in your browser via WebAssembly.

<style>
.currency-tool {
  display: grid;
  gap: 1rem;
  max-width: 42rem;
}
.currency-field {
  display: grid;
  gap: 0.5rem;
}
.currency-field input,
.currency-field select {
  box-sizing: border-box;
  width: 100%;
  font: inherit;
  font-variant-numeric: tabular-nums;
}
.currency-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.currency-status {
  min-height: 1.5rem;
}
</style>

<form class="currency-tool">
  <label class="currency-field">
    <strong>Decimal amount</strong>
    <input id="currency-input" value="1234567.895" inputmode="decimal" spellcheck="false" autocomplete="off">
  </label>
  <label class="currency-field">
    <strong>Locale</strong>
    <select id="currency-locale">
      <option value="en-us">en-US · Western grouping</option>
      <option value="en-in">en-IN · Indian grouping</option>
      <option value="es-es">es-ES · Spanish</option>
      <option value="de-de">de-DE · German</option>
      <option value="ar-eg">ar-EG · Arabic digits</option>
      <option value="fr-fr">fr-FR · French</option>
      <option value="pt-br">pt-BR · Brazilian Portuguese</option>
      <option value="ja-jp">ja-JP · Japanese</option>
      <option value="zh-cn">zh-CN · Simplified Chinese</option>
    </select>
  </label>
  <label class="currency-field">
    <strong>Currency</strong>
    <select id="currency-select">
      <option value="784">AED · 784</option>
      <option value="971">AFN · 971</option>
      <option value="8">ALL · 008</option>
      <option value="51">AMD · 051</option>
      <option value="973">AOA · 973</option>
      <option value="32">ARS · 032</option>
      <option value="36">AUD · 036</option>
      <option value="533">AWG · 533</option>
      <option value="944">AZN · 944</option>
      <option value="977">BAM · 977</option>
      <option value="52">BBD · 052</option>
      <option value="50">BDT · 050</option>
      <option value="48">BHD · 048</option>
      <option value="108">BIF · 108</option>
      <option value="60">BMD · 060</option>
      <option value="96">BND · 096</option>
      <option value="68">BOB · 068</option>
      <option value="986">BRL · 986</option>
      <option value="44">BSD · 044</option>
      <option value="64">BTN · 064</option>
      <option value="72">BWP · 072</option>
      <option value="933">BYN · 933</option>
      <option value="84">BZD · 084</option>
      <option value="124">CAD · 124</option>
      <option value="976">CDF · 976</option>
      <option value="756">CHF · 756</option>
      <option value="152">CLP · 152</option>
      <option value="156">CNY · 156</option>
      <option value="170">COP · 170</option>
      <option value="188">CRC · 188</option>
      <option value="192">CUP · 192</option>
      <option value="132">CVE · 132</option>
      <option value="203">CZK · 203</option>
      <option value="262">DJF · 262</option>
      <option value="208">DKK · 208</option>
      <option value="214">DOP · 214</option>
      <option value="12">DZD · 012</option>
      <option value="818">EGP · 818</option>
      <option value="232">ERN · 232</option>
      <option value="230">ETB · 230</option>
      <option value="978">EUR · 978</option>
      <option value="242">FJD · 242</option>
      <option value="238">FKP · 238</option>
      <option value="826">GBP · 826</option>
      <option value="981">GEL · 981</option>
      <option value="936">GHS · 936</option>
      <option value="292">GIP · 292</option>
      <option value="270">GMD · 270</option>
      <option value="324">GNF · 324</option>
      <option value="320">GTQ · 320</option>
      <option value="328">GYD · 328</option>
      <option value="344">HKD · 344</option>
      <option value="340">HNL · 340</option>
      <option value="332">HTG · 332</option>
      <option value="348">HUF · 348</option>
      <option value="360">IDR · 360</option>
      <option value="376">ILS · 376</option>
      <option value="356">INR · 356</option>
      <option value="368">IQD · 368</option>
      <option value="364">IRR · 364</option>
      <option value="352">ISK · 352</option>
      <option value="388">JMD · 388</option>
      <option value="400">JOD · 400</option>
      <option value="392">JPY · 392</option>
      <option value="404">KES · 404</option>
      <option value="417">KGS · 417</option>
      <option value="116">KHR · 116</option>
      <option value="174">KMF · 174</option>
      <option value="408">KPW · 408</option>
      <option value="410">KRW · 410</option>
      <option value="414">KWD · 414</option>
      <option value="136">KYD · 136</option>
      <option value="398">KZT · 398</option>
      <option value="418">LAK · 418</option>
      <option value="422">LBP · 422</option>
      <option value="144">LKR · 144</option>
      <option value="430">LRD · 430</option>
      <option value="426">LSL · 426</option>
      <option value="434">LYD · 434</option>
      <option value="504">MAD · 504</option>
      <option value="498">MDL · 498</option>
      <option value="969">MGA · 969</option>
      <option value="807">MKD · 807</option>
      <option value="104">MMK · 104</option>
      <option value="496">MNT · 496</option>
      <option value="446">MOP · 446</option>
      <option value="929">MRU · 929</option>
      <option value="480">MUR · 480</option>
      <option value="462">MVR · 462</option>
      <option value="454">MWK · 454</option>
      <option value="484">MXN · 484</option>
      <option value="458">MYR · 458</option>
      <option value="943">MZN · 943</option>
      <option value="516">NAD · 516</option>
      <option value="566">NGN · 566</option>
      <option value="558">NIO · 558</option>
      <option value="578">NOK · 578</option>
      <option value="524">NPR · 524</option>
      <option value="554">NZD · 554</option>
      <option value="512">OMR · 512</option>
      <option value="590">PAB · 590</option>
      <option value="604">PEN · 604</option>
      <option value="598">PGK · 598</option>
      <option value="608">PHP · 608</option>
      <option value="586">PKR · 586</option>
      <option value="985">PLN · 985</option>
      <option value="600">PYG · 600</option>
      <option value="634">QAR · 634</option>
      <option value="946">RON · 946</option>
      <option value="941">RSD · 941</option>
      <option value="643">RUB · 643</option>
      <option value="646">RWF · 646</option>
      <option value="682">SAR · 682</option>
      <option value="90">SBD · 090</option>
      <option value="690">SCR · 690</option>
      <option value="938">SDG · 938</option>
      <option value="752">SEK · 752</option>
      <option value="702">SGD · 702</option>
      <option value="654">SHP · 654</option>
      <option value="925">SLE · 925</option>
      <option value="706">SOS · 706</option>
      <option value="968">SRD · 968</option>
      <option value="728">SSP · 728</option>
      <option value="930">STN · 930</option>
      <option value="222">SVC · 222</option>
      <option value="760">SYP · 760</option>
      <option value="748">SZL · 748</option>
      <option value="764">THB · 764</option>
      <option value="972">TJS · 972</option>
      <option value="934">TMT · 934</option>
      <option value="788">TND · 788</option>
      <option value="776">TOP · 776</option>
      <option value="949">TRY · 949</option>
      <option value="780">TTD · 780</option>
      <option value="901">TWD · 901</option>
      <option value="834">TZS · 834</option>
      <option value="980">UAH · 980</option>
      <option value="800">UGX · 800</option>
      <option value="840" selected>USD · 840</option>
      <option value="858">UYU · 858</option>
      <option value="860">UZS · 860</option>
      <option value="926">VED · 926</option>
      <option value="928">VES · 928</option>
      <option value="704">VND · 704</option>
      <option value="548">VUV · 548</option>
      <option value="882">WST · 882</option>
      <option value="950">XAF · 950</option>
      <option value="951">XCD · 951</option>
      <option value="532">XCG · 532</option>
      <option value="960">XDR · 960</option>
      <option value="952">XOF · 952</option>
      <option value="953">XPF · 953</option>
      <option value="886">YER · 886</option>
      <option value="710">ZAR · 710</option>
      <option value="967">ZMW · 967</option>
      <option value="924">ZWG · 924</option>
    </select>
  </label>
  <div>
    <output id="currency-output" class="currency-output" for="currency-input" dir="auto"></output>
  </div>
  <div class="currency-actions">
    <button type="button" value="1234.5">Grouping</button>
    <button type="button" value="-9876543.21">Negative</button>
    <button type="button" value="0.005">Small fraction</button>
    <button type="button" value="999.995">Rounding carry</button>
    <span id="currency-status" class="currency-status" role="status"></span>
  </div>
</form>

<script type="module">
const input = document.getElementById("currency-input");
const locale = document.getElementById("currency-locale");
const currency = document.getElementById("currency-select");
const output = document.getElementById("currency-output");
const status = document.getElementById("currency-status");
const cliExample = document.querySelector("#currency-cli-example code");
const jsExample = document.querySelector("#currency-js-example code");
const cliExampleTemplate = cliExample.innerHTML;
const jsExampleTemplate = jsExample.innerHTML;
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const modules = new Map();
let formatVersion = 0;

function loadLocale(name) {
  if (!modules.has(name)) {
    modules.set(name, WebAssembly.instantiateStreaming(
      fetch(`/text/currency-format-${name}.wasm`),
    ).then(({ instance }) => instance.exports));
  }
  return modules.get(name);
}

const readI32 = (wasm, name) =>
  typeof wasm[name] === "function" ? wasm[name]() : wasm[name].value;

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\"'\"'")}'`;
}

function replaceExampleLiteral(html, literal, value) {
  const escaped = value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
  return html.replaceAll(literal, () => escaped);
}

function updateExamples(formatted) {
  const moduleName = `currency-format-${locale.value}.wasm`;
  const result = formatted ?? "";

  let cli = replaceExampleLiteral(cliExampleTemplate, "currency-format-en-us.wasm", moduleName);
  cli = replaceExampleLiteral(cli, "'1234567.895'", shellQuote(input.value));
  cli = replaceExampleLiteral(cli, "?currency=840", `?currency=${currency.value}`);
  cliExample.innerHTML = replaceExampleLiteral(cli, "$1,234,567.90", result);

  let js = replaceExampleLiteral(jsExampleTemplate, "currency-format-en-us.wasm", moduleName);
  js = replaceExampleLiteral(js, "1234567.895", JSON.stringify(input.value).slice(1, -1));
  js = replaceExampleLiteral(js, "840", currency.value);
  jsExample.innerHTML = replaceExampleLiteral(js, "$1,234,567.90", result);
}

async function formatAmount(value) {
  const wasm = await loadLocale(locale.value);
  const bytes = encoder.encode(value);
  const inputCapacity = readI32(wasm, "input_utf8_cap");
  if (bytes.length > inputCapacity) throw new Error("input exceeds component capacity");
  wasm.uniform_set_currency(Number(currency.value));
  new Uint8Array(wasm.memory.buffer, readI32(wasm, "input_ptr"), bytes.length).set(bytes);
  const outputLength = wasm.render(bytes.length);
  return decoder.decode(
    new Uint8Array(wasm.memory.buffer, readI32(wasm, "output_ptr"), outputLength),
  );
}

async function format() {
  const version = ++formatVersion;
  try {
    const formatted = await formatAmount(input.value);
    if (version !== formatVersion) return;
    output.value = formatted;
    status.textContent = "";
    updateExamples(formatted);
  } catch {
    if (version !== formatVersion) return;
    output.value = "";
    status.textContent = "Enter digits with an optional leading minus sign and decimal fraction.";
    updateExamples();
  }
}

for (const button of document.querySelectorAll('button[type="button"][value]')) {
  button.addEventListener("click", () => {
    input.value = button.value;
    format();
  });
}
input.addEventListener("input", format);
locale.addEventListener("change", format);
currency.addEventListener("change", format);
format();
</script>

## CLI

<section id="currency-cli-example">

```bash
go install github.com/royalicing/qip@latest
printf %s '1234567.895' | qip run currency-format-en-us.wasm -u currency=840
# $1,234,567.90
```

</section>

## JavaScript

<section id="currency-js-example">

<copy-code>

```js
const currencyFormatter = await WebAssembly.instantiateStreaming(
  fetch("/text/currency-format-en-us.wasm"),
);
const encoder = new TextEncoder(), decoder = new TextDecoder();

function formatCurrency(amount, currency) {
  const { memory, input_ptr, uniform_set_currency, render } = currencyFormatter.instance.exports;
  const input = encoder.encode(amount);
  uniform_set_currency(currency);
  new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(memory.buffer, outputPtr, outputSize));
}

console.log(formatCurrency("1234567.895", 840));
// $1,234,567.90
```

</copy-code>

</section>

The amount is ASCII decimal text, not a JavaScript `Number`, so the component performs decimal rounding without an intervening binary floating-point conversion.

## Download

- <a href="/text/currency-format-en-us.wasm" download>currency-format-en-US.wasm</a> — <qip-content-size src="/text/currency-format-en-us.wasm"></qip-content-size>
- <a href="/text/currency-format-en-in.wasm" download>currency-format-en-IN.wasm</a> — <qip-content-size src="/text/currency-format-en-in.wasm"></qip-content-size>
- <a href="/text/currency-format-es-es.wasm" download>currency-format-es-ES.wasm</a> — <qip-content-size src="/text/currency-format-es-es.wasm"></qip-content-size>
- <a href="/text/currency-format-de-de.wasm" download>currency-format-de-DE.wasm</a> — <qip-content-size src="/text/currency-format-de-de.wasm"></qip-content-size>
- <a href="/text/currency-format-ar-eg.wasm" download>currency-format-ar-EG.wasm</a> — <qip-content-size src="/text/currency-format-ar-eg.wasm"></qip-content-size>
- <a href="/text/currency-format-fr-fr.wasm" download>currency-format-fr-FR.wasm</a> — <qip-content-size src="/text/currency-format-fr-fr.wasm"></qip-content-size>
- <a href="/text/currency-format-pt-br.wasm" download>currency-format-pt-BR.wasm</a> — <qip-content-size src="/text/currency-format-pt-br.wasm"></qip-content-size>
- <a href="/text/currency-format-ja-jp.wasm" download>currency-format-ja-JP.wasm</a> — <qip-content-size src="/text/currency-format-ja-jp.wasm"></qip-content-size>
- <a href="/text/currency-format-zh-cn.wasm" download>currency-format-zh-CN.wasm</a> — <qip-content-size src="/text/currency-format-zh-cn.wasm"></qip-content-size>
- <a href="/text/iso-4217-alpha-to-numeric.wasm" download>iso-4217-alpha-to-numeric.wasm</a> — <qip-content-size src="/text/iso-4217-alpha-to-numeric.wasm"></qip-content-size>

## Details

Each `currency-format-<locale>.wasm` keeps its locale and formatting data fixed while the integer uniform selects one of 155 current country currencies plus XDR. Metals, testing, no-currency, fund, accounting-unit, and indexed-unit codes remain outside their scope. Components range from 2.2 to 2.6 KiB and have no dependency on the browser, operating system locale, or host ICU version.

Amounts are ASCII decimals matching `-?[0-9]+(\.[0-9]+)?`, avoiding JavaScript floating-point conversion. Each module applies its locale's grouping and the currency's ISO minor units. Invalid input and unsupported codes trap. The page loads locale modules on demand.

Each locale has an independent `compliance/currency-format-<locale>.comply.wasm` executable specification. Every supported currency is dueled against JavaScript [`Intl.NumberFormat`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/NumberFormat), including locale-specific grouping thresholds, separators, affix placement, Arabic-Indic digits, bidi markers, zero- and three-digit currencies, negative zero, rounding carries, and generated decimal inputs.

## Convert alphabetic codes

The companion component converts all 178 current ISO 4217 alphabetic codes to three-digit ASCII numeric codes. It keeps leading zeroes, which are significant in the standard representation:

```bash
echo -n AUD | qip run iso-4217-alpha-to-numeric.wasm
# 036

echo -n BHD | qip run iso-4217-alpha-to-numeric.wasm
# 048
```

Input is exactly three uppercase ASCII letters. Unknown, lowercase, or malformed codes trap. Its compliance component exhaustively declares all 178 mappings from the SIX Group ISO 4217 List One published 2026-01-01, plus rejection cases.

This component is intentionally narrower than [`Intl.NumberFormat`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/NumberFormat). It does not accept exponent notation, `NaN`, infinity, signs other than a leading minus, configurable fraction digits, or runtime locale selection. Use host `Intl` when differing platform behavior is acceptable and you need its full range of options.
