#!/bin/sh
# Builds a release binary and assembles build/Notes.app, then registers it with LaunchServices.
set -eu

cd "$(dirname "$0")/.."
# SCRATCH_PATH and OUT_DIR are optional (build somewhere else than .build and build/); an OUT_DIR build is not registered.
set -- -c release
if [ -n "${SCRATCH_PATH:-}" ]; then set -- "$@" --scratch-path "$SCRATCH_PATH"; fi
swift build "$@"
BIN_DIR="$(swift build "$@" --show-bin-path)"
BIN="$BIN_DIR/Notes"

APP="${OUT_DIR:-build}/Notes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notes"

# SwiftPM resource bundles (string catalogs): Bundle.module finds them in Contents/Resources.
for NAME in Notes_Notes Notes_NotesCore; do
    cp -R "$BIN_DIR/$NAME.bundle" "$APP/Contents/Resources/$NAME.bundle"
done
# One .lproj per UI language so Bundle.main.preferredLocalizations (and AppKit's own texts) resolve to en or tr.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/tr.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"Text and Code" = "Text and Code";
STRINGS
cat > "$APP/Contents/Resources/tr.lproj/InfoPlist.strings" <<'STRINGS'
"Text and Code" = "Metin ve Kod";
STRINGS

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleExecutable</key><string>Notes</string>
    <key>CFBundleIdentifier</key><string>com.vefa.notes</string>
    <key>CFBundleName</key><string>Notes</string>
    <key>CFBundleDisplayName</key><string>Notes</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>tr</string></array>
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
            <key>CFBundleTypeName</key><string>Text and Code</string>
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
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <!-- A tab dragged within the tab bar; never written to disk. -->
            <key>UTTypeIdentifier</key><string>com.vefa.notes.tab</string>
            <key>UTTypeDescription</key><string>Notes Tab</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.data</string></array>
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
if [ -z "${OUT_DIR:-}" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "Built $APP"
