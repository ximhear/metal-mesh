import Testing
@testable import MetalMesh
@testable import MeshCore

/// ShaderTypes.h의 레이아웃이 Metal 쪽 기대와 같은지 고정한다.
struct ShaderTypesTests {
    @Test func vertexLayout() {
        #expect(MemoryLayout<Vertex>.stride == 48)
        #expect(MemoryLayout<Vertex>.offset(of: \.position) == 0)
        #expect(MemoryLayout<Vertex>.offset(of: \.normal) == 16)
        #expect(MemoryLayout<Vertex>.offset(of: \.uv) == 32)
    }

    @Test func meshletLayout() {
        #expect(MemoryLayout<Meshlet>.stride == 64)
        #expect(MemoryLayout<Meshlet>.offset(of: \.boundsRadius) == 16)
        #expect(MemoryLayout<Meshlet>.offset(of: \.materialIndex) == 20)
        #expect(MemoryLayout<Meshlet>.offset(of: \.coneAxis) == 32)
        #expect(MemoryLayout<Meshlet>.offset(of: \.coneCutoff) == 48)
        #expect(MemoryLayout<Meshlet>.offset(of: \.vertexOffset) == 52)
        #expect(MemoryLayout<Meshlet>.offset(of: \.triangleOffset) == 56)
        #expect(MemoryLayout<Meshlet>.offset(of: \.vertexCount) == 60)
        #expect(MemoryLayout<Meshlet>.offset(of: \.triangleCount) == 62)
    }

    @Test func materialLayoutMatchesArgumentBuffer() {
        // MSL: texture2d(8B) @0, float4 @16, uint @32 → 48B
        #expect(MemoryLayout<Material>.stride == 48)
        #expect(MemoryLayout<Material>.offset(of: \.baseColorTexture) == 0)
        #expect(MemoryLayout<BaseColorTexture>.size == 8)
        #expect(MemoryLayout<Material>.offset(of: \.baseColorFactor) == 16)
        #expect(MemoryLayout<Material>.offset(of: \.hasTexture) == 32)
    }

    @Test func limitsWithinMetalMaximums() {
        #expect(MESHLET_MAX_VERTICES <= 256)
        #expect(MESHLET_MAX_TRIANGLES <= 512)
        #expect(MESH_THREADS_PER_THREADGROUP >= MESHLET_MAX_TRIANGLES)
    }
}
