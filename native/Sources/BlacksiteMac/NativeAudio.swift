import AVFoundation
import Foundation
import simd
import BlacksiteCore

/// Precomputed native PCM voices: no allocation or synthesis in the audio callback.
final class NativeAudio {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var voices: [AVAudioPlayerNode] = []
    private let atmosphere = AVAudioPlayerNode()
    private let combat = AVAudioPlayerNode()
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var nextVoice = 0
    private var started = false
    private var paused = true
    private var stepClock: Float = 0
    private var volume: Float = 0.45
    private var threat: Float = 0
    private var alertCooldown: Float = 0

    init() {
        for _ in 0..<16 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice); engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        for node in [atmosphere, combat] {
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        buffers["rifle"] = sound(duration: 0.16, low: 140, gain: 0.28, decay: 34)
        buffers["sniper"] = sound(duration: 0.6, low: 72, gain: 0.48, decay: 10)
        buffers["enemy"] = sound(duration: 0.15, low: 155, gain: 0.12, decay: 35)
        buffers["explosion"] = sound(duration: 1.15, low: 42, gain: 0.55, decay: 5)
        buffers["step"] = sound(duration: 0.12, low: 100, gain: 0.09, decay: 36)
        buffers["damage"] = sound(duration: 0.22, low: 60, gain: 0.16, decay: 15)
        buffers["reload"] = sound(duration: 0.12, low: 530, gain: 0.08, decay: 35)
        buffers["shell"] = shellClink()
        buffers["notice"] = tone(duration: 0.35, frequency: 440, gain: 0.075)
        buffers["ambient"] = music(combat: false)
        buffers["combat"] = music(combat: true)
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value)); engine.mainMixerNode.outputVolume = volume * 0.7
        if volume == 0 { engine.pause() }
        else if !paused { start() }
    }

    func setPaused(_ value: Bool) {
        paused = value; stepClock = 0; alertCooldown = 0
        if value {
            voices.forEach { $0.stop() }
            engine.pause()
        } else if volume > 0 { start() }
    }

    private func start() {
        do {
            if !engine.isRunning { try engine.start() }
            if !started {
                atmosphere.scheduleBuffer(buffers["ambient"]!, at: nil, options: .loops, completionHandler: nil)
                combat.scheduleBuffer(buffers["combat"]!, at: nil, options: .loops, completionHandler: nil)
                atmosphere.play(); combat.play(); started = true
            }
        } catch {
            // Audio output can be unavailable after a device switch; gameplay remains usable.
            NSLog("Blacksite audio output: %@", error.localizedDescription)
        }
    }

    func handle(_ events: [GameEvent]) {
        for event in events {
            switch event.kind {
            case .shot: play(event.weapon == .sniper ? "sniper" : "rifle")
            case .enemyShot: play("enemy")
            case .enemyAlert:
                if alertCooldown <= 0 { play("notice", gain: 0.6); alertCooldown = 1.5 }
            case .explosion: play("explosion")
            case .damage: play("damage")
            case .reload: play("reload")
            case .land: play("step")
            case .waveStarted, .waveCleared, .extractionUnlocked, .supply: play("notice")
            default: break
            }
        }
    }

    func update(delta: Float, simulation: CombatSimulation) {
        alertCooldown = max(0, alertCooldown - max(0, delta))
        guard !paused, volume > 0 else { return }
        let target: Float = simulation.enemies.contains(where: { $0.health > 0 && $0.seesPlayer }) ? 1 : 0
        threat += (target - threat) * min(1, delta * 2)
        atmosphere.volume = 0.55 - threat * 0.3; combat.volume = threat * 0.45
        if simulation.isMoving && simulation.player.grounded {
            stepClock -= delta
            if stepClock <= 0 {
                play("step", gain: simulation.player.prone ? 0.35 : 1)
                stepClock = simulation.isSprinting ? 0.22 : simulation.player.prone ? 0.6 : 0.36
            }
        } else { stepClock = 0 }
    }

    func handleShellImpacts(_ impacts: [ShellImpact], simulation: CombatSimulation) {
        guard !paused, volume > 0 else { return }
        let right = SIMD3<Float>(cos(simulation.player.yaw), 0, -sin(simulation.player.yaw))
        // Limit simultaneous clicks during bursts and attenuate distant impacts.
        for impact in impacts.prefix(3) {
            let offset = impact.position - simulation.eyePosition
            let distance = simd_length(offset)
            guard distance < 12, impact.speed > 0.65 else { continue }
            let gain = min(0.65, impact.speed * 0.10) / (1 + distance * distance * 0.12)
            let pan = simd_dot(offset / max(0.1, distance), right) * 0.8
            play("shell", gain: gain, pan: pan)
        }
    }

    private func play(_ name: String, gain: Float = 1, pan: Float = 0) {
        guard !paused, volume > 0, let buffer = buffers[name], engine.isRunning else { return }
        let voice = voices[nextVoice]; nextVoice = (nextVoice + 1) % voices.count
        voice.stop(); voice.volume = gain; voice.pan = pan; voice.scheduleBuffer(buffer); voice.play()
    }

    private func shellClink() -> AVAudioPCMBuffer {
        // Short, inharmonic brass resonances; synthesized once, then reused.
        pcm(duration: 0.13) { t, _ in
            let strike = sin(t * 7_810 * 2 * .pi) * exp(-t * 210)
            let ring = sin(t * 3_270 * 2 * .pi) * exp(-t * 49)
                + sin(t * 5_140 * 2 * .pi) * exp(-t * 68) * 0.45
            return Float((strike * 0.5 + ring) * min(1, t * 5_000) * 0.095)
        }
    }

    private func pcm(duration: Double, generate: (Double, Int) -> Float) -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(count) { samples[i] = max(-0.8, min(0.8, generate(Double(i) / format.sampleRate, i))) }
        return buffer
    }

    private func sound(duration: Double, low: Double, gain: Double, decay: Double) -> AVAudioPCMBuffer {
        var random: UInt32 = 7127; var filtered = 0.0
        return pcm(duration: duration) { t, _ in
            random = random &* 1_664_525 &+ 1_013_904_223
            let noise = Double(random) / Double(UInt32.max) * 2 - 1
            filtered += (noise - filtered) * 0.22
            let envelope = min(1, t * 1400) * exp(-t * decay)
            let body = sin(2 * Double.pi * (low * t - low * 0.2 * t * t))
            return Float((filtered * 0.75 + body * 0.25) * envelope * gain)
        }
    }

    private func tone(duration: Double, frequency: Double, gain: Double) -> AVAudioPCMBuffer {
        pcm(duration: duration) { t, _ in Float(sin(t * frequency * 2 * .pi) * gain * sin(t / duration * .pi)) }
    }

    private func music(combat: Bool) -> AVAudioPCMBuffer {
        // Eight original bars, with sample-aligned looping and quiet headroom.
        let beat = 60.0 / 144, duration = beat * 32
        var seed: UInt32 = 9234; var filtered = 0.0
        return pcm(duration: duration) { t, _ in
            let fade = min(1, t * 4, (duration - t) * 4)
            if !combat {
                return Float((sin(t * 55 * 2 * .pi) * 0.025 + sin(t * 82.5 * 2 * .pi) * 0.017 + sin(t * 110 * 2 * .pi) * 0.01) * (0.8 + sin(t * 0.45) * 0.2) * fade)
            }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            filtered += (Double(seed) / Double(UInt32.max) * 2 - 1 - filtered) * 0.35
            let b = t.truncatingRemainder(dividingBy: beat)
            let kick = sin(2 * .pi * (55 * b + 7 * (1 - exp(-b * 35)))) * exp(-b * 22) * 0.16
            let snare = Int(t / beat) % 2 == 1 ? filtered * exp(-b * 24) * 0.09 : 0
            let hat = filtered * exp(-t.truncatingRemainder(dividingBy: beat * 0.5) * 85) * 0.025
            let notes = [55.0, 55, 65.406, 49.0]
            let bass = tanh(sin(t * notes[Int(t / (beat * 8)) % 4] * 2 * .pi) * 2) * 0.032 * exp(-b * 5)
            return Float((kick + snare + hat + bass) * fade)
        }
    }

    deinit { engine.stop() }
}
