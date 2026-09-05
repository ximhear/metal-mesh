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

[[object, max_total_threads_per_threadgroup(OBJECT_THREADS_PER_THREADGROUP),
          max_total_threadgroups_per_mesh_grid(OBJECT_THREADS_PER_THREADGROUP)]]
void objectMain(object_data MeshletPayload& payload [[payload]],
                mesh_grid_properties grid,
                constant Uniforms& u                [[buffer(BUFFER_UNIFORMS)]],
                const device Meshlet* meshlets      [[buffer(BUFFER_MESHLETS)]],
                device atomic_uint* visibleCounter  [[buffer(BUFFER_STATS)]],
                uint tid [[thread_index_in_threadgroup]],
                uint gid [[thread_position_in_grid]])
{
    threadgroup atomic_uint count;
    if (tid == 0) atomic_store_explicit(&count, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    bool visible = false;
    if (gid < u.meshletCount) {
        Meshlet m = meshlets[gid];
        visible = true;
        if (u.cullingEnabled) {
            visible = insideFrustum(u, m.boundsCenter, m.boundsRadius) && !coneBackfacing(u, m);
        }
    }
    if (visible) {
        uint slot = atomic_fetch_add_explicit(&count, 1u, memory_order_relaxed);
        payload.meshletIndices[slot] = gid;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        uint total = atomic_load_explicit(&count, memory_order_relaxed);
        grid.set_threadgroups_per_grid(uint3(total, 1, 1));
        if (total > 0) atomic_fetch_add_explicit(visibleCounter, total, memory_order_relaxed);
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
