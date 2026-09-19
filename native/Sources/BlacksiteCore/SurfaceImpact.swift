import simd

public enum SurfaceMaterial: String, CaseIterable, Sendable {
    case soil, concrete, metal, wood, asphalt
}

/// Immutable snapshot of the winning surface hit, captured before its damage can
/// destroy the cover. The owner is the stable obstacle ID, never its array index.
public struct SurfaceImpact: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let material: SurfaceMaterial
    public let obstacleID: Int?

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, material: SurfaceMaterial, obstacleID: Int? = nil) {
        self.position = position
        self.normal = normal
        self.material = material
        self.obstacleID = obstacleID
    }
}

extension CombatSimulation {
    func makeSurfaceImpact(for hit: RayHit, at position: SIMD3<Float>) -> SurfaceImpact? {
        guard hit.enemyIndex == nil else { return nil }
        if let index = hit.obstacleIndex {
            let box = obstacles[index]
            let material: SurfaceMaterial
            switch box.kind {
            case .bunker, .barrier: material = .concrete
            case .container, .barrel: material = .metal
            case .crate: material = .wood
            }
            return SurfaceImpact(position: position, normal: hit.normal, material: material, obstacleID: box.id)
        }
        guard hit.hitGround else { return nil }
        let material = map.groundMaterial(at: position)
        return SurfaceImpact(position: position, normal: hit.normal, material: material)
    }
}
