#!/bin/sh
# Pathological-input time budgets for the markdown components.
#
# Each case renders a generated adversarial input through the GFM component
# (the superset build of text/markdown/lib/commonmark.zig) under a
# hard `qip run --timeout-ms` budget. A trap or timeout fails the suite. This
# is the regression fence for inline/block parser performance work — in
# particular the planned delimiter-stack rewrite (see the TODO block in
# text/markdown/lib/commonmark.zig).
#
# Budgets are calibrated to measured 2026-08-17 behavior on an M-series
# laptop, roughly 3x the observed time, and fall into two groups:
#   - TIGHT cases: currently fast; a budget breach means a superlinear
#     regression crept in.
#   - KNOWN-SLOW cases: currently superlinear (emphasis lookahead, reference
#     definition collection, nested-list re-copying). Their budgets only stop
#     things getting worse. After the delimiter-stack rewrite and the
#     block-level fixes, tighten every KNOWN-SLOW budget to TIGHT levels —
#     these inputs should all render in well under a second.
#
# Usage: tools/test-markdown-pathological.sh (from the repo root)
# Env: QIP_BIN (default ./qip), WASM (default the GFM component)

set -eu

QIP_BIN="${QIP_BIN:-./qip}"
WASM="${WASM:-text/markdown/gfm-commonmark.0.31.2.wasm}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$WORK_DIR" <<'PY'
import sys
d = sys.argv[1]
def w(name, text):
    open(f"{d}/{name}.md", "w").write(text)

# TIGHT: currently fast paths.
w("backticks", "`a` " * 4000)
w("inline-links", "[a](/u) " * 4000)
w("strikethrough", "~~a~~ " * 4000)
w("ref-uses", "".join(f"[x{i}]: /u{i}\n" for i in range(100)) + "\n"
             + " ".join(f"[x{i % 100}]" for i in range(4000)))
w("deep-blockquote", "> " * 200 + "a\n")
w("many-paragraphs", "para text\n\n" * 4000)
# Extended autolinks are found from '@', ':' and '.', and each '_' asks
# whether an email runs through it; none of that may rescan a long run.
w("autolink-underscores", "_a" * 20000 + "@b\n\n\\-" + "_a" * 20000 + "@b.cc\n")
w("autolink-anchors", "a@ " * 5000 + "www. " * 5000 + "http:// " * 5000 + "+www." * 5000 + "@b\n")
# A '<' that opens nothing must fail where its text stops fitting a tag,
# autolink or comment, not after a search for a '>' that is far away or absent.
w("angle-brackets", "<" * 40000 + "\n\n" + "<a " * 20000 + ">\n\n" + "<a b='" * 10000 + "\n")
w("angle-unclosed", "<!-- a " * 10000 + "\n\n" + "<? a " * 10000 + "\n\n" + "<!a " * 10000
                    + "\n\n" + "<![CDATA[ " * 8000 + "\n")
# Lazy lines are joined to the item's paragraph one by one; neither the join
# nor the fence check before it may rescan the item.
w("lazy-lines", "- a\n" + "b\n" * 20000 + "\n- x\n  - a\n" + "  ===\n" * 20000
                + "\n- > a\n" + "===\n" * 20000)
w("fence-blanks", "- ```\n" + "\n" * 20000 + "  ```\n")
# KNOWN-SLOW: superlinear today, budgeted at current-or-better.
w("em-open", "*a " * 300)
w("em-nest", "*a **a " * 150)
w("ref-defs", "".join(f"[x{i}]: /u{i}\n" for i in range(1000)) + "\n[x1]")
w("nest-list", ("".join("  " * i + "- a\n" for i in range(200))) * 20)
PY

status=0
run_case() {
    name="$1"
    budget_ms="$2"
    start=$(date +%s)
    if ! "$QIP_BIN" run --timeout-ms "$budget_ms" -i "$WORK_DIR/$name.md" "$WASM" > /dev/null 2>&1; then
        echo "FAIL $name: trap or over ${budget_ms}ms budget"
        status=1
        return
    fi
    end=$(date +%s)
    echo "ok $name (budget ${budget_ms}ms, took <=$((end - start + 1))s)"
}

# TIGHT budgets. em-open/em-nest joined this group when the delimiter-stack
# rewrite landed (2026-08-18): both dropped from multi-second to ~50 ms.
run_case backticks 2000
run_case inline-links 2000
run_case strikethrough 2000
run_case ref-uses 2000
run_case deep-blockquote 2000
run_case many-paragraphs 4000
run_case autolink-underscores 2000
run_case autolink-anchors 2000
run_case angle-brackets 2000
run_case angle-unclosed 2000
run_case lazy-lines 2000
run_case fence-blanks 2000
run_case em-open 2000
run_case em-nest 2000
# KNOWN-SLOW budgets — block-level quadratics (reference-definition collection,
# nested-list re-copying); tighten with the line-classification rework.
run_case ref-defs 5000
run_case nest-list 25000

exit $status
