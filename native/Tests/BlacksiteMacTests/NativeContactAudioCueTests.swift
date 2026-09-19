import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeContactAudioCueTests {
    private func game()->CombatSimulation { CombatSimulation(world:[],startingPlayer:PlayerState(position:.zero),startingWave:3) }
    private func event(_ eventKind:GameEvent.Kind,hearingKind:HearingKind = .radio,source:SIMD3<Float> = SIMD3(4,1.6,0),range:Float = 25)->GameEvent {
        let report=ContactReport(id:10,enemyID:20,contactPosition:SIMD3(-20,0,0),contactTime:0,
            transmittedAt:1.2,expiresAt:10,channel:.radio)
        return GameEvent(kind:eventKind,position:source,hearing:HearingStimulus(id:41,kind:hearingKind,
            position:source,time:0,strength:0.9,range:range,source:.enemy,sourceID:20),contactReport:report)
    }
    @Test func actualAudibleSourceDeterminesPanInsteadOfTheFrozenContact() throws {
        let simulation=game()
        let cue=try #require(NativeContactAudioCue.make(event:event(.contactReportStarted),simulation:simulation))
        #expect(cue.kind == .radioBegin && cue.spatial.pan>0.8 && cue.spatial.gain>0.1)
        let left=try #require(NativeContactAudioCue.make(event:event(.contactReportTransmitted,source:SIMD3(-4,1.6,0)),simulation:simulation))
        #expect(left.kind == .radioSent && left.spatial.pan < -0.8)
        let shout=try #require(NativeContactAudioCue.make(event:event(.contactReportTransmitted,hearingKind:.shout),simulation:simulation))
        #expect(shout.kind == .call)
        let interrupted=try #require(NativeContactAudioCue.make(event:event(.contactReportInterrupted),simulation:simulation))
        #expect(interrupted.kind == .radioInterrupted)
    }
    @Test func confirmationOrRemoteStatusCannotMakeAnUnheardGlobalTone() {
        let simulation=game()
        #expect(NativeContactAudioCue.make(event:GameEvent(kind:.enemyAlert),simulation:simulation)==nil)
        #expect(NativeContactAudioCue.make(event:event(.alarmEscalated),simulation:simulation)==nil)
        #expect(NativeContactAudioCue.make(event:event(.contactReportInterrupted,hearingKind:.shout),simulation:simulation)==nil)
        #expect(NativeContactAudioCue.make(event:event(.contactReportStarted,range:1),simulation:simulation)==nil)
        #expect(NativeContactAudioCue.make(event:GameEvent(kind:.contactReportTransmitted),simulation:simulation)==nil)
    }
}
