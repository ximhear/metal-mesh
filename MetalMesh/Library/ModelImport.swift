import Foundation
import MeshCore

enum ModelImport {
    enum ImportError: LocalizedError {
        case resource(String)
        case emptyFolder
        case recursiveFolder

        var errorDescription: String? {
            switch self {
            case .resource(let path):
                return "관련 파일을 가져올 수 없습니다: \(path)\n모델과 재질·텍스처가 들어 있는 폴더를 선택해 가져오세요."
            case .emptyFolder:
                return "폴더에 지원하는 모델 파일이 없습니다."
            case .recursiveFolder:
                return "앱의 모델 저장 폴더를 포함하는 폴더는 가져올 수 없습니다."
            }
        }
    }

    static func copy(from source: URL, to destination: URL) throws -> [String] {
        let manager = FileManager.default
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let root = isDirectory ? source : source.deletingLastPathComponent()
        if isDirectory, destination.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: root.pathComponents) {
            throw ImportError.recursiveFolder
        }
        var files: [URL] = []
        var models: [URL] = []
        if isDirectory {
            var enumerationError: Error?
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                       options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw ImportError.resource(root.lastPathComponent) }
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ImportError.resource(file.lastPathComponent) }
                if values.isRegularFile == true {
                    files.append(file)
                    if ModelProbe.isSupported(file) { models.append(file) }
                }
            }
            if let enumerationError { throw enumerationError }
            guard !models.isEmpty else { throw ImportError.emptyFolder }
        } else {
            files = [source]
            models = [source]
        }

        var checked = Set<URL>()
        var pending = isDirectory ? models : files
        while let file = pending.popLast() {
            try Task.checkCancellation()
            guard checked.insert(file.standardizedFileURL).inserted else { continue }
            for dependency in try dependencies(of: file, root: root) {
                if !files.contains(dependency) { files.append(dependency) }
                pending.append(dependency)
            }
        }

        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            try Task.checkCancellation()
            let relative = try relativePath(file, root: root)
            let target = destination.appendingPathComponent(relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: file, to: target)
        }
        return try models.map { try relativePath($0, root: root) }.sorted()
    }

    private static func relativePath(_ file: URL, root: URL) throws -> String {
        let path = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix), file.resolvingSymlinksInPath().path.hasPrefix(prefix),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ImportError.resource(file.lastPathComponent)
        }
        return String(path.dropFirst(prefix.count))
    }

    private static func dependencies(of file: URL, root: URL) throws -> [URL] {
        let ext = file.pathExtension.lowercased()
        if GLBLoader.canLoad(file) {
            return try GLBLoader.externalResourceURIs(url: file).map { uri in
                guard let reference = URL(string: uri), reference.scheme == nil, reference.host == nil,
                      reference.query == nil, reference.fragment == nil,
                      let path = uri.removingPercentEncoding, !path.hasPrefix("/") else {
                    throw ImportError.resource(uri)
                }
                return try resource(path, relativeTo: file, root: root)
            }
        }
        guard ext == "obj" || ext == "mtl" else { return [] }
        var resources: [URL] = []
        for line in try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let command = line.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace }).lowercased()
            guard ext == "obj" && command == "mtllib"
                    || ext == "mtl" && (command.hasPrefix("map_") || ["bump", "disp", "decal", "norm", "refl"].contains(command)) else { continue }
            let words = try tokenize(String(line))
            var arguments = Array(words.dropFirst())
            if ext == "obj", command == "mtllib" {
                let joined = arguments.joined(separator: " ")
                if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(joined).path) {
                    arguments = [joined]
                }
                resources += try arguments.map { try resource($0, relativeTo: file, root: root) }
            } else if ext == "mtl", command.hasPrefix("map_") || ["bump", "disp", "decal", "norm", "refl"].contains(command) {
                while let option = arguments.first, option.hasPrefix("-") {
                    arguments.removeFirst()
                    let count: Int
                    if ["-o", "-s", "-t"].contains(option) {
                        count = arguments.prefix(3).prefix { Float($0) != nil }.count
                    } else if option == "-mm" {
                        count = 2
                    } else if ["-blendu", "-blendv", "-boost", "-texres", "-clamp", "-bm", "-imfchan", "-type", "-cc", "-colorspace"].contains(option) {
                        count = 1
                    } else {
                        throw ImportError.resource(String(line))
                    }
                    guard count > 0, arguments.count > count else { throw ImportError.resource(String(line)) }
                    arguments.removeFirst(count)
                }
                guard !arguments.isEmpty else { throw ImportError.resource(String(line)) }
                resources.append(try resource(arguments.joined(separator: " "), relativeTo: file, root: root))
            }
        }
        return resources
    }

    private static func resource(_ path: String, relativeTo file: URL, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":") else { throw ImportError.resource(path) }
        let url = file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        do {
            _ = try relativePath(url, root: root)
        } catch {
            throw ImportError.resource(path)
        }
        return url
    }

    private static func tokenize(_ line: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                word.append(character)
            }
        }
        guard quote == nil, !escaped else { throw ImportError.resource(line) }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
