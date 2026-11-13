#!/bin/sh
# Builds .build/Untunnel.app from the release executable and the audio plug-in, and ad-hoc signs
# both: the plug-in first, because the app's signature seals its resources.
# The icon is built from the required PNG set in Support/AppIcon.iconset with iconutil.
# --zip also writes the release asset the install script and the formula download.

set -eu

print_root() {
    directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    while [ "$directory" != "/" ]; do
        if [ -f "$directory/Package.swift" ]; then
            printf '%s\n' "$directory"
            return 0
        fi
        directory=$(dirname -- "$directory")
    done
    printf 'no Package.swift above %s\n' "$0" >&2
    return 1
}

ZIP=0
case "${1:-}" in
    --print-root)
        print_root
        exit 0
        ;;
    --help|-h)
        printf 'Usage: bundle.sh [--zip]\n\nBuilds .build/Untunnel.app from the release build.\n'
        printf 'With --zip, also writes dist/Untunnel-arm64.zip and its .sha256.\n'
        exit 0
        ;;
    --zip)
        ZIP=1
        ;;
    "")
        ;;
    *)
        printf 'unknown option %s; see bundle.sh --help\n' "$1" >&2
        exit 2
        ;;
esac

ROOT=$(print_root)
cd "$ROOT"

swift build -c release --product untunnel
make -C "$ROOT/driver"
BIN_DIR=$(swift build -c release --show-bin-path)

APP="$ROOT/.build/Untunnel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/untunnel" "$APP/Contents/MacOS/Untunnel"

ICON_SET="$ROOT/Support/AppIcon.iconset"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICON_SET"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

DRIVER="$APP/Contents/Resources/Untunnel.driver"
cp -R "$ROOT/.build/driver/Untunnel.driver" "$DRIVER"
codesign --force --sign - --identifier com.intesarjawad.untunnel.driver "$DRIVER"
codesign --verify --strict "$DRIVER"

codesign --force --sign - --identifier com.intesarjawad.untunnel "$APP"
codesign --verify --strict "$APP"

printf 'Built %s\n' "$APP"

if [ "$ZIP" = 1 ]; then
    ASSET=Untunnel-arm64.zip
    mkdir -p "$ROOT/dist"
    rm -f "$ROOT/dist/$ASSET" "$ROOT/dist/$ASSET.sha256"
    ditto -c -k --keepParent "$APP" "$ROOT/dist/$ASSET"
    # The checksum names the file without a directory, so `shasum -c` works wherever both land.
    (cd "$ROOT/dist" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
    printf 'Wrote dist/%s and dist/%s.sha256\n' "$ASSET" "$ASSET"
fi
