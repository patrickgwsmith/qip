#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/bench-qip-component-to-c-source.sh [options] source.zig|source.c

Options:
  -i, --input PATH          Input fixture (required)
  --wasm PATH               QIP Wasm artifact (default: source basename + .wasm)
  --duration-ms N           Warm measurement per implementation (default: 2000)
  --trials N                Warm trials to average (default: 3)
  --startup-runs N          Fresh processes per implementation (default: 100)
  --skip-build              Use existing qip, translator, and Wasm artifacts
  --keep-temp               Keep generated sources, binaries, and raw results
  -h, --help                Show this help

Zig sources must publish:

  pub const native_output_capacity: usize
  pub fn nativeRender(input: []const u8, output: []u8) u32

C sources must define these when QIP_NATIVE_BENCHMARK is defined:

  size_t qip_native_output_capacity(void);
  uint32_t qip_native_render(
      const uint8_t *, size_t, uint8_t *, size_t);

The normal source-to-Wasm build remains in the Makefile. Override CC, ZIG,
WASM2C, NODE, QIP_BIN, or WABT_ROOT through the environment when needed.
EOF
}

fail() {
  echo "bench-qip-component-to-c-source: $*" >&2
  exit 2
}

step() {
  echo "bench-qip-component-to-c-source: $*" >&2
}

input_path=
wasm_path=
duration_ms=2000
trials=3
startup_runs=100
skip_build=0
keep_temp=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      [[ $# -ge 2 ]] || fail "$1 requires a path"
      input_path=$2
      shift 2
      ;;
    --wasm)
      [[ $# -ge 2 ]] || fail "$1 requires a path"
      wasm_path=$2
      shift 2
      ;;
    --duration-ms)
      [[ $# -ge 2 ]] || fail "$1 requires a number"
      duration_ms=$2
      shift 2
      ;;
    --startup-runs)
      [[ $# -ge 2 ]] || fail "$1 requires a number"
      startup_runs=$2
      shift 2
      ;;
    --trials)
      [[ $# -ge 2 ]] || fail "$1 requires a number"
      trials=$2
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --keep-temp)
      keep_temp=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "${source_path:-}" ]] || fail "pass exactly one source path"
      source_path=$1
      shift 1
      ;;
  esac
done

[[ -n "${source_path:-}" ]] || fail "a source path is required"
[[ -n "$input_path" ]] || fail "--input is required"
[[ "$duration_ms" =~ ^[1-9][0-9]*$ ]] || fail "--duration-ms must be positive"
[[ "$trials" =~ ^[1-9][0-9]*$ ]] || fail "--trials must be positive"
[[ "$startup_runs" =~ ^[1-9][0-9]*$ ]] || fail "--startup-runs must be positive"

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
source_path=$(realpath "$source_path")
input_path=$(realpath "$input_path")
[[ -f "$source_path" ]] || fail "source does not exist: $source_path"
[[ -f "$input_path" ]] || fail "input does not exist: $input_path"

case "$source_path" in
  *.zig) source_kind=zig ;;
  *.c) source_kind=c ;;
  *) fail "source must end in .zig or .c" ;;
esac

if [[ -z "$wasm_path" ]]; then
  wasm_path=${source_path%.*}.wasm
fi
if [[ "$wasm_path" != /* ]]; then
  wasm_path="$repo_root/$wasm_path"
fi
case "$wasm_path" in
  "$repo_root"/*) wasm_target=${wasm_path#"$repo_root"/} ;;
  *)
    [[ "$skip_build" -eq 1 ]] ||
      fail "a Wasm artifact outside the repository requires --skip-build"
    wasm_target=$wasm_path
    ;;
esac

cc_bin=${CC:-cc}
zig_bin=${ZIG:-zig}
wasm2c_bin=${WASM2C:-wasm2c}
node_bin=${NODE:-node}
qip_bin=${QIP_BIN:-"$repo_root/qip"}
translator="$repo_root/application/wasm/qip-component-to-c.wasm"

for command in "$cc_bin" "$node_bin" "$wasm2c_bin"; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done
if [[ "$source_kind" == zig ]]; then
  command -v "$zig_bin" >/dev/null 2>&1 || fail "required command not found: $zig_bin"
fi

if [[ "$skip_build" -eq 0 ]]; then
  step "building QIP, translator, and $wasm_target"
  make -j qip application/wasm/qip-component-to-c.wasm \
    "$wasm_target" >&2
fi
[[ -x "$qip_bin" ]] || fail "QIP executable not found: $qip_bin"
[[ -f "$translator" ]] || fail "translator not found: $translator"
[[ -f "$wasm_path" ]] || fail "Wasm artifact not found: $wasm_path"

bench_tmp=$(mktemp -d "${TMPDIR:-/tmp}/qip-source-bench.XXXXXX")
cleanup() {
  if [[ "$keep_temp" -eq 1 ]]; then
    echo "bench-qip-component-to-c-source: kept $bench_tmp" >&2
  else
    rm -rf "$bench_tmp"
  fi
}
trap cleanup EXIT

native_fast_object="$bench_tmp/native-fast-api.o"
native_fast_warm="$bench_tmp/native-fast-warm"
native_fast_once="$bench_tmp/native-fast-once"
native_small_object="$bench_tmp/native-small-api.o"
native_small_warm="$bench_tmp/native-small-warm"
native_small_once="$bench_tmp/native-small-once"
generated_header="$bench_tmp/generated.h"
generated_warm="$bench_tmp/generated-warm"
generated_once="$bench_tmp/generated-once"
wasm2c_source="$bench_tmp/translated.c"
wasm2c_header="$bench_tmp/translated.h"
guard_warm="$bench_tmp/wasm2c-guard-warm"
guard_once="$bench_tmp/wasm2c-guard-once"
bounds_warm="$bench_tmp/wasm2c-bounds-warm"
bounds_once="$bench_tmp/wasm2c-bounds-once"
startup_tool="$bench_tmp/bench-process-startup"

if [[ "$(uname -s)" == Darwin ]]; then
  link_flags=(-Wl,-dead_strip)
else
  link_flags=(-Wl,--gc-sections)
fi

step "building direct native source"
if [[ "$source_kind" == zig ]]; then
  if ! "$zig_bin" build-obj \
      --cache-dir "$bench_tmp/zig-cache" \
      --global-cache-dir "$bench_tmp/zig-global-cache" \
      -O ReleaseFast -fstrip \
      --dep component \
      -Mroot="$repo_root/tools/bench-content-native-api.zig" \
      -O ReleaseFast \
      -Mcomponent="$source_path" \
      -femit-bin="$native_fast_object"; then
    fail "Zig source must provide native_output_capacity and nativeRender"
  fi
  "$zig_bin" build-obj \
    --cache-dir "$bench_tmp/zig-cache" \
    --global-cache-dir "$bench_tmp/zig-global-cache" \
    -O ReleaseSmall -fstrip \
    --dep component \
    -Mroot="$repo_root/tools/bench-content-native-api.zig" \
    -O ReleaseSmall \
    -Mcomponent="$source_path" \
    -femit-bin="$native_small_object"
  "$cc_bin" -std=c11 -O3 -DNDEBUG \
    "$repo_root/test/bench-content-native.c" "$native_fast_object" \
    -lm -o "$native_fast_warm"
  "$cc_bin" -std=c11 -O3 -DNDEBUG \
    "$repo_root/test/bench-content-native-once.c" "$native_fast_object" \
    "${link_flags[@]}" -lm -o "$native_fast_once"
  "$cc_bin" -std=c11 -Os -DNDEBUG \
    "$repo_root/test/bench-content-native.c" "$native_small_object" \
    -lm -o "$native_small_warm"
  "$cc_bin" -std=c11 -Os -DNDEBUG \
    "$repo_root/test/bench-content-native-once.c" "$native_small_object" \
    "${link_flags[@]}" -lm -o "$native_small_once"
else
  if ! "$cc_bin" -std=c11 -O3 -DNDEBUG -DQIP_NATIVE_BENCHMARK \
      "$repo_root/test/bench-content-native.c" "$source_path" \
      -lm -o "$native_fast_warm"; then
    fail "C source must provide qip_native_output_capacity and qip_native_render under QIP_NATIVE_BENCHMARK"
  fi
  "$cc_bin" -std=c11 -O3 -DNDEBUG -DQIP_NATIVE_BENCHMARK \
    "$repo_root/test/bench-content-native-once.c" "$source_path" \
    "${link_flags[@]}" -lm -o "$native_fast_once"
  "$cc_bin" -std=c11 -Os -DNDEBUG -DQIP_NATIVE_BENCHMARK \
    "$repo_root/test/bench-content-native.c" "$source_path" \
    -lm -o "$native_small_warm"
  "$cc_bin" -std=c11 -Os -DNDEBUG -DQIP_NATIVE_BENCHMARK \
    "$repo_root/test/bench-content-native-once.c" "$source_path" \
    "${link_flags[@]}" -lm -o "$native_small_once"
fi

step "translating Wasm with QIP"
"$qip_bin" run -i "$wasm_path" -o "$generated_header" "$translator"
"$cc_bin" -std=c11 -O3 -DNDEBUG \
  -DQIP_WASM_GENERATED_HEADER="\"$generated_header\"" \
  "$repo_root/test/bench-content-c.c" -lm -o "$generated_warm"
"$cc_bin" -std=c11 -O3 -DNDEBUG \
  -DQIP_WASM_GENERATED_HEADER="\"$generated_header\"" \
  "$repo_root/test/bench-content-c-once.c" \
  "${link_flags[@]}" -lm -o "$generated_once"

if [[ -n "${WABT_ROOT:-}" ]]; then
  wabt_root=$WABT_ROOT
else
  wasm2c_resolved=$(realpath "$(command -v "$wasm2c_bin")")
  wabt_root=$(cd "$(dirname "$wasm2c_resolved")/.." && pwd)
fi
wabt_include="$wabt_root/include"
wabt_runtime="$wabt_root/share/wabt/wasm2c"
[[ -f "$wabt_include/wasm-rt.h" ]] ||
  fail "cannot find wasm-rt.h; set WABT_ROOT"
[[ -f "$wabt_runtime/wasm-rt-impl.c" ]] ||
  fail "cannot find WABT wasm2c runtime sources; set WABT_ROOT"

step "translating Wasm with WABT wasm2c"
"$wasm2c_bin" -n qipbench "$wasm_path" -o "$wasm2c_source"

compile_wasm2c() {
  local mode=$1
  local warm_output=$2
  local once_output=$3
  local -a mode_flags=()
  if [[ "$mode" == bounds ]]; then
    mode_flags=(-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1)
  fi
  "$cc_bin" -std=c11 -O3 -DNDEBUG \
    "${mode_flags[@]}" \
    -I"$wabt_include" -I"$wabt_runtime" \
    -DWASM2C_GENERATED_HEADER="\"$wasm2c_header\"" \
    "$repo_root/test/bench-content-wasm2c.c" \
    "$wasm2c_source" \
    "$wabt_runtime/wasm-rt-impl.c" \
    "$wabt_runtime/wasm-rt-mem-impl.c" \
    -lm -o "$warm_output"
  "$cc_bin" -std=c11 -O3 -DNDEBUG \
    "${mode_flags[@]}" \
    -I"$wabt_include" -I"$wabt_runtime" \
    -DWASM2C_GENERATED_HEADER="\"$wasm2c_header\"" \
    "$repo_root/test/bench-content-wasm2c-once.c" \
    "$wasm2c_source" \
    "$wabt_runtime/wasm-rt-impl.c" \
    "$wabt_runtime/wasm-rt-mem-impl.c" \
    "${link_flags[@]}" -lm -o "$once_output"
}

compile_wasm2c guard "$guard_warm" "$guard_once"
compile_wasm2c bounds "$bounds_warm" "$bounds_once"

"$cc_bin" -std=c11 -O3 -DNDEBUG \
  "$repo_root/tools/bench-process-startup.c" -o "$startup_tool"

strip_binary() {
  if [[ "$(uname -s)" == Darwin ]]; then
    strip -x "$1"
  else
    strip "$1"
  fi
}
for binary in \
  "$native_fast_once" "$native_small_once" \
  "$generated_once" "$guard_once" "$bounds_once"; do
  strip_binary "$binary"
done

step "running warmed benchmarks serially"
for ((trial = 1; trial <= trials; trial += 1)); do
  step "warm trial $trial/$trials"
  "$native_fast_warm" "$input_path" "$duration_ms" "$bench_tmp/native-fast-output" \
    >"$bench_tmp/native-fast-warm-$trial.json"
  "$native_small_warm" "$input_path" "$duration_ms" "$bench_tmp/native-small-output" \
    >"$bench_tmp/native-small-warm-$trial.json"
  "$generated_warm" "$input_path" "$duration_ms" "$bench_tmp/generated-output" \
    >"$bench_tmp/generated-warm-$trial.json"
  "$guard_warm" "$input_path" "$duration_ms" "$bench_tmp/guard-output" \
    >"$bench_tmp/guard-warm-$trial.json"
  "$bounds_warm" "$input_path" "$duration_ms" "$bench_tmp/bounds-output" \
    >"$bench_tmp/bounds-warm-$trial.json"
  "$node_bin" "$repo_root/tools/bench-content-node.mjs" \
    "$wasm_path" "$input_path" "$duration_ms" "$bench_tmp/node-output" \
    >"$bench_tmp/node-warm-$trial.json"
  "$qip_bin" bench -i "$input_path" --benchtime="${duration_ms}ms" "$wasm_path" \
    >"$bench_tmp/qip-warm-$trial.txt"
done
"$qip_bin" run -i "$input_path" -o "$bench_tmp/qip-output" "$wasm_path"

for output in native-small generated guard bounds node qip; do
  cmp "$bench_tmp/native-fast-output" "$bench_tmp/$output-output" ||
    fail "$output output differs from direct native output"
done

step "measuring fresh-process startup"
"$startup_tool" "$startup_runs" "$input_path" "$native_fast_once" \
  >"$bench_tmp/native-fast-startup.json"
"$startup_tool" "$startup_runs" "$input_path" "$native_small_once" \
  >"$bench_tmp/native-small-startup.json"
"$startup_tool" "$startup_runs" "$input_path" "$generated_once" \
  >"$bench_tmp/generated-startup.json"
"$startup_tool" "$startup_runs" "$input_path" "$guard_once" \
  >"$bench_tmp/guard-startup.json"
"$startup_tool" "$startup_runs" "$input_path" "$bounds_once" \
  >"$bench_tmp/bounds-startup.json"
"$startup_tool" "$startup_runs" "$input_path" "$node_bin" \
  "$repo_root/tools/bench-content-node-once.mjs" "$wasm_path" \
  >"$bench_tmp/node-startup.json"
"$startup_tool" "$startup_runs" "$input_path" "$qip_bin" \
  run -i "$input_path" -o - "$wasm_path" \
  >"$bench_tmp/qip-startup.json"

step "formatting comparison"
export CC="$cc_bin" ZIG="$zig_bin" WASM2C="$wasm2c_bin"
"$node_bin" "$repo_root/tools/format-qip-component-to-c-source-bench.mjs" \
  "$bench_tmp" "$trials" "$source_path" "$wasm_path" "$input_path" \
  "$native_fast_once" "$native_small_once" \
  "$generated_once" "$guard_once" "$bounds_once" \
  "$qip_bin" "$(command -v "$node_bin")"
