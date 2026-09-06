import Testing
import Foundation
@testable import MetalMesh
@testable import MeshCore

@MainActor
struct ModelLibraryTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTriangleOBJ(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("\(name).obj")
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importCopiesGLTFBuffersAndTextures() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("buffers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("textures"), withIntermediateDirectories: true)
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        try positions.withUnsafeBytes { try Data($0).write(to: source.appendingPathComponent("buffers/triangle data.bin")) }
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        try FileManager.default.copyItem(at: samples.appendingPathComponent("food_apple_01/textures/food_apple_01_diff_1k.jpg"),
                                        to: source.appendingPathComponent("textures/color.jpg"))
        let model = source.appendingPathComponent("triangle.gltf")
        let json = """
        {"asset":{"version":"2.0"},"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
         "bufferViews":[{"buffer":0,"byteLength":36}],
         "buffers":[{"byteLength":36,"uri":"buffers/triangle%20data.bin"}],
         "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
         "textures":[{"source":0}],"images":[{"uri":"textures/color.jpg"}]}
        """
        try json.write(to: model, atomically: true, encoding: .utf8)
        let library = ModelLibrary(rootDirectory: root.appendingPathComponent("Library"))
        let entry = try await library.importFile(from: model)
        let imported = try #require(library.fileURL(for: entry))
        try FileManager.default.removeItem(at: source)
        let mesh = try await ModelLoader.load(url: imported)
        #expect(mesh.triangleCount == 1)
        #expect(mesh.materials.contains { $0.baseColorImage != nil })
    }

    @Test func importCopiesOBJMaterialsAndMapOptions() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("materials"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("textures"), withIntermediateDirectories: true)
        let model = try writeTriangleOBJ(named: "triangle", in: source)
        let original = try String(contentsOf: model, encoding: .utf8)
        try ("mtllib materials/surface.mtl\n" + original).write(to: model, atomically: true, encoding: .utf8)
        let material = "newmtl surface\nmap_Kd -s 1 1 1 -clamp on \"../textures/base color.jpg\"\n"
        try material.write(to: source.appendingPathComponent("materials/surface.mtl"), atomically: true, encoding: .utf8)
        let pixels = Data([1, 2, 3, 4])
        try pixels.write(to: source.appendingPathComponent("textures/base color.jpg"))
        let library = ModelLibrary(rootDirectory: root.appendingPathComponent("Library"))
        let entry = try await library.importFile(from: model)
        let folder = try #require(library.fileURL(for: entry)).deletingLastPathComponent()
        #expect(try String(contentsOf: folder.appendingPathComponent("materials/surface.mtl"), encoding: .utf8) == material)
        #expect(try Data(contentsOf: folder.appendingPathComponent("textures/base color.jpg")) == pixels)
    }

    @Test func missingDependencyLeavesNoEntryOrPartialImport() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeTriangleOBJ(named: "triangle", in: root)
        let original = try String(contentsOf: source, encoding: .utf8)
        try ("mtllib missing.mtl\n" + original).write(to: source, atomically: true, encoding: .utf8)
        let libraryRoot = root.appendingPathComponent("Library")
        let library = ModelLibrary(rootDirectory: libraryRoot)
        await #expect(throws: ModelLibrary.LibraryError.self) { try await library.importFile(from: source) }
        #expect(library.entries.isEmpty)
        let remaining = try? FileManager.default.contentsOfDirectory(atPath: libraryRoot.appendingPathComponent("Models").path)
        #expect(remaining?.isEmpty ?? true)
    }

    @Test func folderImportPreservesSharedResourcesUntilLastModelIsDeleted() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try writeTriangleOBJ(named: "first", in: source)
        let second = try writeTriangleOBJ(named: "second", in: nested)
        let original = try String(contentsOf: second, encoding: .utf8)
        try ("mtllib ../shared.mtl\n" + original).write(to: second, atomically: true, encoding: .utf8)
        try "newmtl shared\nKd 1 0 0\n".write(to: source.appendingPathComponent("shared.mtl"), atomically: true, encoding: .utf8)
        let libraryRoot = root.appendingPathComponent("Library")
        let library = ModelLibrary(rootDirectory: libraryRoot)
        let entries = try await library.importFolder(from: source)
        #expect(entries.count == 2)
        let firstEntry = try #require(entries.first { $0.name == "first" })
        let secondEntry = try #require(entries.first { $0.name == "second" })
        let firstURL = try #require(library.fileURL(for: firstEntry))
        let secondURL = try #require(library.fileURL(for: secondEntry))
        try FileManager.default.removeItem(at: source)
        library.delete(firstEntry)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().appendingPathComponent("shared.mtl").path))
        let reloaded = ModelLibrary(rootDirectory: libraryRoot)
        reloaded.load()
        #expect(reloaded.entry(id: firstEntry.id) == nil)
        #expect(reloaded.entry(id: secondEntry.id) != nil)
        let mesh = try await ModelLoader.load(url: secondURL)
        #expect(mesh.triangleCount == 1)
        reloaded.delete(secondEntry)
        #expect(!FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path))
    }

    @Test func rejectsReferencesOutsideSelectedFolder() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let model = try writeTriangleOBJ(named: "triangle", in: source)
        let original = try String(contentsOf: model, encoding: .utf8)
        try ("mtllib ../outside.mtl\n" + original).write(to: model, atomically: true, encoding: .utf8)
        try "newmtl outside\n".write(to: root.appendingPathComponent("outside.mtl"), atomically: true, encoding: .utf8)
        let library = ModelLibrary(rootDirectory: root.appendingPathComponent("Library"))
        await #expect(throws: ModelLibrary.LibraryError.self) { try await library.importFolder(from: source) }
        #expect(library.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.mtl").path))
    }

    @Test func rejectsRecursiveFolderCopyBeforeEnumeration() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Library/Models/import")
        for source in [root, URL(fileURLWithPath: "/", isDirectory: true)] {
            #expect(throws: ModelImport.ImportError.self) {
                try ModelImport.copy(from: source, to: destination)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func bundledSamplesAreRegisteredOnce() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = ModelLibrary(rootDirectory: root)
        library.load()
        let bundledCount = library.entries.filter(\.isBundled).count
        #expect(bundledCount >= 6, "번들 샘플 6개 이상 기대, 실제 \(bundledCount)")
        #expect(library.entries.allSatisfy { !$0.name.isEmpty })

        // 다시 로드해도 중복 등록되지 않는다
        let again = ModelLibrary(rootDirectory: root)
        again.load()
        #expect(again.entries.filter(\.isBundled).count == bundledCount)
    }

    @Test func importPersistsAcrossReloadAndDeleteRemovesFiles() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeTriangleOBJ(named: "tri", in: root)

        let library = ModelLibrary(rootDirectory: root)
        library.load()
        let before = library.entries.count

        let entry = try await library.importFile(from: source)
        #expect(entry.isBundled == false)
        #expect(entry.name == "tri")
        #expect(entry.triangleCount == 1)
        #expect(entry.vertexCount == 3)
        #expect(library.entries.count == before + 1)

        let reloaded = ModelLibrary(rootDirectory: root)
        reloaded.load()
        let persisted = try #require(reloaded.entry(id: entry.id))
        let fileURL = try #require(reloaded.fileURL(for: persisted))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        reloaded.delete(persisted)
        #expect(reloaded.entry(id: entry.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func unsupportedExtensionIsRejected() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("model.fbx")
        try Data("x".utf8).write(to: bad)

        let library = ModelLibrary(rootDirectory: root)
        library.load()
        await #expect(throws: ModelLibrary.LibraryError.self) {
            try await library.importFile(from: bad)
        }
    }

    @Test func bundledEntriesCannotBeDeleted() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(rootDirectory: root)
        library.load()
        let firstBundled = library.entries.first { $0.isBundled }
        let bundled = try #require(firstBundled)
        library.delete(bundled)
        #expect(library.entry(id: bundled.id) != nil)
    }
}
