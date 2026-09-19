import Foundation
import simd

/// Pure mixing decisions, shared by the live engine and hardware-free tests.
struct NativeAudioLevels: Equatable, Sendable {
    let music: Float
    let effects: Float

    init(music: Float = 0.45, effects: Float = 0.45) {
        self.music = Self.clamped(music)
        self.effects = Self.clamped(effects)
    }

    func shouldRun(paused: Bool) -> Bool { !paused && (music > 0 || effects > 0) }

    private static func clamped(_ value: Float) -> Float {
        value.isFinite ? max(0, min(1, value)) : 0
    }
}

struct NativeSpatialSample: Equatable, Sendable {
    let gain: Float
    let pan: Float
    static let silent = NativeSpatialSample(gain: 0, pan: 0)
}

enum NativeSpatialAudio {
    enum Sound: Sendable {
        case enemyShot, explosion, shellImpact

        fileprivate var falloff: Float {
            switch self {
            case .enemyShot: return 1 / (18 * 18)
            case .explosion: return 1 / (26 * 26)
            case .shellImpact: return 0.12
            }
        }

        fileprivate var range: Float {
            switch self {
            case .enemyShot: return 96
            case .explosion: return 120
            case .shellImpact: return 12
            }
        }

        fileprivate var width: Float { self == .shellImpact ? 0.8 : 0.9 }
    }

    /// The camera faces (-sin(yaw), 0, -cos(yaw)); positive pan is screen right.
    /// Height contributes to distance and reduces hard panning for overhead sounds.
    static func sample(_ sound: Sound, source: SIMD3<Float>, listener: SIMD3<Float>,
                       yaw: Float) -> NativeSpatialSample {
        let offset = source - listener
        let distanceSquared = simd_length_squared(offset)
        guard distanceSquared.isFinite, yaw.isFinite,
              distanceSquared < sound.range * sound.range else { return .silent }
        let distance = sqrt(distanceSquared)
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let pan = max(-sound.width, min(sound.width,
            simd_dot(offset / max(0.1, distance), right) * sound.width))
        var gain = 1 / (1 + distanceSquared * sound.falloff)
        // Combat sounds fade out at the arena's far edge; keep the established
        // short-range brass response unchanged.
        if sound != .shellImpact {
            gain *= min(1, (sound.range - distance) / (sound.range * 0.2))
        }
        return NativeSpatialSample(gain: gain, pan: pan)
    }
}
