#!/bin/zsh
# Builds Scene with SwiftPM and assembles build/Scene.app.
#   ./build.sh              Apple Silicon build (fast, for development)
#   UNIVERSAL=1 ./build.sh  Apple Silicon + Intel build (for releases)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Scene.app"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --triple arm64-apple-macosx15.0
    swift build -c release --triple x86_64-apple-macosx15.0
    mkdir -p build
    lipo -create -output build/SceneApp \
        .build/arm64-apple-macosx/release/SceneApp \
        .build/x86_64-apple-macosx/release/SceneApp
    BIN="build/SceneApp"
else
    swift build -c release
    BIN=".build/release/SceneApp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SceneApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Signing. If a local signing keychain exists (signing/, not in the repository) the app is
# signed with that stable identity, so the Accessibility permission survives rebuilds.
# Otherwise it is signed ad hoc: macOS will ask for Accessibility again after each build.
KC="$PWD/signing/scene.keychain-db"
if [[ -f "$KC" ]] && security unlock-keychain -p scene "$KC" 2>/dev/null; then
    # The keychain has to be in the search list while codesign runs.
    OLD=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
    security list-keychains -d user -s "${OLD[@]}" "$KC"
    codesign --force --keychain "$KC" --sign "Scene Local Signing" \
        --identifier local.scenerecall.Scene "$APP" || STATUS=$?
    security list-keychains -d user -s "${OLD[@]}"
    [[ -z "${STATUS:-}" ]] || exit $STATUS
else
    codesign --force --sign - --identifier local.scenerecall.Scene "$APP"
fi
echo "Built $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/SceneApp"))"
