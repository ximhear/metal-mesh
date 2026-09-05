import CoreGraphics
import Foundation
import ImageIO
import simd

public enum GLBLoaderError: LocalizedError {
    case invalidContainer(String)
    case unsupported(String)
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidContainer(let why): return "glTF 파일이 손상되었습니다: \(why)"
        case .unsupported(let what): return "지원하지 않는 glTF 기능입니다: \(what)"
        case .missing(let what): return "glTF 데이터가 없습니다: \(what)"
        }
    }
}

/// 삼각형 메시 전용 최소 glTF 2.0 로더 (.glb 컨테이너, .gltf + 외부/data: URI).
/// 지원: 노드 변환, POSITION/NORMAL/TEXCOORD_0, 인덱스 유무, TRIANGLES/STRIP/FAN, pbrMetallicRoughness의 baseColor.
/// 미지원: Draco/meshopt 압축, sparse accessor, 스키닝, 애니메이션, 모프 타깃, KHR_texture_transform.
public enum GLBLoader {
    public static let supportedExtensions: Set<String> = ["glb", "gltf"]

    public static func canLoad(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func load(url: URL) throws -> MeshData {
        let fileData = try Data(contentsOf: url)
        let (jsonData, binChunk) = try splitContainer(fileData, isBinary: url.pathExtension.lowercased() == "glb")
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonData)

        if let required = gltf.extensionsRequired {
            let unsupported = required.filter { $0 != "KHR_materials_emissive_strength" && $0 != "KHR_mesh_quantization" }
            if !unsupported.isEmpty { throw GLBLoaderError.unsupported(unsupported.joined(separator: ", ")) }
        }

        var context = Context(gltf: gltf, binChunk: binChunk, baseURL: url.deletingLastPathComponent())
        var merged = MeshData(vertices: [], indices: [],
                              boundsMin: SIMD3(repeating: .greatestFiniteMagnitude),
                              boundsMax: SIMD3(repeating: -.greatestFiniteMagnitude))

        let roots: [Int]
        if let scenes = gltf.scenes, !scenes.isEmpty {
            roots = scenes[min(gltf.scene ?? 0, scenes.count - 1)].nodes ?? []
        } else {
            // 씬이 없으면 부모가 없는 노드 전부
            let all = gltf.nodes ?? []
            var hasParent = [Bool](repeating: false, count: all.count)
            for node in all { for child in node.children ?? [] where child < all.count { hasParent[child] = true } }
            roots = all.indices.filter { !hasParent[$0] }
        }
        var visited = Set<Int>()
        for root in roots {
            try visit(node: root, parent: matrix_identity_float4x4, context: &context, into: &merged, visited: &visited)
        }
        guard !merged.indices.isEmpty else { throw GLBLoaderError.missing("삼각형 메시") }
        merged.materials = context.materials
        if merged.triangleMaterials.allSatisfy({ $0 == 0 }) { merged.triangleMaterials = [] }
        return merged
    }

    // MARK: - 컨테이너

    /// GLB: 12바이트 헤더 + (JSON 청크, BIN 청크). glTF: 파일 전체가 JSON.
    private static func splitContainer(_ data: Data, isBinary: Bool) throws -> (json: Data, bin: Data?) {
        guard isBinary else { return (data, nil) }
        guard data.count >= 20 else { throw GLBLoaderError.invalidContainer("파일이 너무 작음") }
        func u32(_ offset: Int) -> UInt32 {
            data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        guard u32(0) == 0x4654_6C67 else { throw GLBLoaderError.invalidContainer("magic 'glTF' 아님") }
        guard u32(4) == 2 else { throw GLBLoaderError.unsupported("glTF 버전 \(u32(4))") }
        let total = min(Int(u32(8)), data.count)
        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= total {
            let length = Int(u32(offset))
            let type = u32(offset + 4)
            let start = offset + 8
            guard start + length <= total else { throw GLBLoaderError.invalidContainer("청크 길이 초과") }
            let chunk = data.subdata(in: start..<start + length)
            if type == 0x4E4F_534A { json = chunk }           // 'JSON'
            else if type == 0x004E_4942 { bin = chunk }       // 'BIN\0'
            offset = start + length
            offset += (4 - offset % 4) % 4
        }
        guard let json else { throw GLBLoaderError.invalidContainer("JSON 청크 없음") }
        return (json, bin)
    }

    // MARK: - 순회

    private struct Context {
        let gltf: GLTF
        let binChunk: Data?
        let baseURL: URL
        var bufferCache: [Int: Data] = [:]
        var materials: [MaterialData] = [.default]
        var materialIndexMap: [Int: UInt32] = [:]
        var imageCache: [Int: CGImage] = [:]

        init(gltf: GLTF, binChunk: Data?, baseURL: URL) {
            self.gltf = gltf; self.binChunk = binChunk; self.baseURL = baseURL
        }
    }

    private static func visit(node index: Int, parent: float4x4, context: inout Context, into merged: inout MeshData, visited: inout Set<Int>) throws {
        guard let nodes = context.gltf.nodes, index < nodes.count, !visited.contains(index) else { return }
        visited.insert(index)
        let node = nodes[index]
        let world = parent * localTransform(node)
        if let meshIndex = node.mesh, let meshes = context.gltf.meshes, meshIndex < meshes.count {
            for primitive in meshes[meshIndex].primitives {
                try append(primitive: primitive, transform: world, context: &context, into: &merged)
            }
        }
        for child in node.children ?? [] {
            try visit(node: child, parent: world, context: &context, into: &merged, visited: &visited)
        }
    }

    private static func localTransform(_ node: GLTF.Node) -> float4x4 {
        if let m = node.matrix, m.count == 16 {
            return float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                            SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
        }
        var result = matrix_identity_float4x4
        if let t = node.translation, t.count == 3 {
            result.columns.3 = SIMD4(t[0], t[1], t[2], 1)
        }
        if let r = node.rotation, r.count == 4 {
            result = result * float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
        }
        if let s = node.scale, s.count == 3 {
            result = result * float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
        }
        return result
    }

    // MARK: - 프리미티브

    private static func append(primitive: GLTF.Primitive, transform: float4x4, context: inout Context, into merged: inout MeshData) throws {
        if let ext = primitive.extensions, ext.keys.contains("KHR_draco_mesh_compression") {
            throw GLBLoaderError.unsupported("KHR_draco_mesh_compression")
        }
        let mode = primitive.mode ?? 4
        guard mode == 4 || mode == 5 || mode == 6 else { return }   // 점/선은 무시
        guard let positionAccessor = primitive.attributes["POSITION"] else { return }

        let positions = try readVectors(accessor: positionAccessor, context: &context).map { SIMD3($0.x, $0.y, $0.z) }
        guard !positions.isEmpty else { return }
        let normals = try primitive.attributes["NORMAL"].map { try readVectors(accessor: $0, context: &context).map { SIMD3($0.x, $0.y, $0.z) } }
        let uvs = try primitive.attributes["TEXCOORD_0"].map { try readVectors(accessor: $0, context: &context).map { SIMD2($0.x, $0.y) } }

        var localIndices: [UInt32]
        if let indexAccessor = primitive.indices {
            localIndices = try readIndices(accessor: indexAccessor, context: &context)
        } else {
            localIndices = (0..<UInt32(positions.count)).map { $0 }
        }
        localIndices = triangulate(localIndices, mode: mode).filter { Int($0) < positions.count ? true : false }
        let usable = localIndices.count - localIndices.count % 3
        guard usable >= 3 else { return }
        localIndices = Array(localIndices.prefix(usable))

        // 노멀 없으면 면 노멀 누적으로 생성
        let finalNormals: [SIMD3<Float>]
        if let normals, normals.count == positions.count {
            finalNormals = normals
        } else {
            var acc = [SIMD3<Float>](repeating: .zero, count: positions.count)
            for t in stride(from: 0, to: localIndices.count, by: 3) {
                let a = Int(localIndices[t]), b = Int(localIndices[t + 1]), c = Int(localIndices[t + 2])
                let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                acc[a] += n; acc[b] += n; acc[c] += n
            }
            finalNormals = acc.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        }

        let normalMatrix = simd_transpose(simd_inverse(Math.upperLeft3x3(transform)))
        let base = UInt32(merged.vertices.count)
        merged.vertices.reserveCapacity(merged.vertices.count + positions.count)
        for i in 0..<positions.count {
            var v = Vertex()
            let p = transform * SIMD4(positions[i], 1)
            v.position = SIMD3(p.x, p.y, p.z) / (p.w == 0 ? 1 : p.w)
            let n = normalMatrix * finalNormals[i]
            v.normal = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
            // glTF UV는 좌상단 원점. 셰이더가 Model I/O 규약(좌하단)으로 v를 뒤집으므로 여기서 미리 맞춘다.
            if let uvs, i < uvs.count { v.uv = SIMD2(uvs[i].x, 1 - uvs[i].y) }
            merged.vertices.append(v)
            merged.boundsMin = simd_min(merged.boundsMin, v.position)
            merged.boundsMax = simd_max(merged.boundsMax, v.position)
        }

        let materialIndex = try materialIndex(for: primitive.material, context: &context)
        let triangleCount = localIndices.count / 3
        merged.indices.reserveCapacity(merged.indices.count + localIndices.count)
        for index in localIndices { merged.indices.append(index + base) }
        merged.triangleMaterials.append(contentsOf: repeatElement(materialIndex, count: triangleCount))
    }

    private static func triangulate(_ indices: [UInt32], mode: Int) -> [UInt32] {
        switch mode {
        case 5: // TRIANGLE_STRIP
            guard indices.count >= 3 else { return [] }
            var out: [UInt32] = []
            for i in 0..<(indices.count - 2) {
                if i % 2 == 0 { out += [indices[i], indices[i + 1], indices[i + 2]] }
                else { out += [indices[i + 1], indices[i], indices[i + 2]] }
            }
            return out
        case 6: // TRIANGLE_FAN
            guard indices.count >= 3 else { return [] }
            var out: [UInt32] = []
            for i in 1..<(indices.count - 1) { out += [indices[0], indices[i], indices[i + 1]] }
            return out
        default:
            return indices
        }
    }

    // MARK: - 재질

    private static func materialIndex(for gltfIndex: Int?, context: inout Context) throws -> UInt32 {
        guard let gltfIndex, let materials = context.gltf.materials, gltfIndex < materials.count else { return 0 }
        if let cached = context.materialIndexMap[gltfIndex] { return cached }
        let material = materials[gltfIndex]
        var data = MaterialData(name: material.name ?? "material\(gltfIndex)")
        if let f = material.pbrMetallicRoughness?.baseColorFactor, f.count == 4 {
            data.baseColorFactor = SIMD4(f[0], f[1], f[2], f[3])
        }
        if let texInfo = material.pbrMetallicRoughness?.baseColorTexture, (texInfo.texCoord ?? 0) == 0,
           let textures = context.gltf.textures, texInfo.index < textures.count,
           let source = textures[texInfo.index].source {
            data.baseColorImage = try image(index: source, context: &context)
        }
        let index: UInt32
        if data.baseColorImage == nil && data.baseColorFactor == [1, 1, 1, 1] {
            index = 0
        } else {
            index = UInt32(context.materials.count)
            context.materials.append(data)
        }
        context.materialIndexMap[gltfIndex] = index
        return index
    }

    private static func image(index: Int, context: inout Context) throws -> CGImage? {
        if let cached = context.imageCache[index] { return cached }
        guard let images = context.gltf.images, index < images.count else { return nil }
        let image = images[index]
        var data: Data?
        if let viewIndex = image.bufferView {
            data = try bufferViewData(viewIndex, context: &context)
        } else if let uri = image.uri {
            data = try resolveURI(uri, context: &context)
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        context.imageCache[index] = cgImage
        return cgImage
    }

    // MARK: - 버퍼/접근자

    private static func resolveURI(_ uri: String, context: inout Context) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else { throw GLBLoaderError.invalidContainer("data URI") }
            let payload = String(uri[uri.index(after: comma)...])
            guard let decoded = Data(base64Encoded: payload) else { throw GLBLoaderError.invalidContainer("base64") }
            return decoded
        }
        let decoded = uri.removingPercentEncoding ?? uri
        return try Data(contentsOf: context.baseURL.appendingPathComponent(decoded))
    }

    private static func bufferData(_ index: Int, context: inout Context) throws -> Data {
        if let cached = context.bufferCache[index] { return cached }
        guard let buffers = context.gltf.buffers, index < buffers.count else { throw GLBLoaderError.missing("buffer \(index)") }
        let data: Data
        if let uri = buffers[index].uri {
            data = try resolveURI(uri, context: &context)
        } else if let bin = context.binChunk {
            data = bin
        } else {
            throw GLBLoaderError.missing("BIN 청크")
        }
        context.bufferCache[index] = data
        return data
    }

    private static func bufferViewData(_ index: Int, context: inout Context) throws -> Data {
        guard let views = context.gltf.bufferViews, index < views.count else { throw GLBLoaderError.missing("bufferView \(index)") }
        let view = views[index]
        let buffer = try bufferData(view.buffer, context: &context)
        let start = view.byteOffset ?? 0
        guard start + view.byteLength <= buffer.count else { throw GLBLoaderError.invalidContainer("bufferView 범위") }
        return buffer.subdata(in: start..<start + view.byteLength)
    }

    private static func componentSize(_ type: Int) -> Int? {
        switch type {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    private static func componentCount(_ type: String) -> Int? {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        default: return nil
        }
    }

    /// 접근자를 float 벡터(부족한 성분은 0)로 읽는다. 정규화 정수 포맷 지원.
    private static func readVectors(accessor index: Int, context: inout Context) throws -> [SIMD4<Float>] {
        guard let accessors = context.gltf.accessors, index < accessors.count else { throw GLBLoaderError.missing("accessor \(index)") }
        let accessor = accessors[index]
        if accessor.sparse != nil { throw GLBLoaderError.unsupported("sparse accessor") }
        guard let compSize = componentSize(accessor.componentType), let compCount = componentCount(accessor.type) else {
            throw GLBLoaderError.unsupported("accessor type \(accessor.type)/\(accessor.componentType)")
        }
        guard let viewIndex = accessor.bufferView else {
            return [SIMD4<Float>](repeating: .zero, count: accessor.count)
        }
        let view = try bufferViewData(viewIndex, context: &context)
        let stride = context.gltf.bufferViews![viewIndex].byteStride ?? compSize * compCount
        let start = accessor.byteOffset ?? 0
        guard accessor.count == 0 || start + (accessor.count - 1) * stride + compSize * compCount <= view.count else {
            throw GLBLoaderError.invalidContainer("accessor 범위")
        }
        let normalized = accessor.normalized ?? false
        var out = [SIMD4<Float>](repeating: .zero, count: accessor.count)
        view.withUnsafeBytes { raw in
            for i in 0..<accessor.count {
                var v = SIMD4<Float>.zero
                for c in 0..<compCount {
                    let offset = start + i * stride + c * compSize
                    v[c] = readComponent(raw, offset: offset, type: accessor.componentType, normalized: normalized)
                }
                out[i] = v
            }
        }
        return out
    }

    private static func readComponent(_ raw: UnsafeRawBufferPointer, offset: Int, type: Int, normalized: Bool) -> Float {
        switch type {
        case 5126: return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
        case 5120: let v = raw.loadUnaligned(fromByteOffset: offset, as: Int8.self);  return normalized ? max(Float(v) / 127, -1) : Float(v)
        case 5121: let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self); return normalized ? Float(v) / 255 : Float(v)
        case 5122: let v = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self); return normalized ? max(Float(v) / 32767, -1) : Float(v)
        case 5123: let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self); return normalized ? Float(v) / 65535 : Float(v)
        case 5125: return Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        default: return 0
        }
    }

    private static func readIndices(accessor index: Int, context: inout Context) throws -> [UInt32] {
        guard let accessors = context.gltf.accessors, index < accessors.count else { throw GLBLoaderError.missing("accessor \(index)") }
        let accessor = accessors[index]
        if accessor.sparse != nil { throw GLBLoaderError.unsupported("sparse accessor") }
        guard let compSize = componentSize(accessor.componentType), accessor.type == "SCALAR" else {
            throw GLBLoaderError.unsupported("index accessor \(accessor.type)")
        }
        guard let viewIndex = accessor.bufferView else { throw GLBLoaderError.missing("index bufferView") }
        let view = try bufferViewData(viewIndex, context: &context)
        let stride = context.gltf.bufferViews![viewIndex].byteStride ?? compSize
        let start = accessor.byteOffset ?? 0
        guard accessor.count == 0 || start + (accessor.count - 1) * stride + compSize <= view.count else {
            throw GLBLoaderError.invalidContainer("index accessor 범위")
        }
        var out = [UInt32](repeating: 0, count: accessor.count)
        view.withUnsafeBytes { raw in
            for i in 0..<accessor.count {
                let offset = start + i * stride
                switch accessor.componentType {
                case 5121: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                case 5123: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                default:   out[i] = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }
            }
        }
        return out
    }

    // MARK: - JSON 스키마 (필요한 필드만)

    private struct GLTF: Decodable {
        struct Scene: Decodable { var nodes: [Int]? }
        struct Node: Decodable {
            var mesh: Int?; var children: [Int]?
            var matrix: [Float]?; var translation: [Float]?; var rotation: [Float]?; var scale: [Float]?
        }
        struct Mesh: Decodable { var primitives: [Primitive] }
        struct Empty: Decodable {}
        struct Primitive: Decodable {
            var attributes: [String: Int]; var indices: Int?; var material: Int?; var mode: Int?
            var extensions: [String: Empty]?
        }
        struct Accessor: Decodable {
            var bufferView: Int?; var byteOffset: Int?; var componentType: Int; var count: Int; var type: String
            var normalized: Bool?; var sparse: Empty?
        }
        struct BufferView: Decodable { var buffer: Int; var byteOffset: Int?; var byteLength: Int; var byteStride: Int? }
        struct Buffer: Decodable { var byteLength: Int; var uri: String? }
        struct TextureInfo: Decodable { var index: Int; var texCoord: Int? }
        struct PBR: Decodable { var baseColorFactor: [Float]?; var baseColorTexture: TextureInfo? }
        struct Material: Decodable { var name: String?; var pbrMetallicRoughness: PBR? }
        struct Texture: Decodable { var source: Int? }
        struct Image: Decodable { var uri: String?; var bufferView: Int?; var mimeType: String? }

        var scene: Int?
        var scenes: [Scene]?
        var nodes: [Node]?
        var meshes: [Mesh]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
        var materials: [Material]?
        var textures: [Texture]?
        var images: [Image]?
        var extensionsRequired: [String]?
    }
}
