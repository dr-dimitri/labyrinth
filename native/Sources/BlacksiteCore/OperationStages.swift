import simd

/// A short authored sequence, not a mission scripting graph. Relay targets may
/// be completed in either order; data and radio each have exactly one target.
public enum OperationStageKind: String, Sendable { case relayGroup, collectData, radioTransfer }
public struct OperationTargetDefinition: Sendable {
    public let id: String, title: String
    public let position: SIMD3<Float>
    public let ownerObstacleID: Int?
    public init(id: String, title: String, position: SIMD3<Float>, ownerObstacleID: Int? = nil) {
        self.id = id; self.title = title; self.position = position; self.ownerObstacleID = ownerObstacleID
    }
}
public struct OperationStageDefinition: Sendable {
    public let id: String, title: String
    public let kind: OperationStageKind
    public let targets: [OperationTargetDefinition]
    public let interactionDuration: Float, holdDuration: Float
    public init(id: String, title: String, kind: OperationStageKind, targets: [OperationTargetDefinition],
                interactionDuration: Float = 1, holdDuration: Float = 0) {
        self.id = id; self.title = title; self.kind = kind; self.targets = targets
        self.interactionDuration = interactionDuration; self.holdDuration = holdDuration
    }
}
public struct OperationTargetSnapshot: Sendable {
    public let id: String, title: String, stageID: String
    public let kind: OperationStageKind
    public let position: SIMD3<Float>
    public let ownerObstacleID: Int?
    public let completed: Bool
    /// Unlocked by the current stage and unfinished; interruption carries physical eligibility.
    public let available: Bool
    public let progress: Float, requiredProgress: Float
    public let interruption: MissionInterruption?
    public init(id: String, title: String, stageID: String, kind: OperationStageKind, position: SIMD3<Float>,
                ownerObstacleID: Int? = nil, completed: Bool = false, available: Bool = false,
                progress: Float = 0, requiredProgress: Float = 1, interruption: MissionInterruption? = nil) {
        self.id = id; self.title = title; self.stageID = stageID; self.kind = kind; self.position = position
        self.ownerObstacleID = ownerObstacleID; self.completed = completed; self.available = available
        self.progress = progress; self.requiredProgress = requiredProgress; self.interruption = interruption
    }
}
public struct OperationStageSnapshot: Sendable {
    public let id: String, title: String
    public let kind: OperationStageKind
    public let completed: Bool, active: Bool
    public let targets: [OperationTargetSnapshot]
    public init(id: String, title: String, kind: OperationStageKind, completed: Bool, active: Bool, targets: [OperationTargetSnapshot]) {
        self.id = id; self.title = title; self.kind = kind; self.completed = completed; self.active = active; self.targets = targets
    }
}
