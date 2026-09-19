import simd

extension CombatSimulation {
    /// Read-only camera/viewmodel clearance in metres. Uses the same intact cover
    /// and terrain as combat, with a bounded four-metre query and 0...25cm padding.
    /// Invalid rays return the sanitized limit, so they cannot corrupt the pose.
    public func visualWallDistance(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                   maximumDistance: Float = 1.35, padding: Float = 0.06) -> Float {
        let limit = maximumDistance.isFinite ? max(0, min(4, maximumDistance)) : 1.35
        guard limit > 0, origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return limit }
        let largest = max(abs(direction.x), abs(direction.y), abs(direction.z))
        guard largest > 0 else { return limit }
        // Scale first, avoiding overflow/underflow for otherwise finite vectors.
        let scaled = direction / largest
        let ray = scaled / simd_length(scaled)
        let margin = padding.isFinite ? max(0, min(0.25, padding)) : 0.06
        let distance = wallHit(origin: origin, direction: ray, maximumDistance: limit, padding: margin).distance
        return distance.isFinite ? max(0, min(limit, distance)) : limit
    }
}
