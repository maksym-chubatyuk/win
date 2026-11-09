# win

Windows programs and games on iPhone: [Wine](https://www.winehq.org), with
[FEX](https://github.com/FEX-Emu/FEX) translating x86 and x86-64 code,
[DXMT](https://github.com/3Shain/dxmt) for Direct3D 10 and 11, and Mesa's Zink on MoltenVK for
OpenGL. The runtime is [Madeira](https://github.com/willfaust/madeira)'s; this is the app around it.

## Requirements

- **iOS 26.5 or later.** Tested on iOS 26.6.
- **Device support** (memory wise):
  - 8 GB or more (iPhone 15 Pro, 16 series, 17 series): recommended, and what this is tested on
    (iPhone 16 Pro Max);
  - 6 GB (iPhone 12 Pro, 13 Pro, 14, 15): untested, small programs should work.
  - 4 GB or less: untested, unlikely to run games.
- A computer (Windows, macOS or Linux) and a USB cable, for the first setup and the 7-day reinstall.
- An Apple ID.

## Installing

### 1. Install the app

1. Download `win-<version>.ipa` from [Releases](https://github.com/maksym-chubatyuk/win/releases).
2. Install [iloader](https://github.com/nab138/iloader) on the computer, from its GitHub releases or
   [iloader.app](https://iloader.app).
3. Connect the iPhone with the cable, unlock it and tap **Trust** when it asks about the computer.
4. In iloader, sign in with your Apple ID and import the IPA. iloader signs it with your Apple ID
   and installs it.
5. On the iPhone:
   - **Settings › Privacy & Security › Developer Mode**: turn it on and restart when asked.
   - **Settings › General › VPN & Device Management**: trust your Apple ID if win does not open.

### 2. Set up JIT

Wine and FEX need JIT, so we need a debugger. One is built in (StikJIT). It needs two things:

1. **The iPhone's pairing file.** Make it with iloader's pairing file option while the iPhone is
   connected, and save it. Send the file to the iPhone (AirDrop, iCloud Drive, or any way it ends
   up in the Files app). In win, under **Run Without a Mac**, tap **Import Pairing File** and pick
   it. The app keeps it.
2. **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** from the App Store. Open it and
   connect. It works on Wi-Fi or with no network, but **not over cellular data**.

Tap **Check Setup**. The first time, it downloads the Developer Disk Image, takes a minute and
needs internet.

### 3. Programs

Tap **+** and pick a program from the Files app:

- **Choose Folder**: a program's whole folder, for anything that comes with its own files (games);
- **Choose .exe File**: a single program.

win copies it into its Windows drive (`C:\Programs\<folder>`). x86-64, 32-bit x86 and ARM64
programs work. Tap one to run it; it takes about 25 seconds to start, and the screen freezes for
some of that. Notepad comes with Wine, to try things out.

### Playing

The two buttons at the top of the screen:

- **Mouse / controller**: in mouse mode a tap is a click. In controller mode the screen is an Xbox
  controller: the left half is the left stick and the right half the right stick, wherever your
  thumb lands; double-tap a stick and hold for L3/R3. Arrange it with the controller button in
  **Programs**, or for one program, long-press it › **Controller Layout**.
- **Keyboard**: shows and hides the on-screen keyboard.

Physical controllers (Xbox, PlayStation, MFi) and keyboards are passed on to the program too. A mouse works with
AssistiveTouch on (**Settings › Accessibility › Touch › AssistiveTouch**).

**Resolution** (top left in Programs) is the screen size Windows reports. Lower is faster; games
with their own resolution setting may need it changed in the game too.

### Every time you play

Connect LocalDevVPN first, then open win. To run a different program, close the app and open it
again.

With a free Apple ID, the app stops opening after 7 days. Install it again with iloader. Your
programs, saves and settings stay.

## Troubleshooting

- **The debugger does not connect**: check that LocalDevVPN is connected and you are not on
  cellular data, then **Check Setup**. If the iPhone was reset, re-paired with the computer or its
  passcode changed, make a new pairing file in iloader and use **Replace Pairing File**. If the disk
  image step fails, **Reset Developer Disk Image** and check again.
- **win does not open**: after 7 days with a free Apple ID, reinstall it with iloader. Otherwise,
  check Developer Mode and that your Apple ID is trusted (above).
- **A program does not start or runs badly**: try a lower **Resolution**. Vulkan works for 64-bit
  programs only, Direct3D 12 is untested, and a phone's GPU and memory set limits of their own.

## Reporting problems

[Open an issue](https://github.com/maksym-chubatyuk/win/issues/new/choose) and attach the log:
right after the problem, close win, open it again and tap **Share Log** in Programs (it is the log
of the last program run, and goes once you start another). Please don't report problems with this
app to Wine's, FEX's, DXMT's or Madeira's own trackers.

Building from source: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

GPL-3.0-or-later, like Madeira (`LICENSE`; Madeira's additional permission for Apple's frameworks
is in `third_party/madeira/LICENSE-EXCEPTION.md`). Its Wine fork is LGPL-2.1-or-later, FEX and DXMT
are MIT, StikJIT is MPL-2.0; see `third_party/madeira/LICENSES` and `THIRD-PARTY-NOTICES.md` there.
