#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

// MARK: - Object 스테이지: 메시렛 컬링

/// 경계 구가 프러스텀 밖이면 false
static bool insideFrustum(constant Uniforms& u, float3 center, float radius) {
    for (int i = 0; i < 6; ++i) {
        float d = dot(u.frustumPlanes[i].xyz, center) + u.frustumPlanes[i].w;
        if (d < -radius) return false;
    }
    return true;
}

/// meshoptimizer 규약의 노멀 콘 테스트. true면 메시렛 전체가 뒷면 → 컬링
static bool coneBackfacing(constant Uniforms& u, Meshlet m) {
    if (m.coneCutoff >= 1.0) return false;
    float3 toCenter = m.boundsCenter - u.cameraPositionModel;
    float dist = length(toCenter);
    return dot(toCenter, m.coneAxis) >= m.coneCutoff * dist + m.boundsRadius;
}

/// 경계 구를 화면 공간 사각형으로 투영해 Hi-Z(최대 깊이) 피라미드와 비교한다. true면 완전히 가려짐.
static bool occludedByHiZ(constant Uniforms& u, texture2d<float> hiz, float3 center, float radius) {
    constexpr sampler hizSampler(coord::normalized, filter::nearest, mip_filter::nearest, address::clamp_to_edge);
    float2 ndcMin = float2( 1e30);
    float2 ndcMax = float2(-1e30);
    float minDepth = 1e30;
    // 구의 AABB 8꼭짓점을 투영 (보수적). 한 점이라도 카메라 뒤/근평면 앞이면 컬링하지 않는다.
    for (int i = 0; i < 8; ++i) {
        float3 corner = center + radius * float3((i & 1) ? 1.0 : -1.0, (i & 2) ? 1.0 : -1.0, (i & 4) ? 1.0 : -1.0);
        float4 clip = u.modelViewProjection * float4(corner, 1.0);
        if (clip.w <= 1e-5) return false;
        float3 ndc = clip.xyz / clip.w;
        ndcMin = min(ndcMin, ndc.xy);
        ndcMax = max(ndcMax, ndc.xy);
        minDepth = min(minDepth, ndc.z);
    }
    if (minDepth <= 0.0) return false;
    // NDC(y 위) → UV(y 아래)
    float2 uvMin = clamp(float2(ndcMin.x, -ndcMax.y) * 0.5 + 0.5, 0.0, 1.0);
    float2 uvMax = clamp(float2(ndcMax.x, -ndcMin.y) * 0.5 + 0.5, 0.0, 1.0);
    float2 sizePx = (uvMax - uvMin) * float2(u.hizSize);
    // 텍셀 크기가 사각형의 절반 이상인 밉을 고르면 사각형은 축마다 최대 3텍셀에 걸친다.
    // 3×3 샘플(귀퉁이 + 중점)로 겹치는 텍셀을 모두 읽는다 → 보수적이면서 귀퉁이 4개만 읽을 때보다 2배 정밀.
    float lvl = clamp(ceil(log2(max(max(sizePx.x, sizePx.y), 1.0))) - 1.0, 0.0, float(u.hizMipCount - 1));
    float2 uvMid = (uvMin + uvMax) * 0.5;
    float d = 0.0;
    for (int y = 0; y < 3; ++y) {
        for (int x = 0; x < 3; ++x) {
            float2 uv = float2(x == 0 ? uvMin.x : (x == 1 ? uvMid.x : uvMax.x),
                               y == 0 ? uvMin.y : (y == 1 ? uvMid.y : uvMax.y));
            d = max(d, hiz.sample(hizSampler, uv, level(lvl)).r);
        }
    }
    return minDepth > d;   // 구의 가장 가까운 점이 그 영역의 가장 먼 가림막보다 뒤에 있다
}

[[object, max_total_threads_per_threadgroup(OBJECT_THREADS_PER_THREADGROUP),
          max_total_threadgroups_per_mesh_grid(OBJECT_THREADS_PER_THREADGROUP)]]
void objectMain(object_data MeshletPayload& payload [[payload]],
                mesh_grid_properties grid,
                constant Uniforms& u                [[buffer(BUFFER_UNIFORMS)]],
                const device Meshlet* meshlets      [[buffer(BUFFER_MESHLETS)]],
                device atomic_uint* stats           [[buffer(BUFFER_STATS)]],
                constant uint& cullPass             [[buffer(BUFFER_CULL_PASS)]],
                device uint* visibility             [[buffer(BUFFER_VISIBILITY)]],
                texture2d<float> hiz                [[texture(TEXTURE_HIZ)]],
                uint tid [[thread_index_in_threadgroup]],
                uint gid [[thread_position_in_grid]])
{
    threadgroup atomic_uint count;
    threadgroup atomic_uint occluded;
    if (tid == 0) {
        atomic_store_explicit(&count, 0u, memory_order_relaxed);
        atomic_store_explicit(&occluded, 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    bool draw = false;
    if (gid < u.meshletCount) {
        Meshlet m = meshlets[gid];
        bool inView = true;
        if (u.cullingEnabled) {
            inView = insideFrustum(u, m.boundsCenter, m.boundsRadius) && !coneBackfacing(u, m);
        }
        switch (cullPass) {
            case CULL_PASS_FIRST:
                draw = inView && visibility[gid] != 0u;
                break;
            case CULL_PASS_SECOND: {
                bool drawnInFirst = visibility[gid] != 0u && inView;
                bool occ = inView && occludedByHiZ(u, hiz, m.boundsCenter, m.boundsRadius);
                if (occ) atomic_fetch_add_explicit(&occluded, 1u, memory_order_relaxed);
                bool nowVisible = inView && !occ;
                draw = nowVisible && !drawnInFirst;      // 1패스에서 그린 것은 다시 그리지 않는다
                visibility[gid] = nowVisible ? 1u : 0u;  // 다음 프레임 1패스용
                break;
            }
            default:
                draw = inView;
                break;
        }
    }
    if (draw) {
        uint slot = atomic_fetch_add_explicit(&count, 1u, memory_order_relaxed);
        payload.meshletIndices[slot] = gid;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        uint total = atomic_load_explicit(&count, memory_order_relaxed);
        uint occ = atomic_load_explicit(&occluded, memory_order_relaxed);
        grid.set_threadgroups_per_grid(uint3(total, 1, 1));
        if (total > 0) atomic_fetch_add_explicit(&stats[STAT_DRAWN], total, memory_order_relaxed);
        if (occ > 0) atomic_fetch_add_explicit(&stats[STAT_OCCLUDED], occ, memory_order_relaxed);
    }
}

// MARK: - Mesh 스테이지: 메시렛 1개 → 정점/삼각형

struct VertexOut {
    float4 position [[position]];
    float3 normalView;
    float3 positionView;
    float2 uv;
};

struct PrimitiveOut {
    uint meshletID [[flat]];
    uint materialIndex [[flat]];
};

using MeshletMesh = mesh<VertexOut, PrimitiveOut, MESHLET_MAX_VERTICES, MESHLET_MAX_TRIANGLES, topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(MESH_THREADS_PER_THREADGROUP)]]
void meshMain(MeshletMesh out,
              const object_data MeshletPayload& payload [[payload]],
              constant Uniforms& u                       [[buffer(BUFFER_UNIFORMS)]],
              const device Meshlet* meshlets             [[buffer(BUFFER_MESHLETS)]],
              const device Vertex* vertices              [[buffer(BUFFER_VERTICES)]],
              const device uint* meshletVertices         [[buffer(BUFFER_MESHLET_VERTICES)]],
              const device uchar* meshletTriangles       [[buffer(BUFFER_MESHLET_TRIANGLES)]],
              uint tid  [[thread_index_in_threadgroup]],
              uint tgid [[threadgroup_position_in_grid]])
{
    uint meshletIndex = payload.meshletIndices[tgid];
    Meshlet m = meshlets[meshletIndex];

    if (tid < m.vertexCount) {
        Vertex v = vertices[meshletVertices[m.vertexOffset + tid]];
        float4 p = float4(v.position, 1.0);
        VertexOut o;
        o.position = u.modelViewProjection * p;
        o.positionView = (u.modelView * p).xyz;
        o.normalView = normalize(u.normalMatrix * v.normal);
        o.uv = v.uv;
        out.set_vertex(tid, o);
    }

    if (tid < m.triangleCount) {
        uint base = m.triangleOffset + tid * 3;
        out.set_index(tid * 3 + 0, meshletTriangles[base + 0]);
        out.set_index(tid * 3 + 1, meshletTriangles[base + 1]);
        out.set_index(tid * 3 + 2, meshletTriangles[base + 2]);
        PrimitiveOut prim;
        prim.meshletID = meshletIndex;
        prim.materialIndex = m.materialIndex;
        out.set_primitive(tid, prim);
    }

    if (tid == 0) out.set_primitive_count(m.triangleCount);
}

// MARK: - Fragment

struct FragmentIn {
    VertexOut v;
    PrimitiveOut p;
};

static float3 meshletColor(uint id) {
    uint h = id * 2654435761u;
    float3 c = float3((h >> 0) & 255u, (h >> 8) & 255u, (h >> 16) & 255u) / 255.0;
    return 0.35 + 0.65 * c;
}

constexpr sampler baseColorSampler(address::repeat, filter::linear, mip_filter::linear);

fragment float4 fragmentMain(FragmentIn in [[stage_in]],
                             constant Uniforms& u                  [[buffer(BUFFER_UNIFORMS)]],
                             const device Material* materials      [[buffer(BUFFER_MATERIALS)]])
{
    float3 n = normalize(in.v.normalView);
    float3 viewDir = normalize(-in.v.positionView);
    // 뒷면(또는 뒤집힌 와인딩)도 조명이 맞도록 카메라 쪽으로 노멀을 뒤집는다
    if (dot(n, viewDir) < 0.0) n = -n;

    float3 base;
    switch (u.debugMode) {
        case 1:  base = meshletColor(in.p.meshletID); break;
        case 2:  base = n * 0.5 + 0.5; break;
        default: {
            const device Material& m = materials[in.p.materialIndex];
            base = m.baseColorFactor.rgb;
            if (u.texturesEnabled && m.hasTexture) {
                // Model I/O UV는 좌하단 원점, Metal 텍스처는 좌상단 원점 → v 뒤집기
                float2 uv = float2(in.v.uv.x, 1.0 - in.v.uv.y);
                base *= m.baseColorTexture.sample(baseColorSampler, uv).rgb;
            }
            break;
        }
    }

    float3 keyLight = normalize(float3(0.35, 0.6, 1.0));   // 뷰 공간, 카메라 위쪽에서
    float3 fillLight = normalize(float3(-0.6, -0.2, 0.5));
    float diffuse = max(dot(n, keyLight), 0.0) + 0.35 * max(dot(n, fillLight), 0.0);
    float3 h = normalize(keyLight + viewDir);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.2;
    float3 color = base * (0.18 + 0.82 * diffuse) + spec;
    return float4(color, 1.0);
}
