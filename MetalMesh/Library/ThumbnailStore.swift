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
    static let pixelSize = (width: 320, height: 240)

    private(set) var images: [UUID: CGImage] = [:]
    private(set) var failed: Set<UUID> = []

    private let directory: URL
    private let fileURL: (ModelEntry) -> URL?
    private var pending: [ModelEntry] = []
    private var queued: Set<UUID> = []
    private var isRunning = false
    @ObservationIgnored private let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    init(directory: URL, fileURL: @escaping (ModelEntry) -> URL?) {
        self.directory = directory
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(library: ModelLibrary) {
        self.init(directory: library.thumbnailsDirectory) { library.fileURL(for: $0) }
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
        if !isRunning { Task { await runQueue() } }
    }

    func invalidate(_ entry: ModelEntry) {
        images[entry.id] = nil
        failed.remove(entry.id)
        try? FileManager.default.removeItem(at: url(for: entry))
    }

    // MARK: - 생성

    /// 파일을 읽어 메시렛을 만들고 오프스크린 렌더한다. 결과는 디스크와 메모리 캐시에 저장된다.
    @discardableResult
    func generate(_ entry: ModelEntry) async -> CGImage? {
        guard let source = fileURL(entry), let device else {
            failed.insert(entry.id)
            return nil
        }
        do {
            let mesh = try await ModelLoader.load(url: source)
            let meshlets = await Task.detached(priority: .utility) { MeshletBuilder.build(mesh) }.value
            let renderer = try Renderer(device: device, mesh: meshlets, materials: mesh.materials)
            renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
            guard let image = renderer.snapshot(width: Self.pixelSize.width, height: Self.pixelSize.height) else {
                failed.insert(entry.id)
                return nil
            }
            if let png = Renderer.pngData(image) {
                try? png.write(to: url(for: entry), options: .atomic)
            }
            images[entry.id] = image
            return image
        } catch {
            failed.insert(entry.id)
            return nil
        }
    }

    private func runQueue() async {
        isRunning = true
        defer { isRunning = false }
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            queued.remove(entry.id)
            if images[entry.id] == nil, !failed.contains(entry.id) {
                await generate(entry)
            }
        }
    }

    private func loadFromDisk(_ entry: ModelEntry) -> CGImage? {
        let url = url(for: entry)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
