import MeshCore
import SwiftUI
import Metal

/// 렌더 통계를 SwiftUI에 노출한다. 속성별로 관찰되므로 프레임마다 바뀌는 값(가시 메시렛, GPU 시간)은
/// 그것을 읽는 통계 바만 다시 그리고, 툴바(textureCount만 읽음)는 영향을 받지 않는다.
@MainActor
@Observable
final class ViewerStatsModel {
    var meshletCount = 0
    var triangleCount = 0
    var vertexCount = 0
    var materialCount = 0
    var textureCount = 0
    var visibleMeshletCount = 0
    var occludedMeshletCount = 0
    var drawnTriangleCount = 0
    var lodLevelCount = 1
    var gpuTime: Double = 0
    var renderWidth = 0
    var renderHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var upscalerActive = false

    func apply(_ stats: RenderStats) {
        // 같은 값 대입도 관찰자를 깨우므로 바뀐 것만 쓴다
        if meshletCount != stats.meshletCount { meshletCount = stats.meshletCount }
        if triangleCount != stats.triangleCount { triangleCount = stats.triangleCount }
        if vertexCount != stats.vertexCount { vertexCount = stats.vertexCount }
        if materialCount != stats.materialCount { materialCount = stats.materialCount }
        if textureCount != stats.textureCount { textureCount = stats.textureCount }
        if visibleMeshletCount != stats.visibleMeshletCount { visibleMeshletCount = stats.visibleMeshletCount }
        if occludedMeshletCount != stats.occludedMeshletCount { occludedMeshletCount = stats.occludedMeshletCount }
        if drawnTriangleCount != stats.drawnTriangleCount { drawnTriangleCount = stats.drawnTriangleCount }
        if lodLevelCount != stats.lodLevelCount { lodLevelCount = stats.lodLevelCount }
        if renderWidth != stats.renderWidth { renderWidth = stats.renderWidth }
        if renderHeight != stats.renderHeight { renderHeight = stats.renderHeight }
        if outputWidth != stats.outputWidth { outputWidth = stats.outputWidth }
        if outputHeight != stats.outputHeight { outputHeight = stats.outputHeight }
        if upscalerActive != stats.upscalerActive { upscalerActive = stats.upscalerActive }
        if gpuTime != stats.gpuTime { gpuTime = stats.gpuTime }
    }

    var snapshot: RenderStats {
        RenderStats(meshletCount: meshletCount, visibleMeshletCount: visibleMeshletCount, occludedMeshletCount: occludedMeshletCount,
                    triangleCount: triangleCount, drawnTriangleCount: drawnTriangleCount, lodLevelCount: lodLevelCount,
                    vertexCount: vertexCount, materialCount: materialCount, textureCount: textureCount, gpuTime: gpuTime,
                    renderWidth: renderWidth, renderHeight: renderHeight, outputWidth: outputWidth, outputHeight: outputHeight, upscalerActive: upscalerActive)
    }
}

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
    @State private var stats = ViewerStatsModel()
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
            if case .ready = state { StatsBar(stats: stats) }
        }
        .onChange(of: settings) { _, newValue in
            // 표시 옵션은 다음 프레임에 바로 반영 (MetalView 갱신을 기다리지 않는다)
            if case .ready(let renderer) = state { renderer.settings = newValue }
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
                Toggle(isOn: $settings.occlusionEnabled) { Label("오클루전", systemImage: "eye.slash") }
                Toggle(isOn: $settings.wireframe) { Label("와이어프레임", systemImage: "grid") }
                Toggle(isOn: $settings.texturesEnabled) { Label("텍스처", systemImage: "photo") }
                    .disabled(stats.textureCount == 0)
                Toggle(isOn: $settings.iblEnabled) { Label("환경광", systemImage: "sun.max") }
                Toggle(isOn: $settings.lodEnabled) { Label("LOD", systemImage: "square.3.layers.3d") }
                    .disabled(stats.lodLevelCount <= 1)
                Picker("LOD 오차", selection: $settings.lodThresholdPx) {
                    ForEach([0.5, 1, 2, 4, 8] as [Float], id: \.self) { Text("\($0.formatted()) px").tag($0) }
                }
                .disabled(!settings.lodEnabled || stats.lodLevelCount <= 1)
                Picker("렌더 해상도", selection: $settings.renderScale) {
                    Text("100%").tag(Float(1)); Text("75% + MetalFX").tag(Float(0.75)); Text("67% + MetalFX").tag(Float(0.67)); Text("50% + MetalFX").tag(Float(0.5))
                }
                Picker("MSAA", selection: $settings.msaaSamples) { Text("MSAA 끔").tag(1); Text("MSAA 4x").tag(4) }
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
                    Toggle(isOn: $settings.cullingEnabled) { Label("프러스텀·콘 컬링", systemImage: "scissors") }
                    Toggle(isOn: $settings.occlusionEnabled) { Label("Hi-Z 오클루전", systemImage: "eye.slash") }
                    Toggle(isOn: $settings.wireframe) { Label("와이어프레임", systemImage: "grid") }
                    Toggle(isOn: $settings.texturesEnabled) { Label("텍스처", systemImage: "photo") }
                        .disabled(stats.textureCount == 0)
                    Toggle(isOn: $settings.iblEnabled) { Label("환경광 (IBL)", systemImage: "sun.max") }
                    Divider()
                    Toggle(isOn: $settings.lodEnabled) { Label("클러스터 LOD", systemImage: "square.3.layers.3d") }
                        .disabled(stats.lodLevelCount <= 1)
                    Picker("LOD 허용 오차", selection: $settings.lodThresholdPx) {
                        ForEach([0.5, 1, 2, 4, 8] as [Float], id: \.self) { Text("\($0.formatted()) px").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .disabled(!settings.lodEnabled || stats.lodLevelCount <= 1)
                    Divider()
                    Picker("렌더 해상도", selection: $settings.renderScale) {
                        Text("100%").tag(Float(1)); Text("75% + MetalFX").tag(Float(0.75)); Text("67% + MetalFX").tag(Float(0.67)); Text("50% + MetalFX").tag(Float(0.5))
                    }
                    .pickerStyle(.menu)
                    Picker("MSAA", selection: $settings.msaaSamples) { Text("끔").tag(1); Text("4x").tag(4) }
                        .pickerStyle(.menu)
                } label: {
                    Label("표시 옵션", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { infoButton }
            #endif
        }
        .sheet(isPresented: $showInfo) {
            ModelInfoView(entry: entry, fileURL: library.fileURL(for: entry), stats: stats.snapshot)
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
            state = .loading("메시렛·LOD 생성 중… (\(mesh.triangleCount.formatted()) 삼각형)")
            let meshlets = await Task.detached(priority: .userInitiated) { MeshletLODBuilder.build(mesh) }.value
            let renderer = try Renderer(device: device, mesh: meshlets, materials: mesh.materials)
            renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
            renderer.settings = settings
            renderer.onStats = { [stats] in stats.apply($0) }
            stats.apply(renderer.stats)
            state = .ready(renderer)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// 하단 통계 바. 프레임 통계만 이 뷰가 다시 그린다.
private struct StatsBar: View {
    let stats: ViewerStatsModel

    var body: some View {
        HStack(spacing: 14) {
            item("메시렛", "\(stats.visibleMeshletCount.formatted()) / \(stats.meshletCount.formatted())")
            if stats.occludedMeshletCount > 0 { item("가림", stats.occludedMeshletCount.formatted()) }
            item("삼각형", stats.lodLevelCount > 1
                 ? "\(stats.drawnTriangleCount.formatted()) / \(stats.triangleCount.formatted())"
                 : stats.triangleCount.formatted())
            item("GPU", String(format: "%.2f ms", stats.gpuTime * 1000))
            if stats.upscalerActive {
                item("MetalFX", "\(stats.renderWidth)×\(stats.renderHeight) → \(stats.outputWidth)×\(stats.outputHeight)")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
        .padding(.bottom, 10)
    }

    private func item(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.white.opacity(0.6))
            Text(value)
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
                    LabeledContent("LOD 단계", value: "\(stats.lodLevelCount)")
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
