//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/caniuse-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "CAN I USE";
pub const record_count = data.features.len;
pub const rank_count = 3;
const containsFolded = content.containsFolded;
comptime {
    _ = content;
}
pub fn matches(record: usize, query: []const u8) bool {
    const feature = data.features[record];
    var terms = std.mem.tokenizeScalar(u8, query, ' ');
    while (terms.next()) |term| {
        if (!containsFolded(feature.search, term)) return false;
    }
    return true;
}

pub fn rank(record: usize, query: []const u8) usize {
    const feature = data.features[record];
    if (query.len > 0 and std.ascii.eqlIgnoreCase(feature.slug, query)) return 0;
    if (query.len > 0 and std.ascii.eqlIgnoreCase(feature.title, query)) return 1;
    return 2;
}
pub fn label(w: *content.Writer, record: usize) void {
    const r = data.features[record];
    w.text(r.title);
    w.text(" [");
    w.text(r.slug);
    w.text("]");
}
pub fn details(w: *content.Writer, record: usize) void {
    const r = data.features[record];
    w.wrap(r.title);
    const browsers = [_][]const u8{ "Chrome", "Firefox", "Safari", "Edge" };
    for (browsers, 0..) |browser, i| w.field(browser, r.summary[i]);
    w.text("https://caniuse.com/");
    w.wrap(r.slug);
    w.field("Description", r.description);
    w.field("Notes", r.notes);
    for (browsers, 0..) |browser, i| {
        w.wrap(browser);
        w.wrap(r.details[i]);
    }
    w.field("Snapshot", data.snapshot);
    w.wrap("Can I use data: CC BY 4.0.");
}
