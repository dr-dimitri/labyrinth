import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeNoisePresentationTests {
    private func simulation()->CombatSimulation {
        CombatSimulation(world:[],startingPlayer:PlayerState(position:.zero),startingEnemies:[],startingWave:3)
    }
    private func event(_ id:Int,kind:HearingKind = .gunshot,source:NoiseSource = .enemy,
                       position:SIMD3<Float> = SIMD3(5,1,0),time:Double = 0)->GameEvent {
        GameEvent(kind:.enemyShot,position:position,hearing:HearingStimulus(id:id,kind:kind,position:position,
            time:time,strength:1,range:30,source:source,sourceID:id))
    }

    @Test func directionalCuesFollowCameraAxesAndVerticalSources() {
        for yaw:Float in [0,.pi/2,.pi,-.pi/2] {
            let forward=SIMD3<Float>(-sin(yaw),0,-cos(yaw)),right=SIMD3<Float>(cos(yaw),0,-sin(yaw))
            #expect(NativeNoisePresentation.direction(source:forward*5,listener:.zero,yaw:yaw) == "VORN")
            #expect(NativeNoisePresentation.direction(source:right*5,listener:.zero,yaw:yaw) == "RECHTS")
            #expect(NativeNoisePresentation.direction(source:-right*5,listener:.zero,yaw:yaw) == "LINKS")
            #expect(NativeNoisePresentation.direction(source:SIMD3(0,5,0),listener:.zero,yaw:yaw) == "OBEN")
        }
    }

    @Test func unheardAndOwnActionsDoNotCreateEnemyHints() {
        let game=simulation(),presentation=NativeNoisePresentation()
        presentation.consume(events:[event(1,source:.player),event(2,kind:.footstep,source:.player),
            event(3,position:SIMD3(100,1,0))],simulation:game)
        #expect(presentation.lines.isEmpty)
        presentation.consume(events:[event(4)],simulation:game)
        #expect(presentation.lines == ["SCHÜSSE · RECHTS"])
    }

    @Test func cuesAreBoundedDeduplicatedAndExpireOnlyWithSimulationTime() {
        let game=simulation(),presentation=NativeNoisePresentation()
        presentation.consume(events:(1...20).map { event($0) },simulation:game)
        #expect(presentation.lines.count == NativeNoisePresentation.maximumLines)
        let before=presentation.lines
        for _ in 0..<120 { presentation.update(simulation:game) }
        #expect(presentation.lines == before)
        presentation.consume(events:[event(20),event(20)],simulation:game)
        #expect(presentation.lines == before)
        for _ in 0..<32 { game.step(deltaTime:0.1,input:GameInput()) }
        presentation.update(simulation:game)
        #expect(presentation.lines.isEmpty)
        presentation.consume(events:[event(100,time:game.elapsed)],simulation:game)
        #expect(!presentation.lines.isEmpty)
        presentation.clear()
        #expect(presentation.lines.isEmpty)
    }
}
