import Foundation
import simd

public enum WeaponKind: String, CaseIterable, Sendable {
    case rifle, sniper
    public var displayName: String { self == .rifle ? "AR-4 VANGUARD" : "M82 SENTINEL" }
    public var capacity: Int { self == .rifle ? 30 : 5 }
    public var initialReserve: Int { self == .rifle ? 210 : 35 }
    public var damage: Float { self == .rifle ? 28 : 105 }
    public var fireInterval: Float { self == .rifle ? 0.105 : 1.1 }
    public var reloadDuration: Float { self == .rifle ? 1.8 : 2.6 }
}
public enum Difficulty: String, CaseIterable, Sendable { case easy, normal, hard }
public enum MatchState: String, Sendable { case active, won, lost }
public enum EnemyAwareness: String, Sendable { case watching, investigating, searching, engaged }
public enum ObstacleKind: String, Sendable { case bunker, container, barrier, crate, barrel }

public struct GameInput: Sendable {
    public var moveForward: Float = 0
    public var moveRight: Float = 0
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var sprint = false
    public var fire = false
    public var aim = false
    public init() {}
}

public struct PlayerState: Sendable {
    public var position: SIMD3<Float>
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var height: Float = 1.72
    public var health: Float = 100
    public var stamina: Float = 100
    public var prone = false
    public var grounded = true
    var verticalVelocity: Float = 0
    var lastHit: Double = -20
    var exhausted = false
    public init(position: SIMD3<Float> = SIMD3(0, 0, 32)) { self.position = position }
}

public struct EnemyState: Sendable {
    public let id: Int
    public var position: SIMD3<Float>
    public var health: Float
    public var yaw: Float = 0
    public var walkCycle: Float = 0
    public var windup: Float = 0
    public var deathTime: Double?
    public var seesPlayer = false
    public var awareness: EnemyAwareness = .watching
    /// Visual recognition, not knowledge of the player's position through cover.
    public var detectionProgress: Float = 0
    public var isMoving = false
    public var crouchAmount: Float = 0
    public var isRunning = false
    public var grounded = true
    public var aimPitch: Float = 0
    public var aimBlend: Float = 0
    public var recoil: Float = 0
    public var verticalVelocity: Float = 0
    public init(id: Int, position: SIMD3<Float>, health: Float = 100) {
        self.id = id; self.position = position; self.health = health
    }
}

/// Shared anatomy and weapon frame for rendering, visibility, hitboxes and fire.
/// Soldiers face local +Z; positive aimPitch points upward. All centres are world positions.
public struct EnemyPose: Sendable {
    public let headHeight: Float
    public let bodyHeight: Float
    public let hipHeight: Float
    public let eyeHeight: Float
    public let shoulderHeight: Float
    public let totalHeight: Float
    public let headCenter: SIMD3<Float>
    public let bodyCenter: SIMD3<Float>
    public let hipCenter: SIMD3<Float>
    public let eyePosition: SIMD3<Float>
    public let gunRoot: SIMD3<Float>
    public let muzzlePosition: SIMD3<Float>
    public let aimDirection: SIMD3<Float>
    /// Local gun coordinates: +Z along the barrel, +X right, +Y up. Muzzle z = 0.72 m.
    public let gunTransform: simd_float4x4

    public init(_ enemy: EnemyState) {
        let crouch = clamp(enemy.crouchAmount, 0, 1)
        headHeight = 1.73 - 0.65 * crouch; bodyHeight = 1.18 - 0.50 * crouch
        hipHeight = 0.82 - 0.36 * crouch; eyeHeight = 1.68 - 0.65 * crouch
        shoulderHeight = 1.42 - 0.56 * crouch; totalHeight = 1.96 - 0.65 * crouch
        headCenter = enemy.position + SIMD3(0, headHeight, 0)
        bodyCenter = enemy.position + SIMD3(0, bodyHeight, 0)
        hipCenter = enemy.position + SIMD3(0, hipHeight, 0)
        eyePosition = enemy.position + SIMD3(0, eyeHeight, 0)
        let forward = SIMD3<Float>(sin(enemy.yaw), 0, cos(enemy.yaw))
        let right = SIMD3<Float>(cos(enemy.yaw), 0, -sin(enemy.yaw))
        aimDirection = SIMD3(sin(enemy.yaw) * cos(enemy.aimPitch), sin(enemy.aimPitch), cos(enemy.yaw) * cos(enemy.aimPitch))
        gunRoot = enemy.position + right * 0.18 + forward * 0.14 + SIMD3(0, shoulderHeight, 0)
        muzzlePosition = gunRoot + aimDirection * 0.72
        gunTransform = simd_float4x4(columns: (SIMD4(right, 0), SIMD4(simd_cross(aimDirection, right), 0),
                                             SIMD4(aimDirection, 0), SIMD4(gunRoot, 1)))
    }
}

public struct Obstacle: Sendable {
    public let id: Int
    public let kind: ObstacleKind
    /// Base centre in metres; size is width, height, depth.
    public let position: SIMD3<Float>
    public let size: SIMD3<Float>
    public var health: Float
    public var destroyed = false
    public var damageStage: CoverDamageStage {
        if destroyed || health <= 0 { return .destroyed }
        guard health.isFinite, maximumHealth.isFinite else { return .intact }
        return health <= maximumHealth * 0.5 ? .damaged : .intact
    }
    public var maximumHealth: Float {
        switch kind {
        case .bunker: return .infinity
        case .container: return 700
        case .barrier: return 280
        case .crate: return 110
        case .barrel: return 55
        }
    }
    public init(id: Int, kind: ObstacleKind, position: SIMD3<Float>, size: SIMD3<Float>) {
        self.id = id; self.kind = kind; self.position = position; self.size = size
        switch kind {
        case .bunker: health = .infinity
        case .container: health = 700
        case .barrier: health = 280
        case .crate: health = 110
        case .barrel: health = 55
        }
    }
    var minimum: SIMD3<Float> { position - SIMD3(size.x * 0.5, 0, size.z * 0.5) }
    var maximum: SIMD3<Float> { position + SIMD3(size.x * 0.5, size.y, size.z * 0.5) }
}

public struct GrenadeState: Sendable {
    public let id: Int
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var fuse: Float
    public init(id: Int, position: SIMD3<Float>, velocity: SIMD3<Float>, fuse: Float = 2.8) {
        self.id = id; self.position = position; self.velocity = velocity; self.fuse = fuse
    }
}

public struct WeaponState: Sendable {
    public var ammo: Int
    public var reserve: Int
    public var reloadRemaining: Float = 0
    public var cooldown: Float = 0
    public init(kind: WeaponKind) { ammo = kind.capacity; reserve = kind.initialReserve }
}

public struct SupplyState: Sendable {
    public let id: Int
    public let position: SIMD3<Float>
}

public struct GameEvent: Sendable {
    public enum Kind: String, Sendable {
        case shot, enemyShot, enemyAlert, explosion, damage, kill, coverDestroyed
        case waveStarted, waveCleared, extractionUnlocked, reinforcementsArrived, supply, win, lose, reload, jump, land, climb, throwGrenade
    }
    public let kind: Kind
    public var position: SIMD3<Float>
    public var endPosition: SIMD3<Float>
    public var amount: Float
    public var headshot: Bool
    public var weapon: WeaponKind?
    public var id: Int
    public var count: Int
    public var surfaceImpact: SurfaceImpact?
    public init(kind: Kind, position: SIMD3<Float> = .zero, endPosition: SIMD3<Float> = .zero,
                amount: Float = 0, headshot: Bool = false, weapon: WeaponKind? = nil,
                id: Int = 0, count: Int = 0, surfaceImpact: SurfaceImpact? = nil) {
        self.kind = kind; self.position = position; self.endPosition = endPosition
        self.amount = amount; self.headshot = headshot; self.weapon = weapon
        self.id = id; self.count = count
        self.surfaceImpact = surfaceImpact
    }
}

/// Compact authored structures whose visual shell must match their collider.
/// Raw values are stable world IDs, shared with surface hits and render caches.
public enum LevelProp: Int, CaseIterable, Sendable {
    case lowerServiceStep = 19, upperServiceStep = 20
    case westRoofEquipment = 21, northRoofEquipment = 22
}

public enum GameMap {
    public static let minimum = SIMD3<Float>(-38, 0, -42)
    public static let maximum = SIMD3<Float>(38, 0, 42)
    public static let extraction = SIMD3<Float>(0, 0, -35)
    public static let extractionRadius: Float = 3.5
    /// Ground-accessible landmarks reserved for the next mission objectives.
    public static let dataSite = SIMD3<Float>(-31, 0, 31)
    public static let radioSite = SIMD3<Float>(32, 0, 5)
    public static let serviceApproach = SIMD3<Float>(13, 0, -24)
    public static let obstacles: [Obstacle] = {
        let definitions: [(ObstacleKind, Float, Float, Float, Float, Float)] = [
            (.bunker, -22, -12, 13, 13, 5.6), (.bunker, 24, -27, 12, 14, 7.2),
            (.container, -15, 14, 3.6, 11, 3.1), (.container, 15, -5, 11, 3.6, 3.1),
            (.container, -25, 26, 9, 3.6, 3.1),
            (.barrier, -3.9, 18, 5.4, 0.85, 1.05), (.barrier, 5.5, 6, 5.8, 0.85, 1.05),
            (.barrier, -4, -9, 5.8, 0.85, 1.05), (.barrier, 4.5, -24, 5.4, 0.85, 1.05),
            (.crate, 20, 19, 3.2, 2.6, 1.9), (.crate, -9, -25, 2.8, 2.8, 1.3),
            (.crate, 27, 7, 3, 3, 1.2), (.crate, -29, 4, 3.2, 3.2, 1.4),
            (.barrier, -12, -35, 7, 0.8, 1.05), (.barrier, 12, -35, 7, 0.8, 1.05),
            (.barrel, 10, -1, 0.8, 0.8, 1.15), (.barrel, -11, 11, 0.8, 0.8, 1.15),
            (.barrel, 18, 17, 0.8, 0.8, 1.15), (.barrel, -12, -22, 0.8, 0.8, 1.15)
        ]
        var result = definitions.enumerated().map { index, d in
            Obstacle(id: index, kind: d.0, position: SIMD3(d.1, 0, d.2), size: SIMD3(d.3, d.5, d.4))
        }
        // Each concrete stage has its own embedded foundation. It never relies
        // on a destructible box below it, and remains closed on sloping ground.
        result.append(Obstacle(id: LevelProp.lowerServiceStep.rawValue, kind: .bunker,
                               position: SIMD3(15.8,-3,-24), size: SIMD3(3.8,5.4,3.8)))
        result.append(Obstacle(id: LevelProp.upperServiceStep.rawValue, kind: .bunker,
                               position: SIMD3(16.4,-3,-24), size: SIMD3(2.2,7.6,2.2)))
        // Both parent roofs are permanent and lie on level terrain foundations.
        // These metal housings replace previously decorative, floating vents.
        for (prop, position) in [(LevelProp.westRoofEquipment, SIMD3<Float>(-20.4,5.6,-11)),
                                 (.northRoofEquipment, SIMD3<Float>(25.6,7.2,-26))] {
            var housing = Obstacle(id: prop.rawValue, kind: .container, position: position, size: SIMD3(2.5,1,2))
            housing.health = .infinity
            result.append(housing)
        }
        return result
    }()

    /// Grounding changes only y. Verify the other authored dimensions so an
    /// isolated scenario reusing an ID does not acquire unrelated prop visuals.
    public static func levelProp(for obstacle: Obstacle) -> LevelProp? {
        guard let prop = LevelProp(rawValue: obstacle.id) else { return nil }
        let authored = obstacles[prop.rawValue]
        guard obstacle.kind == authored.kind, obstacle.size == authored.size,
              obstacle.position.x == authored.position.x, obstacle.position.z == authored.position.z else { return nil }
        return prop
    }
    static let spawns: [SIMD3<Float>] = [
        SIMD3(9, 0, 1), SIMD3(-8, 0, 5), SIMD3(25, 0, -10), SIMD3(-11, 0, -17),
        SIMD3(2, 0, -30), SIMD3(-30, 0, 14), SIMD3(30, 0, 21), SIMD3(11, 0, -30), SIMD3(-28, 0, -30)
    ]
    /// Preferred positions, then permanent perimeter/building approaches. The
    /// simulation validates every entry again against current cover and sight.
    static let reinforcementEntries: [SIMD3<Float>] = {
        var points = spawns
        for x: Float in [-34, -26, -18, -10, 0, 10, 18, 26, 34] {
            points.append(SIMD3(x, 0, -38)); points.append(SIMD3(x, 0, 38))
        }
        for z: Float in [-30, -20, -10, 0, 10, 20, 30] {
            points.append(SIMD3(-34, 0, z)); points.append(SIMD3(34, 0, z))
        }
        for x: Float in [-32, -12, 16, 32] {
            for z: Float in [-36, -20, -4] { points.append(SIMD3(x, 0, z)) }
        }
        return points
    }()
}

@inline(__always) func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(upper, max(lower, value))
}
@inline(__always) func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let x = a.x - b.x, z = a.z - b.z
    return sqrt(x * x + z * z)
}
public func viewDirection(yaw: Float, pitch: Float) -> SIMD3<Float> {
    SIMD3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
}
