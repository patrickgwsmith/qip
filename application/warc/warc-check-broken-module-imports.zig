const std = @import("std");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";

const MODULE_TABLE_CAP: usize = 65536;
const EXPORT_NAME_CAP: usize = 16384;
const IMPORT_NAME_CAP: usize = 64;

var input_buf: [INPUT_CAP]u8 = undefined;

const ModuleEntry = struct {
    used: bool = false,
    path: []const u8 = "",
    status: u16 = 0,
    content_type: []const u8 = "",
    body: []const u8 = "",
    is_js: bool = false,
    export_start: usize = 0,
    export_count: usize = 0,
};

const NameList = struct {
    names: [IMPORT_NAME_CAP][]const u8 = undefined,
    count: usize = 0,
    overflow: bool = false,

    fn add(self: *NameList, name_raw: []const u8) void {
        const name = trimASCIIWhitespace(name_raw);
        if (name.len == 0) return;
        for (self.names[0..self.count]) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        if (self.count >= self.names.len) {
            self.overflow = true;
            return;
        }
        self.names[self.count] = name;
        self.count += 1;
    }
};

const ValidationSummary = struct {
    module_scripts: usize,
    checked_imports: usize,
    broken_imports: usize,
    page_count: usize,
};

var module_table: [MODULE_TABLE_CAP]ModuleEntry = undefined;
var export_names: [EXPORT_NAME_CAP][]const u8 = undefined;
var export_name_count: usize = 0;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

const WARCRecord = struct {
    next: usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn trimASCIIWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) : (start += 1) {
        const c = s[start];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    while (end > start) : (end -= 1) {
        const c = s[end - 1];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    return s[start..end];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isTagNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == ':';
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentifierChar(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

fn keywordAt(s: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > s.len) return false;
    if (!std.mem.eql(u8, s[pos .. pos + keyword.len], keyword)) return false;
    if (pos > 0 and isIdentifierChar(s[pos - 1])) return false;
    if (pos + keyword.len < s.len and isIdentifierChar(s[pos + keyword.len])) return false;
    return true;
}

fn findHeaderEnd(buf: []const u8, start: usize) ?struct { end: usize, delim_len: usize } {
    if (start >= buf.len) return null;
    if (std.mem.indexOfPos(u8, buf, start, "\r\n\r\n")) |pos| {
        return .{ .end = pos + 4, .delim_len = 4 };
    }
    if (std.mem.indexOfPos(u8, buf, start, "\n\n")) |pos| {
        return .{ .end = pos + 2, .delim_len = 2 };
    }
    return null;
}

fn parseUnsigned10(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var value: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + @as(usize, c - '0');
    }
    return value;
}

fn parseStatusCode(line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    if (i >= line.len) return null;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const code_start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == code_start) return null;
    const code = parseUnsigned10(line[code_start..i]) orelse return null;
    if (code > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(code));
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const head = findHeaderEnd(input, start) orelse return null;
    const header_slice = input[start..head.end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl_rel = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < header_slice.len) nl_rel + 1 else header_slice.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "WARC-Type")) {
            warc_type = value;
        } else if (eqlIgnoreCase(key, "WARC-Target-URI")) {
            target_uri = value;
        } else if (eqlIgnoreCase(key, "Content-Length")) {
            content_length = parseUnsigned10(value);
        }
    }

    const payload_len = content_length orelse return null;
    if (head.end + payload_len > input.len) return null;
    const payload = input[head.end .. head.end + payload_len];

    var next = head.end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{ .next = next, .warc_type = warc_type, .target_uri = target_uri, .payload = payload };
}

fn parseHTTPMeta(payload: []const u8) ?HTTPMeta {
    const head = findHeaderEnd(payload, 0) orelse return null;
    const header_slice = payload[0..head.end];
    var status: ?u16 = null;
    var content_type: []const u8 = "";

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl_rel = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < header_slice.len) nl_rel + 1 else header_slice.len;
        if (line.len == 0) break;

        if (line_index == 0) {
            status = parseStatusCode(line);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "Content-Type")) content_type = value;
    }

    return .{ .status = status orelse return null, .content_type = content_type, .body = payload[head.end..] };
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return trimASCIIWhitespace(content_type[0..end]);
}

fn isHTMLContentType(content_type_raw: []const u8) bool {
    const content_type = mimeTypeToken(content_type_raw);
    return eqlIgnoreCase(content_type, "text/html") or eqlIgnoreCase(content_type, "application/xhtml+xml");
}

fn isJSContentType(content_type_raw: []const u8) bool {
    const content_type = mimeTypeToken(content_type_raw);
    return eqlIgnoreCase(content_type, "text/javascript") or
        eqlIgnoreCase(content_type, "application/javascript") or
        eqlIgnoreCase(content_type, "text/ecmascript") or
        eqlIgnoreCase(content_type, "application/ecmascript");
}

fn pathFromTargetURI(uri: []const u8) []const u8 {
    if (uri.len == 0) return "/";

    var path = uri;
    if (std.mem.indexOf(u8, uri, "://")) |scheme_sep| {
        const after_scheme = scheme_sep + 3;
        if (std.mem.indexOfPos(u8, uri, after_scheme, "/")) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (std.mem.startsWith(u8, uri, "//")) {
        if (std.mem.indexOfPos(u8, uri, 2, "/")) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (uri[0] != '/') {
        if (std.mem.indexOfScalar(u8, uri, '/')) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    }

    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, path, '#')) |pos| end = @min(end, pos);
    path = path[0..end];
    if (path.len == 0) return "/";
    if (path[0] != '/') return "/";
    return path;
}

fn cutPathPart(raw: []const u8) []const u8 {
    var end = raw.len;
    if (std.mem.indexOfScalar(u8, raw, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, raw, '#')) |idx| end = @min(end, idx);
    return raw[0..end];
}

fn canonicalizePath(path_raw: []const u8, out_buf: []u8) ?[]const u8 {
    if (path_raw.len == 0 or path_raw[0] != '/') return null;
    if (out_buf.len == 0) return null;

    out_buf[0] = '/';
    var out_len: usize = 1;
    var i: usize = 1;
    while (true) {
        while (i < path_raw.len and path_raw[i] == '/') : (i += 1) {}
        if (i >= path_raw.len) break;

        const seg_start = i;
        while (i < path_raw.len and path_raw[i] != '/') : (i += 1) {}
        const seg = path_raw[seg_start..i];
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (out_len > 1) {
                out_len -= 1;
                while (out_len > 0 and out_buf[out_len - 1] != '/') : (out_len -= 1) {}
            }
            continue;
        }

        if (out_len > 1 and out_buf[out_len - 1] != '/') {
            if (out_len >= out_buf.len) return null;
            out_buf[out_len] = '/';
            out_len += 1;
        }
        if (out_len + seg.len > out_buf.len) return null;
        @memcpy(out_buf[out_len .. out_len + seg.len], seg);
        out_len += seg.len;
    }

    if (out_len == 0) return null;
    return out_buf[0..out_len];
}

fn pathHash(path: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (path) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

fn clearModuleTable() void {
    for (&module_table) |*entry| entry.* = .{};
    export_name_count = 0;
}

fn moduleTableInsert(path: []const u8, status: u16, content_type: []const u8, body: []const u8, is_js: bool) ?*ModuleEntry {
    if (path.len == 0) return null;
    var idx: usize = @as(usize, @intCast(pathHash(path) % MODULE_TABLE_CAP));
    var probes: usize = 0;
    while (probes < MODULE_TABLE_CAP) : (probes += 1) {
        const entry = &module_table[idx];
        if (!entry.used or std.mem.eql(u8, entry.path, path)) {
            entry.* = .{
                .used = true,
                .path = path,
                .status = status,
                .content_type = content_type,
                .body = body,
                .is_js = is_js,
                .export_start = export_name_count,
                .export_count = 0,
            };
            return entry;
        }
        idx = (idx + 1) % MODULE_TABLE_CAP;
    }
    return null;
}

fn moduleTableLookup(path: []const u8) ?*ModuleEntry {
    if (path.len == 0) return null;
    var idx: usize = @as(usize, @intCast(pathHash(path) % MODULE_TABLE_CAP));
    var probes: usize = 0;
    while (probes < MODULE_TABLE_CAP) : (probes += 1) {
        const entry = &module_table[idx];
        if (!entry.used) return null;
        if (std.mem.eql(u8, entry.path, path)) return entry;
        idx = (idx + 1) % MODULE_TABLE_CAP;
    }
    return null;
}

fn addExportName(entry: *ModuleEntry, name_raw: []const u8) bool {
    const name = trimASCIIWhitespace(name_raw);
    if (name.len == 0) return true;
    for (export_names[entry.export_start .. entry.export_start + entry.export_count]) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    if (export_name_count >= export_names.len) return false;
    export_names[export_name_count] = name;
    export_name_count += 1;
    entry.export_count += 1;
    return true;
}

fn moduleHasExport(entry: *const ModuleEntry, name: []const u8) bool {
    for (export_names[entry.export_start .. entry.export_start + entry.export_count]) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn skipQuoted(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return pos;
    const quote = s[pos];
    var i = pos + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == quote) return i + 1;
    }
    return s.len;
}

fn skipJSWhitespaceAndComments(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        while (i < s.len and isSpace(s[i])) : (i += 1) {}
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '/') {
            i += 2;
            while (i < s.len and s[i] != '\n') : (i += 1) {}
            continue;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "*/")) |end| {
                i = end + 2;
                continue;
            }
            return s.len;
        }
        break;
    }
    return i;
}

fn findStatementEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '"' or s[i] == '\'' or s[i] == '`') {
            i = skipQuoted(s, i);
            if (i >= s.len) return s.len;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '/') {
            while (i < s.len and s[i] != '\n') : (i += 1) {}
            continue;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "*/")) |end| {
                i = end + 1;
                continue;
            }
            return s.len;
        }
        if (s[i] == ';') return i + 1;
    }
    return s.len;
}

fn findKeyword(s: []const u8, keyword: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '"' or s[i] == '\'' or s[i] == '`') {
            i = skipQuoted(s, i);
            if (i >= s.len) return null;
            continue;
        }
        if (keywordAt(s, i, keyword)) return i;
    }
    return null;
}

fn parseIdentifier(s: []const u8, start: usize) ?struct { name: []const u8, next: usize } {
    var i = skipJSWhitespaceAndComments(s, start);
    if (i >= s.len or !isIdentifierStart(s[i])) return null;
    const name_start = i;
    i += 1;
    while (i < s.len and isIdentifierChar(s[i])) : (i += 1) {}
    return .{ .name = s[name_start..i], .next = i };
}

fn parseStringLiteralAt(s: []const u8, start: usize) ?struct { value: []const u8, next: usize } {
    var i = skipJSWhitespaceAndComments(s, start);
    if (i >= s.len or (s[i] != '"' and s[i] != '\'')) return null;
    const quote = s[i];
    i += 1;
    const value_start = i;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            return null;
        }
        if (s[i] == quote) {
            return .{ .value = s[value_start..i], .next = i + 1 };
        }
    }
    return null;
}

fn parseNamedList(list_raw: []const u8, source_names: bool) NameList {
    var list = NameList{};
    var start: usize = 0;
    while (start < list_raw.len) {
        var end = start;
        while (end < list_raw.len and list_raw[end] != ',') : (end += 1) {}
        const part = trimASCIIWhitespace(list_raw[start..end]);
        if (part.len != 0) {
            if (findKeyword(part, "as")) |as_pos| {
                if (source_names) {
                    list.add(part[0..as_pos]);
                } else {
                    list.add(part[as_pos + "as".len ..]);
                }
            } else {
                list.add(part);
            }
        }
        start = if (end < list_raw.len) end + 1 else list_raw.len;
    }
    return list;
}

fn parseImportNames(statement_after_import: []const u8) NameList {
    var names = NameList{};
    const from_pos = findKeyword(statement_after_import, "from") orelse return names;
    const clause = trimASCIIWhitespace(statement_after_import[0..from_pos]);
    if (clause.len == 0) return names;

    if (clause[0] != '{' and clause[0] != '*') {
        names.add("default");
    }

    if (std.mem.indexOfScalar(u8, clause, '{')) |open| {
        if (std.mem.lastIndexOfScalar(u8, clause, '}')) |close| {
            if (close > open) {
                var named = parseNamedList(clause[open + 1 .. close], true);
                for (named.names[0..named.count]) |name| names.add(name);
                if (named.overflow) names.overflow = true;
            }
        }
    }

    return names;
}

fn importSpecifier(statement_after_import: []const u8) ?[]const u8 {
    const i = skipJSWhitespaceAndComments(statement_after_import, 0);
    if (i < statement_after_import.len and (statement_after_import[i] == '"' or statement_after_import[i] == '\'')) {
        return (parseStringLiteralAt(statement_after_import, i) orelse return null).value;
    }
    const from_pos = findKeyword(statement_after_import, "from") orelse return null;
    return (parseStringLiteralAt(statement_after_import, from_pos + "from".len) orelse return null).value;
}

fn exportFromSpecifier(statement_after_export: []const u8) ?[]const u8 {
    const from_pos = findKeyword(statement_after_export, "from") orelse return null;
    return (parseStringLiteralAt(statement_after_export, from_pos + "from".len) orelse return null).value;
}

fn parseExportFromNames(statement_after_export: []const u8) NameList {
    const names = NameList{};
    const from_pos = findKeyword(statement_after_export, "from") orelse return names;
    const clause = trimASCIIWhitespace(statement_after_export[0..from_pos]);
    if (clause.len == 0 or clause[0] == '*') return names;
    if (clause[0] == '{') {
        if (std.mem.lastIndexOfScalar(u8, clause, '}')) |close| {
            if (close > 0) return parseNamedList(clause[1..close], true);
        }
    }
    return names;
}

fn resolveModuleSpecifier(importer_path: []const u8, specifier_raw: []const u8, canonical_buf: []u8) ?[]const u8 {
    const specifier = trimASCIIWhitespace(specifier_raw);
    if (specifier.len == 0) return null;
    const path_part = cutPathPart(specifier);
    if (path_part.len == 0) return null;
    if (path_part[0] == '/') return canonicalizePath(path_part, canonical_buf);
    if (!std.mem.startsWith(u8, path_part, "./") and !std.mem.startsWith(u8, path_part, "../")) return null;
    if (importer_path.len == 0 or importer_path[0] != '/') return null;

    const slash = std.mem.lastIndexOfScalar(u8, importer_path, '/') orelse return null;
    var joined_buf: [4096]u8 = undefined;
    const base = importer_path[0 .. slash + 1];
    if (base.len + path_part.len > joined_buf.len) return null;
    @memcpy(joined_buf[0..base.len], base);
    @memcpy(joined_buf[base.len .. base.len + path_part.len], path_part);
    return canonicalizePath(joined_buf[0 .. base.len + path_part.len], canonical_buf);
}

fn checkModuleTarget(importer_path: []const u8, specifier: []const u8, names: NameList, checked_imports: *usize, broken_imports: *usize) void {
    checked_imports.* += 1;
    if (names.overflow) {
        broken_imports.* += 1;
        return;
    }

    var canonical_buf: [4096]u8 = undefined;
    const target_path = resolveModuleSpecifier(importer_path, specifier, canonical_buf[0..]) orelse {
        broken_imports.* += 1;
        return;
    };

    const target = moduleTableLookup(target_path) orelse {
        broken_imports.* += 1;
        return;
    };
    if (target.status >= 400 or !target.is_js) {
        broken_imports.* += 1;
        return;
    }
    for (names.names[0..names.count]) |name| {
        if (!moduleHasExport(target, name)) {
            broken_imports.* += 1;
            return;
        }
    }
}

fn scanStaticModuleImports(js: []const u8, importer_path: []const u8, checked_imports: *usize, broken_imports: *usize) void {
    var i: usize = 0;
    while (true) {
        i = skipJSWhitespaceAndComments(js, i);
        if (i >= js.len) return;

        if (keywordAt(js, i, "import")) {
            const after = skipJSWhitespaceAndComments(js, i + "import".len);
            if (after < js.len and js[after] == '(') return;
            const end = findStatementEnd(js, after);
            const statement = js[after..end];
            const specifier = importSpecifier(statement) orelse {
                broken_imports.* += 1;
                checked_imports.* += 1;
                return;
            };
            const names = parseImportNames(statement);
            checkModuleTarget(importer_path, specifier, names, checked_imports, broken_imports);
            i = end;
            continue;
        }

        if (keywordAt(js, i, "export")) {
            const after = skipJSWhitespaceAndComments(js, i + "export".len);
            if (after >= js.len or (js[after] != '{' and js[after] != '*')) return;
            const end = findStatementEnd(js, after);
            const statement = js[after..end];
            if (exportFromSpecifier(statement)) |specifier| {
                const names = parseExportFromNames(statement);
                checkModuleTarget(importer_path, specifier, names, checked_imports, broken_imports);
                i = end;
                continue;
            }
            return;
        }

        return;
    }
}

fn parseVarDeclarationExports(entry: *ModuleEntry, statement: []const u8, start: usize) bool {
    var i = start;
    while (i < statement.len) {
        i = skipJSWhitespaceAndComments(statement, i);
        if (i >= statement.len) break;
        if (isIdentifierStart(statement[i])) {
            const parsed = parseIdentifier(statement, i) orelse return true;
            if (!addExportName(entry, parsed.name)) return false;
            i = parsed.next;
        }
        while (i < statement.len and statement[i] != ',') : (i += 1) {}
        if (i < statement.len and statement[i] == ',') i += 1;
    }
    return true;
}

fn scanExports(entry: *ModuleEntry) bool {
    const js = entry.body;
    var i: usize = 0;
    while (i < js.len) : (i += 1) {
        if (js[i] == '"' or js[i] == '\'' or js[i] == '`') {
            i = skipQuoted(js, i);
            if (i >= js.len) break;
            continue;
        }
        if (i + 1 < js.len and js[i] == '/' and js[i + 1] == '/') {
            while (i < js.len and js[i] != '\n') : (i += 1) {}
            continue;
        }
        if (i + 1 < js.len and js[i] == '/' and js[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, js, i + 2, "*/")) |end| {
                i = end + 1;
                continue;
            }
            break;
        }
        if (!keywordAt(js, i, "export")) continue;

        var after = skipJSWhitespaceAndComments(js, i + "export".len);
        if (keywordAt(js, after, "default")) {
            if (!addExportName(entry, "default")) return false;
            i = after + "default".len;
            continue;
        }
        if (keywordAt(js, after, "async")) {
            after = skipJSWhitespaceAndComments(js, after + "async".len);
        }
        if (keywordAt(js, after, "function")) {
            if (parseIdentifier(js, after + "function".len)) |parsed| {
                if (!addExportName(entry, parsed.name)) return false;
            }
            i = after + "function".len;
            continue;
        }
        if (keywordAt(js, after, "class")) {
            if (parseIdentifier(js, after + "class".len)) |parsed| {
                if (!addExportName(entry, parsed.name)) return false;
            }
            i = after + "class".len;
            continue;
        }
        if (keywordAt(js, after, "const") or keywordAt(js, after, "let") or keywordAt(js, after, "var")) {
            const keyword_len: usize = if (keywordAt(js, after, "const")) "const".len else if (keywordAt(js, after, "let")) "let".len else "var".len;
            const end = findStatementEnd(js, after + keyword_len);
            if (!parseVarDeclarationExports(entry, js[after + keyword_len .. end], 0)) return false;
            i = end;
            continue;
        }
        if (after < js.len and js[after] == '{') {
            const end = findStatementEnd(js, after);
            const statement = js[after..end];
            if (std.mem.indexOfScalar(u8, statement, '}')) |close| {
                const names = parseNamedList(statement[1..close], false);
                if (names.overflow) return false;
                for (names.names[0..names.count]) |name| {
                    if (!addExportName(entry, name)) return false;
                }
            }
            i = end;
        }
    }
    return true;
}

fn indexWARCResponses(input: []const u8) void {
    clearModuleTable();

    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;
        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        const http = parseHTTPMeta(rec.payload) orelse continue;
        const path = pathFromTargetURI(rec.target_uri);
        const is_js = http.status == 200 and isJSContentType(http.content_type);
        const entry = moduleTableInsert(path, http.status, http.content_type, http.body, is_js) orelse @trap();
        if (is_js and !scanExports(entry)) @trap();
    }
}

fn indexOfCloseTagIgnoreCase(body: []const u8, start: usize, tag_name: []const u8) ?usize {
    if (start >= body.len) return null;
    var i = start;
    while (i + 2 + tag_name.len <= body.len) : (i += 1) {
        if (body[i] != '<') continue;
        if (i + 1 >= body.len or body[i + 1] != '/') continue;
        if (i + 2 + tag_name.len > body.len) continue;
        if (!eqlIgnoreCase(body[i + 2 .. i + 2 + tag_name.len], tag_name)) continue;
        return i;
    }
    return null;
}

fn parseHTMLModuleScripts(html: []const u8, document_path: []const u8, module_scripts: *usize, checked_imports: *usize, broken_imports: *usize) void {
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |end| {
                i = end + 3;
            } else {
                return;
            }
            continue;
        }

        var j = i + 1;
        if (j >= html.len) break;
        if (html[j] == '/' or html[j] == '!' or html[j] == '?') {
            if (std.mem.indexOfPos(u8, html, j, ">")) |end| {
                i = end + 1;
            } else {
                break;
            }
            continue;
        }

        const tag_start = j;
        while (j < html.len and isTagNameChar(html[j])) : (j += 1) {}
        if (j == tag_start) {
            i += 1;
            continue;
        }
        const tag = html[tag_start..j];
        const is_script = eqlIgnoreCase(tag, "script");
        var is_module = false;
        var src: []const u8 = "";
        var is_self_closing = false;

        while (j < html.len) {
            while (j < html.len and isSpace(html[j])) : (j += 1) {}
            if (j >= html.len) break;
            if (html[j] == '>') {
                j += 1;
                break;
            }
            if (html[j] == '/') {
                is_self_closing = true;
                j += 1;
                continue;
            }

            const attr_start = j;
            while (j < html.len and isTagNameChar(html[j])) : (j += 1) {}
            if (j == attr_start) {
                j += 1;
                continue;
            }
            const attr = html[attr_start..j];
            while (j < html.len and isSpace(html[j])) : (j += 1) {}
            var value: []const u8 = "";
            if (j < html.len and html[j] == '=') {
                j += 1;
                while (j < html.len and isSpace(html[j])) : (j += 1) {}
                if (j < html.len and (html[j] == '"' or html[j] == '\'')) {
                    const quote = html[j];
                    j += 1;
                    const value_start = j;
                    while (j < html.len and html[j] != quote) : (j += 1) {}
                    value = html[value_start..@min(j, html.len)];
                    if (j < html.len and html[j] == quote) j += 1;
                } else {
                    const value_start = j;
                    while (j < html.len and !isSpace(html[j]) and html[j] != '>') : (j += 1) {}
                    value = html[value_start..j];
                }
            }
            if (is_script and eqlIgnoreCase(attr, "type") and eqlIgnoreCase(trimASCIIWhitespace(value), "module")) {
                is_module = true;
            } else if (is_script and eqlIgnoreCase(attr, "src")) {
                src = value;
            }
        }

        if (!is_script) {
            i = j;
            continue;
        }

        const content_start = j;
        var close_end = j;
        var script_body: []const u8 = "";
        if (!is_self_closing) {
            if (indexOfCloseTagIgnoreCase(html, content_start, "script")) |close_start| {
                script_body = html[content_start..close_start];
                if (std.mem.indexOfPos(u8, html, close_start, ">")) |end| {
                    close_end = end + 1;
                } else {
                    broken_imports.* += 1;
                    checked_imports.* += 1;
                    return;
                }
            } else {
                broken_imports.* += 1;
                checked_imports.* += 1;
                return;
            }
        }

        if (is_module) {
            module_scripts.* += 1;
            if (src.len != 0) {
                checkModuleTarget(document_path, src, .{}, checked_imports, broken_imports);
            } else {
                scanStaticModuleImports(script_body, document_path, checked_imports, broken_imports);
            }
        }
        i = close_end;
    }
}

fn validateModuleImports(input: []const u8) ValidationSummary {
    indexWARCResponses(input);

    var module_scripts: usize = 0;
    var checked_imports: usize = 0;
    var broken_imports: usize = 0;
    var page_count: usize = 0;

    for (&module_table) |*entry| {
        if (!entry.used or !entry.is_js) continue;
        scanStaticModuleImports(entry.body, entry.path, &checked_imports, &broken_imports);
    }

    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;
        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        const http = parseHTTPMeta(rec.payload) orelse continue;
        if (http.status != 200 or !isHTMLContentType(http.content_type)) continue;

        page_count += 1;
        parseHTMLModuleScripts(http.body, pathFromTargetURI(rec.target_uri), &module_scripts, &checked_imports, &broken_imports);
    }

    return .{
        .module_scripts = module_scripts,
        .checked_imports = checked_imports,
        .broken_imports = broken_imports,
        .page_count = page_count,
    };
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    const input = input_buf[0..input_size];
    const summary = validateModuleImports(input);
    if (summary.broken_imports != 0) @trap();
    return input_size_u32;
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&input_buf)),
        .failed = 0,
    };
}

fn appendWARCRecord(out_buf: []u8, cursor: *usize, warc_type: []const u8, target_uri: []const u8, payload: []const u8) !void {
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.1\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ warc_type, target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += rec.len;
}

test "validates inline module named imports" {
    var build_buf: [8192]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<script type=\"module\">import { contentComponent, contentTypeUTF8 } from \"/qip-runner.js\";\nconst ok = true;</script>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/qip-runner.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript; charset=utf-8\r\n\r\nexport function contentTypeUTF8() {}\nexport function contentTypeBytes() {}\nexport function contentComponent() {}\nexport function contentRecipe() {}\n",
    );

    @memcpy(input_buf[0..n], build_buf[0..n]);
    const out_len = renderImpl(@as(u32, @intCast(n)));
    try std.testing.expectEqual(@as(u32, @intCast(n)), out_len);

    const summary = validateModuleImports(build_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 1), summary.page_count);
    try std.testing.expectEqual(@as(usize, 1), summary.module_scripts);
    try std.testing.expectEqual(@as(usize, 1), summary.checked_imports);
    try std.testing.expectEqual(@as(usize, 0), summary.broken_imports);
}

test "resolves relative imports against module and document paths" {
    var build_buf: [16384]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/guide/page",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<script type=\"module\">import { inlineValue } from \"./inline.js\";</script><script type=\"module\" src=\"../scripts/entry.js\"></script>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/guide/inline.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport const inlineValue = 1;",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/scripts/entry.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nimport { sharedValue } from \"./shared/value.js?cache=1#value\";\nimport { rootValue } from \"../root.js\";\nexport { sharedValue, rootValue };",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/scripts/shared/value.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport const sharedValue = 2;",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/root.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport const rootValue = 3;",
    );

    const summary = validateModuleImports(build_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 2), summary.module_scripts);
    try std.testing.expectEqual(@as(usize, 4), summary.checked_imports);
    try std.testing.expectEqual(@as(usize, 0), summary.broken_imports);
}

test "detects missing named import from existing module" {
    var build_buf: [8192]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<script type=\"module\">import { render } from \"/qip-runner.js\";</script>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/qip-runner.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport function contentTypeUTF8() {}\nexport function contentComponent() {}\n",
    );

    const summary = validateModuleImports(build_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 1), summary.checked_imports);
    try std.testing.expectEqual(@as(usize, 1), summary.broken_imports);
}

test "detects missing module target and script src" {
    var build_buf: [8192]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<script type=\"module\">import { x } from \"/missing.js\";</script><script type=\"module\" src=\"/also-missing.js\"></script>",
    );

    const summary = validateModuleImports(build_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 2), summary.checked_imports);
    try std.testing.expectEqual(@as(usize, 2), summary.broken_imports);
}

test "parses exported declarations and export lists" {
    var build_buf: [8192]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<script type=\"module\">import def, { a, exportedName, renamed } from \"/mod.js\";</script>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/mod.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport default function main() {}\nexport const a = 1;\nconst local = 1;\nexport { local as exportedName, renamed };\n",
    );

    const summary = validateModuleImports(build_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 1), summary.checked_imports);
    try std.testing.expectEqual(@as(usize, 0), summary.broken_imports);
}
