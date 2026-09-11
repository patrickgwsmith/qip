# Counting A WebAssembly Module

`wasm-counts.wasm` turns a WebAssembly module into deterministic long-form
CSV. It reports factual static counts for comparing builds; it does not assign
a score or decide whether a module is acceptable.

```sh
make -j qip application/wasm/wasm-counts.wasm

qip run \
  -i text/e164.wasm \
  -- application/wasm/wasm-counts.wasm
```

The output has one integer measurement per row:

```csv
metric,value
module_bytes,304
functions_defined,5
functions_imported,0
instructions,75
loops,1
branches,5
simd_instructions,0
```

Rows are always emitted in the same order, including zero values. This makes
the output useful with `diff`, spreadsheets, and databases without treating a
missing row as zero.

## What It Counts

The report covers module structure, functions, control flow, calls, SIMD,
declared memory, data segments, and instructions that can trap directly based
on their operands or bounds.

- `loops` counts structured `loop` instructions.
- `function_instructions` counts instructions in function bodies. `instructions`
  also includes instructions in constant expressions used by globals and
  active data or element segments.
- `branches` counts `br`, `br_if`, and `br_table` instructions.
- `conditional_branches` counts `if`, `br_if`, and `br_table` instructions.
- `simd_instructions` counts instructions in the SIMD opcode space.
- `v128_types` counts `v128` occurrences in function and global types.
- `table_initial_slots` and `table_maximum_slots` sum declared table limits.
  `element_initializers` counts values supplied by element segments; it is not
  the table's capacity.
- `tables_funcref`, `tables_externref`, and `tables_typed_reference` count
  declared table reference types. `tables_fixed_size` counts tables whose
  declared minimum and maximum are equal.
- Element rows separate active, passive, and declarative segments. Active
  segments are also split between table zero and nonzero tables. Their offset
  expressions distinguish `i32.const 0`, `i32.const 1`, other `i32.const`
  values, `global.get`, and other expressions. Initializers are split between
  function-index and expression encodings.
- `call_indirect`, `return_call_indirect`, and `call_ref` count those exact
  instructions. `calls_indirect` remains their aggregate. Table-indexed calls
  are also split between table zero and nonzero tables.
- `table_get`, `table_set`, `table_init`, `elem_drop`, `table_copy`,
  `table_grow`, `table_size`, and `table_fill` count those exact instructions.
  The `ref_null`, `ref_is_null`, and `ref_func` rows do the same for reference
  instructions.
- `memory_loads`, `memory_stores`, `memory_copies`, and `memory_fills` count
  instruction sites, not runtime accesses.
- `potentially_trapping_instructions` combines explicit traps, integer
  division and remainder, trapping float-to-integer conversion, bounded
  memory and table operations, and indirect or reference calls.
- `explicit_traps`, `integer_divisions`, `integer_remainders`,
  `trapping_float_to_int`, `potentially_trapping_memory`,
  `potentially_trapping_table`, and `call_ref` expose that total's parts.

The trapping count describes instruction sites, not executions. A load that
is provably in bounds still counts, while an ordinary direct call does not
count merely because its callee might trap.

All rows report facts from the binary. The component does not decide whether
a table shape, instruction, or count is acceptable. Apply those decisions in
a separate checker or in the system that consumes the CSV.

Memory rows report declared capacity and initial data. They do not measure
allocator use, working set, stack depth, or peak memory; those require running
or instrumenting the module.

## Load It Into SQLite

SQLite's shell can import the output directly:

```sh
qip run -i a.wasm -- application/wasm/wasm-counts.wasm > a.csv

sqlite3 counts.db
```

Then use the shell's CSV mode:

```text
.mode csv
.headers on
CREATE TABLE a_counts (metric TEXT PRIMARY KEY, value INTEGER NOT NULL);
.import --skip 1 a.csv a_counts
SELECT * FROM a_counts WHERE metric IN ('loops', 'branches', 'simd_instructions');
```

For comparisons across many modules, add the module name as a column while
loading each file into a shared `(module, metric, value)` table.

## When Not To Use It

Use WABT's `wasm-stats` when you need a full frequency table for every opcode
and immediate value. Use runtime profiling when you need to know which code is
hot or how much memory an execution actually touches. Counts alone do not
predict either result.
