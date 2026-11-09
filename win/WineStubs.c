// Hooks that Wine's unix libraries and Madeira's display driver expect from parts of
// Madeira that are not linked. Direct3D goes through DXMT (libdxmt_combined.a) and OpenGL
// through Vendored/WiniosGL.m.

#define STUB_VOID(name) void name(void) {}
#define STUB_ZERO(name) long name(void) { return 0; }

STUB_ZERO(MadeiraDonorPoolStart)
STUB_ZERO(winios_mouse_routing_enabled)
