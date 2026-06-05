#!/bin/bash
# Build a release DMG for pgAgent macOS app.
# Run after `xcodegen generate` and a successful Xcode archive build.
#
# Usage:
#   ./build_dmg.sh [path/to/pgAgent.app]
#
# If no path is given, looks in DerivedData for the latest build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="pgAgent"
DMG_NAME="${APP_NAME}.dmg"
VOLUME_NAME="${APP_NAME}"

# Locate the .app bundle
if [ $# -ge 1 ]; then
    APP_PATH="$1"
else
    # Find the most recently built .app in DerivedData
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "${APP_NAME}.app" -type d -maxdepth 4 2>/dev/null | sort -r | head -1)
fi

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at: ${APP_PATH:-<none>}"
    echo "   Pass the path: $0 /path/to/pgAgent.app"
    exit 1
fi

echo "📦 Building DMG from: $APP_PATH"

# Create a temporary directory for DMG staging
STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

# Copy app into staging
cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"

# Create symlink to Applications
ln -s /Applications "$STAGING/Applications"

# Build DMG
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

echo "✅ DMG created: $DMG_PATH"
echo "   Size: $(du -h "$DMG_PATH" | cut -f1)"
