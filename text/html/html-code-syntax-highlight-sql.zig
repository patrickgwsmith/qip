const std = @import("std");

// Highlights `<code class="language-sql">` blocks with Highlight.js class
// names. Keywords, types and literals match case-insensitively. Words that
// double as common names (`first`, `key`, `view`, `rows`...) are keywords
// only inside a known phrase such as `PRIMARY KEY` or `NULLS LAST`. A known
// function name is `hljs-built_in` only when a `(` follows it, so `count(*)`
// is a call but `count` as a column name stays plain. Parts of qualified
// names such as `orders.date` stay plain. `'strings'` (including `''`
// escapes, E'...' strings and PostgreSQL `$$` bodies) are `hljs-string`;
// `"quoted"` and `` `quoted` `` identifiers stay plain. `@var`, `$1` and
// `:name` parameters are `hljs-variable`. `--` and nested `/* */` comments
// are `hljs-comment`.

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

fn wordSet(comptime words: []const []const u8) type {
    comptime var entries: [words.len]struct { []const u8, void } = undefined;
    inline for (words, 0..) |word, index| entries[index] = .{ word, {} };
    const final = entries;
    return struct {
        const map = std.StaticStringMap(void).initComptime(final);
        fn has(word: []const u8) bool {
            return map.has(word);
        }
    };
}

// Reserved words are always keywords.
const KeywordSet = wordSet(&.{
    "all",          "alter",      "analyze",   "and",           "any",
    "array",        "as",         "asc",       "authorization", "autoincrement",
    "begin",        "between",    "by",        "cascade",       "case",
    "cast",         "check",      "collate",   "column",        "commit",
    "concurrently", "constraint", "create",    "cross",         "cube",
    "deallocate",   "declare",    "default",   "deferrable",    "deferred",
    "delete",       "desc",       "distinct",  "do",            "drop",
    "else",         "end",        "escape",    "except",        "exclusive",
    "execute",      "exists",     "explain",   "fetch",         "following",
    "for",          "foreign",    "from",      "full",          "function",
    "glob",         "grant",      "group",     "grouping",      "having",
    "if",           "ilike",      "immediate", "in",            "inner",
    "insert",       "intersect",  "into",      "is",            "isnull",
    "join",         "lateral",    "left",      "like",          "limit",
    "materialized", "merge",      "natural",   "not",           "nothing",
    "notnull",      "offset",     "on",        "only",          "or",
    "order",        "others",     "outer",     "over",          "overlaps",
    "partition",    "pragma",     "preceding", "primary",       "procedure",
    "recursive",    "references", "regexp",    "reindex",       "restrict",
    "returning",    "returns",    "revoke",    "right",         "rollback",
    "rollup",       "savepoint",  "select",    "set",           "similar",
    "some",         "table",      "then",      "ties",          "to",
    "transaction",  "trigger",    "truncate",  "unbounded",     "union",
    "unique",       "update",     "upsert",    "using",         "vacuum",
    "values",       "when",       "where",     "window",        "with",
    "within",       "without",
});

// Words that are often column or table names too (`first`, `key`, `rows`,
// `view`...). They are keywords only next to a partner word from PhraseSet,
// as in `PRIMARY KEY`, `NULLS LAST` or `CREATE VIEW`; otherwise plain.
const ContextualSet = wordSet(&.{
    "abort",    "action",  "add",       "after",     "always",
    "attach",   "before",  "conflict",  "current",   "cursor",
    "database", "detach",  "each",      "exclude",   "extension",
    "filter",   "first",   "generated", "groups",    "identity",
    "ignore",   "index",   "instead",   "key",       "language",
    "last",     "local",   "lock",      "no",        "nulls",
    "of",       "plan",    "prepare",   "range",     "release",
    "rename",   "replace", "row",       "rows",      "schema",
    "sequence", "sets",    "temp",      "temporary", "top",
    "view",     "virtual",
});

// Two-word phrases, lowercase, joined by one space.
const PhraseSet = wordSet(&.{
    "primary key",       "foreign key",      "nulls first",         "nulls last",
    "asc nulls",         "desc nulls",       "on conflict",         "no action",
    "exclude no",        "no others",        "add column",          "add constraint",
    "add primary",       "add foreign",      "add unique",          "add check",
    "rename to",         "rename column",    "rename constraint",   "or replace",
    "or ignore",         "or abort",         "insert ignore",       "replace into",
    "replace view",      "current row",      "current of",          "exclude current",
    "exclude ties",      "exclude group",    "exclude using",       "rows between",
    "rows unbounded",    "rows current",     "rows only",           "first rows",
    "range between",     "range unbounded",  "range current",       "groups between",
    "groups unbounded",  "groups current",   "fetch first",         "first row",
    "row only",          "each row",         "for each",            "create view",
    "drop view",         "alter view",       "materialized view",   "recursive view",
    "temp view",         "temporary view",   "create index",        "drop index",
    "alter index",       "unique index",     "index if",            "index concurrently",
    "reindex index",     "create temp",      "create temporary",    "temp table",
    "temporary table",   "create schema",    "drop schema",         "alter schema",
    "schema if",         "create sequence",  "drop sequence",       "alter sequence",
    "sequence if",       "create extension", "drop extension",      "alter extension",
    "extension if",      "create database",  "drop database",       "alter database",
    "attach database",   "detach database",  "attach partition",    "detach partition",
    "create virtual",    "virtual table",    "generated always",    "generated by",
    "always as",         "as identity",      "filter where",        "before insert",
    "before update",     "before delete",    "before truncate",     "after insert",
    "after update",      "after delete",     "after truncate",      "instead of",
    "update of",         "grouping sets",    "query plan",          "release savepoint",
    "set local",         "lock table",       "prepare transaction", "cursor for",
    "select top",        "language sql",     "language plpgsql",    "language c",
    "language internal",
});

const TypeSet = wordSet(&.{
    "bigint",      "bigserial", "binary",    "bit",       "blob",
    "bool",        "boolean",   "bytea",     "char",      "character",
    "cidr",        "clob",      "date",      "datetime",  "decimal",
    "double",      "float",     "float4",    "float8",    "inet",
    "int",         "int2",      "int4",      "int8",      "integer",
    "interval",    "json",      "jsonb",     "money",     "nchar",
    "numeric",     "nvarchar",  "real",      "serial",    "smallint",
    "smallserial", "text",      "time",      "timestamp", "timestamptz",
    "tinyint",     "uuid",      "varbinary", "varchar",   "xml",
});

const LiteralSet = wordSet(&.{ "false", "null", "true", "unknown" });

const FunctionSet = wordSet(&.{
    "abs",          "array_agg",    "avg",                "ceil",      "ceiling",
    "char_length",  "coalesce",     "concat",             "count",     "cume_dist",
    "current_date", "current_time", "current_timestamp",  "date_part", "date_trunc",
    "dense_rank",   "extract",      "first_value",        "floor",     "format",
    "greatest",     "group_concat", "ifnull",             "json_agg",  "json_build_object",
    "json_extract", "jsonb_agg",    "jsonb_build_object", "lag",       "last_value",
    "lead",         "least",        "length",             "lower",     "ltrim",
    "max",          "min",          "mod",                "now",       "nth_value",
    "ntile",        "nullif",       "percent_rank",       "position",  "power",
    "random",       "rank",         "regexp_replace",     "round",     "row_number",
    "rtrim",        "sqrt",         "string_agg",         "strftime",  "substr",
    "substring",    "sum",          "to_char",            "to_date",   "trim",
    "unnest",       "upper",
});

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Writer, byte: u8) void {
        if (self.overflow) return;
        if (self.idx == output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = byte;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, bytes: []const u8) void {
        if (self.overflow or bytes.len == 0) return;
        if (bytes.len > output_buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + bytes.len], bytes);
        self.idx += bytes.len;
    }

    fn writeSpan(self: *Writer, class_name: []const u8, text: []const u8) void {
        self.openSpan(class_name);
        self.writeSlice(text);
        self.closeSpan();
    }

    fn openSpan(self: *Writer, class_name: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
    }

    fn closeSpan(self: *Writer) void {
        self.writeSlice("</span>");
    }
};

const CodeTag = struct {
    end: usize,
    is_sql: bool,
    has_hljs: bool,
};

const CloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_sql: bool = false,
    has_hljs: bool = false,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
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

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (lower(left) != lower(right)) return false;
    }
    return true;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isNameBoundary(byte: u8) bool {
    return byte == '>' or byte == '/' or isSpace(byte);
}

fn isAttrChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':';
}

fn isIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentContinue(byte: u8) bool {
    return isIdentStart(byte) or std.ascii.isDigit(byte);
}

fn classInfo(value: []const u8) ClassInfo {
    var result = ClassInfo{};
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (start == i) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-sql")) result.is_sql = true;
        if (eqlIgnoreCase(token, "hljs")) result.has_hljs = true;
    }
    return result;
}

fn tagEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        if (quote != 0) {
            if (input[i] == quote) quote = 0;
        } else if (input[i] == '"' or input[i] == '\'') {
            quote = input[i];
        } else if (input[i] == '>') {
            return i;
        }
    }
    return null;
}

fn classRange(tag: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 5;
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }
        const name_start = i;
        while (i < tag.len and isAttrChar(tag[i])) : (i += 1) {}
        if (name_start == i) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len) break;
        var start = i;
        var end = i;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            i += 1;
            start = i;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            end = i;
            if (i < tag.len) i += 1;
        } else {
            start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
            end = i;
        }
        if (eqlIgnoreCase(name, "class")) return .{ .start = start, .end = end };
    }
    return null;
}

fn parseOpenTag(input: []const u8, start: usize) ?CodeTag {
    if (start + 5 > input.len or input[start] != '<') return null;
    if (!eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isNameBoundary(input[start + 5])) return null;
    const end = tagEnd(input, start + 5) orelse return null;
    const tag = input[start .. end + 1];
    const range = classRange(tag) orelse return .{ .end = end, .is_sql = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_sql = info.is_sql, .has_hljs = info.has_hljs };
}

fn closeTag(input: []const u8, start: usize) ?CloseTag {
    var i = start;
    while (i + 7 <= input.len) : (i += 1) {
        if (input[i] != '<' or input[i + 1] != '/') continue;
        if (!eqlIgnoreCase(input[i + 2 .. i + 6], "code")) continue;
        var end = i + 6;
        if (end < input.len and !isNameBoundary(input[end])) continue;
        while (end < input.len and isSpace(input[end])) : (end += 1) {}
        if (end < input.len and input[end] == '>') return .{ .start = i, .end = end };
    }
    return null;
}

fn containsSpanTag(code: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= code.len) : (i += 1) {
        if (code[i] != '<') continue;
        if (!eqlIgnoreCase(code[i + 1 .. i + 5], "span")) continue;
        if (i + 5 == code.len or isNameBoundary(code[i + 5])) return true;
    }
    return false;
}

fn writeOpenTag(tag: []const u8, writer: *Writer) void {
    const range = classRange(tag) orelse {
        writer.writeSlice(tag);
        return;
    };
    writer.writeSlice(tag[0..range.end]);
    if (range.start != range.end) writer.writeByte(' ');
    writer.writeSlice("hljs");
    writer.writeSlice(tag[range.end..]);
}

const Quote = struct {
    byte: u8,
    len: usize,
};

// Recognises a quote written literally or as one of the character references
// an HTML escaper produces for it.
fn quoteAt(code: []const u8, start: usize) ?Quote {
    if (start >= code.len) return null;
    if (code[start] == '"' or code[start] == '\'' or code[start] == '`') {
        return .{ .byte = code[start], .len = 1 };
    }
    if (code[start] != '&') return null;
    const references = [_]struct { text: []const u8, byte: u8 }{
        .{ .text = "&quot;", .byte = '"' },
        .{ .text = "&#34;", .byte = '"' },
        .{ .text = "&#x22;", .byte = '"' },
        .{ .text = "&#39;", .byte = '\'' },
        .{ .text = "&#x27;", .byte = '\'' },
        .{ .text = "&apos;", .byte = '\'' },
        .{ .text = "&#96;", .byte = '`' },
        .{ .text = "&#x60;", .byte = '`' },
    };
    for (references) |reference| {
        if (start + reference.text.len <= code.len and
            eqlIgnoreCase(code[start .. start + reference.text.len], reference.text))
        {
            return .{ .byte = reference.byte, .len = reference.text.len };
        }
    }
    return null;
}

// SQL escapes a quote by doubling it, so `'it''s'` is one string. With
// `backslash` set (E'...' strings) a backslash also escapes the next byte.
fn quotedEnd(code: []const u8, start: usize, quote: Quote, backslash: bool) usize {
    var i = start + quote.len;
    while (i < code.len) {
        if (backslash and code[i] == '\\') {
            i += 1;
            if (i < code.len) {
                if (quoteAt(code, i)) |escaped| {
                    i += escaped.len;
                } else {
                    i += 1;
                }
            }
            continue;
        }
        if (quoteAt(code, i)) |candidate| {
            if (candidate.byte == quote.byte) {
                const after = i + candidate.len;
                if (quoteAt(code, after)) |next| {
                    if (next.byte == quote.byte) {
                        i = after + next.len;
                        continue;
                    }
                }
                return after;
            }
            i += candidate.len;
            continue;
        }
        i += 1;
    }
    return code.len;
}

// Returns the end of an HTML character reference such as `&lt;` or `&#x3C;`,
// so its letters are never read as keywords.
fn entityEnd(code: []const u8, start: usize) ?usize {
    if (start >= code.len or code[start] != '&') return null;
    var i = start + 1;
    if (i < code.len and code[i] == '#') i += 1;
    const name_start = i;
    while (i < code.len and i - start <= 32 and std.ascii.isAlphanumeric(code[i])) : (i += 1) {}
    if (i == name_start or i >= code.len or code[i] != ';') return null;
    return i + 1;
}

// PostgreSQL and the SQL standard let block comments nest.
fn blockCommentEnd(code: []const u8, start: usize) usize {
    var depth: usize = 1;
    var i = start + 2;
    while (i + 1 < code.len) {
        if (code[i] == '/' and code[i + 1] == '*') {
            depth += 1;
            i += 2;
            continue;
        }
        if (code[i] == '*' and code[i + 1] == '/') {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return code.len;
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    if (i + 1 < code.len and code[i] == '0' and (code[i + 1] == 'x' or code[i + 1] == 'X')) {
        i += 2;
        while (i < code.len and (std.ascii.isHex(code[i]) or code[i] == '_')) : (i += 1) {}
        return i;
    }
    while (i < code.len and (std.ascii.isDigit(code[i]) or code[i] == '_')) : (i += 1) {}
    if (i < code.len and code[i] == '.' and !(i + 1 < code.len and code[i + 1] == '.')) {
        i += 1;
        while (i < code.len and (std.ascii.isDigit(code[i]) or code[i] == '_')) : (i += 1) {}
    }
    if (i < code.len and (code[i] == 'e' or code[i] == 'E')) {
        var exponent = i + 1;
        if (exponent < code.len and (code[exponent] == '+' or code[exponent] == '-')) exponent += 1;
        if (exponent < code.len and std.ascii.isDigit(code[exponent])) {
            i = exponent;
            while (i < code.len and std.ascii.isDigit(code[i])) : (i += 1) {}
        }
    }
    return i;
}

// PostgreSQL dollar quoting: `$$ body $$` or `$fn$ body $fn$`.
fn dollarQuoteEnd(code: []const u8, start: usize) ?usize {
    var tag_end = start + 1;
    if (tag_end < code.len and isIdentStart(code[tag_end])) {
        while (tag_end < code.len and isIdentContinue(code[tag_end])) : (tag_end += 1) {}
    }
    if (tag_end >= code.len or code[tag_end] != '$') return null;
    const tag = code[start .. tag_end + 1];
    const close = std.mem.indexOfPos(u8, code, tag_end + 1, tag) orelse return code.len;
    return close + tag.len;
}

fn isWordByte(byte: u8) bool {
    return isIdentContinue(byte) or byte == '$';
}

fn identifierEnd(code: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < code.len and isWordByte(code[end])) : (end += 1) {}
    return end;
}

fn skipSpace(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len and isSpace(code[i])) : (i += 1) {}
    return i;
}

// Word lists are lowercase; SQL keywords are case-insensitive.
fn lookupLower(comptime Set: type, word: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (word.len > buf.len) return false;
    for (word, 0..) |byte, index| buf[index] = lower(byte);
    return Set.has(buf[0..word.len]);
}

// The word just before `start`, separated only by spaces.
fn previousWord(code: []const u8, start: usize) []const u8 {
    var end = start;
    while (end > 0 and isSpace(code[end - 1])) : (end -= 1) {}
    var begin = end;
    while (begin > 0 and isWordByte(code[begin - 1])) : (begin -= 1) {}
    return code[begin..end];
}

// The word after `start`, separated by spaces and at most one `(`, so that
// `FILTER (WHERE` pairs up.
fn nextWord(code: []const u8, start: usize) []const u8 {
    var i = skipSpace(code, start);
    if (i < code.len and code[i] == '(') i = skipSpace(code, i + 1);
    if (i >= code.len or !isIdentStart(code[i])) return "";
    return code[i..identifierEnd(code, i)];
}

fn isPhrase(first: []const u8, second: []const u8) bool {
    var buf: [48]u8 = undefined;
    if (first.len == 0 or second.len == 0 or first.len + 1 + second.len > buf.len) return false;
    for (first, 0..) |byte, index| buf[index] = lower(byte);
    buf[first.len] = ' ';
    for (second, 0..) |byte, index| buf[first.len + 1 + index] = lower(byte);
    return PhraseSet.has(buf[0 .. first.len + 1 + second.len]);
}

fn writeSql(code: []const u8, writer: *Writer) void {
    var i: usize = 0;
    while (i < code.len) {
        const byte = code[i];
        if (i + 1 < code.len and byte == '-' and code[i + 1] == '-') {
            var end = i + 2;
            while (end < code.len and code[end] != '\n') : (end += 1) {}
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (i + 1 < code.len and byte == '/' and code[i + 1] == '*') {
            const end = blockCommentEnd(code, i);
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            const end = quotedEnd(code, i, quote, false);
            if (quote.byte == '\'') {
                writer.writeSpan("hljs-string", code[i..end]);
            } else {
                // "quoted" and `quoted` names are identifiers: plain, but read
                // whole so keywords inside them stay plain.
                writer.writeSlice(code[i..end]);
            }
            i = end;
            continue;
        }
        if (entityEnd(code, i)) |end| {
            writer.writeSlice(code[i..end]);
            i = end;
            continue;
        }
        if (byte == '$') {
            if (dollarQuoteEnd(code, i)) |end| {
                writer.writeSpan("hljs-string", code[i..end]);
                i = end;
                continue;
            }
            if (i + 1 < code.len and std.ascii.isDigit(code[i + 1])) {
                var end = i + 1;
                while (end < code.len and std.ascii.isDigit(code[end])) : (end += 1) {}
                writer.writeSpan("hljs-variable", code[i..end]);
                i = end;
                continue;
            }
        }
        if (byte == '@' and i + 1 < code.len) {
            var name = i + 1;
            if (code[name] == '@') name += 1;
            if (name < code.len and isIdentStart(code[name])) {
                const end = identifierEnd(code, name);
                writer.writeSpan("hljs-variable", code[i..end]);
                i = end;
                continue;
            }
        }
        // `:name` bind parameters, but not PostgreSQL `::type` casts.
        if (byte == ':' and i + 1 < code.len and isIdentStart(code[i + 1]) and
            (i == 0 or (code[i - 1] != ':' and !isWordByte(code[i - 1]))))
        {
            const end = identifierEnd(code, i + 1);
            writer.writeSpan("hljs-variable", code[i..end]);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(byte) or
            (byte == '.' and i + 1 < code.len and std.ascii.isDigit(code[i + 1]) and (i == 0 or !isWordByte(code[i - 1]))))
        {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (isIdentStart(byte)) {
            const end = identifierEnd(code, i);
            const word = code[i..end];
            // E'...' strings allow backslash escapes; N'...', B'...' and
            // X'...' prefixes belong to the string.
            if (word.len == 1) {
                if (quoteAt(code, end)) |quote| {
                    const prefix = lower(byte);
                    if (quote.byte == '\'' and (prefix == 'e' or prefix == 'n' or prefix == 'b' or prefix == 'x')) {
                        const string_end = quotedEnd(code, end, quote, prefix == 'e');
                        writer.writeSpan("hljs-string", code[i..string_end]);
                        i = string_end;
                        continue;
                    }
                }
            }
            // Qualified names such as `orders.date` keep their parts plain.
            const after_dot = i > 0 and code[i - 1] == '.';
            const before_dot = end + 1 < code.len and code[end] == '.' and
                (isIdentStart(code[end + 1]) or code[end + 1] == '*' or quoteAt(code, end + 1) != null);
            if (after_dot or before_dot) {
                writer.writeSlice(word);
                i = end;
                continue;
            }
            const next = skipSpace(code, end);
            const is_call = next < code.len and code[next] == '(';
            if (lookupLower(LiteralSet, word)) {
                writer.writeSpan("hljs-literal", word);
            } else if (lookupLower(TypeSet, word)) {
                writer.writeSpan("hljs-type", word);
            } else if (is_call and lookupLower(FunctionSet, word)) {
                writer.writeSpan("hljs-built_in", word);
            } else if (lookupLower(KeywordSet, word)) {
                writer.writeSpan("hljs-keyword", word);
            } else if (lookupLower(ContextualSet, word) and
                (isPhrase(previousWord(code, i), word) or isPhrase(word, nextWord(code, end))))
            {
                writer.writeSpan("hljs-keyword", word);
            } else {
                writer.writeSlice(word);
            }
            i = end;
            continue;
        }
        writer.writeByte(byte);
        i += 1;
    }
}

fn transform(input: []const u8, writer: *Writer) void {
    var copied: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        const open = parseOpenTag(input, i) orelse {
            i += 1;
            continue;
        };
        writer.writeSlice(input[copied..i]);
        const close = closeTag(input, open.end + 1) orelse {
            writer.writeSlice(input[i..]);
            return;
        };
        const code = input[open.end + 1 .. close.start];
        if (!open.is_sql or open.has_hljs or containsSpanTag(code)) {
            writer.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenTag(input[i .. open.end + 1], writer);
            writeSql(code, writer);
            writer.writeSlice(input[close.start .. close.end + 1]);
        }
        copied = close.end + 1;
        i = copied;
    }
    writer.writeSlice(input[copied..]);
}

fn renderImpl(input_size: u32) u32 {
    const len: usize = @intCast(input_size);
    if (len > INPUT_CAP) @trap();
    var writer = Writer{};
    transform(input_buf[0..len], &writer);
    if (writer.overflow) @trap();
    return @intCast(writer.idx);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn runForTest(input: []const u8) []const u8 {
    @memcpy(input_buf[0..input.len], input);
    return output_buf[0..renderImpl(@intCast(input.len))];
}

test "highlights keywords functions types and literals case-insensitively" {
    const input = "<code class=\"language-sql\">SELECT id, COUNT(*) AS total FROM orders WHERE paid IS NOT NULL AND amount &gt; 10.5 GROUP BY id;\ncreate table t (n integer default 0, ok boolean default TRUE);</code>";
    const expected = "<code class=\"language-sql hljs\"><span class=\"hljs-keyword\">SELECT</span> id, <span class=\"hljs-built_in\">COUNT</span>(*) <span class=\"hljs-keyword\">AS</span> total <span class=\"hljs-keyword\">FROM</span> orders <span class=\"hljs-keyword\">WHERE</span> paid <span class=\"hljs-keyword\">IS</span> <span class=\"hljs-keyword\">NOT</span> <span class=\"hljs-literal\">NULL</span> <span class=\"hljs-keyword\">AND</span> amount &gt; <span class=\"hljs-number\">10.5</span> <span class=\"hljs-keyword\">GROUP</span> <span class=\"hljs-keyword\">BY</span> id;\n<span class=\"hljs-keyword\">create</span> <span class=\"hljs-keyword\">table</span> t (n <span class=\"hljs-type\">integer</span> <span class=\"hljs-keyword\">default</span> <span class=\"hljs-number\">0</span>, ok <span class=\"hljs-type\">boolean</span> <span class=\"hljs-keyword\">default</span> <span class=\"hljs-literal\">TRUE</span>);</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "keeps function names without calls and qualified names plain" {
    const input = "<code class=\"language-sql\">select o.date, o.order, count from orders o</code>";
    const expected = "<code class=\"language-sql hljs\"><span class=\"hljs-keyword\">select</span> o.date, o.order, count <span class=\"hljs-keyword\">from</span> orders o</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights strings comments and quoted identifiers" {
    const input = "<code class=\"language-sql\">-- select\n/* outer /* from */ where */ SELECT &#39;it&#39;&#39;s&#39;, E&#39;a\\&#39;b&#39;, &quot;select&quot;, `from` FROM t</code>";
    const expected = "<code class=\"language-sql hljs\"><span class=\"hljs-comment\">-- select</span>\n<span class=\"hljs-comment\">/* outer /* from */ where */</span> <span class=\"hljs-keyword\">SELECT</span> <span class=\"hljs-string\">&#39;it&#39;&#39;s&#39;</span>, <span class=\"hljs-string\">E&#39;a\\&#39;b&#39;</span>, &quot;select&quot;, `from` <span class=\"hljs-keyword\">FROM</span> t</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights parameters casts and dollar-quoted bodies" {
    const input = "<code class=\"language-sql\">select $1::int, :name, @total, x::text from t;\ncreate function f() returns int as $$ select 1 $$ language sql;</code>";
    const expected = "<code class=\"language-sql hljs\"><span class=\"hljs-keyword\">select</span> <span class=\"hljs-variable\">$1</span>::<span class=\"hljs-type\">int</span>, <span class=\"hljs-variable\">:name</span>, <span class=\"hljs-variable\">@total</span>, x::<span class=\"hljs-type\">text</span> <span class=\"hljs-keyword\">from</span> t;\n<span class=\"hljs-keyword\">create</span> <span class=\"hljs-keyword\">function</span> f() <span class=\"hljs-keyword\">returns</span> <span class=\"hljs-type\">int</span> <span class=\"hljs-keyword\">as</span> <span class=\"hljs-string\">$$ select 1 $$</span> <span class=\"hljs-keyword\">language</span> sql;</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights name-like words only inside keyword phrases" {
    const input = "<code class=\"language-sql\">select first, last, key, rows from view order by last nulls last;\ncreate table t (id int primary key, add text);\ncount(*) filter (where ok)</code>";
    const expected = "<code class=\"language-sql hljs\"><span class=\"hljs-keyword\">select</span> first, last, key, rows <span class=\"hljs-keyword\">from</span> view <span class=\"hljs-keyword\">order</span> <span class=\"hljs-keyword\">by</span> last <span class=\"hljs-keyword\">nulls</span> <span class=\"hljs-keyword\">last</span>;\n<span class=\"hljs-keyword\">create</span> <span class=\"hljs-keyword\">table</span> t (id <span class=\"hljs-type\">int</span> <span class=\"hljs-keyword\">primary</span> <span class=\"hljs-keyword\">key</span>, add <span class=\"hljs-type\">text</span>);\n<span class=\"hljs-built_in\">count</span>(*) <span class=\"hljs-keyword\">filter</span> (<span class=\"hljs-keyword\">where</span> ok)</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "leaves HTML character references alone" {
    const input = "<code class=\"language-sql\">a &lt;&gt; b &amp;&amp; c &#x3C; 1</code>";
    const expected = "<code class=\"language-sql hljs\">a &lt;&gt; b &amp;&amp; c &#x3C; <span class=\"hljs-number\">1</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted blocks and other languages" {
    const highlighted = "<code class=\"language-sql\"><span class=\"hljs-keyword\">select</span> 1</code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const go = "<code class=\"language-go\">select { case x: }</code>";
    try std.testing.expectEqualStrings(go, runForTest(go));
}
