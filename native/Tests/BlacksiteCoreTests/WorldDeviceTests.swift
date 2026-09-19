import Foundation
import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct WorldDeviceTests {
    private var held: GameInput { var input = GameInput(); input.interact = true; return input }
    private func fixture(extra: [Obstacle] = [], generatorAt: SIMD3<Float> = SIMD3(12,0,8),
                         gateControl: SIMD3<Float> = SIMD3(6.9,0,0), missionAt: SIMD3<Float> = SIMD3(-20,0,20),
                         terrain: TerrainProfile = .flat) throws -> MapDefinition {
        let generator = Obstacle(id: 23, kind: .container, position: generatorAt, size: SIMD3(1.6,1.4,1.2))
        let gate = Obstacle(id: 24, kind: .container, position: .zero, size: SIMD3(12,2.8,0.45))
        var environment = MapEnvironmentDefinition()
        environment.sunDirection = simd_normalize(SIMD3(-1,2,-1))
        environment.noiseEmitters = [NoiseEmitterDefinition(id: 7001, position: generatorAt + SIMD3(0,0.8,0), ownerObstacleID: 23)]
        environment.devices = [
            WorldInteractableDefinition(id: 1001, kind: .generator, ownerObstacleID: 23,
                interactionPoints: [generatorAt + SIMD3(0,0,1.5)], noiseEmitterIDs: [7001], lightIDs: [8001]),
            WorldInteractableDefinition(id: 1002, kind: .serviceGate, ownerObstacleID: 24,
                interactionPoints: [gateControl], generatorID: 1001, openOffset: SIMD3(0,3.4,0))
        ]
        environment.spotlights = [WorldSpotlightDefinition(id: 8001, position: SIMD3(-10,6,8), direction: SIMD3(0,-1,0))]
        return try MapDefinition(id: "device-test", displayName: "Geräteprüfung", minimum: SIMD3(-30,0,-30), maximum: SIMD3(30,0,30),
            terrain: terrain, obstacles: [generator,gate] + extra, playerStart: PlayerState(position: generatorAt + SIMD3(0,0,1.5)),
            reinforcementEntries: [SIMD3(0,0,-28)], waveStaging: [SIMD3(0,0,-20)], extraction: SIMD3(0,0,-28),
            dataSite: missionAt, radioSite: SIMD3(-20,0,-20), environment: environment)
    }
    private func game(_ map: MapDefinition, player: SIMD3<Float>? = nil, enemies: [EnemyState] = [],
                      mission: MissionKind = .waves) -> CombatSimulation {
        CombatSimulation(difficulty: .easy, seed: 41, world: map.obstacles,
            startingPlayer: player.map { PlayerState(position: $0) }, startingEnemies: enemies,
            startingWave: 3, mission: mission, map: map)
    }
    @discardableResult private func advance(_ simulation: CombatSimulation, _ ticks: Int, input: GameInput = GameInput(),
                                           isolateCombat: Bool = false) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            simulation.step(deltaTime: 1.0/120, input: input)
            if isolateCombat {
                for index in simulation.enemies.indices where simulation.enemies[index].health > 0 {
                    simulation.damageEnemy(index: index, amount: 10_000)
                }
            }
            events += simulation.drainEvents()
        }
        return events
    }
    private func gate(_ simulation: CombatSimulation) -> WorldInteractableState { simulation.devices.first { $0.kind == .serviceGate }! }
    private func walk(_ simulation: CombatSimulation, _ point: SIMD2<Float>, isolateCombat: Bool = false) -> Bool {
        for _ in 0..<2400 {
            let delta = point - SIMD2(simulation.player.position.x,simulation.player.position.z)
            if simd_length(delta) < 0.08 { return true }
            var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
            advance(simulation, 1, input: input, isolateCombat: isolateCombat)
        }
        return false
    }

    @Test func generatorPressHasOneTypedTransitionAndRequiresReleaseBeforeReversing() throws {
        let simulation = game(try fixture())
        #expect(simulation.obstacles.allSatisfy { $0.damageStage == .intact })
        #expect(simulation.devices.count == 2 && simulation.spotlights.count == 1 && simulation.noiseEmitters[0].enabled)
        #expect(simulation.deviceInteractionAvailable && simulation.deviceContextAvailable)
        #expect(simulation.deviceInteractionStatus?.action == .disableGenerator)
        advance(simulation, 60, input: held)
        #expect(simulation.deviceInteractionStatus?.progress == 0.5)
        advance(simulation, 1)
        #expect(simulation.deviceInteractionStatus?.progress == 0)
        var events = advance(simulation, 120, input: held)
        #expect(!simulation.devices[0].enabled && !simulation.spotlights[0].enabled && !simulation.noiseEmitters[0].enabled)
        #expect(!gate(simulation).powered && simulation.deviceInteractionStatus?.interruption == .releaseRequired)
        #expect(simulation.deviceContextAvailable && !simulation.deviceInteractionAvailable)
        events += advance(simulation, 360, input: held)
        #expect(events.filter { $0.kind == .deviceActivated }.count == 1)
        #expect(events.first { $0.kind == .deviceActivated }?.device?.enabled == false)
        #expect(!simulation.devices[0].enabled)
        advance(simulation, 1)
        #expect(simulation.deviceInteractionStatus?.action == .enableGenerator)
        advance(simulation, 120, input: held)
        #expect(simulation.devices[0].enabled && simulation.spotlights[0].enabled && simulation.noiseEmitters[0].enabled)
    }

    @Test func gateUsesItsMovingColliderForHitsBodyClearanceAndNavigation() throws {
        let wallLeft = Obstacle(id: 40, kind: .bunker, position: SIMD3(-18,0,0), size: SIMD3(24,8,0.45))
        let wallRight = Obstacle(id: 41, kind: .bunker, position: SIMD3(18,0,0), size: SIMD3(24,8,0.45))
        // The panel is on the near side of the closed wall, outside the sweep.
        let simulation = game(try fixture(extra: [wallLeft,wallRight], gateControl: SIMD3(5,0,1.4)), player: SIMD3(5,0,1.4))
        #expect(!simulation.hasReachableRoute(from: SIMD3(0,0,4), to: SIMD3(0,0,-4)))
        #expect(simulation.traceShot(origin: SIMD3(0,1.5,4), direction: SIMD3(0,0,-1)).obstacleIndex == 1)
        advance(simulation, 120, input: held)
        #expect(gate(simulation).isMoving && simulation.deviceContextAvailable && !simulation.deviceInteractionAvailable)
        advance(simulation, 110)
        let mid = simulation.obstacles[1]
        #expect(mid.id == 24 && mid.position.y > 1.5 && mid.position.y < 1.7)
        #expect(simulation.blocked(.zero) && !simulation.blocked(.zero, height: 0.65))
        #expect(simulation.clearLine(SIMD3(0,0.5,4),SIMD3(0,0.5,-4)))
        #expect(!simulation.clearLine(SIMD3(0,2,4),SIMD3(0,2,-4)))
        #expect(!simulation.hasReachableRoute(from: SIMD3(0,0,4), to: SIMD3(0,0,-4)))
        advance(simulation, 132)
        #expect(gate(simulation).gateProgress == 1 && !gate(simulation).isMoving)
        #expect(abs(simulation.obstacles[1].position.y - 3.4) < 0.00001)
        #expect(simulation.hasReachableRoute(from: SIMD3(0,0,4), to: SIMD3(0,0,-4)))
        advance(simulation, 120, input: held)
        advance(simulation, 245)
        #expect(gate(simulation).gateProgress == 0)
        #expect(!simulation.hasReachableRoute(from: SIMD3(0,0,4), to: SIMD3(0,0,-4)))
    }

    @Test func closingStopsForStandingAndPronePlayersAndResumesWhenClear() throws {
        for prone in [false,true] {
            let simulation = game(try fixture(), player: SIMD3(6.9,0,0))
            advance(simulation, 120, input: held); advance(simulation, 245)
            if prone { simulation.toggleProne(); advance(simulation, 90) }
            advance(simulation, 120, input: held)
            var left = GameInput(); left.moveRight = -1
            // A prone player needs to start closer to the edge after opening.
            var events: [GameEvent] = []
            for _ in 0..<240 {
                events += advance(simulation, 1, input: left)
                if simulation.player.position.x < 5.8 { break }
            }
            events += advance(simulation, 480)
            #expect(gate(simulation).blockedByActor && gate(simulation).isMoving)
            #expect(events.filter { $0.kind == .gateBlocked }.count == 1)
            #expect(!simulation.blocked(simulation.player.position, height: simulation.player.height))
            #expect(simulation.obstacles[1].minimum.y >= simulation.player.position.y + simulation.player.height)
            var right = GameInput(); right.moveRight = 1
            advance(simulation, 240, input: right); advance(simulation, 480)
            #expect(!gate(simulation).blockedByActor && gate(simulation).gateProgress == 0)
        }
    }

    @Test func openingStopsForEnemyOnTheTopAndDestructionFailsOpenWithoutSolidDebris() throws {
        let map = try fixture()
        let enemy = EnemyState(id: 99, position: SIMD3(0,2.8,0))
        let simulation = game(map, player: SIMD3(6.9,0,0), enemies: [enemy])
        let events = advance(simulation, 120, input: held)
        #expect(gate(simulation).blockedByActor && gate(simulation).gateProgress == 0)
        #expect(events.contains { $0.kind == .gateBlocked })
        #expect(abs(simulation.enemies[0].position.y - 2.8) < 0.001)
        simulation.damageCover(index: 1, amount: 10_000)
        #expect(gate(simulation).destroyed && gate(simulation).gateProgress == 1 && !gate(simulation).isMoving)
        #expect(simulation.coverDebris.filter { $0.sourceObstacleID == 24 }.allSatisfy { $0.solidObstacleID == nil })
        #expect(simulation.clearLine(SIMD3(0,1,4),SIMD3(0,1,-4)))
        let score = simulation.score
        simulation.damageCover(index: 1, amount: 10_000)
        #expect(simulation.score == score && simulation.drainEvents().filter { $0.kind == .deviceDestroyed }.count == 1)
        advance(simulation, 60)
        #expect(simulation.enemies[0].position.y < 2.8)
    }

    @Test func generatorDestructionStopsMotorButManualResumeRemainsPossible() throws {
        let simulation = game(try fixture(), player: SIMD3(6.9,0,0))
        advance(simulation, 120, input: held); advance(simulation, 80)
        let before = gate(simulation).gateProgress
        simulation.damageCover(index: 0, amount: 10_000)
        #expect(gate(simulation).gateProgress == before && !gate(simulation).isMoving && !gate(simulation).powered)
        #expect(!simulation.noiseEmitters[0].enabled && !simulation.spotlights[0].enabled)
        #expect(simulation.deviceInteractionStatus?.manual == true && simulation.deviceInteractionStatus?.requiredProgress == 2)
        #expect(simulation.deviceInteractionStatus?.action == .openGate)
        advance(simulation, 239, input: held)
        #expect(!gate(simulation).isMoving && gate(simulation).gateProgress == before)
        advance(simulation, 1, input: held)
        #expect(gate(simulation).isMoving)
        advance(simulation, 120)
        #expect(abs(gate(simulation).gateProgress - before - 0.25) < 0.003)
        advance(simulation, 360)
        #expect(gate(simulation).gateProgress == 1 && !gate(simulation).isMoving)
        #expect(simulation.drainEvents().allSatisfy { $0.kind != .deviceDestroyed })
    }

    @Test func objectivePriorityPauseFrameRatesAndResetKeepDeviceStatePredictable() throws {
        let priorityMap = try fixture(missionAt: SIMD3(12,0,9.5))
        let priority = game(priorityMap, mission: .recoverData)
        #expect(priority.missionInteractionAvailable && priority.deviceInteractionStatus == nil && !priority.deviceContextAvailable)
        let events = advance(priority, 180, input: held, isolateCombat: true)
        #expect(priority.missionStatus.phase == .extract && priority.devices[0].enabled)
        #expect(!events.contains { $0.kind == .deviceActivated })
        #expect(priority.deviceInteractionStatus?.interruption == .releaseRequired)
        for rate in [30,60,120] {
            let map = try fixture(), simulation = game(map, player: SIMD3(6.9,0,0))
            for _ in 0..<rate { simulation.step(deltaTime: 1/Double(rate), input: held) }
            for _ in 0..<rate { simulation.step(deltaTime: 1/Double(rate), input: GameInput()) }
            let progress = gate(simulation).gateProgress, clock = simulation.elapsed, box = simulation.obstacles[1].position
            #expect(abs(progress - 0.5041667) < 0.0001)
            for dt in [Double(0),-1,.nan,.infinity] { simulation.step(deltaTime: dt, input: held) }
            #expect(gate(simulation).gateProgress == progress && simulation.elapsed == clock && simulation.obstacles[1].position == box)
            let reset = game(map)
            #expect(reset.devices[0].enabled && gate(reset).gateProgress == 0 && reset.spotlights[0].enabled)
        }
        let legacy = CombatSimulation(world: GameMap.obstacles, startingWave: 3)
        #expect(legacy.devices.isEmpty && legacy.spotlights.isEmpty)
    }

    @Test func lightUsesCommonConeAndRealOcclusionWithoutChangingSunOrKnownContacts() throws {
        let map = try fixture(), simulation = game(map)
        let centre = SIMD3<Float>(-10,0,8)
        let on = simulation.lightSample(at: centre)
        #expect(on.directSun == 1 && abs(on.artificial - 0.390625) < 0.0001)
        #expect(simulation.lightSample(at: SIMD3(-1,0,8)).artificial == 0)
        advance(simulation, 120, input: held)
        let off = simulation.lightSample(at: centre)
        #expect(off.artificial == 0 && off.directSun == on.directSun)
        let roof = Obstacle(id: 44, kind: .bunker, position: SIMD3(-10,0,8), size: SIMD3(4,3,4))
        let occluded = game(try fixture(extra: [roof]))
        #expect(occluded.lightSample(at: centre + SIMD3(0,1,0)).artificial == 0)
        #expect(occluded.lightSample(at: centre + SIMD3(0,3.01,0)).artificial > 0)
        // A once-confirmed target remains confirmed when only artificial light changes.
        var enemy = EnemyState(id: 8, position: SIMD3(12,0,18)); enemy.yaw = .pi
        let known = game(map, enemies: [enemy])
        advance(known, 100)
        #expect(known.enemies[0].seesPlayer && known.enemies[0].detectionProgress == 1)
        advance(known, 120, input: held)
        #expect(known.enemies[0].seesPlayer && known.enemies[0].detectionProgress == 1)
    }

    @Test func realBlacksiteDataMissionTraversesTheOpenedServiceGateAndExtracts() {
        // Combat is deliberately isolated; objectives, input, terrain, device
        // clocks, actor movement and the gate collider all run normally.
        let simulation = CombatSimulation(difficulty: .easy, seed: 41, world: MapDefinition.blacksite.obstacles,
            startingPlayer: PlayerState(position: GameMap.dataSite), mission: .recoverData, map: .blacksite)
        advance(simulation, 96, input: held, isolateCombat: true)
        #expect(simulation.extractionReady)
        for point in [SIMD2<Float>(-32,22),SIMD2(-30,14),SIMD2(-25,8),SIMD2(-8,8),
                      SIMD2(0,8),SIMD2(0,-12),SIMD2(6.9,-12),SIMD2(6.9,-13.8)] {
            #expect(walk(simulation, point, isolateCombat: true), "route point \(point), player \(simulation.player.position)")
        }
        #expect(simulation.deviceInteractionStatus?.action == .openGate)
        let commands = advance(simulation, 120, input: held, isolateCombat: true)
        #expect(commands.contains { $0.kind == .deviceActivated && $0.device?.kind == .serviceGate })
        advance(simulation, 245, isolateCombat: true)
        #expect(gate(simulation).gateProgress == 1)
        for point in [SIMD2<Float>(0,-13.8),SIMD2(0,-18),SIMD2(0,-35)] {
            #expect(walk(simulation, point, isolateCombat: true), "gate return point \(point)")
        }
        let completion = advance(simulation, 360, isolateCombat: true)
        #expect(simulation.state == .won && completion.filter { $0.kind == .win }.count == 1)
    }
    @Test func generatorHasOneSharedLevelFoundationAndInvalidLightsFailBeforeUpload() throws {
        let simulation = CombatSimulation(map: .blacksite)
        let generator = try #require(simulation.obstacles.first { $0.id == 23 })
        #expect(generator.damageStage == .intact)
        for row in 0...12 { for column in 0...16 {
            let point = SIMD3(generator.minimum.x + Float(column) * 0.1, generator.minimum.y,
                              generator.minimum.z + Float(row) * 0.1)
            #expect(abs(simulation.terrain.height(x: point.x, z: point.z) - point.y) < 0.0001)
            #expect(simulation.terrain.normal(x: point.x, z: point.z).y > 0.999)
        } }
        let source = try #require(simulation.noiseEmitters.first { $0.id == 7001 })
        #expect(source.ownerObstacleID == generator.id && source.position.y > generator.minimum.y && source.position.y < generator.maximum.y)
        let valid = try fixture()
        for light in [
            WorldSpotlightDefinition(id: 8001, position: SIMD3(-10,6,8), direction: SIMD3(0,-1,0), range: 0.15),
            WorldSpotlightDefinition(id: 8001, position: SIMD3(-10,6,8), direction: SIMD3(0,-1,0), outerCos: 0),
            WorldSpotlightDefinition(id: 8001, position: SIMD3(-10,6,8), direction: SIMD3(0,-1,0), color: SIMD3(-0.1,1,1))
        ] {
            var environment = valid.environment; environment.spotlights = [light]
            #expect(throws: MapValidationError.self) {
                try MapDefinition(id: "invalid-light", displayName: "Invalid", minimum: valid.minimum, maximum: valid.maximum,
                    terrain: valid.terrain, obstacles: valid.obstacles, playerStart: valid.playerStart,
                    reinforcementEntries: valid.reinforcementEntries, waveStaging: valid.waveStaging,
                    extraction: valid.extraction, dataSite: valid.dataSite, radioSite: valid.radioSite, environment: environment)
            }
        }
        // An actual height-field ridge blocks a light even when no AABB wall
        // exists; the same target and cone on flat terrain remain illuminated.
        var samples = [Float](repeating: 0, count: 61 * 61)
        for z in 37...39 { samples[z * 61 + 21] = 4 }
        let heightField = try TerrainHeightField(origin: SIMD2(-30,-30), width: 61, depth: 61, samples: samples)
        let hill = game(try fixture(terrain: .heightField(heightField)))
        let point = SIMD3<Float>(-8,0.1,8)
        #expect(game(valid).lightSample(at: point).artificial > 0.3)
        #expect(hill.lightSample(at: point).artificial == 0)
    }

}
