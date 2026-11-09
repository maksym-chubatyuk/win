// Direct3D 11 benchmark suite: on the iPhone it measures the GPU through DXMT (Direct3D
// to Metal). It renders offscreen, waits for the GPU after each test, and reads a pixel
// back, so a test that drew nothing cannot report a score. Output lines start with
// "RESULT" so scripts can collect them.
//
// Two traps this avoids. Apple GPUs skip pixels a later opaque draw covers, so every
// full-screen test blends onto what is already there, which makes each layer count. And
// shader compilers fold arithmetic on constants, so the math test takes its values from a
// constant buffer at run time.

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <stdio.h>
#include <string.h>

#if defined(__x86_64__)
#define BUILD "x86-64"
#else
#define BUILD "arm64"
#endif

enum { WIDTH = 1920, HEIGHT = 1080 };

static ID3D11Device *device;
static ID3D11DeviceContext *context;
static ID3D11Texture2D *target, *staging;
static ID3D11RenderTargetView *target_view;
static int failures = 0;

static double now_seconds(void) {
    LARGE_INTEGER counter, frequency;
    QueryPerformanceCounter(&counter);
    QueryPerformanceFrequency(&frequency);
    return (double)counter.QuadPart / (double)frequency.QuadPart;
}

static void result(const char *name, double value, const char *unit) {
    printf("RESULT %-22s %12.2f %s\n", name, value, unit);
    fflush(stdout);
}

static void fail(const char *what) {
    printf("FAIL: %s\n", what);
    fflush(stdout);
    failures++;
}

/// Blocks until the GPU has finished everything submitted so far.
static void wait_for_gpu(void) {
    D3D11_QUERY_DESC desc = { D3D11_QUERY_EVENT, 0 };
    ID3D11Query *query;
    if (FAILED(ID3D11Device_CreateQuery(device, &desc, &query))) { fail("event query"); return; }
    ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)query);
    ID3D11DeviceContext_Flush(context);
    BOOL done = FALSE;
    while (ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)query, &done, sizeof(done), 0) == S_FALSE) {
        SwitchToThread();
    }
    ID3D11Query_Release(query);
}

/// The color at pixel (0, 0) of the render target, as 0xAABBGGRR.
static UINT read_pixel(void) {
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped))) {
        fail("map staging texture");
        return 0;
    }
    UINT pixel = *(UINT *)mapped.pData;
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    return pixel;
}

static ID3DBlob *compile(const char *source, const char *profile) {
    ID3DBlob *code = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(source, strlen(source), NULL, NULL, NULL, "main", profile, 0, 0, &code, &errors);
    if (FAILED(hr)) {
        printf("FAIL: compile %s: %s\n", profile, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "?");
        failures++;
        return NULL;
    }
    return code;
}

static ID3D11VertexShader *vertex_shader(const char *source) {
    ID3DBlob *code = compile(source, "vs_5_0");
    ID3D11VertexShader *shader = NULL;
    if (code) ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), NULL, &shader);
    return shader;
}

static ID3D11PixelShader *pixel_shader(const char *source) {
    ID3DBlob *code = compile(source, "ps_5_0");
    ID3D11PixelShader *shader = NULL;
    if (code) ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), NULL, &shader);
    return shader;
}

// A triangle covering the whole target, from the vertex index alone.
static const char *fullscreen_vs =
    "float4 main(uint id : SV_VertexID) : SV_Position {"
    "  float2 p = float2((id << 1) & 2, id & 2);"
    "  return float4(p * float2(2, -2) + float2(-1, 1), 0, 1); }";

// Many small triangles in a grid, about 2 pixels each, for geometry throughput.
static const char *small_triangles_vs =
    "cbuffer offset : register(b0) { float4 shift; };"
    "float4 main(uint id : SV_VertexID) : SV_Position {"
    "  uint tri = id / 3, corner = id % 3;"
    "  float2 cell = float2(tri % 960, (tri / 960) % 540) / float2(480, 270) - 1;"
    "  float2 p = float2(cell.x, -cell.y) + float2(corner == 1, -(float)(corner == 2)) * 0.002 + shift.xy;"
    "  return float4(p, 0, 1); }";

static const char *solid_ps =
    "float4 main() : SV_Target { return float4(0.2, 0.4, 0.6, 1.0); }";

// 128 multiply-adds on four lanes per pixel: 1024 floating point operations. The factors
// come from a constant buffer and the lanes rotate, so nothing can be folded away.
static const char *math_ps =
    "cbuffer factors : register(b0) { float4 a; float4 b; };"
    "float4 main(float4 pos : SV_Position) : SV_Target {"
    "  float4 v = pos.xyxy * 0.001;"
    "  [unroll] for (int i = 0; i < 128; i++) v = v.yzwx * a + b;"
    "  return saturate(v * 10); }";

// 16 bilinear samples from a 2048x2048 texture per pixel.
static const char *texture_ps =
    "Texture2D t : register(t0); SamplerState s : register(s0);"
    "float4 main(float4 pos : SV_Position) : SV_Target {"
    "  float2 uv = pos.xy / float2(1920, 1080); float4 c = 0;"
    "  [unroll] for (int i = 0; i < 16; i++) c += t.Sample(s, uv + float2(i * 0.013, i * 0.007));"
    "  return c / 16; }";

static int setup(void) {
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL level;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 1, D3D11_SDK_VERSION,
                                   &device, &level, &context);
    if (FAILED(hr)) { printf("FAIL: D3D11CreateDevice 0x%08lx\n", hr); return 0; }

    IDXGIDevice *dxgi_device;
    IDXGIAdapter *adapter;
    DXGI_ADAPTER_DESC adapter_desc;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_device, &adapter)) &&
        SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adapter_desc))) {
        printf("adapter: %ls, %llu MB video memory\n", adapter_desc.Description,
               (unsigned long long)(adapter_desc.DedicatedVideoMemory >> 20));
    }

    D3D11_TEXTURE2D_DESC desc = { WIDTH, HEIGHT, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 },
                                  D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0, 0 };
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &target);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &target_view);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);

    D3D11_VIEWPORT viewport = { 0, 0, WIDTH, HEIGHT, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
    ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target_view, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    // No culling, so winding never decides whether a test draws.
    D3D11_RASTERIZER_DESC raster = { D3D11_FILL_SOLID, D3D11_CULL_NONE, FALSE, 0, 0, 0, TRUE, FALSE, FALSE, FALSE };
    ID3D11RasterizerState *raster_state;
    ID3D11Device_CreateRasterizerState(device, &raster, &raster_state);
    ID3D11DeviceContext_RSSetState(context, raster_state);
    return 1;
}

/// Adds each draw onto the target, so every pixel of every layer is shaded.
static void additive_blending(void) {
    D3D11_BLEND_DESC blend = { 0 };
    blend.RenderTarget[0] = (D3D11_RENDER_TARGET_BLEND_DESC){ TRUE, D3D11_BLEND_ONE, D3D11_BLEND_ONE,
        D3D11_BLEND_OP_ADD, D3D11_BLEND_ONE, D3D11_BLEND_ONE, D3D11_BLEND_OP_ADD, D3D11_COLOR_WRITE_ENABLE_ALL };
    ID3D11BlendState *state;
    ID3D11Device_CreateBlendState(device, &blend, &state);
    ID3D11DeviceContext_OMSetBlendState(context, state, NULL, 0xffffffff);
}

static void clear(void) {
    float black[4] = { 0, 0, 0, 0 };
    ID3D11DeviceContext_ClearRenderTargetView(context, target_view, black);
}

/// Draws `passes` full-screen triangles and returns the seconds the GPU took.
static double timed_fullscreen(int passes) {
    clear();
    ID3D11DeviceContext_Draw(context, 3, 0);   // warm-up: the first draw builds pipelines
    wait_for_gpu();
    double start = now_seconds();
    for (int i = 0; i < passes; i++) ID3D11DeviceContext_Draw(context, 3, 0);
    wait_for_gpu();
    return now_seconds() - start;
}

static void test_fill(ID3D11VertexShader *vs) {
    ID3D11PixelShader *ps = pixel_shader(solid_ps);
    if (!vs || !ps) return;
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);

    // Opaque fill is not measured: the GPU skips the layers it covers.
    int passes = 300;
    D3D11_BLEND_DESC blend = { 0 };
    blend.RenderTarget[0] = (D3D11_RENDER_TARGET_BLEND_DESC){ TRUE, D3D11_BLEND_SRC_ALPHA, D3D11_BLEND_INV_SRC_ALPHA,
        D3D11_BLEND_OP_ADD, D3D11_BLEND_ONE, D3D11_BLEND_ZERO, D3D11_BLEND_OP_ADD, D3D11_COLOR_WRITE_ENABLE_ALL };
    ID3D11BlendState *blend_state;
    ID3D11Device_CreateBlendState(device, &blend, &blend_state);
    ID3D11DeviceContext_OMSetBlendState(context, blend_state, NULL, 0xffffffff);
    double seconds = timed_fullscreen(passes);
    if ((read_pixel() & 0xff) == 0) fail("blend pixel");
    result("blend_fill_rate", (double)passes * WIDTH * HEIGHT / seconds / 1e9, "G pixels/s");
    ID3D11DeviceContext_OMSetBlendState(context, NULL, NULL, 0xffffffff);
}

static void test_math(ID3D11VertexShader *vs) {
    ID3D11PixelShader *ps = pixel_shader(math_ps);
    if (!vs || !ps) return;
    float factors[8] = { 1.0001f, 0.9999f, 1.0002f, 0.9998f, 0.0001f, 0.0002f, 0.0003f, 0.0004f };
    D3D11_BUFFER_DESC desc = { sizeof(factors), D3D11_USAGE_DEFAULT, D3D11_BIND_CONSTANT_BUFFER, 0, 0, 0 };
    D3D11_SUBRESOURCE_DATA data = { factors, 0, 0 };
    ID3D11Buffer *buffer;
    ID3D11Device_CreateBuffer(device, &desc, &data, &buffer);
    ID3D11DeviceContext_PSSetConstantBuffers(context, 0, 1, &buffer);
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
    additive_blending();
    int passes = 60;
    double seconds = timed_fullscreen(passes);
    if (read_pixel() == 0) fail("math pixel");
    result("shader_math", (double)passes * WIDTH * HEIGHT * 1024.0 / seconds / 1e9, "GFLOPS");
}

static void test_texture(ID3D11VertexShader *vs) {
    ID3D11PixelShader *ps = pixel_shader(texture_ps);
    if (!vs || !ps) return;
    enum { SIZE = 2048 };
    static UINT texels[SIZE * SIZE];
    for (int i = 0; i < SIZE * SIZE; i++) texels[i] = 0xff000000u | (UINT)(i * 2654435761u >> 8);
    D3D11_TEXTURE2D_DESC desc = { SIZE, SIZE, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 },
                                  D3D11_USAGE_IMMUTABLE, D3D11_BIND_SHADER_RESOURCE, 0, 0 };
    D3D11_SUBRESOURCE_DATA data = { texels, SIZE * 4, 0 };
    ID3D11Texture2D *texture;
    ID3D11ShaderResourceView *view;
    ID3D11Device_CreateTexture2D(device, &desc, &data, &texture);
    ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)texture, NULL, &view);
    D3D11_SAMPLER_DESC sampler_desc = { D3D11_FILTER_MIN_MAG_MIP_LINEAR, D3D11_TEXTURE_ADDRESS_WRAP,
        D3D11_TEXTURE_ADDRESS_WRAP, D3D11_TEXTURE_ADDRESS_WRAP, 0, 1, D3D11_COMPARISON_NEVER, { 0 }, 0, D3D11_FLOAT32_MAX };
    ID3D11SamplerState *sampler;
    ID3D11Device_CreateSamplerState(device, &sampler_desc, &sampler);

    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
    ID3D11DeviceContext_PSSetShaderResources(context, 0, 1, &view);
    ID3D11DeviceContext_PSSetSamplers(context, 0, 1, &sampler);
    additive_blending();
    int passes = 60;
    double seconds = timed_fullscreen(passes);
    if (read_pixel() == 0) fail("texture pixel");
    // Neighbouring pixels sample neighbouring texels, so this is filtering throughput with
    // the texture cache working, as in most real rendering.
    result("texture_samples", (double)passes * WIDTH * HEIGHT * 16.0 / seconds / 1e9, "G samples/s");
}

static ID3D11Buffer *make_constant_buffer(void) {
    D3D11_BUFFER_DESC desc = { 16, D3D11_USAGE_DEFAULT, D3D11_BIND_CONSTANT_BUFFER, 0, 0, 0 };
    float zero[4] = { 0 };
    D3D11_SUBRESOURCE_DATA data = { zero, 0, 0 };
    ID3D11Buffer *buffer;
    ID3D11Device_CreateBuffer(device, &desc, &data, &buffer);
    return buffer;
}

static void test_geometry(void) {
    ID3D11VertexShader *vs = vertex_shader(small_triangles_vs);
    ID3D11PixelShader *ps = pixel_shader(solid_ps);
    if (!vs || !ps) return;
    ID3D11Buffer *offsets = make_constant_buffer();
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(context, 0, 1, &offsets);
    ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
    ID3D11DeviceContext_OMSetBlendState(context, NULL, NULL, 0xffffffff);

    UINT triangles = 960 * 540;   // about half a million per draw
    clear();
    ID3D11DeviceContext_Draw(context, 3 * triangles, 0);
    wait_for_gpu();
    int passes = 20;
    double start = now_seconds();
    for (int i = 0; i < passes; i++) ID3D11DeviceContext_Draw(context, 3 * triangles, 0);
    wait_for_gpu();
    double seconds = now_seconds() - start;
    if (read_pixel() == 0) fail("geometry pixel");
    result("triangles", (double)passes * triangles / seconds / 1e6, "M triangles/s");

    // Draw calls: many small draws, each after a constant buffer update. This measures the
    // CPU side of every draw, where the translation to Metal adds work.
    int draws = 20000;
    wait_for_gpu();
    start = now_seconds();
    for (int i = 0; i < draws; i++) {
        float shift[4] = { (float)(i % 7) * 0.01f, 0, 0, 0 };
        ID3D11DeviceContext_UpdateSubresource(context, (ID3D11Resource *)offsets, 0, NULL, shift, 0, 0);
        ID3D11DeviceContext_Draw(context, 3, 0);
    }
    wait_for_gpu();
    seconds = now_seconds() - start;
    result("draw_calls", draws / seconds / 1000.0, "K draws/s");
}

int main(void) {
    printf("win-gpubench built for %s, %dx%d offscreen\n", BUILD, WIDTH, HEIGHT);
    fflush(stdout);
    if (!setup()) return 1;
    ID3D11VertexShader *vs = vertex_shader(fullscreen_vs);
    test_fill(vs);
    test_math(vs);
    test_texture(vs);
    test_geometry();
    printf("failures: %d\n", failures);
    fflush(stdout);
    return failures == 0 ? 0 : 1;
}
