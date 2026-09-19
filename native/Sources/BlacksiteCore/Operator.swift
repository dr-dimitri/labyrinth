import simd

public enum OperatorClass: String, CaseIterable, Codable, Sendable {
    case recon, engineer, assault
}

/// Explicitly observed historical points, never live links to a hidden actor.
/// targetID is used only to replace a repeated observation of the same contact.
public struct ReconMark: Sendable, Equatable {
    public static let maximumCount = 3
    public static let lifetime: Double = 12
    public let id: Int, targetID: Int
    public let position: SIMD3<Float>
    public let createdAt: Double, expiresAt: Double
    public init(id: Int, targetID: Int, position: SIMD3<Float>, createdAt: Double) {
        self.id = id; self.targetID = targetID; self.position = position; self.createdAt = createdAt
        expiresAt = createdAt + Self.lifetime
    }
}

/// Position always denotes the physical body centre. The outward normal orients
/// the 12 × 8 × 6 cm housing; resting charges align their thin axis with the actual support normal.
public struct BreachChargeState: Sendable {
    public static let maximumCount = 1
    public let id: Int, ownerObstacleID: Int
    public internal(set) var position: SIMD3<Float>, normal: SIMD3<Float>
    public let createdAt: Double
    public internal(set) var attached: Bool
    public var fuse: Float { Float(remainingTicks)/120 }
    var remainingTicks = 360
    var velocity = SIMD3<Float>.zero
    var resting = false
    public init(id: Int, ownerObstacleID: Int, position: SIMD3<Float>, normal: SIMD3<Float>, createdAt: Double,
                attached: Bool = true) {
        self.id = id; self.ownerObstacleID = ownerObstacleID; self.position = position; self.normal = normal
        self.createdAt = createdAt; self.attached = attached
    }
}
