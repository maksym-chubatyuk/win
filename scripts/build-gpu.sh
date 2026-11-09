#!/usr/bin/env bash
# Builds what GPU support needs, using the Madeira recipes in third_party/madeira:
#   1. ntdll.dll for both DLL sets, which picks up the thread-exit crash fix in loader.c
#   2. LLVM for iOS, which DXMT's shader translator links
#   3. DXMT's native half, as app/Madeira/libdxmt_combined.a
# Finished steps are reused on a rerun. The LLVM step is the slow one.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT="$PROJECT/third_party/madeira"
export JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
export PATH="$(brew --prefix bison)/bin:$PATH"
BIN="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
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

# The commit Madeira pins for its DXMT fork.
fetch_dxmt() {
  local dir="$ROOT/dxmt" pin
  pin="$(git -C "$ROOT" ls-tree HEAD dxmt | awk '{print $3}')"
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin https://github.com/willfaust/dxmt.git
  fi
  if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$pin" ]]; then
    git -C "$dir" fetch --depth 1 origin "$pin"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
  git -C "$dir" submodule update --init --recursive --depth 1
}

build_arm64_ntdll() {
  local out="$ROOT/app/Madeira/aarch64-windows/ntdll.dll"
  PATH="$BIN:$PATH" make -C "$ROOT/wine/build-macos" -j"$JOBS" dlls/ntdll/aarch64-windows/ntdll.dll
  cp "$ROOT/wine/build-macos/dlls/ntdll/aarch64-windows/ntdll.dll" "$out.tmp"
  "$BIN/aarch64-w64-mingw32-strip" --strip-debug "$out.tmp"
  mv "$out.tmp" "$out"
}

step ntdll-arm64ec "$ROOT/build/wine-pe/build-ntdll.sh"
step ntdll-arm64   build_arm64_ntdll
step dxmt-source   fetch_dxmt
step llvm-ios      "$ROOT/tools/build/build-llvm-ios.sh"
step dxmt-shaders  "$ROOT/tools/build/build-shader-headers.sh"
step dxmt-ios      "$ROOT/tools/build/build-dxmt-ios.sh"

echo "==> done ($(date +%H:%M:%S))"
ls -la "$ROOT/app/Madeira/libdxmt_combined.a"
