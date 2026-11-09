// Prints controller 1 as a Windows program sees it through XInput, each time it changes,
// for about 25 seconds. Used to check the on-screen and physical controllers end to end.

#include <windows.h>
#include <xinput.h>
#include <stdio.h>

int main(void) {
    DWORD last_packet = (DWORD)-1, last_result = (DWORD)-1;
    for (int i = 0; i < 250; i++) {
        XINPUT_STATE state;
        DWORD result = XInputGetState(0, &state);
        if (result != last_result) {
            printf("t=%.1fs %s\n", i / 10.0, result == ERROR_SUCCESS ? "connected" : "not connected");
            last_result = result;
        }
        if (result == ERROR_SUCCESS && state.dwPacketNumber != last_packet) {
            XINPUT_GAMEPAD *g = &state.Gamepad;
            printf("t=%.1fs buttons=0x%04x LT=%u RT=%u L=(%d,%d) R=(%d,%d)\n", i / 10.0, g->wButtons,
                   g->bLeftTrigger, g->bRightTrigger, g->sThumbLX, g->sThumbLY, g->sThumbRX, g->sThumbRY);
            last_packet = state.dwPacketNumber;
        }
        fflush(stdout);
        Sleep(100);
    }
    return 0;
}
