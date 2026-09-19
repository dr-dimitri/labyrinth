import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeSmokeWarningCueTests {
    private func game(world: [Obstacle] = []) -> CombatSimulation {
        CombatSimulation(world: world, startingPlayer: PlayerState(position: .zero), startingWave: 3)
    }

    private func event(id: Int = 41, position: SIMD3<Float> = SIMD3(4,1.5,0),
                       time: Double = 0, startsAt: Double = 3, strength: Float = 1) -> GameEvent {
        GameEvent(kind: .smokeWarning, position: SIMD3(-15,1,0),
            hearing: HearingStimulus(id: id, kind: .gust, position: position, time: time,
                strength: strength, range: 28, source: .world, sourceID: 2760),
            warning: SmokeWarning(emitterID: 2760, kind: .spray, position: position,
                startsAt: startsAt, cycle: 0, beginsAt: time))
    }

    @Test func coastalWarningUsesActualAcousticsAndRejectsMissingOrExpiredSnapshots() throws {
        let simulation = game()
        let cue = try #require(NativeSmokeWarningCue.make(event: event(), simulation: simulation))
        #expect(cue.label == "GISCHT NAHT" && cue.expiresAt == 3)
        #expect(cue.spatial.pan > 0.8 && cue.spatial.gain > 0)
        let expected = simulation.acousticSample(for: try #require(event().hearing), listener: simulation.eyePosition)
        #expect(cue.spatial.gain == expected.gain)
        #expect(NativeSmokeWarningCue.make(event: event(position: SIMD3(100,1.5,0)), simulation: simulation) == nil)
        #expect(NativeSmokeWarningCue.make(event: event(startsAt: 0), simulation: simulation) == nil)
        #expect(NativeSmokeWarningCue.make(event: event(time: 1), simulation: simulation) == nil)
        #expect(NativeSmokeWarningCue.make(event: GameEvent(kind: .smokeWarning), simulation: simulation) == nil)

        let wall = Obstacle(id: 9, kind: .bunker, position: SIMD3(2,0,0), size: SIMD3(0.4,3,5))
        let occluded = game(world: [wall])
        let weak = event(strength: 0.24)
        #expect(NativeSmokeWarningCue.make(event: weak, simulation: simulation) != nil)
        #expect(NativeSmokeWarningCue.make(event: weak, simulation: occluded) == nil)
    }

    @Test func hearingTextSharesWarningDeadlineAndPauseResetSemantics() {
        let simulation = game(), presentation = NativeNoisePresentation()
        let warning = event()
        presentation.consume(events: [warning, warning], simulation: simulation)
        #expect(presentation.lines == ["GISCHT NAHT · RECHTS"])
        for _ in 0..<120 { presentation.update(simulation: simulation) }
        #expect(presentation.lines == ["GISCHT NAHT · RECHTS"])
        for _ in 0..<336 { simulation.step(deltaTime: 1.0/120, input: GameInput()) }
        presentation.update(simulation: simulation)
        #expect(presentation.lines == ["GISCHT NAHT · RECHTS"])
        for _ in 0..<36 { simulation.step(deltaTime: 1.0/120, input: GameInput()) }
        presentation.update(simulation: simulation)
        #expect(presentation.lines.isEmpty)
        // A stale warning is not replayed when passed again after its window.
        presentation.consume(events: [warning, event(id: 42)], simulation: simulation)
        #expect(presentation.lines.isEmpty)
        presentation.clear()
        presentation.consume(events: [warning], simulation: game())
        #expect(presentation.lines == ["GISCHT NAHT · RECHTS"])
    }

    @Test func aDistantGustNeverCreatesAHearingHintOrReplacesNearbyInformation() {
        let simulation = game(), presentation = NativeNoisePresentation()
        presentation.consume(events: [event(position: SIMD3(100,1.5,0))], simulation: simulation)
        #expect(presentation.lines.isEmpty)
        presentation.consume(events: [event(id: 42)], simulation: simulation)
        presentation.consume(events: [event(id: 43, position: SIMD3(-100,1.5,0))], simulation: simulation)
        #expect(presentation.lines == ["GISCHT NAHT · RECHTS"])
        presentation.clear()
        #expect(presentation.lines.isEmpty)
    }
}
