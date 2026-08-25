#!/bin/bash
# Build, package, codesign (ad-hoc) and install the markdown-lib.app bundle.
# Usage: bash scripts/make-app-bundle.sh [version]
#   If [version] is omitted, reads $ROOT/VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -ge 1 ]; then
    VERSION="$1"
elif [ -f "$ROOT/VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
else
    VERSION="0.0.0"
fi
if [ -z "$VERSION" ]; then
    echo "VERSION is empty" >&2
    exit 1
fi
echo "==> version: $VERSION"

echo "==> swift build -c release"
(cd "$ROOT" && swift build -c release)

BIN="$ROOT/.build/release/markdown-lib"
if [ ! -x "$BIN" ]; then
    echo "Binary not found at $BIN" >&2
    exit 1
fi

DIST="$ROOT/dist"
APP="$DIST/markdown-lib.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/markdown-lib"

# Copy the SwiftPM-generated resource bundle next to the binary so Bundle.module resolves at runtime.
BUNDLE_NAME="markdown-lib_MarkdownEditor.bundle"
BUNDLE_SRC="$(dirname "$BIN")/${BUNDLE_NAME}"
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP/Contents/MacOS/"
    # SwiftPM emits a flat resource bundle without an Info.plist, but codesign
    # insists on both Contents/Info.plist and Contents/Resources/. Repackage in
    # place so `codesign --deep` accepts it while Bundle.module can still find
    # the toastui assets.
    RES_BUNDLE="$APP/Contents/MacOS/${BUNDLE_NAME}"
    if [ -d "$RES_BUNDLE/Resources" ] && [ ! -d "$RES_BUNDLE/Contents/Resources" ]; then
        mkdir -p "$RES_BUNDLE/Contents"
        mv "$RES_BUNDLE/Resources" "$RES_BUNDLE/Contents/Resources"
    fi
    cat > "$RES_BUNDLE/Contents/Info.plist" <<BPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.liuhe.markdown-lib.resources</string>
    <key>CFBundleName</key><string>markdown-lib_markdown-lib</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
</dict>
</plist>
BPLIST
fi

# Bundle an app icon if present at the repo root.
if [ -f "$ROOT/AppIcon.icns" ]; then
    cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>markdown-lib</string>
    <key>CFBundleDisplayName</key><string>Markdown Lib</string>
    <key>CFBundleIdentifier</key><string>com.liuhe.markdown-lib</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>markdown-lib</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>com.liuhe.markdown-lib.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.liuhe.markdown-lib.markdown</string>
            <key>UTTypeDescription</key><string>Markdown Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>md</string>
                    <string>markdown</string>
                    <string>mdown</string>
                    <string>mkd</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>text/markdown</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper doesn't block launch on first run.
echo "==> codesign --force --deep --sign -"
codesign --force --deep --sign - "$APP"

# Install to ~/Applications so Launch Services + Dock pick it up.
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
INSTALL_PATH="$INSTALL_DIR/markdown-lib.app"
rm -rf "$INSTALL_PATH"
cp -R "$APP" "$INSTALL_PATH"

# Nudge Launch Services so the file associations take effect immediately.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$INSTALL_PATH" || true
fi

echo "Built  $APP"
echo "Installed $INSTALL_PATH"
