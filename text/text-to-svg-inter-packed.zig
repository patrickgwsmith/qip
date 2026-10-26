//! Render plain UTF-8 text as wrapped Inter Display paths on a transparent,
//! intrinsically sized SVG canvas.
//!
//! This fork of text-to-svg-inter.zig stores glyph outlines as packed i16
//! coordinates and deduplicated kerning rows. It produces the same SVG.

const builtin = @import("builtin");

pub const plain_text_input = !builtin.is_test;
pub const regular_font = @import("lib/inter_display_latin_packed_paths.zig");
pub const bold_font = @import("lib/inter_display_bold_latin_packed_paths.zig");

comptime {
    _ = @import("text-to-og-image-svg-inter.zig");
}

test "packed glyph paths match the string tables" {
    const std = @import("std");
    const pairs = .{
        .{ regular_font, @import("lib/inter_display_latin_paths.zig") },
        .{ bold_font, @import("lib/inter_display_bold_latin_paths.zig") },
    };
    inline for (pairs) |pair| {
        const packed_font = pair[0];
        const string_font = pair[1];
        var buffer: [packed_font.MAX_GLYPH_PATH_LEN]u8 = undefined;
        try std.testing.expectEqual(string_font.glyph_paths.len, packed_font.codepoints.len);
        for (string_font.glyph_paths, 0..) |path, glyph_index| {
            try std.testing.expectEqualStrings(path, packed_font.glyphPath(glyph_index, &buffer));
        }
        for (0..packed_font.codepoints.len) |left| {
            for (0..packed_font.codepoints.len) |right| {
                try std.testing.expectEqual(string_font.kerning(left, right), packed_font.kerning(left, right));
            }
        }
    }
}
