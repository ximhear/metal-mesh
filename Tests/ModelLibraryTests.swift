import Testing
import Foundation
@testable import MetalMesh

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
