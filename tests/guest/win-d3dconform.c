// Direct3D 11 conformance checks for the features game lighting and shadows depend on,
// each compared with the value the D3D11 specification requires. On the iPhone this tests
// DXMT's translation to Metal, so a wrong result points at the translation.
//
// Every check is one pixel of a 32-bit float render target: the pixel shader picks the
// check by pixel index and writes its result, which is read back and compared here.
// Inputs come from a constant buffer at run time, so the compiler cannot fold them.

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11_1.h>
#include <d3dcompiler.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static ID3D11Device *device;
static ID3D11DeviceContext *context;
static int failures = 0, checks = 0;

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

static ID3D11Buffer *constant_buffer(const void *data, UINT size) {
    D3D11_BUFFER_DESC desc = { (size + 15) & ~15u, D3D11_USAGE_DEFAULT, D3D11_BIND_CONSTANT_BUFFER, 0, 0, 0 };
    D3D11_SUBRESOURCE_DATA init = { data, 0, 0 };
    ID3D11Buffer *buffer = NULL;
    ID3D11Device_CreateBuffer(device, &desc, &init, &buffer);
    return buffer;
}

// ---------------------------------------------------------------------------------------
// Depth textures: 4x4, cleared to 1, with the left two columns drawn at depth 0.25.

static const char *half_quad_vs =
    "cbuffer c : register(b0) { float4 depth; };"
    "float4 main(uint id : SV_VertexID) : SV_Position {"
    "  const float2 corners[6] = { float2(-1, 1), float2(0, 1), float2(-1, -1),"
    "                              float2(0, 1), float2(0, -1), float2(-1, -1) };"
    "  return float4(corners[id], depth.x, 1); }";     // the left half

typedef struct {
    const char *name;
    DXGI_FORMAT texture, dsv, srv;
} depth_format;

static ID3D11ShaderResourceView *make_depth(depth_format format, int array) {
    D3D11_TEXTURE2D_DESC desc = { 4, 4, 1, array ? 2 : 1, format.texture, { 1, 0 }, D3D11_USAGE_DEFAULT,
                                  D3D11_BIND_DEPTH_STENCIL | D3D11_BIND_SHADER_RESOURCE, 0, 0 };
    ID3D11Texture2D *texture;
    if (FAILED(ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture))) {
        printf("FAIL: create depth texture %s\n", format.name);
        failures++;
        return NULL;
    }
    D3D11_DEPTH_STENCIL_VIEW_DESC dsv_desc = { 0 };
    dsv_desc.Format = format.dsv;
    if (array) {
        dsv_desc.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2DARRAY;
        dsv_desc.Texture2DArray.FirstArraySlice = 1;
        dsv_desc.Texture2DArray.ArraySize = 1;
    } else {
        dsv_desc.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2D;
    }
    ID3D11DepthStencilView *dsv;
    ID3D11Device_CreateDepthStencilView(device, (ID3D11Resource *)texture, &dsv_desc, &dsv);

    // Slice 0 of an array stays at 1 everywhere; the drawing goes to slice 1.
    if (array) {
        D3D11_DEPTH_STENCIL_VIEW_DESC whole = dsv_desc;
        whole.Texture2DArray.FirstArraySlice = 0;
        whole.Texture2DArray.ArraySize = 2;
        ID3D11DepthStencilView *all;
        ID3D11Device_CreateDepthStencilView(device, (ID3D11Resource *)texture, &whole, &all);
        ID3D11DeviceContext_ClearDepthStencilView(context, all, D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 1.0f, 0);
    }
    ID3D11DeviceContext_ClearDepthStencilView(context, dsv, D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 1.0f, 0);

    static ID3D11VertexShader *vs;
    static ID3D11DepthStencilState *always;
    if (!vs) {
        vs = vertex_shader(half_quad_vs);
        D3D11_DEPTH_STENCIL_DESC ds = { TRUE, D3D11_DEPTH_WRITE_MASK_ALL, D3D11_COMPARISON_ALWAYS, FALSE, 0, 0,
            { D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_ALWAYS },
            { D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_ALWAYS } };
        ID3D11Device_CreateDepthStencilState(device, &ds, &always);
    }
    float depth[4] = { 0.25f, 0, 0, 0 };
    ID3D11Buffer *cb = constant_buffer(depth, sizeof(depth));
    D3D11_VIEWPORT viewport = { 0, 0, 4, 4, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
    ID3D11DeviceContext_OMSetRenderTargets(context, 0, NULL, dsv);
    ID3D11DeviceContext_OMSetDepthStencilState(context, always, 0);
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(context, 0, 1, &cb);
    ID3D11DeviceContext_PSSetShader(context, NULL, NULL, 0);
    ID3D11DeviceContext_Draw(context, 6, 0);
    ID3D11DeviceContext_OMSetRenderTargets(context, 0, NULL, NULL);
    ID3D11DeviceContext_OMSetDepthStencilState(context, NULL, 0);

    D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = { 0 };
    srv_desc.Format = format.srv;
    if (array) {
        srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
        srv_desc.Texture2DArray.MipLevels = 1;
        srv_desc.Texture2DArray.ArraySize = 2;
    } else {
        srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
        srv_desc.Texture2D.MipLevels = 1;
    }
    ID3D11ShaderResourceView *srv = NULL;
    if (FAILED(ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)texture, &srv_desc, &srv))) {
        printf("FAIL: depth SRV %s\n", format.name);
        failures++;
    }
    return srv;
}

// ---------------------------------------------------------------------------------------
// The checks: one pixel each.

typedef struct {
    const char *name;
    float expected;   // NAN: the result must be a NaN
    float tolerance;
} check_t;

#define CHECK_COUNT 53
static const check_t expected[CHECK_COUNT] = {
    // Depth comparison, 4x4 depth texture: columns 0-1 hold 0.25, columns 2-3 hold 1.0.
    // Reference 0.5, LESS_EQUAL: a texel passes when 0.5 <= its depth.
    { "cmp linear, between columns 1 and 2",   0.5f, 0.02f },   // 0
    { "cmp linear, inside the 0.25 half",      0.0f, 0.02f },   // 1
    { "cmp linear, inside the 1.0 half",       1.0f, 0.02f },   // 2
    { "cmp linear, quarter texel",             0.25f, 0.03f },  // 3
    { "cmp border right (border depth 1)",     1.0f, 0.02f },   // 4
    { "cmp border left (border depth 1)",      1.0f, 0.02f },   // 5
    { "cmp point filter, left texel",          0.0f, 0.0f },    // 6
    { "cmp point filter, right texel",         1.0f, 0.0f },    // 7
    { "gather cmp, sum of four",               2.0f, 0.0f },    // 8
    { "cmp array slice 1",                     0.5f, 0.02f },   // 9
    { "cmp array slice 0 (all 1.0)",           1.0f, 0.02f },   // 10
    { "cmp D16 linear",                        0.5f, 0.02f },   // 11
    { "cmp D24S8 linear",                      0.5f, 0.02f },   // 12
    { "cmp with derivatives (SampleCmp)",      0.5f, 0.02f },   // 13
    { "raw depth load, left texel",            0.25f, 0.001f }, // 14
    { "raw depth load, right texel row 2",     1.0f, 0.001f },  // 15
    { "raw depth sample linear midpoint",      0.625f, 0.01f }, // 16
    { "cmp GREATER, between columns",          0.5f, 0.02f },   // 17
    { "cmp clamp address, right edge",         1.0f, 0.02f },   // 18
    { "cmp D16, reference 1.5 clamped to 1",   0.5f, 0.02f },   // 19
    // Floating point rules (D3D11 functional spec, section 3.1).
    { "saturate(NaN) is 0",                    0.0f, 0.0f },    // 20
    { "max(NaN, 0) is 0",                      0.0f, 0.0f },    // 21
    { "min(NaN, 1) is 1",                      1.0f, 0.0f },    // 22
    { "rsqrt(0) is +inf",                      1.0f, 0.0f },    // 23 (isinf)
    { "0 * inf is NaN",                        1.0f, 0.0f },    // 24 (isnan)
    { "normalize(0) is NaN",                   1.0f, 0.0f },    // 25 (isnan)
    { "(int)NaN is 0",                         0.0f, 0.0f },    // 26
    { "(uint)-1.0 is 0",                       0.0f, 0.0f },    // 27
    { "(int)1e20 is INT_MAX",                  1.0f, 0.0f },    // 28
    { "sqrt(-1) is NaN",                       1.0f, 0.0f },    // 29
    { "log2(0) is -inf",                       1.0f, 0.0f },    // 30
    { "NaN < 1 is false",                      0.0f, 0.0f },    // 31
    { "NaN != NaN is true",                    1.0f, 0.0f },    // 32
    { "1 / 0 is +inf",                         1.0f, 0.0f },    // 33
    { "x / x with x=0 is NaN",                 1.0f, 0.0f },    // 34
    { "pow(0, 0) (spec: NaN or 1, finite ok)", -1.0f, 0.0f },   // 35 informational
    { "exp2(-200) is 0 (denormal flush ok)",   0.0f, 0.0f },    // 36
    { "frac(-0.25) is 0.75",                   0.75f, 0.0001f },// 37
    { "round_ne(2.5) is 2",                    2.0f, 0.0f },    // 38
    { "f32tof16(65520) (31744 = +inf half)",   -1.0f, 0.0f },
    // Constant buffers: reads past the end of what is bound must return 0.
    { "cb read inside a 16-byte buffer",       1.0f, 0.0f },    // 40
    { "cb read past a 16-byte buffer is 0",    0.0f, 0.0f },    // 41
    { "cb1 offset view, first constant",       2.0f, 0.0f },    // 42
    { "cb1 offset view, past NumConstants",    0.0f, 0.0f },    // 43
    // A 6x6 grid of comparison taps, as soft shadows take them, scaled by a radius from a
    // constant buffer. Expected values worked out from the texel layout by hand.
    { "36 taps across the depth edge",         0.41667f, 0.02f }, // 44
    { "36 taps inside the 1.0 half",           1.0f, 0.02f },   // 45
    { "unbound cb slot 5 reads 0",             0.0f, 0.0f },    // 46
    { "cb slot 13 bound with 3.0",             3.0f, 0.0f },    // 47
    { "cb slot 9 bound after slot 13",         4.0f, 0.0f },    // 48
    // The tail of Unigine's soft shadow: pow((36 - sum) / 36, 2.2) where every tap passed.
    { "pow((36 - 36 taps) / 36, 2.2) is 0",    0.0f, 0.0f },    // 49
    { "exp2(-inf) is 0",                       0.0f, 0.0f },    // 50
    { "36 taps of 1.0 sum to exactly 36",      36.0f, 0.0f },   // 51
    { "single tap of 1.0 is exactly 1",        1.0f, 0.0f },    // 52// 39
};

static const char *checks_ps =
    "cbuffer v : register(b0) { float zero; float one; float minus_one; float inf;"
    "                           float nan; float big; float half_; float quarter; };"
    "cbuffer small : register(b1) { float4 small0; float4 small1; float4 small2; };"
    "cbuffer view : register(b2) { float4 view[20]; };"
    "cbuffer unbound : register(b5) { float4 nothing; };"
    "cbuffer high : register(b13) { float4 high13; };"
    "cbuffer nine : register(b9) { float4 nine9; };"
    "Texture2D<float> d32 : register(t0);"
    "Texture2DArray<float> d32_array : register(t1);"
    "Texture2D<float> d16 : register(t2);"
    "Texture2D<float> d24 : register(t3);"
    "SamplerComparisonState cmp_border : register(s0);"
    "SamplerComparisonState cmp_point : register(s1);"
    "SamplerComparisonState cmp_greater : register(s2);"
    "SamplerComparisonState cmp_clamp : register(s3);"
    "SamplerState linear_clamp : register(s4);"
    "float4 main(float4 pos : SV_Position) : SV_Target {"
    "  uint i = (uint)pos.x; float r = -1;"
    "  float ref = half_;"                                    // 0.5
    "  float y = 0.5;"
    "  switch (i) {"
    "  case 0: r = d32.SampleCmpLevelZero(cmp_border, float2(0.5, y), ref); break;"
    "  case 1: r = d32.SampleCmpLevelZero(cmp_border, float2(0.25, y), ref); break;"
    "  case 2: r = d32.SampleCmpLevelZero(cmp_border, float2(0.75, y), ref); break;"
    "  case 3: r = d32.SampleCmpLevelZero(cmp_border, float2(0.375 + 0.0625, y), ref); break;"
    "  case 4: r = d32.SampleCmpLevelZero(cmp_border, float2(1.5, y), ref); break;"
    "  case 5: r = d32.SampleCmpLevelZero(cmp_border, float2(-0.5, y), ref); break;"
    "  case 6: r = d32.SampleCmpLevelZero(cmp_point, float2(0.45, y), ref); break;"
    "  case 7: r = d32.SampleCmpLevelZero(cmp_point, float2(0.55, y), ref); break;"
    "  case 8: { float4 g = d32.GatherCmp(cmp_border, float2(0.5, y), ref); r = g.x + g.y + g.z + g.w; } break;"
    "  case 9: r = d32_array.SampleCmpLevelZero(cmp_border, float3(0.5, y, 1), ref); break;"
    "  case 10: r = d32_array.SampleCmpLevelZero(cmp_border, float3(0.5, y, 0), ref); break;"
    "  case 11: r = d16.SampleCmpLevelZero(cmp_border, float2(0.5, y), ref); break;"
    "  case 12: r = d24.SampleCmpLevelZero(cmp_border, float2(0.5, y), ref); break;"
    "  case 13: r = d32.SampleCmp(cmp_border, float2(0.5, y) + pos.y * 0.0001 - 0.00005, ref); break;"
    "  case 14: r = d32.Load(int3(1, 1, 0)); break;"
    "  case 15: r = d32.Load(int3(2, 2, 0)) + d32.Load(int3(1, 2, 0)) - 0.25; break;"
    "  case 16: r = d32.SampleLevel(linear_clamp, float2(0.5, y), 0); break;"
    "  case 17: r = d32.SampleCmpLevelZero(cmp_greater, float2(0.5, y), ref); break;"
    "  case 18: r = d32.SampleCmpLevelZero(cmp_clamp, float2(1.5, y), ref); break;"
    "  case 19: r = d16.SampleCmpLevelZero(cmp_border, float2(0.5, y), 3 * ref); break;"
    "  case 20: r = saturate(nan); break;"
    "  case 21: r = max(nan, zero); break;"
    "  case 22: r = min(nan, one); break;"
    "  case 23: { float v = rsqrt(zero); r = (v == inf) ? 1 : 0; } break;"
    "  case 24: { float v = zero * inf; r = (v != v) ? 1 : 0; } break;"
    "  case 25: { float3 v = normalize(float3(zero, zero, zero)); r = (v.x != v.x) ? 1 : 0; } break;"
    "  case 26: r = (float)(int)nan; break;"
    "  case 27: r = (float)(uint)minus_one; break;"
    "  case 28: r = ((int)big == 2147483647) ? 1 : 0; break;"
    "  case 29: { float v = sqrt(minus_one); r = (v != v) ? 1 : 0; } break;"
    "  case 30: r = (log2(zero) == -inf) ? 1 : 0; break;"
    "  case 31: r = (nan < one) ? 1 : 0; break;"
    "  case 32: r = (nan != nan) ? 1 : 0; break;"
    "  case 33: r = (one / zero == inf) ? 1 : 0; break;"
    "  case 34: { float v = zero / zero; r = (v != v) ? 1 : 0; } break;"
    "  case 35: r = pow(zero, zero); break;"
    "  case 36: r = exp2(-200 * one); break;"
    "  case 37: r = frac(-quarter); break;"
    "  case 38: r = round(2.5 * one); break;"
    "  case 39: r = (float)f32tof16(65520 * one); break;"
    "  case 40: r = small0.x; break;"
    "  case 41: r = small2.x; break;"
    "  case 42: r = view[0].x; break;"
    "  case 43: r = view[18 + (int)zero].x; break;"
    "  case 44: case 45: {"
    "    float2 c = i == 44 ? float2(0.5, y) : float2(0.75, y); float radius = i == 44 ? 0.4 * one : 0.1 * one;"
    "    float sum = 0;"
    "    [unroll] for (int a = 0; a < 6; a++) [unroll] for (int b = 0; b < 6; b++)"
    "      sum += d32.SampleCmpLevelZero(cmp_border, c + radius * (float2(a, b) / 6.0 - 0.5), ref);"
    "    r = sum / 36; } break;"
    "  case 49: case 51: {"
    "    float sum = 0;"
    "    [unroll] for (int a = 0; a < 6; a++) [unroll] for (int b = 0; b < 6; b++)"
    "      sum += d32.SampleCmpLevelZero(cmp_border, float2(0.75, y) + 0.1 * one * (float2(a, b) / 6.0 - 0.5), ref);"
    "    r = i == 51 ? sum : exp2(log2((36 - sum) * 0.027778) * 2.2); } break;"
    "  case 50: r = exp2(-inf); break;"
    "  case 52: r = d32.SampleCmpLevelZero(cmp_border, float2(0.7 + 0.01 * one, y), ref); break;"
    "  case 46: r = nothing.x; break;"
    "  case 47: r = high13.x; break;"
    "  case 48: r = nine9.x; break;"
    "  }"
    "  return float4(r, 0, 0, 1); }";

static const char *fullscreen_vs =
    "float4 main(uint id : SV_VertexID) : SV_Position {"
    "  float2 p = float2((id << 1) & 2, id & 2);"
    "  return float4(p * float2(2, -2) + float2(-1, 1), 0, 1); }";

static ID3D11SamplerState *sampler(D3D11_FILTER filter, D3D11_TEXTURE_ADDRESS_MODE address, D3D11_COMPARISON_FUNC func) {
    D3D11_SAMPLER_DESC desc = { filter, address, address, address, 0, 1, func, { 1, 1, 1, 1 }, 0, D3D11_FLOAT32_MAX };
    ID3D11SamplerState *state = NULL;
    if (FAILED(ID3D11Device_CreateSamplerState(device, &desc, &state))) { printf("FAIL: sampler\n"); failures++; }
    return state;
}

static void run_checks(void) {
    depth_format d32 = { "D32", DXGI_FORMAT_R32_TYPELESS, DXGI_FORMAT_D32_FLOAT, DXGI_FORMAT_R32_FLOAT };
    depth_format d16 = { "D16", DXGI_FORMAT_R16_TYPELESS, DXGI_FORMAT_D16_UNORM, DXGI_FORMAT_R16_UNORM };
    depth_format d24 = { "D24S8", DXGI_FORMAT_R24G8_TYPELESS, DXGI_FORMAT_D24_UNORM_S8_UINT, DXGI_FORMAT_R24_UNORM_X8_TYPELESS };
    ID3D11ShaderResourceView *views[4] = { make_depth(d32, 0), make_depth(d32, 1), make_depth(d16, 0), make_depth(d24, 0) };

    ID3D11SamplerState *samplers[5] = {
        sampler(D3D11_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT, D3D11_TEXTURE_ADDRESS_BORDER, D3D11_COMPARISON_LESS_EQUAL),
        sampler(D3D11_FILTER_COMPARISON_MIN_MAG_MIP_POINT, D3D11_TEXTURE_ADDRESS_BORDER, D3D11_COMPARISON_LESS_EQUAL),
        sampler(D3D11_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT, D3D11_TEXTURE_ADDRESS_BORDER, D3D11_COMPARISON_GREATER),
        sampler(D3D11_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT, D3D11_TEXTURE_ADDRESS_CLAMP, D3D11_COMPARISON_LESS_EQUAL),
        sampler(D3D11_FILTER_MIN_MAG_MIP_LINEAR, D3D11_TEXTURE_ADDRESS_CLAMP, D3D11_COMPARISON_NEVER),
    };

    UINT nan_bits = 0x7fc00000;
    float values[8] = { 0, 1, -1, INFINITY, 0, 1e20f, 0.5f, 0.25f };
    memcpy(&values[4], &nan_bits, 4);
    ID3D11Buffer *cb = constant_buffer(values, sizeof(values));

    // A 16-byte buffer behind a 48-byte declaration: the rest must read as 0.
    float ones[4] = { 1, 1, 1, 1 };
    ID3D11Buffer *small = constant_buffer(ones, sizeof(ones));
    // A 64-constant buffer seen through a 16-constant window starting at constant 16:
    // constant 16 holds 2.0; constants past the window hold 9.0 but must read as 0.
    static float big[64 * 4];
    for (int i = 0; i < 64 * 4; i++) big[i] = i < 16 * 4 ? 5.0f : i < 18 * 4 ? 2.0f : 9.0f;
    ID3D11Buffer *viewed = constant_buffer(big, sizeof(big));
    ID3D11DeviceContext1 *context1 = NULL;
    ID3D11DeviceContext_QueryInterface(context, &IID_ID3D11DeviceContext1, (void **)&context1);

    D3D11_TEXTURE2D_DESC desc = { CHECK_COUNT, 1, 1, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, { 1, 0 },
                                  D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0, 0 };
    ID3D11Texture2D *target, *staging;
    ID3D11RenderTargetView *rtv;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &target);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &rtv);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);

    ID3D11VertexShader *vs = vertex_shader(fullscreen_vs);
    ID3D11PixelShader *ps = pixel_shader(checks_ps);
    if (!vs || !ps) return;
    D3D11_VIEWPORT viewport = { 0, 0, CHECK_COUNT, 1, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
    ID3D11DeviceContext_OMSetRenderTargets(context, 1, &rtv, NULL);
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(context, 0, 1, &cb);
    ID3D11DeviceContext_PSSetConstantBuffers(context, 1, 1, &small);
    float three[4] = { 3, 3, 3, 3 }, four[4] = { 4, 4, 4, 4 };
    ID3D11Buffer *b13 = constant_buffer(three, sizeof(three)), *b9 = constant_buffer(four, sizeof(four));
    ID3D11DeviceContext_PSSetConstantBuffers(context, 13, 1, &b13);
    ID3D11DeviceContext_PSSetConstantBuffers(context, 9, 1, &b9);
    if (context1) {
        // Offsets and counts are in constants and must be multiples of 16.
        UINT first = 16, count = 16;
        ID3D11DeviceContext1_PSSetConstantBuffers1(context1, 2, 1, &viewed, &first, &count);
    } else {
        printf("no ID3D11DeviceContext1\n");
    }
    ID3D11DeviceContext_PSSetShaderResources(context, 0, 4, views);
    ID3D11DeviceContext_PSSetSamplers(context, 0, 5, samplers);
    float clear[4] = { -7, -7, -7, -7 };
    ID3D11DeviceContext_ClearRenderTargetView(context, rtv, clear);
    ID3D11DeviceContext_Draw(context, 3, 0);

    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped))) {
        printf("FAIL: map\n");
        failures++;
        return;
    }
    const float *pixels = mapped.pData;
    for (int i = 0; i < CHECK_COUNT; i++) {
        float got = pixels[i * 4];
        const check_t *c = &expected[i];
        int ok;
        if (c->expected == -1.0f) ok = 1;   // informational
        else if (isnan(got)) ok = 0;
        else ok = fabsf(got - c->expected) <= c->tolerance;
        checks++;
        if (!ok) failures++;
        printf("%s %2d %-40s got %-12g expected %g\n", ok ? "ok  " : "FAIL", i, c->name, got, c->expected);
    }
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
}

// ---------------------------------------------------------------------------------------
// Render target formats: a known color written, blended and read back.

static void check_format(DXGI_FORMAT format, const char *name, const float color[4], int components) {
    D3D11_TEXTURE2D_DESC desc = { 4, 4, 1, 1, format, { 1, 0 }, D3D11_USAGE_DEFAULT,
                                  D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0, 0 };
    ID3D11Texture2D *texture;
    if (FAILED(ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture))) {
        printf("FAIL: create %s\n", name); failures++; return;
    }
    ID3D11RenderTargetView *rtv;
    ID3D11ShaderResourceView *srv;
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)texture, NULL, &rtv);
    ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)texture, NULL, &srv);
    ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);

    // Read it back through a shader into a float target, so every format reads the same way.
    static ID3D11PixelShader *copy_ps;
    static ID3D11VertexShader *vs;
    static ID3D11Texture2D *out, *staging;
    static ID3D11RenderTargetView *out_rtv;
    if (!copy_ps) {
        copy_ps = pixel_shader("Texture2D t : register(t0);"
                               "float4 main(float4 pos : SV_Position) : SV_Target { return t.Load(int3(1, 1, 0)); }");
        vs = vertex_shader(fullscreen_vs);
        D3D11_TEXTURE2D_DESC o = { 1, 1, 1, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, { 1, 0 }, D3D11_USAGE_DEFAULT,
                                   D3D11_BIND_RENDER_TARGET, 0, 0 };
        ID3D11Device_CreateTexture2D(device, &o, NULL, &out);
        ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)out, NULL, &out_rtv);
        o.Usage = D3D11_USAGE_STAGING; o.BindFlags = 0; o.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ID3D11Device_CreateTexture2D(device, &o, NULL, &staging);
    }
    D3D11_VIEWPORT viewport = { 0, 0, 1, 1, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
    ID3D11DeviceContext_OMSetRenderTargets(context, 1, &out_rtv, NULL);
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, copy_ps, NULL, 0);
    ID3D11DeviceContext_PSSetShaderResources(context, 0, 1, &srv);
    ID3D11DeviceContext_Draw(context, 3, 0);
    ID3D11ShaderResourceView *none = NULL;
    ID3D11DeviceContext_PSSetShaderResources(context, 0, 1, &none);
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)out);
    D3D11_MAPPED_SUBRESOURCE mapped;
    ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    const float *got = mapped.pData;
    int ok = 1;
    for (int c = 0; c < components; c++) ok &= fabsf(got[c] - color[c]) <= fmaxf(0.01f, fabsf(color[c]) * 0.01f);
    checks++;
    if (!ok) failures++;
    printf("%s    format %-30s got (%g, %g, %g, %g) expected (%g, %g, %g, %g)\n", ok ? "ok  " : "FAIL", name,
           got[0], got[1], got[2], got[3], color[0], color[1], color[2], color[3]);
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
}

int main(void) {
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL level;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 1, D3D11_SDK_VERSION,
                                   &device, &level, &context);
    if (FAILED(hr)) { printf("FAIL: D3D11CreateDevice 0x%08lx\n", hr); return 1; }
    ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    D3D11_RASTERIZER_DESC raster = { D3D11_FILL_SOLID, D3D11_CULL_NONE, FALSE, 0, 0, 0, TRUE, FALSE, FALSE, FALSE };
    ID3D11RasterizerState *raster_state;
    ID3D11Device_CreateRasterizerState(device, &raster, &raster_state);
    ID3D11DeviceContext_RSSetState(context, raster_state);

    run_checks();

    const float hdr[4] = { 3.5f, 0.125f, 20.0f, 1 };
    const float unorm[4] = { 0.25f, 0.5f, 0.75f, 1 };
    check_format(DXGI_FORMAT_R11G11B10_FLOAT, "R11G11B10_FLOAT", hdr, 3);
    check_format(DXGI_FORMAT_R16G16B16A16_FLOAT, "R16G16B16A16_FLOAT", hdr, 4);
    check_format(DXGI_FORMAT_R10G10B10A2_UNORM, "R10G10B10A2_UNORM", unorm, 4);
    check_format(DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, "R8G8B8A8_UNORM_SRGB", unorm, 4);
    check_format(DXGI_FORMAT_R16G16_FLOAT, "R16G16_FLOAT", hdr, 2);
    check_format(DXGI_FORMAT_R32_FLOAT, "R32_FLOAT", hdr, 1);
    check_format(DXGI_FORMAT_R16_FLOAT, "R16_FLOAT", hdr, 1);

    printf("checks: %d, failures: %d\n", checks, failures);
    fflush(stdout);
    return failures == 0 ? 0 : 1;
}
