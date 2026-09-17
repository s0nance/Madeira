// One cube, drawn many times, with a per-draw constant buffer and a sampled
// texture. Deliberately the shape a real engine has and the existing tests do
// not: triangle, texquad, cube and dxchkmsaa are all a single draw, so none of
// them exercises the path a game actually hammers.

cbuffer PerDraw : register(b0) {
    float4 place;   // xy = screen offset, z = scale, w = cos(yaw)
    float4 spin;    // x = sin(yaw), y = cos(pitch), z = sin(pitch), w = unused
    float4 tint;    // rgb = colour, a = unused
};

Texture2D    tex : register(t0);
SamplerState smp : register(s0);

struct VS_IN  { float3 pos : POSITION; float2 uv : TEXCOORD; };
struct VS_OUT { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float3 col : COLOR; };

VS_OUT vs_main(VS_IN i) {
    VS_OUT o;
    float3 p = i.pos;
    // Yaw then pitch, from cosines the CPU already computed. No matrix upload:
    // the point is to measure the constant-buffer traffic, not to be a maths
    // demo, and six floats say the same thing as sixteen.
    float3 a = float3(p.x * place.w + p.z * spin.x,
                      p.y,
                      p.z * place.w - p.x * spin.x);
    float3 b = float3(a.x,
                      a.y * spin.y - a.z * spin.z,
                      a.y * spin.z + a.z * spin.y);
    b *= place.z;
    // Cheap perspective so the cubes read as solid rather than flat.
    float w = 2.4 + b.z;
    o.pos = float4((b.x + place.x) / w * 2.4, (b.y + place.y) / w * 2.4, 0.5, 1.0);
    o.uv  = i.uv;
    o.col = tint.rgb;
    return o;
}

float4 ps_main(VS_OUT i) : SV_TARGET {
    return float4(tex.Sample(smp, i.uv).rgb * i.col, 1.0);
}
