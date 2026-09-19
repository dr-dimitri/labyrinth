import simd

/// Orthographic light volume; sphere checks include casters behind the camera.
/// Clip-space Z is Metal's 0...1, unlike the symmetric X/Y planes.
struct DirectionalShadowVolume {
    let matrix: simd_float4x4
    private let radiusScale: SIMD3<Float>

    init(matrix: simd_float4x4) {
        self.matrix = matrix
        let rows = matrix.transpose
        radiusScale = SIMD3(simd_length(SIMD3(rows.columns.0.x, rows.columns.0.y, rows.columns.0.z)),
                            simd_length(SIMD3(rows.columns.1.x, rows.columns.1.y, rows.columns.1.z)),
                            simd_length(SIMD3(rows.columns.2.x, rows.columns.2.y, rows.columns.2.z)))
    }

    func intersects(center: SIMD3<Float>, radius: Float) -> Bool {
        let p = matrix * SIMD4(center, 1)
        let r = radiusScale * max(0, radius)
        return abs(p.x) <= 1 + r.x && abs(p.y) <= 1 + r.y && p.z >= -r.z && p.z <= 1 + r.z
    }

    /// Keep orientation and extent fixed. Snapping the centre in the light's
    /// basis locks the shadow texel grid to world geometry during camera motion.
    static func near(eye: SIMD3<Float>, forward: SIMD3<Float>, sun: SIMD3<Float>, resolution: Int) -> DirectionalShadowVolume {
        let light = simd_normalize(sun)
        let right = rightVector(for: light)
        let up = simd_cross(light, right)
        let flat = SIMD3<Float>(forward.x, 0, forward.z)
        let lookAhead = simd_length_squared(flat) > 0.0001 ? simd_normalize(flat) * 6 : .zero
        let desired = eye + lookAhead - SIMD3<Float>(0, 0.9, 0)
        let step = nearWidth / Float(max(1, resolution))
        let x = (simd_dot(desired, right) / step).rounded() * step
        let y = (simd_dot(desired, up) / step).rounded() * step
        let centre = right * x + up * y + light * simd_dot(desired, light)
        let origin = centre + light * 90
        let view = simd_float4x4(columns: (
            SIMD4(right.x, up.x, light.x, 0), SIMD4(right.y, up.y, light.y, 0),
            SIMD4(right.z, up.z, light.z, 0),
            SIMD4(-simd_dot(right, origin), -simd_dot(up, origin), -simd_dot(light, origin), 1)))
        let projection = simd_float4x4(columns: (
            SIMD4(2 / nearWidth, 0, 0, 0), SIMD4(0, 2 / nearWidth, 0, 0),
            SIMD4(0, 0, -1 / nearDepth, 0), SIMD4(0, 0, -1 / nearDepth, 1)))
        return DirectionalShadowVolume(matrix: projection * view)
    }

    static let nearWidth: Float = 40
    static let nearDepth: Float = 180

    /// A vertical midday sun needs a different reference axis. Both shadow
    /// cascades use this basis so a valid map never produces a zero cross product.
    static func rightVector(for direction: SIMD3<Float>) -> SIMD3<Float> {
        let reference = abs(direction.y) > 0.999 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(reference, direction))
    }
}
