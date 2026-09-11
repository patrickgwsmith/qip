#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time
import zlib
from dataclasses import dataclass


@dataclass
class Tool:
    name: str
    bench_cmd_template: str
    ratio_cmd_template: str


@dataclass
class RatioResult:
    fmt: str
    compressed: int
    valid: bool
    error: str


def build_go_helper() -> str | None:
    go = shutil.which("go")
    if not go:
        return None

    src = pathlib.Path("tools/zlib-go-compress.go")
    if not src.exists():
        return None

    out = pathlib.Path(tempfile.gettempdir()) / "qip-zlib-go-compress"
    proc = subprocess.run(
        [go, "build", "-trimpath", "-ldflags=-s -w", "-o", str(out), str(src)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "GOCACHE": os.environ.get("GOCACHE", "/tmp/go-build")},
    )
    if proc.returncode != 0:
        raise RuntimeError("failed to build go helper: " + proc.stderr.decode("utf-8", errors="replace"))
    return str(out)


def discover_tools() -> tuple[list[Tool], list[str]]:
    tools: list[Tool] = []
    skipped: list[str] = []

    qip = pathlib.Path("./qip")
    if qip.exists():
        for name, module in [
            ("qip-zlib-stored", "bytes/zlib-compress.wasm"),
            ("qip-zlib-fixed", "bytes/zlib-compress-fixed-huffman.wasm"),
            ("qip-zlib-dynamic", "bytes/zlib-compress-dynamic-huffman.wasm"),
            ("qip-zlib-dynamic-opt", "bytes/zlib-compress-dynamic-huffman-opt.wasm"),
        ]:
            if pathlib.Path(module).exists():
                tools.append(
                    Tool(
                        name=name,
                        bench_cmd_template=f"./qip bench -i __INPUT__ -r __ITERS__ {shlex.quote(module)} > /dev/null",
                        ratio_cmd_template=f"./qip run -i __INPUT__ {shlex.quote(module)}",
                    )
                )
            else:
                skipped.append(f"{name} (missing {module})")
    else:
        skipped.append("qip (missing ./qip)")

    py = shutil.which("python3")
    if py:
        py_bench_code = (
            "import pathlib,sys,zlib\n"
            "data=pathlib.Path(sys.argv[1]).read_bytes()\n"
            "n=int(sys.argv[2])\n"
            "out=b''\n"
            "for _ in range(n):\n"
            "    out=zlib.compress(data,9)\n"
            "sys.stdout.buffer.write(out)\n"
        )
        py_ratio_code = (
            "import pathlib,sys,zlib\n"
            "data=pathlib.Path(sys.argv[1]).read_bytes()\n"
            "sys.stdout.buffer.write(zlib.compress(data,9))\n"
        )
        tools.append(
            Tool(
                name="python-zlib-9",
                bench_cmd_template=f"{shlex.quote(py)} -c {shlex.quote(py_bench_code)} __INPUT__ __ITERS__ > /dev/null",
                ratio_cmd_template=f"{shlex.quote(py)} -c {shlex.quote(py_ratio_code)} __INPUT__",
            )
        )
    else:
        skipped.append("python3")

    try:
        go_helper = build_go_helper()
    except Exception as e:
        go_helper = None
        skipped.append(f"go-zlib-9 helper build failed ({e})")

    if go_helper:
        tools.append(
            Tool(
                name="go-zlib-9",
                bench_cmd_template=f"{shlex.quote(go_helper)} -level 9 -file __INPUT__ -iters __ITERS__ > /dev/null",
                ratio_cmd_template=f"{shlex.quote(go_helper)} -level 9 -file __INPUT__ -iters 1",
            )
        )

    bun = shutil.which("bun")
    if bun:
        bun_bench_code = (
            "const input=new Uint8Array(await Bun.file(process.argv[1]).arrayBuffer());"
            "const n=Number(process.argv[2]);"
            "let out=new Uint8Array();"
            "for(let i=0;i<n;i++) out=Bun.deflateSync(input,{level:9});"
            "await Bun.write(Bun.stdout,out);"
        )
        bun_ratio_code = (
            "const input=new Uint8Array(await Bun.file(process.argv[1]).arrayBuffer());"
            "const out=Bun.deflateSync(input,{level:9});"
            "await Bun.write(Bun.stdout,out);"
        )
        tools.append(
            Tool(
                name="bun-deflate-9",
                bench_cmd_template=f"{shlex.quote(bun)} -e {shlex.quote(bun_bench_code)} __INPUT__ __ITERS__ > /dev/null",
                ratio_cmd_template=f"{shlex.quote(bun)} -e {shlex.quote(bun_ratio_code)} __INPUT__",
            )
        )
    else:
        skipped.append("bun")

    zlib_flate = shutil.which("zlib-flate")
    if zlib_flate:
        tools.append(
            Tool(
                name="zlib-flate",
                bench_cmd_template=f"for i in $(seq 1 __ITERS__); do {shlex.quote(zlib_flate)} -compress < __INPUT__ > /dev/null; done",
                ratio_cmd_template=f"{shlex.quote(zlib_flate)} -compress < __INPUT__",
            )
        )
    else:
        skipped.append("zlib-flate")

    return tools, skipped


def expand_cmd(template: str, input_path: pathlib.Path, inner_iters: int) -> str:
    return template.replace("__INPUT__", shlex.quote(str(input_path))).replace("__ITERS__", str(inner_iters))


def run_cmd_capture_stdout(cmd: str) -> bytes:
    p = subprocess.run(["/bin/sh", "-lc", cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", errors="replace").strip() or f"exit {p.returncode}")
    return p.stdout


def detect_format_and_decode(blob: bytes) -> tuple[str, bytes | None]:
    try:
        return "zlib", zlib.decompress(blob)
    except Exception:
        pass

    try:
        return "raw-deflate", zlib.decompress(blob, -15)
    except Exception:
        pass

    try:
        return "gzip", zlib.decompress(blob, 16 + zlib.MAX_WBITS)
    except Exception:
        pass

    return "unknown", None


def evaluate_ratio_output(blob: bytes, raw_data: bytes) -> RatioResult:
    fmt, decoded = detect_format_and_decode(blob)
    if decoded is None:
        return RatioResult(fmt=fmt, compressed=len(blob), valid=False, error="decompression failed")
    if decoded != raw_data:
        return RatioResult(fmt=fmt, compressed=len(blob), valid=False, error="roundtrip mismatch")
    return RatioResult(fmt=fmt, compressed=len(blob), valid=True, error="")


def run_python_bench(cmd: str, warmup: int, runs: int) -> float:
    for _ in range(warmup):
        p = subprocess.run(["/bin/sh", "-lc", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.decode("utf-8", errors="replace").strip() or f"exit {p.returncode}")

    durations = []
    for _ in range(runs):
        t0 = time.perf_counter_ns()
        p = subprocess.run(["/bin/sh", "-lc", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        t1 = time.perf_counter_ns()
        if p.returncode != 0:
            raise RuntimeError(p.stderr.decode("utf-8", errors="replace").strip() or f"exit {p.returncode}")
        durations.append((t1 - t0) / 1e9)

    return statistics.fmean(durations)


def run_hyperfine(cmd: str, warmup: int, runs: int) -> float:
    hyperfine = shutil.which("hyperfine")
    if not hyperfine:
        raise RuntimeError("hyperfine not found in PATH")

    fd, json_path = tempfile.mkstemp(prefix="qip-hf-", suffix=".json")
    os.close(fd)
    try:
        p = subprocess.run(
            [
                hyperfine,
                "--warmup",
                str(warmup),
                "--runs",
                str(runs),
                "--export-json",
                json_path,
                cmd,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if p.returncode != 0:
            raise RuntimeError(p.stderr.decode("utf-8", errors="replace").strip() or f"exit {p.returncode}")

        payload = json.loads(pathlib.Path(json_path).read_text())
        results = payload.get("results", [])
        if not results:
            raise RuntimeError("no results from hyperfine")
        return float(results[0]["mean"])
    finally:
        pathlib.Path(json_path).unlink(missing_ok=True)


def fmt_ratio(result: RatioResult, raw_size: int) -> str:
    if raw_size == 0:
        return "n/a"
    if result.compressed == 0 and not result.valid:
        return "n/a"
    return f"{result.compressed / raw_size:.3f}"


def sanitize_error(error: str) -> str:
    return error.replace("|", "/").replace("\n", " ").strip()


def ordered_tools_for_table(
    means_per_iter: dict[str, float | None],
    ratio_results: dict[str, RatioResult],
) -> list[str]:
    valid_timed = [
        name for name, mean in means_per_iter.items() if mean is not None and ratio_results.get(name, RatioResult("err", 0, False, "missing")).valid
    ]
    invalid_timed = [
        name for name, mean in means_per_iter.items() if mean is not None and not ratio_results.get(name, RatioResult("err", 0, False, "missing")).valid
    ]
    no_timing = [name for name, mean in means_per_iter.items() if mean is None]

    valid_timed.sort(key=lambda name: means_per_iter[name])
    invalid_timed.sort(key=lambda name: means_per_iter[name])
    no_timing.sort()

    return valid_timed + invalid_timed + no_timing


def print_rankings(
    title: str,
    means_per_iter: dict[str, float | None],
    ratio_results: dict[str, RatioResult],
    raw_size: int,
    timing_errors: dict[str, str],
) -> None:
    ordered = ordered_tools_for_table(means_per_iter, ratio_results)

    print(title)
    print("| Rank | Tool | Format | Compressed | Ratio | Valid | Mean ms/op |")
    print("|---:|---|---|---:|---:|---:|---:|")

    rank = 0
    for name in ordered:
        mean = means_per_iter[name]
        ratio_result = ratio_results.get(name, RatioResult("err", 0, False, "missing ratio result"))

        if mean is not None:
            rank += 1
            rank_str = str(rank)
            mean_str = f"{mean * 1000:.3f}"
        else:
            rank_str = "-"
            mean_str = "ERR"

        valid_str = "yes" if ratio_result.valid else "no"
        compressed_str = str(ratio_result.compressed)
        ratio_str = fmt_ratio(ratio_result, raw_size)
        fmt_str = ratio_result.fmt

        print(f"| {rank_str} | {name} | {fmt_str} | {compressed_str} | {ratio_str} | {valid_str} | {mean_str} |")

    failures = []
    for name in ordered:
        ratio_result = ratio_results.get(name)
        if ratio_result and not ratio_result.valid:
            failures.append(f"{name}: invalid output ({sanitize_error(ratio_result.error)})")
        if name in timing_errors:
            failures.append(f"{name}: benchmark failed ({sanitize_error(timing_errors[name])})")

    if failures:
        print("Failures")
        for line in failures:
            print(f"- {line}")


def ordered_valid_for_agreement(
    means_per_iter: dict[str, float | None],
    ratio_results: dict[str, RatioResult],
) -> list[str]:
    valid_names = [
        name
        for name, mean in means_per_iter.items()
        if mean is not None and ratio_results.get(name, RatioResult("err", 0, False, "missing")).valid
    ]
    valid_names.sort(key=lambda name: means_per_iter[name])
    return valid_names


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark compression speed with repeated in-launch iterations.")
    parser.add_argument("inputs", nargs="+", help="Input files")
    parser.add_argument("--runs", type=int, default=5, help="Measured runs per tool (default: 5)")
    parser.add_argument("--warmup", type=int, default=1, help="Warmup runs per tool (default: 1)")
    parser.add_argument("--inner-iters", type=int, default=25, help="Compression iterations per launch (default: 25)")
    parser.add_argument("--skip-hyperfine", action="store_true", help="Only run Python timer")
    args = parser.parse_args()

    if args.inner_iters < 1:
        raise SystemExit("--inner-iters must be >= 1")

    tools, skipped = discover_tools()
    if not tools:
        print("No tools available.")
        return 1

    print("Tools:", ", ".join(t.name for t in tools))
    print(f"Mode: {args.inner_iters} compression iterations per launch")
    if skipped:
        print("Skipped:", ", ".join(skipped))

    for input_name in args.inputs:
        input_path = pathlib.Path(input_name)
        raw_data = input_path.read_bytes()
        raw_size = len(raw_data)
        print(f"\nInput: {input_path} ({raw_size} bytes)")

        ratio_results: dict[str, RatioResult] = {}
        for tool in tools:
            ratio_cmd = expand_cmd(tool.ratio_cmd_template, input_path, 1)
            try:
                out = run_cmd_capture_stdout(ratio_cmd)
                ratio_results[tool.name] = evaluate_ratio_output(out, raw_data)
            except Exception as e:
                ratio_results[tool.name] = RatioResult(
                    fmt="err",
                    compressed=0,
                    valid=False,
                    error=f"ratio command failed: {sanitize_error(str(e))}",
                )

        py_means: dict[str, float | None] = {}
        py_timing_errors: dict[str, str] = {}
        expanded_cmds: dict[str, str] = {}

        for tool in tools:
            bench_cmd = expand_cmd(tool.bench_cmd_template, input_path, args.inner_iters)
            expanded_cmds[tool.name] = bench_cmd
            try:
                launch_mean = run_python_bench(bench_cmd, args.warmup, args.runs)
                py_means[tool.name] = launch_mean / args.inner_iters
            except Exception as e:
                py_means[tool.name] = None
                py_timing_errors[tool.name] = str(e)

        print_rankings("Python timing", py_means, ratio_results, raw_size, py_timing_errors)

        if args.skip_hyperfine:
            continue

        hf_means: dict[str, float | None] = {}
        hf_timing_errors: dict[str, str] = {}
        for tool in tools:
            cmd = expanded_cmds[tool.name]
            try:
                launch_mean = run_hyperfine(cmd, args.warmup, args.runs)
                hf_means[tool.name] = launch_mean / args.inner_iters
            except Exception as e:
                hf_means[tool.name] = None
                hf_timing_errors[tool.name] = str(e)

        print_rankings("Hyperfine", hf_means, ratio_results, raw_size, hf_timing_errors)

        py_order = ordered_valid_for_agreement(py_means, ratio_results)
        hf_order = ordered_valid_for_agreement(hf_means, ratio_results)

        print("Agreement")
        if not py_order or not hf_order:
            print("- Fastest: n/a (no valid timed contenders in one or both runners)")
            print("- Slowest: n/a (no valid timed contenders in one or both runners)")
            continue

        py_fast, py_slow = py_order[0], py_order[-1]
        hf_fast, hf_slow = hf_order[0], hf_order[-1]

        print(f"- Fastest: python={py_fast}, hyperfine={hf_fast}, match={'yes' if py_fast == hf_fast else 'no'}")
        print(f"- Slowest: python={py_slow}, hyperfine={hf_slow}, match={'yes' if py_slow == hf_slow else 'no'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
