#!/bin/zsh
# Builds a universal Scene.app and packs it into build/Scene-<version>.dmg,
# with a shortcut to /Applications for drag-and-drop install.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Scene-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Scene.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Scene" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $PWD/$DMG"
