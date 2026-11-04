#!/usr/bin/env bash
# Tag a doma release. The tag starts the release workflow, which runs goreleaser: the linux
# binaries, sha256sums.txt, SBOMs and the container image. Before the tag, doma for Mac is built,
# signed and notarized (scripts/mac-release.sh), so a release never stops half done; after it the
# app's DMG is added to the GitHub release and the cask in w4jnl/homebrew-tap is written for it.
#   scripts/release.sh 0.2.0            (macOS: uses BSD sed -i '')
#   DOMA_NO_APP=1 scripts/release.sh 0.2.0   the server alone, the cask left as it is
# Requires: a clean tree on main pushed to origin, a "## <version> (YYYY-MM-DD)" section in
# CHANGELOG.md, ssh access to both repositories, gh, and for the app what scripts/mac-release.sh
# requires.
set -euo pipefail
ver=${1:?usage: scripts/release.sh <version>   e.g. 0.2.0}
retry() { local n; for n in 1 2 3; do "$@" && return 0; [ "$n" -lt 3 ] && { echo "release.sh: $* failed, retrying in 10 s" >&2; sleep 10; }; done; return 1; }
ver=${ver#v}
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R"
[ "$(git branch --show-current)" = main ] || { echo "release.sh: not on main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "release.sh: working tree not clean" >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release.sh: main is not pushed" >&2; exit 1; }
notes=$(awk -v v="$ver" '/^## /{p = ($2 == v)} p && !/^## /' CHANGELOG.md | sed '/./,$!d')
[ -n "$notes" ] || { echo "release.sh: CHANGELOG.md has no \"## $ver (YYYY-MM-DD)\" section; write the release notes first (move the Unreleased items)" >&2; exit 1; }
grep -qE "^## $ver \([0-9]{4}-[0-9]{2}-[0-9]{2}\)" CHANGELOG.md || { echo "release.sh: the CHANGELOG.md heading must be \"## $ver (YYYY-MM-DD)\"" >&2; exit 1; }
go vet ./... && go test ./... >/dev/null && echo "tests ok"

dmg=""
TAP=${DOMA_TAP_DIR:-$R/../../homebrew-tap}
if [ "${DOMA_NO_APP:-}" != 1 ]; then
  [ "$(uname)" = Darwin ] || { echo "release.sh: doma for Mac is built on a Mac; DOMA_NO_APP=1 releases the server alone" >&2; exit 1; }
  command -v gh >/dev/null || { echo "release.sh: gh adds the app's DMG to the release (brew install gh); DOMA_NO_APP=1 releases the server alone" >&2; exit 1; }
  # the tap is checked before anything is built or tagged, so a release never stops half done
  [ -d "$TAP/.git" ] || retry git clone -q git@github.com:w4jnl/homebrew-tap.git "$TAP"
  [ -z "$(git -C "$TAP" status --porcelain)" ] || { echo "release.sh: $TAP has uncommitted changes; commit or stash them first" >&2; exit 1; }
  retry git -C "$TAP" pull -q --ff-only
  "$R/scripts/mac-release.sh" "$ver"
  dmg=$R/app/macos/build/release/doma-$ver.dmg
fi

git tag -a "v$ver" -m "doma v$ver"
retry git push -q origin "v$ver"
echo "tag v$ver pushed; the release workflow builds the assets and the image"

if [ -n "$dmg" ]; then
  # the release workflow makes the GitHub release a minute or so after the tag
  for _ in $(seq 1 60); do gh release view "v$ver" >/dev/null 2>&1 && break; sleep 5; done
  retry gh release upload "v$ver" "$dmg" --clobber
  echo "added $(basename "$dmg") to the release"
  "$R/scripts/cask.sh" "$ver" "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" >"$TAP/Casks/doma.rb"
  git -C "$TAP" add Casks/doma.rb
  git -C "$TAP" commit -q -m "doma $ver"
  retry git -C "$TAP" push -q
  echo "cask written: $TAP/Casks/doma.rb"
fi

echo "release: https://github.com/w4jnl/doma/releases/tag/v$ver"
echo "CI:      https://github.com/w4jnl/doma/actions"
[ -z "$dmg" ] || echo "users:   brew install --cask w4jnl/tap/doma   (brew upgrade --cask doma)"
