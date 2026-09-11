# Provable Loops

QIP's loop verifier proves, from the compiled `.wasm` alone, that every loop terminates. It looks for one local per loop whose writes are all monotonic steps in a single direction, paired with an exit comparison in the matching direction. [Hard Limits](hard-limits.md#fixed-bound-loops) describes the exact evidence rules; this page is about writing and refactoring source code so the compiled output passes.

The one-line summary: **give every loop a cursor that only moves one way, and test that cursor against something stable.**

Every example below was compiled with the repo's production flags (`-O ReleaseSmall`) and verified with the strict-tier components. Two of the "obvious" fixes on this page compile into shapes that fail because the optimizer rewrites loops. Always verify the artifact, not the source:

```bash
qip run -i component.wasm -- application/wasm/wasm-strict-profile.wasm application/wasm/wasm-bounded-loops.wasm
# passes bytes through on success, rejects any strict-tier violation
```

## Shapes that already pass

Ordinary counter loops, `for` over slices, and division countdowns all compile to provable shapes. No rewriting needed:

```zig
// counter loop: i only increases, exit compares i to a stable bound
var i: u32 = 0;
while (i < m) : (i += 1) {
    total +%= buf[i];
}

// for over a slice compiles to the same provable shape
for (buf[0..m]) |b| total +%= b;

// itoa-style division countdown: x shrinks toward zero every iteration
while (x != 0) : (x /= 10) {
    digits += 1;
}

// while(true) with a counter break also passes
while (true) {
    if (i >= m) break;
    total +%= buf[i];
    i += 1;
}
```

Signed or unsigned comparisons, 32-bit or 64-bit counters, bounds held in locals, globals, or constants: all fine.

## Scanning: carry the length, never trust a sentinel

A scan that only stops on a byte value has no visible bound. If the byte never appears, the loop walks memory forever.

```zig
// DON'T: exit depends only on memory contents
while (buf[i] != 0) : (i += 1) {}
```

Put the length check in the loop condition. The counter test provides the bound; the content test stays as a second exit:

```zig
// DO: the i < m test bounds the loop even if the sentinel never appears
while (i < m and buf[i] != 0) : (i += 1) {}
```

This is also just correct code: the DON'T version reads out of bounds on unterminated input.

## Variable strides: add a step budget

Parsers that advance by a decoded length have no constant step, and the verifier cannot know the stride stays positive:

```zig
// DON'T: stride comes from a function of the data; could be zero
while (i < m) {
    i += decodeLen(buf[i]);
    count += 1;
}
```

Bound the iterations instead of the stride. Each item is at least one byte, so the item count cannot exceed the input length:

```zig
// DO: steps is a second cursor that only decreases, with its own exit
var steps: u32 = m;
while (i < m and steps > 0) : (steps -= 1) {
    i += decodeLen(buf[i]);
    count += 1;
}
```

The verifier proves the loop from `steps` alone, so `i` may move however the format demands. The guard also hardens the code: a `decodeLen` bug that returns 0 becomes a clean early exit instead of a hang.

Splitting the stride into a strict part and a data part — `i += 1; i += extra;` where `extra` is a byte load — also proves: the verifier recognizes both the split form and the fused `i = i + extra + 1` add chain LLVM merges it into. The step budget remains the more general tool: it works when the stride is a computed value the verifier can't classify at all, like the `decodeLen` call above.

## Skip-ahead scans: flatten to a state machine

Writing anything other than a step to the cursor disqualifies it — a reset like `i = next` could move it backward, and the verifier can't rule that out:

```zig
// DON'T: the helper's return value overwrites the cursor
while (i < m) : (i += 1) {
    if (buf[i] == '#') {
        i = findLineEnd(i, m);
        lines += 1;
    }
}
```

The natural fix — an inner `while (i < m and buf[i] != '\n') : (i += 1)` scan on the same cursor — looks provable but is not: LLVM canonicalizes the inner loop's exit into an `i = m` copy, which is exactly the kind of write the verifier must reject. Verified: it fails.

What works is one flat loop and a mode flag. The cursor advances by exactly one everywhere, and the "where am I" state lives in a boolean instead of in a second loop:

```zig
// DO: single pass, single +1, a state flag instead of a nested scan
var in_comment = false;
while (i < m) : (i += 1) {
    const b = buf[i];
    if (in_comment) {
        if (b == '\n') in_comment = false;
    } else if (b == '#') {
        in_comment = true;
        lines += 1;
    }
}
```

This is the same transformation that turns a hand-rolled scanner into a table-driven one, and it usually simplifies the code.

## Migrating recursion to a loop with a fixed stack

The strict profile rejects recursive call graphs. A runtime depth guard does not help — the cycle is in the compiled call graph whether or not you bound it. The fix is mechanical: reify the stack. Your existing `MAX_DEPTH` guard stops being a check and becomes an array length.

The key observation is that your algorithm's frame is much smaller than the compiler's. The compiler saves every live local across a recursive call; the algorithm only needs what must be *restored on the way back up*. Write that down before anything else:

- JSON prettifier: which container am I in. One byte.
- SVG rasterizer: inherited transform, fill, stroke, stroke-width. Forty bytes.

Then apply four rewrites. Recursive call → push + stay in the loop. Return → pop. Code *after* a recursive call site → a second loop mode. Depth check on entry → depth check on push.

Before, the JSON shape — the cycle is `value → object/array → value`:

```zig
fn value(p: *Parser, depth: usize) !void {
    if (depth > MAX_DEPTH) return error.InvalidJson;
    switch (p.peek()) {
        '{' => p.object(depth), // calls value(depth + 1) per member,
        '[' => p.array(depth),  // then handles ',' and '}' after it returns
        else => p.scalar(),
    }
}
```

After — one loop, two modes, no cycle:

```zig
fn value(p: *Parser) !void {
    var want_value = true;
    while (true) {
        if (want_value) {
            want_value = switch (p.peek()) {
                '{' => try p.open(.object), // push; false if {} closed inline
                '[' => try p.open(.array),
                else => blk: {
                    try p.scalar();
                    break :blk false;
                },
            };
            continue;
        }
        // A value just finished: close or continue the container on top.
        if (p.depth == 0) return;
        switch (p.next()) {
            '}', ']' => p.pop(),
            ',' => want_value = true, // objects also consume the next key here
            else => return error.InvalidJson,
        }
    }
}

fn open(p: *Parser, kind: Container) !bool {
    // ...
    if (p.depth >= MAX_DEPTH) return error.InvalidJson; // was: depth > MAX_DEPTH on entry
    p.stack[p.depth] = kind; // [MAX_DEPTH]Container — the whole frame
    p.depth += 1;
    // ...
}
```

Two modes are enough for any grammar you'd parse by recursive descent: "produce a value" and "a value just finished." Everything that ran after a recursive call site — the comma/close handling in `object` and `array` — moves into the second mode, dispatched on the container type on top of the stack. The SVG rasterizer is the same transform with a bigger frame: push saves the parent's style on `<g>`, the matching close tag pops it back.

Three things to hold yourself to:

1. **Byte-identical output.** `qip bench old.wasm new.wasm` asserts outputs match while it measures. Diff against the artifact in git, not against your memory of the behavior.
2. **Same boundary.** Nesting accepted and rejected at exactly the same depth as before. Write the two tests: `MAX_DEPTH + 1` levels pass, `MAX_DEPTH + 2` fail.
3. **Measure.** For these two modules: JSON 3% slower on a 900 KB document, noise on depth-heavy input; SVG within noise; binaries +250 and +690 bytes. What you buy: the profile passes, per-level memory drops from a ~2 KB call frame to the bytes you chose, and the depth bound is a number in your source instead of a property of the host's stack size — the recursive SVG rasterizer overflowed at ~25 levels, silently, host-dependently. The loop version handles 128 and traps on 129, everywhere.

The loop you end up with still needs its own bound evidence like any other loop. A parser's cursor advances every iteration, so the scanning rules above usually cover it; if the loop is work-driven rather than input-driven, add fuel — which is the next section.

## Work stacks and recursion: budget the iterations

The strict profile already rejects recursion (the call graph must be acyclic), so tree-shaped work becomes an explicit stack. But a work-stack loop is not provable either — the stack pointer moves both ways:

```zig
// DON'T: sp goes up on push and down on pop; no monotonic cursor
while (sp > 0) {
    sp -= 1;
    const node = stack[sp];
    // ... may push more nodes ...
}
```

Add a fuel counter sized from the input. This is rule 2 of NASA/JPL's Power of Ten — every loop gets a statically verifiable upper bound — and the same shape works for event loops, fixpoint iterations, and interpreters:

```zig
// DO: fuel only decreases and bounds the loop; sp is free to churn
var fuel: u32 = 100_000;
while (sp > 0 and fuel > 0) : (fuel -= 1) {
    sp -= 1;
    const node = stack[sp];
    // ... may push more nodes ...
}
if (fuel == 0) @trap(); // ran past the budget: fail loudly, not wrongly
```

Trap on exhaustion rather than returning partial output. A trap is a clean, observable failure; silently truncated output looks like data loss.

Pick the budget from the input shape — bytes processed, nodes allocated, pixels touched — so legitimate inputs never hit it. If no such bound exists for your workload, that is a sign the component wants the metered tier rather than the strict one.

## Checklist when a loop warns

1. Run `wasm-bounded-loops.wasm` in the strict-tier pipeline.
2. Find the loop's cursor. If there is no local that bounds the loop, add one, usually fuel.
3. Make every write to that cursor a constant step in one direction. Move other work to other locals.
4. Put the cursor exit test in the loop condition. Compare it with a constant, a local set before the loop, or a global.
5. Rebuild and run the pipeline again. The optimizer changes the Wasm shape, so verify the artifact, not the source.

## When not to bother

The verifier is a strict tier, not a universal requirement. Modules with irregular control flow, such as parsers with backtracking, simulations, and interpreters, may work better with `--timeout-ms` or future deterministic fuel metering. If `wasm-bounded-loops.wasm` rejects a module, prove the loop, add a budget, or run it in a less strict tier.
