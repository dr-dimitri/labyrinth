import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct WeaponReloadPoseTests {
    private func point(_ matrix: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = matrix * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    private func matrixError(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        (0..<4).map { simd_length(a[$0] - b[$0]) }.max()!
    }

    @Test func completedAndInvalidReloadsReturnToTheExactBindPose() {
        for kind in WeaponKind.allCases {
            for p: Float in [-100, 0, 1, 100, .nan, .infinity, -.infinity] {
                let pose = WeaponReloadPose(progress: p, kind: kind)
                #expect(matrixError(pose.magazineTransform, matrix_identity_float4x4) < 0.000001)
                #expect(matrixError(pose.supportHandTransform, matrix_identity_float4x4) < 0.000001)
                #expect(simd_distance(pose.supportElbowPosition, WeaponReloadPose.restSupportElbowPosition) < 0.000001)
                #expect(pose.slideOffset == 0 && pose.presentationBlend == 0)
            }
        }
    }

    @Test func theHandStaysLockedToTheMagazineThroughoutRemovalAndInsertion() {
        for kind in WeaponKind.allCases {
            let grip = SIMD3<Float>(-0.033, (kind == .rifle ? -0.132 : -0.096) - 0.010, -0.134)
            let pivot = SIMD3<Float>(0, kind == .rifle ? -0.0395 : -0.0435, -0.142)
            for i in 0...100 {
                let p: Float = 0.18 + Float(i) * 0.006
                let pose = WeaponReloadPose(progress: p, kind: kind)
                #expect(simd_distance(pose.supportHandPosition, point(pose.magazineTransform, grip)) < 0.000001)
                #expect(simd_distance(point(pose.supportHandTransform, WeaponReloadPose.restSupportHandPosition), pose.supportHandPosition) < 0.000001)
                let finger = point(pose.supportHandTransform, WeaponReloadPose.restSupportHandPosition + SIMD3(0,0,0.02))
                #expect(simd_distance(finger, point(pose.magazineTransform, grip + SIMD3(0,-0.02,0))) < 0.000001)
                #expect(simd_distance(point(pose.magazineTransform, pivot), pivot + pose.magazineOffset) < 0.000001)
            }
            let removed = WeaponReloadPose(progress: 0.48, kind: kind)
            #expect(removed.magazineOffset.y < -0.20)
            #expect(simd_length(removed.magazineRotation.imag) > 0.1)
            let seated = WeaponReloadPose(progress: 0.78, kind: kind)
            #expect(matrixError(seated.magazineTransform, matrix_identity_float4x4) < 0.000001)
        }
    }

    @Test func allPhaseBoundariesAreContinuousAndGeometryRemainsFinite() {
        for kind in WeaponKind.allCases {
            for p: Float in [0, 0.18, 0.48, 0.78, 0.84, 0.90, 0.94, 1] {
                let before = WeaponReloadPose(progress: p - 0.000001, kind: kind)
                let after = WeaponReloadPose(progress: p + 0.000001, kind: kind)
                #expect(matrixError(before.magazineTransform, after.magazineTransform) < 0.00001)
                #expect(matrixError(before.supportHandTransform, after.supportHandTransform) < 0.00001)
                #expect(simd_distance(before.supportElbowPosition, after.supportElbowPosition) < 0.00001)
                #expect(abs(before.slideOffset - after.slideOffset) < 0.00001)
            }
            for i in 0...1000 {
                let pose = WeaponReloadPose(progress: Float(i) / 1000, kind: kind)
                for matrix in [pose.magazineTransform, pose.supportHandTransform] {
                    #expect((0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } })
                    #expect(abs(simd_determinant(matrix) - 1) < 0.00001)
                }
                #expect(pose.presentationBlend >= 0 && pose.presentationBlend <= 1.000001)
                #expect(pose.slideOffset >= 0 && pose.slideOffset < 0.06)
                #expect(simd_length(pose.supportHandPosition) < 0.55)
                #expect(simd_distance(pose.supportHandPosition, pose.supportElbowPosition) < 0.75)
            }
        }
    }

    @Test func finishingHandPullsTheChargingHandleAndPoseHasNoHistory() {
        for kind in WeaponKind.allCases {
            let a = WeaponReloadPose(progress: 0.865, kind: kind)
            let b = WeaponReloadPose(progress: 0.90, kind: kind)
            #expect(b.slideOffset > a.slideOffset && a.slideOffset > 0)
            #expect(simd_distance(b.supportHandPosition - a.supportHandPosition, SIMD3(0, 0, b.slideOffset - a.slideOffset)) < 0.000001)
            _ = WeaponReloadPose(progress: 1, kind: kind)
            let repeated = WeaponReloadPose(progress: 0.865, kind: kind)
            #expect(matrixError(a.supportHandTransform, repeated.supportHandTransform) == 0)
        }
    }
}
