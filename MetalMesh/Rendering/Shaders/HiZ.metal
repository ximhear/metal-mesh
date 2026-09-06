#include <metal_stdlib>
using namespace metal;

/// 깊이 버퍼 → Hi-Z 밉 0 (r32Float)
kernel void hizCopyDepth(depth2d<float, access::read> depth [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(depth.read(gid), gid);
}

/// 2x2(가장자리 홀수면 3까지) 최대값으로 다음 밉 생성. 최대 깊이 = 가장 먼 가림막 → 보수적 오클루전
kernel void hizDownsample(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint2 dstSize = uint2(dst.get_width(), dst.get_height());
    if (gid.x >= dstSize.x || gid.y >= dstSize.y) return;
    uint2 srcSize = uint2(src.get_width(), src.get_height());
    uint2 base = gid * 2;
    uint spanX = (srcSize.x & 1u) && gid.x == dstSize.x - 1 ? 3u : 2u;
    uint spanY = (srcSize.y & 1u) && gid.y == dstSize.y - 1 ? 3u : 2u;
    float d = 0.0;
    for (uint y = 0; y < spanY; ++y) {
        for (uint x = 0; x < spanX; ++x) {
            uint2 p = min(base + uint2(x, y), srcSize - 1u);
            d = max(d, src.read(p).r);
        }
    }
    dst.write(d, gid);
}
