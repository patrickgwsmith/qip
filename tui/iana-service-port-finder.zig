//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/iana-service-port-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "IANA SERVICE PORTS";
pub const record_count = data.services.len;
pub const rank_count = 1;
const containsFolded = content.containsFolded;
comptime {
    _ = content;
}
fn portContainsNumber(port: []const u8, term: []const u8) bool {
    const number = std.fmt.parseInt(u32, term, 10) catch return false;
    if (std.mem.indexOfScalar(u8, port, '-')) |dash| {
        const first = std.fmt.parseInt(u32, port[0..dash], 10) catch return false;
        const last = std.fmt.parseInt(u32, port[dash + 1 ..], 10) catch return false;
        return number >= first and number <= last;
    }
    return (std.fmt.parseInt(u32, port, 10) catch return false) == number;
}

pub fn matches(record: usize, query: []const u8) bool {
    const service = data.services[record];
    var terms = std.mem.tokenizeScalar(u8, query, ' ');
    while (terms.next()) |term| {
        var all_digits = true;
        for (term) |char| {
            if (char < '0' or char > '9') all_digits = false;
        }
        if (all_digits) {
            if (!portContainsNumber(service.port, term)) return false;
        } else if (std.ascii.eqlIgnoreCase(term, "tcp") or
            std.ascii.eqlIgnoreCase(term, "udp") or
            std.ascii.eqlIgnoreCase(term, "sctp") or
            std.ascii.eqlIgnoreCase(term, "dccp"))
        {
            if (!std.ascii.eqlIgnoreCase(service.protocol, term)) return false;
        } else if (!containsFolded(service.name, term) and
            !containsFolded(service.protocol, term) and
            !containsFolded(service.description, term) and
            !containsFolded(service.reference, term)) return false;
    }
    return true;
}

pub fn rank(_: usize, _: []const u8) usize {
    return 0;
}
pub fn label(w: *content.Writer, record: usize) void {
    const r = data.services[record];
    w.text(r.port);
    w.text("/");
    w.text(r.protocol);
    w.text("  ");
    w.text(r.name);
    w.text("  ");
    w.text(r.description);
}
pub fn details(w: *content.Writer, record: usize) void {
    const r = data.services[record];
    w.field("Service", r.name);
    w.field("Port", r.port);
    w.field("Transport", r.protocol);
    w.field("Description", r.description);
    w.field("Reference", r.reference);
    w.field("Assignee", r.assignee);
    w.field("Registered", r.registered);
    w.field("Modified", r.modified);
    w.field("Notes", r.notes);
    w.field("IANA updated", data.updated);
}
