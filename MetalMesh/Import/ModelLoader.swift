import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import simd

/// 재질의 CPU 표현. baseColor만 다룬다.
struct MaterialData: @unchecked Sendable, Equatable {
    var name: String
    var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]
    /// sRGB baseColor 이미지. nil이면 색 계수만 쓴다.
    var baseColorImage: CGImage?

    static let `default` = MaterialData(name: "default")

    static func == (a: MaterialData, b: MaterialData) -> Bool {
        a.name == b.name && a.baseColorFactor == b.baseColorFactor && a.baseColorImage === b.baseColorImage
    }
}

/// 렌더링용 중간 표현. 모든 서브메시를 하나의 삼각형 리스트로 병합한 결과.
struct MeshData: @unchecked Sendable {
    var vertices: [Vertex]
    var indices: [UInt32]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    /// 최소 1개. 인덱스 0은 기본 재질.
    var materials: [MaterialData]
    /// 삼각형별 재질 인덱스. 비어 있으면 모두 0.
    var triangleMaterials: [UInt32]

    init(vertices: [Vertex], indices: [UInt32], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>,
         materials: [MaterialData] = [.default], triangleMaterials: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.materials = materials.isEmpty ? [.default] : materials
        self.triangleMaterials = triangleMaterials
    }

    var triangleCount: Int { indices.count / 3 }

    func materialIndex(ofTriangle t: Int) -> UInt32 {
        t < triangleMaterials.count ? triangleMaterials[t] : 0
    }
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
        if url.pathExtension.lowercased() == "usdz" {
            // 아카이브 내장 텍스처는 파일 경로로 열 수 없어 Model I/O에 풀어 달라고 요청한다
            asset.loadTextures()
        }

        var merged = MeshData(vertices: [], indices: [],
                              boundsMin: SIMD3(repeating: .greatestFiniteMagnitude),
                              boundsMax: SIMD3(repeating: -.greatestFiniteMagnitude))
        var materialCache = MaterialCache(assetDirectory: url.deletingLastPathComponent())

        for index in 0..<asset.count {
            visit(asset.object(at: index), parentTransform: matrix_identity_float4x4, into: &merged, materials: &materialCache)
        }
        guard !merged.indices.isEmpty else { throw ModelLoaderError.noTriangles }
        merged.materials = materialCache.materials
        if merged.triangleMaterials.allSatisfy({ $0 == 0 }) { merged.triangleMaterials = [] }
        return merged
    }

    // MARK: - 재질

    /// 같은 텍스처/색을 쓰는 서브메시 재질을 하나로 합친다.
    private struct MaterialCache {
        let assetDirectory: URL
        private(set) var materials: [MaterialData] = [.default]
        private var indexByKey: [String: UInt32] = [:]

        init(assetDirectory: URL) { self.assetDirectory = assetDirectory }

        mutating func index(for mdlMaterial: MDLMaterial?) -> UInt32 {
            guard let mdlMaterial else { return 0 }
            // baseColor 의미의 속성이 여러 개일 수 있다(예: USD의 상수 baseColor + 텍스처 diffuseColor).
            // 텍스처가 있는 속성을 우선하고, 없으면 상수 색을 쓴다.
            let candidates = (0..<mdlMaterial.count).compactMap { mdlMaterial[$0] }.filter { $0.semantic == .baseColor }
            guard !candidates.isEmpty else { return 0 }

            var data = MaterialData(name: mdlMaterial.name)
            var key = ""
            for property in candidates {
                if let (image, imageKey) = image(from: property) {
                    data.baseColorImage = image
                    key = imageKey
                    break
                }
            }
            if data.baseColorImage == nil {
                for property in candidates {
                    if let color = constantColor(from: property) {
                        data.baseColorFactor = color
                        key = "color:\(color)"
                        break
                    }
                }
            }
            if data.baseColorImage == nil && data.baseColorFactor == [1, 1, 1, 1] { return 0 }
            if let existing = indexByKey[key] { return existing }
            let index = UInt32(materials.count)
            materials.append(data)
            indexByKey[key] = index
            return index
        }

        private func image(from property: MDLMaterialProperty) -> (CGImage, String)? {
            switch property.type {
            case .texture:
                guard let texture = property.textureSamplerValue?.texture,
                      let image = texture.imageFromTexture()?.takeUnretainedValue() else { return nil }
                let key = property.stringValue.flatMap { $0.isEmpty ? nil : "str:\($0)" }
                    ?? property.urlValue.map { "url:\($0.absoluteString)" }
                    ?? "tex:\(ObjectIdentifier(texture).hashValue)"
                return (image, key)
            case .URL:
                guard let url = property.urlValue, let image = loadImage(at: url) else { return nil }
                return (image, "url:\(url.absoluteString)")
            case .string:
                guard let path = property.stringValue, !path.isEmpty else { return nil }
                let url = URL(fileURLWithPath: path, relativeTo: assetDirectory)
                guard let image = loadImage(at: url) else { return nil }
                return (image, "url:\(url.absoluteString)")
            default:
                return nil
            }
        }

        private func constantColor(from property: MDLMaterialProperty) -> SIMD4<Float>? {
            switch property.type {
            case .float3: let c = property.float3Value; return [c.x, c.y, c.z, 1]
            case .float4: return property.float4Value
            case .color:
                guard let c = property.color?.components, c.count >= 3 else { return nil }
                return [Float(c[0]), Float(c[1]), Float(c[2]), c.count > 3 ? Float(c[3]) : 1]
            default: return nil
            }
        }

        private func loadImage(at url: URL) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
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

    private static func visit(_ object: MDLObject, parentTransform: float4x4, into merged: inout MeshData, materials: inout MaterialCache) {
        let local = object.transform?.matrix ?? matrix_identity_float4x4
        let world = parentTransform * local
        if let mesh = object as? MDLMesh {
            append(mesh, transform: world, into: &merged, materials: &materials)
        }
        for child in object.children.objects {
            visit(child, parentTransform: world, into: &merged, materials: &materials)
        }
    }

    private static func append(_ mesh: MDLMesh, transform: float4x4, into merged: inout MeshData, materials: inout MaterialCache) {
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
            let materialIndex = materials.index(for: submesh.material)
            let triangleCount = count / 3
            merged.indices.reserveCapacity(merged.indices.count + count)
            merged.triangleMaterials.reserveCapacity(merged.triangleMaterials.count + triangleCount)
            for i in 0..<(triangleCount * 3) {
                merged.indices.append(indices[i] + base)
            }
            merged.triangleMaterials.append(contentsOf: repeatElement(materialIndex, count: triangleCount))
        }
    }

    private static func upperLeft3x3(_ m: float4x4) -> float3x3 {
        float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                 SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                 SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }
}
