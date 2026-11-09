// Prints controller 1 as a Windows program sees it through DirectInput 8, each time it
// changes, for about 25 seconds: the counterpart of win-xinput.c for games that read
// their pad only through DirectInput. Run with WIN_PAD_TEST=1 to drive the on-screen
// controller through a fixed sequence.

#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <stdio.h>
#include <string.h>

static LPDIRECTINPUT8A input;
static GUID first_guid;
static int devices;

static BOOL CALLBACK enum_device(const DIDEVICEINSTANCEA *instance, void *context) {
    (void)context;
    printf("device %d: \"%s\" type=0x%08lx\n", devices, instance->tszProductName, instance->dwDevType);
    if (!devices) first_guid = instance->guidInstance;
    devices++;
    return DIENUM_CONTINUE;
}

int main(void) {
    HINSTANCE module = GetModuleHandleA(NULL);
    HRESULT hr = DirectInput8Create(module, DIRECTINPUT_VERSION, &IID_IDirectInput8A, (void **)&input, NULL);
    if (FAILED(hr)) { printf("DirectInput8Create failed 0x%08lx\n", hr); return 1; }
    hr = IDirectInput8_EnumDevices(input, DI8DEVCLASS_GAMECTRL, enum_device, NULL, DIEDFL_ATTACHEDONLY);
    printf("game controllers: %d\n", devices);
    if (!devices) return 2;

    LPDIRECTINPUTDEVICE8A pad;
    if (FAILED(hr = IDirectInput8_CreateDevice(input, &first_guid, &pad, NULL))) {
        printf("CreateDevice failed 0x%08lx\n", hr); return 3;
    }
    DIDEVCAPS caps;
    memset(&caps, 0, sizeof(caps));
    caps.dwSize = sizeof(caps);
    IDirectInputDevice8_GetCapabilities(pad, &caps);
    printf("axes=%lu buttons=%lu povs=%lu\n", caps.dwAxes, caps.dwButtons, caps.dwPOVs);

    // A cooperative level needs a top-level window of this process.
    HWND window = CreateWindowA("STATIC", "win-dinput", WS_OVERLAPPED, 0, 0, 10, 10, NULL, NULL, module, NULL);
    IDirectInputDevice8_SetCooperativeLevel(pad, window, DISCL_BACKGROUND | DISCL_NONEXCLUSIVE);
    if (FAILED(hr = IDirectInputDevice8_SetDataFormat(pad, &c_dfDIJoystick2))) {
        printf("SetDataFormat failed 0x%08lx\n", hr); return 4;
    }
    if (FAILED(hr = IDirectInputDevice8_Acquire(pad))) { printf("Acquire failed 0x%08lx\n", hr); return 5; }

    DIJOYSTATE2 last;
    memset(&last, 0xff, sizeof(last));
    for (int i = 0; i < 250; i++) {
        DIJOYSTATE2 state;
        IDirectInputDevice8_Poll(pad);
        hr = IDirectInputDevice8_GetDeviceState(pad, sizeof(state), &state);
        if (SUCCEEDED(hr) && memcmp(&state, &last, sizeof(state))) {
            unsigned buttons = 0;
            for (int b = 0; b < 16; b++) if (state.rgbButtons[b] & 0x80) buttons |= 1u << b;
            printf("t=%.1fs buttons=0x%04x X=%ld Y=%ld Z=%ld Rx=%ld Ry=%ld pov=%ld\n", i / 10.0, buttons,
                   state.lX, state.lY, state.lZ, state.lRx, state.lRy, (long)(int)state.rgdwPOV[0]);
            last = state;
        } else if (FAILED(hr)) {
            printf("t=%.1fs GetDeviceState failed 0x%08lx\n", i / 10.0, hr);
        }
        fflush(stdout);
        Sleep(100);
    }
    IDirectInputDevice8_Unacquire(pad);
    return 0;
}
