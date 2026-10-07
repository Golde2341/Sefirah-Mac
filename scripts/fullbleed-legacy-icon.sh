#!/bin/bash
# Overwrites the helper's legacy app icon (.icns) with a full-bleed render.
#
# Why: macOS notification/tray icon slots fall back to the legacy .icns for the nested
# "Sefirah Phone" helper and expose the artwork's transparent margins as a light "well"
# around the tile (a thick gray outline). The Icon Composer export is inset by design, so
# before the target is signed we replace the .icns with an edge-to-edge render while the
# modern `.icon` asset keeps providing the correct dock/settings artwork.
#
# Required build settings (present in script phases): SRCROOT, TARGET_TEMP_DIR,
# TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH.

set -euo pipefail

SOURCE_PNG="$SRCROOT/SefirahPhoneLegacyIcon/icon-1024.png"
ICONSET="$TARGET_TEMP_DIR/legacy.iconset"
DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SefirahPhone.icns"

if [ ! -f "$SOURCE_PNG" ]; then
    echo "error: $SOURCE_PNG is missing" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

while read -r size name; do
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET/$name.png" >/dev/null
done <<'SPEC'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SPEC

iconutil -c icns "$ICONSET" -o "$DESTINATION"
