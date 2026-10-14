HOTCELL_REV := 805dde16fdace04a864410ee4a1485e0881d2642
ROOT := $(CURDIR)
HOTCELL_REPO ?= $(ROOT)/vendor/hotcell
HOTCELL_DIR ?= $(ROOT)/run/active_storage
BUNDLE_PATH ?= $(ROOT)/vendor/bundle
BENCH_ARGS ?=
export HOTCELL_REPO BUNDLE_PATH

.PHONY: install cell benchmark benchmark-qip

install:
	@if [ ! -d "$(HOTCELL_REPO)/.git" ]; then git clone https://github.com/basecamp/hotcell.git "$(HOTCELL_REPO)"; fi
	git -C "$(HOTCELL_REPO)" checkout --detach $(HOTCELL_REV)
	bundle install
	BUNDLE_GEMFILE=$(ROOT)/Gemfile.cell bundle install

cell:
	mkdir -p $(ROOT)/run $(ROOT)/tmp/scratch
	BUNDLE_GEMFILE=$(ROOT)/Gemfile.cell HOTCELL_CONFIG=$(ROOT)/config.rb HOTCELL_OPERATIONS=$(ROOT)/operations HOTCELL_DIR=$(HOTCELL_DIR) HOTCELL_WORKSPACE=$(ROOT)/tmp/workspace TMPDIR=$(ROOT)/tmp/scratch bundle exec hotcell --development

benchmark:
	HOTCELL_DIR=$(HOTCELL_DIR) bundle exec ruby bench.rb $(BENCH_ARGS)

benchmark-qip:
	bundle exec ruby bench.rb --qip-only $(BENCH_ARGS)
