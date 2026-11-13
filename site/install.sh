#!/bin/sh
# Installs Untunnel into ~/Applications from the newest release, then runs its setup.
#
# Only ~/Applications/Untunnel.app is replaced. The model and preferences live in
# ~/Library/Application Support/Untunnel and are kept, so running this again upgrades.
# A running Untunnel is left alone; it switches to the new version when it is next idle.
#
# UNTUNNEL_ARTIFACT=<path to Untunnel-arm64.zip> installs a local build instead of the
# download; its .sha256 must sit beside it. Arguments are passed to `setup`.

set -eu

RELEASE=https://github.com/intesarjawad/untunnel/releases/latest/download
ASSET=Untunnel-arm64.zip
MINIMUM_MACOS=15

fail() {
    printf '%s\n' "$1" >&2
    printf 'Fix: %s\n' "$2" >&2
    exit 1
}

check_mac() {
    # uname reports x86_64 in a shell running under Rosetta; the sysctl still sees the chip.
    if [ "$(uname -m)" != arm64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
        fail "Untunnel needs an Apple silicon Mac." \
            "Open the Apple menu > About This Mac to confirm the chip."
    fi
    version=$(sw_vers -productVersion)
    if [ "${version%%.*}" -lt "$MINIMUM_MACOS" ]; then
        fail "Untunnel needs macOS $MINIMUM_MACOS or later." \
            "Open System Settings > General > Software Update, then run this install line again."
    fi
}

fetch() {
    if [ -n "${UNTUNNEL_ARTIFACT:-}" ]; then
        [ -f "$UNTUNNEL_ARTIFACT" ] ||
            fail "$UNTUNNEL_ARTIFACT does not exist." "Run tools/src/untunnel_tools/bundle.sh --zip."
        cp "$UNTUNNEL_ARTIFACT" "$work/$ASSET"
        cp "$UNTUNNEL_ARTIFACT.sha256" "$work/$ASSET.sha256"
    else
        curl -fsSL -o "$work/$ASSET" "$RELEASE/$ASSET"
        curl -fsSL -o "$work/$ASSET.sha256" "$RELEASE/$ASSET.sha256"
    fi
    (cd "$work" && shasum -a 256 -c "$ASSET.sha256" >/dev/null 2>&1) ||
        fail "The download does not match its checksum." "Run this install line again."
}

main() {
    check_mac

    app="$HOME/Applications/Untunnel.app"
    # Homebrew installs the app in its own prefix and links it here. Replacing the link's
    # target would leave brew and this script overwriting each other.
    if [ -L "$app" ] && [ -e "$app" ]; then
        fail "Untunnel is installed with Homebrew." \
            "run \`brew upgrade untunnel\`; to switch, run \`brew uninstall untunnel\`, then this install line again."
    fi

    work=$(mktemp -d "${TMPDIR:-/tmp}/untunnel-install.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM

    fetch
    ditto -x -k "$work/$ASSET" "$work/unpacked"
    [ -d "$work/unpacked/Untunnel.app" ] ||
        fail "The download has no Untunnel.app in it." "Run this install line again."

    # A link whose target is gone is what `brew uninstall` leaves without `untunnel uninstall`.
    if [ -L "$app" ]; then
        rm "$app"
    fi
    mkdir -p "$HOME/Applications"
    if [ -e "$app" ]; then
        mv "$app" "$work/previous.app"
    fi
    if ! mv "$work/unpacked/Untunnel.app" "$app"; then
        [ ! -e "$work/previous.app" ] || mv "$work/previous.app" "$app"
        fail "Untunnel.app could not be moved into ~/Applications." \
            "Check that you can write to ~/Applications, then run this install line again."
    fi

    # Under `curl ... | sh` stdin is this script, so setup's questions and the password prompt
    # read the terminal when there is one. Without one (CI), pass --yes.
    if (: </dev/tty) 2>/dev/null; then
        "$app/Contents/MacOS/Untunnel" setup "$@" </dev/tty
    else
        "$app/Contents/MacOS/Untunnel" setup "$@"
    fi
}

# Everything runs from this last line, so a shell reading the script from a pipe has read all
# of it before setup starts and setup cannot receive the rest of the script as input.
main "$@"
