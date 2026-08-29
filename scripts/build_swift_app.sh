#!/usr/bin/env bash
set -euo pipefail

# Build the OpenZombr .app bundle from the SwiftPM executable.
#
# Usage:
#   ./scripts/build_swift_app.sh
#
# Environment:
#   VERSION=1.2.3               Override the version written into Info.plist.
#                               Defaults to the newest release in CHANGELOG.md.
#   CONFIGURATION=debug         Build debug instead of release.
#   CODESIGN_IDENTITY="..."     Explicit signing identity.
#   SKIP_SIGN=1                 Do not code sign at all (CI / smoke checks).
#
# The bundle is written to dist/OpenZombr.app. Installation is a separate step
# (`make install`), so this script never touches /Applications.

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="OpenZombr"
BUNDLE_ID="com.openzombr.app"
CONFIGURATION="${CONFIGURATION:-release}"
SKIP_SIGN="${SKIP_SIGN:-0}"

version_from_changelog() {
  grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null \
    | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/' || true
}

VERSION="${VERSION:-$(version_from_changelog)}"
VERSION="${VERSION:-0.0.0}"

echo "=== Building $APP_NAME $VERSION ($CONFIGURATION) ==="
swift build -c "$CONFIGURATION"

BINARY_PATH=".build/$CONFIGURATION/$APP_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH" >&2
  exit 1
fi

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Info.plist carries LSUIElement=true, which is what keeps this a menu-bar-only app
# with no Dock icon.
sed "s/__VERSION__/$VERSION/g" "Sources/$APP_NAME/Info.plist" > "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

plutil -lint "$APP_DIR/Contents/Info.plist" > /dev/null
if ! plutil -extract LSUIElement raw "$APP_DIR/Contents/Info.plist" | grep -q '^true$'; then
  echo "Info.plist is missing LSUIElement=true; the app would show a Dock icon." >&2
  exit 1
fi
if ! plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist" | grep -q "^$BUNDLE_ID$"; then
  echo "Info.plist bundle identifier does not match $BUNDLE_ID." >&2
  exit 1
fi

find_signing_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CODESIGN_IDENTITY"
    return 0
  fi
  local identities label identity
  # `find-identity -v` still lists certificates it knows to be unusable, tagging them with
  # a `(CSSMERR_...)` reason — a revoked "Apple Development" cert was picked ahead of a
  # perfectly good "Developer ID Application" one and failed the build outright. Drop the
  # tagged lines so an unusable certificate is treated as absent rather than preferred.
  identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -v 'CSSMERR_' || true)"
  for label in "Apple Development" "Developer ID Application"; do
    identity="$(printf '%s\n' "$identities" | grep "$label" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
    if [[ -n "$identity" ]]; then
      printf '%s\n' "$identity"
      return 0
    fi
  done
  return 1
}

if [[ "$SKIP_SIGN" == "1" ]]; then
  echo "Skipping code signing"
else
  IDENTITY="$(find_signing_identity || true)"
  if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_DIR"
  else
    # Ad-hoc signing keeps a stable-enough identity for UserDefaults and notification
    # permissions on a single machine.
    echo "No signing identity found; ad-hoc signing instead."
    codesign --force --sign - "$APP_DIR"
  fi
  codesign --verify --verbose=2 "$APP_DIR"
fi

echo "Bundle: $APP_DIR"
echo "Bundle id: $BUNDLE_ID"
echo "=== Build complete ==="
