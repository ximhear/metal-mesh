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
}

/// 렌더러가 프레임마다 채우는 통계. 메인 스레드에서 갱신된다.
struct RenderStats: Equatable {
    var meshletCount = 0
    var visibleMeshletCount = 0
    var triangleCount = 0
    var vertexCount = 0
    var materialCount = 0
    var textureCount = 0
    /// 초 단위 GPU 시간
    var gpuTime: Double = 0
}
