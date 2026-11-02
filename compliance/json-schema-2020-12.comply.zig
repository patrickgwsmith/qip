// JSON-Schema-Test-Suite, draft 2020-12 core tests (no optional/), as a
// Compliance oracle for validators that take the TAR layout of
// application/x-tar/json-schema-2020-12-must-be-valid.wasm:
//
//   schema.json, instance.json, and schemas/<scheme>/<rest> for each remote
//
// The cases come from json-schema-2020-12.fixtures.txt, flattened from the
// vendored suite in json-schema-test-suite/ by
// tools/gen-json-schema-2020-12-fixtures.mjs. A valid instance must render
// exactly its own bytes; an invalid instance must be rejected (not trapped).
//
// Building a TAR per case at comptime would embed ~4 MB of 512-byte blocks,
// so this is a generated oracle: it reads the fixture with a few mechanical
// line rules and writes each case's archive into its own buffer. It declares
// exactly the number of cases the fixture's "cases" line promises, or traps.
extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;
extern "qip" fn must_reject(ordinal: u64, input_ptr: u32, input_len: u32) i32;

const FIXTURE = @embedFile("json-schema-2020-12.fixtures.txt");
const MAX_REMOTES = 8;

var tar_buf: [64 * 1024]u8 = undefined;

const Remote = struct { uri: []const u8, json: []const u8 };

const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
        const line = self.text[start..self.pos];
        self.pos += 1;
        return line;
    }

    fn json(self: *Lines) []const u8 {
        return self.next() orelse @trap();
    }
};

fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (text[i] != c) return false;
    }
    return true;
}

fn indexOf(text: []const u8, needle: []const u8) ?usize {
    if (needle.len > text.len) return null;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (startsWith(text[i..], needle)) return i;
    }
    return null;
}

fn parseCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c < '0' or c > '9') @trap();
        n = n * 10 + (c - '0');
    }
    return n;
}

const TarWriter = struct {
    len: usize = 0,

    fn put(self: *TarWriter, bytes: []const u8) void {
        if (self.len + bytes.len > tar_buf.len) @trap();
        @memcpy(tar_buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn zeros(self: *TarWriter, count: usize) void {
        if (self.len + count > tar_buf.len) @trap();
        @memset(tar_buf[self.len..][0..count], 0);
        self.len += count;
    }

    fn octal(field: []u8, value: usize) void {
        // Zero-padded octal digits followed by NUL.
        var v = value;
        var i = field.len - 1;
        field[i] = 0;
        while (i > 0) {
            i -= 1;
            field[i] = '0' + @as(u8, @intCast(v & 7));
            v >>= 3;
        }
        if (v != 0) @trap();
    }

    // One ustar regular file. The path is written as prefix + name when the
    // pieces are given separately, so "schemas/<scheme>/" never needs joining.
    fn file(self: *TarWriter, parts: []const []const u8, data: []const u8) void {
        var header = [_]u8{0} ** 512;
        var n: usize = 0;
        for (parts) |part| {
            if (n + part.len > 100) @trap();
            @memcpy(header[n..][0..part.len], part);
            n += part.len;
        }
        octal(header[100..108], 0o644);
        octal(header[108..116], 0);
        octal(header[116..124], 0);
        octal(header[124..136], data.len);
        octal(header[136..148], 0);
        header[156] = '0';
        @memcpy(header[257..263], "ustar\x00");
        @memcpy(header[263..265], "00");
        @memset(header[148..156], ' ');
        var sum: usize = 0;
        for (header) |b| sum += b;
        octal(header[148..155], sum);
        header[155] = ' ';
        self.put(&header);
        self.put(data);
        self.zeros((512 - data.len % 512) % 512);
    }
};

fn buildTar(remotes: []const Remote, schema: []const u8, instance: []const u8) usize {
    var w = TarWriter{};
    w.file(&.{"schema.json"}, schema);
    w.file(&.{"instance.json"}, instance);
    for (remotes) |remote| {
        // http://host/path becomes schemas/http/host/path.
        const sep = indexOf(remote.uri, "://") orelse @trap();
        w.file(&.{ "schemas/", remote.uri[0..sep], "/", remote.uri[sep + 3 ..] }, remote.json);
    }
    w.zeros(1024);
    return w.len;
}

export fn comply() i32 {
    var lines = Lines{ .text = FIXTURE };
    const header = lines.next() orelse @trap();
    if (!startsWith(header, "cases ")) @trap();
    const expected_cases = parseCount(header["cases ".len..]);

    var remotes: [MAX_REMOTES]Remote = undefined;
    var remote_count: usize = 0;
    var schema: ?[]const u8 = null;
    var ordinal: u64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (startsWith(line, "group ")) {
            remote_count = 0;
            schema = null;
        } else if (startsWith(line, "remote ")) {
            if (remote_count == MAX_REMOTES) @trap();
            remotes[remote_count] = .{ .uri = line["remote ".len..], .json = lines.json() };
            remote_count += 1;
        } else if (startsWith(line, "schema") and line.len == "schema".len) {
            schema = lines.json();
        } else if (startsWith(line, "valid ")) {
            const instance = lines.json();
            const len = buildTar(remotes[0..remote_count], schema orelse @trap(), instance);
            _ = must_render_exactly(
                ordinal,
                @intCast(@intFromPtr(&tar_buf)),
                @intCast(len),
                @intCast(@intFromPtr(instance.ptr)),
                @intCast(instance.len),
            );
            ordinal += 1;
        } else if (startsWith(line, "invalid ")) {
            const instance = lines.json();
            const len = buildTar(remotes[0..remote_count], schema orelse @trap(), instance);
            _ = must_reject(ordinal, @intCast(@intFromPtr(&tar_buf)), @intCast(len));
            ordinal += 1;
        } else @trap();
    }
    if (ordinal != expected_cases) @trap();
    return @intCast(ordinal);
}
