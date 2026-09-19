import Foundation
import simd

public enum CamouflagePattern: String, CaseIterable, Codable, Sendable {
    case none, vegetation, mineral

    public func matches(_ ground: CamouflageGround) -> Bool {
        switch self {
        case .none: return false
        case .vegetation: return ground == .vegetation
        case .mineral: return ground == .earth || ground == .rubble
        }
    }
}

/// One immutable source for the selected equipment and its actual capacity.
/// A camouflage suit occupies the auxiliary slot of the fourth fragmentation grenade.
public struct LoadoutDefinition: Sendable, Equatable {
    public let camouflage: CamouflagePattern
    public var fragmentationGrenades: Int { camouflage == .none ? 4 : 3 }
    public init(camouflage: CamouflagePattern = .none) { self.camouflage = camouflage }
}

public enum ConcealmentReason: String, Sendable {
    case noSuit, unsuitableGround, moving, turning, airborne, recentShot, settling, ready
}

/// Local conditions only: no enemy positions, distances, awareness or promises
/// of safety. Strength describes the suit, independently of visible foliage.
public struct ConcealmentStatus: Sendable {
    public let pattern: CamouflagePattern
    public let surfaceMaterial: SurfaceMaterial
    public let camouflageGround: CamouflageGround
    public let matchesGround: Bool
    public let settleProgress: Float
    public let localStrength: Float
    public let reason: ConcealmentReason
    public init(pattern: CamouflagePattern, surfaceMaterial: SurfaceMaterial, camouflageGround: CamouflageGround,
                matchesGround: Bool, settleProgress: Float, localStrength: Float, reason: ConcealmentReason) {
        self.pattern = pattern; self.surfaceMaterial = surfaceMaterial; self.camouflageGround = camouflageGround
        self.matchesGround = matchesGround; self.reason = reason
        self.settleProgress = settleProgress.isFinite ? clamp(settleProgress, 0, 1) : 0
        self.localStrength = localStrength.isFinite ? clamp(localStrength, 0, 1) : 0
    }
}

/// Apply only after FOV and actual visibility have passed. This adjusts initial
/// recognition speed, never hard visibility, confirmed contact or hit chance.
public struct ConcealmentEvaluation: Sendable {
    public static let activationDuration: Float = 1.5
    public static let shotLockoutDuration: Double = 3
    public static let minimumCombinedRecognition: Float = 0.15
    public let recognitionMultiplier: Float

    public init(status: ConcealmentStatus, observerDistance: Float) {
        guard observerDistance.isFinite, observerDistance > 6, status.pattern != .none,
              status.matchesGround, status.reason == .ready else { recognitionMultiplier = 1; return }
        let distance = clamp((observerDistance - 6) / 19, 0, 1)
        let distanceBlend = distance * distance * (3 - 2 * distance)
        recognitionMultiplier = 1 - 0.55 * status.localStrength * distanceBlend
    }

    public func combinedRecognition(vegetation: Float) -> Float {
        // A zero visibility result remains blocked. Future opaque effects must
        // be resolved before this soft modifier, just like current hard cover.
        guard vegetation.isFinite, vegetation > 0 else { return 0 }
        return max(Self.minimumCombinedRecognition, min(1, vegetation) * recognitionMultiplier)
    }
}

/// Absolute angular travel over a fixed half-second simulation window avoids
/// render-rate-dependent spikes when mouse input arrives every 1/30 vs 1/120s.
struct ConcealmentMotion {
    private var angles = [Float](repeating: 0, count: 60)
    private var cursor = 0
    private(set) var angularTravel: Float = 0
    private(set) var stationaryTicks = 0
    private(set) var reason: ConcealmentReason?
    private var previous: PlayerState?
    var settleProgress: Float { min(1, Float(stationaryTicks) / 180) }
    var turnStrength: Float { clamp((0.35 - angularTravel) / 0.25, 0, 1) }

    mutating func resetPose(_ player: PlayerState) { previous = player }
    mutating func interrupt() { stationaryTicks = 0 }
    mutating func observe(player: PlayerState, sprinting: Bool, climbing: Bool, matchesGround: Bool, recentShot: Bool) {
        let before = previous ?? player
        defer { previous = player }
        let yaw = atan2(sin(player.yaw - before.yaw), cos(player.yaw - before.yaw))
        let angle = sqrt(yaw * yaw + pow(player.pitch - before.pitch, 2))
        angularTravel = max(0, angularTravel + angle - angles[cursor])
        angles[cursor] = angle; cursor = (cursor + 1) % angles.count
        let movement = simd_distance(player.position, before.position)
        let posture = abs(player.height - before.height)
        reason = nil
        if recentShot { reason = .recentShot }
        else if !player.grounded || climbing { reason = .airborne }
        else if sprinting || movement > 0.001 || posture > 0.000_7 || player.prone != before.prone { reason = .moving }
        else if angularTravel > 0.35 { reason = .turning }
        if reason != nil || !matchesGround { stationaryTicks = 0 }
        else { stationaryTicks = min(180, stationaryTicks + 1) }
    }
}
