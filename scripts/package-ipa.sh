#!/usr/bin/env bash
# Builds a release of the app as an .ipa for sideloading (iloader, SideStore, Sideloadly...):
#   scripts/package-ipa.sh 0.1.0        -> build/release/win-0.1.0.ipa
# Needs the runtime in third_party/madeira/app/Madeira built first (docs/DEVELOPMENT.md). The app
# is signed ad hoc, with its entitlements, so the sideloading tool can re-sign it with the user's
# own Apple ID and keep what the app asks for (the raised memory limit).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MADEIRA="$ROOT/third_party/madeira"

VERSION="${1:?usage: scripts/package-ipa.sh <version, e.g. 0.1.0>}"
# The build number: commits so far, so every release has a higher one
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
OUT="$ROOT/build/release"
DERIVED="$OUT/derived"
LOGS="$ROOT/build-logs"
IPA="$OUT/win-$VERSION.ipa"
mkdir -p "$OUT" "$LOGS"

[[ -f "$MADEIRA/app/Madeira/i386-windows/ntdll.dll" ]] || { echo "The 32-bit DLL set is missing (third_party/madeira/build/wine-i386/build.sh)"; exit 1; }
[[ -f "$MADEIRA/app/Madeira/gl/libOSMesa.dylib" ]] || { echo "OpenGL (Zink) is missing from third_party/madeira/app/Madeira/gl"; exit 1; }

echo "== app $VERSION ($BUILD_NUMBER)"
rm -rf "$DERIVED"
if ! xcodebuild -project "$ROOT/win.xcodeproj" -scheme win -configuration Release \
    -sdk iphoneos -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$LOGS/release-app.log" 2>&1; then
  grep -E "error:" "$LOGS/release-app.log" | sort -u | head -30
  exit 1
fi

APP="$DERIVED/Build/Products/Release-iphoneos/win.app"
[[ -d "$APP/PlugIns/winJITHelper.appex" ]] || { echo "The JIT helper is missing from the app"; exit 1; }
[[ -d "$APP/Frameworks/StikJIT.framework" ]] || { echo "StikJIT is missing from the app"; exit 1; }
[[ -f "$APP/arm64ec-windows/ntdll.dll" ]] || { echo "The Wine runtime is missing from the app"; exit 1; }

# The test programs from tests/guest are for development only
find "$APP"/*-windows -maxdepth 1 -name 'win-*.exe' -delete

echo "== signing ad hoc"
ENTITLEMENTS="$OUT/entitlements.plist"
cp "$ROOT/win.entitlements" "$ENTITLEMENTS"
# The debugger that enables JIT (StikJIT) needs it; sideloading tools set it too
plutil -replace get-task-allow -bool YES "$ENTITLEMENTS"
# Inside out: loose dylibs, frameworks, the extension, then the app
for dylib in "$APP"/gl/*.dylib; do
  [[ -f "$dylib" ]] && codesign --force --sign - --timestamp=none "$dylib"
done
for framework in "$APP"/Frameworks/*.framework "$APP"/PlugIns/*.appex/Frameworks/*.framework; do
  [[ -d "$framework" ]] && codesign --force --sign - --timestamp=none "$framework"
done
codesign --force --sign - --timestamp=none "$APP/PlugIns/winJITHelper.appex"
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "== packaging"
rm -rf "$OUT/Payload" "$IPA"
mkdir -p "$OUT/Payload"
ditto "$APP" "$OUT/Payload/win.app"
(cd "$OUT" && zip -qry "$IPA" Payload)
rm -rf "$OUT/Payload"

echo "$IPA ($(du -h "$IPA" | cut -f1)), Madeira $(git -C "$MADEIRA" rev-parse --short HEAD)"
