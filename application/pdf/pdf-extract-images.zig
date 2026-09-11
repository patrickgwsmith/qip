//! Extract supported PDF image XObjects into a tar archive.
//!
//! This deliberately scans indirect objects rather than rendering pages. It
//! emits each supported image stream once, in file order:
//!   - DCTDecode as the original JPEG bytes
//!   - JPXDecode as the original JPEG 2000 bytes
//!   - unfiltered, RunLengthDecode, and FlateDecode DeviceGray, DeviceRGB,
//!     and direct Indexed rasters as PNG
//!   - CCITTFaxDecode Group 4 streams in a lossless TIFF wrapper
//!
//! ASCII85/ASCIIHex wrappers around JPEG and JPEG 2000 streams are decoded.
//! Inline images, encrypted PDFs, indirect image properties, masks, ICC
//! colour spaces, and other multi-filter streams are left for later.

const std = @import("std");
const inflate = @import("inflate");

const INPUT_CAP: usize = 64 * 1024 * 1024;
const OUTPUT_CAP: usize = 128 * 1024 * 1024;
const RASTER_CAP: usize = 64 * 1024 * 1024;
const TAR_BLOCK: usize = 512;
const INPUT_CONTENT_TYPE = "application/pdf";
const OUTPUT_CONTENT_TYPE = "application/x-tar";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var raster_buf: [RASTER_CAP]u8 = undefined;

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

const Output = struct {
    index: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Output, byte: u8) void {
        if (self.overflow) return;
        if (self.index >= output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.index] = byte;
        self.index += 1;
    }

    fn writeSlice(self: *Output, bytes: []const u8) void {
        if (self.overflow or bytes.len == 0) return;
        if (bytes.len > output_buf.len - self.index) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.index .. self.index + bytes.len], bytes);
        self.index += bytes.len;
    }

    fn writeZeros(self: *Output, count: usize) void {
        if (self.overflow or count == 0) return;
        if (count > output_buf.len - self.index) {
            self.overflow = true;
            return;
        }
        @memset(output_buf[self.index .. self.index + count], 0);
        self.index += count;
    }
};

fn isWhite(byte: u8) bool {
    return byte == 0 or byte == '\t' or byte == '\n' or byte == '\x0c' or byte == '\r' or byte == ' ';
}

fn isDelimiter(byte: u8) bool {
    return isWhite(byte) or byte == '(' or byte == ')' or byte == '<' or byte == '>' or
        byte == '[' or byte == ']' or byte == '{' or byte == '}' or byte == '/' or byte == '%';
}

const TokenKind = enum {
    integer,
    name,
    word,
    dict_open,
    dict_close,
    array_open,
    array_close,
    opaque_value,
};

const Token = struct {
    kind: TokenKind,
    bytes: []const u8,
    integer: i64 = 0,
};

const Lexer = struct {
    input: []const u8,
    pos: usize,

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.input.len) {
            if (isWhite(self.input[self.pos])) {
                self.pos += 1;
                continue;
            }
            if (self.input[self.pos] == '%') {
                while (self.pos < self.input.len and self.input[self.pos] != '\r' and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }

    fn next(self: *Lexer) ?Token {
        self.skipSpace();
        if (self.pos >= self.input.len) return null;

        const start = self.pos;
        const first = self.input[self.pos];
        if (first == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '<') {
            self.pos += 2;
            return .{ .kind = .dict_open, .bytes = self.input[start..self.pos] };
        }
        if (first == '>' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
            self.pos += 2;
            return .{ .kind = .dict_close, .bytes = self.input[start..self.pos] };
        }
        if (first == '[' or first == ']') {
            self.pos += 1;
            return .{
                .kind = if (first == '[') .array_open else .array_close,
                .bytes = self.input[start..self.pos],
            };
        }
        if (first == '/') {
            self.pos += 1;
            const name_start = self.pos;
            while (self.pos < self.input.len and !isDelimiter(self.input[self.pos])) self.pos += 1;
            return .{ .kind = .name, .bytes = self.input[name_start..self.pos] };
        }
        if (first == '(') {
            self.pos += 1;
            var depth: usize = 1;
            while (self.pos < self.input.len and depth != 0) {
                const byte = self.input[self.pos];
                self.pos += 1;
                if (byte == '\\') {
                    if (self.pos < self.input.len) {
                        if (self.input[self.pos] == '\r') {
                            self.pos += 1;
                            if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                        } else {
                            self.pos += 1;
                        }
                    }
                } else if (byte == '(') {
                    depth += 1;
                } else if (byte == ')') {
                    depth -= 1;
                }
            }
            return .{ .kind = .opaque_value, .bytes = self.input[start..self.pos] };
        }
        if (first == '<') {
            self.pos += 1;
            while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
            if (self.pos < self.input.len) self.pos += 1;
            return .{ .kind = .opaque_value, .bytes = self.input[start..self.pos] };
        }

        while (self.pos < self.input.len and !isDelimiter(self.input[self.pos])) self.pos += 1;
        if (self.pos == start) {
            self.pos += 1;
            return .{ .kind = .opaque_value, .bytes = self.input[start..self.pos] };
        }
        const bytes = self.input[start..self.pos];
        const value = std.fmt.parseInt(i64, bytes, 10) catch {
            return .{ .kind = .word, .bytes = bytes };
        };
        return .{ .kind = .integer, .bytes = bytes, .integer = value };
    }
};

const Filter = enum {
    none,
    flate,
    run_length,
    jpeg,
    jpeg2000,
    ccitt,
    unsupported,
};

const OuterEncoding = enum {
    none,
    ascii85,
    ascii_hex,
    unsupported,
};

const ColorSpace = enum {
    unknown,
    gray,
    rgb,
    indexed,
};

const ImageInfo = struct {
    is_image: bool = false,
    width: usize = 0,
    height: usize = 0,
    bits_per_component: usize = 0,
    color_space: ColorSpace = .unknown,
    filter: Filter = .none,
    filter_count: usize = 0,
    outer_encoding: OuterEncoding = .none,
    length: ?usize = null,
    predictor: usize = 1,
    predictor_colors: ?usize = null,
    predictor_columns: ?usize = null,
    predictor_bits: ?usize = null,
    image_mask: bool = false,
    indexed_base: ColorSpace = .unknown,
    indexed_hival: usize = 0,
    indexed_lookup: []const u8 = "",
    decode_values: [8]f32 = [_]f32{0} ** 8,
    decode_count: usize = 0,
    ccitt_k: i32 = 0,
    ccitt_black_is_1: bool = false,
};

fn filterFromName(name: []const u8) Filter {
    if (std.mem.eql(u8, name, "FlateDecode") or std.mem.eql(u8, name, "Fl")) return .flate;
    if (std.mem.eql(u8, name, "RunLengthDecode") or std.mem.eql(u8, name, "RL")) return .run_length;
    if (std.mem.eql(u8, name, "DCTDecode") or std.mem.eql(u8, name, "DCT")) return .jpeg;
    if (std.mem.eql(u8, name, "JPXDecode")) return .jpeg2000;
    if (std.mem.eql(u8, name, "CCITTFaxDecode") or std.mem.eql(u8, name, "CCF")) return .ccitt;
    return .unsupported;
}

fn addFilter(info: *ImageInfo, name: []const u8) void {
    info.filter_count += 1;
    if (info.filter_count == 1) {
        if (std.mem.eql(u8, name, "ASCII85Decode") or std.mem.eql(u8, name, "A85")) {
            info.outer_encoding = .ascii85;
            return;
        }
        if (std.mem.eql(u8, name, "ASCIIHexDecode") or std.mem.eql(u8, name, "AHx")) {
            info.outer_encoding = .ascii_hex;
            return;
        }
        info.filter = filterFromName(name);
        return;
    }
    if (info.filter_count == 2 and info.outer_encoding != .none and info.outer_encoding != .unsupported) {
        info.filter = filterFromName(name);
        return;
    }
    info.filter = .unsupported;
    info.outer_encoding = .unsupported;
}

fn colorSpaceFromName(name: []const u8) ColorSpace {
    if (std.mem.eql(u8, name, "DeviceGray") or std.mem.eql(u8, name, "G")) return .gray;
    if (std.mem.eql(u8, name, "DeviceRGB") or std.mem.eql(u8, name, "RGB")) return .rgb;
    return .unknown;
}

fn setRootValue(info: *ImageInfo, key: []const u8, token: Token) void {
    if (std.mem.eql(u8, key, "Subtype") and token.kind == .name) {
        info.is_image = std.mem.eql(u8, token.bytes, "Image");
    } else if (std.mem.eql(u8, key, "Width") and token.kind == .integer and token.integer > 0) {
        info.width = @intCast(token.integer);
    } else if (std.mem.eql(u8, key, "Height") and token.kind == .integer and token.integer > 0) {
        info.height = @intCast(token.integer);
    } else if (std.mem.eql(u8, key, "BitsPerComponent") and token.kind == .integer and token.integer > 0) {
        info.bits_per_component = @intCast(token.integer);
    } else if (std.mem.eql(u8, key, "ColorSpace") and token.kind == .name) {
        info.color_space = colorSpaceFromName(token.bytes);
    } else if (std.mem.eql(u8, key, "Length") and token.kind == .integer and token.integer >= 0) {
        info.length = @intCast(token.integer);
    } else if (std.mem.eql(u8, key, "ImageMask") and token.kind == .word) {
        info.image_mask = std.mem.eql(u8, token.bytes, "true");
    } else if (std.mem.eql(u8, key, "Filter") and token.kind == .name) {
        addFilter(info, token.bytes);
    }
}

fn setDecodeValue(info: *ImageInfo, key: []const u8, token: Token) void {
    if (std.mem.eql(u8, key, "K") and token.kind == .integer) {
        if (token.integer >= std.math.minInt(i32) and token.integer <= std.math.maxInt(i32)) {
            info.ccitt_k = @intCast(token.integer);
        }
        return;
    }
    if (std.mem.eql(u8, key, "BlackIs1") and token.kind == .word) {
        info.ccitt_black_is_1 = std.mem.eql(u8, token.bytes, "true");
        return;
    }
    if (token.kind != .integer or token.integer < 0) return;
    const value: usize = @intCast(token.integer);
    if (std.mem.eql(u8, key, "Predictor")) {
        info.predictor = value;
    } else if (std.mem.eql(u8, key, "Colors")) {
        info.predictor_colors = value;
    } else if (std.mem.eql(u8, key, "Columns")) {
        info.predictor_columns = value;
    } else if (std.mem.eql(u8, key, "BitsPerComponent")) {
        info.predictor_bits = value;
    }
}

const ActiveArray = enum {
    none,
    filter,
    color_space,
    decode,
};

fn parseNumber(token: Token) ?f32 {
    if (token.kind == .integer) return @floatFromInt(token.integer);
    if (token.kind != .word) return null;
    const value = std.fmt.parseFloat(f32, token.bytes) catch return null;
    if (!std.math.isFinite(value)) return null;
    return value;
}

fn parseImageDictionary(input: []const u8, dict_start: usize) ?struct { info: ImageInfo, end: usize } {
    var lexer = Lexer{ .input = input, .pos = dict_start };
    const opening = lexer.next() orelse return null;
    if (opening.kind != .dict_open) return null;

    var info = ImageInfo{};
    var depth: usize = 1;
    var array_depth: usize = 0;
    var decode_depth: ?usize = null;
    var root_key: ?[]const u8 = null;
    var decode_key: ?[]const u8 = null;
    var active_array: ActiveArray = .none;
    var color_space_index: usize = 0;

    while (lexer.next()) |token| {
        switch (token.kind) {
            .dict_open => {
                depth += 1;
                if (depth == 2 and root_key != null and
                    (std.mem.eql(u8, root_key.?, "DecodeParms") or std.mem.eql(u8, root_key.?, "DP")))
                {
                    decode_depth = depth;
                    root_key = null;
                }
                continue;
            },
            .dict_close => {
                if (depth == 0) return null;
                if (decode_depth != null and decode_depth.? == depth) {
                    decode_depth = null;
                    decode_key = null;
                }
                depth -= 1;
                if (depth == 0) return .{ .info = info, .end = lexer.pos };
                continue;
            },
            .array_open => {
                array_depth += 1;
                if (depth == 1 and array_depth == 1 and root_key != null) {
                    if (std.mem.eql(u8, root_key.?, "Filter")) {
                        active_array = .filter;
                        info.filter_count = 0;
                        info.filter = .none;
                        info.outer_encoding = .none;
                    } else if (std.mem.eql(u8, root_key.?, "ColorSpace") or
                        std.mem.eql(u8, root_key.?, "CS"))
                    {
                        active_array = .color_space;
                        color_space_index = 0;
                    } else if (std.mem.eql(u8, root_key.?, "Decode") or
                        std.mem.eql(u8, root_key.?, "D"))
                    {
                        active_array = .decode;
                        info.decode_count = 0;
                    }
                    root_key = null;
                }
                continue;
            },
            .array_close => {
                if (array_depth > 0) array_depth -= 1;
                if (array_depth == 0) active_array = .none;
                continue;
            },
            else => {},
        }

        if (array_depth > 0) {
            switch (active_array) {
                .filter => {
                    if (token.kind == .name) addFilter(&info, token.bytes);
                },
                .color_space => {
                    if (color_space_index == 0 and token.kind == .name and
                        (std.mem.eql(u8, token.bytes, "Indexed") or std.mem.eql(u8, token.bytes, "I")))
                    {
                        info.color_space = .indexed;
                    } else if (color_space_index == 1 and token.kind == .name) {
                        info.indexed_base = colorSpaceFromName(token.bytes);
                    } else if (color_space_index == 2 and token.kind == .integer and
                        token.integer >= 0 and token.integer <= 255)
                    {
                        info.indexed_hival = @intCast(token.integer);
                    } else if (color_space_index == 3 and token.kind == .opaque_value) {
                        info.indexed_lookup = token.bytes;
                    }
                    color_space_index += 1;
                },
                .decode => {
                    if (info.decode_count < info.decode_values.len) {
                        if (parseNumber(token)) |value| {
                            info.decode_values[info.decode_count] = value;
                            info.decode_count += 1;
                        }
                    }
                },
                .none => {},
            }
            continue;
        }

        if (decode_depth != null and depth == decode_depth.? and array_depth == 0) {
            if (decode_key == null) {
                if (token.kind == .name) decode_key = token.bytes;
            } else {
                setDecodeValue(&info, decode_key.?, token);
                decode_key = null;
            }
            continue;
        }

        if (depth == 1 and array_depth == 0) {
            if (root_key == null) {
                if (token.kind == .name) root_key = token.bytes;
            } else {
                setRootValue(&info, root_key.?, token);
                root_key = null;
            }
        }
    }
    return null;
}

fn tokenBoundary(input: []const u8, start: usize, len: usize) bool {
    const before = start == 0 or isDelimiter(input[start - 1]);
    const after = start + len == input.len or isDelimiter(input[start + len]);
    return before and after;
}

fn findKeyword(input: []const u8, start: usize, keyword: []const u8) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, input, cursor, keyword)) |at| {
        if (tokenBoundary(input, at, keyword.len)) return at;
        cursor = at + keyword.len;
    }
    return null;
}

const PdfObject = struct {
    info: ImageInfo,
    stream: ?[]const u8,
    next: usize,
};

fn findNextObject(input: []const u8, start: usize) ?PdfObject {
    var lexer = Lexer{ .input = input, .pos = start };
    var prior2: ?Token = null;
    var prior1: ?Token = null;

    while (lexer.next()) |token| {
        if (token.kind == .word and std.mem.eql(u8, token.bytes, "obj") and
            prior2 != null and prior2.?.kind == .integer and prior2.?.integer >= 0 and
            prior1 != null and prior1.?.kind == .integer and prior1.?.integer >= 0)
        {
            lexer.skipSpace();
            const parsed = parseImageDictionary(input, lexer.pos) orelse {
                const endobj = findKeyword(input, lexer.pos, "endobj") orelse return null;
                lexer.pos = endobj + "endobj".len;
                prior2 = null;
                prior1 = null;
                continue;
            };

            var after = Lexer{ .input = input, .pos = parsed.end };
            const maybe_stream = after.next();
            if (maybe_stream == null or maybe_stream.?.kind != .word or
                !std.mem.eql(u8, maybe_stream.?.bytes, "stream"))
            {
                const endobj = findKeyword(input, parsed.end, "endobj") orelse input.len;
                return .{ .info = parsed.info, .stream = null, .next = @min(input.len, endobj + "endobj".len) };
            }

            var stream_start = after.pos;
            if (stream_start < input.len and input[stream_start] == '\r') {
                stream_start += 1;
                if (stream_start < input.len and input[stream_start] == '\n') stream_start += 1;
            } else if (stream_start < input.len and input[stream_start] == '\n') {
                stream_start += 1;
            } else {
                const endobj = findKeyword(input, after.pos, "endobj") orelse input.len;
                return .{ .info = parsed.info, .stream = null, .next = @min(input.len, endobj + "endobj".len) };
            }

            var stream_end: usize = undefined;
            if (parsed.info.length) |length| {
                if (length > input.len - stream_start) return null;
                stream_end = stream_start + length;
                var check = stream_end;
                while (check < input.len and isWhite(input[check])) check += 1;
                if (check + "endstream".len > input.len or
                    !std.mem.eql(u8, input[check .. check + "endstream".len], "endstream"))
                {
                    stream_end = findKeyword(input, stream_start, "endstream") orelse return null;
                    while (stream_end > stream_start and
                        (input[stream_end - 1] == '\r' or input[stream_end - 1] == '\n'))
                    {
                        stream_end -= 1;
                    }
                }
            } else {
                stream_end = findKeyword(input, stream_start, "endstream") orelse return null;
                while (stream_end > stream_start and
                    (input[stream_end - 1] == '\r' or input[stream_end - 1] == '\n'))
                {
                    stream_end -= 1;
                }
            }
            const endstream = findKeyword(input, stream_end, "endstream") orelse return null;
            const endobj = findKeyword(input, endstream + "endstream".len, "endobj") orelse input.len;
            return .{
                .info = parsed.info,
                .stream = input[stream_start..stream_end],
                .next = @min(input.len, endobj + "endobj".len),
            };
        }
        prior2 = prior1;
        prior1 = token;
    }
    return null;
}

fn writeOctal(field: []u8, value: u64) bool {
    if (field.len < 2) return false;
    @memset(field, '0');
    field[field.len - 1] = 0;
    var remaining = value;
    var index = field.len - 2;
    while (true) {
        field[index] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
        if (remaining == 0) break;
        if (index == 0) return false;
        index -= 1;
    }
    return true;
}

fn buildTarHeader(path: []const u8, size: usize, header: *[TAR_BLOCK]u8) bool {
    if (path.len == 0 or path.len > 100) return false;
    @memset(header, 0);
    @memcpy(header[0..path.len], path);
    if (!writeOctal(header[100..108], 0o644) or
        !writeOctal(header[108..116], 0) or
        !writeOctal(header[116..124], 0) or
        !writeOctal(header[124..136], @intCast(size)) or
        !writeOctal(header[136..148], 0))
    {
        return false;
    }
    @memset(header[148..156], ' ');
    header[156] = '0';
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header) |byte| sum += byte;

    var checksum: [8]u8 = undefined;
    @memset(&checksum, 0);
    if (!writeOctal(checksum[0..7], sum)) return false;
    @memcpy(header[148..154], checksum[0..6]);
    header[154] = 0;
    header[155] = ' ';
    return true;
}

fn finishTarEntry(out: *Output, header_at: usize, body_at: usize, path: []const u8) bool {
    if (out.overflow or body_at > out.index) return false;
    const body_len = out.index - body_at;
    var header: [TAR_BLOCK]u8 = undefined;
    if (!buildTarHeader(path, body_len, &header)) return false;
    @memcpy(output_buf[header_at .. header_at + TAR_BLOCK], &header);
    const remainder = body_len % TAR_BLOCK;
    if (remainder != 0) out.writeZeros(TAR_BLOCK - remainder);
    return !out.overflow;
}

fn beginTarEntry(out: *Output) ?struct { header: usize, body: usize } {
    const header = out.index;
    out.writeZeros(TAR_BLOCK);
    if (out.overflow) return null;
    return .{ .header = header, .body = out.index };
}

fn numberedPath(buffer: []u8, number: usize, extension: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "image-{d:0>4}.{s}", .{ number, extension }) catch null;
}

const CRC_TABLE = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, value| {
        var crc: u32 = @intCast(value);
        var bit: usize = 0;
        while (bit < 8) : (bit += 1) {
            crc = if (crc & 1 != 0) 0xedb88320 ^ (crc >> 1) else crc >> 1;
        }
        entry.* = crc;
    }
    break :blk table;
};

fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >> 8);
    return crc ^ 0xffffffff;
}

fn writeU32BE(out: *Output, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    out.writeSlice(&bytes);
}

fn writePngChunk(out: *Output, kind: *const [4]u8, data: []const u8) void {
    writeU32BE(out, @intCast(data.len));
    const crc_start = out.index;
    out.writeSlice(kind);
    out.writeSlice(data);
    if (out.overflow) return;
    writeU32BE(out, crc32(output_buf[crc_start..out.index]));
}

fn pngColorType(info: ImageInfo) ?u8 {
    if (info.color_space == .gray) return 0;
    if (info.color_space == .rgb) return 2;
    if (info.color_space == .indexed) return 3;
    return null;
}

fn validPngBitDepth(bits: usize) bool {
    return bits == 1 or bits == 2 or bits == 4 or bits == 8 or bits == 16;
}

fn imageLayout(info: ImageInfo) ?struct { components: usize, row_bytes: usize, raster_len: usize } {
    if (info.width == 0 or info.height == 0 or !validPngBitDepth(info.bits_per_component)) return null;
    const components: usize = switch (info.color_space) {
        .gray, .indexed => 1,
        .rgb => 3,
        else => return null,
    };
    const row_bits = std.math.mul(usize, info.width, components * info.bits_per_component) catch return null;
    const row_bytes = std.math.add(usize, row_bits, 7) catch return null;
    const rounded = row_bytes / 8;
    const raster_len = std.math.mul(usize, rounded, info.height) catch return null;
    if (raster_len > RASTER_CAP) return null;
    return .{ .components = components, .row_bytes = rounded, .raster_len = raster_len };
}

fn writePngHeader(out: *Output, info: ImageInfo, palette: []const u8) bool {
    const color_type = pngColorType(info) orelse return false;
    if (color_type == 3) {
        if (palette.len == 0 or palette.len > 768 or palette.len % 3 != 0) return false;
    } else if (palette.len != 0) {
        return false;
    }
    out.writeSlice(&[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var ihdr: [13]u8 = [_]u8{0} ** 13;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(info.width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(info.height), .big);
    ihdr[8] = @intCast(info.bits_per_component);
    ihdr[9] = color_type;
    writePngChunk(out, "IHDR", &ihdr);
    if (color_type == 3) writePngChunk(out, "PLTE", palette);
    return !out.overflow;
}

const Adler = struct {
    a: u32 = 1,
    b: u32 = 0,

    fn update(self: *Adler, bytes: []const u8) void {
        for (bytes) |byte| {
            self.a = (self.a + byte) % 65521;
            self.b = (self.b + self.a) % 65521;
        }
    }

    fn value(self: Adler) u32 {
        return (self.b << 16) | self.a;
    }
};

fn writeStoredBlock(out: *Output, bytes: []const u8, final: bool) void {
    std.debug.assert(bytes.len <= 65535);
    out.writeByte(if (final) 1 else 0);
    const length: u16 = @intCast(bytes.len);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], length, .little);
    std.mem.writeInt(u16, header[2..4], ~length, .little);
    out.writeSlice(&header);
    out.writeSlice(bytes);
}

fn writePngFromRaster(out: *Output, info: ImageInfo, pixels: []const u8, palette: []const u8) bool {
    const layout = imageLayout(info) orelse return false;
    if (pixels.len != layout.raster_len or !writePngHeader(out, info, palette)) return false;

    const chunk_length_at = out.index;
    out.writeZeros(4);
    const crc_start = out.index;
    out.writeSlice("IDAT");
    const data_start = out.index;
    out.writeSlice(&[_]u8{ 0x78, 0x01 });

    var adler = Adler{};
    const zero = [_]u8{0};
    var row: usize = 0;
    while (row < info.height) : (row += 1) {
        const row_start = row * layout.row_bytes;
        const first_len = @min(layout.row_bytes, 65534);
        const final_first = row + 1 == info.height and first_len == layout.row_bytes;

        // One stored block contains the PNG filter byte and the first part of
        // the row, avoiding a separate block for every filter byte.
        const combined_len = first_len + 1;
        out.writeByte(if (final_first) 1 else 0);
        var block_header: [4]u8 = undefined;
        const length: u16 = @intCast(combined_len);
        std.mem.writeInt(u16, block_header[0..2], length, .little);
        std.mem.writeInt(u16, block_header[2..4], ~length, .little);
        out.writeSlice(&block_header);
        out.writeByte(0);
        out.writeSlice(pixels[row_start .. row_start + first_len]);
        adler.update(&zero);
        adler.update(pixels[row_start .. row_start + first_len]);

        var consumed = first_len;
        while (consumed < layout.row_bytes) {
            const count = @min(layout.row_bytes - consumed, 65535);
            const final = row + 1 == info.height and consumed + count == layout.row_bytes;
            const part = pixels[row_start + consumed .. row_start + consumed + count];
            writeStoredBlock(out, part, final);
            adler.update(part);
            consumed += count;
        }
    }
    writeU32BE(out, adler.value());
    if (out.overflow) return false;

    const data_len = out.index - data_start;
    if (data_len > std.math.maxInt(u32)) return false;
    std.mem.writeInt(u32, output_buf[chunk_length_at..][0..4], @intCast(data_len), .big);
    writeU32BE(out, crc32(output_buf[crc_start..out.index]));
    writePngChunk(out, "IEND", "");
    return !out.overflow;
}

fn writePngFromPredictorStream(out: *Output, info: ImageInfo, zlib: []const u8, palette: []const u8) bool {
    if (!writePngHeader(out, info, palette)) return false;
    writePngChunk(out, "IDAT", zlib);
    writePngChunk(out, "IEND", "");
    return !out.overflow;
}

fn decodeRunLength(input: []const u8, output: []u8) ?usize {
    var source: usize = 0;
    var target: usize = 0;
    while (source < input.len) {
        const control = input[source];
        source += 1;
        if (control == 128) return target;
        if (control <= 127) {
            const count = @as(usize, control) + 1;
            if (count > input.len - source or count > output.len - target) return null;
            @memcpy(output[target .. target + count], input[source .. source + count]);
            source += count;
            target += count;
        } else {
            const count = 257 - @as(usize, control);
            if (source >= input.len or count > output.len - target) return null;
            @memset(output[target .. target + count], input[source]);
            source += 1;
            target += count;
        }
    }
    return null;
}

fn hexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return null;
}

fn decodeAsciiHex(input: []const u8, output: []u8) ?usize {
    var high: ?u8 = null;
    var target: usize = 0;
    for (input) |byte| {
        if (isWhite(byte)) continue;
        if (byte == '>') break;
        const nibble = hexNibble(byte) orelse return null;
        if (high) |value| {
            if (target >= output.len) return null;
            output[target] = (value << 4) | nibble;
            target += 1;
            high = null;
        } else {
            high = nibble;
        }
    }
    if (high) |value| {
        if (target >= output.len) return null;
        output[target] = value << 4;
        target += 1;
    }
    return target;
}

fn decodeAscii85(input: []const u8, output: []u8) ?usize {
    var source: usize = 0;
    var target: usize = 0;
    var group: [5]u8 = undefined;
    var count: usize = 0;

    while (source < input.len) : (source += 1) {
        const byte = input[source];
        if (isWhite(byte)) continue;
        if (byte == '<' and source + 1 < input.len and input[source + 1] == '~') {
            source += 1;
            continue;
        }
        if (byte == '~') {
            if (source + 1 >= input.len or input[source + 1] != '>') return null;
            break;
        }
        if (byte == 'z') {
            if (count != 0 or target + 4 > output.len) return null;
            @memset(output[target .. target + 4], 0);
            target += 4;
            continue;
        }
        if (byte < '!' or byte > 'u') return null;
        group[count] = byte - '!';
        count += 1;
        if (count == 5) {
            var value: u64 = 0;
            for (group) |digit| value = value * 85 + digit;
            if (value > std.math.maxInt(u32) or target + 4 > output.len) return null;
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @intCast(value), .big);
            @memcpy(output[target .. target + 4], &bytes);
            target += 4;
            count = 0;
        }
    }

    if (count == 1) return null;
    if (count > 1) {
        const output_count = count - 1;
        while (count < 5) : (count += 1) group[count] = 'u' - '!';
        var value: u64 = 0;
        for (group) |digit| value = value * 85 + digit;
        if (value > std.math.maxInt(u32) or target + output_count > output.len) return null;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(value), .big);
        @memcpy(output[target .. target + output_count], bytes[0..output_count]);
        target += output_count;
    }
    return target;
}

fn decodeOuterStream(info: ImageInfo, stream: []const u8) ?[]const u8 {
    return switch (info.outer_encoding) {
        .none => stream,
        .ascii85 => raster_buf[0 .. decodeAscii85(stream, &raster_buf) orelse return null],
        .ascii_hex => raster_buf[0 .. decodeAsciiHex(stream, &raster_buf) orelse return null],
        .unsupported => null,
    };
}

fn decodeLiteralString(input: []const u8, output: []u8) ?usize {
    if (input.len < 2 or input[0] != '(' or input[input.len - 1] != ')') return null;
    var source: usize = 1;
    var target: usize = 0;
    while (source + 1 < input.len) {
        var byte = input[source];
        source += 1;
        if (byte == '\\') {
            if (source + 1 > input.len) return null;
            byte = input[source];
            source += 1;
            switch (byte) {
                'n' => byte = '\n',
                'r' => byte = '\r',
                't' => byte = '\t',
                'b' => byte = 0x08,
                'f' => byte = 0x0c,
                '\r' => {
                    if (source < input.len and input[source] == '\n') source += 1;
                    continue;
                },
                '\n' => continue,
                '0'...'7' => {
                    var value: u16 = byte - '0';
                    var digits: usize = 1;
                    while (digits < 3 and source + 1 < input.len and
                        input[source] >= '0' and input[source] <= '7')
                    {
                        value = value * 8 + input[source] - '0';
                        source += 1;
                        digits += 1;
                    }
                    byte = @truncate(value);
                },
                else => {},
            }
        }
        if (target >= output.len) return null;
        output[target] = byte;
        target += 1;
    }
    return target;
}

fn decodeLookup(input: []const u8, output: []u8) ?usize {
    if (input.len < 2) return null;
    if (input[0] == '<' and input[input.len - 1] == '>') {
        return decodeAsciiHex(input[1 .. input.len - 1], output);
    }
    if (input[0] == '(' and input[input.len - 1] == ')') {
        return decodeLiteralString(input, output);
    }
    return null;
}

fn buildPngPalette(info: ImageInfo, palette: []u8, lookup: []u8) ?[]const u8 {
    if (info.color_space != .indexed or info.indexed_lookup.len == 0) return null;
    if (info.bits_per_component != 1 and info.bits_per_component != 2 and
        info.bits_per_component != 4 and info.bits_per_component != 8)
    {
        return null;
    }
    const base_components: usize = switch (info.indexed_base) {
        .gray => 1,
        .rgb => 3,
        else => return null,
    };
    const source_len = decodeLookup(info.indexed_lookup, lookup) orelse return null;
    const source_entries = info.indexed_hival + 1;
    const needed = std.math.mul(usize, source_entries, base_components) catch return null;
    if (source_len < needed) return null;

    const png_entries = @as(usize, 1) << @intCast(info.bits_per_component);
    if (png_entries * 3 > palette.len) return null;
    var entry: usize = 0;
    while (entry < png_entries) : (entry += 1) {
        const source_entry = @min(entry, info.indexed_hival);
        if (base_components == 1) {
            const value = lookup[source_entry];
            @memset(palette[entry * 3 .. entry * 3 + 3], value);
        } else {
            @memcpy(
                palette[entry * 3 .. entry * 3 + 3],
                lookup[source_entry * 3 .. source_entry * 3 + 3],
            );
        }
    }
    return palette[0 .. png_entries * 3];
}

fn decodeComponentCount(info: ImageInfo) ?usize {
    return switch (info.color_space) {
        .gray, .indexed => 1,
        .rgb => 3,
        else => null,
    };
}

fn decodeIsDefault(info: ImageInfo) bool {
    if (info.decode_count == 0) return true;
    const components = decodeComponentCount(info) orelse return false;
    if (info.decode_count != components * 2) return false;
    const sample_max: f32 = @floatFromInt((@as(u32, 1) << @intCast(info.bits_per_component)) - 1);
    var component: usize = 0;
    while (component < components) : (component += 1) {
        if (info.decode_values[component * 2] != 0) return false;
        const expected_max: f32 = if (info.color_space == .indexed) sample_max else 1;
        if (info.decode_values[component * 2 + 1] != expected_max) return false;
    }
    return true;
}

fn readPackedSample(bytes: []const u8, bit_offset: usize, bit_count: usize) u32 {
    var value: u32 = 0;
    var bit: usize = 0;
    while (bit < bit_count) : (bit += 1) {
        const at = bit_offset + bit;
        value = (value << 1) | ((bytes[at / 8] >> @intCast(7 - at % 8)) & 1);
    }
    return value;
}

fn writePackedSample(bytes: []u8, bit_offset: usize, bit_count: usize, value: u32) void {
    var bit: usize = 0;
    while (bit < bit_count) : (bit += 1) {
        const at = bit_offset + bit;
        const shift: u3 = @intCast(7 - at % 8);
        const mask = @as(u8, 1) << shift;
        const source_shift: u5 = @intCast(bit_count - 1 - bit);
        if ((value >> source_shift) & 1 != 0) {
            bytes[at / 8] |= mask;
        } else {
            bytes[at / 8] &= ~mask;
        }
    }
}

fn applyDecode(info: ImageInfo, pixels: []u8) bool {
    if (decodeIsDefault(info)) return true;
    const layout = imageLayout(info) orelse return false;
    const components = decodeComponentCount(info) orelse return false;
    if (info.decode_count != components * 2 or pixels.len != layout.raster_len) return false;

    const sample_max_u32 = (@as(u32, 1) << @intCast(info.bits_per_component)) - 1;
    const sample_max: f32 = @floatFromInt(sample_max_u32);
    const output_max: f32 = if (info.color_space == .indexed)
        @floatFromInt(info.indexed_hival)
    else
        1;

    var row: usize = 0;
    while (row < info.height) : (row += 1) {
        const row_bit_start = row * layout.row_bytes * 8;
        var sample: usize = 0;
        while (sample < info.width * components) : (sample += 1) {
            const component = sample % components;
            const bit_offset = row_bit_start + sample * info.bits_per_component;
            const input_value = readPackedSample(pixels, bit_offset, info.bits_per_component);
            const input_float: f32 = @floatFromInt(input_value);
            const decode_min = info.decode_values[component * 2];
            const decode_max = info.decode_values[component * 2 + 1];
            var decoded = decode_min + input_float * (decode_max - decode_min) / sample_max;
            decoded = @min(output_max, @max(0, decoded));
            const mapped_float = if (info.color_space == .indexed) decoded else decoded * sample_max;
            const mapped: u32 = @intFromFloat(@round(mapped_float));
            writePackedSample(pixels, bit_offset, info.bits_per_component, mapped);
        }
    }
    return true;
}

fn paethPredictor(left: u8, above: u8, upper_left: u8) u8 {
    const estimate = @as(i32, left) + @as(i32, above) - @as(i32, upper_left);
    const left_distance = @abs(estimate - @as(i32, left));
    const above_distance = @abs(estimate - @as(i32, above));
    const corner_distance = @abs(estimate - @as(i32, upper_left));
    if (left_distance <= above_distance and left_distance <= corner_distance) return left;
    if (above_distance <= corner_distance) return above;
    return upper_left;
}

fn undoPngPredictor(info: ImageInfo, filtered: []u8) ?[]u8 {
    const layout = imageLayout(info) orelse return null;
    const expected = std.math.mul(usize, layout.row_bytes + 1, info.height) catch return null;
    if (filtered.len != expected) return null;
    const components = decodeComponentCount(info) orelse return null;
    const bytes_per_pixel = (components * info.bits_per_component + 7) / 8;

    var row: usize = 0;
    while (row < info.height) : (row += 1) {
        const source = row * (layout.row_bytes + 1);
        const target = row * layout.row_bytes;
        const filter = filtered[source];
        if (filter > 4) return null;
        var column: usize = 0;
        while (column < layout.row_bytes) : (column += 1) {
            const encoded = filtered[source + 1 + column];
            const left = if (column >= bytes_per_pixel) filtered[target + column - bytes_per_pixel] else 0;
            const above = if (row > 0) filtered[target + column - layout.row_bytes] else 0;
            const upper_left = if (row > 0 and column >= bytes_per_pixel)
                filtered[target + column - layout.row_bytes - bytes_per_pixel]
            else
                0;
            const prediction: u8 = switch (filter) {
                0 => 0,
                1 => left,
                2 => above,
                3 => @intCast((@as(u16, left) + @as(u16, above)) / 2),
                4 => paethPredictor(left, above, upper_left),
                else => unreachable,
            };
            filtered[target + column] = encoded +% prediction;
        }
    }
    return filtered[0..layout.raster_len];
}

fn undoTiffPredictor(info: ImageInfo, pixels: []u8) bool {
    const layout = imageLayout(info) orelse return false;
    if (info.bits_per_component != 8 or pixels.len != layout.raster_len) return false;
    var row: usize = 0;
    while (row < info.height) : (row += 1) {
        const start = row * layout.row_bytes;
        var index = layout.components;
        while (index < layout.row_bytes) : (index += 1) {
            pixels[start + index] +%= pixels[start + index - layout.components];
        }
    }
    return true;
}

fn writeRasterImage(out: *Output, info: ImageInfo, stream: []const u8) bool {
    const layout = imageLayout(info) orelse return false;
    if (info.image_mask or info.outer_encoding != .none) return false;
    var palette_buffer: [768]u8 = undefined;
    var lookup_buffer: [768]u8 = undefined;
    const palette: []const u8 = if (info.color_space == .indexed)
        buildPngPalette(info, &palette_buffer, &lookup_buffer) orelse return false
    else
        "";

    var decoded: []u8 = undefined;
    switch (info.filter) {
        .none => {
            if (stream.len != layout.raster_len) return false;
            if (decodeIsDefault(info)) return writePngFromRaster(out, info, stream, palette);
            @memcpy(raster_buf[0..stream.len], stream);
            decoded = raster_buf[0..stream.len];
        },
        .run_length => {
            const size = decodeRunLength(stream, &raster_buf) orelse return false;
            decoded = raster_buf[0..size];
        },
        .flate => {
            const size = inflate.inflateZlib(stream, &raster_buf) orelse return false;
            decoded = raster_buf[0..size];
        },
        else => return false,
    }

    if (info.predictor >= 10 and info.predictor <= 15 and info.filter == .flate) {
        const colors = info.predictor_colors orelse 1;
        const columns = info.predictor_columns orelse 1;
        const bits = info.predictor_bits orelse 8;
        const expected = std.math.mul(usize, layout.row_bytes + 1, info.height) catch return false;
        if (colors != layout.components or columns != info.width or bits != info.bits_per_component or
            decoded.len != expected)
        {
            return false;
        }
        if (decodeIsDefault(info)) return writePngFromPredictorStream(out, info, stream, palette);
        decoded = undoPngPredictor(info, decoded) orelse return false;
    } else if (info.predictor == 2) {
        if (!undoTiffPredictor(info, decoded)) return false;
    } else if (info.predictor != 1) {
        return false;
    }
    if (decoded.len != layout.raster_len) return false;
    if (!applyDecode(info, decoded)) return false;
    return writePngFromRaster(out, info, decoded, palette);
}

fn writeExactEntry(out: *Output, number: usize, extension: []const u8, body: []const u8) bool {
    var path_buffer: [32]u8 = undefined;
    const path = numberedPath(&path_buffer, number, extension) orelse return false;
    const entry = beginTarEntry(out) orelse return false;
    out.writeSlice(body);
    return finishTarEntry(out, entry.header, entry.body, path);
}

fn writeRasterEntry(out: *Output, number: usize, info: ImageInfo, stream: []const u8) bool {
    var path_buffer: [32]u8 = undefined;
    const path = numberedPath(&path_buffer, number, "png") orelse return false;
    const entry = beginTarEntry(out) orelse return false;
    if (!writeRasterImage(out, info, stream)) {
        out.index = entry.header;
        out.overflow = false;
        return false;
    }
    return finishTarEntry(out, entry.header, entry.body, path);
}

fn writeTiffIfdEntry(buffer: []u8, offset: usize, tag: u16, field_type: u16, count: u32, value: u32) void {
    std.mem.writeInt(u16, buffer[offset..][0..2], tag, .little);
    std.mem.writeInt(u16, buffer[offset + 2 ..][0..2], field_type, .little);
    std.mem.writeInt(u32, buffer[offset + 4 ..][0..4], count, .little);
    std.mem.writeInt(u32, buffer[offset + 8 ..][0..4], value, .little);
}

fn ccittPhotometric(info: ImageInfo) ?u16 {
    var inverted = false;
    if (info.decode_count != 0) {
        if (info.decode_count != 2) return null;
        if (info.decode_values[0] == 0 and info.decode_values[1] == 1) {
            inverted = false;
        } else if (info.decode_values[0] == 1 and info.decode_values[1] == 0) {
            inverted = true;
        } else {
            return null;
        }
    }
    const black_is_one = info.ccitt_black_is_1 != inverted;
    // TIFF 0 is WhiteIsZero; TIFF 1 is BlackIsZero.
    return if (black_is_one) 0 else 1;
}

fn writeGroup4Tiff(out: *Output, info: ImageInfo, ccitt: []const u8) bool {
    if (info.width == 0 or info.height == 0 or info.image_mask or info.ccitt_k >= 0 or
        (info.bits_per_component != 0 and info.bits_per_component != 1))
    {
        return false;
    }
    const photometric = ccittPhotometric(info) orelse return false;
    if (info.width > std.math.maxInt(u32) or info.height > std.math.maxInt(u32) or
        ccitt.len > std.math.maxInt(u32))
    {
        return false;
    }

    const entry_count: usize = 10;
    const header_size: usize = 8 + 2 + entry_count * 12 + 4;
    var header: [header_size]u8 = [_]u8{0} ** header_size;
    @memcpy(header[0..4], "II*\x00");
    std.mem.writeInt(u32, header[4..8], 8, .little);
    std.mem.writeInt(u16, header[8..10], entry_count, .little);

    var offset: usize = 10;
    writeTiffIfdEntry(&header, offset, 256, 4, 1, @intCast(info.width)); // ImageWidth
    offset += 12;
    writeTiffIfdEntry(&header, offset, 257, 4, 1, @intCast(info.height)); // ImageLength
    offset += 12;
    writeTiffIfdEntry(&header, offset, 258, 3, 1, 1); // BitsPerSample
    offset += 12;
    writeTiffIfdEntry(&header, offset, 259, 3, 1, 4); // Compression: CCITT Group 4
    offset += 12;
    writeTiffIfdEntry(&header, offset, 262, 3, 1, photometric); // PhotometricInterpretation
    offset += 12;
    writeTiffIfdEntry(&header, offset, 266, 3, 1, 1); // FillOrder: MSB first
    offset += 12;
    writeTiffIfdEntry(&header, offset, 273, 4, 1, header_size); // StripOffsets
    offset += 12;
    writeTiffIfdEntry(&header, offset, 278, 4, 1, @intCast(info.height)); // RowsPerStrip
    offset += 12;
    writeTiffIfdEntry(&header, offset, 279, 4, 1, @intCast(ccitt.len)); // StripByteCounts
    offset += 12;
    writeTiffIfdEntry(&header, offset, 293, 4, 1, 0); // T6Options
    std.mem.writeInt(u32, header[header_size - 4 .. header_size], 0, .little);

    out.writeSlice(&header);
    out.writeSlice(ccitt);
    return !out.overflow;
}

fn writeCcittEntry(out: *Output, number: usize, info: ImageInfo, stream: []const u8) bool {
    const ccitt = decodeOuterStream(info, stream) orelse return false;
    var path_buffer: [32]u8 = undefined;
    const path = numberedPath(&path_buffer, number, "tif") orelse return false;
    const entry = beginTarEntry(out) orelse return false;
    if (!writeGroup4Tiff(out, info, ccitt)) {
        out.index = entry.header;
        out.overflow = false;
        return false;
    }
    return finishTarEntry(out, entry.header, entry.body, path);
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP or input_size < 5) return 0;
    const input = input_buf[0..input_size];
    if (!std.mem.startsWith(u8, input, "%PDF-")) return 0;

    var out = Output{};
    var cursor: usize = 0;
    var image_number: usize = 1;
    while (findNextObject(input, cursor)) |object| {
        if (object.next <= cursor) return 0;
        cursor = object.next;
        if (!object.info.is_image or object.stream == null) continue;

        const emitted = switch (object.info.filter) {
            .jpeg => if (decodeOuterStream(object.info, object.stream.?)) |body|
                writeExactEntry(&out, image_number, "jpg", body)
            else
                false,
            .jpeg2000 => if (decodeOuterStream(object.info, object.stream.?)) |body|
                writeExactEntry(&out, image_number, "jp2", body)
            else
                false,
            .none, .flate, .run_length => writeRasterEntry(&out, image_number, object.info, object.stream.?),
            .ccitt => writeCcittEntry(&out, image_number, object.info, object.stream.?),
            .unsupported => false,
        };
        if (out.overflow) return 0;
        if (emitted) image_number += 1;
    }
    out.writeZeros(TAR_BLOCK * 2);
    if (out.overflow) return 0;
    return @intCast(out.index);
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "run length decoder handles literal and repeated runs" {
    const encoded = [_]u8{ 2, 'a', 'b', 'c', 253, 'x', 128 };
    var decoded: [16]u8 = undefined;
    const size = decodeRunLength(&encoded, &decoded) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abcxxxx", decoded[0..size]);
}

test "lexer ignores obj text inside strings" {
    const source = "1 0 obj << /Note (2 0 obj) >> endobj";
    const object = findNextObject(source, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!object.info.is_image);
    try std.testing.expectEqual(source.len, object.next);
}
