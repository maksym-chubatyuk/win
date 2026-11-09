# Manual testing

What has to be checked by hand on an iPhone: taps, other controllers, and anything that needs you
to play. The runtime paths were tested on the device through the app's test hooks
(`scripts/jit-run.sh` with `WIN_AUTOTEST`, `WIN_PAD_TEST`, `WIN_PAD_PRESSES`, `WIN_IMPORT_TEST` and
the programs in `tests/guest`); what remains is the screens themselves and real play.

Tick an item off when it works; note what went wrong otherwise.

## JIT and setup

- [ ] JIT without a Mac: import the pairing file, connect LocalDevVPN, Check Setup, run a program.
- [ ] Replace Pairing File and Reset Developer Disk Image.
- [ ] Without LocalDevVPN, or over cellular data, running a program says what to do.

## Programs

- [ ] Add a program with Choose Folder and with Choose .exe File, from iCloud Drive and On My iPhone.
- [ ] Remove a program: swipe, long press and Edit all ask first.
- [ ] Notepad runs, and typing with the on-screen keyboard reaches it.
- [ ] A 32-bit program runs; an unsupported one is greyed out.
- [ ] Resolution: each size reaches the program.
- [ ] Share Log shares the last run's madeira-log.txt.

## Controls

- [ ] Mouse mode: a tap clicks where it lands; dragging drags.
- [ ] Controller mode: both sticks (from wherever the thumb lands), L3/R3 by double-tap and hold,
      ABXY, the D-pad, LB/RB and LT/RT on their ring segments, View and Menu.
- [ ] The mode is remembered for the next program.
- [ ] Controller Layout for all programs: drag and pinch each group, Size, Opacity, Vibrate on Press,
      Reset, Save and Cancel.
- [ ] Controller Layout for one program (long press): This Program Only keeps its own layout, All
      Programs goes back to the shared one; the running program uses the right one.
- [ ] A physical controller (Xbox, PlayStation), together with the on-screen one.
- [ ] A hardware keyboard; a mouse with AssistiveTouch.
