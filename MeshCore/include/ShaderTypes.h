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
    unsigned int materialIndex;   // 20  Material 배열 인덱스 (메시렛은 재질 하나만 가진다)
    simd_float3  coneAxis;        // 32  정규화된 평균 노멀
    float        coneCutoff;      // 48  meshoptimizer 규약: 1.0이면 컬링 불가
    unsigned int vertexOffset;    // 52  meshletVertices 내 시작 위치
    unsigned int triangleOffset;  // 56  meshletTriangles 내 시작 위치 (인덱스 단위, 3의 배수)
    unsigned short vertexCount;   // 60
    unsigned short triangleCount; // 62
} Meshlet;

/// 프레임 유니폼. 모델 행렬은 단위행렬로 두고 카메라만 움직인다(모델 공간 == 월드 공간).
typedef struct {
    simd_float4x4 modelViewProjection;
    simd_float4x4 modelView;
    simd_float3x3 normalMatrix;        // 모델 → 뷰 공간 노멀
    simd_float4   frustumPlanes[6];    // 모델 공간, 정규화, 안쪽이 양수 (left,right,bottom,top,near,far)
    simd_float3   cameraPositionModel; // 모델 공간 카메라 위치 (콘 컬링용)
    unsigned int  meshletCount;
    unsigned int  debugMode;           // DebugMode: 0 셰이딩, 1 메시렛 색, 2 노멀
    unsigned int  cullingEnabled;
    unsigned int  texturesEnabled;
    simd_uint2    hizSize;             // Hi-Z 밉 0 크기 (픽셀)
    unsigned int  hizMipCount;
    unsigned int  occlusionEnabled;
} Uniforms;

/// 컬링 패스 종류 (object 스테이지 setObjectBytes로 전달)
#define CULL_PASS_SINGLE 0   // 오클루전 없이 한 번에
#define CULL_PASS_FIRST  1   // 지난 프레임에 보였던 메시렛만 그린다
#define CULL_PASS_SECOND 2   // 나머지를 Hi-Z로 테스트해 새로 보이는 것만 그린다, 가시성 비트 갱신

/// 통계 버퍼 레이아웃 (atomic uint)
#define STAT_DRAWN    0      // 이 프레임에 그린 메시렛 수 (두 패스 합)
#define STAT_OCCLUDED 1      // Hi-Z 테스트로 제거된 메시렛 수
#define STAT_COUNT    2

/// 재질. Metal 3 인자 버퍼(tier 2)에 그대로 놓인다. 48바이트.
/// MSL에서는 texture2d가 8바이트 리소스 ID로 저장되므로 C 쪽은 MTLResourceID와 같은 8바이트로 맞춘다.
#ifdef __METAL_VERSION__
typedef metal::texture2d<float> BaseColorTexture;
#else
typedef struct { unsigned long long _impl; } BaseColorTexture;   // == MTLResourceID
#endif

typedef struct {
    BaseColorTexture baseColorTexture;  // 0  (8B, 텍스처 없으면 1x1 흰색 플레이스홀더)
    simd_float4      baseColorFactor;   // 16
    unsigned int     hasTexture;        // 32
    unsigned int     padding[3];
} Material;

/// object → mesh 페이로드: 컬링을 통과한 메시렛 인덱스
typedef struct {
    unsigned int meshletIndices[OBJECT_THREADS_PER_THREADGROUP];
} MeshletPayload;

// 버퍼 인덱스 (object / mesh / fragment 스테이지 공통)
#define BUFFER_UNIFORMS          0
#define BUFFER_MESHLETS          1
#define BUFFER_MATERIALS         1   // fragment 전용: Material 배열 (인자 버퍼)
#define BUFFER_STATS             2   // object 전용: atomic uint[STAT_COUNT]
#define BUFFER_CULL_PASS         3   // object 전용: uint (CULL_PASS_*)
#define BUFFER_VISIBILITY        4   // object 전용: uint[meshletCount], 지난 프레임 가시성
#define TEXTURE_HIZ              0   // object 전용: r32Float 밉 피라미드 (max depth)
#define BUFFER_VERTICES          2   // mesh 전용
#define BUFFER_MESHLET_VERTICES  3
#define BUFFER_MESHLET_TRIANGLES 4

#endif /* ShaderTypes_h */
