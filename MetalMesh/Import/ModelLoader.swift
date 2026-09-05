import Foundation
import ModelIO
import simd

/// 렌더링용 중간 표현. 모든 서브메시를 하나의 삼각형 리스트로 병합한 결과.
struct MeshData: Sendable {
    var vertices: [Vertex]
    var indices: [UInt32]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>

    var triangleCount: Int { indices.count / 3 }
    var boundsCenter: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var boundsRadius: Float { simd_length(boundsMax - boundsMin) * 0.5 }
}

enum ModelLoaderError: LocalizedError {
    case unsupportedExtension(String)
    case openFailed(String)
    case noTriangles

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext): return "지원하지 않는 형식입니다: .\(ext)"
        case .openFailed(let reason): return "파일을 열 수 없습니다: \(reason)"
        case .noTriangles: return "삼각형 메시가 없습니다."
        }
    }
}

/// Model I/O로 파일을 읽어 `Vertex` 레이아웃(position/normal/uv, stride 48)으로 정규화한다.
/// 노드 변환을 정점에 적용하고, 노멀이 없으면 생성한다. 폴리곤은 삼각형으로 분할된다.
enum ModelLoader {
    static func load(url: URL) async throws -> MeshData {
        try await ModelIOQueue.shared.run { try loadSynchronously(url: url) }
    }

    /// 테스트나 직렬 컨텍스트에서 직접 호출할 때 사용. 일반 코드는 `load(url:)`.
    static func loadSynchronously(url: URL) throws -> MeshData {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            throw ModelLoaderError.unsupportedExtension(url.pathExtension)
        }
        var error: NSError?
        // preserveTopology: false → 쿼드/폴리곤을 삼각형으로 분할
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil,
                             preserveTopology: false, error: &error)
        if let error { throw ModelLoaderError.openFailed(error.localizedDescription) }

        var merged = MeshData(vertices: [], indices: [],
                              boundsMin: SIMD3(repeating: .greatestFiniteMagnitude),
                              boundsMax: SIMD3(repeating: -.greatestFiniteMagnitude))

        for index in 0..<asset.count {
            visit(asset.object(at: index), parentTransform: matrix_identity_float4x4, into: &merged)
        }
        guard !merged.indices.isEmpty else { throw ModelLoaderError.noTriangles }
        return merged
    }

    // MARK: - 내부

    private static let targetDescriptor: MDLVertexDescriptor = {
        let d = MDLVertexDescriptor()
        d.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        d.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 16, bufferIndex: 0)
        d.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 32, bufferIndex: 0)
        d.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Vertex>.stride)
        return d
    }()

    private static func visit(_ object: MDLObject, parentTransform: float4x4, into merged: inout MeshData) {
        let local = object.transform?.matrix ?? matrix_identity_float4x4
        let world = parentTransform * local
        if let mesh = object as? MDLMesh {
            append(mesh, transform: world, into: &merged)
        }
        for child in object.children.objects {
            visit(child, parentTransform: world, into: &merged)
        }
    }

    private static func append(_ mesh: MDLMesh, transform: float4x4, into merged: inout MeshData) {
        let hasNormals = (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute])?
            .contains { $0.name == MDLVertexAttributeNormal && $0.format != .invalid } ?? false
        if !hasNormals {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        }
        mesh.vertexDescriptor = targetDescriptor

        guard let buffer = mesh.vertexBuffers.first else { return }
        let vertexCount = mesh.vertexCount
        let stride = MemoryLayout<Vertex>.stride
        let map = buffer.map()
        guard buffer.length >= vertexCount * stride else { return }

        let normalMatrix = simd_transpose(simd_inverse(upperLeft3x3(transform)))
        let base = UInt32(merged.vertices.count)
        merged.vertices.reserveCapacity(merged.vertices.count + vertexCount)
        let raw = map.bytes.bindMemory(to: Vertex.self, capacity: vertexCount)
        for i in 0..<vertexCount {
            var v = raw[i]
            let p = transform * SIMD4(v.position, 1)
            v.position = SIMD3(p.x, p.y, p.z) / (p.w == 0 ? 1 : p.w)
            let n = normalMatrix * v.normal
            v.normal = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
            merged.vertices.append(v)
            merged.boundsMin = simd_min(merged.boundsMin, v.position)
            merged.boundsMax = simd_max(merged.boundsMax, v.position)
        }

        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
            let indexBuffer = submesh.indexBuffer(asIndexType: .uInt32)
            let count = submesh.indexCount
            let indexMap = indexBuffer.map()
            let indices = indexMap.bytes.bindMemory(to: UInt32.self, capacity: count)
            merged.indices.reserveCapacity(merged.indices.count + count)
            for i in 0..<(count - count % 3) {
                merged.indices.append(indices[i] + base)
            }
        }
    }

    private static func upperLeft3x3(_ m: float4x4) -> float3x3 {
        float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                 SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                 SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }
}
