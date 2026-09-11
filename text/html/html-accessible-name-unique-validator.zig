const std = @import("std");
const accessibility = @import("lib/html-accessibility.zig");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const CONTENT_TYPE = "text/html";

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&accessibility.input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    if (!accessibility.accessibleNamesAreUnique(accessibility.input_buf[0..input_size])) @trap();
    return input_size_in;
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&accessibility.input_buf)),
        .failed = 0,
    };
}

fn validate(input: []const u8) bool {
    return accessibility.accessibleNamesAreUnique(input);
}

test "accepts distinct computed accessible names" {
    try std.testing.expect(validate("<main><button>Save</button><button>Cancel</button><img alt=Logo></main>"));
}

test "rejects duplicate names from different naming mechanisms" {
    try std.testing.expect(!validate("<button>Save</button><button aria-label=Save>Icon</button>"));
    try std.testing.expect(!validate("<span id=label>Account</span><input aria-labelledby=label><input aria-label=Account>"));
    try std.testing.expect(!validate("<label for=one>Email</label><input id=one><input title=Email>"));
}

test "ignores empty names and hidden accessible objects" {
    try std.testing.expect(validate("<main><p>One</p><p>Two</p><button></button><button hidden>Save</button><button>Save</button></main>"));
}

test "scopes link name uniqueness to the nearest navigation landmark" {
    try std.testing.expect(!validate("<nav><a href=/one>Docs</a><a href=/two aria-label=Docs>Other</a></nav>"));
    try std.testing.expect(validate("<nav aria-label=Primary><a href=/one>Docs</a></nav><nav aria-label=Footer><a href=/two>Docs</a></nav><a href=/three>Docs</a><a href=/four>Docs</a>"));
}

test "allows structural content to share accessible names" {
    try std.testing.expect(validate("<h2>Status</h2><h3>Status</h3><table><tr><td>Ready</td><td>Ready</td></tr></table>"));
}

test "requires unique h2 accessible names" {
    try std.testing.expect(!validate("<h2>Install</h2><h2 aria-label=Install>Setup</h2>"));
    try std.testing.expect(validate("<h2>Install</h2><h3>Install</h3><button>Install</button>"));
}
