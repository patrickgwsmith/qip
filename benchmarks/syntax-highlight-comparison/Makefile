.PHONY: install build compare benchmark

install:
	npm ci

build:
	$(MAKE) -C ../.. components/text/javascript/javascript-to-syntax-highlight-html.wasm

compare: build
	npm run compare

benchmark: build
	npm run benchmark:qip
