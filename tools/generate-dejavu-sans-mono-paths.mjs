#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { basename } from "node:path";
import { writeFileSync } from "node:fs";

const [fontPath, outputPath] = process.argv.slice(2);
if (!fontPath || !outputPath) {
  console.error(
    "usage: node tools/generate-dejavu-sans-mono-paths.mjs FONT.ttf OUTPUT.zig",
  );
  process.exit(2);
}

// Keep Latin-1 text coverage and add Unicode blocks that provide common UI,
// diagram, technical, mathematical, and terminal symbols. Each range is below
// ttf-to-svg-paths-csv's 4,096-codepoint limit.
const ranges = [
  [0x0020, 0x00ff],
  [0x0100, 0x024f], // Latin Extended-A and -B
  [0x0300, 0x036f], // combining diacritical marks
  [0x0370, 0x03ff], // Greek and Coptic
  [0x0400, 0x052f], // Cyrillic and Cyrillic Supplement
  [0x1e00, 0x1eff], // Latin Extended Additional
  [0x2000, 0x206f], // general punctuation
  [0x2070, 0x209f], // superscripts and subscripts
  [0x20a0, 0x20cf], // currency symbols
  [0x2100, 0x214f], // letterlike symbols
  [0x2150, 0x218f], // number forms
  [0x2190, 0x21ff], // arrows
  [0x2200, 0x22ff], // mathematical operators
  [0x2300, 0x23ff], // miscellaneous technical
  [0x2400, 0x243f], // control pictures
  [0x2440, 0x245f], // optical character recognition
  [0x2460, 0x24ff], // enclosed alphanumerics
  [0x2500, 0x257f], // box drawing
  [0x2580, 0x259f], // block elements
  [0x25a0, 0x25ff], // geometric shapes
  [0x2600, 0x26ff], // miscellaneous symbols
  [0x2700, 0x27bf], // dingbats
  [0x27c0, 0x27ef], // miscellaneous mathematical symbols-A
  [0x27f0, 0x27ff], // supplemental arrows-A
  [0x2800, 0x28ff], // braille patterns
  [0x2980, 0x29ff], // miscellaneous mathematical symbols-B
  [0x2a00, 0x2aff], // supplemental mathematical operators
  [0x2b00, 0x2bff], // miscellaneous symbols and arrows
];

// DejaVu Sans Mono Bold does not map BLACK HOURGLASS. Keep the fallback in
// font units so it uses the same scale and cell advance as the generated data.
const fallbackPaths = new Map([
  [
    0x29d7,
    "M 200 -1530 L 1033 -1530 L 1033 -1360 L 760 -760 L 1033 -160 L 1033 10 L 200 10 L 200 -160 L 473 -760 L 200 -1360 Z",
  ],
]);

function extractRange(first, last) {
  return execFileSync(
    "./qip",
    [
      "run",
      "-i",
      fontPath,
      "--",
      "font/ttf/ttf-to-svg-paths-csv.wasm",
      `?first_codepoint=${first}&last_codepoint=${last}`,
    ],
    { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
  );
}

const rowPattern = /^(\d+),U\+[0-9A-F]+,\d+,(-?\d+),-?\d+,-?\d+,-?\d+,-?\d+,-?\d+,(\d+),(-?\d+),(-?\d+),(-?\d+),"(.*)"$/;
const rows = new Map();
for (const [first, last] of ranges) {
  for (const line of extractRange(first, last).split("\n")) {
    const match = line.match(rowPattern);
    if (!match) continue;
    rows.set(Number(match[1]), {
      codepoint: Number(match[1]),
      advance: Number(match[2]),
      unitsPerEm: Number(match[3]),
      ascenderY: Number(match[4]),
      descenderY: Number(match[5]),
      lineGap: Number(match[6]),
      path: match[7],
    });
  }
}

const metrics = rows.values().next().value;
if (!metrics) throw new Error("font has no glyphs in the requested ranges");
for (const [codepoint, path] of fallbackPaths) {
  if (rows.has(codepoint)) continue;
  rows.set(codepoint, {
    codepoint,
    advance: metrics.advance,
    unitsPerEm: metrics.unitsPerEm,
    ascenderY: metrics.ascenderY,
    descenderY: metrics.descenderY,
    lineGap: metrics.lineGap,
    path,
  });
}

const glyphs = [...rows.values()].sort((a, b) => a.codepoint - b.codepoint);
for (const glyph of glyphs) {
  if (
    glyph.unitsPerEm !== metrics.unitsPerEm ||
    glyph.ascenderY !== metrics.ascenderY ||
    glyph.descenderY !== metrics.descenderY ||
    glyph.lineGap !== metrics.lineGap
  ) {
    throw new Error(`inconsistent font-wide metric at ${hexCodepoint(glyph.codepoint)}`);
  }
}

const source = `// Generated from ${basename(fontPath)} with QIP's TrueType parser.
// Requested Unicode blocks: Latin, Greek, Cyrillic, and U+2000..U+2BFF
// symbol blocks.
// Only code points mapped by the source font are emitted.
// Coordinates and metrics remain in native font units; callers scale them once.
// U+29D7 is a native-unit fallback because DejaVu Sans Mono does not map it.

pub const UNITS_PER_EM: f32 = ${metrics.unitsPerEm}.0;
pub const ADVANCE_X: f32 = ${metrics.advance}.0;
pub const ASCENDER: f32 = ${-metrics.ascenderY}.0;
pub const DESCENDER: f32 = ${metrics.descenderY}.0;
pub const LINE_GAP: f32 = ${metrics.lineGap}.0;
pub const LINE_HEIGHT: f32 = ASCENDER + DESCENDER + LINE_GAP;

pub const codepoints = [_]u32{
${formatValues(glyphs.map((glyph) => `0x${glyph.codepoint.toString(16).toUpperCase()}`), 12)}
};

pub const glyph_paths = [_][]const u8{
${glyphs.map((glyph) => `    "${glyph.path}", // ${hexCodepoint(glyph.codepoint)}`).join("\n")}
};

pub fn glyphIndex(codepoint: u32) ?usize {
    var low: usize = 0;
    var high: usize = codepoints.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (codepoint < codepoints[middle]) {
            high = middle;
        } else if (codepoint > codepoints[middle]) {
            low = middle + 1;
        } else {
            return middle;
        }
    }
    return null;
}

test "font tables stay aligned" {
    const std = @import("std");
    try std.testing.expectEqual(codepoints.len, glyph_paths.len);
    var index: usize = 1;
    while (index < codepoints.len) : (index += 1) {
        try std.testing.expect(codepoints[index - 1] < codepoints[index]);
    }
}
`;

writeFileSync(outputPath, source);
execFileSync("zig", ["fmt", outputPath], { stdio: "inherit" });
console.log(`generated ${outputPath}: ${glyphs.length} glyphs`);

function hexCodepoint(codepoint) {
  return `U+${codepoint.toString(16).toUpperCase().padStart(4, "0")}`;
}

function formatValues(values, perLine) {
  const lines = [];
  for (let index = 0; index < values.length; index += perLine) {
    lines.push(`    ${values.slice(index, index + perLine).join(", ")},`);
  }
  return lines.join("\n");
}
