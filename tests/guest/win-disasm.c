// Disassembles every <folder>\*.dxbc into a .asm file next to it, with the D3DDisassemble
// of the d3dcompiler_47.dll named first on the command line. The folder is the second
// argument (default C:\shaders).
// Used to read the shaders a game handed to Direct3D, dumped by DXMT_SHADER_DUMP=1.

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    void *vtbl;
} blob_t;
typedef struct {
    HRESULT (WINAPI *QueryInterface)(void *, const GUID *, void **);
    ULONG (WINAPI *AddRef)(void *);
    ULONG (WINAPI *Release)(void *);
    void *(WINAPI *GetBufferPointer)(void *);
    SIZE_T (WINAPI *GetBufferSize)(void *);
} blob_vtbl;

typedef HRESULT (WINAPI *disassemble_fn)(const void *, SIZE_T, UINT, const char *, void **);

int main(int argc, char **argv) {
    const char *dll = argc > 1 ? argv[1] : "d3dcompiler_47.dll";
    HMODULE module = LoadLibraryA(dll);
    if (!module) { printf("cannot load %s (%lu)\n", dll, GetLastError()); return 1; }
    disassemble_fn disassemble = (disassemble_fn)GetProcAddress(module, "D3DDisassemble");
    if (!disassemble) { printf("no D3DDisassemble\n"); return 1; }

    const char *folder = argc > 2 ? argv[2] : "C:\\shaders";
    char pattern[MAX_PATH];
    snprintf(pattern, sizeof pattern, "%s\\*.dxbc", folder);
    WIN32_FIND_DATAA found;
    HANDLE search = FindFirstFileA(pattern, &found);
    if (search == INVALID_HANDLE_VALUE) { printf("no shaders\n"); return 1; }
    int done = 0, failed = 0, skipped = 0;
    do {
        char in[MAX_PATH], out[MAX_PATH];
        snprintf(in, sizeof in, "%s\\%s", folder, found.cFileName);
        snprintf(out, sizeof out, "%s\\%.*s.asm", folder, (int)(strlen(found.cFileName) - 5), found.cFileName);
        if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES) { skipped++; continue; }
        FILE *f = fopen(in, "rb");
        if (!f) { failed++; continue; }
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        fseek(f, 0, SEEK_SET);
        void *data = malloc(size);
        fread(data, 1, size, f);
        fclose(f);
        void *text = NULL;
        if (SUCCEEDED(disassemble(data, size, 0, NULL, &text)) && text) {
            blob_vtbl *v = *(blob_vtbl **)text;
            FILE *o = fopen(out, "wb");
            if (o) {
                SIZE_T n = v->GetBufferSize(text);
                const char *p = v->GetBufferPointer(text);
                while (n && p[n - 1] == 0) n--;
                fwrite(p, 1, n, o);
                fclose(o);
            }
            v->Release(text);
            done++;
        } else {
            failed++;
        }
        free(data);
    } while (FindNextFileA(search, &found));
    FindClose(search);
    printf("disassembled %d, failed %d, already done %d\n", done, failed, skipped);
    return 0;
}
