//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/caniemail-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "CAN I EMAIL";
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
    const clients = [_][]const u8{ "Apple Mail", "Gmail", "Outlook", "Yahoo! Mail" };
    for (clients, 0..) |client, i| w.field(client, r.summary[i]);
    w.text("https://www.caniemail.com/features/");
    w.text(r.slug);
    w.wrap("/");
    w.field("Category", r.category);
    w.field("Description", r.description);
    w.field("Notes", r.notes);
    w.field("Last tested", r.tested);
    w.wrap(r.clients);
    w.field("Snapshot", data.snapshot);
    w.wrap("Can I email data: MIT licence, (c) 2019 Remi Parmentier.");
}
