// This oracle is a pure spec mirror: the 655 embedded examples, nothing else.
// The spec areas the examples under-exercise are covered by sibling oracles:
// compliance/html5-entities.comply.wasm (all HTML5 named references + numeric
// edge cases) and compliance/unicode-17-casefold-labels.comply.wasm (full
// Unicode 17 label folding) — both must_render_into-based so they assert only the
// behavior under test. Pathological-input time budgets live in
// tools/test-markdown-pathological.sh (wired into make test), and
// tools/fuzz-markdown-vs-cmark.py differentially fuzzes the component against
// cmark 0.31.2 as oracle, and its minimized findings are frozen (by
// tools/freeze-markdown-divergences.py) into
// compliance/commonmark-differential-corpus.comply.wasm — expected to fail
// until the delimiter-stack rewrite (see the TODO block in
// text/markdown/lib/commonmark.zig) lands, then wired into
// test-comply and regrown from fresh fuzz runs.
// TODO(testing): Property fuzzing via the --seed/Luhn generative-oracle pattern
// (docs/comply.md): arbitrary bytes (including invalid UTF-8) must never trap, and
// output must always be valid UTF-8, as the utf8 cap exports promise.
const std = @import("std");

extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

const SPEC_TEXT = @embedFile("commonmark-spec-0.31.2.txt");
const SPEC_EXAMPLE_COUNT: usize = 655;
const OPEN_LINE = ("`" ** 32) ++ " example\n";
const SEPARATOR = "\n.\n";
const EMPTY_SEPARATOR = ".\n";
const CLOSE_LINE = ("`" ** 32) ++ "\n";
const OPEN_SKIP = skipTable(OPEN_LINE);
const SEPARATOR_SKIP = skipTable(SEPARATOR);
const CLOSE_SKIP = skipTable(CLOSE_LINE);

const Segment = struct { start: usize, len: usize };
const Case = struct { input: Segment, expected: Segment };

fn skipTable(comptime sequence: []const u8) [256]usize {
    var table = [_]usize{sequence.len} ** 256;
    for (sequence[0 .. sequence.len - 1], 0..) |byte, index| {
        table[byte] = sequence.len - 1 - index;
    }
    return table;
}

fn findSequence(comptime text: []const u8, start: usize, comptime sequence: []const u8, comptime table: *const [256]usize) ?usize {
    var cursor = start;
    while (cursor <= text.len - sequence.len) {
        if (std.mem.eql(u8, text[cursor..][0..sequence.len], sequence)) return cursor;
        cursor += table[text[cursor + sequence.len - 1]];
    }
    return null;
}

fn parseSpec(comptime spec_text: []const u8, comptime expected_count: usize) [expected_count]Case {
    @setEvalBranchQuota(1_000_000);

    var cases: [expected_count]Case = undefined;
    var cursor: usize = 0;
    var count: usize = 0;

    while (findSequence(spec_text, cursor, OPEN_LINE, &OPEN_SKIP)) |open_start| {
        if (count == expected_count) {
            @compileError("commonmark-spec-0.31.2.txt contains more examples than expected");
        }
        const input_start = open_start + OPEN_LINE.len;
        const input_end, const expected_start = if (std.mem.startsWith(u8, spec_text[input_start..], EMPTY_SEPARATOR))
            .{ input_start, input_start + EMPTY_SEPARATOR.len }
        else blk: {
            const separator_start = findSequence(spec_text, input_start, SEPARATOR, &SEPARATOR_SKIP) orelse
                @compileError("commonmark-spec-0.31.2.txt example has no separator");
            break :blk .{ separator_start + 1, separator_start + SEPARATOR.len };
        };
        const close_start = findSequence(spec_text, expected_start, CLOSE_LINE, &CLOSE_SKIP) orelse
            @compileError("commonmark-spec-0.31.2.txt example has no closing fence");
        cases[count] = .{
            .input = .{ .start = input_start, .len = input_end - input_start },
            .expected = .{ .start = expected_start, .len = close_start - expected_start },
        };
        count += 1;
        cursor = close_start + CLOSE_LINE.len;
    }

    if (count != expected_count) @compileError("commonmark-spec-0.31.2.txt example count changed");
    return cases;
}

fn containsTabArrow(comptime source: []const u8) bool {
    return std.mem.indexOf(u8, source, "→") != null;
}

fn normalizedLen(comptime source: []const u8) usize {
    @setEvalBranchQuota(100_000);
    var source_index: usize = 0;
    var len: usize = 0;
    while (source_index < source.len) : (len += 1) {
        source_index += if (std.mem.startsWith(u8, source[source_index..], "→")) 3 else 1;
    }
    return len;
}

fn normalize(comptime source: []const u8) [normalizedLen(source)]u8 {
    var result: [normalizedLen(source)]u8 = undefined;
    var source_index: usize = 0;
    var destination_index: usize = 0;
    while (source_index < source.len) : (destination_index += 1) {
        if (std.mem.startsWith(u8, source[source_index..], "→")) {
            result[destination_index] = '\t';
            source_index += 3;
        } else {
            result[destination_index] = source[source_index];
            source_index += 1;
        }
    }
    return result;
}

inline fn declareCase(comptime ordinal: usize, comptime input_raw: []const u8, comptime expected_raw: []const u8) void {
    if (comptime containsTabArrow(input_raw)) {
        const input = comptime normalize(input_raw);
        if (comptime containsTabArrow(expected_raw)) {
            const expected = comptime normalize(expected_raw);
            _ = must_render_exactly(ordinal, @intCast(@intFromPtr(&input)), input.len, @intCast(@intFromPtr(&expected)), expected.len);
        } else {
            _ = must_render_exactly(ordinal, @intCast(@intFromPtr(&input)), input.len, @intCast(@intFromPtr(expected_raw.ptr)), expected_raw.len);
        }
    } else if (comptime containsTabArrow(expected_raw)) {
        const expected = comptime normalize(expected_raw);
        _ = must_render_exactly(ordinal, @intCast(@intFromPtr(input_raw.ptr)), input_raw.len, @intCast(@intFromPtr(&expected)), expected.len);
    } else {
        _ = must_render_exactly(ordinal, @intCast(@intFromPtr(input_raw.ptr)), input_raw.len, @intCast(@intFromPtr(expected_raw.ptr)), expected_raw.len);
    }
}

const CASES = parseSpec(SPEC_TEXT, SPEC_EXAMPLE_COUNT);

export fn comply() i32 {
    inline for (CASES, 0..) |case, ordinal| {
        declareCase(
            ordinal,
            SPEC_TEXT[case.input.start..][0..case.input.len],
            SPEC_TEXT[case.expected.start..][0..case.expected.len],
        );
    }
    return SPEC_EXAMPLE_COUNT;
}
