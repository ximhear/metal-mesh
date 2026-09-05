import ModelIO
import Foundation
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard MDLAsset.canImportFileExtension(url.pathExtension) else { print("\(path): 확장자 미지원"); continue }
    let asset = MDLAsset(url: url)
    asset.loadTextures()
    var meshes = 0, verts = 0, tris = 0
    func walk(_ o: MDLObject) {
        if let m = o as? MDLMesh {
            meshes += 1; verts += m.vertexCount
            for s in (m.submeshes ?? []) { if let sm = s as? MDLSubmesh, sm.geometryType == .triangles { tris += sm.indexCount / 3 } }
        }
        for c in o.children.objects { walk(c) }
    }
    for i in 0..<asset.count { walk(asset.object(at: i)) }
    print("\(url.lastPathComponent): meshes=\(meshes) vertices=\(verts) triangles=\(tris)")
}
