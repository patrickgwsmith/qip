const std = @import("std");
const wasm_reader = @import("wasm_reader");

pub const TAR_BLOCK: usize = 512;
pub const MAX_RECIPES: usize = 512;
pub const MAX_PATH: usize = 512;

pub const Error = error{
    InvalidTar,
    UnsupportedTarEntry,
    UnsafePath,
    TooManyRecipes,
    PathTooLong,
    InvalidRecipePath,
    InvalidRecipeFilename,
    DuplicateRecipeStep,
    InvalidWasm,
    UnsupportedWasm,
    MissingWasmExport,
};

pub const Recipe = struct {
    path_buf: [MAX_PATH]u8 = undefined,
    path_len: u16 = 0,
    mime_len: u16 = 0,
    order: u8 = 0,
    body: []const u8 = "",

    pub fn path(self: *const Recipe) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn mime(self: *const Recipe) []const u8 {
        return self.path_buf[0..self.mime_len];
    }
};

pub const Book = struct {
    recipes: *[MAX_RECIPES]Recipe,
    order: *[MAX_RECIPES]u16,
    count: usize = 0,

    pub fn sorted(self: *const Book) []const u16 {
        return self.order[0..self.count];
    }
};

const TarOverrides = struct {
    path: ?[]const u8 = null,
    size: ?usize = null,

    fn overlay(base: TarOverrides, next: TarOverrides) TarOverrides {
        return .{
            .path = next.path orelse base.path,
            .size = next.size orelse base.size,
        };
    }
};

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn fieldString(field: []const u8) Error![]const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    if (end < field.len and !allZero(field[end..])) return error.InvalidTar;
    return field[0..end];
}

fn parseTarNumber(field: []const u8) Error!u64 {
    if (field.len == 0) return error.InvalidTar;
    if ((field[0] & 0x80) != 0) {
        if ((field[0] & 0x40) != 0) return error.InvalidTar;
        var value: u64 = field[0] & 0x3f;
        for (field[1..]) |byte| {
            value = std.math.mul(u64, value, 256) catch return error.InvalidTar;
            value = std.math.add(u64, value, byte) catch return error.InvalidTar;
        }
        return value;
    }

    var value: u64 = 0;
    var have_digit = false;
    var ended = false;
    for (field) |byte| {
        if (byte == 0 or byte == ' ') {
            if (have_digit) ended = true;
            continue;
        }
        if (ended or byte < '0' or byte > '7') return error.InvalidTar;
        have_digit = true;
        value = std.math.mul(u64, value, 8) catch return error.InvalidTar;
        value = std.math.add(u64, value, byte - '0') catch return error.InvalidTar;
    }
    return value;
}

fn validTarChecksum(header: []const u8) bool {
    const stored = parseTarNumber(header[148..156]) catch return false;
    var sum: u64 = 0;
    for (header, 0..) |byte, index| {
        sum += if (index >= 148 and index < 156) ' ' else byte;
    }
    return stored == sum;
}

fn paddedSize(size: usize) Error!usize {
    const padded = std.math.add(usize, size, TAR_BLOCK - 1) catch return error.InvalidTar;
    return (padded / TAR_BLOCK) * TAR_BLOCK;
}

fn decimal(bytes: []const u8) Error!usize {
    if (bytes.len == 0) return error.InvalidTar;
    var value: usize = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidTar;
        value = std.math.mul(usize, value, 10) catch return error.InvalidTar;
        value = std.math.add(usize, value, byte - '0') catch return error.InvalidTar;
    }
    return value;
}

fn parsePax(data: []const u8, overrides: *TarOverrides) Error!void {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const space = std.mem.indexOfPos(u8, data, cursor, " ") orelse return error.InvalidTar;
        const record_len = try decimal(data[cursor..space]);
        if (record_len == 0 or record_len > data.len - cursor) return error.InvalidTar;
        const end = cursor + record_len;
        if (data[end - 1] != '\n' or space + 1 >= end) return error.InvalidTar;
        const body = data[space + 1 .. end - 1];
        const equals = std.mem.indexOfScalar(u8, body, '=') orelse return error.InvalidTar;
        const key = body[0..equals];
        const value = body[equals + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            overrides.path = value;
        } else if (std.mem.eql(u8, key, "size")) {
            overrides.size = try decimal(value);
        }
        cursor = end;
    }
}

fn trimExtensionValue(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == 0 or data[end - 1] == '\n')) : (end -= 1) {}
    return data[0..end];
}

fn headerPath(header: []const u8, scratch: *[MAX_PATH]u8) Error![]const u8 {
    const name = try fieldString(header[0..100]);
    const prefix = try fieldString(header[345..500]);
    const length = name.len + prefix.len + @intFromBool(prefix.len != 0);
    if (length > scratch.len) return error.PathTooLong;
    var index: usize = 0;
    if (prefix.len != 0) {
        @memcpy(scratch[index..][0..prefix.len], prefix);
        index += prefix.len;
        scratch[index] = '/';
        index += 1;
    }
    @memcpy(scratch[index..][0..name.len], name);
    return scratch[0..length];
}

fn validatePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > MAX_PATH) return error.UnsafePath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.UnsafePath;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.UnsafePath;
    }
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
    }
}

fn parseRecipePath(raw_path: []const u8, recipe: *Recipe) Error!bool {
    var path = raw_path;
    if (std.mem.startsWith(u8, path, "_recipes/")) path = path["_recipes/".len..];
    if (!std.mem.endsWith(u8, path, ".wasm")) return false;

    var parts = std.mem.splitScalar(u8, path, '/');
    const type_name = parts.next() orelse return error.InvalidRecipePath;
    const subtype = parts.next() orelse return error.InvalidRecipePath;
    const filename = parts.next() orelse return error.InvalidRecipePath;
    if (parts.next() != null or type_name.len == 0 or subtype.len == 0) return error.InvalidRecipePath;
    if (!isASCII(type_name) or !isASCII(subtype) or !isASCII(filename)) {
        return error.InvalidRecipePath;
    }

    var active_name = filename;
    if (active_name.len != 0 and active_name[0] == '-') {
        active_name = active_name[1..];
        _ = try validateRecipeFilename(active_name);
        return false;
    }
    const order = try validateRecipeFilename(active_name);
    if (path.len > recipe.path_buf.len) return error.PathTooLong;
    @memcpy(recipe.path_buf[0..path.len], path);
    recipe.path_len = @intCast(path.len);
    recipe.mime_len = @intCast(type_name.len + 1 + subtype.len);
    recipe.order = order;
    return true;
}

fn isASCII(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isAscii(byte)) return false;
    return true;
}

fn validateRecipeFilename(filename: []const u8) Error!u8 {
    if (filename.len < "00-a.wasm".len or
        filename[0] < '0' or filename[0] > '9' or
        filename[1] < '0' or filename[1] > '9' or
        filename[2] != '-' or
        !std.mem.endsWith(u8, filename, ".wasm") or
        filename.len == "00-.wasm".len)
    {
        return error.InvalidRecipeFilename;
    }
    return (filename[0] - '0') * 10 + filename[1] - '0';
}

const Signature = struct {
    params: u8,
    param0: u8,
    results: u8,
    result0: u8,
};

fn readName(reader: *Reader) Error![]const u8 {
    const length = try reader.varU32();
    return reader.bytes(length);
}

const Reader = struct {
    data: []const u8,
    index: usize = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.index >= self.data.len) return error.InvalidWasm;
        defer self.index += 1;
        return self.data[self.index];
    }

    fn bytes(self: *Reader, count_u32: u32) Error![]const u8 {
        const count: usize = count_u32;
        if (count > self.data.len - self.index) return error.InvalidWasm;
        defer self.index += count;
        return self.data[self.index .. self.index + count];
    }

    fn varU32(self: *Reader) Error!u32 {
        var value: u32 = 0;
        var shift: u5 = 0;
        var i: u8 = 0;
        while (i < 5) : (i += 1) {
            const b = try self.byte();
            value |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return value;
            if (i != 4) shift += 7;
        }
        return error.InvalidWasm;
    }
};

fn exactSignature(signature: Signature, params: u8, param0: u8, results: u8, result0: u8) bool {
    return signature.params == params and signature.param0 == param0 and
        signature.results == results and signature.result0 == result0;
}

const InstructionPolicy = struct {
    pub fn onInstr(_: *InstructionPolicy, instruction: wasm_reader.Instr) Error!void {
        switch (instruction.op) {
            0x40, // memory.grow
            0xfe, // atomics
            => return error.UnsupportedWasm,
            else => {},
        }
    }

    pub fn onBrTableTarget(_: *InstructionPolicy, _: u32) Error!void {}
};

/// Performs the recipe-book's static compatibility check. JavaScript still
/// asks WebAssembly.compile to perform the engine's full validation when the
/// generated book is loaded.
fn validateWasm(wasm: []const u8) Error!void {
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..8], "\x00asm\x01\x00\x00\x00")) return error.InvalidWasm;

    var signatures: [1024]Signature = undefined;
    var signature_count: usize = 0;
    var functions: [4096]u32 = undefined;
    var function_count: usize = 0;
    var memory_count: u32 = 0;
    var memory_exported = false;
    var found: u16 = 0;
    var seen_sections: u16 = 0;
    var reader = Reader{ .data = wasm, .index = 8 };

    while (reader.index < wasm.len) {
        const section_id = try reader.byte();
        const section_size = try reader.varU32();
        const section_bytes = try reader.bytes(section_size);
        if (section_id != 0) {
            if (section_id > 12) return error.InvalidWasm;
            const section_bit = @as(u16, 1) << @intCast(section_id);
            if ((seen_sections & section_bit) != 0) return error.InvalidWasm;
            seen_sections |= section_bit;
        }
        var section = Reader{ .data = section_bytes };
        switch (section_id) {
            0 => {},
            1 => {
                const count = try section.varU32();
                if (count > signatures.len) return error.UnsupportedWasm;
                signature_count = count;
                for (signatures[0..signature_count]) |*signature| {
                    if (try section.byte() != 0x60) return error.InvalidWasm;
                    const params = try section.varU32();
                    var param0: u8 = 0;
                    var param_index: u32 = 0;
                    while (param_index < params) : (param_index += 1) {
                        const value_type = try section.byte();
                        if (param_index == 0) param0 = value_type;
                    }
                    const results = try section.varU32();
                    var result0: u8 = 0;
                    var result_index: u32 = 0;
                    while (result_index < results) : (result_index += 1) {
                        const value_type = try section.byte();
                        if (result_index == 0) result0 = value_type;
                    }
                    signature.* = .{
                        .params = if (params > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(params),
                        .param0 = param0,
                        .results = if (results > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(results),
                        .result0 = result0,
                    };
                }
            },
            2 => if (try section.varU32() != 0) return error.UnsupportedWasm,
            3 => {
                const count = try section.varU32();
                if (count > functions.len) return error.UnsupportedWasm;
                function_count = count;
                for (functions[0..function_count]) |*type_index| {
                    type_index.* = try section.varU32();
                    if (type_index.* >= signature_count) return error.InvalidWasm;
                }
            },
            5 => {
                memory_count = try section.varU32();
                if (memory_count != 1) return error.UnsupportedWasm;
                const flags = try section.byte();
                if (flags > 1) return error.UnsupportedWasm;
                _ = try section.varU32();
                if (flags == 1) _ = try section.varU32();
            },
            8 => return error.UnsupportedWasm,
            7 => {
                const count = try section.varU32();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const name = try readName(&section);
                    const kind = try section.byte();
                    const index = try section.varU32();
                    if (kind == 2 and std.mem.eql(u8, name, "memory")) {
                        if (index != 0) return error.InvalidWasm;
                        memory_exported = true;
                        continue;
                    }
                    if (kind != 0) continue;
                    if (index >= function_count) return error.InvalidWasm;
                    const signature = signatures[functions[index]];
                    const value_sig = exactSignature(signature, 0, 0, 1, 0x7f);
                    if (std.mem.eql(u8, name, "render")) {
                        if (!exactSignature(signature, 1, 0x7f, 1, 0x7e)) return error.InvalidWasm;
                        found |= 1 << 0;
                    } else if (std.mem.eql(u8, name, "input_ptr")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 1;
                    } else if (std.mem.eql(u8, name, "input_utf8_cap")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 2;
                    } else if (std.mem.eql(u8, name, "input_bytes_cap")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 3;
                    } else if (std.mem.eql(u8, name, "output_utf8_cap")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 5;
                    } else if (std.mem.eql(u8, name, "output_bytes_cap")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 6;
                    } else if (std.mem.eql(u8, name, "input_content_type_ptr")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 7;
                    } else if (std.mem.eql(u8, name, "input_content_type_size")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 8;
                    } else if (std.mem.eql(u8, name, "output_content_type_ptr")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 9;
                    } else if (std.mem.eql(u8, name, "output_content_type_size")) {
                        if (!value_sig) return error.InvalidWasm;
                        found |= 1 << 10;
                    }
                }
            },
            10 => {
                const count = try section.varU32();
                if (count != function_count) return error.InvalidWasm;
                var function_index: u32 = 0;
                while (function_index < count) : (function_index += 1) {
                    const body_size = try section.varU32();
                    const body = try section.bytes(body_size);
                    var policy = InstructionPolicy{};
                    wasm_reader.walkFunctionBody(&policy, body) catch |err| switch (err) {
                        error.UnsupportedWasm => return error.UnsupportedWasm,
                        else => return error.InvalidWasm,
                    };
                }
            },
            else => {},
        }
        if (section.index != section.data.len and section_id != 0 and section_id != 4 and section_id != 6 and section_id != 9 and section_id != 11 and section_id != 12) {
            return error.InvalidWasm;
        }
    }

    if (memory_count != 1 or !memory_exported) return error.MissingWasmExport;
    if ((found & 0b11) != 0b11) return error.MissingWasmExport;
    if (@popCount(found & 0b1100) != 1 or @popCount(found & 0b1100000) != 1) return error.MissingWasmExport;
    if (@popCount(found & 0b1_1000_0000) == 1 or @popCount(found & 0b110_0000_0000) == 1) {
        return error.MissingWasmExport;
    }
}

fn lessThan(book: *const Book, a: u16, b: u16) bool {
    const left = &book.recipes[a];
    const right = &book.recipes[b];
    const mime_order = std.mem.order(u8, left.mime(), right.mime());
    if (mime_order != .eq) return mime_order == .lt;
    if (left.order != right.order) return left.order < right.order;
    return std.mem.lessThan(u8, left.path(), right.path());
}

fn sortAndCheck(book: *Book) Error!void {
    var i: usize = 1;
    while (i < book.count) : (i += 1) {
        const value = book.order[i];
        var position = i;
        while (position > 0 and lessThan(book, value, book.order[position - 1])) : (position -= 1) {
            book.order[position] = book.order[position - 1];
        }
        book.order[position] = value;
    }
    for (book.order[1..book.count], book.order[0 .. book.count - 1]) |current_index, previous_index| {
        const current = &book.recipes[current_index];
        const previous = &book.recipes[previous_index];
        if (std.mem.eql(u8, current.mime(), previous.mime()) and current.order == previous.order) {
            return error.DuplicateRecipeStep;
        }
    }
}

pub fn parse(input: []const u8, recipes: *[MAX_RECIPES]Recipe, order: *[MAX_RECIPES]u16) Error!Book {
    if (input.len < TAR_BLOCK * 2 or input.len % TAR_BLOCK != 0) return error.InvalidTar;
    var book = Book{ .recipes = recipes, .order = order };
    var cursor: usize = 0;
    var zero_blocks: usize = 0;
    var global = TarOverrides{};
    var pending = TarOverrides{};
    var have_pending = false;
    var path_scratch: [MAX_PATH]u8 = undefined;

    while (cursor + TAR_BLOCK <= input.len) {
        const header = input[cursor .. cursor + TAR_BLOCK];
        if (allZero(header)) {
            zero_blocks += 1;
            cursor += TAR_BLOCK;
            if (zero_blocks == 2) {
                if (!allZero(input[cursor..]) or have_pending) return error.InvalidTar;
                try sortAndCheck(&book);
                return book;
            }
            continue;
        }
        if (zero_blocks != 0 or !validTarChecksum(header)) return error.InvalidTar;
        const header_size_u64 = try parseTarNumber(header[124..136]);
        if (header_size_u64 > std.math.maxInt(usize)) return error.InvalidTar;
        const header_size: usize = @intCast(header_size_u64);
        const data_start = cursor + TAR_BLOCK;
        const type_flag = header[156];

        if (type_flag == 'x' or type_flag == 'g' or type_flag == 'L' or type_flag == 'K') {
            const padded = try paddedSize(header_size);
            if (padded > input.len - data_start or header_size > input.len - data_start) return error.InvalidTar;
            const data = input[data_start .. data_start + header_size];
            if (!allZero(input[data_start + header_size .. data_start + padded])) return error.InvalidTar;
            if (type_flag == 'x') {
                try parsePax(data, &pending);
            } else if (type_flag == 'g') {
                try parsePax(data, &global);
            } else if (type_flag == 'L') {
                pending.path = trimExtensionValue(data);
            }
            if (type_flag != 'g') have_pending = true;
            cursor = data_start + padded;
            continue;
        }

        const effective = global.overlay(pending);
        const body_size = effective.size orelse header_size;
        const padded = try paddedSize(body_size);
        if (padded > input.len - data_start or body_size > input.len - data_start) return error.InvalidTar;
        if (!allZero(input[data_start + body_size .. data_start + padded])) return error.InvalidTar;
        const raw_path = effective.path orelse try headerPath(header, &path_scratch);
        var checked_path = raw_path;
        while (checked_path.len > 0 and checked_path[checked_path.len - 1] == '/') checked_path = checked_path[0 .. checked_path.len - 1];
        try validatePath(checked_path);

        const kind: u8 = if (type_flag == 0) '0' else type_flag;
        switch (kind) {
            '0' => {
                if (book.count >= MAX_RECIPES) return error.TooManyRecipes;
                var recipe = &book.recipes[book.count];
                if (try parseRecipePath(checked_path, recipe)) {
                    recipe.body = input[data_start .. data_start + body_size];
                    try validateWasm(recipe.body);
                    book.order[book.count] = @intCast(book.count);
                    book.count += 1;
                }
            },
            '5' => if (body_size != 0) return error.InvalidTar,
            else => return error.UnsupportedTarEntry,
        }

        pending = .{};
        have_pending = false;
        cursor = data_start + padded;
    }
    return error.InvalidTar;
}

pub const TarWriter = struct {
    output: []u8,
    index: usize = 0,

    pub fn init(output: []u8) TarWriter {
        return .{ .output = output };
    }

    fn reserve(self: *TarWriter, count: usize) Error![]u8 {
        if (count > self.output.len - self.index) return error.InvalidTar;
        const start = self.index;
        self.index += count;
        return self.output[start..self.index];
    }

    fn octal(field: []u8, value: usize) Error!void {
        @memset(field, '0');
        field[field.len - 1] = 0;
        var remaining = value;
        var position = field.len - 1;
        while (remaining != 0) {
            if (position == 0) return error.InvalidTar;
            position -= 1;
            field[position] = @intCast('0' + (remaining & 7));
            remaining >>= 3;
        }
    }

    pub fn addFile(self: *TarWriter, path: []const u8, body: []const u8) Error!void {
        if (path.len == 0 or path.len > 100) return error.PathTooLong;
        try validatePath(path);
        const header = try self.reserve(TAR_BLOCK);
        @memset(header, 0);
        @memcpy(header[0..path.len], path);
        try octal(header[100..108], 0o644);
        try octal(header[108..116], 0);
        try octal(header[116..124], 0);
        try octal(header[124..136], body.len);
        try octal(header[136..148], 0);
        @memset(header[148..156], ' ');
        header[156] = '0';
        @memcpy(header[257..263], "ustar\x00");
        @memcpy(header[263..265], "00");
        var checksum: usize = 0;
        for (header) |byte| checksum += byte;
        try octal(header[148..155], checksum);
        header[155] = ' ';

        const destination = try self.reserve(body.len);
        @memcpy(destination, body);
        const padding = (TAR_BLOCK - body.len % TAR_BLOCK) % TAR_BLOCK;
        @memset(try self.reserve(padding), 0);
    }

    pub fn finish(self: *TarWriter) Error!usize {
        @memset(try self.reserve(TAR_BLOCK * 2), 0);
        return self.index;
    }
};
