APP = OpenZombr
BUNDLE = $(APP).app
INSTALL_DIR = /Applications

.PHONY: help build run probe test bundle bundle-unsigned install uninstall clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

# --- Development ---

build: ## Dev build (debug)
	swift build -c debug

run: ## Build and run the menu bar app
	swift run $(APP)

probe: ## Print one live process-table reading and exit
	swift run $(APP) --probe

test: ## Run unit tests
	swift test

# --- Release ---

bundle: ## Build dist/OpenZombr.app
	bash scripts/build_swift_app.sh

bundle-unsigned: ## Build the app bundle without code signing (CI)
	SKIP_SIGN=1 bash scripts/build_swift_app.sh

install: bundle ## Install to /Applications and relaunch
	@osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	ditto dist/$(BUNDLE) $(INSTALL_DIR)/$(BUNDLE)
	@echo "Installed to $(INSTALL_DIR)/$(BUNDLE)"
	open $(INSTALL_DIR)/$(BUNDLE)

uninstall: ## Remove from /Applications
	@osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	@echo "Removed $(INSTALL_DIR)/$(BUNDLE)"

# --- Utilities ---

clean: ## Clean build artifacts
	swift package clean
	rm -rf dist/
