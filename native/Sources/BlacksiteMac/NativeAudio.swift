import AVFoundation
import AudioToolbox
import Foundation
import simd
import BlacksiteCore

/// Uses the actual heard fracture, without inferring a position from an opening
/// or a current owner. Pure selection is testable without an audio device.
struct NativeBreakageAudioCue {
    let bufferName: String
    let spatial: NativeSpatialSample
    static func make(event: GameEvent, simulation: CombatSimulation) -> NativeBreakageAudioCue? {
        guard event.kind == .breachOpened, let sound = event.hearing, sound.kind == .breakage else { return nil }
        let sample = simulation.acousticSample(for: sound, listener: simulation.eyePosition)
        guard sample.audible else { return nil }
        return NativeBreakageAudioCue(bufferName: sound.surface == .glass ? "break-glass" : "break-panel",
            spatial: NativeSpatialAudio.positioned(gain: sample.gain, source: sound.position,
                listener: simulation.eyePosition, yaw: simulation.player.yaw))
    }
}

/// Precomputed native PCM voices: no allocation or synthesis in the audio callback.
final class NativeAudio {
    private let engine: AVAudioEngine
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var voices: [AVAudioPlayerNode] = []
    private var machineVoices: [AVAudioPlayerNode] = []
    private var machineIDs: [Int?] = Array(repeating:nil,count:NoiseEmitterState.maximumCount)
    private var machineGains: [Float] = Array(repeating:0,count:NoiseEmitterState.maximumCount)
    private let atmosphere = AVAudioPlayerNode()
    private let combat = AVAudioPlayerNode()
    private let musicBus = AVAudioMixerNode()
    private let effectsBus = AVAudioMixerNode()
    private let masterBus = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var nextVoice = 0
    private var started = false
    private var paused = true
    private var levels = NativeAudioLevels()
    private var threat: Float = 0
    private var contactSoundIDs:[Int]=[]
    private var breakageSoundIDs:[Int]=[]
    private var warningSoundIDs: [Int] = []
    var machineLoopCount: Int { machineIDs.compactMap { $0 }.count }
    var oneShotVoiceCapacity: Int { voices.count }
    var machineVoiceCapacity: Int { machineVoices.count }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.attach(masterBus)
        for node in [musicBus, effectsBus] {
            engine.attach(node); engine.connect(node, to: masterBus, format: stereo)
        }
        engine.attach(limiter)
        // Both independently controlled buses pass through one master limiter.
        // Leave the main mixer's hardware-format negotiation intact, and keep
        // a little output headroom after limiting synchronized combat transients.
        engine.connect(masterBus, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        for (parameter, value) in [(kLimiterParam_AttackTime, Float(0.001)),
                                   (kLimiterParam_DecayTime, Float(0.06)),
                                   (kLimiterParam_PreGain, Float(0))] {
            let status = AudioUnitSetParameter(limiter.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
            if status != noErr { NSLog("Blacksite audio limiter parameter: %d", status) }
        }
        for _ in 0..<16 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice); engine.connect(voice, to: effectsBus, format: format)
            voices.append(voice)
        }
        for _ in 0..<NoiseEmitterState.maximumCount {
            let voice=AVAudioPlayerNode()
            engine.attach(voice);engine.connect(voice,to:effectsBus,format:format)
            machineVoices.append(voice)
        }
        for node in [atmosphere, combat] {
            engine.attach(node); engine.connect(node, to: musicBus, format: format)
        }
        buffers["rifle"] = sound(duration: 0.16, low: 140, gain: 0.28, decay: 34)
        buffers["sniper"] = sound(duration: 0.6, low: 72, gain: 0.48, decay: 10)
        buffers["enemy"] = sound(duration: 0.15, low: 155, gain: 0.12, decay: 35)
        buffers["explosion"] = sound(duration: 1.15, low: 42, gain: 0.55, decay: 5)
        for surface in SurfaceSound.allCases { for variant in 0..<NativeSoundSynthesis.variants {
            buffers["step-\(surface.rawValue)-\(variant)"]=pcm(samples:NativeSoundSynthesis.step(surface:surface,variant:variant))
        } }
        buffers["machine"]=pcm(samples:NativeSoundSynthesis.machine())
        buffers["decoy"]=pcm(samples:NativeSoundSynthesis.decoy())
        buffers["gust"] = pcm(samples: NativeSoundSynthesis.gust())
        buffers["break-glass"]=pcm(samples:NativeSoundSynthesis.breakage(kind:.glass))
        buffers["break-panel"]=pcm(samples:NativeSoundSynthesis.breakage(kind:.lightPanel))
        buffers["contact-call"]=pcm(samples:NativeSoundSynthesis.contactCall())
        buffers["contact-radioBegin"]=pcm(samples:NativeSoundSynthesis.radioContact(transmitted:false))
        buffers["contact-radioSent"]=pcm(samples:NativeSoundSynthesis.radioContact(transmitted:true))
        buffers["contact-radioInterrupted"]=pcm(samples:NativeSoundSynthesis.radioInterruption())
        buffers["damage"] = sound(duration: 0.22, low: 60, gain: 0.16, decay: 15)
        buffers["reload"] = sound(duration: 0.12, low: 530, gain: 0.08, decay: 35)
        buffers["shell"] = shellClink()
        buffers["notice"] = tone(duration: 0.35, frequency: 440, gain: 0.075)
        buffers["ambient"] = music(combat: false)
        buffers["combat"] = music(combat: true)
        musicBus.outputVolume = levels.music; effectsBus.outputVolume = levels.effects
        atmosphere.volume = 0.55; combat.volume = 0
        masterBus.outputVolume = 0.7; engine.mainMixerNode.outputVolume = 0.9
        engine.prepare()
    }

    func setVolumes(music: Float, effects: Float) {
        levels = NativeAudioLevels(music: music, effects: effects)
        musicBus.outputVolume = levels.music; effectsBus.outputVolume = levels.effects
        if levels.effects == 0 { voices.forEach { $0.stop() };stopMachines() }
        if levels.shouldRun(paused: paused) { start() }
        else { engine.pause() }
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value {
            voices.forEach { $0.stop() }
            stopMachines()
            engine.pause()
        } else if levels.shouldRun(paused: paused) { start() }
    }

    func reset() {
        voices.forEach { $0.stop() };stopMachines()
        nextVoice=0;contactSoundIDs.removeAll(keepingCapacity:true);breakageSoundIDs.removeAll(keepingCapacity:true);warningSoundIDs.removeAll(keepingCapacity:true);threat=0
    }

    private func stopMachines() {
        for index in machineVoices.indices {
            machineVoices[index].stop();machineIDs[index]=nil;machineGains[index]=0
        }
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

    func handle(_ events: [GameEvent], simulation: CombatSimulation) {
        guard !paused, levels.effects > 0 else { return }
        for event in events {
            switch event.kind {
            case .shot: play(event.weapon == .sniper ? "sniper" : "rifle")
            case .enemyShot:
                let spatial = spatial(event, fallback:.enemyShot,simulation:simulation)
                play("enemy", gain: spatial.gain, pan: spatial.pan)
            case .contactReportStarted, .contactReportTransmitted, .contactReportInterrupted:
                if let hearing=event.hearing,!contactSoundIDs.contains(hearing.id),
                   let cue=NativeContactAudioCue.make(event:event,simulation:simulation) {
                    contactSoundIDs.append(hearing.id)
                    if contactSoundIDs.count>64 { contactSoundIDs.removeFirst(contactSoundIDs.count-64) }
                    play("contact-\(cue.kind.rawValue)",gain:cue.spatial.gain,pan:cue.spatial.pan)
                }
            case .explosion:
                let spatial = spatial(event,fallback:.explosion,simulation:simulation)
                play("explosion", gain: spatial.gain, pan: spatial.pan)
            case .breachOpened:
                if let hearing=event.hearing,!breakageSoundIDs.contains(hearing.id),
                   let cue=NativeBreakageAudioCue.make(event:event,simulation:simulation) {
                    breakageSoundIDs.append(hearing.id)
                    if breakageSoundIDs.count>64 { breakageSoundIDs.removeFirst(breakageSoundIDs.count-64) }
                    play(cue.bufferName,gain:cue.spatial.gain,pan:cue.spatial.pan)
                }
            case .smokeWarning:
                if let hearing = event.hearing, !warningSoundIDs.contains(hearing.id),
                   let cue = NativeSmokeWarningCue.make(event: event, simulation: simulation) {
                    warningSoundIDs.append(hearing.id)
                    if warningSoundIDs.count > 64 { warningSoundIDs.removeFirst(warningSoundIDs.count - 64) }
                    play("gust", gain: cue.spatial.gain, pan: cue.spatial.pan)
                }
            case .damage: play("damage")
            case .reload: play("reload")
            case .footstep, .land:
                if let hearing=event.hearing {
                    let sample=simulation.acousticSample(for:hearing,listener:simulation.eyePosition)
                    let spatial=NativeSpatialAudio.positioned(gain:sample.gain,source:hearing.position,
                        listener:simulation.eyePosition,yaw:simulation.player.yaw)
                    let variant=Int(hearing.id.magnitude % UInt(NativeSoundSynthesis.variants))
                    play("step-\((hearing.surface ?? .hard).rawValue)-\(variant)",gain:spatial.gain,pan:spatial.pan)
                }
            case .decoyPulse:
                if let hearing=event.hearing {
                    let sample=simulation.acousticSample(for:hearing,listener:simulation.eyePosition)
                    let spatial=NativeSpatialAudio.positioned(gain:sample.gain,source:hearing.position,
                        listener:simulation.eyePosition,yaw:simulation.player.yaw)
                    play("decoy",gain:spatial.gain,pan:spatial.pan)
                }
            case .waveStarted, .waveCleared, .extractionUnlocked, .supply: play("notice")
            case .missionPhaseChanged:
                if let phase = event.missionPhase, phase != .completed { play("notice") }
            default: break
            }
        }
    }

    func update(delta: Float, simulation: CombatSimulation) {
        guard levels.shouldRun(paused: paused) else { return }
        let target: Float = simulation.enemies.contains(where: { $0.health > 0 && $0.seesPlayer }) ? 1 : 0
        threat += (target - threat) * min(1, delta * 2)
        atmosphere.volume = 0.55 - threat * 0.3; combat.volume = threat * 0.45
        updateMachines(delta:delta,simulation:simulation)
    }

    private func spatial(_ event:GameEvent,fallback:NativeSpatialAudio.Sound,simulation:CombatSimulation)->NativeSpatialSample {
        if let hearing=event.hearing {
            let sample=simulation.acousticSample(for:hearing,listener:simulation.eyePosition)
            return NativeSpatialAudio.positioned(gain:sample.gain,source:hearing.position,
                listener:simulation.eyePosition,yaw:simulation.player.yaw)
        }
        return NativeSpatialAudio.sample(fallback,source:event.position,listener:simulation.eyePosition,yaw:simulation.player.yaw)
    }

    private func updateMachines(delta:Float,simulation:CombatSimulation) {
        guard !paused,levels.effects>0,engine.isRunning else { stopMachines();return }
        let audible=simulation.noiseEmitters.compactMap { emitter -> (NoiseEmitterState,Float)? in
            let gain=simulation.noiseEmitterGain(emitter,listener:simulation.eyePosition)
            return gain>0.001 ? (emitter,gain):nil
        }
        for index in machineVoices.indices {
            guard let id=machineIDs[index] else { continue }
            if !audible.contains(where:{ $0.0.id==id }) {
                machineVoices[index].stop();machineIDs[index]=nil;machineGains[index]=0
            }
        }
        for (emitter,gain) in audible {
            guard let index=machineIDs.firstIndex(where:{ $0==emitter.id }) ?? machineIDs.firstIndex(where:{ $0==nil }) else { break }
            let voice=machineVoices[index]
            if machineIDs[index] == nil {
                voice.stop();voice.volume=0
                voice.scheduleBuffer(buffers["machine"]!,at:nil,options:.loops,completionHandler:nil)
                voice.play();machineIDs[index]=emitter.id
            }
            machineGains[index]+=(gain-machineGains[index])*min(1,max(0,delta)*8)
            let spatial=NativeSpatialAudio.positioned(gain:machineGains[index],source:emitter.position,
                listener:simulation.eyePosition,yaw:simulation.player.yaw)
            voice.volume=spatial.gain;voice.pan=spatial.pan
        }
    }

    func handleShellImpacts(_ impacts: [ShellImpact], simulation: CombatSimulation) {
        guard !paused, levels.effects > 0 else { return }
        // Limit simultaneous clicks during bursts and attenuate distant impacts.
        for impact in impacts.prefix(3) {
            guard impact.speed > 0.65 else { continue }
            let spatial = NativeSpatialAudio.sample(.shellImpact, source: impact.position,
                listener: simulation.eyePosition, yaw: simulation.player.yaw)
            play("shell", gain: min(0.65, impact.speed * 0.10) * spatial.gain, pan: spatial.pan)
        }
    }

    private func play(_ name: String, gain: Float = 1, pan: Float = 0) {
        guard !paused, levels.effects > 0, gain > 0, let buffer = buffers[name], engine.isRunning else { return }
        let voice = voices[nextVoice]; nextVoice = (nextVoice + 1) % voices.count
        voice.stop(); voice.volume = max(0, min(1, gain)); voice.pan = max(-1, min(1, pan))
        voice.scheduleBuffer(buffer); voice.play()
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

    private func pcm(samples:[Float])->AVAudioPCMBuffer {
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(samples.count))!
        buffer.frameLength=AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from:source.baseAddress!,count:source.count)
        }
        return buffer
    }

    private func sound(duration: Double, low: Double, gain: Double, decay: Double) -> AVAudioPCMBuffer {
        var random: UInt32 = 7127; var filtered = 0.0
        return pcm(duration: duration) { (t: Double, _: Int) -> Float in
            random = random &* 1_664_525 &+ 1_013_904_223
            let noise = Double(random) / Double(UInt32.max) * 2 - 1
            filtered += (noise - filtered) * 0.22
            let envelope = min(1, t * 1400) * exp(-t * decay)
            let phase: Double = low * t - low * 0.2 * t * t
            let body = sin(2 * Double.pi * phase)
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
        return pcm(duration: duration) { (t: Double, _: Int) -> Float in
            let fade = min(1, t * 4, (duration - t) * 4)
            if !combat {
                let fundamental: Double = sin(t * 55 * 2 * Double.pi) * 0.025
                let fifth: Double = sin(t * 82.5 * 2 * Double.pi) * 0.017
                let octave: Double = sin(t * 110 * 2 * Double.pi) * 0.01
                let modulation: Double = 0.8 + sin(t * 0.45) * 0.2
                return Float((fundamental + fifth + octave) * modulation * fade)
            }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            filtered += (Double(seed) / Double(UInt32.max) * 2 - 1 - filtered) * 0.35
            let b = t.truncatingRemainder(dividingBy: beat)
            let kickPhase: Double = 55 * b + 7 * (1 - exp(-b * 35))
            let kick: Double = sin(2 * Double.pi * kickPhase) * exp(-b * 22) * 0.16
            let snare = Int(t / beat) % 2 == 1 ? filtered * exp(-b * 24) * 0.09 : 0
            let hat = filtered * exp(-t.truncatingRemainder(dividingBy: beat * 0.5) * 85) * 0.025
            let notes = [55.0, 55, 65.406, 49.0]
            let note: Double = notes[Int(t / (beat * 8)) % 4]
            let bass: Double = tanh(sin(t * note * 2 * Double.pi) * 2) * 0.032 * exp(-b * 5)
            return Float((kick + snare + hat + bass) * fade)
        }
    }

    deinit { engine.stop() }
}
