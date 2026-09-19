import simd

public enum BreachKind: String, Sendable { case lightPanel, glass }
public enum BreachVisibility: String, Sendable { case clear, opaque }

/// A small authored opening with one authoritative physical owner. Visibility
/// is independent of collision, so clear and later obscured glass share the
/// same destruction rules without pretending that glass is an opaque wall.
public struct MapBreachDefinition: Sendable {
    public let ownerObstacleID: Int
    public let kind: BreachKind
    public let visibility: BreachVisibility
    public let frameObstacleIDs: [Int]
    public init(ownerObstacleID: Int, kind: BreachKind, visibility: BreachVisibility, frameObstacleIDs: [Int] = []) {
        self.ownerObstacleID = ownerObstacleID; self.kind = kind; self.visibility = visibility
        self.frameObstacleIDs = frameObstacleIDs
    }
}

/// A grounded read-only view of the existing owner's damage state. An opening
/// never has a second collider or a separate mutable destruction state.
public struct BreachState: Sendable {
    public let ownerObstacleID: Int
    public var id: Int { ownerObstacleID }
    public let kind: BreachKind
    public let visibility: BreachVisibility
    public let damageStage: CoverDamageStage
    public let position: SIMD3<Float>, size: SIMD3<Float>
    public let openedAt: Double?
    public var isOpen: Bool { damageStage == .destroyed }
    public init(ownerObstacleID: Int, kind: BreachKind, visibility: BreachVisibility,
                damageStage: CoverDamageStage, position: SIMD3<Float>, size: SIMD3<Float>, openedAt: Double? = nil) {
        self.ownerObstacleID = ownerObstacleID; self.kind = kind; self.visibility = visibility
        self.damageStage = damageStage; self.position = position; self.size = size; self.openedAt = openedAt
    }
}


extension CombatSimulation {
    public var breaches: [BreachState] {
        map.breaches.compactMap { definition in
            guard let owner = obstacles.first(where: { $0.id == definition.ownerObstacleID }) else { return nil }
            return BreachState(ownerObstacleID: owner.id,kind: definition.kind,visibility: definition.visibility,
                damageStage: owner.damageStage,position: owner.position,size: owner.size,openedAt: breachOpeningTimes[owner.id])
        }
    }

    func standingOnGlassShards(at point: SIMD3<Float>) -> Bool {
        for debris in coverDebris where debris.kind == .glass {
            guard abs(point.x-debris.position.x) <= max(0.45,debris.size.x*0.5),
                  abs(point.z-debris.position.z) <= max(0.45,debris.size.z*0.5) else { continue }
            var support = terrain.height(x: point.x,z: point.z)
            for box in obstacles where !box.destroyed && box.maximum.y <= debris.position.y+0.05 {
                if point.x >= box.minimum.x && point.x <= box.maximum.x && point.z >= box.minimum.z && point.z <= box.maximum.z {
                    support = max(support,box.maximum.y)
                }
            }
            if abs(point.y-support) <= 0.2 { return true }
        }
        return false
    }

    /// Optical queries can cross authored clear glass; bullets, bodies, blast,
    /// sound and throwable sweeps continue to use the complete physical world.
    func blocksSight(_ obstacle: Obstacle) -> Bool {
        obstacle.kind != .glass || !map.breaches.contains {
            $0.ownerObstacleID == obstacle.id && $0.kind == .glass && $0.visibility == .clear
        }
    }
    func sightLine(_ from: SIMD3<Float>, _ to: SIMD3<Float>, excludingObstacle: Int? = nil) -> Bool {
        let offset = to-from, length = simd_length(offset)
        guard length > 0.001 else { return true }
        return wallHit(origin: from,direction: offset/length,maximumDistance: length,
            excludingObstacle: excludingObstacle,purpose: .sight).distance >= length-0.01
    }
}

enum WorldRayPurpose { case physical, sight }
