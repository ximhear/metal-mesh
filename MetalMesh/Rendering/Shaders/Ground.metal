#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

/// 그림자를 받는 바닥 원판. 모델 아래 y = groundY. 가장자리로 갈수록 배경에 녹아든다.
struct GroundOut {
    float4 position [[position]];
    float3 positionModel;
    float3 positionView;
};

vertex GroundOut groundVertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(BUFFER_UNIFORMS)]]) {
    // 삼각형 2개 = 사각형, 중심은 (0, groundY, 0)이 아니라 카메라 타깃을 따르도록 반지름 큰 사각형
    float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid] * u.groundRadius;
    float3 p = float3(c.x, u.groundY, c.y) + float3(u.lodCameraPositionModel.x, 0, u.lodCameraPositionModel.z) * 0.0;
    GroundOut o;
    o.positionModel = p;
    o.positionView = (u.modelView * float4(p, 1.0)).xyz;
    o.position = u.modelViewProjection * float4(p, 1.0);
    return o;
}

static float groundShadow(constant Uniforms& u, depth2d<float> shadowMap, float3 positionModel) {
    if (u.shadowsEnabled == 0u) return 1.0;
    float4 lc = u.lightViewProjection * float4(positionModel, 1.0);
    float3 ndc = lc.xyz / lc.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z > 1.0) return 1.0;
    constexpr sampler s(filter::linear, compare_func::less_equal, address::clamp_to_edge);
    float2 texel = 1.0 / float2(shadowMap.get_width(), shadowMap.get_height());
    float sum = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            sum += shadowMap.sample_compare(s, uv + float2(x, y) * texel, ndc.z - u.shadowBias);
    return sum / 9.0;
}

fragment float4 groundFragment(GroundOut in [[stage_in]],
                               constant Uniforms& u [[buffer(BUFFER_UNIFORMS)]],
                               texturecube<float> irradianceMap [[texture(TEXTURE_IBL_IRRADIANCE)]],
                               depth2d<float> shadowMap [[texture(TEXTURE_SHADOW_MAP)]])
{
    constexpr sampler iblSampler(filter::linear, address::clamp_to_edge);
    float3 nView = normalize(u.normalMatrix * float3(0, 1, 0));
    float3 albedo = float3(0.33, 0.33, 0.35);
    float shadow = groundShadow(u, shadowMap, in.positionModel);
    float3 color;
    if (u.iblEnabled != 0u) {
        color = irradianceMap.sample(iblSampler, float3(0, 1, 0)).rgb * albedo;
        color += albedo / 3.14159265 * max(u.lightDirectionView.y * 0.0 + dot(nView, u.lightDirectionView), 0.0) * u.sunIntensity * shadow;
    } else {
        color = albedo * (0.15 + 2.2 * max(dot(nView, u.lightDirectionView), 0.0) * shadow / 3.14159265 * 3.0);
    }
    // ACES (메시와 동일)
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    float3 x = color * u.exposure;
    color = clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    // 가장자리 페이드: 배경색으로
    float dist = length(in.positionModel.xz) / u.groundRadius;
    float fade = 1.0 - smoothstep(0.35, 0.95, dist);
    float3 background = float3(0.11, 0.11, 0.13);
    return float4(mix(background, color, fade), 1.0);
}
