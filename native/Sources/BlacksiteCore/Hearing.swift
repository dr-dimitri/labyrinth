import Foundation
import simd

public enum SurfaceSound: String, CaseIterable, Sendable {
    case earth, vegetation, gravel, metal, water, hard, wood
    var stepRange: Float {
        switch self { case .earth: return 9; case .vegetation: return 6; case .gravel: return 14
        case .metal: return 18; case .water: return 15; case .hard: return 12; case .wood: return 11 }
    }
    static func fallback(_ surface: SurfaceMaterial) -> SurfaceSound {
        switch surface { case .soil: return .earth; case .metal: return .metal; case .wood: return .wood
        case .concrete, .asphalt: return .hard }
    }
}
public enum HearingKind: String, Sendable { case footstep, landing, gunshot, explosion, decoy, shout, radio }
public enum NoiseSource: String, Sendable { case player, enemy, world }

/// An immutable source snapshot, independent of audio settings and later actor movement.
public struct HearingStimulus: Sendable {
    public let id: Int
    public let kind: HearingKind
    public let position: SIMD3<Float>
    public let surface: SurfaceSound?
    public let time: Double
    public let strength: Float, range: Float
    public let source: NoiseSource
    public let sourceID: Int?
    public init(id: Int, kind: HearingKind, position: SIMD3<Float>, surface: SurfaceSound? = nil,
                time: Double, strength: Float, range: Float, source: NoiseSource, sourceID: Int? = nil) {
        self.id = id; self.kind = kind; self.position = position; self.surface = surface; self.time = time
        self.strength = strength; self.range = range; self.source = source; self.sourceID = sourceID
    }
}

/// What a guard actually heard. No reference to the current player is retained.
public struct HearingObservation: Sendable {
    public let position: SIMD3<Float>
    public let kind: HearingKind
    public let time: Double
}

public struct AcousticSample: Sendable {
    public let gain: Float, transmission: Float, masking: Float
    public let audible: Bool
}

/// Authored position is terrain-relative; owner identifies an existing housing,
/// which can also control the renderer's indicator and acoustic source aperture.
public struct NoiseEmitterDefinition: Sendable {
    public let id: Int
    public let position: SIMD3<Float>
    public let enabled: Bool
    public let strength: Float, range: Float
    public let ownerObstacleID: Int?
    public init(id: Int, position: SIMD3<Float>, enabled: Bool = true, strength: Float = 0.8,
                range: Float = 18, ownerObstacleID: Int? = nil) {
        self.id = id; self.position = position; self.enabled = enabled; self.strength = strength
        self.range = range; self.ownerObstacleID = ownerObstacleID
    }
}
public struct NoiseEmitterState: Sendable {
    public static let maximumCount = 4
    public let id: Int
    public let position: SIMD3<Float>
    public var enabled: Bool
    public let strength: Float, range: Float
    public let ownerObstacleID: Int?
    public init(id: Int, position: SIMD3<Float>, enabled: Bool = true, strength: Float = 0.8,
                range: Float = 18, ownerObstacleID: Int? = nil) {
        self.id = id; self.position = position; self.enabled = enabled; self.strength = strength
        self.range = range; self.ownerObstacleID = ownerObstacleID
    }
}
public struct NoiseDecoyState: Sendable {
    public static let maximumCount = 2
    public let id: Int
    public var position: SIMD3<Float>, velocity: SIMD3<Float>
    public var age: Float = 0
    public let lifetime: Float = 12
    var emittedPulses = 0
}

extension CombatSimulation {
    /// Shared propagation for AI decisions and audio output. No mixer setting is
    /// read here. Solid occlusion attenuates rather than becoming a binary sound wall.
    public func acousticSample(for stimulus: HearingStimulus, listener: SIMD3<Float>) -> AcousticSample {
        let distance = simd_distance(listener, stimulus.position)
        guard distance.isFinite, stimulus.range.isFinite, stimulus.range > 0,
              stimulus.strength.isFinite, stimulus.strength > 0 else {
            return AcousticSample(gain: 0, transmission: 0, masking: 0, audible: false)
        }
        let transmission = acousticTransmission(from: stimulus.position, to: listener)
        let gain = clamp(stimulus.strength, 0, 1) * max(0, 1 - distance / stimulus.range) * transmission
        var masking: Float = 0
        for emitter in noiseEmitters where emitter.enabled {
            masking += noiseEmitterGain(emitter, listener: listener)
        }
        masking = min(0.65, masking)
        let conspicuous = stimulus.kind == .explosion || (stimulus.kind == .gunshot && distance <= 6)
        let threshold: Float = 0.12 + masking * (conspicuous ? 0.05 : 0.3)
        return AcousticSample(gain: gain, transmission: transmission, masking: masking, audible: gain >= threshold)
    }

    public func noiseEmitterGain(_ emitter: NoiseEmitterState, listener: SIMD3<Float>) -> Float {
        guard emitter.enabled, emitter.range.isFinite, emitter.range > 0, emitter.strength.isFinite else { return 0 }
        if let owner = emitter.ownerObstacleID,
           !obstacles.contains(where: { $0.id == owner && !$0.destroyed }) { return 0 }
        let distance = simd_distance(emitter.position, listener)
        guard distance.isFinite, distance < emitter.range else { return 0 }
        return clamp(emitter.strength, 0, 1) * (1 - distance / emitter.range) *
            acousticTransmission(from: emitter.position, to: listener, excludingOwner: emitter.ownerObstacleID)
    }

    private func acousticTransmission(from: SIMD3<Float>, to: SIMD3<Float>, excludingOwner: Int? = nil) -> Float {
        let offset = to - from, distance = simd_length(offset)
        guard distance.isFinite, distance > 0.01 else { return 1 }
        let excluded = excludingOwner.flatMap { id in obstacles.firstIndex { $0.id == id } }
        let hit = wallHit(origin: from, direction: offset / distance, maximumDistance: distance, excludingObstacle: excluded)
        return hit.distance >= distance - 0.02 ? 1 : hit.hitGround ? 0.3 : 0.4
    }
}
