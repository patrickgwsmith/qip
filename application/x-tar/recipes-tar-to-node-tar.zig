const std = @import("std");
const recipe_book = @import("lib/recipe-book.zig");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 160 * 1024 * 1024;
const RUNTIME_CAP: usize = 256 * 1024;
const INPUT_CONTENT_TYPE = "application/x-tar";
const OUTPUT_CONTENT_TYPE = "application/x-tar";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var runtime_buf: [RUNTIME_CAP]u8 = undefined;
var recipes: [recipe_book.MAX_RECIPES]recipe_book.Recipe = undefined;
var recipe_order: [recipe_book.MAX_RECIPES]u16 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
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

const TextWriter = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *TextWriter, value: []const u8) !void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    fn quoted(self: *TextWriter, value: []const u8) !void {
        try self.write("\"");
        const hex = "0123456789abcdef";
        for (value) |byte| {
            if (byte == '"' or byte == '\\') {
                if (2 > self.bytes.len - self.index) return error.OutputOverflow;
                self.bytes[self.index] = '\\';
                self.bytes[self.index + 1] = byte;
                self.index += 2;
            } else if (byte >= 0x20 and byte <= 0x7e) {
                if (self.index == self.bytes.len) return error.OutputOverflow;
                self.bytes[self.index] = byte;
                self.index += 1;
            } else {
                if (6 > self.bytes.len - self.index) return error.OutputOverflow;
                @memcpy(self.bytes[self.index..][0..4], "\\u00");
                self.bytes[self.index + 4] = hex[byte >> 4];
                self.bytes[self.index + 5] = hex[byte & 0x0f];
                self.index += 6;
            }
        }
        try self.write("\"");
    }
};

const RUNTIME_PREFIX =
    \\import { readFile } from "node:fs/promises";
    \\
    \\const decoder = new TextDecoder();
    \\const encoder = new TextEncoder();
    \\const specs = [
    \\
;

const RUNTIME_SUFFIX =
    \\];
    \\
    \\function value(exports, name) {
    \\  const item = exports[name];
    \\  if (typeof item !== "function") {
    \\    throw new Error(`Wasm module must export ${name}() -> i32`);
    \\  }
    \\  return item();
    \\}
    \\
    \\function declaredType(exports, prefix) {
    \\  const pointer = exports[`${prefix}_content_type_ptr`];
    \\  const size = exports[`${prefix}_content_type_size`];
    \\  if (pointer === undefined && size === undefined) return "";
    \\  if (pointer === undefined || size === undefined) {
    \\    throw new Error(`incomplete ${prefix} content-type exports`);
    \\  }
    \\  const start = value(exports, `${prefix}_content_type_ptr`);
    \\  const length = value(exports, `${prefix}_content_type_size`);
    \\  const type = decoder.decode(new Uint8Array(exports.memory.buffer, start, length));
    \\  if (!/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(type)) {
    \\    throw new Error(`invalid declared ${prefix} content type: ${type}`);
    \\  }
    \\  return type;
    \\}
    \\
    \\async function loadStage(spec) {
    \\  const module = await WebAssembly.compile(
    \\    await readFile(new URL(spec[1], import.meta.url)),
    \\  );
    \\  const instance = await WebAssembly.instantiate(module);
    \\  const exports = instance.exports;
    \\  return {
    \\    sourceType: spec[0],
    \\    path: spec[2],
    \\    exports,
    \\    inputType: declaredType(exports, "input"),
    \\    outputType: declaredType(exports, "output"),
    \\    inputCapName: exports.input_utf8_cap ? "input_utf8_cap" : "input_bytes_cap",
    \\    outputCapName: exports.output_utf8_cap ? "output_utf8_cap" : "output_bytes_cap",
    \\    clearsContentType: !!exports.output_utf8_cap && !!exports.input_bytes_cap,
    \\  };
    \\}
    \\
    \\function runChain(chain, sourceType, input) {
    \\  let bytes =
    \\    typeof input === "string"
    \\      ? encoder.encode(input)
    \\      : input instanceof Uint8Array
    \\        ? input
    \\        : new Uint8Array(input);
    \\  let contentType = sourceType;
    \\  for (const stage of chain) {
    \\    const exports = stage.exports;
    \\    if (stage.inputType && stage.inputType !== contentType) {
    \\      throw new Error(`${stage.path} expects ${stage.inputType}, got ${contentType}`);
    \\    }
    \\    const pointer = value(exports, "input_ptr");
    \\    const capacity = value(exports, stage.inputCapName);
    \\    if (bytes.byteLength > capacity || pointer + bytes.byteLength > exports.memory.buffer.byteLength) {
    \\      throw new RangeError(`${stage.path} input exceeds its capacity`);
    \\    }
    \\    new Uint8Array(exports.memory.buffer, pointer, bytes.byteLength).set(bytes);
    \\    const result = exports.render(bytes.byteLength);
    \\    if (typeof result !== "bigint") throw new TypeError(`${stage.path} render must return i64`);
    \\    const bits = BigInt.asUintN(64, result);
    \\    if ((bits & (1n << 63n)) !== 0n) throw new Error(`${stage.path} rejected input`);
    \\    const outputLength = Number(bits & 0xffff_ffffn);
    \\    const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
    \\    const outputCapacity = value(exports, stage.outputCapName);
    \\    if (outputLength > outputCapacity || outputPointer + outputLength > exports.memory.buffer.byteLength) {
    \\      throw new RangeError(`${stage.path} returned an invalid output length`);
    \\    }
    \\    bytes = new Uint8Array(exports.memory.buffer, outputPointer, outputLength).slice();
    \\    if (stage.outputType) contentType = stage.outputType;
    \\    else if (stage.clearsContentType) contentType = "";
    \\  }
    \\  return { bytes, contentType };
    \\}
    \\
    \\function validateChain(chain, sourceType) {
    \\  let contentType = sourceType;
    \\  for (const stage of chain) {
    \\    if (stage.inputType && stage.inputType !== contentType) {
    \\      throw new Error(`${stage.path} expects ${stage.inputType}, got ${contentType}`);
    \\    }
    \\    if (stage.outputType) contentType = stage.outputType;
    \\    else if (stage.clearsContentType) contentType = "";
    \\  }
    \\}
    \\
    \\export async function createRecipeBook() {
    \\  const stages = await Promise.all(specs.map(loadStage));
    \\  const chains = new Map();
    \\  for (const stage of stages) {
    \\    const chain = chains.get(stage.sourceType);
    \\    if (chain) chain.push(stage);
    \\    else chains.set(stage.sourceType, [stage]);
    \\  }
    \\  for (const [sourceType, chain] of chains) validateChain(chain, sourceType);
    \\  const queues = new Map();
    \\  return Object.freeze({
    \\    sourceTypes: Object.freeze([...chains.keys()]),
    \\    render(sourceType, input) {
    \\      const chain = chains.get(sourceType);
    \\      if (!chain) return Promise.reject(new Error(`no recipe for ${sourceType}`));
    \\      const previous = queues.get(sourceType) ?? Promise.resolve();
    \\      const result = previous.then(() => runChain(chain, sourceType, input));
    \\      queues.set(sourceType, result.catch(() => {}));
    \\      return result;
    \\    },
    \\  });
    \\}
    \\
;

fn moduleTarPath(buffer: []u8, ordinal: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "modules/{d:0>3}.wasm", .{ordinal}) catch error.OutputOverflow;
}

fn buildRuntime(book: *const recipe_book.Book, output: []u8) ![]const u8 {
    var writer = TextWriter{ .bytes = output };
    try writer.write(RUNTIME_PREFIX);
    for (book.sorted(), 0..) |recipe_index, ordinal| {
        const recipe = &book.recipes[recipe_index];
        var module_path_buf: [32]u8 = undefined;
        const module_path = try moduleTarPath(&module_path_buf, ordinal);
        try writer.write("  [");
        try writer.quoted(recipe.mime());
        try writer.write(", ");
        try writer.quoted(module_path);
        try writer.write(", ");
        try writer.quoted(recipe.path());
        try writer.write("],\n");
    }
    try writer.write(RUNTIME_SUFFIX);
    return writer.bytes[0..writer.index];
}

fn convert(input: []const u8, output: []u8) !usize {
    const book = try recipe_book.parse(input, &recipes, &recipe_order);
    const runtime = try buildRuntime(&book, &runtime_buf);
    var tar = recipe_book.TarWriter.init(output);
    try tar.addFile("recipe-book.mjs", runtime);
    for (book.sorted(), 0..) |recipe_index, ordinal| {
        var module_path_buf: [32]u8 = undefined;
        const module_path = try moduleTarPath(&module_path_buf, ordinal);
        try tar.addFile(module_path, book.recipes[recipe_index].body);
    }
    return tar.finish();
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > INPUT_CAP) @trap();
    return @intCast(convert(input_buf[0..input_size], &output_buf) catch @trap());
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
