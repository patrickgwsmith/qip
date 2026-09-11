const std = @import("std");
const recipe_book = @import("lib/recipe-book.zig");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 512 * 1024;
const INPUT_CONTENT_TYPE = "application/x-tar";
const OUTPUT_CONTENT_TYPE = "text/csv";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var recipes: [recipe_book.MAX_RECIPES]recipe_book.Recipe = undefined;
var recipe_order: [recipe_book.MAX_RECIPES]u16 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const Output = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Output, value: []const u8) !void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }
};

fn appendHex(out: *Output, digest: [32]u8) !void {
    const hex = "0123456789abcdef";
    if (64 > out.bytes.len - out.index) return error.OutputOverflow;
    for (digest) |byte| {
        out.bytes[out.index] = hex[byte >> 4];
        out.bytes[out.index + 1] = hex[byte & 0x0f];
        out.index += 2;
    }
}

fn appendCSVField(out: *Output, value: []const u8) !void {
    const quoted = std.mem.indexOfAny(u8, value, ",\"\r\n") != null;
    if (!quoted) return out.write(value);
    try out.write("\"");
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte != '"') continue;
        try out.write(value[start..index]);
        try out.write("\"\"");
        start = index + 1;
    }
    try out.write(value[start..]);
    try out.write("\"");
}

fn convert(input: []const u8, output: []u8) !usize {
    const book = try recipe_book.parse(input, &recipes, &recipe_order);
    var out = Output{ .bytes = output };
    try out.write("source_mime,step,module,bytes,sha256\n");
    for (book.sorted()) |recipe_index| {
        const recipe = &book.recipes[recipe_index];
        var number_buf: [24]u8 = undefined;
        try appendCSVField(&out, recipe.mime());
        try out.write(",");
        try out.write(std.fmt.bufPrint(&number_buf, "{d}", .{recipe.order}) catch return error.OutputOverflow);
        try out.write(",");
        try appendCSVField(&out, recipe.path());
        try out.write(",");
        try out.write(std.fmt.bufPrint(&number_buf, "{d}", .{recipe.body.len}) catch return error.OutputOverflow);
        try out.write(",");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(recipe.body, &digest, .{});
        try appendHex(&out, digest);
        try out.write("\n");
    }
    return out.index;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > INPUT_CAP) @trap();
    return @intCast(convert(input_buf[0..input_size], &output_buf) catch @trap());
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
