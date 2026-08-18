#!/usr/bin/env bash
# Copyright (c) 2026, Salesforce, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Build → sign → (notarize) → staple → DMG for Thread.
#
# Usage:
#   ./release.sh            # full run: build, sign, notarize, staple, dmg
#   ./release.sh --no-notarize   # build, sign, dmg only (Gatekeeper will warn)
#
# First-time setup: copy release.config.sh.example to release.config.sh and fill
# in your signing identity, team ID, and update-feed URL.
#
# You also need a notarization credential stored in the keychain. Either:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#     --apple-id "you@example.com" --team-id "YOUR_TEAM_ID" --password "app-specific-pw"
# or with an API key:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#     --key /path/AuthKey_XXX.p8 --key-id "XXXXXXXX" --issuer "uuid"

set -euo pipefail

# ---- Config -----------------------------------------------------------------
SCHEME="Thread"
PROJECT="Thread.xcodeproj"
APP_NAME="Thread"
BUNDLE_ID="com.thread.app"
ENTITLEMENTS="Thread/Thread.entitlements"
UPDATES_DIR_NAME="updates"

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Signing and publishing settings differ per developer and per fork, so they are
# kept out of the repo. Copy release.config.sh.example to release.config.sh and
# fill it in, or export the same variables in your shell.
if [[ -f "$ROOT/release.config.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/release.config.sh"
fi

# A keychain can hold several identically-named "Developer ID Application"
# certificates, so codesign needs the SHA-1 hash rather than the name.
# List them with: security find-identity -v -p codesigning
SIGN_ID="${THREAD_SIGN_ID:?not set — see release.config.sh.example}"
TEAM_ID="${THREAD_TEAM_ID:?not set — see release.config.sh.example}"
NOTARY_PROFILE="${THREAD_NOTARY_PROFILE:-thread-notary}"

# The public URL that the updates folder is served from. Must match SUFeedURL
# in Info.plist, or installed builds will stop seeing updates.
DOWNLOAD_URL_PREFIX="${THREAD_DOWNLOAD_URL_PREFIX:?not set — see release.config.sh.example}"

BUILD_DIR="$ROOT/build"
EXPORT_DIR="$ROOT/dist"
UPDATES_DIR="$ROOT/$UPDATES_DIR_NAME"
SPARKLE_BIN="$ROOT/.sparkle-tools/bin"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

echo "==> Cleaning previous release build"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# ---- 1. Build + sign (Release, Developer ID, hardened runtime, secure ts) ---
echo "==> Building Release and signing with Developer ID"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  clean build

[[ -d "$APP_PATH" ]] || { echo "!! Build product missing: $APP_PATH"; exit 1; }

# xcodebuild does NOT re-sign Sparkle's deeply-nested helper bundles, so they
# keep Sparkle's shipped signature (no secure timestamp, not our Developer ID)
# and notarization rejects them. Re-sign inside-out with hardened runtime +
# secure timestamp, then re-sign the app last with our entitlements (which also
# strips the debug get-task-allow entitlement).
echo "==> Re-signing Sparkle helpers (inside-out)"
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_ID")
if [[ -d "$SPARKLE_FW" ]]; then
  "${SIGN[@]}" "$SPARKLE_FW/Versions/Current/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SPARKLE_FW/Versions/Current/XPCServices/Installer.xpc"
  "${SIGN[@]}" "$SPARKLE_FW/Versions/Current/Autoupdate"
  "${SIGN[@]}" "$SPARKLE_FW/Versions/Current/Updater.app"
  "${SIGN[@]}" "$SPARKLE_FW"
fi
echo "==> Re-signing the app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_PATH"

echo "==> Verifying signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Timestamp" || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
echo "==> Version $VERSION"

# ---- 2. Notarize the app (zip is the submission vehicle) --------------------
if [[ "$NOTARIZE" == "1" ]]; then
  ZIP="$EXPORT_DIR/$APP_NAME-$VERSION.zip"
  echo "==> Zipping for notarization"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP"

  echo "==> Submitting to Apple notary (this can take a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling the app"
  xcrun stapler staple "$APP_PATH"
  rm -f "$ZIP"
else
  echo "==> Skipping notarization (--no-notarize)"
fi

# ---- 3. Build the DMG -------------------------------------------------------
echo "==> Building DMG"
DMG="$EXPORT_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGE"

echo "==> Signing the DMG"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

# ---- 4. Notarize + staple the DMG ------------------------------------------
if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "==> Verifying Gatekeeper acceptance"
  spctl -a -t open --context context:primary-signature -vvv "$DMG" || true
fi

# ---- 5. Sparkle appcast -----------------------------------------------------
# generate_appcast scans the updates folder, signs each archive with the
# EdDSA private key from the keychain, and (re)writes appcast.xml. Old DMGs
# left in the folder stay in the feed as prior versions.
echo "==> Updating Sparkle appcast"
mkdir -p "$UPDATES_DIR"
cp "$DMG" "$UPDATES_DIR/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$UPDATES_DIR"

# generate_appcast tucks pruned delta files into an old_updates/ archive. We
# don't publish those, so drop it to keep the updates folder (and repo) clean.
rm -rf "$UPDATES_DIR/old_updates"

echo ""
echo "✅ Done."
echo "   DMG:      $DMG"
echo "   Appcast:  $UPDATES_DIR/appcast.xml"
echo ""
echo "Next: write release-notes/$VERSION.md, then run ./publish.sh to push the"
echo "'$UPDATES_DIR_NAME/' folder, tag the release, and attach the DMG to it."
