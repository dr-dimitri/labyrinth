import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct HearingTests {
    private func map(regions: [MapSurfaceRegion] = [], emitters: [NoiseEmitterDefinition] = [],
                     world: [Obstacle] = [], roads: [MapSurfaceRegion] = []) throws -> MapDefinition {
        var environment = MapEnvironmentDefinition(); environment.groundRegions = regions; environment.noiseEmitters = emitters
        return try MapDefinition(id: "sound-test", displayName: "Hörprüfung", minimum: SIMD3(-32,0,-32), maximum: SIMD3(32,0,32),
            terrain: .flat, obstacles: world, playerStart: PlayerState(position: SIMD3(0,0,12)),
            reinforcementEntries: [SIMD3(0,0,-29)], waveStaging: [SIMD3(0,0,-20)], extraction: SIMD3(0,0,-29),
            dataSite: SIMD3(-20,0,20), radioSite: SIMD3(20,0,20), roads: roads, environment: environment)
    }
    private func game(regions: [MapSurfaceRegion] = [], emitters: [NoiseEmitterDefinition] = [], world: [Obstacle] = [],
                      player: PlayerState? = nil, enemies: [EnemyState] = []) throws -> CombatSimulation {
        CombatSimulation(seed: 41, world: world, startingPlayer: player, startingEnemies: enemies,
                         startingWave: 3, map: try map(regions: regions, emitters: emitters, world: world),loadout: .init(operatorClass: .recon))
    }
    private func region(_ surface: SurfaceSound, low: Float = -30, high: Float = 30) -> MapSurfaceRegion {
        MapSurfaceRegion(minimum: SIMD2(-30,low), maximum: SIMD2(30,high), material: .soil, soundSurface: surface)
    }
    private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput()) {
        for _ in 0..<ticks { game.step(deltaTime: 1.0 / 120, input: input) }
    }
    private func stimulus(_ kind: HearingKind = .footstep, position: SIMD3<Float> = SIMD3(12,0.1,0),
                          strength: Float = 0.8, range: Float = 18) -> HearingStimulus {
        HearingStimulus(id: 1, kind: kind, position: position, surface: kind == .footstep ? .metal : nil,
                        time: 0, strength: strength, range: range, source: .player)
    }

    @Test func GroundDistanceProducesTheSameMaterialSequenceAtThirtySixtyAndOneTwentyHertz() throws {
        let regions = [region(.water, low: 1, high: 4), region(.gravel, low: 5, high: 8), region(.metal, low: 9, high: 12)]
        var sequences: [[SurfaceSound]] = []
        for rate in [30,60,120] {
            let simulation = try game(regions: regions)
            var walk = GameInput(); walk.moveForward = 1
            for _ in 0..<(rate * 2) { simulation.step(deltaTime: 1 / Double(rate), input: walk) }
            let steps = simulation.drainEvents().filter { $0.kind == .footstep }.compactMap(\.hearing)
            #expect(steps.count == 5 && steps.allSatisfy { $0.source == .player && $0.time > 0 })
            #expect(steps.allSatisfy { $0.position.y > 0 && $0.position.z < 12 })
            sequences.append(steps.compactMap(\.surface))
        }
        #expect(sequences[0] == sequences[1] && sequences[1] == sequences[2])
        #expect(sequences[0].contains(.metal) && sequences[0].contains(.gravel) && sequences[0].contains(.water))
    }

    @Test func WallPressureStillnessPauseAndFlightDoNotGenerateStepSeries() throws {
        let wall = Obstacle(id: 1, kind: .bunker, position: SIMD3(0,0,8), size: SIMD3(12,4,0.5))
        let blocked = try game(world: [wall])
        var walk = GameInput(); walk.moveForward = 1
        advance(blocked, ticks: 240, input: walk)
        #expect(blocked.drainEvents().filter { $0.kind == .footstep }.count == 2)
        advance(blocked, ticks: 240, input: walk)
        #expect(!blocked.drainEvents().contains { $0.kind == .footstep })
        for _ in 0..<100 { blocked.step(deltaTime: 0, input: walk) }
        #expect(blocked.drainEvents().isEmpty)
        let air = try game()
        #expect(air.jump())
        advance(air, ticks: 60, input: walk)
        #expect(!air.drainEvents().contains { $0.kind == .footstep })
        let still = try game()
        advance(still, ticks: 480)
        #expect(!still.drainEvents().contains { $0.kind == .footstep })
    }

    @Test func RealSurfacePaceAndPostureShareOneTypedStepForHearingAndAudio() throws {
        let asphalt = MapSurfaceRegion(minimum: SIMD2(-1,-30), maximum: SIMD2(1,30), material: .asphalt)
        let overlapping = CombatSimulation(map: try map(regions: [region(.water)], roads: [asphalt]))
        let roadSample = overlapping.environmentSample(at: SIMD3(0,0,12))
        #expect(roadSample.surfaceMaterial == .asphalt && roadSample.soundSurface == .hard)
        #expect(overlapping.environmentSample(at: SIMD3(2,0,12)).soundSurface == .water)
        var ranges: [SurfaceSound: Float] = [:]
        for surface in SurfaceSound.allCases {
            let simulation = try game(regions: [region(surface)])
            var walk = GameInput(); walk.moveForward = 1
            advance(simulation, ticks: 50, input: walk)
            let step = try #require(simulation.drainEvents().first { $0.kind == .footstep }?.hearing)
            #expect(step.surface == surface && step.strength > 0 && step.strength <= 1)
            #expect(simulation.hearingStimuli.contains { $0.id == step.id && $0.position == step.position && $0.time == step.time })
            ranges[surface] = step.range
        }
        #expect(try #require(ranges[.metal]) > #require(ranges[.earth]))
        #expect(try #require(ranges[.earth]) > #require(ranges[.vegetation]))
        let walking = try game(), running = try game(), crawling = try game()
        crawling.toggleProne()
        var walk = GameInput(); walk.moveForward = 1
        var sprint = walk; sprint.sprint = true
        advance(walking, ticks: 120, input: walk); advance(running, ticks: 120, input: sprint); advance(crawling, ticks: 120, input: walk)
        let w = walking.drainEvents().compactMap(\.hearing).filter { $0.kind == .footstep }
        let r = running.drainEvents().compactMap(\.hearing).filter { $0.kind == .footstep }
        let c = crawling.drainEvents().compactMap(\.hearing).filter { $0.kind == .footstep }
        #expect(r.count > w.count && w.count > c.count)
        #expect(try #require(r.first).strength > #require(w.first).strength)
        #expect(try #require(w.first).strength > #require(c.first).strength)

        // Keep the player beyond the 48m sight range: a close guard can stop to
        // aim before its first full stride, which is correctly silent.
        var guardState = EnemyState(id: 8, position: SIMD3(24,0,24)); guardState.yaw = .pi
        let enemy = try game(player: PlayerState(position: SIMD3(-24,0,-24)), enemies: [guardState])
        advance(enemy, ticks: 600)
        let sounds = enemy.drainEvents().compactMap(\.hearing).filter { $0.kind == .footstep && $0.source == .enemy }
        #expect(!sounds.isEmpty && sounds.allSatisfy { $0.sourceID == 8 })
        #expect(enemy.enemies[0].walkCycle > 0)
        #expect(simd_distance(enemy.enemies[0].position, guardState.position) >= 1.65)
    }

    @Test func DistanceSolidOcclusionAndListenerLocalMaskingHaveBoundedEffects() throws {
        let plain = try game(), ear = SIMD3<Float>(0,1.6,0), step = stimulus()
        let clear = plain.acousticSample(for: step, listener: ear)
        #expect(clear.audible && clear.transmission == 1 && clear.masking == 0)
        #expect(!plain.acousticSample(for: step, listener: SIMD3(-20,1.6,0)).audible)
        let near = try game(emitters: [NoiseEmitterDefinition(id: 90, position: ear, strength: 1, range: 18)])
        let masked = near.acousticSample(for: step, listener: ear)
        #expect(masked.gain == clear.gain && masked.masking == 0.65 && !masked.audible)
        let distant = try game(emitters: [NoiseEmitterDefinition(id: 90, position: step.position, strength: 1, range: 4)])
        #expect(distant.acousticSample(for: step, listener: ear).masking == 0)
        #expect(distant.acousticSample(for: step, listener: ear).audible)
        let wall = Obstacle(id: 2, kind: .crate, position: SIMD3(6,0,0), size: SIMD3(1,4,5))
        let blocked = try game(world: [wall])
        #expect(blocked.acousticSample(for: step, listener: ear).gain < clear.gain)
        #expect(!blocked.acousticSample(for: step, listener: ear).audible)
        blocked.damageCover(index: 0, amount: 1000)
        #expect(blocked.acousticSample(for: step, listener: ear).transmission == 1)
        for kind in [HearingKind.gunshot,.explosion] {
            let loud = stimulus(kind, position: SIMD3(3,1,0), strength: 1, range: 40)
            #expect(near.acousticSample(for: loud, listener: ear).audible)
        }
        let muffledMachine = try game(emitters: [NoiseEmitterDefinition(id: 90, position: SIMD3(12,1,0), strength: 1, range: 20)], world: [wall])
        #expect(muffledMachine.noiseEmitterGain(muffledMachine.noiseEmitters[0], listener: ear) < 0.2)
    }

    @Test func GroundAndRoofSourcesDoNotMuffleThemselvesAndObservationsRetainWorldHeight() throws {
        let roof = Obstacle(id: 4, kind: .container, position: SIMD3(0,0,12), size: SIMD3(6,3,10))
        let simulation = try game(world: [roof], player: PlayerState(position: SIMD3(0,3,12)))
        var walk = GameInput(); walk.moveForward = 1
        advance(simulation, ticks: 50, input: walk)
        let step = try #require(simulation.drainEvents().first { $0.kind == .footstep }?.hearing)
        #expect(step.surface == .metal && abs(step.position.y - 3.1) < 0.0001)
        #expect(simulation.acousticSample(for: step, listener: SIMD3(1,4.6,step.position.z)).transmission == 1)
        let ground = try game()
        #expect(ground.acousticSample(for: stimulus(position: SIMD3(0,0.1,12)), listener: SIMD3(1,1.6,12)).transmission == 1)

        for (floor, world, material): (Float, [Obstacle], SurfaceSound) in [(0, [], .earth), (3, [roof], .metal)] {
            var fall = PlayerState(position: SIMD3(0,floor + 0.02,12)); fall.grounded = false; fall.verticalVelocity = -20
            let landing = try game(world: world, player: fall)
            advance(landing, ticks: 1)
            let event = try #require(landing.drainEvents().first { $0.kind == .land })
            let sound = try #require(event.hearing)
            #expect(event.position.y == floor && sound.surface == material)
            #expect(abs(sound.position.y - floor - 0.1) < 0.0001)
            #expect(landing.acousticSample(for: sound, listener: SIMD3(1,floor + 1.6,12)).transmission == 1)
        }

        var guardState = EnemyState(id: 5, position: SIMD3(8,0,12)); guardState.yaw = .pi / 2
        let source = try game(world: [roof], player: PlayerState(position: SIMD3(0,3,12)), enemies: [guardState])
        #expect(source.fire())
        let observation = try #require(source.enemies[0].lastHeard)
        let shot = try #require(source.drainEvents().first { $0.kind == .shot }?.hearing)
        #expect(observation.kind == .gunshot && observation.position == shot.position && observation.time == shot.time)
        #expect(observation.position.y > 4)
    }

    @Test func MachineStateIsTheSingleSourceForMaskingEventsAndFreshStarts() throws {
        let simulation = try game(emitters: [NoiseEmitterDefinition(id: 90, position: SIMD3(0,1,0), strength: 1)])
        let ear = SIMD3<Float>(0,1.6,0), sound = stimulus()
        #expect(!simulation.acousticSample(for: sound, listener: ear).audible)
        #expect(simulation.setNoiseEmitterEnabled(id: 90, enabled: false))
        #expect(simulation.acousticSample(for: sound, listener: ear).audible)
        #expect(!simulation.setNoiseEmitterEnabled(id: 90, enabled: false))
        let changed = simulation.drainEvents().filter { $0.kind == .noiseEmitterChanged }
        #expect(changed.count == 1 && changed[0].noiseEmitter?.enabled == false)
        #expect(changed[0].noiseEmitter?.id == 90)
        let restart = try game(emitters: [NoiseEmitterDefinition(id: 90, position: SIMD3(0,1,0), strength: 1)])
        #expect(restart.noiseEmitters[0].enabled && restart.hearingStimuli.isEmpty)
        #expect(throws: MapValidationError.self) { try map(emitters: (0..<5).map { NoiseEmitterDefinition(id: 90 + $0, position: SIMD3(0,1,0)) }) }
        #expect(throws: MapValidationError.self) { try map(emitters: [NoiseEmitterDefinition(id: 90, position: .zero, ownerObstacleID: 99)]) }
        let actual = CombatSimulation()
        let machine = try #require(actual.noiseEmitters.first)
        let owner = try #require(actual.obstacles.first { $0.id == machine.ownerObstacleID })
        #expect(machine.id == 7001 && owner.id == 23 && machine.position.y > owner.position.y && machine.position.y < owner.maximum.y)
        #expect(actual.noiseEmitterGain(machine, listener: machine.position + SIMD3(0,1,0)) > 0)
    }

    @Test func DecoysUseActualFlightAndFiniteInventoryPulsesLifetimeAndPause() throws {
        let simulation = try game()
        #expect(simulation.noiseDecoyCount == 1 && simulation.throwNoiseDecoy())
        #expect(!simulation.throwNoiseDecoy())
        advance(simulation, ticks: 86)
        #expect(!simulation.throwNoiseDecoy() && simulation.noiseDecoyCount == 0)
        #expect(simulation.decoys.count == 1 && !simulation.throwNoiseDecoy())
        let ages = simulation.decoys.map(\.age), positions = simulation.decoys.map(\.position)
        for _ in 0..<120 { simulation.step(deltaTime: 0, input: GameInput()) }
        #expect(simulation.decoys.map(\.age) == ages && simulation.decoys.map(\.position) == positions)
        advance(simulation, ticks: 1600)
        #expect(simulation.decoys.isEmpty && simulation.noiseDecoyCount == 0)
        let events = simulation.drainEvents()
        let throwsMade = events.filter { $0.kind == .decoyThrown }
        let pulses = events.filter { $0.kind == .decoyPulse }
        #expect(throwsMade.count == 1 && pulses.count == 6)
        for thrown in throwsMade {
            let ownPulses = pulses.filter { $0.id == thrown.id }
            #expect(ownPulses.count == 6 && ownPulses.allSatisfy { $0.hearing?.sourceID == thrown.id && $0.hearing?.kind == .decoy })
            #expect(ownPulses.allSatisfy { $0.position.y >= 0.08 && simd_distance($0.position, thrown.position) > 1 })
        }
        let restarted = try game()
        #expect(restarted.noiseDecoyCount == 1 && restarted.decoys.isEmpty && restarted.hearingStimuli.isEmpty)
    }

    @Test func FreshConfirmedDamageCannotBeReplacedByAQuieterDecoyAfterLossOfSight() throws {
        var guardState = EnemyState(id: 1, position: SIMD3(0,0,-10)); guardState.yaw = .pi
        let player = PlayerState(position: SIMD3(0,0,-4))
        let control = try game(player: player, enemies: [guardState]), baited = try game(player: player, enemies: [guardState])
        for simulation in [control,baited] { simulation.damageEnemy(index: 0, amount: 1, from: SIMD3(-10,1,-10)) }
        #expect(!baited.enemies[0].seesPlayer && baited.throwNoiseDecoy())
        advance(control, ticks: 360); advance(baited, ticks: 360)
        #expect(baited.hearingStimuli.contains { $0.kind == .decoy })
        #expect(baited.enemies[0].lastHeard?.kind == .decoy)
        #expect(simd_distance(control.enemies[0].position, baited.enemies[0].position) < 0.0001)
        #expect(control.enemies[0].yaw == baited.enemies[0].yaw)
        #expect(baited.enemies[0].position.x < -3)
    }

    @Test func HearingHistoryIsBoundedAndBothThrowableTypesRespectTranslatedMapBounds() throws {
        let simulation = try game()
        for _ in 0..<100 { simulation.explode(at: SIMD3(25,1,-25)) }
        #expect(simulation.hearingStimuli.count == 64)
        #expect(simulation.hearingStimuli.first?.id == 37 && simulation.hearingStimuli.last?.id == 100)
        advance(simulation, ticks: 1080)
        #expect(simulation.hearingStimuli.isEmpty)
        let foreign = CombatSimulation(map: .testRange,loadout: .init(operatorClass: .recon))
        foreign.throwGrenade(); #expect(foreign.throwNoiseDecoy())
        advance(foreign, ticks: 120)
        #expect(foreign.grenades.count == 1 && foreign.decoys.count == 1)
        for point in foreign.grenades.map(\.position) + foreign.decoys.map(\.position) {
            #expect(point.x > 98 && point.x < 122 && point.z > 198 && point.z < 234)
            #expect(point.y >= foreign.terrain.height(x: point.x, z: point.z) + 0.08)
        }
    }
}
