.PHONY: install build compare benchmark benchmark-wasm-simd benchmark-wasm-variants

install:
	npm ci

build:
	$(MAKE) -C ../.. text/javascript/js-syntax-highlight-html.wasm

compare: build
	npm run compare

benchmark: build
	npm run benchmark:qip

gpu-lexer-classifier-simd.wasm: gpu-lexer-classifier-simd.zig Makefile
	ZIG_CACHE_DIR=/tmp/qip-gpu-lexer-zig-cache ZIG_GLOBAL_CACHE_DIR=/tmp/qip-gpu-lexer-zig-global-cache zig build-exe $< -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -mcpu=generic+simd128 --stack 65536 --max-memory=2097152 -femit-bin=$@

gpu-lexer-classifier-simd-odin.wasm: gpu-lexer-classifier-simd.odin Makefile
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -o:speed -strict-target-features -target-features:simd128 -extra-linker-flags:"--strip-all --max-memory=4194304" -out:$@

gpu-lexer-classifier-simd-relaxed.wasm: gpu-lexer-classifier-simd-relaxed.wat
	wat2wasm --enable-relaxed-simd $< -o $@

benchmark-wasm-simd: gpu-lexer-classifier-simd.wasm
	node benchmark-gpu-lexer-wasm-simd.mjs

benchmark-wasm-variants: gpu-lexer-classifier-simd.wasm gpu-lexer-classifier-simd-odin.wasm gpu-lexer-classifier-simd-relaxed.wasm
	node benchmark-gpu-lexer-wasm-variants.mjs
