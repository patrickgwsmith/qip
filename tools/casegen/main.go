// casegen generates the Unicode lowercase tables for text/unicode-17-lowercase.zig
// from the Unicode 17.0.0 UCD files in ucd-17.0.0/, then cross-checks every code
// point (and Final_Sigma contexts) against golang.org/x/text cases.Lower and emits
// duel fixtures for test/unicode-17-lowercase.mjs.
//
// UCD 17.0.0 file pins (https://www.unicode.org/Public/17.0.0/ucd/):
//
//	UnicodeData.txt            2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c
//	SpecialCasing.txt          efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588
//	DerivedCoreProperties.txt  24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08
//	CaseFolding.txt            ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183
//
// CaseFolding.txt is not read by casegen itself; it is consumed by
// tools/generate-markdown-tables.py, which emits the reference-label case-fold
// tables for the markdown components and their compliance checkers.
//
// Usage: go run . (from tools/casegen; writes into the repo relative to this dir)
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

const ucdDir = "ucd-17.0.0"

type mapping struct {
	cp    rune
	lower []rune
}

type rng struct{ lo, hi rune }

func parseHex(s string) rune {
	v, err := strconv.ParseUint(strings.TrimSpace(s), 16, 32)
	if err != nil {
		panic(fmt.Sprintf("bad hex %q: %v", s, err))
	}
	return rune(v)
}

func parseSeq(s string) []rune {
	fields := strings.Fields(strings.TrimSpace(s))
	out := make([]rune, 0, len(fields))
	for _, f := range fields {
		out = append(out, parseHex(f))
	}
	return out
}

func eachLine(path string, fn func(line string)) {
	f, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fn(line)
	}
	if err := sc.Err(); err != nil {
		panic(err)
	}
}

func loadSimpleLower() map[rune][]rune {
	m := map[rune][]rune{}
	eachLine(ucdDir+"/UnicodeData.txt", func(line string) {
		fields := strings.Split(line, ";")
		if len(fields) < 15 {
			return
		}
		low := strings.TrimSpace(fields[13])
		if low == "" {
			return
		}
		cp := parseHex(fields[0])
		m[cp] = []rune{parseHex(low)}
	})
	return m
}

// applySpecialCasing overrides simple mappings with the unconditional full
// lowercase mappings (conditional entries are locale/tr/az/lt or Final_Sigma,
// which the component implements in code).
func applySpecialCasing(m map[rune][]rune) {
	eachLine(ucdDir+"/SpecialCasing.txt", func(line string) {
		fields := strings.Split(line, ";")
		if len(fields) < 5 {
			return
		}
		cond := strings.TrimSpace(fields[4])
		if cond != "" {
			return
		}
		cp := parseHex(fields[0])
		lower := parseSeq(fields[1])
		if len(lower) == 1 && lower[0] == cp {
			delete(m, cp)
			return
		}
		m[cp] = lower
	})
}

func loadProperty(name string) []rng {
	var out []rng
	eachLine(ucdDir+"/DerivedCoreProperties.txt", func(line string) {
		fields := strings.Split(line, ";")
		if len(fields) < 2 || strings.TrimSpace(fields[1]) != name {
			return
		}
		cps := strings.TrimSpace(fields[0])
		if lohi := strings.SplitN(cps, "..", 2); len(lohi) == 2 {
			out = append(out, rng{parseHex(lohi[0]), parseHex(lohi[1])})
		} else {
			cp := parseHex(cps)
			out = append(out, rng{cp, cp})
		}
	})
	sort.Slice(out, func(i, j int) bool { return out[i].lo < out[j].lo })
	// merge adjacent
	merged := out[:0]
	for _, r := range out {
		if n := len(merged); n > 0 && r.lo <= merged[n-1].hi+1 {
			if r.hi > merged[n-1].hi {
				merged[n-1].hi = r.hi
			}
			continue
		}
		merged = append(merged, r)
	}
	return merged
}

func inRanges(rs []rng, cp rune) bool {
	i := sort.Search(len(rs), func(i int) bool { return rs[i].hi >= cp })
	return i < len(rs) && rs[i].lo <= cp
}

// ourLower mirrors the component's algorithm, for cross-checking. Invalid
// UTF-8 bytes are copied through unchanged and treated as uncased,
// non-ignorable characters — matching x/text cases.Lower.
func ourLower(s string, m map[rune][]rune, cased, ignorable []rng) string {
	var b strings.Builder
	prevCased := false
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size <= 1 {
			b.WriteByte(s[i])
			prevCased = false
			i++
			continue
		}
		if r == 'Σ' {
			followedByCased := false
			for j := i + size; j < len(s); {
				r2, size2 := utf8.DecodeRuneInString(s[j:])
				if r2 == utf8.RuneError && size2 <= 1 {
					break
				}
				if inRanges(ignorable, r2) {
					j += size2
					continue
				}
				followedByCased = inRanges(cased, r2)
				break
			}
			if prevCased && !followedByCased {
				b.WriteRune('ς')
			} else {
				b.WriteRune('σ')
			}
			prevCased = true
			i += size
			continue
		}
		if lower, ok := m[r]; ok {
			for _, l := range lower {
				b.WriteRune(l)
			}
		} else {
			b.WriteRune(r)
		}
		if !inRanges(ignorable, r) {
			prevCased = inRanges(cased, r)
		}
		i += size
	}
	return b.String()
}

func emitZig(m map[rune][]rune, cased, ignorable []rng, path string) {
	cps := make([]rune, 0, len(m))
	for cp := range m {
		if cp == 'Σ' {
			continue
		}
		cps = append(cps, cp)
	}
	sort.Slice(cps, func(i, j int) bool { return cps[i] < cps[j] })

	var blob []byte
	var keys, packed []string
	for _, cp := range cps {
		var enc []byte
		for _, l := range m[cp] {
			enc = append(enc, []byte(string(l))...)
		}
		off := len(blob)
		blob = append(blob, enc...)
		if off > 0xFFFFFF || len(enc) > 0xFF {
			panic("blob layout overflow")
		}
		keys = append(keys, fmt.Sprintf("0x%X", cp))
		packed = append(packed, fmt.Sprintf("0x%X", off<<8|len(enc)))
	}

	var b strings.Builder
	b.WriteString("// Generated by tools/casegen from UCD 17.0.0 — do not edit.\n")
	b.WriteString("// Full lowercase mappings (UnicodeData.txt Simple_Lowercase_Mapping +\n")
	b.WriteString("// SpecialCasing.txt unconditional entries). U+03A3 handled in code.\n\n")
	writeArr := func(name, typ string, vals []string) {
		fmt.Fprintf(&b, "pub const %s = [_]%s{", name, typ)
		for i, v := range vals {
			if i%12 == 0 {
				b.WriteString("\n    ")
			}
			b.WriteString(v)
			if i != len(vals)-1 {
				b.WriteString(", ")
			}
		}
		b.WriteString("\n};\n\n")
	}
	writeArr("map_keys", "u32", keys)
	writeArr("map_packed", "u32", packed)
	blobVals := make([]string, len(blob))
	for i, v := range blob {
		blobVals[i] = fmt.Sprintf("0x%02X", v)
	}
	writeArr("map_blob", "u8", blobVals)

	rangeVals := func(rs []rng) []string {
		out := make([]string, 0, len(rs)*2)
		for _, r := range rs {
			out = append(out, fmt.Sprintf("0x%X", r.lo), fmt.Sprintf("0x%X", r.hi))
		}
		return out
	}
	writeArr("cased_ranges", "u32", rangeVals(cased))
	writeArr("case_ignorable_ranges", "u32", rangeVals(ignorable))

	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("wrote %s: %d mappings (%d blob bytes), %d cased ranges, %d ignorable ranges\n",
		path, len(cps), len(blob), len(cased), len(ignorable))
}

type fixture struct {
	Name     string `json:"name"`
	InputB64 string `json:"input_b64"`
	WantB64  string `json:"want_b64"`
	// OracleMatches records whether x/text v0.40.0 (tables at the Go stdlib's
	// Unicode version) agrees with the UCD-17 expectation for this fixture.
	OracleMatches bool `json:"oracle_matches"`
}

// checkTag reports whether cases.Lower(tag) is byte-identical to the en/root
// lowercase over every code point and the Final_Sigma context probes. Exit 0
// means "alias unicode-17-lowercase.wasm for this tag"; exit 1 means the tag needs
// its own tables and conditional rules (tr, az, lt).
func checkTag(tagName string) {
	tag, err := language.Parse(tagName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "bad BCP 47 tag %q: %v\n", tagName, err)
		os.Exit(2)
	}
	en := cases.Lower(language.English)
	other := cases.Lower(tag)
	diffs := 0
	for cp := rune(0); cp <= 0x10FFFF; cp++ {
		if cp >= 0xD800 && cp <= 0xDFFF {
			continue
		}
		s := string(cp)
		if en.String(s) != other.String(s) {
			diffs++
			if diffs <= 20 {
				fmt.Printf("U+%04X: en=%q %s=%q\n", cp, en.String(s), tag, other.String(s))
			}
		}
	}
	for _, s := range []string{"ΑΣ", "ΑΣΒ", "İ", "ì", "İİ", "II"} {
		if en.String(s) != other.String(s) {
			diffs++
			fmt.Printf("ctx %q: en=%q %s=%q\n", s, en.String(s), tag, other.String(s))
		}
	}
	if diffs == 0 {
		fmt.Printf("%s lowercase is byte-identical to en: alias text/unicode-17-lowercase.wasm, no new tables needed\n", tag)
		return
	}
	fmt.Printf("%s lowercase differs from en in %d cases: this tag needs its own component\n", tag, diffs)
	os.Exit(1)
}

func main() {
	checkFlag := flag.String("check-tag", "", "compare cases.Lower(<BCP 47 tag>) against en over all code points, then exit")
	flag.Parse()
	if *checkFlag != "" {
		checkTag(*checkFlag)
		return
	}

	m := loadSimpleLower()
	applySpecialCasing(m)
	cased := loadProperty("Cased")
	ignorable := loadProperty("Case_Ignorable")

	emitZig(m, cased, ignorable, "../../text/lib/unicode-17-lowercase-tables.zig")
	emitZig(m, cased, ignorable, "../../compliance/unicode-17-lowercase-tables.zig")

	caser := cases.Lower(language.English)
	fmt.Printf("oracle: x/text cases.Lower(language.English), Go stdlib unicode %s\n", unicode.Version)

	mismatches := 0
	newerThanOracle := 0
	for cp := rune(0); cp <= 0x10FFFF; cp++ {
		if cp >= 0xD800 && cp <= 0xDFFF {
			continue
		}
		s := string(cp)
		want := caser.String(s)
		got := ourLower(s, m, cased, ignorable)
		if want != got {
			// The oracle's tables follow the Go stdlib Unicode version; mappings
			// added in later UCD versions show up as oracle-identity vs ours-mapped
			// and are the intended UCD-17 behavior, not an error.
			if want == s && got != s {
				newerThanOracle++
				continue
			}
			mismatches++
			if mismatches <= 20 {
				fmt.Printf("MISMATCH U+%04X: ours %q oracle %q\n", cp, got, want)
			}
		}
	}
	fmt.Printf("mappings newer than oracle's Unicode %s: %d code points (UCD 17 wins)\n", unicode.Version, newerThanOracle)
	// Final_Sigma context probes: sigma with every class of neighbor.
	contexts := []string{
		"Σ", "ΑΣ", "ΑΣ.", "ΑΣΒ", "Α Σ", "ΑΣ́", "ΑΣ́Β", "Σ́",
		"ΟΔΥΣΣΕΥΣ", "ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ ΣΟΦΟΣ.", "ΣΣ", "ΑΣ'Β", "ΑΣ’", "1Σ2",
	}
	for _, s := range contexts {
		want := caser.String(s)
		got := ourLower(s, m, cased, ignorable)
		if want != got {
			mismatches++
			fmt.Printf("MISMATCH ctx %q: ours %q oracle %q\n", s, got, want)
		}
	}
	fmt.Printf("cross-check mismatches: %d\n", mismatches)

	fixtures := []fixture{}
	type rawCase struct {
		name     string
		in, want []byte
	}
	rawCases := []rawCase{}
	add := func(name, in string) {
		want := ourLower(in, m, cased, ignorable)
		fixtures = append(fixtures, fixture{
			Name:          name,
			InputB64:      base64.StdEncoding.EncodeToString([]byte(in)),
			WantB64:       base64.StdEncoding.EncodeToString([]byte(want)),
			OracleMatches: want == caser.String(in),
		})
		rawCases = append(rawCases, rawCase{name, []byte(in), []byte(want)})
	}
	add("empty", "")
	add("ascii", "Hello, World! QIP 123")
	add("german-caps-eszett", "STRASSE ẞ GROẞ")
	add("dotted-I-en", "İstanbul İ I ı")
	add("greek-final-sigma", "ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ ΣΟΦΟΣ. ΟΔΥΣΣΕΥΣ")
	add("greek-sigma-contexts", "Σ ΑΣ ΑΣ. ΑΣΒ ΑΣ́ ΑΣ́Β ΣΣ 1Σ2 ΑΣ’")
	add("titlecase-digraphs", "ǅungla Ǳ Ǆ ǈ")
	add("ij-digraph", "ĲSSELMEER")
	add("cherokee", "ᏣᎳᎩ ᎣᏏᏲ")
	add("deseret-plane1", "\U00010400\U00010401\U00010402")
	add("garay-unicode16", "\U00010D50\U00010D51\U00010D52")
	add("mixed-scripts", "ПРИВЕТ ΓΕΙΑ HELLO مرحبا 你好 ЁЖИК")
	add("armenian-georgian", "ԵՐԵՎԱՆ ᲐᲑᲒ ႠႡႢ")

	rnd := rand.New(rand.NewSource(17))
	var mapped []rune
	for cp := range m {
		mapped = append(mapped, cp)
	}
	sort.Slice(mapped, func(i, j int) bool { return mapped[i] < mapped[j] })
	for i := 0; i < 24; i++ {
		var sb strings.Builder
		n := 1 + rnd.Intn(40)
		for j := 0; j < n; j++ {
			switch rnd.Intn(5) {
			case 0:
				sb.WriteRune(mapped[rnd.Intn(len(mapped))])
			case 1:
				sb.WriteRune('Σ')
			case 2:
				sb.WriteRune(rune(0x20 + rnd.Intn(0x60)))
			case 3:
				sb.WriteRune('́')
			case 4:
				sb.WriteRune(rune(0xA0 + rnd.Intn(0x2000)))
			}
		}
		add(fmt.Sprintf("random-%02d", i), sb.String())
	}

	out, err := json.MarshalIndent(fixtures, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile("../../test/fixtures/unicode-17-lowercase.json", append(out, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("wrote ../../test/fixtures/unicode-17-lowercase.json: %d fixtures\n", len(fixtures))

	var zb strings.Builder
	zb.WriteString("// Generated by tools/casegen from UCD 17.0.0 — do not edit.\n")
	zb.WriteString("// Curated inputs for compliance/unicode-17-lowercase.comply.zig. Inputs\n")
	zb.WriteString("// only: expected outputs come from the component's embedded oracle.\n\n")
	zb.WriteString("pub const Case = struct {\n    name: []const u8,\n    input: []const u8,\n};\n\npub const cases = [_]Case{\n")
	for _, c := range rawCases {
		fmt.Fprintf(&zb, "    .{ .name = \"%s\", .input = \"%s\" },\n", c.name, zigEscape(c.in))
	}
	zb.WriteString("};\n")
	if err := os.WriteFile("../../compliance/unicode-17-lowercase-fixtures.zig", []byte(zb.String()), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("wrote ../../compliance/unicode-17-lowercase-fixtures.zig: %d cases\n", len(rawCases))

	mismatches += generateUppercase()

	if mismatches > 0 {
		os.Exit(1)
	}
}

func zigEscape(b []byte) string {
	var sb strings.Builder
	for _, c := range b {
		if c >= 0x20 && c < 0x7F && c != '"' && c != '\\' {
			sb.WriteByte(c)
		} else {
			fmt.Fprintf(&sb, "\\x%02X", c)
		}
	}
	return sb.String()
}

func loadSimpleUpper() map[rune][]rune {
	m := map[rune][]rune{}
	eachLine(ucdDir+"/UnicodeData.txt", func(line string) {
		fields := strings.Split(line, ";")
		if len(fields) < 15 {
			return
		}
		up := strings.TrimSpace(fields[12])
		if up == "" {
			return
		}
		cp := parseHex(fields[0])
		m[cp] = []rune{parseHex(up)}
	})
	return m
}

// applySpecialCasingUpper overrides simple mappings with unconditional full
// uppercase mappings (ligatures, sharp s, ypogegrammeni). Unicode default
// uppercase has no context rules at all — unlike lowercase's Final_Sigma.
func applySpecialCasingUpper(m map[rune][]rune) {
	eachLine(ucdDir+"/SpecialCasing.txt", func(line string) {
		fields := strings.Split(line, ";")
		if len(fields) < 5 {
			return
		}
		if strings.TrimSpace(fields[4]) != "" {
			return
		}
		cp := parseHex(fields[0])
		upper := parseSeq(fields[3])
		if len(upper) == 1 && upper[0] == cp {
			delete(m, cp)
			return
		}
		m[cp] = upper
	})
}

// ourUpper mirrors the compliance component's embedded oracle: table lookup
// over the valid UTF-8 input domain, with no context rules.
func ourUpper(s string, m map[rune][]rune) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size <= 1 {
			b.WriteByte(s[i])
			i++
			continue
		}
		if upper, ok := m[r]; ok {
			for _, u := range upper {
				b.WriteRune(u)
			}
		} else {
			b.WriteRune(r)
		}
		i += size
	}
	return b.String()
}

func emitUpperTablesZig(m map[rune][]rune, path string) {
	cps := make([]rune, 0, len(m))
	for cp := range m {
		cps = append(cps, cp)
	}
	sort.Slice(cps, func(i, j int) bool { return cps[i] < cps[j] })

	var blob []byte
	var keys, packed []string
	for _, cp := range cps {
		var enc []byte
		for _, u := range m[cp] {
			enc = append(enc, []byte(string(u))...)
		}
		off := len(blob)
		blob = append(blob, enc...)
		if off > 0xFFFFFF || len(enc) > 0xFF {
			panic("blob layout overflow")
		}
		keys = append(keys, fmt.Sprintf("0x%X", cp))
		packed = append(packed, fmt.Sprintf("0x%X", off<<8|len(enc)))
	}

	var b strings.Builder
	b.WriteString("// Generated by tools/casegen from UCD 17.0.0 — do not edit.\n")
	b.WriteString("// Full uppercase mappings (UnicodeData.txt Simple_Uppercase_Mapping +\n")
	b.WriteString("// SpecialCasing.txt unconditional entries). No context rules exist for\n")
	b.WriteString("// Unicode default uppercase.\n\n")
	writeVals := func(name, typ string, vals []string) {
		fmt.Fprintf(&b, "pub const %s = [_]%s{", name, typ)
		for i, v := range vals {
			if i%12 == 0 {
				b.WriteString("\n    ")
			}
			b.WriteString(v)
			if i != len(vals)-1 {
				b.WriteString(", ")
			}
		}
		b.WriteString("\n};\n\n")
	}
	writeVals("map_keys", "u32", keys)
	writeVals("map_packed", "u32", packed)
	blobVals := make([]string, len(blob))
	for i, v := range blob {
		blobVals[i] = fmt.Sprintf("0x%02X", v)
	}
	writeVals("map_blob", "u8", blobVals)

	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("wrote %s: %d mappings (%d blob bytes)\n", path, len(cps), len(blob))
}

func generateUppercase() int {
	m := loadSimpleUpper()
	applySpecialCasingUpper(m)
	emitUpperTablesZig(m, "../../compliance/unicode-17-uppercase-tables.zig")
	emitUpperTablesZig(m, "../../text/lib/unicode-17-uppercase-tables.zig")

	caser := cases.Upper(language.English)
	mismatches := 0
	newer := 0
	for cp := rune(0); cp <= 0x10FFFF; cp++ {
		if cp >= 0xD800 && cp <= 0xDFFF {
			continue
		}
		s := string(cp)
		want := caser.String(s)
		got := ourUpper(s, m)
		if want != got {
			if want == s && got != s {
				newer++
				continue
			}
			mismatches++
			if mismatches <= 20 {
				fmt.Printf("UPPER MISMATCH U+%04X: ours %q oracle %q\n", cp, got, want)
			}
		}
	}
	fmt.Printf("uppercase mappings newer than oracle: %d code points (UCD 17 wins); mismatches: %d\n", newer, mismatches)

	inputs := []struct{ name, in string }{
		{"empty", ""},
		{"ascii", "Hello, World! qip 123"},
		{"sharp-s", "straße ß groß ẞ"},
		{"ligatures", "ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ ǳ ǆ"},
		{"apostrophe-n", "ŉ"},
		{"greek-accents", "ΐ ΰ έξοχή σοφός ς σ"},
		{"ypogegrammeni", "ᾀ ᾷ ῃ ῴ ᾳ"},
		{"dotless-dotted-i", "i ı İ i̇"},
		{"titlecase-digraphs", "ǅungla ǈ ǋ"},
		{"cherokee-small", "ꭰꭱꭲ ᏣᎳᎩ"},
		{"deseret-plane1", "\U00010428\U00010429"},
		{"garay-unicode16", "\U00010D70\U00010D71"},
		{"mixed-scripts", "привет γεια hello мир"},
	}
	var zb strings.Builder
	zb.WriteString("// Generated by tools/casegen from UCD 17.0.0 — do not edit.\n")
	zb.WriteString("// Curated inputs for compliance/unicode-17-uppercase.comply.zig. Inputs\n")
	zb.WriteString("// only: expected outputs come from the component's embedded oracle.\n\n")
	zb.WriteString("pub const Case = struct {\n    name: []const u8,\n    input: []const u8,\n};\n\npub const cases = [_]Case{\n")
	for _, c := range inputs {
		fmt.Fprintf(&zb, "    .{ .name = \"%s\", .input = \"%s\" },\n", c.name, zigEscape([]byte(c.in)))
	}
	zb.WriteString("};\n")
	if err := os.WriteFile("../../compliance/unicode-17-uppercase-fixtures.zig", []byte(zb.String()), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("wrote ../../compliance/unicode-17-uppercase-fixtures.zig: %d curated inputs\n", len(inputs))
	return mismatches
}
