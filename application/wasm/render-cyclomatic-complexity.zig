//! render-cyclomatic-complexity: branch complexity reachable from render.
//!
//! Input is a WebAssembly module with a defined exported `render` function.
//! Output is one unsigned decimal integer. The value starts at one, then adds
//! one for each reachable `if` and `br_if`, plus one fewer than the number of
//! distinct destinations in each reachable `br_table`. Direct local calls are
//! followed transitively; each reachable function body contributes once.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 20;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_BRANCH_DEPTH: usize = 8192;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/plain";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var function_body_buf: [MAX_DEFINED_FUNCS][]const u8 = undefined;
var reachable_buf: [MAX_DEFINED_FUNCS]bool = undefined;
var worklist_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var br_table_seen_buf: [MAX_BRANCH_DEPTH]u32 = undefined;

const ComplexityError = wasm_reader.Error || error{
    UnsupportedImportKind,
    TooManyFunctions,
    TooDeepBranchNesting,
    FunctionCodeMismatch,
    MissingRenderExport,
    RenderNotFunction,
    RenderMustBeDefined,
    InvalidFunctionIndex,
    IndirectCallNotSupported,
    InvalidSection,
    OutputOverflow,
};

const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

const Analysis = struct {
    defined_func_count: u32,
    imported_func_count: u32,
    complexity: u64 = 1,
    worklist_len: usize = 0,
    br_table_generation: u32 = 0,

    fn enqueue(self: *Analysis, function_index: u32) ComplexityError!void {
        if (function_index < self.imported_func_count) return;
        const local_index = function_index - self.imported_func_count;
        if (local_index >= self.defined_func_count) return ComplexityError.InvalidFunctionIndex;
        if (reachable_buf[local_index]) return;
        if (self.worklist_len >= MAX_DEFINED_FUNCS) return ComplexityError.TooManyFunctions;

        reachable_buf[local_index] = true;
        worklist_buf[self.worklist_len] = local_index;
        self.worklist_len += 1;
    }

    fn nextBrTableGeneration(self: *Analysis) u32 {
        self.br_table_generation +%= 1;
        // A module below INPUT_CAP cannot contain enough br_table instructions
        // to wrap this counter. Keep zero available as the initial marker.
        if (self.br_table_generation == 0) self.br_table_generation = 1;
        return self.br_table_generation;
    }
};

fn readName(r: *Reader) ComplexityError![]const u8 {
    return r.readN(try r.readVarU32());
}

fn readRefType(r: *Reader) ComplexityError!void {
    const kind = try r.readByte();
    switch (kind) {
        0x70, 0x6f => {},
        0x63, 0x64 => _ = try r.readVarS64(5),
        else => return ComplexityError.InvalidSection,
    }
}

fn skipTableType(r: *Reader) ComplexityError!void {
    try readRefType(r);
    _ = try wasm_reader.readLimits(r);
}

fn parseImportSection(payload: []const u8) ComplexityError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var imported_functions: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try readName(&r);
        _ = try readName(&r);
        switch (try r.readByte()) {
            0 => {
                _ = try r.readVarU32();
                imported_functions +|= 1;
            },
            1 => try skipTableType(&r),
            2 => _ = try wasm_reader.readLimits(&r),
            3 => {
                _ = try r.readByte();
                _ = try r.readByte();
            },
            4 => {
                _ = try r.readByte();
                _ = try r.readVarU32();
            },
            else => return ComplexityError.UnsupportedImportKind,
        }
    }
    if (r.remaining() != 0) return ComplexityError.TrailingBytes;
    return imported_functions;
}

fn parseFunctionSection(payload: []const u8) ComplexityError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_DEFINED_FUNCS) return ComplexityError.TooManyFunctions;
    var i: u32 = 0;
    while (i < count) : (i += 1) _ = try r.readVarU32();
    if (r.remaining() != 0) return ComplexityError.TrailingBytes;
    return count;
}

fn parseExportSection(payload: []const u8) ComplexityError!?u32 {
    var r = Reader.init(payload);
    var render_export: ?u32 = null;
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try readName(&r);
        const kind = try r.readByte();
        const index = try r.readVarU32();
        if (!std.mem.eql(u8, name, "render")) continue;
        if (kind != 0) return ComplexityError.RenderNotFunction;
        if (render_export != null) return ComplexityError.InvalidSection;
        render_export = index;
    }
    if (r.remaining() != 0) return ComplexityError.TrailingBytes;
    return render_export;
}

fn parseCodeSection(payload: []const u8, defined_func_count: u32) ComplexityError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != defined_func_count) return ComplexityError.FunctionCodeMismatch;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body = try r.readN(try r.readVarU32());
        function_body_buf[i] = body;
    }
    if (r.remaining() != 0) return ComplexityError.TrailingBytes;
}

const ValidateHandler = struct {
    pub fn onInstr(self: *ValidateHandler, instr: Instr) ComplexityError!void {
        _ = self;
        _ = instr;
    }

    pub fn onBrTableTarget(self: *ValidateHandler, depth: u32) ComplexityError!void {
        _ = self;
        _ = depth;
    }
};

const ComplexityHandler = struct {
    analysis: *Analysis,
    br_table_remaining: u32 = 0,
    br_table_unique: u32 = 0,
    br_table_generation: u32 = 0,

    pub fn onInstr(self: *ComplexityHandler, instr: Instr) ComplexityError!void {
        switch (instr.op) {
            0x04, 0x0d => self.analysis.complexity +|= 1,
            0x0e => {
                const target_count: u32 = @intCast(instr.imm);
                if (target_count == std.math.maxInt(u32)) return ComplexityError.InvalidSection;
                self.br_table_remaining = target_count + 1;
                self.br_table_unique = 0;
                self.br_table_generation = self.analysis.nextBrTableGeneration();
            },
            0x10, 0x12 => try self.analysis.enqueue(@intCast(instr.imm)),
            0x11, 0x13, 0x14 => return ComplexityError.IndirectCallNotSupported,
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *ComplexityHandler, depth: u32) ComplexityError!void {
        if (self.br_table_remaining == 0) return ComplexityError.InvalidSection;
        if (depth >= MAX_BRANCH_DEPTH) return ComplexityError.TooDeepBranchNesting;

        const index: usize = @intCast(depth);
        if (br_table_seen_buf[index] != self.br_table_generation) {
            br_table_seen_buf[index] = self.br_table_generation;
            self.br_table_unique += 1;
        }
        self.br_table_remaining -= 1;
        if (self.br_table_remaining == 0 and self.br_table_unique > 0) {
            self.analysis.complexity +|= self.br_table_unique - 1;
        }
    }
};

fn analyze(wasm: []const u8) ComplexityError!u64 {
    try wasm_reader.checkHeader(wasm);

    var r = Reader.init(wasm[8..]);
    var imported_func_count: u32 = 0;
    var defined_func_count: u32 = 0;
    var render_index: ?u32 = null;
    var have_function_section = false;
    var have_code_section = false;

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const payload = try r.readN(try r.readVarU32());
        switch (section_id) {
            2 => imported_func_count = try parseImportSection(payload),
            3 => {
                if (have_function_section) return ComplexityError.InvalidSection;
                defined_func_count = try parseFunctionSection(payload);
                have_function_section = true;
            },
            7 => render_index = try parseExportSection(payload),
            10 => {
                if (have_code_section) return ComplexityError.InvalidSection;
                try parseCodeSection(payload, defined_func_count);
                have_code_section = true;
            },
            else => {},
        }
    }

    if (!have_function_section or !have_code_section) return ComplexityError.InvalidSection;
    const render_global_index = render_index orelse return ComplexityError.MissingRenderExport;
    if (render_global_index < imported_func_count) return ComplexityError.RenderMustBeDefined;
    const render_local_index = render_global_index - imported_func_count;
    if (render_local_index >= defined_func_count) return ComplexityError.InvalidFunctionIndex;

    // Decode every body before selecting the render-reachable subset. This
    // prevents malformed unreachable code from producing a partial metric.
    var validate_handler = ValidateHandler{};
    var i: u32 = 0;
    while (i < defined_func_count) : (i += 1) {
        try wasm_reader.walkFunctionBody(&validate_handler, function_body_buf[i]);
        reachable_buf[i] = false;
    }

    var analysis = Analysis{
        .defined_func_count = defined_func_count,
        .imported_func_count = imported_func_count,
    };
    try analysis.enqueue(render_global_index);

    var next: usize = 0;
    while (next < analysis.worklist_len) : (next += 1) {
        const function_index = worklist_buf[next];
        var handler = ComplexityHandler{ .analysis = &analysis };
        try wasm_reader.walkFunctionBody(&handler, function_body_buf[function_index]);
        if (handler.br_table_remaining != 0) return ComplexityError.InvalidSection;
    }

    return analysis.complexity;
}

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

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    const complexity = analyze(input_buf[0..input_size]) catch @trap();
    const output = std.fmt.bufPrint(&output_buf, "{d}", .{complexity}) catch @trap();
    return @intCast(output.len);
}

export fn render(input_size: u32) RenderResult {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
