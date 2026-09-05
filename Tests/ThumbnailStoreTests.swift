import Testing
import Foundation
@testable import MetalMesh
@testable import MeshCore

@MainActor
struct ThumbnailStoreTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generatesAndCachesThumbnailOnDisk() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(rootDirectory: root)
        library.load()
        let entry = try #require(library.entries.first { $0.name == "Teapot" })

        let store = ThumbnailStore(library: library)
        #expect(store.image(for: entry) == nil, "처음엔 캐시 없음 → 큐에 들어감")
        let image = try #require(await store.generate(entry))
        #expect(image.width == ThumbnailStore.pixelSize.width && image.height == ThumbnailStore.pixelSize.height)
        #expect(FileManager.default.fileExists(atPath: store.url(for: entry).path))
        #expect(store.image(for: entry) != nil)

        // 새 인스턴스는 디스크에서 바로 읽는다
        let second = ThumbnailStore(library: library)
        #expect(second.image(for: entry) != nil)

        second.invalidate(entry)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: entry).path))
    }

    @Test func missingFileIsMarkedFailedWithoutThrowing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThumbnailStore(directory: root.appendingPathComponent("Thumbs")) { _ in
            URL(fileURLWithPath: "/nonexistent/model.obj")
        }
        let entry = ModelEntry(id: UUID(), name: "ghost", source: .imported(relativePath: "x/model.obj"), addedAt: Date(), fileSize: 0)
        let image = await store.generate(entry)
        #expect(image == nil)
        #expect(store.failed.contains(entry.id))
    }
}
