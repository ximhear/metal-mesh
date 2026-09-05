//  Swift(브리징 헤더)와 Metal 셰이더가 공유하는 타입과 상수.
//  레이아웃을 바꾸면 Swift 쪽 MemoryLayout 테스트(ShaderTypesTests)가 잡아낸다.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// 메시렛 한계. Metal 최대치는 정점 256 / 프리미티브 512.
#define MESHLET_MAX_VERTICES   64
#define MESHLET_MAX_TRIANGLES  126

// object 스테이지: 스레드 1개 = 메시렛 1개, 스레드그룹 32개 메시렛
#define OBJECT_THREADS_PER_THREADGROUP 32
// mesh 스테이지: 스레드그룹 1개 = 메시렛 1개
#define MESH_THREADS_PER_THREADGROUP   128

/// 정점. stride 48 (float3는 16바이트 정렬).
typedef struct {
    simd_float3 position;   // offset 0
    simd_float3 normal;     // offset 16
    simd_float2 uv;         // offset 32
} Vertex;

/// 메시렛 서술자. 64바이트.
typedef struct {
    simd_float3  boundsCenter;    // 0   모델 공간 경계 구 중심
    float        boundsRadius;    // 16
    simd_float3  coneAxis;        // 32  정규화된 평균 노멀
    float        coneCutoff;      // 48  meshoptimizer 규약: 1.0이면 컬링 불가
    unsigned int vertexOffset;    // 52  meshletVertices 내 시작 위치
    unsigned int triangleOffset;  // 56  meshletTriangles 내 시작 위치 (인덱스 단위, 3의 배수)
    unsigned short vertexCount;   // 60
    unsigned short triangleCount; // 62
} Meshlet;

#endif /* ShaderTypes_h */
