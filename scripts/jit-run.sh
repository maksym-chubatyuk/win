#!/usr/bin/env bash
# Builds the app, installs it on the connected iPhone, starts it suspended and
# attaches the Mac-side JIT host, then collects results. The iPhone must be unlocked.
# DEVICE defaults to the first connected iPhone (`xcrun devicectl list devices`).
#
#   scripts/jit-run.sh           opens the program library; waits until you tap a program
#   SKIP_BUILD=1 scripts/jit-run.sh   no build or install: only starts the installed app with JIT
#   WIN_EXE=notepad.exe scripts/jit-run.sh                        starts one from system32
#   WIN_CONSOLE=1 WIN_EXE=win-probe-x64.exe scripts/jit-run.sh    a console program
#   WIN_EXE=notepad.exe WIN_AUTOTEST=1 WIN_TAP=40,12 scripts/jit-run.sh    scripted input
#   WIN_AUTOTEST=1 WIN_IMPORT_TEST=1 WIN_LIBRARY_EXE=win-window-x64.exe scripts/jit-run.sh
#                                imports a bundled program, then runs the imported copy
#
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$PROJECT/build/DerivedData"
LOGS="$PROJECT/build-logs"
SCREENS="$PROJECT/build/screens"
WAIT_SECONDS="${WAIT_SECONDS:-120}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$LOGS" "$SCREENS"

if [[ -z "${DEVICE:-}" ]]; then
  xcrun devicectl list devices --quiet --json-output "$WORK/devices.json" >/dev/null 2>&1 || true
  DEVICE="$(python3 -I -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and conn.get("tunnelState") == "connected":
        print(d["identifier"]); break
' "$WORK/devices.json")"
  if [[ -z "$DEVICE" ]]; then
    echo "No connected iPhone found. Connect it, unlock it, and check \`xcrun devicectl list devices\`."
    exit 1
  fi
fi

# Xcode does not track libraries passed with -l, so a rebuilt one needs a forced relink.
APP_BINARY="$DERIVED/Build/Products/Debug-iphoneos/win.app/win"
if [[ -n "$(find "$PROJECT/third_party/madeira/app/Madeira" -maxdepth 1 -name '*.a' -newer "$APP_BINARY" 2>/dev/null)" ]]; then
  rm -f "$APP_BINARY"
  find "$DERIVED/Build/Intermediates.noindex" -path '*/Objects-normal/arm64/Binary/win' -delete
fi

if [[ -z "${SKIP_BUILD:-}" ]]; then
if ! xcodebuild -project "$PROJECT/win.xcodeproj" -scheme win -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  build >"$LOGS/app-build.log" 2>&1; then
  echo "App build failed, see $LOGS/app-build.log"
  grep -E "error:|Undefined symbol|duplicate symbol|ld: |clang: error|\*\* BUILD" "$LOGS/app-build.log" | sort -u | head -60
  exit 1
fi
echo "app built"

xcrun devicectl device install app --device "$DEVICE" --quiet \
  "$DERIVED/Build/Products/Debug-iphoneos/win.app"
echo "app installed"
fi

# The bundle ID comes from the build, so a changed signing setup needs no edit here.
BUNDLE_ID="${BUNDLE_ID:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$DERIVED/Build/Products/Debug-iphoneos/win.app/Info.plist" 2>/dev/null || echo winnny.win)}"

# devicectl rejects an empty environment, so the option is only passed when there is one.
# Built with JSON escaping, so Windows paths with backslashes survive.
ENVIRONMENT="$(python3 -I -c '
import json, os, sys
names = sys.argv[1:]
values = {n: os.environ[n] for n in names if os.environ.get(n)}
print(json.dumps(values) if values else "")
' WIN_EXE WIN_ARGS WIN_CONSOLE WIN_AUTOTEST WIN_TAP WIN_DESKTOP WIN_IMPORT_TEST WIN_LIBRARY_EXE WIN_CLEAN_TESTS WIN_NO_PLACEHOLDER WIN_POOL_MB WIN_DIAG WIN_TEST_HELPER WIN_NO_TYPING WIN_TAPS WIN_SNAPSHOT_EVERY WIN_ENGINE_CONSOLE WIN_PAD_TEST WIN_PAD_PRESSES MADEIRA_DINPUT_TRACE WIN_SHOW_PAD QT_QUICK_BACKEND QT_OPENGL QSG_RHI_BACKEND MADEIRA_FEX_ARENA MADEIRA_DEBUG_VERBOSE DXMT_PRECISE_MATH DXMT_FAST_REASSOC MADEIRA_PROBES FEX_VECTORTSOENABLED FEX_TSOENABLED FEX_MULTIBLOCK DXMT_SHADER_DUMP WIN_STDERR DXMT_LOG_LEVEL WINEDEBUG MADEIRA_FRAME_STATS DXMT_METALFX_SPATIAL_SWAPCHAIN DXMT_CONFIG DXMT_DYN_KEEP DXMT_DYN_KEEP_KB DXMT_ALLOC_STATS WIN_RESOLUTION WIN_CLEAN_SLATE)"
LAUNCH_OPTIONS=()
if [[ -n "$ENVIRONMENT" ]]; then LAUNCH_OPTIONS=(--environment-variables "$ENVIRONMENT"); fi

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --start-stopped --quiet ${LAUNCH_OPTIONS[@]+"${LAUNCH_OPTIONS[@]}"} \
  --json-output "$WORK/launch.json" "$BUNDLE_ID"
PID="$(plutil -extract result.process.processIdentifier raw -o - "$WORK/launch.json")"
echo "launched pid $PID"

xcrun lldb --batch \
  -o "command script import '$PROJECT/scripts/jit_host.py'" \
  -o "jit_host $DEVICE $PID"

# A copy with no timeout can hang for good and wedge CoreDevice's file service for every
# later transfer (2026-11-06); `killall CoreDeviceService` clears that.
fetch() {
  xcrun devicectl device copy from --device "$DEVICE" --quiet --timeout 30 \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/$1" --destination "$2" >/dev/null 2>&1
}

# Wine runs after the debugger detaches, so results are only on the device.
# A desktop session keeps running, so without an autotest there is nothing to wait for.
for ((elapsed = 0; elapsed < WAIT_SECONDS; elapsed += 3)); do
  if [[ -n "${WIN_AUTOTEST:-}" ]]; then
    fetch autotest-done.txt "$WORK/done.txt" && break
  elif [[ -n "${WIN_CONSOLE:-}" ]]; then
    fetch wine-output.txt "$WORK/out.txt" && grep -q "wine finished" "$WORK/out.txt" && break
  else
    break
  fi
  sleep 3
done

fetch wine-output.txt "$LOGS/device-output.txt" && cp "$LOGS/device-output.txt" "$WORK/out.txt" || true
echo "--- guest output ---"
cat "$WORK/out.txt" 2>/dev/null || echo "(no output file)"

if [[ -n "${WIN_AUTOTEST:-}" ]]; then
  echo "--- autotest ---"
  cat "$WORK/done.txt" 2>/dev/null || echo "(autotest did not finish)"
  echo
  rm -f "$SCREENS"/*.png
  for name in 0-library 1-started 2-typed 3-tapped 4-tapped-again tap-1 tap-2 tap-3 tap-4 tap-5 tap-6 console pad-sticks run-1 run-2 run-3 run-4 run-5 run-6 run-7 run-8 run-9 run-10 run-11 run-12 press-1 press-2 press-3 press-4 press-5 press-6 press-7 press-8; do
    if fetch "screen-$name.png" "$SCREENS/$name.png"; then echo "screenshot: $SCREENS/$name.png"; fi
  done
fi

if [[ "${WIN_EXE:-}${WIN_LIBRARY_EXE:-}" == win-window* ]] && fetch wine/drive_c/win-window.log "$WORK/messages.txt"; then
  echo "--- messages the program received ---"
  grep -vE "msg=0x010[012]|msg=0x0135|msg=0x0020" "$WORK/messages.txt" | tail -n 30
fi

if [[ -n "${WIN_STDERR:-}" ]] && fetch wine-stderr.txt "$LOGS/device-stderr.txt"; then
  echo "runtime messages: $LOGS/device-stderr.txt ($(wc -l <"$LOGS/device-stderr.txt") lines)"
fi

if fetch madeira-log.txt "$LOGS/device-wine.log"; then
  echo "--- end of runtime log, full copy in $LOGS/device-wine.log ---"
  tail -n "${LOG_LINES:-15}" "$LOGS/device-wine.log"
else
  echo "(no runtime log)"
fi

# Captured first: `grep -q` closing a live pipe would fail the pipeline under pipefail.
PROCESSES="$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null || true)"
if grep -q "win.app/win" <<<"$PROCESSES"; then
  echo "--- app is still running ---"
else
  echo "--- app is no longer running ---"
fi
