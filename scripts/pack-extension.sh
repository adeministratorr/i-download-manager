#!/bin/zsh
# Packs the WebExtension for Chrome Web Store upload: build/i-download-manager-chrome-<version>.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/Extension/manifest.json'))['version'])")"
OUT="$ROOT/build/i-download-manager-chrome-$VERSION.zip"
mkdir -p "$ROOT/build"; rm -f "$OUT"
(cd "$ROOT/Extension" && zip -qr "$OUT" . -x ".DS_Store" "*/.DS_Store")
echo "✓ $OUT"
