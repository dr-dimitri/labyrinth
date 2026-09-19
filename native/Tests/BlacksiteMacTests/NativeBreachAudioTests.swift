import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeBreachAudioTests {
    private func event(id: Int = 41, surface: SurfaceSound = .glass,
                       position: SIMD3<Float> = SIMD3(4,1.5,0), time: Double = 0) -> GameEvent {
        GameEvent(kind:.breachOpened,position:SIMD3(-15,1,0),hearing:HearingStimulus(id:id,
            kind:.breakage,position:position,surface:surface,time:time,strength:1,range:28,source:.world,sourceID:9))
    }
    private func game() -> CombatSimulation {
        CombatSimulation(world:[],startingPlayer:PlayerState(position:.zero),startingWave:3)
    }
    @Test func audibleFractureSelectsItsMaterialAndActualSourceWithoutGlobalFallback() throws {
        let simulation=game()
        let glass=try #require(NativeBreakageAudioCue.make(event:event(),simulation:simulation))
        #expect(glass.bufferName == "break-glass" && glass.spatial.pan > 0.8 && glass.spatial.gain > 0)
        let panel=try #require(NativeBreakageAudioCue.make(event:event(surface:.metal,position:SIMD3(-4,1.5,0)),simulation:simulation))
        #expect(panel.bufferName == "break-panel" && panel.spatial.pan < -0.8)
        #expect(NativeBreakageAudioCue.make(event:event(position:SIMD3(100,1.5,0)),simulation:simulation) == nil)
        #expect(NativeBreakageAudioCue.make(event:GameEvent(kind:.breachOpened),simulation:simulation) == nil)
    }
    @Test func breakageCaptionIsLocalDeduplicatedAndExpiresWithSimulationTime() {
        let simulation=game(),presentation=NativeNoisePresentation()
        let sound=event()
        presentation.consume(events:[sound,sound],simulation:simulation)
        #expect(presentation.lines == ["GLASBRUCH · RECHTS"])
        presentation.consume(events:[event(id:42,position:SIMD3(100,1.5,0))],simulation:simulation)
        #expect(presentation.lines == ["GLASBRUCH · RECHTS"])
        for _ in 0..<60 { presentation.update(simulation:simulation) }
        #expect(presentation.lines == ["GLASBRUCH · RECHTS"])
        for _ in 0..<324 { simulation.step(deltaTime:1.0/120,input:GameInput()) }
        presentation.update(simulation:simulation)
        #expect(presentation.lines.isEmpty)
        presentation.consume(events:[event(id:43,surface:.metal,time:simulation.elapsed)],simulation:simulation)
        #expect(presentation.lines == ["DURCHBRUCH · RECHTS"])
        presentation.clear()
        #expect(presentation.lines.isEmpty)
    }
}
