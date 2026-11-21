#!/usr/bin/env bash
# Validates an unsigned iPlay5 .ipa for SideStore/AltStore/Sideloadly installation.
set -Eeuo pipefail

# ::error:: lines show up as GitHub annotations, readable without opening the log.
fail() {
	echo "::error title=verify-ipa::$*"
	echo "ERROR: $*" >&2
	exit 1
}
trap 'echo "::error title=verify-ipa::line $LINENO failed: $BASH_COMMAND"' ERR

IPA="${1:-build/iPlay5.ipa}"
if [ ! -s "$IPA" ]; then
	fail "IPA not found or empty: $IPA"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$IPA" -d "$TMP"
if [ ! -d "$TMP/Payload" ]; then
	fail "Payload/ directory missing from $IPA"
fi

APP="$(find "$TMP/Payload" -maxdepth 1 -name '*.app' | head -n 1)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
	fail "No .app bundle found inside Payload/ of $IPA"
fi

PLIST="$APP/Info.plist"
if [ ! -f "$PLIST" ]; then
	fail "Missing Info.plist in $APP"
fi

plutil -lint "$PLIST" >/dev/null

plist_val() {
	/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}

BUNDLE_ID="$(plist_val CFBundleIdentifier)"
if [ -z "$BUNDLE_ID" ]; then
	fail "CFBundleIdentifier is missing or empty"
fi

EXEC="$(plist_val CFBundleExecutable)"
if [ -z "$EXEC" ] || [ ! -s "$APP/$EXEC" ]; then
	fail "Missing or empty executable '$EXEC' in $APP"
fi

ARCHS="$(lipo -archs "$APP/$EXEC" 2>/dev/null || file "$APP/$EXEC")"
if ! echo "$ARCHS" | grep -q "arm64"; then
	fail "Binary '$EXEC' is not arm64: $ARCHS"
fi

HIGH_REFRESH="$(plist_val CADisableMinimumFrameDurationOnPhone)"
if [ "$HIGH_REFRESH" != "true" ]; then
	fail "CADisableMinimumFrameDurationOnPhone must be true (got '$HIGH_REFRESH')"
fi

GAME_MODE="$(plist_val GCSupportsGameMode)"
if [ "$GAME_MODE" != "true" ]; then
	fail "GCSupportsGameMode must be true (got '$GAME_MODE')"
fi

LAN_DESC="$(plist_val NSLocalNetworkUsageDescription)"
if [ -z "$LAN_DESC" ]; then
	fail "NSLocalNetworkUsageDescription is missing or empty"
fi

if ! find "$APP" -name 'default.metallib' | grep -q .; then
	fail "Compiled Metal shader library default.metallib not found in $APP"
fi

if find "$APP" \( -name '*.entitlements' -o -name '*.xcent' \) -exec grep -E -q '(com\.apple\.developer\.networking\.multicast|aps-environment|com\.apple\.developer\.icloud)' {} +; then
	fail "Paid-only entitlements found that would block free sideloading"
fi

echo "Verified $IPA: $EXEC ($BUNDLE_ID, $ARCHS), Info.plist, default.metallib, sideload-safe entitlements"
