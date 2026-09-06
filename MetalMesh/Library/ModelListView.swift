import SwiftUI
import UniformTypeIdentifiers

struct ModelListView: View {
    @Environment(ModelLibrary.self) private var library
    @Environment(ThumbnailStore.self) private var thumbnails
    @State private var showImporter = false
    @State private var importDirectory = false
    @State private var pendingImports = 0
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(sortedEntries) { entry in
                NavigationLink(value: entry.id) {
                    ModelRowView(entry: entry)
                }
                .contextMenu { deleteButton(for: entry) }
                .swipeActions(edge: .trailing) { deleteButton(for: entry) }
            }
        }
        .overlay {
            if library.entries.isEmpty {
                ContentUnavailableView(
                    "모델이 없습니다",
                    systemImage: "cube.transparent",
                    description: Text("+ 버튼으로 모델 파일이나 관련 파일이 들어 있는 폴더를 추가하세요.")
                )
            }
        }
        .navigationTitle("Models")
        .navigationDestination(for: UUID.self) { id in
            if let entry = library.entry(id: id) {
                ModelViewerView(entry: entry)
            } else {
                ContentUnavailableView("항목을 찾을 수 없습니다", systemImage: "questionmark.folder")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("모델 파일 가져오기", systemImage: "doc.badge.plus") {
                        importDirectory = false
                        showImporter = true
                    }
                    Button("모델·텍스처 폴더 가져오기", systemImage: "folder.badge.plus") {
                        importDirectory = true
                        showImporter = true
                    }
                } label: {
                    Label("추가", systemImage: "plus")
                }
                .disabled(pendingImports > 0)
            }
            if pendingImports > 0 {
                ToolbarItem(placement: .status) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importDirectory ? [.folder] : ModelLibrary.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importAll(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importAll(urls)
            return true
        }
        .alert("가져오기 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var sortedEntries: [ModelEntry] {
        library.entries.sorted { $0.addedAt > $1.addedAt }
    }

    @ViewBuilder
    private func deleteButton(for entry: ModelEntry) -> some View {
        if !entry.isBundled {
            Button(role: .destructive) {
                thumbnails.invalidate(entry)
                library.delete(entry)
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    private func importAll(_ urls: [URL]) {
        pendingImports += urls.count
        Task {
            var failures: [String] = []
            for url in urls {
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        try await library.importFolder(from: url)
                    } else {
                        try await library.importFile(from: url)
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                pendingImports -= 1
            }
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }
}
