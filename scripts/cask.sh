#!/usr/bin/env bash
# Print the Homebrew cask for doma for Mac at one version: scripts/release.sh writes it into
# w4jnl/homebrew-tap as Casks/doma.rb after the DMG is on the GitHub release.
#   scripts/cask.sh 0.2.0 <sha256 of doma-0.2.0.dmg>
set -euo pipefail
ver=${1:?usage: scripts/cask.sh <version> <sha256>}
sha=${2:?usage: scripts/cask.sh <version> <sha256>}
[ ${#sha} -eq 64 ] || { echo "cask.sh: $sha is not a sha256" >&2; exit 1; }
cat <<EOC
# doma for Mac: the family's lists in a window. Signed with a Developer ID and notarized;
# scripts/release.sh in w4jnl/doma writes this file at every tag.
cask "doma" do
  version "$ver"
  sha256 "$sha"

  url "https://github.com/w4jnl/doma/releases/download/v#{version}/doma-#{version}.dmg"
  name "doma"
  desc "Family shopping lists, synced through your own server"
  homepage "https://github.com/w4jnl/doma"

  depends_on macos: :tahoe

  app "doma.app"

  zap trash: [
    "~/Library/Containers/nl.w4j.doma.mac",
  ]

  caveats <<~EOS
    doma for Mac joins your household with an invite from a phone that is already in it:
    Settings, Add a device. Where the lists live is your own server; see
    https://github.com/w4jnl/doma.
  EOS
end
EOC
