# Common tasks. Everything lives in app/: the Car Thing app, its settings page, and the
# Bridgething extension that runs on the computer.

.PHONY: all test dev release clean

## Builds and zips the app → app/dist/TVThing.zip (also typechecks and runs the tests)
all:
	cd app && npm install --no-audit --no-fund && npm run package

## Tests (needs Deno)
test:
	cd app && npm test

## Develop without a Car Thing: the extension on its own, plus a browser stand-in for Bridgething.
## Open http://localhost:5173/?browser (the Car Thing app) or /settings-dev (settings).
dev: all
	cd app && (deno run -A dist/extension-dev.mjs & npm run dev)

## The download for a GitHub release, in dist/
VERSION := $(shell node -p "require('./app/package.json').version")
release: all
	mkdir -p dist && cp app/dist/TVThing.zip dist/TVThing-$(VERSION).zip
	@echo "Release $(VERSION) is in dist/"

clean:
	rm -rf app/dist dist
