import Testing
import simd
@testable import BlacksiteMac

struct ShadowMathTests {
    private let sun = simd_normalize(SIMD3<Float>(-0.68, 0.24, -0.69))

    @Test func cameraMotionOnlyMovesTheWorldGridByWholeTexels() {
        let eye = SIMD3<Float>(3, 1.6, 14), forward = SIMD3<Float>(0, 0, -1)
        for resolution in [1024, 2048] {
            let first = DirectionalShadowVolume.near(eye: eye, forward: forward, sun: sun, resolution: resolution)
            let point = SIMD4<Float>(7, 2, -3, 1), a = first.matrix * point
            for i in -25...25 {
                let moved = DirectionalShadowVolume.near(eye: eye + SIMD3(Float(i)*0.013, Float(i)*0.006, Float(i)*0.009),
                                                         forward: forward, sun: sun, resolution: resolution)
                let b = moved.matrix * point
                let pixels = SIMD2(b.x-a.x, b.y-a.y) * Float(resolution) * 0.5
                #expect(abs(pixels.x-pixels.x.rounded()) < 0.003)
                #expect(abs(pixels.y-pixels.y.rounded()) < 0.003)
            }
        }
    }

    @Test func lightVolumeRetainsOffscreenAndBorderCasters() {
        let eye = SIMD3<Float>(0, 1.6, 14)
        let volume = DirectionalShadowVolume.near(eye: eye, forward: SIMD3(0,0,-1), sun: sun, resolution: 2048)
        // A sunward caster may be far outside the camera's view but still shade
        // the receiver. Culling must use the full depth of the light volume.
        #expect(volume.intersects(center: eye + sun*50, radius: 3))
        #expect(!volume.intersects(center: eye + SIMD3(200,0,0), radius: 1))
        for clip in [SIMD3<Float>(1.005,0,0.5), SIMD3(-1.005,0,0.5),
                     SIMD3(0,1.005,0.5), SIMD3(0,-1.005,0.5),
                     SIMD3(0,0,-0.0005), SIMD3(0,0,1.0005)] {
            let world = volume.matrix.inverse * SIMD4(clip,1)
            let center = SIMD3(world.x,world.y,world.z)
            #expect(volume.intersects(center: center, radius: 0.2))
            #expect(!volume.intersects(center: center, radius: 0))
        }
    }

    @Test func receiversRemainCoveredOnHillsRoofsAndInHollows() {
        for elevation: Float in [-2, 0, 4.7, 7.475] {
            let foot = SIMD3<Float>(12,elevation,8)
            let volume = DirectionalShadowVolume.near(eye: foot + SIMD3(0,1.62,0),
                forward: SIMD3(-0.6,0,-0.8), sun: sun, resolution: 2048)
            let receiver = volume.matrix * SIMD4(foot,1)
            #expect(abs(receiver.x) < 0.8 && abs(receiver.y) < 0.8)
            #expect(receiver.z > 0 && receiver.z < 1)
            #expect(volume.intersects(center: foot + SIMD3(0,0.9,0), radius: 1.1))
        }
    }

    @Test func overheadSunKeepsFiniteShadowMatricesAndVisibleReceivers() {
        for direction in [SIMD3<Float>(0, 1, 0), SIMD3(0.00001, 1, -0.00001), SIMD3(0, -1, 0)] {
            let light = simd_normalize(direction)
            let right = DirectionalShadowVolume.rightVector(for: light)
            #expect(abs(simd_length(right) - 1) < 0.0001 && abs(simd_dot(right, light)) < 0.0001)
            for resolution in [1024, 2048] {
                let receiver = SIMD3<Float>(110, 18.8, 216)
                let volume = DirectionalShadowVolume.near(eye: receiver + SIMD3(0, 1.62, 0),
                    forward: SIMD3(0, 0, -1), sun: light, resolution: resolution)
                for column in [volume.matrix.columns.0, volume.matrix.columns.1, volume.matrix.columns.2, volume.matrix.columns.3] {
                    #expect(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite)
                }
                #expect(volume.intersects(center: receiver, radius: 0.1))
            }
        }
    }
}
