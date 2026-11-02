// JSON-Schema-Test-Suite, draft 2020-12 core tests (no optional/), as a
// Compliance oracle for validators that take the JSON envelope of
// application/json/json-schema-2020-12-must-be-valid.wasm:
//
//   {"schemas": {"<uri>": <remote>, ...}, "schema": <schema>, "instance": <instance>}
//
// The cases come from json-schema-2020-12.fixtures.txt, flattened from the
// vendored suite in json-schema-test-suite/ by
// tools/gen-json-schema-2020-12-fixtures.mjs. A valid instance must render
// exactly its own bytes; an invalid instance must be rejected (not trapped).
//
// The fixture already holds every value as minified JSON, so this is a
// generated oracle: it reads the fixture with a few mechanical line rules and
// joins each case's envelope into its own buffer, with "instance" last. It declares
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

var envelope_buf: [64 * 1024]u8 = undefined;

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

fn parseCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c < '0' or c > '9') @trap();
        n = n * 10 + (c - '0');
    }
    return n;
}

const EnvelopeWriter = struct {
    len: usize = 0,

    fn put(self: *EnvelopeWriter, bytes: []const u8) void {
        if (self.len + bytes.len > envelope_buf.len) @trap();
        @memcpy(envelope_buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

fn buildEnvelope(remotes: []const Remote, schema: []const u8, instance: []const u8) usize {
    var w = EnvelopeWriter{};
    w.put("{");
    if (remotes.len > 0) {
        w.put("\"schemas\":{");
        for (remotes, 0..) |remote, i| {
            // The suite's remote URIs need no JSON escaping; trap if one would.
            for (remote.uri) |c| {
                if (c < 0x20 or c == '"' or c == '\\') @trap();
            }
            if (i > 0) w.put(",");
            w.put("\"");
            w.put(remote.uri);
            w.put("\":");
            w.put(remote.json);
        }
        w.put("},");
    }
    w.put("\"schema\":");
    w.put(schema);
    w.put(",\"instance\":");
    w.put(instance);
    w.put("}");
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
            const len = buildEnvelope(remotes[0..remote_count], schema orelse @trap(), instance);
            _ = must_render_exactly(
                ordinal,
                @intCast(@intFromPtr(&envelope_buf)),
                @intCast(len),
                @intCast(@intFromPtr(instance.ptr)),
                @intCast(instance.len),
            );
            ordinal += 1;
        } else if (startsWith(line, "invalid ")) {
            const instance = lines.json();
            const len = buildEnvelope(remotes[0..remote_count], schema orelse @trap(), instance);
            _ = must_reject(ordinal, @intCast(@intFromPtr(&envelope_buf)), @intCast(len));
            ordinal += 1;
        } else @trap();
    }
    if (ordinal != expected_cases) @trap();
    return @intCast(ordinal);
}
