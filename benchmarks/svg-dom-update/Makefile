.PHONY: install vendor

REACT_VERSION := 19.3.0
MORPHDOM_VERSION := 2.7.8

install:
	npm install --no-audit --no-fund

# The site serves these files to /svg-dom-update-benchmark.
vendor: install
	./node_modules/.bin/esbuild react-entry.mjs --bundle --format=esm --minify --define:process.env.NODE_ENV='"production"' --legal-comments=inline --outfile=../../site/vendor/react-dom-$(REACT_VERSION).mjs
	{ printf '/* morphdom $(MORPHDOM_VERSION) | MIT License | Copyright (c) Patrick Steele-Idem */\n'; cat node_modules/morphdom/dist/morphdom-esm.js; } > ../../site/vendor/morphdom-$(MORPHDOM_VERSION).mjs
