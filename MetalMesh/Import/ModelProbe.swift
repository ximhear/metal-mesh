import Foundation
import ModelIO

/// Model I/O로 파일을 열어 정점·삼각형 수만 센다. 리스트 표시용이며 렌더링 로더(Phase 2)와는 별개.
/// 모든 Model I/O 호출은 `ModelIOQueue`로 직렬화한다 (동시 로드 크래시 회피).
enum ModelProbe {
    struct Stats: Sendable, Equatable {
        var vertexCount: Int
        var triangleCount: Int
    }

    static var supportedExtensions: Set<String> { ModelLoader.supportedExtensions }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 백그라운드에서 실행된다. 열 수 없으면 nil.
    static func stats(for url: URL) async -> Stats? {
        if GLBLoader.canLoad(url) {
            return await Task.detached(priority: .utility) {
                guard let mesh = try? GLBLoader.load(url: url) else { return nil }
                return Stats(vertexCount: mesh.vertices.count, triangleCount: mesh.triangleCount)
            }.value
        }
        return await ModelIOQueue.shared.run {
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
