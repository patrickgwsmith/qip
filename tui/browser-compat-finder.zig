//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/browser-compat-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "BROWSER COMPATIBILITY";
pub const record_count = data.features.len;
pub const rank_count = 1;
const containsFolded = content.containsFolded;
comptime {
    _ = content;
}
pub fn matches(record: usize, query: []const u8) bool {
    const feature = data.features[record];
    const term = query;
    return containsFolded(feature.path, term);
}

pub fn rank(_: usize, _: []const u8) usize {
    return 0;
}
pub fn label(w: *content.Writer, record: usize) void {
    const r = data.features[record];
    w.text(r.path);
}
pub fn details(w: *content.Writer, record: usize) void {
    const r = data.features[record];
    w.wrap(r.path);
    const browsers = [_][]const u8{ "Chrome", "Firefox", "Safari", "Edge" };
    for (browsers, 0..) |browser, i| w.field(browser, r.summary[i]);
    for (browsers, 0..) |browser, i| {
        w.wrap(browser);
        w.wrap(r.details[i]);
    }
    w.field("Snapshot", data.snapshot);
}
