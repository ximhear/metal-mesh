import SwiftUI

/// Phase 3에서 MetalView(MTKView)로 채워진다. 지금은 파일 정보와 라이선스만 보여준다.
struct ModelViewerView: View {
    @Environment(ModelLibrary.self) private var library
    let entry: ModelEntry

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 56))
                    Text("메시 셰이더 렌더러는 Phase 3에서 들어옵니다")
                        .font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            infoPanel
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("형식", value: entry.formatLabel)
            LabeledContent("정점", value: entry.vertexCount.map { $0.formatted() } ?? "–")
            LabeledContent("삼각형", value: entry.triangleCount.map { $0.formatted() } ?? "–")
            LabeledContent("크기", value: entry.fileSize.formatted(.byteCount(style: .file)))
            if let url = library.fileURL(for: entry) {
                LabeledContent("파일", value: url.lastPathComponent)
            }
            if let license = entry.licenseText?.trimmingCharacters(in: .whitespacesAndNewlines), !license.isEmpty {
                Divider().padding(.vertical, 2)
                Text(license)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
