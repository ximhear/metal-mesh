import MeshCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// 모델 목록의 단일 진실 공급원. JSON 인덱스 + `Models/` 폴더로 영속화한다.
@MainActor
@Observable
final class ModelLibrary {
    enum LibraryError: LocalizedError {
        case unsupportedFormat(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "지원하지 않는 형식입니다: .\(ext)\n지원: \(ModelProbe.supportedExtensions.sorted().joined(separator: ", "))"
            case .copyFailed(let reason):
                return "파일을 가져오지 못했습니다: \(reason)"
            }
        }
    }

    private(set) var entries: [ModelEntry] = []
    var lastError: String?

    private let rootDirectory: URL
    private let bundle: Bundle
    private let fileManager = FileManager.default

    private var indexURL: URL { rootDirectory.appendingPathComponent("library.json") }
    private var modelsDirectory: URL { rootDirectory.appendingPathComponent("Models", isDirectory: true) }
    /// 렌더링이 바뀌면 버전을 올려 썸네일을 다시 만들게 한다 (v2: PBR + IBL)
    var thumbnailsDirectory: URL { rootDirectory.appendingPathComponent("Thumbnails-v2", isDirectory: true) }
    private var samplesDirectory: URL? { bundle.url(forResource: "Samples", withExtension: nil) }

    /// 파일 임포터에 넘길 타입 목록
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.usdz, .threeDContent]
        for ext in ModelProbe.supportedExtensions.sorted() {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    /// - Parameter rootDirectory: 기본값은 Documents. 테스트에서는 임시 폴더를 넘긴다.
    init(rootDirectory: URL? = nil, bundle: Bundle = .main) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.bundle = bundle
    }

    // MARK: - 조회

    func entry(id: UUID) -> ModelEntry? {
        entries.first { $0.id == id }
    }

    func fileURL(for entry: ModelEntry) -> URL? {
        switch entry.source {
        case .bundled(let path):
            return samplesDirectory?.appendingPathComponent(path)
        case .imported(let path):
            let url = modelsDirectory.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(modelsDirectory.standardizedFileURL.path + "/") else { return nil }
            return url
        }
    }

    // MARK: - 로드/저장

    /// 인덱스를 읽고, 아직 등록되지 않은 번들 샘플을 추가한다. 앱 시작 시 한 번 호출.
    func load() {
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? Self.decoder.decode([ModelEntry].self, from: data) {
            entries = decoded
        }
        // 파일이 사라진 임포트 항목 정리
        entries.removeAll { entry in
            guard let url = fileURL(for: entry) else { return true }
            return !fileManager.fileExists(atPath: url.path)
        }
        registerBundledSamples()
        save()
        probeMissingStats()
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(entries)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            lastError = "목록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func registerBundledSamples() {
        guard let samplesDirectory else { return }
        let known = Set(entries.compactMap { entry -> String? in
            if case .bundled(let p) = entry.source { return p }
            return nil
        })
        guard let enumerator = fileManager.enumerator(
            at: samplesDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let basePath = samplesDirectory.standardizedFileURL.path + "/"
        var added: [ModelEntry] = []
        for case let url as URL in enumerator where ModelProbe.isSupported(url) {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: basePath, with: "")
            guard !known.contains(relative) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let licenseURL = url.deletingLastPathComponent().appendingPathComponent("LICENSE.txt")
            let license = try? String(contentsOf: licenseURL, encoding: .utf8)
            added.append(ModelEntry(
                id: UUID(),
                name: Self.displayName(forBundled: url, samplesDirectory: samplesDirectory),
                source: .bundled(relativePath: relative),
                addedAt: Date(),
                fileSize: size,
                licenseText: license
            ))
        }
        entries.append(contentsOf: added.sorted { $0.name < $1.name })
    }

    /// `Samples/stanford-bunny/stanford-bunny.obj` → "Stanford Bunny". 폴더가 없으면 파일 이름 사용.
    private static func displayName(forBundled url: URL, samplesDirectory: URL) -> String {
        let parent = url.deletingLastPathComponent()
        let raw = parent.standardizedFileURL.path == samplesDirectory.standardizedFileURL.path
            ? url.deletingPathExtension().lastPathComponent
            : parent.lastPathComponent
        return raw
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .capitalized
    }

    // MARK: - 추가/삭제

    /// 외부 파일을 라이브러리로 복사해 등록한다. 보안 범위 URL(파일 임포터, 드롭)을 그대로 넘겨도 된다.
    @discardableResult
    func importFile(from sourceURL: URL) async throws -> ModelEntry {
        let ext = sourceURL.pathExtension.lowercased()
        guard ModelProbe.supportedExtensions.contains(ext) else {
            throw LibraryError.unsupportedFormat(ext)
        }

        return try await importSource(from: sourceURL, isDirectory: false)[0]
    }

    @discardableResult
    func importFolder(from sourceURL: URL) async throws -> [ModelEntry] {
        try await importSource(from: sourceURL, isDirectory: true)
    }

    private func importSource(from sourceURL: URL, isDirectory: Bool) async throws -> [ModelEntry] {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let group = UUID().uuidString
        let folder = modelsDirectory.appendingPathComponent(group, isDirectory: true)
        var imported: [ModelEntry]
        do {
            let actualDirectory = try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard actualDirectory == isDirectory else { throw ModelImport.ImportError.resource(sourceURL.lastPathComponent) }
            let paths = try await BackgroundWork.run {
                try ModelImport.copy(from: sourceURL, to: folder)
            }
            try Task.checkCancellation()
            imported = try paths.map { path in
                let destination = folder.appendingPathComponent(path)
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
                let license = try? String(contentsOf: destination.deletingLastPathComponent().appendingPathComponent("LICENSE.txt"), encoding: .utf8)
                return ModelEntry(id: UUID(), name: destination.deletingPathExtension().lastPathComponent,
                                  source: .imported(relativePath: "\(group)/\(path)"), addedAt: Date(), fileSize: size, licenseText: license)
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            if error is CancellationError { throw error }
            throw LibraryError.copyFailed(error.localizedDescription)
        }
        entries.insert(contentsOf: imported, at: 0)
        save()

        for index in imported.indices {
            guard !Task.isCancelled, let destination = fileURL(for: imported[index]),
                  let stats = await ModelProbe.stats(for: destination) else { continue }
            imported[index].vertexCount = stats.vertexCount
            imported[index].triangleCount = stats.triangleCount
            update(imported[index])
        }
        return imported
    }

    func delete(_ entry: ModelEntry) {
        guard case .imported = entry.source else { return }
        entries.removeAll { $0.id == entry.id }
        let group = entry.source.relativePath.split(separator: "/").first.map(String.init)
        if let group, UUID(uuidString: group) != nil,
           !entries.contains(where: { !$0.isBundled && $0.source.relativePath.hasPrefix(group + "/") }) {
            try? fileManager.removeItem(at: modelsDirectory.appendingPathComponent(group, isDirectory: true))
        }
        try? fileManager.removeItem(at: thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png"))
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent("Thumbnails/\(entry.id.uuidString).png"))
        save()
    }

    private func update(_ entry: ModelEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    /// 통계가 없는 항목을 백그라운드에서 하나씩 채운다 (USD 런타임은 동시 로드에 취약).
    private func probeMissingStats() {
        let pending = entries.filter { $0.triangleCount == nil }
        guard !pending.isEmpty else { return }
        Task {
            for entry in pending {
                guard let url = fileURL(for: entry),
                      let stats = await ModelProbe.stats(for: url),
                      var current = self.entry(id: entry.id) else { continue }
                current.vertexCount = stats.vertexCount
                current.triangleCount = stats.triangleCount
                update(current)
            }
        }
    }

    // MARK: - Codable

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
