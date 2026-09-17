// load.c — many draws per frame, so DXMT is measured under the shape a game
// actually has.
//
// Every D3D11 test in this tree is a single draw: triangle, texquad, cube and
// dxchkmsaa each clear, draw once, present. That proves the path works and
// says nothing about what it costs. A game issues hundreds of draws a frame,
// each preceded by a constant-buffer update, with a texture bound and state
// changing between them -- and that is the traffic DXMT translates into Metal.
//
// So: one cube, drawn N times per frame, each draw preceded by a MAP_DISCARD
// of a dynamic constant buffer, sampling a texture. Timed, and it stops on its
// own with numbers rather than running until someone closes it, because the
// result has to survive in the log.
//
// Build for BOTH architectures on purpose. aarch64 is native and isolates
// DXMT; x86-64 goes through FEX and ARM64EC first, which is the real game
// path. The difference between the two frame times is what separates "DXMT is
// slow" from "the emulator is slow", and neither number means much alone.
//
//   usage: load-x64.exe [draws-per-frame] [frames]      default 256 300

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "vs_dxbc.h"
#include "ps_dxbc.h"

#define WIDTH  800
#define HEIGHT 600
#define TEXDIM  64

static const char g_class_name[] = "MadeiraLoadWnd";

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

struct Vertex { float x, y, z; float u, v; };

/* The constant buffer the VS declares. 48 bytes, already a multiple of 16, so
 * no padding member is needed and none is written -- a struct whose layout
 * only accidentally matches the shader is a bug waiting for someone to add a
 * field. */
struct PerDraw {
    float place[4];   /* xy offset, z scale, w cos(yaw)   */
    float spin[4];    /* sin(yaw), cos(pitch), sin(pitch) */
    float tint[4];    /* rgb colour                       */
};

int main(int argc, char **argv) {
    int draws  = (argc > 1) ? atoi(argv[1]) : 256;
    int frames = (argc > 2) ? atoi(argv[2]) : 300;
    if (draws  < 1) draws  = 1;
    if (frames < 1) frames = 1;

    fprintf(stderr, "[load] starting: %d draws/frame, %d frames (vs=%u ps=%u bytes)\n",
            draws, frames, (unsigned)vs_dxbc_len, (unsigned)ps_dxbc_len);

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = g_class_name;
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowExA(0, g_class_name, "Madeira D3D11 Load",
                                WS_OVERLAPPEDWINDOW, 0, 0, WIDTH, HEIGHT,
                                NULL, NULL, wc.hInstance, NULL);
    ShowWindow(hwnd, SW_SHOW);

    DXGI_SWAP_CHAIN_DESC scd = {0};
    scd.BufferCount = 2;
    scd.BufferDesc.Width  = WIDTH;
    scd.BufferDesc.Height = HEIGHT;
    scd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.BufferDesc.RefreshRate.Numerator = 60;
    scd.BufferDesc.RefreshRate.Denominator = 1;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.OutputWindow = hwnd;
    scd.SampleDesc.Count = 1;
    scd.Windowed = TRUE;

    ID3D11Device *device = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *swap = NULL;
    D3D_FEATURE_LEVEL fl_out;
    D3D_FEATURE_LEVEL fls[] = { D3D_FEATURE_LEVEL_11_0 };
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                                               fls, 1, D3D11_SDK_VERSION,
                                               &scd, &swap, &device, &fl_out, &ctx);
    if (FAILED(hr)) { fprintf(stderr, "[load] CreateDevice+Swap failed 0x%lx\n", hr); return 1; }
    fprintf(stderr, "[load] device created, feature_level=0x%x\n", fl_out);

    ID3D11Texture2D *backbuf = NULL;
    swap->lpVtbl->GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&backbuf);
    ID3D11RenderTargetView *rtv = NULL;
    device->lpVtbl->CreateRenderTargetView(device, (ID3D11Resource *)backbuf, NULL, &rtv);

    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader  *ps = NULL;
    device->lpVtbl->CreateVertexShader(device, vs_dxbc, vs_dxbc_len, NULL, &vs);
    device->lpVtbl->CreatePixelShader (device, ps_dxbc, ps_dxbc_len, NULL, &ps);

    D3D11_INPUT_ELEMENT_DESC il[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0,  0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,    0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    ID3D11InputLayout *layout = NULL;
    device->lpVtbl->CreateInputLayout(device, il, 2, vs_dxbc, vs_dxbc_len, &layout);

    /* A cube as six independent quads: 24 vertices so each face gets its own
     * UVs, which is what makes the texture readable rather than smeared. */
    static const float F[6][4][5] = {
      {{-1,-1, 1,0,1},{ 1,-1, 1,1,1},{ 1, 1, 1,1,0},{-1, 1, 1,0,0}}, /* +z */
      {{ 1,-1,-1,0,1},{-1,-1,-1,1,1},{-1, 1,-1,1,0},{ 1, 1,-1,0,0}}, /* -z */
      {{ 1,-1, 1,0,1},{ 1,-1,-1,1,1},{ 1, 1,-1,1,0},{ 1, 1, 1,0,0}}, /* +x */
      {{-1,-1,-1,0,1},{-1,-1, 1,1,1},{-1, 1, 1,1,0},{-1, 1,-1,0,0}}, /* -x */
      {{-1, 1, 1,0,1},{ 1, 1, 1,1,1},{ 1, 1,-1,1,0},{-1, 1,-1,0,0}}, /* +y */
      {{-1,-1,-1,0,1},{ 1,-1,-1,1,1},{ 1,-1, 1,1,0},{-1,-1, 1,0,0}}, /* -y */
    };
    struct Vertex verts[24];
    unsigned short idx[36];
    for (int f = 0; f < 6; f++) {
        for (int v = 0; v < 4; v++) {
            verts[f*4+v] = (struct Vertex){ F[f][v][0], F[f][v][1], F[f][v][2],
                                            F[f][v][3], F[f][v][4] };
        }
        static const int order[6] = { 0, 1, 2, 0, 2, 3 };
        for (int k = 0; k < 6; k++) idx[f*6+k] = (unsigned short)(f*4 + order[k]);
    }

    D3D11_BUFFER_DESC vbd = { .ByteWidth = sizeof(verts), .Usage = D3D11_USAGE_IMMUTABLE,
                              .BindFlags = D3D11_BIND_VERTEX_BUFFER };
    D3D11_SUBRESOURCE_DATA vbi = { .pSysMem = verts };
    ID3D11Buffer *vb = NULL;
    device->lpVtbl->CreateBuffer(device, &vbd, &vbi, &vb);

    D3D11_BUFFER_DESC ibd = { .ByteWidth = sizeof(idx), .Usage = D3D11_USAGE_IMMUTABLE,
                              .BindFlags = D3D11_BIND_INDEX_BUFFER };
    D3D11_SUBRESOURCE_DATA ibi = { .pSysMem = idx };
    ID3D11Buffer *ib = NULL;
    device->lpVtbl->CreateBuffer(device, &ibd, &ibi, &ib);

    /* DYNAMIC + MAP_DISCARD per draw is the pattern engines use for per-object
     * constants, and it is the one that costs: each map is a rename the
     * translation layer has to service. */
    D3D11_BUFFER_DESC cbd = { .ByteWidth = sizeof(struct PerDraw),
                              .Usage = D3D11_USAGE_DYNAMIC,
                              .BindFlags = D3D11_BIND_CONSTANT_BUFFER,
                              .CPUAccessFlags = D3D11_CPU_ACCESS_WRITE };
    ID3D11Buffer *cb = NULL;
    if (FAILED(device->lpVtbl->CreateBuffer(device, &cbd, NULL, &cb))) {
        fprintf(stderr, "[load] dynamic constant buffer failed\n"); return 1;
    }

    /* A checkerboard, generated rather than shipped: one less file to keep in
     * step with the code, and the pattern makes UV errors obvious. */
    static unsigned int px[TEXDIM * TEXDIM];
    for (int y = 0; y < TEXDIM; y++)
        for (int x = 0; x < TEXDIM; x++)
            px[y*TEXDIM+x] = ((x >> 3) ^ (y >> 3)) & 1 ? 0xfff0f0f0u : 0xff404040u;

    D3D11_TEXTURE2D_DESC td = { .Width = TEXDIM, .Height = TEXDIM, .MipLevels = 1,
                                .ArraySize = 1, .Format = DXGI_FORMAT_R8G8B8A8_UNORM,
                                .SampleDesc.Count = 1, .Usage = D3D11_USAGE_IMMUTABLE,
                                .BindFlags = D3D11_BIND_SHADER_RESOURCE };
    D3D11_SUBRESOURCE_DATA ti = { .pSysMem = px, .SysMemPitch = TEXDIM * 4 };
    ID3D11Texture2D *tex = NULL;
    device->lpVtbl->CreateTexture2D(device, &td, &ti, &tex);
    ID3D11ShaderResourceView *srv = NULL;
    device->lpVtbl->CreateShaderResourceView(device, (ID3D11Resource *)tex, NULL, &srv);

    D3D11_SAMPLER_DESC sd = { .Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                              .AddressU = D3D11_TEXTURE_ADDRESS_WRAP,
                              .AddressV = D3D11_TEXTURE_ADDRESS_WRAP,
                              .AddressW = D3D11_TEXTURE_ADDRESS_WRAP,
                              .MaxLOD = D3D11_FLOAT32_MAX };
    ID3D11SamplerState *smp = NULL;
    device->lpVtbl->CreateSamplerState(device, &sd, &smp);

    D3D11_VIEWPORT vp = { 0, 0, (float)WIDTH, (float)HEIGHT, 0.0f, 1.0f };
    const float clear[] = { 0.06f, 0.07f, 0.10f, 1.0f };
    UINT stride = sizeof(struct Vertex), offset = 0;

    LARGE_INTEGER freq, t_start, t_prev, t_now;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t_start);
    t_prev = t_start;
    double worst = 0.0, best = 1e9;

    fprintf(stderr, "[load] entering render loop\n");
    for (int f = 0; f < frames; f++) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { frames = f; goto report; }
            TranslateMessage(&msg); DispatchMessageA(&msg);
        }

        ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, clear);
        ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ctx->lpVtbl->RSSetViewports(ctx, 1, &vp);
        ctx->lpVtbl->IASetInputLayout(ctx, layout);
        ctx->lpVtbl->IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->lpVtbl->IASetVertexBuffers(ctx, 0, 1, &vb, &stride, &offset);
        ctx->lpVtbl->IASetIndexBuffer(ctx, ib, DXGI_FORMAT_R16_UINT, 0);
        ctx->lpVtbl->VSSetShader(ctx, vs, NULL, 0);
        ctx->lpVtbl->PSSetShader(ctx, ps, NULL, 0);
        ctx->lpVtbl->PSSetShaderResources(ctx, 0, 1, &srv);
        ctx->lpVtbl->PSSetSamplers(ctx, 0, 1, &smp);

        for (int d = 0; d < draws; d++) {
            float t   = (float)f * 0.03f + (float)d * 0.37f;
            float col = (float)d / (float)draws;
            struct PerDraw pd = {
                .place = { cosf(t * 0.7f) * 1.6f, sinf(t * 0.9f) * 1.2f,
                           0.18f, cosf(t) },
                .spin  = { sinf(t), cosf(t * 0.6f), sinf(t * 0.6f), 0.0f },
                .tint  = { 0.4f + 0.6f * col, 0.5f, 1.0f - 0.5f * col, 1.0f },
            };
            D3D11_MAPPED_SUBRESOURCE m;
            if (SUCCEEDED(ctx->lpVtbl->Map(ctx, (ID3D11Resource *)cb, 0,
                                           D3D11_MAP_WRITE_DISCARD, 0, &m))) {
                memcpy(m.pData, &pd, sizeof(pd));
                ctx->lpVtbl->Unmap(ctx, (ID3D11Resource *)cb, 0);
            }
            ctx->lpVtbl->VSSetConstantBuffers(ctx, 0, 1, &cb);
            ctx->lpVtbl->DrawIndexed(ctx, 36, 0, 0);
        }

        /* Present with no vsync: with it, every frame reads as 16.6 ms and the
         * measurement says nothing about what the work cost. */
        swap->lpVtbl->Present(swap, 0, 0);

        QueryPerformanceCounter(&t_now);
        double ms = (double)(t_now.QuadPart - t_prev.QuadPart) * 1000.0 / (double)freq.QuadPart;
        t_prev = t_now;
        if (ms > worst) worst = ms;
        if (ms < best)  best  = ms;
        /* Every 60 frames, so a stall is visible in the log as a gap rather
         * than only in the average at the end. */
        if ((f % 60) == 0)
            fprintf(stderr, "[load] frame %d  %.2f ms\n", f, ms);
    }

report:
    QueryPerformanceCounter(&t_now);
    {
        double total = (double)(t_now.QuadPart - t_start.QuadPart) * 1000.0 / (double)freq.QuadPart;
        double mean  = frames ? total / frames : 0.0;
        fprintf(stderr, "[load] DONE %d frames x %d draws in %.0f ms\n", frames, draws, total);
        fprintf(stderr, "[load]   mean %.2f ms/frame (%.1f fps), best %.2f, worst %.2f\n",
                mean, mean > 0 ? 1000.0 / mean : 0.0, best, worst);
        fprintf(stderr, "[load]   %.0f draws/s, %.0f cbuffer maps/s\n",
                total > 0 ? frames * (double)draws * 1000.0 / total : 0.0,
                total > 0 ? frames * (double)draws * 1000.0 / total : 0.0);
    }
    fprintf(stderr, "[load] exiting cleanly\n");
    return 0;
}
