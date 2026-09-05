import SwiftUI

struct ModelRowView: View {
    let entry: ModelEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
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
}
