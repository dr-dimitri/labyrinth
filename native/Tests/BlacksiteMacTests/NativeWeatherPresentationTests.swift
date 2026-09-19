import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeWeatherPresentationTests {
    private func event(_ id: Int, source: SIMD3<Float>, begins: Double = 0, starts: Double, kind: SmokeKind = .spray) -> GameEvent {
        GameEvent(kind: .smokeWarning, hearing: HearingStimulus(id: id, kind: .gust,
            position: source, time: begins, strength: 1, range: 25, source: .world, sourceID: id),
            warning: SmokeWarning(emitterID: id, kind: kind, position: source,
                startsAt: starts, cycle: 0, beginsAt: begins))
    }
    @Test func onlyHeardWarningsCountDownPauseExpireAndResetAtTheirRealTimes() throws {
        let simulation = CombatSimulation(world: [], startingPlayer: PlayerState(position: .zero), startingWave: 3)
        let presentation = NativeWeatherPresentation()
        presentation.consume([event(1, source: SIMD3(100,1,0), starts: 3)], simulation: simulation)
        #expect(presentation.line(simulation: simulation) == nil)
        let first = event(2, source: SIMD3(3,1,0), starts: 2)
        let second = event(3, source: SIMD3(-3,1,0), starts: 4, kind: .steam)
        presentation.consume([second, first, first], simulation: simulation)
        let paused = try #require(presentation.line(simulation: simulation))
        #expect(paused.contains("GISCHT NAHT") && paused.contains("RECHTS") && paused.contains("2.0 s"))
        for _ in 0..<60 { simulation.step(deltaTime: 0, input: GameInput()); presentation.consume([], simulation: simulation) }
        #expect(presentation.line(simulation: simulation) == paused)
        for _ in 0..<252 { simulation.step(deltaTime: 1.0/120, input: GameInput()) }
        presentation.consume([first], simulation: simulation)
        #expect(presentation.line(simulation: simulation)?.contains("DAMPF NAHT") == true)
        #expect(presentation.line(simulation: simulation)?.contains("LINKS") == true)
        for _ in 0..<240 { simulation.step(deltaTime: 1.0/120, input: GameInput()) }
        presentation.consume([first, second], simulation: simulation)
        #expect(presentation.line(simulation: simulation) == nil)
        let retry = CombatSimulation(world: [], startingPlayer: PlayerState(position: .zero), startingWave: 3)
        presentation.consume([first], simulation: retry)
        #expect(presentation.line(simulation: retry) == paused)
        presentation.clear(); #expect(presentation.line(simulation: retry) == nil)
    }
    @Test func realSeededWarningReachesHUDOnItsFirstFixedTick() throws {
        let map = MapDefinition.nebelwacht
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: PlayerState(position: SIMD3(0,0,13)), startingEnemies: [], startingWave: 3, map: map)
        let presentation = NativeWeatherPresentation()
        var heard = false
        for _ in 0..<1200 {
            game.step(deltaTime: 1.0/120, input: GameInput())
            let events = game.drainEvents()
            presentation.consume(events, simulation: game)
            if let event = events.first(where: { $0.kind == .smokeWarning }),
               NativeSmokeWarningCue.make(event: event, simulation: game) != nil {
                #expect(presentation.line(simulation: game)?.contains("GISCHT NAHT") == true)
                heard = true; break
            }
        }
        #expect(heard)
    }

    @Test func switchingOffARealSourceCancelsItsPreviouslyHeardCountdown() throws {
        var environment=MapEnvironmentDefinition()
        environment.devices=[WorldInteractableDefinition(id:1001,kind:.generator,ownerObstacleID:23,
            interactionPoints:[SIMD3(3,0,2)])]
        environment.smokeEmitters=[SmokeEmitterDefinition(id:9002,kind:.steam,position:SIMD3(0,0,2),
            startDelay:4,powerDeviceID:1001,warningLeadTime:3)]
        let map=try MapDefinition(id:"weather-power-test",displayName:"Warnungsprüfung",
            minimum:SIMD3(-20,0,-20),maximum:SIMD3(20,10,20),terrain:.flat,
            obstacles:[Obstacle(id:23,kind:.container,position:SIMD3(3,0,0),size:SIMD3(1.6,1.4,1.2))],
            playerStart:PlayerState(position:SIMD3(3,0,2)),reinforcementEntries:[SIMD3(15,0,15)],
            waveStaging:[SIMD3(14,0,14)],extraction:SIMD3(0,0,-15),dataSite:SIMD3(-12,0,0),radioSite:SIMD3(12,0,0),environment:environment)
        let game=CombatSimulation(world:map.obstacles,startingWave:3,map:map)
        let presentation=NativeWeatherPresentation()
        let hearingText=NativeNoisePresentation()
        for _ in 0..<132 {
            game.step(deltaTime:1.0/120,input:GameInput())
            let events=game.drainEvents()
            presentation.consume(events,simulation:game)
            hearingText.consume(events:events,simulation:game)
        }
        #expect(game.smokeWarnings.count==1 && presentation.line(simulation:game)?.contains("DAMPF NAHT")==true)
        #expect(hearingText.lines.contains { $0.contains("DAMPF NAHT") })
        // An ordinary recently heard event remains a historical cue even if
        // the powered source subsequently cancels its future emission.
        let contact=HearingStimulus(id:9900,kind:.shout,position:game.eyePosition+SIMD3(1,0,0),
            time:game.elapsed,strength:1,range:20,source:.world,sourceID:9900)
        hearingText.consume(events:[GameEvent(kind:.contactReportTransmitted,hearing:contact)],simulation:game)
        var input=GameInput();input.interact=true
        for _ in 0..<121 {
            game.step(deltaTime:1.0/120,input:input)
            let events=game.drainEvents()
            presentation.consume(events,simulation:game)
            hearingText.consume(events:events,simulation:game)
        }
        #expect(game.devices[0].enabled==false && game.smokeWarnings.isEmpty)
        #expect(game.elapsed<4 && presentation.line(simulation:game)==nil)
        #expect(hearingText.lines.allSatisfy { !$0.contains("DAMPF NAHT") })
        #expect(hearingText.lines.contains { $0.contains("KONTAKTRUF") })
        for _ in 0..<250 {
            game.step(deltaTime:1.0/120,input:GameInput())
            presentation.consume(game.drainEvents(),simulation:game)
        }
        #expect(game.smokeVolumes.isEmpty && presentation.line(simulation:game)==nil)
    }

}
