#!/bin/sh
# Builds a release binary and assembles build/Notes.app, then registers it with LaunchServices.
set -eu

cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Notes"

APP=build/Notes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notes"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Notes</string>
    <key>CFBundleIdentifier</key><string>com.vefa.notes</string>
    <key>CFBundleName</key><string>Notes</string>
    <key>CFBundleDisplayName</key><string>Notes</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>tr</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>LSItemContentTypes</key>
            <array><string>net.daringfireball.markdown</string></array>
        </dict>
        <dict>
            <!-- Alternate: listed under "Open With", never made the default for these types. -->
            <key>CFBundleTypeName</key><string>Metin ve Kod</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.json</string>
                <string>public.plain-text</string>
                <string>public.utf8-plain-text</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.shell-script</string>
                <string>public.python-script</string>
                <string>public.swift-source</string>
                <string>com.netscape.javascript-source</string>
                <string>public.c-source</string>
                <string>public.c-header</string>
                <string>public.c-plus-plus-source</string>
                <string>public.objective-c-source</string>
                <string>com.sun.java-source</string>
                <string>public.yaml</string>
                <string>public.xml</string>
                <string>public.html</string>
                <string>public.css</string>
                <string>public.comma-separated-values-text</string>
                <string>public.log</string>
                <string>public.svg-image</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
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
                <array><string>text/markdown</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $(pwd)/$APP"
