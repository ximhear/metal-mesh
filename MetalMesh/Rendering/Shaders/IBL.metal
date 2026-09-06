#include <metal_stdlib>
using namespace metal;

// MARK: - 공통

constant float PI = 3.14159265358979;

/// 큐브맵 면/텍셀 → 방향 (Metal 큐브맵 규약)
static float3 cubeDirection(uint face, float2 uv) {
    float2 st = uv * 2.0 - 1.0;   // -1…1
    switch (face) {
        case 0: return normalize(float3( 1.0, -st.y, -st.x));
        case 1: return normalize(float3(-1.0, -st.y,  st.x));
        case 2: return normalize(float3( st.x,  1.0,  st.y));
        case 3: return normalize(float3( st.x, -1.0, -st.y));
        case 4: return normalize(float3( st.x, -st.y,  1.0));
        default: return normalize(float3(-st.x, -st.y, -1.0));
    }
}

static float2 equirectUV(float3 d) {
    float u = atan2(d.x, -d.z) / (2.0 * PI) + 0.5;
    float v = acos(clamp(d.y, -1.0, 1.0)) / PI;
    return float2(u, v);
}

static float radicalInverse(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

static float2 hammersley(uint i, uint n) { return float2(float(i) / float(n), radicalInverse(i)); }

static float3 importanceSampleGGX(float2 xi, float roughness, float3 n) {
    float a = roughness * roughness;
    float phi = 2.0 * PI * xi.x;
    float cosTheta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    float3 h = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 tx = normalize(cross(up, n));
    float3 ty = cross(n, tx);
    return normalize(tx * h.x + ty * h.y + n * h.z);
}

static float geometrySchlickGGX_IBL(float nDotV, float roughness) {
    float k = (roughness * roughness) / 2.0;
    return nDotV / (nDotV * (1.0 - k) + k);
}

// MARK: - 커널

/// 등장방형 HDR → 큐브맵 (밉 0)
kernel void iblEquirectToCube(texture2d<float, access::sample> equirect [[texture(0)]],
                              texturecube<float, access::write> cube [[texture(1)]],
                              uint3 gid [[thread_position_in_grid]])
{
    uint size = cube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    constexpr sampler s(filter::linear, address::repeat);
    float3 d = cubeDirection(gid.z, (float2(gid.xy) + 0.5) / float(size));
    float4 c = equirect.sample(s, equirectUV(d));
    cube.write(float4(min(c.rgb, 64.0), 1.0), gid.xy, gid.z);   // 극단적 광원 클램프 (불꽃 방지)
}

/// 조도(디퓨즈) 큐브맵: 반구 코사인 가중 적분
kernel void iblIrradiance(texturecube<float, access::sample> env [[texture(0)]],
                          texturecube<float, access::write> out [[texture(1)]],
                          uint3 gid [[thread_position_in_grid]])
{
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 n = cubeDirection(gid.z, (float2(gid.xy) + 0.5) / float(size));
    float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 tx = normalize(cross(up, n));
    float3 ty = cross(n, tx);
    float3 sum = 0.0;
    const uint N = 512;
    for (uint i = 0; i < N; ++i) {
        float2 xi = hammersley(i, N);
        // 코사인 가중 반구 샘플
        float phi = 2.0 * PI * xi.x;
        float cosTheta = sqrt(1.0 - xi.y);
        float sinTheta = sqrt(xi.y);
        float3 d = tx * (cos(phi) * sinTheta) + ty * (sin(phi) * sinTheta) + n * cosTheta;
        sum += env.sample(s, d, level(2.0)).rgb;   // 살짝 흐린 밉으로 노이즈 억제
    }
    out.write(float4(sum / float(N), 1.0), gid.xy, gid.z);
}

/// GGX 프리필터 스펙큘러 큐브맵 (밉 레벨 = 러프니스)
kernel void iblPrefilterSpecular(texturecube<float, access::sample> env [[texture(0)]],
                                 texturecube<float, access::write> out [[texture(1)]],
                                 constant float& roughness [[buffer(0)]],
                                 constant float& envSize [[buffer(1)]],
                                 uint3 gid [[thread_position_in_grid]])
{
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 n = cubeDirection(gid.z, (float2(gid.xy) + 0.5) / float(size));
    float3 v = n;
    if (roughness < 0.001) { out.write(float4(env.sample(s, n, level(0.0)).rgb, 1.0), gid.xy, gid.z); return; }
    float3 sum = 0.0;
    float weight = 0.0;
    const uint N = 256;
    float saTexel = 4.0 * PI / (6.0 * envSize * envSize);
    for (uint i = 0; i < N; ++i) {
        float2 xi = hammersley(i, N);
        float3 h = importanceSampleGGX(xi, roughness, n);
        float3 l = normalize(2.0 * dot(v, h) * h - v);
        float nDotL = dot(n, l);
        if (nDotL > 0.0) {
            // pdf 기반 밉 선택 (aliasing 방지)
            float nDotH = max(dot(n, h), 0.0);
            float a = roughness * roughness;
            float d = (nDotH * nDotH) * (a * a - 1.0) + 1.0;
            float D = (a * a) / (PI * d * d);
            float pdf = D * nDotH / (4.0 * max(dot(v, h), 1e-4)) + 1e-4;
            float saSample = 1.0 / (float(N) * pdf + 1e-4);
            float mip = 0.5 * log2(saSample / saTexel);
            sum += env.sample(s, l, level(max(mip, 0.0))).rgb * nDotL;
            weight += nDotL;
        }
    }
    out.write(float4(sum / max(weight, 1e-4), 1.0), gid.xy, gid.z);
}

/// split-sum BRDF LUT: x = nDotV, y = roughness → (scale, bias)
kernel void iblBRDFLUT(texture2d<float, access::write> out [[texture(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float nDotV = max((float(gid.x) + 0.5) / float(w), 1e-3);
    float roughness = (float(gid.y) + 0.5) / float(h);
    float3 v = float3(sqrt(1.0 - nDotV * nDotV), 0.0, nDotV);
    float3 n = float3(0, 0, 1);
    float A = 0.0, B = 0.0;
    const uint N = 512;
    for (uint i = 0; i < N; ++i) {
        float2 xi = hammersley(i, N);
        float3 hv = importanceSampleGGX(xi, roughness, n);
        float3 l = normalize(2.0 * dot(v, hv) * hv - v);
        float nDotL = max(l.z, 0.0), nDotH = max(hv.z, 0.0), vDotH = max(dot(v, hv), 0.0);
        if (nDotL > 0.0) {
            float g = geometrySchlickGGX_IBL(nDotV, roughness) * geometrySchlickGGX_IBL(nDotL, roughness);
            float gVis = g * vDotH / (nDotH * nDotV + 1e-5);
            float fc = pow(1.0 - vDotH, 5.0);
            A += (1.0 - fc) * gVis;
            B += fc * gVis;
        }
    }
    out.write(float4(A / float(N), B / float(N), 0.0, 1.0), gid);
}
