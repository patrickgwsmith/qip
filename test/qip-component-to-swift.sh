#!/bin/sh
set -eu

qip_bin=${QIP_BIN:-./qip}
translator=application/wasm/qip-component-to-swift.wasm
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qip-component-to-swift.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

compile_and_run() {
    generated=$1
    runner=$2
    executable=$3
    cp "$runner" "$tmp_dir/main.swift"
    swiftc -O -whole-module-optimization -module-cache-path "$tmp_dir/module-cache" "$generated" "$tmp_dir/main.swift" -o "$executable"
    "$executable"
}

"$qip_bin" run -i text/hello.wasm -o "$tmp_dir/hello.swift" "$translator"
compile_and_run "$tmp_dir/hello.swift" test/qip-component-to-swift-runner.swift "$tmp_dir/hello"

"$qip_bin" run -i text/trim.wasm -o "$tmp_dir/trim.swift" "$translator"
swiftc -O -whole-module-optimization -emit-library -emit-module -module-name HelloComponent -module-cache-path "$tmp_dir/module-cache" "$tmp_dir/hello.swift" -o "$tmp_dir/libHelloComponent.dylib"
swiftc -O -whole-module-optimization -emit-library -emit-module -module-name TrimComponent -module-cache-path "$tmp_dir/module-cache" "$tmp_dir/trim.swift" -o "$tmp_dir/libTrimComponent.dylib"
cp test/qip-component-to-swift-bundle.swift "$tmp_dir/main.swift"
swiftc -O -whole-module-optimization -module-cache-path "$tmp_dir/module-cache" -I "$tmp_dir" -L "$tmp_dir" -lHelloComponent -lTrimComponent "$tmp_dir/main.swift" -o "$tmp_dir/bundle"
DYLD_LIBRARY_PATH="$tmp_dir" "$tmp_dir/bundle"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-floats.wasm -o "$tmp_dir/floats.swift" "$translator"
compile_and_run "$tmp_dir/floats.swift" test/qip-component-to-swift-floats.swift "$tmp_dir/floats"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-traps.wasm -o "$tmp_dir/traps.swift" "$translator"
compile_and_run "$tmp_dir/traps.swift" test/qip-component-to-swift-traps.swift "$tmp_dir/traps"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-direct.wasm -o "$tmp_dir/direct.swift" "$translator"
compile_and_run "$tmp_dir/direct.swift" test/qip-component-to-swift-direct.swift "$tmp_dir/direct"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-float-traps.wasm -o "$tmp_dir/float-traps.swift" "$translator"
compile_and_run "$tmp_dir/float-traps.swift" test/qip-component-to-swift-float-traps.swift "$tmp_dir/float-traps"

"$qip_bin" run -i test/fixtures/qip-component-to-zig-indirect.wasm -o "$tmp_dir/indirect.swift" "$translator"
compile_and_run "$tmp_dir/indirect.swift" test/qip-component-to-swift-indirect.swift "$tmp_dir/indirect"

echo "qip-component-to-swift native parity tests passed"
