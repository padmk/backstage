# Builds Backstage.app from the Swift package with the Command Line Tools alone, and installs it.
#   make app       build/Backstage.app, signed ad hoc; `setup` signs the installed copy with this Mac's identity
#   make install   make app, then run its setup: install into /Applications, permissions, MCP registration
#   make test      the tests (Swift Testing; the live ones need LIVE=1, an installed app and its permissions)
#   make live      the live test against the installed app (needs its Accessibility; operates a test app in the background)
#   make bench     latency against the installed app
#   make check     what CI runs

PRODUCT := Sources/HelperLink/Product.swift
APP_NAME := $(shell sed -n 's/.*static let appName = "\(.*\)"/\1/p' $(PRODUCT))
VERSION := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' $(PRODUCT))
BUNDLE_ID := $(shell sed -n 's/.*static let bundleIdentifier = "\(.*\)"/\1/p' $(PRODUCT))
MINIMUM_MACOS := $(shell sed -n 's/.*static let minimumMacOS = \([0-9]*\).*/\1/p' $(PRODUCT))
HANDOFF_KEY := $(shell sed -n 's/.*static let sessionHandoffKey = "\(.*\)"/\1/p' $(PRODUCT))
HANDOFF_REVISION := $(shell sed -n 's/.*static let sessionHandoffRevision = \([0-9]*\).*/\1/p' $(PRODUCT))
COMMAND := $(shell echo $(APP_NAME) | tr A-Z a-z)
BUILD = $(shell swift build -c release --arch arm64 --show-bin-path)
APP := build/$(APP_NAME).app

.PHONY: app install test live bench check clean

app:
	swift build -c release --arch arm64 --product $(APP_NAME)
	swift build -c release --arch arm64 --product $(COMMAND)-tool
	rm -rf $(APP).partial
	mkdir -p $(APP).partial/Contents/MacOS $(APP).partial/Contents/Helpers $(APP).partial/Contents/Resources
	cp $(BUILD)/$(APP_NAME) $(APP).partial/Contents/MacOS/$(APP_NAME)
	cp $(BUILD)/$(COMMAND)-tool $(APP).partial/Contents/Helpers/$(COMMAND)
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

live:
	LIVE=1 swift test --filter LiveTests

bench:
	BENCH=1 swift test --filter BenchTests

check: app test

clean:
	rm -rf build .build
