DEPS_DIR      := $(CURDIR)/tests/deps
MOCK_ACP_DIR  := $(DEPS_DIR)/mock-acp
DEPS_SENTINEL := $(DEPS_DIR)/.deps-initialized

.PHONY: test deps-init

test: deps-init
	bash tests/run.sh $(TEST)

deps-init: $(DEPS_SENTINEL)

$(DEPS_SENTINEL):
	git submodule update --init --recursive
	cd $(MOCK_ACP_DIR) && direnv allow && direnv exec . uv sync
	touch $@
