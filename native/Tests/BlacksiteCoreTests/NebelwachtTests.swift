import Foundation
import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct NebelwachtTests {
    private let map = MapDefinition.nebelwacht
    private func scene(at position: SIMD3<Float>? = nil, mission: MissionKind = .waves, seed: UInt64 = 1745,
                       enemies: [EnemyState] = [], loadout: LoadoutDefinition = .init()) -> CombatSimulation {
        CombatSimulation(difficulty: .easy, seed: seed, world: map.obstacles,
            startingPlayer: position.map { PlayerState(position: $0) }, startingEnemies: enemies,
            startingWave: 3, mission: mission, map: map, loadout: loadout)
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput(),
                                            isolateCombat: Bool = false) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            if isolateCombat { for index in game.enemies.indices where game.enemies[index].health > 0 { game.damageEnemy(index: index, amount: 10_000) } }
            game.step(deltaTime: 1.0/120, input: input)
            events += game.drainEvents()
        }
        return events
    }
    private func walk(_ game: CombatSimulation, _ points: [SIMD3<Float>], isolateCombat: Bool = false) throws {
        for point in points {
            var reached = false
            for _ in 0..<2400 {
                let delta = SIMD2(point.x - game.player.position.x, point.z - game.player.position.z)
                if simd_length(delta) < 0.08 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x, -delta.y)
                advance(game, 1, input: input, isolateCombat: isolateCombat)
            }
            try #require(reached, "target=\(point), actual=\(game.player.position), state=\(game.state)")
        }
    }
    private func altered(environment: MapEnvironmentDefinition? = nil, scenery: MapSceneryDefinition? = nil) throws -> MapDefinition {
        try MapDefinition(id: map.id, displayName: map.displayName, minimum: map.minimum, maximum: map.maximum,
            terrain: map.terrain, obstacles: map.obstacles, playerStart: map.playerStart, spawns: map.spawns,
            reinforcementEntries: map.reinforcementEntries, waveStaging: map.waveStaging,
            extraction: map.extraction, extractionRadius: map.extractionRadius, dataSite: map.dataSite, radioSite: map.radioSite,
            serviceApproach: map.serviceApproach, roads: map.roads, supportSurfaces: map.supportSurfaces,
            levelProps: map.levelProps, scenery: scenery ?? map.scenery, environment: environment ?? map.environment,
            resources: map.resources, operation: map.operation)
    }

    @Test func authoredMapHasRealFoundationsIndependentResourcesAndNineReachableGuards() throws {
        try map.validateGameplay()
        #expect(map.id == "nebelwacht" && map.version == 2 && map.spawns.count == 9)
        let returnSpray = try #require(map.environment.smokeEmitters.first { $0.id == 2761 })
        #expect(returnSpray.position == NebelwachtDefinition.supplyExit)
        #expect(returnSpray.warningIndicatorPosition == SIMD3<Float>(4.9,0,-35))
        #expect(map.environment.vegetationZones.isEmpty && map.resources.textureCrops.isEmpty)
        #expect(!map.resources.texturePaths.values.contains { $0.contains("pine") || $0.contains("bark") })
        #expect(map.resources.texturePaths[0] == map.resources.texturePaths[6] && map.resources.texturePaths[0] == map.resources.texturePaths[14])
        let game = scene()
        for box in game.obstacles {
            if box.id == 2721 {
                let platform = try #require(game.obstacles.first { $0.id == 2720 })
                #expect(abs(box.minimum.y - platform.maximum.y) < 0.0001 && abs(box.maximum.y - 11.6) < 0.0001)
            } else {
                for x in [box.minimum.x,box.position.x,box.maximum.x] {
                    for z in [box.minimum.z,box.position.z,box.maximum.z] {
                        #expect(abs(box.minimum.y - map.terrain.height(x: x,z: z)) < 0.0001, "id=\(box.id)")
                    }
                }
            }
        }
        #expect(abs(map.groundedSupportSurfaces[0].maximum.y - 6.016) < 0.0001)
        #expect(game.environmentSample(at: map.grounded(SIMD3(-28,0,10))).camouflageGround == .rubble)
        #expect(game.environmentSample(at: map.grounded(SIMD3(0,0,10))).camouflageGround == .none)
        let enemies = map.spawns.enumerated().map { EnemyState(id: 3000+$0.offset, position: map.grounded($0.element)) }
        let guards = scene(enemies: enemies), original = enemies.map(\.position)
        advance(guards, 720)
        #expect(guards.elapsed > 5.9 && guards.enemies.count >= 9 && guards.enemies.count <= 11)
        #expect(guards.enemies.prefix(9).enumerated().contains { simd_distance($0.element.position,original[$0.offset]) > 1 })
        #expect(guards.enemies.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
    }

    @Test func allGroundRoutesAndBothExitsRemainWalkableAfterDestructibleCoverCollapses() throws {
        for destroyed in [false,true] {
            for route in [NebelwachtDefinition.westRoute,NebelwachtDefinition.centralRoute,NebelwachtDefinition.eastGroundRoute,
                          NebelwachtDefinition.supplyReturnRoute,NebelwachtDefinition.westReturnRoute] {
                let game = scene(at: route[0])
                if destroyed {
                    for id in game.obstacles.filter({ $0.health.isFinite }).map(\.id) {
                        if let index = game.obstacles.firstIndex(where: { $0.id == id }) { game.damageCover(index: index, amount: 10_000) }
                    }
                }
                #expect(game.hasReachableRoute(from: game.player.position,to: map.grounded(route.last!)))
                try walk(game,Array(route.dropFirst()))
                #expect(game.player.grounded && abs(game.player.position.y - map.terrain.height(x: game.player.position.x,z: game.player.position.z)) < 0.05)
            }
        }
        let game = scene(), start = map.grounded(map.dataSite)
        func length(to point: SIMD3<Float>) -> Float {
            let path = [start] + game.findPath(from: start,to: map.grounded(point))
            return zip(path,path.dropFirst()).reduce(0) { $0 + simd_distance($1.0,$1.1) }
        }
        let supply = length(to: NebelwachtDefinition.supplyExit), west = length(to: NebelwachtDefinition.westExit)
        #expect(supply > 30 && supply < 45 && west > supply + 10)
        let rock = try #require(game.obstacles.first { $0.id == 2702 })
        #expect(!game.sightLine(rock.position + SIMD3(-5,1,0),rock.position + SIMD3(5,1,0)))
        #expect(game.sightLine(SIMD3(-6,7,6),SIMD3(6,7,6)))
    }

    @Test func bothOptionalClimbsReachHonestRoofsAndRadomeCannotBeMantled() throws {
        for (start,ids) in [(SIMD3<Float>(9.8,0,21),[2713,2714,2711]),(SIMD3<Float>(15.3,0,7),[2715,2716,2712])] {
            var player = PlayerState(position: start); player.yaw = -.pi/2
            let game = CombatSimulation(world: map.obstacles,startingPlayer: player,startingWave: 3,map: map)
            var input = GameInput(); input.yaw = player.yaw
            for (stage,id) in ids.enumerated() {
                if stage > 0 { input.moveForward = 1; advance(game,8,input: input); input.moveForward = 0 }
                try #require(game.mantle(), "id=\(id), position=\(game.player.position)")
                advance(game,100,input: input)
                let owner = try #require(game.obstacles.first { $0.id == id })
                #expect(game.player.grounded && abs(game.player.position.y - owner.maximum.y) < 0.001)
            }
            try walk(game,[SIMD3(30,0,start.z)])
            advance(game,120)
            #expect(game.player.grounded && abs(game.player.position.y - 6) < 0.001)
        }
        var player = PlayerState(position: SIMD3(19.7,8,-29)); player.yaw = -.pi/2
        let pedestal = CombatSimulation(world: map.obstacles,startingPlayer: player,startingWave: 3,map: map)
        #expect(!pedestal.mantle())
        #expect(pedestal.blocked(SIMD3(23,8,-29)))
    }

    @Test func warningAndActualSprayShareSeededPhaseAtEveryFrameRateAndPause() throws {
        let source = map.environment.smokeEmitters[0]
        #expect(source.firstEmissionTime(seed: 1745) == source.firstEmissionTime(seed: 1745))
        #expect(Set((1...8).map { source.firstEmissionTime(seed: UInt64($0)) }).count > 1)
        #expect((6...8).contains(source.firstEmissionTime(seed: 1745)))
        var baseline: [(Int,Double)] = []
        for fps in [30,60,120] {
            let game = scene(), dt = 1.0/Double(fps)
            var warnings: [GameEvent] = [], clouds: [GameEvent] = []
            for _ in 0..<(64*fps) {
                game.step(deltaTime: dt,input: GameInput())
                for event in game.drainEvents() {
                    if event.kind == .smokeWarning { warnings.append(event) }
                    if event.kind == .smokeActivated { clouds.append(event) }
                }
                #expect(game.smokeWarnings.count <= 2 && game.smokeVolumes.count <= 4)
            }
            #expect(warnings.count == 6 && clouds.count == 6)
            for event in warnings {
                let warning = try #require(event.warning), hearing = try #require(event.hearing)
                #expect(hearing.kind == .gust && hearing.source == .world && hearing.sourceID == warning.emitterID)
                #expect(abs(warning.startsAt - warning.beginsAt - 3) < 0.0001)
                #expect(abs(hearing.time - warning.beginsAt) <= 1.0/120 + 0.00001)
                let matching = try #require(clouds.first { $0.smoke?.sourceEmitterID == warning.emitterID && abs(($0.smoke?.createdAt ?? 0) - warning.startsAt) < 0.001 })
                #expect(matching.smoke?.kind == .spray)
            }
            let sequence = warnings.map { ($0.warning!.emitterID,$0.warning!.startsAt) }
            if baseline.isEmpty { baseline = sequence }
            else { #expect(zip(sequence,baseline).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }) }
            let time = game.elapsed, state = game.smokeWarnings, volumes = game.smokeVolumes.map(\.age)
            game.step(deltaTime: 0,input: GameInput())
            #expect(game.elapsed == time && game.smokeWarnings == state && game.smokeVolumes.map(\.age) == volumes)
        }
        let reset = scene(); #expect(reset.smokeWarnings.isEmpty && reset.smokeVolumes.isEmpty)
    }

    @Test func naturalGustDoesNotInventEnemyKnowledgeAndHasNoPrematureOpacity() throws {
        var environment = map.environment
        environment.smokeEmitters = [SmokeEmitterDefinition(id: 2760,kind: .spray,position: SIMD3(0,0,6),radii: SIMD3(4,2.2,4),density: 3.2,
            lifetime: 8,interval: 24,startDelay: 6,warningLeadTime: 3)]
        let windyMap = try altered(environment: environment)
        environment.smokeEmitters = []
        let clearMap = try altered(environment: environment)
        var watcher = EnemyState(id: 3001,position: SIMD3(12,6,6)); watcher.yaw = .pi/2
        let clear = CombatSimulation(world: map.obstacles,startingEnemies: [watcher],startingWave: 3,map: clearMap)
        let windy = CombatSimulation(world: map.obstacles,startingEnemies: [watcher],startingWave: 3,map: windyMap)
        var events: [GameEvent] = []
        for _ in 0..<600 {
            advance(clear,1); events += advance(windy,1)
            #expect(clear.enemies[0].position == windy.enemies[0].position && clear.enemies[0].awareness == windy.enemies[0].awareness)
            #expect(clear.enemies[0].lastHeard?.kind == windy.enemies[0].lastHeard?.kind)
            #expect(windy.smokeVolumes.isEmpty)
        }
        #expect(events.filter { $0.kind == .smokeWarning }.count == 1)
        #expect(windy.smokeWarnings.count == 1 && windy.hearingStimuli.contains { $0.kind == .gust })
        #expect(!windy.enemies.contains { $0.lastHeard?.kind == .gust })
        #expect(windy.smokeOpticalDepth(from: SIMD3(-6,7.3,6),to: SIMD3(6,7.3,6)) == 0)
        advance(windy,240)
        #expect(windy.smokeVisibility(from: SIMD3(-6,7.3,6),to: SIMD3(6,7.3,6)).opaque)
        #expect(!windy.smokeVisibility(from: SIMD3(-6,10,6),to: SIMD3(6,10,6)).opaque)
        let ray = windy.traceShot(origin: SIMD3(-6,7.3,6),direction: SIMD3(1,0,0))
        #expect(ray.distance > 8) // Optical spray never becomes a ballistic wall.
    }

    @Test func operationRoutesUseAnAnnouncedWindowOrPersistentAlarmWithoutRequiringPreparation() throws {
        // Route/objective regression deliberately isolates combat after proving
        // a real report. It does not claim to replace a human stealth/combat run.
        for role in OperatorClass.allCases { for alarmed in [false,true] {
            var witness = EnemyState(id: 3001,position: SIMD3(0,6,22)); witness.yaw = 0
            let game = scene(mission: .operation,enemies: alarmed ? [witness] : [],loadout: .init(operatorClass: role))
            if alarmed {
                for _ in 0..<720 {
                    advance(game,1)
                    if game.alarmStatus.escalated { break }
                }
                try #require(game.alarmStatus.escalated && game.state == .active)
            }
            try walk(game,[SIMD3(0,0,12)],isolateCombat: true)
            let source = map.environment.smokeEmitters[0], first = source.firstEmissionTime(seed: 1745)
            let cycle = max(0,ceil((game.elapsed - first)/Double(source.interval)))
            let crossing = first + cycle*Double(source.interval) + 1
            while game.elapsed < crossing { advance(game,1,isolateCombat: true) }
            try walk(game,[SIMD3(0,0,6)],isolateCombat: true)
            #expect(game.smokeVisibility(from: SIMD3(-6,7.3,6),to: SIMD3(6,7.3,6)).opaque)
            try walk(game,Array(NebelwachtDefinition.centralRoute.dropFirst(2)),isolateCombat: true)
            var interact = GameInput(); interact.interact = true
            advance(game,96,input: interact,isolateCombat: true)
            #expect(game.missionStatus.phase == .extract)
            let route = alarmed ? NebelwachtDefinition.westReturnRoute : NebelwachtDefinition.supplyReturnRoute
            try walk(game,Array(route.dropFirst()),isolateCombat: true)
            advance(game,361,isolateCombat: true)
            #expect(game.state == .won && game.selectedExtractionID == (alarmed ? "rock" : "supply"))
            #expect(game.devices.first { $0.id == 2750 }?.enabled == true)
            #expect(game.alarmStatus.escalated == alarmed)
            #expect(game.loadout.operatorClass == role)
        } }
    }

    @Test func authoringRejectsFalseSolidSkinsPlayableWaterAndInvalidWeather() throws {
        var environment = map.environment; environment.sunIntensity = .nan
        #expect(throws: MapValidationError.self) { try altered(environment: environment) }
        environment = map.environment
        environment.smokeEmitters = [SmokeEmitterDefinition(id: 1,position: .zero,startDelay: 2,warningLeadTime: 3)]
        #expect(throws: MapValidationError.self) { try altered(environment: environment) }
        environment.smokeEmitters = [SmokeEmitterDefinition(id: 1,position: .zero,seededDelayRange: .infinity)]
        #expect(throws: MapValidationError.self) { try altered(environment: environment) }
        var scenery = map.scenery
        scenery.boxes.append(MapVisualBox(position: .zero,size: SIMD3(1,1,1),color: SIMD3(repeating: 1),material: .zero,ownerID: 2701,replacesOwnerBody: true))
        #expect(throws: MapValidationError.self) { try altered(scenery: scenery) }
        scenery = map.scenery
        scenery.boxes.append(MapVisualBox(position: SIMD3(0,5,0),size: SIMD3(2,1,2),color: SIMD3(repeating: 1),material: .zero,castsShadow: false,mesh: .water))
        #expect(throws: MapValidationError.self) { try altered(scenery: scenery) }
        scenery = map.scenery; scenery.terrainAppearance.materialScales.x = 0
        #expect(throws: MapValidationError.self) { try altered(scenery: scenery) }
        scenery = map.scenery; scenery.terrainAppearance.surfaceWetness = 1.01
        #expect(throws: MapValidationError.self) { try altered(scenery: scenery) }
    }
}
