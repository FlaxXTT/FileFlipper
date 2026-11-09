#!/usr/bin/env bash
# Builds FileFlipper.app into ./build for running on this Mac (ad-hoc signed, sandboxed like the App Store build).
#
#   ./scripts/build-app.sh             # build
#   ./scripts/build-app.sh --install   # also copy to /Applications
#
# Needs Xcode. Without Xcode it falls back to the Swift command-line tools
# (both builds use the same offline sandbox and localization resources).
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP="build/Proteus.app"
rm -rf "$APP"
mkdir -p build

if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -project FileFlipper.xcodeproj -scheme FileFlipper -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_DEBUG_DYLIB=NO \
    build > build/xcodebuild.log 2>&1 || {
      grep -E "error:" build/xcodebuild.log || tail -20 build/xcodebuild.log
      echo "Build failed. Full log: build/xcodebuild.log"
      exit 1
    }
  BUILT="build/DerivedData/Build/Products/Release/FileFlipper.app"
  cp -R "$BUILT" "$APP"
else
  echo "Xcode not found - building with the Swift command-line tools instead."
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/FileFlipper" "$APP/Contents/MacOS/FileFlipper"
  sed -e 's/$(EXECUTABLE_NAME)/FileFlipper/; s/$(PRODUCT_NAME)/FileFlipper/' \
      -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/local.fileflipper.offline/' \
      -e 's/$(MARKETING_VERSION)/1.5.3/; s/$(CURRENT_PROJECT_VERSION)/13/' \
      -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
      Resources/Info.plist > "$APP/Contents/Info.plist"
  # Icon for the command-line build
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  cp Resources/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
  cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
  cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
  codesign --force --options runtime --entitlements Resources/FileFlipper.entitlements --sign - "$APP"
fi

codesign --force --options runtime --entitlements Resources/FileFlipper.entitlements --sign - "$APP"

echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  # Finish the replacement before touching the installed app. Do not replace a running binary.
  if pgrep -f '^/Applications/Proteus.app/Contents/MacOS/FileFlipper$' >/dev/null; then
    echo "Quit Proteus before installing this build." >&2
    exit 1
  fi
  STAGED_APP="/Applications/.Proteus-install-$$.app"
  trap 'rm -rf "$STAGED_APP"' EXIT
  ditto "$APP" "$STAGED_APP"
  if [ -e /Applications/Proteus.app ]; then
    python3 - "$STAGED_APP" <<'PYINSTALL'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
if libc.renamex_np(os.fsencode(sys.argv[1]), b"/Applications/Proteus.app", 2) != 0:
    raise OSError(ctypes.get_errno(), "Could not exchange application bundles")
PYINSTALL
  else
    mv "$STAGED_APP" /Applications/Proteus.app
  fi
  echo "Installed to /Applications/Proteus.app"
fi
