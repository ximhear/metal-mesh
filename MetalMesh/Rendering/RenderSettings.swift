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
    /// 클러스터 LOD (계층이 있을 때). 끄면 LOD0만
    var lodEnabled = true
    /// 허용 화면 오차 (픽셀)
    var lodThresholdPx: Float = 1.0
    /// 내부 렌더 해상도 비율 (1 = 출력과 같음). 1 미만이면 MetalFX 공간 업스케일러가 출력 해상도로 키운다
    var renderScale: Float = 1.0
    /// MSAA 샘플 수 (1 또는 4)
    var msaaSamples: Int = 1
    /// 태양 방향광 섀도 맵
    var shadowsEnabled = true
    /// 그림자를 받는 바닥 평면
    var groundEnabled = false
    /// 화면 공간 앰비언트 오클루전
    var ssaoEnabled = true
}

/// 렌더러가 프레임마다 채우는 통계. 메인 스레드에서 갱신된다.
struct RenderStats: Equatable {
    var meshletCount = 0
    var visibleMeshletCount = 0
    /// Hi-Z 테스트로 제거된 메시렛 수 (오클루전 켜진 경우)
    var occludedMeshletCount = 0
    /// LOD0(원본) 삼각형 수
    var triangleCount = 0
    /// 이 프레임에 그린 삼각형 수
    var drawnTriangleCount = 0
    var lodLevelCount = 1
    var vertexCount = 0
    var materialCount = 0
    var textureCount = 0
    /// 초 단위 GPU 시간
    var gpuTime: Double = 0
    var renderWidth = 0
    var renderHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var upscalerActive = false
}
