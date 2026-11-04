#!/usr/bin/env bash
# Build doma for Mac for a release: signed with the team's Developer ID, notarized by Apple and
# stapled, the app and the DMG that carries it, checked as Gatekeeper checks them. Nothing is
# tagged or uploaded: scripts/release.sh does that with the DMG this writes and keeps the cask in
# w4jnl/homebrew-tap current.
#   scripts/mac-release.sh 0.2.0     → app/macos/build/release/doma-0.2.0.dmg
# Requires: Xcode 26, XcodeGen; in app/macos/Local.xcconfig the team (DOMA_TEAM_ID), whose
# Developer ID Application certificate is in the keychain, and the App Store Connect API key that
# notarizes (DOMA_ASC_KEY_ID, DOMA_ASC_ISSUER_ID, there or in app/ios/Local.xcconfig; the .p8 in
# ~/.appstoreconnect/private_keys/). The key's ids stay out of the log.
set -euo pipefail
ver=${1:?usage: scripts/mac-release.sh <version>   e.g. 0.2.0}
ver=${ver#v}
[[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "mac-release.sh: $ver is not a version like 0.2.0" >&2; exit 1; }
R=$(cd "$(dirname "$0")/.." && pwd)
MAC=$R/app/macos
# conf reads a key from app/macos/Local.xcconfig, or app/ios/Local.xcconfig when the Mac's has none.
conf() {
  local f v
  for f in "$MAC/Local.xcconfig" "$R/app/ios/Local.xcconfig"; do
    [ -f "$f" ] || continue
    v=$(sed -n "s/^$1 *= *//p" "$f" | tr -d ' \r')
    [ -z "$v" ] || { echo "$v"; return 0; }
  done
  return 0
}
TEAM=$(conf DOMA_TEAM_ID)
KEY=$(conf DOMA_ASC_KEY_ID)
ISSUER=$(conf DOMA_ASC_ISSUER_ID)
P8=${DOMA_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY.p8}
[ -n "$TEAM" ] || { echo "mac-release.sh: no DOMA_TEAM_ID in app/macos/Local.xcconfig" >&2; exit 1; }
[ -n "$KEY" ] && [ -n "$ISSUER" ] || { echo "mac-release.sh: no DOMA_ASC_KEY_ID or DOMA_ASC_ISSUER_ID in app/macos/Local.xcconfig or app/ios/Local.xcconfig" >&2; exit 1; }
[ -f "$P8" ] || { echo "mac-release.sh: no App Store Connect API key at ~/.appstoreconnect/private_keys/" >&2; exit 1; }
ID=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .* ($TEAM)\)\".*/\1/p" | awk 'NR == 1')
[ -n "$ID" ] || { echo "mac-release.sh: no Developer ID Application certificate for team $TEAM in the keychain (Xcode › Settings › Accounts › Manage Certificates)" >&2; exit 1; }

OUT=$MAC/build/release
rm -rf "$OUT"
mkdir -p "$OUT"
app=$OUT/doma.app

echo "1/5 the app, Release, for both architectures, signed with $ID"
(cd "$MAC" && xcodegen generate --quiet)
build=$(awk -F. '{print $1 * 10000 + $2 * 100 + $3}' <<<"$ver") # 0.2.0 → 200: always rising
# xcodebuild signs, so the entitlements (the sandbox, the camera, the microphone) and the
# hardened runtime from project.yml stay on the app; a secure timestamp goes with the signature
(cd "$MAC" && xcodebuild -project Doma.xcodeproj -scheme Doma -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/ReleaseData MARKETING_VERSION="$ver" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$ID" DEVELOPMENT_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet)
ditto "$MAC/build/ReleaseData/Build/Products/Release/doma.app" "$app"
codesign --verify --deep --strict "$app"
# codesign's answers are read whole before they are searched (see gatekeeper below for why)
ent=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - 2>/dev/null || true)
grep -q '"com.apple.security.app-sandbox" => true' <<<"$ent" || { echo "mac-release.sh: the sandbox entitlement did not survive signing" >&2; exit 1; }
# a build action injects get-task-allow, which the notary refuses; CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO above keeps it out
grep -q 'get-task-allow' <<<"$ent" && { echo "mac-release.sh: the app carries get-task-allow, a debug entitlement Apple does not notarize" >&2; exit 1; }
sig=$(codesign -d -vv "$app" 2>&1 || true)
grep -q 'flags=.*runtime' <<<"$sig" || { echo "mac-release.sh: the hardened runtime is not on the app" >&2; exit 1; }
[ "$(defaults read "$app/Contents/Info" CFBundleShortVersionString)" = "$ver" ] || { echo "mac-release.sh: the app is not v$ver" >&2; exit 1; }
lipo -archs "$app/Contents/MacOS/doma" | grep -q 'x86_64' && lipo -archs "$app/Contents/MacOS/doma" | grep -q 'arm64' || { echo "mac-release.sh: the app is not universal" >&2; exit 1; }

# notarize submits a file to Apple's notary service and waits for its verdict; on anything but
# Accepted it prints Apple's log, which names each problem, and stops.
notarize() {
  local out id status
  out=$(xcrun notarytool submit "$1" --key "$P8" --key-id "$KEY" --issuer "$ISSUER" --wait --timeout 2h --output-format json)
  id=$(python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' <<<"$out" 2>/dev/null || true)
  status=$(python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' <<<"$out" 2>/dev/null || true)
  echo "    $(basename "$1"): ${status:-no answer} ($id)"
  if [ "$status" != Accepted ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" --key "$P8" --key-id "$KEY" --issuer "$ISSUER" >&2
    echo "mac-release.sh: Apple did not notarize $(basename "$1")" >&2
    exit 1
  fi
}

echo "2/5 notarizing the app (a few minutes)"
# the app on its own first, so the copy people drag to Applications carries its own ticket
ditto -c -k --keepParent "$app" "$OUT/doma.zip"
notarize "$OUT/doma.zip"
xcrun stapler staple -q "$app"
rm "$OUT/doma.zip"

echo "3/5 the DMG: the app and a link to Applications, signed"
stage=$OUT/dmg
mkdir -p "$stage"
ditto "$app" "$stage/doma.app"
ln -s /Applications "$stage/Applications"
dmg=$OUT/doma-$ver.dmg
hdiutil create -quiet -volname "doma $ver" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"
codesign --force --timestamp --sign "$ID" "$dmg"

echo "4/5 notarizing the DMG"
notarize "$dmg"
xcrun stapler staple -q "$dmg"

echo "5/5 checking as Gatekeeper does"
# spctl's answer is read whole before it is searched: grep -q stopping at the first match would
# cut spctl off mid-write, and pipefail would take that for a failure
gatekeeper() {
  local out
  out=$(spctl --assess -vv "$@" 2>&1) || true
  grep -q "source=Notarized Developer ID" <<<"$out" || { echo "$out" >&2; echo "mac-release.sh: Gatekeeper does not take ${*: -1} as notarized" >&2; exit 1; }
}
gatekeeper --type execute "$app"
gatekeeper --type open --context context:primary-signature "$dmg"
xcrun stapler validate -q "$app"
xcrun stapler validate -q "$dmg"
echo "notarized: $dmg"
shasum -a 256 "$dmg" | cut -d' ' -f1
