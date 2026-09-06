import Foundation

enum DebugMode: UInt32, CaseIterable, Identifiable {
    case shaded = 0
    case meshlets = 1
    case normals = 2

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .shaded: return "셰이딩"
        case .meshlets: return "메시렛"
        case .normals: return "노멀"
        }
    }
}

struct RenderSettings: Equatable {
    var debugMode: DebugMode = .shaded
    var cullingEnabled = true
    var wireframe = false
    var texturesEnabled = true
    /// 2패스 Hi-Z 오클루전 컬링
    var occlusionEnabled = true
    /// 이미지 기반 조명 (환경맵). 끄면 방향광 2개로 셰이딩
    var iblEnabled = true
    var exposure: Float = 1.0
}

/// 렌더러가 프레임마다 채우는 통계. 메인 스레드에서 갱신된다.
struct RenderStats: Equatable {
    var meshletCount = 0
    var visibleMeshletCount = 0
    /// Hi-Z 테스트로 제거된 메시렛 수 (오클루전 켜진 경우)
    var occludedMeshletCount = 0
    var triangleCount = 0
    var vertexCount = 0
    var materialCount = 0
    var textureCount = 0
    /// 초 단위 GPU 시간
    var gpuTime: Double = 0
}
