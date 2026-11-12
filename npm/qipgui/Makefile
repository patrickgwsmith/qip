.PHONY: publish

NPM ?= npm

publish:
	@node ../sync-shared.mjs --check
	@set -eu; \
	version=$$(node -p "require('./package.json').version"); \
	if grep -Fqx "$$version" published-versions.txt; then \
		printf 'qipgui %s is already in published-versions.txt\n' "$$version" >&2; \
		exit 1; \
	fi; \
	$(NPM) publish; \
	printf '%s\n' "$$version" >> published-versions.txt; \
	printf 'Recorded qipgui %s in published-versions.txt\n' "$$version"
