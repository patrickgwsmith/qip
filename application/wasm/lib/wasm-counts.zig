//! Shared static, factual WebAssembly counts.

const wasm_reader = @import("wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

pub const Error = wasm_reader.Error || error{
    UnsupportedImportKind,
    UnsupportedExportKind,
    UnsupportedType,
    InvalidSection,
    FunctionCodeMismatch,
};

pub const Counts = struct {
    module_bytes: u64 = 0,
    sections: u64 = 0,
    custom_sections: u64 = 0,
    types: u64 = 0,
    v128_types: u64 = 0,
    exports: u64 = 0,
    functions_exported: u64 = 0,
    tables_exported: u64 = 0,
    memories_exported: u64 = 0,
    globals_exported: u64 = 0,
    tags_exported: u64 = 0,
    functions_defined: u64 = 0,
    functions_imported: u64 = 0,
    tables_defined: u64 = 0,
    tables_imported: u64 = 0,
    tables_funcref: u64 = 0,
    tables_externref: u64 = 0,
    tables_typed_reference: u64 = 0,
    tables_table64: u64 = 0,
    tables_with_maximum: u64 = 0,
    tables_fixed_size: u64 = 0,
    table_initial_slots: u64 = 0,
    table_maximum_slots: u64 = 0,
    element_segments: u64 = 0,
    active_element_segments: u64 = 0,
    passive_element_segments: u64 = 0,
    declarative_element_segments: u64 = 0,
    active_element_segments_table_zero: u64 = 0,
    active_element_segments_nonzero_table: u64 = 0,
    active_element_offsets_i32_const_zero: u64 = 0,
    active_element_offsets_i32_const_one: u64 = 0,
    active_element_offsets_i32_const_other: u64 = 0,
    active_element_offsets_global_get: u64 = 0,
    active_element_offsets_other: u64 = 0,
    element_initializers: u64 = 0,
    active_element_initializers: u64 = 0,
    element_function_index_initializers: u64 = 0,
    element_expression_initializers: u64 = 0,
    globals_defined: u64 = 0,
    globals_imported: u64 = 0,
    memories_defined: u64 = 0,
    memories_imported: u64 = 0,
    memories_memory64: u64 = 0,
    memories_shared: u64 = 0,
    memories_with_maximum: u64 = 0,
    memory_initial_pages: u64 = 0,
    memory_maximum_pages: u64 = 0,
    data_segments: u64 = 0,
    active_data_segments: u64 = 0,
    data_bytes: u64 = 0,
    active_data_bytes: u64 = 0,
    instructions: u64 = 0,
    function_instructions: u64 = 0,
    loops: u64 = 0,
    branches: u64 = 0,
    conditional_branches: u64 = 0,
    br_table_targets: u64 = 0,
    calls_direct_local: u64 = 0,
    calls_direct_imported: u64 = 0,
    calls_indirect: u64 = 0,
    call_indirect: u64 = 0,
    return_call_indirect: u64 = 0,
    call_ref: u64 = 0,
    indirect_calls_table_zero: u64 = 0,
    indirect_calls_nonzero_table: u64 = 0,
    table_get: u64 = 0,
    table_set: u64 = 0,
    table_init: u64 = 0,
    elem_drop: u64 = 0,
    table_copy: u64 = 0,
    table_grow: u64 = 0,
    table_size: u64 = 0,
    table_fill: u64 = 0,
    ref_null: u64 = 0,
    ref_is_null: u64 = 0,
    ref_func: u64 = 0,
    simd_instructions: u64 = 0,
    memory_loads: u64 = 0,
    memory_stores: u64 = 0,
    memory_copies: u64 = 0,
    memory_fills: u64 = 0,
    explicit_traps: u64 = 0,
    integer_divisions: u64 = 0,
    integer_remainders: u64 = 0,
    trapping_float_to_int: u64 = 0,
    potentially_trapping_memory: u64 = 0,
    potentially_trapping_table: u64 = 0,
    potentially_trapping_instructions: u64 = 0,
};

fn readName(r: *Reader) Error!void {
    _ = try r.readN(try r.readVarU32());
}

fn countValueType(counts: *Counts, value_type: u8) Error!void {
    switch (value_type) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x70, 0x6f => {},
        0x7b => counts.v128_types += 1,
        else => return Error.UnsupportedType,
    }
}

const RefTypeKind = enum {
    funcref,
    externref,
    typed_reference,
};

fn readRefType(r: *Reader) Error!RefTypeKind {
    const kind = try r.readByte();
    return switch (kind) {
        0x70 => .funcref,
        0x6f => .externref,
        0x63, 0x64 => blk: {
            _ = try r.readVarS64(5);
            break :blk .typed_reference;
        },
        else => return Error.UnsupportedType,
    };
}

fn addMemoryLimits(counts: *Counts, limits: wasm_reader.Limits) void {
    if (limits.memory64) counts.memories_memory64 += 1;
    if (limits.shared) counts.memories_shared += 1;
    counts.memory_initial_pages +|= limits.min;
    if (limits.has_max) {
        counts.memories_with_maximum += 1;
        counts.memory_maximum_pages +|= limits.max;
    }
}

fn addTableLimits(counts: *Counts, limits: wasm_reader.Limits) void {
    if (limits.memory64) counts.tables_table64 += 1;
    counts.table_initial_slots +|= limits.min;
    if (limits.has_max) {
        counts.tables_with_maximum += 1;
        counts.table_maximum_slots +|= limits.max;
        if (limits.min == limits.max) counts.tables_fixed_size += 1;
    }
}

fn parseTypeSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.types += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (try r.readByte() != 0x60) return Error.UnsupportedType;
        const params = try r.readVarU32();
        var p: u32 = 0;
        while (p < params) : (p += 1) try countValueType(counts, try r.readByte());
        const results = try r.readVarU32();
        var q: u32 = 0;
        while (q < results) : (q += 1) try countValueType(counts, try r.readByte());
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn parseTableType(r: *Reader, counts: *Counts) Error!void {
    switch (try readRefType(r)) {
        .funcref => counts.tables_funcref += 1,
        .externref => counts.tables_externref += 1,
        .typed_reference => counts.tables_typed_reference += 1,
    }
    addTableLimits(counts, try wasm_reader.readLimits(r));
}

fn parseImportSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try readName(&r);
        try readName(&r);
        switch (try r.readByte()) {
            0 => {
                _ = try r.readVarU32();
                counts.functions_imported += 1;
            },
            1 => {
                try parseTableType(&r, counts);
                counts.tables_imported += 1;
            },
            2 => {
                const limits = try wasm_reader.readLimits(&r);
                counts.memories_imported += 1;
                addMemoryLimits(counts, limits);
            },
            3 => {
                try countValueType(counts, try r.readByte());
                _ = try r.readByte();
                counts.globals_imported += 1;
            },
            4 => {
                _ = try r.readByte();
                _ = try r.readVarU32();
            },
            else => return Error.UnsupportedImportKind,
        }
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn parseFunctionSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.functions_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) _ = try r.readVarU32();
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn parseTableSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.tables_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) try parseTableType(&r, counts);
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn parseMemorySection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.memories_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) addMemoryLimits(counts, try wasm_reader.readLimits(&r));
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn parseExportSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.exports += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try readName(&r);
        switch (try r.readByte()) {
            0 => counts.functions_exported += 1,
            1 => counts.tables_exported += 1,
            2 => counts.memories_exported += 1,
            3 => counts.globals_exported += 1,
            4 => counts.tags_exported += 1,
            else => return Error.UnsupportedExportKind,
        }
        _ = try r.readVarU32();
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn skipConstExpr(r: *Reader, counts: *Counts) Error!void {
    while (true) {
        const op = try r.readByte();
        counts.instructions += 1;
        switch (op) {
            0x0b => return,
            0x23 => _ = try r.readVarU32(),
            0xd2 => {
                _ = try r.readVarU32();
                counts.ref_func += 1;
            },
            0x41 => _ = try r.readVarS32(),
            0x42 => _ = try r.readVarS64(10),
            0x43 => _ = try r.readN(4),
            0x44 => _ = try r.readN(8),
            0xd0 => {
                _ = try readRefType(r);
                counts.ref_null += 1;
            },
            0xfd => {
                if (try r.readVarU32() != 12) return Error.InvalidSection;
                _ = try r.readN(16);
                counts.simd_instructions += 1;
            },
            0x45...0xc4 => {},
            else => return Error.InvalidSection,
        }
    }
}

fn parseGlobalSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.globals_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try countValueType(counts, try r.readByte());
        _ = try r.readByte();
        try skipConstExpr(&r, counts);
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn readElementInitializers(r: *Reader, counts: *Counts, expressions: bool, active: bool) Error!void {
    const count = try r.readVarU32();
    counts.element_initializers +|= count;
    if (active) counts.active_element_initializers +|= count;
    if (expressions) {
        counts.element_expression_initializers +|= count;
    } else {
        counts.element_function_index_initializers +|= count;
    }
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (expressions) {
            try skipConstExpr(r, counts);
        } else {
            _ = try r.readVarU32();
        }
    }
}

fn countActiveElementTable(counts: *Counts, table_index: u32) void {
    if (table_index == 0) {
        counts.active_element_segments_table_zero += 1;
    } else {
        counts.active_element_segments_nonzero_table += 1;
    }
}

fn classifyActiveElementOffset(counts: *Counts, expression: []const u8) void {
    var r = Reader.init(expression);
    const op = r.readByte() catch {
        counts.active_element_offsets_other += 1;
        return;
    };
    switch (op) {
        0x41 => {
            const value = r.readVarS32() catch {
                counts.active_element_offsets_other += 1;
                return;
            };
            const end = r.readByte() catch {
                counts.active_element_offsets_other += 1;
                return;
            };
            if (end != 0x0b or r.remaining() != 0) {
                counts.active_element_offsets_other += 1;
            } else if (value == 0) {
                counts.active_element_offsets_i32_const_zero += 1;
            } else if (value == 1) {
                counts.active_element_offsets_i32_const_one += 1;
            } else {
                counts.active_element_offsets_i32_const_other += 1;
            }
        },
        0x23 => {
            _ = r.readVarU32() catch {
                counts.active_element_offsets_other += 1;
                return;
            };
            const end = r.readByte() catch {
                counts.active_element_offsets_other += 1;
                return;
            };
            if (end == 0x0b and r.remaining() == 0) {
                counts.active_element_offsets_global_get += 1;
            } else {
                counts.active_element_offsets_other += 1;
            }
        },
        else => counts.active_element_offsets_other += 1,
    }
}

fn readActiveElementOffset(r: *Reader, counts: *Counts) Error!void {
    const start = r.off;
    try skipConstExpr(r, counts);
    classifyActiveElementOffset(counts, r.data[start..r.off]);
}

fn parseElementSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.element_segments += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try r.readVarU32();
        const active = flags == 0 or flags == 2 or flags == 4 or flags == 6;
        if (active) {
            counts.active_element_segments += 1;
        } else if (flags == 1 or flags == 5) {
            counts.passive_element_segments += 1;
        } else if (flags == 3 or flags == 7) {
            counts.declarative_element_segments += 1;
        }
        switch (flags) {
            0 => {
                countActiveElementTable(counts, 0);
                try readActiveElementOffset(&r, counts);
                try readElementInitializers(&r, counts, false, true);
            },
            1, 3 => {
                if (try r.readByte() != 0) return Error.InvalidSection;
                try readElementInitializers(&r, counts, false, false);
            },
            2 => {
                countActiveElementTable(counts, try r.readVarU32());
                try readActiveElementOffset(&r, counts);
                if (try r.readByte() != 0) return Error.InvalidSection;
                try readElementInitializers(&r, counts, false, true);
            },
            4 => {
                countActiveElementTable(counts, 0);
                try readActiveElementOffset(&r, counts);
                try readElementInitializers(&r, counts, true, true);
            },
            5, 7 => {
                _ = try readRefType(&r);
                try readElementInitializers(&r, counts, true, false);
            },
            6 => {
                countActiveElementTable(counts, try r.readVarU32());
                try readActiveElementOffset(&r, counts);
                _ = try readRefType(&r);
                try readElementInitializers(&r, counts, true, true);
            },
            else => return Error.InvalidSection,
        }
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

fn parseDataSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.data_segments += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try r.readVarU32();
        const active = switch (flags) {
            0 => blk: {
                try skipConstExpr(&r, counts);
                break :blk true;
            },
            1 => false,
            2 => blk: {
                _ = try r.readVarU32();
                try skipConstExpr(&r, counts);
                break :blk true;
            },
            else => return Error.InvalidSection,
        };
        const size = try r.readVarU32();
        _ = try r.readN(size);
        counts.data_bytes += size;
        if (active) {
            counts.active_data_segments += 1;
            counts.active_data_bytes += size;
        }
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

const InstructionCounter = struct {
    counts: *Counts,
    imported_functions: u64,

    pub fn onInstr(self: *InstructionCounter, instr: Instr) Error!void {
        const c = self.counts;
        c.instructions += 1;
        c.function_instructions += 1;

        switch (instr.op) {
            0x00 => {
                c.explicit_traps += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x03 => c.loops += 1,
            0x04 => c.conditional_branches += 1,
            0x0c => c.branches += 1,
            0x0d => {
                c.branches += 1;
                c.conditional_branches += 1;
            },
            0x0e => {
                c.branches += 1;
                c.conditional_branches += 1;
            },
            0x10, 0x12 => {
                if (@as(u64, @intCast(instr.imm)) < self.imported_functions) {
                    c.calls_direct_imported += 1;
                } else {
                    c.calls_direct_local += 1;
                }
            },
            0x11 => {
                c.calls_indirect += 1;
                c.call_indirect += 1;
                if (instr.imm2 == 0) {
                    c.indirect_calls_table_zero += 1;
                } else {
                    c.indirect_calls_nonzero_table += 1;
                }
                c.potentially_trapping_table += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x13 => {
                c.calls_indirect += 1;
                c.return_call_indirect += 1;
                if (instr.imm2 == 0) {
                    c.indirect_calls_table_zero += 1;
                } else {
                    c.indirect_calls_nonzero_table += 1;
                }
                c.potentially_trapping_table += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x14 => {
                c.calls_indirect += 1;
                c.call_ref += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x25 => {
                c.table_get += 1;
                c.potentially_trapping_table += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x26 => {
                c.table_set += 1;
                c.potentially_trapping_table += 1;
                c.potentially_trapping_instructions += 1;
            },
            0xd0 => c.ref_null += 1,
            0xd1 => c.ref_is_null += 1,
            0xd2 => c.ref_func += 1,
            0x28...0x35 => {
                c.memory_loads += 1;
                c.potentially_trapping_memory += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x36...0x3e => {
                c.memory_stores += 1;
                c.potentially_trapping_memory += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x6d, 0x6e, 0x7f, 0x80 => {
                c.integer_divisions += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x6f, 0x70, 0x81, 0x82 => {
                c.integer_remainders += 1;
                c.potentially_trapping_instructions += 1;
            },
            0xa8...0xab, 0xae...0xb1 => {
                c.trapping_float_to_int += 1;
                c.potentially_trapping_instructions += 1;
            },
            0xfc => switch (instr.subop) {
                8 => {
                    c.potentially_trapping_memory += 1;
                    c.potentially_trapping_instructions += 1;
                },
                10 => {
                    c.memory_copies += 1;
                    c.potentially_trapping_memory += 1;
                    c.potentially_trapping_instructions += 1;
                },
                11 => {
                    c.memory_fills += 1;
                    c.potentially_trapping_memory += 1;
                    c.potentially_trapping_instructions += 1;
                },
                12 => {
                    c.table_init += 1;
                    c.potentially_trapping_table += 1;
                    c.potentially_trapping_instructions += 1;
                },
                13 => c.elem_drop += 1,
                14 => {
                    c.table_copy += 1;
                    c.potentially_trapping_table += 1;
                    c.potentially_trapping_instructions += 1;
                },
                15 => c.table_grow += 1,
                16 => c.table_size += 1,
                17 => {
                    c.table_fill += 1;
                    c.potentially_trapping_table += 1;
                    c.potentially_trapping_instructions += 1;
                },
                else => {},
            },
            0xfd => {
                c.simd_instructions += 1;
                if (instr.subop <= 11 or (instr.subop >= 84 and instr.subop <= 93)) {
                    c.potentially_trapping_memory += 1;
                    c.potentially_trapping_instructions += 1;
                }
            },
            0xfe => if (instr.subop != 3) {
                c.potentially_trapping_memory += 1;
                c.potentially_trapping_instructions += 1;
            },
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *InstructionCounter, depth: u32) Error!void {
        _ = depth;
        self.counts.br_table_targets += 1;
    }
};

fn parseCodeSection(counts: *Counts, payload: []const u8) Error!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != counts.functions_defined) return Error.FunctionCodeMismatch;
    var counter = InstructionCounter{
        .counts = counts,
        .imported_functions = counts.functions_imported,
    };
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body = try r.readN(try r.readVarU32());
        var locals = Reader.init(body);
        const local_groups = try locals.readVarU32();
        var group: u32 = 0;
        while (group < local_groups) : (group += 1) {
            const local_count = try locals.readVarU32();
            const value_type = try locals.readByte();
            if (value_type == 0x7b) {
                counts.v128_types += local_count;
            } else {
                try countValueType(counts, value_type);
            }
        }
        try wasm_reader.walkFunctionBody(&counter, body);
        counts.instructions += 1;
        counts.function_instructions += 1;
    }
    if (r.remaining() != 0) return Error.TrailingBytes;
}

pub fn analyze(wasm: []const u8) Error!Counts {
    try wasm_reader.checkHeader(wasm);
    var counts = Counts{ .module_bytes = wasm.len };
    var r = Reader.init(wasm[8..]);
    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const payload = try r.readN(try r.readVarU32());
        counts.sections += 1;
        switch (section_id) {
            0 => counts.custom_sections += 1,
            1 => try parseTypeSection(&counts, payload),
            2 => try parseImportSection(&counts, payload),
            3 => try parseFunctionSection(&counts, payload),
            4 => try parseTableSection(&counts, payload),
            5 => try parseMemorySection(&counts, payload),
            6 => try parseGlobalSection(&counts, payload),
            7 => try parseExportSection(&counts, payload),
            9 => try parseElementSection(&counts, payload),
            10 => try parseCodeSection(&counts, payload),
            11 => try parseDataSection(&counts, payload),
            else => {},
        }
    }
    return counts;
}
