//! Runs one QIP Content component with the bounded Zig Wasm interpreter and
//! draws a heat map of its memory as a KTX2 image, one pixel per byte.
//!
//! Input is the same `multipart/form-data` request as `qip-content-interpreter`:
//! the required `component` part, the optional `input` part, and optional
//! `uniforms[key]` parts.
//!
//! The target runs twice. The first run finds the pages that the target read or
//! wrote and the shadow stack range. The second run records work and access
//! counts for each byte of up to 32 of those pages. Each page becomes one
//! 256x256 tile, 256 bytes per row, and tiles stack from top to bottom in
//! ascending page order.
//!
//! Each instruction of `render` is attributed to the next write outside the
//! shadow stack, and added to the first byte that write touched. A byte's
//! totals therefore show the work done to produce it, and the totals of the
//! whole image add up to the work done before the last such write. A buffer
//! written front to back shows what each byte cost to produce. Stack writes
//! happen every few instructions, so they would otherwise take most of the
//! work.
//!
//! - red: instructions executed.
//! - green: loop iterations (branches back to a `loop`).
//! - blue: calls, direct and indirect.
//! - alpha: 0 for a byte that `render` did not read or write, otherwise the
//!   count of load, store, `memory.copy`, and `memory.fill` operations that
//!   touched it, from 64 upward. A byte that `render` did not touch but that
//!   was loaded before it ran has alpha 40 if it is part of the input and 24
//!   if it is part of a data segment, with red, green, and blue at 0. These
//!   show loaded bytes that the run never used, such as sparsely read tables.
//!
//! Levels are log2 scaled. With `normalize` set to 1 (the default), the
//! largest value of each channel in the image maps to 255. With `normalize`
//! set to 0, each doubling adds 8 levels, so images from different runs
//! compare directly.
//!
//! A target failure, trap, exhausted budget, rejection, or a run that touches
//! no memory becomes an outer rejection.

const std = @import("std");
const interpreter = @import("wasm_interpreter");
const request = @import("content_interpreter_request");
const ktx2 = @import("ktx2_rgba8_srgb");

const INPUT_CAP = request.INPUT_CAP;
const PAGE_BYTES = interpreter.WASM_PAGE_BYTES;
const TILE_SIDE: usize = 256;
const MAX_TILES: usize = ktx2.MAX_DIMENSION / TILE_SIDE;
const OUTPUT_CAP: usize = ktx2.HEADER_SIZE + MAX_TILES * PAGE_BYTES * 4;
const NO_TILE: u8 = std.math.maxInt(u8);
/// Levels added for each doubling when `normalize` is 0.
const ABSOLUTE_LEVELS_PER_DOUBLING: f32 = 8;
/// Lowest alpha for a touched byte, so bytes touched once stay visible.
const ALPHA_FLOOR: u8 = 64;
/// Alpha for an untouched byte that a data segment loaded.
const DATA_ALPHA: u8 = 24;
/// Alpha for an untouched byte of the target's input.
const INPUT_ALPHA: u8 = 40;

comptime {
    std.debug.assert(MAX_TILES < NO_TILE);
    std.debug.assert(TILE_SIDE * TILE_SIDE == PAGE_BYTES);
}

/// Work attributed to writes that started at the byte, and the operations
/// that touched it during `render`.
const ByteStats = extern struct {
    instructions: u32 = 0,
    loops: u32 = 0,
    calls: u32 = 0,
    accesses: u32 = 0,
};

const Work = struct {
    instructions: u64 = 0,
    loops: u64 = 0,
    calls: u64 = 0,
};

var input_content_type = request.default_content_type;
var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var machine: interpreter.Machine = undefined;
var tiles: [MAX_TILES][PAGE_BYTES]ByteStats = undefined;
var tile_pages: [MAX_TILES]u32 = undefined;
var tile_count: usize = 0;
var tile_of_page: [interpreter.MAX_TARGET_MEMORY_PAGES]u8 = undefined;
var instruction_budget: u32 = request.DEFAULT_INSTRUCTION_BUDGET;
var normalize: u32 = 1;
var first_page: u32 = 0;

const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(&input_content_type));
}

export fn input_content_type_size() u32 {
    return input_content_type.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(ktx2.CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return ktx2.CONTENT_TYPE.len;
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

export fn uniform_set_instruction_budget(value: u32) u32 {
    instruction_budget = std.math.clamp(value, 1, request.MAX_INSTRUCTION_BUDGET);
    return instruction_budget;
}

export fn uniform_set_normalize(value: u32) u32 {
    normalize = @intFromBool(value != 0);
    return normalize;
}

export fn uniform_set_first_page(value: u32) u32 {
    first_page = @min(value, interpreter.MAX_TARGET_MEMORY_PAGES - 1);
    return first_page;
}

fn rejected() RenderResult {
    return .{ .output_size = 0, .output_ptr = 0, .failed = 1 };
}

export fn render(input_size: u32) RenderResult {
    if (input_size > INPUT_CAP) @trap();
    defer {
        instruction_budget = request.DEFAULT_INSTRUCTION_BUDGET;
        normalize = 1;
        first_page = 0;
    }

    const parsed = request.parse(input_buf[0..input_size], &input_content_type) catch return rejected();
    _ = request.run(&machine, parsed, instruction_budget) orelse return rejected();
    selectTiles(&machine);
    if (tile_count == 0) return rejected();

    var recorder: Recorder = .{ .stack = machine.stackRange() };
    // The interpreter is deterministic, so the second run touches the same pages.
    _ = request.runObserved(&machine, parsed, instruction_budget, &recorder) orelse return rejected();
    const image = writeImage(&output_buf, &machine, normalize != 0) orelse return rejected();
    return .{
        .output_size = @intCast(image.len),
        .output_ptr = @intCast(@intFromPtr(image.ptr)),
        .failed = 0,
    };
}

/// Picks up to MAX_TILES pages from `first_page` upward that the first run
/// read or wrote, and clears their counters.
fn selectTiles(target: *const interpreter.Machine) void {
    @memset(&tile_of_page, NO_TILE);
    tile_count = 0;
    var page: usize = first_page;
    while (page < target.memory_pages and tile_count < MAX_TILES) : (page += 1) {
        if (target.memoryPageActivity(page) == .untouched) continue;
        tile_of_page[page] = @intCast(tile_count);
        tile_pages[tile_count] = @intCast(page);
        @memset(&tiles[tile_count], .{});
        tile_count += 1;
    }
}

const Recorder = struct {
    stack: ?interpreter.MemoryRange,
    reads: u64 = 0,
    writes: u64 = 0,
    /// Counters at the previous write outside the stack.
    attributed: Work = .{},

    pub fn afterStep(self: *Recorder, target: *const interpreter.Machine) void {
        const counters = target.counters;
        // One instruction does at most one read and one write.
        if (counters.memory_reads != self.reads) {
            self.reads = counters.memory_reads;
            const access = target.last_read_access;
            countAccesses(access.address, access.width);
        }
        if (counters.memory_writes != self.writes) {
            self.writes = counters.memory_writes;
            const access = target.last_write_access;
            countAccesses(access.address, access.width);
            if (self.stack) |stack| {
                if (access.address >= stack.start and access.address < stack.end) return;
            }
            const now: Work = .{
                .instructions = counters.instructions,
                .loops = counters.loop_iterations,
                .calls = counters.calls + counters.indirect_calls,
            };
            addWork(access.address, .{
                .instructions = now.instructions - self.attributed.instructions,
                .loops = now.loops - self.attributed.loops,
                .calls = now.calls - self.attributed.calls,
            });
            self.attributed = now;
        }
    }
};

fn tileByte(address: usize) ?*ByteStats {
    const tile = tile_of_page[address / PAGE_BYTES];
    if (tile == NO_TILE) return null;
    return &tiles[tile][address % PAGE_BYTES];
}

/// Counts one access to each tracked byte in the range.
fn countAccesses(start: usize, length: usize) void {
    const end = start + length;
    var chunk_start = start;
    while (chunk_start < end) {
        const page = chunk_start / PAGE_BYTES;
        const chunk_end = @min(end, (page + 1) * PAGE_BYTES);
        const tile = tile_of_page[page];
        if (tile != NO_TILE) {
            const offset = chunk_start % PAGE_BYTES;
            for (tiles[tile][offset .. offset + (chunk_end - chunk_start)]) |*byte| byte.accesses +|= 1;
        }
        chunk_start = chunk_end;
    }
}

fn addWork(address: usize, work: Work) void {
    const byte = tileByte(address) orelse return;
    byte.instructions +|= saturate(work.instructions);
    byte.loops +|= saturate(work.loops);
    byte.calls +|= saturate(work.calls);
}

fn saturate(value: u64) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn level(value: u32, maximum: u32, normalized: bool) u8 {
    if (value == 0) return 0;
    const doublings = @log2(@as(f32, @floatFromInt(value)) + 1);
    if (normalized) return @intFromFloat(@round(255 * doublings / @log2(@as(f32, @floatFromInt(maximum)) + 1)));
    return @intFromFloat(@min(255, @round(ABSOLUTE_LEVELS_PER_DOUBLING * doublings)));
}

fn alphaLevel(accesses: u32, maximum: u32, normalized: bool) u8 {
    if (accesses == 0) return 0;
    const range: f32 = 255 - ALPHA_FLOOR;
    const doublings = @log2(@as(f32, @floatFromInt(accesses)));
    const above_floor = if (normalized)
        (if (maximum <= 1) range else range * doublings / @log2(@as(f32, @floatFromInt(maximum))))
    else
        @min(range, ABSOLUTE_LEVELS_PER_DOUBLING * doublings);
    return ALPHA_FLOOR + @as(u8, @intFromFloat(@round(above_floor)));
}

/// Alpha for a byte that `render` never touched: whether it was loaded before
/// the run, and from where.
fn preloadedAlpha(provenance: interpreter.MemoryByteProvenance) u8 {
    return switch (provenance) {
        .data => DATA_ALPHA,
        .input => INPUT_ALPHA,
        .untouched, .written => 0,
    };
}

fn writeImage(out: []u8, target: *const interpreter.Machine, normalized: bool) ?[]const u8 {
    const size = ktx2.writeHeader(out, TILE_SIDE, tile_count * TILE_SIDE) orelse return null;
    var maximum: ByteStats = .{};
    if (normalized) {
        for (tiles[0..tile_count]) |*tile| {
            for (tile) |byte| {
                maximum.instructions = @max(maximum.instructions, byte.instructions);
                maximum.loops = @max(maximum.loops, byte.loops);
                maximum.calls = @max(maximum.calls, byte.calls);
                maximum.accesses = @max(maximum.accesses, byte.accesses);
            }
        }
    }
    const pixels = out[ktx2.HEADER_SIZE..size];
    for (tiles[0..tile_count], 0..) |*tile, index| {
        const page_start = @as(usize, tile_pages[index]) * PAGE_BYTES;
        for (tile, 0..) |byte, offset| {
            const pixel = pixels[(index * PAGE_BYTES + offset) * 4 ..][0..4];
            if (byte.accesses == 0) {
                pixel.* = .{ 0, 0, 0, preloadedAlpha(target.memoryByteProvenance(page_start + offset)) };
                continue;
            }
            pixel.* = .{
                level(byte.instructions, maximum.instructions, normalized),
                level(byte.loops, maximum.loops, normalized),
                level(byte.calls, maximum.calls, normalized),
                alphaLevel(byte.accesses, maximum.accesses, normalized),
            };
        }
    }
    return out[0..size];
}

test "absolute levels add 8 per doubling and saturate" {
    try std.testing.expectEqual(@as(u8, 0), level(0, 0, false));
    try std.testing.expectEqual(@as(u8, 8), level(1, 0, false));
    try std.testing.expectEqual(@as(u8, 16), level(3, 0, false));
    try std.testing.expectEqual(@as(u8, 255), level(std.math.maxInt(u32), 0, false));
    try std.testing.expectEqual(@as(u8, 0), alphaLevel(0, 0, false));
    try std.testing.expectEqual(@as(u8, 64), alphaLevel(1, 0, false));
    try std.testing.expectEqual(@as(u8, 72), alphaLevel(2, 0, false));
    try std.testing.expectEqual(@as(u8, 255), alphaLevel(std.math.maxInt(u32), 0, false));
}

test "normalized levels map the maximum to 255" {
    try std.testing.expectEqual(@as(u8, 255), level(1000, 1000, true));
    try std.testing.expectEqual(@as(u8, 0), level(0, 1000, true));
    try std.testing.expect(level(31, 1000, true) < level(500, 1000, true));
    try std.testing.expectEqual(@as(u8, 255), alphaLevel(1, 1, true));
    try std.testing.expectEqual(@as(u8, 64), alphaLevel(1, 50, true));
    try std.testing.expectEqual(@as(u8, 255), alphaLevel(50, 50, true));
}

test "untouched loaded bytes sit below the touched alpha floor" {
    try std.testing.expectEqual(@as(u8, 0), preloadedAlpha(.untouched));
    try std.testing.expect(preloadedAlpha(.data) > 0);
    try std.testing.expect(preloadedAlpha(.data) < preloadedAlpha(.input));
    try std.testing.expect(preloadedAlpha(.input) < ALPHA_FLOOR);
}

fn trackOnly(page: usize) void {
    @memset(&tile_of_page, NO_TILE);
    tile_of_page[page] = 0;
    tile_pages[0] = @intCast(page);
    tile_count = 1;
    @memset(&tiles[0], .{});
}

test "access counts split ranges across pages and skip untracked pages" {
    trackOnly(1);
    countAccesses(PAGE_BYTES - 2, 4);
    countAccesses(PAGE_BYTES + 1, 1);
    try std.testing.expectEqual(@as(u32, 1), tiles[0][0].accesses);
    try std.testing.expectEqual(@as(u32, 2), tiles[0][1].accesses);
    try std.testing.expectEqual(@as(u32, 0), tiles[0][2].accesses);
}

test "work since the previous non-stack write goes to the first byte written" {
    trackOnly(0);
    const target = &machine;
    var recorder: Recorder = .{ .stack = .{ .start = 1000, .end = 2000 } };

    // A stack write takes no work, so the next output write gets all of it.
    target.counters = .{ .instructions = 40, .loop_iterations = 3, .calls = 1, .memory_writes = 1 };
    target.last_write_access = .{ .valid = true, .address = 1500, .width = 4 };
    recorder.afterStep(target);
    target.counters = .{ .instructions = 50, .loop_iterations = 4, .calls = 1, .indirect_calls = 1, .memory_writes = 2 };
    target.last_write_access = .{ .valid = true, .address = 100, .width = 4 };
    recorder.afterStep(target);
    target.counters = .{ .instructions = 57, .loop_iterations = 5, .calls = 1, .indirect_calls = 1, .memory_writes = 3 };
    target.last_write_access = .{ .valid = true, .address = 104, .width = 1 };
    recorder.afterStep(target);

    try std.testing.expectEqual(@as(u32, 0), tiles[0][1500].instructions);
    try std.testing.expectEqual(@as(u32, 1), tiles[0][1500].accesses);
    try std.testing.expectEqual(@as(u32, 50), tiles[0][100].instructions);
    try std.testing.expectEqual(@as(u32, 4), tiles[0][100].loops);
    try std.testing.expectEqual(@as(u32, 2), tiles[0][100].calls);
    try std.testing.expectEqual(@as(u32, 0), tiles[0][101].instructions);
    try std.testing.expectEqual(@as(u32, 1), tiles[0][101].accesses);
    try std.testing.expectEqual(@as(u32, 7), tiles[0][104].instructions);
}
