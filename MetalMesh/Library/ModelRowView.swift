import SwiftUI

struct ModelRowView: View {
    @Environment(ThumbnailStore.self) private var thumbnails
    let entry: ModelEntry

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 80, height: 60)
                .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.formatLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if let triangles = entry.triangleCount {
                        Text("\(triangles.formatted()) 삼각형")
                    } else {
                        Text("분석 중…")
                    }
                    Text(entry.fileSize.formatted(.byteCount(style: .file)))
                    if entry.isBundled {
                        Text("샘플").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.addedAt, format: .dateTime.month().day())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = thumbnails.image(for: entry) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if thumbnails.failed.contains(entry.id) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
