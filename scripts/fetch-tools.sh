#!/bin/zsh
# Downloads the yt-dlp, ffmpeg and aria2c binaries that get bundled into the app (into Tools/).
# Sources:
#   yt-dlp : https://github.com/yt-dlp/yt-dlp/releases  (yt-dlp_macos, universal)
#   ffmpeg : https://ffmpeg.martin-riedl.de  (statik, arm64 + x86_64) -> universal lipo
#   aria2c : static macOS builds, arm64 + x86_64 -> universal lipo (see below)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/Tools"
mkdir -p "$TOOLS"
cd "$TOOLS"

YTDLP_URL="${YTDLP_URL:-https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos}"
FFMPEG_ARM64_URL="${FFMPEG_ARM64_URL:-https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip}"
FFMPEG_X86_URL="${FFMPEG_X86_URL:-https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip}"
# Pinned SHA-256 of the third-party zips (fail closed on mismatch; bump with the URLs).
ARIA2_VERSION="1.37.0"
ARIA2_ARM64_URL="${ARIA2_ARM64_URL:-https://github.com/yaobiao131/downkyi-aria2-static-build/releases/download/1.37.0/aria2-aarch64-apple-darwin_static.zip}"
ARIA2_ARM64_SHA="${ARIA2_ARM64_SHA:-5431ba2e1b81318e07646d53373d2da8348f3fdea3331cef98f02764c105bfe1}"
ARIA2_X86_URL="${ARIA2_X86_URL:-https://github.com/yaobiao131/downkyi-aria2-static-build/releases/download/1.37.0/aria2-x86_64-apple-darwin_static.zip}"
ARIA2_X86_SHA="${ARIA2_X86_SHA:-95bd7654ae68c9049893c64e83f22a472d1ad9ff8b6aebe1b047106fa5c6bfc2}"

if [[ ! -x yt-dlp ]]; then
  echo "→ downloading yt-dlp…"
  curl -fL --retry 3 -o yt-dlp "$YTDLP_URL"
  chmod +x yt-dlp
  # Best-effort checksum: release SHA2-256SUMS ile karşılaştır, tutmazsa dur.
  # NOT: dosya adı tam eşleşmeli — `grep yt-dlp_macos` varyantları da
  # (örn. .zip) yakalayıp iki hash döndürür ve sağlam binary'yi çöpe atar.
  if curl -fL --retry 3 -o SHA2-256SUMS "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS" 2>/dev/null; then
    expect="$(tr -d '\r' < SHA2-256SUMS | awk '$2 == "yt-dlp_macos" {print $1; exit}')"
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

if [[ ! -x aria2c ]]; then
  # 1) Homebrew kopyası en güveniliri (resmi kaynaktan derlenmiş): ağa çıkmadan al.
  #    Brew binary'si Homebrew kütüphanelerine bağlıysa gömülemez -> static indirmeye düş.
  for brew_bin in /opt/homebrew/bin/aria2c /usr/local/bin/aria2c; do
    if [[ -x "$brew_bin" ]] && ! otool -L "$brew_bin" 2>/dev/null | grep -q '/opt/homebrew/opt/\|/usr/local/opt/'; then
      echo "→ using $brew_bin"
      cp "$brew_bin" aria2c
      break
    fi
  done
  # 2) Static build (arm64 + x86_64 -> universal). Hash pinli: tutmazsa dur.
  if [[ ! -x aria2c ]]; then
    echo "→ downloading aria2c $ARIA2_VERSION (static)…"
    curl -fL --retry 3 -o aria2-arm64.zip "$ARIA2_ARM64_URL"
    curl -fL --retry 3 -o aria2-x86.zip "$ARIA2_X86_URL"
    [[ "$(shasum -a 256 aria2-arm64.zip | cut -d' ' -f1)" == "$ARIA2_ARM64_SHA" ]] || { echo "✗ aria2 arm64 checksum mismatch" >&2; exit 1; }
    [[ "$(shasum -a 256 aria2-x86.zip | cut -d' ' -f1)" == "$ARIA2_X86_SHA" ]] || { echo "✗ aria2 x86_64 checksum mismatch" >&2; exit 1; }
    rm -rf _a64 _ax86 && mkdir _a64 _ax86
    unzip -q -o aria2-arm64.zip -d _a64
    unzip -q -o aria2-x86.zip -d _ax86
    a64="$(find _a64 -type f -name 'aria2*' | head -1)"
    ax86="$(find _ax86 -type f -name 'aria2*' | head -1)"
    [[ -n "$a64" && -n "$ax86" ]] || { echo "✗ aria2c not found in archives" >&2; exit 1; }
    lipo -create "$a64" "$ax86" -output aria2c
    rm -rf _a64 _ax86 aria2-arm64.zip aria2-x86.zip
  fi
  chmod +x aria2c
  # Xcode, hardened-runtime ile imzalarken imzasız iç binary'de patlar
  # (yt-dlp/ffmpeg hazır imzalı gelir, static aria2c gelmez) — ad-hoc imzala.
  codesign --force --sign - aria2c 2>/dev/null || true
fi

xattr -cr yt-dlp ffmpeg aria2c 2>/dev/null || true
echo "✓ Tools ready:"
lipo -info yt-dlp ffmpeg aria2c 2>/dev/null || file yt-dlp ffmpeg aria2c
./yt-dlp --version
./ffmpeg -version | head -1
./aria2c --version | head -1
