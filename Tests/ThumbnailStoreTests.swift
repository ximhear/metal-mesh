import Testing
import Foundation
import CoreGraphics
@testable import MetalMesh
@testable import MeshCore

@MainActor
struct ThumbnailStoreTests {
    private actor RenderProbe {
        private(set) var calls: [URL] = []
        private(set) var maximumActive = 0
        private var active = 0
        private let holdFirst: Bool
        private var started: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?

        init(holdFirst: Bool = false) { self.holdFirst = holdFirst }

        func render(_ url: URL) async -> CGImage? {
            calls.append(url)
            active += 1
            maximumActive = max(maximumActive, active)
            started?.resume()
            started = nil
            if holdFirst, calls.count == 1 {
                await withCheckedContinuation { release = $0 }
            } else {
                await Task.yield()
            }
            active -= 1
            return CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }

        func waitForStart() async {
            if calls.isEmpty { await withCheckedContinuation { started = $0 } }
        }

        func finishFirst() {
            release?.resume()
            release = nil
        }
    }

    private func entry(_ name: String) -> ModelEntry {
        ModelEntry(id: UUID(), name: name, source: .imported(relativePath: "group/\(name).obj"), addedAt: Date(), fileSize: 0)
    }

    @Test func burstRequestsRunSeriallyAndDeduplicateActiveEntries() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = RenderProbe(holdFirst: true)
        let store = ThumbnailStore(directory: root,
                                   fileURL: { root.appendingPathComponent($0.name + ".obj") },
                                   renderImage: { await probe.render($0) })
        let entries = (0..<8).map { entry("model\($0)") }
        for entry in entries { store.request(entry) }
        await probe.waitForStart()
        for entry in entries { store.request(entry) }
        await probe.finishFirst()
        await store.waitUntilIdle()
        #expect(await probe.maximumActive == 1)
        #expect(await probe.calls.count == entries.count)
        #expect(store.images.count == entries.count)
    }

    @Test func invalidationDiscardsActiveResultAndRemovesPendingRequest() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = RenderProbe(holdFirst: true)
        let store = ThumbnailStore(directory: root,
                                   fileURL: { root.appendingPathComponent($0.name + ".obj") },
                                   renderImage: { await probe.render($0) })
        let active = entry("active")
        let pending = entry("pending")
        store.request(active)
        store.request(pending)
        await probe.waitForStart()
        store.invalidate(active)
        store.invalidate(pending)
        await probe.finishFirst()
        await store.waitUntilIdle()
        #expect(await probe.calls.count == 1)
        #expect(store.images.isEmpty)
        #expect(store.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: active).path))
        let retried = await store.generate(active)
        #expect(retried != nil)
        #expect(await probe.calls.count == 2)
    }

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
