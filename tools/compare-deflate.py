#!/usr/bin/env python3
import argparse
import os
import pathlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import zlib
from dataclasses import dataclass


@dataclass
class Tool:
    name: str
    cmd: list[str]
    note: str = ""


def detect_format_and_decode(blob: bytes):
    # zlib wrapper
    try:
        return "zlib", zlib.decompress(blob)
    except Exception:
        pass

    # raw DEFLATE (e.g. Bun.deflateSync)
    try:
        return "raw-deflate", zlib.decompress(blob, -15)
    except Exception:
        pass

    # gzip wrapper
    try:
        return "gzip", zlib.decompress(blob, 16 + zlib.MAX_WBITS)
    except Exception:
        pass

    return "unknown", None


def run_tool(cmd: list[str], data: bytes, runs: int, warmup: int):
    durations = []
    first_out = None

    for _ in range(warmup):
        proc = subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip() or f"exit {proc.returncode}")

    for _ in range(runs):
        t0 = time.perf_counter_ns()
        proc = subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        t1 = time.perf_counter_ns()

        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip() or f"exit {proc.returncode}")

        out = proc.stdout
        if first_out is None:
            first_out = out
        elif out != first_out:
            raise RuntimeError("non-deterministic output across runs")

        durations.append((t1 - t0) / 1e9)

    return first_out, durations


def fmt_ratio(comp: int, raw: int) -> str:
    if raw == 0:
        return "n/a"
    return f"{comp / raw:.3f}"


def fmt_ms(sec: float) -> str:
    return f"{sec * 1000:.3f}"


def fmt_mibs(raw: int, sec: float) -> str:
    if sec <= 0:
        return "inf"
    return f"{(raw / (1024 * 1024)) / sec:.2f}"


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


def build_tools() -> tuple[list[Tool], list[str]]:
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
                tools.append(Tool(name=name, cmd=["./qip", "run", "-i", "-", module]))
            else:
                skipped.append(f"{name} (missing {module})")
    else:
        skipped.append("qip components (missing ./qip)")

    py = shutil.which("python3")
    if py:
        tools.append(Tool(
            name="python-zlib-6",
            cmd=[py, "-c", "import sys,zlib;sys.stdout.buffer.write(zlib.compress(sys.stdin.buffer.read(),6))"],
        ))
        tools.append(Tool(
            name="python-zlib-9",
            cmd=[py, "-c", "import sys,zlib;sys.stdout.buffer.write(zlib.compress(sys.stdin.buffer.read(),9))"],
        ))
    else:
        skipped.append("python3")

    try:
        go_helper = build_go_helper()
    except Exception as e:
        skipped.append(f"go-zlib helper build failed ({e})")
        go_helper = None

    if go_helper:
        tools.append(Tool(name="go-zlib-6", cmd=[go_helper, "-level", "6"]))
        tools.append(Tool(name="go-zlib-9", cmd=[go_helper, "-level", "9"]))
    else:
        skipped.append("go-zlib helper")

    bun = shutil.which("bun")
    if bun:
        tools.append(Tool(
            name="bun-deflate-default",
            cmd=[bun, "-e", "const input=new Uint8Array(await new Response(Bun.stdin.stream()).arrayBuffer());const out=Bun.deflateSync(input);await Bun.write(Bun.stdout,out);"] ,
            note="raw-deflate",
        ))
        tools.append(Tool(
            name="bun-deflate-9",
            cmd=[bun, "-e", "const input=new Uint8Array(await new Response(Bun.stdin.stream()).arrayBuffer());const out=Bun.deflateSync(input,{level:9});await Bun.write(Bun.stdout,out);"] ,
            note="raw-deflate",
        ))
    else:
        skipped.append("bun")

    zlib_flate = shutil.which("zlib-flate")
    if zlib_flate:
        tools.append(Tool(name="zlib-flate", cmd=[zlib_flate, "-compress"]))
    else:
        skipped.append("zlib-flate")

    return tools, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare deflate/zlib compression ratio and speed across tools.")
    parser.add_argument("inputs", nargs="+", help="Input files to compress")
    parser.add_argument("--runs", type=int, default=3, help="Measured runs per tool per input (default: 3)")
    parser.add_argument("--warmup", type=int, default=1, help="Warmup runs per tool per input, excluded from timing (default: 1)")
    args = parser.parse_args()

    tools, skipped = build_tools()
    if not tools:
        print("No tools available.", file=sys.stderr)
        return 1

    print(f"Tools: {', '.join(t.name for t in tools)}")
    if skipped:
        print("Skipped: " + ", ".join(skipped))

    for input_path in args.inputs:
        p = pathlib.Path(input_path)
        data = p.read_bytes()
        raw = len(data)
        print(f"\nInput: {p} ({raw} bytes)")
        print("| Tool | Format | Compressed | Ratio | Mean ms | MiB/s | Valid |")
        print("|---|---:|---:|---:|---:|---:|---:|")

        for tool in tools:
            try:
                out, durations = run_tool(tool.cmd, data, args.runs, args.warmup)
                comp = len(out)
                fmt, decoded = detect_format_and_decode(out)
                valid = decoded == data
                mean_sec = statistics.fmean(durations)
                print(
                    f"| {tool.name} | {fmt} | {comp} | {fmt_ratio(comp, raw)} | {fmt_ms(mean_sec)} | {fmt_mibs(raw, mean_sec)} | {'yes' if valid else 'no'} |"
                )
            except Exception as e:
                print(f"| {tool.name} | err | - | - | - | - | no ({str(e).replace('|', '/')}) |")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
