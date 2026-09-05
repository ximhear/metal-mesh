import Metal

/// 메시렛 메시의 GPU 버퍼 묶음
struct GPUMesh {
    let vertices: MTLBuffer
    let meshlets: MTLBuffer
    let meshletVertices: MTLBuffer
    let meshletTriangles: MTLBuffer
    let meshletCount: Int
    let vertexCount: Int
    let triangleCount: Int

    enum Error: LocalizedError {
        case empty
        case allocationFailed(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "메시렛이 없습니다."
            case .allocationFailed(let name): return "GPU 버퍼를 만들 수 없습니다: \(name)"
            }
        }
    }

    init(device: MTLDevice, mesh: MeshletMesh) throws {
        guard !mesh.meshlets.isEmpty, !mesh.vertices.isEmpty else { throw Error.empty }
        func make<T>(_ array: [T], _ name: String) throws -> MTLBuffer {
            let length = array.count * MemoryLayout<T>.stride
            guard let buffer = array.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: length, options: .storageModeShared)
            }) else { throw Error.allocationFailed(name) }
            buffer.label = name
            return buffer
        }
        vertices = try make(mesh.vertices, "vertices")
        meshlets = try make(mesh.meshlets, "meshlets")
        meshletVertices = try make(mesh.meshletVertices, "meshletVertices")
        // uchar 배열은 4바이트 정렬 보장을 위해 패딩
        var triangles = mesh.meshletTriangles
        while triangles.count % 4 != 0 { triangles.append(0) }
        meshletTriangles = try make(triangles, "meshletTriangles")
        meshletCount = mesh.meshlets.count
        vertexCount = mesh.vertices.count
        triangleCount = mesh.triangleCount
    }
}
