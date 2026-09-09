import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createHighlighter } from "shiki";

const directory = fileURLToPath(new URL(".", import.meta.url));
const componentPath = fileURLToPath(new URL(
  "../../components/text/javascript/javascript-to-syntax-highlight-html.wasm",
  import.meta.url,
));
const categories = [
  "plain",
  "comment",
  "string",
  "number",
  "keyword",
  "type",
  "function",
  "constant",
  "operator",
];

const arguments_ = process.argv.slice(2);
const json = arguments_.includes("--json");
const selectedNames = arguments_.filter((argument) => argument !== "--json");
const manifest = JSON.parse(await readFile(`${directory}/fixtures.json`, "utf8"));
const fixtures = selectedNames.length === 0
  ? manifest
  : selectedNames.map((name) => {
      const fixture = manifest.find((candidate) => candidate.name === name);
      if (!fixture) throw new Error(`unknown fixture: ${name}`);
      return fixture;
    });

function emptyCounts() {
  return Object.fromEntries(categories.map((category) => [category, 0]));
}

function emptyConfusion() {
  return Object.fromEntries(categories.map((expected) => [expected, emptyCounts()]));
}

function decodeHtml(text) {
  return text
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

function qipLabelsFromHtml(html, source) {
  const labels = [];
  const previous = [];
  let current = "plain";
  let rebuilt = "";
  const parts = html.split(/(<span class="syntax-[a-z]+">|<\/span>)/);

  for (const part of parts) {
    const open = /^<span class="syntax-([a-z]+)">$/.exec(part);
    if (open) {
      if (!categories.includes(open[1])) throw new Error(`unknown QIP class: ${open[1]}`);
      previous.push(current);
      current = open[1];
    } else if (part === "</span>") {
      if (previous.length === 0) throw new Error("QIP HTML has an unmatched closing span");
      current = previous.pop();
    } else if (part) {
      const decoded = decodeHtml(part);
      rebuilt += decoded;
      for (let index = 0; index < decoded.length; index += 1) labels.push(current);
    }
  }

  if (previous.length !== 0) throw new Error("QIP HTML has an unclosed span");
  if (rebuilt !== source) throw new Error("QIP HTML does not reproduce the source");
  return labels;
}

function shikiClass(scopes) {
  if (scopes.some((scope) => scope.startsWith("comment") || scope.includes(".comment"))) {
    return "comment";
  }
  if (scopes.some((scope) => scope.startsWith("string") || scope.includes("regexp"))) {
    return "string";
  }
  if (scopes.some((scope) => scope.startsWith("constant.numeric"))) return "number";
  if (scopes.some((scope) => scope.startsWith("keyword.operator"))) return "operator";
  if (scopes.some((scope) =>
    scope.startsWith("entity.name.function") || scope.startsWith("support.function"))) {
    return "function";
  }
  if (scopes.some((scope) =>
    /^(entity\.name\.(type|class|interface|enum)|support\.(type|class))/.test(scope))) {
    return "type";
  }
  if (scopes.some((scope) =>
    /^(constant\.language|entity\.name\.constant|variable\.language)/.test(scope))) {
    return "constant";
  }
  if (scopes.some((scope) => scope.startsWith("keyword") || scope.startsWith("storage"))) {
    return "keyword";
  }
  return "plain";
}

function shikiLabelsFromTokens(tokens, source) {
  const labels = Array(source.length).fill("plain");
  for (const token of tokens.flat()) {
    let offset = token.offset;
    const explanations = token.explanation ?? [{ content: token.content, scopes: [] }];
    for (const explanation of explanations) {
      const content = explanation.content;
      if (source.slice(offset, offset + content.length) !== content) {
        throw new Error(`Shiki token does not match the source at offset ${offset}`);
      }
      const label = shikiClass(explanation.scopes.map((scope) => scope.scopeName));
      labels.fill(label, offset, offset + content.length);
      offset += content.length;
    }
  }
  return labels;
}

async function renderQip(wasm, source) {
  const { instance } = await WebAssembly.instantiate(wasm);
  const exports = instance.exports;
  const input = new TextEncoder().encode(source);
  if (input.length > exports.input_utf8_cap()) throw new Error("fixture exceeds QIP input capacity");
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const packed = BigInt.asUintN(64, exports.render(input.length));
  if ((packed & (1n << 63n)) !== 0n) throw new Error("QIP rejected the fixture");
  const outputLength = Number(packed & 0xffff_ffffn);
  const outputPointer = Number((packed >> 32n) & 0x7fff_ffffn);
  return new TextDecoder("utf8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, outputPointer, outputLength),
  );
}

function score(source, expected, actual) {
  const confusion = emptyConfusion();
  let compared = 0;
  let matched = 0;
  for (let index = 0; index < source.length; index += 1) {
    if (/\s/u.test(source[index])) continue;
    compared += 1;
    if (expected[index] === actual[index]) matched += 1;
    confusion[expected[index]][actual[index]] += 1;
  }

  const classes = Object.fromEntries(categories.map((category) => {
    const truePositive = confusion[category][category];
    const expectedCount = Object.values(confusion[category]).reduce((sum, value) => sum + value, 0);
    const actualCount = categories.reduce((sum, expectedClass) =>
      sum + confusion[expectedClass][category], 0);
    return [category, {
      expected_characters: expectedCount,
      actual_characters: actualCount,
      precision_percent: actualCount === 0 ? null : 100 * truePositive / actualCount,
      recall_percent: expectedCount === 0 ? null : 100 * truePositive / expectedCount,
    }];
  }));

  const mismatchGroups = new Map();
  const tokenPattern = /[A-Za-z_$][A-Za-z0-9_$]*|===|!==|>>>|<<=|>>=|\*\*|&&|\|\||\?\?|=>|==|!=|<=|>=|\+\+|--|<<|>>|[+\-*\/%<>=!&|^~?:]/g;
  for (const match of source.matchAll(tokenPattern)) {
    const offset = match.index;
    const expectedClass = expected[offset];
    const actualClass = actual[offset];
    if (expectedClass === actualClass) continue;
    const key = `${expectedClass}\u0000${actualClass}\u0000${match[0]}`;
    let group = mismatchGroups.get(key);
    if (!group) {
      group = {
        expected: expectedClass,
        actual: actualClass,
        token: match[0],
        count: 0,
        examples: [],
      };
      mismatchGroups.set(key, group);
    }
    group.count += 1;
    if (group.examples.length < 3) {
      const start = Math.max(0, offset - 30);
      const end = Math.min(source.length, offset + match[0].length + 30);
      group.examples.push(source.slice(start, end).replaceAll("\n", "\\n"));
    }
  }

  return {
    compared_characters: compared,
    matched_characters: matched,
    agreement_percent: 100 * matched / compared,
    classes,
    confusion,
    common_mismatches: [...mismatchGroups.values()]
      .sort((left, right) => right.count - left.count)
      .slice(0, 30),
  };
}

const wasm = await readFile(componentPath);
const highlighter = await createHighlighter({
  langs: ["javascript"],
  themes: ["github-dark"],
});
const results = [];

for (const fixture of fixtures) {
  const response = await fetch(fixture.url);
  if (!response.ok) throw new Error(`${fixture.name} returned HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length !== fixture.bytes) {
    throw new Error(`${fixture.name} byte length changed: ${bytes.length}`);
  }
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (digest !== fixture.sha256) throw new Error(`${fixture.name} SHA-256 changed`);
  const source = new TextDecoder("utf8", { fatal: true }).decode(bytes);
  const html = await renderQip(wasm, source);
  const actual = qipLabelsFromHtml(html, source);
  const shiki = highlighter.codeToTokens(source, {
    lang: "javascript",
    theme: "github-dark",
    includeExplanation: true,
  });
  const expected = shikiLabelsFromTokens(shiki.tokens, source);
  results.push({
    name: fixture.name,
    source_bytes: bytes.length,
    source_characters: source.length,
    output_bytes: Buffer.byteLength(html),
    ...score(source, expected, actual),
  });
}

highlighter.dispose();

if (json) {
  console.log(JSON.stringify({ shiki_version: "4.4.3", results }, null, 2));
} else {
  console.table(results.map((result) => ({
    fixture: result.name,
    bytes: result.source_bytes,
    compared: result.compared_characters,
    agreement: `${result.agreement_percent.toFixed(2)}%`,
  })));
}
