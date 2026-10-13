//! Builds an RFC 1035 DNS query message (`application/dns-message`) from one
//! question in master-file presentation form:
//!
//!     www.example.com. IN A
//!
//! The name comes first. A class and a type may follow in either order. The
//! class defaults to IN and the type defaults to A, so `www.example.com AAAA`
//! (dig's argument order) and `www.example.com` are also accepted. Every name
//! is treated as absolute, so the trailing dot is optional. Mnemonics are case
//! insensitive, and the RFC 3597 `TYPEnnn` and `CLASSnnn` forms select any
//! code. Names accept the RFC 1035 `\X` and `\DDD` escapes. A final line break
//! and surrounding spaces or tabs are allowed.
//!
//! Uniforms:
//!
//! - `id`: the 16-bit message ID. Default 0, which RFC 8484 recommends for
//!   DNS over HTTPS so that HTTP caches can share responses.
//! - `recursion_desired`: 1 sets the RD flag (default), 0 clears it.
//! - `dnssec_ok`: 1 adds an RFC 6891 OPT record with the DO flag, which asks
//!   the server to include DNSSEC records. Default 0, which sends no OPT
//!   record.
//!
//! Rejected input reports the byte offset of the token or byte that failed:
//! an empty name or label, a label over 63 bytes, a name over 255 wire bytes,
//! a bad escape, an unknown class or type, a repeated class or type, a fourth
//! token, or text after the line break.

const dns = @import("lib/dns.zig");

const INPUT_CONTENT_TYPE = "text/plain";
const OUTPUT_CONTENT_TYPE = "application/dns-message";

const INPUT_CAP: usize = 4096;
const HEADER_SIZE: usize = 12;
const NAME_WIRE_CAP: usize = 255;
const LABEL_CAP: usize = 63;
const QUESTION_TAIL_SIZE: usize = 4;
// Root name, type, class, TTL, and RDLENGTH.
const OPT_RECORD_SIZE: usize = 11;
// RFC 9715 recommends 1232 bytes to avoid IP fragmentation.
const EDNS_UDP_PAYLOAD_SIZE: u16 = 1232;
const OUTPUT_CAP: usize = HEADER_SIZE + NAME_WIRE_CAP + QUESTION_TAIL_SIZE + OPT_RECORD_SIZE;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var message_id: u16 = 0;
var recursion_desired: u1 = 1;
var dnssec_ok: u1 = 0;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

export fn uniform_set_id(value: u32) u32 {
    message_id = @intCast(@min(value, 0xffff));
    return message_id;
}

export fn uniform_set_recursion_desired(value: u32) u32 {
    recursion_desired = @intFromBool(value != 0);
    return recursion_desired;
}

export fn uniform_set_dnssec_ok(value: u32) u32 {
    dnssec_ok = @intFromBool(value != 0);
    return dnssec_ok;
}

// The offset of the first rejected input byte.
var failure_offset: usize = 0;
const Rejected = error{Rejected};

fn reject(offset: usize) Rejected {
    failure_offset = offset;
    return error.Rejected;
}

const Token = struct { start: usize, end: usize };
const TOKEN_CAP: usize = 3;

fn isBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isLineBreak(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

// Splits the single input line into at most three tokens. A backslash keeps
// the next byte inside the token, so an escaped space stays in a name.
noinline fn tokenize(input: []const u8, tokens: *[TOKEN_CAP]Token) Rejected!usize {
    var count: usize = 0;
    var in_token = false;
    var escaped = false;
    var after_line = false;
    for (input, 0..) |byte, offset| {
        if (after_line) {
            if (!isBlank(byte) and !isLineBreak(byte)) return reject(offset);
        } else if (escaped) {
            escaped = false;
        } else if (isBlank(byte) or isLineBreak(byte)) {
            if (in_token) {
                tokens[count - 1].end = offset;
                in_token = false;
            }
            after_line = isLineBreak(byte);
        } else if (!in_token) {
            if (count == TOKEN_CAP) return reject(offset);
            tokens[count] = .{ .start = offset, .end = input.len };
            count += 1;
            in_token = true;
            escaped = byte == '\\';
        } else {
            escaped = byte == '\\';
        }
    }
    if (count == 0) return reject(input.len);
    return count;
}

// Writes a name one presentation byte at a time.
const NameWriter = struct {
    out: *dns.Output,
    name_start: usize,
    label_start: usize,
    // 0: plain text, 1: after a backslash, 2 and 3: after one or two digits.
    state: u2 = 0,
    escape_offset: usize = 0,
    value: u16 = 0,

    fn labelByte(self: *NameWriter, byte: u8, offset: usize) Rejected!void {
        if (self.out.len - self.label_start > LABEL_CAP) return reject(offset);
        // Leave room for the root label.
        if (self.out.len - self.name_start >= NAME_WIRE_CAP - 1) return reject(offset);
        self.out.byte(byte);
    }

    fn endLabel(self: *NameWriter, offset: usize) Rejected!void {
        const size = self.out.len - self.label_start - 1;
        if (size == 0) return reject(offset);
        self.out.buf[self.label_start] = @intCast(size);
        // labelByte keeps the name at 254 bytes or fewer, so the next length
        // byte, or the root label, still fits.
        self.label_start = self.out.len;
        self.out.byte(0);
    }

    // Kept out of line so that the calling loop is a plain counter loop.
    noinline fn step(self: *NameWriter, byte: u8, offset: usize) Rejected!void {
        switch (self.state) {
            0 => if (byte == '\\') {
                self.state = 1;
                self.escape_offset = offset;
            } else if (byte == '.') {
                try self.endLabel(offset);
            } else {
                try self.labelByte(byte, offset);
            },
            1 => if (isDigit(byte)) {
                self.value = byte - '0';
                self.state = 2;
            } else {
                try self.labelByte(byte, offset);
                self.state = 0;
            },
            2 => {
                if (!isDigit(byte)) return reject(self.escape_offset);
                self.value = self.value * 10 + (byte - '0');
                self.state = 3;
            },
            3 => {
                if (!isDigit(byte)) return reject(self.escape_offset);
                self.value = self.value * 10 + (byte - '0');
                if (self.value > 0xff) return reject(self.escape_offset);
                try self.labelByte(@intCast(self.value), self.escape_offset);
                self.state = 0;
            },
        }
    }
};

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

// Writes the wire form of the name in `input[token.start..token.end]`.
noinline fn writeName(input: []const u8, token: Token, out: *dns.Output) Rejected!void {
    const text = input[token.start..token.end];
    if (text.len == 1 and text[0] == '.') {
        out.byte(0);
        return;
    }

    var writer: NameWriter = .{ .out = out, .name_start = out.len, .label_start = out.len };
    out.byte(0);
    for (text, token.start..) |byte, offset| try writer.step(byte, offset);
    if (writer.state != 0) return reject(writer.escape_offset);

    if (out.len - writer.label_start == 1) {
        // A trailing dot left an empty label, which becomes the root label.
        if (writer.label_start == writer.name_start) return reject(token.start);
    } else {
        try writer.endLabel(token.end);
    }
}

noinline fn classOrType(input: []const u8, token: Token, qclass: *?u16, qtype: *?u16) Rejected!void {
    const text = input[token.start..token.end];
    if (dns.parseMnemonic(&dns.classes, "CLASS", text)) |code| {
        if (qclass.* != null) return reject(token.start);
        qclass.* = code;
    } else if (dns.parseMnemonic(&dns.types, "TYPE", text)) |code| {
        if (qtype.* != null) return reject(token.start);
        qtype.* = code;
    } else {
        return reject(token.start);
    }
}

fn encode(input: []const u8) Rejected!usize {
    var tokens: [TOKEN_CAP]Token = undefined;
    const token_count = try tokenize(input, &tokens);

    var qclass: ?u16 = null;
    var qtype: ?u16 = null;
    inline for (1..TOKEN_CAP) |k| {
        if (k < token_count) try classOrType(input, tokens[k], &qclass, &qtype);
    }

    var out: dns.Output = .{ .buf = &output_buf };
    out.u16be(message_id);
    out.u16be(@as(u16, recursion_desired) << 8);
    out.u16be(1); // QDCOUNT
    out.u16be(0); // ANCOUNT
    out.u16be(0); // NSCOUNT
    out.u16be(dnssec_ok); // ARCOUNT
    try writeName(input, tokens[0], &out);
    out.u16be(qtype orelse dns.TYPE_A);
    out.u16be(qclass orelse dns.CLASS_IN);

    if (dnssec_ok == 1) {
        out.byte(0);
        out.u16be(dns.TYPE_OPT);
        out.u16be(EDNS_UDP_PAYLOAD_SIZE);
        // Extended RCODE 0, version 0, then the flags with DO set.
        out.u16be(0);
        out.u16be(0x8000);
        out.u16be(0);
    }
    return out.len;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    const size = encode(input_buf[0..input_size]) catch return .{
        .output_size_or_failure = @intCast(failure_offset),
        .output_ptr = 0,
        .failed = 1,
    };
    if (size > OUTPUT_CAP) @trap();
    return .{
        .output_size_or_failure = @intCast(size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

const std = @import("std");

fn expectEncoded(input: []const u8, expected: []const u8) !void {
    const size = try encode(input);
    try std.testing.expectEqualSlices(u8, expected, output_buf[0..size]);
}

fn expectRejected(input: []const u8, offset: usize) !void {
    try std.testing.expectError(error.Rejected, encode(input));
    try std.testing.expectEqual(offset, failure_offset);
}

const www_example_com_a = "\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
    "\x03www\x07example\x03com\x00\x00\x01\x00\x01";

test "presentation and dig forms give the same query" {
    try expectEncoded("www.example.com. IN A\n", www_example_com_a);
    try expectEncoded("www.example.com A", www_example_com_a);
    try expectEncoded("  www.example.com\t a in \r\n", www_example_com_a);
    try expectEncoded("www.example.com", www_example_com_a);
}

test "generic forms, root name, and escapes" {
    try expectEncoded(". TYPE2 CLASS3", "\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03");
    try expectEncoded("a\\.b\\032c.d HTTPS", "\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x05a.b c\x01d\x00\x00\x41\x00\x01");
}

test "label and name limits" {
    const label63 = "a" ** 63;
    try expectEncoded(label63, "\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x3f" ++ label63 ++ "\x00\x00\x01\x00\x01");
    try expectRejected("a" ** 64, 63);
    // Four labels of 63 bytes need 257 wire bytes.
    const long = (label63 ++ ".") ** 3 ++ "a" ** 61;
    _ = try encode(long);
    try expectRejected(long ++ "a", long.len);
}

test "rejections report offsets" {
    try expectRejected("", 0);
    try expectRejected("a..b A", 2);
    try expectRejected(".. A", 0);
    try expectRejected("a A A", 4);
    try expectRejected("a A IN CH", 7);
    try expectRejected("a BOGUS", 2);
    try expectRejected("a\\25x A", 1);
    try expectRejected("a\\256 A", 1);
    try expectRejected("a A\nb A", 4);
}

test "uniforms set the ID, RD, and DO" {
    _ = uniform_set_id(0x1_0000);
    try std.testing.expectEqual(@as(u16, 0xffff), message_id);
    _ = uniform_set_id(0xabcd);
    _ = uniform_set_recursion_desired(0);
    _ = uniform_set_dnssec_ok(7);
    defer {
        _ = uniform_set_id(0);
        _ = uniform_set_recursion_desired(1);
        _ = uniform_set_dnssec_ok(0);
    }
    try expectEncoded("example.com", "\xab\xcd\x00\x00\x00\x01\x00\x00\x00\x00\x00\x01" ++
        "\x07example\x03com\x00\x00\x01\x00\x01" ++
        "\x00\x00\x29\x04\xd0\x00\x00\x80\x00\x00\x00");
}
