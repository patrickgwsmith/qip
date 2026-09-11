// CommonMark 0.31.2 renderer, generic over GFM extensions. Both markdown
// components build from this file: commonmark.0.31.2.zig instantiates
// Make(false) and gfm-commonmark.0.31.2.zig instantiates Make(true), so
// conformance and performance fixes land once and apply to both variants.
// GFM additions (tables, task lists, strikethrough, extended autolinks, tag
// filter) are gated on the comptime `enable_gfm` flag; gated-off code is
// eliminated from the non-GFM binary.
//
// Inline parsing uses the CommonMark spec appendix delimiter-stack algorithm
// (see "Inline parsing" section below): one tokenize pass, links resolved per
// the look-for-link procedure, emphasis via process-emphasis with
// openers_bottom, GFM strikethrough as a delimiter type. Landed 2026-08-18:
// linear on adversarial input (3 KB of "*a " dropped from ~16 s to ~50 ms) and
// differential divergence vs cmark 0.31.2 dropped from ~4.7% to ~0.2%
// (n=2000; tools/fuzz-markdown-vs-cmark.py). The frozen corpus
// (compliance/commonmark-differential-corpus.comply.wasm, 88 cases) is green
// and runs in test-comply.
// TODO(conformance): Remaining known cmark divergences, all in block-level
// list structure (~0.2% of fuzzed inputs, saved seeds reproduce via the
// fuzzer): (1) reference definitions inside list-item content are never
// collected; (2) sibling-item boundary detection when markers sit at
// in-between indents (e.g. "- a - b\n  - c\n   - d"); (3) list looseness when
// blank lines sit inside a fenced block in an item; (4) blank-line
// preservation inside unclosed fences in items. All four stem from the
// reassemble-into-tmp-buffers list architecture and are best fixed together
// with the line-classification work below.
// TODO(conformance): Delimiter flanking treats every byte >= 0x80 as
// punctuation (isDelimiterPunctuation); the spec wants Unicode whitespace and
// punctuation classes. ASCII-only fuzzing cannot see this — needs UCD-derived
// class tables like the case-fold ones.
// TODO(perf): Classify each line once (blank, indent cols, ATX/thematic/setext/fence/
// list-marker/html-block-start) into a table beside line_start/line_end.
// collectReferenceDefs, renderBlocks, paragraph lookahead, and the renderList
// prescans currently re-parse the same lines many times; nested lists also re-copy
// item content per nesting level via tmp buffers (4x input size -> ~4x time).
// TODO(perf): parseReferenceDefAt is quadratic on runs of consecutive reference
// definitions: after parsing a def's first line it appends every following
// non-blank line (to allow multi-line hrefs/titles) and re-runs
// parseReferenceDefTail on the growing buffer, so 4000 consecutive defs take
// ~16 s (measured 2026-08-17). Lookups are already O(1) via ref_table; the fix
// here is bounding the extension scan — a def can only extend while a title is
// plausibly open — and belongs with the block-level line-classification work.
// tools/test-markdown-pathological.sh ("ref-defs") guards it at reduced size.
// Measured 2026-08-18: a scan-and-bulk-copy Writer.writeEscaped showed no
// improvement over the byte-at-a-time loop on paragraph-, code-, and
// emphasis-heavy inputs (qip bench), so the naive loop stays. Still open:
// TODO(perf): benchmark -O ReleaseSmall against ReleaseFast (speed vs wasm
// size) via qip bench.
// TODO(conformance, GFM): Extended-autolink trimming (trimExtendedURLEnd, entity
// truncation, trailing-paren balancing) is only exercised by 22 fixture examples.
// Validate against cmark-gfm and grow the extension fixture accordingly.
// TODO(size): The full entity table costs ~35 KB of wasm as flat blobs + u16
// offsets. If size pressure returns, front-code the sorted names (shared-prefix
// lengths) before reaching for anything cleverer — measure with qip bench and
// keep the Options.full_entities escape hatch either way.
const std = @import("std");

// Generated fixture tables (see each file's header for source pins, and
// tools/generate-markdown-tables.py for regeneration):
// - html5-entities-table.zig: WHATWG entities.json — the semicolon-terminated
//   HTML5 named character references CommonMark 0.31.2 recognizes.
// - unicode-17-casefold-tables.zig: Unicode 17.0.0 UCD CaseFolding.txt
//   (statuses C+F) — full non-Turkic case folding for reference labels.
const entity_table = @import("html5-entities-table.zig");
const casefold = @import("unicode-17-casefold-tables.zig");

pub const Options = struct {
    gfm: bool,
    // The exhaustive conformance tables cost about 42 KB of wasm between them
    // (entities ~35 KB, case folding ~7 KB). Both default on — the published
    // components ship fully conforming — but embedders that need a smaller
    // binary can opt down to the minimal fallbacks, which still pass the
    // embedded CommonMark/GFM spec-example suites (the examples only exercise
    // a handful of entities and folds) but fail the exhaustive
    // compliance/html5-entities.comply.wasm and
    // compliance/unicode-17-casefold-labels.comply.wasm checkers.
    full_entities: bool = true,
    full_casefold: bool = true,
};

pub fn Make(comptime options: Options) type {
    return struct {
        const enable_gfm = options.gfm;
        pub const INPUT_CAP: u32 = 0x200000;
        pub const OUTPUT_CAP: u32 = 0x200000;

        pub const INPUT_CONTENT_TYPE = "text/markdown";
        pub const OUTPUT_CONTENT_TYPE = "text/html";

        const MAX_LINES: usize = 131072;
        const MAX_TMP: usize = @as(usize, INPUT_CAP);
        const MAX_REF_DEFS: usize = 8192;

        pub var input_buf: [INPUT_CAP]u8 = undefined;
        pub var output_buf: [OUTPUT_CAP]u8 = undefined;

        var line_start: [MAX_LINES]u32 = undefined;
        var line_end: [MAX_LINES]u32 = undefined;
        var line_next: [MAX_LINES]u32 = undefined;
        var lines_count: u32 = 0;

        var tmp_buf: [MAX_TMP]u8 = undefined;
        var tmp2_buf: [MAX_TMP]u8 = undefined;
        var tmp3_buf: [MAX_TMP]u8 = undefined;
        var tmp4_buf: [MAX_TMP]u8 = undefined;
        var ref_storage_buf: [MAX_TMP]u8 = undefined;
        var ref_storage_len: usize = 0;

        const RefDef = struct {
            label_hash: u64,
            href: []const u8,
            title: []const u8,
        };

        var ref_defs: [MAX_REF_DEFS]RefDef = undefined;
        var ref_defs_count: u32 = 0;

        // Open-addressing index over ref_defs keyed by label_hash: each slot
        // holds (index into ref_defs) + 1, with 0 meaning empty. Sized at 2x
        // MAX_REF_DEFS so the load factor stays below 0.5 and linear probing
        // stays short. Rebuilt (zeroed) at the start of every render.
        const REF_TABLE_SIZE: usize = MAX_REF_DEFS * 2;
        var ref_table: [REF_TABLE_SIZE]u32 = undefined;

        fn refTableFind(label_hash: u64) ?u32 {
            var slot = @as(usize, @truncate(label_hash)) & (REF_TABLE_SIZE - 1);
            while (ref_table[slot] != 0) : (slot = (slot + 1) & (REF_TABLE_SIZE - 1)) {
                const idx = ref_table[slot] - 1;
                if (ref_defs[@as(usize, @intCast(idx))].label_hash == label_hash) return idx;
            }
            return null;
        }

        fn refTableInsert(label_hash: u64, idx: u32) void {
            var slot = @as(usize, @truncate(label_hash)) & (REF_TABLE_SIZE - 1);
            while (ref_table[slot] != 0) : (slot = (slot + 1) & (REF_TABLE_SIZE - 1)) {}
            ref_table[slot] = idx + 1;
        }

        const Writer = struct {
            buf: []u8,
            idx: usize,
            overflow: bool,

            fn init(buf: []u8) Writer {
                return .{ .buf = buf, .idx = 0, .overflow = false };
            }

            fn len(self: *const Writer) u32 {
                return @as(u32, @intCast(self.idx));
            }

            fn writeByte(self: *Writer, b: u8) void {
                if (self.overflow) return;
                if (self.idx >= self.buf.len) {
                    self.overflow = true;
                    return;
                }
                self.buf[self.idx] = b;
                self.idx += 1;
            }

            fn writeSlice(self: *Writer, s: []const u8) void {
                if (self.overflow) return;
                if (self.idx + s.len > self.buf.len) {
                    const room = self.buf.len - self.idx;
                    if (room > 0) {
                        @memcpy(self.buf[self.idx..][0..room], s[0..room]);
                        self.idx += room;
                    }
                    self.overflow = true;
                    return;
                }
                @memcpy(self.buf[self.idx..][0..s.len], s);
                self.idx += s.len;
            }

            fn writeEscapedByte(self: *Writer, b: u8) void {
                switch (b) {
                    '&' => self.writeSlice("&amp;"),
                    '<' => self.writeSlice("&lt;"),
                    '>' => self.writeSlice("&gt;"),
                    '"' => self.writeSlice("&quot;"),
                    else => self.writeByte(b),
                }
            }

            fn writeEscaped(self: *Writer, s: []const u8) void {
                for (s) |b| self.writeEscapedByte(b);
            }
        };

        const Indent = struct {
            cols: usize,
            idx: usize,
        };

        const Fence = struct {
            indent: usize,
            marker: u8,
            count: usize,
            info: []const u8,
        };

        const ListKind = enum {
            unordered,
            ordered,
        };

        const ListMarker = struct {
            kind: ListKind,
            marker: u8,
            indent_cols: usize,
            marker_end: usize,
            content_start: usize,
            ordered_start: usize,
            prefix_spaces: usize,
        };

        const HtmlBlockType = enum {
            none,
            type1,
            type2,
            type3,
            type4,
            type5,
            type6,
            type7,
        };

        fn isAsciiAlpha(b: u8) bool {
            return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
        }

        fn isAsciiDigit(b: u8) bool {
            return b >= '0' and b <= '9';
        }

        fn isAsciiAlnum(b: u8) bool {
            return isAsciiAlpha(b) or isAsciiDigit(b);
        }

        fn isWhitespace(b: u8) bool {
            return b == ' ' or b == '\t';
        }

        fn isSpaceOrTab(b: u8) bool {
            return b == ' ' or b == '\t';
        }

        fn isTagNameChar(b: u8) bool {
            return isAsciiAlnum(b) or b == '-';
        }

        fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
            if (s.len < prefix.len) return false;
            var i: usize = 0;
            while (i < prefix.len) : (i += 1) {
                if (std.ascii.toLower(s[i]) != std.ascii.toLower(prefix[i])) return false;
            }
            return true;
        }

        fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
            if (needle.len == 0 or haystack.len < needle.len) return false;
            var i: usize = 0;
            while (i + needle.len <= haystack.len) : (i += 1) {
                var j: usize = 0;
                while (j < needle.len) : (j += 1) {
                    if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
                }
                if (j == needle.len) return true;
            }
            return false;
        }

        fn trimRightCR(s: []const u8) []const u8 {
            if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
            return s;
        }

        fn trimRightSpacesTabs(s0: []const u8) []const u8 {
            var s = trimRightCR(s0);
            while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t')) {
                s = s[0 .. s.len - 1];
            }
            return s;
        }

        fn trimAscii(s: []const u8) []const u8 {
            var a: usize = 0;
            var b: usize = s.len;
            while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r')) : (a += 1) {}
            while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\n' or s[b - 1] == '\r')) : (b -= 1) {}
            return s[a..b];
        }

        fn lowerAscii(b: u8) u8 {
            if (b >= 'A' and b <= 'Z') return b + 32;
            return b;
        }

        fn binarySearchU32(keys: []const u32, key: u32) ?usize {
            var lo: usize = 0;
            var hi: usize = keys.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (keys[mid] == key) return mid;
                if (keys[mid] < key) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return null;
        }

        // Minimal fold used when options.full_casefold is off: ASCII plus the
        // Latin-1/Greek/basic-Cyrillic ranges and the sharp-s expansions the
        // embedded spec examples exercise.
        fn foldReferenceCodepointMinimal(cp: u21) [3]u21 {
            if (cp == 0x00DF or cp == 0x1E9E) return .{ 's', 's', 0 };
            if (cp >= 'A' and cp <= 'Z') return .{ cp + 32, 0, 0 };
            if (cp >= 0x00C0 and cp <= 0x00D6) return .{ cp + 32, 0, 0 };
            if (cp >= 0x00D8 and cp <= 0x00DE) return .{ cp + 32, 0, 0 };
            if (cp >= 0x0391 and cp <= 0x03A1) return .{ cp + 32, 0, 0 };
            if (cp >= 0x03A3 and cp <= 0x03AB) return .{ cp + 32, 0, 0 };
            if (cp >= 0x0410 and cp <= 0x042F) return .{ cp + 32, 0, 0 };
            return .{ cp, 0, 0 };
        }

        // Full Unicode 17.0.0 case fold (CaseFolding.txt statuses C and F,
        // non-Turkic), as CommonMark's reference-label matching requires.
        // Tables and their UCD provenance: lib/unicode-17-casefold-tables.zig.
        // Returns 1-3 code points; unused trailing slots are zero.
        fn foldReferenceCodepoint(cp: u21) [3]u21 {
            if (!options.full_casefold) return foldReferenceCodepointMinimal(cp);
            const key = @as(u32, cp);
            if (binarySearchU32(&casefold.fold_multi_keys, key)) |idx| {
                const m = casefold.fold_multi_values[idx];
                return .{ @intCast(m[0]), @intCast(m[1]), @intCast(m[2]) };
            }
            if (binarySearchU32(&casefold.fold_map_keys, key)) |idx| {
                return .{ @intCast(casefold.fold_map_values[idx]), 0, 0 };
            }
            return .{ cp, 0, 0 };
        }

        fn normalizeLabelHash(label_raw: []const u8) u64 {
            const s = trimAscii(label_raw);
            var h: u64 = 14695981039346656037;
            var i: usize = 0;
            var in_ws = false;
            while (i < s.len) {
                if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '[' or s[i + 1] == ']')) {
                    const b = s[i + 1];
                    i += 2;
                    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
                        in_ws = true;
                        continue;
                    }
                    if (in_ws) {
                        h = (h ^ @as(u64, ' ')) *% 1099511628211;
                        in_ws = false;
                    }
                    h = (h ^ @as(u64, lowerAscii(b))) *% 1099511628211;
                    continue;
                }

                if (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r') {
                    i += 1;
                    in_ws = true;
                    continue;
                }

                if (in_ws) {
                    h = (h ^ @as(u64, ' ')) *% 1099511628211;
                    in_ws = false;
                }

                if (s[i] < 0x80) {
                    h = (h ^ @as(u64, lowerAscii(s[i]))) *% 1099511628211;
                    i += 1;
                    continue;
                }

                const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                    h = (h ^ @as(u64, s[i])) *% 1099511628211;
                    i += 1;
                    continue;
                };
                if (i + n > s.len) {
                    h = (h ^ @as(u64, s[i])) *% 1099511628211;
                    i += 1;
                    continue;
                }
                const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
                    h = (h ^ @as(u64, s[i])) *% 1099511628211;
                    i += 1;
                    continue;
                };
                const folded = foldReferenceCodepoint(cp);
                for (folded) |fcp| {
                    if (fcp == 0) break;
                    var enc: [4]u8 = undefined;
                    const m = std.unicode.utf8Encode(fcp, &enc) catch break;
                    var k: usize = 0;
                    while (k < m) : (k += 1) {
                        h = (h ^ @as(u64, enc[k])) *% 1099511628211;
                    }
                }
                i += n;
            }
            return h;
        }

        fn isBlankLine(s0: []const u8) bool {
            const s = trimRightCR(s0);
            for (s) |b| {
                if (!isWhitespace(b)) return false;
            }
            return true;
        }

        fn leadingIndent(s0: []const u8) Indent {
            const s = trimRightCR(s0);
            var cols: usize = 0;
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == ' ') {
                    cols += 1;
                    i += 1;
                    continue;
                }
                if (s[i] == '\t') {
                    cols = ((cols / 4) + 1) * 4;
                    i += 1;
                    continue;
                }
                break;
            }
            return .{ .cols = cols, .idx = i };
        }

        fn stripIndentCols(s0: []const u8, want_cols: usize) []const u8 {
            const s = trimRightCR(s0);
            var cols: usize = 0;
            var i: usize = 0;
            while (i < s.len and cols < want_cols) {
                if (s[i] == ' ') {
                    cols += 1;
                    i += 1;
                    continue;
                }
                if (s[i] == '\t') {
                    cols = ((cols / 4) + 1) * 4;
                    i += 1;
                    continue;
                }
                break;
            }
            return s[i..];
        }

        fn stripBlockIndentUpTo3(s0: []const u8) []const u8 {
            const s = trimRightCR(s0);
            const ind = leadingIndent(s);
            if (ind.cols <= 3) return s[ind.idx..];
            return s;
        }

        fn stripAllLeadingSpacesTabs(s0: []const u8) []const u8 {
            const s = trimRightCR(s0);
            var i: usize = 0;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
            return s[i..];
        }

        fn appendStrippedIndent(dst: *Writer, s0: []const u8, want_cols: usize) void {
            const s = trimRightCR(s0);
            var cols: usize = 0;
            var i: usize = 0;
            while (i < s.len and cols < want_cols) {
                if (s[i] == ' ') {
                    cols += 1;
                    i += 1;
                    continue;
                }
                if (s[i] == '\t') {
                    const next_cols = ((cols / 4) + 1) * 4;
                    i += 1;
                    if (next_cols <= want_cols) {
                        cols = next_cols;
                        continue;
                    }
                    const keep_spaces = next_cols - want_cols;
                    var k: usize = 0;
                    while (k < keep_spaces) : (k += 1) dst.writeByte(' ');
                    cols = want_cols;
                    break;
                }
                break;
            }
            dst.writeSlice(s[i..]);
        }

        fn appendListContinuation(dst: *Writer, s0: []const u8, base_cols: usize) void {
            const s = trimRightCR(s0);
            const ind = leadingIndent(s);
            const rel_cols = if (ind.cols > base_cols) ind.cols - base_cols else 0;
            var i: usize = 0;
            while (i < rel_cols) : (i += 1) dst.writeByte(' ');
            dst.writeSlice(s[ind.idx..]);
        }

        fn appendBlockquoteStripped(dst: *Writer, s0: []const u8) bool {
            const s = trimRightCR(s0);
            const ind = leadingIndent(s);
            if (ind.cols > 3 or ind.idx >= s.len or s[ind.idx] != '>') return false;

            var p = ind.idx + 1;
            var keep_cols: usize = 0;
            if (p < s.len and s[p] == ' ') {
                p += 1;
            } else if (p < s.len and s[p] == '\t') {
                const col_after_marker = ind.cols + 1;
                const tab_to = ((col_after_marker / 4) + 1) * 4;
                const tab_width = tab_to - col_after_marker;
                p += 1;
                if (tab_width > 0) keep_cols = tab_width - 1;
            }

            const rem = s[p..];
            const rem_ind = leadingIndent(rem);
            var k: usize = 0;
            while (k < keep_cols + rem_ind.cols) : (k += 1) dst.writeByte(' ');
            dst.writeSlice(rem[rem_ind.idx..]);
            return true;
        }

        fn splitLines(input: []const u8) bool {
            lines_count = 0;
            var cursor: usize = 0;
            while (cursor < input.len) {
                if (lines_count >= MAX_LINES) return false;
                const start = cursor;
                var end = cursor;
                while (end < input.len and input[end] != '\n') : (end += 1) {}
                var logical_end = end;
                if (logical_end > start and input[logical_end - 1] == '\r') {
                    logical_end -= 1;
                }
                if (end < input.len and input[end] == '\n') end += 1;

                const i = @as(usize, @intCast(lines_count));
                line_start[i] = @as(u32, @intCast(start));
                line_end[i] = @as(u32, @intCast(logical_end));
                line_next[i] = @as(u32, @intCast(end));
                lines_count += 1;
                cursor = end;
            }

            if (input.len == 0) {
                lines_count = 0;
            }
            return true;
        }

        fn lineSlice(input: []const u8, idx_u32: u32) []const u8 {
            const idx = @as(usize, @intCast(idx_u32));
            const a = @as(usize, @intCast(line_start[idx]));
            const b = @as(usize, @intCast(line_end[idx]));
            return input[a..b];
        }

        fn lineRawSlice(input: []const u8, idx_u32: u32) []const u8 {
            const idx = @as(usize, @intCast(idx_u32));
            const a = @as(usize, @intCast(line_start[idx]));
            const b = @as(usize, @intCast(line_next[idx]));
            return input[a..b];
        }

        fn parseATXHeading(line0: []const u8) ?struct { level: u8, text: []const u8 } {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return null;
            var i = ind.idx;
            var level: u8 = 0;
            var total_hashes: usize = 0;
            while (i < line.len and line[i] == '#') : (i += 1) {
                total_hashes += 1;
                if (level < 6) level += 1;
            }
            if (level == 0) return null;
            if (total_hashes > 6) return null;
            if (i < line.len and !isWhitespace(line[i])) return null;

            while (i < line.len and isWhitespace(line[i])) : (i += 1) {}
            var text = line[i..];

            // Trim optional closing sequence of #.
            var end = text.len;
            while (end > 0 and isWhitespace(text[end - 1])) : (end -= 1) {}
            var k = end;
            while (k > 0 and text[k - 1] == '#') : (k -= 1) {}
            if (k < end and (k == 0 or isWhitespace(text[k - 1]))) {
                while (k > 0 and isWhitespace(text[k - 1])) : (k -= 1) {}
                text = text[0..k];
            } else {
                text = text[0..end];
            }

            return .{ .level = level, .text = text };
        }

        fn parseThematicBreak(line0: []const u8) bool {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return false;
            var i = ind.idx;
            if (i >= line.len) return false;
            const marker = line[i];
            if (!(marker == '*' or marker == '-' or marker == '_')) return false;

            var count: usize = 0;
            while (i < line.len) : (i += 1) {
                const b = line[i];
                if (b == marker) {
                    count += 1;
                    continue;
                }
                if (isWhitespace(b)) continue;
                return false;
            }
            return count >= 3;
        }

        fn parseSetextUnderline(line0: []const u8) ?u8 {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return null;
            var i = ind.idx;
            if (i >= line.len) return null;
            const marker = line[i];
            if (!(marker == '=' or marker == '-')) return null;
            var count: usize = 0;
            while (i < line.len and line[i] == marker) : (i += 1) count += 1;
            if (count == 0) return null;
            while (i < line.len and isWhitespace(line[i])) : (i += 1) {}
            if (i != line.len) return null;
            return if (marker == '=') 1 else 2;
        }

        fn matchesType1Start(s: []const u8) bool {
            const prefixes = [_][]const u8{ "<pre", "<script", "<style", "<textarea" };
            for (prefixes) |p| {
                if (startsWithIgnoreCase(s, p)) {
                    if (s.len == p.len) return true;
                    const next = s[p.len];
                    return next == '>' or isSpaceOrTab(next);
                }
            }
            return false;
        }

        fn isType6TagName(name: []const u8) bool {
            const tags = [_][]const u8{
                "address", "article",  "aside",   "base",     "basefont", "blockquote", "body",
                "caption", "center",   "col",     "colgroup", "dd",       "details",    "dialog",
                "dir",     "div",      "dl",      "dt",       "fieldset", "figcaption", "figure",
                "footer",  "form",     "frame",   "frameset", "h1",       "h2",         "h3",
                "h4",      "h5",       "h6",      "head",     "header",   "hr",         "html",
                "iframe",  "legend",   "li",      "link",     "main",     "menu",       "menuitem",
                "nav",     "noframes", "ol",      "optgroup", "option",   "p",          "param",
                "search",  "section",  "summary", "table",    "tbody",    "td",         "tfoot",
                "th",      "thead",    "title",   "tr",       "track",    "ul",
            };
            for (tags) |tag| {
                if (std.ascii.eqlIgnoreCase(name, tag)) return true;
            }
            return false;
        }

        fn matchesType6Start(s: []const u8) bool {
            if (s.len < 3 or s[0] != '<') return false;
            var i: usize = 1;
            if (s[i] == '/') i += 1;
            if (i >= s.len or !isAsciiAlpha(s[i])) return false;
            const start = i;
            i += 1;
            while (i < s.len and isTagNameChar(s[i])) : (i += 1) {}
            const name = s[start..i];
            if (!isType6TagName(name)) return false;
            if (i >= s.len) return true;
            const c = s[i];
            return c == '>' or c == '/' or isSpaceOrTab(c);
        }

        fn matchesType7Start(s0: []const u8) bool {
            var s = s0;
            while (s.len > 0 and isSpaceOrTab(s[s.len - 1])) {
                s = s[0 .. s.len - 1];
            }
            if (s.len < 3 or s[0] != '<' or s[s.len - 1] != '>') return false;
            if (startsWithIgnoreCase(s, "<!") or startsWithIgnoreCase(s, "<?")) return false;
            return isPlausibleInlineTag(s[1 .. s.len - 1]);
        }

        fn detectHtmlBlockStart(line0: []const u8, prev_blank: bool) HtmlBlockType {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return .none;
            const s = line[ind.idx..];
            if (s.len == 0) return .none;

            if (matchesType1Start(s)) return .type1;
            if (std.mem.startsWith(u8, s, "<!--")) return .type2;
            if (std.mem.startsWith(u8, s, "<?")) return .type3;
            if (std.mem.startsWith(u8, s, "<!") and s.len >= 3 and isAsciiAlpha(s[2])) return .type4;
            if (std.mem.startsWith(u8, s, "<![") and startsWithIgnoreCase(s[3..], "CDATA[")) return .type5;
            if (matchesType6Start(s)) return .type6;
            if (prev_blank and matchesType7Start(s)) return .type7;
            return .none;
        }

        fn htmlBlockEnds(block: HtmlBlockType, line: []const u8, next_is_blank: bool) bool {
            return switch (block) {
                .type1 => containsIgnoreCase(line, "</pre>") or containsIgnoreCase(line, "</script>") or containsIgnoreCase(line, "</style>") or containsIgnoreCase(line, "</textarea>"),
                .type2 => std.mem.indexOf(u8, line, "-->") != null,
                .type3 => std.mem.indexOf(u8, line, "?>") != null,
                .type4 => std.mem.indexOfScalar(u8, line, '>') != null,
                .type5 => std.mem.indexOf(u8, line, "]]>") != null,
                .type6, .type7 => next_is_blank,
                else => false,
            };
        }

        fn parseFenceOpen(line0: []const u8) ?Fence {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return null;
            var i = ind.idx;
            if (i >= line.len) return null;
            const marker = line[i];
            if (!(marker == '`' or marker == '~')) return null;

            var count: usize = 0;
            while (i < line.len and line[i] == marker) : (i += 1) count += 1;
            if (count < 3) return null;

            if (marker == '`') {
                var j = i;
                while (j < line.len) : (j += 1) {
                    if (line[j] == '`') return null;
                }
            }

            while (i < line.len and isWhitespace(line[i])) : (i += 1) {}
            return .{
                .indent = ind.cols,
                .marker = marker,
                .count = count,
                .info = trimAscii(line[i..]),
            };
        }

        fn isFenceClose(line0: []const u8, fence: Fence) bool {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return false;
            var i = ind.idx;
            var count: usize = 0;
            while (i < line.len and line[i] == fence.marker) : (i += 1) count += 1;
            if (count < fence.count) return false;
            while (i < line.len) : (i += 1) {
                if (!isWhitespace(line[i])) return false;
            }
            return true;
        }

        fn parseListMarker(line0: []const u8) ?ListMarker {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            const i = ind.idx;
            if (i >= line.len) return null;

            if (line[i] == '-' or line[i] == '+' or line[i] == '*') {
                if (i + 1 < line.len and !isWhitespace(line[i + 1])) return null;
                var content = i + 1;
                var prefix_spaces: usize = 0;
                if (content < line.len and isWhitespace(line[content])) {
                    if (line[content] == '\t') {
                        const col_after_marker = ind.cols + (content - ind.idx);
                        const tab_to = ((col_after_marker / 4) + 1) * 4;
                        const tab_width = tab_to - col_after_marker;
                        if (tab_width > 0) prefix_spaces = tab_width - 1;
                        content += 1;
                    } else {
                        var p = content;
                        while (p < line.len and line[p] == ' ') : (p += 1) {}
                        const space_count = p - content;
                        if (space_count <= 4) {
                            content = p;
                        } else {
                            content += 1;
                        }
                    }
                }
                return .{
                    .kind = .unordered,
                    .marker = line[i],
                    .indent_cols = ind.cols,
                    .marker_end = i + 1,
                    .content_start = content,
                    .ordered_start = 1,
                    .prefix_spaces = prefix_spaces,
                };
            }

            var j = i;
            var num: usize = 0;
            var digits: usize = 0;
            while (j < line.len and isAsciiDigit(line[j]) and digits < 9) : (j += 1) {
                num = num * 10 + @as(usize, line[j] - '0');
                digits += 1;
            }
            if (digits == 0 or j >= line.len) return null;
            const delim = line[j];
            if (!(delim == '.' or delim == ')')) return null;
            if (j + 1 < line.len and !isWhitespace(line[j + 1])) return null;
            var content = j + 1;
            var prefix_spaces: usize = 0;
            if (content < line.len and isWhitespace(line[content])) {
                if (line[content] == '\t') {
                    const col_after_marker = ind.cols + (content - ind.idx);
                    const tab_to = ((col_after_marker / 4) + 1) * 4;
                    const tab_width = tab_to - col_after_marker;
                    if (tab_width > 0) prefix_spaces = tab_width - 1;
                    content += 1;
                } else {
                    var p = content;
                    while (p < line.len and line[p] == ' ') : (p += 1) {}
                    const space_count = p - content;
                    if (space_count <= 4) {
                        content = p;
                    } else {
                        content += 1;
                    }
                }
            }

            return .{
                .kind = .ordered,
                .marker = delim,
                .indent_cols = ind.cols,
                .marker_end = j + 1,
                .content_start = content,
                .ordered_start = num,
                .prefix_spaces = prefix_spaces,
            };
        }

        fn canInterruptParagraphWithList(line0: []const u8) bool {
            const ind = leadingIndent(line0);
            if (ind.cols > 3) return false;
            const mark = parseListMarker(line0) orelse return false;
            const line = trimRightCR(line0);
            if (mark.content_start >= line.len) return false;
            if (trimAscii(line[mark.content_start..]).len == 0) return false;
            if (mark.kind == .ordered and mark.ordered_start != 1) return false;
            return true;
        }

        fn isPunctuation(b: u8) bool {
            return (b >= 33 and b <= 47) or
                (b >= 58 and b <= 64) or
                (b >= 91 and b <= 96) or
                (b >= 123 and b <= 126);
        }

        fn isDelimiterPunctuation(b: u8) bool {
            return isPunctuation(b) or b >= 128;
        }

        fn isLikelyURIScheme(s: []const u8) bool {
            if (s.len < 2 or s.len > 32) return false;
            if (!isAsciiAlpha(s[0])) return false;
            var i: usize = 1;
            while (i < s.len) : (i += 1) {
                const b = s[i];
                if (isAsciiAlnum(b) or b == '+' or b == '-' or b == '.') continue;
                return false;
            }
            return true;
        }

        fn isEntity(s: []const u8) bool {
            if (s.len < 3) return false;
            if (s[0] != '&' or s[s.len - 1] != ';') return false;
            if (s[1] == '#') {
                if (s.len >= 4 and (s[2] == 'x' or s[2] == 'X')) {
                    if (s.len <= 4) return false;
                    var hex_digits: usize = 0;
                    var i: usize = 3;
                    while (i + 1 < s.len) : (i += 1) {
                        const b = s[i];
                        if (!((b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F'))) return false;
                        hex_digits += 1;
                    }
                    return hex_digits >= 1 and hex_digits <= 6;
                }
                var dec_digits: usize = 0;
                var j: usize = 2;
                if (j >= s.len - 1) return false;
                while (j < s.len - 1) : (j += 1) {
                    if (!isAsciiDigit(s[j])) return false;
                    dec_digits += 1;
                }
                return dec_digits >= 1 and dec_digits <= 7;
            }

            var k: usize = 1;
            while (k < s.len - 1) : (k += 1) {
                if (!isAsciiAlnum(s[k])) return false;
            }
            return true;
        }

        // Minimal entity set used when options.full_entities is off: the
        // names the embedded spec examples exercise.
        fn decodeNamedEntityMinimal(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "amp")) return "&";
            if (std.mem.eql(u8, name, "lt")) return "<";
            if (std.mem.eql(u8, name, "gt")) return ">";
            if (std.mem.eql(u8, name, "quot")) return "\"";
            if (std.mem.eql(u8, name, "apos")) return "'";
            if (std.mem.eql(u8, name, "nbsp")) return "\xC2\xA0";
            if (std.mem.eql(u8, name, "copy")) return "\xC2\xA9";
            if (std.mem.eql(u8, name, "AElig")) return "\xC3\x86";
            if (std.mem.eql(u8, name, "Auml")) return "\xC3\x84";
            if (std.mem.eql(u8, name, "auml")) return "\xC3\xA4";
            if (std.mem.eql(u8, name, "Dcaron")) return "\xC4\x8E";
            if (std.mem.eql(u8, name, "ouml")) return "\xC3\xB6";
            if (std.mem.eql(u8, name, "frac34")) return "\xC2\xBE";
            if (std.mem.eql(u8, name, "HilbertSpace")) return "\xE2\x84\x8B";
            if (std.mem.eql(u8, name, "DifferentialD")) return "\xE2\x85\x86";
            if (std.mem.eql(u8, name, "ClockwiseContourIntegral")) return "\xE2\x88\xB2";
            if (std.mem.eql(u8, name, "ngE")) return "\xE2\x89\xA7\xCC\xB8";
            return null;
        }

        // Binary search over the generated HTML5 entity table (provenance in
        // lib/html5-entities-table.zig). Names are matched bytewise and
        // case-sensitively, per the WHATWG list; only semicolon-terminated
        // references are present, matching CommonMark's entity rule.
        fn decodeNamedEntity(name: []const u8) ?[]const u8 {
            if (!options.full_entities) return decodeNamedEntityMinimal(name);
            var lo: usize = 0;
            var hi: usize = entity_table.count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const name_start: usize = if (mid == 0) 0 else entity_table.name_ends[mid - 1];
                const candidate = entity_table.names_blob[name_start..entity_table.name_ends[mid]];
                switch (std.mem.order(u8, name, candidate)) {
                    .eq => {
                        const value_start: usize = if (mid == 0) 0 else entity_table.value_ends[mid - 1];
                        return entity_table.values_blob[value_start..entity_table.value_ends[mid]];
                    },
                    .lt => hi = mid,
                    .gt => lo = mid + 1,
                }
            }
            return null;
        }

        fn decodeEntityToBuf(ent: []const u8, out_buf: *[8]u8) ?[]const u8 {
            if (ent.len < 3 or ent[0] != '&' or ent[ent.len - 1] != ';') return null;
            const body = ent[1 .. ent.len - 1];
            if (body.len == 0) return null;

            if (body[0] == '#') {
                var cp: u32 = 0;
                if (body.len >= 2 and (body[1] == 'x' or body[1] == 'X')) {
                    if (body.len == 2) return null;
                    var i: usize = 2;
                    while (i < body.len) : (i += 1) {
                        const b = body[i];
                        var d: u32 = 0;
                        if (b >= '0' and b <= '9') d = b - '0' else if (b >= 'a' and b <= 'f') d = 10 + (b - 'a') else if (b >= 'A' and b <= 'F') d = 10 + (b - 'A') else return null;
                        cp = cp * 16 + d;
                    }
                } else {
                    if (body.len == 1) return null;
                    var i: usize = 1;
                    while (i < body.len) : (i += 1) {
                        const b = body[i];
                        if (b < '0' or b > '9') return null;
                        cp = cp * 10 + (b - '0');
                    }
                }

                if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) cp = 0xFFFD;
                const n = std.unicode.utf8Encode(@as(u21, @intCast(cp)), out_buf) catch return null;
                return out_buf[0..n];
            }

            return decodeNamedEntity(body);
        }

        fn normalizeLinkDestination(raw: []const u8, out_buf: []u8) []const u8 {
            var w = Writer.init(out_buf);
            var i: usize = 0;
            while (i < raw.len) {
                if (raw[i] == '\\' and i + 1 < raw.len and isPunctuation(raw[i + 1])) {
                    w.writeByte(raw[i + 1]);
                    i += 2;
                    continue;
                }
                if (raw[i] == '&') {
                    var semi = i + 1;
                    while (semi < raw.len and semi - i <= 32 and raw[semi] != ';' and raw[semi] != '\n') : (semi += 1) {}
                    if (semi < raw.len and raw[semi] == ';') {
                        const ent = raw[i .. semi + 1];
                        var dec_buf: [8]u8 = undefined;
                        if (isEntity(ent)) {
                            if (decodeEntityToBuf(ent, &dec_buf)) |decoded| {
                                w.writeSlice(decoded);
                                i = semi + 1;
                                continue;
                            }
                        }
                    }
                }
                w.writeByte(raw[i]);
                i += 1;
            }
            return w.buf[0..w.idx];
        }

        const ParsedReferenceTail = struct {
            href: []const u8,
            title: []const u8,
        };

        fn parseReferenceDefTail(tail_raw: []const u8) ?ParsedReferenceTail {
            const s = trimAscii(tail_raw);
            if (s.len == 0) return null;

            var p: usize = 0;
            var href: []const u8 = "";
            if (s[p] == '<') {
                p += 1;
                const hs = p;
                while (p < s.len and s[p] != '>') : (p += 1) {
                    if (s[p] == '\n' or s[p] == '<') return null;
                }
                if (p >= s.len) return null;
                href = s[hs..p];
                p += 1;
            } else {
                const hs = p;
                var paren_depth: usize = 0;
                while (p < s.len and !isWhitespace(s[p]) and s[p] != '\n') {
                    if (s[p] == '\\' and p + 1 < s.len and isPunctuation(s[p + 1])) {
                        p += 2;
                        continue;
                    }
                    if (s[p] == '(') paren_depth += 1;
                    if (s[p] == ')') {
                        if (paren_depth == 0) break;
                        paren_depth -= 1;
                    }
                    p += 1;
                }
                if (paren_depth != 0) return null;
                if (p == hs) return null;
                href = s[hs..p];
            }

            var had_sep = false;
            while (p < s.len and (isWhitespace(s[p]) or s[p] == '\n' or s[p] == '\r')) : (p += 1) had_sep = true;
            var title: []const u8 = "";
            if (p < s.len) {
                if (!had_sep) return null;
                const open = s[p];
                var close_ch: u8 = 0;
                if (open == '"' or open == '\'') {
                    close_ch = open;
                } else if (open == '(') {
                    close_ch = ')';
                } else {
                    return null;
                }
                p += 1;
                const ts = p;
                while (p < s.len and s[p] != close_ch) {
                    if (s[p] == '\\' and p + 1 < s.len and isPunctuation(s[p + 1])) {
                        p += 2;
                        continue;
                    }
                    p += 1;
                }
                if (p >= s.len) return null;
                title = s[ts..p];
                p += 1;
                while (p < s.len and (isWhitespace(s[p]) or s[p] == '\n' or s[p] == '\r')) : (p += 1) {}
                if (p != s.len) return null;
            }

            return .{ .href = href, .title = title };
        }

        fn parseReferenceDefLine(line0: []const u8) ?struct { label_hash: u64, href: []const u8, title: []const u8 } {
            const line = trimRightCR(line0);
            const ind = leadingIndent(line);
            if (ind.cols > 3) return null;
            var i = ind.idx;
            if (i >= line.len or line[i] != '[') return null;
            i += 1;
            const label_start = i;
            const label_end = findUnescapedRightBracket(line, i) orelse return null;
            if (label_end == label_start) return null;
            const label = line[label_start..label_end];
            if (!isValidReferenceLabel(label)) return null;
            i = label_end + 1;
            if (i >= line.len or line[i] != ':') return null;
            i += 1;
            if (parseReferenceDefTail(line[i..])) |tail| {
                return .{
                    .label_hash = normalizeLabelHash(label),
                    .href = tail.href,
                    .title = tail.title,
                };
            }
            return null;
        }

        const ParsedReferenceDef = struct {
            label_hash: u64,
            href: []const u8,
            title: []const u8,
            next_idx: u32,
        };

        fn parseReferenceDefAt(input: []const u8, idx: u32) ?ParsedReferenceDef {
            const first = lineSlice(input, idx);
            const first_raw = trimRightCR(first);
            const ind = leadingIndent(first_raw);
            if (ind.cols > 3) return null;

            var line_idx = idx;
            var line = first_raw;
            var p = ind.idx;
            if (p >= line.len or line[p] != '[') return null;
            p += 1;

            var label_writer = Writer.init(tmp_buf[0..]);
            while (true) {
                while (p < line.len) : (p += 1) {
                    if (line[p] == ']' and !isEscapedAt(line, p)) {
                        if (label_writer.idx == 0) return null;
                        p += 1;
                        if (p >= line.len or line[p] != ':') return null;
                        p += 1;

                        const label = label_writer.buf[0..label_writer.idx];
                        if (!isValidReferenceLabel(label)) return null;
                        var combined = Writer.init(tmp3_buf[0..]);
                        combined.writeSlice(line[p..]);
                        if (combined.overflow) return null;

                        var best: ?ParsedReferenceDef = null;
                        if (parseReferenceDefTail(combined.buf[0..combined.idx])) |tail| {
                            best = .{
                                .label_hash = normalizeLabelHash(label),
                                .href = tail.href,
                                .title = tail.title,
                                .next_idx = line_idx + 1,
                            };
                        }

                        var j = line_idx + 1;
                        var extended = false;
                        while (j < lines_count) : (j += 1) {
                            const ln = lineSlice(input, j);
                            if (isBlankLine(ln)) break;

                            // Cheap termination rules keep runs of consecutive
                            // definitions linear (re-parsing the growing tail
                            // for every line is quadratic otherwise). They
                            // apply only before the first extension line is
                            // appended — after that a multi-line title may be
                            // open and its continuation lines can start with
                            // anything. Both are behavior-preserving:
                            // - A parse that already consumed a title can
                            //   never be extended: any appended content
                            //   follows the closed title and is invalid.
                            // - An href-only parse can only be extended by a
                            //   title, so the next line must begin with a
                            //   title opener.
                            if (!extended and best != null) {
                                if (best.?.title.len > 0) break;
                                const t = stripAllLeadingSpacesTabs(ln);
                                if (t.len == 0 or (t[0] != '"' and t[0] != '\'' and t[0] != '(')) break;
                            }
                            extended = true;

                            combined.writeByte('\n');
                            const li = leadingIndent(ln);
                            if (li.cols >= 4) {
                                combined.writeSlice(stripIndentCols(ln, 4));
                            } else {
                                combined.writeSlice(stripBlockIndentUpTo3(ln));
                            }
                            if (combined.overflow) break;

                            if (parseReferenceDefTail(combined.buf[0..combined.idx])) |tail| {
                                best = .{
                                    .label_hash = normalizeLabelHash(label),
                                    .href = tail.href,
                                    .title = tail.title,
                                    .next_idx = j + 1,
                                };
                            }
                        }

                        return best;
                    }
                    if (line[p] == '[' and !isEscapedAt(line, p)) return null;
                    label_writer.writeByte(line[p]);
                    if (label_writer.overflow) return null;
                }

                line_idx += 1;
                if (line_idx >= lines_count) return null;
                const next_line = lineSlice(input, line_idx);
                if (isBlankLine(next_line)) return null;
                label_writer.writeByte('\n');
                if (label_writer.overflow) return null;
                line = trimRightCR(next_line);
                p = 0;
            }
        }

        fn isValidReferenceLabel(label: []const u8) bool {
            if (label.len == 0 or label.len > 999) return false;
            var has_non_ws = false;
            var i: usize = 0;
            while (i < label.len) : (i += 1) {
                if ((label[i] == '[' or label[i] == ']') and !isEscapedAt(label, i)) return false;
                if (!(label[i] == ' ' or label[i] == '\t' or label[i] == '\n' or label[i] == '\r')) has_non_ws = true;
            }
            return has_non_ws;
        }

        // Collects reference definitions from inside one list item,
        // mirroring how the renderer walks item content: definitions parse
        // only at block-start positions within the item (the marker line's
        // own content, or after a blank line, or directly after another
        // definition — they stack), and never inside an open paragraph,
        // fenced block, or indented code. Definitions inside nested
        // containers are conservatively not collected, and multi-line
        // definition tails (title on a following line) are not recognized
        // inside items. Returns the line index after the walked extent.
        fn collectListItemDefs(input: []const u8, marker_idx: u32, mark: ListMarker) u32 {
            const first = trimRightCR(lineSlice(input, marker_idx));
            const base = listItemContinuationBase(first, mark);
            var at_block_start = true;
            var para_open = false;
            var fence: ?Fence = null;

            if (mark.content_start < first.len and !isBlankLine(first[mark.content_start..])) {
                const content = first[mark.content_start..];
                if (parseReferenceDefLine(content)) |p| {
                    if (!pushReferenceDef(p.label_hash, p.href, p.title)) return marker_idx + 1;
                } else if (parseFenceOpen(content)) |f| {
                    fence = f;
                    at_block_start = false;
                } else {
                    para_open = contentOpensParagraph(content);
                    at_block_start = false;
                }
            }

            var i = marker_idx + 1;
            while (i < lines_count) : (i += 1) {
                const ln = lineSlice(input, i);
                if (isBlankLine(ln)) {
                    if (fence == null) {
                        at_block_start = true;
                        para_open = false;
                    }
                    continue;
                }
                const ind = leadingIndent(ln);
                if (ind.cols >= base) {
                    const stripped = stripIndentCols(ln, base);
                    if (fence) |f| {
                        if (isFenceClose(stripped, f)) {
                            fence = null;
                            at_block_start = true;
                        }
                        continue;
                    }
                    if (at_block_start) {
                        if (leadingIndent(stripped).cols >= 4) {
                            at_block_start = false;
                            continue;
                        }
                        if (parseReferenceDefLine(stripped)) |p| {
                            if (!pushReferenceDef(p.label_hash, p.href, p.title)) return i + 1;
                            continue;
                        }
                        if (parseFenceOpen(stripped)) |f| {
                            fence = f;
                            at_block_start = false;
                            continue;
                        }
                        para_open = contentOpensParagraph(stripped);
                        at_block_start = false;
                        continue;
                    }
                    if (para_open) {
                        if (parseSetextUnderline(stripped) != null or parseATXHeading(stripped) != null or
                            parseThematicBreak(stripped) or canInterruptParagraphWithList(stripped))
                        {
                            para_open = false;
                        } else if (parseFenceOpen(stripped)) |f| {
                            fence = f;
                            para_open = false;
                        }
                    }
                    continue;
                }
                if (fence != null) break;
                if (para_open and canLazyContinueListParagraph(ln)) {
                    if (!contentOpensParagraph(ln)) para_open = false;
                    continue;
                }
                break;
            }
            return i;
        }

        // Whether everything from start_k to the end of an item's content
        // (indent >= base) consists only of blank lines and reference
        // definitions. Used for looseness: definitions render nothing, so a
        // blank followed only by definitions behaves like a trailing blank.
        fn itemTailIsDefsOnly(input: []const u8, start_k: u32, base: usize) bool {
            var k = start_k;
            while (k < lines_count) : (k += 1) {
                const ln = lineSlice(input, k);
                if (isBlankLine(ln)) continue;
                if (leadingIndent(ln).cols < base) {
                    // A following sibling item means the blank separates items
                    // (spec example 318: the list is loose); a non-item line
                    // ends the list, making the blank trailing.
                    return parseListMarker(ln) == null;
                }
                if (parseReferenceDefLine(stripIndentCols(ln, base)) == null) return false;
            }
            return true;
        }

        fn tmpTailIsDefsOnly(text: []const u8, start_cursor: usize, base: usize) bool {
            var cur = start_cursor;
            while (nextTmpLine(text, &cur)) |ln| {
                if (isBlankLine(ln)) continue;
                if (leadingIndent(ln).cols < base) {
                    return parseListMarker(ln) == null;
                }
                if (parseReferenceDefLine(stripIndentCols(ln, base)) == null) return false;
            }
            return true;
        }

        fn collectReferenceDefs(input: []const u8) void {
            ref_defs_count = 0;
            ref_storage_len = 0;
            @memset(ref_table[0..], 0);
            var i: u32 = 0;
            while (i < lines_count and ref_defs_count < MAX_REF_DEFS) {
                const line = lineSlice(input, i);
                if (isBlankLine(line)) {
                    i += 1;
                    continue;
                }

                const ind = leadingIndent(line);
                if (ind.cols >= 4) {
                    i += 1;
                    while (i < lines_count) {
                        const ln = lineSlice(input, i);
                        if (isBlankLine(ln)) {
                            i += 1;
                            continue;
                        }
                        if (leadingIndent(ln).cols >= 4) {
                            i += 1;
                            continue;
                        }
                        break;
                    }
                    continue;
                }

                if (parseFenceOpen(line)) |fence| {
                    i += 1;
                    while (i < lines_count) : (i += 1) {
                        if (isFenceClose(lineSlice(input, i), fence)) {
                            i += 1;
                            break;
                        }
                    }
                    continue;
                }

                const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
                const html_block = detectHtmlBlockStart(line, prev_blank);
                if (html_block != .none) {
                    while (i < lines_count) : (i += 1) {
                        const next_is_blank = i + 1 >= lines_count or isBlankLine(lineSlice(input, i + 1));
                        if (htmlBlockEnds(html_block, trimRightCR(lineSlice(input, i)), next_is_blank)) {
                            if ((html_block == .type6 or html_block == .type7) and i + 1 < lines_count and isBlankLine(lineSlice(input, i + 1))) {
                                i += 1;
                            }
                            i += 1;
                            break;
                        }
                    }
                    continue;
                }

                if (parseReferenceDefAt(input, i)) |def| {
                    if (!pushReferenceDef(def.label_hash, def.href, def.title)) break;
                    i = def.next_idx;
                    continue;
                }

                if (parseATXHeading(line) != null) {
                    i += 1;
                    continue;
                }
                if (parseThematicBreak(line)) {
                    i += 1;
                    continue;
                }
                if (parseListMarker(line)) |m| {
                    i = collectListItemDefs(input, i, m);
                    continue;
                }
                if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') {
                    var stripped = Writer.init(tmp2_buf[0..]);
                    if (appendBlockquoteStripped(&stripped, line)) {
                        if (parseReferenceDefLine(stripped.buf[0..stripped.idx])) |p| {
                            if (!pushReferenceDef(p.label_hash, p.href, p.title)) break;
                        }
                    }
                    i += 1;
                    continue;
                }

                var j = i + 1;
                while (j < lines_count) : (j += 1) {
                    const l = lineSlice(input, j);
                    if (isBlankLine(l)) break;
                    if (parseATXHeading(l) != null) break;
                    if (parseThematicBreak(l)) break;
                    if (parseFenceOpen(l) != null) break;
                    if (canInterruptParagraphWithList(l)) break;
                    const l_prev_blank = if (j == 0) true else isBlankLine(lineSlice(input, j - 1));
                    const l_html_block = detectHtmlBlockStart(l, l_prev_blank);
                    if (l_html_block != .none and l_html_block != .type7) break;
                    const li = leadingIndent(l);
                    if (li.cols <= 3 and li.idx < l.len and l[li.idx] == '>') break;
                }
                i = j;
            }
        }

        fn pushReferenceDef(label_hash: u64, href_src: []const u8, title_src: []const u8) bool {
            if (refTableFind(label_hash) != null) return true;
            if (ref_defs_count >= MAX_REF_DEFS) return false;
            if (ref_storage_len + href_src.len + title_src.len > ref_storage_buf.len) return false;

            const href_start = ref_storage_len;
            @memcpy(ref_storage_buf[href_start..][0..href_src.len], href_src);
            ref_storage_len += href_src.len;
            const href = ref_storage_buf[href_start..ref_storage_len];

            const title_start = ref_storage_len;
            @memcpy(ref_storage_buf[title_start..][0..title_src.len], title_src);
            ref_storage_len += title_src.len;
            const title = ref_storage_buf[title_start..ref_storage_len];

            ref_defs[@as(usize, @intCast(ref_defs_count))] = .{
                .label_hash = label_hash,
                .href = href,
                .title = title,
            };
            refTableInsert(label_hash, ref_defs_count);
            ref_defs_count += 1;
            return true;
        }

        fn lookupRefDef(label: []const u8) ?RefDef {
            const h = normalizeLabelHash(label);
            if (refTableFind(h)) |idx| return ref_defs[@as(usize, @intCast(idx))];
            return null;
        }

        fn writeLinkAttrEscaped(out: *Writer, src: []const u8) void {
            var decoded = Writer.init(tmp3_buf[0..]);
            var i: usize = 0;
            while (i < src.len and !decoded.overflow) {
                if (src[i] == '\\' and i + 1 < src.len and isPunctuation(src[i + 1])) {
                    decoded.writeByte(src[i + 1]);
                    i += 2;
                    continue;
                }
                if (src[i] == '&') {
                    var semi = i + 1;
                    while (semi < src.len and semi - i <= 32 and src[semi] != ';' and src[semi] != '\n') : (semi += 1) {}
                    if (semi < src.len and src[semi] == ';') {
                        const ent = src[i .. semi + 1];
                        var dec_buf: [8]u8 = undefined;
                        if (isEntity(ent)) {
                            if (decodeEntityToBuf(ent, &dec_buf)) |decoded_ent| {
                                decoded.writeSlice(decoded_ent);
                                i = semi + 1;
                                continue;
                            }
                        }
                    }
                }
                decoded.writeByte(src[i]);
                i += 1;
            }
            if (decoded.overflow) return;

            var j: usize = 0;
            while (j < decoded.idx) : (j += 1) {
                out.writeEscapedByte(decoded.buf[j]);
            }
        }

        fn isURISafeByte(b: u8) bool {
            if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')) return true;
            return b == '-' or b == '_' or b == '.' or b == '~' or
                b == ':' or b == '/' or b == '?' or b == '#' or
                b == '@' or
                b == '!' or b == '$' or b == '&' or b == '\'' or
                b == '(' or b == ')' or b == '*' or b == '+' or
                b == ',' or b == ';' or b == '=' or b == '%';
        }

        fn writeURIAttrEscaped(out: *Writer, src: []const u8) void {
            var decoded = Writer.init(tmp3_buf[0..]);
            var i: usize = 0;
            while (i < src.len and !decoded.overflow) {
                if (src[i] == '\\' and i + 1 < src.len and isPunctuation(src[i + 1])) {
                    decoded.writeByte(src[i + 1]);
                    i += 2;
                    continue;
                }
                if (src[i] == '&') {
                    var semi = i + 1;
                    while (semi < src.len and semi - i <= 32 and src[semi] != ';' and src[semi] != '\n') : (semi += 1) {}
                    if (semi < src.len and src[semi] == ';') {
                        const ent = src[i .. semi + 1];
                        var dec_buf: [8]u8 = undefined;
                        if (isEntity(ent)) {
                            if (decodeEntityToBuf(ent, &dec_buf)) |decoded_ent| {
                                decoded.writeSlice(decoded_ent);
                                i = semi + 1;
                                continue;
                            }
                        }
                    }
                }
                decoded.writeByte(src[i]);
                i += 1;
            }
            if (decoded.overflow) return;

            const hex = "0123456789ABCDEF";
            var j: usize = 0;
            while (j < decoded.idx) : (j += 1) {
                const b = decoded.buf[j];
                if (isURISafeByte(b)) {
                    switch (b) {
                        '&' => out.writeSlice("&amp;"),
                        '"' => out.writeSlice("&quot;"),
                        '\'' => out.writeSlice("&#x27;"),
                        else => out.writeByte(b),
                    }
                } else {
                    out.writeByte('%');
                    out.writeByte(hex[(b >> 4) & 0x0F]);
                    out.writeByte(hex[b & 0x0F]);
                }
            }
        }

        fn writeRawURIAttrEscaped(out: *Writer, src: []const u8) void {
            const hex = "0123456789ABCDEF";
            for (src) |b| {
                if (isURISafeByte(b) and b != '[' and b != ']') {
                    switch (b) {
                        '&' => out.writeSlice("&amp;"),
                        '"' => out.writeSlice("&quot;"),
                        '\'' => out.writeSlice("&#x27;"),
                        else => out.writeByte(b),
                    }
                } else {
                    out.writeByte('%');
                    out.writeByte(hex[(b >> 4) & 0x0F]);
                    out.writeByte(hex[b & 0x0F]);
                }
            }
        }

        fn writeCodeSpan(out: *Writer, src: []const u8) void {
            var norm = Writer.init(tmp3_buf[0..]);
            for (src) |b| {
                if (b == '\n') {
                    norm.writeByte(' ');
                } else {
                    norm.writeByte(b);
                }
            }
            if (norm.overflow) return;

            var start: usize = 0;
            var end: usize = norm.idx;
            if (end >= 2 and norm.buf[0] == ' ' and norm.buf[end - 1] == ' ') {
                var all_spaces = true;
                var i: usize = 0;
                while (i < end) : (i += 1) {
                    if (norm.buf[i] != ' ') {
                        all_spaces = false;
                        break;
                    }
                }
                if (!all_spaces) {
                    start += 1;
                    end -= 1;
                }
            }

            var i: usize = start;
            while (i < end) : (i += 1) {
                out.writeEscapedByte(norm.buf[i]);
            }
        }

        fn writeAutolink(out: *Writer, inner: []const u8) bool {
            if (inner.len == 0) return false;
            for (inner) |b| {
                if (b == '<' or b == '>' or b == ' ' or b == '\t' or b == '\n') return false;
            }

            if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
                if (!isLikelyURIScheme(inner[0..colon])) return false;
                out.writeSlice("<a href=\"");
                writeRawURIAttrEscaped(out, inner);
                out.writeSlice("\">");
                out.writeEscaped(inner);
                out.writeSlice("</a>");
                return true;
            }

            if (isValidEmailAutolink(inner)) {
                out.writeSlice("<a href=\"mailto:");
                writeRawURIAttrEscaped(out, inner);
                out.writeSlice("\">");
                out.writeEscaped(inner);
                out.writeSlice("</a>");
                return true;
            }

            return false;
        }

        fn findMatchingRun(s: []const u8, from: usize, marker: u8, count: usize) ?usize {
            var i = from;
            while (i < s.len) {
                if (s[i] != marker) {
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < s.len and s[j] == marker) : (j += 1) {}
                const n = j - i;
                if (n == count) return i;
                i = j;
            }
            return null;
        }

        fn isEscapedAt(s: []const u8, idx: usize) bool {
            if (idx == 0) return false;
            var bs: usize = 0;
            var i = idx;
            while (i > 0) {
                i -= 1;
                if (s[i] == '\\') {
                    bs += 1;
                    continue;
                }
                break;
            }
            return (bs & 1) == 1;
        }

        fn findUnescapedRightBracket(s: []const u8, from: usize) ?usize {
            var depth: usize = 0;
            var i = from;
            while (i < s.len) : (i += 1) {
                if (isEscapedAt(s, i) or isInsideCodeSpan(s, from, i) or isInsideInlineTag(s, from, i)) continue;
                if (s[i] == '[') {
                    depth += 1;
                    continue;
                }
                if (s[i] == ']') {
                    if (depth == 0) return i;
                    depth -= 1;
                    continue;
                }
            }
            return null;
        }

        fn isInlineSpace(b: u8) bool {
            return b == ' ' or b == '\t' or b == '\n' or b == '\r';
        }

        fn isInlineSpaceAt(s: []const u8, idx: usize) bool {
            const b = s[idx];
            if (isInlineSpace(b)) return true;
            if (b == 0xC2 and idx + 1 < s.len and s[idx + 1] == 0xA0) return true;
            if (b == 0xA0 and idx > 0 and s[idx - 1] == 0xC2) return true;
            return false;
        }

        fn canOpenDelimiter(s: []const u8, pos: usize, run_len: usize, marker: u8) bool {
            const prev_opt: ?u8 = if (pos == 0) null else s[pos - 1];
            const next_idx = pos + run_len;
            const next_opt: ?u8 = if (next_idx >= s.len) null else s[next_idx];

            const prev_ws = prev_opt == null or isInlineSpaceAt(s, pos - 1);
            const next_ws = next_opt == null or isInlineSpaceAt(s, next_idx);
            const prev_punct = prev_opt != null and isDelimiterPunctuation(prev_opt.?);
            const next_punct = next_opt != null and isDelimiterPunctuation(next_opt.?);

            if (marker == '_' and prev_opt != null and next_opt != null and prev_opt.? >= 128 and next_opt.? >= 128) {
                return false;
            }

            const left_flanking = !next_ws and (!next_punct or prev_ws or prev_punct);
            const right_flanking = !prev_ws and (!prev_punct or next_ws or next_punct);

            if (marker == '_') {
                return left_flanking and (!right_flanking or prev_punct);
            }
            return left_flanking;
        }

        fn canCloseDelimiter(s: []const u8, pos: usize, run_len: usize, marker: u8) bool {
            const prev_opt: ?u8 = if (pos == 0) null else s[pos - 1];
            const next_idx = pos + run_len;
            const next_opt: ?u8 = if (next_idx >= s.len) null else s[next_idx];

            const prev_ws = prev_opt == null or isInlineSpaceAt(s, pos - 1);
            const next_ws = next_opt == null or isInlineSpaceAt(s, next_idx);
            const prev_punct = prev_opt != null and isDelimiterPunctuation(prev_opt.?);
            const next_punct = next_opt != null and isDelimiterPunctuation(next_opt.?);

            if (marker == '_' and prev_opt != null and next_opt != null and prev_opt.? >= 128 and next_opt.? >= 128) {
                return false;
            }

            const left_flanking = !next_ws and (!next_punct or prev_ws or prev_punct);
            const right_flanking = !prev_ws and (!prev_punct or next_ws or next_punct);

            if (marker == '_') {
                return right_flanking and (!left_flanking or next_punct);
            }
            return right_flanking;
        }

        fn isInsideCodeSpan(s: []const u8, from: usize, pos: usize) bool {
            var i = from;
            while (i < pos and i < s.len) {
                if (s[i] != '`') {
                    i += 1;
                    continue;
                }
                var ticks: usize = 1;
                while (i + ticks < s.len and s[i + ticks] == '`') : (ticks += 1) {}
                if (findMatchingRun(s, i + ticks, '`', ticks)) |end_idx| {
                    if (end_idx >= pos) return true;
                    i = end_idx + ticks;
                    continue;
                }
                i += ticks;
            }
            return false;
        }

        fn isInsideInlineTag(s: []const u8, from: usize, pos: usize) bool {
            var i = from;
            while (i < pos and i < s.len) {
                if (s[i] != '<') {
                    i += 1;
                    continue;
                }
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '>')) |gt| {
                    if (gt >= pos) return true;
                    i = gt + 1;
                    continue;
                }
                i += 1;
            }
            return false;
        }

        fn canContinueTagAfterNewline(prefix: []const u8) bool {
            if (prefix.len == 0) return false;
            var i: usize = 0;
            const is_close = prefix[0] == '/';
            if (is_close) {
                i = 1;
                if (i >= prefix.len or !isAsciiAlpha(prefix[i])) return false;
            } else if (!isAsciiAlpha(prefix[0])) {
                return false;
            }
            i += 1;
            while (i < prefix.len and isTagNameChar(prefix[i])) : (i += 1) {}

            if (is_close) {
                while (i < prefix.len and isSpaceOrTab(prefix[i])) : (i += 1) {}
                return i == prefix.len;
            }

            var quote: u8 = 0;
            while (i < prefix.len) : (i += 1) {
                const ch = prefix[i];
                if (quote != 0) {
                    if (ch == quote) quote = 0;
                    continue;
                }
                if (ch == '"' or ch == '\'') {
                    quote = ch;
                    continue;
                }
                if (ch == '<') return false;
                if (isSpaceOrTab(ch) or isAsciiAlnum(ch) or ch == '_' or ch == ':' or ch == '-' or ch == '.' or ch == '=' or ch == '/') continue;
                return false;
            }
            return true;
        }

        fn isPlausibleInlineTag(inner: []const u8) bool {
            if (inner.len == 0) return false;
            var i: usize = 0;
            const is_close = inner[0] == '/';
            if (is_close) {
                i = 1;
                if (i >= inner.len or !isAsciiAlpha(inner[i])) return false;
            } else if (!isAsciiAlpha(inner[i])) {
                return false;
            }
            i += 1;
            while (i < inner.len and isTagNameChar(inner[i])) : (i += 1) {}

            if (is_close) {
                while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
                return i == inner.len;
            }
            if (i < inner.len and !(isSpaceOrTab(inner[i]) or inner[i] == '\n' or inner[i] == '/')) return false;

            while (true) {
                while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
                if (i >= inner.len) return true;
                if (inner[i] == '/') {
                    i += 1;
                    return i == inner.len;
                }

                if (!isAttrNameChar(inner[i])) return false;
                i += 1;
                while (i < inner.len and isAttrNameChar(inner[i])) : (i += 1) {}

                while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
                if (i >= inner.len) return true;
                if (inner[i] != '=') continue;

                i += 1;
                while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
                if (i >= inner.len) return false;

                if (inner[i] == '"' or inner[i] == '\'') {
                    const quote = inner[i];
                    i += 1;
                    while (i < inner.len and inner[i] != quote) : (i += 1) {}
                    if (i >= inner.len) return false;
                    i += 1;
                    if (i < inner.len and !(isSpaceOrTab(inner[i]) or inner[i] == '\n' or inner[i] == '/')) return false;
                    continue;
                }

                if (!isUnquotedAttrValueChar(inner[i])) return false;
                i += 1;
                while (i < inner.len and isUnquotedAttrValueChar(inner[i])) : (i += 1) {}
                if (i < inner.len and !(isSpaceOrTab(inner[i]) or inner[i] == '\n' or inner[i] == '/')) return false;
            }
        }

        fn isAttrNameChar(b: u8) bool {
            return isAsciiAlnum(b) or b == '_' or b == ':' or b == '-' or b == '.';
        }

        fn isUnquotedAttrValueChar(b: u8) bool {
            if (isSpaceOrTab(b) or b == '\n') return false;
            if (b == '"' or b == '\'' or b == '=' or b == '<' or b == '>' or b == '`') return false;
            return true;
        }

        fn isTagFilterName(name: []const u8) bool {
            const names = [_][]const u8{
                "title",    "textarea", "style",     "xmp", "iframe", "noembed",
                "noframes", "script",   "plaintext",
            };
            for (names) |candidate| {
                if (name.len == candidate.len and std.ascii.eqlIgnoreCase(name, candidate)) return true;
            }
            return false;
        }

        fn isFilteredTagAt(s: []const u8, less_than: usize) bool {
            if (less_than >= s.len or s[less_than] != '<') return false;
            var i = less_than + 1;
            if (i < s.len and s[i] == '/') i += 1;
            const start = i;
            while (i < s.len and isAsciiAlpha(s[i])) : (i += 1) {}
            if (i == start or !isTagFilterName(s[start..i])) return false;
            return i >= s.len or isInlineSpace(s[i]) or s[i] == '>' or s[i] == '/';
        }

        fn writeTagFiltered(out: *Writer, s: []const u8) void {
            if (!enable_gfm) {
                out.writeSlice(s);
                return;
            }
            for (s, 0..) |byte, i| {
                if (byte == '<' and isFilteredTagAt(s, i)) {
                    out.writeSlice("&lt;");
                } else {
                    out.writeByte(byte);
                }
            }
        }

        fn isExtendedURLBoundary(s: []const u8, i: usize) bool {
            if (i == 0) return true;
            const prev = s[i - 1];
            return !isAsciiAlnum(prev) and prev != '_' and prev != '-';
        }

        fn isURLTrailingPunctuation(byte: u8) bool {
            return byte == '.' or byte == ',' or byte == ':' or byte == ';' or byte == '?' or byte == '!';
        }

        fn truncateEntitySuffix(s: []const u8, start: usize, end: usize) usize {
            var i = start;
            while (i < end) : (i += 1) {
                if (s[i] != '&') continue;
                var j = i + 1;
                if (j >= end or !isAsciiAlpha(s[j])) continue;
                j += 1;
                while (j < end and isAsciiAlnum(s[j]) and j - i <= 32) : (j += 1) {}
                if (j < end and s[j] == ';') return i;
            }
            return end;
        }

        fn trimExtendedURLEnd(s: []const u8, start: usize, end_in: usize) usize {
            var end = truncateEntitySuffix(s, start, end_in);
            while (end > start and isURLTrailingPunctuation(s[end - 1])) : (end -= 1) {}

            var opens: usize = 0;
            var closes: usize = 0;
            for (s[start..end]) |byte| {
                if (byte == '(') opens += 1;
                if (byte == ')') closes += 1;
            }
            while (end > start and s[end - 1] == ')' and closes > opens) {
                end -= 1;
                closes -= 1;
            }
            return end;
        }

        fn writeExtendedURL(out: *Writer, text: []const u8, add_http: bool) void {
            out.writeSlice("<a href=\"");
            if (add_http) out.writeSlice("http://");
            writeURIAttrEscaped(out, text);
            out.writeSlice("\">");
            out.writeEscaped(text);
            out.writeSlice("</a>");
        }

        fn isEmailLocalByte(byte: u8) bool {
            return isAsciiAlnum(byte) or byte == '.' or byte == '-' or byte == '_' or byte == '+';
        }

        fn isEmailDomainByte(byte: u8) bool {
            return isAsciiAlnum(byte) or byte == '.' or byte == '-';
        }

        // ---- Inline parsing: delimiter-stack algorithm ----
        //
        // One left-to-right pass tokenizes a paragraph's inline content into a
        // doubly linked node list (code spans, autolinks, raw HTML, breaks,
        // bracket and delimiter runs, in spec precedence order). Links and
        // images resolve at each `]` per the spec's "look for link or image"
        // procedure, emphasis resolves with the spec appendix's "process
        // emphasis" delimiter stack (GFM strikethrough is one more delimiter
        // type in the same stack), and a final walk renders the list. Linear
        // in practice; the node pool is fixed, and a paragraph that overflows
        // it fails the whole render (empty output), matching the MAX_LINES
        // overflow behavior.

        const MAX_INLINE_NODES: usize = 65536;
        const MAX_LINK_DATA: usize = 8192;
        const NODE_NONE: u32 = 0xFFFF_FFFF;
        const NODE_HEAD: u32 = 0;
        const NODE_TAIL: u32 = 1;

        const InlineKind = enum(u8) {
            head,
            tail,
            text,
            escaped_char,
            code_span,
            raw_html,
            filtered_html,
            autolink,
            ext_url,
            ext_email,
            softbreak,
            hardbreak,
            delim,
            bracket,
            em_open,
            em_close,
            strong_open,
            strong_close,
            del_open,
            del_close,
            link_open,
            link_close,
            image_open,
            image_close,
        };

        const F_CAN_OPEN: u8 = 1;
        const F_CAN_CLOSE: u8 = 2;
        const F_ACTIVE: u8 = 4;
        const F_IMAGE: u8 = 8;
        const F_ADD_HTTP: u8 = 16;

        const InlineNode = struct {
            kind: InlineKind,
            marker: u8,
            flags: u8,
            orig_len: u32,
            cur_len: u32,
            start: u32,
            end: u32,
            prev: u32,
            next: u32,
            prev_delim: u32,
            next_delim: u32,
            data: u32,
        };

        const LinkData = struct {
            href: []const u8,
            title: []const u8,
        };

        var inline_nodes: [MAX_INLINE_NODES]InlineNode = undefined;
        var inline_node_count: u32 = 0;
        var link_data: [MAX_LINK_DATA]LinkData = undefined;
        var link_data_count: u32 = 0;
        var delim_top: u32 = NODE_NONE;
        var inline_overflow = false;

        // Backtick-scan memo, replicating cmark's subject.backticks /
        // scanned_for_backticks exactly (including its quirk that a
        // successful scan updates the per-length memo, so a later opener can
        // be declared closerless even though a closer exists further on —
        // frozen in the differential corpus as expected behavior).
        const MAX_BACKTICK_MEMO: usize = 80;
        var backtick_memo: [MAX_BACKTICK_MEMO + 1]usize = undefined;
        var backticks_scanned = false;

        fn scanBackticks(s: []const u8, after_open: usize, ticks: usize) ?usize {
            if (ticks > MAX_BACKTICK_MEMO) return null;
            if (backticks_scanned and backtick_memo[ticks] < after_open) return null;
            var i = after_open;
            while (i < s.len) {
                while (i < s.len and s[i] != '`') i += 1;
                if (i >= s.len) break;
                const run_start = i;
                var run: usize = 0;
                while (i < s.len and s[i] == '`') {
                    i += 1;
                    run += 1;
                }
                if (run <= MAX_BACKTICK_MEMO) backtick_memo[run] = run_start;
                if (run == ticks) return run_start;
            }
            backticks_scanned = true;
            return null;
        }

        fn nodeAlloc(kind: InlineKind) u32 {
            if (inline_node_count >= MAX_INLINE_NODES) {
                inline_overflow = true;
                return NODE_NONE;
            }
            const idx = inline_node_count;
            inline_node_count += 1;
            inline_nodes[idx] = .{
                .kind = kind,
                .marker = 0,
                .flags = 0,
                .orig_len = 0,
                .cur_len = 0,
                .start = 0,
                .end = 0,
                .prev = NODE_NONE,
                .next = NODE_NONE,
                .prev_delim = NODE_NONE,
                .next_delim = NODE_NONE,
                .data = 0,
            };
            return idx;
        }

        fn nodeInsertBefore(ref: u32, idx: u32) void {
            if (idx == NODE_NONE) return;
            const p = inline_nodes[ref].prev;
            inline_nodes[idx].prev = p;
            inline_nodes[idx].next = ref;
            inline_nodes[p].next = idx;
            inline_nodes[ref].prev = idx;
        }

        fn nodeInsertAfter(ref: u32, idx: u32) void {
            if (idx == NODE_NONE) return;
            const nx = inline_nodes[ref].next;
            inline_nodes[idx].prev = ref;
            inline_nodes[idx].next = nx;
            inline_nodes[ref].next = idx;
            inline_nodes[nx].prev = idx;
        }

        fn nodeAppendEnd(idx: u32) void {
            nodeInsertBefore(NODE_TAIL, idx);
        }

        fn nodeUnlink(idx: u32) void {
            const p = inline_nodes[idx].prev;
            const nx = inline_nodes[idx].next;
            inline_nodes[p].next = nx;
            inline_nodes[nx].prev = p;
        }

        fn delimPush(idx: u32) void {
            if (idx == NODE_NONE) return;
            inline_nodes[idx].prev_delim = delim_top;
            inline_nodes[idx].next_delim = NODE_NONE;
            if (delim_top != NODE_NONE) inline_nodes[delim_top].next_delim = idx;
            delim_top = idx;
        }

        fn delimRemove(idx: u32) void {
            const below = inline_nodes[idx].prev_delim;
            const above = inline_nodes[idx].next_delim;
            if (below != NODE_NONE) inline_nodes[below].next_delim = above;
            if (above != NODE_NONE) {
                inline_nodes[above].prev_delim = below;
            } else {
                delim_top = below;
            }
            inline_nodes[idx].prev_delim = NODE_NONE;
            inline_nodes[idx].next_delim = NODE_NONE;
        }

        fn emitText(start: usize, end: usize) void {
            if (end <= start) return;
            const idx = nodeAlloc(.text);
            if (idx == NODE_NONE) return;
            inline_nodes[idx].start = @intCast(start);
            inline_nodes[idx].end = @intCast(end);
            nodeAppendEnd(idx);
        }

        fn linkDataAlloc(href: []const u8, title: []const u8) u32 {
            if (link_data_count >= MAX_LINK_DATA) {
                inline_overflow = true;
                return 0;
            }
            const idx = link_data_count;
            link_data_count += 1;
            link_data[idx] = .{ .href = href, .title = title };
            return idx;
        }

        // Spec email-autolink grammar: atext local part, dot-separated
        // alphanumeric-and-hyphen labels of at most 63 chars that neither
        // start nor end with a hyphen.
        fn isValidEmailAutolink(inner: []const u8) bool {
            const at = std.mem.indexOfScalar(u8, inner, '@') orelse return false;
            if (at == 0) return false;
            for (inner[0..at]) |b| {
                if (!isAsciiAlnum(b) and std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", b) == null) return false;
            }
            const domain = inner[at + 1 ..];
            if (domain.len == 0) return false;
            var it = std.mem.splitScalar(u8, domain, '.');
            while (it.next()) |label| {
                if (label.len == 0 or label.len > 63) return false;
                if (!isAsciiAlnum(label[0]) or !isAsciiAlnum(label[label.len - 1])) return false;
                for (label) |b| {
                    if (!isAsciiAlnum(b) and b != '-') return false;
                }
            }
            return true;
        }

        fn isAutolinkInner(inner: []const u8) bool {
            if (inner.len == 0) return false;
            for (inner) |b| {
                if (b == '<' or b == '>' or b == ' ' or b == '\t' or b == '\n') return false;
            }
            if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
                if (isLikelyURIScheme(inner[0..colon])) return true;
            }
            return isValidEmailAutolink(inner);
        }

        const AngleScan = struct { end: usize, kind: InlineKind };

        fn scanAngle(s: []const u8, i: usize) ?AngleScan {
            if (i + 1 < s.len and s[i + 1] == '!') {
                // Comment, declaration, or CDATA — per the spec's exact rules;
                // anything else after "<!" is literal text. cmark matches the
                // CDATA keyword case-insensitively (a re2c scanner quirk), so
                // we do too.
                if (i + 2 < s.len and s[i + 2] == '[' and startsWithIgnoreCase(s[i + 3 ..], "CDATA[")) {
                    if (std.mem.indexOfPos(u8, s, i + 9, "]]>")) |end_idx| {
                        return .{ .end = end_idx + 3, .kind = .raw_html };
                    }
                    return null;
                }
                if (std.mem.startsWith(u8, s[i..], "<!--")) {
                    if (std.mem.startsWith(u8, s[i + 4 ..], ">")) return .{ .end = i + 5, .kind = .raw_html };
                    if (std.mem.startsWith(u8, s[i + 4 ..], "->")) return .{ .end = i + 6, .kind = .raw_html };
                    if (std.mem.indexOfPos(u8, s, i + 4, "-->")) |end_idx| {
                        return .{ .end = end_idx + 3, .kind = .raw_html };
                    }
                    return null;
                }
                if (i + 2 < s.len and isAsciiAlpha(s[i + 2])) {
                    if (std.mem.indexOfScalarPos(u8, s, i + 3, '>')) |gt| {
                        return .{ .end = gt + 1, .kind = .raw_html };
                    }
                }
                return null;
            }
            if (i + 1 < s.len and s[i + 1] == '?') {
                if (std.mem.indexOfPos(u8, s, i + 2, "?>")) |end_idx| {
                    return .{ .end = end_idx + 2, .kind = .raw_html };
                }
                return null;
            }
            var close_opt: ?usize = null;
            var p = i + 1;
            var saw_newline = false;
            var quote: u8 = 0;
            while (p < s.len) : (p += 1) {
                const ch = s[p];
                if (quote != 0) {
                    if (ch == quote) {
                        quote = 0;
                        continue;
                    }
                    if (ch == '\n') {
                        if (saw_newline) break;
                        saw_newline = true;
                    }
                    continue;
                }
                if (ch == '"' or ch == '\'') {
                    quote = ch;
                    continue;
                }
                if (ch == '>') {
                    close_opt = p;
                    break;
                }
                if (ch == '\n') {
                    if (saw_newline) break;
                    saw_newline = true;
                }
            }
            const close = close_opt orelse return null;
            const inner = s[i + 1 .. close];
            if (isAutolinkInner(inner)) return .{ .end = close + 1, .kind = .autolink };
            if (inner.len > 0) {
                const c0 = inner[0];
                if (c0 == '/' or isAsciiAlpha(c0)) {
                    if (isPlausibleInlineTag(inner)) return .{ .end = close + 1, .kind = .filtered_html };
                }
            }
            return null;
        }

        const ExtAutolink = struct { kind: InlineKind, end: usize, add_http: bool };

        fn scanExtendedAutolink(s: []const u8, start: usize) ?ExtAutolink {
            if (!isExtendedURLBoundary(s, start)) return null;
            var add_http = false;
            var prefix_len: usize = 0;
            if (std.mem.startsWith(u8, s[start..], "www.")) {
                add_http = true;
                prefix_len = 4;
            } else if (std.mem.startsWith(u8, s[start..], "http://")) {
                prefix_len = 7;
            } else if (std.mem.startsWith(u8, s[start..], "https://")) {
                prefix_len = 8;
            } else if (std.mem.startsWith(u8, s[start..], "ftp://")) {
                prefix_len = 6;
            }
            if (prefix_len != 0) {
                var end = start + prefix_len;
                while (end < s.len and !isInlineSpace(s[end]) and s[end] != '<') : (end += 1) {}
                end = trimExtendedURLEnd(s, start, end);
                if (end > start + prefix_len) {
                    return .{ .kind = .ext_url, .end = end, .add_http = add_http };
                }
            }
            if (!isEmailLocalByte(s[start])) return null;
            var at = start;
            while (at < s.len and isEmailLocalByte(s[at])) : (at += 1) {}
            if (at >= s.len or s[at] != '@' or at == start) return null;
            var end = at + 1;
            while (end < s.len and isEmailDomainByte(s[end])) : (end += 1) {}
            var domain_end = end;
            if (domain_end > at + 1 and s[domain_end - 1] == '.') domain_end -= 1;
            const domain = s[at + 1 .. domain_end];
            if (domain.len == 0 or std.mem.indexOfScalar(u8, domain, '.') == null) return null;
            if (domain[domain.len - 1] == '-' or (end < s.len and (s[end] == '-' or s[end] == '_'))) return null;
            return .{ .kind = .ext_email, .end = domain_end, .add_http = false };
        }

        fn writeExtendedEmail(out: *Writer, text: []const u8) void {
            out.writeSlice("<a href=\"mailto:");
            writeURIAttrEscaped(out, text);
            out.writeSlice("\">");
            out.writeEscaped(text);
            out.writeSlice("</a>");
        }

        const InlineLinkRaw = struct {
            href_start: usize,
            href_end: usize,
            title_start: usize,
            title_end: usize,
            next: usize,
        };

        fn parseInlineLinkRaw(s: []const u8, start: usize) ?InlineLinkRaw {
            var i = start;
            while (i < s.len and (isWhitespace(s[i]) or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
            if (i >= s.len) return null;
            var href_start: usize = i;
            var href_end: usize = i;
            if (s[i] == '<') {
                href_start = i + 1;
                var close: usize = href_start;
                while (close < s.len and s[close] != '>') : (close += 1) {
                    if (s[close] == '\n' or s[close] == '<' or s[close] == '\\') return null;
                }
                if (close >= s.len) return null;
                href_end = close;
                i = close + 1;
            } else {
                var paren_depth: usize = 0;
                while (i < s.len) {
                    const ch = s[i];
                    if (ch == '\n' or ch == '\r') break;
                    if (ch == '\\' and i + 1 < s.len and isPunctuation(s[i + 1])) {
                        i += 2;
                        continue;
                    }
                    if (isWhitespace(ch)) break;
                    if (ch == '(') {
                        paren_depth += 1;
                        i += 1;
                        continue;
                    }
                    if (ch == ')') {
                        if (paren_depth == 0) break;
                        paren_depth -= 1;
                        i += 1;
                        continue;
                    }
                    i += 1;
                }
                href_end = i;
            }
            var had_sep = false;
            while (i < s.len and (isWhitespace(s[i]) or s[i] == '\n' or s[i] == '\r')) : (i += 1) had_sep = true;
            var title_start: usize = 0;
            var title_end: usize = 0;
            if (i < s.len and s[i] != ')') {
                if (!had_sep) return null;
                const open = s[i];
                var close_ch: u8 = 0;
                if (open == '"' or open == '\'') {
                    close_ch = open;
                } else if (open == '(') {
                    close_ch = ')';
                } else {
                    return null;
                }
                i += 1;
                title_start = i;
                while (i < s.len and s[i] != close_ch) {
                    if (s[i] == '\\' and i + 1 < s.len and isPunctuation(s[i + 1])) {
                        i += 2;
                        continue;
                    }
                    if (s[i] == '\n') return null;
                    i += 1;
                }
                if (i >= s.len) return null;
                title_end = i;
                i += 1;
                while (i < s.len and (isWhitespace(s[i]) or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
            }
            if (i >= s.len or s[i] != ')') return null;
            return .{
                .href_start = href_start,
                .href_end = href_end,
                .title_start = title_start,
                .title_end = title_end,
                .next = i + 1,
            };
        }

        fn markerIndex(marker: u8) usize {
            return switch (marker) {
                '*' => 0,
                '_' => 1,
                else => 2,
            };
        }

        fn processEmphasis(bottom: u32) void {
            var openers_bottom: [3][3][2]u32 = undefined;
            {
                var a: usize = 0;
                while (a < 3) : (a += 1) {
                    var m: usize = 0;
                    while (m < 3) : (m += 1) {
                        openers_bottom[a][m][0] = bottom;
                        openers_bottom[a][m][1] = bottom;
                    }
                }
            }
            var closer: u32 = undefined;
            if (bottom == NODE_NONE) {
                closer = delim_top;
                if (closer == NODE_NONE) return;
                while (inline_nodes[closer].prev_delim != NODE_NONE) closer = inline_nodes[closer].prev_delim;
            } else {
                closer = inline_nodes[bottom].next_delim;
            }
            while (closer != NODE_NONE) {
                const cn = inline_nodes[closer];
                if (cn.kind != .delim or (cn.flags & F_CAN_CLOSE) == 0) {
                    closer = cn.next_delim;
                    continue;
                }
                const mi = markerIndex(cn.marker);
                const can_open_bit: usize = if ((cn.flags & F_CAN_OPEN) != 0) 1 else 0;
                const ob = openers_bottom[mi][cn.orig_len % 3][can_open_bit];
                var opener = cn.prev_delim;
                var found = NODE_NONE;
                while (opener != NODE_NONE and opener != bottom and opener != ob) {
                    const on = inline_nodes[opener];
                    if (on.kind == .delim and on.marker == cn.marker and (on.flags & F_CAN_OPEN) != 0) {
                        if (cn.marker == '~') {
                            if (on.orig_len == cn.orig_len) {
                                found = opener;
                                break;
                            }
                        } else {
                            const either_both = (on.flags & F_CAN_CLOSE) != 0 or (cn.flags & F_CAN_OPEN) != 0;
                            const sum_mult3 = (on.orig_len + cn.orig_len) % 3 == 0;
                            const both_mult3 = on.orig_len % 3 == 0 and cn.orig_len % 3 == 0;
                            if (!(either_both and sum_mult3 and !both_mult3)) {
                                found = opener;
                                break;
                            }
                        }
                    }
                    opener = on.prev_delim;
                }
                if (found == NODE_NONE) {
                    openers_bottom[mi][cn.orig_len % 3][can_open_bit] = cn.prev_delim;
                    const nxt = cn.next_delim;
                    if ((cn.flags & F_CAN_OPEN) == 0) delimRemove(closer);
                    closer = nxt;
                    continue;
                }
                if (cn.marker == '~') {
                    const oidx = nodeAlloc(.del_open);
                    const cidx = nodeAlloc(.del_close);
                    if (oidx == NODE_NONE or cidx == NODE_NONE) return;
                    nodeInsertAfter(found, oidx);
                    nodeInsertBefore(closer, cidx);
                    var d = inline_nodes[closer].prev_delim;
                    while (d != found) {
                        const pd = inline_nodes[d].prev_delim;
                        delimRemove(d);
                        d = pd;
                    }
                    const nxt = inline_nodes[closer].next_delim;
                    delimRemove(found);
                    nodeUnlink(found);
                    delimRemove(closer);
                    nodeUnlink(closer);
                    closer = nxt;
                    continue;
                }
                const use: u32 = if (inline_nodes[found].cur_len >= 2 and inline_nodes[closer].cur_len >= 2) 2 else 1;
                const oidx = nodeAlloc(if (use == 2) .strong_open else .em_open);
                const cidx = nodeAlloc(if (use == 2) .strong_close else .em_close);
                if (oidx == NODE_NONE or cidx == NODE_NONE) return;
                nodeInsertAfter(found, oidx);
                nodeInsertBefore(closer, cidx);
                var d = inline_nodes[closer].prev_delim;
                while (d != found) {
                    const pd = inline_nodes[d].prev_delim;
                    delimRemove(d);
                    d = pd;
                }
                inline_nodes[found].cur_len -= use;
                inline_nodes[found].end -= use;
                inline_nodes[closer].cur_len -= use;
                inline_nodes[closer].start += use;
                if (inline_nodes[found].cur_len == 0) {
                    delimRemove(found);
                    nodeUnlink(found);
                }
                if (inline_nodes[closer].cur_len == 0) {
                    const nxt = inline_nodes[closer].next_delim;
                    delimRemove(closer);
                    nodeUnlink(closer);
                    closer = nxt;
                }
            }
            while (delim_top != NODE_NONE and delim_top != bottom) {
                delimRemove(delim_top);
            }
        }

        fn lookForLinkOrImage(s: []const u8, close_pos: usize) usize {
            var opener = delim_top;
            while (opener != NODE_NONE and inline_nodes[opener].kind != .bracket) {
                opener = inline_nodes[opener].prev_delim;
            }
            if (opener == NODE_NONE) {
                emitText(close_pos, close_pos + 1);
                return close_pos + 1;
            }
            const is_image = (inline_nodes[opener].flags & F_IMAGE) != 0;
            if ((inline_nodes[opener].flags & F_ACTIVE) == 0) {
                delimRemove(opener);
                inline_nodes[opener].kind = .text;
                emitText(close_pos, close_pos + 1);
                return close_pos + 1;
            }
            const label = s[@as(usize, inline_nodes[opener].end)..close_pos];

            var href: []const u8 = "";
            var title: []const u8 = "";
            var matched = false;
            var consumed_end: usize = close_pos + 1;

            if (close_pos + 1 < s.len and s[close_pos + 1] == '(') {
                if (parseInlineLinkRaw(s, close_pos + 2)) |raw| {
                    href = s[raw.href_start..raw.href_end];
                    title = s[raw.title_start..raw.title_end];
                    matched = true;
                    consumed_end = raw.next;
                }
            }
            if (!matched) {
                var ref_label = label;
                var ref_next = close_pos + 1;
                if (close_pos + 1 < s.len and s[close_pos + 1] == '[') {
                    if (findUnescapedRightBracket(s, close_pos + 2)) |ref_close| {
                        if (ref_close != close_pos + 2) ref_label = s[close_pos + 2 .. ref_close];
                        ref_next = ref_close + 1;
                    }
                }
                if (lookupRefDef(ref_label)) |def| {
                    href = def.href;
                    title = def.title;
                    matched = true;
                    consumed_end = ref_next;
                }
            }
            if (!matched) {
                delimRemove(opener);
                inline_nodes[opener].kind = .text;
                emitText(close_pos, close_pos + 1);
                return close_pos + 1;
            }
            const data = linkDataAlloc(href, title);
            inline_nodes[opener].kind = if (is_image) .image_open else .link_open;
            inline_nodes[opener].data = data;
            processEmphasis(opener);
            if (!is_image) {
                var b = inline_nodes[opener].prev_delim;
                while (b != NODE_NONE) : (b = inline_nodes[b].prev_delim) {
                    if (inline_nodes[b].kind == .bracket and (inline_nodes[b].flags & F_IMAGE) == 0) {
                        inline_nodes[b].flags &= ~F_ACTIVE;
                    }
                }
            }
            delimRemove(opener);
            const close_idx = nodeAlloc(if (is_image) .image_close else .link_close);
            if (close_idx != NODE_NONE) {
                inline_nodes[close_idx].data = data;
                nodeAppendEnd(close_idx);
            }
            return consumed_end;
        }

        fn inlineParse(s: []const u8) bool {
            inline_node_count = 0;
            link_data_count = 0;
            delim_top = NODE_NONE;
            inline_overflow = false;
            backticks_scanned = false;
            _ = nodeAlloc(.head);
            _ = nodeAlloc(.tail);
            inline_nodes[NODE_HEAD].next = NODE_TAIL;
            inline_nodes[NODE_TAIL].prev = NODE_HEAD;

            var text_start: usize = 0;
            var i: usize = 0;
            while (i < s.len and !inline_overflow) {
                const b = s[i];
                switch (b) {
                    '\\' => {
                        if (i + 1 < s.len and s[i + 1] == '\n') {
                            emitText(text_start, i);
                            const idx = nodeAlloc(.hardbreak);
                            if (idx != NODE_NONE) nodeAppendEnd(idx);
                            i += 2;
                            text_start = i;
                        } else if (i + 1 < s.len and isPunctuation(s[i + 1])) {
                            emitText(text_start, i);
                            const idx = nodeAlloc(.escaped_char);
                            if (idx != NODE_NONE) {
                                inline_nodes[idx].start = @intCast(i + 1);
                                inline_nodes[idx].end = @intCast(i + 2);
                                nodeAppendEnd(idx);
                            }
                            i += 2;
                            text_start = i;
                        } else {
                            i += 1;
                        }
                    },
                    '\n' => {
                        var space_start = i;
                        while (space_start > text_start and s[space_start - 1] == ' ') space_start -= 1;
                        const trailing_spaces = i - space_start;
                        var ws_start = space_start;
                        while (ws_start > text_start and (s[ws_start - 1] == ' ' or s[ws_start - 1] == '\t')) ws_start -= 1;
                        emitText(text_start, ws_start);
                        const idx = nodeAlloc(if (trailing_spaces >= 2) .hardbreak else .softbreak);
                        if (idx != NODE_NONE) nodeAppendEnd(idx);
                        i += 1;
                        text_start = i;
                    },
                    '`' => {
                        var ticks: usize = 1;
                        while (i + ticks < s.len and s[i + ticks] == '`') ticks += 1;
                        if (scanBackticks(s, i + ticks, ticks)) |end_idx| {
                            emitText(text_start, i);
                            const idx = nodeAlloc(.code_span);
                            if (idx != NODE_NONE) {
                                inline_nodes[idx].start = @intCast(i + ticks);
                                inline_nodes[idx].end = @intCast(end_idx);
                                nodeAppendEnd(idx);
                            }
                            i = end_idx + ticks;
                            text_start = i;
                        } else {
                            i += ticks;
                        }
                    },
                    '<' => {
                        if (scanAngle(s, i)) |res| {
                            emitText(text_start, i);
                            const idx = nodeAlloc(res.kind);
                            if (idx != NODE_NONE) {
                                inline_nodes[idx].start = @intCast(i);
                                inline_nodes[idx].end = @intCast(res.end);
                                nodeAppendEnd(idx);
                            }
                            i = res.end;
                            text_start = i;
                        } else {
                            i += 1;
                        }
                    },
                    '*', '_' => {
                        if (enable_gfm and b == '_') {
                            if (scanExtendedAutolink(s, i)) |ext| {
                                emitText(text_start, i);
                                const idx = nodeAlloc(ext.kind);
                                if (idx != NODE_NONE) {
                                    inline_nodes[idx].start = @intCast(i);
                                    inline_nodes[idx].end = @intCast(ext.end);
                                    if (ext.add_http) inline_nodes[idx].flags |= F_ADD_HTTP;
                                    nodeAppendEnd(idx);
                                }
                                i = ext.end;
                                text_start = i;
                                continue;
                            }
                        }
                        var run: usize = 1;
                        while (i + run < s.len and s[i + run] == b) run += 1;
                        const can_open = canOpenDelimiter(s, i, run, b);
                        const can_close = canCloseDelimiter(s, i, run, b);
                        if (can_open or can_close) {
                            emitText(text_start, i);
                            const idx = nodeAlloc(.delim);
                            if (idx != NODE_NONE) {
                                inline_nodes[idx].marker = b;
                                if (can_open) inline_nodes[idx].flags |= F_CAN_OPEN;
                                if (can_close) inline_nodes[idx].flags |= F_CAN_CLOSE;
                                inline_nodes[idx].orig_len = @intCast(run);
                                inline_nodes[idx].cur_len = @intCast(run);
                                inline_nodes[idx].start = @intCast(i);
                                inline_nodes[idx].end = @intCast(i + run);
                                nodeAppendEnd(idx);
                                delimPush(idx);
                            }
                            i += run;
                            text_start = i;
                        } else {
                            i += run;
                        }
                    },
                    '~' => {
                        var run: usize = 1;
                        while (i + run < s.len and s[i + run] == '~') run += 1;
                        var made = false;
                        if (enable_gfm and run <= 2) {
                            const can_open = canOpenDelimiter(s, i, run, '~');
                            const can_close = canCloseDelimiter(s, i, run, '~');
                            if (can_open or can_close) {
                                emitText(text_start, i);
                                const idx = nodeAlloc(.delim);
                                if (idx != NODE_NONE) {
                                    inline_nodes[idx].marker = '~';
                                    if (can_open) inline_nodes[idx].flags |= F_CAN_OPEN;
                                    if (can_close) inline_nodes[idx].flags |= F_CAN_CLOSE;
                                    inline_nodes[idx].orig_len = @intCast(run);
                                    inline_nodes[idx].cur_len = @intCast(run);
                                    inline_nodes[idx].start = @intCast(i);
                                    inline_nodes[idx].end = @intCast(i + run);
                                    nodeAppendEnd(idx);
                                    delimPush(idx);
                                }
                                made = true;
                            }
                        }
                        i += run;
                        if (made) text_start = i;
                    },
                    '[' => {
                        emitText(text_start, i);
                        const idx = nodeAlloc(.bracket);
                        if (idx != NODE_NONE) {
                            inline_nodes[idx].marker = '[';
                            inline_nodes[idx].flags = F_ACTIVE;
                            inline_nodes[idx].start = @intCast(i);
                            inline_nodes[idx].end = @intCast(i + 1);
                            nodeAppendEnd(idx);
                            delimPush(idx);
                        }
                        i += 1;
                        text_start = i;
                    },
                    '!' => {
                        if (i + 1 < s.len and s[i + 1] == '[') {
                            emitText(text_start, i);
                            const idx = nodeAlloc(.bracket);
                            if (idx != NODE_NONE) {
                                inline_nodes[idx].marker = '[';
                                inline_nodes[idx].flags = F_ACTIVE | F_IMAGE;
                                inline_nodes[idx].start = @intCast(i);
                                inline_nodes[idx].end = @intCast(i + 2);
                                nodeAppendEnd(idx);
                                delimPush(idx);
                            }
                            i += 2;
                            text_start = i;
                        } else {
                            i += 1;
                        }
                    },
                    ']' => {
                        emitText(text_start, i);
                        i = lookForLinkOrImage(s, i);
                        text_start = i;
                    },
                    else => {
                        if (enable_gfm and (b == 'w' or b == 'h' or b == 'f' or isEmailLocalByte(b))) {
                            if (scanExtendedAutolink(s, i)) |ext| {
                                emitText(text_start, i);
                                const idx = nodeAlloc(ext.kind);
                                if (idx != NODE_NONE) {
                                    inline_nodes[idx].start = @intCast(i);
                                    inline_nodes[idx].end = @intCast(ext.end);
                                    if (ext.add_http) inline_nodes[idx].flags |= F_ADD_HTTP;
                                    nodeAppendEnd(idx);
                                }
                                i = ext.end;
                                text_start = i;
                                continue;
                            }
                        }
                        i += 1;
                    },
                }
            }
            if (inline_overflow) return false;
            emitText(text_start, s.len);
            processEmphasis(NODE_NONE);
            return !inline_overflow;
        }

        fn writeTextRange(out: *Writer, s: []const u8) void {
            var i: usize = 0;
            while (i < s.len and !out.overflow) {
                const b = s[i];
                if (b == '&') {
                    var semi = i + 1;
                    while (semi < s.len and semi - i <= 32 and s[semi] != ';' and s[semi] != '\n') : (semi += 1) {}
                    if (semi < s.len and s[semi] == ';') {
                        const ent = s[i .. semi + 1];
                        var dec_buf: [8]u8 = undefined;
                        if (isEntity(ent)) {
                            if (decodeEntityToBuf(ent, &dec_buf)) |decoded| {
                                for (decoded) |db| out.writeEscapedByte(db);
                                i = semi + 1;
                                continue;
                            }
                        }
                    }
                    out.writeSlice("&amp;");
                    i += 1;
                    continue;
                }
                out.writeEscapedByte(b);
                i += 1;
            }
        }

        fn renderInlineNodes(out: *Writer, s: []const u8) void {
            var plain_depth: usize = 0;
            var idx = inline_nodes[NODE_HEAD].next;
            while (idx != NODE_TAIL and !out.overflow) : (idx = inline_nodes[idx].next) {
                const n = inline_nodes[idx];
                switch (n.kind) {
                    .head, .tail => {},
                    .text, .escaped_char => writeTextRange(out, s[n.start..n.end]),
                    .code_span => {
                        if (plain_depth == 0) {
                            out.writeSlice("<code>");
                            writeCodeSpan(out, s[n.start..n.end]);
                            out.writeSlice("</code>");
                        } else {
                            for (s[n.start..n.end]) |cb| out.writeEscapedByte(cb);
                        }
                    },
                    .raw_html => if (plain_depth == 0) out.writeSlice(s[n.start..n.end]),
                    .filtered_html => if (plain_depth == 0) writeTagFiltered(out, s[n.start..n.end]),
                    .autolink => {
                        const inner = s[n.start + 1 .. n.end - 1];
                        if (plain_depth == 0) {
                            _ = writeAutolink(out, inner);
                        } else {
                            out.writeEscaped(inner);
                        }
                    },
                    .ext_url => {
                        if (plain_depth == 0) {
                            writeExtendedURL(out, s[n.start..n.end], (n.flags & F_ADD_HTTP) != 0);
                        } else {
                            out.writeEscaped(s[n.start..n.end]);
                        }
                    },
                    .ext_email => {
                        if (plain_depth == 0) {
                            writeExtendedEmail(out, s[n.start..n.end]);
                        } else {
                            out.writeEscaped(s[n.start..n.end]);
                        }
                    },
                    .softbreak => out.writeByte('\n'),
                    .hardbreak => if (plain_depth == 0) out.writeSlice("<br />\n") else out.writeByte('\n'),
                    .delim, .bracket => {
                        for (s[n.start..n.end]) |db| out.writeEscapedByte(db);
                    },
                    .em_open => if (plain_depth == 0) out.writeSlice("<em>"),
                    .em_close => if (plain_depth == 0) out.writeSlice("</em>"),
                    .strong_open => if (plain_depth == 0) out.writeSlice("<strong>"),
                    .strong_close => if (plain_depth == 0) out.writeSlice("</strong>"),
                    .del_open => if (plain_depth == 0) out.writeSlice("<del>"),
                    .del_close => if (plain_depth == 0) out.writeSlice("</del>"),
                    .link_open => {
                        if (plain_depth == 0) {
                            const d = link_data[n.data];
                            out.writeSlice("<a href=\"");
                            writeURIAttrEscaped(out, d.href);
                            out.writeByte('"');
                            if (d.title.len > 0) {
                                out.writeSlice(" title=\"");
                                writeLinkAttrEscaped(out, d.title);
                                out.writeByte('"');
                            }
                            out.writeByte('>');
                        }
                    },
                    .link_close => if (plain_depth == 0) out.writeSlice("</a>"),
                    .image_open => {
                        if (plain_depth == 0) {
                            const d = link_data[n.data];
                            out.writeSlice("<img src=\"");
                            writeURIAttrEscaped(out, d.href);
                            out.writeSlice("\" alt=\"");
                        }
                        plain_depth += 1;
                    },
                    .image_close => {
                        plain_depth -= 1;
                        if (plain_depth == 0) {
                            const d = link_data[n.data];
                            out.writeByte('"');
                            if (d.title.len > 0) {
                                out.writeSlice(" title=\"");
                                writeLinkAttrEscaped(out, d.title);
                                out.writeByte('"');
                            }
                            out.writeSlice(" />");
                        }
                    },
                }
            }
        }

        fn writeInline(out: *Writer, s: []const u8) void {
            if (!inlineParse(s)) {
                out.overflow = true;
                return;
            }
            renderInlineNodes(out, s);
        }

        fn renderParagraph(input: []const u8, out: *Writer, i_ptr: *u32) void {
            const start = i_ptr.*;
            var i = start;
            while (i < lines_count) : (i += 1) {
                const line = lineSlice(input, i);
                if (isBlankLine(line)) break;
                if (i != start) {
                    if (parseATXHeading(line) != null) break;
                    if (parseThematicBreak(line)) break;
                    if (parseFenceOpen(line) != null) break;
                    if (canInterruptParagraphWithList(line)) break;
                    const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
                    const html_block = detectHtmlBlockStart(line, prev_blank);
                    if (html_block != .none and html_block != .type7) break;
                    const ind = leadingIndent(line);
                    if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') break;
                }
            }

            var para = Writer.init(tmp2_buf[0..]);
            var j = start;
            while (j < i) : (j += 1) {
                if (j != start) para.writeByte('\n');
                const line = lineSlice(input, j);
                var seg: []const u8 = undefined;
                if (j != start) {
                    seg = stripAllLeadingSpacesTabs(line);
                } else if (leadingIndent(line).cols > 3) {
                    seg = stripAllLeadingSpacesTabs(line);
                } else {
                    seg = stripBlockIndentUpTo3(line);
                }
                if (j + 1 == i) seg = trimRightSpacesTabs(seg);
                para.writeSlice(seg);
            }

            out.writeSlice("<p>");
            writeInline(out, para.buf[0..para.idx]);
            out.writeSlice("</p>\n");

            i_ptr.* = i;
        }

        fn renderFencedCode(input: []const u8, out: *Writer, i_ptr: *u32, fence: Fence) void {
            var i = i_ptr.* + 1;

            out.writeSlice("<pre><code");
            if (fence.info.len > 0) {
                var info_end: usize = 0;
                while (info_end < fence.info.len and !isWhitespace(fence.info[info_end])) : (info_end += 1) {}
                const lang = fence.info[0..info_end];
                if (lang.len > 0) {
                    out.writeSlice(" class=\"language-");
                    writeLinkAttrEscaped(out, lang);
                    out.writeByte('"');
                }
            }
            out.writeSlice(">");

            while (i < lines_count) : (i += 1) {
                const line = lineSlice(input, i);
                if (isFenceClose(line, fence)) {
                    i += 1;
                    break;
                }
                var tmp = Writer.init(tmp2_buf[0..]);
                appendStrippedIndent(&tmp, line, fence.indent);
                out.writeEscaped(tmp.buf[0..tmp.idx]);
                out.writeByte('\n');
            }

            out.writeSlice("</code></pre>\n");
            i_ptr.* = i;
        }

        fn renderIndentedCode(input: []const u8, out: *Writer, i_ptr: *u32) void {
            var i = i_ptr.*;
            var code = Writer.init(tmp2_buf[0..]);
            var seen_content = false;

            out.writeSlice("<pre><code>");

            while (i < lines_count) : (i += 1) {
                const line = lineSlice(input, i);
                if (isBlankLine(line)) {
                    const bi = leadingIndent(line);
                    var stripped: []const u8 = "";
                    if (bi.cols >= 4) {
                        stripped = stripIndentCols(line, 4);
                    }
                    if (!seen_content and trimAscii(stripped).len == 0) continue;
                    code.writeEscaped(stripped);
                    code.writeByte('\n');
                    continue;
                }
                const ind = leadingIndent(line);
                if (ind.cols < 4) break;
                const stripped = stripIndentCols(line, 4);
                if (trimAscii(stripped).len > 0) seen_content = true;
                code.writeEscaped(stripped);
                code.writeByte('\n');
            }

            // Trim trailing blank lines from indented code blocks.
            while (code.idx > 0) {
                if (code.buf[code.idx - 1] != '\n') break;
                var start = code.idx - 1;
                while (start > 0 and code.buf[start - 1] != '\n') : (start -= 1) {}
                const line_content = code.buf[start .. code.idx - 1];
                if (trimAscii(line_content).len != 0) break;
                code.idx = start;
            }

            out.writeSlice(code.buf[0..code.idx]);
            out.writeSlice("</code></pre>\n");
            i_ptr.* = i;
        }

        fn appendTmp(dst: *Writer, s: []const u8) void {
            dst.writeSlice(s);
        }

        fn appendListItemFirstLine(tmp: *Writer, line: []const u8, mark: ListMarker) void {
            var ps: usize = 0;
            while (ps < mark.prefix_spaces) : (ps += 1) tmp.writeByte(' ');
            const first_rem = line[mark.content_start..];
            const first_ind = leadingIndent(first_rem);
            var fs: usize = 0;
            while (fs < first_ind.cols) : (fs += 1) tmp.writeByte(' ');
            appendTmp(tmp, first_rem[first_ind.idx..]);
        }

        fn listItemContinuationBase(first_line: []const u8, mark: ListMarker) usize {
            const marker_min = mark.marker_end + 1;
            if (mark.content_start >= first_line.len) return marker_min;
            if (trimAscii(first_line[mark.content_start..]).len == 0) return marker_min;
            if (mark.content_start > mark.marker_end) return mark.content_start;
            return marker_min;
        }

        fn canLazyContinueListParagraph(line: []const u8) bool {
            if (parseATXHeading(line) != null) return false;
            if (parseThematicBreak(line)) return false;
            if (parseFenceOpen(line) != null) return false;
            // Any list-marker line — even an empty item, which could not
            // interrupt a paragraph in the same container — starts a block
            // and therefore cannot be a lazy continuation line. A marker
            // indented 4+ columns starts nothing and stays lazy.
            if (leadingIndent(line).cols <= 3 and parseListMarker(line) != null) return false;
            const html_block = detectHtmlBlockStart(line, false);
            if (html_block != .none and html_block != .type7) return false;
            const ind = leadingIndent(line);
            if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') return false;
            return true;
        }

        // Whether this line, as item/blockquote content, leaves a paragraph
        // open that a lazy continuation line could attach to. Strips nested
        // list markers and blockquote prefixes before judging; anything that
        // opens a leaf block other than a paragraph (code, fence, heading,
        // thematic break, HTML) means no lazy continuation.
        fn contentOpensParagraph(s0: []const u8) bool {
            var depth: u8 = 0;
            var cur = trimRightCR(s0);
            while (true) {
                if (isBlankLine(cur)) return false;
                const ind = leadingIndent(cur);
                if (ind.cols >= 4) return false;
                if (parseATXHeading(cur) != null) return false;
                if (parseThematicBreak(cur)) return false;
                if (parseFenceOpen(cur) != null) return false;
                if (ind.idx < cur.len and cur[ind.idx] == '>') {
                    var stripped = Writer.init(if (depth % 2 == 0) tmp3_buf[0..] else tmp4_buf[0..]);
                    if (!appendBlockquoteStripped(&stripped, cur)) return false;
                    cur = trimRightCR(stripped.buf[0..stripped.idx]);
                    depth += 1;
                    if (depth > 64) return false;
                    continue;
                }
                if (parseListMarker(cur)) |m| {
                    if (m.content_start >= cur.len) return false;
                    cur = cur[m.content_start..];
                    depth += 1;
                    if (depth > 64) return false;
                    continue;
                }
                if (detectHtmlBlockStart(cur, false) != .none) return false;
                return true;
            }
        }

        fn sameLevelListIndentLimit(base_indent: usize) usize {
            return if (base_indent == 0) 3 else base_indent;
        }

        fn nextTmpLine(text: []const u8, cursor: *usize) ?[]const u8 {
            if (cursor.* >= text.len) return null;
            const start = cursor.*;
            var end = start;
            while (end < text.len and text[end] != '\n') : (end += 1) {}
            if (end < text.len and text[end] == '\n') end += 1;
            cursor.* = end;
            return trimRightCR(text[start..if (end > start and text[end - 1] == '\n') end - 1 else end]);
        }

        fn renderTmpList(out: *Writer, text: []const u8, cursor: *usize, first_line: []const u8) void {
            const first_mark = parseListMarker(first_line) orelse return;
            const ordered = first_mark.kind == .ordered;

            if (ordered) {
                if (first_mark.ordered_start != 1) {
                    out.writeSlice("<ol start=\"");
                    var num_buf: [32]u8 = undefined;
                    const n = std.fmt.bufPrint(&num_buf, "{d}", .{first_mark.ordered_start}) catch "1";
                    out.writeSlice(n);
                    out.writeSlice("\">\n");
                } else {
                    out.writeSlice("<ol>\n");
                }
            } else {
                out.writeSlice("<ul>\n");
            }

            var line = first_line;
            var done = false;
            var list_is_loose = false;
            // Markers indented less than the previous item's content base are
            // siblings of this list (cmark), so the acceptance bound has to
            // follow the previous item rather than the first marker's column.
            var sibling_limit = listItemContinuationBase(first_line, first_mark) - 1;
            while (!done) {
                if (parseThematicBreak(line)) break;
                const mark = parseListMarker(line) orelse break;
                if (mark.kind != first_mark.kind or mark.marker != first_mark.marker) break;
                if (mark.indent_cols > sibling_limit) break;
                const item_content_base = listItemContinuationBase(line, mark);
                sibling_limit = item_content_base - 1;

                var tmp = Writer.init(tmp_buf[0..]);
                appendListItemFirstLine(&tmp, line, mark);
                var item_has_blank = false;
                var saw_nonblank = trimAscii(tmp.buf[0..tmp.idx]).len != 0;
                var separator_blank = false;
                var saw_nested_list = false;
                const first_line_trimmed = trimRightCR(line);
                var lazy_ok = mark.content_start < first_line_trimmed.len and
                    contentOpensParagraph(first_line_trimmed[mark.content_start..]);
                var fence_trailing_blank = false;

                while (true) {
                    const save = cursor.*;
                    const maybe_ln = nextTmpLine(text, cursor);
                    if (maybe_ln == null) break;
                    const ln = maybe_ln.?;
                    if (isBlankLine(ln)) {
                        if (saw_nonblank and tmpInsideFence(tmp.buf[0..tmp.idx])) {
                            // Inside an open fence the blank is fence content
                            // and cannot end the item.
                            appendTmp(&tmp, "\n");
                            fence_trailing_blank = true;
                            continue;
                        }
                        if (!saw_nonblank) break;
                        var look = cursor.*;
                        var next_nonblank: ?[]const u8 = null;
                        while (nextTmpLine(text, &look)) |peek| {
                            if (isBlankLine(peek)) continue;
                            next_nonblank = peek;
                            break;
                        }
                        if (next_nonblank == null) break;
                        const next_ln = next_nonblank.?;
                        if (parseListMarker(next_ln)) |nm| {
                            if (leadingIndent(next_ln).cols <= first_mark.indent_cols) {
                                if (nm.kind == first_mark.kind and nm.marker == first_mark.marker) {
                                    separator_blank = true;
                                }
                                break;
                            }
                        } else if (leadingIndent(next_ln).cols < item_content_base) {
                            break;
                        }
                        appendTmp(&tmp, "\n");
                        if (!tmpInsideFence(tmp.buf[0..tmp.idx]) and (!saw_nested_list or leadingIndent(next_ln).cols <= item_content_base + 1) and
                            !tmpTailIsDefsOnly(text, cursor.*, item_content_base))
                        {
                            item_has_blank = true;
                        }
                        lazy_ok = false;
                        continue;
                    }

                    if (parseListMarker(ln)) |nm| {
                        const ind = leadingIndent(ln);
                        if (ind.cols < item_content_base) {
                            _ = nm;
                            cursor.* = save;
                            break;
                        }
                    }

                    const ind = leadingIndent(ln);
                    if (ind.cols < item_content_base and parseListMarker(ln) == null) {
                        if (saw_nonblank and lazy_ok and !tmpInsideFence(tmp.buf[0..tmp.idx]) and canLazyContinueListParagraph(ln)) {
                            appendTmp(&tmp, "\n");
                            // A setext underline cannot be a lazy continuation
                            // line; indent it so it stays paragraph text after
                            // reassembly (leading whitespace is stripped during
                            // paragraph assembly).
                            if (parseSetextUnderline(ln) != null) appendTmp(&tmp, "    ");
                            appendTmp(&tmp, trimRightCR(ln));
                            saw_nonblank = true;
                            continue;
                        }
                        cursor.* = save;
                        break;
                    }
                    if (parseListMarker(ln) != null and ind.cols >= item_content_base and
                        !(lazy_ok and parseSetextUnderline(stripIndentCols(ln, item_content_base)) != null))
                    {
                        saw_nested_list = true;
                    }

                    appendTmp(&tmp, "\n");
                    appendListContinuation(&tmp, ln, item_content_base);
                    saw_nonblank = true;
                    fence_trailing_blank = false;
                    lazy_ok = contentOpensParagraph(stripIndentCols(ln, item_content_base));
                }

                if (fence_trailing_blank) appendTmp(&tmp, "\n");
                const item_is_tight = !(list_is_loose or item_has_blank or separator_blank);
                const item_empty = trimAscii(tmp.buf[0..tmp.idx]).len == 0;
                if (item_empty) {
                    out.writeSlice("<li></li>\n");
                    list_is_loose = list_is_loose or item_has_blank or separator_blank;
                } else {
                    if (!item_is_tight or firstListItemBlockIsCode(tmp.buf[0..tmp.idx])) {
                        out.writeSlice("<li>\n");
                    } else {
                        out.writeSlice("<li>");
                    }
                    renderListItemContent(out, tmp.buf[0..tmp.idx], item_is_tight);
                    out.writeSlice("</li>\n");
                    list_is_loose = list_is_loose or item_has_blank or separator_blank;
                }

                var have_next = false;
                while (true) {
                    const save = cursor.*;
                    const maybe_next = nextTmpLine(text, cursor);
                    if (maybe_next == null) {
                        done = true;
                        break;
                    }
                    const nl = maybe_next.?;
                    if (isBlankLine(nl)) continue;

                    if (parseListMarker(nl)) |nm| {
                        const ind = leadingIndent(nl);
                        if (nm.kind == first_mark.kind and nm.marker == first_mark.marker and ind.cols <= sibling_limit) {
                            line = nl;
                            have_next = true;
                            break;
                        }
                    }

                    cursor.* = save;
                    done = true;
                    break;
                }
                if (!have_next) break;
            }

            if (ordered) {
                out.writeSlice("</ol>\n");
            } else {
                out.writeSlice("</ul>\n");
            }
        }

        fn renderTmpBlockquote(out: *Writer, text: []const u8, cursor: *usize, first_line: []const u8) void {
            var tmp = Writer.init(tmp_buf[0..]);
            var line = first_line;
            var line_start_set = false;
            var current_line_start: usize = 0;
            var started = false;
            var allow_lazy = false;

            while (true) {
                if (isBlankLine(line)) {
                    if (line_start_set) cursor.* = current_line_start;
                    break;
                }

                var stripped_line = Writer.init(tmp2_buf[0..]);
                if (appendBlockquoteStripped(&stripped_line, line)) {
                    const stripped = stripped_line.buf[0..stripped_line.idx];
                    appendTmp(&tmp, stripped);
                    appendTmp(&tmp, "\n");
                    started = true;
                    if (isBlankLine(stripped)) {
                        allow_lazy = false;
                    } else {
                        const si = leadingIndent(stripped);
                        const html_block = detectHtmlBlockStart(stripped, false);
                        allow_lazy = parseATXHeading(stripped) == null and
                            !parseThematicBreak(stripped) and
                            parseFenceOpen(stripped) == null and
                            (html_block == .none or html_block == .type7) and
                            si.cols < 4;
                    }
                } else {
                    if (!started or !allow_lazy) {
                        if (line_start_set) cursor.* = current_line_start;
                        break;
                    }
                    if (parseATXHeading(line) != null or
                        parseThematicBreak(line) or
                        parseFenceOpen(line) != null or
                        (leadingIndent(line).cols <= 3 and parseListMarker(line) != null))
                    {
                        if (line_start_set) cursor.* = current_line_start;
                        break;
                    }
                    const prev_blank = false;
                    const html_block = detectHtmlBlockStart(line, prev_blank);
                    if (html_block != .none and html_block != .type7) {
                        if (line_start_set) cursor.* = current_line_start;
                        break;
                    }
                    if (parseSetextUnderline(line) != null) appendTmp(&tmp, "    ");
                    appendTmp(&tmp, trimRightCR(line));
                    appendTmp(&tmp, "\n");
                    allow_lazy = true;
                }

                const save = cursor.*;
                const maybe_next = nextTmpLine(text, cursor);
                if (maybe_next == null) break;
                current_line_start = save;
                line_start_set = true;
                line = maybe_next.?;
            }

            out.writeSlice("<blockquote>\n");
            renderListItemContent(out, tmp.buf[0..tmp.idx], false);
            out.writeSlice("</blockquote>\n");
        }

        fn renderListItemContent(out: *Writer, text: []const u8, tight: bool) void {
            var cursor: usize = 0;
            var first_block = true;
            var prev_blank = true;
            var after_def = false;

            while (cursor < text.len) {
                const line = nextTmpLine(text, &cursor) orelse break;
                const was_after_def = after_def;
                after_def = false;
                if (isBlankLine(line)) {
                    prev_blank = true;
                    continue;
                }
                if (parseReferenceDefLine(line) != null) {
                    prev_blank = false;
                    after_def = true;
                    continue;
                }

                const ind = leadingIndent(line);
                if (ind.cols >= 4 and !was_after_def) {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    var code = Writer.init(tmp3_buf[0..]);
                    var code_line = line;
                    while (true) {
                        code.writeEscaped(stripIndentCols(code_line, 4));
                        code.writeByte('\n');
                        const save = cursor;
                        const maybe_next = nextTmpLine(text, &cursor);
                        if (maybe_next == null) break;
                        const nl = maybe_next.?;
                        if (isBlankLine(nl)) {
                            code_line = nl;
                            continue;
                        }
                        const ni = leadingIndent(nl);
                        if (ni.cols < 4) {
                            cursor = save;
                            break;
                        }
                        code_line = nl;
                    }

                    while (code.idx > 0) {
                        if (code.buf[code.idx - 1] != '\n') break;
                        var start = code.idx - 1;
                        while (start > 0 and code.buf[start - 1] != '\n') : (start -= 1) {}
                        const line_content = code.buf[start .. code.idx - 1];
                        if (trimAscii(line_content).len != 0) break;
                        code.idx = start;
                    }

                    out.writeSlice("<pre><code>");
                    out.writeSlice(code.buf[0..code.idx]);
                    out.writeSlice("</code></pre>\n");
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                const qi = leadingIndent(line);
                if (qi.cols <= 3 and qi.idx < line.len and line[qi.idx] == '>') {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    renderTmpBlockquote(out, text, &cursor, line);
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                const html_block = detectHtmlBlockStart(line, prev_blank);
                if (html_block != .none) {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    out.writeSlice(line);
                    out.writeByte('\n');
                    while (true) {
                        const save = cursor;
                        const maybe_next = nextTmpLine(text, &cursor);
                        if (maybe_next == null) break;
                        const nl = maybe_next.?;
                        if ((html_block == .type6 or html_block == .type7) and isBlankLine(nl)) {
                            prev_blank = true;
                            break;
                        }
                        var next_save = cursor;
                        const maybe_after = nextTmpLine(text, &next_save);
                        const next_is_blank = maybe_after == null or isBlankLine(maybe_after.?);
                        out.writeSlice(nl);
                        out.writeByte('\n');
                        if (htmlBlockEnds(html_block, nl, next_is_blank)) {
                            if ((html_block == .type6 or html_block == .type7) and maybe_after != null and isBlankLine(maybe_after.?)) {
                                cursor = next_save;
                            }
                            break;
                        }
                        _ = save;
                    }
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                if (parseFenceOpen(line)) |fence| {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    out.writeSlice("<pre><code");
                    if (fence.info.len > 0) {
                        var info_end: usize = 0;
                        while (info_end < fence.info.len and !isWhitespace(fence.info[info_end])) : (info_end += 1) {}
                        const lang = fence.info[0..info_end];
                        if (lang.len > 0) {
                            out.writeSlice(" class=\"language-");
                            writeLinkAttrEscaped(out, lang);
                            out.writeByte('"');
                        }
                    }
                    out.writeSlice(">");

                    while (true) {
                        const maybe_next = nextTmpLine(text, &cursor);
                        if (maybe_next == null) break;
                        const nl = maybe_next.?;
                        if (isFenceClose(nl, fence)) break;
                        var stripped = Writer.init(tmp3_buf[0..]);
                        appendStrippedIndent(&stripped, nl, fence.indent);
                        out.writeEscaped(stripped.buf[0..stripped.idx]);
                        out.writeByte('\n');
                    }
                    out.writeSlice("</code></pre>\n");
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                if (parseThematicBreak(line)) {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    out.writeSlice("<hr />\n");
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                if (parseATXHeading(line)) |h| {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    var tag: [6]u8 = undefined;
                    const open = std.fmt.bufPrint(&tag, "<h{d}>", .{h.level}) catch "<h1>";
                    out.writeSlice(open);
                    writeInline(out, h.text);
                    const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{h.level}) catch "</h1>\n";
                    out.writeSlice(close);
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                if (parseListMarker(line) != null) {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    renderTmpList(out, text, &cursor, line);
                    first_block = false;
                    prev_blank = false;
                    continue;
                }

                var para = Writer.init(tmp2_buf[0..]);
                para.writeSlice(line);
                var setext_level: u8 = 0;
                while (true) {
                    const save = cursor;
                    const maybe_next = nextTmpLine(text, &cursor);
                    if (maybe_next == null) break;
                    const nl = maybe_next.?;
                    if (isBlankLine(nl)) break;
                    if (parseSetextUnderline(nl)) |lvl| {
                        setext_level = lvl;
                        break;
                    }
                    if (parseATXHeading(nl) != null) {
                        cursor = save;
                        break;
                    }
                    if (parseThematicBreak(nl)) {
                        cursor = save;
                        break;
                    }
                    if (parseFenceOpen(nl) != null) {
                        cursor = save;
                        break;
                    }
                    if (canInterruptParagraphWithList(nl)) {
                        cursor = save;
                        break;
                    }
                    const nl_html = detectHtmlBlockStart(nl, false);
                    if (nl_html != .none and nl_html != .type7) {
                        cursor = save;
                        break;
                    }
                    const ni = leadingIndent(nl);
                    if (ni.cols <= 3 and ni.idx < nl.len and nl[ni.idx] == '>') {
                        cursor = save;
                        break;
                    }
                    para.writeByte('\n');
                    para.writeSlice(stripAllLeadingSpacesTabs(nl));
                }

                const paragraph = trimAscii(para.buf[0..para.idx]);
                if (setext_level != 0) {
                    if (!first_block and out.idx > 0 and out.buf[out.idx - 1] != '\n') out.writeByte('\n');
                    var tag: [7]u8 = undefined;
                    const open = std.fmt.bufPrint(&tag, "<h{d}>", .{setext_level}) catch "<h1>";
                    out.writeSlice(open);
                    writeInline(out, paragraph);
                    const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{setext_level}) catch "</h1>\n";
                    out.writeSlice(close);
                    first_block = false;
                    prev_blank = false;
                    continue;
                }
                if (tight and first_block) {
                    writeTaskListParagraph(out, paragraph);
                } else if (tight) {
                    writeInline(out, paragraph);
                } else {
                    out.writeSlice("<p>");
                    if (first_block) {
                        writeTaskListParagraph(out, paragraph);
                    } else {
                        writeInline(out, paragraph);
                    }
                    out.writeSlice("</p>\n");
                }
                first_block = false;
                prev_blank = false;
            }
        }

        const TaskListMarker = struct {
            checked: bool,
            content: []const u8,
        };

        fn parseTaskListMarker(paragraph: []const u8) ?TaskListMarker {
            if (!enable_gfm) return null;
            if (paragraph.len < 3 or paragraph[0] != '[' or paragraph[2] != ']') return null;
            const checked = switch (paragraph[1]) {
                'x', 'X' => true,
                ' ', '\t' => false,
                else => return null,
            };
            if (paragraph.len == 3) return .{ .checked = checked, .content = "" };
            if (!isWhitespace(paragraph[3])) return null;
            var content_start: usize = 3;
            while (content_start < paragraph.len and isWhitespace(paragraph[content_start])) : (content_start += 1) {}
            return .{ .checked = checked, .content = paragraph[content_start..] };
        }

        fn writeTaskListParagraph(out: *Writer, paragraph: []const u8) void {
            const marker = parseTaskListMarker(paragraph) orelse {
                writeInline(out, paragraph);
                return;
            };
            out.writeSlice("<input ");
            if (marker.checked) out.writeSlice("checked=\"\" ");
            out.writeSlice("disabled=\"\" type=\"checkbox\">");
            if (marker.content.len > 0) {
                out.writeByte(' ');
                writeInline(out, marker.content);
            }
        }

        fn firstListItemBlockIsCode(text: []const u8) bool {
            var cursor: usize = 0;
            var prev_blank = true;
            while (nextTmpLine(text, &cursor)) |line| {
                if (isBlankLine(line)) {
                    prev_blank = true;
                    continue;
                }
                if (parseATXHeading(line) != null) return true;
                {
                    var look = cursor;
                    while (nextTmpLine(text, &look)) |nl| {
                        if (isBlankLine(nl)) break;
                        if (parseSetextUnderline(nl) != null) return true;
                        if (parseATXHeading(nl) != null) break;
                        if (parseThematicBreak(nl)) break;
                        if (parseFenceOpen(nl) != null) break;
                        if (canInterruptParagraphWithList(nl)) break;
                        const nl_html = detectHtmlBlockStart(nl, false);
                        if (nl_html != .none and nl_html != .type7) break;
                        const ni = leadingIndent(nl);
                        if (ni.cols <= 3 and ni.idx < nl.len and nl[ni.idx] == '>') break;
                    }
                }
                if (leadingIndent(line).cols >= 4) return true;
                if (parseFenceOpen(line) != null) return true;
                const ind = leadingIndent(line);
                if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') return true;
                if (parseThematicBreak(line)) return true;
                if (parseListMarker(line) != null) return true;
                if (detectHtmlBlockStart(line, prev_blank) != .none) return true;
                return false;
            }
            return false;
        }

        fn firstListItemStartsFence(text: []const u8) bool {
            var cursor: usize = 0;
            while (nextTmpLine(text, &cursor)) |line| {
                if (isBlankLine(line)) continue;
                return parseFenceOpen(line) != null;
            }
            return false;
        }

        fn tmpInsideFence(text: []const u8) bool {
            var cursor: usize = 0;
            var open: ?Fence = null;
            while (nextTmpLine(text, &cursor)) |line| {
                if (open) |f| {
                    if (isFenceClose(line, f)) open = null;
                    continue;
                }
                if (parseFenceOpen(line)) |f| {
                    open = f;
                    continue;
                }
            }
            return open != null;
        }

        fn renderSimpleBlockquote(input: []const u8, out: *Writer, i_ptr: *u32) void {
            var i = i_ptr.*;
            var tmp = Writer.init(tmp_buf[0..]);
            var started = false;
            var allow_lazy = false;

            while (i < lines_count) : (i += 1) {
                const line = lineSlice(input, i);
                if (isBlankLine(line)) {
                    break;
                }
                var stripped_line = Writer.init(tmp2_buf[0..]);
                if (appendBlockquoteStripped(&stripped_line, line)) {
                    const stripped = stripped_line.buf[0..stripped_line.idx];
                    appendTmp(&tmp, stripped);
                    appendTmp(&tmp, "\n");
                    started = true;
                    if (isBlankLine(stripped)) {
                        allow_lazy = false;
                    } else {
                        const si = leadingIndent(stripped);
                        const prev_blank_for_html = false;
                        const html_block = detectHtmlBlockStart(stripped, prev_blank_for_html);
                        allow_lazy = parseATXHeading(stripped) == null and
                            !parseThematicBreak(stripped) and
                            parseFenceOpen(stripped) == null and
                            (html_block == .none or html_block == .type7) and
                            si.cols < 4;
                    }
                    continue;
                }
                if (!started) break;
                if (!allow_lazy) break;
                if (parseATXHeading(line) != null) break;
                if (parseThematicBreak(line)) break;
                if (parseFenceOpen(line) != null) break;
                if (leadingIndent(line).cols <= 3 and parseListMarker(line) != null) break;
                const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
                const html_block = detectHtmlBlockStart(line, prev_blank);
                if (html_block != .none and html_block != .type7) break;
                // Lazy continuation line inside an open blockquote paragraph.
                if (parseSetextUnderline(line) != null) appendTmp(&tmp, "    ");
                appendTmp(&tmp, trimRightCR(line));
                appendTmp(&tmp, "\n");
                allow_lazy = true;
            }

            out.writeSlice("<blockquote>\n");
            renderListItemContent(out, tmp.buf[0..tmp.idx], false);
            out.writeSlice("</blockquote>\n");
            i_ptr.* = i;
        }

        fn listHasSiblingSeparatorBlank(input: []const u8, start_i: u32, first: ListMarker) bool {
            var i = start_i;
            while (i < lines_count) {
                const line = lineSlice(input, i);
                if (isBlankLine(line)) {
                    i += 1;
                    continue;
                }
                if (parseThematicBreak(line)) break;
                if (leadingIndent(line).cols > 3) break;
                const mark = parseListMarker(line) orelse break;
                if (mark.kind != first.kind or mark.marker != first.marker) break;
                const item_content_base = listItemContinuationBase(line, mark);
                var saw_nested_list = false;
                var saw_nonblank = if (mark.content_start < line.len) trimAscii(line[mark.content_start..]).len != 0 else false;
                var in_fence: ?Fence = if (mark.content_start < line.len) parseFenceOpen(line[mark.content_start..]) else null;
                var lazy_ok = mark.content_start < line.len and contentOpensParagraph(line[mark.content_start..]);

                var j = i + 1;
                while (j < lines_count) : (j += 1) {
                    const ln = lineSlice(input, j);
                    if (isBlankLine(ln)) {
                        if (saw_nonblank and in_fence != null) continue;
                        lazy_ok = false;
                        var k = j + 1;
                        while (k < lines_count and isBlankLine(lineSlice(input, k))) : (k += 1) {}
                        if (k >= lines_count) return false;
                        const next_ln = lineSlice(input, k);
                        const ni = leadingIndent(next_ln);
                        const next_mark = if (ni.cols <= 3) parseListMarker(next_ln) else null;
                        if (next_mark) |nm| {
                            if (ni.cols < item_content_base) {
                                if (nm.kind == first.kind and nm.marker == first.marker) return true;
                                break;
                            }
                        } else if (ni.cols < item_content_base) {
                            break;
                        }
                        if (in_fence == null and (!saw_nested_list or ni.cols <= item_content_base + 1) and
                            !itemTailIsDefsOnly(input, k, item_content_base)) return true;
                        break;
                    }
                    const ind = leadingIndent(ln);
                    const maybe_next = if (ind.cols <= 3) parseListMarker(ln) else null;
                    if (maybe_next) |nm| {
                        if (ind.cols < item_content_base) {
                            if (nm.kind == first.kind and nm.marker == first.marker) break;
                            break;
                        }
                    }
                    if (ind.cols < item_content_base and maybe_next == null) {
                        if (saw_nonblank and lazy_ok and canLazyContinueListParagraph(ln)) continue;
                        break;
                    }
                    if (maybe_next != null and ind.cols >= item_content_base and
                        !(lazy_ok and parseSetextUnderline(stripIndentCols(ln, item_content_base)) != null))
                    {
                        saw_nested_list = true;
                    }
                    saw_nonblank = true;
                    if (ind.cols >= item_content_base) {
                        const stripped = stripIndentCols(ln, item_content_base);
                        if (in_fence) |f| {
                            if (isFenceClose(stripped, f)) in_fence = null;
                        } else if (parseFenceOpen(stripped)) |f| {
                            in_fence = f;
                        }
                    }
                    lazy_ok = contentOpensParagraph(stripIndentCols(ln, item_content_base));
                }
                i = j;
            }
            return false;
        }

        fn renderList(input: []const u8, out: *Writer, i_ptr: *u32, first: ListMarker) void {
            const ordered = first.kind == .ordered;
            if (ordered) {
                if (first.ordered_start != 1) {
                    out.writeSlice("<ol start=\"");
                    var num_buf: [32]u8 = undefined;
                    const n = std.fmt.bufPrint(&num_buf, "{d}", .{first.ordered_start}) catch "1";
                    out.writeSlice(n);
                    out.writeSlice("\">\n");
                } else {
                    out.writeSlice("<ol>\n");
                }
            } else {
                out.writeSlice("<ul>\n");
            }

            var i = i_ptr.*;
            var list_is_loose = listHasSiblingSeparatorBlank(input, i_ptr.*, first);
            while (i < lines_count) {
                const line = lineSlice(input, i);
                if (isBlankLine(line)) {
                    i += 1;
                    continue;
                }
                if (parseThematicBreak(line)) break;
                if (leadingIndent(line).cols > 3) break;

                const mark = parseListMarker(line) orelse break;
                if (mark.kind != first.kind or mark.marker != first.marker) break;
                const item_content_base = listItemContinuationBase(line, mark);

                var tmp = Writer.init(tmp_buf[0..]);
                appendListItemFirstLine(&tmp, line, mark);
                var item_has_blank = false;
                var saw_nonblank = trimAscii(tmp.buf[0..tmp.idx]).len != 0;
                var separator_blank = false;
                var saw_nested_list = false;
                const first_line_trimmed = trimRightCR(line);
                var lazy_ok = mark.content_start < first_line_trimmed.len and
                    contentOpensParagraph(first_line_trimmed[mark.content_start..]);
                var fence_trailing_blank = false;

                var j = i + 1;
                while (j < lines_count) : (j += 1) {
                    const ln = lineSlice(input, j);
                    if (isBlankLine(ln)) {
                        if (saw_nonblank and tmpInsideFence(tmp.buf[0..tmp.idx])) {
                            // Inside an open fence the blank is fence content
                            // and cannot end the item.
                            appendTmp(&tmp, "\n");
                            fence_trailing_blank = true;
                            continue;
                        }
                        if (!saw_nonblank) break;
                        var k = j + 1;
                        while (k < lines_count and isBlankLine(lineSlice(input, k))) : (k += 1) {}
                        if (k >= lines_count) break;
                        const next_ln = lineSlice(input, k);
                        const next_ind = leadingIndent(next_ln);
                        if (next_ind.cols <= 3) {
                            if (parseListMarker(next_ln)) |nm| {
                                if (next_ind.cols < item_content_base) {
                                    if (nm.kind == first.kind and nm.marker == first.marker) {
                                        separator_blank = true;
                                    }
                                    break;
                                }
                            } else if (next_ind.cols < item_content_base) {
                                break;
                            }
                        } else if (next_ind.cols < item_content_base) {
                            break;
                        }
                        appendTmp(&tmp, "\n");
                        if (!tmpInsideFence(tmp.buf[0..tmp.idx]) and (!saw_nested_list or next_ind.cols <= item_content_base + 1) and
                            !itemTailIsDefsOnly(input, k, item_content_base))
                        {
                            item_has_blank = true;
                        }
                        lazy_ok = false;
                        continue;
                    }

                    const ind = leadingIndent(ln);
                    const maybe_next = if (ind.cols <= 3) parseListMarker(ln) else null;
                    if (maybe_next) |nm| {
                        _ = nm;
                        if (ind.cols < item_content_base) break;
                    }
                    if (ind.cols < item_content_base and maybe_next == null) {
                        if (saw_nonblank and lazy_ok and !tmpInsideFence(tmp.buf[0..tmp.idx]) and canLazyContinueListParagraph(ln)) {
                            appendTmp(&tmp, "\n");
                            // A setext underline cannot be a lazy continuation
                            // line; indent it so it stays paragraph text after
                            // reassembly (leading whitespace is stripped during
                            // paragraph assembly).
                            if (parseSetextUnderline(ln) != null) appendTmp(&tmp, "    ");
                            appendTmp(&tmp, trimRightCR(ln));
                            saw_nonblank = true;
                            continue;
                        }
                        break;
                    }
                    if (maybe_next != null and ind.cols >= item_content_base and
                        !(lazy_ok and parseSetextUnderline(stripIndentCols(ln, item_content_base)) != null))
                    {
                        saw_nested_list = true;
                    }

                    appendTmp(&tmp, "\n");
                    appendListContinuation(&tmp, ln, item_content_base);
                    saw_nonblank = true;
                    fence_trailing_blank = false;
                    lazy_ok = contentOpensParagraph(stripIndentCols(ln, item_content_base));
                }

                if (fence_trailing_blank) appendTmp(&tmp, "\n");
                const item_is_tight = !(list_is_loose or item_has_blank or separator_blank);
                const item_empty = trimAscii(tmp.buf[0..tmp.idx]).len == 0;
                if (item_empty) {
                    out.writeSlice("<li></li>\n");
                    list_is_loose = list_is_loose or item_has_blank or separator_blank;
                } else {
                    if (!item_is_tight or firstListItemBlockIsCode(tmp.buf[0..tmp.idx])) {
                        out.writeSlice("<li>\n");
                    } else {
                        out.writeSlice("<li>");
                    }
                    renderListItemContent(out, tmp.buf[0..tmp.idx], item_is_tight);
                    out.writeSlice("</li>\n");
                    list_is_loose = list_is_loose or item_has_blank or separator_blank;
                }

                i = j;
            }

            if (ordered) {
                out.writeSlice("</ol>\n");
            } else {
                out.writeSlice("</ul>\n");
            }
            i_ptr.* = i;
        }

        const MAX_TABLE_COLUMNS: usize = 256;

        const TableAlign = enum {
            none,
            left,
            center,
            right,
        };

        fn isTablePipeAt(line: []const u8, index: usize) bool {
            return line[index] == '|' and !isEscapedAt(line, index);
        }

        fn splitTableRow(line_in: []const u8, cells: *[MAX_TABLE_COLUMNS][]const u8) ?usize {
            const line = trimAscii(line_in);
            if (line.len == 0) return null;

            var start: usize = 0;
            var end = line.len;
            if (isTablePipeAt(line, 0)) start = 1;
            if (end > start and isTablePipeAt(line, end - 1)) end -= 1;

            var count: usize = 0;
            var cell_start = start;
            var i = start;
            while (i <= end) : (i += 1) {
                if (i != end and !isTablePipeAt(line, i)) continue;
                if (count == MAX_TABLE_COLUMNS) return null;
                cells[count] = trimAscii(line[cell_start..i]);
                count += 1;
                cell_start = i + 1;
            }
            return if (count == 0) null else count;
        }

        fn parseTableDelimiterCell(cell_in: []const u8) ?TableAlign {
            var cell = trimAscii(cell_in);
            var left = false;
            var right = false;
            if (cell.len > 0 and cell[0] == ':') {
                left = true;
                cell = cell[1..];
            }
            if (cell.len > 0 and cell[cell.len - 1] == ':') {
                right = true;
                cell = cell[0 .. cell.len - 1];
            }
            if (cell.len == 0) return null;
            for (cell) |byte| if (byte != '-') return null;
            if (left and right) return .center;
            if (left) return .left;
            if (right) return .right;
            return .none;
        }

        fn parseTableDelimiter(line: []const u8, expected_count: usize, alignments: *[MAX_TABLE_COLUMNS]TableAlign) bool {
            var cells: [MAX_TABLE_COLUMNS][]const u8 = undefined;
            const count = splitTableRow(line, &cells) orelse return false;
            if (count != expected_count) return false;
            for (cells[0..count], 0..) |cell, index| {
                alignments[index] = parseTableDelimiterCell(cell) orelse return false;
            }
            return true;
        }

        fn writeTableAlign(out: *Writer, alignment: TableAlign) void {
            switch (alignment) {
                .none => {},
                .left => out.writeSlice(" align=\"left\""),
                .center => out.writeSlice(" align=\"center\""),
                .right => out.writeSlice(" align=\"right\""),
            }
        }

        fn writeTableCellInline(out: *Writer, cell: []const u8) void {
            var unescaped = Writer.init(tmp4_buf[0..]);
            var i: usize = 0;
            while (i < cell.len) : (i += 1) {
                if (cell[i] == '\\' and i + 1 < cell.len and cell[i + 1] == '|') {
                    unescaped.writeByte('|');
                    i += 1;
                } else {
                    unescaped.writeByte(cell[i]);
                }
            }
            if (!unescaped.overflow) writeInline(out, unescaped.buf[0..unescaped.idx]);
        }

        fn writeTableRow(
            out: *Writer,
            cells: []const []const u8,
            column_count: usize,
            alignments: *const [MAX_TABLE_COLUMNS]TableAlign,
            header: bool,
        ) void {
            out.writeSlice("<tr>\n");
            var column: usize = 0;
            while (column < column_count) : (column += 1) {
                if (header) out.writeSlice("<th") else out.writeSlice("<td");
                writeTableAlign(out, alignments[column]);
                out.writeByte('>');
                if (column < cells.len) writeTableCellInline(out, cells[column]);
                if (header) out.writeSlice("</th>\n") else out.writeSlice("</td>\n");
            }
            out.writeSlice("</tr>\n");
        }

        fn tableBodyCanContinue(line: []const u8) bool {
            if (isBlankLine(line)) return false;
            const ind = leadingIndent(line);
            if (ind.cols >= 4) return false;
            if (ind.idx < line.len and line[ind.idx] == '>') return false;
            if (parseATXHeading(line) != null or parseThematicBreak(line) or parseFenceOpen(line) != null) return false;
            if (parseListMarker(line) != null) return false;
            return true;
        }

        fn renderTable(input: []const u8, out: *Writer, i_ptr: *u32) bool {
            const start = i_ptr.*;
            if (start + 1 >= lines_count) return false;

            var header_cells: [MAX_TABLE_COLUMNS][]const u8 = undefined;
            const header_count = splitTableRow(lineSlice(input, start), &header_cells) orelse return false;
            if (std.mem.indexOfScalar(u8, lineSlice(input, start), '|') == null) return false;

            var alignments: [MAX_TABLE_COLUMNS]TableAlign = undefined;
            if (!parseTableDelimiter(lineSlice(input, start + 1), header_count, &alignments)) return false;

            out.writeSlice("<table>\n<thead>\n");
            writeTableRow(out, header_cells[0..header_count], header_count, &alignments, true);
            out.writeSlice("</thead>\n");

            var i = start + 2;
            var wrote_body = false;
            while (i < lines_count and tableBodyCanContinue(lineSlice(input, i))) : (i += 1) {
                var body_cells: [MAX_TABLE_COLUMNS][]const u8 = undefined;
                const body_count = splitTableRow(lineSlice(input, i), &body_cells) orelse break;
                if (!wrote_body) {
                    out.writeSlice("<tbody>\n");
                    wrote_body = true;
                }
                writeTableRow(out, body_cells[0..body_count], header_count, &alignments, false);
            }
            if (wrote_body) out.writeSlice("</tbody>\n");
            out.writeSlice("</table>\n");
            i_ptr.* = i;
            return true;
        }

        fn renderHTMLBlock(input: []const u8, out: *Writer, i_ptr: *u32, block: HtmlBlockType) void {
            var i = i_ptr.*;
            while (i < lines_count) : (i += 1) {
                const line = lineRawSlice(input, i);
                if (block == .type1) {
                    out.writeSlice(line);
                } else {
                    writeTagFiltered(out, line);
                }
                if (line.len == 0 or line[line.len - 1] != '\n') out.writeByte('\n');
                const next_is_blank = i + 1 >= lines_count or isBlankLine(lineSlice(input, i + 1));
                if (htmlBlockEnds(block, trimRightCR(lineSlice(input, i)), next_is_blank)) {
                    if ((block == .type6 or block == .type7) and i + 1 < lines_count and isBlankLine(lineSlice(input, i + 1))) {
                        i += 1;
                    }
                    i += 1;
                    break;
                }
            }
            i_ptr.* = i;
        }

        fn renderBlocks(input: []const u8, out: *Writer) void {
            var i: u32 = 0;
            var after_def = false;
            while (i < lines_count and !out.overflow) {
                const line = lineSlice(input, i);
                const was_after_def = after_def;
                after_def = false;

                if (isBlankLine(line)) {
                    i += 1;
                    continue;
                }
                const ind = leadingIndent(line);
                if (ind.cols >= 4) {
                    if (was_after_def) {
                        // A reference definition is consumed out of a
                        // paragraph, so a following indented line continues
                        // that paragraph rather than opening indented code.
                        renderParagraph(input, out, &i);
                        continue;
                    }
                    renderIndentedCode(input, out, &i);
                    continue;
                }

                if (enable_gfm and renderTable(input, out, &i)) continue;

                if (parseATXHeading(line)) |h| {
                    var tag: [6]u8 = undefined;
                    const open = std.fmt.bufPrint(&tag, "<h{d}>", .{h.level}) catch "<h1>";
                    out.writeSlice(open);
                    writeInline(out, h.text);
                    const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{h.level}) catch "</h1>\n";
                    out.writeSlice(close);
                    i += 1;
                    continue;
                }

                if (parseThematicBreak(line)) {
                    out.writeSlice("<hr />\n");
                    i += 1;
                    continue;
                }

                if (parseFenceOpen(line)) |f| {
                    renderFencedCode(input, out, &i, f);
                    continue;
                }

                const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
                const html_block = detectHtmlBlockStart(line, prev_blank);
                if (html_block != .none) {
                    renderHTMLBlock(input, out, &i, html_block);
                    continue;
                }

                if (parseReferenceDefAt(input, i)) |def| {
                    i = def.next_idx;
                    after_def = true;
                    continue;
                }

                if (parseListMarker(line)) |mark| {
                    renderList(input, out, &i, mark);
                    continue;
                }

                if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') {
                    renderSimpleBlockquote(input, out, &i);
                    continue;
                }

                var setext_level: u8 = 0;
                var setext_underline_idx: u32 = 0;
                var j = i + 1;
                while (j < lines_count) : (j += 1) {
                    const l = lineSlice(input, j);
                    if (isBlankLine(l)) break;
                    if (parseSetextUnderline(l)) |lvl| {
                        setext_level = lvl;
                        setext_underline_idx = j;
                        break;
                    }
                    if (parseATXHeading(l) != null) break;
                    if (parseThematicBreak(l)) break;
                    if (parseFenceOpen(l) != null) break;
                    if (canInterruptParagraphWithList(l)) break;
                    const l_prev_blank = if (j == 0) true else isBlankLine(lineSlice(input, j - 1));
                    const l_html_block = detectHtmlBlockStart(l, l_prev_blank);
                    if (l_html_block != .none and l_html_block != .type7) break;
                    const li = leadingIndent(l);
                    if (li.cols <= 3 and li.idx < l.len and l[li.idx] == '>') break;
                }
                if (setext_level != 0) {
                    var para = Writer.init(tmp2_buf[0..]);
                    var k = i;
                    while (k < setext_underline_idx) : (k += 1) {
                        if (k != i) para.writeByte('\n');
                        const l = lineSlice(input, k);
                        if (k != i and leadingIndent(l).cols >= 4) {
                            para.writeSlice(trimRightSpacesTabs(stripIndentCols(l, 4)));
                        } else {
                            para.writeSlice(trimRightSpacesTabs(stripBlockIndentUpTo3(l)));
                        }
                    }
                    if (!para.overflow) {
                        var tag: [7]u8 = undefined;
                        const open = std.fmt.bufPrint(&tag, "<h{d}>", .{setext_level}) catch "<h1>";
                        out.writeSlice(open);
                        writeInline(out, para.buf[0..para.idx]);
                        const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{setext_level}) catch "</h1>\n";
                        out.writeSlice(close);
                        i = setext_underline_idx + 1;
                        continue;
                    }
                }

                renderParagraph(input, out, &i);
            }
        }

        fn compactEmptyListItems(buf: []u8, len: usize) usize {
            const pattern = "<li>\n</li>\n";
            const replacement = "<li></li>\n";
            var r: usize = 0;
            var w: usize = 0;
            while (r < len) {
                if (r + pattern.len <= len and std.mem.eql(u8, buf[r .. r + pattern.len], pattern)) {
                    @memcpy(buf[w..][0..replacement.len], replacement);
                    w += replacement.len;
                    r += pattern.len;
                    continue;
                }
                buf[w] = buf[r];
                w += 1;
                r += 1;
            }
            return w;
        }

        pub fn renderMarkdown(input: []const u8, out: []u8) u32 {
            if (!splitLines(input)) return 0;
            collectReferenceDefs(input);
            var w = Writer.init(out);
            renderBlocks(input, &w);
            if (w.overflow) return 0;
            w.idx = compactEmptyListItems(w.buf, w.idx);
            return w.len();
        }

        pub fn render(input_size_in: u32) u32 {
            var input_size = input_size_in;
            if (input_size > INPUT_CAP) input_size = INPUT_CAP;

            const in = input_buf[0..@as(usize, @intCast(input_size))];
            return renderMarkdown(in, output_buf[0..]);
        }
    };
}
