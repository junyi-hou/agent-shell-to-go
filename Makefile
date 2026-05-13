DEPS_DIR     := $(CURDIR)/tests/deps
MOCK_ACP_DIR := $(DEPS_DIR)/mock-acp

.PHONY: test deps-init

test: deps-init
	bash tests/run.sh $(TEST)

deps-init:
	git submodule update --init --recursive
	cd $(MOCK_ACP_DIR) && direnv allow && direnv exec . uv sync
