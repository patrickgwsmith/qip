#!/usr/bin/env node

// Convert a module from generate-inter-display-zig.mjs into packed tables.
// SVG path strings become command letters plus i16 coordinates in half font
// units. Kerning rows that repeat for many left glyphs are stored once.
// The decoder in the output reproduces each original path string exactly.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  console.error("usage: node tools/pack-glyph-paths-zig.mjs PATHS.zig OUTPUT.zig");
  process.exit(2);
}

const source = readFileSync(inputPath, "utf8");
const header = source.match(/^(\/\/.*\n)+/)[0].trimEnd();
const metrics = source.match(/^pub const (UNITS_PER_EM|ASCENDER|DESCENDER|LINE_GAP): f32 = .*;$/gm);
const codepoints = arrayBody("codepoints", "u32");
const advances = arrayBody("advances", "u16");
const paths = [...section("glyph_paths").matchAll(/^ {4}"(.*)", \/\/ (U\+[0-9A-F]+)$/gm)];
const kernPairs = [...source.matchAll(/\.key = (\d+), \.adjustment = (-?\d+)/g)].map((match) => ({
  left: Number(match[1]) >>> 16,
  right: Number(match[1]) & 0xffff,
  adjustment: Number(match[2]),
}));

const glyphCount = paths.length;
if (glyphCount > 255) throw new Error(`${glyphCount} glyphs do not fit u8 kerning indexes`);
if (metrics.length !== 4) throw new Error("missing font-wide metrics");

const commandArgs = { M: 2, L: 2, Q: 4, Z: 0 };
const commandStrings = [];
const commandOffsets = [0];
const coords = [];
const coordOffsets = [0];
let maxPathLength = 0;
for (const [, path, label] of paths) {
  const tokens = path.length === 0 ? [] : path.split(" ");
  let commands = "";
  for (let index = 0; index < tokens.length;) {
    const command = tokens[index];
    const argCount = commandArgs[command];
    if (argCount === undefined) throw new Error(`${label}: unexpected token ${command}`);
    commands += command;
    for (let arg = 1; arg <= argCount; arg += 1) {
      const halfUnits = Number(tokens[index + arg]) * 2;
      if (!Number.isInteger(halfUnits) || halfUnits < -32768 || halfUnits > 32767) {
        throw new Error(`${label}: coordinate ${tokens[index + arg]} does not fit i16 half units`);
      }
      coords.push(halfUnits);
    }
    index += 1 + argCount;
  }
  commandStrings.push({ commands, label });
  commandOffsets.push(commandOffsets.at(-1) + commands.length);
  coordOffsets.push(coords.length);
  const decoded = decodePath(commands, coords.slice(coordOffsets.at(-2), coordOffsets.at(-1)));
  if (decoded !== path) throw new Error(`${label}: packed path does not round-trip`);
  maxPathLength = Math.max(maxPathLength, path.length);
}
if (commandOffsets.at(-1) > 0xffff || coords.length > 0xffff) {
  throw new Error("packed path tables do not fit u16 offsets");
}

const rowsByLeft = new Map();
for (const pair of kernPairs) {
  if (!rowsByLeft.has(pair.left)) rowsByLeft.set(pair.left, []);
  rowsByLeft.get(pair.left).push(pair);
}
const rowIndexByKey = new Map();
const rowForLeft = new Array(glyphCount).fill(255);
const rowOffsets = [0];
const kernRights = [];
const kernAdjustments = [];
for (const [left, pairs] of rowsByLeft) {
  const key = pairs.map((pair) => `${pair.right}:${pair.adjustment}`).join(",");
  if (!rowIndexByKey.has(key)) {
    rowIndexByKey.set(key, rowOffsets.length - 1);
    for (const pair of pairs) {
      kernRights.push(pair.right);
      kernAdjustments.push(pair.adjustment);
    }
    rowOffsets.push(kernRights.length);
  }
  rowForLeft[left] = rowIndexByKey.get(key);
}
if (rowOffsets.length - 1 > 255) throw new Error("kerning rows do not fit u8 row indexes");

const output = `${header.replace(/^\/\/ Generated from .*$/m, (line) => `${line}\n// Packed from ${basename(inputPath)} by tools/pack-glyph-paths-zig.mjs.`)}
// Paths: command letters and i16 coordinates in half font units.

${metrics.join("\n")}

pub const MAX_GLYPH_PATH_LEN: usize = ${maxPathLength};

pub const codepoints = [_]u32{
${codepoints}
};

pub const advances = [_]u16{
${advances}
};

pub const glyph_command_offsets = [_]u16{
${formatValues(commandOffsets, 16)}
};

pub const glyph_commands =
${commandStrings.map(({ commands, label }) => `    "${commands}" ++ // ${label}`).join("\n")}
    "";

pub const glyph_coord_offsets = [_]u16{
${formatValues(coordOffsets, 16)}
};

pub const glyph_coords = [_]i16{
${formatValues(coords, 16)}
};

pub const NO_KERN_ROW: u8 = 255;

pub const kern_row_for_left = [_]u8{
${formatValues(rowForLeft, 16)}
};

pub const kern_row_offsets = [_]u16{
${formatValues(rowOffsets, 16)}
};

pub const kern_rights = [_]u8{
${formatValues(kernRights, 16)}
};

pub const kern_adjustments = [_]i16{
${formatValues(kernAdjustments, 16)}
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
    const row = kern_row_for_left[left];
    if (row == NO_KERN_ROW) return 0;
    var low: usize = kern_row_offsets[row];
    var high: usize = kern_row_offsets[row + 1];
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (right < kern_rights[middle]) {
            high = middle;
        } else if (right > kern_rights[middle]) {
            low = middle + 1;
        } else {
            return kern_adjustments[middle];
        }
    }
    return 0;
}

/// Writes the glyph's SVG path data into \`buffer\`, which must hold at least
/// \`MAX_GLYPH_PATH_LEN\` bytes, and returns the written slice.
pub fn glyphPath(glyph_index: usize, buffer: []u8) []const u8 {
    const commands = glyph_commands[glyph_command_offsets[glyph_index]..glyph_command_offsets[glyph_index + 1]];
    var coord_index: usize = glyph_coord_offsets[glyph_index];
    var len: usize = 0;
    for (commands, 0..) |command, command_index| {
        if (command_index != 0) {
            buffer[len] = ' ';
            len += 1;
        }
        buffer[len] = command;
        len += 1;
        const arg_count: usize = switch (command) {
            'M', 'L' => 2,
            'Q' => 4,
            else => 0,
        };
        for (0..arg_count) |_| {
            buffer[len] = ' ';
            len += 1;
            len += writeHalfUnits(buffer[len..], glyph_coords[coord_index]);
            coord_index += 1;
        }
    }
    return buffer[0..len];
}

fn writeHalfUnits(buffer: []u8, half_units: i16) usize {
    var len: usize = 0;
    if (half_units < 0) {
        buffer[0] = '-';
        len = 1;
    }
    const magnitude: u16 = @abs(half_units);
    var whole: u16 = magnitude / 2;
    var digits: [5]u8 = undefined;
    var digit_count: usize = 0;
    while (true) {
        digits[digit_count] = '0' + @as(u8, @intCast(whole % 10));
        digit_count += 1;
        whole /= 10;
        if (whole == 0) break;
    }
    while (digit_count > 0) {
        digit_count -= 1;
        buffer[len] = digits[digit_count];
        len += 1;
    }
    if (magnitude % 2 != 0) {
        buffer[len] = '.';
        buffer[len + 1] = '5';
        len += 2;
    }
    return len;
}

test "font tables stay aligned" {
    const std = @import("std");
    try std.testing.expectEqual(codepoints.len, advances.len);
    try std.testing.expectEqual(codepoints.len + 1, glyph_command_offsets.len);
    try std.testing.expectEqual(codepoints.len + 1, glyph_coord_offsets.len);
    try std.testing.expectEqual(codepoints.len, kern_row_for_left.len);
    try std.testing.expectEqual(glyph_commands.len, glyph_command_offsets[codepoints.len]);
    try std.testing.expectEqual(glyph_coords.len, glyph_coord_offsets[codepoints.len]);
    try std.testing.expectEqual(kern_rights.len, kern_adjustments.len);
    var index: usize = 1;
    while (index < codepoints.len) : (index += 1) {
        try std.testing.expect(codepoints[index - 1] < codepoints[index]);
    }
}
`;

writeFileSync(outputPath, output);
execFileSync("zig", ["fmt", outputPath], { stdio: "inherit" });
console.log(
  `packed ${outputPath}: ${glyphCount} glyphs, ${coords.length} coordinates, ` +
    `${kernPairs.length} kerning pairs in ${rowOffsets.length - 1} rows of ${kernRights.length} entries`,
);

function section(name) {
  const start = source.indexOf(`pub const ${name} = `);
  if (start < 0) throw new Error(`missing ${name}`);
  return source.slice(start, source.indexOf("\n};\n", start));
}

function arrayBody(name, type) {
  const text = section(name);
  const prefix = `pub const ${name} = [_]${type}{\n`;
  if (!text.startsWith(prefix)) throw new Error(`unexpected ${name} declaration`);
  return text.slice(prefix.length);
}

function decodePath(commands, values) {
  const tokens = [];
  let valueIndex = 0;
  for (const command of commands) {
    tokens.push(command);
    for (let arg = 0; arg < commandArgs[command]; arg += 1) {
      tokens.push(String(values[valueIndex] / 2));
      valueIndex += 1;
    }
  }
  return tokens.join(" ");
}

function formatValues(values, perLine) {
  const lines = [];
  for (let index = 0; index < values.length; index += perLine) {
    lines.push(`    ${values.slice(index, index + perLine).join(", ")},`);
  }
  return lines.join("\n");
}
