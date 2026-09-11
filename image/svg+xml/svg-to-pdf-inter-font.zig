//! # SVG to PDF with Inter
//!
//! Converts a strict SVG vector subset to a single-page PDF/A-2b document. It
//! writes PDF paths and text operators, never rasterizing SVG input. PDF/A-2b
//! retains native PDF transparency and requires a PDF 1.7 header.
//!
//! The module embeds the complete Inter Display Regular, Bold, Italic, or Bold
//! Italic 4.1 TrueType program for every face used by the SVG. The PDF has no
//! dependency on fonts installed by the reader. Text is selectable, searchable,
//! and copied through generated `/ToUnicode` maps. A small PDF with text
//! therefore includes about 409 KiB of font data for each used face. This is an
//! intentional trade: fixed rendering and a simple writer take precedence over
//! small output files. Inter is licensed under the SIL Open Font License 1.1;
//! see `fixtures/inter-4.1/LICENSE.txt`.
//!
//! Colour is explicit sRGB, not PDF `DeviceRGB`: the component embeds the ICC
//! sRGB v2 profile from the International Color Consortium. Its source and
//! license are recorded in `third_party/libavif-1.4.1/tests/data/README.md`.
//! The PDF embeds that profile both as its paint colour space and as the
//! PDF/A-2b output intent. `sRGB2014.icc` has SHA-256
//! `384b832de3412066743b52a75ee906b6fb9fb8d9e09e936fc2c43223815c6e0a`.
//!
//! Input: `image/svg+xml`. Output: `application/pdf`. The SVG `width` and
//! `height` are required. The component maps 96 SVG/CSS units to 72 PDF
//! points, so a 960 by 540 SVG produces a 720 by 405 point page. An optional
//! `viewBox` must be exactly `0 0 width height`.
//!
//! ```sh
//! ./qip run -i logo.svg -o logo.pdf -- \
//!   image/svg+xml/svg-to-pdf-inter-font.wasm
//! ```
//!
//! ## Supported SVG
//!
//! - `rect` without rounded corners, `circle`, `ellipse`, `line`, `polyline`,
//!   `polygon`, and `path`.
//! - Path commands `M`, `L`, `H`, `V`, `C`, `Q`, and `Z`, in absolute or
//!   relative form. Quadratic curves are converted to cubic PDF curves.
//! - Nested `g` groups, inherited `fill`, `stroke`, and `stroke-width`, and
//!   `transform` lists with `matrix`, `translate`, `scale`, and `rotate`.
//! - Up to 16-stop `linearGradient` and `radialGradient` definitions in `defs`,
//!   with `gradientUnits="userSpaceOnUse"` and `fill="url(#name)"`. PDF native
//!   shadings retain the gradient as vector data.
//! - Solid `fill`, `stroke`, and `stroke-width`; colours are `#rgb` or
//!   `#rrggbb`.
//! - `fill-opacity`, `stroke-opacity`, and `opacity` from 0 through 1 on
//!   supported painted elements and `g` groups. Element and group opacity use
//!   isolated PDF transparency groups, so overlapping children retain SVG
//!   compositing semantics without rasterizing.
//! - `text` with `font-family="Inter"` or `font-family="Inter Display"`,
//!   normal or italic `font-style`, normal/400 or bold/700 `font-weight`, `x`,
//!   `y`, `font-size`, and a solid fill. The component supports glyphs in the
//!   embedded face and simple left-to-right advance layout.
//!
//! Unsupported SVG is a recoverable Content rejection. This includes CSS
//! `style`, `stop-opacity`, gradient strokes, gradients with more than 16
//! stops, masks, filters, images, external references, animation, scripts,
//! non-Inter text, text spacing and anchoring, SVG arc commands, and path shorthand
//! commands. Use
//! an SVG authoring step that converts those features to the accepted path/text
//! subset before this component. The component accepts up to 1 MiB of SVG and
//! uses a 1 MiB PDF content-stream buffer; an unusually verbose SVG can be
//! rejected even when its source is within the input cap.

const std = @import("std");
const ttf = @import("ttf");
const inter_regular = @import("inter_regular");
const inter_bold = @import("inter_bold");
const inter_italic = @import("inter_italic");
const inter_bold_italic = @import("inter_bold_italic");
const SRGB_ICC = @embedFile("sRGB2014.icc");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 3 * 1024 * 1024;
const CONTENT_CAP: usize = 1024 * 1024;
const CMAP_CAP: usize = 128 * 1024;
const MAX_ATTRIBUTES: usize = 24;
const MAX_GLYPHS: usize = 4096;
const MAX_GROUP_DEPTH: usize = 32;
const MAX_GRADIENTS: usize = 32;
const MAX_SVG_GRADIENT_STOPS: usize = 16;
const MAX_GRADIENT_STOPS: usize = MAX_SVG_GRADIENT_STOPS + 2;
const MAX_FORMS: usize = 32;
const MAX_OPACITY_STATES: usize = 64;
const MAX_PDF_OBJECTS: usize = 256;
const INPUT_CONTENT_TYPE = "image/svg+xml";
const OUTPUT_CONTENT_TYPE = "application/pdf";
const METADATA_OBJECT: usize = 5;
const SRGB_ICC_OBJECT: usize = 6;
const FIRST_DYNAMIC_OBJECT: usize = 7;
const XMP_METADATA =
    "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" ++
    "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"QIP\">\n" ++
    "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n" ++
    "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"2\" pdfaid:conformance=\"B\"/>\n" ++
    "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:format>application/pdf</dc:format></rdf:Description>\n" ++
    "</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>";
const Face = enum(u8) { regular, bold, italic, bold_italic };
const FACE_COUNT: usize = 4;
const FontFace = struct { bytes: []const u8, pdf_name: []const u8, italic_angle: i32 };
const FONT_FACES = [_]FontFace{
    .{ .bytes = inter_regular.bytes, .pdf_name = "InterDisplay-Regular", .italic_angle = 0 },
    .{ .bytes = inter_bold.bytes, .pdf_name = "InterDisplay-Bold", .italic_angle = 0 },
    .{ .bytes = inter_italic.bytes, .pdf_name = "InterDisplay-Italic", .italic_angle = -10 },
    .{ .bytes = inter_bold_italic.bytes, .pdf_name = "InterDisplay-BoldItalic", .italic_angle = -10 },
};

const Error = error{
    InvalidSvg,
    UnsupportedSvg,
    OutputOverflow,
    TooManyGlyphs,
};

const Attr = struct { name: []const u8, value: []const u8 };
const Tag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
    attrs: [MAX_ATTRIBUTES]Attr = undefined,
    attr_count: usize = 0,

    fn value(self: *const Tag, name: []const u8) Error!?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.attrs[0..self.attr_count]) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) {
                if (result != null) return error.InvalidSvg;
                result = attribute.value;
            }
        }
        return result;
    }
};

const Color = struct { red: f32, green: f32, blue: f32 };
const Paint = union(enum) { none, color: Color, gradient: usize };
const Style = struct {
    fill: Paint = .{ .color = .{ .red = 0, .green = 0, .blue = 0 } },
    stroke: Paint = .none,
    stroke_width: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
};
const GradientKind = enum { linear, radial };
const GradientStop = struct { offset: f32, color: Color };
const Gradient = struct {
    id: []const u8,
    kind: GradientKind,
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 0,
    y2: f32 = 0,
    radius: f32 = 0,
    stops: [MAX_GRADIENT_STOPS]GradientStop = undefined,
    stop_count: usize = 0,
    used: bool = false,
};
const Mat = struct { a: f32 = 1, b: f32 = 0, c: f32 = 0, d: f32 = 1, e: f32 = 0, f: f32 = 0 };
const Context = struct {
    style: Style,
    is_group: bool,
    form_index: ?usize = null,
    transform: Mat = .{},
    opacity: f32 = 1,
};
const Form = struct { scratch_start: usize, offset: usize = 0, size: usize = 0 };
const OpacityState = struct { fill: f32, stroke: f32 };
const GlyphMapping = struct { face: Face, glyph_id: u16, codepoint: u32 };

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var content_buf: [CONTENT_CAP]u8 = undefined;
var form_content_buf: [CONTENT_CAP]u8 = undefined;
var form_scratch_buf: [CONTENT_CAP]u8 = undefined;
var cmap_buf: [FACE_COUNT][CMAP_CAP]u8 = undefined;
var glyph_mappings: [MAX_GLYPHS]GlyphMapping = undefined;
var glyph_mapping_count: usize = 0;
var face_used: [FACE_COUNT]bool = .{false} ** FACE_COUNT;
var gradients: [MAX_GRADIENTS]Gradient = undefined;
var gradient_count: usize = 0;
var forms: [MAX_FORMS]Form = undefined;
var form_writers: [MAX_FORMS]Writer = undefined;
var form_count: usize = 0;
var form_content_size: usize = 0;
var opacity_states: [MAX_OPACITY_STATES]OpacityState = undefined;
var opacity_state_count: usize = 0;

const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Writer, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    fn byte(self: *Writer, value: u8) Error!void {
        if (self.index == self.bytes.len) return error.OutputOverflow;
        self.bytes[self.index] = value;
        self.index += 1;
    }

    fn integer(self: *Writer, value: anytype) Error!void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.write(text);
    }

    fn float(self: *Writer, value: f32) Error!void {
        if (!std.math.isFinite(value)) return error.InvalidSvg;
        var buffer: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d:.3}", .{value}) catch return error.OutputOverflow;
        try self.write(text);
    }

    fn hex16(self: *Writer, value: u16) Error!void {
        const digits = "0123456789ABCDEF";
        try self.byte(digits[(value >> 12) & 0xf]);
        try self.byte(digits[(value >> 8) & 0xf]);
        try self.byte(digits[(value >> 4) & 0xf]);
        try self.byte(digits[value & 0xf]);
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
} {
    const input_size: usize = input_size_u32;
    if (input_size > input_buf.len) @trap();
    const output_size = renderSvg(input_buf[0..input_size], &output_buf) catch {
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{
        .output_size_or_failure = @intCast(output_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn renderSvg(input: []const u8, output: []u8) Error!usize {
    glyph_mapping_count = 0;
    face_used = .{false} ** FACE_COUNT;
    gradient_count = 0;
    form_count = 0;
    form_content_size = 0;
    opacity_state_count = 0;
    try collectGradients(input);
    const fonts = [_]ttf.Font{
        ttf.Font.init(FONT_FACES[0].bytes) catch return error.UnsupportedSvg,
        ttf.Font.init(FONT_FACES[1].bytes) catch return error.UnsupportedSvg,
        ttf.Font.init(FONT_FACES[2].bytes) catch return error.UnsupportedSvg,
        ttf.Font.init(FONT_FACES[3].bytes) catch return error.UnsupportedSvg,
    };
    var content = Writer{ .bytes = &content_buf };
    const page = try svgContent(input, &content, &fonts);
    var cmap_sizes: [FACE_COUNT]usize = .{0} ** FACE_COUNT;
    for (0..FACE_COUNT) |index| {
        if (!face_used[index]) continue;
        var cmap = Writer{ .bytes = &cmap_buf[index] };
        try writeToUnicodeCMap(&cmap, @enumFromInt(index));
        cmap_sizes[index] = cmap.index;
    }
    return writePdf(output, page, content.bytes[0..content.index], cmap_sizes, &fonts);
}

const Page = struct { width: f32, height: f32 };

fn currentForm(contexts: *const [MAX_GROUP_DEPTH]Context, context_count: usize) ?usize {
    var index = context_count;
    while (index > 0) {
        index -= 1;
        if (contexts[index].form_index) |form_index| return form_index;
    }
    return null;
}

fn currentWriter(content: *Writer, contexts: *const [MAX_GROUP_DEPTH]Context, context_count: usize) *Writer {
    if (currentForm(contexts, context_count)) |form_index| return &form_writers[form_index];
    return content;
}

fn nextFormScratchStart(contexts: *const [MAX_GROUP_DEPTH]Context, context_count: usize) usize {
    if (currentForm(contexts, context_count)) |form_index| return forms[form_index].scratch_start + form_writers[form_index].index;
    return 0;
}

fn beginForm(scratch_start: usize) Error!usize {
    if (form_count == forms.len or scratch_start >= form_scratch_buf.len) return error.OutputOverflow;
    const index = form_count;
    form_count += 1;
    forms[index] = .{ .scratch_start = scratch_start };
    form_writers[index] = .{ .bytes = form_scratch_buf[scratch_start..] };
    return index;
}

fn finishForm(index: usize) Error!void {
    const size = form_writers[index].index;
    if (size > form_content_buf.len - form_content_size) return error.OutputOverflow;
    @memcpy(form_content_buf[form_content_size..][0..size], form_writers[index].bytes[0..size]);
    forms[index].offset = form_content_size;
    forms[index].size = size;
    form_content_size += size;
}

fn writeFormInvocation(out: *Writer, transform: Mat, opacity: f32, form_index: usize) Error!void {
    try beginTransform(out, transform);
    try applyOpacity(out, opacity, opacity);
    try out.write("/X");
    try out.integer(form_index + 1);
    try out.write(" Do\nQ\n");
}

fn svgContent(input: []const u8, content: *Writer, fonts: *const [FACE_COUNT]ttf.Font) Error!Page {
    var cursor: usize = 0;
    var root_seen = false;
    var root_closed = false;
    var page: Page = undefined;
    var contexts: [MAX_GROUP_DEPTH]Context = undefined;
    var context_count: usize = 0;
    var defs_depth: usize = 0;

    while (cursor < input.len) {
        if (input[cursor] != '<') {
            const start = cursor;
            while (cursor < input.len and input[cursor] != '<') : (cursor += 1) {}
            if (!onlyWhitespace(input[start..cursor])) return error.UnsupportedSvg;
            continue;
        }
        const tag = try readTag(input, &cursor);
        if (std.mem.eql(u8, tag.name, "svg")) {
            if (tag.closing) {
                if (!root_seen or root_closed) return error.InvalidSvg;
                if (context_count != 1 or defs_depth != 0) return error.InvalidSvg;
                root_closed = true;
                try content.write("Q\n");
                continue;
            }
            if (root_seen or tag.self_closing) return error.InvalidSvg;
            if (try tag.value("transform") != null or try tag.value("opacity") != null) return error.UnsupportedSvg;
            page = try pageFromRoot(&tag);
            root_seen = true;
            contexts[0] = .{ .style = try styleFromTag(&tag, Style{}), .is_group = false };
            context_count = 1;
            try content.write("q\n0.75 0 0 -0.75 0 ");
            try content.float(page.height);
            try content.write(" cm\n");
            continue;
        }
        if (!root_seen or root_closed) return error.InvalidSvg;
        if (defs_depth != 0) {
            if (std.mem.eql(u8, tag.name, "defs")) {
                if (tag.closing) {
                    defs_depth -= 1;
                } else if (!tag.self_closing) {
                    defs_depth += 1;
                }
            }
            continue;
        }
        if (std.mem.eql(u8, tag.name, "defs")) {
            if (tag.closing) return error.InvalidSvg;
            if (!tag.self_closing) defs_depth = 1;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "g")) {
            if (tag.closing) {
                if (context_count <= 1 or !contexts[context_count - 1].is_group) return error.InvalidSvg;
                const group = contexts[context_count - 1];
                if (group.form_index) |form_index| {
                    try finishForm(form_index);
                    context_count -= 1;
                    try writeFormInvocation(currentWriter(content, &contexts, context_count), group.transform, group.opacity, form_index);
                } else {
                    try currentWriter(content, &contexts, context_count).write("Q\n");
                    context_count -= 1;
                }
            } else {
                if (tag.self_closing or context_count == contexts.len) return error.InvalidSvg;
                const style = try styleFromTag(&tag, contexts[context_count - 1].style);
                const transform = try transformFromTag(&tag);
                const opacity = try opacityFromTag(&tag);
                const form_index = if (opacity == 1) null else try beginForm(nextFormScratchStart(&contexts, context_count));
                contexts[context_count] = .{ .style = style, .is_group = true, .form_index = form_index, .transform = transform, .opacity = opacity };
                context_count += 1;
                if (form_index == null) try beginTransform(currentWriter(content, &contexts, context_count), transform);
            }
            continue;
        }
        if (tag.closing) return error.UnsupportedSvg;
        const style = contexts[context_count - 1].style;
        if (std.mem.eql(u8, tag.name, "text")) {
            if (tag.self_closing) return error.InvalidSvg;
            const text_start = cursor;
            while (cursor < input.len and input[cursor] != '<') : (cursor += 1) {}
            if (cursor == input.len) return error.InvalidSvg;
            const text_end = cursor;
            const close = try readTag(input, &cursor);
            if (!close.closing or !std.mem.eql(u8, close.name, "text")) return error.UnsupportedSvg;
            const transform = try transformFromTag(&tag);
            const opacity = try opacityFromTag(&tag);
            if (opacity == 1) {
                const out = currentWriter(content, &contexts, context_count);
                try beginTransform(out, transform);
                try writeText(out, &tag, input[text_start..text_end], fonts, style);
                try out.write("Q\n");
            } else {
                const form_index = try beginForm(nextFormScratchStart(&contexts, context_count));
                try writeText(&form_writers[form_index], &tag, input[text_start..text_end], fonts, style);
                try finishForm(form_index);
                try writeFormInvocation(currentWriter(content, &contexts, context_count), transform, opacity, form_index);
            }
            continue;
        }
        if (!tag.self_closing) return error.UnsupportedSvg;
        const transform = try transformFromTag(&tag);
        const opacity = try opacityFromTag(&tag);
        const form_index = if (opacity == 1) null else try beginForm(nextFormScratchStart(&contexts, context_count));
        const out = if (form_index) |index| &form_writers[index] else currentWriter(content, &contexts, context_count);
        if (form_index == null) try beginTransform(out, transform);
        if (std.mem.eql(u8, tag.name, "rect")) {
            try writeRect(out, &tag, style);
        } else if (std.mem.eql(u8, tag.name, "circle")) {
            try writeCircle(out, &tag, style);
        } else if (std.mem.eql(u8, tag.name, "ellipse")) {
            try writeEllipse(out, &tag, style);
        } else if (std.mem.eql(u8, tag.name, "line")) {
            try writeLine(out, &tag, style);
        } else if (std.mem.eql(u8, tag.name, "polyline") or std.mem.eql(u8, tag.name, "polygon")) {
            try writePoly(out, &tag, std.mem.eql(u8, tag.name, "polygon"), style);
        } else if (std.mem.eql(u8, tag.name, "path")) {
            try writePath(out, &tag, style);
        } else {
            return error.UnsupportedSvg;
        }
        if (form_index) |index| {
            try finishForm(index);
            try writeFormInvocation(currentWriter(content, &contexts, context_count), transform, opacity, index);
        } else {
            try out.write("Q\n");
        }
    }
    if (!root_seen or !root_closed) return error.InvalidSvg;
    return page;
}

fn readTag(input: []const u8, cursor: *usize) Error!Tag {
    if (cursor.* >= input.len or input[cursor.*] != '<') return error.InvalidSvg;
    cursor.* += 1;
    if (cursor.* + 3 <= input.len and std.mem.eql(u8, input[cursor.* .. cursor.* + 3], "!--")) {
        cursor.* += 3;
        while (cursor.* + 3 <= input.len and !std.mem.eql(u8, input[cursor.* .. cursor.* + 3], "-->")) : (cursor.* += 1) {}
        if (cursor.* + 3 > input.len) return error.InvalidSvg;
        cursor.* += 3;
        return readTag(input, cursor);
    }
    if (cursor.* < input.len and (input[cursor.*] == '?' or input[cursor.*] == '!')) return error.UnsupportedSvg;
    var tag = Tag{ .name = undefined, .closing = false, .self_closing = false };
    skipWhitespace(input, cursor);
    if (cursor.* < input.len and input[cursor.*] == '/') {
        tag.closing = true;
        cursor.* += 1;
        skipWhitespace(input, cursor);
    }
    tag.name = readName(input, cursor);
    if (tag.name.len == 0) return error.InvalidSvg;
    while (true) {
        skipWhitespace(input, cursor);
        if (cursor.* >= input.len) return error.InvalidSvg;
        if (input[cursor.*] == '>') {
            cursor.* += 1;
            return tag;
        }
        if (input[cursor.*] == '/') {
            if (tag.closing or cursor.* + 1 >= input.len or input[cursor.* + 1] != '>') return error.InvalidSvg;
            tag.self_closing = true;
            cursor.* += 2;
            return tag;
        }
        if (tag.closing or tag.attr_count == tag.attrs.len) return error.InvalidSvg;
        const name = readName(input, cursor);
        if (name.len == 0) return error.InvalidSvg;
        skipWhitespace(input, cursor);
        if (cursor.* >= input.len or input[cursor.*] != '=') return error.InvalidSvg;
        cursor.* += 1;
        skipWhitespace(input, cursor);
        if (cursor.* >= input.len or (input[cursor.*] != '\"' and input[cursor.*] != '\'')) return error.InvalidSvg;
        const quote = input[cursor.*];
        cursor.* += 1;
        const value_start = cursor.*;
        while (cursor.* < input.len and input[cursor.*] != quote) : (cursor.* += 1) {}
        if (cursor.* == input.len) return error.InvalidSvg;
        tag.attrs[tag.attr_count] = .{ .name = name, .value = input[value_start..cursor.*] };
        tag.attr_count += 1;
        cursor.* += 1;
    }
}

fn pageFromRoot(tag: *const Tag) Error!Page {
    const width = try requiredNumber(tag, "width");
    const height = try requiredNumber(tag, "height");
    if (width <= 0 or height <= 0 or width > 16384 or height > 16384) return error.InvalidSvg;
    if (try tag.value("viewBox")) |view_box| {
        var cursor: usize = 0;
        const x = try readNumber(view_box, &cursor);
        const y = try readNumber(view_box, &cursor);
        const view_width = try readNumber(view_box, &cursor);
        const view_height = try readNumber(view_box, &cursor);
        skipNumberSeparators(view_box, &cursor);
        if (cursor != view_box.len or x != 0 or y != 0 or view_width != width or view_height != height) return error.UnsupportedSvg;
    }
    return .{ .width = width * 0.75, .height = height * 0.75 };
}

fn writeRect(out: *Writer, tag: *const Tag, inherited: Style) Error!void {
    if (try tag.value("rx") != null or try tag.value("ry") != null) return error.UnsupportedSvg;
    const x = try optionalNumber(tag, "x", 0);
    const y = try optionalNumber(tag, "y", 0);
    const width = try requiredNumber(tag, "width");
    const height = try requiredNumber(tag, "height");
    if (width < 0 or height < 0) return error.InvalidSvg;
    try point(out, x, y, " m\n");
    try point(out, x + width, y, " l\n");
    try point(out, x + width, y + height, " l\n");
    try point(out, x, y + height, " l\n");
    try out.write("h\n");
    try paint(out, try styleFromTag(tag, inherited));
}

fn writeCircle(out: *Writer, tag: *const Tag, inherited: Style) Error!void {
    const cx = try requiredNumber(tag, "cx");
    const cy = try requiredNumber(tag, "cy");
    const radius = try requiredNumber(tag, "r");
    if (radius < 0) return error.InvalidSvg;
    try writeEllipseGeometry(out, cx, cy, radius, radius);
    try paint(out, try styleFromTag(tag, inherited));
}

fn writeEllipse(out: *Writer, tag: *const Tag, inherited: Style) Error!void {
    const cx = try requiredNumber(tag, "cx");
    const cy = try requiredNumber(tag, "cy");
    const rx = try requiredNumber(tag, "rx");
    const ry = try requiredNumber(tag, "ry");
    if (rx < 0 or ry < 0) return error.InvalidSvg;
    try writeEllipseGeometry(out, cx, cy, rx, ry);
    try paint(out, try styleFromTag(tag, inherited));
}

fn writeEllipseGeometry(out: *Writer, cx: f32, cy: f32, rx: f32, ry: f32) Error!void {
    const k: f32 = 0.55228475;
    try point(out, cx + rx, cy, " m\n");
    try curve(out, cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry);
    try curve(out, cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy);
    try curve(out, cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry);
    try curve(out, cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy);
    try out.write("h\n");
}

fn writeLine(out: *Writer, tag: *const Tag, inherited: Style) Error!void {
    try point(out, try requiredNumber(tag, "x1"), try requiredNumber(tag, "y1"), " m\n");
    try point(out, try requiredNumber(tag, "x2"), try requiredNumber(tag, "y2"), " l\n");
    var style = try styleFromTag(tag, inherited);
    style.fill = .none;
    try paint(out, style);
}

fn writePoly(out: *Writer, tag: *const Tag, closed: bool, inherited: Style) Error!void {
    const points = (try tag.value("points")) orelse return error.InvalidSvg;
    var cursor: usize = 0;
    var count: usize = 0;
    while (true) {
        skipNumberSeparators(points, &cursor);
        if (cursor == points.len) break;
        const x = try readNumber(points, &cursor);
        const y = try readNumber(points, &cursor);
        try point(out, x, y, if (count == 0) " m\n" else " l\n");
        count += 1;
    }
    if (count < 2 or (closed and count < 3)) return error.InvalidSvg;
    if (closed) try out.write("h\n");
    var style = try styleFromTag(tag, inherited);
    if (!closed) style.fill = .none;
    try paint(out, style);
}

fn writePath(out: *Writer, tag: *const Tag, inherited: Style) Error!void {
    const data = (try tag.value("d")) orelse return error.InvalidSvg;
    try writePathData(out, data);
    try paint(out, try styleFromTag(tag, inherited));
}

fn writePathData(out: *Writer, data: []const u8) Error!void {
    var cursor: usize = 0;
    var command: u8 = 0;
    var x: f32 = 0;
    var y: f32 = 0;
    var start_x: f32 = 0;
    var start_y: f32 = 0;
    while (true) {
        skipNumberSeparators(data, &cursor);
        if (cursor == data.len) break;
        if (isPathCommand(data[cursor])) {
            command = data[cursor];
            cursor += 1;
        } else if (command == 0) {
            return error.InvalidSvg;
        }
        const relative = command >= 'a' and command <= 'z';
        switch (std.ascii.toLower(command)) {
            'm' => {
                var first = true;
                while (hasNumber(data, cursor)) {
                    var px = try readNumber(data, &cursor);
                    var py = try readNumber(data, &cursor);
                    if (relative) {
                        px += x;
                        py += y;
                    }
                    if (first) {
                        try point(out, px, py, " m\n");
                        start_x = px;
                        start_y = py;
                        first = false;
                    } else {
                        try point(out, px, py, " l\n");
                    }
                    x = px;
                    y = py;
                }
                if (first) return error.InvalidSvg;
            },
            'l' => while (hasNumber(data, cursor)) {
                var px = try readNumber(data, &cursor);
                var py = try readNumber(data, &cursor);
                if (relative) {
                    px += x;
                    py += y;
                }
                try point(out, px, py, " l\n");
                x = px;
                y = py;
            },
            'h' => while (hasNumber(data, cursor)) {
                var px = try readNumber(data, &cursor);
                if (relative) px += x;
                try point(out, px, y, " l\n");
                x = px;
            },
            'v' => while (hasNumber(data, cursor)) {
                var py = try readNumber(data, &cursor);
                if (relative) py += y;
                try point(out, x, py, " l\n");
                y = py;
            },
            'c' => while (hasNumber(data, cursor)) {
                var x1 = try readNumber(data, &cursor);
                var y1 = try readNumber(data, &cursor);
                var x2 = try readNumber(data, &cursor);
                var y2 = try readNumber(data, &cursor);
                var px = try readNumber(data, &cursor);
                var py = try readNumber(data, &cursor);
                if (relative) {
                    x1 += x;
                    y1 += y;
                    x2 += x;
                    y2 += y;
                    px += x;
                    py += y;
                }
                try curve(out, x1, y1, x2, y2, px, py);
                x = px;
                y = py;
            },
            'q' => while (hasNumber(data, cursor)) {
                var control_x = try readNumber(data, &cursor);
                var control_y = try readNumber(data, &cursor);
                var px = try readNumber(data, &cursor);
                var py = try readNumber(data, &cursor);
                if (relative) {
                    control_x += x;
                    control_y += y;
                    px += x;
                    py += y;
                }
                try curve(out, x + (control_x - x) * (2.0 / 3.0), y + (control_y - y) * (2.0 / 3.0), px + (control_x - px) * (2.0 / 3.0), py + (control_y - py) * (2.0 / 3.0), px, py);
                x = px;
                y = py;
            },
            'z' => {
                try out.write("h\n");
                x = start_x;
                y = start_y;
                command = 0;
            },
            else => return error.UnsupportedSvg,
        }
    }
}

fn writeText(out: *Writer, tag: *const Tag, text: []const u8, fonts: *const [FACE_COUNT]ttf.Font, inherited: Style) Error!void {
    if (try tag.value("text-anchor") != null or try tag.value("letter-spacing") != null) return error.UnsupportedSvg;
    if (try tag.value("font-family")) |family| {
        if (!std.mem.eql(u8, family, "Inter") and !std.mem.eql(u8, family, "Inter Display")) return error.UnsupportedSvg;
    }
    const face = try textFace(tag);
    const face_index: usize = @intFromEnum(face);
    const font = &fonts[face_index];
    face_used[face_index] = true;
    const x = try requiredNumber(tag, "x");
    const y = try requiredNumber(tag, "y");
    const size = try requiredNumber(tag, "font-size");
    if (size <= 0) return error.InvalidSvg;
    const style = try styleFromTag(tag, inherited);
    if (style.stroke != .none) return error.UnsupportedSvg;
    const color = switch (style.fill) {
        .none, .gradient => return error.UnsupportedSvg,
        .color => |value| value,
    };
    try applyOpacity(out, style.fill_opacity, 1);
    try setFillColor(out, color);
    var cursor: usize = 0;
    var pen_x = x;
    while (cursor < text.len) {
        const codepoint = try readTextCodepoint(text, &cursor);
        const glyph_id = (font.glyphIndex(codepoint) catch return error.UnsupportedSvg) orelse return error.UnsupportedSvg;
        try recordGlyph(face, glyph_id, codepoint);
        try out.write("BT /F");
        try out.integer(face_index + 1);
        try out.byte(' ');
        try out.float(size);
        try out.write(" Tf 1 0 0 -1 ");
        try out.float(pen_x);
        try out.byte(' ');
        try out.float(y);
        try out.write(" Tm <");
        try out.hex16(glyph_id);
        try out.write("> Tj ET\n");
        const metrics = font.metrics(glyph_id) catch return error.UnsupportedSvg;
        pen_x += size * @as(f32, @floatFromInt(metrics.advance_x)) / @as(f32, @floatFromInt(font.units_per_em));
    }
}

fn textFace(tag: *const Tag) Error!Face {
    const bold = if (try tag.value("font-weight")) |weight|
        if (std.mem.eql(u8, weight, "normal") or std.mem.eql(u8, weight, "400")) false else if (std.mem.eql(u8, weight, "bold") or std.mem.eql(u8, weight, "700")) true else return error.UnsupportedSvg
    else
        false;
    const italic = if (try tag.value("font-style")) |style|
        if (std.mem.eql(u8, style, "normal")) false else if (std.mem.eql(u8, style, "italic")) true else return error.UnsupportedSvg
    else
        false;
    return switch (@as(u2, @intFromBool(bold) | (@as(u2, @intFromBool(italic)) << 1))) {
        0 => .regular,
        1 => .bold,
        2 => .italic,
        3 => .bold_italic,
    };
}

fn recordGlyph(face: Face, glyph_id: u16, codepoint: u32) Error!void {
    for (glyph_mappings[0..glyph_mapping_count]) |mapping| {
        if (mapping.face == face and mapping.glyph_id == glyph_id) {
            if (mapping.codepoint != codepoint) return error.UnsupportedSvg;
            return;
        }
    }
    if (glyph_mapping_count == glyph_mappings.len) return error.TooManyGlyphs;
    glyph_mappings[glyph_mapping_count] = .{ .face = face, .glyph_id = glyph_id, .codepoint = codepoint };
    glyph_mapping_count += 1;
}

fn writeToUnicodeCMap(out: *Writer, face: Face) Error!void {
    try out.write("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Inter-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
    var start: usize = 0;
    while (start < glyph_mapping_count) {
        var count: usize = 0;
        var index = start;
        while (index < glyph_mapping_count and count < 100) : (index += 1) {
            if (glyph_mappings[index].face == face) count += 1;
        }
        if (count == 0) break;
        try out.integer(count);
        try out.write(" beginbfchar\n");
        var emitted: usize = 0;
        while (start < glyph_mapping_count and emitted < count) : (start += 1) {
            const mapping = glyph_mappings[start];
            if (mapping.face != face) continue;
            try out.byte('<');
            try out.hex16(mapping.glyph_id);
            try out.write("> <");
            try writeUtf16Hex(out, mapping.codepoint);
            try out.write(">\n");
            emitted += 1;
        }
        try out.write("endbfchar\n");
    }
    try out.write("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
}

fn writeCidWidths(out: *Writer, font: *const ttf.Font, face: Face) Error!void {
    try out.write(" /W [");
    for (glyph_mappings[0..glyph_mapping_count]) |mapping| {
        if (mapping.face != face) continue;
        const metrics = font.metrics(mapping.glyph_id) catch return error.UnsupportedSvg;
        const width: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(metrics.advance_x)) * 1000 / @as(f32, @floatFromInt(font.units_per_em))));
        try out.integer(mapping.glyph_id);
        try out.write(" [");
        try out.integer(width);
        try out.write("] ");
    }
    try out.write("]");
}

fn writeUtf16Hex(out: *Writer, codepoint: u32) Error!void {
    if (codepoint <= 0xffff) return out.hex16(@intCast(codepoint));
    if (codepoint > 0x10ffff) return error.InvalidSvg;
    const value = codepoint - 0x10000;
    try out.hex16(@intCast(0xd800 + (value >> 10)));
    try out.hex16(@intCast(0xdc00 + (value & 0x3ff)));
}

const FontObjects = struct {
    descriptor: usize,
    type0: usize,
    font_file: usize,
    cid: usize,
    cmap: usize,
};
const GradientObjects = struct { function: usize, shading: usize };

fn writePdf(output: []u8, page: Page, content: []const u8, cmap_sizes: [FACE_COUNT]usize, fonts: *const [FACE_COUNT]ttf.Font) Error!usize {
    var out = Writer{ .bytes = output };
    var objects: [FACE_COUNT]?FontObjects = .{null} ** FACE_COUNT;
    var next_object: usize = FIRST_DYNAMIC_OBJECT;
    var opacity_objects: [MAX_OPACITY_STATES]?usize = .{null} ** MAX_OPACITY_STATES;
    for (0..opacity_state_count) |index| {
        opacity_objects[index] = next_object;
        next_object += 1;
    }
    var form_objects: [MAX_FORMS]?usize = .{null} ** MAX_FORMS;
    for (0..form_count) |index| {
        form_objects[index] = next_object;
        next_object += 1;
    }
    var gradient_objects: [MAX_GRADIENTS]?GradientObjects = .{null} ** MAX_GRADIENTS;
    for (gradients[0..gradient_count], 0..) |gradient, index| {
        if (!gradient.used) continue;
        gradient_objects[index] = .{ .function = next_object, .shading = next_object + 1 };
        next_object += 2;
    }
    for (0..FACE_COUNT) |index| {
        if (!face_used[index]) continue;
        objects[index] = .{
            .descriptor = next_object,
            .type0 = next_object + 1,
            .font_file = next_object + 2,
            .cid = next_object + 3,
            .cmap = next_object + 4,
        };
        next_object += 5;
    }
    if (next_object > MAX_PDF_OBJECTS) return error.OutputOverflow;
    var offsets: [MAX_PDF_OBJECTS]usize = undefined;
    try out.write("%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");
    offsets[1] = out.index;
    try out.write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Metadata ");
    try out.integer(METADATA_OBJECT);
    try out.write(" 0 R /OutputIntents [<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) /Info (sRGB IEC61966-2.1) /DestOutputProfile ");
    try out.integer(SRGB_ICC_OBJECT);
    try out.write(" 0 R >>] >>\nendobj\n");
    try object(&out, &offsets, 2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n");
    try metadataObject(&out, &offsets, METADATA_OBJECT);
    try iccObject(&out, &offsets, SRGB_ICC_OBJECT);
    offsets[3] = out.index;
    try out.write("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ");
    try out.float(page.width);
    try out.byte(' ');
    try out.float(page.height);
    try out.write("] /Resources ");
    try writeResources(&out, &objects, &gradient_objects, &opacity_objects, &form_objects, null);
    try out.write(" /Contents 4 0 R >>\nendobj\n");
    try streamObject(&out, &offsets, 4, content);
    for (0..opacity_state_count) |index| {
        const object_number = opacity_objects[index] orelse unreachable;
        try writeOpacityObject(&out, &offsets, object_number, opacity_states[index]);
    }
    for (0..form_count) |index| {
        const object_number = form_objects[index] orelse unreachable;
        try writeFormObject(&out, &offsets, object_number, page, index, &objects, &gradient_objects, &opacity_objects, &form_objects);
    }
    for (gradient_objects, 0..) |maybe_ids, index| {
        const ids = maybe_ids orelse continue;
        try writeGradientFunction(&out, &offsets, ids.function, gradients[index]);
        try writeGradientShading(&out, &offsets, ids.shading, ids.function, gradients[index]);
    }
    for (0..FACE_COUNT) |index| {
        const ids = objects[index] orelse continue;
        const face = FONT_FACES[index];
        offsets[ids.descriptor] = out.index;
        try out.integer(ids.descriptor);
        try out.write(" 0 obj\n<< /Type /FontDescriptor /FontName /");
        try out.write(face.pdf_name);
        try out.write(" /Flags 32 /FontBBox [-200 -500 3000 2200] /ItalicAngle ");
        try out.integer(face.italic_angle);
        try out.write(" /Ascent 1984 /Descent -494 /CapHeight 1490 /StemV 80 /FontFile2 ");
        try out.integer(ids.font_file);
        try out.write(" 0 R >>\nendobj\n");
        offsets[ids.type0] = out.index;
        try out.integer(ids.type0);
        try out.write(" 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /");
        try out.write(face.pdf_name);
        try out.write(" /Encoding /Identity-H /DescendantFonts [");
        try out.integer(ids.cid);
        try out.write(" 0 R] /ToUnicode ");
        try out.integer(ids.cmap);
        try out.write(" 0 R >>\nendobj\n");
        offsets[ids.font_file] = out.index;
        try out.integer(ids.font_file);
        try out.write(" 0 obj\n<< /Length ");
        try out.integer(face.bytes.len);
        try out.write(" /Length1 ");
        try out.integer(face.bytes.len);
        try out.write(" >>\nstream\n");
        try out.write(face.bytes);
        try out.write("\nendstream\nendobj\n");
        offsets[ids.cid] = out.index;
        try out.integer(ids.cid);
        try out.write(" 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /");
        try out.write(face.pdf_name);
        try out.write(" /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor ");
        try out.integer(ids.descriptor);
        try out.write(" 0 R /DW 1000");
        try writeCidWidths(&out, &fonts[index], @enumFromInt(index));
        try out.write(" /CIDToGIDMap /Identity >>\nendobj\n");
        try streamObject(&out, &offsets, ids.cmap, cmap_buf[index][0..cmap_sizes[index]]);
    }
    const xref = out.index;
    try out.write("xref\n0 ");
    try out.integer(next_object);
    try out.write("\n0000000000 65535 f \n");
    var object_number: usize = 1;
    while (object_number < next_object) : (object_number += 1) {
        var line: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{d:0>10} 00000 n \n", .{offsets[object_number]}) catch return error.OutputOverflow;
        try out.write(text);
    }
    try out.write("trailer\n<< /Size ");
    try out.integer(next_object);
    try out.write(" /Root 1 0 R /ID [<5149502D5356472D504446412D3242> <5149502D5356472D504446412D3242>] >>\nstartxref\n");
    try out.integer(xref);
    try out.write("\n%%EOF\n");
    return out.index;
}

fn writeResources(out: *Writer, fonts: *const [FACE_COUNT]?FontObjects, gradient_objects: *const [MAX_GRADIENTS]?GradientObjects, opacity_objects: *const [MAX_OPACITY_STATES]?usize, form_objects: *const [MAX_FORMS]?usize, form_source: ?usize) Error!void {
    try out.write("<< /ColorSpace << /CS0 [/ICCBased ");
    try out.integer(SRGB_ICC_OBJECT);
    try out.write(" 0 R] >>");
    var has_fonts = false;
    for (fonts, 0..) |maybe_font, index| {
        const font = maybe_font orelse continue;
        if (!has_fonts) {
            try out.write(" /Font <<");
            has_fonts = true;
        }
        try out.write(" /F");
        try out.integer(index + 1);
        try out.byte(' ');
        try out.integer(font.type0);
        try out.write(" 0 R");
    }
    if (has_fonts) try out.write(" >>");
    var has_shadings = false;
    for (gradient_objects, 0..) |maybe_ids, index| {
        const ids = maybe_ids orelse continue;
        if (!has_shadings) {
            try out.write(" /Shading <<");
            has_shadings = true;
        }
        try out.write(" /G");
        try out.integer(index + 1);
        try out.byte(' ');
        try out.integer(ids.shading);
        try out.write(" 0 R");
    }
    if (has_shadings) try out.write(" >>");
    var has_opacity = false;
    for (opacity_objects, 0..) |maybe_object, index| {
        const object_number = maybe_object orelse continue;
        if (!has_opacity) {
            try out.write(" /ExtGState <<");
            has_opacity = true;
        }
        try out.write(" /GS");
        try out.integer(index + 1);
        try out.byte(' ');
        try out.integer(object_number);
        try out.write(" 0 R");
    }
    if (has_opacity) try out.write(" >>");
    var has_forms = false;
    for (form_objects, 0..) |maybe_object, index| {
        const object_number = maybe_object orelse continue;
        if (form_source) |source| if (!formReferences(source, index)) continue;
        if (!has_forms) {
            try out.write(" /XObject <<");
            has_forms = true;
        }
        try out.write(" /X");
        try out.integer(index + 1);
        try out.byte(' ');
        try out.integer(object_number);
        try out.write(" 0 R");
    }
    if (has_forms) try out.write(" >>");
    try out.write(" >>");
}

fn formReferences(source: usize, target: usize) bool {
    var needle: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&needle, "/X{d} Do", .{target + 1}) catch return false;
    const form = forms[source];
    return std.mem.indexOf(u8, form_content_buf[form.offset..][0..form.size], text) != null;
}

fn writeOpacityObject(out: *Writer, offsets: []usize, number: usize, state: OpacityState) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n<< /Type /ExtGState /ca ");
    try out.float(state.fill);
    try out.write(" /CA ");
    try out.float(state.stroke);
    try out.write(" >>\nendobj\n");
}

fn writeFormObject(out: *Writer, offsets: []usize, number: usize, page: Page, form_index: usize, fonts: *const [FACE_COUNT]?FontObjects, gradient_objects: *const [MAX_GRADIENTS]?GradientObjects, opacity_objects: *const [MAX_OPACITY_STATES]?usize, form_objects: *const [MAX_FORMS]?usize) Error!void {
    const form = forms[form_index];
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n<< /Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 ");
    try out.float(page.width / 0.75);
    try out.byte(' ');
    try out.float(page.height / 0.75);
    try out.write("] /Group << /S /Transparency /CS [/ICCBased ");
    try out.integer(SRGB_ICC_OBJECT);
    try out.write(" 0 R] /I true /K false >> /Resources ");
    try writeResources(out, fonts, gradient_objects, opacity_objects, form_objects, form_index);
    try out.write(" /Length ");
    try out.integer(form.size);
    try out.write(" >>\nstream\n");
    try out.write(form_content_buf[form.offset..][0..form.size]);
    try out.write("\nendstream\nendobj\n");
}

fn writeGradientFunction(out: *Writer, offsets: []usize, number: usize, gradient: Gradient) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n");
    if (gradient.stop_count == 2) {
        try out.write("<< /FunctionType 2 /Domain [0 1] /C0 ");
        try writeColorArray(out, gradient.stops[0].color);
        try out.write(" /C1 ");
        try writeColorArray(out, gradient.stops[1].color);
        try out.write(" /N 1 >>\n");
    } else {
        try out.write("<< /FunctionType 3 /Domain [0 1] /Functions [");
        for (gradient.stops[0 .. gradient.stop_count - 1], 0..) |stop, index| {
            try out.write(" << /FunctionType 2 /Domain [0 1] /C0 ");
            try writeColorArray(out, stop.color);
            try out.write(" /C1 ");
            try writeColorArray(out, gradient.stops[index + 1].color);
            try out.write(" /N 1 >>");
        }
        try out.write(" ] /Bounds [");
        for (gradient.stops[1 .. gradient.stop_count - 1]) |stop| {
            try out.float(stop.offset);
            try out.byte(' ');
        }
        try out.write("] /Encode [");
        for (gradient.stops[0 .. gradient.stop_count - 1]) |_| try out.write("0 1 ");
        try out.write("] >>\n");
    }
    try out.write("endobj\n");
}

fn writeGradientShading(out: *Writer, offsets: []usize, number: usize, function: usize, gradient: Gradient) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n<< /ShadingType ");
    switch (gradient.kind) {
        .linear => {
            try out.write("2 /ColorSpace [/ICCBased ");
            try out.integer(SRGB_ICC_OBJECT);
            try out.write(" 0 R] /Coords [");
            try out.float(gradient.x1);
            try out.byte(' ');
            try out.float(gradient.y1);
            try out.byte(' ');
            try out.float(gradient.x2);
            try out.byte(' ');
            try out.float(gradient.y2);
        },
        .radial => {
            try out.write("3 /ColorSpace [/ICCBased ");
            try out.integer(SRGB_ICC_OBJECT);
            try out.write(" 0 R] /Coords [");
            try out.float(gradient.x1);
            try out.byte(' ');
            try out.float(gradient.y1);
            try out.write(" 0 ");
            try out.float(gradient.x2);
            try out.byte(' ');
            try out.float(gradient.y2);
            try out.byte(' ');
            try out.float(gradient.radius);
        },
    }
    try out.write("] /Function ");
    try out.integer(function);
    try out.write(" 0 R /Extend [true true] >>\nendobj\n");
}

fn writeColorArray(out: *Writer, color: Color) Error!void {
    try out.write("[");
    try out.float(color.red);
    try out.byte(' ');
    try out.float(color.green);
    try out.byte(' ');
    try out.float(color.blue);
    try out.write("]");
}

fn metadataObject(out: *Writer, offsets: []usize, number: usize) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n<< /Type /Metadata /Subtype /XML /Length ");
    try out.integer(XMP_METADATA.len);
    try out.write(" >>\nstream\n");
    try out.write(XMP_METADATA);
    try out.write("\nendstream\nendobj\n");
}

fn iccObject(out: *Writer, offsets: []usize, number: usize) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n<< /N 3 /Length ");
    try out.integer(SRGB_ICC.len);
    try out.write(" >>\nstream\n");
    try out.write(SRGB_ICC);
    try out.write("\nendstream\nendobj\n");
}

fn object(out: *Writer, offsets: []usize, number: usize, body: []const u8) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n");
    try out.write(body);
    try out.write("endobj\n");
}

fn streamObject(out: *Writer, offsets: []usize, number: usize, contents: []const u8) Error!void {
    offsets[number] = out.index;
    try out.integer(number);
    try out.write(" 0 obj\n<< /Length ");
    try out.integer(contents.len);
    try out.write(" >>\nstream\n");
    try out.write(contents);
    try out.write("\nendstream\nendobj\n");
}

fn collectGradients(input: []const u8) Error!void {
    var cursor: usize = 0;
    var active: ?usize = null;
    while (cursor < input.len) {
        if (input[cursor] != '<') {
            cursor += 1;
            continue;
        }
        const tag = try readTag(input, &cursor);
        if (std.mem.eql(u8, tag.name, "linearGradient") or std.mem.eql(u8, tag.name, "radialGradient")) {
            if (tag.closing) {
                const index = active orelse return error.InvalidSvg;
                const expected = switch (gradients[index].kind) {
                    .linear => "linearGradient",
                    .radial => "radialGradient",
                };
                if (!std.mem.eql(u8, tag.name, expected)) return error.UnsupportedSvg;
                try normalizeGradientStops(&gradients[index]);
                active = null;
            } else {
                if (active != null or tag.self_closing or gradient_count == gradients.len) return error.InvalidSvg;
                const kind: GradientKind = if (std.mem.eql(u8, tag.name, "linearGradient")) .linear else .radial;
                const id = (try tag.value("id")) orelse return error.InvalidSvg;
                if (id.len == 0 or try tag.value("href") != null or try tag.value("gradientTransform") != null) return error.UnsupportedSvg;
                const units = (try tag.value("gradientUnits")) orelse return error.UnsupportedSvg;
                if (!std.mem.eql(u8, units, "userSpaceOnUse")) return error.UnsupportedSvg;
                for (gradients[0..gradient_count]) |gradient| if (std.mem.eql(u8, gradient.id, id)) return error.InvalidSvg;
                var gradient = Gradient{ .id = id, .kind = kind };
                switch (kind) {
                    .linear => {
                        gradient.x1 = try requiredNumber(&tag, "x1");
                        gradient.y1 = try requiredNumber(&tag, "y1");
                        gradient.x2 = try requiredNumber(&tag, "x2");
                        gradient.y2 = try requiredNumber(&tag, "y2");
                    },
                    .radial => {
                        gradient.x1 = try requiredNumber(&tag, "cx");
                        gradient.y1 = try requiredNumber(&tag, "cy");
                        gradient.x2 = gradient.x1;
                        gradient.y2 = gradient.y1;
                        gradient.radius = try requiredNumber(&tag, "r");
                        if (gradient.radius < 0) return error.InvalidSvg;
                        if (try tag.value("fx")) |value| if (try parseLength(value) != gradient.x1) return error.UnsupportedSvg;
                        if (try tag.value("fy")) |value| if (try parseLength(value) != gradient.y1) return error.UnsupportedSvg;
                    },
                }
                gradients[gradient_count] = gradient;
                active = gradient_count;
                gradient_count += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, tag.name, "stop")) {
            const index = active orelse continue;
            if (tag.closing or !tag.self_closing or try tag.value("style") != null or try tag.value("stop-opacity") != null) return error.UnsupportedSvg;
            var gradient = &gradients[index];
            if (gradient.stop_count == MAX_SVG_GRADIENT_STOPS) return error.UnsupportedSvg;
            const offset = try parseGradientOffset((try tag.value("offset")) orelse return error.InvalidSvg);
            if (gradient.stop_count != 0 and offset <= gradient.stops[gradient.stop_count - 1].offset) return error.UnsupportedSvg;
            gradient.stops[gradient.stop_count] = .{ .offset = offset, .color = try parseColor((try tag.value("stop-color")) orelse return error.InvalidSvg) };
            gradient.stop_count += 1;
            continue;
        }
        if (active != null and !tag.closing) return error.UnsupportedSvg;
    }
    if (active != null) return error.InvalidSvg;
}

fn parseGradientOffset(value: []const u8) Error!f32 {
    const percent = std.mem.endsWith(u8, value, "%");
    const number = try parseLength(if (percent) value[0 .. value.len - 1] else value);
    const offset = if (percent) number / 100 else number;
    if (offset < 0 or offset > 1) return error.InvalidSvg;
    return offset;
}

fn normalizeGradientStops(gradient: *Gradient) Error!void {
    if (gradient.stop_count == 0) return error.UnsupportedSvg;
    if (gradient.stops[0].offset > 0) {
        var index = gradient.stop_count;
        while (index > 0) {
            index -= 1;
            gradient.stops[index + 1] = gradient.stops[index];
        }
        gradient.stops[0] = .{ .offset = 0, .color = gradient.stops[1].color };
        gradient.stop_count += 1;
    }
    if (gradient.stops[gradient.stop_count - 1].offset < 1) {
        gradient.stops[gradient.stop_count] = .{ .offset = 1, .color = gradient.stops[gradient.stop_count - 1].color };
        gradient.stop_count += 1;
    }
    if (gradient.stop_count == 1) return error.UnsupportedSvg;
}

fn styleFromTag(tag: *const Tag, inherited: Style) Error!Style {
    if (try tag.value("style") != null) return error.UnsupportedSvg;
    var style = inherited;
    if (try tag.value("fill")) |value| style.fill = try parsePaint(value);
    if (try tag.value("stroke")) |value| style.stroke = try parsePaint(value);
    if (try tag.value("stroke-width")) |value| style.stroke_width = try parseLength(value);
    if (try tag.value("fill-opacity")) |value| style.fill_opacity = try parseOpacity(value);
    if (try tag.value("stroke-opacity")) |value| style.stroke_opacity = try parseOpacity(value);
    if (style.stroke_width < 0) return error.InvalidSvg;
    return style;
}

fn paint(out: *Writer, style: Style) Error!void {
    try applyOpacity(out, style.fill_opacity, style.stroke_opacity);
    switch (style.fill) {
        .none, .gradient => {},
        .color => |color| try setFillColor(out, color),
    }
    switch (style.stroke) {
        .none => {},
        .color => |color| {
            try setStrokeColor(out, color);
            try out.float(style.stroke_width);
            try out.write(" w\n");
        },
        .gradient => return error.UnsupportedSvg,
    }
    switch (style.fill) {
        .none => switch (style.stroke) {
            .none => try out.write("n\n"),
            .color => try out.write("S\n"),
            .gradient => return error.UnsupportedSvg,
        },
        .color => switch (style.stroke) {
            .none => try out.write("f\n"),
            .color => try out.write("B\n"),
            .gradient => return error.UnsupportedSvg,
        },
        .gradient => |index| {
            switch (style.stroke) {
                .none => {},
                else => return error.UnsupportedSvg,
            }
            gradients[index].used = true;
            try out.write("q\nW n\n/G");
            try out.integer(index + 1);
            try out.write(" sh\nQ\n");
        },
    }
}

fn opacityFromTag(tag: *const Tag) Error!f32 {
    return if (try tag.value("opacity")) |value| parseOpacity(value) else 1;
}

fn parseOpacity(value: []const u8) Error!f32 {
    const percent = std.mem.endsWith(u8, value, "%");
    const opacity = try parseLength(if (percent) value[0 .. value.len - 1] else value);
    const result = if (percent) opacity / 100 else opacity;
    if (result < 0 or result > 1) return error.InvalidSvg;
    return result;
}

fn applyOpacity(out: *Writer, fill: f32, stroke: f32) Error!void {
    if (fill == 1 and stroke == 1) return;
    const index = try opacityState(fill, stroke);
    try out.write("/GS");
    try out.integer(index + 1);
    try out.write(" gs\n");
}

fn opacityState(fill: f32, stroke: f32) Error!usize {
    for (opacity_states[0..opacity_state_count], 0..) |state, index| {
        if (state.fill == fill and state.stroke == stroke) return index;
    }
    if (opacity_state_count == opacity_states.len) return error.UnsupportedSvg;
    const index = opacity_state_count;
    opacity_states[index] = .{ .fill = fill, .stroke = stroke };
    opacity_state_count += 1;
    return index;
}

fn setFillColor(out: *Writer, color: Color) Error!void {
    try out.write("/CS0 cs\n");
    try out.float(color.red);
    try out.byte(' ');
    try out.float(color.green);
    try out.byte(' ');
    try out.float(color.blue);
    try out.write(" scn\n");
}

fn setStrokeColor(out: *Writer, color: Color) Error!void {
    try out.write("/CS0 CS\n");
    try out.float(color.red);
    try out.byte(' ');
    try out.float(color.green);
    try out.byte(' ');
    try out.float(color.blue);
    try out.write(" SCN\n");
}

fn parsePaint(value: []const u8) Error!Paint {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (value.len >= 7 and std.mem.startsWith(u8, value, "url(#") and value[value.len - 1] == ')') {
        const id = value[5 .. value.len - 1];
        for (gradients[0..gradient_count], 0..) |gradient, index| if (std.mem.eql(u8, gradient.id, id)) return .{ .gradient = index };
        return error.UnsupportedSvg;
    }
    return .{ .color = try parseColor(value) };
}

fn beginTransform(out: *Writer, mat: Mat) Error!void {
    try out.write("q\n");
    try out.float(mat.a);
    try out.byte(' ');
    try out.float(mat.b);
    try out.byte(' ');
    try out.float(mat.c);
    try out.byte(' ');
    try out.float(mat.d);
    try out.byte(' ');
    try out.float(mat.e);
    try out.byte(' ');
    try out.float(mat.f);
    try out.write(" cm\n");
}

fn transformFromTag(tag: *const Tag) Error!Mat {
    const value = (try tag.value("transform")) orelse return .{};
    var cursor: usize = 0;
    var result = Mat{};
    while (true) {
        skipWhitespace(value, &cursor);
        if (cursor == value.len) break;
        const name = readName(value, &cursor);
        if (name.len == 0) return error.InvalidSvg;
        skipWhitespace(value, &cursor);
        if (cursor == value.len or value[cursor] != '(') return error.InvalidSvg;
        cursor += 1;
        var args: [6]f32 = undefined;
        var count: usize = 0;
        while (true) {
            skipNumberSeparators(value, &cursor);
            if (cursor == value.len) return error.InvalidSvg;
            if (value[cursor] == ')') {
                cursor += 1;
                break;
            }
            if (count == args.len) return error.InvalidSvg;
            args[count] = try readNumber(value, &cursor);
            count += 1;
        }
        const next: Mat = if (std.mem.eql(u8, name, "matrix") and count == 6)
            .{ .a = args[0], .b = args[1], .c = args[2], .d = args[3], .e = args[4], .f = args[5] }
        else if (std.mem.eql(u8, name, "translate") and (count == 1 or count == 2))
            .{ .e = args[0], .f = if (count == 2) args[1] else 0 }
        else if (std.mem.eql(u8, name, "scale") and (count == 1 or count == 2))
            .{ .a = args[0], .d = if (count == 2) args[1] else args[0] }
        else if (std.mem.eql(u8, name, "rotate") and (count == 1 or count == 3)) blk: {
            const radians = args[0] * std.math.pi / 180.0;
            const rotation = Mat{ .a = std.math.cos(radians), .b = std.math.sin(radians), .c = -std.math.sin(radians), .d = std.math.cos(radians) };
            if (count == 1) break :blk rotation;
            break :blk matMultiply(matMultiply(.{ .e = args[1], .f = args[2] }, rotation), .{ .e = -args[1], .f = -args[2] });
        } else return error.UnsupportedSvg;
        result = matMultiply(result, next);
    }
    return result;
}

fn matMultiply(left: Mat, right: Mat) Mat {
    return .{
        .a = left.a * right.a + left.c * right.b,
        .b = left.b * right.a + left.d * right.b,
        .c = left.a * right.c + left.c * right.d,
        .d = left.b * right.c + left.d * right.d,
        .e = left.a * right.e + left.c * right.f + left.e,
        .f = left.b * right.e + left.d * right.f + left.f,
    };
}

fn parseColor(value: []const u8) Error!Color {
    if (value.len == 4 and value[0] == '#') {
        return .{ .red = @as(f32, @floatFromInt(try hex(value[1]))) / 15.0, .green = @as(f32, @floatFromInt(try hex(value[2]))) / 15.0, .blue = @as(f32, @floatFromInt(try hex(value[3]))) / 15.0 };
    }
    if (value.len != 7 or value[0] != '#') return error.UnsupportedSvg;
    return .{ .red = @as(f32, @floatFromInt((try hex(value[1])) * 16 + try hex(value[2]))) / 255.0, .green = @as(f32, @floatFromInt((try hex(value[3])) * 16 + try hex(value[4]))) / 255.0, .blue = @as(f32, @floatFromInt((try hex(value[5])) * 16 + try hex(value[6]))) / 255.0 };
}

fn hex(value: u8) Error!u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidSvg,
    };
}

fn point(out: *Writer, x: f32, y: f32, suffix: []const u8) Error!void {
    try out.float(x);
    try out.byte(' ');
    try out.float(y);
    try out.write(suffix);
}

fn curve(out: *Writer, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) Error!void {
    try out.float(x1);
    try out.byte(' ');
    try out.float(y1);
    try out.byte(' ');
    try out.float(x2);
    try out.byte(' ');
    try out.float(y2);
    try out.byte(' ');
    try out.float(x);
    try out.byte(' ');
    try out.float(y);
    try out.write(" c\n");
}

fn requiredNumber(tag: *const Tag, name: []const u8) Error!f32 {
    return parseLength((try tag.value(name)) orelse return error.InvalidSvg);
}

fn optionalNumber(tag: *const Tag, name: []const u8, fallback: f32) Error!f32 {
    return if (try tag.value(name)) |value| parseLength(value) else fallback;
}

fn parseLength(value: []const u8) Error!f32 {
    const number = std.fmt.parseFloat(f32, if (std.mem.endsWith(u8, value, "px")) value[0 .. value.len - 2] else value) catch return error.InvalidSvg;
    if (!std.math.isFinite(number)) return error.InvalidSvg;
    return number;
}

fn readNumber(input: []const u8, cursor: *usize) Error!f32 {
    skipNumberSeparators(input, cursor);
    const start = cursor.*;
    if (cursor.* < input.len and (input[cursor.*] == '+' or input[cursor.*] == '-')) cursor.* += 1;
    var digits = false;
    while (cursor.* < input.len and input[cursor.*] >= '0' and input[cursor.*] <= '9') : (cursor.* += 1) digits = true;
    if (cursor.* < input.len and input[cursor.*] == '.') {
        cursor.* += 1;
        while (cursor.* < input.len and input[cursor.*] >= '0' and input[cursor.*] <= '9') : (cursor.* += 1) digits = true;
    }
    if (!digits) return error.InvalidSvg;
    if (cursor.* < input.len and (input[cursor.*] == 'e' or input[cursor.*] == 'E')) {
        cursor.* += 1;
        if (cursor.* < input.len and (input[cursor.*] == '+' or input[cursor.*] == '-')) cursor.* += 1;
        const exponent_start = cursor.*;
        while (cursor.* < input.len and input[cursor.*] >= '0' and input[cursor.*] <= '9') : (cursor.* += 1) {}
        if (cursor.* == exponent_start) return error.InvalidSvg;
    }
    const value = std.fmt.parseFloat(f32, input[start..cursor.*]) catch return error.InvalidSvg;
    if (!std.math.isFinite(value)) return error.InvalidSvg;
    return value;
}

fn readTextCodepoint(input: []const u8, cursor: *usize) Error!u32 {
    if (input[cursor.*] == '&') {
        const entities = [_]struct { text: []const u8, codepoint: u32 }{ .{ .text = "&amp;", .codepoint = '&' }, .{ .text = "&lt;", .codepoint = '<' }, .{ .text = "&gt;", .codepoint = '>' }, .{ .text = "&quot;", .codepoint = '\"' }, .{ .text = "&apos;", .codepoint = '\'' } };
        for (entities) |entity| if (cursor.* + entity.text.len <= input.len and std.mem.eql(u8, input[cursor.* .. cursor.* + entity.text.len], entity.text)) {
            cursor.* += entity.text.len;
            return entity.codepoint;
        };
        return error.UnsupportedSvg;
    }
    const sequence = std.unicode.utf8ByteSequenceLength(input[cursor.*]) catch return error.InvalidSvg;
    if (cursor.* + sequence > input.len) return error.InvalidSvg;
    const codepoint = std.unicode.utf8Decode(input[cursor.* .. cursor.* + sequence]) catch return error.InvalidSvg;
    cursor.* += sequence;
    return codepoint;
}

fn onlyWhitespace(input: []const u8) bool {
    for (input) |byte| if (byte != ' ' and byte != '\n' and byte != '\r' and byte != '\t') return false;
    return true;
}
fn skipWhitespace(input: []const u8, cursor: *usize) void {
    while (cursor.* < input.len and (input[cursor.*] == ' ' or input[cursor.*] == '\n' or input[cursor.*] == '\r' or input[cursor.*] == '\t')) : (cursor.* += 1) {}
}
fn skipNumberSeparators(input: []const u8, cursor: *usize) void {
    while (cursor.* < input.len and (input[cursor.*] == ' ' or input[cursor.*] == '\n' or input[cursor.*] == '\r' or input[cursor.*] == '\t' or input[cursor.*] == ',')) : (cursor.* += 1) {}
}
fn readName(input: []const u8, cursor: *usize) []const u8 {
    const start = cursor.*;
    while (cursor.* < input.len and ((input[cursor.*] >= 'a' and input[cursor.*] <= 'z') or (input[cursor.*] >= 'A' and input[cursor.*] <= 'Z') or (input[cursor.*] >= '0' and input[cursor.*] <= '9') or input[cursor.*] == '-' or input[cursor.*] == '_' or input[cursor.*] == ':')) : (cursor.* += 1) {}
    return input[start..cursor.*];
}
fn isPathCommand(value: u8) bool {
    return switch (value) {
        'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'Q', 'q', 'Z', 'z', 'S', 's', 'T', 't', 'A', 'a' => true,
        else => false,
    };
}
fn hasNumber(input: []const u8, position: usize) bool {
    var cursor = position;
    skipNumberSeparators(input, &cursor);
    return cursor < input.len and ((input[cursor] >= '0' and input[cursor] <= '9') or input[cursor] == '+' or input[cursor] == '-' or input[cursor] == '.');
}

test "writes vector paths and embedded Inter text" {
    const svg = "<svg width=\"96\" height=\"48\"><rect x=\"0\" y=\"0\" width=\"96\" height=\"48\" fill=\"#fed\"/><path d=\"M 10 10 L 40 30 Z\" fill=\"#123\"/><text x=\"10\" y=\"36\" font-size=\"12\" font-family=\"Inter\">Hi</text></svg>";
    var output: [OUTPUT_CAP]u8 = undefined;
    const size = try renderSvg(svg, &output);
    try std.testing.expect(std.mem.startsWith(u8, output[0..size], "%PDF-1.7"));
    try std.testing.expect(std.mem.indexOf(u8, output[0..size], "/FontFile2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..size], "/Image") == null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..size], "<0048>") != null);
}

test "rejects SVG filters rather than rasterizing" {
    var output: [OUTPUT_CAP]u8 = undefined;
    try std.testing.expectError(error.UnsupportedSvg, renderSvg("<svg width=\"1\" height=\"1\"><filter/></svg>", &output));
}
