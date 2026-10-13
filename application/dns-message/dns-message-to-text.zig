//! Decodes an RFC 1035 DNS message (`application/dns-message`) into the text
//! layout that dig prints. Records use RFC 1035 master-file presentation
//! format, one per line, with tabs between the fields:
//!
//!     ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 0
//!     ;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
//!
//!     ;; QUESTION SECTION:
//!     ;www.example.com.  IN  A
//!
//!     ;; ANSWER SECTION:
//!     www.example.com.  300  IN  A  93.184.215.14
//!
//! An RFC 6891 OPT record is shown as an `OPT PSEUDOSECTION` before the
//! question, and its extended RCODE is part of `status`. RDATA has a type
//! specific form for common, DNSSEC, and RFC 9460 SVCB/HTTPS records, and the
//! RFC 3597 `\# length hex` form for other types.
//!
//! Names are decompressed with fixed limits. A compression pointer must point
//! to an earlier byte than the pointer itself, a name has at most 255 wire
//! bytes, and one name follows at most NAME_STEP_CAP labels and pointers.
//! Every loop in a name therefore ends.
//!
//! Rejected input reports the byte offset of the field that failed:
//!
//! - a header, record, or field that does not fit the message;
//! - a bad label type, a forward or self pointer, or a name over 255 bytes;
//! - RDATA that does not match its type, or does not use all of RDLENGTH;
//! - an OPT record outside the additional section, with a non-root name, or
//!   after another OPT record; and
//! - any byte after the last record.

const dns = @import("lib/dns.zig");

const INPUT_CONTENT_TYPE = "application/dns-message";
const OUTPUT_CONTENT_TYPE = "text/plain";

// A DNS message over TCP or HTTPS has a 16-bit length.
const INPUT_CAP: usize = 65535;
const HEADER_SIZE: usize = 12;
const NAME_WIRE_CAP: usize = 255;
const NAME_STEP_CAP: usize = 255;

// The header lines and section titles have a fixed size.
const PREAMBLE_CAP: usize = 1024;
// A 2-byte compression pointer gives the largest expansion. It can stand for
// a full 255-byte name, and each label byte can print as a 4-byte `\DDD`
// escape, for at most 4 * 253 + 1 bytes. Every other field prints at most 88
// bytes per input byte: an NSEC type bitmap byte with eight bits set prints
// eight " NSEC3PARAM" mnemonics.
const NAME_TEXT_CAP: usize = 4 * (NAME_WIRE_CAP - 2) + 1;
const MAX_EXPANSION: usize = 512;
const OUTPUT_CAP: usize = PREAMBLE_CAP + MAX_EXPANSION * INPUT_CAP;

comptime {
    if (NAME_TEXT_CAP > 2 * MAX_EXPANSION) @compileError("names can exceed MAX_EXPANSION");
    if (OUTPUT_CAP > 0x7fff_ffff) @compileError("OUTPUT_CAP does not fit the ABI");
}

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_utf8_cap() u32 {
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

var failure_offset: usize = 0;
const Rejected = error{Rejected};

fn reject(offset: usize) Rejected {
    failure_offset = offset;
    return error.Rejected;
}

const Output = dns.Output;
const readU16 = dns.readU16;
const readU32 = dns.readU32;

const opcodes = [_]dns.Mnemonic{
    .{ .code = 0, .name = "QUERY" },
    .{ .code = 1, .name = "IQUERY" },
    .{ .code = 2, .name = "STATUS" },
    .{ .code = 4, .name = "NOTIFY" },
    .{ .code = 5, .name = "UPDATE" },
    .{ .code = 6, .name = "DSO" },
};

const rcodes = [_]dns.Mnemonic{
    .{ .code = 0, .name = "NOERROR" },
    .{ .code = 1, .name = "FORMERR" },
    .{ .code = 2, .name = "SERVFAIL" },
    .{ .code = 3, .name = "NXDOMAIN" },
    .{ .code = 4, .name = "NOTIMP" },
    .{ .code = 5, .name = "REFUSED" },
    .{ .code = 6, .name = "YXDOMAIN" },
    .{ .code = 7, .name = "YXRRSET" },
    .{ .code = 8, .name = "NXRRSET" },
    .{ .code = 9, .name = "NOTAUTH" },
    .{ .code = 10, .name = "NOTZONE" },
    .{ .code = 11, .name = "DSOTYPENI" },
    .{ .code = 16, .name = "BADVERS" },
    .{ .code = 23, .name = "BADCOOKIE" },
};

const header_flags = [_]struct { mask: u16, name: []const u8 }{
    .{ .mask = 0x8000, .name = "qr" },
    .{ .mask = 0x0400, .name = "aa" },
    .{ .mask = 0x0200, .name = "tc" },
    .{ .mask = 0x0100, .name = "rd" },
    .{ .mask = 0x0080, .name = "ra" },
    .{ .mask = 0x0020, .name = "ad" },
    .{ .mask = 0x0010, .name = "cd" },
};

// RFC 9460 SvcParamKeys.
const svc_keys = [_]dns.Mnemonic{
    .{ .code = 0, .name = "mandatory" },
    .{ .code = 1, .name = "alpn" },
    .{ .code = 2, .name = "no-default-alpn" },
    .{ .code = 3, .name = "port" },
    .{ .code = 4, .name = "ipv4hint" },
    .{ .code = 5, .name = "ech" },
    .{ .code = 6, .name = "ipv6hint" },
    .{ .code = 7, .name = "dohpath" },
    .{ .code = 8, .name = "ohttp" },
    .{ .code = 9, .name = "tls-supported-groups" },
};

// RFC 8914 Extended DNS Error codes.
const ede_codes = [_]dns.Mnemonic{
    .{ .code = 0, .name = "Other Error" },
    .{ .code = 1, .name = "Unsupported DNSKEY Algorithm" },
    .{ .code = 2, .name = "Unsupported DS Digest Type" },
    .{ .code = 3, .name = "Stale Answer" },
    .{ .code = 4, .name = "Forged Answer" },
    .{ .code = 5, .name = "DNSSEC Indeterminate" },
    .{ .code = 6, .name = "DNSSEC Bogus" },
    .{ .code = 7, .name = "Signature Expired" },
    .{ .code = 8, .name = "Signature Not Yet Valid" },
    .{ .code = 9, .name = "DNSKEY Missing" },
    .{ .code = 10, .name = "RRSIGs Missing" },
    .{ .code = 11, .name = "No Zone Key Bit Set" },
    .{ .code = 12, .name = "NSEC Missing" },
    .{ .code = 13, .name = "Cached Error" },
    .{ .code = 14, .name = "Not Ready" },
    .{ .code = 15, .name = "Blocked" },
    .{ .code = 16, .name = "Censored" },
    .{ .code = 17, .name = "Filtered" },
    .{ .code = 18, .name = "Prohibited" },
    .{ .code = 19, .name = "Stale NXDomain Answer" },
    .{ .code = 20, .name = "Not Authoritative" },
    .{ .code = 21, .name = "Not Supported" },
    .{ .code = 22, .name = "No Reachable Authority" },
    .{ .code = 23, .name = "Network Error" },
    .{ .code = 24, .name = "Invalid Data" },
    .{ .code = 25, .name = "Signature Expired before Valid" },
    .{ .code = 26, .name = "Too Early" },
    .{ .code = 27, .name = "Unsupported NSEC3 Iterations Value" },
    .{ .code = 28, .name = "Unable to conform to policy" },
    .{ .code = 29, .name = "Synthesized" },
};

// Text helpers.

const upper_hex = "0123456789ABCDEF";
const lower_hex = "0123456789abcdef";

fn hex(out: *Output, bytes: []const u8) void {
    for (bytes) |byte| {
        out.byte(upper_hex[byte >> 4]);
        out.byte(upper_hex[byte & 0xf]);
    }
}

fn escapeDecimal(out: *Output, byte: u8) void {
    out.byte('\\');
    out.byte('0' + byte / 100);
    out.byte('0' + byte / 10 % 10);
    out.byte('0' + byte % 10);
}

// Writes one label with RFC 1035 escapes for bytes that end or delimit a
// name in master-file text.
fn labelText(out: *Output, label: []const u8) void {
    for (label) |byte| {
        switch (byte) {
            '.', '\\', '"', '(', ')', ';', '@', '$' => {
                out.byte('\\');
                out.byte(byte);
            },
            else => if (byte > 0x20 and byte < 0x7f) out.byte(byte) else escapeDecimal(out, byte),
        }
    }
}

// Writes the inside of a quoted character-string.
fn quotedText(out: *Output, bytes: []const u8) void {
    quotedTextItem(out, bytes, false);
}

// With `list_item`, also escapes the commas and backslashes of an RFC 9460
// value-list item. The quoted string then escapes that backslash again.
noinline fn quotedTextItem(out: *Output, bytes: []const u8, comptime list_item: bool) void {
    for (bytes) |byte| {
        if (list_item and (byte == ',' or byte == '\\')) out.bytes("\\\\");
        switch (byte) {
            '"', '\\' => {
                out.byte('\\');
                out.byte(byte);
            },
            else => if (byte >= 0x20 and byte < 0x7f) out.byte(byte) else escapeDecimal(out, byte),
        }
    }
}

fn quoted(out: *Output, bytes: []const u8) void {
    out.byte('"');
    quotedText(out, bytes);
    out.byte('"');
}

fn base64(out: *Output, bytes: []const u8) void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var i: usize = 0;
    while (i < bytes.len) : (i += 3) {
        const left = bytes.len - i;
        const b0: u32 = bytes[i];
        const b1: u32 = if (left > 1) bytes[i + 1] else 0;
        const b2: u32 = if (left > 2) bytes[i + 2] else 0;
        const group = b0 << 16 | b1 << 8 | b2;
        out.byte(alphabet[group >> 18]);
        out.byte(alphabet[group >> 12 & 63]);
        out.byte(if (left > 1) alphabet[group >> 6 & 63] else '=');
        out.byte(if (left > 2) alphabet[group & 63] else '=');
    }
}

// RFC 4648 base32hex without padding, as NSEC3 uses for hashed owner names.
fn base32hex(out: *Output, bytes: []const u8) void {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUV";
    var acc: u32 = 0;
    var bits: u32 = 0;
    for (bytes) |byte| {
        acc = (acc << 8 | byte) & 0xfff;
        bits += 8;
        while (bits >= 5) : (bits -= 5) {
            out.byte(alphabet[acc >> @intCast(bits - 5) & 31]);
        }
    }
    if (bits > 0) out.byte(alphabet[acc << @intCast(5 - bits) & 31]);
}

fn ipv4(out: *Output, bytes: []const u8) void {
    for (bytes, 0..) |byte, i| {
        if (i > 0) out.byte('.');
        out.decimal(byte);
    }
}

// RFC 5952 text: lowercase, no leading zeros, and the first longest run of
// two or more zero groups shortened to "::".
fn ipv6(out: *Output, bytes: *const [16]u8) void {
    var groups: [8]u16 = undefined;
    inline for (&groups, 0..) |*group, i| group.* = readU16(bytes, 2 * i);

    var best_start: usize = 8;
    var best_len: usize = 1;
    var run_start: usize = 0;
    var run_len: usize = 0;
    inline for (groups, 0..) |group, i| {
        if (group == 0) {
            if (run_len == 0) run_start = i;
            run_len += 1;
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
        } else {
            run_len = 0;
        }
    }

    inline for (groups, 0..) |group, i| {
        if (i >= best_start and i < best_start + best_len) {
            if (i == best_start) out.bytes("::");
        } else {
            if (i > 0 and i != best_start + best_len) out.byte(':');
            ipv6Group(out, group);
        }
    }
}

fn ipv6Group(out: *Output, group: u16) void {
    var started = false;
    inline for (0..4) |k| {
        const digit: u4 = @truncate(group >> (12 - 4 * k));
        if (digit != 0 or started or k == 3) {
            out.byte(lower_hex[digit]);
            started = true;
        }
    }
}

// Writes seconds since 1970 as YYYYMMDDHHmmSS, the RRSIG time form.
fn timestamp(out: *Output, seconds: u32) void {
    const days = seconds / 86400;
    const day_seconds = seconds % 86400;
    // Howard Hinnant's civil_from_days, for days on or after 1970-01-01.
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = doy - (153 * mp + 2) / 5 + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    out.decimal(year);
    twoDigits(out, month);
    twoDigits(out, day);
    twoDigits(out, day_seconds / 3600);
    twoDigits(out, day_seconds / 60 % 60);
    twoDigits(out, day_seconds % 60);
}

fn twoDigits(out: *Output, value: u32) void {
    out.byte('0' + @as(u8, @intCast(value / 10)));
    out.byte('0' + @as(u8, @intCast(value % 10)));
}

// Message reading.

// Writes the name at `pos` and returns the offset after its in-place bytes.
// `limit` bounds those in-place bytes; a pointer may reach any earlier byte.
fn name(m: []const u8, pos: usize, limit: usize, out: *Output) Rejected!usize {
    var cursor = pos;
    var end: ?usize = null;
    var wire: usize = 1;
    var steps: usize = 0;
    while (steps < NAME_STEP_CAP) : (steps += 1) {
        const bound = if (end == null) limit else m.len;
        if (cursor >= bound) return reject(cursor);
        const length = m[cursor];
        switch (length >> 6) {
            0 => {
                if (length == 0) {
                    if (wire == 1) out.byte('.');
                    return end orelse cursor + 1;
                }
                if (length > bound - cursor - 1) return reject(cursor);
                wire += 1 + @as(usize, length);
                if (wire > NAME_WIRE_CAP) return reject(cursor);
                labelText(out, m[cursor + 1 ..][0..length]);
                out.byte('.');
                cursor += 1 + @as(usize, length);
            },
            3 => {
                if (bound - cursor < 2) return reject(cursor);
                const target = @as(usize, readU16(m, cursor) & 0x3fff);
                if (target >= cursor) return reject(cursor);
                if (end == null) end = cursor + 2;
                cursor = target;
            },
            else => return reject(cursor),
        }
    }
    return reject(pos);
}

// A bounded reader over one RDATA or option field.
const Field = struct {
    m: []const u8,
    pos: usize,
    end: usize,

    fn remaining(self: *const Field) usize {
        return self.end - self.pos;
    }

    fn take(self: *Field, size: usize) Rejected![]const u8 {
        if (size > self.remaining()) return reject(self.pos);
        const bytes = self.m[self.pos..][0..size];
        self.pos += size;
        return bytes;
    }

    fn rest(self: *Field) []const u8 {
        const bytes = self.m[self.pos..self.end];
        self.pos = self.end;
        return bytes;
    }

    // The rest of the field, which must not be empty.
    fn restNonEmpty(self: *Field) Rejected![]const u8 {
        if (self.pos == self.end) return reject(self.pos);
        return self.rest();
    }

    fn u8_(self: *Field) Rejected!u8 {
        return (try self.take(1))[0];
    }

    fn u16_(self: *Field) Rejected!u16 {
        return readU16(try self.take(2), 0);
    }

    fn u32_(self: *Field) Rejected!u32 {
        return readU32(try self.take(4), 0);
    }

    fn string(self: *Field) Rejected![]const u8 {
        const size = try self.u8_();
        return self.take(size);
    }

    fn string16(self: *Field) Rejected![]const u8 {
        const size = try self.u16_();
        return self.take(size);
    }

    fn done(self: *const Field) Rejected!void {
        if (self.pos != self.end) return reject(self.pos);
    }
};

fn decimalField(field: *Field, out: *Output, size: u8) Rejected!void {
    const value: u32 = switch (size) {
        1 => try field.u8_(),
        2 => try field.u16_(),
        else => try field.u32_(),
    };
    out.decimal(value);
    out.byte(' ');
}

fn nameField(field: *Field, out: *Output) Rejected!void {
    field.pos = try name(field.m, field.pos, field.end, out);
}

// Writes an RFC 4034 type bitmap, each type preceded by a space.
fn typeBitmap(field: *Field, out: *Output) Rejected!void {
    var next_window: u16 = 0;
    var windows: usize = 0;
    while (windows < 256 and field.remaining() > 0) : (windows += 1) {
        const window_offset = field.pos;
        const window = try field.u8_();
        if (window < next_window) return reject(window_offset);
        const size = try field.u8_();
        if (size == 0 or size > 32) return reject(field.pos - 1);
        const bitmap = try field.take(size);
        for (bitmap, 0..) |byte, i| {
            for (0..8) |bit| {
                if (byte & (@as(u8, 0x80) >> @intCast(bit)) == 0) continue;
                out.byte(' ');
                out.mnemonic(&dns.types, "TYPE", @intCast(@as(usize, window) * 256 + i * 8 + bit));
            }
        }
        next_window = @as(u16, window) + 1;
    }
    try field.done();
}

fn svcKey(out: *Output, key: u16) void {
    out.mnemonic(&svc_keys, "key", key);
}

fn addressList(out: *Output, value: []const u8, comptime size: usize, offset: usize) Rejected!void {
    if (value.len == 0 or value.len % size != 0) return reject(offset);
    var i: usize = 0;
    while (i < value.len) : (i += size) {
        if (i > 0) out.byte(',');
        if (size == 4) ipv4(out, value[i..][0..4]) else ipv6(out, value[i..][0..16]);
    }
}

// Writes RFC 9460 SvcParams, each preceded by a space.
fn svcParams(field: *Field, out: *Output) Rejected!void {
    var next_key: u32 = 0;
    // Each parameter takes at least 4 bytes, so the budget is never reached.
    const limit: usize = INPUT_CAP / 4;
    var n: usize = 0;
    while (n < limit and field.remaining() > 0) : (n += 1) try svcParam(field, out, &next_key);
    try field.done();
}

noinline fn svcParam(field: *Field, out: *Output, next_key: *u32) Rejected!void {
    {
        const key_offset = field.pos;
        const key = try field.u16_();
        if (key < next_key.*) return reject(key_offset);
        next_key.* = @as(u32, key) + 1;
        const value_offset = field.pos + 2;
        const value = try field.string16();
        out.byte(' ');
        svcKey(out, key);
        switch (key) {
            0, 9 => {
                if (value.len == 0 or value.len % 2 != 0) return reject(value_offset);
                out.byte('=');
                var i: usize = 0;
                while (i < value.len) : (i += 2) {
                    if (i > 0) out.byte(',');
                    const item = readU16(value, i);
                    if (key == 0) svcKey(out, item) else out.decimal(item);
                }
            },
            1 => {
                if (value.len == 0) return reject(value_offset);
                out.bytes("=\"");
                var ids: Field = .{ .m = field.m, .pos = value_offset, .end = value_offset + value.len };
                // Each ID takes at least 2 bytes.
                const limit: usize = INPUT_CAP / 2;
                var n: usize = 0;
                while (n < limit and ids.remaining() > 0) : (n += 1) {
                    try alpnId(&ids, out, ids.pos == value_offset);
                }
                try ids.done();
                out.byte('"');
            },
            2, 8 => if (value.len != 0) return reject(value_offset),
            3 => {
                if (value.len != 2) return reject(value_offset);
                out.byte('=');
                out.decimal(readU16(value, 0));
            },
            4 => {
                out.byte('=');
                try addressList(out, value, 4, value_offset);
            },
            5 => {
                out.byte('=');
                base64(out, value);
            },
            6 => {
                out.byte('=');
                try addressList(out, value, 16, value_offset);
            },
            else => if (value.len > 0) {
                out.byte('=');
                quoted(out, value);
            },
        }
    }
}

noinline fn alpnId(ids: *Field, out: *Output, first: bool) Rejected!void {
    const id_offset = ids.pos;
    const id = try ids.string();
    if (id.len == 0) return reject(id_offset);
    if (!first) out.byte(',');
    quotedTextItem(out, id, true);
}

fn rdataText(m: []const u8, rtype: u16, class: u16, start: usize, end: usize, out: *Output) Rejected!void {
    var field: Field = .{ .m = m, .pos = start, .end = end };
    if (start == end) {
        out.bytes("\\# 0");
        return;
    }
    switch (rtype) {
        // A and AAAA
        1, 28 => {
            const size: usize = if (rtype == 1) 4 else 16;
            if (class != dns.CLASS_IN) return genericRdata(&field, out);
            const bytes = try field.take(size);
            if (size == 4) ipv4(out, bytes) else ipv6(out, bytes[0..16]);
        },
        // NS, CNAME, PTR, DNAME
        2, 5, 12, 39 => try nameField(&field, out),
        // MX, AFSDB, KX
        15, 18, 36 => {
            try decimalField(&field, out, 2);
            try nameField(&field, out);
        },
        // SOA
        6 => {
            try nameField(&field, out);
            out.byte(' ');
            try nameField(&field, out);
            inline for (0..5) |_| {
                out.byte(' ');
                out.decimal(try field.u32_());
            }
        },
        // RP
        17 => {
            try nameField(&field, out);
            out.byte(' ');
            try nameField(&field, out);
        },
        // TXT, SPF
        16, 99 => try characterStrings(&field, out),
        // HINFO
        13 => {
            quoted(out, try field.string());
            out.byte(' ');
            quoted(out, try field.string());
        },
        // SRV
        33 => {
            try decimalField(&field, out, 2);
            try decimalField(&field, out, 2);
            try decimalField(&field, out, 2);
            try nameField(&field, out);
        },
        // NAPTR
        35 => {
            try decimalField(&field, out, 2);
            try decimalField(&field, out, 2);
            inline for (0..3) |_| {
                quoted(out, try field.string());
                out.byte(' ');
            }
            try nameField(&field, out);
        },
        // DS, CDS
        43, 59 => {
            try decimalField(&field, out, 2);
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            hex(out, try field.restNonEmpty());
        },
        // DNSKEY, CDNSKEY
        48, 60 => {
            try decimalField(&field, out, 2);
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            base64(out, try field.restNonEmpty());
        },
        // RRSIG
        46 => {
            out.mnemonic(&dns.types, "TYPE", try field.u16_());
            out.byte(' ');
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 4);
            timestamp(out, try field.u32_());
            out.byte(' ');
            timestamp(out, try field.u32_());
            out.byte(' ');
            try decimalField(&field, out, 2);
            try nameField(&field, out);
            out.byte(' ');
            base64(out, try field.restNonEmpty());
        },
        // NSEC
        47 => {
            try nameField(&field, out);
            try typeBitmap(&field, out);
        },
        // NSEC3, NSEC3PARAM
        50, 51 => {
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 2);
            const salt = try field.string();
            if (salt.len == 0) out.byte('-') else hex(out, salt);
            if (rtype == 50) {
                out.byte(' ');
                const hash_offset = field.pos;
                const hash = try field.string();
                if (hash.len == 0) return reject(hash_offset);
                base32hex(out, hash);
                try typeBitmap(&field, out);
            }
        },
        // TLSA, SMIMEA
        52, 53 => {
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            hex(out, try field.restNonEmpty());
        },
        // SSHFP
        44 => {
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            hex(out, try field.restNonEmpty());
        },
        // OPENPGPKEY
        61 => base64(out, field.rest()),
        // ZONEMD
        63 => {
            try decimalField(&field, out, 4);
            try decimalField(&field, out, 1);
            try decimalField(&field, out, 1);
            hex(out, try field.restNonEmpty());
        },
        // SVCB, HTTPS
        64, 65 => {
            try decimalField(&field, out, 2);
            try nameField(&field, out);
            try svcParams(&field, out);
        },
        // URI
        256 => {
            try decimalField(&field, out, 2);
            try decimalField(&field, out, 2);
            quoted(out, field.rest());
        },
        // CAA
        257 => {
            try decimalField(&field, out, 1);
            const tag_offset = field.pos;
            const tag = try field.string();
            if (tag.len == 0) return reject(tag_offset);
            if (!isAlphanumeric(tag)) return reject(tag_offset);
            out.bytes(tag);
            out.byte(' ');
            quoted(out, field.rest());
        },
        else => return genericRdata(&field, out),
    }
    try field.done();
}

noinline fn isAlphanumeric(bytes: []const u8) bool {
    for (bytes) |byte| {
        const upper = byte & 0xdf;
        if ((byte < '0' or byte > '9') and (upper < 'A' or upper > 'Z')) return false;
    }
    return true;
}

noinline fn characterStrings(field: *Field, out: *Output) Rejected!void {
    const start = field.pos;
    // Each string takes at least 1 byte, so this budget is never reached.
    const limit = field.remaining();
    var n: usize = 0;
    while (n < limit and field.remaining() > 0) : (n += 1) {
        try characterString(field, out, field.pos == start);
    }
}

noinline fn characterString(field: *Field, out: *Output, first: bool) Rejected!void {
    if (!first) out.byte(' ');
    quoted(out, try field.string());
}

// RFC 3597 form for RDATA without a type-specific form.
fn genericRdata(field: *Field, out: *Output) void {
    out.bytes("\\# ");
    out.decimal(@intCast(field.remaining()));
    out.byte(' ');
    hex(out, field.rest());
}

fn ednsOptions(m: []const u8, start: usize, end: usize, out: *Output) Rejected!void {
    var field: Field = .{ .m = m, .pos = start, .end = end };
    // Each option takes at least 4 bytes.
    const limit: usize = INPUT_CAP / 4;
    var n: usize = 0;
    while (n < limit and field.remaining() > 0) : (n += 1) try ednsOption(&field, out);
    try field.done();
}

noinline fn ednsOption(field: *Field, out: *Output) Rejected!void {
    {
        const code = try field.u16_();
        const value_offset = field.pos + 2;
        const value = try field.string16();
        switch (code) {
            3 => {
                out.bytes("; NSID: ");
                hex(out, value);
                out.bytes(" (");
                quoted(out, value);
                out.byte(')');
            },
            8 => clientSubnet: {
                const family = if (value.len >= 4) readU16(value, 0) else 0;
                const size: usize = if (family == 1) 4 else 16;
                if ((family != 1 and family != 2) or value.len - 4 > size) {
                    out.bytes("; CLIENT-SUBNET: ");
                    hex(out, value);
                    break :clientSubnet;
                }
                var address = [_]u8{0} ** 16;
                @memcpy(address[0 .. value.len - 4], value[4..]);
                out.bytes("; CLIENT-SUBNET: ");
                if (family == 1) ipv4(out, address[0..4]) else ipv6(out, &address);
                out.byte('/');
                out.decimal(value[2]);
                out.byte('/');
                out.decimal(value[3]);
            },
            10 => {
                out.bytes("; COOKIE: ");
                hex(out, value);
            },
            11 => {
                out.bytes("; TCP-KEEPALIVE");
                if (value.len == 2) {
                    // The timeout is in units of 100 ms.
                    const tenths = readU16(value, 0);
                    out.bytes(": ");
                    out.decimal(tenths / 10);
                    out.byte('.');
                    out.decimal(tenths % 10);
                    out.bytes(" secs");
                } else if (value.len != 0) {
                    return reject(value_offset);
                }
            },
            12 => {
                out.bytes("; PADDING: (");
                out.decimal(@intCast(value.len));
                out.bytes(" bytes)");
            },
            15 => {
                if (value.len < 2) return reject(value_offset);
                const info = readU16(value, 0);
                out.bytes("; EDE: ");
                out.decimal(info);
                if (dns.nameOf(&ede_codes, info)) |label| {
                    out.bytes(" (");
                    out.bytes(label);
                    out.byte(')');
                }
                if (value.len > 2) {
                    out.bytes(": ");
                    quoted(out, value[2..]);
                }
            },
            else => {
                out.bytes("; OPTION ");
                out.decimal(code);
                out.bytes(": ");
                hex(out, value);
            },
        }
        out.byte('\n');
    }
}

// Skips a name without following pointers. Returns null when the name does
// not fit, so the decoding pass can report the exact offset.
fn skipName(m: []const u8, pos: usize) ?usize {
    var cursor = pos;
    var labels: usize = 0;
    while (labels < NAME_STEP_CAP) : (labels += 1) {
        if (cursor >= m.len) return null;
        const length = m[cursor];
        if (length == 0) return cursor + 1;
        if (length >= 0xc0) return if (m.len - cursor >= 2) cursor + 2 else null;
        if (length >= 0x40) return null;
        cursor += 1 + @as(usize, length);
    }
    return null;
}

// Finds the first OPT record in the additional section, so that the header
// can include its extended RCODE and its pseudosection can come first.
fn findOpt(m: []const u8) ?usize {
    var pos: usize = HEADER_SIZE;
    for (0..readU16(m, 4)) |_| {
        pos = skipName(m, pos) orelse return null;
        if (m.len - pos < 4) return null;
        pos += 4;
    }
    const answers = @as(usize, readU16(m, 6)) + readU16(m, 8);
    const records = answers + readU16(m, 10);
    for (0..records) |i| {
        const record_start = pos;
        pos = skipName(m, pos) orelse return null;
        if (m.len - pos < 10) return null;
        if (i >= answers and readU16(m, pos) == dns.TYPE_OPT) return record_start;
        const rdlength = readU16(m, pos + 8);
        pos += 10;
        if (m.len - pos < rdlength) return null;
        pos += rdlength;
    }
    return null;
}

fn writeOpt(m: []const u8, pos: usize, out: *Output) Rejected!void {
    // findOpt checked that the root name and the fixed fields fit.
    const fields = pos + 1;
    const flags = readU16(m, fields + 6);
    const rdlength = readU16(m, fields + 8);
    if (m.len - (fields + 10) < rdlength) return reject(fields + 8);
    out.bytes("\n;; OPT PSEUDOSECTION:\n; EDNS: version: ");
    out.decimal(m[fields + 5]);
    out.bytes(", flags:");
    if (flags & 0x8000 != 0) out.bytes(" do");
    if (flags & 0x7fff != 0) {
        out.bytes("; MBZ: 0x");
        inline for (0..4) |i| out.byte(lower_hex[flags >> (12 - 4 * i) & 0xf]);
        out.byte(',');
    } else {
        out.byte(';');
    }
    out.bytes(" udp: ");
    out.decimal(readU16(m, fields + 2));
    out.byte('\n');
    try ednsOptions(m, fields + 10, fields + 10 + rdlength, out);
}

noinline fn question(m: []const u8, pos: usize, out: *Output) Rejected!usize {
    out.byte(';');
    const end = try name(m, pos, m.len, out);
    if (m.len - end < 4) return reject(end);
    out.byte('\t');
    out.mnemonic(&dns.classes, "CLASS", readU16(m, end + 2));
    out.byte('\t');
    out.mnemonic(&dns.types, "TYPE", readU16(m, end));
    out.byte('\n');
    return end + 4;
}

const Section = enum { answer, authority, additional };

noinline fn record(m: []const u8, pos: usize, section: Section, opt: ?usize, out: *Output) Rejected!usize {
    const line_start = out.len;
    const fields = try name(m, pos, m.len, out);
    if (m.len - fields < 10) return reject(fields);
    const rtype = readU16(m, fields);
    const class = readU16(m, fields + 2);
    const rdlength = readU16(m, fields + 8);
    const rdata = fields + 10;
    if (m.len - rdata < rdlength) return reject(fields + 8);

    if (rtype == dns.TYPE_OPT) {
        if (section != .additional) return reject(fields);
        if (m[pos] != 0) return reject(pos);
        if (opt == null or opt.? != pos) return reject(fields);
        // The pseudosection was written before the question.
        out.len = line_start;
        return rdata + rdlength;
    }

    out.byte('\t');
    out.decimal(readU32(m, fields + 4));
    out.byte('\t');
    out.mnemonic(&dns.classes, "CLASS", class);
    out.byte('\t');
    out.mnemonic(&dns.types, "TYPE", rtype);
    out.byte('\t');
    try rdataText(m, rtype, class, rdata, rdata + rdlength, out);
    out.byte('\n');
    return rdata + rdlength;
}

fn sectionTitle(out: *Output, title: []const u8) void {
    out.bytes("\n;; ");
    out.bytes(title);
    out.bytes(" SECTION:\n");
}

fn decode(m: []const u8) Rejected!usize {
    if (m.len < HEADER_SIZE) return reject(m.len);
    var out: Output = .{ .buf = &output_buf };

    const flags = readU16(m, 2);
    const counts = [4]u16{ readU16(m, 4), readU16(m, 6), readU16(m, 8), readU16(m, 10) };
    const opt = findOpt(m);
    if (opt) |pos| {
        if (m[pos] != 0) return reject(pos);
    }
    const opcode: u16 = flags >> 11 & 0xf;
    var rcode: u16 = flags & 0xf;
    // The OPT TTL starts with the upper eight bits of the extended RCODE.
    if (opt) |pos| rcode |= @as(u16, m[pos + 5]) << 4;

    out.bytes(";; ->>HEADER<<- opcode: ");
    out.mnemonic(&opcodes, "OPCODE", opcode);
    out.bytes(", status: ");
    out.mnemonic(&rcodes, "RCODE", rcode);
    out.bytes(", id: ");
    out.decimal(readU16(m, 0));
    out.bytes("\n;; flags:");
    inline for (header_flags) |flag| {
        if (flags & flag.mask != 0) {
            out.byte(' ');
            out.bytes(flag.name);
        }
    }

    // RFC 2136 renames the sections of an UPDATE message.
    const update = opcode == 5;
    const titles: [4][]const u8 = if (update)
        .{ "ZONE", "PREREQUISITE", "UPDATE", "ADDITIONAL" }
    else
        .{ "QUESTION", "ANSWER", "AUTHORITY", "ADDITIONAL" };
    const count_labels: [4][]const u8 = if (update)
        .{ "ZONE", "PREREQ", "UPDATE", "ADDITIONAL" }
    else
        .{ "QUERY", "ANSWER", "AUTHORITY", "ADDITIONAL" };
    inline for (count_labels, counts, 0..) |label, count, i| {
        out.bytes(if (i == 0) "; " else ", ");
        out.bytes(label);
        out.bytes(": ");
        out.decimal(count);
    }
    out.byte('\n');

    if (opt) |pos| try writeOpt(m, pos, &out);

    var pos: usize = HEADER_SIZE;
    if (counts[0] > 0) sectionTitle(&out, titles[0]);
    for (0..counts[0]) |_| pos = try question(m, pos, &out);

    const sections = [3]Section{ .answer, .authority, .additional };
    inline for (sections, counts[1..], titles[1..]) |section, count, title| {
        const shown = if (section == .additional and opt != null) count - 1 else count;
        if (shown > 0) sectionTitle(&out, title);
        for (0..count) |_| pos = try record(m, pos, section, opt, &out);
    }

    if (pos != m.len) return reject(pos);
    return out.len;
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    const size = decode(input_buf[0..input_size]) catch return .{
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

fn expectFormatted(expected: []const u8, comptime write: anytype, args: anytype) !void {
    var buf: [64]u8 = undefined;
    var out: Output = .{ .buf = &buf };
    @call(.auto, write, .{&out} ++ args);
    try std.testing.expectEqualStrings(expected, buf[0..out.len]);
}

test "IPv6 text follows RFC 5952" {
    const cases = [_]struct { []const u8, [16]u8 }{
        .{ "::", [_]u8{0} ** 16 },
        .{ "::1", [_]u8{0} ** 15 ++ [_]u8{1} },
        .{ "1::", [_]u8{ 0, 1 } ++ [_]u8{0} ** 14 },
        // A single zero group is not shortened.
        .{ "2001:db8:0:1:1:1:1:1", .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 } },
        // The first of two equal runs is shortened.
        .{ "2001::1:0:0:1:1", .{ 0x20, 0x01, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1 } },
        // A longer later run wins.
        .{ "2001:0:0:1::1", .{ 0x20, 0x01, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 } },
    };
    for (cases) |case| try expectFormatted(case[0], ipv6, .{&case[1]});
}

test "base32hex, base64, and RRSIG timestamps" {
    try expectFormatted("CPNMUOG", base32hex, .{@as([]const u8, "foob")});
    try expectFormatted("CPNMUOJ1", base32hex, .{@as([]const u8, "fooba")});
    try expectFormatted("Zm9vYg==", base64, .{@as([]const u8, "foob")});
    try expectFormatted("19700101000000", timestamp, .{@as(u32, 0)});
    try expectFormatted("20000229235959", timestamp, .{@as(u32, 951868799)});
    try expectFormatted("21060207062815", timestamp, .{@as(u32, 0xffff_ffff)});
}

test "labels escape delimiters and non-printing bytes" {
    try expectFormatted("a\\.b\\032\\\\c\\255", labelText, .{@as([]const u8, "a.b \\c\xff")});
}
