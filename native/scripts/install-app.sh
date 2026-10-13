#!/bin/zsh
set -euo pipefail
NATIVE_ROOT="${0:A:h:h}"
SOURCE="${HERO_OOS_BUILD_DIR:-$HOME/Library/Caches/Hero OOS Build}/Hero OOS.app"
TARGET="$HOME/Applications/Hero OOS.app"
[[ -x "$SOURCE/Contents/MacOS/oos-state" ]] || { print -u2 'Run build-app.sh first.'; exit 1; }
if /usr/bin/pgrep -f "$TARGET/Contents/MacOS/HeroOOS" >/dev/null; then
  print -u2 'Quit Hero OOS before installing so pending edits can save.'
  exit 1
fi
mkdir -p "$HOME/Applications"
STAGE="$(/usr/bin/mktemp -d "$HOME/Applications/.hero-oos-install.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
/usr/bin/ditto --noextattr --norsrc "$SOURCE" "$STAGE/Hero OOS.app"
/usr/bin/xattr -dr com.apple.FinderInfo "$STAGE/Hero OOS.app" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$STAGE/Hero OOS.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/Hero OOS.app"
"$STAGE/Hero OOS.app/Contents/MacOS/oos-state" init
"$STAGE/Hero OOS.app/Contents/MacOS/oos-state" health
if [[ -d "$TARGET" ]]; then /bin/mv "$TARGET" "$STAGE/retired.app"; fi
if ! /bin/mv "$STAGE/Hero OOS.app" "$TARGET"; then
  [[ ! -d "$STAGE/retired.app" ]] || /bin/mv "$STAGE/retired.app" "$TARGET"
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$TARGET"
"$TARGET/Contents/MacOS/oos-state" health
/bin/rm -r -- "$SOURCE"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")
print "Installed Hero OOS $VERSION. Build copy removed; no rollback copy retained."
