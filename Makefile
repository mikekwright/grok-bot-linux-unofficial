PREFIX ?= /usr/local
UPDATER_BIN ?= $(HOME)/.local/bin/grok-bot-update

.PHONY: help detect build run update pin install-deb install-updater clean

help:
	@echo "Grok Bot Linux port"
	@echo
	@echo "  make detect       Print the newest stable version from Cursor's update API"
	@echo "  make build        Rebuild that version for Linux (tarball, .deb, AppImage)"
	@echo "  make update       Build and install only when a newer version exists"
	@echo "  make pin          Refresh upstream.json with the newest stable release"
	@echo "  make run          Launch the staged app from dist/"
	@echo "  make install-deb  Alias for make update"
	@echo "  make install-updater  Add grok-bot-update to ~/.local/bin"
	@echo "  make clean        Remove dist/ (keeps .cache/ downloads)"

detect:
	@./scripts/detect-version.sh

build:
	./scripts/build.sh

run:
	@version="$$(./scripts/detect-version.sh)"; \
	app="dist/Grok_Bot_$${version}_linux_x64/grok-bot"; \
	if [ ! -x "$$app" ]; then $(MAKE) build; fi; \
	"$$app" --no-sandbox --ozone-platform-hint=auto --class=grok-bot

update install-deb:
	./scripts/update.sh

pin:
	./scripts/update-pin.sh

install-updater:
	@mkdir -p "$(dir $(UPDATER_BIN))"
	@if [ -e "$(UPDATER_BIN)" ] && [ ! -L "$(UPDATER_BIN)" ]; then \
		echo "error: $(UPDATER_BIN) exists and is not a symlink" >&2; \
		exit 1; \
	fi
	@ln -sfn "$(abspath scripts/update.sh)" "$(UPDATER_BIN)"
	@echo "installed $(UPDATER_BIN)"

clean:
	rm -rf dist
