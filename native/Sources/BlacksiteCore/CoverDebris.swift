import simd

public enum CoverDamageStage: String, CaseIterable, Hashable, Sendable {
    case intact, damaged, destroyed
}

/// A bounded, simulation-clock lifetime for one destroyed object's visible
/// remains. Position/size describe the original, terrain-grounded object.
/// Only solidObstacleID grants collision: decorative fragments never do.
public struct CoverDebrisState: Sendable {
    public static let maximumCount = 24
    public let sourceObstacleID: Int
    public let kind: ObstacleKind
    public let position: SIMD3<Float>
    public let size: SIMD3<Float>
    public let createdAt: Double
    public let lifetime: Double
    public let solidObstacleID: Int?

    public init(sourceObstacleID: Int, kind: ObstacleKind, position: SIMD3<Float>, size: SIMD3<Float>,
                createdAt: Double, lifetime: Double, solidObstacleID: Int? = nil) {
        self.sourceObstacleID = sourceObstacleID; self.kind = kind
        self.position = position; self.size = size
        self.createdAt = createdAt; self.lifetime = lifetime; self.solidObstacleID = solidObstacleID
    }
}
