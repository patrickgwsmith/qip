//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/iana-media-type-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "IANA MEDIA TYPES";
pub const record_count = data.media_types.len;
pub const rank_count = 1;
const containsFolded = content.containsFolded;
comptime {
    _ = content;
}
pub fn matches(record: usize, query: []const u8) bool {
    const media_type = data.media_types[record];
    const term = query;
    return containsFolded(media_type.name, term) or
        containsFolded(media_type.qualifier, term) or
        containsFolded(media_type.references, term);
}

pub fn rank(_: usize, _: []const u8) usize {
    return 0;
}
pub fn label(w: *content.Writer, record: usize) void {
    const r = data.media_types[record];
    w.text(r.name);
    w.text("  ");
    w.text(r.qualifier);
}
pub fn details(w: *content.Writer, record: usize) void {
    const r = data.media_types[record];
    w.field("Media type", r.name);
    w.field("IANA label", r.qualifier);
    w.field("References", r.references);
    w.field("Record date", r.date);
    w.field("IANA updated", data.updated);
    w.wrap("This registry does not map filename extensions.");
}
