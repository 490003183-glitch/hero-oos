#!/bin/zsh
set -euo pipefail
NATIVE_ROOT="${0:A:h:h}"
cd "$NATIVE_ROOT"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp/}hero-oos-native-modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --disable-keychain --disable-netrc --cache-path .build/cache
# File Provider folders can recreate FinderInfo on nested .app/.xpc bundles during signing.
# Assemble and sign outside Documents, then copy only the verified result to dist.
BUILD_STAGE="$(/usr/bin/mktemp -d /private/tmp/hero-oos-build.XXXXXX)"
trap '/bin/rm -r -- "$BUILD_STAGE"' EXIT
NATIVE_APP="$BUILD_STAGE/Hero OOS.app"
mkdir -p "$NATIVE_APP/Contents/MacOS" "$NATIVE_APP/Contents/Resources" "$NATIVE_APP/Contents/Frameworks"
cp .build/release/HeroOOS "$NATIVE_APP/Contents/MacOS/HeroOOS"
cp .build/release/oos-state "$NATIVE_APP/Contents/MacOS/oos-state"
cp Resources/Info.plist "$NATIVE_APP/Contents/Info.plist"
# SwiftPM links the binary dependency but does not embed it in a hand-made app bundle.
SPARKLE_FRAMEWORKS=("$NATIVE_ROOT"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/*/Sparkle.framework(N/))
if (( ${#SPARKLE_FRAMEWORKS[@]} != 1 )); then
  echo "Expected one official Sparkle macOS framework; found ${#SPARKLE_FRAMEWORKS[@]}" >&2
  exit 1
fi
/usr/bin/ditto --noextattr --norsrc "${SPARKLE_FRAMEWORKS[1]}" "$NATIVE_APP/Contents/Frameworks/Sparkle.framework"
swift scripts/make-assets.swift "$NATIVE_ROOT"
/usr/bin/iconutil -c icns .build/HeroOOS.iconset -o "$NATIVE_APP/Contents/Resources/HeroOOS.icns"
/usr/bin/xattr -dr com.apple.FinderInfo "$NATIVE_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$NATIVE_APP"
/usr/bin/codesign --verify --deep --strict "$NATIVE_APP"
NATIVE_OUTPUT="${HERO_OOS_BUILD_DIR:-$HOME/Library/Caches/Hero OOS Build}"
mkdir -p "$NATIVE_OUTPUT"
/usr/bin/ditto --noextattr --norsrc "$NATIVE_APP" "$NATIVE_OUTPUT/Hero OOS.app"
/usr/bin/codesign --verify --deep --strict "$NATIVE_OUTPUT/Hero OOS.app"
echo "$NATIVE_OUTPUT/Hero OOS.app"
