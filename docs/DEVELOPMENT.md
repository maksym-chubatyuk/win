# Development

**JIT.** On iOS 26 an app can't make memory executable; a debugger can. Before Wine starts, the app
asks the debugger for one large region and Wine and FEX keep their generated code in it
(`win/WineHost.m`). The debugger is StikJIT, run by the app's own extension (`winJITHelper`)
through LocalDevVPN, or the Mac (`scripts/jit_host.py` through lldb, started by
`scripts/jit-run.sh`). Wine runs as threads of the one app process, as iOS allows no second one.

**Layout.** Madeira is a submodule; its local changes are patches, applied at build time.

| Path | |
| --- | --- |
| `win/` | The app: SwiftUI library and controls, `WineHost.m` (starts Wine, session defaults), `Vendored/` (one-line includes of Madeira's app sources) |
| `winJITHelper/` | App extension for JIT without a Mac (StikJIT, needs a pairing file and LocalDevVPN) |
| `win.entitlements` | Increased Memory Limit (works with a free Apple ID) |
| `third_party/madeira/` | [Madeira](https://github.com/willfaust/madeira) (submodule): Wine, FEX, DXMT sources, toolchains, and the prebuilt runtime in `app/Madeira` |
| `patches/` | The changes Madeira needs, each with a note: `madeira.patch` for Madeira itself, `submodules/<path>.patch` for its `wine`, `FEX` and `dxmt` |
| `scripts/` | Builds, running on a phone, packaging, patches |
| `tests/guest/` | Small Windows test programs, built into `build/guest` and bundled into development builds |

**Building** (Xcode, Homebrew):

```sh
git submodule update --init --recursive
scripts/apply-patches.sh
scripts/build-native.sh              # native static libraries the app links
scripts/build-gpu.sh                 # ntdll.dll, LLVM for iOS, DXMT's native half
```

Then rebuild the runtime parts the patches touch (below), and

```sh
scripts/jit-run.sh                   # build, install, start with JIT; then pick a program on the phone
SKIP_BUILD=1 scripts/jit-run.sh      # start the installed app with JIT, no build
WIN_CONSOLE=1 WIN_EXE=win-probe-x64.exe scripts/jit-run.sh   # run a test program, print its output
```

The phone must be connected and unlocked. `DEVICE=<id>` picks a phone when several are connected
(`xcrun devicectl list devices`).

**Rebuilding runtime parts.** The app links and bundles prebuilt pieces from
`third_party/madeira/app/Madeira`. After changing one:

| Changed | Rebuild |
| --- | --- |
| `third_party/madeira/build/ntdll-unix/*.c` | `third_party/madeira/build/ntdll-unix/build.sh` |
| win32u unix side | `third_party/madeira/build/win32u-unix/build.sh` |
| FEX, 32-bit (`FEX/Source/Windows/WOW64`, `Common`) | `third_party/madeira/build/fex-wow64/build.sh` (makes `aarch64-windows/xtajit.dll`) |
| 32-bit Wine DLLs | `third_party/madeira/build/wine-i386/build.sh` (Homebrew bison first on PATH) |
| DXMT Windows side | `scripts/build-dxmt-pe.sh` |
| DXMT native side | `third_party/madeira/tools/build/build-dxmt-ios.sh` |
| OpenGL (Mesa, Zink) and MoltenVK | `tools/build/prepare-graphics.sh moltenvk`, then `GRAPHICS_WORK=toolchains/graphics/zink-local build/mesa-ios/build.sh` (in `third_party/madeira`; puts `gl/`) |
| Vulkan DLLs | `DEST=app/Madeira/vulkan/arm64ec-windows build/wine-pe/build-modules.sh winevulkan vulkan-1` (in `third_party/madeira`) |
| `tests/guest/*.c` | `scripts/build-guest.sh` |

Then `scripts/jit-run.sh`; it forces a relink when a library is newer than the app.

**Changing Madeira:** edit it in `third_party/madeira` (or its `wine`, `FEX`, `dxmt`), then
`scripts/save-patches.sh` writes the changes back into `patches/` and keeps each patch's note; add
a line to the note. Prebuilt binaries are build outputs and stay out of the patches.

**Updating Madeira:** check out the new commit in `third_party/madeira` (with
`git submodule update --recursive` inside it), run `scripts/apply-patches.sh`, and commit the
submodule. If a patch no longer applies, it stops and names it; fix it by hand and
`scripts/save-patches.sh`.

**Useful switches**, set in the environment of `scripts/jit-run.sh` (the list it passes on is in
the script): `WINEDEBUG`, `WIN_STDERR=1` (Wine's messages to `Documents/wine-stderr.txt`),
`WIN_DIAG=1` (keep Madeira's diagnostics), `MADEIRA_DINPUT_PAD=0` (hide the DirectInput controller
from a game that reads both XInput and DirectInput), `DXMT_PRECISE_MATH=1`.

**When the phone stops answering:**

- Locked phone: builds report "Device is busy" and launches fail. Unlock it; the app keeps the
  screen on only while it is in front.
- File copies (`devicectl device copy from`) that hang even with the phone unlocked:
  `killall CoreDeviceService` on the Mac.
- The runtime log is `Documents/madeira-log.txt` in the app's container.

**Releasing:** `scripts/package-ipa.sh 0.2.0`, then
`gh release create v0.2.0 build/release/win-0.2.0.ipa`. The release leaves out the test programs.

What has to be tested by hand is in [TESTING.md](../TESTING.md).

**License.** Madeira is GPL-3.0-or-later (its Wine fork LGPL). Giving the built app to anyone means
offering them the corresponding source: this repository at the release's tag, with the Madeira
commit it pins and `patches/`.
