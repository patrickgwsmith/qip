// Accepts a well-formed XML 1.0 document unchanged, like `xmllint --noout`.
//
// It checks the XML 1.0 (Fifth Edition) grammar and well-formedness
// constraints: matching tags, one root element, unique attributes, legal
// characters and names, references, and the XML and document type
// declarations. It does not fetch external DTDs or validate against a DTD.
//
// Like xmllint, it does not reject Namespaces in XML errors such as an
// undeclared prefix: xmllint reports those but still exits 0.
//
// Limits:
// - Input is UTF-8, with or without a BOM. An encoding declaration may also
//   name US-ASCII or ISO-8859-1. Other encodings, including UTF-16, are
//   rejected at the encoding name or at offset 0. After a UTF-8 BOM the input
//   is read as UTF-8 whatever the declaration says.
// - Internal general entities are checked where they are referenced: in
//   content the replacement text must be balanced content, and in an
//   attribute value it must not contain `<`. Recursive references are
//   rejected. Each entity is checked once per context, so nested expansion
//   costs no more than the entity text itself. As in libxml2, an undeclared
//   entity referenced from replacement text used in content is rejected even
//   when the document has an external subset.
// - Elements nest at most 256 deep, as in libxml2's default. A start tag
//   holds at most 4096 attributes, and the internal subset declares at most
//   4096 general entities. Entity references nest at most 40 deep, as in
//   libxml2, and the entity values that contain character references hold
//   at most 1 MiB of replacement text in total.
// - libxml2 also rejects some deep or repeated nesting of well-formed
//   entities as an "entity reference loop", to limit expansion. This
//   component does not, because it never expands an entity twice.
//
// Rejection reports the offset of the byte where the document stops being
// well-formed. A document that ends too early reports the input length.
const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const MAX_DEPTH: usize = 256;
const MAX_ATTRS: usize = 4096;
const MAX_ENTITIES: usize = 4096;
const MAX_GROUP_DEPTH: usize = 64;
const TABLE_SIZE: usize = 8192;
const MAX_ENTITY_DEPTH: usize = 40;
const REPL_CAP: usize = 1024 * 1024;

comptime {
    std.debug.assert(TABLE_SIZE >= 2 * MAX_ATTRS);
    std.debug.assert(TABLE_SIZE >= 2 * MAX_ENTITIES);
}

var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

// Accepted output is the input itself.
export fn output_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

// Input is any bytes (that is what this component validates); only accepted
// output is known to be XML, so only the output content type is declared.
const OUTPUT_CONTENT_TYPE = "application/xml";

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

const Malformed = error{Malformed};

var fail_at: u32 = 0;

fn fail(at: usize) Malformed {
    fail_at = @intCast(@min(at, src.len));
    return error.Malformed;
}

const Encoding = enum { utf8, ascii, latin1 };

var src: []const u8 = &.{};
var enc: Encoding = .utf8;
var has_doctype = false;
var has_external_subset = false;
var has_pe_refs = false;
var standalone_yes = false;

// Hash table keyed by one or two byte strings. A slot is live when its stamp
// equals the table generation, so reset is O(1).
fn Table(comptime N: usize) type {
    return struct {
        a: [N][]const u8 = undefined,
        b: [N][]const u8 = undefined,
        val: [N]u32 = undefined,
        stamp: [N]u32 = [_]u32{0} ** N,
        gen: u32 = 0,
        count: usize = 0,

        const Self = @This();

        fn reset(self: *Self) void {
            if (self.gen == std.math.maxInt(u32)) {
                @memset(&self.stamp, 0);
                self.gen = 0;
            }
            self.gen += 1;
            self.count = 0;
        }

        fn live(self: *const Self, idx: usize) bool {
            return self.stamp[idx] == self.gen;
        }

        // Returns the slot holding the key, or the free slot for it.
        fn find(self: *const Self, ka: []const u8, kb: []const u8) usize {
            var idx: usize = hash(ka, kb) & (N - 1);
            var probes: usize = N;
            while (probes > 0) : (probes -= 1) {
                if (!self.live(idx)) return idx;
                if (std.mem.eql(u8, self.a[idx], ka) and std.mem.eql(u8, self.b[idx], kb)) return idx;
                idx = (idx + 1) & (N - 1);
            }
            // Callers keep the load factor at or below one half.
            @trap();
        }

        fn put(self: *Self, idx: usize, ka: []const u8, kb: []const u8, v: u32) void {
            if (!self.live(idx)) self.count += 1;
            self.a[idx] = ka;
            self.b[idx] = kb;
            self.val[idx] = v;
            self.stamp[idx] = self.gen;
        }
    };
}

fn hash(ka: []const u8, kb: []const u8) u32 {
    var h: u32 = 2166136261;
    for (ka) |c| h = (h ^ c) *% 16777619;
    h = (h ^ 0xff) *% 16777619;
    for (kb) |c| h = (h ^ c) *% 16777619;
    return h;
}

var raw_attrs: Table(TABLE_SIZE) = .{};
var entities: Table(TABLE_SIZE) = .{};

// An entity's table value holds its flags in the low two bits and its index
// in the arrays below in the rest.
const ENTITY_EXTERNAL: u32 = 1;
const ENTITY_UNPARSED: u32 = 2;
const ENTITY_INDEX_SHIFT: u5 = 2;

// Replacement text of each internal general entity. Text without character
// references is a slice of the document in its encoding. Text with them is
// expanded into repl_buf as UTF-8.
var ent_text: [MAX_ENTITIES][]const u8 = undefined;
var ent_enc: [MAX_ENTITIES]Encoding = undefined;
var repl_buf: [REPL_CAP]u8 = undefined;
var repl_used: usize = 0;

// A node is an entity in one context: index * 2 for content, index * 2 + 1
// for an attribute value.
const MAX_NODES: usize = 2 * MAX_ENTITIES;
const NODE_UNSEEN: u8 = 0;
const NODE_ACTIVE: u8 = 1;
const NODE_DONE: u8 = 2;
var node_state: [MAX_NODES]u8 = undefined;
var node_queued: [MAX_NODES]bool = undefined;

// Nodes referenced from the document, with the offset of the first
// reference, in document order.
const Root = struct { node: u32, origin: u32 };
var roots: [MAX_NODES]Root = undefined;
var root_count: usize = 0;

// True while parsing replacement text instead of the document.
var in_entity = false;

var open_names: [MAX_DEPTH][]const u8 = undefined;

// Characters and names

fn isXmlChar(cp: u32) bool {
    return cp == 0x9 or cp == 0xA or cp == 0xD or
        (cp >= 0x20 and cp <= 0xD7FF) or
        (cp >= 0xE000 and cp <= 0xFFFD) or
        (cp >= 0x10000 and cp <= 0x10FFFF);
}

fn isNameStart(cp: u32) bool {
    return cp == ':' or cp == '_' or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
        (cp >= 0xC0 and cp <= 0xD6) or (cp >= 0xD8 and cp <= 0xF6) or
        (cp >= 0xF8 and cp <= 0x2FF) or (cp >= 0x370 and cp <= 0x37D) or
        (cp >= 0x37F and cp <= 0x1FFF) or (cp >= 0x200C and cp <= 0x200D) or
        (cp >= 0x2070 and cp <= 0x218F) or (cp >= 0x2C00 and cp <= 0x2FEF) or
        (cp >= 0x3001 and cp <= 0xD7FF) or (cp >= 0xF900 and cp <= 0xFDCF) or
        (cp >= 0xFDF0 and cp <= 0xFFFD) or (cp >= 0x10000 and cp <= 0xEFFFF);
}

fn isNameChar(cp: u32) bool {
    return isNameStart(cp) or cp == '-' or cp == '.' or (cp >= '0' and cp <= '9') or
        cp == 0xB7 or (cp >= 0x300 and cp <= 0x36F) or (cp >= 0x203F and cp <= 0x2040);
}

fn isS(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

fn isPubidChar(b: u8) bool {
    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')) return true;
    return std.mem.indexOfScalar(u8, " \r\n-'()+,./:=?;!*#@$_%", b) != null;
}

const Ch = struct { cp: u32, len: usize };

// Decodes one character and requires it to match the Char production.
fn charAt(at: usize) Malformed!Ch {
    if (at >= src.len) return fail(at);
    const b0 = src[at];
    if (b0 < 0x80) {
        if (!isXmlChar(b0)) return fail(at);
        return .{ .cp = b0, .len = 1 };
    }
    switch (enc) {
        // Every byte from 0x80 to 0xFF is a Char in ISO-8859-1.
        .latin1 => return .{ .cp = b0, .len = 1 },
        .ascii => return fail(at),
        .utf8 => {},
    }
    var need: usize = undefined;
    var cp: u32 = undefined;
    var min: u32 = undefined;
    if (b0 >= 0xC2 and b0 <= 0xDF) {
        need = 1;
        cp = b0 & 0x1F;
        min = 0x80;
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        need = 2;
        cp = b0 & 0x0F;
        min = 0x800;
    } else if (b0 >= 0xF0 and b0 <= 0xF4) {
        need = 3;
        cp = b0 & 0x07;
        min = 0x10000;
    } else return fail(at);
    if (src.len - at <= need) return fail(at);
    var k: usize = 1;
    while (k <= need) : (k += 1) {
        const b = src[at + k];
        if ((b & 0xC0) != 0x80) return fail(at);
        cp = (cp << 6) | (b & 0x3F);
    }
    if (cp < min or !isXmlChar(cp)) return fail(at);
    return .{ .cp = cp, .len = need + 1 };
}

fn startsWith(at: usize, lit: []const u8) bool {
    return at <= src.len and src.len - at >= lit.len and std.mem.eql(u8, src[at..][0..lit.len], lit);
}

fn byteAt(at: usize) u8 {
    return if (at < src.len) src[at] else 0;
}

fn skipS(at: usize) usize {
    var i = at;
    while (i < src.len and isS(src[i])) : (i += 1) {}
    return i;
}

fn requireS(at: usize) Malformed!usize {
    if (!isS(byteAt(at))) return fail(at);
    return skipS(at);
}

fn expectByte(at: usize, b: u8) Malformed!usize {
    if (byteAt(at) != b) return fail(at);
    return at + 1;
}

// Returns the end of the Name that starts at `at`.
fn readName(at: usize) Malformed!usize {
    const first = try charAt(at);
    if (!isNameStart(first.cp)) return fail(at);
    var end = at + first.len;
    var budget = src.len - end;
    while (budget > 0) : (budget -= 1) {
        if (end >= src.len) break;
        const c = try charAt(end);
        if (!isNameChar(c.cp)) break;
        end += c.len;
    }
    return end;
}

fn readNmtoken(at: usize) Malformed!usize {
    const first = try charAt(at);
    if (!isNameChar(first.cp)) return fail(at);
    var end = at + first.len;
    var budget = src.len - end;
    while (budget > 0) : (budget -= 1) {
        if (end >= src.len) break;
        const c = try charAt(end);
        if (!isNameChar(c.cp)) break;
        end += c.len;
    }
    return end;
}

// Comments, processing instructions, CDATA sections

fn comment(at: usize) Malformed!usize {
    var i = at + 4;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return fail(src.len);
        if (src[i] == '-' and byteAt(i + 1) == '-') {
            if (byteAt(i + 2) == '>') return i + 3;
            return fail(i);
        }
        i += (try charAt(i)).len;
    }
    @trap();
}

fn pi(at: usize) Malformed!usize {
    const name_end = try readName(at + 2);
    const target = src[at + 2 .. name_end];
    if (std.ascii.eqlIgnoreCase(target, "xml")) return fail(at);
    if (startsWith(name_end, "?>")) return name_end + 2;
    var i = try requireS(name_end);
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return fail(src.len);
        if (startsWith(i, "?>")) return i + 2;
        i += (try charAt(i)).len;
    }
    @trap();
}

fn cdata(at: usize) Malformed!usize {
    var i = at + 9;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return fail(src.len);
        if (startsWith(i, "]]>")) return i + 3;
        i += (try charAt(i)).len;
    }
    @trap();
}

// References

const RefMode = enum { content, attr, entity_value };

fn mustDeclareEntities() bool {
    return !has_doctype or standalone_yes or (!has_external_subset and !has_pe_refs);
}

const Ref = struct { end: usize, char: ?u32, name: []const u8 };

fn reference(at: usize, mode: RefMode) Malformed!Ref {
    if (byteAt(at + 1) == '#') {
        const hex = byteAt(at + 2) == 'x';
        var i = at + (if (hex) @as(usize, 3) else 2);
        const digits_start = i;
        var value: u32 = 0;
        while (i < src.len) : (i += 1) {
            const b = src[i];
            const d: u32 = if (b >= '0' and b <= '9')
                b - '0'
            else if (hex and b >= 'a' and b <= 'f')
                b - 'a' + 10
            else if (hex and b >= 'A' and b <= 'F')
                b - 'A' + 10
            else
                break;
            value = @min(value * (if (hex) @as(u32, 16) else 10) + d, 0x110000);
        }
        if (i == digits_start) return fail(i);
        if (byteAt(i) != ';') return fail(i);
        if (!isXmlChar(value)) return fail(at);
        return .{ .end = i + 1, .char = value, .name = "" };
    }
    const name_end = try readName(at + 1);
    if (byteAt(name_end) != ';') return fail(name_end);
    const name = src[at + 1 .. name_end];
    const ref: Ref = .{ .end = name_end + 1, .char = null, .name = name };
    if (mode == .entity_value) return ref;
    if (predefined(name) != null) return ref;
    const idx = entities.find(name, "");
    if (entities.live(idx)) {
        const flags = entities.val[idx];
        if (flags & ENTITY_UNPARSED != 0) return fail(at);
        if (mode == .attr and flags & ENTITY_EXTERNAL != 0) return fail(at);
        if (flags & ENTITY_EXTERNAL == 0 and !in_entity) {
            queueNode(entityNode(flags, mode == .attr), at);
        }
    } else if (mustDeclareEntities()) {
        return fail(at);
    } else if (in_entity and mode == .content) {
        // libxml2 parses replacement text in content as a balanced chunk
        // and treats an undeclared entity there as fatal even when an
        // external subset could declare it.
        return fail(at);
    }
    return ref;
}

fn entityNode(flags: u32, attr: bool) u32 {
    return (flags >> ENTITY_INDEX_SHIFT) * 2 + @intFromBool(attr);
}

fn queueNode(node: u32, at: usize) void {
    if (node_queued[node]) return;
    node_queued[node] = true;
    roots[root_count] = .{ .node = node, .origin = @intCast(at) };
    root_count += 1;
}

fn predefined(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "lt")) return '<';
    if (std.mem.eql(u8, name, "gt")) return '>';
    if (std.mem.eql(u8, name, "amp")) return '&';
    if (std.mem.eql(u8, name, "apos")) return '\'';
    if (std.mem.eql(u8, name, "quot")) return '"';
    return null;
}

// Returns the end of the quoted AttValue at `at`.
fn attValue(at: usize) Malformed!usize {
    const q = byteAt(at);
    if (q != '"' and q != '\'') return fail(at);
    var i = at + 1;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return fail(src.len);
        const b = src[i];
        if (b == q) return i + 1;
        if (b == '<') return fail(i);
        if (b == '&') {
            i = (try reference(i, .attr)).end;
        } else {
            i += (try charAt(i)).len;
        }
    }
    @trap();
}

// Elements

const StartTag = struct { end: usize, empty: bool, name: []const u8 };

fn startTag(at: usize) Malformed!StartTag {
    const name_end = try readName(at + 1);
    raw_attrs.reset();
    var i = name_end;
    var empty = false;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        const j = skipS(i);
        if (j >= src.len) return fail(src.len);
        if (src[j] == '>') {
            i = j + 1;
            break;
        }
        if (src[j] == '/') {
            if (byteAt(j + 1) != '>') return fail(j + 1);
            i = j + 2;
            empty = true;
            break;
        }
        if (j == i) return fail(j);
        const aname_end = try readName(j);
        const aname = src[j..aname_end];
        var k = skipS(aname_end);
        k = try expectByte(k, '=');
        k = skipS(k);
        const value_end = try attValue(k);
        if (raw_attrs.count == MAX_ATTRS) return fail(j);
        const slot = raw_attrs.find(aname, "");
        if (raw_attrs.live(slot)) return fail(j);
        raw_attrs.put(slot, aname, "", 0);
        i = value_end;
    } else @trap();

    return .{ .end = i, .empty = empty, .name = src[at + 1 .. name_end] };
}

// Declarations

fn xmlDecl(at: usize) Malformed!usize {
    var i = skipS(at + 5);
    if (!startsWith(i, "version")) return fail(i);
    i = try eq(i + 7);
    const q = byteAt(i);
    if (q != '"' and q != '\'') return fail(i);
    i += 1;
    if (!startsWith(i, "1.")) return fail(i);
    i += 2;
    const digits = i;
    while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
    if (i == digits) return fail(i);
    i = try expectByte(i, q);

    var j = skipS(i);
    if (j > i and startsWith(j, "encoding")) {
        var k = try eq(j + 8);
        const eq_quote = byteAt(k);
        if (eq_quote != '"' and eq_quote != '\'') return fail(k);
        k += 1;
        const name_start = k;
        while (k < src.len and src[k] != eq_quote and src[k] != '<') : (k += 1) {}
        const name = src[name_start..k];
        const bom = startsWith(0, "\xEF\xBB\xBF");
        if (std.ascii.eqlIgnoreCase(name, "UTF-8")) {
            enc = .utf8;
        } else if (std.ascii.eqlIgnoreCase(name, "US-ASCII") or std.ascii.eqlIgnoreCase(name, "ASCII")) {
            enc = .ascii;
        } else if (std.ascii.eqlIgnoreCase(name, "ISO-8859-1") or std.ascii.eqlIgnoreCase(name, "ISO_8859-1") or std.ascii.eqlIgnoreCase(name, "LATIN1")) {
            enc = .latin1;
        } else return fail(name_start);
        if (bom) enc = .utf8;
        i = try expectByte(k, eq_quote);
        j = skipS(i);
    }
    if (j > i and startsWith(j, "standalone")) {
        var k = try eq(j + 10);
        const sd_quote = byteAt(k);
        if (sd_quote != '"' and sd_quote != '\'') return fail(k);
        k += 1;
        if (startsWith(k, "yes")) {
            standalone_yes = true;
            k += 3;
        } else if (startsWith(k, "no")) {
            k += 2;
        } else return fail(k);
        i = try expectByte(k, sd_quote);
        j = skipS(i);
    }
    if (!startsWith(j, "?>")) return fail(j);
    return j + 2;
}

fn eq(at: usize) Malformed!usize {
    const i = try expectByte(skipS(at), '=');
    return skipS(i);
}

fn quotedLiteral(at: usize, pubid: bool) Malformed!usize {
    const q = byteAt(at);
    if (q != '"' and q != '\'') return fail(at);
    var i = at + 1;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return fail(src.len);
        if (src[i] == q) return i + 1;
        if (pubid) {
            if (!isPubidChar(src[i])) return fail(i);
            i += 1;
        } else {
            i += (try charAt(i)).len;
        }
    }
    @trap();
}

fn externalId(at: usize, public_only_allowed: bool) Malformed!usize {
    if (startsWith(at, "SYSTEM")) {
        return quotedLiteral(try requireS(at + 6), false);
    }
    if (!startsWith(at, "PUBLIC")) return fail(at);
    const i = try quotedLiteral(try requireS(at + 6), true);
    const j = skipS(i);
    const q = byteAt(j);
    if (j > i and (q == '"' or q == '\'')) return quotedLiteral(j, false);
    if (public_only_allowed) return i;
    return fail(j);
}

fn doctype(at: usize) Malformed!usize {
    var i = try requireS(at + 9);
    i = try readName(i);
    has_doctype = true;
    var j = skipS(i);
    if (j > i and (startsWith(j, "SYSTEM") or startsWith(j, "PUBLIC"))) {
        i = try externalId(j, false);
        has_external_subset = true;
        j = skipS(i);
    }
    if (byteAt(j) == '[') {
        i = try internalSubset(j + 1);
        j = skipS(i);
    }
    return expectByte(j, '>');
}

fn internalSubset(at: usize) Malformed!usize {
    var i = at;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        i = skipS(i);
        if (i >= src.len) return fail(src.len);
        if (src[i] == ']') return i + 1;
        if (src[i] == '%') {
            const name_end = try readName(i + 1);
            i = try expectByte(name_end, ';');
            has_pe_refs = true;
        } else if (startsWith(i, "<!--")) {
            i = try comment(i);
        } else if (startsWith(i, "<?")) {
            i = try pi(i);
        } else if (startsWith(i, "<!ELEMENT")) {
            i = try elementDecl(i);
        } else if (startsWith(i, "<!ATTLIST")) {
            i = try attlistDecl(i);
        } else if (startsWith(i, "<!ENTITY")) {
            i = try entityDecl(i);
        } else if (startsWith(i, "<!NOTATION")) {
            i = try notationDecl(i);
        } else return fail(i);
    }
    @trap();
}

fn quantifier(at: usize) usize {
    const b = byteAt(at);
    return if (b == '?' or b == '*' or b == '+') at + 1 else at;
}

fn elementDecl(at: usize) Malformed!usize {
    var i = try requireS(at + 9);
    i = try readName(i);
    i = try requireS(i);
    i = try contentSpec(i);
    return expectByte(skipS(i), '>');
}

fn contentSpec(at: usize) Malformed!usize {
    if (byteAt(at) != '(') {
        const end = try readName(at);
        const word = src[at..end];
        if (std.mem.eql(u8, word, "EMPTY") or std.mem.eql(u8, word, "ANY")) return end;
        return fail(at);
    }
    var i = skipS(at + 1);
    var budget = src.len - i + 1;
    if (startsWith(i, "#PCDATA")) {
        i += 7;
        var names: usize = 0;
        while (budget > 0) : (budget -= 1) {
            i = skipS(i);
            if (byteAt(i) == ')') {
                if (byteAt(i + 1) == '*') return i + 2;
                if (names > 0) return fail(i + 1);
                return i + 1;
            }
            i = try expectByte(i, '|');
            i = try readName(skipS(i));
            names += 1;
        }
        @trap();
    }
    // Children: a stack of group separators instead of recursion.
    var seps: [MAX_GROUP_DEPTH]u8 = undefined;
    seps[0] = 0;
    var depth: usize = 1;
    var expect_cp = true;
    while (budget > 0) : (budget -= 1) {
        i = skipS(i);
        if (i >= src.len) return fail(src.len);
        if (expect_cp) {
            if (src[i] == '(') {
                if (depth == MAX_GROUP_DEPTH) return fail(i);
                seps[depth] = 0;
                depth += 1;
                i += 1;
            } else {
                i = quantifier(try readName(i));
                expect_cp = false;
            }
        } else {
            const c = src[i];
            if (c == '|' or c == ',') {
                if (seps[depth - 1] == 0) {
                    seps[depth - 1] = c;
                } else if (seps[depth - 1] != c) return fail(i);
                i += 1;
                expect_cp = true;
            } else if (c == ')') {
                depth -= 1;
                i = quantifier(i + 1);
                if (depth == 0) return i;
            } else return fail(i);
        }
    }
    @trap();
}

fn attlistDecl(at: usize) Malformed!usize {
    var i = try requireS(at + 9);
    i = try readName(i);
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        const j = skipS(i);
        if (j >= src.len) return fail(src.len);
        if (src[j] == '>') return j + 1;
        if (j == i) return fail(j);
        i = try requireS(try readName(j));
        if (src[i] == '(') {
            i = try enumeration(i, true);
        } else {
            const type_end = try readName(i);
            const t = src[i..type_end];
            const simple = [_][]const u8{ "CDATA", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS" };
            var known = false;
            for (simple) |s| known = known or std.mem.eql(u8, t, s);
            if (known) {
                i = type_end;
            } else if (std.mem.eql(u8, t, "NOTATION")) {
                const k = try requireS(type_end);
                if (byteAt(k) != '(') return fail(k);
                i = try enumeration(k, false);
            } else return fail(i);
        }
        i = try requireS(i);
        if (startsWith(i, "#REQUIRED")) {
            i += 9;
        } else if (startsWith(i, "#IMPLIED")) {
            i += 8;
        } else if (startsWith(i, "#FIXED")) {
            i = try attValue(try requireS(i + 6));
        } else {
            i = try attValue(i);
        }
    }
    @trap();
}

fn enumeration(at: usize, nmtokens: bool) Malformed!usize {
    var i = skipS(at + 1);
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        i = skipS(if (nmtokens) try readNmtoken(i) else try readName(i));
        if (byteAt(i) == ')') return i + 1;
        i = skipS(try expectByte(i, '|'));
    }
    @trap();
}

fn entityValue(at: usize) Malformed!usize {
    const q = byteAt(at);
    var i = at + 1;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return fail(src.len);
        const b = src[i];
        if (b == q) return i + 1;
        // Parameter-entity references cannot occur inside a declaration in
        // the internal subset.
        if (b == '%') return fail(i);
        if (b == '&') {
            i = (try reference(i, .entity_value)).end;
        } else {
            i += (try charAt(i)).len;
        }
    }
    @trap();
}

fn entityDecl(at: usize) Malformed!usize {
    var i = try requireS(at + 8);
    var parameter = false;
    if (src[i] == '%') {
        parameter = true;
        i = try requireS(i + 1);
    }
    const name_start = i;
    i = try readName(i);
    const name = src[name_start..i];
    i = try requireS(i);
    var flags: u32 = 0;
    const q = byteAt(i);
    const value_start = i;
    if (q == '"' or q == '\'') {
        i = try entityValue(i);
    } else {
        i = try externalId(i, false);
        flags |= ENTITY_EXTERNAL;
        if (!parameter) {
            const j = skipS(i);
            if (j > i and startsWith(j, "NDATA")) {
                i = try readName(try requireS(j + 5));
                flags |= ENTITY_UNPARSED;
            }
        }
    }
    const end = try expectByte(skipS(i), '>');
    if (!parameter) {
        // The first declaration of an entity is binding.
        const slot = entities.find(name, "");
        if (!entities.live(slot)) {
            if (entities.count == MAX_ENTITIES) return fail(name_start);
            const index = entities.count;
            if (flags & ENTITY_EXTERNAL == 0) {
                try replacementText(index, value_start + 1, i - 1, name_start);
            }
            entities.put(slot, name, "", flags | (@as(u32, @intCast(index)) << ENTITY_INDEX_SHIFT));
            node_state[2 * index] = NODE_UNSEEN;
            node_state[2 * index + 1] = NODE_UNSEEN;
            node_queued[2 * index] = false;
            node_queued[2 * index + 1] = false;
        }
    }
    return end;
}

// Records the replacement text of the already checked EntityValue between
// `start` and `end`: character references are expanded and general entity
// references are kept as they are.
fn replacementText(index: usize, start: usize, end: usize, name_start: usize) Malformed!void {
    const literal = src[start..end];
    if (std.mem.indexOf(u8, literal, "&#") == null) {
        ent_text[index] = literal;
        ent_enc[index] = enc;
        return;
    }
    const out_start = repl_used;
    var i = start;
    var budget = literal.len + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= end) break;
        if (REPL_CAP - repl_used < 4) return fail(name_start);
        const b = src[i];
        if (b == '&' and byteAt(i + 1) == '#') {
            const ref = try reference(i, .entity_value);
            const cp: u21 = @intCast(ref.char.?);
            repl_used += std.unicode.utf8Encode(cp, repl_buf[repl_used..]) catch unreachable;
            i = ref.end;
        } else if (enc == .latin1 and b >= 0x80) {
            repl_used += std.unicode.utf8Encode(b, repl_buf[repl_used..]) catch unreachable;
            i += 1;
        } else {
            repl_buf[repl_used] = b;
            repl_used += 1;
            i += 1;
        }
    } else @trap();
    ent_text[index] = repl_buf[out_start..repl_used];
    ent_enc[index] = .utf8;
}

fn notationDecl(at: usize) Malformed!usize {
    var i = try requireS(at + 10);
    i = try readName(i);
    i = try externalId(try requireS(i), true);
    return expectByte(skipS(i), '>');
}

// Document

fn parseDocument(input: []const u8) Malformed!void {
    src = input;
    enc = .utf8;
    has_doctype = false;
    has_external_subset = false;
    has_pe_refs = false;
    standalone_yes = false;
    entities.reset();
    repl_used = 0;
    root_count = 0;
    in_entity = false;

    // UTF-16 byte order marks.
    if (startsWith(0, "\xFE\xFF") or startsWith(0, "\xFF\xFE")) return fail(0);
    var i: usize = 0;
    if (startsWith(0, "\xEF\xBB\xBF")) i = 3;
    if (startsWith(i, "<?xml") and isS(byteAt(i + 5))) i = try xmlDecl(i);

    return parseMarkup(i, true);
}

// Parses from `at` to the end of src: the rest of the document after the
// XML declaration, or the replacement text of an entity used in content.
fn parseMarkup(at: usize, document: bool) Malformed!void {
    var i = at;
    var depth: usize = 0;
    var root_seen = false;
    var budget = src.len - i + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) {
            if (depth > 0 or (document and !root_seen)) return fail(src.len);
            return;
        }
        const b = src[i];
        if (b == '<') {
            if (startsWith(i, "</")) {
                if (depth == 0) return fail(i);
                const name_end = try readName(i + 2);
                if (!std.mem.eql(u8, src[i + 2 .. name_end], open_names[depth - 1])) return fail(i + 2);
                i = try expectByte(skipS(name_end), '>');
                depth -= 1;
            } else if (startsWith(i, "<!--")) {
                i = try comment(i);
            } else if (startsWith(i, "<?")) {
                i = try pi(i);
            } else if (startsWith(i, "<![CDATA[")) {
                if (document and depth == 0) return fail(i);
                i = try cdata(i);
            } else if (startsWith(i, "<!DOCTYPE")) {
                if (!document or root_seen or has_doctype) return fail(i);
                i = try doctype(i);
            } else {
                if (document and root_seen and depth == 0) return fail(i);
                const tag = try startTag(i);
                root_seen = true;
                if (!tag.empty) {
                    if (depth == MAX_DEPTH) return fail(i);
                    open_names[depth] = tag.name;
                    depth += 1;
                }
                i = tag.end;
            }
        } else if (document and depth == 0) {
            if (!isS(b)) return fail(i);
            i += 1;
        } else if (b == '&') {
            i = (try reference(i, .content)).end;
        } else if (b == ']' and startsWith(i, "]]>")) {
            return fail(i);
        } else {
            i += (try charAt(i)).len;
        }
    }
    @trap();
}

// Entities

// Checks one node's own replacement text, without following references.
fn checkNode(node: u32) bool {
    const index = node >> 1;
    const doc_src = src;
    const doc_enc = enc;
    src = ent_text[index];
    enc = ent_enc[index];
    in_entity = true;
    defer {
        src = doc_src;
        enc = doc_enc;
        in_entity = false;
    }
    if (node & 1 == 1) {
        attrText() catch return false;
    } else {
        parseMarkup(0, false) catch return false;
    }
    return true;
}

// Replacement text used in an attribute value.
fn attrText() Malformed!void {
    var i: usize = 0;
    var budget = src.len + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= src.len) return;
        const b = src[i];
        if (b == '<') return fail(i);
        if (b == '&') {
            i = (try reference(i, .attr)).end;
        } else {
            i += (try charAt(i)).len;
        }
    }
    @trap();
}

// A node being checked, with where to resume scanning its checked
// replacement text for references.
const Frame = struct { node: u32, pos: usize, in_tag: bool, quote: u8 };
var frames: [MAX_ENTITY_DEPTH]Frame = undefined;

fn endAfter(text: []const u8, from: usize, lit: []const u8) usize {
    const k = std.mem.indexOfPos(u8, text, from, lit) orelse return text.len;
    return k + lit.len;
}

// Returns the next internal entity node referenced by the frame's text.
fn nextChild(f: *Frame) ?u32 {
    const text = ent_text[f.node >> 1];
    const attr_text = f.node & 1 == 1;
    var i = f.pos;
    var budget = text.len + 1;
    while (budget > 0) : (budget -= 1) {
        if (i >= text.len) {
            f.pos = text.len;
            return null;
        }
        const b = text[i];
        if (b == '&' and (attr_text or f.quote != 0 or !f.in_tag)) {
            const semi = std.mem.indexOfScalarPos(u8, text, i, ';') orelse text.len;
            const name = text[i + 1 .. semi];
            i = semi + 1;
            if (name.len == 0 or name[0] == '#' or predefined(name) != null) continue;
            const slot = entities.find(name, "");
            if (!entities.live(slot)) continue;
            const flags = entities.val[slot];
            if (flags & ENTITY_EXTERNAL != 0) continue;
            f.pos = i;
            return entityNode(flags, attr_text or f.quote != 0);
        }
        if (attr_text) {
            i += 1;
        } else if (f.quote != 0) {
            if (b == f.quote) f.quote = 0;
            i += 1;
        } else if (f.in_tag) {
            if (b == '"' or b == '\'') f.quote = b;
            if (b == '>') f.in_tag = false;
            i += 1;
        } else if (b == '<') {
            const rest = text[i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                i = endAfter(text, i + 4, "-->");
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                i = endAfter(text, i + 9, "]]>");
            } else if (std.mem.startsWith(u8, rest, "<?")) {
                i = endAfter(text, i + 2, "?>");
            } else {
                f.in_tag = true;
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    @trap();
}

// Checks a node and every node it reaches, depth first with an explicit
// stack. Reaching a node that is still on the stack is a recursive entity.
fn visitNode(root: u32, budget_in: usize) bool {
    if (node_state[root] == NODE_DONE) return true;
    if (!checkNode(root)) return false;
    node_state[root] = NODE_ACTIVE;
    frames[0] = .{ .node = root, .pos = 0, .in_tag = false, .quote = 0 };
    var top: usize = 1;
    var budget = budget_in;
    while (budget > 0) : (budget -= 1) {
        if (top == 0) return true;
        const f = &frames[top - 1];
        const child = nextChild(f) orelse {
            node_state[f.node] = NODE_DONE;
            top -= 1;
            continue;
        };
        if (node_state[child] == NODE_DONE) continue;
        if (node_state[child] == NODE_ACTIVE) return false;
        if (top == MAX_ENTITY_DEPTH) return false;
        if (!checkNode(child)) return false;
        node_state[child] = NODE_ACTIVE;
        frames[top] = .{ .node = child, .pos = 0, .in_tag = false, .quote = 0 };
        top += 1;
    }
    @trap();
}

// Returns the failure offset, or null when the document is well-formed.
fn check(input_size: u32) ?u32 {
    if (input_size > INPUT_CAP) @trap();
    var doc_fail: ?u32 = null;
    parseDocument(input_buf[0..input_size]) catch {
        doc_fail = fail_at;
    };
    // Every node is pushed at most once and each push scans its text once,
    // so this bounds the work of all visits together.
    const budget = 2 * (input_size + repl_used) + 2 * MAX_NODES + 2;
    // Roots are in document order and all precede any document failure, so
    // the first failing root is the earliest failure.
    for (roots[0..root_count]) |r| {
        if (!visitNode(r.node, budget)) return r.origin;
    }
    return doc_fail;
}

export fn render(input_size: u32) RenderResult {
    if (check(input_size)) |offset| {
        return .{ .output_size_or_failure = offset, .output_ptr = 0, .failed = 1 };
    }
    return .{ .output_size_or_failure = input_size, .output_ptr = @intCast(@intFromPtr(&input_buf)), .failed = 0 };
}

fn checkText(text: []const u8) ?u32 {
    @memcpy(input_buf[0..text.len], text);
    return check(@intCast(text.len));
}

test "accepts an OPML subscription list" {
    try std.testing.expectEqual(@as(?u32, null), checkText(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<?xml-stylesheet type="text/xsl" href="opml.xsl"?>
        \\<opml version="2.0">
        \\  <head><title>Feeds &amp; more</title></head>
        \\  <body>
        \\    <outline text="QIP" type="rss" xmlUrl="https://qip.dev/feed.xml?a=1&amp;b=2"/>
        \\  </body>
        \\</opml>
        \\
    ));
}

test "reports the offset where well-formedness fails" {
    try std.testing.expectEqual(@as(?u32, 8), checkText("<a><b></a>"));
    try std.testing.expectEqual(@as(?u32, 3), checkText("<a>"));
    try std.testing.expectEqual(@as(?u32, 3), checkText("<a>&nbsp;</a>"));
    try std.testing.expectEqual(@as(?u32, 9), checkText("<a x='1' x='2'/>"));
    try std.testing.expectEqual(@as(?u32, 4), checkText("<a/><b/>"));
    try std.testing.expectEqual(@as(?u32, 0), checkText(""));
}

test "recovers after rejection" {
    try std.testing.expect(checkText("<a b='<'/>") != null);
    try std.testing.expectEqual(@as(?u32, null), checkText("<a b='&lt;'/>"));
}

test "does not check namespace prefixes" {
    try std.testing.expectEqual(@as(?u32, null), checkText("<p:a q:b='1'/>"));
    try std.testing.expectEqual(@as(?u32, 13), checkText("<p:a q:b='1' q:b='2'/>"));
}

test "accepts entities declared in the internal subset" {
    try std.testing.expectEqual(@as(?u32, null), checkText(
        "<!DOCTYPE a [<!ENTITY e 'x'><!ELEMENT a (#PCDATA|b)*><!ATTLIST a k CDATA #IMPLIED>]><a>&e;</a>",
    ));
    try std.testing.expectEqual(@as(?u32, null), checkText(
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"x.dtd\"><html>&nbsp;</html>",
    ));
}

test "checks entity replacement text where it is used" {
    try std.testing.expectEqual(@as(?u32, null), checkText("<!DOCTYPE a [<!ENTITY e '<'>]><a/>"));
    try std.testing.expectEqual(@as(?u32, 33), checkText("<!DOCTYPE a [<!ENTITY e '<'>]><a>&e;</a>"));
    try std.testing.expectEqual(@as(?u32, 35), checkText("<!DOCTYPE a [<!ENTITY e '&e;'>]><a>&e;</a>"));
    try std.testing.expect(checkText("<!DOCTYPE a [<!ENTITY e '&f;'><!ENTITY f '&e;'>]><a>&e;</a>") != null);
    try std.testing.expect(checkText("<!DOCTYPE a [<!ENTITY e '<b>'>]><a>&e;</b></a>") != null);
    try std.testing.expect(checkText("<!DOCTYPE a [<!ENTITY e '&#60;'>]><a>&e;</a>") != null);
    try std.testing.expectEqual(@as(?u32, null), checkText("<!DOCTYPE a [<!ENTITY e '&#38;#60;'>]><a x='&e;'>&e;</a>"));
    try std.testing.expect(checkText("<!DOCTYPE a [<!ENTITY e '<b/>'>]><a x='&e;'/>") != null);
    try std.testing.expect(checkText("<!DOCTYPE a [<!ENTITY e \"<b x='&f;'/>\"><!ENTITY f '<'>]><a>&e;</a>") != null);
    try std.testing.expectEqual(@as(?u32, null), checkText("<!DOCTYPE a [<!ENTITY e \"<b x='&f;'>&f;</b>\"><!ENTITY f '1'>]><a>&e;&e;</a>"));
    // An earlier entity failure wins over a later document failure.
    try std.testing.expectEqual(@as(?u32, 33), checkText("<!DOCTYPE a [<!ENTITY e '<'>]><a>&e;</b>"));
}

test "maximum depth fits the element stack" {
    var n: usize = 0;
    var d: usize = 0;
    while (d < MAX_DEPTH) : (d += 1) {
        @memcpy(input_buf[n..][0..3], "<a>");
        n += 3;
    }
    d = 0;
    while (d < MAX_DEPTH) : (d += 1) {
        @memcpy(input_buf[n..][0..4], "</a>");
        n += 4;
    }
    try std.testing.expectEqual(@as(?u32, null), check(@intCast(n)));
    @memcpy(input_buf[0..3], "<b>");
    try std.testing.expect(check(@intCast(n)) != null);
}
