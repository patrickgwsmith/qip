//! Signs one HTTP request with AWS Signature Version 4.
//! Reads request fields from multipart/form-data and the signing time from the
//! `timestamp` uniform, then outputs the headers to add to the request.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;
const WORK_CAP: usize = 64 * 1024;
const MAX_QUERY_PARAMS: usize = 128;
const MAX_PATH_SEGMENTS: usize = 256;
const OUTPUT_CONTENT_TYPE = "text/plain";
const TYPE_PREFIX = "multipart/form-data;boundary=uuid-";
const DEFAULT_UUID = "00000000-0000-0000-0000-000000000000";
const UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD";

// The UUID bytes are deliberately writable through the exported pointer. Hosts
// may replace them with another canonical lowercase UUID before render().
var input_content_type = (TYPE_PREFIX ++ DEFAULT_UUID).*;
var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var canonical_buf: [WORK_CAP]u8 = undefined;

var timestamp: i64 = 0;

export fn uniform_set_timestamp(v: i64) i64 {
    timestamp = v;
    return timestamp;
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(&input_content_type));
}

export fn input_content_type_size() u32 {
    return input_content_type.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const SignError = error{
    InvalidBoundary,
    InvalidMultipart,
    InvalidHeader,
    MissingName,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidField,
    InvalidUrl,
    InvalidTimestamp,
    TooManyQueryParams,
    TooManyPathSegments,
    WriteFailed,
};

const Fields = struct {
    method: ?[]const u8 = null,
    url: ?[]const u8 = null,
    region: ?[]const u8 = null,
    service: ?[]const u8 = null,
    access_key_id: ?[]const u8 = null,
    secret_access_key: ?[]const u8 = null,
    session_token: ?[]const u8 = null,
    body: ?[]const u8 = null,
    payload_sha256: ?[]const u8 = null,

    fn set(self: *Fields, name: []const u8, value: []const u8) SignError!void {
        inline for (std.meta.fields(Fields)) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                if (@field(self, field.name) != null) return error.DuplicateField;
                @field(self, field.name) = value;
                return;
            }
        }
        return error.UnknownField;
    }
};

pub const Request = struct {
    method: []const u8,
    host: []const u8,
    path: []const u8,
    query: []const u8,
    region: []const u8,
    service: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
    payload_sha256: []const u8,
    /// Adds and signs `X-Amz-Content-Sha256`. S3 requires it; other services
    /// only hash the payload into the canonical request.
    sign_content_sha256: bool = true,
    timestamp: i64,
};

fn readBoundary(out: *[TYPE_PREFIX.len + DEFAULT_UUID.len]u8) SignError![]const u8 {
    // Volatile loads are required because the host can edit this metadata after
    // instantiation, outside Zig's view of program execution.
    for (&input_content_type, 0..) |*byte, index| {
        out[index] = @as(*volatile u8, @ptrCast(byte)).*;
    }
    if (!std.mem.eql(u8, out[0..TYPE_PREFIX.len], TYPE_PREFIX)) return error.InvalidBoundary;
    const uuid = out[TYPE_PREFIX.len..];
    for (uuid, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidBoundary;
        } else if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) {
            return error.InvalidBoundary;
        }
    }
    return out["multipart/form-data;boundary=".len..];
}

fn trimOWS(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn dispositionName(value: []const u8) SignError![]const u8 {
    var fields = std.mem.splitScalar(u8, value, ';');
    if (!std.ascii.eqlIgnoreCase(trimOWS(fields.next() orelse return error.InvalidHeader), "form-data")) {
        return error.InvalidHeader;
    }
    while (fields.next()) |raw_field| {
        const field = trimOWS(raw_field);
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidHeader;
        const raw_value = trimOWS(field[equal + 1 ..]);
        if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(trimOWS(field[0..equal]), "name")) return raw_value[1 .. raw_value.len - 1];
    }
    return error.MissingName;
}

fn partName(block: []const u8) SignError![]const u8 {
    var name: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const key = line[0..colon];
        if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
            if (name != null) return error.InvalidHeader;
            name = try dispositionName(trimOWS(line[colon + 1 ..]));
        } else if (!std.ascii.eqlIgnoreCase(key, "content-type")) {
            return error.InvalidHeader;
        }
    }
    return name orelse error.MissingName;
}

fn parseForm(input: []const u8, boundary: []const u8) SignError!Fields {
    var fields: Fields = .{};
    var marker_buf: [4 + "uuid-".len + DEFAULT_UUID.len]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "\r\n--{s}", .{boundary}) catch unreachable;
    // Prefixing CRLF lets the opening delimiter match the same marker as the rest.
    if (!std.mem.startsWith(u8, input, marker[2..])) return error.InvalidMultipart;
    var cursor: usize = marker.len - 2;
    while (true) {
        if (std.mem.startsWith(u8, input[cursor..], "--")) {
            const rest = input[cursor + 2 ..];
            if (rest.len != 0 and !std.mem.eql(u8, rest, "\r\n")) return error.InvalidMultipart;
            return fields;
        }
        if (!std.mem.startsWith(u8, input[cursor..], "\r\n")) return error.InvalidMultipart;
        cursor += 2;
        const header_end = std.mem.indexOfPos(u8, input, cursor, "\r\n\r\n") orelse return error.InvalidMultipart;
        const name = try partName(input[cursor..header_end]);
        const body_start = header_end + 4;
        const body_end = std.mem.indexOfPos(u8, input, body_start, marker) orelse return error.InvalidMultipart;
        try fields.set(name, input[body_start..body_end]);
        cursor = body_end + marker.len;
    }
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
}

fn isVisibleAscii(value: []const u8) bool {
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn isScopePart(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return true;
}

fn isLowerHex(value: []const u8) bool {
    for (value) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

/// S3 and its variants sign the path encoded once, without normalizing it.
fn isS3(service: []const u8) bool {
    return std.mem.eql(u8, service, "s3") or std.mem.startsWith(u8, service, "s3-");
}

/// Strips the port when it is the scheme's default, as HTTP clients omit it
/// from the Host header they send.
fn hostWithoutDefaultPort(host: []const u8, default_port: []const u8) SignError![]const u8 {
    const port_start = if (host[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return error.InvalidUrl;
        if (close + 1 == host.len) return host;
        if (host[close + 1] != ':') return error.InvalidUrl;
        break :blk close + 1;
    } else std.mem.indexOfScalar(u8, host, ':') orelse return host;
    const port = host[port_start + 1 ..];
    if (port_start == 0 or port.len == 0) return error.InvalidUrl;
    for (port) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidUrl;
    return if (std.mem.eql(u8, port, default_port)) host[0..port_start] else host;
}

fn requestFromFields(fields: Fields, signing_time: i64) SignError!Request {
    const method = fields.method orelse return error.MissingField;
    if (method.len == 0) return error.InvalidField;
    for (method) |byte| if (!std.ascii.isUpper(byte)) return error.InvalidField;

    const url = fields.url orelse return error.MissingField;
    if (!isVisibleAscii(url) or std.mem.indexOfScalar(u8, url, '#') != null) return error.InvalidUrl;
    const https = std.mem.startsWith(u8, url, "https://");
    if (!https and !std.mem.startsWith(u8, url, "http://")) return error.InvalidUrl;
    const after_scheme = url[if (https) "https://".len else "http://".len ..];
    const host_end = std.mem.indexOfAny(u8, after_scheme, "/?") orelse after_scheme.len;
    const raw_host = after_scheme[0..host_end];
    if (raw_host.len == 0 or std.mem.indexOfScalar(u8, raw_host, '@') != null) return error.InvalidUrl;
    const host = try hostWithoutDefaultPort(raw_host, if (https) "443" else "80");
    const target = after_scheme[host_end..];
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;

    const region = fields.region orelse return error.MissingField;
    const service = fields.service orelse return error.MissingField;
    if (!isScopePart(region) or !isScopePart(service)) return error.InvalidField;
    const access_key_id = fields.access_key_id orelse return error.MissingField;
    const secret_access_key = fields.secret_access_key orelse return error.MissingField;
    if (access_key_id.len == 0 or !isVisibleAscii(access_key_id) or std.mem.indexOfScalar(u8, access_key_id, '/') != null) return error.InvalidField;
    if (secret_access_key.len == 0 or !isVisibleAscii(secret_access_key)) return error.InvalidField;
    if (fields.session_token) |token| {
        if (token.len == 0 or !isVisibleAscii(token)) return error.InvalidField;
    }

    if (fields.body != null and fields.payload_sha256 != null) return error.InvalidField;
    const payload_sha256 = fields.payload_sha256 orelse "";
    if (fields.payload_sha256 != null and !std.mem.eql(u8, payload_sha256, UNSIGNED_PAYLOAD) and
        !(payload_sha256.len == 64 and isLowerHex(payload_sha256))) return error.InvalidField;

    return .{
        .method = method,
        .host = host,
        .path = target[0..query_start],
        .query = if (query_start < target.len) target[query_start + 1 ..] else "",
        .region = region,
        .service = service,
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = fields.session_token,
        .payload_sha256 = payload_sha256,
        .sign_content_sha256 = isS3(service) or fields.payload_sha256 != null,
        .timestamp = signing_time,
    };
}

const QueryParam = struct {
    key: []const u8,
    value: []const u8,

    fn lessThan(_: void, a: QueryParam, b: QueryParam) bool {
        return switch (std.mem.order(u8, a.key, b.key)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, a.value, b.value),
        };
    }
};

fn hexValue(byte: u8) ?u8 {
    return std.fmt.charToDigit(byte, 16) catch null;
}

/// Writes `value` URI-encoded the way AWS canonicalizes it: existing `%XX`
/// escapes are decoded, then every byte except unreserved ones is written as
/// `%XX` with uppercase hex. A literal `/` is kept when `keep_slash` is set;
/// an escaped `%2F` always stays escaped. `double` encodes the result again.
fn writeUriEncoded(w: *std.Io.Writer, value: []const u8, keep_slash: bool, double: bool) SignError!void {
    var index: usize = 0;
    while (index < value.len) {
        var byte = value[index];
        if (byte == '%') {
            if (index + 2 >= value.len) return error.InvalidUrl;
            const high = hexValue(value[index + 1]) orelse return error.InvalidUrl;
            const low = hexValue(value[index + 2]) orelse return error.InvalidUrl;
            byte = high * 16 + low;
            index += 3;
        } else {
            index += 1;
            if (byte == '/' and keep_slash) {
                try w.writeByte('/');
                continue;
            }
        }
        if (isUnreserved(byte)) {
            try w.writeByte(byte);
        } else {
            try w.print("{s}{X:0>2}", .{ if (double) "%25" else "%", byte });
        }
    }
}

/// True if `segment` decodes to `.` or `..`.
fn isDotSegment(segment: []const u8, dots: usize) bool {
    var rest = segment;
    for (0..dots) |_| {
        if (std.mem.startsWith(u8, rest, ".")) {
            rest = rest[1..];
        } else if (rest.len >= 3 and std.ascii.eqlIgnoreCase(rest[0..3], "%2e")) {
            rest = rest[3..];
        } else return false;
    }
    return rest.len == 0;
}

/// Writes the canonical URI. The path must already be percent-encoded. S3
/// signs it encoded once and as given. Other services first drop empty, `.`
/// and `..` segments, then sign it encoded a second time.
fn writeCanonicalUri(w: *std.Io.Writer, path: []const u8, service: []const u8) SignError!void {
    if (path.len == 0) return w.writeByte('/');
    if (isS3(service)) return writeUriEncoded(w, path, true, false);

    var segments: [MAX_PATH_SEGMENTS][]const u8 = undefined;
    var count: usize = 0;
    var trailing_slash = false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |segment| {
        trailing_slash = segment.len == 0 or isDotSegment(segment, 1) or isDotSegment(segment, 2);
        if (segment.len == 0 or isDotSegment(segment, 1)) continue;
        if (isDotSegment(segment, 2)) {
            count -|= 1;
            continue;
        }
        if (count == MAX_PATH_SEGMENTS) return error.TooManyPathSegments;
        segments[count] = segment;
        count += 1;
    }
    for (segments[0..count]) |segment| {
        try w.writeByte('/');
        try writeUriEncoded(w, segment, false, true);
    }
    if (count == 0 or trailing_slash) try w.writeByte('/');
}

/// Writes the canonical query string. Keys and values are re-encoded as AWS
/// canonicalizes them, using `scratch`, then sorted by key, then value.
fn writeCanonicalQuery(w: *std.Io.Writer, query: []const u8, scratch: []u8) SignError!void {
    var params: [MAX_QUERY_PARAMS]QueryParam = undefined;
    var count: usize = 0;
    var encoded: std.Io.Writer = .fixed(scratch);
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (count == MAX_QUERY_PARAMS) return error.TooManyQueryParams;
        const equal = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key_start = encoded.end;
        try writeUriEncoded(&encoded, pair[0..equal], false, false);
        const value_start = encoded.end;
        if (equal < pair.len) try writeUriEncoded(&encoded, pair[equal + 1 ..], false, false);
        params[count] = .{
            .key = scratch[key_start..value_start],
            .value = scratch[value_start..encoded.end],
        };
        count += 1;
    }
    std.mem.sort(QueryParam, params[0..count], {}, QueryParam.lessThan);
    for (params[0..count], 0..) |param, index| {
        if (index != 0) try w.writeByte('&');
        try w.print("{s}={s}", .{ param.key, param.value });
    }
}

fn hmac(key: []const u8, message: []const u8) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, message, key);
    return out;
}

/// Writes the signed headers, one `Name: value` per line, to `out`.
pub fn sign(request: Request, out: *std.Io.Writer, work: []u8) SignError!void {
    if (request.timestamp <= 0) return error.InvalidTimestamp;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(request.timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var amz_date_buf: [16]u8 = undefined;
    const amz_date = std.fmt.bufPrint(&amz_date_buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return error.InvalidTimestamp;
    const date = amz_date[0..8];

    const payload_sha256 = request.payload_sha256;
    const signed_headers = switch (@as(u2, @intFromBool(request.sign_content_sha256)) << 1 | @intFromBool(request.session_token != null)) {
        0b00 => "host;x-amz-date",
        0b01 => "host;x-amz-date;x-amz-security-token",
        0b10 => "host;x-amz-content-sha256;x-amz-date",
        0b11 => "host;x-amz-content-sha256;x-amz-date;x-amz-security-token",
    };

    // The first half holds the canonical request; the second the re-encoded
    // query parameters it is built from.
    var canonical: std.Io.Writer = .fixed(work[0 .. work.len / 2]);
    try canonical.print("{s}\n", .{request.method});
    try writeCanonicalUri(&canonical, request.path, request.service);
    try canonical.writeByte('\n');
    try writeCanonicalQuery(&canonical, request.query, work[work.len / 2 ..]);
    // Host names are case-insensitive and clients send them lowercase.
    try canonical.writeAll("\nhost:");
    for (request.host) |byte| try canonical.writeByte(std.ascii.toLower(byte));
    try canonical.writeByte('\n');
    if (request.sign_content_sha256) try canonical.print("x-amz-content-sha256:{s}\n", .{payload_sha256});
    try canonical.print("x-amz-date:{s}\n", .{amz_date});
    if (request.session_token) |token| try canonical.print("x-amz-security-token:{s}\n", .{token});
    try canonical.print("\n{s}\n{s}", .{ signed_headers, payload_sha256 });

    var canonical_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(canonical.buffered(), &canonical_hash, .{});

    var scope_buf: [256]u8 = undefined;
    const scope = std.fmt.bufPrint(&scope_buf, "{s}/{s}/{s}/aws4_request", .{ date, request.region, request.service }) catch return error.InvalidField;

    var string_to_sign: std.Io.Writer = .fixed(work);
    try string_to_sign.print("AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ amz_date, scope, std.fmt.bytesToHex(canonical_hash, .lower) });

    var secret_key_buf: [256]u8 = undefined;
    const secret_key = std.fmt.bufPrint(&secret_key_buf, "AWS4{s}", .{request.secret_access_key}) catch return error.InvalidField;
    const date_key = hmac(secret_key, date);
    std.crypto.secureZero(u8, &secret_key_buf);
    const region_key = hmac(&date_key, request.region);
    const service_key = hmac(&region_key, request.service);
    const signing_key = hmac(&service_key, "aws4_request");
    const signature = hmac(&signing_key, string_to_sign.buffered());

    try out.print("X-Amz-Date: {s}\n", .{amz_date});
    if (request.sign_content_sha256) try out.print("X-Amz-Content-Sha256: {s}\n", .{payload_sha256});
    if (request.session_token) |token| try out.print("X-Amz-Security-Token: {s}\n", .{token});
    try out.print("Authorization: AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}\n", .{
        request.access_key_id,
        scope,
        signed_headers,
        std.fmt.bytesToHex(signature, .lower),
    });
}

fn run(input: []const u8) SignError!usize {
    var type_bytes: [TYPE_PREFIX.len + DEFAULT_UUID.len]u8 = undefined;
    const boundary = try readBoundary(&type_bytes);
    const fields = try parseForm(input, boundary);
    var request = try requestFromFields(fields, timestamp);
    var body_hash_hex: [Sha256.digest_length * 2]u8 = undefined;
    if (fields.payload_sha256 == null) {
        var body_hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(fields.body orelse "", &body_hash, .{});
        body_hash_hex = std.fmt.bytesToHex(body_hash, .lower);
        request.payload_sha256 = &body_hash_hex;
    }
    var out: std.Io.Writer = .fixed(&output_buf);
    try sign(request, &out, &canonical_buf);
    return out.end;
}

const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    const output_size = run(input_buf[0..input_size]) catch {
        return .{ .output_size = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{
        .output_size = @intCast(output_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

fn expectSigned(request: Request, expected: []const u8) !void {
    var out_buf: [1024]u8 = undefined;
    var work: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try sign(request, &out, &work);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

// Vectors from the AWS S3 SigV4 documentation, "Examples: Signature
// Calculations in AWS Signature Version 4" (Authenticating Requests: Using
// the Authorization Header).
const s3_example: Request = .{
    .method = "GET",
    .host = "examplebucket.s3.amazonaws.com",
    .path = "/",
    .query = "",
    .region = "us-east-1",
    .service = "s3",
    .access_key_id = "AKIAIOSFODNN7EXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    .payload_sha256 = EMPTY_SHA256,
    .timestamp = 1369353600, // 2013-05-24T00:00:00Z
};

test "signs the S3 GET bucket lifecycle example" {
    var request = s3_example;
    request.query = "lifecycle";
    try expectSigned(request,
        "X-Amz-Date: 20130524T000000Z\n" ++
        "X-Amz-Content-Sha256: " ++ EMPTY_SHA256 ++ "\n" ++
        "Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " ++
        "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543\n");
}

test "signs the S3 list objects example with sorted query parameters" {
    var request = s3_example;
    request.query = "prefix=J&max-keys=2";
    try expectSigned(request,
        "X-Amz-Date: 20130524T000000Z\n" ++
        "X-Amz-Content-Sha256: " ++ EMPTY_SHA256 ++ "\n" ++
        "Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " ++
        "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7\n");
}

test "rejects a missing timestamp" {
    var out_buf: [1024]u8 = undefined;
    var work: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var request = s3_example;
    request.timestamp = 0;
    try std.testing.expectError(error.InvalidTimestamp, sign(request, &out, &work));
}

test "double-encodes the path for services other than S3" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeCanonicalUri(&w, "/a%20b/c", "execute-api");
    try std.testing.expectEqualStrings("/a%2520b/c", w.buffered());
    w = .fixed(&buf);
    try writeCanonicalUri(&w, "//a/./b/../c%2f/", "s3");
    try std.testing.expectEqualStrings("//a/./b/../c%2F/", w.buffered());
}

// Vectors from the AWS SigV4 test suite (aws-sig-v4-test-suite, 2015-08-30),
// which signs only `host` and `x-amz-date`. Vectors that send a literal space
// or UTF-8 in the path are left out: this component takes the path as sent,
// already percent-encoded.
const suite_example: Request = .{
    .method = "GET",
    .host = "example.amazonaws.com",
    .path = "/",
    .query = "",
    .region = "us-east-1",
    .service = "service",
    .access_key_id = "AKIDEXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    .payload_sha256 = EMPTY_SHA256,
    .sign_content_sha256 = false,
    .timestamp = 1440938160, // 2015-08-30T12:36:00Z
};

fn expectSuiteSignature(path: []const u8, query: []const u8, signature: []const u8) !void {
    var request = suite_example;
    request.path = path;
    request.query = query;
    var expected_buf: [512]u8 = undefined;
    try expectSigned(request, try std.fmt.bufPrint(&expected_buf, "X-Amz-Date: 20150830T123600Z\n" ++
        "Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " ++
        "SignedHeaders=host;x-amz-date, Signature={s}\n", .{signature}));
}

test "signs the AWS test suite get-vanilla example" {
    try expectSuiteSignature("/", "", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31");
}

test "normalizes paths like the AWS test suite" {
    const vanilla = "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31";
    try expectSuiteSignature("//", "", vanilla); // get-slash
    try expectSuiteSignature("/./", "", vanilla); // get-slash-dot-slash
    try expectSuiteSignature("/example/..", "", vanilla); // get-relative
    try expectSuiteSignature("/example1/example2/../..", "", vanilla); // get-relative-relative
    try expectSuiteSignature("/./example", "", "ef75d96142cf21edca26f06005da7988e4f8dc83a165a80865db7089db637ec5"); // get-slash-pointless-dot
    try expectSuiteSignature("//example//", "", "9a624bd73a37c9a373b5312afbebe7a714a789de108f0bdfe846570885f57e84"); // get-slashes
    try expectSuiteSignature("/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", "", "07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f"); // get-unreserved
}

test "canonicalizes queries like the AWS test suite" {
    try expectSuiteSignature("/", "Param2=value2&Param1=value1", "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"); // get-vanilla-query-order-key-case
    try expectSuiteSignature("/", "Param1=value1", "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"); // get-vanilla-empty-query-key
    try expectSuiteSignature("/", "%E1%88%B4=bar", "2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04"); // get-vanilla-utf8-query
}

test "re-encodes escapes with uppercase hex and decodes unreserved bytes" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUriEncoded(&w, "/a%2fb%7e+c:", true, false);
    try std.testing.expectEqualStrings("/a%2Fb~%2Bc%3A", w.buffered());
    try std.testing.expectError(error.InvalidUrl, writeUriEncoded(&w, "%2", true, false));
}

test "canonicalizes the host" {
    try std.testing.expectEqualStrings("example.com", try hostWithoutDefaultPort("example.com:443", "443"));
    try std.testing.expectEqualStrings("example.com:8443", try hostWithoutDefaultPort("example.com:8443", "443"));
    try std.testing.expectEqualStrings("[::1]", try hostWithoutDefaultPort("[::1]:80", "80"));
    try std.testing.expectError(error.InvalidUrl, hostWithoutDefaultPort("example.com:", "443"));
    var mixed_case = s3_example;
    mixed_case.host = "ExampleBucket.S3.amazonaws.com";
    mixed_case.query = "lifecycle";
    try expectSigned(mixed_case,
        "X-Amz-Date: 20130524T000000Z\n" ++
        "X-Amz-Content-Sha256: " ++ EMPTY_SHA256 ++ "\n" ++
        "Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " ++
        "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543\n");
}

test "parses form fields and splits the URL" {
    const boundary = "uuid-" ++ DEFAULT_UUID;
    const input =
        "--" ++ boundary ++ "\r\nContent-Disposition: form-data; name=\"method\"\r\n\r\nGET" ++
        "\r\n--" ++ boundary ++ "\r\nContent-Disposition: form-data; name=\"url\"\r\n\r\nhttps://examplebucket.s3.amazonaws.com/?lifecycle" ++
        "\r\n--" ++ boundary ++ "--\r\n";
    const fields = try parseForm(input, boundary);
    try std.testing.expectEqualStrings("GET", fields.method.?);
    var with_rest = fields;
    with_rest.region = "us-east-1";
    with_rest.service = "s3";
    with_rest.access_key_id = "AKIAIOSFODNN7EXAMPLE";
    with_rest.secret_access_key = "secret";
    const request = try requestFromFields(with_rest, 1);
    try std.testing.expectEqualStrings("examplebucket.s3.amazonaws.com", request.host);
    try std.testing.expectEqualStrings("/", request.path);
    try std.testing.expectEqualStrings("lifecycle", request.query);
}

test "rejects unknown and duplicate fields" {
    var fields: Fields = .{};
    try std.testing.expectError(error.UnknownField, fields.set("secret", "x"));
    try fields.set("method", "GET");
    try std.testing.expectError(error.DuplicateField, fields.set("method", "PUT"));
}
