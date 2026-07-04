#!/usr/bin/env bash
#
# build-and-install.sh — one command to build Jotty, sign it with a stable local
# identity (so macOS remembers Calendar/permission grants across rebuilds), and
# install it to /Applications.
#
# First run creates the signing identity for you (via make-dev-cert.sh). After
# that, just re-run this whenever you want to update your installed copy — the
# Calendar permission you granted once will stick.
#
# Usage:  scripts/build-and-install.sh
# Env:    JOTTY_SIGN_IDENTITY   signing identity name (default: "Jotty Dev")
#         JOTTY_CONFIG          Release | Debug (default: Release)
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${JOTTY_SIGN_IDENTITY:-Jotty Dev}"
CONFIG="${JOTTY_CONFIG:-Release}"
BUNDLE_ID="com.jotty.Jotty"

# 1. Ensure a stable signing identity exists.
scripts/make-dev-cert.sh "$IDENTITY"

# 2. Generate the Xcode project and build.
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
echo "Generating project + building ($CONFIG)…"
xcodegen generate
xcodebuild -scheme Jotty -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath build build

APP="build/Build/Products/$CONFIG/Jotty.app"
[ -d "$APP" ] || { echo "Build did not produce $APP"; exit 1; }

# 3. Re-sign with the stable identity (preserving the entitlements xcodebuild set).
echo "Signing with '$IDENTITY'…"
codesign --force --deep --preserve-metadata=entitlements,flags \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ Signature verified."

# 4. Install to /Applications.
rm -rf /Applications/Jotty.app
cp -R "$APP" /Applications/Jotty.app
echo "✓ Installed /Applications/Jotty.app"

# 5. If an earlier unsigned/ad-hoc run left a confused Calendar grant, clear it once
#    so the next grant is clean and durable under the new stable identity.
echo
echo "Done. Launch it:  open /Applications/Jotty.app"
echo "If Calendar still re-prompts (leftover from an earlier unsigned run), run once:"
echo "  tccutil reset Calendar $BUNDLE_ID"
