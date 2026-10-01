# Common tasks. Build output goes outside the repo (iCloud-synced folders break code signing).
BUILD_DIR ?= $(TMPDIR)tvthing-build
# Optional, untracked Local.mk: `TEAM = <Apple team ID>` signs builds with your team;
# `NOTARY_PROFILE = <notarytool keychain profile>` also notarizes release downloads.
-include Local.mk

.PHONY: all carthing test integration app release server clean

all: carthing app

## Car Thing webapp → carthing/dist/TVThing-CarThing.zip
carthing:
	cd carthing && npm install --no-audit --no-fund && npm run package

## Unit tests for the Mac engine
test:
	cd mac/TVThingKit && swift test --scratch-path $(BUILD_DIR)/kit

## Live end-to-end tests (network + FFmpeg)
integration:
	cd mac/TVThingKit && TVTHING_INTEGRATION=1 swift test --scratch-path $(BUILD_DIR)/kit --filter EngineIntegrationTests

## The Mac app (embeds the Car Thing webapp if it has been built)
app:
	xcodebuild -project mac/TVThing.xcodeproj -scheme TVThing -configuration Release -derivedDataPath $(BUILD_DIR)/xcode $(if $(TEAM),DEVELOPMENT_TEAM=$(TEAM)) build
	@echo "Built $(BUILD_DIR)/xcode/Build/Products/Release/TV Thing.app"

## Downloads for a GitHub release, in dist/
VERSION := $(shell node -p "require('./carthing/package.json').version")
release: carthing
	BUILD_DIR="$(BUILD_DIR)" TEAM="$(TEAM)" NOTARY_PROFILE="$(NOTARY_PROFILE)" mac/Scripts/release.sh
	@echo "Release $(VERSION) is in dist/"

## Headless engine for Car Thing development: make server PACK=examples/channel-packs/starter-channels.tvthing
server:
	cd mac/TVThingKit && swift run --scratch-path $(BUILD_DIR)/kit tvthing-server $(if $(PACK),--pack $(abspath $(PACK)))

clean:
	rm -rf $(BUILD_DIR) carthing/dist
