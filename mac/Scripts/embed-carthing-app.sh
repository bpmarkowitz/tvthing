#!/bin/sh
# Copies the packaged Car Thing webapp into the Mac app so users can install it from
# Settings → Car Thing. Build it first with `npm run package` in ../carthing.
set -eu
BUNDLE="${SRCROOT}/../carthing/dist/TVThing-CarThing.zip"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ -f "$BUNDLE" ]; then
  mkdir -p "$DEST"
  cp "$BUNDLE" "$DEST/TVThing-CarThing.zip"
else
  echo "warning: Car Thing app not built; run 'npm run package' in carthing/ to embed it."
fi
