import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import simd

/// 재질의 CPU 표현. baseColor만 다룬다.
public struct MaterialData: @unchecked Sendable, Equatable {
    public var name: String
    public var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]
    /// sRGB baseColor 이미지. nil이면 색 계수만 쓴다.
    public var baseColorImage: CGImage?
    /// 탄젠트 공간 노멀 맵 (OpenGL 규약, +Y 위). 선형.
    public var normalImage: CGImage?
    public var normalScale: Float = 1
    /// 러프니스 텍스처와 읽을 채널 (0=R,1=G,2=B). glTF는 metallicRoughness 텍스처의 G.
    public var roughnessImage: CGImage?
    public var roughnessChannel: Int = 0
    public var roughnessFactor: Float = 1
    /// 메탈릭 텍스처와 채널. glTF는 metallicRoughness 텍스처의 B.
    public var metallicImage: CGImage?
    public var metallicChannel: Int = 0
    public var metallicFactor: Float = 0

    public init(name: String, baseColorFactor: SIMD4<Float> = [1, 1, 1, 1], baseColorImage: CGImage? = nil) {
        self.name = name; self.baseColorFactor = baseColorFactor; self.baseColorImage = baseColorImage
    }

    /// 텍스처 없는 회색·비금속 기본 재질 (러프니스 0.6)
    public static let `default`: MaterialData = {
        var m = MaterialData(name: "default")
        m.roughnessFactor = 0.6
        return m
    }()

    public var hasAnyTexture: Bool {
        baseColorImage != nil || normalImage != nil || roughnessImage != nil || metallicImage != nil
    }

    public static func == (a: MaterialData, b: MaterialData) -> Bool {
        a.name == b.name && a.baseColorFactor == b.baseColorFactor && a.baseColorImage === b.baseColorImage
            && a.normalImage === b.normalImage && a.roughnessImage === b.roughnessImage && a.metallicImage === b.metallicImage
            && a.roughnessFactor == b.roughnessFactor && a.metallicFactor == b.metallicFactor
    }
}

/// 렌더링용 중간 표현. 모든 서브메시를 하나의 삼각형 리스트로 병합한 결과.
public struct MeshData: @unchecked Sendable {
    public var vertices: [Vertex]
    public var indices: [UInt32]
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
    /// 최소 1개. 인덱스 0은 기본 재질.
    public var materials: [MaterialData]
    /// 삼각형별 재질 인덱스. 비어 있으면 모두 0.
    public var triangleMaterials: [UInt32]

    public init(vertices: [Vertex], indices: [UInt32], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>,
         materials: [MaterialData] = [.default], triangleMaterials: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.materials = materials.isEmpty ? [.default] : materials
        self.triangleMaterials = triangleMaterials
    }

    public var triangleCount: Int { indices.count / 3 }

    public func materialIndex(ofTriangle t: Int) -> UInt32 {
        t < triangleMaterials.count ? triangleMaterials[t] : 0
    }
    public var boundsCenter: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    public var boundsRadius: Float { simd_length(boundsMax - boundsMin) * 0.5 }
}

public enum ModelLoaderError: LocalizedError {
    case unsupportedExtension(String)
    case openFailed(String)
    case noTriangles

    public var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext): return "지원하지 않는 형식입니다: .\(ext)"
        case .openFailed(let reason): return "파일을 열 수 없습니다: \(reason)"
        case .noTriangles: return "삼각형 메시가 없습니다."
        }
    }
}

/// Model I/O로 파일을 읽어 `Vertex` 레이아웃(position/normal/uv/tangent, stride 64)으로 정규화한다.
/// 노드 변환을 정점에 적용하고, 노멀이 없으면 생성한다. 폴리곤은 삼각형으로 분할된다.
public enum ModelLoader {
    /// Model I/O가 읽는 포맷 + 자체 glTF 로더 포맷
    public static let supportedExtensions: Set<String> = Set(["obj", "ply", "stl", "usd", "usda", "usdc", "usdz"]).union(GLBLoader.supportedExtensions)

    public static func load(url: URL) async throws -> MeshData {
        try Task.checkCancellation()
        if GLBLoader.canLoad(url) {
            // Model I/O를 쓰지 않으므로 직렬 큐가 필요 없다
            return try await BackgroundWork.run { try GLBLoader.load(url: url) }
        }
        let mesh = try await ModelIOQueue.shared.run {
            try Task.checkCancellation()
            return try loadSynchronously(url: url)
        }
        try Task.checkCancellation()
        return mesh
    }

    /// 테스트나 직렬 컨텍스트에서 직접 호출할 때 사용. 일반 코드는 `load(url:)`.
    public static func loadSynchronously(url: URL) throws -> MeshData {
        if GLBLoader.canLoad(url) { return try GLBLoader.load(url: url) }
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
        var needsNormals = false
        let upAxis = asset.upAxis
        let upLength = simd_length(upAxis)
        let axisTransform: float4x4
        if upLength.isFinite, upLength > 1e-6 {
            axisTransform = float4x4(simd_quatf(from: upAxis / upLength, to: SIMD3<Float>(0, 1, 0)))
        } else {
            axisTransform = matrix_identity_float4x4
        }

        for index in 0..<asset.count {
            visit(asset.object(at: index), parentTransform: axisTransform, into: &merged,
                  materials: &materialCache, needsNormals: &needsNormals)
        }
        guard !merged.indices.isEmpty else { throw ModelLoaderError.noTriangles }
        merged.materials = materialCache.materials
        if merged.triangleMaterials.allSatisfy({ $0 == 0 }) { merged.triangleMaterials = [] }

        // Model I/O는 서브메시/면 단위로 정점을 복제하는 일이 많다. 같은 정점을 합쳐 메시렛 정점 재사용률을 높인다.
        MeshPostProcess.weld(&merged, includeNormals: !needsNormals)
        if needsNormals { MeshPostProcess.computeSmoothNormals(&merged) }
        MeshPostProcess.computeTangents(&merged)
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
            let all = (0..<mdlMaterial.count).compactMap { mdlMaterial[$0] }
            var data = MaterialData(name: mdlMaterial.name)
            data.roughnessFactor = 0.6
            var key = ""

            // baseColor: 의미가 같은 속성이 여러 개일 수 있다(예: USD의 상수 baseColor + 텍스처 diffuseColor). 텍스처 우선.
            let baseCandidates = all.filter { $0.semantic == .baseColor }
            var baseColorURL: URL?
            for property in baseCandidates {
                if let (image, imageKey) = image(from: property) {
                    data.baseColorImage = image; key += imageKey
                    baseColorURL = fileURL(of: property)
                    break
                }
            }
            if data.baseColorImage == nil {
                for property in baseCandidates {
                    if let color = constantColor(from: property) { data.baseColorFactor = color; key += "color:\(color)"; break }
                }
            }
            // 러프니스 / 메탈릭: 텍스처면 R 채널, 아니면 스칼라
            if let p = all.first(where: { $0.semantic == .roughness }) {
                if let (image, k) = image(from: p) { data.roughnessImage = image; data.roughnessChannel = 0; data.roughnessFactor = 1; key += "|r:" + k }
                else if p.type == .float { data.roughnessFactor = p.floatValue; key += "|r:\(p.floatValue)" }
            }
            if let p = all.first(where: { $0.semantic == .metallic }) {
                if let (image, k) = image(from: p) { data.metallicImage = image; data.metallicChannel = 0; data.metallicFactor = 1; key += "|m:" + k }
                else if p.type == .float { data.metallicFactor = p.floatValue; key += "|m:\(p.floatValue)" }
            }
            if let p = all.first(where: { $0.semantic == .tangentSpaceNormal }), let (image, k) = image(from: p) {
                data.normalImage = image; key += "|n:" + k
            }
            // Model I/O가 USD의 roughness/metallic 텍스처 연결을 놓치는 경우(Poly Haven usdc: 빈 문자열)
            // baseColor 파일명 규칙(_diff_ → _rough_ / _metal_ / _nor_gl_)으로 이웃 파일을 찾는다.
            if let baseURL = baseColorURL {
                if data.roughnessImage == nil, let (image, url) = sibling(of: baseURL, replacing: "diff", withAny: ["rough", "roughness"]) {
                    data.roughnessImage = image; data.roughnessChannel = 0; data.roughnessFactor = 1; key += "|r:" + url
                }
                if data.metallicImage == nil, let (image, url) = sibling(of: baseURL, replacing: "diff", withAny: ["metal", "metallic"]) {
                    data.metallicImage = image; data.metallicChannel = 0; data.metallicFactor = 1; key += "|m:" + url
                }
                if data.normalImage == nil, let (image, url) = sibling(of: baseURL, replacing: "diff", withAny: ["nor_gl", "normal"]) {
                    data.normalImage = image; key += "|n:" + url
                }
            }

            // 텍스처도 색도 금속성도 없는 재질은 기본 재질로 합친다 (Model I/O가 OBJ에도 스칼라 러프니스를 붙이므로 러프니스는 무시)
            if !data.hasAnyTexture && data.baseColorFactor == [1, 1, 1, 1] && data.metallicFactor == 0 { return 0 }
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

        /// 텍스처 속성이 가리키는 파일 URL (있으면)
        private func fileURL(of property: MDLMaterialProperty) -> URL? {
            if let url = property.urlValue, url.isFileURL { return url }
            if let path = property.stringValue, !path.isEmpty { return URL(fileURLWithPath: path, relativeTo: assetDirectory) }
            return nil
        }

        /// 같은 폴더에서 파일명의 `token`을 `replacement`로 바꾼 이웃 텍스처 (확장자는 jpg/png/exr 순으로 시도)
        private func sibling(of url: URL, replacing token: String, withAny replacements: [String]) -> (CGImage, String)? {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.contains("_\(token)_") else { return nil }
            let dir = url.deletingLastPathComponent()
            for replacement in replacements {
                let stem = name.replacingOccurrences(of: "_\(token)_", with: "_\(replacement)_")
                for ext in [url.pathExtension, "jpg", "png"] where !ext.isEmpty {
                    let candidate = dir.appendingPathComponent(stem).appendingPathExtension(ext)
                    if FileManager.default.fileExists(atPath: candidate.path), let image = loadImage(at: candidate) {
                        return (image, candidate.absoluteString)
                    }
                }
            }
            return nil
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

    private static func visit(_ object: MDLObject, parentTransform: float4x4, into merged: inout MeshData,
                              materials: inout MaterialCache, needsNormals: inout Bool) {
        let local = object.transform?.matrix ?? matrix_identity_float4x4
        let world = parentTransform * local
        if let mesh = object as? MDLMesh {
            append(mesh, transform: world, into: &merged, materials: &materials, needsNormals: &needsNormals)
        }
        for child in object.children.objects {
            visit(child, parentTransform: world, into: &merged, materials: &materials, needsNormals: &needsNormals)
        }
    }

    private static func append(_ mesh: MDLMesh, transform: float4x4, into merged: inout MeshData,
                               materials: inout MaterialCache, needsNormals: inout Bool) {
        let hasNormals = (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute])?
            .contains { $0.name == MDLVertexAttributeNormal && $0.format != .invalid } ?? false
        // 노멀이 없으면 Model I/O의 addNormals 대신(면마다 정점을 쪼갠다) 용접 후 직접 계산한다
        if !hasNormals { needsNormals = true }
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
            v.tangent = .zero   // 버퍼에는 탄젠트 영역이 없다(후처리에서 계산)
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
