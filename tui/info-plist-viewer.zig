//! Info.plist-specific view of the shared XML and binary plist parser.
pub const info_plist_mode = true;

comptime {
    _ = @import("plist-viewer.zig");
}
