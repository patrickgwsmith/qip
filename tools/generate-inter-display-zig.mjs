#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { basename } from "node:path";

const [fontPath, outputPath] = process.argv.slice(2);
if (!fontPath || !outputPath) {
  console.error(
    "usage: node tools/generate-inter-display-zig.mjs FONT.ttf OUTPUT.zig",
  );
  process.exit(2);
}

const extraCodepoints = [
  0x2013, // en dash
  0x2014, // em dash
  0x2018, // left single quotation mark
  0x2019, // right single quotation mark
  0x201c, // left double quotation mark
  0x201d, // right double quotation mark
  0x2022, // bullet
  0x2026, // ellipsis
  0x2032, // prime
  0x2033, // double prime
  0x2039, // single left-pointing angle quotation mark
  0x203a, // single right-pointing angle quotation mark
  0x20ac, // euro sign
  0x2122, // trademark sign
  0x2212, // minus sign
];
const requestedCodepoints = [
  ...Array.from({ length: 0x7e - 0x20 + 1 }, (_, index) => 0x20 + index),
  ...Array.from({ length: 0xff - 0xa0 + 1 }, (_, index) => 0xa0 + index),
  ...extraCodepoints,
].filter((codepoint) => codepoint !== 0xad);
const requested = new Set(requestedCodepoints);

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

const csv = [
  extractRange(0x20, 0xff),
  extractRange(0x2013, 0x203a),
  extractRange(0x20ac, 0x20ac),
  extractRange(0x2122, 0x2122),
  extractRange(0x2212, 0x2212),
].join("");

const rowPattern = /^(\d+),U\+[0-9A-F]+,(\d+),(\d+),(-?\d+),(-?\d+),(-?\d+),(-?\d+),(-?\d+),(\d+),(-?\d+),(-?\d+),(-?\d+),"(.*)"$/;
const rows = new Map();
for (const line of csv.split("\n")) {
  const match = line.match(rowPattern);
  if (!match) continue;
  const codepoint = Number(match[1]);
  if (!requested.has(codepoint)) continue;
  rows.set(codepoint, {
    codepoint,
    advance: Number(match[3]),
    unitsPerEm: Number(match[9]),
    ascenderY: Number(match[10]),
    descenderY: Number(match[11]),
    lineGap: Number(match[12]),
    path: match[13],
  });
}

const missing = requestedCodepoints.filter((codepoint) => !rows.has(codepoint));
if (missing.length !== 0) {
  throw new Error(
    `font is missing requested codepoints: ${missing.map(hexCodepoint).join(", ")}`,
  );
}
const glyphs = requestedCodepoints.map((codepoint) => rows.get(codepoint));
const metrics = glyphs[0];
for (const glyph of glyphs) {
  if (
    glyph.unitsPerEm !== metrics.unitsPerEm ||
    glyph.ascenderY !== metrics.ascenderY ||
    glyph.descenderY !== metrics.descenderY ||
    glyph.lineGap !== metrics.lineGap
  ) {
    throw new Error("font-wide metrics changed between CSV rows");
  }
}

const pairText = [];
for (const left of glyphs) {
  for (const right of glyphs) {
    pairText.push(String.fromCodePoint(left.codepoint, right.codepoint));
  }
}
const shapedText = execFileSync(
  "hb-shape",
  [fontPath, "--features=-liga,-clig,-calt", "--output-format=json"],
  {
    input: `${pairText.join("\n")}\n`,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  },
);
const shapedLines = shapedText.trimEnd().split("\n");
if (shapedLines.length !== pairText.length) {
  throw new Error(`expected ${pairText.length} shaped lines, got ${shapedLines.length}`);
}

const kernPairs = [];
let pairIndex = 0;
for (let leftIndex = 0; leftIndex < glyphs.length; leftIndex += 1) {
  for (let rightIndex = 0; rightIndex < glyphs.length; rightIndex += 1) {
    const shaped = JSON.parse(shapedLines[pairIndex]);
    pairIndex += 1;
    if (
      shaped.length !== 2 ||
      shaped.some((glyph) => glyph.dx !== 0 || glyph.dy !== 0 || glyph.ay !== 0)
    ) {
      throw new Error(
        `pair ${hexCodepoint(glyphs[leftIndex].codepoint)} ${hexCodepoint(glyphs[rightIndex].codepoint)} needs runtime shaping`,
      );
    }
    const unkerned = glyphs[leftIndex].advance + glyphs[rightIndex].advance;
    const adjustment = shaped[0].ax + shaped[1].ax - unkerned;
    if (adjustment !== 0) {
      if (adjustment < -32768 || adjustment > 32767) {
        throw new Error(`kerning adjustment ${adjustment} does not fit in i16`);
      }
      kernPairs.push({
        key: leftIndex * 65536 + rightIndex,
        adjustment,
      });
    }
  }
}

const source = `// Generated from ${basename(fontPath)} with QIP's TrueType parser and hb-shape.
// Coverage: U+0020..U+007E, U+00A0..U+00FF except U+00AD, plus selected punctuation.
// Shaping: proportional advances and pair kerning; liga, clig, and calt are disabled.

pub const UNITS_PER_EM: f32 = ${metrics.unitsPerEm}.0;
pub const ASCENDER: f32 = ${-metrics.ascenderY}.0;
pub const DESCENDER: f32 = ${-metrics.descenderY}.0;
pub const LINE_GAP: f32 = ${metrics.lineGap}.0;

pub const codepoints = [_]u32{
${formatValues(glyphs.map((glyph) => `0x${glyph.codepoint.toString(16).toUpperCase()}`), 12)}
};

pub const advances = [_]u16{
${formatValues(glyphs.map((glyph) => String(glyph.advance)), 16)}
};

pub const glyph_paths = [_][]const u8{
${glyphs.map((glyph) => `    "${glyph.path}", // ${hexCodepoint(glyph.codepoint)}`).join("\n")}
};

pub const KernPair = struct {
    key: u32,
    adjustment: i16,
};

pub const kern_pairs = [_]KernPair{
${kernPairs.map((pair) => `    .{ .key = ${pair.key}, .adjustment = ${pair.adjustment} },`).join("\n")}
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

pub fn kerning(left: usize, right: usize) i16 {
    if (kern_pairs.len == 0) return 0;
    const key = @as(u32, @intCast(left)) * 65536 + @as(u32, @intCast(right));
    var low: usize = 0;
    var high: usize = kern_pairs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (key < kern_pairs[middle].key) {
            high = middle;
        } else if (key > kern_pairs[middle].key) {
            low = middle + 1;
        } else {
            return kern_pairs[middle].adjustment;
        }
    }
    return 0;
}

test "font tables stay aligned" {
    const std = @import("std");
    try std.testing.expectEqual(codepoints.len, advances.len);
    try std.testing.expectEqual(codepoints.len, glyph_paths.len);
    var index: usize = 1;
    while (index < codepoints.len) : (index += 1) {
        try std.testing.expect(codepoints[index - 1] < codepoints[index]);
    }
}
`;

writeFileSync(outputPath, source);
execFileSync("zig", ["fmt", outputPath], { stdio: "inherit" });
console.log(
  `generated ${outputPath}: ${glyphs.length} glyphs, ${kernPairs.length} kerning pairs`,
);

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
