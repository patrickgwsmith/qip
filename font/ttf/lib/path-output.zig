const std = @import("std");
const ttf = @import("ttf.zig");

pub const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    pub fn write(self: *Writer, value: []const u8) ttf.Error!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    pub fn integer(self: *Writer, value: anytype) ttf.Error!void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.write(text);
    }

    pub fn coordinate(self: *Writer, input: f64) ttf.Error!void {
        const value = if (@abs(input) < 0.0000001) @as(f64, 0) else input;
        var buffer: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.write(text);
    }

    pub fn codepointHex(self: *Writer, codepoint: u32) ttf.Error!void {
        var buffer: [8]u8 = undefined;
        const text = if (codepoint <= 0xffff)
            std.fmt.bufPrint(&buffer, "{X:0>4}", .{codepoint}) catch return error.OutputOverflow
        else
            std.fmt.bufPrint(&buffer, "{X:0>6}", .{codepoint}) catch return error.OutputOverflow;
        try self.write(text);
    }
};

pub const PathWriter = struct {
    out: *Writer,
    has_command: bool = false,

    fn command(self: *PathWriter, name: []const u8) ttf.Error!void {
        if (self.has_command) try self.out.write(" ");
        try self.out.write(name);
        self.has_command = true;
    }

    pub fn moveTo(self: *PathWriter, x: f64, y: f64) ttf.Error!void {
        try self.command("M");
        try self.point(x, y);
    }

    pub fn lineTo(self: *PathWriter, x: f64, y: f64) ttf.Error!void {
        try self.command("L");
        try self.point(x, y);
    }

    pub fn quadTo(self: *PathWriter, cx: f64, cy: f64, x: f64, y: f64) ttf.Error!void {
        try self.command("Q");
        try self.point(cx, cy);
        try self.point(x, y);
    }

    pub fn close(self: *PathWriter) ttf.Error!void {
        try self.command("Z");
    }

    fn point(self: *PathWriter, x: f64, y: f64) ttf.Error!void {
        try self.out.write(" ");
        try self.out.coordinate(x);
        try self.out.write(" ");
        try self.out.coordinate(y);
    }
};

test "formats SVG path commands" {
    var bytes: [128]u8 = undefined;
    var out = Writer{ .bytes = &bytes };
    var path = PathWriter{ .out = &out };
    try path.moveTo(1, -2);
    try path.quadTo(3, 4, 5, 6);
    try path.close();
    try std.testing.expectEqualStrings("M 1 -2 Q 3 4 5 6 Z", bytes[0..out.index]);
}
