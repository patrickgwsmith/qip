// Generated from IBMPlexMono-Medium.woff2 by tools/generate-tldraw-font-metrics-zig.py.
// Font: tldraw_mono
// Coverage: U+0020..U+007E, U+00A0..U+00FF except U+00AD, plus selected punctuation.
// Metrics model Chrome/tldraw shaping for the bundled font profile:
// cmap glyph metrics, optional required/contextual substitutions, optional
// ligatures, GPOS pair adjustments, and native-font bounding boxes.

pub const FONT_NAME = "tldraw_mono";
pub const UNITS_PER_EM: i32 = 1000;
pub const ASCENDER: i32 = 1025;
pub const DESCENDER: i32 = -275;
pub const LINE_GAP: i32 = 0;

pub const GlyphMetrics = struct {
    codepoint: u32,
    variant: u8,
    advance_x: i32,
    left_side_bearing: i32,
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,
};

pub const CoverageGlyph = struct {
    codepoint: u32,
    variant: u8,
};

pub const CoverageSpan = struct {
    start: u32,
    len: u16,
};

pub const ContextRule = struct {
    input_coverage: u16,
    backtrack_0: u16,
    backtrack_1: u16,
    backtrack_2: u16,
    backtrack_len: u8,
    result_variant: u8,
};

pub const PairAdjustment = struct {
    left: u32,
    right: u32,
    left_variant: u8,
    right_variant: u8,
    advance_x: i16,
};

pub const PairLookup = struct {
    start: u32,
    len: u16,
};

pub const PairSubtable = struct {
    kind: u8,
    start: u32,
    len: u32,
};

pub const PairClassSubtable = struct {
    left_start: u32,
    left_len: u16,
    right_start: u32,
    right_len: u16,
    value_start: u32,
    class_1_count: u16,
    class_2_count: u16,
};

pub const PairClassGlyph = struct {
    codepoint: u32,
    variant: u8,
    class: u16,
};

pub const PairStateGlyph = struct {
    codepoint: u32,
    variant: u8,
};

pub const PairExactPackedAdjustment = struct {
    key: u32,
    advance_x: i16,
};

pub const LigatureSpan = struct {
    start: u32,
    len: u8,
};

pub const LigatureRule = struct {
    span: u16,
    pair_codepoint: u32,
    advance_x: i32,
};

pub const glyphs = [_]GlyphMetrics{
    .{ .codepoint = 0x20, .variant = 0, .advance_x = 600, .left_side_bearing = 0, .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 }, // U+0020
    .{ .codepoint = 0x21, .variant = 0, .advance_x = 600, .left_side_bearing = 216, .x_min = 216, .y_min = -10, .x_max = 384, .y_max = 698 }, // U+0021
    .{ .codepoint = 0x22, .variant = 0, .advance_x = 600, .left_side_bearing = 152, .x_min = 152, .y_min = 442, .x_max = 449, .y_max = 740 }, // U+0022
    .{ .codepoint = 0x23, .variant = 0, .advance_x = 600, .left_side_bearing = 13, .x_min = 13, .y_min = 0, .x_max = 587, .y_max = 698 }, // U+0023
    .{ .codepoint = 0x24, .variant = 0, .advance_x = 600, .left_side_bearing = 43, .x_min = 43, .y_min = -113, .x_max = 559, .y_max = 811 }, // U+0024
    .{ .codepoint = 0x25, .variant = 0, .advance_x = 600, .left_side_bearing = 11, .x_min = 11, .y_min = -12, .x_max = 589, .y_max = 710 }, // U+0025
    .{ .codepoint = 0x26, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = -12, .x_max = 583, .y_max = 710 }, // U+0026
    .{ .codepoint = 0x27, .variant = 0, .advance_x = 600, .left_side_bearing = 250, .x_min = 250, .y_min = 442, .x_max = 350, .y_max = 740 }, // U+0027
    .{ .codepoint = 0x28, .variant = 0, .advance_x = 600, .left_side_bearing = 192, .x_min = 192, .y_min = -138, .x_max = 509, .y_max = 760 }, // U+0028
    .{ .codepoint = 0x29, .variant = 0, .advance_x = 600, .left_side_bearing = 91, .x_min = 91, .y_min = -138, .x_max = 408, .y_max = 760 }, // U+0029
    .{ .codepoint = 0x2A, .variant = 0, .advance_x = 600, .left_side_bearing = 38, .x_min = 38, .y_min = 48, .x_max = 562, .y_max = 549 }, // U+002A
    .{ .codepoint = 0x2B, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 62, .x_max = 538, .y_max = 549 }, // U+002B
    .{ .codepoint = 0x2C, .variant = 0, .advance_x = 600, .left_side_bearing = 190, .x_min = 190, .y_min = -145, .x_max = 399, .y_max = 152 }, // U+002C
    .{ .codepoint = 0x2D, .variant = 0, .advance_x = 600, .left_side_bearing = 149, .x_min = 149, .y_min = 250, .x_max = 451, .y_max = 359 }, // U+002D
    .{ .codepoint = 0x2E, .variant = 0, .advance_x = 600, .left_side_bearing = 213, .x_min = 213, .y_min = -10, .x_max = 387, .y_max = 154 }, // U+002E
    .{ .codepoint = 0x2F, .variant = 0, .advance_x = 600, .left_side_bearing = 83, .x_min = 83, .y_min = -138, .x_max = 517, .y_max = 760 }, // U+002F
    .{ .codepoint = 0x30, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 710 }, // U+0030
    .{ .codepoint = 0x31, .variant = 0, .advance_x = 600, .left_side_bearing = 45, .x_min = 45, .y_min = 0, .x_max = 565, .y_max = 698 }, // U+0031
    .{ .codepoint = 0x32, .variant = 0, .advance_x = 600, .left_side_bearing = 54, .x_min = 54, .y_min = 0, .x_max = 545, .y_max = 710 }, // U+0032
    .{ .codepoint = 0x33, .variant = 0, .advance_x = 600, .left_side_bearing = 38, .x_min = 38, .y_min = -12, .x_max = 534, .y_max = 710 }, // U+0033
    .{ .codepoint = 0x34, .variant = 0, .advance_x = 600, .left_side_bearing = 30, .x_min = 30, .y_min = 0, .x_max = 567, .y_max = 698 }, // U+0034
    .{ .codepoint = 0x35, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 547, .y_max = 698 }, // U+0035
    .{ .codepoint = 0x36, .variant = 0, .advance_x = 600, .left_side_bearing = 53, .x_min = 53, .y_min = -12, .x_max = 550, .y_max = 698 }, // U+0036
    .{ .codepoint = 0x37, .variant = 0, .advance_x = 600, .left_side_bearing = 59, .x_min = 59, .y_min = 0, .x_max = 540, .y_max = 698 }, // U+0037
    .{ .codepoint = 0x38, .variant = 0, .advance_x = 600, .left_side_bearing = 47, .x_min = 47, .y_min = -12, .x_max = 553, .y_max = 710 }, // U+0038
    .{ .codepoint = 0x39, .variant = 0, .advance_x = 600, .left_side_bearing = 50, .x_min = 50, .y_min = 0, .x_max = 547, .y_max = 710 }, // U+0039
    .{ .codepoint = 0x3A, .variant = 0, .advance_x = 600, .left_side_bearing = 213, .x_min = 213, .y_min = -10, .x_max = 387, .y_max = 526 }, // U+003A
    .{ .codepoint = 0x3B, .variant = 0, .advance_x = 600, .left_side_bearing = 190, .x_min = 190, .y_min = -145, .x_max = 399, .y_max = 526 }, // U+003B
    .{ .codepoint = 0x3C, .variant = 0, .advance_x = 600, .left_side_bearing = 85, .x_min = 85, .y_min = 12, .x_max = 515, .y_max = 598 }, // U+003C
    .{ .codepoint = 0x3D, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 155, .x_max = 538, .y_max = 456 }, // U+003D
    .{ .codepoint = 0x3E, .variant = 0, .advance_x = 600, .left_side_bearing = 85, .x_min = 85, .y_min = 12, .x_max = 515, .y_max = 598 }, // U+003E
    .{ .codepoint = 0x3F, .variant = 0, .advance_x = 600, .left_side_bearing = 70, .x_min = 70, .y_min = -10, .x_max = 517, .y_max = 710 }, // U+003F
    .{ .codepoint = 0x40, .variant = 0, .advance_x = 600, .left_side_bearing = 52, .x_min = 52, .y_min = -112, .x_max = 537, .y_max = 710 }, // U+0040
    .{ .codepoint = 0x41, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 698 }, // U+0041
    .{ .codepoint = 0x42, .variant = 0, .advance_x = 600, .left_side_bearing = 83, .x_min = 83, .y_min = 0, .x_max = 548, .y_max = 698 }, // U+0042
    .{ .codepoint = 0x43, .variant = 0, .advance_x = 600, .left_side_bearing = 58, .x_min = 58, .y_min = -12, .x_max = 549, .y_max = 710 }, // U+0043
    .{ .codepoint = 0x44, .variant = 0, .advance_x = 600, .left_side_bearing = 82, .x_min = 82, .y_min = 0, .x_max = 553, .y_max = 698 }, // U+0044
    .{ .codepoint = 0x45, .variant = 0, .advance_x = 600, .left_side_bearing = 86, .x_min = 86, .y_min = 0, .x_max = 523, .y_max = 698 }, // U+0045
    .{ .codepoint = 0x46, .variant = 0, .advance_x = 600, .left_side_bearing = 86, .x_min = 86, .y_min = 0, .x_max = 535, .y_max = 698 }, // U+0046
    .{ .codepoint = 0x47, .variant = 0, .advance_x = 600, .left_side_bearing = 47, .x_min = 47, .y_min = -12, .x_max = 532, .y_max = 710 }, // U+0047
    .{ .codepoint = 0x48, .variant = 0, .advance_x = 600, .left_side_bearing = 72, .x_min = 72, .y_min = 0, .x_max = 528, .y_max = 698 }, // U+0048
    .{ .codepoint = 0x49, .variant = 0, .advance_x = 600, .left_side_bearing = 80, .x_min = 80, .y_min = 0, .x_max = 520, .y_max = 698 }, // U+0049
    .{ .codepoint = 0x4A, .variant = 0, .advance_x = 600, .left_side_bearing = 59, .x_min = 59, .y_min = -12, .x_max = 493, .y_max = 698 }, // U+004A
    .{ .codepoint = 0x4B, .variant = 0, .advance_x = 600, .left_side_bearing = 78, .x_min = 78, .y_min = 0, .x_max = 589, .y_max = 698 }, // U+004B
    .{ .codepoint = 0x4C, .variant = 0, .advance_x = 600, .left_side_bearing = 108, .x_min = 108, .y_min = 0, .x_max = 538, .y_max = 698 }, // U+004C
    .{ .codepoint = 0x4D, .variant = 0, .advance_x = 600, .left_side_bearing = 56, .x_min = 56, .y_min = 0, .x_max = 544, .y_max = 698 }, // U+004D
    .{ .codepoint = 0x4E, .variant = 0, .advance_x = 600, .left_side_bearing = 72, .x_min = 72, .y_min = 0, .x_max = 528, .y_max = 698 }, // U+004E
    .{ .codepoint = 0x4F, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 710 }, // U+004F
    .{ .codepoint = 0x50, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = 0, .x_max = 550, .y_max = 698 }, // U+0050
    .{ .codepoint = 0x51, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -175, .x_max = 556, .y_max = 710 }, // U+0051
    .{ .codepoint = 0x52, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = 0, .x_max = 560, .y_max = 698 }, // U+0052
    .{ .codepoint = 0x53, .variant = 0, .advance_x = 600, .left_side_bearing = 39, .x_min = 39, .y_min = -12, .x_max = 548, .y_max = 710 }, // U+0053
    .{ .codepoint = 0x54, .variant = 0, .advance_x = 600, .left_side_bearing = 25, .x_min = 25, .y_min = 0, .x_max = 575, .y_max = 698 }, // U+0054
    .{ .codepoint = 0x55, .variant = 0, .advance_x = 600, .left_side_bearing = 69, .x_min = 69, .y_min = -12, .x_max = 531, .y_max = 698 }, // U+0055
    .{ .codepoint = 0x56, .variant = 0, .advance_x = 600, .left_side_bearing = 25, .x_min = 25, .y_min = 0, .x_max = 575, .y_max = 698 }, // U+0056
    .{ .codepoint = 0x57, .variant = 0, .advance_x = 600, .left_side_bearing = 25, .x_min = 25, .y_min = 0, .x_max = 575, .y_max = 698 }, // U+0057
    .{ .codepoint = 0x58, .variant = 0, .advance_x = 600, .left_side_bearing = 19, .x_min = 19, .y_min = 0, .x_max = 582, .y_max = 698 }, // U+0058
    .{ .codepoint = 0x59, .variant = 0, .advance_x = 600, .left_side_bearing = 12, .x_min = 12, .y_min = 0, .x_max = 588, .y_max = 698 }, // U+0059
    .{ .codepoint = 0x5A, .variant = 0, .advance_x = 600, .left_side_bearing = 48, .x_min = 48, .y_min = 0, .x_max = 552, .y_max = 698 }, // U+005A
    .{ .codepoint = 0x5B, .variant = 0, .advance_x = 600, .left_side_bearing = 207, .x_min = 207, .y_min = -138, .x_max = 506, .y_max = 760 }, // U+005B
    .{ .codepoint = 0x5C, .variant = 0, .advance_x = 600, .left_side_bearing = 83, .x_min = 83, .y_min = -138, .x_max = 517, .y_max = 760 }, // U+005C
    .{ .codepoint = 0x5D, .variant = 0, .advance_x = 600, .left_side_bearing = 94, .x_min = 94, .y_min = -138, .x_max = 393, .y_max = 760 }, // U+005D
    .{ .codepoint = 0x5E, .variant = 0, .advance_x = 600, .left_side_bearing = 37, .x_min = 37, .y_min = 267, .x_max = 563, .y_max = 698 }, // U+005E
    .{ .codepoint = 0x5F, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -179, .x_max = 540, .y_max = -85 }, // U+005F
    .{ .codepoint = 0x60, .variant = 0, .advance_x = 600, .left_side_bearing = 171, .x_min = 171, .y_min = 579, .x_max = 356, .y_max = 791 }, // U+0060
    .{ .codepoint = 0x61, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 528 }, // U+0061
    .{ .codepoint = 0x62, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -12, .x_max = 549, .y_max = 740 }, // U+0062
    .{ .codepoint = 0x63, .variant = 0, .advance_x = 600, .left_side_bearing = 74, .x_min = 74, .y_min = -12, .x_max = 527, .y_max = 528 }, // U+0063
    .{ .codepoint = 0x64, .variant = 0, .advance_x = 600, .left_side_bearing = 51, .x_min = 51, .y_min = -12, .x_max = 521, .y_max = 740 }, // U+0064
    .{ .codepoint = 0x65, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 540, .y_max = 528 }, // U+0065
    .{ .codepoint = 0x66, .variant = 0, .advance_x = 600, .left_side_bearing = 68, .x_min = 68, .y_min = 0, .x_max = 549, .y_max = 740 }, // U+0066
    .{ .codepoint = 0x67, .variant = 0, .advance_x = 600, .left_side_bearing = 59, .x_min = 59, .y_min = -212, .x_max = 570, .y_max = 598 }, // U+0067
    .{ .codepoint = 0x68, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = 0, .x_max = 521, .y_max = 740 }, // U+0068
    .{ .codepoint = 0x69, .variant = 0, .advance_x = 600, .left_side_bearing = 101, .x_min = 101, .y_min = 0, .x_max = 551, .y_max = 749 }, // U+0069
    .{ .codepoint = 0x6A, .variant = 0, .advance_x = 600, .left_side_bearing = 92, .x_min = 92, .y_min = -200, .x_max = 455, .y_max = 749 }, // U+006A
    .{ .codepoint = 0x6B, .variant = 0, .advance_x = 600, .left_side_bearing = 88, .x_min = 88, .y_min = 0, .x_max = 580, .y_max = 740 }, // U+006B
    .{ .codepoint = 0x6C, .variant = 0, .advance_x = 600, .left_side_bearing = 75, .x_min = 75, .y_min = 0, .x_max = 526, .y_max = 740 }, // U+006C
    .{ .codepoint = 0x6D, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = 0, .x_max = 555, .y_max = 528 }, // U+006D
    .{ .codepoint = 0x6E, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = 0, .x_max = 521, .y_max = 528 }, // U+006E
    .{ .codepoint = 0x6F, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 528 }, // U+006F
    .{ .codepoint = 0x70, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -200, .x_max = 549, .y_max = 528 }, // U+0070
    .{ .codepoint = 0x71, .variant = 0, .advance_x = 600, .left_side_bearing = 51, .x_min = 51, .y_min = -200, .x_max = 521, .y_max = 528 }, // U+0071
    .{ .codepoint = 0x72, .variant = 0, .advance_x = 600, .left_side_bearing = 76, .x_min = 76, .y_min = 0, .x_max = 560, .y_max = 516 }, // U+0072
    .{ .codepoint = 0x73, .variant = 0, .advance_x = 600, .left_side_bearing = 59, .x_min = 59, .y_min = -12, .x_max = 528, .y_max = 528 }, // U+0073
    .{ .codepoint = 0x74, .variant = 0, .advance_x = 600, .left_side_bearing = 40, .x_min = 40, .y_min = 0, .x_max = 528, .y_max = 698 }, // U+0074
    .{ .codepoint = 0x75, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -12, .x_max = 516, .y_max = 516 }, // U+0075
    .{ .codepoint = 0x76, .variant = 0, .advance_x = 600, .left_side_bearing = 48, .x_min = 48, .y_min = 0, .x_max = 552, .y_max = 516 }, // U+0076
    .{ .codepoint = 0x77, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 580, .y_max = 516 }, // U+0077
    .{ .codepoint = 0x78, .variant = 0, .advance_x = 600, .left_side_bearing = 45, .x_min = 45, .y_min = 0, .x_max = 556, .y_max = 516 }, // U+0078
    .{ .codepoint = 0x79, .variant = 0, .advance_x = 600, .left_side_bearing = 39, .x_min = 39, .y_min = -200, .x_max = 561, .y_max = 516 }, // U+0079
    .{ .codepoint = 0x7A, .variant = 0, .advance_x = 600, .left_side_bearing = 77, .x_min = 77, .y_min = 0, .x_max = 523, .y_max = 516 }, // U+007A
    .{ .codepoint = 0x7B, .variant = 0, .advance_x = 600, .left_side_bearing = 100, .x_min = 100, .y_min = -138, .x_max = 500, .y_max = 760 }, // U+007B
    .{ .codepoint = 0x7C, .variant = 0, .advance_x = 600, .left_side_bearing = 253, .x_min = 253, .y_min = -138, .x_max = 347, .y_max = 760 }, // U+007C
    .{ .codepoint = 0x7D, .variant = 0, .advance_x = 600, .left_side_bearing = 100, .x_min = 100, .y_min = -138, .x_max = 500, .y_max = 760 }, // U+007D
    .{ .codepoint = 0x7E, .variant = 0, .advance_x = 600, .left_side_bearing = 45, .x_min = 45, .y_min = 187, .x_max = 555, .y_max = 423 }, // U+007E
    .{ .codepoint = 0xA0, .variant = 0, .advance_x = 600, .left_side_bearing = 0, .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 }, // U+00A0
    .{ .codepoint = 0xA1, .variant = 0, .advance_x = 600, .left_side_bearing = 216, .x_min = 216, .y_min = -182, .x_max = 384, .y_max = 526 }, // U+00A1
    .{ .codepoint = 0xA2, .variant = 0, .advance_x = 600, .left_side_bearing = 74, .x_min = 74, .y_min = -114, .x_max = 527, .y_max = 630 }, // U+00A2
    .{ .codepoint = 0xA3, .variant = 0, .advance_x = 600, .left_side_bearing = 49, .x_min = 49, .y_min = 0, .x_max = 554, .y_max = 710 }, // U+00A3
    .{ .codepoint = 0xA4, .variant = 0, .advance_x = 600, .left_side_bearing = 63, .x_min = 63, .y_min = 19, .x_max = 537, .y_max = 679 }, // U+00A4
    .{ .codepoint = 0xA5, .variant = 0, .advance_x = 600, .left_side_bearing = 13, .x_min = 13, .y_min = 0, .x_max = 587, .y_max = 698 }, // U+00A5
    .{ .codepoint = 0xA6, .variant = 0, .advance_x = 600, .left_side_bearing = 253, .x_min = 253, .y_min = -138, .x_max = 347, .y_max = 760 }, // U+00A6
    .{ .codepoint = 0xA7, .variant = 0, .advance_x = 600, .left_side_bearing = 74, .x_min = 74, .y_min = -164, .x_max = 531, .y_max = 710 }, // U+00A7
    .{ .codepoint = 0xA8, .variant = 0, .advance_x = 600, .left_side_bearing = 133, .x_min = 133, .y_min = 607, .x_max = 467, .y_max = 732 }, // U+00A8
    .{ .codepoint = 0xA9, .variant = 0, .advance_x = 600, .left_side_bearing = 0, .x_min = 0, .y_min = 18, .x_max = 600, .y_max = 680 }, // U+00A9
    .{ .codepoint = 0xAA, .variant = 0, .advance_x = 600, .left_side_bearing = 133, .x_min = 133, .y_min = 342, .x_max = 474, .y_max = 710 }, // U+00AA
    .{ .codepoint = 0xAB, .variant = 0, .advance_x = 600, .left_side_bearing = 68, .x_min = 68, .y_min = 47, .x_max = 541, .y_max = 493 }, // U+00AB
    .{ .codepoint = 0xAC, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 68, .x_max = 522, .y_max = 350 }, // U+00AC
    .{ .codepoint = 0xAE, .variant = 0, .advance_x = 600, .left_side_bearing = 117, .x_min = 117, .y_min = 346, .x_max = 483, .y_max = 710 }, // U+00AE
    .{ .codepoint = 0xAF, .variant = 0, .advance_x = 600, .left_side_bearing = 155, .x_min = 155, .y_min = 628, .x_max = 445, .y_max = 710 }, // U+00AF
    .{ .codepoint = 0xB0, .variant = 0, .advance_x = 600, .left_side_bearing = 122, .x_min = 122, .y_min = 354, .x_max = 478, .y_max = 710 }, // U+00B0
    .{ .codepoint = 0xB1, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 0, .x_max = 538, .y_max = 625 }, // U+00B1
    .{ .codepoint = 0xB2, .variant = 0, .advance_x = 600, .left_side_bearing = 156, .x_min = 156, .y_min = 329, .x_max = 443, .y_max = 704 }, // U+00B2
    .{ .codepoint = 0xB3, .variant = 0, .advance_x = 600, .left_side_bearing = 146, .x_min = 146, .y_min = 323, .x_max = 438, .y_max = 704 }, // U+00B3
    .{ .codepoint = 0xB4, .variant = 0, .advance_x = 600, .left_side_bearing = 244, .x_min = 244, .y_min = 579, .x_max = 429, .y_max = 791 }, // U+00B4
    .{ .codepoint = 0xB5, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = -200, .x_max = 516, .y_max = 516 }, // U+00B5
    .{ .codepoint = 0xB6, .variant = 0, .advance_x = 600, .left_side_bearing = 35, .x_min = 35, .y_min = -149, .x_max = 524, .y_max = 698 }, // U+00B6
    .{ .codepoint = 0xB7, .variant = 0, .advance_x = 600, .left_side_bearing = 213, .x_min = 213, .y_min = 222, .x_max = 387, .y_max = 386 }, // U+00B7
    .{ .codepoint = 0xB8, .variant = 0, .advance_x = 600, .left_side_bearing = 203, .x_min = 203, .y_min = -209, .x_max = 433, .y_max = 24 }, // U+00B8
    .{ .codepoint = 0xB9, .variant = 0, .advance_x = 600, .left_side_bearing = 158, .x_min = 158, .y_min = 329, .x_max = 453, .y_max = 698 }, // U+00B9
    .{ .codepoint = 0xBA, .variant = 0, .advance_x = 600, .left_side_bearing = 131, .x_min = 131, .y_min = 342, .x_max = 469, .y_max = 710 }, // U+00BA
    .{ .codepoint = 0xBB, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = 47, .x_max = 533, .y_max = 493 }, // U+00BB
    .{ .codepoint = 0xBC, .variant = 0, .advance_x = 600, .left_side_bearing = 11, .x_min = 11, .y_min = 0, .x_max = 589, .y_max = 698 }, // U+00BC
    .{ .codepoint = 0xBD, .variant = 0, .advance_x = 600, .left_side_bearing = 11, .x_min = 11, .y_min = 0, .x_max = 589, .y_max = 698 }, // U+00BD
    .{ .codepoint = 0xBE, .variant = 0, .advance_x = 600, .left_side_bearing = 11, .x_min = 11, .y_min = 0, .x_max = 589, .y_max = 704 }, // U+00BE
    .{ .codepoint = 0xBF, .variant = 0, .advance_x = 600, .left_side_bearing = 83, .x_min = 83, .y_min = -194, .x_max = 530, .y_max = 526 }, // U+00BF
    .{ .codepoint = 0xC0, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 961 }, // U+00C0
    .{ .codepoint = 0xC1, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 961 }, // U+00C1
    .{ .codepoint = 0xC2, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 944 }, // U+00C2
    .{ .codepoint = 0xC3, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 903 }, // U+00C3
    .{ .codepoint = 0xC4, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 902 }, // U+00C4
    .{ .codepoint = 0xC5, .variant = 0, .advance_x = 600, .left_side_bearing = 20, .x_min = 20, .y_min = 0, .x_max = 581, .y_max = 988 }, // U+00C5
    .{ .codepoint = 0xC6, .variant = 0, .advance_x = 600, .left_side_bearing = 10, .x_min = 10, .y_min = 0, .x_max = 565, .y_max = 698 }, // U+00C6
    .{ .codepoint = 0xC7, .variant = 0, .advance_x = 600, .left_side_bearing = 58, .x_min = 58, .y_min = -209, .x_max = 549, .y_max = 710 }, // U+00C7
    .{ .codepoint = 0xC8, .variant = 0, .advance_x = 600, .left_side_bearing = 86, .x_min = 86, .y_min = 0, .x_max = 523, .y_max = 961 }, // U+00C8
    .{ .codepoint = 0xC9, .variant = 0, .advance_x = 600, .left_side_bearing = 86, .x_min = 86, .y_min = 0, .x_max = 523, .y_max = 961 }, // U+00C9
    .{ .codepoint = 0xCA, .variant = 0, .advance_x = 600, .left_side_bearing = 86, .x_min = 86, .y_min = 0, .x_max = 523, .y_max = 944 }, // U+00CA
    .{ .codepoint = 0xCB, .variant = 0, .advance_x = 600, .left_side_bearing = 86, .x_min = 86, .y_min = 0, .x_max = 523, .y_max = 902 }, // U+00CB
    .{ .codepoint = 0xCC, .variant = 0, .advance_x = 600, .left_side_bearing = 80, .x_min = 80, .y_min = 0, .x_max = 520, .y_max = 961 }, // U+00CC
    .{ .codepoint = 0xCD, .variant = 0, .advance_x = 600, .left_side_bearing = 80, .x_min = 80, .y_min = 0, .x_max = 520, .y_max = 961 }, // U+00CD
    .{ .codepoint = 0xCE, .variant = 0, .advance_x = 600, .left_side_bearing = 80, .x_min = 80, .y_min = 0, .x_max = 520, .y_max = 944 }, // U+00CE
    .{ .codepoint = 0xCF, .variant = 0, .advance_x = 600, .left_side_bearing = 80, .x_min = 80, .y_min = 0, .x_max = 520, .y_max = 902 }, // U+00CF
    .{ .codepoint = 0xD0, .variant = 0, .advance_x = 600, .left_side_bearing = 17, .x_min = 17, .y_min = 0, .x_max = 553, .y_max = 698 }, // U+00D0
    .{ .codepoint = 0xD1, .variant = 0, .advance_x = 600, .left_side_bearing = 72, .x_min = 72, .y_min = 0, .x_max = 528, .y_max = 903 }, // U+00D1
    .{ .codepoint = 0xD2, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 961 }, // U+00D2
    .{ .codepoint = 0xD3, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 961 }, // U+00D3
    .{ .codepoint = 0xD4, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 944 }, // U+00D4
    .{ .codepoint = 0xD5, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 903 }, // U+00D5
    .{ .codepoint = 0xD6, .variant = 0, .advance_x = 600, .left_side_bearing = 44, .x_min = 44, .y_min = -12, .x_max = 556, .y_max = 902 }, // U+00D6
    .{ .codepoint = 0xD7, .variant = 0, .advance_x = 600, .left_side_bearing = 80, .x_min = 80, .y_min = 85, .x_max = 520, .y_max = 525 }, // U+00D7
    .{ .codepoint = 0xD8, .variant = 0, .advance_x = 600, .left_side_bearing = 35, .x_min = 35, .y_min = -53, .x_max = 565, .y_max = 751 }, // U+00D8
    .{ .codepoint = 0xD9, .variant = 0, .advance_x = 600, .left_side_bearing = 69, .x_min = 69, .y_min = -12, .x_max = 531, .y_max = 961 }, // U+00D9
    .{ .codepoint = 0xDA, .variant = 0, .advance_x = 600, .left_side_bearing = 69, .x_min = 69, .y_min = -12, .x_max = 531, .y_max = 961 }, // U+00DA
    .{ .codepoint = 0xDB, .variant = 0, .advance_x = 600, .left_side_bearing = 69, .x_min = 69, .y_min = -12, .x_max = 531, .y_max = 944 }, // U+00DB
    .{ .codepoint = 0xDC, .variant = 0, .advance_x = 600, .left_side_bearing = 69, .x_min = 69, .y_min = -12, .x_max = 531, .y_max = 902 }, // U+00DC
    .{ .codepoint = 0xDD, .variant = 0, .advance_x = 600, .left_side_bearing = 12, .x_min = 12, .y_min = 0, .x_max = 588, .y_max = 961 }, // U+00DD
    .{ .codepoint = 0xDE, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = 0, .x_max = 548, .y_max = 698 }, // U+00DE
    .{ .codepoint = 0xDF, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = -200, .x_max = 573, .y_max = 740 }, // U+00DF
    .{ .codepoint = 0xE0, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 791 }, // U+00E0
    .{ .codepoint = 0xE1, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 791 }, // U+00E1
    .{ .codepoint = 0xE2, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 774 }, // U+00E2
    .{ .codepoint = 0xE3, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 733 }, // U+00E3
    .{ .codepoint = 0xE4, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 732 }, // U+00E4
    .{ .codepoint = 0xE5, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 559, .y_max = 818 }, // U+00E5
    .{ .codepoint = 0xE6, .variant = 0, .advance_x = 600, .left_side_bearing = 7, .x_min = 7, .y_min = -12, .x_max = 583, .y_max = 528 }, // U+00E6
    .{ .codepoint = 0xE7, .variant = 0, .advance_x = 600, .left_side_bearing = 74, .x_min = 74, .y_min = -209, .x_max = 527, .y_max = 528 }, // U+00E7
    .{ .codepoint = 0xE8, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 540, .y_max = 791 }, // U+00E8
    .{ .codepoint = 0xE9, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 540, .y_max = 791 }, // U+00E9
    .{ .codepoint = 0xEA, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 540, .y_max = 774 }, // U+00EA
    .{ .codepoint = 0xEB, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 540, .y_max = 732 }, // U+00EB
    .{ .codepoint = 0xEC, .variant = 0, .advance_x = 600, .left_side_bearing = 101, .x_min = 101, .y_min = 0, .x_max = 551, .y_max = 791 }, // U+00EC
    .{ .codepoint = 0xED, .variant = 0, .advance_x = 600, .left_side_bearing = 101, .x_min = 101, .y_min = 0, .x_max = 551, .y_max = 791 }, // U+00ED
    .{ .codepoint = 0xEE, .variant = 0, .advance_x = 600, .left_side_bearing = 101, .x_min = 101, .y_min = 0, .x_max = 551, .y_max = 774 }, // U+00EE
    .{ .codepoint = 0xEF, .variant = 0, .advance_x = 600, .left_side_bearing = 101, .x_min = 101, .y_min = 0, .x_max = 551, .y_max = 732 }, // U+00EF
    .{ .codepoint = 0xF0, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 753 }, // U+00F0
    .{ .codepoint = 0xF1, .variant = 0, .advance_x = 600, .left_side_bearing = 84, .x_min = 84, .y_min = 0, .x_max = 521, .y_max = 733 }, // U+00F1
    .{ .codepoint = 0xF2, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 791 }, // U+00F2
    .{ .codepoint = 0xF3, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 791 }, // U+00F3
    .{ .codepoint = 0xF4, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 774 }, // U+00F4
    .{ .codepoint = 0xF5, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 733 }, // U+00F5
    .{ .codepoint = 0xF6, .variant = 0, .advance_x = 600, .left_side_bearing = 55, .x_min = 55, .y_min = -12, .x_max = 545, .y_max = 732 }, // U+00F6
    .{ .codepoint = 0xF7, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 42, .x_max = 538, .y_max = 569 }, // U+00F7
    .{ .codepoint = 0xF8, .variant = 0, .advance_x = 600, .left_side_bearing = 37, .x_min = 37, .y_min = -48, .x_max = 563, .y_max = 564 }, // U+00F8
    .{ .codepoint = 0xF9, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -12, .x_max = 516, .y_max = 791 }, // U+00F9
    .{ .codepoint = 0xFA, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -12, .x_max = 516, .y_max = 791 }, // U+00FA
    .{ .codepoint = 0xFB, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -12, .x_max = 516, .y_max = 774 }, // U+00FB
    .{ .codepoint = 0xFC, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -12, .x_max = 516, .y_max = 732 }, // U+00FC
    .{ .codepoint = 0xFD, .variant = 0, .advance_x = 600, .left_side_bearing = 39, .x_min = 39, .y_min = -200, .x_max = 561, .y_max = 791 }, // U+00FD
    .{ .codepoint = 0xFE, .variant = 0, .advance_x = 600, .left_side_bearing = 79, .x_min = 79, .y_min = -200, .x_max = 549, .y_max = 740 }, // U+00FE
    .{ .codepoint = 0xFF, .variant = 0, .advance_x = 600, .left_side_bearing = 39, .x_min = 39, .y_min = -200, .x_max = 561, .y_max = 732 }, // U+00FF
    .{ .codepoint = 0x2013, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = 257, .x_max = 540, .y_max = 351 }, // U+2013
    .{ .codepoint = 0x2014, .variant = 0, .advance_x = 600, .left_side_bearing = 0, .x_min = 0, .y_min = 257, .x_max = 600, .y_max = 351 }, // U+2014
    .{ .codepoint = 0x2018, .variant = 0, .advance_x = 600, .left_side_bearing = 181, .x_min = 181, .y_min = 442, .x_max = 390, .y_max = 740 }, // U+2018
    .{ .codepoint = 0x2019, .variant = 0, .advance_x = 600, .left_side_bearing = 210, .x_min = 210, .y_min = 442, .x_max = 419, .y_max = 740 }, // U+2019
    .{ .codepoint = 0x201C, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 442, .x_max = 517, .y_max = 740 }, // U+201C
    .{ .codepoint = 0x201D, .variant = 0, .advance_x = 600, .left_side_bearing = 91, .x_min = 91, .y_min = 442, .x_max = 546, .y_max = 740 }, // U+201D
    .{ .codepoint = 0x2022, .variant = 0, .advance_x = 600, .left_side_bearing = 165, .x_min = 165, .y_min = 173, .x_max = 435, .y_max = 435 }, // U+2022
    .{ .codepoint = 0x2026, .variant = 0, .advance_x = 600, .left_side_bearing = 38, .x_min = 38, .y_min = -5, .x_max = 562, .y_max = 135 }, // U+2026
    .{ .codepoint = 0x2032, .variant = 0, .advance_x = 600, .left_side_bearing = 220, .x_min = 220, .y_min = 366, .x_max = 379, .y_max = 698 }, // U+2032
    .{ .codepoint = 0x2033, .variant = 0, .advance_x = 600, .left_side_bearing = 122, .x_min = 122, .y_min = 366, .x_max = 478, .y_max = 698 }, // U+2033
    .{ .codepoint = 0x2039, .variant = 0, .advance_x = 600, .left_side_bearing = 171, .x_min = 171, .y_min = 47, .x_max = 408, .y_max = 493 }, // U+2039
    .{ .codepoint = 0x203A, .variant = 0, .advance_x = 600, .left_side_bearing = 192, .x_min = 192, .y_min = 47, .x_max = 429, .y_max = 493 }, // U+203A
    .{ .codepoint = 0x20AC, .variant = 0, .advance_x = 600, .left_side_bearing = 60, .x_min = 60, .y_min = -12, .x_max = 553, .y_max = 710 }, // U+20AC
    .{ .codepoint = 0x2122, .variant = 0, .advance_x = 600, .left_side_bearing = 15, .x_min = 15, .y_min = 415, .x_max = 546, .y_max = 698 }, // U+2122
    .{ .codepoint = 0x2212, .variant = 0, .advance_x = 600, .left_side_bearing = 62, .x_min = 62, .y_min = 261, .x_max = 538, .y_max = 350 }, // U+2212
};

pub const variant_glyphs = [_]GlyphMetrics{

};

pub const coverage_glyphs = [_]CoverageGlyph{

};

pub const coverage_spans = [_]CoverageSpan{

};

pub const context_rules = [_]ContextRule{

};

pub const ligature_components = [_]u32{

};

pub const ligature_spans = [_]LigatureSpan{

};

pub const ligature_rules = [_]LigatureRule{

};

pub const pair_adjustments = [_]PairAdjustment{

};

pub const pair_lookups = [_]PairLookup{

};

pub const pair_subtables = [_]PairSubtable{

};

pub const pair_states = [_]PairStateGlyph{

};

pub const pair_exact_adjustments = [_]PairAdjustment{

};

pub const pair_exact_packed_adjustments = [_]PairExactPackedAdjustment{

};

pub const pair_class_subtables = [_]PairClassSubtable{

};

pub const pair_left_classes = [_]PairClassGlyph{

};

pub const pair_right_classes = [_]PairClassGlyph{

};

pub const pair_class_values = [_]i16{

};

pub fn glyphIndex(codepoint: u32) ?usize {
    var low: usize = 0;
    var high: usize = glyphs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (codepoint < glyphs[middle].codepoint) {
            high = middle;
        } else if (codepoint > glyphs[middle].codepoint) {
            low = middle + 1;
        } else {
            return middle;
        }
    }
    return null;
}

pub fn glyphMetrics(codepoint: u32, variant: u8) ?GlyphMetrics {
    if (variant == 0) {
        const index = glyphIndex(codepoint) orelse return null;
        return glyphs[index];
    }
    if (variant_glyphs.len == 0) return null;
    const key = glyphKey(codepoint, variant);
    var low: usize = 0;
    var high: usize = variant_glyphs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(variant_glyphs[middle].codepoint, variant_glyphs[middle].variant);
        if (key < middle_key) {
            high = middle;
        } else if (key > middle_key) {
            low = middle + 1;
        } else {
            return variant_glyphs[middle];
        }
    }
    return null;
}

pub fn coverageContains(coverage_index: u16, codepoint: u32, variant: u8) bool {
    if (coverage_spans.len == 0) return false;
    const span = coverage_spans[coverage_index];
    const target = glyphKey(codepoint, variant);
    var low: usize = span.start;
    var high: usize = span.start + span.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(coverage_glyphs[middle].codepoint, coverage_glyphs[middle].variant);
        if (target < middle_key) {
            high = middle;
        } else if (target > middle_key) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn pairAdvanceX(left: u32, left_variant: u8, right: u32, right_variant: u8) i32 {
    if (pair_lookups.len != 0) {
        var total: i32 = 0;
        for (pair_lookups) |lookup| {
            if (pairLookupAdvance(lookup, left, left_variant, right, right_variant)) |advance_x| {
                total += advance_x;
            }
        }
        return total;
    }
    if (pair_adjustments.len == 0) return 0;
    const key = pairKey(left, left_variant, right, right_variant);
    var low: usize = 0;
    var high: usize = pair_adjustments.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = pairKey(
            pair_adjustments[middle].left,
            pair_adjustments[middle].left_variant,
            pair_adjustments[middle].right,
            pair_adjustments[middle].right_variant,
        );
        if (key < middle_key) {
            high = middle;
        } else if (key > middle_key) {
            low = middle + 1;
        } else {
            return pair_adjustments[middle].advance_x;
        }
    }
    return 0;
}

fn pairLookupAdvance(lookup: PairLookup, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {
    if (pair_subtables.len == 0) return null;
    var index: usize = lookup.start;
    const end = lookup.start + lookup.len;
    while (index < end) : (index += 1) {
        const subtable = pair_subtables[index];
        if (subtable.kind == 1) {
            if (pairExactAdvance(subtable, left, left_variant, right, right_variant)) |advance_x| return advance_x;
        } else if (subtable.kind == 3) {
            if (pairExactPackedAdvance(subtable, left, left_variant, right, right_variant)) |advance_x| return advance_x;
        } else if (subtable.kind == 2) {
            if (pairClassAdvance(subtable, left, left_variant, right, right_variant)) |advance_x| return advance_x;
        }
    }
    return null;
}

fn pairExactPackedAdvance(subtable: PairSubtable, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {
    if (pair_states.len == 0 or pair_exact_packed_adjustments.len == 0) return null;
    const left_id = pairStateId(left, left_variant) orelse return null;
    const right_id = pairStateId(right, right_variant) orelse return null;
    const key = pairExactPackedKey(left_id, right_id);
    var low: usize = subtable.start;
    var high: usize = subtable.start + subtable.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = pair_exact_packed_adjustments[middle].key;
        if (key < middle_key) {
            high = middle;
        } else if (key > middle_key) {
            low = middle + 1;
        } else {
            return pair_exact_packed_adjustments[middle].advance_x;
        }
    }
    return null;
}

fn pairStateId(codepoint: u32, variant: u8) ?u16 {
    if (pair_states.len == 0) return null;
    const key = glyphKey(codepoint, variant);
    var low: usize = 0;
    var high: usize = pair_states.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(pair_states[middle].codepoint, pair_states[middle].variant);
        if (key < middle_key) {
            high = middle;
        } else if (key > middle_key) {
            low = middle + 1;
        } else {
            return @intCast(middle);
        }
    }
    return null;
}

fn pairExactPackedKey(left_id: u16, right_id: u16) u32 {
    return (@as(u32, left_id) << 16) | @as(u32, right_id);
}

fn pairExactAdvance(subtable: PairSubtable, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {
    if (pair_exact_adjustments.len == 0) return null;
    const key = pairKey(left, left_variant, right, right_variant);
    var low: usize = subtable.start;
    var high: usize = subtable.start + subtable.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = pairKey(
            pair_exact_adjustments[middle].left,
            pair_exact_adjustments[middle].left_variant,
            pair_exact_adjustments[middle].right,
            pair_exact_adjustments[middle].right_variant,
        );
        if (key < middle_key) {
            high = middle;
        } else if (key > middle_key) {
            low = middle + 1;
        } else {
            return pair_exact_adjustments[middle].advance_x;
        }
    }
    return null;
}

fn pairClassAdvance(subtable: PairSubtable, left: u32, left_variant: u8, right: u32, right_variant: u8) ?i32 {
    if (pair_class_subtables.len == 0 or pair_class_values.len == 0) return null;
    const table = pair_class_subtables[subtable.start];
    const left_class = pairClassGlyphClass(pair_left_classes[0..], table.left_start, table.left_len, left, left_variant) orelse return null;
    const right_class = pairClassGlyphClass(pair_right_classes[0..], table.right_start, table.right_len, right, right_variant) orelse 0;
    if (left_class >= table.class_1_count or right_class >= table.class_2_count) return null;
    const value_index = table.value_start + @as(u32, left_class) * table.class_2_count + right_class;
    return pair_class_values[value_index];
}

fn pairClassGlyphClass(entries: []const PairClassGlyph, start: u32, len: u16, codepoint: u32, variant: u8) ?u16 {
    if (entries.len == 0) return null;
    const key = glyphKey(codepoint, variant);
    var low: usize = start;
    var high: usize = start + len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const middle_key = glyphKey(entries[middle].codepoint, entries[middle].variant);
        if (key < middle_key) {
            high = middle;
        } else if (key > middle_key) {
            low = middle + 1;
        } else {
            return entries[middle].class;
        }
    }
    return null;
}

pub fn ligatureMatches(rule_index: usize, codepoints: []const u32) bool {
    if (ligature_rules.len == 0) return false;
    const span = ligature_spans[ligature_rules[rule_index].span];
    if (codepoints.len < span.len) return false;
    var index: usize = 0;
    while (index < span.len) : (index += 1) {
        if (codepoints[index] != ligature_components[span.start + index]) return false;
    }
    return true;
}

fn glyphKey(codepoint: u32, variant: u8) u64 {
    return (@as(u64, codepoint) << 8) | @as(u64, variant);
}

fn pairKey(left: u32, left_variant: u8, right: u32, right_variant: u8) u64 {
    return (@as(u64, left) << 40) |
        (@as(u64, right) << 8) |
        (@as(u64, left_variant) << 4) |
        @as(u64, right_variant);
}

test "glyph table is sorted" {
    const std = @import("std");
    var index: usize = 1;
    while (index < glyphs.len) : (index += 1) {
        try std.testing.expect(glyphs[index - 1].codepoint < glyphs[index].codepoint);
    }
}

test "variant glyph table is sorted" {
    const std = @import("std");
    var index: usize = 1;
    while (index < variant_glyphs.len) : (index += 1) {
        const before = glyphKey(variant_glyphs[index - 1].codepoint, variant_glyphs[index - 1].variant);
        const after = glyphKey(variant_glyphs[index].codepoint, variant_glyphs[index].variant);
        try std.testing.expect(before < after);
    }
}

test "pair adjustment table is sorted" {
    const std = @import("std");
    var index: usize = 1;
    while (index < pair_adjustments.len) : (index += 1) {
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
    }
}
