#include <metal_stdlib>
using namespace metal;

/// 풀스크린 삼각형: 업스케일(또는 원본) 컬러를 드로어블에 복사한다
struct PresentOut {
    float4 position [[position]];
    float2 uv;
};

vertex PresentOut presentVertex(uint vid [[vertex_id]]) {
    float2 pos = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
    PresentOut o;
    o.position = float4(pos, 0.0, 1.0);
    o.uv = float2(pos.x * 0.5 + 0.5, 1.0 - (pos.y * 0.5 + 0.5));
    return o;
}

fragment float4 presentFragment(PresentOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                texture2d<float> ao [[texture(1)]],
                                constant float& aoStrength [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 color = source.sample(s, in.uv).rgb;
    if (aoStrength > 0.0) {
        float a = ao.sample(s, in.uv).r;
        color *= mix(1.0, a, aoStrength);
    }
    return float4(color, 1.0);
}
