import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { runInNewContext } from "node:vm";
import { findRankedRecipes, mediaTypeOf, parseContentType, profileFromParameters } from "../site/_elements/lib/recipe-finder.js";

function component(path, inputMime, outputMime, inputEncoding = "bytes", outputEncoding = "bytes") {
  return { path, inputMime, outputMime, inputEncoding, outputEncoding };
}

test("recipe finder keeps incompatible KTX2 profiles apart", () => {
  const catalog = [
    component("/svg-to-ktx2-rgba32float-bt709-linear.wasm", "image/svg+xml", "image/ktx2", "utf8"),
    component("/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm", "image/ktx2", "image/webp"),
    component("/svg-to-ktx2-r8g8b8a8-srgb.wasm", "image/svg+xml", "image/ktx2", "utf8"),
  ];

  const recipes = findRankedRecipes(catalog, "image/svg+xml", "image/webp");
  assert.deepEqual(recipes.map((recipe) => recipe.map((step) => step.path)), [[
    "/svg-to-ktx2-r8g8b8a8-srgb.wasm",
    "/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm",
  ]]);
});

test("recipe finder ranks canonical KTX2 bridges before BMP bridges", () => {
  const catalog = [
    component("/svg-to-bmp.wasm", "image/svg+xml", "image/bmp", "utf8"),
    component("/bmp-to-webp-lossless.wasm", "image/bmp", "image/webp"),
    component("/svg-to-ktx2-r8g8b8a8-srgb.wasm", "image/svg+xml", "image/ktx2", "utf8"),
    component("/ktx2-r8g8b8a8-srgb-to-webp-lossless.wasm", "image/ktx2", "image/webp"),
  ];

  const recipes = findRankedRecipes(catalog, "image/svg+xml", "image/webp", "balanced");
  assert.deepEqual(recipes[0].map((step) => step.path), [
    "/svg-to-ktx2-r8g8b8a8-srgb.wasm",
    "/ktx2-r8g8b8a8-srgb-to-webp-lossless.wasm",
  ]);
});

test("quality keeps lossless recipes ahead while smallest prefers lossy output", () => {
  const catalog = [
    component("/bmp-to-webp-lossless.wasm", "image/bmp", "image/webp"),
    component("/bmp-to-webp-lossy.wasm", "image/bmp", "image/webp"),
  ];

  assert.equal(
    findRankedRecipes(catalog, "image/bmp", "image/webp", "quality")[0][0].path,
    "/bmp-to-webp-lossless.wasm",
  );
  assert.equal(
    findRankedRecipes(catalog, "image/bmp", "image/webp", "smallest")[0][0].path,
    "/bmp-to-webp-lossy.wasm",
  );
});

const FLOAT_BT709 = "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR";
const FLOAT_P3_LINEAR = "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=DISPLAYP3;transferFunction=LINEAR";
const RGBA8 = "image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB";

test("declared KTX2 parameters decide compatibility, not file names", () => {
  // Names suggest RGBA8 throughout, but the declarations say the first step emits linear
  // float, so only the float consumer may follow it.
  const catalog = [
    component("/svg-to-ktx2-r8g8b8a8-srgb.wasm", "image/svg+xml", FLOAT_BT709, "utf8"),
    component("/ktx2-r8g8b8a8-srgb-to-png.wasm", RGBA8, "image/png"),
    component("/float-to-png.wasm", FLOAT_BT709, "image/png"),
  ];
  const recipes = findRankedRecipes(catalog, "image/svg+xml", "image/png");
  assert.deepEqual(recipes.map((recipe) => recipe.map((step) => step.path)), [
    ["/svg-to-ktx2-r8g8b8a8-srgb.wasm", "/float-to-png.wasm"],
  ]);
});

test("mismatched declared profiles never chain", () => {
  const catalog = [
    component("/svg-to-float.wasm", "image/svg+xml", FLOAT_BT709, "utf8"),
    component("/p3-to-png.wasm", FLOAT_P3_LINEAR, "image/png"),
    component("/rgba8-to-png.wasm", RGBA8, "image/png"),
  ];
  assert.deepEqual(findRankedRecipes(catalog, "image/svg+xml", "image/png"), []);
});

test("a bare image/ktx2 declaration still falls back to the file name", () => {
  const catalog = [
    component("/svg-to-ktx2-rgba32float.wasm", "image/svg+xml", "image/ktx2", "utf8"),
    component("/ktx2-rgba32float-to-png.wasm", "image/ktx2", "image/png"),
    component("/ktx2-r8g8b8a8-srgb-to-png.wasm", RGBA8, "image/png"),
  ];
  const recipes = findRankedRecipes(catalog, "image/svg+xml", "image/png");
  assert.deepEqual(recipes.map((recipe) => recipe.map((step) => step.path)), [
    ["/svg-to-ktx2-rgba32float.wasm", "/ktx2-rgba32float-to-png.wasm"],
  ]);
});

test("content type helpers read parameters case-sensitively by value", () => {
  assert.equal(mediaTypeOf(" Image/KTX2 ;vkFormat=R8G8B8A8_SRGB"), "image/ktx2");
  assert.equal(profileFromParameters(parseContentType(FLOAT_P3_LINEAR).params), "ktx2-rgba32float-display-p3-linear");
  assert.equal(profileFromParameters(parseContentType(RGBA8).params), "ktx2-r8g8b8a8-srgb");
  assert.equal(profileFromParameters(parseContentType("image/ktx2; vkformat=VK_FORMAT_R8G8B8A8_SRGB").params), "ktx2-r8g8b8a8-srgb");
  assert.equal(profileFromParameters(parseContentType("image/ktx2").params), undefined);
  assert.equal(profileFromParameters(parseContentType("image/ktx2;vkFormat=BC7_SRGB_BLOCK").params), null);
  assert.equal(profileFromParameters(parseContentType("image/ktx2;vkFormat=r8g8b8a8_srgb").params), null);
});

test("recipe page WebMCP callbacks work when the browser omits execution context", async () => {
  const page = await readFile(new URL("../site/recipes.md", import.meta.url), "utf8");
  const start = page.indexOf("async function registerWebMCPTools(");
  const end = page.indexOf("\ntry {", start);
  assert.ok(start >= 0 && end > start);
  const tools = new Map();
  const pipeline = [component("/plain-to-html.wasm", "text/plain", "text/html", "utf8", "utf8")];
  let renders = 0;
  const context = {
    document: { modelContext: { registerTool: tool => tools.set(tool.name, tool) } },
    PREFERENCES: new Set(["balanced"]),
    catalog: pipeline,
    inputSelect: { value: "" }, outputSelect: { value: "" }, preferenceSelect: { value: "" },
    updateOutputOptions() {}, render() { renders += 1; },
    findRankedRecipes, outputRole: () => "deliverable",
    recipeForAgent: recipe => ({ steps: recipe.map(step => step.path) }),
    chooseRecipe: () => pipeline, commandFor: () => "qip run plain-to-html.wasm",
  };
  const register = runInNewContext(page.slice(start, end) + "\nregisterWebMCPTools", context);
  await register(new Set(["text/plain", "text/html"]));
  const search = tools.get("find_component_recipes");
  const result = JSON.parse(await search.execute({ from: "text/plain", to: "text/html" }));
  assert.deepEqual(result.recipes[0].steps, ["/plain-to-html.wasm"]);
  assert.equal(context.inputSelect.value, "text/plain");
  assert.equal(context.outputSelect.value, "text/html");
  assert.equal(renders, 1);
  const code = JSON.parse(await tools.get("get_recipe_code").execute({
    from: "text/plain", to: "text/html", recipe_index: 0, format: "cli",
  }));
  assert.equal(code.code, "qip run plain-to-html.wasm");
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(search.execute({ from: "text/plain", to: "text/html" }, { signal: controller.signal }),
    error => error.name === "AbortError");
});
