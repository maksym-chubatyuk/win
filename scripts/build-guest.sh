#!/usr/bin/env bash
# Builds the Windows test programs for x86-64, ARM64 and 32-bit x86 into build/guest. The app's
# "Bundle Wine runtime" phase copies the results into the matching DLL sets.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$PROJECT/tests/guest/win-probe.c"
OUT="$PROJECT/build/guest"
BIN="$PROJECT/third_party/madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
mkdir -p "$OUT"

# The expected answer comes from a native Mac run, so a wrong answer on the phone
# points at the translation rather than at the test.
cat >"$OUT/checksum.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
int main(void) {
    uint64_t state = 88172645463325252ULL, sum = 0;
    for (int i = 0; i < 200000000; i++) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        sum += state & 0xff;
    }
    printf("%llu\n", (unsigned long long)sum);
    return 0;
}
EOF
clang -O1 "$OUT/checksum.c" -o "$OUT/checksum"
CHECKSUM="$("$OUT/checksum")"
echo "expected integer checksum: $CHECKSUM"

build() {
  "$BIN/$1-w64-mingw32-clang" -O1 -Wall -Wextra -static \
    -DBENCHMARK_INTEGER_CHECKSUM="${CHECKSUM}ULL" "$SOURCE" -o "$OUT/$2"
  "$BIN/llvm-readobj" --file-headers "$OUT/$2" | grep -m1 "Machine:"
}
build x86_64 win-probe-x64.exe
build aarch64 win-probe-arm64.exe

"$BIN/x86_64-w64-mingw32-clang" -O1 -Wall -Wextra -mwindows \
  "$PROJECT/tests/guest/win-window.c" -o "$OUT/win-window-x64.exe"
"$BIN/aarch64-w64-mingw32-clang" -O1 -Wall -Wextra -mwindows \
  "$PROJECT/tests/guest/win-window.c" -o "$OUT/win-window-arm64.exe"

# Benchmark suites: the CPU one for both architectures (FEX against native), the GPU one
# for x86-64 only, since Wine's d3dcompiler is only in the x86-64 DLL set.
for arch in x86_64:x64 aarch64:arm64; do
  "$BIN/${arch%%:*}-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-cpubench.c" \
    -o "$OUT/win-cpubench-${arch##*:}.exe"
done
"$BIN/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-gpubench.c" \
  -ld3d11 -ld3dcompiler -ldxgi -o "$OUT/win-gpubench-x64.exe"
"$BIN/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-d3dconform.c" \
  -ld3d11 -ld3dcompiler -o "$OUT/win-d3dconform-x64.exe"
"$BIN/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-disasm.c" \
  -o "$OUT/win-disasm-x64.exe"
"$BIN/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-xinput.c" \
  -lxinput -o "$OUT/win-xinput-x64.exe"
"$BIN/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-dinput.c" \
  -ldinput8 -ldxguid -o "$OUT/win-dinput-x64.exe"
# 32-bit x86 builds (WoW64), copied into the i386 DLL set: the probe (CPU and console),
# a window, XInput and the Direct3D 11 conformance test.
"$BIN/i686-w64-mingw32-clang" -O1 -Wall -Wextra -static \
  -DBENCHMARK_INTEGER_CHECKSUM="${CHECKSUM}ULL" "$SOURCE" -o "$OUT/win-probe-x86.exe"
"$BIN/i686-w64-mingw32-clang" -O1 -Wall -Wextra -mwindows \
  "$PROJECT/tests/guest/win-window.c" -o "$OUT/win-window-x86.exe"
"$BIN/i686-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-xinput.c" \
  -lxinput -o "$OUT/win-xinput-x86.exe"
"$BIN/i686-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-dinput.c" \
  -ldinput8 -ldxguid -o "$OUT/win-dinput-x86.exe"
"$BIN/i686-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-d3dconform.c" \
  -ld3d11 -ld3dcompiler -o "$OUT/win-d3dconform-x86.exe"
"$BIN/i686-w64-mingw32-clang" -O2 -Wall -Wextra "$PROJECT/tests/guest/win-cpubench.c" \
  -o "$OUT/win-cpubench-x86.exe"
"$BIN/llvm-readobj" --file-headers "$OUT/win-probe-x86.exe" | grep -m1 "Machine:"

# Desktop OpenGL checks, 64- and 32-bit (the 32-bit one goes through the WoW64 GL thunks).
"$BIN/x86_64-w64-mingw32-clang" -O1 -Wall -Wextra "$PROJECT/tests/guest/win-gl.c" \
  -lopengl32 -lgdi32 -o "$OUT/win-gl-x64.exe"
"$BIN/i686-w64-mingw32-clang" -O1 -Wall -Wextra "$PROJECT/tests/guest/win-gl.c" \
  -lopengl32 -lgdi32 -o "$OUT/win-gl-x86.exe"

# Vulkan through winevulkan on MoltenVK (64-bit only).
"$BIN/x86_64-w64-mingw32-clang" -O1 -Wall -Wextra "$PROJECT/tests/guest/win-vulkan.c" -o "$OUT/win-vulkan-x64.exe"

# Structured exception handling (stack SEH frames on 32-bit x86).
"$BIN/i686-w64-mingw32-clang" -O1 -Wall -Wextra "$PROJECT/tests/guest/win-seh.c" -o "$OUT/win-seh-x86.exe"

# The same CPU suite natively on this Mac, as a reference point.
clang -O2 -Wall -Wextra "$PROJECT/tests/guest/win-cpubench.c" -o "$OUT/cpubench-mac"
