// Desktop OpenGL conformance checks for the iOS port: one window, one WGL context, and
// a set of draws each verified by reading a pixel back. It covers the paths a 32-bit
// program takes through Wine's WoW64 GL thunks, where an argument can be a client
// address or an offset into a bound buffer: client and buffer vertex arrays, client
// and buffer indices, texture uploads from memory and from a pixel-unpack buffer,
// reads into a pixel-pack buffer, mapped buffers, glGetPointerv, and the shader paths
// older games use (fixed function, ARB assembly programs as Cg emits them, GLSL).
//
// Prints one "ok"/"FAIL" line per check and "checks: N, failures: M"; the exit code is
// the number of failures.

#include <windows.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <stdio.h>
#include <string.h>

static int checks, failures;

static void check(const char *name, int ok, const char *detail) {
    printf("%-4s %2d %-44s %s\n", ok ? "ok" : "FAIL", checks, name, detail ? detail : "");
    checks++;
    if (!ok) failures++;
}

#define GL_FUNCS(X) \
    X(PFNGLGENBUFFERSPROC, glGenBuffers) X(PFNGLBINDBUFFERPROC, glBindBuffer) \
    X(PFNGLBUFFERDATAPROC, glBufferData) X(PFNGLMAPBUFFERPROC, glMapBuffer) \
    X(PFNGLUNMAPBUFFERPROC, glUnmapBuffer) X(PFNGLDELETEBUFFERSPROC, glDeleteBuffers) \
    X(PFNGLCREATESHADERPROC, glCreateShader) X(PFNGLSHADERSOURCEPROC, glShaderSource) \
    X(PFNGLCOMPILESHADERPROC, glCompileShader) X(PFNGLGETSHADERIVPROC, glGetShaderiv) \
    X(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog) X(PFNGLCREATEPROGRAMPROC, glCreateProgram) \
    X(PFNGLATTACHSHADERPROC, glAttachShader) X(PFNGLLINKPROGRAMPROC, glLinkProgram) \
    X(PFNGLGETPROGRAMIVPROC, glGetProgramiv) X(PFNGLUSEPROGRAMPROC, glUseProgram) \
    X(PFNGLGETUNIFORMLOCATIONPROC, glGetUniformLocation) X(PFNGLUNIFORM4FVPROC, glUniform4fv) \
    X(PFNGLGENPROGRAMSARBPROC, glGenProgramsARB) X(PFNGLBINDPROGRAMARBPROC, glBindProgramARB) \
    X(PFNGLPROGRAMSTRINGARBPROC, glProgramStringARB) \
    X(PFNGLPROGRAMLOCALPARAMETER4FVARBPROC, glProgramLocalParameter4fvARB)
#define DECLARE(type, name) static type p_##name;
GL_FUNCS(DECLARE)

static const int W = 64, H = 64;

// The colour at the centre of the back buffer, as 0xRRGGBB.
static unsigned read_center(void) {
    unsigned char px[4] = {0};
    glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    return (px[0] << 16) | (px[1] << 8) | px[2];
}

static int close_to(unsigned got, unsigned want) {
    for (int shift = 0; shift < 24; shift += 8) {
        int a = (got >> shift) & 0xff, b = (want >> shift) & 0xff;
        if (a - b > 3 || b - a > 3) return 0;
    }
    return 1;
}

static void check_color(const char *name, unsigned want) {
    char detail[64];
    unsigned got = read_center();
    snprintf(detail, sizeof detail, "got %06x expected %06x", got, want);
    check(name, close_to(got, want), detail);
}

static void reset(void) {
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glColor4f(1, 1, 1, 1);
    glDisable(GL_TEXTURE_2D);
    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    p_glBindBuffer(GL_ARRAY_BUFFER, 0);
    p_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    p_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    p_glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
}

// A quad covering the window, two triangles, in clip space (identity matrices).
static const GLfloat quad[] = { -1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1 };
static const GLfloat quad_uv[] = { 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
static const GLushort quad_indices[] = { 0, 1, 2, 0, 2, 3 };
static const GLfloat corners[] = { -1, -1, 1, -1, 1, 1, -1, 1 };

static void run_checks(void) {
    char detail[160];
    const char *version = (const char *)glGetString(GL_VERSION);
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    snprintf(detail, sizeof detail, "%s | %s", version ? version : "(null)", renderer ? renderer : "(null)");
    check("glGetString version and renderer", version && renderer, detail);
    check("glGetString extensions", extensions && strlen(extensions) > 10, NULL);
    glViewport(0, 0, W, H);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    reset();
    glClearColor(0.0f, 0.5f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    check_color("clear", 0x0080ff);

    // Fixed function, immediate mode, with a matrix.
    reset();
    glPushMatrix();
    glScalef(2, 2, 1);
    glColor3f(1, 0, 0);
    glBegin(GL_TRIANGLES);
    glVertex2f(-0.5f, -0.5f); glVertex2f(0.5f, -0.5f); glVertex2f(0, 0.5f);
    glEnd();
    glPopMatrix();
    check_color("glBegin triangle with glScalef", 0xff0000);

    // Vertex array from client memory.
    reset();
    glColor3f(0, 1, 0);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, quad);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    check_color("client vertex array", 0x00ff00);
    GLvoid *got_pointer = NULL;
    glGetPointerv(GL_VERTEX_ARRAY_POINTER, &got_pointer);
    check("glGetPointerv returns the client pointer", got_pointer == (GLvoid *)quad, NULL);

    // Vertex array from a buffer: the pointer argument is an offset.
    reset();
    GLuint vbo = 0, ibo = 0;
    p_glGenBuffers(1, &vbo);
    p_glBindBuffer(GL_ARRAY_BUFFER, vbo);
    p_glBufferData(GL_ARRAY_BUFFER, sizeof(GLfloat) * 4 + sizeof(quad), NULL, GL_STATIC_DRAW);
    GLfloat *mapped = p_glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
    check("glMapBuffer returns memory", mapped != NULL, NULL);
    if (mapped) {
        memset(mapped, 0, sizeof(GLfloat) * 4);  // 16 bytes of padding before the quad
        memcpy(mapped + 4, quad, sizeof(quad));
        check("glUnmapBuffer", p_glUnmapBuffer(GL_ARRAY_BUFFER) == GL_TRUE, NULL);
    }
    glColor3f(0, 0, 1);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, (const void *)(sizeof(GLfloat) * 4));
    glDrawArrays(GL_TRIANGLES, 0, 6);
    check_color("buffer vertex array at offset 16", 0x0000ff);
    glGetPointerv(GL_VERTEX_ARRAY_POINTER, &got_pointer);
    check("glGetPointerv returns the offset", got_pointer == (GLvoid *)(sizeof(GLfloat) * 4), NULL);

    // Indices from client memory, then from an element buffer (offset).
    reset();
    glColor3f(1, 1, 0);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, corners);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, quad_indices);
    check_color("glDrawElements, client indices", 0xffff00);
    reset();
    glColor3f(0, 1, 1);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, corners);
    p_glGenBuffers(1, &ibo);
    p_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    GLushort padded[8] = { 0, 0, 0, 1, 2, 0, 2, 3 };
    p_glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(padded), padded, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (const void *)(2 * sizeof(GLushort)));
    check_color("glDrawElements, element buffer offset", 0x00ffff);

    // Texture from client memory.
    reset();
    GLuint tex = 0;
    unsigned char texels[4 * 4 * 4];
    for (int i = 0; i < 16; i++) { texels[i * 4] = 0xff; texels[i * 4 + 1] = 0x80; texels[i * 4 + 2] = 0x00; texels[i * 4 + 3] = 0xff; }
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
    glEnable(GL_TEXTURE_2D);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, quad);
    glTexCoordPointer(2, GL_FLOAT, 0, quad_uv);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    check_color("texture uploaded from client memory", 0xff8000);

    // Texture from a pixel-unpack buffer: the pixels argument is an offset.
    reset();
    GLuint pbo = 0;
    p_glGenBuffers(1, &pbo);
    p_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
    p_glBufferData(GL_PIXEL_UNPACK_BUFFER, 64 + sizeof(texels), NULL, GL_STREAM_DRAW);
    unsigned char *upload = p_glMapBuffer(GL_PIXEL_UNPACK_BUFFER, GL_WRITE_ONLY);
    if (upload) {
        for (int i = 0; i < 16; i++) { upload[64 + i * 4] = 0x40; upload[64 + i * 4 + 1] = 0x00; upload[64 + i * 4 + 2] = 0xc0; upload[64 + i * 4 + 3] = 0xff; }
        p_glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    }
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, (const void *)64);
    p_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glEnable(GL_TEXTURE_2D);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, quad);
    glTexCoordPointer(2, GL_FLOAT, 0, quad_uv);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    check_color("texture uploaded from pixel-unpack buffer", 0x4000c0);

    // Read into a pixel-pack buffer at an offset, then map it.
    GLuint pack = 0;
    p_glGenBuffers(1, &pack);
    p_glBindBuffer(GL_PIXEL_PACK_BUFFER, pack);
    p_glBufferData(GL_PIXEL_PACK_BUFFER, 32, NULL, GL_STREAM_READ);
    glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, (void *)16);
    unsigned char *readback = p_glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
    unsigned packed = readback ? (readback[16] << 16) | (readback[17] << 8) | readback[18] : 0;
    if (readback) p_glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    p_glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    snprintf(detail, sizeof detail, "got %06x expected 4000c0", packed);
    check("glReadPixels into pixel-pack buffer offset", close_to(packed, 0x4000c0), detail);

    // ARB assembly programs, as Cg's arbvp1/arbfp1 profiles emit them.
    reset();
    if (strstr(extensions ? extensions : "", "GL_ARB_fragment_program") && p_glGenProgramsARB) {
        static const char vp[] = "!!ARBvp1.0\nMOV result.position, vertex.position;\nEND\n";
        static const char fp[] = "!!ARBfp1.0\nMOV result.color, program.local[0];\nEND\n";
        GLuint progs[2];
        p_glGenProgramsARB(2, progs);
        p_glBindProgramARB(GL_VERTEX_PROGRAM_ARB, progs[0]);
        p_glProgramStringARB(GL_VERTEX_PROGRAM_ARB, GL_PROGRAM_FORMAT_ASCII_ARB, sizeof(vp) - 1, vp);
        p_glBindProgramARB(GL_FRAGMENT_PROGRAM_ARB, progs[1]);
        p_glProgramStringARB(GL_FRAGMENT_PROGRAM_ARB, GL_PROGRAM_FORMAT_ASCII_ARB, sizeof(fp) - 1, fp);
        GLenum error = glGetError();
        static const GLfloat purple[4] = { 0.5f, 0, 0.5f, 1 };
        p_glProgramLocalParameter4fvARB(GL_FRAGMENT_PROGRAM_ARB, 0, purple);
        glEnable(GL_VERTEX_PROGRAM_ARB);
        glEnable(GL_FRAGMENT_PROGRAM_ARB);
        glEnableClientState(GL_VERTEX_ARRAY);
        glVertexPointer(2, GL_FLOAT, 0, quad);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glDisable(GL_VERTEX_PROGRAM_ARB);
        glDisable(GL_FRAGMENT_PROGRAM_ARB);
        snprintf(detail, sizeof detail, "program load error %#x", error);
        check("ARB programs load", error == GL_NO_ERROR, detail);
        check_color("ARB program draw", 0x800080);
    } else {
        check("GL_ARB_fragment_program supported", 0, NULL);
    }

    // GLSL, with the source passed as an array of strings.
    reset();
    static const char *vs_parts[] = { "#version 110\n", "void main() { gl_Position = gl_Vertex; }\n" };
    static const char *fs_parts[] = { "#version 110\nuniform vec4 tint;\n", "void main() { gl_FragColor = tint; }\n" };
    GLuint vs = p_glCreateShader(GL_VERTEX_SHADER), fs = p_glCreateShader(GL_FRAGMENT_SHADER);
    p_glShaderSource(vs, 2, vs_parts, NULL);
    p_glShaderSource(fs, 2, fs_parts, NULL);
    p_glCompileShader(vs);
    p_glCompileShader(fs);
    GLint compiled_vs = 0, compiled_fs = 0, linked = 0;
    p_glGetShaderiv(vs, GL_COMPILE_STATUS, &compiled_vs);
    p_glGetShaderiv(fs, GL_COMPILE_STATUS, &compiled_fs);
    if (!compiled_fs) {
        char log[256] = "";
        p_glGetShaderInfoLog(fs, sizeof log, NULL, log);
        printf("     fragment shader log: %s\n", log);
    }
    GLuint program = p_glCreateProgram();
    p_glAttachShader(program, vs);
    p_glAttachShader(program, fs);
    p_glLinkProgram(program);
    p_glGetProgramiv(program, GL_LINK_STATUS, &linked);
    check("GLSL compile and link", compiled_vs && compiled_fs && linked, NULL);
    p_glUseProgram(program);
    static const GLfloat teal[4] = { 0, 0.5f, 0.5f, 1 };
    p_glUniform4fv(p_glGetUniformLocation(program, "tint"), 1, teal);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, quad);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    p_glUseProgram(0);
    check_color("GLSL draw with uniform", 0x008080);

    GLenum error = glGetError();
    snprintf(detail, sizeof detail, "%#x", error);
    check("no GL error at the end", error == GL_NO_ERROR, detail);
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcA(hwnd, msg, wparam, lparam);
}

int main(void) {
#if defined(__i386__)
    printf("win-gl built for 32-bit x86\n");
#elif defined(__x86_64__)
    printf("win-gl built for x86-64\n");
#else
    printf("win-gl built for ARM64\n");
#endif
    WNDCLASSA wc = {0};
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "win-gl";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("win-gl", "win-gl", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, W + 16, H + 39,
                              NULL, NULL, wc.hInstance, NULL);
    RECT client;
    GetClientRect(hwnd, &client);
    HDC dc = GetDC(hwnd);
    PIXELFORMATDESCRIPTOR pfd = { sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
                                  PFD_TYPE_RGBA, 32, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 24, 8, 0,
                                  PFD_MAIN_PLANE, 0, 0, 0, 0 };
    int format = ChoosePixelFormat(dc, &pfd);
    check("ChoosePixelFormat", format > 0, NULL);
    PIXELFORMATDESCRIPTOR described = {0};
    check("DescribePixelFormat", DescribePixelFormat(dc, format, sizeof(described), &described) > 0, NULL);
    check("SetPixelFormat", SetPixelFormat(dc, format, &pfd), NULL);
    HGLRC context = wglCreateContext(dc);
    check("wglCreateContext", context != NULL, NULL);
    if (!context || !wglMakeCurrent(dc, context)) {
        printf("checks: %d, failures: %d\n", checks, failures + 1);
        return failures + 1;
    }
#define LOAD(type, name) p_##name = (type)wglGetProcAddress(#name);
    GL_FUNCS(LOAD)
    check("wglGetProcAddress for GL 1.5/2.0 functions", p_glGenBuffers && p_glShaderSource && p_glMapBuffer, NULL);
    if (p_glGenBuffers && p_glShaderSource && p_glMapBuffer) run_checks();
    SwapBuffers(dc);
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(context);
    printf("checks: %d, failures: %d\n", checks, failures);
    Sleep(3000);  // leave the last frame on screen for the screenshot
    return failures;
}
