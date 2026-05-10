DEPS_DIR     := $(CURDIR)/tests/deps
MOCK_ACP_DIR := $(DEPS_DIR)/mock-acp

.PHONY: test deps-update

test: deps-update
	bash tests/run.sh $(TEST)

deps-update: $(DEPS_DIR)/.initialized
	cd $(DEPS_DIR)/shell-maker && git pull
	cd $(DEPS_DIR)/acp        && git pull
	cd $(DEPS_DIR)/agent-shell && git pull
	cd $(DEPS_DIR)/websocket  && git pull
	cd $(MOCK_ACP_DIR) && git pull && git submodule update --init --recursive && direnv allow && direnv exec . uv sync

$(DEPS_DIR)/.initialized:
	mkdir -p $(DEPS_DIR)
	git clone https://github.com/xenodium/shell-maker      $(DEPS_DIR)/shell-maker
	git clone https://github.com/xenodium/acp.el           $(DEPS_DIR)/acp
	git clone https://github.com/xenodium/agent-shell      $(DEPS_DIR)/agent-shell
	git clone https://github.com/ahyatt/emacs-websocket    $(DEPS_DIR)/websocket
	git clone https://github.com/junyi-hou/mock-acp        $(MOCK_ACP_DIR)
	cd $(MOCK_ACP_DIR) && git submodule update --init --recursive && direnv allow && direnv exec . uv sync
	touch $(DEPS_DIR)/.initialized
