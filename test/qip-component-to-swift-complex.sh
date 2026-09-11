#!/bin/sh
set -eu

qip_bin=${QIP_BIN:-./qip}
translator=application/wasm/qip-component-to-swift.wasm
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qip-component-to-swift-complex.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

translate_and_compile() {
    module=$1
    stem=$2
    "$qip_bin" run -i "$module" -o "$tmp_dir/$stem.swift" "$translator"
    cp test/qip-component-to-swift-differential.swift "$tmp_dir/main.swift"
    swiftc -Onone -module-cache-path "$tmp_dir/module-cache" "$tmp_dir/$stem.swift" "$tmp_dir/main.swift" -o "$tmp_dir/$stem"
}

compare_output() {
    module=$1
    stem=$2
    input=$3
    "$qip_bin" run -i "$input" -o "$tmp_dir/$stem.wasm-output" "$module"
    "$tmp_dir/$stem" < "$input" > "$tmp_dir/$stem.swift-output"
    cmp "$tmp_dir/$stem.wasm-output" "$tmp_dir/$stem.swift-output"
}

printf '# Heading\n\nHello *world*.\n\n- one\n- two\n\n> quote\n' > "$tmp_dir/commonmark.md"
printf '%s' '{"name":"QIP","values":[1,true,null],"nested":{"escaped":"a\\nb"}}' > "$tmp_dir/data.json"

translate_and_compile text/markdown/commonmark.0.31.2.wasm commonmark
translate_and_compile application/json/json-prettify.wasm json-prettify
translate_and_compile image/png/png-to-bmp-b8g8r8a8-srgb.wasm png-to-bmp
translate_and_compile image/bmp/bmp-to-png.wasm bmp-to-png
translate_and_compile application/wasm/wasm-counts.wasm wasm-counts

compare_output text/markdown/commonmark.0.31.2.wasm commonmark "$tmp_dir/commonmark.md"
compare_output application/json/json-prettify.wasm json-prettify "$tmp_dir/data.json"
compare_output image/png/png-to-bmp-b8g8r8a8-srgb.wasm png-to-bmp site-static/_og/index.png
compare_output application/wasm/wasm-counts.wasm wasm-counts text/hello.wasm

"$qip_bin" run -i site-static/_og/index.png -o "$tmp_dir/image.bmp" image/png/png-to-bmp-b8g8r8a8-srgb.wasm
compare_output image/bmp/bmp-to-png.wasm bmp-to-png "$tmp_dir/image.bmp"

"$tmp_dir/png-to-bmp" < site-static/_og/index.png > "$tmp_dir/roundtrip.bmp"
"$tmp_dir/bmp-to-png" < "$tmp_dir/roundtrip.bmp" > "$tmp_dir/roundtrip.png"
cmp site-static/_og/index.png "$tmp_dir/roundtrip.png"

echo "qip-component-to-swift complex native parity tests passed"
