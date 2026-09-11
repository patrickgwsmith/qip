#!/usr/bin/env python3
"""Differential fuzzer: the CommonMark component vs the cmark reference binary.

Renders generated markdown through both text/markdown/
commonmark.0.31.2.wasm (via `qip run`) and `cmark --unsafe`, and reports every
byte-level divergence. cmark 0.31.2 implements exactly the spec revision the
component targets, so any divergence is a conformance finding — this is the
inventory step that precedes the delimiter-stack rewrite of
text/markdown/lib/commonmark.zig (see the TODO block there), and
the surviving corpus becomes that rewrite's acceptance test.

Inputs are ASCII-only by construction (invalid UTF-8 is deliberately out of
scope: cmark substitutes U+FFFD, the component passes bytes through, and that
known representational difference would drown real findings).

Seeds come from the spec-example inputs in
compliance/commonmark-spec-0.31.2.txt; mutations splice, perturb, and recombine
them alongside random markdown token soup.

Usage: tools/fuzz-markdown-vs-cmark.py [--n 1000] [--seed 1]
       [--out /tmp/markdown-fuzz-divergences]
Requires: ./qip, cmark 0.31.x on PATH.
Exit status is always 0 — this is an inventory tool, not a test gate.
"""

import argparse
import pathlib
import random
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WASM = ROOT / "text/markdown/commonmark.0.31.2.wasm"
SPEC = ROOT / "compliance/commonmark-spec-0.31.2.txt"
FENCE = "`" * 32

TOKENS = [
    "*", "**", "_", "__", "`", "``", "[", "]", "(", ")", "<", ">", "\\", "&",
    ";", "#", "##", ">", "-", "+", "1.", "2)", "~~~", "```", "===", "---",
    "a", "b", "foo", "bar", "x", " ", "  ", "\n", "\n\n", "\t",
    "*foo*", "**foo**", "[a](/u)", "[a]", "![a](/i)", "`code`", "&amp;",
    "&#35;", "<em>", "</em>", "<https://x.y>", '"title"', "[a]: /u",
    "    code", "> quote", "- item", "1. item",
]


def spec_inputs():
    text = SPEC.read_text()
    inputs = []
    pos = 0
    marker = FENCE + " example\n"
    while True:
        start = text.find(marker, pos)
        if start == -1:
            break
        body_start = start + len(marker)
        sep = text.find("\n.\n", body_start)
        close = text.find("\n" + FENCE + "\n", body_start)
        if sep == -1 or close == -1:
            break
        end = min(sep + 1, close + 1)
        inputs.append(text[body_start:end].replace("→", "\t"))
        pos = close + 1
    return [i for i in inputs if i.isascii()]


def generate(rng, seeds):
    kind = rng.randrange(6)
    if kind == 0:  # token soup
        return "".join(rng.choice(TOKENS) for _ in range(rng.randrange(4, 40)))
    if kind == 1:  # verbatim seed (sanity floor)
        return rng.choice(seeds)
    if kind == 2:  # splice two seeds
        a, b = rng.choice(seeds), rng.choice(seeds)
        return a[: rng.randrange(len(a) + 1)] + b[rng.randrange(len(b) + 1) :]
    if kind == 3:  # perturb a seed with token insertions/deletions
        s = list(rng.choice(seeds))
        for _ in range(rng.randrange(1, 5)):
            op = rng.randrange(3)
            pos = rng.randrange(len(s) + 1) if s else 0
            if op == 0:
                s.insert(pos, rng.choice(TOKENS))
            elif op == 1 and s:
                del s[min(pos, len(s) - 1)]
            elif s:
                s[min(pos, len(s) - 1)] = rng.choice(TOKENS)
        return "".join(s)
    if kind == 4:  # concatenate seeds into a multi-block document
        return "\n".join(rng.choice(seeds) for _ in range(rng.randrange(2, 5)))
    # emphasis/bracket stress: short strings from the trickiest alphabet
    return "".join(
        rng.choice(["*", "_", "`", "[", "]", "(", ")", "\\", "a", " ", "\n"])
        for _ in range(rng.randrange(3, 25))
    )


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out", default="/tmp/markdown-fuzz-divergences")
    args = parser.parse_args()

    seeds = spec_inputs()
    print(f"{len(seeds)} ASCII spec-example seeds")
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(args.seed)
    stats = {"match": 0, "diff": 0, "component_error": 0, "cmark_error": 0}
    diff_count = 0
    for i in range(args.n):
        text = generate(rng, seeds)
        expected = run_cmark(text)
        if expected is None:
            stats["cmark_error"] += 1
            continue
        actual = run_component(text)
        if actual is None:
            stats["component_error"] += 1
            (out_dir / f"error-{i:05d}.md").write_text(text)
            continue
        if actual == expected:
            stats["match"] += 1
        else:
            stats["diff"] += 1
            diff_count += 1
            (out_dir / f"diff-{i:05d}.md").write_text(text)
            (out_dir / f"diff-{i:05d}.cmark").write_bytes(expected)
            (out_dir / f"diff-{i:05d}.qip").write_bytes(actual)

    total = sum(stats.values())
    print(f"\n{total} cases (seed {args.seed}):")
    for key, count in stats.items():
        print(f"  {key}: {count} ({100.0 * count / total:.1f}%)")
    if diff_count:
        print(f"\ndivergent inputs + both outputs written to {out_dir}/")


if __name__ == "__main__":
    main()
