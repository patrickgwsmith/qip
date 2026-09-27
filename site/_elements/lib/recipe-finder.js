const KTX2_RGBA8_SRGB = "ktx2-r8g8b8a8-srgb";
const KTX2_BGRA8_SRGB = "ktx2-b8g8r8a8-srgb";
const KTX2_RGBA32FLOAT_BT709_LINEAR = "ktx2-rgba32float-bt709-linear";
const KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR = "ktx2-rgba32float-display-p3-linear";
const KTX2_RGBA32FLOAT_DISPLAY_P3 = "ktx2-rgba32float-display-p3";

const MAX_RECIPES = 512;

export const PREFERENCES = new Set(["balanced", "quality", "smallest", "fastest"]);

export function encodingAccepted(actual, expected) {
  return actual === expected || (actual === "utf8" && expected === "bytes");
}


/**
 * Splits "type/subtype; name=value; ..." into a lowercase media type and a map of
 * parameters keyed by lowercase name. Parameter values are case-sensitive and kept
 * verbatim, as in
 * "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR".
 */
export function parseContentType(value) {
  const segments = String(value ?? "").split(";");
  const mediaType = segments[0].trim().toLowerCase();
  const params = new Map();
  for (const segment of segments.slice(1)) {
    const eq = segment.indexOf("=");
    if (eq === -1) continue;
    const name = segment.slice(0, eq).trim().toLowerCase();
    if (name !== "") params.set(name, segment.slice(eq + 1).trim());
  }
  return { mediaType, params };
}

export function mediaTypeOf(value) {
  return parseContentType(value).mediaType;
}

function stripPrefix(value, prefix) {
  return value !== undefined && value.startsWith(prefix) ? value.slice(prefix.length) : value;
}

/**
 * The KTX2 profile a declared content type names through its vkFormat, colorPrimaries,
 * and transferFunction parameters. Returns undefined when no vkFormat is declared, so the
 * caller may fall back to the component name, and null when the declaration names a
 * profile QIP does not support, so nothing chains to it.
 */
export function profileFromParameters(params) {
  const format = stripPrefix(params.get("vkformat"), "VK_FORMAT_");
  if (format === undefined) return undefined;
  const primaries = stripPrefix(params.get("colorprimaries"), "KHR_DF_PRIMARIES_");
  const transfer = stripPrefix(params.get("transferfunction"), "KHR_DF_TRANSFER_");
  const srgb8 = (primaries === undefined || primaries === "BT709") && (transfer === undefined || transfer === "SRGB");
  if (format === "R8G8B8A8_SRGB") return srgb8 ? KTX2_RGBA8_SRGB : null;
  if (format === "B8G8R8A8_SRGB") return srgb8 ? KTX2_BGRA8_SRGB : null;
  if (format === "R32G32B32A32_SFLOAT") {
    if (primaries === "BT709" && transfer === "LINEAR") return KTX2_RGBA32FLOAT_BT709_LINEAR;
    if (primaries === "DISPLAYP3" && transfer === "LINEAR") return KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR;
    if (primaries === "DISPLAYP3" && transfer === "SRGB") return KTX2_RGBA32FLOAT_DISPLAY_P3;
  }
  return null;
}

export function outputRole(mime) {
  if (mediaTypeOf(mime) === "image/ktx2") return "working";
  return "deliverable";
}

// A component's declared parameters are the source of truth for its KTX2 profile; the
// file name is the fallback for components that declare a bare image/ktx2.
function inputProfiles(component) {
  const declared = component.inputContentType ?? component.inputMime;
  if (mediaTypeOf(declared) !== "image/ktx2") return [null];
  const fromParameters = profileFromParameters(parseContentType(declared).params);
  if (fromParameters !== undefined) return fromParameters === null ? [] : [fromParameters];
  const { path } = component;
  if (path.includes("r8g8b8a8-or-b8g8r8a8-srgb")) {
    return [KTX2_RGBA8_SRGB, KTX2_BGRA8_SRGB];
  }
  if (path.includes("r8g8b8a8-srgb")) return [KTX2_RGBA8_SRGB];
  if (path.includes("b8g8r8a8-srgb")) return [KTX2_BGRA8_SRGB];
  if (path.includes("rgba32float-display-p3-linear")) {
    return [KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR];
  }
  if (path.includes("rgba32float-display-p3")) {
    return [KTX2_RGBA32FLOAT_DISPLAY_P3];
  }
  if (path.includes("rgba32float")) return [KTX2_RGBA32FLOAT_BT709_LINEAR];
  return [];
}

function outputProfile(component) {
  const declared = component.outputContentType ?? component.outputMime;
  if (mediaTypeOf(declared) !== "image/ktx2") return null;
  const fromParameters = profileFromParameters(parseContentType(declared).params);
  if (fromParameters !== undefined) return fromParameters;
  const { path } = component;
  if (path.includes("rgba32float-display-p3-linear")) {
    return KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR;
  }
  if (path.includes("rgba32float-display-p3")) return KTX2_RGBA32FLOAT_DISPLAY_P3;
  if (path.includes("rgba32float")) return KTX2_RGBA32FLOAT_BT709_LINEAR;
  if (path.includes("r8g8b8a8-srgb")) return KTX2_RGBA8_SRGB;
  if (path.includes("b8g8r8a8-srgb")) return KTX2_BGRA8_SRGB;
  return null;
}

function initialProfile(mime) {
  // The finder has no file inspector. Treat a user-selected KTX2 source as
  // QIP's documented canonical profile rather than connecting it to every
  // component that happens to use image/ktx2.
  return mime === "image/ktx2" ? KTX2_RGBA8_SRGB : null;
}

function stateKey(state) {
  return `${state.mime}\0${state.encoding}\0${state.profile ?? ""}`;
}

function accepts(component, state) {
  if (mediaTypeOf(component.inputMime) !== state.mime) return false;
  if (state.encoding !== null && !encodingAccepted(state.encoding, component.inputEncoding)) return false;
  const profiles = inputProfiles(component);
  return profiles.includes(state.profile);
}

function nextState(component) {
  return {
    mime: mediaTypeOf(component.outputMime),
    encoding: component.outputEncoding,
    profile: outputProfile(component),
  };
}

function countLossy(recipe) {
  return recipe.filter((component) => component.path.includes("-lossy")).length;
}

function countLossless(recipe) {
  return recipe.filter((component) => component.path.includes("-lossless")).length;
}

function intermediatePenalty(recipe) {
  let penalty = 0;
  for (const component of recipe.slice(0, -1)) {
    const outputMime = mediaTypeOf(component.outputMime);
    if (outputMime === "image/ktx2") {
      // Canonical RGBA8 KTX2 is the preferred QIP image bridge. Float profiles
      // stay valid, but are more specialised working representations.
      penalty += outputProfile(component) === KTX2_RGBA8_SRGB ? 0 : 1;
    } else if (outputMime === "image/bmp") {
      penalty += 2;
    }
  }
  return penalty;
}

function scalarPenalty(recipe) {
  return recipe.filter((component) =>
    component.path.includes("rasterize") && !component.path.includes("-simd"),
  ).length;
}

function compareNumbers(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

function score(recipe, preference) {
  const lossiness = countLossy(recipe);
  const losslessness = countLossless(recipe);
  const bridge = intermediatePenalty(recipe);
  const scalar = scalarPenalty(recipe);
  switch (preference) {
    case "quality":
      return [lossiness, bridge, recipe.length, scalar];
    case "smallest":
      return [losslessness, recipe.length, bridge, scalar];
    case "fastest":
      return [recipe.length, scalar, bridge, lossiness];
    default:
      return [lossiness, recipe.length, bridge, scalar];
  }
}

/**
 * Finds executable, non-cyclic format-conversion pipelines. A graph node has
 * an encoding, MIME type, and optional KTX2 profile; MIME alone is not enough
 * to connect QIP image components safely.
 */
export function findRecipes(catalog, inputMime, outputMime) {
  inputMime = mediaTypeOf(inputMime);
  outputMime = mediaTypeOf(outputMime);
  if (inputMime === outputMime) return [[]];

  const recipes = [];
  const start = {
    mime: inputMime,
    encoding: null,
    profile: initialProfile(inputMime),
  };

  function visit(state, steps, visited) {
    if (recipes.length >= MAX_RECIPES) return;
    for (const component of catalog) {
      if (!accepts(component, state)) continue;
      const next = nextState(component);
      const nextKey = stateKey(next);
      if (visited.has(nextKey)) continue;

      const nextSteps = [...steps, component];
      if (next.mime === outputMime) {
        recipes.push(nextSteps);
        continue;
      }

      const nextVisited = new Set(visited);
      nextVisited.add(nextKey);
      visit(next, nextSteps, nextVisited);
    }
  }

  visit(start, [], new Set([stateKey(start)]));
  return recipes;
}

export function reachableOutputMimes(catalog, inputMime) {
  inputMime = mediaTypeOf(inputMime);
  const mimes = new Set(catalog.flatMap((component) => [
    mediaTypeOf(component.inputMime), mediaTypeOf(component.outputMime),
  ]));
  const reachable = new Set([inputMime]);
  for (const mime of mimes) {
    if (mime !== inputMime && findRecipes(catalog, inputMime, mime).length > 0) {
      reachable.add(mime);
    }
  }
  return reachable;
}

export function rankRecipes(recipes, preference = "balanced") {
  if (!PREFERENCES.has(preference)) throw new RangeError(`Unknown recipe preference: ${preference}`);
  return [...recipes].sort((left, right) => {
    const result = compareNumbers(score(left, preference), score(right, preference));
    if (result !== 0) return result;
    return left.map((component) => component.path).join("\n").localeCompare(
      right.map((component) => component.path).join("\n"),
    );
  });
}

export function findRankedRecipes(catalog, inputMime, outputMime, preference = "balanced") {
  return rankRecipes(findRecipes(catalog, inputMime, outputMime), preference);
}
