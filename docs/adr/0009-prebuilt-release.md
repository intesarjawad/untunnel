# ADR-0009: One prebuilt release build for both installers

Status: Accepted.

## Context

Untunnel has no paid Apple developer account, so the app and its plug-in are signed ad hoc and
not notarised. Building on every user's Mac would need the Command Line Tools and minutes of
compile time before the first call. A single build made in CI and downloaded by both installers
keeps the install short and makes every user run the same bytes.

## Decision

**Build once.** On a `v*` tag, `release.yml` runs CI, creates the GitHub release from the tag's
`CHANGELOG.md` section (a tag with a hyphen makes a pre-release), and then, on `macos-26`:

1. stamps `Support/Info.plist` with the tag's version and the run number as `CFBundleVersion`,
   which is what the running app's update check compares;
2. runs `tools/src/untunnel_tools/bundle.sh --zip`: a release build of the executable and the
   plug-in, the plug-in signed ad hoc before the app because the app's signature seals its
   resources, then `ditto -c -k --keepParent` into `dist/Untunnel-arm64.zip` and its `.sha256`;
3. uploads both under that fixed name, so `releases/latest/download/Untunnel-arm64.zip` always
   serves the newest release.

**Install it two ways.**

- `site/install.sh`, run through `curl ... | sh`, refuses an Intel Mac or macOS older than 15,
  downloads the archive and its checksum with `curl`, checks them with `shasum -a 256 -c`,
  unpacks with `ditto` and swaps the result for `~/Applications/Untunnel.app`. The model and
  preferences live in `~/Library/Application Support/Untunnel` and are kept, so running the line
  again upgrades. It then runs the app's `setup`, reading the terminal so a piped script never
  reaches setup's prompts. `UNTUNNEL_ARTIFACT` points it at a local archive for CI and tests.
- The `tap` job writes `Formula/untunnel.rb` with `untunnel_tools.formula` from the versioned
  asset and its checksum, and opens a pull request on `intesarjawad/homebrew-tap` with the
  `TAP_TOKEN` secret, because the default token cannot write to another repository.

Each installer refuses to overwrite the other and prints the command that switches: the script
recognises Homebrew's install by the link Homebrew leaves in `~/Applications`, and `setup`
refuses a script-installed bundle when it runs from Homebrew.

**Contributors** still build from source with `make setup` and `make run`; CI builds with the
Command Line Tools alone so that path keeps working.

## Consequences

Files downloaded with `curl` carry no quarantine attribute, so Gatekeeper does not stop the ad
hoc signed app the way it stops a browser download. Because the signature is ad hoc, macOS may
ask for microphone and audio permissions again after an upgrade.

The CI `cold-start` job installs the archive with `install.sh --yes` on a fresh runner and checks
the installed model with `untunnel doctor --json`. It cannot pass until the default model is
pinned in `ModelPins.recorded` (`Sources/Untunnel/Download.swift`) and `setup` downloads it.
