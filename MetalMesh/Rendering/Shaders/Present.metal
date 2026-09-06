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

fragment float4 presentFragment(PresentOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(source.sample(s, in.uv).rgb, 1.0);
}
