#!/usr/bin/env bash
# Tag a doma release. The tag starts the release workflow, which runs goreleaser: the linux
# binaries, sha256sums.txt, SBOMs and the container image.
#   scripts/release.sh 0.1.0
# Requires: a clean tree on main pushed to origin, and a "## <version> (YYYY-MM-DD)" section
# in CHANGELOG.md.
set -euo pipefail
ver=${1:?usage: scripts/release.sh <version>   e.g. 0.1.0}
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

git tag -a "v$ver" -m "doma v$ver"
retry git push -q origin "v$ver"
echo "tag v$ver pushed; the release workflow builds the assets and the image"
echo "release: https://github.com/w4jnl/doma/releases/tag/v$ver"
echo "CI:      https://github.com/w4jnl/doma/actions"
