import MeshCore
import SwiftUI
import Metal

/// 모델 하나를 메시 셰이더로 렌더링하는 화면
struct ModelViewerView: View {
    @Environment(ModelLibrary.self) private var library
    let entry: ModelEntry

    private enum LoadState {
        case loading(String)
        case failed(String)
        case ready(Renderer)
    }

    @State private var state: LoadState = .loading("준비 중…")
    @State private var settings = RenderSettings()
    @State private var stats = RenderStats()
    @State private var showInfo = false

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.13).ignoresSafeArea()
            switch state {
            case .loading(let message):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                ContentUnavailableView("불러오지 못했습니다", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready(let renderer):
                MetalView(renderer: renderer, settings: settings)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if case .ready = state { statsBar }
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            // 넓은 툴바: 세그먼트 피커 + 토글을 나열
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("표시", selection: $settings.debugMode) {
                    ForEach(DebugMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $settings.cullingEnabled) { Label("컬링", systemImage: "scissors") }
                Toggle(isOn: $settings.wireframe) { Label("와이어프레임", systemImage: "grid") }
                Toggle(isOn: $settings.texturesEnabled) { Label("텍스처", systemImage: "photo") }
                    .disabled(stats.textureCount == 0)
                infoButton
            }
            #else
            // 좁은 화면: 표시 옵션을 메뉴 하나로 묶는다 (버튼이 겹치지 않도록)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("표시", selection: $settings.debugMode) {
                        ForEach(DebugMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle(isOn: $settings.cullingEnabled) { Label("메시렛 컬링", systemImage: "scissors") }
                    Toggle(isOn: $settings.wireframe) { Label("와이어프레임", systemImage: "grid") }
                    Toggle(isOn: $settings.texturesEnabled) { Label("텍스처", systemImage: "photo") }
                        .disabled(stats.textureCount == 0)
                } label: {
                    Label("표시 옵션", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { infoButton }
            #endif
        }
        .sheet(isPresented: $showInfo) {
            ModelInfoView(entry: entry, fileURL: library.fileURL(for: entry), stats: stats)
        }
        .task(id: entry.id) { await load() }
    }

    private var infoButton: some View {
        Button {
            showInfo = true
        } label: {
            Label("정보", systemImage: "info.circle")
        }
    }

    private var statsBar: some View {
        HStack(spacing: 14) {
            statItem("메시렛", "\(stats.visibleMeshletCount.formatted()) / \(stats.meshletCount.formatted())")
            statItem("삼각형", stats.triangleCount.formatted())
            statItem("GPU", String(format: "%.2f ms", stats.gpuTime * 1000))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
        .padding(.bottom, 10)
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.white.opacity(0.6))
            Text(value)
        }
    }

    @MainActor
    private func load() async {
        guard let url = library.fileURL(for: entry) else {
            state = .failed("파일 경로를 찾을 수 없습니다.")
            return
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .failed("Metal 기기를 찾을 수 없습니다.")
            return
        }
        do {
            state = .loading("파일 읽는 중…")
            let mesh = try await ModelLoader.load(url: url)
            state = .loading("메시렛 생성 중… (\(mesh.triangleCount.formatted()) 삼각형)")
            let meshlets = await Task.detached(priority: .userInitiated) { MeshletBuilder.build(mesh) }.value
            let renderer = try Renderer(device: device, mesh: meshlets, materials: mesh.materials)
            renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
            renderer.onStats = { stats = $0 }
            stats = renderer.stats
            state = .ready(renderer)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// 파일·라이선스·통계 정보 시트
private struct ModelInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ModelEntry
    let fileURL: URL?
    let stats: RenderStats

    var body: some View {
        NavigationStack {
            List {
                Section("파일") {
                    LabeledContent("형식", value: entry.formatLabel)
                    LabeledContent("크기", value: entry.fileSize.formatted(.byteCount(style: .file)))
                    if let fileURL { LabeledContent("이름", value: fileURL.lastPathComponent) }
                }
                Section("메시") {
                    LabeledContent("정점", value: stats.vertexCount.formatted())
                    LabeledContent("삼각형", value: stats.triangleCount.formatted())
                    LabeledContent("메시렛", value: stats.meshletCount.formatted())
                    LabeledContent("재질 / 텍스처", value: "\(stats.materialCount) / \(stats.textureCount)")
                    LabeledContent("메시렛 한계", value: "정점 \(MESHLET_MAX_VERTICES) · 삼각형 \(MESHLET_MAX_TRIANGLES)")
                }
                if let license = entry.licenseText?.trimmingCharacters(in: .whitespacesAndNewlines), !license.isEmpty {
                    Section("라이선스 / 출처") {
                        Text(license).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(entry.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}
