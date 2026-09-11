#!/usr/bin/env python3
"""Freezes cmark-vs-component divergences into a compliance fixture.

Reads a divergence directory produced by tools/fuzz-markdown-vs-cmark.py,
greedily minimizes each input while the byte-level divergence persists,
deduplicates, and writes compliance/commonmark-differential-corpus.txt in the
spec-example fixture format (32-backtick fences, input, ".", cmark's output as
the expected HTML). compliance/commonmark-differential-corpus.comply.zig embeds
the fixture as an executable spec.

The corpus captures inputs where the component currently DISAGREES with cmark
0.31.2, so the checker is expected to fail until the delimiter-stack rewrite
(see the TODO block in text/markdown/lib/commonmark.zig) makes it
pass — it is that rewrite's acceptance gate, and joins test-comply once green.

Cases are dropped (with a note) if they cannot be represented in the fixture
format: an input line of 32+ backticks or a bare "." line would break the
fence/separator markers, and every input must stay divergent after a trailing
newline is ensured.

Regeneration MERGES: existing fixture entries are preserved (they are
regression pins, kept whether or not the component currently passes them, as
long as cmark still produces the recorded output), new divergences from the
input directory are minimized and appended, and --pin FILE adds an input
verbatim with cmark's current output (use it to pin fixed bugs found outside
a divergence run).

Usage: tools/freeze-markdown-divergences.py [--in DIR] [--pin FILE ...]
Requires: ./qip, cmark 0.31.x on PATH.
"""

import argparse
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
WASM = ROOT / "text/markdown/commonmark.0.31.2.wasm"
FIXTURE = ROOT / "compliance/commonmark-differential-corpus.txt"
FENCE = "`" * 32


def run_component(text):
    proc = subprocess.run(
        [str(ROOT / "qip"), "run", "--timeout-ms", "3000", str(WASM)],
        input=text.encode(),
        capture_output=True,
        cwd=ROOT,
    )
    if proc.returncode != 0:
        return None
    # `qip run` appends one newline of its own after the component output.
    return proc.stdout[:-1] if proc.stdout.endswith(b"\n") else proc.stdout


def run_cmark(text):
    proc = subprocess.run(
        ["cmark", "--unsafe"], input=text.encode(), capture_output=True
    )
    return proc.stdout if proc.returncode == 0 else None


def diverges(text):
    expected = run_cmark(text)
    if expected is None:
        return False
    return run_component(text) != expected


def minimize(text):
    """Greedy chunk removal at shrinking granularity, lines first then chars."""
    lines = text.split("\n")
    chunk = max(1, len(lines) // 2)
    while chunk >= 1:
        i = 0
        while i < len(lines):
            candidate_lines = lines[:i] + lines[i + chunk :]
            candidate = "\n".join(candidate_lines)
            if candidate.strip() and diverges(candidate):
                lines = candidate_lines
            else:
                i += chunk
        chunk //= 2
    text = "\n".join(lines)
    chunk = max(1, len(text) // 2)
    while chunk >= 1:
        i = 0
        while i < len(text):
            candidate = text[:i] + text[i + chunk :]
            if candidate.strip() and diverges(candidate):
                text = candidate
            else:
                i += chunk
        chunk //= 2
    return text


def representable(text):
    for line in text.split("\n"):
        if line.startswith(FENCE):
            return False
        if line == ".":
            return False
    return True


def existing_entries():
    if not FIXTURE.exists():
        return {}
    text = FIXTURE.read_text()
    entries = {}
    pos = 0
    marker = FENCE + " example\n"
    while True:
        start = text.find(marker, pos)
        if start == -1:
            break
        body = start + len(marker)
        if text.startswith(".\n", body):
            inp, exp_start = "", body + 2
        else:
            sep = text.find("\n.\n", body)
            inp, exp_start = text[body : sep + 1], sep + 3
        close = text.find("\n" + FENCE + "\n", exp_start - 1)
        entries[inp] = text[exp_start : close + 1]
        pos = close + 1
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="in_dir", default="/tmp/markdown-fuzz-divergences")
    parser.add_argument("--pin", action="append", default=[])
    args = parser.parse_args()

    corpus = {}
    stale = 0
    for inp, exp in existing_entries().items():
        current = run_cmark(inp)
        if current is not None and current.decode() == exp:
            corpus[inp] = exp
        else:
            stale += 1
    print(f"kept {len(corpus)} existing entries ({stale} stale vs current cmark)")

    for pin_path in args.pin:
        text = pathlib.Path(pin_path).read_text()
        if not text.endswith("\n"):
            text += "\n"
        if not representable(text):
            print(f"  pin {pin_path}: not representable, skipped")
            continue
        expected = run_cmark(text)
        if expected is None:
            print(f"  pin {pin_path}: cmark error, skipped")
            continue
        if run_component(text) != expected:
            print(f"  pin {pin_path}: NOTE — component currently diverges; pinning cmark's output")
        corpus[text] = expected.decode()
        print(f"  pinned {pin_path} ({len(text)} bytes)")

    in_dir = pathlib.Path(args.in_dir)
    sources = sorted(in_dir.glob("diff-*.md")) + sorted(in_dir.glob("error-*.md")) if in_dir.is_dir() else []
    print(f"{len(sources)} divergent inputs from {in_dir}")

    dropped = 0
    for idx, path in enumerate(sources):
        text = path.read_text()
        if text in corpus:
            continue
        if not diverges(text):
            dropped += 1  # stale relative to current component build
            continue
        text = minimize(text)
        if not text.endswith("\n"):
            text += "\n"
            if not diverges(text):
                dropped += 1
                continue
        if not representable(text):
            dropped += 1
            continue
        expected = run_cmark(text).decode()
        corpus[text] = expected
        print(f"  [{idx + 1}/{len(sources)}] minimized to {len(text)} bytes", flush=True)

    entries = sorted(corpus.items())
    with open(FIXTURE, "w") as f:
        f.write(
            "Differential corpus: inputs where the markdown component's output has\n"
            "diverged from the cmark 0.31.2 reference implementation, minimized and\n"
            "frozen by tools/freeze-markdown-divergences.py from a\n"
            "tools/fuzz-markdown-vs-cmark.py run. Expected HTML is cmark's output\n"
            "(`cmark --unsafe`), which for CommonMark 0.31.2 is the authoritative\n"
            "reading of the spec. Same example format as commonmark-spec-0.31.2.txt,\n"
            "except tabs are literal bytes (no arrow substitution).\n\n"
        )
        for text, expected in entries:
            f.write(FENCE + " example\n")
            f.write(text)
            f.write(".\n")
            f.write(expected)
            f.write(FENCE + "\n\n")
    print(f"\nwrote {FIXTURE.relative_to(ROOT)}: {len(entries)} unique cases "
          f"({dropped} dropped as stale/unrepresentable)")


if __name__ == "__main__":
    main()
