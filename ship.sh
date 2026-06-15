#!/usr/bin/env bash
# Ship a WhoopBar release over the air. One command does everything users need to get the update:
#   1. builds the universal DMG/zip (release.sh)
#   2. pushes main + a v<version> tag
#   3. creates/updates the GitHub release with WhoopBar.dmg + WhoopBar.zip assets
#   4. bumps version + sha256 in the Homebrew cask and pushes the tap
# After this, brew users get it via `brew upgrade --cask whoopbar` and the in-app pill points here.
#
# Prereqs: gh (authed), a clean-ish working tree (Info.plist version already bumped + committed).
# Override the tap location with: TAP_DIR=/path/to/homebrew-tap ./ship.sh
set -euo pipefail
cd "$(dirname "$0")"

REPO="Mahir-Isikli/whoopbar"
TAP_DIR="${TAP_DIR:-/opt/homebrew/Library/Taps/mahir-isikli/homebrew-tap}"
CASK="$TAP_DIR/Casks/whoopbar.rb"

VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)" \
    || { echo 'ERROR: cannot read version from Info.plist'; exit 1; }
echo "==> Shipping WhoopBar v$VER"

command -v gh >/dev/null || { echo 'ERROR: gh CLI not found'; exit 1; }
[ -f "$CASK" ] || { echo "ERROR: cask not found at $CASK (set TAP_DIR)"; exit 1; }

echo "==> Building universal release"
./release.sh >/dev/null
SHA="$(shasum -a 256 WhoopBar.dmg | awk '{print $1}')"
echo "    WhoopBar.dmg sha256 = $SHA"

echo "==> Pushing main + tag v$VER"
git push -q origin main
if ! git rev-parse "v$VER" >/dev/null 2>&1; then
    git tag "v$VER"
fi
git push -q origin "v$VER"

echo "==> Publishing GitHub release v$VER"
if gh release view "v$VER" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VER" -R "$REPO" --clobber WhoopBar.dmg WhoopBar.zip
else
    # A full (non-prerelease) release so GitHub marks it "latest" — both the Homebrew livecheck
    # (:github_latest) and the in-app UpdateChecker read /releases/latest, which ignores prereleases.
    gh release create "v$VER" -R "$REPO" --latest \
        --title "WhoopBar $VER" \
        --notes "WhoopBar $VER. Install: \`brew install --cask mahir-isikli/tap/whoopbar\` · Update: \`brew upgrade --cask whoopbar\`." \
        WhoopBar.dmg WhoopBar.zip
fi

echo "==> Bumping Homebrew cask"
git -C "$TAP_DIR" pull -q --ff-only || true
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$VER\"/" "$CASK"
/usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP_DIR" add Casks/whoopbar.rb
git -C "$TAP_DIR" commit -q -m "whoopbar $VER" || echo "    (cask already up to date)"
git -C "$TAP_DIR" push -q origin HEAD

echo "==> Done. Users update with: brew upgrade --cask whoopbar"
