import MeshCore
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Observation
import UniformTypeIdentifiers

/// 모델별 썸네일 PNG를 만들고 캐시한다. 생성은 한 번에 하나씩(Model I/O 직렬화 + GPU) 진행된다.
@MainActor
@Observable
final class ThumbnailStore {
    nonisolated static let pixelSize = (width: 320, height: 240)

    private(set) var images: [UUID: CGImage] = [:]
    private(set) var failed: Set<UUID> = []

    private let directory: URL
    private let fileURL: (ModelEntry) -> URL?
    private var pending: [ModelEntry] = []
    private var queued: Set<UUID> = []
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<CGImage?, Never>?
    private var activeID: UUID?
    @ObservationIgnored private let renderImage: @Sendable (URL) async throws -> CGImage?

    init(directory: URL, fileURL: @escaping (ModelEntry) -> URL?,
         renderImage: @escaping @Sendable (URL) async throws -> CGImage? = { try await ThumbnailStore.renderImage(url: $0) }) {
        self.directory = directory
        self.fileURL = fileURL
        self.renderImage = renderImage
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(library: ModelLibrary) {
        self.init(directory: library.thumbnailsDirectory, fileURL: { library.fileURL(for: $0) })
    }

    func url(for entry: ModelEntry) -> URL {
        directory.appendingPathComponent("\(entry.id.uuidString).png")
    }

    /// 캐시된 이미지. 없으면 디스크에서 읽고, 그것도 없으면 생성 큐에 넣는다.
    func image(for entry: ModelEntry) -> CGImage? {
        if let image = images[entry.id] { return image }
        if let image = loadFromDisk(entry) {
            images[entry.id] = image
            return image
        }
        request(entry)
        return nil
    }

    func request(_ entry: ModelEntry) {
        guard images[entry.id] == nil, !failed.contains(entry.id), !queued.contains(entry.id) else { return }
        queued.insert(entry.id)
        pending.append(entry)
        if queueTask == nil { queueTask = Task { await runQueue() } }
    }

    func invalidate(_ entry: ModelEntry) {
        images[entry.id] = nil
        failed.remove(entry.id)
        pending.removeAll { $0.id == entry.id }
        queued.remove(entry.id)
        if activeID == entry.id { activeTask?.cancel() }
        try? FileManager.default.removeItem(at: url(for: entry))
    }

    // MARK: - 생성

    /// 파일을 읽어 메시렛을 만들고 오프스크린 렌더한다. 결과는 디스크와 메모리 캐시에 저장된다.
    @discardableResult
    func generate(_ entry: ModelEntry) async -> CGImage? {
        if let image = images[entry.id] { return image }
        request(entry)
        await waitUntilIdle()
        return images[entry.id]
    }

    func waitUntilIdle() async {
        while let task = queueTask { await task.value }
    }

    private func runQueue() async {
        defer { queueTask = nil }
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            guard let source = fileURL(entry) else {
                queued.remove(entry.id)
                failed.insert(entry.id)
                continue
            }
            let task = Task<CGImage?, Never> { [renderImage] in
                do {
                    let image = try await renderImage(source)
                    try Task.checkCancellation()
                    return image
                } catch {
                    return nil
                }
            }
            activeID = entry.id
            activeTask = task
            let image = await task.value
            activeID = nil
            activeTask = nil
            if !pending.contains(where: { $0.id == entry.id }) { queued.remove(entry.id) }
            guard !task.isCancelled else { continue }
            if let image {
                if let png = Renderer.pngData(image) { try? png.write(to: url(for: entry), options: .atomic) }
                images[entry.id] = image
            } else {
                failed.insert(entry.id)
            }
        }
    }

    nonisolated private static func renderImage(url: URL) async throws -> CGImage? {
        let mesh = try await ModelLoader.load(url: url)
        return try await BackgroundWork.run(priority: .utility) {
            let meshlets = try MeshletBuilder.build(mesh, cancellationCheck: Task.checkCancellation)
            try Task.checkCancellation()
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            let renderer = try Renderer(device: device, mesh: meshlets, materials: mesh.materials)
            renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
            try Task.checkCancellation()
            return renderer.snapshot(width: Self.pixelSize.width, height: Self.pixelSize.height)
        }
    }

    private func loadFromDisk(_ entry: ModelEntry) -> CGImage? {
        let url = url(for: entry)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
