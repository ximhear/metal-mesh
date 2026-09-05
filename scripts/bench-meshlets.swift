// 메시렛 빌더 벤치마크 (최적화 빌드로 실제 속도 측정)
// swiftc -O -parse-as-library -import-objc-header MeshCore/include/ShaderTypes.h \
//   MeshCore/*.swift scripts/bench-meshlets.swift -o /tmp/bench && /tmp/bench <files...>
import Foundation

@main
struct Bench {
static func main() {
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let t0 = Date()
    guard let mesh = try? ModelLoader.loadSynchronously(url: url) else { print("\(url.lastPathComponent): 로드 실패"); continue }
    let loadMs = Date().timeIntervalSince(t0) * 1000
    for (name, strategy) in [("spatialScan", MeshletBuilder.Strategy.spatialScan), ("cluster", .cluster)] {
        let t1 = Date()
        let result = MeshletBuilder.build(mesh, strategy: strategy)
        let ms = Date().timeIntervalSince(t1) * 1000
        let radius = result.meshlets.map(\.boundsRadius).reduce(0, +) / Float(result.meshlets.count)
        print(String(format: "%@ [%@] tris=%d verts=%d load=%.0fms build=%.0fms meshlets=%d meanRadius=%.4f",
                     url.lastPathComponent, name, mesh.triangleCount, mesh.vertices.count, loadMs, ms, result.meshlets.count, radius))
    }
}
}
}
