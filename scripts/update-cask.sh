#!/bin/bash
# Bumps the Homebrew cask in adeministratorr/homebrew-tap to the version in project.yml, after its DMG is published
# as a GitHub release asset (iDownload-Manager-<version>.dmg on tag v<version>).
# Requires the tap repo + a i-download-manager.rb cask (with depends_on formula: "aria2").
# Usage: scripts/update-cask.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)}
url="https://github.com/adeministratorr/i-download-manager/releases/download/v$version/iDownload-Manager-$version.dmg"

# use the checksum GitHub reports for the published asset, so the cask always matches what users download
sha=$(curl -fsSL "https://api.github.com/repos/adeministratorr/i-download-manager/releases/tags/v$version" |
  python3 -c "import json,sys; a=[x for x in json.load(sys.stdin)['assets'] if x['name']=='iDownload-Manager-$version.dmg']; print(a[0]['digest'].split(':')[1] if a and a[0].get('digest') else '')")
if [ -z "$sha" ]; then
  echo "Release asset digest not available; hashing the downloaded DMG instead"
  sha=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)
fi

tap=$(mktemp -d)
trap 'rm -rf "$tap"' EXIT
git clone -q https://github.com/adeministratorr/homebrew-tap.git "$tap"
cask="$tap/Casks/i-download-manager.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
if git -C "$tap" diff --quiet; then echo "Cask already at $version"; exit 0; fi
git -C "$tap" commit -qam "i-download-manager $version"
git -C "$tap" push -q origin HEAD
echo "Cask updated to $version ($sha)"
