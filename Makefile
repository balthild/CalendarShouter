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
# directly. macOS ties those decisions to the signature, so an ad-hoc rebuild
# loses them on every build — sign with the self-signed certificate instead (see
# SIGN_IDENTITY below). `make reset-permissions` clears them deliberately.

SHELL := /bin/sh

APP_NAME := CalendarShouter
BUNDLE_ID := com.balthild.CalendarShouter
# Mirrors UserDefaultsReminderStateStore.appSuiteName.
STATE_SUITE := $(BUNDLE_ID).state
CORE_TARGET := CalendarShouterCore
EXEC_TARGET := CalendarShouter

CONFIG ?= debug

# Signing.
#
#   SIGN_IDENTITY=auto     (default) sign with the self-signed certificate. Its
#                          Designated Requirement — and so every calendar,
#                          reminders, automation and keychain grant macOS
#                          remembers — stays the same across rebuilds. Fetch it
#                          with SIGNING_SOURCE:
#                            op   (default) 1Password, the OP_ITEM_REF item below
#                            env            $SIGNING_P12_BASE64 + $SIGNING_P12_PASSWORD
#   SIGN_IDENTITY=-        ad-hoc: nothing to set up, but the code hash changes
#                          on every rebuild, so macOS forgets those grants.
#   SIGN_IDENTITY=<name>   an identity already in a keychain, e.g.
#                          "Developer ID Application: Foo (TEAMID)".
#
# SIGN_OPTIONS carries extra codesign flags and is empty on purpose: hardened
# runtime has no team to pin under a self-signed certificate, and --timestamp
# wants Apple's TSA, which means nothing without notarisation. Pass
# SIGN_OPTIONS='--options runtime --timestamp' for a Developer ID build.
SIGN_IDENTITY ?= auto
SIGNING_SOURCE ?= op
OP_ITEM_REF ?= CalendarShouter Signing
SIGN_OPTIONS ?=

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

# The helper owns the keychain items so their access control follows a stable
# code identity instead of the app's per-build cdhash.
#
# The artifact is COMMITTED, so assembling an app never needs the toolchain that
# produced it — the bundle gets the tracked binary. `-Wl,-no_uuid` only makes a
# build reproducible within one toolchain, and CI and a dev machine do not share
# one: a different SDK gives a different cdhash, which silently re-prompts every
# user. Committing the binary and pinning its hash takes that out of the release
# path.
#
# After editing Tools/KeychainHelper/main.c:
#   make build-keychain-helper    build it, failing with the new cdhash if it no
#                                 longer reproduces the pin
#   set HELPER_CDHASH to that value, then
#   make stage-keychain-helper    adopt it: overwrite the tracked binary and git add
HELPER_NAME := $(APP_NAME)KeychainHelper
HELPER_BIN := $(BUILD_DIR)/$(HELPER_NAME)
HELPER_TRACKED := Tools/KeychainHelper/$(HELPER_NAME)
HELPER_STORE_LINK := $(BUILD_DIR)/helper-store
HELPER_ATTR := .\#keychain-helper

# The helper's identity, as macOS sees it: its keychain items are pinned to this
# hash, so changing it makes every installed copy ask for permission again. That
# is invisible at build time and only shows up on users' machines, so it is
# checked instead of trusted. The value is the helper BEFORE signing, which keeps
# it independent of the certificate. `stage-keychain-helper` maintains it.
HELPER_CDHASH := 559514fceee8a1c783543c1bd5b7a4c42e4b2611

.DEFAULT_GOAL := help

.PHONY: help format lint localize build test icon build-keychain-helper stage-keychain-helper app sign signing-cert package notarize run demo demo-missed demo-reminder dev reset-permissions reset-data clean release

help: ## Show this help.
	@printf '%s\n' "CalendarShouter $(VERSION) — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%s\t\033[0m %s\n", $$1, $$2}' | column -t -s $$'\t'

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

build-keychain-helper: ## Build into $(BUILD_DIR) and fail if it no longer reproduces the pin.
	@mkdir -p "$(BUILD_DIR)"
	nix build $(HELPER_ATTR) --out-link "$(HELPER_STORE_LINK)"
	@install -m 755 "$(HELPER_STORE_LINK)/bin/$(HELPER_NAME)" "$(HELPER_BIN)"
	@printf '%s\n' "Built $(HELPER_BIN)"
	@actual=$$(codesign -d -vvv "$(HELPER_BIN)" 2>&1 | sed -n 's/^CDHash=//p'); \
	if [ "$$actual" != "$(HELPER_CDHASH)" ]; then \
		printf '%s\n' \
			"error: the helper built from source no longer reproduces the pin." \
			"  pinned:     $(HELPER_CDHASH)" \
			"  built:      $${actual:-<none>}" \
			"" \
			"The helper's source, or the toolchain the flake pins, has changed. If" \
			"that is intended, set HELPER_CDHASH in this Makefile to $$actual and run" \
			"'make stage-keychain-helper'; every existing install will then authorise" \
			"once more."; \
		exit 1; \
	fi
	@printf '%s\n' "Keychain helper build reproduces the pin."

stage-keychain-helper: build-keychain-helper ## Adopt the built helper: overwrite the tracked binary and git add.
	@install -m 755 "$(HELPER_BIN)" "$(HELPER_TRACKED)"
	@git add "$(HELPER_TRACKED)"
	@printf '%s\n' "Staged $(HELPER_TRACKED); the Makefile is left for you to review and commit."

app: build icon ## Assemble $(APP_NAME).app from the tracked helper (no Nix needed).
	@actual=$$(codesign -d -vvv "$(HELPER_TRACKED)" 2>&1 | sed -n 's/^CDHash=//p'); \
	if [ "$$actual" != "$(HELPER_CDHASH)" ]; then \
		printf '%s\n' \
			"error: the tracked keychain helper does not match HELPER_CDHASH." \
			"  pinned:     $(HELPER_CDHASH)" \
			"  tracked:    $${actual:-<none>}" \
			"" \
			"Packaging this would ship a helper whose keychain items every user has" \
			"to authorise again. Run 'make stage-keychain-helper' if the change is" \
			"intended, or restore Tools/KeychainHelper/$(HELPER_NAME)."; \
		exit 1; \
	fi
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_DIR)/$(EXEC_TARGET)" "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_TARGET)"
	@cp "$(HELPER_TRACKED)" "$(APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)"
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

sign: app ## Codesign the app bundle (see SIGN_IDENTITY).
	@SIGN_IDENTITY='$(SIGN_IDENTITY)' SIGNING_SOURCE='$(SIGNING_SOURCE)' \
		SIGN_OPTIONS='$(SIGN_OPTIONS)' OP_ITEM_REF='$(OP_ITEM_REF)' \
		Tools/sign-app.sh "$(APP_BUNDLE)"
	@codesign --verify --verbose=2 "$(APP_BUNDLE)"

signing-cert: ## Create the self-signed certificate the app is signed with.
	Tools/create-signing-cert.sh "$(BUILD_DIR)/signing"

package: sign ## Produce a distributable zip in .build/dist.
	@mkdir -p "$(DIST_DIR)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"
	@printf '%s\n' "Created $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"

notarize: ## Notarize and staple the packaged app (requires Developer ID + NOTARY_PROFILE).
	@case "$(SIGN_IDENTITY)" in \
	-|auto) \
		printf '%s\n' \
			"error: notarisation needs a Developer ID Application identity." \
			"Set SIGN_IDENTITY to it and SIGN_OPTIONS='--options runtime --timestamp'."; \
		exit 1; \
		;; \
	esac
	@if [ -z "$$NOTARY_PROFILE" ]; then \
		printf '%s\n' "error: set NOTARY_PROFILE to a notarytool keychain profile."; \
		exit 1; \
	fi
	xcrun notarytool submit "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip" \
		--keychain-profile "$$NOTARY_PROFILE" --wait
	xcrun stapler staple "$(APP_BUNDLE)"

run: sign ## Build, bundle and launch the app.
	open "$(APP_BUNDLE)"

rerun: sign ## Build, bundle, and relaunch the app with settings window open.
	pkill -f "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" || true
	open -n "$(APP_BUNDLE)" --args --open-settings

demo: sign ## Show a demo calendar reminder to inspect the panel.
	open -n "$(APP_BUNDLE)" --args --demo-calendar

demo-missed: sign ## Show a demo missed calendar reminder backlog to inspect the summary panel.
	open -n "$(APP_BUNDLE)" --args --demo-calendar-missed

demo-reminder: sign ## Show a demo Reminders-app reminder to inspect the panel.
	open -n "$(APP_BUNDLE)" --args --demo-reminder

dev: localize ## Run without bundling. Calendar access and the login item do not work.
	$(SWIFT) run -c $(CONFIG)

reset-permissions: ## Forget the app's calendar and reminders permission decisions.
	tccutil reset Calendar $(BUNDLE_ID)
	tccutil reset Reminders $(BUNDLE_ID)
	@printf '%s\n' "Reset. Relaunch with 'make run' to be asked again."

reset-data: ## Forget the app's preferences and the scheduler's bookkeeping.
	@pkill -f "$(APP_BUNDLE)/Contents/MacOS" 2>/dev/null || true
	@-defaults delete $(BUNDLE_ID)
	@-defaults delete $(STATE_SUITE)
	@printf '%s\n' "Preferences and bookkeeping cleared (menu bar icon shown, every calendar off, reminders on, Glass)."

clean: ## Remove all build products.
	rm -rf "$(BUILD_DIR)"
	@find "$(RESOURCES_DIR)" -maxdepth 1 -name '*.lproj' -type d -exec rm -rf {} + 2>/dev/null || true

release: ## Clean release build, tested and packaged.
	$(MAKE) clean
	$(MAKE) CONFIG=release test
	$(MAKE) CONFIG=release package
