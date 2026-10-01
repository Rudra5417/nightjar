#!/bin/bash
# Build Nightjar for a physical iPhone, install it, and stream its console.
#
# Prerequisite: an Apple ID signed into Xcode (Xcode > Settings > Accounts > +).
# Nothing here touches credentials — Xcode holds them, and -allowProvisioningUpdates
# mints the 7-day profile from them. Without an account this fails with
# "No Accounts: Add a new account in Accounts settings."
#
# The target device is discovered, never hardcoded: no UDID and no team id is stored in this
# repository. Override with NIGHTJAR_UDID / NIGHTJAR_TEAM when several devices are attached.
#
# Usage:  scripts/run-on-device.sh [--build-only]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${NIGHTJAR_BUNDLE:-com.rudrapatel.nightjar}"
DD="$ROOT/.build-device"
APP="$DD/Build/Products/Debug-iphoneos/Nightjar.app"

UDID="${NIGHTJAR_UDID:-$(xcrun devicectl list devices 2>/dev/null \
    | grep physical | grep -E 'available|connected' \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' | head -1)}"
if [ -z "$UDID" ]; then
    echo "No physical device found."
    echo "  plug the phone in (or put it on the same Wi-Fi) and unlock it, then check:"
    echo "    xcrun devicectl list devices"
    echo "  or target one explicitly with NIGHTJAR_UDID=<udid>."
    exit 1
fi

# Only needed when the Xcode account holds more than one team.
TEAM_ARGS=()
[ -n "${NIGHTJAR_TEAM:-}" ] && TEAM_ARGS=("DEVELOPMENT_TEAM=${NIGHTJAR_TEAM}")

echo "==> building for $UDID"
if ! xcodebuild -project "$ROOT/Nightjar.xcodeproj" -scheme Nightjar \
        -destination "id=$UDID" -configuration Debug \
        -derivedDataPath "$DD" \
        -allowProvisioningUpdates ${TEAM_ARGS[@]+"${TEAM_ARGS[@]}"} \
        build > /tmp/nightjar-device-build.log 2>&1; then
    echo "BUILD FAILED — tail of /tmp/nightjar-device-build.log:"
    grep -E "error:" /tmp/nightjar-device-build.log | head -10
    echo
    echo "If it says 'No Accounts', add your Apple ID in Xcode > Settings > Accounts."
    exit 1
fi
echo "==> build ok"
[ "${1:-}" = "--build-only" ] && exit 0

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
xcrun devicectl device process launch --device "$UDID" --console "$BUNDLE"
