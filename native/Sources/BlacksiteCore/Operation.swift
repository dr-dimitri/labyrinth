import simd

public enum OperationRouteKind: String, Sendable { case exposed, sheltered }
public enum OperationPreparationKind: String, Sendable { case disableRadio, openGate }
public struct ExtractionDefinition: Sendable {
    public let id: String, title: String, detail: String
    public let position: SIMD3<Float>
    public let radius: Float, holdDuration: Float
    public let routeKind: OperationRouteKind
    public init(id: String, title: String, detail: String, position: SIMD3<Float>, radius: Float = 3.5,
                holdDuration: Float = 3, routeKind: OperationRouteKind) {
        self.id = id; self.title = title; self.detail = detail; self.position = position
        self.radius = radius; self.holdDuration = holdDuration; self.routeKind = routeKind
    }
}
public struct OperationPreparationDefinition: Sendable {
    public let kind: OperationPreparationKind
    public let deviceID: Int
    public init(kind: OperationPreparationKind, deviceID: Int) { self.kind = kind; self.deviceID = deviceID }
}
public struct MapOperationDefinition: Sendable {
    public let preparations: [OperationPreparationDefinition]
    public let extractions: [ExtractionDefinition]
    public let requiredStages: [OperationStageDefinition]
    public init(preparations: [OperationPreparationDefinition] = [], extractions: [ExtractionDefinition], requiredStages: [OperationStageDefinition] = []) {
        self.preparations = preparations; self.extractions = extractions; self.requiredStages = requiredStages
    }
}
public struct OperationPreparationStatus: Sendable {
    public let kind: OperationPreparationKind
    public let deviceID: Int
    public let completed: Bool, unavailable: Bool
    public init(kind: OperationPreparationKind, deviceID: Int, completed: Bool, unavailable: Bool) {
        self.kind = kind; self.deviceID = deviceID; self.completed = completed; self.unavailable = unavailable
    }
}
/// Grounded exit state. `blocked` is physical, `unlocked` comes from the data
/// objective, and `active` means the player is presently qualifying for its timer.
public struct ExtractionSnapshot: Sendable {
    public let id: String, title: String, detail: String
    public let position: SIMD3<Float>
    public let radius: Float, requiredProgress: Float, progress: Float, distance: Float
    public let routeKind: OperationRouteKind
    public let unlocked: Bool, blocked: Bool, active: Bool
    public let interruption: MissionInterruption?
    public var fraction: Float { requiredProgress > 0 ? min(1, max(0, progress / requiredProgress)) : 0 }
    public init(id: String, title: String, detail: String, position: SIMD3<Float>, radius: Float,
                requiredProgress: Float, progress: Float = 0, distance: Float = 0, routeKind: OperationRouteKind,
                unlocked: Bool = false, blocked: Bool = false, active: Bool = false, interruption: MissionInterruption? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.position = position; self.radius = radius
        self.requiredProgress = requiredProgress; self.progress = progress; self.distance = distance; self.routeKind = routeKind
        self.unlocked = unlocked; self.blocked = blocked; self.active = active; self.interruption = interruption
    }
}
public struct OperationStatus: Sendable {
    public let preparations: [OperationPreparationStatus]
    public let extractions: [ExtractionSnapshot]
    /// Last exit deliberately entered; nil before the first choice. Leaving its
    /// zone resets only its timer. Entering the other zone replaces this choice.
    public let stages: [OperationStageSnapshot]
    public let activeStageID: String?
    public let selectedExtractionID: String?
    public var activeExtractionID: String? { extractions.first { $0.active }?.id }
    public var activeExtractionTitle: String? { extractions.first { $0.active }?.title }
    public var selectedExtractionTitle: String? { extractions.first { $0.id == selectedExtractionID }?.title }
    public init(preparations: [OperationPreparationStatus], extractions: [ExtractionSnapshot], selectedExtractionID: String?, stages: [OperationStageSnapshot] = [], activeStageID: String? = nil) {
        self.preparations = preparations; self.extractions = extractions; self.selectedExtractionID = selectedExtractionID
        self.stages = stages; self.activeStageID = activeStageID
    }
}
