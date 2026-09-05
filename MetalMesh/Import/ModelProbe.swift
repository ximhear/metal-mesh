import Foundation
import ModelIO

/// Model I/O로 파일을 열어 정점·삼각형 수만 센다. 리스트 표시용이며 렌더링 로더(Phase 2)와는 별개.
///
/// 주의: Apple의 USD 런타임(libusd_ms)은 여러 USD 파일을 동시에 처음 열면 내부 플러그인 레지스트리에서
/// 널 포인터 역참조로 크래시한다(EXC_BAD_ACCESS in Sdf_GetExtension). 모든 로드는 `serialQueue`로 직렬화한다.
enum ModelProbe {
    /// Model I/O 호출을 한 번에 하나씩만 실행하는 액터
    private actor SerialLoader {
        func run<T: Sendable>(_ body: @Sendable () -> T) -> T { body() }
    }
    private static let serialQueue = SerialLoader()

    struct Stats: Sendable, Equatable {
        var vertexCount: Int
        var triangleCount: Int
    }

    static let supportedExtensions: Set<String> = ["obj", "ply", "stl", "usd", "usda", "usdc", "usdz"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 백그라운드에서 실행된다. 열 수 없으면 nil.
    static func stats(for url: URL) async -> Stats? {
        await serialQueue.run {
            guard MDLAsset.canImportFileExtension(url.pathExtension) else { return nil }
            let asset = MDLAsset(url: url)
            var vertices = 0
            var triangles = 0
            func walk(_ object: MDLObject) {
                if let mesh = object as? MDLMesh {
                    vertices += mesh.vertexCount
                    for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
                        triangles += submesh.indexCount / 3
                    }
                }
                for child in object.children.objects { walk(child) }
            }
            for index in 0..<asset.count { walk(asset.object(at: index)) }
            guard vertices > 0 else { return nil }
            return Stats(vertexCount: vertices, triangleCount: triangles)
        }
    }
}
