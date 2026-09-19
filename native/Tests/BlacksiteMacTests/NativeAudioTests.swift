import Testing
import simd
import AVFoundation
import Foundation
import BlacksiteCore
@testable import BlacksiteMac

/// Spatial decisions are pure; the engine regression renders offline without a device.
struct NativeAudioTests {
    @Test func spatialPanFollowsTheCameraRatherThanWorldAxes() {
        let origin = SIMD3<Float>(0, 1.6, 0)
        for yaw: Float in [0, .pi / 2, -.pi / 2, .pi] {
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
            let rightSample = NativeSpatialAudio.sample(.enemyShot, source: origin + right * 15, listener: origin, yaw: yaw)
            let leftSample = NativeSpatialAudio.sample(.enemyShot, source: origin - right * 15, listener: origin, yaw: yaw)
            #expect(abs(rightSample.pan - 0.9) < 0.0001)
            #expect(abs(leftSample.pan + 0.9) < 0.0001)
            #expect(abs(rightSample.gain - leftSample.gain) < 0.0001)
            for sign: Float in [-1, 1] {
                let central = NativeSpatialAudio.sample(.enemyShot, source: origin + forward * 15 * sign, listener: origin, yaw: yaw)
                #expect(abs(central.pan) < 0.0001)
            }
        }
    }

    @Test func explosionsCarryFartherAndDistanceIncludesHeight() {
        let listener = SIMD3<Float>(4, 2, 7)
        for sound in [NativeSpatialAudio.Sound.enemyShot, .explosion] {
            let near = NativeSpatialAudio.sample(sound, source: listener + SIMD3(0, 0, -4), listener: listener, yaw: 0)
            let far = NativeSpatialAudio.sample(sound, source: listener + SIMD3(0, 0, -40), listener: listener, yaw: 0)
            let overhead = NativeSpatialAudio.sample(sound, source: listener + SIMD3(0, 40, 0), listener: listener, yaw: 0)
            #expect(near.gain > far.gain && far.gain > 0)
            #expect(abs(overhead.gain - far.gain) < 0.0001)
            #expect(overhead.pan == 0)
        }
        let shot = NativeSpatialAudio.sample(.enemyShot, source: listener + SIMD3(30, 0, 0), listener: listener, yaw: 0)
        let blast = NativeSpatialAudio.sample(.explosion, source: listener + SIMD3(30, 0, 0), listener: listener, yaw: 0)
        #expect(blast.gain > shot.gain)
    }

    @Test func rangeFadeAndCoincidentSourcesStayBounded() {
        for sound in [NativeSpatialAudio.Sound.enemyShot, .explosion, .shellImpact] {
            let centred = NativeSpatialAudio.sample(sound, source: .zero, listener: .zero, yaw: 0)
            #expect(centred == NativeSpatialSample(gain: 1, pan: 0))
            let distant = NativeSpatialAudio.sample(sound, source: SIMD3(200, 0, 0), listener: .zero, yaw: 0)
            #expect(distant == .silent)
        }
        let edge = NativeSpatialAudio.sample(.enemyShot, source: SIMD3(95.99, 0, 0), listener: .zero, yaw: 0)
        #expect(edge.gain >= 0 && edge.gain < 0.0001)
    }

    @Test func shellImpactRetainsItsQuietShortRangeResponse() {
        let sample = NativeSpatialAudio.sample(.shellImpact, source: SIMD3(4, 0, 0), listener: .zero, yaw: 0)
        #expect(abs(sample.pan - 0.8) < 0.0001)
        #expect(abs(sample.gain - 1 / (1 + 16 * 0.12)) < 0.0001)
        #expect(NativeSpatialAudio.sample(.shellImpact, source: SIMD3(12, 0, 0), listener: .zero, yaw: 0) == .silent)
    }

    @Test func musicAndEffectsMuteIndependently() {
        let onlyEffects = NativeAudioLevels(music: 0, effects: 0.7)
        #expect(onlyEffects.music == 0 && onlyEffects.effects == 0.7)
        #expect(onlyEffects.shouldRun(paused: false))
        let onlyMusic = NativeAudioLevels(music: 0.7, effects: 0)
        #expect(onlyMusic.music == 0.7 && onlyMusic.effects == 0)
        #expect(onlyMusic.shouldRun(paused: false))
        #expect(!NativeAudioLevels(music: 0, effects: 0).shouldRun(paused: false))
        for levels in [onlyEffects, onlyMusic, NativeAudioLevels(music: 1, effects: 1)] {
            #expect(!levels.shouldRun(paused: true))
        }
    }

    @Test func volumeLimitsDoNotChangeTheOtherBus() {
        #expect(NativeAudioLevels(music: -0.5, effects: 0.6) == NativeAudioLevels(music: 0, effects: 0.6))
        #expect(NativeAudioLevels(music: 0.4, effects: 8) == NativeAudioLevels(music: 0.4, effects: 1))
        #expect(NativeAudioLevels(music: .nan, effects: 0.3) == NativeAudioLevels(music: 0, effects: 0.3))
    }

    // An isolated command sandbox cannot access even Apple's built-in AU
    // registry. Opt in for the system integration check; it still uses no device.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLACKSITE_TEST_SYSTEM_AUDIO"] == "1"))
    func offlineMasterLimiterAndIndependentBuses() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let audio = NativeAudio(engine: engine)
        defer { audio.setPaused(true) }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        func peak(blocks: Int) throws -> Float {
            var result: Float = 0
            for _ in 0..<blocks {
                let status = try engine.renderOffline(1024, to: buffer)
                try #require(status == .success)
                let channels = try #require(buffer.floatChannelData)
                var finite = true
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        let sample = channels[channel][frame]
                        finite = finite && sample.isFinite
                        result = max(result, abs(sample))
                    }
                }
                try #require(finite)
            }
            return result
        }

        let simulation = CombatSimulation(world: [])
        let burst = Array(repeating: GameEvent(kind: .explosion, position: simulation.eyePosition), count: 16)
        audio.setVolumes(music: 0, effects: 1); audio.setPaused(false)
        #expect(engine.isRunning)
        audio.handle(burst, simulation: simulation)
        let limitedPeak = try peak(blocks: 24)
        #expect(limitedPeak > 0.2 && limitedPeak <= 1)

        audio.setVolumes(music: 1, effects: 0)
        #expect(engine.isRunning)
        _ = try peak(blocks: 8) // Drain the limiter's short release after muting effects.
        #expect(try peak(blocks: 4) > 0.001)

        audio.setVolumes(music: 0, effects: 1)
        #expect(engine.isRunning)
        audio.handle(burst, simulation: simulation)
        #expect(try peak(blocks: 4) > 0.1)
        audio.setVolumes(music: 0, effects: 0)
        #expect(!engine.isRunning)
    }
}
