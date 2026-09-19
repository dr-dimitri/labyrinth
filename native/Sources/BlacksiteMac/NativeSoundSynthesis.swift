import Foundation
import BlacksiteCore

/// Original, deterministic PCM generated once when the audio bank is created.
/// All render callbacks consume cached buffers; no synthesis runs on that thread.
enum NativeSoundSynthesis {
    static let sampleRate = 44_100.0
    static let variants = 3

    static func step(surface: SurfaceSound, variant: Int) -> [Float] {
        let choice = ((variant % variants) + variants) % variants
        let duration: Double
        switch surface {
        case .earth: duration = 0.19
        case .vegetation: duration = 0.25
        case .gravel: duration = 0.23
        case .metal: duration = 0.32
        case .water: duration = 0.32
        case .hard: duration = 0.15
        case .wood: duration = 0.21
        }
        var seed = UInt32(18_013 + choice * 7_919), filtered = 0.0
        let pitch = 0.93 + Double(choice) * 0.07
        return samples(duration: duration) { t in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            filtered += (noise - filtered) * 0.12
            let transient = min(1, t * 1_600), heel = sin(t * 105 * pitch * 2 * .pi) * exp(-t * 35)
            let signal: Double
            switch surface {
            case .earth:
                signal = filtered * exp(-t * 23) * 0.34 + heel * 0.12
            case .vegetation:
                let rustle = (noise - filtered) * (0.55 + 0.45 * sin(t * 39 + 0.8))
                signal = rustle * exp(-t * 17) * 0.10 + heel * 0.055
            case .gravel:
                let grains = (noise - filtered) * pow(0.5 + 0.5 * sin(t * 730 * pitch), 2)
                signal = grains * exp(-t * 19) * 0.27 + heel * 0.10
            case .metal:
                let ring = sin(t * 1_190 * pitch * 2 * .pi) * 0.075
                    + sin(t * 2_370 * pitch * 2 * .pi) * 0.038
                signal = heel * 0.12 + noise * exp(-t * 90) * 0.14 + ring * exp(-t * 17)
            case .water:
                let splash = filtered * exp(-t * 12) * 0.38
                let drop = sin((620 * t - 540 * t * t) * pitch * 2 * .pi) * exp(-t * 19) * 0.055
                signal = splash + drop + heel * 0.025
            case .hard:
                signal = noise * exp(-t * 65) * 0.16 + heel * 0.16
                    + sin(t * 670 * pitch * 2 * .pi) * exp(-t * 45) * 0.045
            case .wood:
                signal = filtered * exp(-t * 32) * 0.12 + heel * 0.12
                    + sin(t * 420 * pitch * 2 * .pi) * exp(-t * 25) * 0.075
                    + sin(t * 790 * pitch * 2 * .pi) * exp(-t * 37) * 0.025
            }
            return signal * transient * min(1, (duration - t) * 180)
        }
    }

    static func machine() -> [Float] {
        // Integer harmonic periods make the two-second loop sample-continuous.
        samples(duration: 2) { t in
            let rumble = sin(t * 45 * 2 * .pi) * 0.095 + sin(t * 90 * 2 * .pi) * 0.034
            let motor = sin(t * 315 * 2 * .pi) * 0.024 + sin(t * 631 * 2 * .pi) * 0.009
            let rattle = sin(t * 1_117 * 2 * .pi) * sin(t * 37 * 2 * .pi) * 0.008
            return (rumble + motor) * (0.86 + 0.14 * cos(t * 2 * .pi)) + rattle
        }
    }

    static func decoy() -> [Float] {
        samples(duration: 0.42) { t in
            let click = sin(t * 1_790 * 2 * .pi) * exp(-t * 100) * 0.16
            let ring = sin(t * 840 * 2 * .pi) * exp(-t * 17) * 0.10
                + sin(t * 1_370 * 2 * .pi) * exp(-t * 23) * 0.04
            return (click + ring) * min(1, t * 2_000) * min(1, (0.42 - t) * 180)
        }
    }

    private static func samples(duration: Double, generate: (Double) -> Double) -> [Float] {
        (0..<Int(duration * sampleRate)).map { frame in
            Float(max(-0.8, min(0.8, generate(Double(frame) / sampleRate))))
        }
    }
}
