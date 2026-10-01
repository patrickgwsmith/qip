<title>Find a component recipe</title>
<link rel="modulepreload" href="/elements/lib/recipe-finder.js">

# Find a component recipe

Choose the type of content you have and the content type you want made.

<style>
.pipeline-form {
  display: grid;
  gap: 1rem;
  margin-block: 1.5rem;
}

@media (min-width: 700px) {
  .pipeline-form {
    grid-template-columns: 1fr auto 1fr 1fr;
    align-items: end;
  }
}

.pipeline-form label {
  display: grid;
  gap: 0.35rem;
}

.pipeline-form select {
  box-sizing: border-box;
  width: 100%;
}

.pipeline-arrow {
  display: none;
  padding-block-end: 0.5rem;
  font-size: 1.5rem;
}

@media (min-width: 700px) {
  .pipeline-arrow { display: block; }
}

.pipeline-results {
  padding: 0;
  list-style: none;
  counter-reset: pipeline;
}

.pipeline-result {
  counter-increment: pipeline;
  padding-block: 1rem;
  border-top: 1px solid currentColor;
}

.pipeline-result h2 {
  margin-block: 0 0.5rem;
  font-size: 1rem;
}

.pipeline-result h2::before {
  content: counter(pipeline) ". ";
}

.pipeline-steps {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  align-items: center;
  margin-block: 0.5rem;
}

.pipeline-steps code {
  overflow-wrap: anywhere;
}

.pipeline-command {
  position: relative;
}

.pipeline-command pre {
  margin-bottom: 0;
}

.pipeline-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  justify-content: end;
  margin-top: 0.5rem;
}
</style>

<form class="pipeline-form" id="pipeline-form">
  <label>
    <strong>Input content type</strong>
    <select id="pipeline-input" name="from" aria-describedby="pipeline-status"></select>
  </label>
  <span class="pipeline-arrow" aria-hidden="true">→</span>
  <label>
    <strong>Output content type</strong>
    <select id="pipeline-output" name="to" aria-describedby="pipeline-status"></select>
  </label>
  <label>
    <strong>Prefer</strong>
    <select id="pipeline-preference" name="preference" aria-describedby="pipeline-status">
      <option value="balanced" selected>Balanced results</option>
      <option value="quality">Lossless and high fidelity</option>
      <option value="smallest">Smallest likely output</option>
      <option value="fastest">Fewest and fastest stages</option>
    </select>
  </label>
</form>

<p id="pipeline-status" role="status">Loading the component catalog…</p>
<ol id="pipeline-results" class="pipeline-results"></ol>

<script type="module">
import { findRankedRecipes, mediaTypeOf, outputRole, PREFERENCES, reachableOutputMimes } from "/elements/lib/recipe-finder.js";

const CATALOG_URL = "/data/component-catalog.csv";
const GENERATOR_URL = "/text/csv/content-recipe-to-browser-javascript.wasm";
const CATALOG_HEADER = "path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes";

const MIME_LABELS = {
  "application/json": "JSON",
  "application/octet-stream": "Binary data",
  "application/pdf": "PDF",
  "application/vnd.sqlite3": "SQLite database",
  "application/warc": "WARC web archive",
  "application/wasm": "WebAssembly module",
  "application/x-www-form-urlencoded": "URL-encoded form",
  "application/x-tar": "TAR archive",
  "application/xml": "XML",
  "application/zip": "ZIP archive",
  "font/ttf": "TrueType font",
  "multipart/form-data": "Multipart form data",
  "image/avif": "AVIF image",
  "image/bmp": "BMP image",
  "image/jp2": "JPEG 2000 image",
  "image/jpeg": "JPEG image",
  "image/ktx2": "KTX2 working image",
  "image/png": "PNG image",
  "image/svg+xml": "SVG image",
  "image/webp": "WebP image",
  "image/x-icon": "ICO image",
  "text/csv": "CSV",
  "text/html": "HTML",
  "text/javascript": "JavaScript",
  "text/markdown": "Markdown",
  "text/plain": "Plain text",
  "text/uri-list": "URI list",
  "text/vnd.mermaid": "Mermaid diagram",
  "text/x-c": "C source",
};

const FILE_EXTENSIONS = {
  "application/json": "json",
  "application/pdf": "pdf",
  "application/vnd.sqlite3": "sqlite",
  "application/warc": "warc",
  "application/wasm": "wasm",
  "application/x-www-form-urlencoded": "form",
  "application/x-tar": "tar",
  "application/xml": "xml",
  "application/zip": "zip",
  "multipart/form-data": "multipart",
  "image/avif": "avif",
  "image/bmp": "bmp",
  "image/jp2": "jp2",
  "image/jpeg": "jpg",
  "image/ktx2": "ktx2",
  "image/png": "png",
  "image/svg+xml": "svg",
  "image/webp": "webp",
  "image/x-icon": "ico",
  "text/csv": "csv",
  "text/html": "html",
  "text/javascript": "js",
  "text/markdown": "md",
  "text/plain": "txt",
  "text/uri-list": "txt",
  "text/vnd.mermaid": "mmd",
  "text/x-c": "c",
};

const form = document.getElementById("pipeline-form");
const inputSelect = document.getElementById("pipeline-input");
const outputSelect = document.getElementById("pipeline-output");
const preferenceSelect = document.getElementById("pipeline-preference");
const status = document.getElementById("pipeline-status");
const resultsElement = document.getElementById("pipeline-results");

function labelFor(mime) {
  return MIME_LABELS[mime] ?? mime;
}

function parseCSV(csv) {
  if (!csv.endsWith("\n") || csv.includes("\r")) throw new Error("CSV must use LF lines and end with a newline.");
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  let closedQuote = false;
  for (let index = 0; index < csv.length; index += 1) {
    const character = csv[index];
    if (quoted) {
      if (character !== '"') {
        if (character === "\n") throw new Error("CSV fields must not contain newlines.");
        field += character;
      } else if (csv[index + 1] === '"') {
        field += '"';
        index += 1;
      } else {
        quoted = false;
        closedQuote = true;
      }
      continue;
    }
    if (closedQuote && character !== "," && character !== "\n") throw new Error("Invalid character after a quoted CSV field.");
    if (character === '"') {
      if (field.length !== 0 || closedQuote) throw new Error("Invalid quote in CSV field.");
      quoted = true;
    } else if (character === "," || character === "\n") {
      row.push(field);
      field = "";
      closedQuote = false;
      if (character === "\n") {
        rows.push(row);
        row = [];
      }
    } else {
      field += character;
    }
  }
  if (quoted || row.length !== 0 || field.length !== 0) throw new Error("Invalid final CSV row.");
  return rows;
}

function parseCatalog(csv) {
  const rows = parseCSV(csv);
  if (rows.shift()?.join(",") !== CATALOG_HEADER) throw new Error("The component catalog has an unexpected header.");
  return rows.map((fields, index) => {
    if (fields.length !== 7 || fields.some((field) => field.length === 0)) {
      throw new Error(`Invalid component catalog row ${index + 2}.`);
    }
    const [path, inputEncoding, inputMime, inputCapacityText, outputEncoding, outputMime, outputCapacityText] = fields;
    if (![inputEncoding, outputEncoding].every((encoding) => encoding === "utf8" || encoding === "bytes")) {
      throw new Error(`Invalid component catalog encoding on row ${index + 2}.`);
    }
    if (![inputCapacityText, outputCapacityText].every((capacity) => /^(0|[1-9][0-9]*)$/.test(capacity))) {
      throw new Error(`Invalid component catalog capacity on row ${index + 2}.`);
    }
    const inputCapacity = Number(inputCapacityText);
    const outputCapacity = Number(outputCapacityText);
    if (![inputCapacity, outputCapacity].every((capacity) => Number.isSafeInteger(capacity) && capacity <= 0xffffffff)) {
      throw new Error(`Component catalog capacity exceeds uint32 on row ${index + 2}.`);
    }
    // The catalog stores declared content types, parameters included; pages match and
    // label by media type while the finder reads the parameters for KTX2 profiles.
    return {
      path,
      inputEncoding,
      inputMime: mediaTypeOf(inputMime),
      inputContentType: inputMime,
      inputCapacity,
      outputEncoding,
      outputMime: mediaTypeOf(outputMime),
      outputContentType: outputMime,
      outputCapacity,
    };
  });
}

function commandFor(recipe, inputMime, outputMime) {
  const inputExtension = FILE_EXTENSIONS[inputMime] ?? "input";
  const outputExtension = FILE_EXTENSIONS[outputMime] ?? "output";
  const paths = recipe.map((step) => step.path.replace(/^\//, "")).join(" \\\n  ");
  return `qip run -i input.${inputExtension} -o output.${outputExtension} -- \\\n  ${paths}`;
}

function csvField(value) {
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function contentRecipeCSV(recipe) {
  const rows = recipe.map((component) => [
    component.path,
    component.inputEncoding,
    component.inputMime,
    component.inputCapacity,
    component.outputEncoding,
    component.outputMime,
    component.outputCapacity,
  ].map(csvField).join(","));
  return `${CATALOG_HEADER}\n${rows.join("\n")}\n`;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });
let generatorPromise;

async function browserJavaScriptFor(recipe) {
  generatorPromise ??= WebAssembly.instantiateStreaming(fetch(GENERATOR_URL));
  const { instance } = await generatorPromise;
  const exports = instance.exports;
  const input = textEncoder.encode(contentRecipeCSV(recipe));
  const inputCapacity = exports.input_utf8_cap();
  if (input.length > inputCapacity) throw new RangeError(`Content Recipe CSV is too large: ${input.length} > ${inputCapacity}`);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("generator rejected recipe");
  const outputLength = Number(result & 0xffff_ffffn);
  const outputPointer = Number((result >> 32n) & 0x7fff_ffffn);
  return textDecoder.decode(new Uint8Array(exports.memory.buffer, outputPointer, outputLength));
}

async function copyText(button, defaultLabel, makeText) {
  button.disabled = true;
  try {
    await navigator.clipboard.writeText(await makeText());
    button.textContent = "Copied";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
    button.textContent = "Copy failed";
  }
  window.setTimeout(() => {
    button.textContent = defaultLabel;
    button.disabled = false;
  }, 1500);
}

function addMimeOptions(catalog, selectedInput, selectedOutput) {
  const mimes = [...new Set(catalog.flatMap((component) => [component.inputMime, component.outputMime]))]
    .sort((left, right) => labelFor(left).localeCompare(labelFor(right)) || left.localeCompare(right));

  for (const mime of mimes) {
    const text = `${labelFor(mime)} — ${mime}`;
    inputSelect.add(new Option(text, mime, false, mime === selectedInput));
  }
  for (const role of ["deliverable", "working"]) {
    const roleMimes = mimes.filter((mime) => outputRole(mime) === role);
    if (roleMimes.length === 0) continue;
    const group = document.createElement("optgroup");
    group.label = role === "working" ? "Intermediate and advanced formats" : "Output formats";
    for (const mime of roleMimes) {
      const suffix = role === "working" ? " — for QIP pipelines" : "";
      group.append(new Option(`${labelFor(mime)} — ${mime}${suffix}`, mime, false, mime === selectedOutput));
    }
    outputSelect.append(group);
  }
}

function updateOutputOptions(inputMime, selectFallback) {
  const reachable = reachableOutputMimes(catalog, inputMime);
  for (const option of outputSelect.options) option.disabled = !reachable.has(option.value);

  if (!selectFallback || reachable.has(outputSelect.value)) return;

  const options = [...outputSelect.options];
  const fallback = options.find((option) => !option.disabled && outputRole(option.value) === "deliverable" && option.value !== inputMime)
    ?? options.find((option) => !option.disabled && outputRole(option.value) === "deliverable")
    ?? options.find((option) => !option.disabled);
  if (fallback) outputSelect.value = fallback.value;
}

function renderRecipe(recipe, inputMime, outputMime, rank) {
  const item = document.createElement("li");
  item.className = "pipeline-result";

  const title = document.createElement("h2");
  title.textContent = `${rank === 0 ? "Recommended: " : ""}${recipe.length} component${recipe.length === 1 ? "" : "s"}`;
  item.append(title);

  const steps = document.createElement("div");
  steps.className = "pipeline-steps";
  const mimes = [inputMime, ...recipe.map((component) => component.outputMime)];
  mimes.forEach((mime, index) => {
    if (index > 0) steps.append(document.createTextNode(" → "));
    const code = document.createElement("code");
    code.textContent = labelFor(mime);
    code.title = mime;
    steps.append(code);
  });
  item.append(steps);

  const componentList = document.createElement("ol");
  for (const component of recipe) {
    const componentItem = document.createElement("li");
    const link = document.createElement("a");
    link.href = component.path;
    link.textContent = component.path.replace("/", "");
    componentItem.append(link);
    componentList.append(componentItem);
  }
  item.append(componentList);

  const command = commandFor(recipe, inputMime, outputMime);
  const commandWrapper = document.createElement("div");
  commandWrapper.className = "pipeline-command";
  const pre = document.createElement("pre");
  const code = document.createElement("code");
  code.textContent = command;
  pre.append(code);
  const actions = document.createElement("div");
  actions.className = "pipeline-actions";
  const copyCommand = document.createElement("button");
  copyCommand.type = "button";
  copyCommand.textContent = "Copy CLI";
  copyCommand.addEventListener("click", () => {
    copyText(copyCommand, "Copy CLI", () => command);
  });
  const copyJavaScript = document.createElement("button");
  copyJavaScript.type = "button";
  copyJavaScript.textContent = "Copy JavaScript";
  copyJavaScript.addEventListener("click", () => {
    copyText(copyJavaScript, "Copy JavaScript", () => browserJavaScriptFor(recipe));
  });
  actions.append(copyCommand, copyJavaScript);
  commandWrapper.append(pre, actions);
  item.append(commandWrapper);
  return item;
}

let catalog = [];

function recipeForAgent(recipe, inputMime, outputMime) {
  return {
    components: recipe.map((component) => component.path),
    command: commandFor(recipe, inputMime, outputMime),
  };
}

function render() {
  const inputMime = inputSelect.value;
  const outputMime = outputSelect.value;
  const preference = preferenceSelect.value;
  const recipes = findRankedRecipes(catalog, inputMime, outputMime, preference);
  const params = new URLSearchParams({ from: inputMime, to: outputMime, preference });
  history.replaceState(null, "", `${location.pathname}?${params}`);
  resultsElement.replaceChildren();

  if (inputMime === outputMime) {
    status.textContent = "No conversion is required: the input and output content types are the same.";
    return;
  }
  if (recipes.length === 0) {
    status.textContent = `No component pipeline converts ${labelFor(inputMime)} to ${labelFor(outputMime)}.`;
    return;
  }

  const ktx2Note = outputMime === "image/ktx2"
    ? " KTX2 is a QIP working format for downstream components."
    : "";
  status.textContent = `${recipes.length} valid ${recipes.length === 1 ? "recipe" : "recipes"}, ranked for ${preference}.${ktx2Note}`;
  const fragment = document.createDocumentFragment();
  for (const [rank, recipe] of recipes.entries()) {
    fragment.append(renderRecipe(recipe, inputMime, outputMime, rank));
  }
  resultsElement.append(fragment);
}

function chooseRecipe(inputMime, outputMime, preference, recipeIndex) {
  if (!PREFERENCES.has(preference)) throw new RangeError(`Unsupported preference: ${preference}`);
  const recipes = findRankedRecipes(catalog, inputMime, outputMime, preference);
  if (!Number.isInteger(recipeIndex) || recipeIndex < 0 || recipeIndex >= recipes.length) {
    throw new RangeError(`Recipe index ${recipeIndex} is unavailable for this conversion.`);
  }
  return recipes[recipeIndex];
}

async function registerWebMCPTools(knownMimes) {
  if (!document.modelContext?.registerTool) return;
  const mimeSchema = {
    type: "string",
    enum: [...knownMimes].sort(),
  };
  const preferenceSchema = {
    type: "string",
    enum: [...PREFERENCES],
    default: "balanced",
  };
  const commonProperties = {
    from: { ...mimeSchema, description: "Input MIME type." },
    to: { ...mimeSchema, description: "Desired output MIME type." },
    preference: { ...preferenceSchema, description: "Rank valid recipes by this tradeoff." },
  };

  const tools = [
    {
      name: "list_content_types",
      title: "List QIP content types",
      description: "List MIME types in the QIP component catalog, marking working formats that are mainly for component pipelines.",
      inputSchema: { type: "object", additionalProperties: false },
      annotations: { readOnlyHint: true, untrustedContentHint: false },
      execute: async () => JSON.stringify([...knownMimes].sort().map((mime) => ({
        mime,
        label: labelFor(mime),
        role: outputRole(mime),
      }))),
    },
    {
      name: "find_component_recipes",
      title: "Find QIP component recipes",
      description: "Find compatible, ranked QIP component pipelines between two MIME types. The finder updates visibly for the user and returns the five best recipes.",
      inputSchema: {
        type: "object",
        properties: commonProperties,
        required: ["from", "to"],
        additionalProperties: false,
      },
      annotations: { readOnlyHint: true, untrustedContentHint: false },
      execute: async ({ from, to, preference = "balanced" }, { signal } = {}) => {
        signal?.throwIfAborted();
        if (!knownMimes.has(from) || !knownMimes.has(to)) throw new RangeError("Unknown MIME type.");
        if (!PREFERENCES.has(preference)) throw new RangeError("Unsupported preference.");
        inputSelect.value = from;
        updateOutputOptions(from, false);
        outputSelect.value = to;
        preferenceSelect.value = preference;
        render();
        const recipes = findRankedRecipes(catalog, from, to, preference);
        return JSON.stringify({
          from,
          to,
          preference,
          output_role: outputRole(to),
          recipe_count: recipes.length,
          recipes: recipes.slice(0, 5).map((recipe) => recipeForAgent(recipe, from, to)),
        });
      },
    },
    {
      name: "get_recipe_code",
      title: "Get QIP recipe code",
      description: "Return CLI or browser JavaScript for one ranked QIP component recipe. Use a recipe index returned by find_component_recipes.",
      inputSchema: {
        type: "object",
        properties: {
          ...commonProperties,
          recipe_index: { type: "integer", minimum: 0, description: "Zero-based index in the ranked recipe list." },
          format: { type: "string", enum: ["cli", "javascript"], description: "Requested code format." },
        },
        required: ["from", "to", "recipe_index", "format"],
        additionalProperties: false,
      },
      annotations: { readOnlyHint: true, untrustedContentHint: false },
      execute: async ({ from, to, preference = "balanced", recipe_index: recipeIndex, format }, { signal } = {}) => {
        signal?.throwIfAborted();
        if (!knownMimes.has(from) || !knownMimes.has(to)) throw new RangeError("Unknown MIME type.");
        if (format !== "cli" && format !== "javascript") throw new RangeError("Unsupported code format.");
        const recipe = chooseRecipe(from, to, preference, recipeIndex);
        inputSelect.value = from;
        updateOutputOptions(from, false);
        outputSelect.value = to;
        preferenceSelect.value = preference;
        render();
        const code = format === "cli"
          ? commandFor(recipe, from, to)
          : await browserJavaScriptFor(recipe);
        return JSON.stringify({ format, recipe: recipeForAgent(recipe, from, to), code });
      },
    },
  ];

  await Promise.all(tools.map((tool) => document.modelContext.registerTool(tool)));
}

try {
  const response = await fetch(CATALOG_URL);
  if (!response.ok) throw new Error(`The component catalog returned HTTP ${response.status}.`);
  catalog = parseCatalog(await response.text());
  const params = new URLSearchParams(location.search);
  const knownMimes = new Set(catalog.flatMap((component) => [component.inputMime, component.outputMime]));
  const requestedInput = params.get("from");
  const requestedOutput = params.get("to");
  const requestedPreference = params.get("preference");
  const selectedInput = knownMimes.has(requestedInput) ? requestedInput : "image/svg+xml";
  const selectedOutput = knownMimes.has(requestedOutput) ? requestedOutput : "image/webp";
  addMimeOptions(catalog, selectedInput, selectedOutput);
  preferenceSelect.value = PREFERENCES.has(requestedPreference) ? requestedPreference : "balanced";
  updateOutputOptions(inputSelect.value, false);
  form.addEventListener("submit", (event) => event.preventDefault());
  inputSelect.addEventListener("change", () => {
    updateOutputOptions(inputSelect.value, true);
    render();
  });
  outputSelect.addEventListener("change", render);
  preferenceSelect.addEventListener("change", render);
  render();
  try {
    await registerWebMCPTools(knownMimes);
  } catch (error) {
    console.warn("WebMCP tools were not registered:", error);
  }
} catch (error) {
  status.textContent = error instanceof Error ? error.message : String(error);
}
</script>

<p><small>This finder lists non-repeating, profile-compatible pipelines through QIP's typed component catalog. It ranks them for the selected tradeoff. KTX2 is shown as an advanced output because QIP uses it mainly as a working image format between components, not as a general delivery format.</small></p>
<p><small>The catalog includes components with different, explicitly declared input and
output MIME types. It deliberately leaves out generic components and
same-content-type transforms such as validators, formatters, and image
adjustments. The finder checks MIME, encoding, and KTX2 pixel-profile connections; run `qip dry run` when you
need capacity and encoding diagnostics for a selected pipeline.</small></p>
<p><small>A selected KTX2 input is treated as QIP's canonical RGBA8 sRGB profile. The
catalog cannot infer another KTX2 pixel profile from the MIME type alone; use a
component path that names the required profile when you need linear float or
Display P3 data.</small></p>
