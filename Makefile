PREFIX ?= $(HOME)/.dotfiles/scripts/.local/bin
BIN := fanctl
BUILD_DIR := .build/release

.PHONY: build install clean run debug

build:
	swift build -c release

debug:
	swift build

run:
	swift run $(BIN) $(ARGS)

install: build
	mkdir -p "$(PREFIX)"
	cp "$(BUILD_DIR)/$(BIN)" "$(PREFIX)/$(BIN)"
	@echo "Installed to $(PREFIX)/$(BIN)"

clean:
	swift package clean
	rm -rf .build
