// Accepts a valid BCP 47 (RFC 5646 section 2.2.9) language tag unchanged.
// A valid tag is well-formed, every language, extlang, script, region and
// variant subtag is in the IANA Language Subtag Registry (or the whole tag is
// grandfathered), and no variant or extension singleton repeats.
//
// Deprecated subtags are still registered, so they pass. Extension and
// private-use contents are not checked against any registry, and extlang and
// variant Prefix fields are not enforced; RFC 5646 does not make those part
// of validity.
//
// Rejection reports the subtag offset times 4 plus the failure mode.
const bcp47 = @import("lib/bcp47.zig");
const registry = @import("lib/bcp47-registry.zig");

const INPUT_CAP: usize = 1024;
var input_buf: [INPUT_CAP]u8 = undefined;
var parsed: bcp47.Parsed = undefined;

const Mode = enum(u32) {
    malformed = 0,
    unregistered = 1,
    duplicate_variant = 2,
    duplicate_singleton = 3,
};

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

// Accepted output is the input itself.
export fn output_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn failure_modes_per_input_offset() u32 {
    return 4;
}

fn alphaIndex(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| n = n * 26 + (bcp47.lower(c) - 'a');
    return n;
}

fn packed64(s: []const u8) u64 {
    var n: u64 = 0;
    for (s) |c| n = (n << 8) | bcp47.lower(c);
    return n;
}

fn regionIndex(s: []const u8) u32 {
    if (s.len == 2) return alphaIndex(s);
    var n: u32 = 0;
    for (s) |c| n = n * 10 + (c - '0');
    return 26 * 26 + n;
}

fn testBit(words: []const u64, bit: u32) bool {
    return (words[bit / 64] >> @intCast(bit % 64)) & 1 == 1;
}

fn contains(comptime T: type, sorted: []const T, value: T) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] < value) lo = mid + 1 else hi = mid;
    }
    return lo < sorted.len and sorted[lo] == value;
}

fn isRegistered(s: []const u8, kind: bcp47.Kind) bool {
    return switch (kind) {
        // No 4-8 letter languages are registered; the generator checks this.
        .language => s.len <= 3 and testBit(&registry.language_bits, if (s.len == 2) alphaIndex(s) else 26 * 26 + alphaIndex(s)),
        .extlang => contains(u32, &registry.extlangs, @intCast(packed64(s))),
        .script => contains(u32, &registry.scripts, @intCast(packed64(s))),
        .region => testBit(&registry.region_bits, regionIndex(s)),
        .variant => contains(u64, &registry.variants, packed64(s)),
        .singleton, .extension, .privateuse_singleton, .privateuse => true,
    };
}

const Failure = struct { offset: u32, mode: Mode };

fn check(input: []const u8) ?Failure {
    if (bcp47.parse(input, &parsed)) |err| return .{ .offset = err.offset, .mode = .malformed };
    if (parsed.grandfathered) return null;

    const subtags = parsed.subtags[0..parsed.count];
    var singletons: u64 = 0;
    for (subtags, 0..) |subtag, i| {
        const s = input[subtag.start..][0..subtag.len];
        if (!isRegistered(s, subtag.kind)) return .{ .offset = subtag.start, .mode = .unregistered };
        switch (subtag.kind) {
            .variant => for (subtags[0..i]) |earlier| {
                if (earlier.kind == .variant and bcp47.eqlIgnoreCase(input[earlier.start..][0..earlier.len], s)) {
                    return .{ .offset = subtag.start, .mode = .duplicate_variant };
                }
            },
            .singleton => {
                const c = bcp47.lower(s[0]);
                const bit = @as(u64, 1) << @intCast(if (c <= '9') c - '0' else c - 'a' + 10);
                if (singletons & bit != 0) return .{ .offset = subtag.start, .mode = .duplicate_singleton };
                singletons |= bit;
            },
            else => {},
        }
    }
    return null;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    if (check(input_buf[0..input_size])) |failure| {
        return .{ .output_size_or_failure = failure.offset * 4 + @intFromEnum(failure.mode), .output_ptr = 0, .failed = 1 };
    }
    return .{ .output_size_or_failure = input_size, .output_ptr = @intCast(@intFromPtr(&input_buf)), .failed = 0 };
}

const std = @import("std");

test {
    _ = bcp47;
}

fn expectValid(tag: []const u8) !void {
    if (check(tag)) |failure| {
        std.debug.print("expected valid: {s} ({s} at {d})\n", .{ tag, @tagName(failure.mode), failure.offset });
        return error.TestUnexpectedResult;
    }
}

fn expectInvalid(tag: []const u8, offset: u32, mode: Mode) !void {
    const failure = check(tag) orelse {
        std.debug.print("expected invalid: {s}\n", .{tag});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(mode, failure.mode);
    try std.testing.expectEqual(offset, failure.offset);
}

test "RFC 5646 appendix A valid examples" {
    for ([_][]const u8{
        "de",                    "fr",          "ja",                     "i-enochian",
        "zh-Hant",               "zh-Hans",     "sr-Cyrl",                "sr-Latn",
        "zh-cmn-Hans-CN",        "cmn-Hans-CN", "zh-yue-HK",              "yue-HK",
        "zh-Hans-CN",            "sr-Latn-RS",  "sl-rozaj",               "sl-rozaj-biske",
        "sl-nedis",              "de-CH-1901",  "sl-IT-nedis",            "hy-Latn-IT-arevela",
        "de-DE",                 "en-US",       "es-419",                 "de-CH-x-phonebk",
        "az-Arab-x-AZE-derbend", "x-whatever",  "qaa-Qaaa-QM-x-southern", "de-Qaaa",
        "sr-Latn-QM",            "sr-Qaaa-RS",  "en-US-u-islamcal",       "zh-CN-a-myext-x-private",
        "en-a-myext-b-another",  "qtz-Qabx-XZ", "zh-min-nan",             "EN-gb-OED",
        "iw",                    "en-x-a-a",    "en-ZZ",
    }) |tag| try expectValid(tag);
}

test "invalid tags report the subtag and mode" {
    try expectInvalid("de-419-DE", 7, .malformed);
    try expectInvalid("a-DE", 0, .malformed);
    try expectInvalid("ar-a-aaa-b-bbb-a-ccc", 15, .duplicate_singleton);
    try expectInvalid("sl-rozaj-ROZAJ", 9, .duplicate_variant);
    try expectInvalid("qq-ZZ", 0, .unregistered);
    try expectInvalid("en-QL", 3, .unregistered);
    try expectInvalid("en-Abcd-US", 3, .unregistered);
    try expectInvalid("en-US-abcde", 6, .unregistered);
    try expectInvalid("abcde", 0, .unregistered);
    try expectInvalid("zh-xyz", 3, .unregistered);
    try expectInvalid("en-999", 3, .unregistered);
    try expectInvalid("qzz", 0, .unregistered);
}

test "registry tables come from the pinned snapshot" {
    try std.testing.expectEqualStrings("2026-09-17", registry.file_date);
}
