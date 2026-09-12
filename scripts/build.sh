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
case "${VELOCITY_EXPERIMENTAL:-0}" in
    0) swift build -c release; APP="$PWD/dist/Terminal Velocity.app" ;;
    1) swift build -c release -Xswiftc -DVELOCITY_EXPERIMENTAL; APP="$PWD/dist/private/Terminal Velocity.app" ;;
    *) echo "VELOCITY_EXPERIMENTAL must be 0 or 1" >&2; exit 1 ;;
esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TerminalVelocity "$APP/Contents/MacOS/TerminalVelocity"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp resources/Info.plist "$APP/Contents/Info.plist"
if [[ "${VELOCITY_EXPERIMENTAL:-0}" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Set :VelocityExperimental true" "$APP/Contents/Info.plist"
fi
codesign --force --options runtime --timestamp=none --entitlements resources/entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
