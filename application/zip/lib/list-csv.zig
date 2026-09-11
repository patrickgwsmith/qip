const zip = @import("zip.zig");

const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Writer, value: []const u8) zip.Error!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    fn number(self: *Writer, value: u64) zip.Error!void {
        var buffer: [20]u8 = undefined;
        var remaining = value;
        var start = buffer.len;

        if (remaining == 0) {
            start -= 1;
            buffer[start] = '0';
        } else {
            while (remaining != 0) {
                start -= 1;
                const digit: u8 = @intCast(remaining % 10);
                buffer[start] = '0' + digit;
                remaining /= 10;
            }
        }
        try self.write(buffer[start..]);
    }

    fn mode(self: *Writer, value: u16) zip.Error!void {
        var buffer: [4]u8 = undefined;
        var remaining = value;
        var pos = buffer.len;
        while (pos != 0) {
            pos -= 1;
            buffer[pos] = @intCast('0' + (remaining & 7));
            remaining >>= 3;
        }
        try self.write(&buffer);
    }

    fn quoted(self: *Writer, value: []const u8) zip.Error!void {
        try self.write("\"");
        for (value) |byte| {
            if (byte == '"') try self.write("\"\"");
            const one = [1]u8{byte};
            try self.write(&one);
        }
        try self.write("\"");
    }
};

fn writeEntryRow(out: *Writer, entry: zip.Entry) zip.Error!void {
    try out.number(entry.entry_index);
    try out.write(",");
    if (entry.file_index) |file_index| try out.number(file_index);
    try out.write(",");
    try out.quoted(entry.path);
    try out.write(",");
    try out.write(entry.kind.text());
    try out.write(",");
    try out.write(entry.methodText());
    try out.write(",");
    try out.number(entry.compressed_size);
    try out.write(",");
    try out.number(entry.uncompressed_size);
    try out.write(",");
    try out.mode(entry.mode);
    try out.write(",");
    try out.number(entry.mtime);
    try out.write("\n");
}

fn writeFileRow(out: *Writer, entry: zip.Entry) zip.Error!void {
    try out.number(entry.file_index.?);
    try out.write(",");
    try out.number(entry.entry_index);
    try out.write(",");
    try out.quoted(entry.path);
    try out.write(",");
    try out.write(entry.methodText());
    try out.write(",");
    try out.number(entry.compressed_size);
    try out.write(",");
    try out.number(entry.uncompressed_size);
    try out.write(",");
    try out.mode(entry.mode);
    try out.write(",");
    try out.number(entry.mtime);
    try out.write("\n");
}

pub fn render(input: []const u8, output: []u8, files_only: bool) zip.Error!usize {
    var out = Writer{ .bytes = output };
    if (files_only) {
        try out.write("file_index,entry_index,path,method,compressed_size,size,mode,mtime\n");
    } else {
        try out.write("entry_index,file_index,path,type,method,compressed_size,size,mode,mtime\n");
    }

    var reader = try zip.Reader.init(input);
    while (try reader.next()) |entry| {
        if (files_only) {
            if (entry.kind == .regular) try writeFileRow(&out, entry);
        } else {
            try writeEntryRow(&out, entry);
        }
    }
    try reader.finish();
    return out.index;
}
