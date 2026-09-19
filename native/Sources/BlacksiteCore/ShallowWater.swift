import Foundation
import simd

/// A horizontal shallow surface over the actual heightfield. It never replaces
/// the ground collider, blocks sight, or stops a bullet.
public struct MapShallowWaterZone: Sendable {
    public let id: Int
    public let minimum: SIMD2<Float>, maximum: SIMD2<Float>
    public let surfaceHeight: Float, movementMultiplier: Float
    public init(id: Int, minimum: SIMD2<Float>, maximum: SIMD2<Float>, surfaceHeight: Float,
                movementMultiplier: Float = 0.65) {
        self.id = id; self.minimum = minimum; self.maximum = maximum
        self.surfaceHeight = surfaceHeight; self.movementMultiplier = movementMultiplier
    }
    public func contains(x: Float, z: Float) -> Bool {
        x >= minimum.x && x <= maximum.x && z >= minimum.y && z <= maximum.y
    }
    public func depth(x: Float, z: Float, terrain: TerrainProfile) -> Float {
        contains(x: x,z: z) ? max(0,surfaceHeight-terrain.height(x: x,z: z)) : 0
    }
}
public struct WaterContact: Sendable, Equatable {
    public let zoneID: Int
    public let surfaceHeight: Float, supportHeight: Float, depth: Float, movementMultiplier: Float
    public init(zoneID: Int, surfaceHeight: Float, supportHeight: Float, depth: Float, movementMultiplier: Float) {
        self.zoneID = zoneID; self.surfaceHeight = surfaceHeight; self.supportHeight = supportHeight
        self.depth = depth; self.movementMultiplier = movementMultiplier
    }
}
public struct WaterImpact: Sendable, Equatable {
    public let zoneID: Int
    public let position: SIMD3<Float>
    public let normal: SIMD3<Float>
    public init(zoneID: Int, position: SIMD3<Float>) {
        self.zoneID = zoneID; self.position = position; normal = SIMD3(0,1,0)
    }
}
extension MapDefinition {
    public func waterSurface(at point: SIMD3<Float>) -> MapShallowWaterZone? {
        guard point.x.isFinite, point.z.isFinite else { return nil }
        return environment.shallowWaterZones.first { $0.depth(x: point.x,z: point.z,terrain: terrain) > 0.005 }
    }
}
extension CombatSimulation {
    /// Only genuine supported feet receive wading friction or water footsteps.
    /// Solid debris is already represented in obstacles. Cosmetic support
    /// overlays cannot create a dry platform over an unsupported wet floor.
    public func waterContact(at point: SIMD3<Float>, grounded: Bool = true) -> WaterContact? {
        guard grounded, point.y.isFinite, let zone = map.waterSurface(at: point) else { return nil }
        var support = terrain.height(x: point.x,z: point.z)
        for box in obstacles where !box.destroyed && box.maximum.y <= point.y + 0.12 {
            if point.x >= box.minimum.x, point.x <= box.maximum.x, point.z >= box.minimum.z, point.z <= box.maximum.z {
                support = max(support,box.maximum.y)
            }
        }
        let depth = zone.surfaceHeight-support
        guard abs(point.y-support) <= 0.12, depth > 0.02, depth <= 0.351 else { return nil }
        return WaterContact(zoneID: zone.id,surfaceHeight: zone.surfaceHeight,supportHeight: support,
                            depth: depth,movementMultiplier: zone.movementMultiplier)
    }
    /// The nearest real surface crossing before a shot's winning physical hit.
    /// This payload produces one splash and never creates another damage hit.
    public func waterImpact(from: SIMD3<Float>, to: SIMD3<Float>) -> WaterImpact? {
        guard from.x.isFinite, from.y.isFinite, from.z.isFinite, to.x.isFinite, to.y.isFinite, to.z.isFinite else { return nil }
        let delta = to-from
        guard abs(delta.y) > 0.00001 else { return nil }
        var nearest: Float = .infinity, result: WaterImpact?
        for zone in map.environment.shallowWaterZones {
            let t = (zone.surfaceHeight-from.y)/delta.y
            guard t >= 0, t <= 1, t < nearest else { continue }
            let point = from+delta*t
            guard zone.depth(x: point.x,z: point.z,terrain: terrain) > 0.005,
                  !obstacles.contains(where: { !$0.destroyed && point.x >= $0.minimum.x && point.x <= $0.maximum.x &&
                      point.z >= $0.minimum.z && point.z <= $0.maximum.z && point.y >= $0.minimum.y && point.y <= $0.maximum.y }) else { continue }
            nearest = t; result = WaterImpact(zoneID: zone.id,position: point)
        }
        return result
    }
    func submergedExplosionSurface(at point: SIMD3<Float>) -> WaterImpact? {
        guard let zone = map.waterSurface(at: point), point.y <= zone.surfaceHeight,
              point.y >= terrain.height(x: point.x,z: point.z)-0.02 else { return nil }
        return WaterImpact(zoneID: zone.id,position: SIMD3(point.x,zone.surfaceHeight,point.z))
    }
}
