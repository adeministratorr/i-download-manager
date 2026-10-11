#!/bin/zsh
# Downloads the yt-dlp and ffmpeg binaries that get bundled into the app (into Tools/).
# Sources:
#   yt-dlp : https://github.com/yt-dlp/yt-dlp/releases  (yt-dlp_macos, universal)
#   ffmpeg : https://ffmpeg.martin-riedl.de  (statik, arm64 + x86_64) -> universal lipo
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/Tools"
mkdir -p "$TOOLS"
cd "$TOOLS"

YTDLP_URL="${YTDLP_URL:-https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos}"
FFMPEG_ARM64_URL="${FFMPEG_ARM64_URL:-https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip}"
FFMPEG_X86_URL="${FFMPEG_X86_URL:-https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip}"

if [[ ! -x yt-dlp ]]; then
  echo "→ downloading yt-dlp…"
  curl -fL --retry 3 -o yt-dlp "$YTDLP_URL"
  chmod +x yt-dlp
  # Best-effort checksum: release SHA2-256SUMS ile karşılaştır, tutmazsa dur.
  if curl -fL --retry 3 -o SHA2-256SUMS "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS" 2>/dev/null; then
    expect="$(grep 'yt-dlp_macos' SHA2-256SUMS | awk '{print $1}')"
    actual="$(shasum -a 256 yt-dlp | awk '{print $1}')"
    if [[ -n "$expect" && "$expect" != "$actual" ]]; then
      echo "✗ yt-dlp checksum mismatch (expected $expect, got $actual)" >&2
      rm -f yt-dlp SHA2-256SUMS
      exit 1
    fi
    echo "✓ yt-dlp checksum ok"
    rm -f SHA2-256SUMS
  else
    echo "  (checksum file unavailable, skipping verification)"
  fi
fi

if [[ ! -x ffmpeg ]]; then
  echo "→ downloading ffmpeg (arm64)…"
  curl -fL --retry 3 -o ffmpeg-arm64.zip "$FFMPEG_ARM64_URL"
  rm -rf _arm64 && mkdir _arm64 && unzip -q -o ffmpeg-arm64.zip -d _arm64
  echo "→ downloading ffmpeg (x86_64)…"
  if curl -fL --retry 3 -o ffmpeg-x86.zip "$FFMPEG_X86_URL"; then
    rm -rf _x86 && mkdir _x86 && unzip -q -o ffmpeg-x86.zip -d _x86
    lipo -create "$(find _arm64 -type f -name ffmpeg | head -1)" "$(find _x86 -type f -name ffmpeg | head -1)" -output ffmpeg
  else
    echo "   x86_64 ffmpeg unavailable, using arm64 only"
    cp "$(find _arm64 -type f -name ffmpeg | head -1)" ffmpeg
  fi
  chmod +x ffmpeg
  rm -rf _arm64 _x86 ffmpeg-arm64.zip ffmpeg-x86.zip
fi

xattr -cr yt-dlp ffmpeg 2>/dev/null || true
echo "✓ Tools ready:"
lipo -info yt-dlp ffmpeg 2>/dev/null || file yt-dlp ffmpeg
./yt-dlp --version
./ffmpeg -version | head -1
