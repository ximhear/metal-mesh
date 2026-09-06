#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

/// 깊이 → 뷰 공간 위치
static float3 viewPosition(constant SSAOUniforms& u, float2 uv, float depth) {
    float4 ndc = float4(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0, depth, 1.0);
    float4 v = u.inverseProjection * ndc;
    return v.xyz / v.w;
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// 반구 샘플링 SSAO (16 샘플, 픽셀별 회전). 출력 r8: 1 = 가려지지 않음
kernel void ssaoMain(depth2d<float, access::sample> depthTex [[texture(0)]],
                     texture2d<float, access::write> out [[texture(1)]],
                     constant SSAOUniforms& u [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / u.screenSize;
    float depth = depthTex.sample(s, uv);
    if (depth >= 1.0) { out.write(1.0, gid); return; }
    float3 p = viewPosition(u, uv, depth);
    // 깊이 미분으로 노멀 재구성
    float2 du = float2(1.0 / u.screenSize.x, 0.0), dv = float2(0.0, 1.0 / u.screenSize.y);
    float3 px = viewPosition(u, uv + du, depthTex.sample(s, uv + du));
    float3 py = viewPosition(u, uv + dv, depthTex.sample(s, uv + dv));
    float3 mx = viewPosition(u, uv - du, depthTex.sample(s, uv - du));
    float3 my = viewPosition(u, uv - dv, depthTex.sample(s, uv - dv));
    float3 dx = abs(px.z - p.z) < abs(mx.z - p.z) ? px - p : p - mx;
    float3 dy = abs(py.z - p.z) < abs(my.z - p.z) ? py - p : p - my;
    float3 n = normalize(cross(dy, dx));
    if (dot(n, -p) < 0.0) n = -n;

    float angle = hash12(float2(gid) + float(u.frameIndex % 8u)) * 6.2831853;
    float3 randomVec = float3(cos(angle), sin(angle), 0.0);
    float3 t = normalize(randomVec - n * dot(randomVec, n));
    float3 b = cross(n, t);
    float occlusion = 0.0;
    const int N = 16;
    for (int i = 0; i < N; ++i) {
        // 코사인 가중 반구 샘플 (Hammersley 근사)
        float fi = (float(i) + 0.5) / float(N);
        float phi = fi * 6.2831853 * 3.0;   // 나선
        float r = sqrt(fi);
        float3 dir = t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(1.0 - fi, 0.0));
        float scale = mix(0.15, 1.0, fi * fi);
        float3 sp = p + dir * (u.radius * scale);
        float4 clip = u.projection * float4(sp, 1.0);
        float2 suv = float2(clip.x / clip.w * 0.5 + 0.5, 1.0 - (clip.y / clip.w * 0.5 + 0.5));
        if (any(suv < 0.0) || any(suv > 1.0)) continue;
        float sceneDepth = depthTex.sample(s, suv);
        float3 scenePos = viewPosition(u, suv, sceneDepth);
        float rangeCheck = smoothstep(0.0, 1.0, u.radius / max(abs(p.z - scenePos.z), 1e-5));
        occlusion += (scenePos.z >= sp.z + u.bias ? 1.0 : 0.0) * rangeCheck;
    }
    float ao = 1.0 - (occlusion / float(N)) * u.intensity;
    out.write(clamp(ao, 0.0, 1.0), gid);
}

/// 4×4 박스 블러 (깊이 인식 없이 간단히)
kernel void ssaoBlur(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 size = uint2(src.get_width(), src.get_height());
    float sum = 0.0;
    for (int y = -2; y < 2; ++y) {
        for (int x = -2; x < 2; ++x) {
            int2 p = clamp(int2(gid) + int2(x, y), int2(0), int2(size) - 1);
            sum += src.read(uint2(p)).r;
        }
    }
    dst.write(sum / 16.0, gid);
}
