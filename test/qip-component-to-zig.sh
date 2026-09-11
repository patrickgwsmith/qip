#!/bin/sh
set -eu

qip_bin=${QIP_BIN:-./qip}
zig_bin=${ZIG_BIN:-zig}
translator=application/wasm/qip-component-to-zig.wasm
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qip-component-to-zig.XXXXXX")
export ZIG_CACHE_DIR=${ZIG_CACHE_DIR:-/tmp/zig-cache}
export ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-global-cache}
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

zig_build() {
    if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]; then
        "$zig_bin" build-exe \
            --sysroot /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
            "$@"
    else
        "$zig_bin" build-exe "$@"
    fi
}

"$qip_bin" run -i text/hello.wasm \
    -o "$tmp_dir/hello.zig" "$translator"
zig_build --dep component \
    -Mroot=test/qip-component-to-zig-runner.zig \
    -Mcomponent="$tmp_dir/hello.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/hello"
"$tmp_dir/hello"

"$qip_bin" run -i text/trim.wasm \
    -o "$tmp_dir/trim.zig" "$translator"
zig_build --dep first --dep second \
    -Mroot=test/qip-component-to-zig-bundle.zig \
    -Mfirst="$tmp_dir/hello.zig" \
    -Msecond="$tmp_dir/trim.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/bundle"
"$tmp_dir/bundle"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-traps.wasm \
    -o "$tmp_dir/traps.zig" "$translator"
zig_build --dep component \
    -Mroot=test/qip-component-to-zig-traps.zig \
    -Mcomponent="$tmp_dir/traps.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/traps"
"$tmp_dir/traps"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-direct.wasm \
    -o "$tmp_dir/direct.zig" "$translator"
zig_build --dep component \
    -Mroot=test/qip-component-to-zig-direct.zig \
    -Mcomponent="$tmp_dir/direct.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/direct"
"$tmp_dir/direct"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-floats.wasm \
    -o "$tmp_dir/floats.zig" "$translator"
zig_build --dep component \
    -Mroot=test/qip-component-to-zig-floats.zig \
    -Mcomponent="$tmp_dir/floats.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/floats"
"$tmp_dir/floats"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-float-traps.wasm \
    -o "$tmp_dir/float-traps.zig" "$translator"
zig_build --dep component \
    -Mroot=test/qip-component-to-zig-float-traps.zig \
    -Mcomponent="$tmp_dir/float-traps.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/float-traps"
"$tmp_dir/float-traps"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-indirect.wasm \
    -o "$tmp_dir/indirect.zig" "$translator"
zig_build --dep component \
    -Mroot=test/qip-component-to-zig-indirect.zig \
    -Mcomponent="$tmp_dir/indirect.zig" \
    -O ReleaseSafe -femit-bin="$tmp_dir/indirect"
"$tmp_dir/indirect"

echo "qip-component-to-zig native parity tests passed"
