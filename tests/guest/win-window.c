// Windows GUI test program: a window with GDI drawing and a button that responds to
// clicks. Its window position is fixed, so scripts can tap the button by coordinates.

#include <windows.h>

#define BUTTON_ID 1

static int clicks = 0;
static int ticks = 0;
static HWND button;
static HANDLE message_log;

// Records what the program receives, in C:\\win-window.log, for checking from the Mac.
static void log_message(const char *where, HWND hwnd, UINT message) {
    if (message == WM_PAINT || message == WM_TIMER || message == WM_NCPAINT || message == WM_ERASEBKGND) return;
    char line[96];
    DWORD count;
    int length = wsprintfA(line, "%s hwnd=%p msg=0x%04x\r\n", where, hwnd, message);
    WriteFile(message_log, line, length, &count, NULL);
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    log_message("proc", hwnd, message);
    switch (message) {
    case WM_TIMER:
        // Shows on screen that the message loop is still running.
        ticks++;
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_MOUSEACTIVATE: {
        LRESULT result = DefWindowProcA(hwnd, message, wparam, lparam);
        char line[256];
        DWORD count;
        int length = wsprintfA(line, "mouseactivate result=%d wparam=%p foreground=%p active=%p desktop=%p "
                               "button_root=%p button_parent=%p own_root=%p own_parent=%p own_ancestor_parent=%p\r\n",
                               (int)result, (void *)wparam, GetForegroundWindow(), GetActiveWindow(), GetDesktopWindow(),
                               GetAncestor(button, GA_ROOT), GetParent(button), GetAncestor(hwnd, GA_ROOT),
                               GetParent(hwnd), GetAncestor(hwnd, GA_PARENT));
        WriteFile(message_log, line, length, &count, NULL);
        return result;
    }
    case WM_CREATE:
        button = CreateWindowA("BUTTON", "Click me", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                               20, 110, 200, 60, hwnd, (HMENU)BUTTON_ID, NULL, NULL);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == BUTTON_ID) {
            clicks++;
            InvalidateRect(hwnd, NULL, TRUE);
        }
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        char line[64];
#if defined(__x86_64__)
        const char *arch = "This window comes from x86-64 code";
#elif defined(__i386__)
        const char *arch = "This window comes from 32-bit x86 code";
#else
        const char *arch = "This window comes from ARM64 code";
#endif
        TextOutA(dc, 20, 16, arch, lstrlenA(arch));
        wsprintfA(line, "Button clicks: %d   Timer ticks: %d  ", clicks, ticks);
        TextOutA(dc, 20, 44, line, lstrlenA(line));

        HBRUSH brush = CreateSolidBrush(clicks ? RGB(40, 160, 70) : RGB(200, 60, 50));
        RECT swatch = { 260, 110, 400, 170 };
        FillRect(dc, &swatch, brush);
        DeleteObject(brush);
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, message, wparam, lparam);
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command_line, int show) {
    (void)previous;
    (void)command_line;

    message_log = CreateFileA("C:\\win-window.log", GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);

    WNDCLASSA window_class = {0};
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance;
    window_class.hCursor = LoadCursor(NULL, IDC_ARROW);
    window_class.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    window_class.lpszClassName = "WinProbeWindow";
    if (!RegisterClassA(&window_class)) return 1;

    HWND hwnd = CreateWindowA("WinProbeWindow", "win-window test", WS_OVERLAPPEDWINDOW,
                              100, 80, 500, 300, NULL, NULL, instance, NULL);
    if (!hwnd) return 2;
    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 1000, NULL);

    MSG message;
    while (GetMessageA(&message, NULL, 0, 0) > 0) {
        log_message("loop", message.hwnd, message.message);
        TranslateMessage(&message);
        DispatchMessageA(&message);
    }
    return 0;
}
