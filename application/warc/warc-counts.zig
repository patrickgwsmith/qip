//! `warc-counts` scans an uncompressed WARC 1.0 or 1.1 archive. It writes
//! deterministic long-form CSV with one integer metric in each row. It reports
//! archive structure, stored bytes, HTTP messages, status families, and MIME
//! families. It does not extract payloads or decide if an archive is good.
//!
//! Build and run it with:
//!
//! ```sh
//! make -j qip application/warc/warc-counts.wasm
//!
//! qip router warc ./site |
//!   qip run application/warc/warc-counts.wasm
//! ```
//!
//! Output has this form:
//!
//! ```csv
//! metric,value
//! archive_bytes,12177834
//! records,381
//! response_records,379
//! http_status_2xx,376
//! http_html_records,84
//! http_html_body_bytes,1928441
//! ```
//!
//! Zero-valued rows remain in the output. You can compare two reports with
//! `diff`, SQLite, or a spreadsheet.
//!
//! The report counts:
//!
//! - WARC 1.0 and 1.1 records, split by standard `WARC-Type`;
//! - bytes used by record headers, payloads, and record separators;
//! - the largest complete record and payload;
//! - records that have target URIs, block digests, and payload digests;
//! - embedded HTTP requests, responses, headers, and bodies;
//! - HTTP status families and redirects other than `304 Not Modified`; and
//! - HTTP records and body bytes grouped as HTML, CSS, JavaScript, other text,
//!   JSON, XML, image, audio, video, font, Wasm, other, or no content type.
//!
//! MIME parameters do not affect grouping. For example,
//! `text/html; charset=utf-8` is HTML. A structured suffix such as `+json`
//! selects JSON. The top-level `image` type takes precedence over an XML
//! suffix, so `image/svg+xml` is an image.
//!
//! Byte metrics describe stored bytes, not decoded or decompressed sizes. The
//! component accepts raw WARC input up to 128 MiB. It does not decode
//! `.warc.gz`.
//!
//! Malformed WARC record framing traps. A valid WARC record with a malformed
//! embedded HTTP message remains countable and increments
//! `http_malformed_messages`.
//!
//! Use a record inventory when you need target URIs, dates, headers, or
//! offsets for each record. Use an extractor when you need payload contents.
//! Aggregate counts support comparisons and overview charts, but they cannot
//! identify the record that caused a change.

const std = @import("std");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "text/csv";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const CountError = error{
    EmptyArchive,
    InvalidVersion,
    InvalidHeader,
    MissingRequiredField,
    DuplicateContentLength,
    InvalidContentLength,
    TruncatedPayload,
    InvalidRecordSeparator,
    OutputOverflow,
};

const Counts = struct {
    archive_bytes: u64 = 0,
    records: u64 = 0,
    warc_1_0_records: u64 = 0,
    warc_1_1_records: u64 = 0,
    warcinfo_records: u64 = 0,
    response_records: u64 = 0,
    request_records: u64 = 0,
    resource_records: u64 = 0,
    metadata_records: u64 = 0,
    revisit_records: u64 = 0,
    conversion_records: u64 = 0,
    continuation_records: u64 = 0,
    other_records: u64 = 0,
    records_with_target_uri: u64 = 0,
    records_with_block_digest: u64 = 0,
    records_with_payload_digest: u64 = 0,
    record_header_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    record_separator_bytes: u64 = 0,
    largest_record_bytes: u64 = 0,
    largest_payload_bytes: u64 = 0,
    http_candidate_records: u64 = 0,
    http_messages: u64 = 0,
    http_malformed_messages: u64 = 0,
    http_requests: u64 = 0,
    http_responses: u64 = 0,
    http_header_bytes: u64 = 0,
    http_body_bytes: u64 = 0,
    http_status_1xx: u64 = 0,
    http_status_2xx: u64 = 0,
    http_status_3xx: u64 = 0,
    http_status_4xx: u64 = 0,
    http_status_5xx: u64 = 0,
    http_status_other: u64 = 0,
    http_redirect_responses: u64 = 0,
    http_html_records: u64 = 0,
    http_html_body_bytes: u64 = 0,
    http_css_records: u64 = 0,
    http_css_body_bytes: u64 = 0,
    http_javascript_records: u64 = 0,
    http_javascript_body_bytes: u64 = 0,
    http_text_records: u64 = 0,
    http_text_body_bytes: u64 = 0,
    http_json_records: u64 = 0,
    http_json_body_bytes: u64 = 0,
    http_xml_records: u64 = 0,
    http_xml_body_bytes: u64 = 0,
    http_image_records: u64 = 0,
    http_image_body_bytes: u64 = 0,
    http_audio_records: u64 = 0,
    http_audio_body_bytes: u64 = 0,
    http_video_records: u64 = 0,
    http_video_body_bytes: u64 = 0,
    http_font_records: u64 = 0,
    http_font_body_bytes: u64 = 0,
    http_wasm_records: u64 = 0,
    http_wasm_body_bytes: u64 = 0,
    http_other_records: u64 = 0,
    http_other_body_bytes: u64 = 0,
    http_missing_content_type_records: u64 = 0,
    http_missing_content_type_body_bytes: u64 = 0,
};

const Record = struct {
    next: usize,
    record_bytes: usize,
    header_bytes: usize,
    payload: []const u8,
    warc_type: []const u8,
    content_type: []const u8,
    has_target_uri: bool,
    has_block_digest: bool,
    has_payload_digest: bool,
    version_minor: u8,
};

const HTTPKind = enum { request, response };

const HTTPMessage = struct {
    kind: HTTPKind,
    status: u16 = 0,
    header_bytes: usize,
    body_bytes: usize,
    content_type: []const u8,
};

const Writer = struct {
    off: usize = 0,

    fn write(self: *Writer, bytes: []const u8) CountError!void {
        if (bytes.len > output_buf.len - self.off) return CountError.OutputOverflow;
        @memcpy(output_buf[self.off..][0..bytes.len], bytes);
        self.off += bytes.len;
    }

    fn row(self: *Writer, comptime name: []const u8, value: u64) CountError!void {
        try self.write(name ++ ",");
        var buf: [32]u8 = undefined;
        const number = std.fmt.bufPrint(&buf, "{d}\n", .{value}) catch unreachable;
        try self.write(number);
    }
};

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

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn trimASCIIWhitespace(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn parseUnsigned10(value: []const u8) ?usize {
    if (value.len == 0) return null;
    var result: usize = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, c - '0') catch return null;
    }
    return result;
}

fn parseRecord(archive: []const u8, start: usize) CountError!Record {
    const marker = std.mem.indexOfPos(u8, archive, start, "\r\n\r\n") orelse
        return CountError.InvalidHeader;
    const header = archive[start..marker];
    const first_line_end = std.mem.indexOf(u8, header, "\r\n") orelse
        return CountError.InvalidHeader;
    const version = header[0..first_line_end];
    const version_minor: u8 = if (std.mem.eql(u8, version, "WARC/1.0"))
        0
    else if (std.mem.eql(u8, version, "WARC/1.1"))
        1
    else
        return CountError.InvalidVersion;

    var warc_type: []const u8 = "";
    var content_type: []const u8 = "";
    var content_length: ?usize = null;
    var have_date = false;
    var have_id = false;
    var has_target_uri = false;
    var has_block_digest = false;
    var has_payload_digest = false;
    var line_start = first_line_end + 2;

    while (line_start < header.len) {
        const line_end = std.mem.indexOfPos(u8, header, line_start, "\r\n") orelse header.len;
        const line = header[line_start..line_end];
        line_start = if (line_end < header.len) line_end + 2 else header.len;
        if (line.len == 0) break;
        if (line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return CountError.InvalidHeader;
        const name = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (name.len == 0) return CountError.InvalidHeader;

        if (eqlIgnoreCase(name, "WARC-Type")) {
            warc_type = value;
        } else if (eqlIgnoreCase(name, "WARC-Date")) {
            have_date = value.len > 0;
        } else if (eqlIgnoreCase(name, "WARC-Record-ID")) {
            have_id = value.len > 0;
        } else if (eqlIgnoreCase(name, "WARC-Target-URI")) {
            has_target_uri = value.len > 0;
        } else if (eqlIgnoreCase(name, "WARC-Block-Digest")) {
            has_block_digest = value.len > 0;
        } else if (eqlIgnoreCase(name, "WARC-Payload-Digest")) {
            has_payload_digest = value.len > 0;
        } else if (eqlIgnoreCase(name, "Content-Type")) {
            content_type = value;
        } else if (eqlIgnoreCase(name, "Content-Length")) {
            if (content_length != null) return CountError.DuplicateContentLength;
            content_length = parseUnsigned10(value) orelse
                return CountError.InvalidContentLength;
        }
    }

    if (warc_type.len == 0 or !have_date or !have_id or content_length == null)
        return CountError.MissingRequiredField;

    const header_end = marker + 4;
    const payload_len = content_length.?;
    if (payload_len > archive.len - header_end) return CountError.TruncatedPayload;
    const payload_end = header_end + payload_len;
    if (archive.len - payload_end < 4 or
        !std.mem.eql(u8, archive[payload_end .. payload_end + 4], "\r\n\r\n"))
        return CountError.InvalidRecordSeparator;

    const next = payload_end + 4;
    return .{
        .next = next,
        .record_bytes = next - start,
        .header_bytes = header_end - start,
        .payload = archive[header_end..payload_end],
        .warc_type = warc_type,
        .content_type = content_type,
        .has_target_uri = has_target_uri,
        .has_block_digest = has_block_digest,
        .has_payload_digest = has_payload_digest,
        .version_minor = version_minor,
    };
}

fn mimeTypeToken(raw: []const u8) []const u8 {
    const value = trimASCIIWhitespace(raw);
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return trimASCIIWhitespace(value[0..semicolon]);
}

fn isApplicationHTTP(raw: []const u8) bool {
    return eqlIgnoreCase(mimeTypeToken(raw), "application/http");
}

fn parseResponseStatus(line: []const u8) ?u16 {
    if (!startsWithIgnoreCase(line, "HTTP/")) return null;
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    var start = first_space;
    while (start < line.len and line[start] == ' ') : (start += 1) {}
    if (start + 3 > line.len) return null;
    const token = line[start .. start + 3];
    const parsed = parseUnsigned10(token) orelse return null;
    if (parsed > 999) return null;
    return @intCast(parsed);
}

fn isRequestLine(line: []const u8) bool {
    const last_space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return false;
    return startsWithIgnoreCase(line[last_space + 1 ..], "HTTP/");
}

fn parseHTTP(payload: []const u8, expected_kind: HTTPKind) ?HTTPMessage {
    const marker = std.mem.indexOf(u8, payload, "\r\n\r\n") orelse return null;
    const header = payload[0..marker];
    const first_line_end = std.mem.indexOf(u8, header, "\r\n") orelse return null;
    const first_line = header[0..first_line_end];

    var message = HTTPMessage{
        .kind = expected_kind,
        .header_bytes = marker + 4,
        .body_bytes = payload.len - marker - 4,
        .content_type = "",
    };
    switch (expected_kind) {
        .response => message.status = parseResponseStatus(first_line) orelse return null,
        .request => if (!isRequestLine(first_line)) return null,
    }

    var line_start = first_line_end + 2;
    while (line_start < header.len) {
        const line_end = std.mem.indexOfPos(u8, header, line_start, "\r\n") orelse header.len;
        const line = header[line_start..line_end];
        line_start = if (line_end < header.len) line_end + 2 else header.len;
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = trimASCIIWhitespace(line[0..colon]);
        if (eqlIgnoreCase(name, "Content-Type")) {
            message.content_type = trimASCIIWhitespace(line[colon + 1 ..]);
        }
    }
    return message;
}

fn countRecordType(counts: *Counts, warc_type: []const u8) void {
    if (eqlIgnoreCase(warc_type, "warcinfo")) {
        counts.warcinfo_records += 1;
    } else if (eqlIgnoreCase(warc_type, "response")) {
        counts.response_records += 1;
    } else if (eqlIgnoreCase(warc_type, "request")) {
        counts.request_records += 1;
    } else if (eqlIgnoreCase(warc_type, "resource")) {
        counts.resource_records += 1;
    } else if (eqlIgnoreCase(warc_type, "metadata")) {
        counts.metadata_records += 1;
    } else if (eqlIgnoreCase(warc_type, "revisit")) {
        counts.revisit_records += 1;
    } else if (eqlIgnoreCase(warc_type, "conversion")) {
        counts.conversion_records += 1;
    } else if (eqlIgnoreCase(warc_type, "continuation")) {
        counts.continuation_records += 1;
    } else {
        counts.other_records += 1;
    }
}

fn countStatus(counts: *Counts, status: u16) void {
    switch (status / 100) {
        1 => counts.http_status_1xx += 1,
        2 => counts.http_status_2xx += 1,
        3 => counts.http_status_3xx += 1,
        4 => counts.http_status_4xx += 1,
        5 => counts.http_status_5xx += 1,
        else => counts.http_status_other += 1,
    }
    switch (status) {
        300, 301, 302, 303, 305, 307, 308 => counts.http_redirect_responses += 1,
        else => {},
    }
}

fn countMIME(counts: *Counts, raw: []const u8, body_bytes: u64) void {
    const mime = mimeTypeToken(raw);
    if (mime.len == 0) {
        counts.http_missing_content_type_records += 1;
        counts.http_missing_content_type_body_bytes += body_bytes;
    } else if (eqlIgnoreCase(mime, "text/html") or eqlIgnoreCase(mime, "application/xhtml+xml")) {
        counts.http_html_records += 1;
        counts.http_html_body_bytes += body_bytes;
    } else if (eqlIgnoreCase(mime, "text/css")) {
        counts.http_css_records += 1;
        counts.http_css_body_bytes += body_bytes;
    } else if (eqlIgnoreCase(mime, "text/javascript") or
        eqlIgnoreCase(mime, "application/javascript") or
        eqlIgnoreCase(mime, "text/ecmascript") or
        eqlIgnoreCase(mime, "application/ecmascript"))
    {
        counts.http_javascript_records += 1;
        counts.http_javascript_body_bytes += body_bytes;
    } else if (startsWithIgnoreCase(mime, "text/")) {
        counts.http_text_records += 1;
        counts.http_text_body_bytes += body_bytes;
    } else if (startsWithIgnoreCase(mime, "image/")) {
        counts.http_image_records += 1;
        counts.http_image_body_bytes += body_bytes;
    } else if (eqlIgnoreCase(mime, "application/json") or endsWithIgnoreCase(mime, "+json")) {
        counts.http_json_records += 1;
        counts.http_json_body_bytes += body_bytes;
    } else if (eqlIgnoreCase(mime, "application/xml") or
        eqlIgnoreCase(mime, "text/xml") or
        endsWithIgnoreCase(mime, "+xml"))
    {
        counts.http_xml_records += 1;
        counts.http_xml_body_bytes += body_bytes;
    } else if (startsWithIgnoreCase(mime, "audio/")) {
        counts.http_audio_records += 1;
        counts.http_audio_body_bytes += body_bytes;
    } else if (startsWithIgnoreCase(mime, "video/")) {
        counts.http_video_records += 1;
        counts.http_video_body_bytes += body_bytes;
    } else if (startsWithIgnoreCase(mime, "font/") or
        startsWithIgnoreCase(mime, "application/font") or
        eqlIgnoreCase(mime, "application/vnd.ms-fontobject") or
        eqlIgnoreCase(mime, "application/woff") or
        eqlIgnoreCase(mime, "application/woff2"))
    {
        counts.http_font_records += 1;
        counts.http_font_body_bytes += body_bytes;
    } else if (eqlIgnoreCase(mime, "application/wasm")) {
        counts.http_wasm_records += 1;
        counts.http_wasm_body_bytes += body_bytes;
    } else {
        counts.http_other_records += 1;
        counts.http_other_body_bytes += body_bytes;
    }
}

fn analyze(archive: []const u8) CountError!Counts {
    if (archive.len == 0) return CountError.EmptyArchive;
    var counts = Counts{ .archive_bytes = archive.len };
    var cursor: usize = 0;
    while (cursor < archive.len) {
        const record = try parseRecord(archive, cursor);
        counts.records += 1;
        if (record.version_minor == 0)
            counts.warc_1_0_records += 1
        else
            counts.warc_1_1_records += 1;
        countRecordType(&counts, record.warc_type);
        if (record.has_target_uri) counts.records_with_target_uri += 1;
        if (record.has_block_digest) counts.records_with_block_digest += 1;
        if (record.has_payload_digest) counts.records_with_payload_digest += 1;
        counts.record_header_bytes += record.header_bytes;
        counts.payload_bytes += record.payload.len;
        counts.record_separator_bytes += 4;
        counts.largest_record_bytes = @max(counts.largest_record_bytes, record.record_bytes);
        counts.largest_payload_bytes = @max(counts.largest_payload_bytes, record.payload.len);

        const expected_kind: ?HTTPKind =
            if (eqlIgnoreCase(record.warc_type, "response"))
                .response
            else if (eqlIgnoreCase(record.warc_type, "request"))
                .request
            else
                null;
        if (isApplicationHTTP(record.content_type) or expected_kind != null) {
            counts.http_candidate_records += 1;
            if (expected_kind) |kind| {
                if (parseHTTP(record.payload, kind)) |http| {
                    counts.http_messages += 1;
                    counts.http_header_bytes += http.header_bytes;
                    counts.http_body_bytes += http.body_bytes;
                    switch (http.kind) {
                        .request => counts.http_requests += 1,
                        .response => {
                            counts.http_responses += 1;
                            countStatus(&counts, http.status);
                        },
                    }
                    countMIME(&counts, http.content_type, http.body_bytes);
                } else {
                    counts.http_malformed_messages += 1;
                }
            } else {
                counts.http_malformed_messages += 1;
            }
        }
        cursor = record.next;
    }
    return counts;
}

fn renderCsv(c: Counts) CountError!usize {
    var w = Writer{};
    try w.write("metric,value\n");
    try w.row("archive_bytes", c.archive_bytes);
    try w.row("records", c.records);
    try w.row("warc_1_0_records", c.warc_1_0_records);
    try w.row("warc_1_1_records", c.warc_1_1_records);
    try w.row("warcinfo_records", c.warcinfo_records);
    try w.row("response_records", c.response_records);
    try w.row("request_records", c.request_records);
    try w.row("resource_records", c.resource_records);
    try w.row("metadata_records", c.metadata_records);
    try w.row("revisit_records", c.revisit_records);
    try w.row("conversion_records", c.conversion_records);
    try w.row("continuation_records", c.continuation_records);
    try w.row("other_records", c.other_records);
    try w.row("records_with_target_uri", c.records_with_target_uri);
    try w.row("records_with_block_digest", c.records_with_block_digest);
    try w.row("records_with_payload_digest", c.records_with_payload_digest);
    try w.row("record_header_bytes", c.record_header_bytes);
    try w.row("payload_bytes", c.payload_bytes);
    try w.row("record_separator_bytes", c.record_separator_bytes);
    try w.row("largest_record_bytes", c.largest_record_bytes);
    try w.row("largest_payload_bytes", c.largest_payload_bytes);
    try w.row("http_candidate_records", c.http_candidate_records);
    try w.row("http_messages", c.http_messages);
    try w.row("http_malformed_messages", c.http_malformed_messages);
    try w.row("http_requests", c.http_requests);
    try w.row("http_responses", c.http_responses);
    try w.row("http_header_bytes", c.http_header_bytes);
    try w.row("http_body_bytes", c.http_body_bytes);
    try w.row("http_status_1xx", c.http_status_1xx);
    try w.row("http_status_2xx", c.http_status_2xx);
    try w.row("http_status_3xx", c.http_status_3xx);
    try w.row("http_status_4xx", c.http_status_4xx);
    try w.row("http_status_5xx", c.http_status_5xx);
    try w.row("http_status_other", c.http_status_other);
    try w.row("http_redirect_responses", c.http_redirect_responses);
    try w.row("http_html_records", c.http_html_records);
    try w.row("http_html_body_bytes", c.http_html_body_bytes);
    try w.row("http_css_records", c.http_css_records);
    try w.row("http_css_body_bytes", c.http_css_body_bytes);
    try w.row("http_javascript_records", c.http_javascript_records);
    try w.row("http_javascript_body_bytes", c.http_javascript_body_bytes);
    try w.row("http_text_records", c.http_text_records);
    try w.row("http_text_body_bytes", c.http_text_body_bytes);
    try w.row("http_json_records", c.http_json_records);
    try w.row("http_json_body_bytes", c.http_json_body_bytes);
    try w.row("http_xml_records", c.http_xml_records);
    try w.row("http_xml_body_bytes", c.http_xml_body_bytes);
    try w.row("http_image_records", c.http_image_records);
    try w.row("http_image_body_bytes", c.http_image_body_bytes);
    try w.row("http_audio_records", c.http_audio_records);
    try w.row("http_audio_body_bytes", c.http_audio_body_bytes);
    try w.row("http_video_records", c.http_video_records);
    try w.row("http_video_body_bytes", c.http_video_body_bytes);
    try w.row("http_font_records", c.http_font_records);
    try w.row("http_font_body_bytes", c.http_font_body_bytes);
    try w.row("http_wasm_records", c.http_wasm_records);
    try w.row("http_wasm_body_bytes", c.http_wasm_body_bytes);
    try w.row("http_other_records", c.http_other_records);
    try w.row("http_other_body_bytes", c.http_other_body_bytes);
    try w.row("http_missing_content_type_records", c.http_missing_content_type_records);
    try w.row("http_missing_content_type_body_bytes", c.http_missing_content_type_body_bytes);
    return w.off;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    const counts = analyze(input_buf[0..input_size]) catch @trap();
    return @intCast(renderCsv(counts) catch @trap());
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

fn appendRecord(
    out: []u8,
    cursor: *usize,
    version: []const u8,
    warc_type: []const u8,
    target: ?[]const u8,
    content_type: []const u8,
    payload: []const u8,
) !void {
    const record = if (target) |uri|
        try std.fmt.bufPrint(
            out[cursor.*..],
            "{s}\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000000>\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
            .{ version, warc_type, uri, content_type, payload.len, payload },
        )
    else
        try std.fmt.bufPrint(
            out[cursor.*..],
            "{s}\r\nWARC-Type: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000000>\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
            .{ version, warc_type, content_type, payload.len, payload },
        );
    cursor.* += record.len;
}

test "reports WARC, HTTP, status, MIME, and byte counts as CSV" {
    var archive: [8192]u8 = undefined;
    var len: usize = 0;
    try appendRecord(&archive, &len, "WARC/1.0", "warcinfo", null, "application/warc-fields", "software: qip\r\n");
    try appendRecord(
        &archive,
        &len,
        "WARC/1.1",
        "response",
        "https://example.test/",
        "application/http; msgtype=response",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<h1>Hello</h1>",
    );
    try appendRecord(
        &archive,
        &len,
        "WARC/1.1",
        "request",
        "https://example.test/",
        "application/http; msgtype=request",
        "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );

    const counts = try analyze(archive[0..len]);
    try std.testing.expectEqual(@as(u64, 3), counts.records);
    try std.testing.expectEqual(@as(u64, 1), counts.warc_1_0_records);
    try std.testing.expectEqual(@as(u64, 2), counts.warc_1_1_records);
    try std.testing.expectEqual(@as(u64, 1), counts.warcinfo_records);
    try std.testing.expectEqual(@as(u64, 1), counts.response_records);
    try std.testing.expectEqual(@as(u64, 1), counts.request_records);
    try std.testing.expectEqual(@as(u64, 2), counts.http_messages);
    try std.testing.expectEqual(@as(u64, 1), counts.http_status_2xx);
    try std.testing.expectEqual(@as(u64, 1), counts.http_html_records);
    try std.testing.expectEqual(@as(u64, "<h1>Hello</h1>".len), counts.http_html_body_bytes);
    try std.testing.expectEqual(@as(u64, 1), counts.http_missing_content_type_records);
    try std.testing.expectEqual(@as(u64, len), counts.archive_bytes);
    try std.testing.expectEqual(counts.archive_bytes, counts.record_header_bytes + counts.payload_bytes + counts.record_separator_bytes);

    const output_len = try renderCsv(counts);
    const csv = output_buf[0..output_len];
    try std.testing.expect(std.mem.startsWith(u8, csv, "metric,value\n"));
    try std.testing.expect(std.mem.indexOf(u8, csv, "records,3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "http_html_records,1\n") != null);
}

test "rejects malformed WARC record structure" {
    const archive =
        "WARC/1.1\r\n" ++
        "WARC-Type: response\r\n" ++
        "WARC-Date: 2000-01-01T00:00:00Z\r\n" ++
        "WARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000000>\r\n" ++
        "Content-Length: 20\r\n\r\n" ++
        "short\r\n\r\n";
    try std.testing.expectError(CountError.TruncatedPayload, analyze(archive));
}

test "counts redirects separately from the complete 3xx family" {
    var counts = Counts{};
    countStatus(&counts, 301);
    countStatus(&counts, 304);
    countStatus(&counts, 308);
    try std.testing.expectEqual(@as(u64, 3), counts.http_status_3xx);
    try std.testing.expectEqual(@as(u64, 2), counts.http_redirect_responses);
}
