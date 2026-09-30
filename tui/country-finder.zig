//! Stateless offline finder. The host owns search, selection, and detail scrolling.
const std = @import("std");
const data = @import("lib/country-data.zig");
const content = @import("lib/finder-content.zig");
pub const output_capacity = 64 * 1024;
pub const title = "COUNTRIES";
pub const record_count = data.countries.len;
pub const rank_count = 1;
const containsFolded = content.containsFolded;
comptime {
    _ = content;
}
pub fn matches(record: usize, query: []const u8) bool {
    const country = data.countries[record];
    const term = query;
    return containsFolded(country.search_name, term) or
        containsFolded(country.name, term) or
        containsFolded(country.code, term) or
        containsFolded(country.alpha3, term) or
        containsFolded(country.currencies, term) or
        containsFolded(country.dial, term);
}

pub fn rank(_: usize, _: []const u8) usize {
    return 0;
}
pub fn label(w: *content.Writer, record: usize) void {
    const r = data.countries[record];
    w.text(r.code);
    w.text("  ");
    w.text(r.name);
}
pub fn details(w: *content.Writer, record: usize) void {
    const r = data.countries[record];
    w.field("Country", r.name);
    w.field("Alpha-2", r.code);
    w.field("Alpha-3", r.alpha3);
    w.field("Currency", r.currencies);
    w.field("Calling prefix", r.dial);
    w.field("Capital", r.capital);
    w.field("Region", r.region);
    w.field("Domain", r.tld);
}
