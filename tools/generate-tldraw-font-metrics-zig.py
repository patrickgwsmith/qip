#!/usr/bin/env python3
"""Generate compact metric and shaping tables for tldraw bundled fonts."""

from pathlib import Path
import sys

try:
    from fontTools.ttLib import TTFont
except ImportError as exc:
    raise SystemExit("fontTools is required: python3 -m pip install fonttools") from exc


EXTRA_CODEPOINTS = [
    0x2013,
    0x2014,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2026,
    0x2032,
    0x2033,
    0x2039,
    0x203A,
    0x20AC,
    0x2122,
    0x2212,
]

REQUESTED_CODEPOINTS = [
    *range(0x20, 0x7F),
    *(cp for cp in range(0xA0, 0x100) if cp != 0xAD),
    *EXTRA_CODEPOINTS,
]

VARIANT_DEFAULT = 0
VARIANT_LOOKUP_60 = 1
VARIANT_LOOKUP_61 = 2
VARIANT_LOOKUP_62 = 3
LIGATURE_PAIR_CODEPOINT_BASE = 0xF0000


def main() -> None:
    pair_mode = "expanded"
    args = sys.argv[1:]
    if args and args[0].startswith("--pair-mode="):
        pair_mode = args.pop(0).split("=", 1)[1]
    if pair_mode not in {"expanded", "compact", "packed"}:
        raise SystemExit("pair mode must be expanded, compact, or packed")
    if len(args) != 3:
        raise SystemExit(
            "usage: tools/generate-tldraw-font-metrics-zig.py [--pair-mode=expanded|compact|packed] FONT.ttf NAME OUTPUT.zig"
        )
    font_path = Path(args[0])
    font_name = args[1]
    output_path = Path(args[2])

    font = TTFont(font_path)
    cmap = font.getBestCmap()
    units_per_em = font["head"].unitsPerEm
    ascender = font["hhea"].ascent
    descender = font["hhea"].descent
    line_gap = font["hhea"].lineGap

    missing = [cp for cp in REQUESTED_CODEPOINTS if cp not in cmap]
    if missing:
        formatted = ", ".join(hex_codepoint(cp) for cp in missing)
        raise SystemExit(f"{font_path} is missing requested codepoints: {formatted}")

    profile = "shantell" if font_name == "tldraw_draw" else "simple"
    variant_glyphs = collect_variant_glyphs(font, cmap, profile)
    glyph_name_to_states = collect_glyph_name_to_states(variant_glyphs)
    default_rows, variant_rows = collect_metric_rows(font, variant_glyphs)
    coverage_rows, coverage_spans, context_rules = collect_context_rules(
        font, glyph_name_to_states, profile
    )
    ligature_components, ligature_spans, ligature_rules, ligature_glyph_states = collect_ligature_rules(
        font, cmap, profile
    )
    pair_glyph_name_to_states = {
        glyph_name: list(states) for glyph_name, states in glyph_name_to_states.items()
    }
    for glyph_name, state in ligature_glyph_states.items():
        pair_glyph_name_to_states.setdefault(glyph_name, []).append(state)
    if pair_mode in {"compact", "packed"}:
        pair_adjustments = []
        compact_pairs = collect_compact_pair_lookups(
            font, pair_glyph_name_to_states, pack_exact=(pair_mode == "packed")
        )
    else:
        pair_adjustments = collect_pair_adjustments(font, pair_glyph_name_to_states)
        compact_pairs = empty_compact_pairs()

    output_path.write_text(
        f"""// Generated from {font_path.name} by tools/generate-tldraw-font-metrics-zig.py.
// Font: {font_name}
// Coverage: U+0020..U+007E, U+00A0..U+00FF except U+00AD, plus selected punctuation.
// Metrics model Chrome/tldraw shaping for the bundled font profile:
// cmap glyph metrics, optional required/contextual substitutions, optional
// ligatures, GPOS pair adjustments, and native-font bounding boxes.

pub const FONT_NAME = "{font_name}";
pub const UNITS_PER_EM: i32 = {units_per_em};
pub const ASCENDER: i32 = {ascender};
pub const DESCENDER: i32 = {descender};
pub const LINE_GAP: i32 = {line_gap};

pub const GlyphMetrics = struct {{
    codepoint: u32,
    variant: u8,
    advance_x: i32,
    left_side_bearing: i32,
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,
}};

pub const CoverageGlyph = struct {{
    codepoint: u32,
    variant: u8,
}};

pub const CoverageSpan = struct {{
    start: u32,
    len: u16,
}};

pub const ContextRule = struct {{
    input_coverage: u16,
    backtrack_0: u16,
    backtrack_1: u16,
    backtrack_2: u16,
    backtrack_len: u8,
    result_variant: u8,
}};

pub const PairAdjustment = struct {{
    left: u32,
    right: u32,
    left_variant: u8,
    right_variant: u8,
    advance_x: i16,
}};

pub const PairLookup = struct {{
    start: u32,
    len: u16,
}};

pub const PairSubtable = struct {{
    kind: u8,
    start: u32,
    len: u32,
}};

pub const PairClassSubtable = struct {{
    left_start: u32,
    left_len: u16,
    right_start: u32,
    right_len: u16,
    value_start: u32,
    class_1_count: u16,
    class_2_count: u16,
}};

pub const PairClassGlyph = struct {{
    codepoint: u32,
    variant: u8,
    class: u16,
}};

pub const PairStateGlyph = struct {{
    codepoint: u32,
    variant: u8,
}};

pub const PairExactPackedAdjustment = struct {{
    key: u32,
    advance_x: i16,
}};

pub const LigatureSpan = struct {{
    start: u32,
    len: u8,
}};

pub const LigatureRule = struct {{
    span: u16,
    pair_codepoint: u32,
    advance_x: i32,
}};

pub const glyphs = [_]GlyphMetrics{{
{format_metric_rows(default_rows)}
}};

pub const variant_glyphs = [_]GlyphMetrics{{
{format_metric_rows(variant_rows)}
}};

pub const coverage_glyphs = [_]CoverageGlyph{{
{format_coverage_rows(coverage_rows)}
}};

pub const coverage_spans = [_]CoverageSpan{{
{format_coverage_spans(coverage_spans)}
}};

pub const context_rules = [_]ContextRule{{
{format_context_rules(context_rules)}
}};

pub const ligature_components = [_]u32{{
{format_ligature_components(ligature_components)}
}};

pub const ligature_spans = [_]LigatureSpan{{
{format_ligature_spans(ligature_spans)}
}};

pub const ligature_rules = [_]LigatureRule{{
{format_ligature_rules(ligature_rules)}
}};

pub const pair_adjustments = [_]PairAdjustment{{
{format_pair_adjustments(pair_adjustments)}
}};

pub const pair_lookups = [_]PairLookup{{
{format_pair_lookups(compact_pairs["lookups"])}
}};

pub const pair_subtables = [_]PairSubtable{{
{format_pair_subtables(compact_pairs["subtables"])}
}};

pub const pair_states = [_]PairStateGlyph{{
{format_pair_states(compact_pairs["states"])}
}};

pub const pair_exact_adjustments = [_]PairAdjustment{{
{format_pair_adjustments(compact_pairs["exact_adjustments"])}
}};

pub const pair_exact_packed_adjustments = [_]PairExactPackedAdjustment{{
{format_pair_exact_packed_adjustments(compact_pairs["exact_packed_adjustments"])}
}};

pub const pair_class_subtables = [_]PairClassSubtable{{
{format_pair_class_subtables(compact_pairs["class_subtables"])}
}};

pub const pair_left_classes = [_]PairClassGlyph{{
{format_pair_class_glyphs(compact_pairs["left_classes"])}
}};

pub const pair_right_classes = [_]PairClassGlyph{{
{format_pair_class_glyphs(compact_pairs["right_classes"])}
}};

pub const pair_class_values = [_]i16{{
{format_i16_values(compact_pairs["class_values"])}
}};

pub fn glyphIndex(codepoint: u32) ?usize {{
    var low: usize = 0;
    var high: usize = glyphs.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        if (codepoint < glyphs[middle].codepoint) {{
            high = middle;
        }} else if (codepoint > glyphs[middle].codepoint) {{
            low = middle + 1;
        }} else {{
            return middle;
        }}
    }}
    return null;
}}

pub fn glyphMetrics(codepoint: u32, variant: u8) ?GlyphMetrics {{
    if (variant == 0) {{
        const index = glyphIndex(codepoint) orelse return null;
        return glyphs[index];
    }}
    if (variant_glyphs.len == 0) return null;
    const key = glyphKey(codepoint, variant);
    var low: usize = 0;
    var high: usize = variant_glyphs.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(variant_glyphs[middle].codepoint, variant_glyphs[middle].variant);
        if (key < middle_key) {{
            high = middle;
        }} else if (key > middle_key) {{
            low = middle + 1;
        }} else {{
            return variant_glyphs[middle];
        }}
    }}
    return null;
}}

pub fn coverageContains(coverage_index: u16, codepoint: u32, variant: u8) bool {{
    if (coverage_spans.len == 0) return false;
    const span = coverage_spans[coverage_index];
    const target = glyphKey(codepoint, variant);
    var low: usize = span.start;
    var high: usize = span.start + span.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(coverage_glyphs[middle].codepoint, coverage_glyphs[middle].variant);
        if (target < middle_key) {{
            high = middle;
        }} else if (target > middle_key) {{
            low = middle + 1;
        }} else {{
            return true;
        }}
    }}
    return false;
}}

pub fn pairAdvanceX(left: u32, left_variant: u8, right: u32, right_variant: u8) i32 {{
    if (pair_lookups.len != 0) {{
        var total: i32 = 0;
        for (pair_lookups) |lookup| {{
            if (pairLookupAdvance(lookup, left, left_variant, right, right_variant)) |advance_x| {{
                total += advance_x;
            }}
        }}
        return total;
    }}
    if (pair_adjustments.len == 0) return 0;
    const key = pairKey(left, left_variant, right, right_variant);
    var low: usize = 0;
    var high: usize = pair_adjustments.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = pairKey(
            pair_adjustments[middle].left,
            pair_adjustments[middle].left_variant,
            pair_adjustments[middle].right,
            pair_adjustments[middle].right_variant,
        );
        if (key < middle_key) {{
            high = middle;
        }} else if (key > middle_key) {{
            low = middle + 1;
        }} else {{
            return pair_adjustments[middle].advance_x;
        }}
    }}
    return 0;
}}

fn pairLookupAdvance(lookup: PairLookup, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {{
    if (pair_subtables.len == 0) return null;
    var index: usize = lookup.start;
    const end = lookup.start + lookup.len;
    while (index < end) : (index += 1) {{
        const subtable = pair_subtables[index];
        if (subtable.kind == 1) {{
            if (pairExactAdvance(subtable, left, left_variant, right, right_variant)) |advance_x| return advance_x;
        }} else if (subtable.kind == 3) {{
            if (pairExactPackedAdvance(subtable, left, left_variant, right, right_variant)) |advance_x| return advance_x;
        }} else if (subtable.kind == 2) {{
            if (pairClassAdvance(subtable, left, left_variant, right, right_variant)) |advance_x| return advance_x;
        }}
    }}
    return null;
}}

fn pairExactPackedAdvance(subtable: PairSubtable, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {{
    if (pair_states.len == 0 or pair_exact_packed_adjustments.len == 0) return null;
    const left_id = pairStateId(left, left_variant) orelse return null;
    const right_id = pairStateId(right, right_variant) orelse return null;
    const key = pairExactPackedKey(left_id, right_id);
    var low: usize = subtable.start;
    var high: usize = subtable.start + subtable.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = pair_exact_packed_adjustments[middle].key;
        if (key < middle_key) {{
            high = middle;
        }} else if (key > middle_key) {{
            low = middle + 1;
        }} else {{
            return pair_exact_packed_adjustments[middle].advance_x;
        }}
    }}
    return null;
}}

fn pairStateId(codepoint: u32, variant: u8) ?u16 {{
    if (pair_states.len == 0) return null;
    const key = glyphKey(codepoint, variant);
    var low: usize = 0;
    var high: usize = pair_states.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(pair_states[middle].codepoint, pair_states[middle].variant);
        if (key < middle_key) {{
            high = middle;
        }} else if (key > middle_key) {{
            low = middle + 1;
        }} else {{
            return @intCast(middle);
        }}
    }}
    return null;
}}

fn pairExactPackedKey(left_id: u16, right_id: u16) u32 {{
    return (@as(u32, left_id) << 16) | @as(u32, right_id);
}}

fn pairExactAdvance(subtable: PairSubtable, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {{
    if (pair_exact_adjustments.len == 0) return null;
    const key = pairKey(left, left_variant, right, right_variant);
    var low: usize = subtable.start;
    var high: usize = subtable.start + subtable.len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = pairKey(
            pair_exact_adjustments[middle].left,
            pair_exact_adjustments[middle].left_variant,
            pair_exact_adjustments[middle].right,
            pair_exact_adjustments[middle].right_variant,
        );
        if (key < middle_key) {{
            high = middle;
        }} else if (key > middle_key) {{
            low = middle + 1;
        }} else {{
            return pair_exact_adjustments[middle].advance_x;
        }}
    }}
    return null;
}}

fn pairClassAdvance(subtable: PairSubtable, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {{
    if (pair_class_subtables.len == 0 or pair_class_values.len == 0) return null;
    const table = pair_class_subtables[subtable.start];
    const left_class = pairClassGlyphClass(pair_left_classes[0..], table.left_start, table.left_len, left, left_variant) orelse return null;
    const right_class = pairClassGlyphClass(pair_right_classes[0..], table.right_start, table.right_len, right, right_variant) orelse 0;
    if (left_class >= table.class_1_count or right_class >= table.class_2_count) return null;
    const value_index = table.value_start + @as(u32, left_class) * table.class_2_count + right_class;
    return pair_class_values[value_index];
}}

fn pairClassGlyphClass(entries: []const PairClassGlyph, start: u32, len: u16, codepoint: u32, variant: u8) ?u16 {{
    if (entries.len == 0) return null;
    const key = glyphKey(codepoint, variant);
    var low: usize = start;
    var high: usize = start + len;
    while (low < high) {{
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(entries[middle].codepoint, entries[middle].variant);
        if (key < middle_key) {{
            high = middle;
        }} else if (key > middle_key) {{
            low = middle + 1;
        }} else {{
            return entries[middle].class;
        }}
    }}
    return null;
}}

pub fn ligatureMatches(rule_index: usize, codepoints: []const u32) bool {{
    if (ligature_rules.len == 0) return false;
    const span = ligature_spans[ligature_rules[rule_index].span];
    if (codepoints.len < span.len) return false;
    var index: usize = 0;
    while (index < span.len) : (index += 1) {{
        if (codepoints[index] != ligature_components[span.start + index]) return false;
    }}
    return true;
}}

fn glyphKey(codepoint: u32, variant: u8) u64 {{
    return (@as(u64, codepoint) << 8) | @as(u64, variant);
}}

fn pairKey(left: u32, left_variant: u8, right: u32, right_variant: u8) u64 {{
    return (@as(u64, left) << 40) |
        (@as(u64, right) << 8) |
        (@as(u64, left_variant) << 4) |
        @as(u64, right_variant);
}}

test "glyph table is sorted" {{
    const std = @import("std");
    var index: usize = 1;
    while (index < glyphs.len) : (index += 1) {{
        try std.testing.expect(glyphs[index - 1].codepoint < glyphs[index].codepoint);
    }}
}}

test "variant glyph table is sorted" {{
    const std = @import("std");
    var index: usize = 1;
    while (index < variant_glyphs.len) : (index += 1) {{
        const before = glyphKey(variant_glyphs[index - 1].codepoint, variant_glyphs[index - 1].variant);
        const after = glyphKey(variant_glyphs[index].codepoint, variant_glyphs[index].variant);
        try std.testing.expect(before < after);
    }}
}}

test "pair adjustment table is sorted" {{
    const std = @import("std");
    var index: usize = 1;
    while (index < pair_adjustments.len) : (index += 1) {{
        const before = pairKey(
            pair_adjustments[index - 1].left,
            pair_adjustments[index - 1].left_variant,
            pair_adjustments[index - 1].right,
            pair_adjustments[index - 1].right_variant,
        );
        const after = pairKey(
            pair_adjustments[index].left,
            pair_adjustments[index].left_variant,
            pair_adjustments[index].right,
            pair_adjustments[index].right_variant,
        );
        try std.testing.expect(before < after);
    }}
}}
""",
        encoding="utf-8",
    )


def collect_variant_glyphs(font: TTFont, cmap: dict[int, str], profile: str) -> dict[int, dict[int, str]]:
    if profile != "shantell":
        return {codepoint: {VARIANT_DEFAULT: cmap[codepoint]} for codepoint in REQUESTED_CODEPOINTS}

    lookups = font["GSUB"].table.LookupList.Lookup
    default_mapping = lookups[58].SubTable[0].mapping
    lookup_variant = {
        VARIANT_LOOKUP_60: lookups[60].SubTable[0].mapping,
        VARIANT_LOOKUP_61: lookups[61].SubTable[0].mapping,
        VARIANT_LOOKUP_62: lookups[62].SubTable[0].mapping,
    }

    result: dict[int, dict[int, str]] = {}
    for codepoint in REQUESTED_CODEPOINTS:
        base = cmap[codepoint]
        default = default_mapping.get(base, base)
        variants = {VARIANT_DEFAULT: default}
        for variant, mapping in lookup_variant.items():
            variants[variant] = mapping.get(default, default)
        result[codepoint] = variants
    return result


def collect_glyph_name_to_states(variant_glyphs: dict[int, dict[int, str]]) -> dict[str, list[tuple[int, int]]]:
    states: dict[str, set[tuple[int, int]]] = {}
    for codepoint, variants in variant_glyphs.items():
        for variant, glyph_name in variants.items():
            states.setdefault(glyph_name, set()).add((codepoint, variant))
    return {glyph: sorted(values) for glyph, values in states.items()}


def collect_metric_rows(font: TTFont, variant_glyphs: dict[int, dict[int, str]]) -> tuple[list[dict[str, int]], list[dict[str, int]]]:
    default_rows = []
    variant_rows = []
    seen_variants: set[tuple[int, int]] = set()
    for codepoint in REQUESTED_CODEPOINTS:
        for variant, glyph_name in sorted(variant_glyphs[codepoint].items()):
            row = metric_row(font, codepoint, variant, glyph_name)
            if variant == VARIANT_DEFAULT:
                default_rows.append(row)
            elif (codepoint, variant) not in seen_variants:
                variant_rows.append(row)
                seen_variants.add((codepoint, variant))
    default_rows.sort(key=lambda row: row["codepoint"])
    variant_rows.sort(key=lambda row: (row["codepoint"], row["variant"]))
    return default_rows, variant_rows


def metric_row(font: TTFont, codepoint: int, variant: int, glyph_name: str) -> dict[str, int]:
    advance, left_side_bearing = font["hmtx"].metrics[glyph_name]
    glyf = font["glyf"]
    glyph = glyf[glyph_name]
    if glyph.isComposite():
        glyph.recalcBounds(glyf)
    if glyph.numberOfContours == 0:
        x_min = y_min = x_max = y_max = 0
    else:
        x_min = int(glyph.xMin)
        y_min = int(glyph.yMin)
        x_max = int(glyph.xMax)
        y_max = int(glyph.yMax)
    return {
        "codepoint": codepoint,
        "variant": variant,
        "advance": int(advance),
        "left_side_bearing": int(left_side_bearing),
        "x_min": x_min,
        "y_min": y_min,
        "x_max": x_max,
        "y_max": y_max,
    }


def collect_context_rules(font: TTFont, glyph_name_to_states: dict[str, list[tuple[int, int]]], profile: str):
    if profile != "shantell":
        return [], [], []

    lookup = font["GSUB"].table.LookupList.Lookup[59]
    coverage_indexes: dict[tuple[tuple[int, int], ...], int] = {}
    coverage_rows: list[tuple[int, int]] = []
    coverage_spans: list[dict[str, int]] = []
    rules = []

    def coverage_index(coverage) -> int:
        states: set[tuple[int, int]] = set()
        for glyph_name in coverage.glyphs:
            states.update(glyph_name_to_states.get(glyph_name, []))
        key = tuple(sorted(states))
        if key not in coverage_indexes:
            coverage_indexes[key] = len(coverage_spans)
            coverage_spans.append({"start": len(coverage_rows), "len": len(key)})
            coverage_rows.extend(key)
        return coverage_indexes[key]

    lookup_to_variant = {
        60: VARIANT_LOOKUP_60,
        61: VARIANT_LOOKUP_61,
        62: VARIANT_LOOKUP_62,
    }
    for subtable in lookup.SubTable:
        record = subtable.SubstLookupRecord[0]
        result_variant = lookup_to_variant.get(record.LookupListIndex)
        if result_variant is None or record.SequenceIndex != 0:
            continue
        backtracks = [coverage_index(cov) for cov in subtable.BacktrackCoverage]
        while len(backtracks) < 3:
            backtracks.append(0)
        rules.append(
            {
                "input": coverage_index(subtable.InputCoverage[0]),
                "backtrack": backtracks,
                "backtrack_len": len(subtable.BacktrackCoverage),
                "result_variant": result_variant,
            }
        )
    return coverage_rows, coverage_spans, rules


def collect_ligature_rules(font: TTFont, cmap: dict[int, str], profile: str):
    if "GSUB" not in font:
        return [], [], [], {}

    glyph_to_codepoint = {glyph: codepoint for codepoint, glyph in cmap.items()}
    hmtx = font["hmtx"].metrics
    lookups = font["GSUB"].table.LookupList.Lookup
    rules = []

    if profile == "shantell":
        lookup_indices = [51, 52]
    else:
        lookup_indices = default_ligature_lookup_indices(font)

    for lookup_index in lookup_indices:
        lookup = lookups[lookup_index]
        if lookup.LookupType != 4:
            continue
        for subtable in lookup.SubTable:
            for first_glyph, ligatures in subtable.ligatures.items():
                for ligature in ligatures:
                    glyph_sequence = [first_glyph] + list(ligature.Component)
                    codepoints = []
                    for glyph_name in glyph_sequence:
                        codepoint = glyph_to_codepoint.get(glyph_name)
                        if codepoint is None or codepoint not in REQUESTED_CODEPOINTS:
                            break
                        codepoints.append(codepoint)
                    if len(codepoints) != len(glyph_sequence):
                        continue
                    advance, _ = hmtx[ligature.LigGlyph]
                    rules.append(
                        {
                            "codepoints": tuple(codepoints),
                            "ligature_glyph": ligature.LigGlyph,
                            "advance_x": int(advance),
                        }
                    )

    # Longest first, then deterministic lexical order.
    rules.sort(key=lambda row: (-len(row["codepoints"]), row["codepoints"]))
    ligature_glyph_states = {
        glyph_name: (LIGATURE_PAIR_CODEPOINT_BASE + index, 0)
        for index, glyph_name in enumerate(sorted({rule["ligature_glyph"] for rule in rules}))
    }
    components: list[int] = []
    spans = []
    output_rules = []
    for rule in rules:
        spans.append({"start": len(components), "len": len(rule["codepoints"])})
        components.extend(rule["codepoints"])
        output_rules.append(
            {
                "span": len(spans) - 1,
                "pair_codepoint": ligature_glyph_states[rule["ligature_glyph"]][0],
                "advance_x": rule["advance_x"],
            }
        )
    return components, spans, output_rules, ligature_glyph_states


def default_ligature_lookup_indices(font: TTFont) -> list[int]:
    indexes: list[int] = []
    for record in font["GSUB"].table.FeatureList.FeatureRecord:
        if record.FeatureTag in {"liga", "clig", "rlig"}:
            indexes.extend(record.Feature.LookupListIndex)
    return sorted(set(indexes))


def collect_pair_adjustments(font: TTFont, glyph_name_to_states: dict[str, list[tuple[int, int]]]) -> list[dict[str, int]]:
    pair_adjustments: dict[tuple[int, int, int, int], int] = {}
    lookup_indices: list[int] = []
    for record in font["GPOS"].table.FeatureList.FeatureRecord:
        if record.FeatureTag == "kern":
            lookup_indices.extend(record.Feature.LookupListIndex)

    lookups = font["GPOS"].table.LookupList.Lookup
    for lookup_index in lookup_indices:
        lookup = lookups[lookup_index]
        lookup_adjustments: dict[tuple[int, int, int, int], int] = {}
        for subtable in lookup.SubTable:
            if lookup.LookupType == 2:
                collect_pair_positioning(subtable, glyph_name_to_states, lookup_adjustments)
            elif lookup.LookupType == 9 and subtable.ExtensionLookupType == 2:
                collect_pair_positioning(subtable.ExtSubTable, glyph_name_to_states, lookup_adjustments)
        for key, advance_x in lookup_adjustments.items():
            pair_adjustments[key] = pair_adjustments.get(key, 0) + advance_x

    rows = [
        {
            "left": left,
            "left_variant": left_variant,
            "right": right,
            "right_variant": right_variant,
            "advance_x": advance_x,
        }
        for (left, left_variant, right, right_variant), advance_x in pair_adjustments.items()
        if advance_x != 0
    ]
    rows.sort(key=lambda row: (row["left"], row["right"], row["left_variant"], row["right_variant"]))
    return rows


def empty_compact_pairs() -> dict[str, list]:
    return {
        "lookups": [],
        "subtables": [],
        "states": [],
        "exact_adjustments": [],
        "exact_packed_adjustments": [],
        "class_subtables": [],
        "left_classes": [],
        "right_classes": [],
        "class_values": [],
    }


def collect_compact_pair_lookups(font: TTFont, glyph_name_to_states: dict[str, list[tuple[int, int]]], pack_exact: bool) -> dict[str, list]:
    compact = empty_compact_pairs()
    state_ids: dict[tuple[int, int], int] = {}
    if pack_exact:
        states = sorted({state for states in glyph_name_to_states.values() for state in states})
        compact["states"].extend({"codepoint": codepoint, "variant": variant} for codepoint, variant in states)
        state_ids.update({state: index for index, state in enumerate(states)})
    lookup_indices: list[int] = []
    if "GPOS" not in font:
        return compact
    for record in font["GPOS"].table.FeatureList.FeatureRecord:
        if record.FeatureTag == "kern":
            lookup_indices.extend(record.Feature.LookupListIndex)

    lookups = font["GPOS"].table.LookupList.Lookup
    for lookup_index in lookup_indices:
        lookup = lookups[lookup_index]
        lookup_start = len(compact["subtables"])
        for subtable in lookup.SubTable:
            if lookup.LookupType == 2:
                collect_compact_pair_subtable(subtable, glyph_name_to_states, compact, state_ids)
            elif lookup.LookupType == 9 and subtable.ExtensionLookupType == 2:
                collect_compact_pair_subtable(subtable.ExtSubTable, glyph_name_to_states, compact, state_ids)
        lookup_len = len(compact["subtables"]) - lookup_start
        if lookup_len:
            compact["lookups"].append({"start": lookup_start, "len": lookup_len})
    return compact


def collect_compact_pair_subtable(subtable, glyph_name_to_states: dict[str, list[tuple[int, int]]], compact: dict[str, list], state_ids: dict[tuple[int, int], int]) -> None:
    if subtable.Format == 1:
        rows: list[dict[str, int]] = []
        packed_rows: list[dict[str, int]] = []
        for left_glyph, pair_set in zip(subtable.Coverage.glyphs, subtable.PairSet):
            left_states = glyph_name_to_states.get(left_glyph, [])
            if not left_states:
                continue
            for record in pair_set.PairValueRecord:
                right_states = glyph_name_to_states.get(record.SecondGlyph, [])
                if not right_states:
                    continue
                advance_x = value_x_advance(record.Value1)
                for left, left_variant in left_states:
                    for right, right_variant in right_states:
                        if state_ids:
                            packed_rows.append(
                                {
                                    "key": (state_ids[(left, left_variant)] << 16) | state_ids[(right, right_variant)],
                                    "advance_x": advance_x,
                                }
                            )
                        else:
                            rows.append(
                                {
                                    "left": left,
                                    "left_variant": left_variant,
                                    "right": right,
                                    "right_variant": right_variant,
                                    "advance_x": advance_x,
                                }
                            )
        if state_ids:
            if not packed_rows:
                return
            packed_rows.sort(key=lambda row: row["key"])
            start = len(compact["exact_packed_adjustments"])
            compact["exact_packed_adjustments"].extend(packed_rows)
            compact["subtables"].append({"kind": 3, "start": start, "len": len(packed_rows)})
            return
        if not rows:
            return
        rows.sort(key=lambda row: (row["left"], row["right"], row["left_variant"], row["right_variant"]))
        start = len(compact["exact_adjustments"])
        compact["exact_adjustments"].extend(rows)
        compact["subtables"].append({"kind": 1, "start": start, "len": len(rows)})
    elif subtable.Format == 2:
        left_rows: list[dict[str, int]] = []
        for left_glyph in subtable.Coverage.glyphs:
            left_class = subtable.ClassDef1.classDefs.get(left_glyph, 0)
            for codepoint, variant in glyph_name_to_states.get(left_glyph, []):
                left_rows.append({"codepoint": codepoint, "variant": variant, "class": left_class})
        if not left_rows:
            return

        right_rows: list[dict[str, int]] = []
        for right_glyph, right_class in subtable.ClassDef2.classDefs.items():
            if right_class == 0:
                continue
            for codepoint, variant in glyph_name_to_states.get(right_glyph, []):
                right_rows.append({"codepoint": codepoint, "variant": variant, "class": right_class})

        left_rows.sort(key=lambda row: (row["codepoint"], row["variant"]))
        right_rows.sort(key=lambda row: (row["codepoint"], row["variant"]))

        left_start = len(compact["left_classes"])
        right_start = len(compact["right_classes"])
        value_start = len(compact["class_values"])
        compact["left_classes"].extend(left_rows)
        compact["right_classes"].extend(right_rows)

        class_1_count = len(subtable.Class1Record)
        class_2_count = max((len(record.Class2Record) for record in subtable.Class1Record), default=0)
        for class_1_record in subtable.Class1Record:
            for class_2_index in range(class_2_count):
                if class_2_index < len(class_1_record.Class2Record):
                    compact["class_values"].append(
                        value_x_advance(class_1_record.Class2Record[class_2_index].Value1)
                    )
                else:
                    compact["class_values"].append(0)

        class_start = len(compact["class_subtables"])
        compact["class_subtables"].append(
            {
                "left_start": left_start,
                "left_len": len(left_rows),
                "right_start": right_start,
                "right_len": len(right_rows),
                "value_start": value_start,
                "class_1_count": class_1_count,
                "class_2_count": class_2_count,
            }
        )
        compact["subtables"].append({"kind": 2, "start": class_start, "len": 1})


def collect_pair_positioning(subtable, glyph_name_to_states: dict[str, list[tuple[int, int]]], pair_adjustments: dict[tuple[int, int, int, int], int]) -> None:
    def put(left_glyph: str, right_glyph: str, advance_x: int) -> None:
        if advance_x == 0:
            return
        for left, left_variant in glyph_name_to_states.get(left_glyph, []):
            for right, right_variant in glyph_name_to_states.get(right_glyph, []):
                pair_adjustments.setdefault((left, left_variant, right, right_variant), advance_x)

    if subtable.Format == 1:
        for left_glyph, pair_set in zip(subtable.Coverage.glyphs, subtable.PairSet):
            for record in pair_set.PairValueRecord:
                put(left_glyph, record.SecondGlyph, value_x_advance(record.Value1))
    elif subtable.Format == 2:
        class_def_1 = subtable.ClassDef1.classDefs
        class_def_2 = subtable.ClassDef2.classDefs
        right_glyphs = list(glyph_name_to_states.keys())
        for left_glyph in subtable.Coverage.glyphs:
            left_class = class_def_1.get(left_glyph, 0)
            if left_class >= len(subtable.Class1Record):
                continue
            class_1_record = subtable.Class1Record[left_class]
            for right_glyph in right_glyphs:
                right_class = class_def_2.get(right_glyph, 0)
                if right_class >= len(class_1_record.Class2Record):
                    continue
                put(left_glyph, right_glyph, value_x_advance(class_1_record.Class2Record[right_class].Value1))


def value_x_advance(value) -> int:
    if value is None:
        return 0
    return int(getattr(value, "XAdvance", 0) or 0)


def format_metric_rows(rows: list[dict[str, int]]) -> str:
    lines = []
    for row in rows:
        lines.append(
            "    .{ "
            + f".codepoint = 0x{row['codepoint']:X}, "
            + f".variant = {row['variant']}, "
            + f".advance_x = {row['advance']}, "
            + f".left_side_bearing = {row['left_side_bearing']}, "
            + f".x_min = {row['x_min']}, "
            + f".y_min = {row['y_min']}, "
            + f".x_max = {row['x_max']}, "
            + f".y_max = {row['y_max']} "
            + f"}}, // {hex_codepoint(row['codepoint'])}"
        )
    return "\n".join(lines)


def format_coverage_rows(rows: list[tuple[int, int]]) -> str:
    return "\n".join(
        f"    .{{ .codepoint = 0x{codepoint:X}, .variant = {variant} }},"
        for codepoint, variant in rows
    )


def format_coverage_spans(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .start = {row['start']}, .len = {row['len']} }},"
        for row in rows
    )


def format_context_rules(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        "    .{ "
        + f".input_coverage = {row['input']}, "
        + f".backtrack_0 = {row['backtrack'][0]}, "
        + f".backtrack_1 = {row['backtrack'][1]}, "
        + f".backtrack_2 = {row['backtrack'][2]}, "
        + f".backtrack_len = {row['backtrack_len']}, "
        + f".result_variant = {row['result_variant']} "
        + "},"
        for row in rows
    )


def format_ligature_components(rows: list[int]) -> str:
    return "\n".join(f"    0x{codepoint:X}," for codepoint in rows)


def format_ligature_spans(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .start = {row['start']}, .len = {row['len']} }},"
        for row in rows
    )


def format_ligature_rules(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .span = {row['span']}, .pair_codepoint = 0x{row['pair_codepoint']:X}, .advance_x = {row['advance_x']} }},"
        for row in rows
    )


def format_pair_adjustments(rows: list[dict[str, int]]) -> str:
    lines = []
    for row in rows:
        lines.append(
            "    .{ "
            + f".left = 0x{row['left']:X}, "
            + f".right = 0x{row['right']:X}, "
            + f".left_variant = {row['left_variant']}, "
            + f".right_variant = {row['right_variant']}, "
            + f".advance_x = {row['advance_x']} "
            + f"}}, // {hex_codepoint(row['left'])} {hex_codepoint(row['right'])}"
        )
    return "\n".join(lines)


def format_pair_lookups(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .start = {row['start']}, .len = {row['len']} }},"
        for row in rows
    )


def format_pair_subtables(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .kind = {row['kind']}, .start = {row['start']}, .len = {row['len']} }},"
        for row in rows
    )


def format_pair_states(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .codepoint = 0x{row['codepoint']:X}, .variant = {row['variant']} }},"
        for row in rows
    )


def format_pair_exact_packed_adjustments(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .key = 0x{row['key']:08X}, .advance_x = {row['advance_x']} }},"
        for row in rows
    )


def format_pair_class_subtables(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        "    .{ "
        + f".left_start = {row['left_start']}, "
        + f".left_len = {row['left_len']}, "
        + f".right_start = {row['right_start']}, "
        + f".right_len = {row['right_len']}, "
        + f".value_start = {row['value_start']}, "
        + f".class_1_count = {row['class_1_count']}, "
        + f".class_2_count = {row['class_2_count']} "
        + "},"
        for row in rows
    )


def format_pair_class_glyphs(rows: list[dict[str, int]]) -> str:
    return "\n".join(
        f"    .{{ .codepoint = 0x{row['codepoint']:X}, .variant = {row['variant']}, .class = {row['class']} }},"
        for row in rows
    )


def format_i16_values(rows: list[int]) -> str:
    return "\n".join(f"    {value}," for value in rows)


def hex_codepoint(codepoint: int) -> str:
    width = 4 if codepoint <= 0xFFFF else 6
    return f"U+{codepoint:0{width}X}"


if __name__ == "__main__":
    main()
