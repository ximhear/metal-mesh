import Testing
import Foundation
import Metal
@testable import MetalMesh
@testable import MeshCore

struct EnvironmentTests {
    @Test func buildsIBLTexturesAndLUTIsSane() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let env = try #require(IBLEnvironment.default(device: device))
        #expect(env.irradiance.textureType == .typeCube && env.specular.mipmapLevelCount > 4)

        // LUT를 읽어 split-sum 근사가 상식적인지 확인: nDotV=1, roughness≈0 → scale≈1, bias≈0
        let size = IBLEnvironment.brdfSize
        let readable = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: size, height: size, mipmapped: false)
        readable.storageMode = .shared
        let copy = try #require(device.makeTexture(descriptor: readable))
        let queue = try #require(device.makeCommandQueue())
        let cb = try #require(queue.makeCommandBuffer())
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: env.brdfLUT, to: copy)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var halves = [UInt16](repeating: 0, count: size * size * 2)
        copy.getBytes(&halves, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        func at(_ x: Int, _ y: Int) -> (Float, Float) {
            let i = (y * size + x) * 2
            return (Float(Float16(bitPattern: halves[i])), Float(Float16(bitPattern: halves[i + 1])))
        }
        let smooth = at(size - 1, 0)          // nDotV≈1, roughness≈0
        #expect(smooth.0 > 0.9 && smooth.1 < 0.05, "\(smooth)")
        let grazingRough = at(0, size - 1)    // nDotV≈0, roughness≈1
        #expect(grazingRough.0 + grazingRough.1 < 1.0)
        #expect(grazingRough.0 >= 0 && grazingRough.1 >= 0)
    }

    @Test func sameDeviceSharesEnvironment() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let a = IBLEnvironment.default(device: device)
        let b = IBLEnvironment.default(device: device)
        #expect(a === b)
    }
}
