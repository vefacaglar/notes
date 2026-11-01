#!/bin/sh
# Builds Notes.app (release, via bundle.sh) and installs it as /Applications/Notes.app, replacing an older copy.
# A running installed copy is asked to quit first (it saves its session and drafts) and is opened again afterwards.
# INSTALL_DIR overrides /Applications.
set -eu

cd "$(dirname "$0")/.."
DEST_DIR="${INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/Notes.app"
STAGE="build/install"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Built outside build/ so only the installed copy is registered with LaunchServices.
OUT_DIR="$STAGE" ./scripts/bundle.sh

# Only this path: Apple's Notes lives in /System/Applications and is never touched.
was_running=false
if pgrep -f "^$DEST/Contents/MacOS/Notes" >/dev/null 2>&1; then
    was_running=true
    echo "Quitting the installed Notes…"
    osascript -e "tell application \"$DEST\" to quit"
    i=0
    while pgrep -f "^$DEST/Contents/MacOS/Notes" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -gt 50 ]; then
            echo "Notes did not quit (unsaved changes?). Quit it and run this again." >&2
            exit 1
        fi
        sleep 0.2
    done
fi

# Copy next to the destination first, then swap, so a failed copy leaves the old app in place.
mkdir -p "$DEST_DIR"
NEW="$DEST_DIR/.Notes.app.new"
rm -rf "$NEW"
ditto "$STAGE/Notes.app" "$NEW"
rm -rf "$DEST"
mv "$NEW" "$DEST"
rm -rf "$STAGE"

"$LSREGISTER" -f "$DEST"
echo "Installed $DEST"
if [ "$was_running" = true ]; then open "$DEST"; fi
