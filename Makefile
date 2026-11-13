# Builds Backstage.app from the Swift package with the Command Line Tools alone, and installs it.
#   make app       build/Backstage.app, signed ad hoc; `setup` signs the installed copy with this Mac's identity
#   make install   make app, then run its setup: install into /Applications, permissions, MCP registration
#   make test      the tests (Swift Testing; the live ones need LIVE=1, an installed app and its permissions)
#   make tsan      the tests under the thread sanitizer
#   make lint      SwiftLint with .swiftlint.yml (brew install swiftlint)
#   make hooks     lint the Swift files of each commit before it is made (.githooks/pre-commit)
#   make live      the live test against the installed app (needs its Accessibility; operates a test app in the background)
#   make bench     latency against the installed app
#   make check     what CI runs
# SWIFT_BUILD_FLAGS goes to every `swift build`; the Homebrew formula passes --disable-sandbox, since SwiftPM's own
# sandbox cannot start inside Homebrew's. Warnings fail the build (Package.swift); ALLOW_WARNINGS=1, which the formula
# passes, keeps them warnings.

PRODUCT := Sources/HelperLink/Product.swift
APP_NAME := $(shell sed -n 's/.*static let appName = "\(.*\)"/\1/p' $(PRODUCT))
VERSION := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' $(PRODUCT))
BUNDLE_ID := $(shell sed -n 's/.*static let bundleIdentifier = "\(.*\)"/\1/p' $(PRODUCT))
MINIMUM_MACOS := $(shell sed -n 's/.*static let minimumMacOS = \([0-9]*\).*/\1/p' $(PRODUCT))
HANDOFF_KEY := $(shell sed -n 's/.*static let sessionHandoffKey = "\(.*\)"/\1/p' $(PRODUCT))
HANDOFF_REVISION := $(shell sed -n 's/.*static let sessionHandoffRevision = \([0-9]*\).*/\1/p' $(PRODUCT))
COMMAND := $(shell echo $(APP_NAME) | tr A-Z a-z)
SWIFT_BUILD_FLAGS ?=
SWIFT_BUILD := swift build -c release --arch arm64 $(SWIFT_BUILD_FLAGS)
BUILD = $(shell $(SWIFT_BUILD) --show-bin-path)
APP := build/$(APP_NAME).app

.PHONY: app install test tsan lint hooks live bench check clean

app:
	$(SWIFT_BUILD) --product $(APP_NAME)
	$(SWIFT_BUILD) --product $(COMMAND)-tool
	rm -rf $(APP).partial
	mkdir -p $(APP).partial/Contents/MacOS $(APP).partial/Contents/Helpers $(APP).partial/Contents/Resources
	cp "$(BUILD)/$(APP_NAME)" $(APP).partial/Contents/MacOS/$(APP_NAME)
	cp "$(BUILD)/$(COMMAND)-tool" $(APP).partial/Contents/Helpers/$(COMMAND)
	cp assets/AppIcon.icns assets/Assets.car $(APP).partial/Contents/Resources/
	sed -e 's/@APP_NAME@/$(APP_NAME)/g' -e 's/@VERSION@/$(VERSION)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
	    -e 's/@MINIMUM_MACOS@/$(MINIMUM_MACOS)/g' -e 's/@HANDOFF_KEY@/$(HANDOFF_KEY)/g' -e 's/@HANDOFF_REVISION@/$(HANDOFF_REVISION)/g' packaging/Info.plist > $(APP).partial/Contents/Info.plist
	plutil -lint -s $(APP).partial/Contents/Info.plist
	codesign --force --sign - --identifier $(BUNDLE_ID).command $(APP).partial/Contents/Helpers/$(COMMAND)
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP).partial
	codesign --verify --strict $(APP).partial
	rm -rf $(APP)
	mv $(APP).partial $(APP)

install: app
	$(APP)/Contents/Helpers/$(COMMAND) setup

test:
	swift test

# The helper and the command the tests start write their reports to files, since the tests discard their output.
tsan:
	rm -rf .build/tsan-reports && mkdir -p .build/tsan-reports
	TSAN_OPTIONS=log_path=$(CURDIR)/.build/tsan-reports/report swift test --sanitize=thread
	@if ls .build/tsan-reports/report.* >/dev/null 2>&1; then cat .build/tsan-reports/report.*; exit 1; fi

lint:
	swiftlint lint --strict --quiet

# Installs into the repository's own hooks folder, not core.hooksPath, so hooks set up for every repository stay on.
# The installed hook runs the tracked one, so changes to it apply; another hook already there is left alone.
hooks:
	@hook="$$(git rev-parse --git-common-dir)/hooks/pre-commit"; \
	if [ -e "$$hook" ] && ! grep -q 'Installed by make hooks' "$$hook"; then echo "$$hook exists; call .githooks/pre-commit from it instead." >&2; exit 1; fi; \
	mkdir -p "$$(dirname "$$hook")"; \
	printf '%s\n' '#!/bin/sh' '# Installed by make hooks: runs the tracked .githooks/pre-commit.' 'exec "$$(git rev-parse --show-toplevel)/.githooks/pre-commit" "$$@"' > "$$hook"; \
	chmod +x "$$hook"; echo "Installed $$hook"

live:
	LIVE=1 swift test --filter LiveTests

bench:
	BENCH=1 swift test --filter BenchTests

check: lint app test

clean:
	rm -rf build .build
