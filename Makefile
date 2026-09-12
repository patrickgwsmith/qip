.PHONY: fuzz-zlib compliance components recipes components-wat-wasm components-c-wasm components-zig-wasm components-rust-wasm test test-go test-node test-deno test-comply test-wasm-core-1-spec test-wasm-core-2-spec test-svg-rasterizers test-wasm-bounded-output test-markdown-pathological test-warc-libs test-qip-component-to-c test-qip-component-to-zig test-qip-component-to-swift test-qip-component-to-swift-complex test-qip-router-help site-static site-checks install score wasm-safety-report strict-profile-report

default: qip compliance components recipes

include ./fixtures/sqlite3/sqlite.mk

WASM_STACK_SIZE ?= 65536
WASM_STACK_FLAG := -Wl,-z,stack-size=$(WASM_STACK_SIZE)
ZIG_WASM_FLAGS := -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic
ZIG_WASM_SIMD_FLAGS := -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -mcpu=generic+simd128
GO_TOOL_PKGS := ./tools/bench-content-wazero-recipe
GO_TOOL_FILES := ./tools/zlib-go-compress.go
GO_FIX_PKGS := ./cmd/... ./internal/... $(GO_TOOL_PKGS)
GO_FMT_PKGS := . ./cmd/... ./internal/... $(GO_TOOL_PKGS)
GO_TEST_PKGS := . ./cmd/... ./internal/... $(GO_TOOL_PKGS)
QIP_BIN ?= ./qip
QIP_GO_DEPS := $(filter-out %_test.go,$(wildcard *.go)) $(wildcard cmd/*.go) $(wildcard internal/*.go) $(wildcard internal/*/*.go)

qip: go.mod go.sum $(QIP_GO_DEPS)
	go fix $(GO_FIX_PKGS)
	go fix $(GO_TOOL_FILES)
	go fmt $(GO_FMT_PKGS)
	go fmt $(GO_TOOL_FILES)
	go build -ldflags="-s -w" -trimpath

compliance/%.wasm: compliance/%.wat
	wat2wasm $< -o $@

compliance/unicode-17-lowercase.comply.wasm: compliance/unicode-17-lowercase.comply.zig compliance/unicode-17-lowercase-tables.zig compliance/unicode-17-lowercase-fixtures.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/unicode-17-uppercase.comply.wasm: compliance/unicode-17-uppercase.comply.zig compliance/unicode-17-uppercase-tables.zig compliance/unicode-17-uppercase-fixtures.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-usd-en-us.comply.wasm: compliance/currency-format-usd-en-us.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-en-us.comply.wasm: compliance/currency-format-en-us.comply.zig compliance/currency-format-en-us-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-en-in.comply.wasm: compliance/currency-format-en-in.comply.zig compliance/currency-format-en-in-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-es-es.comply.wasm: compliance/currency-format-es-es.comply.zig compliance/currency-format-es-es-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-de-de.comply.wasm: compliance/currency-format-de-de.comply.zig compliance/currency-format-de-de-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-ar-eg.comply.wasm: compliance/currency-format-ar-eg.comply.zig compliance/currency-format-ar-eg-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-fr-fr.comply.wasm: compliance/currency-format-fr-fr.comply.zig compliance/currency-format-fr-fr-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-pt-br.comply.wasm: compliance/currency-format-pt-br.comply.zig compliance/currency-format-pt-br-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-ja-jp.comply.wasm: compliance/currency-format-ja-jp.comply.zig compliance/currency-format-ja-jp-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-zh-cn.comply.wasm: compliance/currency-format-zh-cn.comply.zig compliance/currency-format-zh-cn-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

text/currency-format-en-us.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-en-us.wasm: text/lib/currency-format-en-us-table.zig
text/currency-format-en-in.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-en-in.wasm: text/lib/currency-format-en-in-table.zig
text/currency-format-es-es.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-es-es.wasm: text/lib/currency-format-es-es-table.zig
text/currency-format-de-de.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-de-de.wasm: text/lib/currency-format-de-de-table.zig
text/currency-format-ar-eg.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-ar-eg.wasm: text/lib/currency-format-ar-eg-table.zig
text/currency-format-fr-fr.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-fr-fr.wasm: text/lib/currency-format-fr-fr-table.zig
text/currency-format-pt-br.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-pt-br.wasm: text/lib/currency-format-pt-br-table.zig
text/currency-format-ja-jp.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-ja-jp.wasm: text/lib/currency-format-ja-jp-table.zig
text/currency-format-zh-cn.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/currency-format-zh-cn.wasm: text/lib/currency-format-zh-cn-table.zig
image/svg+xml/svg-to-data-uri.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
text/uri-list/data-uri-to-css-url.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0

text/html/html-code-syntax-highlight-css.wasm: text/html/lib/syntax-highlight-css.zig
text/html/html-code-syntax-highlight-tsx.wasm: text/html/lib/syntax-highlight-javascript.zig
text/html/html-code-syntax-highlight-html.wasm: text/html/lib/syntax-highlight-css.zig text/html/lib/syntax-highlight-javascript.zig
text/javascript/js-syntax-highlight-html.wasm: text/javascript/js-syntax-highlight-html.zig text/html/lib/syntax-highlight-javascript.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep javascript -Mroot=$< -Mjavascript=text/html/lib/syntax-highlight-javascript.zig -femit-bin=$@
text/html/html-to-accessibility-tree.wasm text/html/html-accessible-name-unique-validator.wasm: text/html/lib/html-accessibility.zig

compliance/iso-4217-alpha-to-numeric.comply.wasm: compliance/iso-4217-alpha-to-numeric.comply.zig compliance/iso-4217-alpha-numeric-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/svg-to-data-uri.comply.wasm: compliance/svg-to-data-uri.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/data-uri-to-css-url.comply.wasm: compliance/data-uri-to-css-url.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/rgb-to-hex.comply.wasm: compliance/rgb-to-hex.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/mermaid-to-unicode-html.comply.wasm: compliance/mermaid-to-unicode-html.comply.zig compliance/mermaid-to-unicode-html.fixtures.txt
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/warc-connect-search-params.comply.wasm: compliance/warc-connect-search-params.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/jpeg-to-bmp-b8g8r8a8-srgb.comply.wasm: compliance/jpeg-to-bmp-b8g8r8a8-srgb.comply.zig $(wildcard compliance/jpeg-to-bmp-b8g8r8a8-srgb-fixtures/*)
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/bmp-b8g8r8a8-icc-to-srgb.comply.wasm: compliance/bmp-b8g8r8a8-icc-to-srgb.comply.zig $(wildcard compliance/bmp-b8g8r8a8-icc-to-srgb-fixtures/*)
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

SYNTAX_HIGHLIGHT_COMPLY_TARGETS := compliance/syntax-highlight-javascript.comply.wasm compliance/syntax-highlight-javascript-semantic.comply.wasm compliance/syntax-highlight-html.comply.wasm compliance/syntax-highlight-css.comply.wasm compliance/syntax-highlight-python.comply.wasm compliance/syntax-highlight-java.comply.wasm compliance/syntax-highlight-csharp.comply.wasm compliance/syntax-highlight-swift.comply.wasm compliance/syntax-highlight-ruby.comply.wasm compliance/syntax-highlight-go.comply.wasm compliance/syntax-highlight-c.comply.wasm compliance/syntax-highlight-bash.comply.wasm compliance/syntax-highlight-wasm.comply.wasm compliance/syntax-highlight-zig.comply.wasm

compliance/syntax-highlight-%.comply.wasm: compliance/syntax-highlight-%.comply.zig compliance/syntax-highlight-%.fixtures.txt compliance/lib/syntax-highlight-comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

COMMONMARK_COMPLY_TARGETS := compliance/commonmark-spec-0.31.2.wasm compliance/commonmark-0.31.2-gfm.wasm compliance/html5-entities.comply.wasm compliance/unicode-17-casefold-labels.comply.wasm compliance/commonmark-differential-corpus.comply.wasm

compliance/commonmark-spec-0.31.2.wasm: compliance/commonmark-spec-0.31.2.zig compliance/commonmark-spec-0.31.2.txt
compliance/commonmark-0.31.2-gfm.wasm: compliance/commonmark-0.31.2-gfm.zig compliance/gfm-commonmark-spec-0.31.2.txt compliance/gfm-extensions-0.29.txt compliance/gfm-spec-0.29.txt
compliance/html5-entities.comply.wasm: compliance/html5-entities.comply.zig compliance/html5-entities-table.zig
compliance/unicode-17-casefold-labels.comply.wasm: compliance/unicode-17-casefold-labels.comply.zig compliance/unicode-17-casefold-tables.zig
compliance/commonmark-differential-corpus.comply.wasm: compliance/commonmark-differential-corpus.comply.zig compliance/commonmark-differential-corpus.txt

$(COMMONMARK_COMPLY_TARGETS):
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance: $(patsubst compliance/%.wat,compliance/%.wasm,$(wildcard compliance/*.wat))
compliance: compliance/unicode-17-lowercase.comply.wasm
compliance: compliance/unicode-17-uppercase.comply.wasm
compliance: compliance/currency-format-usd-en-us.comply.wasm
compliance: compliance/currency-format-en-us.comply.wasm
compliance: compliance/currency-format-en-in.comply.wasm
compliance: compliance/currency-format-es-es.comply.wasm
compliance: compliance/currency-format-de-de.comply.wasm
compliance: compliance/currency-format-ar-eg.comply.wasm
compliance: compliance/currency-format-fr-fr.comply.wasm
compliance: compliance/currency-format-pt-br.comply.wasm
compliance: compliance/currency-format-ja-jp.comply.wasm
compliance: compliance/currency-format-zh-cn.comply.wasm
compliance: compliance/iso-4217-alpha-to-numeric.comply.wasm
compliance: compliance/svg-to-data-uri.comply.wasm
compliance: compliance/data-uri-to-css-url.comply.wasm
compliance: compliance/rgb-to-hex.comply.wasm
compliance: compliance/mermaid-to-unicode-html.comply.wasm
compliance: compliance/warc-connect-search-params.comply.wasm
compliance: compliance/jpeg-to-bmp-b8g8r8a8-srgb.comply.wasm
compliance: compliance/bmp-b8g8r8a8-icc-to-srgb.comply.wasm
compliance: compliance/base64-decode.comply.wasm
compliance: $(SYNTAX_HIGHLIGHT_COMPLY_TARGETS)
compliance: $(COMMONMARK_COMPLY_TARGETS)

ZIG_CACHE_DIR ?= /tmp/zig-cache
ZIG_GLOBAL_CACHE_DIR ?= /tmp/zig-global-cache
ZIG_ENV := ZIG_CACHE_DIR=$(ZIG_CACHE_DIR) ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR)
ZIG_WASM_MAX_MEMORY ?= 67108864
ODIN_WASM_MAX_MEMORY ?= 2097152
RUST_WASM_TARGET_DIR ?= /tmp/qip-rust-wasm-target
RUST_WASM_CARGO_FLAGS ?=

HOST_OS ?= $(shell uname -s)
ifeq ($(HOST_OS),Darwin)
ZIG_TEST_SYSROOT ?= $(firstword $(wildcard /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.4.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk))
ifneq ($(ZIG_TEST_SYSROOT),)
ZIG_TEST_FLAGS ?= --sysroot $(ZIG_TEST_SYSROOT)
endif
endif
ZIG_TEST_FLAGS ?=

CONTENT_COMPONENT_DIRS := application bytes font image multipart text
COMPONENT_DIRS := components $(CONTENT_COMPONENT_DIRS)

COMPONENT_WAT_FILES := $(shell find $(COMPONENT_DIRS) -type f -name '*.wat')
COMPONENT_C_FILES := $(shell find $(COMPONENT_DIRS) -type f -name '*.c')
COMPONENT_ZIG_FILES := $(shell find $(COMPONENT_DIRS) \( -path 'components/interactive/assets' -o -type d -name 'lib' \) -prune -o -type f -name '*.zig' -print)

COMPONENT_WAT_TARGETS := $(patsubst %.wat,%.wasm,$(COMPONENT_WAT_FILES))
COMPONENT_C_TARGETS := $(patsubst %.c,%.wasm,$(COMPONENT_C_FILES))
COMPONENT_ZIG_TARGETS := $(patsubst %.zig,%.wasm,$(COMPONENT_ZIG_FILES))

define COMPONENT_WAT_RULE
$(1)/%.wasm: $(1)/%.wat
	wat2wasm $$< -o $$@
endef
$(foreach dir,$(COMPONENT_DIRS),$(eval $(call COMPONENT_WAT_RULE,$(dir))))

SQLITE3_ZIG_COMPONENTS := sqlite-first-table-dump sqlite-schema sqlite-table-dump sqlite-table-csv sqlite-row-lookup sqlite-table-count
$(foreach m,$(SQLITE3_ZIG_COMPONENTS),application/vnd.sqlite3/$(m).wasm): application/vnd.sqlite3/lib/sqlite.zig

application/vnd.sqlite3/sqlite-table-names.wasm: application/vnd.sqlite3/sqlite-table-names.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_utf8_cap -Oz -o $@

text/text-to-bmp.wasm: text/text-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=uniform_set_leading -Wl,--export=uniform_set_cols -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

text/text-to-ktx2-r8g8b8a8-srgb.wasm: text/text-to-bmp.c text/lib/raster-output.h text/lib/string.h image/lib/ktx2-rgba8-srgb.h
	$(ZIG_ENV) zig cc $< -I text/lib -DQIP_TEXT_OUTPUT_KTX2 -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=uniform_set_leading -Wl,--export=uniform_set_cols -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

text/text-to-og-image-font8x8.wasm: text/text-to-og-image-font8x8.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=uniform_set_text_color_rgba -Wl,--export=uniform_set_background_color_rgba -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

text/text-to-og-image-font8x8-ktx2-r8g8b8a8-srgb.wasm: text/text-to-og-image-font8x8.c text/lib/raster-output.h text/lib/string.h image/lib/ktx2-rgba8-srgb.h
	$(ZIG_ENV) zig cc $< -I text/lib -DQIP_TEXT_OUTPUT_KTX2 -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=uniform_set_text_color_rgba -Wl,--export=uniform_set_background_color_rgba -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

image/bmp/bmp-double.wasm: image/bmp/bmp-double.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_bytes_cap -Oz -o $@

image/bmp/bmp-double-simd.wasm: image/bmp/bmp-double-simd.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -mcpu=generic+simd128 -femit-bin=$@

image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm: image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm: image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.zig image/lib/ktx2-bgra8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_bgra8_srgb -Mroot=$< -Mktx2_bgra8_srgb=image/lib/ktx2-bgra8-srgb.zig -femit-bin=$@

image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm: image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm image/ktx2/ktx2-rgba32float-look-warm-fade.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-display-p3-linear-to-ktx2-rgba32float-display-p3.wasm: image/ktx2/ktx2-rgba32float-display-p3-linear-to-ktx2-rgba32float-display-p3.zig image/lib/ktx2-rgba32float-display-p3-linear.zig image/lib/ktx2-rgba32float-display-p3.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_display_p3_linear --dep ktx2_rgba32float_display_p3 -Mroot=$< -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig --dep ktx2_rgba32float_display_p3_linear -Mktx2_rgba32float_display_p3=image/lib/ktx2-rgba32float-display-p3.zig -femit-bin=$@

image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear.wasm: ZIG_WASM_MAX_MEMORY = 134217728
image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear.wasm: image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear.zig image/lib/ktx2-rgba32float-display-p3-linear.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_display_p3_linear -Mroot=$< -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig -femit-bin=$@

image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm: ZIG_WASM_MAX_MEMORY = 134217728
image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm: image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.zig image/lib/ktx2-rgba32float-display-p3-linear.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_display_p3_linear -Mroot=$< -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig -femit-bin=$@

image/svg+xml/svg-to-pdf-inter-font.wasm: ZIG_WASM_MAX_MEMORY = 12582912
image/svg+xml/svg-to-pdf-inter-font.wasm: image/svg+xml/svg-to-pdf-inter-font.zig image/svg+xml/sRGB2014.icc font/ttf/lib/ttf.zig fixtures/inter-4.1/inter-display-regular.zig fixtures/inter-4.1/inter-display-bold.zig fixtures/inter-4.1/inter-display-italic.zig fixtures/inter-4.1/inter-display-bold-italic.zig fixtures/inter-4.1/ttf/InterDisplay-Regular.ttf fixtures/inter-4.1/ttf/InterDisplay-Bold.ttf fixtures/inter-4.1/ttf/InterDisplay-Italic.ttf fixtures/inter-4.1/ttf/InterDisplay-BoldItalic.ttf
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ttf --dep inter_regular --dep inter_bold --dep inter_italic --dep inter_bold_italic -Mroot=$< -Mttf=font/ttf/lib/ttf.zig -Minter_regular=fixtures/inter-4.1/inter-display-regular.zig -Minter_bold=fixtures/inter-4.1/inter-display-bold.zig -Minter_italic=fixtures/inter-4.1/inter-display-italic.zig -Minter_bold_italic=fixtures/inter-4.1/inter-display-bold-italic.zig -femit-bin=$@

text/csv/time-series-csv-to-svg-polylines.wasm: text/csv/time-series-csv-to-svg-polylines.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

image/svg+xml/svg-polylines-exponential-moving-average.wasm: image/svg+xml/svg-polylines-exponential-moving-average.zig image/svg+xml/lib/polyline-smoothing.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep polyline_smoothing -Mroot=$< -Mpolyline_smoothing=image/svg+xml/lib/polyline-smoothing.zig -femit-bin=$@

image/svg+xml/svg-polylines-rolling-mean.wasm: image/svg+xml/svg-polylines-rolling-mean.zig image/svg+xml/lib/polyline-smoothing.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep polyline_smoothing -Mroot=$< -Mpolyline_smoothing=image/svg+xml/lib/polyline-smoothing.zig -femit-bin=$@

image/svg+xml/svg-polylines-add-mean-lines.wasm: image/svg+xml/svg-polylines-add-mean-lines.zig image/svg+xml/lib/polyline-smoothing.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep polyline_smoothing -Mroot=$< -Mpolyline_smoothing=image/svg+xml/lib/polyline-smoothing.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/ktx2/lib/resize-rgba8-srgb.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/ktx2/lib/resize-rgba8-srgb.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_SIMD_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/ktx2/lib/resize-rgba32float-linear.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_profile -Mroot=$< -Mktx2_rgba32float_profile=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3-simd.wasm image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-simd.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/ktx2/lib/resize-rgba32float-linear.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_SIMD_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_profile -Mroot=$< -Mktx2_rgba32float_profile=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.wasm image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/ktx2/lib/resize-rgba32float-linear.zig image/lib/ktx2-rgba32float-display-p3-linear.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_profile -Mroot=$< -Mktx2_rgba32float_profile=image/lib/ktx2-rgba32float-display-p3-linear.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3-simd.wasm image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell-simd.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/ktx2/lib/resize-rgba32float-linear.zig image/lib/ktx2-rgba32float-display-p3-linear.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_SIMD_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float_profile -Mroot=$< -Mktx2_rgba32float_profile=image/lib/ktx2-rgba32float-display-p3-linear.zig -femit-bin=$@

image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm: image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-rgba32float-display-p3-linear.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -mcpu=generic+simd128 --dep ktx2_rgba8_srgb --dep ktx2_rgba32float_display_p3_linear -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig -femit-bin=$@

image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm: image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.zig image/lib/ktx2-bgra8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_bgra8_srgb -Mroot=$< -Mktx2_bgra8_srgb=image/lib/ktx2-bgra8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm: image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.wasm: ZIG_WASM_MAX_MEMORY = 2097152
image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.wasm: image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-color-palette.wasm: ZIG_WASM_MAX_MEMORY = 134217728
image/ktx2/ktx2-r8g8b8a8-srgb-color-palette.wasm: image/ktx2/ktx2-r8g8b8a8-srgb-color-palette.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm: ZIG_WASM_MAX_MEMORY = 100663296
image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm: image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-double.wasm: ZIG_WASM_MAX_MEMORY = 134217728
image/ktx2/ktx2-r8g8b8a8-srgb-double.wasm: image/ktx2/ktx2-r8g8b8a8-srgb-double.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-rotate-and-flip.wasm: ZIG_WASM_MAX_MEMORY = 268435456
image/ktx2/ktx2-r8g8b8a8-srgb-rotate-and-flip.wasm: image/ktx2/ktx2-r8g8b8a8-srgb-rotate-and-flip.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/ktx2/ktx2-rgba32float-rotate-and-flip.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-rotate-and-flip.wasm: image/ktx2/ktx2-rgba32float-rotate-and-flip.zig image/lib/ktx2-rgba32float.zig image/lib/ktx2-rgba32float-display-p3-linear.zig image/lib/ktx2-rgba32float-display-p3.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba32float --dep ktx2_rgba32float_display_p3_linear --dep ktx2_rgba32float_display_p3 -Mroot=$< -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig --dep ktx2_rgba32float_display_p3_linear -Mktx2_rgba32float_display_p3=image/lib/ktx2-rgba32float-display-p3.zig -femit-bin=$@

image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm: image/ktx2/%.wasm: image/ktx2/%.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm: image/png/png-to-bmp-b8g8r8a8-srgb-simd.zig image/png/png-to-bmp-b8g8r8a8-srgb.zig
	$(ZIG_ENV) zig build-exe $< -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic --max-memory=$(ZIG_WASM_MAX_MEMORY) -mcpu=generic+simd128 -femit-bin=$@

image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm: image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm: image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm: image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.zig image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_SIMD_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm: image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.zig image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-rgba32float.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_SIMD_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -femit-bin=$@

components/interactive/calendar-gregorian.wasm: ZIG_WASM_MAX_MEMORY = 1114112

components/interactive/qipdb.wasm: ZIG_WASM_MAX_MEMORY = 268435456
components/interactive/qipdb.wasm: components/interactive/qipdb.zig application/wasm/lib/wasm-interpreter.zig application/wasm/lib/wasm-counts.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep wasm_interpreter --dep wasm_counts -Mroot=$< -Mwasm_interpreter=application/wasm/lib/wasm-interpreter.zig -Mwasm_counts=application/wasm/lib/wasm-counts.zig -femit-bin=$@

components/interactive/svg-path-editor.wasm: ZIG_WASM_MAX_MEMORY = 8388608

application/wasm/qip-content-interpreter.wasm: ZIG_WASM_MAX_MEMORY = 268435456
application/wasm/qip-content-interpreter.wasm: application/wasm/qip-content-interpreter.zig application/wasm/lib/wasm-interpreter.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep wasm_interpreter -Mroot=$< -Mwasm_interpreter=application/wasm/lib/wasm-interpreter.zig -femit-bin=$@

test/fixtures/wasm-debugger-bulk-memory.wasm: test/fixtures/wasm-debugger-bulk-memory.wat
	wat2wasm $< -o $@

test/fixtures/wasm-debugger-call-indirect.wasm: test/fixtures/wasm-debugger-call-indirect.wat
	wat2wasm $< -o $@

test/fixtures/qip-content-interpreter-uniforms.wasm: test/fixtures/qip-content-interpreter-uniforms.wat
	wat2wasm $< -o $@

components/interactive/cover-flow.wasm: components/interactive/cover-flow.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -mcpu=generic+simd128 --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

components/interactive/god-rays-optimized.wasm: components/interactive/god-rays-optimized.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

components/interactive/tic-tac-toe-sun-moon.wasm: components/interactive/tic-tac-toe-sun-moon.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

components/interactive/side-scroller-platformer.wasm components/interactive/spreadsheet.wasm: components/interactive/%.wasm: components/interactive/%.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

components/interactive/gameboy-camera.wasm components/interactive/liars-dice.wasm components/interactive/macos9-desktop.wasm components/interactive/macosx-leopard-desktop.wasm components/interactive/org_planner.wasm components/interactive/peon-gold.wasm components/interactive/textedit.wasm components/interactive/vertical-shooter.wasm components/interactive/windows95-desktop.wasm: components/interactive/%.wasm: components/interactive/%.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

components/interactive/aces-up.wasm components/interactive/browser-security.wasm components/interactive/calculator.wasm components/interactive/chronograph.wasm components/interactive/cover-flow-lofi.wasm components/interactive/dock-magnification.wasm components/interactive/formula-1-map.wasm components/interactive/gif-player.wasm components/interactive/god-rays.wasm components/interactive/graph-calculator.wasm components/interactive/ieee-754-floats.wasm components/interactive/layout-systems.wasm components/interactive/macintosh-1bit.wasm components/interactive/mandelbrot.wasm components/interactive/moon-phases.wasm components/interactive/openai-anthropic-arr.wasm components/interactive/page-load-waterfall.wasm components/interactive/paint.wasm components/interactive/perlin-noise.wasm components/interactive/photo-light-table.wasm components/interactive/ps2-menu.wasm components/interactive/render-counts.wasm components/interactive/shadow-rendering.wasm components/interactive/shutterstock-earnings.wasm components/interactive/snake.wasm components/interactive/sudoku.wasm components/interactive/tetris.wasm components/interactive/tile-world-12x12.wasm components/interactive/web-mechanics.wasm components/interactive/webos-card-view.wasm components/interactive/xbox-dashboard.wasm: components/interactive/%.wasm: components/interactive/%.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb $(if $(filter components/interactive/chronograph.wasm,$@),--dep ktx2_rgba32float_display_p3_linear) -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig $(if $(filter components/interactive/chronograph.wasm,$@),-Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig) -femit-bin=$@

components/interactive/chronograph.wasm: components/interactive/assets/inter_display_bold_chronograph_digits.zig image/lib/ktx2-rgba32float-display-p3-linear.zig

application/wasm/wasm-strict-profile.wasm: ZIG_WASM_MAX_MEMORY = 20971520
application/wasm/wasm-strict-profile.wasm: application/wasm/wasm-strict-profile.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/wasm-read-input-content-type.wasm: ZIG_WASM_MAX_MEMORY = 16777216
application/wasm/wasm-read-input-content-type.wasm: application/wasm/wasm-read-input-content-type.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/wasm-validate-core-1.0.wasm: ZIG_WASM_MAX_MEMORY = 25165824
# Keep bulk-memory lowering for copies, but do not emit sign-extension opcodes.
application/wasm/wasm-validate-core-1.0.wasm: application/wasm/wasm-validate-core-1.0.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) -mcpu=generic-sign_ext --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

CORE2_VALIDATOR_DIR := application/wasm/wasm-validate-core-2.0
CORE2_VALIDATOR_DEPS := $(shell find $(CORE2_VALIDATOR_DIR) third_party/rust/wasmparser-0.252.0 third_party/rust/bitflags-2.13.0 -type f)
application/wasm/wasm-validate-core-2.0.wasm: $(CORE2_VALIDATOR_DEPS)
	cd $(CORE2_VALIDATOR_DIR) && CARGO_TARGET_DIR=$(RUST_WASM_TARGET_DIR) cargo build --release --locked --offline --target wasm32-unknown-unknown $(RUST_WASM_CARGO_FLAGS)
	cp $(RUST_WASM_TARGET_DIR)/wasm32-unknown-unknown/release/qip-wasm-validate-core-2.wasm $@

application/wasm/wasm-bounded-loops.wasm: ZIG_WASM_MAX_MEMORY = 25165824
application/wasm/wasm-bounded-loops.wasm: application/wasm/wasm-bounded-loops.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/wasm-bounded-output.wasm: ZIG_WASM_MAX_MEMORY = 20971520
application/wasm/wasm-bounded-output.wasm: application/wasm/wasm-bounded-output.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/wasm-counts.wasm: ZIG_WASM_MAX_MEMORY = 12582912
application/wasm/wasm-counts.wasm: application/wasm/wasm-counts.zig application/wasm/lib/wasm-counts.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/render-cyclomatic-complexity.wasm: ZIG_WASM_MAX_MEMORY = 12582912
application/wasm/render-cyclomatic-complexity.wasm: application/wasm/render-cyclomatic-complexity.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/wasm-nontrapping-divides.wasm: ZIG_WASM_MAX_MEMORY = 25165824
application/wasm/wasm-nontrapping-divides.wasm: application/wasm/wasm-nontrapping-divides.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/wasm-to-js.wasm: application/wasm/wasm-to-js.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

text/csv/content-recipe-to-browser-javascript.wasm: ZIG_WASM_MAX_MEMORY = 2097152

font/ttf/ttf-to-svg-paths-csv.wasm font/ttf/ttf-to-svg-path-defs.wasm: font/ttf/lib/ttf.zig font/ttf/lib/path-output.zig

text/text-to-og-image-svg-dejavu-sans-mono.wasm: text/dejavu_sans_mono_56_latin1_paths.zig text/dejavu_sans_mono_bold_56_latin1_paths.zig

text/text-to-path-svg-dejavu-sans-mono-bold.wasm: text/dejavu_sans_mono_bold_paths.zig

text/text-to-path-svg-dejavu-sans-mono.wasm: text/dejavu_sans_mono_paths.zig

text/text-to-og-image-svg-inter.wasm: text/lib/inter_display_latin_paths.zig text/lib/inter_display_bold_latin_paths.zig

text/text-to-svg-inter.wasm: text/text-to-og-image-svg-inter.zig text/lib/inter_display_latin_paths.zig text/lib/inter_display_bold_latin_paths.zig

text/text-to-svg-jetbrains-mono-v2.304.wasm: text/text-to-og-image-svg-inter.zig text/lib/jetbrains_mono_2_304_regular_latin_paths.zig text/lib/jetbrains_mono_2_304_bold_latin_paths.zig

text/strip-ansi-sgr.wasm text/ansi-sgr-to-html.wasm text/ansi-sgr-to-svg.wasm: text/lib/ansi-sgr.zig

text/text-to-og-image-dejavu-sans-mono-ktx2-r8g8b8a8-srgb.wasm: text/text-to-og-image-dejavu-sans-mono-ktx2-r8g8b8a8-srgb.zig text/text-to-og-image-dejavu-sans-mono.zig text/dejavu_sans_mono_56_latin1_bitmap.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

application/wasm/qip-component-to-c.wasm: ZIG_WASM_MAX_MEMORY = 41943040
application/wasm/qip-component-to-c.wasm: application/wasm/qip-component-to-c.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/qip-component-to-zig.wasm: ZIG_WASM_MAX_MEMORY = 41943040
application/wasm/qip-component-to-zig.wasm: application/wasm/qip-component-to-zig.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

application/wasm/qip-component-to-swift.wasm: ZIG_WASM_MAX_MEMORY = 41943040
application/wasm/qip-component-to-swift.wasm: application/wasm/qip-component-to-swift.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

bytes/bytes-to-sha256.wasm: ZIG_WASM_MAX_MEMORY = 20971520

text/javascript/js-to-bmp.wasm: text/javascript/js-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

text/javascript/js-to-ktx2-r8g8b8a8-srgb.wasm: text/javascript/js-to-bmp.c text/lib/raster-output.h text/lib/string.h image/lib/ktx2-rgba8-srgb.h
	$(ZIG_ENV) zig cc $< -I text/lib -DQIP_TEXT_OUTPUT_KTX2 -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

text/x-c/c-to-bmp.wasm: text/x-c/c-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

text/x-c/c-to-ktx2-r8g8b8a8-srgb.wasm: text/x-c/c-to-bmp.c text/lib/raster-output.h text/lib/string.h image/lib/ktx2-rgba8-srgb.h
	$(ZIG_ENV) zig cc $< -I text/lib -DQIP_TEXT_OUTPUT_KTX2 -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_bytes_cap -Oz -o $@

recipes/text/markdown/80-html-page-wrap.wasm: recipes/text/markdown/styles.css recipes/text/markdown/header.html recipes/text/markdown/footer.html

text/html/html-add-highlight-stylesheet-night-owl.wasm: text/html/highlight-night-owl.css

recipes/text/markdown/17-html-code-syntax-highlight-go.wasm: text/html/html-code-syntax-highlight-go.wasm
	cp $< $@

recipes/text/markdown/18-html-code-syntax-highlight-ruby.wasm: text/html/html-code-syntax-highlight-ruby.wasm
	cp $< $@

recipes/text/markdown/19-html-code-syntax-highlight-swift.wasm: text/html/html-code-syntax-highlight-swift.wasm
	cp $< $@

recipes/text/markdown/29-add-highlight-stylesheet-night-owl.wasm: text/html/html-add-highlight-stylesheet-night-owl.wasm
	cp $< $@

recipes/text/markdown/28-html-code-syntax-highlight-css.wasm: text/html/html-code-syntax-highlight-css.wasm
	cp $< $@

recipes/text/markdown/23-html-code-syntax-highlight-tsx.wasm: text/html/html-code-syntax-highlight-tsx.wasm
	cp $< $@

text/markdown/commonmark.0.31.2.wasm text/markdown/gfm-commonmark.0.31.2.wasm: text/markdown/lib/commonmark.zig text/markdown/lib/html5-entities-table.zig text/markdown/lib/unicode-17-casefold-tables.zig

text/markdown/markdown-basic.wasm: recipes/text/markdown/10-markdown-basic.wasm
	cp $< $@

text/html/html-page-wrap.wasm: recipes/text/markdown/80-html-page-wrap.wasm
	cp $< $@

application/warc/warc-check-broken-links.wasm: ZIG_WASM_MAX_MEMORY = 167772160
application/warc/warc-counts.wasm: ZIG_WASM_MAX_MEMORY = 142606336
application/warc/warc-extract-broken-links.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/warc/warc-check-broken-module-imports.wasm: ZIG_WASM_MAX_MEMORY = 167772160
application/warc/warc-to-static-tar-no-trailing-slash.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/x-tar/tar-to-zip.wasm: ZIG_WASM_MAX_MEMORY = 402653184
application/x-tar/tar-to-zip.wasm: application/x-tar/tar-to-zip.zig bytes/lib/deflate.zig
	$(ZIG_ENV) zig build-exe -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep deflate -Mroot=$< -Mdeflate=bytes/lib/deflate.zig -femit-bin=$@
application/x-tar/recipes-tar-to-csv.wasm: ZIG_WASM_MAX_MEMORY = 150994944
application/x-tar/recipes-tar-to-node-tar.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/x-tar/recipes-tar-to-csv.wasm application/x-tar/recipes-tar-to-node-tar.wasm: application/x-tar/%.wasm: application/x-tar/%.zig application/x-tar/lib/recipe-book.zig application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep wasm_reader -Mroot=$< -Mwasm_reader=application/wasm/lib/wasm-reader.zig -femit-bin=$@
application/zip/zip-to-tar.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/zip/zip-to-tar.wasm: application/zip/zip-to-tar.zig application/zip/lib/zip.zig bytes/lib/inflate.zig bytes/lib/deflate.zig
	$(ZIG_ENV) zig build-exe -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep inflate -Mroot=$< -Minflate=bytes/lib/inflate.zig -femit-bin=$@
application/zip/zip-list-entries-csv.wasm application/zip/zip-list-files-csv.wasm application/zip/zip-extract-file.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/zip/zip-list-entries-csv.wasm application/zip/zip-list-files-csv.wasm application/zip/zip-extract-file.wasm: application/zip/%.wasm: application/zip/%.zig application/zip/lib/zip.zig application/zip/lib/list-csv.zig bytes/lib/inflate.zig bytes/lib/deflate.zig
	$(ZIG_ENV) zig build-exe -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep inflate -Mroot=$< -Minflate=bytes/lib/inflate.zig -femit-bin=$@
application/warc/warc-add-open-graph-image-meta.wasm: ZIG_WASM_MAX_MEMORY = 671088640
application/warc/warc-add-custom-element-scripts.wasm: ZIG_WASM_MAX_MEMORY = 671088640
application/warc/warc-text-uri-list-to-redirect.wasm: ZIG_WASM_MAX_MEMORY = 671088640
application/warc/warc-add-open-graph-image-meta.wasm application/warc/warc-add-custom-element-scripts.wasm application/warc/warc-extract-broken-links.wasm application/warc/warc-text-uri-list-to-redirect.wasm: application/warc/lib/warc.zig
recipes/application/warc/15-add-html-data-path.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/20-add-docs-sidebar.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/25-add-content-size.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/30-add-sitemap-xml.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/35-add-search-index.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/15-add-html-data-path.wasm recipes/application/warc/20-add-docs-sidebar.wasm recipes/application/warc/25-add-content-size.wasm recipes/application/warc/30-add-sitemap-xml.wasm recipes/application/warc/35-add-search-index.wasm: recipes/application/warc/lib/warc.zig
image/gif/gifsicle-optimize.wasm: ZIG_WASM_MAX_MEMORY = 167772160
image/bmp/bmp-rgb-metrics.wasm: ZIG_WASM_MAX_MEMORY = 142606336
multipart/form-data/form-data-to-tar.wasm: ZIG_WASM_MAX_MEMORY = 142606336
image/bmp/bmp-to-png.wasm: ZIG_WASM_MAX_MEMORY = 369098752
image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm: ZIG_WASM_MAX_MEMORY = 369098752
# Full 25 MP level-9 VP8L encoding needs a 1.25 GiB reclaiming arena in
# addition to its input and worst-case output buffers.
image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm: ZIG_WASM_MAX_MEMORY = 1610612736
image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm: ZIG_WASM_MAX_MEMORY = 1610612736
# The module has no memory.grow instruction, so its maximum matches its initial
# memory. Transparent images exercise libwebp's VP8L alpha compressor.
image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm: ZIG_WASM_MAX_MEMORY = 1275068416
image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm: ZIG_WASM_MAX_MEMORY = 1275068416
# The opaque build has no VP8L alpha path and needs only the measured lossy VP8
# arena plus input, output, row scratch, stack, and code.
image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm: ZIG_WASM_MAX_MEMORY = 469762048
image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
# MozJPEG's trellis pass stores image-wide coefficient arrays. The 336 MiB
# arena supports the measured 25 MP 4:4:4 peak within 512 MiB fixed memory.
image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 469762048
image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 469762048
image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 671088640
image/png/png-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 201326592
image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm: ZIG_WASM_MAX_MEMORY = 201326592
image/png/png-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 201326592
image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 268435456
# Progressive JPEG retains image-wide DCT coefficients. The fixed 336 MiB
# MozJPEG arena, input, output, stack, and code fit in this 512 MiB module.
image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 536870912
# Experimental self-contained Zig progressive decoder. It retains quantized
# coefficients and renders two MCU rows at a time, avoiding full sample planes.
image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb-zig-progressive.wasm: ZIG_WASM_MAX_MEMORY = 402653184
image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/ktx2/ktx2-rgba32float-look-warm-fade.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-display-p3-linear-to-ktx2-rgba32float-display-p3.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm: ZIG_WASM_MAX_MEMORY = 335544320
image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm: ZIG_WASM_MAX_MEMORY = 335544320
image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm: ZIG_WASM_MAX_MEMORY = 335544320
image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.wasm: ZIG_WASM_MAX_MEMORY = 335544320
image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3-simd.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-simd.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3-simd.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell-simd.wasm: ZIG_WASM_MAX_MEMORY = 1073741824
image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 268435456
image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 268435456
image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 268435456
image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 268435456
image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm: LCMS_WASM_MAX_MEMORY = 536870912
image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 134217728
image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm: ZIG_WASM_MAX_MEMORY = 134217728
image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm: ZIG_WASM_MAX_MEMORY = 536870912
image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm: ZIG_WASM_MAX_MEMORY = 536870912
application/pdf/pdf-extract-images.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/pdf/pdf-extract-text.wasm: ZIG_WASM_MAX_MEMORY = 335544320
application/pdf/pdf-extract-images.wasm application/pdf/pdf-extract-text.wasm: application/pdf/%.wasm: application/pdf/%.zig bytes/lib/inflate.zig
	$(ZIG_ENV) zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep inflate -Mroot=$< -Minflate=bytes/lib/inflate.zig -femit-bin=$@

LIBWEBP_ROOT := third_party/libwebp-1.6.0
LIBWEBP_DEC_NAMES := alpha_dec buffer_dec frame_dec idec_dec io_dec quant_dec tree_dec vp8_dec vp8l_dec webp_dec
LIBWEBP_DEC_DSP_NAMES := alpha_processing cpu dec dec_clip_tables filters lossless rescaler upsampling yuv
LIBWEBP_DEC_DSP_SIMD_NAMES := alpha_processing_sse2 alpha_processing_sse41 dec_sse2 dec_sse41 filters_sse2 lossless_sse2 lossless_sse41 rescaler_sse2 upsampling_sse2 upsampling_sse41 yuv_sse2 yuv_sse41
LIBWEBP_DEC_UTILS_NAMES := bit_reader_utils color_cache_utils filters_utils huffman_utils palette quant_levels_dec_utils rescaler_utils random_utils thread_utils utils
LIBWEBP_ENC_NAMES := alpha_enc analysis_enc backward_references_cost_enc backward_references_enc config_enc cost_enc filter_enc frame_enc histogram_enc iterator_enc near_lossless_enc picture_enc picture_csp_enc picture_psnr_enc picture_rescale_enc picture_tools_enc predictor_enc quant_enc syntax_enc token_enc tree_enc vp8l_enc webp_enc
LIBWEBP_DSP_NAMES := alpha_processing cpu dec dec_clip_tables filters lossless rescaler upsampling yuv cost enc lossless_enc ssim
LIBWEBP_DSP_SIMD_NAMES := alpha_processing_sse2 alpha_processing_sse41 cost_sse2 dec_sse2 dec_sse41 enc_sse2 enc_sse41 filters_sse2 lossless_sse2 lossless_sse41 lossless_enc_sse2 lossless_enc_sse41 rescaler_sse2 ssim_sse2 upsampling_sse2 upsampling_sse41 yuv_sse2 yuv_sse41
LIBWEBP_UTILS_NAMES := bit_reader_utils color_cache_utils filters_utils huffman_utils palette quant_levels_dec_utils rescaler_utils random_utils thread_utils utils bit_writer_utils huffman_encode_utils quant_levels_utils
LIBWEBP_SHARPYUV_NAMES := sharpyuv_cpu sharpyuv_csp sharpyuv_dsp sharpyuv_gamma sharpyuv
LIBWEBP_C_SOURCES := $(addprefix $(LIBWEBP_ROOT)/src/enc/,$(addsuffix .c,$(LIBWEBP_ENC_NAMES)))
LIBWEBP_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/src/dsp/,$(addsuffix .c,$(LIBWEBP_DSP_NAMES)))
LIBWEBP_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/src/utils/,$(addsuffix .c,$(LIBWEBP_UTILS_NAMES)))
LIBWEBP_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/sharpyuv/,$(addsuffix .c,$(LIBWEBP_SHARPYUV_NAMES)))
LIBWEBP_SIMD_C_SOURCES := $(LIBWEBP_C_SOURCES)
# Equivalent to libwebp's WEBP_ENABLE_SIMD=1 CMake build: Emscripten maps the
# upstream SSE2/SSE4.1 implementations to WebAssembly SIMD instructions.
LIBWEBP_SIMD_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/src/dsp/,$(addsuffix .c,$(LIBWEBP_DSP_SIMD_NAMES)))
LIBWEBP_SIMD_C_SOURCES += $(LIBWEBP_ROOT)/sharpyuv/sharpyuv_sse2.c
LIBWEBP_OPAQUE_C_SOURCES := $(filter-out $(LIBWEBP_ROOT)/src/enc/alpha_enc.c,$(LIBWEBP_SIMD_C_SOURCES))
LIBWEBP_OPAQUE_C_SOURCES += $(LIBWEBP_ROOT)/qip-opaque-alpha-stub.c
LIBWEBP_DEC_C_SOURCES := $(addprefix $(LIBWEBP_ROOT)/src/dec/,$(addsuffix .c,$(LIBWEBP_DEC_NAMES)))
LIBWEBP_DEC_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/src/dsp/,$(addsuffix .c,$(LIBWEBP_DEC_DSP_NAMES)))
LIBWEBP_DEC_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/src/dsp/,$(addsuffix .c,$(LIBWEBP_DEC_DSP_SIMD_NAMES)))
LIBWEBP_DEC_C_SOURCES += $(addprefix $(LIBWEBP_ROOT)/src/utils/,$(addsuffix .c,$(LIBWEBP_DEC_UTILS_NAMES)))

OPENJPEG_ROOT := third_party/openjpeg-2.5.4
OPENJPEG_LIB_ROOT := $(OPENJPEG_ROOT)/src/lib/openjp2
OPENJPEG_DEC_NAMES := thread bio cio dwt event ht_dec image invert j2k jp2 mct mqc openjpeg opj_clock pi t1 t2 tcd tgt function_list opj_malloc sparse_array
OPENJPEG_DEC_C_SOURCES := $(addprefix $(OPENJPEG_LIB_ROOT)/,$(addsuffix .c,$(OPENJPEG_DEC_NAMES)))

THORVG_ROOT := third_party/thorvg-1.1.1
THORVG_COMMON_NAMES := tvgCompressor tvgMath tvgStr
THORVG_RENDERER_NAMES := tvgAccessor tvgAnimation tvgCanvas tvgFill tvgInitializer tvgLoaderMgr tvgPaint tvgPicture tvgRender tvgSaver tvgScene tvgShape tvgTaskScheduler tvgText
THORVG_CPU_NAMES := tvgSwBlendOp tvgSwFill tvgSwImage tvgSwMemPool tvgSwPostEffect tvgSwRaster tvgSwRenderer tvgSwRle tvgSwShape tvgSwStroke tvgSwUtil
THORVG_SVG_NAMES := tvgSvgBuilder tvgSvgCssStyle tvgSvgLoader tvgSvgPath tvgSvgUtil tvgXmlParser
THORVG_CPP_SOURCES := $(addprefix $(THORVG_ROOT)/src/common/,$(addsuffix .cpp,$(THORVG_COMMON_NAMES)))
THORVG_CPP_SOURCES += $(addprefix $(THORVG_ROOT)/src/renderer/,$(addsuffix .cpp,$(THORVG_RENDERER_NAMES)))
THORVG_CPP_SOURCES += $(addprefix $(THORVG_ROOT)/src/renderer/cpu_engine/,$(addsuffix .cpp,$(THORVG_CPU_NAMES)))
THORVG_CPP_SOURCES += $(addprefix $(THORVG_ROOT)/src/loaders/svg/,$(addsuffix .cpp,$(THORVG_SVG_NAMES)))
THORVG_CPP_SOURCES += $(THORVG_ROOT)/src/loaders/raw/tvgRawLoader.cpp

LIBAVIF_ROOT := third_party/libavif-1.4.1
LIBAOM_ROOT := third_party/libaom-3.13.0
MOZJPEG_ROOT := third_party/mozjpeg-4.1.1
AVIF_COMPAT_ROOT := third_party/qip-avif-compat
LCMS_ROOT := third_party/lcms2-2.19.1
LCMS_C_SOURCES := $(addprefix $(LCMS_ROOT)/src/,cmsalpha.c cmscam02.c cmscgats.c cmscnvrt.c cmserr.c cmsgamma.c cmsgmt.c cmsintrp.c cmsio0.c cmsio1.c cmslut.c cmsplugin.c cmssm.c cmsmd5.c cmsmtrx.c cmspack.c cmspcs.c cmswtpnt.c cmsxform.c cmssamp.c cmsnamed.c cmsvirt.c cmstypes.c cmsps2.c cmsopt.c cmshalf.c)
AVIF_AOM_SOURCE_FILES := $(shell find $(LIBAOM_ROOT) -type f)
AVIF_LIBAVIF_SOURCE_FILES := $(shell find $(LIBAVIF_ROOT) -type f)

EMSDK_VERSION ?= 2.0.34
EMCC_CACHE ?= $(CURDIR)/tmp/qip-emcc-$(EMSDK_VERSION)-cache
EMSDK_ROOT ?= $(shell mise where emsdk@$(EMSDK_VERSION) 2>/dev/null)
EMSDK_UPSTREAM := $(EMSDK_ROOT)/upstream
EMSDK_SYSROOT := $(EMCC_CACHE)/sysroot
EMSDK_LTO_LIBDIR := $(EMSDK_SYSROOT)/lib/wasm32-emscripten/lto
EMSDK_LIBDIR := $(EMSDK_SYSROOT)/lib/wasm32-emscripten
EMSDK_LTO_STAMP := $(EMCC_CACHE)/qip-lto-system-libs.stamp
EMSDK_CLANG := $(EMSDK_UPSTREAM)/bin/clang
EMSDK_WASM_OPT := $(EMSDK_UPSTREAM)/bin/wasm-opt
EMSDK_EMBUILDER := env EM_CACHE=$(EMCC_CACHE) $(EMSDK_UPSTREAM)/emscripten/embuilder.py
EMSDK_EMCMAKE := env EM_CACHE=$(EMCC_CACHE) $(EMSDK_UPSTREAM)/emscripten/emcmake
LIBWEBP_CLANG_RAW_WASM := $(EMCC_CACHE)/bmp-b8g8r8a8-srgb-to-webp-lossy.raw.wasm
LIBWEBP_OPAQUE_CLANG_RAW_WASM := $(EMCC_CACHE)/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.raw.wasm
LIBWEBP_LOSSLESS_CLANG_RAW_WASM := $(EMCC_CACHE)/bmp-b8g8r8a8-srgb-to-webp-lossless.raw.wasm
LIBWEBP_DEC_CLANG_RAW_WASM := $(EMCC_CACHE)/webp-to-bmp-b8g8r8a8-srgb.raw.wasm
LIBWEBP_KTX_LOSSY_CLANG_RAW_WASM := $(EMCC_CACHE)/ktx2-r8g8b8a8-srgb-to-webp-lossy.raw.wasm
LIBWEBP_KTX_LOSSLESS_CLANG_RAW_WASM := $(EMCC_CACHE)/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.raw.wasm
LIBWEBP_KTX_DEC_CLANG_RAW_WASM := $(EMCC_CACHE)/webp-to-ktx2-r8g8b8a8-srgb.raw.wasm
OPENJPEG_DEC_CLANG_RAW_WASM := $(EMCC_CACHE)/jp2-to-bmp-b8g8r8a8-srgb.raw.wasm
THORVG_SVG_CLANG_RAW_WASM := $(EMCC_CACHE)/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.raw.wasm
AVIF_AOM_BUILD := $(EMCC_CACHE)/libaom-3.13.0-qip-encode-decode
AVIF_LIBAVIF_BUILD := $(EMCC_CACHE)/libavif-1.4.1-qip-encode-decode
AVIF_AOM_STAMP := $(EMCC_CACHE)/qip-libaom-3.13.0-encode-decode.stamp
AVIF_LIBAVIF_STAMP := $(EMCC_CACHE)/qip-libavif-1.4.1-encode-decode.stamp
AVIF_CLANG_RAW_WASM := $(EMCC_CACHE)/bmp-b8g8r8a8-srgb-to-avif-lossy.raw.wasm
AVIF_KTX_CLANG_RAW_WASM := $(EMCC_CACHE)/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.raw.wasm
AVIF_DEC_KTX_CLANG_RAW_WASM := $(EMCC_CACHE)/avif-to-ktx2-r8g8b8a8-srgb.raw.wasm
MOZJPEG_BUILD := $(EMCC_CACHE)/mozjpeg-4.1.1-qip
MOZJPEG_STAMP := $(EMCC_CACHE)/qip-mozjpeg-4.1.1.stamp
MOZJPEG_CLANG_RAW_WASM := $(EMCC_CACHE)/bmp-b8g8r8a8-srgb-to-jpeg-lossy.raw.wasm
MOZJPEG_KTX_CLANG_RAW_WASM := $(EMCC_CACHE)/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.raw.wasm
MOZJPEG_DEC_KTX_CLANG_RAW_WASM := $(EMCC_CACHE)/jpeg-to-ktx2-r8g8b8a8-srgb.raw.wasm
LCMS_CLANG_RAW_WASM := $(EMCC_CACHE)/bmp-b8g8r8a8-icc-to-srgb.raw.wasm
LIBWEBP_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size uniform_set_quality uniform_set_method uniform_set_sharp_yuv uniform_set_low_memory arena_peak_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_null_count arena_free_matched_count arena_free_unmatched_count arena_freed_bytes arena_allocation_size arena_allocation_event arena_allocation_free_event
LIBWEBP_CLANG_EXPORT_FLAGS := $(foreach name,$(LIBWEBP_CLANG_EXPORTS),-Xlinker --export=$(name))
LIBWEBP_OPAQUE_CLANG_EXPORTS := $(LIBWEBP_CLANG_EXPORTS) uniform_set_background_color_rgb
LIBWEBP_OPAQUE_CLANG_EXPORT_FLAGS := $(foreach name,$(LIBWEBP_OPAQUE_CLANG_EXPORTS),-Xlinker --export=$(name))
LIBWEBP_LOSSLESS_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size uniform_set_level arena_peak_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_null_count arena_free_matched_count arena_free_unmatched_count arena_freed_bytes arena_search_steps arena_max_search_steps arena_allocation_size arena_allocation_offset arena_allocation_event arena_allocation_free_event
LIBWEBP_LOSSLESS_CLANG_EXPORT_FLAGS := $(foreach name,$(LIBWEBP_LOSSLESS_CLANG_EXPORTS),-Xlinker --export=$(name))
LIBWEBP_DEC_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size arena_peak_bytes arena_live_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_unmatched_count
LIBWEBP_DEC_CLANG_EXPORT_FLAGS := $(foreach name,$(LIBWEBP_DEC_CLANG_EXPORTS),-Xlinker --export=$(name))
OPENJPEG_DEC_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size arena_peak_bytes arena_live_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_unmatched_count
OPENJPEG_DEC_CLANG_EXPORT_FLAGS := $(foreach name,$(OPENJPEG_DEC_CLANG_EXPORTS),-Xlinker --export=$(name))
OPENJPEG_CLANG_FEATURE_FLAGS = $(LIBWEBP_CLANG_FEATURE_FLAGS)
THORVG_SVG_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size uniform_set_width uniform_set_height uniform_set_background_color_rgba arena_peak_bytes arena_live_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_unmatched_count __wasm_call_ctors
THORVG_SVG_CLANG_EXPORT_FLAGS := $(foreach name,$(THORVG_SVG_CLANG_EXPORTS),-Xlinker --export=$(name))
THORVG_INCLUDE_FLAGS := -I$(THORVG_ROOT)/qip -I$(THORVG_ROOT)/inc -I$(THORVG_ROOT)/src/common -I$(THORVG_ROOT)/src/renderer -I$(THORVG_ROOT)/src/renderer/cpu_engine -I$(THORVG_ROOT)/src/loaders -I$(THORVG_ROOT)/src/loaders/svg -I$(THORVG_ROOT)/src/loaders/raw -Iimage/lib
THORVG_CLANG_FLAGS := -std=c++14 -O3 -ffunction-sections -fdata-sections -msimd128 -mbulk-memory -fno-exceptions -fno-rtti -fno-threadsafe-statics -fno-stack-protector -fno-math-errno -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -fno-builtin-memcpy -U__STDCPP_THREADS__ -D_LIBCPP_ABI_VERSION=2 -DTVG_STATIC -DNDEBUG
LIBWEBP_CLANG_FEATURE_FLAGS := -msimd128 -mbulk-memory -DEMSCRIPTEN=1 -D__SSE__=1 -D__SSE2__=1 -D__SSE3__=1 -D__SSSE3__=1 -D__SSE4_1__=1

AVIF_CMAKE_C_FLAGS := -I$(AVIF_COMPAT_ROOT) -O3 -DNDEBUG -flto -ffunction-sections -fdata-sections -msimd128 -mbulk-memory -fno-builtin-setjmp -fno-builtin-longjmp -sSUPPORT_LONGJMP=0
AVIF_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size uniform_set_quality uniform_set_quality_alpha uniform_set_speed uniform_set_subsample arena_peak_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_matched_count arena_free_unmatched_count
AVIF_CLANG_EXPORT_FLAGS := $(foreach name,$(AVIF_CLANG_EXPORTS),-Xlinker --export=$(name))
AVIF_DEC_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size arena_peak_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_matched_count arena_free_unmatched_count
AVIF_DEC_CLANG_EXPORT_FLAGS := $(foreach name,$(AVIF_DEC_CLANG_EXPORTS),-Xlinker --export=$(name))
MOZJPEG_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size uniform_set_quality uniform_set_subsample uniform_set_background_color_rgb arena_peak_bytes arena_live_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_unmatched_count
MOZJPEG_CLANG_EXPORT_FLAGS := $(foreach name,$(MOZJPEG_CLANG_EXPORTS),-Xlinker --export=$(name))
MOZJPEG_DEC_KTX_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size
MOZJPEG_DEC_KTX_CLANG_EXPORT_FLAGS := $(foreach name,$(MOZJPEG_DEC_KTX_CLANG_EXPORTS),-Xlinker --export=$(name))
MOZJPEG_CMAKE_C_FLAGS := -O3 -DNDEBUG -DQIP_FREESTANDING=1 -flto -ffunction-sections -fdata-sections -mbulk-memory -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free
AVIF_CLANG_WRAP_NAMES := fopen fclose fread fwrite fseek feof fputc fscanf fiprintf __small_fprintf
AVIF_CLANG_WRAP_FLAGS := $(foreach name,$(AVIF_CLANG_WRAP_NAMES),-Xlinker --wrap=$(name))
LCMS_CLANG_EXPORTS := render input_ptr input_bytes_cap output_bytes_cap input_content_type_ptr input_content_type_size output_content_type_ptr output_content_type_size arena_peak_bytes arena_allocation_count arena_largest_allocation arena_failed_allocation arena_free_count arena_free_matched_count arena_free_unmatched_count
LCMS_CLANG_EXPORT_FLAGS := $(foreach name,$(LCMS_CLANG_EXPORTS),-Xlinker --export=$(name))
LCMS_CLANG_FEATURE_FLAGS := -msimd128 -mbulk-memory -DCMS_NO_PTHREADS=1
LCMS_CLANG_WRAP_NAMES := fopen fclose fread fwrite fseek ftell feof ferror fflush remove
LCMS_CLANG_WRAP_FLAGS := $(foreach name,$(LCMS_CLANG_WRAP_NAMES),-Xlinker --wrap=$(name))

$(EMSDK_LTO_STAMP):
	mkdir -p $(EMCC_CACHE)
	$(EMSDK_EMBUILDER) build sysroot
	$(EMSDK_EMBUILDER) build libc++-noexcept libc++abi-noexcept
	$(EMSDK_EMBUILDER) --lto build libc libcompiler_rt libc_rt_wasm libstandalonewasm
	touch $@

$(LIBWEBP_CLANG_RAW_WASM): image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.c $(LIBWEBP_SIMD_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib $(filter %.c,$^) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm: $(LIBWEBP_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(LIBWEBP_OPAQUE_CLANG_RAW_WASM): image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.c $(LIBWEBP_OPAQUE_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DWEBP_OPAQUE_ONLY=1 -DNDEBUG -nostdlib $(filter %.c,$^) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_OPAQUE_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm: $(LIBWEBP_OPAQUE_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(LIBWEBP_LOSSLESS_CLANG_RAW_WASM): image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.c $(LIBWEBP_SIMD_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib $(filter %.c,$^) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_LOSSLESS_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm: $(LIBWEBP_LOSSLESS_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(LIBWEBP_KTX_LOSSY_CLANG_RAW_WASM): image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.c image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.c image/lib/ktx2-rgba8-srgb.h $(LIBWEBP_SIMD_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib $< $(LIBWEBP_SIMD_C_SOURCES) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm: $(LIBWEBP_KTX_LOSSY_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(LIBWEBP_KTX_LOSSLESS_CLANG_RAW_WASM): image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.c image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.c image/lib/ktx2-rgba8-srgb.h $(LIBWEBP_SIMD_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib $< $(LIBWEBP_SIMD_C_SOURCES) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_LOSSLESS_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm: $(LIBWEBP_KTX_LOSSLESS_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(LIBWEBP_DEC_CLANG_RAW_WASM): image/webp/webp-to-bmp-b8g8r8a8-srgb.c $(LIBWEBP_DEC_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib $(filter %.c,$^) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_DEC_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm: $(LIBWEBP_DEC_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(LIBWEBP_KTX_DEC_CLANG_RAW_WASM): image/webp/webp-to-ktx2-r8g8b8a8-srgb.c image/webp/webp-to-bmp-b8g8r8a8-srgb.c image/lib/ktx2-rgba8-srgb.h $(LIBWEBP_DEC_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBWEBP_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-free $(LIBWEBP_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib $< $(LIBWEBP_DEC_C_SOURCES) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LIBWEBP_DEC_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm: $(LIBWEBP_KTX_DEC_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(OPENJPEG_DEC_CLANG_RAW_WASM): image/jp2/jp2-to-bmp-b8g8r8a8-srgb.c $(OPENJPEG_DEC_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(OPENJPEG_LIB_ROOT) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free $(OPENJPEG_CLANG_FEATURE_FLAGS) -DOPJ_STATIC -DMUTEX_stub -DNDEBUG -nostdlib $(filter %.c,$^) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(OPENJPEG_DEC_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm: $(OPENJPEG_DEC_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(THORVG_SVG_CLANG_RAW_WASM): image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.cpp image/lib/ktx2-rgba8-srgb.h $(THORVG_CPP_SOURCES) $(THORVG_ROOT)/qip/config.h $(THORVG_ROOT)/src/common/tvgLock.h $(THORVG_ROOT)/src/renderer/tvgLoader.h $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) $(THORVG_INCLUDE_FLAGS) $(THORVG_CLANG_FLAGS) -nostdlib -Wl,--gc-sections $< $(THORVG_CPP_SOURCES) -L$(EMSDK_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=536870912 -Wl,--max-memory=536870912 $(WASM_STACK_FLAG) $(THORVG_SVG_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc++-noexcept -lc++abi-noexcept -lc_rt_wasm -o $@

image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm: $(THORVG_SVG_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(AVIF_AOM_STAMP): $(AVIF_AOM_SOURCE_FILES) $(AVIF_COMPAT_ROOT)/setjmp.h
	rm -rf $(AVIF_AOM_BUILD)
	$(EMSDK_EMCMAKE) cmake -S $(LIBAOM_ROOT) -B $(AVIF_AOM_BUILD) -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DAOM_TARGET_CPU=generic -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_NASM=OFF -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 -DCONFIG_MULTITHREAD=0 -DCONFIG_RUNTIME_CPU_DETECT=0 -DCONFIG_WEBM_IO=0 -DCONFIG_ACCOUNTING=0 -DCONFIG_INSPECTION=0 -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS='$(AVIF_CMAKE_C_FLAGS)'
	env EM_CACHE=$(EMCC_CACHE) cmake --build $(AVIF_AOM_BUILD) --target aom
	touch $@

$(AVIF_LIBAVIF_STAMP): $(AVIF_LIBAVIF_SOURCE_FILES) $(AVIF_AOM_STAMP) $(AVIF_COMPAT_ROOT)/setjmp.h
	rm -rf $(AVIF_LIBAVIF_BUILD)
	$(EMSDK_EMCMAKE) cmake -S $(LIBAVIF_ROOT) -B $(AVIF_LIBAVIF_BUILD) -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=ON -DAVIF_CODEC_AOM_ENCODE=ON -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAOM_INCLUDE_DIR=$(LIBAOM_ROOT) -DAOM_LIBRARY=$(AVIF_AOM_BUILD)/libaom.a -DCMAKE_C_FLAGS='$(AVIF_CMAKE_C_FLAGS)'
	env EM_CACHE=$(EMCC_CACHE) cmake --build $(AVIF_LIBAVIF_BUILD) --target avif_static
	touch $@

$(AVIF_CLANG_RAW_WASM): image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.c $(AVIF_LIBAVIF_STAMP) $(AVIF_AOM_STAMP) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(AVIF_COMPAT_ROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBAVIF_ROOT)/include -I$(LIBAOM_ROOT) -I$(AVIF_AOM_BUILD) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -fno-builtin-setjmp -fno-builtin-longjmp -DNDEBUG -nostdlib -Wl,--gc-sections $(AVIF_CLANG_WRAP_FLAGS) $< $(AVIF_LIBAVIF_BUILD)/libavif_internal.a $(AVIF_AOM_BUILD)/libaom.a -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(AVIF_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm: $(AVIF_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(AVIF_KTX_CLANG_RAW_WASM): image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.c image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.c image/lib/ktx2-rgba8-srgb.h $(AVIF_LIBAVIF_STAMP) $(AVIF_AOM_STAMP) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(AVIF_COMPAT_ROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBAVIF_ROOT)/include -I$(LIBAOM_ROOT) -I$(AVIF_AOM_BUILD) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -fno-builtin-setjmp -fno-builtin-longjmp -DNDEBUG -nostdlib -Wl,--gc-sections $(AVIF_CLANG_WRAP_FLAGS) $< $(AVIF_LIBAVIF_BUILD)/libavif_internal.a $(AVIF_AOM_BUILD)/libaom.a -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(AVIF_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm: $(AVIF_KTX_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(AVIF_DEC_KTX_CLANG_RAW_WASM): image/avif/avif-to-ktx2-r8g8b8a8-srgb.c image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.c image/lib/ktx2-rgba8-srgb.h $(AVIF_LIBAVIF_STAMP) $(AVIF_AOM_STAMP) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(AVIF_COMPAT_ROOT) -isystem $(EMSDK_SYSROOT)/include/compat -I$(LIBAVIF_ROOT)/include -I$(LIBAOM_ROOT) -I$(AVIF_AOM_BUILD) -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -fno-builtin-setjmp -fno-builtin-longjmp -DNDEBUG -nostdlib -Wl,--gc-sections $(AVIF_CLANG_WRAP_FLAGS) $< $(AVIF_LIBAVIF_BUILD)/libavif_internal.a $(AVIF_AOM_BUILD)/libaom.a -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(AVIF_DEC_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm: $(AVIF_DEC_KTX_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(MOZJPEG_STAMP): $(shell find $(MOZJPEG_ROOT) -type f) $(EMSDK_LTO_STAMP)
	rm -rf $(MOZJPEG_BUILD)
	$(EMSDK_EMCMAKE) cmake -S $(MOZJPEG_ROOT) -B $(MOZJPEG_BUILD) -G 'Unix Makefiles' -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DWITH_12BIT=OFF -DWITH_ARITH_ENC=OFF -DWITH_ARITH_DEC=OFF -DPNG_SUPPORTED=OFF -DCMAKE_C_FLAGS='$(MOZJPEG_CMAKE_C_FLAGS)'
	env EM_CACHE=$(EMCC_CACHE) cmake --build $(MOZJPEG_BUILD) --target jpeg-static
	touch $@

$(MOZJPEG_CLANG_RAW_WASM): image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.c $(MOZJPEG_STAMP) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(MOZJPEG_BUILD) -I$(MOZJPEG_ROOT) -isystem $(EMSDK_SYSROOT)/include/compat -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -mbulk-memory -DNDEBUG -nostdlib -Wl,--gc-sections $< $(MOZJPEG_BUILD)/libjpeg.a -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(MOZJPEG_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm: $(MOZJPEG_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(MOZJPEG_KTX_CLANG_RAW_WASM): image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.c image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.c image/lib/ktx2-rgba8-srgb.h $(MOZJPEG_STAMP) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(MOZJPEG_BUILD) -I$(MOZJPEG_ROOT) -isystem $(EMSDK_SYSROOT)/include/compat -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -mbulk-memory -DNDEBUG -nostdlib -Wl,--gc-sections $< $(MOZJPEG_BUILD)/libjpeg.a -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(MOZJPEG_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm: $(MOZJPEG_KTX_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-bulk-memory --strip-debug --strip-producers $< -o $@

$(MOZJPEG_DEC_KTX_CLANG_RAW_WASM): image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.c image/lib/ktx2-rgba8-srgb.h $(MOZJPEG_STAMP) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(MOZJPEG_BUILD) -I$(MOZJPEG_ROOT) -isystem $(EMSDK_SYSROOT)/include/compat -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free -mbulk-memory -DNDEBUG -nostdlib -Wl,--gc-sections $< $(MOZJPEG_BUILD)/libjpeg.a -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(MOZJPEG_DEC_KTX_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm: $(MOZJPEG_DEC_KTX_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-bulk-memory --strip-debug --strip-producers $< -o $@

image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb-zig-progressive.wasm: image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

$(LCMS_CLANG_RAW_WASM): image/bmp/bmp-b8g8r8a8-icc-to-srgb.c $(LCMS_C_SOURCES) $(EMSDK_LTO_STAMP)
	$(EMSDK_CLANG) --target=wasm32-unknown-emscripten --sysroot=$(EMSDK_SYSROOT) -I$(LCMS_ROOT)/include -I$(LCMS_ROOT)/src -isystem $(EMSDK_SYSROOT)/include/compat -O3 -flto -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free $(LCMS_CLANG_FEATURE_FLAGS) -DNDEBUG -nostdlib -Wl,--gc-sections $(LCMS_CLANG_WRAP_FLAGS) $(filter %.c,$^) -L$(EMSDK_LTO_LIBDIR) -Wl,--no-entry -Wl,--initial-memory=$(LCMS_WASM_MAX_MEMORY) -Wl,--max-memory=$(LCMS_WASM_MAX_MEMORY) $(WASM_STACK_FLAG) $(LCMS_CLANG_EXPORT_FLAGS) -lc -lcompiler_rt -lc_rt_wasm -lstandalonewasm -o $@

image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm: $(LCMS_CLANG_RAW_WASM)
	$(EMSDK_WASM_OPT) -O3 --enable-simd --enable-bulk-memory --strip-debug --strip-producers $< -o $@

text/unicode-17-lowercase.wasm: text/lib/unicode-17-lowercase-tables.zig text/lib/utf8.zig
text/unicode-17-uppercase.wasm: text/lib/unicode-17-uppercase-tables.zig text/lib/utf8.zig
text/iso-4217-alpha-to-numeric.wasm: text/lib/iso-4217-alpha-numeric-table.zig

bytes/zlib-compress-dynamic-huffman-opt.wasm: bytes/lib/deflate.zig
image/bmp/bmp-to-png.wasm: image/bmp/lib/deflate.zig
image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm: image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.zig image/bmp/bmp-to-png.zig image/bmp/lib/deflate.zig image/lib/ktx2-rgba8-srgb.zig image/lib/ktx2-bgra8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep png_encoder_impl -Mroot=$< --dep ktx2_rgba8_srgb --dep ktx2_bgra8_srgb -Mpng_encoder_impl=image/bmp/bmp-to-png.zig -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_bgra8_srgb=image/lib/ktx2-bgra8-srgb.zig -femit-bin=$@
bytes/zlib-decompress.wasm: bytes/lib/inflate.zig bytes/lib/deflate.zig
image/png/png-to-bmp-b8g8r8a8-srgb.wasm image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm: image/png/lib/inflate.zig image/png/lib/deflate.zig
image/png/png-to-ktx2-r8g8b8a8-srgb.wasm: image/png/png-to-ktx2-r8g8b8a8-srgb.zig image/png/png-to-bmp-b8g8r8a8-srgb.zig image/png/lib/inflate.zig image/png/lib/deflate.zig image/lib/ktx2-rgba8-srgb.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep ktx2_rgba8_srgb -Mroot=$< -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -femit-bin=$@

text/html/html-to-svg-inter-paths.wasm: text/html/html-to-svg-inter-paths.zig text/lib/inter_display_latin_paths.zig text/lib/inter_display_bold_latin_paths.zig
	$(ZIG_ENV) zig build-exe $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) --dep inter_regular --dep inter_bold -Mroot=$< -Minter_regular=text/lib/inter_display_latin_paths.zig -Minter_bold=text/lib/inter_display_bold_latin_paths.zig -femit-bin=$@

define COMPONENT_C_RULE
$(1)/%.wasm: $(1)/%.c
	$$(ZIG_ENV) zig cc $$< -target wasm32-freestanding -nostdlib -Wl,--no-entry $$(WASM_STACK_FLAG) -Wl,--max-memory=$$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_utf8_cap -Oz -o $$@
endef
$(foreach dir,$(COMPONENT_DIRS),$(eval $(call COMPONENT_C_RULE,$(dir))))

define COMPONENT_ZIG_RULE
$(1)/%.wasm: $(1)/%.zig
	$$(ZIG_ENV) zig build-exe $$< $$(ZIG_WASM_FLAGS) --max-memory=$$(ZIG_WASM_MAX_MEMORY) -femit-bin=$$@
endef
$(foreach dir,$(COMPONENT_DIRS),$(eval $(call COMPONENT_ZIG_RULE,$(dir))))

text/hello-odin.wasm: text/hello-odin.odin
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -extra-linker-flags:"--max-memory=$(ODIN_WASM_MAX_MEMORY)" -out:$@

text/wc-odin.wasm: ODIN_WASM_MAX_MEMORY = 6291456
text/wc-odin.wasm: text/wc-odin.odin
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -extra-linker-flags:"--max-memory=$(ODIN_WASM_MAX_MEMORY)" -out:$@

text/shortcode-to-emoji-odin.wasm: text/shortcode-to-emoji-odin.odin
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -extra-linker-flags:"--max-memory=$(ODIN_WASM_MAX_MEMORY)" -out:$@

text/utf8-must-be-valid-odin.wasm: ODIN_WASM_MAX_MEMORY = 3145728
text/utf8-must-be-valid-odin.wasm: text/utf8-must-be-valid-odin.odin
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -extra-linker-flags:"--max-memory=$(ODIN_WASM_MAX_MEMORY)" -out:$@

image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-odin-simd.wasm: ODIN_WASM_MAX_MEMORY = 1073741824
image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-odin-simd.wasm: image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-odin-simd.odin
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -o:speed -strict-target-features -target-features:simd128 -extra-linker-flags:"--max-memory=$(ODIN_WASM_MAX_MEMORY)" -out:$@

image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear-odin.wasm: ODIN_WASM_MAX_MEMORY = 134217728
image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear-odin.wasm: image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear.odin
	odin build $< -file -target:freestanding_wasm32 -no-entry-point -no-bounds-check -o:speed -extra-linker-flags:"--max-memory=$(ODIN_WASM_MAX_MEMORY)" -out:$@

recipes/%.wasm: recipes/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

recipes/application/warc/10-add-open-graph-image-meta.wasm: application/warc/warc-add-open-graph-image-meta.wasm
	@mkdir -p $(dir $@)
	ln -sf ../../../application/warc/warc-add-open-graph-image-meta.wasm $@

recipes/application/warc/05-text-uri-list-to-redirect.wasm: application/warc/warc-text-uri-list-to-redirect.wasm
	@mkdir -p $(dir $@)
	ln -sf ../../../application/warc/warc-text-uri-list-to-redirect.wasm $@

recipes/application/warc/99-add-custom-element-scripts.wasm: application/warc/warc-add-custom-element-scripts.wasm
	ln -sf ../../../application/warc/warc-add-custom-element-scripts.wasm $@

components-wat-wasm: $(COMPONENT_WAT_TARGETS)
components-c-wasm: $(COMPONENT_C_TARGETS)
components-zig-wasm: $(COMPONENT_ZIG_TARGETS)
components-zig-wasm: text/markdown/markdown-basic.wasm
components-zig-wasm: text/html/html-page-wrap.wasm
components-zig-wasm: recipes/text/markdown/10-markdown-basic.wasm
components-zig-wasm: recipes/text/markdown/80-html-page-wrap.wasm
components-rust-wasm: application/wasm/wasm-validate-core-2.0.wasm

recipes: $(patsubst recipes/text/markdown/%.zig,recipes/text/markdown/%.wasm,$(wildcard recipes/text/markdown/*.zig))
recipes: $(patsubst recipes/application/warc/%.zig,recipes/application/warc/%.wasm,$(wildcard recipes/application/warc/*.zig))
recipes: recipes/application/warc/05-text-uri-list-to-redirect.wasm
recipes: recipes/application/warc/10-add-open-graph-image-meta.wasm
recipes: recipes/application/warc/99-add-custom-element-scripts.wasm
recipes: recipes/text/markdown/17-html-code-syntax-highlight-go.wasm
recipes: recipes/text/markdown/18-html-code-syntax-highlight-ruby.wasm
recipes: recipes/text/markdown/19-html-code-syntax-highlight-swift.wasm
recipes: recipes/text/markdown/23-html-code-syntax-highlight-tsx.wasm
recipes: recipes/text/markdown/24-html-code-syntax-highlight-html.wasm
recipes: recipes/text/markdown/28-html-code-syntax-highlight-css.wasm
recipes: recipes/text/markdown/29-add-highlight-stylesheet-night-owl.wasm

components: components-wat-wasm components-c-wasm components-zig-wasm components-rust-wasm

test: qip components test-go test-node test-zig test-snapshot test-comply test-markdown-pathological test-warc-libs test-qip-component-to-c test-qip-component-to-zig test-qip-component-to-swift test-qip-router-help

test-wasm-core-1-spec: application/wasm/wasm-validate-core-1.0.wasm
	@test -n "$(WASM_CORE_1_0_SPEC_DIR)" || (echo "set WASM_CORE_1_0_SPEC_DIR to the WebAssembly spec wg-1.0 checkout" && exit 1)
	node test/wasm-validate-core-1.0-spec.mjs $(WASM_CORE_1_0_SPEC_DIR)

test-wasm-core-2-spec: application/wasm/wasm-validate-core-2.0.wasm
	@test -n "$(WASM_CORE_2_0_SPEC_DIR)" || (echo "set WASM_CORE_2_0_SPEC_DIR to the WebAssembly spec wg-2.0 checkout" && exit 1)
	node test/wasm-validate-core-2.0-spec.mjs $(WASM_CORE_2_0_SPEC_DIR)

test-markdown-pathological: qip text/markdown/gfm-commonmark.0.31.2.wasm
	QIP_BIN=$(QIP_BIN) tools/test-markdown-pathological.sh

test-qip-component-to-c: qip application/wasm/qip-component-to-c.wasm
	wat2wasm test/fixtures/qip-component-to-c-traps.wat -o test/fixtures/qip-component-to-c-traps.wasm
	QIP_BIN=$(QIP_BIN) sh test/qip-component-to-c.sh

test-qip-component-to-zig: qip application/wasm/qip-component-to-zig.wasm
	wat2wasm test/fixtures/qip-component-to-zig-traps.wat -o test/fixtures/qip-component-to-zig-traps.wasm
	wat2wasm test/fixtures/qip-component-to-zig-direct.wat -o test/fixtures/qip-component-to-zig-direct.wasm
	wat2wasm test/fixtures/qip-component-to-zig-floats.wat -o test/fixtures/qip-component-to-zig-floats.wasm
	wat2wasm test/fixtures/qip-component-to-zig-float-traps.wat -o test/fixtures/qip-component-to-zig-float-traps.wasm
	wat2wasm test/fixtures/qip-component-to-zig-indirect.wat -o test/fixtures/qip-component-to-zig-indirect.wasm
	QIP_BIN=$(QIP_BIN) sh test/qip-component-to-zig.sh

test-qip-component-to-swift: qip application/wasm/qip-component-to-swift.wasm
	wat2wasm test/fixtures/qip-component-to-zig-traps.wat -o test/fixtures/qip-component-to-zig-traps.wasm
	wat2wasm test/fixtures/qip-component-to-zig-direct.wat -o test/fixtures/qip-component-to-zig-direct.wasm
	wat2wasm test/fixtures/qip-component-to-zig-floats.wat -o test/fixtures/qip-component-to-zig-floats.wasm
	wat2wasm test/fixtures/qip-component-to-zig-float-traps.wat -o test/fixtures/qip-component-to-zig-float-traps.wasm
	wat2wasm test/fixtures/qip-component-to-zig-indirect.wat -o test/fixtures/qip-component-to-zig-indirect.wasm
	QIP_BIN=$(QIP_BIN) sh test/qip-component-to-swift.sh

# Large generated Swift functions make this test take several minutes. Keep it
# separate from the routine test target until the backend splits function bodies.
test-qip-component-to-swift-complex: qip application/wasm/qip-component-to-swift.wasm site-static/_og/index.png
	QIP_BIN=$(QIP_BIN) sh test/qip-component-to-swift-complex.sh

test-warc-libs:
	cmp application/warc/lib/warc.zig recipes/application/warc/lib/warc.zig

test-qip-router-help: qip
	QIP_BIN=$(QIP_BIN) sh test/qip-router-help.sh

test-node: qip components recipes/application/warc/25-add-content-size.wasm compliance/warc-connect-search-params.comply.wasm test/fixtures/wasm-debugger-bulk-memory.wasm test/fixtures/wasm-debugger-call-indirect.wasm test/fixtures/qip-content-interpreter-uniforms.wasm
	node --check site/qip-runner.js
	node test/qip-runner-smoke.mjs
	node --test test/bytes-to-sha256.mjs
	node --test test/recipe-finder.mjs
	node --test test/qip-mcp.mjs
	node --test test/content-total-byte-components.mjs
	node --test test/content-component-host.mjs
	node --test examples/nextjs-qip/test/qip-content.test.mjs
	node --test test/html-to-svg-inter-paths.mjs
	node --test test/ansi-sgr.mjs
	node --test test/wasm-to-js.mjs
	node --test test/qipx-rejection.mjs
	node --test test/qipx-multipart-form.mjs
	node --test test/qipx-hosts.mjs
	node --test test/qipx-tui.mjs
	node --test test/calendar-gregorian-tui.mjs
	node --test test/svg-rasterizer-content.mjs
	node --test test/time-series-polylines.mjs
	node --test test/svg-to-pdf-inter-font.mjs
	node --test test/svg-rasterizer-rgba32float-simd.mjs
	node --test test/svg-rasterizer-thorvg.mjs
	node --test test/qip-play-debug-stats.mjs
	node --test test/qip-play-steps.mjs
	node --test test/qip-play-svg.mjs
	node --test test/svg-path-editor.mjs
	node --test test/qipdb.mjs
	node --test test/qip-content-interpreter.mjs
	node --test test/ktx2-resize.mjs
	node --test test/ktx2-resize-float32.mjs
	node --test test/ktx2-resize-simd.mjs
	node --test test/image-resize-worker.mjs
	node --test test/interactive-host-decisions.mjs
	node --test test/gif-player.mjs
	node --test test/god-rays-optimized-timed.mjs
	node --test test/chronograph-timed.mjs
	node --test test/macintosh-1bit-interactive.mjs
	node --test test/tic-tac-toe-interactive.mjs
	node --test test/calculator-snake-interactive.mjs
	node --test test/fixed-timestep-simulator.mjs
	node --test test/spreadsheet-platformer-update.mjs
	node --test test/final-interactive-components.mjs
	node --test test/cover-flow-shadow-interactive.mjs
	node --test test/render-counts-mandelbrot-perlin.mjs
	node --test test/moon-cover-lofi-dock-interactive.mjs
	node --test test/layout-security-graph-interactive.mjs
	node --test test/tile-tetris-web-interactive.mjs
	node --test test/floats-financial-charts-interactive.mjs
	node --test test/map-waterfall-interactive.mjs
	node --test test/photo-xbox-interactive.mjs
	node --test test/paint-ps2-interactive.mjs
	node --test test/aces-god-rays-interactive.mjs
	node --test test/sudoku-webos-interactive.mjs
	node --test test/qip-edit-stats.mjs
	node --test test/qip-form-element.mjs
	node --test test/qip-search.mjs
	node --test test/sudoku-ui.mjs
	node --test test/html-id-validator.mjs
	node --test test/css-expression-to-value.mjs
	node --test test/html-adjacent.mjs
	node --test test/html-to-accessibility-tree.mjs
	node --test test/luhn.mjs
	node --test test/unicode-17-lowercase.mjs
	node --test test/unicode-17-uppercase-comply.mjs
	node --test test/unicode-17-lowercase-comply.mjs
	node --test test/currency-format-usd-en-us-comply.mjs
	node --test test/currency-format-en-us-comply.mjs
	node --test test/currency-format-en-in-comply.mjs
	node --test test/currency-format-es-es-comply.mjs
	node --test test/currency-format-de-de-comply.mjs
	node --test test/currency-format-ar-eg-comply.mjs
	node --test test/currency-format-fr-fr-comply.mjs
	node --test test/currency-format-pt-br-comply.mjs
	node --test test/currency-format-ja-jp-comply.mjs
	node --test test/currency-format-zh-cn-comply.mjs
	node --test test/iso-4217-alpha-to-numeric-comply.mjs
	node --test test/svg-data-uri-comply.mjs
	node --test test/mermaid-to-unicode-html.mjs
	node --test test/warc-content-size.mjs
	node --test test/warc-connect-search-params-comply.mjs
	node --test test/warc-text-uri-list-to-redirect.mjs
	node --test test/qip-wasm-checks.mjs
	node --test test/trace-with.mjs
	node --test test/qip-wasm-policy.mjs
	node --test test/sqlite-modules.mjs
	node --test test/pdf-extract-images.mjs
	node --test test/pdf-extract-text.mjs
	node --test test/ttf-svg-paths.mjs
	node --test test/text-to-og-image-font8x8.mjs
	node --test test/text-to-og-image-svg.mjs
	node --test test/text-to-og-image-svg-inter.mjs
	node --test test/text-to-svg-inter.mjs
	node --test test/text-to-svg-jetbrains-mono-v2.304.mjs
	node --test test/jp2-bmp.mjs
	node --test test/recipe-book-tar.mjs
	node --test test/content-recipe-browser-javascript.mjs
	node --test test/qip-router-node.mjs
	node --test test/tar-to-zip.mjs
	node --test test/zip-to-tar.mjs
	node --test test/zip-list-extract.mjs
	node --test test/bmp-png.mjs
	node --test test/bmp-b8g8r8a8-srgb-webp-lossy.mjs
	node --test test/bmp-b8g8r8a8-srgb-avif-lossy.mjs
	node --test test/bmp-b8g8r8a8-srgb-jpeg-lossy.mjs
	node --test test/image-compress-jpeg.mjs
	node --test test/bmp-b8g8r8a8-srgb-webp-lossy-opaque.mjs
	node --test test/bmp-b8g8r8a8-srgb-webp-lossless.mjs
	node --test test/bmp-b8g8r8a8-icc-to-srgb.mjs
	node --test test/ktx2-rgba32float.mjs
	node --test test/ktx2-display-p3.mjs
	node --test test/ktx2-rgba8-srgb.mjs
	node --test test/ktx2-rgba8-webp.mjs
	node --test test/ktx2-rgba8-png-avif.mjs
	node --test test/ktx2-bgra8-srgb.mjs
	node --test test/webp-bmp.mjs
	node --test test/bmp-rgb-metrics.mjs
	node --test test/form-data-to-tar.mjs
	node --test test/wasm-trap-instance-continues.mjs

test-svg-rasterizers: image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm application/wasm/wasm-bounded-output.wasm
	$(ZIG_ENV) zig test image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.zig $(ZIG_TEST_FLAGS)
	$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb -Mroot=image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig
	node --test test/svg-rasterizer-content.mjs
	node --test test/svg-rasterizer-rgba32float-simd.mjs
	node --test test/svg-rasterizer-thorvg.mjs

test-wasm-bounded-output: application/wasm/wasm-bounded-output.wasm
	$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep wasm_reader -Mroot=application/wasm/wasm-bounded-output.zig -Mwasm_reader=application/wasm/lib/wasm-reader.zig

fuzz-zlib: bytes/zlib-compress.wasm bytes/zlib-compress-fixed-huffman.wasm bytes/zlib-compress-dynamic-huffman.wasm bytes/zlib-compress-dynamic-huffman-opt.wasm bytes/zlib-decompress.wasm
	node tools/fuzz-zlib.mjs 20000

test-deno: qip components
	deno check site/qip-runner.js
	deno run --allow-read test/qip-runner-smoke.mjs
	deno test --allow-read --allow-write --allow-run --allow-sys --allow-env test/qip-play-debug-stats.mjs test/qip-edit-stats.mjs test/sudoku-ui.mjs test/html-id-validator.mjs test/html-adjacent.mjs test/html-to-accessibility-tree.mjs test/luhn.mjs test/trace-with.mjs test/wasm-trap-instance-continues.mjs

test-comply: qip components compliance
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-tsx.wasm --with compliance/syntax-highlight-javascript.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/javascript/js-syntax-highlight-html.wasm --with compliance/syntax-highlight-javascript-semantic.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-html.wasm --with compliance/syntax-highlight-html.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-css.wasm --with compliance/syntax-highlight-css.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply recipes/text/markdown/25-html-code-syntax-highlight-python.wasm --with compliance/syntax-highlight-python.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply recipes/text/markdown/26-html-code-syntax-highlight-java.wasm --with compliance/syntax-highlight-java.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply recipes/text/markdown/27-html-code-syntax-highlight-csharp.wasm --with compliance/syntax-highlight-csharp.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-swift.wasm --with compliance/syntax-highlight-swift.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-ruby.wasm --with compliance/syntax-highlight-ruby.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-go.wasm --with compliance/syntax-highlight-go.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-c.wasm --with compliance/syntax-highlight-c.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-bash.wasm --with compliance/syntax-highlight-bash.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-wasm.wasm --with compliance/syntax-highlight-wasm.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-code-syntax-highlight-zig.wasm --with compliance/syntax-highlight-zig.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/vnd.mermaid/mermaid-to-unicode-html.wasm --with compliance/mermaid-to-unicode-html.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/markdown/commonmark.0.31.2.wasm --with compliance/commonmark-spec-0.31.2.wasm --straight-line-oracles
	$(QIP_BIN) comply text/markdown/gfm-commonmark.0.31.2.wasm --with compliance/commonmark-0.31.2-gfm.wasm --straight-line-oracles
	$(QIP_BIN) comply text/markdown/commonmark.0.31.2.wasm --with compliance/html5-entities.comply.wasm --with compliance/unicode-17-casefold-labels.comply.wasm --with compliance/commonmark-differential-corpus.comply.wasm
	$(QIP_BIN) comply text/markdown/gfm-commonmark.0.31.2.wasm --with compliance/html5-entities.comply.wasm --with compliance/unicode-17-casefold-labels.comply.wasm --with compliance/commonmark-differential-corpus.comply.wasm
	$(QIP_BIN) comply text/luhn.wasm --with compliance/luhn.comply.wasm
	$(QIP_BIN) comply text/rgb-to-hex.wasm --with compliance/rgb-to-hex.comply.wasm
	$(QIP_BIN) comply text/base64-decode.wasm --with compliance/base64-decode.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/css/css-class-validator.wasm --with compliance/css-class-validator.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-id-validator.wasm --with compliance/html-id-validator.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-input-name-validator.wasm --with compliance/html-input-name-validator.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/html/html-tag-validator.wasm --with compliance/html-tag-validator.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/e164.wasm --with compliance/e164.comply.wasm
	$(QIP_BIN) comply bytes/base64-encode.wasm --with compliance/base64-encode.comply.wasm
	$(QIP_BIN) comply bytes/crc32-hex.wasm --with compliance/crc32-hex.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/trim.wasm --with compliance/trim.comply.wasm
	$(QIP_BIN) comply text/markdown/extract-title-text.wasm --with compliance/extract-title-text.comply.wasm
	$(QIP_BIN) comply text/utf8-must-be-valid.wasm --with compliance/reject-invalid-utf8.wasm --with compliance/preserve-ascii.wasm --with compliance/preserve-empty.wasm --with compliance/preserve-whitespace.wasm
	$(QIP_BIN) comply text/utf8-must-be-ascii.wasm --with compliance/reject-non-ascii.wasm --with compliance/preserve-ascii.wasm --with compliance/preserve-empty.wasm --with compliance/preserve-whitespace.wasm
	$(QIP_BIN) comply text/unicode-17-lowercase.wasm --with compliance/unicode-17-lowercase.comply.wasm
	$(QIP_BIN) comply text/unicode-17-uppercase.wasm --with compliance/unicode-17-uppercase.comply.wasm
	$(QIP_BIN) comply text/currency-format-usd-en-us.wasm --with compliance/currency-format-usd-en-us.comply.wasm
	$(QIP_BIN) comply text/currency-format-en-us.wasm --with compliance/currency-format-en-us.comply.wasm
	$(QIP_BIN) comply text/currency-format-en-in.wasm --with compliance/currency-format-en-in.comply.wasm
	$(QIP_BIN) comply text/currency-format-es-es.wasm --with compliance/currency-format-es-es.comply.wasm
	$(QIP_BIN) comply text/currency-format-de-de.wasm --with compliance/currency-format-de-de.comply.wasm
	$(QIP_BIN) comply text/currency-format-ar-eg.wasm --with compliance/currency-format-ar-eg.comply.wasm
	$(QIP_BIN) comply text/currency-format-fr-fr.wasm --with compliance/currency-format-fr-fr.comply.wasm
	$(QIP_BIN) comply text/currency-format-pt-br.wasm --with compliance/currency-format-pt-br.comply.wasm
	$(QIP_BIN) comply text/currency-format-ja-jp.wasm --with compliance/currency-format-ja-jp.comply.wasm
	$(QIP_BIN) comply text/currency-format-zh-cn.wasm --with compliance/currency-format-zh-cn.comply.wasm
	$(QIP_BIN) comply text/iso-4217-alpha-to-numeric.wasm --with compliance/iso-4217-alpha-to-numeric.comply.wasm
	$(QIP_BIN) comply image/svg+xml/svg-to-data-uri.wasm --with compliance/svg-to-data-uri.comply.wasm
	$(QIP_BIN) comply image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm --with compliance/jpeg-to-bmp-b8g8r8a8-srgb.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm --with compliance/bmp-b8g8r8a8-icc-to-srgb.comply.wasm --straight-line-oracles
	$(QIP_BIN) comply text/uri-list/data-uri-to-css-url.wasm --with compliance/data-uri-to-css-url.comply.wasm

test-snapshot: qip components
	@mkdir -p test
	@rm -f test/latest.txt
	@printf "%s\n" "module: base64-encode.wasm" >> test/latest.txt
	@printf %s "hello" | $(QIP_BIN) run bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: base64-encode.wasm | base64-decode.wasm" >> test/latest.txt
	@printf %s "hello" | $(QIP_BIN) run bytes/base64-encode.wasm text/base64-decode.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: bmp-to-ico.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "424D3A0000000000000036000000280000000100000001000000010018000000000004000000000000000000000000000000000000000000FF00" | xxd -r -p | $(QIP_BIN) run image/bmp/bmp-to-ico.wasm bytes/base64-encode.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: crc32-hex.wasm" >> test/latest.txt
	@printf %s "abc" | $(QIP_BIN) run bytes/crc32-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: css-class-validator.wasm" >> test/latest.txt
	@printf %s "btn-primary" | $(QIP_BIN) run text/css/css-class-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: e164.wasm" >> test/latest.txt
	@printf %s "+14155552671" | $(QIP_BIN) run text/e164.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run bytes/zlib-compress.wasm bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run bytes/zlib-compress.wasm bytes/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-fixed-huffman.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run bytes/zlib-compress-fixed-huffman.wasm bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-fixed-huffman.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run bytes/zlib-compress-fixed-huffman.wasm bytes/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-dynamic-huffman.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run bytes/zlib-compress-dynamic-huffman.wasm bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-dynamic-huffman.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run bytes/zlib-compress-dynamic-huffman.wasm bytes/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: hello.wasm" >> test/latest.txt
	@printf %s "World" | $(QIP_BIN) run text/hello.wasm >> test/latest.txt
	@printf "%s\n" "module: hello-c.wasm" >> test/latest.txt
	@printf %s "World" | $(QIP_BIN) run text/hello-c.wasm >> test/latest.txt
	@printf "%s\n" "module: hello-zig.wasm" >> test/latest.txt
	@printf %s "World" | $(QIP_BIN) run text/hello-zig.wasm >> test/latest.txt
	@printf "%s\n" "module: hex-to-rgb.wasm" >> test/latest.txt
	@printf %s "#ff8800" | $(QIP_BIN) run text/hex-to-rgb.wasm >> test/latest.txt
	@printf "%s\n" "module: html-id-validator.wasm" >> test/latest.txt
	@printf %s "main-content" | $(QIP_BIN) run text/html/html-id-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: html-input-name-validator.wasm" >> test/latest.txt
	@printf %s "email" | $(QIP_BIN) run text/html/html-input-name-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: html-escape.wasm" >> test/latest.txt
	@printf "%s" "<textarea>Tom & \"QIP\"</textarea><input value='raw'>" | $(QIP_BIN) run text/html/html-escape.wasm >> test/latest.txt
	@printf "%s\n" "module: html-wcag-contrast-aa.wasm" >> test/latest.txt
	@printf "%s" "<style>.ok{color:#111;background:#fff}</style><p class=ok>Readable</p>" | $(QIP_BIN) run text/html/html-wcag-contrast-aa.wasm >> test/latest.txt
	@printf "%s\n" "module: html-tag-validator.wasm" >> test/latest.txt
	@printf %s "div" | $(QIP_BIN) run text/html/html-tag-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: luhn.wasm" >> test/latest.txt
	@printf %s "49927398716" | $(QIP_BIN) run text/luhn.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm" >> test/latest.txt
	@printf "%b" "# Title\nHello **World**\n" | $(QIP_BIN) run text/markdown/markdown-basic.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm (table)" >> test/latest.txt
	@printf "%b" '| A | B |\n| --- | --- |\n| `x` | **y** |\n' | $(QIP_BIN) run text/markdown/markdown-basic.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm | html-page-wrap.wasm" >> test/latest.txt
	@printf "%b" "# Title\nHello **World**\n" | $(QIP_BIN) run text/markdown/markdown-basic.wasm text/html/html-page-wrap.wasm | perl -0pe 's#(<style\b[^>]*>).*?(</style>)#$$1$$2#gis' >> test/latest.txt
	@printf "%s\n" "module: rgb-to-hex.wasm" >> test/latest.txt
	@printf %s "255,0,170" | $(QIP_BIN) run text/rgb-to-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: rgb-to-hex.wasm (rgb())" >> test/latest.txt
	@printf %s " rgb( 101, 79, 240 ) " | $(QIP_BIN) run text/rgb-to-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: tld-validator.wasm" >> test/latest.txt
	@printf %s "com" | $(QIP_BIN) run text/tld-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: youtube-id-extractor.wasm" >> test/latest.txt
	@printf %s "https://youtu.be/dQw4w9WgXcQ https://www.youtube.com/embed/9bZkp7q19f0 https://www.youtube.com/watch?v=3JZ_D3ELwOQ" | $(QIP_BIN) run text/youtube-id-extractor.wasm >> test/latest.txt
	@printf "%s\n" "module: trim.wasm" >> test/latest.txt
	@printf %s "  hi  " | $(QIP_BIN) run text/trim.wasm >> test/latest.txt
	@printf "%s\n" "module: utf8-must-be-valid.wasm" >> test/latest.txt
	@printf %s "hello" | $(QIP_BIN) run text/utf8-must-be-valid.wasm >> test/latest.txt
	@printf "%s\n" "module: wasm-to-js.wasm" >> test/latest.txt
	@cat text/hello.wasm | $(QIP_BIN) run -o test/latest-wasm-to-js.txt application/wasm/wasm-to-js.wasm
	@cat test/latest-wasm-to-js.txt >> test/latest.txt
	@rm -f test/latest-wasm-to-js.txt
	diff test/expected.txt test/latest.txt && echo "Snapshots pass."

ZIG_TEST_FILES := $(COMPONENT_ZIG_FILES) $(wildcard recipes/text/markdown/*.zig) $(wildcard recipes/application/warc/*.zig)

test-zig: $(ZIG_TEST_FILES)
	@status=0; \
	for f in $^; do \
		echo "zig test $$f"; \
		if [ "$$f" = "application/pdf/pdf-extract-images.zig" ] || [ "$$f" = "application/pdf/pdf-extract-text.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep inflate -Mroot="$$f" -Minflate=bytes/lib/inflate.zig || status=1; \
		elif [ "$$f" = "components/interactive/qipdb.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep wasm_interpreter --dep wasm_counts -Mroot="$$f" -Mwasm_interpreter=application/wasm/lib/wasm-interpreter.zig -Mwasm_counts=application/wasm/lib/wasm-counts.zig || status=1; \
		elif [ "$$f" = "application/wasm/qip-content-interpreter.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep wasm_interpreter -Mroot="$$f" -Mwasm_interpreter=application/wasm/lib/wasm-interpreter.zig || status=1; \
		elif [ "$$f" = "text/html/html-to-svg-inter-paths.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep inter_regular --dep inter_bold -Mroot="$$f" -Minter_regular=text/lib/inter_display_latin_paths.zig -Minter_bold=text/lib/inter_display_bold_latin_paths.zig || status=1; \
		elif [ "$$f" = "text/javascript/js-syntax-highlight-html.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep javascript -Mroot="$$f" -Mjavascript=text/html/lib/syntax-highlight-javascript.zig || status=1; \
		elif [ "$$f" = "image/svg+xml/svg-to-pdf-inter-font.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ttf --dep inter_regular --dep inter_bold --dep inter_italic --dep inter_bold_italic -Mroot="$$f" -Mttf=font/ttf/lib/ttf.zig -Minter_regular=fixtures/inter-4.1/inter-display-regular.zig -Minter_bold=fixtures/inter-4.1/inter-display-bold.zig -Minter_italic=fixtures/inter-4.1/inter-display-italic.zig -Minter_bold_italic=fixtures/inter-4.1/inter-display-bold-italic.zig || status=1; \
		elif [ "$$f" = "image/svg+xml/svg-polylines-exponential-moving-average.zig" ] || [ "$$f" = "image/svg+xml/svg-polylines-rolling-mean.zig" ] || [ "$$f" = "image/svg+xml/svg-polylines-add-mean-lines.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep polyline_smoothing -Mroot="$$f" -Mpolyline_smoothing=image/svg+xml/lib/polyline-smoothing.zig || status=1; \
		elif [ "$$f" = "application/x-tar/tar-to-zip.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep deflate -Mroot="$$f" -Mdeflate=bytes/lib/deflate.zig || status=1; \
		elif [ "$$f" = "application/x-tar/recipes-tar-to-csv.zig" ] || [ "$$f" = "application/x-tar/recipes-tar-to-node-tar.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep wasm_reader -Mroot="$$f" -Mwasm_reader=application/wasm/lib/wasm-reader.zig || status=1; \
		elif [ "$$f" = "application/zip/zip-to-tar.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep inflate -Mroot="$$f" -Minflate=bytes/lib/inflate.zig || status=1; \
		elif [ "$$f" = "application/zip/zip-list-entries-csv.zig" ] || [ "$$f" = "application/zip/zip-list-files-csv.zig" ] || [ "$$f" = "application/zip/zip-extract-file.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep inflate -Mroot="$$f" -Minflate=bytes/lib/inflate.zig || status=1; \
		elif [ "$$f" = "components/interactive/liars-dice.zig" ] || [ "$$f" = "components/interactive/macos9-desktop.zig" ] || [ "$$f" = "components/interactive/macosx-leopard-desktop.zig" ] || [ "$$f" = "components/interactive/org_planner.zig" ] || [ "$$f" = "components/interactive/peon-gold.zig" ] || [ "$$f" = "components/interactive/textedit.zig" ] || [ "$$f" = "components/interactive/vertical-shooter.zig" ] || [ "$$f" = "components/interactive/windows95-desktop.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig || status=1; \
		elif [ "$$f" = "image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-look-warm-fade.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba32float -Mroot="$$f" -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig || status=1; \
		elif [ "$$f" = "components/interactive/chronograph.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float_display_p3_linear -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig || status=1; \
		elif [ "$$f" = "components/interactive/macintosh-1bit.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig || status=1; \
		elif [ "$$f" = "image/lib/ktx2-rgba32float-display-p3.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba32float_display_p3_linear -Mroot="$$f" -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-rgba32float-display-p3-linear-to-ktx2-rgba32float-display-p3.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba32float_display_p3_linear --dep ktx2_rgba32float_display_p3 -Mroot="$$f" -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig --dep ktx2_rgba32float_display_p3_linear -Mktx2_rgba32float_display_p3=image/lib/ktx2-rgba32float-display-p3.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3-simd.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-simd.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba32float_profile -Mroot="$$f" -Mktx2_rgba32float_profile=image/lib/ktx2-rgba32float.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3-simd.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell-simd.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba32float_profile -Mroot="$$f" -Mktx2_rgba32float_profile=image/lib/ktx2-rgba32float-display-p3-linear.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.zig" ] || [ "$$f" = "image/ktx2/solid-color-to-ktx2-rgba32float-display-p3-linear.zig" ] || [ "$$f" = "image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float_display_p3_linear -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-color-palette.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-double.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-rotate-and-flip.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-rgba32float-rotate-and-flip.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba32float --dep ktx2_rgba32float_display_p3_linear --dep ktx2_rgba32float_display_p3 -Mroot="$$f" -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig --dep ktx2_rgba32float_display_p3_linear -Mktx2_rgba32float_display_p3=image/lib/ktx2-rgba32float-display-p3.zig || status=1; \
		elif [ "$$f" = "image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.zig" ] || [ "$$f" = "image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_bgra8_srgb -Mroot="$$f" -Mktx2_bgra8_srgb=image/lib/ktx2-bgra8-srgb.zig || status=1; \
		elif [ "$$f" = "image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.zig" ] || [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.zig" ] || [ "$$f" = "components/interactive/aces-up.zig" ] || [ "$$f" = "components/interactive/gameboy-camera.zig" ] || [ "$$f" = "components/interactive/gif-player.zig" ] || [ "$$f" = "components/interactive/god-rays-optimized.zig" ] || [ "$$f" = "components/interactive/god-rays.zig" ] || [ "$$f" = "components/interactive/tic-tac-toe-sun-moon.zig" ] || [ "$$f" = "components/interactive/browser-security.zig" ] || [ "$$f" = "components/interactive/calculator.zig" ] || [ "$$f" = "components/interactive/chronograph.zig" ] || [ "$$f" = "components/interactive/cover-flow-lofi.zig" ] || [ "$$f" = "components/interactive/dock-magnification.zig" ] || [ "$$f" = "components/interactive/formula-1-map.zig" ] || [ "$$f" = "components/interactive/graph-calculator.zig" ] || [ "$$f" = "components/interactive/ieee-754-floats.zig" ] || [ "$$f" = "components/interactive/layout-systems.zig" ] || [ "$$f" = "components/interactive/mandelbrot.zig" ] || [ "$$f" = "components/interactive/moon-phases.zig" ] || [ "$$f" = "components/interactive/openai-anthropic-arr.zig" ] || [ "$$f" = "components/interactive/page-load-waterfall.zig" ] || [ "$$f" = "components/interactive/paint.zig" ] || [ "$$f" = "components/interactive/perlin-noise.zig" ] || [ "$$f" = "components/interactive/photo-light-table.zig" ] || [ "$$f" = "components/interactive/ps2-menu.zig" ] || [ "$$f" = "components/interactive/render-counts.zig" ] || [ "$$f" = "components/interactive/shadow-rendering.zig" ] || [ "$$f" = "components/interactive/shutterstock-earnings.zig" ] || [ "$$f" = "components/interactive/side-scroller-platformer.zig" ] || [ "$$f" = "components/interactive/snake.zig" ] || [ "$$f" = "components/interactive/spreadsheet.zig" ] || [ "$$f" = "components/interactive/sudoku.zig" ] || [ "$$f" = "components/interactive/tetris.zig" ] || [ "$$f" = "components/interactive/tile-world-12x12.zig" ] || [ "$$f" = "components/interactive/web-mechanics.zig" ] || [ "$$f" = "components/interactive/webos-card-view.zig" ] || [ "$$f" = "components/interactive/xbox-dashboard.zig" ] || [ "$$f" = "components/interactive/cover-flow.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig || status=1; \
		elif [ "$$f" = "image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.zig" ] || [ "$$f" = "image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig || status=1; \
		elif [ "$$f" = "image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.zig" ] || [ "$$f" = "image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.zig" ] || [ "$$f" = "image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep ktx2_rgba8_srgb --dep ktx2_rgba32float -Mroot="$$f" -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_rgba32float=image/lib/ktx2-rgba32float.zig || status=1; \
		elif [ "$$f" = "image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.zig" ]; then \
			$(ZIG_ENV) zig test $(ZIG_TEST_FLAGS) --dep png_encoder_impl -Mroot="$$f" --dep ktx2_rgba8_srgb --dep ktx2_bgra8_srgb -Mpng_encoder_impl=image/bmp/bmp-to-png.zig -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig -Mktx2_bgra8_srgb=image/lib/ktx2-bgra8-srgb.zig || status=1; \
		else \
			$(ZIG_ENV) zig test "$$f" $(ZIG_TEST_FLAGS) || status=1; \
		fi; \
	done; \
	exit $$status

test-go:
	go test $(GO_TEST_PKGS)
	go test $(GO_TOOL_FILES)

site/favicon.ico: qip-logo.svg
	$(QIP_BIN) run -i qip-logo.svg -- image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm image/bmp/bmp-double.wasm image/bmp/bmp-double.wasm image/bmp/bmp-to-ico.wasm > $@

OG_MD_SOURCES := $(shell find site docs -type f -name '*.md' | sort)
OG_IMAGE_MODULES := text/markdown/extract-title-text.wasm text/text-to-path-svg-dejavu-sans-mono-bold.wasm image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm image/bmp/bmp-to-png.wasm

OG_PNG_TARGETS := $(sort $(patsubst site/_og/%/index.png,site/_og/%.png,$(patsubst docs/%.md,site/_og/docs/%.png,$(patsubst site/%.md,site/_og/%.png,$(OG_MD_SOURCES)))))

site/_og: $(OG_PNG_TARGETS)

define OG_RENDER_PNG_RECIPE
	@mkdir -p $(dir $@)
	$(QIP_BIN) run -i "$<" -o "$@" -- text/markdown/extract-title-text.wasm text/text-to-path-svg-dejavu-sans-mono-bold.wasm '?width=1200&height=630&font_size=72' image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm '?background_color_rgba=0xeecc33ff' image/bmp/bmp-to-png.wasm
endef

site/_og/%.png: site/%.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/%.png: site/%/index.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/docs/%.png: docs/%.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/docs/%.png: docs/%/index.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/docs.png: docs/index.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

install:
	go install github.com/royalicing/qip@latest

score: qip
	@echo "make score is deprecated; use wasm-safety-report for strict policy checks or wasm-counts.wasm for factual metrics."
	@files="$$(find $(COMPONENT_DIRS) -type f -name '*.wasm' | LC_ALL=C sort)"; \
	if [ -z "$$files" ]; then \
		echo "No component .wasm files found"; \
		exit 1; \
	fi; \
	$(QIP_BIN) score $$files

strict-profile-report: components
	@for dir in $(COMPONENT_DIRS); do node tools/report-strict-profile.mjs "$$dir" || exit; done

wasm-safety-report: qip components
	@pass=0; \
	fail=0; \
	files="$$(find $(COMPONENT_DIRS) -type f -name '*.wasm' | LC_ALL=C sort)"; \
	if [ -z "$$files" ]; then \
		echo "No component .wasm files found"; \
		exit 1; \
	fi; \
	for f in $$files; do \
		if $(QIP_BIN) run -i "$$f" -- application/wasm/wasm-strict-profile.wasm application/wasm/wasm-bounded-loops.wasm >/dev/null 2>&1; then \
			printf "PASS %s\n" "$$f"; \
			pass=$$((pass + 1)); \
		else \
			printf "FAIL %s\n" "$$f"; \
			fail=$$((fail + 1)); \
		fi; \
	done; \
	total=$$((pass + fail)); \
	printf "\npass=%d fail=%d total=%d\n" "$$pass" "$$fail" "$$total"

# SITE_HTML_VALIDATORS := text/html/html-unique-id-validator.wasm text/html/html-id-reference-validator.wasm text/html/html-accessible-name-unique-validator.wasm

site-static: qip # $(SITE_HTML_VALIDATORS)
	$(QIP_BIN) router warc ./site --host https://qip.dev --view-source | $(QIP_BIN) run application/warc/warc-check-broken-links.wasm application/warc/warc-check-broken-module-imports.wasm application/warc/warc-to-static-tar-no-trailing-slash.wasm > site-static.tar && mkdir -p site-static && tar -xvf site-static.tar -C site-static
	@failed=0; \
	html_entries="$$(tar -tf site-static.tar | LC_ALL=C sort | awk '/\.html$$/')"; \
	for validator in $(SITE_HTML_VALIDATORS); do \
		validator_failed=0; \
		for entry in $$html_entries; do \
			page="site-static/$$entry"; \
			if ! $(QIP_BIN) run -i "$$page" -- "$$validator" >/dev/null 2>&1; then \
				printf "FAIL %s %s\n" "$${validator##*/}" "$$page"; \
				validator_failed=$$((validator_failed + 1)); \
			fi; \
		done; \
		printf "%s: %d failure(s)\n" "$${validator##*/}" "$$validator_failed"; \
		failed=$$((failed + validator_failed)); \
	done; \
	test "$$failed" -eq 0

site-static-with-og: site/_og recipes/application/warc/10-add-open-graph-image-meta.wasm site-static

site-checks: site-static
	$(QIP_BIN) router get site / | $(QIP_BIN) run text/html/html-wcag-contrast-aa.wasm

dev:
	$(QIP_BIN) router dev ./site -p 4114 --view-source

defluff:
	find . -name '.DS_Store' -type f -delete
