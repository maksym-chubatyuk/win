#!/usr/bin/env bash
# Rebuilds DXMT's Windows-side DLLs (arm64ec: d3d11, dxgi, d3d10core, winemetal) from
# third_party/madeira/dxmt and puts them where the app bundles them from, the same way
# third_party/madeira/build/windows-runtime/build.sh does for a full runtime build.
# The DLLs that were there first are kept once in build/pe-backup.
#
# The native half of DXMT (libdxmt_combined.a) is built separately by
# third_party/madeira/tools/build/build-dxmt-ios.sh.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$PROJECT/third_party/madeira"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
W="$R/wine/build-arm64ec"
B="$R/dxmt/build-arm64ec"
DEST="$R/app/Madeira/arm64ec-windows"
export PATH="$TC:$PATH"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

# Import libraries DXMT links against, from Wine's arm64ec build.
make -C "$W" -s dlls/ntdll/arm64ec-windows/libntdll.a dlls/dbghelp/arm64ec-windows/libdbghelp.a

if [[ ! -f "$B/build.ninja" ]]; then
  sed "s|@GLOBAL_SOURCE_ROOT@|$R|g" "$R/dxmt/build-arm64ec-win.txt" > "$W/dxmt-arm64ec.ini"
  meson setup "$B" "$R/dxmt" --cross-file "$W/dxmt-arm64ec.ini" --native-file "$R/dxmt/build-osx.txt" \
    --buildtype release -Dwine_build_path="$W" -Dwine_builtin_dll=true -Denable_nvapi=true
fi
meson compile -C "$B" -j "$(sysctl -n hw.ncpu)"

mkdir -p "$PROJECT/build/pe-backup"
for m in d3d11/d3d11.dll dxgi/dxgi.dll d3d10/d3d10core.dll winemetal/winemetal.dll; do
  name="$(basename "$m")"
  [[ -f "$PROJECT/build/pe-backup/$name" ]] || cp "$DEST/$name" "$PROJECT/build/pe-backup/$name"
  "$TC/arm64ec-w64-mingw32-strip" --strip-debug -o "$DEST/$name" "$B/src/$m"
done
echo "DXMT arm64ec DLLs installed in $DEST"
