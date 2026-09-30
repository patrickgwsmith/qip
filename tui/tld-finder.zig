//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/tld-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "TOP-LEVEL DOMAINS";
pub const record_count = data.tlds.len;
pub const rank_count = 1;
const containsFolded = content.containsFolded;
comptime {
    _ = content;
}
pub fn matches(record: usize, query: []const u8) bool {
    const tld = data.tlds[record];
    const term = query;
    return containsFolded(tld.ascii, term) or
        containsFolded(tld.display, term) or
        containsFolded(tld.kind, term) or
        containsFolded(tld.manager, term);
}

pub fn rank(_: usize, _: []const u8) usize {
    return 0;
}
pub fn label(w: *content.Writer, record: usize) void {
    const r = data.tlds[record];
    w.text(r.ascii);
    w.text("  ");
    w.text(r.kind);
}
pub fn details(w: *content.Writer, record: usize) void {
    const r = data.tlds[record];
    w.field("Domain", r.display);
    w.field("ASCII / IDNA", r.ascii);
    w.field("Type", r.kind);
    w.field("Manager", r.manager);
    w.field("IANA snapshot", data.snapshot);
    w.wrap("Delegated does not imply open registration.");
}
