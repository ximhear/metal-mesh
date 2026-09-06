import Testing
@testable import MetalMesh
@testable import MeshCore

/// ShaderTypes.h의 레이아웃이 Metal 쪽 기대와 같은지 고정한다.
struct ShaderTypesTests {
    @Test func vertexLayout() {
        #expect(MemoryLayout<Vertex>.stride == 64)
        #expect(MemoryLayout<Vertex>.offset(of: \.position) == 0)
        #expect(MemoryLayout<Vertex>.offset(of: \.normal) == 16)
        #expect(MemoryLayout<Vertex>.offset(of: \.uv) == 32)
        #expect(MemoryLayout<Vertex>.offset(of: \.tangent) == 48)
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
        // MSL: texture2d×4(8B) @0…24, float4 @32, float×3 @48, uint×3 @60 → 80B
        #expect(MemoryLayout<Material>.stride == 80)
        #expect(MemoryLayout<GPUTexture2D>.size == 8)
        #expect(MemoryLayout<Material>.offset(of: \.normalTexture) == 8)
        #expect(MemoryLayout<Material>.offset(of: \.metallicTexture) == 24)
        #expect(MemoryLayout<Material>.offset(of: \.baseColorFactor) == 32)
        #expect(MemoryLayout<Material>.offset(of: \.metallicFactor) == 48)
        #expect(MemoryLayout<Material>.offset(of: \.flags) == 60)
        #expect(MemoryLayout<Material>.offset(of: \.metallicChannel) == 68)
    }

    @Test func limitsWithinMetalMaximums() {
        #expect(MESHLET_MAX_VERTICES <= 256)
        #expect(MESHLET_MAX_TRIANGLES <= 512)
        #expect(MESH_THREADS_PER_THREADGROUP >= MESHLET_MAX_TRIANGLES)
    }
}
