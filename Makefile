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

DAEMON_LABEL := dev.fanctl.watch
DAEMON_PLIST := /Library/LaunchDaemons/$(DAEMON_LABEL).plist

install-daemon:
	@test -x /usr/local/bin/$(BIN) || (echo "Run 'sudo make install' first" && exit 1)
	sudo install -m 0644 -o root -g wheel launchd/$(DAEMON_LABEL).plist $(DAEMON_PLIST)
	-sudo launchctl bootout system/$(DAEMON_LABEL) 2>/dev/null
	sudo launchctl bootstrap system $(DAEMON_PLIST)
	@echo "Daemon $(DAEMON_LABEL) installed and running."
	@echo "Logs: tail -f /var/log/fanctl.log"
	@echo "Status: sudo launchctl print system/$(DAEMON_LABEL) | head"
	@echo "Stop:  sudo launchctl bootout system/$(DAEMON_LABEL)"

uninstall-daemon:
	-sudo launchctl bootout system/$(DAEMON_LABEL) 2>/dev/null
	sudo rm -f $(DAEMON_PLIST)
	@echo "Daemon $(DAEMON_LABEL) uninstalled."

clean:
	swift package clean
	rm -rf .build
