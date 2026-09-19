import simd
import BlacksiteCore

/// Deterministic viewmodel animation in weapon space: +X right, +Y up, -Z muzzle.
/// Progress follows the simulation's reload clock; this value has no mutable state.
struct WeaponReloadPose {
    let magazineOffset: SIMD3<Float>
    let magazineRotation: simd_quatf
    /// Delta applied before the complete magazine's existing bind transform.
    let magazineTransform: simd_float4x4
    let supportHandPosition: SIMD3<Float>
    /// Rotation relative to the hand's existing bind orientation.
    let supportHandRotation: simd_quatf
    let supportElbowPosition: SIMD3<Float>
    /// Backward travel along +Z, shared by bolt and charging handle.
    let slideOffset: Float
    let presentationBlend: Float

    static let restSupportHandPosition = SIMD3<Float>(-0.032, -0.036, -0.327)
    static let restSupportElbowPosition = SIMD3<Float>(-0.15, -0.45, 0.20)

    /// Delta for the palm/fingers/wrist group, excluding the rebuilt forearm.
    var supportHandTransform: simd_float4x4 {
        Self.translation(supportHandPosition) * simd_float4x4(supportHandRotation) * Self.translation(-Self.restSupportHandPosition)
    }

    init(progress: Float, kind: WeaponKind) {
        let p = progress.isFinite ? max(0, min(1, progress)) : 0
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        let magazineY: Float = kind == .rifle ? -0.132 : -0.096
        let pivot = SIMD3<Float>(0, kind == .rifle ? -0.0395 : -0.0435, -0.142)
        let grip = SIMD3<Float>(-0.033, magazineY - 0.010, -0.134)
        let gripRotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let gripElbow = SIMD3<Float>(-0.19, -0.335, 0.15)
        let handle = SIMD3<Float>(-0.064, 0.040, 0.035)
        let handleElbow = SIMD3<Float>(-0.19, -0.29, 0.24)

        // Four connected phases: reach, extract, reinsert, finish. The magazine
        // never changes identity or disappears; it remains in the support hand.
        let travel: Float
        if p < 0.18 || p >= 0.78 { travel = 0 }
        else if p < 0.48 { travel = Self.ease((p - 0.18) / 0.30) }
        else { travel = 1 - Self.ease((p - 0.48) / 0.30) }
        magazineOffset = SIMD3<Float>(-0.075, kind == .rifle ? -0.26 : -0.22, 0.045) * travel
        magazineRotation = simd_quatf(angle: -0.24 * travel, axis: SIMD3<Float>(0, 0, 1)) * simd_quatf(angle: 0.10 * travel, axis: SIMD3<Float>(1, 0, 0))
        magazineTransform = Self.translation(pivot + magazineOffset) * simd_float4x4(magazineRotation) * Self.translation(-pivot)
        presentationBlend = Self.ease(p / 0.15) * Self.ease((1 - p) / 0.13)

        var hand = Self.restSupportHandPosition
        var rotation = identity
        var elbow = Self.restSupportElbowPosition
        var slide: Float = 0
        if p < 0.18 {
            let t = Self.ease(p / 0.18)
            hand = Self.mix(Self.restSupportHandPosition, grip, t) + SIMD3<Float>(-0.055, 0.010, 0) * Self.arc(t)
            rotation = simd_slerp(identity, gripRotation, t)
            elbow = Self.mix(Self.restSupportElbowPosition, gripElbow, t)
        } else if p <= 0.78 {
            // Exact shared transform preserves palm contact while the magazine
            // rotates about its top, including at both phase boundaries.
            hand = Self.point(magazineTransform, grip)
            rotation = magazineRotation * gripRotation
            elbow = gripElbow + magazineOffset * 0.45
        } else if p < 0.84 {
            let t = Self.ease((p - 0.78) / 0.06)
            hand = Self.mix(grip, handle, t) + SIMD3<Float>(-0.065, 0, 0) * Self.arc(t)
            rotation = simd_slerp(gripRotation, identity, t)
            elbow = Self.mix(gripElbow, handleElbow, t)
        } else if p < 0.94 {
            let stroke = p < 0.90 ? Self.ease((p - 0.84) / 0.06) : 1 - Self.ease((p - 0.90) / 0.04)
            slide = (kind == .rifle ? 0.048 : 0.058) * stroke
            hand = handle + SIMD3(0, 0, slide)
            elbow = handleElbow + SIMD3(0, 0, slide * 0.6)
        } else {
            let t = Self.ease((p - 0.94) / 0.06)
            hand = Self.mix(handle, Self.restSupportHandPosition, t) + SIMD3<Float>(-0.030, 0, 0) * Self.arc(t)
            elbow = Self.mix(handleElbow, Self.restSupportElbowPosition, t)
        }
        supportHandPosition = hand
        supportHandRotation = rotation
        supportElbowPosition = elbow
        slideOffset = slide
    }

    private static func ease(_ value: Float) -> Float {
        let t = max(0, min(1, value))
        return max(0, min(1, t * t * t * (t * (t * 6 - 15) + 10)))
    }
    private static func arc(_ t: Float) -> Float { 4 * t * (1 - t) }
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
    private static func translation(_ p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(p, 1)
        return m
    }
    private static func point(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
}
