# casegen — Unicode case tables for QIP components

Generates `text/lib/unicode-17-lowercase-tables.zig` and the duel fixtures
`test/fixtures/unicode-17-lowercase.json` from the pinned Unicode 17.0.0 UCD files in
`ucd-17.0.0/` (committed; URLs and SHA-256 pins in `main.go`'s header), then
cross-checks every code point against `golang.org/x/text` `cases.Lower` as an
independent oracle. It also emits the tables and curated inputs for the two
**Content Compliance components** (`compliance/unicode-17-{lowercase,uppercase}.comply.zig`),
which embed their own UCD-derived oracles and declare curated + seeded-fuzz +
property cases through the `qip` host bridge (see the README TODO for the
bridge ABI; `test/lib/compliance-harness.mjs` is the reference host). The
compliance components are the executable specs: any implementation in any
language must pass the same cases, referenced as (component hash, seed,
ordinal) — see `compliance/hosts/uppercase-node/` and `compliance/hosts/uppercase-go/`.

## Regenerate

```sh
cd tools/casegen
go run .                 # rewrites tables + fixtures, exits nonzero on oracle mismatch
go run . -nfc-singletons-only
cd ../..
make text/unicode-17-lowercase.wasm
node --test test/unicode-17-lowercase.mjs
```

Expected output includes `cross-check mismatches: 0`. The line
`mappings newer than oracle's Unicode 15.0.0: 55 code points` is normal: x/text
selects case tables by Go-version build tags (Go 1.26 = Unicode 15.0.0), so
mappings added in Unicode 16/17 (Garay, U+A7CB…) are ours-right/oracle-stale.
Fixtures record this per entry in `oracle_matches`.

## Adding another BCP 47 tag (say `fr`)

**Step 1 — the identity gate.** Unicode default (`und`/root) lowercase is what
almost every locale uses; only a handful of tags tailor casing. Check before
building anything:

```sh
go run . -check-tag fr
# fr lowercase is byte-identical to en: alias text/unicode-17-lowercase.wasm …
```

Exit 0 ⇒ **alias, don't rebuild.** `fr`, `de`, `es`, and `und` are all
byte-identical to `en` over every code point and every Final_Sigma context.
Ship the alias with two Makefile lines (same pattern the repo already uses for
recipe symlinks):

```make
text/unicode-17-lowercase-fr.wasm: text/unicode-17-lowercase.wasm
	cp $< $@
```

The two artifacts have identical bytes and therefore identical hashes — the
component identity *is* the behavioral claim, and "fr equals en" is verifiable
by `shasum` instead of by trust.

**Step 2 — real tailorings get real components.** Exit 1 names the differing
cases. The complete set of lowercase-tailoring tags:

| Tag | Differences vs root | What an implementation needs |
|---|---|---|
| `tr`, `az` | `I` → `ı`, `İ` → `i` | 2 table deltas + the `Not_Before_Dot` / `After_I` conditional rules from SpecialCasing.txt (an `I` followed by U+0307 lowercases to `i` and absorbs the dot) |
| `lt` | 14 code points; accented `i`/`j` keep an explicit dot (`Ì` → `i̇̀`) | table deltas + the `More_Above` conditional rule |

That is the entire list — Unicode has no other lowercase tailorings. To add
one: extend `applySpecialCasing` to include the tag's conditional lines,
implement the (small) context rules in a per-tag component alongside the
Final_Sigma logic in `unicode-17-lowercase.zig`, generate
`unicode-17-lowercase-<tag>-tables.zig`,
and point fixture generation's oracle at `cases.Lower(language.MustParse(tag))`.
The cross-check loop then verifies the port for free, exactly as it does for en.

**Step 3 — wire up.** Per component: a Makefile dependency line on its tables
file, a `node --test` line in `test-node`, and fixtures generated with the
tag's oracle.

## Design notes

- Tables come from the UCD directly (UnicodeData.txt Simple_Lowercase_Mapping,
  SpecialCasing.txt unconditional entries, DerivedCoreProperties.txt Cased +
  Case_Ignorable, and canonical singleton decompositions from UnicodeData.txt).
  x/text is *only* the case-conversion oracle, never the data source — so the
  component's Unicode version is pinned by the committed UCD files, not by
  whatever Go release built the generator.
- Invalid UTF-8 bytes pass through unchanged as uncased characters, matching
  x/text `cases.Lower` byte-for-byte (verified by fixtures).
- U+03A3 is excluded from the tables; Final_Sigma is context logic in the
  component (`prev cased` + lookahead over Case_Ignorable).
- Naming: the component is `unicode-17-lowercase.wasm`, not `lowercase-en.wasm`,
  because
  it implements Unicode Default Case Conversion (und root) — byte-identical
  for every tag without a casing tailoring. Elixir's `String.downcase/2` mode
  set (`:default | :ascii | :greek | :turkic`) is the precedent: variants are
  named by *tailoring family*, so a Turkish/Azerbaijani component would be
  `unicode-17-lowercase-turkic.wasm` rather than one artifact per BCP 47 tag.
  The Unicode version lives in the name (the `utf8mb4_0900_ai_ci` move): the
  identifier states its data revision, so a future UCD 18 build is a visibly
  different artifact (`unicode-18-lowercase.wasm`) and upgrading is an explicit,
  diffable act rather than silent drift. One nuance:
  our default *includes* Final_Sigma (per Unicode rule R1, matching ICU,
  x/text, and JS `toLowerCase()`), whereas Elixir's `:default` excludes it and
  offers it as `:greek`.
- This generator is the pilot for the CLDR-to-Zig pipeline sketched in
  `drafts/i18n-formatting.md`: the same shape (pinned upstream data files →
  generated Zig tables → shared core logic → per-locale thin variants → oracle
  duel in CI) applies to date/number/plural components, where per-locale
  *data* differences are the norm rather than the exception.
