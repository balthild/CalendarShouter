# CalendarShouter — terminal-first build, test and packaging.
#
# Two independent halves of localization, both required:
#  * the `LocalizationPlugin` build tool generates typed Swift accessors
#    (`Text(localizable:)`) for the catalog while Swift builds;
#  * the `localize` job compiles the catalog into the `.lproj` bundles that macOS
#    actually reads at runtime. SwiftPM copies `.xcstrings` verbatim and never
#    compiles it, so a build without this ships an app showing raw keys.
#
# Always launch the bundled app with `make run` (or `open`): macOS only presents
# the calendar and reminders permission alerts to an app launched through
# LaunchServices, and silently refuses the request when the executable is started
# directly. Re-signing the bundle changes its code hash, so macOS forgets the
# permission decisions after every rebuild; `make reset-permissions` clears them
# deliberately.

SHELL := /bin/sh

APP_NAME := CalendarShouter
BUNDLE_ID := com.balthild.CalendarShouter
CORE_TARGET := CalendarShouterCore
EXEC_TARGET := CalendarShouter

CONFIG ?= debug
SIGN_IDENTITY ?= -
GIT_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION ?= $(if $(GIT_VERSION),$(GIT_VERSION),0.0.0)
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_DIR := .build
DIST_DIR := $(BUILD_DIR)/dist
APP_DIR := $(BUILD_DIR)/app
APP_BUNDLE := $(APP_DIR)/$(APP_NAME).app
BIN_DIR := $(BUILD_DIR)/$(CONFIG)
RESOURCE_BUNDLE := $(BIN_DIR)/$(APP_NAME)_$(CORE_TARGET).bundle

RESOURCES_DIR := Sources/$(CORE_TARGET)/Resources
XCSTRINGS := $(RESOURCES_DIR)/Localizable.xcstrings
INFO_PLIST := App/Info.plist
INFO_PLIST_LOCALIZATION := App/Localization
ICON_SCRIPT := Tools/GenerateAppIcon.swift
ICONSET_DIR := $(BUILD_DIR)/$(APP_NAME).iconset
ICNS := $(BUILD_DIR)/$(APP_NAME).icns

SWIFT := swift
XCSTRINGSTOOL := $(shell xcrun --find xcstringstool 2>/dev/null)
PLIST_BUDDY := /usr/libexec/PlistBuddy

.DEFAULT_GOAL := help

.PHONY: help format lint localize build test icon app sign package notarize run demo demo-missed demo-reminder dev reset-permissions reset-data clean release

help: ## Show this help.
	@printf '%s\n' "CalendarShouter $(VERSION) — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-11s\033[0m %s\n", $$1, $$2}'

format: ## Format Swift sources in place.
	dprint fmt

lint: ## Report formatting violations.
	dprint check

localize: ## Compile Localizable.xcstrings into .lproj bundles (requires full Xcode).
	@if [ -z "$(XCSTRINGSTOOL)" ]; then \
		printf '%s\n' "error: xcstringstool not found." \
			"Install the full Xcode toolchain, or run:" \
			"  sudo xcode-select --switch /Applications/Xcode.app"; \
		exit 1; \
	fi
	$(XCSTRINGSTOOL) compile --output-directory "$(RESOURCES_DIR)" "$(XCSTRINGS)"

build: localize ## Build the executable and its resource bundle.
	$(SWIFT) build -c $(CONFIG)

test: localize ## Run the test suite.
	$(SWIFT) test -c $(CONFIG)

icon: ## Generate AppIcon.icns, drawing the artwork from source if needed.
	@mkdir -p "$(BUILD_DIR)"
	$(SWIFT) "$(ICON_SCRIPT)" "$(ICONSET_DIR)"
	iconutil --convert icns --output "$(ICNS)" "$(ICONSET_DIR)"

app: build icon ## Assemble $(APP_NAME).app.
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_DIR)/$(EXEC_TARGET)" "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_TARGET)"
	@if [ -d "$(RESOURCE_BUNDLE)" ]; then cp -R "$(RESOURCE_BUNDLE)" "$(APP_BUNDLE)/Contents/Resources/"; fi
	@if [ -d "$(INFO_PLIST_LOCALIZATION)" ]; then \
		for dir in "$(INFO_PLIST_LOCALIZATION)"/*.lproj; do \
			if [ -d "$$dir" ]; then cp -R "$$dir" "$(APP_BUNDLE)/Contents/Resources/"; fi; \
		done; \
	fi
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@$(PLIST_BUDDY) -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@$(PLIST_BUDDY) -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP_BUNDLE)/Contents/Info.plist"
	@plutil -lint "$(APP_BUNDLE)/Contents/Info.plist"
	@printf '%s\n' "Assembled $(APP_BUNDLE)"

sign: app ## Codesign the app bundle (ad-hoc unless SIGN_IDENTITY is set).
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		codesign --force --sign - "$(APP_BUNDLE)"; \
	else \
		codesign --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"; \
	fi
	@codesign --verify --verbose=2 "$(APP_BUNDLE)"

package: sign ## Produce a distributable zip in .build/dist.
	@mkdir -p "$(DIST_DIR)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"
	@printf '%s\n' "Created $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"

notarize: ## Notarize and staple the packaged app (requires Developer ID + NOTARY_PROFILE).
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		printf '%s\n' "error: set SIGN_IDENTITY to a Developer ID Application identity."; \
		exit 1; \
	fi
	@if [ -z "$$NOTARY_PROFILE" ]; then \
		printf '%s\n' "error: set NOTARY_PROFILE to a notarytool keychain profile."; \
		exit 1; \
	fi
	xcrun notarytool submit "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip" \
		--keychain-profile "$$NOTARY_PROFILE" --wait
	xcrun stapler staple "$(APP_BUNDLE)"

run: sign ## Build, bundle and launch the app.
	open "$(APP_BUNDLE)"

demo: sign ## Launch the app with a synthetic calendar reminder, to inspect the panel.
	open -n "$(APP_BUNDLE)" --args --demo-calendar

demo-missed: sign ## Launch the app with a synthetic missed calendar-reminder backlog, to inspect the summary panel.
	open -n "$(APP_BUNDLE)" --args --demo-calendar-missed

demo-reminder: sign ## Launch the app with synthetic Reminders-app reminders, to inspect the panel.
	open -n "$(APP_BUNDLE)" --args --demo-reminder

dev: localize ## Run without bundling. Calendar access and the login item do not work.
	$(SWIFT) run -c $(CONFIG)

reset-permissions: ## Forget the app's calendar and reminders permission decisions.
	tccutil reset Calendar $(BUNDLE_ID)
	tccutil reset Reminders $(BUNDLE_ID)
	@printf '%s\n' "Reset. Relaunch with 'make run' to be asked again."

reset-data: ## Forget the app's preferences, restoring the out-of-the-box state.
	@pkill -f "$(APP_BUNDLE)/Contents/MacOS" 2>/dev/null || true
	@-defaults delete $(BUNDLE_ID)
	@printf '%s\n' "Preferences cleared (menu bar icon shown, every calendar off, reminders on, Glass)."

clean: ## Remove all build products.
	rm -rf "$(BUILD_DIR)"
	@find "$(RESOURCES_DIR)" -maxdepth 1 -name '*.lproj' -type d -exec rm -rf {} + 2>/dev/null || true

release: ## Clean release build, tested and packaged.
	$(MAKE) clean
	$(MAKE) CONFIG=release test
	$(MAKE) CONFIG=release package
