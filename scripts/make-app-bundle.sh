#!/bin/bash
# Package the release-built binary into a minimal markdown-editor.app bundle.
# Usage: bash scripts/make-app-bundle.sh <version> [binary-path]
#
# If binary-path is omitted, defaults to .build/release/markdown-editor.
set -euo pipefail

VERSION="${1:-0.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BIN="${2:-$ROOT/.build/release/markdown-editor}"
if [ ! -x "$BIN" ]; then
    echo "Binary not found at $BIN" >&2
    exit 1
fi

DIST="$ROOT/dist"
APP="$DIST/markdown-editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/markdown-editor"

# Copy the SwiftPM-generated resource bundle next to the binary so Bundle.module resolves at runtime.
BUNDLE_NAME="markdown-editor_markdown-editor.bundle"
BUNDLE_SRC="$(dirname "$BIN")/${BUNDLE_NAME}"
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP/Contents/MacOS/"
fi

if [ -f "$ROOT/AppIcon.icns" ]; then
    cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>markdown-editor</string>
    <key>CFBundleDisplayName</key><string>Markdown Editor</string>
    <key>CFBundleIdentifier</key><string>com.liuhe.markdown-editor</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>markdown-editor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Built $APP"
