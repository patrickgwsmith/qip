#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/bench-qip-component-to-c-recipe.sh [options] module.wasm module.wasm [...]

Options:
  -i, --input PATH          Input fixture (required)
  --duration-ms N           Warm measurement per implementation (default: 2000)
  --trials N                Warm trials to average (default: 3)
  --warmup N                Untimed recipes before each measurement (default: 3)
  --skip-build              Use existing qip, translator, and Wasm artifacts
  --keep-temp               Keep generated sources, binaries, and raw results
  -h, --help                Show this help

The first version accepts two or more Content component paths without uniform
arguments. It validates the pipeline through `qip dry run`, renders a canonical
output through `qip run`, and compares:

  QIP-generated C with one shared workspace
  QIP-generated C with one workspace per component
  WABT wasm2c with guard pages and explicit bounds checks
  Node.js/V8 with one reused instance per component
  QIP's wazero runtime with one reused instance per component

Override CC, WASM2C, NODE, QIP_BIN, or WABT_ROOT through the environment.
EOF
}

fail() {
  echo "bench-qip-component-to-c-recipe: $*" >&2
  exit 2
}

step() {
  echo "bench-qip-component-to-c-recipe: $*" >&2
}

input_path=
duration_ms=2000
trials=3
warmup=3
skip_build=0
keep_temp=0
recipe_modules=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      [[ $# -ge 2 ]] || fail "$1 requires a path"
      input_path=$2
      shift 2
      ;;
    --duration-ms)
      [[ $# -ge 2 ]] || fail "$1 requires a number"
      duration_ms=$2
      shift 2
      ;;
    --trials)
      [[ $# -ge 2 ]] || fail "$1 requires a number"
      trials=$2
      shift 2
      ;;
    --warmup)
      [[ $# -ge 2 ]] || fail "$1 requires a number"
      warmup=$2
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
    --)
      shift
      while [[ $# -gt 0 ]]; do
        recipe_modules+=("$1")
        shift
      done
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      recipe_modules+=("$1")
      shift
      ;;
  esac
done

[[ -n "$input_path" ]] || fail "--input is required"
[[ "${#recipe_modules[@]}" -ge 2 ]] ||
  fail "pass at least two Content component paths"
[[ "$duration_ms" =~ ^[1-9][0-9]*$ ]] ||
  fail "--duration-ms must be positive"
[[ "$trials" =~ ^[1-9][0-9]*$ ]] || fail "--trials must be positive"
[[ "$warmup" =~ ^[1-9][0-9]*$ ]] || fail "--warmup must be positive"

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
input_path=$(realpath "$input_path")
[[ -f "$input_path" ]] || fail "input does not exist: $input_path"

module_targets=()
module_paths=()
for module_path in "${recipe_modules[@]}"; do
  [[ "$module_path" != \?* ]] ||
    fail "uniform arguments are not supported yet: $module_path"
  if [[ "$module_path" != /* ]]; then
    module_target=$module_path
    module_path="$repo_root/$module_path"
  else
    case "$module_path" in
      "$repo_root"/*) module_target=${module_path#"$repo_root"/} ;;
      *)
        [[ "$skip_build" -eq 1 ]] ||
          fail "a module outside the repository requires --skip-build"
        module_target=$module_path
        ;;
    esac
  fi
  [[ "$module_path" == *.wasm ]] || fail "component must end in .wasm: $module_path"
  module_targets+=("$module_target")
  module_paths+=("$module_path")
done

cc_bin=${CC:-cc}
wasm2c_bin=${WASM2C:-wasm2c}
node_bin=${NODE:-node}
qip_bin=${QIP_BIN:-"$repo_root/qip"}
translator="$repo_root/application/wasm/qip-component-to-c.wasm"

for command in "$cc_bin" "$wasm2c_bin" "$node_bin" go; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "required command not found: $command"
done

if [[ "$skip_build" -eq 0 ]]; then
  step "building QIP, translator, and ${#module_targets[@]} components"
  make -j qip application/wasm/qip-component-to-c.wasm \
    "${module_targets[@]}" >&2
fi
[[ -x "$qip_bin" ]] || fail "QIP executable not found: $qip_bin"
[[ -f "$translator" ]] || fail "translator not found: $translator"
for module_index in "${!module_paths[@]}"; do
  module_path=${module_paths[$module_index]}
  [[ -f "$module_path" ]] || fail "component does not exist: $module_path"
  module_paths[$module_index]=$(realpath "$module_path")
done

bench_tmp=$(mktemp -d "${TMPDIR:-/tmp}/qip-recipe-bench.XXXXXX")
cleanup() {
  if [[ "$keep_temp" -eq 1 ]]; then
    echo "bench-qip-component-to-c-recipe: kept $bench_tmp" >&2
  else
    rm -rf "$bench_tmp"
  fi
}
trap cleanup EXIT

generated_source="$bench_tmp/qip-generated-recipe.c"
wasm2c_harness="$bench_tmp/wasm2c-recipe.c"
shared_executable="$bench_tmp/qip-shared"
dedicated_executable="$bench_tmp/qip-dedicated"
guard_executable="$bench_tmp/wasm2c-guard"
bounds_executable="$bench_tmp/wasm2c-bounds"
wazero_executable="$bench_tmp/wazero-recipe"
canonical_output="$bench_tmp/qip-output"

step "validating Content types and recipe connections through qip"
"$qip_bin" dry run -- "${module_paths[@]}" >&2

step "rendering the canonical recipe output through qip"
"$qip_bin" run -i "$input_path" -o "$canonical_output" -- "${module_paths[@]}"

generated_headers=()
wasm2c_headers=()
wasm2c_sources=()
step_number=1
for module_path in "${module_paths[@]}"; do
  generated_header="$bench_tmp/qip-step-$step_number.h"
  wasm2c_source="$bench_tmp/wasm2c-step-$step_number.c"
  step "translating step $step_number with QIP and WABT"
  "$qip_bin" run -i "$module_path" -o "$generated_header" "$translator"
  "$wasm2c_bin" -n "qipstep$step_number" "$module_path" -o "$wasm2c_source"
  generated_headers+=("$generated_header")
  wasm2c_headers+=("${wasm2c_source%.c}.h")
  wasm2c_sources+=("$wasm2c_source")
  step_number=$((step_number + 1))
done

"$node_bin" "$repo_root/tools/generate-content-recipe-c.mjs" \
  qip "$generated_source" "${generated_headers[@]}"
"$node_bin" "$repo_root/tools/generate-content-recipe-c.mjs" \
  wasm2c "$wasm2c_harness" "${wasm2c_headers[@]}"

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

step "compiling recipe executables"
"$cc_bin" -std=c11 -O3 -DNDEBUG -DQIP_RECIPE_SHARED_WORKSPACE=1 \
  "$generated_source" -lm -o "$shared_executable"
"$cc_bin" -std=c11 -O3 -DNDEBUG -DQIP_RECIPE_SHARED_WORKSPACE=0 \
  "$generated_source" -lm -o "$dedicated_executable"

compile_wasm2c() {
  local mode=$1
  local output=$2
  local -a mode_flags=()
  if [[ "$mode" == bounds ]]; then
    mode_flags=(-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1)
  fi
  "$cc_bin" -std=c11 -O3 -DNDEBUG \
    "${mode_flags[@]}" \
    -I"$wabt_include" -I"$wabt_runtime" \
    "$wasm2c_harness" \
    "${wasm2c_sources[@]}" \
    "$wabt_runtime/wasm-rt-impl.c" \
    "$wabt_runtime/wasm-rt-mem-impl.c" \
    -lm -o "$output"
}

compile_wasm2c guard "$guard_executable"
compile_wasm2c bounds "$bounds_executable"
GOCACHE="${GOCACHE:-"$bench_tmp/go-cache"}" \
  go build -buildvcs=false -trimpath -ldflags="-s -w" \
  -o "$wazero_executable" ./tools/bench-content-wazero-recipe

strip_binary() {
  if [[ "$(uname -s)" == Darwin ]]; then
    strip -x "$1"
  else
    strip "$1"
  fi
}
for executable in \
  "$shared_executable" "$dedicated_executable" \
  "$guard_executable" "$bounds_executable"; do
  strip_binary "$executable"
done

step "running warmed recipe benchmarks serially"
for ((trial = 1; trial <= trials; trial += 1)); do
  step "warm trial $trial/$trials"
  "$shared_executable" \
    "$input_path" "$duration_ms" "$bench_tmp/shared-output" "$warmup" \
    >"$bench_tmp/shared-$trial.json"
  "$dedicated_executable" \
    "$input_path" "$duration_ms" "$bench_tmp/dedicated-output" "$warmup" \
    >"$bench_tmp/dedicated-$trial.json"
  "$guard_executable" \
    "$input_path" "$duration_ms" "$bench_tmp/guard-output" "$warmup" \
    >"$bench_tmp/guard-$trial.json"
  "$bounds_executable" \
    "$input_path" "$duration_ms" "$bench_tmp/bounds-output" "$warmup" \
    >"$bench_tmp/bounds-$trial.json"
  "$node_bin" "$repo_root/tools/bench-content-node-recipe.mjs" \
    "$input_path" "$duration_ms" --warmup "$warmup" "${module_paths[@]}" \
    >"$bench_tmp/node-$trial.json"
  "$wazero_executable" \
    "$input_path" "$duration_ms" --warmup "$warmup" "${module_paths[@]}" \
    >"$bench_tmp/wazero-$trial.json"
done

for output in shared dedicated guard bounds; do
  cmp "$canonical_output" "$bench_tmp/$output-output" ||
    fail "$output output differs from qip run"
done

step "formatting comparison"
export CC="$cc_bin" WASM2C="$wasm2c_bin"
"$node_bin" "$repo_root/tools/format-qip-component-to-c-recipe-bench.mjs" \
  "$bench_tmp" "$trials" "$input_path" "$canonical_output" \
  "$shared_executable" "$dedicated_executable" \
  "$guard_executable" "$bounds_executable" \
  "$qip_bin" "$(command -v "$node_bin")" "$wazero_executable" \
  "${module_paths[@]}"
