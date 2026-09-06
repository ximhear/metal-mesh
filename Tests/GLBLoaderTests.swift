import Testing
import Foundation
import simd
@testable import MetalMesh
@testable import MeshCore

struct GLBLoaderTests {
    private func sampleURL(_ relative: String) throws -> URL {
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        return samples.appendingPathComponent(relative)
    }

    /// 최소 .gltf(JSON + data: URI 버퍼) 작성: 삼각형 2개짜리 사각형, 노멀 없음, ushort 인덱스
    private func writeQuadGLTF(strip: Bool = false, edit: ((inout [String: Any]) throws -> Void)? = nil) throws -> URL {
        var bin = Data()
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]
        positions.withUnsafeBytes { bin.append(contentsOf: $0) }
        let uvs: [Float] = [0, 1, 1, 1, 1, 0, 0, 0]
        uvs.withUnsafeBytes { bin.append(contentsOf: $0) }
        let indices: [UInt16] = strip ? [0, 1, 3, 2] : [0, 1, 2, 0, 2, 3]
        indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        let json = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
         "nodes":[{"mesh":0,"translation":[10,0,0],"scale":[2,2,2]}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0,"mode":\(strip ? 5 : 4)}]}],
         "materials":[{"name":"red","pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1]}}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
                      {"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},
                      {"bufferView":2,"componentType":5123,"count":\(indices.count),"type":"SCALAR"}],
         "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},{"buffer":0,"byteOffset":80,"byteLength":\(indices.count * 2)}],
         "buffers":[{"byteLength":\(bin.count),"uri":"data:application/octet-stream;base64,\(bin.base64EncodedString())"}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quad-\(UUID().uuidString).gltf")
        var document = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        try edit?(&document)
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return url
    }

    private func expectRejected(_ edit: @escaping (inout [String: Any]) throws -> Void) throws {
        let url = try writeQuadGLTF(edit: edit)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: GLBLoaderError.self) { try GLBLoader.load(url: url) }
    }

    @Test(arguments: [-1, Int.max])
    func rejectsInvalidReferences(index: Int) throws {
        try expectRejected { $0["scene"] = index }
        try expectRejected { $0["scenes"] = [["nodes": [index]]] }
        try expectRejected { $0["nodes"] = [["mesh": index]] }
        try expectRejected { $0["nodes"] = [["children": [index]]] }
        try expectRejected {
            $0["meshes"] = [["primitives": [["attributes": ["POSITION": index]]]]]
        }
        try expectRejected {
            $0["materials"] = [["pbrMetallicRoughness": ["baseColorTexture": ["index": index]]]]
        }
        try expectRejected {
            $0["textures"] = [["source": index]]
        }
        try expectRejected {
            $0["images"] = [["bufferView": index]]
        }
        try expectRejected {
            var views = try #require($0["bufferViews"] as? [[String: Any]])
            views[0]["buffer"] = index
            $0["bufferViews"] = views
        }
        try expectRejected {
            var accessors = try #require($0["accessors"] as? [[String: Any]])
            accessors[0]["bufferView"] = index
            $0["accessors"] = accessors
        }
    }

    @Test(arguments: ["count", "byteOffset"])
    func rejectsInvalidAccessorRanges(field: String) throws {
        for accessorIndex in [0, 2] {
            for value in [-1, Int.max] {
                try expectRejected {
                    var accessors = try #require($0["accessors"] as? [[String: Any]])
                    accessors[accessorIndex][field] = value
                    $0["accessors"] = accessors
                }
            }
        }
    }

    @Test(arguments: ["byteLength", "byteOffset", "byteStride"])
    func rejectsInvalidBufferViewRanges(field: String) throws {
        for value in [-1, Int.max] {
            try expectRejected {
                var views = try #require($0["bufferViews"] as? [[String: Any]])
                views[0][field] = value
                $0["bufferViews"] = views
            }
        }
        if field == "byteStride" {
            try expectRejected {
                var views = try #require($0["bufferViews"] as? [[String: Any]])
                views[0][field] = 4
                $0["bufferViews"] = views
            }
        }
    }

    @Test(arguments: [5120, 5122, 5126])
    func rejectsInvalidIndexComponentTypes(componentType: Int) throws {
        try expectRejected {
            var accessors = try #require($0["accessors"] as? [[String: Any]])
            accessors[2]["componentType"] = componentType
            $0["accessors"] = accessors
        }
    }

    @Test func rejectsInvalidTrianglesWithoutRegroupingIndices() throws {
        try expectRejected {
            var buffers = try #require($0["buffers"] as? [[String: Any]])
            let uri = try #require(buffers[0]["uri"] as? String)
            let payload = try #require(uri.split(separator: ",").last)
            var data = try #require(Data(base64Encoded: String(payload)))
            data[80] = 99
            buffers[0]["uri"] = "data:application/octet-stream;base64," + data.base64EncodedString()
            $0["buffers"] = buffers
        }
        try expectRejected {
            var accessors = try #require($0["accessors"] as? [[String: Any]])
            accessors[2]["count"] = 5
            $0["accessors"] = accessors
        }
    }

    @Test func rejectsNodeCyclesAndShortDeclaredBuffers() throws {
        try expectRejected { $0["nodes"] = [["mesh": 0, "children": [0]]] }
        try expectRejected { $0["nodes"] = [["children": [1, 1]], ["mesh": 0]] }
        try expectRejected { $0["nodes"] = [["mesh": 0, "translation": [0, 1]]] }
        try expectRejected {
            var buffers = try #require($0["buffers"] as? [[String: Any]])
            buffers[0]["byteLength"] = 4
            $0["buffers"] = buffers
        }
    }

    @Test func rejectsNonFiniteVertexAttributes() throws {
        try expectRejected {
            var buffers = try #require($0["buffers"] as? [[String: Any]])
            let uri = try #require(buffers[0]["uri"] as? String)
            let payload = try #require(uri.split(separator: ",").last)
            var data = try #require(Data(base64Encoded: String(payload)))
            var value = Float.nan
            withUnsafeBytes(of: &value) { data.replaceSubrange(0..<4, with: $0) }
            buffers[0]["uri"] = "data:application/octet-stream;base64," + data.base64EncodedString()
            $0["buffers"] = buffers
        }
    }

    @Test func rejectsMismatchedGLBLength() throws {
        let source = try sampleURL("Duck/Duck.glb")
        var data = try Data(contentsOf: source)
        data.append(0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-length-\(UUID()).glb")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        #expect(throws: GLBLoaderError.self) { try GLBLoader.load(url: url) }
    }

    @Test func parsesMinimalGLTFWithTransformsAndGeneratedNormals() throws {
        let url = try writeQuadGLTF()
        defer { try? FileManager.default.removeItem(at: url) }
        let mesh = try GLBLoader.load(url: url)
        #expect(mesh.vertices.count == 4)
        #expect(mesh.triangleCount == 2)
        // translation(10,0,0) * scale 2 → x ∈ [10, 12]
        #expect(abs(mesh.boundsMin.x - 10) < 1e-5 && abs(mesh.boundsMax.x - 12) < 1e-5)
        #expect(mesh.vertices.allSatisfy { abs(simd_length($0.normal) - 1) < 1e-4 })
        #expect(abs(mesh.vertices[0].normal.z) > 0.99, "평면 사각형 → ±z 노멀")
        // glTF v(좌상단) → 내부 규약(좌하단)으로 뒤집힘: 입력 v=1 → 0
        #expect(abs(mesh.vertices[0].uv.y - 0) < 1e-6 && abs(mesh.vertices[2].uv.y - 1) < 1e-6)
        #expect(mesh.materials.count == 2)
        #expect(mesh.materials[1].baseColorFactor == [1, 0, 0, 1])
        #expect(mesh.triangleMaterials == [1, 1])
    }

    @Test func triangleStripIsTriangulated() throws {
        let url = try writeQuadGLTF(strip: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let mesh = try GLBLoader.load(url: url)
        #expect(mesh.triangleCount == 2)
    }

    @Test func rejectsBadMagic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).glb")
        try Data(repeating: 0, count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: GLBLoaderError.self) { try GLBLoader.load(url: url) }
    }

    @Test func loadsKhronosDuckWithTexture() async throws {
        let mesh = try await ModelLoader.load(url: try sampleURL("Duck/Duck.glb"))
        #expect(mesh.triangleCount > 1_000)
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertices.count })
        let textured = mesh.materials.filter { $0.baseColorImage != nil }
        #expect(textured.count == 1)
        let meshlets = MeshletBuilder.build(mesh)
        #expect(meshlets.triangleCount == mesh.triangleCount)
    }

    @Test func avocadoHasMetallicRoughnessAndNormal() async throws {
        let mesh = try await ModelLoader.load(url: try sampleURL("Avocado/Avocado.glb"))
        let m = try #require(mesh.materials.first { $0.baseColorImage != nil })
        #expect(m.roughnessImage != nil && m.roughnessChannel == 1)
        #expect(m.metallicImage != nil && m.metallicChannel == 2)
        #expect(m.roughnessImage === m.metallicImage, "glTF는 한 텍스처를 공유")
        #expect(m.normalImage != nil)
    }

    @Test func loadsPolyPizzaBunny() async throws {
        let mesh = try await ModelLoader.load(url: try sampleURL("polypizza-bunny/polypizza-bunny.glb"))
        #expect(mesh.triangleCount > 100)
        #expect(mesh.materials.count >= 1)
    }

    @Test func probeReportsGLBStats() async throws {
        let stats = try #require(await ModelProbe.stats(for: try sampleURL("Duck/Duck.glb")))
        #expect(stats.triangleCount > 1_000)
        #expect(ModelProbe.supportedExtensions.contains("glb"))
    }
}
