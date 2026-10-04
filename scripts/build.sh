#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -n 1)"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "No Developer ID signing identity found. Set CODE_SIGN_IDENTITY to a stable signing identity." >&2
    echo "For an explicitly ad-hoc build, use CODE_SIGN_IDENTITY=- (Accessibility may reset after rebuilds)." >&2
    exit 1
fi
# Where the bundle lands (default dist/). VELOCITY_DIST=dist/farewell builds BESIDE the copy he is running.
DIST="${VELOCITY_DIST:-$PWD/dist}"
case "${VELOCITY_EXPERIMENTAL:-0}" in
    0) swift build -c release; APP="$DIST/Terminal Velocity.app" ;;
    1) swift build -c release -Xswiftc -DVELOCITY_EXPERIMENTAL; APP="$DIST/private/Terminal Velocity.app" ;;
    *) echo "VELOCITY_EXPERIMENTAL must be 0 or 1" >&2; exit 1 ;;
esac
# BUILD BESIDE, THEN SWAP. Overwriting the bundle of a RUNNING Velocity in place changed the
# pages under the live process and macOS killed it ("Code Signature Invalid" — three times on
# 2026-10-03, each one silently taking ⌥Space with it). A fresh bundle swapped in by rename
# leaves the running copy's files intact; the next launch picks up the new one.
FINAL="$APP"
APP="$FINAL.staging"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TerminalVelocity "$APP/Contents/MacOS/TerminalVelocity"
node scripts/directory-inspector.verify.ts
cp resources/directory-inspector.py "$APP/Contents/Resources/directory-inspector.py"
# Give changed artwork a new resource URL so macOS does not reuse the old icon.
ICON_HASH="$(shasum -a 256 resources/AppIcon.icns | cut -c 1-16)"
ICON_NAME="AppIcon-$ICON_HASH"
cp resources/AppIcon.icns "$APP/Contents/Resources/$ICON_NAME.icns"
cp resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_NAME" "$APP/Contents/Info.plist"
if [[ "${VELOCITY_EXPERIMENTAL:-0}" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Set :VelocityExperimental true" "$APP/Contents/Info.plist"
fi
codesign --force --options runtime --timestamp=none --entitlements resources/entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
rm -rf "$FINAL.old"
if [[ -d "$FINAL" ]]; then mv "$FINAL" "$FINAL.old"; fi
mv "$APP" "$FINAL"
rm -rf "$FINAL.old"
APP="$FINAL"
# Refresh this bundle only; do not reset the user's Launch Services database.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built: $APP"
