import simd

public enum MissionKind: String, CaseIterable, Hashable, Sendable {
    case waves, recoverData, secureRadio, operation
}

public enum MissionPhase: String, Sendable {
    case waves, prepareOperation, collectData, extract, activateRadio, holdRadio, completed
}

public enum MissionInterruption: String, Sendable {
    case outOfRange, notGrounded, interactionReleased, contested, blocked
}

/// Read-only objective rules for native UI, accessibility and world markers.
/// Progress values are seconds except in the waves phase, which counts kills.
/// Objective positions are already grounded on the simulation's terrain.
public struct MissionStatus: Sendable {
    public let kind: MissionKind
    public let phase: MissionPhase
    public let objectivePosition: SIMD3<Float>?
    public let objectiveRadius: Float
    public let distance: Float?
    public let progress: Float
    public let requiredProgress: Float
    public let interruption: MissionInterruption?
    public let interactionAvailable: Bool
    public let extractionID: String?

    public init(kind: MissionKind, phase: MissionPhase, objectivePosition: SIMD3<Float>?,
                objectiveRadius: Float, distance: Float?, progress: Float, requiredProgress: Float,
                interruption: MissionInterruption?, interactionAvailable: Bool, extractionID: String? = nil) {
        self.kind = kind; self.phase = phase; self.objectivePosition = objectivePosition
        self.objectiveRadius = objectiveRadius; self.distance = distance
        self.progress = progress; self.requiredProgress = requiredProgress
        self.interruption = interruption; self.interactionAvailable = interactionAvailable; self.extractionID = extractionID
    }
}
