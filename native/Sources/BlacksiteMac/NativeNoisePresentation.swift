import Foundation
import simd
import BlacksiteCore

/// Optional accessibility cues for actually heard sources. This object never
/// reads mixer levels and cannot change AI state. Its clock is simulation time.
final class NativeNoisePresentation {
    static let maximumLines=3
    private struct Caption {
        let key:String,label:String,position:SIMD3<Float>,time:Double,expires:Double,priority:Int
        let warning:SmokeWarning?
    }
    private var captions:[Caption]=[]
    private var recentIDs:[Int]=[]
    private var lastTime:Double=0
    private(set) var lines:[String]=[]

    func clear() { captions.removeAll(keepingCapacity:true);recentIDs.removeAll(keepingCapacity:true);lines=[];lastTime=0 }

    func consume(events:[GameEvent],simulation:CombatSimulation) {
        synchronizeClock(simulation.elapsed)
        for event in events {
            guard let sound=event.hearing,!recentIDs.contains(sound.id) else { continue }
            recentIDs.append(sound.id)
            if recentIDs.count>64 { recentIDs.removeFirst(recentIDs.count-64) }
            // Own footsteps and weapon handling would continually obscure the
            // external cues. A thrown decoy and nearby blast remain meaningful.
            if sound.source == .player && (sound.kind == .footstep || sound.kind == .landing || sound.kind == .gunshot) { continue }
            let warningCue = sound.kind == .gust ? NativeSmokeWarningCue.make(event:event,simulation:simulation) : nil
            if sound.kind == .gust {
                guard warningCue != nil else { continue }
            } else {
                guard simulation.acousticSample(for:sound,listener:simulation.eyePosition).audible else { continue }
            }
            let label:String,priority:Int,lifetime:Double
            switch sound.kind {
            case .gunshot:label="SCHÜSSE";priority=4;lifetime=2.4
            case .explosion:label="EXPLOSION";priority=5;lifetime=2.8
            case .decoy:label="KÖDER";priority=3;lifetime=1.6
            case .landing:label=sound.surface == .water ? "PLATSCHEN":"AUFPRALL";priority=2;lifetime=1.6
            case .footstep:label=sound.surface == .water ? "WASSERSCHRITTE":"SCHRITTE";priority=2;lifetime=1.4
            case .shout:label="KONTAKTRUF";priority=4;lifetime=2.2
            case .breakage:label=sound.surface == .glass ? "GLASBRUCH":"DURCHBRUCH";priority=4;lifetime=2.6
            case .gust:
                guard let warningCue else { continue }
                label=warningCue.label;priority=3;lifetime=warningCue.expiresAt-sound.time
            case .radio:
                label=event.kind == .contactReportInterrupted ? "FUNK UNTERBROCHEN":event.kind == .contactReportTransmitted ? "FUNK ÜBERMITTELT":"FUNK MELDET"
                priority=4;lifetime=2.2
            }
            let source=sound.sourceID.map(String.init) ?? String(sound.id)
            insert(Caption(key:"\(sound.kind.rawValue)-\(sound.source.rawValue)-\(source)",label:label,
                position:sound.position,time:sound.time,expires:sound.time+lifetime,priority:priority,
                warning:sound.kind == .gust ? event.warning:nil))
        }
        update(simulation:simulation)
    }

    func update(simulation:CombatSimulation) {
        synchronizeClock(simulation.elapsed)
        captions.removeAll { caption in
            if caption.expires<=simulation.elapsed || caption.key.hasPrefix("machine-") { return true }
            // A forecast caption promises a future emission. Cancel it when
            // its authored source loses that warning; ordinary heard events
            // remain historical snapshots for their existing short lifetime.
            guard let warning=caption.warning,
                  simulation.map.environment.smokeEmitters.contains(where:{ $0.id==warning.emitterID }) else { return false }
            return !simulation.smokeWarnings.contains {
                $0.emitterID==warning.emitterID && $0.cycle==warning.cycle && $0.startsAt==warning.startsAt
            }
        }
        for emitter in simulation.noiseEmitters {
            // A local, audible machine is useful context for a player without
            // sound. A remote or switched-off source produces no global notice.
            guard simulation.noiseEmitterGain(emitter,listener:simulation.eyePosition)>=0.12 else { continue }
            insert(Caption(key:"machine-\(emitter.id)",label:"MASCHINE",position:emitter.position,
                time:simulation.elapsed,expires:simulation.elapsed+0.1,priority:1,warning:nil))
        }
        lines=captions.map { "\($0.label) · \(Self.direction(source:$0.position,listener:simulation.eyePosition,yaw:simulation.player.yaw))" }
    }

    private func synchronizeClock(_ time:Double) {
        if time<lastTime { clear() }
        lastTime=time
    }
    private func insert(_ caption:Caption) {
        captions.removeAll { $0.key==caption.key }
        captions.append(caption)
        captions.sort {
            if $0.priority != $1.priority { return $0.priority>$1.priority }
            if $0.time != $1.time { return $0.time>$1.time }
            return $0.key<$1.key
        }
        if captions.count>Self.maximumLines { captions.removeLast(captions.count-Self.maximumLines) }
    }

    static func direction(source:SIMD3<Float>,listener:SIMD3<Float>,yaw:Float)->String {
        let delta=source-listener, horizontal=simd_length(SIMD2(delta.x,delta.z))
        guard horizontal.isFinite,delta.y.isFinite,yaw.isFinite else { return "UMGEBUNG" }
        if abs(delta.y)>max(3,horizontal*1.5) { return delta.y>0 ? "OBEN":"UNTEN" }
        if horizontal<0.5 { return "NAH" }
        let forward=SIMD3<Float>(-sin(yaw),0,-cos(yaw)),right=SIMD3<Float>(cos(yaw),0,-sin(yaw))
        let angle=atan2(simd_dot(delta,right),simd_dot(delta,forward))
        let sector=(Int((angle/(Float.pi/4)).rounded())+8)%8
        return ["VORN","VORN RECHTS","RECHTS","HINTEN RECHTS","HINTEN","HINTEN LINKS","LINKS","VORN LINKS"][sector]
    }
}
