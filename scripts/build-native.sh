#!/usr/bin/env bash
# Builds the native static libraries the win app links, using the Madeira recipes
# in third_party/madeira. Graphics (DXMT/LLVM), Steam Dock and in-app pairing are
# left out on purpose: the first milestone is a console Windows program.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT="$PROJECT/third_party/madeira"
export JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
export PATH="$(brew --prefix bison)/bin:$PATH"
LOGS="$PROJECT/build-logs"
mkdir -p "$LOGS"

step() {
  local name=$1; shift
  echo "==> $name ($(date +%H:%M:%S))"
  if "$@" >"$LOGS/$name.log" 2>&1; then
    echo "    ok ($(date +%H:%M:%S))"
  else
    echo "    FAILED: $name, see $LOGS/$name.log"; tail -25 "$LOGS/$name.log"; exit 1
  fi
}

step llvm-mingw   "$ROOT/tools/build/setup-llvm-mingw.sh"
step wine-host    "$ROOT/tools/build/build-wine.sh"
step fex          "$ROOT/tools/build/build-fex-ios.sh"
step freetype     "$ROOT/tools/build/build-freetype-ios.sh"
step gnutls       "$ROOT/build/gnutls-ios/build.sh"
step gnutls-sync  "$ROOT/tools/build/sync-gnutls-libs.sh"
step ffmpeg       "$ROOT/build/ffmpeg/build.sh"
step wineserver   "$ROOT/build/wineserver/build.sh"
step ntdll-unix   "$ROOT/build/ntdll-unix/build.sh"
step win32u-unix  "$ROOT/build/win32u-unix/build.sh"
echo "==> done ($(date +%H:%M:%S))"
ls -la "$ROOT"/app/Madeira/*.a
