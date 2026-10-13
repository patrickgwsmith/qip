//! Shared tables and helpers for the `application/dns-message` components.
//! Mnemonics follow the IANA DNS Parameters registry. Codes without a
//! mnemonic use the RFC 3597 `TYPEnnn` and `CLASSnnn` forms.

pub const Mnemonic = struct { code: u16, name: []const u8 };

pub const types = [_]Mnemonic{
    .{ .code = 1, .name = "A" },
    .{ .code = 2, .name = "NS" },
    .{ .code = 5, .name = "CNAME" },
    .{ .code = 6, .name = "SOA" },
    .{ .code = 10, .name = "NULL" },
    .{ .code = 12, .name = "PTR" },
    .{ .code = 13, .name = "HINFO" },
    .{ .code = 15, .name = "MX" },
    .{ .code = 16, .name = "TXT" },
    .{ .code = 17, .name = "RP" },
    .{ .code = 18, .name = "AFSDB" },
    .{ .code = 24, .name = "SIG" },
    .{ .code = 25, .name = "KEY" },
    .{ .code = 28, .name = "AAAA" },
    .{ .code = 29, .name = "LOC" },
    .{ .code = 33, .name = "SRV" },
    .{ .code = 35, .name = "NAPTR" },
    .{ .code = 36, .name = "KX" },
    .{ .code = 37, .name = "CERT" },
    .{ .code = 39, .name = "DNAME" },
    .{ .code = 41, .name = "OPT" },
    .{ .code = 42, .name = "APL" },
    .{ .code = 43, .name = "DS" },
    .{ .code = 44, .name = "SSHFP" },
    .{ .code = 45, .name = "IPSECKEY" },
    .{ .code = 46, .name = "RRSIG" },
    .{ .code = 47, .name = "NSEC" },
    .{ .code = 48, .name = "DNSKEY" },
    .{ .code = 49, .name = "DHCID" },
    .{ .code = 50, .name = "NSEC3" },
    .{ .code = 51, .name = "NSEC3PARAM" },
    .{ .code = 52, .name = "TLSA" },
    .{ .code = 53, .name = "SMIMEA" },
    .{ .code = 55, .name = "HIP" },
    .{ .code = 59, .name = "CDS" },
    .{ .code = 60, .name = "CDNSKEY" },
    .{ .code = 61, .name = "OPENPGPKEY" },
    .{ .code = 62, .name = "CSYNC" },
    .{ .code = 63, .name = "ZONEMD" },
    .{ .code = 64, .name = "SVCB" },
    .{ .code = 65, .name = "HTTPS" },
    .{ .code = 99, .name = "SPF" },
    .{ .code = 108, .name = "EUI48" },
    .{ .code = 109, .name = "EUI64" },
    .{ .code = 128, .name = "NXNAME" },
    .{ .code = 249, .name = "TKEY" },
    .{ .code = 250, .name = "TSIG" },
    .{ .code = 251, .name = "IXFR" },
    .{ .code = 252, .name = "AXFR" },
    .{ .code = 255, .name = "ANY" },
    .{ .code = 256, .name = "URI" },
    .{ .code = 257, .name = "CAA" },
};

// ANY (255) is left out so that a bare "ANY" in a question means the QTYPE.
// CLASS255 still selects the ANY class.
pub const classes = [_]Mnemonic{
    .{ .code = 1, .name = "IN" },
    .{ .code = 3, .name = "CH" },
    .{ .code = 4, .name = "HS" },
    .{ .code = 254, .name = "NONE" },
};

pub const TYPE_A: u16 = 1;
pub const TYPE_OPT: u16 = 41;
pub const CLASS_IN: u16 = 1;

// The tables are small and known at compile time, so lookups unroll into
// comparisons and leave no loop for wasm-bounded-loops to prove.
pub fn nameOf(comptime table: []const Mnemonic, code: u16) ?[]const u8 {
    inline for (table) |entry| {
        if (entry.code == code) return entry.name;
    }
    return null;
}

fn asciiUpper(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
}

fn equalIgnoreCase(comptime expected: []const u8, text: []const u8) bool {
    if (text.len != expected.len) return false;
    inline for (expected, 0..) |byte, i| {
        if (asciiUpper(text[i]) != asciiUpper(byte)) return false;
    }
    return true;
}

// Parses a mnemonic from `table`, or `prefix` followed by a decimal code
// from 0 to 65535, without regard to ASCII case.
pub fn parseMnemonic(comptime table: []const Mnemonic, comptime prefix: []const u8, text: []const u8) ?u16 {
    inline for (table) |entry| {
        if (equalIgnoreCase(entry.name, text)) return entry.code;
    }
    if (text.len <= prefix.len or text.len > prefix.len + 5) return null;
    if (!equalIgnoreCase(prefix, text[0..prefix.len])) return null;
    var value: u32 = 0;
    inline for (0..5) |k| {
        if (prefix.len + k < text.len) {
            const byte = text[prefix.len + k];
            if (byte < '0' or byte > '9') return null;
            value = value * 10 + (byte - '0');
        }
    }
    if (value > 0xffff) return null;
    return @intCast(value);
}

pub fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) << 8 | bytes[offset + 1];
}

pub fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, readU16(bytes, offset)) << 16 | readU16(bytes, offset + 2);
}

// Writes into a fixed buffer. The components prove their output bounds, so a
// write past the end is an invariant failure and traps.
pub const Output = struct {
    buf: []u8,
    len: usize = 0,

    pub fn byte(self: *Output, value: u8) void {
        if (self.len >= self.buf.len) @trap();
        self.buf[self.len] = value;
        self.len += 1;
    }

    pub fn bytes(self: *Output, values: []const u8) void {
        if (values.len > self.buf.len - self.len) @trap();
        @memcpy(self.buf[self.len..][0..values.len], values);
        self.len += values.len;
    }

    pub fn u16be(self: *Output, value: u16) void {
        self.byte(@truncate(value >> 8));
        self.byte(@truncate(value));
    }

    pub fn decimal(self: *Output, value: u32) void {
        var digits: [10]u8 = undefined;
        var remaining = value;
        var start: usize = digits.len - 1;
        inline for (0..digits.len) |k| {
            const i = digits.len - 1 - k;
            digits[i] = '0' + @as(u8, @intCast(remaining % 10));
            if (remaining != 0) start = i;
            remaining /= 10;
        }
        self.bytes(digits[start..]);
    }

    pub fn mnemonic(self: *Output, comptime table: []const Mnemonic, comptime prefix: []const u8, code: u16) void {
        if (nameOf(table, code)) |name| {
            self.bytes(name);
        } else {
            self.bytes(prefix);
            self.decimal(code);
        }
    }
};
