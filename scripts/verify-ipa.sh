#!/usr/bin/env bash
# Validates an unsigned iPlay5 .ipa for SideStore/AltStore/Sideloadly installation.
set -euo pipefail

IPA="${1:-build/iPlay5.ipa}"
if [ ! -s "$IPA" ]; then
	echo "ERROR: IPA not found or empty: $IPA" >&2
	exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$IPA" -d "$TMP"
if [ ! -d "$TMP/Payload" ]; then
	echo "ERROR: Payload/ directory missing from $IPA" >&2
	exit 1
fi

APP="$(find "$TMP/Payload" -maxdepth 1 -name '*.app' | head -n 1)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
	echo "ERROR: No .app bundle found inside Payload/ of $IPA" >&2
	exit 1
fi

PLIST="$APP/Info.plist"
if [ ! -f "$PLIST" ]; then
	echo "ERROR: Missing Info.plist in $APP" >&2
	exit 1
fi

plutil -lint "$PLIST" >/dev/null

plist_val() {
	/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}

BUNDLE_ID="$(plist_val CFBundleIdentifier)"
if [ -z "$BUNDLE_ID" ]; then
	echo "ERROR: CFBundleIdentifier is missing or empty" >&2
	exit 1
fi

EXEC="$(plist_val CFBundleExecutable)"
if [ -z "$EXEC" ] || [ ! -s "$APP/$EXEC" ]; then
	echo "ERROR: Missing or empty executable '$EXEC' in $APP" >&2
	exit 1
fi

ARCHS="$(lipo -archs "$APP/$EXEC" 2>/dev/null || file "$APP/$EXEC")"
if ! echo "$ARCHS" | grep -q "arm64"; then
	echo "ERROR: Binary '$EXEC' is not arm64: $ARCHS" >&2
	exit 1
fi

HIGH_REFRESH="$(plist_val CADisableMinimumFrameDurationOnPhone)"
if [ "$HIGH_REFRESH" != "true" ]; then
	echo "ERROR: CADisableMinimumFrameDurationOnPhone must be true (got '$HIGH_REFRESH')" >&2
	exit 1
fi

GAME_MODE="$(plist_val GCSupportsGameMode)"
if [ "$GAME_MODE" != "true" ]; then
	echo "ERROR: GCSupportsGameMode must be true (got '$GAME_MODE')" >&2
	exit 1
fi

LAN_DESC="$(plist_val NSLocalNetworkUsageDescription)"
if [ -z "$LAN_DESC" ]; then
	echo "ERROR: NSLocalNetworkUsageDescription is missing or empty" >&2
	exit 1
fi

if ! find "$APP" -name 'default.metallib' | grep -q .; then
	echo "ERROR: Compiled Metal shader library default.metallib not found in $APP" >&2
	exit 1
fi

if find "$APP" \( -name '*.entitlements' -o -name '*.xcent' \) -exec grep -E -q '(com\.apple\.developer\.networking\.multicast|aps-environment|com\.apple\.developer\.icloud)' {} +; then
	echo "ERROR: Paid-only entitlements found that would block free sideloading" >&2
	exit 1
fi

echo "Verified $IPA: $EXEC ($BUNDLE_ID, $ARCHS), Info.plist, default.metallib, sideload-safe entitlements"
