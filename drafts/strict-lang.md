# A Lightweight Language For Strict-Profile QIP Components

Design notes from a conversation about a new, minimal language that compiles
only to wasm and cannot express a program outside the QIP strict profile.
Nothing here is built; this is a sketch to react to.

## Goal

Make the strict profile ([Hard Limits](../docs/hard-limits.md),
[Provable Loops](../docs/provable-loops.md)) the *type system* rather than a
property you verify after the fact with Zig plus discipline. If it compiles,
it passes `wasm-strict-profile` and `wasm-bounded-loops`. The external wasm
gate stays the trust anchor either way — a compiler bug can't smuggle a
violation past `qip score` — but for a compliant program the compiler's
guarantee should make the gate a formality, not a source of surprise
failures late in the build.

Secondary goal: easy to parse. Keyword-led statements, one declaration per
line, no macros, no operator overloading, define-before-use. LL(1)-ish, a
few hundred lines of recursive descent. This also matters for the drafts on
agentic verification — a language other tools can parse easily is a language
agents can reason about reliably.

## One restriction per profile rule

| Profile rule | Language consequence |
|---|---|
| No ambient imports | No import/FFI mechanism in the general language. The only outside world is the input buffer, declared uniforms, and (for comply components only, see below) the `impl`/`qip` bridge. |
| Declared max memory, no `memory.grow` | No heap, no allocator, no `new`. Every array is a module-level buffer with a compile-time-constant size. The compiler sums buffer sizes and emits `initial == max` memory — fixed memory by construction, not by remembering a linker flag. |
| No indirect calls | No function pointers, no closures-as-values, no dynamic dispatch. Calls are by name. Generics, if any, monomorphize to direct calls. |
| No recursion | Compiler rejects any cycle in the call graph. Cheap to check because there are no indirect calls to obscure it; define-before-use makes acyclicity nearly syntactic. |
| No atomics / shared memory | Nothing to remove — the language has no concurrency model at all. |
| Fixed-bound loops | No general `while`. See below. |

## Loops: only the shapes the verifier already accepts

Rather than offering a general loop and hoping the optimizer preserves a
provable shape (see the LLVM canonicalization failures in Provable Loops,
where the "obvious" fix compiled to an unprovable `i = m` copy), the
language only offers loop forms that compile straight to accepted counter
shapes:

1. **`for i in 0..n`** / **`for b in slice`** — the bound is evaluated once
   into a hidden local before the loop; the induction variable is a
   binding, not an assignable variable, so it cannot be written a second
   way inside the body. Covers most content transforms.
2. **`loop budget n { ... }`** — the general escape hatch. Arbitrary
   `break`/`continue` and arbitrary cursor movement inside, but the
   construct itself emits the monotonic fuel decrement and traps (or runs
   an `else` clause) on exhaustion. This is the fuel idiom from Provable
   Loops made mandatory syntax, so sentinel scans, variable-stride parsers,
   and work-stack loops all fit without the author needing to know the
   verifier's pattern-matching rules.
3. Possibly a built-in fixed-capacity `stack[N] of T` type with trapping
   push/pop, so the recursion-to-explicit-stack transform documented for
   the JSON prettifier example is the idiomatic shape rather than a manual
   migration.

Net effect: the language is deliberately not Turing-complete. Every program
terminates by construction. Anything that genuinely needs unbounded work
belongs in a metered tier, not this one — consistent with the "when not to
bother" section of Provable Loops.

## Codegen: own the backend, don't sit on an optimizer

Emit wasm directly rather than going through LLVM. The provable-loops
failures are the reason: an optimizing backend can rewrite a provably-bounded
loop into a shape the verifier rejects, and the whole point of this language
is that compiling successfully should imply passing. Owning codegen also
keeps the toolchain small, which matches the "lightweight" goal.

This trades away LLVM's optimizations, which fits [[prefer-measured-naive-over-clever]]:
emit boring, predictable code, then `qip bench` it. Strict-tier components
are small transforms where predictable codegen beats clever codegen anyway.

## The ABI as a language construct

Instead of hand-writing `input_ptr` / `output_utf8_cap` / `render` exports
(see [Zig Components](../docs/zig-components.md)), the component declaration
is front matter and the compiler generates the exports and sizes the
buffers, rejecting a program whose declared buffer use exceeds its declared
capacities:

```
component text.transform
input  utf8  cap 64K
output utf8  cap 64K

buf counts: [256]u32

fn render(input: bytes) -> bytes {
    for b in input {
        counts[b] += 1     # bounds-checked; trap on OOB
    }
    ...
}
```

Different component kinds (`text.transform`, `rgba.filter`, the two comply
kinds below) are just different declared signatures the compiler knows how
to lower.

## Semantics details

- Bounds-checked indexing that traps — no raw pointers, only slices over the
  static buffers. Start with runtime checks (measured-naive); a
  Wuffs-style "prove the check away" pass is later optimization work, not a
  v1 requirement.
- Explicit arithmetic: `+` traps on overflow, `+%` wraps, matching Zig and
  mapping 1:1 to wasm.
- Trap is the only failure mode at the component boundary — "fail loudly,
  not wrongly," per Provable Loops' fuel-exhaustion guidance.
- Floats either excluded from v1 or NaN-canonicalized, since NaN bit
  patterns are wasm's one remaining determinism leak.

## Inline tests

Ported from Zig's `test` blocks, and better-behaved here because of the
restrictions above:

- Hermetic by construction. No filesystem, clock, network, or allocator
  means nothing to mock and nothing flaky.
- Total. Test code obeys the same bounded-loop and acyclic-call-graph rules
  as everything else, so the suite provably terminates and the compiler can
  report its worst-case cost.
- Verified as an artifact, not interpreted from source: `qlc test foo.q`
  compiles a test build to wasm (each `test` block becomes a driver case)
  and runs it under the qip runtime, so the semantics tested are the
  semantics shipped.

```
test "empty input is preserved" {
    let out = render("")
    expect out == ""
}

test "trailing spaces trimmed" {
    expect render("abc  ") == "abc"
}
```

`render` is callable from tests because the boundary buffers are static —
the harness writes the input buffer, calls the export, reads the output
buffer, the same loop a comply module runs by hand today. `expect` traps
with the test name and ordinal on failure. Test blocks are stripped from
the production artifact, so they cost nothing against the memory budget.

Tests need one addition to the "no ambient imports" language: a
compile-time **`embed`** declaration for fixture files (`@embedFile`
equivalent). Fine under the profile since embedding happens at build time
and the artifact still imports nothing at runtime. This also covers the
casegen workflow — generated fixture files become embedded tables instead
of a separate imported fixtures module.

## Comply modules as declared component kinds

Comply modules are the deliberate, already-documented exception to "no
imports" ([Hard Limits](../docs/hard-limits.md), [qip comply](../docs/comply.md)).
Rather than opening a general import mechanism, each comply protocol in the
repo becomes its own declared component kind, and the compiler emits exactly
the allowlisted imports and required exports for that kind — nothing else
is reachable from language code.

**Classic `--suite` checkers.** The kind declaration gives typed access to
the implementation and generates the `impl.*` imports plus
`positive()`/`negative()`:

```
comply component "trim-preserves-empty"

positive {
    expect impl.render("") == ""
    expect impl.render(" a ") == "a"
}

negative {
    must_trap impl.render("\xFF\xFE")
}
```

The manual scratch-memory choreography `comply.md` describes — check
capacity is at least 512 bytes, write input at `input_ptr`, expected output
at `input_ptr + 256`, compare — is exactly the kind of protocol a compiler
should own instead of an author re-deriving per module. The language
exposes `impl.render(bytes) -> bytes` as a plain call; the compiler emits
the capacity check, buffer writes, and comparison, and wires `must_trap` to
the host's `qip.render_must_trap`. Bugs like scratch-region overlap or a
missing capacity check stop being things an author can get wrong.

**Bridge-style declare-cases modules** (the newer shape used by
`compliance/unicode-17-lowercase.comply.zig`: component owns its own
memory, imports `qip.render_must_equal` / `qip.render_examine*`, tracks
ordinals itself):

```
comply cases "unicode-17-lowercase"
uniform seed: u32 = 17

cases {
    for c in embed_cases("fixtures/lowercase.cases") {
        must_equal(c.input, oracle(c.input))
    }
    var rng = xorshift32(seed)
    repeat 64 times {
        let input = gen_biased(rng)   # sigma-biased generator, in-language
        must_equal(input, oracle(input))
    }
}
```

Ordinal bookkeeping (manual `ordinal += 1` in the Zig version) becomes
compiler-managed. A seeded-PRNG builtin belongs in the prelude, since
deterministic fuzzing is the only randomness the model should permit at
all.

Comply modules still obey the strict profile otherwise — bounded loops, no
recursion, fixed memory, declared maximums. That suggests a natural
companion on the verifier side: a **comply profile**, the strict profile
with the import allowlist widened to exactly `impl.*` and the `qip.*`
bridge, shippable as a third gate component alongside
`wasm-strict-profile` and `wasm-bounded-loops` so comply artifacts get the
same artifact-level check as normal components.

### Where tests and comply modules meet

An inline `test` and a comply case are both "(input, expected) against the
public ABI." That suggests the compiler could **export a component's
inline tests as a `.comply.wasm`** directly. Cases get written once; in dev
they run as the fast inline suite, and the same cases become a contract
artifact `qip comply` can run against a different implementation of the
same interface — a rewrite, a size-optimized version, next year's spec
update.

Caveat, straight from `comply.md`'s double-entry-accounting framing: tests
exported from an implementation's own source carry that implementation's
biases. Promotion-to-comply is a convenience tier, not a substitute for
independently authored comply modules like the UCD-oracle ones — those
should stay hand-written under the `comply cases` kind above, derived from
the spec rather than from the implementation being checked.

## Ideas from Jai

Jonathan Blow's Jai is unreleased/beta with no fixed public spec, so treat
this as a set of ideas to adapt, not syntax to copy. Several fit this
language unusually well because Jai's whole ethos — explicitness, no hidden
control flow, no hidden allocation — is a milder version of what the strict
profile already forces here.

**Compile-time execution folds `tools/casegen` into the compiler.** Jai's
`#run` executes arbitrary code at compile time and bakes the result into
the binary — used in Jai itself to generate lookup tables, parse data
files, even run the compiler's own tests. That maps directly onto a problem
this repo already has: `compliance/unicode-17-lowercase.comply.zig` imports
a separately generated `unicode-17-lowercase-fixtures.zig`, produced ahead
of time by `tools/casegen` from UCD data. A `#run`-equivalent lets that
become in-language:

```
const lowercase_table = #run generate_from_ucd(embed("UnicodeData.txt"))
```

This doesn't weaken "no ambient imports" — `#run` executes on the host
during compilation, with the host's full capabilities, and only its
*output bytes* are baked into the artifact. The artifact itself still
imports nothing at runtime. It does mean the compiler needs a safe-enough
host-side interpreter for the subset of the language used at compile time,
which is new work, but it replaces an external generator script plus a
"do not edit, regenerate with casegen" file with one buildable artifact.

**Compile-time `#assert` for capacity math.** The lowercase comply module
has a load-bearing comment: `// Worst-case growth is 1.5x; give the oracle
and examine buffers 3x slack.` That's an invariant a comment can't enforce.
Jai's `#assert` (or C11 `static_assert`) checked at compile time turns it
into something the compiler verifies on every build:

```
buf expected_buf: [MAX_INPUT * 3]u8
#assert MAX_INPUT * 3 >= MAX_INPUT * 1.5   # oracle growth bound, with slack
```

Cheap to add, and it directly prevents the class of bug where someone
changes `MAX_INPUT` and forgets the buffers sized off it.

**Baked polymorphism, not generics-via-indirection.** Jai's `proc :: (x: $T)`
generic procedures are instantiated per call-site type at compile time —
no vtable, no boxing, no indirect call. That's the only kind of generics
compatible with "no indirect calls" from the profile table above, so it's
worth adopting as the concrete model rather than inventing one: a generic
`fn max(a: $T, b: $T) -> T` monomorphizes into one direct-call function per
`T` actually used, same as Jai, same as Zig's `comptime`.

**Multiple return values instead of exceptions, trap reserved for the
boundary.** Jai has no exceptions; a fallible procedure returns `(value,
success: bool)` and the caller checks it. Worth using for *internal*
fallibility — a number parser, a table lookup — so a recoverable "this
substring isn't a valid integer" doesn't have to trap the whole component.
Trap stays reserved for actual contract violations: capacity overflow, fuel
exhaustion, malformed input past the point the format says is impossible.
That's a slightly more precise version of the "trap is the only failure
mode" line from the semantics section above — trap is for the boundary
contract, `(value, ok)` is for ordinary control flow inside it.

**`defer` for push/pop discipline.** No heap means no destructors to run,
but `defer` still earns its keep around the explicit `stack[N] of T` from
the loop section: pairing a push with `defer pop()` keeps the recursion-to-
loop migration from Provable Loops honest, the same way `defer` keeps
Jai's manual arena allocations balanced without RAII.

**Deliberate divergence: don't strip bounds checks in release.** Jai checks
array bounds in debug builds and strips the checks in release for speed.
This language should not do that — the trap-on-OOB checks are part of the
strict-profile safety story, not a debug convenience, so they stay in every
build regardless of optimization level. If a specific component's bounds
checks turn out to matter for performance, that's a `qip bench` question
([[prefer-measured-naive-over-clever]]), not a default to flip globally.

**One-line validation of the parsing goal.** Jai's compiler avoids header
files and forward-declaration order dependencies in favor of a simpler,
faster, single-pass-feeling model — different mechanism than this
language's define-before-use rule, but the same instinct: a language and
compiler that get out of the way of iteration speed. Worth citing as
existing precedent that the "easy to parse" goal isn't just this project's
own preference.

## Certified `qip score` at build time, for free

Because the call graph is a DAG and every loop's bound is chosen by the
compiler rather than pattern-matched after optimization, the compiler can
compute at build time what the [Verifier Roadmap](verifier-roadmap.md)
describes as Tier 3 for the external checker: max memory (exact), max call
depth (exact), and max instructions per `render` at declared input
capacity. The build output can *be* the `qip score` manifest, rather than
something a separate static pass has to reconstruct from a binary that may
or may not have preserved provable shapes through optimization.

## Prior art to study before building anything

- **Wuffs** (Google) — no allocation, no FFI, bounds proven at compile
  time. Targets C, and does not require termination, so the loop story
  differs.
- **eBPF verifier** — the bounded-loop evidence rules already borrow its
  spirit; worth re-reading the verifier's loop-bound proof directly.
- **Total languages** (Dafny and similar) — for the termination-checking
  discipline generally, though those aim at proof, not at a tiny
  single-target compiler.
- **Jai** (Jonathan Blow, unreleased/beta) — compile-time execution,
  baked polymorphism, and no-hidden-control-flow ethos; see "Ideas from
  Jai" above for specifics.

The combination that looks novel here: total + first-order + static memory
+ wasm as the only target + an external artifact verifier as the actual
trust anchor rather than the compiler. Keeping trust in the `.wasm` gate
instead of the compiler is the part worth preserving even as the rest of
this design changes.

## Biggest known cost

No standard library. Every component starts from bytes and integers, so
common helpers (UTF-8 decode, integer formatting, the sigma-biased fuzz
generator shape used in the Unicode comply module) need to ship as language
builtins or a small audited prelude. That prelude is probably the largest
real chunk of work in this design, bigger than the compiler frontend or the
wasm backend.

## Ideas from MLIR

MLIR has a deeper contribution to make here than a specific syntax feature:
keep the program's logical operation separate from its SIMD schedule, and
keep both separate from the final wasm instructions. Borrow the model, not
necessarily MLIR itself. A custom MLIR dialect and lowering pipeline would
work against the "few hundred lines, predictable direct-to-wasm compiler"
goal for v1; the useful part is the separation of concerns:

```
structured operation
    ↓ vectorization schedule
virtual vectors and masks
    ↓ fixed wasm lowering
v128 instructions + scalar tail
```

MLIR makes roughly this distinction between structured `linalg` operations,
its target-independent Vector dialect, and hardware-level vectors. QIP's
bottom level is unusually simple: wasm has one 128-bit vector value, viewed
through lane shapes such as `i8x16`, `i16x8`, `i32x4`, and `f32x4`.

The rule worth carrying through the whole design:

> Keep iteration space, memory layout, vector width, and target instructions
> as separate concepts, then permit only lowering steps that preserve the
> strict profile's proofs.

### Structured operations describe meaning

Rather than starting with a hand-vectorized loop, let an author express a
bounded iteration space:

```
map p in pixels {
    output[p] = brighten(input[p], amount)
}
```

Or a stencil:

```
stencil p in pixels radius 2 edge clamp {
    output[p] = gaussian(input[p + offset])
}
```

Or a reduction whose evaluation order is part of its semantics:

```
reduce sum in samples order tree {
    yield sum +% samples[index]
}
```

This is the strongest idea in MLIR's Linalg dialect. An operation retains its
iteration domain, indexing maps, and iterator kinds instead of immediately
becoming arbitrary loops. The compiler can tile or vectorize from that
structure without reverse-engineering memory access from pointer arithmetic.

For this language, the same structure could prove:

- loop bounds
- which buffers are read and written
- whether accesses are contiguous
- whether iterations are independent
- required image halo
- temporary storage
- output-size bounds

The halo result is especially useful. A stencil whose declared reads range
from `p - 2` through `p + 2` can have `calculate_halo_px()` generated as `2`.
The compiler also owns the expanded tile stride, eliminating the dynamic-span
WAT gotcha described in this repo's image notes.

The current scalar halo should be treated as one host projection of a richer
**access footprint**, not as the source language's fundamental model. A
footprint can distinguish:

- left, right, top, and bottom extents instead of overfetching a symmetric
  square
- boundary semantics such as clamp, reflect, wrap, constant, or reject
- a compile-time maximum footprint from the exact value selected by uniforms
- logical valid and output regions from the physical buffer extent
- an immutable input view from output storage, so in-place traversal order
  cannot accidentally change stencil results

For example, a directional filter might declare:

```
reads p + [x: -8..2, y: -1..1] boundary clamp
writes p
```

The existing image ABI can conservatively lower that to
`calculate_halo_px() == 8` and a symmetric clamped tile. A future host can use
the full footprint to fetch less data. Keeping the richer declaration in the
language also leaves room for resampling and geometric transforms, where the
required source region is an affine mapping of the output tile rather than
"the same tile plus N pixels."

Materializing the full image between stages, as the current halo pipeline
does, keeps each stage's footprint local and independent. If pipeline fusion
is added later, the planner must compose footprints backwards through the
pipeline: a blur after an edge detector needs source pixels for both
neighborhoods, not merely the larger of the two scalar halo values. Structured
access maps make that composition explicit instead of relying on filter-name
knowledge in the host.

### A first-class virtual vector type

Model vectors by their lane meaning, not as a raw `v128`:

```
vec<16, u8>
vec<8, i16>
vec<4, u32>
vec<4, f32>
mask<16>
```

`v128` is a storage and register representation. `vec<16, u8>` carries the
lane interpretation needed to choose arithmetic, comparisons, widening,
narrowing, and reductions.

For v1, require:

```
lanes * bit_width(T) == 128
```

That gives direct, predictable lowering. Later, virtual widths could be
permitted:

```
vec<32, u8>   # two v128 values
vec<3, f32>   # scalarized or padded according to declared policy
```

MLIR progressively lowers non-native and multidimensional vectors into
target-supported one-dimensional vectors. QIP needs only a much smaller
fixed-width subset of that machinery.

This also complements the element-type / logical-shape / physical-layout
separation in [Numeric Outputs as SIMD-Aware Tensors](tensor-outputs.md). A
tensor or view is memory; a vector is a computation value loaded from that
memory. They should not be the same type.

### Masks are a real type

Comparisons produce masks:

```
let dark: mask<16> = pixels < splat(32)
let adjusted = select(dark, brighten(pixels), pixels)

if any(dark) { ... }
let bits: u32 = bitmask(dark)
```

This maps cleanly onto wasm comparisons, `v128.bitselect`, `*.all_true`,
`*.any_true`, and `*.bitmask`. It also prevents masks from becoming vaguely
typed vectors of zero and negative one, with the signedness and lane-width
mistakes that follow.

A mask must not imply generally safe masked memory access, however. Wasm
does not provide it. That makes boundary semantics part of the language
rather than an optimizer detail.

### Tail and boundary behavior are explicit

MLIR's `vector.transfer_read` and `vector.transfer_write` describe vector
access independently of how boundary lanes eventually lower. This language
could adopt a smaller, more explicit form:

```
load<16>(input, at i) in_bounds
load<16>(input, at i) pad 0
load<16>(input, at i) edge clamp
```

Vector loops declare their tail policy:

```
vector for i in 0..input.size lanes 16 tail scalar {
    ...
}
```

Useful policies:

- `tail scalar`: full-vector loop followed by a bounded scalar loop
- `tail pad value`: missing lanes have a specified value
- `tail clamp`: image-style edge clamping
- `tail reject`: input length must be a lane multiple
- `tail store_partial`: only valid lanes are written

The compiler must never implement `pad` by performing an out-of-bounds
`v128.load` and masking afterward; the illegal load has already happened.
It must prove all 16 bytes lie inside the physical buffer or construct the
final vector from safe scalar or lane loads.

This gives vector memory operations meaningful safety semantics rather than
exposing a fast but sharp raw load primitive.

### The algorithm and its schedule are separate

MLIR's Transform dialect separates payload IR from the IR directing tiling,
unrolling, and vectorization. A deliberately small QIP version could look
like:

```
schedule gaussian_fast for gaussian {
    tile y by 4
    vectorize x lanes 4
    tail scalar
}
```

Or:

```
emit gaussian_scalar using default
emit gaussian_simd using gaussian_fast
```

This fits the repo's benchmark discipline directly:

```
qip bench gaussian_scalar.wasm gaussian_simd.wasm
```

It should not become an open-ended rewrite language. Each schedule operation
is compiler-defined and proof-preserving: initially `tile`, `vectorize`,
`unroll`, `fuse`, `tail`, and possibly `layout`. The compiler rejects a
schedule when it cannot preserve bounds, access safety, or exact arithmetic
semantics.

The applied schedule belongs in the score manifest:

```
kernel gaussian
  logical iterations: width × height
  tile:                 64 × 64
  vector lanes:         4 × f32
  full-vector loops:    floor(width / 4)
  scalar tail:          width % 4
  memory alignment:     16
  halo:                 6
```

That is more useful than silently hoping an optimizer vectorizes something.

### Arithmetic has lane-level modes

The scalar proposal already distinguishes trapping and wrapping arithmetic.
SIMD makes the distinction more important because wasm offers wrapping and
saturating operations but not general trapping vector addition:

```
a +% b                # wrapping
add_sat(a, b)         # saturating
add_checked(a, b)     # traps if any lane overflows
```

`add_checked` lowers to arithmetic plus overflow comparisons, followed by
`any(mask)` and a trap.

For image processing, widening and narrowing should also be first-class:

```
let wide = widen_low<u16>(bytes)
let result = narrow_sat<u8>(wide_a, wide_b)
```

These map directly to wasm SIMD and avoid asking the compiler to recognize a
fragile collection of casts and clamps.

### Reductions pin their order

Automatic SIMD reduction is dangerous for deterministic floating-point
output because vectorization may change association:

```
((a + b) + c) + d
```

is not necessarily equal to:

```
(a + b) + (c + d)
```

Reductions therefore distinguish:

```
reduce ... order left
reduce ... order tree
reduce ... order lanes_then_left
```

The order is program semantics, not an optimizer choice. For integer
wrapping operations, several orderings may be equivalent and the compiler
can exploit that. For floats, it must preserve the declared tree and
canonicalize NaNs if that remains the language rule.

Relaxed SIMD should be outside the strict language. Core wasm SIMD is already
accepted by the repository's strict-profile checker, including lane loads and
shuffles; relaxed instructions add target-dependent choices that work against
the determinism goal.

### Layout types unlock vectorization

Buffers and views can carry logical shape and physical layout separately:

```
view<rgba8, [height, width], interleaved, align 16>
view<u8, [4, height, width], planar, align 16>
view<f32, [rows, cols], row_stride 112, align 16>
```

An indexing expression then contains enough information to determine whether
adjacent logical elements are adjacent bytes. That makes several
transformations mechanically checkable:

- interleaved RGBA: operate on four pixels as `u8x16`
- planar RGBA: operate on sixteen channel samples as `u8x16`
- padded matrix rows: vector loads never cross row boundaries
- halo tiles: vector loads can use physical halo while respecting logical
  edges

MLIR uses affine indexing maps for the general version. QIP probably wants a
finite set of layouts — dense, strided, planar, interleaved, transpose —
rather than arbitrary affine expressions in v1.

### A complete source sketch

The structured operation says "four independent RGBA pixels"; the schedule
says to pack them into one `u8x16`; lowering chooses the shuffles or masks
needed to preserve alpha:

```
kernel brighten(
    input: view<rgba8, [height, width], interleaved, align 16>,
    output: view<rgba8, [height, width], interleaved, align 16>,
    amount: u8,
) {
    map p in input.pixels {
        let rgba = input[p]
        output[p] = rgba {
            r = add_sat(rgba.r, amount)
            g = add_sat(rgba.g, amount)
            b = add_sat(rgba.b, amount)
            a = rgba.a
        }
    }
}

schedule brighten_simd for brighten {
    vectorize pixels lanes 4
    tail scalar
}
```

Most compilers discard high-level structure, optimize aggressively, and emit
whatever loop form results. Here, retaining structured operations strengthens
the certificate:

- vectorization multiplies the induction step by a compile-time constant
- scalar tails remain visibly bounded
- access maps prove full-width loads
- stencil offsets derive halo
- layouts determine alignment and stride
- reduction order preserves determinism
- the final emitted wasm remains the trust anchor

The combination looks genuinely useful: MLIR-style structured vectorization
inside a total language where every transformation must preserve a
mechanically reported memory and execution bound.
