import Foundation

/// 라이브러리의 모델 한 항목. 파일 위치는 `ModelLibrary.fileURL(for:)`로 해석한다.
struct ModelEntry: Identifiable, Codable, Hashable {
    enum Source: Codable, Hashable {
        /// 앱 번들 `Samples/` 폴더 기준 상대 경로
        case bundled(relativePath: String)
        /// 라이브러리 `Models/` 폴더 기준 상대 경로
        case imported(relativePath: String)

        var relativePath: String {
            switch self {
            case .bundled(let p), .imported(let p): return p
            }
        }
    }

    let id: UUID
    var name: String
    var source: Source
    var addedAt: Date
    var fileSize: Int64
    var vertexCount: Int?
    var triangleCount: Int?
    /// 같은 폴더의 LICENSE.txt 내용 (번들 샘플). 표기 의무 라이선스 표시용.
    var licenseText: String?

    var isBundled: Bool {
        if case .bundled = source { return true }
        return false
    }

    var fileExtension: String {
        (source.relativePath as NSString).pathExtension.lowercased()
    }

    var formatLabel: String { fileExtension.uppercased() }
}
