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
        case .glass: duration = 0.29
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
            case .glass:
                let crunch = (noise-filtered) * pow(0.5+0.5*sin(t*970*pitch),3) * exp(-t*21) * 0.15
                let chink = (sin(t*3_170*pitch*2 * .pi)+0.4*sin(t*5_630*pitch*2 * .pi)) * exp(-t*23) * 0.038
                signal = crunch + chink + heel*0.045
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

    /// One sharp fracture followed by a finite scatter of light pieces. Both
    /// sources are original PCM and share the existing limited one-shot voices.
    static func breakage(kind: BreachKind) -> [Float] {
        let glass = kind == .glass, duration = glass ? 0.68 : 0.42
        var seed: UInt32 = glass ? 71_299 : 34_819, filtered = 0.0
        return samples(duration: duration) { t in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed)/Double(UInt32.max)*2-1
            filtered += (noise-filtered)*0.16
            let attack = min(1,t*2_000), ending = min(1,(duration-t)*180)
            if glass {
                let crack = (noise-filtered)*exp(-t*70)*0.30
                let scatter = (noise-filtered)*pow(0.5+0.5*sin(t*139),6)*exp(-t*7)*0.12
                let ringing = (sin(t*2_730*2 * .pi)+0.55*sin(t*4_190*2 * .pi)+0.3*sin(t*6_170*2 * .pi))*exp(-t*11)*0.08
                return (crack+scatter+ringing)*attack*ending
            }
            let tear = (noise-filtered)*exp(-t*22)*0.14
            let body = sin(t*135*2 * .pi)*exp(-t*15)*0.12
            let rattle = (sin(t*730*2 * .pi)+0.4*sin(t*1_430*2 * .pi))*exp(-t*13)*0.05
            return (tear+body+rattle)*attack*ending
        }
    }

    /// A brief original nonverbal contact call. Fixed formant bands and a voiced
    /// onset distinguish a nearby human warning from an electronic radio cue;
    /// no speech service, recording download or runtime synthesis is required.
    static func contactCall() -> [Float] {
        let duration=0.46
        var seed:UInt32=91_441
        return samples(duration:duration) { t in
            seed=seed &* 1_664_525 &+ 1_013_904_223
            let noise=Double(seed)/Double(UInt32.max)*2-1
            let opening=min(1,max(0,(t-0.03)/0.10)),ending=min(1,max(0,(duration-t)/0.12))
            let fundamental=155+45*exp(-t*8)
            let phase=2*Double.pi*(155*t+45*(1-exp(-t*8))/8)
            let firstFormant=590+210*opening,secondFormant=1_660-510*opening
            var voiced=0.0
            for harmonic in 1...20 {
                let frequency=Double(harmonic)*fundamental
                let band=exp(-pow((frequency-firstFormant)/200,2))*0.8
                    + exp(-pow((frequency-secondFormant)/310,2))*0.46
                    + exp(-pow((frequency-2_700)/500,2))*0.19
                voiced+=sin(phase*Double(harmonic))*band/pow(Double(harmonic),0.48)
            }
            let breath=noise*exp(-t*22)*0.042
            return (voiced*0.15+breath)*min(1,t*90)*ending*(0.8+0.2*sin(t*11))
        }
    }

    /// Distinct push-to-talk and completed-transmission syllables, synthesized
    /// once into the existing bounded one-shot bank, never additional loops.
    static func radioContact(transmitted:Bool)->[Float] {
        let duration=transmitted ? 0.30:0.19
        var seed:UInt32=transmitted ? 41_991:52_301,low=0.0
        return samples(duration:duration) { t in
            seed=seed &* 1_664_525 &+ 1_013_904_223
            let noise=Double(seed)/Double(UInt32.max)*2-1
            low+=(noise-low)*0.23
            let tone:Double
            if transmitted {
                let first=sin(t*1_020*2*Double.pi)*exp(-pow((t-0.055)/0.038,2))
                let second=sin(t*740*2*Double.pi)*exp(-pow((t-0.155)/0.044,2))
                tone=(first+second)*0.11
            } else { tone=sin(t*640*2*Double.pi)*exp(-pow((t-0.065)/0.045,2))*0.10 }
            let staticNoise=(noise-low)*0.028*exp(-t*10)
            return (tone+staticNoise)*min(1,t*800)*min(1,(duration-t)*140)
        }
    }

    static func radioInterruption()->[Float] {
        var seed:UInt32=19_347,low=0.0
        return samples(duration:0.21) { t in
            seed=seed &* 1_664_525 &+ 1_013_904_223
            let noise=Double(seed)/Double(UInt32.max)*2-1
            low+=(noise-low)*0.17
            let dropping=sin((780*t-1_350*t*t)*2*Double.pi)*exp(-t*14)*0.12
            let squelch=(noise-low)*0.055*exp(-t*11)
            return (dropping+squelch)*min(1,t*650)*min(1,(0.21-t)*150)
        }
    }

    private static func samples(duration: Double, generate: (Double) -> Double) -> [Float] {
        (0..<Int(duration * sampleRate)).map { frame in
            Float(max(-0.8, min(0.8, generate(Double(frame) / sampleRate))))
        }
    }
}
