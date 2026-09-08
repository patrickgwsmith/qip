//! Deterministic, instruction-stepped interpreter for a small QIP Wasm profile.
//!
//! The initial profile accepts one fixed wasm32 memory, no imports, direct
//! calls, one fixed `funcref` table,
//! active function-index element segments, `call_indirect`, structured control
//! flow, active data segments, numeric locals and globals, scalar loads/stores,
//! `memory.copy`/`memory.fill`, and a deliberately small SIMD subset.
//! Integer execution is substantially complete; unsupported floating-point
//! operations trap after their operands and types have been decoded.
//! A caller supplies the module bytes and asks the machine to enter the
//! exported `render(i32) -> i64` function. Each call to `step` executes exactly
//! one target instruction and updates factual counters used by debugger UIs.

const std = @import("std");

pub const MAX_MODULE_BYTES: usize = 1024 * 1024;
pub const MAX_TARGET_MEMORY_BYTES: usize = 192 * 1024 * 1024;
pub const WASM_PAGE_BYTES: usize = 65536;
pub const MAX_TARGET_MEMORY_PAGES: usize = MAX_TARGET_MEMORY_BYTES / WASM_PAGE_BYTES;
const MEMORY_PAGE_WORD_BITS: usize = @bitSizeOf(u64);
const MEMORY_PAGE_WORDS: usize = std.math.divCeil(usize, MAX_TARGET_MEMORY_PAGES, MEMORY_PAGE_WORD_BITS) catch unreachable;
pub const MAX_TYPES: usize = 2048;
pub const MAX_FUNCTIONS: usize = 4096;
pub const MAX_TABLE_ENTRIES: usize = 4096;
pub const MAX_GLOBALS: usize = 2048;
pub const MAX_EXPORTS: usize = 1024;
pub const MAX_ELEMENT_SEGMENTS: usize = 512;
pub const MAX_DATA_SEGMENTS: usize = 512;
pub const MAX_INSTRUCTIONS: usize = 131072;
pub const MAX_BRANCH_TABLE_TARGETS: usize = 65536;
pub const MAX_VALUES: usize = 32768;
pub const MAX_LOCALS: usize = 32768;
pub const MAX_LOCAL_TYPES: usize = 131072;
pub const MAX_FRAMES: usize = 256;
pub const MAX_CONTROLS: usize = 4096;
pub const MAX_FUNCTION_PARAMETERS: usize = 64;
const NO_INSTRUCTION: u32 = std.math.maxInt(u32);
const NO_FUNCTION: u32 = std.math.maxInt(u32);

pub const Error = error{
    InvalidWasm,
    UnexpectedEOF,
    InvalidLeb,
    InvalidSection,
    InvalidType,
    InvalidIndex,
    UnsupportedFeature,
    TooManyItems,
    MissingMemory,
    MissingRender,
    InvalidRenderSignature,
    InvalidInputContract,
    MissingInputBuffer,
    InputTooLarge,
    InvalidUTF8,
    MemoryTooLarge,
    StackOverflow,
    StackUnderflow,
    CallDepthExceeded,
    ControlDepthExceeded,
    LocalLimitExceeded,
};

pub const Status = enum {
    empty,
    ready,
    halted,
    trapped,
};

pub const Trap = enum {
    none,
    explicit_unreachable,
    out_of_bounds_memory,
    out_of_bounds_table,
    uninitialized_element,
    indirect_call_type_mismatch,
    divide_by_zero,
    integer_overflow,
    invalid_control,
    unsupported_instruction,
};

pub const Counters = struct {
    instructions: u64 = 0,
    calls: u64 = 0,
    indirect_calls: u64 = 0,
    returns: u64 = 0,
    branches: u64 = 0,
    loop_iterations: u64 = 0,
    memory_reads: u64 = 0,
    memory_writes: u64 = 0,
};

pub const MemoryEvent = struct {
    valid: bool = false,
    address: u32 = 0,
    width: u32 = 0,
};

pub const MemoryAccessKind = enum { none, read, write };

pub const MemoryByteProvenance = enum { untouched, data, input, written };

pub const MemoryPageActivity = enum { untouched, read, written, read_written };

pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
};

/// Raw bits for every numeric WebAssembly value. Scalar values occupy the low
/// 32 or 64 bits; v128 values use all 128 bits.
pub const Value = u128;

const FuncType = struct {
    params: u16,
    results: u1,
    parameter_types: [MAX_FUNCTION_PARAMETERS]ValType = undefined,
    result_type: ?ValType = null,
};

pub const FunctionSignature = struct {
    parameters: []const ValType,
    result: ?ValType,
};

pub const InstructionRange = struct {
    first: u32,
    end: u32,
};

const Function = struct {
    type_index: u32,
    local_count: u32 = 0,
    local_types_offset: u32 = 0,
    first_instruction: u32 = NO_INSTRUCTION,
    final_instruction: u32 = NO_INSTRUCTION,
};

const Global = struct {
    initial: Value,
    value: Value,
    value_type: ValType,
    mutable: bool,
};

const Export = struct {
    name_offset: u32,
    name_length: u32,
    kind: u8,
    index: u32,
};

const DataSegment = struct {
    offset: u32,
    bytes_offset: u32,
    bytes_length: u32,
};

pub const Instruction = struct {
    op: u8,
    function_index: u32,
    byte_offset: u32,
    immediate: u64 = 0,
    immediate2: u32 = 0,
    result_arity: u1 = 0,
    match: u32 = NO_INSTRUCTION,
    else_instruction: u32 = NO_INSTRUCTION,
    depth: u16 = 0,
};

pub const StepTargets = struct {
    into: u32 = NO_INSTRUCTION,
    over: u32 = NO_INSTRUCTION,
    out: u32 = NO_INSTRUCTION,
};

const ControlKind = enum { function, block, loop, if_ };

const Control = struct {
    kind: ControlKind,
    instruction: u32,
    end_instruction: u32,
    stack_base: u32,
    result_arity: u1,
};

const Frame = struct {
    function_index: u32,
    locals_base: u32,
    locals_count: u32,
    stack_base: u32,
    control_base: u32,
    return_instruction: u32,
};

const Reader = struct {
    data: []const u8,
    offset: usize = 0,
    base: usize = 0,

    fn init(data: []const u8, base: usize) Reader {
        return .{ .data = data, .base = base };
    }

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.offset;
    }

    fn byte(self: *Reader) Error!u8 {
        if (self.offset >= self.data.len) return Error.UnexpectedEOF;
        const value = self.data[self.offset];
        self.offset += 1;
        return value;
    }

    fn bytes(self: *Reader, length: usize) Error![]const u8 {
        if (length > self.remaining()) return Error.UnexpectedEOF;
        const start = self.offset;
        self.offset += length;
        return self.data[start..self.offset];
    }

    fn absoluteOffset(self: *const Reader) u32 {
        return @intCast(self.base + self.offset);
    }

    fn varU32(self: *Reader) Error!u32 {
        var result: u32 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.byte();
            if (i == 4 and (b & 0xf0) != 0) return Error.InvalidLeb;
            result |= @as(u32, b & 0x7f) << @intCast(shift);
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return Error.InvalidLeb;
    }

    fn signed(self: *Reader, comptime bits: u7, comptime max_bytes: usize) Error!i64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        var b: u8 = 0;
        var i: usize = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.byte();
            const payload = b & 0x7f;
            result |= @as(u64, payload) << @intCast(shift);
            shift += 7;
            if ((b & 0x80) == 0) {
                if ((b & 0x40) != 0 and shift < 64) result |= ~@as(u64, 0) << @intCast(shift);
                if (bits == 32) return @as(i32, @bitCast(@as(u32, @truncate(result))));
                return @bitCast(result);
            }
        }
        return Error.InvalidLeb;
    }

    fn s32(self: *Reader) Error!i32 {
        return @intCast(try self.signed(32, 5));
    }

    fn s64(self: *Reader) Error!i64 {
        return try self.signed(64, 10);
    }

    fn name(self: *Reader) Error!struct { offset: u32, length: u32 } {
        const length = try self.varU32();
        const offset = self.absoluteOffset();
        _ = try self.bytes(length);
        return .{ .offset = offset, .length = length };
    }
};

pub const Machine = struct {
    module: []const u8 = &.{},
    types: [MAX_TYPES]FuncType = undefined,
    type_count: usize = 0,
    functions: [MAX_FUNCTIONS]Function = undefined,
    function_count: usize = 0,
    table: [MAX_TABLE_ENTRIES]u32 = undefined,
    table_defined: bool = false,
    table_size: usize = 0,
    globals: [MAX_GLOBALS]Global = undefined,
    global_count: usize = 0,
    exports: [MAX_EXPORTS]Export = undefined,
    export_count: usize = 0,
    data_segments: [MAX_DATA_SEGMENTS]DataSegment = undefined,
    data_segment_count: usize = 0,
    instructions: [MAX_INSTRUCTIONS]Instruction = undefined,
    instruction_count: usize = 0,
    branch_table_targets: [MAX_BRANCH_TABLE_TARGETS]u32 = undefined,
    branch_table_target_count: usize = 0,
    loop_counts: [MAX_INSTRUCTIONS]u64 = undefined,
    function_invocations: [MAX_FUNCTIONS]u64 = undefined,
    memory: [MAX_TARGET_MEMORY_BYTES]u8 = undefined,
    memory_written: [MAX_TARGET_MEMORY_BYTES / 8]u8 = undefined,
    memory_pages_read: [MEMORY_PAGE_WORDS]u64 = undefined,
    memory_pages_written: [MEMORY_PAGE_WORDS]u64 = undefined,
    memory_initialized: bool = false,
    memory_size: usize = 0,
    memory_pages: u32 = 0,
    stack: [MAX_VALUES]Value = undefined,
    stack_types: [MAX_VALUES]ValType = undefined,
    stack_count: usize = 0,
    locals: [MAX_LOCALS]Value = undefined,
    local_types: [MAX_LOCALS]ValType = undefined,
    locals_count: usize = 0,
    function_local_types: [MAX_LOCAL_TYPES]ValType = undefined,
    function_local_type_count: usize = 0,
    frames: [MAX_FRAMES]Frame = undefined,
    frame_count: usize = 0,
    controls: [MAX_CONTROLS]Control = undefined,
    control_count: usize = 0,
    render_function: u32 = 0,
    current_instruction: u32 = NO_INSTRUCTION,
    last_executed_instruction: u32 = NO_INSTRUCTION,
    result: u64 = 0,
    status: Status = .empty,
    trap: Trap = .none,
    budget_exhausted: bool = false,
    counters: Counters = .{},
    last_access: MemoryEvent = .{},
    last_access_kind: MemoryAccessKind = .none,
    last_read_access: MemoryEvent = .{},
    last_write_access: MemoryEvent = .{},
    target_input: []const u8 = &.{},
    target_input_ptr: u32 = 0,

    pub fn load(self: *Machine, module: []const u8) Error!void {
        return self.loadWithInput(module, &.{});
    }

    pub fn loadWithInput(self: *Machine, module: []const u8, target_input: []const u8) Error!void {
        if (module.len > MAX_MODULE_BYTES) return Error.TooManyItems;
        self.module = module;
        self.target_input = target_input;
        self.target_input_ptr = 0;
        self.type_count = 0;
        self.function_count = 0;
        self.table_defined = false;
        self.table_size = 0;
        self.global_count = 0;
        self.export_count = 0;
        self.data_segment_count = 0;
        self.instruction_count = 0;
        self.branch_table_target_count = 0;
        self.memory_initialized = false;
        self.memory_size = 0;
        self.memory_pages = 0;
        self.stack_count = 0;
        self.locals_count = 0;
        self.function_local_type_count = 0;
        self.frame_count = 0;
        self.control_count = 0;
        self.current_instruction = NO_INSTRUCTION;
        self.last_executed_instruction = NO_INSTRUCTION;
        self.result = 0;
        self.status = .empty;
        self.trap = .none;
        self.budget_exhausted = false;
        self.counters = .{};
        self.last_access = .{};
        self.last_access_kind = .none;
        self.last_read_access = .{};
        self.last_write_access = .{};
        try self.parseModule();
        if (target_input.len > 0) self.target_input_ptr = try self.resolveInputPointer(target_input.len);
        try self.restart();
    }

    pub fn restart(self: *Machine) Error!void {
        self.resetMemory();
        for (self.globals[0..self.global_count]) |*global| global.value = global.initial;
        for (self.data_segments[0..self.data_segment_count]) |segment| {
            const start: usize = segment.offset;
            const end = start + segment.bytes_length;
            if (end > self.memory_size) return Error.InvalidSection;
            @memcpy(self.memory[start..end], self.module[segment.bytes_offset .. segment.bytes_offset + segment.bytes_length]);
        }
        if (self.target_input.len > 0) {
            const start: usize = self.target_input_ptr;
            @memcpy(self.memory[start .. start + self.target_input.len], self.target_input);
        }
        @memset(self.loop_counts[0..self.instruction_count], 0);
        @memset(self.function_invocations[0..self.function_count], 0);
        self.stack_count = 0;
        self.locals_count = 0;
        self.frame_count = 0;
        self.control_count = 0;
        self.current_instruction = NO_INSTRUCTION;
        self.last_executed_instruction = NO_INSTRUCTION;
        self.result = 0;
        self.status = .ready;
        self.trap = .none;
        self.budget_exhausted = false;
        self.counters = .{};
        self.last_access = .{};
        self.last_access_kind = .none;
        self.last_read_access = .{};
        self.last_write_access = .{};
        try self.enterFunction(self.render_function, 0, &.{@as(Value, self.target_input.len)});
    }

    fn resetMemory(self: *Machine) void {
        const page_words = std.math.divCeil(usize, self.memory_pages, MEMORY_PAGE_WORD_BITS) catch unreachable;
        if (!self.memory_initialized) {
            @memset(self.memory[0..self.memory_size], 0);
            @memset(self.memory_written[0 .. std.math.divCeil(usize, self.memory_size, 8) catch unreachable], 0);
            @memset(self.memory_pages_read[0..page_words], 0);
            @memset(self.memory_pages_written[0..page_words], 0);
            self.memory_initialized = true;
            return;
        }

        var page: usize = 0;
        while (page < self.memory_pages) : (page += 1) {
            const mask = @as(u64, 1) << @intCast(page % MEMORY_PAGE_WORD_BITS);
            if ((self.memory_pages_written[page / MEMORY_PAGE_WORD_BITS] & mask) == 0) continue;
            const start = page * WASM_PAGE_BYTES;
            const end = @min(start + WASM_PAGE_BYTES, self.memory_size);
            @memset(self.memory[start..end], 0);
            @memset(self.memory_written[start / 8 .. std.math.divCeil(usize, end, 8) catch unreachable], 0);
        }
        @memset(self.memory_pages_read[0..page_words], 0);
        @memset(self.memory_pages_written[0..page_words], 0);
    }

    pub fn memoryByteProvenance(self: *const Machine, address: usize) MemoryByteProvenance {
        if (address >= self.memory_size) return .untouched;
        if ((self.memory_written[address / 8] & (@as(u8, 1) << @intCast(address % 8))) != 0) return .written;
        const input_start: usize = self.target_input_ptr;
        if (address >= input_start and address - input_start < self.target_input.len) return .input;
        for (self.data_segments[0..self.data_segment_count]) |segment| {
            const start: usize = segment.offset;
            if (address >= start and address - start < segment.bytes_length) return .data;
        }
        return .untouched;
    }

    pub fn memoryPageActivity(self: *const Machine, page: usize) MemoryPageActivity {
        if (page >= @as(usize, self.memory_pages)) return .untouched;
        const mask = @as(u64, 1) << @intCast(page % MEMORY_PAGE_WORD_BITS);
        const read = (self.memory_pages_read[page / MEMORY_PAGE_WORD_BITS] & mask) != 0;
        const written = (self.memory_pages_written[page / MEMORY_PAGE_WORD_BITS] & mask) != 0;
        if (read and written) return .read_written;
        if (read) return .read;
        if (written) return .written;
        return .untouched;
    }

    pub fn step(self: *Machine) bool {
        if (self.status != .ready) return false;
        self.budget_exhausted = false;
        self.stepImpl() catch {
            if (self.trap == .none) self.trap = .unsupported_instruction;
            self.status = .trapped;
        };
        return true;
    }

    pub fn continueFor(self: *Machine, budget: usize) void {
        var count: usize = 0;
        while (self.status == .ready and count < budget) : (count += 1) _ = self.step();
        if (self.status == .ready) self.budget_exhausted = true;
    }

    pub fn stepOver(self: *Machine, budget: usize) void {
        if (self.status != .ready) return;
        const depth = self.frame_count;
        const is_call = isCallInstruction(self.instructions[self.current_instruction].op);
        _ = self.step();
        if (!is_call) return;
        var count: usize = 1;
        while (self.status == .ready and self.frame_count > depth and count < budget) : (count += 1) _ = self.step();
        if (self.status == .ready and self.frame_count > depth) self.budget_exhausted = true;
    }

    pub fn stepOut(self: *Machine, budget: usize) void {
        if (self.status != .ready) return;
        const depth = self.frame_count;
        var count: usize = 0;
        while (self.status == .ready and self.frame_count >= depth and count < budget) : (count += 1) _ = self.step();
        if (self.status == .ready and self.frame_count >= depth) self.budget_exhausted = true;
    }

    pub fn current(self: *const Machine) ?Instruction {
        if (self.status != .ready or self.current_instruction >= self.instruction_count) return null;
        return self.instructions[self.current_instruction];
    }

    /// Returns the number of values at the top of the operand stack used by
    /// the current instruction. This describes inputs even when an instruction
    /// such as local.tee or end produces the same value again.
    pub fn currentStackInputCount(self: *const Machine) usize {
        const instruction = self.current() orelse return 0;
        return switch (instruction.op) {
            0x04, // if condition
            0x1a, // drop
            0x21,
            0x22, // local.set, local.tee
            0x24, // global.set
            0x28...0x35, // loads
            0x45,
            0x50, // eqz
            0x67...0x69,
            0x79...0x7b, // clz, ctz, popcnt
            0xa7,
            0xac,
            0xad,
            0xc0...0xc4, // conversions
            => 1,
            0x36...0x3e, // stores
            0x46...0x4f,
            0x51...0x5a, // comparisons
            0x6a...0x78,
            0x7c...0x8a, // binary numeric operations
            => 2,
            0x1b => 3, // select: two choices and a condition
            0xfc => switch (instruction.immediate) {
                10, 11 => 3, // memory.copy/fill
                else => 0,
            },
            0xfd => switch (simdSubopcode(instruction)) {
                0, 93 => 1, // v128.load, v128.load64_zero
                11, 13, 110 => 2, // v128.store, i8x16.shuffle, i8x16.add
                else => 0,
            },
            0x0b => if (self.control_count == 0) 0 else self.controls[self.control_count - 1].result_arity,
            0x0c => self.branchStackInputCount(@intCast(instruction.immediate)),
            0x0d => 1 + if (self.stack_count != 0 and @as(u32, @truncate(self.stack[self.stack_count - 1])) != 0)
                self.branchStackInputCount(@intCast(instruction.immediate))
            else
                0,
            0x0e => if (self.branchTableDepth(instruction)) |depth|
                1 + self.branchStackInputCount(depth)
            else
                1,
            0x0f => if (self.frame_count == 0)
                0
            else blk: {
                const function = self.functions[self.frames[self.frame_count - 1].function_index];
                break :blk self.types[function.type_index].results;
            },
            0x10 => if (instruction.immediate >= self.function_count)
                0
            else blk: {
                const function = self.functions[@intCast(instruction.immediate)];
                break :blk self.types[function.type_index].params;
            },
            0x11 => if (indirectTypeIndex(instruction) >= self.type_count)
                0
            else
                self.types[indirectTypeIndex(instruction)].params + 1,
            else => 0,
        };
    }

    fn branchStackInputCount(self: *const Machine, depth: u32) usize {
        if (self.frame_count == 0) return 0;
        const frame = self.frames[self.frame_count - 1];
        if (depth >= self.control_count - frame.control_base) return 0;
        const target = self.controls[self.control_count - 1 - depth];
        return if (target.kind == .loop) 0 else target.result_arity;
    }

    pub fn stepTargets(self: *const Machine) StepTargets {
        if (self.status != .ready or self.current_instruction >= self.instruction_count) return .{};
        const instruction = self.instructions[self.current_instruction];
        const into = self.singleStepTarget(instruction);
        return .{
            .into = into,
            .over = if (isCallInstruction(instruction.op)) self.sequentialTarget(instruction) else into,
            .out = self.frameReturnTarget(),
        };
    }

    pub fn functionName(self: *const Machine, function_index: u32) ?[]const u8 {
        for (self.exports[0..self.export_count]) |exp| {
            if (exp.kind == 0 and exp.index == function_index) {
                return self.module[exp.name_offset .. exp.name_offset + exp.name_length];
            }
        }
        return null;
    }

    pub fn functionSignature(self: *const Machine, function_index: u32) ?FunctionSignature {
        if (function_index >= self.function_count) return null;
        const function = self.functions[function_index];
        const function_type = &self.types[function.type_index];
        return .{
            .parameters = function_type.parameter_types[0..function_type.params],
            .result = function_type.result_type,
        };
    }

    pub fn functionInstructionRange(self: *const Machine, function_index: u32) ?InstructionRange {
        if (function_index >= self.function_count) return null;
        const function = self.functions[function_index];
        if (function.first_instruction == NO_INSTRUCTION or function.final_instruction == NO_INSTRUCTION) return null;
        return .{ .first = function.first_instruction, .end = function.final_instruction + 1 };
    }

    pub fn indirectCallMayTarget(self: *const Machine, instruction: Instruction, function_index: u32) bool {
        if (instruction.op != 0x11 or function_index >= self.function_count) return false;
        if (!self.sameFunctionType(indirectTypeIndex(instruction), self.functions[function_index].type_index)) return false;
        for (self.table[0..self.table_size]) |table_function| {
            if (table_function == function_index) return true;
        }
        return false;
    }

    pub fn typeSignature(self: *const Machine, type_index: u32) ?FunctionSignature {
        if (type_index >= self.type_count) return null;
        const function_type = &self.types[type_index];
        return .{
            .parameters = function_type.parameter_types[0..function_type.params],
            .result = function_type.result_type,
        };
    }

    pub fn callTarget(self: *const Machine, instruction: Instruction) ?u32 {
        return switch (instruction.op) {
            0x10 => if (instruction.immediate < self.function_count) @intCast(instruction.immediate) else null,
            0x11 => self.indirectTarget(instruction),
            else => null,
        };
    }

    pub fn hasFunctionExport(self: *const Machine, name: []const u8) bool {
        for (self.exports[0..self.export_count]) |exp| {
            if (exp.kind == 0 and std.mem.eql(u8, self.module[exp.name_offset .. exp.name_offset + exp.name_length], name)) {
                return true;
            }
        }
        return false;
    }

    pub fn staticExportedBytes(
        self: *const Machine,
        pointer_export: []const u8,
        size_export: []const u8,
    ) Error!?[]const u8 {
        const pointer = try self.staticI32Getter(pointer_export);
        const size = try self.staticI32Getter(size_export);
        if ((pointer == null) != (size == null)) return Error.InvalidInputContract;
        if (pointer == null) return null;
        const end = @as(u64, pointer.?) + size.?;
        if (end > self.memory_size) return Error.InvalidInputContract;
        return self.memory[pointer.?..@intCast(end)];
    }

    pub fn inputPointer(self: *const Machine) Error!?u32 {
        return self.staticI32Getter("input_ptr");
    }

    pub fn inputCapacity(self: *const Machine) Error!?u32 {
        return self.staticCapacity("input_utf8_cap", "input_bytes_cap");
    }

    pub fn outputCapacity(self: *const Machine) Error!?u32 {
        return self.staticCapacity("output_utf8_cap", "output_bytes_cap");
    }

    pub fn frameParameters(self: *const Machine, frame_index: usize) []const Value {
        if (frame_index >= self.frame_count) return &.{};
        const frame = self.frames[frame_index];
        const function = self.functions[frame.function_index];
        const parameter_count = self.types[function.type_index].params;
        const start: usize = frame.locals_base;
        return self.locals[start .. start + parameter_count];
    }

    pub fn frameDefinedLocals(self: *const Machine, frame_index: usize) []const Value {
        if (frame_index >= self.frame_count) return &.{};
        const frame = self.frames[frame_index];
        const function = self.functions[frame.function_index];
        const parameter_count = self.types[function.type_index].params;
        const start: usize = frame.locals_base + parameter_count;
        const end: usize = frame.locals_base + frame.locals_count;
        return self.locals[start..end];
    }

    fn singleStepTarget(self: *const Machine, instruction: Instruction) u32 {
        const sequential = self.sequentialTarget(instruction);
        return switch (instruction.op) {
            0x00 => NO_INSTRUCTION,
            0x04 => if (self.stack_count == 0)
                NO_INSTRUCTION
            else if (@as(u32, @truncate(self.stack[self.stack_count - 1])) == 0)
                if (instruction.else_instruction == NO_INSTRUCTION) instruction.match else instruction.else_instruction + 1
            else
                sequential,
            0x05 => instruction.match,
            0x0b => if (self.control_count == 0)
                NO_INSTRUCTION
            else if (self.controls[self.control_count - 1].kind == .function)
                self.frameReturnTarget()
            else
                sequential,
            0x0c => self.branchTarget(@intCast(instruction.immediate)),
            0x0d => if (self.stack_count == 0)
                NO_INSTRUCTION
            else if (@as(u32, @truncate(self.stack[self.stack_count - 1])) != 0)
                self.branchTarget(@intCast(instruction.immediate))
            else
                sequential,
            0x0e => if (self.branchTableDepth(instruction)) |depth| self.branchTarget(depth) else NO_INSTRUCTION,
            0x0f => self.functionEndTarget(),
            0x10, 0x11 => if (self.callTarget(instruction)) |function_index|
                self.functions[function_index].first_instruction
            else
                NO_INSTRUCTION,
            else => sequential,
        };
    }

    fn sequentialTarget(self: *const Machine, instruction: Instruction) u32 {
        const target = self.current_instruction + 1;
        if (target >= self.instruction_count or self.instructions[target].function_index != instruction.function_index)
            return NO_INSTRUCTION;
        return target;
    }

    fn frameReturnTarget(self: *const Machine) u32 {
        if (self.frame_count <= 1) return NO_INSTRUCTION;
        const target = self.frames[self.frame_count - 1].return_instruction;
        return if (target < self.instruction_count) target else NO_INSTRUCTION;
    }

    fn functionEndTarget(self: *const Machine) u32 {
        if (self.frame_count == 0) return NO_INSTRUCTION;
        const frame = self.frames[self.frame_count - 1];
        if (frame.control_base >= self.control_count) return NO_INSTRUCTION;
        return self.controls[frame.control_base].end_instruction;
    }

    fn branchTarget(self: *const Machine, depth: u32) u32 {
        if (self.frame_count == 0) return NO_INSTRUCTION;
        const frame = self.frames[self.frame_count - 1];
        if (depth >= self.control_count - frame.control_base) return NO_INSTRUCTION;
        const target = self.controls[self.control_count - 1 - depth];
        return if (target.kind == .loop) target.instruction + 1 else target.end_instruction;
    }

    fn parseModule(self: *Machine) Error!void {
        if (self.module.len < 8 or !std.mem.eql(u8, self.module[0..4], "\x00asm") or
            !std.mem.eql(u8, self.module[4..8], "\x01\x00\x00\x00")) return Error.InvalidWasm;
        var reader = Reader.init(self.module[8..], 8);
        while (reader.remaining() != 0) {
            const id = try reader.byte();
            const payload_length = try reader.varU32();
            const payload_base = reader.base + reader.offset;
            const payload = try reader.bytes(payload_length);
            var section = Reader.init(payload, payload_base);
            switch (id) {
                0 => {},
                1 => try self.parseTypes(&section),
                2 => if (try section.varU32() != 0) return Error.UnsupportedFeature,
                3 => try self.parseFunctions(&section),
                4 => try self.parseTable(&section),
                5 => try self.parseMemory(&section),
                6 => try self.parseGlobals(&section),
                7 => try self.parseExports(&section),
                8 => return Error.UnsupportedFeature,
                9 => try self.parseElements(&section),
                10 => try self.parseCode(&section),
                11 => try self.parseData(&section),
                12 => _ = try section.varU32(),
                else => return Error.UnsupportedFeature,
            }
            if (id != 0 and section.remaining() != 0) return Error.InvalidSection;
        }
        if (self.memory_size == 0) return Error.MissingMemory;
        self.render_function = try self.findRender();
    }

    fn parseTypes(self: *Machine, reader: *Reader) Error!void {
        const count = try reader.varU32();
        if (count > MAX_TYPES) return Error.TooManyItems;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (try reader.byte() != 0x60) return Error.InvalidType;
            const params = try reader.varU32();
            if (params > MAX_FUNCTION_PARAMETERS) return Error.TooManyItems;
            var function_type = FuncType{ .params = @intCast(params), .results = 0 };
            var p: u32 = 0;
            while (p < params) : (p += 1) function_type.parameter_types[p] = try valueType(try reader.byte());
            const results = try reader.varU32();
            if (results > 1) return Error.UnsupportedFeature;
            if (results == 1) function_type.result_type = try valueType(try reader.byte());
            function_type.results = @intCast(results);
            self.types[i] = function_type;
        }
        self.type_count = count;
    }

    fn parseFunctions(self: *Machine, reader: *Reader) Error!void {
        const count = try reader.varU32();
        if (count > MAX_FUNCTIONS) return Error.TooManyItems;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const type_index = try reader.varU32();
            if (type_index >= self.type_count) return Error.InvalidIndex;
            self.functions[i] = .{ .type_index = type_index };
        }
        self.function_count = count;
    }

    fn parseTable(self: *Machine, reader: *Reader) Error!void {
        if (try reader.varU32() != 1) return Error.UnsupportedFeature;
        if (try reader.byte() != 0x70) return Error.UnsupportedFeature;
        const flags = try reader.varU32();
        if (flags != 1) return Error.UnsupportedFeature;
        const minimum = try reader.varU32();
        const maximum = try reader.varU32();
        if (minimum != maximum) return Error.UnsupportedFeature;
        if (minimum > MAX_TABLE_ENTRIES) return Error.TooManyItems;
        self.table_defined = true;
        self.table_size = minimum;
        @memset(self.table[0..self.table_size], NO_FUNCTION);
    }

    fn parseElements(self: *Machine, reader: *Reader) Error!void {
        if (!self.table_defined) return Error.InvalidSection;
        const count = try reader.varU32();
        if (count > MAX_ELEMENT_SEGMENTS) return Error.TooManyItems;
        var segment_index: u32 = 0;
        while (segment_index < count) : (segment_index += 1) {
            const flags = try reader.varU32();
            if (flags == 2 and try reader.varU32() != 0) return Error.InvalidIndex;
            if (flags != 0 and flags != 2) return Error.UnsupportedFeature;
            if (try reader.byte() != 0x41) return Error.UnsupportedFeature;
            const offset: u32 = @bitCast(try reader.s32());
            if (try reader.byte() != 0x0b) return Error.InvalidSection;
            if (flags == 2 and try reader.byte() != 0) return Error.UnsupportedFeature;
            const function_count = try reader.varU32();
            const end = @as(u64, offset) + function_count;
            if (end > self.table_size) return Error.InvalidSection;
            var item: u32 = 0;
            while (item < function_count) : (item += 1) {
                const function_index = try reader.varU32();
                if (function_index >= self.function_count) return Error.InvalidIndex;
                self.table[offset + item] = function_index;
            }
        }
    }

    fn parseMemory(self: *Machine, reader: *Reader) Error!void {
        if (try reader.varU32() != 1) return Error.UnsupportedFeature;
        const flags = try reader.varU32();
        if (flags != 1) return Error.UnsupportedFeature;
        const minimum = try reader.varU32();
        const maximum = try reader.varU32();
        if (minimum > maximum) return Error.InvalidSection;
        const bytes = @as(u64, minimum) * 65536;
        if (bytes == 0 or bytes > MAX_TARGET_MEMORY_BYTES) return Error.MemoryTooLarge;
        self.memory_pages = minimum;
        self.memory_size = @intCast(bytes);
    }

    fn parseGlobals(self: *Machine, reader: *Reader) Error!void {
        const count = try reader.varU32();
        if (count > MAX_GLOBALS) return Error.TooManyItems;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const kind = try valueType(try reader.byte());
            const mutable = switch (try reader.byte()) {
                0 => false,
                1 => true,
                else => return Error.InvalidType,
            };
            const op = try reader.byte();
            const value: Value = switch (op) {
                0x41 => @as(u32, @bitCast(try reader.s32())),
                0x42 => @as(u64, @bitCast(try reader.s64())),
                0x43 => try readFixedU32(reader),
                0x44 => try readFixedU64(reader),
                0xfd => blk: {
                    if (try reader.varU32() != 12) return Error.UnsupportedFeature;
                    break :blk try readFixedU128(reader);
                },
                else => return Error.UnsupportedFeature,
            };
            if (try reader.byte() != 0x0b) return Error.InvalidSection;
            self.globals[i] = .{ .initial = value, .value = value, .value_type = kind, .mutable = mutable };
        }
        self.global_count = count;
    }

    fn parseExports(self: *Machine, reader: *Reader) Error!void {
        const count = try reader.varU32();
        if (count > MAX_EXPORTS) return Error.TooManyItems;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const name = try reader.name();
            self.exports[i] = .{
                .name_offset = name.offset,
                .name_length = name.length,
                .kind = try reader.byte(),
                .index = try reader.varU32(),
            };
        }
        self.export_count = count;
    }

    fn parseCode(self: *Machine, reader: *Reader) Error!void {
        const count = try reader.varU32();
        if (count != self.function_count) return Error.InvalidSection;
        var function_index: u32 = 0;
        while (function_index < count) : (function_index += 1) {
            const body_length = try reader.varU32();
            const body_base = reader.base + reader.offset;
            const body = try reader.bytes(body_length);
            var body_reader = Reader.init(body, body_base);
            const declarations = try body_reader.varU32();
            const function_type = self.types[self.functions[function_index].type_index];
            const params = function_type.params;
            var local_count: u32 = params;
            const local_types_offset = self.function_local_type_count;
            if (local_types_offset + params > MAX_LOCAL_TYPES) return Error.TooManyItems;
            @memcpy(
                self.function_local_types[local_types_offset .. local_types_offset + params],
                function_type.parameter_types[0..params],
            );
            self.function_local_type_count += params;
            var d: u32 = 0;
            while (d < declarations) : (d += 1) {
                const amount = try body_reader.varU32();
                const local_type = try valueType(try body_reader.byte());
                local_count = std.math.add(u32, local_count, amount) catch return Error.TooManyItems;
                if (local_count > MAX_LOCALS) return Error.TooManyItems;
                if (self.function_local_type_count + amount > MAX_LOCAL_TYPES) return Error.TooManyItems;
                @memset(
                    self.function_local_types[self.function_local_type_count .. self.function_local_type_count + amount],
                    local_type,
                );
                self.function_local_type_count += amount;
            }
            self.functions[function_index].local_count = local_count;
            self.functions[function_index].local_types_offset = @intCast(local_types_offset);
            self.functions[function_index].first_instruction = @intCast(self.instruction_count);
            try self.decodeFunction(function_index, &body_reader);
            self.functions[function_index].final_instruction = @intCast(self.instruction_count - 1);
            if (body_reader.remaining() != 0) return Error.InvalidSection;
        }
    }

    fn decodeFunction(self: *Machine, function_index: u32, reader: *Reader) Error!void {
        var openings: [MAX_CONTROLS]u32 = undefined;
        var opening_count: usize = 0;
        while (true) {
            if (self.instruction_count >= MAX_INSTRUCTIONS) return Error.TooManyItems;
            const byte_offset = reader.absoluteOffset();
            const op = try reader.byte();
            const index: u32 = @intCast(self.instruction_count);
            self.instructions[self.instruction_count] = .{
                .op = op,
                .function_index = function_index,
                .byte_offset = byte_offset,
                .depth = @intCast(opening_count),
            };
            self.instruction_count += 1;
            var instruction = &self.instructions[index];
            switch (op) {
                0x00,
                0x01,
                0x0f,
                0x1a,
                0x1b,
                0x45...0x8a,
                0xa7,
                0xac,
                0xad,
                0xc0...0xc4,
                => {},
                0x02, 0x03, 0x04 => {
                    instruction.result_arity = try blockArity(reader);
                    if (opening_count == MAX_CONTROLS) return Error.TooManyItems;
                    openings[opening_count] = index;
                    opening_count += 1;
                },
                0x05 => {
                    if (opening_count == 0) return Error.InvalidSection;
                    const opening = openings[opening_count - 1];
                    if (self.instructions[opening].op != 0x04) return Error.InvalidSection;
                    self.instructions[opening].else_instruction = index;
                },
                0x0b => {
                    if (opening_count == 0) return;
                    opening_count -= 1;
                    const opening = openings[opening_count];
                    self.instructions[opening].match = index;
                    if (self.instructions[opening].else_instruction != NO_INSTRUCTION)
                        self.instructions[self.instructions[opening].else_instruction].match = index;
                },
                0x0c, 0x0d, 0x10, 0x20...0x24 => instruction.immediate = try reader.varU32(),
                0x0e => {
                    const target_count = try reader.varU32();
                    const stored_count = std.math.add(u32, target_count, 1) catch return Error.TooManyItems;
                    if (self.branch_table_target_count + stored_count > MAX_BRANCH_TABLE_TARGETS) return Error.TooManyItems;
                    const offset: u32 = @intCast(self.branch_table_target_count);
                    var target_index: u32 = 0;
                    while (target_index < stored_count) : (target_index += 1) {
                        self.branch_table_targets[self.branch_table_target_count] = try reader.varU32();
                        self.branch_table_target_count += 1;
                    }
                    instruction.immediate = offset | (@as(u64, target_count) << 32);
                },
                0x11 => {
                    const type_index = try reader.varU32();
                    const table_index = try reader.varU32();
                    if (type_index >= self.type_count or table_index != 0 or !self.table_defined) return Error.InvalidIndex;
                    instruction.immediate = type_index | (@as(u64, table_index) << 32);
                },
                0x28...0x3e => {
                    _ = try reader.varU32();
                    instruction.immediate = try reader.varU32();
                },
                0x3f => if (try reader.byte() != 0) return Error.InvalidIndex,
                0x40 => return Error.UnsupportedFeature,
                0x41 => instruction.immediate = @as(u32, @bitCast(try reader.s32())),
                0x42 => instruction.immediate = @bitCast(try reader.s64()),
                0x43 => instruction.immediate = try readFixedU32(reader),
                0x44 => instruction.immediate = try readFixedU64(reader),
                0xfc => {
                    const subopcode = try reader.varU32();
                    instruction.immediate = subopcode;
                    switch (subopcode) {
                        10 => {
                            if (try reader.varU32() != 0) return Error.InvalidIndex;
                            if (try reader.varU32() != 0) return Error.InvalidIndex;
                        },
                        11 => if (try reader.varU32() != 0) return Error.InvalidIndex,
                        else => return Error.UnsupportedFeature,
                    }
                },
                0xfd => {
                    const subopcode = try reader.varU32();
                    instruction.immediate = subopcode;
                    switch (subopcode) {
                        0...11, 92, 93 => {
                            _ = try reader.varU32(); // alignment hint
                            const offset = try reader.varU32();
                            instruction.immediate |= @as(u64, offset) << 32;
                        },
                        12, 13 => {
                            const bytes_offset = reader.absoluteOffset();
                            _ = try reader.bytes(16);
                            instruction.immediate |= @as(u64, bytes_offset) << 32;
                        },
                        21...34 => instruction.immediate2 = try reader.byte(),
                        84...91 => {
                            _ = try reader.varU32(); // alignment hint
                            const offset = try reader.varU32();
                            instruction.immediate |= @as(u64, offset) << 32;
                            instruction.immediate2 = try reader.byte();
                        },
                        14...20, 35...83, 94...255 => {},
                        else => return Error.UnsupportedFeature,
                    }
                },
                else => return Error.UnsupportedFeature,
            }
        }
    }

    fn parseData(self: *Machine, reader: *Reader) Error!void {
        const count = try reader.varU32();
        if (count > MAX_DATA_SEGMENTS) return Error.TooManyItems;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const mode = try reader.varU32();
            if (mode == 2 and try reader.varU32() != 0) return Error.InvalidIndex;
            if (mode != 0 and mode != 2) return Error.UnsupportedFeature;
            if (try reader.byte() != 0x41) return Error.UnsupportedFeature;
            const offset: u32 = @bitCast(try reader.s32());
            if (try reader.byte() != 0x0b) return Error.InvalidSection;
            const length = try reader.varU32();
            const bytes_offset = reader.absoluteOffset();
            _ = try reader.bytes(length);
            if (@as(u64, offset) + length > self.memory_size) return Error.InvalidSection;
            self.data_segments[i] = .{ .offset = offset, .bytes_offset = bytes_offset, .bytes_length = length };
        }
        self.data_segment_count = count;
    }

    fn findRender(self: *Machine) Error!u32 {
        for (self.exports[0..self.export_count]) |exp| {
            if (exp.kind == 0 and std.mem.eql(u8, self.module[exp.name_offset .. exp.name_offset + exp.name_length], "render")) {
                if (exp.index >= self.function_count) return Error.InvalidIndex;
                const ft = self.types[self.functions[exp.index].type_index];
                if (ft.params != 1 or ft.results != 1) return Error.InvalidRenderSignature;
                return exp.index;
            }
        }
        return Error.MissingRender;
    }

    fn resolveInputPointer(self: *Machine, input_size: usize) Error!u32 {
        const pointer = try self.staticI32Getter("input_ptr") orelse return Error.MissingInputBuffer;
        const bytes_capacity = try self.staticI32Getter("input_bytes_cap");
        const utf8_capacity = try self.staticI32Getter("input_utf8_cap");
        if ((bytes_capacity == null) == (utf8_capacity == null)) return Error.InvalidInputContract;
        const capacity = bytes_capacity orelse utf8_capacity.?;
        if (input_size > capacity) return Error.InputTooLarge;
        if (utf8_capacity != null and !std.unicode.utf8ValidateSlice(self.target_input)) return Error.InvalidUTF8;
        const end = @as(u64, pointer) + input_size;
        if (end > self.memory_size) return Error.InputTooLarge;
        return pointer;
    }

    fn staticI32Getter(self: *const Machine, name: []const u8) Error!?u32 {
        var function_index: ?u32 = null;
        for (self.exports[0..self.export_count]) |exp| {
            if (!std.mem.eql(u8, self.module[exp.name_offset .. exp.name_offset + exp.name_length], name)) continue;
            if (function_index != null or exp.kind != 0 or exp.index >= self.function_count) return Error.InvalidInputContract;
            function_index = exp.index;
        }
        const index = function_index orelse return null;
        const function = self.functions[index];
        const function_type = self.types[function.type_index];
        if (function_type.params != 0 or function_type.results != 1 or function_type.result_type != .i32) {
            return Error.InvalidInputContract;
        }
        if (function.final_instruction != function.first_instruction + 1) return Error.InvalidInputContract;
        const value_instruction = self.instructions[function.first_instruction];
        if (self.instructions[function.final_instruction].op != 0x0b) return Error.InvalidInputContract;
        return switch (value_instruction.op) {
            0x41 => @truncate(value_instruction.immediate),
            0x23 => blk: {
                if (value_instruction.immediate >= self.global_count) return Error.InvalidInputContract;
                const global = self.globals[@intCast(value_instruction.immediate)];
                if (global.mutable or global.initial > std.math.maxInt(u32)) return Error.InvalidInputContract;
                break :blk @truncate(global.initial);
            },
            else => Error.InvalidInputContract,
        };
    }

    fn staticCapacity(self: *const Machine, utf8_name: []const u8, bytes_name: []const u8) Error!?u32 {
        const utf8_capacity = try self.staticI32Getter(utf8_name);
        const bytes_capacity = try self.staticI32Getter(bytes_name);
        if (utf8_capacity != null and bytes_capacity != null) return Error.InvalidInputContract;
        return utf8_capacity orelse bytes_capacity;
    }

    fn enterFunction(self: *Machine, function_index: u32, return_instruction: u32, arguments: []const Value) Error!void {
        if (function_index >= self.function_count) return Error.InvalidIndex;
        if (self.frame_count >= MAX_FRAMES) return Error.CallDepthExceeded;
        const function = self.functions[function_index];
        const ft = self.types[function.type_index];
        if (arguments.len != ft.params) return Error.InvalidType;
        if (self.locals_count + function.local_count > MAX_LOCALS) return Error.LocalLimitExceeded;
        const locals_base = self.locals_count;
        @memset(self.locals[locals_base .. locals_base + function.local_count], 0);
        @memcpy(self.locals[locals_base .. locals_base + arguments.len], arguments);
        const type_start: usize = function.local_types_offset;
        @memcpy(
            self.local_types[locals_base .. locals_base + function.local_count],
            self.function_local_types[type_start .. type_start + function.local_count],
        );
        self.locals_count += function.local_count;
        const control_base = self.control_count;
        if (control_base >= MAX_CONTROLS) return Error.ControlDepthExceeded;
        self.frames[self.frame_count] = .{
            .function_index = function_index,
            .locals_base = @intCast(locals_base),
            .locals_count = function.local_count,
            .stack_base = @intCast(self.stack_count),
            .control_base = @intCast(control_base),
            .return_instruction = return_instruction,
        };
        self.frame_count += 1;
        self.controls[self.control_count] = .{
            .kind = .function,
            .instruction = function.first_instruction,
            .end_instruction = function.final_instruction,
            .stack_base = @intCast(self.stack_count),
            .result_arity = ft.results,
        };
        self.control_count += 1;
        self.current_instruction = function.first_instruction;
        self.function_invocations[function_index] += 1;
    }

    fn indirectTarget(self: *const Machine, instruction: Instruction) ?u32 {
        if (instruction.op != 0x11 or indirectTableIndex(instruction) != 0 or self.stack_count == 0) return null;
        const element_index: u32 = @truncate(self.stack[self.stack_count - 1]);
        if (element_index >= self.table_size) return null;
        const function_index = self.table[element_index];
        if (function_index == NO_FUNCTION or function_index >= self.function_count) return null;
        if (!self.sameFunctionType(indirectTypeIndex(instruction), self.functions[function_index].type_index)) return null;
        return function_index;
    }

    fn sameFunctionType(self: *const Machine, left_index: u32, right_index: u32) bool {
        if (left_index >= self.type_count or right_index >= self.type_count) return false;
        const left = self.types[left_index];
        const right = self.types[right_index];
        if (left.params != right.params or left.results != right.results or left.result_type != right.result_type) return false;
        return std.mem.eql(ValType, left.parameter_types[0..left.params], right.parameter_types[0..right.params]);
    }

    fn callFunction(self: *Machine, function_index: u32, return_instruction: u32) Error!void {
        if (function_index >= self.function_count) return Error.InvalidIndex;
        const ft = self.types[self.functions[function_index].type_index];
        if (self.stack_count < ft.params) return Error.StackUnderflow;
        var arguments: [MAX_FUNCTION_PARAMETERS]Value = undefined;
        const start = self.stack_count - ft.params;
        @memcpy(arguments[0..ft.params], self.stack[start..self.stack_count]);
        self.stack_count = start;
        self.counters.calls += 1;
        try self.enterFunction(function_index, return_instruction, arguments[0..ft.params]);
    }

    fn push(self: *Machine, value: Value, value_type: ValType) Error!void {
        if (self.stack_count >= MAX_VALUES) return Error.StackOverflow;
        self.stack[self.stack_count] = value;
        self.stack_types[self.stack_count] = value_type;
        self.stack_count += 1;
    }

    fn pop(self: *Machine) Error!Value {
        if (self.stack_count == 0) return Error.StackUnderflow;
        self.stack_count -= 1;
        return self.stack[self.stack_count];
    }

    fn pop32(self: *Machine) Error!u32 {
        return @truncate(try self.pop());
    }

    fn pop64(self: *Machine) Error!u64 {
        return @truncate(try self.pop());
    }

    fn currentFrame(self: *Machine) *Frame {
        return &self.frames[self.frame_count - 1];
    }

    fn trapWith(self: *Machine, reason: Trap) Error {
        self.trap = reason;
        return Error.UnsupportedFeature;
    }

    fn normalizeStack(self: *Machine, base: usize, arity: u1) Error!void {
        const result_type = if (arity == 1 and self.stack_count > 0) self.stack_types[self.stack_count - 1] else .i32;
        const result = if (arity == 1) try self.pop() else 0;
        if (base > self.stack_count) return Error.StackUnderflow;
        self.stack_count = base;
        if (arity == 1) try self.push(result, result_type);
    }

    fn finishFunction(self: *Machine) Error!void {
        const frame = self.currentFrame().*;
        const ft = self.types[self.functions[frame.function_index].type_index];
        const value = if (ft.results == 1) try self.pop() else 0;
        self.stack_count = frame.stack_base;
        self.locals_count = frame.locals_base;
        self.control_count = frame.control_base;
        self.frame_count -= 1;
        self.counters.returns += 1;
        if (self.frame_count == 0) {
            self.result = @truncate(value);
            self.current_instruction = NO_INSTRUCTION;
            self.status = .halted;
            return;
        }
        if (ft.results == 1) try self.push(value, ft.result_type.?);
        self.current_instruction = frame.return_instruction;
    }

    fn branch(self: *Machine, depth: u32) Error!void {
        const frame = self.currentFrame().*;
        if (depth >= self.control_count - frame.control_base) return self.trapWith(.invalid_control);
        const target_index = self.control_count - 1 - depth;
        const target = self.controls[target_index];
        const arity: u1 = if (target.kind == .loop) 0 else target.result_arity;
        try self.normalizeStack(target.stack_base, arity);
        self.counters.branches += 1;
        if (target.kind == .loop) {
            self.control_count = target_index + 1;
            self.loop_counts[target.instruction] += 1;
            self.counters.loop_iterations += 1;
            self.current_instruction = target.instruction + 1;
        } else {
            self.control_count = target_index + 1;
            self.current_instruction = target.end_instruction;
        }
    }

    fn branchTableDepth(self: *const Machine, instruction: Instruction) ?u32 {
        if (instruction.op != 0x0e or self.stack_count == 0) return null;
        const offset: u32 = @truncate(instruction.immediate);
        const target_count: u32 = @truncate(instruction.immediate >> 32);
        const selector: u32 = @truncate(self.stack[self.stack_count - 1]);
        const selected = if (selector < target_count) selector else target_count;
        const index = @as(u64, offset) + selected;
        if (index >= self.branch_table_target_count) return null;
        return self.branch_table_targets[@intCast(index)];
    }

    fn readMemory(self: *Machine, address: u32, offset: u64, width: u8) Error!u64 {
        const effective = @as(u64, address) + offset;
        if (effective + width > self.memory_size) return self.trapWith(.out_of_bounds_memory);
        self.counters.memory_reads += 1;
        self.last_access = .{ .valid = true, .address = @intCast(effective), .width = width };
        self.last_read_access = self.last_access;
        self.last_access_kind = .read;
        markMemoryPages(&self.memory_pages_read, @intCast(effective), width);
        var value: u64 = 0;
        var i: u8 = 0;
        while (i < width) : (i += 1) value |= @as(u64, self.memory[@as(usize, @intCast(effective)) + i]) << @intCast(i * 8);
        return value;
    }

    fn readMemory128(self: *Machine, address: u32, offset: u32) Error!u128 {
        const effective = @as(u64, address) + offset;
        if (effective + 16 > self.memory_size) return self.trapWith(.out_of_bounds_memory);
        self.counters.memory_reads += 1;
        self.last_access = .{ .valid = true, .address = @intCast(effective), .width = 16 };
        self.last_read_access = self.last_access;
        self.last_access_kind = .read;
        markMemoryPages(&self.memory_pages_read, @intCast(effective), 16);
        const start: usize = @intCast(effective);
        return std.mem.readInt(u128, self.memory[start..][0..16], .little);
    }

    fn writeMemory(self: *Machine, address: u32, offset: u64, width: u8, value: u64) Error!void {
        const effective = @as(u64, address) + offset;
        if (effective + width > self.memory_size) return self.trapWith(.out_of_bounds_memory);
        self.counters.memory_writes += 1;
        self.last_access = .{ .valid = true, .address = @intCast(effective), .width = width };
        self.last_write_access = self.last_access;
        self.last_access_kind = .write;
        var i: u8 = 0;
        while (i < width) : (i += 1) {
            const byte_address = @as(usize, @intCast(effective)) + i;
            self.memory[byte_address] = @truncate(value >> @intCast(i * 8));
        }
        self.markMemoryWritten(@intCast(effective), width);
    }

    fn writeMemory128(self: *Machine, address: u32, offset: u32, value: u128) Error!void {
        const effective = @as(u64, address) + offset;
        if (effective + 16 > self.memory_size) return self.trapWith(.out_of_bounds_memory);
        self.counters.memory_writes += 1;
        self.last_access = .{ .valid = true, .address = @intCast(effective), .width = 16 };
        self.last_write_access = self.last_access;
        self.last_access_kind = .write;
        const start: usize = @intCast(effective);
        std.mem.writeInt(u128, self.memory[start..][0..16], value, .little);
        self.markMemoryWritten(start, 16);
    }

    fn markMemoryPages(pages: *[MEMORY_PAGE_WORDS]u64, start: usize, length: usize) void {
        if (length == 0) return;
        const first = start / WASM_PAGE_BYTES;
        const last = (start + length - 1) / WASM_PAGE_BYTES;
        var page = first;
        while (true) : (page += 1) {
            pages[page / MEMORY_PAGE_WORD_BITS] |= @as(u64, 1) << @intCast(page % MEMORY_PAGE_WORD_BITS);
            if (page == last) break;
        }
    }

    fn markMemoryWritten(self: *Machine, start: usize, length: usize) void {
        if (length == 0) return;
        markMemoryPages(&self.memory_pages_written, start, length);
        const end = start + length;
        var address = start;
        while (address < end and address % 8 != 0) : (address += 1)
            self.memory_written[address / 8] |= @as(u8, 1) << @intCast(address % 8);
        const full_byte_end = end - end % 8;
        if (address < full_byte_end) {
            @memset(self.memory_written[address / 8 .. full_byte_end / 8], 0xff);
            address = full_byte_end;
        }
        while (address < end) : (address += 1)
            self.memory_written[address / 8] |= @as(u8, 1) << @intCast(address % 8);
    }

    fn executeMemoryCopy(self: *Machine) Error!void {
        const length = try self.pop32();
        const source = try self.pop32();
        const destination = try self.pop32();
        const source_end = @as(u64, source) + length;
        const destination_end = @as(u64, destination) + length;
        if (source_end > self.memory_size or destination_end > self.memory_size)
            return self.trapWith(.out_of_bounds_memory);
        if (length == 0) return;

        const source_start: usize = source;
        const destination_start: usize = destination;
        const byte_count: usize = length;
        if (destination_start <= source_start) {
            std.mem.copyForwards(
                u8,
                self.memory[destination_start .. destination_start + byte_count],
                self.memory[source_start .. source_start + byte_count],
            );
        } else {
            std.mem.copyBackwards(
                u8,
                self.memory[destination_start .. destination_start + byte_count],
                self.memory[source_start .. source_start + byte_count],
            );
        }
        self.counters.memory_reads += 1;
        self.counters.memory_writes += 1;
        self.last_read_access = .{ .valid = true, .address = source, .width = length };
        self.last_write_access = .{ .valid = true, .address = destination, .width = length };
        self.last_access = self.last_write_access;
        self.last_access_kind = .write;
        markMemoryPages(&self.memory_pages_read, source_start, byte_count);
        self.markMemoryWritten(destination_start, byte_count);
    }

    fn executeMemoryFill(self: *Machine) Error!void {
        const length = try self.pop32();
        const value = try self.pop32();
        const destination = try self.pop32();
        const destination_end = @as(u64, destination) + length;
        if (destination_end > self.memory_size) return self.trapWith(.out_of_bounds_memory);
        if (length == 0) return;

        const destination_start: usize = destination;
        const byte_count: usize = length;
        @memset(self.memory[destination_start .. destination_start + byte_count], @as(u8, @truncate(value)));
        self.counters.memory_writes += 1;
        self.last_write_access = .{ .valid = true, .address = destination, .width = length };
        self.last_access = self.last_write_access;
        self.last_access_kind = .write;
        self.markMemoryWritten(destination_start, byte_count);
    }

    fn binary32(self: *Machine, comptime operation: anytype) Error!void {
        const right = try self.pop32();
        const left = try self.pop32();
        try self.push(operation(left, right), .i32);
    }

    fn binary64(self: *Machine, result_type: ValType, comptime operation: anytype) Error!void {
        const right = try self.pop64();
        const left = try self.pop64();
        try self.push(operation(left, right), result_type);
    }

    fn stepImpl(self: *Machine) Error!void {
        if (self.current_instruction >= self.instruction_count) return Error.InvalidIndex;
        const instruction = self.instructions[self.current_instruction];
        self.last_executed_instruction = self.current_instruction;
        self.counters.instructions += 1;
        var next = self.current_instruction + 1;
        switch (instruction.op) {
            0x00 => return self.trapWith(.explicit_unreachable),
            0x01 => {},
            0x02, 0x03, 0x04 => {
                if (self.control_count >= MAX_CONTROLS) return Error.ControlDepthExceeded;
                const kind: ControlKind = switch (instruction.op) {
                    0x02 => .block,
                    0x03 => .loop,
                    else => .if_,
                };
                if (instruction.match == NO_INSTRUCTION) return Error.InvalidSection;
                if (instruction.op == 0x04) {
                    const condition = try self.pop32();
                    if (condition == 0) next = if (instruction.else_instruction == NO_INSTRUCTION) instruction.match else instruction.else_instruction + 1;
                }
                self.controls[self.control_count] = .{
                    .kind = kind,
                    .instruction = self.current_instruction,
                    .end_instruction = instruction.match,
                    .stack_base = @intCast(self.stack_count),
                    .result_arity = instruction.result_arity,
                };
                self.control_count += 1;
            },
            0x05 => next = instruction.match,
            0x0b => {
                if (self.control_count == 0) return self.trapWith(.invalid_control);
                const control = self.controls[self.control_count - 1];
                try self.normalizeStack(control.stack_base, control.result_arity);
                self.control_count -= 1;
                if (control.kind == .function) return self.finishFunction();
            },
            0x0c => {
                try self.branch(@intCast(instruction.immediate));
                return;
            },
            0x0d => {
                if (try self.pop32() != 0) {
                    try self.branch(@intCast(instruction.immediate));
                    return;
                }
            },
            0x0e => {
                const depth = self.branchTableDepth(instruction) orelse return Error.InvalidIndex;
                _ = try self.pop32();
                try self.branch(depth);
                return;
            },
            0x0f => {
                try self.branch(@intCast(self.control_count - 1 - self.currentFrame().control_base));
                return;
            },
            0x10 => {
                const function_index: u32 = @intCast(instruction.immediate);
                try self.callFunction(function_index, next);
                return;
            },
            0x11 => {
                const expected_type = indirectTypeIndex(instruction);
                const element_index = try self.pop32();
                if (element_index >= self.table_size) return self.trapWith(.out_of_bounds_table);
                const function_index = self.table[element_index];
                if (function_index == NO_FUNCTION) return self.trapWith(.uninitialized_element);
                if (function_index >= self.function_count) return Error.InvalidIndex;
                if (!self.sameFunctionType(expected_type, self.functions[function_index].type_index))
                    return self.trapWith(.indirect_call_type_mismatch);
                self.counters.indirect_calls += 1;
                try self.callFunction(function_index, next);
                return;
            },
            0x1a => _ = try self.pop(),
            0x1b => {
                const condition = try self.pop32();
                if (self.stack_count == 0) return Error.StackUnderflow;
                const result_type = self.stack_types[self.stack_count - 1];
                const right = try self.pop();
                const left = try self.pop();
                try self.push(if (condition != 0) left else right, result_type);
            },
            0x20 => {
                const local = self.currentFrame().locals_base + @as(u32, @intCast(instruction.immediate));
                if (local >= self.locals_count) return Error.InvalidIndex;
                try self.push(self.locals[local], self.local_types[local]);
            },
            0x21 => {
                const local = self.currentFrame().locals_base + @as(u32, @intCast(instruction.immediate));
                if (local >= self.locals_count) return Error.InvalidIndex;
                self.locals[local] = try self.pop();
            },
            0x22 => {
                const local = self.currentFrame().locals_base + @as(u32, @intCast(instruction.immediate));
                if (local >= self.locals_count or self.stack_count == 0) return Error.InvalidIndex;
                self.locals[local] = self.stack[self.stack_count - 1];
            },
            0x23 => {
                if (instruction.immediate >= self.global_count) return Error.InvalidIndex;
                const global = self.globals[@intCast(instruction.immediate)];
                try self.push(global.value, global.value_type);
            },
            0x24 => {
                if (instruction.immediate >= self.global_count or !self.globals[@intCast(instruction.immediate)].mutable) return Error.InvalidIndex;
                self.globals[@intCast(instruction.immediate)].value = try self.pop();
            },
            0x28...0x35 => try self.executeLoad(instruction),
            0x36...0x3e => try self.executeStore(instruction),
            0x3f => try self.push(self.memory_pages, .i32),
            0x41 => try self.push(instruction.immediate, .i32),
            0x42 => try self.push(instruction.immediate, .i64),
            0x43 => try self.push(instruction.immediate, .f32),
            0x44 => try self.push(instruction.immediate, .f64),
            0x45 => try self.push(@intFromBool((try self.pop32()) == 0), .i32),
            0x46 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(a == b);
                }
            }.f),
            0x47 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(a != b);
                }
            }.f),
            0x48 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(@as(i32, @bitCast(a)) < @as(i32, @bitCast(b)));
                }
            }.f),
            0x49 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(a < b);
                }
            }.f),
            0x4a => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(@as(i32, @bitCast(a)) > @as(i32, @bitCast(b)));
                }
            }.f),
            0x4b => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(a > b);
                }
            }.f),
            0x4c => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(@as(i32, @bitCast(a)) <= @as(i32, @bitCast(b)));
                }
            }.f),
            0x4d => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(a <= b);
                }
            }.f),
            0x4e => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(@as(i32, @bitCast(a)) >= @as(i32, @bitCast(b)));
                }
            }.f),
            0x4f => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @intFromBool(a >= b);
                }
            }.f),
            0x50 => try self.push(@intFromBool((try self.pop64()) == 0), .i32),
            0x51 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(a == b);
                }
            }.f),
            0x52 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(a != b);
                }
            }.f),
            0x53 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(@as(i64, @bitCast(a)) < @as(i64, @bitCast(b)));
                }
            }.f),
            0x54 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(a < b);
                }
            }.f),
            0x55 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(@as(i64, @bitCast(a)) > @as(i64, @bitCast(b)));
                }
            }.f),
            0x56 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(a > b);
                }
            }.f),
            0x57 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(@as(i64, @bitCast(a)) <= @as(i64, @bitCast(b)));
                }
            }.f),
            0x58 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(a <= b);
                }
            }.f),
            0x59 => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(@as(i64, @bitCast(a)) >= @as(i64, @bitCast(b)));
                }
            }.f),
            0x5a => try self.binary64(.i32, struct {
                fn f(a: u64, b: u64) u64 {
                    return @intFromBool(a >= b);
                }
            }.f),
            0x67 => try self.push(@clz(try self.pop32()), .i32),
            0x68 => try self.push(@ctz(try self.pop32()), .i32),
            0x69 => try self.push(@popCount(try self.pop32()), .i32),
            0x6a => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a +% b;
                }
            }.f),
            0x6b => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a -% b;
                }
            }.f),
            0x6c => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a *% b;
                }
            }.f),
            0x6d...0x70 => try self.executeDivision32(instruction.op),
            0x71 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a & b;
                }
            }.f),
            0x72 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a | b;
                }
            }.f),
            0x73 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a ^ b;
                }
            }.f),
            0x74 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a << @intCast(b & 31);
                }
            }.f),
            0x75 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return @bitCast(@as(i32, @bitCast(a)) >> @intCast(b & 31));
                }
            }.f),
            0x76 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return a >> @intCast(b & 31);
                }
            }.f),
            0x77 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return std.math.rotl(u32, a, b);
                }
            }.f),
            0x78 => try self.binary32(struct {
                fn f(a: u32, b: u32) u32 {
                    return std.math.rotr(u32, a, b);
                }
            }.f),
            0x79 => try self.push(@clz(try self.pop64()), .i64),
            0x7a => try self.push(@ctz(try self.pop64()), .i64),
            0x7b => try self.push(@popCount(try self.pop64()), .i64),
            0x7c => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a +% b;
                }
            }.f),
            0x7d => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a -% b;
                }
            }.f),
            0x7e => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a *% b;
                }
            }.f),
            0x7f...0x82 => try self.executeDivision64(instruction.op),
            0x83 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a & b;
                }
            }.f),
            0x84 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a | b;
                }
            }.f),
            0x85 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a ^ b;
                }
            }.f),
            0x86 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a << @intCast(b & 63);
                }
            }.f),
            0x87 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return @bitCast(@as(i64, @bitCast(a)) >> @intCast(b & 63));
                }
            }.f),
            0x88 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a >> @intCast(b & 63);
                }
            }.f),
            0x89 => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return std.math.rotl(u64, a, b);
                }
            }.f),
            0x8a => try self.binary64(.i64, struct {
                fn f(a: u64, b: u64) u64 {
                    return std.math.rotr(u64, a, b);
                }
            }.f),
            0xa7 => try self.push(@as(u32, @truncate(try self.pop())), .i32),
            0xac => try self.push(@as(u64, @bitCast(@as(i64, @as(i32, @bitCast(try self.pop32()))))), .i64),
            0xad => try self.push(try self.pop32(), .i64),
            0xc0 => try self.push(signExtend8To32(try self.pop32()), .i32),
            0xc1 => try self.push(signExtend16To32(try self.pop32()), .i32),
            0xc2 => try self.push(signExtend8To64(try self.pop64()), .i64),
            0xc3 => try self.push(signExtend16To64(try self.pop64()), .i64),
            0xc4 => try self.push(signExtend32To64(try self.pop64()), .i64),
            0xfc => switch (instruction.immediate) {
                10 => try self.executeMemoryCopy(),
                11 => try self.executeMemoryFill(),
                else => return self.trapWith(.unsupported_instruction),
            },
            0xfd => try self.executeSIMD(instruction),
            else => return self.trapWith(.unsupported_instruction),
        }
        self.current_instruction = next;
    }

    fn executeLoad(self: *Machine, instruction: Instruction) Error!void {
        const address = try self.pop32();
        const raw = switch (instruction.op) {
            0x28, 0x2a => try self.readMemory(address, instruction.immediate, 4),
            0x29, 0x2b => try self.readMemory(address, instruction.immediate, 8),
            0x2c, 0x2d, 0x30, 0x31 => try self.readMemory(address, instruction.immediate, 1),
            0x2e, 0x2f, 0x32, 0x33 => try self.readMemory(address, instruction.immediate, 2),
            0x34, 0x35 => try self.readMemory(address, instruction.immediate, 4),
            else => unreachable,
        };
        const value: u64 = switch (instruction.op) {
            0x2c => signExtend8To32(@truncate(raw)),
            0x2e => signExtend16To32(@truncate(raw)),
            0x30 => signExtend8To64(raw),
            0x32 => signExtend16To64(raw),
            0x34 => signExtend32To64(raw),
            else => raw,
        };
        const result_type: ValType = switch (instruction.op) {
            0x28, 0x2c...0x2f => .i32,
            0x29, 0x30...0x35 => .i64,
            0x2a => .f32,
            0x2b => .f64,
            else => unreachable,
        };
        try self.push(value, result_type);
    }

    fn executeStore(self: *Machine, instruction: Instruction) Error!void {
        const value: u64 = @truncate(try self.pop());
        const address = try self.pop32();
        const width: u8 = switch (instruction.op) {
            0x36, 0x38 => 4,
            0x37, 0x39 => 8,
            0x3a, 0x3c => 1,
            0x3b, 0x3d => 2,
            0x3e => 4,
            else => unreachable,
        };
        try self.writeMemory(address, instruction.immediate, width, value);
    }

    fn executeSIMD(self: *Machine, instruction: Instruction) Error!void {
        const subopcode = simdSubopcode(instruction);
        switch (subopcode) {
            0 => { // v128.load
                const address = try self.pop32();
                try self.push(try self.readMemory128(address, simdImmediate(instruction)), .v128);
            },
            11 => { // v128.store
                const value = try self.pop();
                const address = try self.pop32();
                try self.writeMemory128(address, simdImmediate(instruction), value);
            },
            12 => { // v128.const
                const offset: usize = simdImmediate(instruction);
                if (offset + 16 > self.module.len) return Error.InvalidSection;
                try self.push(std.mem.readInt(u128, self.module[offset..][0..16], .little), .v128);
            },
            13 => { // i8x16.shuffle
                const right = try self.pop();
                const left = try self.pop();
                const offset: usize = simdImmediate(instruction);
                if (offset + 16 > self.module.len) return Error.InvalidSection;
                try self.push(try i8x16Shuffle(left, right, self.module[offset..][0..16]), .v128);
            },
            93 => { // v128.load64_zero
                const address = try self.pop32();
                try self.push(try self.readMemory(address, simdImmediate(instruction), 8), .v128);
            },
            110 => { // i8x16.add
                const right = try self.pop();
                const left = try self.pop();
                try self.push(i8x16Add(left, right), .v128);
            },
            else => return self.trapWith(.unsupported_instruction),
        }
    }

    fn executeDivision32(self: *Machine, op: u8) Error!void {
        const right = try self.pop32();
        const left = try self.pop32();
        if (right == 0) return self.trapWith(.divide_by_zero);
        const value: u32 = switch (op) {
            0x6d => blk: {
                const a: i32 = @bitCast(left);
                const b: i32 = @bitCast(right);
                if (a == std.math.minInt(i32) and b == -1) return self.trapWith(.integer_overflow);
                break :blk @bitCast(@divTrunc(a, b));
            },
            0x6e => left / right,
            0x6f => blk: {
                const a: i32 = @bitCast(left);
                const b: i32 = @bitCast(right);
                break :blk if (a == std.math.minInt(i32) and b == -1) 0 else @bitCast(@rem(a, b));
            },
            0x70 => left % right,
            else => unreachable,
        };
        try self.push(value, .i32);
    }

    fn executeDivision64(self: *Machine, op: u8) Error!void {
        const right = try self.pop64();
        const left = try self.pop64();
        if (right == 0) return self.trapWith(.divide_by_zero);
        const value: u64 = switch (op) {
            0x7f => blk: {
                const a: i64 = @bitCast(left);
                const b: i64 = @bitCast(right);
                if (a == std.math.minInt(i64) and b == -1) return self.trapWith(.integer_overflow);
                break :blk @bitCast(@divTrunc(a, b));
            },
            0x80 => left / right,
            0x81 => blk: {
                const a: i64 = @bitCast(left);
                const b: i64 = @bitCast(right);
                break :blk if (a == std.math.minInt(i64) and b == -1) 0 else @bitCast(@rem(a, b));
            },
            0x82 => left % right,
            else => unreachable,
        };
        try self.push(value, .i64);
    }
};

pub fn i8x16Shuffle(left: u128, right: u128, lanes: []const u8) Error!u128 {
    if (lanes.len != 16) return Error.InvalidSection;
    var result: u128 = 0;
    for (lanes, 0..) |lane, destination| {
        if (lane >= 32) return Error.InvalidSection;
        const source = if (lane < 16) left else right;
        const source_lane: u7 = @intCast(lane & 15);
        const byte: u8 = @truncate(source >> @intCast(source_lane * 8));
        result |= @as(u128, byte) << @intCast(destination * 8);
    }
    return result;
}

pub fn i8x16Add(left: u128, right: u128) u128 {
    var result: u128 = 0;
    for (0..16) |lane| {
        const shift: u7 = @intCast(lane * 8);
        const left_byte: u8 = @truncate(left >> shift);
        const right_byte: u8 = @truncate(right >> shift);
        result |= @as(u128, left_byte +% right_byte) << shift;
    }
    return result;
}

fn signExtend8To32(value: u32) u32 {
    const narrowed: i8 = @bitCast(@as(u8, @truncate(value)));
    return @bitCast(@as(i32, narrowed));
}

fn signExtend16To32(value: u32) u32 {
    const narrowed: i16 = @bitCast(@as(u16, @truncate(value)));
    return @bitCast(@as(i32, narrowed));
}

fn signExtend8To64(value: u64) u64 {
    const narrowed: i8 = @bitCast(@as(u8, @truncate(value)));
    return @bitCast(@as(i64, narrowed));
}

fn signExtend16To64(value: u64) u64 {
    const narrowed: i16 = @bitCast(@as(u16, @truncate(value)));
    return @bitCast(@as(i64, narrowed));
}

fn signExtend32To64(value: u64) u64 {
    const narrowed: i32 = @bitCast(@as(u32, @truncate(value)));
    return @bitCast(@as(i64, narrowed));
}

fn valueType(byte: u8) Error!ValType {
    return switch (byte) {
        0x7f => .i32,
        0x7e => .i64,
        0x7d => .f32,
        0x7c => .f64,
        0x7b => .v128,
        else => Error.UnsupportedFeature,
    };
}

pub fn simdSubopcode(instruction: Instruction) u32 {
    return @truncate(instruction.immediate);
}

pub fn simdImmediate(instruction: Instruction) u32 {
    return @truncate(instruction.immediate >> 32);
}

pub fn indirectTypeIndex(instruction: Instruction) u32 {
    return @truncate(instruction.immediate);
}

pub fn indirectTableIndex(instruction: Instruction) u32 {
    return @truncate(instruction.immediate >> 32);
}

fn isCallInstruction(op: u8) bool {
    return op == 0x10 or op == 0x11;
}

fn blockArity(reader: *Reader) Error!u1 {
    return switch (try reader.byte()) {
        0x40 => 0,
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b => 1,
        else => Error.UnsupportedFeature,
    };
}

fn readFixedU32(reader: *Reader) Error!u32 {
    const bytes = try reader.bytes(4);
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readFixedU64(reader: *Reader) Error!u64 {
    const bytes = try reader.bytes(8);
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn readFixedU128(reader: *Reader) Error!u128 {
    const bytes = try reader.bytes(16);
    return std.mem.readInt(u128, bytes[0..16], .little);
}

pub fn opcodeName(op: u8) []const u8 {
    return switch (op) {
        0x00 => "unreachable",
        0x01 => "nop",
        0x02 => "block",
        0x03 => "loop",
        0x04 => "if",
        0x05 => "else",
        0x0b => "end",
        0x0c => "br",
        0x0d => "br_if",
        0x0e => "br_table",
        0x0f => "return",
        0x10 => "call",
        0x11 => "call_indirect",
        0x1a => "drop",
        0x1b => "select",
        0x20 => "local.get",
        0x21 => "local.set",
        0x22 => "local.tee",
        0x23 => "global.get",
        0x24 => "global.set",
        0x28 => "i32.load",
        0x29 => "i64.load",
        0x2a => "f32.load",
        0x2b => "f64.load",
        0x2c => "i32.load8_s",
        0x2d => "i32.load8_u",
        0x2e => "i32.load16_s",
        0x2f => "i32.load16_u",
        0x30 => "i64.load8_s",
        0x31 => "i64.load8_u",
        0x32 => "i64.load16_s",
        0x33 => "i64.load16_u",
        0x34 => "i64.load32_s",
        0x35 => "i64.load32_u",
        0x36 => "i32.store",
        0x37 => "i64.store",
        0x38 => "f32.store",
        0x39 => "f64.store",
        0x3a => "i32.store8",
        0x3b => "i32.store16",
        0x3c => "i64.store8",
        0x3d => "i64.store16",
        0x3e => "i64.store32",
        0x3f => "memory.size",
        0x41 => "i32.const",
        0x42 => "i64.const",
        0x43 => "f32.const",
        0x44 => "f64.const",
        0x45 => "i32.eqz",
        0x46 => "i32.eq",
        0x47 => "i32.ne",
        0x48 => "i32.lt_s",
        0x49 => "i32.lt_u",
        0x4a => "i32.gt_s",
        0x4b => "i32.gt_u",
        0x4c => "i32.le_s",
        0x4d => "i32.le_u",
        0x4e => "i32.ge_s",
        0x4f => "i32.ge_u",
        0x50 => "i64.eqz",
        0x51 => "i64.eq",
        0x52 => "i64.ne",
        0x53 => "i64.lt_s",
        0x54 => "i64.lt_u",
        0x55 => "i64.gt_s",
        0x56 => "i64.gt_u",
        0x57 => "i64.le_s",
        0x58 => "i64.le_u",
        0x59 => "i64.ge_s",
        0x5a => "i64.ge_u",
        0x67 => "i32.clz",
        0x68 => "i32.ctz",
        0x69 => "i32.popcnt",
        0x6a => "i32.add",
        0x6b => "i32.sub",
        0x6c => "i32.mul",
        0x6d => "i32.div_s",
        0x6e => "i32.div_u",
        0x6f => "i32.rem_s",
        0x70 => "i32.rem_u",
        0x71 => "i32.and",
        0x72 => "i32.or",
        0x73 => "i32.xor",
        0x74 => "i32.shl",
        0x75 => "i32.shr_s",
        0x76 => "i32.shr_u",
        0x77 => "i32.rotl",
        0x78 => "i32.rotr",
        0x79 => "i64.clz",
        0x7a => "i64.ctz",
        0x7b => "i64.popcnt",
        0x7c => "i64.add",
        0x7d => "i64.sub",
        0x7e => "i64.mul",
        0x7f => "i64.div_s",
        0x80 => "i64.div_u",
        0x81 => "i64.rem_s",
        0x82 => "i64.rem_u",
        0x83 => "i64.and",
        0x84 => "i64.or",
        0x85 => "i64.xor",
        0x86 => "i64.shl",
        0x87 => "i64.shr_s",
        0x88 => "i64.shr_u",
        0x89 => "i64.rotl",
        0x8a => "i64.rotr",
        0xa7 => "i32.wrap_i64",
        0xac => "i64.extend_i32_s",
        0xad => "i64.extend_i32_u",
        0xc0 => "i32.extend8_s",
        0xc1 => "i32.extend16_s",
        0xc2 => "i64.extend8_s",
        0xc3 => "i64.extend16_s",
        0xc4 => "i64.extend32_s",
        else => "unsupported",
    };
}

pub fn instructionName(instruction: Instruction) []const u8 {
    if (instruction.op == 0xfc) return switch (instruction.immediate) {
        10 => "memory.copy",
        11 => "memory.fill",
        else => "unsupported",
    };
    if (instruction.op == 0xfd) return switch (simdSubopcode(instruction)) {
        0 => "v128.load",
        11 => "v128.store",
        12 => "v128.const",
        13 => "i8x16.shuffle",
        93 => "v128.load64_zero",
        110 => "i8x16.add",
        else => "simd.unsupported",
    };
    return opcodeName(instruction.op);
}

pub fn trapName(trap: Trap) []const u8 {
    return switch (trap) {
        .none => "none",
        .explicit_unreachable => "unreachable",
        .out_of_bounds_memory => "out-of-bounds memory",
        .out_of_bounds_table => "out-of-bounds table access",
        .uninitialized_element => "uninitialized table element",
        .indirect_call_type_mismatch => "indirect call type mismatch",
        .divide_by_zero => "integer divide by zero",
        .integer_overflow => "integer overflow",
        .invalid_control => "invalid control flow",
        .unsupported_instruction => "unsupported instruction",
    };
}

test "operand stack retains every numeric value type" {
    const machine = try std.testing.allocator.create(Machine);
    defer std.testing.allocator.destroy(machine);
    machine.* = undefined;
    machine.stack_count = 0;

    try machine.push(1, .i32);
    try machine.push(2, .i64);
    try machine.push(3, .f32);
    try machine.push(4, .f64);
    try machine.push(5, .v128);

    try std.testing.expectEqualSlices(
        ValType,
        &.{ .i32, .i64, .f32, .f64, .v128 },
        machine.stack_types[0..machine.stack_count],
    );
}

test "i8x16 shuffle selects bytes from both vectors" {
    const left = std.mem.readInt(u128, &[_]u8{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    }, .little);
    const right = std.mem.readInt(u128, &[_]u8{
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    }, .little);
    const result = try i8x16Shuffle(left, right, &[_]u8{
        31, 0, 16, 15, 30, 1, 17, 14, 29, 2, 18, 13, 28, 3, 19, 12,
    });
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, result, .little);
    try std.testing.expectEqualSlices(u8, &.{
        31, 0, 16, 15, 30, 1, 17, 14, 29, 2, 18, 13, 28, 3, 19, 12,
    }, &bytes);
}

test "i8x16 add wraps each byte independently" {
    const left = std.mem.readInt(u128, &[_]u8{
        255, 1, 128, 64, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120,
    }, .little);
    const right = std.mem.readInt(u128, &[_]u8{
        2, 3, 128, 192, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
    }, .little);
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, i8x16Add(left, right), .little);
    try std.testing.expectEqualSlices(u8, &.{
        1, 4, 0, 0, 11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132,
    }, &bytes);
}

test "memory restart clears written pages and resets page activity" {
    const machine = try std.testing.allocator.create(Machine);
    defer std.testing.allocator.destroy(machine);
    machine.* = undefined;
    machine.memory_size = 2 * WASM_PAGE_BYTES;
    machine.memory_pages = 2;
    machine.memory_initialized = false;
    machine.data_segment_count = 0;
    machine.target_input = &.{};
    machine.target_input_ptr = 0;
    machine.memory[7] = 0xaa;
    machine.memory[WASM_PAGE_BYTES + 7] = 0xbb;

    machine.resetMemory();
    try std.testing.expectEqual(@as(u8, 0), machine.memory[7]);
    try std.testing.expectEqual(@as(u8, 0), machine.memory[WASM_PAGE_BYTES + 7]);

    machine.memory[7] = 0xcc;
    machine.markMemoryWritten(7, 1);
    machine.memory[WASM_PAGE_BYTES + 7] = 0xdd;
    Machine.markMemoryPages(&machine.memory_pages_read, WASM_PAGE_BYTES + 7, 1);
    try std.testing.expectEqual(MemoryPageActivity.written, machine.memoryPageActivity(0));
    try std.testing.expectEqual(MemoryPageActivity.read, machine.memoryPageActivity(1));
    try std.testing.expectEqual(MemoryByteProvenance.written, machine.memoryByteProvenance(7));

    machine.resetMemory();
    try std.testing.expectEqual(@as(u8, 0), machine.memory[7]);
    try std.testing.expectEqual(@as(u8, 0xdd), machine.memory[WASM_PAGE_BYTES + 7]);
    try std.testing.expectEqual(MemoryPageActivity.untouched, machine.memoryPageActivity(0));
    try std.testing.expectEqual(MemoryPageActivity.untouched, machine.memoryPageActivity(1));
    try std.testing.expectEqual(MemoryByteProvenance.untouched, machine.memoryByteProvenance(7));
}

test "memory page activity records ranges that cross page boundaries" {
    const machine = try std.testing.allocator.create(Machine);
    defer std.testing.allocator.destroy(machine);
    machine.* = undefined;
    machine.memory_size = 2 * WASM_PAGE_BYTES;
    machine.memory_pages = 2;
    machine.memory_initialized = false;
    machine.data_segment_count = 0;
    machine.target_input = &.{};
    machine.target_input_ptr = 0;
    machine.resetMemory();

    const start = WASM_PAGE_BYTES - 1;
    Machine.markMemoryPages(&machine.memory_pages_read, start, 2);
    machine.markMemoryWritten(start, 2);

    try std.testing.expectEqual(MemoryPageActivity.read_written, machine.memoryPageActivity(0));
    try std.testing.expectEqual(MemoryPageActivity.read_written, machine.memoryPageActivity(1));
    try std.testing.expectEqual(MemoryPageActivity.untouched, machine.memoryPageActivity(2));
}
