import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct SundkaiTests {
    private let map = MapDefinition.sundkai
    private var held: GameInput { var i = GameInput(); i.interact = true; return i }
    private func scene(at point: SIMD3<Float>? = nil, mission: MissionKind = .waves,
                       role: OperatorClass = .assault, enemies: [EnemyState] = []) -> CombatSimulation {
        CombatSimulation(difficulty: .easy,seed: 1745,world: map.obstacles,
            startingPlayer: point.map { PlayerState(position: map.grounded($0)) },startingEnemies: enemies,
            startingWave: 3,mission: mission,map: map,loadout: .init(operatorClass: role))
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput(),
                                            isolateCombat: Bool = false) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            if isolateCombat { for i in game.enemies.indices where game.enemies[i].health > 0 { game.damageEnemy(index: i,amount: 10_000) } }
            game.step(deltaTime: 1.0/120,input: input); events += game.drainEvents()
        }
        return events
    }
    @discardableResult private func walk(_ game: CombatSimulation, _ route: [SIMD3<Float>],
                                         dry: Bool = false, isolateCombat: Bool = false) throws -> [GameEvent] {
        var events: [GameEvent] = []
        for point in route {
            var reached = false
            for _ in 0..<2400 {
                let delta = SIMD2(point.x-game.player.position.x,point.z-game.player.position.z)
                if simd_length(delta) < 0.08 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
                events += advance(game,1,input: input,isolateCombat: isolateCombat)
                if dry { try #require(game.waterContact(at: game.player.position,grounded: game.player.grounded) == nil) }
            }
            try #require(reached,"target=\(point), actual=\(game.player.position), state=\(game.state)")
        }
        return events
    }

    @Test func authoredBasinsTerminalsAndFoundationsShareActualTerrainAndNineActiveGuards() throws {
        try map.validateGameplay()
        #expect(map.spawns.count == 9 && map.environment.shallowWaterZones.count == 2)
        #expect(map.resources.texturePaths[0] == map.resources.texturePaths[14] && map.resources.texturePaths[2] == map.resources.texturePaths[19])
        #expect(map.resources.textureCrops.isEmpty && map.environment.vegetationZones.allSatisfy { $0.kind == .tallGrass })
        let game = scene()
        for pool in map.environment.shallowWaterZones {
            let center = (pool.minimum+pool.maximum)*0.5
            #expect(abs(map.terrain.height(x: center.x,z: center.y)-0.75) < 0.0001)
            #expect(pool.depth(x: center.x,z: center.y,terrain: map.terrain) == 0.25)
            #expect(pool.depth(x: pool.minimum.x,z: center.y,terrain: map.terrain) == 0)
        }
        for box in game.obstacles {
            for x in [box.minimum.x,box.position.x,box.maximum.x] { for z in [box.minimum.z,box.position.z,box.maximum.z] {
                #expect(abs(box.minimum.y-map.terrain.height(x: x,z: z)) < 0.0001,"owner=\(box.id)")
            } }
        }
        for target in map.operation!.requiredStages.flatMap(\.targets) {
            let point = map.grounded(target.position)
            #expect(game.waterContact(at: point) == nil && !game.blocked(point))
        }
        for exit in map.operation!.extractions { #expect(game.waterContact(at: map.grounded(exit.position)) == nil) }
        let soldiers = map.spawns.enumerated().map { EnemyState(id: 3000+$0.offset,position: map.grounded($0.element)) }
        let guards = scene(enemies: soldiers)
        advance(guards,600)
        #expect(guards.enemies.count >= 9 && guards.enemies.count <= 11 && guards.state == .active)
        #expect(guards.enemies.prefix(9).enumerated().contains { simd_distance($0.element.position,soldiers[$0.offset].position) > 1 })
        #expect(guards.enemies.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
    }

    @Test func dryAlternativesWetShortcutAndBothExitsRemainWalkableAfterCoverDestruction() throws {
        for destroyed in [false,true] {
            for route in [SundkaiDefinition.dryWestRoute,SundkaiDefinition.dryEastRoute,SundkaiDefinition.dryRelayRoute,
                          SundkaiDefinition.serviceReturnRoute,SundkaiDefinition.harborReturnRoute] {
                let game = scene(at: route[0])
                if destroyed {
                    for id in game.obstacles.filter({ $0.health.isFinite }).map(\.id) {
                        if let index = game.obstacles.firstIndex(where: { $0.id == id }) { game.damageCover(index: index,amount: 10_000) }
                    }
                }
                #expect(game.hasReachableRoute(from: game.player.position,to: map.grounded(route.last!)))
                try walk(game,Array(route.dropFirst()),dry: true)
                #expect(game.player.grounded)
            }
        }
        let wet = scene(at: SundkaiDefinition.relayWest), dry = scene(at: SundkaiDefinition.relayWest)
        let wetEvents = try walk(wet,Array(SundkaiDefinition.wetRelayRoute.dropFirst()))
        let dryEvents = try walk(dry,Array(SundkaiDefinition.dryRelayRoute.dropFirst()),dry: true)
        #expect(wetEvents.contains { $0.hearing?.surface == .water && $0.kind == .footstep })
        #expect(!dryEvents.contains { $0.hearing?.surface == .water })
        func distance(_ route: [SIMD3<Float>]) -> Float { zip(route,route.dropFirst()).reduce(0) { $0+simd_distance($1.0,$1.1) } }
        #expect(distance(SundkaiDefinition.wetRelayRoute) < distance(SundkaiDefinition.dryRelayRoute))
        var player = PlayerState(position: map.grounded(SIMD3(15,0,21.7))); player.yaw = 0
        let climb = CombatSimulation(world: map.obstacles,startingPlayer: player,startingWave: 3,map: map)
        #expect(climb.mantle()); advance(climb,100)
        let cargo = try #require(climb.obstacles.first { $0.id == 2810 })
        #expect(climb.player.grounded && abs(climb.player.position.y-cargo.maximum.y) < 0.001)
        #expect(climb.waterContact(at: climb.player.position) == nil)
    }

    @Test func lockedDataAndInterruptedRelayUseAuthoritativeContextWithoutPrematureCompletion() throws {
        let locked = scene(at: map.dataSite,mission: .operation)
        #expect(locked.missionContextAvailable && !locked.missionInteractionAvailable && !locked.deviceContextAvailable)
        #expect(locked.missionStatus.interruption == .prerequisites && locked.missionStatus.objectiveID == "shipping-data")
        #expect(locked.missionStatus.requiredProgress == 0.8)
        let denied = advance(locked,180,input: held,isolateCombat: true)
        #expect(!denied.contains { $0.kind == .operationObjectiveCompleted } && !locked.extractionReady)
        let game = scene(at: SundkaiDefinition.relayWest,mission: .operation)
        var events = advance(game,60,input: held,isolateCombat: true)
        #expect(game.missionStatus.progress == 0.5 && game.missionStatus.phase == .activateRelays)
        let time = game.elapsed; game.step(deltaTime: 0,input: held)
        #expect(game.elapsed == time && game.missionStatus.progress == 0.5)
        events += advance(game,1,isolateCombat: true)
        #expect(game.missionStatus.progress == 0 && game.missionStatus.interruption == .interactionReleased)
        events += advance(game,119,input: held,isolateCombat: true)
        #expect(game.operationStatus?.stages[0].targets.filter(\.completed).count == 0)
        events += advance(game,1,input: held,isolateCombat: true)
        events += advance(game,240,input: held,isolateCombat: true)
        #expect(events.filter { $0.kind == .operationObjectiveCompleted }.count == 1)
        let target = try #require(events.first { $0.kind == .operationObjectiveCompleted }?.operationObjective)
        #expect(target.id == "relay-west" && target.completed && target.position == map.grounded(SundkaiDefinition.relayWest))
        #expect(game.operationStatus?.stages[0].targets.filter(\.completed).count == 1 && !game.extractionReady)
        #expect(game.missionStatus.interruption == .releaseRequired && !game.missionInteractionAvailable)
        let reset = scene(at: SundkaiDefinition.relayWest,mission: .operation)
        #expect(reset.operationStatus?.stages.flatMap(\.targets).contains(where: \.completed) == false)
        #expect(reset.missionStatus.progress == 0 && reset.missionInteractionAvailable)
    }

    @Test func everySoloClassCompletesBothRelayOrdersAndBothDryExtractionsWithRealMovement() throws {
        // Deliberately isolate combat: these are physical/objective completion
        // proofs, not claims that a human tactical run is represented by a bot.
        for role in OperatorClass.allCases { for reverse in [false,true] {
            let game = scene(mission: .operation,role: role)
            var events: [GameEvent] = []
            if reverse {
                events += try walk(game,[SIMD3(24,0,32),SIMD3(24,0,16),SundkaiDefinition.relayEast],dry: true,isolateCombat: true)
            } else {
                events += try walk(game,[SIMD3(-26,0,32),SundkaiDefinition.relayWest],dry: true,isolateCombat: true)
            }
            events += advance(game,120,input: held,isolateCombat: true)
            #expect(game.missionStatus.phase == .activateRelays && !game.extractionReady)
            let connection = reverse ? Array(SundkaiDefinition.dryRelayRoute.reversed()) : SundkaiDefinition.wetRelayRoute
            events += try walk(game,Array(connection.dropFirst()),dry: reverse,isolateCombat: true)
            events += advance(game,120,input: held,isolateCombat: true)
            #expect(game.missionStatus.phase == .collectData && game.operationStatus?.stages[0].completed == true)
            let toData: [SIMD3<Float>] = reverse ? [SIMD3(-26,0,2),SIMD3(-26,0,-18),map.dataSite] :
                [SIMD3(24,0,-22),SIMD3(-26,0,-22),map.dataSite]
            events += try walk(game,toData,dry: true,isolateCombat: true)
            events += advance(game,96,input: held,isolateCombat: true)
            #expect(game.missionStatus.phase == .extract && game.operationStatus?.stages.allSatisfy(\.completed) == true)
            let route = reverse ? SundkaiDefinition.harborReturnRoute : SundkaiDefinition.serviceReturnRoute
            events += try walk(game,Array(route.dropFirst()),dry: true,isolateCombat: true)
            events += advance(game,361,isolateCombat: true)
            #expect(game.state == .won && game.selectedExtractionID == (reverse ? "harbor" : "service"))
            #expect(game.loadout.operatorClass == role && game.devices[0].enabled)
            let completed = events.filter { $0.kind == .operationObjectiveCompleted }.compactMap(\.operationObjective)
            #expect(completed.map(\.id) == (reverse ? ["relay-east","relay-west","shipping-data"] : ["relay-west","relay-east","shipping-data"]))
            #expect(events.filter { $0.kind == .reinforcementsArrived && $0.contactReport == nil }.count == 7)
            #expect(game.pendingReinforcements == 0 && game.wave == 0 && events.filter { $0.kind == .win }.count == 1)
        } }
    }

    @Test func stagedAuthoringRejectsWetOrDestructibleRelaysAndInvalidOrdering() throws {
        func modified(_ stages: [OperationStageDefinition], world: [Obstacle]? = nil) throws -> MapDefinition {
            try MapDefinition(id: map.id,displayName: map.displayName,minimum: map.minimum,maximum: map.maximum,
                terrain: map.terrain,obstacles: world ?? map.obstacles,playerStart: map.playerStart,spawns: map.spawns,
                reinforcementEntries: map.reinforcementEntries,waveStaging: map.waveStaging,extraction: map.extraction,
                dataSite: map.dataSite,radioSite: map.radioSite,environment: map.environment,
                operation: MapOperationDefinition(preparations: [],extractions: map.operation!.extractions,requiredStages: stages))
        }
        let stages = map.operation!.requiredStages
        #expect(throws: MapValidationError.self) { try modified(Array(stages.reversed())) }
        var world = map.obstacles; world[7].health = 100
        #expect(throws: MapValidationError.self) { try modified(stages,world: world) }
        let wet = OperationStageDefinition(id: "relays",title: "Relais",kind: .relayGroup,targets: [
            .init(id: "wet",title: "Nass",position: SIMD3(0,0,15),ownerObstacleID: 2830),stages[0].targets[1]])
        let invalid = try modified([wet,stages[1]])
        #expect(throws: MapValidationError.self) { try invalid.validateGameplay() }
        #expect(MapDefinition.blacksite.operation?.requiredStages.isEmpty == true && MapDefinition.nebelwacht.operation?.requiredStages.isEmpty == true)
    }
}
