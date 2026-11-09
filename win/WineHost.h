#pragma once
#include <stdbool.h>
#include <stdint.h>

// Frames presented through Direct3D or OpenGL so far (Vendored/WiniosGL.m).
uint64_t madeira_frame_count(void);

// True once a debugger has set CS_DEBUGGED on this process.
bool win_jit_debugger_flag(void);

// Creates the Wine prefix if it does not exist yet. Safe to call repeatedly.
void win_wine_prepare_prefix(void);

// Starts Wine on a background thread and runs one Windows program. `exe` is a name in
// system32 or a full C:\\ path, and `folder` is its working folder (NULL for the default).
// Needs scripts/jit_host.py attached: it authorizes the executable memory, then detaches
// before Wine starts. Guest stdout goes to Documents/wine-output.txt.
// With a screen size, the program's windows and Direct3D output are shown; the size is
// the Windows screen it sees. Pass 0 for a console program.
void win_wine_start(const char *exe, const char *args, const char *folder,
                    int desktop_width, int desktop_height);

// True once the program has ended or Wine failed to start.
bool win_wine_finished(int *exit_code);
