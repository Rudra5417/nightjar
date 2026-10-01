#!/bin/bash
# Build Nightjar for the phone, install it, and stream its console.
#
# Prerequisite: an Apple ID signed into Xcode (Xcode > Settings > Accounts > +).
# Nothing here touches credentials — Xcode holds them, and -allowProvisioningUpdates
# mints the 7-day profile from them. Without an account this fails with
# "No Accounts: Add a new account in Accounts settings."
#
# Usage:  scripts/run-on-device.sh [--build-only]
set -uo pipefail

UDID="${NIGHTJAR_UDID:-DEVICE-UDID}"
TEAM="${NIGHTJAR_TEAM:-TEAMID}"
BUNDLE="com.rudrapatel.nightjar"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/.build-device"
APP="$DD/Build/Products/Debug-iphoneos/Nightjar.app"

echo "==> building for $UDID (team $TEAM)"
if ! xcodebuild -project "$ROOT/Nightjar.xcodeproj" -scheme Nightjar \
        -destination "id=$UDID" -configuration Debug \
        -derivedDataPath "$DD" \
        -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
        build > /tmp/nightjar-device-build.log 2>&1; then
    echo "BUILD FAILED — tail of /tmp/nightjar-device-build.log:"
    grep -E "error:" /tmp/nightjar-device-build.log | head -10
    echo
    echo "If it says 'No Accounts', add your Apple ID in Xcode > Settings > Accounts."
    exit 1
fi
echo "==> build ok"
[ "$1" = "--build-only" ] && exit 0

echo "==> installing (phone must be unlocked and reachable)"
if ! xcrun devicectl device install app --device "$UDID" "$APP" > /tmp/nightjar-install.log 2>&1; then
    echo "INSTALL FAILED — tail of /tmp/nightjar-install.log:"
    tail -5 /tmp/nightjar-install.log
    echo
    echo "Most common cause: the phone is locked, or Developer Mode is off"
    echo "(Settings > Privacy & Security > Developer Mode)."
    exit 1
fi
echo "==> installed; streaming console (ctrl-c to stop)"
echo "    look for: [nightjar] live activity started"
xcrun devicectl device process launch --device "$UDID" --console "$BUNDLE"
